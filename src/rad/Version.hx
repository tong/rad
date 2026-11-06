package rad;

/**
	The version of rad, from `package.json`.
**/
class Version {
	/** Reads the `version` field at compile time, the build runs in the project folder **/
	public static macro function get():haxe.macro.Expr {
		final file = "package.json";
		haxe.macro.Context.registerModuleDependency("rad.Version", file); // compilation server: recompiled when it changes
		return macro $v{(haxe.Json.parse(sys.io.File.getContent(file)).version : String)};
	}
}
