local DataStorage = require("datastorage")
local isAndroid, android = pcall(require, "android")
local util = require("util")
local GetText = require("gettext")

local NewGetText = {
    dirname = string.format("%s/plugins/zlibrary.koplugin/l10n", DataStorage:getDataDir())
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

if os.getenv("LANGUAGE") then
    changeLang(os.getenv("LANGUAGE"))
elseif os.getenv("LC_ALL") then
    changeLang(os.getenv("LC_ALL"))
elseif os.getenv("LC_MESSAGES") then
    changeLang(os.getenv("LC_MESSAGES"))
elseif os.getenv("LANG") then
    changeLang(os.getenv("LANG"))
end

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

return NewGetText.wrapUntranslated and NewGetText or GetText

