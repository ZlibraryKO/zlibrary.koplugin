local util = require("util")
local GetText = require("gettext")
local logger = require("logger")

-- Change this parameter to true to dump the parsed data of the po file. For debugging only.
local debug_dump = false

local full_source_path = debug.getinfo(1, "S").source
if full_source_path:sub(1, 1) == "@" then
    full_source_path = full_source_path:sub(2)
end
local lib_path, _ = util.splitFilePathName(full_source_path)
local plugin_path = lib_path:gsub("[\\/]zlibrary[\\/]", "")

local NewGetText = {
    dirname = string.format("%s/l10n", plugin_path)
}

local changeLang = function(new_lang)
    local original_l10n_dirname = GetText.dirname
    local original_context = GetText.context
    local original_translation = GetText.translation
    local original_wrapUntranslated_func = GetText.wrapUntranslated

    GetText.dirname = NewGetText.dirname

    local ok, err = pcall(GetText.changeLang, new_lang)
    if not ok then
        logger.warn( string.format("Failed to parse the PO file for lang %s: %s", tostring(new_lang), tostring(err)))
    end

    if (GetText.translation and next(GetText.translation) ~= nil) or (GetText.context and next(GetText.context) ~= nil) then
        NewGetText = util.tableDeepCopy(GetText)
    end

    GetText.context = original_context
    GetText.translation = original_translation
    GetText.dirname = original_l10n_dirname
    GetText.wrapUntranslated = original_wrapUntranslated_func

    -- reuse koreader-translation
    if NewGetText.wrapUntranslated and NewGetText.translation then
        NewGetText.wrapUntranslated = function(msgid)
            return GetText(msgid)
        end
        for k, v in pairs(NewGetText.translation) do
            if k and GetText.translation[k] then
                NewGetText.translation[k] = nil
            end
        end
    end

    -- debug_dump
    if debug_dump == true then
        local dump_path = string.format("%s/%s/%s", NewGetText.dirname, tostring(new_lang), "debug_dump.lua")
        if NewGetText.translation then
            require("luasettings"):open(dump_path):saveSetting("po", NewGetText.translation):flush()
            logger.info( string.format("debug_dump: %s.po to %s", tostring(new_lang), dump_path))
        else
            logger.warn( string.format("debug_dump: NewGetText.translation is nil for lang %s", tostring(new_lang)))
        end
    end
end

local setting_language = G_reader_settings:readSetting("language")
if setting_language then
    changeLang(setting_language)
else
    if os.getenv("LANGUAGE") then
        changeLang(os.getenv("LANGUAGE"))
    elseif os.getenv("LC_ALL") then
        changeLang(os.getenv("LC_ALL"))
    elseif os.getenv("LC_MESSAGES") then
        changeLang(os.getenv("LC_MESSAGES"))
    elseif os.getenv("LANG") then
        changeLang(os.getenv("LANG"))
    end

    local isAndroid, android = pcall(require, "android")
    if isAndroid then
        local ffi = require("ffi")
        local buf = ffi.new("char[?]", 16)
        android.lib.AConfiguration_getLanguage(android.app.config, buf)
        local lang = ffi.string(buf)
        android.lib.AConfiguration_getCountry(android.app.config, buf)
        local country = ffi.string(buf)
        if lang and country then
            changeLang(lang .. "_" .. country)
        end
    end
end

return NewGetText.wrapUntranslated and NewGetText or GetText