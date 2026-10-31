package rad;

import js.Browser.window;
import js.html.WebSocket;
import lit.Lit.*;
import lit.LitElement;
import rad.Chat;
import rad.Login;
import rad.Player;
import rad.Player.Track;
import xmpp.Jid;
import xmpp.EntityTime;
import xmpp.Muc;
import xmpp.Presence;
import xmpp.Response;
import xmpp.XML;
import xmpp.client.Authentication;
import xmpp.client.Stream;

using xmpp.DelayedDelivery;
using xmpp.client.Authentication;

@:customElement("rad-app")
class App extends LitElement {
	/** Namespace of the playlist elements attached to messages: `<media/>` adds an item, `<remove/>` removes one **/
	static inline var XMLNS_MEDIA = "urn:xmpp:rad:media:0";

	static function main() {}

	// Site configuration, see `Login.Config`
	@:property public var domain:Null<String>;
	@:property public var websocket:Null<String>;
	@:property public var room:Null<String>;
	@:property public var conference:Null<String>;

	@:state var busy = false;
	@:state var error:Null<String>;
	@:state var muc:Null<Muc>;
	@:state var subject = "";
	@:state var messages:Array<Message> = [];
	@:state var occupants:Array<String> = [];
	@:state var items:Array<Track> = [];
	@:state var offset = 0.0;

	var ws:Null<WebSocket>;

	override function createRenderRoot()
		return cast this;

	function login(a:Account) {
		busy = true;
		error = null;
		final jid:Jid = a.jid;
		final stream = new Stream(jid.domain);
		stream.framing = true;
		stream.output = str -> ws.send(str);
		stream.onEnd = () -> close("Stream closed");
		ws = new WebSocket(a.websocket, xmpp.net.WebSocket.PROTOCOL);
		ws.onmessage = e -> stream.recv(e.data);
		ws.onclose = () -> close('Connection to ${a.websocket} closed');
		ws.onopen = () -> stream.start(features -> {
			final mechanism = Authentication.selectMechanism(features, true); // PLAIN is ok, wss:// is TLS
			if (mechanism == null)
				return close("No supported authentication mechanism");
			stream.authenticate(jid.node, 'rad-' + StringTools.hex(Std.random(0xffffff)), a.password, mechanism, (?e) -> {
				if (e != null)
					return close('Login failed: ${e.condition}');
				stream.send(new Presence());
				syncTime(stream);
				join(stream, a.room, a.nick);
			});
		});
	}

	/** Gets the offset of the local clock to the server **/
	function syncTime(stream:Stream) {
		final sent = Date.now().getTime();
		EntityTime.getEntityTime(stream, res -> switch res {
			case Result(xml):
				final date = EntityTime.parse(xml)?.date;
				if (date != null)
					offset = date.getTime() + 500 - (sent + Date.now().getTime()) / 2; // utc has seconds precision
			case Error(_):
		});
	}

	function join(stream:Stream, room:Jid, nick:String) {
		final muc = new Muc(stream, room.domain, room.node);
		stream.onPresence = muc.handlePresence;
		stream.onMessage = muc.handleMessage;
		muc.onPresence = p -> {
			final n = Jid.parseResource(p.from);
			occupants = occupants.filter(o -> o != n).concat(p.type == unavailable ? [] : [n]);
		}
		muc.onMessage = m -> {
			final nick = Jid.parseResource(m.from) ?? "";
			messages = messages.concat([
				{
					nick: nick,
					body: m.body,
					time: DelayedDelivery.parseStamp(m.delay()?.stamp) ?? Date.now()
				}
			]);
			for (e in m.properties)
				if (e.is(XMLNS_MEDIA))
					switch e.name {
						case "media":
							items = items.concat([
								{
									id: e["id"],
									url: e["url"],
									nick: nick,
									duration: Std.parseFloat(e["duration"]),
									time: Std.parseFloat(e["time"])
								}
							]);
						case "remove":
							final time = Std.parseFloat(e["time"]);
							items = [for (i in items) (i.id == e["id"]) ? {
								id: i.id,
								url: i.url,
								nick: i.nick,
								duration: i.duration,
								time: i.time,
								removed: Math.min(i.removed ?? time, time)
							} : i];
					}
		}
		muc.onSubject = s -> subject = s;
		muc.onNick = _ -> requestUpdate();
		muc.onLeave = (reason, ?text) -> close('Left room: $reason ${text ?? ""}');
		muc.join(nick, res -> switch res {
			case Result(_):
				rememberLogin('${room}');
				busy = false;
				occupants = occupants.concat([muc.nick]);
				this.muc = muc;
			case Error(e):
				close('Could not join ${room}: ${e.condition}');
		});
	}

