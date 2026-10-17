module dua.typecheck;

import dua.ast;
import dua.execution : CheckDiagnostic;
import dua.lexer : lex;
import dua.parser : parse;
import dua.value : ValueKind;
import dua.type_syntax;
import std.algorithm : canFind;
import std.format : format;

private struct StaticFunctionInfo
{
    string[] parameterTypes;
    string returnType;
}

/// Checks a source unit with the host class names registered by its engine.
package(dua) CheckDiagnostic[] checkSource(string source, string[] nativeClassTypes = null)
{
    CheckDiagnostic[] diagnostics;
    try
    {
        auto program = parse(lex(source));
        string[string] variableTypes;
        foreach (name; nativeClassTypes) variableTypes["#class_" ~ name] = "class";
        StaticFunctionInfo[string] functions;
        checkStatements(program.statements, variableTypes, functions, diagnostics, "");
    }
    catch (Exception error)
    {
        diagnostics ~= CheckDiagnostic(0, 0, error.msg);
    }
    return diagnostics;
}

private void checkStatements(Statement[] statements, ref string[string] variables,
    ref StaticFunctionInfo[string] functions, ref CheckDiagnostic[] diagnostics,
    string expectedReturnType)
{
    foreach (statement; statements)
        if (statement.kind == Statement.Kind.alias_)
            variables["#type_" ~ statement.name] = statement.names.length == 1 ? statement.names[0] : "any";
    expectedReturnType = resolveStaticType(expectedReturnType, variables);
    foreach (statement; statements)
    {
        if (statement.kind == Statement.Kind.functionDecl)
        {
            string[] parameterTypes;
            foreach (type; statement.parameterTypes) parameterTypes ~= resolveStaticType(type, variables);
            functions[statement.name] = StaticFunctionInfo(
                parameterTypes, resolveStaticType(statement.returnType, variables));
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
                        ? resolveStaticType(statement.declaredType, variables) : actual;
                    if (statement.declaredType.length > 0 && statement.declaredType != "auto"
                        && !staticTypesCompatible(actual, declared, variables))
                        addDiagnostic(diagnostics, statement,
                            format("Variable '%s' expects %s but expression has type %s",
                                name, statement.declaredType, actual));
                    // nullから始めるauto変数には、後から実体を格納できます。
                    variables[name] = declared == "auto" ? (actual == "null" ? "any" : actual) : declared;
                }
                break;
            case Statement.Kind.assign:
                foreach (index, target; statement.targets)
                {
                    auto expression = index < statement.expressions.length ? statement.expressions[index] : null;
                    if (statement.assignmentOperator.length)
                        expression = new BinaryExpression(target, statement.assignmentOperator, expression);
                    auto actual = index < statement.expressions.length
                        ? inferExpressionType(expression, variables, functions, diagnostics)
                        : "any";
                    if (target.kind == Expression.Kind.variable)
                    {
                        auto expected = (cast(VariableExpression) target).name in variables;
                        if (expected !is null && !staticTypesCompatible(actual, *expected, variables))
                            diagnostics ~= CheckDiagnostic(target.line, target.column,
                                format("Assignment to '%s' expects %s but expression has type %s",
                                    (cast(VariableExpression) target).name, *expected, actual));
                    }
                    else if (target.kind == Expression.Kind.index)
                    {
                        auto expected = inferExpressionType(target, variables, functions, diagnostics);
                        if (!staticTypesCompatible(actual, expected, variables))
                            diagnostics ~= CheckDiagnostic(target.line, target.column,
                                format("Indexed assignment expects %s but has type %s", expected, actual));
                    }
                    else if (target.kind == Expression.Kind.get)
                    {
                        auto get = cast(GetExpression) target;
                        auto container = inferExpressionType(get.target, variables, functions, diagnostics);
                        string element, key;
                        if (get.memberName == "length" && (container == "array"
                            || (splitContainerType(container, element, key) && !key.length)))
                            diagnostics ~= CheckDiagnostic(target.line, target.column, "Array length is read-only");
                    }
                }
                break;
            case Statement.Kind.return_:
                auto actual = statement.expressions.length == 0 ? "null"
                    : inferExpressionType(statement.expressions[0], variables, functions, diagnostics);
                if (expectedReturnType.length > 0)
                {
                    if (!staticTypesCompatible(actual, expectedReturnType, variables))
                        addDiagnostic(diagnostics, statement,
                            format("Return expects %s but expression has type %s",
                                expectedReturnType, actual));
                }
                break;
            case Statement.Kind.functionDecl:
                auto childVariables = variables.dup;
                foreach (index, parameter; statement.parameters)
                    childVariables[parameter] = index < statement.parameterTypes.length
                        ? resolveStaticType(statement.parameterTypes[index], variables) : "any";
                checkStatements(statement.body, childVariables, functions, diagnostics,
                    statement.returnType);
                break;
            case Statement.Kind.block:
                auto childVariables = variables.dup;
                checkStatements(statement.body, childVariables, functions, diagnostics, expectedReturnType);
                break;
            case Statement.Kind.for_:
                auto loopVariables = variables.dup;
                if (statement.init !is null)
                    checkStatements([statement.init], loopVariables, functions, diagnostics, expectedReturnType);
                if (statement.condition !is null)
                    inferExpressionType(statement.condition, loopVariables, functions, diagnostics);
                checkStatements(statement.body, loopVariables, functions, diagnostics, expectedReturnType);
                if (statement.incrementStatement !is null)
                    checkStatements([statement.incrementStatement], loopVariables, functions, diagnostics, expectedReturnType);
                break;
            case Statement.Kind.if_, Statement.Kind.while_,
                 Statement.Kind.foreach_, Statement.Kind.switch_:
                if (statement.condition !is null)
                    inferExpressionType(statement.condition, variables, functions, diagnostics);
                foreach (child; statement.body)
                {
                    auto nestedVariables = variables.dup;
                    if (statement.kind == Statement.Kind.foreach_)
                    {
                        auto iterableType = inferExpressionType(statement.iterable, variables, functions, diagnostics);
                        string element, key;
                        if (statement.rangeEnd !is null)
                        {
                            auto endType = inferExpressionType(statement.rangeEnd, variables, functions, diagnostics);
                            if ((iterableType != "int" && iterableType != "any")
                                || (endType != "int" && endType != "any"))
                                addDiagnostic(diagnostics, statement, "Range foreach bounds must be integers");
                            nestedVariables[statement.iteratorName] = "int";
                        }
                        else if (splitContainerType(iterableType, element, key))
                        {
                            nestedVariables[statement.iteratorName] = statement.iteratorSecondName.length
                                ? (key.length ? key : "int") : element;
                            if (statement.iteratorSecondName.length)
                                nestedVariables[statement.iteratorSecondName] = element;
                        }
                    }
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
            case Statement.Kind.alias_, Statement.Kind.tableDecl, Statement.Kind.structDecl,
                 Statement.Kind.break_, Statement.Kind.continue_, Statement.Kind.yield_,
                 Statement.Kind.import_, Statement.Kind.export_:
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
            final switch ((cast(LiteralExpression) expression).value.kind)
            {
                case ValueKind.integer: return "int";
                case ValueKind.floating: return "double";
                case ValueKind.boolean: return "bool";
                case ValueKind.string_: return "string";
                case ValueKind.null_: return "null";
                case ValueKind.array: return "array";
                case ValueKind.associativeArray: return "associativeArray";
                case ValueKind.table: return "table";
                case ValueKind.struct_: return "struct";
                case ValueKind.function_: return "function";
                case ValueKind.native: return "any";
            }
        case Expression.Kind.variable:
            auto found = (cast(VariableExpression) expression).name in variables;
            return found is null ? "any" : *found;
        case Expression.Kind.array: return "array";
        case Expression.Kind.associativeArray:
            auto aa = cast(AssociativeArrayExpression) expression;
            foreach (index, key; aa.keys)
            {
                inferExpressionType(key, variables, functions, diagnostics);
                inferExpressionType(aa.values[index], variables, functions, diagnostics);
            }
            return "associativeArray";
        case Expression.Kind.table: return "table";
        case Expression.Kind.function_: return "function";
        case Expression.Kind.unary:
            if ((cast(UnaryExpression) expression).operatorSymbol == "new") return "table";
            return (cast(UnaryExpression) expression).operatorSymbol == "!" ? "bool"
                : inferExpressionType((cast(UnaryExpression) expression).operand, variables, functions, diagnostics);
        case Expression.Kind.cast_:
            auto conversion = cast(CastExpression) expression;
            inferExpressionType(conversion.operand, variables, functions, diagnostics);
            return conversion.targetType;
        case Expression.Kind.binary:
            auto left = inferExpressionType((cast(BinaryExpression) expression).left, variables, functions, diagnostics);
            auto right = (cast(BinaryExpression) expression).operatorSymbol == "is" ? "any"
                : inferExpressionType((cast(BinaryExpression) expression).right, variables, functions, diagnostics);
            if (["==", "!=", "<", "<=", ">", ">=", "&&", "||", "is"].canFind((cast(BinaryExpression) expression).operatorSymbol))
                return "bool";
            auto op = (cast(BinaryExpression) expression).operatorSymbol;
            if (op == "~")
            {
                string element, key;
                auto leftArray = left == "array" || (splitContainerType(left, element, key) && !key.length);
                auto rightArray = right == "array" || (splitContainerType(right, element, key) && !key.length);
                if (leftArray && rightArray) return left;
                if (left == "any" || right == "any" || left == "table" || right == "table") return "any";
                return "string";
            }
            if (left == "any" || right == "any" || left == "table" || right == "table") return "any";
            if (op == "/") return "double";
            if (["%", "&", "|", "^", "<<", ">>"].canFind(op)) return "int";
            return left == "int" && right == "int" ? "int" : "double";
        case Expression.Kind.ternary:
            auto middle = inferExpressionType((cast(TernaryExpression) expression).whenTrue, variables, functions, diagnostics);
            auto right = inferExpressionType((cast(TernaryExpression) expression).whenFalse, variables, functions, diagnostics);
            return middle == right ? middle : "any";
        case Expression.Kind.call:
            if ((cast(CallExpression) expression).callee.kind == Expression.Kind.variable)
            {
                auto functionInfo = (cast(VariableExpression) (cast(CallExpression) expression).callee).name in functions;
                if (functionInfo !is null)
                {
                    foreach (index, argument; (cast(CallExpression) expression).arguments)
                    {
                        auto actual = inferExpressionType(argument, variables, functions, diagnostics);
                        if (index < functionInfo.parameterTypes.length
                            && !staticTypesCompatible(actual, functionInfo.parameterTypes[index], variables))
                            diagnostics ~= CheckDiagnostic(argument.line, argument.column,
                                format("Argument %s to '%s' expects %s but has type %s",
                                    index + 1, (cast(VariableExpression) (cast(CallExpression) expression).callee).name,
                                    functionInfo.parameterTypes[index], actual));
                    }
                    return functionInfo.returnType.length > 0 ? functionInfo.returnType : "any";
                }
            }
            return "any";
        case Expression.Kind.index:
            auto indexExpression = cast(IndexExpression) expression;
            auto container = inferExpressionType(indexExpression.target, variables, functions, diagnostics);
            string element, key;
            if (splitContainerType(container, element, key) && !indexExpression.isSlice)
            {
                if (indexExpression.indices.length != 1)
                {
                    diagnostics ~= CheckDiagnostic(expression.line, expression.column,
                        "Array/associative array indexing requires a single index");
                    return "any";
                }
                auto actual = inferExpressionType(indexExpression.index, variables, functions, diagnostics);
                auto expected = key.length ? key : "int";
                if (!staticTypesCompatible(actual, expected, variables))
                    diagnostics ~= CheckDiagnostic(expression.line, expression.column,
                        format("Index expects %s but has type %s", expected, actual));
                return element;
            }
            return "any";
        case Expression.Kind.get:
            auto get = cast(GetExpression) expression;
            auto targetType = inferExpressionType(get.target, variables, functions, diagnostics);
            string element, key;
            if (get.memberName == "length" && (targetType == "array"
                || splitContainerType(targetType, element, key)))
                return "int";
            return "any";
    }
}

private string resolveStaticType(string name, ref string[string] variables, size_t depth = 0)
{
    if (depth >= 64) return "any";
    if (auto aliasType = "#type_" ~ name in variables)
        return resolveStaticType(*aliasType, variables, depth + 1);
    string element, key;
    if (splitContainerType(name, element, key))
        return resolveStaticType(element, variables, depth + 1) ~ "["
            ~ (key.length ? resolveStaticType(key, variables, depth + 1) : "") ~ "]";
    return name;
}

private bool staticTypesCompatible(string actual, string expected, ref string[string] variables)
{
    if (actual == "null" && ("#class_" ~ expected in variables) !is null) return true;
    if (actual == "any" || expected == "any" || expected == "auto") return true;
    string element, key;
    if (splitContainerType(expected, element, key))
        return actual == expected || actual == (key.length ? "associativeArray" : "array")
            || (key.length && actual == "array");
    if (canFind(expected, " delegate(")) return actual == "function";
    if (!["int", "double", "bool", "string", "null", "void", "array", "table"].canFind(expected))
        return actual == "table" || actual == expected;
    return actual == expected || (expected == "void" && actual == "null");
}

private void addDiagnostic(ref CheckDiagnostic[] diagnostics, Statement statement, string message)
{
    diagnostics ~= CheckDiagnostic(statement.line, statement.column, message);
}
