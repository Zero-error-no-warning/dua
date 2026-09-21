module compatibility_snapshot;

import dua;
import std.conv : to;
import std.format : format;
import std.json : JSONValue;
import std.stdio : writeln;

// Compile this same driver against two revisions and compare stdout bytewise.
// Do not sort aggregate output: iteration/display order is part of the check.
private struct ObservedCopy
{
    static size_t copies;
    int value;
    this(this) { ++copies; }
}

void record(size_t index, string source, bool observeCopies = false)
{
    auto engine = new ScriptEngine();
    if (observeCopies)
    {
        auto observed = ObservedCopy(7);
        engine.bindAuto("observed", observed);
        ObservedCopy.copies = 0;
    }
    RunOptions options;
    options.sourceName = "compatibility.dua";
    options.limits.maxSteps = 100_000;
    auto outcome = engine.runSafe(source, options);
    writeln(index, "|", outcome.ok, "|", outcome.errorKind, "|", outcome.stepsExecuted,
        "|", JSONValue(outcome.value.toHostString()).toString(),
        "|", JSONValue(outcome.errorMessage).toString(),
        "|", JSONValue(outcome.stackTrace).toString(),
        "|", observeCopies ? ObservedCopy.copies : 0);
}

void main()
{
    size_t index;
    foreach (seed; 1 .. 101)
    {
        auto a = seed * 17;
        auto b = seed % 23 + 1;
        record(index++, format(q{
            auto a = %s; auto b = %s;
            return [a + b, a - b, a * b, a / b, a %% b, a & b, a | b, a ^ b,
                a << 2, a >> 2, a == b, a != b, a < b, a <= b, a > b, a >= b,
                -a, !a, (a > b && b > 0) || false];
        }, a, b));
        record(index++, format(q{
            auto items = [:];
            for (auto i = 0; i < 50; i += 1) { items[(i * %s) %% 53] = i; }
            for (auto i = 0; i < 20; i += 1) { items.remove(i); }
            for (auto i = 0; i < 10; i += 1) { items[i] = i * 2; }
            return [items.keys, items.values];
        }, seed));
    }
    foreach (fieldCount; [2, 4, 8, 40])
    foreach (seed; 1 .. 41)
    {
        Value[string] fields;
        foreach (i; 0 .. fieldCount)
            fields["field" ~ to!string((i * seed) % 53)] = Value.from(i);
        auto value = Value.fromStruct(fields);
        foreach (_; 0 .. 3)
            value = Value.fromStruct(["nested": value, "first": Value.from(1), "last": Value.from(2)]);
        writeln(index++, "|", value.valueCopy().toHostString());
    }
    foreach (source; [
        `auto value = observed; return value.value;`,
        `auto items = [observed, observed]; return [...items][0].value;`,
        `auto items = [observed, observed]; return items[0..$][1].value;`,
        `any identity(any item) { return item; } return identity(observed).value;`,
        `struct Outer { any child; } auto parent = Outer(observed); auto copied = parent; return copied.child.value;`,
        `struct Outer { any child; } struct Root { Outer child; }
         auto parent = Root(Outer(observed)); auto copied = parent; return copied.child.child.value;`
    ]) record(index++, source, true);
    foreach (source; [
        `return [iota(100), iota(17, -13, -3), iota(-3), iota(2, 20, 7)];`,
        `return missing;`, `auto values = [1]; return values[2];`,
        `int fail(int n) { if (n == 0) { error("failed"); } return fail(n - 1); } return fail(4);`,
        `alias Cycle = Cycle; return cast(Cycle) 1;`,
        `while (true) {}`, `auto a = [(0.0 / 0.0): 1];`,
        `auto callbacks = [null, null, null]; foreach (i; [0, 1, 2]) { callbacks[i] = () => i; }
         return [callbacks[0](), callbacks[1](), callbacks[2]()];`,
        `auto shared = 1; auto f = () => shared; shared = 9; return f();`,
        `auto co = coroutine.create(() { yield 1; yield 2; return 3; });
         return [coroutine.resume(co), coroutine.resume(co), coroutine.resume(co)];`
    ]) record(index++, source);
}
