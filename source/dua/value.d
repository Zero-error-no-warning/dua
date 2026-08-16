module dua.value;

import std.algorithm : map;
import std.array : array;
import std.conv : convTo = to;
import std.exception : enforce;
import std.format : format;
import std.string : join;
import std.meta : AliasSeq, staticIndexOf, staticMap;
import std.traits : BaseClassesTuple, FieldNameTuple, ForeachType, KeyType, OriginalType, Parameters, ReturnType, Unqual, Variadic, isAggregateType, isAssociativeArray, isCallable, isDelegate, isDynamicArray, isFloatingPoint, isIntegral, isInstanceOf, isSomeString, isStaticArray, variadicFunctionStyle;
import std.typecons : Tuple;

abstract class CallableValue
{
    string debugName;

    this(string debugName)
    {
        this.debugName = debugName;
    }

    abstract Value invoke(Value[] args);

    size_t expectedArity() const
    {
        return size_t.max;
    }

    size_t minimumArity() const
    {
        auto arity = expectedArity();
        return arity == size_t.max ? 0 : arity;
    }
}

final class ReflectedCallable : CallableValue
{
    private Value delegate(Value[] args) invoker;
    private int delegate(scope const(Value)[] args) argumentMatcher;
    private size_t arity;
    private bool variadic;
    // Keeps a heap-backed struct receiver alive for the lifetime of its bound
    // delegate. Class receivers do not need a separate owner.
    private Object lifetimeOwner;

    this(string debugName, size_t arity, Value delegate(Value[] args) invoker,
        Object lifetimeOwner = null,
        int delegate(scope const(Value)[] args) argumentMatcher = null,
        bool variadic = false)
    {
        super(debugName);
        this.arity = arity;
        this.invoker = invoker;
        this.lifetimeOwner = lifetimeOwner;
        this.argumentMatcher = argumentMatcher;
        this.variadic = variadic;
    }

    override Value invoke(Value[] args)
    {
        return invoker(args);
    }

    override size_t expectedArity() const
    {
        return variadic ? size_t.max : arity;
    }

    override size_t minimumArity() const
    {
        return arity;
    }

    int matchArguments(scope const(Value)[] args) const
    {
        if (variadic ? args.length < arity : args.length != arity)
            return -1;
        return argumentMatcher is null ? 0 : argumentMatcher(args);
    }

}

final class OverloadedReflectedCallable : CallableValue
{
    private ReflectedCallable[] overloads;

    this(string debugName, ReflectedCallable[] overloads)
    {
        super(debugName);
        this.overloads = overloads;
    }

    override Value invoke(Value[] args)
    {
        ReflectedCallable match;
        int bestScore = -1;
        bool ambiguous;
        foreach (overload; overloads)
        {
            auto score = overload.matchArguments(args);
            if (score > bestScore)
            {
                match = overload;
                bestScore = score;
                ambiguous = false;
            }
            else if (score >= 0 && score == bestScore)
            {
                ambiguous = true;
            }
        }
        enforce(match !is null,
            format("Function '%s' has no overload matching %s arguments", debugName, args.length));
        enforce(!ambiguous,
            format("Function '%s' has multiple matching overloads for %s arguments", debugName, args.length));
        return match.invoke(args);
    }
}

private final class ReflectedStructStorage(T)
{
    T value;

    this(T source)
    {
        value = source;
    }
}

enum ValueKind
{
    null_,
    integer,
    floating,
    boolean,
    string_,
    array,
    table,
    function_,
    native
}

enum string internalFieldGetterPrefix = "__dua_get_";
enum string internalFieldSetterPrefix = "__dua_set_";

/// Reference storage makes table identity explicit. Copies of Value (including
/// module exports already handed to an importer) therefore observe additions.
private final class TableStorage
{
    Value[string] entries;
}

struct Value
{
    ValueKind kind = ValueKind.null_;
    long integerValue;
    double floatingValue;
    bool booleanValue;
    string stringValue;
    Value[] arrayValue;
    private TableStorage tableStorage;
    CallableValue functionValue;
    string nativeTypeName;
    string nativeDisplay;

    ref Value[string] tableValue()
    {
        if (tableStorage is null)
            tableStorage = new TableStorage();
        return tableStorage.entries;
    }

    const(Value[string]) tableValue() const
    {
        return tableStorage is null ? null : tableStorage.entries;
    }

    static Value nullValue()
    {
        return Value();
    }

    static Value from(long value)
    {
        Value result;
        result.kind = ValueKind.integer;
        result.integerValue = value;
        return result;
    }

    static Value from(int value)
    {
        return from(cast(long) value);
    }

    static Value from(double value)
    {
        Value result;
        result.kind = ValueKind.floating;
        result.floatingValue = value;
        return result;
    }

    static Value from(bool value)
    {
        Value result;
        result.kind = ValueKind.boolean;
        result.booleanValue = value;
        return result;
    }

    static Value from(string value)
    {
        Value result;
        result.kind = ValueKind.string_;
        result.stringValue = value;
        return result;
    }

