module module_imports;
import dua;
import dua.module_resolver;
import std.file : mkdirRecurse, write, exists;
import std.path : buildPath, absolutePath;
import std.stdio : writeln;
import std.algorithm : canFind;

void main()
{
    auto root = absolutePath("import-fixtures");
    mkdirRecurse(buildPath(root, "a")); mkdirRecurse(buildPath(root, "b"));
    write(buildPath(root, "a", "types.dua"), `export alias Kind = int | string; export Kind value = 3;`);
    write(buildPath(root, "b", "types.dua"), `export alias Kind = bool; export Kind value = true;`);
    write(buildPath(root, "count.dua"), `ticks += 1; export int value = ticks;`);
    auto engine = new ScriptEngine;
    engine.bind("ticks", Value.from(0));
    engine.setModulePaths([buildPath(root, "?.dua"), buildPath(root, "?", "init.dua")]);
    RunOptions options; options.sourceName = buildPath(root, "entry.dua"); options.typeCheck = true;
    auto result = engine.runSafe(q{
        import "./a/types.dua" as a;
        import "./b/types.dua" as b;
        a.Kind first = a.value; b.Kind second = b.value;
        import count as c;
        import "./a/../count.dua" as again;
        return first == 3 && second && c == again && ticks == 1;
    }, options);
    assert(result.ok && result.value.truthy(), result.errorMessage);
    writeln("PASS relative imports, qualified aliases, distinct files, normalized identity, initialize once");

    auto invalid = engine.runSafe(`import "./a/types.dua" as a; a.Kind x = false;`, options);
    assert(!invalid.ok, "imported union must reject bool");
    auto privateType = engine.analyzeModule(`import "./a/types.dua" as a; a.Private x = 1;`, options.sourceName);
    assert(privateType.diagnostics.length && privateType.diagnostics[0].message.canFind("does not export type"));
    writeln("PASS imported type checking and private type visibility");

    write(buildPath(root, "cycleA.dua"), `import "./cycleB.dua";`);
    write(buildPath(root, "cycleB.dua"), `import "./cycleA.dua";`);
    auto cycle = engine.runSafe(`import "./cycleA.dua";`, options);
    assert(!cycle.ok && cycle.errorMessage.canFind("Import cycle") && cycle.errorMessage.canFind("cyclea.dua")
        && cycle.errorMessage.canFind("cycleb.dua"), cycle.errorMessage);
    auto missing = engine.analyzeModule(`import "./missing.dua";`, options.sourceName);
    assert(missing.diagnostics.length && missing.diagnostics[0].message.canFind("entry.dua")
        && missing.diagnostics[0].message.canFind("missing.dua"));
    writeln("PASS cycle chain and missing-import context");

    string[string] overlays;
    overlays[buildPath(root, "unsaved.dua")] = `export alias Number = int; export Number value = 8;`;
    auto overlay = engine.analyzeModule(`import "./unsaved.dua" as u; u.Number x = u.value;`, options.sourceName, null, overlays);
    assert(!overlay.diagnostics.length, overlay.diagnostics.length ? overlay.diagnostics[0].message : "");
    assert(overlay.root.imports[0].key == canonicalModulePath(buildPath(root, "unsaved.dua")));
    assert(overlay.modules[0].exports[0].kind == "type");
    assert(!exists(buildPath(root, "unsaved.dua")), "overlay must not write source");
    auto paths = engine.importPathCompletions("./un", options.sourceName, overlays);
    assert(paths.length == 1 && paths[0].label == "./unsaved.dua");
    writeln("PASS unsaved overlay, export metadata, path candidates, analysis has no side effects");

    auto noOrigin = engine.runSafe(`import "./a/types.dua";`);
    assert(!noOrigin.ok && noOrigin.errorMessage.canFind("saved source path"));
    auto defaultAlias = engine.runSafe(`import "./a/types.dua"; return types.value;`, options);
    assert(defaultAlias.ok && defaultAlias.value.toInt() == 3, defaultAlias.errorMessage);
    auto publicOnly = engine.analyzeModule(`import "./a/types.dua" as a; return a.hidden;`, options.sourceName);
    assert(publicOnly.diagnostics.length && publicOnly.diagnostics[0].message.canFind("does not export value"));
    auto noLeak = engine.runSafe(`Kind hidden = 3;`, options);
    assert(!noLeak.ok, "source module alias leaked into importer");
    auto analysisOnly = engine.analyzeModule(`import count;`, options.sourceName);
    assert(!analysisOnly.diagnostics.length);
    assert(engine.run(`return ticks;`).toInt() == 1, "analysis ran an initializer");
    writeln("PASS saved-origin requirement, default name, value visibility, no type leak, no initialization during analysis");

    write(buildPath(root, "bad.dua"), "export int value = \"bad\";");
    auto bad = engine.analyzeModule(`import "./bad.dua";`, options.sourceName);
    assert(bad.diagnostics.length && bad.diagnostics[0].sourceName == canonicalModulePath(buildPath(root, "bad.dua"))
        && bad.diagnostics[0].sourceText.canFind("bad"));
    auto newInstance = engine.loadModuleFile(buildPath(root, "a", "types.dua")).instantiate();
    assert(newInstance.get("value").toInt() == 3);
    assert(newInstance.run(`Kind next = value; return next;`).toInt() == 3);
    engine.clearModuleCache();
    assert(engine.loadModuleFile(buildPath(root, "a", "types.dua")).get("value").toInt() == 3);
    writeln("PASS dependency diagnostic snapshot, module instances, module-local type reuse and explicit cache clear");

    auto origin = buildPath(root, "registered.dua");
    write(origin, `ticks += 1; export auto value = 9;`);
    auto registrationEngine = new ScriptEngine;
    registrationEngine.bind("ticks", Value.from(0));
    registrationEngine.registerModule("named", `ticks += 1; export auto value = 9;`, origin);
    auto registered = registrationEngine.runSafe(`import named; import "./registered.dua" as file; return named == file && ticks == 1;`, options);
    assert(registered.ok && registered.value.truthy(), registered.errorMessage);
    auto simple = registrationEngine.analyzeModule(`import named; int x = named.value;`, options.sourceName);
    assert(!simple.diagnostics.length, simple.diagnostics.length ? simple.diagnostics[0].message : "");
    auto legacy = registrationEngine.analyzeModule(`int local = 2; export local;`, options.sourceName);
    assert(!legacy.diagnostics.length && legacy.root.exports.length == 1 && legacy.root.exports[0].name == "local");
    writeln("PASS registered source origins share identity, inferred export values, legacy export statement");

    write(buildPath(root, "record.dua"), `struct Record { int count; } export alias PublicRecord = Record; export auto make = () => Record(4);`);
    auto record = engine.runSafe(`import "./record.dua" as record; record.PublicRecord data = record.make(); return data.count;`, options);
    assert(record.ok && record.value.toInt() == 4, record.errorMessage);
    write(buildPath(root, "lambda.dua"), `export auto make = () { alias Local = int; Local x = 5; return x; };`);
    auto lambda = engine.runSafe(`import "./lambda.dua" as local; return local.make();`, options);
    assert(lambda.ok && lambda.value.toInt() == 5, lambda.errorMessage);
    assert(!engine.runSafe(`Local x = 3;`, options).ok);
    writeln("PASS private struct factories, public aliases to private shapes, lambda-local type isolation");

    auto globalEngine = new ScriptEngine;
    assert(globalEngine.runSafe(`alias GlobalCount = int; GlobalCount value = 1;`).ok);
    assert(!globalEngine.runSafe(`alias GlobalCount = int;`).ok, "legacy global duplicate alias behavior changed");
    writeln("PASS legacy global alias duplicate checks");

    write(buildPath(root, "api.dua"), q{
        export struct Record { int count; }
        export table Row { int count; }
        export alias Number = int;
        export int first(int head, int tail...) { return head; }
    });
    auto aggregate = engine.runSafe(q{
        import "./api.dua" as api;
        api.Record record = api.Record(6);
        api.Row row = { count = 4 };
        api.Number[] numbers = [record.count, row.count];
        api.Number converted = cast(api.Number) numbers[0];
        return converted is api.Number && api.first(6, 7, 8) == 6;
    }, options);
    assert(aggregate.ok && aggregate.value.truthy(), aggregate.errorMessage);
    auto apiAnalysis = engine.analyzeModule(`import "./api.dua" as api; api.first(1, 2, "bad");`, options.sourceName);
    assert(apiAnalysis.diagnostics.length, "imported variadic parameter type must be checked");
    writeln("PASS exported aggregates, qualified array/cast/is types and variadic metadata");

    auto rollbackEngine = new ScriptEngine;
    rollbackEngine.registerModule("dependency", `export int value = 1;`);
    rollbackEngine.registerModule("failing", `import dependency; error("initializer failed");`);
    auto rollback = rollbackEngine.loadModuleSafe("failing");
    assert(!rollback.ok && rollback.errorMessage.canFind("initializer failed"));
    assert(rollbackEngine.run(`return package.loaded("failing") == null && package.loaded("dependency") == null;`).truthy());
    assert(rollbackEngine.loadModule("dependency").get("value").toInt() == 1);
    auto ordinaryCycleEngine = new ScriptEngine;
    ordinaryCycleEngine.bind("ticks", Value.from(0));
    ordinaryCycleEngine.registerModule("A", `ticks += 1; import B;`);
    ordinaryCycleEngine.registerModule("B", `ticks += 1; import A;`);
    auto ordinaryCycle = ordinaryCycleEngine.loadModuleSafe("A");
    assert(!ordinaryCycle.ok && ordinaryCycle.errorMessage.canFind("A -> B -> A"));
    assert(ordinaryCycleEngine.run(`return ticks;`).toInt() == 0);
    writeln("PASS cycle rejection before initialization and nested load rollback");

    engine.registerModule("legacyTable", `return { value = 4 };`);
    auto legacyTable = engine.runSafe(`import legacyTable; int value = legacyTable.value; return value;`, options);
    assert(legacyTable.ok && legacyTable.value.toInt() == 4, legacyTable.errorMessage);
    auto legacyAnalysis = engine.analyzeModule(`import legacyTable; int value = legacyTable.value;`, options.sourceName);
    assert(!legacyAnalysis.diagnostics.length && legacyAnalysis.modules[0].dynamicExports);
    writeln("PASS computed legacy table exports remain compatible without evaluation");
}
