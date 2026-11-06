module dua.stdlib.text;
import dua.value : Value, ValueKind;
import std.exception : enforce;
import std.string : indexOf;
import std.array : appender;

package(dua) Value splitText(Value text, Value separator)
{
    enforce(text.kind == ValueKind.string_ && separator.kind == ValueKind.string_,
        "string.split expects a string and a string separator");
    enforce(separator.stringValue.length != 0, "string.split separator must not be empty");
    Value[] parts;
    size_t start;
    while (true)
    {
        auto offset = text.stringValue[start .. $].indexOf(separator.stringValue);
        if (offset < 0) break;
        auto end = start + cast(size_t) offset;
        parts ~= Value.from(text.stringValue[start .. end]);
        start = end + separator.stringValue.length;
    }
    parts ~= Value.from(text.stringValue[start .. $]);
    return Value.fromOwnedArray(parts, "string");
}

package(dua) Value joinText(Value parts, Value separator)
{
    enforce(parts.kind == ValueKind.array && separator.kind == ValueKind.string_,
        "string.join expects an array of strings and a string separator");
    auto result = appender!string();
    foreach (index, part; parts.arrayValue)
    {
        enforce(part.kind == ValueKind.string_, "string.join array elements must be strings");
        if (index) result.put(separator.stringValue);
        result.put(part.stringValue);
    }
    return Value.from(result.data);
}
