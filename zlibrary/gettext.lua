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

local function _tryLoadLang(lang, original_translation)
    local ok, err = pcall(GetText.changeLang, lang)
    local loaded = ok and (
        (GetText.translation and next(GetText.translation) ~= nil) or
        (GetText.context and next(GetText.context) ~= nil)
    )
    if loaded then
        logger.info(string.format("zlibrary.gettext: loaded translations for '%s'", lang))
        local copied_gettext = util.tableDeepCopy(GetText)
        if copied_gettext then
            NewGetText = copied_gettext
            if NewGetText.translation and original_translation then
                for k, _ in pairs(NewGetText.translation) do
                    if original_translation[k] then
                        NewGetText.translation[k] = nil
                    end
                end
            end
        end
        return true
    end
    if not ok then
        logger.warn(string.format("zlibrary.gettext: error loading '%s': %s", lang, tostring(err)))
    else
        logger.warn(string.format("zlibrary.gettext: no translations found for '%s'", lang))
    end
    return false
end

local changeLang = function(new_lang)
    local original_l10n_dirname = GetText.dirname
    local original_context = GetText.context
    local original_translation = GetText.translation
    local original_wrapUntranslated_func = GetText.wrapUntranslated
    local original_current_lang = GetText.current_lang

    GetText.dirname = NewGetText.dirname

    -- Try full language code, then base language (e.g. "es_ES" -> "es", "zh-CN" -> "zh_CN" -> "zh")
    local loaded = _tryLoadLang(new_lang, original_translation)
    if not loaded then
        -- Normalize hyphens to underscores and try again
        local normalized = new_lang:gsub("%-", "_")
        if normalized ~= new_lang then
            loaded = _tryLoadLang(normalized, original_translation)
        end
    end
    if not loaded then
        -- Try base language (strip region suffix)
        local base_lang = new_lang:match("^([^%-%_]+)")
        if base_lang and base_lang ~= new_lang then
            _tryLoadLang(base_lang, original_translation)
        end
    end

    GetText.context = original_context
    GetText.translation = original_translation
    GetText.dirname = original_l10n_dirname
    GetText.wrapUntranslated = original_wrapUntranslated_func
    GetText.current_lang = original_current_lang

    original_translation = nil
    original_context = nil
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

    return setmetatable({
        -- dump the parsed data of the po file. For debugging only.
        -- If NewGetText is not loaded, this will be nil value when called
        debug_dump = function()
            local new_lang = new_gettext.current_lang
            local dump_path = string.format("%s/%s/%s", new_gettext.dirname, new_lang, "debug_logs.lua")
            require("luasettings"):open(dump_path):saveSetting("po", new_gettext):flush()
            logger.info(string.format("debug_dump: %s.po to %s", new_lang, dump_path))
      end
    }, mt)
end

local current_lang = GetText.current_lang or G_reader_settings:readSetting("language")
if current_lang then
    changeLang(current_lang)
end

return createGetTextProxy(NewGetText, GetText)
