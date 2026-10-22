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

-- Size variants (relative to the base size, which equals the body font size).
-- 一级评论 0.93，二级评论 0.90（比一级略小一点）。
-- 「展开 N 条回复」属于一级评论的附属行，与一级作者行同号 —— 未登记 variant
-- 时 getFace 会兜底成 1.0，反而比一级正文还大。
FaceFactory.VARIANTS = {
    content      = 0.93,  -- thought body
    quote        = 0.93,  -- quoted abstract (italic, gray)
    meta         = 0.93,  -- author line; same size as the thought body
    reply_meta   = 0.90,  -- 二级评论作者行：字体同 meta，字号略小
    reply        = 0.90,  -- 二级评论正文：字体同 content，字号略小
    reply_toggle = 0.93,  -- 「展开/收起 N 条回复」：与一级作者行同款同号
}

-- 仿粗强度（对应 KOReader Font.lua 的 bold_strength_factor = 3/8）。
-- 档位 1 用更轻的强度，只够补上「对比度调高」那点笔画差异。
local SYNTH_BOLD_FACTORS = { [1] = 0.18, [2] = 3 / 8 }

--- 把阅读器的「字重 + 对比度」映射成弹框的字重档位：
---   0 常规 / 1 轻仿粗 / 2 标准仿粗
--- cre 的 font.face.base.weight（400/500/350）与 setGammaIndex 只作用于
--- crengine 排版，弹框是自建 FreeType face，必须自己换算。
--- 字重「加粗」= cre 的 500（中等），不是 700，所以用仿粗而不是直接换成
--- 粗体文件——后者会明显比正文重。
---
--- ⚠️ 第二个参数 gamma 必须是**换算后的 gamma 值**（1.0 = 标准），
---    不是设置里存的索引 —— 索引请先过 gammaIndexToValue()。
function FaceFactory.resolveBoldLevel(weight, gamma)
    weight = tonumber(weight) or 0
    gamma = tonumber(gamma) or 1.0
    local level = 0
    if weight >= 0.5 then
        level = 2
    end
    -- 对比度调高时正文字缘被压深，视觉上等于笔画变粗；低对比度则不加粗。
    if gamma >= 1.25 then
        level = math.max(level, 2)
    elseif gamma >= 1.1 then
        level = math.max(level, 1)
    end
    return level
end

--- crengine 的「对比度」在设置里存的是**索引**（0 起，对应 GammaGen 表），
--- 不是 gamma 值：0 → 0.3，15 → 1.0（默认），25 → 1.45，56 → 15。
--- 直接把索引当 gamma 值判断会永远命中「高对比」（15 >= 1.25），
--- 段评就会全篇多一层标准仿粗，比正文还黑。
local GAMMA_BY_INDEX = {
    0.3, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9,
    0.95, 0.98, 1, 1.02, 1.05, 1.1, 1.15, 1.2, 1.25, 1.3, 1.35, 1.4, 1.45,
    1.5, 1.6, 1.7, 1.8, 1.9, 2, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9,
    3, 3.5, 4, 4.5, 5, 5.5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
}

--- 对比度索引 -> gamma 值。默认索引 15（= 1.0）对应「不调对比度」。
function FaceFactory.gammaIndexToValue(index)
    index = math.floor(tonumber(index) or 15)
    if index < 0 then index = 0 end
    if index > #GAMMA_BY_INDEX - 1 then index = #GAMMA_BY_INDEX - 1 end
    return GAMMA_BY_INDEX[index + 1]
end

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

--- Hand-built FontFaceObj (modeled on Font:getAdjustedFace's clone): fonts resolve via
--- fontdir then a FontList scan, fallbacks prefilled so xtext skips the name lookup.
--- Built by hand because Font:getFace rescales size by DPI again → glyphs 2x too large.
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

--- @param embolden_factor number|nil 仿粗强度；nil 表示常规字重
function FaceFactory:_buildFace(path, size, embolden_factor)
    if not path or not size or size <= 0 then return nil end
    local ok, ftsize = pcall(Freetype.newFaceSize, path, size)
    if not ok or not ftsize then
        logger.warn("thought popup failed to open font:", path, ftsize)
        return nil
    end
    -- 仿粗的加粗强度（上游 Font:getAdjustedFace 同款）；老版本 FreeType
    -- 包装没有这个方法，取不到就留空（xtext 会退回普通仿粗）。
    local half
    if embolden_factor then
        local ok_emb, v = pcall(function()
            return ftsize:getEmboldenHalfStrength(embolden_factor)
        end)
        half = ok_emb and v or nil
    end
    -- ⚠️ hash 必须带仿粗强度：RenderText:getGlyphByIndex 的字形缓存键是
    --    face.hash + bold 布尔值，轻仿粗和标准仿粗都是 bold=true，不带强度
    --    就会互相串用（轻档拿到粗档的字形）。
    local hash = path .. "|" .. size
    if embolden_factor then
        hash = string.format("%s|emb%.3f", hash, embolden_factor)
    end
    local face_obj = {
        orig_font = path,
        realname = path,
        size = size,
        orig_size = size,
        ftsize = ftsize,
        hash = hash,
        is_real_bold = false,
        embolden_half_strength = half,
        synth_bold = half ~= nil,
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

--- Fallback faces are shared process-wide: one FT face per (path, size, 仿粗强度).
--- 仿粗链要跟着主字体走，否则中文全落在回退字体上，加粗会失效。
function FaceFactory:_getFallbackFace(path, size, embolden_factor)
    if not path or not size or size <= 0 then return nil end
    local key = string.format("%s|%d|%s", path, size, tostring(embolden_factor))
    local cached = self.fallback_cache[key]
    if cached then return cached end
    local face = self:_buildFace(path, size, embolden_factor)
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

function FaceFactory:_addFallbacks(face, size, embolden_factor)
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
            local fb = self:_getFallbackFace(path, size, embolden_factor)
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
--- @param bold_level number|nil 0/1/2, see resolveBoldLevel
function FaceFactory:getFace(doc_font_name, size, variant, bold_level)
    variant = variant or "content"
    bold_level = tonumber(bold_level) or 0
    local key = string.format("%s|%d|%s|%d", doc_font_name or "", size or 0, variant, bold_level)
    local cached = self.face_cache[key]
    if cached then return cached end

    local ratio = self.VARIANTS[variant] or 1.0
    local v_size = math.max(8, math.floor(size * ratio + 0.5))
    local face

    local paths = self:getFontPaths(doc_font_name)
    local regular, italic
    for _, fp in ipairs(paths) do
        -- 仿粗统一走常规字形：cre 的「加粗」是 500（中等），换成真粗体会过重
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
    local synth = bold_level > 0
    local factor = synth and SYNTH_BOLD_FACTORS[bold_level >= 2 and 2 or 1] or nil

    if path then
        face = self:_buildFace(path, v_size, factor)
        if face then
            self:_addFallbacks(face, v_size, factor)
        end
    end

    -- Fallback when the document font cannot be resolved: use a bundled font
    -- (also hand-built to avoid the double DPI scaling).
    if not face then
        local fallback_path = resolveBundledFont(
            prefer_italic and "NotoSans-Italic.ttf" or "NotoSans-Regular.ttf")
            or resolveBundledFont("NotoSansCJKsc-Regular.otf")
        if fallback_path then
            face = self:_buildFace(fallback_path, v_size, factor)
            if face then
                self:_addFallbacks(face, v_size, factor)
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
