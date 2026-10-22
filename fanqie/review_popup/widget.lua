--[[--
Thought popup widget (bottom position).

Renders review items by shaping each text block with the document font (or a
fallback chain) and paginating once; pages are blitted into a bitmap viewport
that scrolls. Long content scrolls directly, with no button navigation.

Pagination, layout, page and piece caches live in fanqie/review_popup/
pages.lua (PageRenderer). This module composes the renderer into the bottom
bar: a solid top border, a scrollable page viewport (scroll_container.lua),
and bottom/tap/Back gestures.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local PageRenderer = require("fanqie.review_popup.pages")
local ScrollContainer = require("fanqie.review_popup.scroll_container")
local Size = require("ui/size")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
-- 日志模块缺失时静默降级（测试环境 / 精简安装）
local ok_log, Log = pcall(require, "fanqie.logger")
if not ok_log then Log = nil end

local TOP_BORDER_SIZE = Size.line.thick
local PADDING = Size.padding.large

local ThoughtPopupWidget = InputContainer:extend{
    items = nil,
    doc_font_name = nil,
    doc_font_size = Screen:scaleBySize(18),
    doc_margins = {
        left = Screen:scaleBySize(20),
        right = Screen:scaleBySize(20),
        top = Screen:scaleBySize(10),
        bottom = Screen:scaleBySize(10),
    },
    height_ratio = 0.70,
    contrast = 9,
    doc_font_weight = 0,
    doc_font_gamma = 0,
    close_callback = nil,
    dialog = nil,
    -- Optional fanqie navigation: when set, a horizontal swipe calls
    -- para_nav("next") / para_nav("prev") instead of closing. Swiping to
    -- close stays available through tap-outside and the Back key.
    para_nav = nil,

    -- 底部「继续加载（还剩 N 条）」按钮：more_text 为文案（nil 则不显示），
    -- on_more 为点击回调。加载中回调内部用 _more_busy 挡连点。
    more_text = nil,
    on_more = nil,
    _more_busy = false,
    -- 二级评论回调：on_replies(item, cursor, done)，
    -- done(ok, result, err)，result = { replies, total, has_more, cursor }
    on_replies = nil,
    -- 续拉重开后恢复的滚动位置（内容坐标）；_buildLayout 消费后清零
    _restore_offset = nil,

    _pages = nil,
    _scroll_container = nil,

    covers_footer = true,
}

--- 高度比例钳制 + 尺寸换算（init 与 _reopen 共用）。
function ThoughtPopupWidget:_clampHeight()
    self.height_ratio = math.max(0.1, math.min(0.9, self.height_ratio or 0.70))
    self.width = Screen:getWidth()
    self.height = math.floor(Screen:getHeight() * self.height_ratio)
end

function ThoughtPopupWidget:init()
    self:_clampHeight()

    if Device:isTouchDevice() then
        local range = Geom:new{
            x = 0, y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        }
        self.ges_events = {
            TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = range,
                }
            },
            SwipeClose = {
                GestureRange:new{
                    ges = "swipe",
                    range = range,
                }
            },
        }
    end

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end

    self._pages = PageRenderer:new{
        items = self.items,
        doc_font_name = self.doc_font_name,
        doc_font_size = self.doc_font_size,
        doc_margins = self.doc_margins,
        height_ratio = self.height_ratio,
        contrast = self.contrast,
        doc_font_weight = self.doc_font_weight,
        doc_font_gamma = self.doc_font_gamma,
    }
    self._pages:ensureLayout()
    self:_buildLayout()
end

function ThoughtPopupWidget:onShow()
    UIManager:setDirty(self, function()
        return "partial", self.container.dimen
    end)
end

function ThoughtPopupWidget:_reopen(opts)
    -- 续拉重开（opts.restore_scroll=true）才恢复滚动位置；
    -- 点新段落重开时不带该标记，避免弹窗一打开就停在旧滚动位置
    if opts.restore_scroll and self._scroll_container then
        self._restore_offset = self._scroll_container.scroll_offset or 0
    else
        self._restore_offset = nil
    end
    self._more_busy = false
    self.items = opts.items or {}
    if opts.doc_font_name then self.doc_font_name = opts.doc_font_name end
    if opts.doc_font_size then self.doc_font_size = opts.doc_font_size end
    if opts.doc_margins then self.doc_margins = opts.doc_margins end
    if opts.height_ratio then self.height_ratio = opts.height_ratio end
    if opts.contrast ~= nil then self.contrast = opts.contrast end
    if opts.doc_font_weight ~= nil then self.doc_font_weight = opts.doc_font_weight end
    if opts.doc_font_gamma ~= nil then self.doc_font_gamma = opts.doc_font_gamma end
    if opts.dialog then self.dialog = opts.dialog end
    self.close_callback = opts.close_callback
    self.para_nav = opts.para_nav
    self.more_text = opts.more_text
    self.on_more = opts.on_more
    self.on_replies = opts.on_replies
    self:_clampHeight()

    self._pages:setContent(self.items, self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio, self.contrast,
        self.doc_font_weight, self.doc_font_gamma)
    self:_buildLayout()
