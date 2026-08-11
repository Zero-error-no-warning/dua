module dua.runtime;

import dua.ast;
import dua.lexer : lex;
import dua.parser : parse;
import dua.value;
import core.thread : Fiber;
import std.algorithm : canFind, map;
import std.array : array;
import std.conv : to;
import std.datetime.systime : Clock;
import std.exception : enforce;
import std.file : exists, readText, remove, write;
import std.format : format;
import std.math : floor;
import std.string : join, replace, startsWith;
import std.traits : BaseClassesTuple, isAggregateType;
import std.uni : toLower, toUpper;
import std.utf : byDchar;

alias NativeFunction = Value delegate(scope const(Value)[] args);

private final class ScriptThrownException : Exception
{
    Value thrownValue;

    this(Value value, string message)
    {
        super(message);
        thrownValue = value;
    }
}

enum RunErrorKind
{
    none,
    runtime,
    stepLimit,
    callDepthLimit
}

struct ExecutionLimits
{
    /// Zero means unlimited.
    size_t maxSteps;
    /// Zero means unlimited.
    size_t maxCallDepth;
}

struct RunOptions
{
    ExecutionLimits limits;
    bool typeCheck;
}

struct RunOutcome
{
    bool ok;
    Value value;
    string errorMessage;
    string[] stackTrace;
    RunErrorKind errorKind;
    size_t stepsExecuted;
}

struct CheckDiagnostic
{
    size_t line;
    size_t column;
    string message;
}

private struct StaticFunctionInfo
{
    string[] parameterTypes;
    string returnType;
}

final class Environment
{
    Environment parent;
    private Value[string] values;

    this(Environment parent = null)
    {
        this.parent = parent;
    }

    void define(string name, Value value)
    {
        enforce((name in values) is null,
            format("Variable '%s' is already defined in this scope", name));
        values[name] = value;
    }

    bool contains(string name) const
    {
        return (name in values) !is null || (parent !is null && parent.contains(name));
    }

    Value get(string name)
    {
        if (auto value = name in values)
        {
            return *value;
        }
        if (parent !is null)
        {
            return parent.get(name);
        }
        enforce(false, format("Undefined variable '%s'", name));
        assert(0);
    }

    Value* find(string name)
    {
        if (auto value = name in values) return value;
        return parent is null ? null : parent.find(name);
    }

    void assign(string name, Value value)
    {
        if (auto slot = name in values)
        {
            *slot = value;
            return;
        }
        if (parent !is null)
        {
            parent.assign(name, value);
            return;
        }
        enforce(false, format("Cannot assign undefined variable '%s'", name));
    }
}

struct ExecutionResult
{
    Value lastValue;
    bool returned;
    bool broke;
    bool continued;
}

final class NativeCallable : CallableValue
{
    private NativeFunction nativeCallback;

    this(string name, NativeFunction callback)
    {
        super(name);
        this.nativeCallback = callback;
    }

    override Value invoke(Value[] args)
    {
        return nativeCallback(args);
    }
}

/// A host-created Dua module with an isolated top-level environment.
/// Values bound through this facade are exposed as module exports.
final class ScriptModule
{
    private ScriptEngine engine;
    private string moduleName;
    private Environment environment;
    private Value moduleValue;

    private this(ScriptEngine engine, string name, Environment environment)
    {
        this.engine = engine;
        this.moduleName = name;
        this.environment = environment;

        // Ensure that the associative array backing the table is allocated so
        // copies returned by import keep observing subsequently added exports.
        Value[string] exports;
        exports["__dua_module_placeholder"] = Value.nullValue();
        exports.remove("__dua_module_placeholder");
        moduleValue = Value.from(exports);
    }

    string name() const
    {
        return moduleName;
    }

    void bind(string name, Value value)
    {
        environment.define(name, value);
        moduleValue.tableValue[name] = value;
        engine.updateHostModule(this);
    }

    void bindAuto(T)(string name, auto ref T value)
    {
        static if (is(T == Value))
            bind(name, value);
        else static if (isAggregateType!T)
            bind(name, Value.reflect(value));
        else
            bind(name, Value.from(value));
    }

    void bindNative(string name, NativeFunction callback)
    {
        bind(name, Value.fromFunction(new NativeCallable(moduleName ~ "." ~ name, callback)));
    }

    void opIndexAssign(T)(auto ref T value, string name)
    {
        bindAuto(name, value);
    }

    Value opIndex(string name)
    {
        return moduleValue[name];
    }

    Value get(string name)
    {
        return environment.get(name);
    }

    Value call(string functionName, scope const(Value)[] args = [])
    {
        return moduleValue.call(functionName, args);
    }

    Value run(string source)
    {
        return run(source, RunOptions.init);
    }

    Value run(string source, RunOptions options)
    {
        auto result = runSafe(source, options);
        enforce(result.ok, result.errorMessage);
        return result.value;
    }

    RunOutcome runSafe(string source)
    {
        return runSafe(source, RunOptions.init);
    }

    RunOutcome runSafe(string source, RunOptions options)
    {
        return engine.runInHostModuleSafe(this, source, new Environment(environment), options);
    }

    void load(string source)
    {
        auto result = loadSafe(source);
        enforce(result.ok, result.errorMessage);
    }

    RunOutcome loadSafe(string source)
    {
        return loadSafe(source, RunOptions.init);
    }

    RunOutcome loadSafe(string source, RunOptions options)
    {
        return engine.runInHostModuleSafe(this, source, environment, options);
    }

    void loadFile(string path)
    {
        auto result = loadFileSafe(path);
        enforce(result.ok, result.errorMessage);
    }

    RunOutcome loadFileSafe(string path)
    {
        return loadFileSafe(path, RunOptions.init);
    }

    RunOutcome loadFileSafe(string path, RunOptions options)
    {
        try
            return loadSafe(engine.readScriptFile(path), options);
        catch (Exception error)
        {
            RunOutcome outcome;
            outcome.ok = false;
            outcome.errorMessage = error.msg;
            outcome.errorKind = RunErrorKind.runtime;
            return outcome;
        }
    }
}

final class ScriptCallable : CallableValue
{
    private ScriptEngine engine;
    private Environment closure;
    private string[] parameters;
    private bool variadic;
    private Statement[] body;
    private string[] parameterTypes;
    private string returnType;

    this(string name, ScriptEngine engine, Environment closure, string[] parameters, bool variadic,
        Statement[] body, string[] parameterTypes = null, string returnType = "")
    {
        super(name);
        this.engine = engine;
        this.closure = closure;
        this.parameters = parameters.dup;
        this.variadic = variadic;
        this.body = body.dup;
        this.parameterTypes = parameterTypes.dup;
        this.returnType = returnType;
    }

    override Value invoke(Value[] args)
    {
        auto requiredCount = variadic && parameters.length > 0 ? parameters.length - 1 : parameters.length;
        if (variadic)
        {
            enforce(args.length >= requiredCount,
                format("Function '%s' expected at least %s arguments but got %s", debugName, requiredCount, args.length));
        }
        else
        {
            enforce(args.length == parameters.length,
                format("Function '%s' expected %s arguments but got %s", debugName, parameters.length, args.length));
        }

        auto environment = new Environment(closure);
        if (engine.hasThisContext())
        {
            environment.define("this", engine.currentThisContext());
        }
        foreach (index, parameter; parameters)
        {
            if (variadic && index + 1 == parameters.length)
            {
                environment.define(parameter, Value.from(args[index .. $].dup));
                break;
            }
            if (index < parameterTypes.length)
            {
                enforce(engine.valueMatchesType(args[index], parameterTypes[index]),
                    format("Function '%s' argument '%s' expected %s but got %s",
                        debugName, parameter, parameterTypes[index], args[index].kind));
            }
            environment.define(parameter, args[index]);
        }

        auto result = engine.executeStatements(body, environment);
        auto returnValue = result.returned ? result.lastValue : Value.nullValue();
        if (returnType.length > 0)
        {
            enforce(engine.valueMatchesType(returnValue, returnType),
                format("Function '%s' expected return type %s but got %s",
                    debugName, returnType, returnValue.kind));
        }
        return returnValue;
    }

    override size_t expectedArity() const
    {
        if (variadic)
        {
            return size_t.max;
        }
        return parameters.length;
    }

    override size_t minimumArity() const
    {
        return variadic && parameters.length > 0 ? parameters.length - 1 : parameters.length;
    }
}

final class ScriptEngine
{
    private final class CoroutineState
    {
        Value entryFunction;
        Fiber fiber;
        Value[] pendingArgs;
        Value[] yieldedValues;
        Value[] returnValues;
        bool started;
        bool dead;
        bool failed;
        string errorMessage;
    }

    private Environment globals;
    private string[] callStack;
    private string[] lastErrorStack;
    private string[string] moduleSources;
    private Value[string] moduleCache;
    private ScriptModule[string] hostModules;
    private Value[string][] moduleExportScopes;
    private string[] moduleSearchPaths;
    private Value[] moduleLoaders;
    private size_t nextCoroutineId = 1;
    private CoroutineState[size_t] coroutines;
    private CoroutineState activeCoroutine;
    private long[] indexLengthStack;
    private Value[] thisContextStack;
    private RunOptions currentRunOptions;
    private size_t executedSteps;

    this()
    {
        globals = new Environment();
        moduleSearchPaths = ["?.dua", "?/init.dua"];
        installStandardLibraries();
        installRequireFunction();
    }

    void bind(string name, Value value)
    {
        globals.define(name, value);
    }

    void bindAuto(T)(string name, auto ref T value)
    {
        static if (is(T == Value))
        {
            bind(name, value);
        }
        else static if (isAggregateType!T)
        {
            bind(name, Value.reflect(value));
        }
        else
        {
            bind(name, Value.from(value));
        }
    }

    void opIndexAssign(T)(auto ref T value, string name)
    {
        bindAuto(name, value);
    }

    Value opIndex(string name)
    {
        return globals.get(name);
    }

    void bindType(T)(string name)
        if (isAggregateType!T)
    {
        Value[] typeChain;
        typeChain ~= Value.from(T.stringof);
        static if (is(T == class))
        {
            static foreach (Base; BaseClassesTuple!T)
            {
                typeChain ~= Value.from(Base.stringof);
            }
        }

        ReflectedCallable[] reflectedConstructors;
        static if (__traits(compiles, __traits(getOverloads, T, "__ctor")))
        {
            static foreach (ctor; __traits(getOverloads, T, "__ctor"))
            {
                static if (__traits(compiles, makeReflectedConstructor!(ctor, T)(name ~ ".new")))
                {
                    reflectedConstructors ~= makeReflectedConstructor!(ctor, T)(name ~ ".new");
                }
            }
        }

        auto constructor = Value.fromFunction(new NativeCallable(name ~ ".new", (scope const(Value)[] args) {
            size_t argOffset = 0;
            if (args.length > 0 && args[0].kind == ValueKind.table)
            {
                if (("new" in args[0].tableValue) !is null)
                {
                    argOffset = 1;
                }
            }
            auto userArgs = args[argOffset .. $];
            ReflectedCallable matchedConstructor;
            foreach (candidate; reflectedConstructors)
            {
                if (candidate.expectedArity() == userArgs.length)
                {
                    enforce(matchedConstructor is null,
                        format("%s.new has multiple constructors taking %s arguments", name, userArgs.length));
                    matchedConstructor = candidate;
                }
            }
            if (matchedConstructor !is null)
            {
                Value[] copiedArgs;
                foreach (arg; userArgs)
                {
                    copiedArgs ~= cast(Value) arg;
                }
                return matchedConstructor.invoke(copiedArgs);
            }

            enforce(userArgs.length <= 1,
                format("%s.new has no constructor taking %s arguments", name, userArgs.length));
            static if (is(T == class))
            {
                static if (__traits(compiles, new T()))
                {
                    auto instance = new T();
                    auto reflected = Value.reflect(instance);
                    if (userArgs.length == 1)
                    {
                        enforce(userArgs[0].kind == ValueKind.table, format("%s.new init argument must be table", name));
                        foreach (key, entry; userArgs[0].tableValue)
                        {
                            auto setterKey = internalFieldSetterPrefix ~ key;
                            if (auto setter = setterKey in reflected.tableValue)
                            {
                                enforce((*setter).kind == ValueKind.function_,
                                    format("%s.new setter '%s' is not callable", name, key));
                                Value[] setterArgs = [cast(Value) entry];
                                (*setter).functionValue.invoke(setterArgs);
                            }
                        }
                    }
                    return reflected;
                }
                else
                {
                    enforce(false, format("%s.new requires constructor arguments", name));
                    assert(0);
                }
            }
            else static if (is(T == struct))
            {
                T instance = T.init;
                if (userArgs.length == 1)
                {
                    enforce(userArgs[0].kind == ValueKind.table, format("%s.new init argument must be table", name));
                    instance = (cast(Value) userArgs[0]).to!T();
                }
                return Value.reflect(instance);
            }
        }));

        Value[string] typeTable;
        typeTable["name"] = Value.from(name);
        typeTable["new"] = constructor;
        typeTable["__typechain"] = Value.from(typeChain);
        static foreach (memberName; __traits(allMembers, T))
        {{
            static if (memberName != "this" && memberName != "__ctor")
            {
                static if (__traits(compiles, __traits(getOverloads, T, memberName)))
                {
                    ReflectedCallable[] staticOverloads;
                    static foreach (overload; __traits(getOverloads, T, memberName))
                    {
                        static if (__traits(compiles,
                            makeStaticReflectedCallable!overload(name ~ "." ~ memberName)))
                        {
                            staticOverloads ~= makeStaticReflectedCallable!overload(
                                name ~ "." ~ memberName);
                        }
                    }
                    if (staticOverloads.length == 1)
                    {
                        typeTable[memberName] = Value.fromFunction(staticOverloads[0]);
                    }
                    else if (staticOverloads.length > 1)
                    {
                        typeTable[memberName] = Value.fromFunction(
                            new OverloadedReflectedCallable(name ~ "." ~ memberName, staticOverloads));
                    }
                }
            }
        }}

        Value[string] meta;
        meta["__index"] = Value.from(typeTable);
        meta["__call"] = constructor;
        typeTable["__meta"] = Value.from(meta);

        bind(name, Value.from(typeTable));
    }

    void bindNative(string name, NativeFunction callback)
    {
        globals.define(name, Value.fromFunction(new NativeCallable(name, callback)));
    }

    void registerModule(string name, string source)
    {
        moduleSources[name] = source;
    }

    /// Creates an empty, independently scoped module that can be populated from D.
    ScriptModule newModule(string name)
    {
        enforce(name.length > 0, "Module name must not be empty");
        enforce((name in hostModules) is null && (name in moduleSources) is null
                && (name in moduleCache) is null,
            format("Module '%s' is already registered", name));
        auto result = new ScriptModule(this, name, new Environment(globals));
        hostModules[name] = result;
        moduleCache[name] = result.moduleValue;
        return result;
    }

    private void updateHostModule(ScriptModule hostModule)
    {
        moduleCache[hostModule.moduleName] = hostModule.moduleValue;
    }

