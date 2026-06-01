-- Auto-Loader
--
-- Supply: every Auto-Loader chest is linked to one inventory per surface. On
-- build we set link_id to the surface index, so all chests on a surface share a
-- single linked-container inventory (keyed by prototype name, force, link_id).
--
-- Fill: distributes that pooled supply into turrets (ammo) and burners (fuel)
-- We keep a registry of fillable entities and sweep a bounded number of them
-- per tick in a round-robin cursor. For each surface we touch in a tick we read
-- its supply pool once, decrement a local tally as we insert, and write the total
-- back with a single remove at the end of the tick.
local CHEST = "auto-loader-chest"
local K_SETTING = "auto-loader-entities-per-tick"

-- Ammo target when the prototype gives no automated_ammo_count (vehicles,
-- characters). Caps how much ammo we keep stocked so a single entity can't drain
-- the whole pool; turrets use their own automated_ammo_count instead.
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
  for k in pairs(ITEM_FUEL) do ITEM_FUEL[k] = nil end
  for k in pairs(ITEM_AMMO) do ITEM_AMMO[k] = nil end
  for i = #FILLABLE_TYPES, 1, -1 do FILLABLE_TYPES[i] = nil end

  for name, proto in pairs(prototypes.item) do
    local fv = proto.fuel_value
    if fv and fv > 0 then ITEM_FUEL[name] = proto.fuel_category end
    -- ammo_category is only valid to read on ammo items.
    if proto.type == "ammo" then
      local ac = proto.ammo_category
      if ac then ITEM_AMMO[name] = ac.name end
    end
  end

  local typeset = {}
  for t in pairs(AMMO_DEFINE) do typeset[t] = true end
  for _, proto in pairs(prototypes.entity) do
    -- Burner-ness is a property of the energy source, not the entity type, so
    -- collect every type that has at least one burner prototype.
    if proto.burner_prototype then typeset[proto.type] = true end
  end
  for t in pairs(typeset) do FILLABLE_TYPES[#FILLABLE_TYPES + 1] = t end
end

----------------------------------------------------------------------
-- Supply half: per-surface linking + representative chest tracking.
----------------------------------------------------------------------

local function link_chest(entity)
  if not (entity and entity.valid and entity.name == CHEST) then return end
  entity.link_id = entity.surface.index
  -- Remember one chest per surface as the cheap handle to the pool. Validity is
  -- re-checked on use, so caching a chest that later gets mined is harmless.
  if storage.reps then storage.reps[entity.surface.index] = entity end
end

----------------------------------------------------------------------
-- Fillable registry.
----------------------------------------------------------------------

local function register_fillable(entity)
  if not (entity and entity.valid) then return end
  local un = entity.unit_number
  if not un then return end
  local fillables = storage.fillables
  if not fillables or fillables[un] then return end

  local etype = entity.type
  local ammo_define = AMMO_DEFINE[etype]
  local has_fuel = entity.burner ~= nil
  if not (ammo_define or has_fuel) then return end

  local ammo_target
  if ammo_define then
    local aac = entity.prototype.automated_ammo_count
    ammo_target = (aac and aac > 0) and aac or DEFAULT_AMMO_TARGET
  end

  fillables[un] = {
    entity = entity,
    type = etype,
    ammo_define = ammo_define,
    ammo_target = ammo_target,
    fuel = has_fuel or nil,
    is_locomotive = (etype == "locomotive") or nil,
  }
  local order = storage.order
  order[#order + 1] = un
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
  -- For entities useful_id is the unit_number. The order array keeps the stale
  -- slot until the sweep compacts it.
  local un = event.useful_id
  if un and storage.fillables then storage.fillables[un] = nil end
end

----------------------------------------------------------------------
-- Pool access: one read + one batched write per surface per tick.
----------------------------------------------------------------------

local function representative_chest(si)
  local rep = storage.reps[si]
  if rep and rep.valid and rep.name == CHEST then return rep end
  local surface = game.surfaces[si]
  if not surface then return nil end
  rep = surface.find_entities_filtered{ name = CHEST, limit = 1 }[1]
  storage.reps[si] = rep -- may be nil; a surface with no chest has no supply
  return rep
end

-- pools[si] is the per-tick cache: a pool table, or false meaning "no supply
-- here, don't retry this tick".
local function get_pool(si, pools)
  local cached = pools[si]
  if cached ~= nil then return cached or nil end

  local chest = representative_chest(si)
  local inv = chest and chest.get_inventory(defines.inventory.chest)
  if not inv then pools[si] = false; return nil end

  local avail, fuels, ammos = {}, {}, {}
  for _, item in pairs(inv.get_contents()) do
    local q = item.quality
    if type(q) == "table" then q = q.name end
    local byq = avail[item.name]
    if not byq then byq = {}; avail[item.name] = byq end
    byq[q] = (byq[q] or 0) + item.count
  end
  for name, byq in pairs(avail) do
    local fc, ac = ITEM_FUEL[name], ITEM_AMMO[name]
    if fc then
      for q, c in pairs(byq) do
        if c > 0 then fuels[#fuels + 1] = { name = name, quality = q, category = fc } end
      end
    end
    if ac then
      for q, c in pairs(byq) do
        if c > 0 then ammos[#ammos + 1] = { name = name, quality = q, category = ac } end
      end
    end
  end

  local pool = {
    inv = inv,
    force = chest.force,
    avail = avail,
    fuels = fuels,
    ammos = ammos,
    consumed = {},
  }
  pools[si] = pool
  return pool
end

local function pool_avail(pool, name, q)
  local byq = pool.avail[name]
  return (byq and byq[q]) or 0
end

local function pool_charge(pool, name, q, n)
  if n <= 0 then return end
  pool.avail[name][q] = pool.avail[name][q] - n
  local c = pool.consumed[name]
  if not c then c = {}; pool.consumed[name] = c end
  c[q] = (c[q] or 0) + n
end

----------------------------------------------------------------------
-- Filling.
----------------------------------------------------------------------

-- Ammo categories the character can actually fire right now. nil => no gun
-- equipped, so we insert nothing (don't stuff ammo for a gun they don't have).
local function character_categories(entity)
  local guns = entity.get_inventory(defines.inventory.character_guns)
  if not guns then return nil end
  local accepted
  for i = 1, #guns do
    local g = guns[i]
    if g.valid_for_read then
      local ap = g.prototype.attack_parameters
      local cats = ap and ap.ammo_categories
      if cats then
        accepted = accepted or {}
        for _, c in ipairs(cats) do accepted[c] = true end
      end
    end
  end
  return accepted
end

local function fill_ammo(entry, entity, pool)
  local inv = entity.get_inventory(entry.ammo_define)
  if not inv then return end

  local accepted
  if entry.type == "character" then
    accepted = character_categories(entity)
    if not accepted then return end
  end

  -- Top up to ammo_target total rounds (turrets reject wrong categories on
  -- insert; characters are pre-filtered by equipped guns).
  local current = 0
  for i = 1, #inv do
    local s = inv[i]
    if s.valid_for_read and ITEM_AMMO[s.name] then current = current + s.count end
  end
  local budget = entry.ammo_target - current
  if budget <= 0 then return end

  for _, a in ipairs(pool.ammos) do
    if budget <= 0 then break end
    if (not accepted) or accepted[a.category] then
      local av = pool_avail(pool, a.name, a.quality)
      if av > 0 then
        local want = budget < av and budget or av
        local inserted = inv.insert{ name = a.name, count = want, quality = a.quality }
        if inserted > 0 then
          pool_charge(pool, a.name, a.quality, inserted)
          budget = budget - inserted
        end
      end
    end
  end
end

-- Fill one fuel slot (used for locomotives, which we keep to a single slot so a
-- train fleet doesn't hoard fuel across all three).
local function fill_fuel_slot(slot, cats, pool)
  if not slot then return end
  if slot.valid_for_read then
    local name = slot.name
    local fc = ITEM_FUEL[name]
    if not (fc and cats[fc]) then return end -- foreign/unaccepted item; leave it
    local cap = prototypes.item[name].stack_size
    local gap = cap - slot.count
    if gap <= 0 then return end
    local q = slot.quality.name
    local av = pool_avail(pool, name, q)
    if av <= 0 then return end
    local take = gap < av and gap or av
    slot.count = slot.count + take
    pool_charge(pool, name, q, take)
  else
    for _, f in ipairs(pool.fuels) do
      if cats[f.category] then
        local av = pool_avail(pool, f.name, f.quality)
        if av > 0 then
          local cap = prototypes.item[f.name].stack_size
          local take = cap < av and cap or av
          slot.set_stack{ name = f.name, count = take, quality = f.quality }
          pool_charge(pool, f.name, f.quality, take)
          return
        end
      end
    end
  end
end

local function fill_fuel(entry, entity, pool)
  local inv = entity.get_fuel_inventory()
  if not inv then return end
  local burner = entity.burner
  local cats = burner and burner.fuel_categories
  if not cats then return end

  if entry.is_locomotive then
    fill_fuel_slot(inv[1], cats, pool)
    return
  end

  -- Top up to FUEL_TARGET total fuel rather than a full stack, so a large
  -- buildout can't drain the supply instantly (mirrors the ammo top-up).
  local current = 0
  for i = 1, #inv do
    local s = inv[i]
    if s.valid_for_read and ITEM_FUEL[s.name] then current = current + s.count end
  end
  local budget = FUEL_TARGET - current
  if budget <= 0 then return end

  for _, f in ipairs(pool.fuels) do
    if budget <= 0 then break end
    if cats[f.category] then
      local av = pool_avail(pool, f.name, f.quality)
      if av > 0 then
        local want = budget < av and budget or av
        local inserted = inv.insert{ name = f.name, count = want, quality = f.quality }
        if inserted > 0 then
          pool_charge(pool, f.name, f.quality, inserted)
          budget = budget - inserted
        end
      end
    end
  end
end

local function fill_entity(entry, pools)
  local entity = entry.entity
  if entity.to_be_deconstructed() then return end

  local pool = get_pool(entity.surface.index, pools)
  if not pool then return end
  -- The pool belongs to the chest's force; never fill another force's entities.
  if entity.force.index ~= pool.force.index then return end

  if entry.ammo_define then fill_ammo(entry, entity, pool) end
  if entry.fuel then fill_fuel(entry, entity, pool) end
end

----------------------------------------------------------------------
-- The bounded round-robin sweep.
----------------------------------------------------------------------

local function compact_order()
  local order = storage.order
  local w = 0
  for r = 1, #order do
    local un = order[r]
    if un ~= nil then
      w = w + 1
      order[w] = un
    end
  end
  for r = #order, w + 1, -1 do order[r] = nil end
  storage.nil_count = 0
  if storage.cursor > w then storage.cursor = 1 end
end

local function on_tick()
  local order = storage.order
  if not order then return end
  local n = #order
  if n == 0 then return end

  local fillables = storage.fillables
  local s = settings.global[K_SETTING]
  local k = (s and s.value) or 10

  local cursor = storage.cursor
  local pools = {}
  local filled, steps = 0, 0

  -- steps < n bounds the scan so a registry full of stale holes can't spin; the
  -- cursor persists across ticks for fair round-robin.
  while filled < k and steps < n do
    steps = steps + 1
    if cursor > n then cursor = 1 end
    local idx = cursor
    local un = order[idx]
    cursor = cursor + 1
    if un ~= nil then
      local entry = fillables[un]
      if entry and entry.entity.valid then
        fill_entity(entry, pools)
        filled = filled + 1
      else
        order[idx] = nil
        fillables[un] = nil
        storage.nil_count = storage.nil_count + 1
      end
    end
  end
  storage.cursor = cursor

  -- Single batched writeback per surface touched this tick.
  for _, pool in pairs(pools) do
    if pool and pool.inv.valid then
      for name, byq in pairs(pool.consumed) do
        for q, c in pairs(byq) do
          if c > 0 then pool.inv.remove{ name = name, count = c, quality = q } end
        end
      end
    end
  end

  if storage.nil_count * 4 > n then compact_order() end
end

----------------------------------------------------------------------
-- Lifecycle.
----------------------------------------------------------------------

local function initialize()
  build_caches()
  storage.fillables = storage.fillables or {}
  storage.order = storage.order or {}
  storage.cursor = storage.cursor or 1
  storage.nil_count = storage.nil_count or 0
  storage.reps = storage.reps or {}

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
