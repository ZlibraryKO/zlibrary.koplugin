-- Does the Ui table still have every function it had before ui.lua was split?
--
-- ui.lua was one 1,950-line module. It is now a facade over ui_core, ui_settings, ui_categories,
-- ui_search and ui_books, which all fill the one Ui table, with private helpers in ui_shared and
-- ui_pickers that deliberately stay off it. Ten modules call Ui.<name> and none of them changed, so
-- every name has to still be defined -- and exactly once, since a second definition in another part
-- would silently replace the first.
--
-- Read from the sources rather than by loading the module, which needs KOReader's widget stack. The
-- list was recorded from the unsplit ui.lua on 2026-11-10 (44 functions).

local PLUGIN = assert(arg[1], "usage: luajit ui_surface_harness.lua <plugin-root> <luasocket-src>")
local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local EXPECTED = {
    "appendSearchResultsToMenu",
    "buildCategoriesMenuItems",
    "buildOneCategoryMenuItems",
    "closeDialog",
    "closeMessage",
    "colonConcat",
    "confirmClearCredentials",
    "confirmDownload",
    "confirmOpenBook",
    "confirmRemoveDownloaded",
    "createBookMenuItem",
    "createPerPageSettingCallback",
    "createSearchResultsMenu",
    "createSingleBookMenu",
    "setPluginInstance",
    "showAboutDialog",
    "showAllTimeoutConfigDialog",
    "showBookDetails",
    "showBookDownloadProgress",
    "showCancellableLoadingMessage",
    "_showCategoryChooser",
    "showCategoryNameDialog",
    "showCoverDialog",
    "_showCreateCategoryDialog",
    "showCredentialsDialog",
    "showDonationQrCode",
    "showDownloadDirectoryDialog",
    "showErrorMessage",
    "showExtensionSelectionDialog",
    "showFullTextDialog",
    "showGenericInputDialog",
    "showInfoMessage",
    "showLanguageSelectionDialog",
    "showLoadingMessage",
    "showOrdersSelectionDialog",
    "showRetryErrorDialog",
    "showSearchDialog",
    "showSearchErrorDialog",
    "showSearchHistoryDialog",
    "showSimilarBooksMenu",
    "showSimpleMessageDialog",
    "showTimeoutConfigDialog",
    "showUpdateInstalledDialog",
    "showUrlCheckProgress",
}

local defined = {}
for _, path in ipairs(support.ui_files(PLUGIN)) do
    local fh = assert(io.open(path))
    local src = "\n" .. fh:read("*a")
    fh:close()
    local file = path:match("[^/]+$")
    for name in src:gmatch("\nfunction Ui%.([%w_]+)%(") do
        defined[name] = defined[name] or {}
        table.insert(defined[name], file)
    end
    for name in src:gmatch("\nUi%.([%w_]+)%s*=") do
        defined[name] = defined[name] or {}
        table.insert(defined[name], file)
    end
end

local missing, twice, extra, expected = {}, {}, {}, {}
for _, name in ipairs(EXPECTED) do
    expected[name] = true
    if not defined[name] then missing[#missing + 1] = name end
end
for name, files in pairs(defined) do
    if not expected[name] then extra[#extra + 1] = name end
    if #files > 1 then twice[#twice + 1] = name .. " (" .. table.concat(files, ", ") .. ")" end
end
table.sort(missing); table.sort(twice); table.sort(extra)

r.check(string.format("all %d recorded Ui functions are still defined", #EXPECTED),
        #missing == 0, "missing: " .. table.concat(missing, ", "))
r.check("each exactly once", #twice == 0, "defined twice: " .. table.concat(twice, "; "))
r.check("and nothing new on Ui -- private helpers stay in ui_shared / ui_pickers",
        #extra == 0, "not recorded: " .. table.concat(extra, ", "))

r.finish()
