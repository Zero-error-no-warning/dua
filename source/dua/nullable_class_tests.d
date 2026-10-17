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
