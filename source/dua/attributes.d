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

// Callable aggregates can inherit opCall through alias this. Inspect the path
// without invoking accessors; their UDAs still exist at registration time.
package(dua) template hasNoBindCallablePath(T, Seen...)
{
    import std.meta : staticIndexOf;
    import std.traits : BaseClassesTuple, isAggregateType, isCallable, ReturnType, Unqual;
    alias Current = Unqual!T;
    static if (!isAggregateType!Current || staticIndexOf!(Current, Seen) >= 0)
        enum hasNoBindCallablePath = false;
    else static if (hasNoBindOverload!(Current, "opCall"))
        enum hasNoBindCallablePath = true;
    else static if (staticIndexOf!("opCall", __traits(allMembers, Current)) >= 0)
        // A direct/inherited opCall does not traverse an unrelated alias this.
        enum hasNoBindCallablePath = false;
    else static if (__traits(getAliasThis, Current).length)
    {
        enum name = __traits(getAliasThis, Current)[0];
        static if (hasNoBindOverload!(Current, name))
            enum hasNoBindCallablePath = true;
        else
        {
            alias Member = typeof(__traits(getMember, *cast(Current*) null, name));
            static if (__traits(compiles, __traits(getOverloads, Current, name))
                && __traits(getOverloads, Current, name).length > 0
                && isCallable!Member && !isAggregateType!Member)
                alias Target = ReturnType!Member;
            else
                alias Target = Member;
            enum hasNoBindCallablePath = hasNoBindCallablePath!(Target, Seen, Current);
        }
    }
    else static if (is(Current == class) && BaseClassesTuple!Current.length > 0)
        // getAliasThis only reports aliases declared on this class, while D
        // callability also inherits an alias declared by a base class.
        // Visit the immediate base only: its alias may shadow an ancestor's.
        enum hasNoBindCallablePath = hasNoBindCallablePath!(
            BaseClassesTuple!Current[0], Seen, Current);
    else
        enum hasNoBindCallablePath = false;
}
