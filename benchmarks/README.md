# Runtime benchmarks

See [Reflected struct allocation reduction](REFLECTION.md) for the D-struct
reflection workloads, allocation results and compatibility checks.

Run from the repository root with DMD (PowerShell):

```powershell
New-Item -ItemType Directory -Force .dub | Out-Null
dmd -O -release -inline -i -Isource benchmarks/runtime.d -of=.dub/runtime-benchmark.exe
.\.dub\runtime-benchmark.exe
# Run one workload in its own process for revision comparisons:
.\.dub\runtime-benchmark.exe wideStructCopies
```

The harness parses each function once and measures calls through `ScriptEngine.call`.
It validates every result, warms up each workload, and reports the median and minimum
of seven samples in microseconds, plus the median change in
`GC.allocatedInCurrentThread()`. Garbage collection runs before each sample and is
outside the timed region; allocations and any collections during execution are timed.
Use the same compiler, flags, machine, and workload when comparing revisions.

The associative array workloads cover small and larger integer/string maps, including
construction and lookup. The other workloads exercise nested variable scopes and UFCS
function calls, host overloads, arrays, type checking, struct copies and range
generation. These are focused microbenchmarks, not a general application score.

For revision comparisons, compile this same driver against each source tree and
run each workload in a **separate process**. Running every workload sequentially
is useful for a quick check, but earlier allocation-heavy workloads can change
the GC heap and distort later measurements even with collection between samples.

## Initial comparison (2026-09-22)

Windows x86_64, DMD 2.113.0, the flags above, seven samples per workload.
The baseline is `ce27f60d` (benchmark harness added, runtime unchanged), and the
optimized revision is `20b4f9ff`.
Baseline and optimized executables were run consecutively on the same machine.

| Workload | Count | Baseline median (us) | Optimized median (us) |
| --- | ---: | ---: | ---: |
| Integer keys | 8 | 28 | 27 |
| String keys | 8 | 28 | 28 |
| Integer keys | 128 | 975 | 295 |
| String keys | 128 | 1,071 | 342 |
| Integer keys | 2,048 | 187,188 | 4,262 |
| String keys | 2,048 | 190,077 | 4,999 |
| Nested scopes | 10,000 | 9,376 | 7,790 |
| UFCS calls | 5,000 | 9,687 | 8,018 |

Larger scalar-key maps use a hash index alongside their ordered entries, making
lookup and replacement average O(1) in the entry count. Maps initially smaller
than eight entries use linear search. Aggregate keys still use their original
equality rules and linear search; deletion remains O(n) to preserve order and
existing entry snapshots. The index requires extra memory for scalar keys.

Environment bindings now store each value and its validator together, and scope
lookup walks the parent chain iteratively. UFCS resolution uses one lookup per
scope chain and returns the existing slot without allocating a temporary Value.
Scope search remains O(depth). Timings vary with system load and should be rerun
for application-specific workloads.

## Further optimization (2026-09-22)

The baseline below is the already optimized `20b4f9ff`; the final runtime is
`7b0c5b6b`. Both executables use the extended driver and the same DMD 2.113.0
flags above. Each named workload runs in a fresh process, with baseline and
optimized invocations adjacent. Figures are medians of seven samples.

| Workload | Count | Before (us) | After (us) | Before GC (MB) | After GC (MB) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Integer keys | 8 | 29 | 21 | 0.017 | 0.008 |
| Integer keys | 128 | 287 | 190 | 0.249 | 0.127 |
| Integer keys | 2,048 | 4,312 | 3,053 | 3.57 | 1.63 |
| String keys | 8 | 34 | 19 | 0.019 | 0.008 |
| String keys | 128 | 313 | 237 | 0.282 | 0.131 |
| String keys | 2,048 | 4,987 | 3,393 | 4.09 | 1.70 |
| Nested scopes | 10,000 | 9,219 | 6,033 | 4.64 | 1.28 |
| UFCS calls | 5,000 | 9,848 | 6,268 | 8.40 | 4.48 |
| Host overloads | 5,000 | 8,362 | 3,553 | 6.00 | 2.24 |
| Eight arguments | 2,000 | 14,275 | 8,596 | 17.41 | 9.22 |
| Array copies | 500 | 9,379 | 4,473 | 31.22 | 23.00 |
| Typed arrays | 300 | 13,636 | 6,911 | 11.45 | 5.34 |
| Nested structs | 500 | 34,800 | 1,718 | 71.79 | 2.66 |
| Overloaded operators | 5,000 | 12,715 | 8,326 | 10.81 | 6.01 |
| Wide nested structs | 100 | 10,978 | 10,895 | 20.64 | 20.58 |
| Range construction | 20,000 | 2,772 | 919 | 2.67 | 4.80 |

