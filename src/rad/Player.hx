package rad;

import js.Browser.document;
import js.Browser.window;
import lit.Directives.*;
import lit.Lit.*;
import lit.LitElement;

typedef Track = {
	id:String,
	url:String,
	?title:String,

	/** Url of a thumbnail image, https **/
	?thumb:String,

	nick:String,

	/** Length in seconds **/
	duration:Float,

	/** When it was posted, server time in ms **/
	time:Float,

	/** When it was removed, server time in ms **/
	?removed:Float
}

typedef Slot = {item:Track, start:Float, end:Float}

/**
	Plays the playlist in sync with all clients.

	Every client computes the same schedule from the items: each starts when it was posted or when the previous ended, whichever is later.
	A removed item ends when it was removed, items removed before they started are dropped.
**/
@:customElement("rad-player")
class Player extends LitElement {
	@:property({attribute: false}) public var items:Array<Track> = [];

	/** Server time minus local time in ms **/
	@:property({type: Number}) public var offset = 0.0;

	@:query(".screen") var screen:js.html.Element;
	@:query("ol") var list:js.html.Element;

	var current:Null<Track>;

	/** Start of the current item, server time in ms **/
	var start = 0.0;

	var media:Null<Media>;
	var timer = 0;
	var ticks = 0;

	/** Scrolls the list to the end, see `Chat.pinToEnd` **/
	var toEnd:() -> Void = () -> {};

	/** Items when last rendered, the list scrolls to a new one **/
	var count = 0;

	override function createRenderRoot()
		return cast this;

	override function connectedCallback() {
		super.connectedCallback();
		timer = window.setInterval(tick, 1000);
		final size:Dynamic = try haxe.Json.parse(window.localStorage.getItem("rad-size")) catch (_) null;
		if (size != null)
			for (name in Reflect.fields(size))
				document.documentElement.style.setProperty(name, Reflect.field(size, name));
	}

	/**
		Drag the border to resize the player: its width beside the chat, its height above it (mobile).
		The size is set as `--player-width`/`--player-height` on the root element, used by the chat layout.
	**/
	function drag(e:js.html.PointerEvent) {
		final handle:js.html.Element = cast e.currentTarget;
		final vertical = handle.offsetWidth > handle.offsetHeight;
		final name = vertical ? "--player-height" : "--player-width";
		final rect = getBoundingClientRect();
		final clamp = (v:Float, min:Float, max:Float) -> Math.round(Math.max(min, Math.min(v, max)));
		e.preventDefault();
		handle.setPointerCapture(e.pointerId);
		handle.onpointermove = (e:js.html.PointerEvent) -> document.documentElement.style.setProperty(name,
			vertical ? '${clamp(e.clientY - rect.top, 40, window.innerHeight - 200)}px' : '${clamp(e.clientX - rect.left, 160, window.innerWidth - 400)}px');
		handle.onpointerup = _ -> {
			handle.onpointermove = handle.onpointerup = null;
			final size = {};
			for (n in ["--player-width", "--player-height"])
				if (document.documentElement.style.getPropertyValue(n) != "")
					Reflect.setField(size, n, document.documentElement.style.getPropertyValue(n));
			try window.localStorage.setItem("rad-size", haxe.Json.stringify(size)) catch (_) {}
		}
	}

	override function firstUpdated(changed:lit.PropertyValues)
		toEnd = Chat.pinToEnd(list);

	override function updated(changed:lit.PropertyValues) {
		if (items.length > count)
			toEnd();
		count = items.length;
	}

	override function disconnectedCallback() {
		super.disconnectedCallback();
		window.clearInterval(timer);
		media?.destroy();
		media = null;
		current = null;
	}

	public static function schedule(items:Array<Track>):Array<Slot> {
		final sorted = items.copy();
		sorted.sort((a, b) -> Reflect.compare(a.time, b.time));
		final slots = [];
		var end = 0.0;
		for (item in sorted) {
			final start = Math.max(item.time, end);
			end = start + item.duration * 1000;
			if (item.removed != null)
				end = Math.max(start, Math.min(end, item.removed));
			if (end > start)
				slots.push({item: item, start: start, end: end});
			else
				end = start;
		}
		return slots;
	}

