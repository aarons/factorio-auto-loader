# Refill performance: 10,000 entities per pass

The batched implementation is faster under sustained refill demand in this
comparison. The newer implementation saves work when little needs refilling at
the default budget, but the measurements do **not** support a general performance
improvement from replacing the Lua supply ledger with immediate API transfers.

The supplied refill-heavy cases took **29–53% longer** with the new implementation.
Partially filled consumers without supply took **97–130% longer**. Every one of
those workload/budget combinations was slower in all six paired samples. Both
versions delivered identical, correct item counts in every measured pass.

## Versions and environment

- Old, batched: `8af5786eeb619b341df77e74effc4c4372705496`.
- New, immediate transfers: `19f9953889f965cb59d9be0ba93a02866eb41b45`.
- Factorio 2.1.17, build 87315, Steam, native macOS ARM64.
- Mac Studio, Apple M2 Ultra, 24 CPU cores, 192 GB RAM; macOS 15.7.4.
- Bundled base, elevated-rails, quality, recycler, and space-age mods enabled.
- Default 48-slot chests with 10× stack compression; normal-quality items.

These are the exact requested revisions, not the current working tree. Their
`data.lua` and `settings.lua` are identical. No production code was changed by
this benchmark work.

## Workload and controls

Every pass visits **10,000 real entities: 5,000 gun turrets and 5,000 stone
furnaces**. Ten surfaces each contain 1,000 consumers and one independent supply
chest. This supplies enough inventory capacity for full refills while preserving
default chest settings and equivalent old/new force semantics. Each consumer's
target is ten items; supplied chests start with 5,000 magazines and 5,000 coal.

The callback matrix covers nine inventory patterns and four budgets: 10, 100,
1,000, and 10,000 entities per callback. Lower budgets preserve the cursor across
callbacks until all 10,000 entities have been visited. The largest budget also
tests **10,000 entities in a single callback**.

Each version gets six samples of four timed passes per case, alternating version
order and reversing scenario/budget order. One full pass warms each configuration
first. Preparation, inventory resets, validation, and logging are outside the
Factorio profiler. Each measured pass validates every entity's count and item
conservation across consumers and supply. A shortage is an explicit workload,
never an accidental consequence of insufficient fixture capacity.

The matrix completed **1,728 timed passes and 17,280,000 measured entity visits**,
plus 432 validated warmup passes. All assertions passed. Values below are the
median of six sample means; callback values divide each sweep by its callback
count. These are averages, not individual-callback p99 timings.

## Default budget: 10 entities per tick

| Workload | Items moved per pass | Old ms/callback | New ms/callback | New time change |
|---|---:|---:|---:|---:|
| All full | 0 | 0.0441 | 0.0382 | −13.4% |
| 10% need one item | 1,000 | 0.0450 | 0.0393 | −12.7% |
| Equal shares empty, half full, at 9, and full | 40,000 | 0.0506 | 0.0652 | +28.8% |
| All at 9 of 10 | 10,000 | 0.0555 | 0.0773 | +39.3% |
| All half full | 50,000 | 0.0548 | 0.0781 | +42.6% |
| All empty, filled fully | 100,000 | 0.0545 | 0.0713 | +30.8% |
| All at 9, no matching supply | 0 | 0.0440 | 0.0876 | +99.1% |
| All at 9, supply covers half the demand | 5,000 | 0.0525 | 0.0786 | +49.9% |
| All at 9, 30 additional supply item identities | 10,000 | 0.0811 | 0.0830 | +2.4% |

The dense-inventory result at this budget is inconclusive: paired changes ranged
from 22% faster to 39% slower. Fully stocked consumers were faster with the new
code in all six pairs. The 10%-active case was faster in five of six pairs.
The large refill and shortage regressions consistently survived the run-to-run
variation; their exact percentages should still be treated as machine-specific.

## Larger budgets and refill latency

| Entities/tick | Revisit interval at 60 UPS | Top-up old/new ms/callback | Empty-to-full old/new ms/callback |
|---:|---:|---:|---:|
| 10 | 16.67 seconds | 0.0555 / 0.0773 | 0.0545 / 0.0713 |
| 100 | 1.67 seconds | 0.4839 / 0.7381 | 0.4689 / 0.6568 |
| 1,000 | 0.167 seconds | 5.1239 / 7.4465 | 4.4912 / 6.3857 |
| 10,000 | 0.0167 seconds, if 60 UPS can be maintained | 47.7867 / 70.4900 | 42.0041 / 62.0763 |

The revisit intervals follow from the round-robin scheduler with 10,000 valid
registered entities. They describe the maximum wait after an entity has just
been visited, assuming supply is available and game speed remains 60 UPS.
Both revisions use the same scheduling budget, so neither inherently reaches
entities sooner in game ticks.

At the default budget, the sustained top-up regression costs about **0.022 ms
per tick**, only 0.13% of the complete 16.67 ms update budget. The refill wait
across a large registry is therefore a more visible responsiveness issue than
that small absolute CPU difference, unless a save is already CPU-constrained.
At 1,000 entities/tick, the same difference is **2.32 ms per tick**, about 14%
of the entire update budget. At 10,000 entities/tick, both implementations'
measured callbacks exceed the entire 60-UPS budget even before other game work.

