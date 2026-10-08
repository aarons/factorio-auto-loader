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

Consumers are stored in separate surface/force buckets. A compact list contains
only nonempty buckets with chest membership; dormant consumers consume no refill
slots and are never polled. Adding the first chest activates an existing bucket
without a rescan. Removing the last chest deactivates it. Destruction events
remove consumers from either active or dormant buckets immediately. Activation
appends to the active-group array in constant time. Deactivation shifts subsequent
active-group indices, taking time proportional to active groups, not consumers.

A round-robin sweep checks at most `auto-loader-entities-per-tick` consumers
(default 10), and at most the active consumer count. One persisted traversal
position holds the active bucket index and consumer index; completing a group advances that position to the next active bucket.
Groups have no individual cursors. Reactivated groups start at their first
consumer. Removing an earlier group preserves the current consumer position.
The sweep remains fair across differently sized groups. Invalid consumers encountered
before their destruction notification consume one bounded visit and are removed.
Full consumers still need demand polling, but return before location reads,
chest validation, or supply resolution. There is no general consumption event.

When demand exists, known chest references are checked once per bucket per tick.
Invalid records are pruned until the first live chest, then validation stops.
With live members this needs one validity check, regardless of bucket size;
a run of invalid members can still require multiple checks. Destruction events
clean up unvisited invalid records. No world searches occur during refills.
With no chests anywhere, the tick handler is unregistered; the first registered
chest restores it. Empty chests remain active for eventless restocking. On load,
subscription is restored with storage reads only and without accessing `game`.

Player surface/force changes, explicitly raised teleports, and force merges
reroute consumers even while refill ticks are disabled. Other mods must raise
teleport events; silent force/surface mutation cannot activate a dormant bucket.
Configuration changes rebuild routing while preserving character refill delays.

When a consumer needs supply, the engine reads the shared inventory. A Lua ledger
caches direct inventory lookups (including nil) per surface/force for the tick,
tracks available items and accepted transfers, and supply item removals are batched
at the end of the sweep. The [ledger benchmark report](BENCHMARK_RESULTS_2026-09-09_LEDGER.md)
documents the earlier supply-batching comparison. The
[membership report](BENCHMARK_RESULTS_2026-10-07_MEMBERSHIP.md) measures the
previous discovery and scheduling change. The
[supplied-queue report](BENCHMARK_RESULTS_2026-10-07_QUEUES.md) compares this follow-up
against that implementation.

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
