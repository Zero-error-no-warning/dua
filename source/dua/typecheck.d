module dua.typecheck;

import dua.ast;
import dua.execution : CheckDiagnostic;
import dua.lexer : lex;
import dua.parser : parse;
import dua.value : ValueKind, valuesEqual;
import dua.type_syntax;
import dua.type_effects : TypeEffects;
import std.algorithm : canFind;
import std.format : format;

private struct StaticFunctionInfo
{
    string[] parameterTypes;
    string returnType;
}

// 型定義は変数のブロックスコープではなくエンジンに登録されます。
private final class NullableClassTypes
{
    bool[string] names;
    TypeEffects effects;
    this(string[] types) { foreach (name; types) names[name] = true; }
    NullableClassTypes copy()
    {
        auto result = new NullableClassTypes(null);
        result.names = names.dup;
        result.effects = effects;
        return result;
    }
    void intersect(NullableClassTypes path)
    {
        // 到達し得る経路で同名型を定義したら、後続ではnullableなクラスと断定しません。
        foreach (name; names.keys)
            if ((name in path.names) is null) names.remove(name);
    }
}

private bool knownCondition(Expression expression, out bool value, Statement init = null)
{
    if (expression is null) return false;
    if (expression.kind == Expression.Kind.literal)
    {
        value = (cast(LiteralExpression) expression).value.truthy();
        return true;
    }
    // for(auto i=0; i<0; ...)の初回条件だけは、初期化された整数で判定できます。
    if (init is null || init.kind != Statement.Kind.variableDecl || init.names.length != 1
        || init.expressions.length != 1 || init.expressions[0].kind != Expression.Kind.literal
        || expression.kind != Expression.Kind.binary) return false;
    auto binary = cast(BinaryExpression) expression;
    if (binary.left.kind != Expression.Kind.variable || binary.right.kind != Expression.Kind.literal
        || (cast(VariableExpression) binary.left).name != init.names[0]) return false;
    auto left = (cast(LiteralExpression) init.expressions[0]).value;
    auto right = (cast(LiteralExpression) binary.right).value;
    if (left.kind != ValueKind.integer || right.kind != ValueKind.integer) return false;
    switch (binary.operatorSymbol)
    {
        case "<": value = left.integerValue < right.integerValue; break;
        case "<=": value = left.integerValue <= right.integerValue; break;
        case ">": value = left.integerValue > right.integerValue; break;
        case ">=": value = left.integerValue >= right.integerValue; break;
        case "==": value = left.integerValue == right.integerValue; break;
        case "!=": value = left.integerValue != right.integerValue; break;
        default: return false;
    }
    return true;
}

/// Checks a source unit with the host class names registered by its engine.
package(dua) CheckDiagnostic[] checkSource(string source, string[] nativeClassTypes = null)
{
    CheckDiagnostic[] diagnostics;
    try
    {
        auto program = parse(lex(source));
        string[string] variableTypes;
        auto classTypes = new NullableClassTypes(nativeClassTypes);
        classTypes.effects = new TypeEffects(program, nativeClassTypes);
        StaticFunctionInfo[string] functions;
        checkStatements(program.statements, variableTypes, functions, diagnostics, "", classTypes);
    }
    catch (Exception error)
    {
        diagnostics ~= CheckDiagnostic(0, 0, error.msg);
    }
    return diagnostics;
}

