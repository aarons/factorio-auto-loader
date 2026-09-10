-- Run from the repository root: lua tests/supply.lua
-- Exercise production refill logic, including the real tick boundary.
defines = { inventory = { character_guns = 1, character_ammo = 2, chest = 3, turret_ammo = 4 }, events = {} }
script = { on_init = function() end, on_configuration_changed = function() end,
  on_load = function() end, on_event = function() end }
storage = { representative_chests = {} }
settings = { global = { ['auto-loader-entities-per-tick'] = {value=100} } }
prototypes = { item = {
  bullet = { stack_size = 100 }, piercing = { stack_size = 100 },
  shell = { stack_size = 100 }, coal = { stack_size = 50 },
  hybrid = { stack_size = 50 },
}, entity = {} }
local file = assert(io.open('control.lua'))
local source = file:read('*a'); file:close()
local supply_functions = assert(load(source .. [[
ITEM_AMMO.bullet, ITEM_AMMO.piercing, ITEM_AMMO.shell = 'bullet', 'bullet', 'shotgun'
ITEM_FUEL.coal = 'chemical'
ITEM_AMMO.hybrid, ITEM_FUEL.hybrid = 'bullet', 'chemical'
return { fill_inventory = fill_inventory, fill_slot = fill_slot, get_pool = get_pool,
  fill_character_ammo = fill_character_ammo, debit_pools = debit_pools, tick = on_tick,
  fill_entity = fill_entity, initialize = initialize }
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
    assert(item.count > 0 and item.count <= (stock[key] or 0), 'Supply overdraw')
    stock[key] = stock[key] - item.count
    return item.count
  end
  inventory.insert = function() error('Refills must never need refunds') end
  inventory.get_contents = function()
    inventory.reads = inventory.reads + 1
    local contents = {}
    for key, item_count in pairs(stock) do
      if item_count > 0 then
        local name, quality = key:match('(.+)/(.+)')
        contents[#contents + 1] = { name = name, quality = quality, count = item_count }
      end
    end
    table.sort(contents, function(a, b) return a.name..a.quality < b.name..b.quality end)
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
  local inventory = { item_stack, inserts = 0 }
  inventory.insert = function(item)
    inventory.inserts = inventory.inserts + 1
    if not item_stack.can_set_stack(item) then return 0 end
    if item_stack.valid_for_read and (item_stack.name ~= item.name or item_stack.quality.name ~= item.quality) then return 0 end
    local count = math.min(item.count, math.max(0, capacity-item_stack.count), insertion_limit or math.huge)
    if count > 0 then item_stack.set_stack{name=item.name, quality=item.quality, count=item_stack.count+count} end
    return count
  end
  return inventory
end
local forces = {{index=1}, {index=2}, {index=3}}
local chests = {}
game = {surfaces={}, tick=0, players={}}
for surface_index=1,2 do
  local surface = {index=surface_index, searches=0}
  chests[surface_index] = {}
  surface.find_entities_filtered = function(filter)
    surface.searches = surface.searches + 1
    local found = {}
    if filter.name then
      for _, chest in pairs(chests[surface_index]) do
        if chest.valid and (not filter.force or chest.force == filter.force) then found[#found+1] = chest end
      end
    end
    return found
  end
  game.surfaces[surface_index] = surface
end
local function add_chest(surface_index, force_index, stock)
  local inventory = supply(stock)
  local chest = {valid=true, name='auto-loader-chest', force=forces[force_index],
    surface=game.surfaces[surface_index], link_id=surface_index,
    get_inventory=function() return inventory end}
  chests[surface_index][force_index] = chest
  storage.representative_chests[surface_index] = storage.representative_chests[surface_index] or {}
  storage.representative_chests[surface_index][force_index] = chest
  return inventory, chest
end
local function entity(surface_index, force_index)
  return {valid=true, surface=game.surfaces[surface_index or 1], force=forces[force_index or 1],
    to_be_deconstructed=function() return false end}
end
local consumer = entity()
local function fill(pools, inventory, who)
  supply_functions.fill_inventory(inventory, 10, who or consumer, pools, 'ammos', ammo)
end
local function fill_slot(pools, item_stack, categories, target, kind, categories_by_item)
  supply_functions.fill_slot(item_stack, categories, target, consumer, pools, kind or 'ammos', categories_by_item or ammo)
end

-- Demand gating: full inventories and capped/incompatible slots do not even find a chest.
local stock = {['bullet/normal']=100}
local supply_inventory = add_chest(1,1,stock)
local pools = {}
fill(pools, destination(slot('bullet',10),100))
fill_slot(pools, slot('bullet',10), {bullet=true}, 10)
fill_slot(pools, slot('shell',1), {bullet=true}, 10)
assert_equal(next(pools), nil); assert_equal(supply_inventory.reads, 0)

-- One read and one debit for many consumers; no chest debit until tick end.
local total = 0
for _=1,12 do
  local item_stack = slot()
  fill(pools, destination(item_stack,100))
  total = total + item_stack.count
  assert_equal(stock['bullet/normal'], 100)
end
assert_equal(total,100); assert_equal(supply_inventory.reads,1); assert_equal(supply_inventory.removes,0)
supply_functions.debit_pools(pools)
assert_equal(stock['bullet/normal']+total,100); assert_equal(supply_inventory.removes,1)

-- An empty snapshot is shared, then newly stocked supply is visible next tick.
stock = {}; supply_inventory = add_chest(1,1,stock); pools = {}
for _=1,20 do fill(pools,destination(slot(),100)) end
assert_equal(supply_inventory.reads,1)
supply_functions.debit_pools(pools); assert_equal(supply_inventory.removes,0)
stock['piercing/normal']=20
local item_stack = slot(); pools = {}; fill(pools,destination(item_stack,100))
assert_equal(item_stack.name,'piercing'); assert_equal(item_stack.count,10)
supply_functions.debit_pools(pools); assert_equal(supply_inventory.reads,2); assert_equal(stock['piercing/normal'],10)

-- Short supply and existing identity preference are exact-quality, even when another sorts first.
stock = {['bullet/normal']=100, ['bullet/rare']=3}
supply_inventory = add_chest(1,1,stock); pools = {}; item_stack = slot('bullet',2,'rare')
fill(pools,destination(item_stack,100)); assert_equal(item_stack.count,5)
supply_functions.debit_pools(pools)
assert_equal(stock['bullet/rare']+item_stack.count,5); assert_equal(stock['bullet/normal'],100)

-- A later occupied stack still takes precedence over unoccupied alternatives.
stock={['bullet/normal']=10,['piercing/normal']=10}
supply_inventory=add_chest(1,1,stock); pools={}
local multi={slot('bullet',1,'rare'),slot('piercing',1),slot()}
multi.insert=function(item)
  for _,stack in ipairs(multi) do
    if stack.valid_for_read and stack.name==item.name and stack.quality.name==item.quality then
      stack.count=stack.count+item.count
      return item.count
    end
  end
  assert(multi[3].set_stack(item))
  return item.count
end
fill(pools,multi); supply_functions.debit_pools(pools)
assert_equal(multi[1].count,1); assert_equal(multi[2].count,9); assert_equal(multi[3].count,0)
assert_equal(stock['piercing/normal'],2); assert_equal(stock['bullet/normal'],10)

-- Rejected/partial insertion charges only the count accepted; barred supply needs no refund.
for _, limit in ipairs({0,2}) do
  stock = {['bullet/normal']=10}; supply_inventory = add_chest(1,1,stock); pools = {}
  item_stack = slot('bullet',1)
  local inventory = destination(item_stack,100,limit)
  fill(pools,inventory)
  assert_equal(inventory.inserts,1) -- no retry of a rejected existing identity
  assert_equal(item_stack.count,1+limit); assert_equal(stock['bullet/normal'],10)
  supply_functions.debit_pools(pools)
  assert_equal(stock['bullet/normal']+item_stack.count,11)
  assert_equal(supply_inventory.removes,limit>0 and 1 or 0)
end

-- A rejection must not hide that identity from later compatible consumers.
stock = {['bullet/normal']=10}; supply_inventory = add_chest(1,1,stock); pools = {}
fill(pools,destination(slot(),100,0))
item_stack = slot(); fill(pools,destination(item_stack,100))
supply_functions.debit_pools(pools); assert_equal(item_stack.count,10); assert_equal(stock['bullet/normal'],0)

-- Incompatible alternatives may be skipped in favor of an accepted identity.
stock = {['bullet/normal']=10, ['shell/rare']=20}; supply_inventory = add_chest(1,1,stock); pools = {}
item_stack = slot(nil,nil,nil,'shell'); fill(pools,destination(item_stack,100))
supply_functions.debit_pools(pools)
assert_equal(item_stack.name,'shell'); assert_equal(item_stack.quality.name,'rare')
assert_equal(stock['shell/rare'],10); assert_equal(stock['bullet/normal'],10)

-- Character filters and categories are slot-specific; failed set_stack never charges.
for _, failure in ipairs({'filter','placement','partial'}) do
  stock = {['shell/rare']=20}; supply_inventory = add_chest(1,1,stock); pools = {}
  item_stack = slot(nil,nil,nil,failure=='filter' and 'bullet' or nil)
  if failure=='placement' then item_stack.set_stack=function() return false end end
  if failure=='partial' then
    local set_stack = item_stack.set_stack
    item_stack.set_stack=function(item) item.count=3; return set_stack(item) end
  end
  fill_slot(pools,item_stack,{shotgun=true},10)
  local accepted = failure=='partial' and 3 or 0
  assert_equal(item_stack.count,accepted)
  supply_functions.debit_pools(pools)
  assert_equal(stock['shell/rare']+item_stack.count,20)
  assert_equal(supply_inventory.removes,accepted>0 and 1 or 0)
end

-- Occupied slot accounting also measures the count actually placed.
stock={['bullet/normal']=10}; supply_inventory=add_chest(1,1,stock); pools={}
item_stack=slot('bullet',1)
local actual_count=item_stack.count
item_stack.count=nil
setmetatable(item_stack, {
  __index=function(_,key) if key=='count' then return actual_count end end,
  __newindex=function(t,key,value)
    if key=='count' then actual_count=math.min(value,4) else rawset(t,key,value) end
  end,
})
fill_slot(pools,item_stack,{bullet=true},10)
supply_functions.debit_pools(pools)
assert_equal(item_stack.count,4); assert_equal(stock['bullet/normal'],7)

-- API quality objects normalize to the same identity as quality strings.
stock={['bullet/rare']=10}; supply_inventory=add_chest(1,1,stock); pools={}
local contents=supply_inventory.get_contents
supply_inventory.get_contents=function()
  local items=contents()
  for _,item in ipairs(items) do item.quality={name=item.quality} end
  return items
end
item_stack=slot('bullet',1,'rare'); fill(pools,destination(item_stack,100))
supply_functions.debit_pools(pools)
assert_equal(item_stack.count,10); assert_equal(stock['bullet/rare'],1)

-- Locomotives fill only slot 1 to its stack cap; occupied qualities cannot switch.
stock = {['coal/normal']=70, ['coal/rare']=2}; supply_inventory = add_chest(1,1,stock); pools = {}
local train = entity()
local train_inventory = {slot('coal',48,'rare'),slot(),slot()}
train.get_fuel_inventory=function() return train_inventory end
train.burner={fuel_categories={chemical=true}}
supply_functions.fill_entity({entity=train,fuel=true,is_locomotive=true},pools)
supply_functions.debit_pools(pools)
assert_equal(train_inventory[1].count,50); assert_equal(train_inventory[2].count,0); assert_equal(train_inventory[3].count,0)
assert_equal(stock['coal/rare'],0); assert_equal(stock['coal/normal'],70)
train_inventory[1]=slot(); pools={}
supply_functions.fill_entity({entity=train,fuel=true,is_locomotive=true},pools)
supply_functions.debit_pools(pools); assert_equal(train_inventory[1].count,50); assert_equal(stock['coal/normal'],20)

-- An item that is both fuel and ammo shares one balance, not two inventories.
stock={['hybrid/normal']=15}; supply_inventory=add_chest(1,1,stock); pools={}
local hybrid_ammo, hybrid_fuel=slot(),slot()
supply_functions.fill_inventory(destination(hybrid_ammo,100),10,consumer,pools,'ammos',{hybrid='bullet'})
supply_functions.fill_inventory(destination(hybrid_fuel,100),10,consumer,pools,'fuels',{hybrid='chemical'},{chemical=true})
supply_functions.debit_pools(pools)
assert_equal(hybrid_ammo.count+hybrid_fuel.count,15); assert_equal(stock['hybrid/normal'],0); assert_equal(supply_inventory.removes,1)

-- Real on_tick debits independently across two surfaces and two forces.
storage.order, storage.fillables, storage.cursor = {}, {}, 1
local inventories, stocks, stacks = {}, {}, {}
for surface_index=1,2 do
  for force_index=1,2 do
    local i=#stocks+1
    stocks[i]={['bullet/normal']=i}
    inventories[i]=add_chest(surface_index,force_index,stocks[i])
    stacks[i]=slot()
    local inventory=destination(stacks[i],100)
    local who=entity(surface_index,force_index)
    who.get_inventory=function() return inventory end
    storage.order[i]=i
    storage.fillables[i]={entity=who,ammo_define=4,ammo_target=10}
  end
end
supply_functions.tick()
for i=1,4 do
  assert_equal(stacks[i].count,i); assert_equal(stocks[i]['bullet/normal'],0)
  assert_equal(inventories[i].reads,1); assert_equal(inventories[i].removes,1)
end
-- Current entity force/surface selects the pool, even after registration.
stocks[4]['bullet/normal']=10
storage.fillables[1].entity.force=forces[2]
storage.fillables[1].entity.surface=game.surfaces[2]
supply_functions.tick()
assert_equal(stacks[1].count,10); assert_equal(stocks[4]['bullet/normal'],0)
assert_equal(stacks[4].count,5)

-- Missing chests are searched once per tick, without borrowing another force's pool.
pools={}; local absent=entity(1,3); local before=game.surfaces[1].searches
for _=1,10 do fill(pools,destination(slot(),100),absent) end
assert_equal(game.surfaces[1].searches,before+1)
fill({},destination(slot(),100),absent)
assert_equal(game.surfaces[1].searches,before+2)
-- Mined/moved/force-changed representatives are rediscovered and relinked.
local _, stale=add_chest(1,1,{})
stale.force=forces[2]
chests[1][1]=nil
assert_equal(supply_functions.get_pool(1,forces[1],{}),nil)
local replacement=supply({['bullet/normal']=10})
chests[1][1]={valid=true,name='auto-loader-chest',surface=game.surfaces[1],force=forces[1],link_id=99,
  get_inventory=function() return replacement end}
assert_equal(supply_functions.get_pool(1,forces[1],{}).inventory,replacement)
assert_equal(chests[1][1].link_id,1)
chests[1][1].valid=false
assert_equal(supply_functions.get_pool(1,forces[1],{}),nil)

-- Deconstruction skips all demand, even for otherwise empty inventories.
local skipped=entity(); skipped.to_be_deconstructed=function() return true end
skipped.get_inventory=function() error('Deconstructed consumer inspected') end
supply_functions.fill_entity({entity=skipped,ammo_define=4}, {})
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
  local entity = {player=player, unit_number=123, surface=game.surfaces[1],
    force=forces[1],
    get_requester_point=function() error('Logistics must not be consulted') end,
    get_inventory=function(id) return id == defines.inventory.character_guns and guns or inventory end,
  }
  player.character = entity
  local entry = {ammo_define=defines.inventory.character_ammo, ammo_target=10}
  local stock = {['bullet/normal']=100}
  local chest = add_chest(1, 1, stock)
  local function refill(tick)
    game.tick = tick
    local pools = {}
    supply_functions.fill_character_ammo(entry, entity, pools)
    supply_functions.debit_pools(pools)
  end
  return entry, player, guns, inventory, refill, chest
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

-- No ledger is built for delayed empty slots or slots without guns.
local supply_inventory
entry, player, guns, inventory, refill, supply_inventory = character(10)
inventory[2]=slot()
refill(0)
assert_equal(supply_inventory.reads,0)
player.cursor_stack=slot()
guns[1].valid_for_read=false; guns[2].valid_for_read=false
refill(1000)
assert_equal(supply_inventory.reads,0)

-- Upgrade initialization drops stale persistent supply identities but retains
-- registry/cursor and player delay state; on_load remains prototype-only.
local order, fillables = storage.order, storage.fillables
fillables[1].ammo_refill_after=9000
storage.supply_candidates={stale=true}
supply_functions.initialize()
assert_equal(storage.supply_candidates,nil)
assert_equal(storage.order,order); assert_equal(storage.fillables,fillables)
assert_equal(fillables[1].ammo_refill_after,9000)
print('Demand gating and upgrade checks passed')
