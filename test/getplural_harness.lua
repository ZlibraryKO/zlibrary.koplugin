-- Does loading the plugin's gettext shim leave KOReader's global getPlural clobbered?
--
-- KOReader rebuilds GetText.getPlural from the catalogue's Plural-Forms header every
-- changeLang (frontend/gettext.lua:220). The shim points GetText.dirname at the plugin's
-- own l10n and calls changeLang to parse it, then restores the fields it saved. If
-- getPlural is not among them, KOReader keeps using the plural rule from the PLUGIN's
-- catalogue for the rest of the session.
--
-- usage: luajit getplural_harness.lua <plugin-root> <luasocket-src>

local PLUGIN = assert(arg[1], "usage: luajit getplural_harness.lua <plugin-root> <luasocket-src>")
local target = PLUGIN .. "/zlibrary/gettext.lua"

-- ---------------------------------------------------------------- stubs
local KOREADER_PLURAL = function(n) return n == 1 and 0 or 1 end   -- sentinel we must get back
local PLUGIN_PLURAL   = function(n) return 0 end                   -- what our catalogue would install

local GetText
GetText = {
    dirname = "l10n",
    textdomain = "koreader",
    context = { koreader_ctx = { hello = "hallo" } },
    translation = { ["KOReader string"] = "KOReader vertaling" },
    current_lang = "nl_NL",
    getPlural = KOREADER_PLURAL,
    wrapUntranslated = function(t) return t end,
    -- Simulates frontend/gettext.lua changeLang: wipes both tables, sets current_lang,
    -- and rebuilds getPlural from the newly-parsed header.
    changeLang = function(new_lang)
        GetText.context = {}
        GetText.translation = { ["Plugin string"] = "Plugin vertaling" }
        GetText.current_lang = new_lang
        GetText.getPlural = PLUGIN_PLURAL
        return true
    end,
}

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
local before = GetText.getPlural
assert(before == KOREADER_PLURAL, "harness setup wrong")

local ok, err = pcall(dofile, target)
if not ok then
    print(string.format("  LOAD FAILED: %s", tostring(err)))
    os.exit(2)
end

local after = GetText.getPlural

-- ---------------------------------------------------------------- assertions
local checks = {}
local function check(name, pass, detail)
    checks[#checks + 1] = { name = name, pass = pass, detail = detail or "" }
end

check("GetText.getPlural restored to KOReader's",
      after == KOREADER_PLURAL,
      after == PLUGIN_PLURAL and "still the PLUGIN's plural rule -- LEAKED"
          or (after == KOREADER_PLURAL and "" or "some third function"))

-- The plural rules differ observably, so show the behavioural consequence too.
check("plural selection for n=5 unchanged",
      after(5) == KOREADER_PLURAL(5),
      string.format("KOReader expects %d, global now yields %d", KOREADER_PLURAL(5), after(5)))

-- The fields the shim already restored must stay restored.
check("GetText.translation restored",
      GetText.translation["KOReader string"] == "KOReader vertaling",
      "plugin catalogue left in KOReader's table")
check("GetText.current_lang restored", GetText.current_lang == "nl_NL", "")
check("GetText.dirname restored", GetText.dirname == "l10n",
      "dirname still points at the plugin: " .. tostring(GetText.dirname))

local failed = 0
for _, c in ipairs(checks) do
    if not c.pass then failed = failed + 1 end
    print(string.format("  [%s] %s%s", c.pass and "PASS" or "FAIL", c.name,
                        (not c.pass and c.detail ~= "") and ("  <- " .. c.detail) or ""))
end
print(string.format("  %d/%d passed", #checks - failed, #checks))
os.exit(failed == 0 and 0 or 1)
