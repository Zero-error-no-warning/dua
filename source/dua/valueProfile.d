module dua.valueProfile;
version(DuaValueProfile):
import core.memory : GC;
import core.time : MonoTime;
struct ValueProfileRow {string name;ulong calls,allocated,inclusiveAllocated;long ticks,inclusiveTicks;}
private class Counter {ValueProfileRow row;this(string name){row.name=name;}}
private struct Frame {Counter counter;ulong startAlloc,childrenAlloc;MonoTime startTime;long childrenTicks;}
private Counter[string] counters;
private Frame[4096] stack;
private size_t depth;
private bool enabled;
void enableValueProfile(bool value){assert(depth==0);enabled=value;}
void resetValueProfile(){assert(depth==0);foreach(c;counters){auto name=c.row.name;c.row=ValueProfileRow.init;c.row.name=name;}}
ValueProfileRow[] valueProfileSnapshot(){assert(depth==0);ValueProfileRow[] rows;foreach(c;counters)rows~=c.row;return rows;}
package bool beginValueProfile(string name){
    if(!enabled)return false;
    auto found=name in counters;Counter counter;
    if(found is null){counter=new Counter(name);counters[name]=counter;}else counter=*found;
    assert(depth<stack.length);
    stack[depth++]=Frame(counter,GC.allocatedInCurrentThread,0,MonoTime.currTime,0);
    return true;
}
package void endValueProfile(){
    auto elapsed=MonoTime.currTime;
    auto allocated=GC.allocatedInCurrentThread;
    assert(depth>0);auto f=stack[--depth];stack[depth]=Frame.init;
    auto totalAllocated=allocated-f.startAlloc;
    auto totalTicks=elapsed.ticks-f.startTime.ticks;
    ++f.counter.row.calls;
    f.counter.row.allocated+=totalAllocated-f.childrenAlloc;
    f.counter.row.inclusiveAllocated+=totalAllocated;
    f.counter.row.ticks+=totalTicks-f.childrenTicks;
    f.counter.row.inclusiveTicks+=totalTicks;
    if(depth){stack[depth-1].childrenAlloc+=totalAllocated;stack[depth-1].childrenTicks+=totalTicks;}
}
