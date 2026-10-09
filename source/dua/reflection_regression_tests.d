module dua.reflection_regression_tests;

version (unittest):

import dua;
import core.memory : GC;
import std.format : format;

private struct PrintableVec
{
    int x, y;
    this(int x, int y) { this.x = x; this.y = y; }
    string toString() { return format("Vec2(%s,%s)", x, y); }
}

private struct SinkPrintable
{
    int value;
    void toString(scope void delegate(const(char)[]) sink) const
    {
        sink(format("sink:%s", value));
    }
}

private struct EagerPrintable
{
    PrintableVec vector;
    alias vector this;
    string toString() const { return format("eager:%s", vector.x); }
}

private class PrintableObject
{
    int value;
    override string toString() { return format("object:%s", value); }
}

private struct ThrowingPrintable
{
    string toString() { throw new Exception("format failed"); }
}

unittest
{
    auto engine = new ScriptEngine;
    engine.bindType!PrintableVec("Vec2");
    engine.bindAuto("sink", SinkPrintable(5));
    engine.bindAuto("eager", EagerPrintable(PrintableVec(6, 7)));
    auto object = new PrintableObject;
    object.value = 8;
    engine.bindAuto("object", object);
    engine.bindAuto("bad", ThrowingPrintable());
    assert(engine.run(q{
        auto original = Vec2(0, 0);
        auto copied = original;
        copied.x = 3;
        object.value = 9;
        return cast!(string) original == "Vec2(0,0)"
            && cast!(string) copied == "Vec2(3,0)"
            && i" $(Vec2(1,1)) " == " Vec2(1,1) "
            && i"$(copied)" == "Vec2(3,0)"
            && cast!(string) [original] == "[Vec2(0,0)]"
            && cast!(string) sink == "sink:5"
            && cast!(string) eager == "eager:6"
            && i"$(object)" == "object:9";
    }).truthy());
    assert(object.value == 9);
    auto retained = Value.reflect(PrintableVec(10, 11)).valueCopy();
    GC.collect();
    assert(retained.toHostString() == "Vec2(10,11)");
    foreach (source; [`return cast!(string) bad;`, `return i"$(bad)";`])
    {
        auto failure = engine.runSafe(source);
        assert(!failure.ok);
        import std.algorithm.searching : canFind;
        assert(failure.errorMessage.canFind("format failed"));
    }
    assert(!engine.runSafe("return cast(string) Vec2(0,0);").ok);
    assert(Value.reflect(Cell(2)).toHostString().length > 0);
}

private struct Cell
{
    int value;
    private int hidden = 42;
    int read() { return value; }
    void write(int next) { value = next; }
    int adjusted(int amount = 2) { return value + amount; }
}

private Value[] escapedAccessors(int initial)
{
    auto original = Value.reflect(Cell(initial));
    auto copied = original.valueCopy();
    auto getter = *copied.propertyGetter("value");
    auto setter = *copied.propertySetter("value");
    auto read = copied.tableValue["read"];
    auto write = copied.tableValue["write"];
    return [getter, setter, read, write, original];
}

unittest
{
    // Field accessors and methods must own the copied receiver, even after all
    // Value handles for that receiver and the factory's stack frame are gone.
    auto first = escapedAccessors(3);
    auto second = escapedAccessors(7);
    foreach (i; 0 .. 3)
    {
        GC.collect();
        first[1].functionValue.invoke([Value.from(20 + i)]);
        second[3].functionValue.invoke([Value.from(40 + i)]);
        assert(first[0].functionValue.invoke([]).toInt() == 20 + i);
        assert(first[2].functionValue.invoke([]).toInt() == 20 + i);
        assert(second[0].functionValue.invoke([]).toInt() == 40 + i);
        assert(second[2].functionValue.invoke([]).toInt() == 40 + i);
        assert(first[4].to!Cell().value == 3);
        assert(second[4].to!Cell().value == 7);
    }
}

