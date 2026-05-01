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
  storage.chest_surface             = {}
  storage.consumer_queue            = {}
  storage.consumer_cursor           = {}
  storage.consumers                 = {}
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
  if not storage.consumer_cursor[surface_index] then
    storage.consumer_cursor[surface_index] = 1
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
  storage.chest_surface[unit_number] = surface_index
  if not storage.shared_chest[surface_index] then
    storage.shared_chest[surface_index] = entity
  end
  script.register_on_object_destroyed(entity)
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
  for unit_number, entity in pairs(chests) do
    if entity.valid then
      storage.shared_chest[surface_index] = entity
      return entity.get_inventory(defines.inventory.chest)
    else
      chests[unit_number] = nil
    end
  end
  storage.shared_chest[surface_index] = nil
  return nil
end

-- Item-kind classification cache: name -> "fuel" | "ammo" | false. Derived
-- from prototypes.item[name] (immutable for the session). An item is fuel
-- XOR ammo — Factorio doesn't ship items that are both, so we don't pay
-- complexity for the mythical case. Module-local so on_configuration_changed
-- naturally invalidates it via reload; never persist in storage.
local kind_cache = {}

local function classify_item(name)
  local cached = kind_cache[name]
  if cached ~= nil then return cached end
  local proto = prototypes.item[name]
  local kind = false
  if proto then
    if proto.type == "ammo" then
      kind = "ammo"
    elseif proto.fuel_category then
      kind = "fuel"
    end
  end
  kind_cache[name] = kind
  return kind
end

-- Per-step plan for one surface. Walks shared_inv once, partitions occupied
-- slots into fuel_slots / ammo_slots in chest-slot order (filter slot 1
-- first → priority pull) and records the original total per item.
--
-- During fill: consumers don't mutate slot state; they just bump
-- ctx.taken[key]. ctx.totals[key] - ctx.taken[key] tells us when an item
-- runs out so we don't over-insert.
--
-- At commit: drain slots in slot order, applying ctx.taken[key] to slot 0
-- of that key first, overflowing into later slots — matches Factorio's
-- usual slot-0-first drain. One boundary crossing per slot actually
-- drained, regardless of how many consumers pulled the same item.
local function build_step_context(shared_inv)
  local fuel_slots, ammo_slots = {}, {}
  local fuel_n, ammo_n = 0, 0
  local totals = {}

  local size = #shared_inv
  for i = 1, size do
    local stack = shared_inv[i]
    if stack.valid_for_read then
      local kind = classify_item(stack.name)
      if kind then
        local name = stack.name
        local quality = stack.quality and stack.quality.name or "normal"
        local key = name .. "|" .. quality
        local count = stack.count
        local slot = {
          stack = stack, name = name, quality = quality, key = key, count = count,
        }
        if kind == "ammo" then
          ammo_n = ammo_n + 1
          ammo_slots[ammo_n] = slot
        else
          fuel_n = fuel_n + 1
          fuel_slots[fuel_n] = slot
        end
        totals[key] = (totals[key] or 0) + count
      end
    end
  end

  return {
    fuel_slots = fuel_slots, fuel_slot_count = fuel_n,
    ammo_slots = ammo_slots, ammo_slot_count = ammo_n,
    totals = totals, taken = {},
  }
end

-- Drain one side's slots in slot order, applying taken[key] to each slot
-- starting from the front. A slot's contribution is min(slot.count,
-- taken[key] still owed); zero-owed slots are skipped without writing.
local function commit_slots(slots, slot_count, taken)
  for i = 1, slot_count do
    local slot = slots[i]
    local key = slot.key
    local t = taken[key]
    if t and t > 0 then
      local original = slot.count
      if t >= original then
        slot.stack.count = 0
        taken[key] = t - original
      else
        slot.stack.count = original - t
        taken[key] = 0
      end
    end
  end
end

local function commit_step(ctx)
  local taken = ctx.taken
  commit_slots(ctx.fuel_slots, ctx.fuel_slot_count, taken)
  commit_slots(ctx.ammo_slots, ctx.ammo_slot_count, taken)
end

