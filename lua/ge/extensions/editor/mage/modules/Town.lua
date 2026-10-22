-- =============================================================================
-- MaGE - buildings placed along roads
-- Version: 1.0.2
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local Window = require("editor/mage/core/Window")
local B      = require("editor/mage/modules/Building")
local C      = require("editor/mage/core/Common")

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local atan2     = math.atan2 or math.atan
local quarter   = math.pi / 2.0
local stepOn    = 1.0
local piece     = 2.0
local probe     = 1.0
local cellSize  = 32.0
local lift      = 20.0
local reach     = 60.0
local raised    = 0.6
local maxDrop   = 2.5
local snapReach = 40.0
local tol       = 0.05
local shrink    = 0.05
local maxPush   = 3.0
local marker    = "WarningMaterial"
local modulus   = 2147483647
local parallel  = 0.9
local foldRatio = 2.0

local defaults = {setback = 3.0, gapMin = 1.0, gapMax = 4.0, sides = "front", snap = false}

-- =============================================================================
-- RANDOM
-- =============================================================================

local function rng(seed)
    local x = math.floor(math.abs(seed or 1)) % (modulus - 1) + 1
    return function()
        x = (x * 16807) % modulus
        return (x - 1) / (modulus - 1)
    end
end

local function pick(r, n)
    return math.min(n, math.floor(r() * n) + 1)
end

-- =============================================================================
-- SHAPES
-- =============================================================================

local function turned(x, y, a)
    local c, s = math.cos(a), math.sin(a)
    return x * c - y * s, x * s + y * c
end

