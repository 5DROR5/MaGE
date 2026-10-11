-- =============================================================================
-- MaGE - buildings made of stacked MeshRoads
-- Version: 1.0.1
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local Window  = require("editor/mage/core/Window")
local Modules = require("editor/mage/core/Modules")
local S       = require("editor/mage/config/Settings")
local BA      = require("editor/mage/modules/BuildingArchitect")
local C       = require("editor/mage/core/Common")

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local meshClass = "MeshRoad"
local marker    = "WarningMaterial"
local appendAt  = 4294967295
local tol       = 1e-4
local refresh   = 0.5
local snapKeys  = {"height", "path", "width"}

local defaults = {
    floor    = 3.2,
    length   = 10.0,
    width    = 8.0,
    wall     = "m_bricks_01_bat",
    roof     = "m_stucco_white_bat",
    winW     = 1.2,
    winH     = 1.3,
    winSill  = 1.0,
    winSpace = 1.6,
    margin   = 0.2,
    depth    = 0.3,
    doorW    = 1.0,
    doorH    = 2.1,
    doorSill = 0.05,
    doorAt   = 0.5,
}

-- =============================================================================
-- STATE
-- =============================================================================

local fields = {}
local cache  = {at = -math.huge, gen = 0, list = {}, byId = {}, byKey = {}}
local memory = {}
local serial = 0
local synced = -1

-- =============================================================================
-- DATA
-- =============================================================================

local function parse(str)
    if type(str) ~= "string" or str == "" then return nil end
    local ok, data = pcall(jsonDecode, str)
    if not ok or type(data) ~= "table" then data = {} end
    local snap = type(data.snap) == "table" and data.snap or {}
    local out  = {snap = {}}
    for _, k in ipairs(snapKeys) do out.snap[k] = snap[k] ~= false end
    if type(data.below) == "string" and data.below ~= "" then out.below = data.below end
    if type(data.key) == "string" and data.key ~= "" then out.key = data.key end
    return out
end

local function encode(b)
    if not b then return "" end
    local snap = {}
    for _, k in ipairs(snapKeys) do snap[k] = b.snap[k] ~= false end
    return jsonEncode({key = b.key, below = b.below, snap = snap})
end

local function newKey()
    serial = serial + 1
    return string.format("%x%04x%04x", os.time(), serial % 65536, math.random(0, 65535))
end

local function newData(below)
    local b = {snap = {}, below = below, key = newKey()}
    for _, k in ipairs(snapKeys) do b.snap[k] = true end
    return b
end

local function windowRow(dae, w, h, sill, gap)
    return {style = "rect", dir = "left", width = w, height = h, sill = sill, gap = gap, dae = dae}
end

local function defaultWindows(withDoor)
    local d    = defaults
    local cfg  = Window.newConfig("rect")
    cfg.floors = {windowRow(Modules.defWin, d.winW, d.winH, d.winSill, d.winSpace - d.winW)}
    if withDoor then
        local door         = windowRow(Modules.defDoor, d.doorW, d.doorH, d.doorSill, 0.0)
        door.face, door.at = "right", d.doorAt
        table.insert(cfg.floors, 1, door)
    end
    cfg.faces   = {right = true, left = true, start = true, ["end"] = true}
    cfg.margin  = d.margin
    cfg.depth   = d.depth
    cfg.modules = true
    return cfg
end

-- =============================================================================
-- FIELDS
-- =============================================================================

local function configure(fieldOf)
    fields = fieldOf
end

local function dyn(obj, name)
    local v = name and obj:getDynDataFieldbyName(name, 0)
    if v == nil or v == "" then return nil end
    return tostring(v)
end

local function write(id, name, value)
    editor.setDynamicFieldValue(id, name, value, 0)
end

local function dataOf(id)
    local obj = scenetree.findObjectById(id)
    return obj and parse(dyn(obj, fields.building)) or nil
end

-- =============================================================================
-- INDEX
-- =============================================================================