end

function ThoughtPopupWidget:_buildLayout()
    self:clear()

    local item_width = math.min(math.ceil(self.doc_margins.right * 2 / 5), Screen:scaleBySize(10))
    local text_w = self._pages.text_w
    local content_h = self._pages.content_h

    local ratio_h = math.floor(Screen:getHeight() * self.height_ratio)
    local chrome = TOP_BORDER_SIZE + 2 * PADDING

    -- 「继续加载」按钮：先建好并量高度，把占的纵向空间一起计进 chrome，
    -- 否则视口会把按钮挤出屏幕
    local more_btn
    if self.more_text and self.on_more then
        local Button = require("ui/widget/button")
        more_btn = Button:new{
            text = self.more_text,
            width = self.width - Screen:scaleBySize(24),  -- 铺满（左右各留 12px 边距）
            text_font_bold = false,
            callback = function()
                if self._more_busy then return end
                self._more_busy = true
                self.on_more()
            end,
        }
        local ok_size, btn_size = pcall(function() return more_btn:getSize() end)
        local btn_h = (ok_size and btn_size and btn_size.h) or Screen:scaleBySize(36)
        chrome = chrome + btn_h + Screen:scaleBySize(14)
    end
    -- 布局诊断（仅 DEBUG 级，需开启 developer_logs）
    if Log and Log.debug then
        Log.debug(string.format("[段评] 布局 btn=%s ratio_h=%d content_h=%d chrome=%d",
            tostring(more_btn ~= nil), ratio_h, content_h, chrome))
    end
    local blank_tolerance = math.ceil((self.doc_font_size or Screen:scaleBySize(18)) * 1.2)

    local viewport_h
    if content_h + chrome <= ratio_h - blank_tolerance then
        viewport_h = content_h
        self.height = content_h + chrome
    else
        viewport_h = ratio_h - chrome
        self.height = ratio_h
    end
    if viewport_h < 1 then viewport_h = 1 end

    local scroll = ScrollContainer:new{
        content_h = content_h,
        viewport_h = viewport_h,
        scrollbar_w = item_width,
        margin_left = self.doc_margins.left,
        text_w = text_w,
        dialog = self,
        -- 续拉重开时恢复滚动位置（init 内会按新的 max_offset 自动钳制）
        scroll_offset = self._restore_offset or 0,
        boundaries = self._pages.boundaries,
        page_bb_getter = function(page_idx)
            local pages = self._scroll_container and self._scroll_container.pages
            return self._pages:renderPage(page_idx, pages)
        end,
    }
    self._scroll_container = scroll
    self._restore_offset = nil

    local vgroup_children = {
        LineWidget:new{
            dimen = Geom:new{ w = self.width, h = TOP_BORDER_SIZE },
        },
        VerticalSpan:new{ width = PADDING },
        scroll,
        VerticalSpan:new{ width = PADDING },
    }

    if more_btn then
        table.insert(vgroup_children, VerticalSpan:new{ width = Screen:scaleBySize(4) })
        table.insert(vgroup_children, more_btn)
        table.insert(vgroup_children, VerticalSpan:new{ width = Screen:scaleBySize(10) })
    end

    local vgroup = VerticalGroup:new(vgroup_children)

    self.container = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        margin = 0,
        padding = 0,
        vgroup,
    }

    self[1] = BottomContainer:new{
        dimen = Screen:getSize(),
        self.container
    }
end

function ThoughtPopupWidget:onCloseWidget()
    UIManager:setDirty(self, function()
        return "partial", self.container.dimen
    end)
    if self.close_callback then
        local callback = self.close_callback
        self.close_callback = nil
        callback(self.height)
    end
end

function ThoughtPopupWidget:onClose()
    UIManager:close(self)
    return true
end

function ThoughtPopupWidget:onTapClose(_, ges)
    -- Tap outside the bottom bar closes the popup.
    if ges.pos:notIntersectWith(self.container.dimen) then
        UIManager:close(self)
        return true
    end
    -- 只有「展开/收起/继续加载」这几行会拦截点击；未命中就什么都不做
    local scroll = self._scroll_container
    if scroll and scroll.dimen and ges.pos:intersectWith(scroll.dimen) then
        local content_y = (ges.pos.y - scroll.dimen.y) + (scroll.scroll_offset or 0)
        local piece = self:_findActionPieceAtContentY(content_y)
        if piece and self:_handleReplyAction(piece) then
            return true
        end
    end
    return true
