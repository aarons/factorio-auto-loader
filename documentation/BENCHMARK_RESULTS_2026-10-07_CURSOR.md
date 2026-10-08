# Single traversal cursor — October 7, 2026

The scheduler now stores one traversal position: the current active group and
consumer index. Individual consumer groups have no cursors. Group registration,
the active-group array, demand-first refilling, and first-live-chest validation
are unchanged. Activation remains O(1); deactivation remains O(active groups).
Neither operation iterates the group's consumers.

Removing a group before the current group preserves the consumer position;
removing the current group starts its successor at the first consumer. A
reactivated group starts from its first consumer instead of remembering the
position at which it was deactivated. Configuration changes rebuild traversal
through the existing initialization handler; ordinary loading preserves it.

## Baseline and method

The baseline is the exact per-group-cursor implementation measured in the
[preceding report](BENCHMARK_RESULTS_2026-10-07_QUEUES.md), retained at
`benchmarks/artifacts/supplied-queues-callback-final/sources/new`. Both versions
were rerun together. This compares the cursor cleanup against that latest
implementation, not against v1.2.2's global consumer queue.

Factorio 2.1.21, mac-arm64 Steam; 10,000 real consumers; six alternating samples.
Benchmark processes ran sequentially. Callback measurements use four measured
passes per sample and exclude fixture preparation, resets, and assertions.
Tables report medians of six sample means. Changes are observations from these
runs, not statistical significance estimates or predictions for player saves.

## Standard callback sweeps

One chest per surface/force pool; each pass visits 10,000 consumers.

| Budget | Scenario | Old sweep ms | New sweep ms | Change | Old ms/callback | New ms/callback |
|---:|---|---:|---:|---:|---:|---:|
| 10 | full | 23.694 | 22.582 | -4.7% | 0.0237 | 0.0226 |
| 10 | partial | 58.330 | 54.143 | -7.2% | 0.0583 | 0.0541 |
| 10 | no_supply | 33.503 | 31.603 | -5.7% | 0.0335 | 0.0316 |
| 1000 | full | 22.429 | 22.168 | -1.2% | 2.2429 | 2.2168 |
| 1000 | partial | 40.473 | 44.933 | +11.0% | 4.0473 | 4.4933 |
| 1000 | no_supply | 30.481 | 31.619 | +3.7% | 3.0481 | 3.1619 |

Callback differences change sign across workloads and samples. For example, the
budget-1,000 partial case increased 11.0% in the aggregate, while its paired sample
changes ranged from -14.3% to +29.2%. The results do not establish a general speedup
from consolidating cursor state. Callback timings include GC occurring within
the timer but exclude some between-tick collection.

## Mixed supplied/unsupplied consumers

Both versions already exclude dormant groups. Each pass refills the same 2,500
supplied consumers and leaves 7,500 consumers unchanged. Both require 250
callbacks at budget 10, or three callbacks at budget 1,000 (including 500 extra
full-consumer checks). This comparison has equal work and callback counts.

| Budget | Scenario | Old sweep ms | New sweep ms | Change | Old ms/callback | New ms/callback |
|---:|---|---:|---:|---:|---:|---:|
| 10 | mixed_supply | 13.128 | 13.869 | +5.6% | 0.0525 | 0.0555 |
| 1000 | mixed_supply | 12.937 | 14.004 | +8.2% | 4.3125 | 4.6679 |

## Many linked chests

1,000 physical chests per pool, 10,000 total. Supply stock and consumer demand
are unchanged. Both implementations stop validation at the first live chest.
This checks that the preceding membership optimization remains in place; it
is not a comparison against the old all-members validation loop.

| Budget | Scenario | Old sweep ms | New sweep ms | Change | Old ms/callback | New ms/callback |
|---:|---|---:|---:|---:|---:|---:|
| 10 | full | 23.735 | 25.692 | +8.2% | 0.0237 | 0.0257 |
| 10 | partial | 55.938 | 57.246 | +2.3% | 0.0559 | 0.0572 |
| 10 | no_supply | 38.512 | 36.901 | -4.2% | 0.0385 | 0.0369 |
| 1000 | full | 21.681 | 23.068 | +6.4% | 2.1681 | 2.3068 |
| 1000 | partial | 46.350 | 48.912 | +5.5% | 4.6350 | 4.8912 |
| 1000 | no_supply | 35.263 | 29.257 | -17.0% | 3.5263 | 2.9257 |

## Advancing-tick confirmation

