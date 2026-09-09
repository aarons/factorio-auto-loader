-- Run from the repository root: lua tests/supply.lua
-- Exercise the real transfer functions with inventories that track API calls.
defines = { inventory = { character_guns = 1, character_ammo = 2 }, events = {} }
script = { on_init = function() end, on_configuration_changed = function() end,
  on_load = function() end, on_event = function() end }
storage = { representative_chests = {}, supply_candidates = {} }
prototypes = { item = {
  bullet = { stack_size = 100 }, piercing = { stack_size = 100 },
  shell = { stack_size = 100 }, coal = { stack_size = 50 },
} }
local file = assert(io.open('control.lua'))
local source = file:read('*a'); file:close()
local supply_functions = assert(load(source .. [[
ITEM_AMMO.bullet, ITEM_AMMO.piercing, ITEM_AMMO.shell = 'bullet', 'bullet', 'shotgun'
ITEM_FUEL.coal = 'chemical'
return { fill_inventory = fill_inventory, fill_slot = fill_slot, get_pool = get_pool, fill_character_ammo = fill_character_ammo }
]]))()
local ammo = { bullet = 'bullet', piercing = 'bullet', shell = 'shotgun' }
local function assert_equal(actual, expected)
  assert(actual == expected, ('expected %s, got %s'):format(expected, actual))