    void clearModuleCache()
    {
        moduleCache = null;
        foreach (name, hostModule; hostModules)
            moduleCache[name] = hostModule.moduleValue;
    }

    /// Loads a registered or discoverable Dua module and returns its exports.
    /// Modules are evaluated in their own file scope and cached by name.
    Value loadModule(string name)
    {
        auto result = loadModuleSafe(name);
        if (result.ok)
        {
            return result.value;
        }

        auto trace = result.stackTrace.length > 0
            ? "\nStack:\n  " ~ result.stackTrace.join("\n  ")
            : "";
        enforce(false, result.errorMessage ~ trace);
        assert(0);
    }

    /// Safe counterpart to loadModule. Module failures are returned as data.
    RunOutcome loadModuleSafe(string name)
    {
        callStack.length = 0;
        lastErrorStack.length = 0;
        currentRunOptions = RunOptions.init;
        executedSteps = 0;
        RunOutcome outcome;
        try
        {
            outcome.value = requireModule(name);
            outcome.ok = true;
            outcome.errorKind = RunErrorKind.none;
        }
        catch (Exception error)
        {
            outcome.ok = false;
            outcome.errorMessage = error.msg;
            outcome.stackTrace = lastErrorStack.length > 0 ? lastErrorStack.dup : callStack.dup;
            outcome.errorKind = RunErrorKind.runtime;
        }
        outcome.stepsExecuted = executedSteps;
        currentRunOptions = RunOptions.init;
        return outcome;
    }

    /// Loads the file at path as a module, rather than as a shared global script.
    /// The path is also the module cache key.
    Value loadModuleFile(string path)
    {
        auto result = loadModuleFileSafe(path);
        if (result.ok)
        {
            return result.value;
        }

        auto trace = result.stackTrace.length > 0
            ? "\nStack:\n  " ~ result.stackTrace.join("\n  ")
            : "";
        enforce(false, result.errorMessage ~ trace);
        assert(0);
    }

