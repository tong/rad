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
	?action:Bool,

	/** Ids of the playlist items it added **/
	?items:Array<String>
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

	/** Media links in the input, previewed above it **/
	@:state var links:Array<String> = [];

	/** The input holds only media links: sent, they are added to the playlist **/
	@:state var playable = false;

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
		linksTimer = js.Browser.window.setInterval(drawLinksSoon, 1000); // the playing item changes, thumbnails load
		addEventListener("scroll", drawLinksSoon, true); // of the log and the playlist
		addEventListener("mouseover", hover);
		addEventListener("mouseleave", () -> {
			hovered = null;
			drawLinksSoon();
		});
		js.Browser.window.addEventListener("resize", drawLinksSoon);
	}

	override function disconnectedCallback() {
		super.disconnectedCallback();
		js.Browser.window.clearInterval(timer);
		js.Browser.window.clearInterval(linksTimer);
		js.Browser.window.removeEventListener("resize", drawLinksSoon);
		js.Browser.window.cancelAnimationFrame(linksFrame);
		js.Browser.window.clearTimeout(pause);
	}

	/**
		Shared to rad from another app (Web Share Target, see `manifest.json`): put into the input after joining, to send it.
		Read once from the query of the start url, then removed from the address.
	**/
	public static var shared:Null<String> = readShared();

	static function readShared():Null<String> {
		final location = js.Browser.window.location;
		final q = new js.html.URLSearchParams(location.search);
		final text = q.get("text") ?? "", title = q.get("title") ?? "";
		var url = q.get("url") ?? "";
		final link = ~/https?:\/\/\S+/;
		if (url == "" && link.match(text)) // e.g. the YouTube app shares the link in the text
			url = link.matched(0);
		final value = (url != "") ? url : (text != "") ? text : title;
		if (value == "")
			return null;
		js.Browser.window.history.replaceState(null, "", location.pathname + location.hash);
		return value;
	}

	/**
		Keeps `el` scrolled to the end when it is resized or content is added later, unless scrolled up:
		the layout changes after the content arrived (the player loads, fonts), thumbnails of media links are inserted once looked up.
	**/
	public static function pinToEnd(el:js.html.Element):() -> Void {
		var end = true;
		final stick = () -> if (end) el.scrollTop = el.scrollHeight;
		el.addEventListener("scroll", () -> end = el.scrollHeight - el.scrollTop - el.clientHeight < 40);
		js.Syntax.code("new ResizeObserver({0}).observe({1})", stick, el); // no extern
		new js.html.MutationObserver((_, _) -> stick()).observe(el, {childList: true, subtree: true});
		// scrolls to the end, and stays there: content may follow before the scroll event says so
		return () -> {
			end = true;
			stick();
		}
	}

	/** Scrolls the log to the end, see `pinToEnd` **/
	var toEnd:() -> Void = () -> {};

	/** Focuses the input on desktop only, on touch devices the keyboard would cover the chat **/
	override function firstUpdated(changed:PropertyValues) {
		toEnd = pinToEnd(log);
		if (shared != null) {
			input.value = shared;
			shared = null;
			readInput();
		}
		if (js.Browser.window.matchMedia("(pointer: fine)").matches)
			input.focus();
	}

	// --- Links between the playlist items and the chat messages that added them, side by side (desktop)

	/** Item ids under the mouse, `null`: the playing item **/
	var hovered:Null<Array<String>>;

	var linksTimer = 0;
	var linksFrame = 0;

	function drawLinksSoon()
		if (linksFrame == 0)
			linksFrame = js.Browser.window.requestAnimationFrame(_ -> {
				linksFrame = 0;
				drawLinks();
			});

	function hover(e:js.html.MouseEvent) {
		final el = (cast e.target : js.html.Element).closest("[data-item], [data-items]");
		final ids = (el == null) ? [] : (el.dataset.item != null) ? [el.dataset.item] : el.dataset.items.split(" ").filter(s -> s != "");
		hovered = (ids.length > 0) ? ids : null;
		drawLinksSoon();
	}

	/** Lines with sharp turns from the items to their messages, to the edge with an arrow when scrolled out of view, both ends highlighted **/
	function drawLinks() {
		final svg = querySelector("svg.links"), list = querySelector("rad-player ol");
		for (e in querySelectorAll(".linked"))
			(cast e : js.html.Element).classList.remove("linked");
		if (svg == null)
			return;
		svg.innerHTML = "";
		if (list == null || !js.Browser.window.matchMedia("(width >= 64rem)").matches)
			return;
		final playing = querySelector("rad-player li.current .item");
		final ids = hovered ?? ((playing != null) ? [playing.dataset.item] : []);
		final lr = list.getBoundingClientRect(), gr = log.getBoundingClientRect();
		final out = new StringBuf();
		// a dot, or an arrow up/down when the element is out of view
		function end(x:Float, y:Float, dir:Int)
			out.add((dir == 0) ? '<circle class="end" cx="$x" cy="$y" r="3"/>' : '<path class="end" d="M${x - 4} ${y - 3 * dir}L$x ${y + 3 * dir}L${x + 4} ${y - 3 * dir}Z"/>');
		function clamp(y:Float, r:js.html.DOMRect)
			return (y < r.top + 8) ? {y: r.top + 8, dir: -1} : (y > r.bottom - 8) ? {y: r.bottom - 8, dir: 1} : {y: y, dir: 0};
		for (id in ids) {
			final css:String = js.Syntax.code("CSS.escape({0})", id);
			final a = list.querySelector('.item[data-item="$css"]'), b = log.querySelector('[data-items~="$css"]');
			if (a == null || b == null)
				continue;
			a.classList.add("linked");
			b.classList.add("linked");
			final ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect();
			final x1 = Math.min(ra.right, lr.right) + 2, x2 = Math.max(rb.left, gr.left) - 2;
			final p1 = clamp(ra.top + ra.height / 2, lr), p2 = clamp(rb.top + rb.height / 2, gr);
			final xm = Math.round((x1 + x2) / 2); // the vertical part, in the gap between the views
			if (p1.dir != 0 && p1.dir == p2.dir)
				continue; // both out of view on the same side
			final dy = p2.y - p1.y, sy = (dy < 0) ? -1 : 1;
			final r = Math.min(4, Math.min(Math.abs(dy) / 2, Math.min(xm - x1, x2 - xm))); // slightly rounded turns
			// an end out of view: no turn into its view, the vertical part runs on to the edge
			final start = (p1.dir == 0) ? 'M$x1 ${p1.y}H${xm - r}Q$xm ${p1.y} $xm ${p1.y + r * sy}' : 'M$xm ${p1.y}';
			final finish = (p2.dir == 0) ? 'V${p2.y - r * sy}Q$xm ${p2.y} ${xm + r} ${p2.y}H$x2' : 'V${p2.y}';
			out.add('<path d="$start$finish"/>');
			end((p1.dir == 0) ? x1 : xm, p1.y, p1.dir);
			end((p2.dir == 0) ? x2 : xm, p2.y, p2.dir);
		}
		svg.innerHTML = out.toString();
	}

	override function updated(changed:PropertyValues) {
		drawLinksSoon();
		if (changed.has("messages") && own(messages[messages.length - 1]))
			toEnd(); // also when scrolled up to read: the own message, or the answer to a command
		if (changed.get("busy") == true && js.Browser.window.matchMedia("(pointer: fine)").matches)
			input.focus(); // focus got lost while disabled
	}

	function submit(e:Event) {
		e.preventDefault();
		post(StringTools.trim(input.value));
	}

	/** Only media links: posted, they are added to the playlist **/
	public static function onlyMedia(value:String):Bool {
		final words = ~/\s+/g.split(StringTools.trim(value));
		return words[0] != "" && Lambda.foreach(words, w -> Media.parse(w) != null);
	}

	function post(body:String) {
		if (body != "") {
			SEND.dispatch(this, body);
			sent.push(body);
		}
		browse = sent.length;
		input.value = "";
		readInput();
		js.Browser.window.clearTimeout(pause);
		composing = false; // the message says it
	}

	/** Typing, stops after 5 seconds without input or when the input is cleared **/
	function onInput() {
		readInput();
		js.Browser.window.clearTimeout(pause);
		if (input.value == "")
			return setComposing(false);
		setComposing(true);
		pause = js.Browser.window.setTimeout(() -> setComposing(false), 5000);
	}

	/** Updates the preview of the media links in the input **/
	function readInput() {
		final l = mediaUrls(input.value);
		if (l.join(" ") != links.join(" "))
			links = l;
		playable = onlyMedia(input.value);
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

	/** Clicking an "added" line scrolls its playlist item into view, when it isn't **/
	function showItem(e:js.html.MouseEvent, m:Message) {
		if (m.items == null || m.items.length == 0 || (cast e.target : js.html.Element).closest("a, button") != null)
			return;
		final css:String = js.Syntax.code("CSS.escape({0})", m.items[0]);
		querySelector('rad-player .item[data-item="$css"]')?.scrollIntoView({block: NEAREST, behavior: SMOOTH});
	}

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
				input.value = sent[--browse];
			case "ArrowDown" if (browse < sent.length && value.indexOf("\n", input.selectionEnd) == -1):
				input.value = (++browse == sent.length) ? draft : sent[browse];
			case _:
				return;
		}
		readInput();
		e.preventDefault();
	}

	/** Joined or left: a line of its own. Shown locally, no id, unlike the playlist changes **/
	static function presence(m:Message)
		return m.action == true && m.id == null;

	/** Consecutive messages of the same sender, its playlist changes too. Each shows its own time **/
	static function groups(messages:Array<Message>):Array<Array<Message>> {
		final groups:Array<Array<Message>> = [];
		for (m in messages) {
			final last = groups[groups.length - 1];
			if (last != null && !presence(m) && !presence(last[0]) && last[0].nick == m.nick)
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

	/** Thumbnails of media links in messages, by url, looked up once **/
	static final thumbs = new Map<String, js.lib.Promise<Null<String>>>();

	/** The thumbnail of a media link once looked up, nothing if it has none **/
	static function thumbnail(url:String) {
		if (!thumbs.exists(url))
			thumbs[url] = Media.thumbnail(Media.parse(url)).catchError(_ -> null);
		return until(thumbs[url].then(t -> (t != null && StringTools.startsWith(t, "https://")) ? html(<img src=${t} alt="" referrerpolicy="no-referrer"/>) : nothing), nothing);
	}

	/** Media links in `text`, each once **/
	static function mediaUrls(text:String):Array<String> {
		final urls:Array<String> = [];
		final r = ~/https?:\/\/[^\s<>"]+/;
		while (r.match(text)) {
			final url = r.matched(0);
			if (Media.parse(url) != null && !urls.contains(url))
				urls.push(url);
			text = r.matchedRight();
		}
		return urls;
	}

	/** Media links posted within other text: thumbnail and a button to add them to the playlist **/
	function mediaLinks(m:Message):Renderable
		return (m.nick == "*") ? nothing : [
			for (url in mediaUrls(m.body))
				html(<span class="media"><a href=${url} target="_blank">${thumbnail(url)}</a><button data-icon="add" title="add to the playlist" @click=${() -> SEND.dispatch(this, url)}>play</button></span>)
		];

	/** Thumbnails of the playlist items a message added **/
	function itemThumbs(m:Message):Renderable {
		final urls = [for (id in m.items ?? []) Lambda.find(items, i -> i.id == id)?.thumb].filter(t -> t != null);
		return (urls.length == 0) ? nothing : html(<span class="thumbs">${map(urls, t -> html(<img src=${t} alt="" loading="lazy" referrerpolicy="no-referrer"/>))}</span>);
	}

	/** Media links in the input: their thumbnails, sent alone they are added to the playlist **/
	function preview():Renderable
		return (links.length == 0) ? nothing : html(<div class="preview">
			${map(links, thumbnail)}
			${playable ? html(<span data-icon="add">send adds to the playlist</span>) : nothing}
		</div>);

	/** Age of a message, e.g. `6m`, the date on hover **/
	static function ago(date:Date) {
		final s = (Date.now().getTime() - date.getTime()) / 1000;
		final text = (s < 60) ? "now" : (s < 3600) ? '${Std.int(s / 60)}m' : (s < 86400) ? '${Std.int(s / 3600)}h' : '${Std.int(s / 86400)}d';
		return html(<time title=${DateTools.format(date, "%Y-%m-%d %H:%M")}>${text}</time>);
	}

	/** Body contains `@` and the nick **/
	public static function mentions(body:String, nick:String)
		return new EReg('@${EReg.escape(nick)}(?![\\w-])', "i").match(body);

	/** Own message, or a notice: the answer to an own command **/
	function own(m:Null<Message>)
		return m != null && (m.nick == "*" || m.nick == muc?.nick);

	function mentionsMe(m:Message)
		return muc != null && m.nick != muc.nick && mentions(m.body, muc.nick);

	/** Nicks in alphabetical order, ignoring case **/
	static function sorted(nicks:Array<String>) {
		final a = nicks.copy();
		a.sort((x, y) -> js.Syntax.code("{0}.localeCompare({1}, undefined, {sensitivity: 'base'})", x, y));
		return a;
	}

	/** Stable color for a nick **/
	/** Saves the playlist as an extended M3U file, playable in VLC and mpv **/
	function exportPlaylist() {
		final lines = ["#EXTM3U", '#PLAYLIST:$room'];
		for (s in Player.schedule(items))
			lines.push('#EXTINF:${Math.round(s.item.duration)},${(s.item.title ?? s.item.url).split("\n").join(" ")}\n${s.item.url}');
		final a = js.Browser.document.createAnchorElement();
		a.href = js.html.URL.createObjectURL(new js.html.Blob([lines.join("\n") + "\n"], {type: "audio/x-mpegurl"}));
		a.download = '${room.split("@")[0]}-${DateTools.format(Date.now(), "%Y-%m-%d")}.m3u';
		a.click();
		js.Browser.window.setTimeout(() -> js.html.URL.revokeObjectURL(a.href), 1000); // after the download started
	}

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
				<button data-icon="download" title="export playlist" aria-label="export playlist" ?disabled=${items.length == 0} @click=${exportPlaylist}></button>
				<button data-icon="settings" title="settings" aria-label="settings" @click=${() -> settings = !settings}></button>
				<button data-icon="leave" title="leave" aria-label="leave" @click=${() -> LOGOUT.dispatch(this)}></button>
			</header>
			<rad-player .items=${items} .offset=${offset}></rad-player>
			<svg class="links" aria-hidden="true"></svg>
			<div class="log">
				${map(groups(messages), g -> presence(g[0])
					? html(<div class="action" style="--hue:${hue(g[0].nick)}"><span><b class="nick">${g[0].nick}</b> ${g[0].body}</span>${ago(g[0].time)}</div>)
					: html(<div class=${g[0].nick == "*" ? "group notice" : g[0].nick == muc?.nick ? "group own" : "group"} style="--hue:${hue(g[0].nick)}">
						<b class="nick">${g[0].nick}</b>
						${map(g, m -> ([m.action ? html(<div class="action playlist" data-items=${(m.items ?? []).join(" ")} @click=${e -> {
							tap(e, m);
							showItem(e, m);
						}}><span>${linkify(m.body)}${itemThumbs(m)}</span>${reactButton(m)}${ago(m.time)}</div>) : html(<p class=${mentionsMe(m) ? "mention" : ""} @click=${e -> tap(e, m)}><span>${styled(m.body)}${mediaLinks(m)}</span>${reactButton(m)}${ago(m.time)}</p>), reactionBar(m)] : Array<Renderable>))}
					</div>))}
			</div>
			<ul class=${people ? "open" : ""}>${map(sorted(occupants), n -> html(<li class=${n == muc?.nick ? "nick me" : "nick"} style="--hue:${hue(n)}">${n}</li>))}</ul>
			${people ? html(<div class="backdrop" @click=${() -> people = false}></div>) : nothing}
			${settings && muc != null ? html(<rad-settings .muc=${muc} @close=${Settings.CLOSE.listen(() -> settings = false)}></rad-settings>) : nothing}
			<form @submit=${submit}>${preview()}${typing.length > 0 ? html(<span class="typing">${typingText(typing)}</span>) : nothing}<textarea rows="1" ?disabled=${busy} placeholder=${busy ? "loading media…" : "..."} @keydown=${onKey} @input=${onInput}></textarea><button data-icon="send" title="send" aria-label="send" ?disabled=${busy}></button></form>
		</div>);
}
