
local PLUGIN = assert(arg[1], "usage: luajit booklist_rows_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()
support.preload_koreader_stubs()

local noop = function() end
local function passthrough(module)
    package.preload[module] = function()
        return { new = function(_, spec) return spec end }
    end
end

-- Touch by default; set keys_only for a Kindle 4 style reader, where the dialog builds a focus layout.
local device = { keys_only = false }
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 800 end,
            getHeight = function() return 600 end,
            scaleBySize = function(_, n) return n end,
        },
        isTouchDevice = function() return not device.keys_only end,
        hasDPad = function() return device.keys_only end,
        useDPadAsActionKeys = function() return device.keys_only end,
    }
end
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 1, COLOR_BLACK = 0 } end
package.preload["ui/size"] = function()
    return { padding = { default = 3, button = 1 }, border = { thin = 1 },
             item = { height_default = 10 } }
end
package.preload["ui/geometry"] = function() return { new = function(_, t) return t or {} end } end
local shown = {}
package.preload["ui/uimanager"] = function()
    return { nextTick = function(_, f) f() end, close = noop, setDirty = noop,
             show = function(_, widget) table.insert(shown, widget) end }
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
        spec.setPosition = function(self, position) self.position = position end
        spec.togglePosition = function(self, position) self.position = position end
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

-- KOReader's MenuItem:init runs text:gsub, so a row without text crashes the reader. Fail the same way.
local function render(menu)
    for i, item in ipairs(menu.item_table or {}) do
        if type(item.text) ~= "string" then
            error(string.format("MenuItem:init would crash: row %d has text %s", i, tostring(item.text)))
        end
    end
    menu.updates = (menu.updates or 0) + 1
end
local MenuStub = {}
function MenuStub.new(_, spec)
    spec.key_events = {}
    spec.updateItems = render
    return spec
end
MenuStub.updateItems = function(menu) if menu then render(menu) end end
function MenuStub.onGotoPage(menu, page) menu.page = page end
package.preload["zlibrary.menu"] = function() return MenuStub end

