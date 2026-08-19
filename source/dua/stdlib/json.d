module dua.stdlib.json;

import dua.value : Value, ValueKind;
import std.exception : enforce;
import std.json : JSONValue;
import std.math : isFinite;

/// Encode a Dua value as standards-compliant JSON.
string encodeJson(const Value value)
{
    return toJsonValue(value).toString();
}

private JSONValue toJsonValue(const Value value)
{
    final switch (value.kind)
    {
        case ValueKind.null_:
            return JSONValue(null);
        case ValueKind.integer:
            return JSONValue(value.integerValue);
        case ValueKind.floating:
            enforce(value.floatingValue.isFinite, "json.encode cannot encode a non-finite number");
            return JSONValue(value.floatingValue);
        case ValueKind.boolean:
            return JSONValue(value.booleanValue);
        case ValueKind.string_:
            return JSONValue(value.stringValue);
        case ValueKind.array:
            JSONValue[] items;
            foreach (item; value.arrayValue)
                items ~= toJsonValue(item);
            return JSONValue(items);
        case ValueKind.table:
        case ValueKind.struct_:
            JSONValue[string] object;
            foreach (key, item; value.tableValue)
                object[key] = toJsonValue(item);
            return JSONValue(object);
        case ValueKind.function_:
        case ValueKind.native:
            enforce(false, "json.encode cannot encode " ~ value.kind.stringof);
            assert(0);
    }
}

unittest
{
    Value[string] object;
    object["message"] = Value.from("line\n\"quoted\"");
    object["enabled"] = Value.from(true);
    assert(encodeJson(Value.from(object)) ==
        `{"enabled":true,"message":"line\n\"quoted\""}`);
}
