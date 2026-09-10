# Refill ledger follow-up: 10,000 entities

The revised engine restores per-tick Lua supply accounting and batched chest
debits, with demand-driven snapshots and the current gameplay fixes. These are
fresh paired comparisons against both historical engines on the standalone
Factorio installation; they do not combine timings from the earlier Steam runs.

Against immediate transfers, top-up callbacks took **26–34% less time** and
empty-to-full callbacks took **15–37% less time** across the four budgets.
At 1,000 entities/tick, whole-update time fell **20–22%** in both sustained-demand
cases, with improvements in all six paired production samples. At the default
budget, whole-update savings were much smaller: about 2%.

Original batching remains faster in some cases. The revised default-budget
top-up callback took 23% more time (about 0.014 ms/callback), while its whole-update
mean was within 1% of the original. At budget 1,000, revised production means
were 4.2% higher for top-ups and 0.8% higher for empty-to-full refills. The revised
engine preserves force isolation, existing item/quality preferences, and the
later player behavior; these comparisons include their costs alongside the
accounting changes. They do not isolate individual API costs.

## Sources and method

- Original batched engine: `8af5786eeb619b341df77e74effc4c4372705496`.
- Immediate-transfer engine: `19f9953889f965cb59d9be0ba93a02866eb41b45`.
- Revised engine: working-tree snapshot based on `17d69cc`, with `control.lua` SHA-256
  `ee82e35fce54e38bc15a12a99c87904a76d270611378cca7fdfb8866c059c9f2`.
- Factorio 2.1.17, build 87315, standalone macOS ARM64 at
  `/Applications/factorio.app/Contents/MacOS/factorio`; Apple M2 Ultra, macOS 15.7.4.
- Bundled base, elevated-rails, quality, recycler, and space-age mods; default
  48-slot, 10× compressed chests. Sources and per-file hashes are retained.

The [harness](../benchmarks/README.md) visits 10,000 real entities per pass:
5,000 gun turrets and 5,000 stone furnaces, split across ten surface pools.
Callback timing uses all nine scenarios and budgets 10, 100, 1,000, and 10,000,
with six samples, four timed passes per cell, warmup, and alternating version
order. Across both comparisons, all 3,456 timed passes (34,560,000 entity visits)
and 864 warmup passes passed the expected-count and conservation assertions.

The production comparisons use normal tick/load handlers, budgets 10 and 1,000,
and sustained `partial` and `empty` demand. Each comparison has 48 runs: six
samples per version/case, 12,000 ticks at budget 10 and 1,200 at budget 1,000.
The first 2,000/60 ticks are excluded, leaving 10,000/1,140 measured ticks per run.
Both comparisons together validate 633,600 updates and 63,360,000 entity visits.

Prototypes and benchmark-relevant settings match. The runner permits only the
known player ammo delay setting addition in the revised snapshot; the timed
fixture has no players. Each run freezes complete mod sources before launching.

## Callback results

Values are medians of six sample mean times. Negative changes mean less time.
Each baseline and revised value comes from its own paired run; revised timings
can differ between the two comparisons. These are average callback costs, not
individual-callback tail latencies.

| Baseline | Entities/tick | Workload | Baseline ms/callback | Revised ms/callback | Change | Faster pairs |
|---|---:|---|---:|---:|---:|---:|
| Immediate | 10 | Full | 0.0437 | 0.0300 | -31.3% | 6/6 |
| Immediate | 10 | At 9 of 10 | 0.0879 | 0.0652 | -25.8% | 6/6 |
| Immediate | 10 | Empty to full | 0.0785 | 0.0670 | -14.6% | 6/6 |
| Immediate | 10 | No matching supply | 0.0971 | 0.0491 | -49.4% | 6/6 |
| Immediate | 1,000 | Full | 3.9725 | 2.9075 | -26.8% | 6/6 |
| Immediate | 1,000 | At 9 of 10 | 8.3835 | 5.7615 | -31.3% | 6/6 |
| Immediate | 1,000 | Empty to full | 7.6724 | 5.0729 | -33.9% | 6/6 |
| Immediate | 1,000 | No matching supply | 8.5730 | 4.2671 | -50.2% | 6/6 |
| Batched | 10 | Full | 0.0560 | 0.0294 | -47.5% | 6/6 |
| Batched | 10 | At 9 of 10 | 0.0626 | 0.0770 | +23.0% | 0/6 |
| Batched | 10 | Empty to full | 0.0649 | 0.0604 | -6.9% | 4/6 |
| Batched | 10 | No matching supply | 0.0448 | 0.0444 | -0.9% | 4/6 |
| Batched | 1,000 | Full | 4.1090 | 2.7937 | -32.0% | 6/6 |
| Batched | 1,000 | At 9 of 10 | 5.8805 | 6.0700 | +3.2% | 1/6 |
| Batched | 1,000 | Empty to full | 5.0998 | 5.1606 | +1.2% | 2/6 |
| Batched | 1,000 | No matching supply | 4.6066 | 4.3991 | -4.5% | 4/6 |

