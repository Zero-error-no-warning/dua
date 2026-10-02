# Dua language reference

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

## Module instances

Each source module has shared ordinary variables and per-instance `instance`
variables. Within one ScriptEngine, ordinary import, require, and loadModule
return the same default instance. Import aliases change only local bindings;
module identity and shared storage are unchanged. Folder `init.dua` resolution
is preserved.

```dua
// actor.dua
int totalDamage = 0;
instance int hp = 100;
export void damage(int amount) { hp -= amount; totalDamage += amount; }
export int health() { return hp; }
export int total() { return totalDamage; }
```

```dua
import actor as Actor;
Actor.damage(10);
auto player = new Actor;
auto enemy = new Actor;
player.damage(20);
// health: default 90, player 80, enemy 100; total() is 30 for all three.
```

`new binding` takes an identifier holding a module value, including an import
alias, require result, or another instance. It has no argument list. It reevaluates
instance initializers; it never copies the default instance's current state.
Ordinary variable initializers, ordinary imports, type declarations, and other
module initialization statements run only for the default instance. Container
literals in instance initializers create fresh values. An initializer that
explicitly returns shared data retains sharing; there is no implicit deep copy.

```dua
instance import movement;
instance import animation as anim;
```

Each declaration creates a fresh dependency instance for every owning instance,
including the default. It is equivalent to an ordinary import under another name
followed by `instance auto movement = new Movement`. Dependencies also have their
own normally loaded defaults. Only instance imports instantiate dependencies;
ordinary imports inside those dependencies still use their defaults. The
dependency graph is not recursively cloned.

```dua
instance {
    int hp = 100;
    import movement;
    import animation as anim;
}
export int health() { return hp; }
```

An instance block adds no lexical scope and means individual instance modifiers.
Only variable and import declarations are allowed. Functions, types, aliases,
nested blocks, and executable statements are rejected. Instance declarations are
restricted to source-module top level, not functions, ordinary blocks, global
run/load, or incremental ModuleHandle loads. Both `export instance int x = 1;`
and `instance export int x = 1;` are supported. Export a dependency with a separate
`export movement;` statement after its instance import.

Initialization follows source order, with instance blocks flattened in place.
Fresh instances skip ordinary initialization, construct their own directly
declared functions, and execute instance declarations and exports in that order.
There is no function hoisting. Top-level variable, import, and function names are
reserved: accessing or assigning one before its declaration executes is an error,
even if an outer binding has the same name. For example,
`instance int a = b; instance int b = 1;` fails.

Functions retain their defining instance. Extracted functions, returned closures,
and calls through another instance do not rebind instance state. Function values
stored in ordinary variables are shared and retain their original owner. Module
member access returns functions without automatically calling zero-argument
functions: `auto f = player.health; f();` reads player's health. Ordinary tables
retain their existing property-call behavior. Exported numeric values remain
snapshots, not live variable references; use functions to read current state.

Modules containing instance declarations publish only explicit exports. A final
container initializer or instance import is not implicitly exported. Modules
without public exports can still be instantiated. The legacy final-table export
fallback applies only to modules without instance declarations.

Ordinary import cycles share the in-progress default export table; reading an
export that has not executed yet fails. Recursive instantiation is separately
rejected with a creation path such as `A -> B -> A`. Failed creations are never
returned as successful handles or installed as defaults. A failed nested load
evicts modules newly cached during that load; provisional export tables are
cleared and captured functions invalidated. Previously loaded modules remain
intact. Shared-state changes and external side effects are not rolled back.
Execution limits, source positions, and call traces use the same evaluator.

Only source definitions are instantiable. Host-created empty `newModule` handles,
the global handle, and legacy modules publishing a returned table instead of
explicit exports cannot be instantiated. Legacy modules still support ordinary
import/require. Incremental host load/bind operations do not change the stored
source definition. `ModuleHandle.instantiate()` and
`ScriptEngine.instantiateModule(name)` return fresh handles through the same
implementation as Dua's `new`.

See the [runnable example](../examples/module-instances/README.md) and the
[complete Japanese reference](language-reference-ja.md).
