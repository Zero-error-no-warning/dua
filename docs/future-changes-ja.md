# 今後の変更候補

この文書は将来検討する案の記録です。実装予定・採用・時期を約束するものではありません。

## ref 引数（2026-10-23 調査）

**状態：検討候補・実装未決定。現行 Dua には未実装。**

### 目的と現状の代替

配列を仮引数へ渡し、関数内で削除後の配列を再代入しても、呼び出し元の変数は更新されません。D の ref 引数のように、呼び出し元の変数そのものを変更できる機能を検討します。

今回の inventory の用途は、複数 inventory を共有 table のフィールドや外側の配列の要素として保持し、そのフィールド／要素へ更新配列を代入する方法で対応できます。更新配列を返して呼び出し元で受け取る方法もあります。この用途だけで ref の実装が必要と決まったわけではありません。

### 構文案と規模

```dua
// 構文案。現在は実行できません。
void removeItem(ItemInfo item, ref ItemInfo[] inventory, uint N) {
    // inventory への再代入が呼び出し元の変数へ即時に反映される想定。
}
```

- **通常変数限定なら中規模**：ローカル／モジュール／instance の変数名を対象に、ref から別の ref への転送も扱う案。既存の変数解決と代入時検査は利用できますが、値だけを渡す呼び出し経路の変更が必要です。
- **一般的な左辺式や native D 対応まで含めると大規模**：メンバー、配列・連想配列の要素は、receiver／添字の評価回数、再代入・削除後の参照先、getter／setter を定義する必要があります。native D の ref は既存の一時値への変換だけでは対応できません。

### 主な必要変更と注意点

- parser／AST、ラムダ・delegate 型、関数の引数属性、import／export 解析、型検査、補完署名、VS Code 拡張へ ref 情報を保持・伝達する。
- `CallableValue`／`ScriptCallable` と変数束縛に参照引数の経路を追加する。関数変数、モジュール経由、UFCS、実行コンテキストのラッパーでも情報を失わないようにする。
- **変数の別名として即時書き込みする方式を推奨**。終了時のコピー戻しは、同じ変数を二つの引数に渡した場合、例外、再入、Fiber の yield 中に結果が異なるため、D の ref 相当とは区別する。
- **寿命**：裸の `Value*` を保存するだけにしない。所有する環境を保持し、クロージャや Fiber の中断・再開、モジュール終了時の無効化を扱う。
- **型**：一時値や書き込み不可の対象を拒否する。通常の値引数の型変換をそのまま流用せず、呼び出し元と仮引数の双方の型制約を維持する。初期案は解決後の型が一致する変数に限定し、const な参照や変換付き ref は別途検討する。
- **評価順**：現行は実引数を左から右に評価した後で callee／UFCS receiver を評価する。この既存動作を不用意に変えない。
- **性能**：通常の値渡し経路を残し、ref が必要な呼び出しだけ追加処理へ分ける設計は可能。全変数のヒープセル化は必須ではない。ただし分岐や変数アクセスへの影響は実装次第で、性能は未測定。

### 推奨する初期範囲と検証

まずは Dua の通常変数への ref と、その転送・関数変数／import／UFCS 経由の呼び出しを対象にする案です。メンバー・添字、native D バインド／D から呼ぶ callback、ref return、ref の有無だけによる新しいオーバーロードは初期範囲に含めません。既存 native オーバーロード選択の互換性は維持します。

最小検証は、配列再代入、既存値引数、同一変数への複数 ref、ref 転送、評価順、型不一致・一時値拒否、import／UFCS／関数変数、クロージャ・Fiber・モジュール終了時の寿命です。これは今後実装を選んだ場合の検証候補で、今回実施したものではありません。

### 調査時の根拠（リポジトリ相対パス）

- `source/dua/parser.d`：`parseTypedFunctionSignature`、`parseTypedLambdaParameters`、`parseTypeName`。`source/dua/ast.d`：引数名・型の保持。
- `source/dua/evaluator.d`：`evaluateExpressionList`、`evaluateCall`、`invokeFunctionValue`、`Environment.findBinding`／`assignBinding`、`assignTarget`。`source/dua/scope_layout.d`：変数検索キャッシュ。
- `source/dua/runtime.d`：`ScriptCallable.invokeBody` の新しい関数環境と値による仮引数束縛。`source/dua/value.d`：`CallableValue` と native 引数の変換用一時値。
- `source/dua/coroutine.d`、`source/dua/module_system.d`：Fiber／モジュールの寿命と実行コンテキスト。
- `source/dua/typecheck.d`、`source/dua/module_analysis.d`、`source/dua/completion.d`、`editors/vscode-dua/hostCompletion.js`、`language.js`、`syntaxes/dua.tmLanguage.json`：解析・診断・補完・表示。
