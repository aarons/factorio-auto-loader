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

local chest = table.deepcopy(source)
chest.name = "auto-loader-chest"
chest.minable = { mining_time = 0.2, result = "auto-loader-chest" }

if chest.picture then
  apply_tint_to_sprite(chest.picture)
end

local function tinted_icons()
  if chest.icons then
    local icons = table.deepcopy(chest.icons)
    for _, entry in ipairs(icons) do
      entry.tint = TINT
    end
    return icons
  end
  return {
    {
      icon = chest.icon,
      icon_size = chest.icon_size,
      tint = TINT,
    },
  }
end

local icons = tinted_icons()
chest.icon = nil
chest.icon_size = nil
chest.icons = icons

local item = {
  type = "item",
  name = "auto-loader-chest",
  icons = table.deepcopy(icons),
  subgroup = "logistic-network",
  order = "a[items]-b[auto-loader-chest]",
  place_result = "auto-loader-chest",
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

data:extend({
  chest, item, recipe,
  {
    type = "custom-input",
    name = "al-inspect",
    key_sequence = "CONTROL + 5",
    consuming = "none",
  },
})

local tech_name = TECH_BY_AVAILABILITY[availability]
if tech_name then
  local tech = data.raw.technology[tech_name]
  if tech then
    tech.effects = tech.effects or {}
    table.insert(tech.effects, { type = "unlock-recipe", recipe = "auto-loader-chest" })
  end
end
