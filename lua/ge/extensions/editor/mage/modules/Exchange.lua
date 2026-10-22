-- =============================================================================
-- MaGE - export and import of buildings
-- Version: 1.0.2
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local B       = require("editor/mage/modules/Building")
local E       = require("editor/mage/modules/Export")
local C       = require("editor/mage/core/Common")
local G       = require("editor/mage/core/Geometry")
local Window  = require("editor/mage/core/Window")
local Texture = require("editor/mage/core/Texture")
local mr      = G.mr

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local root      = "/art/shapes/mage/exports/"
local ext       = ".mage.json"
local version   = 1
local listAge   = 2.0
local importDir = "art/shapes/mage/imported/"
local images    = {png = true, dds = true, jpg = true, jpeg = true, tga = true}
local plainMods = {windows = true, doors = true, roof = true}

-- =============================================================================
-- STATE
-- =============================================================================

local listed = nil

-- =============================================================================
-- NAMES
-- =============================================================================

local function lead(path)
    local p = tostring(path)
    return (p:sub(1, 1) == "/") and p or ("/" .. p)
end

local function safe(s)
    return (tostring(s):gsub("[^%w_%-]", "_"))
end

local function mapName()
    return (editor.getLevelPath() or ""):match("([^/]+)/*$") or "map"
end

local function autoName(label)
    return safe(mapName() .. "_" .. label .. "_" .. os.date("%Y-%m-%d_%H%M"))
end

local function objName(id)
    local o = scenetree.findObjectById(id)
    local n = o and o:getName()
    return n ~= "" and n or nil
end

-- =============================================================================
-- DESCRIBE
-- =============================================================================

local function round(v)
    return math.floor(v * 10.0 + 0.5) / 10.0
end

local function wallLabel(v)
    if type(v) ~= "string" then return nil end
    local m = Texture.material(v) or v
    return (m:gsub("^@", ""):gsub("^mage_tex_", ""):gsub("^mage_", ""):gsub("^m_", ""):gsub("_bat$", ""):gsub("_", " "))
end

