-- The About dialog, and the one invariant that matters in it.
--
-- It is the plugin's only mention of donations, and the only screen that can lead anywhere off the
-- device: a URL cannot be followed on an e-reader, so the QR code is the path a reader actually
-- takes. The address printed in the dialog and the address encoded in that QR therefore have to be
-- the same string -- a QR that quietly points somewhere else than the text above it is worse than
-- having neither.
--
-- Both functions are driven for real, with the URL read out of the source rather than invented
-- here, so changing the constant moves the test with it while hardcoding a second address
-- anywhere fails it.

local PLUGIN = assert(arg[1], "usage: luajit about_dialog_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local function read(path) local fh = assert(io.open(path)); local s = fh:read("*a"); fh:close(); return s end
local ui_src = read(PLUGIN .. "/zlibrary/ui.lua")

local DONATION_URL = ui_src:match('\nlocal DONATION_URL = "([^"]+)"')
assert(DONATION_URL, "no DONATION_URL constant in ui.lua -- the dialog has nowhere to point")

local rig = { shown = nil, confirm = nil, untracked = {} }

local env = {
    type = type, table = table, string = string, math = math, tostring = tostring,
    T = function(s) return s end,
    Device = { screen = { getWidth = function() return 1236 end, getHeight = function() return 1648 end } },
    DONATION_URL = DONATION_URL,
    require = function(mod)
        assert(mod == "ui/widget/qrmessage", "unexpected require: " .. tostring(mod))
        return { new = function(_, spec) return spec end }
    end,
    UIManager = { show = function(_, w) rig.shown = w end },
    ConfirmBox = { new = function(_, spec) return spec end },
    _showAndTrackDialog = function(dialog) rig.shown = dialog return dialog end,
}
env._plugin_instance = {
    dialog_manager = {
        showConfirmDialog = function(_, spec) rig.confirm = spec return spec end,
        untrackOnClose = function(_, dialog) table.insert(rig.untracked, dialog) end,
    },
}
env.Ui = {}

for _, name in ipairs{ "showDonationQrCode", "showAboutDialog" } do
    local block = support.extract_block(PLUGIN .. "/zlibrary/ui.lua",
        "(\nfunction Ui%." .. name .. "%(.-\nend\n)")
    local chunk = assert(loadstring(block, "=Ui." .. name))
    setfenv(chunk, env)
    chunk()
end

-- ---------------------------------------------------------------- the dialog
env.Ui.showAboutDialog("1.0.51")
r.check("the About dialog opens", rig.confirm ~= nil and rig.confirm.text ~= nil, "no dialog built")
r.check("it names the running version",
        rig.confirm.text:find("1.0.51", 1, true) ~= nil,
        "the version is not shown, so a bug report cannot start with it")
r.check("and prints the donation address in full",
        rig.confirm.text:find(DONATION_URL, 1, true) ~= nil,
        "the address is missing from the text, leaving the QR as the only copy")
r.check("with a way to reach it that suits an e-ink screen",
        type(rig.confirm.ok_callback) == "function" and rig.confirm.ok_text ~= nil,
        "there is no button to raise the QR code")

-- ---------------------------------------------------------------- the QR
rig.shown = nil
rig.confirm.ok_callback()
r.check("the QR code encodes exactly the address that was printed",
        type(rig.shown) == "table" and rig.shown.text == DONATION_URL,
        "QR points at " .. tostring(rig.shown and rig.shown.text))
r.check("and is square, and fits the screen",
        rig.shown.width == rig.shown.height and rig.shown.width > 0 and rig.shown.width <= 1236,
        string.format("%sx%s on a 1236x1648 screen",
            tostring(rig.shown.width), tostring(rig.shown.height)))
r.check("it untracks itself when closed, so it cannot pile up",
        #rig.untracked == 1 and rig.untracked[1] == rig.shown,
        "a self-closing widget was tracked and never removed")

-- ---------------------------------------------------------------- an unknown version
rig.confirm = nil
local ok = pcall(env.Ui.showAboutDialog, nil)
r.check("a version that could not be read still opens the dialog",
        ok and rig.confirm ~= nil and rig.confirm.text:find(DONATION_URL, 1, true) ~= nil,
        "no version meant no dialog at all")

r.finish()
