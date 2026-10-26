module dua.module_analysis;

import dua.ast;
import dua.execution;
import dua.lexer : lex;
import dua.parser : parse;
import dua.module_resolver;
import dua.type_syntax;
import dua.value : ValueKind;
import std.algorithm : canFind;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.exception : enforce;
import std.string : indexOf, join, replace, startsWith;
import std.json : JSONValue;

struct ImportInfo
{
    string request, aliasName, sourceName, key;
    bool pathImport;
    size_t line, column;
}

struct ModuleExportInfo
{
    string name, kind, type;
    string displayType;
    bool runtimeValue;
    bool exported;
    string declarationKind;
    string[string] fields;
    string[] alternatives;
    string[] baseTypes;
    string[] parameterTypes;
    bool variadic;
    bool nominalValue;
    string sourceName;
    size_t line, column;
    size_t requiredParameterCount = size_t.max; // 未知のホスト署名では個数を断定しません。
}

/// Parsed and bound source. Import discovery never executes user code.
struct TypeConstructionInfo
{
    string type, displayType, sourceName;
    size_t line, column, endLine, endColumn;
}

final class BoundModule
{
    Program program;
    string key, sourceName, source;
    ImportInfo[] imports;
    ModuleExportInfo[] exports;
    ModuleExportInfo[] types;
    TypeConstructionInfo[] typeConstructions;
    private BoundModule constructionOwner;
    bool dynamicExports;
    bool exportsComplete = true;
    string[string] localTypes;
    string[string] publicTypes;
    bool[string] constructors;
    BoundModule[string] dependencies;
}

struct ModuleAnalysis
{
    BoundModule root;
    BoundModule[] modules;
    CheckDiagnostic[] diagnostics;
}

alias ImportResolver = ImportResolution delegate(string request, string importer, bool pathImport);
alias ModuleSourceReader = string delegate(ImportResolution resolution);
alias ModuleMetadataReader = ModuleExportInfo[] delegate(string key);
alias ModuleExportsCompleteReader = bool delegate(string key);

/// A single graph shares precisely the resolver used by ScriptEngine imports.
final class ModuleAnalyzer
{
    private ImportResolver resolver;
    private ModuleSourceReader reader;
    private ModuleMetadataReader metadata;
    private ModuleExportsCompleteReader exportsComplete;
    private BoundModule[string] cache;
    private bool[Expression] boundExpressions;
    private string[] active;
    BoundModule[] modules;

    this(ImportResolver resolver, ModuleSourceReader reader, ModuleMetadataReader metadata = null,
        ModuleExportsCompleteReader exportsComplete = null)
    {
        this.resolver = resolver;
        this.reader = reader;
        this.metadata = metadata;
        this.exportsComplete = exportsComplete;
    }

    BoundModule bind(string source, string sourceName, string key = "", BoundModule previous = null)
    {
        try return bindImpl(source, sourceName, key, previous);
        catch (Exception error)
        {
            if (scriptDiagnostic(error).sourceName.length) throw error;
            auto diagnostic = scriptDiagnostic(error);
            auto located = new SourceException(error.msg, error);
            located.diagnostic = diagnostic;
            located.diagnostic.sourceName = sourceName;
            located.diagnostic.sourceText = source;
            located.diagnostic.hasSourceText = true;
            throw located;
        }
    }

