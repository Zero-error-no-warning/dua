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
