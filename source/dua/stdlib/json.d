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
    // 型付き連想配列はnull handleでもJSON未対応です。通常配列のnullは維持します。
    if (value.isNullContainer && value.kind != ValueKind.associativeArray) return JSONValue(null);
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
            items.length = value.arrayValue.length;
            foreach (index, item; value.arrayValue)
                items[index] = toJsonValue(item);
            return JSONValue(items);
        case ValueKind.table:
        case ValueKind.struct_:
            JSONValue[string] object;
            foreach (key, item; value.tableValue)
                object[key] = toJsonValue(item);
            return JSONValue(object);
        case ValueKind.function_:
        case ValueKind.native:
        case ValueKind.associativeArray:
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

unittest
{
    import std.exception : assertThrown;
    foreach (value; [Value.nullAssociativeArray("int", "int"), Value.associativeArray("int", "int")])
    {
        assertThrown!Exception(encodeJson(value));
        assertThrown!Exception(encodeJson(Value.from([value])));
    }
    assert(encodeJson(Value.init) == "null");
    assert(encodeJson(Value.nullArray("int")) == "null");
}