    static Value from(Value[] values)
    {
        Value result;
        result.kind = ValueKind.array;
        result.arrayValue = values.dup;
        return result;
    }

    static Value from(Value[string] entries)
    {
        Value result;
        result.kind = ValueKind.table;
        result.tableStorage = new TableStorage();
        result.tableStorage.entries = entries.dup;
        return result;
    }

    static Value fromFunction(CallableValue callable)
    {
        Value result;
        result.kind = ValueKind.function_;
        result.functionValue = callable;
        return result;
    }

    /// Converts any value supported by the D/Dua reflection boundary.
    static Value fromAuto(T)(auto ref T value)
    {
        return convertToValue(value);
    }

    /// Calls a named function stored in this table value.
    /// This lets module export values use the same call(name, args) shape as ScriptEngine.
    Value call(string functionName, scope const(Value)[] args = [])
    {
        enforce(kind == ValueKind.table,
            format("Cannot call member '%s' on %s value", functionName, kind));
        auto member = functionName in tableValue;
        enforce(member !is null, format("Undefined module export '%s'", functionName));
        enforce(member.kind == ValueKind.function_,
            format("Module export '%s' is not callable", functionName));

        Value[] copiedArgs;
        foreach (arg; args)
        {
            copiedArgs ~= cast(Value) arg;
        }
        return member.functionValue.invoke(copiedArgs);
    }

    /// Looks up a named entry in a table value (for example, a module export).
    Value opIndex(string name)
    {
        enforce(kind == ValueKind.table, format("Cannot index %s value by name", kind));
        auto member = name in tableValue;
        enforce(member !is null, format("Undefined table member '%s'", name));
        return *member;
    }

    static Value native(T)(T value)
    {
        Value result;
        result.kind = ValueKind.native;
        result.nativeTypeName = T.stringof;
        result.nativeDisplay = convTo!string(value);
        return result;
    }

    static Value from(T)(T values)
        if ((isDynamicArray!T || isStaticArray!T) && !isSomeString!T)
    {
        Value[] converted;
        foreach (ref value; values)
        {
            converted ~= convertToValue(value);
        }
        return Value.from(converted);
    }

    static Value from(T)(T entries)
        if (isAssociativeArray!T && isSomeString!(KeyType!T))
    {
        Value[string] converted;
        foreach (key, value; entries)
        {
            converted[key] = convertToValue(value);
        }
        return Value.from(converted);
    }

