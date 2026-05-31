# Auto-Loader — Architecture

A map of how the mod is structured today: the data-stage prototypes, the runtime data model, the per-tick algorithm, the GUI, and the circuit-network wiring.

---

## 1. What the mod does (one paragraph)

A single item — the **Auto-Loader Chest** — is placed on the map. Players drop ammo or fuel into it. Every tick (configurable), the mod tops up every compatible entity (turrets, vehicles, locomotives, burner machines, …) on the **same surface** up to a configurable `max_fill` per item-quality. All chests on the same surface share one inventory pool (via `linked-container`), one virtual ledger (per-surface table in `storage`), and one priority list. Circuit-network red/green wires connected to a chest read live virtual-storage counts (one signal per item × quality). The chest itself has no in-game GUI for filtering or settings — instead, opening one shows a relative-anchored "priority" panel listing every item the chest has ever seen, with up/down/top/bottom reordering, a per-item quality-iteration strategy, and a click-to-take-stack button.

---

## 2. File layout

| File | Stage | Role |
|---|---|---|
| `info.json` | — | Mod manifest. Depends on `base`, optional `space-age`. Factorio 2.0. |
| `settings.lua` | settings | 2 startup + 5 runtime-global settings. |
| `data.lua` | data | Prototypes: tinted `linked-container` chest, paired hidden `constant-combinator`, item, recipe, tech unlock. |
| `control.lua` | runtime | Event handlers, storage shape, sweep/fill loop, circuit-signal projection. ~840 LOC. |
| `gui.lua` | runtime | Relative-anchored priority panel. ~355 LOC. Bound from `control.lua` via `gui.bind(deps)`. |
| `locale/en/loader.cfg` | — | All player-visible strings. |
| `archive/`, `plans/`, `auto-loader-chest_2.6.1.zip` | — | Out-of-band; not loaded. |

`control.lua` does `local gui = require("gui")` and calls `gui.bind({...})` to inject three values (`CHEST_NAME`, `quality_order_for`, `update_combinators_for_surface`) — there is no circular `require`. `gui.lua` reads `storage` directly.

---

## 3. Prototype layer (`data.lua`)

Three prototypes are emitted plus one tech effect:

### 3.1 `auto-loader-chest-linked` — the chest entity
- **Type: `linked-container`.** Built by `table.deepcopy`-ing the vanilla `steel-chest` and overriding type, name, inventory size (100), `inventory_type = "with_bar"`, `gui_mode = "none"`, sprite tint (amber, `r=1.0, g=0.85, b=0.2`).
- `placeable_by = { item = "auto-loader-chest" }` and `minable.result = "auto-loader-chest"` so the player sees a normal item, not a hidden linked-container item.
- `circuit_wire_max_distance` + `circuit_connector` copied from steel-chest so player wires can attach. (Linked containers don't normally have circuit ports; the chest gets them only because we copy the steel-chest prototype's circuit_connector definition.)
- Tinting is applied recursively to `picture.layers`/`picture.sheets`/`picture.sheet`, skipping `draw_as_shadow` layers, then to `icons`.

### 3.2 `auto-loader-chest-cc` — paired hidden constant-combinator
A per-chest invisible CC that holds the projected virtual-storage signals. Heavily neutered:
- `hidden = true`, `selectable_in_game = false`, `allow_copy_paste = false`.
- Empty collision/selection boxes (zero-area).
- Empty `sprites`, `activity_led_sprites`, zero-area `circuit_wire_connection_points`, `draw_circuit_wires = false`, `draw_copper_wires = false`.
- Flags: `placeable-off-grid`, `not-on-map`, `not-deconstructable`, `not-blueprintable`, `not-selectable-in-game`, `hide-alt-info`, `no-automated-item-removal`, `no-automated-item-insertion`.

The CC is what the chest's circuit ports actually read from — see §7.

### 3.3 Item + recipe
- `auto-loader-chest` item: `place_result = "auto-loader-chest-linked"`, stack 50, subgroup `logistic-network`.
- Recipe: ingredients chosen from `INGREDIENTS_BY_COST[cost]` where `cost ∈ {cheat, easy, normal, expensive}` (note: `normal` and `expensive` have identical recipes today — a leftover from a prior split).
- Recipe `enabled` only if `cost == "cheat"`. Otherwise it's unlocked by appending an `unlock-recipe` effect to a tech selected by `TECH_BY_AVAILABILITY[availability]` (`electronics`, `construction-robotics`, `logistic-robotics`).

