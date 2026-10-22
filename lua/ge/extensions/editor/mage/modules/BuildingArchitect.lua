-- =============================================================================
-- MaGE - Building Architect capture
-- Version: 1.0.2
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M      = {}
local logTag = 'mage'

local G       = require("editor/mage/core/Geometry")
local C       = require("editor/mage/core/Common")
local Modules = require("editor/mage/core/Modules")
local S       = require("editor/mage/config/Settings")
local Texture = require("editor/mage/core/Texture")
local mr      = G.mr
local tr      = C.tr

require("editor/mage/modules/Export")

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local worldModule = "/lua/ge/extensions/editor/gen/world"
local objPrefix   = "mageBAT_"
local matPrefix   = "mage_"
local matFile     = "mage_bat.materials.json"
local batMatDir   = "/art/shapes/common/building_architect_modules/bat_materials/"
local gameMatDir  = "/art/shapes/objects/"
local texRoot     = "/assets/materials/"
local wallFile    = "wall.mat.json"
local batMatFiles = {wallFile, "top.mat.json"}
local liveNames   = {adesc = true, dforest = true, fdata = true, cedit = true}
local texPrefix   = "mage_tex_"
local scanFile    = "/temp/mage/textures.json"
local batTex      = {cladding_zinc = "t_metal_cladded_zinc"}
local batWalls    = {"cladding_zinc_bat", "m_bricks_01_bat", "m_concrete_cinderblock_01_bat", "m_greybox_base_bat", "m_plaster_float_bat",
                     "m_plaster_raw_dirty_01_bat", "m_plaster_worn_01_bat", "m_stonebrick_eroded_01_bat", "m_stonebrick_mixed_02_bat",
                     "m_stonewall_damaged_01_bat", "m_stucco_scraped_01_bat", "m_stucco_white_bat"}
local batTops     = {"m_plaster_float_bat", "m_plaster_raw_dirty_01_bat", "m_plaster_worn_01_bat", "m_roof_slates_ochre_bat",
                     "m_roof_slates_rounded_bat", "m_roof_slates_square_bat", "m_stucco_scraped_01_bat", "m_stucco_white_bat"}

-- =============================================================================
-- STATE
-- =============================================================================

local defs    = nil
local fixedAt = nil
local texs    = nil
local texAll  = nil
local scan    = nil

-- =============================================================================
-- LIVE STATE
-- =============================================================================

local function live()
    local W = package.loaded[worldModule]
    if type(W) ~= "table" then return nil end
    local st = {}
    for _, fn in ipairs({W.forDesc, W.toLevel, W.forJSON}) do
        if type(fn) == "function" then
            for i = 1, 255 do
                local name, v = debug.getupvalue(fn, i)
                if not name then break end
                if liveNames[name] and st[name] == nil then st[name] = v end
            end
        end
    end
    if type(st.adesc) ~= "table" then return nil end
    st.dforest = type(st.dforest) == "table" and st.dforest or {}
    st.out     = W.out
    return st
end

