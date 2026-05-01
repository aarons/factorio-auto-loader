# AmmoLoader+=1

A small Factorio Space Age (2.0) mod that adds an **Auto-Loader Chest**.
Drop ammo or fuel into one and it tops up nearby compatible entities on the
**same surface** — no GUI, no circuit logic, no logistic-network integration.

The chest reuses the vanilla **steel-chest** sprite with an amber tint to
mark it as the loader, so it should look distinct on the map without shipping
new art. Internally it's a `linked-container`, so every chest on the same
surface shares one inventory pool.

## Install

Drop the mod folder into your Factorio `mods/` directory:

- macOS: `~/Library/Application Support/factorio/mods/`
- Linux: `~/.factorio/mods/`
- Windows: `%APPDATA%\Factorio\mods\`

Restart Factorio. Recipe cost and unlock are configurable via startup
settings (`auto-loader-chest-cost`, `auto-loader-chest-availability`); by
default it costs 1 steel chest + 3 electronic circuits + 1 advanced circuit
and unlocks with **Construction robotics**.

## Runtime settings

| Setting | Default | Range | Effect |
| --- | --- | --- | --- |
| `auto-loader-chest-batch-size` | 10 | 1–1000 | Entities processed per step. Higher = faster top-ups but more impact to UPS. |
| `auto-loader-chest-tick-interval` | 1 | 1–600 | Ticks between processing steps. Avoid lag spikes by using 1 tick with fewer entities processed per step. |
| `auto-loader-chest-max-fill` | 10 | 1–1000 | Max fill size per item (per quality). Any consumer below this gets topped back up to it. Replaces the game's own defaults entirely. |
| `auto-loader-chest-insert-overrides` | `nuclear-fuel=1,uranium-fuel-cell=1` | string | Per-item max overrides, comma-separated `item=count` pairs. Example: `coal=50,nutrients=100,nuclear-fuel=1`. |

All are runtime-global, so they can be changed mid-game from **Settings → Mod
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

## Priority by slot order

The chest pulls from **earlier slots first**. Pin which ammo or fuel a
consumer should consume first by placing it in a lower-numbered slot —
the easiest way is to set a slot filter and let inserters drop into it.

Examples:

- Slot 1 filter `uranium-rounds-magazine`, slot 2 filter `piercing-rounds-magazine` →
  turrets drain uranium first and only fall back to piercing when uranium
  is gone.
- Slot 1 filter `nuclear-fuel`, slot 2 filter `solid-fuel`, slot 3 filter
  `coal` → locomotives and burner drills burn the higher-value fuel first
  and let coal sit as a backup.

Fair-share still applies: when stock is low relative to the number of
consumers, each visit takes a smaller slice so everyone gets a turn
before the first few top up to `max-fill`.

## Optimizations to Consider for UPS

Cache fuel_inv and ammo_inv references on the consumer record.
get_fuel_inventory() / get_inventory() are called every visit. LuaInventory references are stable as long as the entity is valid, so store them in
storage.consumers[unit_number] at registration time (alongside the entity). Skip the API calls in fill_consumer entirely.

Stash {has_fuel, ammo_idx} (and optionally the fuel/ammo inventory refs in a runtime-only table rebuilt in on_load from storage.consumers)
so fill_consumer doesn't call get_fuel_inventory() + get_inventory(idx) every visit. Already tracking has_fuel/has_ammo in destroy_registry
 — promote to storage.consumers[un] = {entity=…, ammo_idx=…, has_fuel=…}.

Replace get_item_count{} with a per-consumer contents snapshot.
For each consumer inventory, one get_contents() per visit beats N get_item_count{} calls (one per slot). Build a current[name|quality] = count dict once, decrement in Lua as you insert. Eliminates ~N table allocs per consumer per inventory.

Skip empty/known-full consumers cheaply.
Currently is_full() short-circuits the outer check, but a turret with one bullet of nine ammo types is "not full" and re-scans the whole shared inventory. Track per-consumer per-item "filled to cap" state, or at least short-circuit the slot loop the moment cap - current <= 0 for everything in the snapshot. Combined with (A), the all-topped-up case becomes ~free.

Avoid scanning unused slots.
If the linked container has 48 slots but only 5 are used, the for i = 1, size loop pays 48 iterations. After (A), the snapshot can store only filled slots, so the per-consumer loop is #snapshot (=5), not #shared_inv (=48). Big multiplier on sparse chests.

Quality string normalization once per snapshot.
stack.quality and stack.quality.name or "normal" is done per-slot per-consumer today. After (A), it happens once per slot in the snapshot.

Drop the totals[...] string concat key.
Use a nested table totals[name][quality] = count instead of name .. "|" .. quality. Eliminates per-lookup string allocation. Minor but free.

