local batch_size
local tick_interval
local current_nth_tick
local max_fill
local default_fuel_strategy
local default_ammo_strategy
local fill_consumer              -- forward decl: try_register_consumer instant-fills via this
local build_filters_for_surface  -- forward decl: register_chest seeds new CCs via this
local update_combinators_for_surface -- forward decl: called from on_step / take_stack

local AMMO_INVENTORY = {
  ["ammo-turret"]      = defines.inventory.turret_ammo,
  ["car"]              = defines.inventory.car_ammo,
  ["spider-vehicle"]   = defines.inventory.spider_ammo,
  ["artillery-turret"] = defines.inventory.artillery_turret_ammo,
  ["artillery-wagon"]  = defines.inventory.artillery_wagon_ammo,
  ["character"]        = defines.inventory.character_ammo,
}

local CHEST_NAME = "auto-loader-chest-linked"
local CC_NAME    = "auto-loader-chest-cc"
local FRAME_NAME = "alc_priority_frame"

-- Circuit-network signals are int32. Counts in virtual storage are Lua
-- numbers and could in theory exceed that range; clamp before assigning
-- to a logistic filter so we never overflow.
local INT32_MAX = 2147483647

-- Item-kind sets, populated from prototypes once at startup and refreshed
-- on_configuration_changed. Mutated in place so closures over them stay valid.
local FUEL_ITEMS = {}
local AMMO_ITEMS = {}

-- Quality orderings — module-level, mutated in place. ASC: normal → legendary,
-- DESC: legendary → normal. Used by the highest/lowest-quality-first strategies
-- without per-fill allocation.
local QUALITY_ASC = {}
local QUALITY_DESC = {}

local STRATEGY_NAMES = {
  "highest_quality_first",
  "lowest_quality_first",
  "highest_count_first",
  "lowest_count_first",
}
local STRATEGY_NAME_TO_INDEX = {}
for i, name in ipairs(STRATEGY_NAMES) do
  STRATEGY_NAME_TO_INDEX[name] = i
end

local function rebuild_item_kind_sets()
  for k in pairs(FUEL_ITEMS) do FUEL_ITEMS[k] = nil end
  for k in pairs(AMMO_ITEMS) do AMMO_ITEMS[k] = nil end
  for name, proto in pairs(prototypes.item) do
    if proto.type == "ammo" then
      AMMO_ITEMS[name] = true
    elseif proto.fuel_category then
      FUEL_ITEMS[name] = true
    end
  end
end

