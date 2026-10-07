# Architecture

## Shared supply

The chest defined in `data.lua` is based on Factorio's `linked-chest`.
`control.lua` assigns its surface index as its `link_id`, giving chests on the
same surface and force a shared inventory. This lets the refill code access one
supply pool without choosing between individual chests.

## Refill engine

The current implementation maintains a registry of ammo consumers and burners,
populated by initialization scans and build/clone events. Destruction events and
cleanup during processing remove stale entries.

A round-robin sweep checks a configurable number of consumers each tick
(`auto-loader-entities-per-tick`, default 10). Polling provides refill checks
without relying on a general ammo or fuel consumption event.

When a consumer needs supply, the engine reads the shared inventory. A Lua ledger
tracks available items and accepted transfers, and chest removals are batched
at the end of the sweep. The [ledger benchmark report](BENCHMARK_RESULTS_2026-09-09_LEDGER.md)
compares this implementation with earlier approaches.

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
