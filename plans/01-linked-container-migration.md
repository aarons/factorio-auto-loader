# Plan 01 — Convert auto-loader chest to per-surface linked-container

## Goal

Eliminate the per-consumer chest-iteration cost in `fill_one_inventory` (the
real `O(N·M)` hot path) by switching the chest from `container` to
`linked-container` with one shared inventory **per surface**.

After this, the per-step cost drops from
`consumers_on_surface × chests_on_surface × stacks_per_chest`
to
`consumers_on_surface × stacks_in_one_shared_inventory`.

## Non-goals
- Cross-surface inventory sharing. We're explicitly choosing **per-surface
  pools**, not global.
- User-configurable link_ids. The chest GUI will not expose link_id editing.
- Any logistics-bot integration. Linked containers can't be logistic
  requesters/providers; this was never a supported flow anyway.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Pool scope | One pool per surface | Matches existing mental model; cross-planet ammo pipes feel weird and would couple unrelated bases. |
| Inventory size | 100 slots | Playtesting may inform this size change |
| Inventory type | `with_filters_and_bar` | Player can pin slots to specific items. |
| link_id source | `fnv1a32("raleys-ammo-loader-" .. surface.name)` | Deterministic from surface identity; collision-resistant across mods; stable across save reloads. **Using surface NAME, not index** — indices aren't stable across saves, names are. |
| New entity name | `auto-loader-chest-linked` | Type changes (`container` → `linked-container`) under the same name are migration-hostile (forum bug 130815). New name + Lua migration is the safe pattern. |
| Item / recipe name | unchanged (`auto-loader-chest`) | Players' inventories and existing recipes keep working seamlessly. Only `item.place_result` changes. |
| Old prototype | Kept hidden in v2.0.0 for migration | Drop in a future version (e.g. v3.0.0) once we can assume all saves have migrated. |
| Version | 2.0.0 | Underlying entity type change warrants major bump even with clean migration. |

## Implementation

### Add linked-container prototype

Files: `data.lua`, `info.json`

- New entity prototype `auto-loader-chest-linked`:
  - `type = "linked-container"`
  - `inventory_size = 100`
  - `inventory_type = "with_filters_and_bar"`
  - `gui_mode = "all"` (no player-facing link_id field — the engine still
    shows whatever GUI it shows, which we'll verify; if it exposes link_id
    editing, we set `gui_mode = "none"` so the player can't change it)
  - Picture deepcopied from steel-chest with the existing tint applied
  - `circuit_wire_max_distance` left unset for now (not in scope)
  - `minable.result = "auto-loader-chest"` (item name unchanged)
- Old `auto-loader-chest` container prototype:
  - **Keep it** so the migration can still find existing entities on save load.
  - Add `flags = {"hidden"}` (or similar) so it doesn't appear in any
    pickers / filter lists going forward.
- Item `auto-loader-chest`:
  - `place_result = "auto-loader-chest-linked"` (was `"auto-loader-chest"`).
- Recipe `auto-loader-chest`: unchanged.
- `info.json`: bump version to `2.0.0`.

### Control logic refactor

Files: `control.lua`

- Add a 32-bit hash helper:
  ```lua
  local function fnv1a32(s)
    local hash = 0x811c9dc5
    for i = 1, #s do
      hash = bit32.bxor(hash, string.byte(s, i))
      hash = bit32.band(hash * 0x01000193, 0xffffffff)
    end
    if hash == 0 then hash = 1 end  -- never use the engine default 0
    return hash
  end
  local function link_id_for_surface(surface)
    return fnv1a32("raleys-ammo-loader-" .. surface.name)
  end
  ```
  ** Note from principle engineer: is this really necessary? We should not be adding single use functions. Keep the codebase clean and lean.
  ** Further note: why fallback to hash=1 and not something more unique? This is just asking for another collision with another mod.

- Storage shape change:
  - `storage.chests_by_surface` keeps the same structure (`{[surface_index] =
    {[unit_number] = entity}}`) — semantics shift from "iterate all chests on
    this surface" to "any one of these chests gives us the surface's shared
    inventory."
  - No new top-level fields needed.
- `register_chest`:
  - After registering, set `entity.link_id = link_id_for_surface(entity.surface)`.
  - Critical: do this immediately on the same tick the entity becomes valid,
    before any inserter or robot interacts with it (otherwise it briefly
    shares with default-0).
- New helper `get_shared_inventory(surface_index)`:
  - Walk `storage.chests_by_surface[surface_index]`, return the first valid
    chest's `get_inventory(defines.inventory.chest)`. Compact dead unit_numbers
    lazily as we walk. All chests on the surface resolve to the same logical
    inventory.
- `fill_one_inventory(consumer_inv, shared_inv)`:
  - Takes the shared inventory directly — **no chest loop**.
  - Single `shared_inv:get_contents()` per consumer fill.
  - Same insert/remove pattern as today, with the trigger logic stripped.
- `on_step`:
  - Per surface, resolve the shared inventory once before walking the
    consumer queue.
  - Skip the surface entirely if the inventory is nil or empty.
  - Otherwise pass the same `shared_inv` to every consumer fill in that
    surface's batch — avoids recomputing per consumer.

### Migration

Files: `migrations/2.0.0.lua` (new)

- Iterate `game.surfaces`.
- For each surface, `find_entities_filtered{name = "auto-loader-chest"}`.
- For each old chest:
  1. Snapshot inventory contents (`get_contents()` returns array of
     `{name, count, quality}` entries).
  2. Snapshot position, force, direction, last_user.
  3. Create new entity:
     `surface.create_entity{name = "auto-loader-chest-linked", position = ...,
     force = ..., direction = ..., raise_built = false}` (no event, we register
     manually after).
  4. Set `link_id` on the new entity from `link_id_for_surface(surface)`.
  5. Insert each snapshot stack into the new entity's inventory. Because all
     new chests on the surface share inventory, this naturally merges
     contents from N old chests into one pool.
  6. If insert returns less than the requested count (overflow), spill the
     remainder to the ground at the chest's position with
     `surface.spill_item_stack`. Print one `game.print` warning per surface
     summarizing total spilled so the player isn't surprised.
  7. `old_entity.destroy{raise_destroy = false}`.
- After all surfaces processed, `script.on_configuration_changed` already
  calls `reset_storage` + `scan_all_surfaces` + `refresh_settings`, which
  picks up the new chests via the normal registration path.

