# Auto-Loader

A Factorio mod that automatically supplies ammo and fuel from shared Auto-Loader
chests to turrets, vehicles, characters, and burners. Inspired by ammo-loader,
with support for quality ammo and fuel.

## Using the mod

Place an Auto-Loader chest and stock it with ammo and fuel. Chests belonging to
the same force on the same surface share an inventory and supply nearby or
distant entities on that surface, including on space platforms.

Chest capacity, stack size multiplier, and refill processing budget are
configurable in mod settings. Players can also adjust the ammo refill delay,
which gives them time to remove guns while holding ammo in the cursor.

## Install

Drop the mod folder into your Factorio `mods/` directory:

- macOS: `~/Library/Application Support/factorio/mods/`
- Linux: `~/.factorio/mods/`
- Windows: `%APPDATA%\Factorio\mods\`

## Development

Runtime behavior lives in `control.lua`, chest and item definitions in `data.lua`,
and mod settings in `settings.lua`.

- [Architecture](documentation/ARCHITECTURE.md) — current implementation and refill behavior.
- [Testing](documentation/TESTING.md) — Lua checks and Factorio integration tests.
- [Benchmarks](benchmarks/README.md) — running performance comparisons and finding results.
- [Ideas](documentation/IDEAS.md) — possible future improvements.
- [Event reference](documentation/EVENTS.md) — exploratory notes on Factorio events.
