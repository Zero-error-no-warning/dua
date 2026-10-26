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

`dua-language-win32-x64-0.4.1.vsix` を用意し、VS Codeのコマンドパレットで **Extensions: Install from VSIX...** を実行して選択します。必要に応じて **Developer: Reload Window** を実行してください。

コマンドからインストールする場合は、リポジトリのルートで次を実行します。

```powershell
code --install-extension .\editors\vscode-dua\dua-language-win32-x64-0.4.1.vsix
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

alias Fruit = "Apple" | "Orange";
Fruit fruit = "Apple";
Fruit invalid = "Banana"; // 候補にない値を診断
```

`math.` の後に補完を開くと `abs` / `floor` / `min` / `max` を表示します。`func`、`for`、`foreach`、`struct`、`try`、`import`、`instanceimport`、`lambda`、`istr` はスニペットの入力候補です。

## 診断の設定と対応範囲

### nullable配列とハンドル代入（0.6.3）

```dua
int[] array1 = [1, 2, 3];
int[] array2 = [4, 5, 6];
int[] pointArray = null;
pointArray = array1;
pointArray[0] = 9;  // array1の要素も9になる
pointArray = array2; // pointArrayの参照先を変更
```

`T[]`、`V[K]`、汎用`array` / `associativeArray`は既定nullableです。同じ型へ準備済みの配列は要素を共有し、再代入は代入先ハンドルだけを変更します。型付きnull配列/AAはlength=0、foreach=0回。nullと空コンテナは内容比較で等しくなりますが、nullハンドル状態は別に保持され、`is null`で判別できます。Dの一般的な参照同一性演算子を追加するものではありません。汎用`any x=null`やtableのnullへ配列操作を付与しません。

`int[] p;` / `int[string] p;`は直接のnullableコンテナとしてnull初期化できます。非nullableコンテナ・table・型aliasの宣言へ初期値省略を広げません。`T[] & !null`はコンテナ全体、`(T & !null)[]`は要素だけを非nullにします。`int[] p=[null]`は引き続き拒否され、nullable fieldの指定も必須です。

診断には更新したcheckerを使用し、型付きnullから既存配列への代入後も宣言された要素shapeを補完します。補完候補があることは、現在nullのハンドルへの添字アクセスが安全であるという証明ではありません。動的状態の評価はruntimeへ委ねます。

### tableのnullableと明示非nullable（0.6.2）

```dua
table Item { int count; }
Item optional = null;
alias RequiredItem = Item & !null;
RequiredItem required = Item { count = 1 };
(Item & !null)[] elements = [Item { count = 2 }];
Item[] & !null container = [null];
```

宣言済みtableと組込みtableは既定でnullを許可します。`T & !null` はnullだけを除く限定型で、一般の交差型・補集合ではありません。`T!` / `T?` は導入しません。tableや非nullable型の宣言には引き続き初期値が必要で、nullable fieldもinitializer内の指定が必須です（直接のnullable配列/AA宣言については0.6.3の説明を参照）。nullable値から非nullableへの変換は、現在値を確認する明示castが必要です。checkerは`is`分岐による型の絞り込みを追加していません。

補完は元のopaque型IDとnull除外wrapperを保ち、引数・戻り値・field・配列/AA・import型aliasから形状を追跡します。`(T & !null)[]` は非null要素、`T[] & !null` は配列全体への指定です。既存の`&`・`!`・`null`の色分けと型宣言ジャンプを使用します。null可否の診断は同梱の共有checkerへ委ね、補完処理で診断を抑制したり型規則を実行したりしません。動的な値や共有状態には実行時検査が残ります。

### UFCSの括弧省略（0.6.1）

`weapon.doubledDamage` は、受け手一つで呼べる関数なら `weapon.doubledDamage()` と同じ評価になります。既存メンバーが優先され、追加必須引数がある関数や引数数不明の関数は省略式で呼ばれません。`auto f = fn;` / `auto f = module.fn;` は関数値を保ち、明示呼び出しも維持されます。

診断には更新した共有checkerを使用します。補完の式型追跡は、既知のメンバーと引数情報を使い、スカラー・配列/AAなどでUFCS結果を推論します。tableやホスト型は動的メンバーがUFCSを隠せるため、未知メンバーの戻り値を確定しません。補完のために関数を実行することはありません。

### named table生成式（0.6.0）

```dua
table Hoge { int x; string label; }
auto value = Hoge { x = 1, label = "one" };
auto imported = common.Hoge { x = 2, label = "two" };
```

型名、生成式内の未設定field、生成後のメンバーを補完します。import先の型とfieldは共有解析の公開情報を使用し、型名から宣言へジャンプできます。明示したunion配列型と生成値の型IDを補完で保持します。未完の `Hoge {` やfield名も補完できるよう、補完要求だけに仮想本文を使用します。診断は編集本文をそのまま共有解析へ渡します。field名からの定義ジャンプは、解析APIがfield別の宣言位置を持たないため対象外です。

生成先はtable型または単一table aliasです。基底型のfieldも補完し、必須field不足・型不一致・キー重複は共有解析が診断します。追加fieldは許可されますが、宣言のないfield候補は推測しません。型スコープは同名の値変数から独立しています。新構文の値は自型・基底型・そのalias/unionへの適合を保持し、構造が同じ別table型へ再分類されません。無名literalと従来castの互換動作は維持されます。

### ファイルimport（0.5.0）

