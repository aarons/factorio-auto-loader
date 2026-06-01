# Event-light refill engine (Tier 0–2)

Build the "fill" half of the Auto-Loader: a runtime engine that distributes the
per-surface pooled supply into turrets (ammo) and burners (fuel). Do it without
iterating every entity every tick, using three layered techniques:

- **Tier 0** — a bounded round-robin sweep (process K registered entities per
  tick, hard latency bound, constant per-tick cost).
- **Tier 1** — a cheap `entity.status` gate before any inventory work.
- **Tier 2** — deadline scheduling for fuel burners: compute when a burner will
  run dry from its fuel value and burn rate, and don't revisit it until then.

**Tier 3 (turret hot/cold sets driven by `on_entity_damaged`) is explicitly
deferred** — it is hard to troubleshoot and get right, and Tier 0+1 already make
the turret case cheap. Leave hooks where Tier 3 would slot in, but do not build
it here.

## Context

### What this mod is

Auto-Loader adds a single special chest (`auto-loader-chest`). The **supply
half** is already built and shipping (v3.x):

- `data.lua` defines the chest as a derivative of the vanilla `linked-chest`
  (prototype type `linked-container`), tinted blue, 20 slots, 10× stack
  multiplier.
- `control.lua` sets every chest's `link_id` to its `surface.index` on build /
  clone / surface-import. Linked-container inventories are keyed by
  `(prototype name, force, link_id)`, so **every Auto-Loader chest on a surface
  shares one pooled inventory**, and `surface.index` as the key never collides
  with other mods.

The player stocks fuel and ammo into this pooled chest. **Nothing distributes
that supply into turrets/burners yet** — that is this plan.

The intended player experience: any turret or fuel-burner on the same surface as
a stocked Auto-Loader chest stays topped up automatically, with no logistics
range or wiring — supply is surface-global. (No spatial/range logic is needed;
that is a deliberate design simplification baked into the supply half.)

### Why event-light polling, and not events or alerts (already-settled research)

We researched whether this could be event-driven. Conclusions, treat as settled:

1. **There is no event for ammo or fuel consumption**, and **no
   inventory-changed event for non-player entities**. Ammo only decreases when a
   turret fires; fuel only when a burner works; neither raises anything.
2. **Alerts are poll-only** (no `on_alert_raised`) and **`LuaPlayer::get_alerts`
   requires a connected player** — it returns nothing on a dedicated server with
   no players on the relevant force. So alerts are unreliable as a primary
   trigger and are **not used** in this plan. (`get_alerts` is on `LuaPlayer`,
   not `LuaForce` — note for anyone tempted to revisit it.)
3. Therefore: **maintain our own registry of fillable entities** (built from the
   entity-creation events the chest already listens to, plus destruction
   tracking) and **poll it cheaply**.

### The insight that shapes the design

The two things we fill have opposite consumption profiles, and we exploit that:

- **Fuel** is slow, continuous, and **predictable** → we can *schedule* the next
  check (Tier 2).
- **Ammo** is bursty, rare, and unpredictable (most turrets fire nothing almost
  all the time) → we cannot schedule it; we fall back to the bounded sweep
  (Tier 0) gated by status (Tier 1). Proactive combat-aware topping is Tier 3,
  deferred.

## Implementation Notes

An engineer should read the `factorio-modding` skill before starting; the points
below are the ones specific to this task.

### Accessing the pooled supply inventory

The pool is a linked-container inventory shared by `link_id == surface.index`. To
read/withdraw for surface S you need a `LuaInventory` handle to that pool:

- Keep **one representative chest `LuaEntity` per surface** in storage (the first
  one built/seen on the surface). Get the pool via
  `chest.get_inventory(defines.inventory.chest)` — **verify this is the correct
  inventory index for `linked-container` in-game**; confirm before relying on it.
- Representative chests can be mined/destroyed. On removal of the representative,
  promote another chest on that surface (find one via
  `surface.find_entities_filtered{ name = "auto-loader-chest" }`), or lazily
  re-find on next use and cache. If a surface has **zero** chests, that surface
  has no supply — skip all fills there.
- Withdraw with `inventory.remove{name=, count=, quality=}` and insert the same
  stack into the target; or move stacks directly. Respect quality (see below).

### The fillable registry

Extend the existing build-event wiring (`control.lua` `BUILD_EVENTS` +
`on_entity_cloned`). For every built entity (not just the chest), classify and,
if fillable, register it:

- **Ammo set**: entity has an ammo inventory. Item-ammo turret types only —
  `ammo-turret`, `artillery-turret`, plus vehicles `car`, `spider-vehicle`, and
  `artillery-wagon`. **Exclude** `electric-turret` (uses power) and
  `fluid-turret` (uses fluid, not item ammo).
