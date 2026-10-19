--[[--
Thought popup face factory.

Builds KOReader FontFaceObj tables directly:

  * primary face: the document font (real font file resolved through
    cre.getFontFaceFilenameAndFaceIndex), or the built-in Noto Sans family
    when no document font is available;
  * fallback chain: NotoSansCJKsc -> ... -> NotoEmoji prefilled into
    face.fallbacks; xtext (HarfBuzz) switches fonts per glyph automatically,
    so emoji never needs per-character spans.

Faces are cached process-wide by (doc_font_name, size, variant); glyph bitmaps
are cached by KOReader's Fontcache, so after the first popup there is no font
file I/O.

The face table mirrors Font:getAdjustedFace's clone (frontend/ui/font.lua);
prefilling fallbacks short-circuits font.lua's name-based resolution
(_getFallbackFont checks face_obj.fallbacks[num] first).
--]]

local FontList = require("fontlist")
local Freetype = require("ffi/freetype")
local logger = require("fanqie.logger")

local FaceFactory = {
    initialized = false,
    emoji_path = nil,
    font_paths_cache = {},
    face_cache = {},
    fallback_cache = {}, -- path|size -> FontFaceObj (fallback faces shared across variants)
}

-- Size variants (relative to the base size). quote/meta render one step
-- smaller; meta is the author line.
-- 二级评论（官方源的回复）用同一套字体，只把字号降半档：
--   reply_meta / reply  = 0.85（一级 meta/content 是 0.9）
-- 「展开 N 条回复」这个入口属于一级评论的附属行，字号与一级作者行完全一致
-- （0.9）—— 之前没有登记 variant，getFace 兜底成 1.0，反而比正文还大。
FaceFactory.VARIANTS = {
    content      = 0.9,   -- thought body
    quote        = 0.9,   -- quoted abstract (italic, gray)
    meta         = 0.9,   -- author line; keep it as readable as the thought body
    reply_meta   = 0.85,  -- 二级评论作者行：字体同 meta，字号小半档
    reply        = 0.85,  -- 二级评论正文：字体同 content，字号小半档
    reply_toggle = 0.9,   -- 「展开/收起 N 条回复」：与一级作者行同款同号
}

function FaceFactory:init()
    if self.initialized then return end
    -- The cre engine resolves document font file paths.
    pcall(function()
        require("document/credocument"):engineInit()
    end)
    self:findEmojiFont()
    self.initialized = true
end

