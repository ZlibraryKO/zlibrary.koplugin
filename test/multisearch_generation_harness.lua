-- Stale responses, duplicate pagination fetches, and the toggle-title rebuild.
--
-- The browse lists fetch asynchronously: a response can come back after the user switched
-- tabs or forced a refresh, and applying it would mix rows from one list into another, and
-- turning to the last page twice before the answer lands fetched the same page twice. The
-- dialog tags every fetch with a generation and remembers the page still in flight; this
-- harness drives the real module (KOReader widgets stubbed) through those interleavings and
-- checks what lands on screen.

local PLUGIN = assert(arg[1], "usage: luajit multisearch_generation_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()
support.preload_koreader_stubs()

-- ---------------------------------------------------------------- KOReader widget stubs
-- Enough of the widget set for multisearch_dialog.lua to load and run init: constructors
-- return their spec, and only what the dialog actually calls is filled in.
local noop = function() end

local function passthrough(module)
    package.preload[module] = function()
        return { new = function(_, spec) return spec end }
    end
end

package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 800 end,
            getHeight = function() return 600 end,
            scaleBySize = function(_, n) return n end,
        },
        isTouchDevice = function() return true end,
        hasDPad = function() return false end,
        useDPadAsActionKeys = function() return false end,
    }
end
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 1, COLOR_BLACK = 0 } end
package.preload["ui/size"] = function()
    return { padding = { default = 3, button = 1 }, border = { thin = 1 },
             item = { height_default = 10 } }
end
package.preload["ui/geometry"] = function() return { new = function(_, t) return t or {} end } end
package.preload["ui/uimanager"] = function()
    -- nextTick runs inline: the harness drives fetches and responses synchronously.
    return { nextTick = function(_, f) f() end, show = noop, close = noop, setDirty = noop }
end
passthrough("ui/widget/iconbutton")
passthrough("ui/widget/buttondialog")
passthrough("ui/widget/titlebar")
passthrough("ui/widget/horizontalgroup")
passthrough("ui/widget/verticalgroup")
passthrough("ui/widget/container/framecontainer")
package.preload["ui/widget/toggleswitch"] = function()
    return { new = function(_, spec)
        -- Cells without a text widget on purpose: setToggleTitle then takes its rebuild
        -- branch, but only when the switch structure itself is there (it returns early
        -- without toggle_content and n_pos).
        spec.n_pos = #spec.toggle
        spec.toggle_content = { {} }
        for _ in ipairs(spec.toggle) do table.insert(spec.toggle_content[1], {}) end
        spec.setPosition = function(self, position) self.position = position end
        spec.disableFocusManagement = noop
        return spec
    end }
end
package.preload["ui/widget/container/inputcontainer"] = function()
    local InputContainer = { onKeyPress = function() return false end, free = noop }
    function InputContainer:extend(fields)
        local cls = fields or {}
        setmetatable(cls, { __index = self })
        function cls:new(o)
            local instance = o or {}
            setmetatable(instance, { __index = cls })
            instance:init()
            return instance
        end
        return cls
    end
    return InputContainer
end

-- The menu keeps no state of its own here; updateItems and onGotoPage just record.
local MenuStub = {}
function MenuStub.new(_, spec)
    spec.updateItems = function(self) self.updates = (self.updates or 0) + 1 end
    return spec
end
function MenuStub.updateItems(menu) if menu then menu.updates = (menu.updates or 0) + 1 end end
function MenuStub.onGotoPage(menu, page) menu.page = page end
package.preload["zlibrary.menu"] = function() return MenuStub end

-- A primable cache, shared across calls like the real singleton.
local cache_store = {}
local function clear_cache()
    for key in pairs(cache_store) do cache_store[key] = nil end
end
package.preload["zlibrary.config"] = function()
    return { getMultiSearchCache = function()
        return {
            get = function(_, key) return cache_store[key] end,
            insert = function(_, key, value) cache_store[key] = value end,
            remove = function(_, key) cache_store[key] = nil end,
        }
    end }
