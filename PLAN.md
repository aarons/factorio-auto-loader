# UPS performance investigation

On 2026-10-07, a new playthrough showed unexpectedly high Auto-Loader script time
with no Auto-Loader chests built: `mod-auto-loader-chest: 2.185/0.845/4.031`.
The cause is unknown; the save and active settings have not been examined.

A review of v1.2.1 (`00c3840`) identified the following priorities in
[control.lua](control.lua). Their performance impact has not been measured.

## 1. Repeated unsuccessful chest discovery

`representative_chest()` searches the surface when it has no valid cached chest.
Successful searches are remembered, but missing chests are rediscovered on each
tick that needs supply. One consumer with unmet demand can trigger 60 failed
searches per second at 60 UPS. The query has no area restriction.

This is the leading hypothesis for the no-chest report. Avoiding repeated failed
searches could reduce idle cost; chest availability can change as chests are
built, removed, moved, or assigned to another force.

The existing benchmark's `no_supply` scenario has chests without matching supply,
so it does not exercise this case. The missing-chest assertions in [tests/supply.lua](tests/supply.lua)
describe the current repeated searches rather than a required behavior.

## 2. Polling consumers without a supply chest

Consumers are registered regardless of chest availability. Refill checks inspect
inventories, shortages, and item categories before discovering that there is no
supply chest. Character checks also inspect guns, cursor contents, and settings.

The player's character alone keeps this work active. With ten or fewer consumers
and the default budget of ten, every consumer can be checked every tick. This
cost remains even if repeated chest searches are eliminated.

An absent chest and an empty chest are different cases: an empty chest can be
restocked without a build event. Worlds can also have a mixture of supplied and
unsupplied surfaces and forces.

## 3. Supply snapshots and candidate scans

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
- Stale registry entries do not consume that budget, so cleanup after mass
  destruction or surface deletion can traverse much of the registry in one tick.
- Build and clone handlers inspect unrelated entities before rejecting them,
  potentially adding overhead during large construction bursts.
