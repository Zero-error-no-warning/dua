module dua.string_index_tests;
version(unittest):
import dua;
import std.algorithm : canFind;
import std.conv : to;

unittest {
    // Expected values come from D's actual immutable(char) indexing and length.
    foreach(text;["", "ABC", "日本語", "😀🦊", "é", "が", "A日😀é", "A\0B",
        cast(string) [cast(immutable(char)) 0xFF, cast(immutable(char)) 0x80]]) {
        auto engine=new ScriptEngine;
        engine.bind("text",Value.from(text));
        foreach(code;[
            q{auto result=[];for(auto i=0;i<text.length;i+=1)result~=text[i];return result;},
            q{auto co=coroutine.create((){auto result=[];for(auto i=0;i<text.length;i+=1){yield;result~=text[i];}return result;});
                any result=null;while(coroutine.status(co)!="dead"){auto r=coroutine.resume(co);if(!r[0])error(r[1]);result=r[1];}return result;}
        ]) {
            auto result=engine.run(code);
            assert(result.arrayValue.length==text.length);
            foreach(i;0..text.length){
                assert(result.arrayValue[i].kind==ValueKind.integer);
                assert(result.arrayValue[i].toInt()==cast(ubyte)text[i]);
            }
        }
        foreach(expr;["text.length", "length(text)", "len(text)", "string.len(text)"])
            assert(engine.run("return "~expr~";").toInt()==text.length);
        if(text.length) assert(engine.run("return text[$-1];").toInt()==cast(ubyte)text[$-1]);
        foreach(index;["-1",text.length.to!string,"9223372036854775807"]){
            auto source="return text["~index~"];";
            auto result=engine.runSafe(source);assert(!result.ok&&result.errorMessage.canFind("String index out of range"));
            auto co=engine.run("auto co=coroutine.create((){"~source~"});return coroutine.resume(co);");
            assert(!co.arrayValue[0].truthy()&&co.arrayValue[1].toHostString().canFind("String index out of range"));
        }
    }
}

unittest {
    auto engine=new ScriptEngine;
    assert(engine.run(q{return "AB"[false]==65&&"AB"[true]==66&&"日本".length==6&&utf8.len("日本")==2;}).truthy());
    foreach(code;[q{string s="ABC";s[0]=90;},q{string s="ABC";s[0]+=1;},q{string s="ABC";s[0]-=1;}]) {
        auto result=engine.runSafe(code);assert(!result.ok&&result.errorMessage.canFind("immutable"),result.errorMessage);
        auto co=engine.run("auto co=coroutine.create((){"~code~"});return coroutine.resume(co);");
        assert(!co.arrayValue[0].truthy()&&co.arrayValue[1].toHostString().canFind("immutable"));
        auto diagnostics=engine.check(code);
        assert(diagnostics.canFind!(d=>d.message.canFind("immutable")),code);
    }
    foreach(index;["0.0","\"0\"","null","[0]"]){
        auto code="string text=\"AB\";return text["~index~"];";
        auto result=engine.runSafe(code);assert(!result.ok&&result.errorMessage.canFind("integer"),result.errorMessage);
        assert(engine.check(code).length,code);
        auto co=engine.run("auto co=coroutine.create((){"~code~"});return coroutine.resume(co);");
        assert(!co.arrayValue[0].truthy()&&co.arrayValue[1].toHostString().canFind("integer"));
    }
    foreach(type;["byte","ubyte","short","ushort","int","uint","long","ulong","bool"]){
        auto source=type~" index="~(type=="bool"?"false":"0")~";string text=\"日本\";int value=text[index];return value;";
        assert(!engine.check(source).length,source);
        RunOptions options;options.typeCheck=true;
        auto result=engine.runSafe(source,options);assert(result.ok&&result.value.toInt()==230,result.errorMessage);
    }
    foreach(source;[
        q{int head(string s){return s[0];} return head("A");},
        q{alias Text=string;Text s="A";int value=s[0];int size=s.length;return value;},
        q{int value="A"[0];return value;}
    ])assert(!engine.check(source).length,source);
    assert(engine.check(q{string wrong="A"[0];}).length);
    assert(engine.check(q{return "A"[0,1];}).length);
    assert(!engine.runSafe(q{return "A"[0,1];}).ok);
    // No accidental extension to character slicing/iteration.
    assert(!engine.runSafe(q{return "A"[0..1];}).ok);
    assert(engine.check(q{return "A"[0..1];}).length);
    assert(!engine.runSafe(q{foreach(c;"A"){};}).ok);
}