    static Value reflect(T)(auto ref T value)
        if (isAggregateType!T)
    {
        Value[string] converted;
        // A member delegate contains a pointer to its struct receiver.  Keep a
        // reflected struct copy on the GC heap so delegates remain valid when
        // reflection was triggered by a temporary return value.
        static if (is(T == struct))
        {
            auto reflectedTarget = new ReflectedStructStorage!T(value);
        }
        else
        {
            auto reflectedTarget = value;
        }
        static foreach (memberName; __traits(allMembers, T))
        {{
            static if (memberName != "this" && memberName != "__ctor" && memberName != "Monitor" && memberName != "factory")
            {
                static if (__traits(compiles, __traits(getOverloads, T, memberName)))
                {
                    ReflectedCallable[] overloads;
                    static foreach (overload; __traits(getOverloads, T, memberName))
                    {
                        static if (__traits(compiles, makeBoundReflectedCallable!overload(
                            T.stringof ~ "." ~ memberName, value)))
                        {
                            static if (is(T == struct))
                            {
                                overloads ~= makeBoundReflectedCallable!overload(
                                    T.stringof ~ "." ~ memberName, reflectedTarget.value,
                                    reflectedTarget);
                            }
                            else
                            {
                                overloads ~= makeBoundReflectedCallable!overload(
                                    T.stringof ~ "." ~ memberName, reflectedTarget);
                            }
                        }
                    }
                    if (overloads.length == 1)
                    {
                        converted[memberName] = Value.fromFunction(overloads[0]);
                    }
                    else if (overloads.length > 1)
                    {
                        converted[memberName] = Value.fromFunction(
                            new OverloadedReflectedCallable(T.stringof ~ "." ~ memberName, overloads));
                    }
                    static if (is(T == class) || is(T == struct))
                    {
                        foreach (overload; overloads)
                        {
                            if (overload.expectedArity() == 0)
                            {
                                converted[internalFieldGetterPrefix ~ memberName] = Value.fromFunction(overload);
                            }
                            else if (overload.expectedArity() == 1)
                            {
                                converted[internalFieldSetterPrefix ~ memberName] = Value.fromFunction(overload);
                            }
                        }
                    }
                }
            }
        }}
        static foreach (operatorSymbol; ["+", "-", "*", "/", "%", "~", "&", "|", "^", "<<", ">>"])
        {{
            static if (staticIndexOf!("opBinary", __traits(allMembers, T)) >= 0
                && __traits(compiles, makeBoundBinaryOperator!(T, "opBinary", operatorSymbol)(
                T.stringof ~ ".opBinary" ~ operatorSymbol, value)))
            {
                converted["opBinary" ~ operatorSymbol] = Value.fromFunction(
                    makeBoundBinaryOperator!(T, "opBinary", operatorSymbol)(
                        T.stringof ~ ".opBinary" ~ operatorSymbol, value));
            }
            static if (staticIndexOf!("opBinaryRight", __traits(allMembers, T)) >= 0
                && __traits(compiles, makeBoundBinaryOperator!(T, "opBinaryRight", operatorSymbol)(
                T.stringof ~ ".opBinaryRight" ~ operatorSymbol, value)))
            {
                converted["opBinaryRight" ~ operatorSymbol] = Value.fromFunction(
                    makeBoundBinaryOperator!(T, "opBinaryRight", operatorSymbol)(
                        T.stringof ~ ".opBinaryRight" ~ operatorSymbol, value));
            }
        }}
        static foreach (operatorSymbol; ["-", "!"])
        {{
            static if (__traits(compiles, makeBoundUnaryOperator!(T, operatorSymbol)(
                T.stringof ~ ".opUnary" ~ operatorSymbol, value)))
            {
                converted["opUnary" ~ operatorSymbol] = Value.fromFunction(
                    makeBoundUnaryOperator!(T, operatorSymbol)(
                        T.stringof ~ ".opUnary" ~ operatorSymbol, value));
            }
        }}
        static if (is(T == struct) && staticIndexOf!("opEquals", __traits(allMembers, T)) >= 0
            && __traits(compiles, makeBoundEqualityOperator(
            T.stringof ~ ".opEquals", value)))
        {
            converted["__eq"] = Value.fromFunction(
                makeBoundEqualityOperator(T.stringof ~ ".opEquals", value));
        }
        static foreach (memberName; FieldNameTuple!T)
        {{
            static if (__traits(compiles, convertToValue(mixin("value." ~ memberName))))
            {
                converted[memberName] = convertToValue(mixin("value." ~ memberName));
                static if (is(T == class))
                {
                    converted[internalFieldGetterPrefix ~ memberName] = Value.fromFunction(
                        new ReflectedCallable(T.stringof ~ "." ~ memberName ~ ".getter", 0, (Value[] args) {
                        return convertToValue(mixin("value." ~ memberName));
                    }));
                    static if (__traits(compiles, mixin("value." ~ memberName) = mixin("value." ~ memberName)))
                    {
                        converted[internalFieldSetterPrefix ~ memberName] = Value.fromFunction(
                            new ReflectedCallable(T.stringof ~ "." ~ memberName ~ ".setter", 1, (Value[] args) {
                            alias FieldType = typeof(mixin("value." ~ memberName));
                            mixin("value." ~ memberName) = convertFromValue!FieldType(args[0]);
                            return Value.nullValue();
                        }));
                    }
                }
            }
        }}
        static if (is(T == class))
        {
            Value[] typeChain;
            typeChain ~= Value.from(T.stringof);
            static foreach (Base; BaseClassesTuple!T)
            {
                typeChain ~= Value.from(Base.stringof);
            }
            converted["__typechain"] = Value.from(typeChain);
        }
        // Reflect alias-this targets last: the helper only fills missing slots,
        // so declarations on the outer aggregate always win.  It retains the
        // outer receiver and evaluates every alias-this hop when called.
        static if (__traits(getAliasThis, T).length && !isInstanceOf!(Tuple, T))
        {
            static if (is(T == struct))
                addAliasThisReflection!(T, T, "root", AliasSeq!T)(converted,
                    reflectedTarget.value, reflectedTarget);
            else
                addAliasThisReflection!(T, T, "root", AliasSeq!T)(converted,
                    reflectedTarget);
        }
        return Value.from(converted);
    }

    bool isNumber() const
    {
        return kind == ValueKind.integer || kind == ValueKind.floating;
    }

    double toFloat() const
    {
        switch (kind)
        {
            case ValueKind.integer:
                return integerValue;
            case ValueKind.floating:
                return floatingValue;
            default:
                enforce(false, format("Expected number but got %s", kind));
                assert(0);
        }
    }

    long toInt() const
    {
        switch (kind)
        {
            case ValueKind.integer:
                return integerValue;
            case ValueKind.floating:
                return cast(long) floatingValue;
            default:
                enforce(false, format("Expected integer but got %s", kind));
                assert(0);
        }
    }

    T to(T)() const
    {
        return convertFromValue!T(this);
    }

    string toHostString() const
    {
        final switch (kind)
        {
            case ValueKind.null_:
                return "null";
            case ValueKind.integer:
                return convTo!string(integerValue);
            case ValueKind.floating:
                return convTo!string(floatingValue);
            case ValueKind.boolean:
                return booleanValue ? "true" : "false";
            case ValueKind.string_:
                return stringValue;
            case ValueKind.array:
                return "[" ~ arrayValue.map!(item => item.toHostString()).array.join(", ") ~ "]";
            case ValueKind.table:
                string[] parts;
                foreach (key, value; tableValue)
                {
                    parts ~= key ~ ": " ~ value.toHostString();
                }
                return "{" ~ parts.join(", ") ~ "}";
            case ValueKind.function_:
                return "<function " ~ functionValue.debugName ~ ">";
            case ValueKind.native:
                return nativeTypeName ~ "(" ~ nativeDisplay ~ ")";
        }
    }

