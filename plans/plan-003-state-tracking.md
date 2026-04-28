# Chunk B — Runtime state tracking (no transfers yet)

**Parent plan:** [`plan-001.md`](plan-001.md). **Prerequisite:** chunk A (`plan-002-scaffolding.md`) is merged — the chest prototype, item, recipe, settings declarations, and locale exist.

## Goal

Wire up `control.lua` so that the mod *knows* about every chest and every compatible consumer on every surface — populated and cleaned up via events, with an initial scan covering pre-existing entities. **No item transfers yet.** After this chunk, the mod is silent in-game but `storage` is a faithful live view of the world's auto-loader-relevant entities.

The reason this is its own chunk: registration is the foundation for transfers, and getting it right (event filters, destroy-handler lifecycle, surface lifecycle, configuration-changed rescans) is fiddly. Better to validate it standalone via console inspection than to debug it tangled together with transfer logic.

## Files

- Create `control.lua`.

## What `control.lua` must do in this chunk

### 1. `storage` shape

```lua
storage = {
  chests_by_surface = {},    -- surface_index -> { [unit_number] = LuaEntity }
  consumer_queue = {},       -- surface_index -> array of unit_numbers
  consumer_cursor = {},      -- surface_index -> int  (chunk C uses this; init to 1 here)
  consumers = {},            -- unit_number -> LuaEntity
  destroy_registry = {},     -- registration_number -> { unit_number, kind = "chest"|"consumer", surface_index }
}
```

> No `proto_cache` field — see §"No prototype cache" below for the rationale. Plan-001's storage shape and plan-004's `fill_consumer` have been updated to match.

### 2. No prototype cache — ask the entity directly

Plan-001 originally specified a `build_proto_cache()` pass that walked `prototypes.entity` and stored `{ has_fuel, ammo_index }` per name. **Skip it.** The engine already maintains everything we need; querying it directly is simpler, safer, and indistinguishable in cost.

**Fuel: `entity.get_fuel_inventory()`**

Documented as: *"The fuel inventory for this entity or `nil` if this entity doesn't have a fuel inventory."* Safe to call on any entity — no precondition, no error path. Returns `nil` for electric-only entities (electric drill, steam engine), heat-consumers, fluid-burners (fusion generators in Space Age, fluid-burning boilers), and ghosts. Returns a `LuaInventory` for stone furnace, burner mining drill, locomotive, nuclear reactor (consumes uranium fuel cells), tank/car/spidertron (burner-fueled), etc.

This is preferred over `(proto.burner_prototype ~= nil)` for three reasons:

1. `burner_prototype` is a prototype-shape check, not a runtime-truth check. Mods can add prototypes after this runs, so a runtime check is safest.
2. `burner_prototype` doesn't compose cleanly with ghosts (`entity.type == "entity-ghost"` exposes its contained prototype via `ghost_prototype`, not `prototype`). `get_fuel_inventory()` returns `nil` on ghosts — the correct answer for a fuel-loader.
3. If a future or modded entity grows an item-fueled mechanism outside the burner energy-source class, only `get_fuel_inventory()` will track it.

**Ammo: branch on `entity.type`, then call `get_inventory(...)`**

There is no `entity.get_ammo_inventory()` shortcut. The mapping from entity type to ammo-inventory define is fixed and tiny — declare it as a file-local constant, not in `storage`:

```lua
local AMMO_INVENTORY = {
  ["turret"]      = defines.inventory.turret_ammo,
  ["car"]              = defines.inventory.car_ammo,        -- includes tanks
  ["spider-vehicle"]   = defines.inventory.spider_ammo,
  ["artillery-turret"] = defines.inventory.artillery_turret_ammo,
  ["artillery-wagon"]  = defines.inventory.artillery_wagon_ammo,
  ["character"]   = defines.inventory.charter_ammo,
}
```

To detect ammo capability on a given entity:

```lua
local idx = AMMO_INVENTORY[entity.type]
local ammo_inv = idx and entity.get_inventory(idx)
local has_ammo = ammo_inv ~= nil and #ammo_inv > 0
```

The `#ammo_inv > 0` guard handles the rare case of a `car`-type prototype with zero gun slots (modded transport-only car); `LuaInventory` length reflects gun count.

**Why this is fine performance-wise**

- Capability detection happens once per entity, at registration time (in the built handlers and during the on_init/on_configuration_changed scan). Not in the tick loop.
- The tick loop in chunk C will call `entity.get_fuel_inventory()` and `entity.get_inventory(idx)` per visit anyway — those are the values it operates on. A cached `has_fuel` boolean would only save a `nil` check, which is free.
- Long-lived `LuaEntity` references (held in `storage.consumers`, validated with `.valid`) are the engine's preferred pattern. Parallel caches in `storage` add migration and invalidation surface for negligible savings.

### 3. Registration helpers

- `register_chest(entity)`:
  - Insert into `storage.chests_by_surface[entity.surface.index][entity.unit_number] = entity` (create the inner table if missing).
  - `local reg_num = script.register_on_object_destroyed(entity)`; record `storage.destroy_registry[reg_num] = { unit_number = entity.unit_number, kind = "chest", surface_index = entity.surface.index }`.

- `try_register_consumer(entity)`:
  - Compute capability inline:
    ```lua
    local has_fuel = entity.get_fuel_inventory() ~= nil
    local idx     = AMMO_INVENTORY[entity.type]
    local ammo_inv = idx and entity.get_inventory(idx)
    local has_ammo = ammo_inv ~= nil and #ammo_inv > 0
    if not (has_fuel or has_ammo) then return end
    ```
  - Append `entity.unit_number` to `storage.consumer_queue[entity.surface.index]` (init array if missing).
  - `storage.consumers[entity.unit_number] = entity`.
  - `register_on_object_destroyed` and record `kind = "consumer"`.

  Don't store `has_fuel` / `idx` per consumer — chunk C re-derives them per visit, and the engine answers fast.