GC figures use decimal MB and measure the allocation counter, not peak/live
memory. Range construction is faster but reports more allocated bytes in this
measurement; allocation reduction is not universal. Timing and allocation
figures depend on allocator state and workload.

Changes include lazy overload diagnostics, exact-size argument buffers, transfer
of private array scratch storage, removal of an allocating evaluation closure,
reuse of evaluation-stack capacity, integer operator dispatch, and fewer repeated
AST downcasts. Type lookup reuses name strings while still reading mutable type
definitions on every lookup. Range generation computes its size with unsigned
arithmetic to support signed-limit crossings without overflow.

Struct copying skips repeated recursive copies only when there are no host-copy
callbacks and field order has reached a fixed point under hash-table reinsertion.
The original path remains for trees containing structs wider than eight fields.
This preserves display order, independent struct storage, shallow reference
members, and host-copy effects. The wide-struct benchmark covers that fallback.

For example, after building `runtime-before.exe` and `runtime-after.exe` against
the respective source trees:

```powershell
$cases = 'integerKeys', 'stringKeys', 'scopedLoop', 'ufcsCalls', 'hostOverloads',
    'manyArguments', 'arrayCopies', 'typedArrays', 'structCopies', 'operatorCalls',
    'wideStructCopies', 'rangeBuild'
foreach ($caseName in $cases) {
    .\.dub\runtime-before.exe $caseName
    .\.dub\runtime-after.exe $caseName
}
```

## Compatibility snapshots

`compatibility.d` emits deterministic results for 376 cases: arithmetic and
execution steps, associative-array mutation/order, struct display order at
multiple widths, reflected-copy counts, errors, closures and coroutines. Build
the same driver against the original `f3ca6ccf` source tree and the current tree:

```powershell
dmd -O -release -inline -i -Isource benchmarks/compatibility.d -of=.dub/compatibility-after.exe
.\.dub\compatibility-after.exe | Set-Content -Encoding UTF8 .dub/compatibility-after.txt
# Build compatibility-before.exe with -I pointing to the original source tree.
.\.dub\compatibility-before.exe | Set-Content -Encoding UTF8 .dub/compatibility-before.txt
Get-FileHash .dub/compatibility-before.txt, .dub/compatibility-after.txt
```

The original and final outputs had identical SHA-256 hashes. The public regression
tests in `source/dua/performance_regression_tests.d` also pass when compiled
against the original implementation. The final `dub build --compiler=dmd` and
`dub test --compiler=dmd` pass, with eight modules reporting successful unittests.

At that revision, hashed lexical-scope lookup and AST interpretation remained
major costs. The following change addresses local-variable storage and lookup.

## Local-variable slots (2026-09-22)

Baseline: `13343aaa` (runtime identical to `fe096909`). Final runtime: `5ef3d510`.
Windows x86_64, DMD 2.113.0, `-O -release -inline`, the same drivers compiled
against both trees. Each workload/revision ran in a fresh process, with seven
timed samples after warmup. Three process pairs were collected, reversing the
revision order in the second pair. Figures below are the median of those three
process medians. Raw process medians, minima and allocation counts are in
[results/slots-2026-09-22.txt](results/slots-2026-09-22.txt).

| Workload | Count | Before (us) | After (us) | Before GC (MB) | After GC (MB) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Integer keys | 8 | 23 | 22 | 0.008 | 0.008 |
| Integer keys | 128 | 200 | 199 | 0.127 | 0.127 |
| Integer keys | 2,048 | 3,002 | 2,924 | 1.63 | 1.63 |
| String keys | 8 | 24 | 22 | 0.008 | 0.008 |
| String keys | 128 | 220 | 228 | 0.131 | 0.131 |
| String keys | 2,048 | 3,442 | 3,330 | 1.70 | 1.70 |
| Local-variable loop | 20,000 | 8,436 | 8,481 | 0.641 | 0.641 |
| Nested scopes | 10,000 | 6,018 | 5,916 | 1.28 | 1.28 |
| Capturing closure calls | 5,000 | 5,546 | 5,142 | 3.84 | 3.44 |
| Recursive Fibonacci | 18 | 7,631 | 7,135 | 6.29 | 5.62 |
| Four declarations per iteration | 5,000 | 10,008 | 8,420 | 7.60 | 6.80 |
| UFCS calls | 5,000 | 6,228 | 6,041 | 4.48 | 4.08 |
| Host overloads | 5,000 | 3,805 | 3,597 | 2.24 | 2.24 |
| Eight arguments | 2,000 | 9,002 | 7,401 | 9.22 | 7.01 |
| Array copies | 500 | 4,548 | 4,945 | 23.00 | 22.87 |
| Typed arrays | 300 | 7,132 | 7,269 | 5.34 | 5.23 |
| Nested structs | 500 | 1,614 | 1,671 | 2.66 | 2.52 |
| Overloaded operators | 5,000 | 8,464 | 8,235 | 6.01 | 5.44 |
| Wide nested structs | 100 | 11,771 | 12,304 | 20.58 | 20.56 |
| Range construction | 20,000 | 945 | 897 | 4.80 | 4.80 |

