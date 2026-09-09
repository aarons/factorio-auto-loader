# Automated validation

Use Factorio's API and command-line executable to test the mod with real entities and inventories, building on the [benchmarking guide](../documentation/BENCHMARKING.md). The checklist below collects test ideas for refill behavior, lifecycle changes, and performance; implementation details can be decided as each test is added.

Good to always validate (have automated tests for):
- [ ] Handle limited supply and partial refills without losing or duplicating items.

Evaluate if we need tests for (do not implement these yet):
- [ ] Use the correct supply after a consumer changes surface or force.
- [ ] Fill only the first locomotive fuel slot according to its special refill rule.
- [ ] Refill character ammo slots independently according to their paired guns.
- [ ] Respect character logistics requests, research, and paused logistics.
- [ ] Pause refilling for deconstruction and resume when it is cancelled.
- [ ] Register consumers built by players, robots, scripts, and space platforms, including revived entities.
- [ ] Handle cloned entities and imported surfaces without duplicate registration.
- [ ] Register new and respawned player characters.
- [ ] Keep serving surviving consumers after entities are destroyed or surfaces deleted.
- [ ] Serve all eligible consumers across ticks and respond to processing-budget changes.
- [ ] Preserve refill behavior across save and reload.
- [ ] Preserve inventories and update consumer behavior across mod upgrades and configuration changes.
- [ ] Load and operate with different chest settings, recipe choices, and layered source icons.
- [ ] Measure refill cost and delay as factory size, demand, and processing budget change.
- [ ] Measure performance with missing supply, varied items and qualities, and multiple supply pools.
- [ ] Check recovery and performance during large construction and destruction bursts.
- [ ] Sustain refilling in a running factory with actual ammo and fuel consumption.
