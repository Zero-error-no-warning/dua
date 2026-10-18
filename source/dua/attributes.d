module dua.attributes;

/// Exclude a D function, method or constructor from Dua's automatic bindings.
/// Explicit declaration-based bindFunc registration rejects marked overload sets.
/// Converting a declaration to a function pointer/delegate erases its UDAs.
struct NoBind {}

package(dua) template isNoBind(alias declaration)
{
    import std.traits : hasUDA;
    static if (__traits(compiles, __traits(getAttributes, declaration)))
        enum isNoBind = hasUDA!(declaration, NoBind);
    else
        enum isNoBind = false;
}

package(dua) template hasNoBindOverload(T, string name)
{
    enum hasNoBindOverload = () {
        static if (__traits(compiles, __traits(getOverloads, T, name, true)))
            static foreach (declaration; __traits(getOverloads, T, name, true))
                static if (isNoBind!declaration) return true;
        return false;
    }();
}
