-- 插件元信息唯一来源：版本号 / 描述 / 关于文案（main.lua 与 _meta.lua 都从这里读）。
-- about_template 用 T() 格式化：%1 = 版本号，%2 = 缓存目录。

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

return {
    -- 版本号（唯一来源，main.lua 和 _meta.lua 都读这里）
    version = "2.2.0-fixed.6.2-mod",

    -- 插件描述（_meta.lua 的 description 字段使用）
    description = _("在 KOReader 中阅读番茄小说，支持扫码登录、多书源、段评、两层智能缓存、进度同步，适配墨水屏黑白显示。"),

    -- 关于文案模板：main.lua 两处「关于」对话框共用
    -- 修改文案只需改这一处，两处关于对话框自动同步
    about_template = _("番茄小说hesan1232 v%1\n\n seaneasysaid改版:\n• 书源调整：书山 | 知秋 | 番茄官方，多书源自动回退。\n• 书架 UI 改版：封面网格、圆角卡片、进度标注。\n\n gytwo改版:\n• 搜索书籍：可搜索非番茄书架的书籍并直接阅读（但无法加入番茄书架、不同步进度）。\n• 下载全本并生成 EPUB：自动合并已缓存章节并生成EPUB书籍。\n• 本地书籍匹配段评：按书名匹配番茄书，按章节标题匹配章节，可重新手动匹配，可缓存章节段评供离线查看。\n• 绕过番茄书架打开目录、加载段评：从文件管理器直接打开已缓存章节也能正常用。\n• 快捷手势：注册[番茄-书架/目录]、[番茄-搜索书籍]（常规类）及[番茄-拉取段评]（阅读类）。\n• 缓存文件夹封面：缓存章节时自动下载封面为 cover.jpg，方便美化插件识别。\n• 缓存文件夹命名：新建缓存文件夹按 title-id 命名。\n• 拉取云端数据前先检测网络，未联网时弹 WiFi 连接框，连上后自动继续。\n\n缓存目录: %2"),
}
