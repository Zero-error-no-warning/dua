module dua.runtime_default_tests;

version (unittest):

import dua;

private int currentDefault = 17;
private int defaultCalls;
private int nextDefault() { ++defaultCalls; return currentDefault; }

private int dynamicDefault(int value = nextDefault()) { return value; }
private string dynamicDefault(string text) { return text; }
private int collide(int duaDefaultArgs = nextDefault(), int duaDefaultValue = nextDefault())
{
    return duaDefaultArgs + duaDefaultValue;
}
private int lazyDefault(lazy int value = nextDefault()) { return value; }

private struct LiveDefaults
{
    int value;
    this(bool enabled, int value = nextDefault()) { this.value = value; }
    int read(int value = nextDefault()) { return value; }
    static int readStatic(int value = nextDefault()) { return value; }
}

private class LiveDefaultClass
{
    int value;
    this(int value = nextDefault()) { this.value = value; }
    int read(int value = nextDefault(), string origin = __FILE__, int line = __LINE__)
    {
        assert(origin == "dynamic.dua" && line > 0);
        return value;
    }
}

unittest
{
    currentDefault = 17;
    defaultCalls = 0;
    auto engine = new Dua.ScriptEngine();
    engine.bindFunc!dynamicDefault("dynamicDefault");
    engine.bindFunc!collide("collide");
    engine.bindFunc!lazyDefault("lazyDefault");
    assert(defaultCalls == 0); // 登録時には状態を読まず、副作用を起こしません。
    assert(engine.run("return dynamicDefault();").toInt() == 17);
    assert(defaultCalls == 1);
    currentDefault = 29;
    assert(engine.run("return dynamicDefault();").toInt() == 29);
    assert(engine.run("return dynamicDefault(7);").toInt() == 7);
    assert(engine.run(`return dynamicDefault("text");`).toHostString() == "text");
    assert(defaultCalls == 2);
    engine.bindAuto("reader", LiveDefaults.init);
    engine.bindType!LiveDefaults("LiveDefaults");
    engine.bindType!LiveDefaultClass("LiveDefaultClass");
    assert(engine.run("return collide();").toInt() == 58);
    assert(engine.run("return collide(3);").toInt() == 32);
    assert(engine.run("return lazyDefault();").toInt() == 29);
    assert(engine.run("return reader.read();").toInt() == 29);
    assert(engine.run("return LiveDefaults.readStatic();").toInt() == 29);
    assert(engine.run("return LiveDefaults(true).value;").toInt() == 29);
    auto options = Dua.RunOptions.init;
    options.sourceName = "dynamic.dua";
    assert(engine.run("auto item = LiveDefaultClass(); return item.read();", options).toInt() == 29);
    currentDefault = 17;
}
