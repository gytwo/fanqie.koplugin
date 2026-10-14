local util = require("util")
local function rshift(n, k)
    return math.floor(n / (2 ^ k))
end

local function lshift(n, k)
    return math.floor(n * (2 ^ k))
end

local FanQie = require("fanqie.fanqie")

local ok_logger, logger = pcall(require, "fanqie.logger")
if not ok_logger then
    logger = nil
end
local LOG_MODULE = "[FanQie]"

local ok_socket_perf, socket_perf = pcall(require, "socket")
local function now_ms()
    if ok_socket_perf and socket_perf and socket_perf.gettime then
        return socket_perf.gettime() * 1000
    end
    return os.clock() * 1000
end

local H = require("fanqie.helper")

local Content = {}

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local b64decode = {}
for i = 1, 64 do
    b64decode[b64chars:sub(i, i)] = i - 1
end
b64decode["="] = 0

local function base64_encode(data)
    local len = #data
    local out_len = math.floor((len + 2) / 3) * 4
    local out = {}
    out[out_len] = ""
    local idx = 1
    for i = 1, len, 3 do
        local a = data:byte(i)
        local b = i + 1 <= len and data:byte(i + 1) or 0
        local c = i + 2 <= len and data:byte(i + 2) or 0
        local n = a * 65536 + b * 256 + c
        out[idx] = b64chars:sub(rshift(n, 18) % 64 + 1, rshift(n, 18) % 64 + 1)
        out[idx + 1] = b64chars:sub(rshift(n, 12) % 64 + 1, rshift(n, 12) % 64 + 1)
        if i + 1 <= len then
            out[idx + 2] = b64chars:sub(rshift(n, 6) % 64 + 1, rshift(n, 6) % 64 + 1)
        else
            out[idx + 2] = "="
        end
        if i + 2 <= len then
            out[idx + 3] = b64chars:sub(n % 64 + 1, n % 64 + 1)
        else
            out[idx + 3] = "="
        end
        idx = idx + 4
    end
    return table.concat(out)
end

local function base64_decode(data)
    if not data then return nil end
    data = data:gsub("[^%w%+%/=]", "")
    if #data == 0 then return nil end
    local result = {}
    local idx = 1
    for i = 1, #data, 4 do
        local a = b64decode[data:sub(i, i)] or 0
        local b = b64decode[data:sub(i + 1, i + 1)] or 0
        local c_char = data:sub(i + 2, i + 2)
        local d_char = data:sub(i + 3, i + 3)
        local n = lshift(a, 18) + lshift(b, 12)
        if c_char and c_char ~= "=" then
            local c_val = b64decode[c_char] or 0
            n = n + lshift(c_val, 6)
            if d_char and d_char ~= "=" then
                local d_val = b64decode[d_char] or 0
                n = n + d_val
                result[idx] = string.char(rshift(n, 16) % 256)
                result[idx + 1] = string.char(rshift(n, 8) % 256)
                result[idx + 2] = string.char(n % 256)
                idx = idx + 3
            else
                result[idx] = string.char(rshift(n, 16) % 256)
                result[idx + 1] = string.char(rshift(n, 8) % 256)
                idx = idx + 2
            end
        else
            result[idx] = string.char(rshift(n, 16) % 256)
            idx = idx + 1
        end
    end
    return table.concat(result)
end

local function fix_svg_for_inkscreen(svg_str)
    if not svg_str or svg_str:find("<svg", 1, true) ~= 1 then
        return svg_str
    end
    svg_str = svg_str:gsub("rgba%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*,%s*([%.%d]+)%s*%)", function(r, g, b, a)
        local alpha = tonumber(a) or 1.0
        if alpha < 0.15 then
            return "#FFFFFF"
        elseif alpha < 0.3 then
            return "#EEEEEE"
        elseif alpha < 0.5 then
            return "#DDDDDD"
        elseif alpha < 0.7 then
            return "#BBBBBB"
        else
            return "#999999"
        end
    end)
    svg_str = svg_str:gsub('opacity%s*=%s*"[%.%d]+"', "")
    svg_str = svg_str:gsub("opacity%s*=%s*'[%.%d]+'", "")
    svg_str = svg_str:gsub('stroke%-opacity%s*=%s*"[%.%d]+"', "")
    svg_str = svg_str:gsub("stroke%-opacity%s*=%s*'[%.%d]+'", "")
    svg_str = svg_str:gsub('fill%-opacity%s*=%s*"[%.%d]+"', "")
    svg_str = svg_str:gsub("fill%-opacity%s*=%s*'[%.%d]+'", "")
    svg_str = svg_str:gsub('fill%s*=%s*"#F06260"', 'fill="#444444"')
    svg_str = svg_str:gsub("fill%s*=%s*'#F06260'", "fill='#444444'")
    svg_str = svg_str:gsub('fill%s*=%s*"#FFFFFF"', 'fill="#333333"')
    svg_str = svg_str:gsub("fill%s*=%s*'#FFFFFF'", "fill='#333333'")
    svg_str = svg_str:gsub("<svg([^>]*)>", function(attrs)
        if not attrs:find('fill=', 1, true) then
            return "<svg" .. attrs .. ' fill="#F5F5F5">'
        end
        return "<svg" .. attrs .. ">"
    end, 1)
    return svg_str
end

local function fix_svg_imgs_in_text(text)
    local result = text:gsub('(<[iI][mM][gG][^>]*src%s*=%s*")(data:image/svg%+xml;base64,)([^"]*)("[^>]*>)',
        function(prefix, prefix2, b64_data, suffix)
            local svg_decoded = base64_decode(b64_data)
            if svg_decoded and svg_decoded:find("<svg", 1, true) == 1 then
                local fixed_svg = fix_svg_for_inkscreen(svg_decoded)
                local fixed_b64 = base64_encode(fixed_svg)
                return prefix .. prefix2 .. fixed_b64 .. suffix
            end
            return prefix .. prefix2 .. b64_data .. suffix
        end)
    return result
end

local function basename_safe(value)
    value = tostring(value or "")
        :gsub("[/\\:%*%?\"<>|]", "_")
        :gsub("%c", "")
        :gsub("^%s+", ""):gsub("%s+$", "")
        :gsub("^%.+", ""):gsub("%.+$", "")
    if value == "" then
        value = "fanqie"
    end
    local chars = require("util").splitToChars(value)
    if #chars > 10 then
        value = table.concat(chars, "", 1, 10)
    end
    return value
end

local function id_safe(value)
    value = tostring(value or ""):gsub("[/\\:%*%?\"<>|]", "_")
    if value == "" then value = "fanqie" end
    return value
end

local _book_dir_cache = {}

