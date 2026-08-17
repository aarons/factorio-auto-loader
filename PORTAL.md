Summary

Inspired by the ammo-loader+ mod. Will automatically fill turrets with ammo and fuel burners with fuel from a chest. Works with quality ammo and fuel, has shared storage per surface, and works in spaaaaace.

Description

# Auto-Loader Chest

This is an alternative version of the excellent [Ammo-Loader+](https://mods.factorio.com/mod/ammo-loader) mod. Place fuel and ammo in the chest and then turrets and fuel-burners (trains, furnaces, boilers, etc.) will automatically get refilled.

**What's different?**

The ammo-loader+ mod doesn't currently work with quality ammo and fuel. I looked at submitting a patch, but it required more work than expected. It was easier to start fresh.

This mod uses Factorio's core functionality where possible to replace custom features in ammo-loader+. There are a few things that ammo-loader+ does that this mod currently does not do: refunding ammo to chest, entity filters, and upgrading ammo to higher damage ones pro-actively.

**Features & Design**

The auto-loader chest is linked and shares inventory with all other auto-loaders on a given surface.

This makes it trivial for the mod to determine where to pull ammo and fuel from. We don't need to scan multiple chests, can avoid distance calculations, and don't need to make prioritization decisions when inventories between chests are different. Having a single chest per surface allows us to avoid entire classes of problems (race conditions etc.)

**Stack-Size Multipliers**

Linked-chests can have stack-size multipliers, or slot-filters, but not both. Both would be beneficial for this mod. But after play testing, stack-size multipliers are better since we are limiting each surface to a single shared inventory. This allows for large inventory counts and no issues with high consumption scenarios (such as Rampant++, which I tested this on for about a hundred hours :D).

The slot count and stack size multiplier of the chest is configurable.

**Constrained Per-Surface**

The chest only fills entities on the same surface. So chests on Nauvis will only fill entities on Nauvis.

This helps manage things like specialized fuels or ammo getting used only on the surface where they're needed. We don't have to provide a user interface or more complicated filtering mechanism by doing it this way.

You can place chests on space platforms.

If using a mod like factorissimo, just know that each building has its own surface.

**Combinator Support**

The chests can be wired up to combinators to help manage the inventory.

Use this to help keep a certain amount stocked, or to quickly fill in a fallback ammo if the primary one is running out.

**First in, First out**

The chest uses the first matching slot or item that's valid for the consumer. So if you have multiple fuel types and ammos:
- for an empty turret, it will pick from the first ammo in the chest
- for a refill turret, it will try to refill the matching ammo. If not matching ammo exists it will wait until the turret runs out, then replace with the next ammo.

If you want to prioritize consumption of higher quality ammo for example, you would use combinators to load the chest with preferred types, and only add in lower tier ammo when the preffered type runs low.

## Feedback

It's always great hearing from folks who enjoy a mod, or have suggestions/requests. Please feel free to reach out!