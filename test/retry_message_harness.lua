-- Does the retry dialog classify a failure correctly, and then say something true about it?
--
-- The api layer produced a correct, actionable error for a bot-walled mirror and the dialog threw
-- it away: the flag was added to the guard that opens the dialog and to the auto-discovery button,
-- but not to the if/elseif that picks the wording, so it fell to the generic branch and the user
-- was told "due to a temporary issue" about the one failure here that is permanent.
--
-- This drives the real classification too, not just the wording. An earlier version injected
-- is_blocked as a ready-made boolean and so tested only half the path: deleting the line that
-- derives it, or dropping it from the guard, left the whole suite green. It now starts from a raw
-- error string and the real Api.BLOCKED_TEXT / Api.DNS_ERROR_TEXT values, so the classification,
-- the guard and the wording are all under test.

local PLUGIN = assert(arg[1], "usage: luajit retry_message_harness.lua <plugin-root> <luasocket-src>")
local LUASOCKET = assert(arg[2], "usage: luajit retry_message_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
support.preload_socket(LUASOCKET)
local r = support.reporter()

local UI = PLUGIN .. "/zlibrary/ui.lua"

-- From the first classification line through the end of the wording chain, so the flags, the
-- guard and the branch selection are all real code rather than harness inputs.
local block = support.extract_block(UI, "(local is_http_400 =.-\n        end\n)")

-- Two adjustments, neither touching the logic under test. The captured text opens
-- `if is_http_400 ... then` and closes only the inner wording chain, so the outer guard needs
-- its `end`. And both results are declared local inside that guard, which puts them out of
-- reach once it closes -- dropping `local` lets them land in the environment where the harness
-- can read which branch actually ran.
block = block
    :gsub("local offer_discover", "offer_discover", 1)
    :gsub("local retry_message\n", "retry_message = nil\n", 1)
    .. "end\n"

-- The constants the classifier matches on, read from api.lua rather than retyped: a reworded
-- message must not be able to silently stop being recognised.
local API = PLUGIN .. "/zlibrary/api.lua"
local function api_constant(name)
    local fh = assert(io.open(API))
    local src = fh:read("*a")
    fh:close()
    local v = src:match("Api%." .. name .. ' = T%("([^"]+)"%)')
    assert(v, "could not read Api." .. name .. " from api.lua")
    return v
end
local BLOCKED_TEXT = api_constant("BLOCKED_TEXT")
local DNS_ERROR_TEXT = api_constant("DNS_ERROR_TEXT")

-- Run the real block against a raw error string, as showRetryErrorDialog would.
local function classify(error_string)
    local env = {
        string = string,
        T = function(s) return s end,
        Api = { BLOCKED_TEXT = BLOCKED_TEXT, DNS_ERROR_TEXT = DNS_ERROR_TEXT },
        error_string = error_string,
        operation_name = "Sign-in",
        operation_key = "login",
        TIMEOUT_GETTERS = { login = function() return { 10, 15 } end },
    }
    local chunk = assert(loadstring(block, "=classify"))
    setfenv(chunk, env)
    chunk()
    return { message = env.retry_message, offer_discover = env.offer_discover }
end

local BLOCKED = BLOCKED_TEXT .. " (1lib.sk). Try a different Z-library server."
local TIMEOUT = "Request timed out - please check your connection and try again"
local DNS     = DNS_ERROR_TEXT .. " (z-lib.example). The Z-library address may be wrong."
local NETWORK = "Network connection error - please check your internet connection and try again"
local OTHER   = "HTTP Error: 400 (Bad Request)"

local blocked = classify(BLOCKED)
r.check("blocked mirror: dialog opens at all",
        blocked.message ~= nil, "no message produced -- the guard did not admit it")
r.check("blocked mirror: keeps the actionable message",
        blocked.message and blocked.message:find("refusing automated access", 1, true) ~= nil,
        "got: " .. tostring(blocked.message))
r.check("blocked mirror: does NOT claim a temporary issue",
        blocked.message and blocked.message:find("temporary issue", 1, true) == nil,
        "got: " .. tostring(blocked.message))
r.check("blocked mirror: names the host so the user can act",
        blocked.message and blocked.message:find("1lib.sk", 1, true) ~= nil,
        "got: " .. tostring(blocked.message))
-- Retry can never clear a wall, so the button that switches mirrors has to be on screen.
r.check("blocked mirror: offers auto-discovery",
        blocked.offer_discover == true, "offer_discover = " .. tostring(blocked.offer_discover))

local timeout = classify(TIMEOUT)
r.check("timeout: reports a timeout and its budget",
        timeout.message and timeout.message:find("timeout", 1, true) ~= nil
            and timeout.message:find("(10s)", 1, true) ~= nil,
        "got: " .. tostring(timeout.message))
r.check("timeout: offers auto-discovery", timeout.offer_discover == true,
        tostring(timeout.offer_discover))

local dns = classify(DNS)
r.check("dns: reports the address could not be found",
        dns.message and dns.message:find("address could not be found", 1, true) ~= nil,
        "got: " .. tostring(dns.message))
r.check("dns: offers auto-discovery", dns.offer_discover == true, tostring(dns.offer_discover))

local net = classify(NETWORK)
r.check("network: reports a network error",
        net.message and net.message:find("network error", 1, true) ~= nil,
        "got: " .. tostring(net.message))
-- A network fault is the user's connection, not the mirror, so switching servers is not the fix.
r.check("network: does NOT offer auto-discovery",
        net.offer_discover == nil, tostring(net.offer_discover))

local other = classify(OTHER)
r.check("anything else: falls back to the generic wording",
        other.message and other.message:find("temporary issue", 1, true) ~= nil,
        "got: " .. tostring(other.message))

-- An error resembling none of the recognised kinds must not open the dialog at all.
local unknown = classify("Some entirely unrelated failure")
r.check("unrecognised error: dialog does not open",
        unknown.message == nil, "got: " .. tostring(unknown.message))

-- Every kind must read differently; sharing another branch's wording by accident is exactly
-- what happened to the blocked case.
local seen = {}
for _, m in ipairs({ blocked.message, timeout.message, dns.message, net.message, other.message }) do
    r.check("distinct wording: " .. tostring(m):sub(1, 42), not seen[m], "duplicate wording")
    seen[m] = true
end

r.finish()
