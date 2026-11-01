module dua.public_visibility_tests;

version(unittest) enum runVisibilityTests=true;
else version(PublicVisibilityTests) enum runVisibilityTests=true;
else enum runVisibilityTests=false;

static if(runVisibilityTests) {
    import dua;
    import std.exception : enforce,assertThrown;
    import std.algorithm : canFind;
    import std.conv : to;

    class VisibilityBase {
        private string _kind="native";
        string kind(){return _kind;}
        package(dua) void kind(string value){_kind=value;}
        private int secret(int n){return n;}
        protected int hidden(int n){return n;}
        int mixed(string text){return 17;}
        package(dua) int mixed(int number){return 99;}
        int setting=3;
        @NoBind int hiddenField=5;
        const int immutableSetting=8;
    }
    class VisibilityDerived:VisibilityBase {}
    struct VisibilityStruct {
        int setting=4;
        @NoBind int hiddenField=6;
        private int _n=2;
        int number(){return _n;}
        package(dua) void number(int value){_n=value;}
    }

    void runPublicVisibilityChecks() {
        foreach(typeCheck;[false,true]) {
            auto engine=new ScriptEngine;
            auto native=new VisibilityBase;
            auto box=Value.reflect(VisibilityStruct.init);
            engine.bind("native",Value.reflect(native));engine.bind("box",box);
            engine.bind("derived",Value.reflect(new VisibilityDerived));
            RunOptions options;options.typeCheck=typeCheck;
            enforce(engine.run(`return native.kind;`,options).to!string=="native");
            enforce(engine.run(`return native.kind();`,options).to!string=="native");
            enforce(engine.run(`return derived.kind;`,options).to!string=="native");
            enforce(engine.run(`return native.mixed("x");`,options).toInt==17);
            engine.run(`native.setting=13;box.setting=14;`,options);
            enforce(native.setting==13,"native setting="~native.setting.to!string);
            enforce(engine.run(`return box.setting;`,options).toInt==14,"struct setting did not update");
            foreach(script;[`native.kind="forged";`,`native["kind"]="forged";`,`native.kind("forged");`,
                `box.number=20;`,`box["number"]=20;`,`box.number(20);`,`native.immutableSetting=9;`,
                `derived.kind="forged";`,`derived.kind("forged");`,`rawset(native,"kind","forged");`,
                `return native.secret(1);`,`return native.hidden(1);`,`return native.hiddenField;`,`return box.hiddenField;`]) {
                bool rejected;
                try engine.run(script,options);catch(Exception)rejected=true;
                enforce(rejected,"Unexpectedly permitted: "~script);
            }
            enforce(native.kind=="native"&&box.to!VisibilityStruct.number==2);
            // 普通のtableと、明示的に公開されたpublic fieldへの代入は維持します。
            enforce(engine.run(`auto t={};t.kind="ok";return t.kind;`,options).to!string=="ok");
            auto metadata=describeHostCompletionType!VisibilityDerived()["members"].object;
            enforce("hiddenField" !in metadata&&"secret" !in metadata&&"hidden" !in metadata);
            enforce(metadata["kind"]["signatures"].array.length==1);
            enforce(metadata["mixed"]["signatures"].array.length==1);
        }
    }
    unittest {runPublicVisibilityChecks();}
}
