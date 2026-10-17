module dua.type_effect_tests;

version (unittest):

import dua;
import std.algorithm : canFind;

private class EffectItem { int number; }

private ScriptEngine effectEngine()
{
    auto engine = new ScriptEngine;
    engine.bindAuto("native", cast(EffectItem) null);
    engine.bindAuto("flag", true);
    return engine;
}

private void accepted(string source)
{
    auto diagnostics = effectEngine().check(source);
    assert(diagnostics.length == 0, source ~ (diagnostics.length ? "\n" ~ diagnostics[0].message : ""));
    foreach (checked; [false, true])
    {
        RunOptions options; options.typeCheck = checked;
        auto result = effectEngine().runSafe(source, options);
        assert(result.ok && result.value.truthy(), source ~ "\n" ~ result.errorMessage);
    }
}

private void rejected(string source)
{
    auto diagnostics = effectEngine().check(source);
    assert(diagnostics.length != 0, source);
    foreach (checked; [false, true])
    {
        RunOptions options; options.typeCheck = checked;
        auto result = effectEngine().runSafe(source, options);
        assert(!result.ok, source);
    }
}

unittest
{
    foreach (declaration; ["table EffectItem { int number; }", "struct EffectItem { int number; }"])
    {
        auto install = "void install() { " ~ declaration ~ " } ";
        auto invalid = " EffectItem value = null;";
        foreach (calls; [
            "install();",
            "void middle() { install(); } void outer() { middle(); } outer();",
            "auto f = install; f();",
            "void apply(any f) { f(); } apply(install);",
            "void outer() { void inner() { install(); } inner(); } outer();",
            "auto f = () => { install(); }; f();",
            "auto values = [install()];",
            "auto value = true ? install() : null;",
            "true && install();",
            "false || install();",
            "try { install(); error(\"stop\"); } catch (err) {}"
        ]) rejected(install ~ calls ~ invalid);

        rejected("void recurse(int n) { if (n == 0) { " ~ declaration
            ~ " return; } recurse(n - 1); } recurse(2);" ~ invalid);
        rejected("void first(int n) { if (n == 0) { " ~ declaration
            ~ " return; } second(n - 1); } void second(int n) { first(n); } first(2);" ~ invalid);

        auto valid = " EffectItem value = null; return value == null;";
        foreach (calls; [
            "",
            "void noop() {} auto f = install; f = noop; f();",
            "{ auto install = () => {}; install(); }",
            "void apply(any install) { install(); } apply(() => {});",
            "false && install();",
            "true || install();",
            "auto selected = false ? install() : null;",
            "if (false) install();",
            "while (true) { break; install(); }",
            "for (auto i = 0; i < 1; i += 1) { continue; install(); }",
            "foreach (i; [1, 2]) { continue; install(); }",
            "switch (1) { case 1: break; install(); default: install(); }"
        ]) accepted(install ~ calls ~ valid);

        accepted("void early() { return; " ~ declaration ~ " } early();" ~ valid);
        accepted("void maybe(bool stop) { if (stop) { " ~ declaration
            ~ " return; } EffectItem value = null; } maybe(false); return true;");
        accepted("void recurse(int n) { if (n > 0) { recurse(n - 1); return; } return; "
            ~ declaration ~ " } recurse(2);" ~ valid);
        rejected(install ~ "{ auto install = () => {}; install(); } install();" ~ invalid);
        rejected("while (true) { " ~ declaration ~ " break; }" ~ invalid);
        rejected("for (auto i = 0; i < 1; i += 1) { " ~ declaration ~ " continue; }" ~ invalid);
        rejected("void install() { " ~ declaration ~ " return; } install();" ~ invalid);
        rejected(install ~ "void use(EffectItem value, any ignored) {} use(null, install());");
        accepted("void use(EffectItem value) { " ~ declaration ~ " } use(null); return true;");
        accepted("void install(any ignored) { " ~ declaration ~ " } void noop(any ignored) {} "
            ~ "auto f = install; any swap() { f = noop; return null; } f(swap());" ~ valid);
        rejected("void install(any ignored) { " ~ declaration ~ " } void noop(any ignored) {} "
            ~ "auto f = noop; any swap() { f = install; return null; } f(swap());" ~ invalid);
        auto expose = "any expose() { " ~ declaration ~ " return { x = 0 }; } ";
        rejected(expose ~ "int consume(EffectItem value) { return 1; } expose().x += consume(null);");
        accepted(expose ~ "int consume(EffectItem value) { return 1; } expose().x = consume(null); return true;");
        rejected("any expose() { " ~ declaration ~ " return [0]; } int consume(EffectItem value) { return 1; } expose()[0] += consume(null);");
        rejected("int pattern() { " ~ declaration ~ " return 1; } switch (1) { case pattern(): break; }" ~ invalid);
        rejected("int pattern() { " ~ declaration ~ " return 2; } switch (1) { case pattern(): break; default: break; }" ~ invalid);
        rejected("int pattern() { " ~ declaration ~ " return 2; } switch (1) { case pattern(): break; case 1: EffectItem inner = null; break; }");
        rejected("int pattern() { " ~ declaration ~ " return 1; } switch (1) { case pattern(): EffectItem inner = null; break; }");
        accepted(install ~ "switch (1) { case 1: break; case install(): break; }" ~ valid);
        accepted("try {} catch (err) { " ~ declaration ~ " }" ~ valid);
        accepted("try { 1; } catch (err) { " ~ declaration ~ " }" ~ valid);
        accepted("try { auto number = 1; } catch (err) { " ~ declaration ~ " }" ~ valid);
        accepted("void empty() {} try { empty(); } catch (err) { " ~ declaration ~ " }" ~ valid);
        accepted("try { int number = 1; 1 + 2; } catch (err) { " ~ declaration ~ " }" ~ valid);
        accepted("try { cast(int) 1; null is int; } catch (err) { " ~ declaration ~ " }" ~ valid);
        accepted("void early() { try { return; } catch (err) { " ~ declaration ~ " } } early();" ~ valid);
        rejected("try { error(\"stop\"); } catch (err) { " ~ declaration ~ " }" ~ invalid);
        foreach (operation; [
            "missing;", "auto value = (1).missing;", "auto value = [1][3];",
            "auto value = cast(int) \"bad\";", "auto value = -\"bad\";",
            "auto value = \"bad\" + 1;", "int value = null;",
            "void use(int value) {} use(null);", "int use() { return \"bad\"; } use();",
            "auto value = [...1];", "auto value = { ...1 };",
            "auto value = 1; auto value = 2;", "void use() {} use(1);",
            "foreach (i; 1) {}", "auto moduleValue = 1; auto value = new moduleValue;"
        ])
        {
            auto source = "try { " ~ operation ~ " } catch (err) { " ~ declaration ~ " } EffectItem after = null;";
            auto diagnostics = effectEngine().check(source);
            bool afterDiagnostic;
            foreach (diagnostic; diagnostics) afterDiagnostic |= diagnostic.message.canFind("'after'");
            assert(afterDiagnostic, source);
            rejected(source);
        }
    }
}

unittest
{
    // 関数名の隠蔽・参照を追っても、実際の呼出し先の引数診断を失いません。
    accepted("void original(int value) {} { auto original = (string value) => true; original(\"ok\"); } return true;");
    foreach (source; [
        "int value = \"bad\";",
        "void use(int value) {} use(\"bad\");",
        "void use(int value) {} auto aliasFunction = use; aliasFunction(\"bad\");",
        "void apply(any f) { f(\"bad\"); } void use(int value) {} apply(use);",
        "int use() { return \"bad\"; } use();"
    ]) rejected(source);
    assert(effectEngine().check("void use() { return; int value = \"bad\"; } use();").length != 0);
    // checkはホスト関数を実行しません。
    auto engine = effectEngine();
    bool called;
    engine.bindFunc("host", () { called = true; });
    assert(engine.check("host(); EffectItem value = null;").length == 0);
    assert(!called);
}
