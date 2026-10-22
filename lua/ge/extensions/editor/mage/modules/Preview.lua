-- =============================================================================
-- MaGE - live preview
-- Version: 1.0.2
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M      = {}
local logTag = 'mage'

local S        = require("editor/mage/config/Settings")
local hairpin  = S.hairpin
local meshRoad = S.meshRoad

local C  = require("editor/mage/core/Common")
local tr = C.tr

local G             = require("editor/mage/core/Geometry")
local buildRoadMesh = G.buildRoadMesh
local loadStyles    = G.loadStyles
local mrState       = G.mrState
local resolveStyle  = G.resolveStyle
local features      = G.features
local mr            = G.mr

local O       = require("editor/mage/modules/Overlap")
local Gate    = require("editor/mage/core/Gate")
local Window  = require("editor/mage/core/Window")
local Chain   = require("editor/mage/core/Chain")
local Modules = require("editor/mage/core/Modules")
local Collada = require("editor/mage/core/Collada")

local D                = require("editor/mage/modules/Decals")
local buildIslandMesh  = D.buildIslandMesh
local extractIslands   = D.extractIslands
local flushHairpinTips = D.flushHairpinTips
local hairpinUnionRing = D.hairpinUnionRing
local markJoinedEnds   = D.markJoinedEnds
local mergeJunctions   = D.mergeJunctions
local signedArea2D     = D.signedArea2D

-- =============================================================================
-- STATE
-- =============================================================================

local meshPrefix = "MagePreview_"

local previewMeshes = {}
local previewSrc    = {}
local builtMeshes   = {}
local hiddenRoads   = {}
local restOf        = {}
local rendered      = {}
local trying        = {}
local tryOwn        = false
local liveEnabled   = false
local lastStatus    = ""
local follow        = nil
local followKey     = nil
local followIds     = nil
local watch         = nil
local queue         = {}
local lastPaths     = nil
local lastNb        = {}
local srcIndex      = nil
local copyOf        = {}
local oldDropped    = nil

local stackOf = nil

local matsFile = "mage_models.materials.json"
local plainSrc = {italy_plastic = "/art/shapes/garage_and_dealership/Clutter/main.materials.json"}
local shapeDir = "/art/shapes/"

local liveMaxRoads = 12
local liveDelay    = 0.3
local stepBudget   = 0.004
local pollEvery    = 0.1
local polledAt     = -math.huge
local pendingSince = {}
local pendingSig   = {}

-- =============================================================================
-- SCENE
-- =============================================================================

local function fieldPrefix()
    return (G.getStyleCfg() and G.getStyleCfg().fieldPrefix) or C.fieldPrefix
end

local function axisField(axis)
    local axes = G.getStyleCfg() and G.getStyleCfg().axes
    local a    = axes and axes[axis]
    if a and a.field then return C.fieldName(a.field) end
    return C.fieldName(fieldPrefix() .. axis)
end

local function dynValue(obj, fieldName)
    local over = trying[obj:getID()]
    if over and over[fieldName] ~= nil then
        if over[fieldName] == "" then return nil end
        return over[fieldName]
    end
    for _, f in ipairs({fieldName, C.legacyField(fieldName)}) do
        local v = obj:getDynDataFieldbyName(f, 0)
        if v ~= nil and v ~= "" then return tostring(v) end
    end
    return nil
end

local markerMaterial = "WarningMaterial"
local buildError     = "build failed"

function mr.meshRoadIsTextured(obj)
    for _, key in ipairs(meshRoad.materialKeys) do
        local v = C.objField(obj, key)
        if v and v ~= markerMaterial then return true end
    end
    return false
end

function mr.flagValue(v)
    if v == nil then return nil end
    local t = tostring(v):lower()
    if t == "on" or t == "true" or t == "1" or t == "yes" then return true end
    if t == "off" or t == "false" or t == "0" or t == "no" then return false end
    return nil
end

local function pidOf(obj)
    local pid = C.objField(obj, "persistentId")
    if not pid then
        local v = obj:getOrCreatePersistentID()
        if v and v ~= "" then pid = tostring(v) end
    end
    return pid
end

local function nameOf(obj)
    local nm = obj:getName()
    return (nm ~= nil and nm ~= "") and nm or nil
end

local function identOf(obj)
    return pidOf(obj) or nameOf(obj) or tostring(obj:getID())
end