    private BoundModule bindImpl(string source, string sourceName, string key, BoundModule previous)
    {
        if (key.length)
        {
            enforce(!active.canFind(key), "Import cycle: " ~ (active ~ key).join(" -> "));
            if (auto cached = key in cache) return *cached;
        }
        auto unit = new BoundModule;
        unit.source = source;
        unit.sourceName = sourceName;
        unit.key = key;
        unit.program = parse(lex(source));
        active ~= key.length ? key : (sourceName.length ? sourceName : "<source>");
        scope(exit) active.length -= 1;
        if (previous !is null)
        {
            unit.localTypes = previous.localTypes.dup;
            unit.dependencies = previous.dependencies.dup;
            unit.constructors = previous.constructors.dup;
            unit.types = previous.types.dup;
        }
        collectTypes(unit.program.statements, unit);
        collectImports(unit.program.statements, unit);
        foreach (statement; unit.program.statements)
            bindStatement(statement, unit);
        collectTypeMetadata(unit.program.statements, unit);
        collectExports(unit);
        // Legacy modules may return a table computed by arbitrary script code.
        // Keep member checking conservative instead of executing that code.
        if (!unit.exports.length && !unit.program.hasInstanceDeclarations)
            foreach (statement; unit.program.statements)
                if (statement.kind == Statement.Kind.return_ || statement.kind == Statement.Kind.expression)
                    unit.dynamicExports = true;
        if (metadata !is null)
            foreach (export_; metadata(key))
            {
                unit.exports ~= export_;
                if (export_.kind == "type") unit.publicTypes[export_.name] = export_.type;
            }
        unit.exportsComplete = !unit.dynamicExports && (exportsComplete is null || exportsComplete(key));
        modules ~= unit;
        if (key.length) cache[key] = unit;
        return unit;
    }

    private void collectTypes(Statement[] statements, BoundModule unit, bool nested = false)
    {
        bool[string] declared;
        foreach (statement; statements)
        {
            if (statement.kind == Statement.Kind.alias_ || statement.kind == Statement.Kind.tableDecl
                || statement.kind == Statement.Kind.structDecl)
            {
                auto publicName = statement.name;
                auto origin = unit.key.length ? unit.key : unit.source;
                import std.conv : to;
                string identity = nested ? ("__dua_scope_" ~ sha256Of(origin).toHexString ~ "_"
                    ~ statement.line.to!string ~ "_" ~ statement.column.to!string ~ "_" ~ publicName).idup
                    : unit.key.length ? ("__dua_module_" ~ sha256Of(unit.key).toHexString ~ "_" ~ publicName).idup : publicName;
                enforce((publicName in declared) is null && (nested || (publicName in unit.localTypes) is null),
                    "Duplicate type '" ~ publicName ~ "' in '" ~ unit.sourceName ~ "'");
                declared[publicName] = true;
                unit.localTypes[publicName] = identity;
                statement.publicTypeName = publicName;
                statement.scopedType = nested || unit.key.length > 0;
                if (statement.kind == Statement.Kind.structDecl) unit.constructors[publicName] = true;
                if (statement.isExported) unit.publicTypes[publicName] = identity;
            }
        }
    }

    private void bindScope(Statement[] statements, BoundModule parent)
    {
        if (!statements.length) return;
        auto scope_ = new BoundModule;
        scope_.key = parent.key; scope_.sourceName = parent.sourceName; scope_.source = parent.source;
        scope_.localTypes = parent.localTypes.dup;
        scope_.publicTypes = parent.publicTypes.dup;
        scope_.dependencies = parent.dependencies;
        scope_.constructionOwner = parent.constructionOwner is null ? parent : parent.constructionOwner;
        collectTypes(statements, scope_, true);
        foreach (statement; statements) bindStatement(statement, scope_);
    }

    private void collectImports(Statement[] statements, BoundModule unit)
    {
        foreach (statement; statements)
        {
            if (statement.kind == Statement.Kind.import_)
            {
                try
                {
                    auto resolution = resolver(statement.name, unit.sourceName, statement.isPathImport);
                    enforce(resolution.key.length, unresolvedImportMessage(resolution));
                    auto dependency = bind(reader(resolution), resolution.sourceName, resolution.key);
                    unit.dependencies[statement.aliasName] = dependency;
                    unit.imports ~= ImportInfo(statement.name, statement.aliasName, resolution.sourceName,
                        resolution.key, statement.isPathImport, statement.line, statement.column);
                }
                catch (Exception error)
                {
                    if (scriptDiagnostic(error).sourceName.length) throw error;
                    auto located = new SourceException(error.msg, error);
                    located.diagnostic.line = statement.line;
                    located.diagnostic.column = statement.column;
                    located.diagnostic.sourceName = unit.sourceName;
                    located.diagnostic.sourceText = unit.source;
                    located.diagnostic.hasSourceText = true;
                    throw located;
                }
            }
            collectImports(statement.body, unit);
            if (statement.elseBranch !is null) collectImports([statement.elseBranch], unit);
            if (statement.init !is null) collectImports([statement.init], unit);
            foreach (branch; statement.switchCases) collectImports(branch.body, unit);
            visitStatementLambdas(statement, body => collectImports(body, unit));
        }
    }

