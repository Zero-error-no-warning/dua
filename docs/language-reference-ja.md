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
- キーワードは `auto delegate alias struct is cast try catch return if else while for foreach switch case default break continue yield true false null this import export as` です。`table` は宣言先頭では文脈キーワードですが、標準の `table.map` などでは通常の識別子です。`int` などの型名、`any`、`void` は構文上は識別子として型位置に現れます。

### 1.2 値の種類と真偽

実行時の値は `null`、整数、浮動小数、真偽値、文字列、配列、型付き連想配列、参照型テーブル、値型struct、関数、native 値です。条件式では `null`、`false`、数値の `0`、空文字列、空の配列・連想配列・テーブル・structが偽です。それ以外の値は真として扱われます。

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

- `auto name = expr;` は型注釈なしで値を束縛します。事前型検査では初期値から型を推論します。
- `Type name = expr;` は宣言の初期値を実行時に型検査します。現在の実行時環境は変数の型注釈を保持しないため、その後の単純代入すべてを同じ型に制限するものではありません。事前型検査は別途 `check` / `RunOptions.typeCheck` で有効にします。
- 宣言には初期値が必須です。未宣言変数への代入はエラーです。
- ブロックと関数は外側を参照できるレキシカルスコープを作り、ラムダは外側の変数をキャプチャします。
- `auto a, b = array;` と `a, b = array;` は、右辺の配列要素を左辺へ順番に割り当てる分配代入です。`return a, b;` も書けますが、戻り値は配列にまとめられます。要素が足りない左辺には `null` が入ります。

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
- `ReturnType delegate(ArgumentTypes)` は関数型の表記です（例: `int delegate(int)`）。型付き関数自身の引数・戻り値は呼び出し時に検査されます。ただし現在の delegate 型への実行時適合判定は関数値であることの確認で、注釈だけでシグネチャ全体の一致を保証するものではありません。
- テーブル上の関数を `object.method(...)` と呼ぶと、関数本体の `this` はそのテーブルになります。
- 同名の直接メンバーがない場合、`value.fn(args)` はスコープ内の関数 `fn(value, args)` を探す UFCS 呼び出しになります。メンバーが存在して関数でない場合はエラーです。

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
- 現在の `switch` は最初に選ばれた節だけを実行し、次の節へフォールスルーしません。`default` は最後に置いてください。

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

### 5.1 型付き連想配列

テーブル `{ ... }` と別の値として、`値型[キー型]` の連想配列を使えます。リテラルは `[キー: 値, ...]` です。

```dua
string[int] names = [1: "Alice", 2: "Bob"];
names[3] = "Carol";
auto first = names[1];

int[int] counts;             // 空の連想配列
int[int] alsoEmpty = [:];    // [] での初期化も可
counts[10] = 42;

foreach (key, value; names) {
    // key は整数、value は文字列
}

bool found = names.contains(1);
auto fallback = names.get(9, "unknown");
bool removed = names.remove(2);
auto keys = names.keys;
auto values = names.values;
auto size = names.length;   // length(names)、names.length() も可
```

型注釈は初期化、変数への再代入、要素の追加・更新、添字参照、関数の引数・戻り値で検査されます。例えば `names["1"]` や `names[1] = 42` はエラーです。存在しないキーの `names[key]` もエラーです。既定値付き取得には `get` を使います。`keys()` / `values()` もプロパティ形式と同じ内容を返します。

```dua
struct Position { int x; int y; }
string[Position] labels = [Position(1, 2): "start"];
auto label = labels[Position(1, 2)];
int[bool] switches = [true: 1, false: 0];
string[double] fractions = [1.5: "one and a half"];
int[int][string] teams = ["red": [1: 100]];

alias Names = string[int];
Names copy = [1: "Alice"];
auto explicitlyTyped = cast(string[int]) [1: "Alice"];
string[int] identity(string[int] value) { return value; }
```

- キーは整数・有限の浮動小数・真偽値・文字列・配列・struct・reflect 済み D クラスに対応します。通常のテーブル、連想配列自身、関数、opaque native 値はキーにできません。
- 配列および Dua struct のキーは内容で比較し、保存時と取り出し時にコピーします。reflect 済み D struct は D のコピーと等値比較を使います。D クラスのキーはインスタンスの同一性で比較します。
- キーを文字列化しません。型注釈のないリテラルは `any[any]` で、`auto mixed = [7: "number", "7": "text"];` は別々の2要素を保持します。型を固定するには宣言または `cast` を使います。
- 連想配列は参照型です。同じ型の代入や `auto alias = names;` は内容を共有します。型のないリテラルを型付き連想配列へ変換するときは、新しいコンテナを作ります。
- `typeof(names).kind` は `"associativeArray"` です。`keyType` と `valueType` でも宣言型を確認でき、`names is string[int]` で型を検査できます。
- 現在のキー検索は線形です。列挙順序に依存しないでください。テーブル専用のメタテーブル操作、spread、`map` / `filter`、`json.encode` は型付き連想配列には対応していません。
- 数値の内部表現は従来と同じ符号付き64ビット整数と倍精度浮動小数です。D に渡す整数キーは変換先の範囲を検査します。D の `ulong` 全域など、内部表現を超える値は扱えません。

