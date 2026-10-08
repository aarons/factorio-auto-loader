# Runtime events

Chest membership is keyed by surface and force. Every chest has a reverse record
with its entity, unit number, destruction registration number, and recorded keys.
Duplicate registration/removal is harmless. Consumers remain registered even on
surfaces without supply in dormant buckets, so adding a first chest needs no
consumer rescan. Only supplied buckets participate in the refill sweep.

| Event | Handling |
| --- | --- |
| `on_built_entity`, `on_robot_built_entity`, `on_space_platform_built_entity`, `script_raised_built`, `script_raised_revive` | Link/register `entity`, or register a consumer. |
| `on_entity_cloned` | Link/register `destination`; area cloning emits individual entity events too. |
| `on_player_mined_entity`, `on_robot_mined_entity`, `on_space_platform_mined_entity`, `on_entity_died`, `script_raised_destroy` | Remove chest membership immediately using the still-valid entity. |
| `on_object_destroyed` | Idempotent chest removal by registration number; immediate active/dormant consumer removal by useful ID. |
| `on_surface_cleared`, `on_surface_deleted` | Drop chest and consumer buckets by `surface_index`; later destruction notifications are harmless. |
| `on_forces_merged` | Reroute source consumers and re-register source chests under the destination force. |
| `on_surface_imported` | Resolve `game.surfaces[event.surface_index]`; scan once for chests and consumers. |
| `on_player_created`, `on_player_respawned` | Register the player's current character. |
| `on_player_changed_surface`, `on_player_changed_force` | Reroute the current character and vehicle. |
| `script_raised_teleported` | Reroute the registered consumer using its current surface/force. |
| Initialization/configuration change | Rebuild chest membership from one chest scan per surface; rebuild consumer routing, preserve character delays, and discard legacy queues/caches. |
| Save loading | Rebuild local prototype caches and restore conditional tick subscription using storage reads only. |
| `on_tick` | Bounded visits to supplied buckets and batched transfers; registered only while at least one chest is recorded. |

Destruction notifications arrive at the end of the current or next tick. Before
a bucket authorizes supply, its known entity references are checked until one live chest is found, once
per demanding bucket per tick. Invalid members preceding it are removed;
destruction events clean up the remaining invalid records. There is no world search or
representative-chest selection. Marking a chest for deconstruction leaves it
active until removal. Surface clearing/deletion can complete after the requesting
handler returns; fixtures wait before rebuilding on a cleared surface.

The supported contract covers normal lifecycle operations and scripts raising
appropriate events. Silent creation, consumer force/surface reassignment, and chest force/link-ID
mutation by other mods are not discovery mechanisms. In particular, dormant
consumers cannot be rediscovered by a refill visit. Scripted teleportation must
use `raise_teleported=true` or explicitly raise `script_raised_teleported`. There is no periodic reconciliation
scan or general entity-force-change event. Registered silent destruction still
has the object-destruction backstop.

API references: [events](https://lua-api.factorio.com/latest/events.html),
[object registration](https://lua-api.factorio.com/latest/classes/LuaBootstrap.html#register_on_object_destroyed),
[load contract](https://lua-api.factorio.com/latest/classes/LuaBootstrap.html#on_load).
Runtime tests use Factorio 2.1.21; the mod minimum remains 2.1.20.

Routing API references: [player surface changes](https://lua-api.factorio.com/latest/events.html#on_player_changed_surface),
[player force changes](https://lua-api.factorio.com/latest/events.html#on_player_changed_force),
[teleport events](https://lua-api.factorio.com/latest/events.html#script_raised_teleported),
[teleport opt-in](https://lua-api.factorio.com/latest/classes/LuaControl.html#teleport).