    string toScriptLiteral() const
    {
        final switch (kind)
        {
            case ValueKind.null_:
                return "null";
            case ValueKind.integer:
                return convTo!string(integerValue);
            case ValueKind.floating:
                return convTo!string(floatingValue);
            case ValueKind.boolean:
                return booleanValue ? "true" : "false";
            case ValueKind.string_:
                return '"' ~ stringValue ~ '"';
            case ValueKind.array:
                return "[" ~ arrayValue.map!(item => item.toScriptLiteral()).array.join(", ") ~ "]";
            case ValueKind.table:
                string[] parts;
                foreach (key, value; tableValue)
                {
                    parts ~= key ~ " = " ~ value.toScriptLiteral();
                }
                return "{" ~ parts.join(", ") ~ "}";
            case ValueKind.function_:
                return "<function " ~ functionValue.debugName ~ ">";
            case ValueKind.native:
                return "<" ~ nativeTypeName ~ ":" ~ nativeDisplay ~ ">";
        }
    }

    bool truthy() const
    {
        final switch (kind)
        {
            case ValueKind.null_:
                return false;
            case ValueKind.integer:
                return integerValue != 0;
            case ValueKind.floating:
                return floatingValue != 0;
            case ValueKind.boolean:
                return booleanValue;
            case ValueKind.string_:
                return stringValue.length > 0;
            case ValueKind.array:
                return arrayValue.length > 0;
            case ValueKind.table:
                return tableValue.length > 0;
            case ValueKind.function_:
                return true;
            case ValueKind.native:
                return true;
        }
    }
}

private void addAliasThisReflection(Root, Current, string expression, Seen...)(
    ref Value[string] converted, auto ref Root root, Object lifetimeOwner = null)
{
    static if (__traits(getAliasThis, Current).length)
    {
        enum aliasName = __traits(getAliasThis, Current)[0];
        enum rawExpression = expression ~ "." ~ aliasName;
        alias AliasMember = typeof(mixin(rawExpression));
        static if (isCallable!AliasMember)
        {
            enum nextExpression = rawExpression ~ "()";
            alias Next = Unqual!(ReturnType!AliasMember);
        }
        else
        {
            enum nextExpression = rawExpression;
            alias Next = Unqual!AliasMember;
        }
        // D rejects direct alias-this cycles, but this guard also handles
        // mutually recursive types and keeps reflection compilation bounded.
        static if (isAggregateType!Next && staticIndexOf!(Next, Seen) < 0)
        {
            static foreach (memberName; __traits(allMembers, Next))
            {{
                static if (memberName != "this" && memberName != "__ctor"
                    && memberName != "Monitor" && memberName != "factory")
                {
                    static if (__traits(compiles, __traits(getOverloads, Next, memberName)))
                    {
                        ReflectedCallable[] overloads;
                        static foreach (overload; __traits(getOverloads, Next, memberName))
                        {
                            static if (__traits(compiles, makeLazyAliasCallable!(overload,
                                Root, nextExpression)(Root.stringof ~ "." ~ memberName,
                                    root, lifetimeOwner)))
                                overloads ~= makeLazyAliasCallable!(overload, Root,
                                    nextExpression)(Root.stringof ~ "." ~ memberName,
                                        root, lifetimeOwner);
                        }
                        if (memberName !in converted && overloads.length == 1)
                            converted[memberName] = Value.fromFunction(overloads[0]);
                        else if (memberName !in converted && overloads.length > 1)
                            converted[memberName] = Value.fromFunction(
                                new OverloadedReflectedCallable(Root.stringof ~ "." ~ memberName,
                                    overloads));
                    }
                }
            }}
            static foreach (operatorSymbol; ["+", "-", "*", "/", "%", "~", "&", "|", "^", "<<", ">>"])
            {{
                static foreach (methodName; ["opBinary", "opBinaryRight"])
                {{
                    auto slot = methodName ~ operatorSymbol;
                    if (slot !in converted)
                    {
                        static if (__traits(compiles, mixin("&" ~ nextExpression ~ "."
                            ~ methodName ~ "!(\"" ~ operatorSymbol ~ "\")"))
                            || __traits(compiles, mixin(nextExpression ~ "." ~ methodName
                                ~ "!(\"" ~ operatorSymbol ~ "\", long)(long.init)")))
                            converted[slot] = Value.fromFunction(makeLazyAliasBinary!(Root, Next,
                                nextExpression, methodName, operatorSymbol)(slot, root, lifetimeOwner));
                    }
                }}
            }}
            if ("__eq" !in converted)
            {
                static if (__traits(compiles, makeLazyAliasEquality!(Root, Next,
                    nextExpression)(Root.stringof ~ ".opEquals", root, lifetimeOwner)))
                    converted["__eq"] = Value.fromFunction(makeLazyAliasEquality!(Root, Next,
                        nextExpression)(Root.stringof ~ ".opEquals", root, lifetimeOwner));
            }
            addAliasThisReflection!(Root, Next, nextExpression, Seen, Next)(converted,
                root, lifetimeOwner);
        }
    }
}

