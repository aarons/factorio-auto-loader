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


## Optimizations to COnsider for UPS

  Where the time is going

  The hot path is on_step → fill_consumer → fill_one_inventory, running every tick by default. Per surface, per visited consumer (×10 by default), per inventory (fuel +
  ammo), the inner loop touches the shared inventory once per consumer:

  1. shared_inv.get_contents() — full snapshot allocated, then a totals dict built with name .. "|" .. quality keys (string allocs in a hot loop).
  2. for i = 1, #shared_inv do — every slot, even empties. Each iteration hits stack.valid_for_read, stack.name, stack.quality.name, stack.count — each is a Lua↔C++
  boundary cross.
  3. consumer_inv.get_item_count{ name=..., quality=... } — allocates a table per slot, per consumer, every tick.
  4. consumer_inv.insert{...} and entity.get_fuel_inventory() / entity.get_inventory() — more boundary crossings every visit.

  For a moderate base (say ~200 turrets, batch=10, ~48-slot linked container), each tick is ~10 × 2 × 48 ≈ ~1000 boundary crosses just for the slot scan, plus ~10 × 2 = 20
  get_contents() snapshots. That comports with the 1.7 ms average you're seeing.

  Strategies, ranked by likely impact

  A. Hoist shared-inventory work out of the per-consumer loop (biggest win).
  fill_one_inventory rebuilds totals and re-walks the shared inventory's slots for every consumer, but the shared inventory is the same for all consumers on a surface
  within a tick. Build a per-tick Lua snapshot once: [{slot_index, name, quality, count}, ...] plus the totals dict. Per-consumer loop reads/writes through the snapshot,
  and we only call shared_inv[i].count = … when an insert actually succeeds. Should cut shared-side boundary crosses by ~10× (= batch_size).

  B. Cache fuel_inv and ammo_inv references on the consumer record.
  get_fuel_inventory() / get_inventory() are called every visit. LuaInventory references are stable as long as the entity is valid, so store them in
  storage.consumers[unit_number] at registration time (alongside the entity). Skip the API calls in fill_consumer entirely.

  C. Replace get_item_count{} with a per-consumer contents snapshot.
  For each consumer inventory, one get_contents() per visit beats N get_item_count{} calls (one per slot). Build a current[name|quality] = count dict once, decrement in Lua
   as you insert. Eliminates ~N table allocs per consumer per inventory.

  D. Skip empty/known-full consumers cheaply.
  Currently is_full() short-circuits the outer check, but a turret with one bullet of nine ammo types is "not full" and re-scans the whole shared inventory. Track
  per-consumer per-item "filled to cap" state, or at least short-circuit the slot loop the moment cap - current <= 0 for everything in the snapshot. Combined with (A), the
  all-topped-up case becomes ~free.

  E. Spread cost across more ticks.
  The default tick_interval=1, batch=10 means 10 consumers/tick. Setting tick_interval=6, batch=60 gives the same throughput but the event handler fires 6× less often (and
  on_nth_tick itself has overhead). Doesn't help avg ms/tick directly but reduces variance and the fixed per-call overhead. This is a config choice, not a code change — but
   worth documenting.

  F. Avoid scanning unused slots.
  If the linked container has 48 slots but only 5 are used, the for i = 1, size loop pays 48 iterations. After (A), the snapshot can store only filled slots, so the
  per-consumer loop is #snapshot (=5), not #shared_inv (=48). Big multiplier on sparse chests.

  G. Quality string normalization once per snapshot.
  stack.quality and stack.quality.name or "normal" is done per-slot per-consumer today. After (A), it happens once per slot in the snapshot.

  H. Drop the totals[...] string concat key.
  Use a nested table totals[name][quality] = count instead of name .. "|" .. quality. Eliminates per-lookup string allocation. Minor but free.

  What I'd touch first

  (A) + (B) + (C) together are the structural wins — they're the same code change, basically: pre-build a snapshot once per surface per tick, and cache inventory refs at
  registration. I'd expect that alone to halve or better the avg ms/tick. (D) is the next step if you have lots of turrets that mostly sit idle. (E) is a settings tweak you
   could ship as a recommendation in the README.

  One non-obvious risk to flag: caching LuaInventory references means the validity guard becomes "is the entity still valid" — same lifetime, but worth verifying behavior
  under entity teleportation/space-platform travel before shipping.