unittest
{
    auto reflected = Value.reflect(Cell(5));
    auto getter = reflected.propertyGetter("value").functionValue;
    auto read = reflected.propertyGetter("read").functionValue;
    const snapshot = reflected;
    assert("hidden" !in snapshot.tableValue);
    assert(reflected.propertyGetter("hidden") is null);
    assert(reflected.propertySetter("hidden") is null);
    assert(snapshot.tableValue["read"].functionValue is read);
    assert(reflected.tableValue["read"].functionValue is read);
    assert(reflected.propertyGetter("value").functionValue is getter);
    assert(reflected.tableValue["adjusted"].functionValue.invoke([]).toInt() == 7);
    assert(reflected.tableValue["adjusted"].functionValue.invoke([Value.from(4)]).toInt() == 9);

    // Full table access remains a writable map, including removing and
    // replacing reflected members. Native conversion still uses native data.
    reflected.tableValue.remove("value");
    reflected.tableValue["read"] = Value.from(99);
    reflected.tableValue["extra"] = Value.from(8);
    assert(reflected.findMember("value") is null);
    assert(reflected.findMember("read").toInt() == 99);
    assert(reflected.findMember("extra").toInt() == 8);
    assert(reflected.to!Cell().value == 5);
    assert(reflected.propertyGetter("value").functionValue.invoke([]).toInt() == 5);
    reflected.refreshMember("value", Value.from(77));
    assert(reflected.tableValue["value"].toInt() == 77);
    auto copy = reflected.valueCopy();
    assert(copy.tableValue["value"].toInt() == 5);
    assert(copy.tableValue["read"].kind == ValueKind.function_);
    assert("extra" !in copy.tableValue);
}

unittest
{
    auto first = Value.reflect(Cell(1));
    auto second = Value.reflect(Cell(2));
    // Replacing metadata must not expose or modify another value's bindings.
    Value[string] getters = ["custom": *second.propertyGetter("value")];
    first.setPropertyMetadata(getters, null);
    getters["custom"] = Value.nullValue();
    assert(first.propertyGetter("value") is null);
    assert(first.propertySetter("value") is null);
    assert(first.propertyGetter("custom").functionValue.invoke([]).toInt() == 2);
    assert(first.tableValue["read"].functionValue.invoke([]).toInt() == 1);
    assert(first.propertyGetter("read") is null);
    assert(second.propertyGetter("value").functionValue.invoke([]).toInt() == 2);

    auto chain = [Value.from("Replacement")];
    first.setTypeChain(chain);
    chain[0] = Value.from("Changed input");
    assert(first.typeChain[0].stringValue == "Replacement");
    assert(first.valueCopy().typeChain[0].stringValue == "Replacement");
    assert(second.typeChain[0].stringValue == "Cell");
    assert(Value.reflect(Cell(3)).typeChain[0].stringValue == "Cell");
}

private class Camera
{
    Cell position;
}

private struct CellList
{
    Cell[] items;
    alias items this;
    int first() { return items[0].value; }
}

private struct NumberAlias
{
    static int reads;
    long number;
    ref long raw() { ++reads; return number; }
    alias raw this;
}

unittest
{
    auto array = Value.reflect(CellList([Cell(3), Cell(7)]));
    auto copy = array.valueCopy();
    auto getter = *array.propertyGetter("items");
    auto setter = *array.propertySetter("items");
    setter.functionValue.invoke([Value.fromAuto([Cell(11)])]);
    assert(array.to!CellList().items[0].value == 11);
    assert(copy.to!CellList().items[0].value == 3);
    auto aliasTarget = cast(Value) array.aliasThisTargets[0];
    assert(aliasTarget.functionValue.invoke([]).to!(Cell[])()[0].value == 11);
    assert(array.tableValue["first"].functionValue.invoke([]).toInt() == 11);
    array = Value.nullValue();
    GC.collect();
    assert(getter.functionValue.invoke([]).to!(Cell[])()[0].value == 11);

    NumberAlias.reads = 0;
    auto scalar = Value.reflect(NumberAlias(13));
    auto scalarCopy = scalar.valueCopy();
    assert(NumberAlias.reads == 0); // Type discovery must not evaluate aliases.
    assert(scalar.to!long() == 13);
    assert(NumberAlias.reads == 1);
    scalar.propertySetter("number").functionValue.invoke([Value.from(19)]);
    assert(scalar.to!long() == 19);
    assert(scalarCopy.to!long() == 13);
    assert(NumberAlias.reads == 3);
}

private struct CameraProxy
{
    Camera camera;
    ref Camera raw() { return camera; }
    alias raw this;
    Cell position() { return camera.position; }
    void position(Cell next) { camera.position = next; }
}

unittest
{
    auto camera = new Camera;
    camera.position = Cell(5);
    auto engine = new ScriptEngine;
    engine.bindAuto("proxy", CameraProxy(camera));
    engine.bindAuto("cell", Cell(11));
    assert(engine.run(q{
        auto a = cell; auto b = a;
        b.value = 17;
        proxy.position = b;
        auto temporary = proxy.position;
        temporary.write(29);
        return a.value == 11 && b.value == 17 && proxy.position.value == 17
            && temporary.value == 29;
    }).truthy());
    assert(camera.position.value == 17);
}

private class ReferenceBase
{
    int inherited() const { return 7; }
    int virtualRead() const { return -1; }
}

