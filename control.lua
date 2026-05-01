local batch_size
local tick_interval
local current_nth_tick
local max_fill
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
  storage.shared_chest              = {}
  storage.consumer_queue            = {}
  storage.consumer_queue_size       = {}
  storage.consumer_cursor           = {}
  storage.consumers                 = {}
  storage.consumer_counts           = {}
  storage.destroy_registry          = {}
  storage.surface_list              = {}
  storage.surface_list_cursor       = 1
end

-- surface_list is the round-robin axis for on_step: each step resumes at
-- surface_list_cursor and processes up to batch_size consumer-fills total
-- across surfaces, advancing the cursor only after a surface's per-surface
-- queue has been fully cycled this step.
local function add_surface_to_list(surface_index)
  local list = storage.surface_list
  for i = 1, #list do
    if list[i] == surface_index then return end
  end
  list[#list + 1] = surface_index
end

local function remove_surface_from_list(surface_index)
  local list = storage.surface_list
  local n = #list
  for i = 1, n do
    if list[i] == surface_index then
      list[i] = list[n]
      list[n] = nil
      if storage.surface_list_cursor > n - 1 then
        storage.surface_list_cursor = 1
      end
      return
    end
  end
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
  add_surface_to_list(surface_index)
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
  if not storage.shared_chest[surface_index] then
    storage.shared_chest[surface_index] = entity
  end
  local reg_num = script.register_on_object_destroyed(entity)
  storage.destroy_registry[reg_num] = {
    unit_number   = unit_number,
    kind          = "chest",
    surface_index = surface_index,
  }
end

-- All chests on a surface share one linked-container inventory, so any valid
-- one will do. We cache a single entity for an O(1) hot path; if it's gone
-- (destroy event missed, mod meddling) we rescan the map and re-cache.
local function get_shared_inventory(surface_index)
  local cached = storage.shared_chest[surface_index]
  if cached and cached.valid then
    return cached.get_inventory(defines.inventory.chest)
  end
  local chests = storage.chests_by_surface[surface_index]
  if not chests then return nil end
  for un, entity in pairs(chests) do
    if entity.valid then
      storage.shared_chest[surface_index] = entity
      return entity.get_inventory(defines.inventory.chest)
    else
      chests[un] = nil
    end
  end
  storage.shared_chest[surface_index] = nil
  return nil
end

-- Build a per-step shared-inventory snapshot once, then reuse it across
-- every consumer on this surface. Without this, fill_one_inventory would
-- re-call get_contents() and re-iterate every shared_inv slot per consumer
-- per inventory — O(consumers * slots) Lua<->C++ boundary crossings every
-- tick. ctx.slots holds each occupied stack with cached name/quality strings
-- and a mutable count we decrement as we insert; ctx.totals is the
-- cross-slot aggregate that drives fair-share. Both stay in sync with the
-- live shared_inv as the step progresses.
local function build_step_context(shared_inv)
  local totals = {}
  local slots = {}
  local n = 0
  local size = #shared_inv
  for i = 1, size do
    local stack = shared_inv[i]
    if stack.valid_for_read then
      local name = stack.name
      local quality = stack.quality and stack.quality.name or "normal"
      local key = name .. "|" .. quality
      local count = stack.count
      n = n + 1
      slots[n] = {
        stack = stack, name = name, quality = quality, key = key, count = count,
      }
      totals[key] = (totals[key] or 0) + count
    end
  end
  return { totals = totals, slots = slots, slot_count = n }
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
    fill_consumer(entity, build_step_context(shared_inv), counts)
  end
end

local function unregister_destroyed(reg_num)
  local entry = storage.destroy_registry[reg_num]
  if not entry then return end
  storage.destroy_registry[reg_num] = nil
  if entry.kind == "chest" then
    local chests = storage.chests_by_surface[entry.surface_index]
    if chests then chests[entry.unit_number] = nil end
    local cached = storage.shared_chest[entry.surface_index]
    if cached and (not cached.valid or cached.unit_number == entry.unit_number) then
      storage.shared_chest[entry.surface_index] = nil
    end
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
  storage.shared_chest[surface_index]              = nil
  storage.consumer_queue[surface_index]            = nil
  storage.consumer_queue_size[surface_index]       = nil
  storage.consumer_cursor[surface_index]           = nil
  storage.consumer_counts[surface_index]           = nil
  remove_surface_from_list(surface_index)
  for reg_num, entry in pairs(storage.destroy_registry) do
    if entry.surface_index == surface_index then
      storage.destroy_registry[reg_num] = nil
    end
  end
end

local function fill_one_inventory(consumer_inv, ctx, consumer_count)
  if not consumer_inv or consumer_inv.is_full() then return end

  -- Aggregate the consumer's current contents in one boundary crossing
  -- instead of a per-slot get_item_count{...} below.
  local current = {}
  for _, entry in ipairs(consumer_inv.get_contents()) do
    current[entry.name .. "|" .. (entry.quality or "normal")] = entry.count
  end

  -- Slot-order iteration is the priority knob: earlier slots are pulled
  -- first. Players use the chest's filter slots to pin specific ammo or
  -- fuel to the front (e.g. uranium in slot 1, piercing in slot 2) and
  -- this loop honors that order.
  local slots = ctx.slots
  local totals = ctx.totals
  for i = 1, ctx.slot_count do
    local slot = slots[i]
    local available = slot.count
    if available > 0 then
      local key = slot.key
      -- Smooth fair-share: when this item is scarce relative to the
      -- consumer pool, shrink the per-visit cap so everyone gets a turn
      -- before the first few hoard up to max_fill. Floor of zero is
      -- bumped to 1 so a starving consumer still gets at least one unit
      -- if any stock exists.
      local total = totals[key]
      local share = math.floor(total / consumer_count)
      if share < 1 then share = 1 end
      local cap = max_fill < share and max_fill or share
      local have = current[key] or 0
      local want = cap - have
      if want > 0 then
        local to_insert = available < want and available or want
        local inserted = consumer_inv.insert{
          name = slot.name, count = to_insert, quality = slot.quality,
        }
        if inserted > 0 then
          slot.stack.count = slot.stack.count - inserted
          slot.count = available - inserted
          totals[key] = total - inserted
          current[key] = have + inserted
        end
      end
      if consumer_inv.is_full() then return end
    end
  end
end

fill_consumer = function(entity, ctx, counts)
  local fuel_inv = entity.get_fuel_inventory()
  if fuel_inv then fill_one_inventory(fuel_inv, ctx, counts.fuel) end

  local idx = AMMO_INVENTORY[entity.type]
  local ammo_inv = idx and entity.get_inventory(idx)
  if ammo_inv then fill_one_inventory(ammo_inv, ctx, counts.ammo) end
end

local function on_step()
  local surface_list = storage.surface_list
  local n_surfaces = #surface_list
  if n_surfaces == 0 then return end

  local sc = storage.surface_list_cursor
  if sc < 1 or sc > n_surfaces then sc = 1 end

  local consumers = storage.consumers
  local processed = 0
  local surfaces_visited = 0

  -- Global round-robin: each step processes up to batch_size consumer-fills
  -- in total, advancing through surface_list. We finish a surface's queue
  -- cycle (or run out of budget) before advancing surface_list_cursor, so a
  -- surface's per-surface cursor is preserved across steps. The
  -- surfaces_visited cap stops us looping forever if every surface is empty
  -- or has nothing to give.
  while processed < batch_size and surfaces_visited < n_surfaces do
    local surface_index = surface_list[sc]
    local n = storage.consumer_queue_size[surface_index] or 0
    local advance_surface = true

    if n > 0 then
      local shared_inv = get_shared_inventory(surface_index)
      if shared_inv and not shared_inv.is_empty() then
        local queue = storage.consumer_queue[surface_index]
        local ctx = build_step_context(shared_inv)
        local cursor = storage.consumer_cursor[surface_index] or 1
        if cursor > n then cursor = 1 end
        local counts = storage.consumer_counts[surface_index]
        local cycle_complete = false

        while processed < batch_size and n > 0 do
          local unit_number = queue[cursor]
          local entity = unit_number and consumers[unit_number]
          if entity and entity.valid then
            fill_consumer(entity, ctx, counts)
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

          if cursor > n then
            cursor = 1
            cycle_complete = true
            break
          end
        end

        storage.consumer_queue_size[surface_index] = n
        storage.consumer_cursor[surface_index] = cursor
        advance_surface = cycle_complete or n == 0
      end
    end

    if advance_surface then
      sc = sc + 1
      if sc > n_surfaces then sc = 1 end
      surfaces_visited = surfaces_visited + 1
    else
      break
    end
  end

  storage.surface_list_cursor = sc
end

local function refresh_settings()
  batch_size    = settings.global["auto-loader-chest-batch-size"].value
  tick_interval = settings.global["auto-loader-chest-tick-interval"].value
  max_fill      = settings.global["auto-loader-chest-max-fill"].value
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
     or name == "auto-loader-chest-max-fill" then
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
