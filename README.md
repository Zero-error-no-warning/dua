# Dua

Dua は、**D 言語アプリケーションへ組み込み可能な軽量スクリプトランタイム**です。  
このリポジトリでは、字句解析・構文解析・AST・実行エンジンまでを `source/dua` 以下に実装しています。

## 特徴

- D から簡単に埋め込める `Dua.ScriptEngine` API
- 値の橋渡しを行う `Dua.Value`（数値、文字列、配列、テーブル、関数など）
- `run/runSafe`, `load/loadSafe`, `runFile/runFileSafe`, `loadFile/loadFileSafe` による実行導線
- `bind` / `bindNative` による D 側データと関数の公開
- `bindAuto` / `engine["name"] = value` による自動変換バインド（aggregate は reflect）
- `registerModule` + `require(...)` によるモジュール読み込み
- `RunOutcome` によるエラー情報とスタックトレース取得
- `#` / `//` / `/+ ... +/`（ネスト可）によるコメント
- 参照型の配列・テーブルと `[...array]` / `{...table}` による浅いコピー
- `iota(end)` / `iota(start, end[, step])` による整数配列の生成
- `auto` と `int` / `double` / `bool` / `string` による型付き宣言・関数
- `delegate` 型と `=>` / `:>` による型付きラムダ
- `alias` によるテーブル型、型spread、Union / Optional型
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
- [埋め込み API リファレンス](docs/embedding-api-ja.md) — `ScriptEngine` / `Value` / reflection / 安全な実行

## エディターサポート

- [Visual Studio Code 拡張](editors/vscode-dua/README.md) — `.dua` のシンタックスハイライト、コメント、括弧補完、折りたたみ

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
