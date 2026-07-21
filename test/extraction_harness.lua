-- Did moving code out of main.lua change anything?
--
-- Two features have left it: mirror discovery (346 lines) and downloading (308). Both were
-- moved verbatim -- the module functions take a parameter literally named `self`, so the bodies
-- are byte-for-byte what they were and the plugin methods they call still resolve on the
-- instance. A move that changes no line cannot change behaviour.
--
-- What a move like that still gets wrong is the seam: a dropped return, a lost argument, a
-- dependency that used to come free from main.lua's upvalues and is now an unbound global,
-- reached only on a path that runs when something is already going wrong.

local PLUGIN = assert(arg[1], "usage: luajit discovery_extraction_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local function read(path)
    local fh = assert(io.open(path), "cannot open " .. path)
    local s = fh:read("*a")
    fh:close()
    return s
end

local main_src = read(PLUGIN .. "/main.lua")

-- module file, the table it exports, and the methods main.lua keeps pointing at it
local EXTRACTED = {
    {
        file = "zlibrary/discovery.lua", exports = "Discovery",
        requires = { "zlibrary.api", "zlibrary.async_helper", "zlibrary.cache", "zlibrary.config",
                     "zlibrary.ui", "zlibrary.gettext", "device", "ui/network/manager",
                     "ui/uimanager", "logger" },
        methods = {
            { name = "autoDiscoverAndSetBaseUrl", args = "is_interactive, retry_callback",
              call = "Discovery.run(self, is_interactive, retry_callback)" },
        },
        gone = { "discover_channel", "findWorkingBaseUrl" },
    },
    {
        file = "zlibrary/download.lua", exports = "Download",
        requires = { "zlibrary.api", "zlibrary.async_helper", "zlibrary.config", "zlibrary.ui",
                     "zlibrary.gettext", "device", "ui/network/manager", "ui/uimanager",
                     "apps/reader/readerui", "ui/trapper", "libs/libkoreader-lfs", "logger",
                     "util" },
        methods = {
            { name = "_fetchDetailsThenDownload", args = "book_stub",
              call = "Download.fetchDetailsThenDownload(self, book_stub)" },
            { name = "downloadBook", args = "book", call = "Download.run(self, book)" },
        },
        -- The filename guard moved with the code that uses it.
        gone = { "_usableFormat" },
    },
}

for _, mod in ipairs(EXTRACTED) do
    local src = read(PLUGIN .. "/" .. mod.file)
    local label = mod.file:match("([%w_]+)%.lua$")

    -- ------------------------------------------------------------ the wrapper in main.lua
    for _, m in ipairs(mod.methods) do
        r.check(label .. ": main.lua still exposes " .. m.name,
                main_src:find("function Zlibrary:" .. m.name .. "(" .. m.args .. ")", 1, true) ~= nil,
                "the method is gone -- other modules call it on the plugin instance")
        -- Every argument must reach the module, and the result must come back: these bodies
        -- recurse through the plugin method.
        r.check(label .. ": " .. m.name .. " delegates and returns",
                main_src:find("return " .. m.call, 1, true) ~= nil,
                "expected `return " .. m.call .. "`")
    end
    r.check(label .. ": main.lua requires it",
            main_src:find('require("' .. mod.file:gsub("/", "."):gsub("%.lua$", "") .. '")', 1, true) ~= nil,
            "the module would be nil at the call")

    -- ------------------------------------------------------------ the module
    r.check(label .. ": takes the instance as `self`",
            src:find("(self,", 1, true) ~= nil,
            "the parameter was renamed -- the body is no longer verbatim")
    r.check(label .. ": returns itself",
            src:match("\nreturn " .. mod.exports .. "%s*$") ~= nil,
            "require would yield true rather than the module")

    for _, dep in ipairs(mod.requires) do
        r.check(label .. ": requires " .. dep,
                src:find('require("' .. dep .. '")', 1, true) ~= nil,
                "not required -- a nil global at runtime")
    end

    -- Nothing may be left unbound. Found rather than listed: the failure worth guarding against
    -- is the dependency nobody remembered was there.
    local bound, used = {}, {}
    for name in src:gmatch("local (%w+) = require%(") do bound[name] = true end
    for name in src:gmatch("local ([%w_, ]+)%s*=") do
        for part in name:gmatch("[%w_]+") do bound[part] = true end
    end
    for name in src:gmatch("local function (%w+)") do bound[name] = true end
    -- `local a, b` with no assignment is a forward declaration and still a binding.
    for name in src:gmatch("local ([%w_, ]+)%s*\n") do
        for part in name:gmatch("[%w_]+") do bound[part] = true end
    end
    for name in src:gmatch("for%s+([%w_, ]+)%s+in") do
        for part in name:gmatch("[%w_]+") do bound[part] = true end
    end
    for name in src:gmatch("for%s+([%w_]+)%s*=") do bound[name] = true end
    for name in src:gmatch("function%s+[%w_.:]*%(([^)]*)%)") do
        for part in name:gmatch("[%w_]+") do bound[part] = true end
    end
    for name in src:gmatch("function%s*%(([^)]*)%)") do
        for part in name:gmatch("[%w_]+") do bound[part] = true end
    end
    bound[mod.exports] = true
    for _, g in ipairs({ "string", "table", "math", "os", "io", "type", "tostring", "tonumber",
                         "pairs", "ipairs", "next", "pcall", "error", "assert", "select",
                         "setmetatable", "getmetatable", "require", "unpack", "print", "self" }) do
        bound[g] = true
    end
    -- Scan code only. Comments mention modules the file does not use -- download.lua explains
    -- why the child owns the socket and why an error cannot be read out of socket.http, and the
    -- first version of this reported `socket` as an unbound dependency because of it.
    local code = src:gsub("%-%-[^\n]*", "")
    for name in code:gmatch("[^%w_.:\"]([A-Za-z_][%w_]*)[.:][%w_]+%s*%(") do used[name] = true end
    local unbound = {}
    for name in pairs(used) do
        if not bound[name] then unbound[#unbound + 1] = name end
    end
    table.sort(unbound)
    r.check(label .. ": every module it calls into is bound", #unbound == 0,
            "unbound: " .. table.concat(unbound, ", "))

    -- ------------------------------------------------------------ main.lua kept nothing
    for _, name in ipairs(mod.gone) do
        local _, n = main_src:gsub(name, "")
        r.check(label .. ": main.lua no longer mentions " .. name, n == 0,
                n .. " references left behind")
    end
end

r.finish()
