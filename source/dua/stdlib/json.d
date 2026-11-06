module dua.stdlib.json;

import dua.value : Value, ValueKind;
import std.exception : enforce;
import std.json : JSONValue, JSONType, JSONOptions, parseJSON;
import std.math : isFinite;

/// Encode a Dua value as standards-compliant JSON.
string encodeJson(const Value value)
{
    const(Value)[] ancestors;
    return toJsonValue(value, ancestors).toString();
}

/// Decode one strict JSON value. Integer tokens retain signed 64-bit precision.
Value decodeJson(string source)
{
    return fromJsonValue(parseJSON(source, -1, JSONOptions.strictParsing));
}

private Value fromJsonValue(const JSONValue value)
{
    final switch (value.type)
    {
        case JSONType.null_: return Value.nullValue();
        case JSONType.true_: return Value.from(true);
        case JSONType.false_: return Value.from(false);
        case JSONType.string: return Value.from(value.str);
        case JSONType.integer: return Value.from(value.integer);
        case JSONType.uinteger:
            enforce(value.uinteger <= long.max, "json.decode integer is outside the signed 64-bit range");
            return Value.from(cast(long) value.uinteger);
        case JSONType.float_:
            enforce(value.floating.isFinite, "json.decode cannot decode a non-finite number");
            return Value.from(value.floating);
        case JSONType.array:
            Value[] items;
            items.length = value.array.length;
            foreach (index, item; value.array) items[index] = fromJsonValue(item);
            return Value.fromOwnedArray(items);
        case JSONType.object:
            Value[string] items;
            foreach (name, item; value.object) items[name] = fromJsonValue(item);
            return Value.from(items);
    }
}

private JSONValue toJsonValue(const Value value, ref const(Value)[] ancestors)
{
    // 型付き連想配列はnull handleでもJSON未対応です。通常配列のnullは維持します。
    if (value.isNullContainer && value.kind != ValueKind.associativeArray) return JSONValue(null);
    // Track the current ancestry, not all visited values: shared acyclic values
    // are valid JSON. Do not introduce a new limit on existing acyclic input.
    bool container = value.kind == ValueKind.array || value.kind == ValueKind.table
        || value.kind == ValueKind.struct_;
    if (container)
    {
        foreach (ancestor; ancestors)
        {
            bool same = value.kind == ValueKind.array
                ? ancestor.kind == ValueKind.array
                    && value.arrayValue.ptr is ancestor.arrayValue.ptr
                    && value.arrayValue.length == ancestor.arrayValue.length
                : (ancestor.kind == ValueKind.table || ancestor.kind == ValueKind.struct_)
                    && value.tableValue is ancestor.tableValue;
            enforce(!same, "json.encode cannot encode a cyclic value");
        }
        ancestors ~= value;
    }
    scope(exit) if (container) ancestors = ancestors[0 .. $ - 1];
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
                items[index] = toJsonValue(item, ancestors);
            return JSONValue(items);
        case ValueKind.table:
        case ValueKind.struct_:
            JSONValue[string] object;
            foreach (key, item; value.tableValue)
                object[key] = toJsonValue(item, ancestors);
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

unittest
{
    import std.exception : assertThrown;
    import std.json : parseJSON;
    auto table = Value.from(["value": Value.from(1)]);
    table.tableValue["self"] = table;
    assertThrown!Exception(encodeJson(table));

    table.tableValue.remove("self");
    auto repeated = Value.from([table, table]);
    assert(parseJSON(encodeJson(repeated)).array.length == 2);

    auto array = Value.from([Value.init]);
    array.arrayValue[0] = array;
    assertThrown!Exception(encodeJson(array));
    table.tableValue["array"] = array;
    array.arrayValue[0] = table;
    assertThrown!Exception(encodeJson(table));

    auto deep = Value.from(0);
    foreach (_; 0 .. 256) deep = Value.from([deep]);
    assert(encodeJson(deep).length == 513);
    deep = Value.from([deep]);
    assert(encodeJson(deep).length == 515);
    assert(encodeJson(Value.from(42)) == "42");
}
