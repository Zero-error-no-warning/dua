# 明示的フレームによるコルーチン

`coroutine.create` は実行を開始せず、`resume` で普通の関数を進めます。
`yield` 文は入れ子のDua関数の中でも使えます。中断時のローカル変数、
呼出し途中の式、ループ、クロージャ、try/catchはheap上の実行フレームに保持します。
Dの `Fiber` をコルーチンごとに生成しません。新しいキーワードはありません。

```dua
int attack(int power) {
    yield power;
    return power + 1;
}
auto co = coroutine.create(() {
    int total = 0;
    for (auto i = 0; i < 3; i += 1) total += attack(i);
    return total;
});
auto first = coroutine.resume(co); // [true, 0]
auto next = coroutine.resume(co);  // [true, 1]
```

既存の戻り値を保持します。`resume` は成功時 `[true, 値...]`、失敗時
`[false, message]`。`status` は `suspended` / `running` / `dead` です。
正常終了と失敗は `resume` のboolで区別します。実行中の同じコルーチンの
再開は失敗を返し、終了済みの実行は復活しません。

任意の同期DコールバックのDスタックを保存することはできません。
例えば標準 `map` / `filter` のコールバック内の `yield` は
`Cannot yield across a synchronous native callback boundary` になります。
同期Dで実装された型生成・メンバー既定値・モジュールロードからの再入も同じ制約です。
`coroutine.isyieldable()` はその同期コールバック内でfalseを返します。
通常のDuaの関数呼出しや、Duaで書いたループを使えば中断できます。

ModuleContextを閉じると停止中の実行フレームを解放し、それ以降の再開を拒否します。
閉じた実行の続きを再生してcatch等を実行する契約はありません。
ZsDのDネイティブMiniFiber用に存在するFiber別評価文脈は維持しています。

実装は `coroutine.d`（寿命・再開）、`coroutineExecution.d`（文と実行フレーム）、
`coroutineExpressions.d`（式・代入）、`coroutineCalls.d`（関数・lazy）に分けています。
`coroutine_tests.d` が評価順、短絡、入れ子・再帰、引数、代入対象、制御構文、
例外・制限、メタメソッド、ModuleContext独立性、同期native境界を検証します。

## 比較計測

2026-11-02、Windows x64、DMD 2.113、`-O -release`。
256個の同一関数を生成し、各8回yieldする処理を3回ずつ別プロセスで実行。
計測区間は生成、最初のyieldまで、残りを正常終了まで再開する区間です。
単位は全256個分のms、表は中央値です。

| 区間 | 旧D Fiber | 明示的フレーム |
|---|---:|---:|
| 生成 | 1.303 | 0.429 |
| 初回中断まで | 8.623 | 3.702 |
| 残りの再開から終了まで | 15.396 | 18.691 |

初回中断時の増分はワーキングセット約20.7 MB→約7.4 MB、
Windows PrivateUsage約278 MB→約7.7 MBです（10進MB、生成前との差）。
旧設定は1個につき1 MiBのFiberスタックでしたが、この設定容量をRSSとは呼びません。
新方式はDのGC上の一時割当が増え、繰り返し再開の区間はこの条件では遅くなりました。
これは小さい合成ケースの結果で、ZsD全体や制作ゲームの速度保証ではありません。

最終ZsD接続修正後のソースで再計測しました。ウォームアップなし、基準版は先に、
最終版は候補ビルドのコンパイラ終了後に測定しています。3回の範囲は生成
1.300–1.343→0.424–0.443 ms、初回8.568–8.867→3.572–3.933 ms、
残り15.346–16.018→18.383–24.140 msです。3標本なのでp95は出しません。
release比較ハーネス内のassertは無効で、意味の検証は別の単体・接続試験で行っています。

## 対応範囲と終了処理

現在のASTの全Statement/Expression種別を明示的な分岐で扱います。式の評価途中、
短絡、三項、通常/既定/lazy引数、代入対象、配列・table・AA、再帰、if/for/while/foreach、
switch、break/continue、return、クロージャ、try/catch、Duaのメタメソッドを保持します。
宣言の登録、型の構築・検証、モジュール初期化などの既存同期処理はnative境界です。
そこからDuaへ再入してyieldすることは対応しません。未対応の中断を旧Fiberへ戻す経路はありません。

`map` / `filter` / `pcall` / `xpcall` がDから呼び出す関数内のyieldも同じ制限です。
pcall系は境界エラーを通常の失敗結果にできますが、中断・再開には変わりません。
この制限は実行時のもので、静的診断が任意のcallbackの中断可能性を証明するわけではありません。
Duaのtry/catchなら中断を保持できます。例外時は実行フレームの評価文脈を復元し、
catchまたは既存のresume失敗結果へ渡します。実行制限エラーは従来どおりcatchできません。

ZsDではDua関数を渡す `self.miniScene(() { ... });` が軽量経路です。
`self.yields()` / `self.waitNsecs(seconds)` を呼出し先の普通のDua関数に書けます。
内部の `coroutineInterop.d` は既知の待機と反射結果ラッパーだけを中断可能として扱います。
任意のD delegateの中身を継続へ変換するものではありません。

停止は既存Sceneの `exit()` を使います。停止中はフレーム参照を捨てて以後再開せず、
実行中の自己exitは次のyield/returnまで処理した後で捨てます。
`onExit` / `miniExit` は従来の一回の通知です。停止したコードのcatchやDのscope(exit)を
後から実行する保証、新しいcancel APIはありません。FreeListのMiniFiber禁止も維持します。
D delegate版MiniFiberとMiniStep配列は既存経路を維持します。配置Dua MiniSceneも軽量実行に統一しました。
配置側では関数定義元のModuleContextをpackage内bridgeで取得し、同じ寿命に所属させます。

## 検証とエディタ

2026-11-02: DMD 2.113の `dub build --compiler=dmd` と `dub test --compiler=dmd`
が成功（30 modules）。ZsDの全体試験は配置ノード回帰を加えてDMD -lowmemで91 modules成功。
LDC 1.43の接続試験はbase/derived/UI/取り出したminiSceneメソッドでD Fiberなしを確認し、
Dの既定8ページ・直接4ページを維持し、文書配置Duaノードも子関数yieldをD Fiberなしで実行します。

キーワードと公開coroutine APIは変えていないのでVSCodeの文法更新は不要です。
既存拡張の121テストと、新ソースから別途ビルドした診断器の5条件が成功しました。
後者は入れ子yield、Scene待機、callback境界コード、関数内型エラー、日本語/絵文字の位置を
既存診断器と比較しています。拡張の再インストール、バンドル診断器の差替え、再読込はしていません。

配置ノードの統一では保存形式・D native APIは変更していません。上記の比較計測はDua単体の合成ケースであり、配置ノード固有の速度計測ではありません。
