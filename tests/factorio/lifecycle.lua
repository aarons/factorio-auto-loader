-- Real lifecycle operations with production event handlers and linked inventories.
local CHEST, AMMO = 'auto-loader-chest', 'firearm-magazine'
local function check(condition, message)
  assert(condition, 'AUTO_LOADER_TEST FAIL: '..message)
end
local function create(surface, name, x, force)
  return assert(surface.create_entity{name=name,position={x,0},force=force or 'player',raise_built=true})
end
local function stock(chest)
  local inventory=chest.force.get_linked_inventory(CHEST,chest.surface.index)
  check(inventory and inventory.valid,'direct linked inventory exists')
  inventory.clear()
  check(inventory.insert{name=AMMO,count=100}==100,'stock linked inventory')
  check(chest.get_inventory(defines.inventory.chest).get_item_count(AMMO)==100,'direct and entity inventories agree')
  return inventory
end
local function surface(name)
  local s=game.create_surface(name,{width=64,height=64,
    autoplace_settings={entity={treat_missing_as_default=false},tile={treat_missing_as_default=false},
      decorative={treat_missing_as_default=false}}})
  local tiles={}
  for x=-30,30 do for y=-10,10 do tiles[#tiles+1]={name='grass-1',position={x,y}} end end
  s.set_tiles(tiles)
  return s
end
local function count() return storage.ammo.get_item_count(AMMO) end
local function empty() storage.ammo.clear() end
script.on_init(function()
  storage.surface=surface('lifecycle')
  storage.turret=create(storage.surface,'gun-turret',0)
  storage.ammo=storage.turret.get_inventory(defines.inventory.turret_ammo)
  storage.step=0 -- save/load begins with no chests and a registered consumer
end)
script.on_event(defines.events.on_tick,function()
  storage.step=storage.step+1
  local step=storage.step
  if step==1 then
    check(count()==0,'no chest after save/load')
    storage.first=create(storage.surface,CHEST,5)
    stock(storage.first)
  elseif step==2 then
    check(count()==10,'first chest resumes preexisting consumer')
    empty()
    storage.second=assert(storage.first.clone{position={10,0}})
    check(storage.second.link_id==storage.surface.index,'individual clone linked')
    check(storage.second.get_inventory(defines.inventory.chest).get_item_count(AMMO)==90,'clone shares inventory')
    storage.first.destroy{raise_destroy=true}
  elseif step==3 then
    check(count()==10,'remaining clone supplies after one removal')
    empty()
    -- No immediate event: the destruction-registration backstop and reference
    -- validation must prevent even a single stale refill on the next tick.
    storage.second.destroy()
  elseif step==4 then
    check(count()==0,'last chest removal blocks next tick')
    storage.first=create(storage.surface,CHEST,5)
    stock(storage.first)
  elseif step==5 then
    check(count()==10,'rebuilding resumes supply')
    empty()
    storage.first.order_deconstruction('player')
  elseif step==6 then
    check(count()==10,'marked chest still supplies')
    empty()
    storage.first.cancel_deconstruction('player')
    storage.first.die()
  elseif step==7 then
    check(count()==0,'death stops supply')
    local force=game.create_force('lifecycle-source')
    storage.first=create(storage.surface,CHEST,5,force)
    stock(storage.first)
    game.merge_forces(force,'player')
  elseif step==8 then
    check(count()==10,'merged source chest rebucketed to destination')
    empty()
    storage.first.destroy{raise_destroy=true}
  elseif step==9 then
    check(count()==0,'merged chest removal uses updated reverse record')
    storage.first=create(storage.surface,CHEST,5)
    stock(storage.first).clear()
  elseif step==10 then
    check(count()==0,'empty chest has no supply')
    stock(storage.first) -- restocking raises no build event
  elseif step==11 then
    check(count()==10,'empty chest stays active for restocking')
    storage.surface.clear()
  elseif step==12 then
    storage.turret=create(storage.surface,'gun-turret',0)
    storage.ammo=storage.turret.get_inventory(defines.inventory.turret_ammo)
  elseif step==13 then
    check(count()==0,'cleared surface has no chest membership')
    storage.first=create(storage.surface,CHEST,5)
    stock(storage.first)
  elseif step==14 then
    check(count()==10,'cleared surface can be rebuilt')
    game.delete_surface(storage.surface)
  elseif step==15 then
    storage.surface=surface('lifecycle-replacement')
    storage.turret=create(storage.surface,'gun-turret',0)
    storage.ammo=storage.turret.get_inventory(defines.inventory.turret_ammo)
  elseif step==16 then
    check(count()==0,'deleted surface cannot authorize replacement surface')
    storage.first=create(storage.surface,CHEST,5)
    stock(storage.first)
  elseif step==17 then
    check(count()==10,'replacement surface supplies independently')
    local destination=surface('lifecycle-area-clone')
    empty()
    stock(storage.first)
    storage.surface.clone_area{source_area={{-2,-2},{7,2}},destination_area={{-2,-2},{7,2}},
      destination_surface=destination,clone_entities=true,clone_tiles=true,clone_decoratives=false,
      clear_destination_entities=false,clear_destination_decoratives=false,expand_map=true}
    storage.cloned=assert(destination.find_entities_filtered{name='gun-turret'}[1])
      .get_inventory(defines.inventory.turret_ammo)
    local chest=assert(destination.find_entities_filtered{name=CHEST}[1])
    check(chest.link_id==destination.index,'area cloned chest uses destination key')
    stock(chest)
  elseif step==18 then
    check(storage.cloned.get_item_count(AMMO)==10,'area cloned consumer registered without rescan')
    storage.dormant=surface('lifecycle-dormant')
    storage.car=create(storage.dormant,'car',0)
    storage.car_ammo=storage.car.get_inventory(defines.inventory.car_ammo)
    stock(storage.first)
  elseif step==19 then
    check(storage.car_ammo.is_empty(),'dormant mobile consumer stays empty')
    check(storage.car.teleport({20,0},storage.surface,true),'teleport into supplied surface')
  elseif step==20 then
    check(storage.car_ammo.get_item_count(AMMO)==10,'teleport event activates dormant consumer')
    storage.car_ammo.clear()
    check(storage.car.teleport({0,0},storage.dormant,true),'teleport out of supplied surface')
  elseif step==21 then
    check(storage.car_ammo.is_empty(),'teleport event removes active consumer')
    storage.mobile_chest=create(storage.dormant,CHEST,5)
    stock(storage.mobile_chest)
  elseif step==22 then
    check(storage.car_ammo.get_item_count(AMMO)==10,'first chest activates relocated consumer')
    storage.car_ammo.clear()
    storage.mobile_chest.destroy{raise_destroy=true}
  elseif step==23 then
    check(storage.car_ammo.is_empty(),'last chest deactivates relocated consumer')
    local force=game.create_force('lifecycle-consumer-source')
    storage.merge_car=create(storage.surface,'car',25,force)
    storage.merge_ammo=storage.merge_car.get_inventory(defines.inventory.car_ammo)
    game.merge_forces(force,'player')
  elseif step==24 then
    check(storage.merge_ammo.get_item_count(AMMO)==10,'force merge activates dormant consumer')
    log('AUTO_LOADER_TEST SUCCESS no-chest load, build, clones, removal, death, merge, restock, clear, delete and mobile routing')
  end
end)
