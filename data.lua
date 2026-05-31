-- Auto-Loader: the supply chest.
--
-- A per-surface linked-container. Every Auto-Loader chest on a given surface
-- shares one inventory (linked at runtime in control.lua by setting link_id to
-- the surface index), giving players a single pooled supply of fuel and ammo
-- per surface. This is the supply half of the auto-fill chest: the strategy
-- that distributes this supply into turrets and burners is not built yet.

local CHEST = "auto-loader-chest"

-- A subtle tint so the chest reads as distinct from a plain steel chest.
local CHEST_TINT = { r = 0.45, g = 0.75, b = 1.0, a = 1.0 }

local function tint_sprite_layer(layer, tint)
  if type(layer) ~= "table" then return end
  if layer.draw_as_shadow then return end
  layer.tint = tint
end

local function tint_sprite(sprite, tint)
  if type(sprite) ~= "table" then return end
  if sprite.layers then
    for _, layer in ipairs(sprite.layers) do tint_sprite_layer(layer, tint) end
  elseif sprite.sheets then
    for _, sheet in ipairs(sprite.sheets) do tint_sprite_layer(sheet, tint) end
  elseif sprite.sheet then
    tint_sprite_layer(sprite.sheet, tint)
  else
    tint_sprite_layer(sprite, tint)
  end
end

local linked_chest = data.raw["linked-container"]["linked-chest"]
assert(linked_chest, "auto-loader: vanilla linked-chest not found")
local steel_chest = data.raw["container"]["steel-chest"]
assert(steel_chest, "auto-loader: steel-chest not found")

-- Base the entity on the vanilla linked-chest: it is already a linked-container
-- with a working chest circuit connector. Override the bits we care about.
local chest = table.deepcopy(linked_chest)
chest.name = CHEST
chest.flags = table.deepcopy(steel_chest.flags) -- normal, blueprintable chest
chest.minable = { mining_time = 0.2, result = CHEST }
chest.max_health = steel_chest.max_health
chest.resistances = table.deepcopy(steel_chest.resistances)
chest.next_upgrade = nil

-- Graphics + icon, tinted for distinction.
chest.icons = { { icon = steel_chest.icon, icon_size = steel_chest.icon_size, tint = CHEST_TINT } }
chest.icon = nil
chest.icon_size = nil
chest.picture = table.deepcopy(steel_chest.picture)
tint_sprite(chest.picture, CHEST_TINT)

-- 20 slots, fuel/ammo stacks hold 10x for a compact pooled supply.
chest.inventory_size = 20
chest.inventory_type = "with_custom_stack_size"
chest.inventory_properties = {
  stack_size_multiplier = 10,
  with_bar = true,
}

-- Players stock the chest, but the per-surface link is managed at runtime and
-- must not be editable through the GUI.
chest.gui_mode = "none"

-- Placeable anywhere, including space platforms: no gravity/surface gate.
chest.surface_conditions = nil

-- Circuit readout of contents (inherited from linked-chest; set explicitly).
chest.circuit_connector = table.deepcopy(steel_chest.circuit_connector)
chest.circuit_wire_max_distance = steel_chest.circuit_wire_max_distance

local item = {
  type = "item",
  name = CHEST,
  icons = table.deepcopy(chest.icons),
  subgroup = "storage",
  order = "b[storage]-z[auto-loader-chest]",
  place_result = CHEST,
  stack_size = 50,
}

local recipe = {
  type = "recipe",
  name = CHEST,
  enabled = true,
  energy_required = 0.5,
  ingredients = {
    { type = "item", name = "steel-chest",        amount = 1 },
    { type = "item", name = "electronic-circuit", amount = 3 },
  },
  results = { { type = "item", name = CHEST, amount = 1 } },
}

data:extend({ chest, item, recipe })
