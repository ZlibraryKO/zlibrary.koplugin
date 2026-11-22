-- The plugin's own icons: are they found where the plugin is installed, shipped in the release, and
-- credited?
--
-- KOReader has no icon for some of what the plugin shows (the recent-searches clock beside the
-- search field), so those live in icons/ beside zlibrary/. Three things have to hold for one to
-- reach a reader's screen, and each failed silently until checked:
--
--   * _pluginIcon finds icons/<name>.svg from its own file's path, whatever directory KOReader was
--     installed in, and gives nil for a missing file so the dialog falls back to a text button.
--   * every icon the code asks for exists in icons/ -- a typo would quietly show the fallback.
--   * the release zip takes icons/*.svg (release.yml) -- otherwise every OTA install lacks them --
--     and icons/README.md credits each one, as their licence requires.

local PLUGIN = assert(arg[1], "usage: luajit plugin_icons_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local function read(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local s = fh:read("*a"); fh:close(); return s
end

-- ---------------------------------------------------------------- _pluginIcon
do
    local existing = {}
    local source = "@/mnt/us/koreader/plugins/zlibrary.koplugin/zlibrary/ui_search.lua"
    local icon = support.extract_function(PLUGIN .. "/zlibrary/ui_search.lua", "_pluginIcon", {
        debug = { getinfo = function() return { source = source } end },
        util = { fileExists = function(p) return existing[p] == true end },
    })

    existing["/mnt/us/koreader/plugins/zlibrary.koplugin/icons/history.svg"] = true
    r.check("an icon is found in icons/ beside zlibrary/",
            icon("history") == "/mnt/us/koreader/plugins/zlibrary.koplugin/icons/history.svg",
            "got " .. tostring(icon("history")))
    r.check("a missing icon is nil, so the caller falls back", icon("nope") == nil,
            "got " .. tostring(icon("nope")))

    source = "@plugins/zlibrary.koplugin/zlibrary/ui_search.lua"
    existing = { ["plugins/zlibrary.koplugin/icons/history.svg"] = true }
    r.check("a relative install path works too",
            icon("history") == "plugins/zlibrary.koplugin/icons/history.svg",
            "got " .. tostring(icon("history")))
end

-- ---------------------------------------------------------------- every icon asked for exists
local readme = read(PLUGIN .. "/icons/README.md") or ""
local asked = {}
for _, file in ipairs(support.ui_files(PLUGIN)) do
    for name in (read(file) or ""):gmatch('_pluginIcon%("([%w%._-]+)"%)') do asked[name] = true end
end
r.check("the code asks for at least one icon", next(asked) ~= nil, "no _pluginIcon(\"...\") calls found")
for name in pairs(asked) do
    local svg = read(PLUGIN .. "/icons/" .. name .. ".svg")
    r.check("icons/" .. name .. ".svg exists", svg ~= nil and svg:find("<svg", 1, true) ~= nil,
            "missing or not an SVG")
    r.check("icons/README.md credits " .. name .. ".svg",
            readme:find("`" .. name .. ".svg`", 1, true) ~= nil, "no row for it")
end

-- ---------------------------------------------------------------- shipped in the release
local workflow = read(PLUGIN .. "/.github/workflows/release.yml") or ""
r.check("the release zip takes icons/*.svg",
        workflow:find("find ./icons -maxdepth 1 -type f -name '*.svg'", 1, true) ~= nil,
        "release.yml has no icons find")

r.finish()
