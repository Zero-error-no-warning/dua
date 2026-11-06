module dua.coroutine_tests;

version(unittest) {
import dua;
import core.thread : Fiber;
import std.algorithm : canFind;
import std.conv : to;

private void expectNumbers(Value value,long[] expected){
    assert(value.kind==ValueKind.array&&value.arrayValue.length==expected.length,value.toHostString());
    foreach(i,n;expected)assert(value.arrayValue[i].toInt()==n,value.toHostString());
}
// 普通の関数・式の評価途中・短絡・三項演算子は中断前を再実行しません。
unittest {
    auto engine=new ScriptEngine;
    auto result=engine.run(q{
        int calls=0;
        int step(int n){calls+=1;yield n;return n+1;}
        int run(){
            auto a=step(2)+step(4)*3;
            auto b=false&&step(99)>0;
            auto c=true||step(98)>0;
            return (c?step(a):step(97))+calls;
        }
        auto co=coroutine.create(run);
        auto untouched=calls;
        auto a=coroutine.resume(co);auto b=coroutine.resume(co);
        auto c=coroutine.resume(co);auto d=coroutine.resume(co);
        return [untouched,a[1],b[1],c[1],d[1],calls];
    });
    expectNumbers(result,[0,2,4,18,22,3]);
}
// 再帰・ローカル・捕捉変数は別々の再開点で保持します。
unittest {
    auto engine=new ScriptEngine;
    auto value=engine.run(q{
        int walk(int n){if(n==0){yield 7;return 1;}return n*walk(n-1);}
        auto co=coroutine.create((){int x=2;auto inc=(){yield x;x+=1;return x;};return walk(5)+inc()+inc();});
        auto a=coroutine.resume(co);auto b=coroutine.resume(co);auto c=coroutine.resume(co);auto d=coroutine.resume(co);
        return [a[1],b[1],c[1],d[1]];
    });
    expectNumbers(value,[7,2,3,127]);
}
unittest {
    auto engine=new ScriptEngine;
    auto value=engine.run(q{
        auto co=coroutine.create((){
            int sum=0;
            for(auto i=0;i<5;i+=1){if(i==1)continue;if(i==4)break;yield i;sum+=i;}
            foreach(v;[4,5]){yield v;sum+=v;}
            foreach(i;0..2){yield i;sum+=i;}
            int j=0;while(j<2){j+=1;yield j;sum+=j;}
            switch(sum){case 18:yield 88;break;default:yield 99;}
            return sum;
        });
        auto values=[];
        while(coroutine.status(co)!="dead"){auto r=coroutine.resume(co);if(!r[0])error(r[1]);values~=r[1];}
        return values;
    });
    expectNumbers(value,[0,2,3,4,5,0,1,1,2,88,18]);
}
// catchの保留状態も保持し、例外時は内側だけ巻き戻します。
unittest {
    auto engine=new ScriptEngine;
    auto value=engine.run(q{
        int fail(){yield 3;error("boom");return 0;}
        auto co=coroutine.create((){
            try {return fail();} catch(e){yield e.kind;try {yield 4;error("again");}catch(other){return 9;}}
        });
        auto a=coroutine.resume(co);auto b=coroutine.resume(co);auto c=coroutine.resume(co);auto d=coroutine.resume(co);
        return a[1]==3&&b[1]=="ScriptError"&&c[1]==4&&d[0]&&d[1]==9;
    });
    assert(value.truthy());
}
// 既定引数とlazyの読み出しごとの評価もDスタックを使いません。
unittest {
    auto engine=new ScriptEngine;
    auto value=engine.run(q{
        int n=0;int next(){n+=1;yield n;return n;}
        int defaults(int a=next(),int b=next()){return a+b;}
        int twice(lazy int x){return x+x;}
        auto co=coroutine.create((){return defaults()+twice(next());});
        auto values=[];while(coroutine.status(co)!="dead"){auto r=coroutine.resume(co);if(!r[0])error(r[1]);values~=r[1];}
        return values;
    });
    expectNumbers(value,[1,2,3,4,10]);
}
// compound代入の対象固定、$のスコープ、単純代入のRHS先行順。
unittest {
    auto engine=new ScriptEngine;
    auto value=engine.run(q{
        auto data=[10,20];int pos=0;
        int index(){yield 1;return pos;}
        int rhs(){pos=1;yield 2;return 3;}
        auto co=coroutine.create((){data[index()]+=rhs();data[index()]=rhs();yield data[$-1];return data[0]+data[1];});
        auto values=[];while(coroutine.status(co)!="dead"){auto r=coroutine.resume(co);if(!r[0])error(r[1]);values~=r[1];}
        return values;
    });
    expectNumbers(value,[1,2,2,1,3,16]);
}
unittest {
    auto engine=new ScriptEngine;
    // 同じホストFiberの上で実行され、独立したFiberを生成しません。
    auto host=Fiber.getThis();size_t calls;
    engine.bindNative("sameHost",(scope const(Value)[] args){++calls;return Value.from(Fiber.getThis() is host);});
    assert(engine.run(q{
        auto co=coroutine.create((){yield sameHost();return sameHost();});
        auto a=coroutine.resume(co);auto b=coroutine.resume(co);return a[1]&&b[1];
    }).truthy());
    assert(calls==2);
    foreach(operation;["map","filter"]){
        auto value=engine.run("auto co=coroutine.create((){return "~operation~"([1,2],(int n){yield n;return n;});});return coroutine.resume(co);");
        assert(!value.arrayValue[0].truthy());
        assert(value.arrayValue[1].toHostString().canFind("synchronous native callback"),value.toHostString());
    }
    assert(engine.run(q{
        auto co=coroutine.create((){
            auto inside=map([1],(int n){return coroutine.isyieldable();});
            return coroutine.isyieldable()&&!inside[0];
        });
        return !coroutine.isyieldable()&&coroutine.resume(co)[1];
    }).truthy());
}
unittest {
    auto engine=new ScriptEngine;
    auto a=engine.createModuleContext(),b=engine.createModuleContext();
    auto ma=engine.newContextModule(a,"a"),mb=engine.newContextModule(b,"b");
    auto ca=ma.run(`int x=10;return coroutine.create((){yield x;x+=1;return x;});`);
    auto cb=mb.run(`int x=20;return coroutine.create((){yield x;x+=2;return x;});`);
    engine.bind("ca",ca);engine.bind("cb",cb);
    expectNumbers(engine.run(`return [coroutine.resume(ca)[1],coroutine.resume(cb)[1]];`),[10,20]);
    a.close();
    assert(!engine.run(`return coroutine.resume(ca)[0];`).truthy());
    assert(engine.run(`return coroutine.resume(cb)[1];`).toInt()==22);
    b.close();
}
unittest {
    auto engine=new ScriptEngine;
    auto result=engine.run(q{
        any co=null;
        co=coroutine.create((){auto own=coroutine.resume(co);yield own[0];return 6;});
        auto a=coroutine.resume(co);auto b=coroutine.resume(co);return a[0]&&!a[1]&&b[0]&&b[1]==6;
    });
    assert(result.truthy());
}
unittest {
    auto engine=new ScriptEngine;
    auto result=engine.run(q{
        auto co=coroutine.create((){
            auto data=[1,2];
            int edit(){data[0]=9;yield 3;return 4;}
            auto copied=[...data,edit()];
            int key(){yield 5;return 0;}
            auto item=data[key()];
            int outside(){return $;}
            bool rejected=false;try{outside();}catch(e){rejected=true;}
            yield copied[0];yield item;return rejected;
        });
        auto a=coroutine.resume(co);auto b=coroutine.resume(co);
        auto c=coroutine.resume(co);auto d=coroutine.resume(co);auto e=coroutine.resume(co);
        return a[1]==3&&b[1]==5&&c[1]==1&&d[1]==9&&e[0]&&e[1];
    });
    assert(result.truthy());
}
unittest {
    auto engine=new ScriptEngine;
    auto result=engine.run(q{
        auto co=coroutine.create((){
            auto obj={__index=(any self,string key){yield 1;return 10;},
                __newindex=(any self,string key,int value){yield 2;},
                __eq=(any a,any b){yield 3;return true;},
                __tostring=(any self){yield 4;return "item";}};
            auto a=obj.missing;obj.other=7;auto same=obj=={};auto text="a"~obj;
            return a==10&&same&&text=="aitem";
        });
        auto a=coroutine.resume(co);auto b=coroutine.resume(co);auto c=coroutine.resume(co);
        auto d=coroutine.resume(co);auto e=coroutine.resume(co);
        return a[1]==1&&b[1]==2&&c[1]==3&&d[1]==4&&e[0]&&e[1];
    });
    assert(result.truthy());
}
unittest {
    auto engine=new ScriptEngine;
    RunOptions options;options.limits.maxCallDepth=16;
    auto result=engine.run(q{
        int recurse(int n){if(n==0){yield 1;return 0;}return recurse(n-1)+1;}
        auto co=coroutine.create((){try{return recurse(30);}catch(e){return 99;}});
        return coroutine.resume(co);
    },options);
    assert(!result.arrayValue[0].truthy());
    assert(result.arrayValue[1].toHostString().canFind("limit:call-depth"),result.toHostString());
    options.limits.maxCallDepth=0;options.limits.maxSteps=100;
    result=engine.run(q{
        auto co=coroutine.create((){try{while(true){}}catch(e){return 99;}return 1;});
        return coroutine.resume(co);
    },options);
    assert(!result.arrayValue[0].truthy());
    assert(result.arrayValue[1].toHostString().canFind("limit:steps"),result.toHostString());
}
unittest {
    auto engine=new ScriptEngine;
    assert(engine.run(q{
        auto co=coroutine.create((){
            auto data={a=1,b=2};
            foreach(k,v;data){yield v;data.a=9;data.b=9;}
            int calls=0;int index(){calls+=1;return 0;}
            any nil=null;try{nil[index()]=1;}catch(e){}
            return calls;
        });
        auto a=coroutine.resume(co);auto b=coroutine.resume(co);auto c=coroutine.resume(co);
        return a[0]&&b[0]&&b[1]==9&&c[0]&&c[1]==0;
    }).truthy());
}
}
