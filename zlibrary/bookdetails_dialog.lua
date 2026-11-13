-- The book details dialog, opened from a book in any list (Ui.showBookDetails in ui_books.lua).
--
-- One widget class, created in bookdetails_core.lua; each part adds its methods to it:
--
--   bookdetails_core.lua      the class, building and sizing the dialog, switching views, key
--                             focus, the refresh region, closing
--   bookdetails_book.lua      the book record: cleaning up the server's fields, the ISBN, the
--                             metadata lines
--   bookdetails_content.lua   the header beside the cover and the description/comments section
--   bookdetails_cover.lua     the cover: loading, rounded corners, shadow, late arrival
--   bookdetails_buttons.lua   the buttons and the favourites toggle
--   bookdetails_comments.lua  comments rendered as HTML
--
-- The parts require bookdetails_core, never this file, so the modules form no cycle
-- (test/module_graph_harness.lua). test/bookdetails_surface_harness.lua checks that every method
-- the single bookdetails_dialog.lua had is still defined, exactly once, and that every part is
-- required here.

local UIManager = require("ui/uimanager")
local logger = require("logger")

local BookDetailsDialog = require("zlibrary.bookdetails_core")
require("zlibrary.bookdetails_book")
require("zlibrary.bookdetails_content")
require("zlibrary.bookdetails_cover")
require("zlibrary.bookdetails_buttons")
require("zlibrary.bookdetails_comments")

local function showBookDetails(Ui_module, parent_zlibrary, book, clear_cache_callback)
     if not(type(book) == "table" and book.hash and book.title and book.id)then
        logger.warn("BookDetailsDialog: Cannot show details, invalid book data")
        return nil
    end
    local dialog = BookDetailsDialog:new{
        Ui_module = Ui_module,
        parent_zlibrary = parent_zlibrary,
        raw_book = book,
        clear_cache_callback = clear_cache_callback,
        view_state = "menu"
    }
    UIManager:show(dialog, function()  
         return "ui", dialog:getRefreshRegion()  
    end) 
    return dialog
end

return {
    showBookDetails = showBookDetails,
    BookDetailsDialog = BookDetailsDialog 
}