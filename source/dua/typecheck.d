module dua.typecheck;

import dua.ast;
import dua.execution : CheckDiagnostic, scriptDiagnostic;
import dua.lexer : lex, TokenKind;
import dua.parser : parse;
import dua.value : ValueKind;
import dua.type_syntax;
import dua.module_analysis;
import std.algorithm : canFind;
import std.format : format;
import std.json : JSONValue, parseJSON;

private struct StaticFunctionInfo
{
    string[] parameterTypes;
    string returnType;
    bool variadic;
    size_t requiredArguments = size_t.max;
}

/// Check the already-bound graph, without executing module initializers/loaders.
package(dua) CheckDiagnostic[] checkModuleGraph(ModuleAnalysis analysis, string[] classTypes)
{
    CheckDiagnostic[] diagnostics;
    string[string] aliases;
    void definitions(Statement[] statements)
    {
        foreach (statement; statements)
        {
            if (statement.kind == Statement.Kind.alias_)
            {
                if (statement.names.length == 1) aliases["#type_" ~ statement.name] = statement.names[0];
                else aliases["#union_" ~ statement.name] = JSONValue(statement.names).toString();
            }
            if (statement.kind == Statement.Kind.tableDecl || statement.kind == Statement.Kind.structDecl)
            {
                JSONValue[string] fields;
                foreach (i, name; statement.parameters) fields[name] = JSONValue(statement.parameterTypes[i]);
                aliases["#table_" ~ statement.name] = JSONValue(fields).toString();
                aliases["#bases_" ~ statement.name] = JSONValue(statement.names).toString();
                if (statement.kind == Statement.Kind.structDecl) aliases["#struct_" ~ statement.name] = "true";
            }
            definitions(statement.body);
            if (statement.elseBranch !is null) definitions([statement.elseBranch]);
            foreach (branch; statement.switchCases) definitions(branch.body);
        }
    }
    bool[BoundModule] seen;
    void graphTypes(BoundModule unit)
    {
        if ((unit in seen) !is null) return;
        seen[unit] = true;
        foreach (dependency; unit.dependencies.byValue) graphTypes(dependency);
        foreach (type; unit.types)
        {
            if (type.declarationKind == "alias")
            {
                if (type.alternatives.length == 1) aliases["#type_" ~ type.type] = type.alternatives[0];
                else aliases["#union_" ~ type.type] = JSONValue(type.alternatives).toString();
            }
            else
            {
                JSONValue[string] fields;
                foreach (name, fieldType; type.fields) fields[name] = JSONValue(fieldType);
                aliases["#table_" ~ type.type] = JSONValue(fields).toString();
                aliases["#bases_" ~ type.type] = JSONValue(type.baseTypes).toString();
                if (type.declarationKind == "struct") aliases["#struct_" ~ type.type] = "true";
            }
        }
        definitions(unit.program.statements);
    }
    foreach (unit; analysis.modules) graphTypes(unit);
    foreach (unit; analysis.modules)
    {
        auto variables = aliases.dup;
        foreach (name; classTypes) variables["#class_" ~ name] = "class";
        StaticFunctionInfo[string] functions;
        foreach (aliasName, dependency; unit.dependencies)
        {
            variables["#module_" ~ aliasName] = dependency.key;
            if (!dependency.exportsComplete) variables["#dynamic_module_" ~ aliasName] = "true";
            foreach (export_; dependency.exports)
            {
                auto name = aliasName ~ "." ~ export_.name;
                if (export_.kind == "function")
                    functions[name] = StaticFunctionInfo(export_.parameterTypes, export_.type, export_.variadic, export_.requiredParameterCount);
                else if (export_.kind == "variable") variables["#member_" ~ name] =
                    export_.nominalValue ? "@named:" ~ export_.type : export_.type;
                else if (export_.kind == "type")
                {
                    variables["#export_type_" ~ name] = export_.type;
                    if (export_.runtimeValue) variables["#member_" ~ name] = "any";
                }
            }
        }
        CheckDiagnostic[] local;
        checkStatements(unit.program.statements, variables, functions, local, "");
        foreach (ref diagnostic; local)
        { diagnostic.sourceName = unit.sourceName; diagnostic.sourceText = unit.source; }
        diagnostics ~= local;
    }
    return diagnostics;
}

