module reflection_benchmark;

import dua;
import core.memory : GC;
import std.algorithm : sort;
import std.datetime.stopwatch : StopWatch;
import std.exception : enforce;
import std.stdio : writefln;
import std.conv : to;

struct Point
{
    long x;
    long y;
}

struct Vector
{
    long x;
    long y;
    this(long x, long y) { this.x = x; this.y = y; }
    long sum() { return x + y; }
    long scaled(long factor = 2) { return (x + y) * factor; }
    void translate(long dx, long dy) { x += dx; y += dy; }
    Vector opBinary(string op)(Vector rhs) if (op == "+")
    {
        return Vector(x + rhs.x, y + rhs.y);
    }
}

Vector hostVector(long x) { return Vector(x, 2); }

// A small payload with many public methods, like a host geometry type. These
// unused members must not impose per-copy callable/map allocation costs.
struct WideVector
{
    long x;
    long y;
    long sum() { return x + y; }
    static foreach (i; 0 .. 40)
        mixin("long method" ~ to!string(i) ~ "(long n = 1) { return x + y + n; }");
}

void main(string[] args)
{
    auto name = args.length > 1 ? args[1] : "methodHostCopies";
    auto engine = new ScriptEngine();
    engine.bindAuto("point", Point(3, 4));
    engine.bindAuto("vector", Vector(3, 4));
    engine.bindAuto("wide", WideVector(3, 4));
    engine.bindFunc!hostVector("hostVector");
    engine.bindType!Vector("BoundVector");
    engine.load(q{
        struct ScriptPoint { int x; int y; }
        int plainHostCopies(int n) {
            auto total = 0;
            for (auto i = 0; i < n; i += 1) { auto p = point; total += p.x; }
            return total;
        }
        int methodHostCopies(int n) {
            auto total = 0;
            for (auto i = 0; i < n; i += 1) { auto v = vector; total += v.sum(); }
            return total;
        }
        int namedScriptCopies(int n) {
            auto source = ScriptPoint(3, 4); auto total = 0;
            for (auto i = 0; i < n; i += 1) { auto p = source; total += p.x; }
            return total;
        }
        int wideHostCopies(int n) {
            auto total = 0;
            for (auto i = 0; i < n; i += 1) { auto v = wide; total += v.sum(); }
            return total;
        }
        int boundHostCopies(int n) {
            auto source = BoundVector(3, 4); auto total = 0;
            for (auto i = 0; i < n; i += 1) { auto v = source; total += v.sum(); }
            return total;
        }
        int reflectedReturns(int n) {
            auto total = 0;
            for (auto i = 0; i < n; i += 1) { auto v = hostVector(i); total += v.x; }
            return total;
        }
        int reflectedOperators(int n) {
            auto v = vector;
            for (auto i = 0; i < n; i += 1) { v = v + vector; }
            return v.x;
        }
    });
    enum count = 1_000;
    long expected;
    switch (name)
    {
        case "plainHostCopies", "namedScriptCopies": expected = count * 3; break;
        case "methodHostCopies", "boundHostCopies", "wideHostCopies": expected = count * 7; break;
        case "reflectedReturns": expected = count * (count - 1) / 2; break;
        case "reflectedOperators": expected = (count + 1) * 3; break;
        default: enforce(false, "Unknown workload: " ~ name);
    }
    auto arguments = [Value.from(count)];
    enforce(engine.call(name, arguments).toInt() == expected, "Checksum mismatch");
    long[7] times;
    ulong[7] allocations;
    foreach (i; 0 .. times.length)
    {
        GC.collect();
        auto before = GC.allocatedInCurrentThread();
        StopWatch timer;
        timer.start();
        auto result = engine.call(name, arguments);
        timer.stop();
        allocations[i] = GC.allocatedInCurrentThread() - before;
        enforce(result.toInt() == expected, "Checksum mismatch");
        times[i] = timer.peek.total!"usecs";
    }
    sort(times[]); sort(allocations[]);
    writefln("%s(%s): median %s us, min %s us, GC %s bytes", name, count,
        times[$ / 2], times[0], allocations[$ / 2]);
}
