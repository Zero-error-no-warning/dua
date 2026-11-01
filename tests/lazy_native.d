module lazy_native;
import dua;
import std.exception : enforce;
import std.stdio : writeln;
import std.algorithm : canFind;

class Host {
    int sideEffects;
    int bump(){return ++sideEffects;}
    int skip(lazy int x) { return 8; }
    int twice(lazy int x) { return x+x; }
    int mixed(int x) { return 1; }
    int mixed(lazy string x) { return x.length ? 2 : 3; }
    int same(int x) { return 1; }
    int same(lazy int x) { return 2; }
    int steps(lazy int[] x) { return cast(int)x.length; }
    int steps(int[] delegate() f) { return cast(int)f().length+10; }
}
int twiceFree(lazy int x){return x+x;}
int defaults;
int nextDefault(){return ++defaults;}
int defaultTwice(lazy int x=nextDefault()){return x+x;}
struct AliasHost { Host target; alias target this; }
void main() {
    foreach(checked;[false,true]) {
        auto e=new ScriptEngine;
        auto host=new Host;
        e.bindAuto("host",host);
        e.bindFunc!twiceFree("twiceFree");
        e.bindFunc!defaultTwice("defaultTwice");
        AliasHost aliasHost=AliasHost(new Host);
        e.bindAuto("aliasHost",aliasHost);
        RunOptions o;o.typeCheck=checked;
        defaults=0;
        enforce(e.run("return defaultTwice();",o).toInt()==3 && defaults==2);
        enforce(e.run(q{
            int n=0;
            int bump(){n=n+1;return n;}
            auto a=host.skip(bump());
            auto b=host.twice(bump());
            auto c=host.mixed(bump());
            auto d=host.mixed("x");
            return a==8 && b==3 && c==1 && d==2 && n==3
                && host.steps([1,2])==2 && host.steps(() => [1,2])==12;
        },o).truthy());
        enforce(e.run(q{
            int ufcsCalls=0;
            int nextUfcs(){ufcsCalls=ufcsCalls+1;return ufcsCalls;}
            return nextUfcs().twiceFree()==3 && ufcsCalls==2;
        },o).truthy());
        enforce(e.run(q{
            int calls=0;
            int next(){calls=calls+1;return calls;}
            int forward(lazy int value){return twiceFree(value);}
            return forward(next())==3 && aliasHost.twice(next())==7 && calls==4;
        },o).truthy());
        auto result=e.runSafe("return host.same(host.bump());",o);
        enforce(!result.ok && result.errorMessage.canFind("Ambiguous lazy overload") && host.sideEffects==0,result.errorMessage);
        result=e.runSafe("any unknown(){return host.bump();} return host.mixed(unknown());",o);
        enforce(!result.ok && result.errorMessage.canFind("without evaluation") && host.sideEffects==0,result.errorMessage);
    }
    writeln("native lazy tests passed");
}
