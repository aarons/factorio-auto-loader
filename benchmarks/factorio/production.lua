-- Companion mod, with the exact production mod running normal event handlers.
local config = require('config')
local fixture = require('fixture')
script.on_init(function()
  assert(settings.global['auto-loader-entities-per-tick'].value==config.budget)
  storage.state = fixture.create(true)
  storage.cursor = 1
  storage.sweeps = 0
  storage.updates = 0
  fixture.supply(storage.state,config.scenario)
  fixture.reset(storage.state,config.scenario)
end)

-- Dependency order puts this after the production mod's on_tick. Check and
-- reset only the visited batch, avoiding a 10,000-inventory reset every frame.
script.on_event(defines.events.on_tick,function()
  local state = storage.state
  local first,last = storage.cursor,storage.cursor+config.budget-1
  local charged = {}
  for i=first,last do
    local name = i%2==1 and 'firearm-magazine' or 'coal'
    local count = state.inventories[i].get_item_count(name)
    assert(count==10, 'PRODUCTION wrong count for entity '..i..': '..count)
    local pool = math.floor((i-1)/(config.entities/10))+1
    charged[pool] = charged[pool] or {['firearm-magazine']=0,coal=0}
    charged[pool][name] = charged[pool][name]+10-fixture.initial(config.scenario,i)
  end
  for pool,items in pairs(charged) do
    for name,count in pairs(items) do
      local inventory = state.supplies[pool]
      local expected = config.entities/20*10
      assert(inventory.get_item_count(name)==expected-count, 'PRODUCTION supply conservation failed')
      assert(inventory.insert{name=name,count=count}==count)
    end
  end
  fixture.reset(state,config.scenario,first,last)
  storage.cursor = last==config.entities and 1 or last+1
  if storage.cursor==1 then storage.sweeps=storage.sweeps+1 end
  storage.updates = storage.updates+1
  if storage.updates==config.actual_ticks then
    log('PRODUCTION SUCCESS sweeps='..storage.sweeps..' entities='..config.entities)
  end
end)
