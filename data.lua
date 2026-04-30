local TINT = { r = 1.0, g = 0.85, b = 0.2, a = 1.0 }

local function apply_tint_to_layer(layer)
  if type(layer) ~= "table" then return end
  if layer.draw_as_shadow then return end
  layer.tint = TINT
end

local function apply_tint_to_sprite(sprite)
  if type(sprite) ~= "table" then return end
  if sprite.layers then
    for _, layer in ipairs(sprite.layers) do
      apply_tint_to_layer(layer)
    end
  elseif sprite.sheets then
    for _, sheet in ipairs(sprite.sheets) do
      apply_tint_to_layer(sheet)
    end
  elseif sprite.sheet then
    apply_tint_to_layer(sprite.sheet)
  else
    apply_tint_to_layer(sprite)
  end
end

local cost         = settings.startup["auto-loader-chest-cost"].value
local availability = settings.startup["auto-loader-chest-availability"].value

local INGREDIENTS_BY_COST = {
  cheat     = { { type = "item", name = "iron-plate", amount = 1 } },
  easy      = { { type = "item", name = "iron-plate", amount = 8 } },
  normal    = {
    { type = "item", name = "steel-chest",        amount = 1 },
    { type = "item", name = "electronic-circuit", amount = 3 },
    { type = "item", name = "advanced-circuit",   amount = 1 },
  },
  expensive = {
    { type = "item", name = "steel-chest",        amount = 1 },
    { type = "item", name = "electronic-circuit", amount = 3 },
    { type = "item", name = "advanced-circuit",   amount = 1 },
  },
}

local TECH_BY_AVAILABILITY = {
  easy   = "electronics",
  normal = "construction-robotics",
  hard   = "logistic-robotics",
}

local source = data.raw["container"]["steel-chest"]
if not source then
  error("auto-loader-chest: vanilla steel-chest prototype not found")
end

local function tinted_icons()
  if source.icons then
    local icons = table.deepcopy(source.icons)
    for _, entry in ipairs(icons) do
      entry.tint = TINT
    end
    return icons
  end
  return {
    {
      icon = source.icon,
      icon_size = source.icon_size,
      tint = TINT,
    },
  }
end

local icons = tinted_icons()

local linked_chest = table.deepcopy(source)
linked_chest.type = "linked-container"
linked_chest.name = "auto-loader-chest-linked"
linked_chest.minable = { mining_time = 0.2, result = "auto-loader-chest" }
linked_chest.inventory_size = 100
linked_chest.inventory_type = "with_filters_and_bar"
linked_chest.gui_mode = "none"
linked_chest.localised_name = { "entity-name.auto-loader-chest" }
linked_chest.localised_description = { "entity-description.auto-loader-chest" }
linked_chest.placeable_by = { item = "auto-loader-chest", count = 1 }
linked_chest.icon = nil
linked_chest.icon_size = nil
linked_chest.icons = table.deepcopy(icons)

if linked_chest.picture then
  apply_tint_to_sprite(linked_chest.picture)
end

linked_chest.enable_inventory_bar = nil
linked_chest.scale_info_icons = nil
linked_chest.circuit_wire_max_distance = nil
linked_chest.circuit_connector = nil

local item = {
  type = "item",
  name = "auto-loader-chest",
  icons = table.deepcopy(icons),
  subgroup = "logistic-network",
  order = "a[items]-b[auto-loader-chest]",
  place_result = "auto-loader-chest-linked",
  stack_size = 50,
}

local recipe = {
  type = "recipe",
  name = "auto-loader-chest",
  enabled = (availability == "cheat"),
  energy_required = 0.5,
  ingredients = INGREDIENTS_BY_COST[cost],
  results = {
    { type = "item", name = "auto-loader-chest", amount = 1 },
  },
}

data:extend({ linked_chest, item, recipe })

local tech_name = TECH_BY_AVAILABILITY[availability]
if tech_name then
  local tech = data.raw.technology[tech_name]
  if tech then
    tech.effects = tech.effects or {}
    table.insert(tech.effects, { type = "unlock-recipe", recipe = "auto-loader-chest" })
  end
end
