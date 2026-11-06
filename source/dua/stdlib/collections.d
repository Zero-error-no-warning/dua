module dua.stdlib.collections;
import dua.value : Value, ValueKind;
import std.exception : enforce;
import std.math : isFinite;

package(dua) Value sortedValues(Value collection, Value comparator,
    Value delegate(Value, Value[]) invoke, void delegate() step)
{
    enforce(collection.kind == ValueKind.array, "sorted expects an array");
    bool custom = comparator.kind != ValueKind.null_;
    enforce(!custom || comparator.kind == ValueKind.function_, "sorted comparator must be a function");
    auto values = collection.arrayValue.dup;
    if (!custom)
        foreach (value; values)
        {
            enforce(value.kind == ValueKind.integer || value.kind == ValueKind.floating
                || value.kind == ValueKind.string_, "sorted needs a comparator for this element type");
            enforce(value.kind == values[0].kind, "sorted default ordering requires elements of the same kind");
            if (value.kind == ValueKind.floating)
                enforce(value.floatingValue.isFinite, "sorted default ordering requires finite numbers");
        }
    bool less(Value left, Value right)
    {
        step();
        if (custom)
        {
            auto result = invoke(comparator, [left, right]);
            enforce(result.kind == ValueKind.boolean, "sorted comparator must return bool");
            return result.booleanValue;
        }
        if (left.kind == ValueKind.integer) return left.integerValue < right.integerValue;
        if (left.kind == ValueKind.floating) return left.floatingValue < right.floatingValue;
        return left.stringValue < right.stringValue;
    }
    Value[] scratch;
    scratch.length = values.length;
    void merge(size_t start, size_t end)
    {
        if (end - start < 2) return;
        auto middle = start + (end - start) / 2;
        merge(start, middle); merge(middle, end);
        size_t left = start, right = middle;
        foreach (position; start .. end)
        {
            // Prefer the left element for equivalent keys to retain stability.
            if (right == end || (left < middle && !less(values[right], values[left])))
                scratch[position] = values[left++];
            else scratch[position] = values[right++];
        }
        values[start .. end] = scratch[start .. end];
    }
    merge(0, values.length);
    if (collection.isNullContainer) return collection.valueCopy();
    auto result = Value.fromOwnedArray(values, collection.arrayElementType);
    result.arrayDefaultType = collection.arrayDefaultType;
    result.arrayUnionType = collection.arrayUnionType;
    return result;
}
