module dua.unknown_type_tests;

version (unittest):

import dua;
import std.algorithm : canFind;

private class KnownClass { int value; }
private struct KnownStruct { int value; }
private KnownStruct makeKnownStruct() { return KnownStruct(1); }

private ScriptEngine diagnosticEngine()
{
    auto engine = new ScriptEngine;
    engine.registerModule("types", `export table ItemState { int count; }`);
    engine.bindType!KnownClass("KnownClass");
    engine.bindType!KnownStruct("KnownStruct");
    return engine;
}

unittest
{
    // null と非nullの両方で、互換性ではなく未解決の型名を報告します。
    foreach (checked; [false, true]) foreach (source; [
        `ItemState Table = null;`,
        `ItemState Table = 42;`,
        `ItemState Table = {};`,
        `import types as idata; ItemState Table = null;`,
        `import types as idata; ItemState Table = idata.ItemState{count=1};`,
        `alias Optional = ItemState; Optional Table = null;`,
        `alias Choice = ItemState | int; Choice Table = "wrong";`,
        `ItemState & !null Table = null;`,
        `ItemState[] Table = [null];`,
        `ItemState[string] Table = ["slot": null];`,
        `void consume(ItemState value) {} consume(null);`,
        `void consume(ItemState value) {} consume(1);`,
        `ItemState result() { return null; } result();`,
        `ItemState result() { return 1; } result();`,
        `void consume(ItemState value = null) {} consume();`,
        `auto callback = () { ItemState Table = null; }; callback();`,
        `return cast(ItemState) null;`,
        `return cast(ItemState & !null) null;`,
        `ItemState[] values=[]; values ~= null;`,
        `ItemState[string] values=[:]; values["slot"] = null;`
    ])
    {
        auto engine = diagnosticEngine();
        RunOptions options; options.typeCheck = checked; options.sourceName = "unknown.dua";
        auto result = engine.runSafe(source, options);
        assert(!result.ok, source);
        assert(result.errorMessage.canFind("Unknown type 'ItemState'"), result.errorMessage ~ "\n" ~ source);
        assert(result.diagnostic.line > 0 && result.diagnostic.column > 0, source);
        assert(result.diagnostic.sourceName.canFind("unknown.dua"), result.diagnostic.sourceName);
    }
}

unittest
{
    foreach (checked; [false, true]) foreach (source; [
        `table Table=null; return Table==null;`,
        `table ItemState { int count; } ItemState Table=null; Table=ItemState{count=1}; Table=null; return Table==null;`,
        `import types as idata; alias ItemState=idata.ItemState; ItemState Table=null; return Table==null;`,
        `import types as idata; idata.ItemState Table=null; return Table==null;`,
        `table ItemState { int count; } ItemState echo(ItemState v){return v;} return echo(null)==null;`,
        `ItemState echo(ItemState v){return v;} table ItemState { int count; } return echo(null)==null;`,
        `table ItemState { ItemState next=null; } ItemState Table=ItemState{}; return Table.next==null;`,
        `table First { Second next=null; } table Second { First next=null; } return First{}.next==null;`,
        `alias ItemState=Later; table Later { int count; } ItemState Table=null; return Table==null;`,
        `table ItemState { int count; } alias Choice=ItemState | int; Choice Table=null; return Table==null;`,
        `table ItemState { int count; } alias Required=ItemState & !null; Required Table=ItemState{count=1}; return Table.count==1;`,
        `KnownClass Table=null; KnownClass echo(KnownClass value){return value;} return echo(Table)==null;`,
        `KnownStruct Table=KnownStruct(); return Table.value==0;`,
        `table ItemState { int count; } int count(ItemState value){return 1;} int delegate(ItemState) callback=count; return callback(null)==1;`,
        // unionの途中の不一致を例外化せず、後続候補と従来どおり照合します。
        `alias Choice=ItemState | int; Choice Table=1; return Table==1;`,
        `table ItemState { int count; } alias Choice=ItemState | int; Choice Table=1; return Table==1;`
    ])
    {
        RunOptions options; options.typeCheck = checked;
        auto result = diagnosticEngine().runSafe(source, options);
        assert(result.ok && result.value.truthy(), result.errorMessage ~ "\n" ~ source);
    }
}

unittest
{
    // 解決済みの型は、不正な値でも「型が存在しない」と誤診断しません。
    foreach (checked; [false, true]) foreach (source; [
        `int value=null;`, `table value=1;`,
        `table ItemState { int count; } ItemState value=1;`,
        `struct ItemState { int count; } ItemState value=null;`,
        `table ItemState { int count; } ItemState & !null value=null;`,
        `KnownClass value=1;`, `KnownStruct value=null;`,
        `alias Point=KnownStruct; Point value=null;`,
        `KnownStruct[] values=[null];`
    ])
    {
        RunOptions options; options.typeCheck=checked;
        auto result=diagnosticEngine().runSafe(source,options);
        assert(!result.ok,source);
        assert(!result.errorMessage.canFind("Unknown type"),result.errorMessage ~ "\n" ~ source);
    }
    // 名前付きコンストラクタを公開しないホスト値・関数シグネチャも既知型です。
    foreach (checked; [false, true]) foreach (binding; 0 .. 3)
    {
        auto engine=new ScriptEngine;
        if (binding==0) engine.bind("point",Value.reflect(KnownStruct(1)));
        else if (binding==1) engine.bindFunc!makeKnownStruct("makePoint");
        else engine.bindAuto("point",KnownStruct(1));
        RunOptions options; options.typeCheck=checked;
        auto result=engine.runSafe(`KnownStruct value=null;`,options);
        assert(!result.ok && !result.errorMessage.canFind("Unknown type"),result.errorMessage);
    }
}

unittest
{
    // 実例と同じラムダの実呼出しを行い、宣言行とソース名を確認します。
    auto source = "import types as idata;\nauto callback = () {\n    ItemState eqWeapon = null;\n};\ncallback();";
    foreach (checked; [false,true])
    {
        RunOptions options; options.typeCheck=checked; options.sourceName="ammoUI.dua";
        auto result=diagnosticEngine().runSafe(source,options);
        assert(!result.ok && result.errorMessage.canFind("Unknown type 'ItemState'"),result.errorMessage);
        assert(result.diagnostic.line==3 && result.diagnostic.column==5,result.errorMessage);
        assert(result.diagnostic.sourceName.canFind("ammoUI.dua"),result.diagnostic.sourceName);
    }
    auto diagnostics=diagnosticEngine().check("import types as idata;\nItemState Table=null;","static.dua");
    assert(diagnostics.length && diagnostics[0].message=="Unknown type 'ItemState'");
    assert(diagnostics[0].line==2 && diagnostics[0].column==1);
}