local function sideAt(nodes, i)
    local a, b   = nodes[math.max(1, i - 1)], nodes[math.min(#nodes, i + 1)]
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local l      = math.sqrt(dx * dx + dy * dy)
    if l < 1e-9 then return 0.0, 0.0 end
    return dy / l, -dx / l
end

local function polyOf(nodes)
    local right, left = {}, {}
    for i, n in ipairs(nodes) do
        local sx, sy = sideAt(nodes, i)
        local h      = n[4] / 2.0
        right[#right + 1]  = {n[1] + sx * h, n[2] + sy * h}
        left[#nodes - i + 1] = {n[1] - sx * h, n[2] - sy * h}
    end
    for _, p in ipairs(left) do right[#right + 1] = p end
    return right
end

local function frontOf(p)
    local cfg  = Window.parse(p.dyn.windows)
    local face = "right"
    for _, f in ipairs(cfg and cfg.floors or {}) do
        if f.at and f.face then
            face = f.face
            break
        end
    end
    local ns = p.nodes
    if face == "start" or face == "end" then
        local a, b = ns[2], ns[1]
        if face == "end" then a, b = ns[#ns - 1], ns[#ns] end
        local dx, dy = b[1] - a[1], b[2] - a[2]
        local l      = math.max(1e-9, math.sqrt(dx * dx + dy * dy))
        return dx / l, dy / l
    end
    local total, at = 0.0, 0.0
    for i = 2, #ns do total = total + math.sqrt((ns[i][1] - ns[i - 1][1]) ^ 2 + (ns[i][2] - ns[i - 1][2]) ^ 2) end
    local sx, sy = 0.0, 0.0
    for i = 2, #ns do
        local dx, dy = ns[i][1] - ns[i - 1][1], ns[i][2] - ns[i - 1][2]
        local l      = math.sqrt(dx * dx + dy * dy)
        if l > 1e-9 and (at + l >= total / 2.0 - 1e-9 or i == #ns) then
            sx, sy = dy / l, -dx / l
            break
        end
        at = at + l
    end
    if face == "left" then return -sx, -sy end
    return sx, sy
end

local function shapeOf(t)
    local polys, hi, home = {}, 0.0, nil
    for _, p in ipairs(type(t) == "table" and type(t.parts) == "table" and t.parts or {}) do
        if type(p) == "table" and type(p.nodes) == "table" and #p.nodes >= 2 and type(p.dyn) == "table" then
            polys[#polys + 1] = polyOf(p.nodes)
            for _, n in ipairs(p.nodes) do hi = math.max(hi, n[3]) end
            local data = B.parse(p.dyn.building)
            if not home and data and not data.below and not data.host then home = p end
        end
    end
    if #polys == 0 then return nil end
    local fx, fy = frontOf(home or t.parts[1])
    return {polys = polys, front = atan2(fy, fx), hi = hi}
end

local function extents(shape, yaw, tx, ty)
    local aLo, aHi, dLo, dHi = math.huge, -math.huge, math.huge, -math.huge
    for _, poly in ipairs(shape.polys) do
        for _, q in ipairs(poly) do
            local x, y = turned(q[1], q[2], yaw)
            local a, d = x * tx + y * ty, x * ty - y * tx
            aLo, aHi   = math.min(aLo, a), math.max(aHi, a)
            dLo, dHi   = math.min(dLo, d), math.max(dHi, d)
        end
    end
    return aLo, aHi, dLo, dHi
end

local function outline(shape, at, yaw)
    local out = {}
    for _, poly in ipairs(shape.polys) do
        local w = {}
        for _, q in ipairs(poly) do
            local x, y = turned(q[1], q[2], yaw)
            w[#w + 1]  = {at.x + x, at.y + y}
        end
        out[#out + 1] = w
    end
    return out
end

local function facing(shape, nx, ny, k)
    return atan2(-ny, -nx) - (shape.front + (k or 0) * quarter)
end

-- =============================================================================
-- ROADS
-- =============================================================================

local function spline(p0, p1, p2, p3, u)
    local u2, u3 = u * u, u * u * u
    local function at(a, b, c, d)
        return 0.5 * (2 * b + (c - a) * u + (2 * a - 5 * b + 4 * c - d) * u2 + (3 * b - a - 3 * c + d) * u3)
    end
    return {at(p0[1], p1[1], p2[1], p3[1]), at(p0[2], p1[2], p2[2], p3[2]), at(p0[3], p1[3], p2[3], p3[3]), p1[4] + (p2[4] - p1[4]) * u}
end

local function smooth(nodes)
    if #nodes < 3 then return nodes end
    local out = {}
    for i = 1, #nodes - 1 do
        local p0, p1, p2, p3 = nodes[math.max(1, i - 1)], nodes[i], nodes[i + 1], nodes[math.min(#nodes, i + 2)]
        local l              = math.sqrt((p2[1] - p1[1]) ^ 2 + (p2[2] - p1[2]) ^ 2)
        local n              = math.max(1, math.ceil(l / piece))
        for k = 0, n - 1 do out[#out + 1] = spline(p0, p1, p2, p3, k / n) end
    end
    out[#out + 1] = nodes[#nodes]
    return out
end

local function lineOf(pts, id)
    local cum = {0.0}
    for i = 2, #pts do cum[i] = cum[i - 1] + math.sqrt((pts[i][1] - pts[i - 1][1]) ^ 2 + (pts[i][2] - pts[i - 1][2]) ^ 2) end
    return {id = id, pts = pts, cum = cum, len = cum[#cum]}
end

local function reversed(line)
    local pts = {}
    for i = #line.pts, 1, -1 do pts[#pts + 1] = line.pts[i] end
    return lineOf(pts, line.id)
end

local function roadOf(id)
    local obj = scenetree.findObjectById(id)
    local cls = obj and obj:getClassName()
    if (cls ~= "DecalRoad" and cls ~= "MeshRoad") or obj:getNodeCount() < 2 then return nil end
    local nodes = {}
    for i = 0, obj:getNodeCount() - 1 do
        local p = obj:getNodePosition(i)
        local w = obj:getNodeWidth(i)
        nodes[#nodes + 1] = {p.x, p.y, p.z, (w and w > 0) and w / 2.0 or 1.0}
    end
    local line = lineOf(smooth(nodes), id)
    if line.len < 1e-6 then return nil end
    return line
end

local function pointAt(line, s)
    local pts, cum = line.pts, line.cum
    s              = math.max(0.0, math.min(line.len, s))
    local lo, hi   = 1, #pts
    while hi - lo > 1 do
        local mid = math.floor((lo + hi) / 2)
        if cum[mid] <= s then lo = mid else hi = mid end
    end
    local l    = cum[hi] - cum[lo]
    local u    = (l > 1e-9) and (s - cum[lo]) / l or 0.0
    local a, b = pts[lo], pts[hi]
    return a[1] + (b[1] - a[1]) * u, a[2] + (b[2] - a[2]) * u, a[3] + (b[3] - a[3]) * u, a[4] + (b[4] - a[4]) * u, lo
end

local function widest(line, s0, s1)
    local _, _, _, w0, i0 = pointAt(line, s0)
    local _, _, _, w1, i1 = pointAt(line, s1)
    local w               = math.max(w0, w1)
    for i = i0, i1 do w = math.max(w, line.pts[i][4]) end
    return w
end

local function drivable()
    local out = {}
    for _, nm in ipairs(scenetree.findClassObjects("DecalRoad") or {}) do
        local obj = scenetree.findObject(nm)
        local v   = obj and tonumber(C.objField(obj, "drivability"))
        if v and v > 0 and C.objField(obj, "material") ~= marker then out[#out + 1] = obj:getID() end
    end
    table.sort(out)
    return out
end

local function obstacles()
    local out = drivable()
    for _, nm in ipairs(scenetree.findClassObjects("DecalRoad") or {}) do
        local obj = scenetree.findObject(nm)
        if obj and C.objField(obj, "material") == marker then out[#out + 1] = obj:getID() end
    end
    for _, nm in ipairs(scenetree.findClassObjects("MeshRoad") or {}) do
        local obj = scenetree.findObject(nm)
        if obj and not B.dataOf(obj:getID()) then out[#out + 1] = obj:getID() end
    end
    table.sort(out)
    return out
end

-- =============================================================================
-- GRID
-- =============================================================================

local function cellKey(ix, iy)
    return ix .. ":" .. iy
end

local function newGrid()
    return {cells = {}}
end

local function gridAdd(g, item, lx, ly, hx, hy)
    for ix = math.floor(lx / cellSize), math.floor(hx / cellSize) do
        for iy = math.floor(ly / cellSize), math.floor(hy / cellSize) do
            local k = cellKey(ix, iy)
            local l = g.cells[k] or {}
            g.cells[k] = l
            l[#l + 1]  = item
        end
    end
end

local function gridNear(g, lx, ly, hx, hy)
    local out, seen = {}, {}
    for ix = math.floor(lx / cellSize), math.floor(hx / cellSize) do
        for iy = math.floor(ly / cellSize), math.floor(hy / cellSize) do
            for _, it in ipairs(g.cells[cellKey(ix, iy)] or {}) do
                if not seen[it] then
                    seen[it]      = true
                    out[#out + 1] = it
                end
            end
        end
    end
    return out
end

local function addRoad(g, line)
    for i = 2, #line.pts do
        local a, b = line.pts[i - 1], line.pts[i]
        local h    = math.max(a[4], b[4])
        gridAdd(g, {ax = a[1], ay = a[2], bx = b[1], by = b[2], half = h, id = line.id},
                math.min(a[1], b[1]) - h, math.min(a[2], b[2]) - h, math.max(a[1], b[1]) + h, math.max(a[2], b[2]) + h)
    end
end

local function segDist(px, py, s)
    local dx, dy = s.bx - s.ax, s.by - s.ay
    local l2     = dx * dx + dy * dy
    local u      = (l2 > 1e-12) and math.max(0.0, math.min(1.0, ((px - s.ax) * dx + (py - s.ay) * dy) / l2)) or 0.0
    local qx, qy = s.ax + dx * u - px, s.ay + dy * u - py
    return math.sqrt(qx * qx + qy * qy)
end

local function boxOf(poly)
    local lx, ly, hx, hy = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(poly) do
        lx, ly = math.min(lx, p[1]), math.min(ly, p[2])
        hx, hy = math.max(hx, p[1]), math.max(hy, p[2])
    end
    return lx, ly, hx, hy
end

-- =============================================================================
-- OVERLAP
-- =============================================================================

local function inside(poly, x, y)
    local hit, j = false, #poly
    for i = 1, #poly do
        local a, b = poly[i], poly[j]
        if (a[2] > y) ~= (b[2] > y) and x < (b[1] - a[1]) * (y - a[2]) / (b[2] - a[2]) + a[1] then hit = not hit end
        j = i
    end
    return hit
end

local function crosses(a, b, c, d)
    local function side(p, q, r) return (q[1] - p[1]) * (r[2] - p[2]) - (q[2] - p[2]) * (r[1] - p[1]) end
    local d1, d2 = side(a, b, c), side(a, b, d)
    local d3, d4 = side(c, d, a), side(c, d, b)
    return ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0))
end

local function overlap(p, q)
    for _, v in ipairs(p) do
        if inside(q, v[1], v[2]) then return true end
    end
    for _, v in ipairs(q) do
        if inside(p, v[1], v[2]) then return true end
    end
    for i = 1, #p do
        local a, b = p[i], p[i % #p + 1]
        for j = 1, #q do
            if crosses(a, b, q[j], q[j % #q + 1]) then return true end
        end
    end
    return false
end

local function shrunk(poly)
    local cx, cy = 0.0, 0.0
    for _, v in ipairs(poly) do cx, cy = cx + v[1] / #poly, cy + v[2] / #poly end
    local out = {}
    for _, v in ipairs(poly) do
        local dx, dy = v[1] - cx, v[2] - cy
        local l      = math.sqrt(dx * dx + dy * dy)
        local f      = (l > shrink) and (l - shrink) / l or 0.0
        out[#out + 1] = {cx + dx * f, cy + dy * f}
    end
    return out
end

local function samples(poly)
    local out = {}
    for i = 1, #poly do
        local a, b = poly[i], poly[i % #poly + 1]
        local l    = math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
        local n    = math.max(1, math.ceil(l / probe))
        for k = 0, n - 1 do out[#out + 1] = {a[1] + (b[1] - a[1]) * k / n, a[2] + (b[2] - a[2]) * k / n} end
    end
    return out
end

-- =============================================================================
-- GROUND
-- =============================================================================

local function terrainAt(x, y)
    local h = core_terrain.getTerrainHeight(vec3(x, y, 0))
    if h and h > -1e6 then return h end
    return nil
end

local function groundAt(x, y, zref)
    local d = castRayStatic(vec3(x, y, zref + lift), vec3(0, 0, -1), lift + reach)
    if d and d < lift + reach then return zref + lift - d end
    return terrainAt(x, y)
end

local function standOn(polys, zref, strict)
    local lo, hi = math.huge, -math.huge
    local pts    = {}
    for _, poly in ipairs(polys) do
        local cx, cy = 0.0, 0.0
        for _, v in ipairs(poly) do
            pts[#pts + 1] = v
            cx, cy        = cx + v[1] / #poly, cy + v[2] / #poly
        end
        pts[#pts + 1] = {cx, cy}
    end
    for _, v in ipairs(pts) do
        local z = groundAt(v[1], v[2], zref)
        if z then
            local t = strict and terrainAt(v[1], v[2])
            if t and z - t > raised then return nil end
            lo, hi = math.min(lo, z), math.max(hi, z)
        end
    end
    if lo == math.huge then return zref end
    if strict and hi - lo > maxDrop then return nil end
    return lo
end

-- =============================================================================
-- PLACING
-- =============================================================================

local function clearance(job, polys)
    local best, who = math.huge, nil
    for _, poly in ipairs(polys) do
        local lx, ly, hx, hy = boxOf(poly)
        local m              = job.reachOut
        local near           = gridNear(job.roads, lx - m, ly - m, hx + m, hy + m)
        if #near > 0 then
            for _, v in ipairs(samples(poly)) do
                for _, sg in ipairs(near) do
                    local c = segDist(v[1], v[2], sg) - sg.half
                    if c < best then best, who = c, sg.id end
                end
            end
        end
    end
    return best, who
end

local function toEdges(poly, x, y)
    local best = math.huge
    for i = 1, #poly do
        local a, b = poly[i], poly[i % #poly + 1]
        best       = math.min(best, segDist(x, y, {ax = a[1], ay = a[2], bx = b[1], by = b[2]}))
    end
    return best
end

local function gapOf(p, q)
    if overlap(p, q) then return 0.0 end
    local best = math.huge
    for _, v in ipairs(p) do best = math.min(best, toEdges(q, v[1], v[2])) end
    for _, v in ipairs(q) do best = math.min(best, toEdges(p, v[1], v[2])) end
    return best
end

local function taken(job, polys)
    local g = job.opts.gapMin
    for _, poly in ipairs(polys) do
        local small          = shrunk(poly)
        local lx, ly, hx, hy = boxOf(poly)
        for _, o in ipairs(gridNear(job.built, lx - g, ly - g, hx + g, hy + g)) do
            if g <= tol then
                if overlap(small, o) then return true end
            elseif gapOf(poly, o) < g - tol then
                return true
            end
        end
    end
    return false
end

local function remember(job, polys)
    for _, poly in ipairs(polys) do
        local lx, ly, hx, hy = boxOf(poly)
        gridAdd(job.built, poly, lx, ly, hx, hy)
    end
end

local function spanAt(line, s0, shape, k)
    local x0, y0 = pointAt(line, s0)
    local x1, y1 = pointAt(line, s0 + 1.0)
    local tx, ty = 1.0, 0.0
    local l      = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
    if l > 1e-9 then tx, ty = (x1 - x0) / l, (y1 - y0) / l end
    local aLo, aHi = extents(shape, facing(shape, ty, -tx, k), tx, ty)
    return aHi - aLo
end

local function frameOn(line, s0, span, shape, k)
    local xa, ya = pointAt(line, s0)
    local xb, yb = pointAt(line, s0 + span)
    local f      = {tx = 1.0, ty = 0.0, mx = (xa + xb) / 2.0, my = (ya + yb) / 2.0, s0 = s0, span = span}
    local cl     = math.sqrt((xb - xa) ^ 2 + (yb - ya) ^ 2)
    if cl > 1e-9 then f.tx, f.ty = (xb - xa) / cl, (yb - ya) / cl end
    f.nx, f.ny                 = f.ty, -f.tx
    f.yaw                      = facing(shape, f.nx, f.ny, k)
    f.bLo, f.bHi, f.dLo, f.dHi = extents(shape, f.yaw, f.tx, f.ty)
    f.half                     = widest(line, s0, s0 + span)
    return f
end

local function normalAt(line, s)
    local x0, y0 = pointAt(line, s - 0.5)
    local x1, y1 = pointAt(line, s + 0.5)
    local dx, dy = x1 - x0, y1 - y0
    local l      = math.max(1e-9, math.sqrt(dx * dx + dy * dy))
    return dy / l, -dx / l
end

local function radius(line, s0, s1)
    local xa, ya = pointAt(line, s0)
    local xm, ym = pointAt(line, (s0 + s1) / 2.0)
    local xb, yb = pointAt(line, s1)
    local cross  = (xm - xa) * (yb - ym) - (ym - ya) * (xb - xm)
    if math.abs(cross) < 1e-9 then return math.huge, 0.0 end
    local a = math.sqrt((xm - xa) ^ 2 + (ym - ya) ^ 2)
    local b = math.sqrt((xb - xm) ^ 2 + (yb - ym) ^ 2)
    local c = math.sqrt((xb - xa) ^ 2 + (yb - ya) ^ 2)
    return a * b * c / (2.0 * math.abs(cross)), cross
end

local function resample(nodes)
    local out = {nodes[1]}
    for i = 2, #nodes do
        local a, b = nodes[i - 1], nodes[i]
        local n    = math.max(1, math.ceil(math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2) / piece))
        for k = 1, n do
            local q = {}
            for j = 1, 8 do q[j] = a[j] + (b[j] - a[j]) * k / n end
            out[#out + 1] = q
        end
    end
    return out
end

local function placeOn(f, entry, setback, push)
    local off = f.half + setback - f.dLo + push
    local at  = {x = f.mx - f.tx * (f.bLo + f.bHi) / 2.0 + f.nx * off, y = f.my - f.ty * (f.bLo + f.bHi) / 2.0 + f.ny * off}
    return {at = at, yaw = f.yaw, polys = outline(entry.shape, at, f.yaw)}
end

local function lotAt(job, line, s0, entry, k)
    local span = spanAt(line, s0, entry.shape, k)
    if s0 + span > line.len then return nil, span end
    local _, _, z0 = pointAt(line, s0)
    local f        = frameOn(line, s0, span, entry.shape, k)
    local push     = 0.0
    for _ = 1, 3 do
        local lot    = placeOn(f, entry, job.opts.setback, push)
        local c, who = clearance(job, lot.polys)
        if c >= job.opts.setback - tol then
            if taken(job, lot.polys) then return nil, span end
            lot.base = standOn(lot.polys, z0, true)
            if not lot.base then return nil, span end
            return lot, span
        end
        if who ~= line.id or push >= maxPush then return nil, span end
        push = math.min(maxPush, push + (job.opts.setback - c) + 0.01)
    end
    return nil, span
end

local function existing()
    local out = {}
    for _, e in ipairs(B.index(true).list) do
        local f = B.footprint(e.id)
        if f then
            local poly = {}
            for _, p in ipairs(f.poly) do poly[#poly + 1] = {p.x, p.y} end
            out[#out + 1] = poly
        end
    end
    return out
end

local function newJob(targets, obstacles, pool, opts)
    local o = {}
    for k, v in pairs(defaults) do o[k] = v end
    for k, v in pairs(opts or {}) do o[k] = v end
    o.gapMax  = math.max(o.gapMin, o.gapMax)
    local job = {opts = o, pool = {}, roads = newGrid(), built = newGrid(), lines = {}, k = 0, out = {}, reachOut = 0.0, seed = o.seed or 1}
    for _, e in ipairs(pool) do
        local shape = shapeOf(e.t)
        if shape then job.pool[#job.pool + 1] = {name = e.name, t = e.t, shape = shape} end
    end
    local seen, wide = {}, 0.0
    local function add(id, target)
        if seen[id] then
            if target and not seen[id].target then
                seen[id].target    = true
                job.lines[#job.lines + 1] = seen[id].line
            end
            return
        end
        local line = roadOf(id)
        if not line then return end
        seen[id] = {line = line, target = target}
        addRoad(job.roads, line)
        for _, p in ipairs(line.pts) do wide = math.max(wide, p[4]) end
        if target then job.lines[#job.lines + 1] = line end
    end
    for _, id in ipairs(targets) do add(id, true) end
    for _, id in ipairs(obstacles) do add(id, false) end
    job.reachOut = wide + o.setback + 1.0
    for _, poly in ipairs(existing()) do
        local lx, ly, hx, hy = boxOf(poly)
        gridAdd(job.built, poly, lx, ly, hx, hy)
    end
    job.length = 0.0
    for _, l in ipairs(job.lines) do job.length = job.length + l.len end
    job.total = #job.lines * 2
    return job
end

local function sideRun(job, line, r)
    local s = 0.0
    while s < line.len do
        local entry     = job.pool[pick(r, #job.pool)]
        local k         = (job.opts.sides == "all") and (pick(r, 4) - 1) or 0
        local lot, span = lotAt(job, line, s, entry, k)
        if lot then
            lot.name, lot.t = entry.name, entry.t
            job.out[#job.out + 1] = lot
            remember(job, lot.polys)
            s = s + span + job.opts.gapMin + (job.opts.gapMax - job.opts.gapMin) * r()
        elseif not span or s + span > line.len then
            return
        else
            s = s + stepOn
        end
    end
end

local function stepJob(job, budget)
    if #job.pool == 0 then return true end
    local t0 = os.clock()
    while job.k < job.total do
        local n     = job.k + 1
        local line  = job.lines[math.floor((n - 1) / 2) + 1]
        local right = (n % 2) == 1
        sideRun(job, right and line or reversed(line), rng(job.seed * 7919 + n * 104729))
        job.k = n
        if budget and os.clock() - t0 > budget then return job.k >= job.total end
    end
    return true
end

-- =============================================================================
-- SNAP
-- =============================================================================

local function snapAt(lines, p, entry, k, setback)
    local best, bestD = nil, snapReach
    for _, line in ipairs(lines) do
        for i = 2, #line.pts do
            local a, b = line.pts[i - 1], line.pts[i]
            local sg   = {ax = a[1], ay = a[2], bx = b[1], by = b[2]}
            local d    = segDist(p.x, p.y, sg)
            if d < bestD then best, bestD = {line = line, i = i}, d end
        end
    end
    if not best then return nil end
    local line   = best.line
    local a, b   = line.pts[best.i - 1], line.pts[best.i]
    local tx, ty = b[1] - a[1], b[2] - a[2]
    local l      = math.max(1e-9, math.sqrt(tx * tx + ty * ty))
    tx, ty       = tx / l, ty / l
    local u      = math.max(0.0, math.min(l, (p.x - a[1]) * tx + (p.y - a[2]) * ty))
    local s      = line.cum[best.i - 1] + u
    if (p.x - a[1] - tx * u) * ty - (p.y - a[2] - ty * u) * tx < 0 then
        line, s = reversed(line), line.len - s
    end
    local span = spanAt(line, math.max(0.0, s - 0.5), entry.shape, k)
    local s0   = math.max(0.0, math.min(line.len - span, s - span / 2.0))
    if span >= line.len then s0, span = 0.0, line.len end
    local f   = frameOn(line, s0, span, entry.shape, k)
    local lot = placeOn(f, entry, setback, 0.0)
    lot.z     = a[3] + (b[3] - a[3]) * u / l
    return lot
end

-- =============================================================================
-- BENDING
-- =============================================================================

local function nearestRoad(x, y)
    local best, bestD = nil, snapReach
    for _, nm in ipairs(scenetree.findClassObjects("DecalRoad") or {}) do
        local obj = scenetree.findObject(nm)
        if obj and C.objField(obj, "material") ~= marker and obj:getNodeCount() >= 2 then
            local lx, ly, hx, hy = math.huge, math.huge, -math.huge, -math.huge
            for i = 0, obj:getNodeCount() - 1 do
                local p        = obj:getNodePosition(i)
                local w        = (obj:getNodeWidth(i) or 0) / 2.0
                lx, ly, hx, hy = math.min(lx, p.x - w), math.min(ly, p.y - w), math.max(hx, p.x + w), math.max(hy, p.y + w)
            end
            if x > lx - bestD and x < hx + bestD and y > ly - bestD and y < hy + bestD then
                local line = roadOf(obj:getID())
                for i = 2, #(line and line.pts or {}) do
                    local a, b = line.pts[i - 1], line.pts[i]
                    local d    = segDist(x, y, {ax = a[1], ay = a[2], bx = b[1], by = b[2]})
                    if d < bestD then best, bestD = {line = line, i = i}, d end
                end
            end
        end
    end
    if not best then return nil end
    local line   = best.line
    local a, b   = line.pts[best.i - 1], line.pts[best.i]
    local tx, ty = b[1] - a[1], b[2] - a[2]
    local l      = math.max(1e-9, math.sqrt(tx * tx + ty * ty))
    local u      = math.max(0.0, math.min(l, ((x - a[1]) * tx + (y - a[2]) * ty) / l))
    local s      = line.cum[best.i - 1] + u
    if ((x - a[1]) * ty - (y - a[2]) * tx) < 0 then line, s = reversed(line), line.len - s end
    return line, s
end

local function along(line, s)
    local c      = math.max(0.0, math.min(line.len, s))
    local px, py = pointAt(line, c)
    local nx, ny = normalAt(line, math.max(0.5, math.min(line.len - 0.5, c)))
    local over   = s - c
    return px - ny * over, py + nx * over, nx, ny
end

local function bent(id)
    for _, fid in ipairs(B.group(id)) do
        local d = B.dataOf(fid)
        if d and d.straight then return true end
    end
    return false
end

local function bendBuilding(id)
    if bent(id) then return true end
    local floors, cx, cy, n = {}, 0.0, 0.0, 0
    for _, fid in ipairs(B.group(id)) do
        local raw = B.rawNodes(fid)
        floors[#floors + 1] = {id = fid, raw = raw}
        for _, q in ipairs(raw) do cx, cy, n = cx + q[1], cy + q[2], n + 1 end
    end
    if n == 0 then return nil, "no building" end
    cx, cy        = cx / n, cy / n
    local line, s = nearestRoad(cx, cy)
    if not line then return nil, "no road near this building" end
    local qx, qy        = pointAt(line, s)
    local nx, ny        = normalAt(line, s)
    local tx, ty        = -ny, nx
    local aLo, aHi, far = math.huge, -math.huge, 0.0
    for _, f in ipairs(floors) do
        for _, q in ipairs(f.raw) do
            local a, d = (q[1] - qx) * tx + (q[2] - qy) * ty, (q[1] - qx) * nx + (q[2] - qy) * ny
            aLo, aHi   = math.min(aLo, a), math.max(aHi, a)
            far        = math.max(far, d + q[4] / 2.0)
        end
    end
    local r, cross = radius(line, s + aLo, s + aHi)
    if cross < 0 and r < foldRatio * far then return nil, "the road bends too tightly for this building" end
    local changes = {}
    for _, f in ipairs(floors) do
        local raw    = f.raw
        local ax, ay = raw[#raw][1] - raw[1][1], raw[#raw][2] - raw[1][2]
        local l      = math.sqrt(ax * ax + ay * ay)
        local list   = (l > 1e-9 and math.abs((ax * tx + ay * ty) / l) > parallel) and resample(raw) or raw
        local out    = {}
        for _, q in ipairs(list) do
            local a, d           = (q[1] - qx) * tx + (q[2] - qy) * ty, (q[1] - qx) * nx + (q[2] - qy) * ny
            local px, py, mx, my = along(line, s + a)
            out[#out + 1] = {px + mx * d, py + my * d, q[3], q[4], q[5], q[6], q[7], q[8]}
        end
        local data    = B.dataOf(f.id) or B.newData(nil)
        local was     = B.encode(data)
        data.straight = raw
        changes[#changes + 1] = {id = f.id, old = raw, new = out, oldData = was, newData = B.encode(data)}
    end
    B.reshape(changes, "MageBend")
    return true
end

local function straighten(id)
    local changes = {}
    for _, fid in ipairs(B.group(id)) do
        local data = B.dataOf(fid)
        if data and data.straight then
            local was, back = B.encode(data), data.straight
            data.straight   = nil
            changes[#changes + 1] = {id = fid, old = B.rawNodes(fid), new = back, oldData = was, newData = B.encode(data)}
        end
    end
    B.reshape(changes, "MageStraighten")
    return #changes > 0
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.defaults   = defaults
M.rng        = rng
M.shapeOf    = shapeOf
M.outline    = outline
M.facing     = facing
M.extents    = extents
M.roadOf     = roadOf
M.drivable   = drivable
M.obstacles  = obstacles
M.groundAt   = groundAt
M.standOn    = standOn
M.newJob     = newJob
M.stepJob    = stepJob
M.snapAt     = snapAt
M.overlap    = overlap
M.bent       = bent
M.bend       = bendBuilding
M.straighten = straighten

return M
