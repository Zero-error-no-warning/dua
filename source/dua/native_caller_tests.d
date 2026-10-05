module dua.native_caller_tests;

version (unittest):

import dua;
import dua.native_defaults;
import std.traits : ParameterDefaults;
import std.exception : assertThrown;
import std.conv : to;

private struct Received
{
    int argument;
    string moduleName;
    string sourceName;
    int line;
}

private class Recorder
{
    Received[] received;

    int record(int argument, string arbitrary = __MODULE__,
        string source = __FILE__, int number = __LINE__)
    {
        received ~= Received(argument, arbitrary, source, number);
        return argument;
    }

    void action(double interval, void delegate() callback,
        string arbitrary = __MODULE__, int number = __LINE__)
    {
        callback();
        received ~= Received(cast(int) interval, arbitrary, "", number);
    }

    Value defaults(int argument = 17, string text = "__MODULE__", int number = 42,
        string complex = __MODULE__ ~ ".suffix", int compound = __LINE__ + 5)
    {
        return Value.from([Value.from(argument), Value.from(text), Value.from(number),
            Value.from(complex), Value.from(compound)]);
    }

    int overloaded(int argument, string origin = __MODULE__, int number = __LINE__)
    {
        received ~= Received(argument, origin, "", number);
        return argument;
    }
    string overloaded(string argument, string origin = __MODULE__, int number = __LINE__)
    {
        received ~= Received(-1, origin, "", number);
        return argument;
    }

    static long variadic(long initial, long[] rest...) { foreach (item; rest) initial += item; return initial; }
    bool boolean(bool value) { return value; }
    const(bool) constBoolean(bool value) { return value; }
    immutable(bool) immutableBoolean(bool value) { return value; }
}

private class Scene : Recorder {}

private struct RecorderProxy
{
    Recorder target;
    alias target this;
}

private struct StructLocator
{
    Value location(int argument, string origin = __MODULE__,
        string source = __FILE__, int position = __LINE__)
    {
        return locate(argument, origin, source, position);
    }
}

private class ConstructedLocator
{
    private Value stored;
    Value received() { return stored; }
    this(int argument, string origin = __MODULE__, string source = __FILE__, int position = __LINE__)
    {
        stored = locate(argument, origin, source, position);
    }
    static Value location(int argument, string origin = __MODULE__,
        string source = __FILE__, int position = __LINE__)
    {
        return locate(argument, origin, source, position);
    }
}

private Value overloadedLocation(int argument, string origin = __MODULE__,
    string source = __FILE__, int position = __LINE__)
{
    return locate(argument, origin, source, position);
}
private Value overloadedLocation(string argument, string origin = __MODULE__,
    string source = __FILE__, int position = __LINE__)
{
    return locate(-1, origin, source, position);
}

private Value normalizedLocation(int argument, string origin = (__MODULE__),
    string source = (__FILE__), int position = cast(int)__LINE__)
{
    return locate(argument, origin, source, position);
}

private Value locate(int argument = 11, string differentName = __MODULE__,
    string differentFile = __FILE__, int differentLine = __LINE__)
{
    return Value.from([Value.from(argument), Value.from(differentName),
        Value.from(differentFile), Value.from(differentLine)]);
}

private void expectLocation(Value result, int argument, string moduleName, string source, int line)
{
    auto values = result.arrayValue;
    assert(values[0].toInt() == argument);
    assert(values[1].stringValue == moduleName, values[1].toHostString());
    assert(values[2].stringValue == source, values[2].toHostString());
    assert(values[3].toInt() == line, values[3].toHostString());
}

unittest
{
    // Verify the target compiler and the actual declaration/getOverloads path.
    alias FunctionType = typeof(locate);
    static if (is(FunctionType TypedParams == __parameters))
    {
        // Preserve syntax before passing it to a template: DMD canonicalizes
        // types used as template arguments and may discard their defaults.
        static assert(detectLocationDefault(TypedParams[1 .. 2].stringof) == LocationDefault.moduleName);
        static assert(detectLocationDefault(TypedParams[2 .. 3].stringof) == LocationDefault.sourceName);
        static assert(detectLocationDefault(TypedParams[3 .. 4].stringof) == LocationDefault.line);
    }
    static foreach (method; __traits(getOverloads, Scene, "record", true))
    {
        static assert(parameterLocationDefault!(method, 1) == LocationDefault.moduleName);
        static assert(parameterLocationDefault!(method, 2) == LocationDefault.sourceName);
        static assert(parameterLocationDefault!(method, 3) == LocationDefault.line);
        static if (is(typeof(method) P == __parameters))
        {
            static assert(detectLocationDefault(P[1 .. 2].stringof) == LocationDefault.moduleName);
            static assert(detectLocationDefault(P[2 .. 3].stringof) == LocationDefault.sourceName);
            static assert(detectLocationDefault(P[3 .. 4].stringof) == LocationDefault.line);
        }
        else static assert(0, "D compiler must retain parameter syntax");
    }
}