	function tick() {
		final now = Date.now().getTime() + offset;
		final playing = Lambda.find(schedule(items), s -> now >= s.start && now < s.end);
		final changed = playing?.item != current;
		if (changed) {
			media?.destroy();
			media = null;
			current = playing?.item;
			final source = (current == null) ? null : Media.parse(current.url);
			if (source != null) // else unknown to this version
				media = Media.create(source, screen, () -> (Date.now().getTime() + offset - playing.start) / 1000);
		} else if (media != null && ++ticks % 5 == 0) {
			media.position().then(pos -> {
				final want = (Date.now().getTime() + offset - playing.start) / 1000;
				if (Math.abs(pos - want) > 1.5)
					media.seek(want);
			});
		}
		if (playing != null)
			start = playing.start; // moves when an item delivered late is scheduled before
		if (changed || current != null)
			requestUpdate(); // also the position, every second
	}

	/** Toggles fullscreen of the screen, the players have no controls for it **/
	function fullscreen()
		if (document.fullscreenElement != null)
			document.exitFullscreen();
		else if (screen.requestFullscreen != null) // not on iPhone
			screen.requestFullscreen();

	static function icon(url:String)
		return switch Media.parse(url) {
			case YouTube(_): "youtube";
			case Vimeo(_): "vimeo";
			case SoundCloud(_): "soundcloud";
			case Mixcloud(_): "cloud";
			case File(url): Media.isAudio(url) ? "music" : "video";
			case null: "music";
		}

	static function format(seconds:Float)
		return '${Std.int(seconds / 60)}:${StringTools.lpad(Std.string(Std.int(seconds % 60)), "0", 2)}';

	override function render()
		return html(<div style="display:contents">
			<div class="screen" @click=${() -> media?.click()} @dblclick=${fullscreen}></div>
			${current == null ? nothing : html(<div class="bar" style="--progress:${elapsed() / current.duration * 100}%">
				${Media.adjustable ? html(<label class="volume" data-icon="volume" title="volume">
					<input type="range" min="0" max="1" step="0.01" aria-label="volume" .value=${Std.string(Media.level)} @input=${(e:js.html.Event) -> media?.volume(Media.level = Std.parseFloat((cast e.target : js.html.InputElement).value))}>
				</label>) : nothing}
				<span class="time">${format(elapsed())} / ${format(current.duration)}</span>
				<button data-icon="skip" title="skip" aria-label="skip" @click=${() -> Chat.SEND.dispatch(this, "/skip")}></button>
			</div>)}
			<div class="split" @pointerdown=${drag}></div>
			<ol>${map(schedule(items), s -> played(s) ? html(<li class="played">${item(s.item, html(<button data-icon="add" title="play again" aria-label="play again" @click=${() -> Chat.SEND.dispatch(this, '/play ${s.item.url}')}></button>))}</li>) : s.item == current ? html(<li class="current">${item(s.item, html(<button data-icon="skip" title="skip" aria-label="skip" @click=${() -> Chat.SEND.dispatch(this, "/skip")}></button>))}</li>) : html(<li>${item(s.item, html(<button data-icon="close" title="remove" aria-label="remove" @click=${() -> removeItem(s.item)}></button>))}</li>))}</ol>
		</div>);

	/** Position in the current item in seconds, the time all clients sync to **/
	function elapsed()
		return Math.max(0, Math.min((Date.now().getTime() + offset - start) / 1000, current.duration));

	/** Removes an upcoming item: `/remove` with its number at the time of the click **/
	function removeItem(t:Track) {
		final i = Lambda.findIndex(schedule(items), s -> s.item.id == t.id);
		if (i >= 0)
			Chat.SEND.dispatch(this, '/remove ${i + 1}');
	}

	function played(s:{item:Track, end:Float})
		return s.end < Date.now().getTime() + offset;

	/** An item, `action`: a button at the end **/
	function item(t:Track, ?action:lit.Renderable)
		return html(<div class="item" data-item=${t.id}>
			${t.thumb != null ? html(<img src=${t.thumb} alt="" loading="lazy" referrerpolicy="no-referrer"/>) : nothing}
			<div>
				<a href=${t.url} target="_blank" data-icon=${icon(t.url)}>${t.title ?? t.url}</a>
				<span class="muted">${format(t.duration)} · <span class="nick" style="--hue:${Chat.hue(t.nick)}">${t.nick}</span> · ${DateTools.format(Date.fromTime(t.time - offset), "%Y-%m-%d %H:%M")}</span>
			</div>
			${action ?? nothing}
		</div>);
}