## 6. 型、alias、Union

| 型名 | 意味 |
|---|---|
| `int` | 符号付き64ビット整数 |
| `double` | 倍精度浮動小数 |
| `bool` | `true` または `false` |
| `string` | UTF-8文字列 |
| `any` | 任意の種類の値 |
| `void` | 値を返さない関数の注釈。実行時の対応値は `null` |

型付き宣言の数値型は値の種類を区別します。`double rate = 1.0;` または `double rate = cast(double) 1;` と記述してください。整数リテラル `1` が型注釈だけで自動的に double に変換されるわけではありません。配列・table・function の種類を確認して受け取る明示キャストは、後述の `cast(array)` などを使います。

```D
struct Vec2 {
    double x;
    double y;
}
Vec2 point = Vec2(1.0, 2.0);

table Named {
    string name;
}
table Player {
    ...Named;
    int hp;
}
table Enemy {
    string name;
    int damage;
}
alias Target = Player | Enemy;
alias MaybePlayer = Player | null;

Player hero = { name = "Ada", hp = 100 };
if (hero is Named) {
    hero.hp = hero.hp - 1;
}
```

- `struct` はネイティブな値型です。代入、引数、戻り値、配列・テーブルへの格納時に浅くコピーされます。フィールド更新はそのコピーだけを変更します。
- `Name(...)` は宣言順のフィールド引数を受け取り、`Name({ field = value })` も利用できます。等値比較はフィールドごとに行われ、`is` と `typeinfo` の型チェーンにも対応します。
- `table Name { ... }` は参照セマンティクスの名前付きaggregateです。
- `alias Name = T` と `alias Name = A | B` は純粋な型別名とUnion型に使用します。aggregateは宣言しません。

- 名前付きテーブル型は宣言したフィールドを要求しますが、余分なフィールドは許可します。
- table 型内の `...BaseType;` は基底型のフィールドと型チェーンを取り込みます。struct 宣言内の型 spread は未対応です。
- 基底型同士または派生型との同名フィールドは、同じ型でもエラーです。
- `A | B` は Union、`T | null` は Optional 型として使えます。
- `value is Type` は名前付き型とその基底型を判定します。
- `typeinfo(value)` / `typeof(value)` は `{ kind, chain, aliasThisChain }` を返します。`chain` は名前付き型の型チェーン、`aliasThisChain` は D reflection の alias this に関する情報です。
- 事前型検査は保守的です。`any`、動的プロパティ、ネイティブ関数の結果などは実行時検査に残ります。

### 型キャスト

`cast(Type) expr` で明示的に型を変換します。

```dua
auto value = 3.9;
int whole = cast(int) value;             // 3（小数部をゼロ方向に切り捨て）
double decimal = cast(double) whole;    // 3.0
string text = cast(string) whole;       // "3"
int parsed = cast(int) "42";            // 42
alias Count = int;
auto count = cast(Count) value;         // 3
```

- `int` / `double`: 数値、真偽値（false は 0、true は 1）、数値文字列を変換します。`int` は符号付き64ビット整数です。整数範囲外、NaN、無限大から `int` への変換はエラーです。
- `bool`: 条件式と同じ真偽判定です。文字列 `"false"` も空でないため真になります。
- `string`: 値の文字列表現を返します。
- 純粋な型別名は別名先と同じ変換を行います。Union / Optional、名前付き型、delegate 型は既存の型検査に成功した値を返します。Union の候補間での変換は行いません。
- `array` / `table` / `function` は対応する種類の値を受け付けます。`any` は任意の値を受け付けます。参照型の共有とstructのコピー規則は通常の代入と同じです。
- 変換できない値や不正な数値文字列は、キャスト位置付きの実行時エラーになります。

キャストは単項演算子と同じ優先順位で、対象を一度だけ評価します。`cast(int) value * 2` は変換後に乗算します。式全体を変換する場合は `cast(int) (value * 2)` と書きます。

## 7. 演算子と優先順位

上ほど強い優先順位です。通常の二項演算子は同じ段の中で左から結合します。三項式の偽側は右結合です。`is` の右辺は値の式ではなく型名です。

| 優先順位 | 演算子 | 用途 |
|---|---|---|
| 1（最強） | `()`、`.`、`[]`、`[..]` | 呼び出し、メンバー、添字、スライス |
| 2 | `!`、`-`、`cast(Type)` | 論理否定、符号反転、明示変換 |
| 3 | `*`、`/`、`%` | 乗算、除算、整数剰余 |
| 4 | `+`、`-`、`~` | 加減、連結 |
| 5 | `<<`、`>>` | 整数シフト |
| 6 | `<`、`<=`、`>`、`>=`、`is` | 大小比較、型判定 |
| 7 | `==`、`!=` | 等価・不等価 |
| 8 | `&` | ビットAND |
| 9 | `^` | ビットXOR |
| 10 | `|` | ビットOR |
| 11 | `&&` | 短絡論理AND |
| 12 | `||` | 短絡論理OR |
| 13（最弱） | `?:` | 条件による式の選択 |

