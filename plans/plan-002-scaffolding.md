# Completed!

**Summary**

  - info.json — Factorio 2.0 manifest, base required, space-age optional.
  - data.lua — Deepcopies active-provider-chest, switches type to container, drops all LogisticContainerPrototype-only fields
  (logistic_mode, max_logistic_slots, render_not_in_network_icon, opened_duration, trash_inventory_size, animation, animation_sound,
  landing_location_offset, use_exact_mode), promotes animation → picture if needed (vanilla active-provider-chest defines visuals as
  animation), tints all non-shadow sprite layers and icons amber {1.0, 0.85, 0.2}. Adds matching item (stack_size 50) and recipe (1
  steel-chest + 2 electronic-circuit, enabled by default — no tech gating per plan-001 §5).
  - settings.lua — Two runtime-global int settings: auto-loader-chest-batch-size (default 10) and auto-loader-chest-tick-interval
  (default 15, per plan-002's note that 15 — not plan-001's 1 — is the authoritative number).
  - locale/en/loader.cfg — All required sections.

  No control.lua was created (correctly out of scope for chunk A). Validation steps in plan-002 §"Validation for this chunk" require
  running Factorio, which I can't do here — you'll need to load the mod and confirm the log is clean, the chest crafts/places, the amber
  tint reads as visibly distinct from a vanilla active-provider-chest, and the settings menu shows the two settings with locale strings.

  One assumption worth flagging: I set the item's subgroup = "logistic-network" to match where vanilla logistic-chest items live. If the
  user prefers it grouped with storage (steel-chest's group), it's a one-line change.


Original Context:

# Chunk A — Mod scaffolding & data-stage prototypes

**Parent plan:** [`plan-001.md`](plan-001.md). Read it first for full design context, API rationale, and non-goals. This file scopes the first of three sequential implementation chunks.

## Goal

Stand up a loadable Factorio 2.0 mod that adds the auto-loader chest as a placeable, craftable, visually-distinct entity. **No runtime logic yet** — chunks B and C add that. After this chunk, the chest exists in the game and can be placed, but nothing happens when items are put in it.

## Files to create

```
info.json
data.lua
settings.lua
locale/en/loader.cfg
```

No `control.lua` in this chunk — Factorio doesn't require it for pure data-stage mods, and adding it now invites scope creep.

## Tasks

### 1. `info.json`

Standard Factorio 2.0 manifest:
- `factorio_version`: `"2.0"`
- `name`: `"auto-loader-chest"`
- `dependencies`: `["base", "? space-age"]` (space-age optional)
- Pick a sensible `version`, `title`, `author`, `description`. Author can be the repo owner; title `"Auto-Loader Chest"`.

### 2. `data.lua` — chest prototype, item, recipe

Per plan-001 §"`data.lua` — chest entity":

1. `local chest = table.deepcopy(data.raw["logistic-container"]["active-provider-chest"])`
2. `chest.type = "container"`; `chest.name = "auto-loader-chest"`. Drop logistic-only fields (`logistic_mode`, `max_logistic_slots`, etc.) — anything that errors when `type="container"`.
3. Keep or set `inventory_size = 48` (steel-chest parity).
4. **Tint the sprite.** Walk `chest.picture.sheets` and/or `chest.picture.layers` (deepcopy and inspect — 2.0 uses one or the other depending on prototype). Set `tint = {r=1.0, g=0.85, b=0.2, a=1.0}` (amber) on each layer. Same for `icon` / `icons` — if it's a flat `icon`, convert to `icons = {{icon=<path>, icon_size=<size>, tint=<...>}}`.
5. Item: `type="item"`, `name="auto-loader-chest"`, `place_result="auto-loader-chest"`, `stack_size=50`, reuse the tinted icon.
6. Recipe: `type="recipe"`, `name="auto-loader-chest"`, cheap ingredients (e.g. 1 steel-chest + 2 electronic-circuit), `enabled=true` (no tech gating in v1).
7. `data:extend{ chest, item, recipe }`.

Watch out for: in 2.0, the active-provider-chest prototype is under `data.raw["logistic-container"]`, not `data.raw["container"]`. Plan-001 line 42 has the parenthetical correction.

### 3. `settings.lua`

Two `int-setting` entries, `setting_type = "runtime-global"`:

- `auto-loader-chest-batch-size`: default 10, min 1, max 1000.
- `auto-loader-chest-tick-interval`: default 15, min 1, max 600. *(Note: plan-001 line 111 says default 1, but §UPS budget line 173 assumes 15. Use 15 — the budget reasoning is the authoritative number.)*

### 4. `locale/en/loader.cfg`

Sections needed:
```
[entity-name]
auto-loader-chest=Auto-Loader Chest

[item-name]
auto-loader-chest=Auto-Loader Chest

[recipe-name]
auto-loader-chest=Auto-Loader Chest

[entity-description]
auto-loader-chest=Automatically refills ammo and fuel of nearby compatible entities on the same surface.

[mod-setting-name]
auto-loader-chest-batch-size=Auto-loader chest: consumers per tick step
auto-loader-chest-tick-interval=Auto-loader chest: ticks between steps

[mod-setting-description]
auto-loader-chest-batch-size=How many consumer entities the mod processes each step. Higher = faster top-ups, slightly more UPS cost.
auto-loader-chest-tick-interval=How often (in ticks) the mod runs a processing step. Higher = lower UPS cost, slower top-ups.
```

## Validation for this chunk

- [ ] `factorio-current.log` shows the mod loading with no errors.
- [ ] In a fresh creative game, `auto-loader-chest` appears in the player inventory via `/c game.player.insert("auto-loader-chest")`.
- [ ] Recipe appears in the crafting menu (look under logistics or storage).
- [ ] Placed chest is **visibly amber-tinted** — clearly distinct from a vanilla active-provider-chest sitting next to it.
- [ ] Mod settings menu shows both runtime settings with the locale strings above (not the raw IDs).
- [ ] No runtime behavior expected yet — putting items in the chest does nothing. That's correct for this chunk.

## Out of scope (chunk B / C)

- `control.lua`, `storage`, event handlers, fill logic, settings runtime wiring, README updates. Do not write these here.
