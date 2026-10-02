module dua.module_instance_tests;

version(unittest):
import dua.runtime;
import dua.value;
import std.algorithm : canFind;
import std.exception : assertThrown;

private ScriptEngine actorEngine()
{
    auto engine = new ScriptEngine();
    engine.registerModule("actors.player", q{
        export int totalDamage = 0;
        instance export int hp = 100;
        export void damage(int amount) { hp -= amount; totalDamage += amount; }
        export int health() { return hp; }
        export int total() { return totalDamage; }
        export any closure() { return () => hp; }
        export any invoke(any f) { return f(); }
    });
    return engine;
}

unittest
{
    auto engine = new ScriptEngine();
    engine.registerModule("privateState", "instance auto data = { count = 1 };");
    auto state = engine.loadModule("privateState");
    assert(state.exportsValue().tableValue.length == 0);
    auto fresh = state.instantiate();
    assert(fresh.exportsValue().tableValue.length == 0);
    assert(fresh.run("return data.count;").toInt() == 1);
    state.run("data.count = 7;");
    assert(fresh.run("return data.count;").toInt() == 1);

    engine.registerModule("typedState", q{
        struct InstanceVector { int x; int y; }
        instance {
            InstanceVector velocity = InstanceVector(0, 0);
            int[string] counts = ["hits": 0];
        }
        export void move() { velocity.x += 1; counts["hits"] += 1; }
        export int read() { return velocity.x + counts["hits"]; }
    });
    auto typed = engine.loadModule("typedState");
    typed.call("move");
    assert(typed.call("read").toInt() == 2);
    auto other = typed.instantiate();
    assert(other.call("read").toInt() == 0);
    engine.bind("HostInstance", other.exportsValue());
    assert(engine.run("auto value = new HostInstance; return value.read();").toInt() == 0);
    assert(engine.run(q{auto value = require("typedState"); auto fresh = new value; return fresh.read();}).toInt() == 0);
}

unittest
{
    auto engine = actorEngine();
    auto result = engine.run(q{
        import actors.player as Actor;
        import actors.player as Again;
        auto required = require("actors.player");
        Actor.damage(10);
        auto player = new Actor;
        auto enemy = new Again;
        player.damage(20);
        auto detached = player.health;
        auto closure = player.closure();
        enemy.foreign = detached;
        return [Actor == Again, Actor == required, Actor.health(), player.health(), enemy.health(),
            Actor.total(), player.total(), enemy.total(), detached(), closure(),
            enemy.invoke(detached), enemy.foreign(), Actor.hp, player.hp];
    });
    auto values = result.arrayValue;
    assert(values[0].truthy() && values[1].truthy());
    long[] expected = [90, 80, 100, 30, 30, 30, 80, 80, 80, 80, 100, 100];
    foreach (index, value; expected) assert(values[index + 2].toInt() == value);

    auto defaultActor = engine.loadModule("actors.player");
    auto a = engine.instantiateModule("actors.player");
    auto b = defaultActor.instantiate();
    a.call("damage", [Value.from(7)]);
    assert(a.call("health").toInt() == 93);
    assert(b.call("health").toInt() == 100);
    assert(defaultActor.call("health").toInt() == 90);
    assert(b.call("total").toInt() == 37);
    assert(a.instantiate().call("health").toInt() == 100);
    assert(a.name == "actors.player");
}

