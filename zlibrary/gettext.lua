local util = require("util")
local GetText = require("gettext")
local logger = require("logger")

local full_source_path = debug.getinfo(1, "S").source
if full_source_path:sub(1, 1) == "@" then
    full_source_path = full_source_path:sub(2)
end
local lib_path, _ = util.splitFilePathName(full_source_path)
local plugin_path = lib_path:gsub("/+", "/"):gsub("[\\/]zlibrary[\\/]", "")

local NewGetText = {
    dirname = string.format("%s/l10n", plugin_path)
}

local changeLang = function(new_lang)
    local original_l10n_dirname = GetText.dirname
    local original_context = GetText.context
    local original_translation = GetText.translation
    local original_wrapUntranslated_func = GetText.wrapUntranslated
    local original_current_lang = GetText.current_lang

    -- Save current KOReader translations, then clear for plugin loading
    local saved_translation = util.tableDeepCopy(GetText.translation) or {}
    GetText.translation = {}
    GetText.context = {}

    -- Directly load plugin .mo file instead of using changeLang
    -- (changeLang ignores dirname changes in newer KOReader versions)
    local mo_path = string.format("%s/%s/%s.mo", NewGetText.dirname, new_lang, GetText.textdomain or "koreader")
    local load_ok = false
    if GetText.loadMO then
        load_ok = GetText.loadMO(mo_path)
    end

    if load_ok and GetText.translation and next(GetText.translation) ~= nil then
        local copied_gettext = util.tableDeepCopy(GetText)
        if copied_gettext then
            NewGetText = copied_gettext
            NewGetText.current_lang = new_lang
            NewGetText.dirname = NewGetText.dirname or string.format("%s/l10n", plugin_path)
            -- Copy over functions we need from original GetText
            if not NewGetText.wrapUntranslated then
                NewGetText.wrapUntranslated = original_wrapUntranslated_func
            end
            if not NewGetText.getPlural then
                NewGetText.getPlural = GetText.getPlural
            end
            --  reduce memory usage: remove entries identical to KOReader's
            if NewGetText.translation and saved_translation then
                for k, v in pairs(NewGetText.translation) do
                    if type(v) == "string" and saved_translation[k] == v then
                        NewGetText.translation[k] = nil
                    end
                end
            end
        end
    else
        logger.warn(string.format("[zlibrary] Failed to load MO file: %s", mo_path))
    end

    -- Restore original KOReader state
    GetText.context = original_context
    GetText.translation = original_translation
    GetText.dirname = original_l10n_dirname
    GetText.wrapUntranslated = original_wrapUntranslated_func
    GetText.current_lang = original_current_lang
end

local function createGetTextProxy(new_gettext, gettext)
    if not new_gettext.current_lang or new_gettext.current_lang == "C" or
       not (new_gettext.wrapUntranslated and new_gettext.translation) then
        return gettext
    end

    local function getCompareStr(key, args)
        if key == "gettext" then
            return args[1]
        elseif key == "pgettext" then
            return args[2]
        elseif key == "ngettext" then
            local n = args[3]
            return (new_gettext.getPlural and new_gettext.getPlural(n) == 0) and args[1] or args[2]
        elseif key == "npgettext" then
            local n = args[4]
            return (new_gettext.getPlural and new_gettext.getPlural(n) == 0) and args[2] or args[3]
        end
        return nil
    end

    local mt = {
        __index = function(_, key)
            local value = new_gettext[key]
            if type(value) ~= "function" then
                return value
            end

            local fallback_func = gettext[key]
            return function(...)
                local args = {...}
                local msgstr = value(...)
                local compare_str = getCompareStr(key, args)

                if msgstr and compare_str and msgstr == compare_str then
                     if type(fallback_func) == "function" then
                        msgstr = fallback_func(...)
                    end
                end
                return msgstr
            end
        end,
        __call = function(_, msgid)
            local msgstr = new_gettext(msgid)
            if msgstr and msgstr == msgid then
                msgstr = gettext(msgid)
            end
            return msgstr
        end
    }

    return setmetatable({}, mt)
end

local current_lang = GetText.current_lang or G_reader_settings:readSetting("language")
if current_lang then
    changeLang(current_lang)
end

return createGetTextProxy(NewGetText, GetText)