### 3.4 Decisions worth noting
- The chest is a `linked-container`, not a normal `container`. That's how "all chests on a surface share one inventory" works — Factorio engine groups linked containers by `link_id`, set at runtime (§4.3).
- The CC is a separate entity rather than e.g. logistic filters on the chest itself, because:
  - `linked-container` has no `logistic_section` of its own.
  - A CC supports per-item *and per-quality* output signals, matching the virtual-storage shape.

---

## 4. Runtime data model (`storage`)

All persistent state lives under the standard `storage` table. Initialized in `reset_storage()` on `on_init` / `on_configuration_changed`.

### 4.1 Per-surface state

| Key | Shape | Purpose |
|---|---|---|
| `chests_by_surface[surface_index]` | `{ [chest_unit_number] = LuaEntity }` | Every chest on the surface. |
| `shared_chest[surface_index]` | `LuaEntity` | Hot-path cache: any one valid chest, used to grab the shared linked-container inventory in O(1). Rescans on invalidation. |
| `consumer_queue[surface_index]` | `array<consumer>` | Round-robin list. See §4.4. |
| `consumer_cursor[surface_index]` | `int` | Position within `consumer_queue[surface_index]`, preserved across steps. |
| `virtual[surface_index]` | `{ fuel, ammo, fuel_order, ammo_order }` | The virtual ledger. See §4.2. |
| `last_sweep_tick[surface_index]` | `int` (game.tick) | Throttle — sweep at most once per 60 ticks per surface. |

### 4.2 Virtual ledger (`storage.virtual[surface_index]`)

```
v = {
  fuel = { [item_name] = { strategy = "lowest_quality_first", totals = { [quality] = count, ... } }, ... },
  ammo = { same shape },
  fuel_order = { item_name_1, item_name_2, ... },  -- priority order, [1] = highest
  ammo_order = { item_name_1, item_name_2, ... },
}
```

- Items are classified by name into `fuel` or `ammo` once at startup (§4.6).
- `totals` are pure Lua numbers — the chest entity holds no items between sweeps.
- `strategy ∈ {"highest_quality_first","lowest_quality_first","highest_count_first","lowest_count_first"}`. New items adopt the default for their category from the runtime setting.
- `fuel_order` / `ammo_order` are mutated in place by the GUI (move up/down/top/bottom) and appended to on first-sight in `sweep_into_virtual`.

### 4.3 Chest ↔ CC mapping and link_id

| Key | Shape | Purpose |
|---|---|---|
| `chest_surface[unit_number]` | `int` | Reverse map for O(1) destroy handling. |
| `cc_by_chest[unit_number]` | `LuaEntity` | The paired constant-combinator. |

`link_id_for_surface(surface)` is a **FNV-1a hash of `"raleys-auto-loader-" .. surface.name`**, masked to 32 bits. The prefix is mod-scoped so it can't collide with any other linked-container the player places. Hashing the surface **name** (not index) means save/load is stable: surface indices are not persistent across reloads, but names are.

`register_chest` *always* re-sets `entity.link_id`, even on chests that already look registered, so a chest arriving via clone/blueprint paste/script with a stale or default `link_id` gets joined to the surface pool before any inserter can touch it.

### 4.4 Consumer registry

```
consumer = {
  entity        = LuaEntity,
  unit_number   = int,
  surface_index = int,
  has_fuel      = bool,    -- entity.get_fuel_inventory() ~= nil at registration time
  ammo_idx      = int|nil, -- defines.inventory.* index for this entity's ammo inventory
}
```

The **same record** is referenced from two places:
- `consumer_queue[surface_index]` — round-robin iteration order.
- `storage.consumers[unit_number]` — O(1) dedup at registration, O(1) lookup in destroy handler.

`has_fuel` / `ammo_idx` are cached at register-time to avoid `entity.type` lookups in the hot fill path.

### 4.5 Round-robin axes

```
surface_list        = array<surface_index>      -- which surfaces have anything to do
surface_list_cursor = int                       -- resume position across on_step calls
```

The outer round-robin axis: `on_step` cycles surfaces; each surface has its own inner round-robin axis (`consumer_cursor[surface_index]`). See §6.4.

### 4.6 Module-level (not in storage)

