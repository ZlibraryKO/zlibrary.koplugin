-- Does zlibrary/gettext.lua derive the plugin's l10n directory correctly when the
-- checkout path itself contains /zlibrary/ higher up?
--
-- gettext.lua finds the plugin root by stripping its own zlibrary/ directory off the
-- end of its path. An earlier version stripped EVERY occurrence of /zlibrary/, so a
-- checkout nested under another directory named zlibrary (e.g.
-- ~/zlibrary/zlibrary.koplugin/zlibrary/) lost the wrong segments, plugin_path was
-- mangled, and translations silently failed to load.
--
-- The harness copies the real gettext.lua into synthetic layouts and checks the
-- dirname the proxy exposes (a plain value, passed through the proxy's __index).
--
-- usage: luajit gettext_path_harness.lua <plugin-root> <luasocket-src>

local PLUGIN = assert(arg[1], "usage: luajit gettext_path_harness.lua <plugin-root> <luasocket-src>")
local source_file = PLUGIN .. "/zlibrary/gettext.lua"

-- ---------------------------------------------------------------- stubs
-- Just enough of KOReader's GetText for the shim to load a catalogue and build the
-- proxy: changeLang installs a non-empty plugin catalogue, like the rtl_fallback
-- harness's stub does.
local GetText
GetText = {
    dirname = "l10n",
    current_lang = "nl_NL",
    getPlural = function(n) return n == 1 and 0 or 1 end,
    wrapUntranslated = function(t) return t end,
    context = {},
    translation = { ["KOReader string"] = "KOReader vertaling" },
    changeLang = function(new_lang)
        GetText.context = {}
        GetText.translation = { ["Plugin string"] = "Plugin vertaling" }
        GetText.current_lang = new_lang
        return true
    end,
}
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
local checks = {}
local function check_eq(name, got, want)
    local pass = got == want
    checks[#checks + 1] = {
        name = name, pass = pass,
        detail = pass and "" or string.format("got %s, want %s", tostring(got), tostring(want)),
    }
end

-- Copy the real gettext.lua to target_path, run it, and return the proxy's dirname.
local function dirname_for(target_path)
    local input = assert(io.open(source_file, "rb"))
    local code = assert(input:read("*a"))
    input:close()
    assert(os.execute(string.format("mkdir -p '%s'", target_path:match("^(.*/)[^/]*$"))))
    local output = assert(io.open(target_path, "wb"))
    assert(output:write(code))
    output:close()

    local ok, proxy = pcall(dofile, target_path)
    if not ok then
        check_eq("load " .. target_path, "LOAD FAILED: " .. tostring(proxy), "loads")
        return nil
    end
    return proxy.dirname
end

local tmpbase = os.tmpname()
os.remove(tmpbase) -- we want a directory, not the file tmpname created
assert(os.execute(string.format("mkdir -p '%s'", tmpbase)))

-- Standard layout: only the file's own zlibrary/ segment is stripped.
check_eq("standard checkout",
         dirname_for(tmpbase .. "/zlibrary.koplugin/zlibrary/gettext.lua"),
         tmpbase .. "/zlibrary.koplugin/l10n")

-- The bug: nested under ANOTHER directory named zlibrary. The unanchored gsub ate
-- every occurrence and produced tmpbase .. "zlibrary.koplugin/l10n".
check_eq("nested under a higher zlibrary directory",
         dirname_for(tmpbase .. "/zlibrary/zlibrary.koplugin/zlibrary/gettext.lua"),
         tmpbase .. "/zlibrary/zlibrary.koplugin/l10n")

-- Fallback: not directly inside a zlibrary/ directory, so the anchored pattern
-- matches nothing and the old strip-everything behaviour applies.
check_eq("file outside a zlibrary directory falls back to old behaviour",
         dirname_for(tmpbase .. "/zlibrary/odd/gettext.lua"),
         tmpbase .. "odd//l10n")

assert(os.execute(string.format("rm -rf '%s'", tmpbase)))

local failed = 0
for _, c in ipairs(checks) do
    if not c.pass then failed = failed + 1 end
    print(string.format("  [%s] %s%s", c.pass and "PASS" or "FAIL", c.name,
                        (not c.pass and c.detail ~= "") and ("  <- " .. c.detail) or ""))
end
print(string.format("  %d/%d passed", #checks - failed, #checks))
os.exit(failed == 0 and 0 or 1)