unittest {
    auto result=(new ScriptEngine).run(q{
        int calls=0;
        string receiver(){calls+=1;yield;return "😀";}
        int index(){calls+=1;yield;return 3;}
        auto co=coroutine.create((){return receiver()[index()];});
        if(!coroutine.resume(co)[0])error("resume failed");if(!coroutine.resume(co)[0])error("resume failed");
        auto result=coroutine.resume(co);if(!(result[0]&&result[1]==128&&calls==2))error("evaluation order");
        auto nested=coroutine.create((){yield;return "AB"[[0,1][$-1]]+"日"[$-1];});
        coroutine.resume(nested);auto finalValue=coroutine.resume(nested);
        return finalValue[0]&&finalValue[1]==231;
    });
    assert(result.truthy());
}

unittest {
    // A built-in property, like D: a same-named UFCS function cannot replace it.
    auto source=q{
        string length(string value){return "override";}
        string s="日";int count=s.length;
        auto co=coroutine.create((){yield;return s.length;});
        coroutine.resume(co);auto r=coroutine.resume(co);
        return count==3&&r[0]&&r[1]==3&&length(s)=="override";
    };
    auto engine=new ScriptEngine;
    assert(engine.check(source).length==0);
    assert(engine.run(source).truthy());
    assert(engine.check(q{string s="A";s.length=0;}).length);
    assert(!engine.runSafe(q{string s="A";s.length=0;}).ok);
    foreach(testCase;[
        q{string s="A";int writes=0;int rhs(){writes+=1;return 1;}try{s[0]+=rhs();}catch(e){}return writes==0&&s=="A";},
        q{string s="A";int writes=0;int rhs(){writes+=1;return 1;}auto co=coroutine.create((){try{s[0]+=rhs();}catch(e){}return writes==0&&s=="A";});return coroutine.resume(co)[1];}
    ])assert((new ScriptEngine).run(testCase).truthy());
}

unittest {
    import std.algorithm.searching : count;
    import std.utf : byDchar;
    foreach(text;["", "A", "あいう", "😀🦊", "é", "が", "A\0B",
        cast(string)[cast(immutable(char))0xFF,cast(immutable(char))0x80],
        cast(string)[cast(immutable(char))0xF0,cast(immutable(char))0x80]]) {
        string[] expected;
        foreach(cp;text.byDchar) expected~=cp.to!string;
        auto engine=new ScriptEngine;engine.bind("text",Value.from(text));engine.bind("index",Value.from(0));engine.bind("decodedCount",Value.from(cast(long)expected.length));
        foreach(source;["return count(text);","return text.count;","return text.count();"])
            assert(engine.run(source).toInt()==count(text),source);
        foreach(i,cp;expected){
            engine.run("index="~i.to!string~";");
            foreach(source;["return charAt(text,index);","return text.charAt(index);"])
                assert(engine.run(source).toHostString()==cp,source);
        }
        auto co=engine.run(q{
            auto work=coroutine.create((){
                auto result=[];
                for(auto i=0;i<decodedCount;i+=1){yield;result~=text.charAt(i);}
                return result;
            });
            any result=null;
            while(coroutine.status(work)!="dead"){auto r=coroutine.resume(work);if(!r[0])error(r[1]);result=r[1];}
            return result;
        });
        assert(co.arrayValue.length==expected.length);
        foreach(i,cp;expected)assert(co.arrayValue[i].kind==ValueKind.string_&&co.arrayValue[i].toHostString()==cp);
        foreach(index;[-1L,cast(long)expected.length,long.max]){
            engine.run("index="~index.to!string~";");
            auto result=engine.runSafe("return charAt(text,index);");
            assert(!result.ok&&result.errorMessage.canFind("out of range"));
            auto status=engine.run("return coroutine.resume(coroutine.create((){return text.charAt(index);}));");
            assert(!status.arrayValue[0].truthy()&&status.arrayValue[1].toHostString().canFind("out of range"));
        }
    }
}

