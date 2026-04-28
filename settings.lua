data:extend({
  {
    type = "int-setting",
    name = "auto-loader-chest-batch-size",
    setting_type = "runtime-global",
    default_value = 10,
    minimum_value = 1,
    maximum_value = 1000,
    order = "a",
  },
  {
    type = "int-setting",
    name = "auto-loader-chest-tick-interval",
    setting_type = "runtime-global",
    default_value = 15,
    minimum_value = 1,
    maximum_value = 600,
    order = "b",
  },
})
