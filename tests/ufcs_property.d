module ufcs_property_probe;
import dua;
import std.file : readText, write, mkdirRecurse;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildPath;
import std.stdio : writeln;

int nativeCalls;
int selected(int value) { ++nativeCalls; return value * 2; }
int selected(string value) { ++nativeCalls; return cast(int)value.length; }
int needs(int value, int extra) { ++nativeCalls; return value + extra; }
int needs(int value, int a, int b) { ++nativeCalls; return value + a + b; }
int gap() { ++nativeCalls; return 0; }
int gap(int value, int extra) { ++nativeCalls; return value + extra; }
int bonus(int value, int extra = 3) { ++nativeCalls; return value + extra; }
class HostCounter {
    int calls;
    int read() { return ++calls; }
    int read(int extra) { return ++calls + extra; }
    int required(int a, int b) { ++calls; return a + b; }
    int required(int a, int b, int c) { ++calls; return a + b + c; }
}

void main()
{
    auto root=absolutePath("fixtures");mkdirRecurse(root);
    write(buildPath(root,"helpers.dua"),`export int doubled(int value) { return value * 2; }`);
    JSONValue[] results;size_t failures;
    foreach(item;parseJSON(readText("cases.json")).array)
    foreach(checked;[false,true]) {
        nativeCalls=0;
        auto engine=new ScriptEngine;
        engine.bindFunc!selected("selected");engine.bindFunc!needs("needs");
        engine.bindFunc!gap("gap");engine.bindFunc!bonus("bonus");
        engine.bindType!HostCounter("HostCounter");auto host=new HostCounter;
        engine.bindAuto("host",host);
        engine.setModulePaths([buildPath(root,"?.dua")]);
        RunOptions options;options.typeCheck=checked;options.sourceName=buildPath(root,"entry.dua");
        auto result=engine.runSafe(item["source"].str,options);
        bool passed=result.ok==item["ok"].boolean && (!result.ok || result.value.truthy());
        if(auto count="nativeCalls" in item.object) passed=passed && nativeCalls==count.integer;
        if(auto count="hostCalls" in item.object) passed=passed && host.calls==count.integer;
        if(!passed) ++failures;
        results~=JSONValue(["id":item["id"],"checked":JSONValue(checked),"passed":JSONValue(passed),
            "actualOK":JSONValue(result.ok),"message":JSONValue(result.errorMessage),"nativeCalls":JSONValue(nativeCalls)]);
        writeln(passed?"PASS ":"FAIL ",item["id"].str," checked=",checked,passed?"":" "~result.errorMessage);
    }
    write("test-results.json",JSONValue(results).toPrettyString());assert(!failures,"UFCS property boundary failures");
}