unittest
{
    auto engine = new ScriptEngine();
    auto scene = new Scene();
    engine.bindAuto("scene", scene);
    RunOptions options;
    options.sourceName = "calls.dua";
    engine.run("scene.record(1);\nscene.record(2);\n"
        ~ "for (auto i = 0; i < 3; i += 1) {\nscene.record(i);\n}", options);
    assert(scene.received == [Received(1, "<global>", "calls.dua", 1),
        Received(2, "<global>", "calls.dua", 2),
        Received(0, "<global>", "calls.dua", 4),
        Received(1, "<global>", "calls.dua", 4),
        Received(2, "<global>", "calls.dua", 4)]);
    engine.run(`scene.record(3, "explicit", "manual.dua", 123);`);
    engine.run(`scene.record(4, "explicit");`);
    engine.run(`scene.record(5, "explicit", "manual.dua");`);
    assert(scene.received[5] == Received(3, "explicit", "manual.dua", 123));
    assert(scene.received[6] == Received(4, "explicit", "<global>", 1));
    assert(scene.received[7] == Received(5, "explicit", "manual.dua", 1));
    assertThrown(engine.run("scene.record();"));
    assertThrown(engine.run("scene.record(1, 2, 3, 4, 5);"));
    auto callable = engine["scene"].tableValue["record"].functionValue;
    assert(callable.minimumArity() == 1 && callable.maximumArity() == 4);
    callable.invoke([Value.from(9)]);
    alias Defaults = ParameterDefaults!(Recorder.record);
    assert(scene.received[$ - 1] == Received(9, Defaults[1], Defaults[2], Defaults[3]));
}

unittest
{
    auto engine = new ScriptEngine();
    engine.bindFunc!locate("locate");
    expectLocation(engine.run("return locate();"), 11, "<global>", "<global>", 1);
    expectLocation(engine.run("\nreturn locate(2);"), 2, "<global>", "<global>", 2);
    auto host = engine.newModule("host.scope");
    host.bindFunc!locate("locate");
    expectLocation(host.run("return locate(3);"), 3, "host.scope", "host.scope", 1);
    RunOptions options;
    options.sourceName = "host-source.dua";
    expectLocation(host.run("return locate(4);", options), 4, "host.scope", "host-source.dua", 1);
    alias Defaults = ParameterDefaults!locate;
    expectLocation(engine["locate"].functionValue.invoke([]), Defaults[0], Defaults[1], Defaults[2], Defaults[3]);
    expectLocation(engine.call("locate"), Defaults[0], Defaults[1], Defaults[2], Defaults[3]);
    // A runtime pointer loses declaration defaults in D; keep its prior arity.
    engine.bindFunc("runtimeLocate", &locate);
    assertThrown(engine.run("return runtimeLocate(5);"));
    expectLocation(engine.run(`return runtimeLocate(5, "explicit", "manual", 42);`),
        5, "explicit", "manual", 42);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.bindFunc!overloadedLocation("overloadedLocation");
    expectLocation(engine.run("return overloadedLocation(3);"), 3, "<global>", "<global>", 1);
    expectLocation(engine.run("\nreturn overloadedLocation(\"text\");"), -1, "<global>", "<global>", 2);
    engine.bindFunc!normalizedLocation("normalizedLocation");
    expectLocation(engine.run("\nreturn normalizedLocation(2);"), 2, "<global>", "<global>", 2);
    engine.bindType!ConstructedLocator("Locator");
    static foreach (ctor; __traits(getOverloads, ConstructedLocator, "__ctor"))
    {
        auto direct = makeReflectedConstructor!(ctor, ConstructedLocator)("direct");
        assert(direct.invoke([Value.from(1)]).to!ConstructedLocator() !is null);
    }
    expectLocation(engine.run("\nreturn Locator.location(4);"), 4, "<global>", "<global>", 2);
    expectLocation(engine.run("\nreturn Locator(5).received;"), 5, "<global>", "<global>", 2);
    expectLocation(engine.run(`return Locator(6, "manual").received;`), 6, "manual", "<global>", 1);
    expectLocation(engine.run(`return Locator(7, "manual", "explicit", 91).received;`),
        7, "manual", "explicit", 91);
    engine.bindAuto("structLocator", StructLocator());
    expectLocation(engine.run("\nreturn structLocator.location(8);"), 8, "<global>", "<global>", 2);
    auto target = new Recorder();
    engine.bindAuto("proxy", RecorderProxy(target));
    engine.run("\nproxy.record(9);");
    assert(target.received == [Received(9, "<global>", "<global>", 2)]);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.bindFunc!locate("locate");
    engine.registerModule("first.module", "export any call() {\nreturn locate(1);\n}");
    engine.registerModule("second.module", "\nexport any call() {\nreturn locate(2);\n}");
    auto results = engine.run("import first.module as A; import second.module as B;\n"
        ~ "auto fresh = new A;\nreturn [A.call(), B.call(), fresh.call()];").arrayValue;
    expectLocation(results[0], 1, "first.module", "first.module", 2);
    expectLocation(results[1], 2, "second.module", "second.module", 3);
    expectLocation(results[2], 1, "first.module", "first.module", 2);
    auto instance = engine.instantiateModule("first.module");
    expectLocation(instance.call("call"), 1, "first.module", "first.module", 2);
    expectLocation(instance.run("\nreturn locate(6);"), 6, "first.module", "first.module", 2);
    // Captured closures keep their definition's origin when called elsewhere.
    engine.registerModule("closure.module", "export any make() {\nreturn () => locate(7);\n}");
    expectLocation(engine.run(`auto f = require("closure.module").make(); return f();`),
        7, "closure.module", "closure.module", 2);
}

