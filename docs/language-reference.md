# Dua language reference (value structs)

Dua supports native value aggregates alongside its existing reference tables:

```dua
struct Vec2 {
    double x;
    double y;
}

Vec2 a = Vec2(1.0, 2.0);
Vec2 b = a;
b.x = 10.0; // a is unchanged
```

A struct is shallow-copied on assignment, argument passing, return, and storage
in an array or table. Reference-valued fields remain shared. Struct fields are
mutable, equality is structural, and `value is Vec2` and `typeinfo(value)` expose
the declared type. A constructor accepts fields in declaration order or a single
initializer table.

Named table declarations use `table T { ... }` and have reference semantics.
`alias T = U` and `alias T = A | B` are reserved for pure aliases and unions.
At the embedding boundary, `bindType` exposes D structs as Dua value types and
D classes as reference types.
