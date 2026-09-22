module compatibility_snapshot;

import dua;
import std.conv : to;
import std.format : format;
import std.json : JSONValue;
import std.stdio : writeln, stdout;

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
    stdout.flush();
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

    foreach (source; [
        `auto value = 10; any make(int n) { auto f = () => value;
         auto before = f(); auto value = n; return [before, f]; }
         auto a = make(20); auto b = make(30); return [a[0], a[1](), b[0], b[1]()];`,
        `auto value = 10; { auto write = (int n) { value = n; }; write(11);
         auto value = 20; write(21); } return value;`,
        `auto value = 7; { auto value = value + 1; return value; }`,
        `{ auto value = value + 1; return value; }`,
        `{ auto value = 1; auto value = 2; }`,
        `int f(int a, int a) { return a; } return f(1, 2);`,
        `auto value = 5; int f(bool flag) { if (flag) auto value = 9; return value; }
         return [f(false), f(true), f(false)];`,
        `auto value = 5; { auto f = () => value;
         try { int[] value = ["bad"]; } catch (err) {} return f(); }`,
        `int f(int n) { if (n < 2) { return n; } return f(n - 1) + f(n - 2); } return f(8);`,
        `int[] values = [1]; auto set = (any next) { values = next; };
         set([2]); try { set(["bad"]); } catch (err) {} return values;`,
        `any f(int first, any rest...) { return [first, rest]; } return f(1, 2, 3);`,
        `auto callbacks = [null, null, null]; foreach (i, value; [10, 20, 30]) {
         callbacks[i] = () { value += 1; return value; }; }
         return [callbacks[0](), callbacks[1](), callbacks[0](), callbacks[2]()];`,
        `auto callbacks = [null, null, null]; for (auto i = 0; i < 3; i += 1) {
         auto local = i; callbacks[i] = () => [i, local]; }
         return [callbacks[0](), callbacks[1](), callbacks[2]()];`,
        `auto sum = 0; foreach (k, v; [1: 10, 2: 20]) { auto f = () => k + v; sum += f(); } return sum;`,
        `auto sum = 0; foreach (k, v; { a = 10, b = 20 }) { auto f = () => v; sum += f(); } return sum;`,
        `auto f = null; try { error("failure"); } catch (err) { f = () => err.message; } return f();`,
        `auto f = null; switch (2) { case 1: auto value = 10; f = () => value; break;
         case 2: auto value = 20; f = () => value; break; } return f();`,
        `auto receiver = { value = 42, read = () => this.value }; auto f = receiver["read"];
         auto first = receiver.read(); try { f(); } catch (err) { return [first, err.message]; }`,
        `any make(int n) { return coroutine.create(() { yield n; n += 1; yield n; return n + 1; }); }
         auto a = make(10); return [coroutine.resume(a), coroutine.resume(a), coroutine.resume(a)];`,
        `any f(int n) { if (n > 0) { return f(n - 1); } return missing; } return f(3);`
    ]) record(index++, source);
}
