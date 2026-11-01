package rad;

import js.html.Event;
import js.html.KeyboardEvent;
import js.html.TextAreaElement;
import lit.Directives.*;
import lit.EventType;
import lit.Lit.*;
import lit.LitElement;
import lit.PropertyValues;
import lit.Renderable;
import rad.Player;

typedef Message = {
	nick:String,
	body:String,
	time:Date,

	/** Event, e.g. "joined" or a playlist change "added …" **/
	?action:Bool
}

@:customElement("rad-chat")
class Chat extends LitElement {
	public static final SEND = new EventType<String>("send");
	public static final LOGOUT = new EventType<Void>("logout");

	@:property public var room = "";
	@:property public var subject = "";
	@:property({attribute: false}) public var messages:Array<Message> = [];
	@:property({attribute: false}) public var occupants:Array<String> = [];
	@:property({attribute: false}) public var items:Array<rad.Player.Track> = [];
	@:property({attribute: false}) public var offset = 0.0;
	@:property({type: Boolean}) public var offline = false;

	/** A command is in progress, input is blocked **/
	@:property({type: Boolean}) public var busy = false;

	@:property({attribute: false}) public var muc:Null<xmpp.Muc>;

	/** User list shown, on small screens **/
	@:state var people = false;

	@:state var settings = false;

	/** Re-renders the message ages **/
	var timer:Null<Int>;

	/** Own sent messages, browsed with arrow up/down **/
	final sent:Array<String> = [];

	/** Position in `sent`, `sent.length` when not browsing **/
	var browse = 0;

	/** Input before browsing started **/
	var draft = "";

	@:query(".log") var log:js.html.Element;
	@:query("form textarea") var input:TextAreaElement;

	override function createRenderRoot()
		return cast this;

	override function connectedCallback() {
		super.connectedCallback();
		timer = js.Browser.window.setInterval(requestUpdate, 30000);
	}

	override function disconnectedCallback() {
		super.disconnectedCallback();
		js.Browser.window.clearInterval(timer);
	}

	/** Focuses the input on desktop only, on touch devices the keyboard would cover the chat **/
	override function firstUpdated(changed:PropertyValues)
		if (js.Browser.window.matchMedia("(pointer: fine)").matches)
			input.focus();

	override function updated(changed:PropertyValues) {
		if (changed.has("messages"))
			log.scrollTop = log.scrollHeight;
		if (changed.get("busy") == true && js.Browser.window.matchMedia("(pointer: fine)").matches)
			input.focus(); // focus got lost while disabled
	}

	function submit(e:Event) {
		e.preventDefault();
		final body = StringTools.trim(input.value);
		if (body != "") {
			SEND.dispatch(this, body);
			sent.push(body);
		}
		browse = sent.length;
		setInput("");
	}

	/** Enter sends, shift+enter breaks the line, arrow up/down on the first/last line browse the sent messages **/
	function onKey(e:KeyboardEvent) {
		final value = input.value;
		switch e.key {
			case "Enter" if (!e.shiftKey):
				submit(e);
			case "ArrowUp" if (browse > 0 && value.lastIndexOf("\n", input.selectionStart - 1) == -1):
				if (browse == sent.length)
					draft = value;
				setInput(sent[--browse]);
			case "ArrowDown" if (browse < sent.length && value.indexOf("\n", input.selectionEnd) == -1):
				setInput((++browse == sent.length) ? draft : sent[browse]);
			case _:
				return;
		}
		e.preventDefault();
	}

	function setInput(value:String)
		input.value = value;

	/** Consecutive messages of the same sender, at most 5 minutes apart **/
	static function groups(messages:Array<Message>):Array<Array<Message>> {
		final groups:Array<Array<Message>> = [];
		for (m in messages) {
			final last = groups[groups.length - 1];
			if (last != null && !m.action && !last[0].action && last[0].nick == m.nick && m.time.getTime() - last[last.length - 1].time.getTime() < 300000)
				last.push(m);
			else
				groups.push([m]);
		}
		return groups;
	}

