# Dua

Dua は、**D 言語アプリケーションへ組み込み可能な軽量スクリプトランタイム**です。  
このリポジトリでは、字句解析・構文解析・AST・実行エンジンまでを `source/dua` 以下に実装しています。

## 特徴

- D から簡単に埋め込める `Dua.ScriptEngine` API
- 値の橋渡しを行う `Dua.Value`（数値、文字列、配列、テーブル、関数など）
- `run/runSafe`, `load/loadSafe`, `runFile/runFileSafe`, `loadFile/loadFileSafe` による実行導線
- `bind` / `bindFunc` / `bindNative` による D 側データと型付き・動的関数の公開
- `bindAuto` / `engine["name"] = value` による自動変換バインド（aggregate は reflect）
- `registerModule` + `require(...)` によるモジュール読み込み
- `instance` 変数・import・ブロックと `new Module` によるモジュールの実体生成（[使用例](examples/module-instances/README.md)）
- `RunOutcome` によるエラー情報とスタックトレース取得
- `#` / `//` / `/+ ... +/`（ネスト可）によるコメント
- 参照型の配列・テーブルと `[...array]` / `{...table}` による浅いコピー
- ネイティブな値型 `struct`（代入・呼び出し・戻り値・コンテナ格納で浅いコピー）
- `iota(end)` / `iota(start, end[, step])` による整数配列の生成
- `auto` と `int` / `double` / `bool` / `string` による型付き宣言・関数
- `cast(Type) expr` による明示的な型キャスト
- `delegate` 型と `=>` / `:>` による型付きラムダ
- `table` による参照型aggregateと型spread、`alias` による純粋な型別名・Union / Optional型
- `struct Vec2 { int x; int y; }` と `Vec2(1, 2)` による値型の宣言・構築
- `try` / `catch` と構造化エラーテーブル
- `check(source)` と `RunOptions.typeCheck` による事前型診断

## クイックスタート

### 1. ビルド

```bash
dub build --compiler=ldc2
```

### 2. 実行

```bash
dub run --compiler=ldc2
```

### 3. 最小埋め込み例

```d
import dua;
import std.stdio;

void main()
{
    auto engine = new Dua.ScriptEngine();

    engine.bind("base", Dua.Value.from(10));
    engine.bindNative("add", (scope const(Dua.Value)[] args) {
        return Dua.Value.from(args[0].toInt() + args[1].toInt());
    });

    auto result = engine.run(q{
        auto v = add(base, 5);
        return v;
    });

    writeln(result.toInt()); // 15
}
```

## ドキュメント

用途別の日本語ドキュメントを `docs/` に用意しています。

- [入門ガイド](docs/public-guide-ja.md) — ビルド、最初の埋め込み、値・関数・モジュールの基本
- [言語リファレンス](docs/language-reference-ja.md) — 構文、型、標準ライブラリの一覧
- [日本語 HTML リファレンス](docs/language-reference-ja.html) — 30章の言語仕様・標準関数詳解・D API・実用例。全文検索、コードコピー、ダークモード、印刷に対応し、ブラウザーで直接開けます
- [埋め込み API リファレンス](docs/embedding-api-ja.md) — `ScriptEngine` / `Value` / reflection / 安全な実行

HTML版は外部依存のない単体ファイルです。原稿を更新したら `node docs/build-reference.mjs` で再生成できます。

## エディターサポート

- [Visual Studio Code 拡張](editors/vscode-dua/README.md) — `.dua` のハイライト、入力補完、スニペット、構文・型エラー表示。Windows x64用VSIXを作成してインストールできます

## リポジトリ構成

- `source/dua/lexer.d` : Lexer
- `source/dua/parser.d` : Parser
- `source/dua/ast.d` : AST 定義
- `source/dua/runtime.d` : Script 実行エンジン
- `source/dua/value.d` : 値モデルと相互変換
- `source/dua/package.d` : 公開ファサード（`module dua`）

## 開発者向け

```bash
dub test --compiler=ldc2
```

CI を導入する場合も、まずこの 2 コマンド（`build` / `test`）を通す運用を推奨します。

### D の range の返り値

D→Dua の値変換は、`save` を持つ有限の forward struct range を通常の Dua 配列へ実体化します。たとえば D 側で `filter` / `map` の結果を返せば、Dua では `foreach`、`.length`、添字、`$`、スライスを利用できます。具体的な range 型の個別登録は不要です。関数・メソッド・getter・公開フィールド・`bindAuto`・`Value.fromAuto` で同じ変換を使います。

列挙位置を `save` で分離し、走査は一回だけです。標準 `iota` の算術的な length、または `@NonTraversingLength` を型に指定したホストの明示契約で長さを安全に取得できる場合は `Value[]` を事前確保し、それ以外は拡張します。`hasLength` だけでは length 自身が再走査しない保証がないため、任意の length は呼びません。この UDA は最適化の指定であり、自動配列化の利用に個別登録は不要です。D の中間 `T[]` と仕上げ時の配列バッファコピーは作りません。要素の変換・構造体の値コピーは従来の配列変換と同じ境界で行います。長さ不明の拡張、文字列変換、反映された構造体、ユーザーの `save` などでは追加確保が発生し得ます。

文字列・配列・連想配列は既存の変換を維持します。クラス range、input-only range、`alias this` を持つコンテナ、宣言上の無限 range は従来どおり反映され、自動消費しません。有限の forward range へ明示的に変換して返してください。元の range を公開する必要がある場合は `Value.reflect(range)` を返せます。自動配列化は D→Dua 方向だけであり、Dua 配列から任意の D range 型を再構築するものではありません。

`save` はデータの深い複製ではありません。元の配列・参照要素・predicate の状態は共有され得ます。有限性、正しい length、front の値の寿命はホスト側の契約です。共有カーソルや借用バッファを持つ input-only range を forward range と偽装しないでください。`isInfinite == false` は停止の証明ではなく、ホスト内の列挙には Dua の命令数上限も適用されません。必要ならホスト側で件数を制限してください。

実体化された配列の要素代入は元の range へ書き戻しません。クラス要素などの参照共有は既存の配列と同じです。例外は通常のホスト呼び出しと同じ経路で伝播します。

`NoBind` を指定した range プロトコルを持つ型も、自動実体化から除外します。確保量の再現用ベンチは `benchmarks/host_ranges.d` にあります。GC の allocatedInCurrentThread だけでは配列のその場拡張を捕捉できないため、GC.stats.usedSize の差も記録します。
