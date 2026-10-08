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
    log('AUTO_LOADER_TEST SUCCESS no-chest load, build, entity/area clone, removal, death, merge, restock, clear and delete')
  end
end)
