module dua.slot_regression_tests;

version (unittest):

import dua;
import dua.ast;
import dua.evaluator : Environment;
import dua.lexer : lex;
import dua.parser : parse;

unittest
{
    auto engine = new ScriptEngine();
    // The same reference changes its target when a later declaration runs.
    assert(engine.run(q{
        auto value = 10;
        any make(int initial) {
            auto read = () => value;
            auto write = (int next) { value = next; };
            auto before = read();
            write(11);
            auto value = initial;
            auto after = read();
            write(initial + 1);
            return [before, after, read, write];
        }
        auto a = make(20); auto b = make(30);
        a[3](25);
        return a[0] == 10 && a[1] == 20 && a[2]() == 25
            && b[0] == 11 && b[1] == 30 && b[2]() == 31 && value == 11;
    }).truthy());
    assert(engine.run(q{
        auto callbacks = [null, null, null];
        foreach (i, value; [10, 20, 30]) { callbacks[i] = () => value; }
        return callbacks[0]() == 10 && callbacks[1]() == 20 && callbacks[2]() == 30;
    }).truthy());
    assert(engine.run(q{
        int fib(int n) { if (n < 2) { return n; } return fib(n - 1) + fib(n - 2); }
        return fib(10) == 55;
    }).truthy());
}

unittest
{
    auto engine = new ScriptEngine();
    engine.load(q{
        any late() { return later; }
        any typed() {
            int[] values = [1];
            auto set = (any next) { values = next; };
            set([2, 3]);
            try { set(["wrong"]); } catch (err) {}
            return values;
        }
    });
    assert(!engine.runSafe("return late();").ok);
    engine.bind("later", Value.from(42));
    assert(engine.call("late").toInt() == 42);
    assert(engine.call("typed").to!(long[])() == [2, 3]);
    auto first = engine.newModule("slots.first");
    auto second = engine.newModule("slots.second");
    first.load("auto value = 1; export int read() { return value; }");
    second.load("auto value = 2; export int read() { return value; }");
    assert(first.call("read").toInt() == 1 && second.call("read").toInt() == 2);
    first.load("value = 3;");
    assert(first.call("read").toInt() == 3 && second.call("read").toInt() == 2);
}

unittest
{
    auto engine = new ScriptEngine();
    // One AST may be executed with unrelated environments, or changed by its host.
    auto program = parse(lex("{ auto read = () => value; return read(); }"));
    auto first = new Environment(); first.define("value", Value.from(10));
    auto second = new Environment(); second.define("value", Value.from(20));
    assert(engine.executeStatements(program.statements, first).lastValue.toInt() == 10);
    assert(engine.executeStatements(program.statements, second).lastValue.toInt() == 20);
    auto block = parse(lex("{ auto a = 1; auto b = 2; return a; }"));
    assert(engine.executeStatements(block.statements, first).lastValue.toInt() == 1);
    auto reference = cast(VariableExpression) block.statements[0].body[2].expressions[0];
    reference.name = "b";
    assert(engine.executeStatements(block.statements, first).lastValue.toInt() == 2);
    auto replacement = parse(lex("auto added = 7; return added;"));
    block.statements[0].body = replacement.statements;
    assert(engine.executeStatements(block.statements, first).lastValue.toInt() == 7);
}

unittest
{
    auto engine = new ScriptEngine();
    auto results = engine.run(q{
        any make(int start) {
            auto value = start;
            return coroutine.create(() {
                yield value;
                value += 1;
                yield value;
                return value + 1;
            });
        }
        auto a = make(10);
        return [coroutine.resume(a), coroutine.resume(a), coroutine.resume(a)];
    });
    assert(results.arrayValue.length == 3);
    foreach (i, expected; [10, 11, 12])
    {
        auto result = results.arrayValue[i].arrayValue;
        assert(result.length == 2 && result[0].truthy() && result[1].toInt() == expected);
    }
    assert(engine.run(q{
        auto value = 5;
        auto receiver = { value = 42, read = () => this.value };
        auto read = receiver["read"];
        auto first = receiver.read();
        auto failed = false;
        try { read(); } catch (err) { failed = true; }
        return first == 42 && failed;
    }).truthy());
}
