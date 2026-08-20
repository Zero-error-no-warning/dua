module dua.binding;

/**
 * Engine-independent bridges from host D values and callables to Dua values.
 *
 * The binding API is mixed into any host facade that provides
 * `bind(string, Value)`.  It intentionally has no knowledge of ScriptEngine,
 * environments, modules, or evaluator state.
 */
import dua.value;
import std.traits : isAggregateType, isCallable;

alias NativeFunction = Value delegate(scope const(Value)[] args);
enum bool isHostCallable(T) = isCallable!T;

/// Adapts a dynamically typed host callback to Dua's callable representation.
final class NativeCallable : CallableValue
{
    private NativeFunction nativeCallback;

    this(string name, NativeFunction callback)
    {
        super(name);
        this.nativeCallback = callback;
    }

    override Value invoke(Value[] args)
    {
        return nativeCallback(args);
    }
}

/// Automatically converts D values for a facade providing bind(string, Value).
mixin template AutoBindingAPI()
{
    void bindAuto(T)(string name, auto ref T value)
    {
        static if (is(T == Value))
            bind(name, value);
        else static if (isAggregateType!T)
            bind(name, Value.reflect(value));
        else
            bind(name, Value.from(value));
    }

    void opIndexAssign(T)(auto ref T value, string name)
    {
        bindAuto(name, value);
    }
}

/// Converts typed D functions, overload sets, delegates, and lambdas.
mixin template FunctionBindingAPI()
{
    void bindFunc(alias FUN)(string name)
    {
        ReflectedCallable[] overloads;
        static if (__traits(compiles,
            __traits(getOverloads, __traits(parent, FUN), __traits(identifier, FUN))))
        {
            static foreach (overload;
                __traits(getOverloads, __traits(parent, FUN), __traits(identifier, FUN)))
            {
                static if (__traits(compiles, makeStaticReflectedCallable!overload(name)))
                    overloads ~= makeStaticReflectedCallable!overload(name);
            }
        }
        else static if (__traits(compiles, makeAliasReflectedCallable!FUN(name)))
        {
            overloads ~= makeAliasReflectedCallable!FUN(name);
        }
        else
        {
            static assert(0,
                "bindFunc requires a concrete D function or a typed lambda");
        }

        if (overloads.length == 1)
            bind(name, Value.fromFunction(overloads[0]));
        else
            bind(name, Value.fromFunction(new OverloadedReflectedCallable(name, overloads)));
    }

    /// Runtime form for delegates, including lambdas that capture local state.
    void bindFunc(C)(string name, auto ref C callable)
        if (dua.binding.isHostCallable!C)
    {
        bind(name, Value.fromFunction(makeReflectedCallable(name, callable)));
    }
}
