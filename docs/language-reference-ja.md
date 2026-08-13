# Dua 言語リファレンス

この文書は Dua スクリプトの入門と検索用リファレンスを兼ねます。D から実行する方法は[入門ガイド](public-guide-ja.md)、ホスト API は[埋め込み API リファレンス](embedding-api-ja.md)を参照してください。

## 1. 字句規則

### 1.1 コメント、識別子、リテラル

```D
# 行コメント
// 行コメント
/+ ネスト可能な /+ ブロック +/ コメント +/

auto count = 42;
auto ratio = 3.14;
auto title = "Dua";
auto enabled = true;
auto empty = null;
```

- 識別子は英字または `_` で始まり、続きには英数字と `_` を使えます。
- 数値は10進整数か小数です。負数はリテラルではなく単項 `-` を適用した式です。
- 文字列はダブルクォートで1行に記述します。現在、文字列リテラル内のエスケープシーケンスは提供しません。
- 文は原則 `;` で終わり、ブロックは `{ ... }` で囲みます。
- キーワードは `auto delegate alias is try catch return if else while for foreach switch case default break continue yield true false null this import export as` です。`int` などの型名、`any`、`void` は構文上は識別子として型位置に現れます。

### 1.2 値の種類と真偽

実行時の値は `null`、整数、浮動小数、真偽値、文字列、配列、テーブル、関数、native 値です。条件式では `null`、`false`、数値の `0`、空文字列が偽です。配列・テーブル・関数など、それ以外の値は真として扱われます。

## 2. 変数、代入、スコープ

```D
auto inferred = 1;
int lives = 3;
double rate = 0.5;
bool active = true;
string name = "Ada";
any dynamic = [1, 2];

auto first, second = [10, 20]; # 配列の要素を各変数へ分配
first = first + 1;
first, second = [second, first];
```

- `auto name = expr;` は値から型を推論します。
- `Type name = expr;` は代入時に型を検査します。組み込み型は `int`、`double`、`bool`、`string`、`any`、`void` です。
- 宣言には初期値が必須です。未宣言変数への代入はエラーです。
- ブロックと関数は外側を参照できるレキシカルスコープを作り、ラムダは外側の変数をキャプチャします。
- `auto a, b = array;` と `a, b = array;` は、右辺の配列要素を左辺へ順番に割り当てる分配代入です。関数が複数の戻り値を持つ機能ではありません。要素が足りない左辺には `null` が入ります。

## 3. 関数とラムダ

```D
int add(int left, int right) {
    return left + right;
}

any join(any head, any tail...) { # 最後の引数へ残りを配列で格納
    return head ~ tail[0];
}

auto twice = (int value) => value * 2;
auto block = (any value) {
    return value + 1;
};
auto sink = (any value) :> rawset({}, "value", value);
```

- 宣言は `ReturnType name(Type parameter, ...) { ... }` です。
- 可変長引数は最後の引数名に `...` を付け、残りの引数を配列として受け取ります。
- `(typedArgs) => expression` は式を返すラムダです。
- `(typedArgs) :> expression` は式を評価して結果を捨てる `void` ラムダです。値を返すラムダではありません。
- ブロック形式の関数は明示的な `return` がなければ `null` を返します。単なる最後の式は暗黙 return になりません。
- `ReturnType delegate(ArgumentTypes)` は関数型です（例: `int delegate(int)`）。引数・戻り値は呼び出し時に検査されます。
- テーブル上の関数を `object.method(...)` と呼ぶと、関数本体の `this` はそのテーブルになります。

## 4. 制御構文

```D
if (score >= 80) {
    rank = "A";
} else {
    rank = "B";
}

while (count > 0) {
    count = count - 1;
}

for (auto i = 0; i < 3; i = i + 1) {
    if (i == 1) { continue; }
}

foreach (index, value; [10, 20]) {
    if (value == 20) { break; }
}

switch (rank) {
case "A":
    score = score + 10;
    break;
default:
    score = 0;
}
```

