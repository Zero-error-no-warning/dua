module dua.stdlib_migration_tests;
version(unittest):
import dua;

unittest {
    foreach(checked;[false,true]) {
        RunOptions options;options.typeCheck=checked;
        auto engine=new ScriptEngine;
        assert(engine.run(`import math;import algorithm;import string;
            return math.sqrt(9)==3 && math.sin(0)==0 && math.cos(0)==1
                && math.exp(0)==1 && math.log(1)==0 && math.tan(0)==0
                && math.fmod(5,2)==1 && math.fmin(2,3)==2 && math.fmax(2,3)==3
                && math.clamp(5,0,3)==3 && algorithm.clamp(-1,0,3)==0 && math.PI>3.14
                && string.format("%04d %.2f %s",3,1.25,"ok")=="0003 1.25 ok"
                && string.join(string.split("a,b",","),"/")=="a/b";`,options).truthy());
        assert(engine.run(`return string.format("%2$s %1$04d",7,"item");`,options).toHostString()=="item 0007");
        assert(engine.run(`import random;random.seed(42);return random.Random(42).front==Random(42).front;`,options).truthy());
        assert(!engine.runSafe(`import string;return string.format("%d");`,options).ok);
    }
    auto engine=new ScriptEngine;
    engine.bindAuto("Random",17);
    assert(engine.run(`import random;return Random==17 && random.Random(42).front>=0;`).truthy());
    foreach(name;["math","string","random","algorithm"]) {
        auto host=new ScriptEngine;
        host.newModule(name).bindAuto("answer",42);
        assert(host.run("import "~name~";return "~name~".answer;").toInt()==42);
        auto source=new ScriptEngine;
        source.registerModule(name,"export int answer=43;");
        assert(source.run("import "~name~";return "~name~".answer;").toInt()==43);
    }
    auto loader=new ScriptEngine;
    loader.run(`addModuleLoader((string name)=>"export int answer=44;");`);
    assert(loader.run(`import math;return math.answer;`).toInt()==44);
    foreach(metadataOnly;[false,true]) {
        auto metadata=new ScriptEngine;
        metadata.enableCompletionMetadata(metadataOnly);
        metadata.standardLibraryModule("math");metadata.standardLibraryModule("string");metadata.standardLibraryModule("random");
        auto catalog=metadata.completionRegistry.toJson();
        assert(catalog["symbols"]["math.sqrt"]["signatures"].array[0]["returnType"].str=="double");
        assert(catalog["symbols"]["Random"]["kind"].str=="type");
        assert(catalog["symbols"]["random.Random"]["kind"].str=="type");
    }
}
