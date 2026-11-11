-- The plugin's dialogs, menus and messages, as one Ui table.
--
-- Callers require this module and use Ui.<name>, as they always have. The code lives in parts,
-- each filling the same table:
--
--   ui_core.lua        the table itself, setPluginInstance, messages and loading indicators, the
--                      full-text, about, donation, update, cover and simple dialogs, and the retry
--                      dialog with its timeout hints
--   ui_settings.lua    download folder, search-filter pickers, generic input, timeouts, items per
--                      page, the base-URL list, the credentials dialog
--   ui_categories.lua  managing download categories, and the chooser the open-book prompt offers
--   ui_search.lua      recent searches, the search box, result rows and the results list
--   ui_books.lua       book details, download/remove confirmations, the open-after-download prompt,
--                      the similar-books menu
--
-- Two private modules hold what several parts share and are deliberately not on Ui: ui_shared
-- (dialog tracking, the plugin instance every part reads as `_plugin_instance`) and ui_pickers (the
-- multi-select list behind the filter pickers). The parts require ui_core, ui_shared and
-- ui_pickers, never this facade, so the modules form no cycle (test/module_graph_harness.lua).
-- test/ui_surface_harness.lua checks that the parts still define every function the single
-- ui.lua did.
local Ui = require("zlibrary.ui_core")
require("zlibrary.ui_settings")
require("zlibrary.ui_categories")
require("zlibrary.ui_search")
require("zlibrary.ui_books")

return Ui
