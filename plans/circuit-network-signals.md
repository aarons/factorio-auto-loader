# Circuit-Network Output Signals for Auto-Loader Chest

## Context

Players want to wire their auto-loader chest into the circuit network and read what it currently holds. With Factorio 2.0's quality system, each (item, quality) pair must surface as its own signal — e.g. coal at common (5), uncommon (12), rare (33) → three distinct signals. This lets builds gate behavior on stockpile levels per quality tier.

The chest is a `linked-container` (`auto-loader-chest-linked`) whose contents live in per-surface **virtual storage** (`storage.virtual[surface_index].fuel` / `.ammo`) — items are swept out of physical inventory on every step. So the native `LuaContainerControlBehavior.read_contents` won't work: the physical chest is empty in steady state.

Scope (confirmed): only fuel + ammo (everything the mod tracks in virtual storage). Non-tracked items players might dump in the chest are out of scope.

## Approach

Pair each chest with a **hidden constant-combinator** at the same position, script-wired to the chest's red+green circuit connectors. Player-connected wires read these signals as if the chest itself produced them.

Recompute the filter list **only when `storage.virtual` for that surface mutates** — never on a tick timer, never as a global sweep. The mutation points are small and known: the per-surface sweep inside `on_step`, the per-surface `commit_step` after consumer fills (both in `on_step` and instant-fill in `try_register_consumer`), and the `take_stack` GUI action. Each site already knows its `surface_index`, so updates target exactly one surface.

Per-surface (not per-chest) computation is correct because all chests on a surface share one virtual store: build the filter list once for the surface, assign the same table to each chest's CC.

## File touch points

### 1. `data.lua` — restore wires + add hidden CC

**Lines 94-95:** stop nil-ing circuit support; inherit from steel-chest:
```lua
linked_chest.circuit_wire_max_distance = source.circuit_wire_max_distance
linked_chest.circuit_connector       = source.circuit_connector
```

**Before line 118 (`data:extend{...}`):** define `auto-loader-chest-cc` constant-combinator prototype, include in `data:extend`. Required fields:
- `type = "constant-combinator"`, `name = "auto-loader-chest-cc"`
- `hidden = true` (top-level boolean — `"hidden"` flag is gone in 2.0)
- `flags = { "placeable-off-grid", "not-on-map", "not-deconstructable", "not-blueprintable", "not-flammable", "no-copy-paste", "not-upgradable" }`
- `selectable_in_game = false`, `allow_copy_paste = false`
- `collision_mask = { layers = {} }`, `collision_box = {{0,0},{0,0}}`, `selection_box = {{0,0},{0,0}}`
- `sprites` / `activity_led_sprites` = empty 4-direction sprite (1×1 `__core__/graphics/empty.png`)
- `activity_led_light = { intensity = 0, size = 0, color = {0,0,0} }`
- `activity_led_light_offsets = {{0,0},{0,0},{0,0},{0,0}}`
- `circuit_wire_connection_points` = 4 entries, each `{ shadow = {red={0,0},green={0,0}}, wire = {red={0,0},green={0,0}} }`
- `draw_circuit_wires = false`, `draw_copper_wires = false`
- No `item_slot_count` (removed in 2.0; signals are now sections).

### 2. `control.lua` — storage shape

In `reset_storage` (lines 85-105) add:
```lua
storage.cc_by_chest = {}   -- [chest_unit_number] = combinator LuaEntity
```
Update the doc comment block. Keying by chest unit_number means destroying a chest can find its CC in O(1); we don't track CC unit_numbers separately.

### 3. `control.lua` — lifecycle

**`register_chest` (after line 173 `script.register_on_object_destroyed(entity)`):**
Past the `if chests[unit_number] then return end` guard, this runs once per fresh registration. Spawn CC at chest position, set `destructible = false` and `operable = false`, get the chest's `circuit_red`/`circuit_green` connectors and the CC's `combinator_output_red`/`combinator_output_green` connectors, and `connect_to(other, false, defines.wire_origin.script)` for both colors. Then `cc.get_or_create_control_behavior():add_section()` once so the update path can just assign `.filters`. Store `storage.cc_by_chest[unit_number] = cc`. Finally, seed the new CC's section with the surface's current filter list (other chests on the surface may have already accumulated virtual stock) — assign `build_filters_for_surface(surface_index)` directly to this single section rather than re-walking the whole surface.

**`on_object_destroyed` (chest branch, after line 367):**
```lua
local cc = storage.cc_by_chest[unit_number]
if cc and cc.valid then cc.destroy() end
storage.cc_by_chest[unit_number] = nil
```

**`clear_surface` (lines 393-411):** before clearing `chests_by_surface[surface_index]`, walk the surface's chests and destroy each paired CC; nil out `cc_by_chest` entries.

**`scan_all_surfaces` (lines 574-586):** inside the `for _, surface in pairs(game.surfaces)` loop, before `find_entities()`, drop any pre-existing hidden CCs:
```lua
for _, cc in pairs(surface.find_entities_filtered{ name = "auto-loader-chest-cc" }) do
  cc.destroy()
end
```
This handles `on_configuration_changed`: `reset_storage` empties `cc_by_chest`, so the world has orphan CCs we no longer reference. Clean slate before `register_chest` recreates them.

### 4. `control.lua` — filter builder

