module runtime_benchmark;

import dua;
import core.memory : GC;
import std.algorithm : sort;
import std.datetime.stopwatch : StopWatch;
import std.exception : enforce;
import std.format : format;
import std.stdio : writefln;

private long hostIncrement(long value) { return value + 1; }
private long hostIncrement(string value) { return value.length; }
private string selectedWorkload;
private bool measured;

// Parse once, then measure execution through the public embedding API.
void measure(ScriptEngine engine, string name, long count, long expected)
{
    if (selectedWorkload.length && selectedWorkload != name) return;
    measured = true;
    auto args = [Value.from(count)];
    enforce(engine.call(name, args).toInt() == expected, name ~ " checksum mismatch");
    long[7] samples;
    ulong[7] allocations;
    foreach (index, ref sample; samples)
    {
        GC.collect();
        auto before = GC.allocatedInCurrentThread();
        StopWatch timer;
        timer.start();
        auto result = engine.call(name, args);
        timer.stop();
        allocations[index] = GC.allocatedInCurrentThread() - before;
        enforce(result.toInt() == expected, name ~ " checksum mismatch");
        sample = timer.peek.total!"usecs";
    }
    sort(samples[]);
    sort(allocations[]);
    writefln("%s(%s): median %s us, min %s us, GC %s bytes", name, count,
        samples[$ / 2], samples[0], allocations[$ / 2]);
}

void main(string[] arguments)
{
    if (arguments.length > 1) selectedWorkload = arguments[1];
    auto engine = new ScriptEngine();
    engine.bindFunc!hostIncrement("hostIncrement");
    auto nested = Value.fromStruct(["value": Value.from(7)]);
    foreach (_; 0 .. 6) nested = Value.fromStruct(["child": nested]);
    engine.bind("nested", nested);
    Value[string] wideFields;
    foreach (i; 0 .. 40) wideFields["field" ~ format("%s", i)] = Value.from(i + 1);
    auto wide = Value.fromStruct(wideFields);
    foreach (_; 0 .. 3) wide = Value.fromStruct(["child": wide]);
    engine.bind("wideNested", wide);
    engine.load(q{
        int integerKeys(int n) {
            auto items = [:];
            for (auto i = 0; i < n; i += 1) { items[i] = i; }
            auto sum = 0;
            for (auto i = 0; i < n; i += 1) { sum += items[i]; }
            return sum;
        }
        int stringKeys(int n) {
            auto items = [:];
            for (auto i = 0; i < n; i += 1) { items[cast(string) i] = i; }
            auto sum = 0;
            for (auto i = 0; i < n; i += 1) { sum += items[cast(string) i]; }
            return sum;
        }
        int scopedLoop(int n) {
            auto sum = 0;
            for (auto i = 0; i < n; i += 1) {
                { { { sum += i; } } }
            }
            return sum;
        }
        int localLoop(int n) {
            auto i = 0;
            auto sum = 0;
            while (i < n) { sum += i; i += 1; }
            return sum;
        }
        int closureCalls(int n) {
            auto sum = 0;
            auto add = (int value) { sum += value; };
            for (auto i = 0; i < n; i += 1) { add(i); }
            return sum;
        }
        int fib(int n) {
            if (n < 2) { return n; }
            return fib(n - 1) + fib(n - 2);
        }
        int recursiveCalls(int n) { return fib(n); }
        int scopeDeclarations(int n) {
            auto sum = 0;
            for (auto i = 0; i < n; i += 1) {
                auto a = i; auto b = a + 1; auto c = b + 1; auto d = c + 1;
                sum += a + b + c + d;
            }
            return sum;
        }
        int increment(int n) { return n + 1; }
        int ufcsCalls(int n) {
            auto value = 0;
            for (auto i = 0; i < n; i += 1) { value = value.increment(); }
            return value;
        }
        int hostOverloads(int n) {
            auto value = 0;
            for (auto i = 0; i < n; i += 1) { value = hostIncrement(value); }
            return value;
        }
        int sumEight(int a, int b, int c, int d, int e, int f, int g, int h) {
            return a + b + c + d + e + f + g + h;
        }
        int manyArguments(int n) {
            auto sum = 0;
            for (auto i = 0; i < n; i += 1) { sum += sumEight(1, 2, 3, 4, 5, 6, 7, 8); }
            return sum;
        }
        int arrayCopies(int n) {
            auto source = iota(128);
            auto sum = 0;
            for (auto i = 0; i < n; i += 1) {
                auto copied = [...source];
                auto sliced = copied[0..$];
                sum += sliced[127];
            }
            return sum;
        }
        int[] typedIdentity(int[] values) { return values; }
        int typedArrays(int n) {
            auto source = iota(64);
            auto sum = 0;
            for (auto i = 0; i < n; i += 1) {
                auto copied = typedIdentity(source);
                sum += copied[63];
            }
            return sum;
        }
        int structCopies(int n) {
            auto sum = 0;
            for (auto i = 0; i < n; i += 1) {
                auto copied = nested;
                sum += copied.child.child.child.child.child.child.value;
            }
            return sum;
        }
        int operatorCalls(int n) {
            auto receiver = { value = 1 };
            setmetatable(receiver, { ["opBinary+"] = (any self, any other) => self.value + other });
            auto sum = 0;
            for (auto i = 0; i < n; i += 1) { sum += receiver + i; }
            return sum;
        }
        int wideStructCopies(int n) {
            auto sum = 0;
            for (auto i = 0; i < n; i += 1) {
                auto copied = wideNested;
                sum += copied.child.child.child.field0;
            }
            return sum;
        }
        int rangeBuild(int n) {
            auto ascending = iota(n);
            auto descending = iota(n, 0, -1);
            return length(ascending) + length(descending) + ascending[n - 1] + descending[n - 1];
        }
    });
    foreach (count; [8L, 128L, 2048L])
    {
        measure(engine, "integerKeys", count, count * (count - 1) / 2);
        measure(engine, "stringKeys", count, count * (count - 1) / 2);
    }
    measure(engine, "scopedLoop", 10_000, 49_995_000);
    measure(engine, "localLoop", 20_000, 199_990_000);
    measure(engine, "closureCalls", 5_000, 12_497_500);
    measure(engine, "recursiveCalls", 18, 2_584);
    measure(engine, "scopeDeclarations", 5_000, 50_020_000);
    measure(engine, "ufcsCalls", 5_000, 5_000);
    measure(engine, "hostOverloads", 5_000, 5_000);
    measure(engine, "manyArguments", 2_000, 72_000);
    measure(engine, "arrayCopies", 500, 63_500);
    measure(engine, "typedArrays", 300, 18_900);
    measure(engine, "structCopies", 500, 3_500);
    measure(engine, "operatorCalls", 5_000, 12_502_500);
    measure(engine, "wideStructCopies", 100, 100);
    measure(engine, "rangeBuild", 20_000, 60_000);
    enforce(measured, "Unknown workload: " ~ selectedWorkload);
}