unittest {
    auto engine=new ScriptEngine;
    auto source=q{
        string s="あいう";
        int n=count(s);int m=s.count;int k=s.count();
        string first=charAt(s,0);string last=s.charAt(2);
        return n==3&&m==3&&k==3&&first=="あ"&&last=="う"&&s.length==9&&s[0]==227;
    };
    assert(!engine.check(source).length);
    RunOptions options;options.typeCheck=true;auto result=engine.runSafe(source,options);
    assert(result.ok&&result.value.truthy(),result.errorMessage);
    foreach(code;[
        q{count(123);},q{charAt(123,0);},q{charAt("a",0.5);},q{"a".charAt("0");},
        q{count();},q{charAt("a");},q{"a".charAt(0,1);},
        q{string wrong=count("a");},q{int wrong=charAt("a",0);}
    ])assert(engine.check(code).length,code);
    foreach(code;[q{count(123);},q{charAt(123,0);},q{charAt("a",0.5);},q{"a".charAt("0");}]){
        assert(!engine.runSafe(code).ok,code);
        auto co=engine.run("return coroutine.resume(coroutine.create((){"~code~"}));");
        assert(!co.arrayValue[0].truthy(),code);
    }
    foreach(code;[
        q{string count(string s){return "mine";}return count("A")=="mine"&&"A".count=="mine";},
        q{int count=3;auto charAt=(string s,int i){return 42;};return count==3&&charAt("A",0)==42;},
        q{auto custom={count=(){return "own";},charAt=(int i){return i;}};return custom.count()=="own"&&custom.charAt(2)==2;}
    ]){
        auto isolated=new ScriptEngine;assert(!isolated.check(code).length,code);assert(isolated.run(code).truthy(),code);
    }
    auto imported=new ScriptEngine;
    imported.registerModule("custom",q{export string count(int value){return "own";}export int charAt(string s){return 42;}});
    auto code=q{import custom;string own=custom.count(1);int answer=custom.charAt("A");return own=="own"&&answer==42;};
    assert(!imported.check(code).length);assert(imported.run(code).truthy());
}

unittest {
    auto engine=new ScriptEngine;
    engine.load("int count=3;int charAt=7;");
    assert(engine.getGlobal("count").toInt()==3&&engine.getGlobal("charAt").toInt()==7);
    assert(!engine.loadSafe("int count=4;").ok); // Duplicate user definitions remain errors.
    auto native=new ScriptEngine;
    native.bindFunc("count",(string value)=>99);
    assert(native.run("return count(\"A\");").toInt()==99);
    assert((new ScriptEngine).run("return count(\"A\");").toInt()==1);
    auto scripted=new ScriptEngine;
    scripted.load(q{string count(string s){return "own";}});
    assert(scripted.run(q{return "A".count;}).toHostString()=="own");
}

unittest {
    auto engine=new ScriptEngine;
    auto code=q{
        alias Text=(string & !null);
        Text s="あいう";
        int n=count(s);int m=s.count;int b=s[0];int size=s.length;
        string c=charAt(s,0);string d=s.charAt(1);
        return n==3&&m==3&&b==227&&size==9&&c=="あ"&&d=="い";
    };
    assert(engine.check(code).length==0);
    assert(engine.run(code).truthy());
    assert(engine.check(q{(string & !null) s="A";s[0]=2;}).length);
    assert(engine.check(q{(string & !null) s="A";s.length=2;}).length);
}
