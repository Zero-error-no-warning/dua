# Dua 言語リファレンス（日本語）

このページは、スクリプト記述者向けの簡易リファレンスです。

## 0. 字句とコメント

```D
# 行末までのコメント
// この形式も行末までのコメント
/+ ネストできる
   ブロックコメント /+内側+/ +/
```

- 識別子は英字または `_` で始まり、以降に英数字と `_` を使用できます。
- 数値リテラルは 10 進整数または小数です（例: `42`, `3.14`）。小数点の後には数字が必要です。
- 文は原則として `;` で終わります。

## 1. 変数と関数

`auto` による型推論と基本型を明示した宣言を利用できます。

```D
auto inferred = 1;
int count = 10;
double ratio = 1.5;
bool enabled = true;
string name = "Dua";

int add(int left, int right) {
    return left + right;
}

int apply(int value, int delegate(int) transform) {
    return transform(value);
}

auto doubled = (int value) => value * 2;
auto callback = () :> performSideEffect();
```

- `int` は64bit符号付き整数です。
- 型付き変数と関数の引数・戻り値は実行時に検査されます。
- `auto` と明示型の宣言は初期値が必須です。
- `ReturnType delegate(ArgumentTypes)` でクロージャの型を表します。
- `(typedArgs) => expression` は式の値を返し、`:>` は値を明示的に破棄します。

```D
auto hp = 100;

any add(any a, any b) {
    return a + b;
}

auto inc = (any x) {
    return x + 1;
};

auto inc2 = (any x) => x + 1;
auto add = (any x, any y) => x + y;
auto sink = (any x) :> x + 1;  # 評価するが返り値は返さない
```

- 変数宣言: `auto`
- 関数宣言: `any name(any args) { ... }`
- 無名関数: `(any args) { ... }`
- 無名関数（短縮）: `(any x) => expr` / `(any x, any y) => expr`
- 無名関数（戻り値なし短縮）: `(any x) :> expr` / `(any x, any y) :> expr`

## 2. 制御構文

```D
if (hp > 0) {
    hp = hp - 1;
} else {
    hp = 0;
}

while (hp > 0) {
    hp = hp - 10;
}

for (auto i = 0; i < 3; i = i + 1) {
    # loop
}
```

- `if / else`
- `while`
- `for`
- `foreach`
- `switch / case / default`
- `break / continue`

## 3. 値型

- 数値（整数/浮動小数）
- 文字列
- 真偽値
- 配列
- テーブル
- 関数
- `null`

## 4. 配列・テーブル

```D
auto arr = [1, 2, 3];
auto user = { name = "alice", level = 3 };

user.level = user.level + 1;
auto name = user.name;
auto first = arr[0];
```

配列とテーブルは参照型です。代入は同じ値を共有し、独立した浅いコピーが必要な場合は
spread構文を使用します。

```D
auto arrayCopy = [...arr];
auto userCopy = { ...user, level = 4 };
```

- `[...array]` は配列要素を新しい配列へ展開します。
- `{...table}` は通常のテーブル要素を新しいテーブルへ展開します。
- 複数のspreadと通常要素を混在でき、後に書いたテーブル要素が優先されます。
- コピーは浅く、ネストした配列・テーブルの参照は共有されます。
- メタテーブルと実行時型情報はspreadされません。

### 4.1 名前付きテーブル型とUnion

`alias` で型式に名前を付けます。テーブル型は必要なフィールドを検査し、
余分なフィールドは許可します。

```D
alias BaseObject = {
    string name;
};

alias Player = {
    ...BaseObject;
    int hp;
};

alias GameObject = Player | Enemy | Friend;
alias OptionalPlayer = Player | null;

Player player = { name = "hero", hp = 100 };
OptionalPlayer selected = null;
```

- 型内の `...BaseType;` は基底テーブル型のフィールドと実行時型チェーンを取り込みます。
- 基底型間または派生型での同名フィールドは、型が同じでもエラーです。
- `A | B` はUnion型、`T | null` はOptional型として使用できます。
- 名前付きテーブルの型チェーンは `typeinfo(value).chain` から取得できます。
- `value is Type` で名前付き型と基底型を判定できます。
- `setmetatableWithType` で作成した従来のテーブルも、型付き代入時にフィールド検査されます。

## 5. 演算子

```D
auto a = 1 + 2 * 3;
auto ok = (a > 3) && (a < 10);
auto s = "du" ~ "a";
auto msg = i"HP:$(a), ok=$(ok)";
```

- 算術: `+ - * / %`
- 比較: `== != < <= > >=`
- 論理: `&& || !`
- 連結: `~`
- ビット: `& | ^ << >>`

### 5.1 文字列補間（Interpolation Expression Sequence）

`i"..."` 形式で、`$(式)` を文字列の中に埋め込めます。

```D
auto name = "Dua";
auto lv = 7;
auto text = i"Hello $(name)! Lv.$(lv)";
```

- `$(expr)`: 単一式の補間
- `$(expr1, expr2, ...)`: 式列を左から順に評価して連結
- `$$`: リテラルの `$` を出力

## 6. エラーハンドリング

スクリプト内では `try` / `catch` 文で実行時エラーを処理できます。

```D
try {
    riskyOperation();
} catch (err) {
    print(err.kind ~ ": " ~ err.message);
}
```

`catch` 変数は次のフィールドを持つテーブルです。

- `kind`: `RuntimeError` または明示的な `error(...)` の `ScriptError`
- `message`: エラーメッセージ
- `value`: `error(value)` に渡した元の値。通常の実行時エラーでは `null`
- `stack`: 関数呼び出しスタックの配列

```D
try {
    error({ kind = "InvalidAmount", amount = -1 });
} catch (err) {
    print(err.value.kind);
}
```

`return` / `break` / `continue` / `yield` はエラーではないため `catch` されません。
`RunOptions` のステップ数・呼び出し深度超過も、安全制御のため `catch` で無効化できません。
`finally` と `try` 式は現在は提供しません。

ホストアプリ側では `runSafe` / `loadSafe` を利用すると、
実行失敗時に `RunOutcome` から `errorMessage` と `stackTrace` を取得できます。

## 7. 関数型ヘルパー

`map` / `filter` は配列とテーブルに対して利用できます。

```D
auto doubled = map([1, 2, 3, 4], (any x) => x * 2);    # [2, 4, 6, 8]
auto even = filter([1, 2, 3, 4], (any x) => x % 2 == 0); # [2, 4]

auto tbl = { a = 1, b = 2, c = 3 };
auto kept = table.filter(tbl, (any v, any k) => v >= 2);  # { b = 2, c = 3 }
```

## 8. モジュール（import / export）

```D
# module source
export auto base = 10;
export any add(any x) {
    return x + base;
}

# consumer
import combat.rules as rules;
auto value = rules.add(5);
```

- `export auto` / `export ReturnType name(...)` で公開対象を定義
- `export name;` で既存シンボルを公開
- `import module.path as alias;` でモジュールを読み込み

## 9. 現時点の設計範囲

Dua は組み込み用途を優先した小さな言語です。型注釈と事前検査は任意で、
動的な値は `any` と実行時境界検査で扱えます。クラス構文、`async` / `await`、
`finally` は現在提供しません。大きな機能は D 側で実装し、必要最小限の API だけを
バインドする方針を推奨します。

`auto` と型付き関数へ構文を統一したため、旧 `let` / `fn` 構文は受理しません。
