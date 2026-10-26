module with_syntax;
import dua;
import std;
import core.thread : Fiber;

private class NativeWithTarget {
    long x;
    this(long x){this.x=x;}
    long read(){return x;}
    long wait(){Fiber.yield();return x;}
}

void main(){
    size_t count;
    void good(string name,string source){
        foreach(checked;[false,true]){
            auto engine=new ScriptEngine;RunOptions options;options.typeCheck=checked;
            options.sourceName="with-"~name~".dua";
            auto result=engine.runSafe(source,options);
            enforce(result.ok && result.value.truthy(),name~": "~result.errorMessage~" result="~result.value.toHostString());
        }
        ++count;writeln("PASS ",name);stdout.flush();
    }
    void bad(string name,string source,string message){
        foreach(checked;[false,true]){
            auto engine=new ScriptEngine;RunOptions options;options.typeCheck=checked;options.sourceName="with-"~name~".dua";
            auto result=engine.runSafe(source,options);
            enforce(!result.ok && result.errorMessage.canFind(message),name~": "~result.errorMessage);
            enforce(result.diagnostic.line>0 && result.diagnostic.column>0,"Missing location: "~name);
        }
        ++count;writeln("PASS ",name);stdout.flush();
    }
    good("table meta and nominal alias",q{
        auto meta={};table Hoge with meta {int value;} alias H=Hoge;
        meta["opBinary+"]=(any a,any b)=>H{value=a.value+b.value};
        auto a=Hoge{value=2};auto b=H{value=3};auto c=a+b;
        return c.value==5 && c is Hoge && length(c)==1 && rawget(c,"__meta")==null && getmetatable(c)==meta;
    });
    good("struct meta and value copy",q{
        auto meta={};struct Point with meta {int x;int y;}
        meta["opBinary+"]=(any a,any b)=>Point(a.x+b.x,a.y+b.y);
        auto a=Point(1,2);auto b=a;b.x=5;auto c=a+b;
        return a.x==1 && c.x==6 && c.y==4 && getmetatable(c)==meta;
    });
    good("captured meta handle",q{
        auto first={};auto meta=first;table A with meta {int x;}
        meta={};first["opUnary-"]=(any a)=>-a.x;
        return -(A{x=3})==-3 && getmetatable(A{x=1})==first;
    });
    good("explicit overrides and clearing",q{
        auto meta={"opUnary-"=(any a)=>1};table A with meta {int x;}
        auto a=A{x=1};auto b=A{x=1};setmetatable(a,{"opUnary-"=(any a)=>2});
        bool ok=-a==2 && -b==1;setmetatable(a,null);
        return ok && getmetatable(a)==null && getmetatable(b)==meta && length(a)==1;
    });
    good("whole body and bare lookup",q{
        auto vec={x=3,y=4};int x=7;int twice(int n){return n*2;}
        auto d=with(vec) twice(.x*.x+.y*.y)+x;
        return d==57 && (with(vec) .x)+x==10;
    });
    good("target once nested and chain",q{
        int calls=0;any target(){calls+=1;return {x=2,child={x=9}};}
        auto total=with(target()) .x+(with(.child) .x)+.child.x;
        return calls==1 && total==20;
    });
    good("methods and closure retention",q{
        auto v={x=3,read=()=>this.x};auto f=with(v) () => .read();
        auto other={x=8};auto result=with(other) f()+.x;
        return result==11 && f()==3;
    });
    good("coroutine lexical context",q{
        auto make=(any v)=>with(v) (){yield .x;return .x;};
        auto a=coroutine.create(make({x=2}));auto b=coroutine.create(make({x=9}));
        auto a1=coroutine.resume(a);auto b1=coroutine.resume(b);auto a2=coroutine.resume(a);
        return a1[0] && a1[1]==2 && b1[0] && b1[1]==9 && a2[0] && a2[1]==2;
    });
    good("ordinary types unchanged",q{
        table A{int x;}struct B{int x;}auto a=A{x=1};auto b=B(2);auto copy=b;copy.x=3;
        return getmetatable(a)==null && getmetatable(b)==null && b.x==2;
    });
    good("keyword named members",q{
        auto t={["new"]=()=>4,["instance"]=7};return with(t) .new()+.instance==11;
    });
    bad("outside dot","return .x;","requires a with");
    bad("missing property","auto x=9;return with({}) .x;","Unknown property");
    bad("missing method","int f(any x){return 1;}return with({}) .f();","No method");
    bad("chain missing method","int f(any x){return 1;}return with({child={}}) .child.f();","No method");
    bad("call chain assignment","auto t={get=()=>({x=1})};with(t) .get().x=2;","assignment is not supported");
    bad("with assignment","auto a={x=1};with(a) .x=2;","assignment is not supported");
    bad("nested closure assignment","auto a={x=1};auto f=with(a) (){.x=2;};","assignment is not supported");
    bad("bad target","return with(3) 1;","with target");
    bad("bad meta","auto meta=3;table A with meta{int x;}","Type with requires");
    bad("forward meta","table A with meta{int x;}auto meta={};","meta");
    bad("local shared type meta","void f(){auto m={};table A with m{int x;}}","module top level");
    auto engine=new ScriptEngine;
    engine.registerModule("model",q{export auto meta={};export table A with meta{int x;}export alias Alias=A;
        meta["opUnary-"]=(any a)=>-a.x;export struct B with meta{int x;}});
    auto result=engine.runSafe("import model;table Other with model.meta{int x;}auto a=model.Alias{x=4};auto b=model.B(5);auto c=Other{x=6};return -a==-4 && -b==-5 && -c==-6 && a is model.A; ");
    enforce(result.ok && result.value.truthy(),"import/alias: "~result.errorMessage);++count;
    writeln("PASS import/alias");
    auto contextual=new ScriptEngine;
    contextual.registerModule("contextual",q{
        export auto meta={tag=tag};
        export table A with meta {int x;}
        instance int state=0;
        export any callback(){state+=1;return with({x=state,name=tag}) ()=>[.x,.name];}
        export any object(){return A{x=3};}
        export any change(){meta.extra=9;}
    });
    auto ca=contextual.createModuleContext(),cb=contextual.createModuleContext();
    contextual.bindContext(ca,"tag",Value.from("A"));contextual.bindContext(cb,"tag",Value.from("B"));
    auto ma=contextual.instantiateModule("contextual",ca),mb=contextual.instantiateModule("contextual",cb);
    auto fa=ma.call("callback"),fb=mb.call("callback");
    enforce(fa.invoke([]).arrayValue[1].to!string=="A"&&fb.invoke([]).arrayValue[1].to!string=="B","with closure contexts");
    ma.call("change");auto objectB=mb.call("object");
    contextual.bind("objectB",objectB);
    enforce(contextual.run("return getmetatable(objectB).tag==\"A\" && getmetatable(objectB).extra==9;").truthy(),"shared canonical type meta capture");
    ca.close();bool closed;try{fa.invoke([]);}catch(Exception e){closed=e.msg.canFind("closed");}
    enforce(closed&&fb.invoke([]).arrayValue[1].to!string=="B","closed origin and surviving context");cb.close();
    ++count;writeln("PASS shared type meta / instance closures / context close");
    auto nativeEngine=new ScriptEngine;
    nativeEngine.bindAuto("a",new NativeWithTarget(2));nativeEngine.bindAuto("b",new NativeWithTarget(9));
    enforce(nativeEngine.run("return with(a) .read()+.x;").toInt()==4,"native reflected getter/method");
    Value av,bv;
    auto af=new Fiber({av=nativeEngine.run("return with(a) .wait()+.x;");},1024*1024);
    auto bf=new Fiber({bv=nativeEngine.run("return with(b) .wait()+.x;");},1024*1024);
    af.call();bf.call();af.call();bf.call();
    enforce(av.toInt()==4&&bv.toInt()==18,"native Fiber lexical target");
    ++count;writeln("PASS reflected target and native Fiber resume");
    writeln("PASS ",count," focused with syntax cases (checked off/on); no GUI");
}
