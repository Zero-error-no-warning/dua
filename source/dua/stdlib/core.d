module dua.stdlib.core;

import dua.evaluator : ScriptThrownException;
import dua.stdlib.json : encodeJson;
import dua.value : CallableValue, Value, ValueKind;
import std.algorithm : canFind;
import std.conv : to;
import std.datetime.systime : Clock;
import std.exception : enforce;
import std.file : exists, readText;
import std.format : format;
import std.math : floor;
import std.string : replace;
import std.uni : toLower, toUpper;
import std.utf : byDchar;

alias StdlibNativeFunction = Value delegate(scope const(Value)[] args);

/// Narrow internal bridge between the standard library and the execution engine.
package(dua) struct StdlibContext
{
    void delegate(string, StdlibNativeFunction) bindNative;
    void delegate(string, Value) bind;
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

private final class StdlibCallable : CallableValue
{
    private StdlibNativeFunction callback;

    this(string name, StdlibNativeFunction callback)
    {
        super(name);
        this.callback = callback;
    }

    override Value invoke(Value[] args)
    {
        return callback(args);
    }
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
        table.tableValue[(cast(Value) args[1]).toHostString()] = cast(Value) args[2];
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
            table.tableValue.remove("__meta");
        }
        else
        {
            table.tableValue["__meta"] = cast(Value) args[1];
        }
        return table;
    });
    context.bindNative("setmetatableWithType", (scope const(Value)[] args) {
        return context.setMetatableWithType(args);
    });
    context.bindNative("getmetatable", (scope const(Value)[] args) {
        enforce(args.length == 1, "getmetatable(table) expects one argument");
        enforce(args[0].kind == ValueKind.table, "getmetatable argument must be table");
        if (auto meta = "__meta" in args[0].tableValue)
        {
            return cast(Value) *meta;
        }
        return Value.nullValue();
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

    Value[string] stringLib;
    stringLib["len"] = Value.fromFunction(new StdlibCallable("string.len", (scope const(Value)[] args) {
        return context.measureLengthValue(args);
    }));
    stringLib["upper"] = Value.fromFunction(new StdlibCallable("string.upper", (scope const(Value)[] args) {
        enforce(args.length == 1, "string.upper(value) expects one argument");
        return Value.from(args[0].toHostString().toUpper().to!string);
    }));
    stringLib["lower"] = Value.fromFunction(new StdlibCallable("string.lower", (scope const(Value)[] args) {
        enforce(args.length == 1, "string.lower(value) expects one argument");
        return Value.from(args[0].toHostString().toLower().to!string);
    }));
    stringLib["trim"] = Value.fromFunction(new StdlibCallable("string.trim", (scope const(Value)[] args) {
        import std.string : strip;
        enforce(args.length == 1, "string.trim(value) expects one argument");
        return Value.from(args[0].toHostString().strip());
    }));
    stringLib["contains"] = Value.fromFunction(new StdlibCallable("string.contains", (scope const(Value)[] args) {
        enforce(args.length == 2, "string.contains(value, needle) expects two arguments");
        return Value.from(args[0].toHostString().canFind(args[1].toHostString()));
    }));
    stringLib["replace"] = Value.fromFunction(new StdlibCallable("string.replace", (scope const(Value)[] args) {
        enforce(args.length == 3, "string.replace(value, from, to) expects three arguments");
        return Value.from(args[0].toHostString().replace(args[1].toHostString(), args[2].toHostString()));
    }));
    context.bind("string", Value.from(stringLib));

    Value[string] mathLib;
    mathLib["abs"] = Value.fromFunction(new StdlibCallable("math.abs", (scope const(Value)[] args) {
        enforce(args.length == 1, "math.abs(value) expects one argument");
        auto value = args[0].toFloat();
        return Value.from(value < 0 ? -value : value);
    }));
    mathLib["floor"] = Value.fromFunction(new StdlibCallable("math.floor", (scope const(Value)[] args) {
        enforce(args.length == 1, "math.floor(value) expects one argument");
        return Value.from(cast(long) floor(args[0].toFloat()));
    }));
    mathLib["min"] = Value.fromFunction(new StdlibCallable("math.min", (scope const(Value)[] args) {
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
    mathLib["max"] = Value.fromFunction(new StdlibCallable("math.max", (scope const(Value)[] args) {
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
    context.bind("math", Value.from(mathLib));

    Value[string] tableLib;
    tableLib["len"] = Value.fromFunction(new StdlibCallable("table.len", (scope const(Value)[] args) {
        return context.measureLengthValue(args);
    }));
    tableLib["length"] = tableLib["len"];
    tableLib["keys"] = Value.fromFunction(new StdlibCallable("table.keys", (scope const(Value)[] args) {
        enforce(args.length == 1, "table.keys(value) expects one argument");
        enforce(args[0].kind == ValueKind.table, "table.keys supports table values only");
        Value[] keys;
        foreach (key; args[0].tableValue.keys)
        {
            keys ~= context.tableKeyToScriptValue(key);
        }
        return Value.from(keys);
    }));
    tableLib["map"] = Value.fromFunction(new StdlibCallable("table.map", (scope const(Value)[] args) {
        return context.mapValue(args);
    }));
    tableLib["filter"] = Value.fromFunction(new StdlibCallable("table.filter", (scope const(Value)[] args) {
        return context.filterValue(args);
    }));
    context.bind("table", Value.from(tableLib));

    Value[string] ioLib;
    ioLib["exists"] = Value.fromFunction(new StdlibCallable("io.exists", (scope const(Value)[] args) {
        enforce(args.length == 1, "io.exists(path) expects one argument");
        return Value.from(exists(args[0].toHostString()));
    }));
    ioLib["readFile"] = Value.fromFunction(new StdlibCallable("io.readFile", (scope const(Value)[] args) {
        enforce(args.length == 1, "io.readFile(path) expects one argument");
        auto path = args[0].toHostString();
        enforce(exists(path), format("File not found: %s", path));
        return Value.from(readText(path));
    }));
    context.bind("io", Value.from(ioLib));

    Value[string] osLib;
    osLib["clock"] = Value.fromFunction(new StdlibCallable("os.clock", (scope const(Value)[] args) {
        enforce(args.length == 0, "os.clock() takes no arguments");
        return Value.from(Clock.currTime.toUnixTime());
    }));
    osLib["getenv"] = Value.fromFunction(new StdlibCallable("os.getenv", (scope const(Value)[] args) {
        import std.process : environment;
        enforce(args.length == 1, "os.getenv(name) expects one argument");
        auto name = args[0].toHostString();
        return Value.from(environment.get(name, ""));
    }));
    context.bind("os", Value.from(osLib));

    Value[string] utf8Lib;
    utf8Lib["len"] = Value.fromFunction(new StdlibCallable("utf8.len", (scope const(Value)[] args) {
        enforce(args.length == 1, "utf8.len(value) expects one argument");
        long count = 0;
        foreach (_; byDchar(args[0].toHostString()))
        {
            ++count;
        }
        return Value.from(count);
    }));
    context.bind("utf8", Value.from(utf8Lib));

    Value[string] debugLib;
    debugLib["type"] = Value.fromFunction(new StdlibCallable("debug.type", (scope const(Value)[] args) {
        enforce(args.length == 1, "debug.type(value) expects one argument");
        return Value.from(args[0].kind.to!string);
    }));
    debugLib["traceback"] = Value.fromFunction(new StdlibCallable("debug.traceback", (scope const(Value)[] args) {
        enforce(args.length == 0, "debug.traceback() takes no arguments");
        return Value.from(context.traceback());
    }));
    context.bind("debug", Value.from(debugLib));

    Value[string] timeLib;
    timeLib["nowUnix"] = Value.fromFunction(new StdlibCallable("time.nowUnix", (scope const(Value)[] args) {
        enforce(args.length == 0, "time.nowUnix() takes no arguments");
        import core.stdc.time : time;
        return Value.from(cast(long) time(null));
    }));
    context.bind("time", Value.from(timeLib));

    Value[string] jsonLib;
    jsonLib["encode"] = Value.fromFunction(new StdlibCallable("json.encode", (scope const(Value)[] args) {
        enforce(args.length == 1, "json.encode(value) expects one argument");
        return Value.from(encodeJson(args[0]));
    }));
    context.bind("json", Value.from(jsonLib));
    context.bind("_ENV", Value.fromFunction(new StdlibCallable("_ENV", (scope const(Value)[] args) {
        enforce(args.length == 1, "_ENV(name) expects one argument");
        return context.getGlobal(args[0].toHostString());
    })));
}
