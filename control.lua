-- Maintains a live registry of auto-loader chests and compatible consumer
-- entities per surface, then walks the consumer queue every N ticks and
-- pulls items from the surface's chest pool into each consumer.

local batch_size
local tick_interval
local current_nth_tick
local max_fill
local max_insert_overrides = {}

local AMMO_INVENTORY = {
  ["ammo-turret"]      = defines.inventory.turret_ammo,
  ["car"]              = defines.inventory.car_ammo,
  ["spider-vehicle"]   = defines.inventory.spider_ammo,
  ["artillery-turret"] = defines.inventory.artillery_turret_ammo,
  ["artillery-wagon"]  = defines.inventory.artillery_wagon_ammo,
  ["character"]        = defines.inventory.character_ammo,
}

local CHEST_NAME = "auto-loader-chest-linked"

-- All chests on the same surface share one logical inventory via
-- LuaEntity.link_id. We hash a per-surface id off the surface NAME (stable
-- across save/load — surface indices aren't) so reloads don't relink chests
-- into a different pool. Prefix is mod-scoped so we don't collide with any
-- other linked-container the player may have placed.
local function link_id_for_surface(surface)
  local s = "raleys-ammo-loader-" .. surface.name
  local hash = 0x811c9dc5
  for i = 1, #s do
    hash = bit32.bxor(hash, string.byte(s, i))
    hash = bit32.band(hash * 0x01000193, 0xffffffff)
  end
  return hash
end

-- Fraction of the per-step batch budget reserved for the rescan true-up.
-- The fill loop gets the remainder. With batch_size=10 → 7 fills per surface
-- + 3 rescan actions per step.
local RESCAN_BUDGET_RATIO = 0.3

local function reset_storage()
  storage.chests_by_surface         = {}
  storage.consumer_queue            = {}
  storage.consumer_queue_size       = {}
  storage.consumer_cursor           = {}
  storage.consumers                 = {}
  storage.destroy_registry          = {}
  storage.known_consumer_names      = {}
  storage.consumer_count_by_surface = {}
  storage.rescan = {
    surface_indices  = nil,
    next_surface_pos = 1,
    current_surface  = nil,
    entities         = nil,
    cursor           = 1,
  }
end

local function init_surface(surface_index)
  if not storage.chests_by_surface[surface_index] then
    storage.chests_by_surface[surface_index] = {}
  end
  if not storage.consumer_queue[surface_index] then
    storage.consumer_queue[surface_index] = {}
  end
  if not storage.consumer_queue_size[surface_index] then
    storage.consumer_queue_size[surface_index] = 0
  end
  if not storage.consumer_cursor[surface_index] then
    storage.consumer_cursor[surface_index] = 1
  end
  if not storage.consumer_count_by_surface[surface_index] then
    storage.consumer_count_by_surface[surface_index] = 0
  end
end

local function register_chest(entity)
  local unit_number = entity.unit_number
  if not unit_number then return end
  -- Set link_id every time so a chest that arrives with a stale or default
  -- (0) value — clone, blueprint paste, third-party script — gets joined to
  -- the surface's pool before any inserter can touch it.
  entity.link_id = link_id_for_surface(entity.surface)
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

-- Any registered chest on the surface can hand back the shared inventory —
-- they're all linked. Sweep dead unit_numbers we encounter along the way.
local function get_shared_inventory(surface_index)
  local chests = storage.chests_by_surface[surface_index]
  if not chests then return nil end
  for un, entity in pairs(chests) do
    if entity.valid then
      return entity.get_inventory(defines.inventory.chest)
    else
      chests[un] = nil
    end
  end
  return nil
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
  local size  = storage.consumer_queue_size[surface_index] + 1
  queue[size] = unit_number
  storage.consumer_queue_size[surface_index] = size
  storage.consumers[unit_number] = entity
  storage.known_consumer_names[entity.name] = true
  storage.consumer_count_by_surface[surface_index] =
    storage.consumer_count_by_surface[surface_index] + 1
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
    local count_map = storage.consumer_count_by_surface
    if count_map[entry.surface_index] then
      count_map[entry.surface_index] = count_map[entry.surface_index] - 1
    end
    -- Queue slot is left orphaned on purpose; the fill loop swap-pops
    -- it on next visit. Rewriting the array here would be O(n) per
    -- removal.
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
  local size  = storage.consumer_queue_size[surface_index] or 0
  if queue then
    for i = 1, size do
      local unit_number = queue[i]
      if unit_number then
        storage.consumers[unit_number] = nil
      end
    end
  end
  storage.chests_by_surface[surface_index]         = nil
  storage.consumer_queue[surface_index]            = nil
  storage.consumer_queue_size[surface_index]       = nil
  storage.consumer_cursor[surface_index]           = nil
  storage.consumer_count_by_surface[surface_index] = nil
  for reg_num, entry in pairs(storage.destroy_registry) do
    if entry.surface_index == surface_index then
      storage.destroy_registry[reg_num] = nil
    end
  end
  local rescan = storage.rescan
  if rescan and rescan.current_surface == surface_index then
    rescan.current_surface = nil
    rescan.entities        = nil
    rescan.cursor          = 1
  end
end

local function fill_one_inventory(consumer_inv, shared_inv)
  if not consumer_inv or consumer_inv.is_full() then return end
  for _, stack in ipairs(shared_inv.get_contents()) do
    local quality = stack.quality or "normal"
    local cap = max_insert_overrides[stack.name] or max_fill
    if cap > 0 then
      local current = consumer_inv.get_item_count{ name = stack.name, quality = quality }
      local want = cap - current
      if want > 0 then
        local to_insert = stack.count < want and stack.count or want
        local inserted = consumer_inv.insert{
          name = stack.name, count = to_insert, quality = quality,
        }
        if inserted > 0 then
          shared_inv.remove{ name = stack.name, count = inserted, quality = quality }
        end
      end
    end
    if consumer_inv.is_full() then return end
  end
end

local function fill_consumer(entity, shared_inv)
  local fuel_inv = entity.get_fuel_inventory()
  if fuel_inv then fill_one_inventory(fuel_inv, shared_inv) end

  local idx = AMMO_INVENTORY[entity.type]
  local ammo_inv = idx and entity.get_inventory(idx)
  if ammo_inv then fill_one_inventory(ammo_inv, shared_inv) end
end

local function get_known_names_array()
  local arr = {}
  for name in pairs(storage.known_consumer_names) do
    arr[#arr + 1] = name
  end
  return arr
end

-- Round-robin: advance to the next surface in the cached order, rebuilding
-- the order list when we've cycled through it.
local function pick_next_surface(rescan)
  if not rescan.surface_indices or rescan.next_surface_pos > #rescan.surface_indices then
    rescan.surface_indices = {}
    for _, surface in pairs(game.surfaces) do
      rescan.surface_indices[#rescan.surface_indices + 1] = surface.index
    end
    rescan.next_surface_pos = 1
  end
  if #rescan.surface_indices == 0 then return nil end
  local idx = rescan.surface_indices[rescan.next_surface_pos]
  rescan.next_surface_pos = rescan.next_surface_pos + 1
  return idx
end

-- Slow true-up: walk a name-filtered snapshot per surface, registering any
-- consumer the event handlers missed.
local function run_rescan(budget)
  if budget <= 0 then return end
  if not next(storage.known_consumer_names) then return end

  local rescan = storage.rescan
  local empty_surfaces = 0

  while budget > 0 do
    if not rescan.entities or rescan.cursor > #rescan.entities then
      local si = pick_next_surface(rescan)
      if not si then return end
      -- Cap empty-surface walks at one full pass so we don't loop forever
      -- when every surface has zero matching entities.
      if empty_surfaces >= #rescan.surface_indices then return end

      local surface = game.get_surface(si)
      local entities
      if surface and surface.valid then
        local names = get_known_names_array()
        entities = surface.find_entities_filtered{ name = names, force = "player" }
      end

      budget = budget - 1
      if entities and #entities > 0 then
        rescan.entities        = entities
        rescan.cursor          = 1
        rescan.current_surface = si
      else
        rescan.entities        = nil
        rescan.current_surface = nil
        empty_surfaces         = empty_surfaces + 1
      end
    else
      local entity = rescan.entities[rescan.cursor]
      rescan.cursor = rescan.cursor + 1
      if entity and entity.valid then
        handle_built_entity(entity)
      end
      budget = budget - 1
    end
  end
end

local function on_step()
  local rescan_budget = math.max(math.floor(batch_size * RESCAN_BUDGET_RATIO), 1)
  local fill_budget   = math.max(batch_size - rescan_budget, 1)

  for surface_index, queue in pairs(storage.consumer_queue) do
    local shared_inv = get_shared_inventory(surface_index)
    if shared_inv and not shared_inv.is_empty() then
      local n = storage.consumer_queue_size[surface_index] or 0
      if n > 0 then
        local cursor = storage.consumer_cursor[surface_index] or 1
        if cursor > n then cursor = 1 end
        local processed = 0
        local consumers = storage.consumers
        while processed < fill_budget and n > 0 do
          if cursor > n then cursor = 1 end
          local unit_number = queue[cursor]
          local entity = unit_number and consumers[unit_number]
          if entity and entity.valid then
            fill_consumer(entity, shared_inv)
            processed = processed + 1
            cursor = cursor + 1
          else
            -- Orphan: swap with the last live entry and shrink. Cursor
            -- stays put — the slot now holds a different entity that we
            -- haven't visited this cycle. Avoids leaving nil holes that
            -- would make `#queue` return an arbitrary border.
            if unit_number then
              consumers[unit_number] = nil
            end
            queue[cursor] = queue[n]
            queue[n] = nil
            n = n - 1
          end
        end
        storage.consumer_queue_size[surface_index] = n
        storage.consumer_cursor[surface_index] = cursor
      end
    end
  end

  run_rescan(rescan_budget)
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
    for _, entity in pairs(surface.find_entities()) do
      handle_built_entity(entity)
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
     or name == "auto-loader-chest-insert-overrides" then
    refresh_settings()
    reapply_on_nth_tick()
  end
end)

script.on_event(defines.events.on_built_entity,                on_built)
script.on_event(defines.events.on_robot_built_entity,          on_built)
script.on_event(defines.events.on_space_platform_built_entity, on_built)
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
