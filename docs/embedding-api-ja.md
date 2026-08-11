# Dua 埋め込み API リファレンス

この文書は公開入口 `module dua` の API を、用途別に説明します。最初のプログラムは[入門ガイド](public-guide-ja.md)、スクリプト構文は[言語リファレンス](language-reference-ja.md)を参照してください。

## 1. 公開ファサード

```d
import dua;

auto engine = new Dua.ScriptEngine();
```

`Dua` 名前空間は次を公開します。

| 型 | 役割 |
|---|---|
| `Dua.ScriptEngine` | グローバル環境、モジュールキャッシュ、実行状態を持つエンジン |
| `Dua.ScriptModule` | D から作成し、独立した状態と export を持たせるモジュール |
| `Dua.Value`, `Dua.ValueKind`, `Dua.CallableValue` | D と Dua の境界値 |
| `Dua.RunOutcome`, `Dua.RunErrorKind` | Safe API の結果と失敗分類 |
| `Dua.ExecutionLimits`, `Dua.RunOptions` | 実行予算と事前検査設定 |
| `Dua.CheckDiagnostic` | 静的診断の位置とメッセージ |

`module dua` は `dua.runtime` と `dua.value` も public import します。利用側では互換性のある入口として `Dua.*` を使うと、内部モジュールへの直接依存を減らせます。

## 2. ScriptEngine のライフサイクル

```d
auto engine = new Dua.ScriptEngine();
```

生成時に新しいグローバル環境、標準ライブラリ、モジュール検索設定が作られます。グローバル値、ロード済み宣言、モジュールキャッシュは同じインスタンス内で保持されます。テナントや信頼境界をまたいで不用意に共有せず、必要なら処理単位でエンジンを作ってください。

Dua のオブジェクトは D GC の管理下です。手動 GC API はありません。不要になったエンジンや大きな `Value` への参照をホスト側で手放してください。

## 3. 実行、ロード、呼び出し

### 3.1 API 一覧

| API | 成功時 | 用途 |
|---|---|---|
| `run(source[, options])` | `Value` | ソースを実行し、トップレベルの結果を返す |
| `runFile(path[, options])` | `Value` | UTF-8 テキストファイルを読み実行する |
| `load(source)` / `loadFile(path)` | `void` | 同じグローバル環境へ宣言をロードする |
| `loadModule(name)` | `Value` | 登録済み、または検索可能なモジュールを独立スコープでロードする |
| `loadModuleFile(path)` | `Value` | 指定した Dua ファイルを独立スコープのモジュールとしてロードする |
| `call(name, args = [])` | `Value` | グローバル関数を D から呼ぶ |
| `getGlobal(name)` / `engine[name]` | `Value` | グローバル値を取得する |
| `runSafe`, `runFileSafe` | `RunOutcome` | 実行失敗を値として受け取る |
| `loadSafe`, `loadFileSafe` | `RunOutcome` | ロード失敗を値として受け取る |
| `loadModuleSafe(name)` | `RunOutcome` | モジュールのロード失敗を値として受け取る |
| `loadModuleFileSafe(path)` | `RunOutcome` | ファイルをモジュールとしてロードした際の失敗を値として受け取る |

非 Safe API は字句・構文・実行・ファイルエラーを例外として送出します。ユーザー提供ソースや通常運用で失敗し得る処理には Safe API を推奨します。

```d
engine.load(q{
    int add(int a, int b) { return a + b; }
});

auto answer = engine.call("add", [Dua.Value.from(20), Dua.Value.from(22)]);
assert(answer.toInt() == 42);
```

`load` もトップレベル文を実行しますが、結果を返す用途ではなく環境へのロード用途です。

### 3.2 D からモジュールをロードする

```d
engine.registerModule("game.rules", q{
    auto privateBase = 40;
    export auto answer = privateBase + 2;
});

auto rules = engine.loadModule("game.rules");
assert(rules["answer"].toInt() == 42);
auto result = rules.call("calculate", [Dua.Value.from(10)]);

// ファイルを直接モジュールとしてロードする場合
auto settings = engine.loadModuleFile("config/settings.dua");
```

