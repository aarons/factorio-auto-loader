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

local CHEST_NAME = "auto-loader-chest"

-- Fraction of the per-step batch budget reserved for the rescan true-up.
-- The fill loop gets the remainder. With batch_size=10 → 7 fills per surface
-- + 3 rescan actions per step.
local RESCAN_BUDGET_RATIO = 0.3

local function reset_storage()
  storage.chests_by_surface         = {}
  storage.consumer_queue            = {}
  storage.consumer_cursor           = {}
  storage.consumers                 = {}
  storage.destroy_registry          = {}
  storage.known_consumer_names      = {}
  storage.consumer_count_by_surface = {}
  storage.last_fill_tick            = {}
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
    if storage.last_fill_tick then storage.last_fill_tick[entry.unit_number] = nil end
    local count_map = storage.consumer_count_by_surface
    if count_map[entry.surface_index] then
      count_map[entry.surface_index] = count_map[entry.surface_index] - 1
    end
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
  storage.chests_by_surface[surface_index]         = nil
  storage.consumer_queue[surface_index]            = nil
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

local function fill_one_inventory(consumer_inv, surface_chests)
  if not consumer_inv or consumer_inv.is_full() then return 0 end
  local total = 0
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
                  total = total + inserted
                end
              end
            end
          end
          if consumer_inv.is_full() then return total end
        end
      end
    end
  end
  return total
end

local function fill_consumer(entity, surface_chests)
  local total = 0
  local fuel_inv = entity.get_fuel_inventory()
  if fuel_inv then total = total + fill_one_inventory(fuel_inv, surface_chests) end

  local idx = AMMO_INVENTORY[entity.type]
  local ammo_inv = idx and entity.get_inventory(idx)
  if ammo_inv then total = total + fill_one_inventory(ammo_inv, surface_chests) end
  return total
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
    local surface_chests = storage.chests_by_surface[surface_index]
    if surface_chests and next(surface_chests) then
      local n = #queue
      if n > 0 then
        local cursor = storage.consumer_cursor[surface_index] or 1
        if cursor > n then cursor = 1 end
        local processed = 0
        local nil_count = 0
        local consumers = storage.consumers
        while processed < fill_budget do
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
              local inserted = fill_consumer(entity, surface_chests)
              if inserted > 0 then
                storage.last_fill_tick[unit_number] = game.tick
              end
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
  refill_trigger        = settings.global["auto-loader-chest-refill-trigger"].value
  max_insert_overrides  = parse_overrides(settings.global["auto-loader-chest-insert-overrides"].value)
end

local function reapply_on_nth_tick()
  if current_nth_tick == tick_interval then return end
  if current_nth_tick then script.on_nth_tick(current_nth_tick, nil) end
  script.on_nth_tick(tick_interval, on_step)
  current_nth_tick = tick_interval
end