- `foreach (value; collection)` は値だけ、`foreach (key, value; collection)` は配列の添字またはテーブルのキーと値を受け取ります。
- `break` / `continue` はループで使用します。`switch` の分岐を終えるときも `break` を使用できます。
- 三項演算子 `condition ? whenTrue : whenFalse` も利用できます。

## 5. 配列、スライス、テーブル

```D
auto values = [10, 20, 30];
auto indices = iota(10);   # [0, 1, ..., 9]
auto section = iota(5, 9); # [5, 6, 7, 8]
auto odds = iota(1, 8, 2); # [1, 3, 5, 7]
auto first = values[0];
auto tail = values[1 .. $]; # $ は対象の長さ

auto key = "name";
auto user = {
    [key] = "Ada", # 計算キー
    hp = 100,       # 名前付きキー
    7, 8,           # 暗黙の数値キー 0, 1
};
user.hp = user.hp - 1;
```

配列とテーブルは参照型なので、通常の代入は同じ内容を共有します。spread は新しいコンテナを作る浅いコピーです。

```D
auto arrayCopy = [...values, 40];
auto tableCopy = { ...user, hp = 50 };
```

- spread は複数個を通常要素と混在できます。テーブルは後の要素が同じキーを上書きします。
- ネストした配列・テーブルの参照は共有されます。
- テーブルのメタテーブルと実行時型情報は spread されません。
- テーブルの列挙順序に依存しないでください。

## 6. 型、alias、Union

```D
alias Named = {
    string name;
};
alias Player = {
    ...Named;
    int hp;
};
alias Target = Player | Enemy;
alias MaybePlayer = Player | null;

Player hero = { name = "Ada", hp = 100 };
if (hero is Named) {
    hero.hp = hero.hp - 1;
}
```

- 名前付きテーブル型は宣言したフィールドを要求しますが、余分なフィールドは許可します。
- 型内の `...BaseType;` は基底型のフィールドと型チェーンを取り込みます。
- 基底型同士または派生型との同名フィールドは、同じ型でもエラーです。
- `A | B` は Union、`T | null` は Optional 型として使えます。
- `value is Type` は名前付き型とその基底型を判定します。
- `typeinfo(value)` / `typeof(value)` は `{ kind, chain }` を返します。`chain` は名前付き型の継承チェーンです。
- 事前型検査は保守的です。`any`、動的プロパティ、ネイティブ関数の結果などは実行時検査に残ります。

## 7. 演算子と優先順位

強いものから概ね次の順です。

1. 呼び出し、プロパティ、添字、スライス: `()`、`.`、`[]`、`[..]`
2. 単項: `!`、`-`
3. 乗除余: `* / %`
4. 加減・連結: `+ - ~`
5. シフト: `<< >>`
6. 比較と型判定: `< <= > >=`、`is`
7. 等価: `== !=`
8. ビット: `&`、`^`、`|`
9. 論理: `&&`、`||`
10. 三項: `?:`

`&&` と `||` は短絡評価します。算術は数値、`~` は文字列表現の連結です。テーブルには次の特殊キーを置いて動作を拡張できます。

| キー | 用途 |
|---|---|
| `opUnary-`, `opUnary!` | 単項演算。第1引数は自分自身 |
| `opBinary+`, `opBinary-`, `opBinary*`, `opBinary/`, `opBinary%`, `opBinary~` | 二項演算。自分自身と右辺を受け取る |
| `__index`, `__newindex` | 未定義キーの取得・設定 |
| `__call` | テーブルの関数呼び出し |
| `__len` | `length` / `len` |

メタテーブルは `setmetatable(table, meta)` で設定し、`getmetatable(table)` で取得します。`rawget` / `rawset` はメタ処理を経由しません。

## 8. 文字列補間

```D
auto name = "Dua";
auto level = 7;
auto text = i"Hello $(name), Lv.$(level)";
auto dollar = i"$$$(level)"; # $7
```

- `$(expr)` は式の文字列表現を挿入します。
- `$(expr1, expr2)` は式列を左から評価し、それぞれを連結します。
- `$$` はリテラルの `$` です。

## 9. エラー処理

```D
try {
    error({ kind = "InvalidAmount", amount = -1 });
} catch (err) {
    return err.kind ~ ":" ~ err.value.kind;
}
```