`loadModule` は `require` と同じ登録ソース、検索パス、ローダー、キャッシュを利用します。各モジュールは専用のファイルスコープで評価されるため、非 export 宣言は他のファイルへ漏れず、別モジュールで同名のローカル変数を宣言できます。失敗を例外ではなく `RunOutcome` で扱う場合は `loadModuleSafe` を使います。

`loadModule` と `loadModuleFile` の返り値は `Value` ですが、モジュールの export テーブルには `ScriptEngine` と同じ形式の `call(name, args)` と `moduleValue["name"]` を使用できます。これにより、D 側では `moduleValue.call("calculate", args)` の形で export 関数を呼び、添字で export 値を取得できます。存在しない export や関数ではない export を指定すると例外になります。Safe API から取得する場合も、成功時の `outcome.value.call(...)` を使用できます。

### 3.3 D から空のモジュールを作る

`newModule(name)` は、エンジンのグローバルとは別のトップレベル状態を持つ空の `ScriptModule` を作り、同時に import 可能にします。`bind`、`bindAuto`、`bindNative` で追加した値はモジュールの export として公開されます。

```d
auto gameModule = engine.newModule("game.module");
gameModule.bindAuto("player", player);
gameModule.load(q{
    auto privateBonus = 10;
    export int score(int base) { return base + privateBonus; }
});
```

Dua 側では通常のモジュールと同じ構文で参照できます。

```dua
import game.module as gm;
auto pl = gm.player;
auto score = gm.score(32);
```

`ScriptModule` は `run` / `runSafe`、`load` / `loadSafe`、`loadFile` / `loadFileSafe`、`call`、添字アクセスも提供します。ロードしたソースの通常の宣言はそのモジュール内だけに保持され、`export` 宣言だけが import 経由で公開されます。同名モジュールは重複作成できません。`clearModuleCache()` を呼んでも D で作成したモジュールは登録されたままです。

ファイルパスが既に分かっている場合は `loadModuleFile(path)` を使います。`runFile` が戻り値だけを返す一時実行、`loadFile` が共有グローバル環境へのロードであるのに対し、`loadModuleFile` はファイルを専用スコープで評価し、`export` された値のテーブルを返します。ファイルパスはキャッシュキーにもなります。Safe API は `loadModuleFileSafe(path)` です。

### 3.4 RunOutcome

```d
auto out = engine.runSafe("return missing + 1;");
if (!out.ok)
{
    // out.errorKind, out.errorMessage, out.stackTrace
}
else
{
    auto value = out.value;
}
```

| フィールド | 内容 |
|---|---|
| `ok` | 成功したか |
| `value` | 成功時の戻り値 |
| `errorMessage` | 失敗メッセージ |
| `stackTrace` | Dua 関数呼び出しスタック |
| `errorKind` | `none`, `runtime`, `stepLimit`, `callDepthLimit` |
| `stepsExecuted` | 今回消費した概算ステップ |

### 3.5 実行制限と型検査

```d
auto options = Dua.RunOptions();
options.limits.maxSteps = 100_000;
options.limits.maxCallDepth = 128;
options.typeCheck = true;

auto out = engine.runSafe(source, options);
```

制限値 `0` は無制限です。ステップは安全制御用の概算で、性能指標として安定した命令数ではありません。ネイティブ関数内部はステップ制限外です。ホスト側でも I/O、時間、メモリを制限してください。

`check(source)` は実行せず診断を返します。

```d
foreach (diagnostic; engine.check(source))
{
    writeln(diagnostic.line, ":", diagnostic.column, ": ", diagnostic.message);
}
```

`CheckDiagnostic` は1始まりの `line` / `column` と `message` を持ちます。検査は保守的で、動的なテーブルプロパティ、`any`、ネイティブ関数の結果などは実行時境界検査に委ねます。`typeCheck = true` の実行は診断があれば失敗します。

