module dua.module_system;

/**
 * Module loading, caching, and export orchestration for `ScriptEngine`.
 *
 * This implementation is mixed into the public engine so that the module
 * subsystem can use its deliberately narrow execution hooks without creating
 * a second interpreter or exposing engine internals as public API.
 */

import dua.evaluator : Environment;
import dua.execution;
import dua.value;
import std.algorithm : map;
import std.array : array;
import std.exception : enforce;
import std.file : exists, readText;
import std.format : format;
import std.string : join, replace;

mixin template ModuleImplementation()
{
    private string[string] moduleSources;
    private ModuleHandle[string] modules;
    private Value[string][] moduleExportScopes;
    private string[] moduleSearchPaths;
    private Value[] moduleLoaders;

    void registerModule(string name, string source)
    {
        enforce((name in moduleSources) is null && (name in modules) is null,
            format("Module '%s' is already registered", name));
        moduleSources[name] = source;
    }

    /// Creates an empty, independently scoped module that can be populated from D.
    ModuleHandle newModule(string name)
    {
        enforce(name.length > 0, "Module name must not be empty");
        enforce((name in modules) is null && (name in moduleSources) is null,
            format("Module '%s' is already registered", name));
        auto result = new ModuleHandle(this, name, new Environment(globals),
            ModuleVisibility.explicitExports, true);
        modules[name] = result;
        return result;
    }

    void clearModuleCache()
    {
        string[] sourceModuleNames;
        foreach (name, handle; modules)
            if (!handle.hostCreated) sourceModuleNames ~= name;
        foreach (name; sourceModuleNames)
            modules.remove(name);
    }

    /// Loads a registered or discoverable Dua module and returns its exports.
    /// Modules are evaluated in their own file scope and cached by name.
    ModuleHandle loadModule(string name)
    {
        auto result = loadModuleSafe(name);
        if (result.ok)
            return requireModuleHandle(name);

        auto trace = result.stackTrace.length > 0
            ? "\nStack:\n  " ~ result.stackTrace.join("\n  ") : "";
        enforce(false, result.errorMessage ~ trace);
        assert(0);
    }

    /// Safe counterpart to loadModule. Module failures are returned as data.
    RunOutcome loadModuleSafe(string name)
    {
        evaluatorContext.callStack.length = 0;
        evaluatorContext.lastErrorStack.length = 0;
        evaluatorContext.currentRunOptions = RunOptions.init;
        evaluatorContext.executedSteps = 0;
        RunOutcome outcome;
        try
        {
            outcome.value = requireModuleHandle(name).exportsValue();
            outcome.ok = true;
            outcome.errorKind = RunErrorKind.none;
        }
        catch (Exception error)
        {
            outcome.ok = false;
            outcome.errorMessage = error.msg;
            outcome.stackTrace = evaluatorContext.lastErrorStack.length > 0
                ? evaluatorContext.lastErrorStack.dup : evaluatorContext.callStack.dup;
            outcome.errorKind = RunErrorKind.runtime;
        }
        outcome.stepsExecuted = evaluatorContext.executedSteps;
        evaluatorContext.currentRunOptions = RunOptions.init;
        return outcome;
    }

    /// Loads a file as a cached module, using its path as the cache key.
    ModuleHandle loadModuleFile(string path)
    {
        auto result = loadModuleFileSafe(path);
        if (result.ok)
            return requireModuleHandle(path);

        auto trace = result.stackTrace.length > 0
            ? "\nStack:\n  " ~ result.stackTrace.join("\n  ") : "";
        enforce(false, result.errorMessage ~ trace);
        assert(0);
    }

    /// Safe counterpart to loadModuleFile.
    RunOutcome loadModuleFileSafe(string path)
    {
        try
        {
            moduleSources[path] = readScriptFile(path);
            return loadModuleSafe(path);
        }
        catch (Exception error)
        {
            RunOutcome outcome;
            outcome.ok = false;
            outcome.errorMessage = error.msg;
            outcome.errorKind = RunErrorKind.runtime;
            return outcome;
        }
    }

    private RunOutcome runInModuleSafe(ModuleHandle hostModule, string source,
        Environment environment, RunOptions options)
    {
        moduleExportScopes ~= hostModule.moduleValue.tableValue;
        auto outcome = runInEnvironmentSafe(source, environment, options);
        if (hostModule.visibility == ModuleVisibility.explicitExports)
        {
            hostModule.moduleValue.tableValue = moduleExportScopes[$ - 1];
            // Keep the historical `return table` form when no export was declared.
            if (hostModule.moduleValue.tableValue.length == 0
                && outcome.ok && outcome.value.kind == ValueKind.table)
                hostModule.moduleValue.tableValue = outcome.value.tableValue.dup;
        }
        moduleExportScopes.length -= 1;
        return outcome;
    }

    private void installRequireFunction()
    {
        bindNative("require", (scope const(Value)[] args) {
            enforce(args.length == 1, "require(name) expects exactly one argument");
            return requireModuleHandle(args[0].toHostString()).exportsValue();
        });
        bindNative("addModulePath", (scope const(Value)[] args) {
            enforce(args.length == 1, "addModulePath(path) expects one argument");
            moduleSearchPaths ~= args[0].toHostString();
            return Value.nullValue();
        });
        bindNative("setModuleLoaders", (scope const(Value)[] args) {
            moduleLoaders.length = 0;
            foreach (loader; args)
            {
                enforce(loader.kind == ValueKind.function_, "setModuleLoaders expects function arguments");
                moduleLoaders ~= cast(Value) loader;
            }
            return Value.nullValue();
        });
        bindNative("addModuleLoader", (scope const(Value)[] args) {
            enforce(args.length == 1, "addModuleLoader(loader) expects one argument");
            enforce(args[0].kind == ValueKind.function_, "addModuleLoader expects a function");
            moduleLoaders ~= cast(Value) args[0];
            return Value.nullValue();
        });

        Value[string] packageLib;
        packageLib["require"] = globals.get("require");
        packageLib["addPath"] = Value.fromFunction(new NativeCallable("package.addPath", (scope const(Value)[] args) {
            enforce(args.length == 1, "package.addPath(path) expects one argument");
            moduleSearchPaths ~= args[0].toHostString();
            return Value.nullValue();
        }));
        packageLib["addLoader"] = Value.fromFunction(new NativeCallable("package.addLoader", (scope const(Value)[] args) {
            enforce(args.length == 1, "package.addLoader(loader) expects one argument");
            enforce(args[0].kind == ValueKind.function_, "package.addLoader expects a function");
            moduleLoaders ~= cast(Value) args[0];
            return Value.nullValue();
        }));
        packageLib["clearLoaders"] = Value.fromFunction(new NativeCallable("package.clearLoaders", (scope const(Value)[] args) {
            enforce(args.length == 0, "package.clearLoaders() takes no arguments");
            moduleLoaders.length = 0;
            return Value.nullValue();
        }));
        packageLib["loaded"] = Value.fromFunction(new NativeCallable("package.loaded", (scope const(Value)[] args) {
            enforce(args.length == 1, "package.loaded(name) expects one argument");
            if (auto cached = args[0].toHostString() in modules)
                return (*cached).exportsValue();
            return Value.nullValue();
        }));
        packageLib["path"] = Value.from(moduleSearchPaths.map!(item => Value.from(item)).array);
        packageLib["loaders"] = Value.from(moduleLoaders.dup);
        globals.define("package", Value.from(packageLib));
    }

    private void syncPackageConfigFromGlobals()
    {
        if (!globals.contains("package")) return;
        auto packageValue = globals.get("package");
        if (packageValue.kind != ValueKind.table) return;
        if (auto paths = "path" in packageValue.tableValue)
        {
            if (paths.kind == ValueKind.array)
            {
                moduleSearchPaths.length = 0;
                foreach (item; paths.arrayValue)
                    moduleSearchPaths ~= item.toHostString();
            }
        }
    }

    private ModuleHandle requireModuleHandle(string name)
    {
        syncPackageConfigFromGlobals();
        if (auto cached = name in modules) return *cached;

        auto source = name in moduleSources;
        if (source is null)
        {
            auto resolved = resolveModuleSource(name);
            if (resolved.length > 0)
            {
                moduleSources[name] = resolved;
                source = name in moduleSources;
            }
        }
        enforce(source !is null, format("Module '%s' is not registered", name));

        auto handle = new ModuleHandle(this, name, new Environment(globals),
            ModuleVisibility.explicitExports);
        modules[name] = handle; // Make cycles share module identity while loading.
        scope(failure) modules.remove(name);
        auto outcome = handle.loadSafe(*source);
        enforce(outcome.ok, outcome.errorMessage);
        return handle;
    }

    private void exportSymbol(string name, Value value)
    {
        enforce(moduleExportScopes.length > 0,
            "export can only be used inside module source");
        moduleExportScopes[$ - 1][name] = value.valueCopy();
    }

    private string resolveModuleSource(string moduleName)
    {
        foreach (loader; moduleLoaders)
        {
            auto loaded = invokeFunctionValue(loader, [Value.from(moduleName)]);
            if (loaded.kind == ValueKind.string_ && loaded.stringValue.length > 0)
                return loaded.stringValue;
        }

        auto normalized = moduleName.replace(".", "/");
        foreach (pattern; moduleSearchPaths)
        {
            auto path = pattern.replace("?", normalized);
            if (exists(path)) return readText(path);
        }
        return "";
    }
}
