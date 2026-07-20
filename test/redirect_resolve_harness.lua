-- Which redirects does the plugin follow, and where does it resolve them to?
--
-- Two users reported "HTTP Error: 307" on sign-in. 307 was already an accepted status, so the
-- status code was never the problem -- the Location handling was. Only an absolute cross-host
-- URL was followed; a relative or same-host target was refused and the raw 30x was handed to the
-- user as an error. That covered http -> https on the same host, which is about the most ordinary
-- redirect a server can send.
--
-- Checks both that a redirect is followed and that it resolves to the right absolute URL.
-- real_url_base must stay cross-host-only: it is the mirror-move signal that pins a new base URL,
-- and setting it for an in-site hop would repoint every later request at the wrong root.

local PLUGIN = assert(arg[1], "usage: luajit redirect_resolve_harness.lua <plugin-root> <luasocket-src>")
local LUASOCKET = assert(arg[2], "usage: luajit redirect_resolve_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local socket_url = support.preload_socket(LUASOCKET)
local r = support.reporter()

local checkRedirect = support.extract_function(
    PLUGIN .. "/zlibrary/api.lua", "_checkAndHandleRedirect",
    {
        socket_url = socket_url,
        logger = { err = function() end, dbg = function() end, info = function() end },
        string = string, type = type, tostring = tostring, pairs = pairs,
    })

local CURRENT = "https://z-lib.example/eapi/user/login"

-- label, status, Location, expected resolved target (nil = must NOT follow), expect cross-host
local cases = {
    { "absolute, different host",   307, "https://other.example/eapi/user/login",
      "https://other.example/eapi/user/login", true },
    { "absolute, SAME host",        307, "https://z-lib.example/eapi/user/login/",
      "https://z-lib.example/eapi/user/login/", false },
    { "root-relative path",         307, "/eapi/v2/user/login",
      "https://z-lib.example/eapi/v2/user/login", false },
    { "relative path",              307, "login2",
      "https://z-lib.example/eapi/user/login2", false },
    { "protocol-relative //host",   307, "//other.example/eapi/user/login",
      "https://other.example/eapi/user/login", true },
    { "308 permanent, cross host",  308, "https://other.example/eapi/user/login",
      "https://other.example/eapi/user/login", true },
    { "302 found, cross host",      302, "https://other.example/eapi/user/login",
      "https://other.example/eapi/user/login", true },
    { "303 see other, relative",    303, "/eapi/user/session",
      "https://z-lib.example/eapi/user/session", false },
    { "same host, same path",       301, "https://z-lib.example/eapi/user/login",
      "https://z-lib.example/eapi/user/login", false },
    { "no Location at all",         307, nil, nil, false },
    { "non-redirect status",        200, "https://other.example/x", nil, false },
}

print(string.format("  request URL: %s\n", CURRENT))
for _, c in ipairs(cases) do
    local label, status, location, want_target, want_cross = c[1], c[2], c[3], c[4], c[5]
    local headers = location and { location = location } or {}
    -- skip_check = false: the path taken whenever LuaSocket is not following redirects itself
    local res = checkRedirect(false, status, CURRENT, headers)

    if want_target == nil then
        r.check(string.format("%-30s %s  refuses", label, status),
                res.real_url == nil, "followed to " .. tostring(res.real_url))
    else
        r.check(string.format("%-30s %s  -> %s", label, status, want_target),
                res.real_url == want_target,
                res.real_url and ("resolved to " .. res.real_url)
                             or ("REFUSED: " .. tostring(res.error)))
        r.check(string.format("%-30s %s  pins base: %s", label, status, tostring(want_cross)),
                (res.real_url_base ~= nil) == want_cross,
                "real_url_base = " .. tostring(res.real_url_base))
    end
end

-- The two shapes that actually reached users, spelled out so a regression names itself.
local http_to_https = checkRedirect(false, 307, "http://z-lib.fo/eapi/user/login",
                                    { location = "https://z-lib.fo/eapi/user/login" })
r.check("http -> https on the same host is followed",
        http_to_https.real_url == "https://z-lib.fo/eapi/user/login",
        tostring(http_to_https.error))
r.check("http -> https does not pin a new base",
        http_to_https.real_url_base == nil, tostring(http_to_https.real_url_base))

r.finish()
