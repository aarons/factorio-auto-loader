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

-- Own sprites (built by graphics/build_art.py), same geometry as the vanilla
-- 1x1 chests. Not borrowed from steel-chest so other mods reskinning it can't
-- break us.
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
      shift = util.by_pixel(-0.25, -0.5), -- keep equal to ENTITY_SHIFT below
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

-- Circuit connector -----------------------------------------------------------
--
-- CONNECTOR_STYLE picks how the chest looks while a circuit wire is attached:
--   "vanilla" - the stock chest connector box at the lower right, as inherited
--               from the linked-chest we copied (2.1's "chest-single").
--   "mouth"   - our own: the front-panel slats part around a bite gap and the
--               wire ends on pins inside it, so the chest is biting the wire.
--               Art comes from graphics/build_art.py (connector_svg).
--
-- Note: LinkedContainerPrototype takes a *single* CircuitConnectorDefinition.
-- Since 2.1 the vanilla containers use circuit_connector_definitions["chest"],
-- which is now a vector (array) form - copying that from steel-chest silently
-- gave us no connector sprites and a wire that snapped to the entity centre.
local CONNECTOR_STYLE = "mouth"

-- The overlay sprites share the entity sprite's 64x80 canvas and shift, so
-- points can be given in sprite pixels and converted here. Keep the pin
-- coordinates in sync with WIRE_PIN_RED / WIRE_PIN_GREEN in build_art.py.
local ENTITY_SHIFT = util.by_pixel(-0.25, -0.5)
local function sprite_pixel(x, y)
  return util.by_pixel((x - 32) / 2 - 0.25, (y - 40) / 2 - 0.5)
end
local WIRE_PIN_RED = { 28, 59 }
local WIRE_PIN_GREEN = { 36, 59 }
local WIRE_SHADOW_OFFSET = { 24, 16 } -- sprite px; where the wire's shadow lands

local function overlay_sprite(file, glow)
  return {
    filename = "__auto-loader-chest__/graphics/entity/" .. file,
    priority = "extra-high",
    width = 64,
    height = 80,
    shift = ENTITY_SHIFT,
    scale = 0.5,
    draw_as_glow = glow or nil,
  }
end

local function mouth_connector()
  return {
    sprites = {
      connector_main = overlay_sprite("auto-loader-chest-connector.png"),
      led_red = overlay_sprite("auto-loader-chest-connector-led-red.png", true),
      led_green = overlay_sprite("auto-loader-chest-connector-led-green.png", true),
      led_blue = util.empty_sprite(), -- blue LED is the logistic-network one
      led_light = { intensity = 0, size = 0.9 },
    },
    points = {
      wire = {
        red = sprite_pixel(WIRE_PIN_RED[1], WIRE_PIN_RED[2]),
        green = sprite_pixel(WIRE_PIN_GREEN[1], WIRE_PIN_GREEN[2]),
      },
      shadow = {
        red = sprite_pixel(WIRE_PIN_RED[1] + WIRE_SHADOW_OFFSET[1], WIRE_PIN_RED[2] + WIRE_SHADOW_OFFSET[2]),
        green = sprite_pixel(WIRE_PIN_GREEN[1] + WIRE_SHADOW_OFFSET[1], WIRE_PIN_GREEN[2] + WIRE_SHADOW_OFFSET[2]),
      },
    },
  }
end

if CONNECTOR_STYLE == "mouth" then
  chest.circuit_connector = mouth_connector()
end
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