end
package.preload["zlibrary.preloader"] = function() return { Preloader = { channel = nil } } end

local SearchDialog = dofile(PLUGIN .. "/zlibrary/multisearch_dialog.lua")

-- ---------------------------------------------------------------- a dialog with fake fetch callbacks
-- Shaped like the toggle callbacks in main.lua, but synchronous: each call records the
-- fetch, and the harness "resolves" it by calling the response handlers the way
-- _requestDispatcher's resolve_result does.
local fetches
local function new_dialog(extra)
    fetches = {}
    local callback = function(widget, page, is_refresh, fetch_generation)
        table.insert(fetches, { page = page, is_refresh = is_refresh,
                                generation = fetch_generation })
    end
    local spec = {
        def_position = 1,
        toggle_items = {
            { text = "Tab A", cache_key = "a", cache_expiry = 60,
              enable_pagination = true, callback = callback },
            { text = "Tab B", cache_key = "b", cache_expiry = 60,
              enable_pagination = true, callback = callback },
        },
    }
    for k, v in pairs(extra or {}) do spec[k] = v end
    return SearchDialog:new(spec)
end

local function book(id)
    return { id = tostring(id), hash = "h" .. id, title = "Book " .. id, author = "Author " .. id }
end

-- The My Books response shape: pagination state first, then replace (page 1) or append.
local function respond(widget, page, books, has_more, fetch_generation)
    widget:setPaginationState(has_more, page, fetch_generation)
    if page == 1 then
        widget:reloadFromBookData(books, nil, nil, nil, fetch_generation)
    else
        widget:appendBatchDataAndReload(books, fetch_generation)
    end
end

