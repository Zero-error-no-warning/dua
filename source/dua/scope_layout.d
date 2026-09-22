module dua.scope_layout;

// Layouts contain names only, never values or captured frames. They are shared
// by executions of a syntax node and stay fixed after construction.
package(dua) final class ScopeLayout
{
    private size_t[string] indices;
    private size_t count;

    this(string[] names)
    {
        foreach (name; names)
            if ((name in indices) is null) indices[name] = count++;
    }

    size_t length() const { return count; }

    size_t find(string name) const
    {
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
