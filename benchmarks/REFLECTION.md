# Reflected struct allocation reduction (2026-09-22)

Baseline: `341a641cffae0c7e786c3642423e59027dcd0a83`.
Windows x64, DMD 2.113.0, `-O -release -inline`. These are standalone Dua
microbenchmarks, not measurements of ZsD's playground or its debug build.

## Changes

Each reflected D struct used to rebuild its methods, operators, field accessors
and associative maps whenever it crossed a value-copy boundary. A type/thread
now shares a descriptor containing member names, field indices and binder
function pointers. It contains no receiver or bound delegate. Each value still
owns its native struct copy and eagerly converted field snapshots. Callables
are created on first access and retain that value's receiver.

Internal named member lookup can use this descriptor without building the whole
member map. Public `Value.tableValue` access still exposes a complete, writable
map, with the original insertion/iteration order and stable callable identity.
Copies retain the previous native postblit effects and their order. No argument
or return-value copy boundary was removed.

Type-name and alias-name metadata arrays are shared as private snapshots.
Metadata setters continue to replace per-value data. Fresh getter/setter maps
on the eager reflection path are adopted without an extra duplicate.

The descriptor path also supports structs whose `alias this` targets a scalar
or array, including nested text/container shapes. Forwarding to a struct or
class still uses the eager path, because discovering forwarded equality methods
can evaluate user getters. Class reflection also retains the eager path. Those
paths benefit from the metadata changes but still allocate per-member wrappers.

## Reproduce

Compile the same benchmark file against each runtime revision, then run the
executables in separate processes. Pass the workload name and optionally an
iteration count (default 1,000):

```powershell
dmd -O -release -inline -i -Isource benchmarks/reflection.d -of=.dub/reflection-after.exe
.\.dub\reflection-after.exe wideHostCopies
.\.dub\reflection-after.exe aliasedReturns 100000
```

Each process warms up once and takes seven samples, checking every result.
Reported times, allocation counts and GC statistics are independent medians.
Explicit collections occur outside the timed/allocated region. Allocated bytes
come from `GC.allocatedInCurrentThread`; these are not retained heap sizes.

| Workload (1,000 iterations) | Before (us) | After (us) | Before allocated B | After allocated B | Reduction |
| --- | ---: | ---: | ---: | ---: | ---: |
| Two-field native struct copies | 3,480 | 1,692 | 5,137,264 | 2,321,264 | 54.8% |
| Native struct copies + method | 9,509 | 1,984 | 14,929,264 | 2,321,264 | 84.5% |
| Dua-declared struct copies | 1,147 | 1,001 | 1,317,824 | 1,141,472 | 13.4% |
| Bound constructor + copies | 9,995 | 2,059 | 14,975,232 | 2,325,280 | 84.5% |
| Native struct returns | 26,981 | 3,163 | 44,305,264 | 3,761,264 | 91.5% |
| Native struct operators | 44,917 | 3,475 | 73,519,824 | 4,675,248 | 93.6% |
| 41-method, two-field struct copies | 54,546 | 2,062 | 82,817,264 | 2,321,264 | 97.2% |
| Nested structs with array/string aliases | 89,026 | 11,772 | 231,089,264 | 17,473,264 | 92.4% |

Timings depend on heap state, GC heuristics and other processes. In this run the
wide-struct workload collected 83 times before versus 2 after per sample; the
aliased-return workload collected 28 versus 19 times. Reduced allocated bytes
do not imply an identical reduction in collection counts or pause durations.

The final runtime also completed seven measured samples of 100,000 iterations
per workload. After explicit GC, the wide-struct process used 99,408 B after
both its first and last samples; the aliased-return process used 101,200 B after
both. Their median allocated totals were 232,001,264 B and 1,747,201,264 B.
No growth was observed in this test's post-collection heap; this does not replace
a long-running measurement with the application's actual types and workload.

The earlier pre-slotting comparison (`fe096909`) already showed comparable
allocation costs: the method-copy case allocated 15,201,648 B before slotting
versus 14,929,264 B at the baseline above. The large reflection allocation cost
predates the slot implementation.

## Compatibility and crash regression

`dub build --compiler=dmd` and `dub test --compiler=dmd` pass, including ten
unittest modules. The new reflection tests cover:

- Extracted getters, setters and methods after their original handles disappear
  and explicit GC runs; independent receivers on different copies.
- Private-field visibility, overloaded/default-argument methods, callable
  identity, writable full member maps and native conversion after map edits.
- Independent metadata replacement and live scalar/array alias targets.
- A camera proxy whose setter updates the original class instance, while
  returned struct values remain independent.

`reflection_compatibility.d` produces 91 output rows covering 1/4/20/80-method
types, nested fields, arrays, class references, native postblit callback order,
operators, errors, step counts, member-map edits and alias metadata. Before and
after outputs match exactly (UTF-8 BOM, CRLF), SHA-256:

```text
3DFA5C4CF51D488049C1183A2D60DDD54F25E8ABFE5E824F7E42A4AE0DEDAF46
```

The existing 396-case compatibility driver also has identical output when
encoded with the same BOM/newline convention as its baseline.

The wide aggregate-alias fixture is compared through its native conversion,
copy and member-map APIs. Running its complete script sequence crashed the
unchanged baseline; that existing limitation is not counted as a passing script
test. The focused camera proxy and existing alias-this tests do pass.

An intermediate implementation crashed in `reflection-after.exe` because the
field setter's receiver appeared only in compile-time member lookup and DMD did
not capture it correctly. The getter/setter closures now explicitly reference
their owner and retain it. The escaped-accessor GC test covers this failure.
Subsequent Windows validation suppressed system error dialogs.

ZsD's shared DUB cache, game sources and FPS update frequency were not modified.
The reported 0.473-second/75-ms GC hitch has not been remeasured in the game.
Rebuild the game with this Dua revision and repeat the same moving/idle frame
measurement before concluding that its periodic hitch is resolved.
