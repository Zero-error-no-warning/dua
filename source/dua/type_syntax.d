module dua.type_syntax;

/// Split the outermost V[K] (or V[]) suffix, preserving nested type names.
package(dua) bool splitContainerType(string name, out string element, out string key)
{
    if (name.length == 0 || name[$ - 1] != ']') return false;
    size_t depth;
    foreach_reverse (index, ch; name)
    {
        if (ch == ']') ++depth;
        else if (ch == '[' && --depth == 0)
        {
            if (index == 0) return false;
            element = name[0 .. index];
            key = name[index + 1 .. $ - 1];
            return true;
        }
    }
    return false;
}