    private void visitStatementLambdas(Statement statement, void delegate(Statement[]) visit)
    {
        visitLambdas(statement.metatableReference,visit);
        foreach (value; statement.parameterDefaults) visitLambdas(value, visit);
        if (statement.expressions.length) foreach (expression; statement.expressions) visitLambdas(expression, visit);
        else visitLambdas(statement.expression, visit);
        if (statement.targets.length) foreach (target; statement.targets) visitLambdas(target, visit);
        else visitLambdas(statement.target, visit);
        visitLambdas(statement.condition, visit); visitLambdas(statement.iterable, visit); visitLambdas(statement.rangeEnd, visit);
        foreach (branch; statement.switchCases) visitLambdas(branch.pattern, visit);
    }

    private void visitLambdas(Expression expression, void delegate(Statement[]) visit)
    {
        if (expression is null) return;
        switch (expression.kind)
        {
            case Expression.Kind.with_:
                auto with_=cast(WithExpression)expression;
                visitLambdas(with_.target,visit);visitLambdas(with_.body,visit);break;
            case Expression.Kind.function_:
                auto fn=cast(FunctionExpression)expression;
                foreach(value;fn.parameterDefaults)visitLambdas(value,visit);
                visit(fn.body);break;
            case Expression.Kind.unary: visitLambdas((cast(UnaryExpression)expression).operand, visit); break;
            case Expression.Kind.cast_: visitLambdas((cast(CastExpression)expression).operand, visit); break;
            case Expression.Kind.binary:
                auto binary = cast(BinaryExpression)expression;
                visitLambdas(binary.left, visit); visitLambdas(binary.right, visit); break;
            case Expression.Kind.ternary:
                auto ternary = cast(TernaryExpression)expression;
                visitLambdas(ternary.condition, visit); visitLambdas(ternary.whenTrue, visit); visitLambdas(ternary.whenFalse, visit); break;
            case Expression.Kind.call:
                auto call = cast(CallExpression)expression;
                visitLambdas(call.callee, visit); foreach (argument; call.arguments) visitLambdas(argument, visit); break;
            case Expression.Kind.array:
                foreach (item; (cast(ArrayExpression)expression).elements) visitLambdas(item, visit); break;
            case Expression.Kind.associativeArray:
                auto aa = cast(AssociativeArrayExpression)expression;
                foreach (item; aa.keys) visitLambdas(item, visit); foreach (item; aa.values) visitLambdas(item, visit); break;
            case Expression.Kind.table:
                foreach (entry; (cast(TableExpression)expression).entries)
                { visitLambdas(entry.keyExpression, visit); visitLambdas(entry.value, visit); } break;
            case Expression.Kind.get: visitLambdas((cast(GetExpression)expression).target, visit); break;
            case Expression.Kind.index:
                auto indexed = cast(IndexExpression)expression;
                visitLambdas(indexed.target, visit); foreach (index; indexed.indices) visitLambdas(index, visit);
                visitLambdas(indexed.sliceStart, visit); visitLambdas(indexed.sliceEnd, visit); break;
            default: break;
        }
    }