These are local module variables, rebuilt on `on_init` / `on_configuration_changed` / `on_load` from the live prototype tables. They are **mutated in place** so any closures that captured them (none today, but the comment in code calls this out) stay valid.

- `FUEL_ITEMS[name] = true` — every prototype with `fuel_category`.
- `AMMO_ITEMS[name] = true` — every prototype with `type == "ammo"`.
- `QUALITY_ASC[i]` / `QUALITY_DESC[i]` — quality names sorted by `prototype.level` ascending / descending. Used as the cached iteration order for `highest_quality_first` / `lowest_quality_first` strategies.

### 4.7 GUI-only

- `alc_open_chest[player_index]` — surface_index of the chest a player has open.
- `alc_open_tab[player_index]` — `"fuel" | "ammo"`, last-selected tab.

### 4.8 Settings (module-local cache)

Refreshed by `refresh_settings()`:
- `batch_size`, `tick_interval`, `max_fill`, `default_fuel_strategy`, `default_ammo_strategy`.

`auto-loader-chest-insert-overrides` is in `settings.lua`? **No — the README mentions it but it does not exist in `settings.lua`.** This is a documentation drift to flag: the runtime path uses a uniform `max_fill` (clamped by stack size) and has no per-item override.

---

## 5. Lifecycle: events → handlers

### 5.1 Mod lifecycle

| Event | Handler | What it does |
|---|---|---|
| `on_init` | inline | `rebuild_item_kind_sets()` → `rebuild_quality_orders()` → `reset_storage()` → `refresh_settings()` → `scan_all_surfaces()` → `reapply_on_nth_tick()` |
| `on_configuration_changed` | inline | Same sequence. State is wiped and rebuilt — this is the migration path. No incremental migration is attempted. |
| `on_load` | inline | Recomputes derived module-local data only: `rebuild_item_kind_sets()`, `rebuild_quality_orders()`, `refresh_settings()`, `reapply_on_nth_tick()`. No `storage` writes (forbidden in `on_load`). |
| `on_runtime_mod_setting_changed` | inline | If one of the five known runtime settings changed: `refresh_settings()` + `reapply_on_nth_tick()`. |

### 5.2 Surfaces

| Event | Handler |
|---|---|
| `on_surface_created` | `init_surface(surface_index)` — allocate per-surface tables, add to `surface_list`. |
| `on_surface_deleted` | `clear_surface(surface_index)` — drop all consumers, destroy CCs, free per-surface tables, remove from `surface_list`. |
| `on_surface_cleared` | `clear_surface(...)` then `init_surface(...)`. |

### 5.3 Entity placement / cloning

Six events all funnel through `handle_built_entity(entity)`:

- `on_built_entity`, `on_robot_built_entity`, `on_space_platform_built_entity`, `script_raised_built`, `script_raised_revive` → `on_built(event)` → `handle_built_entity(event.entity or event.created_entity)`.
- `on_entity_cloned` → `on_cloned(event)` → `handle_built_entity(event.destination)`.

`handle_built_entity` branches on `entity.name == CHEST_NAME`:
- **Chest:** `register_chest(entity)` — sets `link_id`, registers in `chests_by_surface`, spawns CC, script-wires CC to chest's red+green ports, seeds CC filters from current virtual state.
- **Anything else:** `try_register_consumer(entity)` — if the entity has a fuel inventory or a known ammo inventory, register it and immediately do an instant-fill.

### 5.4 Player characters

The player character is also a consumer (it has `defines.inventory.character_ammo`). `on_player_created` and `on_player_respawned` route through `handle_built_entity(player.character)`, so a player's character is treated like any other ammo-bearing entity. (Fuel-wise, a character has no `get_fuel_inventory()`.)

### 5.5 Destruction

`on_object_destroyed` is used for both chests and consumers — both register via `script.register_on_object_destroyed(entity)`. Dispatch:
1. Look up `useful_id` in `storage.consumers` — if found, clear and return.
2. Otherwise check `storage.chest_surface` — if found, remove from `chests_by_surface`, clear `shared_chest` cache if it pointed at this chest, and destroy + clear the paired CC.

A destroyed consumer is **not** removed from `consumer_queue` here — that would be O(n). Instead the queue slot becomes "orphan" and is swap-popped the next time `on_step` visits it (see §6.4).

### 5.6 GUI

`on_gui_opened`, `on_gui_closed`, `on_gui_click` route to `gui.on_gui_opened` / `gui.on_gui_closed` / `gui.on_gui_click`. See §8.