## 4. 値とネイティブ関数のバインド

### 4.1 bind / bindAuto / 添字記法

```d
engine.bind("exact", Dua.Value.from(42));
engine.bindAuto("name", "Dua");
engine["scores"] = [10, 20, 30];
assert(engine["exact"].toInt() == 42);
```

- `bind(name, Value)` は変換済みの値を公開します。
- `bindAuto(name, value)` は `Value` をそのまま、aggregate を `Value.reflect`、その他を `Value.from` で変換します。
- `engine[name] = value` は `bindAuto`、`engine[name]` はグローバル取得の短縮です。
- 同じスコープにある名前を再度 bind または宣言するとエラーになります。明示的な代入には Dua の代入文を使います。子スコープで親スコープと同じ名前を宣言するシャドーイングは可能です。

### 4.2 bindNative

```d
engine.bindNative("sum", (scope const(Dua.Value)[] args) {
    long total;
    foreach (arg; args)
        total += arg.toInt();
    return Dua.Value.from(total);
});
```

シグネチャは `Value delegate(scope const(Value)[] args)` です。引数個数、型、範囲をコールバック側で検査し、必ず `Value` を返します。戻り値がない処理は `Dua.Value.nullValue()` を返します。

## 5. Value リファレンス

### 5.1 ValueKind と格納フィールド

`ValueKind` は `null_`, `integer`, `floating`, `boolean`, `string_`, `array`, `table`, `function_`, `native` です。`kind` を確認したうえで、必要に応じて `integerValue`, `floatingValue`, `booleanValue`, `stringValue`, `arrayValue`, `tableValue`, `functionValue` を参照できます。通常は変換メソッドを優先してください。

### 5.2 D から Value を作る

```d
auto nil = Dua.Value.nullValue();
auto integer = Dua.Value.from(42);
auto floating = Dua.Value.from(1.5);
auto boolean = Dua.Value.from(true);
auto text = Dua.Value.from("hello");
auto array = Dua.Value.from([1, 2, 3]);
auto table = Dua.Value.from(["hp": 80, "mp": 30]);
```

`from` は `long` / `int` / `double` / `bool` / `string`、配列、文字列キーの連想配列を受けます。独自 aggregate は `reflect`、Dua から変換しない opaque な表示値には `native` があります。

### 5.3 Value から取り出す

```d
auto n = engine.run("return 1 + 2;").toInt();
auto f = engine.run("return 1.5;").toFloat();
auto s = engine.run("return \"abc\";").toHostString();
auto literal = engine.run("return { hp = 3 };").toScriptLiteral();

struct Status { int hp; bool active; }
auto status = engine.run("return { hp = 3, active = true };").to!Status();
```

| メソッド | 用途 |
|---|---|
| `isNumber()` | integer または floating か |
| `toInt()`, `toFloat()` | 数値変換 |
| `toHostString()` | ホスト表示用文字列 |
| `toScriptLiteral()` | Dua リテラル風の表現 |
| `truthy()` | Dua の条件規則で真か |
| `to!T()` | 対応する D 型へ変換。テーブルから struct も可 |

`to!T()` および reflection による引数変換では、Dua の関数値を対応する D の
`ReturnType delegate(Parameters)` 型へ変換できます。生成された delegate を D 側から
呼ぶと、引数は Dua の `Value` へ、戻り値は宣言された D 型へ自動変換されます。

`toScriptLiteral()` は汎用 JSON encoder ではありません。

## 6. D aggregate の reflection

### 6.1 Value.reflect

```d
struct Vec2 {
    int x;
    int y;
    int sum() const { return x + y; }
}
class Counter {
    int value;
}

Vec2 vector = Vec2(1, 2);
auto counter = new Counter();
engine.bindAuto("vector", vector);
engine.bindAuto("counter", counter);

engine.run("vector.x = 99; counter.value = 7;");
assert(vector.x == 1);       // struct は安全な値コピー
assert(counter.value == 7); // class は元インスタンスへ反映
```

