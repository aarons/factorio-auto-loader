# Auto-Loader Chest — minimal greenfield mod

Build a Factorio Space Age (2.0) mod from scratch that introduces a single new entity — an **auto-loader chest** — which automatically refills the ammo and fuel inventories of compatible entities on the same surface. Keep the runtime to a single `control.lua` if practical, prefer event-driven state over per-tick searches, and ship nothing speculative.

## Context

This repo is a clean slate (only a `README.md` exists). The user previously had a legacy ammo-loader mod and decided modernizing it was more expensive than starting fresh — so this plan is the new foundation, not a port. The target is Factorio 2.0 / Space Age; no 1.1 backwards compatibility.

### Behavior we want

- New chest entity that the player can craft and place. Visually distinct from vanilla chests — reuse the **active-provider-chest** sprite and apply a color tint (no new art assets).
- Ammo or fuel placed inside the chest is moved into nearby compatible entities **on the same surface** (no cross-surface effects).
- Compatible entities = anything that returns a non-nil fuel inventory from `entity.get_fuel_inventory()` and/or has an ammo inventory we can look up by `entity.type` (see API specifics below). Examples: ammo turrets, artillery turrets/wagons, tanks, cars, spidertrons, locomotives, burner mining drills, stone furnaces, nuclear reactors.
- Multi-slot ammo entities (tank, spidertron, artillery wagon) must have every gun slot filled, not just the first.
- Multiple auto-loader chests on the same surface aggregate as one supply pool: if chest A is empty for bullets and chest B has bullets, the consumer gets fed from B.
- Behavior must scale to large bases. Don't search every tick.

### Non-goals (do not build)

- No GUI, no circuit-network logic, no logistic-network integration.
- No filtering/whitelists in the chest — whatever the player puts in is fair game.
- No support for vanilla 1.1 (chest names changed; we use 2.0 names only).
- No remote interface, no per-player settings, no mod-compat shims.

## Implementation Notes

### Factorio 2.0 API specifics (all verified against current docs)

- **Persistent state**: use `storage` (renamed from `global` in 2.0). Migration of any old saves is N/A — this is a brand-new mod.
- **Fuel inventory**: prefer the shortcut `entity.get_fuel_inventory()` over `get_inventory(defines.inventory.fuel)`.
- **Ammo inventory**: there is no shortcut; pick the index from `entity.type`:
  - `ammo-turret` → `defines.inventory.turret_ammo`
  - `car`, `tank` (type is `car`) → `defines.inventory.car_ammo`
  - `spider-vehicle` → `defines.inventory.spider_ammo`
  - `artillery-turret` → `defines.inventory.artillery_turret_ammo`
  - `artillery-wagon` → `defines.inventory.artillery_wagon_ammo`
- **No prototype cache.** Don't walk `prototypes.entity`; the engine already maintains everything we need. Capability is detected per entity at registration time:
  - **Fuel**: `entity.get_fuel_inventory() ~= nil`. The docs guarantee this returns the inventory or `nil` — safe to call on any entity, no precondition. Returns nil for electric-only, fluid-burners (fusion gens, fluid-burning boilers), heat-consumers, and ghosts. Returns non-nil for stone furnace, burner mining drill, locomotive, nuclear reactor, tank/car/spidertron, etc. **Don't use `(proto.burner_prototype ~= nil)`** — it's a prototype-shape guess, doesn't compose with ghosts (which expose `ghost_prototype`, not `prototype`), and would miss any future item-fueled mechanism outside the burner energy-source class.
  - **Ammo**: declare a file-local `AMMO_INVENTORY` constant mapping `entity.type` → `defines.inventory.X_ammo` (5 entries: `ammo-turret`, `car`, `spider-vehicle`, `artillery-turret`, `artillery-wagon`). To detect: `local idx = AMMO_INVENTORY[entity.type]; local inv = idx and entity.get_inventory(idx); has_ammo = inv ~= nil and #inv > 0`. The `#inv > 0` check handles modded `car`-type entities with zero gun slots.
