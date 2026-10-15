module dua.function_overload_tests;

version (unittest):

import dua;
import std.algorithm : canFind;

private string describe(long value) { return "integer"; }
private string describe(double value) { return "floating"; }
private string describe(string value) { return "string"; }
private string describe(long a, long b) { return "pair"; }
private string describe() { return "empty"; }
private string ambiguous(int value) { return "signed"; }
private string ambiguous(uint value) { return "unsigned"; }
private string numeric(long value) { return "integer"; }
private string numeric(double value) { return "floating"; }
private string defaults(long value = 42) { return "default"; }
private string defaults(string value, long count = 1) { return "text"; }
private string callback(int delegate(int) f) { return "integer callback"; }
private string callback(double delegate(double) f) { return "floating callback"; }
private string textOrGraph(string text, long style = 0, double height = 15) { return text; }
private string textOrGraph(double delegate(double) f, double height = 15) { return "graph"; }
private string graphOnly(double delegate(double) f) { return "graph"; }

unittest
{
    auto engine = new Dua.ScriptEngine();
    engine.bindFunc!describe("describe");
    engine.bindFunc!ambiguous("ambiguous");
    engine.bindFunc!numeric("numeric");
    engine.bindFunc!defaults("defaults");
    engine.bindFunc!callback("callback");
    engine.bindFunc!textOrGraph("textOrGraph");
    engine.bindFunc!graphOnly("graphOnly");
    assert(engine.run(q{
        return describe() == "empty" && describe(1) == "integer"
            && describe(1.5) == "floating" && describe("1") == "string"
            && describe(1, 2) == "pair" && defaults() == "default"
            && defaults("hi") == "text";
    }).truthy());
    // 既存の文字列化は維持し、実際の関数はdelegate候補へ優先します。
    assert(engine.run(q{
        auto calls = 0;
        auto f = (double x) { calls += 1; return x; };
        return textOrGraph(42) == "42" && textOrGraph(1.5) == "1.5"
            && textOrGraph(true) == "true" && textOrGraph("text") == "text"
            && textOrGraph(f) == "graph" && textOrGraph(f, 20) == "graph"
            && calls == 0;
    }).truthy());
    foreach(source; ["return describe(1, 2, 3);", "return numeric(true);",
        "return numeric([]);", "return numeric(null);"])
    {
        auto result = engine.runSafe(source);
        assert(!result.ok && result.errorMessage.canFind("no overload matching"), source);
    }
    // Duaのintはlong。int/uintの狭め変換やdelegateの引数型は推測で決めません。
    foreach(source; ["return ambiguous(1);", "return callback((double x) => x);"])
    {
        auto result = engine.runSafe(source);
        assert(!result.ok && result.errorMessage.canFind("multiple matching overloads"), source ~ ": " ~ result.errorMessage);
    }
    assert(!engine.runSafe("return graphOnly(42);").ok);
}
