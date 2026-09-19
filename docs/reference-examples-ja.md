# Dua リファレンス補足・実用例

HTMLリファレンスの補足原稿です。構文の基本は [言語リファレンス](language-reference-ja.md)、D API は [埋め込みAPI](embedding-api-ja.md) と合わせて管理します。

## 最初のプログラム

Dua は D アプリケーションに組み込むスクリプト言語です。D に似た波括弧・型注釈・配列構文に、参照型テーブル、クロージャ、コルーチンを組み合わせています。ホストが `ScriptEngine` を作り、Dua のソースを渡して実行します。

```dua
int twice(int value) {
    return value * 2;
}

auto scores = map([10, 20, 30], (int score) => twice(score));
return { language = "Dua", scores = scores };
```

結果は `language` に `"Dua"`、`scores` に `[20, 40, 60]` を持つテーブルです。本文の `dua` ブロックはスクリプト、`d` ブロックはホスト側の D コードです。構文説明の断片では周囲の変数やホスト登録を省略する場合があります。「実用レシピ」の例はそれぞれ単独で実行できます。

### D から動かす最小例

```d
import dua;
import std.stdio : writeln;

void main() {
    auto engine = new Dua.ScriptEngine();
    auto result = engine.run(q{
        int add(int left, int right) { return left + right; }
        return add(20, 22);
    });
    writeln(result.toInt()); // 42
}
```

ホストの DUB プロジェクトから Dua を依存ライブラリとして利用します。このリポジトリの既定構成はライブラリで、`source/app.d` はビルド対象から除外されています。そのため、この構成のまま `dub run` をスクリプト実行CLIとして使うことはできません。

```sh
dub build --compiler=ldc2
dub test --compiler=ldc2
```

### 読み進め方

| やりたいこと | 最初に読む項目 |
|---|---|
| Dua のコードを書きたい | 字句規則 → 変数 → 関数 → 制御構文 |
| データ構造を選びたい | 配列・テーブル → 型・alias・Union → コピーのレシピ |
| 関数を探したい | 標準関数一覧 → 引数・戻り値の詳細 |
| D から呼びたい | ScriptEngine → バインド → Value → reflection |
| エラーの理由を調べたい | エラー処理 → 実行制限 → よくある疑問 |

## 標準関数の詳細：基本とメタテーブル

以下のシグネチャで `[arg]` は省略可能、`args...` は可変長を表す説明用の記法です。Dua の型宣言そのものではありません。標準ライブラリはエンジン生成時に登録されます。

| 呼び出し | 結果・動作 | 条件・注意点 |
|---|---|---|
| `length(value)` / `len(value)` | 長さの整数 | 配列は要素数、文字列はUTF-8バイト数、テーブルは格納キー数。struct は対象外 |
| `typeof(value)` / `typeinfo(value)` | `kind`, `chain`, `aliasThisChain` のテーブル | 型名文字列だけを返す関数ではない |
| `debug.type(value)` | 実行時の値種別文字列 | `integer`, `floating`, `boolean`, `string_`, `array`, `table`, `struct_`, `function_`, `native`, `null_` |
| `debug.traceback()` | 現在の呼び出しスタックの文字列 | `catch` の `stack` 配列とは形式が異なる |
| `_ENV(name)` | 名前で取得したグローバル値 | ローカル変数の列挙用ではない |
| `error(value[, level])` | スクリプトエラーを送出 | `value` は文字列以外も可。`level` はメッセージに付加する情報 |
| `pcall(fn, args...)` | `[true, result]` または `[false, message]` | 第1引数は関数。通常の失敗メッセージは文字列 |
| `xpcall(fn, handler, args...)` | 成功配列、または `[false, handler(message)]` | handler 自身の失敗はその外側へ伝播 |
| `rawget(table, key)` | 生の格納値、欠けていれば `null` | key は文字列化。`__index` を呼ばない |
| `rawset(table, key, value)` | 更新したテーブル | key は文字列化。`__newindex` を呼ばない |
| `setmetatable(table, meta)` | 更新したテーブル | meta は table または `null`。`null` はメタテーブル解除 |
| `getmetatable(table)` | メタテーブルまたは `null` | 引数は table |
| `setmetatableWithType(table, meta, types...)` | メタ情報と型チェーンを設定したテーブル | 型名を順に指定。型名なしならチェーンをクリア |

