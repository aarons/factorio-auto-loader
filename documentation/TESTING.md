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
surfaces, missing/replaced chests, and cleanup of the old supply cache on upgrade.
The mocks deliberately reject refunds and simulate partial API acceptance.
The Python check verifies that both runners prefer standalone macOS Factorio
over a `PATH` copy, honor explicit overrides, and handle missing installations.

## Supply integration test

```sh
python3 tests/run_factorio.py --test supply
```

This runs three advancing ticks after saving and reloading the working mod in
Factorio. It validates four independent pools across two surfaces and two
forces, linked-chest replacement, normal/rare ammo, shortages, a force without
a chest, a filtered character slot, and a turret rejecting incompatible ammo.
A fixture turret requests 120 magazines but can hold only 100; exactly 100 must
be debited from its barred supply chest. Assertions run after each production
tick. This test needs no graphical desktop or player.

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
Factorio client (currently 2.1), and a graphical desktop. No clicks are needed.
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