- **Lifecycle tracking**: use `script.register_on_object_destroyed(entity)` — returns `(registration_number, useful_id, target_type)` where `useful_id` is `unit_number` for entities. One event (`on_object_destroyed`) replaces listening to `on_player_mined_entity` / `on_robot_mined_entity` / `on_entity_died` / `script_raised_destroy` for cleanup.
- **Built events**: subscribe to `on_built_entity`, `on_robot_built_entity`, `on_space_platform_built_entity`, `script_raised_built`, `script_raised_revive`, `on_entity_cloned`. Use **event filters** so the handler only fires for relevant types — see the type list below.
- **Surface lifecycle**: `on_surface_created`, `on_surface_deleted` for per-surface state. `on_surface_cleared` is also worth handling (clears a surface but keeps it).
- **Find filter type list**: `{"ammo-turret","artillery-turret","artillery-wagon","car","spider-vehicle","locomotive","cargo-wagon","mining-drill","furnace","boiler","reactor","inserter","assembling-machine","burner-generator"}`. Note that `tank` is `type="car"`. This is a coarse pre-filter — `try_register_consumer` does the precise per-entity capability test via `get_fuel_inventory()` / `AMMO_INVENTORY` after the find.
- **Tinting the chest sprite**: `data.raw["container"]["active-provider-chest"]` (yes, it is a `logistic-container` in vanilla, so actually `data.raw["logistic-container"]["active-provider-chest"]`). `table.deepcopy` the prototype, change `type = "container"` (drop logistic behavior), rename, walk `picture.layers` (and `icon` if a flat icon) and set `tint = {r,g,b,a}` (floats 0..1) on each layer. Suggested tint: warm yellow / amber so it visually reads as "loader" (pick during data-stage; not load-bearing).
- **Inventory transfer**: no bulk helper. Pattern per item: `inserted = consumer_inv.insert{name,count,quality}; if inserted > 0 then chest_inv.remove{name,count=inserted,quality} end`. `insert` already respects ammo category, so trying to insert wrong ammo into a turret is a safe no-op.
- **Chest contents**: in 2.0, `LuaInventory.get_contents()` returns an **array** of `{name,count,quality}` (not a dict). Iterate with `ipairs`.
- **Tick scheduling**: `script.on_nth_tick(N, ...)` is significantly cheaper than `on_tick` and is the right choice here. Default N=15.

### Files

```
info.json
data.lua            -- entity, item, recipe (and technology unlock if needed)
settings.lua        -- runtime-global int settings
control.lua         -- all runtime logic (target = single file)
locale/en/loader.cfg
```

No graphics directory — we tint vanilla sprites only.

### `storage` shape

```lua
storage = {
  -- surface_index -> { [unit_number] = LuaEntity } of auto-loader chests
  chests_by_surface = {},

  -- surface_index -> array of unit_numbers; the round-robin queue
  consumer_queue = {},
  consumer_cursor = {},   -- surface_index -> int

  -- unit_number -> LuaEntity (for O(1) lookup from queue ids)
  consumers = {},

  -- registration_number -> { unit_number, kind } so on_object_destroyed can clean both maps
  destroy_registry = {},
}
```

Why an array of unit_numbers + a separate map: arrays let us do round-robin cheaply with a cursor; the map gives us O(1) validity-check and removal. When something is destroyed we mark it nil in the map and skip nil entries during queue iteration; periodically (or when nil density gets high) we compact the array. Don't compact on every removal — that's O(n).

### Push vs. pull — we pull

**Decision: pull.** The processing loop iterates **consumers** (the round-robin queue). For each consumer, look up the chest list for that consumer's surface and try to fill from any chest that has compatible items. This makes the multi-chest aggregation requirement trivial — chests are just a pool we walk in order.

Rationale:
- Push (iterate chests) requires answering "who needs this?" every step, which means a spatial query or a per-chest consumer list. Both are more state.
- Pull lets each consumer make a single decision per visit ("fill me from the surface pool"), naturally handles the "chest A empty, fall through to chest B" case, and keeps the per-tick budget proportional to consumers processed (not chests × consumers).
- Throughput tuning is a single knob: how many consumers per N ticks.

## Suggested Approach

### 1. `info.json`

Standard 2.0 manifest. `factorio_version = "2.0"`, dependencies on `base` and (optionally) `space-age` (`? space-age` — optional). Single author, name `auto-loader-chest`.

### 2. `data.lua` — chest entity

