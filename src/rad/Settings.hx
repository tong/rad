package rad;

import js.html.Event;
import js.html.FormData;
import js.html.FormElement;
import lit.Directives.*;
import lit.EventType;
import lit.Lit.*;
import lit.LitElement;
import xmpp.DataForm;
import xmpp.Muc;
import xmpp.Response;
import xmpp.XML;

/**
	Settings of the room: the own nick, the subject (moderators) and the room configuration (owners).
**/
@:customElement("rad-settings")
class Settings extends LitElement {
	public static final CLOSE = new EventType<Void>("close");

	/** [XEP-0045: Owner Use Cases](https://xmpp.org/extensions/xep-0045.html#owner) **/
	static inline var XMLNS_OWNER = "http://jabber.org/protocol/muc#owner";

	@:property({attribute: false}) public var muc:Muc;

	/** Room configuration form, owners only **/
	@:state var config:Null<DataForm>;

	/** Result of the last change **/
	@:state var status:Null<String>;

	override function createRenderRoot()
		return cast this;

	override function connectedCallback() {
		super.connectedCallback();
		if (muc.affiliation == owner)
			muc.stream.get(query(), room(), (res:Response<XML>) -> switch res {
				case Result(payload):
					final x = payload?.elements.first(e -> e.name == "x" && e.is(DataForm.XMLNS));
					if (x != null)
						config = x;
				case Error(e):
					status = 'Could not load the room configuration: ${e.condition}';
			});
	}

	inline function room()
		return '${muc.room}@${muc.host}';

	static function query()
		return XML.create("query").set("xmlns", XMLNS_OWNER);

	static function data(e:Event):FormData {
		e.preventDefault();
		return new FormData(cast(e.target, FormElement));
	}

	function changeNick(e:Event) {
		final nick = StringTools.trim(data(e).get("nick"));
		if (nick != "" && nick != muc.nick)
			muc.changeNick(nick, e -> status = (e == null) ? 'Nick changed to $nick' : 'Could not change the nick: ${e.condition}');
	}

	function changeSubject(e:Event) {
		muc.changeSubject(data(e).get("subject"));
		status = "Subject changed";
	}

	function configure(e:Event) {
		final d = data(e);
		final values = new Map<String, Array<String>>();
		for (f in config.fields)
			if (f.variable != null)
				switch DataForm.fieldType(f) {
					case FieldType.hidden | fixed: // qualified, `hidden` is also a field of the element
					case boolean: values.set(f.variable, [d.has(f.variable) ? "1" : "0"]);
					case list_multi: values.set(f.variable, [for (v in d.getAll(f.variable)) (v : String)]);
					case text_multi | jid_multi: values.set(f.variable, [for (l in (d.get(f.variable) : String).split("\n")) if (StringTools.trim(l) != "") StringTools.trim(l)]);
					case _: values.set(f.variable, [d.get(f.variable)]);
				}
		muc.stream.set(query().append(config.createSubmit(values)), room(), (res:Response<XML>) -> status = switch res {
			case Result(_): "Room configuration saved";
			case Error(e): 'Could not save the room configuration: ${e.condition}';
		});
	}

	static function field(f:Field) {
		final values = f.values ?? [];
		final label = f.label ?? f.variable;
		final options = (f.options ?? []).map(o -> html(<option value=${o.value} ?selected=${values.contains(o.value)}>${o.label ?? o.value}</option>));
		return switch DataForm.fieldType(f) {
			case hidden: nothing;
			case fixed: html(<p>${values.join(" ")}</p>);
			case boolean: html(<label class="check"><input type="checkbox" name=${f.variable} ?checked=${values[0] == "1" || values[0] == "true"}> ${label}</label>);
			case list_single: html(<label>${label} <select name=${f.variable}>${options}</select></label>);
			case list_multi: html(<label>${label} <select name=${f.variable} multiple>${options}</select></label>);
			case text_multi | jid_multi: html(<label>${label} <textarea name=${f.variable} rows="3" .value=${values.join("\n")}></textarea></label>);
			case text_private: html(<label>${label} <input type="password" name=${f.variable} .value=${values[0] ?? ""}></label>);
			case _: html(<label>${label} <input name=${f.variable} .value=${values[0] ?? ""}></label>);
		}
	}

	override function render()
		return html(<div style="display:contents">
			<header>
				<h2>settings</h2>
				<button data-icon="close" title="close" aria-label="close" @click=${() -> CLOSE.dispatch(this)}></button>
			</header>
			${status != null ? html(<p class="status">${status}</p>) : nothing}
			<label class="check"><input type="checkbox" .checked=${Chat.shareTyping} @change=${(e:Event) -> Chat.shareTyping = (cast e.target : js.html.InputElement).checked}> show others when I'm typing</label>
			<form @submit=${changeNick}>
				<label>nick <input name="nick" maxlength="16" required .value=${muc.nick}></label>
				<button>save</button>
			</form>
			${muc.role == moderator ? html(<form @submit=${changeSubject}>
				<label>subject <input name="subject" .value=${muc.subject ?? ""}></label>
				<button>save</button>
			</form>) : nothing}
			${muc.affiliation != owner ? nothing : config == null ? html(<p>loading the room configuration…</p>) : html(<form @submit=${configure}>
				<h3>${config.title ?? "room configuration"}</h3>
				${map(config.instructions, i -> html(<p>${i}</p>))}
				${map(config.fields, field)}
				<button>save</button>
			</form>)}
		</div>);
}