unittest
{
    import std.file : write, remove, exists;
    enum path = "__dua_native_callsite_test.dua";
    assert(!exists(path));
    scope(exit) if (exists(path)) remove(path);
    auto engine = new ScriptEngine();
    engine.bindFunc!locate("locate");
    write(path, "\nreturn locate(4);");
    expectLocation(engine.runFile(path), 4, "<global>", path, 2);
    write(path, "export any call() {\nreturn locate(8);\n}");
    auto fileModule = engine.loadModuleFile(path);
    expectLocation(fileModule.call("call"), 8, path, path, 2);
    // Imported name and the resolved file name are distinct.
    engine.run(`package.path = ["__dua_?_callsite_test.dua"];`);
    expectLocation(engine.loadModule("native").call("call"), 8, "native", path, 2);
    expectLocation(engine.instantiateModule("native").call("call"), 8, "native", path, 2);
}

unittest
{
    auto engine = new ScriptEngine();
    auto scene = new Scene();
    engine.bindAuto("scene", scene);
    auto result = engine.run("scene.overloaded(3);\nreturn scene.overloaded(\"text\");");
    assert(result.stringValue == "text");
    assert(scene.received == [Received(3, "<global>", "", 1),
        Received(-1, "<global>", "", 2)]);
    auto ordinary = engine.run("return scene.defaults();").arrayValue;
    alias Defaults = ParameterDefaults!(Recorder.defaults);
    assert(ordinary[0].toInt() == 17 && ordinary[1].stringValue == "__MODULE__");
    assert(ordinary[2].toInt() == 42 && ordinary[3].stringValue == Defaults[3]);
    assert(ordinary[4].toInt() == Defaults[4]);
    assert(engine.run("return scene.variadic(1, 2, 3);").toInt() == 6);
    assert(engine.run("return scene.variadic(7);").toInt() == 7);
}

unittest
{
    auto engine = new ScriptEngine();
    auto scene = new Scene();
    engine.bindAuto("scene", scene);
    RunOptions options;
    options.sourceName = "nested.dua";
    engine.run("scene.record(\nscene.record(1));\n"
        ~ "scene.action(0.5, () {\nscene.record(2);\n});\nscene.record(3);", options);
    assert(scene.received == [Received(1, "<global>", "nested.dua", 2),
        Received(1, "<global>", "nested.dua", 1),
        Received(2, "<global>", "nested.dua", 4),
        Received(0, "<global>", "", 3),
        Received(3, "<global>", "nested.dua", 6)]);
    // Re-enter the same engine from native code; outer arguments stay local.
    engine.bindFunc("reenter", (void delegate() callback) {
        RunOptions inner;
        inner.sourceName = "inner.dua";
        engine.run("scene.record(8);", inner);
        callback();
        scene.record(10); // No script caller: retain D defaults.
    });
    engine.run("reenter(() {\nscene.record(9);\n});\nscene.record(11);", options);
    assert(scene.received[5] == Received(8, "<global>", "inner.dua", 1));
    assert(scene.received[6] == Received(9, "<global>", "nested.dua", 2));
    assert(scene.received[7].moduleName == __MODULE__);
    assert(scene.received[7].sourceName == __FILE__);
    assert(scene.received[8] == Received(11, "<global>", "nested.dua", 4));
}