`rawget` / `rawset` とメタテーブル操作は参照型 table を対象にします。内部のメタ情報も格納キーとして扱われる場合があるため、メタテーブル付きオブジェクトの `length` を業務データのフィールド数として決め打ちしないでください。

### メタメソッドの例

```dua
auto settings = {};
setmetatable(settings, {
    __index = (any self, any key) {
        return "unset:" ~ key;
    }
});
return settings.theme; // "unset:theme"
```

| フック | 主な用途 |
|---|---|
| `__index` | 存在しないキーを関数または別テーブルで解決 |
| `__newindex` | 未定義キーへの書き込みを処理 |
| `__call` | テーブルを関数のように呼ぶ。先頭引数はそのテーブル |
| `__length` / `__len` | テーブルの長さを定義。`__length` が優先 |
| `__tostring` | 文字列化の拡張 |
| `opUnary-`, `opUnary!` | 単項演算。自分自身を受け取る |
| `opBinary+`, `opBinary~` など | 二項演算。自分自身と右辺を受け取る |

フックの中で同じ動的アクセスを繰り返すと再帰することがあります。生の格納領域を操作する場面では `rawget` / `rawset` を使います。

## 標準関数の詳細：文字列・数値・外部データ

### 文字列とUnicode

| 呼び出し | 戻り値・意味 | 例 |
|---|---|---|
| `string.len(value)` | `length` と同じ長さ | `string.len("Dua")` → `3` |
| `string.upper(value)` | 大文字化した文字列 | `string.upper("Dua")` → `"DUA"` |
| `string.lower(value)` | 小文字化した文字列 | `string.lower("Dua")` → `"dua"` |
| `string.trim(value)` | 両端の空白を取り除く | `string.trim(" Dua ")` → `"Dua"` |
| `string.contains(value, needle)` | 部分文字列を含むかの bool | `string.contains("Dua", "ua")` → `true` |
| `string.replace(value, from, to)` | 一致箇所を置き換えた文字列 | `string.replace("a-b-a", "a", "x")` → `"x-b-x"` |
| `utf8.len(value)` | Unicodeコードポイント数 | `utf8.len("日本語")` → `3` |

`string.upper/lower/trim/contains/replace` と `utf8.len` は入力をホスト文字列に変換してから処理します。`length` 系とは受け入れる値の規則が異なります。

```dua
auto text = "日本語";
return [length(text), utf8.len(text)]; // [9, 3]
```

UTF-8バイト数とコードポイント数、見た目の文字数（書記素クラスタ数）は別です。結合文字や複数コードポイントの絵文字では `utf8.len` も見た目の文字数には一致しません。

### 数値

| 呼び出し | 戻り値 | 注意点 |
|---|---|---|
| `math.abs(value)` | 絶対値の double | 整数入力でも浮動小数 |
| `math.floor(value)` | 負の無限大方向に丸めた int | `math.floor(-1.2)` は `-2` |
| `math.min(value, values...)` | 最小値の double | 1引数以上 |
| `math.max(value, values...)` | 最大値の double | 1引数以上 |
| `iota(end)` | `0` から end 未満の整数配列 | step は `1` |
| `iota(start, end[, step])` | 半開区間の整数配列 | 全引数は int、step は0以外 |

```dua
return [
    iota(4),             // [0, 1, 2, 3]
    iota(5, -1, -2),     // [5, 3, 1]
    cast(int) -1.8,      // -1
    math.floor(-1.8),    // -2
    5 / 2               // 2.5
];
```

`iota` は遅延イテレータではなく、配列を一度に生成します。大きな範囲はその分のメモリを使います。step の方向と端点が一致しない場合は空配列になります。

### ファイル・時刻・環境変数・JSON

| 呼び出し | 戻り値・意味 | 注意点 |
|---|---|---|
| `io.exists(path)` | パスが存在するかの bool | 通常ファイルかどうかだけを判定する関数ではない |
| `io.readFile(path)` | テキスト内容 | 読み取り失敗はエラー。書き込みAPIはない |
| `os.getenv(name)` | 環境変数の文字列 | 存在しない場合は空文字列 |
| `os.clock()` | Unix時刻の整数秒 | この実装ではCPU時間でも高精度計測器でもない |
| `time.nowUnix()` | Unix時刻の整数秒 | ホストの現在時刻 |
| `json.encode(value)` | JSON文字列 | 配列・table・structを再帰的に変換 |

