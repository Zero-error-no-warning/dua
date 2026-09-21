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
import std.conv : to;
import std.exception : enforce;
import std.format : format;
import std.math : floor;

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
struct EvaluatorContext
{
    package string sourceName;
    package EvaluationStack!string callStack;
    package string[] lastErrorStack;
    package EvaluationStack!long indexLengthStack;
    package EvaluationStack!Value thisContextStack;
    package RunOptions currentRunOptions;
    package size_t executedSteps;
}

final class Environment
{
    Environment parent;
    private struct Binding
    {
        Value value;
        Value delegate(Value) validator;
    }
    private Binding[string] bindings;

    this(Environment parent = null)
    {
        this.parent = parent;
    }

    void define(string name, Value value, Value delegate(Value) validator = null)
    {
        enforce((name in bindings) is null,
            format("Variable '%s' is already defined in this scope", name));
        bindings[name] = Binding(value.valueCopy(), validator);
    }

    bool contains(string name) const
    {
        import std.typecons : Rebindable;
        for (auto environment = Rebindable!(const Environment)(this);
            environment !is null; environment = environment.parent)
            if ((name in environment.bindings) !is null) return true;
        return false;
    }

    Value get(string name)
    {
        if (auto value = find(name)) return *value;
        enforce(false, format("Undefined variable '%s'", name));
        assert(0);
    }

    Value* find(string name)
    {
        for (auto environment = this; environment !is null; environment = environment.parent)
            if (auto binding = name in environment.bindings) return &binding.value;
        return null;
    }