	/** Body with clickable links **/
	static function linkify(body:String):Array<Renderable> {
		final parts:Array<Renderable> = [];
		final r = ~/https?:\/\/[^\s<>"]+/;
		while (r.match(body)) {
			parts.push(r.matchedLeft());
			parts.push(html(<a href=${r.matched(0)} target="_blank">${r.matched(0)}</a>));
			body = r.matchedRight();
		}
		parts.push(body);
		return parts;
	}

	/** Age of a message, e.g. `6m`, the date on hover **/
	static function ago(date:Date) {
		final s = (Date.now().getTime() - date.getTime()) / 1000;
		final text = (s < 60) ? "now" : (s < 3600) ? '${Std.int(s / 60)}m' : (s < 86400) ? '${Std.int(s / 3600)}h' : '${Std.int(s / 86400)}d';
		return html(<time title=${DateTools.format(date, "%Y-%m-%d %H:%M")}>${text}</time>);
	}

	/** Body contains `@` and the nick **/
	public static function mentions(body:String, nick:String)
		return new EReg('@${EReg.escape(nick)}(?![\\w-])', "i").match(body);

	function mentionsMe(m:Message)
		return muc != null && m.nick != muc.nick && mentions(m.body, muc.nick);

	/** Nicks in alphabetical order, ignoring case **/
	static function sorted(nicks:Array<String>) {
		final a = nicks.copy();
		a.sort((x, y) -> js.Syntax.code("{0}.localeCompare({1}, undefined, {sensitivity: 'base'})", x, y));
		return a;
	}

	/** Stable color for a nick **/
	public static function hue(nick:String) {
		var h = 0;
		for (i in 0...nick.length)
			h = (h * 31 + nick.charCodeAt(i)) % 360;
		return h;
	}

	override function render()
		return html(<div style="display:contents">
			<header>
				<div class="title">
					<h1 title=${subject}>${subject != "" ? subject : room}</h1>
					${subject != "" ? html(<span class="room">${room}</span>) : nothing}
				</div>
				${offline ? html(<span class="status">reconnecting…</span>) : nothing}
				<button class="count" data-icon="users" title="users" @click=${() -> people = !people}>${occupants.length}</button>
				<button data-icon="settings" title="settings" aria-label="settings" @click=${() -> settings = !settings}></button>
				<button data-icon="leave" title="leave" aria-label="leave" @click=${() -> LOGOUT.dispatch(this)}></button>
			</header>
			<rad-player .items=${items} .offset=${offset}></rad-player>
			<div class="log">
				${map(groups(messages), g -> g[0].action
					? html(<div class="action" style="--hue:${hue(g[0].nick)}"><span><b class="nick">${g[0].nick}</b> ${linkify(g[0].body)}</span>${ago(g[0].time)}</div>)
					: html(<div class=${g[0].nick == "*" ? "group notice" : "group"} style="--hue:${hue(g[0].nick)}">
						<b class="nick">${g[0].nick}</b>
						${map(g, m -> html(<p class=${mentionsMe(m) ? "mention" : ""}><span>${linkify(m.body)}</span>${ago(m.time)}</p>))}
					</div>))}
			</div>
			<ul class=${people ? "open" : ""}>${map(sorted(occupants), n -> html(<li class=${n == muc?.nick ? "nick me" : "nick"} style="--hue:${hue(n)}">${n}</li>))}</ul>
			${people ? html(<div class="backdrop" @click=${() -> people = false}></div>) : nothing}
			${settings && muc != null ? html(<rad-settings .muc=${muc} @close=${Settings.CLOSE.listen(() -> settings = false)}></rad-settings>) : nothing}
			<form @submit=${submit}><textarea rows="1" ?disabled=${busy} placeholder=${busy ? "loading media…" : "..."} @keydown=${onKey}></textarea><button data-icon="send" title="send" aria-label="send" ?disabled=${busy}></button></form>
		</div>);
}
