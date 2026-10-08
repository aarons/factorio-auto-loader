# Refill benchmarks with 10,000 entities

The [single-cursor follow-up](../documentation/BENCHMARK_RESULTS_2026-10-07_CURSOR.md)
compares the simplified traversal with the preceding per-group-cursor snapshot.

The [supplied-queue follow-up](../documentation/BENCHMARK_RESULTS_2026-10-07_QUEUES.md)
compares v1.2.3 with the latest membership implementation, including full consumers
and 1,000 linked chests per bucket.

The [chest membership report](../documentation/BENCHMARK_RESULTS_2026-10-07_MEMBERSHIP.md)
compares the new registry against the pre-change implementation, including true
no-chest worlds and mixed supplied/unsupplied consumers.

See the [September 9, 2026 results](../documentation/BENCHMARK_RESULTS_2026-09-09.md)
for the comparison of the batched and immediate-transfer implementations.
The [ledger follow-up](../documentation/BENCHMARK_RESULTS_2026-09-09_LEDGER.md)
compares the revised engine against both with the standalone macOS installation.

Run from the repository root with Python 3 and an installed Factorio. The runner
checks `/Applications/factorio.app/Contents/MacOS/factorio` first, then `PATH`.
It does not automatically search Steam. Explicit `--factorio` and `--data`
(also `AUTO_FACTORIO` and `AUTO_FACTORIO_DATA`) override discovery. Data is
otherwise located relative to the selected executable. It never edits the installed mod
or normal Factorio user directory. Output directories must not already exist.

```sh
python3 benchmarks/run.py --output benchmarks/artifacts/callback
python3 benchmarks/run.py --mode production --output benchmarks/artifacts/production \
  --scenarios full partial empty --budgets 10 100 1000 10000 --ticks 120
```

Run these sequentially, with other heavy workloads stopped. They default to the
exact old commit `8af5786eeb619b341df77e74effc4c4372705496` and new commit
`19f9953889f965cb59d9be0ba93a02866eb41b45`, six samples, and alternating version
order. `--old` and `--new` can select other compatible revisions or `WORKTREE`.
The runner freezes each complete mod source at startup and records per-file
hashes; later working-tree edits do not affect that run. For example:

```sh
python3 benchmarks/run.py --new WORKTREE --output benchmarks/artifacts/revised-vs-batched
python3 benchmarks/run.py --old 19f9953889f965cb59d9be0ba93a02866eb41b45 \
  --new WORKTREE --output benchmarks/artifacts/revised-vs-immediate
```

The exported
local function wrapper is specific to these implementations and must be reviewed
when testing future code.

In standard scenarios, every pass visits all **10,000 real entities**, consisting of 5,000 gun turrets
and 5,000 stone furnaces. Per-tick budgets of 10, 100, 1,000, and 10,000 mean that
a pass takes 1,000, 100, 10, or 1 callbacks. There are ten surfaces, each with
1,000 consumers and one default 48-slot, 10× compressed supply chest. A single
default chest cannot hold enough coal and magazines to fill 10,000 empty
consumers at once. Separate surfaces preserve equivalent pool behavior in both
versions; the old version cannot isolate multiple forces on one surface.

Supplied tests stock each pool with 5,000 firearm magazines and 5,000 coal.
Every consumer has a target of 10. Qualities are normal. There are no enemies or
smelting ingredients, and demand is synthetic, so natural consumption does not
change the expected counts.

| Scenario | Consumer counts before each pass | Items transferred per pass |
|---|---|---:|
| `full` | All 10 | 0 |
| `active_10pct` | 10% at 9; remaining 90% at 10 | 1,000 |
| `mixed_half` | Equal shares at 0, 5, 9, and 10 | 40,000 |
| `partial` | All 9 | 10,000 |
| `half` | All 5 | 50,000 |
| `empty` | All 0 | 100,000 |
| `no_supply` | All 9; no fuel/ammo in supply | 0 |
| `depleted` | All 9; supply covers half the demand | 5,000 |
| `dense` | All 9; 30 additional non-fuel item identities in supply | 10,000 |

The normal mixed supply includes iron plates. The dense supply occupies 45
slots with 32 item identities. Exact snapshots, hashes, enabled mods, settings,
fixture, map configuration, logs, saves, and parsed results are retained in the
output directory. Generated artifacts are ignored by Git; preserve the directory
when sharing a report. No automated Git commit or mod installation is performed.