function Content.book_cache_dir(settings, book_id)
    local base = settings.cache_dir
    local id = id_safe(book_id)

    if _book_dir_cache[id] then
        return _book_dir_cache[id]
    end

    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(base, "mode") == "directory" then
        for entry in lfs.dir(base) do
            if entry ~= "." and entry ~= ".." then
                if entry == id or entry:sub(-(#id + 1)) == "-" .. id then
                    local dir = base .. "/" .. entry
                    _book_dir_cache[id] = dir
                    return dir
                end
            end
        end
    end

    local dir = base .. "/" .. id
    _book_dir_cache[id] = dir
    return dir
end

function Content.save_cache_index(settings, book_id, cached_chapters)
    local dir = Content.book_cache_dir(settings, book_id)
    H.make_dir(dir)
    local index_path = H.join_path(dir, "cache_index.lua")
    local parts = { "return {" }
    for item_id, path in pairs(cached_chapters or {}) do
        if H.is_str(item_id) then
            table.insert(parts, string.format("  [%q] = %q,", item_id, path))
        end
    end
    table.insert(parts, "}")
    H.write_file(index_path, table.concat(parts, "\n"))

    local ok_state, _state = pcall(require, "fanqie.state")
    if ok_state and _state and _state.setChapterIndexCache then
        _state.setChapterIndexCache(book_id, cached_chapters)
    end
end

function Content.load_cache_index(settings, book_id)
    local ok_state, _state = pcall(require, "fanqie.state")
    if ok_state and _state then
        local cached = _state.getChapterIndexCache(book_id)
        if cached then
            return cached
        end
    end

    local dir = Content.book_cache_dir(settings, book_id)
    local index_path = H.join_path(dir, "cache_index.lua")
    if not H.file_exists(index_path) then
        return {}
    end

    local lfs = require("libs/libkoreader-lfs")
    local attr = lfs.attributes(index_path)
    if attr then
        local now = os.time()
        local mtime = attr.modification
        if mtime and (now - mtime) > 86400 then
            return {}
        end
    end

    local ok, index = pcall(dofile, index_path)
    if not ok or not H.is_tbl(index) then
        return {}
    end

    if ok_state and _state then
        _state.setChapterIndexCache(book_id, index)
    end

    return index
end

function Content.verify_cache_path(path)
    if not path then return false end
    return H.file_exists(path)
end

function Content.save_catalog_cache(settings, book_id, chapters, title, cover)
    local id = id_safe(book_id)
    local dir = Content.book_cache_dir(settings, book_id)

    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" and title and title ~= "" then
        dir = settings.cache_dir .. "/" .. basename_safe(title) .. "-" .. id
    end
    H.make_dir(dir)
    _book_dir_cache[id] = dir

    if cover and cover ~= "" then
        local cover_path = dir .. "/cover.jpg"
        if not H.file_exists(cover_path) then
            local ok, data = pcall(function()
                return require("fanqie.client"):new(settings):get_binary(cover)
            end)
            if ok and data and #data > 0 then
                local ext = Content.detect_image_type(data) or ".jpg"
                H.write_file(dir .. "/cover" .. ext, data)
            else
                if logger then logger.warn("cover download failed:", cover) end
            end
        end
    end

    local path = H.join_path(dir, "catalog_cache.lua")
    local parts = { "return {" }
    for i, ch in ipairs(chapters or {}) do
        local item_id = tostring(ch.itemId or ch.item_id or "")
        local t = tostring(ch.title or "")
        t = t:gsub("\\", "\\\\"):gsub('"', '\\"')
        table.insert(parts, string.format(
            '  { itemId = "%s", title = "%s" },', item_id, t))
    end
    table.insert(parts, "}")
    H.write_file(path, table.concat(parts, "\n"))
end

function Content.load_catalog_cache(settings, book_id)
    local ok_state, _state = pcall(require, "fanqie.state")
    if ok_state and _state and _state.getDirectoryCache then
        local mem = _state.getDirectoryCache(book_id)
        if mem and #mem > 0 then
            return mem
        end
    end

    local dir = Content.book_cache_dir(settings, book_id)
    local path = H.join_path(dir, "catalog_cache.lua")
    if not H.file_exists(path) then
        return nil
    end
    local ok, catalog = pcall(dofile, path)
    if not ok or not H.is_tbl(catalog) then
        return nil
    end

    if ok_state and _state and _state.setDirectoryCache and catalog and #catalog > 0 then
        _state.setDirectoryCache(book_id, catalog)
    end
    return catalog
end

function Content.clear_catalog_cache(settings, book_id)
    local ok_state, _state = pcall(require, "fanqie.state")
    if ok_state and _state and _state.invalidateDirectoryCache then
        _state.invalidateDirectoryCache(book_id)
    end
    local dir = Content.book_cache_dir(settings, book_id)
    local path = H.join_path(dir, "catalog_cache.lua")
    if H.file_exists(path) then
        os.remove(path)
    end
end

function Content.find_chapter_file(settings, book_id, item_id)
    local dir = Content.book_cache_dir(settings, book_id)
    if not dir then return nil end
    local expected_path = dir .. "/chapter_" .. tostring(item_id) .. ".html"
    if H.file_exists(expected_path) then
        return expected_path
    end
    return nil
end

function Content.book_resolved_dir(settings, book_id, book)
    if book and H.is_str(book.cache_dir) and book.cache_dir ~= "" then
        return book.cache_dir
    end
    local function dirname(path)
        if H.is_str(path) then
            return path:match("^(.*)/[^/]+$")
        end
    end
    local dir = book and dirname(book.cached_file)
    if not dir and book and H.is_tbl(book.cached_chapters) then
        for _i, chapter_path in pairs(book.cached_chapters) do
            dir = dirname(chapter_path)
            if dir then
                break
            end
        end
    end
    return dir or Content.book_cache_dir(settings, book_id)
end

local function filename_safe(value)
    value = tostring(value or ""):gsub("[%z%c/\\:%*%?\"<>|]", "_")
    value = H.trim(value)
    value = value:gsub("%s+", " ")
    if value == "" then
        value = "fanqie"
    end
    return value
end

local function utc_modified()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function media_type_for(data)
    if data:sub(1, 8) == "\137PNG\r\n\026\n" then
        return ".png", "image/png"
    elseif data:sub(1, 3) == "\255\216\255" then
        return ".jpg", "image/jpeg"
    elseif data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then
        return ".gif", "image/gif"
    elseif data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        return ".webp", "image/webp"
    end
    return ".bin", "application/octet-stream"
end

function Content.detect_image_type(data)
    if type(data) ~= "string" or #data < 12 then return nil end
    local ext, mt = media_type_for(data)
    if mt and mt:match("^image/") then
        return ext, mt
    end
    return nil
end

local function xml_escape(value)
    value = tostring(value or "")
    value = value:gsub("&", "&amp;")
    value = value:gsub("<", "&lt;")
    value = value:gsub(">", "&gt;")
    value = value:gsub("\"", "&quot;")
    return value
end

local function body_fragment(xhtml)
    xhtml = tostring(xhtml or "")
    xhtml = xhtml:gsub("<%?xml.-%?>", "")
    xhtml = xhtml:gsub("<!DOCTYPE.-%>", "")
    xhtml = xhtml:gsub("<!%[CDATA%[.-%]%]>", "")

    local body = xhtml:match("<body[^>]->([%s%S]--)</body>")
    if not body then
        body = xhtml:match("<body[^>]->(.*)")
    end
    if not body then
        body = xhtml
    end

    body = body:gsub("<script[^>]->[%s%S]-</script>", "")
    body = body:gsub("<style[^>]->[%s%S]-</style>", "")
    body = body:gsub("<header[^>]->[%s%S]-</header>", "")
    body = body:gsub("<nav[^>]->[%s%S]-</nav>", "")
    body = body:gsub("<!--[%s%S]--->", "")

    body = body:gsub("<br%s*/?>", "<br/>")
    body = body:gsub("<img([^>]-)/>", "<img%1>")

    return body
end

local PUA_CODE = { { 58344, 58715 }, { 58345, 58716 } }
local PUA_CHARSET = {
    { "D","在","主","特","家","军","然","表","场","4","要","只","v","和","?","6","别","还","g","现","儿","岁","?","?","此","象","月","3","出","战","工","相","o","男","直","失","世","F","都","平","文","什","V","O","将","真","T","那","当","?","会","立","些","u","是","十","张","学","气","大","爱","两","命","全","后","东","性","通","被","1","它","乐","接","而","感","车","山","公","了","常","以","何","可","话","先","p","i","叫","轻","M","士","w","着","变","尔","快","l","个","说","少","色","里","安","花","远","7","难","师","放","t","报","认","面","道","S","?","克","地","度","I","好","机","U","民","写","把","万","同","水","新","没","书","电","吃","像","斯","5","为","y","白","几","日","教","看","但","第","加","候","作","上","拉","住","有","法","r","事","应","位","利","你","声","身","国","问","马","女","他","Y","比","父","x","A","H","N","s","X","边","美","对","所","金","活","回","意","到","z","从","j","知","又","内","因","点","Q","三","定","8","R","b","正","或","夫","向","德","听","更","?","得","告","并","本","q","过","记","L","让","打","f","人","就","者","去","原","满","体","做","经","K","走","如","孩","c","G","给","使","物","?","最","笑","部","?","员","等","受","k","行","一","条","果","动","光","门","头","见","往","自","解","成","处","天","能","于","名","其","发","总","母","的","死","手","入","路","进","心","来","h","时","力","多","开","已","许","d","至","由","很","界","n","小","与","Z","想","代","么","分","生","口","再","妈","望","次","西","风","种","带","J","?","实","情","才","这","?","E","我","神","格","长","觉","间","年","眼","无","不","亲","关","结","0","友","信","下","却","重","己","老","2","音","字","m","呢","明","之","前","高","P","B","目","太","e","9","起","稜","她","也","W","用","方","子","英","每","理","便","四","数","期","中","C","外","样","a","海","们","任" },
    { "s","?","作","口","在","他","能","并","B","士","4","U","克","才","正","们","字","声","高","全","尔","活","者","动","其","主","报","多","望","放","h","w","次","年","?","中","3","特","于","十","入","要","男","同","G","面","分","方","K","什","再","教","本","己","结","1","等","世","N","?","说","g","u","期","Z","外","美","M","行","给","9","文","将","两","许","张","友","0","英","应","向","像","此","白","安","少","何","打","气","常","定","间","花","见","孩","它","直","风","数","使","道","第","水","已","女","山","解","d","P","的","通","关","性","叫","儿","L","妈","问","回","神","来","S","","四","望","前","国","些","O","v","l","A","心","平","自","无","军","光","代","是","好","却","c","得","种","就","意","先","立","z","子","过","Y","j","表","","么","所","接","了","名","金","受","J","满","眼","没","部","那","m","每","车","度","可","R","斯","经","现","门","明","V","如","走","命","y","6","E","战","很","上","f","月","西","7","长","夫","想","话","变","海","机","x","到","W","一","成","生","信","笑","但","父","开","内","东","马","日","小","而","后","带","以","三","几","为","认","X","死","员","目","位","之","学","远","人","音","呢","我","q","乐","象","重","对","个","被","别","F","也","书","稜","D","写","还","因","家","发","时","i","或","住","德","当","o","l","比","觉","然","吃","去","公","a","老","亲","情","体","太","b","万","C","电","理","?","失","力","更","拉","物","着","原","她","工","实","色","感","记","看","出","相","路","大","你","候","2","和","?","与","p","样","新","只","便","最","不","进","T","r","做","格","母","总","爱","身","师","轻","知","往","加","从","?","天","e","H","?","听","场","由","快","边","让","把","任","8","条","头","事","至","起","点","真","手","这","难","都","界","用","法","n","处","下","又","Q","告","地","5","k","t","岁","有","会","果","利","民" }
}

local function utf8_codepoint(str, i)
    local b1 = str:byte(i)
    if not b1 then return nil, i end
    if b1 < 0x80 then
        return b1, i + 1
    elseif b1 >= 0xC2 and b1 <= 0xDF then
        local b2 = str:byte(i + 1)
        if not b2 then return nil, i end
        return (b1 - 0xC0) * 0x40 + (b2 - 0x80), i + 2
    elseif b1 >= 0xE0 and b1 <= 0xEF then
        local b2 = str:byte(i + 1)
        local b3 = str:byte(i + 2)
        if not b2 or not b3 then return nil, i end
        return (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80), i + 3
    elseif b1 >= 0xF0 and b1 <= 0xF4 then
        local b2 = str:byte(i + 1)
        local b3 = str:byte(i + 2)
        local b4 = str:byte(i + 3)
        if not b2 or not b3 or not b4 then return nil, i end
        return (b1 - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000 + (b3 - 0x80) * 0x40 + (b4 - 0x80), i + 4
    end
    return nil, i
end

function Content.decode_pua_content(content)
    if not content then return "" end
    local result = {}
    local i = 1
    while i <= #content do
        local code, next_i = utf8_codepoint(content, i)
        if not code then
            table.insert(result, content:sub(i, i))
            i = i + 1
            goto continue
        end
        local decoded = false
        for mode = 1, 2 do
            local range = PUA_CODE[mode]
            if code >= range[1] and code <= range[2] then
                local bias = code - range[1]
                local charset = PUA_CHARSET[mode]
                if bias + 1 <= #charset and charset[bias + 1] ~= "?" then
                    table.insert(result, charset[bias + 1])
                    decoded = true
                end
                break
            end
        end
        if not decoded then
            table.insert(result, content:sub(i, next_i - 1))
        end
        i = next_i
        ::continue::
    end
    return table.concat(result)
end

function Content.strip_html(html)
    if not html then return "" end
    html = html:gsub("<br%s*/?>", "\n"):gsub("</p%s*>", "\n")
    html = html:gsub("</div%s*>", "\n"):gsub("</h[1-6]%s*>", "\n")
    html = html:gsub("<[^>]+>", ""):gsub("&nbsp;", " ")
    html = html:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
    html = html:gsub("&quot;", "\""):gsub("&#39;", "'")
    html = html:gsub("&ldquo;", "\u{201C}"):gsub("&rdquo;", "\u{201D}")
    html = html:gsub("&hellip;", "\u{2026}"):gsub("&mdash;", "\u{2014}"):gsub("&ndash;", "\u{2013}")
    return html
end

local function utf8_char(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
    elseif code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + (math.floor(code / 0x40) % 0x40), 0x80 + (code % 0x40))
    elseif code < 0x110000 then
        return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + (math.floor(code / 0x1000) % 0x40), 0x80 + (math.floor(code / 0x40) % 0x40), 0x80 + (code % 0x40))
    end
    return ""
end

function Content.decode_html_entities(text)
    if not text then return "" end
    text = text:gsub("&nbsp;", " "):gsub("&amp;", "&")
    text = text:gsub("&lt;", "<"):gsub("&gt;", ">")
    text = text:gsub("&quot;", "\""):gsub("&#39;", "'")
    text = text:gsub("&ldquo;", "\u{201C}"):gsub("&rdquo;", "\u{201D}")
    text = text:gsub("&lsquo;", "\u{2018}"):gsub("&rsquo;", "\u{2019}")
    text = text:gsub("&hellip;", "\u{2026}"):gsub("&mdash;", "\u{2014}"):gsub("&ndash;", "\u{2013}")
    text = text:gsub("&#(%d+);", function(code)
        return utf8_char(tonumber(code, 10))
    end)
    text = text:gsub("&#x([0-9a-fA-F]+);", function(code)
        return utf8_char(tonumber(code, 16))
    end)
    return text
end

function Content.clean_chapter_content(raw_content, title)
    if not raw_content then return "" end

    local content = raw_content

    content = content:gsub("\226\128[\139\140\141\142\143]", "")
    content = content:gsub("\226\128[\168\169\170\171\172\173\174]", "")
    content = content:gsub("\194\173", "")
    content = content:gsub("\239\187\191", "")

    content = content:gsub("<header[^>]->[%s%S]-</header>", "")
    content = content:gsub("<script[^>]->[%s%S]-</script>", "")
    content = content:gsub("<style[^>]->[%s%S]-</style>", "")
    content = content:gsub("<nav[^>]->[%s%S]-</nav>", "")
    content = content:gsub("<!--[%s%S]--->", "")

    local body_match = content:match("<body[^>]->([%s%S]-)</body>")
    if body_match then
        content = body_match
    end

    local ad_start = nil
    local qt_ad = content:find("\240\159\147\163", 1, true)
    local dl_ad = content:find("本书源", 1, true)
    if qt_ad then ad_start = qt_ad end
    if dl_ad and (not ad_start or dl_ad < ad_start) then ad_start = dl_ad end
    if ad_start then
        content = content:sub(1, ad_start - 1)
    end

    local comment_bubbles = {}
    local comment_count = 0
    local comment_samples = {}

    content = content:gsub('<comment%s+ident="([^"]*)"%s+count="([^"]*)"%s*/?>', function(ident, count)
        comment_count = comment_count + 1
        local idx = comment_count
        local n = tonumber(count) or 0
        if #comment_samples < 3 then
            table.insert(comment_samples, string.format('<comment ident="%s" count="%s" />', ident:sub(1, 80), count))
        end
        local n_label = tostring(n)
        if n > 99 then n_label = "99+" end
        comment_bubbles[idx] = string.format(
            '<a class="para-comment" href="fanqie-para:%d">[%s]</a>',
            idx, n_label
        )
        return "\001CMT" .. idx .. "\001"
    end)
    content = content:gsub('<comment%s+ident="([^"]*)"%s*/?>', function(ident)
        comment_count = comment_count + 1
        local idx = comment_count
        if #comment_samples < 3 then
            table.insert(comment_samples, string.format('<comment ident="%s" />', ident:sub(1, 80)))
        end
        comment_bubbles[idx] = string.format(
            '<a class="para-comment" href="fanqie-para:%d">[0]</a>',
            idx
        )
        return "\001CMT" .. idx .. "\001"
    end)

    if logger then
        logger.info(LOG_MODULE, "[段评] clean_chapter_content: comment_count=" .. comment_count
            .. " title=" .. tostring(title or ""))
        if #comment_samples > 0 then
            logger.info(LOG_MODULE, "[段评] <comment> 样本:\n" .. table.concat(comment_samples, "\n"))
        end
    end

    local svg_count_before = 0
    for _ in content:gmatch('data:image/svg%+xml;base64,') do
        svg_count_before = svg_count_before + 1
    end
    if svg_count_before > 0 then
        content = fix_svg_imgs_in_text(content)
        if logger then
            logger.warn(LOG_MODULE, "[图片] SVG 墨水屏兼容修正: 处理 " .. svg_count_before .. " 个 SVG 图片")
        end
    end

    local function extract_placeholders(text)
        local phs = {}
        for ph in text:gmatch("\001CMT%d+\001") do
            table.insert(phs, ph)
        end
        return table.concat(phs, "")
    end

    local function extract_images(text)
        local imgs = {}
        for img in text:gmatch("<[iI][mM][gG][^>]*/?>") do
            table.insert(imgs, img)
        end
        return table.concat(imgs, "")
    end

    local paragraphs = {}
    local para_regex = "<p[^>]->([%s%S]-)</p>"
    local pos = 1

    local img_stats = { before = 0, inner = 0, tail = 0, fallback = 0 }
    local img_before_clean = 0
    for _ in content:gmatch("<[iI][mM][gG][^>]*/?>") do
        img_before_clean = img_before_clean + 1
    end

    while true do
        local start_pos, end_pos, inner = content:find(para_regex, pos)
        if not start_pos then
            local tail = content:sub(pos)
            local tail_imgs = extract_images(tail)
            for _ in tail_imgs:gmatch("<[iI][mM][gG][^>]*/?>") do
                img_stats.tail = img_stats.tail + 1
            end
            if tail_imgs ~= "" then
                if #paragraphs > 0 then
                    paragraphs[#paragraphs] = paragraphs[#paragraphs] .. tail_imgs
                else
                    table.insert(paragraphs, tail_imgs)
                end
            end
            local ph_html = extract_placeholders(tail)
            if ph_html ~= "" then
                if #paragraphs > 0 then
                    paragraphs[#paragraphs] = paragraphs[#paragraphs] .. ph_html
                else
                    table.insert(paragraphs, "<p>" .. ph_html .. "</p>")
                end
            end
            break
        end

        local before_text = content:sub(pos, start_pos - 1)
        local before_imgs = extract_images(before_text)
        for _ in before_imgs:gmatch("<[iI][mM][gG][^>]*/?>") do
            img_stats.before = img_stats.before + 1
        end
        if before_imgs ~= "" then
            if #paragraphs > 0 then
                paragraphs[#paragraphs] = paragraphs[#paragraphs] .. before_imgs
            else
                table.insert(paragraphs, before_imgs)
            end
        end
        local ph_html = extract_placeholders(before_text)

        local parts = {}
        local scan = 1
        local inner_len = #inner
        while scan <= inner_len do
            local img_start, img_end, img_tag = inner:find('(<[iI][mM][gG][^>]*/?>)', scan)
            local br_start, br_end, br_tag = inner:find('(<br%s*/?>)', scan)
            local next_tag_start, next_tag_end, next_tag = nil, nil, nil
            local is_img = false
            local is_br = false
            if img_start and (not br_start or img_start <= br_start) then
                next_tag_start, next_tag_end, next_tag = img_start, img_end, img_tag
                is_img = true
            elseif br_start then
                next_tag_start, next_tag_end, next_tag = br_start, br_end, br_tag
                is_br = true
            end

            if next_tag_start then
                if next_tag_start > scan then
                    local txt = inner:sub(scan, next_tag_start - 1)
                    txt = txt:gsub("<[^>]+>", "")
                    txt = Content.decode_html_entities(txt)
                    local trimmed = H.trim(txt)
                    if trimmed ~= "" then
                        table.insert(parts, xml_escape(trimmed))
                    end
                end
                if is_img then
                    table.insert(parts, next_tag)
                    img_stats.inner = img_stats.inner + 1
                elseif is_br then
                    table.insert(parts, "<br/>")
                end
                scan = next_tag_end + 1
            else
                local txt = inner:sub(scan)
                txt = txt:gsub("<[^>]+>", "")
                txt = Content.decode_html_entities(txt)
                local trimmed = H.trim(txt)
                if trimmed ~= "" then
                    table.insert(parts, xml_escape(trimmed))
                end
                break
            end
        end

        local para_content = table.concat(parts, "\n")
        if para_content ~= "" then
            local stripped = para_content:gsub("<[iI][mM][gG][^>]*/?>", "")
            stripped = stripped:gsub("%s", "")
            local is_img_only = stripped == "" and para_content:find("<[iI][mM][gG]")
            if is_img_only then
                table.insert(paragraphs, para_content .. ph_html)
            else
                table.insert(paragraphs, "<p>" .. para_content .. "</p>" .. ph_html)
            end
        elseif ph_html ~= "" then
            table.insert(paragraphs, "<p>" .. ph_html .. "</p>")
        end
        pos = end_pos + 1
    end

    if #paragraphs == 0 then
        local lines = {}
        local scan = 1
        local content_len = #content
        while scan <= content_len do
            local img_start, img_end, img_tag = content:find("(<[iI][mM][gG][^>]*/?>)", scan)
            if not img_start then
                local tail = content:sub(scan)
                local ph_html = extract_placeholders(tail)
                tail = tail:gsub("<br%s*/?>", "\n")
                tail = tail:gsub("<[^>]+>", "")
                tail = Content.decode_html_entities(tail)
                for line in (tail .. "\n"):gmatch("([^\n]+)\n") do
                    line = H.trim(line)
                    if line ~= "" then
                        table.insert(lines, "<p>" .. xml_escape(line) .. "</p>")
                    end
                end
                if ph_html ~= "" then
                    if #lines > 0 then
                        lines[#lines] = lines[#lines] .. ph_html
                    else
                        table.insert(lines, "<p>" .. ph_html .. "</p>")
                    end
                end
                break
            end
            local before = content:sub(scan, img_start - 1)
            local ph_html = extract_placeholders(before)
            before = before:gsub("<br%s*/?>", "\n")
            before = before:gsub("<[^>]+>", "")
            before = Content.decode_html_entities(before)
            for line in (before .. "\n"):gmatch("([^\n]+)\n") do
                line = H.trim(line)
                if line ~= "" then
                    table.insert(lines, "<p>" .. xml_escape(line) .. "</p>")
                end
            end
            if ph_html ~= "" then
                if #lines > 0 then
                    lines[#lines] = lines[#lines] .. ph_html
                else
                    table.insert(lines, "<p>" .. ph_html .. "</p>")
                end
            end
            table.insert(lines, img_tag)
            img_stats.fallback = img_stats.fallback + 1
            scan = img_end + 1
        end
        paragraphs = lines
    end

    local result = table.concat(paragraphs, "\n")
    local restored_count = 0
    result = result:gsub("\001CMT(%d+)\001", function(idx_str)
        local idx = tonumber(idx_str)
        if comment_bubbles[idx] then
            restored_count = restored_count + 1
            return comment_bubbles[idx]
        end
        return ""
    end)

    if logger and comment_count > 0 then
        logger.info(LOG_MODULE, "[段评] 气泡还原: restored=" .. restored_count .. "/" .. comment_count)
    end

    if logger then
        local img_after = 0
        for _ in result:gmatch("<[iI][mM][gG][^>]*/?>") do
            img_after = img_after + 1
        end
        local found_total = img_stats.before + img_stats.inner + img_stats.tail + img_stats.fallback
        logger.warn(LOG_MODULE, "[图片] clean_chapter_content: input=" .. img_before_clean
            .. " output=" .. img_after
            .. " found{before=" .. img_stats.before
            .. " inner=" .. img_stats.inner
            .. " tail=" .. img_stats.tail
            .. " fallback=" .. img_stats.fallback
            .. " total=" .. found_total .. "}"
            .. (img_before_clean ~= img_after and " <<< 图片丢失!" or " OK"))
    end

    return result
end

function Content.txt_to_xhtml(text)
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    local parts = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = line:match("^(.-)%s*$") or ""
        if line ~= "" then
            table.insert(parts, "<p>" .. xml_escape(line) .. "</p>")
        end
    end
    return '<?xml version="1.0" encoding="utf-8"?>\n'
        .. '<html xmlns="http://www.w3.org/1999/xhtml"><head><title></title></head>\n'
        .. '<body>\n' .. table.concat(parts, "\n") .. '\n</body></html>'
end

local function to_precise_id(value)
    if value == nil then return nil end
    if type(value) == "string" then return value, false, false end
    if type(value) == "number" then
        local s = string.format("%.0f", value)
        if tonumber(s) ~= value then
            return s, true, true
        end
        return s, true, false
    end
    return tostring(value), false, false
end

local function fix_chapter_ids(chapter)
    if type(chapter) ~= "table" then return chapter end
    local fixed = {}
    for k, v in pairs(chapter) do
        if k == "itemId" or k == "item_id" or k == "bookId" or k == "book_id" then
            local sid = to_precise_id(v)
            if sid then
                fixed[k] = sid
            else
                fixed[k] = v
            end
        else
            fixed[k] = v
        end
    end
    return fixed
end

function Content.normalize_chapters(payload, book_id)
    local records = payload
    if type(payload) == "table" and payload.data then
        records = payload.data
    end
    if type(records) ~= "table" then
        return {}
    end

    if type(records.chapterListWithVolume) == "table" then
        local flattened = {}
        for _, volume in ipairs(records.chapterListWithVolume) do
            if type(volume) == "table" then
                for _, ch in ipairs(volume) do
                    if type(ch) == "table" and ch.itemId then
                        table.insert(flattened, fix_chapter_ids(ch))
                    end
                end
            end
        end
        if #flattened > 0 then
            return flattened
        end
    end
    if type(records.chapterList) == "table" then
        local out = {}
        for _, ch in ipairs(records.chapterList) do
            table.insert(out, fix_chapter_ids(ch))
        end
        return out
    end
    if type(records.allItemIds) == "table" and #records.allItemIds > 0 then
        local chapters = {}
        for i, item_id in ipairs(records.allItemIds) do
            local sid = to_precise_id(item_id) or tostring(item_id)
            table.insert(chapters, {
                itemId = sid,
                title = "第" .. tostring(i) .. "章",
                index = i - 1,
            })
        end
        return chapters
    end
    if records.bookId or records.updated then
        records = { records }
    end
    for record_index, record in ipairs(records) do
        if tostring(record.bookId or "") == tostring(book_id) then
            local list = record.updated or record.chapterInfos or record.chapters
                or record.item_list or record.list or record.chapterList or {}
            local out = {}
            for _, ch in ipairs(list) do
                table.insert(out, fix_chapter_ids(ch))
            end
            return out
        end
    end
    return records
end

function Content.first_readable_chapter(chapters)
    for chapter_index, chapter in ipairs(chapters or {}) do
        if tostring(chapter.title or "") ~= "封面" then
            return chapter
        end
    end
end

function Content.readable_chapters(chapters)
    local out = {}
    for chapter_index, chapter in ipairs(chapters or {}) do
        if tostring(chapter.title or "") ~= "封面" then
            table.insert(out, chapter)
        end
    end
    return out
end

local function image_trim(value)
    local s = tostring(value or ""):match("^%s*(.-)%s*$") or ""
    s = s:gsub("&amp;", "&")
    s = s:gsub("&#38;", "&")
    return s
end

local function image_remote_url(value)
    local url = tostring(value or "")
    if url:match("^//") then
        return "https:" .. url
    end
    if url:match("^https?://") then
        return url
    end
    return nil
end

local function image_attr(attrs, name_pattern)
    local value = attrs:match("%s*" .. name_pattern .. "%s*=%s*[\"']([^\"']*)[\"']")
    if not value then
        value = attrs:match("%s*" .. name_pattern .. "%s*=%s*([^%s>]+)")
    end
    if not value then
        value = attrs:match("^" .. name_pattern .. "%s*=%s*[\"']([^\"']*)[\"']")
        if not value then
            value = attrs:match("^" .. name_pattern .. "%s*=%s*([^%s>]+)")
        end
    end
    return value
end

local function image_remove_attr(attrs, name_pattern)
    local result = attrs:gsub("%s*" .. name_pattern .. "%s*=%s*[\"'][^\"']*[\"']", "")
    result = result:gsub("%s*" .. name_pattern .. "%s*=%s*[^%s>]+", "")
    return result
end

local function image_set_local_src(attrs, href)
    local cleaned = image_remove_attr(attrs, "src")
    cleaned = image_remove_attr(cleaned, "data%-src")
    cleaned = image_remove_attr(cleaned, "data%-original")
    cleaned = image_remove_attr(cleaned, "data%-lazy%-src")
    cleaned = image_remove_attr(cleaned, "data%-actualsrc")
    cleaned = image_remove_attr(cleaned, "data%-actual-src")
    cleaned = image_remove_attr(cleaned, "srcset")
    cleaned = cleaned:gsub("^%s+", "")
    return ' src="' .. href .. '"' .. (cleaned or "")
end

local function image_unique_href(used, prefix, index, ext)
    local href = string.format("images/%s_%03d%s", prefix or "img", index or 1, ext or ".png")
    if used[href] then
        local counter = 1
        while used[href] do
            href = string.format("images/%s_%03d_%d%s", prefix or "img", index or 1, counter, ext or ".png")
            counter = counter + 1
        end
    end
    used[href] = true
    return href
end

function Content.download_remote_images(client, xhtml, used_names, progress)
    local assets = {}
    used_names = used_names or {}
    local source_map = {}

    local summary = { total = 0, downloaded = 0, failed = 0, data_uri = 0, total_found = 0 }

    xhtml = tostring(xhtml or ""):gsub("<[iI][mM][gG]([^>]*)>", function(attrs)
        summary.total_found = summary.total_found + 1
        local srcset = image_attr(attrs, "srcset")
        local source = image_attr(attrs, "data%-src")
            or image_attr(attrs, "data%-original")
            or image_attr(attrs, "data%-lazy%-src")
            or image_attr(attrs, "data%-actualsrc")
            or image_attr(attrs, "data%-actual%-src")
            or image_attr(attrs, "src")
            or (srcset and srcset:match("^%s*([^,%s]+)"))

        local clean_source = image_trim(source)
        if clean_source == "" then
            return "<img" .. attrs .. ">"
        end

        clean_source = Content.decode_html_entities(clean_source)

        if clean_source:lower():match("^data:") then
            summary.data_uri = summary.data_uri + 1
            return "<img" .. attrs .. ">"
        end

        local local_src = source_map[clean_source]
        if not local_src then
            local url = image_remote_url(clean_source)
            if not url then
                return "<img" .. attrs .. ">"
            end

            summary.total = summary.total + 1

            local img_headers = {
                ["Accept"] = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
                ["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8",
                ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36 Edg/150.0.0.0",
                ["Connection"] = "keep-alive",
                ["Upgrade-Insecure-Requests"] = "1",
            }

            local img_referer = nil
            local img_host = url:match("^https?://([^/]+)")
            if img_host and img_host:find("fqnovelpic") then
                img_referer = false
            end
            local ok, data = pcall(function()
                return client:get_binary(url, {
                    referer = img_referer,
                    headers = img_headers,
                })
            end)

            if not ok or not data or #data == 0 then
                summary.failed = summary.failed + 1
                if logger then logger.warn("image download failed:", url) end
                return "<img" .. attrs .. ">"
            end

            local ext, mt = media_type_for(data)
            if not mt:match("^image/") then
                summary.failed = summary.failed + 1
                if logger then logger.warn("remote asset is not an image:", url, mt) end
                return "<img" .. attrs .. ">"
            end

            local img_index = #assets + 1
            local href = image_unique_href(used_names, "img", img_index, ext)
            local local_path = "../" .. href

            assets[#assets + 1] = {
                href = href,
                media_type = mt,
                data = data,
                source = url,
            }

            source_map[clean_source] = local_path
            local_src = local_path
            summary.downloaded = summary.downloaded + 1
        end

        if progress then
            progress(summary.downloaded, summary.total)
        end
        return "<img" .. image_set_local_src(attrs, local_src) .. ">"
    end)

    if logger then
        logger.warn(LOG_MODULE, "[图片] download_remote_images: found=" .. summary.total_found
            .. " data_uri_skipped=" .. summary.data_uri
            .. " remote_total=" .. summary.total
            .. " downloaded=" .. summary.downloaded
            .. " failed=" .. summary.failed)
    end

    return xhtml, assets, summary
end

function Content.fetch_catalog(client, book)
    local book_id = book.book_id or book.bookId
    local result = client:fetch_chapter_directory(book_id)
    local chapters = Content.readable_chapters(Content.normalize_chapters(result, book_id))
    book.chapters = chapters
    return chapters
end

function Content.fetch_chapter_content(client, settings, book, chapter, opts)
    opts = opts or {}
    local book_id = tostring(book.book_id or book.bookId or "")
    local item_id = tostring(chapter.itemId or chapter.item_id or "")

    local t_fetch = now_ms()
    local fetch_opts = opts.review and { review = true } or nil
    local result, _src_id, rate_info = client:get_chapter_content_with_fallback(book_id, item_id, fetch_opts)
    local fetch_elapsed = now_ms() - t_fetch

    local content = result.content or ""
    local title = result.title or chapter.title or ""
    if result.author and result.author ~= "" and (not book.author or book.author == "未知") then
        book.author = result.author
    end

    local t_pua = now_ms()
    if content:find("\238", 1, true) then
        content = Content.decode_pua_content(content)
    end
    local pua_elapsed = now_ms() - t_pua

    local t_clean = now_ms()

    local raw_comment_count = 0
    local raw_comment_pos = content:find("<comment", 1, true)
    if raw_comment_pos then
        for _ in content:gmatch("<comment[^>]*/?>") do
            raw_comment_count = raw_comment_count + 1
        end
    end
    if logger then
        logger.info(LOG_MODULE, "[段评] fetch_chapter_content:",
            "itemId=" .. item_id,
            "review_mode=" .. tostring(opts.review == true),
            "raw_has_comment=" .. tostring(raw_comment_pos ~= nil),
            "raw_comment_count=" .. raw_comment_count,
            "para_reviews_from_api=" .. tostring(#(result.para_reviews or {})),
            "raw_content_len=" .. tostring(#content))
    end

    local cleaned = Content.clean_chapter_content(content, title)
    local clean_elapsed = now_ms() - t_clean
    if logger then
        local bubble_count = 0
        for _ in cleaned:gmatch('class="para%-comment"') do
            bubble_count = bubble_count + 1
        end
        logger.info(LOG_MODULE, "[段评] 清洗结果: bubble_in_cleaned=" .. bubble_count
            .. " raw_comment=" .. raw_comment_count
            .. " (若 raw_comment>0 但 bubble=0 则是处理bug, 已修复)")
    end

    if logger then
        logger.debug(LOG_MODULE, "[perf] fetch_chapter_content:",
            "itemId=" .. item_id,
            "fetch=" .. string.format("%.0f", fetch_elapsed) .. "ms",
            "pua_decode=" .. string.format("%.0f", pua_elapsed) .. "ms",
            "clean=" .. string.format("%.0f", clean_elapsed) .. "ms",
            "raw_len=" .. tostring(#content),
            "cleaned_len=" .. tostring(#cleaned))
    end

    local para_reviews = result.para_reviews or {}

    return '<?xml version="1.0" encoding="utf-8"?>\n'
        .. '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>' .. xml_escape(title) .. '</title></head>\n'
        .. '<body>\n' .. cleaned .. '\n</body></html>',
        para_reviews,
        rate_info
end

function Content.save_chapter_html(settings, book, chapter, xhtml, assets, css)
    local book_id = book.book_id or book.bookId
    local dir = Content.book_cache_dir(settings, book_id)
    H.make_dir(dir)
    local images_dir = dir .. "/images"
    local item_id = tostring(chapter.itemId)
    local path = dir .. "/" .. "chapter_" .. item_id .. ".html"
    local title = chapter.title or book.title or "FanQie"

    local function split_title_for_display(raw_title)
        local t = tostring(raw_title or "")
        local chars = require("util").splitToChars(t)

        local num_chars = {
            ["一"]=true, ["二"]=true, ["三"]=true, ["四"]=true, ["五"]=true,
            ["六"]=true, ["七"]=true, ["八"]=true, ["九"]=true, ["十"]=true,
            ["百"]=true, ["千"]=true, ["零"]=true, ["〇"]=true, ["两"]=true,
        }
        local ending_chars = {
            ["章"]=true, ["卷"]=true, ["节"]=true, ["回"]=true,
            ["部"]=true, ["篇"]=true,
        }

        if chars[1] == "第" then
            local i = 2
            while i <= #chars do
                local c = chars[i]
                if num_chars[c] or c:match("^%d$") then
                    i = i + 1
                else
                    break
                end
            end
            if i >= 3 and ending_chars[chars[i]] then
                local num = table.concat(chars, "", 1, i)
                local rest = table.concat(chars, "", i + 1)
                rest = rest:gsub("^%s+", "")
                if rest ~= "" then
                    return '<span class="chap-num">' .. xml_escape(num)
                        .. "</span><br/>" .. xml_escape(rest)
                end
            end
        end
        return xml_escape(t)
    end

    local href_to_rel = {}
    if assets and #assets > 0 then
        H.make_dir(images_dir)
        for _, a in ipairs(assets) do
            local file_href = a.href
            local abs_path = dir .. "/" .. file_href
            local ok_write, err_write = pcall(function()
                H.write_file(abs_path, a.data)
            end)
            if not ok_write then
                if logger then logger.warn("failed to save image file:", abs_path, tostring(err_write)) end
            end
            href_to_rel[a.href] = file_href
            href_to_rel["../" .. a.href] = file_href
        end
    end

    local href_to_data = {}
    if assets and #assets > 0 then
        for _, a in ipairs(assets) do
            href_to_data[a.href] = "data:" .. a.media_type .. ";base64," .. base64_encode(a.data)
            href_to_data["../" .. a.href] = "data:" .. a.media_type .. ";base64," .. base64_encode(a.data)
        end
    end

    local body = body_fragment(xhtml)

    if logger then
        local img_before_fragment = 0
        for _ in tostring(xhtml):gmatch("<[iI][mM][gG][^>]*/?>") do
            img_before_fragment = img_before_fragment + 1
        end
        local img_after_fragment = 0
        for _ in body:gmatch("<[iI][mM][gG][^>]*/?>") do
            img_after_fragment = img_after_fragment + 1
        end
        if img_before_fragment ~= img_after_fragment then
            logger.warn(LOG_MODULE, "[图片] save_chapter_html body_fragment: 输入=" .. img_before_fragment
                .. " 输出=" .. img_after_fragment .. " <<< body_fragment 丢失图片!")
        end
    end

    local visited = {}
    body = body:gsub('<[iI][mM][gG]([^>]*)>', function(attrs)
        local src, quote_char = nil, nil
        local s_start, s_end, q, val = attrs:find('%ssrc%s*=%s*(["\'])(.-)%1')
        if s_start then
            src, quote_char = val, q
        else
            s_start, s_end, val = attrs:find('%ssrc%s*=%s*([^%s>]+)')
            if s_start then
                src, quote_char = val, nil
            end
        end

        local new_src = nil
        if src then
            local data_uri = href_to_data[src]
            if not data_uri then
                local stripped = src:gsub("^%.%./", "")
                data_uri = href_to_data[stripped]
            end
            if data_uri then
                new_src = data_uri
            else
                new_src = Content.decode_html_entities(src)
            end
        end

        if not new_src or new_src == src then
            return "<img" .. attrs .. ">"
        end

        local new_attrs
        if quote_char then
            new_attrs = attrs:gsub('(%ssrc%s*=%s*)["\'].-["\']', '%1' .. quote_char .. new_src .. quote_char, 1)
        else
            new_attrs = attrs:gsub('(%ssrc%s*=%s*)[^%s>]+', '%1' .. '"' .. new_src .. '"', 1)
        end
        if new_attrs == attrs then
            local cleaned = attrs:gsub('%ssrc%s*=%s*["\'][^"\']*["\']', ''):gsub('%ssrc%s*=%s*[^%s>]+', '')
            new_attrs = cleaned .. ' src="' .. new_src .. '"'
        end
        return "<img" .. new_attrs .. ">"
    end)

    css = css or [[body { font-size: 1.05em; }]]
    local html = [[<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>]] .. xml_escape(title) .. [[</title>
<style>
]] .. css .. [[
</style>
</head>
<body>
<h1>]] .. split_title_for_display(title) .. [[</h1>
]] .. body .. [[
</body>
</html>]]
    H.write_file(path, html)
    return path
end

function Content.fetch_chapter_content_locked(client, settings, book, chapter, opts)
    opts = opts or {}
    local src = book._search_source or "official"
    local item_id = tostring(chapter.itemId or chapter.item_id or "")

    local result
    if src == "shushan" then
        local ShuShan = require("fanqie.shushan")
        result = ShuShan.get_content(client, settings,
            tostring(chapter.bookid or book.book_id or ""),
            item_id, {
            review = opts.review,
            cid = chapter.cid,
            source = book.source,
        })
    else
        result = client:official_get_content(tostring(book.book_id or ""), item_id)
    end

    if not result or not result.content then
        error("锁定源取正文失败: source=" .. src .. " itemId=" .. item_id)
    end

    local content = result.content
    local title = result.title or chapter.title or ""

    if content:find("\238", 1, true) then
        content = Content.decode_pua_content(content)
    end
    local cleaned = Content.clean_chapter_content(content, title)

    return '<?xml version="1.0" encoding="utf-8"?>\n'
        .. '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>'
        .. xml_escape(title) .. '</title></head>\n'
        .. '<body>\n' .. cleaned .. '\n</body></html>',
        result.para_reviews or {},
        nil
end

function Content.fetch_chapter_html(client, settings, book, chapter, opts)
    opts = opts or {}
    local t_total = now_ms()
    local book_id = book.book_id or book.bookId
    local item_id = tostring(chapter.itemId)

    local t_fetch = now_ms()
    local is_locked = book._search_source and book._search_source ~= "official"
    local ok_fetch, xhtml, para_reviews, rate_info
    if is_locked then
        ok_fetch, xhtml, para_reviews, rate_info = pcall(
            Content.fetch_chapter_content_locked, client, settings, book, chapter, opts)
    else
        ok_fetch, xhtml, para_reviews, rate_info = pcall(
            Content.fetch_chapter_content, client, settings, book, chapter, opts)
    end
    local fetch_elapsed = now_ms() - t_fetch
    if not ok_fetch then
        error("fetch_chapter_content failed: " .. tostring(xhtml))
    end

    local css = [[
body { font-size: 1em; }
p{
   text-indent: 2em;
}


img {
  display: block;
  margin: 0 auto;
  max-width: 100%;
  height: auto;
}

/* 段评标记：[数字] 方括号形式，点击触发 onGotoLink
   纯文本字符实现，任何 crengine 版本都可靠渲染（不依赖圆角/背景） */
a.para-comment {
  font-size: 0.8em !important;
  text-decoration: none;
  font-weight: bold;
  margin-left: 1px;
  margin-right: 1px;
}

]]
    local assets = {}
    local cache = settings:get("cache", {})
    local img_elapsed = 0
    if cache.download_book_images ~= false then
        local used_names = {}
        local t_img = now_ms()
        local ok_img, inline_xhtml, inline_assets = pcall(Content.download_remote_images, client, xhtml, used_names)
        img_elapsed = now_ms() - t_img
        if ok_img and inline_xhtml then
            xhtml = inline_xhtml
            for _, a in ipairs(inline_assets or {}) do
                table.insert(assets, a)
            end
        end
    end

    local t_save = now_ms()
    local path = Content.save_chapter_html(settings, book, chapter, xhtml, assets, css)
    local save_elapsed = now_ms() - t_save

    book.cached_chapters = book.cached_chapters or {}
    book.cached_chapters[item_id] = path
    book.cached_file = path
    book.item_id = chapter.itemId
    book.reader_url = book.reader_url or FanQie.reader_url(chapter.itemId)

    if para_reviews and #para_reviews > 0 then
        Content.save_para_reviews_index(settings, book_id, item_id, para_reviews)
    end

    local idx_elapsed = 0
    if not opts.skip_cache_index then
        local t_idx = now_ms()
        Content.save_cache_index(settings, book_id, book.cached_chapters)
        idx_elapsed = now_ms() - t_idx
    end

    local total_elapsed = now_ms() - t_total
    if logger then
        logger.debug(LOG_MODULE, "[perf] fetch_chapter_html TOTAL:",
            "itemId=" .. item_id,
            "total=" .. string.format("%.0f", total_elapsed) .. "ms",
            "content_fetch=" .. string.format("%.0f", fetch_elapsed) .. "ms",
            "images=" .. string.format("%.0f", img_elapsed) .. "ms",
            "save_html=" .. string.format("%.0f", save_elapsed) .. "ms",
            "save_index=" .. string.format("%.0f", idx_elapsed) .. "ms",
            "assets_count=" .. tostring(#assets))
    end

    return path, chapter, para_reviews, rate_info
end

function Content.save_para_reviews_index(settings, book_id, item_id, para_reviews)
    local dir = Content.book_cache_dir(settings, book_id)
    H.make_dir(dir)
    local index_path = H.join_path(dir, "para_reviews_" .. tostring(item_id) .. ".lua")
    local parts = { "return {" }
    for i, pr in ipairs(para_reviews or {}) do
        if pr.ident and pr.count then
            table.insert(parts, string.format('  { ident = "%s", count = %d },',
                tostring(pr.ident):gsub('"', '\\"'), pr.count))
        end
    end
    table.insert(parts, "}")
    H.write_file(index_path, table.concat(parts, "\n"))
end

function Content.load_para_reviews_index(settings, book_id, item_id)
    local dir = Content.book_cache_dir(settings, book_id)
    local index_path = H.join_path(dir, "para_reviews_" .. tostring(item_id) .. ".lua")
    if not H.file_exists(index_path) then
        return {}
    end
    local ok, data = pcall(dofile, index_path)
    if not ok or type(data) ~= "table" then
        return {}
    end
    return data
end

local function lua_serialize(v)
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "nil" then
        return "nil"
    elseif t == "table" then
        local parts = {}
        for k, val in pairs(v) do
            local ks
            if type(k) == "string" then
                ks = string.format("[%q]", k)
            elseif type(k) == "number" then
                ks = "[" .. tostring(k) .. "]"
            end
            if ks then
                parts[#parts + 1] = ks .. "=" .. lua_serialize(val)
            end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "nil"
end

local function one_comment_path(settings, book_id, item_id, pid)
    local dir = Content.book_cache_dir(settings, book_id)
    return H.join_path(dir,
        "para_comments_" .. tostring(item_id) .. "_" .. tostring(pid) .. ".lua")
end

function Content.save_one_comment(settings, book_id, item_id, pid, result)
    if not pid or not result then return end
    local path = one_comment_path(settings, book_id, item_id, pid)
    H.make_dir(path:match("^(.*)/[^/]+$"))
    H.write_file(path, "return " .. lua_serialize(result))
end

function Content.load_one_comment(settings, book_id, item_id, pid)
    if not pid then return nil end
    local path = one_comment_path(settings, book_id, item_id, pid)
    if not H.file_exists(path) then return nil end
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then return data end
    return nil
end

function Content.has_one_comment(settings, book_id, item_id, pid)
    if not pid then return false end
    return H.file_exists(one_comment_path(settings, book_id, item_id, pid))
end

function Content.count_all_comments(settings, book_id)
    local dir = Content.book_cache_dir(settings, book_id)
    local lfs = require("libs/libkoreader-lfs")
    local counts = {}
    if lfs.attributes(dir, "mode") ~= "directory" then return counts end
    for entry in lfs.dir(dir) do
        local iid = entry:match("^para_comments_(%d+)_%d+%.lua$")
        if iid then
            counts[iid] = (counts[iid] or 0) + 1
        end
    end
    return counts
end

function Content.delete_chapter_comments(settings, book_id, item_id)
    local dir = Content.book_cache_dir(settings, book_id)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    local prefix = "para_comments_" .. tostring(item_id) .. "_"
    for entry in lfs.dir(dir) do
        if entry:sub(1, #prefix) == prefix and entry:sub(-4) == ".lua" then
            os.remove(dir .. "/" .. entry)
        end
    end
end

function Content.save_para_records(settings, book_id, item_id, records)
    if not records or #records == 0 then return end
    local dir = Content.book_cache_dir(settings, book_id)
    H.make_dir(dir)
    local path = H.join_path(dir, "para_records_" .. tostring(item_id) .. ".lua")

    local parts = { "return {" }
    for _, rec in ipairs(records) do
        parts[#parts + 1] = string.format(
            "{ pos0=%q, pos1=%q, count=%d, ident=%q, para_index=%d },",
            tostring(rec.pos0 or ""),
            tostring(rec.pos1 or ""),
            tonumber(rec.count) or 0,
            tostring(rec.ident or ""),
            tonumber(rec.para_index) or 0
        )
    end
    parts[#parts + 1] = "}"
    H.write_file(path, table.concat(parts, "\n"))
end

function Content.load_para_records(settings, book_id, item_id)
    local dir = Content.book_cache_dir(settings, book_id)
    local path = H.join_path(dir, "para_records_" .. tostring(item_id) .. ".lua")
    if not H.file_exists(path) then return nil end
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" and #data > 0 then return data end
    return nil
end

return Content
