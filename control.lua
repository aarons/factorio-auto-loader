-- Maintains a live registry of auto-loader chests and compatible consumer
-- entities per surface, then walks the consumer queue every N ticks and
-- pulls items from the surface's chest pool into each consumer.

local batch_size
local tick_interval
local current_nth_tick
local max_fill
local refill_trigger
local max_insert_overrides = {}

local AMMO_INVENTORY = {
  ["ammo-turret"]      = defines.inventory.turret_ammo,
  ["car"]              = defines.inventory.car_ammo,
  ["spider-vehicle"]   = defines.inventory.spider_ammo,
  ["artillery-turret"] = defines.inventory.artillery_turret_ammo,
  ["artillery-wagon"]  = defines.inventory.artillery_wagon_ammo,
  ["character"]        = defines.inventory.character_ammo,
}

-- Items whose stack size is 1 (e.g. nuclear fuel, uranium fuel cells) bypass
-- the refill trigger, since "refill when 4 or fewer" doesn't make sense when
-- you can only ever hold one of them per slot.
local stack_size_cache = {}

local function get_stack_size(name)
  local cached = stack_size_cache[name]
  if cached then return cached end
  local proto = prototypes.item[name]
  local size = proto and proto.stack_size or 1
  stack_size_cache[name] = size
  return size
end

-- Coarse pre-filter for find_entities_filtered and the built-event filter.
-- The precise capability test happens inside try_register_consumer.
local CONSUMER_TYPES = {
  "ammo-turret",
  "artillery-turret",
  "artillery-wagon",
  "car",
  "spider-vehicle",
  "character",
  "locomotive",
  "cargo-wagon",
  "mining-drill",
  "furnace",
  "boiler",
  "reactor",
  "inserter",
  "assembling-machine",
  "burner-generator",
}

local CHEST_NAME = "auto-loader-chest"

