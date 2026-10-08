module dua.native_operator_tests;

version (unittest):

import dua;
import core.memory : GC;
import std.algorithm.searching : canFind;

private struct CallableIndex
{
    long value;
    this(long value) { this.value = value; }
    long opIndex() const { return value; }
    long opIndex(long index) const { return value + index; }
    long opIndex(long row, long column) const { return value + row * 10 + column; }
    string opIndex(string key) const { return "index:" ~ key; }
    long opCall(long amount = 1, long scale = 1) { value += amount * scale; return value; }
    string opCall(string text) const { return "call:" ~ text; }
    // Concrete overloads remain available beside unsupported templates.
    bool opIndex(T)(T index) const if (is(T == bool)) { return index; }
    bool opCall(T)(T arg) const if (is(T == bool)) { return arg; }
}

private struct CallableProxy
{
    CallableIndex target;
    alias target this;
}

private class CallableObject
{
    long value;
    this(long value) { this.value = value; }
    long opIndex(long index) const { return value + index; }
    string opIndex(string key) const { return "object:" ~ key; }
    long opCall(long amount = 1) { value += amount; return value; }
    string opCall(string text) const { return "object-call:" ~ text; }
}

private class DerivedCallableObject : CallableObject
{
    this(long value) { super(value); }
}

private struct StaticCallableIndex
{
    long value;
    static long opIndex(long index) { return 100 + index; }
    static string opIndex(string key) { return "static-index:" ~ key; }
    static long opCall(long arg = 3) { return 10 * arg; }
    static string opCall(string text) { return "static-call:" ~ text; }
    static bool opIndex(T)(T index) if (is(T == bool)) { return index; }
    static bool opCall(T)(T arg) if (is(T == bool)) { return arg; }
}

private class StaticCallableObject
{
    static long opIndex(long index, long offset = 2) { return index + offset; }
    static long opCall(long arg = 4) { return 20 * arg; }
}

private struct MixedCallableIndex
{
    long value;
    long opIndex(long index) const { return value + index; }
    static string opIndex(string key) { return "mixed-index:" ~ key; }
    long opCall(long arg) const { return value + arg; }
    static string opCall(string text) { return "mixed-call:" ~ text; }
}

private struct TemplateCallableIndex
{
    long opIndex(T)(T index) const { return 1; }
    long opCall(T)(T arg) const { return 2; }
}

private struct LocatedCallableIndex
{
    long opIndex(long index, int line = __LINE__) const { return cast(long) line; }
    long opCall(int line = __LINE__) const { return cast(long) line; }
}

unittest
{
    auto engine = new ScriptEngine;
    engine.bindType!CallableIndex("CallableIndex");
    engine.bindAuto("indexed", CallableIndex(10));
    engine.bindAuto("proxy", CallableProxy(CallableIndex(20)));
    auto object = new DerivedCallableObject(30);
    engine.bindAuto("object", object);
    assert(engine.run(q{
        auto original = indexed;
        auto copy = original;
        auto before = copy[];
        auto changed = copy(2, 3);
        auto zero = copy();
        auto constructed = CallableIndex(40);
        auto proxyCopy = proxy;
        return before == 10 && changed == 16 && zero == 17
            && copy[2] == 19 && copy[2, 3] == 40
            && original[] == 10 && indexed[] == 10
            && copy["abc"] == "index:abc" && copy("abc") == "call:abc"
            && constructed[1] == 41 && constructed(2) == 42
            && proxyCopy[2] == 22 && proxyCopy(3) == 23 && proxyCopy() == 24 && proxyCopy["x"] == "index:x"
            && proxyCopy("x") == "call:x" && proxy[0] == 20
            && object[2] == 32 && object["x"] == "object:x"
            && object(5) == 35 && object() == 36
            && object("x") == "object-call:x";
    }).truthy());
    assert(object.value == 36);
    // Invocation also works when the callee is a property or another expression.
    assert(engine.run(q{
        auto box = { fn = indexed };
        auto list = [indexed];
        return box.fn(2) == 12 && list[0](3) == 13 && (indexed)(4) == 14;
    }).truthy());
    foreach (source; ["return indexed(1, 2, 3);", "return indexed[1, 2, 3];"])
    {
        auto failed = engine.runSafe(source);
        assert(!failed.ok && failed.errorMessage.canFind("no overload matching"));
    }
    // Plain array/table indexing and __call/__index still follow their existing routes.
    assert(engine.run(q{
        auto a = [4, 5];
        auto t = { key = 6, "__index" = (any self, string key) => "fallback:" ~ key,
            "__call" = (any self, int n) => n + 1 };
        return a[1] == 5 && t["key"] == 6 && t["other"] == "fallback:other" && t(7) == 8;
    }).truthy());
    assert(!engine.runSafe("return [1, 2][];").ok);
    assert(!engine.runSafe("return [1, 2][0, 1];").ok);
    assert(!engine.runSafe("indexed[1, 2] = 3;").ok);
    assert(!engine.runSafe("indexed[] += 3;").ok);
    assert(engine.check("int[] a = [1, 2]; return a[0, 1];").length > 0);
}

