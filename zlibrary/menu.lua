local Menu = require("ui/widget/menu")

local M = Menu:extend{
}
-- fix no_title = true koreader crash
function M:mergeTitleBarIntoLayout()
    if self.no_title then
        return
    end
   Menu.mergeTitleBarIntoLayout(self)
end

return M