1. `local chest = table.deepcopy(data.raw["logistic-container"]["active-provider-chest"])`.
2. Mutate: `chest.type = "container"`; `chest.name = "auto-loader-chest"`; null out `logistic_mode` etc. that don't apply to plain containers; keep `inventory_size` (or set to 48 — match steel chest).
3. Walk every layer of `chest.picture.sheets` / `chest.picture.layers` (whichever the prototype uses in 2.0; deepcopy and inspect at runtime if unsure) and assign `tint = {r=1.0, g=0.85, b=0.2, a=1.0}` (amber). Same for `icon` / `icons` — if it's a single icon, convert to `icons = {{icon=..., tint=...}}`.
4. Define matching `item` (`type="item"`, `place_result="auto-loader-chest"`, `stack_size=50`) and `recipe` (input: a few steel chests + electronic circuits; cheap — this is QoL, not a balance lever). `data:extend{ chest, item, recipe }`.
5. Skip technology gating in v1 (principle #1); recipe is enabled by default. If the user later wants gating, `logistic-system` or `military-2` would be reasonable.

### 3. `settings.lua`

Two `int-setting`s, `setting_type = "runtime-global"`:

- `auto-loader-chest-batch-size` — consumers processed per tick step. Default 10, min 1, max 1000.
- `auto-loader-chest-tick-interval` — ticks between processing steps. Default 1, min 1, max 600.

Cache values in upvalues; refresh on `on_runtime_mod_setting_changed`. Reapply `script.on_nth_tick` registration when the interval changes (unregister old N, register new N).

### 4. `control.lua` structure

All in one file. Suggested top-to-bottom layout:

```
-- 1. local upvalues + cached settings + AMMO_INVENTORY constant
-- 2. consumer registration         try_register_consumer(entity)
-- 3. chest registration            register_chest(entity), unregister_chest(unit_number)
-- 4. fill-one-consumer routine     fill_consumer(entity, surface_chests)
-- 5. tick step                     on_step()
-- 6. event handlers + filters
-- 7. on_init / on_configuration_changed: full scan
```

Key routines:

- `try_register_consumer(entity)`: call `entity.get_fuel_inventory()` and look up `AMMO_INVENTORY[entity.type]` → `entity.get_inventory(idx)`; if either is non-nil (and the ammo inv has slots), append `unit_number` to that surface's queue, store entity in `storage.consumers`, and `register_on_object_destroyed`. Don't store the capability flags — re-derive per visit.
- `register_chest(entity)`: insert into `storage.chests_by_surface[surface_index]` and register destroy handler.
- `fill_consumer(entity, chests)`:
  - `local fuel_inv = entity.get_fuel_inventory()`; if non-nil and not full, fill from chest pool.
  - `local idx = AMMO_INVENTORY[entity.type]`; `local ammo_inv = idx and entity.get_inventory(idx)`; if non-nil and not full, fill from chest pool.
  - "Fill from chest pool" = walk `chests` in order; for each chest's `get_contents()`, attempt `consumer_inv.insert{...}` then `chest_inv.remove{name,count=inserted,quality}` for the inserted count. Stop when consumer inventory reports `is_empty() == false and not has_room` (i.e., full) or chests exhausted.
  - **Skip work cheaply**: before any insert attempt, `if consumer_inv.is_full() then return end`. Same for chest: pass over chests whose `get_contents()` is empty.
- `on_step()` (called from `on_nth_tick`):
  - For each surface in `storage.consumer_queue`: walk `batch_size` consumers from `cursor`, advance cursor, validate entity, call `fill_consumer`.
  - If a consumer slot is `nil` (destroyed), skip and don't count it against the batch budget — but bump cursor.
  - Periodically compact the array (e.g., when cursor wraps and >25% of slots are nil).

### 5. Event handlers

```
defines.events.on_built_entity         + filter on type list
defines.events.on_robot_built_entity   + filter
defines.events.on_space_platform_built_entity + filter
script_raised_built / script_raised_revive / on_entity_cloned (no filter param available for some — branch on entity.type inside)
on_object_destroyed   -> look up registration_number in storage.destroy_registry, remove from chests/consumers
on_surface_created / on_surface_deleted / on_surface_cleared
on_runtime_mod_setting_changed -> refresh cached settings + re-register on_nth_tick if interval changed
```

In each "built" handler also branch: if the new entity is `auto-loader-chest`, `register_chest`; else `try_register_consumer`.

### 6. Initial scan

In `on_init` and `on_configuration_changed`:
1. Reset `storage` collections.
2. For each surface, `find_entities_filtered{type=<list>}` to enumerate candidate consumers (the type list is a coarse pre-filter; `try_register_consumer` does the precise capability test via `get_fuel_inventory()` / `AMMO_INVENTORY`). Then `find_entities_filtered{name="auto-loader-chest"}` for chests. Register each.

A second mod adding new entities later → `on_configuration_changed` re-scans, picking up any newly-tracked types automatically (no per-prototype bookkeeping to stale out).

## UPS budget — how this stays cheap

- **No per-tick `find_entities_filtered`.** Discovery is event-driven and one-shot at init.
- **`on_nth_tick`** instead of `on_tick`. With defaults (every 15 ticks, batch 10), we touch 40 consumers/sec — enough to keep a base topped up, trivial cost.
- **No prototype cache** — capability is a single `entity.get_fuel_inventory()` call plus an `AMMO_INVENTORY[entity.type]` table lookup. The engine already maintains the inventory; mirroring it in `storage` adds migration/invalidation surface for negligible savings.
- **Skip-when-full** check is the first thing `fill_consumer` does — most ticks, most consumers do nothing.
- **`register_on_object_destroyed`** collapses 4+ removal events into one, and gives us O(1) cleanup.
- **Event filters** make built-event dispatch close to free for unrelated entity types.
- **Chests are typically few**, so iterating "all chests on the surface" inside `fill_consumer` is fine. If a future user reports many chests, we can index chests by item-name; not now (principle #1).

## Testing

Avoid introducing boilerplate tests; we do not want excessive pointless tests as these do not serve anyone.
It's extremely important that the tests are meaningful, clear, and validate core issues and behavior.
It's important to figure out tests that validate our business case, and that ensure healthy core architecture.
They can and should help engineers understand the intention behind the code.

Factorio mods don't have a unit-test framework that ships with the engine. The meaningful test coverage here is **in-game scenarios** the implementer should walk through manually before declaring done. Capture findings in the PR description.

Required scenarios:

1. **Single chest, single turret**: place chest with bullets, place gun-turret next to it, verify turret loads within `tick_interval × ceil(consumer_index / batch_size)` ticks.
2. **Multi-slot ammo**: place a tank, place chest with cannon shells + machine-gun mags, verify both gun slots fill.
3. **Multi-chest aggregation**: chest A has bullets but no rockets, chest B has rockets but no bullets, single turret needs bullets and a rocket-launcher tank needs rockets — both fill correctly.
4. **Fuel**: place burner mining drill, chest with coal, verify fuel inventory fills.
5. **Cross-surface isolation**: chest on Nauvis full of bullets, turret on Vulcanus — turret stays empty.
6. **Lifecycle**: build turret after chest exists → it gets registered; mine turret → cleaned from queue (verify via a `/c game.print(#storage.consumer_queue[1])` console command before/after); deconstruct chest → no further fills happen.
7. **Settings change**: change tick interval at runtime → no errors, new cadence applies.
8. **UPS smoke test**: 200 turrets + 5 chests + 1 spidertron, observe `/show-time-usage` — script time should stay well under 0.1ms/tick on a modern machine.

## Validation

Implementation is done when:

- [ ] Mod loads in Factorio 2.0 with no errors in `factorio-current.log`.
- [ ] Chest is craftable, placeable, and visually tinted (clearly distinct from vanilla active-provider-chest).
- [ ] All 8 testing scenarios above pass.
- [ ] Codebase fits in a single `control.lua` plus `data.lua`, `settings.lua`, `info.json`, and one locale file. No `lib/` or `scripts/` subdirectories.
- [ ] No periodic `find_entities_filtered` calls (grep `control.lua` to confirm — only `on_init` / `on_configuration_changed` should call it).
- [ ] `on_nth_tick` used, not `on_tick`.
- [ ] `register_on_object_destroyed` used for cleanup.
- [ ] User signs off after playing with the mod in their own save.

## Documentation

- Update `README.md` with: short description, install instructions (drop into `mods/` folder), the two runtime settings, and the list of supported entity categories.
- Add `locale/en/loader.cfg` entries for entity name, item name, recipe name, and the two settings.
- No separate design doc — this plan is the design doc.
