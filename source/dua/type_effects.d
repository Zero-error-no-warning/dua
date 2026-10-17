module dua.type_effects;

// null適合に関係する型定義だけを抽象実行します。ホスト関数は実行しません。
import dua.ast;
import dua.value : ValueKind, valuesEqual;
import std.algorithm : canFind;
import std.exception : enforce;

private class Symbol { Scope owner; Function declaration; this(Scope owner) { this.owner = owner; } }
private class Scope
{
    Scope parent;
    Symbol[string] symbols;
    Symbol declare(string name)
    {
        if (auto found = name in symbols) return *found;
        auto result = new Symbol(this); symbols[name] = result; return result;
    }
    Symbol find(string name)
    {
        if (auto found = name in symbols) return *found;
        return parent is null ? null : parent.find(name);
    }
}
private struct Targets
{
    Function[] known;
    bool unknown = true;
}
private Targets unite(Targets a, Targets b)
{
    foreach (fn; b.known) if (!a.known.canFind(fn)) a.known ~= fn;
    a.unknown |= b.unknown;
    return a;
}
private class State
{
    bool[string] nullable;
    Targets[Symbol] bindings;
    State copy() { auto r = new State; r.nullable = nullable.dup; r.bindings = bindings.dup; return r; }
}
private State join(State a, State b)
{
    if (a is null) return b is null ? null : b.copy();
    if (b is null) return a.copy();
    auto r = a.copy();
    foreach (name; r.nullable.keys) if ((name in b.nullable) is null) r.nullable.remove(name);
    foreach (symbol, targets; b.bindings)
        r.bindings[symbol] = unite(r.bindings.get(symbol, Targets.init), targets);
    foreach (symbol; a.bindings.byKey)
        if ((symbol in b.bindings) is null) r.bindings[symbol].unknown = true;
    return r;
}
private struct Flow
{
    State normal, returned, broke, continued, thrown;
    void absorb(Flow other)
    {
        normal = join(normal, other.normal); returned = join(returned, other.returned);
        broke = join(broke, other.broke); continued = join(continued, other.continued);
        thrown = join(thrown, other.thrown);
    }
}
private struct Evaluated { State normal, thrown; Targets value; }
private class Function
{
    AstNode node;
    Scope closure, environment;
    string[] parameters;
    Statement[] body;
    State defaultState;
    bool[string] normalRemovals, throwRemovals;
    bool active;
}
private enum Mode { live, fallback, dead }

