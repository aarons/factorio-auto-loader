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

-- Receive shared names and callbacks from control.lua.
function gui.bind(deps)
end

-- Localised word for an item category ("fuel"/"ammo").
local function localised_category_word(category_key)
end

-- Localised description of a strategy for a category.
local function localised_strategy(strategy, category_key)
end

-- Localised display name for an item.
local function localised_item_name(name)
end

-- Build the fuel/ammo tab bar.
local function build_tab_bar(parent, active_tab)
end

-- Add one row per priority entry to the items table.
local function populate_priority_table(items_table, v, category_key)
end

-- Build the priority list section for a category.
local function build_priority_section(parent, surface_index, category_key)
end

-- Build the full priority frame for a player.
local function build_gui_for_player(player, surface_index)
end

-- Refresh the priority rows in place, preserving scroll position.
local function refresh_priority_items_for_player(player, surface_index)
end

-- Destroy a player's priority frame.
local function destroy_gui_for_player(player)
end

-- Open the priority frame when a loader chest is opened.
function gui.on_gui_opened(event)
end

-- Close the priority frame when a loader chest is closed.
function gui.on_gui_closed(event)
end

-- Handle clicks on tabs, priority arrows, take-stack, and strategy buttons.
function gui.on_gui_click(event)
end

return gui