local function describe(t)
    local byKey, home = {}, nil
    for _, p in ipairs(t.parts) do
        local d = B.parse(p.dyn.building)
        if d and d.key then byKey[d.key] = {p = p, d = d} end
        if d and not d.below and not d.host and not home then home = {p = p, d = d} end
    end
    home                    = home or {p = t.parts[1], d = B.parse(t.parts[1].dyn.building) or {}}
    local floors, cur, seen = 1, home, {}
    while cur and cur.d.key and not seen[cur.d.key] do
        seen[cur.d.key] = true
        local nxt       = nil
        for _, e in pairs(byKey) do
            if e.d.below == cur.d.key and not e.d.host then nxt = e end
        end
        if nxt then floors = floors + 1 end
        cur = nxt
    end
    local ns, len = home.p.nodes, 0.0
    for i = 2, #ns do len = len + math.sqrt((ns[i][1] - ns[i - 1][1]) ^ 2 + (ns[i][2] - ns[i - 1][2]) ^ 2) end
    local mods, roof, units, has = {}, nil, 0, {}
    for _, p in ipairs(t.parts) do
        local d = B.parse(p.dyn.building)
        if d and d.host then units = units + 1 end
        local cfg = Window.parse(p.dyn.windows)
        for _, k in ipairs(Window.modKeys) do
            local m = cfg and cfg.mods[k]
            if m and (m.on or next(m.faces or {})) then
                if k == "roof" and not roof then
                    roof = (m.shape == "shed") and ("shed_" .. (m.high or "left")) or (m.shape or "gable")
                elseif not plainMods[k] and not has[k] then
                    has[k]        = true
                    mods[#mods + 1] = k
                end
            end
        end
    end
    return {floors = floors, len = round(len), wid = round(ns[1][4]), roof = roof, wall = wallLabel(home.p.dyn.wall), mods = mods, units = units}
end

local function canon(v)
    local tv = type(v)
    if tv == "number" then return string.format("%.4f", v) end
    if tv ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. canon(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
end

-- =============================================================================
-- COLLECT
-- =============================================================================

local function collect(homes)
    local styles, byKey, pts = {}, {}, {}
    for _, home in ipairs(homes) do
        local t, c = B.capture(home)
        if t then
            local text, fr = B.twinOf(home)
            local key      = text and ("t" .. C.hash(text)) or ("c" .. C.hash(canon(t)))
            local r        = fr and fr.r or 0.0
            local st       = byKey[key]
            if not st then
                st         = {name = objName(home), desc = describe(t), t = t, r0 = r, at = {}}
                byKey[key] = st
                styles[#styles + 1] = st
            end
            st.at[#st.at + 1] = {x = c.x, y = c.y, z = c.z, r = r - st.r0}
            pts[#pts + 1]     = c
        end
    end
    if #styles == 0 then return nil end
    local gx, gy, gz = 0.0, 0.0, math.huge
    for _, c in ipairs(pts) do gx, gy, gz = gx + c.x / #pts, gy + c.y / #pts, math.min(gz, c.z) end
    for _, st in ipairs(styles) do
        st.r0 = nil
        for _, a in ipairs(st.at) do a.x, a.y, a.z = a.x - gx, a.y - gy, a.z - gz end
    end
    return {version = version, map = mapName(), made = os.date("%Y-%m-%d %H:%M"), buildings = styles}, {x = gx, y = gy, z = gz}
end

-- =============================================================================
-- FILES
-- =============================================================================

local function copyFile(from, to)
    FS:copyFile(from, to)
    return FS:fileExists(to)
end

local function deep(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deep(x) end
    return out
end

local function relocate(def, srcDir, keep, outDir, copied)
    local function walk(t)
        for k, v in pairs(t) do
            if type(v) == "table" then
                walk(v)
            elseif type(v) == "string" then
                local e = v:match("%.(%w+)$")
                if e and images[e:lower()] then
                    local full = (v:sub(1, 1) == "/") and v or (srcDir .. v)
                    if full:lower():sub(1, #keep) == keep:lower() then
                        local dst = outDir .. full:match("([^/]+)$")
                        if copied[dst] == nil then copied[dst] = copyFile(full, dst) end
                        t[k] = dst
                    else
                        t[k] = full
                    end
                end
            end
        end
    end
    walk(def)
end

local function levelMats()
    local lp, defs = editor.getLevelPath(), {}
    for _, f in ipairs(FS:findFiles(lp, "*.materials.json", -1, true, false) or {}) do
        local path = lead(f)
        local d    = C.readJson(path)
        for name, def in pairs(type(d) == "table" and d or {}) do
            if type(def) == "table" and not defs[name] then defs[name] = {def = def, dir = path:match("^(.*/)")} end
        end
    end
    return defs
end

-- =============================================================================
-- EXPORT
-- =============================================================================

local function homesOf(ids)
    local out, seen = {}, {}
    for _, id in ipairs(ids) do
        local h = B.dataOf(id) and B.homeOf(id)
        if h and not seen[h] then
            seen[h]       = true
            out[#out + 1] = h
        end
    end
    return out
end

local function exportSkeleton(name, homes)
    local data = collect(homes)
    if not data then return nil, "no building to export" end
    local file = root .. name .. "/" .. name .. ext
    if not C.writeJson(file, data) then return nil, C.tr("could not write %s", file) end
    listed = nil
    return file, data
end

local function exportDae(name, homes)
    local data, g = collect(homes)
    if not data then return nil, "no building to export" end
    local dir, ids = root .. name .. "/", {}
    for _, h in ipairs(homes) do
        for _, fid in ipairs(B.group(h)) do ids[#ids + 1] = fid end
    end
    local xml, tris = E.bake(ids, vec3(g.x, g.y, g.z))
    if not xml then return nil, tris end
    local dae = dir .. name .. ".dae"
    if not mr.writeChecked(dae, xml) then return nil, C.tr("could not write %s", dae) end
    local defs, mats, copied = levelMats(), {}, {}
    for m in xml:gmatch('<material id="[^"]*" name="([^"]+)"') do
        local e = defs[m]
        if e then
            local def = deep(e.def)
            relocate(def, e.dir, editor.getLevelPath(), dir, copied)
            def.persistentId = nil
            mats[m]          = def
        end
    end
    if next(mats) then
        if not C.writeJson(dir .. name .. ".materials.json", mats) then return nil, C.tr("could not write %s", dir .. name .. ".materials.json") end
        data.materials = name .. ".materials.json"
    end
    E.savePrefab(dir .. name .. ".prefab.json", dae)
    data.dae, data.tris = name .. ".dae", tris
    if not C.writeJson(dir .. name .. ext, data) then return nil, C.tr("could not write %s", dir .. name .. ext) end
    listed = nil
    return dae, data
end

-- =============================================================================
-- IMPORT
-- =============================================================================

local function valid(d)
    if type(d) ~= "table" or type(d.buildings) ~= "table" or #d.buildings == 0 then return false end
    for _, st in ipairs(d.buildings) do
        if type(st) ~= "table" or type(st.t) ~= "table" or type(st.t.parts) ~= "table" or type(st.at) ~= "table" or #st.at == 0 or type(st.desc) ~= "table" then return false end
        for _, a in ipairs(st.at) do
            if type(a) ~= "table" or type(a.x) ~= "number" or type(a.y) ~= "number" or type(a.z) ~= "number" or type(a.r) ~= "number" then return false end
        end
    end
    return true
end

local function exports(force)
    if listed and not force and os.clock() - listed.at < listAge then return listed.list end
    local list = {}
    for _, f in ipairs(FS:findFiles(root, "*" .. ext, -1, true, false) or {}) do
        local path = lead(f)
        local d    = C.readJson(path)
        if valid(d) then
            d.file, d.dir, d.name = path, path:match("^(.*/)"), path:match("([^/]+)%.mage%.json$")
            list[#list + 1]       = d
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    listed = {at = os.clock(), list = list}
    return list
end

local function placeDae(data)
    local obj = mr.newStatic(data.file, mr.matrixOf(data.pos, vec3(-math.sin(data.yaw), math.cos(data.yaw), 0)), vec3(1, 1, 1))
    obj:setCanSave(true)
    obj:registerObject(data.name)
    scenetree.MissionGroup:addObject(obj)
end

local function removeDae(data)
    local o = scenetree.findObject(data.name)
    if o then o:delete() end
end

local function importDae(rec, pos, yaw)
    local dir = editor.getLevelPath() .. importDir .. safe(rec.name) .. "/"
    local dae = dir .. rec.dae
    if not copyFile(rec.dir .. rec.dae, dae) then return nil, C.tr("could not write %s", dae) end
    if rec.materials then
        local mats   = C.readJson(rec.dir .. rec.materials)
        local copied = {}
        for _, def in pairs(type(mats) == "table" and mats or {}) do
            if type(def) == "table" then relocate(def, rec.dir, rec.dir, dir, copied) end
        end
        local file = dir .. rec.materials
        if not C.writeJson(file, type(mats) == "table" and mats or {}) then return nil, C.tr("could not write %s", file) end
        loadJsonMaterialsFile(file)
    end
    local data = {file = dae, pos = vec3(pos.x, pos.y, pos.z), yaw = yaw, name = Sim.getUniqueName("mage_import_" .. safe(rec.name))}
    editor.history:commitAction("MageImportDae", data, removeDae, placeDae)
    return data.name
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.root           = root
M.autoName       = autoName
M.describe       = describe
M.collect        = collect
M.homesOf        = homesOf
M.exportSkeleton = exportSkeleton
M.exportDae      = exportDae
M.exports        = exports
M.importDae      = importDae

return M
