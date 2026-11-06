module dua.stdlib.unicode;

import dua.value : Value, ValueKind;
import std.algorithm.searching : count;
import std.conv : to;
import std.exception : enforce;
import std.utf : byDchar;

// These wrappers intentionally follow Phobos' default decoding/replacement
// semantics. They do not change the byte representation of the source string.
package(dua) long countCodePoints(Value text)
{
    enforce(text.kind == ValueKind.string_, "count expects a string");
    return cast(long) count(text.stringValue);
}

package(dua) string codePointAt(Value text, Value index)
{
    enforce(text.kind == ValueKind.string_, "charAt expects a string");
    enforce(index.kind == ValueKind.integer || index.kind == ValueKind.boolean,
        "charAt index expects an integer");
    auto position = index.kind == ValueKind.boolean ? cast(long) index.booleanValue : index.toInt();
    enforce(position >= 0, "charAt index out of range");
    auto cursor = text.stringValue.byDchar;
    for (long i = 0; i < position && !cursor.empty; ++i) cursor.popFront();
    enforce(!cursor.empty, "charAt index out of range");
    return cursor.front.to!string;
}
