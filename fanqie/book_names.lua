-- 书架书名校正：把 Web 接口的「SEO 推广名」换成 App 里的「正式书名」。
--
-- 背景（2026-10-26 实测，23 本书全量核对）：
--   * 插件登录的是番茄 Web 端，`/api/bookshelf/multidetail` 的 `book_name`
--     是**给搜索流量看的 SEO 长标题**（前挂 IP、堆关键词）。
--     例：book_id 7567557009482976281 → 「笑傲江湖：乔峰重生，荡平天下」
--   * App 端用的正式名（例：「乔峰笑傲江湖！」）只出现在 App 那套接口里。
--   * App 的免登录搜索接口能拿到它：
--       https://novel.snssdk.com/api/novel/channel/homepage/search/search/v1/?aid=1967&q=<书名>
--     只要 App UA，不要 Cookie；响应用 `book_id` 精确匹配（**绝不按名字相似度猜**）。
--     实测 23/23 全部命中，其中 19 本名字不同。
--   * 按 book_id 直查的路径（book/detail、book/info 等）全部 404，只有搜索可用。
--     所以策略是「用 Web 名去搜，再用 book_id 认领结果」。
--
-- ⚠️ 上游 hesan1232 与 moon 都是 `item.book_name`，同样拿不到 App 名，
--    这块没人解决过（moon 甚至书架 `book_name`、搜索 `title` 自己都不一致）。
--
-- 缓存：<cache_dir>/<book_id>/app_name.lua = { name, at, tried }
--   * TTL 只决定「要不要再核对一次」，**不影响已拿到的名字**：
--     过期的名字继续用，绝不退回 SEO 名（否则书架上名字会周期性跳变）。
--   * 搜索成功但结果里没有这本书 → tried，7 天内不重复搜。
--   * 传输层失败 → 不落盘，下次书架刷新再试。
--
-- 统计身份：统计库靠 md5 = "fanqie-<book_id>" 定位行，改名**不会**把历史拆成两行；
--   title 只是簿记的显示列，改名后同步 UPDATE 过去（M.backfill_stats_title）。

local M = {}

local ok_H, H = pcall(require, "fanqie.helper")
if not ok_H then H = nil end

local ok_Content, Content = pcall(require, "fanqie.content")
if not ok_Content then Content = nil end

local function is_str(s)
    return H and H.is_str and H.is_str(s) or type(s) == "string"
end

local function log_debug(...)
    local ok, L = pcall(require, "fanqie.logger")
    if ok and type(L) == "table" and L.debug then pcall(L.debug, ...) end
end

-- App 端 UA：搜索接口不带它会被挡（Web UA 返回空 body）
M.APP_UA = "com.dragon.read/6.5.3.32 (Linux; U; Android 13; zh_CN; "
    .. "VDE-AL10; Build/TP1A.220624.014;tt-ok/3.10.0.2)"
M.SEARCH_BASE = "https://novel.snssdk.com/api/novel/channel/homepage/search/"
    .. "search/v1/?aid=1967&offset=0&q="

M.TTL = 7 * 24 * 60 * 60   -- 7 天：过一周才重新核对，稳态下书架刷新 0 请求
M.REQUEST_GAP = 0.2        -- 串行节流，23 本约 5 秒
M.MAX_PER_RUN = 25         -- 单次最多查 25 本：除以节流后落在 Async 超时之内

local BUSY = false         -- 同一时刻只允许一个校正任务（书架会被反复打开）

-- 缓存路径：<cache_dir>/<book_id>/app_name.lua（与 book_meta.lua 同目录）
function M.cache_path(settings, book_id)
    if not settings or not is_str(book_id) or book_id == "" then return nil end
    if Content and Content.book_cache_dir then
        local ok, dir = pcall(Content.book_cache_dir, settings, book_id)
        if ok and is_str(dir) then return H.join_path(dir, "app_name.lua") end
    end
    return nil
end

-- 返回 (name, at, tried)。name 为空串表示「缓存里就是没名字」。
function M.read(settings, book_id)
    local path = M.cache_path(settings, book_id)
    if not path or not H or not H.file_exists(path) then return nil, 0, false end
    local ok, meta = pcall(dofile, path)
    if not ok or type(meta) ~= "table" then return nil, 0, false end
    local name = is_str(meta.name) and meta.name or ""
    return name, tonumber(meta.at) or 0, meta.tried == true
end

-- 已缓存的正式名。**不看 TTL**：过期也继续用，绝不退回 SEO 名。
function M.get(settings, book_id)
    local name = M.read(settings, book_id)
    if is_str(name) and name ~= "" then return name end
    return nil
end

-- 是否需要再发一次网络请求
function M.needs_fetch(settings, book_id, now)
    local name, at, tried = M.read(settings, book_id)
    now = now or os.time()
    if is_str(name) and name ~= "" then
        return (now - at) >= M.TTL      -- 有名字：只按 TTL 复核
    end
    if tried then
        return (now - at) >= M.TTL      -- 确认过没有：同样按 TTL
    end
    return true                          -- 从没查过
