module dua.switch_typecheck_tests;

version(unittest):
import dua;
import std.algorithm : canFind;

unittest
{
    auto engine = new ScriptEngine;
    foreach (source; [
        "switch(2){case 1: int x=\"wrong\";}",
        "switch(1){case 1: break; default: int x=\"wrong\";}",
        "switch(1){case 1: int n=1; n=\"wrong\";}",
        "int f(){switch(1){case 1: return 1; default: return \"wrong\";}}",
        "switch(2){case 1: switch(0){default: int x=\"wrong\";}}",
        "switch(2){case 1: if(false){int x=\"wrong\";} else {int y=\"wrong\";}}",
        "switch(2){case 1: void f(int n){} f(\"wrong\");}",
        "int f(int n){return n;} switch(f(\"wrong\")){case 0: break;}",
        "int f(int n){return n;} switch(0){case f(\"wrong\"): break;}"
    ])
    {
        assert(engine.check(source).length > 0, source);
        RunOptions checked; checked.typeCheck = true;
        assert(!engine.runSafe(source, checked).ok, source);
    }

    // 本体の連続した文で型を引き継ぎ、兄弟caseや外側の同名宣言を汚しません。
    auto scoped = q{
        int n=7; int convert(int value){return value;}
        switch(2){
            case 1: string n="local"; string convert(string value){return value;}
                string s=convert(n); break;
            case 2: int result=convert(n); break;
            default: bool n=true; bool convert(bool value){return value;}
                bool b=convert(n);
        }
        int after=convert(n); return after;
    };
    assert(engine.check(scoped).length == 0);
    RunOptions checked; checked.typeCheck = true;
    assert(engine.run(scoped, checked).to!int == 7);
    // 異なる型のcase値の比較可否・breakやreturnの実行規則は変更しません。
    assert(engine.run(q{switch(2){case "2": return 0; case 2: return 9; default: return 1;}}, checked).to!int == 9);
    assert(engine.check(q{if(false){int x="wrong";} while(false){int x="wrong";}}).length == 2);
}

unittest
{
    auto engine = new ScriptEngine;
    auto source = "touch();\nswitch(2){\ncase 1:\n  int x=\"wrong\";\n}\n";
    int calls;
    engine.bindFunc("touch", () { ++calls; });
    auto diagnostics = engine.check(source, "switch-regression.dua");
    assert(diagnostics.length == 1);
    assert(diagnostics[0].line == 4 && diagnostics[0].column == 3);
    assert(diagnostics[0].message.canFind("expects int"));
    assert(calls == 0);
    RunOptions options; options.typeCheck = true; options.sourceName = "switch-regression.dua";
    auto rejected = engine.runSafe(source, options);
    assert(!rejected.ok && calls == 0, "事前診断は実行の副作用より前に失敗する");
    options.typeCheck = false;
    assert(engine.runSafe(source, options).ok && calls == 1, "未選択caseの実行時チェックは走らない");
    auto selected = engine.runSafe(q{switch(1){case 1: int x="wrong";}}, options);
    assert(!selected.ok, "選択caseの既存実行時チェックは維持する");
}
