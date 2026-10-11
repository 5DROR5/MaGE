-- =============================================================================
-- MaGE - live preview
-- Version: 1.0.1
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

local O      = require("editor/mage/modules/Overlap")
local Gate   = require("editor/mage/core/Gate")
local Window = require("editor/mage/core/Window")

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
local hiddenRoads   = {}
local rendered      = {}
local liveEnabled   = false
local lastStatus    = ""

local stackOf = nil

local liveMaxRoads = 12
local liveDelay    = 0.3
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
    local a    = type(axes) == "table" and axes[axis] or nil
    local name = type(a) == "table" and a.field or nil
    if type(name) == "string" and name ~= "" then return C.fieldName(name) end
    return C.fieldName(fieldPrefix() .. axis)
end

local function dynValue(obj, fieldName)
    for _, f in ipairs({fieldName, C.legacyField(fieldName)}) do
        local v = obj:getDynDataFieldbyName(f, 0)
        if v ~= nil and v ~= "" then return tostring(v) end
    end
    return nil
end

local function objField(obj, name)
    local v = obj:getField(name, 0)
    if v ~= nil and v ~= "" then return tostring(v) end
    return nil
end

local markerMaterial = "WarningMaterial"

function mr.meshRoadIsTextured(obj)
    for _, key in ipairs(meshRoad.materialKeys) do
        local v = objField(obj, key)
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

