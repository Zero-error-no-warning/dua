module member_defaults;
import dua;
import dua.module_analysis;
import std.stdio : writeln;
import std.algorithm : canFind;
import std.string : toLower;
import std.exception : enforce;

size_t checks;
void good(string source) {
    foreach (checked; [false, true]) {
        auto engine = new Dua.ScriptEngine;
        RunOptions options; options.typeCheck = checked; options.sourceName = "member-defaults.dua";
        auto result = engine.runSafe(source, options);
        enforce(result.ok && result.value.truthy(), source ~ "\n" ~ result.errorMessage);
        ++checks;
    }
}
void bad(string source, string expected) {
    foreach (checked; [false, true]) {
        auto engine = new Dua.ScriptEngine;
        RunOptions options; options.typeCheck = checked; options.sourceName = "member-defaults.dua";
        auto result = engine.runSafe(source, options);
        enforce(!result.ok && result.errorMessage.toLower.canFind(expected.toLower), source ~ "\n" ~ result.errorMessage);
        ++checks;
    }
}
void main() {
    good(q{table T { string name; int hp = 100; int[] items = []; } auto a=T{name="Ada"}; auto b=T{name="Bob",hp=5}; return a.hp==100 && b.hp==5 && a.items.length==0;});
    good(q{table T{int x=1;} auto v=T{}; return v.x==1 && v is T;});
    good(q{table T{int x=1;} auto v=T{extra=2}; return v.x==1 && v.extra==2;});
    good(q{int calls=0; int next(){calls=calls+1;return calls;} table T{int x=next();int y=next();} auto a=T{};auto b=T{x=9};return a.x==1&&a.y==2&&b.y==3&&calls==3;});
    good(q{int calls=0; int next(){calls=calls+1;return calls;} table T{int x=next();} auto a=T{x=9};return calls==0&&a.x==9;});
    good(q{table T{int x=1;int y=2;}auto v=T{...{x=7}};return v.x==7&&v.y==2;});
    good(q{table T{int x=1;}auto v=T{["x"]=7};return v.x==7;});
    good(q{table T{int[] a=[1];table b={x=1};}auto a=T{};auto b=T{};a.a[0]=9;a.b.x=9;return b.a[0]==1&&b.b.x==1;});
    good(q{table T{table[] nested=[{x=1}];int[string] map=["a":1];}auto a=T{};auto b=T{};a.nested[0].x=9;a.map["a"]=7;return b.nested[0].x==1&&b.map["a"]==1;});
    good(q{int[] shared=[1];table T{int[] items=shared;}auto a=T{};auto b=T{};a.items[0]=9;return b.items[0]==9;});
    good(q{table C{int x=1;}table T{C child=null;int[] a=[];}auto v=T{a=null};return v.child==null&&v.a is null;});
    good(q{table C{int x=1;}table T{C child=C{};}auto v=T{child=null};return v.child==null;});
    good(q{int seed=3;table T{int seed=99;int value=seed;}int make(){int seed=10;return T{}.value;}seed=4;return make()==4;});
    good(q{int make(){int seed=4;table T{int x=seed;}auto a=T{};seed=5;return a.x+T{}.x;}return make()==9;});
    good(q{table Base{int a=1;}table Next{...Base;int b=2;}alias Alias=Next;auto x=Alias{};return x.a==1&&x.b==2&&x is Base&&x is Next;});
    good(q{int seq=0;int next(){seq=seq+1;return seq;}table A{int a=next();}table B{int b=next();}table C{int own=next();...A;...B;}auto v=C{};return v.a==1&&v.b==2&&v.own==3;});
    good(q{table T{int x=1;}alias Required=T & !null;auto a=Required{};T[] xs=[T{}];return a.x==1&&xs[0].x==1;});
    good(q{struct V{int x=0;int y=0;}auto a=V();auto b=V(5);auto c=V({y=3});return a==V(0,0)&&b==V(5,0)&&c==V(0,3);});
    good(q{struct V{int x=0;int y;}auto a=V({y=2});auto b=V(1,3);return a.x==0&&a.y==2&&b.y==3;});
    good(q{struct V{int[] a=[];table b={x=1};}auto a=V();auto b=V();a.a~=1;a.b.x=9;return b.a.length==0&&b.b.x==1;});
    good(q{int calls=0;int next(){calls=calls+1;return calls;}struct V{int x=next();int y=next();}auto v=V(8);auto w=V({x=9});return v.x==8&&v.y==1&&w.y==2&&calls==2;});
    good(q{struct V{int x=1;int y=2;}auto v=V({["y"]=4});auto w=V({...{x=3}});return v==V(1,4)&&w==V(3,2);});
    good(q{struct V{int x=1;}auto a=V();auto b=a;b.x=9;auto list=[a];list[0].x=8;return a.x==1&&b.x==9;});
    good(q{table C{int x=1;}struct V{C child=C{};int[] a=[];}auto v=V({child=null,a=null});return v.child==null&&v.a is null;});
    good(q{struct Inner{int n=3;}struct Outer{Inner inner=Inner();}auto x=Outer();auto y=Outer();x.inner.n=8;return y.inner.n==3;});
    good(q{table T{int x=1;}int read(T x=T{}){return x.x;}return read()==1;});
    good(q{table T{int x=1;}auto f=()=>T{};return f().x==1;});
    good(q{int seq=0;int mark(int n){seq=seq*10+n;return n;}table T{int x=mark(2);int y=mark(3);}auto a=T{y=mark(1)};return seq==12&&a.x==2&&a.y==1;});
    good(q{int seed=4;table Base{int x=seed;}int make(){int seed=9;table Child{...Base;int y=seed;}auto a=Child{};return a.x*10+a.y;}return make()==49;});
    good(q{table T{int delegate(int) f=(int n)=>n+2;}auto a=T{};return a.f(3)==5;});
    good(q{struct V{table child={x=1};}auto a=V();auto b=a;b.child.x=9;return a.child.x==9;});
    bad(q{table T{int a=1;int required;}return T{};},"missing");
    bad(q{struct V{int a=1;int required;}return V();},"missing");
    bad(q{struct V{int a=1;int required;}return V(2);},"missing");
    bad(q{struct V{int a=1;int required;}return V({});},"missing");
    bad(q{struct V{int a=1;}return V(1,2);},"argument");
    bad(q{table T{int x=1;}return T{x=null};},"expect");
    bad(q{struct V{int x=1;}return V(null);},"expect");
    bad(q{table C{int x=1;}table T{C & !null child=C{};}return T{child=null};},"null");
    bad(q{table T{int x="bad";}return T{};},"expect");
    bad(q{struct V{int x="bad";}return V();},"expect");
    bad(q{table T{int x=1;}return T{x=1,x=2};},"Duplicate");
    bad(q{table T{int x=1;}return T{...{x=1},x=2};},"Duplicate");
    bad(q{table A{int x=1;}table B{...A;int x=2;}return B{};},"conflict");
    bad(q{table A{int x=1;}table B{int x=2;}table C{...A;...B;}return C{};},"conflict");
    bad(q{table T{int x=1;}T value={};return value;},"expected");
    bad(q{table T{int x=1;}return cast(T){};},"cast");
    bad(q{table T{int x=1;}struct S{int x=1;}return S{};},"table");
    bad(q{table T{int x=1;int y=x;}return T{};},"Undefined");
    bad(q{table T{int x=this.x;}auto receiver={x=7,make=()=>T{}};return receiver.make();},"Undefined");
    // 未使用の既定式も事前検査する一方、typeCheckなしでは評価を省略します。
    {
        auto engine=new Dua.ScriptEngine;
        auto source=q{table T{int x="bad";}return T{x=7}.x==7;};
        enforce(engine.run(source).truthy()); ++checks;
        enforce(engine.check(source).length>0); ++checks;
        enforce(engine.check(q{struct V{int x="bad";}return V(7);}).length>0); ++checks;
    }
    // 必須欠落時には既定式を評価しません。
    foreach (structure; [false,true]) {
        auto engine=new Dua.ScriptEngine; int calls;
        engine.bindNative("tick",(scope const(Dua.Value)[] args){++calls;return Dua.Value.from(1);});
        auto source=structure ? q{struct V{int a=tick();int b;}return V();} : q{table T{int a=tick();int b;}return T{};};
        enforce(!engine.runSafe(source).ok && calls==0); ++checks;
    }
    foreach(checked;[false,true]) {
        auto engine=new Dua.ScriptEngine; RunOptions options;options.typeCheck=checked;
        engine.registerModule("base",q{int seed=4;export table B{int x=seed;int[] a=[];}export table C{...B;int own=99;}export struct V{int x=seed;int y=0;}});
        engine.registerModule("child",q{import base;export alias Alias=base.C;});
        auto result=engine.runSafe(q{import child;import base;auto a=child.Alias{};auto b=base.C{};a.a~=3;auto v=base.V({y=2});return a.x==4&&a.own==99&&b.a.length==0&&v.x==4&&v.y==2;},options);
        enforce(result.ok&&result.value.truthy(),result.errorMessage);++checks;
        engine.registerModule("instances",q{export instance int seed=2;export table T{int x=seed;}export struct V{int x=seed;}export void set(int x){seed=x;}export T make(){return T{};}export V vector(){return V();}});
        result=engine.runSafe(q{import instances;auto other=new instances;other.set(9);auto a=other.make();auto v=other.vector();instances.set(7);return a.x==2&&v.x==2&&other.make().x==7&&other.vector().x==7;},options);
        enforce(result.ok&&result.value.truthy(),result.errorMessage);++checks;
    }
    // 既定式にも通常の実行量と呼出し深度の制限を適用します。
    {
        auto engine=new Dua.ScriptEngine; RunOptions options;options.limits.maxSteps=80;
        auto result=engine.runSafe(q{int spin(){while(true){}return 0;}table T{int x=spin();}return T{};},options);
        enforce(!result.ok&&result.errorKind==RunErrorKind.stepLimit);++checks;
        options.limits.maxSteps=0;options.limits.maxCallDepth=12;
        result=engine.runSafe(q{table Recursive{Recursive child=Recursive{};}return Recursive{};},options);
        enforce(!result.ok&&result.errorKind==RunErrorKind.callDepthLimit);++checks;
    }
    // 初期化失敗したmoduleから取り出した既定式も再利用しません。
    {
        auto engine=new Dua.ScriptEngine;Dua.Value escaped;
        engine.bindNative("keep",(scope const(Dua.Value)[] args){escaped=cast(Dua.Value)args[0];return Dua.Value.nullValue();});
        engine.registerModule("failed",q{table T{int x=1;}keep(()=>T{});error("failed initialization");});
        enforce(!engine.runSafe("import failed;").ok);bool rejected;
        try{escaped.functionValue.invoke([]);}catch(Exception error){rejected=error.msg.canFind("failed module");}
        enforce(rejected);++checks;
    }
    // 解析は既定式を実行せず、定義元と省略可能フィールドの情報を公開します。
    {
        auto engine=new Dua.ScriptEngine;
        auto analysis=engine.analyzeModule(q{export table T{int a=neverRun();int b;}export struct V{int x=1;int y;}} ,"analysis.dua");
        enforce(analysis.diagnostics.length==0);
        auto t=analysis.root.types[0];enforce(t.defaultFields==["a"]&&t.fieldOrder==["a","b"]);++checks;
        engine.registerModule("broken", "export table T {\n int x = missing();\n}");
        auto result=engine.runSafe("import broken;return broken.T{};");
        enforce(!result.ok&&result.diagnostic.line==2&&result.diagnostic.sourceName=="broken"&&result.diagnostic.hasSourceText,result.errorMessage);++checks;
    }
    // 宣言元contextを他の呼出し元contextで置き換えず、終了したcontextも使用しません。
    {
        auto engine=new Dua.ScriptEngine;
        engine.registerModule("owner",q{export table T{int value=self.value;}export struct V{int value=self.value;}export T make(){return T{};}export V vector(){return V();}});
        auto first=engine.createModuleContext;auto second=engine.createModuleContext;
        engine.bindContext(first,"self",Dua.Value.from(["value":Dua.Value.from(3)]));
        engine.bindContext(second,"self",Dua.Value.from(["value":Dua.Value.from(8)]));
        auto a=engine.instantiateModule("owner",first);auto b=engine.instantiateModule("owner",second);
        auto af=a.get("make");auto av=a.get("vector");
        enforce(af.functionValue.invoke([]).tableValue["value"].toInt()==3);++checks;
        enforce(b.get("make").functionValue.invoke([]).tableValue["value"].toInt()==3);++checks;
        enforce(av.functionValue.invoke([]).tableValue["value"].toInt()==3);++checks;
        first.close();bool rejected;
        try{af.functionValue.invoke([]);}catch(Exception error){rejected=error.msg.canFind("closed");}
        enforce(rejected);++checks;
        rejected=false;try{b.get("vector").functionValue.invoke([]);}catch(Exception error){rejected=error.msg.canFind("closed");}enforce(rejected);++checks;second.close();
    }
    writeln("member defaults: ",checks," checks passed");
}