unittest
{
    auto engine = new ScriptEngine();
    int normalRuns, instanceRuns;
    engine.bindNative("normalMark", (scope const(Value)[] args) { return Value.from(++normalRuns); });
    engine.bindNative("instanceMark", (scope const(Value)[] args) { return Value.from(++instanceRuns); });
    engine.registerModule("state", q{
        int once = normalMark();
        normalMark();
        auto sharedTable = { count = 0 };
        instance {
            int serial = instanceMark();
            int[] numbers = [0];
            auto data = { count = 0 };
            auto explicitShared = sharedTable;
        }
        export void change() { numbers[0] += 1; data.count += 1; explicitShared.count += 1; }
        export any read() { return [once, serial, numbers[0], data.count, explicitShared.count]; }
    });
    auto d = engine.loadModule("state");
    d.call("change");
    auto a = d.instantiate();
    auto b = d.instantiate();
    a.call("change");
    auto av = a.call("read").arrayValue;
    auto bv = b.call("read").arrayValue;
    assert(normalRuns == 2 && instanceRuns == 3);
    assert(av[0].toInt() == 1 && av[1].toInt() == 2 && bv[1].toInt() == 3);
    assert(av[2].toInt() == 1 && av[3].toInt() == 1);
    assert(bv[2].toInt() == 0 && bv[3].toInt() == 0 && bv[4].toInt() == 2);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.registerModule("common", q{
        instance int count = 0;
        export void bump() { count += 1; }
        export int read() { return count; }
    });
    engine.registerModule("movement", q{
        import common;
        instance import common as local;
        instance int position = 0;
        export void step() { position += 1; common.bump(); local.bump(); }
        export any read() { return [position, common.read(), local.read()]; }
    });
    engine.registerModule("actor", q{
        import movement as Movement;
        instance import movement;
        instance {
            import movement as anim;
            auto motion = new Movement;
            int hp = 100;
        }
        export void step() { movement.step(); anim.step(); motion.step(); Movement.step(); hp -= 1; }
        export any read() { return [movement.read(), anim.read(), motion.read(), Movement.read(), hp]; }
    });
    auto d = engine.loadModule("actor");
    d.call("step");
    auto a = d.instantiate();
    auto b = d.instantiate();
    a.call("step");
    auto av = a.call("read").arrayValue;
    auto bv = b.call("read").arrayValue;
    foreach (i; 0 .. 3)
    {
        assert(av[i].arrayValue[0].toInt() == 1);
        assert(bv[i].arrayValue[0].toInt() == 0);
        assert(av[i].arrayValue[1].toInt() == 8 && bv[i].arrayValue[1].toInt() == 8);
        assert(av[i].arrayValue[2].toInt() == 1 && bv[i].arrayValue[2].toInt() == 0);
    }
    assert(av[3].arrayValue[0].toInt() == 2 && bv[3].arrayValue[0].toInt() == 2);
    assert(av[4].toInt() == 99 && bv[4].toInt() == 100);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.registerModule("A", "instance import B;");
    engine.registerModule("B", "instance import A;");
    auto cycle = engine.loadModuleSafe("A");
    assert(!cycle.ok && cycle.errorMessage.canFind("A -> B -> A"), cycle.errorMessage);
    assert(engine.run(q{return package.loaded("A") == null && package.loaded("B") == null;}).truthy());
    engine.registerModule("ordinaryA", "import ordinaryB; instance int x = 1; export int read() { return x; }");
    engine.registerModule("ordinaryB", "import ordinaryA; export int read() { return ordinaryA.read(); }");
    assert(engine.loadModule("ordinaryB").call("read").toInt() == 1);
    assert(engine.instantiateModule("ordinaryA").call("read").toInt() == 1);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.bind("later", Value.from(42));
    engine.registerModule("forward", "instance int first = later; instance int later = 1;");
    auto result = engine.loadModuleSafe("forward");
    assert(!result.ok && result.errorMessage.canFind("'later' is not initialized"), result.errorMessage);
    engine.registerModule("failure", q{
        int attempts = 0;
        int next() { attempts += 1; if (attempts == 2) { error("initialization failed"); } return attempts; }
        instance int value = next();
        export int read() { return value; }
        export int tries() { return attempts; }
    });
    auto d = engine.loadModule("failure");
    assertThrown!Exception(d.instantiate());
    assert(d.call("read").toInt() == 1 && d.call("tries").toInt() == 2);
    auto fresh = d.instantiate();
    assert(fresh.call("read").toInt() == 3);
    assert(engine.loadModule("failure") is d);
    auto failed = engine.runSafe("import failure; auto a = new failure; return a.missing;");
    assert(!failed.ok);
}