    /// Safe counterpart to loadModuleFile. File and module failures are returned as data.
    RunOutcome loadModuleFileSafe(string path)
    {
        try
        {
            auto source = readScriptFile(path);
            moduleSources[path] = source;
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

    Value run(string source)
    {
        auto result = runSafe(source);
        if (result.ok)
        {
            return result.value;
        }

        auto trace = result.stackTrace.length > 0
            ? "\nStack:\n  " ~ result.stackTrace.join("\n  ")
            : "";
        enforce(false, result.errorMessage ~ trace);
        assert(0);
    }

    Value run(string source, RunOptions options)
    {
        auto result = runSafe(source, options);
        if (result.ok)
        {
            return result.value;
        }
        enforce(false, result.errorMessage);
        assert(0);
    }

    Value runFile(string path)
    {
        auto result = runFileSafe(path);
        if (result.ok)
        {
            return result.value;
        }

        auto trace = result.stackTrace.length > 0
            ? "\nStack:\n  " ~ result.stackTrace.join("\n  ")
            : "";
        enforce(false, result.errorMessage ~ trace);
        assert(0);
    }

    Value runFile(string path, RunOptions options)
    {
        auto result = runFileSafe(path, options);
        if (result.ok)
        {
            return result.value;
        }
        enforce(false, result.errorMessage);
        assert(0);
    }

    RunOutcome runSafe(string source)
    {
        return runSafe(source, RunOptions.init);
    }

    RunOutcome runSafe(string source, RunOptions options)
    {
        return runInEnvironmentSafe(source, new Environment(globals), options);
    }

    RunOutcome runFileSafe(string path)
    {
        return runFileSafe(path, RunOptions.init);
    }

    RunOutcome runFileSafe(string path, RunOptions options)
    {
        try
        {
            return runSafe(readScriptFile(path), options);
        }
        catch (Exception error)
        {
            RunOutcome outcome;
            outcome.ok = false;
            outcome.errorMessage = error.msg;
            return outcome;
        }
    }

    void load(string source)
    {
        auto result = loadSafe(source);
        if (result.ok)
        {
            return;
        }

        auto trace = result.stackTrace.length > 0
            ? "\nStack:\n  " ~ result.stackTrace.join("\n  ")
            : "";
        enforce(false, result.errorMessage ~ trace);
    }

    void loadFile(string path)
    {
        auto result = loadFileSafe(path);
        if (result.ok)
        {
            return;
        }

        auto trace = result.stackTrace.length > 0
            ? "\nStack:\n  " ~ result.stackTrace.join("\n  ")
            : "";
        enforce(false, result.errorMessage ~ trace);
    }

    RunOutcome loadSafe(string source)
    {
        return loadSafe(source, RunOptions.init);
    }

    RunOutcome loadSafe(string source, RunOptions options)
    {
        return runInEnvironmentSafe(source, globals, options);
    }

    RunOutcome loadFileSafe(string path)
    {
        return loadFileSafe(path, RunOptions.init);
    }

    RunOutcome loadFileSafe(string path, RunOptions options)
    {
        try
        {
            return loadSafe(readScriptFile(path), options);
        }
        catch (Exception error)
        {
            RunOutcome outcome;
            outcome.ok = false;
            outcome.errorMessage = error.msg;
            return outcome;
        }
    }

    Value getGlobal(string name)
    {
        return globals.get(name);
    }

    CheckDiagnostic[] check(string source)
    {
        CheckDiagnostic[] diagnostics;
        try
        {
            auto program = parse(lex(source));
            string[string] variableTypes;
            StaticFunctionInfo[string] functions;
            checkStatements(program.statements, variableTypes, functions, diagnostics, "");
        }
        catch (Exception error)
        {
            diagnostics ~= CheckDiagnostic(0, 0, error.msg);
        }
        return diagnostics;
    }

    Value call(string functionName, scope const(Value)[] args = [])
    {
        auto callable = getGlobal(functionName);
        Value[] copiedArgs;
        foreach (arg; args)
        {
            copiedArgs ~= cast(Value) arg;
        }
        return invokeFunctionValue(callable, copiedArgs);
    }

    private void checkStatements(Statement[] statements, ref string[string] variables,
        ref StaticFunctionInfo[string] functions, ref CheckDiagnostic[] diagnostics,
        string expectedReturnType)
    {
        foreach (statement; statements)
        {
            if (statement.kind == Statement.Kind.functionDecl)
            {
                functions[statement.name] = StaticFunctionInfo(
                    statement.parameterTypes.dup, statement.returnType);
            }
        }
        foreach (statement; statements)
        {
            final switch (statement.kind)
            {
                case Statement.Kind.variableDecl:
                    foreach (index, name; statement.names)
                    {
                        auto actual = index < statement.expressions.length
                            ? inferExpressionType(statement.expressions[index], variables, functions, diagnostics)
                            : "any";
                        auto declared = statement.declaredType.length > 0
                            ? statement.declaredType : actual;
                        if (statement.declaredType.length > 0 && statement.declaredType != "auto"
                            && !staticTypesCompatible(actual, statement.declaredType))
                            addDiagnostic(diagnostics, statement,
                                format("Variable '%s' expects %s but expression has type %s",
                                    name, statement.declaredType, actual));
                        variables[name] = declared == "auto" ? actual : declared;
                    }
                    break;
                case Statement.Kind.assign:
                    foreach (index, target; statement.targets)
                    {
                        auto actual = index < statement.expressions.length
                            ? inferExpressionType(statement.expressions[index], variables, functions, diagnostics)
                            : "any";
                        if (target.kind == Expression.Kind.variable)
                        {
                            auto expected = target.identifier in variables;
                            if (expected !is null && !staticTypesCompatible(actual, *expected))
                                diagnostics ~= CheckDiagnostic(target.line, target.column,
                                    format("Assignment to '%s' expects %s but expression has type %s",
                                        target.identifier, *expected, actual));
                        }
                    }
                    break;
                case Statement.Kind.return_:
                    auto actual = statement.expressions.length == 0 ? "null"
                        : inferExpressionType(statement.expressions[0], variables, functions, diagnostics);
                    if (expectedReturnType.length > 0)
                    {
                        if (!staticTypesCompatible(actual, expectedReturnType))
                            addDiagnostic(diagnostics, statement,
                                format("Return expects %s but expression has type %s",
                                    expectedReturnType, actual));
                    }
                    break;
                case Statement.Kind.functionDecl:
                    auto childVariables = variables.dup;
                    foreach (index, parameter; statement.parameters)
                        childVariables[parameter] = index < statement.parameterTypes.length
                            ? statement.parameterTypes[index] : "any";
                    checkStatements(statement.body, childVariables, functions, diagnostics,
                        statement.returnType);
                    break;
                case Statement.Kind.block:
                    auto childVariables = variables.dup;
                    checkStatements(statement.body, childVariables, functions, diagnostics, expectedReturnType);
                    break;
                case Statement.Kind.if_, Statement.Kind.while_, Statement.Kind.for_,
                     Statement.Kind.foreach_, Statement.Kind.switch_:
                    if (statement.condition !is null)
                        inferExpressionType(statement.condition, variables, functions, diagnostics);
                    foreach (child; statement.body)
                    {
                        auto nestedVariables = variables.dup;
                        checkStatements([child], nestedVariables, functions, diagnostics, expectedReturnType);
                    }
                    if (statement.elseBranch !is null)
                    {
                        auto nestedVariables = variables.dup;
                        checkStatements([statement.elseBranch], nestedVariables, functions, diagnostics, expectedReturnType);
                    }
                    break;
                case Statement.Kind.try_:
                    auto tryVariables = variables.dup;
                    checkStatements(statement.body, tryVariables, functions, diagnostics, expectedReturnType);
                    auto catchVariables = variables.dup;
                    catchVariables[statement.name] = "table";
                    checkStatements(statement.elseBranch.body, catchVariables, functions, diagnostics, expectedReturnType);
                    break;
                case Statement.Kind.expression:
                    inferExpressionType(statement.expression, variables, functions, diagnostics);
                    break;
                case Statement.Kind.alias_, Statement.Kind.break_, Statement.Kind.continue_,
                     Statement.Kind.yield_, Statement.Kind.import_, Statement.Kind.export_:
                    break;
            }
        }
    }

    private string inferExpressionType(Expression expression, ref string[string] variables,
        ref StaticFunctionInfo[string] functions, ref CheckDiagnostic[] diagnostics)
    {
        if (expression is null) return "any";
        final switch (expression.kind)
        {
            case Expression.Kind.literal:
                final switch (expression.literalValue.kind)
                {
                    case ValueKind.integer: return "int";
                    case ValueKind.floating: return "double";
                    case ValueKind.boolean: return "bool";
                    case ValueKind.string_: return "string";
                    case ValueKind.null_: return "null";
                    case ValueKind.array: return "array";
                    case ValueKind.table: return "table";
                    case ValueKind.function_: return "function";
                    case ValueKind.native: return "any";
                }
            case Expression.Kind.variable:
                auto found = expression.identifier in variables;
                return found is null ? "any" : *found;
            case Expression.Kind.array: return "array";
            case Expression.Kind.table: return "table";
            case Expression.Kind.function_: return "function";
            case Expression.Kind.unary:
                return expression.operatorSymbol == "!" ? "bool"
                    : inferExpressionType(expression.right, variables, functions, diagnostics);
            case Expression.Kind.binary:
                auto left = inferExpressionType(expression.left, variables, functions, diagnostics);
                auto right = expression.operatorSymbol == "is" ? "any"
                    : inferExpressionType(expression.right, variables, functions, diagnostics);
                if (["==", "!=", "<", "<=", ">", ">=", "&&", "||", "is"].canFind(expression.operatorSymbol))
                    return "bool";
                if (expression.operatorSymbol == "~") return "string";
                return left == "int" && right == "int" ? "int" : "double";
            case Expression.Kind.ternary:
                auto middle = inferExpressionType(expression.middle, variables, functions, diagnostics);
                auto right = inferExpressionType(expression.right, variables, functions, diagnostics);
                return middle == right ? middle : "any";
            case Expression.Kind.call:
                if (expression.left.kind == Expression.Kind.variable)
                {
                    auto functionInfo = expression.left.identifier in functions;
                    if (functionInfo !is null)
                    {
                        foreach (index, argument; expression.arguments)
                        {
                            auto actual = inferExpressionType(argument, variables, functions, diagnostics);
                            if (index < functionInfo.parameterTypes.length
                                && !staticTypesCompatible(actual, functionInfo.parameterTypes[index]))
                                diagnostics ~= CheckDiagnostic(argument.line, argument.column,
                                    format("Argument %s to '%s' expects %s but has type %s",
                                        index + 1, expression.left.identifier,
                                        functionInfo.parameterTypes[index], actual));
                        }
                        return functionInfo.returnType.length > 0 ? functionInfo.returnType : "any";
                    }
                }
                return "any";
            case Expression.Kind.get, Expression.Kind.index:
                return "any";
        }
    }

    private bool staticTypesCompatible(string actual, string expected) const
    {
        if (actual == "any" || expected == "any" || expected == "auto") return true;
        if (canFind(expected, " delegate(")) return actual == "function";
        if (!["int", "double", "bool", "string", "null", "void", "array", "table"].canFind(expected))
            return actual == "table" || actual == expected;
        return actual == expected || (expected == "void" && actual == "null");
    }

    private void addDiagnostic(ref CheckDiagnostic[] diagnostics, Statement statement, string message)
    {
        diagnostics ~= CheckDiagnostic(statement.line, statement.column, message);
    }

    private RunOutcome runInEnvironmentSafe(string source, Environment environment, RunOptions options)
    {
        callStack.length = 0;
        lastErrorStack.length = 0;
        currentRunOptions = options;
        executedSteps = 0;
        scope (exit) currentRunOptions = RunOptions.init;
        RunOutcome outcome;
        try
        {
            if (options.typeCheck)
            {
                auto typeDiagnostics = check(source);
                enforce(typeDiagnostics.length == 0,
                    typeDiagnostics.length == 0 ? "" : format("Type check failed at %s:%s: %s",
                        typeDiagnostics[0].line, typeDiagnostics[0].column, typeDiagnostics[0].message));
            }
            auto program = parse(lex(source));
            auto result = executeStatements(program.statements, environment);
            outcome.ok = true;
            outcome.value = result.lastValue;
            outcome.errorKind = RunErrorKind.none;
            outcome.stepsExecuted = executedSteps;
            return outcome;
        }
        catch (Exception error)
        {
            outcome.ok = false;
            outcome.errorMessage = error.msg;
            outcome.stackTrace = lastErrorStack.length > 0 ? lastErrorStack.dup : callStack.dup;
            outcome.errorKind = canFind(error.msg, "[limit:steps]")
                ? RunErrorKind.stepLimit
                : canFind(error.msg, "[limit:call-depth]")
                    ? RunErrorKind.callDepthLimit
                    : RunErrorKind.runtime;
            outcome.stepsExecuted = executedSteps;
            return outcome;
        }
    }

    private RunOutcome runInHostModuleSafe(ScriptModule hostModule, string source,
        Environment environment, RunOptions options)
    {
        moduleExportScopes ~= hostModule.moduleValue.tableValue;
        auto outcome = runInEnvironmentSafe(source, environment, options);
        hostModule.moduleValue.tableValue = moduleExportScopes[$ - 1];
        moduleExportScopes.length -= 1;
        updateHostModule(hostModule);
        return outcome;
    }

    private void consumeStep()
    {
        ++executedSteps;
        auto maximum = currentRunOptions.limits.maxSteps;
        enforce(maximum == 0 || executedSteps <= maximum,
            format("[limit:steps] Execution step limit exceeded (%s)", maximum));
    }

    private void registerTypeAlias(Statement statement)
    {
        auto registryName = "__dua_type_" ~ statement.name;
        enforce(globals.find(registryName) is null,
            format("Type alias '%s' is already defined", statement.name));
        Value[string] definition;
        if (statement.declaredType == "table")
        {
            definition["isTable"] = Value.from(true);
            Value[string] fields;
            Value[] typeChain = [Value.from(statement.name)];
            foreach (baseName; statement.names)
            {
                auto base = globals.find("__dua_type_" ~ baseName);
                enforce(base !is null && base.kind == ValueKind.table
                    && base.tableValue["isTable"].truthy(),
                    format("Base type '%s' must be a previously declared table type", baseName));
                foreach (fieldName, fieldType; base.tableValue["fields"].tableValue)
                {
                    enforce((fieldName in fields) is null,
                        format("Inherited field '%s' conflicts in type '%s'", fieldName, statement.name));
                    fields[fieldName] = fieldType;
                }
                foreach (chainName; base.tableValue["chain"].arrayValue)
                {
                    if (!typeChain.canFind(chainName)) typeChain ~= chainName;
                }
            }
            foreach (index, fieldName; statement.parameters)
            {
                enforce((fieldName in fields) is null,
                    format("Field '%s' conflicts in type '%s'", fieldName, statement.name));
                fields[fieldName] = Value.from(statement.parameterTypes[index]);
            }
            definition["fields"] = Value.from(fields);
            definition["chain"] = Value.from(typeChain);
        }
        else
        {
            definition["isTable"] = Value.from(false);
            Value[] alternatives;
            foreach (name; statement.names) alternatives ~= Value.from(name);
            definition["alternatives"] = Value.from(alternatives);
        }
        globals.define(registryName, Value.from(definition));
    }

    private bool valueMatchesType(Value value, string typeName)
    {
        if (canFind(typeName, " delegate(")) return value.kind == ValueKind.function_;
        switch (typeName)
        {
            case "auto", "any": return true;
            case "int": return value.kind == ValueKind.integer;
            case "double": return value.kind == ValueKind.floating;
            case "bool": return value.kind == ValueKind.boolean;
            case "string": return value.kind == ValueKind.string_;
            case "null", "void": return value.kind == ValueKind.null_;
            default: break;
        }

        auto definition = globals.find("__dua_type_" ~ typeName);
        if (definition is null) return false;
        if (!definition.tableValue["isTable"].truthy())
        {
            foreach (alternative; definition.tableValue["alternatives"].arrayValue)
            {
                if (valueMatchesType(value, alternative.toHostString())) return true;
            }
            return false;
        }
        if (value.kind != ValueKind.table) return false;
        foreach (fieldName, fieldType; definition.tableValue["fields"].tableValue)
        {
            auto field = fieldName in value.tableValue;
            if (field is null || !valueMatchesType(*field, fieldType.toHostString())) return false;
        }
        Value[] chain;
        foreach (chainName; definition.tableValue["chain"].arrayValue) chain ~= chainName;
        value.tableValue["__typechain"] = Value.from(chain);
        return true;
    }

    private bool valueIsType(Value value, string typeName)
    {
        auto definition = globals.find("__dua_type_" ~ typeName);
        if (definition is null) return valueMatchesType(value, typeName);
        if (!definition.tableValue["isTable"].truthy())
        {
            foreach (alternative; definition.tableValue["alternatives"].arrayValue)
                if (valueIsType(value, alternative.toHostString())) return true;
            return false;
        }
        if (value.kind != ValueKind.table) return false;
        auto chain = "__typechain" in value.tableValue;
        if (chain is null || chain.kind != ValueKind.array) return false;
        foreach (entry; chain.arrayValue)
            if (entry.toHostString() == typeName) return true;
        return false;
    }

    private string readScriptFile(string path)
    {
        enforce(path.length > 0, "Script path must not be empty");
        enforce(exists(path), format("Script file not found: %s", path));
        return readText(path);
    }

    ExecutionResult executeStatements(Statement[] statements, Environment environment)
    {
        ExecutionResult result;
        foreach (statement; statements)
        {
            result = executeStatement(statement, environment);
            if (result.returned || result.broke || result.continued)
            {
                return result;
            }
        }
        return result;
    }

    private ExecutionResult executeStatement(Statement statement, Environment environment)
    {
        consumeStep();
        try
        {
            ExecutionResult result;

            final switch (statement.kind)
            {
                case Statement.Kind.variableDecl:
                    auto values = evaluateExpressionList(statement.expressions, environment,
                        statement.names.length > 1);
                    foreach (index, name; statement.names)
                    {
                        auto value = index < values.length ? values[index] : Value.nullValue();
                        if (statement.declaredType.length > 0 && statement.declaredType != "auto")
                        {
                            enforce(valueMatchesType(value, statement.declaredType),
                                format("Variable '%s' expected %s but got %s",
                                    name, statement.declaredType, value.kind));
                        }
                        environment.define(name, value);
                        result.lastValue = value;
                        if (statement.isExported)
                        {
                            exportSymbol(name, value);
                        }
                    }
                    break;
                case Statement.Kind.alias_:
                    registerTypeAlias(statement);
                    result.lastValue = Value.nullValue();
                    break;
                case Statement.Kind.try_:
                    try
                    {
                        result = executeStatements(statement.body, new Environment(environment));
                    }
                    catch (Exception error)
                    {
                        if (canFind(error.msg, "[limit:steps]")
                            || canFind(error.msg, "[limit:call-depth]"))
                        {
                            throw error;
                        }
                        Value original = Value.nullValue();
                        string kind = "RuntimeError";
                        if (auto thrown = cast(ScriptThrownException) error)
                        {
                            original = thrown.thrownValue;
                            kind = "ScriptError";
                        }
                        Value[] frames;
                        auto trace = lastErrorStack.length > 0 ? lastErrorStack : callStack;
                        foreach (frame; trace) frames ~= Value.from(frame);
                        Value[string] errorInfo;
                        errorInfo["kind"] = Value.from(kind);
                        errorInfo["message"] = Value.from(error.msg);
                        errorInfo["value"] = original;
                        errorInfo["stack"] = Value.from(frames);
                        auto catchEnvironment = new Environment(environment);
                        catchEnvironment.define(statement.name, Value.from(errorInfo));
                        result = executeStatements(statement.elseBranch.body, catchEnvironment);
                    }
                    break;
                case Statement.Kind.assign:
                    auto values = evaluateExpressionList(statement.expressions, environment,
                        statement.targets.length > 1);
                    foreach (index, target; statement.targets)
                    {
                        auto value = index < values.length ? values[index] : Value.nullValue();
                        assignTarget(target, value, environment);
                        result.lastValue = value;
                    }
                    break;
                case Statement.Kind.expression:
                    result.lastValue = evaluate(statement.expression, environment);
                    break;
                case Statement.Kind.return_:
                    if (statement.expressions.length == 0)
                    {
                        result.lastValue = Value.nullValue();
                    }
                    else if (statement.expressions.length == 1)
                    {
                        result.lastValue = evaluate(statement.expressions[0], environment);
                    }
                    else
                    {
                        Value[] values;
                        foreach (expression; statement.expressions)
                        {
                            values ~= evaluate(expression, environment);
                        }
                        result.lastValue = Value.from(values);
                    }
                    result.returned = true;
                    break;
                case Statement.Kind.functionDecl:
                    auto callable = Value.fromFunction(new ScriptCallable(statement.name, this, environment,
                        statement.parameters, statement.variadic, statement.body,
                        statement.parameterTypes, statement.returnType));
                    environment.define(statement.name, callable);
                    result.lastValue = callable;
                    if (statement.isExported)
                    {
                        exportSymbol(statement.name, callable);
                    }
                    break;
                case Statement.Kind.import_:
                    auto imported = requireModule(statement.name);
                    environment.define(statement.aliasName, imported);
                    result.lastValue = imported;
                    break;
                case Statement.Kind.export_:
                    exportSymbol(statement.name, environment.get(statement.name));
                    break;
                case Statement.Kind.block:
                    return executeStatements(statement.body, new Environment(environment));
                case Statement.Kind.if_:
                    if (evaluate(statement.condition, environment).truthy())
                    {
                        result = executeStatement(statement.body[0], environment);
                    }
                    else if (statement.elseBranch !is null)
                    {
                        result = executeStatement(statement.elseBranch, environment);
                    }
                    break;
                case Statement.Kind.while_:
                    while (evaluate(statement.condition, environment).truthy())
                    {
                        result = executeStatement(statement.body[0], environment);
                        if (result.returned)
                        {
                            return result;
                        }
                        if (result.broke)
                        {
                            result.broke = false;
                            break;
                        }
                        if (result.continued)
                        {
                            result.continued = false;
                            continue;
                        }
                    }
                    break;
                case Statement.Kind.for_:
                    auto loopEnvironment = new Environment(environment);
                    if (statement.init !is null)
                    {
                        auto initResult = executeStatement(statement.init, loopEnvironment);
                        if (initResult.returned)
                        {
                            return initResult;
                        }
                    }

                    while (statement.condition is null || evaluate(statement.condition, loopEnvironment).truthy())
                    {
                        result = executeStatement(statement.body[0], loopEnvironment);
                        if (result.returned)
                        {
                            return result;
                        }
                        if (result.broke)
                        {
                            result.broke = false;
                            break;
                        }
                        if (statement.incrementStatement !is null)
                        {
                            auto incrementResult = executeStatement(statement.incrementStatement, loopEnvironment);
                            if (incrementResult.returned)
                            {
                                return incrementResult;
                            }
                            result.lastValue = incrementResult.lastValue;
                        }
                        if (result.continued)
                        {
                            result.continued = false;
                            continue;
                        }
                    }
                    break;
                case Statement.Kind.foreach_:
                    auto iterable = evaluate(statement.iterable, environment);
                    if (iterable.kind == ValueKind.array)
                    {
                        foreach (index, item; iterable.arrayValue)
                        {
                            auto itemEnvironment = new Environment(environment);
                            if (statement.iteratorSecondName.length == 0)
                            {
                                itemEnvironment.define(statement.iteratorName, item);
                            }
                            else
                            {
                                itemEnvironment.define(statement.iteratorName, Value.from(cast(long) index));
                                itemEnvironment.define(statement.iteratorSecondName, item);
                            }
                            result = executeStatement(statement.body[0], itemEnvironment);
                            if (result.returned)
                            {
                                return result;
                            }
                            if (result.broke)
                            {
                                result.broke = false;
                                break;
                            }
                            if (result.continued)
                            {
                                result.continued = false;
                                continue;
                            }
                        }
                    }
                    else if (iterable.kind == ValueKind.table)
                    {
                        foreach (key, value; iterable.tableValue)
                        {
                            auto itemEnvironment = new Environment(environment);
                            if (statement.iteratorSecondName.length == 0)
                            {
                                itemEnvironment.define(statement.iteratorName, value);
                            }
                            else
                            {
                                itemEnvironment.define(statement.iteratorName, tableKeyToScriptValue(key));
                                itemEnvironment.define(statement.iteratorSecondName, value);
                            }
                            result = executeStatement(statement.body[0], itemEnvironment);
                            if (result.returned)
                            {
                                return result;
                            }
                            if (result.broke)
                            {
                                result.broke = false;
                                break;
                            }
                            if (result.continued)
                            {
                                result.continued = false;
                                continue;
                            }
                        }
                    }
                    else
                    {
                        enforce(false, "foreach expects array or table");
                    }
                    break;
                case Statement.Kind.switch_:
                    auto target = evaluate(statement.expression, environment);
                    bool matched;
                    foreach (switchCase; statement.switchCases)
                    {
                        if (!switchCase.isDefault && !matched)
                        {
                            matched = valuesEqual(target, evaluate(switchCase.pattern, environment));
                        }
                        else if (switchCase.isDefault && !matched)
                        {
                            matched = true;
                        }

                        if (!matched)
                        {
                            continue;
                        }

                        result = executeStatements(switchCase.body, new Environment(environment));
                        if (result.returned)
                        {
                            return result;
                        }
                        if (result.broke)
                        {
                            result.broke = false;
                            break;
                        }
                        break;
                    }
                    break;
                case Statement.Kind.break_:
                    result.broke = true;
                    break;
                case Statement.Kind.continue_:
                    result.continued = true;
                    break;
                case Statement.Kind.yield_:
                    enforce(activeCoroutine !is null, "yield can only be used inside a running coroutine");
                    if (statement.expressions.length == 0)
                    {
                        activeCoroutine.yieldedValues = [Value.nullValue()];
                    }
                    else
                    {
                        activeCoroutine.yieldedValues = evaluateExpressionList(statement.expressions, environment, true);
                    }
                    Fiber.yield();
                    result.lastValue = activeCoroutine.pendingArgs.length > 0
                        ? activeCoroutine.pendingArgs[0]
                        : Value.nullValue();
                    break;
            }

            return result;
        }
        catch (ScriptThrownException error)
        {
            throw error;
        }
        catch (Exception error)
        {
            auto location = statementLocation(statement);
            throw makeContextualException(error.msg, location, "statement");
        }
    }

    private Value[] evaluateExpressionList(Expression[] expressions, Environment environment,
        bool expandSingleArray = false)
    {
        if (expressions.length == 0)
        {
            return [];
        }

        if (expressions.length == 1)
        {
            auto value = evaluate(expressions[0], environment);
            if (expandSingleArray && value.kind == ValueKind.array)
            {
                return value.arrayValue.dup;
            }
            return [value];
        }

        Value[] values;
        foreach (expression; expressions)
        {
            values ~= evaluate(expression, environment);
        }
        return values;
    }

    private void assignTarget(Expression target, Value value, Environment environment)
    {
        try
        {
            switch (target.kind)
            {
                case Expression.Kind.variable:
                    environment.assign(target.identifier, value);
                    return;
                case Expression.Kind.get:
                    auto container = evaluate(target.left, environment);
                    enforce(container.kind == ValueKind.table,
                        "Property assignment currently supports tables/reflected structs/classes");
                    if (auto property = target.identifier in container.tableValue)
                    {
                        if (property.kind == ValueKind.function_
                            && property.functionValue.expectedArity() == 1)
                        {
                            invokeFunctionValueWithThis(*property, [value], container);
                            return;
                        }
                    }
                    auto setterKey = internalFieldSetterPrefix ~ target.identifier;
                    if (auto setter = setterKey in container.tableValue)
                    {
                        invokeFunctionValue(*setter, [value]);
                        return;
                    }
                    if (!applyTableNewIndex(container, target.identifier, value))
                    {
                        container.tableValue[target.identifier] = value;
                    }
                    return;
                case Expression.Kind.index:
                    auto container = evaluate(target.left, environment);
                    enforce(target.operatorSymbol != "..", "Slice cannot be an assignment target");
                    auto index = evaluate(target.right, environment);
                    if (container.kind == ValueKind.array)
                    {
                        auto position = cast(size_t) index.toInt();
                        enforce(position < container.arrayValue.length, "Array index out of range");
                        container.arrayValue[position] = value;
                        return;
                    }
                    if (container.kind == ValueKind.table)
                    {
                        auto key = index.toHostString();
                        if (!applyTableNewIndex(container, key, value))
                        {
                            container.tableValue[key] = value;
                        }
                        return;
                    }
                    break;
                default:
                    break;
            }

            enforce(false, "Invalid assignment target");
        }
        catch (ScriptThrownException error)
        {
            throw error;
        }
        catch (Exception error)
        {
            auto location = expressionLocation(target);
            throw makeContextualException(error.msg, location, "assignment");
        }
    }

    private Value evaluate(Expression expression, Environment environment)
    {
        consumeStep();
        try
        {
            final switch (expression.kind)
            {
                case Expression.Kind.literal:
                    return expression.literalValue;
                case Expression.Kind.variable:
                    return environment.get(expression.identifier);
                case Expression.Kind.unary:
                    switch (expression.operatorSymbol)
                    {
                        case "$":
                            enforce(indexLengthStack.length > 0, "$ is only available inside index expressions");
                            return Value.from(indexLengthStack[$ - 1]);
                        case "-":
                            auto right = evaluate(expression.right, environment);
                            if (auto overloaded = tryCallUnaryOverload(expression.operatorSymbol, right))
                            {
                                return *overloaded;
                            }
                            return right.kind == ValueKind.integer
                                ? Value.from(-right.integerValue)
                                : Value.from(-right.toFloat());
                        case "!":
                            auto right = evaluate(expression.right, environment);
                            if (auto overloaded = tryCallUnaryOverload(expression.operatorSymbol, right))
                            {
                                return *overloaded;
                            }
                            return Value.from(!right.truthy());
                        default:
                            enforce(false, format("Unsupported unary operator '%s'", expression.operatorSymbol));
                            assert(0);
                    }
                case Expression.Kind.binary:
                    if (expression.operatorSymbol == "is")
                    {
                        return Value.from(valueIsType(
                            evaluate(expression.left, environment), expression.right.identifier));
                    }
                    if (expression.operatorSymbol == "&&")
                    {
                        auto left = evaluate(expression.left, environment);
                        if (!left.truthy())
                        {
                            return Value.from(false);
                        }

                        auto right = evaluate(expression.right, environment);
                        return Value.from(right.truthy());
                    }

                    if (expression.operatorSymbol == "||")
                    {
                        auto left = evaluate(expression.left, environment);
                        if (left.truthy())
                        {
                            return Value.from(true);
                        }

                        auto right = evaluate(expression.right, environment);
                        return Value.from(right.truthy());
                    }

                    return evaluateBinary(expression.operatorSymbol,
                        evaluate(expression.left, environment),
                        evaluate(expression.right, environment));
                case Expression.Kind.ternary:
                    return evaluate(expression.left, environment).truthy()
                        ? evaluate(expression.middle, environment)
                        : evaluate(expression.right, environment);
                case Expression.Kind.call:
                    auto args = expression.arguments.map!(arg => evaluate(arg, environment)).array;
                    return evaluateCall(expression.left, args, environment);
                case Expression.Kind.array:
                    Value[] items;
                    foreach (index, argument; expression.arguments)
                    {
                        auto value = evaluate(argument, environment);
                        if (index < expression.argumentSpreads.length && expression.argumentSpreads[index])
                        {
                            enforce(value.kind == ValueKind.array,
                                "Array spread requires an array value");
                            items ~= value.arrayValue;
                        }
                        else
                        {
                            items ~= value;
                        }
                    }
                    return Value.from(items);
                case Expression.Kind.table:
                    Value[string] entries;
                    foreach (entry; expression.entries)
                    {
                        if (entry.isSpread)
                        {
                            auto spread = evaluate(entry.value, environment);
                            enforce(spread.kind == ValueKind.table,
                                "Table spread requires a table value");
                            foreach (spreadKey, spreadValue; spread.tableValue)
                            {
                                if (spreadKey == "__meta" || spreadKey == "__typechain"
                                    || startsWith(spreadKey, internalFieldGetterPrefix)
                                    || startsWith(spreadKey, internalFieldSetterPrefix))
                                {
                                    continue;
                                }
                                entries[spreadKey] = spreadValue;
                            }
                            continue;
                        }
                        auto key = entry.key;
                        if (entry.isArrayEntry)
                        {
                            key = entry.key;
                        }
                        else if (entry.keyExpression !is null)
                        {
                            key = evaluate(entry.keyExpression, environment).toHostString();
                        }
                        entries[key] = evaluate(entry.value, environment);
                    }
                    return Value.from(entries);
                case Expression.Kind.function_:
                    return Value.fromFunction(new ScriptCallable("anonymous", this, environment,
                        expression.parameters, expression.variadic, expression.body,
                        null, expression.returnType));
                case Expression.Kind.get:
                    auto container = evaluate(expression.left, environment);
                    enforce(container.kind == ValueKind.table,
                        "Property access currently supports tables/reflected structs/classes");
                    auto getterKey = internalFieldGetterPrefix ~ expression.identifier;
                    if (auto getter = getterKey in container.tableValue)
                    {
                        auto refreshed = invokeFunctionValueWithThis(*getter, [], container);
                        auto property = expression.identifier in container.tableValue;
                        if (property is null || property.kind != ValueKind.function_)
                        {
                            container.tableValue[expression.identifier] = refreshed;
                        }
                        return refreshed;
                    }
                    if (auto value = expression.identifier in container.tableValue)
                    {
                        if (value.kind == ValueKind.function_
                            && value.functionValue.expectedArity() == 0)
                        {
                            return invokeFunctionValueWithThis(*value, [], container);
                        }
                        return *value;
                    }
                    Value resolved;
                    if (resolveTableIndex(container, expression.identifier, resolved))
                    {
                        return resolved;
                    }
                    enforce(false, format("Unknown property '%s'", expression.identifier));
                    assert(0);
                case Expression.Kind.index:
                    auto container = evaluate(expression.left, environment);
                    bool pushedLengthContext;
                    if (canMeasureLength(container))
                    {
                        indexLengthStack ~= measuredLength(container);
                        pushedLengthContext = true;
                    }
                    scope (exit)
                    {
                        if (pushedLengthContext)
                        {
                            indexLengthStack.length = indexLengthStack.length - 1;
                        }
                    }
                    if (expression.operatorSymbol == "..")
                    {
                        enforce(container.kind == ValueKind.array, "Slicing currently supports arrays only");
                        auto start = evaluate(expression.middle, environment).toInt();
                        auto finish = evaluate(expression.right, environment).toInt();
                        enforce(start >= 0 && finish >= start, "Invalid slice range");
                        auto lowerBound = cast(size_t) start;
                        auto upperBound = cast(size_t) finish;
                        enforce(upperBound <= container.arrayValue.length, "Slice end out of range");
                        Value[] sliced;
                        if (lowerBound < upperBound)
                        {
                            sliced = container.arrayValue[lowerBound .. upperBound].dup;
                        }
                        return Value.from(sliced);
                    }
                    auto index = evaluate(expression.right, environment);
                    if (container.kind == ValueKind.array)
                    {
                        auto position = cast(size_t) index.toInt();
                        enforce(position < container.arrayValue.length, "Array index out of range");
                        return container.arrayValue[position];
                    }
                    if (container.kind == ValueKind.table)
                    {
                        auto key = index.toHostString();
                        Value resolved;
                        if (resolveTableIndex(container, key, resolved))
                        {
                            return resolved;
                        }
                        return Value.nullValue();
                    }
                    enforce(false, "Indexing currently supports arrays and tables");
                    assert(0);
            }
        }
        catch (ScriptThrownException error)
        {
            throw error;
        }
        catch (Exception error)
        {
            auto location = expressionLocation(expression);
            throw makeContextualException(error.msg, location, "expression");
        }
    }

    private string statementLocation(Statement statement) const
    {
        if (statement.line == 0 || statement.column == 0)
        {
            return "unknown";
        }
        return format("%s:%s", statement.line, statement.column);
    }

    private string expressionLocation(Expression expression) const
    {
        if (expression.line == 0 || expression.column == 0)
        {
            return "unknown";
        }
        return format("%s:%s", expression.line, expression.column);
    }

    private Exception makeContextualException(string message, string location, string context)
    {
        if (startsWith(message, "["))
        {
            return new Exception(message);
        }
        return new Exception(format("[%s @ %s] %s", context, location, message));
    }

    private Value evaluateBinary(string operatorSymbol, Value left, Value right)
    {
        if (auto overloaded = tryCallBinaryOverload(operatorSymbol, left, right))
        {
            return *overloaded;
        }

        switch (operatorSymbol)
        {
            case "~":
                if (left.kind == ValueKind.array && right.kind == ValueKind.array)
                {
                    auto combined = left.arrayValue.dup;
                    combined ~= right.arrayValue;
                    return Value.from(combined);
                }
                return Value.from(stringify(left) ~ stringify(right));
            case "+":
                if (left.kind == ValueKind.integer && right.kind == ValueKind.integer)
                {
                    return Value.from(left.integerValue + right.integerValue);
                }
                return Value.from(left.toFloat() + right.toFloat());
            case "-":
                if (left.kind == ValueKind.integer && right.kind == ValueKind.integer)
                {
                    return Value.from(left.integerValue - right.integerValue);
                }
                return Value.from(left.toFloat() - right.toFloat());
            case "*":
                if (left.kind == ValueKind.integer && right.kind == ValueKind.integer)
                {
                    return Value.from(left.integerValue * right.integerValue);
                }
                return Value.from(left.toFloat() * right.toFloat());
            case "/":
                return Value.from(left.toFloat() / right.toFloat());
            case "%":
                return Value.from(left.toInt() % right.toInt());
            case "&":
                return Value.from(left.toInt() & right.toInt());
            case "|":
                return Value.from(left.toInt() | right.toInt());
            case "^":
                return Value.from(left.toInt() ^ right.toInt());
            case "<<":
                return Value.from(left.toInt() << right.toInt());
            case ">>":
                return Value.from(left.toInt() >> right.toInt());
            case "==":
                if (auto overloadedEq = tryCallEqualityOverload(left, right))
                {
                    return Value.from(overloadedEq.truthy());
                }
                return Value.from(valuesEqual(left, right));
            case "!=":
                if (auto overloadedEq = tryCallEqualityOverload(left, right))
                {
                    return Value.from(!overloadedEq.truthy());
                }
                return Value.from(!valuesEqual(left, right));
            case "<":
                return Value.from(left.toFloat() < right.toFloat());
            case "<=":
                return Value.from(left.toFloat() <= right.toFloat());
            case ">":
                return Value.from(left.toFloat() > right.toFloat());
            case ">=":
                return Value.from(left.toFloat() >= right.toFloat());
            default:
                enforce(false, format("Unsupported binary operator '%s'", operatorSymbol));
                assert(0);
        }
    }

    private Value evaluateCall(Expression calleeExpression, Value[] args, Environment environment)
    {
        if (calleeExpression.kind == Expression.Kind.get)
        {
            auto receiver = evaluate(calleeExpression.left, environment);
            return callMethodOrUfcs(receiver, calleeExpression.identifier, args, environment);
        }

        auto callee = evaluate(calleeExpression, environment);
        if (callee.kind == ValueKind.table)
        {
            Value callValue;
            if (lookupMetamethod(callee, "__call", callValue))
            {
                Value[] bridgedArgs = [callee];
                bridgedArgs ~= args;
                return invokeFunctionValue(callValue, bridgedArgs);
            }
        }
        return invokeFunctionValue(callee, args);
    }

    private Value callMethodOrUfcs(Value receiver, string functionName, Value[] args, Environment environment)
    {
        if (receiver.kind == ValueKind.table)
        {
            if (auto method = functionName in receiver.tableValue)
            {
                enforce(method.kind == ValueKind.function_,
                    format("Property '%s' exists but is not callable", functionName));
                return invokeFunctionValueWithThis(*method, args, receiver);
            }
        }

        if (auto ufcsFunction = resolveUfcs(functionName, environment))
        {
            Value[] ufcsArgs = [receiver];
            ufcsArgs ~= args;
            return invokeFunctionValue(*ufcsFunction, ufcsArgs);
        }

        enforce(false, format("No method or UFCS function named '%s'", functionName));
        assert(0);
    }

    private Value invokeFunctionValueWithThis(Value callable, Value[] args, Value thisValue)
    {
        thisContextStack ~= thisValue;
        scope (exit)
        {
            thisContextStack.length = thisContextStack.length - 1;
        }
        return invokeFunctionValue(callable, args);
    }

    private bool hasThisContext() const
    {
        return thisContextStack.length > 0;
    }

    private Value currentThisContext() const
    {
        assert(thisContextStack.length > 0);
        return cast(Value) thisContextStack[$ - 1];
    }

    private Value* tryCallBinaryOverload(string operatorSymbol, Value left, Value right)
    {
        if (left.kind == ValueKind.table)
        {
            auto slot = "opBinary" ~ operatorSymbol;
            Value functionValue;
            if (lookupMetamethod(left, slot, functionValue))
            {
                return callTableBinaryOverload(functionValue, left, right);
            }
        }
        if (right.kind == ValueKind.table)
        {
            auto slot = "opBinaryRight" ~ operatorSymbol;
            Value functionValue;
            if (lookupMetamethod(right, slot, functionValue))
            {
                return callTableBinaryOverload(functionValue, right, left);
            }
        }
        return null;
    }

    private Value* tryCallUnaryOverload(string operatorSymbol, Value operand)
    {
        if (operand.kind != ValueKind.table)
        {
            return null;
        }

        auto slot = "opUnary" ~ operatorSymbol;
        Value functionValue;
        if (!lookupMetamethod(operand, slot, functionValue))
        {
            return null;
        }

        enforce(functionValue.kind == ValueKind.function_,
            "Table unary operator overload must be a function value");
        auto result = new Value();
        *result = invokeFunctionValue(functionValue, [operand]);
        return result;
    }

    private Value* tryCallEqualityOverload(Value left, Value right)
    {
        if (left.kind == ValueKind.table)
        {
            Value functionValue;
            if (lookupMetamethod(left, "__eq", functionValue))
            {
                return callTableBinaryOverload(functionValue, left, right);
            }
        }
        if (right.kind == ValueKind.table)
        {
            Value functionValue;
            if (lookupMetamethod(right, "__eq", functionValue))
            {
                return callTableBinaryOverload(functionValue, right, left);
            }
        }
        return null;
    }

    private Value* callTableBinaryOverload(Value functionValue, Value selfValue, Value otherValue)
    {
        enforce(functionValue.kind == ValueKind.function_,
            "Table operator overload must be a function value");
        Value[] args = [selfValue, otherValue];
        auto result = new Value();
        *result = invokeFunctionValue(functionValue, args);
        return result;
    }

    private Value invokeFunctionValue(Value callable, Value[] args)
    {
        enforce(callable.kind == ValueKind.function_, "Only functions are callable");
        auto maximumDepth = currentRunOptions.limits.maxCallDepth;
        enforce(maximumDepth == 0 || callStack.length < maximumDepth,
            format("[limit:call-depth] Function call depth limit exceeded (%s)", maximumDepth));
        auto name = callable.functionValue.debugName;
        callStack ~= name;
        scope (exit)
        {
            if (callStack.length > 0)
            {
                callStack.length = callStack.length - 1;
            }
        }
        try
        {
            return callable.functionValue.invoke(args);
        }
        catch (Exception error)
        {
            lastErrorStack = callStack.dup;
            throw error;
        }
    }

    private string stringify(Value value)
    {
        if (value.kind == ValueKind.table)
        {
            Value toStringFunction;
            if (lookupMetamethod(value, "__tostring", toStringFunction))
            {
                auto rendered = invokeFunctionValue(toStringFunction, [value]);
                return rendered.toHostString();
            }
        }
        return value.toHostString();
    }

    private bool canMeasureLength(Value value) const
    {
        return value.kind == ValueKind.array
            || value.kind == ValueKind.table
            || value.kind == ValueKind.string_;
    }

    private long measuredLength(Value value)
    {
        if (value.kind == ValueKind.array)
        {
            return cast(long) value.arrayValue.length;
        }
        if (value.kind == ValueKind.string_)
        {
            return cast(long) value.stringValue.length;
        }
        if (value.kind == ValueKind.table)
        {
            Value lengthMeta;
            if (lookupMetamethod(value, "__length", lengthMeta) || lookupMetamethod(value, "__len", lengthMeta))
            {
                enforce(lengthMeta.kind == ValueKind.function_, "__length/__len must be a function");
                auto measured = invokeFunctionValue(lengthMeta, [value]);
                return measured.toInt();
            }
            return cast(long) value.tableValue.length;
        }
        enforce(false, "length supports arrays, tables, and strings only");
        assert(0);
    }

    private Value measureLengthValue(scope const(Value)[] args)
    {
        enforce(args.length == 1, "length(value) expects one argument");
        return Value.from(measuredLength(cast(Value) args[0]));
    }

    private Value[] extractTypeChain(Value value)
    {
        Value[] chain;
        if (value.kind == ValueKind.table)
        {
            if (auto reflected = "__typechain" in value.tableValue)
            {
                if (reflected.kind == ValueKind.array)
                {
                    foreach (name; reflected.arrayValue)
                    {
                        chain ~= Value.from(name.toHostString());
                    }
                }
            }
        }
        return chain;
    }

    private Value buildTypeInfo(Value value)
    {
        auto chain = extractTypeChain(value);
        Value[string] info;
        info["kind"] = Value.from(value.kind.to!string);
        info["chain"] = Value.from(chain.dup);
        return Value.from(info);
    }

    private Value typeOfValue(scope const(Value)[] args)
    {
        enforce(args.length == 1, "typeof(value) expects one argument");
        return buildTypeInfo(cast(Value) args[0]);
    }

    private Value setMetatableWithType(scope const(Value)[] args)
    {
        enforce(args.length >= 2, "setmetatableWithType(table, meta, ...types) expects at least two arguments");
        enforce(args[0].kind == ValueKind.table, "setmetatableWithType first argument must be table");
        enforce(args[1].kind == ValueKind.table || args[1].kind == ValueKind.null_,
            "setmetatableWithType second argument must be table or null");
        auto table = cast(Value) args[0];
        if (args[1].kind == ValueKind.null_)
        {
            table.tableValue.remove("__meta");
        }
        else
        {
            table.tableValue["__meta"] = cast(Value) args[1];
        }

        if (args.length == 2)
        {
            table.tableValue.remove("__typechain");
            return table;
        }

        Value[] typeChain;
        foreach (typeName; args[2 .. $])
        {
            typeChain ~= Value.from((cast(Value) typeName).toHostString());
        }
        table.tableValue["__typechain"] = Value.from(typeChain);
        return table;
    }

    private Value mapValue(scope const(Value)[] args)
    {
        enforce(args.length == 2, "map(collection, callback) expects two arguments");
        auto collection = cast(Value) args[0];
        auto mapper = cast(Value) args[1];
        enforce(mapper.kind == ValueKind.function_, "map second argument must be function");

        if (collection.kind == ValueKind.array)
        {
            Value[] mapped;
            foreach (index, item; collection.arrayValue)
            {
                mapped ~= invokeCollectionCallback(mapper, item, Value.from(cast(long) index));
            }
            return Value.from(mapped);
        }

        if (collection.kind == ValueKind.table)
        {
            Value[string] mapped;
            foreach (key, item; collection.tableValue)
            {
                mapped[key] = invokeCollectionCallback(mapper, item, tableKeyToScriptValue(key));
            }
            return Value.from(mapped);
        }

        enforce(false, format("map supports arrays and tables only (got %s)", collection.kind));
        assert(0);
    }

    private Value filterValue(scope const(Value)[] args)
    {
        enforce(args.length == 2, "filter(collection, callback) expects two arguments");
        auto collection = cast(Value) args[0];
        auto predicate = cast(Value) args[1];
        enforce(predicate.kind == ValueKind.function_, "filter second argument must be function");

        if (collection.kind == ValueKind.array)
        {
            Value[] filtered;
            foreach (index, item; collection.arrayValue)
            {
                auto keep = invokeCollectionCallback(predicate, item, Value.from(cast(long) index));
                if (keep.truthy())
                {
                    filtered ~= item;
                }
            }
            return Value.from(filtered);
        }

        if (collection.kind == ValueKind.table)
        {
            Value[string] filtered;
            foreach (key, item; collection.tableValue)
            {
                auto keep = invokeCollectionCallback(predicate, item, tableKeyToScriptValue(key));
                if (keep.truthy())
                {
                    filtered[key] = item;
                }
            }
            return Value.from(filtered);
        }

        enforce(false, format("filter supports arrays and tables only (got %s)", collection.kind));
        assert(0);
    }

    private Value invokeCollectionCallback(Value callback, Value value, Value keyOrIndex)
    {
        auto expected = callback.functionValue.expectedArity();
        if (expected == 0)
        {
            return invokeFunctionValue(callback, []);
        }
        if (expected == 1)
        {
            return invokeFunctionValue(callback, [value]);
        }
        if (expected != size_t.max)
        {
            return invokeFunctionValue(callback, [value, keyOrIndex]);
        }

        auto minimum = callback.functionValue.minimumArity();
        if (minimum == 0)
        {
            return invokeFunctionValue(callback, []);
        }
        if (minimum == 1)
        {
            return invokeFunctionValue(callback, [value]);
        }
        return invokeFunctionValue(callback, [value, keyOrIndex]);
    }

    private Value* resolveUfcs(string functionName, Environment environment)
    {
        if (environment.contains(functionName))
        {
            auto functionValue = environment.get(functionName);
            if (functionValue.kind == ValueKind.function_)
            {
                auto resolved = new Value();
                *resolved = functionValue;
                return resolved;
            }
        }
        if (globals.contains(functionName))
        {
            auto functionValue = globals.get(functionName);
            if (functionValue.kind == ValueKind.function_)
            {
                auto resolved = new Value();
                *resolved = functionValue;
                return resolved;
            }
        }
        return null;
    }

    private bool resolveTableIndex(Value container, string key, out Value resolved)
    {
        if (auto direct = key in container.tableValue)
        {
            resolved = *direct;
            return true;
        }

        Value indexMeta;
        if (lookupMetamethod(container, "__index", indexMeta))
        {
            if (indexMeta.kind == ValueKind.function_)
            {
                resolved = invokeFunctionValue(indexMeta, [container, Value.from(key)]);
                return true;
            }
            if (indexMeta.kind == ValueKind.table)
            {
                if (auto fallback = key in indexMeta.tableValue)
                {
                    resolved = *fallback;
                    return true;
                }
            }
        }

        return false;
    }

    private Value tableKeyToScriptValue(string key)
    {
        try
        {
            auto numericKey = key.to!long();
            if (numericKey.to!string == key)
            {
                return Value.from(numericKey);
            }
        }
        catch (Exception)
        {
        }
        return Value.from(key);
    }

    private bool applyTableNewIndex(Value container, string key, Value value)
    {
        if (auto directMeta = "__newindex" in container.tableValue)
        {
            if (directMeta.kind == ValueKind.function_)
            {
                invokeFunctionValue(*directMeta, [container, Value.from(key), value]);
                return true;
            }
            if (directMeta.kind == ValueKind.table)
            {
                directMeta.tableValue[key] = value;
                return true;
            }
        }

        Value newIndexMeta;
        if (lookupMetamethod(container, "__newindex", newIndexMeta))
        {
            if (newIndexMeta.kind == ValueKind.function_)
            {
                invokeFunctionValue(newIndexMeta, [container, Value.from(key), value]);
                return true;
            }
            if (newIndexMeta.kind == ValueKind.table)
            {
                if (auto meta = "__meta" in container.tableValue)
                {
                    if (meta.kind == ValueKind.table)
                    {
                        if (auto nested = "__newindex" in meta.tableValue)
                        {
                            if (nested.kind == ValueKind.table)
                            {
                                nested.tableValue[key] = value;
                                return true;
                            }
                        }
                    }
                }
            }
        }
        return false;
    }

    private bool lookupMetamethod(Value container, string key, out Value method)
    {
        if (auto direct = key in container.tableValue)
        {
            method = *direct;
            return true;
        }

        if (auto meta = "__meta" in container.tableValue)
        {
            if (meta.kind == ValueKind.table)
            {
                if (auto nested = key in meta.tableValue)
                {
                    method = *nested;
                    return true;
                }
            }
        }
        return false;
    }

    private void installRequireFunction()
    {
        bindNative("require", (scope const(Value)[] args) {
            enforce(args.length == 1, "require(name) expects exactly one argument");
            return requireModule(args[0].toHostString());
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
            auto name = args[0].toHostString();
            if (auto cached = name in moduleCache)
            {
                return *cached;
            }
            return Value.nullValue();
        }));
        packageLib["path"] = Value.from(moduleSearchPaths.map!(item => Value.from(item)).array);
        packageLib["loaders"] = Value.from(moduleLoaders.dup);
        globals.define("package", Value.from(packageLib));
    }

    private void syncPackageConfigFromGlobals()
    {
        if (!globals.contains("package"))
        {
            return;
        }
        auto packageValue = globals.get("package");
        if (packageValue.kind != ValueKind.table)
        {
            return;
        }
        if (auto paths = "path" in packageValue.tableValue)
        {
            if (paths.kind == ValueKind.array)
            {
                moduleSearchPaths.length = 0;
                foreach (item; paths.arrayValue)
                {
                    moduleSearchPaths ~= item.toHostString();
                }
            }
        }
    }

    private Value requireModule(string name)
    {
        syncPackageConfigFromGlobals();
        if (auto cached = name in moduleCache)
        {
            return *cached;
        }

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

        auto program = parse(lex(*source));
        auto moduleEnvironment = new Environment(globals);
        Value[string] exportScope;
        moduleExportScopes ~= exportScope;
        scope(failure)
        {
            if (moduleExportScopes.length > 0)
            {
                moduleExportScopes.length -= 1;
            }
        }
        auto result = executeStatements(program.statements, moduleEnvironment);
        auto exports = moduleExportScopes[$ - 1];
        moduleExportScopes.length -= 1;

        auto moduleValue = exports.length > 0 ? Value.from(exports) : result.lastValue;
        moduleCache[name] = moduleValue;
        return moduleValue;
    }

    private void exportSymbol(string name, Value value)
    {
        enforce(moduleExportScopes.length > 0, "export can only be used inside module source");
        moduleExportScopes[$ - 1][name] = value;
    }

    private string resolveModuleSource(string moduleName)
    {
        foreach (loader; moduleLoaders)
        {
            auto loaded = invokeFunctionValue(loader, [Value.from(moduleName)]);
            if (loaded.kind == ValueKind.string_ && loaded.stringValue.length > 0)
            {
                return loaded.stringValue;
            }
        }

        auto normalized = moduleName.replace(".", "/");
        foreach (pattern; moduleSearchPaths)
        {
            auto path = pattern.replace("?", normalized);
            if (exists(path))
            {
                return readText(path);
            }
        }
        return "";
    }

    private Value createCoroutine(Value functionValue)
    {
        enforce(functionValue.kind == ValueKind.function_, "coroutine.create(callback) expects function");
        auto state = new CoroutineState();
        state.entryFunction = functionValue;

        state.fiber = new Fiber({
            activeCoroutine = state;
            scope (exit) activeCoroutine = null;
            try
            {
                auto result = invokeFunctionValue(state.entryFunction, state.pendingArgs.dup);
                state.returnValues = [result];
            }
            catch (Exception error)
            {
                state.failed = true;
                state.errorMessage = error.msg;
            }
            state.dead = true;
        }, 1024 * 1024);

        auto id = nextCoroutineId++;
        coroutines[id] = state;

        Value[string] handle;
        handle["__coid"] = Value.from(cast(long) id);
        return Value.from(handle);
    }

    private CoroutineState requireCoroutineState(Value handle)
    {
        enforce(handle.kind == ValueKind.table, "Coroutine handle must be a table");
        auto idValue = "__coid" in handle.tableValue;
        enforce(idValue !is null, "Invalid coroutine handle");
        auto id = cast(size_t) idValue.toInt();
        auto state = id in coroutines;
        enforce(state !is null, "Unknown coroutine handle");
        return *state;
    }

    private Value resumeCoroutine(Value handle, Value[] args)
    {
        auto state = requireCoroutineState(handle);
        if (state.dead)
        {
            auto message = state.failed && state.errorMessage.length > 0
                ? state.errorMessage
                : "cannot resume dead coroutine";
            return Value.from([Value.from(false), Value.from(message)]);
        }

        state.pendingArgs = args.dup;
        state.yieldedValues.length = 0;
        state.started = true;
        state.fiber.call();

        if (state.failed)
        {
            state.dead = true;
            return Value.from([Value.from(false), Value.from(state.errorMessage)]);
        }

        if (state.dead)
        {
            Value[] done = [Value.from(true)];
            done ~= state.returnValues;
            return Value.from(done);
        }

        Value[] yielded = [Value.from(true)];
        yielded ~= state.yieldedValues;
        return Value.from(yielded);
    }

    private Value coroutineStatus(Value handle)
    {
        auto state = requireCoroutineState(handle);
        if (state.dead)
        {
            return Value.from("dead");
        }
        if (!state.started)
        {
            return Value.from("suspended");
        }
        return Value.from(state.fiber.state == Fiber.State.HOLD ? "suspended" : "running");
    }

    private Value currentCoroutineHandle()
    {
        if (activeCoroutine is null)
        {
            return Value.nullValue();
        }
        foreach (id, state; coroutines)
        {
            if (state is activeCoroutine)
            {
                Value[string] handle;
                handle["__coid"] = Value.from(cast(long) id);
                return Value.from(handle);
            }
        }
        return Value.nullValue();
    }

    private void installStandardLibraries()
    {
        bindNative("error", (scope const(Value)[] args) {
            enforce(args.length >= 1, "error(message) expects at least one argument");
            string message = stringify(cast(Value) args[0]);
            if (args.length > 1)
            {
                message = format("%s (level: %s)", message, (cast(Value) args[1]).toHostString());
            }
            throw new ScriptThrownException(cast(Value) args[0], message);
            assert(0);
            return Value.nullValue();
        });
        bindNative("typeof", (scope const(Value)[] args) {
            return typeOfValue(args);
        });
        bindNative("typeinfo", (scope const(Value)[] args) {
            return typeOfValue(args);
        });
        bindNative("length", (scope const(Value)[] args) {
            return measureLengthValue(args);
        });
        bindNative("len", (scope const(Value)[] args) {
            return measureLengthValue(args);
        });
        bindNative("rawget", (scope const(Value)[] args) {
            enforce(args.length == 2, "rawget(table, key) expects two arguments");
            enforce(args[0].kind == ValueKind.table, "rawget first argument must be table");
            auto key = (cast(Value) args[1]).toHostString();
            if (auto found = key in args[0].tableValue)
            {
                return cast(Value) *found;
            }
            return Value.nullValue();
        });
        bindNative("rawset", (scope const(Value)[] args) {
            enforce(args.length == 3, "rawset(table, key, value) expects three arguments");
            enforce(args[0].kind == ValueKind.table, "rawset first argument must be table");
            auto table = cast(Value) args[0];
            table.tableValue[(cast(Value) args[1]).toHostString()] = cast(Value) args[2];
            return table;
        });
        bindNative("setmetatable", (scope const(Value)[] args) {
            enforce(args.length == 2, "setmetatable(table, meta) expects two arguments");
            enforce(args[0].kind == ValueKind.table, "setmetatable first argument must be table");
            enforce(args[1].kind == ValueKind.table || args[1].kind == ValueKind.null_,
                "setmetatable second argument must be table or null");
            auto table = cast(Value) args[0];
            if (args[1].kind == ValueKind.null_)
            {
                table.tableValue.remove("__meta");
            }
            else
            {
                table.tableValue["__meta"] = cast(Value) args[1];
            }
            return table;
        });
        bindNative("setmetatableWithType", (scope const(Value)[] args) {
            return setMetatableWithType(args);
        });
        bindNative("getmetatable", (scope const(Value)[] args) {
            enforce(args.length == 1, "getmetatable(table) expects one argument");
            enforce(args[0].kind == ValueKind.table, "getmetatable argument must be table");
            if (auto meta = "__meta" in args[0].tableValue)
            {
                return cast(Value) *meta;
            }
            return Value.nullValue();
        });
        bindNative("pcall", (scope const(Value)[] args) {
            enforce(args.length >= 1, "pcall(callback, ...) expects at least one argument");
            enforce(args[0].kind == ValueKind.function_, "pcall first argument must be function");
            try
            {
                Value[] callArgs;
                foreach (arg; args[1 .. $])
                {
                    callArgs ~= cast(Value) arg;
                }
                auto result = invokeFunctionValue(cast(Value) args[0], callArgs);
                return Value.from([Value.from(true), result]);
            }
            catch (Exception error)
            {
                return Value.from([Value.from(false), Value.from(error.msg)]);
            }
        });
        bindNative("xpcall", (scope const(Value)[] args) {
            enforce(args.length >= 2, "xpcall(callback, errHandler, ...) expects at least two arguments");
            enforce(args[0].kind == ValueKind.function_, "xpcall first argument must be function");
            enforce(args[1].kind == ValueKind.function_, "xpcall second argument must be function");
            try
            {
                Value[] callArgs;
                foreach (arg; args[2 .. $])
                {
                    callArgs ~= cast(Value) arg;
                }
                auto result = invokeFunctionValue(cast(Value) args[0], callArgs);
                return Value.from([Value.from(true), result]);
            }
            catch (Exception error)
            {
                auto handled = invokeFunctionValue(cast(Value) args[1], [Value.from(error.msg)]);
                return Value.from([Value.from(false), handled]);
            }
        });
        bindNative("map", (scope const(Value)[] args) {
            return mapValue(args);
        });
        bindNative("filter", (scope const(Value)[] args) {
            return filterValue(args);
        });

        Value[string] coroutineLib;
        coroutineLib["create"] = Value.fromFunction(new NativeCallable("coroutine.create", (scope const(Value)[] args) {
            enforce(args.length == 1, "coroutine.create(callback) expects one argument");
            return createCoroutine(cast(Value) args[0]);
        }));
        coroutineLib["resume"] = Value.fromFunction(new NativeCallable("coroutine.resume", (scope const(Value)[] args) {
            enforce(args.length >= 1, "coroutine.resume(co, ...) expects at least one argument");
            Value[] resumeArgs;
            foreach (arg; args[1 .. $])
            {
                resumeArgs ~= cast(Value) arg;
            }
            return resumeCoroutine(cast(Value) args[0], resumeArgs);
        }));
        coroutineLib["status"] = Value.fromFunction(new NativeCallable("coroutine.status", (scope const(Value)[] args) {
            enforce(args.length == 1, "coroutine.status(co) expects one argument");
            return coroutineStatus(cast(Value) args[0]);
        }));
        coroutineLib["running"] = Value.fromFunction(new NativeCallable("coroutine.running", (scope const(Value)[] args) {
            enforce(args.length == 0, "coroutine.running() takes no arguments");
            return currentCoroutineHandle();
        }));
        coroutineLib["isyieldable"] = Value.fromFunction(new NativeCallable("coroutine.isyieldable", (scope const(Value)[] args) {
            enforce(args.length == 0, "coroutine.isyieldable() takes no arguments");
            return Value.from(activeCoroutine !is null);
        }));
        coroutineLib["wrap"] = Value.fromFunction(new NativeCallable("coroutine.wrap", (scope const(Value)[] args) {
            enforce(args.length == 1, "coroutine.wrap(callback) expects one argument");
            auto handle = createCoroutine(cast(Value) args[0]);
            return Value.fromFunction(new NativeCallable("coroutine.wrapped", (scope const(Value)[] callArgs) {
                Value[] resumeArgs;
                foreach (arg; callArgs)
                {
                    resumeArgs ~= cast(Value) arg;
                }
                auto resumed = resumeCoroutine(handle, resumeArgs);
                enforce(resumed.kind == ValueKind.array && resumed.arrayValue.length >= 1,
                    "coroutine.wrap resume failed");
                if (!resumed.arrayValue[0].truthy())
                {
                    enforce(false, resumed.arrayValue.length > 1
                        ? resumed.arrayValue[1].toHostString()
                        : "coroutine.wrap failure");
                }
                return resumed.arrayValue.length > 1 ? resumed.arrayValue[1] : Value.nullValue();
            }));
        }));
        globals.define("coroutine", Value.from(coroutineLib));

        Value[string] stringLib;
        stringLib["len"] = Value.fromFunction(new NativeCallable("string.len", (scope const(Value)[] args) {
            return measureLengthValue(args);
        }));
        stringLib["upper"] = Value.fromFunction(new NativeCallable("string.upper", (scope const(Value)[] args) {
            enforce(args.length == 1, "string.upper(value) expects one argument");
            return Value.from(args[0].toHostString().toUpper().to!string);
        }));
        stringLib["lower"] = Value.fromFunction(new NativeCallable("string.lower", (scope const(Value)[] args) {
            enforce(args.length == 1, "string.lower(value) expects one argument");
            return Value.from(args[0].toHostString().toLower().to!string);
        }));
        stringLib["trim"] = Value.fromFunction(new NativeCallable("string.trim", (scope const(Value)[] args) {
            import std.string : strip;
            enforce(args.length == 1, "string.trim(value) expects one argument");
            return Value.from(args[0].toHostString().strip());
        }));
        stringLib["contains"] = Value.fromFunction(new NativeCallable("string.contains", (scope const(Value)[] args) {
            enforce(args.length == 2, "string.contains(value, needle) expects two arguments");
            return Value.from(args[0].toHostString().canFind(args[1].toHostString()));
        }));
        stringLib["replace"] = Value.fromFunction(new NativeCallable("string.replace", (scope const(Value)[] args) {
            enforce(args.length == 3, "string.replace(value, from, to) expects three arguments");
            return Value.from(args[0].toHostString().replace(args[1].toHostString(), args[2].toHostString()));
        }));
        globals.define("string", Value.from(stringLib));

        Value[string] mathLib;
        mathLib["abs"] = Value.fromFunction(new NativeCallable("math.abs", (scope const(Value)[] args) {
            enforce(args.length == 1, "math.abs(value) expects one argument");
            auto value = args[0].toFloat();
            return Value.from(value < 0 ? -value : value);
        }));
        mathLib["floor"] = Value.fromFunction(new NativeCallable("math.floor", (scope const(Value)[] args) {
            enforce(args.length == 1, "math.floor(value) expects one argument");
            return Value.from(cast(long) floor(args[0].toFloat()));
        }));
        mathLib["min"] = Value.fromFunction(new NativeCallable("math.min", (scope const(Value)[] args) {
            enforce(args.length >= 1, "math.min(value, ...) expects at least one argument");
            double minimum = args[0].toFloat();
            foreach (arg; args[1 .. $])
            {
                auto candidate = arg.toFloat();
                if (candidate < minimum)
                {
                    minimum = candidate;
                }
            }
            return Value.from(minimum);
        }));
        mathLib["max"] = Value.fromFunction(new NativeCallable("math.max", (scope const(Value)[] args) {
            enforce(args.length >= 1, "math.max(value, ...) expects at least one argument");
            double maximum = args[0].toFloat();
            foreach (arg; args[1 .. $])
            {
                auto candidate = arg.toFloat();
                if (candidate > maximum)
                {
                    maximum = candidate;
                }
            }
            return Value.from(maximum);
        }));
        globals.define("math", Value.from(mathLib));

        Value[string] tableLib;
        tableLib["len"] = Value.fromFunction(new NativeCallable("table.len", (scope const(Value)[] args) {
            return measureLengthValue(args);
        }));
        tableLib["length"] = tableLib["len"];
        tableLib["keys"] = Value.fromFunction(new NativeCallable("table.keys", (scope const(Value)[] args) {
            enforce(args.length == 1, "table.keys(value) expects one argument");
            enforce(args[0].kind == ValueKind.table, "table.keys supports table values only");
            Value[] keys;
            foreach (key; args[0].tableValue.keys)
            {
                keys ~= tableKeyToScriptValue(key);
            }
            return Value.from(keys);
        }));
        tableLib["map"] = Value.fromFunction(new NativeCallable("table.map", (scope const(Value)[] args) {
            return mapValue(args);
        }));
        tableLib["filter"] = Value.fromFunction(new NativeCallable("table.filter", (scope const(Value)[] args) {
            return filterValue(args);
        }));
        globals.define("table", Value.from(tableLib));

        Value[string] ioLib;
        ioLib["exists"] = Value.fromFunction(new NativeCallable("io.exists", (scope const(Value)[] args) {
            enforce(args.length == 1, "io.exists(path) expects one argument");
            return Value.from(exists(args[0].toHostString()));
        }));
        ioLib["readFile"] = Value.fromFunction(new NativeCallable("io.readFile", (scope const(Value)[] args) {
            enforce(args.length == 1, "io.readFile(path) expects one argument");
            auto path = args[0].toHostString();
            enforce(exists(path), format("File not found: %s", path));
            return Value.from(readText(path));
        }));
        globals.define("io", Value.from(ioLib));

        Value[string] osLib;
        osLib["clock"] = Value.fromFunction(new NativeCallable("os.clock", (scope const(Value)[] args) {
            enforce(args.length == 0, "os.clock() takes no arguments");
            return Value.from(Clock.currTime.toUnixTime());
        }));
        osLib["getenv"] = Value.fromFunction(new NativeCallable("os.getenv", (scope const(Value)[] args) {
            import std.process : environment;
            enforce(args.length == 1, "os.getenv(name) expects one argument");
            auto name = args[0].toHostString();
            return Value.from(environment.get(name, ""));
        }));
        globals.define("os", Value.from(osLib));

        Value[string] utf8Lib;
        utf8Lib["len"] = Value.fromFunction(new NativeCallable("utf8.len", (scope const(Value)[] args) {
            enforce(args.length == 1, "utf8.len(value) expects one argument");
            long count = 0;
            foreach (_; byDchar(args[0].toHostString()))
            {
                ++count;
            }
            return Value.from(count);
        }));
        globals.define("utf8", Value.from(utf8Lib));

        Value[string] debugLib;
        debugLib["type"] = Value.fromFunction(new NativeCallable("debug.type", (scope const(Value)[] args) {
            enforce(args.length == 1, "debug.type(value) expects one argument");
            return Value.from(args[0].kind.to!string);
        }));
        debugLib["traceback"] = Value.fromFunction(new NativeCallable("debug.traceback", (scope const(Value)[] args) {
            enforce(args.length == 0, "debug.traceback() takes no arguments");
            return Value.from(callStack.join("\n"));
        }));
        globals.define("debug", Value.from(debugLib));

        Value[string] timeLib;
        timeLib["nowUnix"] = Value.fromFunction(new NativeCallable("time.nowUnix", (scope const(Value)[] args) {
            enforce(args.length == 0, "time.nowUnix() takes no arguments");
            import core.stdc.time : time;
            return Value.from(cast(long) time(null));
        }));
        globals.define("time", Value.from(timeLib));

        Value[string] jsonLib;
        jsonLib["encode"] = Value.fromFunction(new NativeCallable("json.encode", (scope const(Value)[] args) {
            enforce(args.length == 1, "json.encode(value) expects one argument");
            return Value.from(args[0].toScriptLiteral());
        }));
        globals.define("json", Value.from(jsonLib));
        globals.define("_ENV", Value.fromFunction(new NativeCallable("_ENV", (scope const(Value)[] args) {
            enforce(args.length == 1, "_ENV(name) expects one argument");
            return globals.get(args[0].toHostString());
        })));
    }
}

private final class BindTypeEnemy
{
    int hp;
    string role;

