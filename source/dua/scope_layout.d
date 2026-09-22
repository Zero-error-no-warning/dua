module dua.scope_layout;

// Layouts contain names only, never values or captured frames. They are shared
// by executions of a syntax node and stay fixed after construction.
package(dua) final class ScopeLayout
{
    private size_t[string] indices;
    private size_t count;
    private string[] smallNames;

    this(string[] names)
    {
        // Most scopes contain only a handful of names. Avoid constructing a
        // hash table for them; hot variable reads already use cached indices.
        if (names.length <= 4)
        {
            smallNames = names.dup;
            count = names.length;
            return;
        }
        foreach (name; names)
            if ((name in indices) is null) indices[name] = count++;
    }

    size_t length() const { return count; }

    size_t find(string name) const
    {
        foreach (slot, candidate; smallNames)
            if (candidate == name) return slot;
        if (auto slot = name in indices) return *slot;
        return size_t.max;
    }
}

// A guarded path, not a captured binding: closures with the same syntax can
// have different frames, and an inactive slot may become defined later.
package(dua) struct VariableSlots
{
    struct Step
    {
        ScopeLayout layout;
        size_t slot;
    }
    string name;
    Step[] steps;
}
