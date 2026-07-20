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
local function build()
    local Ui = {}
    local env = {
        Ui = Ui,
        string = string,
        T = function(s) return s end,
        Config = {
            getSkipOpenBookPrompt = function() return skip_setting end,
            setTurnOffWifiAfterDownload = function() end,
        },
        ConfirmBox = { new = function(_, spec) dialog_spec = spec; return spec end },
        UIManager = { show = function() end, close = function() end },
        _plugin_instance = nil,
        _showAndTrackDialog = function(d) dialog_spec = d end,
    }
    env.Ui.showInfoMessage = function(text) shown = text end
    local chunk = assert(loadstring(block, "=confirmOpenBook"))
    setfenv(chunk, env)
    chunk()
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
r.check("prompt on: it names the file",
        on.dialog and tostring(on.dialog.text):find("Dune.epub", 1, true) ~= nil,
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

r.finish()
