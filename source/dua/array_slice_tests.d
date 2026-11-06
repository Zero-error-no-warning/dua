module dua.array_slice_tests;

version (unittest):

import dua;
import std.format : format;

private void succeeds(string source)
{
    foreach (checked; [false, true]) foreach (coroutine; [false, true])
    {
        auto engine = new ScriptEngine;
        RunOptions options;
        options.typeCheck = checked;
        auto script = coroutine
            ? "auto co=coroutine.create((){" ~ source ~ "});auto last=null;"
                ~ "while(coroutine.status(co)!=\"dead\"){auto r=coroutine.resume(co);if(!r[0])error(r[1]);last=r[1];}return last;"
            : source;
        auto result = engine.runSafe(script, options);
        assert(result.ok, format("checked=%s coroutine=%s: %s\n%s", checked, coroutine, result, source));
        assert(result.value.truthy(), format("checked=%s coroutine=%s\n%s", checked, coroutine, source));
    }
}

private struct CopyProbe
{
    static size_t copies;
    int value;
    this(this) { ++copies; }
}

unittest
{
    // スライスを作るだけでは、反映されたD structのpostblitも呼びません。
    foreach (checked; [false, true]) foreach (coroutine; [false, true])
    {
        auto engine = new ScriptEngine;
        auto original = Value.fromAuto([CopyProbe(1), CopyProbe(2), CopyProbe(3)]);
        engine.bind("items", original);
        CopyProbe.copies = 0;
        RunOptions options;
        options.typeCheck = checked;
        auto source = coroutine
            ? "auto co=coroutine.create((){yield 0;return items[1..$];});coroutine.resume(co);return coroutine.resume(co)[1];"
            : "return items[1..$];";
        auto result = engine.run(source, options);
        assert(CopyProbe.copies == 0);
        assert(result.arrayValue.ptr is original.arrayValue.ptr + 1 && result.arrayValue.length == 2);
        auto empty = engine.run("return items[1..1];", options);
        assert(empty.arrayValue.ptr is original.arrayValue.ptr + 1 && empty.arrayValue.length == 0);
        assert(!empty.isNullContainer && CopyProbe.copies == 0);
    }
}

unittest
{
    succeeds(q{
        int[] original = [10, 20, 30, 40];
        auto middle = original[1..$-1];
        auto nested = middle[1..$];
        middle[0] = 21;
        original[2] = 31;
        if (middle != [21, 31] || nested != [31]) return false;
        nested[0] += 1;
        int[] identity(int[] values) { return values; }
        auto returned = identity(middle);
        returned[0] = 22;
        return original == [10, 22, 32, 40] && middle.length == 2;
    });
    succeeds(q{
        struct Item { int value; }
        auto original = [Item(1), Item(2), Item(3)];
        auto section = original[1..3];
        section[0].value = 20;
        original[2] = Item(30);
        if (original[1].value != 20 || section[1].value != 30) return false;
        auto copy = [...section];
        copy[0].value = 99;
        section[0] = Item(21);
        return original[1].value == 21 && copy[0].value == 99;
    });
    succeeds(q{
        auto rows = [[1], [2], [3]];
        auto section = rows[1..$];
        section[0] = [20];
        rows[2] = [30];
        return rows == [[1], [20], [30]] && section == [[20], [30]];
    });
    succeeds(q{
        int[] original = [1, 2, 3, 4];
        auto section = original[1..3];
        section.length = 1;
        section[0] = 20;
        if (original != [1, 20, 3, 4]) return false;
        section.length = 2;
        section[0] = 99;
        if (original != [1, 20, 3, 4] || section != [99, 0]) return false;
        auto tail = original[2..$];
        original.length = 1;
        tail[0] = 30;
        return original == [1] && tail == [30, 4];
    });
    succeeds(q{
        int[] absent = null;
        auto nullSlice = absent[0..0];
        int[] values = [1, 2];
        auto empty = values[$..$];
        auto literalEmpty = [][0..0];
        empty.length = 1;
        empty[0] = 9;
        return nullSlice is null && nullSlice.length == 0
            && literalEmpty.length == 0 && values == [1, 2] && empty == [9];
    });
}

unittest
{
    succeeds(q{
        int[] values = [1, 2, 3];
        auto section = values[1..$];
        any invalid = "bad";
        try { section[0] = invalid; return false; } catch (e) {}
        try { auto bad = values[-1..1]; return false; } catch (e) {}
        try { auto bad = values[2..1]; return false; } catch (e) {}
        try { auto bad = values[0..4]; return false; } catch (e) {}
        return values == [1, 2, 3] && section[$-1] == 3;
    });
    succeeds(q{
        alias Word = "yes" | "no";
        alias Choice = int[] | Word[];
        Choice values = [1, 2, 3];
        auto section = values[1..$];
        auto nested = section[0..1];
        try { nested[0] = "yes"; return false; } catch (e) {}
        section[0] = 20;
        values[2] = 30;
        if (section != [20, 30] || values != [1, 20, 30]) return false;
        section.length = 1;
        try { section[0] = "yes"; return false; } catch (e) {}
        return values == [1, 20, 30];
    });
    succeeds(q{
        alias Word = "yes" | "no";
        alias Choice = int[][] | Word[][];
        Choice rows = [[1], [2]];
        auto section = rows[1..$];
        try { section[0] = ["yes"]; return false; } catch (e) {}
        section[0] = [20];
        auto inner = section[0];
        try { inner[0] = "yes"; return false; } catch (e) {}
        rows[1][0] = 21;
        return section == [[21]] && rows == [[1], [21]];
    });
}

unittest
{
    succeeds(q{
        int[] values = [10, 20, 30];
        string trace = "";
        int[] target() { trace ~= "t"; yield "target"; return values; }
        int lower() { trace ~= "l"; yield "lower"; return 1; }
        int upper(int length) { trace ~= "u"; yield "upper"; return length; }
        auto co = coroutine.create(() {
            auto section = target()[lower()..upper($)];
            section[0] = 21;
            yield section;
            return section[1];
        });
        auto seen = [];
        foreach (i; 0..3) {
            auto r = coroutine.resume(co);
            if (!r[0]) error(r[1]);
            seen ~= r[1];
        }
        auto yielded = coroutine.resume(co);
        if (!yielded[0] || values != [10, 21, 30]) return false;
        values[2] = 31;
        auto done = coroutine.resume(co);
        return seen == ["target", "lower", "upper"] && trace == "tlu"
            && yielded[1] == [21, 31] && done[0] && done[1] == 31;
    });
}
