package rad;

import js.Browser.document;
import js.Browser.window;
import js.Syntax.code;
import js.html.Element;
import js.lib.Promise;

enum Source {
	File(url:String);
	YouTube(id:String);
	Vimeo(url:String);
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
			case "vimeo.com" | "player.vimeo.com" if (~/\/\d+/.match(u.pathname)): Vimeo(url);
			case "soundcloud.com": SoundCloud(url);
			case "mixcloud.com": Mixcloud(u.pathname);
			case _ if (~/\.(mp3|ogg|oga|opus|wav|flac|m4a|aac|mp4|m4v|webm|ogv)$/i.match(u.pathname)): File(url);
			case _: null;
		}
	}

	/**
		Embeds a player for `source` into `parent`.
		Once loaded it plays from the position returned by `start`, which is asked only then, as loading takes a while.
		Without `start` it does not play.
	**/
	public static function create(source:Source, parent:Element, ?start:() -> Float):Media {
		return switch source {
			case File(url): new FileMedia(parent, url, start);
			case YouTube(id): new YouTubeMedia(parent, id, start);
			case Vimeo(url): new VimeoMedia(parent, url, start);
			case SoundCloud(url): new SoundCloudMedia(parent, url, start);
			case Mixcloud(path): new MixcloudMedia(parent, path, start);
		}
	}

	/** Loads `source` in a hidden player to get its duration and title **/
	public static function probe(source:Source):Promise<{duration:Float, title:Null<String>}> {
		final div = document.createDivElement();
		div.style.cssText = "position:fixed;left:-9999px;width:320px;height:180px";
		document.body.append(div);
		final media = create(source, div);
		final timeout = new Promise((_, reject) -> window.setTimeout(reject, 15000));
		final done = () -> {
			media.destroy();
			div.remove();
		}
		return Promise.race([media.duration(), timeout]).then(d -> Promise.race([media.title(), new Promise((r, _) -> window.setTimeout(() -> r(null), 3000))])
			.catchError(_ -> null)
			.then(title -> {
				done();
				{duration: d, title: (title == "") ? null : title};
			}), e -> {
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

	/** The title, `null` if unknown **/
	public abstract function title():Promise<Null<String>>;

	public abstract function position():Promise<Float>;

	public abstract function seek(time:Float):Void;

	public abstract function destroy():Void;
}

class FileMedia extends Media {
	final video = document.createVideoElement();

	public function new(parent:Element, url:String, ?start:() -> Float) {
		video.src = url;
		video.controls = true;
		video.preload = "metadata";
		if (start != null)
			video.addEventListener("loadedmetadata", () -> {
				video.currentTime = start();
				video.play().catchError(_ -> {});
			}, {once: true});
		parent.append(video);
	}

	function duration()
		return new Promise((resolve, reject) -> {
			if (video.readyState > 0)
				resolve(video.duration);
			video.onloadedmetadata = () -> resolve(video.duration);
			video.onerror = reject;
		});

	function title()
		return Promise.resolve(StringTools.urlDecode(new js.html.URL(video.src).pathname.split("/").pop()));

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

	public function new(parent:Element, id:String, ?start:() -> Float) {
		final el = document.createDivElement();
		box.append(el);
		parent.append(box);
		player = Media.script("https://www.youtube.com/iframe_api", ready -> (window : Dynamic).onYouTubeIframeAPIReady = ready)
			.then(_ -> new Promise((resolve, _) -> code("new YT.Player({0}, {1})", el, {
				videoId: id,
				playerVars: {playsinline: 1},
				events: {
					onReady: e -> {
						if (start != null) {
							e.target.seekTo(start(), true);
							e.target.playVideo();
						}
						resolve(e.target);
					},
					onError: e -> fail(e.data)
				}
			})));
	}

	function duration()
		return Promise.race([
			player.then(p -> Media.poll(() -> Promise.resolve(p.getDuration()))),
			new Promise((_, reject) -> fail = reject) // e.g. embedding not allowed
		]);

	function title()
		return player.then(p -> (p.getVideoData()?.title : Null<String>));

	function position()
		return player.then(p -> (p.getCurrentTime() : Float));

	function seek(time:Float)
		player.then(p -> p.seekTo(time, true));

	function destroy() {
		player.then(p -> p.destroy());
		box.remove();
	}
}

class VimeoMedia extends Media {
	final box = document.createDivElement();
	final player:Promise<Dynamic>;

	public function new(parent:Element, url:String, ?start:() -> Float) {
		parent.append(box);
		player = Media.script("https://player.vimeo.com/api/player.js").then(_ -> {
			final p:Dynamic = code("new Vimeo.Player({0}, {1})", box, {url: url, playsinline: true});
			p.ready().then(_ -> {
				if (start != null) {
					p.setCurrentTime(start()); // resolves only once playing
					(p.play() : Promise<Dynamic>).catchError(_ -> {}); // e.g. autoplay not allowed
				}
				p;
			});
		});
	}

	function duration()
		return player.then(p -> p.getDuration());

	function title()
		return player.then(p -> p.getVideoTitle());

	function position()
		return player.then(p -> p.getCurrentTime());

	function seek(time:Float)
		player.then(p -> p.setCurrentTime(time));

	function destroy() {
		player.then(p -> p.destroy());
		box.remove();
	}
}

class SoundCloudMedia extends Media {
	final frame:js.html.IFrameElement;
	final widget:Promise<Dynamic>;

	public function new(parent:Element, url:String, ?start:() -> Float) {
		frame = Media.iframe(parent, 'https://w.soundcloud.com/player/?url=${StringTools.urlEncode(url)}&visual=true');
		widget = Media.script("https://w.soundcloud.com/player/api.js").then(_ -> new Promise((resolve, _) -> {
			final w:Dynamic = code("SC.Widget({0})", frame);
			w.bind(code("SC.Widget.Events.READY"), () -> {
				if (start != null) {
					// seeking is ignored before playback started
					w.bind(code("SC.Widget.Events.PLAY"), () -> {
						w.unbind(code("SC.Widget.Events.PLAY"));
						w.seekTo(start() * 1000);
						w.setVolume(100);
					});
					w.setVolume(0); // silent until at the position
					w.play();
				}
				resolve(w);
			});
		}));
	}

	function duration()
		return widget.then(w -> new Promise((resolve, _) -> w.getDuration(ms -> resolve(ms / 1000))));

	function title()
		return widget.then(w -> new Promise((resolve, _) -> w.getCurrentSound(s -> resolve(s?.title))));

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

	final path:String;

	public function new(parent:Element, path:String, ?start:() -> Float) {
		this.path = path;
		frame = Media.iframe(parent, 'https://player-widget.mixcloud.com/widget/iframe/?hide_cover=1&feed=${StringTools.urlEncode(path)}');
		widget = Media.script("https://widget.mixcloud.com/media/js/widgetApi.js").then(_ -> {
			final w:Dynamic = code("Mixcloud.PlayerWidget({0})", frame);
			w.ready.then(_ -> {
				if (start != null) {
					// seeking is ignored before playback started
					function seek() {
						w.events.progress.off(seek);
						w.seek(start());
					}
					w.events.progress.on(seek);
					w.play();
				}
				w;
			});
		});
	}

	function duration()
		return widget.then(w -> Media.poll(w.getDuration));

	function title()
		return window.fetch('https://api.mixcloud.com$path').then(r -> r.json()).then(j -> (j.name : Null<String>));

	function position()
		return widget.then(w -> w.getPosition());

	function seek(time:Float)
		widget.then(w -> w.seek(time));

	function destroy()
		frame.remove();
}
