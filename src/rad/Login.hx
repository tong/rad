package rad;

import js.Browser.window;
import js.html.Event;
import js.html.FormElement;
import lit.EventType;
import lit.Lit.*;
import lit.LitElement;

typedef Account = {
	jid:String,
	password:String,
	websocket:String,
	room:String,
	nick:String
}

/**
	Site configuration, set as attributes of `<rad-app>`.
	A configured value is used as is and its login field is hidden.
**/
typedef Config = {
	/** XMPP domain, users only enter their name **/
	?domain:String,

	/** WebSocket endpoint, default is `wss://<domain>/xmpp-websocket` **/
	?websocket:String,

	/** Room to join **/
	?room:String,

	/** MUC service, users only enter the room name **/
	?conference:String
}

@:customElement("rad-login")
class Login extends LitElement {
	public static final LOGIN = new EventType<Account>("login");

	@:property({type: Boolean}) public var busy = false;
	@:property public var error:Null<String>;
	@:property({attribute: false}) public var config:Config = {};

	/** Last used account (without password) **/
	final saved:Dynamic = try haxe.Json.parse(window.localStorage.getItem("rad")) catch (_) null;

	override function createRenderRoot()
		return cast this;

	final onHash:() -> Void = () -> requestUpdate(); // link pasted into an open rad tab, no reload

	override function connectedCallback() {
		super.connectedCallback();
		window.addEventListener("hashchange", onHash);
	}

	override function disconnectedCallback() {
		super.disconnectedCallback();
		window.removeEventListener("hashchange", onHash);
	}

	function submit(e:Event) {
		e.preventDefault();
		final f:Dynamic = Object.fromEntries(new js.html.FormData(cast(e.target, FormElement)).entries());
		final jid:String = (config.domain != null && f.jid.indexOf("@") == -1) ? '${f.jid}@${config.domain}' : f.jid;
		final room:String = config.room ?? ((config.conference != null && f.room.indexOf("@") == -1) ? '${f.room}@${config.conference}' : f.room);
		final a:Account = {
			jid: jid,
			password: f.password,
			room: room,
			nick: (f.nick != "") ? f.nick : jid.substr(0, Std.int(Math.min(jid.indexOf("@"), 16))),
			websocket: config.websocket ?? ((f.websocket ?? "") != "" ? f.websocket : 'wss://${jid.substr(jid.indexOf("@") + 1)}/xmpp-websocket')
		};
		Reflect.deleteField(f, "password");
		try window.localStorage.setItem("rad", haxe.Json.stringify(f)) catch (_) {}
		LOGIN.dispatch(this, a);
	}

	/** Saved value, the room of a shared link (`#room@conference.example.com`) first **/
	function value(key:String):String {
		final hash = StringTools.urlDecode(window.location.hash.substr(1));
		if (key == "room" && hash != "")
			return hash;
		return (saved != null) ? Reflect.field(saved, key) ?? "" : "";
	}

	override function render()
		return html(<form @submit=${submit}>
			${config.domain != null
				? html(<label>user <input name="jid" placeholder=${'name @${config.domain}'} required autocomplete="username" .value=${value("jid")}></label>)
				: html(<label>jid <input name="jid" type="email" placeholder="user@example.com" required autocomplete="username" .value=${value("jid")}></label>)}
			<label>password <input name="password" type="password" required autocomplete="current-password"></label>
			${config.room != null ? nothing : config.conference != null
				? html(<label>room <input name="room" placeholder=${'name @${config.conference}'} required .value=${value("room")}></label>)
				: html(<label>room <input name="room" type="email" placeholder="room@conference.example.com" required .value=${value("room")}></label>)}
			<label>nick <input name="nick" placeholder="optional" maxlength="16" .value=${value("nick")}></label>
			${config.websocket != null ? nothing : html(<label>websocket <input name="websocket" placeholder="wss://example.com/xmpp-websocket (optional)" .value=${value("websocket")}></label>)}
			<button data-icon="join" ?disabled=${busy}>${busy ? "connecting…" : "join"}</button>
			${error != null ? html(<p class="error">${error}</p>) : nothing}
		</form>);
}

@:native("Object") private extern class Object {
	static function fromEntries(entries:Dynamic):Dynamic;
}