local cache_store = {}
local cache = {
    get = function(_, key) return cache_store[key] end,
    insert = function(_, key, value) cache_store[key] = value end,
    remove = function(_, key) cache_store[key] = nil end,
    removePrefix = function(_, prefix)
        for key in pairs(cache_store) do
            if key:sub(1, #prefix) == prefix then cache_store[key] = nil end
        end
        return true
    end,
}
local Config = {
    getMultiSearchCache = function() return cache end,
    getViewSettings = function() return { browse_per_page = 8 } end,
}
package.preload["zlibrary.config"] = function() return Config end
package.preload["zlibrary.preloader"] = function() return { Preloader = { channel = nil } } end

local SearchDialog = dofile(PLUGIN .. "/zlibrary/multisearch_dialog.lua")

-- ---------------------------------------------------------------- the plugin's dialogs (plugin_browse.lua)
local Api = { getFavoriteBooks = "getFavoriteBooks", getDownloadedBooks = "getDownloadedBooks",
              getBooklists = "getBooklists", getBooklistBooks = "getBooklistBooks" }
local dialogs, requests, selected_books
local env = setmetatable({
    Zlibrary = {},
    T = function(s) return s end,
    Api = Api,
    Config = Config,
    Ui = { showInfoMessage = noop, showSearchDialog = noop, confirmRemoveDownloaded = noop },
    MultiSearchDialog = { new = function(_, spec)
        local dialog = SearchDialog:new(spec)
        table.insert(dialogs, dialog)
        return dialog
    end },
    require = function(name)
        if name == "datetime" then return {} end
        return require(name)
    end,
}, { __index = _G })
for _, name in ipairs({ "showMyBooksDialog", "showBooklistDialog" }) do
    local block = support.extract_block(support.plugin_class_files(PLUGIN),
        "(\nfunction Zlibrary:" .. name .. "%(.-\nend\n)")
    local chunk = assert(loadstring(block, "=" .. name))
    setfenv(chunk, env)
    chunk()
end

local plugin = setmetatable({
    dialog_manager = { trackDialog = noop },
    preLoader = { getDownloadQuotaStatus = noop },
    getDownloadQuotaCache = noop,
    resetFavoritesCache = noop,
    resetDownloadQuotaCache = noop,
    onSelectRecommendedBook = function(_, book) table.insert(selected_books, book) end,
    _requestDispatcher = function(_, opts, ...)
        table.insert(requests, { api = opts.api_method, opts = opts, args = { ... } })
    end,
}, { __index = env.Zlibrary })

local function reset()
    dialogs, requests, selected_books, shown = {}, {}, {}, {}
    for key in pairs(cache_store) do cache_store[key] = nil end
end

local function open_my_books(position)
    plugin:showMyBooksDialog(position)
    return dialogs[#dialogs]
end

local function last_request() return requests[#requests] end

-- Hands a recorded request its response, as _requestDispatcher does once the fetch returns.
local function resolve(request, api_result)
    return pcall(request.opts.resolve_result, nil, api_result, plugin)
end

local function texts(dialog)
    local out = {}
    for i, item in ipairs(dialog.menu_container.item_table or {}) do out[i] = tostring(item.text) end
    return table.concat(out, ", ")
end

local BOOK = { id = "1", hash = "h1", title = "Amerika", author = "Kafka", cover = "https://c/1.jpg" }
local OTHER_BOOK = { id = "2", hash = "h2", title = "Der Process", author = "Kafka" }
local LIST = { id = 1001, name = "Test", count = 22 }
local function books(list, has_more) return { books = list, has_more_results = has_more or false } end

-- ---------------------------------------------------------------- the Booklists tab
reset()
local dialog = open_my_books(1)
local menu = dialog.menu_container
r.check("My Books has a Booklists tab after Downloaded", dialog.toggle_items[3].text == "Booklists")
r.check("a book tab opens with covers on", menu.show_cover == true)

r.check("Favorites fetches its books", last_request().api == Api.getFavoriteBooks)
resolve(last_request(), books({ BOOK }))
local row = menu.item_table[1]
r.check("a book tab's rows are unchanged",
        row and row.book_index == 1 and row.hash == "h1" and row.cover == "https://c/1.jpg"
            and row.text:find("Amerika", 1, true) and row.text:find("Kafka", 1, true) and not row.callback,
        row and tostring(row.text) or "no row")

-- What the cover layout leaves behind on the shared Menu.
menu.state_w, menu.list_per_page = 50, 4

dialog:ToggleSwitchCallBack(3)
r.check("Booklists fetches the lists", last_request().api == Api.getBooklists)
resolve(last_request(), { booklists = { LIST } })
row = menu.item_table[1]
r.check("the Booklists tab shows each list with its book count",
        row and row.text == "Test" and row.mandatory == "22" and row.book_index == nil,
        row and tostring(row.text) or "no row")
r.check("and turns covers off", menu.show_cover == false)
r.check("and clears the cover strip", menu.state_w == nil, "state_w=" .. tostring(menu.state_w))
r.check("and restores the user's rows per page", menu.list_per_page == 8,
        "list_per_page=" .. tostring(menu.list_per_page))

local dialogs_before = #dialogs
menu.onMenuSelect(menu, row)
local list_dialog = dialogs[#dialogs]
r.check("a tap on a booklist opens its books",
        #dialogs == dialogs_before + 1 and list_dialog.title == "Test"
            and last_request().api == Api.getBooklistBooks and last_request().args[1] == LIST.id,
        "last request: " .. tostring(last_request().api))
r.check("and does not treat it as a book", #selected_books == 0, #selected_books .. " books selected")

local shown_before = #shown
menu.onMenuHold(menu, row)
r.check("a hold on a booklist opens nothing", #shown == shown_before)

menu.list_per_page = 10
dialog:ToggleSwitchCallBack(1)
r.check("switching back to a book tab turns covers on again", menu.show_cover == true)
r.check("and restores the user's rows per page", menu.list_per_page == 8,
        "list_per_page=" .. tostring(menu.list_per_page))
row = menu.item_table[1]
r.check("the book tab comes back from cache with book rows", row and row.book_index == 1)
menu.onMenuSelect(menu, row)
r.check("a tap on a book row still selects the book", selected_books[1] == BOOK)

reset()
dialog = open_my_books(3)
r.check("a dialog that opens on Booklists builds its Menu without covers",
        dialog.menu_container.show_cover == false)
local ok, err = resolve(last_request(), { booklists = { { id = 1002, count = 0 } } })
r.check("a booklist without a name reads Untitled",
        ok and dialog.menu_container.item_table[1].text == "Untitled", tostring(err or texts(dialog)))

-- ---------------------------------------------------------------- refresh
reset()
dialog = open_my_books(3)
resolve(last_request(), { booklists = { LIST } })
cache_store["booklist_1001"] = { BOOK }
cache_store["favorites"] = { BOOK }
dialog:forceFetchAndReloadMenu()
r.check("refreshing Booklists forgets each list's cached books", cache_store["booklist_1001"] == nil)
r.check("and leaves the other tabs' caches alone", cache_store["favorites"] ~= nil)
r.check("and fetches the lists again", last_request().api == Api.getBooklists)

-- ---------------------------------------------------------------- slow responses
-- Every tab here starts on page 1, so a response must be matched to its fetch by generation.
reset()
dialog = open_my_books(3)
local booklists_request = last_request()
dialog:ToggleSwitchCallBack(1)
resolve(booklists_request, { booklists = { LIST } })
r.check("a booklists response that lands after a switch to Favorites is not shown",
        #dialog.books == 0, texts(dialog))
r.check("nor cached under favorites", cache_store["favorites"] == nil)

for position, name in ipairs({ "Favorites", "Downloaded" }) do
    reset()
    dialog = open_my_books(position)
    local book_request = last_request()
    dialog:ToggleSwitchCallBack(3)
    local lists_request = last_request()
    ok, err = resolve(book_request, books({ BOOK }))
    r.check(name .. " books that land after a switch to Booklists do not crash it", ok, tostring(err))
    r.check("and are not shown there", #dialog.books == 0, texts(dialog))
    r.check("nor cached under booklists", cache_store["booklists"] == nil)
    resolve(lists_request, { booklists = { LIST } })
    r.check("the booklists response that follows is shown", texts(dialog) == "Test", texts(dialog))
end

reset()
dialog = open_my_books(1)
resolve(last_request(), books({ BOOK }, true))
dialog.menu_container.page_num = 1
dialog:onMenuGotoPage(dialog.menu_container, 1)
local page2_request = last_request()
r.check("the last page of Favorites fetches page 2", page2_request.args[1] == 2,
        "page " .. tostring(page2_request.args[1]))
dialog:ToggleSwitchCallBack(2)
resolve(last_request(), books({ OTHER_BOOK }))
resolve(page2_request, books({ BOOK }))
r.check("a Favorites page 2 that lands after a switch to Downloaded is not appended",
        #dialog.books == 1 and dialog.books[1] == OTHER_BOOK, #dialog.books .. " rows")

-- ---------------------------------------------------------------- one booklist
reset()
plugin:showBooklistDialog(LIST)
dialog = dialogs[#dialogs]
local filter_row = dialog.compound_title_bar[2]
r.check("a booklist has no tab switch", dialog.compound_title_bar._toggle == nil
        and filter_row[1] ~= dialog.toggle_switch)
r.check("but keeps the refresh button", filter_row[2] == dialog.compound_title_bar._refresh)

resolve(last_request(), books({ BOOK }, true))
local requests_before = #requests
dialog:onKeyPress({ Tab = true })
r.check("Tab in a booklist fetches nothing", #requests == requests_before,
        (#requests - requests_before) .. " requests")
dialog.menu_container.page_num = 1
dialog:onMenuGotoPage(dialog.menu_container, 1)
r.check("and the next page still loads after it", #requests == requests_before + 1
        and last_request().args[1] == LIST.id and last_request().args[2] == 2,
        "page " .. tostring(last_request().args[2]))

-- ---------------------------------------------------------------- readers without a touchscreen
device.keys_only = true
reset()
plugin:showBooklistDialog(LIST)
dialog = dialogs[#dialogs]
local layout = dialog.compound_title_bar:generateVerticalLayout()
local focus_row = layout[#layout]
r.check("a booklist's focus row holds only the refresh button",
        #focus_row == 1 and focus_row[1] == dialog.compound_title_bar._refresh,
        #focus_row .. " entries")
resolve(last_request(), books({ BOOK }, true))
requests_before = #requests
dialog:onKeyPress({ Left = true })
dialog:onKeyPress({ Right = true })
r.check("Left and Right in a booklist fetch nothing", #requests == requests_before,
        (#requests - requests_before) .. " requests")
dialog.menu_container.page_num = 1
dialog:onMenuGotoPage(dialog.menu_container, 1)
r.check("and the next page still loads after them", last_request().args[2] == 2,
        "page " .. tostring(last_request().args[2]))

reset()
dialog = open_my_books(1)
layout = dialog.compound_title_bar:generateVerticalLayout()
r.check("My Books' focus row still holds the tabs and refresh", #layout[#layout] == 2)
dialog:onKeyPress({ Left = true })
r.check("Left from Favorites still goes to Booklists",
        dialog._position == 3 and last_request().api == Api.getBooklists,
        "position " .. tostring(dialog._position))
device.keys_only = false

r.finish()