    this()
    {
        hp = 10;
        role = "grunt";
    }

    string shout(string suffix)
    {
        return role ~ ":" ~ hp.to!string ~ suffix;
    }
}

private final class BindTypeFeatures
{
    int value;

    this(int value, int scale)
    {
        this.value = value * scale;
    }

    static int combine(int left, int right)
    {
        return left * 10 + right;
    }

    int opBinary(string operator)(int rhs) const
        if (operator == "+")
    {
        return value + rhs;
    }

    int opUnary(string operator)() const
        if (operator == "-")
    {
        return -value;
    }
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto sum = 0;
        for (auto i = 0; i < 6; i = i + 1) {
            if (i == 4) {
                continue;
            }
            sum = sum + i;
        }
        return sum;
    });
    assert(result.toInt() == 11);
}

private struct AliasNumberFixture
{
    int value;
    int opBinary(string op)(int rhs) const if (op == "+") { return value + rhs; }
    int opBinaryRight(string op)(int lhs) const if (op == "+") { return lhs + value; }
    bool opEquals(const AliasNumberFixture rhs) const { return value == rhs.value; }
}

private struct AliasWrapperFixture
{
    AliasNumberFixture number;
    alias number this;
}

private struct AliasMiddleFixture { AliasNumberFixture number; alias number this; }
private struct AliasOuterFixture { AliasMiddleFixture middle; alias middle this; }

