-- What happens after a download finishes, with and without the prompt?
--
-- A user asked to be able to switch off the "downloaded successfully, open it now?" dialog,
-- which is fair when downloading several books in a row. Two things must survive that, and
-- neither is obvious from the request.
--
-- The dialog is also where the "turn off Wi-Fi after closing" toggle lives, so skipping it has
-- to act on the stored preference rather than quietly leave the radio on. And it is the only
-- sign most people get that a download worked, so replacing it with nothing would trade one
-- complaint for a worse one.
--
-- Drives the real Ui.confirmOpenBook, so the suppressed path is exercised rather than described.

local PLUGIN = assert(arg[1], "usage: luajit open_prompt_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local block = support.extract_block(PLUGIN .. "/zlibrary/ui.lua",
    "(\nfunction Ui%.confirmOpenBook%(.-\nend\n)")

-- Rebuild against stubs that record what the function reached for.
local shown, dialog_spec, skip_setting
local last_Ui
local function build()
    local Ui = {}
    local env = {
        Ui = Ui,
        string = string,
        table = table,
        type = type,
        ipairs = ipairs,
        T = function(s) return s end,
        Config = {
            getSkipOpenBookPrompt = function() return skip_setting end,
            setTurnOffWifiAfterDownload = function() end,
        },
        ConfirmBox = { new = function(_, spec) dialog_spec = spec; return spec end },
        UIManager = { show = function() end, close = function() end },
        _plugin_instance = nil,
        _showAndTrackDialog = function(d) dialog_spec = d end,
        _closeAndUntrackDialog = function() end,
    }
    env.Ui.showInfoMessage = function(text) shown = text end
    local chunk = assert(loadstring(block, "=confirmOpenBook"))
    setfenv(chunk, env)
    chunk()
    last_Ui = Ui
    return Ui.confirmOpenBook
end

local confirmOpenBook = build()
r.check("the function was recovered from ui.lua", type(confirmOpenBook) == "function",
        "got " .. type(confirmOpenBook))

local function run(skip, wifi_pref)
    shown, dialog_spec, skip_setting = nil, nil, skip
    local opened, cancelled, cancelled_with = false, false, nil
    confirmOpenBook("Dune.epub", true, wifi_pref,
        function() opened = true end,
        function(w) cancelled = true; cancelled_with = w end)
    return { opened = opened, cancelled = cancelled, wifi = cancelled_with,
             notified = shown, dialog = dialog_spec }
end

-- ---------------------------------------------------------------- prompt on (the default)
local on = run(false, false)
r.check("prompt on: a dialog is built", on.dialog ~= nil, "no ConfirmBox")
-- Deliberately does NOT name the file. Filenames here are "<title> - <author>.<format>" and
-- run long, and this dialog already carries two buttons plus the Wi-Fi toggle's own label.
r.check("prompt on: it says the download succeeded",
        on.dialog and tostring(on.dialog.text):find("downloaded successfully", 1, true) ~= nil,
        "text = " .. tostring(on.dialog and on.dialog.text))
r.check("prompt on: it does not repeat the filename",
        on.dialog and tostring(on.dialog.text):find("Dune.epub", 1, true) == nil,
        "text = " .. tostring(on.dialog and on.dialog.text))
r.check("prompt on: it offers to open the book",
        on.dialog and on.dialog.ok_text ~= nil, "no ok_text")
r.check("prompt on: nothing decided before the user answers",
        not on.opened and not on.cancelled, "a callback fired unprompted")

-- ---------------------------------------------------------------- prompt off
local off = run(true, false)
r.check("prompt off: no dialog is built", off.dialog == nil, "a ConfirmBox was still created")
r.check("prompt off: the book is NOT opened", not off.opened,
        "opened the book without being asked")
r.check("prompt off: the download is still reported", off.notified ~= nil,
        "finished silently")
r.check("prompt off: the report names the file",
        off.notified and tostring(off.notified):find("Dune.epub", 1, true) ~= nil,
        "message = " .. tostring(off.notified))

-- The finish path still runs, because it is also what closes things down.
r.check("prompt off: the finish path still runs", off.cancelled, "cancel_callback never fired")

-- Wi-Fi is left alone, and that does not depend on the preference. "Turn off Wi-Fi after
-- closing this dialog" has no meaning when no dialog appears, and the toggle for it lives on
-- that same dialog -- so honouring it here would keep a background action running that the user
-- can neither see nor change.
r.check("prompt off: Wi-Fi untouched when the preference is off",
        off.wifi == false, "passed " .. tostring(off.wifi))

local off_wifi = run(true, true)
r.check("prompt off: Wi-Fi untouched even when the preference is on",
        off_wifi.wifi == false,
        "passed " .. tostring(off_wifi.wifi) .. " -- the radio would be switched off invisibly")
r.check("prompt off: still reported with the Wi-Fi preference on",
        off_wifi.notified ~= nil, "silent")