### 5.7 Tick

`script.on_nth_tick(tick_interval, on_step)` — re-installed by `reapply_on_nth_tick()` whenever the interval setting changes. `current_nth_tick` tracks the currently-installed interval so the old handler can be uninstalled.

---

## 6. Per-step algorithm (`on_step` and friends)

This is the heart of the mod. Walking it from outermost to innermost.

### 6.1 Sweep into virtual (`sweep_into_virtual`)

Per surface, throttled to **at most once per 60 ticks** (`last_sweep_tick`). Operates on the linked-container inventory:

- For each occupied stack `i` in slot order:
  - Classify by name: `AMMO_ITEMS[name]` → `v.ammo`, else `FUEL_ITEMS[name]` → `v.fuel`, else skip.
  - If this is the first sighting of `name`, create `{ strategy = default_strategy, totals = {} }` and append to the matching `*_order` (so first-arrival order seeds priority).
  - `entry.totals[quality] += stack.count`, then `stack.count = 0` (the item is removed from the visible chest).

After the sweep, the chest is empty; the count lives only in `v`. The chest is intentionally left visible to players in the brief window before sweep so they see in-flight stock (the 60-tick throttle is what makes that window real).

### 6.2 Build per-step context (`build_step_context`)

Per surface, run **once per step**:

- For each name in `v.fuel_order` (then `v.ammo_order`), in order:
  - `quality_order_for(entry)` produces the quality-iteration list for that entry, depending on strategy:
    - `highest_quality_first` → reuse module-level `QUALITY_DESC`.
    - `lowest_quality_first` → reuse module-level `QUALITY_ASC`.
    - `highest_count_first` → sort entry's non-zero qualities by count desc.
    - `lowest_count_first` → sort entry's non-zero qualities by count asc.
  - Emit `{ name, totals, q_order }`.

- Output: `{ fuel_entries, fuel_count, ammo_entries, ammo_count, taken = {} }`.

`taken[name][quality] = count_taken_so_far_this_step` — accumulator shared across all consumers in this step. The **deferred-commit invariant**: `totals` are not decremented while filling; consumers reading `totals[quality]` always see the same step-start snapshot, and "what's left" is `totals[q] - taken[name][q]`. This means consumer fills within a step don't reshuffle priority order (a count-based strategy doesn't oscillate as we fill).

### 6.3 Fill a single consumer (`fill_consumer`)

Two branches, run sequentially for one consumer:

**Fuel** (`fill_fuel_first_slot`): only **slot 1** of the fuel inventory is managed. The reason: locomotives, vehicles, and similar can have multi-slot fuel inventories, and if we touched slot 2+ a mix of priority entries would scatter different fuels across slots. Players keep manual control of slots 2+.
- If slot 1 has an item already: try to top up the *same* item+quality from `entries`, capped to `min(max_fill, stack_size)`. If the item isn't in our priority list at all, do nothing.
- If slot 1 is empty: iterate `entries` in priority order; for each entry iterate `q_order`; the first `(name, quality)` with available stock is inserted via `set_stack{...}`, capped to `min(max_fill, stack_size)`.

**Ammo** (`fill_one_inventory`): general-purpose inventory fill.
- Aggregate the consumer's current contents in **one** boundary call (`consumer_inv.get_contents()`), keyed `"name|quality"`.
- For each entry in priority order, for each quality in `q_order`:
  - `want = max_fill - have`. If `want > 0` and `available > 0`, insert `min(available, want)` via `consumer_inv.insert{...}`.
  - Update `taken`, update local `current`, early-return on `consumer_inv.is_full()`.

### 6.4 Tick loop (`on_step`)

The outer surface round-robin:

```
while processed < batch_size and surfaces_visited < n_surfaces:
  surface = surface_list[surface_list_cursor]
  queue   = consumer_queue[surface]
  if queue not empty:
    if now - last_sweep_tick[surface] >= 60: sweep_into_virtual(shared_inv, surface)
    ctx = build_step_context(surface)
    if ctx has fuel or ammo:
      cursor = consumer_cursor[surface]
      cycle_complete = false
      while processed < batch_size and queue not empty:
        consumer = queue[cursor]
        if consumer.valid:
          fill_consumer(consumer, ctx)
          processed += 1
          cursor += 1
        else:
          # orphan: swap-pop, leave cursor where it is
          swap_pop(queue, cursor)
        if cursor > #queue:
          cursor = 1
          cycle_complete = true
          break
      consumer_cursor[surface] = cursor
      commit_step(ctx, surface)                 # subtract `taken` from totals
      update_combinators_for_surface(surface)   # push new totals to circuit signals
      advance_surface = cycle_complete or queue empty
    else:
      advance_surface = true
  else:
    advance_surface = true
  if advance_surface:
    surface_list_cursor = next; surfaces_visited += 1
  else:
    break                                       # ran out of budget on this surface
```

