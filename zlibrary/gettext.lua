local util = require("util")
local GetText = require("gettext")

local full_source_path = debug.getinfo(1, "S").source
if full_source_path:sub(1,1) == "@" then
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

    GetText.dirname = NewGetText.dirname
    GetText.wrapUntranslated = function(msgid)
        return GetText(msgid)
    end
    GetText.changeLang(new_lang)

    if (GetText.translation and next(GetText.translation) ~= nil) or 
            (GetText.context and next(GetText.context) ~= nil) then
        NewGetText = util.tableDeepCopy(GetText)
    end

    GetText.context = original_context
    GetText.translation = original_translation
    GetText.dirname = original_l10n_dirname
    GetText.wrapUntranslated = GetText.wrapUntranslated_nowrap
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

