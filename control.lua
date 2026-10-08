-- Auto-Loader
--
-- Supply: every Auto-Loader chest is linked to one inventory per surface. On
-- build we set link_id to the surface index, so all chests on a surface share a
-- single linked-container inventory (keyed by prototype name, force, link_id).
--
-- Fill: distributes that pooled supply into turrets (ammo) and burners (fuel)
-- We retain consumers by surface/force and sweep only buckets with a chest.
-- Dormant buckets cost no refill visits; one cursor traverses the active buckets.
local CHEST = "auto-loader-chest"
local ENTITIES_PER_TICK_SETTING = "auto-loader-entities-per-tick"
local AMMO_REFILL_DELAY_SETTING = "auto-loader-player-ammo-refill-delay"

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

-- item name -> fuel categories (array of strings), only for items that actually burn.
local ITEM_FUEL = {}
-- item name -> ammo categories (single-element array of strings).
local ITEM_AMMO = {}
-- entity types worth scanning at init (ammo types + every burner type).
local FILLABLE_TYPES = {}

local function build_caches()
  for item_name in pairs(ITEM_FUEL) do ITEM_FUEL[item_name] = nil end
  for item_name in pairs(ITEM_AMMO) do ITEM_AMMO[item_name] = nil end
  for type_index = #FILLABLE_TYPES, 1, -1 do FILLABLE_TYPES[type_index] = nil end

  for name, prototype in pairs(prototypes.item) do
    local fuel_value = prototype.fuel_value
    if fuel_value and fuel_value > 0 then
      ITEM_FUEL[name] = prototype.fuel_categories
    end
    -- ammo_category is only valid to read on ammo items.
    if prototype.type == "ammo" then
      local ammo_category = prototype.ammo_category
      if ammo_category then ITEM_AMMO[name] = { ammo_category.name } end
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
-- Supply half: physical chest membership, independent of linked inventories.
----------------------------------------------------------------------

-- Forward declaration: chest transitions control the refill subscription.
local on_tick
local set_bucket_active

local function restore_tick_handler()
  script.on_event(defines.events.on_tick, (storage.chest_count or 0) > 0 and on_tick or nil)
end

local function remove_chest(unit_number)
  local record = storage.chest_records[unit_number]
  if not record then return end
  local surfaces = storage.chest_buckets[record.surface_index]
  local bucket = surfaces[record.force_index]
  bucket.members[unit_number] = nil
  bucket.count = bucket.count - 1
  if bucket.count == 0 then
    surfaces[record.force_index] = nil
    set_bucket_active(record.surface_index, record.force_index, false)
  end
  if next(surfaces) == nil then storage.chest_buckets[record.surface_index] = nil end
  storage.chest_records[unit_number] = nil
  storage.chest_destructions[record.registration_number] = nil
  storage.chest_count = storage.chest_count - 1
  if storage.chest_count == 0 then restore_tick_handler() end
end

local function link_chest(entity)
  if not (entity and entity.valid and entity.name == CHEST) then return end
  local unit_number = entity.unit_number
  if not unit_number or storage.chest_records[unit_number] then return end
  local surface_index, force_index = entity.surface.index, entity.force.index
  entity.link_id = surface_index
  local surfaces = storage.chest_buckets[surface_index]
  if not surfaces then surfaces = {}; storage.chest_buckets[surface_index] = surfaces end
  local bucket = surfaces[force_index]
  if not bucket then bucket = {count = 0, members = {}}; surfaces[force_index] = bucket end
  local registration_number = script.register_on_object_destroyed(entity)
  local record = {entity = entity, unit_number = unit_number,
    registration_number = registration_number, surface_index = surface_index, force_index = force_index}
  bucket.members[unit_number] = true
  bucket.count = bucket.count + 1
  storage.chest_records[unit_number] = record
  storage.chest_destructions[registration_number] = unit_number
  storage.chest_count = storage.chest_count + 1
  if bucket.count == 1 then set_bucket_active(surface_index, force_index, true) end
  if storage.chest_count == 1 then restore_tick_handler() end
end

-- Eligibility needs only one live chest. Prune invalid records until that
-- witness is found; destruction events clean up the remaining records.
local function eligible_pool(surface_index, force, pools)
  local force_index = force.index
  pools[surface_index] = pools[surface_index] or {}
  local cached = pools[surface_index][force_index]
  if cached ~= nil then return cached or nil end
  local surfaces = storage.chest_buckets[surface_index]
  local bucket = surfaces and surfaces[force_index]
  if bucket then
    for unit_number in pairs(bucket.members) do
      if storage.chest_records[unit_number].entity.valid then break end
      remove_chest(unit_number)
    end
  end
  local pool = bucket and bucket.count > 0 and {surface_index = surface_index, force = force} or false
  pools[surface_index][force_index] = pool
  return pool or nil