Key invariants:
- `batch_size` is a **global** per-step budget, shared across all surfaces. Big multi-surface bases share UPS budget fairly across surfaces by the outer round-robin.
- A surface's `consumer_cursor` is preserved across steps — we resume mid-cycle next time.
- Orphans (consumers whose entity went invalid without `on_object_destroyed` firing, e.g. replay edge cases) are swap-popped lazily and their `storage.consumers[unit_number]` entry is also cleared as belt-and-suspenders.
- `surfaces_visited < n_surfaces` is the termination guarantee in case every surface has nothing to give (empty virtual or empty queue).

### 6.5 Commit (`commit_step`)

Applies `ctx.taken` to `v.totals`:
- For each `(name, quality)` in `taken`: `totals[q] = max(0, totals[q] - taken)`. If reduced to 0, the entry is set to `nil` (so iteration in §7.1 skips it).

The per-`name` entry itself (with its `strategy` and now-empty `totals`) is left in place. So is its position in `*_order`. **The priority list never shrinks** as long as a name has been seen at least once. This is deliberate — it preserves the player's per-item strategy and priority position across drain-and-refill cycles. It also means deprecation of items requires an explicit player action (today there is none).

### 6.6 Instant-fill on placement

`try_register_consumer` ends with an immediate `fill_consumer + commit_step + update_combinators_for_surface` so a freshly-built turret doesn't sit empty for up to a full step waiting for the round-robin cursor to come around. This uses the same `build_step_context` snapshot machinery.

---

## 7. Circuit network integration

This is the most intricate piece — the chest's circuit ports are wired to a hidden CC that mirrors virtual storage.

### 7.1 Building the filter list (`build_filters_for_surface`)

For one surface:
- For each category (`v.fuel`, `v.ammo`), for each `(name, entry)`, for each `(quality, count)` with `count > 0`:
  - Emit `{ value = { type = "item", name = name, quality = quality, comparator = "=" }, min = clamp(count, INT32_MAX) }`.
- No de-duplication needed because `sweep_into_virtual` classifies each name as exactly one of fuel/ammo (mutually exclusive `if/elseif`).
- `INT32_MAX` clamp: circuit signals are int32. Virtual counts are Lua numbers (~doubles) and could in theory exceed that — clamp to avoid overflow when assigning to the logistic filter.

Output goes into a constant-combinator logistic section as filters with `min` values, which makes them appear as output signals.

### 7.2 Pushing filters to chests (`update_combinators_for_surface`)

For one surface: build the filter list once, assign it to **every** chest's paired CC's section 1. The same `filters` table is shared by reference — there's no per-chest data, only per-surface.

Called only at mutation points:
- End of `on_step` after a fill cycle for that surface.
- `try_register_consumer` after the instant-fill.
- `register_chest` (the new chest needs its CC seeded — does so via `build_filters_for_surface` inline rather than calling `update_combinators_for_surface` which would re-loop all chests).
- `gui.on_gui_click` after `take_stack` mutates virtual storage.

Idle surfaces never enter this path, so the cost is bounded by real activity.

### 7.3 Wiring the CC to the chest (`register_chest`)

For each new chest at `position`:
1. `surface.create_entity{ name = CC_NAME, position = entity.position, force = entity.force, raise_built = false, create_build_effect_smoke = false }`.
2. Set `cc.destructible = false`, `cc.operable = false`.
3. Get the chest's and CC's red+green wire connectors. `chest.get_wire_connector(defines.wire_connector_id.circuit_red, true)` (the `true` creates if absent).
4. `cc_red.connect_to(chest_red, false, defines.wire_origin.script)` — and same for green.
   - **Dot syntax**, not colon. `LuaWireConnector` methods already bind self via `__index`; calling with `:` double-passes self and the engine reports type errors.
   - `false` is `reach_check` — chest and CC are at the same position, so the default reach test would fail.
   - `defines.wire_origin.script` keeps the wire invisible and not player-undoable.