package(dua) ReflectedCallable makeReflectedCallable(C)(string debugName, auto ref C callable,
    Object lifetimeOwner = null)
    if (isCallable!C)
{
    alias Params = Parameters!C;
    alias MutableParams = staticMap!(Unqual, Params);
    enum isTypesafeVariadic = variadicFunctionStyle!C == Variadic.typesafe;
    enum fixedArity = isTypesafeVariadic ? Params.length - 1 : Params.length;
    auto storedCallable = callable;
    return new ReflectedCallable(debugName, fixedArity, (Value[] args) {
        static if (isTypesafeVariadic)
            enforce(args.length >= fixedArity,
                format("Function '%s' expected at least %s arguments but got %s",
                    debugName, fixedArity, args.length));
        else
            enforce(args.length == Params.length,
                format("Function '%s' expected %s arguments but got %s", debugName, Params.length, args.length));

        auto converted = Tuple!MutableParams();
        static foreach (index; 0 .. fixedArity)
        {
            converted[index] = convertFromValue!(MutableParams[index])(args[index]);
        }
        static if (isTypesafeVariadic)
        {
            alias VariadicArray = MutableParams[$ - 1];
            alias Element = ForeachType!VariadicArray;
            foreach (arg; args[fixedArity .. $])
                converted[$ - 1] ~= convertFromValue!Element(arg);
        }

        static if (is(ReturnType!C == void))
        {
            storedCallable(converted.expand);
            return Value.nullValue();
        }
        else
        {
            return convertToValue(storedCallable(converted.expand));
        }
    }, lifetimeOwner, (scope const(Value)[] args) {
        static if (isTypesafeVariadic)
        {
            if (args.length < fixedArity)
                return -1;
        }
        else if (args.length != Params.length)
        {
            return -1;
        }
        int score;
        static foreach (index; 0 .. fixedArity)
        {{
            auto parameterScore = conversionScore!(MutableParams[index])(args[index]);
            if (parameterScore < 0)
                return -1;
            score += parameterScore;
        }}
        static if (isTypesafeVariadic)
        {
            alias Element = ForeachType!(MutableParams[$ - 1]);
            foreach (arg; args[fixedArity .. $])
            {
                auto parameterScore = conversionScore!Element(arg);
                if (parameterScore < 0)
                    return -1;
                score += parameterScore;
            }
            // Prefer a fixed-arity overload when both otherwise match.
            score -= 1;
        }
        return score;
    }, isTypesafeVariadic);
}

private ReflectedCallable makeBoundReflectedCallable(alias overload, T)(string debugName,
    auto ref T value, Object lifetimeOwner = null)
{
    alias Function = typeof(overload);
    alias Delegate = ReturnType!Function delegate(Parameters!Function);
    Delegate callable = &__traits(getMember, value, __traits(identifier, overload));
    return makeReflectedCallable(debugName, callable, lifetimeOwner);
}

private ReflectedCallable makeLazyAliasCallable(alias overload, Root, string expression)(
    string debugName, auto ref Root root, Object lifetimeOwner = null)
{
    alias Function = typeof(overload);
    alias Params = Parameters!Function;
    alias MutableParams = staticMap!(Unqual, Params);
    return new ReflectedCallable(debugName, Params.length, (Value[] args) {
        auto converted = Tuple!MutableParams();
        static foreach (index, Param; Params)
            converted[index] = convertFromValue!(Unqual!Param)(args[index]);
        static if (is(ReturnType!Function == void))
        {
            __traits(getMember, mixin(expression), __traits(identifier, overload))(converted.expand);
            return Value.nullValue();
        }
        else
            return convertToValue(__traits(getMember, mixin(expression),
                __traits(identifier, overload))(converted.expand));
    }, lifetimeOwner);
}

