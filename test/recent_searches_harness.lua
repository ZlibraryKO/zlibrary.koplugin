-- The recent-searches list: what does tapping, holding and going back do?
--
-- Tapping an entry fills the search box with it rather than running it. The history keeps only the
-- words, not the Content (books or articles), language or format choice they were searched with,
-- so running straight away could quietly search something else than last time; in the box, the
-- dialog shows what it would run with, and the query can be refined first. Holding removes the
-- entry, and going back returns to the search box with whatever had been typed there. Also: the
-- search dialog, which has no Cancel button, still closes on Back.
--
-- Drives the real Ui.showSearchHistoryDialog with a stub Menu, so the items and handlers checked
-- are the ones the widget would get.

local PLUGIN = assert(arg[1], "usage: luajit recent_searches_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local block = support.extract_block(support.ui_files(PLUGIN),
    "(\nfunction Ui%.showSearchHistoryDialog%(.-\nend\n)")

local history, menu, searched, reopened_with, closed
local function make()
    local Ui = {
        showSearchDialog = function(_, input) reopened_with = input end,
    }
    local env = {
        Ui = Ui, ipairs = ipairs,
        T = function(s) return s end,
        UIManager = { close = function(_, m) closed = m end, show = function() end },
        ConfirmBox = { new = function(_, spec) return spec end },
        Config = {
            getSearchHistory = function() return history end,
            removeSearchHistory = function(q)
                for i, h in ipairs(history) do if h == q then table.remove(history, i) break end end
            end,
        },
        table = table,
        Menu = { new = function(_, spec)
            menu = spec
            spec.switchItemTable = function(self, _, items) self.item_table = items end
            return spec
        end },
        _showAndTrackDialog = function() end,
    }
    local chunk = assert(loadstring(block, "=showSearchHistoryDialog"))
    setfenv(chunk, env)
    chunk()
    return Ui
end

local function fresh(entries)
    history = entries
    menu, searched, reopened_with, closed = nil, nil, nil, nil
    local Ui = make()
    local plugin = { performSearch = function(_, q) searched = q end }
    Ui.showSearchHistoryDialog(plugin, "typed so far")
    return Ui
end

-- ---------------------------------------------------------------- tap fills the box
do
    local Ui = fresh({ "dune", "attention" })
    menu.item_table[2].callback()
    r.check("tapping an entry does not run a search", searched == nil, "searched " .. tostring(searched))
    r.check("it reopens the search box with that entry", reopened_with == "attention",
            "reopened with " .. tostring(reopened_with))
    r.check("the list is closed first", closed == menu, "closed " .. tostring(closed))
    r.check("the entry becomes the session's last search input", Ui._last_search_input == "attention",
            "last input " .. tostring(Ui._last_search_input))
end

-- ---------------------------------------------------------------- hold removes
do
    fresh({ "dune", "attention" })
    menu:onMenuHold(menu.item_table[1])
    r.check("holding an entry removes it", #history == 1 and history[1] == "attention",
            "history now " .. table.concat(history, ","))
    r.check("and keeps the list open with what is left", reopened_with == nil
            and menu.item_table[1].query == "attention", "list not refreshed")
    menu:onMenuHold(menu.item_table[1])
    r.check("removing the last entry returns to the search box with the typed text",
            #history == 0 and reopened_with == "typed so far", "reopened with " .. tostring(reopened_with))
end

-- ---------------------------------------------------------------- back
do
    fresh({ "dune" })
    menu.onClose()
    r.check("going back returns to the search box with the typed text", reopened_with == "typed so far",
            "reopened with " .. tostring(reopened_with))
    r.check("without searching", searched == nil, "searched " .. tostring(searched))
end

-- ---------------------------------------------------------------- closing the search dialog
-- It has no Cancel button; the title bar's cross replaces it. InputDialog closes on the Back key
-- and on a tap outside by running a button with id "close", which no longer exists, so the dialog
-- must close itself there -- or Back would do nothing.
do
    local close_block = support.extract_block(support.ui_files(PLUGIN),
        "(\nfunction SearchInputDialog:onCloseDialog%(.-\nend\n)")
    local fell_back = false
    local SearchInputDialog = {}
    local chunk = assert(loadstring("local SearchInputDialog = ...\n" .. close_block, "=onCloseDialog"))
    setfenv(chunk, { InputDialog = { onCloseDialog = function() fell_back = true; return false end } })
    chunk(SearchInputDialog)

    local closed_by = nil
    local dialog = { on_close = function() closed_by = "on_close" end }
    local handled = SearchInputDialog.onCloseDialog(dialog)
    r.check("Back (onCloseDialog) closes the search dialog", closed_by == "on_close" and handled == true,
            "closed_by=" .. tostring(closed_by) .. " handled=" .. tostring(handled))
    r.check("without needing a close button", not fell_back, "fell back to InputDialog's button lookup")

    local src = ""
    for _, file in ipairs(support.ui_files(PLUGIN)) do
        local fh = io.open(file); src = src .. fh:read("*a"); fh:close()
    end
    local dialog_src = src:match("\nfunction Ui%.showSearchDialog%(.-\nend\n") or ""
    r.check("the search dialog has no Cancel button", dialog_src ~= ""
            and not dialog_src:find('T("Cancel")', 1, true) and not dialog_src:find('id = "close"', 1, true),
            "Cancel or a close-id button is still built")
    r.check("the search dialog passes on_close", dialog_src:find("on_close = function()", 1, true) ~= nil,
            "no on_close given, so Back and the cross would do nothing")
end

r.finish()
