-- Replace every legacy `auto-loader-chest` (container) on every surface with
-- the new `auto-loader-chest-linked` (linked-container) variant. All chests on
-- a surface end up sharing one inventory via a deterministic per-surface
-- link_id, so contents from N old chests merge into one pool.
--
-- This file is duplicated logic-wise with link_id_for_surface in control.lua,
-- but migrations run before control.lua's locals are in scope, so we inline.

local OLD_NAME = "auto-loader-chest"
local NEW_NAME = "auto-loader-chest-linked"

local function link_id_for_surface(surface)
  local s = "raleys-ammo-loader-" .. surface.name
  local hash = 0x811c9dc5
  for i = 1, #s do
    hash = bit32.bxor(hash, string.byte(s, i))
    hash = bit32.band(hash * 0x01000193, 0xffffffff)
  end
  return hash
end

for _, surface in pairs(game.surfaces) do
  local old_chests = surface.find_entities_filtered{ name = OLD_NAME }
  if #old_chests > 0 then
    local link_id = link_id_for_surface(surface)
    local total_spilled = 0

    for _, old in pairs(old_chests) do
      if old.valid then
        local position  = old.position
        local force     = old.force
        local direction = old.direction
        local last_user = old.last_user
        local quality   = old.quality
        local old_inv   = old.get_inventory(defines.inventory.chest)
        local snapshot  = old_inv and old_inv.get_contents() or {}

        -- Destroy first so create_entity at the same position doesn't collide.
        old.destroy{ raise_destroy = false }

        local new_chest = surface.create_entity{
          name         = NEW_NAME,
          position     = position,
          force        = force,
          direction    = direction,
          quality      = quality,
          raise_built  = false,
          create_build_effect_smoke = false,
        }

        if new_chest then
          if last_user then new_chest.last_user = last_user end
          -- link_id MUST be set before inserting items, otherwise the items
          -- land in the default link_id=0 pool instead of the surface's pool.
          new_chest.link_id = link_id

          local new_inv = new_chest.get_inventory(defines.inventory.chest)
          if new_inv then
            for _, stack in ipairs(snapshot) do
              local q = stack.quality or "normal"
              local inserted = new_inv.insert{
                name = stack.name, count = stack.count, quality = q,
              }
              local overflow = stack.count - inserted
              if overflow > 0 then
                surface.spill_item_stack{
                  position = position,
                  stack    = { name = stack.name, count = overflow, quality = q },
                }
                total_spilled = total_spilled + overflow
              end
            end
          end
        end
      end
    end

    if total_spilled > 0 then
      game.print(string.format(
        "[auto-loader] Migrated chests on surface '%s'. %d items spilled to the ground because the consolidated inventory ran out of space.",
        surface.name, total_spilled))
    end
  end
end