local function try_register_consumer(entity)
  local unit_number = entity.unit_number
  if not unit_number then return end
  if storage.consumers[unit_number] then return end

  local has_fuel = entity.get_fuel_inventory() ~= nil
  local ammo_idx = AMMO_INVENTORY[entity.type]
  if ammo_idx then
    local ammo_inv = entity.get_inventory(ammo_idx)
    if not (ammo_inv and #ammo_inv > 0) then ammo_idx = nil end
  end
  if not (has_fuel or ammo_idx) then return end

  local surface_index = entity.surface.index
  init_surface(surface_index)

  -- Same consumer record is shared between the queue (round-robin
  -- iteration) and storage.consumers[unit_number] (O(1) dedup at
  -- registration plus lookup in the destroy handler). Caching ammo_idx
  -- and has_fuel here keeps the fill path off the
  -- AMMO_INVENTORY[entity.type] / get_fuel_inventory() boundary calls.
  local consumer = {
    entity        = entity,
    unit_number   = unit_number,
    surface_index = surface_index,
    has_fuel      = has_fuel,
    ammo_idx      = ammo_idx,
  }

  local queue = storage.consumer_queue[surface_index]
  queue[#queue + 1] = consumer
  storage.consumers[unit_number] = consumer
  script.register_on_object_destroyed(entity)

  -- Instant-fill at placement so a freshly-built turret doesn't sit empty
  -- while waiting for the cursor to come around.
  local shared_inv = get_shared_inventory(surface_index)
  if shared_inv and not shared_inv.is_empty() then
    local ctx = build_step_context(shared_inv)
    fill_consumer(consumer, ctx)
    commit_step(ctx)
  end
end

local function on_object_destroyed(event)
  -- We only ever register entities, so useful_id is the unit_number. The
  -- queue slot for a destroyed consumer is left for the fill loop to
  -- swap-pop on next visit; rewriting the array here would be O(n).
  local unit_number = event.useful_id
  local consumer = storage.consumers[unit_number]
  if consumer then
    storage.consumers[unit_number] = nil
    return
  end

  local surface_index = storage.chest_surface[unit_number]
  if surface_index then
    storage.chest_surface[unit_number] = nil
    local chests = storage.chests_by_surface[surface_index]
    if chests then chests[unit_number] = nil end
    local cached = storage.shared_chest[surface_index]
    if cached and (not cached.valid or cached.unit_number == unit_number) then
      storage.shared_chest[surface_index] = nil
    end
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
    for i = 1, #queue do
      local consumer = queue[i]
      if consumer then storage.consumers[consumer.unit_number] = nil end
    end
  end
  local chests = storage.chests_by_surface[surface_index]
  if chests then
    for unit_number in pairs(chests) do storage.chest_surface[unit_number] = nil end
  end
  storage.chests_by_surface[surface_index]         = nil
  storage.shared_chest[surface_index]              = nil
  storage.consumer_queue[surface_index]            = nil
  storage.consumer_cursor[surface_index]           = nil
  remove_surface_from_list(surface_index)
end

local function fill_one_inventory(consumer_inv, slots, slot_count, totals, taken)
  if consumer_inv.is_full() then return end

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
  for i = 1, slot_count do
    local slot = slots[i]
    local key = slot.key
    local already_taken = taken[key] or 0
    local available = totals[key] - already_taken
    if available > 0 then
      local have = current[key] or 0
      local want = max_fill - have
      if want > 0 then
        local to_insert = available < want and available or want
        local inserted = consumer_inv.insert{
          name = slot.name, count = to_insert, quality = slot.quality,
        }
        if inserted > 0 then
          taken[key] = already_taken + inserted
          current[key] = have + inserted
          if consumer_inv.is_full() then return end
        end
      end
    end
  end
end

fill_consumer = function(consumer, ctx)
  local entity = consumer.entity
  if consumer.has_fuel and ctx.fuel_slot_count > 0 then
    local fuel_inv = entity.get_fuel_inventory()
    if fuel_inv then
      fill_one_inventory(fuel_inv, ctx.fuel_slots, ctx.fuel_slot_count, ctx.totals, ctx.taken)
    end
  end
  if consumer.ammo_idx and ctx.ammo_slot_count > 0 then
    local ammo_inv = entity.get_inventory(consumer.ammo_idx)
    if ammo_inv then
      fill_one_inventory(ammo_inv, ctx.ammo_slots, ctx.ammo_slot_count, ctx.totals, ctx.taken)
    end
  end
end

local function on_step()
  local surface_list = storage.surface_list
  local n_surfaces = #surface_list
  if n_surfaces == 0 then return end

  local surface_list_cursor = storage.surface_list_cursor
  if surface_list_cursor < 1 or surface_list_cursor > n_surfaces then surface_list_cursor = 1 end

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
    local surface_index = surface_list[surface_list_cursor]
    local queue = storage.consumer_queue[surface_index]
    local n = queue and #queue or 0
    local advance_surface = true

    if n > 0 then
      local shared_inv = get_shared_inventory(surface_index)
      if shared_inv and not shared_inv.is_empty() then
        local ctx = build_step_context(shared_inv)
        local cursor = storage.consumer_cursor[surface_index] or 1
        if cursor > n then cursor = 1 end
        local cycle_complete = false

        while processed < batch_size and n > 0 do
          local consumer = queue[cursor]
          if consumer and consumer.entity.valid then
            fill_consumer(consumer, ctx)
            processed = processed + 1
            cursor = cursor + 1
          else
            -- Orphan: swap-pop with the last live entry. Cursor stays
            -- put so the next iteration picks up the entry we just
            -- swapped in. Belt-and-suspenders consumers[unit_number] = nil
            -- covers a missed destroy event (replays, mod meddling).
            if consumer and consumers[consumer.unit_number] == consumer then
              consumers[consumer.unit_number] = nil
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

        storage.consumer_cursor[surface_index] = cursor
        advance_surface = cycle_complete or n == 0
        commit_step(ctx)
      end
    end

    if advance_surface then
      surface_list_cursor = surface_list_cursor + 1
      if surface_list_cursor > n_surfaces then surface_list_cursor = 1 end
      surfaces_visited = surfaces_visited + 1
    else
      break
    end
  end

  storage.surface_list_cursor = surface_list_cursor
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

script.on_event(defines.events.on_object_destroyed, on_object_destroyed)

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
