package rad;

import js.html.Event;
import js.html.InputElement;
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
	time:Date
}

@:customElement("rad-chat")
class Chat extends LitElement {
	public static final SEND = new EventType<String>("send");
	public static final LOGOUT = new EventType<Void>("logout");

	@:property public var room = "";
	@:property public var nick = "";
	@:property public var subject = "";
	@:property({attribute: false}) public var messages:Array<Message> = [];
	@:property({attribute: false}) public var occupants:Array<String> = [];
	@:property({attribute: false}) public var items:Array<rad.Player.Track> = [];
	@:property({attribute: false}) public var offset = 0.0;

	@:query(".log") var log:js.html.Element;
	@:query("form input") var input:InputElement;

	override function createRenderRoot()
		return cast this;

	override function updated(changed:PropertyValues)
		if (changed.has("messages"))
			log.scrollTop = log.scrollHeight;

	function submit(e:Event) {
		e.preventDefault();
		final body = StringTools.trim(input.value);
		if (body != "")
			SEND.dispatch(this, body);
		input.value = "";
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

	/** Stable color for a nick **/
	static function hue(nick:String) {
		var h = 0;
		for (i in 0...nick.length)
			h = (h * 31 + nick.charCodeAt(i)) % 360;
		return h;
	}

	override function render()
		return html(<div style="display:contents">
			<header>
				<h1>${room}</h1>
				<span class="subject">${subject}</span>
				<span class="nick" style="--hue:${hue(nick)}">${nick}</span>
				<button @click=${() -> LOGOUT.dispatch(this)}>leave</button>
			</header>
			<rad-player .items=${items} .offset=${offset}></rad-player>
			<div class="log">
				${map(messages, m -> html(<p class=${m.nick == "*" ? "notice" : ""}>
					<time>${DateTools.format(m.time, "%H:%M")}</time><b class="nick" style="--hue:${hue(m.nick)}">${m.nick}</b><span>${linkify(m.body)}</span>
				</p>))}
			</div>
			<ul>${map(occupants, n -> html(<li class="nick" style="--hue:${hue(n)}">${n}</li>))}</ul>
			<form @submit=${submit}><input placeholder="message · /play <url> · /skip · /remove <n>" autofocus><button>send</button></form>
		</div>);
}
