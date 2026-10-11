-- =============================================================================
-- MaGE - shared helpers
-- Version: 1.0.1
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local bit                        = require("bit")
local band, bor, bxor, bnot      = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, rol, tobit = bit.lshift, bit.rshift, bit.rol, bit.tobit

-- =============================================================================
-- TRANSLATION
-- =============================================================================

local function transKey(s)
    local k = s:lower():gsub("[^0-9a-z]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    return "mage.ui." .. k:sub(1, 60)
end

local function isRtlText(s)
    return type(s) == "string" and s:find("[\214\215\216\217]") ~= nil
end

local function lookup(s)
    if type(s) ~= "string" or s == "" or isRtlText(s) then return s end
    local v = core_locales.translate(transKey(s), s)
    if type(v) == "string" and v ~= "" then return v end
    return s
end

local function tr(f, ...)
    local s = lookup(f)
    if select("#", ...) == 0 then return s end
    local ok, out = pcall(string.format, s, ...)
    if ok then return out end
    local ok2, out2 = pcall(string.format, f, ...)
    return ok2 and out2 or f
end

-- =============================================================================
-- UTILITIES
-- =============================================================================

local function levelDir()
    local mission = getMissionFilename()
    if not mission or mission == "" then return nil end
    return mission:match("^(.*/)[^/]*$")
end

local function readJson(path)
    local ok, data = pcall(jsonReadFile, path)
    if ok and type(data) == "table" then return data end
    return nil
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function v3(p) return vec3(p.x, p.y, p.z) end

local md5K, md5S = {}, {
    7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
    5, 9,14,20, 5, 9,14,20, 5, 9,14,20, 5, 9,14,20,
    4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
    6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21,
}
for i = 0, 63 do
    md5K[i + 1] = tobit(math.floor(math.abs(math.sin(i + 1)) * 4294967296))
end

local function md5(msg)
    local len = #msg
    msg       = msg .. string.char(0x80) .. string.rep("\0", (55 - len) % 64)

    local bits = len * 8
    for i = 0, 3 do
        msg = msg .. string.char(band(rshift(bits, i * 8), 0xFF))
    end
    msg = msg .. string.char(0, 0, 0, 0)

    local a0, b0, c0, d0 = tobit(0x67452301), tobit(0xefcdab89),
                           tobit(0x98badcfe), tobit(0x10325476)
    for chunk = 0, #msg / 64 - 1 do
        local M = {}
        for j = 0, 15 do
            local o              = chunk * 64 + j * 4
            local b1, b2, b3, b4 = msg:byte(o + 1, o + 4)
            M[j]                 = tobit(bor(b1, lshift(b2, 8), lshift(b3, 16), lshift(b4, 24)))
        end
        local A, B, C, D = a0, b0, c0, d0
        for i = 0, 63 do
            local F, g
            if i < 16 then
                F = bor(band(B, C), band(bnot(B), D)); g = i
            elseif i < 32 then
                F = bor(band(D, B), band(bnot(D), C)); g = (5 * i + 1) % 16
            elseif i < 48 then
                F = bxor(B, bxor(C, D));               g = (3 * i + 5) % 16
            else
                F = bxor(C, bor(B, bnot(D)));          g = (7 * i) % 16
            end
            F = tobit(F + A + md5K[i + 1] + M[g])
            A = D; D = C; C = B
            B = tobit(B + rol(F, md5S[i + 1]))
        end
        a0 = tobit(a0 + A); b0 = tobit(b0 + B)
        c0 = tobit(c0 + C); d0 = tobit(d0 + D)
    end

    local function hex(w)
        local out = {}
        for i = 0, 3 do
            out[#out + 1] = string.format("%02x", band(rshift(w, i * 8), 0xFF))
        end
        return table.concat(out)
    end
    return hex(a0) .. hex(b0) .. hex(c0) .. hex(d0)
end

local fieldPrefix     = "mage_"
local legacyPrefix    = "pit_"
local styleFile       = "mage_styles.json"
local legacyStyleFile = "pit_sidewalk_styles.json"

local function fileExists(path)
    return FS:fileExists(path)
end

local function fieldName(name)
    if type(name) == "string" and name:sub(1, #legacyPrefix) == legacyPrefix then
        return fieldPrefix .. name:sub(#legacyPrefix + 1)
    end
    return name
end

local function legacyField(name)
    if type(name) == "string" and name:sub(1, #fieldPrefix) == fieldPrefix then
        return legacyPrefix .. name:sub(#fieldPrefix + 1)
    end
    return nil
end

local function stylePathIn(dir)
    local path = dir .. styleFile
    if not fileExists(path) and fileExists(dir .. legacyStyleFile) then return dir .. legacyStyleFile end
    return path
end

local function removeFile(path)
    if not fileExists(path) then return false end
    return FS:removeFile(path) == 0
end

local function hash(str)
    return hashStringSHA256(str)
end

local function writeJson(path, data)
    local ok, res = pcall(jsonWriteFile, path, data, true)
    return ok and res ~= false
end

local objectHistory = nil

local function history()
    objectHistory = objectHistory or require("editor/api/objectHistoryActions")()
    return objectHistory
end

local function setDynWithUndo(ids, field, value)
    history().changeObjectDynFieldWithUndo(ids, field, value, 0)
end

local function setFieldWithUndo(ids, field, value)
    history().changeObjectFieldWithUndo(ids, field, value)
end

local function md5Prefix32(str)
    local h = md5(str)
    local v = 0
    for i = 1, 8 do
        v = v * 16 + tonumber(h:sub(i, i), 16)
    end
    return v
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.isRtlText   = isRtlText
M.lookup      = lookup
M.tr          = tr
M.levelDir    = levelDir
M.readJson    = readJson
M.writeJson   = writeJson
M.fileExists  = fileExists
M.fieldName   = fieldName
M.legacyField = legacyField
M.stylePathIn = stylePathIn

M.fieldPrefix      = fieldPrefix
M.styleFile        = styleFile
M.legacyStyleFile  = legacyStyleFile
M.md5              = md5
M.clamp            = clamp
M.v3               = v3
M.md5Prefix32      = md5Prefix32
M.removeFile       = removeFile
M.hash             = hash
M.setDynWithUndo   = setDynWithUndo
M.setFieldWithUndo = setFieldWithUndo

return M
