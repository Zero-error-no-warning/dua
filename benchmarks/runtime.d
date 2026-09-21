module runtime_benchmark;

import dua;
import core.memory : GC;
import std.algorithm : sort;
import std.datetime.stopwatch : StopWatch;
import std.exception : enforce;
import std.stdio : writefln;

// Parse once, then measure execution through the public embedding API.
void measure(ScriptEngine engine, string name, long count, long expected)
{
    auto args = [Value.from(count)];
    enforce(engine.call(name, args).toInt() == expected, name ~ " checksum mismatch");
    long[7] samples;
    foreach (ref sample; samples)
    {
        GC.collect();
        StopWatch timer;
        timer.start();
        auto result = engine.call(name, args);
        timer.stop();
        enforce(result.toInt() == expected, name ~ " checksum mismatch");
        sample = timer.peek.total!"usecs";
    }
    sort(samples[]);
    writefln("%s(%s): median %s us, min %s us", name, count,
        samples[$ / 2], samples[0]);
}

void main()
{
    auto engine = new ScriptEngine();
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
    });
    foreach (count; [8L, 128L, 2048L])
    {
        measure(engine, "integerKeys", count, count * (count - 1) / 2);
        measure(engine, "stringKeys", count, count * (count - 1) / 2);
    }
    measure(engine, "scopedLoop", 10_000, 49_995_000);
    measure(engine, "ufcsCalls", 5_000, 5_000);
}
