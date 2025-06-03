local search_orde_item = {}

for _, v in ipairs(Config.ORDERS) do
        v["name"], v[""]
end
local ss = {
    text = T("Search Settings"),
    keep_menu_open = true,
    separator = true,
    sub_item_table = {{
        text = T("Select search languages"),
        keep_menu_open = true,
        callback = function()
            Ui.showLanguageSelectionDialog(self.ui)
        end
    }, {
        text = T("Select search formats"),
        keep_menu_open = true,
        callback = function()
            Ui.showExtensionSelectionDialog(self.ui)
        end
    }, {
        text = T("Search Orde"),
        keep_menu_open = true,
        separator = true,
        callback = function()
            Ui.showOrdesSelectionDialog(self.ui)
        end
    }}
}