## Callback timing

The callback mode loads both exact `control.lua` files in one temporary mod,
with separate storage and stubbed event registration. Chest prototypes and
startup settings are copied from the new revision; the runner rejects differing
`data.lua` or `settings.lua` between revisions, with one explicit exception:
the later `auto-loader-player-ammo-refill-delay` setting is allowed because the
fixture has no players. The exact setting addition is checked; all other
differences still fail. Both default historical commits have identical settings.

It warms one complete empty-to-full pass for every engine/sample/budget/scenario,
then measures four complete passes with Factorio's own profiler. Preparation,
inventory reset, validation, and logging are outside the timer. The timed region
includes the small Lua loop dispatching callbacks. Budgets and scenario order
reverse between odd and even samples too.

After **every** timed pass, assertions check each consumer's expected count and
conservation of fuel and ammo across consumers and all supply inventories. The
shortage cases have equal, explicitly verified outcomes. A failure aborts the
run. Each version performs 8,640,000 measured entity visits in the default
matrix (36 cells × 6 samples × 4 passes × 10,000 entities).

`callback-results.json` contains each sweep measurement.
`callback-summary.json` retains the sample means and paired percentage changes.
`callback-results.md` reports the median of six sample means, with both complete
sweep time and average callback cost. Sweep timings are not individual-callback
tail latencies. GC incurred inside the timed region remains part of the result;
this mode does not include all normal between-tick garbage collection. Warm
inventory resets can also affect CPU caches. Use production timing as a second
check.

## Advancing-tick timing

Production mode installs each **complete, unmodified production snapshot** with
a companion fixture mod. It creates two equivalent deterministic saves, one per
revision, using the same seed, creation order, entities, supplies, and settings.
Separate initialization gives each implementation its proper storage layout;
this is not a migration benchmark. Build events register real entities, and
normal production `on_tick` and `on_load` handlers run.

The fixture changes only the budget setting's default in the data stage. Its
dependent tick handler runs after production, checks the visited batch and chest
debits, restores that supply, and resets that batch's demand. This provides
sustained access every time each entity is visited, with assertions on every
update. A completion marker and the expected number of verbose timing rows are
required. Furnaces/turrets remain real simulated entities.

Each sample starts again from its version's saved initial state. The runner
uses at least 12 complete passes and at least `--ticks` updates (120 in the
command above). The first two passes or 60 ticks, whichever is longer, are
excluded from the summarized steady-state timings. Thus the example uses
12,000/1,200/120/120 total ticks for budgets 10/100/1,000/10,000.

`production-results.json` retains per-run mean, median, p95, p99, and maximum
for whole-update, script-update, and incremental Lua GC timings, in milliseconds.
The report takes the median of six per-run statistics. Raw logs keep individual
tick timings. The parser checks verbose nanosecond totals against Factorio's
reported millisecond total.

Whole-update timing **includes the demand fixture's checks and resets**, other
engine work, and all ten surfaces. It is a controlled synthetic save comparison,
not a prediction of UPS in a player's factory. `scriptUpdate` also includes the
fixture, so it must not be presented as the Auto-Loader callback alone. The
callback mode supplies that isolated comparison. Factorio 2.1.17 crashed while
printing a selected subset of verbose counters during pilot testing; `all`
completed successfully and is used here.

With only 60 retained ticks, nearest-rank p99 equals the observed maximum and is
not a stable tail estimate. Extend runs when using tails to draw conclusions:

```sh
python3 benchmarks/run.py --mode production --output benchmarks/artifacts/production-extended \
  --scenarios partial empty --budgets 1000 --ticks 1200
```

This leaves 1,140 measured ticks per sample at budget 1,000. The
[September 9 report](../documentation/BENCHMARK_RESULTS_2026-09-09.md) uses these
extended measurements for that budget.

## Scope

The standard matrix compares the commits as a whole, including discovery, caching, transfers,
and bookkeeping; it does not isolate the cost of one API method. It covers
turret ammo and generic burner fuel. Apart from the optional player-only idle scenario below, it does not measure characters, trains,
quality mixtures, rejected insertion/refunds, save migration, multiplayer, or
real combat. A player's representative save remains necessary to quantify
their actual UPS change. Correctness fixes in the new commit should be considered
separately from any performance decision.

