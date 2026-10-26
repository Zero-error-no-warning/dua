module app;
import dua;
import core.thread : Fiber;
import std;

class Host {string name;this(string n){name=n;}void yields(){Fiber.yield();}}
void check(bool value,string message){enforce(value,message);}
int main(string[] args){
    auto dir=absolutePath(args.length>1?args[1]:"fixture").buildNormalizedPath;mkdirRecurse(dir);
    std.file.write(buildPath(dir,"helper.dua"),q{
        import scenes;
        int sharedCount=0;
        instance int count=0;
        export any check(){sharedCount+=1;count+=1;return [sharedCount,count,self.name,scenes.root.name];}
        export any callback(){return ()=>[self.name,scenes.root.name];}
    });
    std.file.write(buildPath(dir,"actor.dua"),q{
        import scenes;
        import "./helper.dua" as helper;
        int sharedCount=0;
        auto initial=[self.name,scenes.root.name];
        auto data={n=0};int[] values=[0];instance table ownData={n=0};
        export int snapshot=0;
        export void changeSnapshot(){snapshot+=1;}
        export int readSnapshot(){return snapshot;}
        export any touch(){data.n+=1;values[0]+=1;ownData.n+=1;return [data.n,values[0],ownData.n];}
        instance int count=0;
        export any step(){sharedCount+=1;count+=1;return [sharedCount,count,self.name,scenes.root.name];}
        export any initialContext(){return initial;}
        export any helperCall(){return helper.check();}
        export any callback(){return helper.callback();}
        export any flow(){auto before=scenes.root.name;self.yields;return [before,scenes.root.name,self.name];}
        export any coro(){return coroutine.create((){yield scenes.root.name;yield scenes.root.name;return scenes.root.name;});}
        export any resume(any c){return coroutine.resume(c);}
    });
    auto engine=new ScriptEngine;
    ModuleContext ownerContext(string n){
        auto session=engine.createModuleContext([buildPath(dir,"?.dua")]);
        engine.newContextModule(session,"scenes").bind("root",Value.reflect(new Host("root-"~n)));
        auto owner=engine.createModuleContext(null,session);
        engine.bindContext(owner,"self",Value.reflect(new Host(n)));return owner;
    }
    auto a=ownerContext("A"),b=ownerContext("B");
    auto am=engine.instantiateModule("actor",a),bm=engine.instantiateModule("actor",b);
    auto av=am.call("step").arrayValue,bv=bm.call("step").arrayValue;
    check(av[0].to!int==1&&bv[0].to!int==2&&av[1].to!int==1&&bv[1].to!int==1,"ordinary shared / instance isolated");
    check(av[2].to!string=="A"&&bv[2].to!string=="B"&&bv[3].to!string=="root-B","self/scenes isolated");
    check(am.call("touch").to!(int[])()==[1,1,1]&&bm.call("touch").to!(int[])()==[2,2,1],"table/array sharing and instance table");
    am.call("changeSnapshot");check(bm.call("readSnapshot").to!int==1&&am.exportsValue().tableValue["snapshot"].to!int==0,"export snapshot unchanged");
    check(am.call("initialContext").arrayValue[0].to!string=="A"&&bm.call("initialContext").arrayValue[0].to!string=="A","shared initializer runs once in first context");
    auto ah=am.call("helperCall").arrayValue,bh=bm.call("helperCall").arrayValue;
    check(ah[0].to!int==1&&bh[0].to!int==2&&ah[1].to!int==1&&bh[1].to!int==1&&bh[3].to!string=="root-B","shared helper import context");
    auto ac=am.call("callback"),bc=bm.call("callback");
    check(ac.functionValue.invoke([]).arrayValue[1].to!string=="root-A"&&bc.functionValue.invoke([]).arrayValue[1].to!string=="root-B","callback creation context");
    Value faResult,fbResult;
    auto fa=new Fiber({faResult=am.call("flow");},1024*1024);
    auto fb=new Fiber({fbResult=bm.call("flow");},1024*1024);
    fa.call();fb.call();fa.call();fb.call();
    check(faResult.arrayValue.map!(x=>x.to!string).array==["root-A","root-A","A"],"A Fiber resume context");
    check(fbResult.arrayValue.map!(x=>x.to!string).array==["root-B","root-B","B"],"B Fiber resume context");
    auto ca=am.call("coro"),cb=bm.call("coro");
    foreach(i;0..3){
        auto ra=am.call("resume",[ca]);check(ra.arrayValue[1].to!string=="root-A","A coroutine repeat resume");
        check(bm.call("resume",[cb]).arrayValue[1].to!string=="root-B","B coroutine repeat resume");
    }
    auto ended=am.call("coro");am.call("resume",[ended]);
    a.close();check(!bm.call("resume",[ended]).arrayValue[0].to!bool,"closed coroutine rejected");
    bool rejected;try{ac.functionValue.invoke([]);}catch(Exception error){rejected=error.msg.canFind("closed");}
    check(rejected,"closed callback rejected");
    check(bm.call("step").arrayValue[0].to!int==3,"remaining context continues shared state");
    auto other=new ScriptEngine;auto second=other.createModuleContext([buildPath(dir,"?.dua")]);
    other.bindContext(second,"self",Value.reflect(new Host("other")));other.newContextModule(second,"scenes").bind("root",Value.reflect(new Host("other-root")));
    check(other.instantiateModule("actor",second).call("step").arrayValue[0].to!int==1,"different engine/Play isolated");
    writeln("PASS shared ordinary / instance / self / scenes / helper / initializer / callback / interleaved Fibers / close / separate Play");return 0;
}
