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
local ui_src = support.read_ui(PLUGIN)

local DONATION_URL = ui_src:match('\nlocal DONATION_URL = "([^"]+)"')
assert(DONATION_URL, "no DONATION_URL constant in ui_core.lua -- the dialog has nowhere to point")

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

for _, name in ipairs{ "showDonationQrCode", "showAboutDialog", "showUpdateInstalledDialog" } do
    local block = support.extract_block(support.ui_files(PLUGIN),
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

-- ---------------------------------------------------------------- after an update installs
-- The plugin's second and last mention of support, and the only one that interrupts anybody. It
-- has to keep saying the thing the reader actually needs first: which version runs until when.
rig.confirm, rig.shown = nil, nil
env.Ui.showUpdateInstalledDialog({ installed = "9.9.9", running = "9.9.8", just_installed = true })
local said = rig.confirm and rig.confirm.text or ""
r.check("the update dialog still leads with what happens next",
        said:find("9.9.9", 1, true) ~= nil and said:find("KOReader restarts", 1, true) ~= nil
            and said:find("KOReader restarts", 1, true) < (said:find(DONATION_URL, 1, true) or 0),
        "the ask was put in front of what the reader has to know")
r.check("and says the running version stays in use until then",
        said:find("you keep using 9.9.8", 1, true) ~= nil, "no word that the reader can carry on")
r.check("and points at the same address as the About screen",
        said:find(DONATION_URL, 1, true) ~= nil, "a second address crept in")
r.check("it waits to be dismissed rather than timing out",
        rig.confirm.cancel_text ~= nil and rig.confirm.no_ok_button == true,
        "a restart instruction that vanishes on a timer")

local qr_button = rig.confirm.other_buttons and rig.confirm.other_buttons[1]
        and rig.confirm.other_buttons[1][1]
r.check("with the QR on its own row above the dismiss button",
        type(qr_button) == "table" and type(qr_button.callback) == "function"
            and rig.confirm.other_buttons_first == true,
        "no QR button, or it was placed below the way out")
r.check("and no Restart now when the caller gave no restart",
        #rig.confirm.other_buttons == 1, "a restart button nobody asked for")

qr_button.callback()
r.check("and that QR encodes the same address too",
        type(rig.shown) == "table" and rig.shown.text == DONATION_URL,
        "QR points at " .. tostring(rig.shown and rig.shown.text))

-- ---------------------------------------------------------------- with Restart now
local restarted = 0
rig.confirm = nil
env.Ui.showUpdateInstalledDialog({ installed = "9.9.9", running = "9.9.8", just_installed = true,
    restart = function() restarted = restarted + 1 end })
local rows = rig.confirm and rig.confirm.other_buttons or {}
local restart_button = rows[1] and rows[1][1]
r.check("Restart now comes first, the QR row after it",
        #rows == 2 and restart_button and restart_button.text == "Restart now"
            and rows[2][1].text == "Show QR code",
        "rows: " .. tostring(#rows))
if restart_button then restart_button.callback() end
r.check("and runs the restart it was given", restarted == 1, "tapped " .. restarted .. " times")

-- ---------------------------------------------------------------- the reminder
-- From "Check for updates" before the restart: the same facts, without the ask.
rig.confirm = nil
env.Ui.showUpdateInstalledDialog({ installed = "9.9.9", running = "9.9.8",
    restart = function() end })
said = rig.confirm and rig.confirm.text or ""
r.check("the reminder repeats which version starts when",
        said:find("9.9.9", 1, true) ~= nil and said:find("9.9.8", 1, true) ~= nil,
        "reminder: " .. said)
r.check("but asks for nothing",
        said:find(DONATION_URL, 1, true) == nil and #rig.confirm.other_buttons == 1,
        "the support ask showed up outside the install moment")
r.check("and has its own title", rig.confirm.title == "Restart to update",
        "title " .. tostring(rig.confirm.title))

-- ---------------------------------------------------------------- while a book downloads
rig.confirm = nil
env.Ui.showUpdateInstalledDialog({ installed = "9.9.9", download_active = true })
said = rig.confirm and rig.confirm.text or ""
r.check("a running download is named, with no restart button",
        said:find("download is running", 1, true) ~= nil and rig.confirm.other_buttons == nil,
        "text: " .. said)
r.check("an unknown running version leaves the second sentence out",
        said:find("you keep using", 1, true) == nil, "text: " .. said)

r.finish()
