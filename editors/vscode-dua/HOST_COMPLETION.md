# Host completion catalogs

The extension reads `.dua-completion.json` from the workspace root. Other relative paths can be specified with `dua.completion.metadataFiles`. No executable, host function, getter, import, or user script is run by completion.

An embedding host can enable declaration collection before registering its API:

```d
import dua;
import std.json;
auto engine = new Dua.ScriptEngine();
engine.enableCompletionMetadata(true); // metadata-only bindType: no static getters
engine.bindFunc!loadActor("loadActor");
engine.bindType!Vector("Vector");
auto json = engine.completionRegistry.toJson();
```

The host writes the JSON to its project. Collection is opt-in and disabled for normal engines. `bindFunc`, `bindAuto`, and `bindType` retain the names actually registered by the host. Overloads include parameter names/types, optional/variadic markers, and return types. Public reflected members are described without constructing instances. Private fields, private methods, unsupported reflection members, and bridge-only `__` symbols are excluded. Dynamic `bindNative` callbacks appear by name; their argument and return types are unknown.

`enableCompletionMetadata(true)` is for an isolated exporter engine, not script execution. Metadata-only type tables are placeholders. Collection cannot make arbitrary host registration code safe: a host must only call its trusted registration routine, never project startup code or user scripts.

Schema version 1 uses:

```json
{
  "schemaVersion": 1,
  "origin": "Example host API",
  "symbols": {
    "loadActor": {
      "kind": "function",
      "signatures": [{"parameters": [{"name": "path", "type": "string"}], "returnType": "Actor"}]
    },
    "Vector": {"kind": "type", "type": "Vector"}
  },
  "types": {
    "Actor": {"members": {"position": {"kind": "property", "type": "Vector"}}},
    "Vector": {"members": {"x": {"kind": "property", "type": "double"}}}
  }
}
```

Module/static members use dotted symbol keys. Instance members are under `types`. The extension follows straightforward local declarations, assignments, aliases, function return types and property chains. Unknown expressions invalidate inferred values. This is conservative token analysis, not a full type checker; arbitrary flow, script-defined functions, and overload resolution are not implemented. Existing language completion remains available without a catalog. Use `Ctrl+Space` to request candidates.

From 0.4.4, a type descriptor may also contain `kind: "class"`, `"struct"`, `"union"` or `"aggregate"`. This is an additive field in schema version 1. The exporter derives it from the D declaration, without invoking getters. The bundled checker receives only explicitly declared class names and public type aliases in a JSON request (`--request-json`, `protocolVersion: 1`, `source`, `hostClassTypes`). It uses the same static checker as the runtime and never loads imports, constructs host objects or runs scripts. Value types do not acquire nullable semantics.

Older catalogs remain usable for completion. Missing/unknown type kinds do not grant null compatibility; regenerate with the updated exporter to clear nullable-reference false positives. Catalogs written again by an older host also need regeneration. `dua.checkerPath` overrides retain their original source-only stdin protocol, so an older custom checker continues to work but cannot consume the catalog's class metadata.

Nested `members` descriptors are retained as well. Version 0.4.3 can complete an enum reached through a module type alias, such as `ui.Font.Type.`, directly from the host's declared members. Regenerate the entire host catalog after an API migration; do not merge symbols from an obsolete catalog into the new one.

## Asset string arguments and scene context

Hosts may add the following generic arrays. No host-specific API or scene-format names are built into the extension.

```json
{
  "assets": [{"path":"hero.asset", "type":"Actor", "size":100, "modifiedMs":1790000000000,
    "names":{"motions":["Walk"], "parts":["Arm"]}}],
  "stringArguments": [{"receiverType":"Actor", "method":"morph", "argument":0, "source":"motions"}],
  "assetLoaders": [{"function":"loadActor", "returnType":"Actor", "pathArguments":[1], "pathWrappers":["resource"]}],
  "contexts": [{"script":"actor.dua", "assetDirectory":".",
    "sources":[{"path":"level.scene", "size":200, "modifiedMs":1790000000000}],
    "bindings":{"self":{"type":"Actor", "assets":["hero.asset"]},
      "scenes.Player":{"type":"Actor", "assets":["hero.asset"]}}}]
}
```

Paths are relative to the workspace root; `modifiedMs` is integer Unix milliseconds. Source size/time are checked on every request. Optional SHA-256 digests are cached by path/size/mtime/ctime/inode, with a second stamp check after reading; unchanged files are not read repeatedly. The first validation still reads the file synchronously. Missing, moved or changed assets/scene contexts are ignored until regeneration. JSON is cached by its own file stamp. An atomic host rewrite or deletion is picked up on the next request. Regeneration must enumerate current files, so deleted paths do not accumulate.

Literal loader calls, direct aliases and matching script contexts narrow asset candidates. Listed wrappers resolve relative to the scene directory; plain literals resolve relative to the project root. Dynamic paths show project candidates with their source and uncertainty. Shared script contexts show the union and mark multiple candidates. Runtime data flow is not evaluated. Only a configured direct string argument receives names; nested calls, comments and interpolated strings do not inherit outer suggestions. Dua string contents are raw, so insertion preserves backslashes and replaces the string content. Names containing a quote or newline cannot be inserted as one Dua literal and are omitted. Typed parameters and uninitialized declarations shadow outer asset bindings, including array types.