private struct AliasOverrideFixture
{
    AliasNumberFixture number;
    alias number this;
    int opBinary(string op)(int rhs) const if (op == "+") { return 1000 + rhs; }
}

private struct AliasGetterFixture
{
    int* current;
    AliasNumberFixture number() const { return AliasNumberFixture(*current); }
    alias number this;
}

private struct AliasGenericNumberFixture
{
    int value;
    auto opBinary(string op, R)(R rhs) const if (op == "+") { return value + rhs; }
}
private struct AliasGenericWrapperFixture
{
    AliasGenericNumberFixture number;
    alias number this;
}

unittest
{
    auto engine = new ScriptEngine();
    engine.bindAuto("wrapped", AliasWrapperFixture(AliasNumberFixture(7)));
    engine.bindAuto("outer", AliasOuterFixture(AliasMiddleFixture(AliasNumberFixture(8))));
    engine.bindAuto("override", AliasOverrideFixture(AliasNumberFixture(9)));
    engine.bindAuto("other", AliasWrapperFixture(AliasNumberFixture(7)));
    engine.bindAuto("different", AliasWrapperFixture(AliasNumberFixture(6)));
    engine.bindAuto("generic", AliasGenericWrapperFixture(AliasGenericNumberFixture(10)));
    assert("opBinary+" in engine["wrapped"].tableValue);
    assert("opBinaryRight+" in engine["wrapped"].tableValue);
    assert("__eq" in engine["wrapped"].tableValue);
    assert("opBinary+" in engine["generic"].tableValue);
    auto result = engine.run(q{
        return [wrapped + 3, 3 + wrapped, outer + 3, override + 3,
            wrapped == other, wrapped != different, generic + 5];
    });
    assert(result.arrayValue[0].toInt() == 10);
    assert(result.arrayValue[1].toInt() == 10);
    assert(result.arrayValue[2].toInt() == 11);
    assert(result.arrayValue[3].toInt() == 1003);
    assert(result.arrayValue[4].truthy());
    assert(result.arrayValue[5].truthy());
    assert(result.arrayValue[6].toInt() == 15);

    int current = 4;
    engine.bindAuto("getter", AliasGetterFixture(&current));
    current = 20;
    assert(engine.run("return getter + 2;").toInt() == 22);
}