`catch` の値は次のフィールドを持つテーブルです。

| フィールド | 内容 |
|---|---|
| `kind` | 通常の実行時失敗は `RuntimeError`、`error(...)` は `ScriptError` |
| `message` | エラーメッセージ |
| `value` | `error(value)` の元の値。通常の実行時失敗は `null` |
| `stack` | 関数呼び出しスタックの配列 |

`return` / `break` / `continue` / `yield` は捕捉しません。ステップ数・呼び出し深度の超過も安全制御を迂回できないよう捕捉しません。`finally` と try 式はありません。

`pcall(function, args...)` は `[成功bool, 値またはメッセージ]`、`xpcall(function, handler, args...)` は失敗メッセージを handler で変換した同形式の配列を返します。配列の分配代入と組み合わせられます。

## 10. コルーチン

```D
auto co = coroutine.create((any start) {
    yield start;
    return start + 1;
});
auto ok1, first = coroutine.resume(co, 5);
auto ok2, last = coroutine.resume(co);
auto state = coroutine.status(co); # "dead"
```

- `yield expr;` は実行を中断して値を返します。コルーチン外では使えません。
- `coroutine.create(fn)`、`resume(co, ...)`、`status(co)`、`running()`、`isyieldable()`、`wrap(fn)` を提供します。
- `resume` は `[成功bool, 値]` 形式です。`wrap` は成功フラグを外し、失敗時にエラーにします。

## 11. モジュール

```D
# game/rules.dua
export auto base = 10;
export int add(int value) { return value + base; }

# 利用側
import game.rules as rules;
return rules.add(5);
```

- `export` はモジュールソース内だけで使えます。宣言に付けるほか、`export existingName;` で既存値を公開できます。
- import のモジュール名は `game.rules` または `"game.rules"`、別名は `as alias` で指定します。
- `require("game.rules")` は同じキャッシュ機構からモジュール値を返します。
- export が1つ以上あれば export テーブルがモジュール値です。export がなければトップレベルの実行結果を返します。

## 12. 標準関数・ライブラリ一覧

| 名前 | 概要 |
|---|---|
| `error(value[, level])` | スクリプトエラーを送出 |
| `typeof(value)`, `typeinfo(value)` | `{ kind, chain }` を返す |
| `length(value)`, `len(value)` | 文字列、配列、テーブル等の長さ |
| `iota(end)`, `iota(start,end[,step])` | 終了値を含まない整数配列を生成。負の step で降順 |
| `rawget(table,key)`, `rawset(table,key,value)` | 生のテーブルアクセス |
| `setmetatable`, `getmetatable`, `setmetatableWithType` | メタ・型チェーン設定 |
| `pcall`, `xpcall` | 保護呼び出し |
| `map`, `filter` | 配列またはテーブルの変換・選別 |
| `string.len/upper/lower/trim/contains/replace` | 文字列操作 |
| `math.abs/floor/min/max` | 数値操作 |
| `table.len/length/keys/map/filter` | テーブル操作 |
| `utf8.len` | Unicode code point 数 |
| `io.exists/readFile` | ファイル確認・読み込み |
| `os.clock/getenv`, `time.nowUnix` | 時刻・環境変数 |
| `debug.type/traceback` | 値種別・現在のスタック |
| `json.encode` | Dua のスクリプトリテラル表現へ変換（汎用 JSON serializer ではない） |
| `_ENV(name)` | グローバル値を名前で取得 |

`map` / `filter` の callback は、0引数なら引数なし、1引数なら値、2引数以上なら値とキー（または添字）を受け取ります。`table.keys` の順序は未規定です。

モジュール用には `require`、`addModulePath`、`setModuleLoaders`、`addModuleLoader` と、`package.require/addPath/addLoader/clearLoaders/loaded` を提供します。`package.path` は検索パターン配列です。

## 13. 現在提供しないもの

Dua は組み込み用途を優先します。クラス構文、`async` / `await`、`finally`、try 式、旧 `let` / `fn` 構文は提供しません。OS やライブラリの大きな機能は D 側で実装し、必要最小限だけをバインドしてください。
