-- Can a loading message crash KOReader?
--
-- It could, for anyone who also had appearance.koplugin installed: opening Most popular died with
-- "./luajit: stack overflow". The loading message asked InfoMessage for force_one_line, which
-- InfoMessage honours by shrinking its font and calling self:init() again until the text fits.
-- appearance.koplugin wraps InfoMessage.init and assigns its own font on every call -- the re-runs
-- included -- so each shrink was undone, the text never fit, and init recursed until the Lua stack
-- ran out. Any loading message too long for one line did it, and nearly all of them are.
--
-- Drives KOReader's real InfoMessage, from the checkout run.sh found, and the plugin's real
-- Ui.showLoadingMessage and Ui.showCancellableLoadingMessage. Only the leaf widgets are stubbed.
-- Text is measured with a rough model, half an em per character: the re-init depends only on
-- whether the text overflows a line, and these messages overflow by a wide margin.

local USAGE = "usage: luajit loading_message_harness.lua <plugin-root> <luasocket-src> <koreader-root>"
local PLUGIN = assert(arg[1], USAGE)
local KOREADER = assert(arg[3], USAGE)

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

-- ---------------------------------------------------------------- leaf widgets
-- A Kindle Paperwhite 5, with the scaling from base/ffi/framebuffer.lua (no DPI override).
local Screen = { w = 1236, h = 1648 }
function Screen:getWidth() return self.w end
function Screen:getHeight() return self.h end
function Screen:getSize() return { w = self.w, h = self.h } end
function Screen:scaleBySize(px) return math.ceil(px * math.min(self.w, self.h) / 600) end

local Font = { sizemap = { infofont = 24, infont = 22 } }
function Font:getFace(font, size)
    size = size or self.sizemap[font]
    return { orig_font = font, orig_size = size, size = Screen:scaleBySize(size) }
end

-- Widget:new and Widget:extend as in frontend/ui/widget/widget.lua.
local Widget = {}
function Widget:extend(o) o = o or {}; setmetatable(o, self); self.__index = self; return o end
function Widget:new(o)
    o = self:extend(o)
    if o._init then o:_init() end
    if o.init then o:init() end
    return o
end
function Widget:free() end
function Widget:getSize() return { w = 0, h = 0 } end

local InputContainer = Widget:extend{}
function InputContainer:_init()
    if not rawget(self, "key_events") then self.key_events = {} end
    if not rawget(self, "ges_events") then self.ges_events = {} end
end

local function utf8_len(s)
    local n = 0
    for _ in s:gmatch("[^\128-\191]") do n = n + 1 end
    return n
end

local TextBoxWidget = Widget:extend{}
function TextBoxWidget:init()
    local em = self.face.size
    self.line_height_px = math.floor(em * 1.3)
    local lines, widest = 0, 0
    for para in (self.text .. "\n"):gmatch("(.-)\n") do
        local w = utf8_len(para) * em / 2
        widest = math.max(widest, math.min(w, self.width))
        lines = lines + math.max(1, math.ceil(w / self.width))
    end
    self.size = { w = widest, h = lines * self.line_height_px }
end
function TextBoxWidget:getSize() return self.size end
function TextBoxWidget:getLineHeight() return self.line_height_px end

local HorizontalSpan = Widget:extend{}
function HorizontalSpan:getSize() return { w = self.width, h = 0 } end

local HorizontalGroup = Widget:extend{}
function HorizontalGroup:getSize()
    local w, h = 0, 0
    for _, child in ipairs(self) do
        local s = child:getSize()
        w, h = w + s.w, math.max(h, s.h)
    end
    return { w = w, h = h }
end

local FrameContainer = Widget:extend{ bordersize = 2, padding = 10 }
function FrameContainer:getSize()
    local s = self[1]:getSize()
    local edge = 2 * (self.bordersize + self.padding)
    return { w = s.w + edge, h = s.h + edge }
end

local shown
local UIManager = {
    show = function(_, widget) shown = widget end,
    close = function() end,
    setDirty = function() end,
    scheduleIn = function() end,
    unschedule = function() end,
}

