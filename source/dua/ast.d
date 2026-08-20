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

abstract class Expression : AstNode
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

    immutable Kind kind;

    protected this(Kind kind)
    {
        this.kind = kind;
    }
}

final class LiteralExpression : Expression
{
    Value value;
    this(Value value) { super(Kind.literal); this.value = value; }
}

final class VariableExpression : Expression
{
    string name;
    this(string name) { super(Kind.variable); this.name = name; }
}

final class UnaryExpression : Expression
{
    string operatorSymbol;
    Expression operand;
    this(string operatorSymbol, Expression operand)
    {
        super(Kind.unary);
        this.operatorSymbol = operatorSymbol;
        this.operand = operand;
    }
}

final class BinaryExpression : Expression
{
    string operatorSymbol;
    Expression left;
    Expression right;
    this(Expression left, string operatorSymbol, Expression right)
    {
        super(Kind.binary);
        this.left = left;
        this.operatorSymbol = operatorSymbol;
        this.right = right;
    }
}

final class TernaryExpression : Expression
{
    Expression condition;
    Expression whenTrue;
    Expression whenFalse;
    this(Expression condition, Expression whenTrue, Expression whenFalse)
    {
        super(Kind.ternary);
        this.condition = condition;
        this.whenTrue = whenTrue;
        this.whenFalse = whenFalse;
    }
}

final class CallExpression : Expression
{
    Expression callee;
    Expression[] arguments;
    this(Expression callee, Expression[] arguments)
    {
        super(Kind.call);
        this.callee = callee;
        this.arguments = arguments;
    }
}

final class ArrayExpression : Expression
{
    Expression[] elements;
    bool[] elementSpreads;
    this(Expression[] elements, bool[] elementSpreads = null)
    {
        super(Kind.array);
        this.elements = elements;
        this.elementSpreads = elementSpreads;
    }
}

final class TableExpression : Expression
{
    TableEntry[] entries;
    this(TableEntry[] entries) { super(Kind.table); this.entries = entries; }
}

final class FunctionExpression : Expression
{
    string[] parameters;
    bool variadic;
    Statement[] body;
    string returnType;
    this(string[] parameters = null, bool variadic = false,
        Statement[] body = null, string returnType = "")
    {
        super(Kind.function_);
        this.parameters = parameters;
        this.variadic = variadic;
        this.body = body;
        this.returnType = returnType;
    }
}

final class GetExpression : Expression
{
    Expression target;
    string memberName;
    this(Expression target, string memberName)
    {
        super(Kind.get);
        this.target = target;
        this.memberName = memberName;
    }
}

final class IndexExpression : Expression
{
    Expression target;
    Expression index;
    Expression sliceStart;
    Expression sliceEnd;
    bool isSlice;

    this(Expression target, Expression index)
    {
        super(Kind.index);
        this.target = target;
        this.index = index;
    }

    this(Expression target, Expression sliceStart, Expression sliceEnd)
    {
        super(Kind.index);
        this.target = target;
        this.sliceStart = sliceStart;
        this.sliceEnd = sliceEnd;
        isSlice = true;
    }
}