    private string typeName(string name, BoundModule unit)
    {
        string nonNullInner;
        if (splitNonNullType(name, nonNullInner)) return nonNullType(typeName(nonNullInner, unit));
        if (!name.length || isStringLiteralType(name) || isBuiltinTypeName(name)) return name;
        string element, key;
        if (splitContainerType(name, element, key))
            return typeName(element, unit) ~ "[" ~ (key.length ? typeName(key, unit) : "") ~ "]";
        auto delegateAt = name.indexOf(" delegate(");
        if (delegateAt >= 0)
        {
            // Preserve nested arrays and nested delegate parameter lists.
            auto parameters = name[delegateAt + 10 .. $ - 1];
            string[] prepared;
            size_t start, depth;
            foreach (i, ch; parameters)
            {
                if (ch == '(' || ch == '[') ++depth;
                else if (ch == ')' || ch == ']') --depth;
                else if (ch == ',' && depth == 0)
                {
                    prepared ~= typeName(parameters[start .. i], unit);
                    start = i + 1;
                    if (start < parameters.length && parameters[start] == ' ') ++start;
                }
            }
            if (parameters.length) prepared ~= typeName(parameters[start .. $], unit);
            return typeName(name[0 .. delegateAt], unit) ~ " delegate(" ~ prepared.join(",") ~ ")";
        }
        if (auto local = name in unit.localTypes) return *local;
        auto dot = name.indexOf('.');
        if (dot >= 0)
        {
            auto imported = name[0 .. dot] in unit.dependencies;
            enforce(imported !is null, "Unknown type module '" ~ name[0 .. dot] ~ "' in '" ~ unit.sourceName ~ "'");
            auto exported = name[dot + 1 .. $] in (*imported).publicTypes;
            enforce(exported !is null, "Module '" ~ name[0 .. dot] ~ "' does not export type '" ~ name[dot + 1 .. $] ~ "'");
            return *exported;
        }
        return name;
    }

    private void bindStatement(Statement statement, BoundModule unit)
    {
        if (statement is null) return;
        try bindStatementImpl(statement, unit);
        catch (Exception error)
        {
            if (scriptDiagnostic(error).sourceName.length) throw error;
            auto located = new SourceException(error.msg, error);
            located.diagnostic.line = statement.line; located.diagnostic.column = statement.column;
            located.diagnostic.sourceName = unit.sourceName;
            located.diagnostic.sourceText = unit.source; located.diagnostic.hasSourceText = true;
            throw located;
        }
    }

    private void bindStatementImpl(Statement statement, BoundModule unit)
    {
        if (statement is null) return;
        statement.declaredType = typeName(statement.declaredType, unit);
        statement.returnType = typeName(statement.returnType, unit);
        foreach (ref parameter; statement.parameterTypes) parameter = typeName(parameter, unit);
        if (statement.publicTypeName.length)
        {
            statement.name = unit.localTypes[statement.publicTypeName];
            if (statement.kind == Statement.Kind.alias_ || statement.kind == Statement.Kind.tableDecl)
                foreach (ref name; statement.names) name = typeName(name, unit);
        }
        bindExpression(statement.expression, unit);
        bindExpression(statement.metatableReference,unit);
        foreach (value; statement.parameterDefaults) bindExpression(value, unit);
        foreach (expression; statement.expressions) bindExpression(expression, unit);
        bindExpression(statement.target, unit);
        foreach (target; statement.targets) bindExpression(target, unit);
        bindExpression(statement.condition, unit);
        bindExpression(statement.iterable, unit);
        bindExpression(statement.rangeEnd, unit);
        bindScope(statement.body, unit);
        bindStatement(statement.elseBranch, unit);
        bindStatement(statement.init, unit);
        bindStatement(statement.incrementStatement, unit);
        foreach (branch; statement.switchCases)
        {
            bindExpression(branch.pattern, unit);
            bindScope(branch.body, unit);
        }
    }