local function readRoad(id)
    local obj = scenetree.findObjectById(id)
    if not obj then return nil end
    local cls = obj:getClassName()
    if cls ~= "DecalRoad" and cls ~= "MeshRoad" then return nil end
    local isMesh = (cls == "MeshRoad")

    if isMesh then
        if meshRoad.untexturedOnly and mr.meshRoadIsTextured(obj) then return nil end
    else
        if C.objField(obj, "material") ~= markerMaterial then return nil end
    end
    local count = obj:getNodeCount()
    if count < 2 then return nil end

    local pts, ws, ds, ups = {}, {}, (isMesh and {} or nil), (isMesh and {} or nil)
    for i = 0, count - 1 do
        local p = obj:getNodePosition(i)
        local w = obj:getNodeWidth(i)
        if w <= 0 then w = 2.0 end
        pts[#pts + 1] = vec3(p.x, p.y, p.z)
        ws[#ws + 1] = w
        if isMesh then
            local d = obj:getNodeDepth(i)
            if d <= 0 then d = S.height end
            ds[#ds + 1] = d
            local v = obj:getNodeNormal(i)
            local n = vec3(v.x, v.y, v.z)
            ups[#ups + 1] = (n:length() > 1e-6) and n:normalized() or vec3(0, 0, 1)
        end
    end

    local rollFlag, bottomFlag, endsFlag
    if isMesh then
        rollFlag   = mr.flagValue(dynValue(obj, axisField("roll")))
        bottomFlag = mr.flagValue(dynValue(obj, axisField("bottom")))
        endsFlag   = mr.flagValue(dynValue(obj, axisField("ends")))
    end

    local pid  = pidOf(obj)
    local over = (not isMesh) and dynValue(obj, axisField("over")) or nil
    local road = {
        id           = id,
        persistentId = pid,
        name         = nameOf(obj) or tostring(id),
        source       = isMesh and "meshroad" or "decalroad",
        points       = pts,
        widths       = ws,
        depths       = ds,
        ups          = ups,
        curb         = dynValue(obj, axisField("curb")),
        walk         = dynValue(obj, axisField("walk")),
        wall         = isMesh and dynValue(obj, axisField("wall")) or nil,
        roll         = rollFlag,
        bottom       = bottomFlag,
        ends         = endsFlag,
        profile      = dynValue(obj, axisField("profile")) or "walk",
        overObjects  = over == "on" or over == "surface",
        overSurface  = over == "surface",
        curbDims     = (not isMesh) and G.curbDimsOf(dynValue(obj, axisField("curbdims"))) or nil,
    }
    if isMesh then
        for _, f in ipairs(features) do
            road[f.key] = mr.flagValue(dynValue(obj, axisField(f.key)))
            if road[f.key] == true then
                road[f.key .. "Dims"] = G.featureOverrides(f, dynValue(obj, axisField(f.key) .. "_dims"))
            end
        end
        local gates = Gate.parse(dynValue(obj, axisField("gates")))
        if #gates > 0 then road.gates = gates end
        road.windows = Window.parse(dynValue(obj, axisField("windows")))
        local pr     = tonumber(dynValue(obj, axisField("priority")))
        if pr and pr > -1.0 + 1e-9 then road.priority = math.min(1.0, pr) end
        local st = stackOf and stackOf(id)
        if st then
            road.profile  = "flat"
            road.noTop    = st.cover
            road.ground   = st.ground
            road.roof     = st.top
            road.under    = st.under
            road.building = st.root
            road.home     = st.home
            road.floors   = st.floors
            road.covered  = st.covered
            road.cut      = st.cut
            road.walls    = st.walls
            if st.overhang then road.bottom = true elseif st.base then road.bottom = false end
        end
    end
    return road
end

local function selectedIds()
    return editor.selection.object or {}
end

-- =============================================================================
-- OBJECTS
-- =============================================================================

local function hideRoadOnce(id)
    if hiddenRoads[id] ~= nil then return end
    local obj = scenetree.findObjectById(id)
    if not obj then return end
    local was       = (obj.hidden == true)
    hiddenRoads[id] = {was = was, set = true}
    obj.hidden      = true
end

local function restoreHiddenRoads(keepMesh)
    for id, _ in pairs(hiddenRoads) do
        local rec = hiddenRoads[id]
        local obj = scenetree.findObjectById(id)
        if obj and rec and not (keepMesh and obj:getClassName() == "MeshRoad") then
            local cur = (obj.hidden == true)
            if cur == rec.set then
                obj.hidden = rec.was
            end
        end
    end
    hiddenRoads = {}
end

local function areaUnits()
    local idx  = C.readJson(editor.getLevelPath() .. mr.daeDir .. mr.indexFile)
    local need = {}
    if type(idx) ~= "table" or type(idx.units) ~= "table" then return need end
    for _, u in pairs(idx.units) do
        if type(u) == "table" and type(u.cell) == "string" then need[u.cell] = (need[u.cell] or 0) + 1 end
    end
    return need
end

local function clearPreview(keepMesh)
    for _, m in pairs(previewMeshes) do
        m:delete()
    end
    previewMeshes, previewSrc, builtMeshes = {}, {}, {}
    restOf                                 = {}
    restoreHiddenRoads(keepMesh)
    lastPaths, lastNb        = nil, {}
    rendered                 = {}
    pendingSince, pendingSig = {}, {}
    queue                    = {}
end

local function sweepOrphans()
    local n = 0
    for _, nm in ipairs(scenetree.findClassObjects("ProceduralMesh") or {}) do
        if nm:find(meshPrefix, 1, true) and not previewMeshes[nm] then
            local o = scenetree.findObject(nm)
            if o then
                o:delete()
                n = n + 1
            end
        end
    end
    return n
end

local function underSignature(under)
    local parts = {}
    for _, u in ipairs(under or {}) do
        parts[#parts + 1] = string.format("%.3f,%.3f", u.top, u.base)
        for _, p in ipairs(u.poly) do parts[#parts + 1] = string.format("%.3f,%.3f", p.x, p.y) end
    end
    return table.concat(parts, ";")
end

local function touchSignature(road)
    local parts = {}
    for _, f in ipairs({"right", "left", "start", "end"}) do parts[#parts + 1] = tostring(road.covered[f]) end
    parts[#parts + 1] = tostring(road.cut.start) .. "," .. tostring(road.cut["end"])
    for _, f in ipairs({"right", "left"}) do
        for _, c in ipairs(road.cut[f]) do parts[#parts + 1] = string.format("%.3f,%.3f", c[1], c[2]) end
        parts[#parts + 1] = "/"
    end
    for _, f in ipairs({"right", "left", "start", "end"}) do
        for _, c in ipairs(road.walls[f]) do parts[#parts + 1] = string.format("%.3f,%.3f", c[1], c[2]) end
        parts[#parts + 1] = "/"
    end
    return table.concat(parts, ";")
end

local function roadSignature(road)
    local parts = {tostring(#road.points), tostring(road.source),
                   tostring(road.curb), tostring(road.walk),
                   tostring(road.wall), tostring(road.roll),
                   tostring(road.bottom), tostring(road.ends),
                   tostring(road.profile), tostring(road.overObjects), tostring(road.overSurface), tostring(road.noTop),
                   tostring(road.ground), tostring(road.roof), underSignature(road.under),
                   tostring(road.priority), Gate.encode(road.gates), Window.encode(road.windows)}
    for _, k in ipairs({"height", "strip", "angle", "exposed", "corner", "tip"}) do parts[#parts + 1] = tostring(road.curbDims and road.curbDims[k]) end
    if road.cut then parts[#parts + 1] = touchSignature(road) end
    for _, f in ipairs(features) do
        parts[#parts + 1] = tostring(road[f.key])
        local dims = road[f.key .. "Dims"] or {}
        for _, fd in ipairs(f.fields or {}) do parts[#parts + 1] = tostring(dims[fd.key]) end
    end
    for i = 1, #road.points do
        local p = road.points[i]
        local u = road.ups and road.ups[i]
        parts[#parts + 1] = string.format("%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f",
                                          p.x, p.y, p.z, road.widths[i] or 0,
                                          road.depths and road.depths[i] or 0,
                                          u and u.x or 0, u and u.y or 0)
    end
    return table.concat(parts, "|")
end

local function meshesOf(id)
    return builtMeshes[id]
end

local function meshList(ids)
    local want, out = {}, {}
    for _, id in ipairs(ids) do want[id] = true end
    for name, m in pairs(previewMeshes) do
        for _, sid in ipairs(previewSrc[name] or {}) do
            if want[sid] then
                out[#out + 1] = m
                break
            end
        end
    end
    return out
end

local function removeMeshFor(id)
    builtMeshes[id] = nil
    local key = "_" .. tostring(id)
    for name, m in pairs(previewMeshes) do
        if name:sub(-#key) == key then
            m:delete()
            previewMeshes[name], previewSrc[name] = nil, nil
        end
    end
end

local meshCtr = 0

local function buildUnit(road)
    G.setStyleKeys(resolveStyle(road))
    mrState.curbMat, mrState.curbBand0, mrState.wallStyle = nil, false, nil
    mrState.orient                                        = (road.source == "meshroad")
    if road.source == "meshroad" then
        mrState.curbMat   = mr.meshCurb(road)
        mrState.curbBand0 = true
        local ws          = mr.styleFor(road.wall, "wall")
        if ws and ws.material then mrState.wallStyle = ws end
    end
    G.setCurb(road.curbDims)
    if road.overSurface then mr.surfaceBegin() end
    local ok, meshes, err = pcall(function()
        if road.isIsland then return buildIslandMesh(road) end
        local m, e = buildRoadMesh(road)
        return m, e
    end)
    mr.surfaceEnd()
    G.setCurb(nil)
    mrState.curbMat, mrState.curbBand0, mrState.orient = nil, false, false
    mrState.wallStyle, mrState.vBase                   = nil, 0.0
    if not ok then
        log('E', logTag, "build failed for " .. tostring(road.name or road.id) .. ": " .. tostring(meshes))
        return nil, buildError
    end
    return meshes, err
end

local function storeMat(name, src, fix)
    local levelPath = C.levelDir()
    local def       = levelPath and (C.readJson(src) or {})[name]
    if type(def) ~= "table" then return false end
    local dir = src:match("^(.*/)[^/]*$")
    for _, st in ipairs(type(def.Stages) == "table" and def.Stages or {}) do
        if type(st) == "table" then
            for k, v in pairs(st) do
                if type(v) == "string" and k:find("Map$") and v ~= "" and not v:find("/") then st[k] = dir .. v end
            end
        end
    end
    def.name, def.persistentId = def.name or name, nil
    fix(def)
    return C.storeMaterials(levelPath .. mr.daeDir .. matsFile, {{name = def.name, def = def}})
end

local function scaleColor(st, rgb)
    local key = (type(st.diffuseColor) == "table" and not st.baseColorFactor) and "diffuseColor" or "baseColorFactor"
    local c   = type(st[key]) == "table" and st[key] or {1, 1, 1, 1}
    st[key]   = {(tonumber(c[1]) or 1) * rgb[1], (tonumber(c[2]) or 1) * rgb[2], (tonumber(c[3]) or 1) * rgb[3], tonumber(c[4]) or 1}
end

local function tinted(def, rgb)
    for _, s in ipairs(type(def.Stages) == "table" and def.Stages or {}) do
        if type(s) == "table" then s.instanceDiffuse = nil end
    end
    local st = type(def.Stages) == "table" and type(def.Stages[1]) == "table" and def.Stages[1]
    if st then scaleColor(st, rgb) end
end

local function needMat(name)
    if scenetree.findObject(name) then return end
    local hex, base = tostring(name):match("^mage_tint_(%x%x%x%x%x%x)_(.+)$")
    if hex and Modules.tintSrc[base] then
        local rgb = {tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255}
        storeMat(base, Modules.tintSrc[base], function(def)
            def.name, def.mapTo = name, name
            tinted(def, rgb)
        end)
    elseif Modules.levelMats[name] then
        storeMat(name, Modules.levelMats[name], function() end)
    elseif name == Modules.darkMat and C.levelDir() then
        C.storeMaterials(C.levelDir() .. mr.daeDir .. matsFile, {{name = name, def = {name = name, mapTo = name, class = "Material", version = 1.5,
            Stages = {{baseColorFactor = {0.03, 0.03, 0.03, 1}, roughnessFactor = 1, metallicFactor = 0}, {}, {}, {}}}}})
    end
end

local function matSource(name)
    local own = shapeDir .. "objects/" .. name .. "/main.materials.json"
    local d   = C.readJson(own)
    if type(d) == "table" and type(d[name]) == "table" then return own end
    local known = Modules.tintSrc[name] or Modules.levelMats[name] or plainSrc[name]
    if known then return known end
    if not srcIndex then
        srcIndex = {}
        for _, f in ipairs(FS:findFiles(shapeDir, "*.materials.json", -1, true, false) or {}) do
            local file = tostring(f)
            if file:sub(1, 1) ~= "/" then file = "/" .. file end
            for k, v in pairs(C.readJson(file) or {}) do
                if type(v) == "table" and srcIndex[k] == nil then srcIndex[k] = file end
            end
        end
    end
    return srcIndex[name]
end

local function secondUv(st)
    for k, v in pairs(st) do
        if type(k) == "string" and k:find("UseUV$") and v == 1 then return true end
    end
    return false
end

local function stagesOf(def)
    return type(def) == "table" and type(def.Stages) == "table" and def.Stages or {}
end

local function usesColor(def)
    for _, st in ipairs(stagesOf(def)) do
        if type(st) == "table" and st.vertColor == true then return true end
    end
    return false
end

local function needsCopy(def, tint)
    for i, st in ipairs(stagesOf(def)) do
        if type(st) == "table" and (st.instanceDiffuse == true or (i > 1 and secondUv(st)) or (tint and st.vertColor == true)) then return true end
    end
    return false
end

local function previewFix(def, tint)
    local stages = stagesOf(def)
    local cut    = #stages + 1
    for i = 2, #stages do
        if cut > #stages and type(stages[i]) == "table" and secondUv(stages[i]) then cut = i end
    end
    for i = cut, #stages do stages[i] = {} end
    if cut <= #stages then def.activeLayers = math.min(tonumber(def.activeLayers) or (cut - 1), cut - 1) end
    for _, st in ipairs(stages) do
        if type(st) == "table" then
            st.instanceDiffuse = nil
            if tint and st.vertColor == true then
                scaleColor(st, tint)
                st.vertColor = nil
            end
        end
    end
end

local function dropOld()
    local levelPath = C.levelDir()
    if not levelPath or oldDropped == levelPath then return end
    oldDropped = levelPath
    local file = levelPath .. mr.daeDir .. matsFile
    local cur  = C.readJson(file)
    local any  = false
    for k in pairs(type(cur) == "table" and cur or {}) do
        if type(k) == "string" and k:find("^mage_vc_") then cur[k], any = nil, true end
    end
    if any then C.writeJson(file, cur) end
end

local function previewMat(sm)
    if type(sm.material) ~= "string" then return sm.material end
    local name = sm.material
    local hex  = sm.tint and string.format("%02x%02x%02x", math.floor(sm.tint[1] * 255 + 0.5), math.floor(sm.tint[2] * 255 + 0.5), math.floor(sm.tint[3] * 255 + 0.5))
    local memo = name .. "|" .. (hex or "")
    needMat(name)
    if copyOf[memo] and (copyOf[memo] == name or scenetree.findObject(copyOf[memo])) then return copyOf[memo] end
    local src  = matSource(name)
    local def  = src and (C.readJson(src) or {})[name]
    local tint = hex and usesColor(def) and sm.tint or nil
    local copy = name
    if needsCopy(def, tint) then
        copy = tint and ("mage_pv_" .. hex .. "_" .. name) or ("mage_plain_" .. name)
        dropOld()
        if not scenetree.findObject(copy) and not storeMat(name, src, function(d)
            d.name, d.mapTo = copy, copy
            previewFix(d, tint)
        end) then copy = name end
    end
    copyOf[memo] = copy
    return copy
end

local function plainMat(name)
    return previewMat({material = name})
end

local function cellOrigin(cell)
    local x, y = cell:match("^(m?%d+)_(m?%d+)$")
    if not x then return nil end
    return (tonumber((x:gsub("^m", "-"))) + 0.5) * mr.daeCell, (tonumber((y:gsub("^m", "-"))) + 0.5) * mr.daeCell
end

local function showRest(cell, area, keys)
    local ox, oy = cellOrigin(cell)
    local file   = tostring(area:getField("shapeName", 0) or "")
    local text   = ox and (readFile(file) or readFile("/" .. file))
    if not text then return end
    for _, k in ipairs(keys) do
        for _, tail in ipairs({"_M", "_modules_M", "_modules_uv_M"}) do
            text = text:gsub('<node id="' .. ("mage_" .. k .. tail):gsub("%p", "%%%0") .. '".-</node>', "")
        end
    end
    local plain = {}
    for _, sm in ipairs(Collada.read(text) or {}) do
        local verts = {}
        for i, v in ipairs(sm.verts) do verts[i] = vec3(v.x + ox, v.y + oy, v.z) end
        plain[#plain + 1] = {verts = verts, normals = sm.normals, uvs = sm.uvs, faces = sm.faces, material = plainMat(sm.material)}
    end
    hideRoadOnce(area:getID())
    restOf[cell] = true
    if #plain == 0 then return end
    local name = meshPrefix .. "rest_" .. cell
    local o    = createObject('ProceduralMesh')
    o:setPosition(vec3(0, 0, 0))
    o.canSave = false
    o:registerObject(name)
    scenetree.MissionGroup:add(o.obj)
    o:createMesh({plain})
    previewMeshes[name] = o
end

local function hideStatics(paths)
    local count, need = {}, {}
    local cells, have = {}, nil
    local keys        = {}
    for _, road in ipairs(paths) do
        if road.building then
            count[road.building] = (count[road.building] or 0) + 1
            need[road.building]  = road.floors
        else
            local cell = mr.cellOf(road)
            if cell then
                cells[cell] = (cells[cell] or 0) + 1
                keys[cell]  = keys[cell] or {}
                table.insert(keys[cell], mr.daeName(road.persistentId or road.name or road.id))
            end
        end
    end
    for key, n in pairs(count) do
        local o = n >= need[key] and scenetree.findObject(mr.daePrefix .. mr.buildingCell(key))
        if o then hideRoadOnce(o:getID()) end
    end
    for cell, n in pairs(cells) do
        local o = scenetree.findObject(mr.daePrefix .. cell)
        if o then
            have = have or areaUnits()
            if have[cell] and n >= have[cell] then hideRoadOnce(o:getID()) elseif not restOf[cell] then showRest(cell, o, keys[cell]) end
        end
    end
end

local function buildOne(road, overlapPlan, overlapCache)
    local meshes, err = O.build(road, overlapPlan, buildUnit, overlapCache)
    if not meshes then return false, err end

    removeMeshFor(road.id)
    if #meshes == 0 then
        for _, sid in ipairs(road.srcIds or {road.id}) do hideRoadOnce(sid) end
        return true
    end
    meshCtr    = meshCtr + 1
    local name = meshPrefix .. tostring(meshCtr) .. "_" .. tostring(road.id)
    local o    = createObject('ProceduralMesh')
    o:setPosition(vec3(0, 0, 0))
    o.canSave = false
    o:registerObject(name)
    scenetree.MissionGroup:add(o.obj)
    local plain = {}
    for i, sm in ipairs(meshes) do
        if sm.material == Modules.darkMat then needMat(sm.material) end
        plain[i] = sm.module and {verts = sm.verts, normals = sm.normals, uvs = sm.uvs, faces = sm.faces, material = previewMat(sm)} or sm
    end
    o:createMesh({plain})
    builtMeshes[road.id] = meshes
    previewMeshes[name]  = o
    previewSrc[name]     = road.srcIds or {road.id}
    for _, sid in ipairs(road.srcIds or {road.id}) do hideRoadOnce(sid) end
    return true
end

local function pickSources(ids)
    local out, seen, hit = {}, {}, false
    for _, id in ipairs(ids) do
        local obj  = scenetree.findObjectById(id)
        local srcs = obj and previewSrc[obj:getName()]
        hit        = hit or srcs ~= nil
        for _, sid in ipairs(srcs or {id}) do
            if not seen[sid] then
                seen[sid]     = true
                out[#out + 1] = sid
            end
        end
    end
    if not hit then return nil end
    local cls = nil
    for i, sid in ipairs(out) do
        local o = scenetree.findObjectById(sid)
        local c = o and o:getClassName()
        if i > 1 and c ~= cls then return out, nil end
        cls = c
    end
    return out, cls
end

local function chainOf(sel, candidates)
    local tol, ends = S.paths.loopTol, {}
    for _, id in ipairs(candidates) do
        local o = scenetree.findObjectById(id)
        if o and o:getClassName() == "MeshRoad" and o:getNodeCount() >= 2 then
            local a, b = o:getNodePosition(0), o:getNodePosition(o:getNodeCount() - 1)
            ends[id]   = {vec3(a.x, a.y, a.z), vec3(b.x, b.y, b.z)}
        end
    end
    local out, seen, queue = {}, {}, {}
    for _, id in ipairs(sel) do
        seen[id]      = true
        out[#out + 1] = id
        if ends[id] then queue[#queue + 1] = id end
    end
    while #queue > 0 do
        local e = ends[table.remove(queue)]
        for oid, f in pairs(ends) do
            if not seen[oid] then
                for _, p in ipairs(e) do
                    for _, q in ipairs(f) do
                        if not seen[oid] and (p - q):length() < tol then
                            seen[oid]           = true
                            out[#out + 1]       = oid
                            queue[#queue + 1]   = oid
                        end
                    end
                end
            end
        end
    end
    table.sort(out)
    return out
end

-- =============================================================================
-- RENDER
-- =============================================================================

local function collectUnits(ids, onRead)
    local roads, skipped = {}, 0
    for _, id in ipairs(ids) do
        local road = readRoad(id)
        if road then roads[#roads + 1] = road else skipped = skipped + 1 end
    end

    table.sort(roads, function(a, b)
        local ia, ib = tonumber(a.id), tonumber(b.id)
        if ia and ib and ia ~= ib then return ia < ib end
        return tostring(a.persistentId or a.name or a.id)
                  < tostring(b.persistentId or b.name or b.id)
    end)

    if onRead then onRead(roads) end

    local meshRoads, decals = {}, {}
    for _, rd in ipairs(roads) do
        if rd.source == "meshroad" then meshRoads[#meshRoads + 1] = rd
        else decals[#decals + 1] = rd end
    end
    meshRoads = Chain.join(meshRoads, features)

    local islands, rest = extractIslands(decals)

    local paths = mergeJunctions(rest)
    markJoinedEnds(paths)
    local hairpins, hairPairs = flushHairpinTips(paths)

    local unions = 0
    if hairpin.union and hairPairs and #hairPairs > 0 then
        local consumed, made = {}, {}
        for _, pr in ipairs(hairPairs) do
            local rdI, eI, rdJ, eJ, tip = pr[1], pr[2], pr[3], pr[4], pr[5]
            local ring                  = hairpinUnionRing(rdI, eI, rdJ, eJ, tip)
            if ring then
                consumed[rdI] = true
                consumed[rdJ] = true
                local srcIds  = {}
                for _, r in ipairs({rdI, rdJ}) do
                    for _, sid in ipairs(r.srcIds or {r.id}) do srcIds[#srcIds + 1] = sid end
                end
                made[#made + 1] = {
                    id          = rdI.id, name = rdI.name, persistentId = rdI.persistentId,
                    srcIds      = srcIds, ring = ring,
                    area        = math.abs(signedArea2D(ring)), parts = 2,
                    curb        = rdI.curb, walk = rdI.walk, profile = rdI.profile, curbDims = rdI.curbDims,
                    overObjects = rdI.overObjects or rdJ.overObjects,
                    overSurface = rdI.overSurface or rdJ.overSurface,
                    isIsland    = true,
                }
                unions = unions + 1
            end
        end
        if unions > 0 then
            local kept = {}
            for _, r in ipairs(paths) do
                if not consumed[r] then kept[#kept + 1] = r end
            end
            for _, r in ipairs(made) do kept[#kept + 1] = r end
            paths = kept
        end
    end

    for _, isl in ipairs(islands) do paths[#paths + 1] = isl end
    for _, mr in ipairs(meshRoads) do paths[#paths + 1] = mr end
    return {
        paths     = paths,
        roads     = roads,
        skipped   = skipped,
        meshRoads = meshRoads,
        islands   = islands,
        hairpins  = hairpins,
        unions    = unions,
    }
end

local function pathIds(road)
    return road.srcIds or {road.id}
end

local function pathsKey(paths)
    local parts = {}
    for i, road in ipairs(paths) do parts[i] = table.concat(pathIds(road), "+") end
    return table.concat(parts, ",")
end

local function rebuildSet(paths, plan, dirty)
    local redo, ids = {}, {}
    for _, road in ipairs(paths) do
        for _, sid in ipairs(pathIds(road)) do
            if dirty[sid] then redo[road] = true end
        end
    end
    for _, road in ipairs(paths) do
        if redo[road] then
            ids[road.id] = true
            for _, nb in ipairs(plan.neighbors[road] or {}) do ids[nb.id] = true end
        end
    end
    for _, road in ipairs(paths) do
        for nid in pairs(lastNb[road.id] or {}) do
            if ids[nid] then ids[road.id] = true end
        end
    end
    for _, road in ipairs(paths) do
        if ids[road.id] then redo[road] = true end
    end
    return redo
end

local function keepNeighbors(paths, plan)
    lastNb = {}
    for _, road in ipairs(paths) do
        local set = {}
        for _, nb in ipairs(plan.neighbors[road] or {}) do set[nb.id] = true end
        lastNb[road.id] = set
    end
end

local function wholeUnits(ids)
    local levelPath = editor.getLevelPath()
    local idx       = levelPath and C.readJson(levelPath .. mr.daeDir .. mr.indexFile)
    if type(idx) ~= "table" or type(idx.units) ~= "table" then return ids end
    local mine, want = {}, {}
    for _, id in ipairs(ids) do
        local obj = scenetree.findObjectById(id)
        if obj then mine[identOf(obj)] = true end
    end
    for _, u in pairs(idx.units) do
        local src = type(u) == "table" and type(u.src) == "table" and u.src or {}
        local hit = false
        for _, p in ipairs(src) do hit = hit or mine[p] == true end
        for _, p in ipairs(hit and src or {}) do
            if not mine[p] then want[p] = true end
        end
    end
    if next(want) == nil then return ids end
    local out = {}
    for i, id in ipairs(ids) do out[i] = id end
    for _, cls in ipairs({"MeshRoad", "DecalRoad"}) do
        for _, nm in ipairs(scenetree.findClassObjects(cls) or {}) do
            local obj = scenetree.findObject(nm)
            local key = obj and identOf(obj)
            if key and want[key] then
                want[key]     = nil
                out[#out + 1] = obj:getID()
            end
        end
    end
    return out
end

local function renderSelection(idsIn, dirty)
    if not dirty then clearPreview() end
    if not G.getStyleCfg() then loadStyles() end
    if not G.getStyleCfg() then
        lastStatus = tostring(G.getStyleErr())
        return lastStatus
    end

    local ids = idsIn or selectedIds()
    if #ids == 0 then
        lastStatus = "nothing selected"
        return lastStatus
    end
    if not dirty then ids = wholeUnits(ids) end

    local u = collectUnits(ids, function(roads)
        if dirty then
            for _, rd in ipairs(roads) do
                if dirty[rd.id] or not rendered[rd.id] then
                    rendered[rd.id]                      = roadSignature(rd)
                    pendingSince[rd.id], pendingSig[rd.id] = nil, nil
                end
            end
            return
        end
        rendered                 = {}
        pendingSince, pendingSig = {}, {}
        for _, rd in ipairs(roads) do rendered[rd.id] = roadSignature(rd) end
    end)
    local skipped, paths     = u.skipped, u.paths
    local meshRoads, islands = u.meshRoads, u.islands
    local hairpins, unions   = u.hairpins, u.unions

    local key = pathsKey(paths)
    if dirty and key ~= lastPaths then return renderSelection(ids) end
    lastPaths = key

    local built, merges = 0, 0
    local overlapPlan   = O.plan(paths)
    local overlapCache  = {}
    local redo          = dirty and rebuildSet(paths, overlapPlan, dirty)
    local later         = {}
    local function watched(road)
        for _, sid in ipairs(road.srcIds or {road.id}) do
            if watch[sid] then return true end
        end
        return false
    end
    keepNeighbors(paths, overlapPlan)
    for _, road in ipairs(paths) do
        if road.merged and road.merged > 1 then merges = merges + 1 end
        if redo and not redo[road] then
            built = built + 1
        elseif watch and not dirty and not watched(road) then
            later[#later + 1] = road
        else
            local ok, err = buildOne(road, overlapPlan, overlapCache)
            if ok then built = built + 1
            else skipped = skipped + 1
                      if err then lastStatus = err end end
        end
    end
    if #later > 0 then
        queue = {list = later, plan = overlapPlan, cache = overlapCache, paths = paths}
    elseif queue.list then
        queue.paths = paths
    else
        hideStatics(paths)
    end

    if built > liveMaxRoads and liveEnabled and not follow then
        liveEnabled = false
        lastStatus  = tr("rendered %d - auto refresh turned off above %d roads",
                        built, liveMaxRoads)
    else
        local parts = {}
        parts[#parts + 1] = (built == 1) and tr("rendered 1 path")
                                                                            or tr("rendered %d paths", built)
        if #meshRoads > 0 then
            parts[#parts + 1] = tr("%d MeshRoad", #meshRoads)
        end
        if merges > 0 then
            parts[#parts + 1] = tr("%d merged at junctions", merges)
        end
        if #islands > 0 then
            parts[#parts + 1] = (#islands == 1) and tr("1 island")
                                                                                      or tr("%d islands", #islands)
        end
        if hairpins > 0 then
            local filled = (unions > 0) and tr(" (%d filled)", unions) or ""
            parts[#parts + 1] = ((hairpins == 1) and tr("1 V-end joined")
                                                  or tr("%d V-ends joined", hairpins)) .. filled
        end
        if skipped > 0 then
            parts[#parts + 1] = tr("%d skipped", skipped)
        end
        if #later > 0 then
            parts[#parts + 1] = tr("%d more of the area on the way", #later)
        end
        lastStatus = table.concat(parts, ", ")
    end
    return lastStatus
end

local function touched(a, b)
    local out = {}
    for _, t in ipairs({a, b}) do
        for id in pairs(t) do
            if rendered[id] ~= nil then out[id] = true end
        end
    end
    return out
end

local function tryFields(map, show)
    local before = trying
    trying       = map or {}
    local ids    = {}
    for id in pairs(rendered) do ids[#ids + 1] = id end
    if #ids == 0 then
        ids, tryOwn = show or {}, true
        if #ids > 0 then renderSelection(ids) end
        return
    end
    local changed = touched(before, trying)
    if next(changed) then renderSelection(ids, changed) end
end

local function idsKey(ids)
    local list = {}
    for i, id in ipairs(ids) do list[i] = tostring(id) end
    table.sort(list)
    return table.concat(list, ",")
end

local function renderFollowed()
    local ids = follow()
    followKey = idsKey(ids)
    followIds = ids
    return renderSelection(ids)
end

local function rerender()
    if follow then return renderFollowed() end
    local ids = {}
    for id in pairs(rendered) do ids[#ids + 1] = id end
    if #ids > 0 then renderSelection(ids) end
end

local function pruneGone()
    local alive, gone = {}, false
    for id in pairs(rendered) do
        if scenetree.findObjectById(id) then alive[#alive + 1] = id else gone = true end
    end
    if not gone then return false end
    if #alive == 0 then
        follow, followKey, followIds, watch = nil, nil, nil, nil
        clearPreview()
    else
        renderSelection(alive)
    end
    return true
end

local function tryEnd(later)
    if next(trying) == nil and not tryOwn then return false end
    local was = trying
    trying    = {}
    if tryOwn then
        tryOwn = false
        clearPreview()
        return false
    end
    if later then return true end
    local ids = {}
    for id in pairs(rendered) do ids[#ids + 1] = id end
    local changed = touched(was, {})
    if next(changed) then renderSelection(ids, changed) end
    return false
end

local function peekSource(id, show)
    local obj = hiddenRoads[id] and scenetree.findObjectById(id)
    if obj then obj.hidden = not show end
end

local function buildQueued()
    local q = queue.list
    if not q then return end
    local t0 = os.clock()
    while #q > 0 do
        buildOne(table.remove(q, 1), queue.plan, queue.cache)
        if os.clock() - t0 > stepBudget then break end
    end
    if #q == 0 then
        hideStatics(queue.paths)
        queue = {}
    end
end

local function refreshLive()
    buildQueued()
    if not liveEnabled then return end
    if follow then
        local ids = follow()
        if ids ~= followIds and idsKey(ids) ~= followKey then
            renderFollowed()
            return
        end
    end
    local tick = os.clock()
    if tick - polledAt < pollEvery then return end
    local since = (polledAt > -math.huge) and polledAt or tick
    polledAt    = tick
    if next(rendered) == nil then return end

    local count = 0
    for _ in pairs(rendered) do count = count + 1 end
    if count > liveMaxRoads and not follow then
        liveEnabled = false
        lastStatus  = "auto refresh turned off - too many roads rendered"
        return
    end

    local now         = os.clock()
    local dirty, gone = false, false
    local changed     = {}
    for id, sig in pairs(rendered) do
        if not watch or watch[id] then
            local road = readRoad(id)
            if not road then
                gone = true
            else
                local cur = roadSignature(road)
                if cur ~= sig then
                    if pendingSig[id] ~= cur then
                        pendingSig[id]   = cur
                        pendingSince[id] = since
                    end
                    if now - pendingSince[id] >= liveDelay then
                        dirty       = true
                        changed[id] = true
                    end
                else
                    pendingSince[id], pendingSig[id] = nil, nil
                end
            end
        end
    end

    if gone then
        rerender()
    elseif dirty then
        local ids = follow and follow() or nil
        if not ids then
            ids = {}
            for id in pairs(rendered) do ids[#ids + 1] = id end
        end
        renderSelection(ids, changed)
    end
end

-- =============================================================================
-- EVENTS
-- =============================================================================

local function onEditorInspectorFieldChanged(selectedIds_, fieldName)
    if not liveEnabled then return end
    if type(selectedIds_) ~= "table" then return end
    for _, id in ipairs(selectedIds_) do
        if rendered[id] ~= nil and fieldName ~= "material" then
            local ids, changed = {}, {}
            for rid in pairs(rendered) do ids[#ids + 1] = rid end
            for _, sid in ipairs(selectedIds_) do
                if rendered[sid] ~= nil then changed[sid] = true end
            end
            renderSelection(ids, changed)
            return
        end
        if fieldName == "material" then
            local ids, seen = {}, {}
            for rid in pairs(rendered) do ids[#ids + 1], seen[rid] = rid, true end
            for _, sid in ipairs(selectedIds()) do
                if not seen[sid] and fieldName == "material" then ids[#ids + 1] = sid end
            end
            renderSelection(ids)
            return
        end
    end
end

local function convertSelection()
    local ids = selectedIds()
    if #ids == 0 then return "nothing selected" end

    local decals, meshes, skipped = {}, {}, 0
    for _, id in ipairs(ids) do
        local obj = scenetree.findObjectById(id)
        local cls = obj and obj:getClassName()
        if cls == "DecalRoad" and C.objField(obj, "material") ~= markerMaterial then
            decals[#decals + 1] = id
        elseif cls == "MeshRoad" and mr.meshRoadIsTextured(obj) then
            meshes[#meshes + 1] = id
        else
            skipped = skipped + 1
        end
    end
    local changed = #decals + #meshes
    C.transaction("MageConvert", function()
        if #decals > 0 then C.setFieldWithUndo(decals, "material", markerMaterial) end
        if #meshes > 0 then
            for _, key in ipairs(meshRoad.materialKeys) do C.setFieldWithUndo(meshes, key, markerMaterial) end
        end
    end)
    editor.setDirty()

    lastStatus = (changed == 1) and tr("warning material applied to 1 road, skipped %d", skipped)
                                 or tr("warning material applied to %d roads, skipped %d", changed, skipped)
    return lastStatus
end

local savedIds = nil

local function beforeSave()
    savedIds = nil
    if next(rendered) == nil then return end
    savedIds = {}
    for id in pairs(rendered) do savedIds[#savedIds + 1] = id end
    clearPreview()
end

local function afterSave()
    if not savedIds then return end
    local ids = savedIds
    savedIds  = nil
    if follow then renderFollowed() else renderSelection(ids) end
end

local function stopFollow()
    follow, followKey, followIds, watch = nil, nil, nil, nil
end

local function onEditorAfterOpenLevel()
    stopFollow()
    clearPreview()
    sweepOrphans()
    loadStyles()
end

local function onClientEndMission()
    stopFollow()
    clearPreview()
    sweepOrphans()
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.renderSelection  = function(ids)
    stopFollow()
    return renderSelection(ids)
end
M.renderGroup      = function(fn, core)
    follow, watch = fn, nil
    if core then
        watch = {}
        for _, id in ipairs(core) do watch[id] = true end
    end
    return renderFollowed()
end
M.busy             = function() return queue.list ~= nil end
M.collectUnits     = collectUnits
M.identOf          = function(id)
    local obj = scenetree.findObjectById(id)
    return obj and identOf(obj)
end
M.chainOf          = chainOf
M.setStack         = function(fn) stackOf = fn end
M.buildUnit        = buildUnit
M.buildError       = buildError
M.pickSources      = pickSources
M.peekSource       = peekSource
M.tryFields        = tryFields
M.meshesOf         = meshesOf
M.tryEnd           = tryEnd
M.rerender         = rerender
M.isTrying         = function() return next(trying) ~= nil end
M.clearPreview     = function(keepMesh)
    stopFollow()
    clearPreview(keepMesh)
end
M.meshList         = meshList
M.pruneGone        = pruneGone
M.convertSelection = convertSelection
M.loadStyles       = loadStyles
M.refreshLive      = refreshLive
M.isLive           = function() return liveEnabled end
M.setLive          = function(v)
    liveEnabled = v and true or false
    if not liveEnabled then pendingSince, pendingSig = {}, {} end
end
M.renderedCount    = function()
    local n = 0
    for _ in pairs(rendered) do n = n + 1 end
    return n
end
M.liveMaxRoads   = function() return liveMaxRoads end
M.fieldChanged   = onEditorInspectorFieldChanged
M.afterOpenLevel = onEditorAfterOpenLevel
M.needMat        = needMat
M.endMission     = onClientEndMission
M.beforeSave     = beforeSave
M.afterSave      = afterSave

return M
