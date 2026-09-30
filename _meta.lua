local _ = require("gettext")

-- 版本号和描述统一从 fanqie/info.lua 读取，避免多处维护不同步。
-- _meta.lua 在插件扫描阶段加载，此时 require 路径已可用，
-- 但为防止异常情况下用硬编码 fallback 保底。
local ok_info, info = pcall(require, "fanqie.info")
local version = (ok_info and info and info.version) or "2.2.1"
local description = (ok_info and info and info.description)
    or _("在 KOReader 中阅读番茄小说，支持扫码登录、多书源、段评、两层智能缓存、进度同步，适配墨水屏黑白显示。")

return {
    name = "fanqie",
    fullname = _("番茄小说"),
    description = description,
    version = version,
}
-- 上游原版v2.2.1 https://github.com/hesan1232/fanqie.koplugin 
-- 上游分支改版v2.2.0-fixed.4 https://github.com/seaneasysaid/fanqie.koplugin-fixed
-- 主要修改点（VS上游原版）：书山聚合 + 知秋段评 + 书架UI
-- 本版本v2.2.1-b https://github.com/gytwo/fanqie.koplugin
-- 主要修改点（VS上游分支改版）：为本地书籍拉取段评 + 搜索书籍（非番茄书架书籍会按书源搜索）
