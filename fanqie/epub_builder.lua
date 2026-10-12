-- fanqie/epub_builder.lua
-- 把已缓存的番茄章节合并成一个干净的 EPUB（不含段评气泡）。

local H = require("fanqie.helper")
local Content = require("fanqie.content")

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(t) return t end

local EpubBuilder = {}

local function xml_escape(v)
    v = tostring(v or "")
    v = v:gsub("[%z\1-\8\11\12\14-\31]", "")
    v = v:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
    return v
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function file_exists(path)
    if not path then return false end
    local f = io.open(path, "rb")
    if not f then return false end
    f:close()
    return true
end

local function utc_modified()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- 提取 body 并剥掉所有段评痕迹
local function clean_chapter_body(html)
    if not html then return "" end
    local body = html:match("<body[^>]*>([%s%S]*)</body>") or html
    body = body:gsub("<[cC][oO][mM][mM][eE][nN][tT][^>]*/?>", "")
    body = body:gsub("</[cC][oO][mM][mM][eE][nN][tT]%s*>", "")
    body = body:gsub('<a[^>]-class="para%-comment"[^>]*>.-</a>', "")
    body = body:gsub("\1CMT%d+\1", "")
    return body
end

local function load_image(book_dir, rel_href)
    local abs = book_dir .. "/" .. rel_href
    local data = read_file(abs)
    if not data then return nil end
    local ext = rel_href:match("%.([^.]+)$")
    if not ext then return nil end
    ext = ext:lower()
    local mt = ({
        jpg = "image/jpeg", jpeg = "image/jpeg",
        png = "image/png", gif = "image/gif",
        webp = "image/webp", svg = "image/svg+xml",
    })[ext]
    if not mt then return nil end
    return { href = rel_href, media_type = mt, data = data }
end

