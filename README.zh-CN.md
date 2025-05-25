# [KOReader Z-library 插件](https://github.com/ZlibraryKO/zlibrary.koplugin)

简体中文 | [English](./README.md)

**免责声明：** 本插件仅供教育用途。请尊重版权法并负责任地使用本插件。

在 KOReader 应用中无缝访问 Z-library。该插件允许你直接在电子阅读器中浏览和下载内容。

如果你觉得这个插件有用，请考虑支持其开发。你的捐赠将有助于项目的持续运作，并推动新功能和改进的实现。

<a href="https://buymeacoffee.com/zlibraryko" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/default-orange.png" alt="Buy Me A Coffee" height="41" width="174"></a>

## 演示

<div align="center">
  <img src="assets/search_and_download_zh.gif" width="400">
</div>

## 功能特色

*   在 Z-library 中搜索图书。
*   按语言和文件扩展名过滤搜索结果。
*   浏览最受欢迎和推荐的图书。
*   将内容直接下载到设备上。

## 前提条件

*   你的设备上已安装 KOReader。
*   拥有一个 Z-library 账户。
*   一个 Z-library 的访问链接（URL）。

## 安装方法

1.  下载最新版本的插件发布包。
2.  将 `plugins/zlibrary.koplugin` 目录复制到设备上的 `koreader/plugins` 文件夹中。
3.  重启 KOReader。

## 配置方法

有两种方式可以配置你的 Z-library 凭据：

**1. 通过 KOReader 用户界面 (UI)：**

1.  确保你处于 KOReader 的文件浏览器界面。
2.  打开 “搜索” 菜单。
3.  选择 “Z-library”（可能在该菜单的第二页）。
4.  选择 “设置”。
5.  输入你的 Z-library 邮箱、密码以及 Z-library 实例的基础 URL。
6.  如有需要，可调整其他设置。

**2. 通过凭据文件（高级方式）：**

若你希望进行更永久或自动化的设置，可在 `zlibrary.koplugin` 目录的根目录（例如 `koreader/plugins/zlibrary.koplugin/zlibrary_credentials.lua`）创建一个名为 `zlibrary_credentials.lua` 的文件。

该文件允许你覆盖 UI 中设置的凭据。如果此文件存在并格式正确，插件将使用此文件中的值。

创建 `zlibrary_credentials.lua` 文件，内容如下，取消注释并填写你想使用的具体信息：

```lua
-- 此文件允许你覆盖 Z-library 的登录凭据。
-- 取消注释并填写你想要使用的内容。
-- 此处设置的值优先于插件 UI 中的设置。

return {
    -- baseUrl = "https://your.zlibrary.domain",
    -- email = "your_email",
    -- password = "your_password",
}
```
**注意：** 如果存在 `zlibrary_credentials.lua` 文件，其中设置的凭据将始终优先于通过 UI 设置的凭据。插件在启动时加载这些设置。

## 设置手势（可选）

为了更方便地访问此插件，你可以设置一个手势来打开搜索菜单：

1.  打开顶部菜单并点击 **齿轮图标 (⚙️)**。
2.  导航至 **点击与手势** > **手势管理器**。
3.  在菜单内选择你想使用的手势。
4.  在 **一般** 分类中，找到最后一页的 **Z-library 搜索** 并勾选它。

## 本地化支持（可选）

该插件提供基础的多语言支持，更多信息请参阅 [l10n/README.MD](l10n/README.md)。

## 使用方法

1.  确保你处于 KOReader 的文件浏览器中。
2.  打开 “搜索” 菜单。
3.  选择 “Z-library”。
4.  点击 “搜索”，并输入你的搜索关键词。
5.  或者选择 “推荐” 或 “最受欢迎” 来浏览这些书单。

## 关键词

KOReader、Z-library、电子阅读器、插件、电子书、下载、KOReader 插件、Z-library 集成、数字图书馆、电子墨水、书虫、阅读、开源。
