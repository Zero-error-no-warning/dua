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