local function collect_image_hrefs(body)
    local set = {}
    for href in body:gmatch('src="([^"]+)"') do
        local clean = href:gsub("^%.%./", "")
        if clean:match("^images/") then
            set[clean] = true
        end
    end
    local list = {}
    for href in pairs(set) do list[#list + 1] = href end
    table.sort(list)
    return list
end

local function rewrite_image_hrefs(body)
    return (body:gsub('src="(images/[^"]+)"', 'src="../%1"'))
end

local function build_chapter_xhtml(title, body)
    return string.format([[
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">
<head>
<title>%s</title>
<link rel="stylesheet" type="text/css" href="../style.css"/>
</head>
<body>
%s
</body>
</html>]], xml_escape(title), body)
end

local DEFAULT_CSS = [[
body { line-height: 1.7; margin: 5%; }
p { text-indent: 2em; margin: 0.4em 0; }
img { display: block; margin: 0 auto; max-width: 100%; height: auto; }
h1 { font-size: 1.3em; text-align: center; margin: 0.8em 0 1.2em; }
]]

-- 返回 (epub_path, chapter_count, missing_count) 或 (nil, err)
function EpubBuilder.build(settings, book, chapters, opts)
    opts = opts or {}
    if type(chapters) ~= "table" or #chapters == 0 then
        return nil, "章节目录为空"
    end

    local book_id = book.book_id or book.bookId
    if not book_id then return nil, "缺少 book_id" end

    local cache = Content.load_cache_index(settings, book_id) or {}
    local book_dir = Content.book_cache_dir(settings, book_id)
    if not H.dir_exists(book_dir) then
        return nil, "缓存目录不存在：" .. tostring(book_dir)
    end

    -- 收集章节
    local selected = {}
    local missing = 0
    local real_count = 0

    for _, ch in ipairs(chapters) do
        local item_id = tostring(ch.itemId or ch.item_id or "")
        local path = cache[item_id]
        if not (path and file_exists(path)) then
            path = book_dir .. "/chapter_" .. item_id .. ".html"
            if not file_exists(path) then
                path = nil
            end
        end

        if path then
            local html = read_file(path)
            local body = clean_chapter_body(html)
            local images = collect_image_hrefs(body)
            body = rewrite_image_hrefs(body)
            selected[#selected + 1] = { chapter = ch, body = body, images = images }
            real_count = real_count + 1
        else
            selected[#selected + 1] = {
                chapter = ch,
                body = string.format('<h1>%s</h1>\n<p>[内容下载失败]</p>',
                    xml_escape(ch.title or "")),
                images = {},
            }
            missing = missing + 1
        end
    end

    if real_count == 0 then
        return nil, "所有章节都下载失败，无法生成 EPUB"
    end

    local book_title = book.title or "FanQie"
    local author = book.author or ""
    local epub_name = book_title:gsub("[/\\:%*%?\"<>|]", "_") .. ".epub"
    local epub_path = book_dir .. "/" .. epub_name

    local entries = {
        { name = "mimetype", data = "application/epub+zip" },
        { name = "META-INF/container.xml", data = [[<?xml version="1.0" encoding="utf-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]] },
    }

    local manifest = {
        [[<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>]],
        [[<item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>]],
        [[<item id="style" href="style.css" media-type="text/css"/>]],
    }
    local spine = {}
    local nav_items = {}
    local ncx_points = {}
    local play_order = 0

    -- 封面
    local cover_file
    for _, ext in ipairs({ "jpg", "jpeg", "png", "webp" }) do
        local p = book_dir .. "/cover." .. ext
        if file_exists(p) then cover_file = p; break end
    end
    if cover_file then
        local data = read_file(cover_file)
        if data then
            local ext = cover_file:match("%.([^.]+)$"):lower()
            local mt = ext == "png" and "image/png" or "image/jpeg"
            table.insert(entries, { name = "OEBPS/images/cover." .. ext, data = data })
            table.insert(manifest, string.format(
                [[<item id="cover-image" href="images/cover.%s" media-type="%s" properties="cover-image"/>]], ext, mt))
            table.insert(manifest, [[<item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>]])
            table.insert(spine, [[<itemref idref="cover"/>]])
            table.insert(entries, { name = "OEBPS/text/cover.xhtml", data = string.format([[
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">
<head><title>Cover</title>
<style>html,body{margin:0;padding:0;width:100%%;height:100%%;overflow:hidden;}img{display:block;width:100%%;height:100%%;object-fit:contain;}</style>
</head>
<body><img src="../images/cover.%s" alt="Cover"/></body>
</html>]], ext) })
        end
    end

    -- 图片去重
    local added_images = {}
    for _, item in ipairs(selected) do
        for _, href in ipairs(item.images) do
            if not added_images[href] then
                local img = load_image(book_dir, href)
                if img then
                    added_images[href] = true
                    local fname = href:match("([^/]+)$")
                    local id = "img_" .. fname:gsub("[^%w]", "_")
                    table.insert(entries, { name = "OEBPS/" .. href, data = img.data })
                    table.insert(manifest, string.format(
                        [[<item id="%s" href="%s" media-type="%s"/>]], id, href, img.media_type))
                end
            end
        end
    end

    -- 章节
    for i, item in ipairs(selected) do
        local ch = item.chapter
        local item_id = tostring(ch.itemId or ch.item_id or i)
        local fname = string.format("text/chapter-%03d.xhtml", i)
        local id = "chapter_" .. item_id:gsub("[^%w]", "_")
        local title = ch.title or ("Chapter " .. i)

        table.insert(entries, {
            name = "OEBPS/" .. fname,
            data = build_chapter_xhtml(title, item.body),
        })
        table.insert(manifest, string.format(
            [[<item id="%s" href="%s" media-type="application/xhtml+xml"/>]], id, fname))
        table.insert(spine, string.format([[<itemref idref="%s"/>]], id))
        table.insert(nav_items, string.format(
            [[<li><a href="%s">%s</a></li>]], fname, xml_escape(title)))
        play_order = play_order + 1
        table.insert(ncx_points, string.format([[
<navPoint id="navPoint-%d" playOrder="%d">
<navLabel><text>%s</text></navLabel>
<content src="%s"/>
</navPoint>]], play_order, play_order, xml_escape(title), fname))
    end

    local opf = string.format([[
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0" prefix="dcterms: http://purl.org/dc/terms/">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="bookid">fanqie-%s</dc:identifier>
<dc:title>%s</dc:title>
<dc:creator>%s</dc:creator>
<dc:publisher>FanQie</dc:publisher>
<dc:language>zh-CN</dc:language>
<meta property="dcterms:modified">%s</meta>
</metadata>
<manifest>
%s
</manifest>
<spine toc="toc">
%s
</spine>
</package>]], xml_escape(book_id), xml_escape(book_title), xml_escape(author),
        utc_modified(), table.concat(manifest, "\n"), table.concat(spine, "\n"))

    local nav = string.format([[
<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Navigation</title></head>
<body>
<nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops">
<ol>
%s
</ol>
</nav>
</body>
</html>]], table.concat(nav_items, "\n"))

    local ncx = string.format([[
<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head>
<meta name="dtb:uid" content="fanqie-%s"/>
<meta name="dtb:depth" content="1"/>
<meta name="dtb:totalPageCount" content="0"/>
<meta name="dtb:maxPageNumber" content="0"/>
</head>
<docTitle><text>%s</text></docTitle>
<navMap>
%s
</navMap>
</ncx>]], xml_escape(book_id), xml_escape(book_title), table.concat(ncx_points, "\n"))

    table.insert(entries, { name = "OEBPS/content.opf", data = opf })
    table.insert(entries, { name = "OEBPS/nav.xhtml", data = nav })
    table.insert(entries, { name = "OEBPS/toc.ncx", data = ncx })
    table.insert(entries, { name = "OEBPS/style.css", data = DEFAULT_CSS })

    -- 写 EPUB
    local Archiver = require("ffi/archiver")
    local archive = Archiver.Writer:new{}
    local part_path = epub_path .. ".part"
    pcall(os.remove, part_path)
    if not archive:open(part_path, "epub") then
        return nil, "无法创建 EPUB：" .. tostring(archive.err)
    end
    local mtime = os.time()
    local ok, err = xpcall(function()
        assert(archive:setZipCompression("store"), archive.err)
        for _, e in ipairs(entries) do
            if e.name == "mimetype" then
                assert(archive:addFileFromMemory(e.name, e.data, mtime), archive.err)
                break
            end
        end
        assert(archive:setZipCompression("deflate"), archive.err)
        for _, e in ipairs(entries) do
            if e.name ~= "mimetype" then
                assert(archive:addFileFromMemory(e.name, e.data or "", mtime), archive.err)
            end
        end
    end, debug.traceback)
    pcall(function() archive:close() end)
    if not ok then
        pcall(os.remove, part_path)
        return nil, err
    end
    pcall(os.remove, epub_path)
    local renamed = os.rename(part_path, epub_path)
    if not renamed then
        pcall(os.remove, part_path)
        return nil, "无法写入 EPUB 文件"
    end

    return epub_path, #selected, missing
end

return EpubBuilder
