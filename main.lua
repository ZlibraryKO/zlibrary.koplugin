--[[--
@module koplugin.Zlibrary
--]]--

local Dispatcher = require("dispatcher")  -- luacheck:ignore
local util = require("util")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("zlibrary.gettext")
local Config = require("zlibrary.config")
local Discovery = require("zlibrary.discovery")
local Download = require("zlibrary.download")
local Ui = require("zlibrary.ui")
local logger = require("logger")
local Ota = require("zlibrary.ota")
local Cache = require("zlibrary.cache")
local DialogManager = require("zlibrary.dialog_manager")

local Zlibrary = WidgetContainer:extend{
    name = T("Z-library"),
    is_doc_only = false,
    plugin_path = nil,
    dialog_manager = nil,
}

function Zlibrary:onDispatcherRegisterActions()
    Dispatcher:registerAction("zlibrary_search", { category="none", event="ZlibrarySearch", title=T("Z-library search"), general=true,})
    Dispatcher:registerAction("zlibrary_mybook", { category="none", event="ZlibrarySearch", title=string.format("%s %s", T("Z-library"), T("My books")), arg="mybooks",general=true,})
end

function Zlibrary:init()
    local full_source_path = debug.getinfo(1, "S").source
    if full_source_path:sub(1,1) == "@" then
        full_source_path = full_source_path:sub(2)
    end
    self.plugin_path, _ = util.splitFilePathName(full_source_path):gsub("/+", "/")

    Config.loadCredentialsFromFile(self.plugin_path)
    -- Ota is the only reader of _meta.lua; config is told the version rather than reading it
    -- again, so the About dialog and the User-Agent can never name different ones.
    Config.setPluginVersion(Ota.getCurrentPluginVersion(self.plugin_path))

    self.dialog_manager = DialogManager:new()
    Ui.setPluginInstance(self)

    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    else
        logger.warn("self.ui or self.ui.menu not initialized in Zlibrary:init")
    end
    self.preLoader = require("zlibrary.preloader").Preloader
end

function Zlibrary:onZlibrarySearch(act_page)
    if act_page == "mybooks" then
        local mybooks_tab_favorites = 1
        self:showMyBooksDialog(mybooks_tab_favorites)
    else
        local def_search_input
        if self.ui and self.ui.doc_settings and self.ui.doc_settings.data.doc_props then
            local doc_props = self.ui.doc_settings.data.doc_props
            def_search_input = doc_props.authors or doc_props.title
        end
        self:showMultiSearchDialog(nil, def_search_input)
    end
    return true
end

-- Delegates to zlibrary/discovery.lua. Kept as a method because the body recurses through it
-- and Ui calls it on the plugin instance when it offers auto-discovery after a failure.
function Zlibrary:autoDiscoverAndSetBaseUrl(is_interactive, retry_callback)
    return Discovery.run(self, is_interactive, retry_callback)
end

-- A file extension is only usable if it survives being pasted into a path.
--
-- Browse-list rows are stubs: they carry an id, a hash and a title, and the extension only
-- arrives with the full book details. Missing, it came through as the literal "N/A" -- truthy,
-- so the `or "unknown"` fallback never fired -- and the slash inside it turned
-- "<title> - <author>.N/A.downloading" into a directory that does not exist. The download died
-- at the open with "No such file or directory", naming a path no one had asked for.
-- Delegate to zlibrary/download.lua. Kept as methods: bookdetails_dialog calls downloadBook
-- on the plugin instance, and the retry and detail-fetch paths recurse through both.
function Zlibrary:_fetchDetailsThenDownload(book_stub)
    return Download.fetchDetailsThenDownload(self, book_stub)
end

function Zlibrary:downloadBook(book)
    return Download.run(self, book)
end

-- Both teardown hooks do the same two things, and used to say so in two identical copies six
-- lines apart -- where a fix applied to one of them would have looked complete. The caller's name
-- is passed only so the log still says which hook ran.
function Zlibrary:_teardown(hook)
    if self.dialog_manager and self.dialog_manager:getDialogCount() > 0 then
        logger.info(hook .. " - Cleaning up " .. self.dialog_manager:getDialogCount() .. " remaining dialogs")
        self.dialog_manager:closeAllDialogs()
    end
    Cache.autoCacheCleanup(Config.getConfigRuntimeCache())
end

function Zlibrary:onExit()
    return self:_teardown("Zlibrary:onExit")
end

function Zlibrary:onCloseWidget()
    return self:_teardown("Zlibrary:onCloseWidget")
end

-- The rest of the plugin lives in parts, each returning the methods it adds to this class. They are
-- written exactly as they were in this file (`function Zlibrary:name(...)`), so copying them here,
-- before KOReader creates an instance, makes them methods like any other. A name defined twice --
-- by two parts, or by a part and this file -- stops the plugin from loading rather than letting one
-- silently replace the other. test/plugin_surface_harness.lua checks the full list.
for _, part in ipairs({ "plugin_menu", "plugin_requests", "plugin_browse",
                        "plugin_books", "plugin_signin", "plugin_search" }) do
    for name, method in pairs(require("zlibrary." .. part)) do
        assert(Zlibrary[name] == nil, "zlibrary." .. part .. " redefines Zlibrary:" .. name)
        Zlibrary[name] = method
    end
end

return Zlibrary
