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
    -- changeLang rebuilds getPlural from the catalogue's Plural-Forms header
    -- (koreader frontend/gettext.lua:220), so loading ours leaves KOReader's global
    -- plural selector pointing at OUR header. Restore it with the rest.
    local original_getPlural = GetText.getPlural

    GetText.dirname = NewGetText.dirname

    local ok, err = pcall(GetText.changeLang, new_lang)
    if ok then
        if (GetText.translation and next(GetText.translation) ~= nil) or (GetText.context and next(GetText.context) ~= nil) then
            local copied_gettext = util.tableDeepCopy(GetText)
            if copied_gettext then
                NewGetText = copied_gettext
                --  reduce memory usage and prioritize using KOReader-translation
                if NewGetText.translation and original_translation then
                    for k, v in pairs(NewGetText.translation) do
                        if original_translation[k] then
                            NewGetText.translation[k] = nil
                        end
                    end
                end
            end
        end
    else
        logger.warn(string.format("Failed to parse the PO file for lang %s: %s", tostring(new_lang), tostring(err)))
    end

    GetText.context = original_context
    GetText.translation = original_translation
    GetText.dirname = original_l10n_dirname
    GetText.wrapUntranslated = original_wrapUntranslated_func
    GetText.current_lang = original_current_lang
    GetText.getPlural = original_getPlural

    original_translation = nil
    original_context = nil
end

local function createGetTextProxy(new_gettext, gettext)
    if not new_gettext.current_lang or new_gettext.current_lang == "C" or 
       not (new_gettext.wrapUntranslated and new_gettext.translation) then
        return gettext
    end

    -- KOReader implements these as GetText_mt.__index functions that reference the
    -- GLOBAL GetText table (frontend/gettext.lua:411-481), and util.tableDeepCopy
    -- copies functions by reference, so the copies in new_gettext would still query
    -- KOReader's catalogue. Look them up against our own catalogue instead,
    -- mirroring KOReader's lookup logic.
    local catalogue_funcs = {
        pgettext = function(msgctxt, msgid)
            return new_gettext.context[msgctxt] and new_gettext.context[msgctxt][msgid]
                or new_gettext.wrapUntranslated(msgid)
        end,
        ngettext = function(msgid, msgid_plural, n)
            local plural = new_gettext.getPlural(n)
            if plural == 0 then
                return new_gettext.translation[msgid] and new_gettext.translation[msgid][plural]
                    or new_gettext.wrapUntranslated(msgid)
            else
                return new_gettext.translation[msgid] and new_gettext.translation[msgid][plural]
                    or new_gettext.wrapUntranslated(msgid_plural)
            end
        end,
        npgettext = function(msgctxt, msgid, msgid_plural, n)
            local plural = new_gettext.getPlural(n)
            if plural == 0 then
                return new_gettext.context[msgctxt] and new_gettext.context[msgctxt][msgid]
                    and new_gettext.context[msgctxt][msgid][plural] or new_gettext.wrapUntranslated(msgid)
            else
                return new_gettext.context[msgctxt] and new_gettext.context[msgctxt][msgid]
                    and new_gettext.context[msgctxt][msgid][plural] or new_gettext.wrapUntranslated(msgid_plural)
            end
        end,
    }

    -- What each lookup returns when our catalogue has no translation: the msgid (or
    -- msgid_plural) run through wrapUntranslated. Under RTL UI languages bidi overrides
    -- that to add LTR isolate marks (frontend/ui/bidi.lua), so comparing against the
    -- raw msgid would never match and the fallback to KOReader's translation would
    -- never fire.
    local function getCompareStr(key, args)
        local msgid
        if key == "gettext" then
            msgid = args[1]
        elseif key == "pgettext" then
            msgid = args[2]
        elseif key == "ngettext" then
            msgid = (new_gettext.getPlural and new_gettext.getPlural(args[3]) == 0) and args[1] or args[2]
        elseif key == "npgettext" then
            msgid = (new_gettext.getPlural and new_gettext.getPlural(args[4]) == 0) and args[2] or args[3]
        end
        if msgid then
            return new_gettext.wrapUntranslated(msgid)
        end
        return nil
    end

    local mt = {
        __index = function(_, key)
            local value = catalogue_funcs[key] or new_gettext[key]
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
            if msgstr and msgstr == new_gettext.wrapUntranslated(msgid) then
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
