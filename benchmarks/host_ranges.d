module range_allocation_benchmark;
import dua.value;
import std.algorithm : filter, map;
import std.range : iota;
import std.array : array;
import core.memory : GC;
import std.stdio;
import std.exception : enforce;
void main(){
    enum count=100_000;
    auto input=iota(count);
    auto warm=Value.fromAuto(input);
    warm=Value.from(input.array);
    foreach(filtered;[false,true]){
        ulong direct,intermediate,directHeap,intermediateHeap;
        foreach(_;0..5){
            GC.collect();GC.disable();auto start=GC.allocatedInCurrentThread();auto used=GC.stats.usedSize;
            auto a=filtered?Value.fromAuto(input.filter!(n=>n%2==0)):Value.fromAuto(input);
            direct+=GC.allocatedInCurrentThread()-start;
            directHeap+=GC.stats.usedSize-used;GC.enable();
            enforce(a.kind==ValueKind.array,"Unexpected kind "~a.kind.stringof);
            enforce(a.arrayValue.length==(filtered?count/2:count));
            GC.collect();GC.disable();start=GC.allocatedInCurrentThread();used=GC.stats.usedSize;
            auto b=filtered?Value.from(input.filter!(n=>n%2==0).array):Value.from(input.array);
            intermediate+=GC.allocatedInCurrentThread()-start;
            intermediateHeap+=GC.stats.usedSize-used;GC.enable();
            enforce(b.arrayValue.length==a.arrayValue.length);
        }
        writefln("%s direct allocated=%s heap=%s; via-T-array allocated=%s heap=%s bytes, Value.sizeof=%s",filtered?"filter-unknown":"iota-known",direct/5,directHeap/5,intermediate/5,intermediateHeap/5,Value.sizeof);
    }
}
