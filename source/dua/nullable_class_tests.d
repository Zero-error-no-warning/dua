module dua.nullable_class_tests;

version (unittest):

import dua;
import std.algorithm : canFind;

private class NativeItem { int number = 7; }
private class DerivedItem : NativeItem { }
private class OtherItem { int number = 7; }
private struct NativePoint { int number = 7; }
private class ItemHolder
{
    NativeItem field;
    private NativeItem stored;
    NativeItem property() { return stored; }
    void property(NativeItem value) { stored = value; }
    NativeItem echo(NativeItem value) { return value; }
}
private struct ItemBox { NativeItem field; }

private NativeItem echoItem(NativeItem value) { return value; }
private NativeItem missingItem() { return null; }
private NativeItem makeItem() { return new DerivedItem; }

private ScriptEngine itemEngine()
{
    auto engine = new ScriptEngine;
    engine.bindType!NativeItem("NativeItem");
    engine.bindType!DerivedItem("DerivedItem");
    engine.bindType!OtherItem("OtherItem");
    engine.bindType!NativePoint("NativePoint");
    engine.bindAuto("holder", new ItemHolder);
    engine.bindAuto("box", ItemBox.init);
    engine.bindFunc!echoItem("echoItem");
    engine.bindFunc!missingItem("missingItem");
    engine.bindFunc!makeItem("makeItem");
    return engine;
}

unittest
{
    foreach (checked; [false, true])
    {
        RunOptions options;
        options.typeCheck = checked;
        foreach (source; [
            q{
                NativeItem value = null;
                if (value != null || echoItem(value) != null) return false;
                value = NativeItem();
                if (value.number != 7) return false;
                value = null;
                return value == null && echoItem(value) == null;
            },
            q{
                NativeItem value = missingItem();
                value = makeItem();
                if (value.number != 7) return false;
                value = missingItem();
                return value == null;
            },
            q{
                NativeItem value = null;
                holder.field = value;
                holder.property = value;
                box.field = value;
                if (holder.field != null || holder.property != null || box.field != null) return false;
                value = makeItem();
                holder.field = value;
                holder.property = holder.echo(value);
                box.field = echoItem(value);
                if (holder.field != value || holder.property != value || box.field != value) return false;
                value = holder.property;
                if (echoItem(value) != value || value.number != 7) return false;
                holder.field = null;
                holder.property = null;
                box.field = null;
                value = holder.field;
                return value == null && holder.property == null && box.field == null;
            },
            q{
                auto value = null;
                NativeItem other = NativeItem();
                value = other;
                holder.field = value;
                holder.property = value;
                if (echoItem(value) != other || holder.field != other || holder.property != other) return false;
                value = null;
                holder.field = value;
                holder.property = value;
                return echoItem(value) == null && holder.field == null && holder.property == null;
            },
            q{
                NativeItem echo(NativeItem value) { return value; }
                NativeItem missing() { return null; }
                NativeItem value = echo(null);
                value = echo(makeItem());
                value = missing();
                return value == null;
            },
            q{
                alias ItemAlias = NativeItem;
                alias OptionalItem = NativeItem | null;
                ItemAlias value = null;
                OptionalItem optional = null;
                return value == null && optional == null
                    && cast(NativeItem) null == null && cast!(NativeItem) null == null
                    && !(null is NativeItem) && null is OptionalItem;
            },
            q{
                NativeItem[] values = [null, NativeItem(), null];
                NativeItem[string] byName = ["empty": null];
                byName["live"] = makeItem();
                byName["live"] = null;
                return values[0] == null && values[1].number == 7
                    && values[2] == null && byName["live"] == null;
            }
        ])
        {
            auto result = itemEngine().runSafe(source, options);
            assert(result.ok, result.errorMessage ~ "\n" ~ source);
            assert(result.value.truthy(), source);
        }
    }
}

unittest
{
    // bindTypeなしの公開でも、null値と関数シグネチャから参照型を登録します。
    foreach (checked; [false, true]) foreach (binding; 0 .. 5)
    {
        auto engine = new ScriptEngine;
        final switch (binding)
        {
            case 0: engine.bindAuto("empty", cast(NativeItem) null); break;
            case 1: engine.bind("item", Value.reflect(new NativeItem)); break;
            case 2: engine.bindFunc!missingItem("missing"); break;
            case 3: engine.bindFunc("echo", (NativeItem value) => value); break;
            case 4: engine.newModule("host").bindAuto("empty", cast(NativeItem) null); break;
        }
        RunOptions options;
        options.typeCheck = checked;
        auto result = engine.runSafe("NativeItem value = null; Object base = null; return value == base;", options);
        assert(result.ok && result.value.truthy(), result.errorMessage);
    }
    auto aliasEngine = new ScriptEngine;
    aliasEngine.bindType!NativeItem("Item");
    assert(aliasEngine.check("Item value = null;").length == 0);
    assert(aliasEngine.run("Item value = null; return value == null;").truthy());
}

