-- Shared real-entity fixture. All inventory mutation is outside callback timers.
local M = {}
local config = require('config')

function M.create(raise_built)
  local surface = game.surfaces[1]
  local tiles = {}
  for x=-8,404 do
    for y=-8,math.ceil(config.entities/1000)*4+4 do tiles[#tiles+1] = {name='grass-1', position={x,y}} end
  end
  surface.set_tiles(tiles)
  local state = {entities={}, inventories={}, chests={}, supplies={}}
  for i=1,10 do
    -- One force per surface keeps both versions' pool semantics equivalent.
    local s = i==1 and surface or game.create_surface('bench-'..i, {width=416,height=416,
      autoplace_settings={entity={treat_missing_as_default=false},
        tile={treat_missing_as_default=false},decorative={treat_missing_as_default=false}}})
    s.set_tiles(tiles)
    state.chests[i] = assert(s.create_entity{
      name='auto-loader-chest', position={4,-4}, force='player', raise_built=raise_built,
    })
    state.chests[i].link_id = s.index
    state.supplies[i] = state.chests[i].get_inventory(defines.inventory.chest)
    assert(#state.supplies[i] == 48, 'Expected default 48-slot chest')
  end
  for i=1,config.entities do
    local pool = math.floor((i-1)/(config.entities/10))+1
    local j = (i-1)%(config.entities/10)
    local is_ammo = i%2==1
    local entity = assert(state.chests[pool].surface.create_entity{
      name=is_ammo and 'gun-turret' or 'stone-furnace', force='player',
      position={(j%100)*4,math.floor(j/100)*4}, raise_built=raise_built,
    })
    -- No enemies or smelting ingredients: consumption is controlled by resets.
    state.entities[i] = entity
    state.inventories[i] = is_ammo and entity.get_inventory(defines.inventory.turret_ammo)
      or entity.get_fuel_inventory()
  end
  assert(state.entities[1].prototype.automated_ammo_count == 10)
  return state
end

function M.initial(scenario, i)
  if scenario=='full' then return 10 end
  if scenario=='active_10pct' then return (math.floor((i-1)/2)%10==0) and 9 or 10 end
  if scenario=='mixed_half' then
    return ({0,5,9,10})[math.floor((i-1)/2)%4+1]
  end
  if scenario=='half' then return 5 end
  if scenario=='empty' then return 0 end
  return 9
end

function M.supply(state, scenario)
  for _,inv in ipairs(state.supplies) do
    inv.clear()
    if scenario~='no_supply' then
      local count = scenario=='depleted' and config.entities/40 or config.entities/20*10
      assert(inv.insert{name='firearm-magazine',count=count} == count)
      assert(inv.insert{name='coal',count=count} == count)
    end
    if scenario=='dense' then
      local names = {}
      for name,p in pairs(prototypes.item) do
        if p.type=='item' and p.fuel_value==0 and p.stack_size>0 then names[#names+1]=name end
      end
      table.sort(names)
      for i=1,30 do assert(inv.insert{name=names[i],count=1} == 1) end
    else
      assert(inv.insert{name='iron-plate',count=100} == 100)
    end
  end
end

function M.reset(state, scenario, first, last)
  for i=first or 1,last or config.entities do
    local inv = state.inventories[i]
    inv.clear()
    local count = M.initial(scenario,i)
    if count>0 then assert(inv.insert{name=i%2==1 and 'firearm-magazine' or 'coal',count=count}==count) end
  end
end

function M.validate(state, scenario)
  local transferred = {0,0}
  for i,inv in ipairs(state.inventories) do
    local kind = i%2==1 and 1 or 2
    local count = inv.get_item_count(kind==1 and 'firearm-magazine' or 'coal')
    local expected = scenario=='no_supply' and 9 or 10
    if scenario=='depleted' then
      local offset = (i-1)%(config.entities/10)
      expected = offset<config.entities/20 and 10 or 9
    end
    assert(count==expected, scenario..' entity '..i..': expected '..expected..', got '..count)
    transferred[kind] = transferred[kind]+count-M.initial(scenario,i)
  end
  for kind,name in ipairs({'firearm-magazine','coal'}) do
    local remaining = 0
    for _,inv in ipairs(state.supplies) do remaining=remaining+inv.get_item_count(name) end
    local before = scenario=='no_supply' and 0 or
      (scenario=='depleted' and config.entities/4 or config.entities*5)
    assert(remaining+transferred[kind]==before, scenario..': conservation failed for '..name)
  end
  return transferred[1]+transferred[2]
end
return M