- `unregister_destroyed(reg_num)`:
  - Look up `destroy_registry[reg_num]`; if missing, return.
  - If `kind == "chest"`: remove from `chests_by_surface[surface_index][unit_number]`.
  - If `kind == "consumer"`: set `consumers[unit_number] = nil`. **Do not** rewrite `consumer_queue` here — chunk C's tick loop skips nil entries and compacts periodically. Just leaving the unit_number in the array with no entity in `consumers` is fine.
  - Clear `destroy_registry[reg_num]`.

### 4. Event handlers

```lua
local built_filter = {
  {filter = "type", type = "ammo-turret"},
  {filter = "type", type = "artillery-turret"},
  {filter = "type", type = "artillery-wagon"},
  {filter = "type", type = "car"},              -- includes tanks
  {filter = "type", type = "spider-vehicle"},
  {filter = "type", type = "locomotive"},
  {filter = "type", type = "cargo-wagon"},
  {filter = "type", type = "mining-drill"},
  {filter = "type", type = "furnace"},
  {filter = "type", type = "boiler"},
  {filter = "type", type = "reactor"},
  {filter = "type", type = "inserter"},
  {filter = "type", type = "assembling-machine"},
  {filter = "type", type = "burner-generator"},
  {filter = "name", name = "auto-loader-chest"},
}
```

Subscribe with the filter:
- `on_built_entity`, `on_robot_built_entity`, `on_space_platform_built_entity`

For events that don't accept filters, branch inside on `entity.name == "auto-loader-chest"` vs everything else (let `try_register_consumer`'s capability check filter the rest):
- `script_raised_built`, `script_raised_revive`, `on_entity_cloned`

In every "built" handler: if `entity.name == "auto-loader-chest"` → `register_chest`; else → `try_register_consumer`.

Cleanup:
- `on_object_destroyed` → `unregister_destroyed(event.registration_number)`.

Surface lifecycle (clear all relevant per-surface state):
- `on_surface_created`: init empty containers for that surface index.
- `on_surface_deleted`: drop `chests_by_surface[idx]`, `consumer_queue[idx]`, `consumer_cursor[idx]`. Walk `consumers` and remove unit_numbers belonging to that surface (or rely on `on_object_destroyed` firing for each — verify which actually happens; if destroy events fire we don't need the manual sweep).
- `on_surface_cleared`: same as deleted but the surface index stays valid; reset its inner collections to empty.

### 5. `on_init` and `on_configuration_changed`

Both must:
1. Reset `storage` collections to empty defaults.
2. For each `surface in game.surfaces`:
   - `surface.find_entities_filtered{type = <type list>}` — call `try_register_consumer` for each result. The helper internally checks `get_fuel_inventory()` and the ammo map and bails on entities that qualify for neither.
   - `surface.find_entities_filtered{name = "auto-loader-chest"}` — call `register_chest` for each.

The `<type list>` is the same set used in the `built_filter` (minus `name = "auto-loader-chest"`). It's a coarse pre-filter so `find_entities_filtered` doesn't return every wall and tree; the precise per-entity capability test happens inside `try_register_consumer`.

`on_configuration_changed` fires when mods are added/removed/updated. A full reset + rescan handles every case — newly-added burner entity types from another mod, removed entity types, capability changes — without any per-prototype bookkeeping to stale out.

## Validation for this chunk

Use `/c` console commands to introspect state. Suggested checks:

- [ ] In a fresh save with no entities: `/c game.print(serpent.line(storage.consumer_queue))` → empty/per-surface empty arrays.
- [ ] Place a gun-turret: queue for the surface gains one entry; `storage.consumers[<unit_number>]` is the turret.
- [ ] Place an auto-loader-chest: `storage.chests_by_surface[1][<unit_number>]` is the chest.
- [ ] Mine the turret: after 1 tick, `storage.consumers[<unit_number>]` is `nil` (the queue array may still contain the orphaned id — that's expected; chunk C compacts).
- [ ] Mine the chest: removed from `chests_by_surface`.
- [ ] Place a stone furnace, burner mining drill, tank with a gun in slot 1, locomotive, spidertron — all should register as consumers. Confirm each shows up in `storage.consumers`.
- [ ] Place an electric mining drill or steam engine — should NOT register (`get_fuel_inventory()` returns nil; no entry in `AMMO_INVENTORY`).
- [ ] Place a nuclear reactor — should register (consumes uranium fuel cells, `get_fuel_inventory()` returns non-nil).
- [ ] Place a fluid-burning boiler or fusion generator (Space Age) — should NOT register (`get_fuel_inventory()` returns nil for fluid-fueled energy sources).
- [ ] Create a second surface (e.g. via editor or `game.create_surface`); place entities there; verify per-surface segregation in `consumer_queue` / `chests_by_surface`.
- [ ] Reload the save: `on_init` does not fire on reload, but `on_configuration_changed` doesn't either unless mods changed. Verify that *no* re-registration happens on plain reload (the `on_load` path is naturally a no-op since `storage` survives).
- [ ] Disable the mod, re-enable it: `on_configuration_changed` fires → scan repopulates `storage` from scratch.

If any consumer or chest shows up duplicated in the queue after a reload-add-remove cycle, the registration logic has a bug — fix before moving to chunk C.

## Out of scope (chunk C)

- Settings caching / `on_runtime_mod_setting_changed` runtime wiring.
- `fill_consumer`, item transfers, inventory inspection.
- `on_nth_tick` registration and the processing loop.
- Cursor advancement and array compaction.
- README updates.

Do not register `on_nth_tick` in this chunk — leave the consumer queue inert.
