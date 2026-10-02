# モジュールのインスタンス化

リポジトリのルートを作業ディレクトリにして、D のホストから実行します。
`actor/init.dua` は既存のフォルダモジュール解決を利用しています。

```d
import dua;
import std.stdio : writeln;

auto engine = new ScriptEngine();
engine.run(q{
    package.path = ["examples/module-instances/?.dua",
                    "examples/module-instances/?/init.dua"];
});
writeln(engine.runFile("examples/module-instances/main.dua").toHostString());
// [90, 80, 100, 30, 5, 0, 80, 80]

auto actor = engine.loadModule("actor"); // import と同じ既定の実体
auto another = actor.instantiate();     // Dua の new Actor と同じ処理
auto enemy = engine.instantiateModule("actor");
another.call("damage", [Value.from(7)]);
assert(another.call("health").toInt() == 93);
assert(enemy.call("health").toInt() == 100);
assert(actor.call("total").toInt() == 37);
```

通常変数 `totalDamage` は共有され、`hp` と `movement` は実体ごとに独立します。
初期化式を再評価するので、既定の実体へのダメージは新しい実体へコピーされません。
この使用例は `module_instance_tests.d` からも実行されます。
