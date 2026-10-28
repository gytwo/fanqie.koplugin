local M = {
    _mark = "_fanqie_patch",
    _mark_link = "_fanqie_patch_link",
    -- 补丁5（ReaderLink）v2 标记：新增 onTap 主拦层。
    -- 🔴 必须换新标记：老设备上 _mark_link 已被旧补丁置 true，
    --    沿用旧标记会让补丁5 整块被跳过，新代码永远装不上（症状与没改一样）。
    _mark_link_v2 = "_fanqie_patch_link_v2",
    -- 导航补丁（ReaderPaging & ReaderRolling）版本化标记：
    -- 升级时改变此值即可强制重新安装，无需改动 _mark / _mark_link。
    -- v3: 回退向前翻页拦截（仅保留向后翻页的上一章拦截）
    -- v4: 改用 crengine getPrevPage 物理关系 + 先判后调 + no_page_turn 守卫
    _mark_nav = "_fanqie_patch_nav_v4",
}

local H = require("fanqie.helper")
local ok_Log, Log = pcall(require, "fanqie.logger")

M.verifyPatched = function(modname)
    if modname == "ReaderLink" then
        local ReaderLink = require("apps/reader/modules/readerlink")
        return ReaderLink[M._mark_link_v2] == true
    end
    -- 默认检查所有补丁是否都已安装
    local ReaderToc = require("apps/reader/modules/readertoc")
    if ReaderToc[M._mark] ~= true then return false end
    local ReaderLink = require("apps/reader/modules/readerlink")
    if ReaderLink[M._mark_link_v2] ~= true then return false end
    -- 导航补丁（ReaderPaging & ReaderRolling）— 版本化检查
    local ReaderPaging = require("apps/reader/modules/readerpaging")
    if ReaderPaging[M._mark_nav] ~= true then return false end
    local ReaderRolling = require("apps/reader/modules/readerrolling")
    if ReaderRolling[M._mark_nav] ~= true then return false end
    return true
end

M.is_plugin_disabled = function()
    if G_reader_settings and G_reader_settings.readSetting then
        local plugins_disabled = G_reader_settings:readSetting("plugins_disabled")
        if plugins_disabled and plugins_disabled["fanqie"] == true then
            return true
        end
    end
    return false
end

--- 判据未命中时的显性告警（同一路径只报一次，总量封顶 20 条）。
-- 判据本身是「形状匹配」，一旦将来目录/文件名规则变化，补丁会再次静默失效；
-- 这条 WARN 让「改了没生效」在日志里留痕，而不是让人靠猜。
local _path_warned = {}
local _path_warn_count = 0
local function warn_shape_mismatch(path)
    if _path_warned[path] or _path_warn_count >= 20 then return end
    _path_warned[path] = true
    _path_warn_count = _path_warn_count + 1
    if ok_Log and Log then
        Log.warn("[patches] 疑似番茄章节但目录形状不符，判据未命中:", path)
    end
end

--- 判断一个文档路径是不是「番茄缓存目录里的章节文件」。
-- 结构判据，不依赖目录名、不依赖大小写：
--   ① 尾部是章节文件名 `.../chapter_<item_id>.html`；
--   ② 其父目录名是书号形状：≥6 位、只含 [%w%._-]、且至少含一位数字。
-- ② 与 content.lua 的 basename_safe 同源（它把非法字符一律换成 _），
-- 番茄 book_id 是纯数字长串，所以自家写出的缓存路径恒满足。
-- 「至少含一位数字」是本仓库对上游的一处收紧：只按长度+字符集判断时，
-- `.../novels/chapter_1.html`、`.../fanqie/chapter_1.html` 这类纯字母
-- 目录名也会命中 ⇒ 用户本地 HTML 小说会被劫持目录/历史/翻章。加上数字
-- 要求后两者判假，而真实书号目录必然带数字，不会造成漏判。
-- 旧判据 `find("/fanqie/")`：用户把下载目录改成 SD 卡 /「番茄小说」等
-- 任何不含 fanqie 的路径后恒假 ⇒ 5 个补丁全部静默失效。
local is_fanqie_path = function(file_path, instance)
    if instance and instance.document and instance.document.file then
        file_path = instance.document.file
    end
    if not H.is_str(file_path) or file_path == "" then
        return false
    end
    -- 兼容 Windows 风格分隔符（开发机 / 回归桩）
    local normalized = file_path:gsub("\\", "/")
    if not normalized:match("/chapter_[^/]+%.html$") then
        return false
    end
    local parent = normalized:match("/([^/]+)/chapter_[^/]+%.html$")
    if parent and #parent >= 6
            and not parent:match("[/\\]")     -- 已经由 match 保证不含分隔符
            and parent:match("%d") then       -- 至少含一位数字（书号）
        return true
    end
    warn_shape_mismatch(normalized)
    return false