end

function M.save(settings, book_id, name, tried)
    local path = M.cache_path(settings, book_id)
    if not path or not H or not H.write_file then return false end
    -- 父目录可能还没建（未下载过的书）
    if Content and Content.book_cache_dir then
        local ok, dir = pcall(Content.book_cache_dir, settings, book_id)
        if ok and is_str(dir) and H.make_dir then pcall(H.make_dir, dir) end
    end
    local body = string.format("return { name = %q, at = %d, tried = %s }\n",
        is_str(name) and name or "", os.time(), tried and "true" or "false")
    local ok = pcall(H.write_file, path, body)
    return ok and true or false
end

-- 从搜索响应里按 book_id 取正式书名。
-- 优先走 JSON 解码 + 深度查找（结构与字段位置都不可信，别用正则猜）；
-- 解码不可用时退回「以 book_id 为锚点切段再找 title」的兜底。
function M.parse_title(text, book_id, decoder)
    if not is_str(text) or text == "" or not is_str(book_id) or book_id == "" then
        return nil
    end
    local target = tostring(book_id)

    if decoder then
        local ok, data = pcall(decoder, text)
        if ok and type(data) == "table" then
            local found = nil
            local function walk(t, depth)
                if found or type(t) ~= "table" or depth > 6 then return end
                local bid = t.book_id or t.bookId or t.id
                if bid ~= nil and tostring(bid) == target then
                    local title = t.title or t.book_name or t.bookName
                    if is_str(title) and title ~= "" then
                        found = title
                        return
                    end
                end
                for _, v in pairs(t) do
                    if type(v) == "table" then walk(v, depth + 1) end
                    if found then return end
                end
            end
            walk(data, 0)
            if found then return found end
        end
    end

    -- 兜底：以 "book_id":"<id>" 为锚，取其后 4000 字里第一个 "title":"…"。
    -- 只用于解码失败（极少），命中错的可能性由外层 book_id 精确匹配挡住主要风险。
    for _, key in ipairs({ "book_id", "bookId" }) do
        local pos = text:find('"' .. key .. '":"' .. target .. '"', 1, true)
        if pos then
            local seg = text:sub(pos, pos + 4000)
            local title = seg:match('"title":"([^"]*)"')
            if title and title ~= "" then return title end
        end
    end
    return nil
end

-- 用本地缓存的名字覆盖 books[i].title（纯内存，不发网络）。
-- 同时把接口原名记到 web_title，作为下次搜索的 query。
-- 返回被改名的本数。
function M.decorate(settings, books)
    if not settings or type(books) ~= "table" then return 0 end
    local changed = 0
    for _, b in ipairs(books) do
        if type(b) == "table" then
            local bid = b.book_id and tostring(b.book_id) or ""
            if bid ~= "" then
                -- web_title 一旦记下就不再变：title 会被改，原始名只此一份
                if not is_str(b.web_title) or b.web_title == "" then
                    b.web_title = is_str(b.title) and b.title or ""
                end
                local name = M.get(settings, bid)
                if name and name ~= b.title then
                    b.title = name
                    changed = changed + 1
                end
            end
        end
    end
    return changed
end

-- 回填统计库书名：统计行靠 md5 定位，这里只改显示列，历史页数/时长不受影响。
-- 批量版：一次开库改多本（回调跑在 UI 线程，别为每本书开关一次 sqlite）。
-- items = { { id = "<book_id>", title = "书名" }, ... }
function M.backfill_stats_titles(items)
    if type(items) ~= "table" or #items == 0 then return 0 end
    local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq3 or not SQ3 then return 0 end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds or type(DataStorage) ~= "table" then return 0 end
    local ok_path, dir = pcall(DataStorage.getSettingsDir, DataStorage)
    if not ok_path or not is_str(dir) then return 0 end
    local ok_db, db = pcall(SQ3.open, dir .. "/statistics.sqlite3")
    if not ok_db or not db then return 0 end
    local n = 0
    for _, it in ipairs(items) do
        if type(it) == "table" and is_str(it.id) and it.id ~= ""
            and is_str(it.title) and it.title ~= "" then
            local md5 = "fanqie-" .. tostring(it.id)
            local esc = it.title:gsub("'", "''")
            local ok = pcall(function()
                db:exec(string.format("UPDATE book SET title = '%s' WHERE md5 = '%s';", esc, md5))
            end)
            if ok then n = n + 1 end
        end
    end
    pcall(db.close, db)
    return n
end

function M.backfill_stats_title(book_id, title)
    if not is_str(book_id) or book_id == "" then return false end
    if not is_str(title) or title == "" then return false end
    return M.backfill_stats_titles({ { id = book_id, title = title } }) > 0
end

