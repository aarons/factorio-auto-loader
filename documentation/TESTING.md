# Automated tests

Run the fast Lua regression checks from the repository root:

```sh
lua tests/supply.lua
python3 -B tests/factorio_discovery.py
```

These exercise the production tick and refill functions with instrumented
inventories. They check lazy supply access (including delayed/unarmed character
slots), one snapshot per surface/force per tick, batched debits, conservation,
shortages/restocking, exact quality and existing-stack preference, rejected and
partial insertion/slot placement, locomotive slot limits, changing forces and
surfaces, membership-gated missing/replaced chests, and cleanup of the old supply
cache on upgrade.
The mocks deliberately reject refunds and simulate partial API acceptance.
The Lua tests exercise the registered init/load/configuration-change handlers.
They model Factorio 2.1.20's plural fuel categories and reject the removed
singular property. Fuel checks cover matching any category, incompatible
burners, empty and occupied locomotive slots, existing-stack preference, quality,
and conservation of supply. Loading is tested with `game` unavailable and
recursively read-only storage,
including both active and disabled tick subscription restoration. Chest searches
are prohibited outside bootstrap handlers. Registry cases cover duplicate build
and removal events, invalid last members with surviving linked inventories,
nil lookup caching, force merges, imports, surface cleanup/index reuse, legacy
migration, and bounded visits to unsupplied/stale consumers.
The Python check verifies that both runners prefer standalone macOS Factorio
over a `PATH` copy, honor explicit overrides, and handle missing installations.

## Supply integration test

```sh
python3 tests/run_factorio.py --test supply
```

This runs three advancing ticks after saving and reloading the working mod in
Factorio. It validates four independent pools across two surfaces and two
forces, linked membership after removing one chest, normal/rare ammo, shortages,
a force without a chest, a filtered character slot, and a turret rejecting incompatible ammo.
A fixture turret requests 120 magazines but can hold only 100; exactly 100 must
be debited from its barred supply chest. Assertions run after each production
tick. This test needs no graphical desktop or player.

## Lifecycle and upgrade integration tests

```sh
python3 tests/run_factorio.py --test lifecycle
python3 tests/run_factorio.py --test supply --upgrade-from HEAD
```

The lifecycle fixture starts from a saved world with a registered consumer and
no chests. Over 18 advancing ticks it exercises first construction, direct linked
inventory access, entity/area cloning, removal of one and the last chest (including
silent destruction with delayed notifications), rebuilding, deconstruction marks,
death, force merging, empty-chest restocking, surface clearing and deletion.
The existing supply fixture covers loading with active membership.

`--upgrade-from` creates the save using that Git revision's `control.lua`, then
copies the working implementation/version to trigger a real configuration
change. If both revisions share a version, it bumps the temporary version. Production version files are untouched.
Use the pre-change revision when HEAD already includes the implementation.

Normal player/robot/platform build and mining handlers, script revival, and map
imports are exercised by Lua mocks. The graphical player test also checks actual
player mining. Actual map-editor import and robot/platform operations are not
covered by the headless fixture. There is no documented script API to initiate
surface import; the import mock verifies the event field and bootstrap scans.

## Player ammo integration test

```sh
python3 tests/run_factorio.py
```

Both test and benchmark runners prefer the standalone macOS installation at
`/Applications/factorio.app/Contents/MacOS/factorio`, then fall back to `PATH`.
They do not automatically search the Steam installation. An explicit
`--factorio` or `AUTO_FACTORIO` takes precedence over discovery. The data
directory is discovered relative to the selected executable unless overridden.
To select an installation explicitly:

```sh
python3 tests/run_factorio.py --factorio /path/to/factorio --data /path/to/data
```

`AUTO_FACTORIO` and `AUTO_FACTORIO_DATA` are also supported, as in the
[benchmarking guide](BENCHMARKING.md). Requirements are Python 3, a compatible
Factorio client (2.1.20 or later), and a graphical desktop. No clicks are needed.
A headless-only server is insufficient for this test: `--create` and
`--benchmark` do not create a player, and a character without a player cannot
exercise the player's cursor stack.

The runner copies the working mod into a temporary directory, creates a save,
and opens it in a separate Factorio window. A companion fixture mod creates a
real player-controlled character, a pistol in gun slot 1, and an Auto-Loader
chest containing 100 magazines. The production mod runs with its normal event
handlers and advancing game ticks; its functions and API objects are not mocked.
Only the fixture's refill delay default is changed to one second.

The fixture checks:

- The first ammo slot receives 10 magazines from the chest; unarmed slots stay empty.
- Moving that ammo to the player's hand keeps the slot empty for two seconds,
  longer than the configured delay.
- Putting the ammo in the player's inventory keeps the slot empty until the
  one-second delay expires, then refills it from the chest.
- Removing ammo again, then removing the gun and putting the ammo away, leaves
  the ammo slot empty for another two seconds.
- Rearming and mining the last chest leaves ammo empty on the following tick.

Each waiting phase checks the slot on every tick. Supply counts are checked too,
so an empty chest cannot produce a false pass for the delay or gun-removal cases.
These are API-driven inventory operations, not simulated mouse clicks.

The runner prints each passed stage and exits with status 0 only after the final
success marker. Errors, premature exits, and timeouts fail the command. The
runner closes its own Factorio process on completion. `--timeout` sets the
maximum seconds per launch (default 120).

The printed temporary directory retains the copied mods, save, configuration,
and `create.log` / `test.log` for diagnosis. Normal Factorio saves, mods, and
settings are untouched. Remove the temporary directory when it is no longer
needed. Avoid interacting with the test window while it runs.
