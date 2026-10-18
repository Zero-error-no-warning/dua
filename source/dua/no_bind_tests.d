module dua.no_bind_tests;

version(unittest):
import dua;
import std.exception : assertThrown;
import std.algorithm : canFind;

private int hiddenCalls;
@NoBind private int hiddenFunction(int n) { ++hiddenCalls; return n; }
private int mixedFunction(string n) { return 12; }
@NoBind private int mixedFunction(int n) { ++hiddenCalls; return n; }

private struct Fixture
{
    int value;
    static int visibleStatic() { return 7; }
    @NoBind static int hiddenStatic() { ++hiddenCalls; return 90; }
    @NoBind static @property int hiddenProperty() { ++hiddenCalls; return 91; }
    int visible(int n = 2) { return value + n; }
    @NoBind int hidden() { ++hiddenCalls; return 92; }
    @NoBind string toString() { ++hiddenCalls; return "hidden"; }
    @NoBind int qualified() { ++hiddenCalls; return 99; }
    int qualified() const { return 16; }
    int mixed(string n) { return 13; }
    @NoBind int mixed(int n) { ++hiddenCalls; return 93; }
    @NoBind this(int n) { ++hiddenCalls; value = n; }
    this(string n) { value = 30; }
}
private class Base
{
    @NoBind int inheritedHidden() { ++hiddenCalls; return 94; }
    int inheritedVisible() { return 14; }
}
private class Derived : Base {}
private class HiddenStringifier
{
    @NoBind override string toString() { ++hiddenCalls; return "hidden"; }
}
private class HiddenConstructor
{
    @NoBind this(int n = 0) { ++hiddenCalls; }
}
private class QualifiedConstructor
{
    int value;
    this(const(int[]) values, int extra = 4) { value = values[0] + extra; }
    @NoBind this(int[] values, int extra) { ++hiddenCalls; value = 99; }
}
private struct AliasTarget
{
    @NoBind int hidden() { ++hiddenCalls; return 95; }
    @NoBind int qualified() { ++hiddenCalls; return 99; }
    int qualified() const { return 17; }
    int mixed(int n, int extra = 4) { return n + extra; }
    @NoBind int mixed(int n) { ++hiddenCalls; return 96; }
}
private struct AliasWrapper
{
    AliasTarget target;
    alias target this;
}
private struct HiddenAliasAccessor
{
    AliasTarget target;
    @NoBind ref AliasTarget asTarget() { ++hiddenCalls; return target; }
    alias asTarget this;
}
private struct HiddenOperators
{
    @NoBind int opBinary(string op)(int rhs) const { ++hiddenCalls; return 1; }
    @NoBind int opUnary(string op)() const { ++hiddenCalls; return 1; }
    @NoBind bool opEquals(HiddenOperators rhs) const { ++hiddenCalls; return true; }
}
private struct HiddenOperatorAlias
{
    HiddenOperators target;
    alias target this;
}
private struct HiddenCallable
{
    @NoBind int opCall(int n) { ++hiddenCalls; return n; }
}

private struct AliasCallableTarget { int opCall(int n) { return n + 10; } }
private struct HiddenCallableAccessor
{
    AliasCallableTarget target;
    @NoBind ref AliasCallableTarget accessor() { ++hiddenCalls; return target; }
    alias accessor this;
}
private struct NestedHiddenCallable
{
    HiddenCallableAccessor inner;
    alias inner this;
}
private struct NestedAccessorCallable
{
    HiddenCallableAccessor inner;
    ref HiddenCallableAccessor accessor() { ++hiddenCalls; return inner; }
    alias accessor this;
}
private class HiddenClassCallable
{
    AliasCallableTarget target;
    @NoBind ref AliasCallableTarget accessor() { ++hiddenCalls; return target; }
    alias accessor this;
}
private class InheritedHiddenClassCallable : HiddenClassCallable {}
private class VisibleAliasOverride : HiddenClassCallable
{
    AliasCallableTarget other;
    ref AliasCallableTarget visibleAccessor() { return other; }
    alias visibleAccessor this;
}
private class InheritedVisibleAliasOverride : VisibleAliasOverride {}
private struct HiddenPropertyCallable
{
    AliasCallableTarget target;
    @NoBind @property ref AliasCallableTarget accessor() { ++hiddenCalls; return target; }
    alias accessor this;
}
private struct VisibleCallableAccessor
{
    AliasCallableTarget target;
    ref AliasCallableTarget accessor() { return target; }
    alias accessor this;
}
private struct VisibleCallableField
{
    AliasCallableTarget target;
    alias target this;
}
private struct DirectCallableWithHiddenAlias
{
    AliasCallableTarget target;
    @NoBind ref AliasCallableTarget accessor() { ++hiddenCalls; return target; }
    alias accessor this;
    int opCall(int n) { return n + 20; }
}
private class VisibleClassCallable
{
    int opCall(int n) { return n + 30; }
}
private class InheritedVisibleCallable : VisibleClassCallable {}

