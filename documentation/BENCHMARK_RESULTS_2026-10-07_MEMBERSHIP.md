# Chest membership benchmark — October 7, 2026

The membership implementation removes refill ticks entirely when no chests
exist. In this synthetic 10,000-consumer world, combined script time decreased
64.8% with no chests and 27.8% with mixed supplied/unsupplied consumers. Existing
empty chests cost 3.2% more script time; active supply cost 1.2% more. These results
support the missing-supply optimization but do not establish a UPS improvement
for the reported player save.

## Production timing

Factorio 2.1.21 (mac-arm64 Steam), 10,000 consumers, a 1,000-visit tick budget,
1,200 ticks per run, and six alternating old/new samples per scenario. The first
60 ticks are excluded, leaving 1,140 measured ticks per run. Values below are
medians of six per-run means, in milliseconds per tick.

`scriptUpdate` includes Auto-Loader, the fixture's inventory assertions/resets,
and other script handlers. With Auto-Loader's tick disabled, fixture work remains.
Whole-update time also includes entity simulation and other engine work.

| Scenario | Old script ms | New script ms | Script change | Old update ms | New update ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| `no_chest` | 5.1404 | 1.8075 | -64.8% | 5.7312 | 2.1128 |
| `mixed_supply` | 5.5768 | 4.0269 | -27.8% | 6.2051 | 4.5143 |
| `no_supply` | 5.3034 | 5.4748 | +3.2% | 5.7749 | 6.0240 |
| `partial` | 6.6093 | 6.6854 | +1.2% | 7.1845 | 7.3647 |

- `no_chest`: zero physical chests on all ten surfaces. Consumers stay at 9.
- `mixed_supply`: five supplied surfaces and five without chests; half the
  consumers on each surface belong to a friendly force with no chest. The 2,500
  supplied consumers refill; 7,500 remain unchanged.
- `no_supply`: ten existing, completely empty chests. Refill ticks remain active
  so eventless restocking can be detected.
- `partial`: ten stocked chests, sustained one-item demand per consumer visit.

Every tick checks consumer counts and exact supply debits. The forces are friends
so combat cannot introduce uncontrolled demand. The modest supplied-case cost
reflects the additional eligibility gate; the gate runs even when demand is absent.
This benchmark has one chest per supplied bucket. Validation of known membership
costs O(chests in visited buckets) each tick, so many-chest worlds need separate
measurement.

## Isolated callback timing

A separate sequential callback run used six alternating samples, four measured
sweeps per sample, and budgets of 10 and 1,000. Each sweep visits 10,000 consumers;
preparation, resets, and assertions are outside the timer. This isolates the
callback and dispatch loop, rather than the advancing-tick fixture. It does not
capture all between-tick garbage collection, so differences from production
measurements are expected.

| Budget | Scenario | Old sweep ms | New sweep ms | Change | Old ms/callback | New ms/callback |
|---:|---|---:|---:|---:|---:|---:|
| 10 | full | 21.724 | 34.650 | +59.5% | 0.0217 | 0.0347 |
| 10 | partial | 58.902 | 59.498 | +1.0% | 0.0589 | 0.0595 |
| 10 | no_supply | 36.250 | 34.413 | -5.1% | 0.0362 | 0.0344 |
| 1000 | full | 20.430 | 29.742 | +45.6% | 2.0430 | 2.9742 |
| 1000 | partial | 48.896 | 50.223 | +2.7% | 4.8896 | 5.0223 |
| 1000 | no_supply | 29.026 | 32.532 | +12.1% | 2.9026 | 3.2532 |

Already-full consumers show a substantial relative regression: 45.6–59.5%.
At the default budget of 10, this is about 0.013 ms extra per callback. Previously,
full consumers returned before reading their surface/force; the required early
supply gate now reads those keys for every visit. Active transfer costs are much
closer to baseline. This tradeoff is retained to meet the early-gating contract;
this change should not be described as a universal refill speedup. Cached consumer
routing or supplied-only queues require separate handling of mobile consumers
and fairness, as deferred in the implementation plan.

[Callback results](../benchmarks/artifacts/membership-callback-final/callback-results.json)
and [source manifest](../benchmarks/artifacts/membership-callback-final/sources.json)
retain all samples. Reproduce with the production command's revision/executable
arguments, `--mode callback --scenarios full partial no_supply --budgets 10 1000
--samples 6 --iterations 4`, and a fresh output directory.

## Reproduction and artifacts

```sh
python3 benchmarks/run.py --mode production \
  --old b679e1030f3194f6e375bc2a6b7f63ef431fc55c --new WORKTREE \
  --output benchmarks/artifacts/membership-final \
  --scenarios no_chest mixed_supply no_supply partial \
  --budgets 1000 --ticks 1200 --samples 6 \
  --factorio '/Users/aaron/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio'
```

Choose a fresh output directory for a rerun. Measurements were sequential; no
other test/benchmark process ran concurrently with this final production run.
Pilot directories are excluded from these results.

Local artifacts (ignored by Git) include full source snapshots, per-file hashes,
fixture copies, saves, raw verbose timing logs, and parsed per-run statistics:

- [Production results](../benchmarks/artifacts/membership-final/production-results.json)
- [Production source manifest](../benchmarks/artifacts/membership-final/sources.json)
- [Whole-update report](../benchmarks/artifacts/membership-final/production-results.md)

The baseline is repository commit `b679e10`, with the v1.2.1 runtime. The new
runtime is the code shipped as v1.2.2; its production timing snapshot still has
v1.2.1 metadata because the migration-triggering version bump followed snapshot
capture. The measured `control.lua` exactly matches the final runtime:

- Old SHA-256: `285b3a474bf2f50eb622c47a466dbdae5aaf898f7608e1883f85ca35832cdff0`
- New SHA-256: `5be1992d6f145d1abc1953cbb3ef34b55a031076060e8efe1c327a80b9be131a`

## Validation limits

Lua regression tests cover membership, no-search refill processing, bounded
visits, read-only loading, negative lookup caching, qualities, conservation,
restocking, and existing refill rules. Real Factorio tests cover supply isolation,
active/no-chest save loading, destruction, death, force merging, cloning, surface
cleanup, and upgrading the old implementation.

The standalone client is 2.0.77, below the mod minimum. Steam 2.1.21 runs headless
integration tests and benchmarks, but graphical startup fails when macOS cannot
open its `steam://` restart URL. The graphical player test (including actual
player mining) and `player_no_chest` benchmark were attempted but could not run.
Their new fixture paths are unverified. No player-only measurement is reported.

Map-editor imports and robot/platform lifecycle events are covered by handler
mocks, not actual editor/robot/platform operations. Silent chest creation,
force/link-ID mutation by another mod, multiplayer determinism, and the user's
original save were not tested. Exact Factorio 2.1.20 runtime behavior was not run;
the integration version was 2.1.21.