```dua
return json.encode({ name = "Dua", scores = [10, 20], active = true });
// JSONオブジェクト。キーの列挙順に依存しないこと。
```

現在の `json.encode` は `std.json` を利用するJSONエンコーダです。`Value.toScriptLiteral()` の表示とは区別してください。null・整数・有限の浮動小数・bool・文字列・配列・table・struct に対応し、関数・native・非有限数は拒否します。循環参照の検出は実装されていないため、循環するコンテナを渡さないでください。`json.decode` は提供しません。

## 標準関数の詳細：配列・テーブルの変換

| 呼び出し | 戻り値・動作 |
|---|---|
| `map(collection, callback)` | 各値を変換した新しい配列またはテーブル |
| `filter(collection, callback)` | callback が真と判定された値を残す新しいコンテナ |
| `table.map(collection, callback)` | グローバル `map` と同じ。配列も受け付ける |
| `table.filter(collection, callback)` | グローバル `filter` と同じ。配列も受け付ける |
| `table.keys(table)` | キーの配列。順序は未規定 |
| `table.len(value)` / `table.length(value)` | グローバル `length` と同じ |

### callback の引数

`foreach (key, value; collection)` と異なり、map/filter の callback は **値が先、キーが後** です。0引数なら引数なし、1引数なら値、2引数なら値と添字またはキーを受け取ります。通常は1引数か2引数の関数を使ってください。

```dua
auto names = ["Ada", "Bob"];
auto numbered = map(names, (string name, int index) {
    return i"$(index):$(name)";
});
return numbered; // ["0:Ada", "1:Bob"]
```

```dua
auto scores = { ada = 80, bob = 45, chris = 90 };
return filter(scores, (int score) => score >= 60);
// ada と chris のキー・値を持つ新しいテーブル
```

配列の filter は結果を0始まりの連続添字に詰め直します。テーブルの map/filter はキーを維持します。元のコンテナ自体を置き換えませんが、callback から参照先を変更する副作用は起こり得ます。

### スライスと連結

```dua
auto items = [10, 20, 30, 40];
auto middle = items[1 .. 3]; // [20, 30]。上限は含まない
auto tail = items[2 .. $];   // [30, 40]
return middle ~ tail;       // [20, 30, 30, 40]
```

配列スライスは新しい要素配列を作ります。入れ子の参照値まで複製する深いコピーではありません。両端を明示する `items[0 .. $]` を使えます。範囲外の添字・範囲はエラーです。配列同士の `~` は新しい配列、他の組み合わせの `~` は文字列連結になります。

## 標準関数の詳細：モジュールとコルーチン

### モジュール関数

| 名前 | 引数・動作 |
|---|---|
| `require(name)` / `package.require(name)` | モジュール名の文字列を受け、キャッシュされた公開テーブルを取得 |
| `addModulePath(pattern)` / `package.addPath(pattern)` | 検索パターンを追加 |
| `addModuleLoader(fn)` / `package.addLoader(fn)` | loader を追加。モジュール名を受け取り、ソース文字列を返す |
| `setModuleLoaders(loaders...)` | loader 群を置き換える。引数なしでクリア |
| `package.clearLoaders()` | loader をクリア |
| `package.loaded(name)` | 指定名のロード済みモジュール。未ロードなら `null` |
| `package.path` | 検索パターンの配列 |

既定の検索パターンは `?.dua` と `?/init.dua` です。`game.rules` は探索時に `game/rules` へ変換されます。登録ソースがなければ loader、続いてファイルを探します。loader は非空のソース文字列を返すと採用されます。

現在は require の前に `package.path` が探索設定へ同期されます。確実に検索パスを設定する例として、配列自体を更新する書き方を使えます。

```dua
package.path = ["scripts/?.dua", "scripts/?/init.dua"];
// scripts/game/rules.dua 等を用意してから実行する。
import game.rules as rules;
return rules;
```

### コルーチン関数

| 名前 | 戻り値・動作 |
|---|---|
| `coroutine.create(fn)` | 新しいコルーチンのハンドル。まだ実行しない |
| `coroutine.resume(co, args...)` | 再開して `[true, 値...]`、または `[false, message]` |
| `coroutine.status(co)` | `"suspended"`, `"running"`, `"dead"` |
| `coroutine.running()` | 実行中のハンドル。外側では `null` |
| `coroutine.isyieldable()` | 現在コルーチン内で中断できるかの bool |
| `coroutine.wrap(fn)` | resume 相当の関数。成功フラグを外し、失敗はエラーにする |

