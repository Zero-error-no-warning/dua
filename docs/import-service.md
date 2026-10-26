# Dua import service v1 — extension contract

Implementation root: the enclosing Dua package (`source/dua/`).
The extension JavaScript is owned by the other task and is not edited here.

## Transport

`tools/vscode-check/main.d` accepts one JSON request on stdin and writes one JSON
response to stdout. Existing raw-source input remains supported.

Build the service from the Dua package root with
`dub build --config=vscode-check --compiler=ldc2 --build=release`.
The executable is `editors/vscode-dua/bin/dua-check.exe` within that package.
The original Dua repository's extension source is maintained separately.

```json
{
  "protocolVersion": 1,
  "operation": "analyze",
  "sourceName": "C:/project/scenes/script/inventory.dua",
  "source": "import \"../common/itemTypes.dua\" as commonTypes;",
  "modulePaths": ["C:/project/?.dua", "C:/project/?/init.dua"],
  "hostClassTypes": ["ListView", "LightCanvas"],
  "hostModules": [{"name":"ui", "exports":[{"name":"ListView", "kind":"type", "type":"ListView"}]}],
  "overlays": [{"sourceName":"C:/project/scenes/common/itemTypes.dua", "source":"export alias ItemKind = int | string;"}],
  "importPathPrefix": "../common/"
}
```

`sourceName` is the saved file path, not the active process directory. `modulePaths`
contains the same `?` patterns as `package.path`, in priority order. Overlays replace
disk text for analysis only and can describe unsaved new files. The source request
itself wins over an overlay for the entry file. Host class names preserve the 0.4.4
class/null diagnostic path. Custom script loaders and host functions are never
executed during analysis.

`hostModules` supplies registered native modules from the existing host catalog;
each export uses `name`, `kind`, `type`, and optional `parameterTypes`. No JS source
module resolution is needed. Module names alone may be declared with `exports:[]`.
Do not flatten source-module type exports into `hostClassTypes`.

Host module export lists are partial by default. Optional
`hostModules[].exportsComplete:true` explicitly asserts that the list is complete
for this analysis context. Omitted/false means an unlisted member is unknown,
not proven absent, so it is treated as `any`. Known members keep their type checks.
Optional export `runtimeValue:false` marks a pure type even in a partial host
module, and using it as a value is still diagnosed. Source module privacy is
checked against its source declarations and is not weakened by this host default.

ZsD integration: take the matching catalog `contexts[].assetDirectory` relative
to the catalog root as the scene/session directory. Supply that directory's
`?.dua` and `?/init.dua` patterns through `modulePaths`; do not substitute the
workspace root. Named imports keep the session search base across dependencies,
whereas quoted relative imports use each importing file's directory. For example,
`sceneItem/script/inventoryUI.dua` in the `sceneItem` context resolves
`script.inventoryData` to `sceneItem/script/inventoryData.dua`.
`scenes` is populated dynamically by the session, so its metadata is partial;
catalog scene bindings may add known members but do not prove other names absent.

The response has `schemaVersion:1`, `diagnostics`, `modules`, `imports`, `exports`,
and `pathCompletions`. Each module carries `key`, `sourceName`, and `sourceText`.
Each module also returns `exportsComplete`; false means omitted members cannot be
diagnosed as absent. This covers partial host modules and computed legacy exports.
Imports carry `request`, `aliasName`, `pathImport`, `key`, `sourceName`, and the
import statement's 1-based UTF-8 `line`/`column`. Exports carry `name`, `kind`
(`variable`, `function`, `type`), stable `type` ID, `alternatives` for aliases,
`parameterTypes` and `variadic` for functions, and definition `sourceName`/`line`/`column`.
`displayType` is a human-readable annotation; `runtimeValue` distinguishes a pure
type alias from a native/struct type that also has a runtime constructor value.
Each module also has a `types` array with opaque IDs, `declarationKind`
(`alias`/`table`/`struct`), `fields`, `alternatives`, and `exported`. Private
descriptors are provided to follow an exported alias's underlying shape; only
`exports` may populate external module member completion. Private simple names
must not be offered to importers.
`dynamicExports:true` means a legacy module can compute its returned export table.
Analysis does not evaluate that table, so unknown members remain `any`; the service
does not invent a completion list for them. Explicit exports still provide precise
public metadata.
Diagnostics carry their own `sourceName`, `sourceText`, `line`, `column`, `message`.
The extension must convert positions against that file's returned source snapshot.
Path candidates carry `label`, `sourceName`, `key`, and `directory`; they come from
the service, not an independent extension resolver.

The service is stateless per request. The extension may use returned module keys
as dependency identities and its existing request generation/cancellation logic.
An overlay edit/rename/delete invalidates importing documents; no independent
resolution cache or fallback search should be introduced in JavaScript.

## Syntax and semantics

- `import "./itemTypes.dua";` binds `itemTypes`.
- `import "../common/itemTypes.dua" as commonTypes;` binds `commonTypes`.
- `import package.module;` preserves registered/host modules and existing package
  search order. Files use normalized absolute identities (case-insensitive on
  Windows). Different names resolving to one file initialize that file once.
- Cyclic source imports are rejected with the dependency path. Missing imports
  report the importer, request, and candidate paths.
- `export alias ItemKind = int | string;` publishes a type. Consumers use
  `commonTypes.ItemKind`; private type names are module-scoped. Type IDs must not
  be flattened to global simple names in hostCompletion.js.
- `export ItemKind selected = 1;` publishes a value independently of the type.
- Value aliases (`alias shortName = imported.value;`) are not part of this change.

## Files

- `source/dua/module_resolver.d`: canonical filesystem resolution.
- `source/dua/module_analysis.d`: non-executing import graph, exported declarations,
  qualified type binding, cycle diagnostics.
- `source/dua/parser.d`, `ast.d`: quoted import/export alias/qualified type syntax.
- `source/dua/module_system.d`, `runtime.d`, `typecheck.d`: shared resolver and
  analysis integration, module type scope and runtime cache.
- `tools/vscode-check/main.d`: JSON transport and legacy-input compatibility.

## Value alias consultation (not implemented)

`alias hoge = test.hoge;` does not create a variable alias. With the new qualified
type grammar it refers to an exported type and rejects a value-only export.
`auto hoge = test.hoge;` copies the retrieved Value through `Environment.define` /
`Value.valueCopy`: scalars are independent, structs are value copies, table/array/
class references can share their target. Replacing `test.hoge` does not retarget
`hoge`. A true variable alias needs a checked read/write forwarding slot, with
module-lifetime handling; it adds indirection and is not inherently faster than a
local cached value. Keep it distinct from type aliases (e.g. explicit `ref` binding)
and define rebinding/assignment semantics before implementation.


## Named table construction additions

See [named-table-expressions.md](named-table-expressions.md) for type identity rules and the optional `typeConstructions`, `nominalValue`, and `baseTypes` response fields. Protocol version remains 1.
