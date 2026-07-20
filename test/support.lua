-- Shared scaffolding for the harnesses in this directory.
--
-- These tests run under KOReader's own LuaJIT against the plugin's real source. They stub the
-- KOReader modules the plugin requires so a harness can drive api.lua or ui.lua without a device
-- or a running reader, and they extract functions from source rather than copying them, so a test
-- cannot quietly drift away from the code it is meant to be checking.
--
-- Everything here takes the LuaSocket source directory as a parameter instead of hunting for it,
-- because test/run.sh already had to locate the KOReader build to find LuaJIT.

local support = {}

-- ---------------------------------------------------------------- reporting
function support.reporter()
    local r = { pass = 0, fail = 0 }

    function r.check(label, ok, detail)
        if ok then
            r.pass = r.pass + 1
        else
            r.fail = r.fail + 1
        end
        print(string.format("  [%s] %s%s", ok and "ok  " or "FAIL", label,
            (not ok and detail and detail ~= "") and ("  <- " .. tostring(detail)) or ""))
        return ok
    end

    function r.finish()
        print(string.format("\n  %d passed, %d failed", r.pass, r.fail))
        os.exit(r.fail == 0 and 0 or 1)
    end

    return r
end

-- ---------------------------------------------------------------- socket
-- url.lua wants require("socket"), which pulls in the C core we have no reason to build here.
-- It only uses that module as a namespace to hang socket.url off, so an empty table is enough.
function support.preload_socket(luasocket_src)
    assert(type(luasocket_src) == "string" and luasocket_src ~= "",
        "preload_socket needs the LuaSocket source directory")
    package.preload["socket"] = function() return {} end
    package.preload["socket.url"] = function()
        dofile(luasocket_src .. "/url.lua")
        return package.loaded["socket"].url
    end
    return require("socket.url")
end

-- ---------------------------------------------------------------- KOReader stubs
-- Only what the plugin actually reaches for. A harness that needs a module to behave in a
-- particular way overrides it afterwards; these are the inert defaults.
function support.preload_koreader_stubs()
    package.preload["logger"] = function()
        return { dbg = function() end, info = function() end,
                 warn = function() end, err = function() end }
    end
    package.preload["util"] = function()
        return {
            urlEncode = function(s) return s end,
            trim = function(s) return s end,
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
    -- Raises on ANY body, not merely a malformed one. The plugin wraps every decode in pcall,
    -- so this exercises those guards; it does mean the JSON-error-extraction path is out of
    -- scope for these harnesses, which is why nothing here asserts on a decoded API message.
    package.preload["json"] = function()
        return { decode = setmetatable({ simple = {} },
            { __call = function(_, s) return error("not json: " .. tostring(s):sub(1, 40)) end }) }
    end
    package.preload["ui/time"] = function()
        local t = 0
        return { now = function() t = t + 1 return t end,
                 since = function() return 1 end,
                 to_ms = function() return 1 end }
    end
    package.preload["socketutil"] = function()
        return {
            set_timeout = function() end,
            reset_timeout = function() end,
            table_sink = function(tbl)
                return function(chunk) if chunk then table.insert(tbl, chunk) end return 1 end
            end,
        }
    end
    -- An ltn12 source is a one-shot generator, and that property is the point of several
    -- assertions here: a body must be rebuilt per attempt or a retried POST goes out empty.
    package.preload["ltn12"] = function()
        return {
            source = {
                string = function(s)
                    local sent = false
                    return function()
                        if sent then return nil end
                        sent = true
                        return s
                    end
                end,
            },
        }
    end
    package.preload["zlibrary.gettext"] = function()
        return setmetatable({}, { __call = function(_, s) return s end })
    end
end

-- ---------------------------------------------------------------- source extraction
-- Pull a named local function out of a source file and compile it against a supplied
-- environment. Testing the real definition rather than a transcription of it is deliberate:
-- these functions are file-local and cannot be required, and a copied one would keep passing
-- after the original changed.
--
-- The count check is what makes that safe, and it is not incidental. Lua's `.` matches
-- newlines, so a pattern like this cannot tell live code from text inside a --[[ ]] block, and
-- string.match returns the FIRST hit. An earlier version had no count check: paste an old copy
-- of a function into a comment above the working one, break the working one, and the suite
-- reported 22 passed while exercising the commented-out copy. So refuse to guess -- if a name
-- appears more than once at the start of a line, fail loudly and make a human look.
local function read_source(path)
    local fh = assert(io.open(path), "cannot open " .. path)
    local src = fh:read("*a")
    fh:close()
    -- A leading newline lets the anchored patterns below match a definition on line 1.
    return "\n" .. src
end

local function count_matches(src, pattern)
    local n, pos = 0, 1
    while true do
        local s, e = string.find(src, pattern, pos)
        if not s then break end
        n = n + 1
        pos = e + 1
    end
    return n
end

function support.extract_function(path, name, env)
    local src = read_source(path)
    -- Anchored to the start of a line so an indented mention, or the name appearing inside
    -- another expression, is not mistaken for the definition.
    local anchor = "\nlocal function " .. name .. "%("
    local found = count_matches(src, anchor)
    assert(found > 0, string.format("no 'local function %s' in %s", name, path))
    assert(found == 1, string.format(
        "'local function %s' appears %d times in %s -- refusing to guess which one is live. "
        .. "A stale copy left in a comment or a duplicate definition would be tested instead "
        .. "of the real one, and the suite would pass while the shipped code was broken.",
        name, found, path))

    local body = src:match("(\nlocal function " .. name .. "%(.-\n)end\n")
    assert(body, string.format("found 'local function %s' in %s but could not delimit its end",
        name, path))

    local chunk = assert(loadstring(body .. "end\nreturn " .. name, "=" .. name))
    setfenv(chunk, env)
    return chunk()
end

-- Pull an arbitrary block for logic that lives inline in a large function rather than in one of
-- its own. Same uniqueness rule, for the same reason.
function support.extract_block(path, pattern)
    local src = read_source(path)
    local found = count_matches(src, pattern)
    assert(found > 0, "no block matching " .. pattern .. " in " .. path)
    assert(found == 1, string.format(
        "the block pattern matches %d times in %s -- refusing to guess which one is live.",
        found, path))
    return (src:match(pattern))
end

return support
