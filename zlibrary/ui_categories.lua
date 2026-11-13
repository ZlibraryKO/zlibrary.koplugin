-- Download categories: managing them from the settings menu, and the chooser and create dialog the
-- open-after-download prompt offers.
--
-- Part of the Ui facade (ui.lua); see ui_core.lua. Moved from ui.lua unchanged: diff with
-- --color-moved against the commit before the split to see where it came from.

local ConfirmBox = require("ui/widget/confirmbox")
local T = require("zlibrary.gettext")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local Menu = require("zlibrary.menu")
local Config = require("zlibrary.config")
local Ui = require("zlibrary.ui_core")
local Shared = require("zlibrary.ui_shared")
local _showAndTrackDialog = Shared._showAndTrackDialog
local _closeAndUntrackDialog = Shared._closeAndUntrackDialog

-- Download categories management ----------------------------------------------------------------
-- Categories are names that become folders under the download dir (see Config); this is where the
-- user creates, renames and removes them. Folders are derived from the names, so there is no folder
-- picker -- only text entry. Menus rebuild after each change: a sub-category edit refreshes the open
-- submenu in place, while adding, renaming or removing a category (a change to the list itself) is
-- reflected when control returns to the list, through TouchMenu's backToUpperMenu/needs_refresh hook.

local function _categoryError(reason)
    if reason == "empty" then return T("Please enter a name.") end
    if reason == "exists" then return T("A category with that name already exists.") end
    -- "not_found" / "no_parent": it was removed under us (e.g. acting on a menu left open).
    return T("That category no longer exists.")
end

local function _findCategory(name)
    for _, cat in ipairs(Config.getCategories()) do
        if cat.name == name then return cat end
    end
    return nil
end

