module dua.runtime;

import dua.ast;
public import dua.binding;
import dua.coroutine;
import dua.evaluator;
public import dua.execution;
import dua.lexer : lex;
import dua.module_system : ModuleImplementation;
import dua.parser : parse;
import dua.stdlib.core : StdlibContext, installStandardLibraries;
import dua.typecheck : checkSource;
import dua.value;
import std.algorithm : canFind, map;
import std.array : array;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, readText, remove, write;
import std.format : format;
import std.string : join, replace, startsWith;
import std.traits : BaseClassesTuple, isAggregateType, isNumeric;

private string bindFuncOverload(long value)
{
    return "integer:" ~ value.to!string;
}

private string bindFuncOverload(string value)
{
    return "string:" ~ value;
}

private long bindFuncVariadic(long initial, long[] rest...)
{
    foreach (value; rest)
        initial += value;
    return initial;
}

private final class BindFuncOverloadedClass
{
    string describe(long value) { return "class-integer:" ~ value.to!string; }
    string describe(string value) { return "class-string:" ~ value; }
}

private struct BindFuncOverloadedStruct
{
    string describe(long value) { return "struct-integer:" ~ value.to!string; }
    string describe(string value) { return "struct-string:" ~ value; }
}

private struct BindTypeValueVec2
{
    int x;
    int y;
}

private struct StaticPropertyFixture
{
    private static double stored;
    static double p() { return stored; }
    static void p(long value) { stored = value; }
    static void p(double value) { stored = value + 0.5; }
}

private struct MixedBinaryFixture
{
    double value;
    string opBinary(string op)(MixedBinaryFixture rhs) const
        if (op == "+" || op == "-" || op == "*" || op == "/")
    {
        return "aggregate";
    }
    string opBinary(string op, R)(R rhs) const
        if (!is(R : MixedBinaryFixture) && isNumeric!R && (op == "*" || op == "/"))
    {
        return "scalar";
    }
}

private struct MixedBinaryRightFixture
{
    double value;
    string opBinaryRight(string op)(MixedBinaryRightFixture lhs) const
        if (op == "+" || op == "-" || op == "*" || op == "/")
    {
        return "aggregate-right";
    }
    string opBinaryRight(string op, L)(L lhs) const
        if (!is(L : MixedBinaryRightFixture) && isNumeric!L && (op == "*" || op == "/"))
    {
        return "scalar-right";
    }
}

private struct MixedBinaryAliasFixture
{
    MixedBinaryFixture target;
    alias target this;
}

private struct BindTypeEnumFixture
{
    enum State
    {
        idle = 3,
        running = 7
    }

    enum maxRetries = 5;
}

private final class BindTypeStringEnumFixture
{
    enum Label : string
    {
        primary = "main",
        secondary = "sub"
    }
}

/// A host-created Dua module with an isolated top-level environment.
///
/// This is deliberately a scoped facade over ScriptEngine, not a second
/// interpreter: parsing, execution limits, imports, and export collection all
/// continue through the owning engine's single execution implementation.
private enum ModuleVisibility { global, explicitExports }

/// A thin scope facade owned by a ScriptEngine.
final class ModuleHandle
{
    private ScriptEngine engine;
    private string moduleName;
    private Environment environment;
    private Value moduleValue;
    private ModuleVisibility visibility;
    private bool hostCreated;

    private this(ScriptEngine engine, string name, Environment environment,
        ModuleVisibility visibility, bool hostCreated = false)
    {
        this.engine = engine;
        this.moduleName = name;
        this.environment = environment;
        this.visibility = visibility;
        this.hostCreated = hostCreated;

        moduleValue.kind = ValueKind.table;
        // Touch the property to allocate explicit reference storage even while
        // the export set is empty.
        auto storage = moduleValue.tableValue;
    }

    string name() const
    {
        return moduleName;
    }

    void bind(string name, Value value)
    {
        environment.define(name, value);
        if (visibility == ModuleVisibility.explicitExports)
            moduleValue.tableValue[name] = value.valueCopy();
    }

