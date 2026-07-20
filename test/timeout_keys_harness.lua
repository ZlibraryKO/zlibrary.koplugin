-- Does every operation_key at a call site actually resolve to a timeout getter?
--
-- The retry dialog shows the timeout budget it gave up on -- "(15s)" -- by looking the operation
-- up in TIMEOUT_GETTERS. A key that does not match simply yields nothing and the hint silently
-- disappears, which is the exact failure the keys were introduced to fix: the dispatch used to
-- match English literals against an already-translated name, so outside English nothing ever
-- matched and no hint was ever shown.
--
-- Nothing at runtime complains about a typo'd key, and the behavioural harnesses stub the getters
-- away, so this compares the two sets directly against the source.

local PLUGIN = assert(arg[1], "usage: luajit timeout_keys_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local function read(path)
    local fh = assert(io.open(path), "cannot open " .. path)
    local src = fh:read("*a")
    fh:close()
    return src
end

local ui_src = read(PLUGIN .. "/zlibrary/ui.lua")
local main_src = read(PLUGIN .. "/main.lua")
local config_src = read(PLUGIN .. "/zlibrary/config.lua")

-- ---------------------------------------------------------------- the getters that exist
local table_src = ui_src:match("local TIMEOUT_GETTERS = {(.-)\n}")
assert(table_src, "could not find TIMEOUT_GETTERS in ui.lua")

local getters, getter_fns = {}, {}
for key, fn in table_src:gmatch("([%w_]+)%s*=%s*(Config%.[%w_]+)") do
    getters[key] = fn
    getter_fns[#getter_fns + 1] = fn
end
r.check("TIMEOUT_GETTERS is populated", next(getters) ~= nil, "parsed nothing")

-- ---------------------------------------------------------------- the keys in use
-- Both spellings: the literal passed as the last argument to showRetryErrorDialog, and the
-- operation_key field set in a dispatcher options table.
local used = {}
for _, src in ipairs({ ui_src, main_src }) do
    for key in src:gmatch('end,%s*loading_msg,%s*"([%w_]+)"') do used[key] = true end
    for key in src:gmatch('loading_msg_to_close,%s*"([%w_]+)"') do used[key] = true end
    for key in src:gmatch('operation_key%s*=%s*"([%w_]+)"') do used[key] = true end
end
r.check("found operation keys in use", next(used) ~= nil, "parsed none")

for key in pairs(used) do
    r.check(string.format("operation_key %q resolves to a getter", key),
            getters[key] ~= nil,
            "not in TIMEOUT_GETTERS -- the timeout hint silently vanishes for this operation")
end

-- ---------------------------------------------------------------- the getters resolve
for key, fn in pairs(getters) do
    local name = fn:match("^Config%.([%w_]+)$")
    r.check(string.format("%s -> %s exists in config.lua", key, fn),
            config_src:find("function Config." .. name, 1, true) ~= nil,
            fn .. " is not defined")
end

-- A getter nothing dispatches to is dead weight, and more usefully, its absence from the call
-- sites usually means an operation was wired up without its key.
for key in pairs(getters) do
    if not used[key] then
        print(string.format("  note: TIMEOUT_GETTERS has %q but no call site passes it", key))
    end
end

r.finish()
