-- Real inventories and normal production tick/load handlers; no transfer mocks.
local AMMO = 'firearm-magazine'
local function check(condition, message)
  assert(condition, 'AUTO_LOADER_TEST FAIL: '..message)
end
local function create(surface, name, x, y, force)
  local entity = assert(surface.create_entity{name=name,position={x,y},force=force,raise_built=true})
  return entity
end
local function count(inventory, name, quality)
  return inventory.get_item_count{name=name or AMMO,quality=quality or 'normal'}
end
script.on_init(function()
  local other = game.create_force('supply-other')
  local absent = game.create_force('supply-absent')
  storage.pools = {}
  for s=1,2 do
    local surface = game.create_surface('supply-test-'..s, {width=64,height=64,
      autoplace_settings={entity={treat_missing_as_default=false},
      tile={treat_missing_as_default=false},decorative={treat_missing_as_default=false}}})
    surface.request_to_generate_chunks({0,0},1)
    surface.force_generate_chunk_requests()
    local tiles={}
    for x=-20,20 do for y=-20,20 do tiles[#tiles+1]={name='grass-1',position={x,y}} end end
    surface.set_tiles(tiles)
    for f,force in ipairs({game.forces.player,other}) do
      local chest = create(surface,'auto-loader-chest',-10,f*5,force)
      local linked = create(surface,'auto-loader-chest',-13,f*5,force)
      local supply = chest.get_inventory(defines.inventory.chest)
      local quality = f==1 and 'normal' or 'rare'
      local amount = s*2+f
      check(supply.insert{name=AMMO,quality=quality,count=amount}==amount,'stock pool')
      check(count(linked.get_inventory(defines.inventory.chest),AMMO,quality)==amount,'linked pool')
      -- Force rediscovery through the remaining representative after save/load.
      linked.destroy()
      local consumers={}
      for n=1,2 do
        local turret=create(surface,'gun-turret',n*4,f*5,force)
        consumers[n]=turret.get_inventory(defines.inventory.turret_ammo)
      end
      storage.pools[#storage.pools+1]={supply=supply,consumers=consumers,quality=quality,amount=amount}
    end
    local turret=create(surface,'gun-turret',10,-10,absent)
    storage.absent=turret.get_inventory(defines.inventory.turret_ammo)
  end

  local surface=game.surfaces['supply-test-1']
  local force=game.create_force('supply-rejection')
  local chest=create(surface,'auto-loader-chest',-10,-10,force)
  storage.rejected_supply=chest.get_inventory(defines.inventory.chest)
  check(storage.rejected_supply.insert{name=AMMO,count=150}==150,'stock partial/rejected supply')
  storage.rejected_supply.set_bar(1) -- refund insertion would be impossible
  local character=create(surface,'character',-5,-10,force)
  local guns=character.get_inventory(defines.inventory.character_guns)
  guns.clear(); check(guns[1].set_stack{name='pistol'},'equip pistol')
  storage.filtered=character.get_inventory(defines.inventory.character_ammo)
  storage.filtered.clear()
  check(storage.filtered.set_filter(1,{name='piercing-rounds-magazine',quality='normal'}),'filter ammo slot')
  -- A one-slot inventory with target 120 accepts only its 100-stack capacity.
  local partial=create(surface,'auto-loader-test-turret',0,-10,force)
  storage.partial=partial.get_inventory(defines.inventory.turret_ammo)
  check(#storage.partial==1,'partial fixture requires one ammo slot')

  local incompatible_force=game.create_force('supply-incompatible')
  chest=create(surface,'auto-loader-chest',-10,-16,incompatible_force)
  storage.incompatible_supply=chest.get_inventory(defines.inventory.chest)
  check(storage.incompatible_supply.insert{name='shotgun-shell',count=20}==20,'stock incompatible ammo')
  local rejected=create(surface,'gun-turret',0,-16,incompatible_force)
  storage.rejected=rejected.get_inventory(defines.inventory.turret_ammo)
end)
script.on_event(defines.events.on_tick,function()
  for _,pool in ipairs(storage.pools) do
    local total=count(pool.supply,AMMO,pool.quality)
    for _,inventory in ipairs(pool.consumers) do
      total=total+count(inventory,AMMO,pool.quality)
      check(count(inventory,AMMO,pool.quality=='rare' and 'normal' or 'rare')==0,'quality/force leak')
    end
    check(total==pool.amount,'surface/force conservation')
    check(count(pool.supply,AMMO,pool.quality)==0,'short supply fully distributed')
  end
  check(count(storage.absent)==0,'force without chest must stay empty')
  check(storage.filtered.is_empty(),'filtered character slot rejected supplied ammo')
  check(count(storage.partial)==100,'partial insertion must stop at stack capacity')
  check(count(storage.rejected_supply)==50,'debit actual accepted count only')
  check(storage.rejected.is_empty(),'incompatible turret must reject shotgun ammo')
  check(count(storage.incompatible_supply,'shotgun-shell')==20,'rejected supply unchanged')
  log('AUTO_LOADER_TEST SUCCESS surface/force isolation, linked chest replacement, quality, shortage, filtered/rejected and partial transfers')
end)
