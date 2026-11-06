module dua.array_length_tests;

version (unittest):
import dua;
import std.format : format;
import std.algorithm : canFind;

private struct NativeDefault { int x=17; this(int n){x=n;} }
private class NativeReference { }
private class ArrayProperty {
    int[] items=[1,2]; int reads,writes;
    int[] numbers(){++reads;return items;}
    void numbers(int[] next){++writes;items=next;}
}

private void succeeds(string source)
{
    foreach (checked; [false, true]) foreach (coroutine; [false, true])
    {
        auto engine=new ScriptEngine;
        engine.bindType!NativeDefault("NativeDefault");
        engine.bindType!NativeReference("NativeReference");
        auto property=new ArrayProperty;
        engine.bindAuto("property",property);
        RunOptions options;options.typeCheck=checked;
        auto script=coroutine?"auto co=coroutine.create((){"~source~"});auto last=null;"
            ~"while(coroutine.status(co)!=\"dead\"){auto r=coroutine.resume(co);if(!r[0])error(r[1]);last=r[1];}return last;":source;
        auto result=engine.runSafe(script,options);
        assert(result.ok,format("checked=%s coroutine=%s: %s\n%s",checked,coroutine,result,source));
        assert(result.value.truthy(),source);
    }
}

unittest
{
    succeeds(q{
        int[] a;a.length=3;if(a!=[0,0,0])return false;
        a[1]=7;a.length+=2;if(a!=[0,7,0,0,0])return false;
        a.length-=3;if(a!=[0,7])return false;
        a.length=0;a.length=1;return a==[0];
    });
    succeeds(q{
        auto a=[];a.length=2;auto b=[4];b.length=2;
        return a==[null,null]&&b==[4,null];
    });
    succeeds(q{
        double[] f;f.length=2;bool[] b;b.length=1;string[] s;s.length=1;
        byte[] by;by.length=1;ulong[] u;u.length=1;
        return f[0]!=f[0]&&f[1]!=f[1]&&!b[0]&&s[0]==""&&by[0]==0&&u[0]==0;
    });
    succeeds(q{
        int[][] rows;rows.length=2;rows[0].length=3;
        table Item{int id;} Item[] items;items.length=2;
        NativeReference[] refs;refs.length=1;
        int[string][] maps;maps.length=2;maps[0]["x"]=7;
        return rows[0]==[0,0,0]&&rows[1].length==0&&items==[null,null]
            &&refs[0]==null&&maps[0]["x"]==7&&maps[1].length==0;
    });
    succeeds(q{
        int calls=0;int next(){calls+=1;return calls;}
        struct Inner{int x;double f;}
        struct Entry{Inner p;int id=next();int[] data;}
        Entry[] a;a.length=2;a[0].p.x=9;a[0].data.length=1;
        NativeDefault[] native;native.length=2;native[0].x=3;
        return calls==2&&a[0].id==1&&a[1].id==2&&a[1].p.x==0&&a[1].p.f!=a[1].p.f
            &&a[1].data.length==0&&native[0].x==3&&native[1].x==17;
    });
    succeeds(q{
        int[] a=[1,2,3];auto b=a;a.length=1;b[0]=9;
        if(a[0]!=9||b.length!=3)return false;
        a.length=4;a[0]=8;
        return a==[8,0,0,0]&&b==[9,2,3];
    });
    succeeds(q{
        int[] original=[1];int[] other=[8,9];auto selected=original;
        int rhs(){selected=other;return 3;}
        selected.length=rhs();if(selected!=[8,9,0]||other.length!=2)return false;
        selected=original;selected.length+=rhs();
        return selected==[1,0,0,0]&&other==[8,9]&&original.length==1;
    });
    succeeds(q{
        int[][] rows=[[1],[2]];string trace="";
        int[][] target(){trace~="t";return rows;}
        int index(){trace~="i";return 1;}int rhs(){trace~="r";return 3;}
        target()[index()].length=rhs();if(trace!="rti"||rows[1]!=[2,0,0])return false;
        trace="";target()[index()].length+=rhs();
        return trace=="tir"&&rows[1].length==6;
    });
    succeeds(q{
        struct Point{int x;} Point[] a=[Point(1)];auto b=a;
        a.length=2;a[0].x=7;a[1].x=8;
        return b[0].x==1&&a[0].x==7&&a[1].x==8;
    });
    succeeds(q{
        property.numbers.length=4;
        if(property.reads!=1||property.writes!=1||property.numbers.length!=4)return false;
        property.numbers.length-=3;
        return property.reads==3&&property.writes==2&&property.numbers.length==1;
    });
    succeeds(q{
        alias Number=int;Number[] a;a.length=2;
        alias Maybe=int|null;Maybe[] b;b.length=1;
        alias Literal="hello";Literal[] c;c.length=1;
        return a==[0,0]&&b==[null]&&c==["hello"];
    });
}

unittest
{
    // エラーが配列を書き換えないことと、その後も$や再代入が使えることを確認します。
    foreach (bad; ["-1", "9223372036854775807", "1.5", "true", "\"3\"", "null"])
    {
        auto source="int[] a=[1,2];auto b=a;try{a.length="~bad~";}catch(e){}return a==[1,2]&&b==[1,2];";
        if (bad=="-1"||bad=="9223372036854775807") succeeds(source);
        else {
            assert((new ScriptEngine).check("int[] a=[];a.length="~bad~";").length>0,bad);
            auto outcome=(new ScriptEngine).runSafe(source);
            assert(outcome.ok&&outcome.value.truthy(),source);
        }
    }
    succeeds(q{
        alias Choice=int[]|string[];Choice a=[1,2];a.length=1;
        try{a.length=3;return false;}catch(e){}
        alias Word="yes"|"no";Word[] words=[];
        try{words.length=1;return false;}catch(e){}
        return a==[1]&&words.length==0;
    });
    foreach(source;["auto a=[1];a[0..1].length=2;","int[] get(){return [1];}get().length=2;",
        "auto a=[1:2];a.length=2;","auto a=\"hi\";a.length=3;"])
    {
        assert((new ScriptEngine).check(source).length>0,source);
        assert(!(new ScriptEngine).runSafe(source).ok,source);
    }
}

unittest
{
    succeeds(q{
        int[][] rows=[[1]];string trace="";
        int[][] target(){trace~="t";yield "target";return rows;}
        int index(){trace~="i";yield "index";return 0;}
        int rhs(){trace~="r";yield "rhs";return 2;}
        auto co=coroutine.create((){target()[index()].length=rhs();target()[index()].length+=rhs();return rows[0].length;});
        auto seen=[];while(coroutine.status(co)!="dead"){auto r=coroutine.resume(co);if(!r[0])error(r[1]);seen~=r[1];}
        return seen==["rhs","target","index","target","index","rhs",4]&&trace=="rtitir"&&rows[0]==[1,0,0,0];
    });
}
