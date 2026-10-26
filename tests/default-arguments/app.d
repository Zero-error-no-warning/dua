module dua.default_argument_probe;
import std;
import dua;
private int nativeDefault(int n=9){return n;}
private void callTwice(void delegate() cb){cb();cb();}
struct Case{string name;string source;bool good=true;}
void main(){
 Case[] cases=[
 Case("multiple",q{int f(int a,int b=2,int c=3){return a+b+c;}return f(1)==6 && f(1,5)==9 && f(1,5,6)==12;}),
 Case("no-default",q{int f(int x){return x+1;}return f(3)==4;}),
 Case("each-call",q{int n=0;int next(){n=n+1;return n;}int f(int x=next()){return x;}return f()==1 && f()==2 && n==2;}),
 Case("only-omitted",q{int n=0;int next(){n=n+1;return n;}int f(int a=next(),int b=next()){return a+b;}auto x=f(10,20);auto y=f(10);return x==30 && y==11 && n==1;}),
 Case("order",q{int log=0;int tap(int n){log=log*10+n;return n;}int f(int a,int b=tap(2),int c=tap(3)){return a+b+c;}auto x=f(tap(1));return x==6 && log==123;}),
 Case("earlier",q{int f(int a,int b=a+2,int c=b+3){return a+b+c;}return f(1)==10 && f(2,8)==21;}),
 Case("definition-scope",q{int x=4;int f(int n=x){return n;}int caller(){int x=99;return f();}return caller()==4;}),
 Case("body-shadow",q{int x=4;int f(int n=x){int x=9;return n;}return f()==4;}),
 Case("table-fresh",q{int f(table t={n=0}){t.n=t.n+1;return t.n;}return f()==1 && f()==1;}),
 Case("array-fresh",q{int f(int[] t=[0]){t[0]=t[0]+1;return t[0];}return f()==1 && f()==1;}),
 Case("reference-alias",q{table shared={n=0};int f(table t=shared){t.n=t.n+1;return t.n;}return f()==1 && f()==2 && shared.n==2;}),
 Case("null-explicit",q{bool f(int[] t=[]){return t is null;}return !f() && f(null);}),
 Case("lambda-arrow",q{auto f=(int a=1,int b=a+2)=>a+b;return f()==4 && f(3)==8 && f(3,4)==7;}),
 Case("lambda-block",q{auto f=(int a=1){return a;};return f()==1 && f(8)==8;}),
 Case("lambda-subroutine",q{int n=0;auto f=(int a=3):> n=n+a;f();return n==3;}),
 Case("nested-default",q{auto f=(int a=1,int b=((int x=2)=>x+1)())=>a+b;return f()==4;}),
 Case("late-capture",q{any f(any cb=()=>b,int b=7){return cb;}auto g=f();return g()==7;}),
 Case("varargs",q{int f(int a=1,int rest...){return a+rest.length;}return f()==1 && f(2)==2 && f(2,3,4)==4;}),
 Case("ufcs",q{int add(int x,int y=3){return x+y;}return 2.add()==5 && 2.add(4)==6 && 2.add==5;}),
 Case("native-default",q{return nativeDefault()==9 && nativeDefault(2)==2;}),
 Case("native-callback",q{int n=0;void work(int amount=3){n=n+amount;}callTwice(work);return n==6;}),
 Case("coroutine",q{int n=0;int next(){n=n+1;return n;}int work(int x=next()){yield x;return x+1;}auto co=coroutine.create(work);auto a=coroutine.resume(co);auto b=coroutine.resume(co);return a[0] && a[1]==1 && b[0] && b[1]==2 && n==1;}),
 Case("this",q{auto t={n=7,f=(int x=this.n)=>x};return t.f()==7;}),
 Case("module",q{import defs;return defs.f()==6 && defs.f(4)==10;}),
 Case("module-type",q{import typed;return typed.f()==9;}),
 Case("module-instance",q{import consumer;return consumer.check();}),
 Case("ordering-error",q{void f(int a=1,int b){}},false),
 Case("default-type",q{int f(int n="bad"){return n;}return f();},false),
 Case("missing",q{int f(int a,int b=2){return a+b;}return f();},false),
 Case("excess",q{int f(int a=1){return a;}return f(1,2);},false),
 Case("explicit-type",q{int f(int a=1){return a;}return f("bad");},false),
 Case("self-reference",q{int a=7;int f(int a=a){return a;}return f();},false),
 Case("forward-reference",q{int b=7;int f(int a=b,int b=1){return a;}return f();},false),
 Case("middle-skip",q{int f(int a,int b=2,int c=3){return a+b+c;}return f(1,,4);},false),
 Case("rest-default",q{int f(int a=1,int rest...=2){return a;}return f();},false)
 ];
 size_t count,failed;
 foreach(checked;[false,true])foreach(c;cases){
  auto e=new ScriptEngine;e.bindFunc!nativeDefault("nativeDefault");e.bindFunc!callTwice("callTwice");
  e.registerModule("defs","int base=2;export int f(int x=base,int y=x+2){return x+y;}");
  e.registerModule("typed","export table P {int n;}export int f(P p=P{n=9}){return p.n;}");
  e.registerModule("state","instance int n=0;export int f(int x=n+1){n=x;return x;}");
  e.registerModule("consumer","instance import state as a;instance import state as b;export bool check(){return a.f()==1 && a.f()==2 && b.f()==1;}");
  RunOptions o;o.typeCheck=checked;o.sourceName="default-argument-probe.dua";
  auto result=e.runSafe(c.source,o);
  if(result.ok!=c.good){writeln(format("FAIL %s checked=%s expectedOK=%s actual=%s error=%s",c.name,checked,c.good,result.ok,result.errorMessage));++failed;continue;}
  if(c.good && !result.value.truthy()){writeln(format("FAIL %s checked=%s result=%s",c.name,checked,result.value.toHostString()));++failed;continue;}
  ++count;
 }
 enforce(!failed,format("Default-argument probe failed=%s passed=%s",failed,count));
 writeln("PASS default-argument runtime cases=",count," modes=unchecked/checked; imports/UFCS/callback/coroutine/closures/fresh values/native defaults/errors");
}