    mixin AutoBindingAPI;
    mixin FunctionBindingAPI;

    void bindNative(string name, NativeFunction callback)
    {
        bind(name, Value.fromFunction(new NativeCallable(moduleName ~ "." ~ name, callback)));
    }

    Value opIndex(string name)
    {
        return get(name);
    }

    Value get(string name)
    {
        if (visibility == ModuleVisibility.global)
            return environment.get(name);
        auto value = name in moduleValue.tableValue;
        enforce(value !is null, format("Undefined module export '%s'", name));
        return *value;
    }

    Value call(string functionName, scope const(Value)[] args = [])
    {
        return engine.callInModule(this, functionName, args);
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
        return engine.runInModuleSafe(this, source, new Environment(environment), options);
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
        return engine.runInModuleSafe(this, source, environment, options);
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

    Value exportsValue() { return moduleValue; }
}

/// Backwards-compatible name for the former host-only module facade.
alias ScriptModule = ModuleHandle;

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
    private Environment globals;
    mixin ModuleImplementation;
    mixin CoroutineImplementation;
    private EvaluatorContext evaluatorContext;
    private ModuleHandle globalModule_;

    this()
    {
        globals = new Environment();
        globalModule_ = new ModuleHandle(this, "<global>", globals, ModuleVisibility.global);
        moduleSearchPaths = ["?.dua", "?/init.dua"];
        installStandardLibraries(stdlibContext());
        installCoroutineLibrary();
        installRequireFunction();
    }

    private StdlibContext stdlibContext()
    {
        StdlibContext context;
        context.bindNative = (name, callback) => bindNative(name, callback);
        context.bind = (name, value) => globals.define(name, value);
        context.stringify = (value) => stringify(value);
        context.typeOfValue = (args) => typeOfValue(args);
        context.measureLengthValue = (args) => measureLengthValue(args);
        context.iotaValue = (args) => iotaValue(args);
        context.setMetatableWithType = (args) => setMetatableWithType(args);
        context.invokeFunctionValue = (callable, args) => invokeFunctionValue(callable, args);
        context.mapValue = (args) => mapValue(args);
        context.filterValue = (args) => filterValue(args);
        context.tableKeyToScriptValue = (key) => tableKeyToScriptValue(key);
        context.traceback = () => evaluatorContext.callStack.join("\n");
        context.getGlobal = (name) => globals.get(name);
        return context;
    }

    ModuleHandle globalModule() { return globalModule_; }

    void bind(string name, Value value)
    {
        globalModule_.bind(name, value);
    }

    mixin AutoBindingAPI;
    mixin FunctionBindingAPI;

    Value opIndex(string name)
    {
        return globalModule_.get(name);
    }

