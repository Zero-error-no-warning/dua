# Runtime benchmarks

Run from the repository root with DMD (PowerShell):

```powershell
New-Item -ItemType Directory -Force .dub | Out-Null
dmd -O -release -inline -i -Isource benchmarks/runtime.d -of=.dub/runtime-benchmark.exe
.\.dub\runtime-benchmark.exe
```

The harness parses each function once and measures calls through `ScriptEngine.call`.
It validates every result, warms up each workload, and reports the median and minimum
of seven samples in microseconds. Garbage collection runs before each sample and is
outside the timed region; allocations and any collections during execution are timed.
Use the same compiler, flags, machine, and workload when comparing revisions.

The associative array workloads cover small and larger integer/string maps, including
construction and lookup. The other workloads exercise nested variable scopes and UFCS
function calls. These are focused microbenchmarks, not a general application score.

## Comparison (2026-09-22)

Windows x86_64, DMD 2.113.0, the flags above, seven samples per workload.
The baseline is `ce27f60d` (benchmark harness added, runtime unchanged).
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
