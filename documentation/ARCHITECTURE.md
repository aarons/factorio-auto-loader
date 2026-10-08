# Architecture

## Shared supply

The chest defined in `data.lua` is based on Factorio's `linked-chest`.
`control.lua` assigns its surface index as its `link_id`, giving chests on the
same surface and force a shared inventory. This lets the refill code access one
supply pool without choosing between individual chests. Supply is obtained with
`force.get_linked_inventory("auto-loader-chest", surface_index)`. The second
argument is a link ID, whose surface meaning comes from our assignment.

A persisted membership registry tracks every physical chest by surface and
force, with counts, unit-number records, and a destruction-registration lookup.
Only live membership enables supply: a linked inventory surviving the last
chest cannot supply consumers. Initialization/configuration changes rebuild the
registry; normal refill processing never searches for chests. See the
[event reference](EVENTS.md) for registration, cleanup, merge, and import rules.

## Refill engine

The current implementation maintains a registry of ammo consumers and burners,
populated by initialization scans and build/clone events. Destruction events and
cleanup during processing remove stale entries.

A round-robin sweep checks a configurable number of consumers each tick
(`auto-loader-entities-per-tick`, default 10). Polling provides refill checks
without relying on a general ammo or fuel consumption event. Unsupplied and
stale entries count toward the visit budget. Each consumer uses its current
surface and force, including mobile consumers.

Bucket eligibility is checked before consumer inventories, burners, or player
settings. Known chest references are validated once per visited bucket per tick
to cover delayed destruction notifications. This costs O(chests in visited
buckets), without retaining a representative. With no chests anywhere, the tick
handler is unregistered; the first registered chest restores it. Empty chests
stay active so ordinary restocking is detected. On load, subscription is restored
from the persisted total without modifying storage or accessing `game`.

When a consumer needs supply, the engine reads the shared inventory. A Lua ledger
caches direct inventory lookups (including nil) per surface/force for the tick,
tracks available items and accepted transfers, and supply item removals are batched
at the end of the sweep. The [ledger benchmark report](BENCHMARK_RESULTS_2026-09-09_LEDGER.md)
documents the earlier supply-batching comparison. The
[membership report](BENCHMARK_RESULTS_2026-10-07_MEMBERSHIP.md) measures the
current discovery and scheduling change.

## Refill behavior

- Entities marked for deconstruction are skipped.
- Ammo targets come from the entity prototype, with a fallback of 10.
- Generic burners receive up to 10 fuel items; locomotives fill their first fuel
  slot to a stack.
- Existing eligible item and quality combinations are preferred when topping up.
  Transfers preserve quality and charge supply for the amount accepted.
- Character ammo slots are filled according to their paired guns. Holding ammo
  postpones refilling empty slots so the player can remove guns; occupied slots
  continue topping up. The per-player delay defaults to 10 seconds, with 0
  disabling the delay.
