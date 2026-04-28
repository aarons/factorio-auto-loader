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

local source = data.raw["logistic-container"]["active-provider-chest"]
if not source then
  error("auto-loader-chest: vanilla active-provider-chest prototype not found")
end

local chest = table.deepcopy(source)
chest.type = "container"
chest.name = "auto-loader-chest"
chest.minable = { mining_time = 0.2, result = "auto-loader-chest" }

chest.logistic_mode = nil
chest.max_logistic_slots = nil
chest.render_not_in_network_icon = nil
chest.opened_duration = nil
chest.trash_inventory_size = nil
chest.animation = nil
chest.animation_sound = nil
chest.landing_location_offset = nil
chest.use_exact_mode = nil

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
  enabled = true,
  energy_required = 0.5,
  ingredients = {
    { type = "item", name = "iron-chest", amount = 1 },
    { type = "item", name = "electronic-circuit", amount = 2 },
  },
  results = {
    { type = "item", name = "auto-loader-chest", amount = 1 },
  },
}

data:extend({ chest, item, recipe })
