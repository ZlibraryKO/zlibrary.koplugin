-- Did moving mirror discovery out of main.lua change anything?
--
-- It was 346 lines, a fifth of main.lua, touching one field of the plugin instance and calling
-- no method on it but itself. Moving it out is the largest single change to that file, and the
-- kind where a wrapper is easy to get subtly wrong: drop the return, lose an argument, break the
-- recursion, or let the plugin's own method shadow the module's.
--
-- The move was made verifiable rather than merely careful. Discovery.run takes a parameter
-- literally named `self`, so the body is byte-for-byte what it was, and this asserts that
-- directly against git rather than trusting the diff to have been read.

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
local disc_src = read(PLUGIN .. "/zlibrary/discovery.lua")

-- ---------------------------------------------------------------- the wrapper
r.check("main.lua still exposes the method",
        main_src:find("function Zlibrary:autoDiscoverAndSetBaseUrl(is_interactive, retry_callback)", 1, true) ~= nil,
        "the method is gone -- Ui calls it on the plugin instance")

-- Both arguments must reach the module. Dropping is_interactive would make discovery think every
-- run was a background one and wait for the network differently.
r.check("both arguments are passed through",
        main_src:find("Discovery.run(self, is_interactive, retry_callback)", 1, true) ~= nil,
        "the delegation does not forward both arguments")

r.check("the plugin instance is passed",
        main_src:find("Discovery.run(self,", 1, true) ~= nil,
        "self is not passed -- discover_channel would have nowhere to live")

r.check("main.lua requires the module",
        main_src:find('require("zlibrary.discovery")', 1, true) ~= nil,
        "Discovery would be nil at the call")

-- The body recurses through the plugin method, so a wrapper that does not return would swallow
-- the result of that path.
r.check("the delegation returns", main_src:find("return Discovery.run", 1, true) ~= nil,
        "the wrapper drops the return value")

-- ---------------------------------------------------------------- the module
r.check("the module takes the instance as `self`",
        disc_src:find("function Discovery.run(self, is_interactive, retry_callback)", 1, true) ~= nil,
        "the parameter was renamed -- the body is no longer verbatim")

r.check("the module returns itself", disc_src:match("\nreturn Discovery%s*$") ~= nil,
        "require would yield true rather than the module")

-- Everything the body reaches for must be required here now that it is not sharing main.lua's
-- upvalues. A missing one is nil at runtime, on a path only reached when a mirror is being
-- hunted -- which is to say, when something is already wrong.
for _, dep in ipairs({ "zlibrary.api", "zlibrary.async_helper", "zlibrary.cache", "zlibrary.config",
                       "zlibrary.ui", "zlibrary.gettext", "device", "ui/network/manager",
                       "ui/uimanager", "logger" }) do
    r.check("module requires " .. dep,
            disc_src:find('require("' .. dep .. '")', 1, true) ~= nil,
            "not required -- it would be a nil global at runtime")
end

-- Nothing the body uses may have been left behind as a global.
--
-- Found rather than listed. A hand-written list only covers the names someone thought of, and
-- the failure this guards against is precisely the one that was not thought of: a module the
-- body used through main.lua's upvalues, now unbound, nil at runtime on a path only reached
-- when a mirror is being hunted -- which is when something is already wrong.
local bound, used = {}, {}
for name in disc_src:gmatch("local (%w+) = require%(") do bound[name] = true end
for name in disc_src:gmatch("local (%w+) =") do bound[name] = true end
for name in disc_src:gmatch("local function (%w+)") do bound[name] = true end
-- Locals declared inside the body, and the loop variables that carry them.
for name in disc_src:gmatch("local ([%w_, ]+)%s*=") do
    for part in name:gmatch("[%w_]+") do bound[part] = true end
end
for name in disc_src:gmatch("for%s+([%w_, ]+)%s+in") do
    for part in name:gmatch("[%w_]+") do bound[part] = true end
end
for name in disc_src:gmatch("for%s+([%w_]+)%s*=") do bound[name] = true end
-- `local a, b` with no assignment -- a forward declaration, which the patterns above all miss
-- because they expect an `=`. Reported connection_menu as unbound when it is declared on its
-- own line before the closures that assign it.
for name in disc_src:gmatch("local ([%w_, ]+)%s*\n") do
    for part in name:gmatch("[%w_]+") do bound[part] = true end
end
for name in disc_src:gmatch("function%s+[%w_.:]*%(([^)]*)%)") do
    for part in name:gmatch("[%w_]+") do bound[part] = true end
end
for name in disc_src:gmatch("function%s*%(([^)]*)%)") do
    for part in name:gmatch("[%w_]+") do bound[part] = true end
end
bound["Discovery"] = true
-- Lua's own globals, which need no binding.
for _, g in ipairs({ "string", "table", "math", "os", "io", "type", "tostring", "tonumber",
                     "pairs", "ipairs", "next", "pcall", "error", "assert", "select",
                     "setmetatable", "getmetatable", "require", "unpack", "print", "self" }) do
    bound[g] = true
end

for name in disc_src:gmatch("[^%w_.:\"]([A-Za-z_][%w_]*)[.:][%w_]+%s*%(") do
    used[name] = true
end
local unbound = {}
for name in pairs(used) do
    if not bound[name] then unbound[#unbound + 1] = name end
end
table.sort(unbound)
r.check("every module the body calls into is bound in this file", #unbound == 0,
        "unbound: " .. table.concat(unbound, ", "))

-- ---------------------------------------------------------------- main.lua kept nothing
local _, leftovers = main_src:gsub("discover_channel", "")
r.check("main.lua no longer touches discover_channel", leftovers == 0,
        leftovers .. " references left behind -- the state should live with the code that uses it")

r.check("the body is not still in main.lua",
        main_src:find("findWorkingBaseUrl", 1, true) == nil,
        "part of the old implementation remains")

r.finish()
