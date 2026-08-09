# Dua Language for Visual Studio Code

Dua スクリプト（`.dua`）向けの軽量な Visual Studio Code 拡張です。言語サーバーや実行環境は含まず、次のエディター支援を提供します。

- キーワード、型、数値、文字列、演算子、関数のシンタックスハイライト
- `#` / `//` の行コメントと、ネストした `/+ ... +/` ブロックコメント
- `i"...$(expression)..."` の文字列補間
- 括弧とダブルクォートの自動補完、対応する括弧の強調、リージョンの折りたたみ

## ローカルインストール

拡張ディレクトリを VS Code の拡張フォルダーへコピーまたはシンボリックリンクします。

```bash
ln -s "$(pwd)/editors/vscode-dua" "$HOME/.vscode/extensions/dua-language-0.1.0"
```

その後、VS Code のコマンドパレットから **Developer: Reload Window** を実行してください。`.dua` ファイルは自動的に Dua として認識されます。

## VSIX の作成（任意）

`@vscode/vsce` が利用できる環境では、次のコマンドで配布用パッケージを作成できます。

```bash
cd editors/vscode-dua
npx @vscode/vsce package
```

生成された `.vsix` は、VS Code の **Extensions: Install from VSIX...** からインストールできます。
