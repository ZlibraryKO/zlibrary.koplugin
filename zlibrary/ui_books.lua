-- One book: its details, the download and remove confirmations, the open-after-download prompt, and
-- the similar-books and single-book menus.
--
-- Part of the Ui facade (ui.lua); see ui_core.lua. Moved from ui.lua unchanged: diff with
-- --color-moved against the commit before the split to see where it came from.

local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local T = require("zlibrary.gettext")
local Menu = require("zlibrary.menu")
local Config = require("zlibrary.config")
local Ui = require("zlibrary.ui_core")
local Shared = require("zlibrary.ui_shared")
local _showAndTrackDialog = Shared._showAndTrackDialog
local _closeAndUntrackDialog = Shared._closeAndUntrackDialog

local _plugin_instance = nil
Shared.track_plugin_instance(function(instance) _plugin_instance = instance end)

function Ui.showBookDetails(parent_zlibrary, book, clear_cache_callback)
    local ZlibBookDialog = require("zlibrary.bookdetails_dialog")
    return ZlibBookDialog.showBookDetails(Ui, parent_zlibrary, book, clear_cache_callback)
end

function Ui.confirmRemoveDownloaded(title, ok_callback)
    local text = string.format(T("Remove \"%s\" from your downloaded books?"), title or T("Unknown Title"))
    if _plugin_instance and _plugin_instance.dialog_manager then
        _plugin_instance.dialog_manager:showConfirmDialog({
            text = text,
            ok_text = T("Remove"),
            ok_callback = ok_callback,
            cancel_text = T("Cancel")
        })
    else
        UIManager:show(ConfirmBox:new{
            text = text,
            ok_text = T("Remove"),
            ok_callback = ok_callback,
            cancel_text = T("Cancel")
        })
    end
end

function Ui.confirmDownload(filename, ok_callback)
    if _plugin_instance and _plugin_instance.dialog_manager then
        _plugin_instance.dialog_manager:showConfirmDialog({
            text = string.format(T("Download \"%s\"?"), filename),
            ok_text = T("Download"),
            ok_callback = ok_callback,
            cancel_text = T("Cancel")
        })
    else
        local dialog = ConfirmBox:new{
            text = string.format(T("Download \"%s\"?"), filename),
            ok_text = T("Download"),
            ok_callback = ok_callback,
            cancel_text = T("Cancel")
        }
        UIManager:show(dialog)
    end
end