local function firstNode(id)
    local obj = scenetree.findObjectById(id)
    if not obj or obj:getNodeCount() == 0 then return nil end
    return obj:getNodePosition(0)
end

local function remapCopies(copies)
    local byOld = {}
    for _, c in ipairs(copies) do
        local l         = byOld[c.oldKey] or {}
        byOld[c.oldKey] = l
        l[#l + 1]       = c
    end
    for _, c in ipairs(copies) do
        local cands = c.e.data.below and byOld[c.e.data.below]
        local best  = nil
        if cands then
            local p, bestD = firstNode(c.e.id), math.huge
            for _, o in ipairs(cands) do
                local q = p and firstNode(o.e.id)
                local d = q and ((q.x - p.x) ^ 2 + (q.y - p.y) ^ 2) or math.huge
                if not best or d < bestD then best, bestD = o, d end
            end
        end
        c.e.data.below = best and best.e.data.key or nil
    end
end

local function index(force)
    local now = os.clock()
    if not force and now - cache.at < refresh then return cache end
    local found = {}
    for _, nm in ipairs(scenetree.findClassObjects(meshClass)) do
        local obj = scenetree.findObject(nm)
        local b   = obj and parse(dyn(obj, fields.building))
        if b then found[#found + 1] = {id = obj:getID(), data = b} end
    end
    table.sort(found, function(a, b) return a.id < b.id end)
    local list, byId, byKey, copies = {}, {}, {}, {}
    for _, e in ipairs(found) do
        if not e.data.key then
            e.data.key = newKey()
            write(e.id, fields.building, encode(e.data))
        elseif byKey[e.data.key] then
            copies[#copies + 1] = {e = e, oldKey = e.data.key}
            e.data.key          = newKey()
        end
        list[#list + 1]   = e
        byId[e.id]        = e
        byKey[e.data.key] = e
    end
    remapCopies(copies)
    for _, c in ipairs(copies) do write(c.e.id, fields.building, encode(c.e.data)) end
    for _, e in ipairs(list) do
        if e.data.below == e.data.key then e.data.below = nil end
    end
    cache = {at = now, gen = cache.gen + 1, list = list, byId = byId, byKey = byKey}
    return cache
end

local function below(e, idx)
    local b = e.data.below and idx.byKey[e.data.below]
    if b == e then return nil end
    return b
end

local function chain(id)
    local idx = index()
    local e   = idx.byId[id]
    if not e then return {} end
    local seen = {[e] = true}
    local base = e
    while true do
        local b = below(base, idx)
        if not b or seen[b] then break end
        seen[b] = true
        base    = b
    end
    local out, cur = {base}, base
    seen           = {[base] = true}
    while true do
        local nxt
        for _, o in ipairs(idx.list) do
            if o.data.below == cur.data.key and not seen[o] then nxt = o break end
        end
        if not nxt then break end
        seen[nxt]     = true
        out[#out + 1] = nxt
        cur           = nxt
    end
    local ids = {}
    for _, o in ipairs(out) do ids[#ids + 1] = o.id end
    return ids
end

-- =============================================================================
-- NODES
-- =============================================================================

local function nodesOf(obj)
    local out = {}
    for i = 0, obj:getNodeCount() - 1 do
        local p = obj:getNodePosition(i)
        local n = obj:getNodeNormal(i)
        out[#out + 1] = {pos = vec3(p.x, p.y, p.z), width = obj:getNodeWidth(i), depth = obj:getNodeDepth(i),
                         normal = vec3(n.x, n.y, n.z)}
    end
    return out
end

local function nearest(list, p)
    local best, bestD = list[1], math.huge
    for _, n in ipairs(list) do
        local dx, dy = n.pos.x - p.x, n.pos.y - p.y
        local d      = dx * dx + dy * dy
        if d < bestD then best, bestD = n, d end
    end
    return best
end

local function differs(a, b)
    return math.abs(a.x - b.x) > tol or math.abs(a.y - b.y) > tol or math.abs(a.z - b.z) > tol
end

-- =============================================================================
-- SNAPPING
-- =============================================================================

local function keepBase(obj, id)
    local ns  = nodesOf(obj)
    local mem = memory[id]
    if mem and #mem == #ns then
        for i, n in ipairs(ns) do
            local m = mem[i]
            if math.abs(n.depth - m.depth) > tol and math.abs(n.pos.z - m.z) < tol then
                local z = m.z - m.depth + n.depth
                editor.setNodePosition(obj, i - 1, vec3(n.pos.x, n.pos.y, z))
                n.pos.z = z
            end
        end
    end
    local out = {}
    for i, n in ipairs(ns) do out[i] = {z = n.pos.z, depth = n.depth} end
    memory[id] = out
end

local function follow(obj, lower, snap)
    local L = nodesOf(lower)
    if #L < 2 then return end
    if snap.path then
        local count = obj:getNodeCount()
        while count < #L do
            local src = L[count + 1]
            editor.addMeshNode(obj:getID(), {pos = src.pos, width = src.width, depth = obj:getNodeDepth(count - 1),
                                             normal = src.normal, index = appendAt})
            count = count + 1
        end
        while count > #L do
            editor.deleteMeshNode(obj, count - 1)
            count = count - 1
        end
    end
    local U = nodesOf(obj)
    for i, n in ipairs(U) do
        local src  = (snap.path or #U == #L) and L[i] or nearest(L, n.pos)
        local want = vec3(n.pos.x, n.pos.y, n.pos.z)
        if snap.path then want.x, want.y = src.pos.x, src.pos.y end
        if snap.height then want.z = src.pos.z + n.depth end
        if differs(want, n.pos) then editor.setNodePosition(obj, i - 1, want) end
        if snap.width and math.abs(n.width - src.width) > tol then editor.setNodeWidth(obj, i - 1, src.width) end
        if snap.path and differs(n.normal, src.normal) then obj:setNodeNormal(i - 1, src.normal) end
    end
end

local function level(e, idx)
    local n, cur, seen = 0, e, {}
    while cur and not seen[cur] do
        seen[cur] = true
        cur       = below(cur, idx)
        n         = n + 1
    end
    return n, cur ~= nil
end

local function root(e, idx)
    local cur, seen = e, {}
    while not seen[cur] do
        seen[cur] = true
        local b   = below(cur, idx)
        if not b then return cur end
        cur = b
    end
    return cur
end

local function activeRoots(idx)
    local roots = {}
    for _, id in ipairs(editor.selection.object or {}) do
        local e = idx.byId[id]
        if e then roots[root(e, idx)] = true end
    end
    return roots
end

local function sync()
    if not fields.building then return end
    local idx   = index()
    local roots = nil
    if idx.gen == synced then
        roots = activeRoots(idx)
        if next(roots) == nil then return end
    end
    synced      = idx.gen
    local order = {}
    for _, e in ipairs(idx.list) do
        if not roots or roots[root(e, idx)] then
            local lv, loop = level(e, idx)
            order[#order + 1] = {e = e, lv = lv, loop = loop}
        end
    end
    table.sort(order, function(a, b) return a.lv < b.lv end)
    for _, o in ipairs(order) do
        local e   = o.e
        local obj = scenetree.findObjectById(e.id)
        if obj and obj:getNodeCount() >= 2 then
            local low  = (not o.loop) and below(e, idx) or nil
            local lobj = low and scenetree.findObjectById(low.id)
            if lobj then
                follow(obj, lobj, e.data.snap)
                memory[e.id] = nil
            else
                keepBase(obj, e.id)
            end
        end
    end
end

-- =============================================================================
-- CREATING
-- =============================================================================

local function material(name)
    return BA.use(name) or nil
end

local function setup(id, wall, roof, cfg, data)
    local obj = scenetree.findObjectById(id)
    for _, key in ipairs(S.meshRoad.materialKeys) do obj:setField(key, 0, marker) end
    if wall then write(id, fields.wall, wall) end
    if roof then write(id, fields.walk, roof) end
    write(id, fields.ends, "on")
    write(id, fields.windows, Window.encode(cfg))
    write(id, fields.building, encode(data))
end

local function ground(p)
    local d = castRayStatic(p, vec3(0, 0, -1), 2000)
    if type(d) == "number" and d < 2000 then return p.z - d end
    return p.z - 2.0
end

local function create(at)
    local d    = defaults
    local z    = ground(at) + d.floor
    local up   = vec3(0, 0, 1)
    local half = d.length / 2.0
    local id   = editor.createMesh(meshClass, {
        {pos = vec3(at.x - half, at.y, z), width = d.width, depth = d.floor, normal = up},
        {pos = vec3(at.x + half, at.y, z), width = d.width, depth = d.floor, normal = up},
    }, {})
    if not id then return nil end
    setup(id, material(d.wall), material(d.roof), defaultWindows(true), newData(nil))
    index(true)
    return id
end

local function addFloor(id)
    local ids = chain(id)
    local top = scenetree.findObjectById(ids[#ids] or id)
    if not top then return nil end
    local ns    = nodesOf(top)
    local nodes = {}
    for i, n in ipairs(ns) do
        nodes[i] = {pos = vec3(n.pos.x, n.pos.y, n.pos.z + defaults.floor), width = n.width, depth = defaults.floor, normal = n.normal}
    end
    local nid = editor.createMesh(meshClass, nodes, {})
    if not nid then return nil end
    local cfg  = Window.parse(dyn(top, fields.windows)) or defaultWindows(false)
    local kept = {}
    for _, f in ipairs(cfg.floors) do
        if not f.at then kept[#kept + 1] = f end
    end
    cfg.floors    = (#kept > 0) and kept or defaultWindows(false).floors
    local topData = parse(dyn(top, fields.building)) or newData(nil)
    if not topData.key then
        topData.key = newKey()
        write(top:getID(), fields.building, encode(topData))
    end
    setup(nid, dyn(top, fields.wall), dyn(top, fields.walk), cfg, newData(topData.key))
    index(true)
    return nid
end

local function held(e)
    return e.data.snap.path and e.data.snap.width
end

local function stack(id)
    local idx = index()
    local e   = idx.byId[id]
    if not e then return nil end
    local low   = below(e, idx)
    local cover = false
    for _, o in ipairs(idx.list) do
        if o ~= e and o.data.below == e.data.key and held(o) then
            cover = true
            break
        end
    end
    return {base = low ~= nil and held(e), cover = cover}
end

local function setData(id, b)
    C.setDynWithUndo({id}, fields.building, encode(b))
    index(true)
end

local function setHeight(id, h)
    local obj = scenetree.findObjectById(id)
    for i = 0, obj:getNodeCount() - 1 do editor.setNodeDepth(obj, i, h) end
end

local function height(id)
    local obj = scenetree.findObjectById(id)
    if not obj or obj:getNodeCount() == 0 then return defaults.floor end
    local h = 0.0
    for i = 0, obj:getNodeCount() - 1 do h = h + obj:getNodeDepth(i) end
    return h / obj:getNodeCount()
end

local function reset()
    cache, memory = {at = -math.huge, gen = cache.gen, list = {}, byId = {}, byKey = {}}, {}
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.defaults       = defaults
M.snapKeys       = snapKeys
M.parse          = parse
M.encode         = encode
M.newData        = newData
M.defaultWindows = defaultWindows
M.configure      = configure
M.dataOf         = dataOf
M.index          = index
M.chain          = chain
M.stack          = stack
M.sync           = sync
M.create         = create
M.addFloor       = addFloor
M.setData        = setData
M.setHeight      = setHeight
M.height         = height
M.reset          = reset

return M
