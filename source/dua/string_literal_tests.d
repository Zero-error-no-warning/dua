module dua.string_literal_tests;
version(unittest):
import dua;
import dua.lexer : lex, TokenKind;
import std.string : indexOf;

unittest
{
    auto engine = new Dua.ScriptEngine;
    foreach (checked; [false, true])
    {
        RunOptions options; options.typeCheck = checked;
        foreach (sample; [
            [`return "a\nb\tc\r\0\"\\";`, "a\nb\tc\r\0\"\\"],
            [`return i"a\nb\tc\r\0\"\\";`, "a\nb\tc\r\0\"\\"],
            [`return i" $("test") ";`, " test "],
            [`return i"$("(test)")";`, "(test)"],
            [`return i"$("a\"(b)\\")";`, "a\"(b)\\"],
            [`return i"$(i"nested $("string")")";`, "nested string"],
            [`return i"$$(";`, "$("],
            [`return i"\\$(1 + (2 * 3))";`, "\\7"],
            [`return i"$(1 /+ ) " /+ nested +/ +/ + 2)";`, "3"],
            ["return i\"$(1 // ) \" ignored\n + 2)\";", "3"],
            ["return i\"$(1 # ) \" ignored\n + 2)\";", "3"],
            [`return "C:\\new\\test";`, `C:\new\test`],
            [`return {"a\"b"=42}["a\"b"];`, "42"],
            [`return i"$(1, 2)";`, "12"],
            [`return i "$("spaced prefix")";`, "spaced prefix"],
            [`return i"$(i /+ comment +/ "$("nested")")";`, "nested"],
            [`alias EscapeRegressionText = "a\"b\n"; EscapeRegressionText value = "a\"b\n"; return value;`, "a\"b\n"],
        ])
        {
            engine = new Dua.ScriptEngine;
            auto diagnostics = engine.check(sample[0]);
            assert(diagnostics.length == 0, sample[0] ~ (diagnostics.length ? diagnostics[0].message : ""));
            assert(engine.run(sample[0], options).to!string == sample[1], sample[0]);
        }
    }
    auto ts = lex(`"a\n\"" next`);
    assert(ts[0].lexeme == "a\n\"");
    assert(ts[1].lexeme == "next" && ts[1].column == 9);
    auto multiline = lex("i\"$(1 // comment\n+ 2)\" next");
    assert(multiline[2].lexeme == "next" && multiline[2].line == 2 && multiline[2].column == 7);
}

unittest
{
    auto engine = new Dua.ScriptEngine;
    foreach (source; [
        `return "bad\q";`, `return i"bad\q";`, `return i"$("bad\q")";`,
        `return "trailing\`, `return "unterminated`, `return i"$(1`,
        `return i"$("unterminated`, `return i"$(1 /+ unfinished`,
        "return \"line\nbreak\";", `return i"$(1 2)";`, `return i"$()";`
    ])
    {
        auto result = engine.runSafe(source);
        assert(!result.ok && result.diagnostic.line > 0 && result.diagnostic.column > 0, source);
    }
    foreach (source; [`return "bad\q";`, `return i"bad\q";`, `return i"$("bad\q")";`])
    {
        auto result = engine.runSafe(source);
        assert(result.diagnostic.column == source.indexOf(`\q`) + 1);
    }
    auto source = "return i\"\\n$(1 // comment\n + missing)\";";
    auto result = engine.runSafe(source);
    assert(!result.ok && result.diagnostic.line == 2 && result.diagnostic.column == 4);
    auto afterEscape = `return i"\n$(missing)";`;
    result = engine.runSafe(afterEscape);
    assert(!result.ok && result.diagnostic.column == afterEscape.indexOf("missing") + 1);
}
