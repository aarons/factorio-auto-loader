-- Companion mod, with the exact production mod running normal event handlers.
local config = require('config')
local fixture = require('fixture')
script.on_init(function()
  if remote.interfaces.freeplay then
    remote.call('freeplay','set_skip_intro',true)
    remote.call('freeplay','set_disable_crashsite',true)
  end
  assert(settings.global['auto-loader-entities-per-tick'].value==config.budget)
  storage.state = fixture.create(true)
  storage.schedule = {}
  for i=1,config.entities do
    if config.scenario~='mixed_supply' or not config.supplied_queue or storage.state.supplied[i] then
      storage.schedule[#storage.schedule+1]=i
    end
  end
  storage.cursor = 1
  storage.sweeps = 0
  storage.updates = 0
  fixture.supply(storage.state,config.scenario)
  if config.scenario~='player_no_chest' then fixture.reset(storage.state,config.scenario) end
end)

script.on_event(defines.events.on_player_created,function(event)
  if config.scenario~='player_no_chest' then return end
  local player=game.get_player(event.player_index)
  local character=assert(player.character)
  character.teleport({0,0},storage.state.surfaces[1])
  local guns=character.get_inventory(defines.inventory.character_guns)
  guns.clear(); assert(guns[1].set_stack{name='pistol'})
  storage.state.entities[1]=character
  storage.state.inventories[1]=character.get_inventory(defines.inventory.character_ammo)
  fixture.reset(storage.state,config.scenario)
  game.auto_save('benchmark-player')
end)

-- Dependency order puts this after the production mod's on_tick. Check and
-- reset only the visited batch, avoiding a 10,000-inventory reset every frame.
script.on_event(defines.events.on_tick,function()
  local state = storage.state
  if config.scenario=="player_no_chest" and not state.entities[1] then return end
  local schedule = storage.schedule
  local visits = math.min(config.budget,#schedule)
  local visited = {}
  local charged = {}
  for offset=0,visits-1 do
    local i=schedule[(storage.cursor+offset-1)%#schedule+1]
    visited[#visited+1]=i
    local name = i%2==1 and 'firearm-magazine' or 'coal'
    local count = state.inventories[i].get_item_count(name)
    local expected = state.supplied[i] and config.scenario~='no_supply' and 10 or fixture.initial(config.scenario,i)
    assert(count==expected, 'PRODUCTION wrong count for entity '..i..': '..count)
    local pool = math.floor((i-1)/(config.entities/10))+1
    if state.supplied[i] then
      charged[pool] = charged[pool] or {['firearm-magazine']=0,coal=0}
      charged[pool][name] = charged[pool][name]+expected-fixture.initial(config.scenario,i)
    end
  end
  for pool,items in pairs(charged) do
    for name,count in pairs(items) do
      local inventory = state.supplies[pool]
      local expected = config.scenario=='no_supply' and 0 or config.entities/20*10
      assert(inventory.get_item_count(name)==expected-count, 'PRODUCTION supply conservation failed')
      if count>0 then assert(inventory.insert{name=name,count=count}==count) end
    end
  end
  for _,i in ipairs(visited) do fixture.reset(state,config.scenario,i,i) end
  -- Equal extra validation in both variants, including all dormant consumers
  -- over ten ticks. This is outside Auto-Loader but inside scriptUpdate.
  if config.scenario=='mixed_supply' then
    local first=(storage.updates%10)*(config.entities/10)+1
    for i=first,first+config.entities/10-1 do
      if not state.supplied[i] then
        assert(state.inventories[i].get_item_count(i%2==1 and 'firearm-magazine' or 'coal')==9,
          'PRODUCTION dormant consumer changed')
      end
    end
  end
  storage.sweeps = storage.sweeps + math.floor((storage.cursor-1+visits)/#schedule)
  storage.cursor = (storage.cursor+visits-1)%#schedule+1
  storage.updates = storage.updates+1
  if storage.updates==config.actual_ticks then
    log('PRODUCTION SUCCESS sweeps='..storage.sweeps..' entities='..config.entities)
  end
end)