- struct はコピーを reflection するため、スクリプト側フィールド代入は元 struct に反映されません。
- class は getter/setter を介して元インスタンスを読み書きします。
- 公開可能なフィールド、メソッド、演算子がテーブルへ反映されます。
- 同名の0引数メソッドと1引数メソッドは property getter/setter としても扱われます。通常の `obj.method(...)` 呼び出しも可能です。
- class の継承チェーンは `typeinfo(value).chain` で取得できます。

Reflection は D の型安全な境界変換に対応できるメンバーだけを公開します。公開面が意図どおりかテストしてください。

### 6.2 bindType

```d
struct Player {
    string name;
    int hp;
}

engine.bindType!Player("Player");
auto value = engine.run(q{
    auto player = Player.new({ name = "Ada", hp = 40 });
    auto alsoPlayer = Player({ name = "Bob", hp = 30 });
    return player.hp + alsoPlayer.hp;
});
```

`bindType!T(name)` は型テーブルを公開し、`Name.new(...)` と `Name(...)` を利用可能にします。

- D コンストラクタは引数個数で候補を選択します。同じ arity の候補が複数あると曖昧エラーです。
- 対応するコンストラクタがなければ、struct はゼロ初期化または初期化テーブル、既定構築可能な class は既定構築後に初期化テーブルを適用します。
- 公開可能な static メンバーも型テーブルへ反映されます。
- `typeinfo(Name)` と `typeinfo(instance)` で型チェーンを確認できます。

## 7. モジュール API

```d
engine.registerModule("game.rules", q{
    export int bonus(int value) { return value + 10; }
});

auto answer = engine.run(q{
    import game.rules as rules;
    return rules.bonus(32);
});
engine.clearModuleCache();
```

- `registerModule(name, source)` はソースをエンジンへ登録します。
- `require(name)` / `import ... as ...` は一度評価した値をキャッシュします。
- `clearModuleCache()` は全キャッシュを消します。登録ソースは残ります。
- 未登録時は loader、続いて検索パターン `?.dua`, `?/init.dua` を調べます。`.` はパス区切りへ変換されます。
- スクリプト側で `package.path`、`package.addPath`、`package.addLoader` などを使って設定できます。ファイル探索を許可する場合は検索元を信頼境界として扱ってください。

## 8. エラーとセキュリティの推奨パターン

```d
auto options = Dua.RunOptions();
options.typeCheck = true;
options.limits.maxSteps = 50_000;
options.limits.maxCallDepth = 64;

auto out = engine.runSafe(untrustedSource, options);
if (!out.ok)
{
    final switch (out.errorKind)
    {
    case Dua.RunErrorKind.none: break;
    case Dua.RunErrorKind.runtime: /* 入力エラーとして通知 */ break;
    case Dua.RunErrorKind.stepLimit: /* 予算超過 */ break;
    case Dua.RunErrorKind.callDepthLimit: /* 再帰過多 */ break;
    }
}
```

実行制限は完全な sandbox ではありません。特に標準 `io.readFile` / `io.exists` / `os.getenv` と、バインドしたネイティブ関数はホストプロセスの権限で動作します。信頼できないコードには、別プロセス、OS 権限、ファイルシステム分離、ホスト側タイムアウトも組み合わせてください。

## 9. API 選択早見表

| やりたいこと | API |
|---|---|
| 1回実行して結果を得る | `runSafe` |
| 信頼済み固定ソースを簡潔に実行 | `run` |
| 関数群を環境へ定義して後で呼ぶ | `load` + `call` |
| primitive / 配列 / AA を公開 | `bindAuto` |
| 変換済み値を公開 | `bind` |
| D callback を公開 | `bindNative` |
| class / struct インスタンスを公開 | `bindAuto` / `Value.reflect` |
| D 型の構築機能を公開 | `bindType!T` |
| 実行せず型診断 | `check` |
| スクリプトをモジュール化 | `registerModule` + `import` / `require` |
