# Supplied consumer queues — October 7, 2026

These measurements cover the per-group-cursor implementation. See the
[single-cursor follow-up](BENCHMARK_RESULTS_2026-10-07_CURSOR.md) for the later
traversal simplification and its comparison against this snapshot.

This follow-up implements all three requested changes: supplied-only surface/force
queues, demand checks before location/supply resolution, and chest validation that
stops at the first live member. Version 1.2.3 rebuilds queues on upgrade while
preserving character ammo delays. Full consumers still require demand polling;
they no longer resolve location or supply when already satisfied.

The baseline is `7468a388c42c053759813f92a84d82a701b21bb3` (v1.2.2), the **new**
implementation from the [latest membership report](BENCHMARK_RESULTS_2026-10-07_MEMBERSHIP.md).
Both versions were rerun together rather than comparing only against historical
wall-clock values. All final measurements use Factorio 2.1.21, mac-arm64 Steam,
10,000 real consumers, six alternating samples, and sequential benchmark processes.

## Isolated callbacks: one chest per bucket

Four measured passes per sample, with preparation, resets, and conservation checks
outside the timer. Values are medians of six sample-mean sweep times. Each standard
pass visits all 10,000 consumers. GC occurring inside the callback remains timed;
this does not include all between-tick collection.

| Budget | Scenario | Old sweep ms | New sweep ms | Change | Old ms/callback | New ms/callback |
|---:|---|---:|---:|---:|---:|---:|
| 10 | full | 31.741 | 22.748 | -28.3% | 0.0317 | 0.0227 |
| 10 | partial | 58.973 | 54.256 | -8.0% | 0.0590 | 0.0543 |
| 10 | no_supply | 36.793 | 34.270 | -6.9% | 0.0368 | 0.0343 |
| 1000 | full | 30.718 | 22.431 | -27.0% | 3.0718 | 2.2431 |
| 1000 | partial | 51.373 | 46.096 | -10.3% | 5.1373 | 4.6096 |
| 1000 | no_supply | 32.324 | 32.807 | +1.5% | 3.2324 | 3.2807 |

This directly retests the full-inventory regression reported previously at
45.6–59.5% relative to the pre-membership engine. The comparison above is against
the membership engine, not that older pre-membership baseline. Empty chests remain
scheduled so restocking can be detected; this case should be judged separately
from full consumers or absent chests.

## Equal-work mixed worlds

Five surfaces have chests; half the consumers on those surfaces belong to an
unsupplied force. Each measured pass refills the same 2,500 supplied consumers
by one item and leaves the other 7,500 untouched.

| Budget | Scenario | Old sweep ms | New sweep ms | Change | Old ms/callback | New ms/callback |
|---:|---|---:|---:|---:|---:|---:|
| 10 | mixed_supply | 24.888 | 13.105 | -47.3% | 0.0249 | 0.0524 |
| 1000 | mixed_supply | 21.314 | 13.647 | -36.0% | 2.1314 | 4.5491 |

The baseline needs 1,000 callbacks at budget 10 and 10 at budget 1,000. The new
queues need 250 and 3 respectively. At budget 1,000 the final callback performs
500 extra full-consumer checks; these are included in timing. Compare sweep time
for equal useful work: average callback time alone hides the reduced callback
count. Every pass validates all 10,000 inventories and conservation in all pools.

## Many linked chests

The same standard workloads with **1,000 physical chests per surface/force
bucket**, or 10,000 chests total. All members are registered. Shared inventory
stock, inventory size, consumers, and target demand are unchanged. Chest
construction and registration are outside the callback timer.

| Budget | Scenario | Old sweep ms | New sweep ms | Change | Old ms/callback | New ms/callback |
|---:|---|---:|---:|---:|---:|---:|
| 10 | full | 228.802 | 24.566 | -89.3% | 0.2288 | 0.0246 |
| 10 | partial | 248.674 | 53.780 | -78.4% | 0.2487 | 0.0538 |
| 10 | no_supply | 234.004 | 37.622 | -83.9% | 0.2340 | 0.0376 |
| 1000 | full | 36.498 | 26.037 | -28.7% | 3.6498 | 2.6037 |
| 1000 | partial | 49.846 | 44.507 | -10.7% | 4.9846 | 4.4507 |
| 1000 | no_supply | 35.147 | 32.566 | -7.3% | 3.5147 | 3.2566 |

The old implementation checks every member on each visited bucket/tick. The new
implementation checks none for full consumers and stops at the first live member
when demand exists. Invalid members before that witness are still pruned; an
entirely invalid bucket still requires removing all its records. Destruction
events handle invalid records beyond the first live member.

## Advancing ticks

Budget 1,000; 1,200 ticks per run with the first 60 excluded, leaving 1,140 retained
ticks per sample. Values are medians of six per-run means, in milliseconds.
`scriptUpdate` includes Auto-Loader, fixture validation/reset work, and other
script handlers. Whole-update timing also includes engine simulation. This is
not an isolated Auto-Loader callback measurement or a prediction of player UPS.

