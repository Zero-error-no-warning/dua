module named_tables;
import dua;
import std.file : readText, write, mkdirRecurse;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildPath;
import std.stdio : writeln;

void main(string[] args)
{
    auto root=absolutePath("fixtures"); mkdirRecurse(root);
    write(buildPath(root,"a.dua"),`export table Hoge{int x;} export alias Alias=Hoge;
        table Private{int x;} export alias Public=Private; export auto value=Hoge{x=7};`);
    write(buildPath(root,"b.dua"),`export table Hoge{int x;}`);
    JSONValue[] results;
    size_t failed;
    foreach (item; parseJSON(readText(args.length > 1 ? args[1] : "cases.json")).array)
    foreach (checked; [false,true])
    {
        auto engine=new ScriptEngine;
        engine.setModulePaths([buildPath(root,"?.dua"),buildPath(root,"?","init.dua")]);
        RunOptions options; options.typeCheck=checked; options.sourceName=buildPath(root,"entry.dua");
        auto outcome=engine.runSafe(item["source"].str,options);
        bool passed=outcome.ok==item["ok"].boolean;
        if (passed && outcome.ok)
            passed=("expectedString" in item.object) !is null
                ? outcome.value.toHostString()==item["expectedString"].str : outcome.value.truthy();
        if (!passed) ++failed;
        results~=JSONValue(["id":item["id"],"checked":JSONValue(checked),"passed":JSONValue(passed),
            "actualOK":JSONValue(outcome.ok),"message":JSONValue(outcome.errorMessage)]);
        writeln(passed ? "PASS " : "FAIL ",item["id"].str," checked=",checked,
            passed ? "" : " "~outcome.errorMessage);
    }
    write("test-results.json",JSONValue(results).toPrettyString());
    assert(failed==0,"Named table boundary failures");
}
