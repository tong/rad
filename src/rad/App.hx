package rad;

import js.Browser.document;
import js.Browser.window;
import js.html.Notification;
import js.html.WebSocket;
import lit.Lit.*;
import lit.LitElement;
import rad.Chat;
import rad.Login;
import rad.Player;
import rad.Player.Track;
import xmpp.ChatState;
import xmpp.Jid;
import xmpp.MessageReactions;
import xmpp.StanzaId;
import xmpp.EntityTime;
import xmpp.Muc;
import xmpp.Presence;
import xmpp.Response;
import xmpp.StreamManagement;
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

	/** Reactions (XEP-0444) by message id, then nick **/
	@:state var reactions = new Map<String, Map<String, Array<String>>>();

	/** Nicks of the others typing (XEP-0085) **/
	@:state var typing:Array<String> = [];

	/** Clears a typing nick when its `paused` got lost **/
	final typingTimers = new Map<String, Int>();

	/** Messages received while the page was hidden **/
	@:state var unread = 0;

	/** Media of a `/play` command is loading **/
	@:state var probing = false;

	/** Disconnected, reconnecting **/
	@:state var offline = false;

	var ws:Null<WebSocket>;
	var stream:Null<Stream>;
	var sm:Null<StreamManagement>;
	var account:Null<Account>;
	var resource = "";

	/** Time of the last data received, to detect dead connections **/
	var received = 0.0;

	/** Server time of the latest message, to skip room history already shown when rejoining **/
	var seen = 0.0;

	var since = 0.0;

	/** Reconnect timer and delay **/
	var retry:Null<Int>;

	var delay = 1000;

	override function createRenderRoot()
		return cast this;

	override function connectedCallback() {
		super.connectedCallback();
		document.addEventListener("visibilitychange", () -> {
			if (document.hidden)
				return;
			unread = 0;
			if (offline && ws == null) {
				window.clearTimeout(retry);
				connect();
			} else if (muc != null && !offline)
				check();
		});
		// Closing or reloading the tab: leave now, else the server keeps the hibernated session (stream management) in the room for minutes
		window.addEventListener("pagehide", () -> if (muc != null) logout());
	}

	override function updated(changed:lit.PropertyValues)
		document.title = (muc == null) ? "rad" : '${unread > 0 ? '($unread) ' : ""}${muc.room} · ${occupants.length}';

	function login(a:Account) {
		busy = true;
		error = null;
		account = a;
		if (Notification.permission == DEFAULT)
			js.Syntax.code("Notification.requestPermission()"); // missing in the extern, for mentions, asked on the join click
		final jid:Jid = a.jid;
		stream = new Stream(jid.domain);
		stream.framing = true;
		stream.output = str -> {
			js.Browser.console.debug("%c→ " + str, "color:#e8a");
			ws.send(str);
		}
		stream.onEnd = () -> drop("Stream closed");
		sm = new StreamManagement(stream);
		resource = 'rad-' + StringTools.hex(Std.random(0xffffff));
		connect();
	}

	/**
		Opens the connection and logs in.
		After a disconnection it resumes the session (XEP-0198), or else rejoins the room.
	**/
	function connect() {
		retry = null;
		final a = account, jid:Jid = account.jid;
		ws = new WebSocket(a.websocket, xmpp.net.WebSocket.PROTOCOL);
		ws.onmessage = e -> {
			received = Date.now().getTime();
			js.Browser.console.debug("%c← " + e.data, "color:#8ae");
			stream.recv(e.data);
		}
		ws.onclose = () -> drop('Connection to ${a.websocket} closed');
		ws.onopen = () -> stream.start(features -> {
			final mechanism = Authentication.selectMechanism(features, true); // PLAIN is ok, wss:// is TLS
			if (mechanism == null)
				return close("No supported authentication mechanism");
			Authentication.saslAuthentication(stream, jid.node, a.password, mechanism, (?e, features) -> {
				if (e != null)
					return close('Login failed: ${e.condition}');
				sm.resume((?e, ?_) -> {
					if (e == null)
						return online(); // still in the room, missed messages follow
					Authentication.bindResource(stream, resource, (?e, _) -> {
						if (e != null)
							return close('Login failed: ${e.condition}');
						if (StreamManagement.isOffered(features))
							sm.enable((?_) -> {});
						stream.send(new Presence());
						syncTime();
						since = seen;
						join(a.room, a.nick);
					});
				});
			});
		});
	}

	/** Connection lost: reconnects when joined, now if visible or else once visible again **/
	function drop(reason:String) {
		if (muc == null)
			return close(reason);
		if (ws == null)
			return;
		ws.onclose = ws.onmessage = null;
		ws.close();
		ws = null;
		offline = true;
		if (!document.hidden)
			retry = window.setTimeout(connect, delay);
		delay = Std.int(Math.min(delay * 2, 30000));
	}

	function online() {
		offline = false;
		delay = 1000;
	}

	/** Drops the connection if it does not respond, e.g. after the app was in the background **/
	function check() {
		final time = Date.now().getTime();
		syncTime();
		window.setTimeout(() -> if (ws != null && !offline && received < time) drop("No response"), 5000);
	}

	/** Gets the offset of the local clock to the server **/
	function syncTime() {
		final sent = Date.now().getTime();
		EntityTime.getEntityTime(stream, res -> switch res {
			case Result(xml):
				final date = EntityTime.parse(xml)?.date;
				if (date != null)
					offset = date.getTime() + 500 - (sent + Date.now().getTime()) / 2; // utc has seconds precision
			case Error(_):
		});
	}

	/** System notification, throws where only service workers may notify (Android) **/
	static function notify(nick:String, body:String)
		if (Notification.permission == GRANTED)
			try {
				final n = new Notification(nick, {body: body, icon: "icons/icon-192.png"});
				n.onclick = () -> {
					window.focus();
					n.close();
				}
			} catch (_) {}

	function join(room:Jid, nick:String) {
		occupants = [];
		typing = [];
		reactions = new Map();
		final muc = new Muc(stream, room.domain, room.node);
		stream.onPresence = muc.handlePresence;
		stream.onMessage = m -> {
			// Reactions and chat states come without a body, Muc passes on messages with a body only
			final nick = Jid.parseResource(m.from);
			if (muc.isFromRoom(m.from) && m.type == groupchat && nick != null) {
				final r = MessageReactions.getReactions(m);
				if (r != null)
					setReactions(r.id, nick, r.reactions); // also the own, reflected by the room
				if (m.delay() == null && nick != muc.nick) {
					final state = ChatState.getChatState(m);
					if (state == composing)
						setTyping(nick, true);
					else if (state != null || m.body != null)
						setTyping(nick, false);
				}
			}
			muc.handleMessage(m);
		}
		muc.onPresence = p -> {
			final n = Jid.parseResource(p.from);
			final gone = p.type == unavailable;
			if (this.muc == muc && n != muc.nick && occupants.contains(n) == gone) // not while joining
				messages = messages.concat([{nick: n, body: gone ? "left" : "joined", time: Date.now(), action: true}]);
			occupants = occupants.filter(o -> o != n).concat(gone ? [] : [n]);
			if (gone)
				setTyping(n, false);
		}
		muc.onMessage = m -> {
			final nick = Jid.parseResource(m.from) ?? "";
			final time = DelayedDelivery.parseStamp(m.delay()?.stamp);
			if (time != null && time.getTime() <= since)
				return; // shown before the reconnect
			seen = Math.max(seen, time?.getTime() ?? Date.now().getTime() + offset);
			if (m.delay() == null && nick != muc.nick) {
				if (document.hidden)
					unread++;
				if (!document.hasFocus() && Chat.mentions(m.body, muc.nick))
					notify(nick, m.body); // also when another window covers rad
			}
			messages = messages.concat([
				{
					id: StanzaId.getStanzaId(m, '${muc.room}@${muc.host}') ?? m.id, // what reactions refer to
					nick: nick,
					body: m.body,
					action: Lambda.exists(m.properties, e -> e.is(XMLNS_MEDIA)),
					time: time ?? Date.now()
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
									title: e["title"],
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
								title: i.title,
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
				online();
			case Error(e):
				close('Could not join ${room}: ${e.condition}');
		});
	}

	/**
		Sends a message to the room. Commands:

		- `/play <url>…` adds media to the playlist
		- `/skip` removes the playing item
		- `/remove <n>` removes item `n` of the playlist
		- `/help` lists the commands
	**/
	function send(body:String) {
		final args = ~/\s+/g.split(body);
		final now = Date.now().getTime() + offset;
		final slots = Player.schedule(items);
		switch args[0] {
			case "/help":
				notice("/play <url> …   add YouTube, Vimeo, SoundCloud, Mixcloud or media file links to the playlist
/skip           remove the playing item
/remove <n>     remove item n of the playlist
/help           list the commands");
			case "/play":
				final urls = args.slice(1).filter(u -> Media.parse(u) != null);
				if (urls.length == 0)
					return notice("Usage: /play <url> (YouTube, Vimeo, SoundCloud, Mixcloud or a media file)");
				probing = true;
				js.lib.Promise.all([
					for (url in urls)
						Media.probe(Media.parse(url)).then(p -> XML.create("media")
							.set("xmlns", XMLNS_MEDIA)
							.set("id", StringTools.hex(Std.random(0x7fffffff)) + StringTools.hex(Std.random(0x7fffffff)))
							.set("url", url)
							.set("title", p.title ?? url)
							.set("duration", Std.string(p.duration))
							.set("time", Std.string(now)), _ -> {
								notice('Could not load $url');
								null;
							})
				]).then(media -> {
					probing = false;
					media = media.filter(e -> e != null);
					if (media.length > 0)
						say([for (e in media) 'added “${e["title"]}” ${e["url"]}'].join("\n"), media);
				});
			case "/skip":
				final slot = Lambda.find(slots, s -> now >= s.start && now < s.end);
				if (slot == null)
					return notice("Nothing is playing");
				say('skipped “${slot.item.title ?? slot.item.url}”', [removal(slot.item, now)]);
			case "/remove":
				final slot = slots[Std.parseInt(args[1] ?? "") - 1];
				if (slot == null)
					return notice("Usage: /remove <number of the playlist item>");
				if (slot.end <= now)
					return notice("Already played");
				say('removed “${slot.item.title ?? slot.item.url}”', [removal(slot.item, now)]);
			case _:
				say(body);
		}
	}

	/** Shows or hides a typing nick, hidden after 30 seconds without news **/
	function setTyping(nick:String, on:Bool) {
		window.clearTimeout(typingTimers[nick]);
		typingTimers.remove(nick);
		if (on)
			typingTimers[nick] = window.setTimeout(() -> setTyping(nick, false), 30000);
		if (typing.contains(nick) != on)
			typing = on ? typing.concat([nick]) : typing.filter(n -> n != nick);
	}

	/** Replaces the reactions of `nick` to message `id` **/
	function setReactions(id:String, nick:String, list:Array<String>) {
		final next = reactions.copy();
		final byNick = next[id]?.copy() ?? new Map();
		if (list.length > 0)
			byNick[nick] = list;
		else
			byNick.remove(nick);
		next[id] = byNick;
		reactions = next;
	}

	/** Adds or removes an own reaction **/
	function react(r:{id:String, reaction:String}) {
		if (offline)
			return notice("Not connected, reconnecting…");
		final own = reactions[r.id]?.get(muc.nick) ?? [];
		final list = own.contains(r.reaction) ? own.filter(e -> e != r.reaction) : own.concat([r.reaction]);
		muc.stream.send(MessageReactions.react(new xmpp.Message('${muc.room}@${muc.host}', null, null, groupchat), r.id, list));
	}

	/** Sends the own typing state **/
	function sendTyping(on:Bool)
		if (muc != null && !offline)
			muc.stream.send(ChatState.setChatState(new xmpp.Message('${muc.room}@${muc.host}', null, null, groupchat), on ? composing : paused));

	function removal(item:Track, time:Float)
		return XML.create("remove").set("xmlns", XMLNS_MEDIA).set("id", item.id).set("time", Std.string(time));

	function say(body:String, ?elements:Array<XML>) {
		if (offline)
			return notice("Not connected, reconnecting…");
		final m = new xmpp.Message('${muc.room}@${muc.host}', body, null, groupchat);
		m.id = xmpp.Stream.makeRandomId(); // for reactions, when the room adds no stanza-id
		if (elements != null)
			m.properties = m.properties.concat(elements);
		if (Chat.shareTyping)
			ChatState.setChatState(m, active);
		muc.stream.send(m);
	}

	/** Shows a local message **/
	function notice(text:String)
		messages = messages.concat([{nick: "*", body: text, time: Date.now()}]);

	function logout() {
		if (!offline) {
			muc.leave();
			stream.end();
		}
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
			ws.onclose = ws.onmessage = null;
			ws.close();
			ws = null;
		}
		window.clearTimeout(retry);
		retry = null;
		delay = 1000;
		seen = since = 0;
		stream = null;
		sm = null;
		account = null;
		offline = false;
		probing = false;
		muc = null;
		busy = false;
		error = reason;
		messages = [];
		occupants = [];
		items = [];
		subject = "";
		unread = 0;
	}

	override function render()
		return if (muc == null)
			html(<rad-login ?busy=${busy} .error=${error} .config=${{domain: domain, websocket: websocket, room: room, conference: conference}} @login=${Login.LOGIN.listen(login)}></rad-login>);
		else
			html(<rad-chat room=${'${muc.room}@${muc.host}'} subject=${subject} .messages=${messages} .occupants=${occupants} .items=${items} .offset=${offset} ?offline=${offline} ?busy=${probing} .muc=${muc} .typing=${typing} .reactions=${reactions}
				@send=${Chat.SEND.listen(send)} @react=${Chat.REACT.listen(react)} @typing=${Chat.TYPING.listen(sendTyping)} @logout=${Chat.LOGOUT.listen(logout)}></rad-chat>);
}
