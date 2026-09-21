# Runtime benchmarks

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

The remaining major costs include hashed lexical-scope lookup and AST
interpretation. Replacing these with local-variable slots or bytecode would
require a separate execution-model change and additional closure, dynamic-binding,
source-location and execution-limit compatibility work.
