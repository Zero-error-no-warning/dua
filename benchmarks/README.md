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
