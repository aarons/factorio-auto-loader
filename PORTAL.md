Summary

Inspired by the ammo-loader mod. Will automatically fill turrets with ammo and fuel burners with fuel from a chest. Works with quality ammo and fuel, has shared storage per surface, and works in spaaaaace.

Description

This is a simplified version of the excellent Ammo-Loader mod. Place fuel and ammo in the chest and then turrets and fuel-burners (trains, furnaces, boilers, etc.) on that surface will automatically get refilled.

Why a new mod?

The original ammo-loader mod has more features, but also a few quirks that don't play well with quality ammo and fuel in Factorio 2.0. I looked at making a patch, but it required more work and changes than I was comfortable with.

So this is a simplified take, written from scratch, that utilizes Factorio 2.1's latest API features and tools. This version leans on existing factorio features as much as possible.

# Auto-Loader Chest Design

**Linked Chests**

The auto-loader chest shares inventory with all other auto-loaders on a given surface.

This makes it trivial for the mod to determine where to pull ammo and fuel from. We don't need to scan multiple chests, avoid having to do distance calculations, and don't need to make prioritization decisions when loaders have different inventories.

**Stack-Size Multipliers**

Linked-chests can have stack-size multipliers, or slot-filters, but not both. Both would be beneficial for this mod. But in this case, stack-size multipliers won out since we only have the one linked-chest inventory on a given surface.

This allows for large inventory counts and no issues with high consumption scenarios (such as Rampant++, which I tested for about a hundred hours :D).

The slot count and stack size multiplier of the chest is configurable. For example, the chest can have 10 slots that support 5 stacks of inventory in each slot. Or 40 slots with 100k stacks :D

**Constrained Per-Surface**

The chest only fills entities on the same surface. So chests on Nauvis will only fill entities on Nauvis.

This helps manage things like specialized fuels or ammo getting used only on the surface where they're needed. We don't have to provide a user interface or more complicated filtering mechanism by doing it this way.

**Combinator Support**

The chests can be wired up to combinators to help manage the inventory.

Use this to help keep a certain amount stocked, or to quickly fill in a fallback ammo if the primary one is running out.

**First in, First out**

The chest fills based on the first matching slot or item that's valid for the consumer. So if you have multiple fuel types and ammos:
- for a new turret, it will pick from the first ammo in the chest
- for a refill, it will try to refill with the matching ammo, then fallback to the next one in the chest

If you want to prioritize consumption of higher quality ammo for example, you would use combinators to load the chest with preferred types, and only add in lower tier ammo when the preffered type runs low.

**No automatic ammo/fuel upgrades**

This is a downgrade from ammo-loaders functionality. It would be great to support, but is challenging to get right.

For now, the way to upgrade ammo or fuel in a consumer is to fill the auto-loader chest with the upgraded ammo you want them to use, then wait for the consumer to run out of the old one. Or deconstruct the consumer so bots take the old ammo/fuel away.

**No entity filtering**

This is also a downgrade from ammo-loader's functionality.

There currently isn't a way to filter out certain entities, or to prioritize one type of fuel for trains vs boilers. The chest will just fill the first compatible type it can.

To do this manually, place nuclear fuel in a train, or sniper bullets in a sniper turret. The auto-loader chest will then refill with those ammo types from it's inventory for those entities.

## Have Fun

So this is a simplified version of the original mod that is performant, uses modern factorio concepts, but also has some trade-offs.

In practice, this mod worked well for a Rampant++ run that scaled up to megabase SPM levels. The biggest issue I had was with managing different types of bullet ammo in different types of turrets: like sniper turrets versus heavy gun turrets.