private void checkParameterDefaults(string[] names, string[] types, Expression[] defaults,
    ref string[string] variables, ref StaticFunctionInfo[string] functions, ref CheckDiagnostic[] diagnostics)
{
    foreach (index, name; names)
    {
        auto type = index < types.length ? resolveStaticType(types[index], variables) : "any";
        if (index < defaults.length && defaults[index] !is null)
        {
            auto actual = inferExpressionType(defaults[index], variables, functions, diagnostics);
            if (!staticTypesCompatible(boundaryActual(defaults[index], actual), type, variables))
                diagnostics ~= CheckDiagnostic(defaults[index].line, defaults[index].column,
                    format("Default argument '%s' expects %s but has type %s", name, type, actual));
            checkNullLiteralContext(defaults[index], type, variables, diagnostics);
        }
        variables[name] = type;
    }
}

private string qualifiedExpressionName(Expression expression)
{
    if (expression.kind == Expression.Kind.variable) return (cast(VariableExpression) expression).name;
    if (expression.kind == Expression.Kind.get)
    {
        auto get = cast(GetExpression) expression;
        auto parent = qualifiedExpressionName(get.target);
        return parent.length ? parent ~ "." ~ get.memberName : "";
    }
    return "";
}

/// Checks a source unit with the host class names registered by its engine.
package(dua) CheckDiagnostic[] checkSource(string source, string[] nativeClassTypes = null,
    string[] registeredClassTypes = null, bool catalogTypes = false)
{
    CheckDiagnostic[] diagnostics;
    try
    {
        auto tokens = lex(source);
        auto program = parse(tokens);
        string[string] variableTypes;
        foreach (name; nativeClassTypes)
        {
            variableTypes["#class_" ~ name] = "class";
            if (catalogTypes) variableTypes["#catalog_class_" ~ name] = "class";
        }
        // 到達性や呼出しを解析しません。同一ソースに同名の型宣言がある公開クラスだけ、
        // 実行順で解決が変わり得る型として、実行時の厳密な検証へ委ねます。
        foreach (index, token; tokens)
        {
            string name;
            if ((token.kind == TokenKind.keywordAlias || token.kind == TokenKind.keywordStruct)
                && index + 1 < tokens.length) name = tokens[index + 1].lexeme;
            else if (token.kind == TokenKind.identifier && token.lexeme == "table"
                && index + 2 < tokens.length && tokens[index + 1].kind == TokenKind.identifier
                && tokens[index + 2].kind == TokenKind.leftBrace) name = tokens[index + 1].lexeme;
            else if (token.kind == TokenKind.identifier && token.lexeme.length > 11
                && token.lexeme[0 .. 11] == "__dua_type_") name = token.lexeme[11 .. $];
            if (!isBuiltinTypeName(name) && registeredClassTypes.canFind(name))
                variableTypes["#dynamic_type_" ~ name] = "runtime";
        }
        StaticFunctionInfo[string] functions;
        checkStatements(program.statements, variableTypes, functions, diagnostics, "");
    }
    catch (Exception error)
    {
        auto diagnostic=scriptDiagnostic(error);
        diagnostics ~= CheckDiagnostic(diagnostic.line, diagnostic.column, error.msg);
    }
    return diagnostics;
}

