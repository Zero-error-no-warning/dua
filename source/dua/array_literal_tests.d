module dua.array_literal_tests;

version (unittest):

import dua;
import dua.parser : parse;
import dua.lexer : lex;
import std.algorithm : canFind;
import std.exception : assertThrown;

private void succeeds(string source)
{
    auto diagnostics = (new ScriptEngine).check(source);
    assert(diagnostics.length == 0, source ~ (diagnostics.length ? "\n" ~ diagnostics[0].message : ""));
    foreach (checked; [false, true])
    {
        RunOptions options; options.typeCheck = checked;
        auto result = (new ScriptEngine).runSafe(source, options);
        assert(result.ok && result.value.truthy(), source ~ "\n" ~ result.errorMessage);
    }
}

unittest
{
    foreach (source; [
        "int[] a = []; return a.length == 0;",
        "int[] a = [1]; return a.length == 1 && a[0] == 1;",
        "int[] a = [1,]; return a.length == 1 && a[0] == 1;",
        "int[] a = [1, 2]; return a.length == 2 && a[0] == 1 && a[1] == 2;",
        "int[] a = [1, 2, /+ end +/]; return a.length == 2 && a[0] == 1 && a[1] == 2;",
        "int[][] a = [[], [1,], [2, 3,],]; return a.length == 3 && a[0].length == 0 && a[1][0] == 1 && a[2][1] == 3;",
        "auto a = [1, ...[2, 3,],]; return a.length == 3 && a[0] == 1 && a[2] == 3;"
    ]) succeeds(source);
}

unittest
{
    enum types = q{
        alias ItemType = "weapon" | "armor";
        table Modifier { string name; ItemType targetType; }
        table ItemInfo { uint id; string itemID; uint count; string name; Modifier[] modifier; }
    };
    // 提示例と末尾カンマなしを、同じ型・内容で検証する。
    foreach (comma; ["", ","])
        succeeds(types ~ q{
            ItemInfo[] inventory = [
                { id = 1, itemID = "knife_001", count = 1, name = "Knife", modifier = [] }
        } ~ comma ~ q{
            ];
            return inventory.length == 1 && inventory[0].id == 1
                && inventory[0].itemID == "knife_001" && inventory[0].count == 1
                && inventory[0].name == "Knife" && inventory[0].modifier.length == 0;
        });
    succeeds(types ~ q{
        ItemInfo[] inventory = [
            { id = 1, itemID = "knife_001", count = 1, name = "Knife", modifier = [] },
            { id = 2, itemID = "armor_001", count = 2, name = "Armor",
              modifier = [{ name = "strong", targetType = "armor" },] },
        ];
        return inventory.length == 2 && inventory[0].modifier.length == 0
            && inventory[1].modifier.length == 1 && inventory[1].modifier[0].name == "strong"
            && inventory[1].modifier[0].targetType == "armor";
    });
}

unittest
{
    foreach (literal; ["[,]", "[1,,]", "[1,,2]", "[1,2,,]", "[[1,,],]"])
    {
        auto source = "auto a = " ~ literal ~ ";";
        assertThrown!Exception(parse(lex(source)));
        auto diagnostics = (new ScriptEngine).check(source);
        assert(diagnostics.length != 0 && diagnostics[0].message.canFind("Unexpected token comma"), source);
        foreach (checked; [false, true])
        {
            RunOptions options; options.typeCheck = checked;
            auto result = (new ScriptEngine).runSafe(source, options);
            assert(!result.ok && result.errorMessage.canFind("Unexpected token comma"), source);
        }
    }
}
