# Circuit-Network Output Signals for Auto-Loader Chest

## Context

Players want to wire their auto-loader chest into the circuit network and read what it currently holds. With Factorio 2.0's quality system, each (item, quality) pair must surface as its own signal — e.g. coal at common (5), uncommon (12), rare (33) → three distinct signals. This lets builds gate behavior on stockpile levels per quality tier.

The chest is a `linked-container` (`auto-loader-chest-linked`) whose contents live in per-surface **virtual storage** (`storage.virtual[surface_index].fuel` / `.ammo`) — items are swept out of physical inventory on every step. So the native `LuaContainerControlBehavior.read_contents` won't work: the physical chest is empty in steady state.

Scope (confirmed): only fuel + ammo (everything the mod tracks in virtual storage). Non-tracked items players might dump in the chest are out of scope.

## Approach

Pair each chest with a **hidden constant-combinator** at the same position, script-wired to the chest's red+green circuit connectors. Each `on_nth_tick` step, build a per-surface filter list from `storage.virtual` and assign it to every chest's combinator. Player-connected wires read these signals as if the chest itself produced them.

Per-surface (not per-chest) signal computation is correct because all chests on a surface share one virtual store. Compute once per surface, assign to all combinators on that surface.

**Note from principle engineer**: building a filter list every on_nth_tick is too aggressive. Should just update this when the chest is swept and virtual contents updated.

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
Past the `if chests[unit_number] then return end` guard, this runs once per fresh registration. Spawn CC at chest position, set `destructible = false` and `operable = false`, get the chest's `circuit_red`/`circuit_green` connectors and the CC's `combinator_output_red`/`combinator_output_green` connectors, and `connect_to(other, false, defines.wire_origin.script)` for both colors. Then `cc.get_or_create_control_behavior():add_section()` once so the update path can just assign `.filters`. Store `storage.cc_by_chest[unit_number] = cc`.

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

New helper:
```lua
local function update_all_combinators()
  local list = storage.surface_list
  for i = 1, #list do
    local surface_index = list[i]
    local filters = build_filters_for_surface(surface_index)
    local chests = storage.chests_by_surface[surface_index]
    if chests then
      for unit_number in pairs(chests) do
        local cc = storage.cc_by_chest[unit_number]
        if cc and cc.valid then
          local section = cc.get_or_create_control_behavior().get_section(1)
          if section then section.filters = filters end
        end
      end
    end
  end
end
```

Call at the **end of `on_step`** (after line 556 `storage.surface_list_cursor = surface_list_cursor`). This piggybacks on the existing `on_nth_tick(tick_interval)` handler — same UPS knob, same cadence — but walks **all surfaces**, not just those the consumer round-robin happened to visit. The consumer loop early-exits surfaces with no consumers (line 503 `if n > 0 then`), so coupling signal updates to that loop would silently break surfaces that have a wired chest but no turrets/furnaces yet.

Lag: signals are at most `tick_interval` ticks behind virtual storage state. Matches the rest of the mod's batching philosophy.

**Wire-connection optimization is intentionally skipped.** A `wire_connector.connection_count` check costs ~4 boundary calls per chest per step, close to the cost of just doing `section.filters = filters`. Add it only if profiling later shows it's needed.

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
7. **No lag spike:** with ~50 chests across multiple surfaces and varied virtual storage, watch `/measured-command` against `on_nth_tick`. The added work is one `build_filters_for_surface` per surface plus one `section.filters` assignment per chest per step.

## Critical files

- `/Users/aaron/code/factorio-ammo-loader-sa/data.lua`
- `/Users/aaron/code/factorio-ammo-loader-sa/control.lua`
- `/Users/aaron/code/factorio-ammo-loader-sa/info.json`
- `/Users/aaron/code/factorio-ammo-loader-sa/locale/en/loader.cfg`
