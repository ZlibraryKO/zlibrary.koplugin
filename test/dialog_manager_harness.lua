-- Does DialogManager stop tracking a dialog once that dialog is gone?
--
-- showInfoMessage/showErrorMessage hand the user an InfoMessage with a timeout, and an
-- InfoMessage closes ITSELF -- on timeout, on a tap, on the back key. None of those paths went
-- through closeAndUntrackDialog, so every one of them left a dead widget in _open_dialogs:
-- getDialogCount lied, and closeAllDialogs re-closed widgets that were already gone. The fix
-- untracks from the widget's dismiss_callback, which InfoMessage.onCloseWidget fires on every
-- close path, and trackDialog now refuses to track the same dialog twice.
--
-- A ConfirmBox has the same leak shape -- its OK/Cancel buttons self-close -- but no
-- dismiss_callback hook, so showConfirmDialog wraps the widget's onCloseWidget instead, and the
-- wrap must chain to the class's own onCloseWidget rather than replace it.
--
-- The stubs below emulate KOReader's side of the contract rather than transcribing the fix:
-- UIManager:close dispatches CloseWidget to the widget (uimanager.lua), and InfoMessage's
-- onCloseWidget fires dismiss_callback (infomessage.lua). If the plugin's untracking stopped
-- hanging off that hook, these checks fail.

local PLUGIN = assert(arg[1], "usage: luajit dialog_manager_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
support.preload_koreader_stubs()
local r = support.reporter()

-- UIManager:close(widget) sends CloseWidget to the widget; the widget's onCloseWidget is where
-- InfoMessage runs its dismiss_callback. Recording closes lets a check prove a dead widget was
-- not closed a second time.
local closed = {}
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        close = function(_, widget)
            table.insert(closed, widget)
            if type(widget) == "table" and widget.onCloseWidget then
                widget:onCloseWidget()
            end
        end,
    }
end

-- Mirrors infomessage.lua: onCloseWidget fires dismiss_callback, and a plain InfoMessage
-- (is_infomessage unset -- only Trapper sets that) drops the callback after firing it once.
package.preload["ui/widget/infomessage"] = function()
    local InfoMessage = {}
    InfoMessage.__index = InfoMessage
    function InfoMessage:new(o)
        o = o or {}
        setmetatable(o, self)
        o.modal = true
        return o
    end
    function InfoMessage:onCloseWidget()
        if self.dismiss_callback then
            self.dismiss_callback()
            self.dismiss_callback = nil
        end
    end
    return InfoMessage
end

-- Mirrors confirmbox.lua: the OK and Cancel button callbacks end in UIManager:close(self), and
-- the class has its own onCloseWidget (a repaint) that a tracking hook must chain to, not
-- replace. pressOk/pressCancel stand in for the ButtonTable callbacks.
package.preload["ui/widget/confirmbox"] = function()
    local ConfirmBox = {}
    ConfirmBox.__index = ConfirmBox
    function ConfirmBox:new(o)
        o = o or {}
        setmetatable(o, self)
        o.modal = true
        o.cancel_callback = o.cancel_callback or function() end
        return o
    end
    function ConfirmBox:onCloseWidget()
        self.inherited_close_runs = (self.inherited_close_runs or 0) + 1
    end
    function ConfirmBox:pressOk()
        if self.ok_callback then self.ok_callback() end
        require("ui/uimanager"):close(self)
    end
    function ConfirmBox:pressCancel()
        self.cancel_callback()
        require("ui/uimanager"):close(self)
    end
    return ConfirmBox
end

local UIManager = require("ui/uimanager")
local DialogManager = dofile(PLUGIN .. "/zlibrary/dialog_manager.lua")

local mgr = DialogManager:new()

-- --- the leak: an auto-closing InfoMessage must untrack itself when it closes -------------

local info = mgr:showInfoMessage("hello")
r.check("info message is tracked while open", mgr:getDialogCount() == 1,
        "count = " .. mgr:getDialogCount())
r.check("info message carries a close hook", type(info.dismiss_callback) == "function",
        "dismiss_callback = " .. type(info.dismiss_callback))

-- The timeout path: InfoMessage's scheduled function calls UIManager:close(self).
UIManager:close(info)
r.check("timeout close untracks the dialog", mgr:getDialogCount() == 0,
        "count = " .. mgr:getDialogCount())