5. `behaviour.enabled = true` so the CC emits signals.
6. `behaviour.get_section(1)` returns the pre-existing section 1. **Do not** call `add_section()` on a fresh CC — it returns `nil` and downstream "bad self" errors follow.
7. Seed `section.filters = build_filters_for_surface(surface_index)`.

When a player plugs a red or green wire into the chest, they read the CC's output signals, transparently.

### 7.4 Lifecycle of CCs

- Created in `register_chest`.
- Destroyed in `on_object_destroyed` (chest branch) and `clear_surface`.
- `scan_all_surfaces` (called from `on_init` / `on_configuration_changed`) destroys all existing `auto-loader-chest-cc` entities **before** re-registering chests, because `reset_storage` cleared `cc_by_chest` and the world might still have orphan CCs from a prior version.

---

## 8. GUI architecture (`gui.lua`)

A relative-anchored frame on the right side of the vanilla linked-container GUI.

### 8.1 Frame and tabs

- Frame name: `alc_priority_frame`. Anchored `defines.relative_gui_position.right` of `defines.relative_gui_type.linked_container_gui` for entity `CHEST_NAME`.
- Two tabs: `fuel` and `ammo`. The active tab is the disabled button (visual state); state is in `storage.alc_open_tab[player_index]`, default `"ammo"`.
- Below the tab bar, a vertical inner frame (`inside_shallow_frame_with_padding`) holds the priority list for the active tab.

### 8.2 Priority table

Three columns per row (the table is `column_count = 3`):

1. **Item button** (`sprite-button`, `slot_button` style) showing the item sprite and total count across all qualities. Tag `alc_action = "take_stack"`.
2. **Arrow flow** with four arrow buttons (`speed_up`, `expand`, `collapse`, `speed_down`) — top / up / down / bottom. First/last positions disable the relevant arrows.
3. **Strategy button** showing one of `Q↓ / Q↑ / N↓ / N↑` (`STRATEGY_BUTTON_CAPTION`). Left-click cycles forward, right-click cycles backward.

Wrapped in a `scroll-pane` with `maximal_height = 400`, `minimal_width = 280`.

If `*_order` is empty for the active tab, the GUI shows `alc.empty-priority` instead.

### 8.3 Events

- `on_gui_opened` (entity, `name == CHEST_NAME`) — record `alc_open_chest[player] = surface_index`, build frame.
- `on_gui_closed` (entity, `name == CHEST_NAME`) — clear `alc_open_chest[player]`, destroy frame.
- `on_gui_click` — dispatches on `element.tags.alc_action`:
  - `"tab"` → flip `alc_open_tab`, rebuild frame.
  - `"up" / "down" / "top" / "bottom"` → mutate `*_order` array directly, then `refresh_priority_items_for_player`.
  - `"take_stack"` → pick the next quality with stock per the entry's strategy, transfer up to `stack_size` to the player's cursor (top up if same item+quality already on cursor), update `totals`, call `update_combinators_for_surface` (because virtual storage changed), then `refresh_priority_items_for_player`.
  - `"strategy_cycle"` → cycle `entry.strategy` via `STRATEGY_NAME_TO_INDEX`, direction depending on left vs right mouse button, then refresh.

### 8.4 Refresh strategy

`refresh_priority_items_for_player` clears `items_table` and re-runs `populate_priority_table` in place, **preserving the scroll-pane** (and thus scroll position). Falls back to a full rebuild via `build_gui_for_player` if the shape needs to change (empty-state ↔ populated).

This is the only path that needs to be careful about preserving scroll. The full rebuild paths (`build_gui_for_player`) are used for tab changes and initial open.

### 8.5 GUI ↔ control coupling

The GUI mutates `storage.virtual` directly (priority reorder, strategy change, take_stack). It does **not** mutate the tick loop's state; the next `on_step` reads the new state organically. The one place the GUI calls back into control is `update_combinators_for_surface` after a take_stack, so circuit signals don't lag a tick.

---

## 9. Quality handling

Quality is one of three Space-Age-introduced concepts the mod has to handle (the others are surfaces and per-quality stack handling, both already covered).

