module dua.stdlib.core;

import dua.evaluator : ScriptThrownException;
import dua.execution : ExecutionLimitException;
import dua.binding : NativeCallable, NativeFunction;
import dua.stdlib.json : encodeJson, decodeJson;
import dua.stdlib.text : splitText, joinText;
import dua.stdlib.collections : sortedValues;
import dua.value : Value, ValueKind, makeReflectedCallable;
import dua.stdlib.unicode : countCodePoints, codePointAt;
import std.algorithm : canFind;
import std.conv : to;
import std.datetime.systime : Clock;
import std.exception : enforce;
import std.file : exists, readText;
import std.format : format;
import std.math : floor, isFinite;
import std.string : replace;
import std.uni : toLower, toUpper;
import std.utf : byDchar;

alias StdlibNativeFunction = NativeFunction;

/// Narrow internal bridge between the standard library and the execution engine.
package(dua) struct StdlibContext
{
    void delegate(string, StdlibNativeFunction) bindNative;
    void delegate(string, Value) bind;
    void delegate(string, Value) bindFallback;
    void delegate() step;
    string delegate(Value) stringify;
    Value delegate(scope const(Value)[]) typeOfValue;
    Value delegate(scope const(Value)[]) measureLengthValue;
    Value delegate(scope const(Value)[]) iotaValue;
    Value delegate(scope const(Value)[]) setMetatableWithType;
    Value delegate(Value, Value[]) invokeFunctionValue;
    Value delegate(scope const(Value)[]) mapValue;
    Value delegate(scope const(Value)[]) filterValue;
    Value delegate(string) tableKeyToScriptValue;
    string delegate() traceback;
    Value delegate(string) getGlobal;
}

