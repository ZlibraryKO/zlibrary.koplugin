-- The rules for the list of recent searches: newest first, no repeats, at most MAX entries.
-- Kept free of KOReader widgets and settings; zlibrary/config.lua stores the result.

local SearchHistory = { MAX = 10 }

local function _matches(a, b)
    return a:lower() == b:lower()
end

function SearchHistory.remove(history, query)
    local kept = {}
    for _, entry in ipairs(history) do
        if not _matches(entry, query) then kept[#kept + 1] = entry end
    end
    return kept
end

-- A repeated search moves to the top, spelled the way it was typed this time.
function SearchHistory.add(history, query)
    local updated = { query }
    for _, entry in ipairs(SearchHistory.remove(history, query)) do
        if #updated >= SearchHistory.MAX then break end
        updated[#updated + 1] = entry
    end
    return updated
end

return SearchHistory
