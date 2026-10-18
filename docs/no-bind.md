# Excluding native declarations with `@NoBind`

```d
import dua;
struct Font {
    @NoBind static void initialize() { /* host lifecycle */ }
    static Font Gui() { return Font.init; }
}
engine.bindType!Font("Font");
```

`@NoBind` keeps a D function, method or constructor available to D while excluding
that declaration from automatic `bindType`, reflected values and completion
signatures. This includes inherited methods, lazy struct/class reflection and
forwarding through `alias this`. A marked alias-this accessor is not forwarded.
Mark declarations individually; this attribute is not a type or field policy.

Automatic ordinary method/function overload sets retain unmarked declarations.
Native method invocation uses the selected declaration, including its defaults,
rather than resolving its name again. Native constructors require a D constructor
expression that performs overload resolution again. Therefore if any constructor
is marked, the whole constructor set is excluded (including class default/table
construction). Struct `.init`/table initialization remains available and invokes
no constructor. Operator forwarding that cannot select an individual declaration
conservatively suppresses the corresponding name if any overload is marked.

Explicit `bindFunc!declaration` rejects the entire selected overload set with an
exception at registration if any member has `@NoBind`; it creates neither a
partial binding nor completion metadata. Callable aggregates passed to runtime
`bindFunc` are likewise rejected if their `opCall` set contains a marked member.

D erases declaration UDAs when a function is converted to a function pointer or
delegate. The runtime `bindFunc(name, pointerOrDelegate)` form cannot recover that
information. A caller can also deliberately expose a new wrapper that invokes a
marked method. Public virtual dispatch can reach an overriding implementation.
`@NoBind` controls declaration exposure; it is not an execution/security boundary.