    void assign(string name, Value value)
    {
        for (auto environment = this; environment !is null; environment = environment.parent)
        {
            if (auto binding = name in environment.bindings)
            {
                if (binding.validator !is null) value = binding.validator(value);
                binding.value = value.valueCopy();
                return;
            }
        }
        enforce(false, format("Cannot assign undefined variable '%s'", name));
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
                            value = prepareContainerValue(value, statement.declaredType);
                            enforce(valueMatchesType(value, statement.declaredType),
                                format("Variable '%s' expected %s but got %s",
                                    name, statement.declaredType, value.kind));
                        }
                        auto declaredType = statement.declaredType;
                        string elementType, keyType;
                        if (splitContainerType(resolveContainerType(declaredType), elementType, keyType))
                            environment.define(name, value, containerValidator(declaredType));
                        else
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
                case Statement.Kind.tableDecl:
                    registerTypeAlias(statement);
                    result.lastValue = Value.nullValue();
                    break;
                case Statement.Kind.structDecl:
                    registerStructType(statement);
                    result.lastValue = Value.nullValue();
                    break;
                case Statement.Kind.try_:
                    try
                    {
                        result = executeStatements(statement.body, new Environment(environment));
                    }
                    catch (Exception error)
                    {
                        if (cast(ExecutionLimitException) error !is null)
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
                        auto catchEnvironment = new Environment(environment);
                        catchEnvironment.define(statement.name, Value.from(errorInfo));
                        result = executeStatements(statement.elseBranch.body, catchEnvironment);
                    }
                    break;
                case Statement.Kind.assign:
                    if (statement.assignmentOperator.length)
                    {
                        Value left;
                        auto target = resolveCompoundTarget(statement.target, environment, left);
                        auto right = evaluate(statement.expression, environment);
                        auto value = evaluateBinary(statement.assignmentOperator, left, right);
                        assignTarget(target, value, environment);
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
                        statement.parameterTypes, statement.returnType));
                    environment.define(statement.name, callable);
                    result.lastValue = callable;
                    if (statement.isExported)
                    {
                        exportSymbol(statement.name, callable);
                    }
                    break;
                case Statement.Kind.import_:
                    auto imported = requireModuleHandle(statement.name).exportsValue();
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
                    else if (iterable.kind == ValueKind.associativeArray)
                    {
                        foreach (entry; (cast(AssociativeEntry[]) iterable.associativeEntries).dup)
                        {
                            auto itemEnvironment = new Environment(environment);
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
            throw withSourceContext(error, evaluatorContext.sourceName, location, "statement");
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
                auto container = evaluate(property.target, environment);
                resolved = new GetExpression(new LiteralExpression(container), property.memberName);
                resolved.line = target.line;
                resolved.column = target.column;
                current = evaluate(resolved, environment);
                break;
            case Expression.Kind.index:
                auto indexed = cast(IndexExpression) target;
                enforce(!indexed.isSlice, "Slice cannot be an assignment target");
                auto container = evaluate(indexed.target, environment);
                auto pushedLength = canMeasureLength(container);
                if (pushedLength) evaluatorContext.indexLengthStack.push(measuredLength(container));
                scope (exit)
                {
                    if (pushedLength) evaluatorContext.indexLengthStack.pop();
                }
                auto index = evaluate(indexed.index, environment);
                resolved = new IndexExpression(new LiteralExpression(container), new LiteralExpression(index));
                current = readIndex(container, index);
                break;
            default:
                enforce(false, "Invalid compound assignment target");
        }
        resolved.line = target.line;
        resolved.column = target.column;
        return resolved;
    }

    private void assignTarget(Expression target, Value value, Environment environment)
    {
        try
        {
            switch (target.kind)
            {
                case Expression.Kind.variable:
                    environment.assign((cast(VariableExpression) target).name, value);
                    return;
                case Expression.Kind.get:
                    auto get = cast(GetExpression) target;
                    auto container = evaluate(get.target, environment);
                    enforce(container.isFieldAggregate,
                        "Property assignment currently supports tables/reflected structs/classes");
                    if (auto property = get.memberName in container.tableValue)
                    {
                        if (property.kind == ValueKind.function_
                            && property.functionValue.acceptsArity(1))
                        {
                            invokeFunctionValueWithThis(*property, [value], container);
                            return;
                        }
                    }
                    if (auto setter = container.propertySetter(get.memberName))
                    {
                        invokeFunctionValue(*setter, [value]);
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
                    enforce(!indexed.isSlice, "Slice cannot be an assignment target");
                    auto index = evaluate(indexed.index, environment);
                    if (container.kind == ValueKind.associativeArray)
                    {
                        index = checkedAssociativeKey(container, index);
                        value = prepareContainerValue(value, container.associativeValueType);
                        enforce(valueMatchesType(value, container.associativeValueType),
                            "Associative array value expected " ~ container.associativeValueType);
                        container.associativeSet(index, value);
                        return;
                    }
                    if (container.kind == ValueKind.array)
                    {
                        auto position = cast(size_t) index.toInt();
                        enforce(position < container.arrayValue.length, "Array index out of range");
                        container.arrayValue[position] = value.valueCopy();
                        return;
                    }
                    if (container.isFieldAggregate)
                    {
                        auto key = index.toHostString();
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
            throw withSourceContext(error, evaluatorContext.sourceName, location, "assignment");
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
                    return (cast(LiteralExpression) expression).value;
                case Expression.Kind.variable:
                    return environment.get((cast(VariableExpression) expression).name);
                case Expression.Kind.cast_:
                    auto conversion = cast(CastExpression) expression;
                    return castValue(evaluate(conversion.operand, environment), conversion.targetType);
                case Expression.Kind.unary:
                    auto unary = cast(UnaryExpression) expression;
                    switch (unary.operatorSymbol)
                    {
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
                    auto binary = cast(BinaryExpression) expression;
                    if (binary.operatorSymbol == "is")
                    {
                        return Value.from(valueIsType(
                            evaluate(binary.left, environment), (cast(VariableExpression) binary.right).name));
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
                case Expression.Kind.ternary:
                    auto ternary = cast(TernaryExpression) expression;
                    return evaluate(ternary.condition, environment).truthy()
                        ? evaluate(ternary.whenTrue, environment)
                        : evaluate(ternary.whenFalse, environment);
                case Expression.Kind.call:
                    auto call = cast(CallExpression) expression;
                    auto args = evaluateExpressionList(call.arguments, environment);
                    return evaluateCall(call.callee, args, environment);
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
                    Value[string] entries;
                    foreach (entry; (cast(TableExpression) expression).entries)
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
                    auto functionExpression = cast(FunctionExpression) expression;
                    return Value.fromFunction(new ScriptCallable("anonymous", this, environment,
                        functionExpression.parameters, functionExpression.variadic, functionExpression.body,
                        functionExpression.parameterTypes, functionExpression.returnType));
                case Expression.Kind.get:
                    auto get = cast(GetExpression) expression;
                    auto container = evaluate(get.target, environment);
                    if (container.kind == ValueKind.associativeArray)
                        return associativeProperty(container, get.memberName);
                    enforce(container.isFieldAggregate,
                        "Property access currently supports tables/reflected structs/classes");
                    if (auto getter = container.propertyGetter(get.memberName))
                    {
                        auto refreshed = invokeFunctionValueWithThis(*getter, [], container);
                        auto property = get.memberName in container.tableValue;
                        if (property is null || property.kind != ValueKind.function_)
                        {
                            container.tableValue[get.memberName] = refreshed;
                        }
                        return refreshed;
                    }
                    if (auto value = get.memberName in container.tableValue)
                    {
                        if (value.kind == ValueKind.function_
                            && value.functionValue.acceptsArity(0))
                        {
                            return invokeFunctionValueWithThis(*value, [], container);
                        }
                        return *value;
                    }
                    Value resolved;
                    if (resolveTableIndex(container, get.memberName, resolved))
                    {
                        return resolved;
                    }
                    enforce(false, format("Unknown property '%s'", get.memberName));
                    assert(0);
                case Expression.Kind.index:
                    auto indexed = cast(IndexExpression) expression;
                    auto container = evaluate(indexed.target, environment);
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
                        Value[] sliced;
                        if (lowerBound < upperBound)
                        {
                            sliced = container.arrayValue[lowerBound .. upperBound].dup;
                        }
                        return Value.fromOwnedArray(sliced);
                    }
                    auto index = evaluate(indexed.index, environment);
                    return readIndex(container, index);
            }
        }
        catch (Exception error)
        {
            auto location = expressionLocation(expression);
            throw withSourceContext(error, evaluatorContext.sourceName, location, "expression");
        }
    }

    private Value readIndex(Value container, Value index)
    {
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
        enforce(false, "Indexing currently supports arrays and tables");
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

    private Value castValue(Value value, string targetType, size_t depth = 0)
    {
        enforce(depth < 64, "Cyclic or excessively nested cast type alias");
        string elementType, keyType;
        if (splitContainerType(resolveContainerType(targetType), elementType, keyType))
            return prepareContainerValue(value, targetType);
        // A pure alias uses the same conversion as its target. Union casts
        // only check membership, since choosing a conversion would be ambiguous.
        if (auto definition = findTypeDefinition(targetType))
        {
            if (!definition.tableValue["isTable"].truthy())
            {
                auto alternatives = definition.tableValue["alternatives"].arrayValue;
                if (alternatives.length == 1)
                    return castValue(value, alternatives[0].toHostString(), depth + 1);
            }
        }
        switch (targetType)
        {
            case "int":
                if (value.kind == ValueKind.boolean)
                    return Value.from(value.booleanValue ? 1 : 0);
                if (value.kind == ValueKind.string_)
                    return Value.from(value.stringValue.to!long);
                if (value.kind == ValueKind.floating)
                    enforce(value.floatingValue >= -9223372036854775808.0
                        && value.floatingValue < 9223372036854775808.0,
                        "Cannot cast non-finite or out-of-range double to int");
                return Value.from(value.toInt());
            case "double":
                if (value.kind == ValueKind.boolean)
                    return Value.from(value.booleanValue ? 1.0 : 0.0);
                if (value.kind == ValueKind.string_)
                    return Value.from(value.stringValue.to!double);
                return Value.from(value.toFloat());
            case "bool": return Value.from(value.truthy());
            case "string": return Value.from(value.toHostString());
            case "array":
                if (value.kind == ValueKind.array) return value;
                break;
            case "table":
                if (value.kind == ValueKind.table) return value;
                break;
            case "function":
                if (value.kind == ValueKind.function_) return value;
                break;
            default:
                if (valueMatchesType(value, targetType)) return value.valueCopy();
                break;
        }
        enforce(false, format("Cannot cast %s to %s", value.kind, targetType));
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
        string location = "", string context = "source")
    {
        auto contextual = cast(SourceException) error;
        if (contextual !is null && contextual.hasSourceContext)
            return error;
        if (contextual is null)
            contextual = new SourceException(error.msg, error);
        auto origin = sourceName.length > 0 ? sourceName : "<global>";
        if (location.length > 0) origin ~= ":" ~ location;
        contextual.msg = format("[%s @ %s] %s", context, origin, error.msg);
        contextual.hasSourceContext = true;
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
                if (left.kind == ValueKind.array && right.kind == ValueKind.array)
                {
                    auto combined = left.arrayValue.dup;
                    combined ~= right.arrayValue;
                    return Value.fromOwnedArray(combined);
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

    private Value evaluateCall(Expression calleeExpression, Value[] args, Environment environment)
    {
        if (calleeExpression.kind == Expression.Kind.get)
        {
            auto get = cast(GetExpression) calleeExpression;
            auto receiver = evaluate(get.target, environment);
            return callMethodOrUfcs(receiver, get.memberName, args, environment);
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
                auto key = checkedAssociativeKey(receiver, args[0]);
                if (functionName == "remove") return Value.from(receiver.associativeRemove(key));
                auto position = receiver.associativeIndex(key);
                if (functionName == "contains") return Value.from(position != size_t.max);
                if (position != size_t.max) return receiver.associativeEntries[position].value.valueCopy();
                auto fallback = prepareContainerValue(args[1], receiver.associativeValueType);
                enforce(valueMatchesType(fallback, receiver.associativeValueType),
                    "Associative array default value expected " ~ receiver.associativeValueType);
                return fallback.valueCopy();
            }
        }
        if (receiver.isFieldAggregate)
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
        evaluatorContext.thisContextStack.push(thisValue);
        scope (exit)
        {
            evaluatorContext.thisContextStack.pop();
        }
        return invokeFunctionValue(callable, args);
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

    private Value invokeFunctionValue(Value callable, Value[] args)
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
            return callable.functionValue.invoke(copyValues(args)).valueCopy();
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
        return (Value next) => prepareContainerValue(next, declaredType);
    }

    private Value checkedAssociativeKey(Value container, Value key)
    {
        key = prepareContainerValue(key, container.associativeKeyType);
        enforce(valueMatchesType(key, container.associativeKeyType),
            "Associative array key expected " ~ container.associativeKeyType);
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

}
