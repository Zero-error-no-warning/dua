module dua.evaluator;

/**
 * Internal execution/evaluation layer for Dua.
 *
 * `EvaluatorImplementation` is mixed into the owning runtime so evaluator code
 * can use the deliberately narrow set of runtime hooks (module loading, type
 * registration, coroutine yielding, and execution limits) without exposing the
 * ScriptEngine's private storage. Runtime orchestration depends on this module;
 * this module does not import `dua.runtime`.
 */

import dua.ast;
import dua.execution;
import dua.value;
import dua.type_syntax;
import dua.scope_layout;
import dua.scope_planner;
import std.conv : to;
import std.exception : enforce;
import std.format : format;
import std.math : floor;

// A reference retains its owning environment and resolves by name on each
// access. No pointer into a growable map or expired call frame escapes.
package(dua) final class ReferenceArgument : DeferredArgument
{
    Environment owner;
    string name, type;
    this(Environment owner, string name)
    {
        this.owner = owner; this.name = name; this.type = owner.bindingType(name);
        auto value = owner.find(name);
        enforce(value !is null, "Undefined reference argument: " ~ name);
        if (value.kind == ValueKind.function_)
            enforce(cast(DeferredArgument) value.functionValue is null
                || cast(ReferenceArgument) value.functionValue !is null, "Cannot reference a lazy parameter");
    }
    override string resultType() const { return type; }
    override Value invoke(Value[] args) { owner.validateModuleLifetime(); return owner.get(name); }
    void assign(Value value) { owner.validateModuleLifetime(); owner.assign(name, value); }
}

package final class ScriptThrownException : SourceException
{
    Value thrownValue;

    this(Value value, string message)
    {
        super(message);
        thrownValue = value;
    }
}

// Stack storage is private to evaluation. Keep capacity across pops, and clear
// inactive slots so receivers and closures are not retained by the GC.
package(dua) struct EvaluationStack(T)
{
    private T[] storage;
    private size_t count;

    size_t length() const { return count; }

    void push(T value)
    {
        if (count == storage.length) storage.length = count == 0 ? 8 : count * 2;
        storage[count++] = value;
    }

    void pop()
    {
        assert(count > 0);
        storage[--count] = T.init;
    }

    void clear()
    {
        storage[0 .. count] = T.init;
        count = 0;
    }

    const(T) top() const
    {
        assert(count > 0);
        return storage[count - 1];
    }

    const(T)[] view() const { return storage[0 .. count]; }
    T[] snapshot() { return storage[0 .. count].dup; }
}

/// Mutable state that belongs exclusively to evaluation of a run.
/// Keeping it together prevents evaluator internals from becoming ScriptEngine API.
/// 一つの実行場所に属する名前空間。通常変数の共有環境とは独立させます。
final class ModuleContext
{
    /// Optional host policy applied to every resolved source, including relative imports.
    void delegate(string source) validateSource;
    package(dua) Environment globals;
    package(dua) Object[string] modules;
    package(dua) string[] paths;
    package(dua) Value[] loaders;
    package(dua) void delegate(ModuleContext) release;
    ModuleContext parent;
    Object owner;
    private bool active = true;
    bool alive() const {
        return active && (parent is null || parent.alive);
    }
    package(dua) bool belongsTo(ModuleContext ancestor){
        for(auto current=this;current !is null;current=current.parent)if(current is ancestor)return true;
        return false;
    }
    void close(){
        if(!active)return;
        active=false;modules=null;
        if(release !is null)release(this);
    }
}

struct EvaluatorContext
{
    package(dua) ModuleContext moduleContext;
    package(dua) ModuleContext rootContext;
    package(dua) size_t contextDepth;
    package(dua) string[] moduleCreationPath;
    package(dua) Value[] moduleExportScopes;
    package(dua) Object activeCoroutine;
    package string moduleName;
    package string sourceName;
    package string sourceText;
    package bool hasSourceText;
    package EvaluationStack!string callStack;
    package string[] lastErrorStack;
    package EvaluationStack!long indexLengthStack;
    package EvaluationStack!Value thisContextStack;
    package RunOptions currentRunOptions;
    package size_t executedSteps;
    package size_t finallyDepth;
    package Exception unwindingException;
}

final class Environment
{
    Environment parent;
    package(dua) ModuleContext context;
    private Environment sharedSource;
    package(dua) Environment sharedDeclarations;
    package(dua) bool initializingModule;
    package(dua) bool failedModule;
    private bool[string] pendingDeclarations;
    package(dua) string pendingBindingLabel = "Module binding";

    package(dua) void reserveDeclaration(string name)
    {
        enforce((name in pendingDeclarations) is null,
            format("Duplicate module declaration '%s'", name));
        pendingDeclarations[name] = true;
    }

    private void checkInitialized(string name)
    {
        if(context !is null)enforce(context.alive,"Module context is closed");
        if(sharedSource !is null)sharedSource.checkInitialized(name);
        enforce(!failedModule, "Cannot access a failed module instance");
        if (auto pending = name in pendingDeclarations)
            enforce(!*pending, format("%s '%s' is not initialized", pendingBindingLabel, name));
    }

    package(dua) void validateModuleLifetime()
    {
        if(context !is null)enforce(context.alive,"Module context is closed");
        for (auto environment = this; environment !is null; environment = environment.parent)
            enforce(!environment.failedModule, "Cannot call a function belonging to a failed module instance");
    }
    private struct Binding
    {
        Value value;
        Value delegate(Value) validator;
        bool defined;
        string declaredType;
    }
    private struct Storage
    {
        ScopeLayout layout;
        Binding[] slots;
        Binding[string] bindings;
    }
    private struct SmallStorage(size_t count)
    {
        Storage header;
        Binding[count] values;
    }
    // Keep empty block environments as small as the original map-only frame.
    private Storage* storage;

    this(Environment parent = null)
    {
        this.parent = parent;
        if(parent !is null)context=parent.context;
    }

    package(dua) this(Environment parent, ScopeLayout layout)
    {
        this.parent = parent;
        if(parent !is null)context=parent.context;
        reserveSlots(layout);
    }

    package(dua) Environment sharedView(Environment parent){
        auto result=new Environment(parent);result.sharedSource=this;return result;
    }
    private Storage* bindingStorage(){return sharedSource is null ? storage : sharedSource.bindingStorage();}
    private const(Storage)* bindingStorage() const{return sharedSource is null ? storage : sharedSource.bindingStorage();}

    package(dua) bool hasStorage() const { return storage !is null; }

    package(dua) void reserveSlots(ScopeLayout layout)
    {
        assert(storage is null);
        // Never resize this array: public find() pointers must remain stable.
        if (layout !is null && layout.length)
        {
            // Small call/block frames need one allocation for metadata and
            // values together. Larger frames retain exact-size array storage.
            allocate: switch (layout.length)
            {
                static foreach (count; 1 .. 9)
                {
                    case count:
                    {
                        auto block = new SmallStorage!count;
                        storage = &block.header;
                        storage.slots = block.values[];
                        break allocate;
                    }
                }
                default:
                    storage = new Storage;
                    storage.slots.length = layout.length;
                    break;
            }
            storage.layout = layout;
        }
    }

    void define(string name, Value value, Value delegate(Value) validator = null)
    {
        if (auto pending = name in pendingDeclarations) *pending = false;
        if (storage is null) storage = new Storage;
        if (storage.layout !is null)
        {
            auto slot = storage.layout.find(name);
            if (slot != size_t.max)
            {
                enforce(!storage.slots[slot].defined,
                    format("Variable '%s' is already defined in this scope", name));
                storage.slots[slot] = Binding(value.valueCopy(), validator, true);
                return;
            }
        }
        enforce((name in storage.bindings) is null,
            format("Variable '%s' is already defined in this scope", name));
        storage.bindings[name] = Binding(value.valueCopy(), validator, true);
    }

    bool contains(string name) const
    {
        import std.typecons : Rebindable;
        for (auto environment = Rebindable!(const Environment)(this);
            environment !is null; environment = environment.parent)
        {
            auto data = environment.bindingStorage();
            if (data is null) continue;
            if (data.layout !is null)
            {
                auto slot = data.layout.find(name);
                if (slot != size_t.max && data.slots[slot].defined) return true;
            }
            if ((name in data.bindings) !is null) return true;
        }
        return false;
    }

    Value get(string name)
    {
        if (auto value = find(name)) return forceArgument(*value);
        enforce(false, format("Undefined variable '%s'", name));
        assert(0);
    }

    Value* find(string name)
    {
        if (auto binding = findBinding(name)) return &binding.value;
        return null;
    }

    package(dua) void declareType(string name,string type) {
        if(auto binding=findBinding(name)) binding.declaredType=type;
    }
    package(dua) string bindingType(string name) {
        if(auto binding=findBinding(name)) {
            if(binding.declaredType.length && binding.declaredType!="auto")return binding.declaredType;
            return argumentType(binding.value);
        }
        return "";
    }

    private Binding* findBinding(string name)
    {
        for (auto environment = this; environment !is null; environment = environment.parent)
        {
            environment.checkInitialized(name);
            auto data = environment.bindingStorage();
            if (data is null) continue;
            if (data.layout !is null)
            {
                auto slot = data.layout.find(name);
                if (slot != size_t.max && data.slots[slot].defined)
                    return &data.slots[slot];
            }
            if (auto binding = name in data.bindings) return binding;
        }
        return null;
    }

    void assign(string name, Value value)
    {
        if (auto binding = findBinding(name))
        {
            assignBinding(binding, value);
            return;
        }
        enforce(false, format("Cannot assign undefined variable '%s'", name));
    }

