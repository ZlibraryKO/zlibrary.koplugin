-- The plugin's Z-library API layer, as one Api table.
--
-- Callers require this module and use Api.<name>, as they always have. The code lives in parts,
-- each filling the same table:
--
--   api_core.lua       the table itself, and the error texts callers match by value, with their
--                      classifiers (isCredentialRejection, isBlockedError, ...)
--   api_transport.lua  makeHttpRequest: timeouts, stall retry, redirects, cookies, bot checks
--   api_login.lua      LOGIN_ENDPOINTS and Api.login
--   api_books.lua      search, recommended, most popular, details, similar books, comments
--   api_downloads.lua  the download link, books, covers, and the temp file a download writes
--   api_account.lua    downloaded, favourites, booklists, quota, and the actions on them
--   api_mirrors.lua    healthCheck and fetchDynamicDomains
--
-- api_shared.lua holds the private helpers several parts use (session cookie, authed headers,
-- book records, JSON errors); it is deliberately not on Api. The parts require api_core and
-- api_shared, never this facade, so the modules form no cycle (test/module_graph_harness.lua).
-- test/api_surface_harness.lua checks that this facade exposes the same fields the single
-- api.lua did before the split. Endpoints call Api.makeHttpRequest through the table, which is
-- what lets a harness replace it.
local Api = require("zlibrary.api_core")
require("zlibrary.api_transport")
require("zlibrary.api_login")
require("zlibrary.api_books")
require("zlibrary.api_downloads")
require("zlibrary.api_account")
require("zlibrary.api_mirrors")

return Api
