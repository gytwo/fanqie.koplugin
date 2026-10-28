-- 书籍元数据（作者）解析与缓存。
-- 背景：书架/目录/书山/知秋接口都不带作者，唯一稳定来源是公开详情页
--   https://fanqienovel.com/page/<book_id> 里的 <span class="author-name-text">。
--   页面 0.2~1.7MB，所以按书抓一次 → 落盘缓存 → 回填统计库，绝不在翻页路径上同步抓。
-- 缓存：<cache_dir>/<book_id>/book_meta.lua = { author, at, tried }
-- ⭐ 只有「页面正常但没有作者」(empty) 才写 tried；传输层/5xx/反爬 515 一律不落盘，
--   否则一次网络抖动就永久放弃（抓取内部另带 3 次重试，间隔 1s/2s）。

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

local function log_warn(...)
    local ok, L = pcall(require, "fanqie.logger")
    if ok and type(L) == "table" and L.warn then pcall(L.warn, ...) end
end

-- 重试策略：总尝试 3 次，失败后分别等待 1s / 2s。
-- 番茄详情页有反爬（偶发 HTTP 515），单次失败不该给这本书判死刑。
local RETRY_MAX = 3
local RETRY_DELAYS = { 1, 2 }

-- 把任意错误值（string / {auth_expired=..., message=...}）转成可读字符串。
local function err_text(e)
    if type(e) == "table" then
        return tostring(e.message or e.err or "table error")
    end
    return tostring(e)
end

-- 判断一次失败是否值得重试。
-- 错误串形如 "GET <url> => HTTP 515, content_type=text/html, body_bytes=123"；
-- 传输层失败（连接被拒 / 超时）时状态码为 nil → "HTTP nil"。
local function is_retryable(err)
    local s = err_text(err)
    local code = tonumber(s:match("HTTP%s+(%d+)"))
    if not code then return true end  -- 无状态码 = 传输层故障，值得重试
    if code == 429 then return true end
    if code >= 500 then return true end -- 含 515 反爬、502/503
    return false                        -- 4xx 是确定性错误，重试无意义
end

-- 子进程内休眠。降级同步路径（无 fork，跑在 UI 线程）绝不休眠，否则卡界面。
local function sleep_seconds(sec)
    if not sec or sec <= 0 then return end
    local ok_a, Async = pcall(require, "fanqie.async")
    if ok_a and type(Async) == "table" and Async.is_available
        and not Async.is_available() then
        return
    end
    local ok_s, socket = pcall(require, "socket")
    if ok_s and type(socket) == "table" and type(socket.sleep) == "function" then
        pcall(socket.sleep, sec)
    end
end

-- <cache_dir>/<book_id>/book_meta.lua（拿不到目录时返回 nil）
function M.meta_path(settings, book_id)
    if not settings or not is_str(book_id) or book_id == "" then return nil end
    if Content and Content.book_cache_dir then
        local ok, dir = pcall(Content.book_cache_dir, settings, book_id)
        if ok and is_str(dir) then return H.join_path(dir, "book_meta.lua") end
    end
    return nil
end

-- 读缓存：返回 (author, tried)。author 为空串表示"缓存里就是没作者"。
function M.read(settings, book_id)
    local path = M.meta_path(settings, book_id)
    if not path or not H or not H.file_exists(path) then return nil, false end
    local ok, meta = pcall(dofile, path)
    if not ok or type(meta) ~= "table" then return nil, false end
    local author = is_str(meta.author) and meta.author or ""
    return author, meta.tried == true
end

function M.get_author(settings, book_id)
    local author = M.read(settings, book_id)
    if author and author ~= "" then return author end
    return nil
end

-- 是否已经抓过（成功或有 tried 标记）——用于决定要不要再发网络请求
function M.is_cached(settings, book_id)
    local author, tried = M.read(settings, book_id)
    if author and author ~= "" then return true end
    return tried
end

function M.save(settings, book_id, author, tried)
    local path = M.meta_path(settings, book_id)
    if not path or not H or not H.write_file then return false end
    local body = string.format("return { author = %q, at = %d, tried = %s }\n",
        is_str(author) and author or "", os.time(), tried and "true" or "false")
    local ok = pcall(H.write_file, path, body)
    return ok and true or false
