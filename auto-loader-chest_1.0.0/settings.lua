-- Tunables for the fill engine.

data:extend({
  {
    -- Recipe cost tier for the Auto-Loader chest.
    type = "string-setting",
    name = "auto-loader-chest-cost",
    setting_type = "startup",
    default_value = "medium",
    allowed_values = { "easy", "medium", "hard", "extra-hard" },
    order = "a",
  },
  {
    -- Number of inventory slots on each Auto-Loader chest.
    type = "int-setting",
    name = "auto-loader-chest-slots",
    setting_type = "startup",
    default_value = 48,
    minimum_value = 1,
    maximum_value = 1000,
    order = "b",
  },
  {
    -- Inventory compression: stack size multiplier for chest inventory slots.
    type = "int-setting",
    name = "auto-loader-chest-stack-multiplier",
    setting_type = "startup",
    default_value = 10,
    minimum_value = 1,
    maximum_value = 100000,
    order = "c",
  },
  {
    -- Round-robin budget: how many entities the engine checks each tick.
    type = "int-setting",
    name = "auto-loader-entities-per-tick",
    setting_type = "runtime-global",
    default_value = 10,
    minimum_value = 1,
    maximum_value = 10000,
    order = "a",
  },
})
