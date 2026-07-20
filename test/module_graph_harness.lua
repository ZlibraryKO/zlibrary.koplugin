-- Do the plugin's own modules form a cycle?
--
-- config.lua and cache.lua used to require each other: config needs Cache because it constructs
-- cache instances, and cache reached back for Config to fetch one value. It worked, because the
-- reaching-back require sat inside a function and so did not run at load time -- which is
-- precisely what made it easy to miss. A cycle deferred to call time is still a cycle, and it
-- constrains every later change to both modules.
--
-- Requires are counted wherever they appear, at the top of a file or inside a function, because
-- a deferred one is exactly the kind this is meant to catch.

local PLUGIN = assert(arg[1], "usage: luajit module_graph_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

-- ---------------------------------------------------------------- build the graph
local MODULES = {
    "main", "zlibrary.api", "zlibrary.async_helper", "zlibrary.bookdetails_dialog",
    "zlibrary.cache", "zlibrary.config", "zlibrary.dialog_manager", "zlibrary.gettext",
    "zlibrary.menu", "zlibrary.multisearch_dialog", "zlibrary.ota", "zlibrary.preloader",
    "zlibrary.ui",
}

local function path_of(mod)
    if mod == "main" then return PLUGIN .. "/main.lua" end
    return PLUGIN .. "/" .. mod:gsub("%.", "/") .. ".lua"
end

local deps = {}
for _, mod in ipairs(MODULES) do
    local fh = io.open(path_of(mod))
    if fh then
        local src = fh:read("*a")
        fh:close()
        local seen = {}
        for dep in src:gmatch('require%("(zlibrary%.[%w_]+)"%)') do
            if dep ~= mod then seen[dep] = true end
        end
        deps[mod] = seen
    end
end
r.check("module graph was read", next(deps) ~= nil, "no sources found under " .. PLUGIN)

-- ---------------------------------------------------------------- find cycles
-- Depth-first search, reporting the path so a failure names the loop rather than just its
-- existence.
local function find_cycle()
    local state, stack = {}, {}
    local found
    local function visit(mod)
        if found then return end
        state[mod] = "open"
        stack[#stack + 1] = mod
        for dep in pairs(deps[mod] or {}) do
            if state[dep] == "open" then
                local from = 1
                for i, m in ipairs(stack) do if m == dep then from = i break end end
                local path = {}
                for i = from, #stack do path[#path + 1] = stack[i] end
                path[#path + 1] = dep
                found = table.concat(path, " -> ")
                return
            elseif state[dep] ~= "closed" and deps[dep] then
                visit(dep)
                if found then return end
            end
        end
        stack[#stack] = nil
        state[mod] = "closed"
    end
    for mod in pairs(deps) do
        if state[mod] == nil then visit(mod) end
        if found then break end
    end
    return found
end

local cycle = find_cycle()
r.check("no module requires itself, directly or through others", cycle == nil, cycle)

-- ---------------------------------------------------------------- the specific pair
-- Named explicitly so a regression here reads as what it is rather than as a generic cycle.
r.check("cache stays a leaf: it requires no plugin module",
        next(deps["zlibrary.cache"] or {}) == nil,
        "cache now requires: " .. (function()
            local t = {}
            for d in pairs(deps["zlibrary.cache"] or {}) do t[#t + 1] = d end
            return table.concat(t, ", ")
        end)())

-- gettext is required by nearly everything, so it must depend on nothing of ours.
r.check("gettext stays a leaf", next(deps["zlibrary.gettext"] or {}) == nil, "gettext gained a dependency")

-- ---------------------------------------------------------------- report the shape
local names = {}
for mod in pairs(deps) do names[#names + 1] = mod end
table.sort(names)
print("")
for _, mod in ipairs(names) do
    local list = {}
    for d in pairs(deps[mod]) do list[#list + 1] = (d:gsub("^zlibrary%.", "")) end
    table.sort(list)
    print(string.format("  %-28s %s", (mod:gsub("^zlibrary%.", "")),
        #list > 0 and table.concat(list, " ") or "(leaf)"))
end

r.finish()
