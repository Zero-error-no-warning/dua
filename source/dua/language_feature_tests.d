

module dua.language_feature_tests;
version(unittest):
import dua;

unittest
{
    foreach (checked; [false, true])
    {
        auto engine = new ScriptEngine;
        RunOptions options; options.typeCheck = checked;
        assert(engine.run(`return null ?? 42;`, options).toInt() == 42);
        assert(engine.run(`return 0 ?? missing();`, options).toInt() == 0);
        assert(!engine.run(`return false ?? true;`, options).truthy());
        assert(engine.run(`return "" ?? "fallback";`, options).toHostString() == "");
        assert(engine.run(`return ([] ?? [1]).length;`, options).toInt() == 0);
        assert(engine.run(`int[] values;return (values ?? [42])[0];`, options).toInt() == 42);
        assert(engine.run(`int calls=0;any once(){calls+=1;return null;}return (once() ?? null ?? 5)==5 && calls==1;`, options).truthy());
        assert(engine.run(`return (null ?? false) ? 1 : 2;`, options).toInt() == 2);
        assert(engine.run(`return null ?? true || false;`, options).truthy());
        assert(engine.run(`any work(){yield 1;return 9;}auto co=coroutine.create((){
            yield 0 ?? work();return null ?? work();});
            auto a=coroutine.resume(co);auto b=coroutine.resume(co);auto c=coroutine.resume(co);
            return a[1]==0 && b[1]==1 && c[1]==9;`, options).truthy());
    }
}


unittest
{
    foreach (checked; [false, true])
    {
        auto engine = new ScriptEngine;
        RunOptions options; options.typeCheck = checked;
        assert(engine.run(`any user=null;return user?.profile?.name ?? "unknown";`, options).toHostString() == "unknown");
        assert(engine.run(`auto user={profile={name="Ada"}};return user?.profile?.name;`, options).toHostString() == "Ada");
        assert(engine.run(`int calls=0;int bump(){calls+=1;return 1;}any user=null;
            auto result=user?.call(bump());return result==null && calls==0;`, options).truthy());
        assert(engine.run(`int[] a;return a?.length==null && []?.length==0;`, options).truthy());
        assert(engine.run(`int calls=0;any once(){calls+=1;return {x=42};}return once()?.x==42 && calls==1;`, options).truthy());
        foreach (source; [`any a=null;return a.x;`, `auto a={};return a?.missing;`,
            `auto a={x=1};a?.x=2;`, `auto a={x={y=1}};a?.x.y=2;`,
            `auto a={xs=[1]};a?.xs[0]=2;`, `auto a={};return a?.f();`,
            `auto a={f=(){error("expected");}};return a?.f();`])
            assert(!engine.runSafe(source, options).ok, source);
        assert(engine.run(`any wait(){yield 1;return 2;}auto co=coroutine.create((){
            any a=null;yield a?.call(wait());return ({call=(int n)=>n})?.call(wait());});
            auto x=coroutine.resume(co);auto y=coroutine.resume(co);auto z=coroutine.resume(co);
            return x[1]==null && y[1]==1 && z[1]==2;`, options).truthy());
    }
}


unittest
{
    auto engine = new ScriptEngine;
    assert(engine.run(`int f(int a,int b=2,int c=3){return a*100+b*10+c;}return f(1,c:9);`).toInt() == 129);
    assert(engine.run(`int f(int a,int b=2){return a+b;}return f(b:4,a:3);`).toInt() == 7);
    assert(engine.run(`int log=0;int next(){log=log*10+1;return log;}
        int f(int a,int b){return a*100+b;}auto v=f(b:next(),a:next());return log==11 && v==1101;`).truthy());
    assert(engine.run(`int f(int a=1,int b=a+1,int c=b+1){return a+b+c;}return f(c:10);`).toInt() == 13);
    assert(engine.run(`int f(int a,int b=2){return a+b;}auto callable=f;return callable(b:3,a:4);`).toInt() == 7);
    assert(engine.run(`int f(int a,int b=2){return a+b;}return 3.f(b:4);`).toInt() == 7);
    assert(engine.run(`int f(lazy int a,int b=2){return b;}return f(b:4,a:missing());`).toInt() == 4);
    foreach (source; [`int f(int a,int b=2){return a+b;}return f(b:3);`,
        `int f(int a){return a;}return f(a:1,a:2);`, `int f(int a){return a;}return f(a:1,2);`,
        `int f(int a){return a;}return f(x:1);`, `int f(int a){return a;}return f(1,a:2);`, `return json.encode(value:1);`])
        assert(!engine.runSafe(source).ok, source);
    assert(engine.run(`any wait(){yield 1;return 4;}int f(int a,int b=2){return a+b;}
        auto co=coroutine.create(()=>f(b:wait(),a:3));
        auto x=coroutine.resume(co);auto y=coroutine.resume(co);return x[1]==1 && y[1]==7;`).truthy());
}