Budget 1,000, 1,200 ticks per run, first 60 excluded, leaving 1,140 retained ticks
per sample. Values are medians of six per-run means in milliseconds.
`scriptUpdate` includes fixture validation/reset work and other script handlers;
whole-update timing also includes engine simulation. Both versions perform the
same useful work: mixed supply transfers 1,000 items per tick in each version.

| Scenario | Old script ms | New script ms | Script change | Old update ms | New update ms | Update change |
|---|---:|---:|---:|---:|---:|---:|
| full | 4.3610 | 4.3569 | -0.1% | 4.8839 | 4.8321 | -1.1% |
| partial | 7.0576 | 7.0077 | -0.7% | 7.6707 | 7.6653 | -0.1% |
| mixed_supply | 7.3899 | 7.4387 | +0.7% | 7.9933 | 8.0100 | +0.2% |

Production timing is approximately unchanged: combined script means vary from
-0.7% to +0.7%, and whole-update means from -1.1% to +0.2%. Together with the
mixed callback results, this supports treating the change as a simplification
of scheduling state rather than a demonstrated general performance improvement.

## Reproduction and artifacts

The runner now accepts a retained source directory for `--old`/`--new` as well as
a Git revision or `WORKTREE`. It freezes that directory and records its path and
file hashes, allowing exact comparisons with an uncommitted previous snapshot.

```sh
export AUTO_FACTORIO='/Users/aaron/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio'
python3 benchmarks/run.py --old benchmarks/artifacts/supplied-queues-callback-final/sources/new \
  --new WORKTREE --mode callback --scenarios full partial no_supply \
  --budgets 10 1000 --samples 6 --iterations 4 --output benchmarks/artifacts/single-cursor-callback
python3 benchmarks/run.py --old benchmarks/artifacts/supplied-queues-callback-final/sources/new \
  --new WORKTREE --mode callback --scenarios mixed_supply \
  --budgets 10 1000 --samples 6 --iterations 4 --output benchmarks/artifacts/single-cursor-mixed
python3 benchmarks/run.py --old benchmarks/artifacts/supplied-queues-callback-final/sources/new \
  --new WORKTREE --mode callback --scenarios full partial no_supply --chests-per-bucket 1000 \
  --budgets 10 1000 --samples 6 --iterations 4 --output benchmarks/artifacts/single-cursor-many-chests
python3 benchmarks/run.py --old benchmarks/artifacts/supplied-queues-callback-final/sources/new \
  --new WORKTREE --mode production --scenarios full partial mixed_supply \
  --budgets 1000 --samples 6 --ticks 1200 --output benchmarks/artifacts/single-cursor-production
```

Use fresh output directories when rerunning. Source snapshots, manifests, raw
logs, fixtures, saves, and parsed samples remain in these local, Git-ignored
artifact directories:

- [Standard callback samples](../benchmarks/artifacts/single-cursor-callback/callback-results.json) and [manifest](../benchmarks/artifacts/single-cursor-callback/sources.json).
- [Mixed callback samples](../benchmarks/artifacts/single-cursor-mixed/callback-results.json) and [manifest](../benchmarks/artifacts/single-cursor-mixed/sources.json).
- [Many-chest samples](../benchmarks/artifacts/single-cursor-many-chests/callback-results.json) and [manifest](../benchmarks/artifacts/single-cursor-many-chests/sources.json).
- [Production samples](../benchmarks/artifacts/single-cursor-production/production-results.json) and [manifest](../benchmarks/artifacts/single-cursor-production/sources.json).

All four runs used these exact runtime hashes; the new hash matches `control.lua`:

- Old SHA-256: `5b84c550e19247664dc897b14a8c80d01722feb23e7fefa0d3734ac2ce5783e6`
- New SHA-256: `6c619c0807db44d1325763299876bfb713768dcd421530683b345113c19ea7ed`

## Validation

Lua regression checks pass, including group removal before/after/at the current
position, tail removal/wraparound, reactivation, shrinking current/noncurrent
groups, empty-to-active transitions, and read-only loading midway through a
group. Existing demand, supply, budget, routing, conservation, and lifecycle
checks also pass. Real Factorio's 24-tick lifecycle fixture and supply fixture
upgraded from v1.2.2 pass. Python executable-discovery checks pass. All measured
benchmark passes/ticks pass the fixture's inventory and conservation assertions.

The [event-driven routing contract](EVENTS.md) and previous gameplay coverage
limits are unchanged. This run does not measure group activation/deactivation
latencies or the user's own save. No-chest shutdown is covered by the lifecycle
checks; its production benchmark was not repeated for this cursor-only change.
