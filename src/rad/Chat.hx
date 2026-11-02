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
import xmpp.MessageStyling;

typedef Message = {
	/** Id that reactions refer to, none for local notices **/
	?id:String,

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

	/** Own reaction added or removed **/
	public static final REACT = new EventType<{id:String, reaction:String}>("react");

	/** Offered in the reaction picker **/
	static final EMOJIS = ["👍", "❤️", "😂", "😮", "😢", "🔥"];

	/** Own typing started (`true`) or stopped, to send as chat state **/
	public static final TYPING = new EventType<Bool>("typing");

	/** Send the own typing state, a setting **/
	public static var shareTyping(default, set):Bool = try js.Browser.window.localStorage.getItem("rad-typing") != "off" catch (_) true;

	static function set_shareTyping(v:Bool) {
		try js.Browser.window.localStorage.setItem("rad-typing", v ? "on" : "off") catch (_) {}
		return shareTyping = v;
	}

	@:property public var room = "";
	@:property public var subject = "";
	@:property({attribute: false}) public var messages:Array<Message> = [];
	@:property({attribute: false}) public var occupants:Array<String> = [];
	@:property({attribute: false}) public var items:Array<rad.Player.Track> = [];
	@:property({attribute: false}) public var offset = 0.0;
	@:property({type: Boolean}) public var offline = false;

	/** Reactions by message id, then nick **/
	@:property({attribute: false}) public var reactions = new Map<String, Map<String, Array<String>>>();

	/** Message id of the open reaction picker **/
	@:state var picking:Null<String>;

	/** Nicks of the others typing **/
	@:property({attribute: false}) public var typing:Array<String> = [];

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

	/** Own typing state sent, and the timer to stop it after a pause **/
	var composing = false;

	var pause:Null<Int>;

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
		js.Browser.window.clearTimeout(pause);
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
		js.Browser.window.clearTimeout(pause);
		composing = false; // the message says it
	}

	/** Typing, stops after 5 seconds without input or when the input is cleared **/
	function onInput() {
		js.Browser.window.clearTimeout(pause);
		if (input.value == "")
			return setComposing(false);
		setComposing(true);
		pause = js.Browser.window.setTimeout(() -> setComposing(false), 5000);
	}

	function setComposing(v:Bool)
		if (v != composing && (shareTyping || !v))
			TYPING.dispatch(this, composing = v);

	function react(id:String, reaction:String) {
		picking = null;
		REACT.dispatch(this, {id: id, reaction: reaction});
	}

	function pick(id:String)
		picking = (picking == id) ? null : id;

	/** Touch devices, no hover for the react button: tapping a message opens the picker **/
	function tap(e:js.html.MouseEvent, m:Message)
		if (m.id != null && js.Browser.window.matchMedia("(pointer: coarse)").matches && (cast e.target : js.html.Element).closest("a, button") == null)
			pick(m.id);

	function reactButton(m:Message)
		return (m.id == null) ? nothing : html(<button class="add" data-icon="react" title="react" aria-label="react" @click=${() -> pick(m.id)}></button>);

	/** Reactions to a message with their counts, and the picker **/
	function reactionBar(m:Message):Renderable {
		if (m.id == null)
			return nothing;
		final counts:Array<{reaction:String, nicks:Array<String>}> = [];
		for (nick => list in reactions[m.id] ?? new Map())
			for (r in list) {
				final c = Lambda.find(counts, c -> c.reaction == r);
				if (c != null)
					c.nicks.push(nick);
				else
					counts.push({reaction: r, nicks: [nick]});
			}
		if (counts.length == 0 && picking != m.id)
			return nothing;
		return html(<div class="reactions">
			${map(counts, c -> html(<button class=${c.nicks.contains(muc?.nick) ? "mine" : ""} title=${c.nicks.join(", ")} @click=${() -> react(m.id, c.reaction)}>${c.reaction} ${c.nicks.length}</button>))}
			${picking == m.id ? map(EMOJIS.filter(e -> !Lambda.exists(counts, c -> c.reaction == e)), e -> html(<button class="pick" @click=${() -> react(m.id, e)}>${e}</button>)) : nothing}
		</div>);
	}

	/** E.g. `tong is typing…` **/
	static function typingText(nicks:Array<String>)
		return switch nicks.length {
			case 1: '${nicks[0]} is typing…';
			case 2: '${nicks[0]} and ${nicks[1]} are typing…';
			case n: '$n people are typing…';
		}

	/**
		Enter sends, shift+enter breaks the line, arrow up/down on the first/last line browse the sent messages.
		Touch devices: enter breaks the line, the send button sends.
	**/
	function onKey(e:KeyboardEvent) {
		final value = input.value;
		switch e.key {
			case "Enter" if (!e.shiftKey && !js.Browser.window.matchMedia("(pointer: coarse)").matches):
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

	/** Body with styling (XEP-0393) and links, the directives shown dimmed **/
	static function styled(body:String):Array<Renderable>
		return blocks(MessageStyling.parse(body));

	static function blocks(blocks:Array<StyledBlock>):Array<Renderable> {
		final out:Array<Renderable> = [];
		var line = false; // the previous block is a line, a line break is needed
		for (b in blocks) {
			switch b {
				case Line(s):
					if (line)
						out.push("\n");
					out.push(spans(s));
				case Pre(t):
					out.push(html(<pre>${t}</pre>));
				case Quote(b):
					out.push(html(<blockquote>${Chat.blocks(b)}</blockquote>));
			}
			line = b.match(Line(_));
		}
		return out;
	}

	static function spans(spans:Array<StyledSpan>):Array<Renderable>
		return [
			for (s in spans)
				switch s {
					case Plain(t): linkify(t);
					case Strong(s): html(<strong><i class="sd">*</i>${Chat.spans(s)}<i class="sd">*</i></strong>);
					case Emphasis(s): html(<em><i class="sd">_</i>${Chat.spans(s)}<i class="sd">_</i></em>);
					case Strike(s): html(<s><i class="sd">~</i>${Chat.spans(s)}<i class="sd">~</i></s>);
					case Code(t): html(<code><i class="sd">`</i>${t}<i class="sd">`</i></code>);
				}
		];

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
					? ([html(<div class="action" style="--hue:${hue(g[0].nick)}" @click=${e -> tap(e, g[0])}><span><b class="nick">${g[0].nick}</b> ${linkify(g[0].body)}</span>${reactButton(g[0])}${ago(g[0].time)}</div>), reactionBar(g[0])] : Renderable)
					: html(<div class=${g[0].nick == "*" ? "group notice" : "group"} style="--hue:${hue(g[0].nick)}">
						<b class="nick">${g[0].nick}</b>
						${map(g, m -> ([html(<p class=${mentionsMe(m) ? "mention" : ""} @click=${e -> tap(e, m)}><span>${styled(m.body)}</span>${reactButton(m)}${ago(m.time)}</p>), reactionBar(m)] : Array<Renderable>))}
					</div>))}
			</div>
			<ul class=${people ? "open" : ""}>${map(sorted(occupants), n -> html(<li class=${n == muc?.nick ? "nick me" : "nick"} style="--hue:${hue(n)}">${n}</li>))}</ul>
			${people ? html(<div class="backdrop" @click=${() -> people = false}></div>) : nothing}
			${settings && muc != null ? html(<rad-settings .muc=${muc} @close=${Settings.CLOSE.listen(() -> settings = false)}></rad-settings>) : nothing}
			<form @submit=${submit}>${typing.length > 0 ? html(<span class="typing">${typingText(typing)}</span>) : nothing}<textarea rows="1" ?disabled=${busy} placeholder=${busy ? "loading media…" : "..."} @keydown=${onKey} @input=${onInput}></textarea><button data-icon="send" title="send" aria-label="send" ?disabled=${busy}></button></form>
		</div>);
}
