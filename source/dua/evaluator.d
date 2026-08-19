module dua.evaluator;

/**
 * Internal execution/evaluation layer for Dua.
 *
 * `EvaluatorImplementation` is mixed into the owning runtime so evaluator code
 * can use the deliberately narrow set of runtime hooks (module loading, type
 * registration, coroutine state, and execution limits) without exposing the
 * ScriptEngine's private storage. Runtime orchestration depends on this module;
 * this module does not import `dua.runtime`.
 */

import dua.ast;
import dua.execution;
import dua.value;
import core.thread : Fiber;
import std.algorithm : map;
import std.array : array;
import std.exception : enforce;
import std.format : format;
import std.math : floor;
import std.string : startsWith;

package final class ScriptThrownException : Exception
{
    Value thrownValue;

    this(Value value, string message)
    {
        super(message);
        thrownValue = value;
    }
}

/// Mutable state that belongs exclusively to evaluation of a run.
/// Keeping it together prevents evaluator internals from becoming ScriptEngine API.
struct EvaluatorContext
{
    package string[] callStack;
    package string[] lastErrorStack;
    package long[] indexLengthStack;
    package Value[] thisContextStack;
    package RunOptions currentRunOptions;
    package size_t executedSteps;
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
        values[name] = value.valueCopy();
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
            *slot = value.valueCopy();
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
                        auto trace = evaluatorContext.lastErrorStack.length > 0 ? evaluatorContext.lastErrorStack : evaluatorContext.callStack;
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
        catch (ExecutionLimitException error)
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
                    enforce(container.isFieldAggregate,
                        "Property assignment currently supports tables/reflected structs/classes");
                    if (auto property = target.identifier in container.tableValue)
                    {
                        if (property.kind == ValueKind.function_
                            && property.functionValue.acceptsArity(1))
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
                        container.tableValue[target.identifier] = value.valueCopy();
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
        catch (ScriptThrownException error)
        {
            throw error;
        }
        catch (ExecutionLimitException error)
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
                            enforce(evaluatorContext.indexLengthStack.length > 0, "$ is only available inside index expressions");
                            return Value.from(evaluatorContext.indexLengthStack[$ - 1]);
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
                                    || spreadKey == internalAliasThisChain
                                    || spreadKey == internalAliasThisTargets
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
                    enforce(container.isFieldAggregate,
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
                            && value.functionValue.acceptsArity(0))
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
                        evaluatorContext.indexLengthStack ~= measuredLength(container);
                        pushedLengthContext = true;
                    }
                    scope (exit)
                    {
                        if (pushedLengthContext)
                        {
                            evaluatorContext.indexLengthStack.length = evaluatorContext.indexLengthStack.length - 1;
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
                    if (container.isFieldAggregate)
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
        catch (ExecutionLimitException error)
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
        evaluatorContext.thisContextStack ~= thisValue;
        scope (exit)
        {
            evaluatorContext.thisContextStack.length = evaluatorContext.thisContextStack.length - 1;
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
        return cast(Value) evaluatorContext.thisContextStack[$ - 1];
    }

    private Value* tryCallBinaryOverload(string operatorSymbol, Value left, Value right)
    {
        if (left.isFieldAggregate)
        {
            auto slot = "opBinary" ~ operatorSymbol;
            Value functionValue;
            if (lookupMetamethod(left, slot, functionValue))
            {
                return callTableBinaryOverload(functionValue, left, right);
            }
        }
        if (right.isFieldAggregate)
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
        if (!operand.isFieldAggregate)
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
        if (left.isFieldAggregate)
        {
            Value functionValue;
            if (lookupMetamethod(left, "__eq", functionValue))
            {
                return callTableBinaryOverload(functionValue, left, right);
            }
        }
        if (right.isFieldAggregate)
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
        auto maximumDepth = evaluatorContext.currentRunOptions.limits.maxCallDepth;
        if (maximumDepth != 0 && evaluatorContext.callStack.length >= maximumDepth)
            throw new CallDepthLimitException(maximumDepth);
        auto name = callable.functionValue.debugName;
        evaluatorContext.callStack ~= name;
        scope (exit)
        {
            if (evaluatorContext.callStack.length > 0)
            {
                evaluatorContext.callStack.length = evaluatorContext.callStack.length - 1;
            }
        }
        try
        {
            Value[] copiedArgs;
            foreach (arg; args) copiedArgs ~= arg.valueCopy();
            return callable.functionValue.invoke(copiedArgs).valueCopy();
        }
        catch (Exception error)
        {
            evaluatorContext.lastErrorStack = evaluatorContext.callStack.dup;
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
        return Value.from(values);
    }

    private Value[] extractTypeChain(Value value)
    {
        Value[] chain;
        if (value.isFieldAggregate)
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
        Value[] aliasThisChain;
        if (value.isFieldAggregate)
            if (auto reflected = internalAliasThisChain in value.tableValue)
                if (reflected.kind == ValueKind.array)
                    foreach (name; reflected.arrayValue)
                        aliasThisChain ~= Value.from(name.toHostString());
        Value[string] info;
        info["kind"] = Value.from(value.kind.to!string);
        info["chain"] = Value.from(chain.dup);
        info["aliasThisChain"] = Value.from(aliasThisChain);
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
