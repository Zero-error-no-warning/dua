module dua.array_assignment_tests;

version (unittest):

import dua;
import std.algorithm : canFind;
private class ArrayNode {}
private class OtherNode {}

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
        "auto a = [1, 2]; a[$-1] = 9; return a[1] == 9 && a[$-1] == 9;",
        "int[] a; a ~= 1; a = a ~ 2; a[$-1] += 3; return a.length == 2 && a[0] == 1 && a[1] == 5;",
        "auto a = []; a ~= null; a ~= \"s\"; a ~= { x = 7 }; a ~= () => 8; return a.length == 4 && a[0] == null && a[2].x == 7 && a[3]() == 8;",
        "auto a = [1]; auto b = a ~ 2; b[0] = 9; return a[0] == 1 && b.length == 2 && b[1] == 2;",
        "int[] a = [1, 2]; auto b = a; b[$-1] = 4; return a[1] == 4;",
        "int[] a = [1, 2]; auto b = a[0..$]; b[$-1] = 4; return a[1] == 2 && b[1] == 4;",
        "int[][] a = [[1, 2], [3]]; a[$-1][$-1] = 7; a[0][$-1] += 5; a ~= [[8]]; return a[0][1] == 7 && a[1][0] == 7 && a[2][0] == 8;",
        "int[][] a = [[1]]; int[] row = [2]; a[$-1] = row; row[0] = 3; auto b = a ~ [[4]]; b[0][0] = 5; return a[0][0] == 5 && row[0] == 5;",
        "auto a = [1, 2, 3]; auto indices = [0, 1]; a[indices[$-1] + $ - 3] = 8; return a[1] == 8;",
        "auto a = [1, 2, 3]; int last() { return $-1; } a[last()] = 8; return a[2] == 8;",
        "auto a = []; try { a[$] = 1; } catch (err) {} auto b = [7]; b[$-1] = 8; return b[0] == 8;",
        "auto a = [1, 2]; try { a[error(\"stop\")] = 3; } catch (err) {} a[$-1] = 7; return a[1] == 7;",
        "auto a = [1]; auto b = [2, 3]; auto c = a ~ b; return c.length == 3 && c[0] == 1 && c[2] == 3 && a.length == 1 && b.length == 2;",
        "int[] a = [1]; int[] b = [2, 3]; int[] c = a ~ b; return c.length == 3 && c[2] == 3;",
        "string s = \"v\"; s ~= 1; s = s ~ [2]; return s == \"v1[2]\" && (1 ~ [2]) == \"1[2]\";",
        "byte[] a = [1]; a ~= 2; a[$-1] = 3; return a[1] == 3;",
        "double[] a = [1.0]; a ~= 2.0; return a[1] == 2.0;",
        "struct Point { int x; } Point[] a = []; a ~= Point(4); return a[0].x == 4;"
    ]) succeeds(source);
}

unittest
{
    // Ordinary assignment evaluates RHS before container/index; compound assignment resolves target first.
    succeeds(q{
        auto a = [1, 2]; string trace = "";
        array target() { trace ~= "a"; return a; }
        int index(int n) { trace ~= "i"; return n-1; }
        int rhs() { trace ~= "r"; return 5; }
        target()[index($)] = rhs();
        if (trace != "rai" || a[1] != 5) return false;
        trace = "";
        target()[index($)] += rhs();
        return trace == "air" && a[1] == 10;
    });
    succeeds(q{
        auto a = []; int calls = 0;
        int rhs() { calls += 1; return 3; }
        try { a[$-1] = rhs(); } catch (err) {}
        if (calls != 1) return false;
        calls = 0;
        try { a[$-1] += rhs(); } catch (err) {}
        return calls == 0;
    });
    succeeds(q{
        int[] original = [1, 2]; int[] other = [8]; auto selected = original;
        int rhs() { selected = other; return 5; }
        selected[$-1] = rhs();
        if (other[0] != 5 || original[1] != 2) return false;
        selected = original;
        selected[$-1] += rhs();
        return original[1] == 7 && other[0] == 5;
    });
    succeeds(q{
        auto a = [1]; string trace = "";
        array lhs() { trace ~= "l"; return a; }
        int rhs() { trace ~= "r"; return 2; }
        auto b = lhs() ~ rhs();
        return trace == "lr" && b.length == 2 && b[1] == 2 && a.length == 1;
    });
    succeeds(q{
        auto a = [1];
        int rhs() { a[0] = 7; return 2; }
        auto b = a ~ rhs();
        return b[0] == 7 && b[1] == 2;
    });
    succeeds(q{
        struct Point { int x; }
        auto point = Point(1); auto a = []; a ~= point; point.x = 9;
        auto lengths = 0; auto writes = 0; auto stored = 0; auto proxy = {};
        setmetatable(proxy, {
            __len = (any self) { lengths += 1; return 1; },
            __newindex = (any self, any key, any value) { writes += 1; stored = value; }
        });
        proxy[$-1] = 5;
        return a[0].x == 1 && lengths == 1 && writes == 1 && stored == 5;
    });
}

unittest
{
    foreach (source; [
        "int[] a = [1]; a[$-1] = \"bad\";",
        "int[] a = [1]; auto aliasArray = a; aliasArray[$-1] = \"bad\";",
        "int[] a = [1]; a ~= \"bad\";",
        "int[] a = [1]; a = a ~ 2.0;",
        "double[] a = [1.0]; a ~= 2;",
        "int[] a = [1]; auto b = a[0..$]; b[$-1] = true;",
        "int[] a = [1]; auto b = a ~ 2; b[$-1] = true;",
        "int[] get() { return [1]; } auto a = get(); a[$-1] = true;",
        "string value = [1] ~ 2;"
    ])
    {
        assert((new ScriptEngine).check(source).length != 0, source);
        foreach (checked; [false, true])
        {
            RunOptions options; options.typeCheck = checked;
            assert(!(new ScriptEngine).runSafe(source, options).ok, source);
        }
    }
    foreach (source; [
        "auto a = []; a[$-1] = 1;", "auto a = [1]; a[$] = 1;", "auto a = [1]; a[-1] = 1;",
        "auto a = [1]; a[0] = $;", "auto a = [1]; a[$-1] += $;",
        "auto a = [1]; try { a[error(\"stop\")] = 2; } catch (err) {} return $;",
        "byte[] a = [1]; a ~= 128;", "uint[] a = [1]; a[$-1] = -1;",
        "int[] a = [1]; auto b = a ~ [\"bad\"];"
    ])
    foreach (checked; [false, true])
    {
        RunOptions options; options.typeCheck = checked;
        auto result = (new ScriptEngine).runSafe(source, options);
        assert(!result.ok, source);
    }
    succeeds("byte[] a = [1]; try { a ~= 128; } catch (err) {} try { a[$-1] = 128; } catch (err) {} return a.length == 1 && a[0] == 1;");
}

unittest
{
    foreach (checked; [false,true])
    {
        auto engine = new ScriptEngine;
        engine.bindType!ArrayNode("ArrayNode");
        engine.bindType!OtherNode("OtherNode");
        RunOptions options; options.typeCheck = checked;
        auto source = "ArrayNode[] a = []; a ~= null; a = a ~ ArrayNode(); a[$-1] = null; return a.length == 2 && a[1] == null;";
        assert(engine.check(source).length == 0);
        assert(engine.run(source,options).truthy());
        source = "ArrayNode[] a = []; OtherNode other = OtherNode(); a ~= other;";
        assert(engine.check(source).length != 0);
        assert(!engine.runSafe(source,options).ok);
    }
}
