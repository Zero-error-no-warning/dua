module dua.numeric_type_tests;

version (unittest):

import dua;
import std.algorithm : canFind;

unittest
{
    foreach (type; ["byte", "ubyte", "short", "ushort", "int", "uint", "long", "ulong", "float", "double", "real"])
    {
        auto engine = new ScriptEngine;
        auto literal = ["float", "double", "real"].canFind(type) ? "1.0" : "1";
        auto source = "export " ~ type ~ " echo(" ~ type ~ " value) { return value; } "
            ~ type ~ " original = " ~ literal ~ "; " ~ type ~ " copy = original; "
            ~ "copy = echo(original); return copy;";
        assert(engine.check(source).length == 0, source);
        RunOptions options; options.typeCheck = true;
        assert(engine.runSafe(source, options).ok, source);

        // Imported annotations and aliases keep their type identity as well.
        auto imported = new ScriptEngine;
        imported.registerModule("numbers", "export alias Count = " ~ type ~ "; "
            ~ "export Count echo(Count value) { return value; } export Count count = " ~ literal ~ ";");
        auto consumer = "import numbers as n; n.Count result(n.Count value) { return n.echo(value); } "
            ~ "n.Count local = result(n.count); return local;";
        assert(imported.check(consumer).length == 0, type);
        assert(imported.runSafe(consumer, options).ok, type);

        // The identity correction must not disable real incompatibilities.
        foreach (value; ["\"bad\"", "true", "null"])
        {
            auto bad = type ~ " bad() { return " ~ value ~ "; }";
            auto diagnostics = (new ScriptEngine).check(bad);
            assert(diagnostics.length && diagnostics[0].message.canFind("Return expects " ~ type), bad);
        }
    }
}

unittest
{
    auto engine = new ScriptEngine;
    // Runtime range checks remain in force even where the static checker accepts an int literal.
    foreach (source; ["uint value = -1;", "ubyte value = 256;", "byte value = 128;"])
    {
        assert(engine.check(source).length == 0, source);
        assert(!engine.runSafe(source).ok, source);
    }
    engine.registerModule("badNumbers", `export uint bad() { return "wrong"; }`);
    auto diagnostics = engine.check("import badNumbers;", "consumer.dua");
    assert(diagnostics.length && diagnostics[0].message.canFind("Return expects uint"));
}
