module dua.reverse_iteration_tests;

version (unittest):
import dua;
import std.format : format;

private void succeeds(string source)
{
    foreach (checked; [false, true]) foreach (coroutine; [false, true])
    {
        auto engine = new ScriptEngine;
        RunOptions options; options.typeCheck = checked;
        auto script = coroutine ? "auto co=coroutine.create((){" ~ source ~ "}); auto last=null;"
            ~ "while(coroutine.status(co)!=\"dead\"){auto r=coroutine.resume(co);if(!r[0])error(r[1]);last=r[1];}return last;" : source;
        auto result = engine.runSafe(script, options);
        assert(result.ok, format("checked=%s coroutine=%s: %s", checked, coroutine, result));
        assert(result.value.truthy(), source);
    }
}

unittest
{
    succeeds(q{
        int[] a=[10,20,30]; auto seen=[]; int calls=0;
        int[] get(){calls+=1;return a;}
        foreach_reverse(i,v;get()){seen~=i;seen~=v; if(i==2)a[1]=99;}
        return seen==[2,30,1,99,0,10] && calls==1;
    });
    succeeds(q{
        auto seen=[]; foreach_reverse(v;[1,2,3,4]){if(v==3)continue;if(v==1)break;seen~=v;}
        foreach_reverse(v;[])return false;
        int[] a; foreach_reverse(v;a)return false;
        return seen==[4,2];
    });
    succeeds(q{
        auto seen=[]; int order=0;
        int lo(){order=order*10+1;return -2;} int hi(){order=order*10+2;return 2;}
        foreach_reverse(i;lo()..hi()){seen~=i;}
        foreach_reverse(i;3..3)return false;
        foreach_reverse(i;4..3)return false;
        foreach_reverse(i;9223372036854775806..9223372036854775807)seen~=i;
        foreach_reverse(i;(-9223372036854775807-1)..-9223372036854775807)seen~=i;
        return order==12 && seen==[1,0,-1,-2,9223372036854775806,(-9223372036854775807-1)];
    });
    succeeds(q{
        int i=90; auto callbacks=[];
        foreach_reverse(i;0..3){callbacks~=()=>i;}
        return i==90 && callbacks[0]()==2 && callbacks[1]()==1 && callbacks[2]()==0;
    });
    succeeds(q{
        alias Arrays=int[]|string[];Arrays a=[1,2];auto seen=[];
        foreach_reverse(v;a)seen~=v;
        long lo=-1;uint hi=2;foreach_reverse(i;lo..hi)seen~=i;
        return seen==[2,1,1,0,-1];
    });
    succeeds(q{
        int find(){foreach_reverse(i;0..5){foreach_reverse(v;[7,8]){if(i==3)return i+v;}}return 0;}
        return find()==11;
    });
}

unittest
{
    succeeds(q{
        auto co=coroutine.create((){
            int bound(int n){yield n;return n;}
            foreach_reverse(i;bound(0)..bound(4)){if(i==2)continue;yield i;if(i==1)break;}
            foreach_reverse(i,v;[4,5]){yield i;yield v;}
            return 99;
        });
        auto seen=[];while(coroutine.status(co)!="dead"){auto r=coroutine.resume(co);if(!r[0])error(r[1]);seen~=r[1];}
        return seen==[0,4,3,1,1,5,0,4,99];
    });
    foreach(source;[
        "foreach_reverse(v;[1:2]){}", "foreach_reverse(v;{a=1}){}",
        "foreach_reverse(v;\"abc\"){}", "foreach_reverse(v;2){}",
        "foreach_reverse(v;0.5..2){}", "foreach_reverse(i,v;0..2){}"
    ]) {
        assert((new ScriptEngine).check(source).length>0,source);
        foreach(checked;[false,true]) {
            RunOptions options;options.typeCheck=checked;
            assert(!(new ScriptEngine).runSafe(source,options).ok,source);
        }
    }
}