end

-- 从书籍详情页 HTML 里解析作者。多路兜底，任一命中即返回。
function M.parse_author(html)
    if not is_str(html) or html == "" then return nil end
    local author = html:match('<span class="author%-name%-text">%s*(.-)%s*</span>')
    if not author or author == "" then
        author = html:match('<meta%s+name="author"%s+content="(.-)"')
    end
    if not author or author == "" then
        author = html:match('"authorName"%s*:%s*"(.-)"')
    end
    if not author or author == "" then
        author = html:match('"author_name"%s*:%s*"(.-)"')
    end
    if author and author ~= "" then
        -- HTML 实体兜底（作者名里偶见 &amp; 等）
        author = author:gsub("&amp;", "&"):gsub("&#39;", "'"):gsub("&quot;", '"')
        if H and H.trim then author = H.trim(author) end
        if author ~= "" then return author end
    end
    return nil
end

-- 直接抓一次书籍详情页并解析作者（在子进程里跑）。
-- 返回 (author, status, err)：
--   "ok"    author = 作者名
--   "empty" author = nil，页面正常返回但确实没有作者（确定性 → 可记 tried）
--   "error" author = nil，传输层/服务端故障（非确定性 → 不落盘，下次再试）
function M.fetch_author(settings, book_id)
    if not settings or not is_str(book_id) or book_id == "" then
        return nil, "error", "invalid book_id"
    end
    local ok_client, Client = pcall(require, "fanqie.client")
    if not ok_client or type(Client) ~= "table" or not Client.new then
        return nil, "error", "client unavailable"
    end
    local ok_new, client = pcall(function() return Client:new(settings) end)
    if not ok_new or not client then
        return nil, "error", "client init failed"
    end

    local url = "https://fanqienovel.com/page/" .. tostring(book_id)
    local headers = {}
    local cookies = settings.get and settings:get("cookies", {}) or nil
    if type(cookies) == "table" and next(cookies) then
        local parts = {}
        for k, v in pairs(cookies) do
            table.insert(parts, tostring(k) .. "=" .. tostring(v))
        end
        if #parts > 0 then headers["Cookie"] = table.concat(parts, "; ") end
    end

    local last_err
    for attempt = 1, RETRY_MAX do
        local ok_get, html = pcall(function()
            return client:get_text(url, { headers = headers, referer = "https://fanqienovel.com/" })
        end)
        if ok_get and is_str(html) and html ~= "" then
            local author = M.parse_author(html)
            if author then return author, "ok" end
            -- 页面拿到了、只是没有作者字段：确定性结果，不重试
            return nil, "empty"
        end

        last_err = ok_get and "empty body" or html
        log_debug("[book_meta] 作者页抓取失败(第" .. tostring(attempt) .. "/"
            .. tostring(RETRY_MAX) .. "次):", tostring(book_id), err_text(last_err))

        if attempt < RETRY_MAX then
            if not is_retryable(last_err) then break end
            sleep_seconds(RETRY_DELAYS[attempt] or 2)
        end
    end
    return nil, "error", err_text(last_err)
end

-- ── 统计库身份收敛 ────────────────────────────────────────────────
-- 为什么不能只写一条 UPDATE authors：
--   KOReader statistics 用 (title, authors, md5) 三元组认书（getIdBookDB），
--   而 book 表上有 UNIQUE(title, authors, md5)。作者在 "N/A" 与真名之间
--   切换一次就会多出一行；之后再想 UPDATE authors 就会撞唯一约束 → 整条
--   语句回滚（外层 pcall 吞掉，日志里什么都看不到），两行永久共存，
--   页记录被拆到两边。所以回填必须是「按 md5 合并成一个身份」，不是改字段：
--     1) 选主行：页记录多者优先 → 已有真名优先 → 最近打开优先
--     2) 其余行的 page_stat_data 改挂主行（UNIQUE 冲突的重复条目跳过，随后清掉）
--     3) 时长/页数累加，last_open 取最大，pages 取最近打开那一行的值
--     4) 先删掉其余行（解除唯一约束），最后才改主行 authors
-- 全过程一个事务，异常回滚，绝不留半合并状态。
local function sql_num(v, default)
    if v == nil then return default end
    local s = tostring(v):gsub("LL$", ""):gsub("%.0$", "")
    return tonumber(s) or default
