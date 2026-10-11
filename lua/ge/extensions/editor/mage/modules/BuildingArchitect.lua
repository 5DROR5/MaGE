-- =============================================================================
-- MaGE - Building Architect capture
-- Version: 1.0.1
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M      = {}
local logTag = 'mage'

local G       = require("editor/mage/core/Geometry")
local C       = require("editor/mage/core/Common")
local Modules = require("editor/mage/core/Modules")
local S       = require("editor/mage/config/Settings")
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
local wallFile    = "wall.mat.json"
local batMatFiles = {wallFile, "top.mat.json"}
local liveNames   = {adesc = true, dforest = true, fdata = true, cedit = true}

-- =============================================================================
-- STATE
-- =============================================================================

local defs = nil

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

local function batDefs()
    if defs then return defs end
    defs = {byName = {}, walls = {}, tops = {}}
    for _, f in ipairs(batMatFiles) do
        for name, def in pairs(C.readJson(batMatDir .. f) or {}) do
            if type(def) == "table" then
                defs.byName[name] = def
                local list        = (f == wallFile) and defs.walls or defs.tops
                list[#list + 1] = name
            end
        end
    end
    table.sort(defs.walls)
    table.sort(defs.tops)
    return defs
end

local function absolute(def)
    for k, v in pairs(def) do
        if type(v) == "table" then
            absolute(v)
        elseif type(v) == "string" and type(k) == "string" and k:find("Map$") and v ~= "" then
            if v:sub(1, 2) == "./" then
                def[k] = batMatDir .. v:sub(3)
            elseif not v:find("/") then
                def[k] = batMatDir .. v
            end
        end
    end
end

local function copyName(name)
    return matPrefix .. name
end

local function isBat(name)
    return batDefs().byName[name] ~= nil
end

local function install(names)
    local levelPath = C.levelDir()
    if not levelPath then return false end
    local file             = levelPath .. mr.daeDir .. matFile
    local cur              = C.readJson(file) or {}
    local changed, missing = false, false
    for _, name in ipairs(names) do
        local def = batDefs().byName[name]
        local new = copyName(name)
        if def then
            if not cur[new] then
                local d         = copy(def)
                d.name, d.mapTo = new, new
                d.persistentId  = nil
                absolute(d)
                cur[new] = d
                changed  = true
            end
            if not scenetree.findObject(new) then missing = true end
        end
    end
    if changed and not C.writeJson(file, cur) then return false end
    if missing then loadJsonMaterialsFile(file) end
    return true
end

local function wallMaterials()
    return batDefs().walls
end

local function roofMaterials()
    return batDefs().tops
end

local function use(name)
    if not install({name}) then return nil end
    return "@" .. copyName(name)
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
    local out        = {verts = {}, normals = {}, uvs = sm.uvs, uvs2 = sm.uvs2, faces = {}, material = sm.material}
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
    local placed, broken     = 0, 0
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
                        broken = broken + 1
                    end
                end
            end
        end
    end
    return walls, mods, mods2, placed, broken
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

    local written, tris, modules, broken = 0, 0, 0, 0
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
            modules, broken = modules + placed, broken + lost
        else
            log('E', logTag, "writing failed: " .. file)
        end
    end
    editor.setDirty()
    local status = tr("saved %d buildings with %d windows and doors, %d triangles", written, modules, tris)
    if broken > 0 then status = status .. ", " .. tr("%d windows or doors could not be read", broken) end
    return status
end

local function counts()
    local st = live()
    if not st then return nil end
    return #buildings(st)
end

local function reset()
    defs = nil
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

return M
