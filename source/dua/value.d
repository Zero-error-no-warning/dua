module dua.value;

import std.algorithm : map;
import std.array : array;
import std.conv : convTo = to;
import std.exception : enforce;
import std.format : format;
import std.string : indexOf, join;
import std.meta : AliasSeq, staticIndexOf, staticMap;
import std.traits : BaseClassesTuple, FieldNameTuple, ForeachType, KeyType, OriginalType, ParameterDefaults, Parameters, ReturnType, Unqual, Variadic, isAggregateType, isAssociativeArray, isCallable, isDelegate, isDynamicArray, isFloatingPoint, isIntegral, isInstanceOf, isSomeString, isStaticArray, variadicFunctionStyle;
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

    size_t maximumArity() const
    {
        return expectedArity();
    }

    final bool acceptsArity(size_t arity) const
    {
        return arity >= minimumArity() && arity <= maximumArity();
    }
}

final class ReflectedCallable : CallableValue
{
    private Value delegate(Value[] args) invoker;
    private int delegate(scope const(Value)[] args) argumentMatcher;
    private size_t minimum;
    private size_t maximum;
    // Keeps a heap-backed struct receiver alive for the lifetime of its bound
    // delegate. Class receivers do not need a separate owner.
    private Object lifetimeOwner;

    this(string debugName, size_t minimum, Value delegate(Value[] args) invoker,
        Object lifetimeOwner = null,
        int delegate(scope const(Value)[] args) argumentMatcher = null,
        size_t maximum = size_t.max, bool unbounded = false)
    {
        super(debugName);
        this.minimum = minimum;
        this.maximum = unbounded ? size_t.max
            : maximum == size_t.max ? minimum : maximum;
        this.invoker = invoker;
        this.lifetimeOwner = lifetimeOwner;
        this.argumentMatcher = argumentMatcher;
    }

    override Value invoke(Value[] args)
    {
        return invoker(args);
    }

    override size_t expectedArity() const
    {
        return minimum == maximum ? minimum : size_t.max;
    }

    override size_t minimumArity() const
    {
        return minimum;
    }

    override size_t maximumArity() const
    {
        return maximum;
    }

    int matchArguments(scope const(Value)[] args) const
    {
        if (!acceptsArity(args.length))
            return -1;
        return argumentMatcher is null ? 0 : argumentMatcher(args);
    }

    string arityDescription() const
    {
        if (minimum == maximum)
            return format("%s", minimum);
        if (maximum == size_t.max)
            return format("at least %s", minimum);
        return format("%s to %s", minimum, maximum);
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
        string[] allowed;
        foreach (overload; overloads)
            allowed ~= overload.arityDescription();
        enforce(match !is null,
            format("Function '%s' has no overload matching %s arguments (allowed: %s)",
                debugName, args.length, allowed.join(", ")));
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
    struct_,
    function_,
    native
}

enum string internalFieldGetterPrefix = "__dua_get_";
enum string internalFieldSetterPrefix = "__dua_set_";
enum string internalAliasThisTargets = "__dua_alias_this_targets";
enum string internalAliasThisChain = "__dua_alias_this_chain";

/// Reference storage makes table identity explicit. Copies of Value (including
/// module exports already handed to an importer) therefore observe additions.
private final class TableStorage
{
    Value[string] entries;
    Value delegate() copier;
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
        foreach (value; values) result.arrayValue ~= value.valueCopy();
        return result;
    }

    static Value from(Value[string] entries)
    {
        Value result;
        result.kind = ValueKind.table;
        result.tableStorage = new TableStorage();
        foreach (key, value; entries) result.tableStorage.entries[key] = value.valueCopy();
        return result;
    }

    /// Creates a native Dua value-aggregate. Its storage is copied at language
    /// value boundaries, unlike a table's deliberately shared storage.
    static Value fromStruct(Value[string] entries)
    {
        auto result = from(entries);
        result.kind = ValueKind.struct_;
        return result;
    }

    Value valueCopy() const
    {
        if (kind != ValueKind.struct_) return cast(Value) this;
        if (tableStorage !is null && tableStorage.copier !is null)
            return tableStorage.copier();
        Value[string] copied;
        foreach (key, value; tableValue) copied[key] = value.valueCopy();
        return Value.fromStruct(copied);
    }

