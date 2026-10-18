## 0.4.2

- Refresh the bundled checker to accept trailing commas in array literals while rejecting missing elements.

## 0.4.1

- Refresh the bundled checker with string literal aliases and union constraints from Dua PR #59.
- Accept declarations such as `alias Fruit = "Apple" | "Orange";` and diagnose incompatible literal values.

## 0.4.0

- Receive structured ZsD scene runtime/load errors through an asynchronous JSON inbox.
- Show source-matched locations in Problems; route unknown/stale locations to Output.
- Keep scene/run ownership, clear stale results on edits and lifecycle events, and preserve other diagnostic collections.

# Changelog

## 0.3.0

- ホストの公開登録から生成した JSON による API・型・メンバー補完を追加
- 型付き戻り値・単純な変数の別名・プロパティを経由する補完に対応
- ホスト定義の文字列引数・アセット名・シーン文脈による補完と出典表示を追加
- 削除・移動・変更されたアセットの古い候補を除外

## 0.2.0

- キーワード・型・標準関数・ファイル内の宣言名の入力補完を追加
- 標準ライブラリのメンバー補完と10種類のスニペットを追加
- Dua本体を使う構文・型診断とWindows x64用の診断ツールを追加
- ネストしたコメント・補間式のハイライトと、不完全な文字列の次行への影響を修正

## 0.1.0

- Duaの構文ハイライト、コメント操作、括弧補完、折りたたみを追加