## Advancing game ticks with the production mods

Normal-tick testing confirms the refill regression. These measurements use the
complete, unmodified production revisions, normal event handlers, and real saved
registries. A dependent fixture validates each visited batch, restores consumed
supply, and resets demand after production runs, keeping access sustained.

| Entities/tick | Workload | Old update ms | New update ms | Change | Old p99 ms | New p99 ms |
|---:|---|---:|---:|---:|---:|---:|
| 10 | All at 9 of 10 | 0.814 | 0.838 | +2.9% | 1.308 | 1.873 |
| 10 | Empty-to-full | 0.791 | 0.809 | +2.3% | 1.216 | 1.309 |
| 1,000 | All at 9 of 10 | 7.150 | 9.434 | +31.9% | 15.103 | 18.680 |
| 1,000 | Empty-to-full | 6.169 | 7.992 | +29.5% | 13.987 | 15.695 |

These are **whole-update timings, including fixture checks/resets and other
engine work**, not isolated Auto-Loader times. Means and p99 values are the
medians of six independent per-run statistics. There are 12,000 ticks per run
at budget 10 and 1,200 at budget 1,000. The first 2,000 and 60 ticks,
respectively, are excluded for warmup, leaving 10,000 and 1,140 measured frames
per sample. The two versions start from separately initialized, equivalent
deterministic saves to retain their proper storage layouts.

The selected comparison completed **48 production runs, 316,800 game updates,
and 31,680,000 validated entity visits**. Every per-update count and chest-debit
assertion passed. The original 120-tick runs at budget 1,000 also passed, but
were extended because only 60 post-warmup frames were insufficient for useful
p99 estimates; those short runs are excluded from this table.

The default-budget whole-update difference is small: the new top-up run was
slower in five of six pairs, and empty-to-full was slower in all six. At budget
1,000, both workloads were slower in all six pairs. In the sustained top-up
case, the newer version's median run p99 exceeds the 16.67 ms budget for 60 UPS,
while the older version's stays below it. This indicates less room for the rest
of a busy factory; it does not predict a specific player's FPS or UPS.

Detailed [production statistics](../benchmarks/results/2026-09-09/production-samples.json)
and [dataset metadata](../benchmarks/results/2026-09-09/production-metadata.json)
identify the selected runs. Raw logs and saves are in the
[initial production artifacts](../benchmarks/artifacts/2026-09-09-production/)
and [extended production artifacts](../benchmarks/artifacts/2026-09-09-production-extended/).

## Why the workloads differ

Code inspection is consistent with the timing results:

- With full inventories, lazy discovery avoids the old unconditional supply
  snapshot and bookkeeping. This helps especially when the per-tick budget is small.
- With many consumers needing items, the old code amortizes supply reads and
  removals across the callback. The new code removes supply for each transfer,
  checks insertable capacity, scans existing stacks, and allocates Lua request
  and attempt tables. Removing the supply-count ledger does not eliminate Lua
  allocation or processing.
- During shortages, the old snapshot lets later consumers see exhausted supply
  through Lua lookups. The new occupied-inventory path continues attempting
  transfers through the inventory API.

This compares the complete commits. It does not separately attribute time to
individual API functions, caching changes, or Lua allocations.

## Interpretation and reproducibility

For sustained, high-access refilling, batching wins this comparison. A useful
next optimization experiment would combine demand-driven discovery with a
per-callback supply ledger and batched debits, while retaining force isolation
and rejected-transfer preservation. This benchmark does not justify discarding
those correctness fixes or treating the old revision as an unconditional replacement.

These fixtures cover generic burner fuel and turret ammo with a single normal-
quality identity per supply category. They do not model trains, characters,
mixed-quality substitution, partial-insertion refunds, real combat, multiplayer,
or migration. Callback timing runs inside initialization, includes Lua loop
dispatch and GC occurring inside the timer, and benefits from freshly reset
inventories. Actual player-save UPS requires a representative factory save.

The [runner and methodology](../benchmarks/README.md) explain all scenarios and
the normal-tick fixture. The [complete callback matrix](../benchmarks/results/2026-09-09/callback.md),
[sample means](../benchmarks/results/2026-09-09/callback-samples.json), and
[source metadata](../benchmarks/results/2026-09-09/callback-metadata.json) accompany
this report. Individual sweep measurements, copied harness, settings, saves,
and raw logs are retained in
[the callback artifacts](../benchmarks/artifacts/2026-09-09-callback/).

```sh
python3 benchmarks/run.py --output benchmarks/artifacts/2026-09-09-callback
python3 benchmarks/run.py --mode production \
  --output benchmarks/artifacts/2026-09-09-production \
  --scenarios partial empty --budgets 10 1000 --ticks 120
python3 benchmarks/run.py --mode production \
  --output benchmarks/artifacts/2026-09-09-production-extended \
  --scenarios partial empty --budgets 1000 --ticks 1200
```

Use new output directory names to rerun. Run the commands sequentially.
