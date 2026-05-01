-- A relative-anchored frame opens beside the vanilla linked-container GUI
-- whenever a player opens an auto-loader chest. The GUI is rebuilt fully
-- on every interaction (priority list size N is small).

local gui = {}

local FRAME_NAME = "alc_priority_frame"

local STRATEGY_NAMES = {
  "highest_quality_first",
  "lowest_quality_first",
  "highest_count_first",
  "lowest_count_first",
}
local STRATEGY_NAME_TO_INDEX = {}
for i, name in ipairs(STRATEGY_NAMES) do
  STRATEGY_NAME_TO_INDEX[name] = i
end

local STRATEGY_BUTTON_CAPTION = {
  highest_quality_first = "Q↓",
  lowest_quality_first  = "Q↑",
  highest_count_first   = "N↓",
  lowest_count_first    = "N↑",
}

-- Set by gui.bind from control.lua.
local CHEST_NAME
local quality_order_for
local update_combinators_for_surface

function gui.bind(deps)
  CHEST_NAME                     = deps.CHEST_NAME
  quality_order_for              = deps.quality_order_for
  update_combinators_for_surface = deps.update_combinators_for_surface
end

local function localised_strategy(strategy)
  return { "alc.strategy-" .. strategy:gsub("_", "-") }
end

local function localised_item_name(name)
  local proto = prototypes.item[name]
  if proto then return proto.localised_name end
  return name
end

local function build_tab_bar(parent, active_tab)
  local bar = parent.add{ type = "flow", direction = "horizontal" }
  for _, tab_key in ipairs({ "fuel", "ammo" }) do
    local btn = bar.add{
      type = "button",
      caption = { "alc.tab-" .. tab_key },
      tags = { alc_action = "tab", tab = tab_key },
    }
    if tab_key == active_tab then
      btn.enabled = false
    end
  end
end