-- ---------------------------------------------------------------- the two paths, contrasted
-- With the prompt shown, the preference is honoured as it always was: the checkbox is right
-- there and the user is looking at it. With the prompt skipped, it is not. Assert both, so the
-- difference stays a decision rather than becoming a bug either way.
for _, pref in ipairs({ false, true }) do
    shown, dialog_spec, skip_setting = nil, nil, false
    local via_dialog
    confirmOpenBook("Dune.epub", true, pref, function() end, function(w) via_dialog = w end)
    local spec = dialog_spec
    r.check("prompt on: a Close action exists (pref=" .. tostring(pref) .. ")",
            spec and type(spec.cancel_callback) == "function", "no cancel_callback")
    if spec and spec.cancel_callback then spec.cancel_callback() end
    r.check("prompt on: the preference is honoured (pref=" .. tostring(pref) .. ")",
            via_dialog == pref,
            "dialog passed " .. tostring(via_dialog) .. " for preference " .. tostring(pref))

    local via_skip = run(true, pref).wifi
    r.check("prompt off: the preference is not acted on (pref=" .. tostring(pref) .. ")",
            via_skip == false, "skip passed " .. tostring(via_skip))
end

-- ---------------------------------------------------------------- the setting itself
local cfg_src = (function()
    local fh = assert(io.open(PLUGIN .. "/zlibrary/config.lua"))
    local s = fh:read("*a"); fh:close(); return s
end)()
r.check("the setting defaults to asking",
        cfg_src:find("SETTINGS_SKIP_OPEN_BOOK_PROMPT_KEY, false", 1, true) ~= nil,
        "default is not false -- the prompt would vanish for everyone on upgrade")

local main_src = (function()
    local fh = assert(io.open(PLUGIN .. "/main.lua"))
    local s = fh:read("*a"); fh:close(); return s
end)()
r.check("the setting is reachable from the menu",
        main_src:find("getSkipOpenBookPrompt", 1, true) ~= nil
            and main_src:find("setSkipOpenBookPrompt", 1, true) ~= nil,
        "no menu entry reads or writes it")

-- ---------------------------------------------------------------- filing into a category
local function find_button(spec, needle)
    if not spec or not spec.other_buttons then return nil end
    for _, row in ipairs(spec.other_buttons) do
        for _, btn in ipairs(row) do
            if type(btn.text) == "string" and btn.text:find(needle, 1, true) then
                return btn
            end
        end
    end
    return nil
end

-- With no categories configured the dialog is unchanged: there is no "Move to" row, whether the
-- argument is omitted (nil) or an empty list.
shown, dialog_spec, skip_setting = nil, nil, false
confirmOpenBook("Dune.epub", true, false, function() end, function() end, nil)
r.check("no categories (nil): no Move to row",
        find_button(dialog_spec, "Move to") == nil, "a Move to button appeared")

shown, dialog_spec, skip_setting = nil, nil, false
confirmOpenBook("Dune.epub", true, false, function() end, function() end, {})
r.check("no categories (empty): no Move to row",
        find_button(dialog_spec, "Move to") == nil, "a Move to button appeared")

-- With categories the row appears, and choosing a target surfaces it to BOTH callbacks -- the point
-- being that "Close" (don't open) files the book just as "Open book" does.
local categories = { { name = "Fiction", children = { "Romance" } } }
local picked = { name = "Fiction", sub = "Romance" }

shown, dialog_spec, skip_setting = nil, nil, false
local ok_target, cancel_target
confirmOpenBook("Dune.epub", true, false,
    function(_, t) ok_target = t end,
    function(_, t) cancel_target = t end,
    categories)

local file_btn = find_button(dialog_spec, "Move to")
r.check("categories: a Move to row appears", file_btn ~= nil, "no Move to button")

-- Stub the chooser so tapping the row selects a target and the dialog re-renders.
local chooser_categories
last_Ui._showCategoryChooser = function(cats, _current, on_pick)
    chooser_categories = cats
    on_pick(picked)
end
if file_btn then file_btn.callback() end
r.check("categories: the chooser is handed the category list",
        chooser_categories == categories, "wrong list passed to the chooser")
r.check("categories: the Move to row updates to the chosen target",
        find_button(dialog_spec, "Fiction › Romance") ~= nil,
        "row did not reflect the choice")

if dialog_spec then dialog_spec.ok_callback() end
r.check("categories: Open passes the chosen target",
        ok_target ~= nil and ok_target.name == "Fiction" and ok_target.sub == "Romance",
        "ok target = " .. tostring(ok_target))
if dialog_spec then dialog_spec.cancel_callback() end
r.check("categories: Close also passes the chosen target",
        cancel_target ~= nil and cancel_target.name == "Fiction" and cancel_target.sub == "Romance",
        "cancel target = " .. tostring(cancel_target))

-- The skip-prompt path never files: with categories present the finish path still runs, but its
-- second argument stays nil so download.lua leaves the book in the download folder.
shown, dialog_spec, skip_setting = nil, nil, true
local skip_cancel_called, skip_cancel_target
confirmOpenBook("Dune.epub", true, false,
    function() end,
    function(_, t) skip_cancel_called = true; skip_cancel_target = t end,
    { { name = "Fiction", children = {} } })
r.check("skip-prompt with categories: no dialog is built", dialog_spec == nil, "a dialog was built")
r.check("skip-prompt with categories: the finish path still runs", skip_cancel_called,
        "cancel_callback never fired")
r.check("skip-prompt with categories: nothing is filed", skip_cancel_target == nil,
        "a target leaked through the skip path: " .. tostring(skip_cancel_target))

r.finish()