    void bindType(T)(string name)
        if (isAggregateType!T)
    {
        Value[] typeChain;
        typeChain ~= Value.from(name);
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
                if (candidate.acceptsArity(userArgs.length))
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
                            if (auto setter = reflected.propertySetter(key))
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
                auto reflected = Value.reflect(instance);
                reflected.setTypeChain(typeChain);
                return reflected;
            }
        }));

        Value[string] typeTable;
        Value[string] propertyGetters;
        Value[string] propertySetters;
        typeTable["name"] = Value.from(name);
        typeTable["new"] = constructor;
        static foreach (memberName; __traits(allMembers, T))
        {{
            static if (memberName != "this" && memberName != "__ctor")
            {
                static if (__traits(compiles, is(__traits(getMember, T, memberName) == enum))
                    && is(__traits(getMember, T, memberName) == enum))
                {
                    alias EnumType = __traits(getMember, T, memberName);
                    Value[string] enumTable;
                    static foreach (enumMemberName; __traits(allMembers, EnumType))
                    {
                        static if (__traits(compiles,
                            Value.fromAuto(__traits(getMember, EnumType, enumMemberName))))
                        {
                            enumTable[enumMemberName] = Value.fromAuto(
                                __traits(getMember, EnumType, enumMemberName));
                        }
                    }
                    typeTable[memberName] = Value.from(enumTable);
                }
                else static if (__traits(compiles,
                    Value.fromAuto(__traits(getMember, T, memberName))))
                {
                    typeTable[memberName] = Value.fromAuto(
                        __traits(getMember, T, memberName));
                }
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
                    ReflectedCallable[] staticGetters;
                    ReflectedCallable[] staticSetters;
                    foreach (overload; staticOverloads)
                    {
                        if (overload.acceptsArity(0))
                            staticGetters ~= overload;
                        if (overload.acceptsArity(1))
                            staticSetters ~= overload;
                    }
                    if (staticGetters.length == 1)
                        propertyGetters[memberName] =
                            Value.fromFunction(staticGetters[0]);
                    else if (staticGetters.length > 1)
                        propertyGetters[memberName] = Value.fromFunction(
                            new OverloadedReflectedCallable(name ~ "." ~ memberName ~ ".getter",
                                staticGetters));
                    if (staticSetters.length == 1)
                        propertySetters[memberName] =
                            Value.fromFunction(staticSetters[0]);
                    else if (staticSetters.length > 1)
                        propertySetters[memberName] = Value.fromFunction(
                            new OverloadedReflectedCallable(name ~ "." ~ memberName ~ ".setter",
                                staticSetters));
                }
            }
        }}

        auto typeValue = Value.from(typeTable);
        typeValue.setPropertyMetadata(propertyGetters, propertySetters);
        typeValue.setTypeChain(typeChain);
        Value[string] meta;
        meta["__index"] = typeValue;
        meta["__call"] = constructor;
        typeValue.tableValue["__meta"] = Value.from(meta);

        bind(name, typeValue);
    }

    void bindNative(string name, NativeFunction callback)
    {
        globalModule_.bindNative(name, callback);
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
        return globalModule_.runSafe(source, options);
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
        return globalModule_.loadSafe(source, options);
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
        return checkSource(source);
    }

    Value call(string functionName, scope const(Value)[] args = [])
    {
        return globalModule_.call(functionName, args);
    }

    private Value callInModule(ModuleHandle handle, string functionName, scope const(Value)[] args)
    {
        auto callable = handle.get(functionName);
        Value[] copiedArgs;
        foreach (arg; args)
        {
            copiedArgs ~= cast(Value) arg;
        }
        return invokeFunctionValue(callable, copiedArgs);
    }

    private RunOutcome runInEnvironmentSafe(string source, Environment environment, RunOptions options)
    {
        evaluatorContext.callStack.length = 0;
        evaluatorContext.lastErrorStack.length = 0;
        evaluatorContext.currentRunOptions = options;
        evaluatorContext.executedSteps = 0;
        scope (exit) evaluatorContext.currentRunOptions = RunOptions.init;
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
            outcome.stepsExecuted = evaluatorContext.executedSteps;
            return outcome;
        }
        catch (Exception error)
        {
            outcome.ok = false;
            outcome.errorMessage = error.msg;
            outcome.stackTrace = evaluatorContext.lastErrorStack.length > 0 ? evaluatorContext.lastErrorStack.dup : evaluatorContext.callStack.dup;
            outcome.errorKind = cast(StepLimitException) error !is null
                ? RunErrorKind.stepLimit
                : cast(CallDepthLimitException) error !is null
                    ? RunErrorKind.callDepthLimit : RunErrorKind.runtime;
            outcome.stepsExecuted = evaluatorContext.executedSteps;
            return outcome;
        }
    }

    private void consumeStep()
    {
        ++evaluatorContext.executedSteps;
        auto maximum = evaluatorContext.currentRunOptions.limits.maxSteps;
        if (maximum != 0 && evaluatorContext.executedSteps > maximum)
            throw new StepLimitException(maximum);
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

    private void registerStructType(Statement statement)
    {
        enforce(!globals.contains("__dua_type_" ~ statement.name),
            format("Type '%s' is already defined", statement.name));
        Value[string] fields;
        foreach (index, fieldName; statement.parameters)
            fields[fieldName] = Value.from(statement.parameterTypes[index]);
        Value[] chain = [Value.from(statement.name)];
        Value[string] definition;
        definition["isTable"] = Value.from(true);
        definition["isStruct"] = Value.from(true);
        definition["fields"] = Value.from(fields);
        definition["chain"] = Value.from(chain);
        globals.define("__dua_type_" ~ statement.name, Value.from(definition));

        auto typeName = statement.name;
        auto names = statement.parameters.dup;
        auto types = statement.parameterTypes.dup;
        auto constructor = Value.fromFunction(new NativeCallable(typeName, (scope const(Value)[] args) {
            enforce(args.length == names.length || (args.length == 1 && args[0].kind == ValueKind.table),
                format("%s expects %s field arguments or one initializer table", typeName, names.length));
            Value[string] entries;
            if (args.length == 1 && args[0].kind == ValueKind.table)
            {
                foreach (index, fieldName; names)
                {
                    auto field = fieldName in args[0].tableValue;
                    enforce(field !is null, format("%s initializer is missing '%s'", typeName, fieldName));
                    enforce(valueMatchesType(cast(Value) *field, types[index]), format("%s.%s expected %s", typeName, fieldName, types[index]));
                    entries[fieldName] = field.valueCopy();
                }
            }
            else foreach (index, fieldName; names)
            {
                enforce(valueMatchesType(cast(Value) args[index], types[index]), format("%s.%s expected %s", typeName, fieldName, types[index]));
                entries[fieldName] = args[index].valueCopy();
            }
            auto result = Value.fromStruct(entries);
            result.setTypeChain(chain);
            return result;
        }));
        globals.define(typeName, constructor);
    }

    private bool valueMatchesType(Value value, string typeName)
    {
        if (canFind(typeName, " delegate(")) return value.kind == ValueKind.function_;
        if (value.isFieldAggregate)
        {
            foreach (entry; value.typeChain)
                if (entry.toHostString() == typeName) return true;
            foreach (entry; value.aliasThisChain)
                if (entry.toHostString() == typeName) return true;
        }
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
        if (definition is null)
        {
            if (value.isFieldAggregate)
            {
                // Nominal and alias-this metadata were checked above.
            }
            return false;
        }
        if (!definition.tableValue["isTable"].truthy())
        {
            foreach (alternative; definition.tableValue["alternatives"].arrayValue)
            {
                if (valueMatchesType(value, alternative.toHostString())) return true;
            }
            return false;
        }
        if (!value.isFieldAggregate) return false;
        foreach (fieldName, fieldType; definition.tableValue["fields"].tableValue)
        {
            auto field = fieldName in value.tableValue;
            if (field is null || !valueMatchesType(*field, fieldType.toHostString())) return false;
        }
        Value[] chain;
        foreach (chainName; definition.tableValue["chain"].arrayValue) chain ~= chainName;
        value.setTypeChain(chain);
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
        if (!value.isFieldAggregate) return false;
        foreach (entry; value.typeChain)
            if (entry.toHostString() == typeName) return true;
        foreach (entry; value.aliasThisChain)
            if (entry.toHostString() == typeName) return true;
        return false;
    }

    private string readScriptFile(string path)
    {
        enforce(path.length > 0, "Script path must not be empty");
        enforce(exists(path), format("Script file not found: %s", path));
        return readText(path);
    }

    mixin EvaluatorImplementation;

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
    auto aliases = engine.run(q{
        alias Health = int;
        alias MaybeHealth = Health | null;
        Health hp = 10;
        MaybeHealth maybe = hp;
        return maybe;
    });
    assert(aliases.toInt() == 10);

    auto removedSyntax = engine.runSafe(q{
        alias Old = { int value; };
        return 0;
    });
    assert(!removedSyntax.ok);

    auto result = engine.run(q{
        struct Vec2 { int x; int y; }
        Vec2 original = Vec2(2, 3);
        Vec2 assigned = original;
        assigned.x = 9;
        auto boxed = [original];
        boxed[0].y = 8;
        int touch(Vec2 value) { value.x = 99; return value.x; }
        auto touched = touch(original);
        Vec2 make() { Vec2 v = Vec2({ x = 4, y = 5 }); return v; }
        auto made = make();
        return original.x == 2 && original.y == 3 && assigned.x == 9
            && boxed[0].y == 8 && touched == 99 && made == Vec2(4, 5)
            && original is Vec2 && typeinfo(original).kind == "struct_";
    });
    assert(result.kind == ValueKind.boolean && result.booleanValue);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.bindType!BindTypeValueVec2("Vec2");
    auto result = engine.run(q{
        Vec2 v = Vec2({ x = 1, y = 2 });
        Vec2 copied = v;
        copied.x = 7;
        return v.x == 1 && copied.x == 7 && v is Vec2
            && typeinfo(v).kind == "struct_";
    });
    assert(result.truthy());
}

