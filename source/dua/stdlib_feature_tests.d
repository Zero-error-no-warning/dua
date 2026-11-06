

module dua.stdlib_feature_tests;
version(unittest):
import dua;

unittest
{
    import dua.stdlib.json : decodeJson, encodeJson;
    import std.exception : assertThrown;
    assert(decodeJson("9223372036854775807").toInt() == long.max);
    assert(decodeJson("-9223372036854775808").toInt() == long.min);
    assert(decodeJson("9007199254740993").toInt() == 9007199254740993L);
    foreach (source; ["9223372036854775808", "18446744073709551616", "-9223372036854775809",
        "1e9999", "NaN", "[1,]", "{a:1}", "01", "true false", "", "\"unfinished"])
        assertThrown!Exception(decodeJson(source));
    foreach (checked; [false, true])
    {
        auto engine = new ScriptEngine;
        RunOptions options; options.typeCheck = checked;
        assert(engine.run(`return json.decode("{\"hp\":100}").hp;`, options).toInt() == 100);
        assert(engine.run(`auto v=json.decode("{\"a\":[true,null,1.5],\"text\":\"猫😀\"}");
            return v.a[0] && v.a[1]==null && v.a[2]==1.5 && v.text=="猫😀";`, options).truthy());
        assert(engine.run(`return json.encode(json.decode("[1,2,null]"));`, options).toHostString() == "[1,2,null]");
        assert(engine.run(`return json.encode(json.decode("{}"));`, options).toHostString() == "{}");
        assert(!engine.runSafe("return json.decode(1);", options).ok);
        assert(!engine.runSafe("return json.decode();", options).ok);
    }
}


unittest
{
    foreach (checked; [false, true])
    {
        auto engine = new ScriptEngine;
        RunOptions options; options.typeCheck = checked;
        assert(engine.run(`return string.join(string.split("a,b",","),"/");`, options).toHostString() == "a/b");
        assert(engine.run(`return json.encode(string.split(",a,,",","));`, options).toHostString() == `["","a","",""]`);
        assert(engine.run(`return json.encode(string.split("",","));`, options).toHostString() == `[""]`);
        assert(engine.run(`return string.join(string.split("猫😀猫","猫"),"犬");`, options).toHostString() == "犬😀犬");
        assert(engine.run(`return string.join([],",");`, options).toHostString() == "");
        foreach (source; [`return string.split("abc","");`, `return string.split(1,",");`,
            `return string.join([1],",");`, `return string.join(["a"],1);`, `return string.split("a");`])
            assert(!engine.runSafe(source, options).ok, source);
    }
}


unittest
{
    foreach (checked; [false, true])
    {
        auto engine = new ScriptEngine;
        RunOptions options; options.typeCheck = checked;
        assert(engine.run(`return json.encode(sorted([3,1,2]));`, options).toHostString() == "[1,2,3]");
        assert(engine.run(`auto a=[3,1,2];auto b=sorted(a);b[0]=9;return a[0]==3 && b[0]==9;`, options).truthy());
        assert(engine.run(`return json.encode(sorted(["z","a"]));`, options).toHostString() == `["a","z"]`);
        assert(engine.run(`auto a=[{k=1,id="a"},{k=0,id="b"},{k=1,id="c"}];
            return string.join(map(sorted(a,(any x,any y)=>x.k<y.k),(any x)=>x.id),"");`, options).toHostString() == "bac");
        assert(engine.run(`return sorted([9007199254740993,9007199254740992])[0];`, options).toInt() == 9007199254740992L);
        assert(engine.run(`return sorted([]).length;`, options).toInt() == 0);
        foreach (source; [`return sorted(1);`, `return sorted([1,"a"]);`, `return sorted([{}]);`,
            `return sorted([1,2],(int a,int b)=>1);`, `return sorted([1],null);`])
            assert(!engine.runSafe(source, options).ok, source);
    }
    auto engine = new ScriptEngine;
    engine.bindFunc("sorted", (long value)=>value+1);
    assert(engine.run("return sorted(3);").toInt() == 4);
    auto limited = new ScriptEngine;
    RunOptions options; options.limits.maxSteps = 20;
    assert(limited.runSafe("return sorted(iota(100));", options).errorKind == RunErrorKind.stepLimit);
}


unittest
{
    foreach (checked; [false, true])
    {
        auto engine = new ScriptEngine;
        RunOptions options; options.typeCheck = checked;
        assert(engine.run(`return reduce([1,2,3],0,(int a,int x)=>a+x);`, options).toInt() == 6);
        assert(engine.run(`return reduce([1,2,3],0,(int a,int x)=>a*10+x);`, options).toInt() == 123);
        assert(engine.run(`int calls=0;return reduce([],42,(int a,int x){calls+=1;return a+x;})==42 && calls==0;`, options).truthy());
        assert(engine.run(`return [1,2,3].reduce("",(string a,int x)=>a~cast!(string)x);`, options).toHostString() == "123");
        foreach (source; [`return reduce(1,0,(int a,int b)=>a+b);`, `return reduce([1],0,3);`,
            `return reduce([1],0,()=>missing);`, `return reduce([1],0,(int a,int b){error("stop");});`])
            assert(!engine.runSafe(source, options).ok, source);
    }
    auto engine = new ScriptEngine;
    engine.bindFunc("reduce", (long value)=>value+1);
    assert(engine.run("return reduce(3);").toInt() == 4);
}


unittest
{
    foreach (checked; [false, true])
    {
        auto engine = new ScriptEngine;
        RunOptions options; options.typeCheck = checked;
        assert(engine.run(`return json.encode(utf8.chars("猫😀"));`, options).toHostString() == `["猫","😀"]`);
        assert(engine.run(`return utf8.chars("").length;`, options).toInt() == 0);
        assert(engine.run(`return utf8.chars("é").length;`, options).toInt() == 2);
        assert(engine.run(`return string.join(utf8.chars("a猫😀"),"");`, options).toHostString() == "a猫😀");
        assert(engine.run(`auto text="猫😀";return text.length==7 && text.count==2 && text.charAt(1)=="😀";`, options).truthy());
        assert(!engine.runSafe("return utf8.chars(1);", options).ok);
        assert(!engine.runSafe("return utf8.chars();", options).ok);
    }
}