local function populate_priority_table(items_table, v, category_key)
  local order = v[category_key .. "_order"]
  for idx = 1, #order do
    local name = order[idx]
    local entry = v[category_key][name]
    if entry then
      local total = 0
      for _, c in pairs(entry.totals) do total = total + c end
      items_table.add{
        type = "sprite-button",
        sprite = "item/" .. name,
        tooltip = { "alc.take-stack-tooltip", localised_item_name(name) },
        number = total,
        style = "slot_button",
        tags = { alc_action = "take_stack", category = category_key, item = name },
      }
      local arrows = items_table.add{ type = "flow", direction = "horizontal" }
      arrows.style.horizontal_spacing = 0
      arrows.add{
        type = "button",
        caption = "⏫",
        tooltip = { "alc.move-to-top" },
        tags = { alc_action = "top", category = category_key, idx = idx },
        enabled = (idx > 1),
        style = "tool_button",
      }
      arrows.add{
        type = "sprite-button",
        sprite = "utility/speed_up",
        tooltip = { "alc.move-up" },
        tags = { alc_action = "up", category = category_key, idx = idx },
        enabled = (idx > 1),
        style = "tool_button",
      }
      arrows.add{
        type = "sprite-button",
        sprite = "utility/speed_down",
        tooltip = { "alc.move-down" },
        tags = { alc_action = "down", category = category_key, idx = idx },
        enabled = (idx < #order),
        style = "tool_button",
      }
      arrows.add{
        type = "button",
        caption = "⏬",
        tooltip = { "alc.move-to-bottom" },
        tags = { alc_action = "bottom", category = category_key, idx = idx },
        enabled = (idx < #order),
        style = "tool_button",
      }
      items_table.add{
        type = "button",
        caption = STRATEGY_BUTTON_CAPTION[entry.strategy] or "?",
        tooltip = { "alc.strategy-tooltip", localised_strategy(entry.strategy) },
        tags = { alc_action = "strategy_cycle", category = category_key, item = name },
        style = "tool_button",
      }
    end
  end
end

local function build_priority_section(parent, surface_index, category_key)
  local v = storage.virtual[surface_index]
  if not v then return end

  local order = v[category_key .. "_order"]

  if #order == 0 then
    parent.add{
      type = "label",
      caption = { "alc.empty-priority" },
    }
    return
  end

  local scroll = parent.add{
    type = "scroll-pane",
    name = "alc_scroll",
    vertical_scroll_policy = "auto-and-reserve-space",
    horizontal_scroll_policy = "never",
  }
  scroll.style.maximal_height = 400
  scroll.style.minimal_width  = 280

  local items_table = scroll.add{
    type = "table",
    name = "alc_items",
    column_count = 3,
  }

  populate_priority_table(items_table, v, category_key)
end

local function build_gui_for_player(player, surface_index)
  local relative = player.gui.relative
  if relative[FRAME_NAME] then relative[FRAME_NAME].destroy() end
  local frame = relative.add{
    type = "frame",
    name = FRAME_NAME,
    direction = "vertical",
    caption = { "alc.priority-frame-title" },
    anchor = {
      gui = defines.relative_gui_type.linked_container_gui,
      position = defines.relative_gui_position.right,
      name = CHEST_NAME,
    },
  }
  local active_tab = storage.alc_open_tab[player.index] or "ammo"
  build_tab_bar(frame, active_tab)
  local content = frame.add{
    type = "frame",
    direction = "vertical",
    style = "inside_shallow_frame_with_padding",
  }
  build_priority_section(content, surface_index, active_tab)
end

-- Refresh the priority list rows in place, preserving the scroll-pane (and
-- thus the user's scroll position). Falls back to a full rebuild if the
-- shape needs to change (empty-state label vs. populated table).
local function refresh_priority_items_for_player(player, surface_index)
  local relative = player.gui.relative
  local frame = relative[FRAME_NAME]
  if not frame then return end
  local active_tab = storage.alc_open_tab[player.index] or "ammo"
  local v = storage.virtual[surface_index]
  if not v then return end
  local order = v[active_tab .. "_order"]
  local content = frame.children[2]
  local scroll = content and content.alc_scroll
  local items_table = scroll and scroll.alc_items
  if (not items_table) or (not order) or #order == 0 then
    build_gui_for_player(player, surface_index)
    return
  end
  items_table.clear()
  populate_priority_table(items_table, v, active_tab)
end

local function destroy_gui_for_player(player)
  local relative = player.gui.relative
  if relative[FRAME_NAME] then relative[FRAME_NAME].destroy() end
end

function gui.on_gui_opened(event)
  if event.gui_type ~= defines.gui_type.entity then return end
  local entity = event.entity
  if not (entity and entity.valid) then return end
  if entity.name ~= CHEST_NAME then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  local surface_index = entity.surface.index
  storage.alc_open_chest[event.player_index] = surface_index
  build_gui_for_player(player, surface_index)
end

function gui.on_gui_closed(event)
  if event.gui_type ~= defines.gui_type.entity then return end
  local entity = event.entity
  if not (entity and entity.valid) then return end
  if entity.name ~= CHEST_NAME then return end
  local player = game.get_player(event.player_index)
  storage.alc_open_chest[event.player_index] = nil
  if player then destroy_gui_for_player(player) end
end

function gui.on_gui_click(event)
  local element = event.element
  if not (element and element.valid) then return end
  local tags = element.tags
  if not tags then return end
  local action = tags.alc_action
  if not action then return end

  local player = game.get_player(event.player_index)

  if action == "tab" then
    local tab = tags.tab
    if tab ~= "fuel" and tab ~= "ammo" then return end
    storage.alc_open_tab[event.player_index] = tab
    local surface_index = storage.alc_open_chest[event.player_index]
    if player and surface_index then build_gui_for_player(player, surface_index) end
    return
  end

  local surface_index = storage.alc_open_chest[event.player_index]
  if not surface_index then return end
  local v = storage.virtual[surface_index]
  if not v then return end

  if action == "up" or action == "down" or action == "top" or action == "bottom" then
    local category = tags.category
    local idx = tags.idx
    if not (category and idx) then return end
    local order = v[category .. "_order"]
    if not order then return end
    local n = #order
    if action == "up" then
      if idx > 1 then
        order[idx - 1], order[idx] = order[idx], order[idx - 1]
      end
    elseif action == "down" then
      if idx < n then
        order[idx + 1], order[idx] = order[idx], order[idx + 1]
      end
    elseif action == "top" then
      if idx > 1 then
        local name = table.remove(order, idx)
        table.insert(order, 1, name)
      end
    else -- bottom
      if idx < n then
        local name = table.remove(order, idx)
        table.insert(order, name)
      end
    end
    if player then refresh_priority_items_for_player(player, surface_index) end
    return
  end

  if action == "take_stack" then
    local category = tags.category
    local item_name = tags.item
    if not (category and item_name and player) then return end
    local entry = v[category][item_name]
    if not entry then return end
    local proto = prototypes.item[item_name]
    if not proto then return end
    local cursor = player.cursor_stack
    if not cursor then return end

    local q_order = quality_order_for(entry)
    local quality
    for i = 1, #q_order do
      if (entry.totals[q_order[i]] or 0) > 0 then
        quality = q_order[i]
        break
      end
    end
    if not quality then
      if player then refresh_priority_items_for_player(player, surface_index) end
      return
    end

    local available = entry.totals[quality]
    local stack_size = proto.stack_size
    local to_take
    if cursor.valid_for_read then
      if cursor.name ~= item_name or cursor.quality.name ~= quality then return end
      local space = stack_size - cursor.count
      if space <= 0 then return end
      to_take = available < space and available or space
      cursor.count = cursor.count + to_take
    else
      to_take = available < stack_size and available or stack_size
      if not cursor.set_stack{ name = item_name, count = to_take, quality = quality } then
        return
      end
    end

    if to_take >= available then
      entry.totals[quality] = nil
    else
      entry.totals[quality] = available - to_take
    end

    -- Player just pulled stock out of virtual storage; refresh circuit
    -- signals before the GUI rebuild reads from the same data.
    update_combinators_for_surface(surface_index)
    refresh_priority_items_for_player(player, surface_index)
    return
  end

  if action == "strategy_cycle" then
    local category = tags.category
    local item = tags.item
    if not (category and item) then return end
    local entry = v[category][item]
    if not entry then return end
    local cur = STRATEGY_NAME_TO_INDEX[entry.strategy] or 1
    local n = #STRATEGY_NAMES
    local dir = (event.button == defines.mouse_button_type.right) and -1 or 1
    local next_idx = ((cur - 1 + dir) % n) + 1
    entry.strategy = STRATEGY_NAMES[next_idx]
    if player then refresh_priority_items_for_player(player, surface_index) end
    return
  end
end

return gui
