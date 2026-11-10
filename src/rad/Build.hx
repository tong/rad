package rad;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
#end

/**
	Values set at compile time, the build runs in the project folder.
**/
class Build {
	/** The version, from `package.json` **/
	public static macro function version():Expr
		return macro $v{(read("package.json").version : String)};

	/**
		The configuration of the target, from `targets/<target>/config.json`, see `Login.Config`.
		The target is set with `-D rad-target=<name>`, else it is `example`.
	**/
	public static macro function config():Expr {
		final target = Context.definedValue("rad-target") ?? "example";
		return macro($v{read('targets/$target/config.json')} : rad.Login.Config); // unknown fields are errors
	}

	#if macro
	static function read(file:String):Dynamic {
		Context.registerModuleDependency("rad.Build", file); // compilation server: recompiled when it changes
		return haxe.Json.parse(sys.io.File.getContent(file));
	}
	#end
}
