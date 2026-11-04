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
		final path = ~/^\/(shorts|live|embed)\/([\w-]+)/, short = ~/^\/([\w-]+)/;
		return switch ~/^(www|m|music)\./.replace(u.hostname, "") {
			case "youtube.com" if (u.searchParams.has("v")): YouTube(u.searchParams.get("v"));
			case "youtube.com" if (path.match(u.pathname)): YouTube(path.matched(2));
			case "youtu.be" if (short.match(u.pathname)): YouTube(short.matched(1));
			case "vimeo.com" | "player.vimeo.com" if (~/\/\d+/.match(u.pathname)): Vimeo(url);
			case "soundcloud.com": SoundCloud(url);
			case "mixcloud.com": Mixcloud(u.pathname);
			case _ if (~/\.(mp3|ogg|oga|opus|wav|flac|m4a|aac|mp4|m4v|webm|ogv|mov|mkv)$/i.match(u.pathname)): File(url); // mov, mkv: depends on the browser and codecs
			case _: null;
		}
	}

	/** The media file at `url` is audio, played with a visualizer **/
	public static function isAudio(url:String):Bool
		return ~/\.(mp3|ogg|oga|opus|wav|flac|m4a|aac)$/i.match(new js.html.URL(url, document.baseURI).pathname);

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

	/** Url of a thumbnail image of `source`, `null` if none **/
	public static function thumbnail(source:Source):Promise<Null<String>> {
		function json(url:String):Promise<Dynamic>
			return window.fetch(url).then(r -> r.json());
		return switch source {
			case YouTube(id): Promise.resolve('https://i.ytimg.com/vi/$id/mqdefault.jpg');
			case Vimeo(url): json('https://vimeo.com/api/oembed.json?width=320&url=${StringTools.urlEncode(url)}').then(j -> j.thumbnail_url);
			case SoundCloud(url): json('https://soundcloud.com/oembed?format=json&url=${StringTools.urlEncode(url)}').then(j -> j.thumbnail_url);
			case Mixcloud(path): json('https://api.mixcloud.com$path').then(j -> j.pictures?.medium);
			case File(_): Promise.resolve(null);
		}
	}

	static function script(src:String, ?ready:(Dynamic->Void)->Void):Promise<Dynamic> {
		if (!scripts.exists(src))
			scripts.set(src, new Promise((resolve, reject) -> {
				final s = document.createScriptElement();
				s.src = src;
				s.onerror = e -> {
					scripts.remove(src); // loaded again on the next try, e.g. once online
					s.remove();
					reject(e);
				}
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

	/** A click on the screen, the players get no pointer events: starts a blocked autoplay **/
	public abstract function click():Void;

	/** Sets the volume, 0…1 **/
	public abstract function volume(v:Float):Void;

	/** Volume of all media, 0…1, kept in the browser **/
	public static var level(default, set):Float = try {
		final v = Std.parseFloat(window.localStorage.getItem("rad-volume"));
		Math.isNaN(v) ? 1 : v;
	} catch (_) 1;

	static function set_level(v:Float) {
		try window.localStorage.setItem("rad-volume", Std.string(v)) catch (_) {}
		return level = v;
	}

	/** `false` where pages can't set the volume (iOS: the device buttons only) **/
	public static final adjustable = {
		final a = document.createAudioElement();
		a.volume = .5;
		a.volume == .5;
	}
}

class FileMedia extends Media {
	final video:js.html.MediaElement;

	/** Audio only: frequency bars above the controls **/
	final box = document.createDivElement();

	final canvas = document.createCanvasElement();
	var context:Null<js.html.audio.AudioContext>;

	/** Volume while the audio goes through the analyser **/
	var gain:Null<js.html.audio.GainNode>;
	var frame = 0;

	/** Waveform instead of the frequency bars, toggled by a click **/
	var wave = false;

	/** Rejects `duration` **/
	var fail:Dynamic->Void = _ -> {};

	public function new(parent:Element, url:String, ?start:() -> Float) {
		final audio = Media.isAudio(url);
		video = audio ? document.createAudioElement() : document.createVideoElement();
		video.controls = false; // playback follows the room
		video.preload = "metadata";
		video.volume = Media.level;
		video.onerror = () -> if (video.crossOrigin != null) {
			// no CORS headers: load again without, the analyser would only output silence so isn't used, the bars stay empty
			video.removeAttribute("crossorigin");
			video.src = url;
		} else fail(video.error);
		if (audio) {
			video.crossOrigin = "anonymous"; // the analyser needs the samples
			video.addEventListener("play", analyse);
			box.className = "audio";
			box.append(canvas, video);
			parent.append(box);
		} else
			parent.append(video);
		video.src = url;
		if (start != null)
			video.addEventListener("loadedmetadata", () -> {
				video.currentTime = start();
				video.play().catchError(_ -> {});
			}, {once: true});
	}

	/** Routes the audio through an analyser, on the first play **/
	function analyse() {
		if (context != null || video.crossOrigin == null) {
			context?.resume();
			return;
		}
		context = new js.html.audio.AudioContext();
		final analyser = context.createAnalyser();
		analyser.fftSize = 256;
		analyser.smoothingTimeConstant = .8;
		gain = context.createGain();
		gain.gain.value = video.volume;
		video.volume = 1; // the gain sets it, the analyser gets the full signal
		context.createMediaElementSource(video).connect(analyser);
		analyser.connect(gain);
		gain.connect(context.destination);
		final bins = new js.lib.Uint8Array(analyser.fftSize); // frequencies use the first half
		final g = canvas.getContext2d();
		function draw(_) {
			frame = window.requestAnimationFrame(draw);
			final w = canvas.width = Std.int(canvas.clientWidth * window.devicePixelRatio);
			final h = canvas.height = Std.int(canvas.clientHeight * window.devicePixelRatio);
			final color = window.getComputedStyle(canvas).getPropertyValue("--accent");
			if (wave) {
				analyser.getByteTimeDomainData(bins);
				g.strokeStyle = color;
				g.lineWidth = 2 * window.devicePixelRatio;
				g.beginPath();
				for (i in 0...bins.length)
					g.lineTo(i / (bins.length - 1) * w, bins[i] / 255 * h);
				g.stroke();
			} else {
				analyser.getByteFrequencyData(bins);
				g.fillStyle = color;
				final n = Std.int(analyser.frequencyBinCount * .75); // the top bins are mostly empty
				final bar = w / n;
				for (i in 0...n) {
					final v = bins[i] / 255 * h;
					g.fillRect(i * bar, h - v, Math.max(1, bar - 1), v);
				}
			}
		}
		draw(0);
	}

	function duration()
		return new Promise((resolve, reject) -> {
			fail = reject;
			if (video.readyState > 0)
				resolve(video.duration);
			else
				video.addEventListener("loadedmetadata", () -> resolve(video.duration), {once: true});
		});

	function title()
		return Promise.resolve(StringTools.urlDecode(new js.html.URL(video.src).pathname.split("/").pop()));

	function position()
		return Promise.resolve(video.currentTime);

	function seek(time:Float)
		video.currentTime = time;

	function click()
		if (video.paused)
			video.play().catchError(_ -> {});
		else if (canvas.isConnected)
			wave = !wave;

	function volume(v:Float)
		if (gain != null) gain.gain.value = v else video.volume = v;

	function destroy() {
		video.onerror = null;
		window.cancelAnimationFrame(frame);
		context?.close();
		video.removeAttribute("src");
		video.load();
		box.remove();
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
				// no controls, keyboard, fullscreen button or annotations, related videos from the same channel only
				// the title and logo on hover can't be turned off: the iframe gets no pointer events
				playerVars: {playsinline: 1, controls: 0, disablekb: 1, fs: 0, iv_load_policy: 3, rel: 0},
				events: {
					onReady: e -> {
						e.target.setVolume(Media.level * 100);
						if (start != null) {
							e.target.seekTo(start(), true);
							e.target.playVideo();
						}
						resolve(e.target);
					},
					onError: e -> fail(e.data),
					// no captions: no option turns them off, unloading the module is undocumented, it loads with the playback
					onApiChange: e -> try e.target.unloadModule("captions") catch (_) {}
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

	function volume(v:Float)
		player.then(p -> p.setVolume(v * 100));

	function click()
		player.then(p -> p.playVideo());

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
			final p:Dynamic = code("new Vimeo.Player({0}, {1})", box, {
				url: url,
				playsinline: true,
				controls: false,
				title: false,
				byline: false,
				portrait: false
			});
			p.ready().then(_ -> {
				p.setVolume(Media.level);
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

	function volume(v:Float)
		player.then(p -> p.setVolume(v));

	function click()
		player.then(p -> (p.play() : Promise<Dynamic>).catchError(_ -> {}));

	function destroy() {
		player.then(p -> p.destroy());
		box.remove();
	}
}

class SoundCloudMedia extends Media {
	final frame:js.html.IFrameElement;
	final widget:Promise<Dynamic>;

	public function new(parent:Element, url:String, ?start:() -> Float) {
		frame = Media.iframe(parent, 'https://w.soundcloud.com/player/?url=${StringTools.urlEncode(url)}&visual=true&buying=false&sharing=false&download=false&show_comments=false&show_playcount=false&show_user=false&hide_related=true&show_teaser=false');
		widget = Media.script("https://w.soundcloud.com/player/api.js").then(_ -> new Promise((resolve, _) -> {
			final w:Dynamic = code("SC.Widget({0})", frame);
			w.bind(code("SC.Widget.Events.READY"), () -> {
				if (start != null) {
					// seeking is ignored before playback started
					w.bind(code("SC.Widget.Events.PLAY"), () -> {
						w.unbind(code("SC.Widget.Events.PLAY"));
						w.seekTo(start() * 1000);
						w.setVolume(Media.level * 100);
					});
					w.setVolume(0); // silent until at the position
					w.play();
				} else
					w.setVolume(Media.level * 100);
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

	function volume(v:Float)
		widget.then(w -> w.setVolume(v * 100));

	function click()
		widget.then(w -> w.play());

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
		frame.style.height = "120px"; // the widget's own height, below it the frame is white
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

	/** The show from the api: `name`, `audio_length` **/
	var info:Null<Promise<Dynamic>>;

	function show():Promise<Dynamic>
		return info ??= window.fetch('https://api.mixcloud.com$path').then(r -> r.json());

	// From the api: on phones the widget knows the duration only once playing
	function duration()
		return show().then(j -> (j.audio_length : Null<Float>) > 0 ? Promise.resolve((j.audio_length : Float)) : Promise.reject(null))
			.catchError(_ -> widget.then(w -> Media.poll(w.getDuration)));

	function title()
		return show().then(j -> (j.name : Null<String>));

	function position()
		return widget.then(w -> w.getPosition());

	function seek(time:Float)
		widget.then(w -> w.seek(time));

	function volume(v:Float) {} // not in the widget api

	function click()
		widget.then(w -> w.play());

	function destroy()
		frame.remove();
}