end

----------------------------------------------------------------------
-- Fillable registry.
----------------------------------------------------------------------

-- All consumers remain indexed, but only supplied, nonempty buckets appear in
-- active_buckets. Chest transitions never rescan entities or splice a global queue.
set_bucket_active = function(surface_index, force_index, supplied)
  local surfaces = storage.consumer_buckets[surface_index]
  local bucket = surfaces and surfaces[force_index]
  if not bucket then return end
  local active = storage.active_buckets
  if supplied and #bucket.order > 0 and not bucket.active_index then
    active[#active + 1] = bucket
    bucket.active_index = #active
    storage.active_consumer_count = storage.active_consumer_count + #bucket.order
  elseif not supplied and bucket.active_index then
    local index = bucket.active_index
    table.remove(active, index)
    for i = index, #active do active[i].active_index = i end
    local cursor = storage.traversal
    if index < cursor.bucket then
      cursor.bucket = cursor.bucket - 1 -- same group, shifted left
    elseif index == cursor.bucket then
      cursor.consumer = 1 -- start the successor group at its first consumer
    end
    if cursor.bucket > #active then cursor.bucket = 1 end
    bucket.active_index = nil
    storage.active_consumer_count = storage.active_consumer_count - #bucket.order
  end
end

local function enqueue(entry, unit_number)
  local surface_index, force_index = entry.entity.surface.index, entry.entity.force.index
  local surfaces = storage.consumer_buckets[surface_index]
  if not surfaces then surfaces = {}; storage.consumer_buckets[surface_index] = surfaces end
  local bucket = surfaces[force_index]
  if not bucket then
    bucket = {surface_index = surface_index, force_index = force_index, order = {}}
    surfaces[force_index] = bucket
  end
  entry.bucket = bucket
  entry.order_index = #bucket.order + 1
  bucket.order[entry.order_index] = unit_number
  if bucket.active_index then
    storage.active_consumer_count = storage.active_consumer_count + 1
  else
    local chests = storage.chest_buckets[surface_index]
    set_bucket_active(surface_index, force_index, chests and chests[force_index] ~= nil)
  end
end

local function dequeue(entry)
  local bucket, index = entry.bucket, entry.order_index
  local order = bucket.order
  local last = order[#order]
  order[index] = last
  order[#order] = nil
  if index <= #order then
    storage.fillables[last].order_index = index
  end
  if bucket.active_index then storage.active_consumer_count = storage.active_consumer_count - 1 end
  local cursor = storage.traversal
  if bucket.active_index == cursor.bucket and cursor.consumer > #order then
    cursor.consumer = 1
  end
  if #order == 0 then
    set_bucket_active(bucket.surface_index, bucket.force_index, false)
    local surfaces = storage.consumer_buckets[bucket.surface_index]
    surfaces[bucket.force_index] = nil
    if next(surfaces) == nil then storage.consumer_buckets[bucket.surface_index] = nil end
  end
  entry.bucket, entry.order_index = nil, nil
end

local function remove_fillable(unit_number)
  local entry = storage.fillables[unit_number]
  if not entry then return end
  dequeue(entry)
  storage.fillables[unit_number] = nil
end

local function relocate_fillable(entity)
  if not (entity and entity.valid) then return end
  local entry = storage.fillables[entity.unit_number]
  if entry and (entry.bucket.surface_index ~= entity.surface.index
      or entry.bucket.force_index ~= entity.force.index) then
    dequeue(entry)
    enqueue(entry, entity.unit_number)
  end
end

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
  enqueue(fillables[unit_number], unit_number)
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
  local chest_unit = storage.chest_destructions[event.registration_number]
  if chest_unit then remove_chest(chest_unit) end
  -- Remove dormant consumers too, without waiting for a refill visit.
  local unit_number = event.useful_id
  if unit_number then remove_fillable(unit_number) end
end

----------------------------------------------------------------------
-- Pool access: demand-driven per-tick ledgers, with debits after the sweep.
----------------------------------------------------------------------

local function get_pool(surface_index, force, pools)
  local pool = eligible_pool(surface_index, force, pools)
  if not pool then return nil end
  if pool.items then return pool end
  local inventory = force.get_linked_inventory(CHEST, surface_index)
  if not (inventory and inventory.valid) then pools[surface_index][force.index] = false; return nil end

  pool.inventory, pool.available, pool.items, pool.fuels, pool.ammos = inventory, {}, {}, {}, {}
  for _, contents in pairs(inventory.get_contents()) do
    local name, quality = contents.name, contents.quality
    if ITEM_FUEL[name] or ITEM_AMMO[name] then
      if type(quality) ~= "string" then quality = quality.name end
      local item = { name = name, quality = quality, count = contents.count, consumed = 0 }
      pool.available[name] = pool.available[name] or {}
      pool.available[name][quality] = item
      pool.items[#pool.items + 1] = item
      if ITEM_FUEL[name] then pool.fuels[#pool.fuels + 1] = item end
      if ITEM_AMMO[name] then pool.ammos[#pool.ammos + 1] = item end
    end
  end
  pools[surface_index][force.index] = pool
  return pool
end

-- Resolve location and supply only after an inventory reports demand.
local function entity_pool(entity, pools)
  return get_pool(entity.surface.index, entity.force, pools)
end

local function pool_item(pool, name, quality)
  local qualities = pool.available[name]
  return qualities and qualities[quality]
end

local function consume(item, count)
  item.count = item.count - count
  item.consumed = item.consumed + count
end

local function debit_pools(pools)
  -- No other event handler runs between our snapshot and these debits.
  for _, forces in pairs(pools) do
    for _, pool in pairs(forces) do
      if pool and pool.inventory then
        for _, item in ipairs(pool.items) do
          if item.consumed > 0 then
            pool.inventory.remove{ name = item.name, quality = item.quality, count = item.consumed }
          end
        end
      end
    end
  end
end

local function transfer_inventory(inventory, item, desired_count)
  local inserted = inventory.insert{
    name = item.name, quality = item.quality, count = math.min(desired_count, item.count),
  }
  consume(item, inserted)
  return inserted
end

----------------------------------------------------------------------
-- Filling.
----------------------------------------------------------------------

local function accepts_category(accepted_categories, item_categories)
  if not accepted_categories then return true end
  if not item_categories then return false end
  for _, category in ipairs(item_categories) do
    if accepted_categories[category] then return true end
  end
  return false
end

-- Occupied slots only accept their exact item/quality. Empty slots additionally
-- validate their filters before removing anything from supply.
local function fill_slot(slot, accepted_categories, target_count, entity, pools, item_kind, item_categories)
  if not slot then return end
  if slot.valid_for_read then
    local name = slot.name
    if not accepts_category(accepted_categories, item_categories[name]) then return end
    local gap = math.min(target_count, prototypes.item[name].stack_size) - slot.count
    if gap <= 0 then return end
    local pool = entity_pool(entity, pools)
    local item = pool and pool_item(pool, name, slot.quality.name)
    if item and item.count > 0 then
      local before = slot.count
      slot.count = before + math.min(gap, item.count)
      consume(item, slot.count - before)
    end
    return -- another item cannot go into this occupied slot
  end
  local pool = entity_pool(entity, pools)
  if not pool then return end
  for _, item in ipairs(pool[item_kind]) do
    if item.count > 0 and accepts_category(accepted_categories, item_categories[item.name]) then
      local request = {
        name = item.name, quality = item.quality,
        count = math.min(target_count, prototypes.item[item.name].stack_size, item.count),
      }
      if slot.can_set_stack(request) and slot.set_stack(request) then
        consume(item, slot.count)
        return
      end
    end
  end
end

-- Character ammo slots pair 1:1 with gun slots, so each slot is topped up
-- independently with ammo its own gun can fire. Slots with no gun get nothing.
local function fill_character_ammo(entry, entity, pools)
  local guns = entity.get_inventory(defines.inventory.character_guns)
  local inventory = entity.get_inventory(entry.ammo_define)
  if not (guns and inventory) then return end
  local player = entity.player
  local cursor = player and player.cursor_stack
  local holding_ammo = cursor and cursor.valid_for_read and ITEM_AMMO[cursor.name]
  local delay_setting = player and player.mod_settings[AMMO_REFILL_DELAY_SETTING]
  local delay_ticks = (delay_setting and delay_setting.value or 10) * 60

  local slots = #guns < #inventory and #guns or #inventory
  for slot_index = 1, slots do
    local gun = guns[slot_index]
    local slot = inventory[slot_index]
    -- Holding ammo postpones refilling empty slots so the player can remove guns.
    if gun.valid_for_read and not slot.valid_for_read and holding_ammo then
      entry.ammo_refill_after = game.tick + delay_ticks
    end
    local delayed = entry.ammo_refill_after and game.tick < entry.ammo_refill_after
    if gun.valid_for_read and (slot.valid_for_read or not delayed) then
      local attack_parameters = gun.prototype.attack_parameters
      local accepted_categories = attack_parameters and attack_parameters.ammo_categories
      if accepted_categories then
        local accepted = {}
        for _, category in ipairs(accepted_categories) do accepted[category] = true end
        fill_slot(slot, accepted, entry.ammo_target, entity, pools, "ammos", ITEM_AMMO)
      end
    end
  end
end

-- Prefer existing eligible stacks, then other supplied identities. A successful
-- partial fill is enough for this sweep, preserving existing refill behavior.
local function fill_inventory(inventory, target_count, entity, pools, item_kind, item_categories, accepted_categories)
  local current = 0
  local preferred_slot, preferred_name, preferred_index
  for slot_index = 1, #inventory do
    local slot = inventory[slot_index]
    if slot.valid_for_read then
      local name = slot.name
      local categories = item_categories[name]
      if categories then
        current = current + slot.count
        if not preferred_slot and accepts_category(accepted_categories, categories) then
          preferred_slot, preferred_name, preferred_index = slot, name, slot_index
        end
      end
    end
  end
  local budget = target_count - current
  if budget <= 0 then return end
  local pool = entity_pool(entity, pools)
  if not pool or #pool[item_kind] == 0 then return end
  local rejected
  if preferred_slot then
    local item = pool_item(pool, preferred_name, preferred_slot.quality.name)
    if item and item.count > 0 then
      if transfer_inventory(inventory, item, budget) > 0 then return end
      rejected = { [item] = true }
    end
  end
  for slot_index = (preferred_index or #inventory) + 1, #inventory do
    local slot = inventory[slot_index]
    if slot.valid_for_read and item_categories[slot.name]
        and accepts_category(accepted_categories, item_categories[slot.name]) then
      local item = pool_item(pool, slot.name, slot.quality.name)
      if item and item.count > 0 and not (rejected and rejected[item]) then
        if transfer_inventory(inventory, item, budget) > 0 then return end
        rejected = rejected or {}
        rejected[item] = true
      end
    end
  end
  for _, item in ipairs(pool[item_kind]) do
    if item.count > 0 and not (rejected and rejected[item])
        and accepts_category(accepted_categories, item_categories[item.name]) then
      if transfer_inventory(inventory, item, budget) > 0 then return end
    end
  end
end

local function fill_ammo(entry, entity, pools)
  if entry.type == "character" then
    fill_character_ammo(entry, entity, pools)
    return
  end
  local inventory = entity.get_inventory(entry.ammo_define)
  if inventory then fill_inventory(inventory, entry.ammo_target, entity, pools, "ammos", ITEM_AMMO, nil) end
end

local function fill_fuel(entry, entity, pools)
  local inventory = entity.get_fuel_inventory()
  local burner = entity.burner
  local accepted_categories = burner and burner.fuel_categories
  if not (inventory and accepted_categories) then return end
  if entry.is_locomotive then
    -- Trains keep one full stack, without hoarding across all three slots.
    fill_slot(inventory[1], accepted_categories, math.huge, entity, pools, "fuels", ITEM_FUEL)
  else
    fill_inventory(inventory, FUEL_TARGET, entity, pools, "fuels", ITEM_FUEL, accepted_categories)
  end
end

local function fill_entity(entry, pools)
  local entity = entry.entity
  if entity.to_be_deconstructed() then return end

  if entry.ammo_define then fill_ammo(entry, entity, pools) end
  if entry.fuel then fill_fuel(entry, entity, pools) end
end

----------------------------------------------------------------------
-- The bounded round-robin sweep.
----------------------------------------------------------------------

on_tick = function()
  local remaining = storage.active_consumer_count
  if remaining == 0 then return end
  local setting = settings.global[ENTITIES_PER_TICK_SETTING]
  remaining = math.min(remaining, (setting and setting.value) or 10)
  local pools = {}
  local cursor = storage.traversal
  while remaining > 0 and #storage.active_buckets > 0 do
    local bucket = storage.active_buckets[cursor.bucket]
    local unit_number = bucket.order[cursor.consumer]
    cursor.consumer = cursor.consumer + 1
    if cursor.consumer > #bucket.order then
      cursor.consumer = 1
      cursor.bucket = cursor.bucket % #storage.active_buckets + 1
    end
    remaining = remaining - 1
    local entry = storage.fillables[unit_number]
    if entry.entity.valid then
      fill_entity(entry, pools)
    else
      remove_fillable(unit_number)
    end
  end
  debit_pools(pools)
end

----------------------------------------------------------------------
-- Lifecycle.
----------------------------------------------------------------------

local function initialize()
  build_caches()
  storage.fillables = storage.fillables or {}
  storage.order, storage.cursor = nil, nil -- discard the old global queue
  storage.consumer_buckets, storage.active_buckets = {}, {}
  storage.traversal = {bucket = 1, consumer = 1}
  storage.bucket_cursor = nil -- discard the earlier scheduler's cursor
  storage.active_consumer_count = 0
  storage.chest_buckets = {}
  storage.chest_records = {}
  storage.chest_destructions = {}
  storage.chest_count = 0
  storage.representative_chests = nil -- discard the previous representative cache
  storage.supply_candidates = nil -- discard the previous engine's persistent cache on upgrade

  -- Preserve character debounce state while rebuilding routing on upgrades.
  for unit_number, entry in pairs(storage.fillables) do
    if entry.entity.valid then enqueue(entry, unit_number)
    else storage.fillables[unit_number] = nil end
  end
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
  restore_tick_handler()
end

script.on_init(initialize)
script.on_configuration_changed(initialize)
script.on_load(function()
  build_caches()
  restore_tick_handler() -- storage reads only; no game access or world scan
end)

for _, event in ipairs(BUILD_EVENTS) do
  script.on_event(event, on_built)
end
script.on_event(defines.events.on_entity_cloned, on_built)
script.on_event(defines.events.on_object_destroyed, on_object_destroyed)

local function on_player_character(event)
  local player = game.get_player(event.player_index)
  if player and player.character then register_fillable(player.character) end
end
script.on_event(defines.events.on_player_created, on_player_character)
script.on_event(defines.events.on_player_respawned, on_player_character)

-- Entity clone events register both chests and consumers individually. Import
-- does not promise those events, so bootstrap the imported surface once.
script.on_event(defines.events.on_surface_imported, function(event)
  local surface = game.surfaces[event.surface_index]
  if not surface then return end
  for _, chest in ipairs(surface.find_entities_filtered{ name = CHEST }) do link_chest(chest) end
  for _, entity in ipairs(surface.find_entities_filtered{ type = FILLABLE_TYPES }) do register_fillable(entity) end
end)

local function on_chest_removed(event)
  local entity = event.entity
  if entity and entity.valid and entity.name == CHEST then remove_chest(entity.unit_number) end
end
for _, event in ipairs({defines.events.on_player_mined_entity, defines.events.on_robot_mined_entity,
    defines.events.on_space_platform_mined_entity, defines.events.on_entity_died,
    defines.events.script_raised_destroy}) do
  script.on_event(event, on_chest_removed)
end

local function on_surface_removed(event)
  local surfaces = storage.chest_buckets[event.surface_index]
  if surfaces then
    for _, bucket in pairs(surfaces) do
      for unit_number in pairs(bucket.members) do remove_chest(unit_number) end
    end
  end
  local consumers = storage.consumer_buckets[event.surface_index]
  if consumers then
    for _, bucket in pairs(consumers) do
      while #bucket.order > 0 do remove_fillable(bucket.order[#bucket.order]) end
    end
  end
end
script.on_event(defines.events.on_surface_cleared, on_surface_removed)
script.on_event(defines.events.on_surface_deleted, on_surface_removed)

script.on_event(defines.events.on_forces_merged, function(event)
  -- Move consumers before chest transitions activate the destination buckets.
  for _, entry in pairs(storage.fillables) do
    if entry.entity.valid and entry.bucket.force_index == event.source_index then
      relocate_fillable(entry.entity)
    end
  end
  -- The source force is already gone; recorded keys remain safe to read.
  local members = {}
  for unit_number, record in pairs(storage.chest_records) do
    if record.force_index == event.source_index then members[#members + 1] = unit_number end
  end
  for _, unit_number in ipairs(members) do
    local entity = storage.chest_records[unit_number].entity
    remove_chest(unit_number)
    if entity.valid then link_chest(entity) end
  end
end)

-- Routing changes are event-driven even while the refill handler is disabled.
local function on_player_routing_changed(event)
  local player = game.get_player(event.player_index)
  if player and player.character then
    register_fillable(player.character)
    relocate_fillable(player.character)
  end
  if player and player.vehicle then relocate_fillable(player.vehicle) end
end
script.on_event(defines.events.on_player_changed_surface, on_player_routing_changed)
script.on_event(defines.events.on_player_changed_force, on_player_routing_changed)
script.on_event(defines.events.script_raised_teleported, function(event)
  relocate_fillable(event.entity)
end)