private void checkStatements(Statement[] statements, ref string[string] variables,
    ref StaticFunctionInfo[string] functions, ref CheckDiagnostic[] diagnostics,
    string expectedReturnType)
{
    foreach (statement; statements)
    {
        if (statement.kind == Statement.Kind.tableDecl || statement.kind == Statement.Kind.structDecl)
            variables.remove("#class_" ~ statement.name);
        if (statement.kind == Statement.Kind.alias_)
        {
            if (statement.names.length == 1) variables["#type_" ~ statement.name] = statement.names[0];
            else variables["#union_" ~ statement.name] = JSONValue(statement.names).toString();
        }
    }
    expectedReturnType = resolveStaticType(expectedReturnType, variables);
    foreach (statement; statements)
    {
        if (statement.kind == Statement.Kind.functionDecl)
        {
            string[] parameterTypes;
            foreach (type; statement.parameterTypes) parameterTypes ~= resolveStaticType(type, variables);
            functions[statement.name] = StaticFunctionInfo(
                parameterTypes, resolveStaticType(statement.returnType, variables), statement.variadic,
                requiredParameterCount(statement.parameters.length, statement.parameterDefaults, statement.variadic));
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
                    string nonNullInitializer;
                    if (index >= statement.expressions.length
                        && splitNonNullType(resolveStaticType(statement.declaredType, variables), nonNullInitializer))
                        actual = "null";
                    auto declared = statement.declaredType.length > 0
                        ? resolveStaticType(statement.declaredType, variables) : actual;
                    if (index < statement.expressions.length && statement.declaredType != "auto")
                        checkNullLiteralContext(statement.expressions[index], declared, variables, diagnostics);
                    if (statement.declaredType.length > 0 && statement.declaredType != "auto"
                        && !staticTypesCompatible(boundaryActual(index < statement.expressions.length ? statement.expressions[index] : null, actual), declared, variables))
                        addDiagnostic(diagnostics, statement,
                            format("Variable '%s' expects %s but expression has type %s",
                                name, statement.declaredType, actual));
                    // nullから始めるauto変数には、後から実体を格納できます。
                    variables[name] = declared == "auto"
                        ? (actual == "null" || ("#union_" ~ actual in variables) !is null ? "any"
                            : isStringLiteralType(actual) ? "string" : actual) : declared;
                }
                break;
            case Statement.Kind.assign:
                foreach (index, target; statement.targets)
                {
                    auto expression = index < statement.expressions.length ? statement.expressions[index] : null;
                    if (statement.assignmentOperator.length)
                    {
                        expression = new BinaryExpression(target, statement.assignmentOperator, expression);
                        expression.line = target.line;
                        expression.column = target.column;
                    }
                    auto actual = index < statement.expressions.length
                        ? inferExpressionType(expression, variables, functions, diagnostics)
                        : "any";
                    if (target.kind == Expression.Kind.variable)
                    {
                        auto expected = (cast(VariableExpression) target).name in variables;
                        if (expected !is null) checkNullLiteralContext(expression, *expected, variables, diagnostics);
                        if (expected !is null && !staticTypesCompatible(boundaryActual(expression, actual), *expected, variables))
                            diagnostics ~= CheckDiagnostic(target.line, target.column,
                                format("Assignment to '%s' expects %s but expression has type %s",
                                    (cast(VariableExpression) target).name, *expected, actual));
                    }
                    else if (target.kind == Expression.Kind.index)
                    {
                        auto expected = inferExpressionType(target, variables, functions, diagnostics);
                        checkNullLiteralContext(expression, expected, variables, diagnostics);
                        if (!staticTypesCompatible(actual, expected, variables))
                            diagnostics ~= CheckDiagnostic(target.line, target.column,
                                format("Indexed assignment expects %s but has type %s", expected, actual));
                    }
                    else if (target.kind == Expression.Kind.get)
                    {
                        auto get = cast(GetExpression) target;
                        auto qualified = qualifiedExpressionName(target);
                        if (auto exported = "#member_" ~ qualified in variables)
                        {
                            auto expected = *exported;
                            if (expected.length > 7 && expected[0 .. 7] == "@named:") expected = expected[7 .. $];
                            string inner;
                            if (splitNonNullType(resolveStaticType(expected, variables), inner)
                                && !staticTypesCompatible(boundaryActual(expression, actual), expected, variables))
                                diagnostics ~= CheckDiagnostic(target.line, target.column,
                                    "Exported value '" ~ qualified ~ "' expects " ~ expected);
                        }
                        auto container = inferExpressionType(get.target, variables, functions, diagnostics);
                        auto owner = resolveStaticType(container, variables);
                        if (owner.length > 7 && owner[0 .. 7] == "@named:") owner = owner[7 .. $];
                        string nonNullOwner;
                        if (splitNonNullType(owner, nonNullOwner)) owner = nonNullOwner;
                        auto fields = staticTableFields(owner, variables);
                        if (auto field = get.memberName in fields)
                        {
                            checkNullLiteralContext(expression, *field, variables, diagnostics);
                            string inner;
                            if (splitNonNullType(resolveStaticType(*field, variables), inner)
                                && !staticTypesCompatible(boundaryActual(expression, actual), *field, variables))
                                diagnostics ~= CheckDiagnostic(target.line, target.column,
                                    "Field '" ~ get.memberName ~ "' expects " ~ *field);
                        }
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
                    if (statement.expressions.length)
                        checkNullLiteralContext(statement.expressions[0], expectedReturnType, variables, diagnostics);
                    if (!staticTypesCompatible(boundaryActual(statement.expressions.length ? statement.expressions[0] : null, actual), expectedReturnType, variables))
                        addDiagnostic(diagnostics, statement,
                            format("Return expects %s but expression has type %s",
                                expectedReturnType, actual));
                }
                break;
            case Statement.Kind.functionDecl:
                auto childVariables = variables.dup;
                checkParameterDefaults(statement.parameters, statement.parameterTypes, statement.parameterDefaults,
                    childVariables, functions, diagnostics);
                if (statement.variadic && statement.parameters.length && statement.parameterTypes.length)
                    childVariables[statement.parameters[$ - 1]] = resolveStaticType(statement.parameterTypes[$ - 1], variables) ~ "[]";
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
            case Statement.Kind.tableDecl, Statement.Kind.structDecl:
                if(statement.metatableReference !is null){
                    auto metaType=inferExpressionType(statement.metatableReference,variables,functions,diagnostics);
                    auto resolved=resolveStaticType(metaType,variables);
                    if(isStringLiteralType(resolved)||["int","double","bool","string","null","array","associativeArray","function"].canFind(resolved))
                        diagnostics~=CheckDiagnostic(statement.metatableReference.line,statement.metatableReference.column,"Type with requires a non-null script metatable");
                }
                break;
            case Statement.Kind.alias_,
                 Statement.Kind.break_, Statement.Kind.continue_, Statement.Kind.yield_,
                 Statement.Kind.import_, Statement.Kind.export_:
                break;
        }
    }
}

