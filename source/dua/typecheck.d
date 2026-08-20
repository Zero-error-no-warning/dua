module dua.typecheck;

import dua.ast;
import dua.execution : CheckDiagnostic;
import dua.lexer : lex;
import dua.parser : parse;
import dua.value : ValueKind;
import std.algorithm : canFind;
import std.format : format;

private struct StaticFunctionInfo
{
    string[] parameterTypes;
    string returnType;
}

/// Statically checks a source unit without depending on runtime engine state.
package(dua) CheckDiagnostic[] checkSource(string source)
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
                        auto expected = (cast(VariableExpression) target).name in variables;
                        if (expected !is null && !staticTypesCompatible(actual, *expected))
                            diagnostics ~= CheckDiagnostic(target.line, target.column,
                                format("Assignment to '%s' expects %s but expression has type %s",
                                    (cast(VariableExpression) target).name, *expected, actual));
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
                case ValueKind.table: return "table";
                case ValueKind.struct_: return "struct";
                case ValueKind.function_: return "function";
                case ValueKind.native: return "any";
            }
        case Expression.Kind.variable:
            auto found = (cast(VariableExpression) expression).name in variables;
            return found is null ? "any" : *found;
        case Expression.Kind.array: return "array";
        case Expression.Kind.table: return "table";
        case Expression.Kind.function_: return "function";
        case Expression.Kind.unary:
            return (cast(UnaryExpression) expression).operatorSymbol == "!" ? "bool"
                : inferExpressionType((cast(UnaryExpression) expression).operand, variables, functions, diagnostics);
        case Expression.Kind.binary:
            auto left = inferExpressionType((cast(BinaryExpression) expression).left, variables, functions, diagnostics);
            auto right = (cast(BinaryExpression) expression).operatorSymbol == "is" ? "any"
                : inferExpressionType((cast(BinaryExpression) expression).right, variables, functions, diagnostics);
            if (["==", "!=", "<", "<=", ">", ">=", "&&", "||", "is"].canFind((cast(BinaryExpression) expression).operatorSymbol))
                return "bool";
            if ((cast(BinaryExpression) expression).operatorSymbol == "~") return "string";
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
                            && !staticTypesCompatible(actual, functionInfo.parameterTypes[index]))
                            diagnostics ~= CheckDiagnostic(argument.line, argument.column,
                                format("Argument %s to '%s' expects %s but has type %s",
                                    index + 1, (cast(VariableExpression) (cast(CallExpression) expression).callee).name,
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

private bool staticTypesCompatible(string actual, string expected)
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
