# Benchmarking refill changes inside Factorio

For the automated **10,000-entity** comparison of commits `8af5786` and
`19f9953`, including sustained demand during normal game ticks, use the
[benchmark runner](../benchmarks/README.md). The manual procedure below records
the original smaller experiment. See the
[September 9 results](BENCHMARK_RESULTS_2026-09-09.md) for the measured comparison.

Factorio can generate a map and run Lua without opening the game window. A
temporary mod can create real entities and inventories, prepare repeatable
workloads, and measure the refill engine with Factorio's own profiler.

This guide reproduces the approach used to compare the committed refill engine
with the uncommitted lazy-discovery implementation in September 2026. The original
run used Factorio **2.1.17**, the bundled Space Age mods, and the default chest
settings: **48 slots, 10× stack compression**.

## What this test measures

The harness calls each implementation's actual `on_tick` function against real
`LuaEntity`, `LuaInventory`, and `LuaItemStack` objects. It times only that callback;
map generation, entity creation, and inventory resets are outside the measurement.

These are synthetic callback invocations during `on_init`, not advancing game
ticks. Turrets do not fire, fuel does not burn, and other mods do not run between
the invocations. Demand is simulated by resetting inventories. This isolates the
refill algorithm, but does not measure whole-save UPS, lifecycle events,
save/load behavior, multiplayer determinism, or natural consumption patterns.

The wrapper gives each implementation its own registry, caches, and settings. It
suppresses event registration and object-destruction registration. Those parts
must be validated separately with the production mod installed.

## 1. Find the executable and create an isolated workspace

Requirements: a compatible Factorio installation, Git, Python 3, and a POSIX shell.
Run these snippets **from the repository root, in the same shell session**.

Use the standalone installation on this Mac. Both repository runners discover
it before `PATH`; neither automatically searches Steam:

```sh
export AUTO_FACTORIO_APP="/Applications/factorio.app"
export AUTO_FACTORIO="$AUTO_FACTORIO_APP/Contents/MacOS/factorio"
export AUTO_FACTORIO_DATA="$AUTO_FACTORIO_APP/Contents/data"
"$AUTO_FACTORIO" --version
"$AUTO_FACTORIO" --help

export AUTO_BENCH="$(mktemp -d "${TMPDIR:-/tmp}/auto-loader-bench.XXXXXX")"
export AUTO_BASELINE=HEAD
```

On Linux, set `AUTO_FACTORIO` to the installation's `bin/x64/factorio` and
`AUTO_FACTORIO_DATA` to its `data` directory. Explicit `--factorio`/`AUTO_FACTORIO`
and `--data`/`AUTO_FACTORIO_DATA` override runner discovery. Check the selected
version before comparing results.

`AUTO_BASELINE` can be any Git revision. `HEAD` compares the committed code with
the working copy. After committing a candidate, select its parent or another
known baseline explicitly.

All generated mods, configuration, logs, and saves go into `AUTO_BENCH`. Neither
the repository's Lua files nor the normal Factorio user directory is modified.

## 2. Copy both engines and wrap their entry points

This setup compares **control.lua only**. Both engines use the working copy's
chest prototype and startup settings. If those are part of the change being
evaluated, use separate complete mod installations instead.

