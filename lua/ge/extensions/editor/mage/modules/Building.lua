-- =============================================================================
-- MaGE - buildings made of stacked MeshRoads
-- Version: 1.0.2
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local Window  = require("editor/mage/core/Window")
local Modules = require("editor/mage/core/Modules")
local S       = require("editor/mage/config/Settings")
local BA      = require("editor/mage/modules/BuildingArchitect")
local C       = require("editor/mage/core/Common")
local Texture = require("editor/mage/core/Texture")

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local meshClass = "MeshRoad"
local marker    = "WarningMaterial"
local appendAt  = 4294967295
local tol       = 1e-4
local refresh   = 0.5
local overhang  = 0.05
local snapKeys  = {"height", "path", "width"}
local savedFile = "/settings/mage/buildings.json"
local savedAge  = 2.0
local frameKeys = {"x", "y", "z", "r"}
local unpack    = table.unpack or unpack

local defaults = {
    floor     = 3.2,
    length    = 10.0,
    width     = 8.0,
    wall      = "m_stucco_white_bat",
    wallTile  = 2.0,
    roof      = "m_stucco_white_bat",
    roofTile  = 1.0,
    tiles     = "italy_bld_roof_tiles",
    tilesTile = 1.0,
    roofOn    = true,
    win       = Modules.root .. "windows/R_HS_A_WN_01_90x120.dae",
    door      = Modules.root .. "doors/R_HS_A_DR_01_90x220.dae",
    winW      = 0.9,
    winH      = 1.2,
    winSill   = 1.0,
    winSpace  = 1.9,
    margin    = 0.2,
    depth     = 0.3,
    doorW     = 0.9,
    doorH     = 2.2,
    doorSill  = 0.05,
    doorAt    = 0.5,
    push      = 0.25,
    least     = 0.5,
    unitLen   = 6.0,
    unitWid   = 4.0,
    probe     = 0.1,
    touchTol  = 0.02,
    touchStep = 0.25,
    covered   = 0.98,
}

-- =============================================================================
-- STATE
-- =============================================================================

local fields   = {}
local cache    = {at = -math.huge, gen = 0, list = {}, byId = {}, byKey = {}}
local memory   = {}
local savedNow = nil
local serial   = 0
local decoded  = {kept = {}, seen = {}}
local synced   = -1
local batching = false

-- =============================================================================
-- DATA
-- =============================================================================

local function frameOf(f)
    if type(f) ~= "table" then return nil end
    for _, k in ipairs(frameKeys) do
        if type(f[k]) ~= "number" or f[k] ~= f[k] then return nil end
    end
    return {x = f.x, y = f.y, z = f.z, r = f.r}
end

local function shapeList(v)
    if type(v) ~= "table" or #v < 2 then return nil end
    local out = {}
    for i, n in ipairs(v) do
        if type(n) ~= "table" then return nil end
        local q = {}
        for k = 1, 8 do
            if type(n[k]) ~= "number" or n[k] ~= n[k] then return nil end
            q[k] = n[k]
        end
        out[i] = q
    end
    return out
end

local function parse(str)
    if type(str) ~= "string" or str == "" then return nil end
    local hit = decoded.seen[str] or decoded.kept[str]
    if not hit then
        local ok, data = pcall(jsonDecode, str)
        if not ok or type(data) ~= "table" then data = {} end
        local snap = type(data.snap) == "table" and data.snap or {}
        hit        = {snap = {}}
        for _, k in ipairs(snapKeys) do hit.snap[k] = snap[k] ~= false end
        if type(data.below) == "string" and data.below ~= "" then hit.below = data.below end
        if type(data.key) == "string" and data.key ~= "" then hit.key = data.key end
        if type(data.host) == "string" and data.host ~= "" then hit.host = data.host end
        if data.free == true then hit.free = true end
        hit.tpl      = frameOf(data.tpl)
        hit.straight = shapeList(data.straight)
    end
    decoded.seen[str] = hit
    local out = {snap = {}, below = hit.below, key = hit.key, host = hit.host, free = hit.free, tpl = frameOf(hit.tpl), straight = shapeList(hit.straight)}
    for _, k in ipairs(snapKeys) do out.snap[k] = hit.snap[k] end
    return out
end

local function encode(b)
    if not b then return "" end
    local snap = {}
    for _, k in ipairs(snapKeys) do snap[k] = b.snap[k] ~= false end
    return jsonEncode({key = b.key, below = b.below, host = b.host, free = b.free or nil, snap = snap, tpl = frameOf(b.tpl), straight = shapeList(b.straight)})
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
    cfg.floors = {windowRow(d.win, d.winW, d.winH, d.winSill, d.winSpace - d.winW)}
    if withDoor then
        local door         = windowRow(d.door, d.doorW, d.doorH, d.doorSill, 0.0)
        door.face, door.at = "right", d.doorAt
        table.insert(cfg.floors, 1, door)
    end
    cfg.faces           = {right = true, left = true, start = true, ["end"] = true}
    cfg.margin          = d.margin
    cfg.depth           = d.depth
    cfg.mods.windows.on = true
    cfg.mods.doors.on   = true
    return cfg
end

local function freshWindows(withDoor)
    local d          = defaults
    local cfg        = defaultWindows(withDoor)
    cfg.mods.roof.on = d.roofOn or nil
    if d.roofOn and scenetree.findObject(d.tiles) then cfg.mods.roof.mat = Texture.encode({mat = d.tiles, u = d.tilesTile, v = d.tilesTile}) end
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
    local function nearestCopy(c, key)
        local cands = key and byOld[key]
        local best  = nil
        if cands then
            local p, bestD = firstNode(c.e.id), math.huge
            for _, o in ipairs(cands) do
                local q = p and firstNode(o.e.id)
                local d = q and ((q.x - p.x) ^ 2 + (q.y - p.y) ^ 2) or math.huge
                if not best or d < bestD then best, bestD = o, d end
            end
        end
        return best and best.e.data.key or nil
    end
    for _, c in ipairs(copies) do
        local host     = c.e.data.host and nearestCopy(c, c.e.data.host)
        c.e.data.below = nearestCopy(c, c.e.data.below)
        if host then c.e.data.host = host end
    end
end

