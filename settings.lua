-- Tunables for the fill engine.

data:extend({
  {
    -- Round-robin sweep budget: how many registered turrets/burners the engine
    -- checks each tick. Higher = quicker refills, more UPS cost. No restart
    -- required (the sweep reads this live each tick).
    type = "int-setting",
    name = "auto-loader-entities-per-tick",
    setting_type = "runtime-global",
    default_value = 10,
    minimum_value = 1,
    maximum_value = 1000,
    order = "a",
  },
})