```sh
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

repo = Path.cwd()
root = Path(os.environ['AUTO_BENCH'])
data = Path(os.environ['AUTO_FACTORIO_DATA'])
baseline = os.environ['AUTO_BASELINE']
info = json.loads((repo / 'info.json').read_text())
mod = root / 'mods' / f"{info['name']}_{info['version']}"
mod.mkdir(parents=True)
(root / 'user').mkdir()
(root / 'mod-path.txt').write_text(str(mod))

for name in ['info.json', 'data.lua', 'settings.lua']:
    shutil.copy2(repo / name, mod / name)
shutil.copytree(repo / 'graphics', mod / 'graphics')

# Enable the installed bundled mods explicitly; record the effective list too.
builtins = sorted(
    json.loads(p.read_text())['name']
    for p in data.glob('*/info.json') if p.parent.name != 'core'
)
(root / 'mods/mod-list.json').write_text(json.dumps({
    'mods': [{'name': name, 'enabled': True}
             for name in builtins + [info['name']]]
}, indent=2))
(root / 'config.ini').write_text(
    f'[path]\nread-data={data}\nwrite-data={root}/user\n'
    '[general]\ncheck-updates=false\n'
)
(root / 'map.json').write_text(json.dumps({
    'width': 256, 'height': 256,
    'default_enable_all_autoplace_controls': False,
    'autoplace_controls': {},
    'autoplace_settings': {
        kind: {'treat_missing_as_default': False}
        for kind in ['entity', 'tile', 'decorative']
    }
}))

prefix = '''local storage = {}
local settings = {global = {['auto-loader-entities-per-tick'] = {value=10}}}
local noop = function() end
local script = {
  on_init=noop, on_load=noop, on_configuration_changed=noop,
  on_event=noop, register_on_object_destroyed=noop,
}
'''
suffix = '''
return {
  tick = on_tick,
  setup = function(entities, chest, count)
    storage = {
      fillables={}, order={}, cursor=1, reps={},
      representative_chests={}, supply_candidates={},
    }
    settings.global['auto-loader-entities-per-tick'].value = count
    build_caches()
    link_chest(chest)
    for i=1,count do register_fillable(entities[i]) end
  end,
}
'''
sources = {
    'old': subprocess.check_output(
        ['git', 'show', f'{baseline}:control.lua'], text=True),
    'new': (repo / 'control.lua').read_text(),
}
metadata = {
    'baseline_commit': subprocess.check_output(
        ['git', 'rev-parse', baseline], text=True).strip(),
    'sha256': {},
}
for label, source in sources.items():
    (root / f'{label}-control.lua').write_text(source)
    (mod / f'{label}.lua').write_text(prefix + source + suffix)
    metadata['sha256'][label] = hashlib.sha256(source.encode()).hexdigest()
(root / 'sources.json').write_text(json.dumps(metadata, indent=2))
print(f'Benchmark workspace: {root}')
print(f'Temporary mod: {mod}')
PY
```

Appending the export table inside each copied module exposes its local functions
without modifying the production source. The local `storage`, `settings`, and
`script` variables shadow Factorio's globals only within that module.

**Adapt this wrapper when the implementation changes.** It currently depends on
`on_tick`, `build_caches`, `link_chest`, `register_fillable`, and the listed storage
fields. New event APIs, initialization requirements, tick-dependent scheduling,
or settings may require changes. Do not stub out behavior that is part of the
performance question itself.

## 3. Generate entities, simulate demand, and profile callbacks

This creates a grass area, one real Auto-Loader chest, and 1,000 gun turrets spaced
four tiles apart. For each scenario, only the first K turrets are registered, so
one callback visits all K. The callback's per-tick setting is also K.

The supply contains four fuel types and, when available, one ammo type. This
exercises a mixed supply inventory even though the consumers are gun turrets.

```sh
export AUTO_BENCH_MOD="$(cat "$AUTO_BENCH/mod-path.txt")"
cat > "$AUTO_BENCH_MOD/control.lua" <<'LUA'
local engines = {old=require('old'), new=require('new')}

script.on_init(function()
  local surface = game.surfaces[1]
  local tiles = {}
  for x=-70,70 do
    for y=-70,70 do
      tiles[#tiles+1] = {name='grass-1', position={x,y}}
    end
  end
  surface.set_tiles(tiles)
  local chest = assert(surface.create_entity{
    name='auto-loader-chest', position={-68,-68}, force='player',
  })
  chest.link_id = surface.index
  local supply = chest.get_inventory(defines.inventory.chest)
  assert(#supply >= 5, 'This fixture requires at least five chest slots')

  local entities, inventories = {}, {}
  for i=1,1000 do
    entities[i] = assert(surface.create_entity{
      name='gun-turret', force='player',
      position={((i-1)%32)*4-64, math.floor((i-1)/32)*4-64},
    })
    inventories[i] = entities[i].get_inventory(defines.inventory.turret_ammo)
  end
  assert(entities[1].prototype.automated_ammo_count == 10,
    'Adjust fixture counts for this turret target')

  local scenarios = {
    'full', 'active_one', 'active_all', 'empty_slots_no_supply',
    'partial_no_supply', 'depleted_mid_tick', 'incompatible_supply',
  }
  for sample=1,3 do
    for _,count in ipairs({10,100,1000}) do
      local iterations = count==10 and 2000 or (count==100 and 400 or 60)
      for _,scenario in ipairs(scenarios) do
        local versions = sample%2==1 and {'old','new'} or {'new','old'}
        for _,version in ipairs(versions) do
          local engine = engines[version]
          engine.setup(entities, chest, count)
          supply.clear()
          for i,name in ipairs({'wood','coal','solid-fuel','rocket-fuel'}) do
            supply[i+1].set_stack{name=name, count=100}
          end
          for i=1,count do inventories[i].clear() end
          supply[1].set_stack{name='firearm-magazine', count=1000}
          assert(supply[1].count == 1000, 'Fixture needs compressed stacks')
          engine.tick() -- Warm the registry handle and candidate caches.

          local timer = helpers.create_profiler(true) -- Initially stopped.
          local before_total
          for iteration=1,iterations do
            -- Reset demand and supply outside the measured section.
            if scenario=='empty_slots_no_supply' or scenario=='partial_no_supply' then
              supply[1].clear()
            elseif scenario=='incompatible_supply' then
              supply[1].set_stack{name='shotgun-shell', count=1000}
            else
              supply[1].set_stack{
                name='firearm-magazine',
                count=scenario=='depleted_mid_tick' and 1 or 1000,
              }
            end
            before_total = supply.get_item_count('firearm-magazine')
            for i=1,count do
              if scenario=='empty_slots_no_supply'
                  or scenario=='depleted_mid_tick'
                  or scenario=='incompatible_supply' then
                inventories[i].clear()
              else
                local stocked = scenario=='full' or (scenario=='active_one' and i>1)
                inventories[i][1].set_stack{
                  name='firearm-magazine', count=stocked and 10 or 9,
                }
              end
              before_total = before_total + inventories[i].get_item_count('firearm-magazine')
            end

            timer.restart() -- Accumulate without resetting the timer.
            engine.tick()
            timer.stop()
          end

          -- Validate the final iteration of every measured configuration.
          local actual = 0
          for i=1,count do
            actual = actual + inventories[i].get_item_count('firearm-magazine')
          end
          local expected = 0
          if scenario=='full' or scenario=='active_one' or scenario=='active_all' then
            expected = count*10
          elseif scenario=='partial_no_supply' then
            expected = count*9
          elseif scenario=='depleted_mid_tick' then
            expected = 1
          end
          assert(actual == expected, scenario..' '..version..': wrong refill amount')
          assert(actual + supply.get_item_count('firearm-magazine') == before_total,
            scenario..' '..version..': item conservation failed')
          timer.divide(iterations)
          log({'', 'PERF ', sample, ' ', count, ' ', scenario, ' ', version, ' ', timer})
        end
      end
    end
  end
end)
LUA
```