    private static void assignBinding(Binding* binding, Value value)
    {
        if (binding.value.kind == ValueKind.function_)
            if (auto reference = cast(ReferenceArgument) binding.value.functionValue)
            {
                if (binding.validator !is null) value = binding.validator(value);
                reference.assign(value);
                return;
            }
        enforce(binding.value.kind != ValueKind.function_ || cast(DeferredArgument)binding.value.functionValue is null,
            "Cannot assign to a lazy parameter" );
        if (binding.validator !is null) value = binding.validator(value);
        binding.value = value.valueCopy();
    }

    package(dua) Value get(string name, ref VariableSlots cache)
    {
        if (auto binding = findBinding(name, cache)) return forceArgument(binding.value);
        enforce(false, format("Undefined variable '%s'", name));
        assert(0);
    }

    package(dua) void assign(string name, Value value, ref VariableSlots cache)
    {
        if (auto binding = findBinding(name, cache))
        {
            assignBinding(binding, value);
            return;
        }
        enforce(false, format("Cannot assign undefined variable '%s'", name));
    }

    private Binding* findBinding(string name, ref VariableSlots cache)
    {
        // One-shot expressions need no path allocation. Resolve slots once the
        // same reference is used again; changing a public AST name resets it.
        if (cache.name !is name)
        {
            cache.name = name;
            cache.steps = null;
            return findBinding(name);
        }
        auto environment = this;
        foreach (step; cache.steps)
        {
            // Public ASTs and Environment.parent may be reused or changed.
            if (environment is null)
                return resolveSlots(name, cache);
            environment.checkInitialized(name);
            auto data = environment.bindingStorage();
            if ((data is null ? null : data.layout) !is step.layout)
                return resolveSlots(name, cache);
            if (data !is null)
            {
                if (step.slot != size_t.max && data.slots[step.slot].defined)
                    return &data.slots[step.slot];
                if (data.bindings !is null)
                    if (auto binding = name in data.bindings) return binding;
            }
            environment = environment.parent;
        }
        if (environment is null) return null;
        return resolveSlots(name, cache);
    }

    private Binding* resolveSlots(string name, ref VariableSlots cache)
    {
        VariableSlots resolved;
        resolved.name = name;
        for (auto environment = this; environment !is null;
            environment = environment.parent)
        {
            environment.checkInitialized(name);
            auto data = environment.bindingStorage();
            auto layout = data is null ? null : data.layout;
            auto slot = layout is null ? size_t.max : layout.find(name);
            resolved.steps ~= VariableSlots.Step(layout, slot);
            if (data !is null)
            {
                if (slot != size_t.max && data.slots[slot].defined)
                {
                    cache = resolved;
                    return &data.slots[slot];
                }
                if (auto binding = name in data.bindings)
                {
                    cache = resolved;
                    return binding;
                }
            }
        }
        cache = resolved;
        return null;
    }
}

unittest
{
    import std.exception : assertThrown;

    auto root = new Environment();
    int validations;
    root.define("checked", Value.from(1), (Value next) {
        ++validations;
        enforce(next.kind == ValueKind.integer, "Expected integer");
        return Value.from(next.toInt() * 2);
    });
    root.define("empty", Value.nullValue());
    auto nested = root;
    foreach (_; 0 .. 512) nested = new Environment(nested);
    assert(nested.contains("empty") && !nested.contains("missing"));
    assert(nested.find("checked") is root.find("checked"));
    nested.assign("checked", Value.from(3));
    assert(root.get("checked").toInt() == 6 && validations == 1);
    assertThrown!Exception(nested.assign("checked", Value.from("invalid")));
    assert(root.get("checked").toInt() == 6 && validations == 2);
    nested.define("checked", Value.from(10));
    nested.assign("checked", Value.from(11));
    assert(nested.get("checked").toInt() == 11 && root.get("checked").toInt() == 6);
    assert(validations == 2);
    assertThrown!Exception(nested.define("checked", Value.from(12)));
    assertThrown!Exception(nested.get("missing"));
    assertThrown!Exception(nested.assign("missing", Value.from(1)));
}

unittest
{
    import std.exception : assertThrown;

    auto layout = new ScopeLayout(["value", "checked", "empty"]);
    auto outer = new Environment();
    outer.define("value", Value.from(1));
    auto first = new Environment(outer, layout);
    VariableSlots cache;
    assert(first.get("value", cache).toInt() == 1);
    assert(!first.contains("checked"));
    first.define("value", Value.from(2));
    assert(first.get("value", cache).toInt() == 2);
    auto pointer = first.find("value");
    // Dynamic additions must neither move slots nor bypass closer bindings.
    foreach (i; 0 .. 128) first.define("extra" ~ to!string(i), Value.from(i));
    first.assign("value", Value.from(3), cache);
    assert(pointer is first.find("value") && pointer.toInt() == 3);
    auto second = new Environment(outer, layout);
    assert(second.get("value", cache).toInt() == 1);
    second.define("value", Value.from(4));
    assert(second.get("value", cache).toInt() == 4);
    auto otherLayout = new ScopeLayout(["empty", "value"]);
    auto third = new Environment(outer, otherLayout);
    third.define("empty", Value.from(99));
    third.define("value", Value.from(5));
    assert(third.get("value", cache).toInt() == 5);
    auto child = new Environment(first, new ScopeLayout(null));
    assert(child.get("value", cache).toInt() == 3);
    child.parent = second;
    assert(child.get("value", cache).toInt() == 4);
    child.define("value", Value.from(6));
    assert(child.get("value", cache).toInt() == 6);
    child.parent = null;
    assert(child.get("value", cache).toInt() == 6);
    VariableSlots missing;
    assertThrown!Exception(child.get("later", missing));
    assertThrown!Exception(child.get("later", missing));
    child.define("later", Value.from(7));
    assert(child.get("later", missing).toInt() == 7);
    first.define("empty", Value.nullValue());
    assert(first.contains("empty") && first.find("empty") !is null);
    int validations;
    first.define("checked", Value.from(8), (Value next) {
        ++validations;
        enforce(next.kind == ValueKind.integer, "Expected integer");
        return Value.from(next.toInt() * 2);
    });
    VariableSlots checked;
    first.assign("checked", Value.from(9), checked);
    assert(first.get("checked").toInt() == 18 && validations == 1);
    assertThrown!Exception(first.assign("checked", Value.from("bad"), checked));
    assert(first.get("checked").toInt() == 18 && validations == 2);
    assertThrown!Exception(first.define("value", Value.from(0)));
}

struct ExecutionResult
{
    Value lastValue;
    bool returned;
    bool broke;
    bool continued;
}


// Exact byte codes avoid a string-switch search on every arithmetic operation.
// The length tag keeps all one- and two-byte spellings distinct.
package(dua) uint operatorCode(string spelling) pure nothrow @safe @nogc
{
    if (spelling.length == 1) return spelling[0];
    if (spelling.length == 2) return 0x10000 | (spelling[0] << 8) | spelling[1];
    return uint.max;
}

package(dua) string binaryOperatorSlot(string spelling, bool right)
{
    switch (operatorCode(spelling))
    {
        static foreach (op; ["~", "+", "-", "*", "/", "%", "&", "|", "^",
            "<<", ">>", "==", "!=", "<", "<=", ">", ">="])
        {
            case operatorCode(op): return right ? "opBinaryRight" ~ op : "opBinary" ~ op;
        }
        default: return (right ? "opBinaryRight" : "opBinary") ~ spelling;
    }
}

