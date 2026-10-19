# Reflected aggregate materialization

Reflected structs keep a receiver-independent member layout per qualified D type
and thread. Each reflected value still owns its native struct snapshot, field
values, bound functions and mutable metadata. Methods and accessors are bound on
first use; explicit `tableValue` access materializes the complete writable map.

Aggregate `alias this` forwarding uses the same layout. An extracted forwarded
method retains the outer receiver and resolves its current alias target when
invoked. `@NoBind`, overload selection and outer-member precedence use the same
registration rules as eager reflection. Type discovery never creates a dummy
native value, so default-construction restrictions and destructors are respected.

Some binding operations have observable native effects. Taking a unary operator
delegate through an alias can evaluate its accessor. Resolving the equality
delegate for an aliased class can also evaluate getters. Those operations retain
their eager ordering relative to field snapshots and copied fields; they are not
silently moved to the first script call.

Regression tests in `dua.value` compare the legacy eager route with the shared
layout for getter effects, nested aliases that mutate their receiver, copies,
overloads, extracted-method lifetime, destructors and disabled default
constructors. Existing reflection, operator, `@NoBind`, completion and editor
tests cover the remaining public contracts.

In the ZsD integration benchmark, this removes per-value construction of unused
member/accessor objects from `Repoxy!Vec2` and nested decorated-text values. This
does not change game scripts, update frequency, Scene transforms or UI behavior.
Benchmarks must compare the same work with an optimized build and measure elapsed
time, allocations and GC separately. Allocation ratios alone do not predict
elapsed-time or whole-frame speedups. Decorated-text benchmark values include
construction and reading the resulting array length, not construction alone.