package(dua) final class TypeEffects
{
    private bool[string][AstNode][3] before, after;
    private AstNode[][CallExpression][3] callees;
    private Scope[Object] scopes;
    private Function[AstNode] functions;
    private Function[] functionOrder;
    private bool changed;
    private size_t depth;

    this(Program program, string[] nativeClasses)
    {
        auto root = scopeFor(program, null, program.statements);
        auto initial = new State;
        foreach (name; nativeClasses) initial.nullable[name] = true;
        // 再帰・相互再帰では除外される型名の要約を単調に広げて固定点へ進めます。
        foreach (pass; 0 .. 128)
        {
            before = typeof(before).init; after = typeof(after).init; callees = typeof(callees).init;
            changed = false;
            foreach (fn; functionOrder) fn.defaultState = null;
            statements(program.statements, root, initial.copy(), Mode.live);
            for (size_t index; index < functionOrder.length; ++index)
            {
                auto fn = functionOrder[index];
                auto defaults = fn.defaultState is null ? initial.copy() : fn.defaultState.copy();
                // 未使用の関数も診断しますが、その定義は呼出し元の型状態を変えません。
                for (auto environment = fn.closure; environment !is null; environment = environment.parent)
                    foreach (symbol; environment.symbols.byValue)
                        if (symbol.declaration !is null && (symbol !in defaults.bindings))
                            defaults.bindings[symbol] = Targets([symbol.declaration], false);
                invoke(fn, defaults, null, Mode.fallback);
            }
            if (!changed) return;
        }
        enforce(false, "Type-definition effects did not converge");
    }

    bool applyBefore(AstNode node, ref bool[string] names) { return apply(before, node, names); }
    bool applyAfter(AstNode node, ref bool[string] names) { return apply(after, node, names); }
    AstNode[] knownCallees(CallExpression call)
    {
        foreach (mode; 0 .. 3) if (auto found = call in callees[mode]) return *found;
        return null;
    }

    private bool apply(ref bool[string][AstNode][3] maps, AstNode node, ref bool[string] names)
    {
        foreach (mode; 0 .. 3)
            if (auto found = node in maps[mode]) { names = (*found).dup; return true; }
        return false;
    }
    private void record(ref bool[string][AstNode][3] maps, AstNode node, State state, Mode mode)
    {
        if (node is null || state is null) return;
        if (auto old = node in maps[mode])
        {
            foreach (name; (*old).keys) if ((name !in state.nullable)) (*old).remove(name);
        }
        else maps[mode][node] = state.nullable.dup;
    }
    private Scope scopeFor(Object node, Scope parent, Statement[] body, string[] parameters = null)
    {
        if (auto found = node in scopes) return *found;
        auto result = new Scope; result.parent = parent; scopes[node] = result;
        foreach (name; parameters) result.declare(name);
        foreach (statement; body)
        {
            if (statement.kind == Statement.Kind.variableDecl)
                foreach (name; statement.names) result.declare(name);
            else if (statement.kind == Statement.Kind.functionDecl || statement.kind == Statement.Kind.structDecl)
                result.declare(statement.name);
            else if (statement.kind == Statement.Kind.import_)
                result.declare(statement.aliasName);
        }
        foreach (statement; body)
            if (statement.kind == Statement.Kind.functionDecl)
                result.declare(statement.name).declaration = functionFor(statement, result);
        return result;
    }
    private Function functionFor(AstNode node, Scope closure)
    {
        if (auto found = node in functions) return *found;
        auto fn = new Function; fn.node = node; fn.closure = closure;
        functions[node] = fn; functionOrder ~= fn;
        if (auto statement = cast(Statement) node) { fn.parameters = statement.parameters; fn.body = statement.body; }
        else { auto expression = cast(FunctionExpression) node; fn.parameters = expression.parameters; fn.body = expression.body; }
        fn.environment = scopeFor(node, closure, fn.body, fn.parameters);
        return fn;
    }
    private static bool literalCondition(Expression expression, out bool value)
    {
        if (expression is null || expression.kind != Expression.Kind.literal) return false;
        value = (cast(LiteralExpression) expression).value.truthy(); return true;
    }
    private static bool inside(Scope environment, Scope ancestor)
    {
        for (; environment !is null; environment = environment.parent) if (environment is ancestor) return true;
        return false;
    }
    private void restoreLocals(State state, State caller, Scope local)
    {
        if (state is null) return;
        foreach (symbol; state.bindings.keys)
            if (inside(symbol.owner, local))
            {
                if (auto old = symbol in caller.bindings) state.bindings[symbol] = *old;
                else state.bindings.remove(symbol);
            }
    }
    private Evaluated invoke(Function fn, State caller, Targets[] arguments, Mode mode)
    {
        if (caller is null) return Evaluated.init;
        if (fn.active)
        {
            auto normal = caller.copy(), thrown = caller.copy();
            foreach (name; fn.normalRemovals.byKey) normal.nullable.remove(name);
            foreach (name; fn.throwRemovals.byKey) thrown.nullable.remove(name);
            return Evaluated(normal, thrown, Targets.init);
        }
        enforce(depth < 128, "Type-definition call nesting is too deep");
        ++depth; fn.active = true;
        scope(exit) { --depth; fn.active = false; }
        auto state = caller.copy();
        foreach (index, name; fn.parameters)
            state.bindings[fn.environment.declare(name)] = index < arguments.length ? arguments[index] : Targets.init;
        auto result = statements(fn.body, fn.environment, state, mode);
        auto normal = join(join(result.normal, result.returned), join(result.broke, result.continued));
        foreach (name; caller.nullable.byKey)
        {
            if (normal !is null && (name !in normal.nullable) && (name !in fn.normalRemovals))
            { fn.normalRemovals[name] = true; changed = true; }
            if (result.thrown !is null && (name !in result.thrown.nullable) && (name !in fn.throwRemovals))
            { fn.throwRemovals[name] = true; changed = true; }
        }
        restoreLocals(normal, caller, fn.environment); restoreLocals(result.thrown, caller, fn.environment);
        return Evaluated(normal, result.thrown, Targets.init);
    }
    private Evaluated expression(Expression node, Scope environment, State state, Mode mode)
    {
        if (node is null || state is null) return Evaluated(state, null, Targets.init);
        record(before, node, state, mode);
        Evaluated result = Evaluated(state, null, Targets.init);
        void evaluateChild(Expression child)
        {
            auto next = expression(child, environment, result.normal, mode);
            result.normal = next.normal; result.thrown = join(result.thrown, next.thrown);
            result.value = next.value;
        }
        final switch (node.kind)
        {
            case Expression.Kind.literal: break;
            case Expression.Kind.variable:
                auto symbol = environment.find((cast(VariableExpression) node).name);
                if (symbol !is null) result.value = state.bindings.get(symbol, Targets.init);
                break;
            case Expression.Kind.function_:
                auto fn = functionFor(node, environment); fn.defaultState = state.copy();
                result.value = Targets([fn], false); break;
            case Expression.Kind.call:
                auto call = cast(CallExpression) node;
                Targets[] arguments;
                // Duaは引数を先に評価してからcalleeを読み取ります。
                foreach (arg; call.arguments) { evaluateChild(arg); arguments ~= result.value; }
                evaluateChild(call.callee);
                if (result.normal is null) break;
                auto targets = result.value;
                if (call !in callees[mode]) callees[mode][call] = null;
                foreach (target; targets.known)
                {
                    if (!callees[mode][call].canFind(target.node)) callees[mode][call] ~= target.node;
                }
                if (!targets.known.length)
                {
                    // 実行前の前方参照でも、従来の宣言シグネチャ診断は保持します。
                    if (call.callee.kind == Expression.Kind.variable)
                    {
                        auto symbol = environment.find((cast(VariableExpression) call.callee).name);
                        if (symbol !is null && symbol.declaration !is null && (symbol !in result.normal.bindings))
                            callees[mode][call] = [symbol.declaration.node];
                    }
                }
                auto input = result.normal;
                result.normal = targets.unknown ? input : null;
                result.thrown = join(result.thrown, targets.unknown ? input : null);
                foreach (fn; targets.known)
                {
                    auto invoked = invoke(fn, input, arguments, mode);
                    result.normal = join(result.normal, invoked.normal);
                    result.thrown = join(result.thrown, invoked.thrown);
                }
                result.value = Targets.init; break;
            case Expression.Kind.binary:
                auto binary = cast(BinaryExpression) node;
                evaluateChild(binary.left);
                if (binary.operatorSymbol == "&&" || binary.operatorSymbol == "||")
                {
                    bool condition; auto known = literalCondition(binary.left, condition);
                    auto evaluateRight = binary.operatorSymbol == "&&" ? condition : !condition;
                    if (!known || evaluateRight)
                    {
                        auto skipped = result.normal;
                        evaluateChild(binary.right);
                        if (!known) result.normal = join(skipped, result.normal);
                    }
                    else expression(binary.right, environment, result.normal.copy(), Mode.dead);
                }
                else if (binary.operatorSymbol != "is") evaluateChild(binary.right);
                result.value = Targets.init; break;
            case Expression.Kind.ternary:
                auto ternary = cast(TernaryExpression) node;
                evaluateChild(ternary.condition);
                if (result.normal is null) break;
                bool condition; auto known = literalCondition(ternary.condition, condition);
                auto a = expression(ternary.whenTrue, environment, result.normal.copy(), known && !condition ? Mode.dead : mode);
                auto b = expression(ternary.whenFalse, environment, result.normal.copy(), known && condition ? Mode.dead : mode);
                result.normal = known ? (condition ? a.normal : b.normal) : join(a.normal, b.normal);
                result.thrown = join(result.thrown, known ? (condition ? a.thrown : b.thrown) : join(a.thrown, b.thrown));
                result.value = known ? (condition ? a.value : b.value) : unite(a.value, b.value); break;
            case Expression.Kind.unary: evaluateChild((cast(UnaryExpression) node).operand); result.value = Targets.init; break;
            case Expression.Kind.cast_: evaluateChild((cast(CastExpression) node).operand); break;
            case Expression.Kind.array:
                foreach (child; (cast(ArrayExpression) node).elements) evaluateChild(child);
                result.value = Targets.init; break;
            case Expression.Kind.associativeArray:
                auto array = cast(AssociativeArrayExpression) node;
                foreach (index, key; array.keys) { evaluateChild(key); evaluateChild(array.values[index]); }
                result.value = Targets.init; break;
            case Expression.Kind.table:
                foreach (entry; (cast(TableExpression) node).entries) { evaluateChild(entry.keyExpression); evaluateChild(entry.value); }
                result.value = Targets.init; break;
            case Expression.Kind.get: evaluateChild((cast(GetExpression) node).target); result.value = Targets.init; break;
            case Expression.Kind.index:
                auto index = cast(IndexExpression) node; evaluateChild(index.target);
                foreach (child; index.indices) evaluateChild(child);
                evaluateChild(index.sliceStart); evaluateChild(index.sliceEnd); result.value = Targets.init; break;
        }
        record(after, node, result.normal, mode);
        return result;
    }
    private Flow statements(Statement[] body, Scope environment, State state, Mode mode)
    {
        Flow result; auto current = state; auto stopped = state;
        foreach (node; body)
        {
            if (current is null)
            {
                // 到達不能部分の通常の型診断は残し、副作用を外へ出しません。
                statement(node, environment, stopped.copy(), Mode.dead);
                continue;
            }
            stopped = current.copy();
            auto next = statement(node, environment, current, mode);
            result.returned = join(result.returned, next.returned); result.broke = join(result.broke, next.broke);
            result.continued = join(result.continued, next.continued); result.thrown = join(result.thrown, next.thrown);
            current = next.normal;
        }
        result.normal = current; return result;
    }
    private Flow statement(Statement node, Scope environment, State state, Mode mode)
    {
        record(before, node, state, mode);
        Flow result; result.normal = state;
        void evaluate(Expression expr)
        {
            auto value = expression(expr, environment, result.normal, mode);
            result.normal = value.normal; result.thrown = join(result.thrown, value.thrown);
        }
        final switch (node.kind)
        {
            case Statement.Kind.variableDecl:
                Targets[] values;
                foreach (expr; node.expressions)
                {
                    auto value = expression(expr, environment, result.normal, mode);
                    result.normal = value.normal; result.thrown = join(result.thrown, value.thrown); values ~= value.value;
                }
                if (result.normal !is null) foreach (index, name; node.names)
                    result.normal.bindings[environment.declare(name)] = index < values.length ? values[index] : Targets.init;
                break;
            case Statement.Kind.assign:
                Targets[] values;
                foreach (expr; node.expressions)
                {
                    auto value = expression(expr, environment, result.normal, mode);
                    result.normal = value.normal; result.thrown = join(result.thrown, value.thrown); values ~= value.value;
                }
                foreach (index, target; node.targets)
                {
                    if (result.normal is null) break;
                    if (target.kind == Expression.Kind.variable)
                    {
                        auto name = (cast(VariableExpression) target).name;
                        auto symbol = environment.find(name); if (symbol is null) symbol = environment.declare(name);
                        result.normal.bindings[symbol] = index < values.length ? values[index] : Targets.init;
                    }
                    else evaluate(target);
                }
                break;
            case Statement.Kind.expression: evaluate(node.expression); break;
            case Statement.Kind.return_:
                foreach (expr; node.expressions) evaluate(expr);
                result.returned = result.normal; result.normal = null; break;
            case Statement.Kind.break_: result.broke = state; result.normal = null; break;
            case Statement.Kind.continue_: result.continued = state; result.normal = null; break;
            case Statement.Kind.functionDecl:
                auto fn = functionFor(node, environment);
                state.bindings[environment.declare(node.name)] = Targets([fn], false); fn.defaultState = state.copy(); break;
            case Statement.Kind.block:
                result = statements(node.body, scopeFor(node, environment, node.body), state, mode); break;
            case Statement.Kind.if_:
                evaluate(node.condition);
                if (result.normal is null) break;
                bool condition; auto known = literalCondition(node.condition, condition);
                auto input = result.normal;
                auto a = statements(node.body, environment, input.copy(), known && !condition ? Mode.dead : mode);
                auto b = node.elseBranch is null ? Flow(input.copy())
                    : statement(node.elseBranch, environment, input.copy(), known && condition ? Mode.dead : mode);
                auto priorThrow = result.thrown;
                if (known) result = condition ? a : b;
                else { result = a; result.absorb(b); }
                result.thrown = join(result.thrown, priorThrow); break;
            case Statement.Kind.for_, Statement.Kind.while_, Statement.Kind.foreach_:
                result = loop(node, environment, state, mode); break;
            case Statement.Kind.switch_:
                evaluate(node.expression);
                if (result.normal is null) break;
                auto input = result.normal; auto priorThrow = result.thrown;
                auto known = node.expression.kind == Expression.Kind.literal;
                foreach (arm; node.switchCases)
                    if (!arm.isDefault && arm.pattern.kind != Expression.Kind.literal) known = false;
                bool selected, hasDefault;
                result = Flow.init;
                foreach (arm; node.switchCases)
                {
                    hasDefault |= arm.isDefault;
                    auto reachable = !known || (!selected && (arm.isDefault || valuesEqual(
                        (cast(LiteralExpression) node.expression).value, (cast(LiteralExpression) arm.pattern).value)));
                    auto branch = statements(arm.body, scopeFor(arm, environment, arm.body), input.copy(), reachable ? mode : Mode.dead);
                    if (reachable)
                    {
                        branch.normal = join(branch.normal, branch.broke); branch.broke = null;
                        result.absorb(branch); selected = true;
                    }
                }
                if ((known && !selected) || (!known && !hasDefault)) result.normal = join(result.normal, input);
                result.thrown = join(result.thrown, priorThrow); break;
            case Statement.Kind.try_:
                auto tried = statements(node.body, scopeFor(node, environment, node.body), state, mode);
                // 型検証なども例外になり得るため、実行済みの接頭部分をcatchへ合流します。
                auto caughtInput = join(state, tried.thrown);
                auto caught = statements(node.elseBranch.body,
                    scopeFor(node.elseBranch, environment, node.elseBranch.body, [node.name]), caughtInput, mode);
                result = tried; result.thrown = null; result.absorb(caught); break;
            case Statement.Kind.tableDecl, Statement.Kind.structDecl:
                result.thrown = state.copy(); state.nullable.remove(node.name);
                if (node.kind == Statement.Kind.structDecl) state.bindings[environment.declare(node.name)] = Targets.init;
                break;
            case Statement.Kind.alias_:
                bool nullable;
                foreach (alternative; node.names)
                    nullable |= alternative == "null" || alternative == "void" || alternative == "any"
                        || alternative == "auto" || (alternative in state.nullable) !is null;
                result.thrown = state.copy(); if (!nullable) state.nullable.remove(node.name); break;
            case Statement.Kind.import_: state.bindings[environment.declare(node.aliasName)] = Targets.init; result.thrown = state.copy(); break;
            case Statement.Kind.export_: break;
            case Statement.Kind.yield_: foreach (expr; node.expressions) evaluate(expr); break;
        }
        record(after, node, result.normal, mode);
        return result;
    }
    private Flow loop(Statement node, Scope parent, State state, Mode mode)
    {
        auto environment = scopeFor(node, parent, node.init is null ? null : [node.init],
            node.kind == Statement.Kind.foreach_ ? [node.iteratorName, node.iteratorSecondName] : null);
        Flow result;
        if (node.init !is null) { auto initialized = statement(node.init, environment, state, mode); result.absorb(initialized); state = initialized.normal; }
        if (state is null) return result;
        result.normal = null;
        if (node.kind == Statement.Kind.foreach_)
        {
            auto collection = expression(node.iterable, environment, state, mode); state = collection.normal;
            result.thrown = join(result.thrown, collection.thrown);
            if (node.rangeEnd !is null) { auto end = expression(node.rangeEnd, environment, state, mode); state = end.normal; result.thrown = join(result.thrown, end.thrown); }
        }
        if (state is null) return result;
        auto count = iterationCount(node);
        if (count == 0)
        {
            statements(node.body, environment, state.copy(), Mode.dead); result.normal = state; return result;
        }
        auto head = state.copy();
        foreach (iteration; 0 .. 128)
        {
            auto entry = head.copy();
            auto condition = expression(node.condition, environment, entry, mode); entry = condition.normal;
            result.thrown = join(result.thrown, condition.thrown);
            if (entry is null) break;
            bool literal; auto knownTrue = node.condition is null || (literalCondition(node.condition, literal) && literal);
            if (count < 0 && (node.kind == Statement.Kind.foreach_ || !knownTrue))
                result.normal = join(result.normal, entry);
            auto body = statements(node.body, environment, entry, mode);
            result.normal = join(result.normal, body.broke); result.returned = join(result.returned, body.returned);
            result.thrown = join(result.thrown, body.thrown);
            auto next = join(body.normal, body.continued);
            if (next is null) break;
            if (node.incrementStatement !is null)
            {
                auto increment = statement(node.incrementStatement, environment, next, mode);
                next = increment.normal; result.thrown = join(result.thrown, increment.thrown);
            }
            if (next is null) break;
            if (count >= 0 && iteration + 1 >= count) { result.normal = join(result.normal, next); break; }
            if (count >= 0)
            {
                if (same(head, next)) { result.normal = join(result.normal, next); break; }
                head = next; continue;
            }
            auto merged = join(head, next);
            if (same(head, merged)) break;
            head = merged;
        }
        return result;
    }
    private static bool same(State a, State b)
    {
        if (a.nullable != b.nullable || a.bindings.length != b.bindings.length) return false;
        foreach (symbol, targets; a.bindings)
        {
            auto other = symbol in b.bindings;
            if (other is null || other.unknown != targets.unknown || other.known.length != targets.known.length) return false;
            foreach (fn; targets.known) if (!other.known.canFind(fn)) return false;
        }
        return true;
    }
    private static long iterationCount(Statement node)
    {
        bool condition;
        if (literalCondition(node.condition, condition) && !condition) return 0;
        if (node.kind == Statement.Kind.foreach_)
        {
            if (node.rangeEnd is null && node.iterable.kind == Expression.Kind.array)
            {
                auto array = cast(ArrayExpression) node.iterable;
                if (!array.elementSpreads.canFind(true)) return cast(long) array.elements.length;
            }
            if (node.rangeEnd !is null && node.iterable.kind == Expression.Kind.literal && node.rangeEnd.kind == Expression.Kind.literal)
            {
                auto start = (cast(LiteralExpression) node.iterable).value, end = (cast(LiteralExpression) node.rangeEnd).value;
                if (start.kind == ValueKind.integer && end.kind == ValueKind.integer)
                    return start.integerValue >= end.integerValue ? 0 : (end.integerValue - start.integerValue == 1 ? 1 : -1);
            }
        }
        if (node.kind == Statement.Kind.for_ && node.init !is null && node.init.names.length == 1
            && node.init.expressions.length == 1 && node.init.expressions[0].kind == Expression.Kind.literal
            && node.condition !is null && node.condition.kind == Expression.Kind.binary)
        {
            auto binary = cast(BinaryExpression) node.condition;
            if (binary.left.kind != Expression.Kind.variable || binary.right.kind != Expression.Kind.literal
                || (cast(VariableExpression) binary.left).name != node.init.names[0]) return -1;
            auto start = (cast(LiteralExpression) node.init.expressions[0]).value, end = (cast(LiteralExpression) binary.right).value;
            if (start.kind != ValueKind.integer || end.kind != ValueKind.integer) return -1;
            auto a = start.integerValue, b = end.integerValue;
            switch (binary.operatorSymbol)
            {
                case "<": if (a >= b) return 0; break;
                case "<=": if (a > b) return 0; break;
                case ">": if (a <= b) return 0; break;
                case ">=": if (a < b) return 0; break;
                case "==": if (a != b) return 0; break;
                case "!=": if (a == b) return 0; break;
                default: break;
            }
            if (node.incrementStatement !is null && node.incrementStatement.assignmentOperator == "+"
                && node.incrementStatement.expressions.length == 1
                && node.incrementStatement.expressions[0].kind == Expression.Kind.literal)
            {
                auto step = (cast(LiteralExpression) node.incrementStatement.expressions[0]).value;
                if (step.kind == ValueKind.integer && step.integerValue == 1 && binary.operatorSymbol == "<" && b - a == 1) return 1;
            }
        }
        return -1;
    }
}
