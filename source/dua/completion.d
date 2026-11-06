module dua.completion;

import dua.value;
import std.json;
import std.algorithm : startsWith;
import std.traits : isAggregateType;

/// Opt-in descriptions of host registrations. Never calls a host function/getter.
final class CompletionRegistry
{
    private JSONValue[string] symbols;
    private JSONValue[string] types;
    private JSONValue[][CallableValue] signatures;
    private JSONValue[string] pending;

    void registerType(T)()
    {
        static if (isAggregateType!T && !is(T == Value))
        {
            enum name = hostReflectedTypeName!T;
            if (name !in types) types[name] = describeHostCompletionType!T();
        }
    }

    void overload(alias declaration)(string path)
    {
        auto entry = pending.get(path, JSONValue(["kind": JSONValue("function")]));
        auto values = "signatures" in entry.object ? entry["signatures"].array : null;
        values ~= hostCompletionSignature!declaration();
        entry["signatures"] = JSONValue(values);
        pending[path] = entry;
    }

    package(dua) void discardPending(string path)
    {
        pending.remove(path);
    }

    void typed(T)(string path)
    {
        auto entry = symbols.get(path, JSONValue(["kind": JSONValue("variable")]));
        entry["type"] = JSONValue(hostCompletionName!T);
        symbols[path] = entry;
    }

    void typeBinding(T)(string path, Value value)
    {
        registerType!T();
        auto entry = symbols[path];
        entry["kind"] = JSONValue("type");
        entry["type"] = JSONValue(hostReflectedTypeName!T);
        entry["signatures"] = types[hostReflectedTypeName!T]["constructors"];
        symbols[path] = entry;
        foreach (name, member; value.tableValue)
            if (!name.startsWith("__")) this.value(path ~ "." ~ name, member);
        foreach (name, member; types[hostReflectedTypeName!T]["members"].object)
            if ("static" in member.object && member["static"].boolean)
                description(path ~ "." ~ name, member);
        symbols[path ~ ".new"] = JSONValue(["kind": JSONValue("function"),
            "signatures": types[hostReflectedTypeName!T]["constructors"]]);
    }

    private void description(string path, JSONValue entry)
    {
        symbols[path] = entry;
        if ("members" in entry.object)
            foreach (name, member; entry["members"].object) description(path ~ "." ~ name, member);
    }

    void value(string path, Value value, size_t depth = 0)
    {
        // Metadata and bridge-only bindings must never become user suggestions.
        auto entry = pending.get(path, JSONValue(["kind": JSONValue("variable")]));
        pending.remove(path);
        foreach (key; symbols.keys) if (key.startsWith(path ~ ".")) symbols.remove(key);
        if (value.kind == ValueKind.function_)
        {
            entry["kind"] = JSONValue("function");
            if ("signatures" in entry.object)
                signatures[value.functionValue] = entry["signatures"].array;
            else if (auto known = value.functionValue in signatures)
                entry["signatures"] = JSONValue(*known);
        }
        else if (value.typeChain.length)
            entry["type"] = JSONValue(value.typeChain[0].toHostString());
        else
        {
            switch (value.kind)
            {
                case ValueKind.integer: entry["type"] = JSONValue("int"); break;
                case ValueKind.floating: entry["type"] = JSONValue("double"); break;
                case ValueKind.boolean: entry["type"] = JSONValue("bool"); break;
                case ValueKind.string_: entry["type"] = JSONValue("string"); break;
                default: break;
            }
        }
        symbols[path] = entry;
        // Plain module/enum tables only; reflected fields are described by type.
        if (value.kind == ValueKind.table && !value.typeChain.length && depth < 4)
            foreach (name, child; value.tableValue)
                this.value(path ~ "." ~ name, child, depth + 1);
    }

    JSONValue toJson()
    {
        JSONValue[string] visible;
        foreach (path, entry; symbols)
        {
            bool hidden;
            foreach (piece; splitPath(path)) if (piece.startsWith("__")) hidden = true;
            if (!hidden) visible[path] = copyMetadata(entry);
        }
        return JSONValue(["schemaVersion": JSONValue(1),
            "symbols": JSONValue(visible), "types": copyMetadata(JSONValue(types))]);
    }

    // JSONValue copies share arrays and objects. Export a recursively detached
    // snapshot so editor consumers cannot alter the registry or other exports.
    private JSONValue copyMetadata(JSONValue value)
    {
        if (value.type == JSONType.object)
        {
            JSONValue[string] result;
            foreach (key, child; value.object) result[key] = copyMetadata(child);
            return JSONValue(result);
        }
        if (value.type == JSONType.array)
        {
            JSONValue[] result;
            foreach (child; value.array) result ~= copyMetadata(child);
            return JSONValue(result);
        }
        return value;
    }

    private string[] splitPath(string path)
    {
        import std.array : split;
        return path.split(".");
    }
}
