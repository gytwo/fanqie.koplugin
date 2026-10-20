--[[--
番茄 App reading 协议拉正文（同步版）：设备身份 → registerkey → batch_full → 解密。
在子进程 work_func 内执行（与其它书源一致），不阻塞 UI。

@module fanqie.reading

⚠️ local 函数必须先定义后调用（`now_ms` 曾置于文件末尾，导致整条链路报 nil）。
--]]

local Crypto = require("fanqie.reading.crypto")
local Device = require("fanqie.reading.device")
local Sign = require("fanqie.reading.sign")

local Reading = {}

local HOST = Crypto.HOST
-- 超时分级：换密钥（registerkey）可以多等一会儿；拉正文要快，失败就立刻换源。
local TIMEOUT_CONTENT = 15
local TIMEOUT_REGISTER = 30

-- 高精度毫秒时间戳（X-Ss-Req-Ticket 用）：os.time() 只有秒级，同秒请求的 ticket 会撞。
-- 🔴 必须定义在 signed_call 之前，否则被解析成全局 nil。
local ok_socket, socket = pcall(require, "socket")
local function now_ms()
    if ok_socket and socket and socket.gettime then
        return math.floor(socket.gettime() * 1000)
    end
    return os.time() * 1000 + math.random(0, 999)
end

--- 带四神签名的 reading API 同步请求。
---@param client table 本地 HTTP 客户端
---@param name string 接口名（错误文案前缀）
---@param device table
---@param path string
---@param build_query fun(device: table, ts_ms: number): table
---@param build_body (fun(client: table, device: table): string)|nil 非 nil 时 POST
---@param opts table|nil { quote_bigints = bool, timeout = number } 见 Reading.quote_bigints
---@return table|nil data, string|nil err
local function signed_call(client, name, device, path, build_query, build_body, opts)
    local ts_ms = now_ms()
    local qs = Crypto.encode_query(build_query(device, ts_ms))
    local body = build_body and build_body(client, device)
    local headers = Crypto.build_unsigned_headers(device, ts_ms)
    if body then
        headers["Content-Type"] = "application/json"
    end
    for k, v in pairs(Sign.sign_headers(qs, device.device_id, {
        khronos = math.floor(ts_ms / 1000),
        version_name = device.version_name,
        device_type = device.device_type,
        os_version = device.os_version,
    })) do
        headers[k] = v
    end
    headers["X-Ss-Req-Ticket"] = tostring(ts_ms)

    local url = "https://" .. HOST .. path .. "?" .. qs
    local text, code = client:request({
        url = url,
        method = body and "POST" or "GET",
        headers = headers,
        body = body,
        timeout = (opts and tonumber(opts.timeout)) or TIMEOUT_CONTENT,
    })
    if not code then
        return nil, name .. " 请求失败"
    end
    if code < 200 or code >= 300 then
        return nil, name .. " HTTP " .. tostring(code)
    end
    if not text or text == "" then
        return nil, name .. " 空响应（设备身份可能被风控）"
    end
    if opts and opts.quote_bigints then
        text = Reading.quote_bigints(text)
    end
    local ok, data = pcall(function() return client:json_decode(text) end)
    if not ok or type(data) ~= "table" then
        return nil, name .. " 响应无效"
    end
    if tonumber(data.code) ~= 0 or type(data.data) ~= "table" then
        return nil, name .. " 失败: " .. tostring(data.message or data.msg or data.code)
    end
    return data
end

--[[--
给 JSON 里的超长整数补引号，避免解码成 double 丢精度。

⚠️ 番茄 comment_id 是 19 位，超过 double 的 53 位尾数，rapidjson 解码后末几位被抹平：
reply/list 带着失真的 ID 请求 → 200 + 空列表 → 前端显示「回复加载失败」，
症状与签名不合规一模一样。只处理裸数字，且只挑 ≥16 位的值（15 位以内仍精确）。
--]]
local BIGINT_FIELDS = {
    "comment_id", "reply_id", "reply_to_reply_id", "reply_to_comment_id",
    "user_id", "reply_to_user_id", "book_id", "chapter_id", "item_id",
}

---@param text string 原始 JSON 文本
---@return string 处理后的 JSON 文本
function Reading.quote_bigints(text)
    if type(text) ~= "string" or text == "" then
        return text
    end
    for _i, key in ipairs(BIGINT_FIELDS) do
        -- ≥16 位（2^53 是 16 位）才需要保护；15 位以内仍在 double 精确范围内
        local pat = '"' .. key .. '"%s*:%s*(%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d+)'
        text = text:gsub(pat, function(v)
            if #v < 16 then
                return nil          -- 不够长：保留原匹配（返回 nil 即不替换）
            end
            return '"' .. key .. '":"' .. v .. '"'
        end)
    end
    return text
end

-- 供 fanqie/reading/comments.lua（段评）等兄弟模块复用同一签名请求链路。
Reading.signed_call = signed_call

