module runtime_benchmark;

import dua;
import core.memory : GC;
import std.algorithm : sort;
import std.datetime.stopwatch : StopWatch;
import std.exception : enforce;
import std.stdio : writefln;

private long hostIncrement(long value) { return value + 1; }
private long hostIncrement(string value) { return value.length; }

// Parse once, then measure execution through the public embedding API.
void measure(ScriptEngine engine, string name, long count, long expected)
{
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

void main()
{
    auto engine = new ScriptEngine();
    engine.bindFunc!hostIncrement("hostIncrement");
    auto nested = Value.fromStruct(["value": Value.from(7)]);
    foreach (_; 0 .. 6) nested = Value.fromStruct(["child": nested]);
    engine.bind("nested", nested);
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
    });
    foreach (count; [8L, 128L, 2048L])
    {
        measure(engine, "integerKeys", count, count * (count - 1) / 2);
        measure(engine, "stringKeys", count, count * (count - 1) / 2);
    }
    measure(engine, "scopedLoop", 10_000, 49_995_000);
    measure(engine, "ufcsCalls", 5_000, 5_000);
    measure(engine, "hostOverloads", 5_000, 5_000);
    measure(engine, "manyArguments", 2_000, 72_000);
    measure(engine, "arrayCopies", 500, 63_500);
    measure(engine, "typedArrays", 300, 18_900);
    measure(engine, "structCopies", 500, 3_500);
    measure(engine, "operatorCalls", 5_000, 12_502_500);
}
