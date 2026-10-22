-- =============================================================================
-- MaGE - texture choices: value format, placement, sources and saved configurations
-- Version: 1.0.2
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local C = require("editor/mage/core/Common")

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local libFile  = "/settings/mage/textures.json"
local kinds    = {"wall", "walk", "curb", "roof"}
local turns    = {[0] = true, [90] = true, [180] = true, [270] = true}
local imageExt = {dds = true, png = true, jpg = true, jpeg = true}

local deny = {
    "annotation", "checkpoint", "marker", "invisible", "unmapped", "noshape", "default",
    "editor", "debug", "test", "lod", "decal", "damage", "eroded", "destroyed", "leak",
    "dirty", "objects", "glass", "window", "wire", "chainlink", "transparent", "tire",
    "curtain", "trim", "atlas", "macro", "blend",
}

local roofWords = {"roof", "shingle"}

local rules = {
    {axis = "curb", rank = 1, keys = {"curb", "kerb", "gutter"}},
    {axis = "walk", rank = 1, keys = {"sidewalk", "pavement", "walkway"}},
    {axis = "walk", rank = 2, keys = {"slab", "paver", "floortile"}},
    {axis = "walk", rank = 3, keys = {"tiles", "cobble"}},
    {axis = "wall", rank = 1, keys = {"concrete", "retaining"}},
    {axis = "wall", rank = 2, keys = {"stone", "wall", "blockwall"}},
    {axis = "wall", rank = 3, keys = {"brick", "cladding", "plaster", "stucco", "planks", "corrugated"}},
    {axis = "roof", rank = 1, keys = {"roof", "shingle", "slate"}},
}

local known = {
    italy_bld_roof_tiles          = 2.0,
    mage_tex_italy_bld_roof_tiles = 2.0,
}

local nonCovering = {Add = true, AddAlpha = true, Mul = true, Sub = true, PreMulAlpha = true}

-- =============================================================================
-- STATE
-- =============================================================================

local lib     = nil
local infos   = {}
local kindsOf = {}

-- =============================================================================
-- VALUE
-- =============================================================================

local function num(s)
    local v = tonumber(s)
    if v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end

local function turnOf(r)
    r = math.floor((num(r) or 0) / 90 + 0.5) * 90 % 360
    return turns[r] and r or 0
end