end
local function supply(stock)
  local inventory = { reads = 0, removes = 0, valid = true }
  inventory.remove = function(item)
    inventory.removes = inventory.removes + 1
    local key = item.name .. '/' .. item.quality
    local item_count = math.min(item.count, stock[key] or 0)
    stock[key] = (stock[key] or 0) - item_count
    return item_count
  end
  inventory.insert = function(item)
    local key = item.name .. '/' .. item.quality
    stock[key] = (stock[key] or 0) + item.count
    return item.count
  end
  inventory.get_contents = function()
    inventory.reads = inventory.reads + 1
    local contents = {}
    for key, item_count in pairs(stock) do
      if item_count > 0 then
        local name, quality = key:match('(.+)/(.+)')
        contents[#contents + 1] = { name = name, quality = quality, count = item_count }
      end
    end
    return contents
  end
  return inventory
end
local function slot(name, count, quality, allowed_item_name)
  local item_stack = { name = name, count = count or 0, quality = { name = quality or 'normal' },
    valid_for_read = name ~= nil }
  item_stack.can_set_stack = function(item) return not allowed_item_name or allowed_item_name == item.name end
  item_stack.set_stack = function(item)
    if not item_stack.can_set_stack(item) then return false end
    item_stack.name, item_stack.count, item_stack.quality, item_stack.valid_for_read = item.name, item.count, {name=item.quality}, true
    return true
  end
  return item_stack
end
local function destination(item_stack, capacity, insertion_limit)
  local inventory = { item_stack }
  inventory.get_insertable_count = function(item)
    if item_stack.valid_for_read and (item_stack.name ~= item.name or item_stack.quality.name ~= item.quality) then return 0 end
    return capacity - item_stack.count
  end
  inventory.insert = function(item)
    local item_count = math.min(item.count, inventory.get_insertable_count(item), insertion_limit or math.huge)
    if item_count > 0 then item_stack.set_stack{name=item.name, quality=item.quality, count=item_stack.count+item_count} end
    return item_count
  end
  return inventory
end
local function pool(stock, candidates)
  return { inventory = supply(stock), candidates = { ammos = candidates or {}, fuels = {} } }
end
local function fill(supply_pool, inventory) supply_functions.fill_inventory(inventory, 10, supply_pool, 'ammos', ammo) end

-- Exact quality, short supply: remove first and only insert what was removed.
local stock = { ['bullet/rare'] = 3, ['bullet/normal'] = 100 }
local supply_pool = pool(stock)
local item_stack = slot('bullet', 2, 'rare')
fill(supply_pool, destination(item_stack, 100))
assert_equal(item_stack.count, 5); assert_equal(stock['bullet/rare'], 0); assert_equal(stock['bullet/normal'], 100); assert_equal(supply_pool.inventory.reads, 0)
-- Sufficiently stocked destinations never inspect/remove supply.
item_stack.count = 10
fill(supply_pool, destination(item_stack, 100)); assert_equal(supply_pool.inventory.removes, 1); assert_equal(supply_pool.inventory.reads, 0)

-- Empty discovery is shared across consumers, but retries on the next tick.
stock = {}; supply_pool = pool(stock)
for _ = 1, 20 do fill(supply_pool, destination(slot(), 100)) end
assert_equal(supply_pool.inventory.reads, 1)
stock['bullet/normal'] = 20
supply_pool.discovered = nil -- get_pool creates a fresh wrapper each tick
item_stack = slot(); fill(supply_pool, destination(item_stack, 100)); assert_equal(item_stack.count, 10); assert_equal(supply_pool.inventory.reads, 2)
-- Warm candidates survive the tick without a contents scan.
supply_pool.discovered = nil
fill(supply_pool, destination(slot(), 100)); assert_equal(supply_pool.inventory.reads, 2)

-- Stale candidates rediscover an alternative; occupied slots cannot switch.
supply_pool = pool({ ['piercing/normal'] = 20 }, {{name='bullet',quality='normal',category='bullet'}})
item_stack = slot('bullet', 2)
fill(supply_pool, destination(item_stack, 100)); assert_equal(item_stack.name, 'bullet'); assert_equal(item_stack.count, 2)
item_stack = slot(); fill(supply_pool, destination(item_stack, 100)); assert_equal(item_stack.name, 'piercing'); assert_equal(item_stack.count, 10)
assert_equal(supply_pool.inventory.reads, 1)

-- General insertion can accept less than its capacity estimate: refund it.
stock = { ['bullet/normal'] = 10 }; supply_pool = pool(stock)
item_stack = slot('bullet', 1)
fill(supply_pool, destination(item_stack, 100, 2)); assert_equal(item_stack.count, 3); assert_equal(stock['bullet/normal'], 8)

-- A barred/filtered supply can reject refunds: preserve leftovers at the chest.
supply_pool = pool({ ['bullet/normal'] = 10 })
local spilled = 0
supply_pool.inventory.insert = function() return 0 end
supply_pool.chest = { position = {0, 0}, force = {}, surface = {
  spill_item_stack = function(spill_parameters) spilled = spilled + spill_parameters.stack.count end,
} }
item_stack = slot('bullet', 1)
fill(supply_pool, destination(item_stack, 100, 2)); assert_equal(item_stack.count, 3); assert_equal(spilled, 7)

-- Character compatibility, filters and quality stay slot-specific.
supply_pool = pool({ ['bullet/normal'] = 20, ['shell/rare'] = 20 })
item_stack = slot(nil, nil, nil, 'shell')
supply_functions.fill_slot(item_stack, {bullet=true}, 10, supply_pool, 'ammos', ammo)
assert_equal(item_stack.valid_for_read, false)
supply_functions.fill_slot(item_stack, {shotgun=true}, 10, supply_pool, 'ammos', ammo)
assert_equal(item_stack.name, 'shell'); assert_equal(item_stack.quality.name, 'rare'); assert_equal(item_stack.count, 10); assert_equal(supply_pool.inventory.reads, 1)

-- Locomotive single-slot policy retains a full stack target and partial fills.
supply_pool = pool({ ['coal/normal'] = 70 })
item_stack = slot()
supply_functions.fill_slot(item_stack, {chemical=true}, math.huge, supply_pool, 'fuels', {coal='chemical'})
assert_equal(item_stack.count, 50)

-- Surface/force handles cannot select another force's linked inventory.
local force1, force2 = {index=1}, {index=2}
local chests = {}
local surface = {index=1}
surface.find_entities_filtered = function(filter) return {chests[filter.force.index]} end
game = {surfaces = {surface}}
for _, force in ipairs({force1, force2}) do
  local inventory = supply({})
  chests[force.index] = {valid=true, name='auto-loader-chest', force=force,
    surface=surface, link_id=1, get_inventory=function() return inventory end}
end
local pools = {}
local first = supply_functions.get_pool(1, force1, pools)
local second = supply_functions.get_pool(1, force2, pools)
assert(first.inventory ~= second.inventory); assert(first.candidates ~= second.candidates)
assert_equal(first, supply_functions.get_pool(1, force1, pools)); assert_equal(first.inventory.reads, 0)
local next_tick = supply_functions.get_pool(1, force1, {})
assert_equal(first.candidates, next_tick.candidates); assert_equal(next_tick.discovered, nil)
chests[1].valid = false
chests[1] = nil
assert_equal(supply_functions.get_pool(1, force1, {}), nil)
print('Supply regression checks passed')


-- Player debounce uses real character fill logic and a simulated game clock.
local function character(delay)
  local guns = {
    {valid_for_read=true, prototype={attack_parameters={ammo_categories={'bullet'}}}},
    {valid_for_read=true, prototype={attack_parameters={ammo_categories={'bullet'}}}},
  }
  local inventory = {slot(), slot('bullet', 1)}
  local player = {cursor_stack=slot('bullet', 10), mod_settings={
    ['auto-loader-player-ammo-refill-delay']={value=delay},
  }}
  local entity = {player=player, unit_number=123,
    force={character_logistic_requests=true},
    get_requester_point=function() error('Logistics must not be consulted') end,
    get_inventory=function(id) return id == defines.inventory.character_guns and guns or inventory end,
  }
  player.character = entity
  local entry = {ammo_define=defines.inventory.character_ammo, ammo_target=10}
  local supply_pool = pool({['bullet/normal']=100})
  local function refill(tick)
    game.tick = tick
    supply_functions.fill_character_ammo(entry, entity, supply_pool)
  end
  return entry, player, guns, inventory, refill
end
local entry, player, guns, inventory, refill = character(10)
refill(0)
assert_equal(inventory[1].valid_for_read, false)
assert_equal(inventory[2].count, 10) -- other occupied slots still top up
refill(600); assert_equal(inventory[1].valid_for_read, false)
refill(6000); assert_equal(inventory[1].valid_for_read, false) -- held indefinitely
player.cursor_stack = slot()
refill(6599); assert_equal(inventory[1].valid_for_read, false)
refill(6600); assert_equal(inventory[1].count, 10)
inventory[1] = slot(); refill(6601) -- normal consumption refills immediately
assert_equal(inventory[1].count, 10)

-- All empty slots share the delay; a new pickup extends it.
entry, player, guns, inventory, refill = character(2)
refill(2000)
player.cursor_stack = slot()
inventory[2] = slot()
refill(2119)
assert_equal(inventory[1].valid_for_read, false)
assert_equal(inventory[2].valid_for_read, false)
player.cursor_stack = slot('bullet', 10)
refill(2120)
player.cursor_stack = slot()
refill(2239); assert_equal(inventory[1].valid_for_read, false)
refill(2240)
assert_equal(inventory[1].count, 10)
assert_equal(inventory[2].count, 10)
-- Removing the gun keeps its slot empty after the delay.
inventory[1] = slot(); player.cursor_stack = slot('bullet', 10); refill(2300)
guns[1].valid_for_read = false
player.cursor_stack = slot()
refill(2500); assert_equal(inventory[1].valid_for_read, false)

entry, player, guns, inventory, refill = character(0)
refill(0); assert_equal(inventory[1].count, 10)
entry, player, guns, inventory, refill = character(10)
player.cursor_stack = slot('coal', 10)
refill(0); assert_equal(inventory[1].count, 10)
print('Player ammo regression checks passed')
