module dua.input_diagnostics_tests;

version(unittest):
import dua;
import dua.lexer : lex, TokenKind;

unittest
{
    enum bom = "\xEF\xBB\xBF";
    auto tokens = lex(bom ~ "return 42;");
    assert(tokens[0].kind == TokenKind.keywordReturn);
    assert(tokens[0].line == 1 && tokens[0].column == 4);
    assert(lex(bom)[0].kind == TokenKind.eof);
    auto engine = new ScriptEngine;
    assert(engine.run(bom ~ "return 42;").toInt() == 42);
    assert(engine.check(bom ~ "return 42;").length == 0);
    auto error = engine.runSafe(bom ~ "\nreturn missing;");
    assert(!error.ok && error.diagnostic.line == 2 && error.diagnostic.column == 8);
    auto firstLine = engine.runSafe(bom ~ "return missing;");
    assert(!firstLine.ok && firstLine.diagnostic.line == 1 && firstLine.diagnostic.column == 11);
    assert(!engine.runSafe("return " ~ bom ~ "42;").ok);

    import std.file : tempDir, write, remove;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    auto path = buildPath(tempDir, "dua-bom-" ~ randomUUID().toString ~ ".dua");
    write(path, bom ~ "return 42;");
    scope(exit) remove(path);
    assert(engine.runFile(path).toInt() == 42);
}

unittest
{
    foreach (checked; [false, true])
    {
        auto engine = new ScriptEngine;
        RunOptions options;
        options.typeCheck = checked;
        options.sourceName = "numbers.dua";
        auto source = "\nreturn 9223372036854775808;";
        auto outcome = engine.runSafe(source, options);
        assert(!outcome.ok);
        assert(outcome.diagnostic.line == 2 && outcome.diagnostic.column == 8, outcome.errorMessage);
        assert(outcome.diagnostic.sourceName == options.sourceName);
        assert(outcome.diagnostic.sourceText == source);
        auto diagnostics = engine.check(source);
        assert(diagnostics.length == 1);
        assert(diagnostics[0].line == 2 && diagnostics[0].column == 8);
        assert(engine.run("return 9223372036854775807;", options).toInt() == long.max);
    }
}
