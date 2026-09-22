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

struct StyledPart
{
    string text;
    Vector position;
    alias text this;
    long textLength() { return text.length; }
}

struct Sentence
{
    StyledPart[] parts;
    alias parts this;
    long textLength() { return parts[0].text.length; }
}

Sentence hostSentence() { return Sentence([StyledPart("FPS: 120", Vector(3, 4))]); }

void main(string[] args)
{
    auto name = args.length > 1 ? args[1] : "methodHostCopies";
    auto engine = new ScriptEngine();
    engine.bindAuto("point", Point(3, 4));
    engine.bindAuto("vector", Vector(3, 4));
    engine.bindAuto("wide", WideVector(3, 4));
    engine.bindFunc!hostVector("hostVector");
    engine.bindFunc!hostSentence("hostSentence");
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
        int aliasedReturns(int n) {
            auto total = 0;
            for (auto i = 0; i < n; i += 1) { auto text = hostSentence(); total += text.textLength(); }
            return total;
        }
    });
    auto count = args.length > 2 ? to!long(args[2]) : 1_000L;
    enforce(count > 0, "Iteration count must be positive");
    long expected;
    switch (name)
    {
        case "plainHostCopies", "namedScriptCopies": expected = count * 3; break;
        case "methodHostCopies", "boundHostCopies", "wideHostCopies": expected = count * 7; break;
        case "reflectedReturns": expected = count * (count - 1) / 2; break;
        case "reflectedOperators": expected = (count + 1) * 3; break;
        case "aliasedReturns": expected = count * 8; break;
        default: enforce(false, "Unknown workload: " ~ name);
    }
    auto arguments = [Value.from(count)];
    enforce(engine.call(name, arguments).toInt() == expected, "Checksum mismatch");
    long[7] times;
    ulong[7] allocations;
    ulong[7] collections;
    long[7] collectionTimes;
    size_t[7] retained;
    foreach (i; 0 .. times.length)
    {
        GC.collect();
        auto before = GC.allocatedInCurrentThread();
        auto profile = GC.profileStats();
        StopWatch timer;
        timer.start();
        auto result = engine.call(name, arguments);
        timer.stop();
        allocations[i] = GC.allocatedInCurrentThread() - before;
        auto afterProfile = GC.profileStats();
        collections[i] = afterProfile.numCollections - profile.numCollections;
        collectionTimes[i] = (afterProfile.totalCollectionTime - profile.totalCollectionTime).total!"usecs";
        enforce(result.toInt() == expected, "Checksum mismatch");
        times[i] = timer.peek.total!"usecs";
        GC.collect();
        retained[i] = GC.stats().usedSize;
    }
    sort(times[]); sort(allocations[]);
    sort(collections[]); sort(collectionTimes[]);
    writefln("%s(%s): median %s us, min %s us, GC %s bytes", name, count,
        times[$ / 2], times[0], allocations[$ / 2]);
    writefln("  GC collections %s, collection time %s us; post-collection heap %s -> %s bytes",
        collections[$ / 2], collectionTimes[$ / 2], retained[0], retained[$ - 1]);
}