unittest
{
    foreach (checked; [false, true])
    {
        auto engine = new ScriptEngine;
        RunOptions options; options.typeCheck = checked;
        assert(engine.run(`string f(int count,string text="x"){return text~cast!(string)count;}
            return f(text:"item",count:3);`, options).toHostString() == "item3");
        assert(!engine.runSafe(`int f(int a,int b=2){return a+b;}return f(b:4);`, options).ok);
        assert(engine.run(`int f(int a=1,int b=a+1,int c=b+1){return a+b+c;}return f(c:10);`, options).toInt() == 13);
        engine.registerModule("named", `export string f(int n,string text="x"){return text~cast!(string)n;}`);
        assert(engine.run(`import named;return named.f(text:"item",n:4);`, options).toHostString() == "item4");
    }
}


unittest
{
    foreach (checked; [false, true])
    {
        auto engine = new ScriptEngine;
        RunOptions options; options.typeCheck = checked;
        assert(engine.run(`void bump(ref int n){n+=1;}int n=0;bump(n);return n;`, options).toInt() == 1);
        assert(engine.run(`void bump(ref int n){n+=1;}void forward(ref int x){bump(x);}int n=3;forward(n);return n;`, options).toInt() == 4);
        assert(engine.run(`void set(ref int a,ref int b){a=3;b=a+1;}int n=0;set(n,n);return n;`, options).toInt() == 4);
        assert(engine.run(`void replace(ref int[] a){a=[4,5];}int[] a=[1];replace(a);return a.length==2 && a[0]==4;`, options).truthy());
        assert(engine.run(`any capture(ref int n){return ()=>n;}int n=3;auto read=capture(n);n=4;return read();`, options).toInt() == 4);
        assert(engine.run(`void set(ref int a,int b=2){a=b;}int n=0;set(b:9,a:n);return n;`, options).toInt() == 9);
        assert(engine.run(`int ref=3;int f(int x){return x+ref;}return f(1);`, options).toInt() == 4);
        foreach (source; [`void f(ref int n){n=2;}f(1);`, `void f(ref int n){n=2;}auto a={n=1};f(a.n);`,
            `void f(ref int n){n=2;}double x=1.0;f(x);`, `void f(ref int n=1){}`, `void f(ref int n...){}`])
            assert(!engine.runSafe(source, options).ok, source);
        assert(engine.run(`void work(ref int n){n+=1;yield n;n+=1;}
            int n=0;auto co=coroutine.create(()=>work(n));auto a=coroutine.resume(co);
            auto first=n;auto b=coroutine.resume(co);return first==1 && n==2;`, options).truthy());
    }
}


unittest
{
    assert((new ScriptEngine).check(`void f(ref int n){}f(1);`).length > 0);
    foreach (checked; [false, true])
    {
        auto engine = new ScriptEngine;
        RunOptions options; options.typeCheck = checked;
        assert(engine.run(`auto f=(ref int x){x+=1;};int n=0;f(n);return n;`,options).toInt()==1);
        engine.registerModule("refs",`export void f(ref int x){x+=1;}`);
        assert(engine.run(`import refs;int n=3;refs.f(n);return n;`,options).toInt()==4);
    }
}


unittest
{
    foreach (checked; [false, true])
    {
        auto engine = new ScriptEngine;
        RunOptions options; options.typeCheck = checked;
        assert(engine.run(`int n=0;try{n=1;}finally{n=2;}return n;`,options).toInt()==2);
        assert(engine.run(`int n=0;int f(){try{return 7;}finally{n=3;}}auto result=f();return result==7 && n==3;`,options).truthy());
        assert(engine.run(`int n=0;try{error("x");}catch(e){n=1;}finally{n+=2;}return n;`,options).toInt()==3);
        assert(engine.run(`int n=0;try{try{error("x");}finally{n=1;}}catch(e){n+=2;}return n;`,options).toInt()==3);
        assert(engine.run(`int n=0;for(auto i=0;i<3;i+=1){try{if(i==0){continue;}break;}finally{n+=1;}}return n;`,options).toInt()==2);
        assert(engine.run(`int n=0;auto co=coroutine.create((){try{yield 1;return 2;}finally{n+=1;}});
            auto a=coroutine.resume(co);auto before=n;auto b=coroutine.resume(co);return a[1]==1 && before==0 && b[1]==2 && n==1;`,options).truthy());
        assert(engine.run(`int n=0;auto co=coroutine.create((){try{error("x");}finally{n+=1;}});
            auto result=coroutine.resume(co);return !result[0] && n==1;`,options).truthy());
        assert(engine.run(`table finally{int x;}try{}catch(e){}finally{x=3};return 42;`,options).toInt()==42);
        foreach(source;[`try{}finally{return 1;}`,`try{}finally{yield 1;}`,`try{}finally{break;}`])
            assert(!engine.runSafe(source,options).ok,source);
    }
    auto engine = new ScriptEngine;
    engine.load("int cleanupCount=0;");
    RunOptions options;options.limits.maxSteps=30;
    auto limited=engine.runSafe(`try{while(true){}}finally{cleanupCount+=1;}`,options);
    assert(!limited.ok && limited.errorKind==RunErrorKind.stepLimit);
    assert(engine.run("return cleanupCount;").toInt()==1);
    auto protectedLimit=engine.runSafe(`try{while(true){}}finally{while(true){}}`,options);
    assert(!protectedLimit.ok && protectedLimit.errorKind==RunErrorKind.stepLimit);
}