Complete matrices and sample means: [against immediate transfers](../benchmarks/results/2026-09-09-ledger/vs-immediate-callback.md)
and [against original batching](../benchmarks/results/2026-09-09-ledger/vs-batched-callback.md).

The dense-inventory case at budget 10 was the one callback cell whose revised
median exceeded immediate transfers: +1.1%, with slower results in five of six
pairs (paired changes ranged from -13.9% to +14.4%). Full inventories improved
in all six pairs at every budget against both baselines. Results near parity,
especially against original batching, should be read with the sample variation.

## Advancing-tick results

These are whole-update means, including the demand fixture, other engine work,
and GC. Each table value is the median of six per-run statistics. They must not
be interpreted as the mod callback alone or a prediction of player-save UPS.

| Baseline | Entities/tick | Workload | Baseline update ms | Revised update ms | Change | Baseline p99 ms | Revised p99 ms | Faster mean pairs |
|---|---:|---|---:|---:|---:|---:|---:|---:|
| Immediate | 10 | At 9 of 10 | 0.871 | 0.855 | -1.8% | 1.840 | 1.638 | 4/6 |
| Immediate | 10 | Empty to full | 0.858 | 0.837 | -2.5% | 1.620 | 1.504 | 5/6 |
| Immediate | 1,000 | At 9 of 10 | 10.914 | 8.708 | -20.2% | 23.423 | 20.271 | 6/6 |
| Immediate | 1,000 | Empty to full | 9.233 | 7.224 | -21.8% | 19.198 | 17.395 | 6/6 |
| Batched | 10 | At 9 of 10 | 0.859 | 0.864 | +0.6% | 1.514 | 1.863 | 3/6 |
| Batched | 10 | Empty to full | 0.841 | 0.841 | +0.1% | 1.508 | 1.508 | 3/6 |
| Batched | 1,000 | At 9 of 10 | 8.288 | 8.635 | +4.2% | 18.132 | 20.104 | 0/6 |
| Batched | 1,000 | Empty to full | 7.019 | 7.074 | +0.8% | 16.685 | 16.989 | 2/6 |

Per-run whole-update, script-update, and incremental GC statistics:
[immediate baseline](../benchmarks/results/2026-09-09-ledger/vs-immediate-production-samples.json),
[batched baseline](../benchmarks/results/2026-09-09-ledger/vs-batched-production-samples.json).

## Correctness and limits

`lua tests/supply.lua` passed ledger/debit checks, rejected and partial transfers,
exact quality and existing-stack preference, multiple consumers sharing limited
supply, restocking next tick, surface/force isolation, representative replacement,
deconstruction, locomotive slot limits, player delay, and upgrade cache cleanup.
The mocks also simulate failed `set_stack`, partial slot placement, and an item
eligible as both fuel and ammo sharing a single balance.

The standalone Factorio supply integration test passed normal tick/load checks
for independent surface/force pools, quality, shortages, representative replacement,
filtered character ammo, incompatible turret ammo, and real partial insertion
into a capacity-limited turret with barred supply. The standalone player test
passed cursor holding, delayed refill, and gun removal checks. See
[automated testing](TESTING.md) for commands and scope.

These synthetic performance cases cover normal-quality turret ammo and generic
burner fuel. They do not time characters, trains, mixed qualities, real combat,
multiplayer, or migration. Callback timing includes GC inside its timer but not
all between-tick GC. The production fixture checks/resets demand after the mod
and is included in update timings. Use a representative save for actual UPS impact.

## Reproduce

Run sequentially from the repository root, using new output directory names:

```sh
python3 benchmarks/run.py --new WORKTREE --output benchmarks/artifacts/ledger-vs-batched-callback
python3 benchmarks/run.py --old 19f9953889f965cb59d9be0ba93a02866eb41b45 \
  --new WORKTREE --output benchmarks/artifacts/ledger-vs-immediate-callback
python3 benchmarks/run.py --mode production --new WORKTREE \
  --scenarios partial empty --budgets 10 1000 --ticks 1200 \
  --output benchmarks/artifacts/ledger-vs-batched-production
python3 benchmarks/run.py --mode production --old 19f9953889f965cb59d9be0ba93a02866eb41b45 \
  --new WORKTREE --scenarios partial empty --budgets 10 1000 --ticks 1200 \
  --output benchmarks/artifacts/ledger-vs-immediate-production
```

On macOS the runners prefer `/Applications/factorio.app` before `PATH` and do
not automatically search Steam. Explicit `--factorio`/`AUTO_FACTORIO` overrides
still take precedence. The reported runs explicitly selected the standalone executable.

Raw logs, source snapshots, configs, saves, and individual sweep measurements
are retained in `benchmarks/artifacts/2026-09-09-ledger-vs-{immediate,batched}-{callback,production}/`.
Each compact dataset includes its corresponding `*-metadata.json` with source
hashes, executable/data paths, settings exception, and configuration.
Both artifact and result directories are ignored by Git; preserve or share them
alongside this report when the underlying measurements are needed.