    private void bindExpression(Expression expression, BoundModule unit)
    {
        if (expression is null) return;
        // AST statements expose both a primary expression and the same node in
        // their expression list. Bind each node once, including lambda scopes.
        if ((expression in boundExpressions) !is null) return;
        boundExpressions[expression] = true;
        final switch (expression.kind)
        {
            case Expression.Kind.with_:
                auto with_=cast(WithExpression)expression;
                bindExpression(with_.target,unit);bindExpression(with_.body,unit);break;
            case Expression.Kind.literal: break;
            case Expression.Kind.variable:
                break;
            case Expression.Kind.unary: bindExpression((cast(UnaryExpression) expression).operand, unit); break;
            case Expression.Kind.cast_:
                auto conversion = cast(CastExpression) expression;
                conversion.targetType = typeName(conversion.targetType, unit);
                bindExpression(conversion.operand, unit); break;
            case Expression.Kind.binary:
                auto binary = cast(BinaryExpression) expression;
                bindExpression(binary.left, unit);
                if (binary.operatorSymbol == "is")
                    (cast(VariableExpression) binary.right).name = typeName((cast(VariableExpression) binary.right).name, unit);
                else bindExpression(binary.right, unit);
                break;
            case Expression.Kind.ternary:
                auto ternary = cast(TernaryExpression) expression;
                bindExpression(ternary.condition, unit); bindExpression(ternary.whenTrue, unit); bindExpression(ternary.whenFalse, unit); break;
            case Expression.Kind.call:
                auto call = cast(CallExpression) expression;
                bindExpression(call.callee, unit);
                foreach (argument; call.arguments) bindExpression(argument, unit);
                break;
            case Expression.Kind.array:
                foreach (item; (cast(ArrayExpression) expression).elements) bindExpression(item, unit); break;
            case Expression.Kind.associativeArray:
                auto aa = cast(AssociativeArrayExpression) expression;
                foreach (item; aa.keys) bindExpression(item, unit);
                foreach (item; aa.values) bindExpression(item, unit); break;
            case Expression.Kind.table:
                auto table = cast(TableExpression)expression;
                if (table.targetType.length)
                {
                    table.targetType = typeName(table.targetType, unit);
                    auto owner = unit.constructionOwner is null ? unit : unit.constructionOwner;
                    owner.typeConstructions ~= TypeConstructionInfo(table.targetType, table.sourceType,
                        unit.sourceName, table.line, table.column, table.endLine, table.endColumn);
                }
                foreach (entry; table.entries)
                { bindExpression(entry.keyExpression, unit); bindExpression(entry.value, unit); } break;
            case Expression.Kind.function_:
                auto function_ = cast(FunctionExpression) expression;
                foreach (ref parameter; function_.parameterTypes) parameter = typeName(parameter, unit);
                function_.returnType = typeName(function_.returnType, unit);
                foreach(value;function_.parameterDefaults)bindExpression(value,unit);
                bindScope(function_.body, unit); break;
            case Expression.Kind.get: bindExpression((cast(GetExpression) expression).target, unit); break;
            case Expression.Kind.index:
                auto indexed = cast(IndexExpression) expression;
                bindExpression(indexed.target, unit);
                foreach (index; indexed.indices) bindExpression(index, unit);
                bindExpression(indexed.sliceStart, unit); bindExpression(indexed.sliceEnd, unit); break;
        }
    }

    private string inferredValueType(Expression expression)
    {
        if (expression is null) return "any";
        switch (expression.kind)
        {
            case Expression.Kind.with_:return inferredValueType((cast(WithExpression)expression).body);
            case Expression.Kind.literal:
                switch ((cast(LiteralExpression)expression).value.kind)
                {
                    case ValueKind.integer: return "int";
                    case ValueKind.floating: return "double";
                    case ValueKind.boolean: return "bool";
                    case ValueKind.string_: return "string";
                    case ValueKind.null_: return "null";
                    default: return "any";
                }
            case Expression.Kind.array: return "array";
            case Expression.Kind.associativeArray: return "associativeArray";
            case Expression.Kind.table:
                auto table = cast(TableExpression)expression;
                return table.targetType.length ? table.targetType : "table";
            case Expression.Kind.function_: return "function";
            default: return "any";
        }
    }