unittest
{
    auto engine = new ScriptEngine();
    foreach (source; ["instance int x = 1;", "instance {}", "return 1; instance int x = 1;", "void f() { instance int x = 1; }",
        "if (true) instance int x = 1;", "instance { void f() {} }",
        "instance { 1 + 2; }", "instance { struct S { int x; } }", "instance void f() {}",
        "auto f = () => { instance int x = 1; };", "auto x = new 1;", "auto x = {}; auto y = new x;"])
    {
        auto outcome = engine.runSafe(source);
        assert(!outcome.ok, source);
    }
    assert(engine.check("instance { int hp = 100; import movement; } auto p = new movement;").length == 0);
    assert(engine.check("instance int hp = \"bad\";").length > 0);
    assertThrown!Exception(engine.newModule("host").instantiate());
    assert(!engine.runSafe("export instance import invalid;").ok);
    assert(!engine.runSafe("instance instance int x = 1;").ok);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.run(q{
        package.path = ["examples/module-instances/?.dua", "examples/module-instances/?/init.dua"];
    });
    auto values = engine.runFile("examples/module-instances/main.dua").arrayValue;
    long[] expected = [90, 80, 100, 30, 5, 0, 80, 80];
    foreach (i, value; expected) assert(values[i].toInt() == value);
    assert(engine.instantiateModule("actor").call("health").toInt() == 100);
    assert(engine.run("import actor; return actor == require(\"actor\");").truthy());
}

unittest
{
    auto engine = new ScriptEngine();
    engine.registerModule("escape", q{
        auto escaped = {};
        export escaped;
        int attempts = 0;
        any leak(any f) {
            attempts += 1;
            escaped.callback = f;
            if (attempts == 2) { error("fail after escape"); }
            return 1;
        }
        instance int value = leak(() => 123);
        export int read() { return value; }
    });
    auto defaultInstance = engine.loadModule("escape");
    auto failed = engine.runSafe("import escape; auto broken = new escape;");
    assert(!failed.ok && failed.errorMessage.canFind("escape:"));
    assert(failed.stackTrace.canFind("leak"));
    auto leaked = engine.runSafe("import escape; return escape.escaped.callback();");
    assert(!leaked.ok && leaked.errorMessage.canFind("failed module instance"), leaked.errorMessage);
    assert(defaultInstance.call("read").toInt() == 1);
    assert(defaultInstance.instantiate().call("read").toInt() == 1);
    assert(!defaultInstance.loadSafe("instance int unsupported = 1;").ok);
}

unittest
{
    auto engine = new ScriptEngine();
    int attempts;
    engine.bindNative("occasionallyFail", (scope const(Value)[] args) {
        if (++attempts == 1) throw new Exception("first attempt");
        return Value.from(attempts);
    });
    engine.registerModule("retry", "instance int x = occasionallyFail(); export int read() { return x; }");
    assert(!engine.loadModuleSafe("retry").ok);
    assert(engine.run("return package.loaded(\"retry\") == null;").truthy());
    assert(engine.loadModule("retry").call("read").toInt() == 2);
    assert(engine.instantiateModule("retry").call("read").toInt() == 3);

    engine.registerModule("catcher", q{
        try { import bad; } catch (e) { }
        export int ok = 1;
    });
    engine.registerModule("bad", "export int x = 1; import observer; error(\"bad\");");
    engine.registerModule("observer", "import bad; export int read() { return bad.x; }");
    assert(engine.loadModule("catcher")["ok"].toInt() == 1);
    assert(engine.run(q{return package.loaded("bad") == null && package.loaded("observer") == null;}).truthy());
}

unittest
{
    auto engine = new ScriptEngine();
    engine.registerModule("limited", "instance int x = 1; export int recurse() { return recurse(); }");
    RunOptions options;
    options.limits.maxCallDepth = 8;
    auto result = engine.runSafe("import limited; auto a = new limited; return a.recurse();", options);
    assert(!result.ok && result.errorKind == RunErrorKind.callDepthLimit, result.errorMessage);
    assert(result.errorMessage.canFind("limited:") && result.stackTrace.length > 0);
    engine.registerModule("steps", "instance int x = 1; while (true) { x += 1; }");
    options.limits.maxSteps = 40;
    auto limited = engine.runSafe("import steps;", options);
    assert(!limited.ok && limited.errorKind == RunErrorKind.stepLimit, limited.errorMessage);
}