local function index(force)
    local now = os.clock()
    if not force and now - cache.at < refresh then return cache end
    local found = {}
    for _, nm in ipairs(scenetree.findClassObjects(meshClass) or {}) do
        local obj = scenetree.findObject(nm)
        local str = obj and dyn(obj, fields.building)
        local b   = parse(str)
        if b then found[#found + 1] = {id = obj:getID(), data = b, str = str} end
    end
    decoded.kept, decoded.seen = decoded.seen, {}
    table.sort(found, function(a, b) return a.id < b.id end)
    local sig = {}
    for k, e in ipairs(found) do
        sig[k] = e.id .. "=" .. e.str
        e.str  = nil
    end
    sig                             = table.concat(sig, "\n")
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
    local same = sig == cache.sig and #copies == 0
    cache      = {at = now, gen = same and cache.gen or cache.gen + 1, list = list, byId = byId, byKey = byKey, sig = sig}
    return cache
end

local function below(e, idx)
    local b = e.data.below and idx.byKey[e.data.below]
    if b == e then return nil end
    return b
end

local function root(e, idx)
    local cur, seen = e, {}
    while not seen[cur] do
        seen[cur] = true
        local b   = below(cur, idx)
        if not b then return cur end
        cur = b
    end
    local best, x = cur, below(cur, idx)
    while x ~= cur do
        if x.id < best.id then best = x end
        x = below(x, idx)
    end
    return best
end

local function home(e, idx)
    local cur, seen = root(e, idx), {}
    while cur.data.host and not seen[cur] do
        seen[cur] = true
        local h   = idx.byKey[cur.data.host]
        if not h then break end
        local r = root(h, idx)
        if seen[r] then break end
        cur = r
    end
    return cur
end

local function topo(idx)
    if idx.topo then return idx.topo end
    local t = {root = {}, home = {}, kids = {}, members = {}, chains = {}}
    for _, e in ipairs(idx.list) do
        t.root[e] = root(e, idx)
        local b   = e.data.below
        if b then
            local l   = t.kids[b] or {}
            t.kids[b] = l
            l[#l + 1] = e
        end
    end
    for _, e in ipairs(idx.list) do t.home[e] = home(e, idx) end
    for _, o in ipairs(idx.list) do
        local h = t.home[o]
        if t.root[o] == o and o ~= h then
            local l        = t.members[h] or {}
            t.members[h]   = l
            l[#l + 1]      = o
        end
    end
    idx.topo = t
    return t
end

local function chain(id)
    local idx = index()
    local e   = idx.byId[id]
    if not e then return {} end
    local t    = topo(idx)
    local base = t.root[e]
    if t.chains[base] then return {unpack(t.chains[base])} end
    local ids, cur = {base.id}, base
    local seen     = {[base] = true}
    while true do
        local nxt
        for _, o in ipairs(t.kids[cur.data.key] or {}) do
            if not seen[o] then
                nxt = o
                break
            end
        end
        if not nxt then break end
        seen[nxt]       = true
        ids[#ids + 1]   = nxt.id
        cur             = nxt
    end
    t.chains[base] = {unpack(ids)}
    return ids
end

local function stacks(id)
    local idx = index()
    local e   = idx.byId[id]
    if not e then return {} end
    local t   = topo(idx)
    local h   = t.home[e]
    local out = {h}
    for _, o in ipairs(t.members[h] or {}) do out[#out + 1] = o end
    return out
end

local function group(id)
    local ids = {}
    for _, s in ipairs(stacks(id)) do
        for _, fid in ipairs(chain(s.id)) do ids[#ids + 1] = fid end
    end
    return ids
end

local function homeOf(id)
    local idx = index()
    local e   = idx.byId[id]
    return e and topo(idx).home[e].id or nil
end

local function parts(id)
    local idx, out = index(), {}
    for n, s in ipairs(stacks(id)) do
        local ids, lead = chain(s.id), {}
        for k, fid in ipairs(ids) do
            if k == 1 or not idx.byId[fid].data.snap.path then lead[#lead + 1] = fid end
        end
        out[#out + 1] = {kind = (n == 1) and "main" or "unit", ids = ids, lead = lead}
    end
    return out
end

-- =============================================================================
-- NODES
-- =============================================================================

local function nodesOf(obj)
    local out = {}
    if not obj then return out end
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

local function activeRoots(idx)
    local roots = {}
    for _, id in ipairs(editor.selection.object or {}) do
        local e = idx.byId[id]
        if e then roots[root(e, idx)] = true end
    end
    return roots
end

local docked = nil

local function sync(only, depth)
    if not fields.building or (depth or 0) > 8 then return end
    local idx   = index()
    local roots = nil
    if only then
        local e = idx.byId[only]
        if not e then return end
        roots = {[root(e, idx)] = true}
    elseif idx.gen == synced then
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
    for _, o in ipairs(idx.list) do
        local h = o.data.host and idx.byKey[o.data.host]
        if h and root(o, idx) == o and root(h, idx) ~= o and (not roots or roots[root(h, idx)]) and not (roots and roots[o]) then
            for _, m in ipairs(docked(o.id) or {}) do
                local obj = scenetree.findObjectById(m.id)
                for i, nd in ipairs(m.new) do
                    if differs(nd.pos, m.old[i].pos) then editor.setNodePosition(obj, i - 1, nd.pos) end
                end
            end
            sync(o.id, (depth or 0) + 1)
        end
    end
end

-- =============================================================================
-- CREATING
-- =============================================================================

local function material(name, tile)
    local mat = Texture.material(BA.use(name) or "")
    return mat and Texture.encode({mat = mat, u = tile, v = tile}) or nil
end

local function spawn(d)
    if d.id then SimObject.setForcedId(d.id) end
    d.id      = editor.createMesh(meshClass, d.nodes, {})
    local obj = scenetree.findObjectById(d.id)
    for _, key in ipairs(S.meshRoad.materialKeys) do obj:setField(key, 0, marker) end
    for name, value in pairs(d.dyn) do write(d.id, name, value) end
    if not batching then index(true) end
end

local function unspawn(d)
    editor.deleteMesh(d.id)
    index(true)
end

local function make(nodes, wall, roof, cfg, data)
    local d = {nodes = nodes, dyn = {
        [fields.ends]     = "on",
        [fields.windows]  = Window.encode(cfg),
        [fields.building] = encode(data),
    }}
    if wall then d.dyn[fields.wall] = wall end
    if roof then d.dyn[fields.walk] = roof end
    editor.history:commitAction("MageCreateFloor", d, unspawn, spawn)
    return d
end

local function create(at, opt)
    local d          = defaults
    opt              = opt or {}
    local len, wid   = opt.length or d.length, opt.width or d.width
    local h          = opt.floor or d.floor
    local n          = math.max(1, math.floor((opt.floors or 1) + 0.5))
    local base, up   = opt.base or C.groundBelow(at), vec3(0, 0, 1)
    local yaw        = opt.yaw or 0.0
    local hx, hy     = math.cos(yaw) * len / 2.0, math.sin(yaw) * len / 2.0
    local wall, roof = material(d.wall, d.wallTile), material(d.roof, d.roofTile)
    local made       = {}
    C.transaction("MageCreateBuilding", function()
        local below = nil
        for k = 1, n do
            local z     = base + h * k
            local data  = newData(below)
            local nodes = {
                {pos = vec3(at.x - hx, at.y - hy, z), width = wid, depth = h, normal = up},
                {pos = vec3(at.x + hx, at.y + hy, z), width = wid, depth = h, normal = up},
            }
            made[#made + 1] = make(nodes, wall, roof, freshWindows(k == 1), data)
            below           = data.key
        end
    end)
    return made[1].id
end

-- =============================================================================
-- SAVED BUILDINGS
-- =============================================================================

local function readSaved()
    local d = C.readJson(savedFile)
    if type(d) ~= "table" then d = {} end
    if type(d.items) ~= "table" then d.items = {} end
    if d.default and not d.items[d.default] then d.default = nil end
    return d
end

local function saved()
    if savedNow and os.clock() - savedNow.at < savedAge then return savedNow.d end
    savedNow = {d = readSaved(), at = os.clock()}
    return savedNow.d
end

local function editSaved(fn)
    local d = readSaved()
    fn(d)
    if d.default and not d.items[d.default] then d.default = nil end
    if not C.writeJson(savedFile, d) then return false end
    savedNow = {d = d, at = os.clock()}
    return true
end

local function capture(id)
    local list, lo, cx, cy, n = {}, math.huge, 0.0, 0.0, 0
    for _, fid in ipairs(group(id)) do
        local obj = scenetree.findObjectById(fid)
        if obj then
            local p = {nodes = nodesOf(obj), dyn = {}, dims = {}}
            for axis, name in pairs(fields) do
                p.dyn[axis], p.dims[axis] = dyn(obj, name), dyn(obj, name .. "_dims")
            end
            for _, nd in ipairs(p.nodes) do
                lo        = math.min(lo, nd.pos.z - nd.depth)
                cx, cy, n = cx + nd.pos.x, cy + nd.pos.y, n + 1
            end
            list[#list + 1] = p
        end
    end
    if n == 0 then return nil end
    cx, cy    = cx / n, cy / n
    local out = {parts = {}}
    for _, p in ipairs(list) do
        local q = {nodes = {}, dyn = p.dyn, dims = p.dims}
        for _, nd in ipairs(p.nodes) do
            q.nodes[#q.nodes + 1] = {nd.pos.x - cx, nd.pos.y - cy, nd.pos.z - lo, nd.width, nd.depth, nd.normal.x, nd.normal.y, nd.normal.z}
        end
        out.parts[#out.parts + 1] = q
    end
    return out, {x = cx, y = cy, z = lo}
end

local function partOk(p)
    if type(p) ~= "table" or type(p.dyn) ~= "table" or type(p.nodes) ~= "table" or #p.nodes < 2 then return false end
    for _, nd in ipairs(p.nodes) do
        if type(nd) ~= "table" then return false end
        for k = 1, 8 do
            if type(nd[k]) ~= "number" then return false end
        end
    end
    return true
end

local function partsOf(t)
    local parts = {}
    for _, p in ipairs(type(t) == "table" and type(t.parts) == "table" and t.parts or {}) do
        if partOk(p) then parts[#parts + 1] = p end
    end
    return parts
end

local function turned(x, y, c, s)
    return x * c - y * s, x * s + y * c
end

local function instantiate(t, at, opt)
    opt         = opt or {}
    local parts = partsOf(t)
    if #parts == 0 then return nil end
    local base                = opt.base or C.groundBelow(at)
    local yaw                 = opt.yaw or 0.0
    local c, s                = math.cos(yaw), math.sin(yaw)
    local keys, list, missing = {}, {}, {}
    local framed              = not opt.frame
    for _, p in ipairs(parts) do
        local data = parse(p.dyn.building)
        if data and data.key then keys[data.key] = newKey() end
    end
    for _, p in ipairs(parts) do
        local d = {nodes = {}, dyn = {}}
        for _, nd in ipairs(p.nodes) do
            local x, y   = turned(nd[1], nd[2], c, s)
            local nx, ny = turned(nd[6], nd[7], c, s)
            d.nodes[#d.nodes + 1] = {pos = vec3(at.x + x, at.y + y, base + nd[3]), width = nd[4], depth = nd[5], normal = vec3(nx, ny, nd[8])}
        end
        for axis, v in pairs(p.dyn) do
            if fields[axis] then d.dyn[fields[axis]] = BA.ensure(v, missing) end
        end
        for axis, v in pairs(type(p.dims) == "table" and p.dims or {}) do
            if fields[axis] then d.dyn[fields[axis] .. "_dims"] = v end
        end
        local data = parse(p.dyn.building)
        if data then
            data.key, data.below, data.host = keys[data.key] or newKey(), data.below and keys[data.below], data.host and keys[data.host]
            data.tpl                        = nil
            if not framed and not data.below and not data.host then
                data.tpl, framed = {x = at.x, y = at.y, z = base, r = yaw}, true
            end
            d.dyn[fields.building] = encode(data)
        end
        list[#list + 1] = d
    end
    local lost = {}
    for name in pairs(missing) do lost[#lost + 1] = name end
    table.sort(lost)
    return list, lost
end

local function spawnSaved(t, at, opt)
    local list, lost = instantiate(t, at, opt)
    if not list then return nil end
    C.transaction("MageCreateBuilding", function()
        for _, d in ipairs(list) do editor.history:commitAction("MageCreateFloor", d, unspawn, spawn) end
    end)
    return list[1].id, lost
end

local function defaultTemplate()
    local d    = defaults
    local half = d.length / 2.0
    local p    = {dims = {}, dyn = {ends = "on", windows = Window.encode(freshWindows(true)), building = encode(newData(nil))},
                  nodes = {{-half, 0.0, d.floor, d.width, d.floor, 0.0, 0.0, 1.0}, {half, 0.0, d.floor, d.width, d.floor, 0.0, 0.0, 1.0}}}
    p.dyn.wall, p.dyn.walk = material(d.wall, d.wallTile), material(d.roof, d.roofTile)
    return {parts = {p}}
end

local function placeBatch(list)
    batching      = true
    local ok, err = pcall(function()
        for _, d in ipairs(list) do spawn(d) end
    end)
    batching = false
    if not ok then error(err, 0) end
end

local function unspawnAll(list)
    for i = #list, 1, -1 do
        if scenetree.findObjectById(list[i].id) then editor.deleteMesh(list[i].id) end
    end
    index(true)
end

local function spawnAll(list)
    local missing = {}
    for _, d in ipairs(list) do
        if not (d.id and scenetree.findObjectById(d.id)) then missing[#missing + 1] = d end
    end
    placeBatch(missing)
    index(true)
end

local function commitBatch(list)
    index(true)
    if #list == 0 then return end
    editor.history:commitAction("MageGenerate", {list = list}, function(data) unspawnAll(data.list) end, function(data) spawnAll(data.list) end, true)
end

-- =============================================================================
-- COPIES
-- =============================================================================

local function fix(v)
    local t = string.format("%.1f", v)
    return (t == "-0.0") and "0.0" or t
end

local function twinOf(id)
    local idx = index()
    local e   = idx.byId[id]
    if not e then return nil end
    local h = home(e, idx)
    local f = h.data.tpl
    if not f then return nil end
    local ids, at = group(h.id), {}
    for k, fid in ipairs(ids) do at[idx.byId[fid].data.key] = k end
    local axes = {}
    for axis in pairs(fields) do
        if axis ~= "building" then axes[#axes + 1] = axis end
    end
    table.sort(axes)
    local c, s     = math.cos(-f.r), math.sin(-f.r)
    local out, vec = {}, {}
    for _, fid in ipairs(ids) do
        local obj = scenetree.findObjectById(fid)
        local d   = idx.byId[fid].data
        if not obj then return nil end
        local snap = {}
        for _, k in ipairs(snapKeys) do snap[#snap + 1] = d.snap[k] and "1" or "0" end
        out[#out + 1] = table.concat({"F", at[d.below] or 0, at[d.host] or 0, d.free and 1 or 0, table.concat(snap)}, ",")
        for _, n in ipairs(nodesOf(obj)) do
            local x, y   = turned(n.pos.x - f.x, n.pos.y - f.y, c, s)
            local nx, ny = turned(n.normal.x, n.normal.y, c, s)
            out[#out + 1] = table.concat({fix(x), fix(y), fix(n.pos.z - f.z), fix(n.width), fix(n.depth), fix(nx), fix(ny), fix(n.normal.z)}, ",")
            for _, v in ipairs({x, y, n.pos.z - f.z, n.width, n.depth, nx, ny, n.normal.z}) do vec[#vec + 1] = v end
        end
        for _, axis in ipairs(axes) do
            out[#out + 1] = axis .. "=" .. (dyn(obj, fields[axis]) or "") .. "|" .. (dyn(obj, fields[axis] .. "_dims") or "")
        end
    end
    return table.concat(out, "\n"), {x = f.x, y = f.y, z = f.z, r = f.r}, vec
end

-- =============================================================================
-- RESHAPING
-- =============================================================================

local function rawNodes(id)
    local out = {}
    for _, n in ipairs(nodesOf(scenetree.findObjectById(id))) do
        out[#out + 1] = {n.pos.x, n.pos.y, n.pos.z, n.width, n.depth, n.normal.x, n.normal.y, n.normal.z}
    end
    return out
end

local function applyNodes(id, list)
    local obj = scenetree.findObjectById(id)
    if not obj then return end
    local count = obj:getNodeCount()
    while count < #list do
        local n = list[count + 1]
        editor.addMeshNode(id, {pos = vec3(n[1], n[2], n[3]), width = n[4], depth = n[5], normal = vec3(n[6], n[7], n[8]), index = appendAt})
        count = count + 1
    end
    while count > #list do
        editor.deleteMeshNode(obj, count - 1)
        count = count - 1
    end
    for i, n in ipairs(list) do
        editor.setNodePosition(obj, i - 1, vec3(n[1], n[2], n[3]))
        editor.setNodeWidth(obj, i - 1, n[4])
        editor.setNodeDepth(obj, i - 1, n[5])
        obj:setNodeNormal(i - 1, vec3(n[6], n[7], n[8]))
    end
    memory[id] = nil
end

local function applyShapes(list, key)
    for _, c in ipairs(list) do
        applyNodes(c.id, c[key])
        write(c.id, fields.building, c[key .. "Data"])
    end
    index(true)
end

local function reshape(list, name)
    if #list == 0 then return end
    editor.history:commitAction(name, {list = list}, function(data) applyShapes(data.list, "old") end, function(data) applyShapes(data.list, "new") end)
end

local function bottomOf(id)
    local obj = scenetree.findObjectById(id)
    return obj:getNodePosition(0).z - obj:getNodeDepth(0)
end

local function placeNodes(data, key)
    local obj = scenetree.findObjectById(data.id)
    for i, p in ipairs(data[key]) do editor.setNodePosition(obj, i - 1, p) end
end

local function settle(id, bottom)
    local obj      = scenetree.findObjectById(id)
    local d        = bottom - bottomOf(id)
    local old, new = {}, {}
    if math.abs(d) < tol then return obj:getNodePosition(0).z end
    for i = 0, obj:getNodeCount() - 1 do
        local p    = obj:getNodePosition(i)
        old[i + 1] = vec3(p.x, p.y, p.z)
        new[i + 1] = vec3(p.x, p.y, p.z + d)
    end
    editor.history:commitAction("MageSettleFloor", {id = id, old = old, new = new},
                                function(data) placeNodes(data, "old") end, function(data) placeNodes(data, "new") end)
    return new[1].z
end

local function restack(ids, bottom)
    for _, fid in ipairs(ids) do bottom = settle(fid, bottom) end
end

local function relink(ids)
    local idx = index(true)
    for i, fid in ipairs(ids) do
        local e = idx.byId[fid]
        local b = (i > 1) and idx.byId[ids[i - 1]].data.key or nil
        if e.data.below ~= b then
            e.data.below = b
            idx.topo     = nil
            C.setDynWithUndo({fid}, fields.building, encode(e.data))
        end
    end
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
    local cfg  = Window.parse(dyn(top, fields.windows)) or defaultWindows(false)
    local kept = {}
    for _, f in ipairs(cfg.floors) do
        if not f.at then kept[#kept + 1] = f end
    end
    cfg.floors    = (#kept > 0) and kept or defaultWindows(false).floors
    local low     = Window.parse(dyn(top, fields.windows))
    local roof    = low and low.mods.roof
    if roof and roof.part then
        cfg.mods.roof.on, cfg.mods.roof.faces, cfg.mods.roof.part = nil, {}, nil
    end
    local topData = parse(dyn(top, fields.building)) or newData(nil)
    local d       = nil
    C.transaction("MageAddFloor", function()
        if roof and not roof.part and (roof.on or next(roof.faces or {})) then
            roof.on, roof.faces = nil, {}
            C.setDynWithUndo({top:getID()}, fields.windows, Window.encode(low))
        end
        if not topData.key then
            topData.key = newKey()
            C.setDynWithUndo({top:getID()}, fields.building, encode(topData))
        end
        d = make(nodes, dyn(top, fields.wall), dyn(top, fields.walk), cfg, newData(topData.key))
    end)
    return d.id
end

local function sideOf(ns, i)
    local a, b = ns[math.max(1, i - 1)].pos, ns[math.min(#ns, i + 1)].pos
    local t    = vec3(b.x - a.x, b.y - a.y, 0)
    if t:length() > 1e-9 then t = t:normalized() end
    return vec3(t.y, -t.x, 0)
end

local function footprint(id)
    local ns          = nodesOf(scenetree.findObjectById(id))
    local right, left = {}, {}
    local top, base   = 0.0, math.huge
    for i, n in ipairs(ns) do
        local side        = sideOf(ns, i) * (n.width / 2.0)
        right[#right + 1] = vec3(n.pos.x + side.x, n.pos.y + side.y, 0)
        left[#ns - i + 1] = vec3(n.pos.x - side.x, n.pos.y - side.y, 0)
        top               = top + n.pos.z / #ns
        base              = math.min(base, n.pos.z - n.depth)
    end
    for _, p in ipairs(left) do right[#right + 1] = p end
    return {poly = right, top = top, base = base}
end

local function sticksOut(upper, lower)
    for _, p in ipairs(upper.poly) do
        if not C.inPoly(lower.poly, p) and C.polyDist(lower.poly, p) > overhang then return true end
    end
    return false
end

local function baseOf(id)
    local f              = footprint(id)
    local lx, ly, hx, hy = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(f.poly) do
        lx, ly = math.min(lx, p.x), math.min(ly, p.y)
        hx, hy = math.max(hx, p.x), math.max(hy, p.y)
    end
    local function round(v) return math.floor(v * 100.0 + 0.5) / 100.0 end
    return {x = round((lx + hx) / 2.0), y = round((ly + hy) / 2.0), z = round(f.base)}
end

local function edgeAt(ns, s)
    local at = 0.0
    for i = 2, #ns do
        local t = vec3(ns[i].pos.x - ns[i - 1].pos.x, ns[i].pos.y - ns[i - 1].pos.y, 0)
        local l = t:length()
        if at + l >= s - 1e-9 or i == #ns then
            local u = (l > 1e-9) and math.max(0.0, math.min(1.0, (s - at) / l)) or 0.0
            t       = (l > 1e-9) and t / l or vec3(1, 0, 0)
            return ns[i - 1].pos + (ns[i].pos - ns[i - 1].pos) * u, vec3(t.y, -t.x, 0), ns[i - 1].width + (ns[i].width - ns[i - 1].width) * u, t
        end
        at = at + l
    end
end

local function touching(id)
    local mine, others = {}, {}
    for _, fid in ipairs(chain(id)) do mine[fid] = true end
    for _, fid in ipairs(group(id)) do
        if not mine[fid] then
            local f = footprint(fid)
            others[#others + 1] = {poly = f.poly, lo = f.base, hi = f.top}
        end
    end
    if #others == 0 then return nil end
    local obj  = scenetree.findObjectById(id)
    local ns   = nodesOf(obj)
    local f    = footprint(id)
    local mid  = (f.base + f.top) / 2.0
    local roof = f.top - defaults.probe
    local function hit(p, z)
        for _, o in ipairs(others) do
            if z > o.lo and z < o.hi and (C.inPoly(o.poly, p) or C.polyDist(o.poly, p) <= defaults.touchTol) then return true end
        end
        return false
    end
    local len = 0.0
    for i = 2, #ns do len = len + vec3(ns[i].pos.x - ns[i - 1].pos.x, ns[i].pos.y - ns[i - 1].pos.y, 0):length() end
    local n                 = math.max(2, math.ceil(len / defaults.touchStep))
    local covered, cut, walls = {}, {right = {}, left = {}}, {right = {}, left = {}}
    local function runs(list, open, on, s)
        if on and not open then return s end
        if not on and open then list[#list + 1] = {open, s} end
        return on and open or nil
    end
    for _, face in ipairs({"right", "left"}) do
        local sign, cnt   = (face == "right") and 1.0 or -1.0, 0
        local atMid, atTop = nil, nil
        for k = 0, n do
            local s          = len * k / n
            local c, side, w = edgeAt(ns, s)
            local p          = c + side * (sign * (w / 2.0 + defaults.probe))
            local onMid      = hit(p, mid)
            if onMid then cnt = cnt + 1 end
            atMid = runs(walls[face], atMid, onMid, s)
            atTop = runs(cut[face], atTop, hit(p, roof), s)
        end
        if atMid then walls[face][#walls[face] + 1] = {atMid, len} end
        if atTop then cut[face][#cut[face] + 1] = {atTop, len} end
        covered[face] = cnt / (n + 1) >= defaults.covered
    end
    for _, e in ipairs({{"start", 0.0, -1.0}, {"end", len, 1.0}}) do
        local c, side, w, t  = edgeAt(ns, e[2])
        local m              = math.max(8, math.ceil(w / defaults.touchStep))
        local r, roofHits    = 0, 0
        local at             = nil
        walls[e[1]]          = {}
        for k = m, 0, -1 do
            local x     = w * (1.0 - k / m)
            local p     = c + side * (w * (k / m - 0.5)) + t * (e[3] * defaults.probe)
            local onMid = hit(p, mid)
            if onMid then r = r + 1 end
            if hit(p, roof) then roofHits = roofHits + 1 end
            at = runs(walls[e[1]], at, onMid, x)
        end
        if at then walls[e[1]][#walls[e[1]] + 1] = {at, w} end
        covered[e[1]] = r / (m + 1) >= defaults.covered
        cut[e[1]]     = roofHits / (m + 1) >= defaults.covered
    end
    return {covered = covered, cut = cut, walls = walls}
end

local function held(e)
    return e.data.snap.path and e.data.snap.width
end

local function stack(id)
    local idx = index()
    local e   = idx.byId[id]
    if not e then return nil end
    local low        = below(e, idx)
    local cover, top = false, true
    for _, o in ipairs(idx.list) do
        if o ~= e and o.data.below == e.data.key then
            top   = false
            cover = cover or held(o)
        end
    end
    local under, seen, cur = {}, {[e] = true}, low
    while cur and not seen[cur] do
        seen[cur]         = true
        under[#under + 1] = footprint(cur.id)
        cur               = below(cur, idx)
    end
    local out   = #under > 0 and sticksOut(footprint(e.id), under[1])
    local h     = home(e, idx)
    local touch = touching(id)
    return {base = low ~= nil and held(e), cover = cover, ground = low == nil, top = top, under = under, overhang = out,
            root = h.data.key, home = baseOf(h.id), floors = #group(h.id), covered = touch and touch.covered, cut = touch and touch.cut,
            walls = touch and touch.walls}
end

local function driver(id)
    local idx     = index()
    local e, seen = idx.byId[id], {}
    while e and e.data.snap.path and not seen[e] do
        seen[e] = true
        local b = below(e, idx)
        if not b then break end
        e = b
    end
    return e and e.id or id
end

local function ofKey(key)
    local idx = index()
    local e   = idx.byKey[key]
    return e and home(e, idx).id or nil
end

local function setData(id, b)
    C.setDynWithUndo({id}, fields.building, encode(b))
    index(true)
end

local function buildings()
    local idx = index()
    local t   = topo(idx)
    if t.buildings then return t.buildings end
    local out = {}
    for _, e in ipairs(idx.list) do
        if not below(e, idx) and not e.data.host then out[#out + 1] = {id = e.id, floors = #group(e.id)} end
    end
    t.buildings = out
    return out
end

local function moveFloor(id, dir)
    local ids = chain(id)
    local k   = nil
    for i, fid in ipairs(ids) do
        if fid == id then k = i end
    end
    local j = k and k + dir
    if not j or j < 1 or j > #ids then return false end
    local bottom   = bottomOf(ids[1])
    ids[k], ids[j] = ids[j], ids[k]
    relink(ids)
    restack(ids, bottom)
    return true
end

local function removeFloor(id)
    local ids  = chain(id)
    local rest = {}
    for _, fid in ipairs(ids) do
        if fid ~= id then rest[#rest + 1] = fid end
    end
    if #ids > 0 then restack(rest, bottomOf(ids[1])) end
    relink(rest)
    C.deleteWithUndo(id)
    return rest
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
-- WALLS
-- =============================================================================

local function along(ns, i, j)
    local t = vec3(ns[j].pos.x - ns[i].pos.x, ns[j].pos.y - ns[i].pos.y, 0)
    local l = t:length()
    if l < 1e-9 then return vec3(0, 0, 0), 0.0 end
    return t / l, l
end

local function isEnd(face)
    return face == "start" or face == "end"
end

local function wallOf(id)
    local d   = driver(id)
    local obj = scenetree.findObjectById(d)
    if not obj or obj:getNodeCount() < 2 then return nil end
    return {id = d, nodes = nodesOf(obj)}
end

local function span(snap, face)
    local ns, s = snap.nodes, 0.0
    if isEnd(face) then
        for i = 2, #ns do
            local _, l = along(ns, i - 1, i)
            s          = s + l
        end
        return s
    end
    for _, n in ipairs(ns) do s = s + n.width end
    return s / #ns
end

local function pushed(snap, face, d)
    local ns, out = snap.nodes, {}
    for i, n in ipairs(ns) do out[i] = {pos = vec3(n.pos.x, n.pos.y, n.pos.z), width = n.width} end
    if isEnd(face) then
        local i, j = 1, 2
        if face == "end" then i, j = #ns, #ns - 1 end
        local t, l = along(ns, j, i)
        d          = math.max(d, defaults.least - l)
        out[i].pos = out[i].pos + t * d
        return out, d
    end
    local lo = math.huge
    for _, n in ipairs(ns) do lo = math.min(lo, n.width) end
    d          = math.max(d, defaults.least - lo)
    local sign = (face == "right") and 1.0 or -1.0
    for i, n in ipairs(ns) do
        out[i].width = n.width + d
        out[i].pos   = out[i].pos + sideOf(ns, i) * (sign * d / 2.0)
    end
    return out, d
end

local function placeWall(id, nodes)
    local obj = scenetree.findObjectById(id)
    if not obj then return end
    for i, n in ipairs(nodes) do
        editor.setNodePosition(obj, i - 1, vec3(n.pos.x, n.pos.y, n.pos.z))
        editor.setNodeWidth(obj, i - 1, n.width)
    end
    sync(id)
end

local function commitWall(id, old, new)
    editor.history:commitAction("MagePushWall", {id = id, old = old, new = new},
                                function(data) placeWall(data.id, data.old) end, function(data) placeWall(data.id, data.new) end)
end

local function detachData(id)
    local old    = dyn(scenetree.findObjectById(id), fields.building) or ""
    local b      = parse(old) or newData(nil)
    b.snap.path  = false
    b.snap.width = false
    return old, encode(b)
end

local function writeData(id, str)
    write(id, fields.building, str)
    index(true)
end

local function commitDetach(id, old, new)
    editor.history:commitAction("MageDetachFloor", {id = id, old = old, new = new},
                                function(data) writeData(data.id, data.old) end, function(data) writeData(data.id, data.new) end)
end

local function ownNodes(id)
    local obj = scenetree.findObjectById(id)
    if not obj or obj:getNodeCount() < 2 then return nil end
    return {id = id, nodes = nodesOf(obj)}
end

local function pushWall(id, face, d, from)
    local snap = from and ownNodes(id) or wallOf(id)
    if not snap then return nil end
    local new, done = pushed(snap, face, d)
    C.transaction("MagePushWall", function()
        if from then
            local old, cut = detachData(id)
            commitDetach(id, old, cut)
        end
        commitWall(snap.id, snap.nodes, new)
    end)
    return done
end

local function anchor(snap, face, fid)
    local ns   = snap.nodes
    local f    = footprint(fid)
    local z    = f.top - height(fid) / 2.0
    local p, n
    if isEnd(face) then
        local i, j = 1, 2
        if face == "end" then i, j = #ns, #ns - 1 end
        n = along(ns, j, i)
        p = ns[i].pos
    else
        local half, k, at = span(snap, "start") / 2.0, 1, 0.0
        for i = 2, #ns do
            local _, l = along(ns, i - 1, i)
            k          = i - 1
            if at + l >= half then break end
            at = at + l
        end
        local t, l = along(ns, k, k + 1)
        local u    = (l > 1e-9) and math.min(1.0, (half - at) / l) or 0.0
        local w    = ns[k].width + (ns[k + 1].width - ns[k].width) * u
        n          = vec3(t.y, -t.x, 0) * ((face == "right") and 1.0 or -1.0)
        p          = ns[k].pos + (ns[k + 1].pos - ns[k].pos) * u + n * (w / 2.0)
    end
    return vec3(p.x, p.y, z), n
end

local function view(list)
    local ids = (type(list) == "table") and list or group(list)
    if #ids == 0 then ids = {list} end
    local lo, hi = vec3(math.huge, math.huge, math.huge), vec3(-math.huge, -math.huge, -math.huge)
    for _, fid in ipairs(ids) do
        local f = footprint(fid)
        for _, p in ipairs(f.poly) do
            lo.x, lo.y = math.min(lo.x, p.x), math.min(lo.y, p.y)
            hi.x, hi.y = math.max(hi.x, p.x), math.max(hi.y, p.y)
        end
        lo.z, hi.z = math.min(lo.z, f.base), math.max(hi.z, f.top)
    end
    local ns = nodesOf(scenetree.findObjectById(ids[1]))
    local t  = along(ns, 1, #ns)
    if t:length() < 1e-9 then t = vec3(1, 0, 0) end
    return {center = (lo + hi) / 2.0, right = vec3(t.y, -t.x, 0), size = (hi - lo):length()}
end

-- =============================================================================
-- PARTS
-- =============================================================================

local function addUnit(id)
    local obj = scenetree.findObjectById(id)
    local e   = index().byId[id]
    if not (obj and e and obj:getNodeCount() >= 2) then return nil end
    local d             = defaults
    local ns            = nodesOf(obj)
    local len           = span({nodes = ns}, "start")
    local c, side, w, t = edgeAt(ns, len / 2.0)
    local L, W, h       = math.min(d.unitLen, math.max(d.least, len / 2.0)), d.unitWid, height(id)
    local mid           = c + side * (w / 2.0 + W / 2.0)
    local base          = ns[1].pos.z - ns[1].depth
    local ids, from     = chain(id), 1
    for k, fid in ipairs(ids) do
        if fid == id then from = k end
    end
    local n, wall, roof = math.max(1, #ids - from), dyn(obj, fields.wall), dyn(obj, fields.walk)
    local first         = nil
    C.transaction("MageAddUnit", function()
        local below = nil
        for k = 1, n do
            local z     = base + h * k
            local data  = newData(below)
            local cfg   = defaultWindows(k == 1)
            local nodes = {
                {pos = vec3(mid.x - t.x * L / 2.0, mid.y - t.y * L / 2.0, z), width = W, depth = h, normal = vec3(0, 0, 1)},
                {pos = vec3(mid.x + t.x * L / 2.0, mid.y + t.y * L / 2.0, z), width = W, depth = h, normal = vec3(0, 0, 1)},
            }
            if k == 1 then data.host = e.data.key end
            cfg.faces.left = false
            local made     = make(nodes, wall, roof, cfg, data)
            first          = first or made
            below          = data.key
        end
    end)
    index(true)
    return first.id
end

docked = function(id, want, step)
    local idx = index()
    local e   = idx.byId[id]
    local h   = e and e.data.host and idx.byKey[e.data.host]
    if not h or root(e, idx) ~= e then return nil end
    local ns              = nodesOf(scenetree.findObjectById(id))
    local len             = span({nodes = ns}, "start")
    local c0, _, w, t0    = edgeAt(ns, len / 2.0)
    local poly, area      = footprint(h.id).poly, 0.0
    want                  = want or c0
    for i = 1, #poly do
        local a, b = poly[i], poly[i % #poly + 1]
        area       = area + a.x * b.y - b.x * a.y
    end
    local best, bestD = nil, math.huge
    for i = 1, #poly do
        local a, b = poly[i], poly[i % #poly + 1]
        local d    = vec3(b.x - a.x, b.y - a.y, 0)
        local el   = d:length()
        if el > 1e-6 then
            d       = d / el
            local u = math.max(0.0, math.min(el, (want.x - a.x) * d.x + (want.y - a.y) * d.y))
            local q = vec3(a.x + d.x * u, a.y + d.y * u, 0)
            local g = math.sqrt((q.x - want.x) ^ 2 + (q.y - want.y) ^ 2)
            if g < bestD then best, bestD = {a = a, d = d, el = el, u = u}, g end
        end
    end
    if not best then return nil end
    local half = math.min(len / 2.0, best.el / 2.0)
    local u    = best.u
    if step then u = math.floor(u / step + 0.5) * step end
    u                = math.max(half, math.min(best.el - half, u))
    local n          = vec3(best.d.y, -best.d.x, 0) * ((area >= 0) and 1.0 or -1.0)
    local c1         = vec3(best.a.x + best.d.x * u, best.a.y + best.d.y * u, 0) + n * (w / 2.0)
    local t1         = vec3(-n.y, n.x, 0)
    local cs, sn     = t0.x * t1.x + t0.y * t1.y, t0.x * t1.y - t0.y * t1.x
    local out        = {}
    for k, fid in ipairs(chain(id)) do
        local f = idx.byId[fid]
        if k == 1 or not f.data.snap.path then
            local old, new = nodesOf(scenetree.findObjectById(fid)), {}
            for i, nd in ipairs(old) do
                local dx, dy = nd.pos.x - c0.x, nd.pos.y - c0.y
                new[i]       = {pos = vec3(c1.x + dx * cs - dy * sn, c1.y + dx * sn + dy * cs, nd.pos.z), width = nd.width}
            end
            out[#out + 1] = {id = fid, old = old, new = new}
        end
    end
    return out
end

local function faceDir(id, face)
    local obj = scenetree.findObjectById(id)
    if not obj or obj:getNodeCount() < 2 then return nil end
    local ns = nodesOf(obj)
    if face == "start" then return (along(ns, 2, 1)) end
    if face == "end" then return (along(ns, #ns - 1, #ns)) end
    local _, side = edgeAt(ns, span({nodes = ns}, "start") / 2.0)
    return (face == "right") and side or side * -1.0
end

local function faceToward(id, dir)
    local best, bestD = nil, 0.7
    for _, f in ipairs(Window.faceKeys) do
        local d = faceDir(id, f)
        local v = d and (d.x * dir.x + d.y * dir.y) or -1.0
        if v > bestD then best, bestD = f, v end
    end
    return best
end

local function faceLines(id)
    local obj = scenetree.findObjectById(id)
    if not obj or obj:getNodeCount() < 2 then return nil end
    local f, n  = footprint(id), obj:getNodeCount()
    local poly  = f.poly
    local lines = {right = {}, left = {}, start = {poly[#poly], poly[1]}, ["end"] = {poly[n], poly[n + 1]}}
    for i = 1, n do lines.right[i] = poly[i] end
    for i = n + 1, #poly do lines.left[#lines.left + 1] = poly[i] end
    return lines, f.base, f.top, poly
end

local function faceAt(id, p)
    local lines = faceLines(id)
    if not lines then return nil end
    local best, bestD = nil, math.huge
    for _, f in ipairs(Window.faceKeys) do
        local l = lines[f]
        local m = math.huge
        for i = 1, #l - 1 do m = math.min(m, C.polyDist({l[i], l[i + 1]}, p)) end
        if m < bestD then best, bestD = f, m end
    end
    return best
end

local function removePart(ids)
    local gone = {}
    for _, fid in ipairs(ids) do gone[fid] = true end
    local all, rest = chain(ids[1]), {}
    for _, fid in ipairs(all) do
        if not gone[fid] then rest[#rest + 1] = fid end
    end
    C.transaction("MageRemovePart", function()
        if #rest > 0 then
            restack(rest, bottomOf(all[1]))
            relink(rest)
        end
        for _, fid in ipairs(ids) do C.deleteWithUndo(fid) end
    end)
    index(true)
    return rest
end

local function movers(list, k)
    local out = {}
    for j, q in ipairs(list) do
        if list[k].kind == "main" or j == k then
            for _, fid in ipairs(q.lead) do out[#out + 1] = fid end
        end
    end
    return out
end

local function moved(snap, delta)
    local out = {}
    for i, n in ipairs(snap.nodes) do out[i] = {pos = vec3(n.pos.x + delta.x, n.pos.y + delta.y, n.pos.z), width = n.width} end
    return out
end

local function placeAll(list, key)
    for _, w in ipairs(list) do placeWall(w.id, w[key]) end
end

local function commitMove(list)
    editor.history:commitAction("MageMovePart", {list = list}, function(data) placeAll(data.list, "old") end, function(data) placeAll(data.list, "new") end)
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.defaults        = defaults
M.snapKeys        = snapKeys
M.parse           = parse
M.encode          = encode
M.newData         = newData
M.defaultWindows  = defaultWindows
M.configure       = configure
M.dataOf          = dataOf
M.index           = index
M.chain           = chain
M.stack           = stack
M.touching        = touching
M.ofKey           = ofKey
M.driver          = driver
M.sync            = sync
M.create          = create
M.saved           = saved
M.editSaved       = editSaved
M.capture         = capture
M.spawnSaved      = spawnSaved
M.instantiate     = instantiate
M.defaultTemplate = defaultTemplate
M.placeBatch      = placeBatch
M.commitBatch     = commitBatch
M.twinOf          = twinOf
M.rawNodes        = rawNodes
M.reshape         = reshape
M.footprint       = footprint
M.addFloor        = addFloor
M.setData         = setData
M.setHeight       = setHeight
M.moveFloor       = moveFloor
M.buildings       = buildings
M.removeFloor     = removeFloor
M.height          = height
M.reset           = reset
M.wallOf          = wallOf
M.span            = span
M.pushed          = pushed
M.placeWall       = placeWall
M.commitWall      = commitWall
M.pushWall        = pushWall
M.detachData      = detachData
M.writeData       = writeData
M.commitDetach    = commitDetach
M.ownNodes        = ownNodes
M.anchor          = anchor
M.view            = view
M.group           = group
M.homeOf          = homeOf
M.parts           = parts
M.addUnit         = addUnit
M.removePart      = removePart
M.movers          = movers
M.faceDir         = faceDir
M.faceToward      = faceToward
M.faceAt          = faceAt
M.faceLines       = faceLines
M.docked         = function(id, want, step) return docked(id, want, step) end
M.moved      = moved
M.placeAll   = placeAll
M.commitMove = commitMove

return M