unittest
{
    auto engine = new ScriptEngine();
    RunOptions options;
    options.limits.maxSteps = 25;
    auto result = engine.runSafe(q{
        while (true) {
        }
    }, options);
    assert(!result.ok);
    assert(result.errorKind == RunErrorKind.stepLimit);
    assert(result.stepsExecuted == 26);
}

unittest
{
    auto engine = new ScriptEngine();
    RunOptions options;
    options.limits.maxCallDepth = 4;
    auto result = engine.runSafe(q{
        any recurse(any n) {
            return recurse(n + 1);
        }
        return recurse(0);
    }, options);
    assert(!result.ok);
    assert(result.errorKind == RunErrorKind.callDepthLimit);
    assert(result.stackTrace.length > 0);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        int add(int left, int right) {
            return left + right;
        }

        int answer = add(20, 22);
        double ratio = 1.5;
        bool enabled = true;
        string label = "typed";
        auto values = [answer, 8];
        return values[0] + (ratio > 1.0 ? 1 : 0) + (enabled ? 1 : 0) + length(label);
    });
    assert(result.toInt() == 49);
}

unittest
{
    auto engine = new ScriptEngine();
    auto variableError = engine.runSafe(q{
        int value = "wrong";
        return value;
    });
    assert(!variableError.ok);
    assert(variableError.errorMessage.canFind("expected int"));

    auto argumentError = engine.runSafe(q{
        int identity(int value) {
            return value;
        }
        return identity("wrong");
    });
    assert(!argumentError.ok);
    assert(argumentError.errorMessage.canFind("argument 'value' expected int"));
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        int apply(int value, int delegate(int) transform) {
            return transform(value);
        }

        auto doubled = (int value) => value * 2;
        return apply(21, doubled);
    });
    assert(result.toInt() == 42);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto state = { calls = 0 };
        int sideEffect() {
            state.calls = state.calls + 1;
            return 99;
        }
        void invoke(void delegate() callback) {
            callback();
        }

        invoke(() :> sideEffect());
        return state.calls;
    });
    assert(result.toInt() == 1);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        alias BaseObject = {
            string name;
        };
        alias LivingObject = {
            int hp;
        };
        alias Player = {
            ...BaseObject;
            ...LivingObject;
            int level;
        };
        alias GameObject = Player | null;

        Player player = { name = "hero", hp = 100, level = 7, extra = true };
        GameObject selected = player;
        auto legacy = setmetatableWithType(
            { name = "legacy", hp = 5, level = 2 }, null,
            "Player", "BaseObject", "LivingObject");
        Player checked = legacy;
        auto info = typeinfo(selected);
        return selected.hp + selected.level + checked.hp + length(info.chain)
            + (selected is BaseObject ? 10 : 1000);
    });
    assert(result.toInt() == 125);
}

