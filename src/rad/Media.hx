package rad;

import js.Browser.document;
import js.Browser.window;
import js.Syntax.code;
import js.html.Element;
import js.lib.Promise;

enum Source {
	File(url:String);
	YouTube(id:String);
	SoundCloud(url:String);
	Mixcloud(path:String);
}

/**
	A media player embedded into a parent element. Times are in seconds.
**/
abstract class Media {
	static final scripts = new Map<String, Promise<Dynamic>>();

	/** Returns the media source of `url`, `null` if not playable **/
	public static function parse(url:String):Null<Source> {
		final u = try new js.html.URL(url) catch (_) return null;
		final path = ~/^\/(shorts|live|embed)\/([\w-]+)/;
		return switch ~/^(www|m|music)\./.replace(u.hostname, "") {
			case "youtube.com" if (u.searchParams.has("v")): YouTube(u.searchParams.get("v"));
			case "youtube.com" if (path.match(u.pathname)): YouTube(path.matched(2));
			case "youtu.be" if (u.pathname.length > 1): YouTube(u.pathname.substr(1));
			case "soundcloud.com": SoundCloud(url);
			case "mixcloud.com": Mixcloud(u.pathname);
			case _ if (~/\.(mp3|ogg|oga|opus|wav|flac|m4a|aac|mp4|m4v|webm|ogv)$/i.match(u.pathname)): File(url);
			case _: null;
		}
	}

	/** Embeds a player for `source` into `parent`, starting at `start` **/
	public static function create(source:Source, parent:Element, start:Float, play = true):Media {
		return switch source {
			case File(url): new FileMedia(parent, url, start, play);
			case YouTube(id): new YouTubeMedia(parent, id, start, play);
			case SoundCloud(url): new SoundCloudMedia(parent, url, start, play);
			case Mixcloud(path): new MixcloudMedia(parent, path, start, play);
		}
	}

	/** Loads `source` in a hidden player to get its duration **/
	public static function probe(source:Source):Promise<Float> {
		final div = document.createDivElement();
		div.style.cssText = "position:fixed;left:-9999px;width:320px;height:180px";
		document.body.append(div);
		final media = create(source, div, 0, false);
		final timeout = new Promise((_, reject) -> window.setTimeout(reject, 15000));
		final done = () -> {
			media.destroy();
			div.remove();
		}
		return Promise.race([media.duration(), timeout]).then(d -> {
			done();
			d;
		}, e -> {
			done();
			Promise.reject(e);
		});
	}

	static function script(src:String, ?ready:(Dynamic->Void)->Void):Promise<Dynamic> {
		if (!scripts.exists(src))
			scripts.set(src, new Promise((resolve, reject) -> {
				final s = document.createScriptElement();
				s.src = src;
				s.onerror = reject;
				if (ready != null) ready(resolve) else s.onload = resolve;
				document.head.append(s);
			}));
		return scripts.get(src);
	}

	/** Calls `get` until it returns a duration **/
	static function poll(get:() -> Promise<Null<Float>>):Promise<Float>
		return get().then(d -> (d != null && d > 0) ? Promise.resolve(d) : new Promise((r, _) -> window.setTimeout(r, 250)).then(_ -> poll(get)));

	static function iframe(parent:Element, src:String) {
		final f = document.createIFrameElement();
		f.setAttribute("allow", "autoplay; encrypted-media");
		f.src = src;
		parent.append(f);
		return f;
	}

	public abstract function duration():Promise<Float>;

	public abstract function position():Promise<Float>;

	public abstract function seek(time:Float):Void;

	public abstract function destroy():Void;
}

class FileMedia extends Media {
	final video = document.createVideoElement();

	public function new(parent:Element, url:String, start:Float, play:Bool) {
		video.src = '$url#t=$start';
		video.controls = true;
		video.preload = "metadata";
		video.autoplay = play;
		parent.append(video);
	}

	function duration()
		return new Promise((resolve, reject) -> {
			if (video.readyState > 0)
				resolve(video.duration);
			video.onloadedmetadata = () -> resolve(video.duration);
			video.onerror = reject;
		});

	function position()
		return Promise.resolve(video.currentTime);

	function seek(time:Float)
		video.currentTime = time;

	function destroy() {
		video.removeAttribute("src");
		video.load();
		video.remove();
	}
}

class YouTubeMedia extends Media {
	final box = document.createDivElement();
	final player:Promise<Dynamic>;
	var fail:Dynamic->Void = _ -> {};

	public function new(parent:Element, id:String, start:Float, play:Bool) {
		final el = document.createDivElement();
		box.append(el);
		parent.append(box);
		player = Media.script("https://www.youtube.com/iframe_api", ready -> (window : Dynamic).onYouTubeIframeAPIReady = ready)
			.then(_ -> new Promise((resolve, _) -> code("new YT.Player({0}, {1})", el, {
				videoId: id,
				playerVars: {autoplay: play ? 1 : 0, start: Std.int(start), playsinline: 1},
				events: {onReady: e -> resolve(e.target), onError: e -> fail(e.data)}
			})));
	}

	function duration()
		return Promise.race([
			player.then(p -> Media.poll(() -> Promise.resolve(p.getDuration()))),
			new Promise((_, reject) -> fail = reject) // e.g. embedding not allowed
		]);

	function position()
		return player.then(p -> (p.getCurrentTime() : Float));

	function seek(time:Float)
		player.then(p -> p.seekTo(time, true));

	function destroy() {
		player.then(p -> p.destroy());
		box.remove();
	}
}

class SoundCloudMedia extends Media {
	final frame:js.html.IFrameElement;
	final widget:Promise<Dynamic>;

	public function new(parent:Element, url:String, start:Float, play:Bool) {
		frame = Media.iframe(parent, 'https://w.soundcloud.com/player/?url=${StringTools.urlEncode(url)}&auto_play=$play&visual=true');
		widget = Media.script("https://w.soundcloud.com/player/api.js").then(_ -> new Promise((resolve, _) -> {
			final w:Dynamic = code("SC.Widget({0})", frame);
			w.bind(code("SC.Widget.Events.READY"), () -> resolve(w));
		}));
	}

	function duration()
		return widget.then(w -> new Promise((resolve, _) -> w.getDuration(ms -> resolve(ms / 1000))));

	function position()
		return widget.then(w -> new Promise((resolve, _) -> w.getPosition(ms -> resolve(ms / 1000))));

	function seek(time:Float)
		widget.then(w -> w.seekTo(time * 1000));

	function destroy()
		frame.remove();
}

class MixcloudMedia extends Media {
	final frame:js.html.IFrameElement;
	final widget:Promise<Dynamic>;

	public function new(parent:Element, path:String, start:Float, play:Bool) {
		frame = Media.iframe(parent,
			'https://player-widget.mixcloud.com/widget/iframe/?hide_cover=1&autoplay=${play ? 1 : 0}&feed=${StringTools.urlEncode(path)}');
		widget = Media.script("https://widget.mixcloud.com/media/js/widgetApi.js").then(_ -> {
			final w:Dynamic = code("Mixcloud.PlayerWidget({0})", frame);
			w.ready.then(_ -> {
				if (play)
					w.play();
				w;
			});
		});
	}

	function duration()
		return widget.then(w -> Media.poll(w.getDuration));

	function position()
		return widget.then(w -> w.getPosition());

	function seek(time:Float)
		widget.then(w -> w.seek(time));

	function destroy()
		frame.remove();
}
