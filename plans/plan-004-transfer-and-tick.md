# Chunk C — Item transfer, tick scheduler, runtime settings

**Parent plan:** [`plan-001.md`](plan-001.md). **Prerequisites:** chunks A and B (`plan-002-scaffolding.md`, `plan-003-state-tracking.md`) merged. The mod must already track chests and consumers in `storage`.

## Goal

Make the mod actually move items. Add the per-tick processing loop, the per-consumer fill routine, and the runtime-settings wiring that controls cadence. After this chunk the mod is feature-complete per plan-001 and should pass all 8 in-game scenarios in §Testing.

## Files

- Extend `control.lua` (do not split into multiple files — plan-001 §Validation says "single `control.lua`").
- Update `README.md` with install instructions, settings, and supported entity categories.
- Add any locale strings missed in chunk A (verify `mod-setting-name` / `mod-setting-description` are present and accurate).

## What to add to `control.lua`

### 1. Cached settings + change handler

```lua
local batch_size       -- int
local tick_interval    -- int
local current_nth_tick -- the N currently registered with on_nth_tick

local function refresh_settings()
  batch_size    = settings.global["auto-loader-chest-batch-size"].value
  tick_interval = settings.global["auto-loader-chest-tick-interval"].value
end
```

- Call `refresh_settings()` in `on_init`, `on_configuration_changed`, and at the top of a single `on_load` hook.
- Re-register `on_nth_tick` whenever `tick_interval` changes:
  ```lua
  if current_nth_tick then script.on_nth_tick(current_nth_tick, nil) end
  script.on_nth_tick(tick_interval, on_step)
  current_nth_tick = tick_interval
  ```
- Subscribe to `on_runtime_mod_setting_changed`: if the changed setting's name matches one of ours, refresh and re-register on_nth_tick if needed.

Caveat about `on_load`: you cannot mutate `storage` in `on_load`, but you *can* re-register `on_nth_tick` based on cached `storage.tick_interval`. Simplest approach: read settings in `on_load` and re-register, since settings are available there.

### 2. `fill_consumer(entity, surface_chests)`

Pull-mode logic per plan-001 §"Push vs. pull":

```lua
local function fill_one_inventory(consumer_inv, surface_chests)
  if not consumer_inv or consumer_inv.is_full() then return end
  for _, chest in pairs(surface_chests) do
    if chest.valid then
      local chest_inv = chest.get_inventory(defines.inventory.chest)
      if chest_inv and not chest_inv.is_empty() then
        for _, stack in ipairs(chest_inv.get_contents()) do
          local inserted = consumer_inv.insert{
            name = stack.name, count = stack.count, quality = stack.quality,
          }
          if inserted > 0 then
            chest_inv.remove{ name = stack.name, count = inserted, quality = stack.quality }
          end
          if consumer_inv.is_full() then return end
        end
      end
    end
  end
end
```

`fill_consumer(entity, surface_chests)` — call the engine accessors directly; no per-entity capability cache (see plan-003 §"No prototype cache"):

```lua
local AMMO_INVENTORY = {
  ["ammo-turret"]      = defines.inventory.turret_ammo,
  ["car"]              = defines.inventory.car_ammo,
  ["spider-vehicle"]   = defines.inventory.spider_ammo,
  ["artillery-turret"] = defines.inventory.artillery_turret_ammo,
  ["artillery-wagon"]  = defines.inventory.artillery_wagon_ammo,
}

local function fill_consumer(entity, surface_chests)
  local fuel_inv = entity.get_fuel_inventory()
  if fuel_inv then fill_one_inventory(fuel_inv, surface_chests) end

  local idx = AMMO_INVENTORY[entity.type]
  local ammo_inv = idx and entity.get_inventory(idx)
  if ammo_inv then fill_one_inventory(ammo_inv, surface_chests) end
end
```

`get_fuel_inventory()` is documented to return the inventory or `nil` with no precondition — safe and cheap to call every visit. `AMMO_INVENTORY` is the same file-local constant introduced in plan-003 chunk B; declare it once at the top of `control.lua`. Don't store `has_fuel` / `idx` per consumer in `storage` — `fill_one_inventory` already early-returns on a `nil` inventory and on `is_full()`.

`insert` already enforces ammo category, so a turret expecting bullets safely no-ops on rockets. Multi-slot ammo entities (tank, spidertron, artillery-wagon) are handled because `LuaInventory.insert` distributes across slots — no special casing needed; `is_full()` returns true only when all slots are filled with valid items.

### 3. `on_step()` — the tick driver

Iterate every surface that has a queue:

```lua
local function on_step()
  for surface_index, queue in pairs(storage.consumer_queue) do
    local surface_chests = storage.chests_by_surface[surface_index]
    if surface_chests and next(surface_chests) then
      local cursor = storage.consumer_cursor[surface_index] or 1
      local processed = 0
      local n = #queue
      if n == 0 then goto continue end

      while processed < batch_size do
        if cursor > n then
          cursor = 1
          -- compaction opportunity: see step 4
        end
        local unit_number = queue[cursor]
        cursor = cursor + 1
        if unit_number then
          local entity = storage.consumers[unit_number]
          if entity and entity.valid then
            fill_consumer(entity, surface_chests)
            processed = processed + 1
          else
            -- stale id; nil it out, don't count against budget
            queue[cursor - 1] = nil
            storage.consumers[unit_number] = nil
          end
        end
        if n == 0 then break end  -- defensive: queue emptied mid-loop
      end
      storage.consumer_cursor[surface_index] = cursor
    end
    ::continue::
  end
end
```

- Skip surfaces that have no chests — pure waste otherwise.
- Don't count nil entries against `batch_size` — they're free.
- The "useful" budget is consumers that were *actually attempted*, not slots scanned. This matters when the queue has many stale ids.

### 4. Periodic compaction

When the cursor wraps (cursor > n), check stale density. If more than ~25% of `queue` entries are nil, compact:

```lua
local compact = {}
for i = 1, #queue do
  if queue[i] then compact[#compact + 1] = queue[i] end
end
storage.consumer_queue[surface_index] = compact
```

Don't compact every wrap — that's O(n) per pass. Track a running stale-count or estimate by sampling. A simple heuristic: count nils during the wrap-detection branch; if `nil_count * 4 > n`, compact and reset cursor to 1.

### 5. Wire `on_nth_tick` in `on_init` / `on_configuration_changed` / `on_load`

After `refresh_settings()`, register `on_nth_tick(tick_interval, on_step)`. Track `current_nth_tick` so the settings-change handler can unregister cleanly.

## Documentation

`README.md` should gain (per plan-001 §Documentation):
- Short description (one paragraph): what the chest does, on-same-surface only, no GUI/circuit.
- Install instructions: drop the mod folder into `<factorio>/mods/`.
- Runtime settings table: the two settings, their defaults, what they mean.
- Supported entity categories: list the find-filter types from plan-001 line 41, with friendly names ("ammo turrets, artillery, tanks, cars, spidertrons, locomotives, burner mining drills, stone furnaces, boilers, reactors, burner inserters, burner assembling machines, burner generators").
- Quick mention of the active-provider-chest sprite reuse + amber tint so users aren't confused about the appearance.

Keep it tight — this is a small mod.

## Validation — the 8 scenarios from plan-001 §Testing

Run each manually in-game and capture results in the PR description.

1. [ ] **Single chest, single turret** — chest with bullets, gun-turret nearby. Turret loads within `tick_interval × ceil(cursor_pos / batch_size)` ticks.
2. [ ] **Multi-slot ammo** — tank with cannon-shells + machine-gun-magazines in chest; both gun slots fill.
3. [ ] **Multi-chest aggregation** — chest A has bullets only, chest B has rockets only; turret fills from A, rocket-launcher tank fills from B. Both succeed in the same tick window.
4. [ ] **Fuel** — burner mining drill, chest with coal; fuel inventory fills.
5. [ ] **Cross-surface isolation** — bullets on Nauvis, turret on Vulcanus; turret stays empty.
6. [ ] **Lifecycle** — build turret after chest exists → registered & filled. Mine turret → `/c game.print(#storage.consumer_queue[1])` reflects removal (or compaction). Deconstruct chest → no further fills.
7. [ ] **Settings change** — change tick interval at runtime via the mod settings menu → no errors in `factorio-current.log`, new cadence visibly applies (e.g. set interval to 600 → fills become very slow; set to 1 → very fast).
8. [ ] **UPS smoke test** — 200 ammo-turrets + 5 chests + 1 spidertron; `/show-time-usage` shows mod script time well under 0.1ms/tick.

## Validation — plan-001 §Validation completion checklist

After scenarios pass, confirm:

- [ ] Mod loads with no errors.
- [ ] Codebase: `info.json`, `data.lua`, `settings.lua`, `control.lua`, `locale/en/loader.cfg`. No `lib/` or `scripts/` subdirs.
- [ ] `grep find_entities_filtered control.lua` only returns hits inside `on_init` / `on_configuration_changed`.
- [ ] `grep on_tick control.lua` returns no matches; `on_nth_tick` is what's used.
- [ ] `grep register_on_object_destroyed control.lua` returns hits in chest and consumer registration paths.
- [ ] User signs off after playing in their own save.

## Out of scope

- GUI, circuit network, logistic-network integration — explicit non-goals from plan-001.
- Filter/whitelist controls on the chest contents.
- Indexing chests by item name for faster lookup. Plan-001 line 176 explicitly defers this until someone reports it as a problem.
- Tech-tree gating on the recipe.