local stubs = {
    ["ffi/blitbuffer"] = { COLOR_WHITE = 0 },
    ["device"] = {
        hasKeys = function() return true end,
        isTouchDevice = function() return true end,
        input = { group = { Any = {} } },
        screen = Screen,
    },
    ["gettext"] = function(s) return s end,
    ["ui/font"] = Font,
    ["ui/geometry"] = { new = function(_, t) return t end },
    ["ui/gesturerange"] = { new = function(_, t) return t end },
    ["ui/size"] = { radius = { window = 7 }, span = { horizontal_default = 12 } },
    ["ui/uimanager"] = UIManager,
    ["ui/widget/container/centercontainer"] = Widget:extend{},
    ["ui/widget/container/framecontainer"] = FrameContainer,
    ["ui/widget/container/inputcontainer"] = InputContainer,
    ["ui/widget/container/movablecontainer"] = Widget:extend{},
    ["ui/widget/container/widgetcontainer"] = Widget:extend{},
    ["ui/widget/horizontalgroup"] = HorizontalGroup,
    ["ui/widget/horizontalspan"] = HorizontalSpan,
    ["ui/widget/iconwidget"] = Widget:extend{},
    ["ui/widget/imagewidget"] = Widget:extend{},
    ["ui/widget/scrolltextwidget"] = TextBoxWidget,
    ["ui/widget/textboxwidget"] = TextBoxWidget,
}
for name, mod in pairs(stubs) do
    package.preload[name] = function() return mod end
end

-- ---------------------------------------------------------------- the real InfoMessage
local InfoMessage = dofile(KOREADER .. "/frontend/ui/widget/infomessage.lua")

local init_calls = 0
local koreader_init = InfoMessage.init
local function counted_init(self)
    init_calls = init_calls + 1
    return koreader_init(self)
end

-- appearance.koplugin's override, from its ui/font_face.lua, installed over a fresh counter each
-- time so overrides do not stack up between checks. Only the font file is fixed here; upstream
-- reads it from the user's setting.
local function install_face_override()
    InfoMessage.init = counted_init
    local original_InfoMessage_init = InfoMessage.init
    function InfoMessage:init()
        local def_face = Font:getFace("infofont")
        local orig_size = def_face.orig_size or 22
        self.face = Font:getFace("Lato-Regular.ttf", orig_size)
        original_InfoMessage_init(self)
    end
end

local function attempt(fn)
    init_calls, shown = 0, nil
    local ok, err = pcall(fn)
    return ok, tostring(err)
end

-- ---------------------------------------------------------------- the real plugin helpers
local Ui = {}
local env = {
    Ui = Ui,
    InfoMessage = InfoMessage,
    UIManager = UIManager,
    string = string,
    T = function(s) return s end,
}
for _, name in ipairs{ "showLoadingMessage", "showCancellableLoadingMessage" } do
    local block = support.extract_block(PLUGIN .. "/zlibrary/ui.lua",
        "(\nfunction Ui%." .. name .. "%(.-\nend\n)")
    local chunk = assert(loadstring(block, "=Ui." .. name))
    setfenv(chunk, env)
    chunk()
end

-- ---------------------------------------------------------------- checks
local FETCHING = "Fetching most popular books..."

print("-- premise")
-- If this stops failing, InfoMessage no longer re-runs init to fit one line, and the checks
-- below prove nothing. Look before relaxing it.
install_face_override()
local ok, err = attempt(function()
    InfoMessage:new{
        text = "\u{23f3}  " .. FETCHING .. " (tap to cancel)",
        dismissable = false,
        show_icon = false,
        force_one_line = true,
    }
end)
r.check("the override makes a force_one_line message recurse until the stack overflows",
    not ok and err:find("stack overflow", 1, true) ~= nil,
    ok and string.format("it built after %d init calls", init_calls) or err)

print("-- loading messages, with appearance.koplugin's override in place")
install_face_override()
local widget
ok, err = attempt(function() widget = Ui.showCancellableLoadingMessage(FETCHING) end)
r.check("the cancellable loading message builds", ok, err)
r.check("InfoMessage:init runs once, not once per font shrink", init_calls == 1,
    string.format("%d calls", init_calls))
r.check("the widget shown is the one returned, so the caller can close it",
    ok and widget ~= nil and widget == shown)

-- A retried search puts the user's query in the message, so its length is not ours to choose.
local query = string.rep("a long book title ", 8)
install_face_override()
ok, err = attempt(function()
    Ui.showCancellableLoadingMessage(string.format("Retrying search for \"%s\"...", query))
end)
r.check("a message several lines long builds", ok, err)
r.check("... and still runs InfoMessage:init once", init_calls == 1,
    string.format("%d calls", init_calls))

r.finish()
