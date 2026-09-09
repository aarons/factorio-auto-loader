local AMMO = 'firearm-magazine'
local PREFIX = 'AUTO_LOADER_TEST '

local function check(condition, message)
  assert(condition, PREFIX .. 'FAIL: ' .. message)
end

script.on_init(function()
  if remote.interfaces.freeplay then
    remote.call('freeplay', 'set_skip_intro', true)
    remote.call('freeplay', 'set_disable_crashsite', true)
  end
end)

script.on_event(defines.events.on_player_created, function(event)
  local player = game.get_player(event.player_index)
  local surface = game.create_surface('ammo-test', {
    width=64, height=64, autoplace_settings={
      entity={treat_missing_as_default=false},
      tile={treat_missing_as_default=false},
      decorative={treat_missing_as_default=false},
    },
  })
  surface.request_to_generate_chunks({0,0}, 1)
  surface.force_generate_chunk_requests()
  local tiles = {}
  for x=-16,16 do
    for y=-16,16 do tiles[#tiles+1] = {name='grass-1', position={x,y}} end
  end
  surface.set_tiles(tiles)
  local old_character = player.character
  player.character = nil
  if old_character then old_character.destroy() end
  check(player.teleport({0,0}, surface), 'move player to test surface')
  local character = assert(surface.create_entity{
    name='character', position={0,0}, force=player.force, raise_built=true,
  })
  player.character = character
  check(character.player == player, 'character must belong to the test player')
  check(player.mod_settings['auto-loader-player-ammo-refill-delay'].value == 1,
    'fixture must use a one-second refill delay')
  local chest = assert(surface.create_entity{
    name='auto-loader-chest', position={4,0}, force=player.force, raise_built=true,
  })
  local supply = chest.get_inventory(defines.inventory.chest)
  check(supply.insert{name=AMMO, count=100} == 100, 'stock supply chest')
  local guns = character.get_inventory(defines.inventory.character_guns)
  local ammo = character.get_inventory(defines.inventory.character_ammo)
  guns.clear()
  ammo.clear()
  player.cursor_stack.clear()
  check(guns[1].set_stack{name='pistol'}, 'equip pistol in first gun slot')
  storage.fixture = {player=player, supply=supply, guns=guns, ammo=ammo,
    start=game.tick, phase='initial'}
  log(PREFIX .. 'fixture ready')
end)

script.on_event(defines.events.on_tick, function()
  local f = storage.fixture
  if not f or f.phase == 'done' then return end
  local slot = f.ammo[1]
  local cursor = f.player.cursor_stack
  local elapsed = game.tick - f.start
  for i=2,#f.ammo do check(not f.ammo[i].valid_for_read, 'unarmed slot must remain empty') end

  if f.phase == 'initial' then
    if not slot.valid_for_read then
      check(elapsed < 10, 'initial ammo refill timed out')
      return
    end
    check(slot.name == AMMO and slot.count == 10, 'first slot should receive ten magazines')
    check(f.supply.get_item_count(AMMO) == 90, 'initial refill should consume supply')
    check(cursor.transfer_stack(slot), 'move ammo from slot to player hand')
    check(not slot.valid_for_read and cursor.count == 10, 'ammo must be held in hand')
    f.start, f.phase = game.tick, 'holding'
    log(PREFIX .. 'PASS initial refill')
  elseif f.phase == 'holding' then
    check(not slot.valid_for_read, 'ammo refilled while held in hand')
    check(f.supply.get_item_count(AMMO) == 90, 'supply changed while holding ammo')
    if elapsed >= 120 then
      check(f.player.get_main_inventory().insert(cursor) == cursor.count, 'put held ammo away')
      cursor.clear()
      f.start, f.phase = game.tick, 'waiting'
      log(PREFIX .. 'PASS held ammo blocks refill beyond delay')
    end
  elseif f.phase == 'waiting' then
    if elapsed < 60 then
      check(not slot.valid_for_read, 'ammo refilled before the one-second delay')
    else
      check(slot.valid_for_read and slot.name == AMMO and slot.count == 10,
        'ammo must refill after one second')
      check(f.supply.get_item_count(AMMO) == 80, 'delayed refill should consume supply')
      check(cursor.transfer_stack(slot), 'remove ammo again')
      f.start, f.phase = game.tick, 'remove-gun'
      log(PREFIX .. 'PASS refill after hand emptied and delay elapsed')
    end
  elseif f.phase == 'remove-gun' then
    check(not slot.valid_for_read, 'ammo must remain empty before removing gun')
    check(f.player.get_main_inventory().insert(f.guns[1]) == 1, 'put gun away')
    f.guns[1].clear()
    check(f.player.get_main_inventory().insert(cursor) == cursor.count, 'put ammo away')
    cursor.clear()
    f.start, f.phase = game.tick, 'unarmed'
  elseif f.phase == 'unarmed' then
    check(not slot.valid_for_read, 'ammo refilled after gun removal')
    check(f.supply.get_item_count(AMMO) == 80, 'unarmed character consumed supply')
    if elapsed >= 120 then
      f.phase = 'done'
      log(PREFIX .. 'PASS gun removal leaves ammo slot empty')
      log(PREFIX .. 'SUCCESS')
    end
  end
end)