unittest
{
    foreach (checked; [false, true]) foreach (source; [
        "int value = null;", "bool value = null;", "string value = null;",
        "double value = null;", "NativePoint value = null;", "Unknown value = null;",
        "table Record { int number; } Record value = null;",
        "struct Record { int number; } Record value = null;",
        "alias PointAlias = NativePoint; PointAlias value = null;",
        "alias NativeItem = int; NativeItem value = null;",
        "NativePoint[] values = [null];",
        "NativeItem value = OtherItem();",
        "holder.field = OtherItem();", "holder.property = OtherItem();",
        // 型の公開テーブルをDのクラス実体として受け入れてはいけません。
        "auto value = null; value = NativeItem; holder.field = value;"
    ])
    {
        RunOptions options;
        options.typeCheck = checked;
        auto result = itemEngine().runSafe(source, options);
        assert(!result.ok, source);
    }
    // ホスト型の登録は別エンジンや同名の値型に漏らしません。
    auto first = itemEngine();
    auto second = new ScriptEngine;
    second.bindType!NativePoint("NativeItem");
    assert(second.check("NativeItem value = null;").length != 0);
    assert(!second.runSafe("NativeItem value = null;").ok);
    auto invalid = first.runSafe("auto value = null; value = NativeItem; holder.field = value;");
    assert(invalid.errorMessage.canFind("Cannot convert Value to 'NativeItem'"), invalid.errorMessage);
}

unittest
{
    auto engine = itemEngine();
    engine.registerModule("nullableState", q{
        instance NativeItem value = null;
        export NativeItem get() { return value; }
        export void set(NativeItem next) { value = next; }
    });
    auto first = engine.instantiateModule("nullableState");
    auto second = engine.instantiateModule("nullableState");
    assert(first.call("get").kind == ValueKind.null_);
    auto item = new NativeItem;
    first.call("set", [Value.reflect(item)]);
    assert(first.call("get").to!NativeItem() is item);
    assert(second.call("get").kind == ValueKind.null_);
    first.call("set", [Value.nullValue()]);
    assert(first.call("get").kind == ValueKind.null_);
}

unittest
{
    foreach (name; ["byte", "ubyte", "short", "ushort", "int", "uint", "long", "ulong",
        "float", "double", "real", "bool", "string", "array", "table", "associativeArray",
        "function", "int[]", "int[string]", "int delegate(int)"])
    {
        auto engine = new ScriptEngine;
        try { engine.bindType!NativeItem(name); }
        catch (Exception error)
        {
            // string/tableなどの既存namespaceとの衝突が登録途中で失敗しても規則を保ちます。
            assert(error.msg.canFind("already defined"), error.msg);
        }
        auto source = name ~ " value = null;";
        assert(engine.check(source).length != 0, source);
        foreach (checked; [false, true])
        {
            RunOptions options;
            options.typeCheck = checked;
            auto result = engine.runSafe(source, options);
            assert(!result.ok, source);
        }
        assert(engine.run("NativeItem value = null; return value == null;").truthy());
    }
    foreach (name; ["null", "void", "any"])
    {
        auto engine = new ScriptEngine;
        engine.bindType!NativeItem(name);
        assert(engine.run("return null is " ~ name ~ ";").truthy(), name);
        if (name != "null")
            assert(itemEngine().run("alias " ~ name ~ " = NativeItem; return null is " ~ name ~ ";").truthy(), name);
    }
    auto engine = itemEngine();
    auto source = "alias int = NativeItem; int value = null;";
    assert(engine.check(source).length != 0);
    assert(!engine.runSafe(source).ok);
}

