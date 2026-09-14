-- 插件元信息集中管理：版本号、描述、关于文案
-- 所有需要展示版本/关于的地方统一从这里读取，避免多处维护不同步。
--   - main.lua: require("fanqie.info") 读取 version 和 about_template
--   - _meta.lua: pcall(require, "fanqie.info") 读取 version 和 description
--
-- about_template 用 T() 格式化，占位符：
--   %1 = 版本号（self.version）
--   %2 = 缓存目录（self.settings:get_download_dir()）

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

return {
    -- 版本号（唯一来源，main.lua 和 _meta.lua 都读这里）
    version = "2.2.1",

    -- 插件描述（_meta.lua 的 description 字段使用）
    description = _("在 KOReader 中阅读番茄小说，支持扫码登录、多书源、段评、两层智能缓存、进度同步，适配墨水屏黑白显示。"),

    -- 关于文案模板：main.lua 两处「关于」对话框共用
    -- 修改文案只需改这一处，两处关于对话框自动同步
    about_template = _("番茄小说插件 v%1\n\n为 KOReader 打造的墨水屏阅读体验，适配黑白电子墨水屏。\n\n gytwo自改版本:\n• 搜索功能：可搜索非番茄书架的书籍并直接阅读(但无法加入番茄书架）\n• 取消patch历史记录：阅读的番茄书籍章节也会出现在历史记录中，可通过继续阅读直接打开已缓存的章节 \n• 绕过番茄书架打开目录、加载段评：通过文件管理器或历史记录直接打开已缓存书籍章节也能直接打开目录，正常加载段评 \n• 快捷手势：添加注册[番茄-书架/目录]、[番茄-搜索书籍]两个系统动作（常规类）\n• 缓存文件夹封面：缓存某书籍章节时自动下载书籍封面并命名为cover.jpg放至该文件夹内，方便其他美化插件识别为文件夹封面\n• 缓存文件夹名称：缓存某书籍章节新建文件夹时自动按title-id命名"),
}