private ReflectedCallable makeLazyAliasBinary(Root, Target, string expression,
    string methodName, string operatorSymbol)(string debugName, auto ref Root root,
        Object lifetimeOwner = null)
{
    // Prefer the traditional partially-instantiated operator.  This preserves
    // concrete RHS overloads and their exact conversion behavior.
    static if (__traits(compiles, mixin("&" ~ expression ~ "." ~ methodName
        ~ "!(\"" ~ operatorSymbol ~ "\")")))
    {
        alias Callable = typeof(mixin("&" ~ expression ~ "." ~ methodName
            ~ "!(\"" ~ operatorSymbol ~ "\")"));
        alias Params = Parameters!Callable;
        alias Rhs = Unqual!(Params[0]);
        return new ReflectedCallable(debugName, 2, (Value[] args) {
            auto rhs = convertFromValue!Rhs(args[1]);
            return convertToValue(mixin(expression ~ "." ~ methodName
                ~ "!(\"" ~ operatorSymbol ~ "\")(rhs)"));
        }, lifetimeOwner);
    }
    else static if (__traits(compiles, mixin(expression ~ "." ~ methodName
        ~ "!(\"" ~ operatorSymbol ~ "\", long)(long.init)")))
    {
        return new ReflectedCallable(debugName, 2, (Value[] args) {
            switch (args[1].kind)
            {
                case ValueKind.integer:
                    auto rhs = convertFromValue!long(args[1]);
                    return convertToValue(mixin(expression ~ "." ~ methodName
                        ~ "!(\"" ~ operatorSymbol ~ "\", long)(rhs)"));
                case ValueKind.floating:
                    static if (__traits(compiles, mixin(expression ~ "." ~ methodName
                        ~ "!(\"" ~ operatorSymbol ~ "\", double)(double.init)")))
                    {
                        auto rhs = convertFromValue!double(args[1]);
                        return convertToValue(mixin(expression ~ "." ~ methodName
                            ~ "!(\"" ~ operatorSymbol ~ "\", double)(rhs)"));
                    }
                    else { enforce(false, "Operator does not accept a floating RHS"); assert(0); }
                case ValueKind.boolean:
                    static if (__traits(compiles, mixin(expression ~ "." ~ methodName
                        ~ "!(\"" ~ operatorSymbol ~ "\", bool)(bool.init)")))
                    {
                        auto rhs = convertFromValue!bool(args[1]);
                        return convertToValue(mixin(expression ~ "." ~ methodName
                            ~ "!(\"" ~ operatorSymbol ~ "\", bool)(rhs)"));
                    }
                    else { enforce(false, "Operator does not accept a boolean RHS"); assert(0); }
                case ValueKind.string_:
                    static if (__traits(compiles, mixin(expression ~ "." ~ methodName
                        ~ "!(\"" ~ operatorSymbol ~ "\", string)(string.init)")))
                    {
                        auto rhs = convertFromValue!string(args[1]);
                        return convertToValue(mixin(expression ~ "." ~ methodName
                            ~ "!(\"" ~ operatorSymbol ~ "\", string)(rhs)"));
                    }
                    else { enforce(false, "Operator does not accept a string RHS"); assert(0); }
                case ValueKind.table:
                    static if (__traits(compiles, mixin(expression ~ "." ~ methodName
                        ~ "!(\"" ~ operatorSymbol ~ "\", Target)(Target.init)")))
                    {
                        auto rhs = convertFromValue!Target(args[1]);
                        return convertToValue(mixin(expression ~ "." ~ methodName
                            ~ "!(\"" ~ operatorSymbol ~ "\", Target)(rhs)"));
                    }
                    else { enforce(false, "Operator does not accept an aggregate RHS"); assert(0); }
                default: enforce(false, "Unsupported RHS value kind for templated operator"); assert(0);
            }
            assert(0);
        }, lifetimeOwner);
    }
    else static assert(0, "No supported binary operator");
}

private ReflectedCallable makeLazyAliasEquality(Root, Target, string expression)(
    string debugName, auto ref Root root, Object lifetimeOwner = null)
{
    auto callable = mixin("&" ~ expression ~ ".opEquals");
    alias Rhs = Unqual!(Parameters!(typeof(callable))[0]);
    return new ReflectedCallable(debugName, 2, (Value[] args) {
        auto rhs = convertFromValue!Rhs(args[1]);
        return convertToValue(mixin(expression ~ ".opEquals(rhs)"));
    }, lifetimeOwner);
}

ReflectedCallable makeStaticReflectedCallable(alias overload)(string debugName)
{
    auto callable = &overload;
    return makeReflectedCallable(debugName, callable);
}

ReflectedCallable makeAliasReflectedCallable(alias callable)(string debugName)
{
    auto storedCallable = callable;
    return makeReflectedCallable(debugName, storedCallable);
}

ReflectedCallable makeReflectedConstructor(alias constructor, T)(string debugName)
{
    alias Params = Parameters!constructor;
    alias MutableParams = staticMap!(Unqual, Params);
    return new ReflectedCallable(debugName, Params.length, (Value[] args) {
        auto converted = Tuple!MutableParams();
        static foreach (index, Param; Params)
        {
            converted[index] = convertFromValue!(Unqual!Param)(args[index]);
        }
        static if (is(T == class))
        {
            auto instance = new T(converted.expand);
            return Value.reflect(instance);
        }
        else
        {
            auto instance = T(converted.expand);
            return Value.reflect(instance);
        }
    });
}

private ReflectedCallable makeBoundBinaryOperator(T, string methodName, string operatorSymbol)(
    string debugName, auto ref T value)
{
    auto callable = mixin("&value." ~ methodName ~ "!(\"" ~ operatorSymbol ~ "\")");
    auto bound = makeReflectedCallable(debugName, callable);
    return new ReflectedCallable(debugName, 2, (Value[] args) {
        return bound.invoke(args[1 .. $]);
    });
}

private ReflectedCallable makeBoundUnaryOperator(T, string operatorSymbol)(
    string debugName, auto ref T value)
{
    auto callable = mixin("&value.opUnary!(\"" ~ operatorSymbol ~ "\")");
    auto bound = makeReflectedCallable(debugName, callable);
    return new ReflectedCallable(debugName, 1, (Value[] args) {
        return bound.invoke(args[1 .. $]);
    });
}

