module startup_benchmark;

import dua;
import core.memory : GC;
import std.algorithm : sort;
import std.datetime.stopwatch : StopWatch;
import std.exception : enforce;
import std.stdio : writefln;

// Include lexing, parsing and first execution. Use a fresh process per name.
void main(string[] args)
{
    auto name = args.length > 1 ? args[1] : "smallLocals";
    string source;
    size_t count = 500;
    long expected;
    switch (name)
    {
        case "smallRun":
            source = "return 1 + 2;"; expected = 3; break;
        case "smallLocals":
            source = "auto a = 1; auto b = 2; return a + b;"; expected = 3; break;
        case "freshFunction":
            source = "int add(int a, int b) { return a + b; } return add(1, 2);";
            expected = 3; break;
        case "topLevelLoop":
            source = "auto sum = 0; for (auto i = 0; i < 20000; i += 1) { sum += i; } return sum;";
            count = 1; expected = 199_990_000; break;
        default: enforce(false, "Unknown workload: " ~ name);
    }
    auto engine = new ScriptEngine();
    enforce(engine.run(source).toInt() == expected, "Checksum mismatch");
    long[7] times;
    ulong[7] allocations;
    foreach (i; 0 .. times.length)
    {
        GC.collect();
        auto before = GC.allocatedInCurrentThread();
        StopWatch timer;
        timer.start();
        foreach (_; 0 .. count)
            enforce(engine.run(source).toInt() == expected, "Checksum mismatch");
        timer.stop();
        times[i] = timer.peek.total!"usecs";
        allocations[i] = GC.allocatedInCurrentThread() - before;
    }
    sort(times[]); sort(allocations[]);
    writefln("%s(%s): median %s us, min %s us, GC %s bytes", name, count,
        times[$ / 2], times[0], allocations[$ / 2]);
}
