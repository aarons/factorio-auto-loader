-- Auto-Loader: the supply chest.
--
-- A per-surface linked-container. Every Auto-Loader chest on a given surface
-- shares one inventory (linked at runtime in control.lua by setting link_id to
-- the surface index), giving players a single pooled supply of fuel and ammo
-- per surface. This is the supply half of the auto-fill chest: the strategy
-- that distributes this supply into turrets and burners is not built yet.

local util = require("util")

local CHEST = "auto-loader-chest"

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

-- Graphics + icon. The mod ships its own original sprites (generated from an
-- SVG design by graphics/build_art.py) rather than reading the steel-chest
-- prototype's `icon`/`picture`: mods that reskin the vanilla chests (e.g. AAI
-- Containers & Warehouses) rewrite those fields into shapes we cannot assume,
-- and shipping our own art keeps startup independent of them. The sprite
-- geometry (64x80 at scale 0.5, 110x46 shadow) matches the vanilla 1x1 chests.
chest.icon = "__auto-loader-chest__/graphics/icons/auto-loader-chest.png"
chest.icon_size = 64
chest.icons = nil
chest.picture = {
  layers = {
    {
      filename = "__auto-loader-chest__/graphics/entity/auto-loader-chest.png",
      priority = "extra-high",
      width = 64,
      height = 80,
      shift = util.by_pixel(-0.25, -0.5),
      scale = 0.5,
    },
    {
      filename = "__auto-loader-chest__/graphics/entity/auto-loader-chest-shadow.png",
      priority = "extra-high",
      width = 110,
      height = 46,
      shift = util.by_pixel(12.25, 8),
      draw_as_shadow = true,
      scale = 0.5,
    },
  },
}

-- Slot count and stack compression are player-configurable (startup settings);
-- multiplied stacks give a compact pooled supply.
chest.inventory_size = settings.startup["auto-loader-chest-slots"].value
chest.inventory_type = "with_custom_stack_size"
chest.inventory_properties = {
  stack_size_multiplier = settings.startup["auto-loader-chest-stack-multiplier"].value,
  with_bar = true,
}

-- Players stock the chest, but the per-surface link is managed at runtime and
-- is not be editable through the GUI.
chest.gui_mode = "none"

-- Placeable anywhere, including space platforms.
chest.surface_conditions = nil

-- Circuit readout of contents (not sure it's required, holdover from older version)
chest.circuit_connector = table.deepcopy(steel_chest.circuit_connector)
chest.circuit_wire_max_distance = steel_chest.circuit_wire_max_distance

local item = {
  type = "item",
  name = CHEST,
  icon = chest.icon,
  icon_size = chest.icon_size,
  subgroup = "storage",
  order = "b[storage]-z[auto-loader-chest]",
  place_result = CHEST,
  stack_size = 50,
}

-- Recipe cost tiers, selected by startup setting. Each tier past "default"
-- adds the next circuit up the chain.
local COST_INGREDIENTS = {
  ["easy"] = {
    { type = "item", name = "iron-plate", amount = 1 },
  },
  ["medium"] = {
    { type = "item", name = "steel-chest",        amount = 1 },
    { type = "item", name = "electronic-circuit", amount = 3 },
  },
  ["hard"] = {
    { type = "item", name = "steel-chest",        amount = 1 },
    { type = "item", name = "electronic-circuit", amount = 3 },
    { type = "item", name = "advanced-circuit",   amount = 3 },
  },
  ["extra-hard"] = {
    { type = "item", name = "steel-chest",        amount = 1 },
    { type = "item", name = "electronic-circuit", amount = 3 },
    { type = "item", name = "advanced-circuit",   amount = 3 },
    { type = "item", name = "processing-unit",    amount = 3 },
  },
}

local cost = settings.startup["auto-loader-chest-cost"].value
local ingredients = COST_INGREDIENTS[cost] or COST_INGREDIENTS["medium"]

local recipe = {
  type = "recipe",
  name = CHEST,
  enabled = true,
  energy_required = 0.5,
  ingredients = table.deepcopy(ingredients),
  results = { { type = "item", name = CHEST, amount = 1 } },
}

data:extend({ chest, item, recipe })