--- Locate the NotoEmoji font shipped with the plugin (it lives outside
--- KOReader's font scan directories).
function FaceFactory:findEmojiFont()
    if self.emoji_path then return self.emoji_path end

    local ffiutil = require("ffi/util")
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")

    local function resolve(path)
        if not path then return nil end
        if ok_lfs and lfs.attributes(path, "mode") ~= "file" then return nil end
        if ffiutil.realpath then
            return ffiutil.realpath(path) or path
        end
        return path
    end

    local candidates = {
        "plugins/fanqie.koplugin/fonts/NotoEmoji-Regular.ttf",
    }
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds then
        candidates[#candidates + 1] = DataStorage:getDataDir()
            .. "/plugins/fanqie.koplugin/fonts/NotoEmoji-Regular.ttf"
    end
    for _, path in ipairs(candidates) do
        local abs = resolve(path)
        if abs then
            self.emoji_path = abs
            logger.info("thought popup emoji font:", abs)
            return self.emoji_path
        end
    end

    -- 候选目录：KOReader 数据目录下的 fonts 是跨平台通用的，放最前；
    -- /mnt/us/fonts 仅 Kindle 存在，/usr/share/fonts/truetype 仅桌面 Linux 存在。
    local font_dirs = { "/mnt/us/fonts/", "/usr/share/fonts/truetype/" }
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and DataStorage.getFullDataDir then
        local ok_dir, data_dir = pcall(DataStorage.getFullDataDir, DataStorage)
        if ok_dir and data_dir then
            table.insert(font_dirs, 1, data_dir .. "/fonts/")
        end
    end
    for _, dir in ipairs(font_dirs) do
        local fp = dir .. "NotoEmoji-Regular.ttf"
        if ok_lfs and lfs.attributes(fp, "mode") == "file" then
            self.emoji_path = fp
            logger.info("thought popup emoji font:", fp)
            return self.emoji_path
        end
    end

    -- 最后兜底：借用同机已装的微信读书插件自带的同一份字体（同款 NotoEmoji，
    -- OFL 许可）。只读不写，装了就用、没装就跳过，不构成功能依赖。
    local borrowed = {
        "plugins/weread.koplugin/fonts/NotoEmoji-Regular.ttf",
    }
    if ok_ds and DataStorage and DataStorage.getDataDir then
        local ok_dir2, dd = pcall(DataStorage.getDataDir, DataStorage)
        if ok_dir2 and dd then
            borrowed[#borrowed + 1] = dd .. "/plugins/weread.koplugin/fonts/NotoEmoji-Regular.ttf"
        end
    end
    for _, path in ipairs(borrowed) do
        local abs = resolve(path)
        if abs then
            self.emoji_path = abs
            logger.info("thought popup emoji font (borrowed):", abs)
            return self.emoji_path
        end
    end

    -- 拿不到就明确记一条：此时 emoji 会显示成空白/豆腐块，正文不受影响。
    logger.warn("thought popup emoji font not found; emoji will not render")
    return nil
end

--- Real font files of the document font, cached by font name.
--- @param doc_font_name string|nil
--- @return table[] { { path=string, bold=bool, italic=bool }, ... }
function FaceFactory:getFontPaths(doc_font_name)
    if not doc_font_name then return {} end
    if self.font_paths_cache[doc_font_name] then
        return self.font_paths_cache[doc_font_name]
    end

    local paths = {}
    local ok, cre = pcall(function()
        return require("document/credocument"):engineInit()
    end)
    if ok and cre and type(cre.getFontFaceFilenameAndFaceIndex) == "function" then
        local seen = {}
        for i = 1, 4 do
            local bold = i >= 3
            local italic = i == 2 or i == 4
            local font_path = cre.getFontFaceFilenameAndFaceIndex(doc_font_name, bold, italic)
            if font_path and not seen[font_path] then
                seen[font_path] = true
                paths[#paths + 1] = { path = font_path, bold = bold, italic = italic }
            end
        end
    end

    self.font_paths_cache[doc_font_name] = paths
    return paths
end

--- Hand-built FontFaceObj (modeled on Font:getAdjustedFace's clone).
--- xtext enumerates fallback fonts through face.getFallbackFont(num); a
--- prefilled fallbacks table short-circuits font.lua's name lookup.
--- Fonts are resolved through fontdir first, then a full FontList scan.
--- Faces are built by hand (not Font:getFace) because Font:getFace rescales
--- the size by DPI again; passing an already-scaled size would render glyphs
--- twice as large.
local function resolveBundledFont(fontname)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local path = FontList.fontdir and (FontList.fontdir .. "/" .. fontname)
    if path and ok_lfs and lfs.attributes(path, "mode") == "file" then
        return path
    end
    local fonts = FontList:getFontList()
    if fonts then
        for _, fp in ipairs(fonts) do
            if fp:find(fontname, 1, true) then
                return fp
            end
        end
    end
    return nil
end

function FaceFactory:_buildFace(path, size)
    if not path or not size or size <= 0 then return nil end
    local ok, ftsize = pcall(Freetype.newFaceSize, path, size)
    if not ok or not ftsize then
        logger.warn("thought popup failed to open font:", path, ftsize)
        return nil
    end
    -- 仿粗体的加粗强度（上游 Font:getAdjustedFace 同款）；老版本 FreeType
    -- 包装没有这个方法，取不到就留空（xtext 会退回普通仿粗）。
    local ok_emb, half = pcall(function()
        return ftsize:getEmboldenHalfStrength(3 / 8)
    end)
    local face_obj = {
        orig_font = path,
        realname = path,
        size = size,
        orig_size = size,
        ftsize = ftsize,
        hash = path .. "|" .. size,
        is_real_bold = false,
        embolden_half_strength = (ok_emb and half) or nil,
        hb_features = { "+kern", "+liga" },
    }
    face_obj.fallbacks = {}
    face_obj.getFallbackFont = function(num)
        if not num or num == 0 then return face_obj end
        if face_obj.fallbacks[num] ~= nil then
            return face_obj.fallbacks[num]
        end
        return false -- chain end
    end
    return face_obj
end

--- Fallback faces are shared process-wide: one FT face per (path, size).
function FaceFactory:_getFallbackFace(path, size)
    if not path or not size or size <= 0 then return nil end
    local key = path .. "|" .. size
    local cached = self.fallback_cache[key]
    if cached then return cached end
    local face = self:_buildFace(path, size)
    if face then
        self.fallback_cache[key] = face
    end
    return face
end

--- 字体回退链（命中即用，缺字体则静默跳过）。对齐 KOReader 的 Font.fallbacks：
--- FreeSans/FreeSerif 负责 ▸ U+25B8、♥、箭头与 𝓕 这类少见符号。
--- ⚠️ NotoEmoji 必须放链尾：xtext 的回退是 cluster 级的，放在链中会让
---    与组合符同簇的 emoji 逐级退化成一串豆腐块，放最后才由它兜住。
--- xtext 最多 16 个字体（含主字体），本链 9 个。
local FALLBACK_FONT_NAMES = {
    "FreeSans.ttf",
    "NotoSansCJKsc-Regular.otf",
    "freefont/FreeSerif.ttf",
    "nerdfonts/symbols.ttf",
    "NotoSansTibetan-Regular.ttf",
    "NotoSansEgyptianHieroglyphs-Regular.ttf",
    "NotoSansBrahmi-Regular.ttf",
    "NotoSansSymbols2-Regular.ttf",
    "NotoEmoji-Regular.ttf", -- special: resolved via self.emoji_path; must stay last
}

function FaceFactory:_addFallbacks(face, size)
    local fallbacks = {}
    local n = 0
    for _, fontname in ipairs(FALLBACK_FONT_NAMES) do
        local path
        if fontname == "NotoEmoji-Regular.ttf" then
            path = self.emoji_path
        else
            -- Hand-built (not Font:getFace): size is already DPI-scaled.
            path = resolveBundledFont(fontname)
        end
        if path then
            local fb = self:_getFallbackFace(path, size)
            if fb then
                n = n + 1
                fallbacks[n] = fb
            end
        end
    end
    fallbacks[n + 1] = false -- explicit chain end
    face.fallbacks = fallbacks
end

--- Get a variant face (process-wide cache).
--- @param doc_font_name string|nil document font name (nil -> Noto Sans family)
--- @param size number DPI-scaled base size (i.e. doc_font_size)
--- @param variant string key of VARIANTS
function FaceFactory:getFace(doc_font_name, size, variant)
    variant = variant or "content"
    local key = string.format("%s|%d|%s", doc_font_name or "", size or 0, variant)
    local cached = self.face_cache[key]
    if cached then return cached end

    local ratio = self.VARIANTS[variant] or 1.0
    local v_size = math.max(8, math.floor(size * ratio + 0.5))
    local face

    local paths = self:getFontPaths(doc_font_name)
    local regular, italic
    for _, fp in ipairs(paths) do
        if not fp.bold then
            if fp.italic then
                if not italic then italic = fp.path end
            elseif not regular then
                regular = fp.path
            end
        end
    end
    local prefer_italic = variant == "quote"
    local path = prefer_italic and (italic or regular) or (regular or italic)
    if path then
        face = self:_buildFace(path, v_size)
        if face then
            self:_addFallbacks(face, v_size)
        end
    end

    -- Fallback when the document font cannot be resolved: use a bundled font
    -- (also hand-built to avoid the double DPI scaling).
    if not face then
        local fallback_path = resolveBundledFont(
            prefer_italic and "NotoSans-Italic.ttf" or "NotoSans-Regular.ttf")
            or resolveBundledFont("NotoSansCJKsc-Regular.otf")
        if fallback_path then
            face = self:_buildFace(fallback_path, v_size)
            if face then
                self:_addFallbacks(face, v_size)
            end
        end
    end

    if face then
        self.face_cache[key] = face
    end
    return face
end

function FaceFactory:clearCache()
    self.face_cache = {}
    self.fallback_cache = {}
    self.font_paths_cache = {}
end

return FaceFactory
