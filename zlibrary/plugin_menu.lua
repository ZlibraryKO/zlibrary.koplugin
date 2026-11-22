-- The plugin's entry in KOReader's main menu: Settings and everything under it, Search, the browse
-- screens, My books and About.
--
-- Part of the plugin class. main.lua used to hold all of it in one 1,579-line file; it now copies
-- the methods each part returns onto the class at load (see the end of main.lua). The methods are
-- written exactly as they were there -- `function Zlibrary:name(...)` on this local table -- so
-- `self` is the plugin instance as before. Diff with --color-moved against the commit before the
-- split to see where the code came from.

local UIManager = require("ui/uimanager")
local util = require("util")
local T = require("zlibrary.gettext")
local Config = require("zlibrary.config")
local Ui = require("zlibrary.ui")
local logger = require("zlibrary.log")
local Ota = require("zlibrary.ota")
local Cache = require("zlibrary.cache")

local Zlibrary = {}

function Zlibrary:addToMainMenu(menu_items)
    if not self.ui.view then
        menu_items.zlibrary_main = {
            sorting_hint = "search",
            text = T("Z-library"),
            sub_item_table = {
                {
                    text = T("Settings"),
                    keep_menu_open = true,
                    separator = true,
                    sub_item_table = {
                        {
                            text = T("Set base URL"),
                            keep_menu_open = true,
                            callback = function()
                                UIManager:nextTick(function() self:autoDiscoverAndSetBaseUrl(true) end)
                            end,
                        },
                        {
                            text = T("Set credentials"),
                            keep_menu_open = true,
                            callback = function()
                                -- Through the broker, so there is one credentials dialog in the
                                -- plugin. The old inline call passed a test_callback taking no
                                -- parameters, which discarded the typed values and verified
                                -- whatever was already stored.
                                self:_promptForCredentials(function(did_save, did_verify)
                                    -- did_verify means the dialog already checked them and said
                                    -- so; a second sign-in and a second toast would be pure
                                    -- repetition.
                                    if not did_save or did_verify then return end
                                    self:login(function(success)
                                        if success then Ui.showInfoMessage(T("Login successful!")) end
                                    end, { no_prompt = true })
                                end)
                            end,
                            -- Inherited from the "Verify credentials" entry that used to sit
                            -- here: it divides the account settings from the download ones.
                            -- Verification now lives in the dialog this opens.
                            separator = true,
                    }, {
                            -- The settings for what happens to a download, together: on their own
                            -- in Settings, "Author folders" or "Ask to open after download" said
                            -- little about what they were for.
                            text = T("Downloads"),
                            keep_menu_open = true,
                            sub_item_table = { {
                                text = T("Download folder"),
                                keep_menu_open = true,
                                callback = function()
                                    Ui.showDownloadDirectoryDialog()
                                end,
                            }, {
                                -- Here rather than under View settings: it changes what happens after
                                -- a download, not how a list looks.
                                text = T("Ask to open after download"),
                                keep_menu_open = true,
                                checked_func = function()
                                    return not Config.getSkipOpenBookPrompt()
                                end,
                                callback = function()
                                    Config.setSkipOpenBookPrompt(not Config.getSkipOpenBookPrompt())
                                end,
                            }, {
                                -- Named folders under the download folder; the post-download
                                -- dialog offers to file the book into one. Rebuilt on each open so it
                                -- always shows the current set. Greyed out when "Ask to open after
                                -- download" is off: categories are only chosen from that dialog, so
                                -- with no dialog there is nothing they could do.
                                text = T("Download categories"),
                                keep_menu_open = true,
                                enabled_func = function()
                                    return not Config.getSkipOpenBookPrompt()
                                end,
                                sub_item_table_func = function()
                                    return Ui.buildCategoriesMenuItems()
                                end,
                            }, {
                                -- No enabled_func, unlike categories: author folders need no choice
                                -- from the open prompt, so they work with it switched off too.
                                text = T("Author folders"),
                                keep_menu_open = true,
                                help_text = T("Saves each downloaded book in a folder named after its author, inside the download folder or the chosen category."),
                                checked_func = function()
                                    return Config.getAuthorFolders()
                                end,
                                callback = function()
                                    Config.setAuthorFolders(not Config.getAuthorFolders())
                                end,
                            } },
                        }, {
                                text = T("View settings"),
                                keep_menu_open = true,
                                sub_item_table = { {
                                    text = T("Search covers"),
                                    keep_menu_open = true,
                                    checked_func = function()
                                        return Config.getViewFlag("show_cover_search")
                                    end,
                                    callback = function()
                                        Config.toggleViewFlag("show_cover_search")
                                    end,
                                },  {
                                    text = T("Search items per page"),
                                    keep_menu_open = true,
                                    separator = true,
                                    callback = Ui.createPerPageSettingCallback(T("Search items per page"), "search_per_page"),
                                }, {
                                    text = T("Browse covers"),
                                    keep_menu_open = true,
                                    checked_func = function()
                                        return Config.getViewFlag("show_cover_browse")
                                    end,
                                    callback = function()
                                        Config.toggleViewFlag("show_cover_browse")
                                    end,
                                }, {
                                    text = T("Browse items per page"),
                                    keep_menu_open = true,
                                    callback = Ui.createPerPageSettingCallback(T("Browse items per page"), "browse_per_page"),
                                }},
                        }, {
                            text = T("Search options"),
                            keep_menu_open = true,
                            separator = true,
                            sub_item_table = {{
                                text = T("Select search languages"),
                                keep_menu_open = true,
                                callback = function()
                                    Ui.showLanguageSelectionDialog(self.ui)
                                end
                            }, {
                                text = T("Select search formats"),
                                keep_menu_open = true,
                                callback = function()
                                    Ui.showExtensionSelectionDialog(self.ui)
                                end
                            }, {
                                text = T("Select search order"),
                                keep_menu_open = true,
                                callback = function()
                                    Ui.showOrdersSelectionDialog(self.ui)
                                end
                            }}
                        }, {
                            text = T("Timeout settings"),
                            keep_menu_open = true,
                            separator = true,
                            callback = function()
                                Ui.showAllTimeoutConfigDialog(self.ui)
                            end,
                        },
                        {
                            text = T("Check for updates"),
                            keep_menu_open = false,
                            separator = true,
                            callback = function()
                                if self.plugin_path then
                                    Ota.startUpdateProcess(self.plugin_path)
                                else
                                    logger.err("ZLibrary: Plugin path not available for OTA update.")
                                    Ui.showErrorMessage(T("Error: Plugin path not found. Cannot check for updates."))
                                end
                            end,
                        },
                        {
                            text = T("Advanced"),
                            keep_menu_open = true,
                            separator = true,
                            sub_item_table_func = function()
                                return {
                                    {
                                        text = T("Clear credentials"),
                                        keep_menu_open = true,
                                        callback = function()
                                            Ui.confirmClearCredentials(function()
                                                Config.clearCredentials()
                                                -- zlibrary_credentials.lua is re-read on every
                                                -- init, which happens per UI, so anything it
                                                -- sets is back before the user notices. Say so
                                                -- rather than report a clearing that will not
                                                -- survive.
                                                if Config.credentialsComeFromFile() then
                                                    Ui.showInfoMessage(string.format(
                                                        T("Credentials cleared, but %s still sets them. Edit that file to stop it."),
                                                        Config.CREDENTIALS_FILENAME))
                                                else
                                                    Ui.showInfoMessage(T("Credentials cleared."))
                                                end
                                            end)
                                        end,
                                    }, {
                                        text = T("Clear user session"),
                                        keep_menu_open = true,
                                        callback = function()
                                            Config.clearUserSession()
                                            -- Same lie to avoid as the credentials above: a
                                            -- session set by zlibrary_credentials.lua is back on
                                            -- the next init, so do not report it as gone.
                                            if Config.sessionComesFromFile() then
                                                Ui.showInfoMessage(string.format(
                                                    T("Session cleared, but %s still sets one. Edit that file to stop it."),
                                                    Config.CREDENTIALS_FILENAME))
                                            else
                                                Ui.showInfoMessage(T("Session cleared. You will need to login again."))
                                            end
                                        end,
                                    }, {
                                        text = T("Clear runtime cache"),
                                        keep_menu_open = true,
                                        callback = function()
                                            Config.getConfigRuntimeCache():clear()
                                            Cache:new{ name = "_domains_cache" }:clear()
                                            Ui.showInfoMessage(T("Runtime cache cleared."))
                                        end,
                                    },
                                    {
                                        -- What the "delete the covers" report actually wanted.
                                        -- Deliberately a button and not the requested delete-on-
                                        -- exit: the covers are a cache, re-fetching them costs
                                        -- requests at a server that rate-limits, and on Android
                                        -- "on exit" is not a thing that reliably happens -- the
                                        -- OS can kill the app outright.
                                        text = T("Clear cover cache"),
                                        keep_menu_open = true,
                                        callback = function()
                                            local _, bytes = Cache:new{ type = "cover" }:clearAll()
                                            if bytes > 0 then
                                                Ui.showInfoMessage(string.format(
                                                    T("Cleared %s of cached covers."),
                                                    util.getFriendlySize(bytes)))
                                            else
                                                Ui.showInfoMessage(T("No cached covers to remove."))
                                            end
                                        end,
                                    },
                                    {
                                        -- The plugin's own switch for its dbg lines, so they can
                                        -- be had without KOReader's whole debug output.
                                        text = T("Detailed logging"),
                                        keep_menu_open = true,
                                        help_text = T("Writes everything the plugin does to crash.log, including what you search for. Without it only warnings and errors are logged."),
                                        checked_func = function()
                                            return Config.getDetailedLogging()
                                        end,
                                        callback = function()
                                            Config.setDetailedLogging(not Config.getDetailedLogging())
                                        end,
                                    },
                                }
                            end
                        },
                    }
                },
                {
                    text = T("Search"),
                    callback = function()
                        Ui.showSearchDialog(self)
                    end,
                },
                {
                    text = T("Recommended"),
                    callback = function()
                        local search_tab_recommended = 2
                        self:showMultiSearchDialog(search_tab_recommended)
                    end,
                },
                {
                    text = T("Most popular"),
                    callback = function()
                        local search_tab_most_popular = 1
                        self:showMultiSearchDialog(search_tab_most_popular)
                    end,
                },{
                    text = T("My books"),
                    callback = function()
                        self:onZlibrarySearch("mybooks")
                    end,
                    separator = true,
                },
                {
                    -- Last, and never in anyone's way. It is also the only place in the plugin
                    -- that mentions donations: until now the ask lived in the README, which is on
                    -- GitHub, which is not where a reader is when the plugin has just fetched them
                    -- a book. Shows the running version too, so a bug report can start with it.
                    text = T("About"),
                    keep_menu_open = true,
                    callback = function()
                        Ui.showAboutDialog(Ota.getCurrentPluginVersion(self.plugin_path))
                    end,
                },
            }
        }
    end
end

return Zlibrary
