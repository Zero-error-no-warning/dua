module dua.coroutine;

/**
 * Internal coroutine lifecycle and Fiber integration for ScriptEngine.
 *
 * The owning runtime supplies function invocation and global registration.  The
 * evaluator crosses this boundary only through `yieldFromScript`.
 */
import dua.binding : NativeCallable;
import dua.value;
import core.thread : Fiber;
import std.exception : enforce;

package final class CoroutineState
{
    Value entryFunction;
    Fiber fiber;
    Value[] pendingArgs;
    Value[] yieldedValues;
    Value[] returnValues;
    bool started;
    bool dead;
    bool failed;
    string errorMessage;
}

package Fiber createFiber(void delegate() body)
{
    return new Fiber(body, 1024 * 1024);
}

package bool fiberIsSuspended(CoroutineState state)
{
    return state.fiber.state == Fiber.State.HOLD;
}

package void suspendFiber()
{
    Fiber.yield();
}

package mixin template CoroutineImplementation()
{
    private size_t nextCoroutineId = 1;
    private CoroutineState[size_t] coroutines;
    private CoroutineState activeCoroutine;

    private Value createCoroutine(Value functionValue)
    {
        enforce(functionValue.kind == ValueKind.function_, "coroutine.create(callback) expects function");
        auto state = new CoroutineState();
        state.entryFunction = functionValue;

        state.fiber = createFiber({
            activeCoroutine = state;
            scope (exit) activeCoroutine = null;
            try
            {
                auto result = invokeFunctionValue(state.entryFunction, state.pendingArgs.dup);
                state.returnValues = [result];
            }
            catch (Exception error)
            {
                state.failed = true;
                state.errorMessage = error.msg;
            }
            state.dead = true;
        });

        auto id = nextCoroutineId++;
        coroutines[id] = state;
        return coroutineHandle(id);
    }

    private Value coroutineHandle(size_t id)
    {
        Value[string] handle;
        handle["__coid"] = Value.from(cast(long) id);
        return Value.from(handle);
    }

    private CoroutineState requireCoroutineState(Value handle)
    {
        enforce(handle.kind == ValueKind.table, "Coroutine handle must be a table");
        auto idValue = "__coid" in handle.tableValue;
        enforce(idValue !is null, "Invalid coroutine handle");
        auto state = cast(size_t) idValue.toInt() in coroutines;
        enforce(state !is null, "Unknown coroutine handle");
        return *state;
    }

    private Value resumeCoroutine(Value handle, Value[] args)
    {
        auto state = requireCoroutineState(handle);
        if (state.dead)
        {
            auto message = state.failed && state.errorMessage.length > 0
                ? state.errorMessage : "cannot resume dead coroutine";
            return Value.from([Value.from(false), Value.from(message)]);
        }

        state.pendingArgs = args.dup;
        state.yieldedValues.length = 0;
        state.started = true;
        state.fiber.call();

        if (state.failed)
        {
            state.dead = true;
            return Value.from([Value.from(false), Value.from(state.errorMessage)]);
        }
        Value[] values = [Value.from(true)];
        values ~= state.dead ? state.returnValues : state.yieldedValues;
        return Value.from(values);
    }

    private Value coroutineStatus(Value handle)
    {
        auto state = requireCoroutineState(handle);
        if (state.dead) return Value.from("dead");
        if (!state.started) return Value.from("suspended");
        return Value.from(fiberIsSuspended(state) ? "suspended" : "running");
    }

    private Value currentCoroutineHandle()
    {
        if (activeCoroutine is null) return Value.nullValue();
        foreach (id, state; coroutines)
            if (state is activeCoroutine) return coroutineHandle(id);
        return Value.nullValue();
    }

    // The sole evaluator-facing coroutine hook: publish values, suspend, and
    // translate the next resume arguments back to the script's yield expression.
    private Value yieldFromScript(Value[] values)
    {
        enforce(activeCoroutine !is null, "yield can only be used inside a running coroutine");
        activeCoroutine.yieldedValues = values;
        suspendFiber();
        return activeCoroutine.pendingArgs.length > 0
            ? activeCoroutine.pendingArgs[0] : Value.nullValue();
    }

    private void installCoroutineLibrary()
    {
        Value[string] library;
        library["create"] = Value.fromFunction(new NativeCallable("coroutine.create", (scope const(Value)[] args) {
            enforce(args.length == 1, "coroutine.create(callback) expects one argument");
            return createCoroutine(cast(Value) args[0]);
        }));
        library["resume"] = Value.fromFunction(new NativeCallable("coroutine.resume", (scope const(Value)[] args) {
            enforce(args.length >= 1, "coroutine.resume(co, ...) expects at least one argument");
            Value[] resumeArgs;
            foreach (arg; args[1 .. $]) resumeArgs ~= cast(Value) arg;
            return resumeCoroutine(cast(Value) args[0], resumeArgs);
        }));
        library["status"] = Value.fromFunction(new NativeCallable("coroutine.status", (scope const(Value)[] args) {
            enforce(args.length == 1, "coroutine.status(co) expects one argument");
            return coroutineStatus(cast(Value) args[0]);
        }));
        library["running"] = Value.fromFunction(new NativeCallable("coroutine.running", (scope const(Value)[] args) {
            enforce(args.length == 0, "coroutine.running() takes no arguments");
            return currentCoroutineHandle();
        }));
        library["isyieldable"] = Value.fromFunction(new NativeCallable("coroutine.isyieldable", (scope const(Value)[] args) {
            enforce(args.length == 0, "coroutine.isyieldable() takes no arguments");
            return Value.from(activeCoroutine !is null);
        }));
        library["wrap"] = Value.fromFunction(new NativeCallable("coroutine.wrap", (scope const(Value)[] args) {
            enforce(args.length == 1, "coroutine.wrap(callback) expects one argument");
            auto handle = createCoroutine(cast(Value) args[0]);
            return Value.fromFunction(new NativeCallable("coroutine.wrapped", (scope const(Value)[] callArgs) {
                Value[] resumeArgs;
                foreach (arg; callArgs) resumeArgs ~= cast(Value) arg;
                auto resumed = resumeCoroutine(handle, resumeArgs);
                enforce(resumed.kind == ValueKind.array && resumed.arrayValue.length >= 1,
                    "coroutine.wrap resume failed");
                if (!resumed.arrayValue[0].truthy())
                    enforce(false, resumed.arrayValue.length > 1
                        ? resumed.arrayValue[1].toHostString() : "coroutine.wrap failure");
                return resumed.arrayValue.length > 1 ? resumed.arrayValue[1] : Value.nullValue();
            }));
        }));
        globals.define("coroutine", Value.from(library));
    }
}