private ReflectedCallable makeBoundEqualityOperator(T)(string debugName, auto ref T value)
{
    auto callable = &value.opEquals;
    auto bound = makeReflectedCallable(debugName, callable);
    return new ReflectedCallable(debugName, 2, (Value[] args) {
        return bound.invoke(args[1 .. $]);
    });
}

private Value convertToValue(T)(auto ref T value)
{
    static if (is(T == Value))
    {
        return value;
    }
    else static if (is(T == enum))
    {
        alias BaseType = OriginalType!T;
        BaseType baseValue = cast(BaseType) value;
        return convertToValue(baseValue);
    }
    else static if (isSomeString!T)
    {
        return Value.from(convTo!string(value));
    }
    else static if (is(T == bool))
    {
        return Value.from(value);
    }
    else static if (isIntegral!T)
    {
        return Value.from(cast(long) value);
    }
    else static if (isFloatingPoint!T)
    {
        return Value.from(cast(double) value);
    }
    else static if ((isDynamicArray!T || isStaticArray!T) && !isSomeString!T)
    {
        return Value.from(value);
    }
    else static if (isAssociativeArray!T && isSomeString!(KeyType!T))
    {
        return Value.from(value);
    }
    else static if (isAggregateType!T)
    {
        return Value.reflect(value);
    }
    else
    {
        return Value.native(value);
    }
}

/// Returns a non-negative overload ranking when a Value can be converted to T.
/// Exact Dua representations outrank the permissive conversions retained by
/// convertFromValue (for example, stringification and boolean truthiness).
private int conversionScore(T)(const(Value) value)
{
    static if (is(T == Value))
    {
        return 1;
    }
    else static if (isSomeString!T)
    {
        return value.kind == ValueKind.string_ ? 100 : 10;
    }
    else static if (is(T == bool))
    {
        return value.kind == ValueKind.boolean ? 100 : 10;
    }
    else static if (isIntegral!T)
    {
        if (value.kind != ValueKind.integer)
            return -1;
        // long is Dua's native integer representation. Other integral types
        // remain equally ranked so narrowing overloads are not chosen by luck.
        return is(Unqual!T == long) ? 100 : 90;
    }
    else static if (isFloatingPoint!T)
    {
        if (value.kind == ValueKind.floating)
            return is(Unqual!T == double) ? 100 : 90;
        return value.kind == ValueKind.integer ? 50 : -1;
    }
    else static if (isDelegate!T)
    {
        return value.kind == ValueKind.function_ ? 100 : -1;
    }
    else static if ((isDynamicArray!T || isStaticArray!T) && !isSomeString!T)
    {
        if (value.kind != ValueKind.array)
            return -1;
        static if (isStaticArray!T)
            if (value.arrayValue.length != T.length)
                return -1;
        int score = 80;
        foreach (element; value.arrayValue)
        {
            auto elementScore = conversionScore!(ForeachType!T)(element);
            if (elementScore < 0)
                return -1;
            score += elementScore;
        }
        return score;
    }
    else static if (isAssociativeArray!T && isSomeString!(KeyType!T))
    {
        return value.kind == ValueKind.table ? 80 : -1;
    }
    else static if (isAggregateType!T && !is(T == class))
    {
        return value.kind == ValueKind.table ? 80 : -1;
    }
    else
    {
        return -1;
    }
}

private T convertFromValue(T)(const(Value) value)
{
    static if (is(T == Value))
    {
        return value;
    }
    else static if (isSomeString!T)
    {
        return convTo!T(value.toHostString());
    }
    else static if (is(T == bool))
    {
        return value.truthy();
    }
    else static if (isIntegral!T)
    {
        return cast(T) value.toInt();
    }
    else static if (isFloatingPoint!T)
    {
        return cast(T) value.toFloat();
    }
    else static if (isDelegate!T)
    {
        enforce(value.kind == ValueKind.function_,
            format("Expected function value to convert into '%s' but got %s", T.stringof, value.kind));
        // A const Value only makes the handle const; invoking a function may
        // legitimately mutate the script closure captured by the callable.
        auto callable = cast(CallableValue) value.functionValue;

        ReturnType!T converted(Parameters!T args)
        {
            Value[] convertedArgs;
            static foreach (index; 0 .. Parameters!T.length)
                convertedArgs ~= convertToValue(args[index]);

            auto result = callable.invoke(convertedArgs);
            static if (is(ReturnType!T == void))
                return;
            else
                return convertFromValue!(ReturnType!T)(result);
        }

        return &converted;
    }
    else static if (isAggregateType!T && !is(T == class))
    {
        enforce(value.kind == ValueKind.table,
            format("Expected table value to convert into '%s' but got %s", T.stringof, value.kind));
        alias MutableT = Unqual!T;

        // A reflected alias-this wrapper retains its outer fields.  When an
        // operator expects the target type, peel the single structural layer
        // whose table exposes that target's fields.
        static if (FieldNameTuple!MutableT.length)
        {
            enum firstField = FieldNameTuple!MutableT[0];
            if (firstField !in value.tableValue)
            {
                foreach (candidate; value.tableValue)
                    if (candidate.kind == ValueKind.table && firstField in candidate.tableValue)
                        return convertFromValue!T(candidate);
            }
        }
        MutableT result = MutableT.init;
        static foreach (memberName; FieldNameTuple!MutableT)
        {{
            static if (__traits(compiles, mixin("result." ~ memberName)))
            {
                alias FieldType = typeof(mixin("result." ~ memberName));
                static if (__traits(compiles,
                    mixin("result." ~ memberName) = convertFromValue!FieldType(value)))
                {
                    if (auto fieldValue = memberName in value.tableValue)
                    {
                        mixin("result." ~ memberName) = convertFromValue!FieldType(*fieldValue);
                    }
                }
            }
        }}
        return result;
    }
    else
    {
        enforce(false, format("Cannot convert Value to '%s'", T.stringof));
        assert(0);
    }
}

