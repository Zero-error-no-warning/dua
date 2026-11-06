module dua.stdlib_safety_tests;

version(unittest):
import dua;

unittest
{
    foreach (source; [
        "any recur() { return recur(); } return pcall(recur);",
        "any recur() { return recur(); } return xpcall(recur, (any e) => e);"
    ])
    {
        auto engine = new ScriptEngine;
        RunOptions options;
        options.limits.maxCallDepth = 3;
        auto outcome = engine.runSafe(source, options);
        assert(!outcome.ok && outcome.errorKind == RunErrorKind.callDepthLimit, outcome.errorMessage);
        assert(engine.run("return 42;").toInt() == 42);
    }
    foreach (source; [
        "return pcall(() { while (true) {} });",
        "return xpcall(() { while (true) {} }, (any e) => e);"
    ])
    {
        auto engine = new ScriptEngine;
        RunOptions options;
        options.limits.maxSteps = 30;
        auto outcome = engine.runSafe(source, options);
        assert(!outcome.ok && outcome.errorKind == RunErrorKind.stepLimit, outcome.errorMessage);
    }
    auto engine = new ScriptEngine;
    assert(!engine.run(`return pcall(() { error("expected"); });`).arrayValue[0].truthy());
    assert(engine.run(`return xpcall(() { error("expected"); }, (any e) => "handled");`).arrayValue[1].toHostString() == "handled");
}

unittest
{
    auto engine = new ScriptEngine;
    foreach (value; [double.nan, double.infinity, -double.infinity,
        cast(double) long.max, -cast(double) long.min, -1.0e30, 1.0e30])
    {
        auto fresh = new ScriptEngine;
        fresh.bind("input", Value.from(value));
        auto outcome = fresh.runSafe("return math.floor(input);");
        assert(!outcome.ok);
        import std.algorithm : canFind;
        assert(outcome.errorMessage.canFind("math.floor result is outside the integer range"));
    }
    engine.bind("minimumInteger", Value.from(long.min));
    assert(engine.run("return math.floor(minimumInteger);").toInt() == long.min);
    assert(engine.run("return math.floor(9223372036854775807);").toInt() == long.max);
    assert(engine.run("return math.floor(9007199254740993);").toInt() == 9007199254740993L);
    engine.bind("minimum", Value.from(cast(double) long.min));
    engine.bind("belowMaximum", Value.from(9223372036854774784.0));
    assert(engine.run("return math.floor(minimum);").toInt() == long.min);
    assert(engine.run("return math.floor(belowMaximum);").toInt() == 9223372036854774784L);
    assert(engine.run("return math.floor(-1.2);").toInt() == -2);
    assert(engine.run("return math.floor(1.9);").toInt() == 1);
}
