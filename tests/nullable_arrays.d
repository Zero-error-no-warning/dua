module array_nullable_probe;
import dua;
import std.file : readText,write,mkdirRecurse;
import std.json : JSONValue,parseJSON;
import std.path : absolutePath,buildPath;
import std.stdio : writeln;
void main(string[] args)
{
    auto root=absolutePath("fixtures");mkdirRecurse(root);
    write(buildPath(root,"types.dua"),`export alias Values=int[]; export alias Required=Values & !null;
        export Values values=null; export Required required=[];`);
    JSONValue[] results;size_t failures;
    foreach(item;parseJSON(readText(args.length>1?args[1]:"cases.json")).array)
    foreach(checked;[false,true]) {
        auto engine=new ScriptEngine;
        engine.bindFunc("hostArrayNull",(long[] values)=>values.ptr is null);
        engine.bindFunc("hostAaNull",(long[string] values)=>values is null);
        engine.bindFunc("hostFixed",(long[1] values)=>values[0]);
        engine.setModulePaths([buildPath(root,"?.dua")]);
        RunOptions options;options.typeCheck=checked;options.sourceName=buildPath(root,"entry.dua");
        auto result=engine.runSafe(item["source"].str,options);
        auto expected=checked && ("checkedOK" in item.object) !is null?item["checkedOK"].boolean:item["ok"].boolean;
        bool passed=result.ok==expected && (!result.ok || result.value.truthy());
        if(auto message="error" in item.object) {
            import std.algorithm : canFind;
            if(!checked)passed=passed && result.errorMessage.canFind(message.str);
        }
        if(!passed)++failures;
        results~=JSONValue(["id":item["id"],"checked":JSONValue(checked),"passed":JSONValue(passed),
            "actualOK":JSONValue(result.ok),"message":JSONValue(result.errorMessage)]);
        writeln(passed?"PASS ":"FAIL ",item["id"].str," checked=",checked,passed?"":" "~result.errorMessage);
    }
    write("test-results.json",JSONValue(results).toPrettyString());assert(!failures,"Array nullable boundary failures");
}