The clearest gains are scope construction (1.19x), eight-argument calls (1.22x)
and capturing closures (1.08x). Eight-argument calls allocate about 24% fewer
bytes. This is not a universal speedup: simple loops are essentially unchanged,
and the aggregate-copy workloads show some slower medians. Variance is visible
in the raw runs; do not interpret a few percent as a stable improvement or
extrapolate these microbenchmarks to all applications. GC counts measure
allocated bytes, not peak or retained memory.

### First execution, including parsing

`startup.d` repeatedly uses `ScriptEngine.run`, parsing a new AST on every call,
so it includes planning and first-use costs. Engine construction is outside
the timed region. Counts of 500 report the whole batch, not a per-run duration.

```powershell
dmd -O -release -inline -i -Isource benchmarks/startup.d -of=.dub/startup-after.exe
.\.dub\startup-after.exe smallRun
.\.dub\startup-after.exe smallLocals
.\.dub\startup-after.exe freshFunction
.\.dub\startup-after.exe topLevelLoop
```

| Workload | Runs/sample | Before (us) | After (us) | Before GC (MB) | After GC (MB) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Literal arithmetic | 500 | 460 | 488 | 0.864 | 0.864 |
| Two local declarations | 500 | 1,443 | 1,399 | 2.400 | 2.376 |
| Define and call a function | 500 | 2,541 | 2,469 | 4.048 | 4.104 |
| Top-level loop, 20,000 iterations | 1 | 8,380 | 8,167 | 0.649 | 0.650 |

These small differences varied between process pairs. Planning still has an
initial cost, and first-run allocation reduction is not universal. Empty layouts
are shared, small name lists avoid hash-table construction, and a variable
reference gets a cached slot path only when used a second time.

### Storage and compatibility

Each syntax scope reserves fixed slots for its declarations. A slot becomes
visible only when its declaration executes; reads of inactive slots continue
searching outer scopes. Values and assignment validators remain together.
Frames with up to eight reserved names allocate metadata and values together;
larger frames use an exact-size array. Empty scopes remain small.

Variable references cache only layout identities and slot indices. Every access
checks the actual environment chain and declaration state. Caches retain no
environment or value, so different closure instances, recursion, host changes
to `Environment.parent`, and reuse of an AST across engines stay independent.
Added declarations in a host-modified AST use dynamic bindings. Globals that
already have bindings retain name lookup, and later host/module definitions
remain visible. Slot arrays never resize, preserving public `Environment.find`
pointers. Lookup remains O(scope depth); this is not a bytecode interpreter.

The expanded compatibility driver emits **396 cases**. Baseline and final output
matched byte for byte, including values, error text, traces, reflected-copy
counts and execution-step counts. Both files had SHA-256:

```text
F6A6CE596F58759941194C4CCE1755DF8624AC2BE95DFF4B31D5A5185B5DFDC0
```

`slot_regression_tests.d` covers late shadowing, shared and independent closures,
per-iteration captures, recursion, typed assignments, module isolation, late host
binding, mutable/reused ASTs, receiver context and coroutine suspension. Escaped
closures with 13 different frame sizes also survive explicit GC collections.
The public regression module passes against both the baseline and final source;
the final `dub build --compiler=dmd` and `dub test --compiler=dmd` pass (nine
unittest modules). Internal environment tests additionally check slot-pointer
stability, cache guards, changed parents and assignment-validator effects.

### Existing coroutine limitation found during validation

The following interleaved-resume example crashed the **unchanged baseline** with
Windows access violation `0xC0000005`. It is excluded from the passing differential
suite and remains a separate coroutine lifecycle issue. Single-coroutine
suspension/resumption, including captured locals, is covered by this change.

```dua
any make(int n) {
    return coroutine.create(() { yield n; n += 1; yield n; return n + 1; });
}
auto a = make(10); auto b = make(20);
return [coroutine.resume(a), coroutine.resume(b), coroutine.resume(a),
    coroutine.resume(b), coroutine.resume(a), coroutine.resume(b)];
```