unittest
{
    foreach (metadata; [false, true])
    {
        hiddenCalls = 0;
        auto engine = new ScriptEngine();
        if (metadata) engine.enableCompletionMetadata(true);
        assertThrown!Exception(engine.bindFunc("hidden", HiddenCallableAccessor.init));
        assertThrown!Exception(engine.bindFunc("nested", NestedHiddenCallable.init));
        assertThrown!Exception(engine.bindFunc("nestedAccessor", NestedAccessorCallable.init));
        assertThrown!Exception(engine.bindFunc("classHidden", new HiddenClassCallable()));
        assertThrown!Exception(engine.bindFunc("inheritedHidden", new InheritedHiddenClassCallable()));
        assertThrown!Exception(engine.bindFunc("propertyHidden", HiddenPropertyCallable.init));
        auto moduleHandle = engine.newModule("host");
        assertThrown!Exception(moduleHandle.bindFunc("moduleHidden", HiddenCallableAccessor.init));
        assert(hiddenCalls == 0);
        foreach (name; ["hidden", "nested", "nestedAccessor", "classHidden", "inheritedHidden", "propertyHidden"])
        {
            assertThrown!Exception(engine.run("return " ~ name ~ "(2);"));
            if (metadata)
                assert(name !in engine.completionRegistry.toJson()["symbols"].object);
        }
        if (metadata)
        {
            assert("HiddenCallableAccessor" !in engine.completionRegistry.toJson()["types"].object);
            assert("host.moduleHidden" !in engine.completionRegistry.toJson()["symbols"].object);
        }
        engine.bindFunc("visibleAccessor", VisibleCallableAccessor.init);
        engine.bindFunc("visibleField", VisibleCallableField.init);
        engine.bindFunc("direct", DirectCallableWithHiddenAlias.init);
        engine.bindFunc("inheritedVisible", new InheritedVisibleCallable());
        engine.bindFunc("shadowedAlias", new InheritedVisibleAliasOverride());
        assert(engine.run("return visibleAccessor(2);").toInt() == 12);
        assert(engine.run("return visibleField(2);").toInt() == 12);
        assert(engine.run("return direct(2);").toInt() == 22);
        assert(engine.run("return inheritedVisible(2);").toInt() == 32);
        assert(engine.run("return shadowedAlias(2);").toInt() == 12);
        assert(hiddenCalls == 0);
    }
}

unittest
{
    hiddenCalls = 0;
    auto engine = new ScriptEngine();
    engine.bindType!Fixture("Fixture");
    engine.bindType!HiddenConstructor("HiddenConstructor");
    engine.bindType!QualifiedConstructor("QualifiedConstructor");
    engine.bindAuto("item", Fixture.init);
    engine.bindAuto("derived", new Derived());
    engine.bindAuto("hiddenStringifier", new HiddenStringifier());
    engine.bindAuto("aliasItem", AliasWrapper.init);
    engine.bindAuto("hiddenAlias", HiddenAliasAccessor.init);
    engine.bindAuto("hiddenOperators", HiddenOperators.init);
    engine.bindAuto("hiddenOperatorAlias", HiddenOperatorAlias.init);
    assert(hiddenCalls == 0); // Even zero-argument static getters must not run.
    assert(engine.run("return Fixture.visibleStatic();").toInt() == 7);
    assert(engine.run("return item.visible();").toInt() == 2);
    assert(engine.run("return item.mixed(\"ok\");").toInt() == 13);
    assert(engine.run("return derived.inheritedVisible();").toInt() == 14);
    assert(engine.run("return aliasItem.mixed(3);").toInt() == 7);
    assert(engine.run("return item.qualified();").toInt() == 16);
    assert(engine.run("return aliasItem.qualified();").toInt() == 17);
    assertThrown!Exception(engine.run("return QualifiedConstructor.new([3]);"));
    assert(engine.run("return item.mixed(1);").toInt() == 13); // Existing string coercion.
    foreach (script; ["return Fixture.hiddenStatic();", "return Fixture.hiddenProperty;",
        "return item.hidden();", "return derived.inheritedHidden();",
        "return aliasItem.hidden();", "return HiddenConstructor.new();",
        "return hiddenAlias.mixed(1);", "return hiddenOperators + 1;",
        "return hiddenOperatorAlias + 1;", "return -hiddenOperators;"])
    {
        bool rejected;
        try { engine.run(script); } catch (Exception) { rejected = true; }
        assert(rejected, script);
    }
    assertThrown!Exception(engine.run("return Fixture.new(\"ok\");"));
    engine.run("return \"\" ~ item;");
    engine.run("return \"\" ~ hiddenStringifier;");
    assert(hiddenCalls == 0);
    assertThrown!Exception(engine.bindFunc!hiddenFunction("explicitHidden"));
    assertThrown!Exception(engine.bindFunc!mixedFunction("explicitMixed"));
    assertThrown!Exception(engine.bindFunc("hiddenCallable", HiddenCallable.init));
    assert(hiddenCalls == 0);
    assertThrown!Exception(engine.run("return explicitHidden(1);"));
    // Native function pointers no longer carry the declaration's UDA.
    auto erased = &hiddenFunction;
    engine.bindFunc("erased", erased);
    assert(engine.run("return erased(5);").toInt() == 5);
    assert(hiddenCalls == 1);
}

unittest
{
    auto description = describeHostCompletionType!Fixture();
    auto members = description["members"].object;
    foreach (name; ["hidden", "hiddenStatic", "hiddenProperty"])
        assert(name !in members, name);
    assert("visible" in members);
    assert(members["mixed"]["signatures"].array.length == 1);
    assert(description["constructors"].array.length == 0);
    auto engine = new ScriptEngine();
    engine.enableCompletionMetadata(true);
    engine.bindType!Fixture("Fixture");
    assertThrown!Exception(engine.bindFunc!mixedFunction("explicitMixed"));
    assert("explicitMixed" !in engine.completionRegistry.toJson()["symbols"].object);
}
