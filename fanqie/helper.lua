local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local M = {}

M.is_str = function(s)
    return type(s) == "string"
end

M.is_tbl = function(t)
    return type(t) == "table"
end

M.trim = function(s)
    if not s then return "" end
    return s:match("^%s*(.-)%s*$") or ""
end

-- 剥离行首 Unicode 空白。Lua 的 %s 只认 ASCII，不匹配全角空格 U+3000 / NBSP U+00A0；
-- 中文源常在段首插 2 个 U+3000，与 CSS text-indent 叠加会变成 4 字符缩进。
-- 逐行处理，不改行尾与换行结构（行数不变，段评 pid 对齐不受影响）。
M.BLANK_PREFIXES = {
    "\9", "\11", "\12", "\13", "\32",                                     -- \t \v \f \r 空格
    "\194\160",                                                            -- U+00A0 不换行空格
    "\226\128\128", "\226\128\129", "\226\128\130", "\226\128\131",        -- U+2000-2003
    "\226\128\132", "\226\128\133", "\226\128\134", "\226\128\135",        -- U+2004-2007
    "\226\128\136", "\226\128\137", "\226\128\138",                        -- U+2008-200A
    "\226\128\175",                                                        -- U+202F 窄不换行空格
    "\226\129\159",                                                        -- U+205F 中等数学空格
    "\227\128\128",                                                        -- U+3000 全角空格
}

M.strip_leading_blank = function(s)
    if type(s) ~= "string" or s == "" then return s end
    -- 快速路径：正文里一个可疑字符都没有时直接返回，不做逐行扫描
    local prefixes = M.BLANK_PREFIXES
    local has = false
    for _, p in ipairs(prefixes) do
        if s:find(p, 1, true) then has = true break end
    end
    if not has then return s end
    -- [^\n]* 逐行匹配（不吞换行符），保证行数与换行分布逐字节不变
    return (s:gsub("[^\n]*", function(line)
        if line == "" then return line end
        local i = 1
        while true do
            local matched = false
            for _, p in ipairs(prefixes) do
                if line:sub(i, i + #p - 1) == p then
                    i = i + #p
                    matched = true
                    break
                end
            end
            if not matched then break end
        end
        if i == 1 then return line end
        return line:sub(i)
    end))
end

-- UTF-8 安全的字节截断：用于日志/错误信息，避免把多字节汉字切成半个
-- （残缺字节写进日志会显示乱码，也让后续按 UTF-8 解析的工具报错）。
M.truncate_utf8 = function(s, n)
    s = tostring(s or "")
    if n <= 0 then return "" end
    if #s <= n then return s end
    local t = s:sub(1, n)
    -- 1) 回退掉结尾的 UTF-8 续字节（0x80~0xBF）
    while #t > 0 do
        local b = t:byte(#t)
        if b >= 0x80 and b < 0xC0 then
            t = t:sub(1, #t - 1)
        else
            break
        end
    end
    -- 2) 若结尾停在多字节字符的首字节上，说明该字符不完整，一并去掉
    if #t > 0 then
        local b = t:byte(#t)
        if b >= 0xC0 then
            t = t:sub(1, #t - 1)
        end
    end
    return t
end

M.join_path = function(...)
    local args = {...}
    local path = ""
    for _, p in ipairs(args) do
        if p then
            path = path .. "/" .. p
        end
    end
    return path:gsub("/+", "/")
end

M.make_dir = function(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    util.makePath(path)
    return lfs.attributes(path, "mode") == "directory"
end

M.file_exists = function(path)
    if not M.is_str(path) then return false end
    return lfs.attributes(path, "mode") == "file"
end

M.dir_exists = function(path)
    if not M.is_str(path) then return false end
    return lfs.attributes(path, "mode") == "directory"
end

M.delete_file = function(path)
    if M.file_exists(path) then
        return os.remove(path)
    end
    return true
end

-- 原子写：先写同目录下的 .tmp，再 rename 覆盖目标。
-- 目的：Async 子进程写 para_comments_*.lua / para_records_*.lua 时，
-- 父进程可能同时在 dofile 读同一个文件；非原子写会让父进程读到半截
-- Lua（dofile 失败 → 段评"数据无效" → 触发重试链路）。
-- 同目录 rename 在 POSIX / FAT32 / exFAT 上均为原子操作。
M.write_file = function(path, data)
    local dir = path:match("^(.*)/[^/]+$")
    if dir then
        M.make_dir(dir)
    end
    local tmp = path .. ".tmp"
    local file, err = io.open(tmp, "wb")
    if not file then
        error(err)
    end
    file:write(data)
    file:close()
    os.remove(path)
    local ok, rerr = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        error(rerr)
    end
end

M.delete_dir = function(path)
    if not M.dir_exists(path) then return true end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local full_path = M.join_path(path, entry)
            local mode = lfs.attributes(full_path, "mode")
            if mode == "directory" then
                M.delete_dir(full_path)
            else
                os.remove(full_path)
            end
        end
    end
    return lfs.rmdir(path)
end

M.split = function(str, sep)
    local result = {}
    local pattern = string.format("([^%s]+)", sep)
    for part in string.gmatch(str, pattern) do
        table.insert(result, part)
    end
    return result
end

M.url_encode = function(str)
    if not str then return "" end
    str = tostring(str)
    return str:gsub("[^a-zA-Z0-9%-_.~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

return M