-- Alphabetical, case-insensitive, on a shallow copy: the display order, never the stored order (the
-- stored list is what the mutation helpers read back and rewrite). One for the category tables, one
-- for the child name strings.
local function _sortedCategories(list)
    local copy = {}
    for _, cat in ipairs(list) do copy[#copy + 1] = cat end
    table.sort(copy, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end)
    return copy
end

local function _sortedNames(list)
    local copy = {}
    for _, name in ipairs(list) do copy[#copy + 1] = name end
    table.sort(copy, function(a, b) return a:lower() < b:lower() end)
    return copy
end

-- A small name-entry dialog for a category or sub-category. on_accept(text) does the work and
-- returns true to accept (the dialog closes) or false to keep it open with what was typed, so a
-- rejected name (empty, duplicate) can be corrected without retyping.
function Ui.showCategoryNameDialog(title, initial, on_accept)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = initial or "",
        buttons = {{
            {
                text = T("Cancel"),
                id = "close",
                callback = function() _closeAndUntrackDialog(dialog) end,
            },
            {
                text = T("Save"),
                is_enter_default = true,
                callback = function()
                    if on_accept(dialog:getInputText() or "") then
                        _closeAndUntrackDialog(dialog)
                    end
                end,
            },
        }},
    }
    _showAndTrackDialog(dialog)
    dialog:onShowKeyboard()
    return dialog
end

-- Rename/Remove for a single sub-category. refresh() rebuilds the open submenu so the change shows
-- at once.
local function _showSubcategoryActions(parent_name, sub_name, refresh)
    local dialog
    dialog = ButtonDialog:new{
        title = parent_name .. " › " .. sub_name,
        title_align = "center",
        buttons = {
            {{
                text = T("Rename"),
                callback = function()
                    _closeAndUntrackDialog(dialog)
                    Ui.showCategoryNameDialog(T("Rename sub-category"), sub_name, function(text)
                        local ok, reason = Config.renameSubcategory(parent_name, sub_name, text)
                        if not ok then Ui.showInfoMessage(_categoryError(reason)) return false end
                        refresh()
                        return true
                    end)
                end,
            }},
            {{
                text = T("Remove"),
                callback = function()
                    _closeAndUntrackDialog(dialog)
                    _showAndTrackDialog(ConfirmBox:new{
                        text = string.format(
                            T("Remove the sub-category \"%s\"? Books already filed there stay where they are."),
                            sub_name),
                        ok_text = T("Remove"),
                        ok_callback = function()
                            Config.removeSubcategory(parent_name, sub_name)
                            refresh()
                        end,
                    })
                end,
            }},
        },
    }
    _showAndTrackDialog(dialog)
end

-- The submenu for one category: its actions first (Add sub-category, Rename category, Remove
-- category), then a separator, then its sub-categories (tap each for Rename/Remove). Actions on top so
-- they stay on the first page however many sub-categories there are. Sub-category edits refresh this
-- submenu in place; renaming or removing the category itself changes the list a level up, so those
-- return there.
function Ui.buildOneCategoryMenuItems(cat_name)
    local cat = _findCategory(cat_name)
    local children = (cat and cat.children) or {}
    local items = {}

    table.insert(items, {
        text = T("Add sub-category…"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            Ui.showCategoryNameDialog(T("New sub-category"), "", function(text)
                local ok, reason = Config.addSubcategory(cat_name, text)
                if not ok then Ui.showInfoMessage(_categoryError(reason)) return false end
                if touchmenu_instance then
                    touchmenu_instance.item_table = Ui.buildOneCategoryMenuItems(cat_name)
                    touchmenu_instance:updateItems()
                end
                return true
            end)
        end,
    })

    table.insert(items, {
        text = T("Rename category…"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            Ui.showCategoryNameDialog(T("Rename category"), cat_name, function(text)
                local ok, reason = Config.renameCategory(cat_name, text)
                if not ok then Ui.showInfoMessage(_categoryError(reason)) return false end
                if touchmenu_instance then touchmenu_instance:backToUpperMenu() end
                return true
            end)
        end,
    })

    table.insert(items, {
        text = T("Remove category"),
        separator = true,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            _showAndTrackDialog(ConfirmBox:new{
                text = string.format(
                    T("Remove the category \"%s\" and its sub-categories? Books already filed there stay where they are."),
                    cat_name),
                ok_text = T("Remove"),
                ok_callback = function()
                    Config.removeCategory(cat_name)
                    if touchmenu_instance then touchmenu_instance:backToUpperMenu() end
                end,
            })
        end,
    })

    for _, child in ipairs(_sortedNames(children)) do
        local child_name = child
        table.insert(items, {
            text = child_name,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                _showSubcategoryActions(cat_name, child_name, function()
                    if touchmenu_instance then
                        touchmenu_instance.item_table = Ui.buildOneCategoryMenuItems(cat_name)
                        touchmenu_instance:updateItems()
                    end
                end)
            end,
        })
    end

    return items
end

-- The top-level "Download categories" list: "Add category…" first, then one row per category (tap to
-- open its submenu). Add stays on the first page however many categories there are, rather than being
-- paged off the bottom. needs_refresh/refresh_func let TouchMenu rebuild the list when returning from
-- a submenu, so a rename or removal made in there shows up on the way back.
function Ui.buildCategoriesMenuItems()
    local categories = Config.getCategories()
    local items = {}

    table.insert(items, {
        text = T("Add category…"),
        separator = true,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            Ui.showCategoryNameDialog(T("New category"), "", function(text)
                local ok, reason = Config.addCategory(text)
                if not ok then Ui.showInfoMessage(_categoryError(reason)) return false end
                if touchmenu_instance then
                    touchmenu_instance.item_table = Ui.buildCategoriesMenuItems()
                    touchmenu_instance:updateItems()
                end
                return true
            end)
        end,
    })

    for _, cat in ipairs(_sortedCategories(categories)) do
        local cat_name = cat.name
        local child_count = (cat.children and #cat.children) or 0
        table.insert(items, {
            text = cat_name,
            mandatory = child_count > 0 and tostring(child_count) or nil,
            keep_menu_open = true,
            sub_item_table_func = function()
                return Ui.buildOneCategoryMenuItems(cat_name)
            end,
        })
    end

    items.needs_refresh = true
    items.refresh_func = function() return Ui.buildCategoriesMenuItems() end

    return items
end

-- Create a category (and optionally a sub-category under it) from a pair of typed names, returning
-- the move target { name = parent, sub = <child or nil> } on success or nil + a message. An existing
-- name is reused, not an error: typing a name that already exists just files into it.
local function _createCategoryTarget(parent_raw, sub_raw)
    local parent = Config.sanitizeCategoryName(parent_raw)
    if parent == "" then return nil, T("Please enter a category name.") end
    local ok, reason = Config.addCategory(parent)
    if not ok and reason ~= "exists" then return nil, _categoryError(reason) end
    local sub = Config.sanitizeCategoryName(sub_raw)
    if sub ~= "" then
        local sok, sreason = Config.addSubcategory(parent, sub)
        if not sok and sreason ~= "exists" then return nil, _categoryError(sreason) end
        return { name = parent, sub = sub }
    end
    return { name = parent }
end

-- Create a category on the spot from the move menu: one dialog with a required category field and an
-- optional sub-category field. on_created(target) receives the move target so the caller can select
-- it straight away.
function Ui._showCreateCategoryDialog(on_created)
    local dialog
    dialog = require("ui/widget/multiinputdialog"):new{
        title = T("New category"),
        fields = {
            { description = T("Category"), hint = T("Category name") },
            { description = T("Sub-category (optional)"), hint = T("Sub-category name") },
        },
        buttons = {{
            {
                text = T("Cancel"),
                id = "close",
                callback = function() _closeAndUntrackDialog(dialog) end,
            },
            {
                text = T("Create"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local target, err = _createCategoryTarget(fields[1], fields[2])
                    if not target then
                        Ui.showInfoMessage(err)
                        return
                    end
                    _closeAndUntrackDialog(dialog)
                    on_created(target)
                end,
            },
        }},
    }
    _showAndTrackDialog(dialog)
    dialog:onShowKeyboard()
end

-- The post-download "Move to" picker, as a scrollable menu. Rows: Keep in download folder, New
-- category… (opens the create dialog), a separator, then every filing target A-Z -- each top-level
-- category, and each sub-category shown indented as "Parent › Child". Picking one hands a descriptor
-- ({ name = <top>, sub = <child or nil> } or nil) to on_pick; leaving the menu (Back / tap-outside)
-- calls on_cancel so the download dialog it came from reopens unchanged. The current choice is ticked.
function Ui._showCategoryChooser(categories, current, on_pick, on_cancel)
    local menu
    -- One close path for both outcomes; the guard stops a stray second call (e.g. a tap racing the
    -- Back gesture) from firing a callback twice.
    local done = false
    local function finish(cancelled, target)
        if done then return end
        done = true
        _closeAndUntrackDialog(menu)
        if cancelled then
            if on_cancel then on_cancel() end
        else
            on_pick(target)
        end
    end

    local function is_current(target)
        if current == nil or target == nil then return current == target end
        return current.name == target.name and current.sub == target.sub
    end
    local function mark(target) return is_current(target) and "✓" or nil end

    local function build_items()
        local items = {}

        items[#items + 1] = {
            text = T("Keep in download folder"),
            mandatory = mark(nil),
            keep_menu_open = true,
            callback = function() finish(false, nil) end,
        }
        items[#items + 1] = {
            text = T("New category…"),
            keep_menu_open = true,
            callback = function()
                Ui._showCreateCategoryDialog(function(target) finish(false, target) end)
            end,
        }
        items[#items].separator = true

        for _, cat in ipairs(_sortedCategories(categories)) do
            if type(cat) == "table" and cat.name then
                items[#items + 1] = {
                    text = cat.name,
                    mandatory = mark({ name = cat.name }),
                    keep_menu_open = true,
                    callback = function() finish(false, { name = cat.name }) end,
                }
                for _, child in ipairs(_sortedNames(cat.children or {})) do
                    items[#items + 1] = {
                        text = "    " .. cat.name .. " › " .. child,
                        mandatory = mark({ name = cat.name, sub = child }),
                        keep_menu_open = true,
                        callback = function() finish(false, { name = cat.name, sub = child }) end,
                    }
                end
            end
        end

        return items
    end

    menu = Menu:new{
        title = T("Move to"),
        item_table = build_items(),
        is_popout = false,
        title_bar_fm_style = true,
        -- Back key / title-bar close / tap-outside all route here; a deliberate pick closes via
        -- finish() first, so by the time this could run `done` is already set and it is a no-op.
        onClose = function() finish(true) end,
    }
    _showAndTrackDialog(menu)
end

return Ui