end

local function sql_quote(s)
    return (tostring(s):gsub("'", "''"))
end

local function fetch_identity_rows(db, md5)
    local rows = {}
    local st = db:prepare(string.format([[
        SELECT b.id, IFNULL(b.authors, ''), IFNULL(b.last_open, 0), IFNULL(b.pages, 0),
               IFNULL(b.total_read_time, 0), IFNULL(b.total_read_pages, 0),
               (SELECT COUNT(*) FROM page_stat_data p WHERE p.id_book = b.id)
        FROM book b WHERE b.md5 = '%s' ORDER BY b.id;
    ]], sql_quote(md5)))
    local r = st:step()
    while r do
        rows[#rows + 1] = {
            id         = sql_num(r[1], 0),
            authors    = tostring(r[2] or ""),
            last_open  = sql_num(r[3], 0),
            pages      = sql_num(r[4], 0),
            time       = sql_num(r[5], 0),
            read_pages = sql_num(r[6], 0),
            psd        = sql_num(r[7], 0),
        }
        r = st:step()
    end
    st:close()
    return rows
end

-- 当前阅读会话正在使用的 book 行 id（没有会话时返回 nil）。
-- 延迟 require：stats.lua 也 require 本模块，放在函数里取才不会撞循环依赖。
local function current_session_id()
    local ok, Stats = pcall(require, "fanqie.stats")
    if ok and type(Stats) == "table" and Stats.current_book_db_id then
        local ok2, id = pcall(Stats.current_book_db_id)
        if ok2 then return tonumber(id) end
    end
    return nil
end

-- 返回 "absent" / "clean" / "updated" / "merged"
local function merge_identity_rows(db, md5, author)
    local rows = fetch_identity_rows(db, md5)
    if #rows == 0 then return "absent" end

    local keep = rows[1]
    for i = 2, #rows do
        local a = rows[i]
        local win = false
        if a.psd ~= keep.psd then
            win = a.psd > keep.psd
        elseif a.authors ~= "N/A" and keep.authors == "N/A" then
            win = true
        elseif a.last_open ~= keep.last_open then
            win = a.last_open > keep.last_open
        end
        if win then keep = a end
    end

    -- 当前会话的行是"活"的：KOReader 内存里缓存着它的 id，删掉它只会让
    -- 之后每一页都写到已删除的 id 上（孤儿行）。所以最后一步强制把它定为主行。
    local protected = current_session_id()
    if protected then
        for _, row in ipairs(rows) do
            if row.id == protected then keep = row break end
        end
    end

    local total_time, total_read_pages, last_open = 0, 0, 0
    local pages, pages_stamp = keep.pages, -1
    for _, row in ipairs(rows) do
        total_time       = total_time + row.time
        total_read_pages = total_read_pages + row.read_pages
        if row.last_open > last_open then last_open = row.last_open end
        if row.pages > 0 and row.last_open > pages_stamp then
            pages, pages_stamp = row.pages, row.last_open
        end
    end

    -- 单行且已收敛：直接返回，避免每次打开书都白写一次库
    if #rows == 1 then
        local only = rows[1]
        if only.authors == author and only.last_open == last_open
            and only.pages == pages and only.time == total_time
            and only.read_pages == total_read_pages then
            return "clean"
        end
    end

    for _, row in ipairs(rows) do
        if row.id ~= keep.id then
            -- page_stat_data 上有 UNIQUE(id_book, page, start_time)。旧写法用
            -- "UPDATE OR IGNORE" 搬家：撞车的行会被静默跳过，紧接着的 DELETE 又
            -- 把它删掉 —— 结果是数据丢失 + 留下指向已删 book 的孤儿行（2026-10-26
            -- 在 Kobo 真机上抓到 id_book=201 那条就是这么来的）。
            -- 正确顺序：先删掉与主行同 (page, start_time) 的重复行，再无冲突地搬。
            db:exec(string.format([[
                DELETE FROM page_stat_data
                 WHERE id_book = %d
                   AND EXISTS (SELECT 1 FROM page_stat_data k
                                WHERE k.id_book = %d
                                  AND k.page = page_stat_data.page
                                  AND k.start_time = page_stat_data.start_time);
            ]], row.id, keep.id))
            db:exec(string.format(
                "UPDATE page_stat_data SET id_book = %d WHERE id_book = %d;",
                keep.id, row.id))
            -- 兜底：搬完之后该 id 不应再有行，留一条防御性清理
            db:exec(string.format(
                "DELETE FROM page_stat_data WHERE id_book = %d;", row.id))
            db:exec(string.format("DELETE FROM book WHERE id = %d;", row.id))
        end
    end

    db:exec(string.format([[
        UPDATE book SET authors = '%s', last_open = %d, pages = %d,
                         total_read_time = %d, total_read_pages = %d
        WHERE id = %d;
    ]], sql_quote(author), last_open, pages, total_time, total_read_pages, keep.id))

    return #rows > 1 and "merged" or "updated"
