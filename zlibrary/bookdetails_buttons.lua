-- The details dialog's buttons: Download, More Similar Books, Description, Comments, the
-- favourites toggle, Refresh and Back. Part of the details dialog; see bookdetails_dialog.lua.

local UIManager = require("ui/uimanager")
local T = require("zlibrary.gettext")

local BookDetailsDialog = require("zlibrary.bookdetails_core")

function BookDetailsDialog:onDownloadClick()
    UIManager:close(self)
    self.parent_zlibrary:downloadBook(self.book)
end

function BookDetailsDialog:_buildButtons()
    local dialog_buttons = {}

    if self.view_state ~= "menu" then
        table.insert(dialog_buttons, {{
            text = "\u{21A9}  " .. T("Back"),
            preselect = true,
            callback = function() self:switchState("menu") end
        }})
        return dialog_buttons
    end

    -- Downloading is what this screen is for, so it gets a row of its own at the top and the key
    -- focus. Everything else shares rows, which leaves more of the screen for the description.
    if self.book.format and self.book.format ~= "N/A" then
        if self.book.download then
            table.insert(dialog_buttons, {{
                text = "\u{F019}  " .. string.format("%s (%s)", T("Download"), self.book.format:upper()),
                preselect = true,
                callback = function() self:onDownloadClick() end
            }})
        else
            table.insert(dialog_buttons, {{
                text = "\u{F019}  " .. string.format("%s: %s (Not available)", T("Format"), self.book.format:upper()),
                enabled = false
            }})
        end
    elseif self.book.download then
        table.insert(dialog_buttons, {{
            text = "\u{F019}  " .. T("Download book"),
            preselect = true,
            callback = function() self:onDownloadClick() end
        }})
    end

    local secondary_buttons = {}

    table.insert(secondary_buttons, {
        text = "\u{F002}  " .. T("More Similar Books"),
        preselect = #dialog_buttons == 0 or nil,
        callback = function()
            UIManager:close(self)
            self.parent_zlibrary:searchSimilarBooks(self.book)
        end
    })

    -- Only offer Description when there is one to expand. The menu view already shows it, so this
    -- button trades the button stack for more reading room; with nothing to read it would lead to a
    -- dead-end view holding only a "Back" button.
    if self.book.description and self.book.description ~= "" then
        table.insert(secondary_buttons, {
            text = "\u{F02D}  " .. T("Description"),
            callback = function() self:switchState("description") end
        })
    end

    table.insert(secondary_buttons, {
        text = "\u{F0E5}  " .. T("Comments"),
        callback = function()
            if type(self.parent_zlibrary.fetchAndDisplayComments) == "function" then
                self.parent_zlibrary:fetchAndDisplayComments(self.book, false, function(book_comments)
                    if self._is_closed == true or not UIManager:isWidgetShown(self) then return end
                    local comments_html, css = self:_renderComments(book_comments)
                    self.book.comments_html = comments_html
                    self.book.comments_css= css
                    self:switchState("comments")
                end)
            end
        end
    })

    if self.has_favorite_ids_cache then
        -- A successful favorite/unfavorite from this dialog clears the shared favorites-id cache
        -- (resetFavoritesCache), so a rebuild after a view switch would read a false negative from
        -- the empty cache and show "Add To Favorites" for a just-favorited book. The toggle's
        -- success callback records the new state in _favorite_state_override; trust it while the
        -- cache is empty. Once fresh cache data exists it is authoritative again -- it reflects
        -- any favorite change made elsewhere too -- so drop the override then.
        local in_favorites
        if self.parent_zlibrary:isBookInFavorites() then
            self._favorite_state_override = nil
            in_favorites = self.parent_zlibrary:isBookInFavorites(self.book) == true
        else
            in_favorites = self._favorite_state_override == true
        end
        local favorite_button = self:_generateFavoriteButtonDef(in_favorites)
        favorite_button.align = nil
        table.insert(secondary_buttons, favorite_button)
    end

    if self.is_cache then
        table.insert(secondary_buttons, {
            text = "\u{F021}  " .. T("Refresh"),
            callback = function()
                UIManager:close(self)
                self.clear_cache_callback()
            end
        })
    end

    table.insert(secondary_buttons, {
        text = "\u{21A9}  " .. T("Back"),
        callback = function() UIManager:close(self) end
    })

    -- Two per row. With an odd number, Back ends up alone on the last row, where it has always been.
    for i = 1, #secondary_buttons, 2 do
        table.insert(dialog_buttons, { secondary_buttons[i], secondary_buttons[i + 1] })
    end

    return dialog_buttons
end

function BookDetailsDialog:_generateFavoriteButtonDef(in_favorites)
    return {
        id = "favorite_btn",
        text = in_favorites and ("\u{2665}  " .. T("Remove From Favorites")) or ("\u{2661}  " .. T("Add To Favorites")),
        align = "left",
        callback = function()
            local reload_ui = function()
                local new_in_favorites = not in_favorites
                -- The toggle succeeded and resetFavoritesCache just emptied the shared cache, so
                -- it cannot confirm this state right now. Remember it on the dialog so a rebuild
                -- after a view switch keeps the button honest; _buildButtons drops the override
                -- as soon as fresh cache data makes the state authoritative again.
                self._favorite_state_override = new_in_favorites
                local updated_config = self:_generateFavoriteButtonDef(new_in_favorites)
                local button = self.inner_dialog:getButtonById("favorite_btn")
                
                if button then
                    if type(button.setText) == "function" then
                        button:setText(updated_config.text)
                    else
                        button.text = updated_config.text
                        if type(button.free) == "function" then button:free() end
                    end
                    button.callback = updated_config.callback
                    UIManager:setDirty(self, "ui")
                end
            end
            
            if in_favorites then
                self.parent_zlibrary:unfavoriteBook(self.book, reload_ui)
            else
                self.parent_zlibrary:favoriteBook(self.book, reload_ui)
            end
        end
    }
end

return BookDetailsDialog
