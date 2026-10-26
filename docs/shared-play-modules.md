# 同一Play内のモジュール共有

同一Play内のExternalSceneは一つのScriptEngineを使います。同じ解決済みファイルの通常変数と解析済みモジュール定義を共有し、別Play・別プレビューとは共有しません。

```dua
import scenes;
int total = 0;                       // 同じファイルを使う実体間で共有
instance int local = 0;              // Scene割当ごとに独立
instance auto ownRoot = scenes.root; // 所属するExternalSceneの内容ルート

export void increment() {
    total += 1;
    local += 1;
}
```

`import scenes;` の構文はそのままです。各スクリプトとそこからimportしたhelperの関数は、所属する内容の `scenes.root` と所有Sceneの `self` を使います。callbackは作成元の文脈を保持し、別の実体から呼んだ場合やFiberのyield・再開後にも混線しません。相対パスimportはソースファイルから、名前importは所属するシーンの検索パスから解決し、通常変数の共有単位は最終的に解決されたcanonical pathです。

通常変数の初期化は最初の読込み時に一度だけ実行します。そこで `self`、`scenes`、Scene固有のオブジェクトやcallbackを保存すると、最初の実体の値を共有します。各実体に必要な参照・状態には `instance` を使ってください。たとえば `auto fn = helper.callback;` も最初の関数参照を共有します。関数を毎回各文脈から選びたい場合は `helper.callback()` と呼ぶか、参照変数を `instance` にします。

外部シーン終了時は利用者のonExitと子の終了を先に実行し、それから所属する文脈を閉じます。閉じた文脈のcallback/coroutineは再実行できません。他の外部シーンと共有通常変数はPlay終了まで継続します。通常変数に保存した最初の実体のcallbackが自動的に別実体へ移ることはありません。

exportの仕様は変更しません。値はexport時のスナップショットです。table/配列は同じ参照先への変更が見えますが、モジュール内変数への再代入とexportスロットの置換は別です。

ホスト側では `createModuleContext`、`bindContext`、`newContextModule`、`instantiateModule(name, context)` を使えます。共有定義・通常変数から文脈ごとの名前空間を分離し、関数呼出しとFiberごとの評価状態で文脈を保持します。実行ごとにグローバルなscenesやpackage.pathを差し替える方式ではありません。

検証: Duaの `tests/play_context` とZsDの `tests/shared_play`。描画・音声・OS入力を初期化しない限定テストです。性能の数値的な改善は測定していません。
