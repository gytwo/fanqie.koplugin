--[[--
Native WeRead thought dialog (bottom bar).

Renders a thought's review items in the bottom bar (widget.lua), with long
reviews painted through a bitmap viewport and scrolled inside it
(scroll_container.lua). All sizing/layout comes from pages.lua.

The widget is pooled: reopening the popup reuses the same instance and only
the content is replaced, so the piece/layout caches survive.

@module fanqie.review_popup
--]]

local FaceFactory = require("fanqie.review_popup.face_factory")
local UIManager = require("ui/uimanager")

FaceFactory:init()

local M = {}
local _popup

--- Show (or reopen) the thought popup.
--- @param opts table { pages, doc_font_name, doc_font_size, doc_margins,
---                    height_ratio, contrast, doc_font_weight,
---                    doc_font_gamma, dialog, close_callback, more_text,
---                    on_more, on_replies, para_nav }
function M.show(opts)
    opts = opts or {}
    -- 公共契约用 "pages"，widget 内部叫 "items"。
    opts.items = opts.items or opts.pages
    if type(opts.items) ~= "table" or #opts.items == 0 then
        error("thought popup: invalid pages")
    end

    if _popup then
        _popup:_reopen(opts)
        UIManager:show(_popup)
        return _popup
    end

    local Widget = require("fanqie.review_popup.widget")
    _popup = Widget:new{
        items = opts.items,
        doc_font_name = opts.doc_font_name,
        doc_font_size = opts.doc_font_size,
        doc_margins = opts.doc_margins,
        height_ratio = opts.height_ratio,
        contrast = opts.contrast,
        -- 字重/对比度：首屏用构造函数，续拉走 _reopen —— 两条路径都得带。
        doc_font_weight = opts.doc_font_weight,
        doc_font_gamma = opts.doc_font_gamma,
        dialog = opts.dialog,
        close_callback = opts.close_callback,
        para_nav = opts.para_nav,
        more_text = opts.more_text,
        on_more = opts.on_more,
        on_replies = opts.on_replies,
    }
    UIManager:show(_popup)
    return _popup
end

function M.closeVisible()
    if not _popup then return end
    pcall(function() UIManager:close(_popup) end)
end

--- 文档关闭时释放弹窗子树与位图缓存（由 main.lua 的 onCloseDocument 调用）。
function M.cleanup()
    if not _popup then return end
    pcall(function() UIManager:close(_popup) end)
    -- clear() 释放子树，位图由 _freeContentCaches 释放。
    _popup:clear()
    _popup:_freeContentCaches()
    _popup = nil
end

return M
