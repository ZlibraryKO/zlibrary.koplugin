-- Does the gettext shim fall back to KOReader's own translation under an RTL UI language,
-- and do pgettext/ngettext/npgettext query the plugin's catalogue at all?
--
-- Two bugs, one harness:
--
-- 1. Under RTL UI languages KOReader's bidi module overrides GetText.wrapUntranslated to
--    wrap untranslated (English) strings in LTR isolate marks (frontend/ui/bidi.lua). The
--    shim's deep-copied catalogue keeps that wrapper, so a missing plugin translation comes
--    back as the WRAPPED msgid. Comparing it against the raw msgid never matches, so the
--    fallback to KOReader's own translation never fires and the user sees English where
--    KOReader has a translation. The plugin ships ar/ translations, so this is live.
--
-- 2. KOReader implements pgettext/ngettext/npgettext as GetText_mt.__index functions that
--    reference the GLOBAL GetText table (frontend/gettext.lua:411-481), and
--    util.tableDeepCopy copies functions by reference. The copies in the shim's catalogue
--    therefore still query KOReader's catalogue and can never serve a plugin translation.
--
-- usage: luajit rtl_fallback_harness.lua <plugin-root> <luasocket-src>

local PLUGIN = assert(arg[1], "usage: luajit rtl_fallback_harness.lua <plugin-root> <luasocket-src>")
local target = PLUGIN .. "/zlibrary/gettext.lua"

-- ---------------------------------------------------------------- stubs
-- Simulates bidi's RTL override: untranslated strings come back wrapped in LTR isolate
-- marks (LRI .. text .. PDI), so wrapped ~= raw.
local function WRAP(t) return "\226\129\166" .. t .. "\226\129\169" end

local PLURAL = function(n) return n == 1 and 0 or 1 end -- Dutch rule, both catalogues

local GetText
GetText = {
    dirname = "l10n",
    textdomain = "koreader",
    current_lang = "nl_NL",
    getPlural = PLURAL,
    wrapUntranslated = WRAP,
    -- KOReader's own catalogue, as loaded before the shim runs.
    context = {
        koreader_ctx = {
            hello = "hallo",
            ["%d ctx item"] = { [0] = "%d ctx item-nl-1", [1] = "%d ctx item-nl-2" },
        },
    },
    translation = {
        ["KOReader string"] = "KOReader vertaling",
        ["%d KOReader file"] = { [0] = "%d KOReader bestand", [1] = "%d KOReader bestanden" },
    },
    -- Simulates frontend/gettext.lua changeLang: wipes both tables and installs the
    -- PLUGIN's catalogue (the shim pointed GetText.dirname at the plugin's l10n).
    changeLang = function(new_lang)
        GetText.context = {
            plugin_ctx = {
                hello = "plugin-hallo",
                ["%d plugin ctx item"] = { [0] = "%d plugin ctx een", [1] = "%d plugin ctx meerdere" },
            },
        }
        GetText.translation = {
            ["Plugin string"] = "Plugin vertaling",
            ["%d plugin file"] = { [0] = "%d plugin bestand", [1] = "%d plugin bestanden" },
        }
        GetText.current_lang = new_lang
        return true
    end,
}

-- The fallback side of the shim calls KOReader's own pgettext/ngettext/npgettext, which
-- query the GLOBAL table (frontend/gettext.lua:411-481). Stub them the same way; the deep
-- copy carries these very functions by reference, which is bug 2.
GetText.pgettext = function(msgctxt, msgid)
    return GetText.context[msgctxt] and GetText.context[msgctxt][msgid] or GetText.wrapUntranslated(msgid)
end
GetText.ngettext = function(msgid, msgid_plural, n)
    local plural = GetText.getPlural(n)
    if plural == 0 then
        return GetText.translation[msgid] and GetText.translation[msgid][plural] or GetText.wrapUntranslated(msgid)
    else
        return GetText.translation[msgid] and GetText.translation[msgid][plural] or GetText.wrapUntranslated(msgid_plural)
    end