unittest
{
    auto createEngine = () {
        auto engine = new ScriptEngine;
        engine.bindAuto("native", cast(NativeItem) null);
        return engine;
    };
    // checkは検査開始時の型状態を見る。同一ソースで解決が変わる名前は実行時へ委ねる。
    foreach (declaration; ["table NativeItem { int number; }", "struct NativeItem { int number; }"])
    {
        auto source = declaration ~ " NativeItem value = null;";
        auto engine = createEngine();
        assert(engine.check(source).length == 0, source);
        assert(engine.check("NativeItem value = null;").length == 0); // checkは登録しない。
        engine.run(declaration);
        assert(engine.check("NativeItem value = null;").length != 0); // 既存のtable/structは確定。
        foreach (checked; [false, true])
        {
            RunOptions options; options.typeCheck = checked;
            assert(!createEngine().runSafe(source, options).ok);
            assert(!engine.runSafe("NativeItem value = null;", options).ok);
        }
    }
    foreach (source; [
        "void define() { table NativeItem { int number; } } define(); NativeItem value = null;",
        "void install() { table NativeItem { int number; } } any getter() { return install; } getter()(); NativeItem value = null;",
        "try { table NativeItem { int number; } } catch (err) {} NativeItem value = null;",
        "int pattern() { table NativeItem { int number; } return 1; } switch (1) { case pattern(): break; } NativeItem value = null;",
        "any expose() { table NativeItem { int number; } return { x = 0 }; } int consume(NativeItem value) { return 1; } expose().x += consume(null);"
    ])
    {
        assert(createEngine().check(source).length == 0, source);
        foreach (checked; [false, true])
        {
            RunOptions options; options.typeCheck = checked;
            assert(!createEngine().runSafe(source, options).ok, source);
        }
    }
    foreach (source; [
        "void unused() { table NativeItem { int number; } } NativeItem value = null; return value == null;",
        "while (true) { break; table NativeItem { int number; } } NativeItem value = null; return value == null;",
        "for (auto i = 0; i < 1; i += 1) { continue; table NativeItem { int number; } } NativeItem value = null; return value == null;",
        "void early() { return; table NativeItem { int number; } } early(); NativeItem value = null; return value == null;",
        "try {} catch (err) { table NativeItem { int number; } } NativeItem value = null; return value == null;",
        "void install(int x) { table NativeItem { int number; } } try { install(); } catch (err) {} NativeItem value = null; return value == null;",
        "NativeItem value = null; alias NativeItem = int; return value == null;",
        "alias NativeItem = string; NativeItem value = \"text\"; return value == \"text\";",
        "any expose() { table NativeItem { int number; } return { x = 0 }; } int consume(NativeItem value) { return 1; } expose().x = consume(null); return true;"
    ])
    {
        assert(createEngine().check(source).length == 0, source);
        foreach (checked; [false, true])
        {
            RunOptions options; options.typeCheck = checked;
            auto result = createEngine().runSafe(source, options);
            assert(result.ok && result.value.truthy(), source ~ "\n" ~ result.errorMessage);
        }
    }
    // structは型情報登録後のconstructor名衝突でも、実行時に残る型情報を尊重する。
    auto partial = "void use() { try { struct NativeItem { int number; } return; } catch (err) {} NativeItem value = null; } use();";
    assert(itemEngine().check(partial).length == 0);
    foreach (checked; [false, true])
    {
        RunOptions options; options.typeCheck = checked;
        assert(!itemEngine().runSafe(partial, options).ok);
    }
    // 委譲は影響する公開型名だけ。組込み型・別クラス等の既存診断を緩めない。
    foreach (source; ["int value = \"bad\";", "OtherItem value = 1;",
        "int use(int x) { return x; } use(\"bad\");", "int use() { return \"bad\"; }"])
        assert(itemEngine().check("void unused() { table NativeItem { int n; } } " ~ source).length != 0, source);
    auto engine = itemEngine();
    engine.run("alias NativeItem = OtherItem | null;");
    assert(engine.check("NativeItem value = null;").length == 0);
    RunOptions options; options.typeCheck = true;
    assert(engine.run("NativeItem value = null; return value == null;", options).truthy());
}

unittest
{
    // globalやホストのbindで内部名が通常値になってもcheckをErrorで終了させません。
    foreach (invalid; [Value.from(7), Value.nullValue(), Value.from("ordinary"),
        Value.from(cast(Value[string]) null), Value.reflect(new NativeItem),
        Value.from(["isTable": Value.from(false)]),
        Value.from(["isTable": Value.from("false"), "alternatives": Value.from([Value.from("null")])]),
        Value.from(["isTable": Value.from(false), "alternatives": Value.from(7)]),
        Value.from(["isTable": Value.from(false), "alternatives": Value.from([Value.from("null"), Value.from(7)])]),
        Value.from(["isTable": Value.from(true)]),
        Value.from(["isTable": Value.from(true), "fields": Value.from(7), "chain": Value.from([Value.from("NativeItem")])])])
    {
        auto engine = itemEngine();
        engine.bind("__dua_type_NativeItem", invalid);
        assert(engine.check("").length != 0);
        auto diagnostics = engine.check("NativeItem value = null;");
        assert(diagnostics.length != 0 && diagnostics[0].message.canFind("Invalid type"));
        assert(!engine.runSafe("NativeItem value = null;").ok);
        RunOptions options;
        options.typeCheck = true;
        assert(!engine.runSafe("NativeItem value = null;", options).ok);
    }
    auto engine = itemEngine();
    assert(engine.loadSafe("auto __dua_type_NativeItem = 7;").ok);
    assert(engine.check("NativeItem value = null;").length != 0);
    assert(!engine.runSafe("NativeItem value = null;").ok);
}
