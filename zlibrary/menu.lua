local Menu = require("ui/widget/menu")
local Device = require("device")
local Screen = Device.screen
local Size = require("ui/size")
local Geom = require("ui/geometry")
local logger = require("logger")
local Cache = require("zlibrary.cache")
local util = require("util")
local ImageWidget = require("ui/widget/imagewidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local M = Menu:extend{}

-- fix no_title = true koreader crash
function M:mergeTitleBarIntoLayout()
    if self.no_title then
        return
    end
    Menu.mergeTitleBarIntoLayout(self)
end

--- Verifica si un cover existe en caché y es válido.
--- @param hash string El hash del libro
--- @return string|nil Ruta al cover si existe, nil si no
local function _getCachedCoverPath(hash)
    if not hash or hash == "" then return nil end
    local cover_path = Cache.getCoverPath(hash)
    if not cover_path then return nil end
    if not util.fileExists(cover_path) then return nil end
    return cover_path
end

--- Override updateItems para inyectar covers SOLO si existen en caché.
--- Nunca inyecta shortcuts para covers que no estén descargados.
function M:updateItems(select_number, no_recalculate_dimen)
    local ok, err = pcall(function()
        -- Solo procesar si hay item_table y no usa items_max_lines
        if not self.item_table or self.items_max_lines then
            Menu.updateItems(self, select_number, no_recalculate_dimen)
            return
        end

        -- Detectar items visibles que tienen cover EN CACHÉ
        local perpage = self.perpage or 14
        local idx_offset = (self.page - 1) * perpage
        local cover_shortcuts = {}
        local has_any_cover = false

        for idx = 1, perpage do
            local item = self.item_table[idx_offset + idx]
            if item and type(item.shortcut) == "string" and item.shortcut:sub(1, 6) == "cover:" then
                local hash = item.shortcut:sub(7)
                local cached_path = _getCachedCoverPath(hash)
                if cached_path then
                    -- Cover existe en caché: inyectar shortcut
                    cover_shortcuts[idx] = item.shortcut
                    has_any_cover = true
                end
                -- Si NO existe en caché: no inyectar shortcut (se muestra solo texto)
            end
        end

        if has_any_cover then
            -- Guardar estado original
            local orig_enable = self.is_enable_shortcut
            local orig_shortcuts = self.item_shortcuts

            self.is_enable_shortcut = true
            self.item_shortcuts = cover_shortcuts

            Menu.updateItems(self, select_number, no_recalculate_dimen)

            -- Restaurar estado
            self.item_shortcuts = orig_shortcuts
            self.is_enable_shortcut = orig_enable
        else
            -- Ningún cover en caché: renderizar sin covers
            Menu.updateItems(self, select_number, no_recalculate_dimen)
        end
    end)

    if not ok then
        logger.err("zlibrary.menu:updateItems error:", tostring(err))
        -- Fallback: renderizar sin covers
        self.is_enable_shortcut = false
        pcall(Menu.updateItems, self, select_number, no_recalculate_dimen)
    end
end

--- Override getItemShortCutIcon para renderizar portadas.
--- Solo se llama para items que tienen cover confirmado en caché.
function M:getItemShortCutIcon(dimen, key, style)
    if type(key) ~= "string" or key:sub(1, 6) ~= "cover:" then
        return Menu.getItemShortCutIcon(self, dimen, key, style)
    end

    local hash = key:sub(7)
    local cover_path = _getCachedCoverPath(hash)

    if not cover_path then
        -- No debería llegar aquí, pero por seguridad
        return WidgetContainer:new{
            dimen = Geom:new{ w = dimen.w, h = dimen.h },
        }
    end

    -- Dimensiones rectangulares: ratio ~2:3 (portada de libro estándar)
    local cover_h = dimen.h
    local cover_w = math.floor(cover_h * 2 / 3)
    if cover_w > dimen.w then
        cover_w = dimen.w
    end

    -- Cargar imagen con pcall para evitar crashes
    local load_ok, widget = pcall(function()
        local img = ImageWidget:new{
            file = cover_path,
            width = cover_w,
            height = cover_h,
            scale_factor = 0, -- auto-escala preservando aspecto
        }

        return CenterContainer:new{
            dimen = Geom:new{ w = dimen.w, h = dimen.h },
            img,
        }
    end)

    if load_ok and widget then
        return widget
    end

    -- Si falla la carga de imagen, eliminar el archivo corrupto
    logger.err("zlibrary.menu: ImageWidget failed:", tostring(widget))
    pcall(os.remove, cover_path)

    -- Retornar widget vacío seguro (con dimensiones correctas)
    return WidgetContainer:new{
        dimen = Geom:new{ w = dimen.w, h = dimen.h },
    }
end

return M