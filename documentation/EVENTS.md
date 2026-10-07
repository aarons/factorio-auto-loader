# Event exploration notes

Candidate signals collected while exploring refill scheduling. These groupings
are possibilities, not a description of the current handlers; those live in
`control.lua`.

## Entity discovery

`on_area_cloned`, `on_built_entity`, `on_entity_cloned`, `on_entity_spawned`,
`on_robot_built_entity`, `on_space_platform_built_entity`, `on_surface_imported`,
`on_train_created`, `script_raised_built`, `script_raised_revive`.

## Player interest and inventory changes

`on_gui_hover`, `on_gui_opened`, `on_player_ammo_inventory_changed`,
`on_player_armor_inventory_changed`, `on_player_gun_inventory_changed`,
`on_player_placed_equipment`, `on_equipment_inserted`, `on_equipment_removed`.

Gun inventory changes could indicate that a character needs different ammo.

## Deconstruction and removal

`on_cancelled_deconstruction`, `on_cancelled_upgrade`,
`on_marked_for_deconstruction`, `on_marked_for_upgrade`,
`on_player_deconstructed_area`, `on_space_platform_mined_entity`,
`on_surface_cleared`, `on_surface_deleted`, `script_raised_destroy`.

## Combat and activity

`on_entity_damaged`, `on_object_destroyed`, `on_segmented_unit_damaged`,
`on_trigger_fired_artillery`, `on_worker_robot_expired`,
`script_raised_destroy_segmented_unit`, `on_train_changed_state`.

Nearby combat or destruction could suggest which consumers need attention.
Other leads include character/turret `in_combat` state and turret
`alert_when_attacking` behavior.

## Other leads

`on_land_mine_armed`, `on_lua_shortcut`, `on_mod_item_opened`,
`on_player_changed_force`, `on_player_repaired_entity`, `on_pre_build`,
`on_resource_depleted`.

A shortcut could offer manual refill checks or an enable/disable control.
