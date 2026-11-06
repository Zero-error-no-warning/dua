module dua.binary_registration_tests;
version(unittest):
import dua;
import std.algorithm.searching : canFind;
import std.traits : isNumeric;

private struct SparseVector {
    double x,y;
    auto opBinary(string op,R=SparseVector)(R rhs) const
        if ((is(R:SparseVector) && (op=="+"||op=="-")) || (isNumeric!R && (op=="*"||op=="/"))) {
        static if(is(R:SparseVector)) return mixin("SparseVector(x"~op~"rhs.x,y"~op~"rhs.y)");
        else return mixin("SparseVector(x"~op~"rhs,y"~op~"rhs)");
    }
    auto opBinaryRight(string op,R)(R lhs) const if(isNumeric!R && op=="*") {
        return SparseVector(lhs*x,lhs*y);
    }
}
private struct EagerNumber {
    long value;
    ~this(){} // Also exercise the eager, non-inert struct reflection path.
    long opBinary(string op)(long rhs) const if(op=="+"){return value+rhs;}
    long opBinaryRight(string op)(long lhs) const if(op=="*"){return lhs*value;}
}
private class NumberObject {
    long value;
    this(long value){this.value=value;}
    long opBinary(string op)(long rhs) const if(op=="+"){return value+rhs;}
    long opBinaryRight(string op)(long lhs) const if(op=="*"){return lhs*value;}
}
private struct NumberProxy { SparseVector target; alias target this; }
private class ObjectProxy { NumberObject target; alias target this; this(){target=new NumberObject(7);} }
private struct UnsupportedGeneric {
    bool opBinaryRight(string op,R)(R rhs) const if(op=="~"&&is(R==bool)){return rhs;}
}
private struct HiddenConcat {
    @NoBind long opBinaryRight(string op)(long[] lhs) const if(op=="~"){return 999;}
}
private class HiddenObjectConcat {
    @NoBind long opBinaryRight(string op)(long[] lhs) const if(op=="~"){return 999;}
}

private void both(ScriptEngine engine,string source){
    foreach(co;[false,true]){
        auto code=co?"auto co=coroutine.create((){yield;"~source~"});coroutine.resume(co);auto r=coroutine.resume(co);if(!r[0])error(r[1]);return r[1];":source;
        auto result=engine.runSafe(code);
        assert(result.ok,result.errorMessage~"\n"~source);
        assert(result.value.truthy(),source);
    }
}

unittest {
    auto engine=new ScriptEngine;
    engine.bindType!SparseVector("SparseVector");
    engine.bindAuto("v",SparseVector(2,4));
    engine.bindAuto("eager",EagerNumber(5));
    engine.bindAuto("object",new NumberObject(6));
    engine.bindAuto("proxy",NumberProxy(SparseVector(3,6)));
    engine.bindAuto("objectProxy",new ObjectProxy);
    engine.bindAuto("generic",UnsupportedGeneric());
    engine.bindAuto("hidden",HiddenConcat());
    engine.bindAuto("hiddenObject",new HiddenObjectConcat);
    foreach(name;["v","eager","object","proxy","objectProxy","generic","hidden","hiddenObject"]){
        auto value=engine.getGlobal(name);
        assert(value.findMember("opBinaryRight~") is null,name);
        assert(value.findMember("opBinary~") is null,name);
        assert(("opBinaryRight~" in value.tableValue) is null,name);
        both(engine,"auto a=[];a~="~name~";a~="~name~";return a.length==2;");
    }
    both(engine,q{
        auto a=[];a~=v;auto copy=v;copy.x=90.;a~=[v];
        SparseVector[] typed=[];typed~=v;typed~=v*2.;typed~=2.*v;
        return a.length==2&&a[0].x==2.&&typed.length==3&&typed[1].y==8.&&typed[2].x==4.;
    });
    both(engine,q{return eager+2==7&&3*eager==15&&object+2==8&&3*object==18
        &&objectProxy+2==9&&3*objectProxy==21&&(proxy*2.).x==6.;});
    both(engine,q{auto a=[];a~=1;a~=[2,3];a~=null;return a.length==4&&a[0]==1&&a[2]==3&&a[3]==null;});
    both(engine,q{
        string trace="";int count=0;auto a=[];
        any rhs(){trace~="r";count+=1;return v;}
        a~=rhs();
        return trace=="r"&&count==1&&a.length==1&&a[0].x==2.;
    });
}

private class RightConcat {
    long calls;
    long opBinaryRight(string op)(long[] lhs) if(op=="~"){++calls;return 100+lhs.length;}
}
private struct ScalarConcat {
    long opBinaryRight(string op)(long lhs) const if(op=="~"){return lhs+10;}
}
private class LeftConcat {
    long calls;
    long opBinary(string op)(RightConcat rhs) if(op=="~"){++calls;return 222;}
}
private class ThrowingConcat {
    long calls;
    long opBinaryRight(string op)(long[] lhs) if(op=="~"){++calls;throw new Exception("operator body error");}
}
private struct NumericOverloads {
    long opBinary(string op)(long rhs) const if(op=="+"){return 100+rhs;}
    double opBinary(string op)(double rhs) const if(op=="+"){return 200.+rhs;}
    string opBinary(string op)(string rhs) const if(op=="+"){return "str:"~rhs;}
}
unittest {
    auto engine=new ScriptEngine;
    auto right=new RightConcat;auto left=new LeftConcat;auto throwing=new ThrowingConcat;
    engine.bindAuto("right",right);engine.bindAuto("left",left);engine.bindAuto("throwing",throwing);
    engine.bindAuto("scalar",ScalarConcat());engine.bindAuto("numeric",NumericOverloads());
    both(engine,q{
        int rightBefore=right.calls;int leftBefore=left.calls;
        string trace="";
        any lhs(){trace~="l";return left;}any rhs(){trace~="r";return right;}
        auto selected=lhs()~rhs();
        return selected==222&&trace=="lr"&&left.calls==leftBefore+1&&right.calls==rightBefore
            &&([1,2]~right)==102&&right.calls==rightBefore+1&&(2~scalar)==12;
    });
    both(engine,q{return numeric+2==102&&numeric+2.5==202.5&&(numeric+"x")=="str:x";});
    both(engine,q{
        auto a=[1];bool failed=false;
        try{a~=scalar;}catch(e){failed=true;}
        return failed&&a.length==1&&a[0]==1;
    });
    foreach(co;[false,true]){
        auto code=q{return [1]~scalar;};
        if(co)code="auto co=coroutine.create((){"~code~"});auto r=coroutine.resume(co);if(!r[0])error(r[1]);return r[1];";
        auto result=engine.runSafe(code);
        assert(!result.ok&&result.errorMessage.canFind("Operator '~' has no overload matching RHS kind array"));
        auto before=throwing.calls;
        auto throwingSource=q{return [1]~throwing;};
        if(co)throwingSource="auto co=coroutine.create((){"~throwingSource~"});auto r=coroutine.resume(co);if(!r[0])error(r[1]);return r[1];";
        auto bodyFailure=engine.runSafe(throwingSource);
        assert(!bodyFailure.ok&&bodyFailure.errorMessage.canFind("operator body error"));
        assert(throwing.calls==before+1);
    }
    both(engine,q{
        int before=throwing.calls;bool failed=false;auto a=[1];
        try{a~=throwing;}catch(e){failed=true;}
        return failed&&throwing.calls==before+1&&a.length==1;
    });
}
