-- Maintains a live registry of auto-loader chests and compatible consumer
-- entities per surface, then walks the consumer queue every N ticks and
-- pulls items from the surface's chest pool into each consumer.

local batch_size
local tick_interval
local current_nth_tick
local max_fill
local max_insert_overrides = {}
local fill_consumer  -- forward decl: try_register_consumer instant-fills via this

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

local function reset_storage()
  storage.chests_by_surface         = {}
  storage.consumer_queue            = {}
  storage.consumer_queue_size       = {}
  storage.consumer_cursor           = {}
  storage.consumers                 = {}
  storage.consumer_counts           = {}
  storage.destroy_registry          = {}
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
  if not storage.consumer_counts[surface_index] then
    storage.consumer_counts[surface_index] = { ammo = 0, fuel = 0 }
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
  local counts = storage.consumer_counts[surface_index]
  if has_fuel then counts.fuel = counts.fuel + 1 end
  if has_ammo then counts.ammo = counts.ammo + 1 end
  local reg_num = script.register_on_object_destroyed(entity)
  storage.destroy_registry[reg_num] = {
    unit_number   = unit_number,
    kind          = "consumer",
    surface_index = surface_index,
    has_fuel      = has_fuel,
    has_ammo      = has_ammo,
  }

  -- Instant-fill at placement so a freshly-built turret doesn't sit empty
  -- while waiting for the cursor to come around. Uses the same smooth-cap
  -- path as on_step, so under scarcity it only takes a fair share.
  local shared_inv = get_shared_inventory(surface_index)
  if shared_inv and not shared_inv.is_empty() then
    fill_consumer(entity, shared_inv, counts)
  end
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
    local counts = storage.consumer_counts[entry.surface_index]
    if counts then
      if entry.has_fuel then counts.fuel = counts.fuel - 1 end
      if entry.has_ammo then counts.ammo = counts.ammo - 1 end
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
  storage.consumer_counts[surface_index]           = nil
  for reg_num, entry in pairs(storage.destroy_registry) do
    if entry.surface_index == surface_index then
      storage.destroy_registry[reg_num] = nil
    end
  end
end

local function fill_one_inventory(consumer_inv, shared_inv, consumer_count)
  if not consumer_inv or consumer_inv.is_full() then return end

  -- Per-item totals across the whole shared inventory. Fair-share divides
  -- by the surface-wide stock so a single item split across multiple slots
  -- (e.g. for filter pinning) is still treated as one pool for scarcity.
  local totals = {}
  for _, entry in ipairs(shared_inv.get_contents()) do
    totals[entry.name .. "|" .. (entry.quality or "normal")] = entry.count
  end

  -- Slot-order iteration is the priority knob: earlier slots are pulled
  -- first. Players use the chest's filter slots to pin specific ammo or
  -- fuel to the front (e.g. uranium in slot 1, piercing in slot 2) and
  -- this loop honors that order. Pulls drain the slot directly via the
  -- LuaItemStack so we don't accidentally take from a later same-item
  -- slot the player intended as fallback.
  local size = #shared_inv
  for i = 1, size do
    local stack = shared_inv[i]
    if stack.valid_for_read then
      local name = stack.name
      local quality = stack.quality and stack.quality.name or "normal"
      local cap = max_insert_overrides[name] or max_fill
      if cap > 0 then
        -- Smooth fair-share: when this item is scarce relative to the
        -- consumer pool, shrink the per-visit cap so everyone gets a turn
        -- before the first few hoard up to max_fill. Floor of zero is
        -- bumped to 1 so a starving consumer still gets at least one unit
        -- if any stock exists.
        local total = totals[name .. "|" .. quality] or stack.count
        local share = math.floor(total / consumer_count)
        if share < 1 then share = 1 end
        if share < cap then cap = share end
        local current = consumer_inv.get_item_count{ name = name, quality = quality }
        local want = cap - current
        if want > 0 then
          local to_insert = stack.count < want and stack.count or want
          local inserted = consumer_inv.insert{
            name = name, count = to_insert, quality = quality,
          }
          if inserted > 0 then
            stack.count = stack.count - inserted
          end
        end
      end
      if consumer_inv.is_full() then return end
    end
  end
end

fill_consumer = function(entity, shared_inv, counts)
  local fuel_inv = entity.get_fuel_inventory()
  if fuel_inv then fill_one_inventory(fuel_inv, shared_inv, counts.fuel) end

  local idx = AMMO_INVENTORY[entity.type]
  local ammo_inv = idx and entity.get_inventory(idx)
  if ammo_inv then fill_one_inventory(ammo_inv, shared_inv, counts.ammo) end
end

local function on_step()
  for surface_index, queue in pairs(storage.consumer_queue) do
    local shared_inv = get_shared_inventory(surface_index)
    if shared_inv and not shared_inv.is_empty() then
      local n = storage.consumer_queue_size[surface_index] or 0
      if n > 0 then
        local cursor = storage.consumer_cursor[surface_index] or 1
        if cursor > n then cursor = 1 end
        local processed = 0
        local consumers = storage.consumers
        local counts = storage.consumer_counts[surface_index]
        while processed < batch_size and n > 0 do
          if cursor > n then cursor = 1 end
          local unit_number = queue[cursor]
          local entity = unit_number and consumers[unit_number]
          if entity and entity.valid then
            fill_consumer(entity, shared_inv, counts)
            processed = processed + 1
            cursor = cursor + 1
          else
            -- Orphan: swap-pop with the last live entry. Cursor stays
            -- put so the next iteration picks up the entity we just
            -- swapped in. Avoids leaving nil holes that would make
            -- `#queue` return an arbitrary border.
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
