Summary

Inspired by the ammo-loader+ mod. Will automatically fill turrets with ammo and fuel burners with fuel from a chest. Works with quality ammo and fuel, has shared storage per surface, and works in spaaaaace.

Description

# Auto-Loader Chest

This is a simplified version of the excellent [Ammo-Loader+](https://mods.factorio.com/mod/ammo-loader) mod. Place fuel and ammo in the chest and then turrets and fuel-burners (trains, furnaces, boilers, etc.) on that surface will automatically get refilled.

**Why a new mod?**

The ammo-loader+ mod doesn't currently work with quality ammo and fuel. I looked at submitting a patch, but it required more work than expected to support. There have also been a lot of changes to the factorio API since the mod was first published 9(!!!) years ago. It's still an amazing mod and works very well if you aren't using quality ammo/fuel or picky-dollies.

## Features

This mod was written from scratch and utilizes Factorio's core functionality as a replacement for features that exist in ammo-loader+. So there are a few things that ammo-loader+ does that this mod does not: refunding ammo to chest, entity filters, and upgrading ammo to higher damage ones pro-actively.

On to the features:

**Linked Chests**

The auto-loader chest shares inventory with all other auto-loaders on a given surface.

This makes it trivial for the mod to determine where to pull ammo and fuel from. We don't need to scan multiple chests, avoid distance calculations, and don't need to make decisions about where to pull from when chests have different inventories.

**Stack-Size Multipliers**

Linked-chests can have stack-size multipliers, or slot-filters, but not both. Both would be beneficial for this mod. But in this case, stack-size multipliers won out since we only have the one linked-chest inventory on a given surface.

This allows for large inventory counts and no issues with high consumption scenarios (such as Rampant++, which I tested this on for about a hundred hours :D).

The slot count and stack size multiplier of the chest is configurable. The chest can have 10 slots that support 5 stacks of inventory in each slot... or 100 slots with 100k stacks per slot :D

**Constrained Per-Surface**

The chest only fills entities on the same surface. So chests on Nauvis will only fill entities on Nauvis.

This helps manage things like specialized fuels or ammo getting used only on the surface where they're needed. We don't have to provide a user interface or more complicated filtering mechanism by doing it this way.

You can place chests on space platforms.
If using a mod like factorissimo, just know that each building is it's own surface.

**Combinator Support**

The chests can be wired up to combinators to help manage the inventory.

Use this to help keep a certain amount stocked, or to quickly fill in a fallback ammo if the primary one is running out.

**First in, First out**

The chest uses the first matching slot or item that's valid for the consumer. So if you have multiple fuel types and ammos:
- for an empty turret, it will pick from the first ammo in the chest
- for a refill turret, it will try to refill the matching ammo. If not matching ammo exists it will wait until the turret runs out, then replace with the next ammo.

If you want to prioritize consumption of higher quality ammo for example, you would use combinators to load the chest with preferred types, and only add in lower tier ammo when the preffered type runs low.

**Player Ammo Respects Logistic Requests**

Before your force unlocks logistic requests, the chest keeps your gun slots topped up automatically — great for the early game.

Once logistic requests are unlocked, your personal requests take over: the chest only refills ammo types you are actively requesting. Remove (or zero) the ammo request — or pause personal logistics — and the refilling stops, so you can drop your ammo off and board a space platform without the mod stuffing it right back in your pockets.

## Known Issues

**No proactive ammo/fuel upgrades**

This is a downgrade from ammo-loader+ functionality. It would be great to support in the future but adds surprising complexity.

Here are some current workarounds:
- fill the auto-loader chest with the upgraded ammo you want used, then wait for the consumer to run out of the old one (it was uncomfortable, but fine on a rampant++ run)
- deconstruct the consumer so bots take the old ammo/fuel away, then reconstruct
- place the ammo you want a turret to use by hand. The chest will always attempt to refill with the type of ammo/fuel that's already in the consumer.

**No entity filtering**

This is also a downgrade from ammo-loader+ functionality.

The chest will attempt to fill all ammo and fuel consumers on the map.

**Teleporting Stuff**

You can put anything you want into the linked-chest. It doesn't have to be ammo/fuel. So you can teleport things around your base or space platform if you aren't disciplined. There are no plans to try to change this.


## Have Fun

So this is a simplified version of the original mod that takes a different design direction and has different characteristics as a result.

In practice, this mod worked well for a multi-month Rampant++ run that scaled up to megabase SPM levels across several planets.