local function dump_inventory(player, label, inv)
  if not inv then
    player.print(string.format("  %s: <none>", label))
    return
  end
  player.print(string.format("  %s: %d slots, full=%s, empty=%s",
    label, #inv, tostring(inv.is_full()), tostring(inv.is_empty())))
  for _, s in ipairs(inv.get_contents()) do
    player.print(string.format("    %s x %d (q=%s)", s.name, s.count, s.quality or "normal"))
  end
end

-- Dry-run trace: walk the same chest-iteration the fill loop would, and print
-- what each chest stack offers + whether the consumer's inventory could
-- accept it. Read-only — uses can_insert rather than insert.
local function trace_for_inventory(player, inv, chest_list)
  if not inv then return end
  if inv.is_full() then
    player.print("    (target inventory is full)")
    return
  end
  for _, c in ipairs(chest_list) do
    local cinv = c.get_inventory(defines.inventory.chest)
    if not cinv or cinv.is_empty() then
      player.print(string.format("    chest un=%d: empty", c.unit_number))
    else
      for _, stack in ipairs(cinv.get_contents()) do
        local q       = stack.quality or "normal"
        local cap     = max_insert_overrides[stack.name] or max_fill
        local trigger = refill_trigger
        if trigger >= cap then trigger = cap - 1 end
        local current = inv.get_item_count{ name = stack.name, quality = q }
        local can     = inv.can_insert{ name = stack.name, count = 1, quality = q }
        local note
        if cap == 0 then
          note = "skip (cap=0)"
        elseif current > trigger and get_stack_size(stack.name) > 1 then
          note = string.format("skip (current=%d > trigger=%d)", current, trigger)
        else
          local want = cap - current
          if want <= 0 then
            note = string.format("skip (current=%d >= cap=%d)", current, cap)
          else
            local attempt = stack.count < want and stack.count or want
            note = string.format("would attempt %d (current=%d, cap=%d, can_insert=%s)",
              attempt, current, cap, tostring(can))
          end
        end
        player.print(string.format("    chest un=%d: %s q=%s x %d -> %s",
          c.unit_number, stack.name, q, stack.count, note))
      end
    end
  end
end

local function inspect_entity(player, entity)
  if not (entity and entity.valid) then
    player.print("[auto-loader] hover over an entity, then run /al-inspect again")
    return
  end
  local un = entity.unit_number
  local si = entity.surface.index
  player.print(string.format("[auto-loader] %s (un=%s, surface=%d, tick=%d)",
    entity.name, tostring(un), si, game.tick))

  if entity.name == CHEST_NAME then
    local chests = storage.chests_by_surface[si]
    local registered = chests and un and chests[un] ~= nil
    player.print(string.format("  role: chest, registered=%s", tostring(registered)))
    dump_inventory(player, "contents", entity.get_inventory(defines.inventory.chest))
    return
  end

  local registered = un and storage.consumers[un] ~= nil
  local last       = un and storage.last_fill_tick and storage.last_fill_tick[un]
  local last_str   = last and string.format("tick %d (%d ago)", last, game.tick - last) or "never"
  player.print(string.format("  role: consumer, registered=%s, last fill: %s",
    tostring(registered), last_str))

  local fuel_inv = entity.get_fuel_inventory()
  local idx      = AMMO_INVENTORY[entity.type]
  local ammo_inv = idx and entity.get_inventory(idx)
  if not (fuel_inv or ammo_inv) then
    player.print("  no fuel or ammo inventory — would not be registered as a consumer")
    return
  end
  if ammo_inv then dump_inventory(player, "ammo", ammo_inv) end
  if fuel_inv then dump_inventory(player, "fuel", fuel_inv) end

  local chests = storage.chests_by_surface[si]
  local chest_list = {}
  if chests then
    for _, c in pairs(chests) do
      if c.valid then chest_list[#chest_list + 1] = c end
    end
  end
  player.print(string.format("  surface chests: %d", #chest_list))

  if #chest_list == 0 then return end
  if ammo_inv then
    player.print("  trace for ammo inv:")
    trace_for_inventory(player, ammo_inv, chest_list)
  end
  if fuel_inv then
    player.print("  trace for fuel inv:")
    trace_for_inventory(player, fuel_inv, chest_list)
  end
end

local function inspect_status(player)
  local consumer_count = 0
  for _ in pairs(storage.consumers) do consumer_count = consumer_count + 1 end
  local chest_total = 0
  for _, chests in pairs(storage.chests_by_surface) do
    for _, c in pairs(chests) do
      if c.valid then chest_total = chest_total + 1 end
    end
  end
  player.print(string.format("[auto-loader] consumers=%d, chests=%d, batch_size=%d, tick_interval=%d, max_fill=%d, refill_trigger=%d",
    consumer_count, chest_total, batch_size or -1, tick_interval or -1, max_fill or -1, refill_trigger or -1))
end

commands.add_command(
  "al-inspect",
  "Inspect the entity under the cursor; dry-run an auto-loader fill check.",
  function(cmd)
    local player = game.get_player(cmd.player_index)
    if not player then return end
    inspect_entity(player, player.selected)
  end
)

script.on_event("al-inspect", function(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  inspect_entity(player, player.selected)
end)

commands.add_command(
  "al-status",
  "Print auto-loader registry counts and active settings.",
  function(cmd)
    local player = game.get_player(cmd.player_index)
    if not player then return end
    inspect_status(player)
  end
)

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
     or name == "auto-loader-chest-refill-trigger"
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