private string boundaryActual(Expression expression, string actual)
{
    // コンテナ literal 自体は非 null。ただし auto 変数の宣言型は nullable のまま。
    return expression !is null && ((expression.kind == Expression.Kind.table && actual == "table")
        || (expression.kind == Expression.Kind.array && actual == "array")
        || (expression.kind == Expression.Kind.associativeArray && actual == "associativeArray"))
        ? nonNullType(actual) : actual;
}

private string[string] staticTableFields(string type, ref string[string] variables, size_t depth = 0)
{
    string[string] result;
    if (depth >= 64) return result;
    type = resolveStaticType(type, variables);
    string nonNullInner;
    if (splitNonNullType(type, nonNullInner)) return staticTableFields(nonNullInner, variables, depth + 1);
    if (auto bases = "#bases_" ~ type in variables)
        foreach (base; parseJSON(*bases).array)
            foreach (name, fieldType; staticTableFields(base.str, variables, depth + 1)) result[name] = fieldType;
    if (auto fields = "#table_" ~ type in variables)
        foreach (name, fieldType; parseJSON(*fields).object) result[name] = fieldType.str;
    return result;
}

// 既知のコンテナ/field リテラルに限り、文脈型の null 除外を検査します。
// 動的 spread や any の内容を実行して推論する処理には広げません。
private void checkNullLiteralContext(Expression expression, string expected,
    ref string[string] variables, ref CheckDiagnostic[] diagnostics, size_t depth = 0)
{
    if (expression is null || depth >= 64) return;
    expected = resolveStaticType(expected, variables);
    string inner;
    if (splitNonNullType(expected, inner))
    {
        if (expression.kind == Expression.Kind.literal
            && (cast(LiteralExpression)expression).value.kind == ValueKind.null_)
        {
            if (depth > 0)
                diagnostics ~= CheckDiagnostic(expression.line, expression.column,
                    "Null is not allowed by " ~ expected);
            return;
        }
        expected = inner;
    }
    if (depth > 0 && expression.kind == Expression.Kind.literal
        && (cast(LiteralExpression)expression).value.kind == ValueKind.null_
        && !staticTypeAllowsNull(expected, variables))
    {
        diagnostics ~= CheckDiagnostic(expression.line, expression.column, "Null is not allowed by " ~ expected);
        return;
    }
    string element, key;
    if (splitContainerType(expected, element, key))
    {
        if (!key.length && expression.kind == Expression.Kind.array)
        {
            auto array = cast(ArrayExpression)expression;
            foreach (i, item; array.elements)
                if (i >= array.elementSpreads.length || !array.elementSpreads[i])
                    checkNullLiteralContext(item, element, variables, diagnostics, depth + 1);
        }
        else if (key.length && expression.kind == Expression.Kind.associativeArray)
        {
            auto array = cast(AssociativeArrayExpression)expression;
            foreach (i, item; array.values)
            {
                checkNullLiteralContext(array.keys[i], key, variables, diagnostics, depth + 1);
                checkNullLiteralContext(item, element, variables, diagnostics, depth + 1);
            }
        }
    }
    else if (expression.kind == Expression.Kind.table)
    {
        auto fields = staticTableFields(expected, variables);
        foreach (entry; (cast(TableExpression)expression).entries)
            if (!entry.isSpread && entry.keyExpression is null)
                if (auto fieldType = entry.key in fields)
                    checkNullLiteralContext(entry.value, *fieldType, variables, diagnostics, depth + 1);
    }
}