local function buildings(st)
    local list = {}
    for id, desc in pairs(st.adesc) do
        if type(desc) == "table" and type(desc.data) == "table" and #desc.data > 0 then
            list[#list + 1] = {id = id, desc = desc}
        end
    end
    table.sort(list, function(a, b)
        local pa, pb = a.desc.prn ~= nil, b.desc.prn ~= nil
        if pa ~= pb then return pa end
        return tostring(a.id) < tostring(b.id)
    end)
    return list
end

local function dfTables(desc)
    local out = {}
    local function add(t)
        if type(t) == "table" and type(t.df) == "table" then out[#out + 1] = t.df end
    end
    add(desc)
    for _, f in pairs(type(desc.afloor) == "table" and desc.afloor or {}) do
        if type(f) == "table" then
            add(f)
            add(f.top)
            for _, w in pairs(type(f.awall) == "table" and f.awall or {}) do add(w) end
        end
    end
    return out
end

-- =============================================================================
-- MATERIALS
-- =============================================================================

local function copy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = copy(v) end
    return r
end

local function batDir()
    return batMatDir
end

local function companion(stem, ext, tails)
    for _, t in ipairs(tails) do
        local f = stem .. t .. ext
        if FS:fileExists(f) then return f end
    end
    return nil
end

local function gameDef(base)
    for _, f in ipairs({gameMatDir .. base .. "/main.materials.json", gameMatDir .. "main.materials.json"}) do
        local d = C.readJson(f)
        if type(d) == "table" and type(d[base]) == "table" and type(d[base].Stages) == "table" then
            local def = copy(d[base])
            local dir = f:match("^(.*/)[^/]*$")
            for _, st in ipairs(def.Stages) do
                for k, v in pairs(type(st) == "table" and st or {}) do
                    if type(k) == "string" and k:find("Map$") and type(v) == "string" and v ~= "" then
                        if v:sub(1, 2) == "./" then st[k] = dir .. v:sub(3) elseif not v:find("/") then st[k] = dir .. v end
                    end
                end
            end
            return def
        end
    end
    return nil
end

local function texOnly(base)
    local short = (base:gsub("^m_", ""))
    local stem  = batTex[short] or ("t_" .. short)
    local f     = (FS:findFiles(texRoot, stem .. "_b.color.*", -1, true, false) or {})[1]
    if not f then return nil end
    local p = tostring(f)
    if p:sub(1, 1) ~= "/" then p = "/" .. p end
    local s, ext = p:match("^(.-)_b(%.color%.[%w]+)$")
    if not s then return nil end
    local tail = ext:match("%.[^%.]+$")
    local st   = {baseColorMap = p, normalMap = companion(s, tail, {"_nm.normal"}), roughnessMap = companion(s, tail, {"_r.data"}),
                  ambientOcclusionMap = companion(s, tail, {"_ao.data"}), metallicMap = companion(s, tail, {"_m.data"})}
    return {class = "Material", version = 1.5, Stages = {st, {}, {}, {}}}
end

local function exists(p)
    if type(p) ~= "string" or p == "" or FS:fileExists(p) then return true end
    local alt = p:find("%.png$") and (p:gsub("%.png$", ".dds")) or (p:gsub("%.dds$", ".png"))
    return alt ~= p and FS:fileExists(alt)
end

local function broken(def)
    for _, st in ipairs(type(def.Stages) == "table" and def.Stages or {}) do
        if type(st) == "table" then
            for k, v in pairs(st) do
                if type(k) == "string" and k:find("Map$") and not exists(v) then return true end
            end
        end
    end
    return false
end

local function freshDef(name)
    local base = (name:gsub("_bat$", ""))
    return gameDef(base) or texOnly(base)
end

local function absolute(def)
    for k, v in pairs(def) do
        if type(v) == "table" then
            absolute(v)
        elseif type(v) == "string" and type(k) == "string" and k:find("Map$") and v ~= "" then
            if v:sub(1, 2) == "./" then
                def[k] = batDir() .. v:sub(3)
            elseif not v:find("/") then
                def[k] = batDir() .. v
            end
        end
    end
end

local function usable(def)
    if type(def) ~= "table" then return false end
    local probe = copy(def)
    absolute(probe)
    return not broken(probe)
end

local function batDefs()
    if defs then return defs end
    defs = {byName = {}, walls = {}, tops = {}}
    for _, f in ipairs(batMatFiles) do
        for name, def in pairs(C.readJson(batDir() .. f) or {}) do
            if type(def) == "table" and not usable(def) then def = freshDef(name) end
            if usable(def) then
                defs.byName[name] = def
                local list        = (f == wallFile) and defs.walls or defs.tops
                list[#list + 1] = name
            end
        end
    end
    if next(defs.byName) == nil then
        for _, pair in ipairs({{batWalls, defs.walls}, {batTops, defs.tops}}) do
            for _, name in ipairs(pair[1]) do
                local def = defs.byName[name] or freshDef(name)
                if def then
                    defs.byName[name]     = def
                    pair[2][#pair[2] + 1] = name
                end
            end
        end
    end
    table.sort(defs.walls)
    table.sort(defs.tops)
    return defs
end

local function copyName(name)
    return matPrefix .. name
end

local function isBat(name)
    return batDefs().byName[name] ~= nil
end

local function store(list)
    local levelPath = C.levelDir()
    if not levelPath then return false end
    local out = {}
    for _, e in ipairs(list) do
        local d         = copy(e.def)
        d.name, d.mapTo = e.name, e.name
        d.persistentId  = nil
        absolute(d)
        out[#out + 1] = {name = e.name, def = d}
    end
    return C.storeMaterials(levelPath .. mr.daeDir .. matFile, out)
end

local function refresh(name, old, new)
    local obj = scenetree.findObject(name)
    if not obj then return end
    for i = 1, 4 do
        local a = type(old.Stages) == "table" and type(old.Stages[i]) == "table" and old.Stages[i] or {}
        local b = new.Stages[i] or {}
        for k in pairs(a) do
            if type(k) == "string" and k:find("Map$") and b[k] == nil then editor.setMaterialProperty(obj, k, i - 1, "") end
        end
        for k, v in pairs(b) do
            if k:find("Map$") then editor.setMaterialProperty(obj, k, i - 1, v) end
        end
    end
end

local function install(names)
    local list = {}
    for _, name in ipairs(names) do
        local def = batDefs().byName[name]
        if def then list[#list + 1] = {name = copyName(name), def = def} end
    end
    return store(list)
end

local function texDef(path)
    local stem, ext = path:match("^(.-)_[dD](%.[%w%.]+)$")
    if stem and not ext:lower():find("normal", 1, true) then
        local tail = ext:match("%.[^%.]+$")
        return stem, {colorMap = path, normalMap = companion(stem, tail, {"_n", "_nm.normal", "_n.normal"}),
                      specularMap = companion(stem, tail, {"_s", "_s.color"}), vertColor = true, useAnisotropic = true}
    end
    stem, ext = path:match("^(.-)_[bB](%.color%.[%w]+)$")
    if stem then
        local tail = ext:match("%.[^%.]+$")
        return stem, {baseColorMap = path, normalMap = companion(stem, tail, {"_nm.normal"}),
                      roughnessMap = companion(stem, tail, {"_r.data"}), ambientOcclusionMap = companion(stem, tail, {"_ao.data"})}, true
    end
    return nil
end

local function levelNames()
    local out = {}
    for _, d in ipairs(FS:findFiles("/levels/", "*", 0, false, true) or {}) do
        local n = tostring(d):match("([^/]+)/?$")
        if n then out[#out + 1] = n end
    end
    table.sort(out)
    return out
end

local function levelsKey(levels)
    local parts = {}
    for _, l in ipairs(levels) do
        local st        = FS:stat("/levels/" .. l)
        parts[#parts + 1] = l .. ":" .. tostring(st and st.modtime)
    end
    return "2|" .. table.concat(parts, "|")
end

local function rooted(f)
    local p = tostring(f)
    return p:sub(1, 1) == "/" and p or "/" .. p
end

local function authored(st, dir)
    local out = {}
    for k, v in pairs(st) do
        if type(k) == "string" and not k:find("UseUV$") then
            if k:find("Map$") and type(v) == "string" and v ~= "" then
                if v:sub(1, 2) == "./" then v = dir .. v:sub(3) elseif not v:find("/") then v = dir .. v end
                if exists(v) then out[k] = v end
            elseif not k:find("Map$") then
                out[k] = copy(v)
            end
        end
    end
    return out
end

local function readOpacity(path, idx, own)
    local ok, d = pcall(jsonDecode, ((readFile(path) or ""):gsub("^\239\187\191", "")))
    if not ok or type(d) ~= "table" then return end
    local dir = path:match("^(.*/)[^/]*$") or "/"
    for _, def in pairs(d) do
        if type(def) == "table" and type(def.Stages) == "table" then
            local solid = Texture.jsonOpacity(def) == "opaque"
            for i, st in ipairs(def.Stages) do
                if type(st) == "table" then
                    for _, k in ipairs({"colorMap", "baseColorMap", "diffuseMap"}) do
                        if type(st[k]) == "string" and st[k] ~= "" then
                            local stem = Texture.stemOf(st[k])
                            idx[stem]  = idx[stem] or solid
                            if i == 1 and not own[stem] then
                                local s = authored(st, dir)
                                if s[k] then own[stem] = {st = s, version = def.version} end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function scanLevel(lvl)
    local dir, own = "/levels/" .. lvl .. "/", {}
    for _, f in ipairs(FS:findFiles(dir, "*.materials.json", -1, true, false) or {}) do readOpacity(rooted(f), scan.idx, own) end
    for _, pat in ipairs({"*_d.*", "*_b.color.*"}) do
        for _, f in ipairs(FS:findFiles(dir, pat, -1, true, false) or {}) do
            local path          = rooted(f)
            local stem, st, pbr = nil, nil, nil
            if Texture.isImage(path) then stem, st, pbr = texDef(path) end
            local src = stem and own[Texture.stemOf(path)]
            if src then
                st, pbr = src.st, src.version == 1.5
            elseif stem and not exists(path) then
                stem = nil
            end
            if stem then
                local base = stem:match("[^/]+$"):lower()
                local name = texPrefix .. base:gsub("[^%w_]", "_")
                if not scan.raw[name] then
                    local def = {class = "Material", Stages = {st, {}, {}, {}}}
                    if pbr then def.version = 1.5 end
                    scan.raw[name] = {name = name, def = def, path = path, lvl = lvl, base = base}
                end
            end
        end
    end
end

local function scanStart()
    if scan then return scan end
    local levels = levelNames()
    local cache  = C.readJson(scanFile)
    local key    = levelsKey(levels)
    if cache and cache.key == key and type(cache.raw) == "table" then
        scan = {levels = levels, key = key, at = #levels + 1, raw = cache.raw, idx = type(cache.idx) == "table" and cache.idx or {}, done = true, ver = 1}
        return scan
    end
    scan = {levels = levels, key = key, at = 1, raw = {}, idx = {}, done = #levels == 0, ver = 1}
    return scan
end

local function scanStep()
    local sc = scanStart()
    if sc.done then return true end
    scanLevel(sc.levels[sc.at])
    sc.at, sc.ver = sc.at + 1, sc.ver + 1
    if sc.at > #sc.levels then
        sc.done = true
        C.writeJson(scanFile, {key = sc.key, raw = sc.raw, idx = sc.idx})
    end
    return sc.done
end

local function scanAll()
    while not scanStep() do end
end

local function scanning()
    return not scanStart().done
end

local function allTextures()
    local sc = scanStart()
    if texAll and texAll.ver == sc.ver then return texAll end
    texAll     = {ver = sc.ver}
    local here = (C.levelDir() or ""):lower()
    for _, e in pairs(sc.raw) do
        if not here:find("/levels/" .. e.lvl:lower() .. "/", 1, true) then
            local axes, set = Texture.axesOf(e.base)
            texAll[#texAll + 1] = {name = e.name, def = e.def, axes = set, kinds = #axes, path = e.path,
                                   solid = sc.idx[Texture.stemOf(e.path)] ~= false,
                                   label = e.base:gsub("^t_", ""):gsub("_", " ") .. " (" .. e.lvl .. ")"}
        end
    end
    table.sort(texAll, function(a, b) return a.label < b.label end)
    return texAll
end

local function textures()
    local all = allTextures()
    if texs and texs.ver == all.ver then return texs end
    texs = {ver = all.ver}
    for _, e in ipairs(all) do
        if e.kinds > 0 and e.solid then texs[#texs + 1] = e end
    end
    return texs
end

local function texturesFor(axis)
    local out = {}
    for _, e in ipairs(textures()) do
        if e.axes[axis] then out[#out + 1] = e end
    end
    return out
end

local function useTex(name)
    if not scanStart().raw[name] then scanAll() end
    for _, e in ipairs(allTextures()) do
        if e.name == name then return store({e}) and ("@" .. name) or nil end
    end
    return nil
end

local function unstore(names)
    local levelPath = C.levelDir()
    if not levelPath or #names == 0 then return end
    local file = levelPath .. mr.daeDir .. matFile
    local cur  = C.readJson(file)
    if not cur then return end
    for _, n in ipairs(names) do cur[n] = nil end
    C.writeJson(file, cur)
end

local function isTex(name)
    return type(name) == "string" and name:sub(1, #texPrefix) == texPrefix
end

local function repair()
    local levelPath = C.levelDir()
    if not levelPath or fixedAt == levelPath then return 0 end
    fixedAt    = levelPath
    local file = levelPath .. mr.daeDir .. matFile
    local cur  = C.readJson(file)
    if type(cur) ~= "table" then return 0 end
    local fixed, stale = {}, {}
    for name, def in pairs(cur) do
        local base = type(name) == "string" and type(def) == "table" and name:sub(1, #matPrefix) == matPrefix and name:sub(#matPrefix + 1)
        local new  = base and batDefs().byName[base]
        if new and broken(def) and usable(new) then
            local d         = copy(new)
            d.name, d.mapTo = name, name
            d.persistentId  = nil
            absolute(d)
            cur[name]         = d
            fixed[#fixed + 1] = {name = name, old = def, new = d}
        elseif isTex(name) and type(def) == "table" and broken(def) then
            stale[#stale + 1] = name
        end
    end
    if #stale > 0 then
        scanAll()
        for _, name in ipairs(stale) do
            local e = scan.raw[name]
            if e and not broken(e.def) then
                local d         = copy(e.def)
                d.name, d.mapTo = name, name
                fixed[#fixed + 1] = {name = name, old = cur[name], new = d}
                cur[name]         = d
            end
        end
    end
    if #fixed == 0 or not C.writeJson(file, cur) then return 0 end
    for _, e in ipairs(fixed) do refresh(e.name, e.old, e.new) end
    return #fixed
end

local function wallMaterials()
    return batDefs().walls
end

local function roofMaterials()
    return batDefs().tops
end

local function use(name)
    repair()
    if batDefs().byName[name] then
        if not install({name}) then return nil end
        return "@" .. copyName(name)
    end
    return scenetree.findObject(name) and ("@" .. name) or nil
end

function mr.batMat(mat)
    if isTex(mat) then
        repair()
        local levelPath = C.levelDir()
        local def       = levelPath and (C.readJson(levelPath .. mr.daeDir .. matFile) or {})[mat]
        if type(def) == "table" and broken(def) then return nil end
        return mat
    end
    if type(mat) ~= "string" or mat:sub(1, #matPrefix) ~= matPrefix or mat:sub(-4) ~= "_bat" then return mat end
    local name = mat:sub(#matPrefix + 1)
    repair()
    if batDefs().byName[name] then return mat end
    return scenetree.findObject(name) and name or nil
end

local function ensure(text, missing)
    for name in tostring(text or ""):gmatch("@([%w_]+)") do
        if not scenetree.findObject(name) then
            local ok = nil
            if isTex(name) then
                ok = useTex(name)
            elseif name:sub(1, #matPrefix) == matPrefix and name:sub(-4) == "_bat" then
                ok = use(name:sub(#matPrefix + 1))
            end
            if not ok and missing then missing[name] = true end
        end
    end
    return text
end

local function labelOf(name)
    local base = name:sub(1, #matPrefix) == matPrefix and name:sub(#matPrefix + 1) or name
    return (base:gsub("^m_", ""):gsub("_bat$", ""):gsub("_", " "))
end

-- =============================================================================
-- MODULES
-- =============================================================================

local function cross(a, b)
    return {x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x}
end

local function place(sm, item)
    local pos        = item:getPosition()
    local s          = item:getScale()
    local t          = item:getTransform()
    local c1, c2, c3 = t:getColumn(0), t:getColumn(1), t:getColumn(2)
    local n1, n2, n3 = cross(c2, c3), cross(c3, c1), cross(c1, c2)
    local det        = (c1.x * n1.x + c1.y * n1.y + c1.z * n1.z) * s
    local sign       = det < 0 and -1 or 1
    local out        = {verts = {}, normals = {}, uvs = sm.uvs, uvs2 = sm.uvs2, faces = {}, material = sm.material, tint = sm.tint}
    for i, v in ipairs(sm.verts) do
        out.verts[i] = vec3(pos.x + (c1.x * v.x + c2.x * v.y + c3.x * v.z) * s,
                            pos.y + (c1.y * v.x + c2.y * v.y + c3.y * v.z) * s,
                            pos.z + (c1.z * v.x + c2.z * v.y + c3.z * v.z) * s)
    end
    for i, n in ipairs(sm.normals) do
        local w = vec3(n1.x * n.x + n2.x * n.y + n3.x * n.z,
                       n1.y * n.x + n2.y * n.y + n3.y * n.z,
                       n1.z * n.x + n2.z * n.y + n3.z * n.z) * sign
        out.normals[i] = w:normalized()
    end
    local f = sm.faces
    for k = 1, #f - 2, 3 do
        if det < 0 then
            out.faces[#out.faces + 1], out.faces[#out.faces + 2], out.faces[#out.faces + 3] = f[k], f[k + 2], f[k + 1]
        else
            out.faces[#out.faces + 1], out.faces[#out.faces + 2], out.faces[#out.faces + 3] = f[k], f[k + 1], f[k + 2]
        end
    end
    return out
end

-- =============================================================================
-- BAKE
-- =============================================================================

local function backOf(sm)
    local out = {verts = sm.verts, uvs = sm.uvs, normals = {}, faces = {}, material = sm.material}
    for i, n in ipairs(sm.normals) do out.normals[i] = vec3(-n.x, -n.y, -n.z) end
    local f = sm.faces
    for k = 1, #f - 2, 3 do
        out.faces[#out.faces + 1], out.faces[#out.faces + 2], out.faces[#out.faces + 3] = f[k], f[k + 2], f[k + 1]
    end
    return out
end

local function meshesOf(desc, st, used)
    local walls, mods, mods2 = {}, {}, {}
    local placed, lost       = 0, 0
    for _, sm in ipairs(desc.data) do
        if type(sm) == "table" and type(sm.verts) == "table" and type(sm.faces) == "table" then
            local w = {verts = sm.verts, normals = sm.normals, uvs = sm.uvs, faces = sm.faces, material = sm.material}
            if w.material and isBat(w.material) then
                used[w.material] = true
                w.material       = copyName(w.material)
            end
            walls[#walls + 1] = w
            if S.buildingArchitect.backFaces then walls[#walls + 1] = backOf(w) end
        end
    end
    for _, df in ipairs(dfTables(desc)) do
        for dae, list in pairs(df) do
            if type(dae) == "string" and type(list) == "table" then
                for _, key in ipairs(list) do
                    local e = st.dforest[key]
                    local m = e and e.item and Modules.model(dae)
                    if m then
                        for _, sm in ipairs(m.meshes) do
                            local p = place(sm, e.item)
                            if p.uvs2 then mods2[#mods2 + 1] = p else mods[#mods + 1] = p end
                        end
                        placed = placed + 1
                    else
                        lost = lost + 1
                    end
                end
            end
        end
    end
    return walls, mods, mods2, placed, lost
end

local function release(id, desc, st)
    for _, df in ipairs(dfTables(desc)) do
        for dae, list in pairs(df) do
            if type(dae) == "string" and type(list) == "table" then
                for _, key in ipairs(list) do
                    local e = st.dforest[key]
                    if e and e.item and st.fdata then editor.removeForestItem(st.fdata, e.item) end
                    st.dforest[key] = nil
                    if type(st.cedit) == "table" and st.cedit.forest == key then st.cedit.forest = nil end
                end
                df[dae] = {scale = list.scale, span = list.span, fitx = list.fitx}
            end
        end
    end
    local parent = desc.prn and st.adesc[desc.prn]
    local floor  = type(parent) == "table" and type(parent.afloor) == "table" and parent.afloor[(desc.floor or 0) - 1]
    if type(floor) == "table" and type(floor.achild) == "table" then
        for k = #floor.achild, 1, -1 do
            local c = floor.achild[k]
            if type(c) == "table" and c.id == id then table.remove(floor.achild, k) end
        end
    end
    if type(st.cedit) == "table" and st.cedit.mesh == id then
        local group = scenetree.findObject('edit')
        if group then group:deleteAllObjects() end
        st.cedit.mesh = nil
        if type(st.out) == "table" then st.out.avedit, st.out.dyell, st.out.fmtop = {}, nil, nil end
    end
    local obj = scenetree.findObjectById(id)
    if obj then obj:delete() end
    st.adesc[id] = nil
end

local function freeName(levelPath)
    local n = 1
    while scenetree.findObject(objPrefix .. n) or C.fileExists(levelPath .. mr.daeDir .. objPrefix .. n .. ".dae") do
        n = n + 1
    end
    return objPrefix .. n
end

local function bake()
    local levelPath = C.levelDir()
    if not levelPath then return "no level loaded" end
    local st = live()
    if not st then return "Building Architect is not open" end
    local list = buildings(st)
    if #list == 0 then return "no buildings in Building Architect yet" end

    local written, tris, modules, unread = 0, 0, 0, 0
    for _, b in ipairs(list) do
        local used                             = {}
        local walls, mods, mods2, placed, lost = meshesOf(b.desc, st, used)
        local minX, minY, maxX, maxY           = math.huge, math.huge, -math.huge, -math.huge
        for _, sm in ipairs(walls) do
            for _, v in ipairs(sm.verts) do
                minX, maxX = math.min(minX, v.x), math.max(maxX, v.x)
                minY, maxY = math.min(minY, v.y), math.max(maxY, v.y)
            end
        end
        local names = {}
        for n in pairs(used) do names[#names + 1] = n end
        table.sort(names)
        repair()
        install(names)
        local entries = {{road = {name = "walls"}, meshes = walls, keepNormals = true}}
        if #mods > 0 then entries[#entries + 1] = {road = {name = "modules"}, meshes = mods, keepNormals = true} end
        if #mods2 > 0 then entries[#entries + 1] = {road = {name = "modules_uv"}, meshes = mods2, keepNormals = true, secondUv = true} end
        local origin    = {x = (minX + maxX) / 2, y = (minY + maxY) / 2}
        local key       = freeName(levelPath)
        local file      = levelPath .. mr.daeDir .. key .. ".dae"
        local xml, _, t = mr.buildDae(entries, origin)
        if (t or 0) > 0 and mr.writeChecked(file, xml) then
            mr.placeStatic(file, key, vec3(origin.x, origin.y, 0))
            release(b.id, b.desc, st)
            written, tris   = written + 1, tris + t
            modules, unread = modules + placed, unread + lost
        else
            log('E', logTag, "writing failed: " .. file)
        end
    end
    editor.setDirty()
    local status = tr("saved %d buildings with %d windows and doors, %d triangles", written, modules, tris)
    if unread > 0 then status = status .. ", " .. tr("%d windows or doors could not be read", unread) end
    return status
end

local function counts()
    local st = live()
    if not st then return nil end
    return #buildings(st)
end

local function reset()
    defs, fixedAt, texs, texAll, scan = nil, nil, nil, nil, nil
    Texture.reset()
    Modules.reset()
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.bake          = bake
M.counts        = counts
M.reset         = reset
M.wallMaterials = wallMaterials
M.use           = use
M.roofMaterials = roofMaterials
M.labelOf       = labelOf
M.copyName      = copyName
M.texturesFor   = texturesFor
M.allTextures   = allTextures
M.scanStep      = scanStep
M.scanning      = scanning
M.unstore       = unstore
M.useTex        = useTex
M.isTex         = isTex
M.ensure        = ensure
M.repair        = repair

return M