local function rebuild_quality_orders()
  for k in pairs(QUALITY_ASC)  do QUALITY_ASC[k]  = nil end
  for k in pairs(QUALITY_DESC) do QUALITY_DESC[k] = nil end
  local list = {}
  for name, proto in pairs(prototypes.quality) do
    list[#list + 1] = { name = name, level = proto.level }
  end
  table.sort(list, function(a, b) return a.level < b.level end)
  local n = #list
  for i = 1, n do
    QUALITY_ASC[i] = list[i].name
    QUALITY_DESC[i] = list[n - i + 1].name
  end
end

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
  -- virtual[surface_index] = {
  --   fuel = { [item_name] = { strategy, totals = {[quality] = count} } },
  --   ammo = { same shape },
  --   fuel_order = { item_name, ... },  -- priority order, position 1 = highest
  --   ammo_order = { item_name, ... },
  -- }
  storage.virtual                   = {}
  -- last_sweep_tick[surface_index] = game.tick of last on_step sweep; throttle key
  storage.last_sweep_tick           = {}
  -- cc_by_chest[chest_unit_number] = paired hidden constant-combinator entity.
  -- Keyed by chest unit_number so destroy events resolve in O(1) without a
  -- separate cc-unit-number → chest map.
  storage.cc_by_chest               = {}
  -- alc_open_chest[player_index] = surface_index of the chest the player has open
  storage.alc_open_chest            = {}
  -- alc_open_tab[player_index] = "fuel" | "ammo" — last-selected priority tab
  storage.alc_open_tab              = {}
end

local function init_surface_virtual(surface_index)
  local v = storage.virtual[surface_index]
  if not v then
    v = { fuel = {}, ammo = {}, fuel_order = {}, ammo_order = {} }
    storage.virtual[surface_index] = v
  end
  return v
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
  init_surface_virtual(surface_index)
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

  -- Spawn the paired hidden constant-combinator and script-wire it to the
  -- chest's circuit ports. Player-attached red/green wires read the CC's
  -- output as if produced by the chest itself. The connection is invisible
  -- and not player-undoable because we mark it wire_origin.script.
  local surface = entity.surface
  local cc = surface.create_entity{
    name      = CC_NAME,
    position  = entity.position,
    force     = entity.force,
    create_build_effect_smoke = false,
    raise_built = false,
  }
  if cc then
    cc.destructible = false
    cc.operable     = false
    local chest_red    = entity.get_wire_connector(defines.wire_connector_id.circuit_red,           true)
    local chest_green  = entity.get_wire_connector(defines.wire_connector_id.circuit_green,         true)
    local cc_red       = cc.get_wire_connector(defines.wire_connector_id.combinator_output_red,     true)
    local cc_green     = cc.get_wire_connector(defines.wire_connector_id.combinator_output_green,   true)
    cc_red:connect_to(chest_red,     false, defines.wire_origin.script)
    cc_green:connect_to(chest_green, false, defines.wire_origin.script)
    -- One section is enough — the update path always writes to section 1.
    cc.get_or_create_control_behavior():add_section()
    storage.cc_by_chest[unit_number] = cc
    -- Seed with the surface's current virtual contents: another chest on
    -- this surface may have already accumulated stock before this one was
    -- placed. Assign filters directly to this single section instead of
    -- re-walking every chest on the surface.
    local section = cc.get_or_create_control_behavior().get_section(1)
    if section then section.filters = build_filters_for_surface(surface_index) end
  end
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

-- Drain occupied slots into virtual storage. The chest is the inserter target
-- and visible briefly to players, but items live as pure counts in virtual
-- storage once swept. Slot iteration preserves the order in which items first
-- arrive — that order seeds the priority list for newly-encountered items
-- (and also seeds priority on first sweep after upgrade from the old
-- slot-based model, where the player's slot 1 was already their priority 1).
local function sweep_into_virtual(shared_inv, surface_index)
  if shared_inv.is_empty() then return end
  local v = init_surface_virtual(surface_index)
  local size = #shared_inv
  for i = 1, size do
    local stack = shared_inv[i]
    if stack.valid_for_read then
      local name = stack.name
      local category, order, default_strat
      if AMMO_ITEMS[name] then
        category = v.ammo
        order = v.ammo_order
        default_strat = default_ammo_strategy
      elseif FUEL_ITEMS[name] then
        category = v.fuel
        order = v.fuel_order
        default_strat = default_fuel_strategy
      end
      if category then
        local entry = category[name]
        if not entry then
          entry = { strategy = default_strat, totals = {} }
          category[name] = entry
          order[#order + 1] = name
        end
        local quality = stack.quality.name
        entry.totals[quality] = (entry.totals[quality] or 0) + stack.count
        stack.count = 0
      end
    end
  end
end

-- Build a quality iteration order for one priority entry, given its strategy.
-- For quality-level strategies the cached module list is reused. For
-- count-based strategies we sort the entry's non-zero qualities by snapshot
-- count; the snapshot is stable for the duration of the step so all consumers
-- see the same order (deferred-commit invariant).
local function quality_order_for(entry)
  local strategy = entry.strategy
  if strategy == "highest_quality_first" then return QUALITY_DESC end
  if strategy == "lowest_quality_first"  then return QUALITY_ASC  end
  local totals = entry.totals
  local list = {}
  for q, c in pairs(totals) do
    if c > 0 then list[#list + 1] = q end
  end
  if strategy == "lowest_count_first" then
    table.sort(list, function(a, b) return totals[a] < totals[b] end)
  else
    table.sort(list, function(a, b) return totals[a] > totals[b] end)
  end
  return list
end

local function build_entries_for(category, order)
  local out, n = {}, 0
  for i = 1, #order do
    local name = order[i]
    local entry = category[name]
    if entry then
      n = n + 1
      out[n] = { name = name, totals = entry.totals, q_order = quality_order_for(entry) }
    end
  end
  return out, n
end

-- Per-step plan for one surface. Iterates the priority list (not slots) and
-- precomputes a quality-iteration order per entry. Consumers pull via
-- ctx.taken[name][quality]; ctx.totals[name][quality] is the live virtual
-- count at step start. commit_step decrements virtual totals once at the end.
local function build_step_context(surface_index)
  local v = storage.virtual[surface_index]
  if not v then return nil end
  local fuel_entries, fuel_count = build_entries_for(v.fuel, v.fuel_order)
  local ammo_entries, ammo_count = build_entries_for(v.ammo, v.ammo_order)
  return {
    fuel_entries = fuel_entries, fuel_count = fuel_count,
    ammo_entries = ammo_entries, ammo_count = ammo_count,
    taken = {},
  }
end

local function commit_step(ctx, surface_index)
  local v = storage.virtual[surface_index]
  if not v then return end
  for name, by_q in pairs(ctx.taken) do
    local entry = v.fuel[name] or v.ammo[name]
    if entry then
      local totals = entry.totals
      for quality, t in pairs(by_q) do
        local cur = totals[quality] or 0
        if t >= cur then
          totals[quality] = nil
        else
          totals[quality] = cur - t
        end
      end
    end
  end
end

-- Build a logistic-section filter list reflecting virtual storage on this
-- surface — one filter per (item × quality) with a non-zero count. Per-surface
-- (not per-chest) because all chests on a surface share one virtual store, so
-- the same table can be assigned to every chest's combinator. No de-dup
-- needed: sweep_into_virtual classifies each item name as exactly one of
-- fuel/ammo (the if/elseif against AMMO_ITEMS / FUEL_ITEMS).
build_filters_for_surface = function(surface_index)
  local v = storage.virtual[surface_index]
  if not v then return {} end
  local out, k = {}, 0
  for _, category in pairs({ v.fuel, v.ammo }) do
    for name, entry in pairs(category) do
      for quality, count in pairs(entry.totals) do
        if count > 0 then
          k = k + 1
          out[k] = {
            value = { type = "item", name = name, quality = quality, comparator = "=" },
            min   = (count > INT32_MAX) and INT32_MAX or count,
          }
        end
      end
    end
  end
  return out
end

-- Update every chest's paired combinator on this surface. Called only at
-- mutation points for storage.virtual[surface_index]; idle surfaces incur
-- zero work.
update_combinators_for_surface = function(surface_index)
  local chests = storage.chests_by_surface[surface_index]
  if not chests then return end
  local filters = build_filters_for_surface(surface_index)
  for unit_number in pairs(chests) do
    local cc = storage.cc_by_chest[unit_number]
    if cc and cc.valid then
      local section = cc.get_or_create_control_behavior().get_section(1)
      if section then section.filters = filters end
    end
  end
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
  -- while waiting for the cursor to come around. Operates against whatever
  -- virtual state on_step has already accumulated.
  local ctx = build_step_context(surface_index)
  if ctx and (ctx.fuel_count > 0 or ctx.ammo_count > 0) then
    fill_consumer(consumer, ctx)
    commit_step(ctx, surface_index)
    update_combinators_for_surface(surface_index)
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
    local cc = storage.cc_by_chest[unit_number]
    if cc and cc.valid then cc.destroy() end
    storage.cc_by_chest[unit_number] = nil
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
    for unit_number in pairs(chests) do
      storage.chest_surface[unit_number] = nil
      local cc = storage.cc_by_chest[unit_number]
      if cc and cc.valid then cc.destroy() end
      storage.cc_by_chest[unit_number] = nil
    end
  end
  storage.chests_by_surface[surface_index]         = nil
  storage.shared_chest[surface_index]              = nil
  storage.consumer_queue[surface_index]            = nil
  storage.consumer_cursor[surface_index]           = nil
  storage.virtual[surface_index]                   = nil
  remove_surface_from_list(surface_index)
end

local function fill_one_inventory(consumer_inv, entries, count, taken)
  if consumer_inv.is_full() then return end

  -- Aggregate the consumer's current contents in one boundary crossing
  -- instead of a per-slot get_item_count{...} below.
  local current = {}
  for _, e in ipairs(consumer_inv.get_contents()) do
    current[e.name .. "|" .. (e.quality or "normal")] = e.count
  end

  -- Priority-list iteration: entries[1] is highest priority. Within an
  -- entry, qualities are visited in q_order (per the entry's strategy).
  for i = 1, count do
    local entry = entries[i]
    local name = entry.name
    local totals = entry.totals
    local q_order = entry.q_order
    local taken_for_name = taken[name]

    for j = 1, #q_order do
      local quality = q_order[j]
      local total = totals[quality] or 0
      if total > 0 then
        local already = (taken_for_name and taken_for_name[quality]) or 0
        local available = total - already
        if available > 0 then
          local key = name .. "|" .. quality
          local have = current[key] or 0
          local want = max_fill - have
          if want > 0 then
            local to_insert = available < want and available or want
            local inserted = consumer_inv.insert{
              name = name, count = to_insert, quality = quality,
            }
            if inserted > 0 then
              if not taken_for_name then
                taken_for_name = {}
                taken[name] = taken_for_name
              end
              taken_for_name[quality] = already + inserted
              current[key] = have + inserted
              if consumer_inv.is_full() then return end
            end
          end
        end
      end
    end
  end
end

fill_consumer = function(consumer, ctx)
  local entity = consumer.entity
  if consumer.has_fuel and ctx.fuel_count > 0 then
    local fuel_inv = entity.get_fuel_inventory()
    if fuel_inv then
      fill_one_inventory(fuel_inv, ctx.fuel_entries, ctx.fuel_count, ctx.taken)
    end
  end
  if consumer.ammo_idx and ctx.ammo_count > 0 then
    local ammo_inv = entity.get_inventory(consumer.ammo_idx)
    if ammo_inv then
      fill_one_inventory(ammo_inv, ctx.ammo_entries, ctx.ammo_count, ctx.taken)
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
      -- Sweep at most once per 60 ticks per surface. Items dropped in by
      -- inserters can sit in the chest for up to ~1s before redistribution;
      -- the linked-container is shown to players directly so they see
      -- in-flight stock there rather than only in the priority GUI.
      local last = storage.last_sweep_tick[surface_index]
      if not last or game.tick - last >= 60 then
        local shared_inv = get_shared_inventory(surface_index)
        if shared_inv then sweep_into_virtual(shared_inv, surface_index) end
        storage.last_sweep_tick[surface_index] = game.tick
      end

      local ctx = build_step_context(surface_index)
      if ctx and (ctx.fuel_count > 0 or ctx.ammo_count > 0) then
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
        commit_step(ctx, surface_index)
        -- Virtual storage just changed (sweep added items, fills decremented
        -- totals, or both). Push the new state to circuit signals before
        -- moving to the next surface. Idle surfaces never get here.
        update_combinators_for_surface(surface_index)
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
  batch_size              = settings.global["auto-loader-chest-batch-size"].value
  tick_interval           = settings.global["auto-loader-chest-tick-interval"].value
  max_fill                = settings.global["auto-loader-chest-max-fill"].value
  default_fuel_strategy   = settings.global["auto-loader-chest-default-fuel-strategy"].value
  default_ammo_strategy   = settings.global["auto-loader-chest-default-ammo-strategy"].value
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
    -- Drop any orphan CCs from a prior version: reset_storage cleared
    -- cc_by_chest, so the world has hidden combinators we no longer
    -- track. Clean slate before register_chest recreates them.
    for _, cc in pairs(surface.find_entities_filtered{ name = CC_NAME }) do
      cc.destroy()
    end
    for _, entity in pairs(surface.find_entities()) do
      handle_built_entity(entity)
    end
  end
end

-- ── GUI ──────────────────────────────────────────────────────────────────
-- A relative-anchored frame opens beside the vanilla linked-container GUI
-- whenever a player opens an auto-loader chest. The GUI is rebuilt fully
-- on every interaction (priority list size N is small).

local function localised_strategy(strategy)
  return { "alc.strategy-" .. strategy:gsub("_", "-") }
end

local function localised_item_name(name)
  local proto = prototypes.item[name]
  if proto then return proto.localised_name end
  return name
end

local STRATEGY_BUTTON_CAPTION = {
  highest_quality_first = "Q↓",
  lowest_quality_first  = "Q↑",
  highest_count_first   = "N↓",
  lowest_count_first    = "N↑",
}

local function build_tab_bar(parent, active_tab)
  local bar = parent.add{ type = "flow", direction = "horizontal" }
  for _, tab_key in ipairs({ "fuel", "ammo" }) do
    local btn = bar.add{
      type = "button",
      caption = { "alc.tab-" .. tab_key },
      tags = { alc_action = "tab", tab = tab_key },
    }
    if tab_key == active_tab then
      btn.enabled = false
    end
  end
end

local function populate_priority_table(items_table, v, category_key)
  local order = v[category_key .. "_order"]
  for idx = 1, #order do
    local name = order[idx]
    local entry = v[category_key][name]
    if entry then
      local total = 0
      for _, c in pairs(entry.totals) do total = total + c end
      items_table.add{
        type = "sprite-button",
        sprite = "item/" .. name,
        tooltip = { "alc.take-stack-tooltip", localised_item_name(name) },
        number = total,
        style = "slot_button",
        tags = { alc_action = "take_stack", category = category_key, item = name },
      }
      local arrows = items_table.add{ type = "flow", direction = "horizontal" }
      arrows.style.horizontal_spacing = 0
      arrows.add{
        type = "sprite-button",
        sprite = "utility/speed_up",
        tags = { alc_action = "up", category = category_key, idx = idx },
        enabled = (idx > 1),
        style = "tool_button",
      }
      arrows.add{
        type = "sprite-button",
        sprite = "utility/speed_down",
        tags = { alc_action = "down", category = category_key, idx = idx },
        enabled = (idx < #order),
        style = "tool_button",
      }
      items_table.add{
        type = "button",
        caption = STRATEGY_BUTTON_CAPTION[entry.strategy] or "?",
        tooltip = { "alc.strategy-tooltip", localised_strategy(entry.strategy) },
        tags = { alc_action = "strategy_cycle", category = category_key, item = name },
        style = "tool_button",
      }
    end
  end
end

local function build_priority_section(parent, surface_index, category_key)
  local v = storage.virtual[surface_index]
  if not v then return end

  local order = v[category_key .. "_order"]

  if #order == 0 then
    parent.add{
      type = "label",
      caption = { "alc.empty-priority" },
    }
    return
  end

  local scroll = parent.add{
    type = "scroll-pane",
    name = "alc_scroll",
    vertical_scroll_policy = "auto-and-reserve-space",
    horizontal_scroll_policy = "never",
  }
  scroll.style.maximal_height = 400
  scroll.style.minimal_width  = 280

  local items_table = scroll.add{
    type = "table",
    name = "alc_items",
    column_count = 3,
  }

  populate_priority_table(items_table, v, category_key)
end

local function build_gui_for_player(player, surface_index)
  local relative = player.gui.relative
  if relative[FRAME_NAME] then relative[FRAME_NAME].destroy() end
  local frame = relative.add{
    type = "frame",
    name = FRAME_NAME,
    direction = "vertical",
    caption = { "alc.priority-frame-title" },
    anchor = {
      gui = defines.relative_gui_type.linked_container_gui,
      position = defines.relative_gui_position.right,
      name = CHEST_NAME,
    },
  }
  local active_tab = storage.alc_open_tab[player.index] or "ammo"
  build_tab_bar(frame, active_tab)
  local content = frame.add{
    type = "frame",
    direction = "vertical",
    style = "inside_shallow_frame_with_padding",
  }
  build_priority_section(content, surface_index, active_tab)
end

-- Refresh the priority list rows in place, preserving the scroll-pane (and
-- thus the user's scroll position). Falls back to a full rebuild if the
-- shape needs to change (empty-state label vs. populated table).
local function refresh_priority_items_for_player(player, surface_index)
  local relative = player.gui.relative
  local frame = relative[FRAME_NAME]
  if not frame then return end
  local active_tab = storage.alc_open_tab[player.index] or "ammo"
  local v = storage.virtual[surface_index]
  if not v then return end
  local order = v[active_tab .. "_order"]
  local content = frame.children[2]
  local scroll = content and content.alc_scroll
  local items_table = scroll and scroll.alc_items
  if (not items_table) or (not order) or #order == 0 then
    build_gui_for_player(player, surface_index)
    return
  end
  items_table.clear()
  populate_priority_table(items_table, v, active_tab)
end

local function destroy_gui_for_player(player)
  local relative = player.gui.relative
  if relative[FRAME_NAME] then relative[FRAME_NAME].destroy() end
end

local function on_gui_opened(event)
  if event.gui_type ~= defines.gui_type.entity then return end
  local entity = event.entity
  if not (entity and entity.valid) then return end
  if entity.name ~= CHEST_NAME then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  local surface_index = entity.surface.index
  storage.alc_open_chest[event.player_index] = surface_index
  build_gui_for_player(player, surface_index)
end

local function on_gui_closed(event)
  if event.gui_type ~= defines.gui_type.entity then return end
  local entity = event.entity
  if not (entity and entity.valid) then return end
  if entity.name ~= CHEST_NAME then return end
  local player = game.get_player(event.player_index)
  storage.alc_open_chest[event.player_index] = nil
  if player then destroy_gui_for_player(player) end
end

local function on_gui_click(event)
  local element = event.element
  if not (element and element.valid) then return end
  local tags = element.tags
  if not tags then return end
  local action = tags.alc_action
  if not action then return end

  local player = game.get_player(event.player_index)

  if action == "tab" then
    local tab = tags.tab
    if tab ~= "fuel" and tab ~= "ammo" then return end
    storage.alc_open_tab[event.player_index] = tab
    local surface_index = storage.alc_open_chest[event.player_index]
    if player and surface_index then build_gui_for_player(player, surface_index) end
    return
  end

  local surface_index = storage.alc_open_chest[event.player_index]
  if not surface_index then return end
  local v = storage.virtual[surface_index]
  if not v then return end

  if action == "up" or action == "down" then
    local category = tags.category
    local idx = tags.idx
    if not (category and idx) then return end
    local order = v[category .. "_order"]
    if not order then return end
    local n = #order
    if action == "up" then
      if idx > 1 then
        order[idx - 1], order[idx] = order[idx], order[idx - 1]
      end
    else
      if idx < n then
        order[idx + 1], order[idx] = order[idx], order[idx + 1]
      end
    end
    if player then refresh_priority_items_for_player(player, surface_index) end
    return
  end

  if action == "take_stack" then
    local category = tags.category
    local item_name = tags.item
    if not (category and item_name and player) then return end
    local entry = v[category][item_name]
    if not entry then return end
    local proto = prototypes.item[item_name]
    if not proto then return end
    local cursor = player.cursor_stack
    if not cursor then return end

    local q_order = quality_order_for(entry)
    local quality
    for i = 1, #q_order do
      if (entry.totals[q_order[i]] or 0) > 0 then
        quality = q_order[i]
        break
      end
    end
    if not quality then
      if player then refresh_priority_items_for_player(player, surface_index) end
      return
    end

    local available = entry.totals[quality]
    local stack_size = proto.stack_size
    local to_take
    if cursor.valid_for_read then
      if cursor.name ~= item_name or cursor.quality.name ~= quality then return end
      local space = stack_size - cursor.count
      if space <= 0 then return end
      to_take = available < space and available or space
      cursor.count = cursor.count + to_take
    else
      to_take = available < stack_size and available or stack_size
      if not cursor.set_stack{ name = item_name, count = to_take, quality = quality } then
        return
      end
    end

    if to_take >= available then
      entry.totals[quality] = nil
    else
      entry.totals[quality] = available - to_take
    end

    -- Player just pulled stock out of virtual storage; refresh circuit
    -- signals before the GUI rebuild reads from the same data.
    update_combinators_for_surface(surface_index)
    refresh_priority_items_for_player(player, surface_index)
    return
  end

  if action == "strategy_cycle" then
    local category = tags.category
    local item = tags.item
    if not (category and item) then return end
    local entry = v[category][item]
    if not entry then return end
    local cur = STRATEGY_NAME_TO_INDEX[entry.strategy] or 1
    local n = #STRATEGY_NAMES
    local dir = (event.button == defines.mouse_button_type.right) and -1 or 1
    local next_idx = ((cur - 1 + dir) % n) + 1
    entry.strategy = STRATEGY_NAMES[next_idx]
    if player then refresh_priority_items_for_player(player, surface_index) end
    return
  end
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

script.on_init(function()
  rebuild_item_kind_sets()
  rebuild_quality_orders()
  reset_storage()
  refresh_settings()
  scan_all_surfaces()
  reapply_on_nth_tick()
end)

script.on_configuration_changed(function()
  rebuild_item_kind_sets()
  rebuild_quality_orders()
  reset_storage()
  refresh_settings()
  scan_all_surfaces()
  reapply_on_nth_tick()
end)

script.on_load(function()
  rebuild_item_kind_sets()
  rebuild_quality_orders()
  refresh_settings()
  reapply_on_nth_tick()
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting_type ~= "runtime-global" then return end
  local name = event.setting
  if name == "auto-loader-chest-batch-size"
     or name == "auto-loader-chest-tick-interval"
     or name == "auto-loader-chest-max-fill"
     or name == "auto-loader-chest-default-fuel-strategy"
     or name == "auto-loader-chest-default-ammo-strategy" then
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

script.on_event(defines.events.on_gui_opened,                    on_gui_opened)
script.on_event(defines.events.on_gui_closed,                    on_gui_closed)
script.on_event(defines.events.on_gui_click,                     on_gui_click)