| Scenario | Old script ms | New script ms | Change | Old update ms | New update ms |
|---|---:|---:|---:|---:|---:|
| no_chest | 2.0356 | 2.1248 | +4.4% | 2.3880 | 2.3918 |
| mixed_supply | 4.5789 | 7.3959 | +61.5% | 5.0397 | 7.9900 |
| no_supply | 5.7819 | 5.6915 | -1.6% | 6.3793 | 6.2196 |
| partial | 7.0680 | 6.9089 | -2.3% | 7.7062 | 7.5600 |
| full | 5.3993 | 4.3857 | -18.8% | 5.9581 | 4.8370 |

No-chest shutdown is unchanged: both implementations unregister the refill handler.
Differences in that combined counter cannot be attributed to refill visits.

**Mixed-world production work differs:** the old global queue transfers 250 items
per tick on average, while supplied queues transfer 1,000. The new implementation
uses its entire visit budget for useful consumers, giving **4× refill throughput**.
Combined script time per transferred item changes by **-59.6%**.
The equal-work callback comparison above isolates completing the same amount of
refilling. Production checks each version's actual scheduled batch and debits,
and rotates additional checks over dormant consumers every ten ticks in both
versions. This revised fixture means mixed-world absolute timings should not be
compared directly with the previous report's fixture.

## Reproduction and retained evidence

Run from the repository root, selecting the compatible executable explicitly:

```sh
export AUTO_FACTORIO='/Users/aaron/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio'
python3 benchmarks/run.py --old 7468a38 --new WORKTREE --mode callback \
  --scenarios full partial no_supply --budgets 10 1000 --samples 6 --iterations 4 \
  --output benchmarks/artifacts/supplied-queues-callback-final
python3 benchmarks/run.py --old 7468a38 --new WORKTREE --mode callback \
  --scenarios full partial no_supply --budgets 10 1000 --samples 6 --iterations 4 \
  --chests-per-bucket 1000 --output benchmarks/artifacts/supplied-queues-many-chests-final
python3 benchmarks/run.py --old 7468a38 --new WORKTREE --mode callback \
  --scenarios mixed_supply --budgets 10 1000 --samples 6 --iterations 4 \
  --output benchmarks/artifacts/supplied-queues-mixed-callback
python3 benchmarks/run.py --old 7468a38 --new WORKTREE --mode production \
  --scenarios no_chest mixed_supply no_supply partial full --budgets 1000 \
  --ticks 1200 --samples 6 --output benchmarks/artifacts/supplied-queues-production
```

Choose fresh output directories on reruns. Artifacts are local and ignored by Git;
retain these directories to share raw logs, source snapshots, hashes, fixtures,
saves, and parsed samples. The pilot directories `supplied-queues-callback` and
`supplied-queues-many-chests` are excluded from this report.

- [Standard callback samples](../benchmarks/artifacts/supplied-queues-callback-final/callback-results.json) and [manifest](../benchmarks/artifacts/supplied-queues-callback-final/sources.json).
- [Many-chest callback samples](../benchmarks/artifacts/supplied-queues-many-chests-final/callback-results.json) and [manifest](../benchmarks/artifacts/supplied-queues-many-chests-final/sources.json).
- [Equal-work mixed samples](../benchmarks/artifacts/supplied-queues-mixed-callback/callback-results.json) and [manifest](../benchmarks/artifacts/supplied-queues-mixed-callback/sources.json).
- [Production samples](../benchmarks/artifacts/supplied-queues-production/production-results.json) and [manifest](../benchmarks/artifacts/supplied-queues-production/sources.json).

Every run below used these exact `control.lua` snapshots:

- Baseline SHA-256: `5be1992d6f145d1abc1953cbb3ef34b55a031076060e8efe1c327a80b9be131a`
- New SHA-256: `5b84c550e19247664dc897b14a8c80d01722feb23e7fefa0d3734ac2ce5783e6`

## Correctness and boundaries

Lua regressions pass for dormant queues, active budgets, differently sized bucket
fairness, first/last chest transitions, invalid-member pruning, full consumers
avoiding location reads, player routing, read-only loading, migration, and existing
quality/conservation/refill rules. Python executable-discovery checks pass.
Real Factorio supply, 24-tick lifecycle, and upgrade-from-v1.2.2 tests pass,
including raised car teleports into/out of dormant surfaces and force merging a
dormant consumer into a supplied force.

Routing is event-driven: player surface/force changes, raised teleports, and force
merges move consumers between buckets. Other mods' silent surface/force mutations
cannot activate dormant consumers; they must raise the appropriate events. See
[the event contract](EVENTS.md). Actual graphical player routing, multiplayer,
and the original player save were not exercised. Benchmarks cover turrets and
furnaces, not every mobile consumer, quality combination, or player inventory.