The three samples alternate old/new execution order to reduce ordering bias.
Within a sample, the profiler accumulates many callback durations and divides by
the number of invocations. The assertions are necessary: a version that transfers
fewer items must not be called faster solely because it did less work.

The shortage scenarios begin with warmed candidates and then withdraw supply.
The first measured invocation can therefore include stale-cache recovery; later
invocations measure the ongoing shortage. Measure cold-cache startup separately
if that is the question.

## 4. Run Factorio and summarize the measurements

```sh
"$AUTO_FACTORIO" \
  --config "$AUTO_BENCH/config.ini" \
  --mod-directory "$AUTO_BENCH/mods" \
  --create "$AUTO_BENCH/test.zip" \
  --map-gen-settings "$AUTO_BENCH/map.json" \
  > "$AUTO_BENCH/run.log" 2>&1

tail -n 15 "$AUTO_BENCH/run.log"
```

`--create` invokes the temporary mod's `on_init` while creating the save. No server
or network connection is required. Check for errors and a successful `Done.` before
using results. The log records the actual engine version, loaded mods, and paths;
verify them rather than assuming the intended installation was used.

```sh
python3 - <<'PY'
from collections import defaultdict
import os
from pathlib import Path
import re
from statistics import median

root = Path(os.environ['AUTO_BENCH'])
log = (root / 'run.log').read_text()
assert '\nDone.' in log, 'Factorio did not finish; inspect run.log'
rows = defaultdict(lambda: defaultdict(list))
pattern = r'PERF (\d+) (\d+) (\S+) (old|new) Duration: ([\d.]+)ms'
for sample, count, scenario, version, duration in re.findall(pattern, log):
    rows[int(count), scenario][version].append(float(duration))
assert len(rows) == 21, 'Expected seven scenarios at three budgets'
lines = [
    '| Entities/tick | Scenario | Old ms | New ms | Time change |',
    '|---:|---|---:|---:|---:|',
]
for (count, scenario), versions in sorted(rows.items()):
    assert len(versions['old']) == len(versions['new']) == 3, 'Incomplete samples'
    old, new = median(versions['old']), median(versions['new'])
    lines.append(f'| {count} | {scenario} | {old:.6f} | {new:.6f} | {(new/old-1)*100:+.1f}% |')
report = '\n'.join(lines) + '\n'
(root / 'results.md').write_text(report)
print(report)
PY
```

