# Duaの改善10項目（2026-11-06）

この文書は言語機能追加より前の不具合修正と検証の記録です。現在の追加機能・制限・検証結果は[言語・標準ライブラリの追加](language-additions-2026-11-06-ja.md)を参照してください。

管理元の独立フォルダ `C:\myProject\D\Dua` の現行コードを対象に、以下の順で実装し、各項目ごとに `dub build --compiler=dmd` と `dub test --compiler=dmd` を実行した。開始時点の未コミット変更19ファイルは今回の編集対象から外し、SHA256一致を確認している。GitHubの版への置換、push、通常版アプリケーションへの配布は行っていない。

| 順 | 問題と実装結果 | 回帰確認 | 状態 |
|---|---|---|---|
| 1 | `json.encode`が循環した配列・テーブルを再帰し続ける。現在の祖先との参照同一性を検査し、循環を例外として止める。 | 自己参照配列・テーブル、配列とテーブルの相互参照、非循環の共有、257段の非循環配列。 | 完了 |
| 2 | `pcall` / `xpcall`が実行上限を通常エラーとして捕捉する。`ExecutionLimitException`を再送出し、呼出し元へ上限の分類を保つ。 | 命令数上限・呼出し深さ上限、通常エラーの保護呼出し、次回実行。 | 完了 |
| 3 | 重複したホスト登録が失敗しても補完データだけが書き換わる。署名を仮登録し、環境への登録失敗時に破棄する。 | global / moduleの重複登録、元の関数呼出し・補完の保持、仮署名の残留と古い子項目の除去。 | 完了 |
| 4 | `CompletionRegistry.toJson()`の返り値を編集すると内部情報も変わる。ネストしたJSON配列・オブジェクトを独立コピーにする。 | symbol種別・引数型・typeメンバー・types削除の編集、取得後の追加登録と既存snapshotの独立性。 | 完了 |
| 5 | UTF-8 BOM付きソースが字句エラーになる。先頭のBOMを許容し、元ソースのUTF-8バイト位置で診断する既存契約を保つ。 | 文字列・ファイル実行、静的チェック、先頭行と次行の診断、ソース途中のBOMの拒否。 | 完了 |
| 6 | 数値リテラルの変換失敗が行0・列0になる。変換例外に数値トークンの位置を付ける。 | 64ビット整数範囲外、型検査あり / なし、sourceName / sourceText、check、long.maxの正常実行。 | 完了 |
| 7 | `math.floor`が非有限数や範囲外のdoubleを整数へキャストする。範囲を検査し、整数入力はdoubleへ変換せず全64ビットを保つ。 | NaN・±Infinity・±範囲外・longの境界・2^53を超える整数・正負の通常小数。 | 完了 |
| 8 | Windowsのバックスラッシュを含むimportパス補完が動かない。Windows上の入力区切りを `/` へ正規化して検索する。 | 実在ファイル・未保存overlay・両区切り・末尾区切り・source境界フィルター。 | 完了 |
| 9 | チェッカーJSONの不正な型が黙って空ソースになったり、エラー応答中に再度失敗する。フィールド型を検査し、フィールド名を含むJSON診断を返す。 | 不正16ケース、従来のplain / structured入力、BOM、解析でソースを実行しないこと。 | 完了 |
| 10 | READMEの`dub run`がライブラリ構成で実行できず、既存サンプルも関数入りテーブルのJSON化で失敗する。`example`構成を追加し、JSON化するデータと失敗時の終了コードを修正する。 | `dub run --config=example --compiler=dmd`の成功・出力、既定library構成の維持。 | 完了 |

## 実装・テストの所在

- JSON検出: [source/dua/stdlib/json.d](../source/dua/stdlib/json.d)
- 保護呼出し・floor: [source/dua/stdlib/core.d](../source/dua/stdlib/core.d)、[stdlib_safety_tests.d](../source/dua/stdlib_safety_tests.d)
- 補完: [completion.d](../source/dua/completion.d)、[runtime.d](../source/dua/runtime.d)、[completion_tests.d](../source/dua/completion_tests.d)
- ソース入力・数値診断: [lexer.d](../source/dua/lexer.d)、[parser.d](../source/dua/parser.d)、[input_diagnostics_tests.d](../source/dua/input_diagnostics_tests.d)
- パス補完: [module_resolver.d](../source/dua/module_resolver.d)
- チェッカー: [tools/vscode-check/main.d](../tools/vscode-check/main.d)、[checkerProtocol.test.js](../editors/vscode-dua/test/checkerProtocol.test.js)
- 実行例: [dub.json](../dub.json)、[source/app.d](../source/app.d)、[README](../README.md)、[入門ガイド](public-guide-ja.md)

## 検証結果

- 変更前: DMDビルド成功、39モジュールの単体テスト成功。
- 各項目: 指定のDMDビルド・テスト成功。
- 最終DMD / LDC: それぞれ41モジュール成功。
- VS Code拡張: 142テスト成功。実際に今回ビルドしたチェッカーを使用。
- 実行例: `Dua result:` を出力し、終了コード0。
- ZsD: 正規ZsDと今回のDuaを依存先にした隔離プロジェクトで、補完の既存自己テスト成功。API・セッション呼出し・旧形式の名前・シーン文脈・保存アセットの非変更・更新/移動/削除を確認。
- 開始時に既に変更されていた19ファイル: SHA256不一致0。

## 互換性と残る範囲

- 公開APIの削除・名称変更、データ形式の移行を伴う変更は行っていない。重複登録は従来どおり拒否する。
- JSONの新たな固定深さ上限は設けていない。循環しない極端に深い入力に対するホストスタックの制約は従来どおり残る。
- 補完JSONの取得時は独立コピーの分だけ確保が増える。ホスト関数・getter・Duaソースを実行して補完データを生成する処理は追加していない。
- Windows上で検証した。Windows以外のOS上の実行はこの作業では行っていない。