private bool staticTableDerives(string actual, string expected, ref string[string] variables, size_t depth = 0)
{
    if (actual == expected) return true;
    if (depth >= 64) return false;
    if (auto bases = "#bases_" ~ actual in variables)
        foreach (base; parseJSON(*bases).array)
            if (staticTableDerives(resolveStaticType(base.str, variables), expected, variables, depth + 1)) return true;
    return false;
}

// Only inspect the new construction form inside previously opaque containers.
private void checkNestedConstructions(Expression expression, ref string[string] variables,
    ref StaticFunctionInfo[string] functions, ref CheckDiagnostic[] diagnostics)
{
    if (expression is null) return;
    if (expression.kind == Expression.Kind.table)
    {
        auto table = cast(TableExpression)expression;
        if (table.targetType.length) { inferExpressionType(expression, variables, functions, diagnostics); return; }
        foreach (entry; table.entries) checkNestedConstructions(entry.value, variables, functions, diagnostics);
    }
    if (expression.kind == Expression.Kind.array)
        foreach (item; (cast(ArrayExpression)expression).elements) checkNestedConstructions(item, variables, functions, diagnostics);
}

private string inferExpressionType(Expression expression, ref string[string] variables,
    ref StaticFunctionInfo[string] functions, ref CheckDiagnostic[] diagnostics)
{
    if (expression is null) return "any";
    final switch (expression.kind)
    {
        case Expression.Kind.with_:
            auto with_=cast(WithExpression)expression;
            auto target=inferExpressionType(with_.target,variables,functions,diagnostics);
            auto scoped=variables.dup;scoped[with_.bindingName]=target;
            if(isStringLiteralType(resolveStaticType(target,variables))||["int","double","bool","string","null","array","associativeArray"].canFind(resolveStaticType(target,variables)))
                diagnostics~=CheckDiagnostic(with_.target.line,with_.target.column,"with target must be a table, struct or reflected object");
            return inferExpressionType(with_.body,scoped,functions,diagnostics);
        case Expression.Kind.literal:
            final switch ((cast(LiteralExpression) expression).value.kind)
            {
                case ValueKind.integer: return "int";
                case ValueKind.floating: return "double";
                case ValueKind.boolean: return "bool";
                case ValueKind.string_: return stringLiteralType((cast(LiteralExpression) expression).value.stringValue);
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
        case Expression.Kind.array:
            checkNestedConstructions(expression, variables, functions, diagnostics);
            return "array";
        case Expression.Kind.associativeArray:
            auto aa = cast(AssociativeArrayExpression) expression;
            foreach (index, key; aa.keys)
            {
                inferExpressionType(key, variables, functions, diagnostics);
                inferExpressionType(aa.values[index], variables, functions, diagnostics);
            }
            return "associativeArray";
        case Expression.Kind.table:
            auto table = cast(TableExpression)expression;
            if (!table.targetType.length)
            {
                checkNestedConstructions(expression, variables, functions, diagnostics);
                return "table";
            }
            auto target = resolveStaticType(table.targetType, variables);
            string constructionInner;
            while (splitNonNullType(target, constructionInner)) target = constructionInner;
            if (isBuiltinTypeName(target) || ("#union_" ~ target in variables) !is null
                || ("#struct_" ~ target in variables) !is null || ("#class_" ~ target in variables) !is null)
            {
                diagnostics ~= CheckDiagnostic(expression.line, expression.column,
                    "Named table construction requires one declared table type: " ~ table.sourceType);
                return "any";
            }
            auto fields = staticTableFields(target, variables);
            bool complete = true;
            bool[string] supplied;
            foreach (entry; table.entries)
            {
                if (entry.isSpread || entry.keyExpression !is null) { complete = false; continue; }
                supplied[entry.key] = true;
                auto actual = inferExpressionType(entry.value, variables, functions, diagnostics);
                if (auto expected = entry.key in fields)
                {
                    checkNullLiteralContext(entry.value, *expected, variables, diagnostics);
                    if (!staticTypesCompatible(boundaryActual(entry.value, actual), *expected, variables))
                        diagnostics ~= CheckDiagnostic(entry.value.line, entry.value.column,
                            "Named table field '" ~ entry.key ~ "' expects " ~ *expected);
                }
            }
            if (complete) foreach (name; fields.byKey)
                if ((name in supplied) is null) diagnostics ~= CheckDiagnostic(expression.line, expression.column,
                    "Named table initializer is missing '" ~ name ~ "'");
            return "@named:" ~ target;
        case Expression.Kind.function_:
            auto fn = cast(FunctionExpression)expression;
            auto childVariables = variables.dup;
            checkParameterDefaults(fn.parameters, fn.parameterTypes, fn.parameterDefaults,
                childVariables, functions, diagnostics);
            return "function";
        case Expression.Kind.unary:
            if ((cast(UnaryExpression) expression).operatorSymbol == "$") return "int";
            if ((cast(UnaryExpression) expression).operatorSymbol == "new") return "table";
            return (cast(UnaryExpression) expression).operatorSymbol == "!" ? "bool"
                : inferExpressionType((cast(UnaryExpression) expression).operand, variables, functions, diagnostics);
        case Expression.Kind.cast_:
            auto conversion = cast(CastExpression) expression;
            auto actual = inferExpressionType(conversion.operand, variables, functions, diagnostics);
            if (actual.length > 7 && actual[0 .. 7] == "@named:")
            {
                if (!staticTypesCompatible(actual, conversion.targetType, variables))
                    diagnostics ~= CheckDiagnostic(expression.line, expression.column,
                        "Cannot cast an explicit named table to " ~ conversion.targetType);
                return actual;
            }
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
                // Unionが配列か文字列かは動的値で決まるため、連結結果は実行時に検査します。
                if (("#union_" ~ left in variables) !is null || ("#union_" ~ right in variables) !is null) return "any";
                string element, key;
                auto leftArray = left == "array" || (splitContainerType(left, element, key) && !key.length);
                auto rightArray = right == "array" || (splitContainerType(right, element, key) && !key.length);
                if (left == "any" || right == "any" || left == "table" || right == "table") return "any";
                if (leftArray)
                {
                    if (!rightArray && splitContainerType(left, element, key)
                        && !staticTypesCompatible(right, element, variables))
                        diagnostics ~= CheckDiagnostic(expression.line, expression.column,
                            format("Array element expects %s but has type %s", element, right));
                    return left;
                }
                if (mayUseBinaryOverload(left, variables) || mayUseBinaryOverload(right, variables)) return "any";
                return "string";
            }
            // 配列連結の要素型検査を保ち、ホスト/集約型の演算結果は数値に決め打ちしません。
            if (mayUseBinaryOverload(left, variables) || mayUseBinaryOverload(right, variables)) return "any";
            if (left == "any" || right == "any" || left == "table" || right == "table") return "any";
            if (op == "/") return "double";
            if (["%", "&", "|", "^", "<<", ">>"].canFind(op)) return "int";
            return left == "int" && right == "int" ? "int" : "double";
        case Expression.Kind.ternary:
            auto middle = inferExpressionType((cast(TernaryExpression) expression).whenTrue, variables, functions, diagnostics);
            auto right = inferExpressionType((cast(TernaryExpression) expression).whenFalse, variables, functions, diagnostics);
            return middle == right ? middle : "any";
        case Expression.Kind.call:
            if (qualifiedExpressionName((cast(CallExpression) expression).callee).length)
            {
                auto calledName = qualifiedExpressionName((cast(CallExpression) expression).callee);
                auto functionInfo = calledName in functions;
                if (functionInfo !is null)
                {
                    auto supplied = (cast(CallExpression)expression).arguments.length;
                    if (functionInfo.requiredArguments != size_t.max
                        && (supplied < functionInfo.requiredArguments
                            || (!functionInfo.variadic && supplied > functionInfo.parameterTypes.length)))
                        diagnostics ~= CheckDiagnostic(expression.line, expression.column,
                            format("Function '%s' expects %s to %s arguments but got %s", calledName,
                                functionInfo.requiredArguments,
                                functionInfo.variadic ? "unlimited" : format("%s", functionInfo.parameterTypes.length), supplied));
                    foreach (index, argument; (cast(CallExpression) expression).arguments)
                    {
                        auto actual = inferExpressionType(argument, variables, functions, diagnostics);
                        auto parameterIndex = functionInfo.variadic && functionInfo.parameterTypes.length
                            && index >= functionInfo.parameterTypes.length - 1 ? functionInfo.parameterTypes.length - 1 : index;
                        if (parameterIndex < functionInfo.parameterTypes.length
                            && !staticTypesCompatible(boundaryActual(argument, actual), functionInfo.parameterTypes[parameterIndex], variables))
                            diagnostics ~= CheckDiagnostic(argument.line, argument.column,
                                format("Argument %s to '%s' expects %s but has type %s",
                                    index + 1, calledName,
                                    functionInfo.parameterTypes[parameterIndex], actual));
                        if (parameterIndex < functionInfo.parameterTypes.length)
                            checkNullLiteralContext(argument, functionInfo.parameterTypes[parameterIndex], variables, diagnostics);
                    }
                    return functionInfo.returnType.length > 0 ? functionInfo.returnType : "any";
                }
            }
            return "any";
        case Expression.Kind.index:
            auto indexExpression = cast(IndexExpression) expression;
            auto container = inferExpressionType(indexExpression.target, variables, functions, diagnostics);
            string element, key;
            if (indexExpression.isSlice)
                return container == "array" || (splitContainerType(container, element, key) && !key.length)
                    ? container : "any";
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
            auto qualifiedName = qualifiedExpressionName(expression);
            if (auto member = "#member_" ~ qualifiedName in variables) return *member;
            if ((qualifiedName in functions) !is null) return "function";
            if (get.target.kind == Expression.Kind.variable
                && ("#module_" ~ (cast(VariableExpression)get.target).name in variables) !is null)
            {
                auto typeOnly = ("#export_type_" ~ qualifiedName in variables) !is null;
                if (!typeOnly && ("#dynamic_module_" ~ (cast(VariableExpression)get.target).name in variables) !is null)
                    return "any";
                diagnostics ~= CheckDiagnostic(expression.line, expression.column,
                    typeOnly ? "Type '" ~ qualifiedName ~ "' is not a runtime value"
                        : "Module does not export value '" ~ qualifiedName ~ "'");
                return "any";
            }
            auto targetType = inferExpressionType(get.target, variables, functions, diagnostics);
            if(get.withMember){
                auto fields=staticTableFields(resolveStaticType(targetType,variables),variables);
                if(auto field=get.memberName in fields)return *field;
                return "any";
            }
            string element, key;
            if (get.memberName == "length" && (targetType == "array"
                || splitContainerType(targetType, element, key)))
                return "int";
            // table/ホスト値は動的メンバーが UFCS を隠せるため any を維持します。
            // メンバーを持たない値だけ、受け手一つで呼べる既知の関数を推論します。
            auto receiverType = resolveStaticType(targetType, variables);
            if (["int", "double", "bool", "string", "array", "associativeArray", "null"].canFind(receiverType)
                || splitContainerType(receiverType, element, key))
            {
                if (receiverType == "associativeArray" || (key.length > 0))
                    if (["keys", "values", "length"].canFind(get.memberName)) return "any";
                if (auto functionInfo = get.memberName in functions)
                {
                    auto count = functionInfo.parameterTypes.length;
                    auto minimum = functionInfo.requiredArguments == size_t.max
                        ? (functionInfo.variadic && count ? count-1 : count) : functionInfo.requiredArguments;
                    auto acceptsReceiver = minimum <= 1 && (functionInfo.variadic || count >= 1);
                    if (acceptsReceiver && (count == 0
                        || staticTypesCompatible(targetType, functionInfo.parameterTypes[0], variables)))
                        return functionInfo.returnType.length ? functionInfo.returnType : "any";
                }
            }
            return "any";
    }
}

