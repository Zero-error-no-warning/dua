module reflection_compatibility;

import dua;
import core.memory : GC;
import std.conv : to;
import std.stdio : writeln;

// Build this driver against both revisions. Do not sort member output: the
// field snapshots, hash iteration order and native copy callbacks must agree.
private string events;

struct Child
{
    int id;
    this(this) { events ~= to!string(id) ~ ","; }
    int read() { return id; }
}

class Reference
{
    int value = 11;
}

struct Wide(size_t width)
{
    int x = 3;
    Child first = Child(17);
    Child second = Child(29);
    Child[] children;
    Reference reference;
    private int hidden = 42;
    static foreach (i; 0 .. width)
        mixin("int method" ~ to!string(i) ~ "(int n = 1) { return x + n; }");
    int property() { return x; }
    void property(int value) { x = value; }
    void change(int value) { x = value; }
    static int constant() { return 91; }
    Wide opBinary(string op)(Wide rhs) if (op == "+")
    {
        auto result = this;
        result.x += rhs.x;
        return result;
    }
    Wide opUnary(string op)() if (op == "-")
    {
        auto result = this;
        result.x = -result.x;
        return result;
    }
}

struct Proxy(T)
{
    T target;
    ref T raw() { return target; }
    alias raw this;
    int own() { return 5; }
}

struct NumberAlias
{
    long number;
    ref long raw() { events ~= "alias,"; return number; }
    alias raw this;
}

struct ArrayAlias
{
    Child[] children;
    alias children this;
    int first() { return children[0].id; }
}

void record(T, bool runScripts = true)(T native)
{
    events = "";
    auto original = Value.reflect(native);
    auto copied = original.valueCopy();
    writeln(T.stringof, "|copies|", events);
    writeln(original.toHostString());
    writeln(copied.toHostString());
    auto saved = copied.tableValue["change"];
    copied = Value.nullValue();
    GC.collect();
    saved.functionValue.invoke([Value.from(65)]);
    writeln("original|", original.to!T().x);

    static if (runScripts)
    {
    auto engine = new ScriptEngine;
    engine.bindAuto("value", native);
    foreach (source; [
        `auto a = value; auto b = a; b.change(8); return [a.x, b.x];`,
        `auto a = value; a.property = 19; return [a.x, a.property, a.constant()];`,
        `auto a = value; return [a.method0(), a.method0(3), (-a).x, (a + a).x];`,
        `auto a = value; auto b = a; a.first.id = 9; a.reference.value = 21;
         return [a.first.id, b.first.id, a.reference.value, b.reference.value];`,
        `any identity(any a) { return a; } return identity(value).x;`,
        `return value;`,
        `return value["x"];`,
        `return value.missing;`,
        `return value.method0(1, 2);`
    ])
    {
        events = "";
        auto outcome = engine.runSafe(source);
        writeln(outcome.ok, "|", outcome.errorKind, "|", outcome.value.toHostString(),
            "|", outcome.errorMessage, "|", outcome.stepsExecuted, "|copies|", events);
    }
    }
    auto mutableMap = Value.reflect(native);
    mutableMap.tableValue.remove("x");
    mutableMap.tableValue["change"] = Value.from(99);
    mutableMap.tableValue["extra"] = Value.from(7);
    writeln("edited|", mutableMap.toHostString());
    writeln("copy edited|", mutableMap.valueCopy().toHostString());
}

void main()
{
    static foreach (width; [1, 4, 20, 80])
    {{
        Wide!width value;
        value.children = [Child(31), Child(43)];
        value.reference = new Reference;
        record(value);
        // Wide alias-this forwarding has pre-existing interpreter limitations;
        // compare native conversion, copying and member tables independently.
        record!(Proxy!(Wide!width), false)(Proxy!(Wide!width)(value));
    }}
    events = "";
    auto number = Value.reflect(NumberAlias(5));
    auto numberCopy = number.valueCopy();
    writeln("number|", number.toHostString(), "|", numberCopy.toHostString(), "|", events);
    writeln(number.to!long(), "|", numberCopy.to!long(), "|", events);
    auto engine = new ScriptEngine;
    engine.bindAuto("number", NumberAlias(7));
    engine.bindAuto("array", ArrayAlias([Child(31), Child(43)]));
    foreach (source; [
        `auto a = number; auto b = a; b.number = 9; return [a.number, b.number];`,
        `auto a = array; auto b = a; b.children = []; return [a.first(), b.children];`,
        `return [number, array];`,
        `return typeinfo(number);`,
        `return typeinfo(array);`
    ])
    {
        events = "";
        auto outcome = engine.runSafe(source);
        writeln(outcome.ok, "|", outcome.errorKind, "|", outcome.value.toHostString(),
            "|", outcome.errorMessage, "|", outcome.stepsExecuted, "|copies|", events);
    }
}