package(dua) void installStandardLibraries(StdlibContext context)
{
    context.bindNative("error", (scope const(Value)[] args) {
        enforce(args.length >= 1, "error(message) expects at least one argument");
        string message = context.stringify(cast(Value) args[0]);
        if (args.length > 1)
        {
            message = format("%s (level: %s)", message, (cast(Value) args[1]).toHostString());
        }
        throw new ScriptThrownException(cast(Value) args[0], message);
        assert(0);
        return Value.nullValue();
    });
    context.bindNative("typeof", (scope const(Value)[] args) {
        return context.typeOfValue(args);
    });
    context.bindNative("typeinfo", (scope const(Value)[] args) {
        return context.typeOfValue(args);
    });
    context.bindNative("length", (scope const(Value)[] args) {
        return context.measureLengthValue(args);
    });
    context.bindNative("len", (scope const(Value)[] args) {
        return context.measureLengthValue(args);
    });
    context.bindNative("iota", (scope const(Value)[] args) {
        return context.iotaValue(args);
    });
    context.bindNative("rawget", (scope const(Value)[] args) {
        enforce(args.length == 2, "rawget(table, key) expects two arguments");
        enforce(args[0].kind == ValueKind.table, "rawget first argument must be table");
        auto key = (cast(Value) args[1]).toHostString();
        if (auto found = key in args[0].tableValue)
        {
            return cast(Value) *found;
        }
        return Value.nullValue();
    });
    context.bindNative("rawset", (scope const(Value)[] args) {
        enforce(args.length == 3, "rawset(table, key, value) expects three arguments");
        enforce(args[0].kind == ValueKind.table, "rawset first argument must be table");
        auto table = cast(Value) args[0];
        auto key = (cast(Value) args[1]).toHostString();
        table.tableValue[key] = table.validateFieldAssignment(key, cast(Value) args[2]);
        return table;
    });
    context.bindNative("setmetatable", (scope const(Value)[] args) {
        enforce(args.length == 2, "setmetatable(table, meta) expects two arguments");
        enforce(args[0].kind == ValueKind.table, "setmetatable first argument must be table");
        enforce(args[1].kind == ValueKind.table || args[1].kind == ValueKind.null_,
            "setmetatable second argument must be table or null");
        auto table = cast(Value) args[0];
        if (args[1].kind == ValueKind.null_)
        {
            table.clearDeclaredMetatable();
            table.tableValue.remove("__meta");
        }
        else
        {
            table.clearDeclaredMetatable();
            table.tableValue["__meta"] = cast(Value) args[1];
        }
        return table;
    });
    context.bindNative("setmetatableWithType", (scope const(Value)[] args) {
        return context.setMetatableWithType(args);
    });
    context.bindNative("getmetatable", (scope const(Value)[] args) {
        enforce(args.length == 1, "getmetatable(table) expects one argument");
        enforce(args[0].kind == ValueKind.table || args[0].kind == ValueKind.struct_, "getmetatable argument must be table or struct");
        auto value=cast(Value)args[0];return value.effectiveMetatable();
    });
    context.bindNative("pcall", (scope const(Value)[] args) {
        enforce(args.length >= 1, "pcall(callback, ...) expects at least one argument");
        enforce(args[0].kind == ValueKind.function_, "pcall first argument must be function");
        try
        {
            Value[] callArgs;
            foreach (arg; args[1 .. $])
            {
                callArgs ~= cast(Value) arg;
            }
            auto result = context.invokeFunctionValue(cast(Value) args[0], callArgs);
            return Value.from([Value.from(true), result]);
        }
        catch (ExecutionLimitException error)
        {
            throw error;
        }
        catch (Exception error)
        {
            return Value.from([Value.from(false), Value.from(error.msg)]);
        }
    });
    context.bindNative("xpcall", (scope const(Value)[] args) {
        enforce(args.length >= 2, "xpcall(callback, errHandler, ...) expects at least two arguments");
        enforce(args[0].kind == ValueKind.function_, "xpcall first argument must be function");
        enforce(args[1].kind == ValueKind.function_, "xpcall second argument must be function");
        try
        {
            Value[] callArgs;
            foreach (arg; args[2 .. $])
            {
                callArgs ~= cast(Value) arg;
            }
            auto result = context.invokeFunctionValue(cast(Value) args[0], callArgs);
            return Value.from([Value.from(true), result]);
        }
        catch (ExecutionLimitException error)
        {
            throw error;
        }
        catch (Exception error)
        {
            auto handled = context.invokeFunctionValue(cast(Value) args[1], [Value.from(error.msg)]);
            return Value.from([Value.from(false), handled]);
        }
    });
    context.bindNative("map", (scope const(Value)[] args) {
        return context.mapValue(args);
    });
    context.bindNative("filter", (scope const(Value)[] args) {
        return context.filterValue(args);
    });

    context.bindFallback("sorted", Value.fromFunction(new NativeCallable("sorted", (scope const(Value)[] args) {
        enforce(args.length == 1 || args.length == 2, "sorted(array[, comparator]) expects one or two arguments");
        if (args.length == 2) enforce(args[1].kind == ValueKind.function_, "sorted comparator must be a function");
        return sortedValues(cast(Value) args[0], args.length == 2 ? cast(Value) args[1] : Value.init,
            context.invokeFunctionValue, context.step);
    })));

    context.bindFallback("reduce", Value.fromFunction(new NativeCallable("reduce", (scope const(Value)[] args) {
        enforce(args.length == 3, "reduce(array, initial, callback) expects three arguments");
        enforce(args[0].kind == ValueKind.array, "reduce first argument must be an array");
        enforce(args[2].kind == ValueKind.function_, "reduce callback must be a function");
        auto accumulator = (cast(Value) args[1]).valueCopy();
        auto callback = cast(Value) args[2];
        foreach (item; args[0].arrayValue)
        {
            context.step();
            accumulator = context.invokeFunctionValue(callback, [accumulator, cast(Value) item]);
        }
        return accumulator.valueCopy();
    })));

    // Known arities let UFCS read text.count and call text.charAt(index).
    context.bindFallback("count", Value.fromFunction(makeReflectedCallable("count", &countCodePoints)));
    context.bindFallback("charAt", Value.fromFunction(makeReflectedCallable("charAt", &codePointAt)));

    Value[string] stringLib;
    stringLib["len"] = Value.fromFunction(new NativeCallable("string.len", (scope const(Value)[] args) {
        return context.measureLengthValue(args);
    }));
    stringLib["upper"] = Value.fromFunction(new NativeCallable("string.upper", (scope const(Value)[] args) {
        enforce(args.length == 1, "string.upper(value) expects one argument");
        return Value.from(args[0].toHostString().toUpper().to!string);
    }));
    stringLib["lower"] = Value.fromFunction(new NativeCallable("string.lower", (scope const(Value)[] args) {
        enforce(args.length == 1, "string.lower(value) expects one argument");
        return Value.from(args[0].toHostString().toLower().to!string);
    }));
    stringLib["trim"] = Value.fromFunction(new NativeCallable("string.trim", (scope const(Value)[] args) {
        import std.string : strip;
        enforce(args.length == 1, "string.trim(value) expects one argument");
        return Value.from(args[0].toHostString().strip());
    }));
    stringLib["contains"] = Value.fromFunction(new NativeCallable("string.contains", (scope const(Value)[] args) {
        enforce(args.length == 2, "string.contains(value, needle) expects two arguments");
        return Value.from(args[0].toHostString().canFind(args[1].toHostString()));
    }));
    stringLib["replace"] = Value.fromFunction(new NativeCallable("string.replace", (scope const(Value)[] args) {
        enforce(args.length == 3, "string.replace(value, from, to) expects three arguments");
        return Value.from(args[0].toHostString().replace(args[1].toHostString(), args[2].toHostString()));
    }));
    stringLib["split"] = Value.fromFunction(new NativeCallable("string.split", (scope const(Value)[] args) {
        enforce(args.length == 2, "string.split(text, separator) expects two arguments");
        return splitText(cast(Value) args[0], cast(Value) args[1]);
    }));
    stringLib["join"] = Value.fromFunction(new NativeCallable("string.join", (scope const(Value)[] args) {
        enforce(args.length == 2, "string.join(parts, separator) expects two arguments");
        return joinText(cast(Value) args[0], cast(Value) args[1]);
    }));
    import dua.stdlib.formatting : formatDua;
    stringLib["format"] = Value.fromFunction(new NativeCallable("string.format", (scope const(Value)[] args) {
        enforce(args.length > 0 && args[0].kind == ValueKind.string_, "string.format requires a format string");
        return Value.from(formatDua(args[0].stringValue, args[1 .. $]));
    }));
    context.bind("string", Value.from(stringLib));

    Value[string] mathLib;
    mathLib["abs"] = Value.fromFunction(new NativeCallable("math.abs", (scope const(Value)[] args) {
        enforce(args.length == 1, "math.abs(value) expects one argument");
        auto value = args[0].toFloat();
        return Value.from(value < 0 ? -value : value);
    }));
    mathLib["floor"] = Value.fromFunction(new NativeCallable("math.floor", (scope const(Value)[] args) {
        enforce(args.length == 1, "math.floor(value) expects one argument");
        // Integers already are whole numbers; keep all 64 bits instead of
        // rounding through double (which loses precision above 2^53).
        if (args[0].kind == ValueKind.integer) return Value.from(args[0].integerValue);
        auto rounded = floor(args[0].toFloat());
        // long.max rounds up when represented as double; use an exclusive 2^63
        // upper bound so a host floating-to-integer cast never overflows.
        enforce(rounded.isFinite && rounded >= cast(double) long.min
            && rounded < -cast(double) long.min,
            "math.floor result is outside the integer range");
        return Value.from(cast(long) rounded);
    }));
    mathLib["min"] = Value.fromFunction(new NativeCallable("math.min", (scope const(Value)[] args) {
        enforce(args.length >= 1, "math.min(value, ...) expects at least one argument");
        double minimum = args[0].toFloat();
        foreach (arg; args[1 .. $])
        {
            auto candidate = arg.toFloat();
            if (candidate < minimum)
            {
                minimum = candidate;
            }
        }
        return Value.from(minimum);
    }));
    mathLib["max"] = Value.fromFunction(new NativeCallable("math.max", (scope const(Value)[] args) {
        enforce(args.length >= 1, "math.max(value, ...) expects at least one argument");
        double maximum = args[0].toFloat();
        foreach (arg; args[1 .. $])
        {
            auto candidate = arg.toFloat();
            if (candidate > maximum)
            {
                maximum = candidate;
            }
        }
        return Value.from(maximum);
    }));
    import dua.stdlib.mathematics : extendedMathFunctions;
    foreach (name, value; extendedMathFunctions()) mathLib[name] = value;
    context.bind("math", Value.from(mathLib));

    Value[string] tableLib;
    tableLib["len"] = Value.fromFunction(new NativeCallable("table.len", (scope const(Value)[] args) {
        return context.measureLengthValue(args);
    }));
    tableLib["length"] = tableLib["len"];
    tableLib["keys"] = Value.fromFunction(new NativeCallable("table.keys", (scope const(Value)[] args) {
        enforce(args.length == 1, "table.keys(value) expects one argument");
        enforce(args[0].kind == ValueKind.table, "table.keys supports table values only");
        Value[] keys;
        foreach (key; args[0].tableValue.keys)
        {
            keys ~= context.tableKeyToScriptValue(key);
        }
        return Value.from(keys);
    }));
    tableLib["map"] = Value.fromFunction(new NativeCallable("table.map", (scope const(Value)[] args) {
        return context.mapValue(args);
    }));
    tableLib["filter"] = Value.fromFunction(new NativeCallable("table.filter", (scope const(Value)[] args) {
        return context.filterValue(args);
    }));
    context.bind("table", Value.from(tableLib));

    Value[string] ioLib;
    ioLib["exists"] = Value.fromFunction(new NativeCallable("io.exists", (scope const(Value)[] args) {
        enforce(args.length == 1, "io.exists(path) expects one argument");
        return Value.from(exists(args[0].toHostString()));
    }));
    ioLib["readFile"] = Value.fromFunction(new NativeCallable("io.readFile", (scope const(Value)[] args) {
        enforce(args.length == 1, "io.readFile(path) expects one argument");
        auto path = args[0].toHostString();
        enforce(exists(path), format("File not found: %s", path));
        return Value.from(readText(path));
    }));
    context.bind("io", Value.from(ioLib));

    Value[string] osLib;
    osLib["clock"] = Value.fromFunction(new NativeCallable("os.clock", (scope const(Value)[] args) {
        enforce(args.length == 0, "os.clock() takes no arguments");
        return Value.from(Clock.currTime.toUnixTime());
    }));
    osLib["getenv"] = Value.fromFunction(new NativeCallable("os.getenv", (scope const(Value)[] args) {
        import std.process : environment;
        enforce(args.length == 1, "os.getenv(name) expects one argument");
        auto name = args[0].toHostString();
        return Value.from(environment.get(name, ""));
    }));
    context.bind("os", Value.from(osLib));

    Value[string] utf8Lib;
    utf8Lib["len"] = Value.fromFunction(new NativeCallable("utf8.len", (scope const(Value)[] args) {
        enforce(args.length == 1, "utf8.len(value) expects one argument");
        long count = 0;
        foreach (_; byDchar(args[0].toHostString()))
        {
            ++count;
        }
        return Value.from(count);
    }));
    utf8Lib["chars"] = Value.fromFunction(new NativeCallable("utf8.chars", (scope const(Value)[] args) {
        enforce(args.length == 1 && args[0].kind == ValueKind.string_, "utf8.chars(text) expects one string");
        Value[] characters;
        foreach (character; byDchar(args[0].stringValue))
        {
            context.step();
            characters ~= Value.from(character.to!string);
        }
        return Value.fromOwnedArray(characters, "string");
    }));
    context.bind("utf8", Value.from(utf8Lib));

    Value[string] debugLib;
    debugLib["type"] = Value.fromFunction(new NativeCallable("debug.type", (scope const(Value)[] args) {
        enforce(args.length == 1, "debug.type(value) expects one argument");
        return Value.from(args[0].kind.to!string);
    }));
    debugLib["traceback"] = Value.fromFunction(new NativeCallable("debug.traceback", (scope const(Value)[] args) {
        enforce(args.length == 0, "debug.traceback() takes no arguments");
        return Value.from(context.traceback());
    }));
    context.bind("debug", Value.from(debugLib));

    Value[string] timeLib;
    timeLib["nowUnix"] = Value.fromFunction(new NativeCallable("time.nowUnix", (scope const(Value)[] args) {
        enforce(args.length == 0, "time.nowUnix() takes no arguments");
        import core.stdc.time : time;
        return Value.from(cast(long) time(null));
    }));
    context.bind("time", Value.from(timeLib));

    Value[string] jsonLib;
    jsonLib["encode"] = Value.fromFunction(new NativeCallable("json.encode", (scope const(Value)[] args) {
        enforce(args.length == 1, "json.encode(value) expects one argument");
        return Value.from(encodeJson(args[0]));
    }));
    jsonLib["decode"] = Value.fromFunction(new NativeCallable("json.decode", (scope const(Value)[] args) {
        enforce(args.length == 1, "json.decode(text) expects one argument");
        enforce(args[0].kind == ValueKind.string_, "json.decode expects a string");
        return decodeJson(args[0].stringValue);
    }));
    context.bind("json", Value.from(jsonLib));
    context.bind("_ENV", Value.fromFunction(new NativeCallable("_ENV", (scope const(Value)[] args) {
        enforce(args.length == 1, "_ENV(name) expects one argument");
        return context.getGlobal(args[0].toHostString());
    })));
}