unittest
{
    auto engine = new ScriptEngine();
    auto collision = engine.runSafe(q{
        alias Base = { int value; };
        alias Invalid = { ...Base; double value; };
        return 0;
    });
    assert(!collision.ok);
    assert(collision.errorMessage.canFind("conflicts"));

    auto missingField = engine.runSafe(q{
        alias Player = { string name; int hp; };
        Player player = { name = "hero" };
        return player;
    });
    assert(!missingField.ok);
    assert(missingField.errorMessage.canFind("expected Player"));
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto handled = "";
        try {
            handled = missingValue;
        } catch (err) {
            handled = err.kind ~ ":" ~ (length(err.message) > 0 ? "message" : "empty");
        }
        return handled;
    });
    assert(result.toHostString() == "RuntimeError:message");
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        try {
            error({ kind = "InvalidAmount", message = "boom", code = 7 });
        } catch (err) {
            return err.kind ~ ":" ~ err.value.kind ~ ":" ~ err.value.code;
        }
        return "unreachable";
    });
    assert(result.toHostString() == "ScriptError:InvalidAmount:7");
}

unittest
{
    auto engine = new ScriptEngine();
    RunOptions options;
    options.limits.maxSteps = 20;
    auto result = engine.runSafe(q{
        try {
            while (true) {
            }
        } catch (err) {
            return "budget bypassed";
        }
    }, options);
    assert(!result.ok);
    assert(result.errorKind == RunErrorKind.stepLimit);
}

unittest
{
    auto engine = new ScriptEngine();
    auto diagnostics = engine.check(q{
        int identity(int value) {
            return "wrong";
        }
        int value = "wrong";
        return identity(true);
    });
    assert(diagnostics.length == 3);
    assert(diagnostics[0].line > 0 && diagnostics[0].column > 0);

    RunOptions options;
    options.typeCheck = true;
    auto blocked = engine.runSafe(q{
        int value = "wrong";
        return value;
    }, options);
    assert(!blocked.ok);
    assert(blocked.errorMessage.canFind("Type check failed"));
}

unittest
{
    auto engine = new ScriptEngine();
    auto oldVariable = engine.runSafe("let value = 1; return value;");
    auto oldFunction = engine.runSafe("fn identity(value) { return value; }");
    assert(!oldVariable.ok);
    assert(!oldFunction.ok);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto total = 0;
        foreach (item; [1, 2, 3, 4, 5]) {
            if (item > 3) {
                break;
            }
            total = total + item;
        }

        switch (total) {
            case 6:
                total = total + 10;
                break;
            default:
                total = total + 99;
        }

        return total == 16 ? total : -1;
    });
    assert(result.toInt() == 16);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto indexTotal = 0;
        auto valueTotal = 0;
        foreach (idx, item; [3, 5, 7]) {
            indexTotal = indexTotal + idx;
            valueTotal = valueTotal + item;
        }

        auto seen = 0;
        foreach (key, value; { a = 2, b = 4 }) {
            if (key == "a" || key == "b") {
                seen = seen + value;
            }
        }

        return indexTotal + valueTotal + seen;
    });

    assert(result.toInt() == 24);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto fallback = { hp = 9 };
        auto sink = {};
        auto obj = {
            __index = fallback,
            __newindex = sink,
            __call = (any self, any x) { return self.hp + x; },
            __len = (any self) { return 77; }
        };

        obj.mp = 5;
        auto hp = obj.hp;
        auto mp = obj.__newindex.mp;
        auto callValue = obj(3);
        return hp + mp + callValue + table.len(obj);
    });

    assert(result.toInt() == 103);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto touched = 0;

        any mark() {
            touched = touched + 1;
            return true;
        }

        auto a = false && mark();
        auto b = true || mark();
        auto c = true && mark();
        auto d = false || mark();

        if (!a && b && c && d) {
            return touched;
        }
        return -1;
    });

    assert(result.toInt() == 2);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        any split(any x) {
            return x, x + 1, x + 2;
        }

        auto a, b, c = split(10);
        a, b = split(2);
        return a + b + c;
    });

    assert(result.toInt() == 17);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        any total(any head, any tail...) {
            auto sum = head;
            foreach (item; tail) {
                sum = sum + item;
            }
            return sum;
        }

        return total(1, 2, 3, 4);
    });

    assert(result.toInt() == 10);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        any decorate(any self, any suffix) {
            return { value = self.value ~ suffix };
        }

        auto node = {
            value = "A",
            opBinary~ = (any self, any rhs) {
                return { value = self.value ~ rhs.value };
            }
        };

        auto combined = node ~ { value = "B" };
        auto chained = combined.decorate("C");
        return chained.value;
    });

    assert(result.toHostString() == "ABC");
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto value = {
            amount = 12,
            opUnary- = (any self) {
                return -self.amount;
            }
        };
        return -value;
    });

    assert(result.toInt() == -12);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.runSafe(q{
        any outer() {
            return missing();
        }

        any missing() {
            return undefinedValue;
        }

        return outer();
    });

    assert(!result.ok);
    assert(result.errorMessage.length > 0);
    assert(result.stackTrace.length > 0);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.registerModule("combat", q{
        auto stats = { base = 40 };
        return stats;
    });

    auto result = engine.run(q{
        auto combat = require("combat");
        auto cached = require("combat");
        auto text = string.upper("ok");
        return combat.base + table.len(cached) + math.abs(-1) + string.len(text);
    });

    assert(result.toInt() == 44);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.registerModule("combat.rules", q{
        export auto base = 7;
        export any add(any x) {
            return x + base;
        }
    });

    auto result = engine.run(q{
        import combat.rules as rules;
        return rules.add(5);
    });

    assert(result.toInt() == 12);
}

unittest
{
    auto engine = new ScriptEngine();
    auto gameModule = engine.newModule("game.module");
    auto otherModule = engine.newModule("other.module");
    gameModule.bindAuto("player", 40);
    otherModule.bindAuto("player", 2);
    gameModule.load(q{
        auto privateBonus = 1;
        export int score(int amount) { return player + privateBonus + amount; }
    });

    assert(engine.run(q{
        import game.module as gm;
        import other.module as other;
        return gm.player + other.player + gm.score(1);
    }).toInt() == 84);
    assert(gameModule["player"].toInt() == 40);
    assert(gameModule.call("score", [Value.from(2)]).toInt() == 43);

    auto imported = engine.run("import game.module as gm; return gm;");
    gameModule.bindAuto("late", 7);
    assert(imported["late"].toInt() == 7);

    engine.clearModuleCache();
    assert(engine.loadModule("game.module")["player"].toInt() == 40);
    auto duplicate = false;
    try engine.newModule("game.module");
    catch (Exception) duplicate = true;
    assert(duplicate);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.registerModule("first", q{
        auto privateValue = 10;
        export auto value = privateValue;
        export any add(any amount) { return privateValue + amount; }
    });
    engine.registerModule("second", q{
        auto privateValue = 20;
        export auto value = privateValue;
    });

    auto first = engine.loadModule("first");
    assert(first["value"].toInt() == 10);
    assert(first.call("add", [Value.from(5)]).toInt() == 15);
    assert(engine.loadModule("second").tableValue["value"].toInt() == 20);
    auto missing = engine.loadModuleSafe("missing-module");
    assert(!missing.ok);
}

unittest
{
    immutable modulePath = "__dua_module_file_test.dua";
    scope (exit) if (exists(modulePath)) remove(modulePath);
    write(modulePath, q{
        auto privateValue = 40;
        export auto answer = privateValue + 2;
        export any add(any amount) { return privateValue + amount; }
    });

    auto engine = new ScriptEngine();
    auto moduleValue = engine.loadModuleFile(modulePath);
    assert(moduleValue["answer"].toInt() == 42);
    assert(moduleValue.call("add", [Value.from(2)]).toInt() == 42);
    auto hidden = engine.runSafe("return privateValue;");
    assert(!hidden.ok);

    auto missing = engine.loadModuleFileSafe("__missing_dua_module__.dua");
    assert(!missing.ok);
}

unittest
{
    auto engine = new ScriptEngine();
    auto duplicateVariable = engine.runSafe("auto value = 1; auto value = 2;");
    auto duplicateFunction = engine.runSafe("any value() {} any value() {}");
    assert(!duplicateVariable.ok);
    assert(duplicateVariable.errorMessage.canFind("already defined in this scope"));
    assert(!duplicateFunction.ok);

    // A nested scope may still deliberately shadow its parent.
    assert(engine.run("auto value = 1; { auto value = 2; } return value;").toInt() == 1);
}

unittest
{
    struct Stats
    {
        int hp;
        int mp;

        int total() const
        {
            return hp + mp;
        }

        int withBonus(int bonus) const
        {
            return hp + mp + bonus;
        }
    }

    final class Player
    {
        string name;

        this(string name)
        {
            this.name = name;
        }

        string greet(string suffix)
        {
            return name ~ suffix;
        }
    }

    auto engine = new ScriptEngine();
    auto stats = Stats(12, 8);
    auto player = new Player("mage");

    engine.bind("stats", Value.reflect(stats));
    engine.bind("player", Value.reflect(player));

    auto result = engine.run(q{
        player.name = "archmage";
        return stats.total() + stats.withBonus(5) + string.len(player.greet("!"));
    });

    assert(result.toInt() == 54);
    assert(player.name == "archmage");
    assert(stats.hp == 12);
}