function Ui.confirmOpenBook(filename, has_wifi_toggle, default_turn_off_wifi, ok_open_callback, cancel_callback, categories)
    local turn_off_wifi = default_turn_off_wifi
    -- nil = leave the book in the download folder; otherwise { name = <top>, sub = <child or nil> }.
    local chosen_target = nil

    -- Downloading several books in a row means answering this dialog several times, which a user
    -- asked to be able to switch off.
    --
    -- Skipping it leaves Wi-Fi alone, whatever the stored preference says. That preference is
    -- "Turn off Wi-Fi after closing this dialog" -- there is no dialog here and nothing being
    -- closed, so there is nothing for it to be after. It also lives only on this dialog, so
    -- honouring it here would keep a background action running that the user can no longer see
    -- or change. Anyone wanting Wi-Fi managed for them still has the prompt.
    --
    -- The notice matters as much as the skipping. This dialog is the only sign most people get
    -- that a download worked; replacing one that demands an answer with one that dismisses
    -- itself is the point, and replacing it with silence would be a different, worse feature.
    if Config.getSkipOpenBookPrompt() then
        Ui.showInfoMessage(string.format(T("\"%s\" downloaded."), filename))
        -- No dialog, so no filing choice was made: the second argument stays nil and the book is
        -- left in the download folder.
        if cancel_callback then cancel_callback(false) end
        return
    end

    -- Only offer the "Move to" row when categories actually exist; with none configured the
    -- dialog is byte-identical to what it was before this feature.
    local has_categories = type(categories) == "table" and #categories > 0

    local function targetLabel(target)
        -- The default when nothing is picked: the book stays in the download folder. Naming it (rather
        -- than an empty "Move to…") tells the user where the book goes if they leave this alone.
        if target == nil then return T("Download folder") end
        if target.sub then return target.name .. " › " .. target.sub end
        return target.name
    end

    local function showDialog()
        -- No filename. It is built as "<title> - <author>.<format>", which for anything with a
        -- long title runs to a paragraph, and this dialog already carries two buttons and the
        -- Wi-Fi toggle's own long label. The user tapped download on a specific book moments
        -- ago, so naming it back to them buys little for the height it costs.
        local full_text = T("Book downloaded successfully. Open it now?")

        local dialog
        local other_buttons = {}

        if has_wifi_toggle then
            table.insert(other_buttons, {
                {
                    text = turn_off_wifi and ("☑ " .. T("Turn off Wi-Fi after closing this dialog")) or ("☐ " .. T("Turn off Wi-Fi after closing this dialog")),
                    callback = function()
                        turn_off_wifi = not turn_off_wifi
                        Config.setTurnOffWifiAfterDownload(turn_off_wifi)
                        _closeAndUntrackDialog(dialog)
                        showDialog()
                    end,
                },
            })
        end

        if has_categories then
            table.insert(other_buttons, {
                {
                    -- No checkbox: this is not a toggle, it opens a chooser. Always name the
                    -- destination -- the download folder by default -- so where the book goes is
                    -- never hidden behind an empty "Move to…".
                    text = string.format(T("Move to: %s"), targetLabel(chosen_target)),
                    callback = function()
                        -- Close this dialog, choose a target, then re-render it -- the same
                        -- close-and-reopen the Wi-Fi toggle above uses. Dismissing the chooser
                        -- reopens this dialog with the choice untouched.
                        _closeAndUntrackDialog(dialog)
                        Ui._showCategoryChooser(categories, chosen_target,
                            function(new_target)
                                chosen_target = new_target
                                showDialog()
                            end,
                            function()
                                showDialog()
                            end)
                    end,
                },
            })
        end

        -- Keep other_buttons nil when empty so ConfirmBox renders exactly as it did before.
        if #other_buttons == 0 then other_buttons = nil end

        dialog = ConfirmBox:new{
            text = full_text,
            ok_text = T("Open book"),
            ok_callback = function()
                ok_open_callback(turn_off_wifi, chosen_target)
            end,
            cancel_text = T("Close"),
            cancel_callback = function()
                cancel_callback(turn_off_wifi, chosen_target)
            end,
            other_buttons = other_buttons,
            other_buttons_first = true,
        }

        _showAndTrackDialog(dialog)
    end

    showDialog()
end

function Ui.showSimilarBooksMenu(ui_self, books, plugin_self, source_title)
    local opts = Config.getViewSettings()
    local show_cover = opts.show_cover_search ~= false
    books = books or {}

    local menu_items = {}
    local menu_item
    for _, book in ipairs(books) do
        menu_item = Ui.createBookMenuItem(book, plugin_self, show_cover)
        menu_item.callback = function()
                plugin_self:onSelectRecommendedBook(book)
        end
        table.insert(menu_items, menu_item)
    end

    if #menu_items == 0 then
       Ui.showInfoMessage(string.format(T("No %s found, please try again. Sometimes this requires a couple of retries."), "similar books"))
        return
    end
    
    local menu = Menu:new({
        title = T("Z-library Similar Books"),
        subtitle = source_title,
        item_table = menu_items,
        show_captions = true,
        parent = ui_self.document_menu_parent_holder,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        multilines_forced = true,
        multilines_show_more_text = false,
        list_per_page =opts and opts.search_per_page,
        show_cover = show_cover,
    })
    _showAndTrackDialog(menu)
end

function Ui.createSingleBookMenu(ui_self, title, menu_items)
    local menu = Menu:new{
        title = title or T("Book Details"),
        show_parent_menu = true,
        parent_menu_text = T("Back"),
        item_table = menu_items,
        parent = ui_self.view,
        items_per_page = 10,
        show_captions = true,
    }
    _showAndTrackDialog(menu)
    return menu
end

return Ui
