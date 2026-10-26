## 0.6.6

- Support contiguous trailing script default arguments, evaluated only when omitted at call time.
- Preserve definition/instance context, argument validation and imported optional-parameter completion.
- Keep the 0.6.5 Vec3 operator inference correction and existing native D defaults.

## 0.6.5

- Fix false numeric assignment diagnostics for overloaded host/aggregate binary operators.
- Preserve scalar inference and typed-array concatenation checks; defer unknown operator return types.

## 0.6.4

- Support shared metatables on top-level table/struct with declarations.
- Support lexical with(target) expressions and leading-dot member completion/diagnostics without outer-name fallback.
- Refresh the shared checker while preserving existing named types, module contexts, nullable containers and UFCS.

## 0.6.3

- Refresh the checker for nullable array/AA handles, preserving explicit nonnull container and element constraints.
- Accept direct nullable array/AA declarations with omitted initialization, and retain imported element completion across nullable handles.
- Document D-like handle assignment and null/empty content comparison without extending generic null/table behavior.

## 0.6.2

- Refresh the checker for nullable table types and restricted `T & !null` type annotations.
- Preserve null-exclusion wrappers and opaque base identities while completing declarations, parameters, returns, fields, arrays and imported aliases.
- Keep primitive/struct/host diagnostics, named tables, UFCS and import behavior; do not introduce postfix `T!` or general intersection syntax.

## 0.6.1

- Refresh the checker for UFCS calls without parentheses.
- Align completion expression inference with member priority and known arity; preserve module/global function values and explicit calls.
- Infer UFCS results only for known scalar/array receivers. Keep dynamic table/host members and unknown arity conservative.
- Preserve named tables, module search contexts, host/null diagnostics and import behavior.

## 0.6.0

- Complete named table types and initializer fields using the shared analysis type descriptors, including imported qualified types.
- Keep typed construction results through member completion and explicitly typed union arrays; preserve opaque module type IDs.
- Support unfinished initializer input through completion-only projections, and jump from constructor type names to their shared declaration locations.
- Highlight named construction targets while preserving existing import, host context and class/null behavior.

## 0.5.1

- Base default named-import patterns on validated scene/session catalog contexts, preserving explicitly configured workspace patterns.
- Preserve native module bindings and known scene member types; treat partial host export lists as unknown rather than absent.
- Keep precise errors for known types and sealed source modules, host class/null behavior, and existing import features.
- Avoid asserting a single fixed signature for optional or overloaded host functions; shared scripts retain only analysis results confirmed across their runtime contexts.

## 0.5.0

- Use the shared non-executing Dua import service for quoted relative paths, imported public values/types and definitions.
- Preserve module type identities, private type boundaries and target-file UTF-8/UTF-16 positions.
- Send open-buffer overlays and invalidate stale results on dependency edits, moves and deletes.
- Retain host class metadata and the legacy custom-checker input protocol.

## 0.4.4

- Pass declared host class types from generated catalogs to the bundled static checker, allowing nullable host references without executing host code.
- Keep null errors for value types, primitives, unknown types and source-defined tables; do not infer class semantics from old catalog entries.
- Preserve the source-only protocol for custom checkers and catalogs without the optional type-kind metadata.

## 0.4.3

- Preserve nested enum metadata when completing module aliases such as `ui.Font.Type.` from generated host catalogs.
- Refresh the bundled checker from Dua `8a16731d4eed0eddc0ee7bc0558a07a272c34b4c`; retain literal aliases and array trailing commas.
- ZsD UI APIs remain in host-generated catalogs rather than extension source.

## 0.4.2

- Refresh the bundled checker to accept trailing commas in array literals while rejecting missing elements.

## 0.4.1

- Refresh the bundled checker with string literal aliases and union constraints from Dua PR #59.
- Accept declarations such as `alias Fruit = "Apple" | "Orange";` and diagnose incompatible literal values.

## 0.4.0

- Receive structured ZsD scene runtime/load errors through an asynchronous JSON inbox.
- Show source-matched locations in Problems; route unknown/stale locations to Output.
- Keep scene/run ownership, clear stale results on edits and lifecycle events, and preserve other diagnostic collections.

# Changelog

## 0.3.0

- ホストの公開登録から生成した JSON による API・型・メンバー補完を追加
- 型付き戻り値・単純な変数の別名・プロパティを経由する補完に対応
- ホスト定義の文字列引数・アセット名・シーン文脈による補完と出典表示を追加
- 削除・移動・変更されたアセットの古い候補を除外

## 0.2.0

- キーワード・型・標準関数・ファイル内の宣言名の入力補完を追加
- 標準ライブラリのメンバー補完と10種類のスニペットを追加
- Dua本体を使う構文・型診断とWindows x64用の診断ツールを追加
- ネストしたコメント・補間式のハイライトと、不完全な文字列の次行への影響を修正

## 0.1.0

- Duaの構文ハイライト、コメント操作、括弧補完、折りたたみを追加