end

-- 「当前位置是不是整个文档的开头」——翻到上一章的唯一判据。
-- 直接用 crengine 自己的物理关系：document:getPrevPage(page) == 0
-- 就是「这一页前面没有页」（KOReader 判首页同款写法）。
-- 取不到 getPrevPage（老 crengine）时才退回「第 1 页」。
local function prev_page_of(doc, page)
    if not doc or type(page) ~= "number" then return nil end
    if type(doc.getPrevPage) ~= "function" then return nil end
    local ok, prev = pcall(doc.getPrevPage, doc, page)
    if not ok or type(prev) ~= "number" then return nil end
    return prev
end

--- ReaderPaging（有物理页的文档）是否已在文档开头。
-- 番茄 HTML/crengine 文档的 ui.paging 根本不注册（只有 has_pages 时才注册），
-- 这一层实际走不到；保留是为了将来 KOReader 改模块划分时不行为倒退。
local function paging_at_document_start(paging_self)
    local doc = paging_self and paging_self.ui and paging_self.ui.document
    if not doc then return false end
    -- 连续滚动模式：getTopPage 不可靠，改看文档内位置比例（0 = 顶部）
    if paging_self.view and paging_self.view.page_scroll then
        local ok, position = pcall(paging_self.getTopPosition, paging_self)
        if not ok or type(position) ~= "number" or position > 0.001 then
            return false
        end
    end
    local page
    if type(paging_self.getTopPage) == "function" then
        local ok, p = pcall(paging_self.getTopPage, paging_self)
        if ok and type(p) == "number" then page = p end
    end
    if type(page) ~= "number" then return false end
    local prev = prev_page_of(doc, page)
    if prev then return prev == 0 end
    return page == 1
end

--- ReaderRolling（crengine 文档）是否已在文档开头。番茄章节走的就是这条。
local function rolling_at_document_start(rolling_self)
    local doc = rolling_self and rolling_self.ui and rolling_self.ui.document
    if not doc then return false end
    local view_mode = rolling_self.view and rolling_self.view.view_mode
    if view_mode == "scroll" then
        -- current_pos 是文内位置（像素，0 = 顶部）。滚动模式下「第 1 页」可能
        -- 横跨好几屏，只看 current_page 会把章中误判成开头 ⇒ 位置与页号都看。
        local pos = rolling_self.current_pos
        if type(pos) ~= "number" or pos > 0.001 then return false end
        local prev = prev_page_of(doc, rolling_self.current_page)
        return prev == nil or prev == 0
    end
    local prev = prev_page_of(doc, rolling_self.current_page)
    if prev then return prev == 0 end
    return rolling_self.current_page == 1
end