local function readRoad(id)
    local obj = scenetree.findObjectById(id)
    if not obj then return nil end
    local cls = obj:getClassName()
    if cls ~= "DecalRoad" and cls ~= "MeshRoad" then return nil end
    local isMesh = (cls == "MeshRoad")

    if isMesh then
        if meshRoad.untexturedOnly and mr.meshRoadIsTextured(obj) then return nil end
    else
        if objField(obj, "material") ~= markerMaterial then return nil end
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

    local over = objField(obj, "overObjects")

    local rollFlag, bottomFlag, endsFlag
    if isMesh then
        rollFlag   = mr.flagValue(dynValue(obj, axisField("roll")))
        bottomFlag = mr.flagValue(dynValue(obj, axisField("bottom")))
        endsFlag   = mr.flagValue(dynValue(obj, axisField("ends")))
    end

    local pid = objField(obj, "persistentId")
    if not pid then
        local v = obj:getOrCreatePersistentID()
        if v and v ~= "" then pid = tostring(v) end
    end
    local road = {
        id           = id,
        persistentId = pid,
        name         = obj:getName() or tostring(id),
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
        overObjects  = (over == "1" or over == "true"),
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
            road.profile = "flat"
            road.noTop   = st.cover
            if st.base then road.bottom = false end
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

local function restoreHiddenRoads()
    for id, _ in pairs(hiddenRoads) do
        local rec = hiddenRoads[id]
        local obj = scenetree.findObjectById(id)
        if obj and rec then
            local cur = (obj.hidden == true)
            if cur == rec.set then
                obj.hidden = rec.was
            end
        end
    end
    hiddenRoads = {}
end

local function clearPreview()
    for _, m in pairs(previewMeshes) do
        m:delete()
    end
    previewMeshes = {}
    restoreHiddenRoads()
    rendered                 = {}
    pendingSince, pendingSig = {}, {}
end

local function sweepOrphans()
    local n = 0
    for _, nm in ipairs(scenetree.findClassObjects("ProceduralMesh")) do
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

local function roadSignature(road)
    local parts = {tostring(#road.points), tostring(road.source),
                   tostring(road.curb), tostring(road.walk),
                   tostring(road.wall), tostring(road.roll),
                   tostring(road.bottom), tostring(road.ends),
                   tostring(road.profile), tostring(road.overObjects), tostring(road.noTop),
                   tostring(road.priority), Gate.encode(road.gates), Window.encode(road.windows)}
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

local function removeMeshFor(id)
    local key = "_" .. tostring(id)
    for name, m in pairs(previewMeshes) do
        if name:sub(-#key) == key then
            m:delete()
            previewMeshes[name] = nil
        end
    end
end

local meshCtr = 0

local function buildUnit(road)
    G.setStyleKeys(resolveStyle(road))
    mrState.curbMat, mrState.curbBand0, mrState.wallStyle = nil, false, nil
    mrState.orient                                        = (road.source == "meshroad")
    if road.source == "meshroad" then
        mrState.curbMat   = mr.meshroadCurbMaterial(road)
        mrState.curbBand0 = true
        local wallStyles  = G.getStyleCfg() and G.getStyleCfg().wall and G.getStyleCfg().wall.styles
        local ws          = mr.rawStyle(road.wall) or (wallStyles and road.wall and wallStyles[road.wall])
        if type(ws) == "table" and ws.material then mrState.wallStyle = ws end
    end
    local ok, meshes, err = pcall(function()
        if road.isIsland then return buildIslandMesh(road) end
        local m, e = buildRoadMesh(road)
        return m, e
    end)
    mrState.curbMat, mrState.curbBand0, mrState.orient = nil, false, false
    mrState.wallStyle                                  = nil
    if not ok then
        log('E', logTag, "build failed for " .. tostring(road.name or road.id) .. ": " .. tostring(meshes))
        return nil, "build failed"
    end
    return meshes, err
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
        plain[i] = sm.module and {verts = sm.verts, normals = sm.normals, uvs = sm.uvs, faces = sm.faces, material = sm.material} or sm
    end
    o:createMesh({plain})
    previewMeshes[name] = o
    for _, sid in ipairs(road.srcIds or {road.id}) do hideRoadOnce(sid) end
    return true
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
                    curb        = rdI.curb, walk = rdI.walk, profile = rdI.profile,
                    overObjects = rdI.overObjects or rdJ.overObjects,
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

local function renderSelection(idsIn)
    clearPreview()
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

    local u = collectUnits(ids, function(roads)
        rendered                 = {}
        pendingSince, pendingSig = {}, {}
        for _, rd in ipairs(roads) do rendered[rd.id] = roadSignature(rd) end
    end)
    local skipped, paths     = u.skipped, u.paths
    local meshRoads, islands = u.meshRoads, u.islands
    local hairpins, unions   = u.hairpins, u.unions

    local built, merges = 0, 0
    local overlapPlan   = O.plan(paths)
    local overlapCache  = {}
    for _, road in ipairs(paths) do
        if road.merged and road.merged > 1 then merges = merges + 1 end
        local ok, err = buildOne(road, overlapPlan, overlapCache)
        if ok then built = built + 1
        else skipped = skipped + 1
                  if err then lastStatus = err end end
    end

    if built > liveMaxRoads and liveEnabled then
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
        lastStatus = table.concat(parts, ", ")
    end
    return lastStatus
end

local function refreshLive()
    if not liveEnabled then return end
    if next(rendered) == nil then return end

    local count = 0
    for _ in pairs(rendered) do count = count + 1 end
    if count > liveMaxRoads then
        liveEnabled = false
        lastStatus  = "auto refresh turned off - too many roads rendered"
        return
    end

    local now         = os.clock()
    local dirty, gone = false, false
    for id, sig in pairs(rendered) do
        local road = readRoad(id)
        if not road then
            gone = true
        else
            local cur = roadSignature(road)
            if cur ~= sig then
                if pendingSig[id] ~= cur then
                    pendingSig[id]   = cur
                    pendingSince[id] = now
                elseif now - (pendingSince[id] or now) >= liveDelay then
                    dirty = true
                end
            else
                pendingSince[id], pendingSig[id] = nil, nil
            end
        end
    end

    if gone or dirty then
        local ids = {}
        for id in pairs(rendered) do ids[#ids + 1] = id end
        renderSelection(ids)
    end
end

-- =============================================================================
-- EVENTS
-- =============================================================================

local function onEditorInspectorFieldChanged(selectedIds_, fieldName, fieldValue, arrayIndex)
    if not liveEnabled then return end
    if type(selectedIds_) ~= "table" then return end
    for _, id in ipairs(selectedIds_) do
        if rendered[id] ~= nil or fieldName == "material" then
            renderSelection()
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
        if cls == "DecalRoad" and objField(obj, "material") ~= markerMaterial then
            decals[#decals + 1] = id
        elseif cls == "MeshRoad" and mr.meshRoadIsTextured(obj) then
            meshes[#meshes + 1] = id
        else
            skipped = skipped + 1
        end
    end
    local changed = #decals + #meshes
    editor.history:beginTransaction("MageConvert")
    if #decals > 0 then C.setFieldWithUndo(decals, "material", markerMaterial) end
    if #meshes > 0 then
        for _, key in ipairs(meshRoad.materialKeys) do C.setFieldWithUndo(meshes, key, markerMaterial) end
    end
    editor.history:endTransaction()
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
    renderSelection(ids)
end

local function onEditorAfterOpenLevel()
    clearPreview()
    sweepOrphans()
    loadStyles()
end

local function onClientEndMission()
    clearPreview()
    sweepOrphans()
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.renderSelection  = renderSelection
M.collectUnits     = collectUnits
M.setStack         = function(fn) stackOf = fn end
M.buildUnit        = buildUnit
M.clearPreview     = clearPreview
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
M.endMission     = onClientEndMission
M.beforeSave     = beforeSave
M.afterSave      = afterSave

return M