end

function ThoughtPopupWidget:onSwipeClose(_, ges)
    local BD = require("ui/bidi")
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" or direction == "east" then
        if self.para_nav then
            -- fanqie: horizontal swipe navigates to an adjacent paragraph.
            self.para_nav(direction == "east" and "prev" or "next")
        else
            UIManager:close(self)
        end
        return true
    end
    if ges.pos:intersectWith(self.container.dimen) then
        return true
    end
    return false
end

--- 命中测试：只找带 action 的行（展开/收起/继续加载回复）。
--- 返回 piece（含 action / item_index）。
function ThoughtPopupWidget:_findActionPieceAtContentY(y)
    local pieces = self._pages and self._pages.layout and self._pages.layout.pieces
    if not pieces then return nil end
    for _, piece in ipairs(pieces) do
        if piece.action and piece.y and piece.piece_h
            and piece.y <= y and y < piece.y + piece.piece_h then
            return piece
        end
    end
    return nil
end

--- 重新分页并重建布局，保留当前滚动位置。
--- 展开/收起回复会改变内容高度，必须整体重排（缓存 key 里带了回复状态）。
function ThoughtPopupWidget:_refreshAfterReplyChange()
    local offset = (self._scroll_container and self._scroll_container.scroll_offset) or 0
    self._restore_offset = offset
    self._pages:setContent(self.items, self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio, self.contrast,
        self.doc_font_weight, self.doc_font_gamma)
    self:_buildLayout()
    UIManager:setDirty(self, function()
        return "partial", self.container.dimen
    end)
end

function ThoughtPopupWidget:_handleReplyAction(piece)
    local item = self.items and self.items[tonumber(piece.item_index) or 0]
    if not item or not self.on_replies then return false end

    if piece.action == "toggle_replies" then
        if item.replies_loading then return true end
        if item.replies_expanded then
            item.replies_expanded = false
            self:_refreshAfterReplyChange()
            return true
        end
        if type(item.replies) == "table" and #item.replies > 0 then
            item.replies_expanded = true
            self:_refreshAfterReplyChange()
            return true
        end
        -- 首次展开：先把「正在加载」显示出来，再去拉数据，避免点了没反应
        item.replies_expanded = true
        item.replies_loading = true
        self:_refreshAfterReplyChange()
        self:_fetchReplies(item, nil)
        return true
    end

    if piece.action == "more_replies" then
        if item.replies_loading then return true end
        item.replies_loading = true
        self:_refreshAfterReplyChange()
        self:_fetchReplies(item, item.replies_cursor)
        return true
    end

    return false
end

function ThoughtPopupWidget:_fetchReplies(item, cursor)
    local widget = self
    local function done(ok, result, err)
        item.replies_loading = false
        if ok and type(result) == "table" and type(result.replies) == "table" then
            item.replies = item.replies or {}
            for _, r in ipairs(result.replies) do
                item.replies[#item.replies + 1] = r
            end
            item.replies_total = tonumber(result.total) or #item.replies
            item.replies_more = result.has_more == true
            item.replies_cursor = result.cursor
            item.replies_expanded = true
            if (tonumber(item.reply_count) or 0) < (tonumber(item.replies_total) or 0) then
                item.reply_count = item.replies_total
            end
        else
            -- 拉失败就收起，不留一个"展开中"的空壳；下次点会重新请求
            item.replies_expanded = false
            local reason = tostring(err or result or "未知原因")
            item.replies_error = reason
            -- 具体原因一并显示：「可能被风控」「HTTP 4xx」「返回为空」这类
            -- 信息直接决定用户该重试还是该换节点，藏在日志里等于没给。
            local brief = reason:gsub("%s+", " ")
            if #brief > 60 then brief = brief:sub(1, 60) .. "…" end
            pcall(function()
                UIManager:show(require("ui/widget/infomessage"):new{
                    text = "回复加载失败：" .. brief,
                })
            end)
            if Log and Log.warn then
                pcall(Log.warn, "[段评] 回复加载失败: " .. reason)
            end
        end
        widget:_refreshAfterReplyChange()
    end

    local ok_call = pcall(self.on_replies, item, cursor, done)
    if not ok_call then
        item.replies_loading = false
        item.replies_expanded = false
        self:_refreshAfterReplyChange()
    end
end

function ThoughtPopupWidget:free(full)
    WidgetContainer.free(self, full)
end

function ThoughtPopupWidget:_freeContentCaches()
    self._pages:freeContentCaches()
end

return ThoughtPopupWidget
