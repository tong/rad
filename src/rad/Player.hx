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

	var current:Null<Track>;
	var media:Null<Media>;
	var timer = 0;
	var ticks = 0;

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
		if (playing?.item != current) {
			media?.destroy();
			media = null;
			current = playing?.item;
			if (playing != null)
				media = Media.create(Media.parse(current.url), screen, () -> (Date.now().getTime() + offset - playing.start) / 1000);
			requestUpdate();
		} else if (media != null && ++ticks % 5 == 0) {
			media.position().then(pos -> {
				final want = (Date.now().getTime() + offset - playing.start) / 1000;
				if (Math.abs(pos - want) > 1.5)
					media.seek(want);
			});
		}
	}

	static function icon(url:String)
		return switch Media.parse(url) {
			case YouTube(_) | Vimeo(_): "video";
			case SoundCloud(_) | Mixcloud(_): "cloud";
			case _: "music";
		}

	static function format(seconds:Float)
		return '${Std.int(seconds / 60)}:${StringTools.lpad(Std.string(Std.int(seconds % 60)), "0", 2)}';

	override function render()
		return html(<div style="display:contents">
			<div class="screen"></div>
			<div class="split" @pointerdown=${drag}></div>
			<ol>${map(schedule(items), s -> html(<li class=${classMap({current: s.item == current, played: s.end < Date.now().getTime() + offset})}>
					<a href=${s.item.url} target="_blank" data-icon=${icon(s.item.url)}>${s.item.title ?? s.item.url}</a>
					<span class="muted">${format(s.item.duration)} · <span class="nick" style="--hue:${Chat.hue(s.item.nick)}">${s.item.nick}</span> · ${DateTools.format(Date.fromTime(s.item.time - offset), "%Y-%m-%d %H:%M")}</span>
				</li>))}</ol>
		</div>);
}
