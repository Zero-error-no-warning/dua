# table の既定 nullable と明示的な非 nullable

## 正式構文

```dua
table Item { int count; }
Item optional = null;
alias RequiredItem = Item & !null;
RequiredItem item = Item { count = 1 };
Item & !null direct = Item { count = 2 };
```

`T & !null` は T から null のみを除く型。一般の交差型・補集合は導入しない。
`Table!`、`Table?` は未対応。既存の `cast!(string)` は変更しない。

型の括弧を使用できる。`T[] & !null` は配列全体への指定、
`(T & !null)[]` は非 null 要素の配列。AA の非 null 値は `(T & !null)[string]`。
`alias Required=T & !null; Required[]` でも同じ意味。

union は従来どおり alias で定義する。`alias U=A & !null | B;` は A 側のみ、
`alias U=A|B; alias RequiredU=U & !null;` は union 全体から null を除く。
`(A | B)` という一般の型式は追加していない。`alias Optional=A & !null | null;` は null を許す。
関数型は `int delegate(int) & !null` のように指定できる。

## 型と null

| 型 | 既定の null |
|---|---|
| Dua の宣言済み `table Name`、組込み `table` | 許可 |
| D の登録済み class | 従来どおり許可 |
| Dua の配列/AA | 既定で許可。詳細は nullable-arrays.md |
| Dua/D の struct、数値、bool、string、function/delegate | 従来どおり不許可 |
| `any`/`auto`/`null`/`void` | 従来の規則 |
| alias/union | 別名先／候補の規則。table 候補があれば null を受け取る |
| `T & !null` | T の種類によらず null を拒否。元が非 nullable なら冗長な指定 |

table 型の変数の宣言は引き続き初期値が必要。`Item value;` も `Item & !null value;` も未対応。
nullable にすることと自動生成・省略初期化は別。`Item value = null;` と書く。

型付き宣言・引数・戻り値・cast の境界で検査する。非 nullable 制約は
変数や引数の再代入、配列/AAの要素にも残す。

```dua
Item maybe = Item { count = 3 };
Item & !null required = cast(Item & !null) maybe;
```

checker は `is` 分岐によるフロー型絞り込みを導入しない。nullable と宣言した値から
非 nullable へは明示 cast を要求する。cast はその時点の値を確認してから返す。
`any`、動的取得値等は実行時検査へ残す。共有可変状態の将来の値を証明する仕組みではない。

既知の型付き配列/AAリテラル（入れ子、field、引数、戻り値を含む）の null 要素は静的にも診断する。
計算されたコンテナや spread/any の内容は実行時へ残す。組込み int 等は hostClassTypes の同名登録より優先する。
非 nullable 要素を持つ配列が union の候補でも、共有配列の変更時の検査を維持する。

`value is Item` は生存する table 実体の型判定のまま。`null is Item` は偽。
null を判別するときは `value == null` を使う。明示 null 候補を持つ union の `is` は従来どおり。

## table field と共有参照

```dua
table Owner { Item child; RequiredItem required; }
auto owner = Owner { child = null, required = Item { count = 1 } };
```

nullable field も initializer 内の指定は必須。`Owner { required = ... }` は child 不足のエラー。
nullable 化を理由に不足 field を自動的に null で補完しない。

明示非 nullable を含む field は、通常の `.field`、`["field"]`、`rawset` に制約を残す。
共有 alias からの書き込みでも同じ table ストレージにある検査を通す。
typed export 値の公開スナップショットへの書き込みにも非 nullable 制約を残す。
export を live 変数参照へ変更するものではない。

これは任意の table を不変にする機能ではない。通常 field 全体の恒久的な構造封印や
フロー型安全性は追加しない。D ホストが `Value.tableValue` を直接操作する経路は
スクリプト代入の検査外であり、そのようなホスト操作までの保証ではない。

## エラーと互換性

null の `.field`／`.method()`／field 代入は、対象名を含む
`Cannot access/call/assign member ... on null` のスクリプト位置付きエラーになる。
null を受け取る関数自体は呼べるが、null への UFCS/メンバー形式の呼び出しはできない。

既存の `alias Maybe=T|null` は有効なまま。table については通常は冗長となる。
従来 null 拒否に依存した table 注釈・union は `& !null` で移行する。
`table|null` と table 以外の Optional は既存の alias 文法で指定する。
named constructor、明示型の union 同一性、必須 field、UFCS のメンバー優先を維持する。

## 解析 API v1

wrapper の型文字列は `(<underlyingType> & !null)`。内部型は従来の opaque table ID／alias ID を保持。
専用 opaque wrapper ID や、新しい type descriptor は追加しない。
fields/parameterTypes/exports.type/alias alternatives のどこでも同じ式表現。
shape/宣言位置は wrapper を外し、従来の modules[].types と alternatives を辿る。
displayType は ID を人間向けの公開型名へ戻した括弧付き正式表記。
配列は `(<ID> & !null)[]`、配列全体は `(<ID>[] & !null)`。

## 確認範囲

独立 LDC O0 debug プローブで、初期化、再代入、引数/戻り値、qualified/alias/union、
field、rawset、共有 alias、struct field copy、配列/AA、class/value 型、null エラー、
named constructor と UFCS を限定確認。既存の全 unittest や全 GUI 操作を実行したという意味ではない。

初回102条件と統合時の追加20条件が成功（計122条件）。checker/API は30条件成功。