end

-- 打开统计库（打不开就返回 nil，调用方不必再判断 DataStorage 等）
local function open_stats_db()
    local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq3 or not SQ3 then return nil end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds or type(DataStorage) ~= "table" then return nil end
    local ok_path, dir = pcall(DataStorage.getSettingsDir, DataStorage)
    if not ok_path or not is_str(dir) then return nil end
    local ok_db, db = pcall(SQ3.open, dir .. "/statistics.sqlite3")
    if not ok_db or not db then return nil end
    return db
end

-- 一次性收敛：把库里所有 fanqie- 书的重复行合并成一行，并清掉孤儿统计行。
--
-- 为什么需要：merge_identity_rows 只在「打开某本书」时顺手收敛那一本。历史上
-- 早期版本先写 N/A 行、抓到作者后又插一行（UNIQUE(title,authors,md5) 拦不住），
-- 这些老行永远不会被再次打开，就长期躺在库里 —— 2026-10-26 在 Kindle 上查到
-- 3 组（4 行空壳）残留、Kobo 上 1 条孤儿。
--
-- 只处理「多于一行」的组，已收敛的书零写入；整段跑在一个事务里。
-- 返回 { merged = 组数, orphans = 清掉的孤儿行数 }
function M.sweep_stats_db()
    local db = open_stats_db()
    if not db then return nil end

    local out = { merged = 0, orphans = 0 }
    local ok, err = pcall(function()
        db:exec("PRAGMA busy_timeout=5000;")
        db:exec("BEGIN IMMEDIATE;")

        -- 1) 同 md5 多行 → 逐组收敛。代表作者优先取组内已有的真名。
        local groups = {}
        local st = db:prepare([[
            SELECT md5, COUNT(*) FROM book
             WHERE md5 LIKE 'fanqie-%'
             GROUP BY md5 HAVING COUNT(*) > 1;
        ]])
        local r = st:step()
        while r do
            groups[#groups + 1] = tostring(r[1])
            r = st:step()
        end
        st:close()

        for _, md5 in ipairs(groups) do
            -- 组内已有的真名（N/A 不算）作为合并后的作者
            local author = nil
            local ast = db:prepare(string.format([[
                SELECT authors FROM book
                 WHERE md5 = '%s' AND IFNULL(authors, '') NOT IN ('', 'N/A')
                 ORDER BY last_open DESC LIMIT 1;
            ]], sql_quote(md5)))
            local ar = ast:step()
            if ar and is_str(ar[1]) and ar[1] ~= "" then author = tostring(ar[1]) end
            ast:close()
            if author then
                local res = merge_identity_rows(db, md5, author)
                if res == "merged" then
                    out.merged = out.merged + 1
                end
            end
        end

        -- 2) 孤儿统计行：id_book 不在 book 表里（旧合并 bug 的产物），无主数据。
        db:exec("CREATE TEMP TABLE IF NOT EXISTS _fq_orphan AS "
            .. "SELECT id_book FROM page_stat_data "
            .. "WHERE id_book NOT IN (SELECT id FROM book);")
        local ost = db:prepare("SELECT COUNT(*) FROM _fq_orphan;")
        local orow = ost:step()
        if orow then out.orphans = sql_num(orow[1], 0) end
        ost:close()
        if out.orphans > 0 then
            db:exec("DELETE FROM page_stat_data WHERE id_book IN (SELECT id_book FROM _fq_orphan);")
        end
        db:exec("DROP TABLE IF EXISTS _fq_orphan;")

        db:exec("COMMIT;")
    end)

    if not ok then
        pcall(function() db:exec("ROLLBACK;") end)
        log_warn("[book_meta] 统计库收敛失败:", tostring(err))
    else
        log_debug("[book_meta] 统计库收敛: merged=", out.merged, "orphans=", out.orphans)
    end
    pcall(db.close, db)
    return ok and out or nil
