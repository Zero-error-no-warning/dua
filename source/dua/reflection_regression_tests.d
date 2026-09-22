module dua.reflection_regression_tests;

version (unittest):

import dua;
import core.memory : GC;

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
