-- Auto-Loader
--
-- Supply: every Auto-Loader chest is linked to one inventory per surface. On
-- build we set link_id to the surface index, so all chests on a surface share a
-- single linked-container inventory (keyed by prototype name, force, link_id).
--
-- Fill: distributes that pooled supply into turrets (ammo) and burners (fuel)
-- We keep a registry of fillable entities in an array (order) and sweep a
-- bounded number per tick with a round-robin cursor. A dead entry is removed by
-- swap-popping it
local CHEST = "auto-loader-chest"
local ENTITIES_PER_TICK_SETTING = "auto-loader-entities-per-tick"

-- Ammo target when the prototype gives no automated_ammo_count (vehicles,
-- characters). Caps how much ammo we keep stocked so a single entity can't drain
-- the whole pool; turrets use their own automated_ammo_count instead. For
-- characters this applies per ammo slot (each slot serves its paired gun).
local DEFAULT_AMMO_TARGET = 10
local FUEL_TARGET = 10

-- Item-ammo inventories
local AMMO_DEFINE = {
  ["ammo-turret"]      = defines.inventory.turret_ammo,
  ["artillery-turret"] = defines.inventory.artillery_turret_ammo,
  ["artillery-wagon"]  = defines.inventory.artillery_wagon_ammo,
  ["car"]              = defines.inventory.car_ammo,
  ["spider-vehicle"]   = defines.inventory.spider_ammo,
  ["character"]        = defines.inventory.character_ammo,
}

local BUILD_EVENTS = {
  defines.events.on_built_entity,
  defines.events.on_robot_built_entity,
  defines.events.on_space_platform_built_entity,
  defines.events.script_raised_built,
  defines.events.script_raised_revive,
}

----------------------------------------------------------------------
-- Prototype-derived caches (rebuilt every load; never stored).
----------------------------------------------------------------------

-- item name -> fuel category (string), only for items that actually burn.
local ITEM_FUEL = {}
-- item name -> ammo category (string).
local ITEM_AMMO = {}
-- entity types worth scanning at init (ammo types + every burner type).
local FILLABLE_TYPES = {}

