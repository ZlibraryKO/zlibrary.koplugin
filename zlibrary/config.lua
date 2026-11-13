-- The plugin's settings, preferences and server addresses, as one Config table.
--
-- Callers require this module and use Config.<name>, as they always have. The code lives in parts,
-- each filling the same table:
--
--   config_core.lua     the table itself, setting keys, getSetting/saveSetting/deleteSetting, the
--                       runtime and multi-search caches, and the guard for forked children
--   config_catalog.lua  search languages, formats and orders, and the seed mirrors
--   config_mirrors.lua  the base URL, the redirect target a mirror moved to, blocked mirrors, and
--                       the candidate list for discovery
--   config_urls.lua     the URL of every API endpoint
--   config_account.lua  credentials, zlibrary_credentials.lua, the session, and the caches and
--                       search history that belong to one account
--   config_prefs.lua    user agent, timeouts, download folder and categories, search preferences,
--                       view settings
--
-- The parts require config_core, never this facade, so the modules form no cycle
-- (test/module_graph_harness.lua). test/config_surface_harness.lua checks that this facade exposes
-- the same fields the single config.lua did before the split.
local Config = require("zlibrary.config_core")
require("zlibrary.config_catalog")
require("zlibrary.config_mirrors")
require("zlibrary.config_urls")
require("zlibrary.config_account")
require("zlibrary.config_prefs")

return Config