-- The tap-to-dismiss path closes the same way, so it is covered by the same hook; what matters
-- next is that nothing double-counts afterwards. Before the fix the dead widget stayed tracked
-- and the count kept growing.
local second = mgr:showInfoMessage("again")
r.check("a later message counts once, not on top of the dead one", mgr:getDialogCount() == 1,
        "count = " .. mgr:getDialogCount())
UIManager:close(second)

local err = mgr:showErrorMessage("boom")
r.check("error message is tracked while open", mgr:getDialogCount() == 1,
        "count = " .. mgr:getDialogCount())
UIManager:close(err)
r.check("error message untracks on close too", mgr:getDialogCount() == 0,
        "count = " .. mgr:getDialogCount())

-- --- the same leak, ConfirmBox edition: a ConfirmBox closes itself from its own buttons -----
--
-- ConfirmBox has no dismiss_callback, so showConfirmDialog untracks by wrapping the widget's
-- onCloseWidget. The wrap must (a) untrack on either button's self-close and (b) still run the
-- class's own onCloseWidget -- replacing it would drop the repaint.

local ok_ran = false
local confirm = mgr:showConfirmDialog({ text = "sure?", ok_callback = function() ok_ran = true end })
r.check("confirm dialog is tracked while open", mgr:getDialogCount() == 1,
        "count = " .. mgr:getDialogCount())
confirm:pressOk()
r.check("OK ran its callback", ok_ran == true)
r.check("OK self-close untracks the dialog", mgr:getDialogCount() == 0,
        "count = " .. mgr:getDialogCount())
r.check("the wrapped onCloseWidget still chains to the inherited one",
        confirm.inherited_close_runs == 1,
        "inherited runs = " .. tostring(confirm.inherited_close_runs))

local cancel_ran = false
local confirm2 = mgr:showConfirmDialog({ text = "sure?", cancel_callback = function() cancel_ran = true end })
confirm2:pressCancel()
r.check("Cancel self-close untracks the dialog too",
        cancel_ran == true and mgr:getDialogCount() == 0,
        "cancel_ran = " .. tostring(cancel_ran) .. ", count = " .. mgr:getDialogCount())

-- --- dedupe: tracking the same dialog twice must not double-count ---------------------------

local dialog = { modal = true }
mgr:trackDialog(dialog)
mgr:trackDialog(dialog)
r.check("trackDialog ignores a dialog it already tracks", mgr:getDialogCount() == 1,
        "count = " .. mgr:getDialogCount())
mgr:untrackDialog(dialog)
r.check("the single tracked copy untracks cleanly", mgr:getDialogCount() == 0,
        "count = " .. mgr:getDialogCount())

-- --- closeAllDialogs must not re-close a widget that already closed itself ------------------

local ghost = mgr:showInfoMessage("ghost")
UIManager:close(ghost) -- closed on its own; correctly untracked now
local live = mgr:showAndTrackDialog({ modal = true })
local closes_before = #closed
mgr:closeAllDialogs()
r.check("closeAllDialogs empties the tracker", mgr:getDialogCount() == 0,
        "count = " .. mgr:getDialogCount())
r.check("closeAllDialogs closed only the live dialog",
        #closed - closes_before == 1 and closed[#closed] == live,
        "closed " .. (#closed - closes_before) .. " dialogs")

-- --- closeAllDialogs stays defensive when UIManager:close raises ----------------------------

local broken = { modal = true, onCloseWidget = function() error("device gone") end }
mgr:trackDialog(broken)
local ok = pcall(function() mgr:closeAllDialogs() end)
r.check("a raising close is contained by the pcall", ok and mgr:getDialogCount() == 0,
        "ok = " .. tostring(ok) .. ", count = " .. mgr:getDialogCount())

-- --- _isDialogValid: honest now that no widget ever sets is_closed/is_destroyed -------------

r.check("a widget-shaped table is valid", mgr:_isDialogValid({ modal = true }) == true)
r.check("a plain table is not a dialog", mgr:_isDialogValid({}) == false)
r.check("nil is not a dialog", mgr:_isDialogValid(nil) == false)
r.check("a non-table is not a dialog", mgr:_isDialogValid("dialog") == false)

r.finish()
