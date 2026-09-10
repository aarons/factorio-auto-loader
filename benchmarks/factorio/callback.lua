local config = require('config')
local fixture = require('fixture')
local engines = {old=require('old'),new=require('new')}
script.on_init(function()
  local state = fixture.create(false)
  for sample=1,config.samples do
    -- Reverse budgets/scenarios as well as version order between sample pairs.
    for bi=1,#config.budgets do
      local budget = config.budgets[sample%2==1 and bi or #config.budgets-bi+1]
      for si=1,#config.scenarios do
        local scenario = config.scenarios[sample%2==1 and si or #config.scenarios-si+1]
        for _,version in ipairs(sample%2==1 and {'old','new'} or {'new','old'}) do
          local engine = engines[version]
          engine.setup(state.entities,state.chests,budget)
          local function sweep()
            for _=1,config.entities/budget do engine.tick() end
          end
          fixture.supply(state,'empty')
          fixture.reset(state,'empty')
          sweep() -- Warm every entity and pool; deliberately warm shortage caches.
          fixture.validate(state,'empty')
          for iteration=1,config.iterations do
            fixture.supply(state,scenario)
            fixture.reset(state,scenario)
            local timer = helpers.create_profiler()
            sweep()
            timer.stop()
            local transferred = fixture.validate(state,scenario)
            log({'','BENCH ',sample,' ',budget,' ',scenario,' ',version,' ',iteration,
              ' ',transferred,' ',timer})
          end
        end
      end
    end
  end
  log('BENCH SUCCESS')
end)
