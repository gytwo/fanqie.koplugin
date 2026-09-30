-- fanqie/local_review.lua

local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(t) return t end

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
                "  [%q] = { book_id=%q, title=%q, author=%q, _search_source=%q, book_url=%q, source=%q },",
                file, b.book_id or "", b.title or "", b.author or "",
                b._search_source or "", b.book_url or "", b.source or "")
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
    local idx = tonumber(record.para_index)
    if not idx then
        local ok_state, _state = pcall(require, "fanqie.state")
        if ok_state and _state and _state.getCurrentParaReviews then
            local reviews = _state.getCurrentParaReviews() or {}
            for i, pr in ipairs(reviews) do
                if tostring(pr.ident) == tostring(record.ident) then
                    idx = i
                    break
                end
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

local function merge_all_records(plugin)
    local all = {}
    for _, recs in pairs(plugin._local_review_cache or {}) do
        for _, r in ipairs(recs) do all[#all + 1] = r end
    end
    return all
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
        local Notification = require("ui/widget/notification")
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
            if _state then _state.active_menu = nil end

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
function LocalReview.locate_chapter_by_title(plugin, book, chapter_title, chapter_start_page, on_done)
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
            if on_done then on_done(nil) end
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
        end)
end

-- ============================================================================
-- 3. 拉段评 + 定位
-- ============================================================================
function LocalReview.fetch_chapter_records(plugin, book, item_id, chapter_start_page, chapter_uid, on_done)
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

        -- 预取判定：chapter_uid 不是当前章 key 时视为预取，不覆盖 _state
        local is_prefetch = (chapter_uid ~= plugin._local_review_current_key)

        local function finish()
            if saved_xp then pcall(doc.gotoXPointer, doc, saved_xp) end

            -- 非预取时把 records 的 ident/count 写进 _state.current_para_reviews，
            -- 让 main.lua 的 showParaReviewDetail(index) 能按 index 取到 ident。
            -- 同时给每条 rec 标 para_index（1-based）。
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

            if on_done then on_done(records) end
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
        local key = "local:" .. tostring(idx) .. ":" .. tostring(start_page)
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
            LocalReview.fetch_chapter_records(plugin, plugin._local_review_book,
                item_id, plan.start_page, plan.key, function(records)
                    plugin._local_review_prefetching[plan.key] = nil
                    if records then
                        plugin._local_review_cache[plan.key] = records
                    end
                    UIManager:scheduleIn(0.5, function()
                        LocalReview._prefetch_next(plugin, planned, i + 1)
                    end)
                end)
        end)
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
function LocalReview.dump_current_chapter(plugin, book, item_id, chapter_start_page, chapter_key, toc_idx)
    return LocalReview.fetch_chapter_records(plugin, book, item_id, chapter_start_page,
        chapter_key, function(records)
            if records then
                plugin._local_review_cache = plugin._local_review_cache or {}
                plugin._local_review_cache[chapter_key] = records
                if plugin._local_review_overlay then
                    plugin._local_review_overlay:setRecords(merge_all_records(plugin))
                    UIManager:setDirty(plugin.ui, "partial")
                end
            end
            local Notification = require("ui/widget/notification")
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
    plugin._local_review_current_key = nil

    LocalReview.auto_match(plugin, function(book)
        if not book then return end
        LocalReview.locate_current_chapter(plugin, book, function(item_id, chapter_start_page, toc_idx)
            if not item_id then return end
            local chapter_key = "local:" .. tostring(toc_idx) .. ":" .. tostring(chapter_start_page)
            plugin._local_review_current_key = chapter_key
            LocalReview.dump_current_chapter(plugin, book, item_id, chapter_start_page, chapter_key, toc_idx)
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
    plugin._local_review_cache = plugin._local_review_cache or {}
    plugin._local_review_prefetching = plugin._local_review_prefetching or {}
    plugin._local_review_bindings = plugin._local_review_bindings or load_bindings(plugin)

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
            plugin._local_review_book = binding

            local Notification = require("ui/widget/notification")
            UIManager:show(Notification:new{
                text = _("正在预取段评..."),
                timeout = 2,
            })

            LocalReview.on_page_update(plugin)
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
    local chapter_key = "local:" .. tostring(toc_idx) .. ":" .. tostring(chapter_start_page)

    if plugin._local_review_current_key == chapter_key then
        return
    end
    plugin._local_review_current_key = chapter_key

    if plugin._local_review_cache and plugin._local_review_cache[chapter_key] then
        if plugin._local_review_overlay then
            plugin._local_review_overlay:setRecords(merge_all_records(plugin))
            UIManager:setDirty(plugin.ui, "partial")
        end
        -- 缓存命中时，把 records 的 ident/count 写进 _state（非预取）
        local ok_state, _state = pcall(require, "fanqie.state")
        if ok_state and _state and _state.setCurrentParaReviews then
            local records = plugin._local_review_cache[chapter_key] or {}
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
        LocalReview.trigger_prefetch(plugin, toc_idx)
        return
    end

    LocalReview.locate_chapter_by_title(plugin, plugin._local_review_book,
        chapter_title, chapter_start_page, function(item_id)
            if not item_id then return end
            LocalReview.dump_current_chapter(plugin, plugin._local_review_book,
                item_id, chapter_start_page, chapter_key, toc_idx)
        end)
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
    plugin._local_review_current_key = nil
end

return LocalReview