unittest
{
    auto engine = new ScriptEngine();
    auto scene = new Scene();
    engine.bindAuto("scene", scene);
    engine.registerModule("factory.module", "export any make() { scene.record(1); return scene; }");
    engine.run("import factory.module as Factory;\nFactory.make().record(\nscene.record(2));");
    assert(scene.received == [Received(2, "<global>", "<global>", 3),
        Received(1, "factory.module", "factory.module", 1),
        Received(2, "<global>", "<global>", 2)]);
}

unittest
{
    auto engine = new ScriptEngine();
    auto scene = new Scene();
    engine.bindAuto("scene", scene);
    engine.registerModule("worker.module", "export void work() {\nscene.record(1);\nyield 1;\nscene.record(2);\n}");
    engine.load("import worker.module as Worker; auto co = coroutine.create(Worker.work);");
    RunOptions options;
    options.sourceName = "resumer.dua";
    engine.run("coroutine.resume(co);\nscene.record(3);", options);
    engine.run("coroutine.resume(co);\nscene.record(4);", options);
    assert(scene.received == [Received(1, "worker.module", "worker.module", 2),
        Received(3, "<global>", "resumer.dua", 2),
        Received(2, "worker.module", "worker.module", 4),
        Received(4, "<global>", "resumer.dua", 2)]);
}

private class TimerScene : Recorder
{
    int[string] frames;
    double[string] lastTime;
    double now;

    const(bool) everyNframes(int interval, string key = __MODULE__, int position = __LINE__)
    {
        auto identity = key ~ ":" ~ position.to!string;
        return ++frames[identity] % interval == 0;
    }
    const(bool) everyNsecs(double interval, string key = __MODULE__, int position = __LINE__)
    {
        auto identity = key ~ ":" ~ position.to!string;
        auto previous = identity in lastTime;
        auto last = previous is null ? 0.0 : *previous;
        if (now - last < interval) return false;
        lastTime[identity] = now;
        return true;
    }
}

unittest
{
    auto engine = new ScriptEngine();
    auto scene = new TimerScene();
    engine.bindAuto("scene", scene);
    auto results = engine.run("auto a = 0; auto b = 0;\n"
        ~ "for (auto i = 0; i < 4; i += 1) {\n"
        ~ "if (scene.everyNframes(2)) a += 1;\n"
        ~ "if (scene.everyNframes(2)) b += 1;\n}\nreturn [a, b];").arrayValue;
    assert(results[0].toInt() == 2 && results[1].toInt() == 2);
    assert(scene.frames.length == 2);
    assert(scene.frames["<global>:3"] == 4 && scene.frames["<global>:4"] == 4);
    results = engine.run("auto a = 0; auto b = 0;\n"
        ~ "for (auto i = 0; i < 5; i += 1) { scene.now = i * 0.5;\n"
        ~ "if (scene.everyNsecs(1.0)) a += 1;\n"
        ~ "if (scene.everyNsecs(1.0)) b += 1;\n}\nreturn [a, b];").arrayValue;
    assert(results[0].toInt() == 2 && results[1].toInt() == 2);
    assert(scene.lastTime.length == 2);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.bindAuto("scene", new Scene());
    foreach (method; ["boolean", "constBoolean", "immutableBoolean"])
    {
        assert(engine.run("if (scene." ~ method ~ "(false)) return 1; return 0;").toInt() == 0);
        assert(engine.run("if (scene." ~ method ~ "(true)) return 1; return 0;").toInt() == 1);
        assert(engine.run("return scene." ~ method ~ "(false);").kind == ValueKind.boolean);
    }
    const bool constant = false;
    immutable bool immutableValue = false;
    assert(Value.fromAuto(constant).kind == ValueKind.boolean);
    assert(!Value.fromAuto(constant).truthy());
    assert(!Value.fromAuto(immutableValue).truthy());
}

private class LegacyCallable : CallableValue
{
    this() { super("legacy"); }
    override Value invoke(Value[] args) { return Value.from(args.length); }
}

unittest
{
    auto engine = new ScriptEngine();
    engine.bind("legacy", Value.fromFunction(new LegacyCallable()));
    assert(engine.run("return legacy(1, 2);").toInt() == 2);
    auto legacyReflected = new ReflectedCallable("legacyReflected", 0,
        (Value[] args) => Value.from(23));
    assert(legacyReflected.invokeWithContext([], CallSite("m", "f", 4)).toInt() == 23);
}
