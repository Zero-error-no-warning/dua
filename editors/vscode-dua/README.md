# Dua Language for Visual Studio Code

Duaスクリプト（`.dua`）向けのVS Code拡張です。

- キーワード、型、数値、文字列、関数のシンタックスハイライト
- `#` / `//` とネストした `/+ ... +/` コメント、`i"...$(expression)..."` 文字列補間
- キーワード・型・標準関数と、編集中のファイルにある宣言名の入力補完
- `math.`、`string.`、`json.` などの標準ライブラリのメンバー補完
- プロジェクトが生成する JSON によるホスト API・型・メンバー補完（[生成方法と形式](HOST_COMPLETION.md)）
- 関数・ループ・struct・importなどのスニペット
- 入力中の構文エラー・事前型チェックの結果を波線と「問題」パネルに表示
- コメント操作、括弧とダブルクォートの補完、リージョンの折りたたみ

## インストール（Windows x64）

`dua-language-win32-x64-0.3.1.vsix` を用意し、VS Codeのコマンドパレットで **Extensions: Install from VSIX...** を実行して選択します。必要に応じて **Developer: Reload Window** を実行してください。

コマンドからインストールする場合は、リポジトリのルートで次を実行します。

```powershell
code --install-extension .\editors\vscode-dua\dua-language-win32-x64-0.3.1.vsix
```

Windows x64用VSIXには診断ツールを含むため、利用時にDコンパイラーやNode.jsを別途インストールする必要はありません。`.dua` を開けばDuaとして認識され、`Ctrl+Space` で補完候補を表示できます。ワークスペースが信頼済みの場合、診断は自動で有効になります。

## 使用例

```dua
int add(int left, int right) {
    return left + right;
}

auto values = iota(5);
auto total = add(10, 20);
int wrong = "text"; // intとstringの不一致を表示
```

`math.` の後に補完を開くと `abs` / `floor` / `min` / `max` を表示します。`func`、`for`、`foreach`、`struct`、`try`、`import`、`instanceimport`、`lambda`、`istr` はスニペットの入力候補です。

## 診断の設定と対応範囲

| 設定 | 既定値 | 内容 |
|---|---|---|
| `dua.diagnostics.enable` | `true` | 構文・型診断の有効／無効 |
| `dua.diagnostics.delay` | `400` | 入力後に検査するまでの待ち時間（ms） |
| `dua.checkerPath` | 空文字列 | 独自の `dua-check` 実行ファイルの絶対パス。空なら同梱版 |

診断にはDua本体の `ScriptEngine.check` を使います。未保存の編集内容を標準入力で渡し、スクリプトを実行せずに検査します。import先の読み込みやホストの関数呼び出しは行いません。入力更新時には古い検査をキャンセルします。

構文解析エラーは本体が返す最初の1件、型診断は本体が検出する不一致を表示します。ホスト側で公開した変数・関数、import先の型、動的なテーブルメンバーや実行時エラーを完全に検証するものではありません。ファイル内の宣言名の補完は字句ベースで、スコープ外の宣言も候補になる場合があります。ユーザー定義の型に応じたメンバー補完・定義ジャンプ・デバッグは未対応です。

診断の対象は1MB以下のファイルです。検査は5秒でタイムアウトします。ツールが使えない場合は通知と出力パネルの **Dua** に理由を表示します。信頼されていないワークスペースではハイライト・補完・スニペットを利用でき、診断ツールは起動しません。

## 開発・VSIX作成

Node.js 22以上、DMD、DUBが必要です。VSIX作成には[公式のvsce](https://code.visualstudio.com/api/working-with-extensions/publishing-extension)を使います。

リポジトリのルートで実行します。

```powershell
dub build --compiler=dmd
dub test --compiler=dmd
cd editors/vscode-dua
npm ci
npm run build:checker
npm test
npm run package
```

`npm run package` は診断ツールを再ビルドし、Windows x64用VSIXを作ります。別のプラットフォーム向けには、その環境で `npm run build:checker` を実行し、`npx vsce package --target linux-x64` など、ビルド環境に合うターゲットを指定してください。

拡張を開発するときは `code --extensionDevelopmentPath=<拡張ディレクトリの絶対パス>` で開発ホストを起動できます。`npm test` は実際の診断ツールとの連携、TextMateのトークン化、補完、文字位置の変換、診断更新の制御を検証します。