unittest
{
    auto engine = new ScriptEngine;
    engine.bindType!StaticCallableIndex("StaticIndex");
    engine.bindType!StaticCallableObject("StaticObject");
    engine.bindType!MixedCallableIndex("MixedIndex");
    StaticCallableIndex staticIndex;
    staticIndex.value = 5;
    engine.bindAuto("staticIndex", staticIndex);
    engine.bindAuto("staticObject", new StaticCallableObject);
    MixedCallableIndex mixed;
    mixed.value = 7;
    engine.bindAuto("mixed", mixed);
    assert(engine.run(q{
        auto constructed = StaticIndex.new({ value = 9 });
        auto object = StaticObject.new();
        return StaticIndex[2] == 102 && StaticIndex["x"] == "static-index:x"
            && StaticIndex(2) == 20 && StaticIndex() == 30
            && StaticIndex("x") == "static-call:x"
            && constructed.value == 9 && constructed[3] == 103 && constructed(4) == 40
            && staticIndex[4] == 104 && staticIndex(5) == 50
            && StaticObject[3] == 5 && StaticObject[3, 4] == 7 && StaticObject() == 80
            && object[4] == 6 && object(2) == 40 && staticObject(3) == 60
            && mixed[2] == 9 && mixed["x"] == "mixed-index:x"
            && mixed(3) == 10 && mixed("x") == "mixed-call:x"
            && MixedIndex["x"] == "mixed-index:x" && MixedIndex("x") == "mixed-call:x";
    }).truthy());
    assert(engine.run("return MixedIndex[1];").stringValue == "mixed-index:1");
    assert(engine.run("return MixedIndex(1);").stringValue == "mixed-call:1");
    auto generic = Value.reflect(TemplateCallableIndex());
    assert(generic.findMember("opIndex") is null);
    assert(generic.findMember("opCall") is null);
}

private Value[] escapedOperators()
{
    auto reflected = Value.reflect(CallableIndex(50)).valueCopy();
    return [*reflected.findMember("opIndex"), *reflected.findMember("opCall")];
}

unittest
{
    auto escaped = escapedOperators();
    GC.collect();
    assert(escaped[1].functionValue.invoke([Value.from(7)]).toInt() == 57);
    assert(escaped[0].functionValue.invoke([Value.from(3)]).toInt() == 60);
    auto engine = new ScriptEngine;
    engine.bindAuto("located", LocatedCallableIndex());
    assert(engine.run("return located[0];").toInt() == 1);
    assert(engine.run("\nreturn located();").toInt() == 2);
}

private struct DefaultPreference
{
    long opIndex(long first = 1) const { return first; }
    long opIndex(long first = 2, long second = 3) const { return first + second; }
    long opCall(long first = 1) const { return first; }
    long opCall(long first = 2, long second = 3) const { return first + second; }
}

private struct VariadicCallableIndex
{
    long opIndex(long[] indices...) const
    {
        long sum;
        foreach (index; indices) sum += index;
        return sum;
    }
    long opCall() const { return 100; }
    long opCall(long[] args...) const { return opIndex(args); }
}

private struct VoidCallableIndex
{
    long value;
    this(long value) { this.value = value; }
    long opIndex(long index) const { return value + index; }
    void opCall(long amount) { value += amount; }
}

unittest
{
    auto engine = new ScriptEngine;
    engine.bindAuto("defaults", DefaultPreference());
    engine.bindAuto("variadic", VariadicCallableIndex());
    engine.bindAuto("sink", VoidCallableIndex(5));
    assert(engine.run(q{
        return defaults[] == 1 && defaults() == 1
            && defaults[4] == 4 && defaults(4) == 4
            && defaults[4, 5] == 9 && defaults(4, 5) == 9
            && variadic[] == 0 && variadic[1, 2, 3] == 6
            && variadic() == 100 && variadic(1, 2, 3) == 6
            && sink(2) == null && sink[0] == 7;
    }).truthy());
}

private struct StructCallFactory
{
    long value;
    static StructCallFactory opCall(long value)
    {
        StructCallFactory result;
        result.value = value;
        return result;
    }
    long opIndex(long index) const { return value + index; }
}

private class ClassCallFactory
{
    long value;
    this(long value) { this.value = value; }
    static ClassCallFactory opCall(long value) { return new ClassCallFactory(value * 2); }
    long opIndex(long index) const { return value + index; }
}

unittest
{
    auto engine = new ScriptEngine;
    engine.bindType!StructCallFactory("StructFactory");
    engine.bindType!ClassCallFactory("ClassFactory");
    assert(engine.run(q{
        auto s = StructFactory(5);
        auto c = ClassFactory(6);
        auto constructedStruct = StructFactory.new({ value = 7 });
        auto constructedClass = ClassFactory.new(8);
        return s[1] == 6 && s(9)[1] == 10 && c[1] == 13 && c(10)[1] == 21
            && constructedStruct[1] == 8 && constructedClass[1] == 9;
    }).truthy());
}