private void checkStatements(Statement[] statements, ref string[string] variables,
    ref StaticFunctionInfo[string] functions, ref CheckDiagnostic[] diagnostics,
    string expectedReturnType, NullableClassTypes classTypes)
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
        classTypes.effects.applyBefore(statement, classTypes.names);
        final switch (statement.kind)
        {
            case Statement.Kind.variableDecl:
                foreach (index, name; statement.names)
                {
                    auto actual = index < statement.expressions.length
                        ? inferExpressionType(statement.expressions[index], variables, functions, diagnostics, classTypes)
                        : "any";
                    auto declared = statement.declaredType.length > 0
                        ? resolveStaticType(statement.declaredType, variables) : actual;
                    if (statement.declaredType.length > 0 && statement.declaredType != "auto"
                        && !staticTypesCompatible(actual, declared, classTypes))
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
                        ? inferExpressionType(expression, variables, functions, diagnostics, classTypes)
                        : "any";
                    if (target.kind == Expression.Kind.variable)
                    {
                        auto expected = (cast(VariableExpression) target).name in variables;
                        if (expected !is null && !staticTypesCompatible(actual, *expected, classTypes))
                            diagnostics ~= CheckDiagnostic(target.line, target.column,
                                format("Assignment to '%s' expects %s but expression has type %s",
                                    (cast(VariableExpression) target).name, *expected, actual));
                    }
                    else if (target.kind == Expression.Kind.index)
                    {
                        auto expected = inferExpressionType(target, variables, functions, diagnostics, classTypes);
                        if (!staticTypesCompatible(actual, expected, classTypes))
                            diagnostics ~= CheckDiagnostic(target.line, target.column,
                                format("Indexed assignment expects %s but has type %s", expected, actual));
                    }
                    else if (target.kind == Expression.Kind.get)
                    {
                        auto get = cast(GetExpression) target;
                        auto container = inferExpressionType(get.target, variables, functions, diagnostics, classTypes);
                        string element, key;
                        if (get.memberName == "length" && (container == "array"
                            || (splitContainerType(container, element, key) && !key.length)))
                            diagnostics ~= CheckDiagnostic(target.line, target.column, "Array length is read-only");
                    }
                }
                break;
            case Statement.Kind.return_:
                auto actual = statement.expressions.length == 0 ? "null"
                    : inferExpressionType(statement.expressions[0], variables, functions, diagnostics, classTypes);
                if (expectedReturnType.length > 0)
                {
                    if (!staticTypesCompatible(actual, expectedReturnType, classTypes))
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
                    statement.returnType, classTypes.copy());
                break;
            case Statement.Kind.block:
                auto childVariables = variables.dup;
                checkStatements(statement.body, childVariables, functions, diagnostics, expectedReturnType, classTypes);
                break;
            case Statement.Kind.for_:
                auto loopVariables = variables.dup;
                if (statement.init !is null)
                    checkStatements([statement.init], loopVariables, functions, diagnostics, expectedReturnType, classTypes);
                if (statement.condition !is null)
                    inferExpressionType(statement.condition, loopVariables, functions, diagnostics, classTypes);
                auto loopClasses = classTypes.copy();
                checkStatements(statement.body, loopVariables, functions, diagnostics, expectedReturnType, loopClasses);
                if (statement.incrementStatement !is null)
                    checkStatements([statement.incrementStatement], loopVariables, functions, diagnostics, expectedReturnType, loopClasses);
                bool firstCondition;
                if (!knownCondition(statement.condition, firstCondition, statement.init) || firstCondition)
                    classTypes.intersect(loopClasses);
                break;
            case Statement.Kind.if_, Statement.Kind.while_,
                 Statement.Kind.foreach_:
                if (statement.condition !is null)
                    inferExpressionType(statement.condition, variables, functions, diagnostics, classTypes);
                auto bodyClasses = classTypes.copy();
                foreach (child; statement.body)
                {
                    auto nestedVariables = variables.dup;
                    if (statement.kind == Statement.Kind.foreach_)
                    {
                        auto iterableType = inferExpressionType(statement.iterable, variables, functions, diagnostics, classTypes);
                        string element, key;
                        if (statement.rangeEnd !is null)
                        {
                            auto endType = inferExpressionType(statement.rangeEnd, variables, functions, diagnostics, classTypes);
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
                    checkStatements([child], nestedVariables, functions, diagnostics, expectedReturnType, bodyClasses);
                }
                auto elseClasses = classTypes.copy();
                if (statement.elseBranch !is null)
                {
                    auto nestedVariables = variables.dup;
                    checkStatements([statement.elseBranch], nestedVariables, functions, diagnostics, expectedReturnType, elseClasses);
                }
                bool condition;
                auto known = knownCondition(statement.condition, condition);
                bool emptyIteration;
                if (statement.kind == Statement.Kind.foreach_)
                {
                    if (statement.iterable.kind == Expression.Kind.array && statement.rangeEnd is null)
                        emptyIteration = (cast(ArrayExpression) statement.iterable).elements.length == 0;
                    else if (statement.rangeEnd !is null && statement.iterable.kind == Expression.Kind.literal
                        && statement.rangeEnd.kind == Expression.Kind.literal)
                    {
                        auto start = (cast(LiteralExpression) statement.iterable).value;
                        auto end = (cast(LiteralExpression) statement.rangeEnd).value;
                        emptyIteration = start.kind == ValueKind.integer && end.kind == ValueKind.integer
                            && start.integerValue >= end.integerValue;
                    }
                }
                if ((!known || condition) && !emptyIteration) classTypes.intersect(bodyClasses);
                if (statement.kind == Statement.Kind.if_ && (!known || !condition))
                    classTypes.intersect(elseClasses);
                break;
            case Statement.Kind.switch_:
                inferExpressionType(statement.expression, variables, functions, diagnostics, classTypes);
                auto incomingClasses = classTypes.copy();
                auto knownSwitch = statement.expression.kind == Expression.Kind.literal;
                foreach (arm; statement.switchCases)
                    if (!arm.isDefault && arm.pattern.kind != Expression.Kind.literal) knownSwitch = false;
                bool selected;
                foreach (arm; statement.switchCases)
                {
                    auto armClasses = incomingClasses.copy();
                    auto armVariables = variables.dup;
                    checkStatements(arm.body, armVariables, functions, diagnostics, expectedReturnType, armClasses);
                    auto reachable = !knownSwitch || (!selected && (arm.isDefault || valuesEqual(
                        (cast(LiteralExpression) statement.expression).value,
                        (cast(LiteralExpression) arm.pattern).value)));
                    if (reachable) { classTypes.intersect(armClasses); selected = true; }
                }
                break;
            case Statement.Kind.try_:
                auto tryVariables = variables.dup;
                auto tryClasses = classTypes.copy();
                checkStatements(statement.body, tryVariables, functions, diagnostics, expectedReturnType, tryClasses);
                auto catchVariables = variables.dup;
                catchVariables[statement.name] = "table";
                auto catchClasses = tryClasses.copy();
                checkStatements(statement.elseBranch.body, catchVariables, functions, diagnostics, expectedReturnType, catchClasses);
                classTypes.intersect(tryClasses);
                classTypes.intersect(catchClasses);
                break;
            case Statement.Kind.expression:
                inferExpressionType(statement.expression, variables, functions, diagnostics, classTypes);
                break;
            case Statement.Kind.tableDecl, Statement.Kind.structDecl:
                // 宣言前のクラス利用は保ち、同名aggregateの宣言以降だけを上書きします。
                classTypes.names.remove(statement.name);
                break;
            case Statement.Kind.alias_,
                 Statement.Kind.break_, Statement.Kind.continue_, Statement.Kind.yield_,
                 Statement.Kind.import_, Statement.Kind.export_:
                break;
        }
    }
}