unittest
{
    StaticPropertyFixture.stored = 3;
    auto engine = new ScriptEngine();
    engine.bindType!StaticPropertyFixture("StaticProperty");
    auto result = engine.run(q{
        auto initial = StaticProperty.p;
        StaticProperty.p = 7;
        auto integerSet = StaticProperty.p;
        StaticProperty.p(2.0);
        auto explicitSet = StaticProperty.p();
        return [initial, integerSet, explicitSet];
    });
    assert(result.arrayValue[0].toFloat() == 3);
    assert(result.arrayValue[1].toFloat() == 7);
    assert(result.arrayValue[2].toFloat() == 2.5);

    auto failed = engine.runSafe(`StaticProperty.p = "invalid";`);
    assert(!failed.ok);
    // A failed property assignment must leave the callable in the type table.
    assert(engine.run(`return StaticProperty.p();`).toFloat() == 2.5);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.bindAuto("vector", MixedBinaryFixture(2));
    engine.bindAuto("otherVector", MixedBinaryFixture(3));
    engine.bindAuto("rightVector", MixedBinaryRightFixture(4));
    engine.bindAuto("otherRightVector", MixedBinaryRightFixture(5));
    engine.bindAuto("aliased", MixedBinaryAliasFixture(MixedBinaryFixture(6)));
    engine.bindAuto("otherAliased", MixedBinaryAliasFixture(MixedBinaryFixture(7)));
    auto result = engine.run(q{
        return [vector - otherVector, vector / 5.0, vector * 2,
            otherRightVector - rightVector, 5.0 / rightVector, 2 * rightVector,
            aliased - otherAliased, aliased / 5.0, aliased * 2];
    });
    assert(result.toScriptLiteral() ==
        `["aggregate", "scalar", "scalar", "aggregate-right", "scalar-right", "scalar-right", "aggregate", "scalar", "scalar"]`);

    auto mismatch = engine.runSafe(`return vector / "nope";`);
    assert(!mismatch.ok);
    assert(mismatch.errorMessage.canFind("no overload matching RHS kind"));
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run("return [iota(10), iota(5, 9), iota(3, 3), iota(1, 8, 3), iota(5, -2, -2)];");
    assert(result.arrayValue[0].toScriptLiteral() == "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]");
    assert(result.arrayValue[1].toScriptLiteral() == "[5, 6, 7, 8]");
    assert(result.arrayValue[2].arrayValue.length == 0);
    assert(result.arrayValue[3].toScriptLiteral() == "[1, 4, 7]");
    assert(result.arrayValue[4].toScriptLiteral() == "[5, 3, 1, -1]");

    auto invalidBounds = engine.runSafe("return iota(1.5);");
    assert(!invalidBounds.ok);
    assert(invalidBounds.errorMessage.canFind("iota bounds must be integers"));

    auto zeroStep = engine.runSafe("return iota(1, 5, 0);");
    assert(!zeroStep.ok);
    assert(zeroStep.errorMessage.canFind("iota step must not be zero"));
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

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        auto typed = setmetatableWithType({ hp = 10 }, null, "Player", "Actor");
        auto spread = { ...typed };
        typed.__typechain = ["Fake"];
        typed.__dua_alias_this_targets = [123];
        typed.__dua_alias_this_chain = ["FakeAlias"];
        auto userSpread = { ...typed };
        auto before = typeinfo(typed);
        auto wasPlayer = typed is Player;
        auto wasFake = typed is Fake;
        auto cleared = setmetatableWithType(typed, null);
        auto after = typeinfo(cleared);
        return [
            length(before.chain), before.chain[0], wasPlayer, wasFake,
            length(after.chain), cleared is Player,
            length(table.keys(spread)) == 1,
            userSpread.__typechain[0], userSpread.__dua_alias_this_chain[0]
        ];
    });
    assert(result.arrayValue[0].toInt() == 2);
    assert(result.arrayValue[1].toHostString() == "Player");
    assert(result.arrayValue[2].truthy());
    assert(!result.arrayValue[3].truthy());
    assert(result.arrayValue[4].toInt() == 0);
    assert(!result.arrayValue[5].truthy());
    assert(result.arrayValue[6].truthy());
    assert(result.arrayValue[7].toHostString() == "Fake");
    assert(result.arrayValue[8].toHostString() == "FakeAlias");
}