- **Fuel set**: `entity.burner ~= nil` (equivalently
  `entity.get_fuel_inventory() ~= nil`). Burner-ness is a property of the
  prototype's `energy_source`, **not** the entity type — test the entity, do not
  hardcode a type list. Common members: burner mining drills, boilers, burner
  inserters, stone/steel furnaces, reactors, burner generators, locomotives;
  `car`/`spider-vehicle` can be in **both** sets.
- There is **no built-entity filter** for "has a burner" or "has ammo." The
  filterable categories are `turret`, `vehicle`, `type`, `name`, etc. Pre-narrow
  with `turret`/`vehicle`/`type` filters to cut event volume, then confirm in the
  handler with `entity.burner` / the ammo-inventory lookup.
- **Removal**: `script.register_on_object_destroyed(entity)` at registration;
  store `{unit_number, kind, surface_index}` keyed by the registration number;
  drop from the registry in `on_object_destroyed`. Mirror the README's
  "remove from processing queue" event list where relevant
  (mined/deconstructed), but `on_object_destroyed` is the reliable backstop.
- **Initial scan**: in `on_init`/`on_configuration_changed`, scan all surfaces
  for existing fillable entities (the chest already does this for chests).
- Pre-classify at registration into ammo-set / fuel-set so the sweep never
  re-derives type each tick.

### Ammo inventory defines vary by type

There is no universal ammo-inventory constant. Build a `type → inventory define`
map at init: `ammo-turret`/`artillery-turret` → `defines.inventory.turret_ammo`,
`car` → `car_ammo`, `spider-vehicle` → `spider_ammo`, artillery wagon →
its artillery ammo define. **Verify the exact define names in-game** (especially
artillery). `get_fuel_inventory()` is generic and needs no map.

### Tier 1: the status gate

`entity.status :: defines.entity_status?` is a cheap C-side enum read. Gate
expensive inventory work on it:

- Fuel: only inspect/insert when `status == defines.entity_status.no_fuel`.
- Ammo: only when `status == defines.entity_status.no_ammo`.
- `status` can be `nil` — nil-guard.

Caveat to document: status only flips at **fully empty**, so a status-gated fill
is reactive (the entity stalls for up to one sweep cycle before refill). That is
acceptable for fuel here; for ammo it is the deferred Tier 3's job to do better.

### Tier 2: deadline scheduling for fuel

When a burner is topped up, compute a conservative lower bound on ticks-until-dry
and schedule the next visit then, instead of sweeping it every cycle:

- Fuel energy available ≈ Σ over fuel stacks of `count × item_prototype.fuel_value`
  (joules). Read `fuel_value` from the item prototype.
- Burn rate ≈ the prototype's energy consumption per tick (e.g.
  `entity.prototype.max_energy_usage`, in J/tick; confirm the right field per
  type). `ticks_until_dry ≈ available_joules / burn_rate_per_tick`.
- This is a **lower bound**: variable-rate burners (a drill with no ore, an idle
  burner inserter) burn *slower* or not at all, so they last *longer*. Revisit at
  the deadline; if still fueled, recompute a new (later) deadline. Never empties
  before the deadline → safe.
- Structure: a min-heap keyed by deadline tick, or a bucketed timer wheel
  (array of tick-buckets). Each tick, pop everything due now and process only
  that. A coal-full drill won't be revisited for thousands of ticks.
- Fall back to the Tier 0 sweep for any burner you cannot compute a rate for
  (unknown energy source, zero/penalty rate) so nothing is silently dropped.

### Quality

The mod's selling point includes quality ammo/fuel. When filling, match what the
entity accepts: insert ammo of the correct ammo category, fuel of a category the
burner accepts (`burner.fuel_categories` / prototype). Decide and document a
quality policy (e.g. any available quality, or prefer-highest) — keep it simple
for v1; just don't insert items the entity rejects.

### Storage, lifecycle, save/load

- `storage` schema: the registry (ammo-set, fuel-set), the sweep cursor, the
  fuel deadline structure, and the per-surface representative-chest map. Use the
  `factorio-modding` nil-slot compaction pattern for the sweep arrays.
- `on_init` / `on_configuration_changed`: (re)build registry + scan surfaces +
  (re)register `on_nth_tick`.
- `on_load`: **read-only** — re-establish locals and re-register the dynamic
  `on_nth_tick`/cursor handlers from `storage`. Never write `storage` here, never
  call `game.*`.
- **Migrations**: adding the storage schema to existing saves needs a migration
  (or be fully tolerant of missing tables in `on_configuration_changed`).
  ⚠️ **`install.sh` currently does NOT copy the `migrations/` folder into the
  packaged zip** (it copies only `control.lua data.lua settings.lua info.json
  locale`). If this plan ships a migration, **update `install.sh` to include
  `migrations/`**, or the migration won't ship.