--- registerkey：换取章节内容密钥 v1_key（36 字节 hex）。
---@param client table
---@param device table
---@return string|nil v1_key, string|nil err
local function register_key(client, device)
    local data, err = signed_call(client, "registerkey", device,
        Crypto.REGISTERKEY_PATH, Crypto.build_common_query,
        function(c, d)
            return c:json_encode({
                content = Crypto.build_register_content(d.device_id, 0),
                keyver = 1,
            })
        end, { timeout = TIMEOUT_REGISTER })
    if not data then
        return nil, err
    end
    if not data.data.key then
        return nil, "registerkey 失败: " .. tostring(data.message or data.msg or data.code)
    end
    local ok, v1 = pcall(Crypto.decrypt_server_key, data.data.key)
    if not ok or not v1 then
        return nil, "解密 v1_key 失败"
    end
    return v1
end

--- batch_full：拉单章密文并解密为明文。
---@param client table
---@param device table
---@param book_id string
---@param item_id string
---@param v1_key string
---@return table|nil row, string|nil err
local function batch_full(client, device, book_id, item_id, v1_key)
    local function query(d, ts_ms)
        return Crypto.build_batch_full_query(d, book_id, { item_id }, ts_ms)
    end
    local data, err = signed_call(client, "batch_full", device, Crypto.BATCH_FULL_PATH, query, nil,
        { timeout = TIMEOUT_CONTENT })
    if not data then
        return nil, err
    end
    local item = data.data[item_id] or data.data[tostring(item_id)]
    if type(item) == "table" and item[1] then
        item = item[1]
    end
    if type(item) ~= "table" then
        return nil, "batch_full 无章节数据"
    end
    local ok, text = pcall(Crypto.decode_chapter_item, item, v1_key)
    if not ok then
        return nil, "章节解密失败: " .. tostring(text)
    end
    if type(text) ~= "string" or not text:match("%S") then
        return nil, "章节正文为空"
    end
    return {
        content = text,
        title = tostring(item.title or ""),
        author = tostring(item.author or item.authorName or ""),
        source = "official_reading",
    }
end

-- v1_key 缓存（与 kindle-forge get_v1_key 对齐）：
-- 内存 → settings 落盘（绑定 device_id，7 天软过期）→ 重新 registerkey。
-- v1_key 不随账号变化、长期有效，避免每章多一次签名 HTTPS 往返。
local _V1KEY_MEM = nil
local V1KEY_SOFT_TTL = 7 * 86400 -- 7 天软过期，防服务端换密钥

---@param client table
---@param settings table
---@param force_refresh boolean|nil 强制重新 registerkey
---@return string|nil v1_key, string|nil err
local function get_v1_key(client, settings, force_refresh)
    if not force_refresh then
        if _V1KEY_MEM then
            return _V1KEY_MEM
        end
        local device = Device.get(settings)
        if device then
            local saved = settings:get("reading_v1_key", nil)
            if type(saved) == "table" and saved.key and saved.device_id == device.device_id
                and (os.time() - (tonumber(saved.ts) or 0)) < V1KEY_SOFT_TTL then
                _V1KEY_MEM = tostring(saved.key)
                return _V1KEY_MEM
            end
        end
    end
    local device, derr = Device.ensure(client, settings)
    if not device then
        return nil, derr or "设备身份注册失败"
    end
    local v1, kerr = register_key(client, device)
    if not v1 then
        return nil, kerr
    end
    _V1KEY_MEM = v1
    settings:set("reading_v1_key", { key = v1, device_id = device.device_id, ts = os.time() })
    settings:flush()
    return v1
end

--- 拉取单章全文（番茄官方 App reading 协议，同步）。
---@param client table 本地 HTTP 客户端（Client 实例）
---@param settings table
---@param book_id string
---@param item_id string
---@return table|nil data {content, title, author, source}, string|nil err
function Reading.fetch(client, settings, book_id, item_id)
    book_id, item_id = tostring(book_id or ""), tostring(item_id or "")
    if not book_id:match("^%d+$") or not item_id:match("^%d+$") then
        return nil, "章节 ID 无效"
    end
    local device, derr = Device.ensure(client, settings)
    if not device then
        return nil, derr or "设备身份注册失败"
    end
    local v1_key, kerr = get_v1_key(client, settings)
    if not v1_key then
        return nil, kerr or "registerkey 失败"
    end
    local row, err = batch_full(client, device, book_id, item_id, v1_key)
    if not row and err and (err:find("解密失败", 1, true) or err:find("正文为空", 1, true)
        or err:find("无章节数据", 1, true)) then
        -- 解密类失败通常是缓存 key 已失效：强制刷新后重试一次
        v1_key, kerr = get_v1_key(client, settings, true)
        if not v1_key then
            return nil, kerr or "registerkey 失败"
        end
        row, err = batch_full(client, device, book_id, item_id, v1_key)
    end
    return row, err
end

return Reading
