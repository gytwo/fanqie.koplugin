-- 封面缓存治理：文件名规则、存在性查找、新鲜度、统计、清理。
--
-- 历史问题：
--   ① 文件名用书名（两本同名书共用一个 .jpg，后下的覆盖前一本）；
--   ② 只写不清：移出书架的书、换过的封面永远留在 covers 目录；
--   ③ 没有任何统计，用户无法知道占了多少空间。
--
-- 命名改为 book_id.jpg 后，旧缓存（书名.jpg）仍能被 find() 找到并使用，
-- 不强制迁移——首次重新下载某本书时自然落到新名字，老的慢慢变成孤儿，
-- 由 prune/maybe_auto_prune 收走。

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
local ok_Log, Log = pcall(require, "fanqie.logger")

local M = {}

M.SUFFIX = ".jpg"
M.FRESH_DAYS = 7                        -- 缓存新鲜期
M.PRUNE_DAYS = 30                       -- 自动清理只删「超过这么久没被写过」的
M.AUTO_PRUNE_BYTES = 200 * 1024 * 1024  -- 目录超过 200MB 才考虑自动清理

local function fs()
    if ok_lfs and lfs then return lfs end
    return nil
end

local function sanitize(name)
    return (tostring(name or ""):gsub("[/\\:%*%?\"<>|]", "_"))
end

-- 父目录不存在时按需创建（main.lua 里原来调 H.make_dir，这里自带一份，
-- 免得调用方每次都要先 require helper）。
local function ensure_dir(path)
    if type(path) ~= "string" or path == "" then return end
    local L = fs()
    if L and L.attributes then
        if not L.attributes(path, "mode") then
            pcall(L.mkdir, path)
        end
        return
    end
    -- 没有 lfs：交给第一次写入的 io.open 去失败
end

--- 封面目录：<下载目录>/covers
function M.dir(settings)
    local base = ""
    if settings then
        local ok, d = pcall(function() return settings:get_download_dir() end)
        if ok and type(d) == "string" then
            base = d
        elseif type(settings) == "table" then
            local ok2, d2 = pcall(function() return settings:get("cache_dir") end)
            if ok2 and type(d2) == "string" then base = d2 end
        end
    end
    if base == "" then base = "./fanqie_cache" end
    return base .. "/covers"
end

function M.file_exists(path)
    if type(path) ~= "string" or path == "" then return false end
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

--- 新命名：<book_id>.jpg；没有 book_id 时退回书名
function M.filename(book)
    if type(book) ~= "table" then return nil end
    local bid = book.book_id or book.bookId
    if bid ~= nil and tostring(bid) ~= "" then
        return sanitize(bid) .. M.SUFFIX
    end
    if type(book.title) == "string" and book.title ~= "" then
        return sanitize(book.title) .. M.SUFFIX
    end
    return nil
end

--- 旧命名：<书名>.jpg（只用于兼容已下载的旧缓存）
function M.legacy_filename(book)
    if type(book) ~= "table" or type(book.title) ~= "string" or book.title == "" then
        return nil
    end
    return sanitize(book.title) .. M.SUFFIX
end

--- 写新封面时的目标路径
function M.path(settings, book)
    local name = M.filename(book)
    if not name then return nil end
    local dir = M.dir(settings)
    ensure_dir(dir)
    return dir .. "/" .. name
end

--- 找已存在的封面文件：先新名，再旧名。
-- 返回 nil 表示没有缓存（调用方去下载）。
function M.find(settings, book)
    local dir = M.dir(settings)
    local name = M.filename(book)
    if not name then return nil end
    local path = dir .. "/" .. name
    if M.file_exists(path) then return path end
    local legacy = M.legacy_filename(book)
    if legacy and legacy ~= name then
        local old_path = dir .. "/" .. legacy
        if M.file_exists(old_path) then return old_path end
    end
    return nil
end

--- 这张缓存还新鲜吗？取不到 mtime 时按「新鲜」处理，
-- 避免因为文件系统能力缺失而反复重下。
function M.is_fresh(path, days)
    if not M.file_exists(path) then return false end
    local L = fs()
    if not L or type(L.attributes) ~= "function" then return true end
    local ok, mtime = pcall(L.attributes, path, "modification")
    if not ok or type(mtime) ~= "number" then return true end
    return (os.time() - mtime) < (tonumber(days) or M.FRESH_DAYS) * 86400
end

--- 目录占用：{ count = 图片数, bytes = 总字节 }
function M.stats(dir)
    local out = { count = 0, bytes = 0 }
    local L = fs()
    if not L or type(L.dir) ~= "function" then return out end
    local ok, iter, dir_obj = pcall(L.dir, dir)
    if not ok or type(iter) ~= "function" then return out end
    for name in iter, dir_obj do
        if type(name) == "string" and name:lower():match("%.jpg$") then
            local path = dir .. "/" .. name
            local ok_a, size = pcall(L.attributes, path, "size")
            if ok_a and type(size) == "number" then
                out.count = out.count + 1
                out.bytes = out.bytes + size
            end
        end
    end
    return out
end

--- 删除超过 days 天没被写过的封面。
-- @return deleted, freed_bytes
function M.prune(dir, days)
    local deleted, freed = 0, 0
    local L = fs()
    if not L or type(L.dir) ~= "function" then return deleted, freed end
    local cutoff = os.time() - (tonumber(days) or M.PRUNE_DAYS) * 86400
    local ok, iter, dir_obj = pcall(L.dir, dir)
    if not ok or type(iter) ~= "function" then return deleted, freed end
    for name in iter, dir_obj do
        if type(name) == "string" and name:lower():match("%.jpg$") then
            local path = dir .. "/" .. name
            local ok_m, mtime = pcall(L.attributes, path, "modification")
            if ok_m and type(mtime) == "number" and mtime < cutoff then
                local ok_s, size = pcall(L.attributes, path, "size")
                if os.remove(path) then
                    deleted = deleted + 1
                    if ok_s and type(size) == "number" then freed = freed + size end
                end
            end
        end
    end
    if deleted > 0 and ok_Log and Log then
        Log.info("[cover_cache] 清理 %d 张过期封面，释放 %d 字节", deleted, freed)
    end
    return deleted, freed
end

--- 保守的自动清理：只有目录超过阈值才动手，且只删超期文件。
-- 返回 deleted, freed；没触发时返回 0, 0。
function M.maybe_auto_prune(settings)
    local dir = M.dir(settings)
    local st = M.stats(dir)
    if st.bytes < M.AUTO_PRUNE_BYTES then
        return 0, 0
    end
    if ok_Log and Log then
        Log.info("[cover_cache] 目录 %d 字节 / %d 张，开始清理超期封面",
            st.bytes, st.count)
    end
    return M.prune(dir, M.PRUNE_DAYS)
end

return M