See [the original benchmarking guide](../documentation/BENCHMARKING.md) for
API and CLI background.

## Chest membership scenarios

Compare the pre-membership revision with the working tree using production mode:

```sh
python3 benchmarks/run.py --mode production --old HEAD --new WORKTREE \
  --output benchmarks/artifacts/membership \
  --scenarios no_chest mixed_supply no_supply partial \
  --budgets 1000 --ticks 1200 --samples 6
```

Use the pre-change commit instead of `HEAD` once these changes are committed.
No-chest scenarios require production mode so conditional `on_tick`
registration and load restoration run normally. Mixed supply also supports the
equal-work callback run described below:

- `no_chest`: 10,000 consumers at 9, across ten surfaces, with zero chests.
- `mixed_supply`: five surfaces have a player-force chest and five have no
  chests. Half the consumers on every surface belong to a friendly force with
  no chest. The 2,500 supplied consumers refill to 10; 7,500 stay at 9.
- `player_no_chest`: one actual player with a pistol and 9 magazines, no
  chests, and no other consumers. The runner opens a separate graphical client
  to create that player and an isolated autosave, then uses normal advancing-tick
  benchmarks on the save. This requires a working graphical client. Its effective
  budget is 1 regardless of the selected matrix budget.

`no_supply` now also works in production mode and leaves existing chests
completely empty (including no iron plates). `partial` provides active supply as a comparison. All assertions
run after every production tick, including unchanged unsupplied consumer counts
and exact supplied-pool debits. Mixed forces are friends to prevent combat from
changing demand. Callback wrappers understand the new membership storage and
conditional tick subscription; the historical callback scenario matrix remains
available.

Run benchmark processes sequentially. Production `scriptUpdate` includes the
fixture's inventory checks and resets; a disabled Auto-Loader handler does not
make that combined counter zero. Use per-run measurements and report this scope
when discussing improvements. `production-results.json` contains script timing
as well as whole-update timing. The player-only scenario and older graphical
player tests cannot run if Steam fails to launch its graphical client.

## Supplied queues and many linked chests

Use `--old 7468a38 --new WORKTREE` to compare with the latest membership report.
Both callback and production modes accept `--chests-per-bucket` (1–1,000,
default 1). Additional chests share the same surface/force inventory; supply
stock and consumer demand stay constant. For example:

```sh
python3 benchmarks/run.py --mode callback --old 7468a38 --new WORKTREE \
  --output benchmarks/artifacts/many-chests \
  --scenarios full partial no_supply --budgets 10 1000 \
  --samples 6 --iterations 4 --chests-per-bucket 1000
```

The callback wrapper registers every chest, not just the inventory representative.
With 1,000 chests per bucket this exercises 10,000 physical chests across ten
pools. Fixture construction and stock resets remain outside the callback timer.

Production `mixed_supply` now follows each implementation's queue: the old
queue visits 1,000 global consumers per tick, while the supplied-only queue
visits 1,000 of the 2,500 supplied consumers. The old implementation transfers
250 items per tick on average; the new one transfers 1,000. This is a throughput
comparison, not equal useful work per tick. Report both tick cost and transfers
per tick (or cost per transfer). All other production scenarios keep equal work.
The fixture validates the exact scheduled batch and debits after every tick,
and rotates a separate check over all dormant consumers every ten ticks in
both versions. These extra checks mean mixed-world absolute script times are
not directly comparable with the earlier report's fixture. Source detection for
this schedule is specific to `storage.consumer_buckets` and should be reviewed
when benchmarking other implementations.

A separate callback invocation with `--scenarios mixed_supply` compares equal
useful work: each measured pass refills the same 2,500 supplied consumers once.
The baseline needs 10,000 global visits; supplied queues need 2,500. Callback
counts are recorded per version. At budget 1,000, the new version uses three
callbacks (including 500 extra full-consumer checks); at budget 10 it uses 250,
versus 1,000 for the baseline. Unsupplied inventories and item conservation are
checked after every pass. This scenario must run separately because it changes
the fixture topology. No-chest shutdown remains a production-mode measurement.

To compare an uncommitted implementation captured by an earlier run, `--old` and
`--new` also accept a source snapshot directory, such as
`--old benchmarks/artifacts/supplied-queues-callback-final/sources/new`.
The runner copies it into the new output directory and records its absolute path
and all source hashes, just as it freezes Git revisions and `WORKTREE`.
