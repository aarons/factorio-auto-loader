-- Auto-Loader: per-surface supply linking.
--
-- Every Auto-Loader chest pools into one inventory per surface. On build we set
-- the entity's link_id to its surface index, so all chests on a surface share a
-- single linked-container inventory. Linked inventories are keyed by (prototype
-- name, force, link_id), so surface.index never collides with other mods.
--
-- This is the supply half of the auto-fill chest: players stock fuel and ammo
-- here. Distributing that supply into turrets and burners is not built yet, so
-- there is no fill loop or persistent storage to maintain.

local CHEST = "auto-loader-chest"

local BUILD_EVENTS = {
  defines.events.on_built_entity,
  defines.events.on_robot_built_entity,
  defines.events.on_space_platform_built_entity,
  defines.events.script_raised_built,
  defines.events.script_raised_revive,
}

local function link_chest(entity)
  if not (entity and entity.valid and entity.name == CHEST) then return end
  entity.link_id = entity.surface.index
end

local function on_built(event)
  link_chest(event.entity or event.destination)
end

-- (Re)link any chests already present — mod added to a running save, or chests
-- carried to a new surface by cloning.
local function scan_all_surfaces()
  for _, surface in pairs(game.surfaces) do
    for _, chest in ipairs(surface.find_entities_filtered{ name = CHEST }) do
      link_chest(chest)
    end
  end
end

script.on_init(scan_all_surfaces)
script.on_configuration_changed(scan_all_surfaces)

local build_filter = { { filter = "name", name = CHEST } }
for _, event in ipairs(BUILD_EVENTS) do
  script.on_event(event, on_built, build_filter)
end
script.on_event(defines.events.on_entity_cloned, on_built)

-- Rescan a region (or a whole surface, area = nil) and relink any chests found.
-- link_chest is idempotent, so re-linking already-correct chests is harmless.
local function relink_area(surface, area)
  for _, chest in ipairs(surface.find_entities_filtered{ area = area, name = CHEST }) do
    link_chest(chest)
  end
end

-- Not sure if area/brush clones raise an on_entity_cloned for
-- entities inside a clone_area, so this may not be needed:
script.on_event(defines.events.on_area_cloned, function(event)
  if event.clone_entities then
    relink_area(event.destination_surface, event.destination_area)
  end
end)

-- similar for imported surfaces, I'm not sure if they can have entities/chests
-- predefined, and if they will get build events or just the surface event:
script.on_event(defines.events.on_surface_imported, function(event)
  relink_area(event.surface, nil)
end)
