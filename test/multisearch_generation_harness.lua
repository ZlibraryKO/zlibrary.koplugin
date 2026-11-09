-- Stale responses and duplicate pagination fetches.
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
passthrough("ui/widget/horizontalspan")
passthrough("ui/widget/verticalgroup")
passthrough("ui/widget/container/framecontainer")
package.preload["ui/widget/toggleswitch"] = function()
    return { new = function(_, spec)
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

-- ---------------------------------------------------------------- shown with books already loaded
-- fetchAndShow with an initial list must not be mistaken for a stale response.
local dialog4 = new_dialog({ books = { book(5) } })
dialog4:fetchAndShow()
r.check("a dialog shown with books keeps them without a fetch in flight",
        dialog4.books[1] and dialog4.books[1].title == "Book 5" and #fetches == 0,
        tostring(#fetches) .. " fetches")

-- ---------------------------------------------------------------- paging survives the cache
-- A list opened from the cache used to forget it had more pages, so it stopped at what it held
-- until someone pressed refresh.
clear_cache()
local dialog5 = new_dialog()
dialog5:fetchAndShow()
respond(dialog5, 1, { book(1) }, true, fetches[1].generation)
r.check("the cached list remembers its paging",
        cache_store["a"]._pagination and cache_store["a"]._pagination.page == 1
        and cache_store["a"]._pagination.has_more == true)

clear_cache()
cache_store["b"] = { book(42), _pagination = { page = 3, has_more = true } }
local dialog6 = new_dialog()
dialog6:ToggleSwitchCallBack(2)
dialog6.menu_container.page_num = 1
dialog6:onMenuGotoPage(dialog6.menu_container, 1)
r.check("a list from the cache fetches the page after the ones it holds",
        #fetches == 1 and fetches[1].page == 4, tostring(fetches[1] and fetches[1].page))

clear_cache()
cache_store["b"] = { book(42), _pagination = { page = 3, has_more = false } }
local dialog7 = new_dialog()
dialog7:ToggleSwitchCallBack(2)
dialog7.menu_container.page_num = 1
dialog7:onMenuGotoPage(dialog7.menu_container, 1)
r.check("a list from the cache that has no more pages stops", #fetches == 0,
        tostring(#fetches) .. " fetches")

-- ---------------------------------------------------------------- the real Most popular tab
-- This paging has broken twice: 1.0.54 fixed the tab stopping at 30 books, and it stopped there
-- again whenever the list came from the cache. So this drives the tab as main.lua defines it,
-- through the real dialog, against a server of 90 books at 30 a page.
local popular_block = support.extract_block(PLUGIN .. "/main.lua",
    "toggle_items = {{%s*(text = T%(\"Most popular\"%),.-end)}, {%s*text = T%(\"Recommended\"%)")

local popular_requests
local function popular_toggle(total)
    local env = {
        T = function(s) return s end,
        Api = { getMostPopularBooks = "api_method" },
        Config = {
            getMostPopularCacheKey = function() return "popular" end,
            getSearchLanguages = function() return { "english" } end,
            getSearchExtensions = function() return { "EPUB" } end,
        },
        self = {
            _fetchBookList = function(_, options, _, _, page)
                popular_requests[#popular_requests + 1] = page or 1
                local number = page or 1
                local books = {}
                for id = (number - 1) * 30 + 1, math.min(number * 30, total or 90) do
                    books[#books + 1] = book(id)
                end
                options.display_menu_func(nil, books, nil,
                    { has_more_results = total ~= nil and number * 30 < total or nil })
            end,
        },
    }
    local chunk = assert(loadstring("return {" .. popular_block .. "}", "=most_popular_toggle"))
    setfenv(chunk, env)
    return chunk()
end

local function open_popular(total)
    popular_requests = {}
    local dialog = new_dialog({ toggle_items = { popular_toggle(total) } })
    dialog:ToggleSwitchCallBack(1)
    return dialog
end

local function reach_last_page(dialog)
    dialog.menu_container.page_num = 1
    dialog:onMenuGotoPage(dialog.menu_container, 1)
end

local function requested() return table.concat(popular_requests, ",") end

local function unique_ids(dialog)
    local seen, count = {}, 0
    for _, b in ipairs(dialog.books) do
        if not seen[b.id] then seen[b.id] = true; count = count + 1 end
    end
    return count
end

clear_cache()
local popular = open_popular(90)
r.check("Most popular: opens on the first page", requested() == "1" and #popular.books == 30,
        requested() .. ", " .. #popular.books .. " books")
reach_last_page(popular)
r.check("Most popular: reaching the end loads the next 30, not just the first page",
        requested() == "1,2" and #popular.books == 60, requested() .. ", " .. #popular.books .. " books")
r.check("Most popular: the new page is added to the list, without repeats",
        unique_ids(popular) == 60 and popular.books[1].id == "1", tostring(unique_ids(popular)))

-- Stop after two pages, as a reader does, and come back later.
popular = open_popular(90)
r.check("Most popular: reopening uses the cache", requested() == "" and #popular.books == 60,
        requested() .. ", " .. #popular.books .. " books")
reach_last_page(popular)
r.check("Most popular: a cached list carries on where it ended",
        requested() == "3" and #popular.books == 90, requested() .. ", " .. #popular.books .. " books")
r.check("Most popular: a cached list gains no repeats", unique_ids(popular) == 90, tostring(unique_ids(popular)))

reach_last_page(popular)
r.check("Most popular: stops once it has every book", requested() == "3", requested())

popular = open_popular(90)
reach_last_page(popular)
r.check("Most popular: a complete cached list stops too", requested() == "" and #popular.books == 90,
        requested() .. ", " .. #popular.books .. " books")

-- With no languages or formats, Z-library sends one fixed list and says nothing about more.
clear_cache()
popular = open_popular(nil)
reach_last_page(popular)
r.check("Most popular: Z-library's own fixed list never asks for another page", requested() == "1", requested())

r.finish()
