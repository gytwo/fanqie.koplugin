-- fanqie/local_review.lua

local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local Notification = require("ui/widget/notification")
local ok_socket, socket = pcall(require, "socket")

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(t) return t end
local ok_state, _state = pcall(require("fanqie.state"))
if not ok_state then _state = {} end
local ok_H, H = pcall(require, "fanqie.helper")
if not ok_H then H = nil end

local Screen = Device.screen

local LocalReview = {}

local MODULE_NAME = "fanqie_local_review"
local TOUCH_ID = "fanqie_local_review_tap"
local PREFETCH_COUNT = 1

-- 只用于错误 / 警告
local function log_warn(...)
    local ok, Log = pcall(require, "fanqie.logger")
    if ok and Log then
        Log.warn("[本地段评]", ...)
    end
end

-- ============================================================================
-- 绑定
-- ============================================================================
local function get_bindings_path(plugin)
    return plugin.settings:get_download_dir() .. "/local_review_bindings.lua"
end

local function load_bindings(plugin)
    local path = get_bindings_path(plugin)
    local f = io.open(path, "r")
    if not f then return {} end
    f:close()
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then return data end
    return {}
end

local function save_bindings(plugin, bindings)
    local path = get_bindings_path(plugin)
    local parts = { "return {" }
    for file, b in pairs(bindings or {}) do
        if type(b) == "table" then
            parts[#parts + 1] = string.format(
                "  [%q] = { book_id=%q, title=%q, author=%q, _search_source=%q, book_url=%q, source=%q,",
                file, b.book_id or "", b.title or "", b.author or "",
                b._search_source or "", b.book_url or "", b.source or "")
            if type(b.chapter_map) == "table" and next(b.chapter_map) then
                parts[#parts + 1] = "    chapter_map = {"
                for k, v in pairs(b.chapter_map) do
                    parts[#parts + 1] = string.format("      [%q] = %q,", tostring(k), tostring(v))
                end
                parts[#parts + 1] = "    },"
            end
            parts[#parts + 1] = "  },"
        end
    end
    parts[#parts + 1] = "}"
    local f = io.open(path, "w")
    if f then f:write(table.concat(parts, "\n")); f:close() end
end

local function get_binding(plugin, file)
    if not file then return nil end
    local bindings = plugin._local_review_bindings
    if not bindings then
        bindings = load_bindings(plugin)
        plugin._local_review_bindings = bindings
    end
    return bindings[file]
end

local function set_binding(plugin, file, book)
    if not file or not book then return end
    plugin._local_review_bindings = plugin._local_review_bindings or load_bindings(plugin)
    plugin._local_review_bindings[file] = {
        book_id = book.book_id,
        title = book.title,
        author = book.author,
        _search_source = book._search_source,
        book_url = book.book_url,
        source = book.source,
        _catalog_hint = book._catalog_hint,
    }
    save_bindings(plugin, plugin._local_review_bindings)
end

function LocalReview.clear_binding(plugin)
    local doc = plugin.ui and plugin.ui.document
    if not doc then return end
    local file = doc.file or doc.path
    plugin._local_review_bindings = plugin._local_review_bindings or load_bindings(plugin)
    plugin._local_review_bindings[file] = nil
    save_bindings(plugin, plugin._local_review_bindings)
    plugin:showInfo(_("已清除绑定，下次匹配重新选择"))
end

function LocalReview.rebind(plugin)
    local doc = plugin.ui and plugin.ui.document
    if not doc then
        plugin:showInfo(_("没有打开文档"))
        return
    end
    local file = doc.file or doc.path
    if not file then
        plugin:showInfo(_("无法识别当前文件"))
        return
    end

    plugin._local_review_bindings = plugin._local_review_bindings or load_bindings(plugin)
    plugin._local_review_bindings[file] = nil
    save_bindings(plugin, plugin._local_review_bindings)

    plugin._local_review_book = nil

    LocalReview.run(plugin)
end

-- ============================================================================
-- Overlay
-- ============================================================================
local BUBBLE_FONT_SIZE = 18
local BUBBLE_COLOR = Blitbuffer.COLOR_GRAY_2
local BUBBLE_GAP = Screen:scaleBySize(3)

local Overlay = InputContainer:extend{
    records = nil,
    enabled = true,
    _visible = nil,
    _sorted = false,
    on_record_tap = nil,
}

function Overlay:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self._visible = {}
end

function Overlay:setRecords(records)
    self.records = records or {}
    self._sorted = false
    self._visible = {}
    for _, rec in ipairs(self.records) do
        rec._start_pos = nil
        rec._end_pos = nil
    end
end

function Overlay:invalidate()
    self._visible = {}
end

function Overlay:_refreshPositions(document)
    local records = self.records or {}
    local need_sort = not self._sorted
    for _, record in ipairs(records) do
        if record.pos0 then
            if record._start_pos == nil then
                record._start_pos = tonumber((document:getPosFromXPointer(record.pos0))) or math.huge
                need_sort = true
            end
            if record._end_pos == nil and record.pos1 then
                record._end_pos = tonumber((document:getPosFromXPointer(record.pos1))) or record._start_pos
            end
        elseif record._start_pos == nil then
            record._start_pos = math.huge
            need_sort = true
        end
    end
    if need_sort then
        table.sort(records, function(a, b)
            return (a._start_pos or math.huge) < (b._start_pos or math.huge)
        end)
        self._sorted = true
    end
end

function Overlay:_computeVisible()
    local document = self.ui and self.ui.document
    if not document then return {} end
    self:_refreshPositions(document)

    local top = tonumber((document:getCurrentPos())) or 0
    local height = self.ui.dimen and tonumber(self.ui.dimen.h) or 0
    local pages = tonumber((document:getVisiblePageCount())) or 1
    local bottom = top + height * math.max(1, pages)

    local visible = {}
    for _ri, rec in ipairs(self.records or {}) do
        local start_pos = rec._start_pos
        if start_pos and start_pos > bottom then
            break
        end
        local end_pos = rec._end_pos
        if start_pos and end_pos and start_pos <= bottom and end_pos >= top then
            local ok, boxes = pcall(document.getScreenBoxesFromPositions,
                document, rec.pos0, rec.pos1, true)
            if ok and type(boxes) == "table" and #boxes > 0 then
                local last = boxes[#boxes]
                local label = tostring(rec.count or 0)
                if tonumber(rec.count) and tonumber(rec.count) > 99 then label = "99+" end
                local widget = TextWidget:new{
                    text = "[" .. label .. "]",
                    face = Font:getFace("cfont", BUBBLE_FONT_SIZE),
                    fgcolor = BUBBLE_COLOR,
                }
                local sz = widget:getSize()
                local bubble_x = last.x + last.w + BUBBLE_GAP
                local bubble_y = last.y + last.h - sz.h
                if bubble_x + sz.w > Screen:getWidth() then
                    bubble_x = last.x + last.w - sz.w - BUBBLE_GAP
                    bubble_y = last.y + last.h - sz.h + math.floor(last.h * 0.5)
                    if bubble_y + sz.h > Screen:getHeight() then
                        bubble_y = last.y - sz.h - BUBBLE_GAP
                    end
                end
                local rect = Geom:new{
                    x = bubble_x,
                    y = bubble_y,
                    w = sz.w, h = sz.h,
                }
                visible[#visible + 1] = { rect = rect, record = rec, widget = widget }
            end
        end
    end
    return visible
end

function Overlay:paintTo(bb, x, y)
    if not self.enabled then self._visible = {}; return end
    local document = self.ui and self.ui.document
    if not document or not document.getCurrentPos then
        self._visible = {}
        return
    end
    self._visible = self:_computeVisible()
    for _ei, entry in ipairs(self._visible) do
        local r = entry.rect
        pcall(function() entry.widget:paintTo(bb, x + r.x, y + r.y) end)
    end
end

function Overlay:hitTest(pos)
    if not self.enabled or not pos then return end
    if not self._visible or #self._visible == 0 then
        self._visible = self:_computeVisible()
    end
    local pad = Screen:scaleBySize(10)
    for i = #self._visible, 1, -1 do
        local r = self._visible[i].rect
        if pos.x >= r.x - pad and pos.x <= r.x + r.w + pad
            and pos.y >= r.y - pad and pos.y <= r.y + r.h + pad then
            return self._visible[i].record
        end
    end
end

-- ============================================================================
-- 点击气泡：交给 main.lua 的 showParaReviewDetail（复用其分页 / 续拉）
-- ============================================================================
local function on_record_tap(plugin, record)
    if not record or not record.ident then
        plugin:showInfo(_("段评数据无效"))
        return
    end
    local ok_state, _state = pcall(require, "fanqie.state")
    local idx
    if ok_state and _state and _state.getCurrentParaReviews then
        local reviews = _state.getCurrentParaReviews() or {}
        for i, pr in ipairs(reviews) do
            if tostring(pr.ident) == tostring(record.ident) then
                idx = i
                break
            end
        end
    end
    if not idx then
        plugin:showInfo(_("段评数据无效"))
        return
    end
    plugin:showParaReviewDetail(idx)
end

-- ============================================================================
-- 工具
-- ============================================================================
local function current_toc_index(doc, toc)
    local pageno = doc.getCurrentPage and doc:getCurrentPage() or 1
    local cur = 1
    for i, item in ipairs(toc) do
        local p = tonumber(item.page) or 0
        if p <= pageno then cur = i else break end
    end
    return cur
end

local function normalize_title(text)
    text = tostring(text or ""):gsub("%s+", "")
    text = text:gsub("《",""):gsub("》",""):gsub("【",""):gsub("】","")
        :gsub("：",""):gsub("，",""):gsub("、","")
        :gsub("。",""):gsub("！",""):gsub("？","")
        :gsub("[%.%,!%?;:%-%_/%\\%(%)%[%]{}]", "")
    return text
end

local function utf8_chars(s)
    local chars, i, len = {}, 1, #s
    while i <= len do
        local b = s:byte(i)
        local w = 1
        if b >= 0xF0 then w = 4
        elseif b >= 0xE0 then w = 3
        elseif b >= 0xC0 then w = 2 end
        chars[#chars + 1] = s:sub(i, i + w - 1)
        i = i + w
    end
    return chars
end

local function char_overlap(a, b)
    local aa, bb = utf8_chars(a), utf8_chars(b)
    local ca, cb = {}, {}
    for _, c in ipairs(aa) do ca[c] = (ca[c] or 0) + 1 end
    for _, c in ipairs(bb) do cb[c] = (cb[c] or 0) + 1 end
    local common = 0
    for c, n in pairs(ca) do common = common + math.min(n, cb[c] or 0) end
    local total = math.max(#aa, #bb)
    return total == 0 and 0 or common / total
end

-- ============================================================================
-- 1. 匹配书籍
-- ============================================================================
function LocalReview.auto_match(plugin, on_done)
    local doc = plugin.ui and plugin.ui.document
    if not doc then
        plugin:showInfo(_("没有打开文档"))
        if on_done then on_done(nil) end
        return
    end
    local file = doc.file or doc.path

    do
        UIManager:show(Notification:new{
            text = _("正在匹配段评..."),
            timeout = 2,
        })
    end

    local binding = get_binding(plugin, file)
    if binding and binding.book_id and binding.book_id ~= "" then
        plugin._local_review_book = binding
        if on_done then on_done(binding) end
        return
    end

    local props = plugin.ui.doc_props or {}
    local title = tostring(props.display_title or props.title or "")
        :gsub("%s*（.-）", ""):gsub("%s*%(.-%)", "")
        :gsub("^%s+", ""):gsub("%s+$", "")
    if title == "" then
        title = tostring(file or ""):match("([^/\\]+)%.[^%.]+$") or ""
    end
    if title == "" then
        plugin:showInfo(_("无法识别书名"))
        if on_done then on_done(nil) end
        return
    end

    plugin:_doSearch(title, {
        on_select_override = function(book)
            if plugin.book_list_menu then
                pcall(function() plugin:_cancelCoverLoading() end)
                UIManager:close(plugin.book_list_menu)
                plugin.book_list_menu = nil
            end
            _state.active_menu = nil

            set_binding(plugin, file, book)
            plugin._local_review_book = book

            UIManager:nextTick(function()
                if on_done then on_done(book) end
            end)
        end,
    })
end

-- ============================================================================
-- 2. 指定章标题 → 番茄 itemId
-- ============================================================================
local function show_chapter_picker(plugin, book, local_title, on_pick)
    local Async = require("fanqie.async")
    Async.run(function()
        local client = plugin.client
        local raw = client:fetch_chapter_directory(book.book_id)
        local Content = require("fanqie.content")
        return Content.readable_chapters(Content.normalize_chapters(raw, book.book_id))
    end, function(ok, chapters, err)
        if not ok or type(chapters) ~= "table" or #chapters == 0 then
            plugin:showInfo(_("无法获取番茄章节目录"))
            if on_pick then on_pick(nil) end
            return
        end
        local Menu = require("ui/widget/menu")
        local menu
        local items = {}
        for i, ch in ipairs(chapters) do
            table.insert(items, {
                text = string.format("%d. %s", i, ch.title or ""),
                callback = function()
                    menu._picked = true
                    if _state.active_menu then
                        UIManager:close(_state.active_menu)
                        _state.active_menu = nil
                    end
                    if on_pick then on_pick(tostring(ch.itemId)) end
                end,
            })
        end
        menu = Menu:new{
            title = string.format(_("没有匹配到对应章节，请选择「%s」对应的番茄章节"), tostring(local_title)),
            item_table = items,
            items_per_page = 15,
            is_borderless = true,
            is_popout = false,
            close_callback = function()
                if _state.active_menu == menu then _state.active_menu = nil end
                if on_pick and not menu._picked then on_pick(nil) end
            end,
        }
        _state.active_menu = menu
        UIManager:show(menu)
    end, { poll_interval = 0.2, timeout = 60 })
end

-- 写入手动章节映射（和 set_binding 同模式：改内存 → 写盘）
local function set_chapter_map(plugin, book, toc_idx, item_id)
    if not book or not toc_idx or not item_id then return end
    book.chapter_map = book.chapter_map or {}
    book.chapter_map[tostring(toc_idx)] = tostring(item_id)

    local doc = plugin.ui and plugin.ui.document
    local file = doc and (doc.file or doc.path)
    if not file then return end
    plugin._local_review_bindings = plugin._local_review_bindings or load_bindings(plugin)
    local b = plugin._local_review_bindings[file]
    if b then
        b.chapter_map = book.chapter_map
        save_bindings(plugin, plugin._local_review_bindings)
    end
end

function LocalReview.locate_chapter_by_title(plugin, book, chapter_title, chapter_start_page, on_done, opts)
    opts = opts or {}
    local notify_on_fail = opts.notify_on_fail == true
    local toc_idx = opts.toc_idx

    -- 优先查手动映射（和 binding 一样，命中直接用）
    if toc_idx and book and type(book.chapter_map) == "table" then
        local mapped = book.chapter_map[tostring(toc_idx)]
        if mapped and mapped ~= "" then
            if on_done then on_done(mapped, chapter_start_page) end
            return
        end
    end

    local want = normalize_title(chapter_title)
    if want == "" then
        if on_done then on_done(nil) end
        return
    end

    local Async = require("fanqie.async")
    Async.run(function()
        local client = plugin.client
        local raw = client:fetch_chapter_directory(book.book_id)
        local Content = require("fanqie.content")
        local chapters = Content.readable_chapters(Content.normalize_chapters(raw, book.book_id))

        -- ★ 落盘目录（如果 catalog_cache.lua 不存在）
        if chapters and #chapters > 0 then
            local dir = Content.book_cache_dir(plugin.settings, book.book_id)
            local cache_path = dir .. "/catalog_cache.lua"
            if not H.file_exists(cache_path) then
                pcall(Content.save_catalog_cache,
                    plugin.settings, book.book_id, chapters, book.title, book.cover)
            end
        end

        local best_id, best_score
        for _i, ch in ipairs(chapters or {}) do
            local uid = tostring(ch.itemId or "")
            if uid ~= "" then
                local have = normalize_title(ch.title)
                if have == want then
                    best_id, best_score = uid, 1.0
                    break
                end
                local s = char_overlap(want, have)
                if s >= 0.70 and (not best_score or s > best_score) then
                    best_id, best_score = uid, s
                end
            end
        end
        return { item_id = best_id, score = best_score }
    end, function(ok, result, err)
        if not ok or type(result) ~= "table" or not result.item_id then
            log_warn("匹配章节失败: " .. tostring(err or result))

            -- 用户主动触发 → 弹手动选择器；翻页/预取 → 静默
            if notify_on_fail then
                UIManager:nextTick(function()
                    show_chapter_picker(plugin, book, chapter_title, function(item_id)
                        -- 把用户的选择写盘（下次直接用）
                        if item_id and toc_idx then
                            set_chapter_map(plugin, book, toc_idx, item_id)
                        end
                        if on_done then on_done(item_id, chapter_start_page) end
                    end)
                end)
            else
                if on_done then on_done(nil) end
            end
            return
        end
        if on_done then on_done(result.item_id, chapter_start_page) end
    end, { poll_interval = 0.2, timeout = 120 })
end

function LocalReview.locate_current_chapter(plugin, book, on_done)
    local doc = plugin.ui and plugin.ui.document
    if not doc then
        if on_done then on_done(nil) end
        return
    end
    local toc = doc:getToc()
    if type(toc) ~= "table" or #toc == 0 then
        if on_done then on_done(nil) end
        return
    end
    local toc_idx = current_toc_index(doc, toc)
    local chapter_title = toc[toc_idx] and toc[toc_idx].title or ""
    local chapter_start_page = tonumber(toc[toc_idx] and toc[toc_idx].page) or 1
    LocalReview.locate_chapter_by_title(plugin, book, chapter_title, chapter_start_page,
        function(item_id)
            if on_done then on_done(item_id, chapter_start_page, toc_idx) end
        end,
        { notify_on_fail = true, toc_idx = toc_idx })
end

function LocalReview.rematch_current_chapter(plugin)
    local doc = plugin.ui and plugin.ui.document
    if not doc then
        plugin:showInfo(_("没有打开文档"))
        return
    end
    local toc = doc:getToc()
    if type(toc) ~= "table" or #toc == 0 then
        plugin:showInfo(_("无法获取目录"))
        return
    end

    local file = doc.file or doc.path
    local book = plugin._local_review_book or get_binding(plugin, file)
    if not book or not book.book_id or book.book_id == "" then
        plugin:showInfo(_("请先匹配段评来源"))
        return
    end
    plugin._local_review_book = book

    local toc_idx = current_toc_index(doc, toc)
    local chapter_title = toc[toc_idx] and toc[toc_idx].title or ""
    local chapter_start_page = tonumber(toc[toc_idx] and toc[toc_idx].page) or 1

    -- 清掉该 toc_idx 对应的云端缓存（按 item_id 清）
    if book.chapter_map then
        local old_item_id = book.chapter_map[tostring(toc_idx)]
        if old_item_id and old_item_id ~= "" then
            if plugin._local_review_cache then
                plugin._local_review_cache["cloud:" .. tostring(old_item_id)] = nil
            end
        end
        book.chapter_map[tostring(toc_idx)] = nil
    end
    plugin._local_review_current_local_key = nil
    plugin._local_review_current_cloud_key = nil

    show_chapter_picker(plugin, book, chapter_title, function(item_id)
        if not item_id then return end
        set_chapter_map(plugin, book, toc_idx, item_id)
        local cloud_key = "cloud:" .. tostring(item_id)
        plugin._local_review_current_cloud_key = cloud_key
        LocalReview.dump_current_chapter(plugin, book, item_id, chapter_start_page, cloud_key, toc_idx)
    end)
end

-- ============================================================================
-- 3. 拉段评 + 定位
-- ============================================================================
function LocalReview.fetch_chapter_records(plugin, book, item_id, chapter_start_page, chapter_uid, on_done, opts)
    opts = opts or {}
    local chapter = { itemId = item_id }
    local book_for_fetch = {
        book_id = book.book_id,
        title = book.title,
        author = book.author,
        source = book.source,
        _search_source = book._search_source,
        _catalog_hint = book._catalog_hint,
        book_url = book.book_url,
    }

    local Async = require("fanqie.async")
    Async.run(function()
        local Content = require("fanqie.content")
        local ok, xhtml, para_reviews = pcall(function()
            return Content.fetch_chapter_content(
                plugin.client, plugin.settings, book_for_fetch, chapter, { review = true })
        end)
        if not ok then
            return { ok = false, err = tostring(xhtml) }
        end
        local text = tostring(xhtml or "")
        local body = text:match("<body[^>]*>([%s%S]-)</body>") or text
        body = body:gsub("<[^>]+>", "")
        body = body:gsub("&nbsp;", " "):gsub("&amp;", "&")
            :gsub("&lt;", "<"):gsub("&gt;", ">")
            :gsub("&quot;", '"'):gsub("&#39;", "'")
        local list = {}
        for _, pr in ipairs(para_reviews or {}) do
            list[#list + 1] = {
                ident = tostring(pr.ident or ""),
                count = tonumber(pr.count) or 0,
            }
        end
        return { ok = true, body = body, list = list }
    end, function(ok, result, err)
        if not ok or type(result) ~= "table" or result.ok == false then
            log_warn("拉段评失败: " .. tostring(result and result.err or err or result))
            if on_done then on_done(nil) end
            return
        end

        local lines = {}
        for line in ((result.body or "") .. "\n"):gmatch("(.-)\n") do
            local t = line:gsub("^%s+", ""):gsub("%s+$", "")
            t = t:gsub("%[%d+%]$", ""):gsub("%[99%+%]$", ""):gsub("%s+$", "")
            if t ~= "" then lines[#lines + 1] = t end
        end

        local doc = plugin.ui and plugin.ui.document
        if not doc then
            if on_done then on_done(nil) end
            return
        end

        local saved_xp = doc.getXPointer and doc:getXPointer()
        local chapter_start_xp = doc:getPageXPointer(chapter_start_page or 1)

        local located, failed = 0, 0
        local consecutive_fail = 0
        local total = #result.list
        local records = {}
        local cursor_xp = chapter_start_xp

        -- 预取判定：优先用显式 opts.is_prefetch；否则用云端 key 比较
        local is_prefetch = opts.is_prefetch == true
            or (chapter_uid ~= plugin._local_review_current_cloud_key)

        local function finish()
            if saved_xp then pcall(doc.gotoXPointer, doc, saved_xp) end

            local ok_content, Content = pcall(require, "fanqie.content")

            -- 段落索引落盘（ident + count）
            if result.list and #result.list > 0 then
                if ok_content and Content and Content.save_para_reviews_index then
                    pcall(Content.save_para_reviews_index,
                        plugin.settings, book.book_id, item_id, result.list)
                end
            end

            -- ★ records 落盘（含 pos0/pos1，供下次打开书直接读磁盘画气泡）
            if #records > 0 then
                if ok_content and Content and Content.save_para_records then
                    pcall(Content.save_para_records,
                        plugin.settings, book.book_id, item_id, records)
                end
            end

            -- 非预取时把 records 的 ident/count 写进 _state.current_para_reviews
            if not is_prefetch then
                local ok_state, _state = pcall(require, "fanqie.state")
                if ok_state and _state and _state.setCurrentParaReviews then
                    local reviews = {}
                    for i, rec in ipairs(records) do
                        rec.para_index = i
                        reviews[#reviews + 1] = {
                            ident = tostring(rec.ident or ""),
                            count = tonumber(rec.count) or 0,
                        }
                    end
                    _state.setCurrentParaReviews(reviews)
                end
            end

            -- 先画气泡
            if on_done then on_done(records) end

            -- ★ 气泡画完后，后台落盘评论正文
            if result.list and #result.list > 0 then
                LocalReview._background_cache_comments(plugin, book, item_id, result.list)
            end
        end

        local function locate_one(i)
            if i > total then
                finish()
                return
            end

            local pr = result.list[i]
            local pid = tonumber(tostring(pr.ident):match("(%d+)$"))
            local para = pid and lines[pid + 1] or nil

            if not para or para == "" then
                failed = failed + 1
                consecutive_fail = consecutive_fail + 1
                if consecutive_fail >= 10 then
                    finish()
                    return
                end
                UIManager:scheduleIn(0, function() locate_one(i + 1) end)
                return
            end

            local short = para
            if cursor_xp then
                pcall(doc.gotoXPointer, doc, cursor_xp)
            end
            local okf, hits = pcall(doc.findText, doc, short, 0, 0, true, nil, false, 1, 0x00FF)
            if doc.clearSelection then pcall(doc.clearSelection, doc) end

            local hit_start, hit_end
            if okf and type(hits) == "table" then
                for _, r in ipairs(hits) do
                    if type(r) == "table" and r["start"] then
                        hit_start = r["start"]
                        hit_end = r["end"]
                        break
                    end
                end
            end

            if hit_start then
                located = located + 1
                consecutive_fail = 0
                cursor_xp = hit_end
                records[#records + 1] = {
                    pos0 = hit_start,
                    pos1 = hit_end,
                    count = pr.count,
                    ident = pr.ident,
                    chapter_uid = chapter_uid,
                    para_index = i,
                }
            else
                failed = failed + 1
                consecutive_fail = consecutive_fail + 1
                if consecutive_fail >= 10 then
                    finish()
                    return
                end
            end

            UIManager:scheduleIn(0, function() locate_one(i + 1) end)
        end

        locate_one(1)
    end, { poll_interval = 0.125, timeout = 90 })
end

-- 后台把该章所有段评的评论正文落盘。
-- 一次 Async.run（一次 fork）处理整章：子进程内循环拉该章所有 pid，
-- 收集完一次性写盘。父进程不参与。
-- 同一云端章只跑一个任务（防止重复启动）。
-- 后台把该章所有段评的评论正文落盘。
-- 一次 Async.run（一次 fork）处理整章：子进程内循环拉该章所有 pid，
-- 收集完一次性写盘。父进程不参与。
-- 同一云端章只跑一个任务（防止重复启动）。
function LocalReview._background_cache_comments(plugin, book, item_id, list)
    local ok_log, Log = pcall(require, "fanqie.logger")
    local function dbg(...)
        if ok_log and Log and Log.warn then Log.warn("[本地段评][后台落盘]", ...) end
    end

    if not list or #list == 0 then
        dbg("跳过：list 为空")
        return
    end
    local book_id = book.book_id
    if not book_id or not item_id then
        dbg("跳过：book_id/item_id 为空 book_id=" .. tostring(book_id)
            .. " item_id=" .. tostring(item_id))
        return
    end

    local Async = require("fanqie.async")
    local Client = require("fanqie.client")

    plugin._comment_cache_running = plugin._comment_cache_running or {}
    local running_key = tostring(book_id) .. ":" .. tostring(item_id)
    if plugin._comment_cache_running[running_key] then
        dbg("跳过：running_key 已存在，已有任务在跑 " .. running_key)
        return
    end
    plugin._comment_cache_running[running_key] = true
    dbg("入队：" .. running_key .. " list_count=" .. tostring(#list)
        .. " 延迟1秒启动")

    -- 延迟 1 秒启动，给画气泡让出时间
    UIManager:scheduleIn(1.0, function()
        dbg("启动子进程：" .. running_key)

        Async.run(function()
            -- ============================================================
            -- 子进程：循环拉该章所有 pid
            --   · 每拉一条 → 只更新 .count（小文件，实时）
            --   · 整章结束 → 一次性写 para_comments（大文件）
            -- ============================================================
            local Content = require("fanqie.content")
            local settings = plugin.settings
            local client = Client:new(settings)

            local function cdbg(...)
              --if ok_log and Log and Log.warn then Log.warn("[本地段评][后台落盘][子进程]", ...) end
            end

            -- 读现有缓存（一次）
            local existing = Content.load_para_comments(settings, book_id, item_id)
            local existing_count = 0
            for _ in pairs(existing or {}) do existing_count = existing_count + 1 end
            cdbg("读取已有缓存 existing_count=" .. tostring(existing_count))

            -- 初始 .count 对齐一次
            if existing_count > 0 then
                pcall(Content.save_comments_count, settings, book_id, item_id, existing_count)
            end

            local new_results = {}
            local saved_count = 0
            local fail_count = 0
            local skip_count = 0

            for idx, pr in ipairs(list) do
                local pid = tonumber(tostring(pr.ident):match("(%d+)$"))
                if not pid then
                    cdbg("跳过 idx=" .. tostring(idx) .. " 无法解析 pid ident=" .. tostring(pr.ident))
                elseif existing and existing[tostring(pid)] then
                    skip_count = skip_count + 1
                else
                    local ident = pr.ident
                    local ok_r, result_r
                    if ident:find("shushan:", 1, true) then
                        ok_r, result_r = pcall(function()
                            return client:shushan_get_para_review(ident, { count = 30, page_max = 1 })
                        end)
                    elseif ident:find("zhiqiu:", 1, true) then
                        ok_r, result_r = pcall(function()
                            return client:zhiqiu_get_para_review(ident, { page = 1, size = 30, page_max = 1 })
                        end)
                    else
                        cdbg("跳过 idx=" .. tostring(idx) .. " 未知来源 ident=" .. tostring(ident):sub(1, 60))
                    end

                    if ok_r and result_r then
                        new_results[tostring(pid)] = result_r
                        saved_count = saved_count + 1
                        cdbg("成功 pid=" .. tostring(pid)
                            .. " 已拉=" .. tostring(saved_count)
                            .. "/" .. tostring(#list))

                        -- ★ 只更新 .count（+1），不写 para_comments、不写 catalog
                        pcall(Content.save_comments_count,
                            settings, book_id, item_id, existing_count + saved_count)
                    else
                        fail_count = fail_count + 1
                        cdbg("失败 pid=" .. tostring(pid)
                            .. " ident=" .. tostring(ident):sub(1, 80)
                            .. " err=" .. tostring(result_r):sub(1, 200))
                    end

                end
            end

            -- ★ 整章结束：一次性写 para_comments
            if saved_count > 0 or skip_count > 0 then
                local merged = {}
                for k, v in pairs(existing or {}) do merged[k] = v end
                for k, v in pairs(new_results) do merged[k] = v end

                local ok_w, err_w = pcall(Content.save_para_comments_batch,
                    settings, book_id, item_id, merged)
                if ok_w then
                    cdbg("para_comments 写盘成功，共 " .. tostring(existing_count + saved_count) .. " 条")
                else
                    cdbg("para_comments 写盘失败 err=" .. tostring(err_w))
                end

                -- .count 最终值（保险，循环里已实时更新）
                pcall(Content.save_comments_count,
                    settings, book_id, item_id, existing_count + saved_count)
            end

            cdbg("汇总 saved=" .. tostring(saved_count)
                .. " skip=" .. tostring(skip_count)
                .. " fail=" .. tostring(fail_count)
                .. " total=" .. tostring(#list))

            return { saved = saved_count, skipped = skip_count, failed = fail_count }
        end, function(ok, result, err)
            plugin._comment_cache_running[running_key] = nil
            if ok and result then
                dbg("完成：" .. running_key
                    .. " saved=" .. tostring(result.saved or 0)
                    .. " skipped=" .. tostring(result.skipped or 0)
                    .. " failed=" .. tostring(result.failed or 0))
            else
                dbg("失败：" .. running_key
                    .. " err=" .. tostring(err))
            end
        end, { delay = 0, poll_interval = 0.5, timeout = 600 })
    end)
end

-- ============================================================================
-- 4. 预取
-- ============================================================================
function LocalReview._plan_prefetch(plugin, toc, current_toc_idx)
    local planned = {}
    local cache = plugin._local_review_cache or {}
    local prefetching = plugin._local_review_prefetching or {}
    for offset = 1, 99 do
        if #planned >= PREFETCH_COUNT then break end
        local idx = current_toc_idx + offset
        if idx > #toc then break end
        local item = toc[idx]
        local start_page = tonumber(item and item.page) or 1
        local book = plugin._local_review_book
        local mapped = book and book.chapter_map and book.chapter_map[tostring(idx)]
        local key = mapped and ("cloud:" .. tostring(mapped))
            or ("local:" .. tostring(idx) .. ":" .. tostring(start_page))
        if not cache[key] and not prefetching[key] then
            planned[#planned + 1] = {
                key = key,
                toc_idx = idx,
                title = item and item.title or "",
                start_page = start_page,
            }
        end
    end
    return planned
end

function LocalReview._prefetch_next(plugin, planned, i)
    if not planned or i > #planned then
        return
    end
    local plan = planned[i]
    if not plan then return end

    if plugin._local_review_cache and plugin._local_review_cache[plan.key] then
        LocalReview._prefetch_next(plugin, planned, i + 1)
        return
    end

    plugin._local_review_prefetching = plugin._local_review_prefetching or {}
    plugin._local_review_prefetching[plan.key] = true

    LocalReview.locate_chapter_by_title(plugin, plugin._local_review_book,
        plan.title, plan.start_page, function(item_id)
            if not item_id then
                plugin._local_review_prefetching[plan.key] = nil
                LocalReview._prefetch_next(plugin, planned, i + 1)
                return
            end

            -- 写入 chapter_map（预取结果也持久化，后续切章直接命中）
            set_chapter_map(plugin, plugin._local_review_book, plan.toc_idx, item_id)

            local cloud_key = "cloud:" .. tostring(item_id)

            -- 云端缓存命中（同一云端章已被其它本地章拉过）：直接跳过，不重复拉取
            if plugin._local_review_cache and plugin._local_review_cache[cloud_key] then
                plugin._local_review_prefetching[plan.key] = nil
                UIManager:scheduleIn(0.5, function()
                    LocalReview._prefetch_next(plugin, planned, i + 1)
                end)
                return
            end

            LocalReview.fetch_chapter_records(plugin, plugin._local_review_book,
                item_id, plan.start_page, cloud_key, function(records)
                    plugin._local_review_prefetching[plan.key] = nil
                    if records then
                        plugin._local_review_cache[cloud_key] = records
                    end
                    UIManager:scheduleIn(0.5, function()
                        LocalReview._prefetch_next(plugin, planned, i + 1)
                    end)
                end, { is_prefetch = true })
        end,
        { toc_idx = plan.toc_idx })
end

function LocalReview.trigger_prefetch(plugin, current_toc_idx)
    if PREFETCH_COUNT <= 0 then return end
    if not plugin._local_review_book then return end
    local doc = plugin.ui and plugin.ui.document
    if not doc then return end
    local toc = doc:getToc()
    if type(toc) ~= "table" or #toc == 0 then return end

    local planned = LocalReview._plan_prefetch(plugin, toc, current_toc_idx)
    if #planned == 0 then
        return
    end
    LocalReview._prefetch_next(plugin, planned, 1)
end

-- ============================================================================
-- 5. 拉当前章
-- ============================================================================
function LocalReview.dump_current_chapter(plugin, book, item_id, chapter_start_page, cloud_key, toc_idx)
    return LocalReview.fetch_chapter_records(plugin, book, item_id, chapter_start_page,
        cloud_key, function(records)
            if records then
                plugin._local_review_cache = plugin._local_review_cache or {}
                plugin._local_review_cache[cloud_key] = records   -- 按云端 key 存
                if plugin._local_review_overlay then
                    plugin._local_review_overlay:setRecords(records)  -- 只传这一份，不 merge
                    UIManager:setDirty(plugin.ui, "partial")
                end
            end
            UIManager:show(Notification:new{
                text = string.format("段评 %d 条", records and #records or 0),
                timeout = 2,
            })
            if toc_idx then
                LocalReview.trigger_prefetch(plugin, toc_idx)
            end
        end)
end

-- ============================================================================
-- 6. 一键
-- ============================================================================
function LocalReview.run(plugin)
    plugin._local_review_cache = {}
    plugin._local_review_prefetching = {}
    plugin._local_review_current_local_key = nil
    plugin._local_review_current_cloud_key = nil

    LocalReview.auto_match(plugin, function(book)
        if not book then return end
        LocalReview.locate_current_chapter(plugin, book, function(item_id, chapter_start_page, toc_idx)
            if not item_id then return end
            set_chapter_map(plugin, book, toc_idx, item_id)
            local cloud_key = "cloud:" .. tostring(item_id)
            plugin._local_review_current_cloud_key = cloud_key
            LocalReview.dump_current_chapter(plugin, book, item_id, chapter_start_page, cloud_key, toc_idx)
        end)
    end)
end

function LocalReview.match_book(plugin)
    LocalReview.run(plugin)
end

-- ============================================================================
-- 生命周期
-- ============================================================================
function LocalReview.on_reader_ready(plugin)
    local doc = plugin.ui and plugin.ui.document
    if not doc or not doc.getCurrentPos then
        return
    end
    plugin._local_review_cache = plugin._local_review_cache or {}
    plugin._local_review_prefetching = plugin._local_review_prefetching or {}
    plugin._local_review_bindings = plugin._local_review_bindings or load_bindings(plugin)
    plugin._local_review_current_local_key = nil
    plugin._local_review_current_cloud_key = nil

    -- ★ 从 binding 加载 _local_review_book（关文档再打开时，plugin 是新实例，
    --   _local_review_book 是 nil，从本地 binding 恢复）
    local file = doc.file or doc.path
    if file then
        local binding = get_binding(plugin, file)
        if binding and binding.book_id and binding.book_id ~= "" then
            plugin._local_review_book = binding
        end
    end

    local overlay = Overlay:new{
        records = {},
        enabled = true,
        on_record_tap = function(rec) on_record_tap(plugin, rec) end,
    }
    plugin.ui.view:registerViewModule(MODULE_NAME, overlay)
    plugin._local_review_overlay = overlay

    plugin.ui:registerTouchZones({{
        id = TOUCH_ID,
        ges = "tap",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
        overrides = { "tap_forward", "tap_backward", "readerfooter_tap" },
        handler = function(ges)
            local rec = overlay:hitTest(ges and ges.pos)
            if not rec then return false end
            on_record_tap(plugin, rec)
            return true
        end,
    }})

     if plugin.settings:get("auto_prefetch_review", false) then
        UIManager:scheduleIn(0.5, function()
            if not (plugin.ui and plugin.ui.document) then return end
            local doc = plugin.ui.document
            local file = doc.file or doc.path
            if not file then return end
            local binding = get_binding(plugin, file)
            if not binding or not binding.book_id or binding.book_id == "" then
                return
            end

            -- 无网络时：先告知用户需要联网，再弹 WiFi 框；联网后自动重试
            local NetworkMgr = require("ui/network/manager")
            if NetworkMgr and NetworkMgr.isOnline and not NetworkMgr:isOnline() then
                UIManager:show(Notification:new{
                    text = _("番茄-拉取段评需要联网"),
                    timeout = 2,
                })
                if NetworkMgr.willRerunWhenOnline then
                    if NetworkMgr:willRerunWhenOnline(function()
                        LocalReview.run(plugin)
                    end) then
                        return
                    end
                end
                return
            end

            LocalReview.run(plugin)
        end)
    end
end

function LocalReview.on_page_update(plugin)
    if plugin._local_review_overlay then
        plugin._local_review_overlay:invalidate()
    end

    if not plugin._local_review_book then return end
    local doc = plugin.ui and plugin.ui.document
    if not doc then return end
    local toc = doc:getToc()
    if type(toc) ~= "table" or #toc == 0 then return end

    local toc_idx = current_toc_index(doc, toc)
    local chapter_title = toc[toc_idx] and toc[toc_idx].title or ""
    local chapter_start_page = tonumber(toc[toc_idx] and toc[toc_idx].page) or 1
    local local_key = "local:" .. tostring(toc_idx) .. ":" .. tostring(chapter_start_page)

    -- 判断是否切了本地章
    if plugin._local_review_current_local_key == local_key then
        return
    end
    plugin._local_review_current_local_key = local_key

    local book = plugin._local_review_book
    local ok_content, Content = pcall(require, "fanqie.content")

    -- 内部函数：用一份 records 更新 overlay 和 _state（overlay/state 始终同步）
    local function apply_records(records, cloud_key)
        plugin._local_review_current_cloud_key = cloud_key
        if plugin._local_review_overlay then
            plugin._local_review_overlay:setRecords(records or {})
            UIManager:setDirty(plugin.ui, "partial")
        end
        local ok_state, _state = pcall(require, "fanqie.state")
        if ok_state and _state and _state.setCurrentParaReviews then
            local reviews = {}
            for i, rec in ipairs(records or {}) do
                rec.para_index = i
                reviews[#reviews + 1] = {
                    ident = tostring(rec.ident or ""),
                    count = tonumber(rec.count or 0),
                }
            end
            _state.setCurrentParaReviews(reviews)
        end
    end

    -- 内部函数：cache 未命中时，先读磁盘 records，命中则 apply 并返回 true
    local function try_disk_records(cloud_key, item_id)
        if not (ok_content and Content and Content.load_para_records) then return false end
        local disk_records = Content.load_para_records(plugin.settings, book.book_id, item_id)
        if not disk_records or #disk_records == 0 then return false end
        -- ★ 预验证 pos0 有效性
        local valid = {}
        for _, rec in ipairs(disk_records) do
            if rec.pos0 then
                -- ★ 加一层括号：只取 getPosFromXPointer 的第一个返回值
                local pos = tonumber((doc:getPosFromXPointer(rec.pos0)))
                if pos and pos ~= math.huge then
                    rec.chapter_uid = cloud_key
                    valid[#valid + 1] = rec
                end
            end
        end
        -- 有效率太低（< 50%）则视为失效，回退网络
        if #valid < #disk_records * 0.5 then return false end
        plugin._local_review_cache = plugin._local_review_cache or {}
        plugin._local_review_cache[cloud_key] = valid
        apply_records(valid, cloud_key)
        return true
    end

    -- 路径 A：chapter_map 已有该 toc_idx 的云端 item_id → 直接查云端缓存
    local mapped_item_id = book and book.chapter_map and book.chapter_map[tostring(toc_idx)]
    if mapped_item_id and mapped_item_id ~= "" then
        local cloud_key = "cloud:" .. tostring(mapped_item_id)
        local cached = plugin._local_review_cache and plugin._local_review_cache[cloud_key]
        if cached then
            apply_records(cached, cloud_key)
            LocalReview.trigger_prefetch(plugin, toc_idx)
            return
        end
        -- ★ cache 未命中 → 先读磁盘 records
        if try_disk_records(cloud_key, tostring(mapped_item_id)) then
            LocalReview.trigger_prefetch(plugin, toc_idx)
            return
        end
        -- 磁盘也没有 → 拉取（用 mapped_item_id）
        LocalReview.dump_current_chapter(plugin, book,
            tostring(mapped_item_id), chapter_start_page, cloud_key, toc_idx)
        return
    end

    -- 路径 B：chapter_map 没有 → 异步匹配云端 item_id
    LocalReview.locate_chapter_by_title(plugin, book,
        chapter_title, chapter_start_page, function(item_id)
            if not item_id then return end

            -- 写入 chapter_map（自动匹配结果也持久化）
            set_chapter_map(plugin, book, toc_idx, item_id)

            local cloud_key = "cloud:" .. tostring(item_id)
            local cached = plugin._local_review_cache and plugin._local_review_cache[cloud_key]
            if cached then
                -- 云端缓存命中（同一云端章的另一个本地章已拉过）
                apply_records(cached, cloud_key)
                LocalReview.trigger_prefetch(plugin, toc_idx)
                return
            end
            -- ★ cache 未命中 → 先读磁盘 records
            if try_disk_records(cloud_key, tostring(item_id)) then
                LocalReview.trigger_prefetch(plugin, toc_idx)
                return
            end
            -- 磁盘也没有 → 拉取
            LocalReview.dump_current_chapter(plugin, book,
                item_id, chapter_start_page, cloud_key, toc_idx)
        end,
        { toc_idx = toc_idx })
end

function LocalReview.on_pos_update(plugin, pos, pageno)
    LocalReview.on_page_update(plugin)
end

function LocalReview.on_close_document(plugin)
    if plugin.ui then
        pcall(function() plugin.ui:unRegisterTouchZones({{ id = TOUCH_ID }}) end)
        if plugin.ui.view and plugin.ui.view.view_modules then
            plugin.ui.view.view_modules[MODULE_NAME] = nil
        end
    end
    plugin._local_review_overlay = nil
    plugin._local_review_cache = {}
    plugin._local_review_prefetching = {}
    plugin._local_review_current_local_key = nil
    plugin._local_review_current_cloud_key = nil
end

-- ============================================================================
-- 段评缓存管理：枚举 / 删除 / 继续下载
-- ============================================================================

-- 返回该书的段评缓存列表：{ {item_id, comment_count, title}, ... }
-- 有 catalog_cache.lua 时遍历所有章；无目录时退回遍历 para_comments_*.lua
function LocalReview.list_review_cache(plugin, book)
    if not book or not book.book_id then return {} end
    local ok_content, Content = pcall(require, "fanqie.content")
    if not ok_content or not Content then return {} end
    local dir = Content.book_cache_dir(plugin.settings, book.book_id)
    local lfs = require("libs/libkoreader-lfs")
    local list = {}

    if lfs.attributes(dir, "mode") ~= "directory" then return {} end

    -- 一次 lfs.dir 收集存在的文件名
    local has_records, has_counts = {}, {}
    for entry in lfs.dir(dir) do
        local rid = entry:match("^para_records_(.+)%.lua$")
        if rid then has_records[rid] = true end
        local cid = entry:match("^para_comments_(.+)%.count$")
        if cid then has_counts[cid] = true end
    end

    local catalog = Content.load_catalog_cache(plugin.settings, book.book_id) or {}

    if #catalog > 0 then
        for _, ch in ipairs(catalog) do
            local item_id = tostring(ch.itemId or ch.item_id or "")
            if item_id ~= "" then
                local total = 0
                if has_records[item_id] then
                    local ok_r, recs = pcall(dofile, dir .. "/para_records_" .. item_id .. ".lua")
                    if ok_r and type(recs) == "table" then
                        for _ in ipairs(recs) do total = total + 1 end
                    end
                end
                local saved = 0
                if has_counts[item_id] then
                    saved = Content.load_comments_count(plugin.settings, book.book_id, item_id) or 0
                end
                list[#list + 1] = {
                    item_id = item_id,
                    review_count = total,
                    comment_count = saved,
                    title = ch.title or item_id,
                }
            end
        end
    else
        for item_id in pairs(has_records) do
            local total = 0
            local ok_r, recs = pcall(dofile, dir .. "/para_records_" .. item_id .. ".lua")
            if ok_r and type(recs) == "table" then
                for _ in ipairs(recs) do total = total + 1 end
            end
            local saved = 0
            if has_counts[item_id] then
                saved = Content.load_comments_count(plugin.settings, book.book_id, item_id) or 0
            end
            list[#list + 1] = {
                item_id = item_id,
                review_count = total,
                comment_count = saved,
                title = item_id,
            }
        end
        table.sort(list, function(a, b) return tostring(a.item_id) < tostring(b.item_id) end)
    end

    return list
end

-- 删除单章段评缓存（para_reviews / para_records / para_comments 三个文件）
-- 同时清内存 cache["cloud:<item_id>"]
function LocalReview.delete_chapter_review_cache(plugin, book, item_id)
    if not book or not book.book_id or not item_id then return end
    local ok_content, Content = pcall(require, "fanqie.content")
    if not ok_content or not Content then return end
    local dir = Content.book_cache_dir(plugin.settings, book.book_id)
    for _, name in ipairs({
        "para_reviews_" .. tostring(item_id) .. ".lua",
        "para_records_" .. tostring(item_id) .. ".lua",
        "para_comments_" .. tostring(item_id) .. ".lua",
        "para_comments_" .. tostring(item_id) .. ".count",
    }) do
        local path = dir .. "/" .. name
        if H.file_exists(path) then os.remove(path) end
    end
    plugin._local_review_cache = plugin._local_review_cache or {}
    plugin._local_review_cache["cloud:" .. tostring(item_id)] = nil
end

-- 触发单章下载：
--   有 para_reviews → 只补评论正文（_background_cache_comments）
--   无 para_reviews → 调 fetch_chapter_records 拉整个（索引 + findText + 评论正文）
-- 没网络时弹 WiFi 框，联网后重跑。
function LocalReview.continue_chapter_review_cache(plugin, book, item_id)
    if not book or not book.book_id or not item_id then return end

    -- 没网络时弹 WiFi 框，联网后重跑
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr and NetworkMgr.willRerunWhenOnline then
        if NetworkMgr:willRerunWhenOnline(function()
            LocalReview.continue_chapter_review_cache(plugin, book, item_id)
        end) then
            return
        end
    end

    local ok_content, Content = pcall(require, "fanqie.content")
    if not ok_content or not Content then return end

    local reviews = Content.load_para_reviews_index(plugin.settings, book.book_id, item_id)
    if reviews and #reviews > 0 then
        -- 有索引，只补评论正文
        plugin._comment_cache_running = plugin._comment_cache_running or {}
        plugin._comment_cache_running[tostring(book.book_id) .. ":" .. tostring(item_id)] = nil
        LocalReview._background_cache_comments(plugin, book, item_id, reviews)
    else
        -- 无索引，拉整个（索引 + findText + 落盘 + 评论正文）
        local cloud_key = "cloud:" .. tostring(item_id)
        LocalReview.fetch_chapter_records(plugin, book, item_id, 1, cloud_key, function(records)
            local Notification = require("ui/widget/notification")
            UIManager:show(Notification:new{
                text = string.format("段评 %d 条", records and #records or 0),
                timeout = 2,
            })
        end)
    end
end

LocalReview.load_bindings = load_bindings

return LocalReview