`yield value;` で呼び出し元へ値を返して中断します。初回 resume の引数は関数の引数になります。終了したコルーチンを再開すると成功フラグが `false` になります。自動で並列実行する仕組みではありません。

```dua
auto co = coroutine.create((int start) {
    yield start;
    yield start + 1;
    return start + 2;
});
auto a = coroutine.resume(co, 10); // [true, 10]
auto b = coroutine.resume(co);     // [true, 11]
auto c = coroutine.resume(co);     // [true, 12]
return [a, b, c, coroutine.status(co)];
```

## 実用レシピ

ここに掲載した Dua コードは、各ブロックを新しい `ScriptEngine` の `run` にそのまま渡せる例です。ホストから値や関数を事前に登録する必要はありません。

### 1. 値型と参照型のコピーを比較する

```dua
struct Point { int x; int y; }
Point original = Point(1, 2);
Point copied = original;
copied.x = 9;

auto shared = { hp = 100 };
auto same = shared;
same.hp = 70;

auto separate = { ...shared };
separate.hp = 50;
return [original.x, copied.x, shared.hp, separate.hp];
// [1, 9, 70, 50]
```

struct のフィールドが配列やテーブルなら、フィールドの参照先は共有されます。「値型」は入れ子を含む完全な独立コピーを意味しません。

### 2. クロージャに状態を保持する

```dua
any makeCounter(int start) {
    auto count = start;
    return () {
        count = count + 1;
        return count;
    };
}
auto counter = makeCounter(10);
auto first = counter();
auto second = counter();
return [first, second]; // [11, 12]
```

### 3. データを選別・集計する

```dua
auto orders = [
    { name = "book", price = 1200, active = true },
    { name = "pen", price = 200, active = false },
    { name = "paper", price = 300, active = true }
];
auto active = filter(orders, (any order) => order.active);
auto total = 0;
foreach (order; active) {
    total = total + order.price;
}
return { count = length(active), total = total }; // count=2, total=1500
```

### 4. 構造化エラーで入力を検証する

```dua
int requirePositive(int amount) {
    if (amount <= 0) {
        error({ code = "INVALID_AMOUNT", amount = amount });
    }
    return amount;
}
try {
    return requirePositive(-2);
} catch (err) {
    return { ok = false, kind = err.kind, detail = err.value };
}
// kind="ScriptError", detail.code="INVALID_AMOUNT"
```

### 5. 名前付き型と Optional を使う

```dua
table Named { string name; }
table Player { ...Named; int hp; }
alias MaybePlayer = Player | null;

Player hero = { name = "Ada", hp = 100 };
MaybePlayer absent = null;
return [hero is Player, hero is Named, absent == null];
// [true, true, true]
```

### 6. UFCS とメソッドを使い分ける

```dua
string surround(string text, string marker) {
    return marker ~ text ~ marker;
}
auto box = {
    title = "Dua",
    label = () { return this.title; }
};
return box.label().surround("*"); // "*Dua*"
```

### 7. 明示的なキャストと失敗を扱う

```dua
auto ok, number = pcall((string text) => cast(int) text, "42");
auto invalid, message = pcall((string text) => cast(int) text, "forty");
return [ok, number, invalid]; // [true, 42, false]
```

### 8. 式ラムダと副作用ラムダ

```dua
auto state = { count = 0 };
auto twice = (int x) => x * 2;
auto update = (int x) :> state.count = x;
update(twice(21));
return state.count; // 42
```

## よくある疑問と移植時の注意

### 文字列を print したい

組み込みの `print` はありません。ホスト側で必要な出力関数を公開します。Dua 側の `return` で値を返し、D 側で `writeln` する方法もあります。

```d
engine.bindNative("print", (scope const(Dua.Value)[] args) {
    foreach (arg; args) writeln(arg.toHostString());
    return Dua.Value.nullValue();
});
```

### int と書けば、その後のすべての代入も保証される？

現在は宣言時の初期値、関数境界、キャストなどで実行時検査を行います。変数への後続の単純代入については型注釈が永続的な制約として保存されません。`check` と `RunOptions.typeCheck` の事前診断を併用し、動的経路は実行時の動作も確認してください。

### D や JavaScript の構文はそのまま使える？