	/**
		Sends a message to the room. Commands:

		- `/play <url>…` adds media to the playlist
		- `/skip` removes the playing item
		- `/remove <n>` removes item `n` of the playlist
	**/
	function send(body:String) {
		final args = ~/\s+/g.split(body);
		final now = Date.now().getTime() + offset;
		final slots = Player.schedule(items);
		switch args[0] {
			case "/play":
				final urls = args.slice(1).filter(u -> Media.parse(u) != null);
				if (urls.length == 0)
					return notice("Usage: /play <url> (YouTube, SoundCloud, Mixcloud or a media file)");
				js.lib.Promise.all([
					for (url in urls)
						Media.probe(Media.parse(url)).then(d -> XML.create("media")
							.set("xmlns", XMLNS_MEDIA)
							.set("id", StringTools.hex(Std.random(0x7fffffff)) + StringTools.hex(Std.random(0x7fffffff)))
							.set("url", url)
							.set("duration", Std.string(d))
							.set("time", Std.string(now)), _ -> {
								notice('Could not load $url');
								null;
							})
				]).then(media -> {
					media = media.filter(e -> e != null);
					if (media.length > 0)
						say(body, media);
				});
			case "/skip":
				final slot = Lambda.find(slots, s -> now >= s.start && now < s.end);
				if (slot == null)
					return notice("Nothing is playing");
				say(body, [removal(slot.item, now)]);
			case "/remove":
				final slot = slots[Std.parseInt(args[1] ?? "") - 1];
				if (slot == null)
					return notice("Usage: /remove <number of the playlist item>");
				if (slot.end <= now)
					return notice("Already played");
				say(body, [removal(slot.item, now)]);
			case _:
				say(body);
		}
	}

	function removal(item:Track, time:Float)
		return XML.create("remove").set("xmlns", XMLNS_MEDIA).set("id", item.id).set("time", Std.string(time));

	function say(body:String, ?elements:Array<XML>) {
		final m = new xmpp.Message('${muc.room}@${muc.host}', body, null, groupchat);
		if (elements != null)
			m.properties = m.properties.concat(elements);
		muc.stream.send(m);
	}

	/** Shows a local message **/
	function notice(text:String)
		messages = messages.concat([{nick: "*", body: text, time: Date.now()}]);

	function logout() {
		muc.leave();
		muc.stream.end();
		close();
	}

	/**
		Lets the browser offer to save the password.
		It can't tell by itself that the login worked, as it ran over the websocket instead of a form submission.
	**/
	function rememberLogin(room:String) {
		final form = querySelector("rad-login form");
		if (form != null && js.Syntax.code("'PasswordCredential' in window"))
			try js.Syntax.code("navigator.credentials.store(new PasswordCredential({0})).catch(() => {})", form) catch (_) {} // Chromium
		window.history.replaceState(null, "", '#$room'); // same document navigation counts as success too (Firefox)
	}

	function close(?reason:String) {
		window.history.replaceState(null, "", window.location.pathname + window.location.search);
		if (ws != null) {
			ws.onclose = null;
			ws.close();
			ws = null;
		}
		muc = null;
		busy = false;
		error = reason;
		messages = [];
		occupants = [];
		items = [];
		subject = "";
	}

	override function render()
		return if (muc == null)
			html(<rad-login ?busy=${busy} .error=${error} .config=${{domain: domain, websocket: websocket, room: room, conference: conference}} @login=${Login.LOGIN.listen(login)}></rad-login>);
		else
			html(<rad-chat room=${'${muc.room}@${muc.host}'} nick=${muc.nick} subject=${subject} .messages=${messages} .occupants=${occupants} .items=${items} .offset=${offset}
				@send=${Chat.SEND.listen(send)} @logout=${Chat.LOGOUT.listen(logout)}></rad-chat>);
}