end

-- 回填 KOReader 统计库：把作者落到 book.authors，并顺手把同 md5 的重复行收敛成一行。
-- 统计库里本插件的书靠 md5 = "fanqie-<book_id>" 标识（见 stats.lua）。
function M.backfill_stats_db(book_id, author)
    if not is_str(book_id) or not is_str(author) or author == "" then return false end
    if author == "N/A" then return false end   -- 占位名不值得写库，也没法收敛
    local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq3 or not SQ3 then return false end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds or type(DataStorage) ~= "table" then return false end
    local ok_path, dir = pcall(DataStorage.getSettingsDir, DataStorage)
    if not ok_path or not is_str(dir) then return false end
    local ok_db, db = pcall(SQ3.open, dir .. "/statistics.sqlite3")
    if not ok_db or not db then return false end
    local md5 = "fanqie-" .. tostring(book_id)
    local ok, res = pcall(function()
        db:exec("PRAGMA busy_timeout=5000;")
        db:exec("BEGIN IMMEDIATE;")
        local r = merge_identity_rows(db, md5, author)
        db:exec("COMMIT;")
        return r
    end)
    if not ok then
        pcall(function() db:exec("ROLLBACK;") end)
        log_warn("[book_meta] 统计库身份合并失败:", tostring(res))
    else
        log_debug("[book_meta] 统计库身份:", tostring(book_id), tostring(res))
    end
    pcall(db.close, db)
    return ok and true or false
end

-- 确保某本书的作者已解析：
--   有缓存 → 直接回填统计库并回调；
--   无缓存 → 后台异步抓取，成功后落盘 + 回填 + 回调。
-- 绝不同步阻塞阅读路径。
function M.ensure(settings, book_id, on_done)
    if not settings or not is_str(book_id) or book_id == "" then return nil end

    local cached = M.get_author(settings, book_id)
    if cached then
        M.backfill_stats_db(book_id, cached)
        if on_done then pcall(on_done, cached) end
        return cached
    end
    if M.is_cached(settings, book_id) then
        -- 之前抓过但确实没有作者：不再重复请求
        return nil
    end

    local ok_Async, Async = pcall(require, "fanqie.async")
    if not ok_Async or type(Async) ~= "table" or not Async.run then
        return nil
    end

    Async.run(function()
        local author, status, err = M.fetch_author(settings, book_id)
        -- 单个返回值（Async.run 只透传一个返回值）
        return { author = author, status = status, err = err }
    end, function(ok, result)
        if not ok or type(result) ~= "table" then
            -- 子进程异常/超时：属于非确定性失败，不落盘，下次打开还会重试
            log_debug("[book_meta] 作者抓取子进程异常，未缓存:", tostring(book_id))
            return
        end
        local status = result.status
        if status == "ok" and is_str(result.author) and result.author ~= "" then
            M.save(settings, book_id, result.author, true)
            M.backfill_stats_db(book_id, result.author)
            log_debug("[book_meta] 作者已解析:", tostring(book_id), result.author)
            if on_done then pcall(on_done, result.author) end
        elseif status == "empty" then
            -- 页面正常返回但确实没有作者：记 tried，避免每次打开都请求
            M.save(settings, book_id, "", true)
        else
            -- "error" 或未知状态：不写缓存，留给下次打开重试
            log_debug("[book_meta] 作者抓取失败，未缓存，下次重试:",
                tostring(book_id), tostring(result.err))
        end
    end, { poll_interval = 0.3, timeout = 90 })
    return nil
end

return M