### Performance discipline

- Drive the sweep from `on_nth_tick` (or `on_tick` with a cursor). Make **K
  (entities per tick)** a `runtime-global` setting with sane min/max.
- Keep the hot path allocation-free; capture `unit_number`/`name`/`type` into
  locals; check `entity.valid` before each post-first API call (entities can be
  invalidated mid-handler by other mods).
- **Instrument it**: log (debug-gated) the registry sizes, needy-fraction per
  sweep, and rough per-sweep cost, so we can tell whether Tier 3 is ever needed.

## Suggested Approach

Phase the work so the cheap baseline lands and is measured before the scheduler:

1. **Registry + supply access (foundation).** Build the fillable registry from
   build/clone/destroy events + initial scan; classify ammo/fuel/both; track a
   representative chest per surface; implement withdraw-from-pool +
   insert-into-entity with quality handling. No sweeping logic yet — a temporary
   debug command that fills one entity proves the plumbing.
2. **Tier 0 + Tier 1 (bounded status-gated sweep).** Round-robin cursor over the
   registry, K/tick, `status` gate, fill on `no_fuel`/`no_ammo`. This alone makes
   both turrets and burners cheap and correct (reactive). Add instrumentation.
3. **Measure.** Confirm in-game that the sweep is cheap and refills work. Capture
   needy-fraction / cost numbers.
4. **Tier 2 (fuel deadline scheduler).** Move fuel burners off the round-robin
   sweep onto the deadline structure; keep the sweep as fallback for
   un-schedulable burners. Re-measure.

Ultimately the implementing engineer decides the structure; this is the
recommended staging.

## Testing

Avoid introducing boilerplate tests; we do not want excessive pointless tests as
these do not serve anyone. It's extremely important that the tests are
meaningful, clear, and validate core issues and behavior. It's important to
figure out tests that validate our business case, and that ensure healthy core
architecture. They can and should help engineers understand the intention behind
the code.

Note for this repo specifically: there is **no test harness yet** (no `tests/`,
no `validate.sh`). Follow the `test-writing` skill. The behavior here is
runtime/in-game, so most validation is the in-game checklist below; reserve
automated tests for logic that can be exercised without the game engine (e.g. the
Tier 2 ticks-until-dry computation: given fuel value and burn rate, the deadline
is correct; idle/variable-rate burners get a safe lower bound). If adding any
test infrastructure, keep it minimal and meaningful.

## Validation

In-game checklist (single-player is sufficient given the no-alert design):

- [ ] Place an Auto-Loader chest and an ammo turret on the same surface; stock
      the chest with ammo. Trigger combat (spawn biters / `/c` command); the
      turret refills from the pool as it fires, and stops drawing when the pool
      empties. No fill happens for turrets on a surface with no chest.
- [ ] Place a burner mining drill (or boiler) + chest with coal. The burner stays
      fueled; with Tier 2, confirm via debug logging that it is **not** revisited
      every tick (deadline far in the future), yet still tops up before stalling
      for long.
- [ ] Mine/destroy a tracked entity and the representative chest: registry drops
      the entity, surface still works after the representative is replaced, and a
      surface with zero chests is skipped cleanly.
- [ ] Save/load mid-operation: registry, cursor, deadlines, and chest map survive
      (no `on_load` writes to `storage`); add the mod to an existing save and it
      scans + works.
- [ ] Quality ammo/fuel: a turret/burner is filled with an accepted quality and
      never receives an item it rejects.
- [ ] UPS sanity: with a few thousand registered entities, the sweep cost is
      negligible (debug instrumentation), and fuel burners barely contribute
      thanks to Tier 2.
- [ ] `K` runtime setting changes take effect (and `on_nth_tick` re-registers).

## Documentation

- **`README.md`** — replace/condense the long "Dev Notes on Events" brain-dump
  with the actual design (registry + Tier 0–2, why alerts/events were rejected,
  Tier 3 deferred). Keep a short event-rationale note.
- **`settings.lua`** + **`locale/en/locale.cfg`** — add the `K`/sweep tunable(s)
  with `[mod-setting-name]` / `[mod-setting-description]` locale keys; note any
  restart requirement.
- **`info.json`** — bump `version`; description already promises ammo/fuel
  filling, so no copy change needed.
- **`install.sh`** — include `migrations/` in the packaged zip if a migration
  ships (see Implementation Notes).
- **`changelog.txt`** — if/when the repo adopts Factorio's strict changelog
  format, record the fill engine; otherwise note in the commit.
