module dua.range_length_tests;

version (unittest):

import dua;
import std.algorithm : canFind;

unittest
{
    auto engine = new Dua.ScriptEngine();
    engine.bindAuto("nativeArray", [10, 20, 30]);
    assert(engine.run(q{
        int[] empty;
        auto values = [10, 20, 30];
        auto shared = values;
        shared[0] = 40;
        auto section = values[1 .. $];
        return empty.length == 0 && [].length == 0 && values.length == 3
            && section.length == 2 && nativeArray.length == 3
            && length(values) == values.length && len(values) == values.length
            && values.length() == 3 && values[0] == 40;
    }).truthy());
    assert(!engine.runSafe("auto a = [1]; a.length = 2;").ok);
    assert(!engine.runSafe("auto a = [1]; a.length += 1;").ok);
    assert(!engine.runSafe("return [1].missing;").ok);
    assert(engine.run("return {length = 42}.length;").toInt() == 42);
    assert(engine.check("int[] a = [1]; int n = a.length;").length == 0);
    assert(engine.check("int[] a = [1]; string n = a.length;").length == 1);
    assert(engine.check("int[] a = [1]; a.length = 2;").length == 1);
}

unittest
{
    auto engine = new Dua.ScriptEngine();
    assert(engine.run(q{
        auto values = [10, 20, 30];
        auto sum = 0;
        foreach(idx; 0..values.length) { sum += values[idx]; }
        foreach(idx, value; values) { sum += idx + value; }
        foreach(value; []) { sum = -100; }
        foreach(key, value; {a = 1, b = 2}) { sum += value; }
        int[int] entries = [1: 5];
        foreach(key, value; entries) { sum += key + value; }
        return sum;
    }).toInt() == 132);
    assert(engine.run(q{
        auto sum = 0;
        foreach(i; -3..3) {
            if (i == -1) { continue; }
            if (i == 2) { break; }
            sum += i;
        }
        foreach(i; 4..4) { sum = 100; }
        foreach(i; 6..2) { sum = 100; }
        return sum;
    }).toInt() == -4);
    assert(engine.run(q{
        int first() {
            foreach(i; 2..8) { return i; }
            return -1;
        }
        auto sum = 0;
        foreach(i; 0..3) {
            foreach(j; 0..3) {
                if (j == 0) { continue; }
                if (j == 2) { break; }
                sum += i;
            }
        }
        return first() + sum;
    }).toInt() == 5);
    assert(engine.run(q{
        auto start = 1;
        auto finish = 4;
        auto calls = 0;
        int lower() { calls += 1; return start; }
        int upper() { calls += 10; return finish; }
        auto sum = 0;
        foreach(i; lower()..upper()) {
            start = 100;
            finish = -100;
            sum += i;
            i = 90;
        }
        return sum == 6 && calls == 11;
    }).truthy());
    assert(engine.run(q{
        auto callbacks = [];
        auto i = 99;
        foreach(i; 0..3) { callbacks ~= [() => i]; }
        return callbacks[0]() == 0 && callbacks[1]() == 1
            && callbacks[2]() == 2 && i == 99;
    }).truthy());
    engine.bindAuto("minimum", long.min);
    engine.bindAuto("maximum", long.max);
    assert(engine.run(q{
        auto sum = 0;
        foreach(i; maximum-2..maximum) { sum += maximum-i; }
        foreach(i; minimum..minimum+2) { sum += i-minimum; }
        foreach(i; minimum..maximum) { sum += 1; break; }
        return sum;
    }).toInt() == 5);
}

unittest
{
    auto engine = new Dua.ScriptEngine();
    foreach(source; [
        "foreach(i; 0.0..2) {}", "foreach(i; 0..2.0) {}",
        "foreach(i; true..2) {}", `foreach(i; 0.."2") {}`,
        "foreach(i; []..2) {}", "foreach(i; 0..null) {}"])
    {
        auto result = engine.runSafe(source);
        assert(!result.ok && result.errorMessage.canFind("bounds must be integers"), source);
        assert(engine.check(source).length > 0, source);
    }
    foreach(source; ["foreach(i, v; 0..2) {}", "foreach(i; ..2) {}",
        "foreach(i; 0..) {}", "foreach(i; 0...2) {}", "return 0..2;"])
        assert(!engine.runSafe(source).ok, source);
    assert(engine.check("foreach(i; 0..3) { string s = i; }").length == 1);
    auto options = Dua.RunOptions.init;
    options.typeCheck = true;
    assert(engine.runSafe("int[] a = [1,2]; foreach(i; 0..a.length) { int v = a[i]; }", options).ok);
    options.limits.maxSteps = 100;
    auto limited = engine.runSafe("foreach(i; 0..10000) {}", options);
    assert(!limited.ok && limited.errorKind == Dua.RunErrorKind.stepLimit);
}
