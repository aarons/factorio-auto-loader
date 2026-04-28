# AmmoLoader+=1

A small Factorio Space Age (2.0) mod that adds an **Auto-Loader Chest**.
Drop ammo or fuel into one and it tops up nearby compatible entities on the
**same surface** — no GUI, no circuit logic, no logistic-network integration.

The chest reuses the vanilla **active-provider-chest** sprite with an amber
tint to mark it as the loader, so it should look distinct on the map without
shipping new art.

## Install

Drop the mod folder into your Factorio `mods/` directory:

- macOS: `~/Library/Application Support/factorio/mods/auto-loader-chest_1.0.0/`
- Linux: `~/.factorio/mods/auto-loader-chest_1.0.0/`
- Windows: `%APPDATA%\Factorio\mods\auto-loader-chest_1.0.0\`

Restart Factorio. The chest's recipe is enabled by default — craft it from
1 iron chest + 2 electronic circuits.

## Runtime settings

| Setting | Default | Range | Effect |
| --- | --- | --- | --- |
| `auto-loader-chest-batch-size` | 10 | 1–1000 | Consumer entities processed per step. Higher = faster top-ups, slightly more UPS. |
| `auto-loader-chest-tick-interval` | 15 | 1–600 | Ticks between processing steps. Higher = lower UPS, slower top-ups. |

Both are runtime-global, so they can be changed mid-game from **Settings → Mod
settings → Map**.

## Supported entities

The loader fills any entity on the same surface that exposes a fuel inventory
or a supported ammo inventory. In practice that covers:

- ammo turrets, artillery turrets, artillery wagons
- tanks, cars, spidertrons
- locomotives
- burner mining drills
- stone furnaces (and other burner furnaces)
- boilers, nuclear reactors
- burner inserters
- burner assembling machines
- burner generators

Whatever items are sitting in the chest are fair game — there is no filter
or whitelist. `LuaInventory.insert` already enforces ammo category, so a
gun-turret won't accept rockets.