`=` と複合代入 `+=`、`-=`、`*=`、`/=`、`%=`、`~=`、`&=`、`|=`、`^=`、`<<=`、`>>=` は代入文に使います。式としての連鎖代入や `++` は提供しません。`+`・`-`・`*` は両辺が整数なら整数、それ以外は浮動小数として計算します。`%`、ビット演算、シフトは整数に変換して処理します。

```D
auto total = 0;
for (auto i = 0; i < 4; i += 1) total += i;
auto add = (int amount) :> total += amount;
auto values = [10, 20];
values[$ - 1] *= 2;
auto text = "total=";
text ~= total;
```

`target op= expr` は左辺の現在値と右辺を通常の二項演算（`opBinary` / `opBinaryRight` を含む）で計算し、結果を同じ場所へ代入します。左辺のコンテナ・添字と現在値を取得してから右辺を評価し、コンテナや添字の式は一度だけ評価します。変数、プロパティ、配列・連想配列・テーブルの要素に使えます。左辺と右辺はそれぞれ1つで、スライスへの代入はできません。通常の文のほか、`for` の初期化・更新節と `:>` ラムダでも使用できます。`/=` の結果は通常の `/` と同じく浮動小数です。事前型検査を有効にした場合、演算結果の型を代入先の型と照合します。

`&&` と `||` は短絡評価します。`/` は浮動小数の結果を返します。`~` は両辺が配列なら配列を連結し、それ以外では文字列表現を連結します。テーブルには次の特殊キーを置いて動作を拡張できます。

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
- export が1つ以上あれば export テーブルがモジュール値です。export がなく、トップレベルの結果がテーブルならその内容を取り込みます。数値などの任意の戻り値が `require` の結果になるわけではありません。

### export の公開タイミングと循環 import

`export` は、その文を実行した時点で共有の公開テーブルへ値を追加します。モジュール全体の読み込み完了を待ちません。初期化中のモジュールを再び import した場合は、その時点までに公開した値を持つ同じテーブルが返ります。

```dua
// A.dua
export auto before = 1;
import B;
export auto result = B.seen;
export auto after = 2;
```

```dua
// B.dua
import A;
export auto seen = A.before; // Aの初期化途中でも1を読める
export int readAfter() { return A.after; }
```

D側から `engine.loadModule("A")` で読み込むと、A → B → A の循環があっても `B.seen` は `1` になります。Aの読み込み完了後なら `B.readAfter()` は `2` を返します。Bのトップレベルで `A.after` を読むと、まだその export を実行していないのでエラーです。後から追加した export も、既に取得済みのモジュールテーブルから参照できます。

- `export Type name = expression;` は初期値の評価と検査が成功してから公開します。関数の export と `export existingName;` も実行時に反映します。
- 公開は既存の値コピー規則に従います。`before = 3;` のような変数への再代入だけでは、公開済みの数値は更新されません。配列・テーブルの参照は共有されます。
- 初期化に失敗したモジュールはキャッシュから除去します。ただし、既に公開した値や副作用を巻き戻す処理はありません。読み込みが成功済みの依存モジュールが保持する公開テーブルの参照も残ります。
- キャッシュはモジュール名をキーにします。上の例ではD側も `loadModule("A")` を使用します。`loadModuleFile("A.dua")` のパスキーと、`import A` の名前キーは別です。

## 12. 標準関数・ライブラリ一覧

| 名前 | 概要 |
|---|---|
| `error(value[, level])` | スクリプトエラーを送出 |
| `typeof(value)`, `typeinfo(value)` | `{ kind, chain, aliasThisChain }` を返す |
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
| `json.encode` | JSON文字列へ変換。配列はJSON配列、table・structはJSONオブジェクト。関数・native・非有限数はエラー |
| `_ENV(name)` | グローバル値を名前で取得 |

`map` / `filter` の callback は、0引数なら引数なし、1引数なら値、2引数以上なら値とキー（または添字）を受け取ります。`table.keys` の順序は未規定です。

モジュール用には `require`、`addModulePath`、`setModuleLoaders`、`addModuleLoader` と、`package.require/addPath/addLoader/clearLoaders/loaded` を提供します。`package.path` は検索パターン配列です。

## 13. 現在提供しないもの

Dua は組み込み用途を優先します。クラス構文、`async` / `await`、`finally`、try 式、旧 `let` / `fn` 構文は提供しません。OS やライブラリの大きな機能は D 側で実装し、必要最小限だけをバインドしてください。