Negative time change means faster; positive means slower. The reported number is
the median of three sample averages, not the median of individual callbacks.
Adapt the parser's expected row/sample counts when changing the workload matrix.

Keep `sources.json`, both source snapshots, the temporary harness, configuration,
effective `mod-list.json`, map settings, and logs with any published result.
Temporary directories may be cleaned by the OS, so copy the evidence to a durable
location when needed.

## Interpreting and extending the test

At 60 UPS, the entire game has approximately **16.67 ms per update**. A callback
changing from 0.05 ms to 0.075 ms is a 50% increase in that callback's time, not a
50% reduction in game UPS. Report absolute milliseconds alongside percentages.

The original mixed-supply test at 10 entities/tick measured approximately:

| Workload | Committed | Candidate | Callback time change |
|---|---:|---:|---:|
| All stocked | 0.042 ms | 0.032 ms | 24% faster |
| One needs a top-up | 0.048 ms | 0.037 ms | 23% faster |
| All need a top-up | 0.052 ms | 0.074 ms | 41% slower |
| Empty destinations, no matching ammo | 0.038 ms | 0.047 ms | 23% slower |
| Partial destinations, no matching ammo | 0.039 ms | 0.074 ms | 92% slower |

These are historical observations on one machine, not acceptance thresholds. The
copyable harness above adds conservation checks and includes the 1,000-entity
mixed-supply workload. Its numbers can vary with engine versions, enabled mods,
hardware, thermal state, Lua garbage collection, and inventory layout. Resetting
inventories immediately before measurement also warms CPU caches. Rerun small or
inconsistent differences rather than interpreting them as conclusive.

Useful extensions are independent dimensions, not substitutes for one another:

- **Work per callback:** budgets of 10, 100, and 1,000 entities.
- **Factory size:** register many more entities than the budget and preserve the
  cursor across invocations. Measure refill latency across a complete sweep too.
- **Supply shape:** one item, many item/quality identities, different slot counts,
  depleted candidates, and incompatible categories or filters.
- **Consumer types:** burners, locomotives, characters with paired guns and
  manual ammo removal delays, artillery, and vehicles. This turret fixture does not cover them.
- **Distribution:** multiple surfaces and forces, missing chests, destroyed
  representative chests, and changing supply.
- **Transfer correctness:** partial insertion, refunds, exact quality, slot
  filters, item conservation, and whether both versions reach the same target in
  the same number of sweeps.

For correctness-focused fixtures, assert invariants after every operation; use
separate timing runs if those checks would distort the measurement. A standalone
Lua test such as `lua tests/supply.lua` is useful for fast regression checks, but
mock inventory timings cannot estimate the cost of Factorio's actual API calls.

## Whole-save UPS validation

After the callback comparison, test representative saves with the **production
mod**, normal event handlers, and advancing game ticks:

```sh
"$AUTO_FACTORIO" \
  --config "$AUTO_BENCH/config.ini" \
  --mod-directory "$AUTO_BENCH/production-mods-old" \
  --benchmark "$AUTO_BENCH/representative.zip" \
  --benchmark-ticks 10000 \
  --benchmark-runs 3 \
  > "$AUTO_BENCH/whole-save-old.log" 2>&1
```

First populate `production-mods-old` and `production-mods-new` with complete
production versions and the same other mods/settings. The command above is a
template, not part of the generated fixture. Repeat it with the new directory and
a separate log. Start each version from the same copied save, and account for any
configuration-change migrations before comparing steady-state performance. Use
`--benchmark-verbose` with timings supported by that executable's `--help` if
per-tick measurements are needed.

Do not use this guide's generated `test.zip` or wrapped benchmark mod for that
comparison: its timing harness only runs during initialization, and its copied
engines have no registered production tick handler. Use a real factory save with
representative consumption and supply shortages, or build a separate scenario
that creates sustained demand during normal ticks.

## References

- [Factorio command-line parameters](https://wiki.factorio.com/Command_line_parameters)
- [LuaBootstrap lifecycle and events](https://lua-api.factorio.com/latest/classes/LuaBootstrap.html)
- [LuaSurface entity creation and terrain](https://lua-api.factorio.com/latest/classes/LuaSurface.html)
- [LuaHelpers.create_profiler](https://lua-api.factorio.com/latest/classes/LuaHelpers.html#create_profiler)
- [LuaProfiler accumulation and division](https://lua-api.factorio.com/latest/classes/LuaProfiler.html)
- [LuaInventory operations](https://lua-api.factorio.com/latest/classes/LuaInventory.html)

The `latest` API pages can change. Use the documentation for the engine version
you actually benchmark, including the installed documentation when available.