M.install = function()
    if M.is_plugin_disabled() then
        return
    end
    if M.verifyPatched() then
        return
    end

    local Event = require("ui/event")

    -- 补丁1：ReaderToc — 番茄文档的目录交给插件处理
    local ReaderToc = require("apps/reader/modules/readertoc")
    if not ReaderToc[M._mark] then
        local original_onShowToc = ReaderToc.onShowToc
        function ReaderToc:onShowToc()
            if is_fanqie_path(nil, self.ui) then
                self.ui:handleEvent(Event:new("ShowFanQieToc"))
                return true
            else
                return original_onShowToc(self)
            end
        end
        ReaderToc[M._mark] = true
    end

    -- 补丁2：ReadHistory — 番茄缓存文件不进入阅读历史
    local ReadHistory = require("readhistory")
    if not ReadHistory[M._mark] then
        local original_addItem = ReadHistory.addItem
        function ReadHistory:addItem(file, ts, no_flush)
            if is_fanqie_path(file) then
                return
            end
            return original_addItem(self, file, ts, no_flush)
        end
        ReadHistory[M._mark] = true
    end

    -- 补丁3：ReaderPaging — 在文档开头前翻页时触发上一章
    local ReaderPaging = require("apps/reader/modules/readerpaging")
    if not ReaderPaging[M._mark_nav] then
        local original_onGotoViewRel = ReaderPaging.onGotoViewRel
        function ReaderPaging:onGotoViewRel(diff, no_page_turn)
            -- no_page_turn = true 是 ReaderSearch 的搜索游标移动
            -- （readersearch.lua 调 paging:onGotoViewRel(-1, true)），不是翻页意图：
            -- 页面刻意不动，位置比较必然「没变」，老逻辑会把它吞成跳章。
            -- 先判后调：命中就提前返回，不让 crengine 先白翻一次。
            if diff and diff < 0 and no_page_turn ~= true
                    and is_fanqie_path(nil, self.ui)
                    and paging_at_document_start(self) then
                self.ui:handleEvent(Event:new("FanQiePrevChapter"))
                return true
            end
            return original_onGotoViewRel(self, diff, no_page_turn)
        end
        ReaderPaging[M._mark_nav] = true
    end

    -- 补丁4：ReaderRolling — 滚动模式 / 分页模式在文档开头前翻页触发上一章。
    -- 老实现「先调原函数再比较调用前后位置」有三处误判：
    --   current_page 为 nil（未首绘）时 nil == nil 成立；滚动模式 current_page
    --   常恒为 1（一页跨几屏）导致章中被判章首；且先调会在文档开头白翻一次。
    local ReaderRolling = require("apps/reader/modules/readerrolling")
    if not ReaderRolling[M._mark_nav] then
        local original_onGotoViewRel_rolling = ReaderRolling.onGotoViewRel
        ReaderRolling.onGotoViewRel = function(rolling_self, diff)
            if diff and diff < 0 and is_fanqie_path(nil, rolling_self.ui)
                    and rolling_at_document_start(rolling_self) then
                rolling_self.ui:handleEvent(Event:new("FanQiePrevChapter"))
                return true
            end
            -- 原实现的返回值要透传（老代码无条件 return true）
            return original_onGotoViewRel_rolling(rolling_self, diff)
        end
        ReaderRolling[M._mark_nav] = true
    end

    -- 补丁5：ReaderLink — 拦截 fanqie-para:N 段评链接
    -- 链路：onTap → getLinkFromGes → showLinkBox → onGotoLink。
    -- 这里只拦 onGotoLink 就够：crengine 解析不出锚点时，getLinkFromPosition
    -- 会把 href 原样当作 link_xpointer 返回（KOReader 对外部链接就是这个行为），
    -- 于是 showLinkBox 的 `link.xpointer ~= ""` 成立，必然调到 onGotoLink。
    -- 旧实现「点段评气泡报无效或外部链接：fanqie-para:N」的原因不是漏了
    -- 拦截层，而是 is_fanqie_path 判假后整段提前 return 落到原实现 ——
    -- 报错文案里带着 fanqie-para:N 本身就证明链路已经走到了 onGotoLink。
    local ReaderLink = require("apps/reader/modules/readerlink")
    if not ReaderLink[M._mark_link_v2] then
        local original_onGotoLink = ReaderLink.onGotoLink
        function ReaderLink:onGotoLink(link, neglect_current_location, allow_footnote_popup)
            if link and is_fanqie_path(nil, self.ui) then
                -- crengine: link.xpointer；PDF: link.uri
                local link_url = nil
                if self.ui.paging then
                    link_url = link.uri
                else
                    link_url = link.xpointer
                end
                if link_url and type(link_url) == "string"
                    and link_url:find("^fanqie%-para:") then
                    -- 同时认 fanqie-para:18 与 fanqie-para:#18：
                    -- 现存章节缓存里写死的是无 # 格式，重下才会变成新格式
                    local idx = tonumber(link_url:match("fanqie%-para:%s*#?(%d+)"))
                    if idx then
                        self.ui:handleEvent(Event:new("FanQieParaReview", idx))
                        return true
                    end
                end
            end
            return original_onGotoLink(self, link, neglect_current_location,
                allow_footnote_popup)
        end
        ReaderLink[M._mark_link_v2] = true
        -- 老标记也顺手置上：万一还有别处看它，别让它变成 false
        ReaderLink[M._mark_link] = true
    end
end

return M