-- 子进程内休眠。无 fork（降级同步）时绝不休眠，否则卡 UI。
local function sleep_seconds(sec)
    if not sec or sec <= 0 then return end
    local ok_a, Async = pcall(require, "fanqie.async")
    if ok_a and type(Async) == "table" and Async.is_available then
        local ok_av, avail = pcall(Async.is_available)
        if ok_av and not avail then return end
    end
    local ok_s, socket = pcall(require, "socket")
    if ok_s and type(socket) == "table" and type(socket.sleep) == "function" then
        pcall(socket.sleep, sec)
    end
end

-- 查一本书的正式名（在子进程里跑）。
-- 返回 (name, status)：status = "ok" / "empty"（搜到了但没这本）/ "error"
function M.fetch_one(client, book_id, query)
    if not client or not is_str(book_id) or book_id == "" then return nil, "error" end
    if not is_str(query) or query == "" then return nil, "empty" end
    local ok_enc = H and H.url_encode
    local url = M.SEARCH_BASE .. (ok_enc and H.url_encode(query) or query)
    local ok_get, text = pcall(function()
        return client:get_text(url, {
            headers = { ["User-Agent"] = M.APP_UA },
            referer = false,   -- 这是 App 接口，带 Web Referer 反而不像客户端
        })
    end)
    if not ok_get or not is_str(text) or text == "" then
        return nil, "error"
    end
    local decoder = nil
    if type(client.json_decode) == "function" then
        decoder = function(s) return client:json_decode(s) end
    end
    local name = M.parse_title(text, book_id, decoder)
    if name and name ~= "" then return name, "ok" end
    return nil, "empty"
end

-- 后台校正入口。同步部分只做「用已有缓存改名」，网络全在子进程。
-- on_updated(books) 在拿到新名字并写回 books 后调用一次（可能一次都不调）。
function M.ensure(settings, books, on_updated)
    if not settings or type(books) ~= "table" or #books == 0 then return false end
    M.decorate(settings, books)   -- 先用缓存名，保证界面立刻正确
    if BUSY then return false end

    local todo = {}
    for _, b in ipairs(books) do
        if type(b) == "table" and #todo < M.MAX_PER_RUN then
            local bid = b.book_id and tostring(b.book_id) or ""
            local query = b.web_title or ""
            if bid ~= "" and query ~= "" and M.needs_fetch(settings, bid) then
                todo[#todo + 1] = { book_id = bid, query = query }
            end
        end
    end
    if #todo == 0 then return false end

    local ok_Async, Async = pcall(require, "fanqie.async")
    if not ok_Async or type(Async) ~= "table" or not Async.run then
        return false
    end

    BUSY = true
    -- pcall 包住：Async.run 自身抛错（无 fork / 管道失败）时 BUSY 必须复位，
    -- 否则本次会话再也不会有第二次校证书名的机会
    local ok_run = pcall(Async.run, function()
        local ok_client, Client = pcall(require, "fanqie.client")
        if not ok_client or type(Client) ~= "table" or not Client.new then
            error("client unavailable", 0)
        end
        local ok_new, client = pcall(function() return Client:new(settings) end)
        if not ok_new or not client then error("client init failed", 0) end

        local out = {}
        for i, it in ipairs(todo) do
            local ok_one, name, status = pcall(M.fetch_one, client, it.book_id, it.query)
            if ok_one then
                out[it.book_id] = {
                    name = name,
                    -- 解析到书 / 明确了「搜到但没有这本」才落盘；
                    -- 传输层故障不落盘，下次书架刷新重试
                    tried = (status == "empty") or false,
                }
            end
            if i < #todo then sleep_seconds(M.REQUEST_GAP) end
        end
        return out
    end, function(ok, result)
        BUSY = false
        if not ok or type(result) ~= "table" then
            log_debug("[book_names] 校证书名子进程异常，本次不落盘")
            return
        end
        local changed = 0
        local sql_items = {}
        for bid, item in pairs(result) do
            if type(item) == "table" and is_str(item.name) and item.name ~= "" then
                M.save(settings, bid, item.name, true)
                sql_items[#sql_items + 1] = { id = bid, title = item.name }
                changed = changed + 1
            elseif type(item) == "table" and item.tried then
                M.save(settings, bid, nil, true)
            end
        end
        -- 一次开库改完，避免 UI 线程上开关 20 次 sqlite
        if #sql_items > 0 then M.backfill_stats_titles(sql_items) end
        if changed > 0 then
            M.decorate(settings, books)
            log_debug("[book_names] 已校正书名:", tostring(changed), "本")
            if on_updated then pcall(on_updated, books) end
        end
    end, {
        poll_interval = 0.3,
        -- 25 本 × (请求 + 0.2s 节流) 可能超过默认 60s；给足余量，
        -- 超时则整批不落盘（下次书架刷新重试），不会写半截错误数据
        timeout = 150,
        on_cancel = function() BUSY = false end,
    })
    if not ok_run then
        BUSY = false
        log_debug("[book_names] Async.run 启动失败，本次跳过")
        return false
    end
    return true
end

return M