end
GetText.npgettext = function(msgctxt, msgid, msgid_plural, n)
    local plural = GetText.getPlural(n)
    if plural == 0 then
        return GetText.context[msgctxt] and GetText.context[msgctxt][msgid]
            and GetText.context[msgctxt][msgid][plural] or GetText.wrapUntranslated(msgid)
    else
        return GetText.context[msgctxt] and GetText.context[msgctxt][msgid]
            and GetText.context[msgctxt][msgid][plural] or GetText.wrapUntranslated(msgid_plural)
    end
end

-- Same lookup shape as GetText_mt.__call (frontend/gettext.lua:66-68).
setmetatable(GetText, { __call = function(gettext, msgid)
    return gettext.translation[msgid] or gettext.wrapUntranslated(msgid)
end })

package.preload["gettext"] = function() return GetText end
package.preload["logger"] = function()
    return { warn = function() end, info = function() end, dbg = function() end }
end
package.preload["util"] = function()
    return {
        splitFilePathName = function(p) return p:match("^(.*/)([^/]*)$") end,
        tableDeepCopy = function(t)
            local function copy(v, seen)
                if type(v) ~= "table" then return v end
                if seen[v] then return seen[v] end
                local out = {}
                seen[v] = out
                for k, val in pairs(v) do out[copy(k, seen)] = copy(val, seen) end
                return setmetatable(out, getmetatable(v))
            end
            return copy(t, {})
        end,
    }
end

G_reader_settings = { readSetting = function() return "nl_NL" end }

-- ---------------------------------------------------------------- run
local ok, proxy = pcall(dofile, target)
if not ok then
    print(string.format("  LOAD FAILED: %s", tostring(proxy)))
    os.exit(2)
end

-- ---------------------------------------------------------------- assertions
local checks = {}
local function check(name, pass, detail)
    checks[#checks + 1] = { name = name, pass = pass, detail = detail or "" }
end

local function check_eq(name, got, want)
    check(name, got == want,
          string.format("got %s, want %s", tostring(got), tostring(want)))
end

-- Bug 1: the __call path under an RTL wrapper.
check_eq("plugin translation served", proxy("Plugin string"), "Plugin vertaling")
check_eq("missing plugin translation falls back to KOReader's under RTL wrap",
         proxy("KOReader string"), "KOReader vertaling")
check_eq("string neither has stays wrapped English",
         proxy("Unknown string"), WRAP("Unknown string"))

-- Bug 2: pgettext/ngettext/npgettext must query the plugin catalogue...
check_eq("pgettext serves plugin context", proxy.pgettext("plugin_ctx", "hello"), "plugin-hallo")
check_eq("ngettext serves plugin singular",
         proxy.ngettext("%d plugin file", "%d plugin files", 1), "%d plugin bestand")
check_eq("ngettext serves plugin plural",
         proxy.ngettext("%d plugin file", "%d plugin files", 2), "%d plugin bestanden")
check_eq("npgettext serves plugin context plural",
         proxy.npgettext("plugin_ctx", "%d plugin ctx item", "%d plugin ctx items", 2),
         "%d plugin ctx meerdere")

-- ...and still fall back to KOReader's where the plugin lacks an entry.
check_eq("pgettext falls back to KOReader context",
         proxy.pgettext("koreader_ctx", "hello"), "hallo")
check_eq("ngettext falls back to KOReader plural",
         proxy.ngettext("%d KOReader file", "%d KOReader files", 2), "%d KOReader bestanden")
check_eq("npgettext falls back to KOReader context",
         proxy.npgettext("koreader_ctx", "%d ctx item", "%d ctx items", 1), "%d ctx item-nl-1")

local failed = 0
for _, c in ipairs(checks) do
    if not c.pass then failed = failed + 1 end
    print(string.format("  [%s] %s%s", c.pass and "PASS" or "FAIL", c.name,
                        (not c.pass and c.detail ~= "") and ("  <- " .. c.detail) or ""))
end
print(string.format("  %d/%d passed", #checks - failed, #checks))
os.exit(failed == 0 and 0 or 1)