New helper near `build_step_context` (after line 286):
```lua
local INT32_MAX = 2147483647
local function clamp_i32(n)
  if n > INT32_MAX then return INT32_MAX end
  return n
end

local function build_filters_for_surface(surface_index)
  local v = storage.virtual[surface_index]
  if not v then return {} end
  local out, k = {}, 0
  for _, category in ipairs({ v.fuel, v.ammo }) do
    for name, entry in pairs(category) do
      for quality, count in pairs(entry.totals) do
        if count > 0 then
          k = k + 1
          out[k] = {
            value = { type = "item", name = name, quality = quality, comparator = "=" },
            min   = clamp_i32(count),
          }
        end
      end
    end
  end
  return out
end
```
No de-dup needed: `sweep_into_virtual` (lines 213-221) and `rebuild_item_kind_sets` (lines 43-53) both branch `if AMMO_ITEMS[name] then ... elseif FUEL_ITEMS[name] then ...`, so any item name lives in exactly one category.

### 5. `control.lua` — update path

New helper, scoped to a single surface:
```lua
local function update_combinators_for_surface(surface_index)
  local chests = storage.chests_by_surface[surface_index]
  if not chests then return end
  local filters = build_filters_for_surface(surface_index)
  for unit_number in pairs(chests) do
    local cc = storage.cc_by_chest[unit_number]
    if cc and cc.valid then
      local section = cc.get_or_create_control_behavior().get_section(1)
      if section then section.filters = filters end
    end
  end
end
```

Call sites — exactly the points that mutate `storage.virtual`:

1. **`on_step`, after `commit_step(ctx, surface_index)` (line 549).** Covers both the sweep at line 511 and the commit at 549: if sweep added items, the resulting entries flow into `ctx`, fills run, and `commit_step` runs. If sweep added nothing and there were no prior entries, `commit_step` is skipped (the `if ctx and (ctx.fuel_count > 0 or ctx.ammo_count > 0)` gate at line 516) — and virtual didn't change, so no update is needed. One update per surface that did work this step.
2. **`try_register_consumer`, after the instant-fill `commit_step` (line 349).** Same gate — only runs when there was something to take.
3. **`on_gui_click` `take_stack` branch, after the `entry.totals[quality]` mutation (after line 844).** Player just pulled stock out of the chest; signal must reflect it before the next GUI rebuild reads from virtual.

**Never walk all surfaces in one tick.** The previous design did, and that's the bug we're avoiding: it scaled with surface count regardless of activity, and did redundant work on surfaces whose virtual storage hadn't moved.

Lag: zero. Signals reflect `storage.virtual` immediately after every mutation. The only inherent delay is the existing 60-tick sweep throttle (line 504-513) — items dropped into a chest by an inserter take up to ~1s to enter virtual storage, and the signal lags that by zero ticks.

### 6. `info.json` — version bump

Line 3: `"version": "2.4.0"` → `"version": "2.5.0"` (storage shape changed: added `cc_by_chest`).

No bespoke migration script needed: `on_configuration_changed` already calls `reset_storage` + `scan_all_surfaces`, and the new orphan-CC cleanup in `scan_all_surfaces` finishes the upgrade end-to-end.

### 7. `locale/en/loader.cfg` — entity description

Line 11: append one sentence to `auto-loader-chest=...`: *"Connect a red or green circuit wire to read item counts (one signal per item × quality combination)."*

## Verification

1. **Fresh install / `on_init`:** start a new save with the mod enabled. Place an auto-loader chest. Confirm it has visible red/green wire ports.
2. **Signals appear:** insert 3 stacks of coal at different qualities into the chest, wire the chest to a constant-combinator displaying its inputs (or a lamp), and verify the network reports 3 distinct coal signals with correct counts. Add ammo magazines at multiple qualities and verify they appear as additional signals.
3. **Multi-chest sharing:** place two chests on the same surface, wire them to two **separate** networks. Both networks should show the same signals (per-surface virtual store), but adding red wire to chest A must not bleed into chest B's network.
4. **Multi-surface:** on Nauvis put coal in chest A; on a different surface (e.g. Vulcanus) put different items in chest B. Each chest's circuit signals should reflect only its own surface's storage.
5. **Lifecycle:** mine the chest. Confirm the hidden CC is also gone (`/c game.print(#game.surfaces[1].find_entities_filtered{name="auto-loader-chest-cc"})`).
6. **Reload migration:** with chests placed in a save on v2.4.0, install v2.5.0. `on_configuration_changed` runs; orphan-CC cleanup leaves zero hidden combinators before `scan_all_surfaces` re-registers chests with fresh CCs. Verify signals work post-upgrade.
7. **Take-stack updates signal:** with a wired chest reading (e.g.) 50 coal, click the coal slot in the priority GUI to pull a stack into the cursor. The wire reading should drop immediately to reflect the new total.
8. **No lag spike:** with ~50 chests across multiple surfaces and varied virtual storage, watch `/measured-command` against `on_nth_tick`. The added work per step is one `build_filters_for_surface` and one `section.filters` assignment per chest, **only on surfaces whose virtual storage actually mutated this step** — idle surfaces add zero cost.

## Critical files

- `/Users/aaron/code/factorio-ammo-loader-sa/data.lua`
- `/Users/aaron/code/factorio-ammo-loader-sa/control.lua`
- `/Users/aaron/code/factorio-ammo-loader-sa/info.json`
- `/Users/aaron/code/factorio-ammo-loader-sa/locale/en/loader.cfg`
