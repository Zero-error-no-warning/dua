module dua.scope_planner;

import dua.ast;
import dua.scope_layout;

// Reserve names without executing declarations or changing visibility. Syntax
// added later by an embedding host goes through Environment's dynamic bindings.
package(dua) ScopeLayout planScope(Statement[] body, string[] initialNames = null)
{
    string[] names = initialNames.dup;
    void collect(Statement statement)
    {
        if (statement is null) return;
        switch (statement.kind)
        {
            case Statement.Kind.variableDecl:
                names ~= statement.names;
                break;
            case Statement.Kind.functionDecl:
                names ~= statement.name;
                break;
            case Statement.Kind.import_:
                names ~= statement.aliasName;
                break;
            case Statement.Kind.if_:
                foreach (child; statement.body) collect(child);
                collect(statement.elseBranch);
                break;
            case Statement.Kind.while_:
                foreach (child; statement.body) collect(child);
                break;
            default:
                // Blocks, loops, try/catch and switch cases own their scopes.
                break;
        }
    }
    foreach (statement; body) collect(statement);
    return new ScopeLayout(names);
}

package(dua) ScopeLayout layoutFor(Statement statement)
{
    if (statement.scopeLayout !is null) return statement.scopeLayout;
    final switch (statement.kind)
    {
        case Statement.Kind.for_:
            statement.scopeLayout = planScope(
                [statement.init, statement.incrementStatement] ~ statement.body);
            break;
        case Statement.Kind.foreach_:
            auto names = [statement.iteratorName];
            if (statement.iteratorSecondName.length) names ~= statement.iteratorSecondName;
            statement.scopeLayout = planScope(statement.body, names);
            break;
        case Statement.Kind.functionDecl:
            statement.scopeLayout = planScope(statement.body, ["this"] ~ statement.parameters);
            break;
        case Statement.Kind.variableDecl, Statement.Kind.assign, Statement.Kind.expression,
             Statement.Kind.return_, Statement.Kind.block, Statement.Kind.if_,
             Statement.Kind.while_, Statement.Kind.switch_, Statement.Kind.break_,
             Statement.Kind.continue_, Statement.Kind.yield_, Statement.Kind.alias_,
             Statement.Kind.tableDecl, Statement.Kind.structDecl, Statement.Kind.try_,
             Statement.Kind.import_, Statement.Kind.export_:
            statement.scopeLayout = planScope(statement.body);
            break;
    }
    return statement.scopeLayout;
}

package(dua) ScopeLayout layoutFor(FunctionExpression expression)
{
    if (expression.scopeLayout is null)
        expression.scopeLayout = planScope(expression.body, ["this"] ~ expression.parameters);
    return expression.scopeLayout;
}

package(dua) ScopeLayout layoutFor(SwitchCase switchCase)
{
    if (switchCase.scopeLayout is null)
        switchCase.scopeLayout = planScope(switchCase.body);
    return switchCase.scopeLayout;
}

package(dua) ScopeLayout catchLayoutFor(Statement statement)
{
    if (statement.elseBranch.scopeLayout is null)
        statement.elseBranch.scopeLayout = planScope(statement.elseBranch.body, [statement.name]);
    return statement.elseBranch.scopeLayout;
}