- **Per-quality counts** in `entry.totals[quality]`. Every (item, quality) is a distinct slot in the virtual ledger and a distinct output signal on the CC.
- **`stack.quality.name`** is the key — falls back to `"normal"` in `fill_fuel_first_slot` only because the slot-1 read path explicitly handles `slot.quality and slot.quality.name or "normal"`.
- **Strategy** decides quality iteration order within one item:
  - `highest_quality_first` / `lowest_quality_first` use cached `QUALITY_DESC` / `QUALITY_ASC`, sorted by `prototype.level`.
  - `highest_count_first` / `lowest_count_first` re-sort the entry's qualities by count on each step (allocates a small list per entry per step).
- Default strategy at item-first-sight: `default_fuel_strategy` for fuel, `default_ammo_strategy` for ammo. Defaults today: fuel = `lowest_quality_first`, ammo = `highest_quality_first` — i.e. burn the cheap stuff, shoot the expensive stuff.

---

## 10. Settings (`settings.lua` and consumers)

| Setting | Type | Default | Used by |
|---|---|---|---|
| `auto-loader-chest-cost` | startup-string | `"normal"` | `data.lua` — selects recipe ingredients. |
| `auto-loader-chest-availability` | startup-string | `"normal"` | `data.lua` — selects unlock tech. |
| `auto-loader-chest-batch-size` | runtime-global-int (1–1000) | 10 | `on_step` — total consumer-fills per step across surfaces. |
| `auto-loader-chest-tick-interval` | runtime-global-int (1–600) | 1 | `script.on_nth_tick` registration. |
| `auto-loader-chest-max-fill` | runtime-global-int (1–1000) | 10 | `fill_fuel_first_slot` and `fill_one_inventory` — fill cap per (item, quality), clamped by `stack_size`. |
| `auto-loader-chest-default-fuel-strategy` | runtime-global-string | `"lowest_quality_first"` | `sweep_into_virtual` — default strategy for new fuel items. |
| `auto-loader-chest-default-ammo-strategy` | runtime-global-string | `"highest_quality_first"` | `sweep_into_virtual` — default strategy for new ammo items. |

Note: README references `auto-loader-chest-insert-overrides` (per-item max overrides). This setting does **not exist** in `settings.lua` — the README is stale. The current model is "uniform `max_fill`, clamped to stack size", which already handles the awkward cases (nuclear fuel stack size 1, etc.) but is less expressive than the README claims.

---

## 11. Cross-cutting invariants

A list of contracts the code relies on

1. **Linked-container = surface-wide pool.** All chests on a surface have the same `link_id` and therefore share inventory. This is structural; removing it changes the user model.
2. **Virtual storage is the ledger; the linked-container is a brief courier.** Items spend at most ~60 ticks in the visible chest before being swept into `v`.
3. **Per-name classification is mutually exclusive.** A name is either fuel or ammo, decided at startup.
4. **`*_order` is monotonically appending** — once a name is seen, it stays in the order list. There is no "forget this item" path. The list grows over a save's lifetime.
5. **Strategies are per-(name, surface).** Two surfaces independently track strategies for the same item.
6. **Round-robin fairness:** outer over surfaces, inner over consumers. `batch_size` is global. A surface with many consumers gets proportionally less per-consumer attention if other surfaces have queues too.
7. **Deferred commit:** within a single step, consumers read a frozen snapshot of `totals`; the commit at end-of-step is the only mutation. This is what keeps count-based strategies stable across the step.
8. **Fuel: slot 1 only.** Multi-slot fuel inventories keep manual control of slots 2+.
9. **CC output = surface virtual state, always live.** Updated at every mutation point. Single section, single filter list, shared by reference across all chests on the surface.
10. **`reset_storage` is the migration path.** `on_configuration_changed` blows everything away and rebuilds from world scan. No incremental schema migration.
11. **`storage.consumers` and `consumer_queue` are dual-indexed**; orphan cleanup happens in the tick loop, not the destroy handler.
12. **`shared_chest[surface]` is a lazy cache** that can become invalid; `get_shared_inventory` rescans on miss.
13. **`link_id` is hashed off surface name**, not index — stable across save/load.
14. **`scan_all_surfaces` destroys orphan CCs** before re-registering chests on configuration change.
15. **CC wiring uses dot syntax + `wire_origin.script` + `reach_check=false`**. Three subtle traps documented inline.
16. **GUI never mutates the tick state** — only `storage.virtual` and `cc_by_chest` (via `update_combinators_for_surface`).