private bool mayUseBinaryOverload(string type, ref string[string] variables)
{
    type = resolveStaticType(type, variables);
    string inner;
    if (splitNonNullType(type, inner)) type = inner;
    string element, key;
    return type.length && !isBuiltinTypeName(type) && !isStringLiteralType(type)
        && !splitContainerType(type, element, key) && !canFind(type, " delegate(");
}

private string resolveStaticType(string name, ref string[string] variables, size_t depth = 0)
{
    if (depth >= 64) return "any";
    string nonNullInner;
    if (splitNonNullType(name, nonNullInner)) return nonNullType(resolveStaticType(nonNullInner, variables, depth + 1));
    if (isStringLiteralType(name)) return name;
    if (isBuiltinTypeName(name)) return name;
    if (("#dynamic_type_" ~ name in variables) !is null) return "any";
    if (auto aliasType = "#type_" ~ name in variables)
        return resolveStaticType(*aliasType, variables, depth + 1);
    string element, key;
    if (splitContainerType(name, element, key))
        return resolveStaticType(element, variables, depth + 1) ~ "["
            ~ (key.length ? resolveStaticType(key, variables, depth + 1) : "") ~ "]";
    return name;
}

private bool staticTypeAllowsNull(string type, ref string[string] variables, size_t depth = 0)
{
    if (depth >= 64) return false;
    type = resolveStaticType(type, variables);
    string inner;
    if (splitNonNullType(type, inner)) return false;
    if (["any", "auto", "null", "void", "table", "array", "associativeArray"].canFind(type)) return true;
    string element, key;
    if (splitContainerType(type, element, key)) return true;
    if (isBuiltinTypeName(type)) return false;
    if (("#class_" ~ type in variables) !is null) return true;
    if (("#table_" ~ type in variables) !is null && ("#struct_" ~ type in variables) is null) return true;
    if (auto members = "#union_" ~ type in variables)
        foreach (member; parseJSON(*members).array)
            if (staticTypeAllowsNull(member.str, variables, depth + 1)) return true;
    return false;
}