/// Statement execution, expression evaluation, assignment, calls, and operators.
mixin template EvaluatorImplementation()
{
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
        try
        {
            consumeStep();
            ExecutionResult result;
            enforce(!statement.isInstance || environment.initializingModule,
                "instance is only allowed in a source module's top-level declarations");
            auto declarationEnvironment = environment.sharedDeclarations !is null && !statement.isInstance
                ? environment.sharedDeclarations : environment;

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
                            value = prepareContainerValue(value, statement.declaredType);
                            enforce(valueMatchesType(value, statement.declaredType),
                                typeMismatchMessage(statement.declaredType, format("Variable '%s' expected %s but got %s",
                                    name, statement.declaredType, value.kind)));
                        }
                        auto declaredType = statement.declaredType;
                        string elementType, keyType;
                        if (splitContainerType(resolveContainerType(declaredType), elementType, keyType)
                            || hasLiteralConstraint(declaredType) || hasNonNullConstraint(declaredType)
                            || hasContainerConstraint(declaredType) || hasFloatingPromotion(declaredType))
                            declarationEnvironment.define(name, value, containerValidator(declaredType));
                        else
                            declarationEnvironment.define(name, value);
                        declarationEnvironment.declareType(name,declaredType);
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
                case Statement.Kind.tableDecl:
                    registerTypeAlias(statement, environment);
                    result.lastValue = Value.nullValue();
                    break;
                case Statement.Kind.structDecl:
                    registerStructType(statement, declarationEnvironment, environment);
                    if (statement.isExported) exportSymbol(statement.publicTypeName, declarationEnvironment.get(statement.publicTypeName));
                    result.lastValue = Value.nullValue();
                    break;
                case Statement.Kind.try_:
                    result = executeTryStatement(statement, environment);
                    break;
                case Statement.Kind.assign:
                    if (statement.assignmentOperator.length)
                    {
                        Value left;
                        auto target = resolveCompoundTarget(statement.target, environment, left);
                        auto right = evaluate(statement.expression, environment);
                        auto value = evaluateBinary(statement.assignmentOperator, left, right);
                        assignTarget(target, value, environment, false);
                        result.lastValue = value;
                        break;
                    }
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
                        result.lastValue = Value.fromOwnedArray(
                            evaluateExpressionList(statement.expressions, environment));
                    }
                    result.returned = true;
                    break;
                case Statement.Kind.functionDecl:
                    auto callable = Value.fromFunction(new ScriptCallable(statement.name, this, environment,
                        statement.parameters, statement.variadic, statement.body,
                        statement.parameterTypes, statement.returnType, layoutFor(statement), statement.line, statement.column,
                        statement.parameterDefaults, statement.parameterLazy, statement.parameterRef));
                    environment.define(statement.name, callable);
                    result.lastValue = callable;
                    if (statement.isExported)
                    {
                        exportSymbol(statement.name, callable);
                    }
                    break;
                case Statement.Kind.import_:
                    auto imported = (statement.isInstance ? instantiateModule(statement.name, statement.isPathImport)
                        : requireModuleHandle(statement.name, statement.isPathImport)).exportsValue();
                    (environment.context is null ? declarationEnvironment : environment).define(statement.aliasName, imported);
                    result.lastValue = imported;
                    break;
                case Statement.Kind.export_:
                    exportSymbol(statement.name, environment.get(statement.name));
                    break;
                case Statement.Kind.block:
                    return executeStatements(statement.body, new Environment(environment, layoutFor(statement)));
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
                    auto loopEnvironment = new Environment(environment, layoutFor(statement));
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
                    enforce(!statement.reverseIteration || statement.rangeEnd !is null || iterable.kind == ValueKind.array,
                        "foreach_reverse expects an array or an integer range");
                    if (statement.rangeEnd !is null)
                    {
                        // 境界を開始時に一度だけ評価し、配列を確保せず上端非包含で進めます。
                        auto end = evaluate(statement.rangeEnd, environment);
                        enforce(iterable.kind == ValueKind.integer && end.kind == ValueKind.integer,
                            "Range foreach bounds must be integers");
                        auto cursor = statement.reverseIteration ? end.integerValue : iterable.integerValue;
                        while (statement.reverseIteration ? cursor > iterable.integerValue : cursor < end.integerValue)
                        {
                            auto index = statement.reverseIteration ? --cursor : cursor++;
                            auto itemEnvironment = new Environment(environment, layoutFor(statement));
                            itemEnvironment.define(statement.iteratorName, Value.from(index));
                            result = executeStatement(statement.body[0], itemEnvironment);
                            if (result.returned) return result;
                            if (result.broke) { result.broke = false; break; }
                            result.continued = false;
                        }
                    }
                    else if (iterable.kind == ValueKind.array)
                    {
                        foreach (offset; 0 .. iterable.arrayValue.length)
                        {
                            auto index = statement.reverseIteration ? iterable.arrayValue.length - 1 - offset : offset;
                            auto item = iterable.arrayValue[index];
                            auto itemEnvironment = new Environment(environment, layoutFor(statement));
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
                    else if (iterable.kind == ValueKind.associativeArray)
                    {
                        foreach (entry; (cast(AssociativeEntry[]) iterable.associativeEntries).dup)
                        {
                            auto itemEnvironment = new Environment(environment, layoutFor(statement));
                            if (statement.iteratorSecondName.length == 0)
                                itemEnvironment.define(statement.iteratorName, cast(Value) entry.value);
                            else
                            {
                                itemEnvironment.define(statement.iteratorName, entry.key.keyCopy());
                                itemEnvironment.define(statement.iteratorSecondName, cast(Value) entry.value);
                            }
                            result = executeStatement(statement.body[0], itemEnvironment);
                            if (result.returned) return result;
                            if (result.broke) { result.broke = false; break; }
                            result.continued = false;
                        }
                    }
                    else if (iterable.kind == ValueKind.table)
                    {
                        foreach (key, value; iterable.tableValue)
                        {
                            auto itemEnvironment = new Environment(environment, layoutFor(statement));
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
                        enforce(false, "foreach expects array, associative array, or table");
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

                        result = executeStatements(switchCase.body, new Environment(environment, layoutFor(switchCase)));
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
                    Value[] yieldedValues;
                    if (statement.expressions.length == 0)
                    {
                        yieldedValues = [Value.nullValue()];
                    }
                    else
                    {
                        yieldedValues = evaluateExpressionList(statement.expressions, environment, true);
                    }
                    result.lastValue = yieldFromScript(yieldedValues);
                    break;
            }

            return result;
        }
        catch (Exception error)
        {
            auto location = statementLocation(statement);
            throw withSourceContext(error, evaluatorContext.sourceName, location, "statement", statement is null ? 0 : statement.line, statement is null ? 0 : statement.column);
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
        values.length = expressions.length;
        foreach (index, expression; expressions)
        {
            values[index] = evaluate(expression, environment);
        }
        return values;
    }

    // Freeze the receiver and index so reading and writing use the same location,
    // including when the RHS changes a variable used by the original target.
    private Expression resolveCompoundTarget(Expression target, Environment environment, out Value current)
    {
        Expression resolved;
        switch (target.kind)
        {
            case Expression.Kind.variable:
                current = evaluate(target, environment);
                return target;
            case Expression.Kind.get:
                auto property = cast(GetExpression) target;
                Expression writeback;
                auto container = resolvePropertyReceiver(property, environment, writeback);
                auto frozen = new GetExpression(new LiteralExpression(container), property.memberName);
                frozen.arrayLengthTarget = writeback;
                resolved = frozen;
                resolved.line = target.line;
                resolved.column = target.column;
                current = evaluate(resolved, environment);
                break;
            case Expression.Kind.index:
                auto indexed = cast(IndexExpression) target;
                enforce(!indexed.isSlice, "Slice cannot be an assignment target");
                enforce(indexed.indices.length == 1, "Index assignment requires a single index");
                auto container = evaluate(indexed.target, environment);
                enforce(container.kind != ValueKind.string_, "String elements are immutable");
                if(container.isNativeAggregate)
                    if(auto setter=container.findMember("opIndexAssign"))
                        enforce(setter.kind!=ValueKind.function_,"Native indexed compound assignment is not supported");
                auto pushedLength = canMeasureLength(container);
                if (pushedLength) evaluatorContext.indexLengthStack.push(measuredLength(container));
                scope (exit)
                {
                    if (pushedLength) evaluatorContext.indexLengthStack.pop();
                }
                auto index = evaluate(indexed.index, environment);
                resolved = new IndexExpression(new LiteralExpression(container), new LiteralExpression(index));
                current = readIndex(container, [index], callSite(target));
                break;
            default:
                enforce(false, "Invalid compound assignment target");
        }
        resolved.line = target.line;
        resolved.column = target.column;
        return resolved;
    }

    // lengthは配列の値でなくハンドルを更新するため、取得と書戻しで同じ場所を使います。
    private Value resolvePropertyReceiver(GetExpression get, Environment environment, out Expression writeback)
    {
        writeback = get.arrayLengthTarget;
        Value receiver;
        if (get.memberName == "length" && writeback is null && isAssignmentLocation(get.target))
            writeback = resolveCompoundTarget(get.target, environment, receiver);
        else receiver = evaluate(get.target, environment);
        return receiver;
    }

    private void assignTarget(Expression target, Value value, Environment environment, bool simpleAssignment=true)
    {
        try
        {
            switch (target.kind)
            {
                case Expression.Kind.variable:
                    auto variable = cast(VariableExpression) target;
                    environment.assign(variable.name, value, variable.slots);
                    return;
                case Expression.Kind.get:
                    auto get = cast(GetExpression) target;
                    Expression writeback;
                    auto container = resolvePropertyReceiver(get, environment, writeback);
                    enforce(container.kind != ValueKind.null_, "Cannot assign member '" ~ get.memberName ~ "' on null");
                    if (container.kind == ValueKind.array && get.memberName == "length")
                    {
                        enforce(writeback !is null, "Array length requires an assignable array");
                        auto resized = resizeScriptArray(container, value);
                        assignTarget(writeback, resized, environment);
                        return;
                    }
                    enforce(container.isFieldAggregate,
                        "Property assignment currently supports tables/reflected structs/classes");
                    value = container.validateFieldAssignment(get.memberName, value);
                    if (auto property = container.findMember(get.memberName))
                    {
                        if (property.kind == ValueKind.function_
                            && property.functionValue.acceptsArity(1))
                        {
                            invokeFunctionValueWithThis(*property, [value], container);
                            return;
                        }
                    }
                    Value setter;
                    if (container.lookupPropertySetter(get.memberName, setter))
                    {
                        invokeFunctionValue(setter, [value]);
                        return;
                    }
                    if (!applyTableNewIndex(container, get.memberName, value))
                    {
                        container.tableValue[get.memberName] = value.valueCopy();
                    }
                    return;
                case Expression.Kind.index:
                    auto indexed = cast(IndexExpression) target;
                    auto container = evaluate(indexed.target, environment);
                    enforce(container.kind != ValueKind.null_, "Cannot index untyped null");
                    enforce(container.kind != ValueKind.null_, "Cannot index untyped null");
                    enforce(container.kind != ValueKind.string_, "String elements are immutable");
                    enforce(!indexed.isSlice, "Slice cannot be an assignment target");
                    enforce(indexed.indices.length == 1, "Index assignment requires a single index");
                    // A compound target already resolved its index to a literal and measured length once.
                    auto pushedLength = indexed.index.kind != Expression.Kind.literal && canMeasureLength(container);
                    if (pushedLength) evaluatorContext.indexLengthStack.push(measuredLength(container));
                    scope (exit)
                    {
                        if (pushedLength) evaluatorContext.indexLengthStack.pop();
                    }
                    auto index = evaluate(indexed.index, environment);
                    if(container.isNativeAggregate){
                        if(auto setter=container.findMember("opIndexAssign")){
                            if(setter.kind==ValueKind.function_){
                                enforce(simpleAssignment,"Native indexed compound assignment is not supported");
                                // Dの代入演算子は値、キーの順。キーを文字列化する前に渡します。
                                invokeFunctionValueWithThis(*setter,[value,index],container,callSite(target));
                                return;
                            }
                        }
                    }
                    if (container.kind == ValueKind.associativeArray)
                    {
                        index = checkedAssociativeKey(container, index);
                        value = prepareContainerValue(value, container.associativeValueType);
                        enforce(valueMatchesType(value, container.associativeValueType),
                            typeMismatchMessage(container.associativeValueType, "Associative array value expected " ~ container.associativeValueType));
                        container.associativeSet(index, value);
                        return;
                    }
                    if (container.kind == ValueKind.array)
                    {
                        auto position = cast(size_t) index.toInt();
                        enforce(position < container.arrayValue.length, "Array index out of range");
                        if (container.arrayElementType.length)
                        {
                            value = prepareArrayElement(value, container.arrayElementType);
                            enforce(valueMatchesType(value, container.arrayElementType),
                                typeMismatchMessage(container.arrayElementType, "Array element expected " ~ container.arrayElementType));
                        }
                        if (container.arrayValidation !is null)
                        {
                            // 候補の配列全体を検査してから確定し、失敗時は共有配列も復元します。
                            if (value.kind == ValueKind.array) value = copyUnionArray(value, true);
                            auto previous = container.arrayValue[position];
                            container.arrayValue[position] = value.valueCopy();
                            try container.arrayValidation.validate();
                            catch (Exception error) { container.arrayValue[position] = previous; throw error; }
                            container.arrayValidation.refresh();
                        }
                        else container.arrayValue[position] = value.valueCopy();
                        return;
                    }
                    if (container.isFieldAggregate)
                    {
                        auto key = index.toHostString();
                        value = container.validateFieldAssignment(key, value);
                        if (!applyTableNewIndex(container, key, value))
                        {
                            container.tableValue[key] = value.valueCopy();
                        }
                        return;
                    }
                    break;
                default:
                    break;
            }

            enforce(false, "Invalid assignment target");
        }
        catch (Exception error)
        {
            auto location = expressionLocation(target);
            throw withSourceContext(error, evaluatorContext.sourceName, location, "assignment", target is null ? 0 : target.line, target is null ? 0 : target.column);
        }
    }

    private void executeFinally(Statement block, Environment environment, Exception pending = null)
    {
        auto limits = evaluatorContext.currentRunOptions.limits;
        auto steps = evaluatorContext.executedSteps;
        auto trace = evaluatorContext.lastErrorStack;
        bool limited = cast(ExecutionLimitException) pending !is null;
        if (limited)
        {
            // Cleanup cannot bypass a limit or run forever after the main
            // budget is exhausted. Preserve the original limit classification.
            evaluatorContext.executedSteps = 0;
            evaluatorContext.currentRunOptions.limits.maxSteps = 1024;
            evaluatorContext.currentRunOptions.limits.maxCallDepth = evaluatorContext.callStack.length + 16;
        }
        scope(exit) if (limited)
        {
            auto cleanupSteps = evaluatorContext.executedSteps;
            evaluatorContext.currentRunOptions.limits = limits;
            evaluatorContext.executedSteps = cleanupSteps > size_t.max - steps ? size_t.max : steps + cleanupSteps;
            evaluatorContext.lastErrorStack = trace;
        }
        ++evaluatorContext.finallyDepth;
        scope(exit) --evaluatorContext.finallyDepth;
        auto result = executeStatements(block.body, new Environment(environment, layoutFor(block)));
        enforce(!result.returned && !result.broke && !result.continued, "Control flow cannot leave finally");
    }

    private ExecutionResult executeTryStatement(Statement statement, Environment environment)
    {
        ExecutionResult result; Exception pending;
        try
        {

                    try
                    {
                        result = executeStatements(statement.body, new Environment(environment, layoutFor(statement)));
                    }
                    catch (Exception error)
                    {
                        if (cast(ExecutionLimitException) error !is null || statement.elseBranch is null)
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
                        auto trace = evaluatorContext.lastErrorStack.length > 0 ? evaluatorContext.lastErrorStack : evaluatorContext.callStack.view;
                        foreach (frame; trace) frames ~= Value.from(frame);
                        Value[string] errorInfo;
                        errorInfo["kind"] = Value.from(kind);
                        errorInfo["message"] = Value.from(error.msg);
                        errorInfo["value"] = original;
                        errorInfo["stack"] = Value.from(frames);
                        auto catchEnvironment = new Environment(environment, catchLayoutFor(statement));
                        catchEnvironment.define(statement.name, Value.from(errorInfo));
                        result = executeStatements(statement.elseBranch.body, catchEnvironment);
                    }
        }
        catch (Exception error) { pending = error; }
        if (statement.finallyBranch !is null)
        {
            try executeFinally(statement.finallyBranch, environment, pending);
            catch (Exception cleanup)
            {
                if (cast(ExecutionLimitException) pending !is null) throw pending;
                if (pending !is null && cleanup !is pending) cleanup.next = pending;
                throw cleanup;
            }
        }
        if (pending !is null) throw pending;
        return result;
    }

    private Value evaluate(Expression expression, Environment environment)
    {
        try
        {
            consumeStep();
            final switch (expression.kind)
            {
                case Expression.Kind.with_:
                    auto with_=cast(WithExpression)expression;
                    auto target=evaluate(with_.target,environment);
                    enforce(target.isFieldAggregate,"with target must be a table, struct or reflected object");
                    auto scope_=new Environment(environment);
                    scope_.define(with_.bindingName,target);
                    return evaluate(with_.body,scope_);
                case Expression.Kind.literal:
                    return (cast(LiteralExpression) expression).value;
                case Expression.Kind.variable:
                    auto variable = cast(VariableExpression) expression;
                    return environment.get(variable.name, variable.slots);
                case Expression.Kind.cast_:
                    auto conversion = cast(CastExpression) expression;
                    return castValue(evaluate(conversion.operand, environment), conversion.targetType, conversion.checkedConversion);
                case Expression.Kind.unary:
                    auto unary = cast(UnaryExpression) expression;
                    switch (unary.operatorSymbol)
                    {
                        case "new":
                            return instantiateModuleValue(evaluate(unary.operand, environment));
                        case "$":
                            enforce(evaluatorContext.indexLengthStack.length > 0, "$ is only available inside index expressions");
                            return Value.from(evaluatorContext.indexLengthStack.top());
                        case "-":
                            auto right = evaluate(unary.operand, environment);
                            Value overloaded;
                            if (tryCallUnaryOverload(unary.operatorSymbol, right, overloaded))
                            {
                                return overloaded;
                            }
                            return right.kind == ValueKind.integer
                                ? Value.from(-right.integerValue)
                                : Value.from(-right.toFloat());
                        case "!":
                            auto right = evaluate(unary.operand, environment);
                            Value overloaded;
                            if (tryCallUnaryOverload(unary.operatorSymbol, right, overloaded))
                            {
                                return overloaded;
                            }
                            return Value.from(!right.truthy());
                        default:
                            enforce(false, format("Unsupported unary operator '%s'", unary.operatorSymbol));
                            assert(0);
                    }
                case Expression.Kind.binary:
                    return evaluateBinaryExpression(cast(BinaryExpression) expression, environment);
                case Expression.Kind.ternary:
                    auto ternary = cast(TernaryExpression) expression;
                    return evaluate(ternary.condition, environment).truthy()
                        ? evaluate(ternary.whenTrue, environment)
                        : evaluate(ternary.whenFalse, environment);
                case Expression.Kind.call:
                    auto call = cast(CallExpression) expression;
                    auto caller = callSite(call);
                    return evaluateCall(call.callee, call.arguments, environment, caller, call.argumentNames);
                case Expression.Kind.array:
                    auto array = cast(ArrayExpression) expression;
                    Value[] items;
                    foreach (index, argument; array.elements)
                    {
                        auto value = evaluate(argument, environment);
                        if (index < array.elementSpreads.length && array.elementSpreads[index])
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
                    return Value.fromOwnedArray(items);
                case Expression.Kind.associativeArray:
                    auto literal = cast(AssociativeArrayExpression) expression;
                    auto result = Value.associativeArray();
                    foreach (index, keyExpression; literal.keys)
                    {
                        auto key = evaluate(keyExpression, environment);
                        auto value = evaluate(literal.values[index], environment);
                        result.associativeSet(key, value);
                    }
                    return result;
                case Expression.Kind.table:
                    auto tableLiteral = cast(TableExpression)expression;
                    Value[string] entries;
                    foreach (entry; tableLiteral.entries)
                    {
                        if (entry.isSpread)
                        {
                            auto spread = evaluate(entry.value, environment);
                            enforce(spread.kind == ValueKind.table,
                                "Table spread requires a table value");
                            foreach (spreadKey, spreadValue; spread.tableValue)
                            {
                                if (spreadKey == "__meta")
                                {
                                    continue;
                                }
                                enforce(!tableLiteral.targetType.length || (spreadKey in entries) is null,
                                    "Duplicate initializer field '" ~ spreadKey ~ "'");
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
                        enforce(!tableLiteral.targetType.length || (key in entries) is null,
                            "Duplicate initializer field '" ~ key ~ "'");
                        entries[key] = evaluate(entry.value, environment);
                    }
                    auto tableValue = Value.from(entries);
                    return tableLiteral.targetType.length ? constructNamedTable(tableLiteral.targetType, tableValue) : tableValue;
                case Expression.Kind.function_:
                    auto functionExpression = cast(FunctionExpression) expression;
                    return Value.fromFunction(new ScriptCallable("anonymous", this, environment,
                        functionExpression.parameters, functionExpression.variadic, functionExpression.body,
                        functionExpression.parameterTypes, functionExpression.returnType, layoutFor(functionExpression),
                        functionExpression.line, functionExpression.column, functionExpression.parameterDefaults, functionExpression.parameterLazy, functionExpression.parameterRef));
                case Expression.Kind.get:
                    return evaluateGetExpression(cast(GetExpression) expression, environment);
                case Expression.Kind.index:
                    auto indexed = cast(IndexExpression) expression;
                    auto container = evaluate(indexed.target, environment);
                    enforce(container.kind != ValueKind.null_, "Cannot index untyped null");
                    bool pushedLengthContext;
                    if (canMeasureLength(container))
                    {
                        evaluatorContext.indexLengthStack.push(measuredLength(container));
                        pushedLengthContext = true;
                    }
                    scope (exit)
                    {
                        if (pushedLengthContext)
                        {
                            evaluatorContext.indexLengthStack.pop();
                        }
                    }
                    if (indexed.isSlice)
                    {
                        enforce(container.kind == ValueKind.array, "Slicing currently supports arrays only");
                        auto start = evaluate(indexed.sliceStart, environment).toInt();
                        auto finish = evaluate(indexed.sliceEnd, environment).toInt();
                        enforce(start >= 0 && finish >= start, "Invalid slice range");
                        auto lowerBound = cast(size_t) start;
                        auto upperBound = cast(size_t) finish;
                        enforce(upperBound <= container.arrayValue.length, "Slice end out of range");
                        return container.slicedArrayHandle(lowerBound, upperBound);
                    }
                    auto indices = evaluateExpressionList(indexed.indices, environment);
                    return readIndex(container, indices, callSite(indexed));
            }
        }
        catch (Exception error)
        {
            auto location = expressionLocation(expression);
            throw withSourceContext(error, evaluatorContext.sourceName, location, "expression", expression is null ? 0 : expression.line, expression is null ? 0 : expression.column);
        }
    }

    private Value readIndex(Value container, Value[] indices, CallSite caller = CallSite.init)
    {
        enforce(container.kind != ValueKind.null_, "Cannot index untyped null");
        if (container.isFieldAggregate)
        {
            if (auto method = container.findMember("opIndex"))
                if (method.kind == ValueKind.function_)
                    return invokeFunctionValueWithThis(*method, indices, container, caller);
        }
        enforce(indices.length == 1, "Indexing requires a single index unless opIndex is defined");
        auto index = indices[0];
        if (container.kind == ValueKind.string_)
        {
            // D string indexes UTF-8 code units, not decoded characters. Dua has
            // no char scalar, so expose the unsigned byte as an integer.
            enforce(index.kind == ValueKind.integer || index.kind == ValueKind.boolean,
                "String index expects an integer");
            auto position = index.kind == ValueKind.boolean ? cast(long) index.booleanValue : index.toInt();
            enforce(position >= 0 && cast(ulong) position < container.stringValue.length,
                "String index out of range");
            return Value.from(cast(int) cast(ubyte) container.stringValue[cast(size_t) position]);
        }
        if (container.kind == ValueKind.associativeArray)
        {
            index = checkedAssociativeKey(container, index);
            auto position = container.associativeIndex(index);
            enforce(position != size_t.max, "Associative array key not found");
            return container.associativeEntries[position].value.valueCopy();
        }
        if (container.kind == ValueKind.array)
        {
            auto position = cast(size_t) index.toInt();
            enforce(position < container.arrayValue.length, "Array index out of range");
            return container.arrayValue[position];
        }
        if (container.isFieldAggregate)
        {
            auto key = index.toHostString();
            Value resolved;
            if (resolveTableIndex(container, key, resolved)) return resolved;
            return Value.nullValue();
        }
        enforce(false, "Indexing currently supports arrays, strings and tables");
        assert(0);
    }

    private string statementLocation(Statement statement) const
    {
        if (statement.line == 0 || statement.column == 0)
        {
            return "unknown";
        }
        return format("%s:%s", statement.line, statement.column);
    }

    // Preserve Dua's long/double storage while using D conversion rules.
    private Value numericCast(T)(Value value, bool checkedConversion)
    {
        T result;
        switch (value.kind)
        {
            case ValueKind.integer:
                result = checkedConversion ? to!T(value.integerValue) : cast(T) value.integerValue;
                break;
            case ValueKind.floating:
                static if (is(T == byte) || is(T == ubyte) || is(T == short)
                    || is(T == ushort) || is(T == uint))
                    if (checkedConversion)
                        enforce(value.floatingValue >= T.min && value.floatingValue <= T.max,
                            "Cannot convert non-finite or out-of-range double to " ~ T.stringof);
                static if (is(T == long))
                    if (checkedConversion)
                        enforce(value.floatingValue >= -9223372036854775808.0
                            && value.floatingValue < 9223372036854775808.0,
                            "Cannot convert non-finite or out-of-range double to int");
                static if (is(T == ulong))
                    if (checkedConversion)
                        enforce(value.floatingValue >= 0
                            && value.floatingValue < 9223372036854775808.0,
                            "Result exceeds Dua's signed 64-bit integer storage");
                result = checkedConversion ? to!T(value.floatingValue) : cast(T) value.floatingValue;
                break;
            case ValueKind.boolean:
                result = checkedConversion ? to!T(value.booleanValue) : cast(T) value.booleanValue;
                break;
            case ValueKind.string_:
                enforce(checkedConversion, "String parsing requires cast!(Type)");
                result = to!T(value.stringValue);
                break;
            default:
                enforce(false, format("Cannot convert %s to %s", value.kind, T.stringof));
        }
        static if (is(T == bool)) return Value.from(result);
        else static if (is(T == float) || is(T == double)) return Value.from(cast(double) result);
        else
        {
            static if (is(T == ulong))
                enforce(result <= long.max, "Result exceeds Dua's signed 64-bit integer storage");
            return Value.from(cast(long) result);
        }
    }

    // Separate expression frames keep ordinary recursive calls small.
    private Value evaluateBinaryExpression(BinaryExpression binary, Environment environment)
    {
        if (binary.operatorSymbol == "is")
        {
            return Value.from(valueIsType(
                evaluate(binary.left, environment), (cast(VariableExpression) binary.right).name));
        }
        if (binary.operatorSymbol == "??")
        {
            auto left = evaluate(binary.left, environment);
            return left.isNullReference ? evaluate(binary.right, environment) : left;
        }
        if (binary.operatorSymbol == "&&")
        {
            auto left = evaluate(binary.left, environment);
            if (!left.truthy())
            {
                return Value.from(false);
            }

            auto right = evaluate(binary.right, environment);
            return Value.from(right.truthy());
        }

        if (binary.operatorSymbol == "||")
        {
            auto left = evaluate(binary.left, environment);
            if (left.truthy())
            {
                return Value.from(true);
            }

            auto right = evaluate(binary.right, environment);
            return Value.from(right.truthy());
        }

        return evaluateBinary(binary.operatorSymbol,
            evaluate(binary.left, environment), evaluate(binary.right, environment));
    }

    // Separate expression frames keep ordinary recursive calls small.
    private Value evaluateGetExpression(GetExpression get, Environment environment)
    {
        auto container = evaluate(get.target, environment);
        if (get.nullConditional && container.isNullReference) return Value.nullValue();
        enforce(container.kind != ValueKind.null_, "Cannot access member '" ~ get.memberName ~ "' on null");
        if ((container.kind == ValueKind.array || container.kind == ValueKind.string_) && get.memberName == "length")
            return Value.from(measuredLength(container));
        if (container.kind == ValueKind.associativeArray
            && (get.memberName == "keys" || get.memberName == "values" || get.memberName == "length"))
            return associativeProperty(container, get.memberName);
        if (container.isFieldAggregate)
        {
            Value getter;
            if (container.lookupPropertyGetter(get.memberName, getter))
            {
                auto refreshed = invokeFunctionValueWithThis(getter, [], container, callSite(get));
                auto property = container.findMember(get.memberName);
                if (!container.isClassReference && (property is null || property.kind != ValueKind.function_))
                {
                    container.refreshMember(get.memberName, refreshed);
                }
                return refreshed;
            }
            if (auto value = container.findMember(get.memberName))
            {
                if (container.moduleOwner is null && value.kind == ValueKind.function_
                    && value.functionValue.acceptsArity(0))
                {
                    return invokeFunctionValueWithThis(*value, [], container, callSite(get));
                }
                return value.withReceiver(container);
            }
            Value resolved;
            if (resolveTableIndex(container, get.memberName, resolved))
            {
                return resolved;
            }
        }
        // メンバーと __index を優先し、受け手だけで呼べる UFCS を
        // 既存の引数なしメンバーと同じ arity 判定で評価します。
        if (!get.withMember) if (auto functionValue = resolveUfcs(get.memberName, environment))
        {
            auto callable = functionValue.functionValue;
            // raw bindNative のように引数数が不明な関数は、
            // 必須引数の不足を避けるため明示呼び出しに残します。
            auto knownArity = callable.expectedArity() != size_t.max
                || callable.minimumArity() != 0 || callable.maximumArity() != size_t.max
                || (cast(ScriptCallable)callable) !is null
                || (cast(ReflectedCallable)callable) !is null
                || (cast(OverloadedReflectedCallable)callable) !is null;
            if (knownArity && callable.acceptsArity(1))
                return invokeFunctionValue(*functionValue, [container], callSite(get));
        }
        if (container.kind == ValueKind.associativeArray)
            return associativeProperty(container, get.memberName);
        enforce(container.isFieldAggregate,
            "Property access currently supports tables/reflected structs/classes or callable UFCS");
        enforce(false, format("Unknown property '%s'", get.memberName));
        assert(0);
    }

    private Value castValue(Value value, string targetType, bool checkedConversion = false, size_t depth = 0)
    {
        enforce(depth < 64, "Cyclic or excessively nested cast type alias");
        string nonNullInner;
        if (splitNonNullType(targetType, nonNullInner))
        {
            enforce(!value.isNullReference, typeMismatchMessage(targetType, "Cannot cast null to non-nullable type " ~ targetType));
            return castValue(value, nonNullInner, checkedConversion, depth + 1);
        }
        string elementType, keyType;
        if (splitContainerType(resolveContainerType(targetType), elementType, keyType)
            || (value.kind == ValueKind.array && hasLiteralConstraint(targetType)))
            return prepareContainerValue(value, targetType);
        // A pure alias uses the same conversion as its target. Union casts
        // only check membership, since choosing a conversion would be ambiguous.
        if (auto definition = findTypeDefinition(targetType))
        {
            if (!definition.tableValue["isTable"].truthy())
            {
                auto alternatives = definition.tableValue["alternatives"].arrayValue;
                if (alternatives.length == 1)
                    return castValue(value, alternatives[0].toHostString(), checkedConversion, depth + 1);
            }
        }
        switch (targetType)
        {
            case "byte": return numericCast!byte(value, checkedConversion);
            case "ubyte": return numericCast!ubyte(value, checkedConversion);
            case "short": return numericCast!short(value, checkedConversion);
            case "ushort": return numericCast!ushort(value, checkedConversion);
            case "uint": return numericCast!uint(value, checkedConversion);
            case "ulong": return numericCast!ulong(value, checkedConversion);
            case "int", "long": return numericCast!long(value, checkedConversion);
            case "float": return numericCast!float(value, checkedConversion);
            case "double", "real": return numericCast!double(value, checkedConversion);
            case "bool":
                if (checkedConversion) return numericCast!bool(value, true);
                return Value.from(value.truthy());
            case "string":
                if (checkedConversion) return Value.from(value.toHostString());
                if (value.kind == ValueKind.string_) return value;
                break;
            case "void":
                if (!checkedConversion) return Value.init;
                if (value.kind == ValueKind.null_) return value;
                break;
            case "array":
                if (value.kind == ValueKind.null_) return Value.nullArray();
                if (value.kind == ValueKind.array) return value;
                break;
            case "associativeArray":
                if (value.kind == ValueKind.null_) return Value.nullAssociativeArray();
                if (value.kind == ValueKind.associativeArray) return value;
                break;
            case "table":
                if (value.kind == ValueKind.table || value.kind == ValueKind.null_) return value;
                break;
            case "function":
                if (value.kind == ValueKind.function_) return value;
                break;
            default:
                if (valueMatchesType(value, targetType)) return value.valueCopy();
                break;
        }
        enforce(false, typeMismatchMessage(targetType, format("Cannot cast %s to %s", value.kind, targetType)));
        assert(0);
    }

    private string expressionLocation(Expression expression) const
    {
        if (expression.line == 0 || expression.column == 0)
        {
            return "unknown";
        }
        return format("%s:%s", expression.line, expression.column);
    }

    private Exception withSourceContext(Exception error, string sourceName,
        string location = "", string context = "source", size_t line = 0, size_t column = 0)
    {
        auto contextual = cast(SourceException) error;
        if (contextual !is null && contextual.hasSourceContext)
            return error;
        if (contextual is null){
            contextual = new SourceException(error.msg, error);
            auto nested=scriptDiagnostic(error);
            if(nested.sourceName.length){contextual.diagnostic=nested;contextual.hasSourceContext=true;return contextual;}
            if(nested.line)contextual.diagnostic=nested;
        }
        if(!contextual.diagnostic.sourceName.length)contextual.diagnostic.sourceName=sourceName;
        if(!contextual.diagnostic.line){contextual.diagnostic.line=line;contextual.diagnostic.column=column;}
        // 解析済み依存の最初の発生元を、外側のrun/import名で置換しません。
        auto origin = contextual.diagnostic.sourceName.length > 0 ? contextual.diagnostic.sourceName : "<global>";
        if (location.length > 0) origin ~= ":" ~ location;
        contextual.msg = format("[%s @ %s] %s", context, origin, error.msg);
        contextual.hasSourceContext = true;
        if(evaluatorContext.hasSourceText && contextual.diagnostic.sourceName==evaluatorContext.sourceName)
            withDiagnosticSource(contextual,evaluatorContext.sourceName,evaluatorContext.sourceText);
        return contextual;
    }

    private Value evaluateBinary(string operatorSymbol, Value left, Value right)
    {
        if (left.isFieldAggregate || right.isFieldAggregate)
        {
            Value overloaded;
            if (tryCallBinaryOverload(operatorSymbol, left, right, overloaded)) return overloaded;
        }

        switch (operatorCode(operatorSymbol))
        {
            case operatorCode("~"):
                if (left.kind == ValueKind.array)
                {
                    auto added = right.kind == ValueKind.array ? right.arrayValue : [right];
                    Value[] combined;
                    combined.length = left.arrayValue.length + added.length;
                    combined[0 .. left.arrayValue.length] = left.arrayValue;
                    combined[left.arrayValue.length .. $] = added;
                    if (left.arrayValidation !is null && left.arrayValidation.localTypes.length)
                    {
                        // 追加リスト全体でmemoを共有し、既存の検査済み内配列へのaliasも保持します。
                        auto prepared = copyUnionArray(Value.fromOwnedArray(added.dup), true);
                        combined[left.arrayValue.length .. $] = prepared.arrayValue;
                        auto result = Value.fromOwnedArray(combined);
                        foreach (types; left.arrayValidation.localTypes)
                            result = prepareUnionArray(result, types);
                        return result;
                    }
                    if (left.arrayElementType.length)
                        foreach (ref element; combined)
                        {
                            element = prepareArrayElement(element, left.arrayElementType);
                            enforce(valueMatchesType(element, left.arrayElementType),
                                typeMismatchMessage(left.arrayElementType, "Array element expected " ~ left.arrayElementType));
                        }
                    auto result = Value.fromOwnedArray(combined, left.arrayElementType);
                    result.arrayDefaultType = left.arrayDefaultType;
                    return result;
                }
                return Value.from(stringify(left) ~ stringify(right));
            case operatorCode("+"):
                if (left.kind == ValueKind.integer && right.kind == ValueKind.integer)
                {
                    return Value.from(left.integerValue + right.integerValue);
                }
                return Value.from(left.toFloat() + right.toFloat());
            case operatorCode("-"):
                if (left.kind == ValueKind.integer && right.kind == ValueKind.integer)
                {
                    return Value.from(left.integerValue - right.integerValue);
                }
                return Value.from(left.toFloat() - right.toFloat());
            case operatorCode("*"):
                if (left.kind == ValueKind.integer && right.kind == ValueKind.integer)
                {
                    return Value.from(left.integerValue * right.integerValue);
                }
                return Value.from(left.toFloat() * right.toFloat());
            case operatorCode("/"):
                return Value.from(left.toFloat() / right.toFloat());
            case operatorCode("%"):
                return Value.from(left.toInt() % right.toInt());
            case operatorCode("&"):
                return Value.from(left.toInt() & right.toInt());
            case operatorCode("|"):
                return Value.from(left.toInt() | right.toInt());
            case operatorCode("^"):
                return Value.from(left.toInt() ^ right.toInt());
            case operatorCode("<<"):
                return Value.from(left.toInt() << right.toInt());
            case operatorCode(">>"):
                return Value.from(left.toInt() >> right.toInt());
            case operatorCode("=="):
                Value overloadedEq;
                if (tryCallEqualityOverload(left, right, overloadedEq))
                {
                    return Value.from(overloadedEq.truthy());
                }
                return Value.from(valuesEqual(left, right));
            case operatorCode("!="):
                Value overloadedEq;
                if (tryCallEqualityOverload(left, right, overloadedEq))
                {
                    return Value.from(!overloadedEq.truthy());
                }
                return Value.from(!valuesEqual(left, right));
            case operatorCode("<"):
                return Value.from(left.toFloat() < right.toFloat());
            case operatorCode("<="):
                return Value.from(left.toFloat() <= right.toFloat());
            case operatorCode(">"):
                return Value.from(left.toFloat() > right.toFloat());
            case operatorCode(">="):
                return Value.from(left.toFloat() >= right.toFloat());
            default:
                enforce(false, format("Unsupported binary operator '%s'", operatorSymbol));
                assert(0);
        }
    }

    private CallSite callSite(Expression expression) const
    {
        return CallSite(evaluatorContext.moduleName, evaluatorContext.sourceName, expression.line);
    }

    // 型の照会ではgetter/関数を呼びません。不明ならlazy overload側で診断します。
    private Value unevaluatedCallable(Expression expression,Environment environment)
    {
        if(auto variable=cast(VariableExpression)expression) {
            if(auto value=environment.find(variable.name))return *value;
        }
        if(auto get=cast(GetExpression)expression) {
            auto target=unevaluatedCallable(get.target,environment);
            if(target.isFieldAggregate)
                if(auto member=target.findMember(get.memberName))return *member;
            if(!get.withMember)
                if(auto ufcs=resolveUfcs(get.memberName,environment))return *ufcs;
        }
        return Value.nullValue();
    }

    private string unevaluatedType(Expression expression,Environment environment)
    {
        if(auto variable=cast(VariableExpression)expression)return environment.bindingType(variable.name);
        if(auto literal=cast(LiteralExpression)expression)return argumentType(literal.value);
        if(cast(FunctionExpression)expression)return "function";
        if(auto cast_=cast(CastExpression)expression)return cast_.targetType;
        if(auto array=cast(ArrayExpression)expression) {
            string element;
            foreach(item;array.elements) {
                auto type=unevaluatedType(item,environment);
                if(!type.length)return "array";
                if(!element.length)element=type;
                else if(element!=type)return "array";
            }
            return element.length ? element~"[]" : "array";
        }
        if(auto call=cast(CallExpression)expression) {
            auto callable=unevaluatedCallable(call.callee,environment);
            return callable.kind==ValueKind.function_ ? callable.functionValue.resultType() : "";
        }
        if(auto binary=cast(BinaryExpression)expression) {
            switch(binary.operatorSymbol) {
                case "==":case "!=":case "<":case ">":case "<=":case ">=":case "&&":case "||":return "bool";
                default:break;
            }
            auto left=unevaluatedType(binary.left,environment);
            auto right=unevaluatedType(binary.right,environment);
            return left==right ? left : "";
        }
        if(auto unary=cast(UnaryExpression)expression)
            return unary.operatorSymbol=="!" ? "bool" : unevaluatedType(unary.operand,environment);
        if(auto ternary=cast(TernaryExpression)expression) {
            auto left=unevaluatedType(ternary.whenTrue,environment);
            return left==unevaluatedType(ternary.whenFalse,environment) ? left : "";
        }
        auto value=unevaluatedCallable(expression,environment);
        return value.kind==ValueKind.null_ ? "" : argumentType(value);
    }

    private Value referenceCallArgument(Expression expression, Environment environment)
    {
        auto variable = cast(VariableExpression) expression;
        enforce(variable !is null, "ref arguments currently require a variable");
        return Value.fromFunction(new ReferenceArgument(environment, variable.name));
    }

    private void bindReferenceParameter(Environment environment, string name, Value value, string type)
    {
        auto reference = value.kind == ValueKind.function_ ? cast(ReferenceArgument) value.functionValue : null;
        enforce(reference !is null, "Expected a ref argument for parameter: " ~ name);
        enforce(resolveContainerType(reference.type) == resolveContainerType(type),
            "ref argument type must match exactly: " ~ type ~ " (got " ~ reference.type ~ ")");
        environment.define(name, value, (Value next) {
            auto prepared = prepareContainerValue(next, type);
            enforce(valueMatchesType(prepared, type), "ref assignment expected " ~ type);
            return prepared;
        });
        environment.declareType(name, type);
    }

    private struct NamedArgumentPlan { size_t[] positions; size_t length; }

    private NamedArgumentPlan namedArgumentPlan(Value callee, string[] names, size_t offset)
    {
        auto function_ = callee.kind == ValueKind.function_ ? cast(ScriptCallable) callee.functionValue : null;
        enforce(function_ !is null, "Named arguments currently require a Dua function");
        auto fixed = function_.variadic ? function_.parameters.length - 1 : function_.parameters.length;
        enforce(offset <= fixed, "Invalid named UFCS receiver");
        NamedArgumentPlan result;
        result.length = fixed - offset;
        bool[size_t] assigned;
        size_t positional = offset;
        foreach (name; names)
        {
            size_t position;
            if (!name.length) position = positional++;
            else
            {
                position = size_t.max;
                foreach (index, parameter; function_.parameters)
                    if (parameter == name)
                    {
                        enforce(position == size_t.max, "Ambiguous parameter name: " ~ name);
                        position = index;
                    }
                enforce(position != size_t.max, "Unknown named argument: " ~ name);
                enforce(position >= offset && position < fixed, "Cannot name the receiver or variadic parameter: " ~ name);
            }
            enforce(function_.variadic || position < fixed, "Too many arguments");
            enforce((position in assigned) is null, "Parameter supplied more than once");
            assigned[position] = true;
            result.positions ~= position - offset;
            if (position - offset >= result.length) result.length = position - offset + 1;
        }
        return result;
    }

    private Value[] namedCallArguments(Value callee, Expression[] expressions, string[] names,
        Environment environment, size_t offset)
    {
        auto plan = namedArgumentPlan(callee, names, offset);
        auto values = new Value[plan.length];
        foreach (ref value; values) value = omittedArgumentValue();
        foreach (index, expression; expressions)
        {
            auto position = plan.positions[index];
            values[position] = callee.functionValue.refParameter(position + offset)
                ? referenceCallArgument(expression, environment)
                : callee.functionValue.lazyParameter(position + offset)
                ? Value.fromFunction(new ExpressionArgument(this, environment, expression))
                : evaluate(expression, environment);
        }
        return values;
    }

    private Value[] callArguments(Value callee, Expression[] expressions, Environment environment, size_t offset=0, string[] names=null)
    {
        if (callee.isFieldAggregate)
        {
            if (auto method=callee.findMember("opCall")) callee=*method;
            else {
                Value method;
                if (lookupMetamethod(callee,"__call",method)) { callee=method; ++offset; }
            }
        }
        if (names.length) return namedCallArguments(callee, expressions, names, environment, offset);
        Value[] args;
        foreach(index, expression;expressions)
            args ~= callee.kind==ValueKind.function_ && callee.functionValue.refParameter(index+offset)
                ? referenceCallArgument(expression,environment)
                : callee.kind==ValueKind.function_ && callee.functionValue.lazyParameter(index+offset)
                ? Value.fromFunction(new ExpressionArgument(this,environment,expression))
                : evaluate(expression,environment);
        return args;
    }

    private Value evaluateCall(Expression calleeExpression, Expression[] expressions, Environment environment,
        CallSite caller, string[] names = null)
    {
        if (calleeExpression.kind == Expression.Kind.get)
        {
            auto get = cast(GetExpression) calleeExpression;
            // UFCSの先頭引数もlazyならreceiver式を先に実行してはいけません。
            if(!get.nullConditional && !get.withMember) if(auto ufcs=resolveUfcs(get.memberName,environment))
            {
                if(ufcs.functionValue.lazyParameter(0)) {
                    auto known=unevaluatedCallable(get.target,environment);
                    auto member=known.isFieldAggregate ? known.findMember(get.memberName) : null;
                    if(member is null) {
                        auto type=unevaluatedType(get.target,environment);
                        import std.algorithm : canFind;
                        enforce(known.isFieldAggregate || ["int","long","uint","ulong","float","double","bool","string","array"].canFind(type),
                            "Cannot resolve lazy UFCS receiver without evaluation; use an explicit function call");
                        Value[] args=[Value.fromFunction(new ExpressionArgument(this,environment,get.target))];
                        args~=callArguments(*ufcs,expressions,environment,1,names);
                        return invokeFunctionValue(*ufcs,args,caller);
                    }
                }
            }
            auto receiver = evaluate(get.target, environment);
            if (get.nullConditional && receiver.isNullReference) return Value.nullValue();
            Value callee;
            size_t offset;
            if (receiver.isFieldAggregate)
                if (auto method=receiver.findMember(get.memberName)) callee=*method;
            if (callee.kind==ValueKind.null_ && !get.withMember)
                if (auto ufcs=resolveUfcs(get.memberName,environment)) {callee=*ufcs;offset=1;}
            auto args=callArguments(callee,expressions,environment,offset,names);
            return callMethodOrUfcs(receiver, get.memberName, args, environment, caller, !get.withMember);
        }

        auto callee=evaluate(calleeExpression,environment);
        return invokeCallableValue(callee,callArguments(callee,expressions,environment,0,names),caller);
    }

    private Value invokeCallableValue(Value callee, Value[] args, CallSite caller)
    {
        if (callee.isFieldAggregate)
        {
            if (auto method = callee.findMember("opCall"))
                if (method.kind == ValueKind.function_)
                    return invokeFunctionValueWithThis(*method, args, callee, caller);
        }
        if (callee.isFieldAggregate)
        {
            Value callValue;
            if (lookupMetamethod(callee, "__call", callValue))
            {
                Value[] bridgedArgs = [callee];
                bridgedArgs ~= args;
                return invokeFunctionValue(callValue, bridgedArgs, caller);
            }
        }
        return invokeFunctionValue(callee, args, caller);
    }

    private Value callMethodOrUfcs(Value receiver, string functionName, Value[] args,
        Environment environment, CallSite caller, bool allowUfcs=true)
    {
        enforce(receiver.kind != ValueKind.null_, "Cannot call member '" ~ functionName ~ "' on null");
        if (receiver.kind == ValueKind.associativeArray)
        {
            if (functionName == "keys" || functionName == "values" || functionName == "length")
            {
                enforce(args.length == 0, functionName ~ " expects no arguments");
                return associativeProperty(receiver, functionName);
            }
            if (functionName == "contains" || functionName == "remove" || functionName == "get")
            {
                enforce(args.length == (functionName == "get" ? 2 : 1), "Invalid associative array method arity");
                foreach (ref arg; args) arg = forceArgument(arg);
                auto key = checkedAssociativeKey(receiver, args[0]);
                if (functionName == "remove") return Value.from(receiver.associativeRemove(key));
                auto position = receiver.associativeIndex(key);
                if (functionName == "contains") return Value.from(position != size_t.max);
                if (position != size_t.max) return receiver.associativeEntries[position].value.valueCopy();
                auto fallback = prepareContainerValue(args[1], receiver.associativeValueType);
                enforce(valueMatchesType(fallback, receiver.associativeValueType),
                    typeMismatchMessage(receiver.associativeValueType, "Associative array default value expected " ~ receiver.associativeValueType));
                return fallback.valueCopy();
            }
        }
        if (receiver.isFieldAggregate)
        {
            if (auto method = receiver.findMember(functionName))
            {
                if (method.isFieldAggregate)
                    return invokeCallableValue(*method, args, caller);
                enforce(method.kind == ValueKind.function_,
                    format("Property '%s' exists but is not callable", functionName));
                return invokeFunctionValueWithThis(*method, args, receiver, caller);
            }
        }

        if (allowUfcs) if (auto ufcsFunction = resolveUfcs(functionName, environment))
        {
            Value[] ufcsArgs = [receiver];
            ufcsArgs ~= args;
            return invokeFunctionValue(*ufcsFunction, ufcsArgs, caller);
        }

        enforce(false, format("No method or UFCS function named '%s'", functionName));
        assert(0);
    }

    private Value invokeFunctionValueWithThis(Value callable, Value[] args, Value thisValue,
        CallSite caller = CallSite.init)
    {
        evaluatorContext.thisContextStack.push(thisValue);
        scope (exit)
        {
            evaluatorContext.thisContextStack.pop();
        }
        return invokeFunctionValue(callable.withReceiver(thisValue), args, caller);
    }

    private bool hasThisContext() const
    {
        return evaluatorContext.thisContextStack.length > 0;
    }

    private Value currentThisContext() const
    {
        assert(evaluatorContext.thisContextStack.length > 0);
        return cast(Value) evaluatorContext.thisContextStack.top();
    }

    private bool tryCallBinaryOverload(string operatorSymbol, Value left, Value right, out Value result)
    {
        if (left.isFieldAggregate)
        {
            auto slot = binaryOperatorSlot(operatorSymbol, false);
            Value functionValue;
            if (lookupMetamethod(left, slot, functionValue))
            {
                result = callTableBinaryOverload(functionValue, left, right);
                return true;
            }
        }
        if (right.isFieldAggregate)
        {
            auto slot = binaryOperatorSlot(operatorSymbol, true);
            Value functionValue;
            if (lookupMetamethod(right, slot, functionValue))
            {
                result = callTableBinaryOverload(functionValue, right, left);
                return true;
            }
        }
        return false;
    }

    private bool tryCallUnaryOverload(string operatorSymbol, Value operand, out Value result)
    {
        if (!operand.isFieldAggregate)
        {
            return false;
        }

        auto slot = operatorSymbol == "-" ? "opUnary-"
            : operatorSymbol == "!" ? "opUnary!" : "opUnary" ~ operatorSymbol;
        Value functionValue;
        if (!lookupMetamethod(operand, slot, functionValue))
        {
            return false;
        }

        enforce(functionValue.kind == ValueKind.function_,
            "Table unary operator overload must be a function value");
        result = invokeFunctionValue(functionValue, [operand]);
        return true;
    }

    private bool tryCallEqualityOverload(Value left, Value right, out Value result)
    {
        if (left.isFieldAggregate)
        {
            Value functionValue;
            if (lookupMetamethod(left, "__eq", functionValue))
            {
                result = callTableBinaryOverload(functionValue, left, right);
                return true;
            }
        }
        if (right.isFieldAggregate)
        {
            Value functionValue;
            if (lookupMetamethod(right, "__eq", functionValue))
            {
                result = callTableBinaryOverload(functionValue, right, left);
                return true;
            }
        }
        return false;
    }

    private Value callTableBinaryOverload(Value functionValue, Value selfValue, Value otherValue)
    {
        enforce(functionValue.kind == ValueKind.function_,
            "Table operator overload must be a function value");
        Value[] args = [selfValue, otherValue];
        return invokeFunctionValue(functionValue, args);
    }

    private Value invokeFunctionValue(Value callable, Value[] args, CallSite caller = CallSite.init)
    {
        enforce(callable.kind == ValueKind.function_, "Only functions are callable");
        auto maximumDepth = evaluatorContext.currentRunOptions.limits.maxCallDepth;
        if (maximumDepth != 0 && evaluatorContext.callStack.length >= maximumDepth)
            throw new CallDepthLimitException(maximumDepth);
        auto name = callable.functionValue.debugName;
        evaluatorContext.callStack.push(name);
        scope (exit)
        {
            if (evaluatorContext.callStack.length > 0)
            {
                evaluatorContext.callStack.pop();
            }
        }
        try
        {
            args = copyValues(args);
            args=callable.functionValue.prepareArguments(args);
            return callable.invoke(args, caller).valueCopy();
        }
        catch (Exception error)
        {
            evaluatorContext.lastErrorStack = evaluatorContext.callStack.snapshot();
            throw error;
        }
    }

    private string stringify(Value value)
    {
        if (value.isFieldAggregate)
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

    private Value delegate(Value) containerValidator(string declaredType)
    {
        if (hasLiteralConstraint(declaredType) || hasNonNullConstraint(declaredType) || hasContainerConstraint(declaredType) || hasFloatingPromotion(declaredType))
            return (Value next) {
                auto prepared = prepareContainerValue(next, declaredType);
                enforce(valueMatchesType(prepared, declaredType),
                    typeMismatchMessage(declaredType, "Assignment expected " ~ declaredType));
                return prepared;
            };
        return (Value next) => prepareContainerValue(next, declaredType);
    }

    private Value prepareArrayElement(Value value, string type)
    {
        string element, key;
        // Preserve references to already typed nested arrays; untyped inputs still need normalization.
        if (value.kind == ValueKind.array && splitContainerType(resolveContainerType(type), element, key)
            && !key.length && value.arrayElementType == element) return value;
        return prepareContainerValue(value, type);
    }

    private Value checkedAssociativeKey(Value container, Value key)
    {
        key = prepareContainerValue(key, container.associativeKeyType);
        enforce(valueMatchesType(key, container.associativeKeyType),
            typeMismatchMessage(container.associativeKeyType, "Associative array key expected " ~ container.associativeKeyType));
        return key.keyCopy();
    }

    private Value associativeProperty(Value container, string name)
    {
        if (name == "length") return Value.from(cast(long) container.associativeEntries.length);
        enforce(name == "keys" || name == "values", "Unknown associative array property: " ~ name);
        Value[] items;
        foreach (entry; container.associativeEntries)
            items ~= name == "keys" ? entry.key.keyCopy() : entry.value.valueCopy();
        return Value.from(items);
    }

    private bool canMeasureLength(Value value) const
    {
        return value.kind == ValueKind.array
            || value.kind == ValueKind.associativeArray
            || value.kind == ValueKind.table
            || value.kind == ValueKind.string_;
    }

    private long measuredLength(Value value)
    {
        if (value.kind == ValueKind.associativeArray) return cast(long) value.associativeEntries.length;
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

    private Value iotaValue(scope const(Value)[] args)
    {
        enforce(args.length >= 1 && args.length <= 3,
            "iota(end), iota(start, end), or iota(start, end, step) expects one to three arguments");
        foreach (arg; args)
        {
            enforce(arg.kind == ValueKind.integer, "iota bounds must be integers");
        }

        auto start = args.length == 1 ? 0L : args[0].integerValue;
        auto end = args.length == 1 ? args[0].integerValue : args[1].integerValue;
        auto step = args.length == 3 ? args[2].integerValue : 1L;
        enforce(step != 0, "iota step must not be zero");
        ulong count;
        if (step > 0 ? start < end : start > end)
        {
            // Unsigned differences handle ranges spanning both signed limits;
            // unsigned negation also handles a step equal to long.min.
            auto distance = step > 0 ? cast(ulong) end - cast(ulong) start
                : cast(ulong) start - cast(ulong) end;
            auto stride = step > 0 ? cast(ulong) step : 0UL - cast(ulong) step;
            count = distance / stride + (distance % stride != 0);
        }
        if (count <= size_t.max / Value.sizeof)
        {
            Value result;
            result.kind = ValueKind.array;
            result.arrayValue.length = cast(size_t) count;
            auto current = start;
            foreach (index, ref value; result.arrayValue)
            {
                value = Value.from(current);
                if (index + 1 < result.arrayValue.length) current += step;
            }
            return result;
        }
        // Preserve incremental behavior when the computed size cannot be
        // represented as one allocation on this platform.
        Value[] values;
        for (auto value = start; step > 0 ? value < end : value > end;)
        {
            values ~= Value.from(value);
            if ((step > 0 && value > long.max - step)
                || (step < 0 && value < long.min - step))
            {
                break;
            }
            value += step;
        }
        return Value.fromOwnedArray(values);
    }

    private Value[] extractTypeChain(Value value)
    {
        Value[] chain;
        if (value.isFieldAggregate)
        {
            foreach (name; value.typeChain)
                chain ~= Value.from(name.toHostString());
        }
        return chain;
    }

    private Value buildTypeInfo(Value value)
    {
        auto chain = extractTypeChain(value);
        Value[] aliasThisChain;
        if (value.isFieldAggregate)
            foreach (name; value.aliasThisChain)
                aliasThisChain ~= Value.from(name.toHostString());
        Value[string] info;
        info["kind"] = Value.from(value.kind.to!string);
        info["chain"] = Value.from(chain.dup);
        info["aliasThisChain"] = Value.from(aliasThisChain);
        if (value.kind == ValueKind.associativeArray)
        {
            info["keyType"] = Value.from(value.associativeKeyType);
            info["valueType"] = Value.from(value.associativeValueType);
        }
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
        table.clearDeclaredMetatable();
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
            table.setTypeChain([]);
            return table;
        }

        Value[] typeChain;
        foreach (typeName; args[2 .. $])
        {
            typeChain ~= Value.from((cast(Value) typeName).toHostString());
        }
        table.setTypeChain(typeChain);
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
            mapped.length = collection.arrayValue.length;
            foreach (index, item; collection.arrayValue)
            {
                mapped[index] = invokeCollectionCallback(mapper, item, Value.from(cast(long) index));
            }
            return Value.fromOwnedArray(mapped);
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
            return Value.fromOwnedArray(filtered);
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
        if (auto functionValue = environment.find(functionName))
            if (functionValue.kind == ValueKind.function_) return functionValue;
        // A non-callable local still falls back to the global function.
        if (auto functionValue = globals.find(functionName))
            if (functionValue.kind == ValueKind.function_) return functionValue;
        return null;
    }

    private bool resolveTableIndex(Value container, string key, out Value resolved)
    {
        Value getter;
        if (container.isClassReference && container.lookupPropertyGetter(key, getter))
        {
            resolved = invokeFunctionValueWithThis(getter, [], container);
            return true;
        }
        if (auto direct = container.findMember(key))
        {
            resolved = direct.withReceiver(container);
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
        if (auto directMeta = container.findMember("__newindex"))
        {
            if (directMeta.kind == ValueKind.function_)
            {
                invokeFunctionValue(directMeta.withReceiver(container), [container, Value.from(key), value]);
                return true;
            }
            if (directMeta.kind == ValueKind.table)
            {
                directMeta.tableValue[key] = value.valueCopy();
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
                                nested.tableValue[key] = value.valueCopy();
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
        if (auto direct = container.findMember(key))
        {
            method = direct.withReceiver(container);
            return true;
        }

        auto meta=container.effectiveMetatable();
        if (meta.kind == ValueKind.table)
        {
            if (auto nested = key in meta.tableValue)
            {
                method = *nested;
                return true;
            }
        }
        return false;
    }

}
