module dua.host_range_tests;
version(unittest):
import dua;
import std.algorithm : filter, map;
import std.range : iota, repeat;
import std.exception : assertThrown;

private size_t predicates;
private bool even(int n) { ++predicates; return n % 2 == 0; }
private auto filtered() { return filter!even([1,2,3,4,5]); }
private auto mapped() { return iota(1,4).map!(n => n * 3); }
private auto emptyRange() { return iota(0); }
private auto broken() { return iota(0,3).map!((int n) { if(n==1)throw new Exception("range-front"); return n; }); }
private class RangeHost { auto values() { return filtered(); } }
private struct InputOnly { int n; bool empty(){return n==2;} int front(){return n;} void popFront(){++n;} }
private struct ArrayAlias { int[] data; alias data this; }
private class RangeClass {
    int n;
    bool empty(){return n==2;} int front(){return n;} void popFront(){++n;}
    RangeClass save(){auto r=new RangeClass;r.n=n;return r;}
}
private size_t copies;
private struct CopyProbe { int n; this(this){++copies;} }
@NonTraversingLength private struct Sized(T) {
    T[] data;
    bool empty(){return !data.length;}
    ref T front(){return data[0];}
    void popFront(){data=data[1..$];}
    size_t length(){return data.length;}
    Sized save(){return this;}
}

unittest {
    static assert(isMaterializedHostRange!(typeof(filtered())));
    static assert(isMaterializedHostRange!(typeof(mapped())));
    static assert(!isMaterializedHostRange!InputOnly);
    static assert(!isMaterializedHostRange!ArrayAlias);
    static assert(!isMaterializedHostRange!RangeClass);
    static assert(!isMaterializedHostRange!(typeof(repeat(1))));
    foreach(checked;[false,true]) {
        auto e=new ScriptEngine;
        e.enableCompletionMetadata(true);
        e.bindFunc!filtered("filtered"); e.bindFunc!mapped("mapped");
        e.bindFunc!emptyRange("emptyRange"); e.bindFunc!broken("broken");
        e.bindAuto("host",new RangeHost);
        predicates=0;
        RunOptions options;options.typeCheck=checked;
        auto outcome=e.runSafe(q{
            int[] a=filtered(); auto b=a[0..$]; b[0]=99;
            int total=0; foreach(i,v;a) total+=i+v;
            auto m=mapped(); auto z=emptyRange();
            return a.length==2 && a[0]==2 && a[$-1]==4 && b[0]==99
                && total==7 && m.length==3 && m[2]==9 && z.length==0;
        },options);
        assert(outcome.ok,outcome.errorMessage);assert(outcome.value.truthy());
        assert(predicates==5,"filter predicate was evaluated more than once");
        predicates=0;
        assert(e.run("return host.values().length;").to!int==2);
        assert(predicates==5);
        auto failed=e.runSafe("return broken();");
        assert(!failed.ok);
        assert(e.run("return mapped()[0];").to!int==3);
        auto metadata=e.completionRegistry.toJson();
        assert(metadata["symbols"]["filtered"]["signatures"].array[0]["returnType"].str=="int[]");
        assert(metadata["symbols"]["mapped"]["signatures"].array[0]["returnType"].str=="int[]");
        predicates=0;e.bindAuto("bound",filtered());assert(predicates==5);
        assert(e.run("return bound[$-1];").to!int==4);
        assert(metadata["types"]["RangeHost"]["members"]["values"]["signatures"].array[0]["returnType"].str=="int[]");
    }
}

unittest {
    auto r=Sized!int([1,2,3]);auto v=Value.fromAuto(r);
    assert(r.length==3);assert(v.to!(int[])==[1,2,3]);
    auto values=[CopyProbe(1),CopyProbe(2)];
    copies=0;auto arrayValue=Value.from(values);auto baseline=copies;
    copies=0;auto rangeValue=Value.fromAuto(Sized!CopyProbe(values));
    assert(copies==baseline,"range conversion changed element copy boundaries");
    assert(rangeValue.arrayValue[0].to!CopyProbe.n==1);
    assert(Value.fromAuto("abc").kind==ValueKind.string_);
    assert(Value.fromAuto(["x":1]).kind==ValueKind.table);
    assert(Value.fromAuto(new RangeClass).kind==ValueKind.table);
    assert(Value.fromAuto(InputOnly()).kind==ValueKind.struct_);
    assert(Value.fromAuto(ArrayAlias([1,2])).kind==ValueKind.struct_);
    auto original=filtered();auto reflected=Value.reflect(original);
    assert(reflected.kind==ValueKind.struct_);
    auto restored=reflected.to!(typeof(original));
    assert(restored.front==2);
}

private enum Number { one=1, two=2 }
private auto enumRange(){return [Number.one,Number.two].filter!(n=>true);}
private auto charRange(){return "abc".filter!(n=>true);}
unittest {
    foreach(metadataOnly;[false,true]) {
        auto e=new ScriptEngine;e.enableCompletionMetadata(metadataOnly);
        alias R=typeof(filtered());e.bindType!R("NativeRange");
        auto catalog=e.completionRegistry.toJson();
        assert(catalog["symbols"]["NativeRange"]["type"].str==hostReflectedTypeName!R);
        assert(hostReflectedTypeName!R in catalog["types"].object);
    }
    auto e=new ScriptEngine;
    e.bindFunc!enumRange("enums");e.bindFunc!charRange("chars");
    assert(e.run(q{auto a=enums();a[0]=a[0];auto b=a~[];return b[1]==2;}).truthy());
    assert(e.run(q{auto a=chars();a[0]=a[0];auto b=a~[];return b.length==3;}).truthy());
}


private int consumeRange(typeof(filtered()) value){return value.front;}
private struct HiddenRange {
    int n;
    bool empty(){return n==2;}
    @NoBind int front(){return n;}
    void popFront(){++n;}
    HiddenRange save(){return this;}
}
unittest {
    static assert(!isMaterializedHostRange!HiddenRange);
    auto e=new ScriptEngine;e.enableCompletionMetadata();
    e.bindFunc!consumeRange("consumeRange");
    auto catalog=e.completionRegistry.toJson();
    auto name=hostReflectedTypeName!(typeof(filtered()));
    assert(catalog["symbols"]["consumeRange"]["signatures"].array[0]["parameters"].array[0]["type"].str==name);
    assert(name in catalog["types"].object);
    e.bind("nativeRange",Value.reflect(filtered()));
    assert(e.run("return consumeRange(nativeRange);").to!int==2);
}


private size_t lengthCalls,frontCalls;
private struct TraversingLength {
    int n;
    bool empty(){return n==3;}
    int front(){++frontCalls;return n;}
    void popFront(){++n;}
    TraversingLength save(){return this;}
    size_t length(){++lengthCalls;size_t result;auto r=save;while(!r.empty){auto unused=r.front;++result;r.popFront();}return result;}
}
unittest {
    lengthCalls=frontCalls=0;
    auto value=Value.fromAuto(TraversingLength());
    assert(value.to!(int[])==[0,1,2]);
    assert(lengthCalls==0 && frontCalls==3,"Untrusted length must not trigger another traversal");
}

