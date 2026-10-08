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

## Completed: supplied scheduling and demand gating

Version 1.2.3 replaces the global queue with surface/force buckets; only buckets
with chests are swept. Dormant consumers retain registration without consuming
refill slots. Chest transitions activate/deactivate buckets, and player routing,
raised teleports, and force merges move consumers between them. Silent routing
changes by other mods require events, as described in [EVENTS.md](documentation/EVENTS.md).

Full consumers now return before location and supply checks. Membership
validation prunes invalid references until finding one live chest. The
[follow-up report](documentation/BENCHMARK_RESULTS_2026-10-07_QUEUES.md) compares
against v1.2.2, including many linked chests per bucket. The subsequent
[single-cursor comparison](documentation/BENCHMARK_RESULTS_2026-10-07_CURSOR.md)
covers simplifying traversal while keeping the active-group array.

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
