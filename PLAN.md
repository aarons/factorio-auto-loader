# UPS performance investigation

On 2026-10-07, a new playthrough showed unexpectedly high Auto-Loader script time
with no Auto-Loader chests built: `mod-auto-loader-chest: 2.185/0.845/4.031`.
The cause is unknown; the save and active settings have not been examined.

Repeated chest discovery was addressed in v1.2.2: chest membership now gates
supply, refill processing uses direct linked-inventory access, and the refill
tick handler is disabled when no chests exist anywhere. See the
[membership benchmark report](documentation/BENCHMARK_RESULTS_2026-10-07_MEMBERSHIP.md)
for measurements and validation limits. The original player save has not been
examined, so its specific reported cost remains unverified.

The remaining priorities in [control.lua](control.lua) are below.

## 1. Scheduling consumers without a supply chest

Consumers on all surfaces and forces still share one global round-robin queue.
When at least one chest exists, each visited consumer's current surface and force
are checked for supply membership. Unsupplied consumers skip inventory checks,
but their visits still consume the per-tick budget and delay supplied consumers.

Replace the global processing queue with scheduling for supplied surface/force
buckets. Keep unsupplied consumers registered so building a first chest does not
require rediscovery. Activation and deactivation must handle chest lifecycle
changes, and consumer routing must remain correct when entities change surfaces
or forces. Preserve fairness and a bounded amount of work per tick, including
cleanup of stale entries.

An absent chest and an empty chest are different cases: an empty chest can be
restocked without a build event and must remain scheduled. Benchmark mixed
supplied/unsupplied worlds and already-full consumers; the current early gate
adds overhead for consumers that would otherwise return before looking up supply.

## 2. Supply snapshots and candidate scans

When supply is needed, `get_pool()` reads the chest inventory and builds item
records. Refill functions search those records for compatible supply, and
`debit_pools()` applies the accumulated removals. Many pools or diverse
inventories may increase API calls, table allocation, and candidate scanning.
This affects active supply networks rather than the no-chest case.

The previous [ledger comparison](documentation/BENCHMARK_RESULTS_2026-09-09_LEDGER.md)
found benefits from batching debits over immediate transfers. Existing benchmarks
cover turrets and furnaces, with consumers grouped by surface; characters,
locomotives, and diverse fuel/ammo quality combinations are coverage gaps.

## Other observations

- The processing budget limits consumers visited per tick. A larger registry can
  therefore increase refill delay without a proportional increase in tick cost.
- Build and clone handlers inspect unrelated entities before rejecting them,
  potentially adding overhead during large construction bursts.