local built_filter = {}
for _, t in ipairs(CONSUMER_TYPES) do
  built_filter[#built_filter + 1] = { filter = "type", type = t }
end
built_filter[#built_filter + 1] = { filter = "name", name = CHEST_NAME }

local function reset_storage()
  storage.chests_by_surface = {}
  storage.consumer_queue    = {}
  storage.consumer_cursor   = {}
  storage.consumers         = {}
  storage.destroy_registry  = {}
end

local function init_surface(surface_index)
  if not storage.chests_by_surface[surface_index] then
    storage.chests_by_surface[surface_index] = {}
  end
  if not storage.consumer_queue[surface_index] then
    storage.consumer_queue[surface_index] = {}
  end
  if not storage.consumer_cursor[surface_index] then
    storage.consumer_cursor[surface_index] = 1
  end
end

local function register_chest(entity)
  local unit_number = entity.unit_number
  if not unit_number then return end
  local surface_index = entity.surface.index
  init_surface(surface_index)
  local chests = storage.chests_by_surface[surface_index]
  if chests[unit_number] then return end
  chests[unit_number] = entity
  local reg_num = script.register_on_object_destroyed(entity)
  storage.destroy_registry[reg_num] = {
    unit_number   = unit_number,
    kind          = "chest",
    surface_index = surface_index,
  }
end

local function try_register_consumer(entity)
  local unit_number = entity.unit_number
  if not unit_number then return end
  if storage.consumers[unit_number] then return end

  local has_fuel = entity.get_fuel_inventory() ~= nil
  local idx      = AMMO_INVENTORY[entity.type]
  local ammo_inv = idx and entity.get_inventory(idx)
  local has_ammo = ammo_inv ~= nil and #ammo_inv > 0
  if not (has_fuel or has_ammo) then return end

  local surface_index = entity.surface.index
  init_surface(surface_index)
  local queue = storage.consumer_queue[surface_index]
  queue[#queue + 1] = unit_number
  storage.consumers[unit_number] = entity
  local reg_num = script.register_on_object_destroyed(entity)
  storage.destroy_registry[reg_num] = {
    unit_number   = unit_number,
    kind          = "consumer",
    surface_index = surface_index,
  }
end

local function unregister_destroyed(reg_num)
  local entry = storage.destroy_registry[reg_num]
  if not entry then return end
  storage.destroy_registry[reg_num] = nil
  if entry.kind == "chest" then
    local chests = storage.chests_by_surface[entry.surface_index]
    if chests then chests[entry.unit_number] = nil end
  else
    storage.consumers[entry.unit_number] = nil
    -- Queue entry is left orphaned on purpose; chunk C compacts during
    -- the tick loop. Rewriting the array here would be O(n) per removal.
  end
end

local function handle_built_entity(entity)
  if not (entity and entity.valid) then return end
  if entity.name == CHEST_NAME then
    register_chest(entity)
  else
    try_register_consumer(entity)
  end
end

local function on_built(event)
  handle_built_entity(event.entity or event.created_entity)
end

local function on_cloned(event)
  handle_built_entity(event.destination)
end

local function clear_surface(surface_index)
  local queue = storage.consumer_queue[surface_index]
  if queue then
    for _, unit_number in ipairs(queue) do
      if unit_number then
        storage.consumers[unit_number] = nil
      end
    end
  end
  storage.chests_by_surface[surface_index] = nil
  storage.consumer_queue[surface_index]    = nil
  storage.consumer_cursor[surface_index]   = nil
  for reg_num, entry in pairs(storage.destroy_registry) do
    if entry.surface_index == surface_index then
      storage.destroy_registry[reg_num] = nil
    end
  end
end

local function fill_one_inventory(consumer_inv, surface_chests)
  if not consumer_inv or consumer_inv.is_full() then return end
  for _, chest in pairs(surface_chests) do
    if chest.valid then
      local chest_inv = chest.get_inventory(defines.inventory.chest)
      if chest_inv and not chest_inv.is_empty() then
        for _, stack in ipairs(chest_inv.get_contents()) do
          local quality = stack.quality or "normal"
          local cap = max_insert_overrides[stack.name] or max_fill
          if cap > 0 then
            -- Clamp the trigger so it never matches or exceeds the cap; if
            -- they were equal we'd refill on a full inventory and loop.
            local trigger = refill_trigger
            if trigger >= cap then trigger = cap - 1 end
            local current = consumer_inv.get_item_count{ name = stack.name, quality = quality }
            if current <= trigger or get_stack_size(stack.name) == 1 then
              local want = cap - current
              if want > 0 then
                local to_insert = stack.count < want and stack.count or want
                local inserted = consumer_inv.insert{
                  name = stack.name, count = to_insert, quality = quality,
                }
                if inserted > 0 then
                  chest_inv.remove{ name = stack.name, count = inserted, quality = quality }
                end
              end
            end
          end
          if consumer_inv.is_full() then return end
        end
      end
    end
  end
end

local function fill_consumer(entity, surface_chests)
  local fuel_inv = entity.get_fuel_inventory()
  if fuel_inv then fill_one_inventory(fuel_inv, surface_chests) end

  local idx = AMMO_INVENTORY[entity.type]
  local ammo_inv = idx and entity.get_inventory(idx)
  if ammo_inv then fill_one_inventory(ammo_inv, surface_chests) end
end

local function on_step()
  for surface_index, queue in pairs(storage.consumer_queue) do
    local surface_chests = storage.chests_by_surface[surface_index]
    if surface_chests and next(surface_chests) then
      local n = #queue
      if n > 0 then
        local cursor = storage.consumer_cursor[surface_index] or 1
        if cursor > n then cursor = 1 end
        local processed = 0
        local nil_count = 0
        local consumers = storage.consumers
        while processed < batch_size do
          if cursor > n then
            if nil_count * 4 > n then
              local compact = {}
              for i = 1, n do
                if queue[i] then compact[#compact + 1] = queue[i] end
              end
              storage.consumer_queue[surface_index] = compact
              queue = compact
              n = #compact
            end
            if n == 0 then break end
            cursor = 1
            nil_count = 0
          end
          local unit_number = queue[cursor]
          if unit_number then
            local entity = consumers[unit_number]
            if entity and entity.valid then
              fill_consumer(entity, surface_chests)
              processed = processed + 1
            else
              queue[cursor] = nil
              consumers[unit_number] = nil
              nil_count = nil_count + 1
            end
          else
            nil_count = nil_count + 1
          end
          cursor = cursor + 1
        end
        storage.consumer_cursor[surface_index] = cursor
      end
    end
  end
end

local function parse_overrides(s)
  local result = {}
  if not s or s == "" then return result end
  for entry in string.gmatch(s, "[^,]+") do
    local name, count = string.match(entry, "^%s*([%w%-_]+)%s*=%s*(%d+)%s*$")
    if name and count then
      result[name] = tonumber(count)
    end
  end
  return result
end

local function refresh_settings()
  batch_size    = settings.global["auto-loader-chest-batch-size"].value
  tick_interval = settings.global["auto-loader-chest-tick-interval"].value
  max_fill              = settings.global["auto-loader-chest-max-fill"].value
  refill_trigger        = settings.global["auto-loader-chest-refill-trigger"].value
  max_insert_overrides  = parse_overrides(settings.global["auto-loader-chest-insert-overrides"].value)
end

local function reapply_on_nth_tick()
  if current_nth_tick == tick_interval then return end
  if current_nth_tick then script.on_nth_tick(current_nth_tick, nil) end
  script.on_nth_tick(tick_interval, on_step)
  current_nth_tick = tick_interval
end

local function scan_all_surfaces()
  for _, surface in pairs(game.surfaces) do
    init_surface(surface.index)
    for _, entity in pairs(surface.find_entities_filtered{ type = CONSUMER_TYPES }) do
      try_register_consumer(entity)
    end
    for _, entity in pairs(surface.find_entities_filtered{ name = CHEST_NAME }) do
      register_chest(entity)
    end
  end
end

script.on_init(function()
  reset_storage()
  scan_all_surfaces()
  refresh_settings()
  reapply_on_nth_tick()
end)

script.on_configuration_changed(function()
  reset_storage()
  scan_all_surfaces()
  refresh_settings()
  reapply_on_nth_tick()
end)

script.on_load(function()
  refresh_settings()
  reapply_on_nth_tick()
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting_type ~= "runtime-global" then return end
  local name = event.setting
  if name == "auto-loader-chest-batch-size"
     or name == "auto-loader-chest-tick-interval"
     or name == "auto-loader-chest-max-fill"
     or name == "auto-loader-chest-refill-trigger"
     or name == "auto-loader-chest-insert-overrides" then
    refresh_settings()
    reapply_on_nth_tick()
  end
end)

script.on_event(defines.events.on_built_entity,                on_built, built_filter)
script.on_event(defines.events.on_robot_built_entity,          on_built, built_filter)
script.on_event(defines.events.on_space_platform_built_entity, on_built, built_filter)
script.on_event(defines.events.script_raised_built,            on_built)
script.on_event(defines.events.script_raised_revive,           on_built)
script.on_event(defines.events.on_entity_cloned,               on_cloned)

script.on_event(defines.events.on_object_destroyed, function(event)
  unregister_destroyed(event.registration_number)
end)

local function on_player_character_event(event)
  local player = game.get_player(event.player_index)
  if player and player.character then
    handle_built_entity(player.character)
  end
end
script.on_event(defines.events.on_player_created,   on_player_character_event)
script.on_event(defines.events.on_player_respawned, on_player_character_event)

script.on_event(defines.events.on_surface_created, function(event)
  init_surface(event.surface_index)
end)
script.on_event(defines.events.on_surface_deleted, function(event)
  clear_surface(event.surface_index)
end)
script.on_event(defines.events.on_surface_cleared, function(event)
  clear_surface(event.surface_index)
  init_surface(event.surface_index)
end)