-- ---------------------------------------------------------------- a basic fetch and response
local dialog = new_dialog()
dialog:ToggleSwitchCallBack(1)
r.check("switching to a tab issues one page-1 fetch", #fetches == 1 and fetches[1].page == nil,
        tostring(#fetches) .. " fetches")
respond(dialog, 1, { book(1) }, true)
r.check("a page-1 response is applied", dialog.books[1] and dialog.books[1].title == "Book 1")
r.check("a page-1 response sets the pagination state",
        dialog.current_page_loaded == 1 and dialog.has_more_api_results == true)

-- ---------------------------------------------------------------- duplicate pagination fetches
dialog.menu_container.page_num = 1
dialog:onMenuGotoPage(dialog.menu_container, 1)
r.check("reaching the last page fetches the next page", #fetches == 2 and fetches[2].page == 2,
        tostring(#fetches) .. " fetches, page " .. tostring(fetches[2] and fetches[2].page))
dialog:onMenuGotoPage(dialog.menu_container, 1)
r.check("re-entering before the response lands does not re-fetch", #fetches == 2,
        tostring(#fetches) .. " fetches -- the second page turn fired another one")
respond(dialog, 2, { book(2) }, true)
r.check("the page-2 response appends exactly once",
        #dialog.books == 2 and dialog.books[2].title == "Book 2",
        tostring(#dialog.books) .. " rows")
dialog:onMenuGotoPage(dialog.menu_container, 1)
r.check("pagination resumes once the response is applied",
        #fetches == 3 and fetches[3].page == 3,
        tostring(#fetches) .. " fetches, page " .. tostring(fetches[3] and fetches[3].page))

-- ---------------------------------------------------------------- a stale page response after refresh
-- The page-3 fetch above is still in flight when the user forces a refresh.
dialog:forceFetchAndReloadMenu()
r.check("a forced refresh refetches page 1",
        #fetches == 4 and fetches[4].page == nil and fetches[4].is_refresh == true,
        tostring(#fetches) .. " fetches")
r.check("a forced refresh resets the pagination state",
        dialog.current_page_loaded == nil and dialog.has_more_api_results == nil)
r.check("a forced refresh tags the fetch with a new generation",
        fetches[4].generation ~= nil and fetches[4].generation > fetches[3].generation,
        tostring(fetches[3].generation) .. " -> " .. tostring(fetches[4].generation))
respond(dialog, 3, { book(3) }, true)
r.check("a stale page response does not append", #dialog.books == 0,
        tostring(#dialog.books) .. " rows")
r.check("a stale page response does not move the pagination state",
        dialog.current_page_loaded == nil and dialog.has_more_api_results == nil)
respond(dialog, 1, { book(10) }, false)
r.check("the refresh's own response still applies",
        dialog.books[1] and dialog.books[1].title == "Book 10")

-- ---------------------------------------------------------------- generation-tagged responses
-- Callbacks that hand back the generation they were issued with get the strict check.
clear_cache()
local dialog2 = new_dialog()
dialog2:ToggleSwitchCallBack(1)
dialog2:ToggleSwitchCallBack(2)
r.check("each tab switch bumps the fetch generation",
        #fetches == 2 and fetches[2].generation == fetches[1].generation + 1,
        tostring(fetches[1] and fetches[1].generation) .. " -> "
        .. tostring(fetches[2] and fetches[2].generation))
respond(dialog2, 1, { book(1) }, true, fetches[1].generation)
r.check("a response tagged with an old generation is dropped", #dialog2.books == 0,
        tostring(#dialog2.books) .. " rows")
respond(dialog2, 1, { book(2) }, false, fetches[2].generation)
r.check("a response tagged with the current generation applies",
        dialog2.books[1] and dialog2.books[1].title == "Book 2")
dialog2:appendBatchDataAndReload({ book(3) }, fetches[1].generation)
r.check("a stale-tagged append is dropped", #dialog2.books == 1,
        tostring(#dialog2.books) .. " rows")

-- ---------------------------------------------------------------- a cache hit with a fetch in flight
clear_cache()
cache_store["b"] = { book(42) }
local dialog3 = new_dialog()
dialog3:ToggleSwitchCallBack(1)
dialog3:ToggleSwitchCallBack(2)
r.check("a cache hit shows the cached rows without fetching",
        #fetches == 1 and dialog3.books[1] and dialog3.books[1].title == "Book 42",
        tostring(#fetches) .. " fetches")
dialog3.menu_container.page_num = 1
dialog3:onMenuGotoPage(dialog3.menu_container, 1)
r.check("a cache-hit tab does not paginate on the previous tab's state", #fetches == 1,
        tostring(#fetches) .. " fetches")
-- Tab A's response finally lands, the way the popular/recommended tabs apply it.
dialog3:reloadFromBookData({ book(7) })
r.check("a response for the previous tab is dropped after a cache-hit switch",
        dialog3.books[1].title == "Book 42", dialog3.books[1].title)

-- ---------------------------------------------------------------- the toggle-title rebuild keeps the tab
-- The stubbed switch has no toggle_content, so setToggleTitle takes its rebuild branch.
r.check("the dialog is on the second tab", dialog3._position == 2)
dialog3:setToggleTitle(2, "Tab B [2/10]")
r.check("the rebuild keeps the tab the user is on", dialog3._position == 2,
        "position=" .. tostring(dialog3._position))
r.check("the rebuild retitles the tab", dialog3.toggle_items[2].text == "Tab B [2/10]")
r.check("the rebuilt switch highlights the current tab", dialog3.toggle_switch.position == 2,
        "switch at " .. tostring(dialog3.toggle_switch.position))
r.check("the rebuild keeps the rows on screen",
        dialog3.books[1] and dialog3.books[1].title == "Book 42")

-- ---------------------------------------------------------------- shown with books already loaded
-- fetchAndShow with an initial list must not be mistaken for a stale response.
local dialog4 = new_dialog({ books = { book(5) } })
dialog4:fetchAndShow()
r.check("a dialog shown with books keeps them without a fetch in flight",
        dialog4.books[1] and dialog4.books[1].title == "Book 5" and #fetches == 0,
        tostring(#fetches) .. " fetches")

r.finish()
