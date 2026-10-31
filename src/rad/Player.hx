package rad;

import js.Browser.window;
import lit.Directives.*;
import lit.Lit.*;
import lit.LitElement;

typedef Track = {
	id:String,
	url:String,
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
				media = Media.create(Media.parse(current.url), screen, (now - playing.start) / 1000);
			requestUpdate();
		} else if (media != null && ++ticks % 5 == 0) {
			media.position().then(pos -> {
				final want = (Date.now().getTime() + offset - playing.start) / 1000;
				if (Math.abs(pos - want) > 1.5)
					media.seek(want);
			});
		}
	}

	static function format(seconds:Float)
		return '${Std.int(seconds / 60)}:${StringTools.lpad(Std.string(Std.int(seconds % 60)), "0", 2)}';

	override function render()
		return html(<div style="display:contents">
			<div class="screen"></div>
			<ol>${map(schedule(items), s -> html(<li class=${classMap({current: s.item == current, played: s.end < Date.now().getTime() + offset})}>
					<a href=${s.item.url} target="_blank">${s.item.url}</a>
					<span class="muted">${format(s.item.duration)} · ${s.item.nick}</span>
				</li>))}</ol>
		</div>);
}