unittest
{
    auto engine = new ScriptEngine();
    engine.bindFunc!bindFuncOverload("describe");
    engine.bindFunc!bindFuncVariadic("sumAll");
    engine.bindFunc!((long value) => value + 1)("plusOne");
    long offset = 2;
    engine.bindFunc("addOffset", (long value) => value + offset);
    engine.bindAuto("classValue", new BindFuncOverloadedClass());
    engine.bindAuto("structValue", BindFuncOverloadedStruct());

    auto result = engine.run(q{
        return [
            describe(42),
            describe("dua"),
            plusOne(41),
            addOffset(40),
            sumAll(10, 20, 12),
            classValue.describe(7),
            classValue.describe("member"),
            structValue.describe(8),
            structValue.describe("member")
        ];
    });

    assert(result.arrayValue[0].toHostString() == "integer:42");
    assert(result.arrayValue[1].toHostString() == "string:dua");
    assert(result.arrayValue[2].toInt() == 42);
    assert(result.arrayValue[3].toInt() == 42);
    assert(result.arrayValue[4].toInt() == 42);
    assert(result.arrayValue[5].toHostString() == "class-integer:7");
    assert(result.arrayValue[6].toHostString() == "class-string:member");
    assert(result.arrayValue[7].toHostString() == "struct-integer:8");
    assert(result.arrayValue[8].toHostString() == "struct-string:member");
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

private struct CallableAliasTargetFixture
{
    double value;
}

private struct CallableAliasWrapperFixture
{
    CallableAliasTargetFixture stored;

    CallableAliasTargetFixture raw() const { return stored; }
    alias raw this;

    // These deliberately shadow CallableAliasTargetFixture.value in the
    // reflected table, just like a property getter/setter on a proxy type.
    double value() const { return stored.value; }
    void value(double newValue) { stored.value = newValue; }
}

private double callableAliasRotationFixture(CallableAliasTargetFixture angle)
{
    return angle.value;
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
    engine.bindAuto("proxy", CallableAliasWrapperFixture(CallableAliasTargetFixture(42.5)));
    engine.bindFunc!callableAliasRotationFixture("rot");

    assert(engine["proxy"].tableValue["value"].kind == ValueKind.function_);
    assert(engine.run("return rot(proxy);").toFloat() == 42.5);
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
    // Limit-like user diagnostics must not be mistaken for interpreter limits.
    Value fakeLimit(scope const(Value)[] args)
    {
        throw new Exception("[limit:steps] application message");
    }
    auto engine = new ScriptEngine();
    engine.bind("fakeLimit", Value.fromFunction(new NativeCallable("fakeLimit", &fakeLimit)));
    auto result = engine.runSafe("return fakeLimit();");
    assert(!result.ok);
    assert(result.errorKind == RunErrorKind.runtime);
}

unittest
{
    import std.json : parseJSON;

    auto engine = new ScriptEngine();
    Value[string] payload;
    payload["text"] = Value.from("line\n\"quoted\"");
    payload["ok"] = Value.from(true);
    engine.bind("payload", Value.from(payload));
    auto encoded = engine.run("return json.encode(payload);");
    auto decoded = parseJSON(encoded.toHostString());
    assert(decoded["text"].str == "line\n\"quoted\"");
    assert(decoded["ok"].boolean);
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
        table BaseObject {
            string name;
        };
        table LivingObject {
            int hp;
        };
        table Player {
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
        table Base { int value; }
        table Invalid { ...Base; double value; }
        return 0;
    });
    assert(!collision.ok);
    assert(collision.errorMessage.canFind("conflicts"));

    auto missingField = engine.runSafe(q{
        table Player { string name; int hp; };
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
    gameModule.bindFunc!bindFuncOverload("describe");
    gameModule.bindFunc!bindFuncVariadic("sumAll");
    gameModule.bindFunc!((long value) => value * 2)("twice");
    long offset = 3;
    gameModule.bindFunc("withOffset", (long value) => value + offset);
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
    assert(gameModule.call("describe", [Value.from("host")]).toHostString() == "string:host");
    assert(gameModule.call("sumAll", [Value.from(1), Value.from(2), Value.from(3)]).toInt() == 6);
    assert(gameModule.call("twice", [Value.from(4)]).toInt() == 8);
    assert(gameModule.call("withOffset", [Value.from(4)]).toInt() == 7);

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
    engine.globalModule.bindAuto("base", 40);
    engine.bindAuto("offset", 2);
    engine.load("any answer() { return base + offset; }");
    assert(engine.call("answer").toInt() == 42);
    assert(engine["base"].toInt() == 40);
    assert(engine.globalModule["offset"].toInt() == 2);

    auto moduleHandle = engine.newModule("identity");
    assert(engine.loadModule("identity") is moduleHandle);

    // A host callback re-enters through ModuleHandle.call. The resulting
    // recursion must still use the engine's active depth accounting.
    moduleHandle.bindNative("enter", (scope const(Value)[] args) {
        return moduleHandle.call("loop");
    });
    moduleHandle.load("export any loop() { return enter(); }");
    RunOptions options;
    options.limits.maxCallDepth = 3;
    auto limited = moduleHandle.runSafe("return enter();", options);
    assert(!limited.ok);
    assert(limited.errorKind == RunErrorKind.callDepthLimit);
    assert(limited.stackTrace.length > 0);

    auto privateLookup = false;
    moduleHandle.load("auto secret = 7; export any reveal() { return secret; }");
    try moduleHandle.get("secret");
    catch (Exception) privateLookup = true;
    assert(privateLookup);
    assert(moduleHandle.call("reveal").toInt() == 7);
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
    assert(engine.loadModule("second")["value"].toInt() == 20);
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
    engine.bindType!BindTypeEnumFixture("Job");
    engine.bindType!BindTypeStringEnumFixture("Labels");

    auto result = engine.run(q{
        if (Job.State.idle != 3 || Job.State.running != 7) return -1;
        if (Job.maxRetries != 5) return -2;
        if (Labels.Label.primary != "main") return -3;
        return Job.State.running + Job.maxRetries;
    });

    assert(result.toInt() == 12);
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
    struct DefaultMethod
    {
        int value(int increment = 5)
        {
            return 10 + increment;
        }
    }

    auto engine = new ScriptEngine();
    engine.bind("item", Value.reflect(DefaultMethod()));
    auto result = engine.run(q{
        auto getterStyle = item.value;
        auto omitted = item.value();
        auto explicitValue = item.value(2);
        return getterStyle + omitted + explicitValue;
    });
    assert(result.toInt() == 42);
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
    assert(reflectedGauge.propertyGetter("value") !is null);
    assert(reflectedGauge.propertySetter("value") !is null);
    assert("__dua_get_value" !in reflectedGauge.tableValue);
    assert("__dua_set_value" !in reflectedGauge.tableValue);
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
    final class Gauge
    {
        private int current;

        int value() const { return current; }
        void value(int next) { current = next; }
    }

    auto engine = new ScriptEngine();
    auto reflected = Value.reflect(new Gauge());
    reflected.tableValue["__dua_get_value"] = Value.from(11);
    reflected.tableValue["__dua_set_value"] = Value.from(22);
    engine.bind("gauge", reflected);

    auto result = engine.run(q{
        gauge.value = 7;
        auto spread = { ...gauge };
        return [gauge.value, spread.__dua_get_value, spread.__dua_set_value];
    });

    assert(result.arrayValue[0].toInt() == 7);
    assert(result.arrayValue[1].toInt() == 11);
    assert(result.arrayValue[2].toInt() == 22);
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
        if (length(info) != 3) {
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
        auto co = coroutine.create(() {
            error("coroutine failed");
        });

        auto ok1, message1 = coroutine.resume(co);
        auto status = coroutine.status(co);
        auto ok2, message2 = coroutine.resume(co);
        return [ok1, message1, status, ok2, message2];
    });

    assert(!result.arrayValue[0].truthy());
    assert(result.arrayValue[1].toHostString() == "coroutine failed");
    assert(result.arrayValue[2].toHostString() == "dead");
    assert(!result.arrayValue[3].truthy());
    assert(result.arrayValue[4].toHostString() == "coroutine failed");
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
    // Keep the complete standard-library surface installed by a fresh engine.
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        return typeof(error).kind == "function_"
            && typeof(length).kind == "function_"
            && typeof(map).kind == "function_"
            && typeof(string).kind == "table"
            && typeof(math).kind == "table"
            && typeof(table).kind == "table"
            && typeof(io).kind == "table"
            && typeof(os).kind == "table"
            && typeof(utf8).kind == "table"
            && typeof(debug).kind == "table"
            && typeof(time).kind == "table"
            && typeof(json).kind == "table"
            && typeof(coroutine).kind == "table";
    });
    assert(result.truthy());
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

