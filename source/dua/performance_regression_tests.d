module dua.performance_regression_tests;

version (unittest):

import dua;

unittest
{
    auto engine = new ScriptEngine();
    long[] range(long start, long end, long step)
    {
        return engine.call("iota", [Value.from(start), Value.from(end), Value.from(step)]).to!(long[])();
    }
    assert(range(long.min, long.max, long.max) == [long.min, -1, long.max - 1]);
    assert(range(long.max, long.min, long.min) == [long.max, -1]);
    assert(range(long.min, long.min + 3, 1) == [long.min, long.min + 1, long.min + 2]);
    assert(range(long.max, long.max - 3, -1) == [long.max, long.max - 1, long.max - 2]);
    assert(range(long.max - 1, long.max, 10) == [long.max - 1]);
    assert(range(long.min + 1, long.min, -10) == [long.min + 1]);
    assert(range(0, 10, -1).length == 0 && range(10, 0, 1).length == 0);
    assert(range(0, 0, long.min).length == 0);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.load(q{
        int descend(int depth) {
            if (depth == 0) { error("deep failure"); }
            return descend(depth - 1);
        }
    });
    auto failed = engine.runSafe("return descend(20);");
    assert(!failed.ok && failed.stackTrace.length > 0);
    auto savedTrace = failed.stackTrace.dup;
    auto second = engine.runSafe("return descend(2);");
    assert(!second.ok && failed.stackTrace == savedTrace);
    RunOptions limited;
    limited.limits.maxCallDepth = 4;
    assert(engine.runSafe("return descend(20);", limited).errorKind == RunErrorKind.callDepthLimit);
    assert(engine.run(q{
        auto inner = { read = () { error("inner failure"); } };
        auto outer = {
            value = 42,
            read = () { try { inner.read(); } catch (err) {} return this.value; }
        };
        auto items = [[1, 2], [3, 4, 5]];
        int badIndex() { error("index failure"); return 0; }
        try { auto ignored = items[badIndex()]; } catch (err) {}
        return outer.read() == 42 && items[$ - 1][$ - 1] == 5;
    }).truthy());
}

unittest
{
    auto engine = new ScriptEngine();
    assert(engine.run(q{
        auto trace = "";
        auto left = {
            "opBinary+" = (any self, any other) { trace ~= "L"; return null; },
            "opBinary==" = (any self, any other) { trace ~= "B"; return false; },
            "__eq" = (any self, any other) { trace ~= "E"; return true; },
            "opUnary-" = (any self) { trace ~= "U"; return null; },
            "opUnary!" = (any self) { trace ~= "N"; return 42; }
        };
        auto right = { "opBinaryRight+" = (any self, any other) { trace ~= "R"; return 4; } };
        auto empty = left + right;
        auto reversed = 1 + right;
        auto equal = left == right;
        auto negative = -left;
        auto negated = !left;
        auto fallback = { "__eq" = (any self, any other) { trace ~= "E"; return false; } };
        auto different = fallback != right;
        return trace == "LRBUNE" && empty == null && reversed == 4 && !equal
            && negative == null && negated == 42 && different;
    }).truthy());
}

unittest
{
    auto engine = new ScriptEngine();
    assert(!engine.runSafe("return cast(Later) 1;").ok);
    engine.load("alias Later = int; alias Items = Later[];");
    assert(engine.run("Items values = [1, 2]; return values[1];").toInt() == 2);
    auto definition = engine.getGlobal("__dua_type_Later");
    definition.tableValue["alternatives"] = Value.from([Value.from("string")]);
    assert(engine.run("return cast(Later) 1;").toHostString() == "1");
    assert(!engine.runSafe("Items values = [1, 2];").ok);
    assert(engine.run(`Items values = ["a", "b"]; return values[1];`).toHostString() == "b");
    assert(!engine.runSafe("return cast(HostAlias) 1;").ok);
    engine.bind("__dua_type_HostAlias", definition);
    assert(engine.run("return cast(HostAlias) 2;").toHostString() == "2");
}

unittest
{
    auto engine = new ScriptEngine();
    assert(engine.run(q{
        struct Leaf { int value; table reference; }
        struct Level1 { Leaf child; }
        struct Level2 { Level1 child; }
        struct Level3 { Level2 child; }
        auto original = Level3(Level2(Level1(Leaf(7, { value = 8 }))));
        auto copied = original;
        copied.child.child.child.value = 70;
        copied.child.child.child.reference.value = 80;
        auto items = [original, original];
        items[0].child.child.child.value = 700;
        return original.child.child.child.value == 7
            && copied.child.child.child.value == 70
            && original.child.child.child.reference.value == 80
            && items[0].child.child.child.value == 700
            && items[1].child.child.child.value == 7
            && copied is Level3 && copied.child is Level2
            && copied.child.child.child is Leaf;
    }).truthy());
}

unittest
{
    auto engine = new ScriptEngine();
    assert(engine.run(q{
        auto trace = "";
        int next(int value) { trace ~= cast(string) value; return value; }
        any choose() {
            trace ~= "c";
            return (int a, int b, int c) => a * 100 + b * 10 + c;
        }
        auto result = choose()(next(1), next(2), next(3));
        auto items = [next(4), ...[next(5), next(6)], next(7)];
        return trace == "123c4567" && result == 123 && items == [4, 5, 6, 7];
    }).truthy());
}

unittest
{
    auto engine = new ScriptEngine();
    assert(engine.run(q{
        struct Item { int value; table reference; }
        auto reference = { value = 10 };
        auto original = [Item(1, reference), Item(2, reference)];
        auto spread = [...original];
        auto sliced = original[0..$];
        auto joined = original ~ original;
        auto mapped = map(original, (any item) => item);
        auto filtered = filter(original, (any item) => true);
        spread[0].value = 11;
        sliced[0].value = 12;
        joined[0].value = 13;
        mapped[0].value = 14;
        filtered[0].value = 15;
        spread[0].reference.value = 99;
        return original[0].value == 1 && spread[0].value == 11
            && sliced[0].value == 12 && joined[0].value == 13
            && mapped[0].value == 14 && filtered[0].value == 15
            && original[1].reference.value == 99 && joined[2].value == 1;
    }).truthy());
}