    void setTypeChain(Value[] chain)
    {
        tableValue["__typechain"] = Value.from(chain);
        if (kind == ValueKind.struct_ && tableStorage.copier !is null)
        {
            auto previous = tableStorage.copier;
            auto saved = chain.dup;
            tableStorage.copier = () {
                auto copied = previous();
                copied.setTypeChain(saved);
                return copied;
            };
        }
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
                    {{
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
                    }}
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
                            if (overload.acceptsArity(0))
                            {
                                converted[internalFieldGetterPrefix ~ memberName] = Value.fromFunction(overload);
                            }
                            if (overload.acceptsArity(1))
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
            T.stringof ~ ".opEquals", reflectedTarget.value, reflectedTarget)))
        {
            converted["__eq"] = Value.fromFunction(
                makeBoundEqualityOperator(T.stringof ~ ".opEquals", reflectedTarget.value, reflectedTarget));
        }
        static foreach (memberName; FieldNameTuple!T)
        {{
            static if (__traits(compiles, convertToValue(mixin("value." ~ memberName))))
            {
                static if (is(T == struct))
                    converted[memberName] = convertToValue(mixin("reflectedTarget.value." ~ memberName));
                else
                    converted[memberName] = convertToValue(mixin("value." ~ memberName));
                static if (is(T == class) || is(T == struct))
                {
                    converted[internalFieldGetterPrefix ~ memberName] = Value.fromFunction(
                        new ReflectedCallable(T.stringof ~ "." ~ memberName ~ ".getter", 0, (Value[] args) {
                        static if (is(T == struct))
                            return convertToValue(mixin("reflectedTarget.value." ~ memberName));
                        else
                            return convertToValue(mixin("value." ~ memberName));
                    }));
                    static if (__traits(compiles, mixin("reflectedTarget.value." ~ memberName) = mixin("reflectedTarget.value." ~ memberName))
                        || __traits(compiles, mixin("value." ~ memberName) = mixin("value." ~ memberName)))
                    {
                        converted[internalFieldSetterPrefix ~ memberName] = Value.fromFunction(
                            new ReflectedCallable(T.stringof ~ "." ~ memberName ~ ".setter", 1, (Value[] args) {
                            static if (is(T == struct))
                            {
                                alias FieldType = typeof(mixin("reflectedTarget.value." ~ memberName));
                                mixin("reflectedTarget.value." ~ memberName) = convertFromValue!FieldType(args[0]);
                            }
                            else
                            {
                                alias FieldType = typeof(mixin("value." ~ memberName));
                                mixin("value." ~ memberName) = convertFromValue!FieldType(args[0]);
                            }
                            return Value.nullValue();
                        }));
                    }
                }
            }
        }}
        static if (is(T == class) || is(T == struct))
        {
            Value[] typeChain;
            typeChain ~= Value.from(T.stringof);
            static if (is(T == class))
                static foreach (Base; BaseClassesTuple!T){{
                    typeChain ~= Value.from(Base.stringof);
            }}
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
        auto result = Value.from(converted);
        static if (is(T == struct))
        {
            result.kind = ValueKind.struct_;
            auto owner = reflectedTarget;
            result.tableStorage.copier = () => Value.reflect(owner.value);
        }
        return result;
    }

    bool isNumber() const
    {
        return kind == ValueKind.integer || kind == ValueKind.floating;
    }

    bool isFieldAggregate() const
    {
        return kind == ValueKind.table || kind == ValueKind.struct_;
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
            case ValueKind.struct_:
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
            case ValueKind.struct_:
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
            case ValueKind.struct_:
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
        static if (staticIndexOf!(Next, Seen) < 0)
        {
            // Keep the actual alias-this value available to host conversions.
            // Reflected members alone are insufficient when an outer method
            // shadows a field of the aliased aggregate.
            Value aliasTarget = Value.fromFunction(new ReflectedCallable(
                Root.stringof ~ ".alias this -> " ~ Next.stringof, 0,
                (Value[] args) => convertToValue(mixin(nextExpression)), lifetimeOwner));
            if (internalAliasThisTargets in converted)
                converted[internalAliasThisTargets].arrayValue ~= aliasTarget;
            else
                converted[internalAliasThisTargets] = Value.from([aliasTarget]);

            Value[] aliasChain;
            if (auto existing = internalAliasThisChain in converted)
                aliasChain = existing.arrayValue.dup;
            void appendAliasType(string name)
            {
                foreach (entry; aliasChain)
                    if (entry.toHostString() == name)
                        return;
                aliasChain ~= Value.from(name);
            }
            appendAliasType(Next.stringof);
            static if (is(Next == class))
                static foreach (Base; BaseClassesTuple!Next)
                    appendAliasType(Base.stringof);
            converted[internalAliasThisChain] = Value.from(aliasChain);

            static if (isAggregateType!Next)
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
                        {{
                            static if (__traits(compiles, makeLazyAliasCallable!(overload,
                                Root, nextExpression)(Root.stringof ~ "." ~ memberName,
                                    root, lifetimeOwner)))
                                overloads ~= makeLazyAliasCallable!(overload, Root,
                                    nextExpression)(Root.stringof ~ "." ~ memberName,
                                        root, lifetimeOwner);
                        }}
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
}

private template RequiredDefaultArity(Defaults...)
{
    static if (Defaults.length == 0 || !is(Defaults[0] == void))
        enum RequiredDefaultArity = 0;
    else
        enum RequiredDefaultArity = 1 + RequiredDefaultArity!(Defaults[1 .. $]);
}

private enum reflectedMinimumArity(alias declaration) =
    RequiredDefaultArity!(ParameterDefaults!declaration);

private ReflectedCallable makeReflectedCallableWithDefaults(alias declaration, C)(string debugName,
    auto ref C callable,
    Object lifetimeOwner = null)
    if (isCallable!C)
{
    alias Params = Parameters!C;
    alias MutableParams = staticMap!(Unqual, Params);
    enum isTypesafeVariadic = variadicFunctionStyle!C == Variadic.typesafe;
    enum fixedArity = isTypesafeVariadic ? Params.length - 1 : Params.length;
    enum minimum = isTypesafeVariadic ? fixedArity : reflectedMinimumArity!declaration;
    enum maximum = isTypesafeVariadic ? size_t.max : fixedArity;
    auto storedCallable = callable;
    return new ReflectedCallable(debugName, minimum, (Value[] args) {
        enforce(args.length >= minimum && args.length <= maximum,
            minimum == maximum
                ? format("Function '%s' expected %s arguments but got %s", debugName, minimum, args.length)
                : maximum == size_t.max
                    ? format("Function '%s' expected at least %s arguments but got %s", debugName, minimum, args.length)
                    : format("Function '%s' expected %s to %s arguments but got %s", debugName, minimum, maximum, args.length));

        auto converted = Tuple!MutableParams();
        static foreach (index; 0 .. fixedArity)
        {{
            if (index < args.length)
                converted[index] = convertFromValue!(MutableParams[index])(args[index]);
            else static if (!is(ParameterDefaults!declaration[index] == void))
                converted[index] = ParameterDefaults!declaration[index];
        }}
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
            return convertToValue(storedCallable(converted.expand));
    }, lifetimeOwner, (scope const(Value)[] args) {
        static if (isTypesafeVariadic)
        {
            if (args.length < fixedArity)
                return -1;
        }
        else if (args.length < minimum || args.length > maximum)
        {
            return -1;
        }
        int score;
        static foreach (index; 0 .. fixedArity)
        {{
            if (index < args.length)
            {
                auto parameterScore = conversionScore!(MutableParams[index])(args[index]);
                if (parameterScore < 0)
                    return -1;
                score += parameterScore;
            }
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
        else
        {
            // Prefer an overload for which fewer default arguments are omitted.
            score -= cast(int) (fixedArity - args.length);
        }
        return score;
    }, maximum, isTypesafeVariadic);
}

package(dua) ReflectedCallable makeReflectedCallable(C)(string debugName, auto ref C callable,
    Object lifetimeOwner = null)
    if (isCallable!C)
{
    alias Params = Parameters!C;
    alias MutableParams = staticMap!(Unqual, Params);
    enum variadic = variadicFunctionStyle!C == Variadic.typesafe;
    enum fixedArity = variadic ? Params.length - 1 : Params.length;
    auto storedCallable = callable;
    return new ReflectedCallable(debugName, fixedArity, (Value[] args) {
        enforce(variadic ? args.length >= fixedArity : args.length == fixedArity,
            format("Function '%s' expected %s%s arguments but got %s", debugName,
                variadic ? "at least " : "", fixedArity, args.length));
        auto converted = Tuple!MutableParams();
        static foreach (index; 0 .. fixedArity){{
            converted[index] = convertFromValue!(MutableParams[index])(args[index]);
        }}
        static if (variadic)
        {
            alias Element = ForeachType!(MutableParams[$ - 1]);
            foreach (arg; args[fixedArity .. $])
                converted[$ - 1] ~= convertFromValue!Element(arg);
        }
        static if (is(ReturnType!C == void))
        {
            storedCallable(converted.expand);
            return Value.nullValue();
        }
        else
            return convertToValue(storedCallable(converted.expand));
    }, lifetimeOwner, (scope const(Value)[] args) {
        if (variadic ? args.length < fixedArity : args.length != fixedArity)
            return -1;
        int score;
        static foreach (index; 0 .. fixedArity)
        {{
            auto parameterScore = conversionScore!(MutableParams[index])(args[index]);
            if (parameterScore < 0) return -1;
            score += parameterScore;
        }}
        static if (variadic)
        {
            alias Element = ForeachType!(MutableParams[$ - 1]);
            foreach (arg; args[fixedArity .. $])
            {
                auto parameterScore = conversionScore!Element(arg);
                if (parameterScore < 0) return -1;
                score += parameterScore;
            }
            --score;
        }
        return score;
    }, size_t.max, variadic);
}

private ReflectedCallable makeBoundReflectedCallable(alias overload, T)(string debugName,
    auto ref T value, Object lifetimeOwner = null)
{
    alias Function = typeof(overload);
    alias Delegate = ReturnType!Function delegate(Parameters!Function);
    Delegate callable = &__traits(getMember, value, __traits(identifier, overload));
    return makeReflectedCallableWithDefaults!overload(debugName, callable, lifetimeOwner);
}

private ReflectedCallable makeLazyAliasCallable(alias overload, Root, string expression)(
    string debugName, auto ref Root root, Object lifetimeOwner = null)
{
    alias Function = typeof(overload);
    alias Params = Parameters!Function;
    alias MutableParams = staticMap!(Unqual, Params);
    enum minimum = reflectedMinimumArity!overload;
    return new ReflectedCallable(debugName, minimum, (Value[] args) {
        auto converted = Tuple!MutableParams();
        static foreach (index, Param; Params){{
            if (index < args.length)
            converted[index] = convertFromValue!(Unqual!Param)(args[index]);
        }}
        static if (is(ReturnType!Function == void))
        {
            static foreach (count; minimum .. Params.length + 1){{
                if (args.length == count)
                    __traits(getMember, mixin(expression),
                        __traits(identifier, overload))(converted[0 .. count]);
            }}
            return Value.nullValue();
        }
        else
        {
            static foreach (count; minimum .. Params.length + 1){{
                if (args.length == count)
                    return convertToValue(__traits(getMember, mixin(expression),
                        __traits(identifier, overload))(converted[0 .. count]));
            }}
            assert(0);
        }
    }, lifetimeOwner, null, Params.length);
}

private ReflectedCallable makeLazyAliasBinary(Root, Target, string expression,
    string methodName, string operatorSymbol)(string debugName, auto ref Root root,
        Object lifetimeOwner = null)
{
    return new ReflectedCallable(debugName, 2, (Value[] args) {
        auto rhsValue = args[1];
        int bestScore = -1;
        Value delegate() invocation;
        static if (__traits(compiles, mixin("&" ~ expression ~ "." ~ methodName
            ~ "!(\"" ~ operatorSymbol ~ "\")")))
        {
            alias Callable = typeof(mixin("&" ~ expression ~ "." ~ methodName
                ~ "!(\"" ~ operatorSymbol ~ "\")"));
            alias Rhs = Unqual!(Parameters!Callable[0]);
            auto score = conversionScore!Rhs(rhsValue);
            if (score >= 0)
            {
                bestScore = score;
                invocation = () {
                    auto rhs = convertFromValue!Rhs(rhsValue);
                    return convertToValue(mixin(expression ~ "." ~ methodName
                        ~ "!(\"" ~ operatorSymbol ~ "\")(rhs)"));
                };
            }
        }
        void considerGeneric(R)()
        {
            static if (methodName == "opBinary")
                enum acceptsGeneric = __traits(compiles,
                    Target.init.opBinary!(operatorSymbol, R)(R.init));
            else
                enum acceptsGeneric = __traits(compiles,
                    Target.init.opBinaryRight!(operatorSymbol, R)(R.init));
            static if (acceptsGeneric)
            {
                auto genericScore = conversionScore!R(rhsValue);
                if (genericScore > bestScore)
                {
                    bestScore = genericScore;
                    invocation = () {
                        auto rhs = convertFromValue!R(rhsValue);
                        auto ref target = mixin(expression);
                        static if (methodName == "opBinary")
                            return convertToValue(target.opBinary!(operatorSymbol, R)(rhs));
                        else
                            return convertToValue(target.opBinaryRight!(operatorSymbol, R)(rhs));
                    };
                }
            }
        }
        static if (__traits(compiles, mixin("&" ~ expression ~ "." ~ methodName
            ~ "!(\"" ~ operatorSymbol ~ "\")")))
        {
            static if (variadicFunctionStyle!(typeof(mixin("&" ~ expression ~ "."
                    ~ methodName ~ "!(\"" ~ operatorSymbol ~ "\")"))) == Variadic.no)
            {
                considerGeneric!long();
                considerGeneric!double();
            }
        }
        else
        {
            considerGeneric!long();
            considerGeneric!double();
        }
        enforce(invocation !is null,
            format("Operator '%s' has no overload matching RHS kind %s",
                operatorSymbol, rhsValue.kind));
        return invocation();
    }, lifetimeOwner);
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
    return makeReflectedCallableWithDefaults!overload(debugName, callable);
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
    enum minimum = reflectedMinimumArity!constructor;
    return new ReflectedCallable(debugName, minimum, (Value[] args) {
        auto converted = Tuple!MutableParams();
        static foreach (index, Param; Params)
        {{
            if (index < args.length)
                converted[index] = convertFromValue!(Unqual!Param)(args[index]);
        }}
        static if (is(T == class))
        {
            static foreach (count; minimum .. Params.length + 1){{
                if (args.length == count)
                    return Value.reflect(new T(converted[0 .. count]));
            }}
        }
        else
        {
            static foreach (count; minimum .. Params.length + 1){{
                if (args.length == count)
                    return Value.reflect(T(converted[0 .. count]));
            }}
        }
        assert(0);
    }, null, null, Params.length);
}

private ReflectedCallable makeBoundBinaryOperator(T, string methodName, string operatorSymbol)(
    string debugName, auto ref T value)
{
    return new ReflectedCallable(debugName, 2, (Value[] args) {
        auto rhsValue = args[1];
        int bestScore = -1;
        Value delegate() invocation;

        // A partially instantiated overload represents every concrete RHS
        // declaration.  Do not let its mere existence hide a second overload
        // whose RHS remains a template parameter.
        static if (__traits(compiles,
            mixin("&value." ~ methodName ~ "!(\"" ~ operatorSymbol ~ "\")")))
        {
            auto concrete = mixin("&value." ~ methodName ~ "!(\"" ~ operatorSymbol ~ "\")");
            alias ConcreteRhs = Unqual!(Parameters!(typeof(concrete))[0]);
            auto score = conversionScore!ConcreteRhs(rhsValue);
            if (score >= 0)
            {
                bestScore = score;
                invocation = () {
                    auto rhs = convertFromValue!ConcreteRhs(rhsValue);
                    return convertToValue(concrete(rhs));
                };
            }
        }

        void considerGeneric(R)()
        {
            static if (methodName == "opBinary")
                enum acceptsGeneric = __traits(compiles,
                    value.opBinary!(operatorSymbol, R)(R.init));
            else
                enum acceptsGeneric = __traits(compiles,
                    value.opBinaryRight!(operatorSymbol, R)(R.init));
            static if (acceptsGeneric)
            {
                auto genericScore = conversionScore!R(rhsValue);
                if (genericScore > bestScore)
                {
                    bestScore = genericScore;
                    invocation = () {
                        auto rhs = convertFromValue!R(rhsValue);
                        static if (methodName == "opBinary")
                            return convertToValue(value.opBinary!(operatorSymbol, R)(rhs));
                        else
                            return convertToValue(value.opBinaryRight!(operatorSymbol, R)(rhs));
                    };
                }
            }
        }
        static if (__traits(compiles,
            mixin("&value." ~ methodName ~ "!(\"" ~ operatorSymbol ~ "\")")))
        {
            static if (variadicFunctionStyle!(typeof(mixin("&value." ~ methodName
                    ~ "!(\"" ~ operatorSymbol ~ "\")"))) == Variadic.no)
            {
                considerGeneric!long();
                considerGeneric!double();
            }
        }
        enforce(invocation !is null,
            format("Operator '%s' has no overload matching RHS kind %s",
                operatorSymbol, rhsValue.kind));
        return invocation();
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

private ReflectedCallable makeBoundEqualityOperator(T)(string debugName, auto ref T value,
    Object lifetimeOwner = null)
{
    auto callable = &value.opEquals;
    auto bound = makeReflectedCallable(debugName, callable, lifetimeOwner);
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
        if (value.kind == ValueKind.string_) return 100;
        return aliasThisConversionScore!T(value, 10);
    }
    else static if (is(T == bool))
    {
        if (value.kind == ValueKind.boolean) return 100;
        return aliasThisConversionScore!T(value, 10);
    }
    else static if (isIntegral!T)
    {
        if (value.kind != ValueKind.integer)
            return aliasThisConversionScore!T(value);
        // long is Dua's native integer representation. Other integral types
        // remain equally ranked so narrowing overloads are not chosen by luck.
        return is(Unqual!T == long) ? 100 : 90;
    }
    else static if (isFloatingPoint!T)
    {
        if (value.kind == ValueKind.floating)
            return is(Unqual!T == double) ? 100 : 90;
        if (value.kind == ValueKind.integer) return 50;
        return aliasThisConversionScore!T(value);
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
        return value.isFieldAggregate ? 80 : -1;
    }
    else static if (isAggregateType!T && !is(T == class))
    {
        if (!value.isFieldAggregate)
            return -1;

        int directScore = 80;
        static foreach (memberName; FieldNameTuple!(Unqual!T))
        {{
            static if (__traits(compiles,
                __traits(getMember, Unqual!T.init, memberName)))
            {
                alias FieldType = typeof(__traits(getMember, Unqual!T.init, memberName));
                if (auto fieldValue = memberName in value.tableValue)
                {
                    auto fieldScore = conversionScore!FieldType(*fieldValue);
                    if (fieldScore < 0)
                        directScore = -1;
                    else if (directScore >= 0)
                        directScore += fieldScore;
                }
            }
        }}

        int bestScore = directScore;
        if (auto targets = internalAliasThisTargets in value.tableValue)
        {
            foreach (target; targets.arrayValue)
            {
                auto resolved = cast(Value) target;
                if (resolved.kind == ValueKind.function_ && resolved.functionValue.acceptsArity(0))
                    resolved = (cast(CallableValue) resolved.functionValue).invoke([]);
                auto targetScore = conversionScore!T(resolved);
                // Preserve the established outer-member preference whenever
                // both the wrapper and its alias target are convertible.
                if (targetScore >= 0 && targetScore - 1 > bestScore)
                    bestScore = targetScore - 1;
            }
        }
        return bestScore;
    }
    else
    {
        return -1;
    }
}

private int aliasThisConversionScore(T)(const(Value) value, int fallback = -1)
{
    if (!value.isFieldAggregate) return fallback;
    if (auto targets = internalAliasThisTargets in value.tableValue)
    {
        foreach (stored; targets.arrayValue)
        {
            auto target = cast(Value) stored;
            if (target.kind == ValueKind.function_ && target.functionValue.acceptsArity(0))
                target = (cast(CallableValue) target.functionValue).invoke([]);
            auto score = conversionScore!T(target);
            if (score >= 0) return score - 1;
        }
    }
    return fallback;
}

private bool convertAliasThisTarget(T)(const(Value) value, out T result)
{
    if (!value.isFieldAggregate) return false;
    if (auto targets = internalAliasThisTargets in value.tableValue)
        foreach (stored; targets.arrayValue)
        {
            auto target = cast(Value) stored;
            if (target.kind == ValueKind.function_ && target.functionValue.acceptsArity(0))
                target = (cast(CallableValue) target.functionValue).invoke([]);
            if (conversionScore!T(target) >= 0)
            {
                result = convertFromValue!T(target);
                return true;
            }
        }
    return false;
}

private T convertFromValue(T)(const(Value) value)
{
    static if (is(T == Value))
    {
        return value;
    }
    else static if (isSomeString!T)
    {
        if (value.kind != ValueKind.string_)
        {
            T aliased;
            if (convertAliasThisTarget!T(value, aliased)) return aliased;
        }
        return convTo!T(value.toHostString());
    }
    else static if (is(T == bool))
    {
        if (value.kind != ValueKind.boolean)
        {
            T aliased;
            if (convertAliasThisTarget!T(value, aliased)) return aliased;
        }
        return value.truthy();
    }
    else static if (isIntegral!T)
    {
        if (value.kind != ValueKind.integer)
        {
            T aliased;
            if (convertAliasThisTarget!T(value, aliased)) return aliased;
        }
        return cast(T) value.toInt();
    }
    else static if (isFloatingPoint!T)
    {
        if (!value.isNumber)
        {
            T aliased;
            if (convertAliasThisTarget!T(value, aliased)) return aliased;
        }
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
            static foreach (index; 0 .. Parameters!T.length){{
                convertedArgs ~= convertToValue(args[index]);
            }}

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
        enforce(value.isFieldAggregate,
            format("Expected table value to convert into '%s' but got %s", T.stringof, value.kind));
        alias MutableT = Unqual!T;

        // A callable alias-this target is reflected separately because its
        // fields can be shadowed by outer getters/setters.  Only peel the
        // wrapper when its own visible fields cannot form the requested type.
        bool directFieldsCompatible = true;
        static foreach (memberName; FieldNameTuple!MutableT)
        {{
            static if (__traits(compiles, __traits(getMember, MutableT.init, memberName)))
            {
                alias FieldType = typeof(__traits(getMember, MutableT.init, memberName));
                if (auto fieldValue = memberName in value.tableValue)
                    if (conversionScore!FieldType(*fieldValue) < 0)
                        directFieldsCompatible = false;
            }
        }}
        if (!directFieldsCompatible)
        {
            T aliased;
            if (convertAliasThisTarget!T(value, aliased)) return aliased;
        }

        // A reflected alias-this wrapper retains its outer fields.  When an
        // operator expects the target type, peel the single structural layer
        // whose table exposes that target's fields.
        static if (FieldNameTuple!MutableT.length)
        {
            enum firstField = FieldNameTuple!MutableT[0];
            if (firstField !in value.tableValue)
            {
                foreach (candidate; value.tableValue)
                    if (candidate.isFieldAggregate && firstField in candidate.tableValue)
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
            case ValueKind.struct_:
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

private int reflectedDefaultStatic(int required, int first = 10, int second = 20)
{
    return required + first + second;
}

private int reflectedDefaultOverload()
{
    return 100;
}

private int reflectedDefaultOverload(int value = 7)
{
    return value;
}

private struct ReflectedDefaultFixture
{
    int base;

    int mod(int value = 6)
    {
        return base + value;
    }

    int combine(int required, int first = 2, int second = 3)
    {
        return base + required + first + second;
    }
}

private struct ReflectedDefaultConstructorFixture
{
    int value;

    this(int required, int optional = 4)
    {
        value = required + optional;
    }
}

unittest
{
    auto reflected = Value.reflect(ReflectedDefaultFixture(1));
    auto mod = reflected.tableValue["mod"].functionValue;
    assert(mod.minimumArity() == 0);
    assert(mod.maximumArity() == 1);
    assert(mod.invoke([]).toInt() == 7);
    assert(mod.invoke([Value.from(4)]).toInt() == 5);
    assert(reflected.tableValue[internalFieldGetterPrefix ~ "mod"]
        .functionValue.invoke([]).toInt() == 7);

    auto combine = reflected.tableValue["combine"].functionValue;
    assert(combine.minimumArity() == 1);
    assert(combine.maximumArity() == 3);
    assert(combine.invoke([Value.from(4)]).toInt() == 10);
    assert(combine.invoke([Value.from(4), Value.from(5), Value.from(6)]).toInt() == 16);

    alias constructor = __traits(getOverloads, ReflectedDefaultConstructorFixture, "__ctor")[0];
    auto ctor = makeReflectedConstructor!(constructor,
        ReflectedDefaultConstructorFixture)("DefaultConstructor.new");
    assert(ctor.minimumArity() == 1 && ctor.maximumArity() == 2);
    assert(ctor.invoke([Value.from(3)]).tableValue["value"].toInt() == 7);
    assert(ctor.invoke([Value.from(3), Value.from(6)]).tableValue["value"].toInt() == 9);

    auto staticCallable = makeStaticReflectedCallable!reflectedDefaultStatic("defaults");
    assert(staticCallable.invoke([Value.from(1)]).toInt() == 31);
    assert(staticCallable.invoke([Value.from(1), Value.from(2)]).toInt() == 23);

    ReflectedCallable[] overloads;
    static foreach (overload; __traits(getOverloads, __traits(parent, reflectedDefaultOverload),
        "reflectedDefaultOverload")){{
        overloads ~= makeStaticReflectedCallable!overload("overloadedDefaults");
    }}
    auto overloaded = new OverloadedReflectedCallable("overloadedDefaults", overloads);
    assert(overloaded.invoke([]).toInt() == 100);
    assert(overloaded.invoke([Value.from(9)]).toInt() == 9);

    foreach (badArgs; [Value[].init, [Value.from(1), Value.from(2), Value.from(3), Value.from(4)]])
    {
        bool rejected;
        try
            staticCallable.invoke(badArgs);
        catch (Exception error)
        {
            rejected = true;
            assert(error.msg.indexOf("1 to 3 arguments") >= 0);
        }
        assert(rejected);
    }
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

private struct AliasAngleFixture
{
    double value;
    alias value this;
}

private struct AliasWrapperFixture
{
    AliasAngleFixture value;
    alias value this;
}

private struct AliasCallableFixture
{
    int current;
    double scalar() const { return current + 0.5; }
    alias scalar this;
}

private struct AliasAggregateTargetFixture { int amount; }
private struct AliasAggregateFixture
{
    AliasAggregateTargetFixture target;
    alias target this;
}

private class AliasBaseFixture { }
private class AliasDerivedFixture : AliasBaseFixture { }
private struct AliasClassFixture
{
    AliasDerivedFixture target;
    alias target this;
}

private int acceptAliasScalar(double value) { return cast(int)(value * 2); }

unittest
{
    auto angle = Value.reflect(AliasAngleFixture(2.5));
    assert(angle.tableValue["__typechain"].arrayValue.length == 1);
    assert(angle.tableValue["__typechain"].arrayValue[0].toHostString() == "AliasAngleFixture");
    assert(angle.tableValue[internalAliasThisChain].arrayValue[0].toHostString() == "double");
    assert(angle.to!double() == 2.5);

    auto wrapper = Value.reflect(AliasWrapperFixture(AliasAngleFixture(3.5)));
    auto aliasChain = wrapper.tableValue[internalAliasThisChain].arrayValue;
    assert(aliasChain.length == 2);
    assert(aliasChain[0].toHostString() == "AliasAngleFixture");
    assert(aliasChain[1].toHostString() == "double");
    assert(wrapper.to!double() == 3.5);
    assert(wrapper.valueCopy().tableValue[internalAliasThisChain].arrayValue.length == 2);

    auto aggregate = Value.reflect(AliasAggregateFixture(AliasAggregateTargetFixture(7)));
    assert(aggregate.to!AliasAggregateTargetFixture().amount == 7);

    auto callable = Value.reflect(AliasCallableFixture(4));
    assert(callable.to!double() == 4.5);

    auto classAlias = Value.reflect(AliasClassFixture(new AliasDerivedFixture()));
    auto classChain = classAlias.tableValue[internalAliasThisChain].arrayValue;
    assert(classChain[0].toHostString() == "AliasDerivedFixture");
    assert(classChain[1].toHostString() == "AliasBaseFixture");

    auto host = makeStaticReflectedCallable!acceptAliasScalar("acceptAliasScalar");
    assert(host.invoke([wrapper]).toInt() == 7);

    // Alias targets are evaluated lazily instead of retaining a stale snapshot.
    angle.tableValue[internalFieldSetterPrefix ~ "value"].functionValue.invoke([Value.from(8.0)]);
    assert(angle.to!double() == 8.0);
}
