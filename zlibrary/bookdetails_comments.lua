-- Book comments as HTML for the details dialog's Comments view: threads replies under their
-- parent and escapes everything the server sent. Part of the details dialog; see
-- bookdetails_dialog.lua.

local T = require("zlibrary.gettext")

local BookDetailsDialog = require("zlibrary.bookdetails_core")

-- Escape plain-text values before interpolating them into the HTML handed to ScrollHtmlWidget,
-- so user/server-supplied comment content cannot break the layout or inject markup.
local function htmlEscape(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&#39;"))
end

function BookDetailsDialog:_renderComments(book_comments)
    if not (type(book_comments) == "table" and type(book_comments[1]) == "table") then 
        -- No css of its own, so it picks up the same text styling as "No description available".
        return string.format("<div>%s</div>", T("No Comments"))
    end
    local function generateCommentsHTML(comments)
        local html_parts = {}
        local roots = {}
        local children = {}

        for i = #comments, 1, -1 do
            local comment = comments[i]
            local pid = comment.parent_id
            if pid and pid ~= "" and pid ~= 0 then
                if not children[pid] then children[pid] = {} end
                table.insert(children[pid], comment)
            else
                table.insert(roots, comment)
            end
        end

        -- Flatten if parent_id exists but root node not found
        local flattened = #roots == 0 and #comments > 0
        if flattened then roots = comments end

        local function renderComment(comment, depth)
            local user = comment.user or {}
            local user_name = user.name or "Anonymous"
            local is_premium = user.isPremium and "⭐" or ""
            local date_str = comment.dateRelative or comment.date or ""
            local text = comment.text or ""

            local inline_style = depth > 0 and string.format(' style="margin-left: %sem;"', depth * 1.5) or ""
            local reply_class = depth > 0 and " comment-reply" or ""

            local comment_html = string.format([[
            <div class="comment-node%s"%s>
                <div class="comment-inner">
                    <div class="comment-header">%s <span>%s</span></div>
                    <div class="comment-body">%s</div>
                    <div class="comment-meta">%s</div>
                </div>
            </div>
            ]], reply_class, inline_style, htmlEscape(user_name), is_premium, htmlEscape(text), htmlEscape(date_str))

            table.insert(html_parts, comment_html)

            local child_comments = children[comment.id]
            if child_comments then
                for _, child in ipairs(child_comments) do
                    renderComment(child, depth + 1)
                end
            end
        end

        for _, root_comment in ipairs(roots) do
            renderComment(root_comment, 0)
        end

        -- Replies whose parent_id points at a comment missing from this page never render: they
        -- wait in `children` for a parent that is not there. Append them at the end as top-level
        -- comments rather than dropping them silently. (Not needed after the flatten fallback
        -- above, which already renders every comment.)
        if not flattened then
            local known_ids = {}
            for _, comment in ipairs(comments) do
                if comment.id ~= nil then known_ids[comment.id] = true end
            end
            -- Newest first, the same order the roots were collected in.
            for i = #comments, 1, -1 do
                local comment = comments[i]
                local pid = comment.parent_id
                if pid and pid ~= "" and pid ~= 0 and not known_ids[pid] then
                    renderComment(comment, 0)
                end
            end
        end
        return table.concat(html_parts, "\n")
    end

    local rendered_html = generateCommentsHTML(book_comments)
    local COMMENTS_CSS = "@page { margin: 0; } body{padding-top:0;}.comment-node{margin-top:0.8em;margin-bottom:0.8em;}.comment-reply{border-left:2px solid #ccc;padding-left:1em;}.comment-inner{padding-bottom:0.8em;border-bottom:1px solid #e0e0e0;}.comment-header{font-weight:bold;margin-bottom:0.5em;color:#333;}.comment-body{margin-bottom:0.5em;line-height:1.4;word-break:break-word;}.comment-meta{font-size:0.85em;color:#666;font-style:italic;}"
    return rendered_html, COMMENTS_CSS 
end

return BookDetailsDialog