private struct RuntimeAliasAngleFixture
{
    double value;
    alias value this;
}

private struct RuntimeAliasWrapperFixture
{
    RuntimeAliasAngleFixture value;
    alias value this;
}

unittest
{
    auto engine = new ScriptEngine();
    auto wrapper = RuntimeAliasWrapperFixture(RuntimeAliasAngleFixture(6.25));
    engine.bind("wrapper", Value.reflect(wrapper));
    engine.bindType!RuntimeAliasWrapperFixture("NamedWrapper");

    auto result = engine.run(q{
        auto reflected = typeinfo(wrapper);
        auto constructed = NamedWrapper({ value = { value = 2.5 } });
        auto constructedInfo = typeinfo(constructed);
        return [
            reflected.chain[0], length(reflected.aliasThisChain),
            wrapper is RuntimeAliasAngleFixture, wrapper is double,
            constructedInfo.chain[0], length(constructedInfo.aliasThisChain)
        ];
    });

    assert(result.arrayValue[0].toHostString() == "RuntimeAliasWrapperFixture");
    assert(result.arrayValue[1].toInt() == 2);
    assert(result.arrayValue[2].truthy() && result.arrayValue[3].truthy());
    assert(result.arrayValue[4].toHostString() == "NamedWrapper");
    assert(result.arrayValue[5].toInt() == 2);
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
