module dua.module_system;

/**
 * Module loading, caching, and export orchestration for `ScriptEngine`.
 *
 * This implementation is mixed into the public engine so that the module
 * subsystem can use its deliberately narrow execution hooks without creating
 * a second interpreter or exposing engine internals as public API.
 */

import dua.evaluator : Environment, ModuleContext;
import dua.execution;
import dua.binding : NativeCallable;
import dua.value;
import dua.ast;
import dua.module_resolver;
import dua.module_analysis;
import dua.typecheck : checkModuleGraph;
import dua.lexer : lex;
import dua.parser : parse;
import std.algorithm : canFind;
import std.algorithm : map;
import std.array : array;
import std.exception : enforce;
import std.file : exists, readText;
import std.format : format;
import std.string : join, replace;
import std.path : absolutePath;

mixin template ModuleImplementation()
{
    private string[string] moduleSources;
    private string[string] moduleSourceNames;
    private ModuleHandle[string] modules;
    private ModuleHandle[string] contextDefinitions;
    // Retain table identity, not a copy of its associative-array handle. In
    // particular, inserting the first export must update a previously obtained
    // host-created module export table.
    private ref Value[] moduleExportScopes(){return evaluatorContext.moduleExportScopes;}
    private string[] moduleSearchPaths;
    private Value[] moduleLoaders;
    private ref string[] moduleCreationPath(){return evaluatorContext.moduleCreationPath;}
    private size_t moduleLoadDepth;
    private string[] moduleLoadTransaction;
    private ModuleExportInfo[][string] analysisModuleExports;
    private bool[string] analysisModuleExportsComplete;

    ModuleContext createModuleContext(string[] paths=null,ModuleContext parent=null,Object owner=null){
        auto context=new ModuleContext;
        context.parent=parent;context.owner=owner;
        context.paths=paths.length ? paths.dup : parent is null ? effectiveModulePaths().dup : parent.paths.dup;
        context.loaders=parent is null ? effectiveModuleLoaders().dup : parent.loaders.dup;
        context.globals=new Environment(parent is null ? globals : parent.globals);
        context.globals.context=context;
        auto packageValue=Value.from((parent is null ? globals : parent.globals).get("package").tableValue.dup);
        packageValue.tableValue["path"]=Value.from(context.paths.map!(path=>Value.from(path)).array);
        packageValue.tableValue["loaders"]=Value.from(context.loaders.dup);
        context.globals.define("package",packageValue);
        context.release=(ModuleContext ended){
            foreach(fiber;fiberEvaluatorContexts.keys){
                auto state=fiberEvaluatorContexts[fiber];
                if(fiber != cast(void*)Fiber.getThis() &&
                    ((state.contextDepth==0 && state.activeCoroutine is null) ||
                    (state.rootContext !is null && state.rootContext.belongsTo(ended))))
                    fiberEvaluatorContexts.remove(fiber);
            }
        };
        return context;
    }
    void bindContext(ModuleContext context,string name,Value value){
        enforce(context !is null&&context.alive,"Module context is closed");
        context.globals.define(name,value);
    }
    ModuleHandle newContextModule(ModuleContext context,string name){
        enforce(context !is null&&context.alive,"Module context is closed");
        enforce(name !in context.modules,"Context module already exists: "~name);
        auto result=new ModuleHandle(this,name,new Environment(context.globals),ModuleVisibility.explicitExports,true);
        context.modules[name]=result;return result;
    }
    ModuleHandle instantiateModule(string name,ModuleContext context){
        auto scope_=enterModuleContext(context);scope(exit)leaveModuleContext(scope_);
        return instantiateModule(name);
    }
    private ModuleHandle contextHost(string name){
        for(auto context=currentModuleContext();context !is null;context=context.parent)
            if(auto found=name in context.modules){auto handle=cast(ModuleHandle)*found;if(handle.hostCreated)return handle;}
        return null;
    }
    private Environment moduleGlobals(){auto context=currentModuleContext();return context is null ? globals : context.globals;}
    private ref string[] effectiveModulePaths(){auto context=currentModuleContext();if(context !is null)return context.paths;return moduleSearchPaths;}
    private ref Value[] effectiveModuleLoaders(){auto context=currentModuleContext();if(context !is null)return context.loaders;return moduleLoaders;}

    /// Metadata-only host modules for a non-executing analysis service.
    void declareAnalysisModule(string name, ModuleExportInfo[] exports, bool exportsComplete = false)
    {
        if ((name in modules) is null && (name in moduleSources) is null) newModule(name);
        analysisModuleExports[name] = exports.dup;
        analysisModuleExportsComplete[name] = exportsComplete;
    }

    private bool moduleExportsComplete(string name)
    {
        if(contextHost(name) !is null)return false;
        if (auto declared = name in analysisModuleExportsComplete) return *declared;
        // A host may bind more values after registration (e.g. scene instances).
        if (auto host = name in modules) if ((*host).hostCreated) return false;
        return true;
    }

    private ModuleExportInfo[] moduleMetadata(string name)
    {
        if (auto declared = name in analysisModuleExports) return *declared;
        ModuleExportInfo[] result;
        auto contextual=contextHost(name);
        auto host=contextual is null ? name in modules : &contextual;
        if (host !is null)
            if ((*host).hostCreated)
                foreach (member, value; (*host).moduleValue.tableValue)
                {
                    ModuleExportInfo info;
                    info.name = member; info.type = "any"; info.kind = "variable";
                    if (value.kind == ValueKind.function_) info.kind = "function";
                    if ((member in nativeClassTypes) !is null
                        || (value.kind == ValueKind.table && !value.isClassReference
                            && ("new" in value.tableValue) !is null))
                    { info.kind = "type"; info.type = member; info.runtimeValue = true; }
                    result ~= info;
                }
        return result;
    }

    /// Shared lookup for runtime and non-executing module analysis.
    ImportResolution resolveImport(string request, string importer = "", bool pathImport = false, string[string] overlays = null)
    {
        syncPackageConfigFromGlobals();
        if(!pathImport && contextHost(request) !is null)return ImportResolution(request,importer,request,request,null,true,false);
        if (!pathImport && ((request in moduleSources) !is null || (request in modules) !is null))
        {
            auto origin = request in moduleSourceNames;
            return ImportResolution(request, importer, origin is null ? request : *origin,
                origin is null ? request : *origin, null, true, false);
        }
        auto result = resolveFileImport(request, importer, pathImport, effectiveModulePaths(),
            path => (path in overlays) !is null);
        if (result.key.length && ((result.key in moduleSources) !is null || (result.key in modules) !is null))
            result.registered = true;
        return result;
    }

    void setModulePaths(string[] paths)
    {
        effectiveModulePaths() = paths.dup;
        auto packageValue = globals.get("package");
        packageValue.tableValue["path"] = Value.from(paths.map!(p => Value.from(p)).array);
    }

    private string readResolvedImport(ImportResolution resolution)
    {
        if(contextHost(resolution.key) !is null)return "";
        if (auto source = resolution.key in moduleSources) return *source;
        if (auto host = resolution.key in modules)
            if ((*host).hostCreated) return "";
        return readScriptFile(resolution.sourceName);
    }

    private ImportResolution resolveRuntimeImport(string request, string importer, bool pathImport)
    {
        if (!pathImport && (request in moduleSources) is null && (request in modules) is null)
            foreach (loader; effectiveModuleLoaders())
            {
                auto loaded = invokeFunctionValue(loader, [Value.from(request)]);
                if (loaded.kind == ValueKind.string_ && loaded.stringValue.length)
                { moduleSources[request] = loaded.stringValue; break; }
            }
        return resolveImport(request, importer, pathImport);
    }

    private ModuleAnalyzer moduleAnalyzer(bool runtime = false, string[string] overlays = null)
    {
        return new ModuleAnalyzer((request, importer, pathImport) => runtime
            ? resolveRuntimeImport(request, importer, pathImport) : resolveImport(request, importer, pathImport, overlays),
            resolution => (resolution.key in overlays) !is null ? overlays[resolution.key] : readResolvedImport(resolution),
            name => moduleMetadata(name), name => moduleExportsComplete(name));
    }

    /// Source discovery and exported declarations without script evaluation.
    ModuleAnalysis analyzeModule(string source, string sourceName = "", string[] hostClassTypes = null,
        string[string] sourceOverlays = null)
    {
        ModuleAnalysis result;
        string[string] overlays;
        foreach (path, text; sourceOverlays) overlays[canonicalModulePath(path)] = text;
        if (sourceName.length) overlays[canonicalModulePath(sourceName)] = source;
        auto analyzer = moduleAnalyzer(false, overlays);
        try
        {
            auto key = sourceName.length ? canonicalModulePath(sourceName) : "";
            result.root = analyzer.bind(source, sourceName, key);
            result.modules = analyzer.modules;
            result.diagnostics = checkModuleGraph(result, nullableHostClassTypes() ~ hostClassTypes);
        }
        catch (Exception error)
        {
            auto diagnostic = scriptDiagnostic(error);
            result.diagnostics ~= CheckDiagnostic(diagnostic.line, diagnostic.column, error.msg,
                diagnostic.sourceName.length ? diagnostic.sourceName : sourceName,
                diagnostic.hasSourceText ? diagnostic.sourceText : source);
            result.modules = analyzer.modules;
        }
        return result;
    }

    ImportPathCompletion[] importPathCompletions(string prefix, string sourceName, string[string] overlays = null)
    {
        return completeImportPaths(prefix, sourceName, overlays);
    }

    /// Creates a fresh instance; import/require/loadModule still return the default.
    ModuleHandle instantiateModule(string name, bool pathImport = false)
    {
        checkModuleCreation(name);
        return instantiateModuleHandle(requireModuleHandle(name, pathImport));
    }

    private void checkModuleCreation(string name)
    {
        enforce(!moduleCreationPath.canFind(name),
            "Module instantiation cycle: " ~ (moduleCreationPath ~ name).join(" -> "));
    }

    private Value instantiateModuleValue(Value value)
    {
        auto handle = cast(ModuleHandle) value.moduleOwner;
        enforce(value.kind == ValueKind.table && handle !is null && handle.engine is this,
            "new expects a source module instance from this ScriptEngine");
        return instantiateModuleHandle(handle).exportsValue();
    }

    private ModuleHandle instantiateModuleHandle(ModuleHandle handle)
    {
        auto definition = handle.definition is null ? handle : handle.definition;
        checkModuleCreation(definition.moduleName);
        enforce(definition.ready && definition.moduleProgram !is null && !definition.legacyExports,
            "Module '" ~ definition.moduleName ~ "' is not an initialized source module with declarative exports");
        auto context=currentModuleContext();
        auto sharedScope=context is null ? definition.sharedEnvironment : definition.sharedEnvironment.sharedView(context.globals);
        auto result = new ModuleHandle(this, definition.moduleName,
            new Environment(sharedScope), ModuleVisibility.explicitExports);
        result.definition = definition;
        result.sharedEnvironment = definition.sharedEnvironment;
        result.moduleProgram = definition.moduleProgram;
        result.boundModule = definition.boundModule;
        result.sourceName = definition.sourceName;
        result.sourceText = definition.sourceText;result.hasSourceText=definition.hasSourceText;
        initializeModuleInstance(result, false);
        return result;
    }

    private void initializeModuleInstance(ModuleHandle handle, bool isDefault)
    {
        auto environment = handle.environment;
        environment.sharedDeclarations = handle.sharedEnvironment;
        environment.initializingModule = true;
        scope(exit) environment.initializingModule = false;
        scope(failure)
        {
            environment.failedModule = true;
            handle.moduleValue.tableValue = null;
        }
        bool[string] names;
        bool hasInstanceDeclarations = handle.moduleProgram.hasInstanceDeclarations;
        foreach (statement; handle.moduleProgram.statements)
        {
            hasInstanceDeclarations |= statement.isInstance;
            string[] declared;
            if (statement.kind == Statement.Kind.variableDecl) declared = statement.names;
            else if (statement.kind == Statement.Kind.functionDecl) declared = [statement.name];
            else if (statement.kind == Statement.Kind.import_) declared = [statement.aliasName];
            foreach (name; declared)
            {
                enforce((name in names) is null, "Duplicate module declaration '" ~ name ~ "'");
                names[name] = true;
                if (statement.isInstance || statement.kind == Statement.Kind.functionDecl
                    || (environment.context !is null && statement.kind==Statement.Kind.import_))
                    environment.reserveDeclaration(name);
                else if (isDefault) handle.sharedEnvironment.reserveDeclaration(name);
            }
        }
        moduleCreationPath ~= handle.moduleName;
        scope(exit) moduleCreationPath.length -= 1;
        auto previousSource = evaluatorContext.sourceName;
        auto previousModule = evaluatorContext.moduleName;
        auto previousText=evaluatorContext.sourceText;auto previousHasText=evaluatorContext.hasSourceText;
        evaluatorContext.sourceText=handle.sourceText;evaluatorContext.hasSourceText=handle.hasSourceText;
        scope(exit){evaluatorContext.sourceText=previousText;evaluatorContext.hasSourceText=previousHasText;}
        evaluatorContext.sourceName = handle.sourceName;
        evaluatorContext.moduleName = handle.moduleName;
        scope(exit) evaluatorContext.sourceName = previousSource;
        scope(exit) evaluatorContext.moduleName = previousModule;
        moduleExportScopes ~= handle.moduleValue;
        scope(exit) moduleExportScopes.length -= 1;
        try
        {
            ExecutionResult result;
            foreach (statement; handle.moduleProgram.statements)
            {
                if (isDefault || statement.isInstance || statement.kind == Statement.Kind.functionDecl
                    || statement.kind == Statement.Kind.export_
                    || (environment.context !is null && statement.kind==Statement.Kind.import_))
                {
                    result = executeStatement(statement, environment);
                    if (result.returned) break;
                }
                else if (statement.isExported && statement.kind == Statement.Kind.variableDecl)
                    foreach (name; statement.names) exportSymbol(name, environment.get(name));
            }
            // Instance declarations do not implicitly export the final container
            // initializer or dependency. Such modules use explicit exports only.
            if (isDefault && !hasInstanceDeclarations && handle.moduleValue.tableValue.length == 0
                && result.lastValue.kind == ValueKind.table)
            {
                handle.moduleValue.tableValue = result.lastValue.tableValue.dup;
                handle.legacyExports = true;
            }
            // export は既存の値スナップショットのまま、非 null 境界だけを公開側にも残します。
            foreach (statement; handle.moduleProgram.statements)
                if (statement.kind == Statement.Kind.variableDecl
                    && (hasNonNullConstraint(statement.declaredType) || hasContainerConstraint(statement.declaredType)))
                    foreach (name; statement.names)
                        if ((name in handle.moduleValue.tableValue) !is null)
                            handle.moduleValue.addFieldConstraint(name, statement.declaredType, containerValidator(statement.declaredType));
            handle.ready = true;
            handle.moduleValue.moduleOwner = handle;
        }
        catch (Exception error)
        {
            throw withSourceContext(error, handle.sourceName);
        }
    }

    void registerModule(string name, string source, string sourceName = "")
    {
        enforce((name in moduleSources) is null && (name in modules) is null,
            format("Module '%s' is already registered", name));
        if (sourceName.length)
        {
            auto key = canonicalModulePath(sourceName);
            if (auto existing = key in moduleSources)
                enforce(*existing == source, "Conflicting registered sources for '" ~ key ~ "'");
            moduleSourceNames[name] = key;
            moduleSources[key] = source;
            moduleSourceNames[key] = key;
        }
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
        throw outcomeException(result,result.errorMessage ~ trace);
        assert(0);
    }

    /// Safe counterpart to loadModule. Module failures are returned as data.
    RunOutcome loadModuleSafe(string name)
    {
        evaluatorContext.callStack.clear();
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
            outcome.errorMessage = withSourceContext(error, name).msg;
            outcome.diagnostic = scriptDiagnostic(withSourceContext(error, name));
            outcome.stackTrace = evaluatorContext.lastErrorStack.length > 0
                ? evaluatorContext.lastErrorStack.dup : evaluatorContext.callStack.snapshot();
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
            return requireModuleHandle(canonicalModulePath(path));

        auto trace = result.stackTrace.length > 0
            ? "\nStack:\n  " ~ result.stackTrace.join("\n  ") : "";
        throw outcomeException(result,result.errorMessage ~ trace);
        assert(0);
    }

    /// Safe counterpart to loadModuleFile.
    RunOutcome loadModuleFileSafe(string path)
    {
        try
        {
            auto key = canonicalModulePath(path);
            moduleSources[key] = readScriptFile(key);
            moduleSourceNames[key] = key;
            return loadModuleSafe(key);
        }
        catch (Exception error)
        {
            RunOutcome outcome;
            outcome.ok = false;
            outcome.errorMessage = withSourceContext(error, path).msg;
            outcome.diagnostic = scriptDiagnostic(withSourceContext(error, path));
            outcome.errorKind = RunErrorKind.runtime;
            return outcome;
        }
    }

    private RunOutcome runInModuleSafe(ModuleHandle hostModule, string source,
        Environment environment, RunOptions options)
    {
        if (options.sourceName.length == 0)
            options.sourceName = hostModule.sourceName.length ? hostModule.sourceName : hostModule.moduleName;
        auto previousModule = evaluatorContext.moduleName;
        evaluatorContext.moduleName = hostModule.moduleName;
        scope(exit) evaluatorContext.moduleName = previousModule;
        moduleExportScopes ~= hostModule.moduleValue;
        scope (exit) moduleExportScopes.length -= 1;
        auto outcome = runInEnvironmentSafe(source, environment, options, hostModule.boundModule, hostModule);
        if (hostModule.visibility == ModuleVisibility.explicitExports)
        {
            // Keep the historical `return table` form when no export was declared.
            if (hostModule.moduleValue.tableValue.length == 0
                && outcome.ok && outcome.value.kind == ValueKind.table)
                hostModule.moduleValue.tableValue = outcome.value.tableValue.dup;
        }
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
            effectiveModulePaths() ~= args[0].toHostString();
            return Value.nullValue();
        });
        bindNative("setModuleLoaders", (scope const(Value)[] args) {
            effectiveModuleLoaders().length = 0;
            foreach (loader; args)
            {
                enforce(loader.kind == ValueKind.function_, "setModuleLoaders expects function arguments");
                effectiveModuleLoaders() ~= cast(Value) loader;
            }
            return Value.nullValue();
        });
        bindNative("addModuleLoader", (scope const(Value)[] args) {
            enforce(args.length == 1, "addModuleLoader(loader) expects one argument");
            enforce(args[0].kind == ValueKind.function_, "addModuleLoader expects a function");
            effectiveModuleLoaders() ~= cast(Value) args[0];
            return Value.nullValue();
        });

        Value[string] packageLib;
        packageLib["require"] = globals.get("require");
        packageLib["addPath"] = Value.fromFunction(new NativeCallable("package.addPath", (scope const(Value)[] args) {
            enforce(args.length == 1, "package.addPath(path) expects one argument");
            effectiveModulePaths() ~= args[0].toHostString();
            return Value.nullValue();
        }));
        packageLib["addLoader"] = Value.fromFunction(new NativeCallable("package.addLoader", (scope const(Value)[] args) {
            enforce(args.length == 1, "package.addLoader(loader) expects one argument");
            enforce(args[0].kind == ValueKind.function_, "package.addLoader expects a function");
            effectiveModuleLoaders() ~= cast(Value) args[0];
            return Value.nullValue();
        }));
        packageLib["clearLoaders"] = Value.fromFunction(new NativeCallable("package.clearLoaders", (scope const(Value)[] args) {
            enforce(args.length == 0, "package.clearLoaders() takes no arguments");
            effectiveModuleLoaders().length = 0;
            return Value.nullValue();
        }));
        packageLib["loaded"] = Value.fromFunction(new NativeCallable("package.loaded", (scope const(Value)[] args) {
            enforce(args.length == 1, "package.loaded(name) expects one argument");
            auto resolution = resolveImport(args[0].toHostString(), evaluatorContext.sourceName);
            if(auto context=currentModuleContext())if(auto cached=resolution.key in context.modules)
                return (cast(ModuleHandle)*cached).exportsValue();
            if (auto cached = resolution.key in modules)
                return (*cached).exportsValue();
            return Value.nullValue();
        }));
        packageLib["path"] = Value.from(effectiveModulePaths().map!(item => Value.from(item)).array);
        packageLib["loaders"] = Value.from(effectiveModuleLoaders().dup);
        globals.define("package", Value.from(packageLib));
    }

    private void syncPackageConfigFromGlobals()
    {
        if (!moduleGlobals().contains("package")) return;
        auto packageValue = moduleGlobals().get("package");
        if (packageValue.kind != ValueKind.table) return;
        if (auto paths = "path" in packageValue.tableValue)
        {
            if (paths.kind == ValueKind.array)
            {
                effectiveModulePaths().length = 0;
                foreach (item; paths.arrayValue)
                    effectiveModulePaths() ~= item.toHostString();
            }
        }
    }

    private ModuleHandle requireContextModuleHandle(string request,bool pathImport,string importer){
        auto context=currentModuleContext();
        enforce(context.alive,"Module context is closed");
        if(!pathImport)if(auto host=contextHost(request))return host;
        auto resolution=resolveRuntimeImport(request,importer.length ? importer : evaluatorContext.sourceName,pathImport);
        enforce(resolution.key.length,unresolvedImportMessage(resolution));
        auto name=resolution.key;
        if(auto host=name in modules)if((*host).hostCreated)return *host;
        if(auto cached=name in context.modules){
            auto result=cast(ModuleHandle)*cached;
            enforce(result.ready||result.hostCreated,"Import cycle: "~name);
            return result;
        }
        auto definition=contextDefinitions.get(name,null);
        bool first=definition is null;
        if(first){
            auto source=readResolvedImport(resolution);
            auto sharedScope=new Environment(globals);
            definition=new ModuleHandle(this,name,sharedScope,ModuleVisibility.explicitExports);
            definition.sharedEnvironment=sharedScope;definition.sourceName=resolution.sourceName;
            definition.sourceText=source;definition.hasSourceText=true;
            // 解析結果だけを共有し、self/scenesを持つviewは文脈ごとに作ります。
            definition.boundModule=moduleAnalyzer(true).bind(source,resolution.sourceName,name);
            definition.moduleProgram=definition.boundModule.program;
            contextDefinitions[name]=definition;
        }else enforce(definition.ready,"Shared module initialization is incomplete or cyclic: "~name);
        auto environment=new Environment(definition.sharedEnvironment.sharedView(context.globals));
        auto result=new ModuleHandle(this,name,environment,ModuleVisibility.explicitExports);
        result.definition=definition;result.sharedEnvironment=definition.sharedEnvironment;
        result.sourceName=definition.sourceName;result.sourceText=definition.sourceText;result.hasSourceText=true;
        result.boundModule=definition.boundModule;result.moduleProgram=definition.moduleProgram;
        context.modules[name]=result;
        try{
            if(!first&&definition.legacyExports){result.moduleValue=definition.moduleValue;result.legacyExports=true;result.ready=true;}
            else initializeModuleInstance(result,first);
            if(first){definition.ready=true;definition.legacyExports=result.legacyExports;if(result.legacyExports)definition.moduleValue=result.moduleValue;}
            return result;
        }catch(Exception error){
            context.modules.remove(name);if(first)contextDefinitions.remove(name);
            throw withDiagnosticSource(withSourceContext(error,definition.sourceName),definition.sourceName,definition.sourceText);
        }
    }

    private ModuleHandle requireModuleHandle(string request, bool pathImport = false, string importer = "")
    {
        if(currentModuleContext() !is null)return requireContextModuleHandle(request,pathImport,importer);
        syncPackageConfigFromGlobals();
        auto resolution = resolveRuntimeImport(request, importer.length ? importer : evaluatorContext.sourceName, pathImport);
        enforce(resolution.key.length, unresolvedImportMessage(resolution));
        auto name = resolution.key;
        if (auto cached = name in modules)
        {
            enforce((*cached).ready || (*cached).hostCreated,
                "Import cycle: " ~ (moduleCreationPath ~ name).join(" -> "));
            return *cached;
        }
        auto source = readResolvedImport(resolution);

        bool outermost = moduleLoadDepth++ == 0;
        if (outermost) moduleLoadTransaction.length = 0;
        auto checkpoint = moduleLoadTransaction.length;
        scope(exit)
        {
            --moduleLoadDepth;
            if (outermost) moduleLoadTransaction.length = 0;
        }
        scope(failure)
        {
            foreach (loaded; moduleLoadTransaction[checkpoint .. $])
            {
                if (auto entry = loaded in modules)
                {
                    (*entry).ready = false;
                    (*entry).environment.failedModule = true;
                    (*entry).moduleValue.tableValue = null;
                }
                modules.remove(loaded);
            }
            moduleLoadTransaction.length = checkpoint;
        }
        auto sharedScope = new Environment(globals);
        auto handle = new ModuleHandle(this, name, new Environment(sharedScope),
            ModuleVisibility.explicitExports);
        handle.sharedEnvironment = sharedScope;
        handle.sourceName = resolution.sourceName;
        handle.sourceText=source;handle.hasSourceText=true;
        // Reserve identity during initialization; re-entry is a cycle error.
        handle.moduleValue.moduleOwner = handle;
        modules[name] = handle;
        moduleLoadTransaction ~= name;
        scope(failure) modules.remove(name);
        try
        {
            handle.boundModule = moduleAnalyzer(true).bind(source, handle.sourceName, name);
            handle.moduleProgram = handle.boundModule.program;
            initializeModuleInstance(handle, true);
        }
        catch (Exception error) { throw withDiagnosticSource(withSourceContext(error, handle.sourceName),handle.sourceName,handle.sourceText); }
        return handle;
    }

    private void exportSymbol(string name, Value value)
    {
        enforce(moduleExportScopes.length > 0,
            "export can only be used inside module source");
        moduleExportScopes[$ - 1].tableValue[name] = value.valueCopy();
    }

}