private class ReferenceNode : ReferenceBase
{
    int value;
    ReferenceNode peer;
    this(int value) { this.value = value; }
    ReferenceNode self() { return this; }
    int read() const { return value; }
    override int virtualRead() const { return value; }
    int add(int amount) { return value += amount; }
    int choose(int amount) { return value + amount; }
    string choose(string text) { return text; }
    @property int current() const { return value; }
    @property void current(int next) { value = next; }
    int sum(int initial, int[] rest...) { foreach (item; rest) initial += item; return value + initial; }
    private int hidden = 99;
}

unittest
{
    // Warm the type descriptor, then measure the boundary itself. Neither class
    // returns, direct calls nor field getters should allocate a table/wrapper.
    auto object = new ReferenceNode(10);
    object.peer = object;
    auto reflected = Value.reflect(object);
    Value getter;
    assert(reflected.lookupPropertyGetter("value", getter));
    assert(reflected.call("self").to!ReferenceNode() is object);
    auto before = GC.allocatedInCurrentThread();
    foreach (_; 0 .. 256)
    {
        auto returned = Value.fromAuto(object).call("self");
        assert(returned.to!ReferenceNode() is object);
        assert(returned.call("read").toInt() == 10);
        assert(getter.invoke([]).toInt() == 10);
        assert(valuesEqual(returned, reflected));
    }
    assert(GC.allocatedInCurrentThread() == before);
    assert(!valuesEqual(reflected, Value.reflect(new ReferenceNode(10))));

    // Host table inspection remains available and binds all callbacks to this
    // instance without changing the shared descriptor used by later returns.
    assert(reflected.tableValue["peer"].to!ReferenceNode() is object);
    assert(reflected.tableValue["add"].functionValue.invoke([Value.from(1)]).toInt() == 11);
    assert(Value.reflect(object).call("read").toInt() == 11);
    const snapshot = Value.reflect(object);
    assert(snapshot.tableValue["value"].toInt() == 11);
}

unittest
{
    auto first = new ReferenceNode(10);
    auto second = new ReferenceNode(20);
    first.peer = second;
    second.peer = first;
    auto engine = new ScriptEngine;
    engine.bindFunc("getFirst", () => first);
    engine.bindFunc("getSecond", () => second);
    engine.bindFunc("asBase", () => cast(ReferenceBase) first);
    engine.bindFunc("missing", () => cast(ReferenceNode) null);
    engine.bindFunc("collect", () { GC.collect(); });
    assert(engine.run(q{
        auto a = getFirst();
        auto b = getSecond();
        a.value = 30;
        b.current = 40;
        auto addA = a.add;
        auto addB = b.add;
        collect();
        auto changedA = addA(2);
        auto changedB = addB(3);
        auto check = a.self() == a && getFirst() == a && a != b
            && a.peer == b && b.peer.peer == b
            && changedA == 32 && changedB == 43
            && a.current == 32 && b.value == 43
            && a.choose(2) == 34 && b.choose("text") == "text"
            && a.sum(1, 2, 3) == 38 && a.inherited() == 7
            && asBase().virtualRead() == 32 && missing() == null;
        return check;
    }).truthy());
    assert(first.value == 32 && second.value == 43);
    assert(!engine.runSafe("return getFirst().hidden;").ok);

    // An escaped method must keep its receiver after host and engine handles go.
    auto escaped = engine.run("return getFirst().add;").to!(int delegate(int))();
    first = null;
    second = null;
    engine = null;
    GC.collect();
    assert(escaped(5) == 37);
}

private class ScalarClassAlias
{
    long number;
    alias number this;
    this(long value) { number = value; }
}

private struct AliasClassTarget
{
    long value;
    long read() const { return value; }
    long add(long amount) { return value += amount; }
    long opBinary(string op)(long rhs) const if (op == "+") { return value + rhs; }
}

private class AggregateClassAlias
{
    AliasClassTarget target;
    alias target this;
    this(long value) { target = AliasClassTarget(value); }
}

unittest
{
    auto scalar = new ScalarClassAlias(12);
    auto aggregate = new AggregateClassAlias(20);
    auto engine = new ScriptEngine;
    engine.bindFunc("scalar", () => scalar);
    engine.bindFunc("aggregate", () => aggregate);
    engine.bindFunc("number", (long value) => value);
    assert(engine.run(q{
        auto a = scalar();
        auto b = aggregate();
        a.number = 15;
        b.add(2);
        return number(a) == 15 && b.read() == 22 && b + 3 == 25;
    }).truthy());
    aggregate.target = AliasClassTarget(30);
    assert(engine.run("return aggregate().read();").toInt() == 30);
}