| 書きたい処理 | Dua での書き方・制限 |
|---|---|
| インクリメント、複合代入 | `i = i + 1;`。`++` / `+=` は未対応 |
| 文字列をつなぐ | `"hello " ~ name`。`+` は文字列連結演算子ではない |
| 配列をつなぐ | `[1, 2] ~ [3]` または `[...[1, 2], 3]` |
| 論理否定 | `!value`。`~` はビット否定ではない |
| 型付き配列 | `auto values = [...]`。D の `int[]` 宣言構文は未対応 |
| 初期化なしの変数 | 宣言時に初期値が必要 |
| オブジェクトリテラル | `{ name = "Ada" }`。JSONの `:` ではなく `=` |
| null許容 | `alias Maybe = T | null;` で型別名を作る |
| 直接Union型の変数宣言 | `alias` を作ってから `Maybe value = ...;` を使う |
| 関数型を変数で使う | `alias Transform = int delegate(int);` のように別名経由で宣言 |
| 例外を投げる | `error(value)`。`throw` / `finally` 構文はない |
| 列挙順序 | テーブルの順序は保証されない。順序が必要なら配列 |
| 非同期処理 | `async` / `await` はない。コルーチンは明示的に resume |

### 文字列内のバックスラッシュや数値表記は？

文字列はダブルクォートの1行形式で、エスケープシーケンスはありません。`"a\nb"` の `\n` は改行へ変換されません。ダブルクォートそのものをバックスラッシュでエスケープして埋め込むこともできません。必要な文字列はホストから渡す方法があります。

数値リテラルは10進整数と小数です。16進表記、指数表記、桁区切りの `_`、`.5` のような省略表記は使用せず、`0.5` のように書いてください。D コードの `100_000` はホスト D の構文です。

### false と判定される値は？

`null`、`false`、数値の0、空文字列です。空配列 `[]` と空テーブル `{}` は真です。`cast(bool) "false"` も空でない文字列なので真です。

### typeof は文字列ではない？

はい。`typeof(value).kind` または `debug.type(value)` で値種別を取得します。D のコンパイル時 `typeof` とは異なる通常の標準関数です。

### run と load はどう使い分ける？

`run` は一時的な子スコープで実行します。宣言を次の呼び出しでも使うなら `load` で永続環境へ読み込み、`call` で関数を呼びます。`run` から親スコープの既存値を更新すると、その更新は残ります。

### Safe API はサンドボックス？

Safe API は失敗を `RunOutcome` にまとめるAPIです。OS機能の隔離ではありません。標準ライブラリにはファイル読み取り・環境変数取得があり、公開した D 関数はホストの権限で動きます。ステップ制限もネイティブ処理内部の実行時間やメモリ割り当てを制限しません。

## 仕様の確認先と更新方法

このリファレンスは、このリポジトリの実装を基準にしています。機能名が D や Lua と似ていても、同じ仕様とは限りません。実装に即した注意事項と、構文説明用の例を区別して掲載しています。

| 分野 | 主な確認先 |
|---|---|
| トークン・リテラル・コメント | [lexer.d](../source/dua/lexer.d) |
| 構文・優先順位 | [parser.d](../source/dua/parser.d) |
| 評価・代入・演算・制御構文 | [evaluator.d](../source/dua/evaluator.d) |
| 値・コピー・Dとの変換 | [value.d](../source/dua/value.d) |
| エンジン・型検査・使用例 | [runtime.d](../source/dua/runtime.d) と [typecheck.d](../source/dua/typecheck.d) |
| 実行制限・結果構造体 | [execution.d](../source/dua/execution.d) |
| モジュール・コルーチン | [module_system.d](../source/dua/module_system.d) と [coroutine.d](../source/dua/coroutine.d) |
| 標準関数・JSON | [core.d](../source/dua/stdlib/core.d) と [json.d](../source/dua/stdlib/json.d) |
| 公開API | [package.d](../source/dua/package.d) |

HTMLの原稿は `language-reference-ja.md`、`embedding-api-ja.md`、`reference-examples-ja.md` です。原稿や表示を更新したら、リポジトリのルートで次のコマンドを実行します。追加の npm パッケージは不要です。

```sh
node docs/build-reference.mjs
```

生成される `docs/language-reference-ja.html` は CSS と JavaScript を内蔵します。ブラウザーで直接開けて、本文表示・検索・テーマ切り替えはネットワーク接続なしで利用できます。リポジトリ内の原稿・ソースへのリンクは、HTMLを単独で移動すると参照できなくなる場合があります。