    private ModuleExportInfo describe(Statement statement, BoundModule unit, string name = "", size_t index = 0)
    {
            ModuleExportInfo info;
            info.sourceName = unit.sourceName; info.line = statement.line; info.column = statement.column;
            info.name = name.length ? name : statement.publicTypeName.length ? statement.publicTypeName : statement.name;
            info.type = statement.declaredType;
            info.displayType = statement.declaredType;
            info.exported = statement.isExported;
            if (statement.publicTypeName.length)
            {
                info.kind = "type"; info.type = statement.name;
                info.displayType = statement.publicTypeName;
                info.runtimeValue = statement.kind == Statement.Kind.structDecl;
                info.declarationKind = statement.kind == Statement.Kind.alias_ ? "alias"
                    : statement.kind == Statement.Kind.tableDecl ? "table" : "struct";
                if (statement.kind == Statement.Kind.alias_) info.alternatives = statement.names;
                else
                {
                    info.baseTypes = statement.names;
                    foreach (i, field; statement.parameters) info.fields[field] = statement.parameterTypes[i];
                }
            }
            else if (statement.kind == Statement.Kind.functionDecl)
            { info.kind = "function"; info.type = statement.returnType; info.displayType = statement.returnType;
                info.parameterTypes = statement.parameterTypes; info.variadic = statement.variadic;
                info.requiredParameterCount = dua.ast.requiredParameterCount(statement.parameters.length,
                    statement.parameterDefaults, statement.variadic); }
            else
            {
                info.kind = "variable";
                auto initializer = index < statement.expressions.length ? statement.expressions[index] : null;
                if (initializer !is null && initializer.kind == Expression.Kind.table)
                    info.nominalValue = (cast(TableExpression)initializer).targetType.length > 0;
                if (info.type == "auto")
                    info.type = info.displayType = inferredValueType(index < statement.expressions.length ? statement.expressions[index] : null);
                if (statement.kind == Statement.Kind.import_) info.type = info.displayType = "table";
            }
            foreach (publicName, identity; unit.localTypes)
                info.displayType = info.displayType.replace(identity, publicName);
            foreach (aliasName, dependency; unit.dependencies)
                foreach (publicName, identity; dependency.publicTypes)
                    info.displayType = info.displayType.replace(identity, aliasName ~ "." ~ publicName);
            return info;
    }

    private void collectTypeMetadata(Statement[] statements, BoundModule unit)
    {
        foreach (statement; statements)
        {
            if (statement.publicTypeName.length) unit.types ~= describe(statement, unit);
            collectTypeMetadata(statement.body, unit);
            if (statement.elseBranch !is null) collectTypeMetadata([statement.elseBranch], unit);
            if (statement.init !is null) collectTypeMetadata([statement.init], unit);
            foreach (branch; statement.switchCases) collectTypeMetadata(branch.body, unit);
            visitStatementLambdas(statement, body => collectTypeMetadata(body, unit));
        }
    }

    private void collectExports(BoundModule unit)
    {
        ModuleExportInfo[string] result;
        foreach (statement; unit.program.statements)
        {
            if (statement.isExported)
            {
                if (statement.kind == Statement.Kind.variableDecl)
                    foreach (i, name; statement.names) result[name] = describe(statement, unit, name, i);
                else
                {
                    auto info = describe(statement, unit);
                    result[info.name] = info;
                }
            }
            if (statement.kind == Statement.Kind.export_)
                foreach (candidate; unit.program.statements)
                {
                    if (candidate.publicTypeName.length) continue;
                    if (candidate.kind == Statement.Kind.variableDecl)
                        foreach (i, name; candidate.names)
                            if (name == statement.name) result[name] = describe(candidate, unit, name, i);
                    if (candidate.kind == Statement.Kind.functionDecl && candidate.name == statement.name)
                        result[statement.name] = describe(candidate, unit);
                    if (candidate.kind == Statement.Kind.import_ && candidate.aliasName == statement.name)
                        result[statement.name] = describe(candidate, unit, statement.name);
                }
        }
        foreach (info; result.byValue) { auto exported = info; exported.exported = true; unit.exports ~= exported; }
        import std.algorithm : sort;
        unit.exports.sort!((a, b) => a.name < b.name);
    }
}