```dua
import "./types.dua";
import "../common/types.dua" as commonTypes;
commonTypes.ItemKind kind = "weapon";
```

引用符内のパス候補、import先と公開宣言への定義ジャンプ、公開された値・関数・型の補完に対応します。相対パスはimport元ファイルが基点です。型aliasはモジュール別の型IDを保ち、非公開の型名を他ファイルの候補へ追加しません。

`dua.modulePaths` は名前import用の検索パターンを実行側と同じ優先順で指定します。既定は `["?.dua", "?/init.dua"]`。0.5.1以降、検証済みカタログにシーン文脈がある場合は、その `assetDirectory`（例: `sceneItem`）が既定の基点です。複数文脈で共有するスクリプトは各文脈を共有サービスで解析し、一致した結果だけを確定します。設定を明示した場合や文脈がない場合の相対パターンは、VS Codeで開いたワークスペースフォルダーが基点です。引用符付き相対importは引き続きimport元ファイルが基点です。拡張独自のファイル探索・初期化は行いません。

`scenes` などのホストモジュールは、カタログの一覧だけで全exportが判明したとは扱いません。未知のホスト値は未確定として扱い、既知の型不一致とソースモジュールの非公開exportのエラーは維持します。

未保存のDua本文もoverlayとして送り、依存先の編集・移動・削除で再解析します。循環・未発見・型エラーは、返された各ファイルの本文に合わせた位置へ表示します。診断は各本文1MB、open-buffer overlayは合計8MBまでです。信頼されていないワークスペースではサービスを起動しません。`dua.checkerPath`による旧custom checkerはsource-only入力を維持し、新しいimport補完・定義連携を有効にはしません。

| 設定 | 既定値 | 内容 |
|---|---|---|
| `dua.diagnostics.enable` | `true` | 構文・型診断の有効／無効 |
| `dua.diagnostics.delay` | `400` | 入力後に検査するまでの待ち時間（ms） |
| `dua.checkerPath` | 空文字列 | 独自の `dua-check` 実行ファイルの絶対パス。空なら同梱版 |

診断にはDua本体の共有解析を使います。未保存の編集内容とimport元の位置を標準入力で渡し、import先本文も読み取って検査します。スクリプトの初期化・ホスト関数の呼出しは実行しません。入力更新時には古い検査をキャンセルします。

構文・型診断は共有解析が検出したものを表示します。動的なテーブルメンバーや実行時エラーを完全に検証するものではありません。ファイル内の宣言名とローカル変数の型追跡は字句ベースの限定的な補完です。import先は公開宣言と型構造を利用し、任意の制御フローの解析やデバッグには対応しません。

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

## ZsD シーン実行時の診断

ZsD がワークスペース直下の `.dua-diagnostics/<scopeId>.json` に出力する実行結果を監視し、実行時・読込時のエラーを波線と「問題」へ表示します。別ウィンドウのプレビューも同じ経路です。拡張は JSON と本文を非同期で読み、シーンやスクリプト、コマンドを起動しません。

位置は Dua の構造化情報だけを採用し、1始まりの UTF-8 バイト列を VS Code の UTF-16 列へ変換します。実行済み本文の SHA-256 と、開いている文書（未保存の編集を含む）または保存済み本文が一致した場合だけ位置を表示します。位置不明・本文変更・対象外パスは出力 **Dua** だけへ記録します。修正後はシーンを再実行してください。

再実行・成功・停止・シーン切替・通常終了ではその所有者の古い診断を消去します。別シーンや既存の構文診断コレクションは維持します。強制終了・クラッシュ時に残った JSON は、ZsD を閉じた状態で `.dua-diagnostics` を削除できます。アセットディレクトリが設定済みの未保存シーンでは、そのディレクトリから決めたプロジェクトが出力先になります。未設定の場合は出力先が確定するまで連携しません。

プロトコルは `schemaVersion:1`、`producer:"ZsD"`、`scopeId`、`runId`、`sceneId`、`diagnostics` を持つ固定ファイルの原子的な置換です。各診断は `file`、`line`、`column`、`message`、`severity`、実行済み本文の `sourceHash` を持ちます。位置不明は0で、ハッシュ不明の診断は出力だけです。最大128所有者、各256診断、JSON 512KB、本文1MBを上限とし、破損したスナップショットは採用しません。

実行時の位置表示・文書監視はワークスペース内の `.dua` ファイルが対象です。Markdown・JavaScript・ワークスペース外の編集では再読取や診断消去を行いません。`.dua` 以外の診断ソースは Output のみへ記録します。

### with（0.6.4）

table/struct の最上位宣言で共通metaを指定できます。with(target) 式の先頭ドットは対象を参照し、裸の名前は通常解決します。補完は対象の既知メンバーを使い、外側へfallbackしません。checkerはwith外の先頭ドット、未対応の代入左辺、不正な対象を診断します。詳細はリポジトリの docs/with-ja.md を参照してください。



### ホストの添字代入とミニシーンの補完

具体的なDホスト`opIndexAssign`を通常の単一添字代入から呼べます。構文は既存の添字代入のままです。[仕様と対象外](../../docs/native-index-assignment.md)を参照してください。ZsDのMiniStep/miniWhile/miniDoWhile/miniForeachやSceneの処理配列版は、更新した公開登録から生成するホストカタログに含まれます。構文・TextMateの新しいキーワード追加は不要です。実行ファイルに対応するソースでカタログを再生成してください。