local function build_caches()
  for item_name in pairs(ITEM_FUEL) do ITEM_FUEL[item_name] = nil end
  for item_name in pairs(ITEM_AMMO) do ITEM_AMMO[item_name] = nil end
  for type_index = #FILLABLE_TYPES, 1, -1 do FILLABLE_TYPES[type_index] = nil end

  for name, prototype in pairs(prototypes.item) do
    local fuel_value = prototype.fuel_value
    if fuel_value and fuel_value > 0 then ITEM_FUEL[name] = prototype.fuel_category end
    -- ammo_category is only valid to read on ammo items.
    if prototype.type == "ammo" then
      local ammo_category = prototype.ammo_category
      if ammo_category then ITEM_AMMO[name] = ammo_category.name end
    end
  end

  local fillable_entity_types = {}
  for entity_type in pairs(AMMO_DEFINE) do fillable_entity_types[entity_type] = true end
  for _, prototype in pairs(prototypes.entity) do
    -- Burner-ness is a property of the energy source, not the entity type, so
    -- collect every type that has at least one burner prototype.
    if prototype.burner_prototype then fillable_entity_types[prototype.type] = true end
  end
  for entity_type in pairs(fillable_entity_types) do FILLABLE_TYPES[#FILLABLE_TYPES + 1] = entity_type end
end

----------------------------------------------------------------------
-- Supply half: per-surface linking + representative chest tracking.
----------------------------------------------------------------------

local function link_chest(entity)
  if not (entity and entity.valid and entity.name == CHEST) then return end
  entity.link_id = entity.surface.index
  -- Remember one chest per surface and force as the pool handle. Validity is
  -- re-checked on use, so caching a chest that later gets mined is harmless.
  if storage.representative_chests then
    local surface_index, force_index = entity.surface.index, entity.force.index
    storage.representative_chests[surface_index] = storage.representative_chests[surface_index] or {}
    storage.representative_chests[surface_index][force_index] = entity
  end
end

----------------------------------------------------------------------
-- Fillable registry.
----------------------------------------------------------------------

local function register_fillable(entity)
  if not (entity and entity.valid) then return end
  local unit_number = entity.unit_number
  if not unit_number then return end
  local fillables = storage.fillables
  if not fillables or fillables[unit_number] then return end

  local entity_type = entity.type
  local ammo_define = AMMO_DEFINE[entity_type]
  local has_fuel = entity.burner ~= nil
  if not (ammo_define or has_fuel) then return end

  local ammo_target
  if ammo_define then
    local automated_ammo_count = entity.prototype.automated_ammo_count
    ammo_target = (automated_ammo_count and automated_ammo_count > 0) and automated_ammo_count or DEFAULT_AMMO_TARGET
  end

  fillables[unit_number] = {
    entity = entity,
    type = entity_type,
    ammo_define = ammo_define,
    ammo_target = ammo_target,
    fuel = has_fuel or nil,
    is_locomotive = (entity_type == "locomotive") or nil,
  }
  local order = storage.order
  order[#order + 1] = unit_number
  -- Reliable removal backstop regardless of how the entity dies.
  script.register_on_object_destroyed(entity)
end

local function on_built(event)
  local entity = event.entity or event.destination
  if not (entity and entity.valid) then return end
  if entity.name == CHEST then
    link_chest(entity)
  else
    register_fillable(entity)
  end
end

local function on_object_destroyed(event)
  -- For entities useful_id is the unit_number. The sweep swap-pops the stale
  -- slot out of the order array when it next reaches it.
  local unit_number = event.useful_id
  if unit_number and storage.fillables then storage.fillables[unit_number] = nil end
end

----------------------------------------------------------------------
-- Pool access: persistent candidates, lazy discovery, immediate transfers.
----------------------------------------------------------------------

local function representative_chest(surface_index, force)
  local representative_chests = storage.representative_chests[surface_index]
  if not representative_chests then representative_chests = {}; storage.representative_chests[surface_index] = representative_chests end
  local chest = representative_chests[force.index]
  if chest and chest.valid and chest.name == CHEST
      and chest.surface.index == surface_index and chest.force.index == force.index
      and chest.link_id == surface_index then return chest end
  local surface = game.surfaces[surface_index]
  if not surface then return nil end
  chest = surface.find_entities_filtered{ name = CHEST, force = force, limit = 1 }[1]
  if chest then link_chest(chest) end
  representative_chests[force.index] = chest
  return chest
end

local function get_pool(surface_index, force, pools)
  local force_index = force.index
  pools[surface_index] = pools[surface_index] or {}
  local cached = pools[surface_index][force_index]
  if cached ~= nil then return cached or nil end

  local chest = representative_chest(surface_index, force)
  local inventory = chest and chest.get_inventory(defines.inventory.chest)
  if not inventory then pools[surface_index][force_index] = false; return nil end

  -- Persist candidate identities for save/load and multiplayer consistency.
  -- No quantities are retained; remove() is always the source of truth.
  local candidates = storage.supply_candidates
  candidates[surface_index] = candidates[surface_index] or {}
  candidates[surface_index][force_index] = candidates[surface_index][force_index] or { fuels = {}, ammos = {} }
  local pool = { inventory = inventory, chest = chest, candidates = candidates[surface_index][force_index] }
  pools[surface_index][force_index] = pool
  return pool
end

local function discover(pool)
  if pool.discovered then return false end
  pool.discovered = true -- includes empty or incompatible supply for this tick
  local candidates = { fuels = {}, ammos = {} }
  for _, item in pairs(pool.inventory.get_contents()) do
    local name, quality = item.name, item.quality
    if type(quality) ~= "string" then quality = quality.name end
    local fuel_category, ammo_category = ITEM_FUEL[name], ITEM_AMMO[name]
    if fuel_category then
      candidates.fuels[#candidates.fuels + 1] = { name = name, quality = quality, category = fuel_category }
    end
    if ammo_category then
      candidates.ammos[#candidates.ammos + 1] = { name = name, quality = quality, category = ammo_category }
    end
  end
  pool.candidates.fuels = candidates.fuels
  pool.candidates.ammos = candidates.ammos
  return true
end

-- Try each identity once per consumer, even if discovery finds it again.
-- Compatibility failures must not evict candidates needed by other consumers.
local function try_candidates(pool, candidate_kind, attempt_transfer, attempted_candidates)
  attempted_candidates = attempted_candidates or {}
  local function try_cached()
    for _, item in ipairs(pool.candidates[candidate_kind]) do
      local key = item.name .. "/" .. item.quality
      if not attempted_candidates[key] then
        attempted_candidates[key] = true
        if attempt_transfer(item) > 0 then return true end
      end
    end
    return false
  end
  if try_cached() then return end
  if discover(pool) then try_cached() end
end

-- A supply bar/filter can prevent reinsertion into the space removal freed.
-- Preserve any rejected refund at the representative chest instead of losing it.
local function refund(pool, request)
  local returned = pool.inventory.insert(request)
  if returned < request.count then
    request.count = request.count - returned
    local chest = pool.chest
    chest.surface.spill_item_stack{
      position = chest.position, stack = request, enable_looted = true,
      force = chest.force, allow_belts = false, use_start_position_on_failure = true,
    }
  end
end

local function transfer_inventory(pool, inventory, item, desired_count)
  local request = { name = item.name, quality = item.quality }
  request.count = math.min(desired_count, inventory.get_insertable_count(request))
  if request.count <= 0 then return 0 end
  local removed = pool.inventory.remove(request)
  if removed == 0 then return 0 end
  request.count = removed
  local inserted = inventory.insert(request)
  if inserted < removed then
    request.count = removed - inserted
    refund(pool, request)
  end
  return inserted
end

----------------------------------------------------------------------
-- Filling.
----------------------------------------------------------------------

-- Once the force unlocks logistic requests, the player's request list becomes
-- the source of truth for character ammo: returns the set of requested ammo
-- item names (empty when personal logistics are paused or no ammo is
-- requested), so clearing the request lets a player unload their ammo — e.g.
-- before boarding a space platform — without the mod instantly refilling it.
-- Returns nil while requests are still locked, so early-game characters keep
-- getting filled unconditionally.
local function character_requested_ammo(entity)
  if not entity.force.character_logistic_requests then return nil end
  local point = entity.get_requester_point()
  if not point then return nil end
  local requested_item_names = {}
  if point.enabled then
    for _, request_filter in ipairs(point.filters or {}) do
      -- Matched by name across qualities: a request for an ammo item at any
      -- quality keeps every quality of it flowing from the pool.
      if request_filter.name and ITEM_AMMO[request_filter.name] and (request_filter.count or 0) > 0 then
        requested_item_names[request_filter.name] = true
      end
    end
  end
  return requested_item_names
end

-- Occupied slots only accept their exact item/quality. Empty slots additionally
-- validate their filters before removing anything from supply.
local function fill_slot(slot, accepted_categories, requested_item_names, target_count, pool, candidate_kind, item_categories)
  if not slot then return end
  if slot.valid_for_read then
    local name = slot.name
    if not accepted_categories[item_categories[name]] or (requested_item_names and not requested_item_names[name]) then return end
    local gap = math.min(target_count, prototypes.item[name].stack_size) - slot.count
    if gap <= 0 then return end
    local removed = pool.inventory.remove{ name = name, quality = slot.quality.name, count = gap }
    if removed > 0 then slot.count = slot.count + removed end
    return -- another item cannot go into this occupied slot
  end
  try_candidates(pool, candidate_kind, function(item)
    if not accepted_categories[item.category] or (requested_item_names and not requested_item_names[item.name]) then return 0 end
    local request = {
      name = item.name, quality = item.quality,
      count = math.min(target_count, prototypes.item[item.name].stack_size),
    }
    if not slot.can_set_stack(request) then return 0 end
    local removed = pool.inventory.remove(request)
    if removed == 0 then return 0 end
    request.count = removed
    if slot.set_stack(request) then return removed end
    refund(pool, request)
    return 0
  end)
end

-- Character ammo slots pair 1:1 with gun slots, so each slot is topped up
-- independently with ammo its own gun can fire. Slots with no gun get nothing.
local function fill_character_ammo(entry, entity, pool)
  local guns = entity.get_inventory(defines.inventory.character_guns)
  local inventory = entity.get_inventory(entry.ammo_define)
  if not (guns and inventory) then return end
  local requested_item_names = character_requested_ammo(entity)

  local slots = #guns < #inventory and #guns or #inventory
  for slot_index = 1, slots do
    local gun = guns[slot_index]
    if gun.valid_for_read then
      local attack_parameters = gun.prototype.attack_parameters
      local accepted_categories = attack_parameters and attack_parameters.ammo_categories
      if accepted_categories then
        local accepted = {}
        for _, category in ipairs(accepted_categories) do accepted[category] = true end
        fill_slot(inventory[slot_index], accepted, requested_item_names, entry.ammo_target, pool, "ammos", ITEM_AMMO)
      end
    end
  end
end

-- Prefer existing eligible stacks, then cached/discovered alternatives. A
-- successful partial fill is enough for this sweep; do not discover to finish it.
local function fill_inventory(inventory, target_count, pool, candidate_kind, item_categories, accepted_categories)
  local current = 0
  for slot_index = 1, #inventory do
    local slot = inventory[slot_index]
    if slot.valid_for_read and item_categories[slot.name] then current = current + slot.count end
  end
  local budget = target_count - current
  if budget <= 0 then return end
  local attempted_candidates = {}
  for slot_index = 1, #inventory do
    local slot = inventory[slot_index]
    if slot.valid_for_read and item_categories[slot.name]
        and (not accepted_categories or accepted_categories[item_categories[slot.name]]) then
      local item = { name = slot.name, quality = slot.quality.name }
      local key = item.name .. "/" .. item.quality
      if not attempted_candidates[key] then
        attempted_candidates[key] = true
        if transfer_inventory(pool, inventory, item, budget) > 0 then return end
      end
    end
  end
  try_candidates(pool, candidate_kind, function(item)
    if accepted_categories and not accepted_categories[item.category] then return 0 end
    return transfer_inventory(pool, inventory, item, budget)
  end, attempted_candidates)
end

local function fill_ammo(entry, entity, pool)
  if entry.type == "character" then
    fill_character_ammo(entry, entity, pool)
    return
  end
  local inventory = entity.get_inventory(entry.ammo_define)
  if inventory then fill_inventory(inventory, entry.ammo_target, pool, "ammos", ITEM_AMMO) end
end

local function fill_fuel(entry, entity, pool)
  local inventory = entity.get_fuel_inventory()
  local burner = entity.burner
  local accepted_categories = burner and burner.fuel_categories
  if not (inventory and accepted_categories) then return end
  if entry.is_locomotive then
    -- Trains keep one full stack, without hoarding across all three slots.
    fill_slot(inventory[1], accepted_categories, nil, math.huge, pool, "fuels", ITEM_FUEL)
  else
    fill_inventory(inventory, FUEL_TARGET, pool, "fuels", ITEM_FUEL, accepted_categories)
  end
end

local function fill_entity(entry, pools)
  local entity = entry.entity
  if entity.to_be_deconstructed() then return end

  local pool = get_pool(entity.surface.index, entity.force, pools)
  if not pool then return end

  if entry.ammo_define then fill_ammo(entry, entity, pool) end
  if entry.fuel then fill_fuel(entry, entity, pool) end
end

----------------------------------------------------------------------
-- The bounded round-robin sweep.
----------------------------------------------------------------------

local function on_tick()
  local order = storage.order
  if not order then return end
  local entity_count = #order
  if entity_count == 0 then return end

  local fillables = storage.fillables
  local entities_per_tick_setting = settings.global[ENTITIES_PER_TICK_SETTING]
  local entities_per_tick = (entities_per_tick_setting and entities_per_tick_setting.value) or 10

  local cursor = storage.cursor
  local pools = {}
  local filled, steps = 0, 0

  -- steps < entity_count bounds the scan; the cursor persists across ticks for fair
  -- round-robin. entity_count is the pre-sweep length, so swap-pops this tick may leave
  -- nils in the tail slots [#order+1, entity_count] which we simply skip.
  while filled < entities_per_tick and steps < entity_count do
    steps = steps + 1
    if cursor > entity_count then cursor = 1 end
    local order_index = cursor
    local unit_number = order[order_index]
    cursor = cursor + 1
    if unit_number ~= nil then
      local entry = fillables[unit_number]
      if entry and entry.entity.valid then
        fill_entity(entry, pools)
        filled = filled + 1
      else
        -- Dead entry: swap the tail into this slot and pop. O(1), keeps the
        -- array dense. We don't revisit order_index this cycle (skipping one entity on
        -- a removal is fine since the queue drains quickly).
        local last_index = #order
        order[order_index] = order[last_index]
        order[last_index] = nil
        fillables[unit_number] = nil
      end
    end
  end
  storage.cursor = cursor
end

----------------------------------------------------------------------
-- Lifecycle.
----------------------------------------------------------------------

local function initialize()
  build_caches()
  storage.fillables = storage.fillables or {}
  storage.order = storage.order or {}
  storage.cursor = storage.cursor or 1
  -- Rebuild the old surface-only representative map on upgrades too.
  storage.representative_chests = {}
  storage.supply_candidates = {}

  for _, surface in pairs(game.surfaces) do
    for _, chest in ipairs(surface.find_entities_filtered{ name = CHEST }) do
      link_chest(chest)
    end
    for _, entity in ipairs(surface.find_entities_filtered{ type = FILLABLE_TYPES }) do
      register_fillable(entity)
    end
  end
  for _, player in pairs(game.players) do
    if player.character then register_fillable(player.character) end
  end
end

script.on_init(initialize)
script.on_configuration_changed(initialize)
script.on_load(build_caches)

for _, event in ipairs(BUILD_EVENTS) do
  script.on_event(event, on_built)
end
script.on_event(defines.events.on_entity_cloned, on_built)
script.on_event(defines.events.on_object_destroyed, on_object_destroyed)
script.on_event(defines.events.on_tick, on_tick)

local function on_player_character(event)
  local player = game.get_player(event.player_index)
  if player and player.character then register_fillable(player.character) end
end
script.on_event(defines.events.on_player_created, on_player_character)
script.on_event(defines.events.on_player_respawned, on_player_character)

-- Rescan a region (or whole surface, area = nil) after a clone/import: relink
-- chests and register any fillables. Both calls are idempotent.
local function rescan_area(surface, area)
  for _, chest in ipairs(surface.find_entities_filtered{ area = area, name = CHEST }) do
    link_chest(chest)
  end
  for _, entity in ipairs(surface.find_entities_filtered{ area = area, type = FILLABLE_TYPES }) do
    register_fillable(entity)
  end
end

script.on_event(defines.events.on_area_cloned, function(event)
  if event.clone_entities then
    rescan_area(event.destination_surface, event.destination_area)
  end
end)
script.on_event(defines.events.on_surface_imported, function(event)
  rescan_area(event.surface, nil)
end)
