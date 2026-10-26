module dua.native_index_assignment_tests;
version(unittest):
import dua;
import std.algorithm.searching : canFind;

private class IndexedAssignment {
    long numeric;
    string text;
    void delegate()[string] actions;
    long opIndex(long key) const {return numeric+key;}
    void opIndexAssign(long value,long key){numeric=value*10+key;}
    void opIndexAssign(string value,string key){text=key~":"~value;}
    void opIndexAssign(void delegate() action,string key){actions[key]=action;}
    void run(string key){actions[key]();}
}
private struct IndexedValue {
    long value;
    long opIndex(long key=0) const {return value+key;}
    void opIndexAssign(long rhs,long key){value=rhs+key;}
}

unittest {
    auto engine=new ScriptEngine;
    auto native=new IndexedAssignment;
    engine.bindAuto("native",native);engine.bindAuto("value",IndexedValue(1));
    assert(engine.run(q{
        native[2]=7; native["name"]="body";
        int calls=0; native["state"]=(){calls+=1;};native.run("state");
        auto copy=value;copy[3]=10;
        return calls==1 && native[1]==73 && copy[]==13 && value[]==1;
    }).truthy());
    assert(native.numeric==72 && native.text=="name:body");
    assert(engine.run(q{
        int evaluations=0;
        any receiver(){evaluations+=1;return native;}
        receiver()[4]=3;return evaluations==1 && native[0]==34;
    }).truthy());
    auto failed=engine.runSafe("value[0] = (){};");
    assert(!failed.ok && failed.errorMessage.length);
    assert(!engine.runSafe("native[1,2] = 3;").ok);
    assert(!engine.runSafe("native[] = 3;").ok);
    assert(engine.run(q{
        int side=0;int rhs(){side+=1;return 2;}
        try {native[0]+=rhs();} catch(error) {}
        return side==0;
    }).truthy());
    assert(engine.run(q{
        int[] a=[1];int[string] aa=["x":2];int writes=0;int nativeWrites=0;
        auto table={opIndexAssign=(int value,string key){nativeWrites+=1;}};
        setmetatable(table,{__newindex=(any self,string key,int value){writes+=value;}});
        a[0]=3;aa["x"]=4;table["new"]=5;
        return a[0]==3 && aa["x"]==4 && writes==5 && nativeWrites==0;
    }).truthy());
}