unittest
{
    foreach (checked; [false, true])
    {
        auto engine = new ScriptEngine;
        RunOptions options; options.typeCheck = checked;
        foreach (source; [
            `double x=1; x=2; return x is double && !(x is int) && x==2.0;`,
            `double f(double x){x=3;return x;}return f(1) is double;`,
            `double f(){return 7;}return f() is double;`,
            `double f(double x=2){return x;}return f() is double;`,
            `double f(lazy double x){return x;}return f(4) is double;`,
            `double[] a=[1,2];a[0]=3;a~=4;return a[0] is double && a[2] is double;`,
            `auto source=[1,2];double[] a=source;return source[0] is int && a[0] is double;`,
            `table T{double x;}auto t=T{x=1};t.x=2;return t.x is double;`,
            `struct S{double x;}auto s=S(1);s.x=2;return s.x is double;`,
            `alias Number=int|double;Number x=1;x=2;return x is int;`,
            `alias Number=double|int;Number x=1;return x is int;`,
            `alias Number=double|string;Number x=1;x=2;return x is double;`,
            `alias Float=double;Float x=1;return x is double;`,
            `void f(ref double x){x=2;}double x=1;f(x);return x is double;`,
            `auto co=coroutine.create((){double x=1;yield x;double f(double a){return a;}return f(2);});
              auto a=coroutine.resume(co);auto b=coroutine.resume(co);return a[1] is double && b[1] is double;`,
            `double x=9007199254740993;return x==9007199254740992.0;`,
            `return 1 is int && !(1 is double);`
        ]) assert((new ScriptEngine).run(source,options).truthy(),source);
        foreach (source; [
            `void f(ref double x){}int x=1;f(x);`,
            `void f(ref int x){x=2.5;}int x=1;f(x);`,
            `int x=1.5;`, `double x="1";`, `double f(double x){return x;}f("1");`
        ]) assert(!engine.runSafe(source,options).ok,source);
        engine.bindFunc("nativeDouble",(double x)=>x);
        assert(engine.run(`return nativeDouble(1) is double;`,options).truthy());
        assert(engine.run(`return nativeDouble(9007199254740993)==9007199254740992.0;`,options).truthy());
    }
}



private struct NumericHost { double value; }
private string chooseNumber(long value){return "int";}
private string chooseNumber(double value){return "double";}
private double nativeReference(ref double value){value+=1;return value;}

unittest
{
    foreach(checked;[false,true]) {
        RunOptions options;options.typeCheck=checked;
        auto engine=new ScriptEngine;
        engine.bindAuto("host",NumericHost.init);
        engine.bindFunc!chooseNumber("chooseNumber");
        engine.bindFunc!nativeReference("nativeReference");
        engine.bindFunc("delegateReference",(ref double value){return value;});
        assert(engine.run(`host.value=1;return host.value is double;`,options).truthy());
        assert(engine.run(`return chooseNumber(1)=="int" && chooseNumber(1.0)=="double";`,options).truthy());
        assert(!engine.runSafe(`return nativeReference(1);`,options).ok);
        assert(!engine.runSafe(`return delegateReference(1);`,options).ok);
        assert(engine.run(`return nativeReference(1.0);`,options).toFloat()==2);
        foreach(source;[
            `double sum(double values...){return values[0]+values[1];}return sum(1,2)==3.0;`,
            `double[double] values=[1:2];values[3]=4;return values[1] is double && values.keys[0] is double;`,
            `alias Number=double|int;Number f(Number x){return x;}return f(9007199254740993) is int;`,
            `auto co=coroutine.create((){double f(double x=1){yield x;return 2;}return f();});
                auto a=coroutine.resume(co);auto b=coroutine.resume(co);return a[1] is double && b[1] is double;`,
            `auto co=coroutine.create((){void f(ref double x){x=2;yield x;x=3;}double x=1;f(x);return x;});
                auto a=coroutine.resume(co);auto b=coroutine.resume(co);return a[1] is double && b[1] is double;`,
            `int cleanup=0;auto co=coroutine.create((){try{try{error("original");}catch(e){error("catch");}}
                finally{cleanup+=1;}});auto a=coroutine.resume(co);return !a[0] && cleanup==1;`
        ]) assert((new ScriptEngine).run(source,options).truthy(),source);
    }
}



unittest
{
    foreach(checked;[false,true]) {
        RunOptions options;options.typeCheck=checked;
        auto engine=new ScriptEngine;
        assert(engine.run(`alias ref=int;int read(ref[] values){return values[0];}
            auto f=(ref[] values)=>values[0];return read([3])+f([4]);`,options).toInt()==7);
    }
}
