# Auto-Loader

This mod adds an Auto-Loader chest that fills ammo and fuel in entities on the same surface.

This is inspired by ammo-loader; but updated to handle quality ammo and fuel, as well as improve UPS efficiency.

## How it works

**Supply (`data.lua` + `control.lua`).** The chest is a vanilla `linked-chest`
derivative. On build we set its `link_id` to the surface index, so every
Auto-Loader chest on a surface shares one pooled inventory (linked-container
inventories are keyed by prototype name, force, and `link_id`). Stock fuel and
ammo into any of them.

**Fill engine (`control.lua`).** A registry of fillable entities (ammo turrets,
artillery, vehicles, characters, and any burner) is built from the build/clone
events plus an initial surface scan, with `register_on_object_destroyed` as the
removal backstop. Each tick a bounded round-robin sweep processes K entities
(the `auto-loader-entities-per-tick` runtime setting, default 10), advancing a
persistent cursor so cost is constant regardless of how many entities exist. For
each surface touched in a tick the pool is read once, decremented locally as
inserts happen, and written back with a single `remove` at tick end.

Fill rules: skip anything marked for deconstruction; never fill another force's
entities; locomotives only get their first fuel slot; characters only get ammo
for categories of a currently-equipped gun; ammo is capped at the turret's
`automated_ammo_count` (default 10) so nothing drains the pool. Quality is
respected — items are inserted at the quality the pool holds and only where the
entity accepts them.

### Why polling, not events

There is **no event for ammo or fuel consumption**, and no inventory-changed
event for non-player entities — ammo only drops when a turret fires, fuel only
when a burner works, and neither raises anything. Alerts are poll-only and
`LuaPlayer::get_alerts` returns nothing on a player-less dedicated server, so
they are unusable as a trigger. Hence the self-maintained registry and bounded
sweep.

### Not yet built (future tiers)

- **Status gating / deadline scheduling for fuel** — skip burners that can't be
  empty yet (compute ticks-until-dry from fuel value and burn rate) so they fall
  off the sweep until they need attention.
- **Combat-aware turret topping** (driven by `on_entity_damaged`) — proactively
  refill turrets that are actually firing instead of waiting for the sweep.

## Dev Notes on Events

This is a list of all events, we are looking for ones that could be used to inform us of an entity needing fuel or ammo. Any kind of activity around combat, or items created etc.

Might be used to detect new units (initial fill):
on_area_cloned
on_built_entity
on_entity_cloned
on_entity_spawned
on_robot_built_entity
on_space_platform_built_entity
on_surface_imported
on_train_created
script_raised_built
script_raised_revive

Might be used to indicate interest to eval an entity:
on_gui_hover
on_gui_opened

May be used to re-add to processing queue:
on_cancelled_deconstruction
on_cancelled_upgrade
on_player_gun_inventory_changed (when players gun equipment is modified in anyway, signifies they probably need updated ammo - A couple of practical notes. The two inventory-changed events are deliberately bare, which is a known pain point — because they only hand you a player_index, the common pattern is to maintain your own snapshot of the relevant inventory and compare on each fire to figure out the actual delta. Also be aware these can fire multiple times for a single player action, and inventory-changed events fire in the same tick as the change but not necessarily instantly. None of these three support event filters, so your handler runs for every occurrence game-wide)

Might be used to remove from processing queue:
on_equipment_removed
on_marked_for_deconstruction
on_marked_for_upgrade
on_player_deconstructed_area
on_space_platform_mined_entity
on_surface_cleared
on_surface_deleted
script_raised_destroy

Might be used to check if it needs ammo/fuel:
on_entity_damaged (proxy that combat has started)
on_equipment_inserted (gun equipment / jetpack style mods?)
on_object_destroyed (if we get destroyers info and it's a player or entity, we could check it's ammo)
on_player_ammo_inventory_changed
on_player_armor_inventory_changed
on_player_gun_inventory_changed
on_player_placed_equipment
on_segmented_unit_damaged (search nearby and register those turrets for a period of time until they are stable)
on_trigger_fired_artillery
on_worker_robot_expired (search nearby for low ammo units)
script_raised_destroy_segmented_unit (search nearby for low ammo units)
on_train_changed_state

Future edition perhaps:
on_land_mine_armed

TBD:
on_lua_shortcut (when player clicks a button near the shortcut bar), could be used to enable/disable features, recheck entities, etc.
on_mod_item_opened
on_player_changed_force
on_player_repaired_entity
on_pre_build
on_resource_depleted

Others:
Can loop through players/characters and check if in_combat
then flag for filling ammo (or searching nearby for active turrets)


Turrets have an:
alert_when_attacking - if we could intercept that'd be ideal
lua control - in_combat


## Install

Drop the mod folder into your Factorio `mods/` directory:

- macOS: `~/Library/Application Support/factorio/mods/`
- Linux: `~/.factorio/mods/`
- Windows: `%APPDATA%\Factorio\mods\`
