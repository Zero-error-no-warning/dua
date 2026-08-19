module dua.ast;

import dua.value : Value;

final class Program
{
    Statement[] statements;

    this(Statement[] statements)
    {
        this.statements = statements;
    }
}

final class TableEntry
{
    string key;
    Expression keyExpression;
    Expression value;
    bool isArrayEntry;
    bool isSpread;

    this(string key, Expression keyExpression, Expression value, bool isArrayEntry = false)
    {
        this.key = key;
        this.keyExpression = keyExpression;
        this.value = value;
        this.isArrayEntry = isArrayEntry;
    }
}

final class SwitchCase
{
    bool isDefault;
    Expression pattern;
    Statement[] body;

    this(bool isDefault, Expression pattern, Statement[] body)
    {
        this.isDefault = isDefault;
        this.pattern = pattern;
        this.body = body;
    }
}

/// Common source information shared by every syntax node.  New expression
/// forms can derive from this node contract without adding more generic
/// location fields to each AST container.
abstract class AstNode
{
    size_t line;
    size_t column;
}

final class Statement : AstNode
{
    enum Kind
    {
        variableDecl,
        assign,
        expression,
        return_,
        functionDecl,
        block,
        if_,
        while_,
        for_,
        foreach_,
        switch_,
        break_,
        continue_,
        yield_,
        alias_,
        tableDecl,
        structDecl,
        try_,
        import_,
        export_
    }

    Kind kind;
    string name;
    string declaredType;
    string returnType;
    string aliasName;
    string[] names;
    bool isExported;
    Expression expression;
    Expression[] expressions;
    Expression target;
    Expression[] targets;
    string[] parameters;
    string[] parameterTypes;
    bool variadic;
    Statement[] body;
    Statement elseBranch;
    Statement init;
    Statement incrementStatement;
    Expression condition;
    string iteratorName;
    string iteratorSecondName;
    Expression iterable;
    SwitchCase[] switchCases;

    this(Kind kind)
    {
        this.kind = kind;
    }
}

final class Expression : AstNode
{
    enum Kind
    {
        literal,
        variable,
        unary,
        binary,
        ternary,
        call,
        array,
        table,
        function_,
        get,
        index
    }

    Kind kind;
    Value literalValue;
    string identifier;
    string operatorSymbol;
    /// Declared result type for function expressions. Empty means inferred/dynamic.
    string returnType;
    Expression left;
    Expression middle;
    Expression right;
    Expression[] arguments;
    bool[] argumentSpreads;
    TableEntry[] entries;
    string[] parameters;
    bool variadic;
    Statement[] body;

    this(Kind kind)
    {
        this.kind = kind;
    }
}