local function parse(value)
    if type(value) ~= "string" or value:sub(1, 1) ~= "@" then return nil end
    local parts = {}
    for p in (value:sub(2) .. ";"):gmatch("([^;]*);") do parts[#parts + 1] = p end
    if parts[1] == "" then return nil end
    local u, v = num(parts[2]), num(parts[3])
    if u and u <= 0 then u = nil end
    if v and v <= 0 then v = nil end
    return {mat = parts[1], u = u, v = v, rot = turnOf(parts[4]), ou = num(parts[5]) or 0.0, ov = num(parts[6]) or 0.0}
end

local function fmt(x)
    if not x then return "" end
    return string.format("%.4g", x)
end

local function encode(t)
    local out = "@" .. t.mat
    local rot = turnOf(t.rot)
    if t.u or t.v or rot ~= 0 or (t.ou or 0) ~= 0 or (t.ov or 0) ~= 0 then
        out = out .. ";" .. fmt(t.u) .. ";" .. fmt(t.v) .. ";" .. rot .. ";" .. fmt(t.ou or 0) .. ";" .. fmt(t.ov or 0)
    end
    return out
end

local function material(value)
    local t = parse(value)
    return t and t.mat or nil
end

local function raw(value, tile)
    local t = parse(value)
    if not t then return nil end
    local scale = {tile, tile}
    if t.u or t.v then scale = {t.u or t.v, t.v or t.u} end
    return {material = t.mat, scale = scale, rot = t.rot, off = {t.ou, t.ov}}
end

-- =============================================================================
-- PLACEMENT
-- =============================================================================

local function moved(st)
    if not st then return false end
    local off = st.off or {}
    return turnOf(st.rot) ~= 0 or (off[1] or 0) ~= 0 or (off[2] or 0) ~= 0
end

local function sig(st)
    if not moved(st) then return "" end
    local off = st.off or {}
    return "|" .. turnOf(st.rot) .. "|" .. fmt(off[1] or 0) .. "|" .. fmt(off[2] or 0)
end

local function place(a, c, su, sv, st)
    local r   = turnOf(st and st.rot)
    local off = st and st.off or {}
    if r == 90 then a, c = c, -a elseif r == 180 then a, c = -a, -c elseif r == 270 then a, c = -c, a end
    return (a + (off[1] or 0)) / su, (c + (off[2] or 0)) / sv
end

local function apply(sm, su, sv, st, flip)
    if not moved(st) then return end
    for _, t in ipairs(sm.uvs) do
        local v    = flip and (1.0 - t.v) or t.v
        local a, b = place(t.u * su, v * sv, su, sv, st)
        t.u, t.v   = a, flip and (1.0 - b) or b
    end
    sm.uvs2 = nil
end

-- =============================================================================
-- SOURCES
-- =============================================================================

local function opacity(get)
    local function on(k)
        local v = get(k)
        return v == true or v == 1 or v == "1" or v == "true"
    end
    local function filled(k)
        local v = get(k)
        return v ~= nil and v ~= ""
    end
    if on("alphaTest") or filled("opacityMap") or filled("opacityDetailMap") then return "cutout" end
    local of = num(get("opacityFactor") or "1")
    if of and of < 1 then return "faded" end
    if on("emissive") then return "glow" end
    local op = get("translucentBlendOp")
    if op and nonCovering[op] then return "glow" end
    if op == "LerpAlpha" and not on("translucentZWrite") then return "blended" end
    return "opaque"
end

local function jsonOpacity(def)
    local stage = type(def.Stages) == "table" and type(def.Stages[1]) == "table" and def.Stages[1] or {}
    return opacity(function(k)
        if k == "translucentBlendOp" and def.translucent ~= true and def.translucent ~= "1" then return nil end
        local v = def[k]
        if v == nil then v = stage[k] end
        return v
    end)
end

local function denied(n, axis)
    for _, d in ipairs(deny) do
        if n:find(d, 1, true) then return true end
    end
    if axis ~= "roof" then
        for _, w in ipairs(roofWords) do
            if n:find(w, 1, true) then return true end
        end
    end
    return false
end

local function info(name)
    local hit = infos[name]
    if hit ~= nil then return hit or nil end
    local n = name:lower()
    for _, r in ipairs(rules) do
        if r.axis ~= "roof" and not denied(n, r.axis) then
            for _, k in ipairs(r.keys) do
                if n:find(k, 1, true) then
                    infos[name] = {axis = r.axis, key = k, rank = r.rank}
                    return infos[name]
                end
            end
        end
    end
    infos[name] = false
    return nil
end

local function axesOf(name)
    local hit = kindsOf[name]
    if hit then return hit[1], hit[2] end
    local n, out, seen = name:lower(), {}, {}
    for _, r in ipairs(rules) do
        if not seen[r.axis] and not denied(n, r.axis) then
            for _, k in ipairs(r.keys) do
                if n:find(k, 1, true) then
                    seen[r.axis], out[#out + 1] = true, r.axis
                    break
                end
            end
        end
    end
    kindsOf[name] = {out, seen}
    return out, seen
end

local function isImage(path)
    local ext = path:lower():match("%.(%w+)$")
    return ext ~= nil and imageExt[ext] == true
end

local function stemOf(path)
    local f = tostring(path):lower():gsub("\\", "/"):match("[^/]+$") or ""
    return (f:gsub("%.color%.%w+$", ""):gsub("%.%w+$", ""))
end

local function knownSize(name)
    return known[name]
end

-- =============================================================================
-- LIBRARY
-- =============================================================================

local function cleanEntry(e)
    if type(e) ~= "table" or type(e.mat) ~= "string" or e.mat == "" then return nil end
    local out = {label = type(e.label) == "string" and e.label or nil, mat = e.mat, rot = turnOf(e.rot), ou = num(e.ou) or 0, ov = num(e.ov) or 0, cats = {}}
    if type(e.bat) == "string" and e.bat ~= "" then out.bat = e.bat end
    if type(e.tex) == "string" and e.tex ~= "" then out.tex = e.tex end
    local u, v = num(e.u), num(e.v)
    if u and u > 0 then out.u = u end
    if v and v > 0 then out.v = v end
    for _, k in ipairs(type(e.cats) == "table" and e.cats or {}) do
        if type(k) == "string" then out.cats[#out.cats + 1] = k end
    end
    return out
end

local function library()
    if lib then return lib end
    local d = C.readJson(libFile) or {}
    lib     = {configs = {}}
    for k, e in pairs(type(d.configs) == "table" and d.configs or {}) do
        if type(k) == "string" then lib.configs[k] = cleanEntry(e) end
    end
    return lib
end

local function saveLibrary()
    return C.writeJson(libFile, library())
end

local function slug(s)
    local k = tostring(s):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    return (k ~= "") and k or "config"
end

local function inKind(entry, kind)
    for _, k in ipairs(entry.cats or {}) do
        if k == kind then return true end
    end
    return false
end

local function norm(s)
    return (tostring(s or ""):lower():gsub("[_%s]+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local function matches(query, ...)
    local q = norm(query)
    if q == "" then return true end
    local hay = {}
    for _, s in ipairs({...}) do hay[#hay + 1] = norm(s) end
    local text = " " .. table.concat(hay, " ") .. " "
    for w in q:gmatch("%S+") do
        if not text:find(w, 1, true) then return false end
    end
    return true
end

local function pinDefault(data, axis)
    local ax = data[axis]
    if (axis ~= "walk" and axis ~= "curb") or not ax or ax.default or not ax.styles then return end
    local names, total = {}, 0
    for k, st in pairs(ax.styles) do
        if (axis == "walk" and st.material) or (axis == "curb" and st.sequence == nil) then
            names[#names + 1] = k
            total             = total + (st.weight or 0)
        end
    end
    if #names == 0 or total > 0 then return end
    table.sort(names)
    ax.default = names[1]
end

local function reset()
    lib, infos, kindsOf = nil, {}, {}
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.kinds       = kinds
M.parse       = parse
M.encode      = encode
M.material    = material
M.raw         = raw
M.moved       = moved
M.sig         = sig
M.place       = place
M.apply       = apply
M.turnOf      = turnOf
M.opacity     = opacity
M.jsonOpacity = jsonOpacity
M.info        = info
M.axesOf      = axesOf
M.isImage     = isImage
M.stemOf      = stemOf
M.knownSize   = knownSize
M.library     = library
M.saveLibrary = saveLibrary
M.slug        = slug
M.inKind      = inKind
M.pinDefault  = pinDefault
M.norm        = norm
M.matches     = matches
M.reset       = reset

return M