unittest
{
    struct StatsAuto
    {
        int hp;
        int mp;
    }

    final class PlayerAuto
    {
        int level;
    }

    auto engine = new ScriptEngine();
    auto stats = StatsAuto(10, 5);
    auto player = new PlayerAuto();
    player.level = 3;

    engine.bindAuto("base", 7);
    engine.bindAuto("stats", stats);
    engine.bindAuto("player", player);

    auto result = engine.run(q{
        player.level = player.level + 2;
        stats.hp = 99;
        return base + stats.hp + player.level;
    });

    assert(result.toInt() == 111);
    assert(stats.hp == 10);
    assert(player.level == 5);
}

unittest
{
    final class Enemy
    {
        int hp;
    }

    auto engine = new ScriptEngine();
    auto enemy = new Enemy();
    enemy.hp = 40;
    engine["base"] = 2;
    engine["enemy"] = enemy;

    auto result = engine.run(q{
        enemy.hp = enemy.hp + base;
        return enemy.hp;
    });

    assert(result.toInt() == 42);
    assert(engine["base"].toInt() == 2);
    assert(enemy.hp == 42);
}

unittest
{
    struct StatsTemplate
    {
        int hp;
        int mp;
    }

    auto engine = new ScriptEngine();
    engine.bindType!StatsTemplate("StatsTemplate");

    auto result = engine.run(q{
        auto s = StatsTemplate.new({ hp = 11, mp = 7 });
        auto infoS = typeinfo(StatsTemplate);
        return s.hp + s.mp + length(infoS.chain);
    });

    assert(result.toInt() == 19);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.bindType!BindTypeEnemy("BindTypeEnemy");

    auto result = engine.run(q{
        auto enemy = BindTypeEnemy({ hp = 42, role = "boss" });
        auto text = enemy.shout("!");
        auto info = typeinfo(enemy);
        if (text != "boss:42!") {
            return -10;
        }
        if (length(info.chain) < 1) {
            return -20;
        }
        return length(info.chain);
    });

    assert(result.toInt() >= 1);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.bindType!BindTypeFeatures("BindTypeFeatures");
    auto reflectedFeature = Value.reflect(new BindTypeFeatures(1, 1));
    assert("opBinary+" in reflectedFeature.tableValue);
    assert("opUnary-" in reflectedFeature.tableValue);

    auto result = engine.run(q{
        auto feature = BindTypeFeatures(6, 7);
        return BindTypeFeatures.combine(4, 2) + (feature + 8) + (-feature);
    });

    assert(result.toInt() == 50);
}

unittest
{
    struct Stats
    {
        int hp;
        int mp;
    }

    auto engine = new ScriptEngine();
    auto stats = Stats(12, 8);
    engine.bind("stats", Value.reflect(stats));

    auto result = engine.run(q{
        stats.hp = 77;
        return stats.hp;
    });

    assert(result.toInt() == 77);
    assert(stats.hp == 12);
}

unittest
{
    final class Gauge
    {
        private int current;

        void set(int value)
        {
            current = value;
        }

        int read() const
        {
            return current;
        }
    }

    auto engine = new ScriptEngine();
    auto gauge = new Gauge();
    engine.bind("gauge", Value.reflect(gauge));

    auto result = engine.run(q{
        gauge.set = 41;
        gauge.set = gauge.read + 1;
        return gauge.read;
    });

    assert(result.toInt() == 42);
}

unittest
{
    final class Gauge
    {
        private int current;

        int value() const
        {
            return current;
        }

        void value(int next)
        {
            current = next;
        }

        int value(int left, int right) const
        {
            return current + left + right;
        }
    }

    auto engine = new ScriptEngine();
    auto gauge = new Gauge();
    auto reflectedGauge = Value.reflect(gauge);
    assert((internalFieldGetterPrefix ~ "value") in reflectedGauge.tableValue);
    assert((internalFieldSetterPrefix ~ "value") in reflectedGauge.tableValue);
    engine.bind("gauge", reflectedGauge);

    auto result = engine.run(q{
        gauge.value = 39;
        auto readAsProperty = gauge.value;
        auto readAsMethod = gauge.value();
        return readAsProperty + readAsMethod + gauge.value(1, 2);
    });

    assert(result.toInt() == 120);
}

unittest
{
    struct Proxy
    {
        int currentValue;

        int value() const
        {
            return currentValue;
        }

        void value(int next)
        {
            currentValue = next;
        }

        int value(int left, int right) const
        {
            return currentValue + left + right;
        }
    }

    auto engine = new ScriptEngine();
    Proxy proxy = Proxy(7);
    auto reflectedProxy = Value.reflect(proxy);
    engine.bind("proxy", reflectedProxy);

    auto result = engine.run(q{
        proxy.value = 39;
        auto propertyValue = proxy.value;
        auto explicitValue = proxy.value();
        auto overloadedValue = proxy.value(1, 2);
        return [propertyValue, explicitValue, overloadedValue, proxy.value];
    });

    assert(result.arrayValue[0].toInt() == 39);
    assert(result.arrayValue[1].toInt() == 39);
    assert(result.arrayValue[2].toInt() == 42);
    assert(result.arrayValue[3].toInt() == 39);
    assert(reflectedProxy.tableValue["value"].kind == ValueKind.function_);
    assert(proxy.currentValue == 7);
}

unittest
{
    final class Owner
    {
        struct FieldProxy
        {
            Owner owner;

            int x() const
            {
                return owner.currentX;
            }

            void x(int next)
            {
                owner.currentX = next;
            }
        }

        int currentX = 11;

        FieldProxy point()
        {
            return FieldProxy(this);
        }
    }

    auto engine = new ScriptEngine();
    auto owner = new Owner();
    engine.bind("owner", Value.reflect(owner));

    auto result = engine.run(q{
        auto before = owner.point.x;
        owner.point.x = 42;
        auto after = owner.point.x;
        return [before, after, owner.point.x];
    });

    assert(result.arrayValue[0].toInt() == 11);
    assert(result.arrayValue[1].toInt() == 42);
    assert(result.arrayValue[2].toInt() == 42);
    assert(owner.currentX == 42);
}

unittest
{
    auto engine = new ScriptEngine();

    auto result = engine.run(q{
        auto obj = {
            value = 0,
            get = () { return this.value; },
            set = (any v) { this.value = v; }
        };
        obj.set = 5;
        obj.set = obj.get + 2;
        return obj.get + obj.value;
    });

    assert(result.toInt() == 14);
}

unittest
{
    auto engine = new ScriptEngine();

    auto result = engine.run(q{
        auto point = {
            x = 3,
            move = (any delta) {
                this.x = this.x + delta;
                return this.x;
            }
        };
        return point.move(4);
    });

    assert(result.toInt() == 7);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.load(q{
        any add(any a, any b) {
            return a + b;
        }
    });

    auto result = engine.call("add", [Value.from(40), Value.from(2)]);
    assert(result.toInt() == 42);
}

unittest
{
    auto engine = new ScriptEngine();
    immutable scriptPath = "__dua_runtime_file_test.dua";
    scope(exit)
    {
        if (exists(scriptPath))
        {
            remove(scriptPath);
        }
    }

    write(scriptPath, q{
        any add(any a, any b) {
            return a + b;
        }
        return add(10, 32);
    });

    auto runResult = engine.runFile(scriptPath);
    assert(runResult.toInt() == 42);

    write(scriptPath, q{
        any mul(any a, any b) {
            return a * b;
        }
    });
    engine.loadFile(scriptPath);
    assert(engine.call("mul", [Value.from(6), Value.from(7)]).toInt() == 42);
}

unittest
{
    auto engine = new ScriptEngine();
    immutable missingPath = "__dua_missing_file_test.dua";
    if (exists(missingPath))
    {
        remove(missingPath);
    }

    auto runOutcome = engine.runFileSafe(missingPath);
    assert(!runOutcome.ok);
    assert(runOutcome.errorMessage.length > 0);

    auto loadOutcome = engine.loadFileSafe(missingPath);
    assert(!loadOutcome.ok);
    assert(loadOutcome.errorMessage.length > 0);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.load(q{
        any makeCounter(any start) {
            auto value = start;
            return (any step) {
                value = value + step;
                return value;
            };
        }

        auto counter = makeCounter(10);
    });

    auto counter = engine.getGlobal("counter");
    assert(counter.kind == ValueKind.function_);
    auto next = counter.functionValue.invoke([Value.from(5)]);
    assert(next.toInt() == 15);
}

unittest
{
    struct Settings
    {
        int volume;
        bool muted;
    }

    Value[string] table;
    table["volume"] = Value.from(15);
    table["muted"] = Value.from(true);
    auto value = Value.from(table);

    auto settings = value.to!Settings();
    assert(settings.volume == 15);
    assert(settings.muted);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto ok, value = pcall(() { return 9; });
        auto failed, err = pcall(() { return missingValue; });
        auto xok, xval = xpcall(() { return nope; }, (any msg) { return "handled"; });
        if (ok && !failed && !xok) {
            return value + string.len(err) + string.len(xval);
        }
        return -1;
    });

    assert(result.toInt() > 9);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto t = {};
        t = setmetatable(t, { __index = { hp = 30 } });
        return t.hp + table.len(getmetatable(t));
    });
    assert(result.toInt() == 31);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto info = typeof({ hp = 1 });
        if (info.kind != "table") {
            return -10;
        }
        if (length(info.chain) != 0) {
            return -20;
        }
        if (length(info) != 2) {
            return -30;
        }
        return 0;
    });
    assert(result.toInt() == 0);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto obj = {};
        obj = setmetatableWithType(obj, { __index = { hp = 10 } }, "Enemy", "Actor");
        auto info = typeinfo(obj);
        if (obj.hp != 10) {
            return -10;
        }
        if (length(info.chain) != 2) {
            return -20;
        }
        if (info.chain[0] != "Enemy") {
            return -30;
        }
        if (info.chain[1] != "Actor") {
            return -35;
        }
        return length(info.chain);
    });
    assert(result.toInt() == 2);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto v = 10 & 3;
        v = v + (8 >> 1);
        v = v + (1 << 3);
        v = v + (6 ^ 3);
        v = v + (4 | 1);
        return v;
    });
    assert(result.toInt() == 24);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto key = "name";
        auto tbl = { [key] = "mage", 7, 8, fixed = 1 };
        return tbl.name ~ ":" ~ tbl[0] ~ ":" ~ tbl[1] ~ ":" ~ tbl.fixed;
    });
    assert(result.toHostString() == "mage:7:8:1");
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto tbl = { 11, 22, name = "mage" };
        auto foundZero = false;
        foreach (k, v; tbl) {
            if (k == 0 && v == 11) { foundZero = true; }
        }
        return foundZero;
    });
    assert(result.truthy());
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto a, b, c = [1, 2, 3];
        a, b = [b, a];
        return [a, b, c];
    });
    assert(result.arrayValue[0].toInt() == 2);
    assert(result.arrayValue[1].toInt() == 1);
    assert(result.arrayValue[2].toInt() == 3);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto co = coroutine.create((any start) {
            auto current = start;
            yield current;
            current = current + 1;
            yield current;
            return current + 1;
        });

        auto ok1, v1 = coroutine.resume(co, 5);
        auto ok2, v2 = coroutine.resume(co);
        auto ok3, v3 = coroutine.resume(co);
        auto status = coroutine.status(co);

        if (ok1 && ok2 && ok3 && status == "dead") {
            return v1 + v2 + v3;
        }
        return -1;
    });

    assert(result.toInt() == 18);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto text = string.trim("  Dua  ");
        if (!string.contains(text, "ua")) {
            return -1;
        }
        return string.replace(text, "ua", "UA");
    });
    assert(result.toHostString() == "DUA");
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto replaced = string.replace("a-b-c", "-", ":");
        return string.len(replaced) + math.min(6, 2, 9) + math.max(1, 5, 3);
    });
    assert(result.toInt() == 12);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto addOne = (any x) => x + 1;
        auto twice = (any v) => v * 2;
        auto composed = twice(addOne(20));
        auto pair = (any a, any b) => a + b;
        return composed + pair(1, 2);
    });
    assert(result.toInt() == 45);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto box = { v = 0 };
        auto sink = (any x) :> rawset(box, "v", x * 3);
        sink(7);
        return box.v;
    });
    assert(result.toInt() == 21);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto values = { first = 1, second = 2, };
        return values.first + values.second;
    });
    assert(result.toInt() == 3);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto value = 0;
        auto assign = (int next) :> value = next;
        assign(42);
        return value;
    });
    assert(result.toInt() == 42);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        void consume() {
            42;
        }
        auto inferred = () {
            42;
        };
        return consume() == null && inferred() == null;
    });
    assert(result.kind == ValueKind.boolean && result.booleanValue);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto ev0 = filter(map([1, 2, 3, 4, 5], (any x) => x * 2), (any x) => x % 4 == 0)[0];
        auto ev1 = filter(map([1, 2, 3, 4, 5], (any x) => x * 2), (any x) => x % 4 == 0)[1];

        auto stats = { hp = 10, mp = 7, sp = 4 };
        auto boosted = table.map(stats, (any v, any k) => v + 1);
        auto picked = table.filter(boosted, (any v, any k) => v >= 8);

        return ev0 + ev1 + picked.hp + picked.mp + table.len(picked);
    });
    assert(result.toInt() == 33);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        // comment
        /+ outer
            /+ inner +/
        +/
        return length([10, 20, 30, 40][1 .. $]);
    });
    assert(result.toInt() == 3);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto name = "Dua";
        auto level = 7;
        return i"Hello, $(name)! Lv.$(level)";
    });
    assert(result.toHostString() == "Hello, Dua! Lv.7");
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto table = { nested = { value = 3 } };
        return i"$$score=$(1 + 2, table.nested.value)";
    });
    assert(result.toHostString() == "$score=33");
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto nested = { value = 1 };
        auto original = { name = "hero", hp = 100, nested = nested };
        auto copied = { ...original, hp = 75 };
        copied.nested.value = 9;

        auto left = [1, 2];
        auto shared = left;
        shared[0] = 8;
        auto right = [4, 5];
        auto combined = [...left, 3, ...right];
        combined[0] = 1;
        copied.name = "mage";

        return original.name ~ ":" ~ original.hp ~ ":" ~ original.nested.value
            ~ ":" ~ left[0] ~ combined[0] ~ combined[2] ~ combined[4];
    });
    assert(result.toHostString() == "hero:100:9:8135");
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto source = setmetatableWithType({ hp = 10 }, { __index = { mp = 5 } }, "Player");
        auto copied = { ...source };
        auto info = typeinfo(copied);
        return copied.hp + length(info.chain) + (getmetatable(copied) == null ? 1 : 100);
    });
    assert(result.toInt() == 11);
}
