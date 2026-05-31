-- The link_id hash prefix changed from "raleys-ammo-loader-" to
-- "raleys-auto-loader-". Move each surface's pooled chest inventory from
-- the old link_id pool to the new one so contents aren't orphaned.

local CHEST_NAME = "auto-loader-chest-linked"

local function fnv1a(s)
  local hash = 0x811c9dc5
  for i = 1, #s do
    hash = bit32.bxor(hash, string.byte(s, i))
    hash = bit32.band(hash * 0x01000193, 0xffffffff)
  end
  return hash
end

for _, surface in pairs(game.surfaces) do
  local chests = surface.find_entities_filtered{ name = CHEST_NAME }
  if next(chests) then
    local old_id = fnv1a("raleys-ammo-loader-" .. surface.name)
    local new_id = fnv1a("raleys-auto-loader-" .. surface.name)
    if old_id ~= new_id then
      local sample = chests[1]
      local old_inv = sample.get_inventory(defines.inventory.chest)
      local buffer
      if old_inv and not old_inv.is_empty() then
        buffer = game.create_inventory(#old_inv)
        for i = 1, #old_inv do
          local src = old_inv[i]
          if src.valid_for_read then buffer[i].set_stack(src) end
        end
        old_inv.clear()
      end
      for _, c in pairs(chests) do c.link_id = new_id end
      if buffer then
        local new_inv = sample.get_inventory(defines.inventory.chest)
        for i = 1, #buffer do
          local src = buffer[i]
          if src.valid_for_read then new_inv[i].set_stack(src) end
        end
        buffer.destroy()
      end
    end
  end
end
