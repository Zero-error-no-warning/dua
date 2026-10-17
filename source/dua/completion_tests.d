module dua.completion_tests;

version (unittest):
import dua;
import std.json;

private int calls;
private class HostFixture
{
    int count;
    private int secret;
    @property int expensive() { ++calls; return 1; }
    void move(double x, double y = 0) { ++calls; }
    private void internalOnly() { ++calls; }
    static int maxCount() { ++calls; return 100; }
}
private HostFixture loadFixture(string path) { ++calls; return new HostFixture; }

private struct CompletionVec { double x; double y; }
private CompletionVec makeVec() { ++calls; return CompletionVec(1, 2); }
private class RawCompletionFixture { Value echo(Value input){ return input; } }

private struct CallableSelf { CallableSelf opCall(CallableSelf input){ return input; } }
private struct CallableLeft { CallableRight opCall(){ return CallableRight.init; } }
private struct CallableRight { CallableLeft opCall(){ return CallableLeft.init; } }
private CallableSelf makeCallableSelf(){ assert(false,"Host factory must not run during registration"); }
private CallableLeft makeCallableLeft(){ assert(false,"Host factory must not run during registration"); }

unittest
{
    foreach(metadata;[false,true])
    {
        auto engine = new Dua.ScriptEngine;
        if(metadata)engine.enableCompletionMetadata(true);
        engine.bindFunc!makeCallableSelf("makeCallableSelf");
        engine.bindFunc!makeCallableLeft("makeCallableLeft");
        engine.bindFunc("callable",CallableSelf.init);
        if(metadata)
        {
            auto types = engine.completionRegistry.toJson()["types"].object;
            foreach(name;["CallableSelf","CallableLeft","CallableRight"])
                assert(name in types,"Missing callable aggregate: " ~ name);
        }
    }
}

unittest
{
    auto engine = new Dua.ScriptEngine;
    engine.enableCompletionMetadata(true);
    engine.bindFunc("rawIdentity", (Value input) => input);
    auto data = engine.completionRegistry.toJson();
    assert(data["symbols"]["rawIdentity"]["signatures"].array[0]["parameters"].array[0]["type"].str == "any");
    assert(engine.run(`return rawIdentity("raw\path");`).to!string == `raw\path`);
    assert(engine.run(`return rawIdentity({name=42}).name;`).to!int == 42);
    auto reflected = Value.reflect(new RawCompletionFixture);
    engine.bind("extracted",reflected["echo"]);
    assert(engine.run(`return extracted("method");`).to!string == "method");
}

unittest
{
    auto engine = new Dua.ScriptEngine;
    engine.enableCompletionMetadata(true);
    engine.bindFunc!makeVec("makeVec");
    auto data = engine.completionRegistry.toJson();
    assert(data["symbols"]["makeVec"]["signatures"].array[0]["returnType"].str == "CompletionVec");
    assert("CompletionVec" in data["types"].object, "Struct return type was omitted");
    assert("x" in data["types"]["CompletionVec"]["members"].object);
    assert(calls == 0);
}

unittest
{
    auto engine = new Dua.ScriptEngine;
    engine.enableCompletionMetadata(true);
    engine.bindFunc!loadFixture("loadFixture");
    engine.bindType!HostFixture("Host");
    auto moduleHandle = engine.newModule("host");
    moduleHandle.bindFunc!((double amount) => amount * 2)("twice");
    engine.bind("aliasLoad", engine["loadFixture"]);
    auto data = engine.completionRegistry.toJson();
    assert(calls == 0, "Export must never invoke host functions or getters");
    auto signature = data["symbols"]["loadFixture"]["signatures"].array[0];
    assert(signature["returnType"].str == "HostFixture");
    assert(signature["parameters"].array[0]["name"].str == "path");
    assert(data["symbols"]["aliasLoad"]["signatures"].array.length == 1);
    assert(data["symbols"]["host.twice"]["signatures"].array.length == 1);
    auto members = data["types"]["HostFixture"]["members"];
    assert("count" in members.object);
    assert("secret" !in members.object && "internalOnly" !in members.object);
    assert(members["move"]["signatures"].array[0]["parameters"].array[1]["optional"].boolean);
    assert(data["symbols"]["Host.maxCount"]["signatures"].array.length == 1);
    assert(calls == 0);
}
