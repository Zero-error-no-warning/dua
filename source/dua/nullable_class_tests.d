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
    foreach (declaration; ["table NativeItem { int number; }", "struct NativeItem { int number; }"])
    {
        // nullの公開だけでもクラス名を登録できます。structの生成名とは衝突させません。
        auto createEngine = () {
            auto engine = new ScriptEngine;
            engine.bindAuto("native", cast(NativeItem) null);
            return engine;
        };
        auto source = declaration ~ " NativeItem value = null;";
        auto engine = createEngine();
        assert(engine.check("NativeItem value = null;").length == 0);
        assert(engine.check(source).length != 0, source);
        // checkだけではエンジンに型を登録しません。
        assert(engine.check("NativeItem value = null;").length == 0);
        foreach (checked; [false, true])
        {
            RunOptions options;
            options.typeCheck = checked;
            auto result = createEngine().runSafe(source, options);
            assert(!result.ok, source);
        }
        source = "NativeItem before = null; " ~ declaration ~ " return before == null;";
        RunOptions options;
        options.typeCheck = true;
        auto beforeResult = createEngine().runSafe(source, options);
        assert(beforeResult.ok && beforeResult.value.truthy(), beforeResult.errorMessage);
        engine.run(declaration);
        assert(engine.check("NativeItem value = null;").length != 0);
        assert(!engine.runSafe("NativeItem value = null;").ok);
        assert(!engine.runSafe("NativeItem value = null;", options).ok);
        source = "NativeItem before = null; { " ~ declaration ~ " } NativeItem after = null;";
        auto blockDiagnostics = createEngine().check(source);
        assert(blockDiagnostics.length == 1 && blockDiagnostics[0].message.canFind("'after'"), source);
        auto unusedFunction = createEngine().runSafe(
            "void later() { " ~ declaration ~ " } NativeItem value = null; return value == null;", options);
        assert(unusedFunction.ok && unusedFunction.value.truthy(), unusedFunction.errorMessage);
        foreach (prefix; ["if (false)", "while (false)", "for (auto i = 0; i < 0; i += 1)",
            "foreach (i; [])", "foreach (i; 0 .. 0)"])
        {
            auto skipped = createEngine().runSafe(prefix ~ " { " ~ declaration
                ~ " } NativeItem value = null; return value == null;", options);
            assert(skipped.ok && skipped.value.truthy(), skipped.errorMessage);
        }
        foreach (flow; [
            "try { " ~ declaration ~ " } catch (err) {}",
            "try { " ~ declaration ~ " error(\"stop\"); } catch (err) {}",
            "if (true) { " ~ declaration ~ " }",
            "if (false) {} else { " ~ declaration ~ " }",
            "while (true) { " ~ declaration ~ " break; }",
            "for (; true;) { " ~ declaration ~ " break; }",
            "foreach (i; [1]) { " ~ declaration ~ " break; }",
            "switch (1) { case 1: " ~ declaration ~ " break; }"
        ])
        {
            auto rejectedSource = flow ~ " NativeItem value = null;";
            assert(createEngine().check(rejectedSource).length != 0, rejectedSource);
            foreach (checked; [false, true])
            {
                RunOptions flowOptions;
                flowOptions.typeCheck = checked;
                auto rejected = createEngine().runSafe(rejectedSource, flowOptions);
                assert(!rejected.ok, rejectedSource);
            }
        }
        auto skippedCase = createEngine().runSafe("switch (1) { case 2: " ~ declaration
            ~ " break; default: break; } NativeItem value = null; return value == null;", options);
        assert(skippedCase.ok && skippedCase.value.truthy(), skippedCase.errorMessage);
    }
    // bindTypeの公開名と同名tableの組合せも、宣言した実行の内外で拒否します。
    foreach (priorRun; [false, true])
    {
        auto engine = itemEngine();
        string source = "NativeItem value = null;";
        if (priorRun) engine.run("table NativeItem { int number; }");
        else source = "table NativeItem { int number; } " ~ source;
        assert(engine.check(source).length != 0);
    }
    // 既存のnullable aliasまで失わないよう、現在の実行時定義で判定します。
    auto engine = itemEngine();
    engine.run("alias NativeItem = OtherItem | null;");
    assert(engine.check("NativeItem value = null;").length == 0);
    RunOptions options;
    options.typeCheck = true;
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