private string inferExpressionType(Expression expression, ref string[string] variables,
    ref StaticFunctionInfo[string] functions, ref CheckDiagnostic[] diagnostics,
    NullableClassTypes classTypes)
{
    if (expression is null) return "any";
    classTypes.effects.applyBefore(expression, classTypes.names);
    scope(exit) classTypes.effects.applyAfter(expression, classTypes.names);
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
                inferExpressionType(key, variables, functions, diagnostics, classTypes);
                inferExpressionType(aa.values[index], variables, functions, diagnostics, classTypes);
            }
            return "associativeArray";
        case Expression.Kind.table: return "table";
        case Expression.Kind.function_: return "function";
        case Expression.Kind.unary:
            if ((cast(UnaryExpression) expression).operatorSymbol == "new") return "table";
            return (cast(UnaryExpression) expression).operatorSymbol == "!" ? "bool"
                : inferExpressionType((cast(UnaryExpression) expression).operand, variables, functions, diagnostics, classTypes);
        case Expression.Kind.cast_:
            auto conversion = cast(CastExpression) expression;
            inferExpressionType(conversion.operand, variables, functions, diagnostics, classTypes);
            return conversion.targetType;
        case Expression.Kind.binary:
            auto left = inferExpressionType((cast(BinaryExpression) expression).left, variables, functions, diagnostics, classTypes);
            auto right = (cast(BinaryExpression) expression).operatorSymbol == "is" ? "any"
                : inferExpressionType((cast(BinaryExpression) expression).right, variables, functions, diagnostics, classTypes);
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
            auto middle = inferExpressionType((cast(TernaryExpression) expression).whenTrue, variables, functions, diagnostics, classTypes);
            auto right = inferExpressionType((cast(TernaryExpression) expression).whenFalse, variables, functions, diagnostics, classTypes);
            return middle == right ? middle : "any";
        case Expression.Kind.call:
            auto call = cast(CallExpression) expression;
            auto targets = classTypes.effects.knownCallees(call);
            auto label = call.callee.kind == Expression.Kind.variable
                ? (cast(VariableExpression) call.callee).name : "<function>";
            string[] actualTypes;
            foreach (argument; call.arguments)
                actualTypes ~= inferExpressionType(argument, variables, functions, diagnostics, classTypes);
            inferExpressionType(call.callee, variables, functions, diagnostics, classTypes);
            // 実行時の引数型検証は、全引数とcalleeを評価した後・本体を実行する前です。
            foreach (index, argument; call.arguments)
            {
                auto actual = actualTypes[index];
                foreach (target; targets)
                {
                    auto declaration = cast(Statement) target;
                    auto types = declaration is null ? (cast(FunctionExpression) target).parameterTypes : declaration.parameterTypes;
                    if (index >= types.length) continue;
                    auto expected = resolveStaticType(types[index], variables);
                    if (!staticTypesCompatible(actual, expected, classTypes))
                        diagnostics ~= CheckDiagnostic(argument.line, argument.column,
                            format("Argument %s to '%s' expects %s but has type %s", index + 1, label, expected, actual));
                }
            }
            string resultType;
            foreach (target; targets)
            {
                auto declaration = cast(Statement) target;
                auto type = resolveStaticType(declaration is null ? (cast(FunctionExpression) target).returnType : declaration.returnType, variables);
                if (!type.length) type = "any";
                if (resultType.length && resultType != type) return "any";
                resultType = type;
            }
            return resultType.length ? resultType : "any";
        case Expression.Kind.index:
            auto indexExpression = cast(IndexExpression) expression;
            auto container = inferExpressionType(indexExpression.target, variables, functions, diagnostics, classTypes);
            string element, key;
            if (splitContainerType(container, element, key) && !indexExpression.isSlice)
            {
                if (indexExpression.indices.length != 1)
                {
                    diagnostics ~= CheckDiagnostic(expression.line, expression.column,
                        "Array/associative array indexing requires a single index");
                    return "any";
                }
                auto actual = inferExpressionType(indexExpression.index, variables, functions, diagnostics, classTypes);
                auto expected = key.length ? key : "int";
                if (!staticTypesCompatible(actual, expected, classTypes))
                    diagnostics ~= CheckDiagnostic(expression.line, expression.column,
                        format("Index expects %s but has type %s", expected, actual));
                return element;
            }
            return "any";
        case Expression.Kind.get:
            auto get = cast(GetExpression) expression;
            auto targetType = inferExpressionType(get.target, variables, functions, diagnostics, classTypes);
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
    if (isBuiltinTypeName(name)) return name;
    if (auto aliasType = "#type_" ~ name in variables)
        return resolveStaticType(*aliasType, variables, depth + 1);
    string element, key;
    if (splitContainerType(name, element, key))
        return resolveStaticType(element, variables, depth + 1) ~ "["
            ~ (key.length ? resolveStaticType(key, variables, depth + 1) : "") ~ "]";
    return name;
}

private bool staticTypesCompatible(string actual, string expected, NullableClassTypes classTypes)
{
    if (actual == "null" && !isBuiltinTypeName(expected)
        && (expected in classTypes.names) !is null) return true;
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