private bool staticTypesCompatible(string actual, string expected, ref string[string] variables,
    size_t depth = 0, bool unionMember = false)
{
    if (depth >= 64) return true;
    auto sourceActual = actual;
    bool nominal = actual.length > 7 && actual[0 .. 7] == "@named:";
    if (nominal) actual = actual[7 .. $];
    actual = resolveStaticType(actual, variables);
    expected = resolveStaticType(expected, variables);
    string actualInner, expectedInner;
    bool actualNonNull = splitNonNullType(actual, actualInner);
    bool expectedNonNull = splitNonNullType(expected, expectedInner);
    if (expectedNonNull)
    {
        if (actual == "null") return false;
        // is 判定で型を狭めたとは仮定せず、nullable 値には明示 cast を要求します。
        if (!actualNonNull && !nominal && actual != "any" && staticTypeAllowsNull(actual, variables)) return false;
        expected = expectedInner;
    }
    if (actualNonNull) actual = actualInner;
    if (actual == "null") return !expectedNonNull && staticTypeAllowsNull(expected, variables);
    if (actual == "any" || expected == "any" || expected == "auto") return true;
    // Unionの実体は型名のまま保持し、配列の要素型などへ展開して曖昧な文字列にしません。
    if (auto alternatives = "#union_" ~ actual in variables)
    {
        foreach (member; parseJSON(*alternatives).array)
            if (!staticTypesCompatible(member.str, expected, variables, depth + 1, true)) return false;
        return true;
    }
    if (auto alternatives = "#union_" ~ expected in variables)
    {
        foreach (member; parseJSON(*alternatives).array)
            if (staticTypesCompatible(sourceActual, member.str, variables, depth + 1, true)) return true;
        return false;
    }
    if (isStringLiteralType(expected))
        return actual == expected || actual == "string"; // 動的なstringの値制約は実行時に確認します。
    if (isStringLiteralType(actual)) actual = "string";
    if (nominal)
        return expected == "table" || staticTableDerives(actual, expected, variables);
    if (actual == "null" && !isBuiltinTypeName(expected)
        && ("#class_" ~ expected in variables) !is null) return true;
    if (["byte", "ubyte", "short", "ushort", "uint", "long", "ulong"].canFind(expected))
        return actual == "int";
    if (expected == "float" || expected == "real") return actual == "double";
    string element, key;
    if (splitContainerType(expected, element, key))
        return actual == expected || actual == (key.length ? "associativeArray" : "array")
            || (key.length && actual == "array");
    if (canFind(expected, " delegate(")) return actual == "function";
    // Unionを具体化しても、tableの構造互換やホストの継承関係は実行時の検査へ残します。
    if (unionMember && !isBuiltinTypeName(expected) && !isBuiltinTypeName(actual)
        && !splitContainerType(actual, element, key) && !canFind(actual, " delegate(")) return true;
    if (!["int", "double", "bool", "string", "null", "void", "array", "table"].canFind(expected))
        return actual == "table" || actual == expected;
    return actual == expected || (expected == "void" && actual == "null");
}

private void addDiagnostic(ref CheckDiagnostic[] diagnostics, Statement statement, string message)
{
    diagnostics ~= CheckDiagnostic(statement.line, statement.column, message);
}
