# 名前付き table 生成式

## 構文と型

```dua
table A { int x; }
table B { int x; }
alias Choice = A | B;
Choice value = B { x = 1 };
// value is B はtrue、value is Aはfalse
```

`Hoge {...}`、`module.Hoge {...}` は新しい参照型 table を作る式です。
配列・AA・field・引数・戻り値・lambda 本体で使え、通常の postfix `.field` 等も続けられます。
型は module scope の型名として解決します。公開型または公開された単一型 alias を使えます。
単一 alias は基底の table 型へ解決します。union alias、struct、組込み型、未登録型は生成先にできません。
非公開の修飾型と、別モジュールの同名型を同一視しません。

## 初期化

必須 field の不足・型不一致を拒否します。型付き配列・AA field は宣言型へ準備して検査します。
追加 field は既存 table と同じく許可します。field の既定式は追加しません。
キー重複は拒否します。静的キーは parse 時、計算キーと spread の衝突は実行時にも確認します。
値は通常の literal と同じ順に評価し、各式を一度だけ評価します。

## 型同一性と互換

明示生成の型と基底型チェーンを table storage の内部情報として持ちます。
コピー・コンテナ・引数・戻り値・union で保持し、無関係な table 型への構造的な再分類は拒否します。
自型・基底型・それらを指す alias/union と、汎用 table/any は受理します。
`setmetatableWithType` によってこの同一性を偽装することもできません。

既存の無名 `{...}` と `cast(Hoge) {...}` は従来の構造検査のままです。
既存 cast から新構文を内部的に呼び出す実装ではありません。
新構文の値を無関係な型へ cast しても同一性を消しません。
新しい値として意図的に作り直す場合は `Other { ...value }` を使えます。
通常の `{ ...value }` は従来どおりメタ情報のない別 table です。

これは field を immutable にする変更ではありません。通常の table の変更規則は維持します。
JSON、toScriptLiteral、table.keys/length に内部の同一性情報は混ぜません。
JSON 等はデータだけを保存し、型同一性の永続化／復元は行いません。

## 共有解析 API v1 の追加情報

- `modules[].typeConstructions`: `type`, `displayType`, `sourceName`, `line`, `column`, `endLine`, `endColumn`。
  行列は既存と同じ1始まりUTF-8、終端は exclusive。型 ID は既存の types/alternatives をたどれます。
- `exports[].nominalValue`: 初期値が直接の名前付き生成式である公開値を示します。
- `types[].baseTypes`: table の型 spread の基底型 ID。
- 既存 `types[].fields/alternatives/定義位置` はそのまま利用できます。新情報の利用は任意です。

静的検査は、分かる生成先・field・不足・型同一性を検査します。
計算キー・spread の実内容や、既存の動的な呼出し・lambda の解析限界は実行時検査に残ります。
未登録ホスト型の全体像を推測して完全な証明をする機能ではありません。

## 検証

`tests/named_tables.d` と `tests/named_tables_cases.json` は独立した限定実行用です。
作業用ディレクトリでケース JSON を引数に指定して実行します。現在のケース数は34、
typeCheck=false/true の計68条件です。別途共有解析 API の型 ID・範囲と7種の診断境界を確認しています。
通常 import 等の既存境界12群も回帰確認しました。
製品 release は既存の全ソース修正を保った原本から LDC で再ビルドし、旧 exe を保存して配置します。

## 共通metaの指定

table Name with meta の最上位宣言は、Name { ... } の生成時に共通metaを内部に保持します。フィールド既定式は追加しません。詳細は [2つのwith](with-ja.md) を参照してください。