bool valuesEqual(Value left, Value right)
{
    if (left.kind == right.kind)
    {
        final switch (left.kind)
        {
            case ValueKind.null_:
                return true;
            case ValueKind.integer:
                return left.integerValue == right.integerValue;
            case ValueKind.floating:
                return left.floatingValue == right.floatingValue;
            case ValueKind.boolean:
                return left.booleanValue == right.booleanValue;
            case ValueKind.string_:
                return left.stringValue == right.stringValue;
            case ValueKind.array:
                if (left.arrayValue.length != right.arrayValue.length)
                {
                    return false;
                }
                foreach (index, item; left.arrayValue)
                {
                    if (!valuesEqual(item, right.arrayValue[index]))
                    {
                        return false;
                    }
                }
                return true;
            case ValueKind.table:
                if (left.tableValue.length != right.tableValue.length)
                {
                    return false;
                }
                foreach (key, value; left.tableValue)
                {
                    auto other = key in right.tableValue;
                    if (other is null || !valuesEqual(value, *other))
                    {
                        return false;
                    }
                }
                return true;
            case ValueKind.function_:
                return left.functionValue is right.functionValue;
            case ValueKind.native:
                return left.nativeTypeName == right.nativeTypeName
                    && left.nativeDisplay == right.nativeDisplay;
        }
    }

    if (left.isNumber() && right.isNumber())
    {
        return left.toFloat() == right.toFloat();
    }

    return false;
}

private struct ReflectionVectorFixture
{
    double x;
    double y;

    double dot(const ReflectionVectorFixture other) const
    {
        return x * other.x + y * other.y;
    }

    int[2] indices() const
    {
        return [1, 2];
    }
}

private class ReflectionMemberFilteringFixture
{
    enum LightMode
    {
        dark,
        light
    }

    int score = 7;
    Tuple!(bool, ubyte, ubyte) color;
    double[4] weights = [1.0, 2.0, 3.0, 4.0];
    ReflectionVectorFixture[4] vertices;
    ubyte* pixels;

    void repoxy(T)(T value)
    {
    }
}

private int applyDelegateFixture(int value, int delegate(int) transform)
{
    return transform(value);
}

unittest
{
    auto fixture = new ReflectionMemberFilteringFixture();
    fixture.color = typeof(fixture.color)(true, 10, 20);

    auto reflected = Value.reflect(fixture);

    assert(reflected.kind == ValueKind.table);
    assert(reflected.tableValue["score"].toInt() == 7);
    assert("color" in reflected.tableValue);
    assert(reflected.tableValue["weights"].kind == ValueKind.array);
    assert(reflected.tableValue["weights"].arrayValue.length == 4);
    assert(reflected.tableValue["vertices"].kind == ValueKind.array);
    assert(reflected.tableValue["pixels"].kind == ValueKind.native);
    assert("LightMode" !in reflected.tableValue);
    assert("repoxy" !in reflected.tableValue);

    auto vector = ReflectionVectorFixture(3.0, 4.0);
    auto reflectedVector = Value.reflect(vector);
    assert(reflectedVector.tableValue["dot"].kind == ValueKind.function_);
    auto dotResult = reflectedVector.tableValue["dot"].functionValue.invoke([
        Value.reflect(ReflectionVectorFixture(1.0, 2.0))
    ]);
    assert(dotResult.toFloat() == 11.0);
    assert(reflectedVector.tableValue["indices"].functionValue.invoke([]).arrayValue.length == 2);
}

unittest
{
    auto scriptDelegate = Value.fromFunction(new ReflectedCallable("double", 1, (Value[] args) {
        return Value.from(args[0].toInt() * 2);
    }));

    auto converted = scriptDelegate.to!(int delegate(int));
    assert(converted(21) == 42);

    auto hostFunction = makeStaticReflectedCallable!applyDelegateFixture("applyDelegateFixture");
    auto result = hostFunction.invoke([Value.from(21), scriptDelegate]);
    assert(result.toInt() == 42);
}
