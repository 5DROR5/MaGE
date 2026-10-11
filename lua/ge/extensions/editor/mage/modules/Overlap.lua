-- =============================================================================
-- MaGE - MeshRoad overlap
-- Version: 1.0.0
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local G  = require("editor/mage/core/Geometry")
local mr = G.mr

-- =============================================================================
-- CONFIG
-- =============================================================================

local config = {
    edgeTol      = 0.005,
    heightTol    = 0.05,
    undersideTol = 0.5,
    margin       = 2.0,
    gridSize     = 8.0,
    flatNormal   = 0.7,
    minArea      = 1e-10,
}

-- =============================================================================
-- WINNER
-- =============================================================================

local tagKeys = {"curb", "walk", "wall", "roll", "bottom", "ends"}

local function tagCount(road)
    local n = 0
    for _, k in ipairs(tagKeys) do
        if road[k] ~= nil then n = n + 1 end
    end
    if road.profile ~= nil and road.profile ~= "walk" then n = n + 1 end
    for _, f in ipairs(G.features) do
        if road[f.key] ~= nil then n = n + 1 end
    end
    return n
end

local function wins(a, b)
    local pa, pb = a.priority or -1.0, b.priority or -1.0
    if math.abs(pa - pb) > 1e-9 then return pa > pb end
    local ta, tb = tagCount(a), tagCount(b)
    if ta ~= tb then return ta > tb end
    local na, nb = tostring(a.name or ""), tostring(b.name or "")
    if na ~= nb then return na < nb end
    return tostring(a.persistentId or a.id) < tostring(b.persistentId or b.id)
end

-- =============================================================================
-- PLAN
-- =============================================================================

local function coarseBox(road)
    local pts = road.points
    if not pts or #pts == 0 then return nil end
    local w, d = 0.0, 0.0
    for i = 1, #pts do
        w = math.max(w, road.widths and road.widths[i] or 0.0)
        d = math.max(d, road.depths and road.depths[i] or 0.0)
    end
    local b = {lx = math.huge, ly = math.huge, lz = math.huge, hx = -math.huge, hy = -math.huge, hz = -math.huge}
    for _, p in ipairs(pts) do
        b.lx, b.ly, b.lz = math.min(b.lx, p.x), math.min(b.ly, p.y), math.min(b.lz, p.z)
        b.hx, b.hy, b.hz = math.max(b.hx, p.x), math.max(b.hy, p.y), math.max(b.hz, p.z)
    end
    local m                = w / 2.0 + config.margin
    b.lx, b.ly, b.hx, b.hy = b.lx - m, b.ly - m, b.hx + m, b.hy + m
    b.lz, b.hz             = b.lz - d - config.margin, b.hz + config.margin
    return b
end

local function boxesTouch(a, b)
    return a.lx <= b.hx and b.lx <= a.hx and a.ly <= b.hy and b.ly <= a.hy and a.lz <= b.hz and b.lz <= a.hz
end

local function roadKey(r)
    return tostring(r.name or "") .. "|" .. tostring(r.persistentId or r.id)
end

local function plan(roads)
    local list = {}
    for _, r in ipairs(roads or {}) do
        if r.source == "meshroad" and not r.isIsland then
            local b = coarseBox(r)
            if b then list[#list + 1] = {road = r, box = b} end
        end
    end
    local nb = {}
    for i = 1, #list do
        for j = i + 1, #list do
            if boxesTouch(list[i].box, list[j].box) then
                local a, b = list[i].road, list[j].road
                nb[a]      = nb[a] or {}
                nb[b]      = nb[b] or {}
                nb[a][#nb[a] + 1] = b
                nb[b][#nb[b] + 1] = a
            end
        end
    end
    for _, l in pairs(nb) do
        table.sort(l, function(x, y) return roadKey(x) < roadKey(y) end)
    end
    return {neighbors = nb}
end

-- =============================================================================
-- SOLID
-- =============================================================================

local function prism(p, flags, b)
    local area = (p[2].x - p[1].x) * (p[3].y - p[1].y) - (p[3].x - p[1].x) * (p[2].y - p[1].y)
    if math.abs(area) < 1e-8 then return nil end
    if area < 0 then
        p     = {p[1], p[3], p[2]}
        b     = {b[1], b[3], b[2]}
        flags = {flags[3], flags[2], flags[1]}
    end
    local e = {}
    for k = 1, 3 do
        local a, b   = p[k], p[k % 3 + 1]
        local dx, dy = b.x - a.x, b.y - a.y
        local l      = math.sqrt(dx * dx + dy * dy)
        if l < 1e-9 then return nil end
        e[k] = {x = a.x, y = a.y, dx = dx / l, dy = dy / l, len = l, outer = flags[k] == true, station = flags[k] == "station"}
    end
    local box = {lx = math.huge, ly = math.huge, hx = -math.huge, hy = -math.huge}
    for _, q in ipairs(p) do
        box.lx, box.ly = math.min(box.lx, q.x), math.min(box.ly, q.y)
        box.hx, box.hy = math.max(box.hx, q.x), math.max(box.hy, q.y)
    end
    return {p = p, b = b, e = e, box = box}
end

local function planeZ(q, x, y)
    local a, b, c    = q[1], q[2], q[3]
    local ux, uy, uz = b.x - a.x, b.y - a.y, b.z - a.z
    local vx, vy, vz = c.x - a.x, c.y - a.y, c.z - a.z
    local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    if math.abs(nz) < 1e-12 then return (a.z + b.z + c.z) / 3.0 end
    return a.z - (nx * (x - a.x) + ny * (y - a.y)) / nz
end

local function heightsAt(pr, x, y)
    return planeZ(pr.p, x, y), planeZ(pr.b, x, y)
end

local function gridKeys(box, fn)
    local g = config.gridSize
    for ix = math.floor(box.lx / g), math.floor(box.hx / g) do
        for iy = math.floor(box.ly / g), math.floor(box.hy / g) do fn(ix .. ":" .. iy) end
    end
end

local function surfaceOf(meshes)
    local tris, grid = {}, {}
    for _, sm in ipairs(meshes or {}) do
        local verts, faces, normals = sm.verts, sm.faces, sm.normals or {}
        if verts and faces then
            for k = 1, #faces - 2, 3 do
                local a      = verts[faces[k].v + 1]
                local b      = verts[faces[k + 1].v + 1]
                local c      = verts[faces[k + 2].v + 1]
                local nz, nl = 0.0, 0.0
                for j = 0, 2 do
                    local n = faces[k + j].n and normals[faces[k + j].n + 1]
                    if n then
                        nz = nz + n.z
                        nl = nl + math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
                    end
                end
                if a and b and c then
                    local d = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
                    if math.abs(d) > 1e-9 then
                        local t = {a = a, b = b, c = c, d = d, down = nz < -1e-6,
                                   flat = nl > 1e-9 and math.abs(nz / nl) >= config.flatNormal, box = {
                            lx = math.min(a.x, b.x, c.x), ly = math.min(a.y, b.y, c.y),
                            hx = math.max(a.x, b.x, c.x), hy = math.max(a.y, b.y, c.y)}}
                        tris[#tris + 1] = t
                        local idx = #tris
                        gridKeys(t.box, function(key)
                            grid[key] = grid[key] or {}
                            grid[key][#grid[key] + 1] = idx
                        end)
                    end
                end
            end
        end
    end
    if #tris == 0 then return nil end
    return {tris = tris, grid = grid}
end

local function column(surf, x, y, fn)
    local g    = config.gridSize
    local list = surf.grid[math.floor(x / g) .. ":" .. math.floor(y / g)]
    if not list then return end
    local eps = 1e-6
    for _, idx in ipairs(list) do
        local t  = surf.tris[idx]
        local bx = t.box
        if x >= bx.lx - config.edgeTol and x <= bx.hx + config.edgeTol and y >= bx.ly - config.edgeTol and y <= bx.hy + config.edgeTol then
            local a, b, c = t.a, t.b, t.c
            local wa      = ((b.y - c.y) * (x - c.x) + (c.x - b.x) * (y - c.y)) / t.d
            local wb      = ((c.y - a.y) * (x - c.x) + (a.x - c.x) * (y - c.y)) / t.d
            local wc      = 1.0 - wa - wb
            if wa >= -eps and wb >= -eps and wc >= -eps then fn(t, wa * a.z + wb * b.z + wc * c.z) end
        end
    end
end

local function undersideAt(surf, x, y, near)
    local lo = math.huge
    column(surf, x, y, function(t, z)
        if t.down and (lo == math.huge or math.abs(z - near) < math.abs(lo - near)) then lo = z end
    end)
    return lo < math.huge and lo or nil
end

local function columnStats(surf, x, y, z, facing)
    x, y                    = x + 1.3e-4, y + 0.7e-4
    local above, below, gap = 0, 0, math.huge
    column(surf, x, y, function(t, fz)
        if fz > z then above = above + 1 else below = below + 1 end
        if facing == nil or (t.flat and t.down == facing) then gap = math.min(gap, math.abs(fz - z)) end
    end)
    return above, below, gap
end

local function solidOf(build, meshes)
    local st = build and build.stations
    if not st or #st < 2 then return nil end
    local n    = #st
    local nc   = #st[1].top
    local cols = {}
    for i, s in ipairs(st) do
        if #s.top ~= nc then return nil end
        local d = s.down or {x = 0, y = 0, z = -1}
        local c = {}
        for k = 1, nc do
            local t    = s.top[k]
            local drop = (s.cols and s.cols[k] and s.cols[k].drop) or 0.0
            local b    = s.bot and s.bot[k]
            if not b then
                local h = (s.height or 0.0) - drop
                b       = {x = t.x + d.x * h, y = t.y + d.y * h, z = t.z + d.z * h}
            end
            c[k] = {t = {x = t.x, y = t.y, z = t.z - d.z * math.max(drop, 0.0)}, b = {x = b.x, y = b.y, z = b.z}}
        end
        cols[i] = c
    end
    local prisms = {}
    local last   = build.closed and n or (n - 1)
    for i = 1, last do
        local j        = (i % n) + 1
        local A, B     = cols[i], cols[j]
        local startOut = (i == 1) and not build.closed
        local endOut   = (j == n) and not build.closed
        for k = 1, nc - 1 do
            local lOut, rOut = (k == 1), (k + 1 == nc)
            local t1         = prism({A[k].t, B[k].t, B[k + 1].t}, {lOut, endOut or "station", false}, {A[k].b, B[k].b, B[k + 1].b})
            local t2         = prism({A[k].t, B[k + 1].t, A[k + 1].t}, {false, rOut, startOut or "station"}, {A[k].b, B[k + 1].b, A[k + 1].b})
            if t1 then prisms[#prisms + 1] = t1 end
            if t2 then prisms[#prisms + 1] = t2 end
        end
    end
    local grid = {}
    for idx, pr in ipairs(prisms) do
        gridKeys(pr.box, function(k)
            grid[k] = grid[k] or {}
            grid[k][#grid[k] + 1] = idx
        end)
    end
    return {prisms = prisms, grid = grid, surface = surfaceOf(meshes)}
end

-- =============================================================================
-- CLIP
-- =============================================================================

local function lerpV(a, b, t)
    return {
        x  = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t,
        nx = a.nx + (b.nx - a.nx) * t, ny = a.ny + (b.ny - a.ny) * t, nz = a.nz + (b.nz - a.nz) * t,
        u  = a.u + (b.u - a.u) * t, v = a.v + (b.v - a.v) * t,
    }
end

local function split(poly, e, t)
    local inside, outside = {}, {}
    local n               = #poly
    local function d(p) return e.dx * (p.y - e.y) - e.dy * (p.x - e.x) - t end
    for k = 1, n do
        local a, b   = poly[k], poly[k % n + 1]
        local da, db = d(a), d(b)
        if da >= 0 then inside[#inside + 1] = a else outside[#outside + 1] = a end
        if (da >= 0) ~= (db >= 0) then
            local c = lerpV(a, b, da / (da - db))
            inside[#inside + 1]   = c
            outside[#outside + 1] = c
        end
    end
    return (#inside >= 3) and inside or nil, (#outside >= 3) and outside or nil
end

local function splitBy(poly, d)
    local above, below = {}, {}
    local n            = #poly
    for k = 1, n do
        local a, b   = poly[k], poly[k % n + 1]
        local da, db = d(a), d(b)
        if da >= 0 then above[#above + 1] = a end
        if da <= 0 then below[#below + 1] = a end
        if (da > 0 and db < 0) or (da < 0 and db > 0) then
            local q = lerpV(a, b, da / (da - db))
            above[#above + 1] = q
            below[#below + 1] = q
        end
    end
    if #above < 3 or #below < 3 then return nil end
    return above, below
end

local function polyBox(poly)
    local b = {lx = math.huge, ly = math.huge, hx = -math.huge, hy = -math.huge}
    for _, p in ipairs(poly) do
        b.lx, b.ly = math.min(b.lx, p.x), math.min(b.ly, p.y)
        b.hx, b.hy = math.max(b.hx, p.x), math.max(b.hy, p.y)
    end
    return b
end

local function boxHit(a, b, pad)
    return a.lx <= b.hx + pad and b.lx <= a.hx + pad and a.ly <= b.hy + pad and b.ly <= a.hy + pad
end

local function candidates(solid, box)
    local seen, cand = {}, {}
    gridKeys({lx = box.lx - config.edgeTol, ly = box.ly - config.edgeTol,
              hx = box.hx + config.edgeTol, hy = box.hy + config.edgeTol}, function(k)
        for _, idx in ipairs(solid.grid[k] or {}) do
            if not seen[idx] then
                seen[idx]       = true
                cand[#cand + 1] = idx
            end
        end
    end)
    table.sort(cand)
    return cand
end

local function containing(solid, cand, x, y, winner)
    local tOuter = winner and config.edgeTol or -config.edgeTol
    for _, idx in ipairs(cand) do
        local pr = solid.prisms[idx]
        local ok = true
        for _, e in ipairs(pr.e) do
            local t = e.outer and tOuter or -config.edgeTol
            if e.dx * (y - e.y) - e.dy * (x - e.x) < t then
                ok = false
                break
            end
        end
        if ok then return pr end
    end
    return nil
end

local function rangeAt(solid, cand, pc, x, y)
    local pr       = containing(solid, cand, x, y, false) or pc
    local top, bot = heightsAt(pr, x, y)
    if solid.surface then
        local cb = undersideAt(solid.surface, x, y, bot)
        if cb and math.abs(cb - bot) < config.undersideTol then bot = cb end
    end
    return top, bot
end

local function faceNormal(t)
    local ux, uy, uz = t[2].x - t[1].x, t[2].y - t[1].y, t[2].z - t[1].z
    local vx, vy, vz = t[3].x - t[1].x, t[3].y - t[1].y, t[3].z - t[1].z
    local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    local l          = math.sqrt(nx * nx + ny * ny + nz * nz)
    if l < 1e-12 then return nil end
    return nx / l, ny / l, nz / l
end

local function polyNormal(poly)
    local nx, ny, nz = 0.0, 0.0, 0.0
    local n          = #poly
    for k = 1, n do
        local a, b = poly[k], poly[k % n + 1]
        nx         = nx + (a.y - b.y) * (a.z + b.z)
        ny         = ny + (a.z - b.z) * (a.x + b.x)
        nz         = nz + (a.x - b.x) * (a.y + b.y)
    end
    local l = math.sqrt(nx * nx + ny * ny + nz * nz)
    if l < 1e-12 then return nil end
    return nx / l, ny / l, nz / l
end

local function onOuterEdge(solid, cand, x, y)
    for _, idx in ipairs(cand) do
        for _, e in ipairs(solid.prisms[idx].e) do
            if e.outer then
                local t = (x - e.x) * e.dx + (y - e.y) * e.dy
                local d = e.dx * (y - e.y) - e.dy * (x - e.x)
                if t >= -config.edgeTol and t <= e.len + config.edgeTol and math.abs(d) <= 2 * config.edgeTol then return true end
            end
        end
    end
    return false
end

local function removable(solid, cand, poly, winner, flat)
    local cx, cy, cz = 0.0, 0.0, 0.0
    for _, p in ipairs(poly) do cx, cy, cz = cx + p.x, cy + p.y, cz + p.z end
    cx, cy, cz = cx / #poly, cy / #poly, cz / #poly
    local pc   = containing(solid, cand, cx, cy, winner)
    if not pc then return false end
    for _, p in ipairs(poly) do
        local top, bot = rangeAt(solid, cand, pc, p.x, p.y)
        if p.z > top + config.heightTol or p.z < bot - config.heightTol then return false, true end
    end
    if not solid.surface then
        if not winner then return true end
        local top, bot = rangeAt(solid, cand, pc, cx, cy)
        return cz <= top - config.heightTol and cz >= bot + config.heightTol
    end
    local above, below, gap = columnStats(solid.surface, cx, cy, cz)
    local enclosed          = (above % 2 == 1) and (below % 2 == 1)
    if flat then
        local _, _, nz = polyNormal(poly)
        local down     = nz ~= nil and nz > 0
        local _, _, g  = columnStats(solid.surface, cx, cy, cz, down)
        if g <= config.heightTol then
            if winner then return false end
            for _, p in ipairs(poly) do
                local x, y, z  = p.x + (cx - p.x) * 0.05, p.y + (cy - p.y) * 0.05, p.z + (cz - p.z) * 0.05
                local _, _, gc = columnStats(solid.surface, x, y, z, down)
                if gc > config.heightTol then return false end
            end
            return true
        end
    end
    if gap <= config.heightTol then return false end
    if not flat and not winner and onOuterEdge(solid, cand, cx, cy) then return true end
    if not enclosed then return false end
    for _, p in ipairs(poly) do
        local x, y, z = p.x + (cx - p.x) * 0.02, p.y + (cy - p.y) * 0.02, p.z + (cz - p.z) * 0.02
        local a, b    = columnStats(solid.surface, x, y, z)
        if a % 2 ~= 1 or b % 2 ~= 1 then return false end
    end
    return true
end



local function onBoundary(solid, cand, piece, flat)
    local cx, cy, cz = 0.0, 0.0, 0.0
    for _, p in ipairs(piece) do cx, cy, cz = cx + p.x, cy + p.y, cz + p.z end
    cx, cy, cz = cx / #piece, cy / #piece, cz / #piece
    local pc   = containing(solid, cand, cx, cy, false)
    if not pc then return false end
    if flat then
        if not solid.surface then
            local top, bot = rangeAt(solid, cand, pc, cx, cy)
            return math.abs(cz - top) <= config.heightTol or math.abs(cz - bot) <= config.heightTol
        end
        local _, _, nz = polyNormal(piece)
        local _, _, g  = columnStats(solid.surface, cx, cy, cz, nz ~= nil and nz > 0)
        return g <= config.heightTol
    end
    for _, idx in ipairs(cand) do
        for _, e in ipairs(solid.prisms[idx].e) do
            if e.outer then
                local t = (cx - e.x) * e.dx + (cy - e.y) * e.dy
                local d = e.dx * (cy - e.y) - e.dy * (cx - e.x)
                if t >= -config.edgeTol and t <= e.len + config.edgeTol and math.abs(d) <= 2 * config.edgeTol then return true end
            end
        end
    end
    return false
end

local function heightCuts(solid, cand, piece)
    local cx, cy = 0.0, 0.0
    for _, p in ipairs(piece) do cx, cy = cx + p.x, cy + p.y end
    local pr = containing(solid, cand, cx / #piece, cy / #piece, false)
    if not pr then return {piece} end
    local parts = {piece}
    for _, q in ipairs({pr.p, pr.b}) do
        local function d(p) return p.z - planeZ(q, p.x, p.y) end
        local nextParts = {}
        for _, part in ipairs(parts) do
            local lo, hi = math.huge, -math.huge
            for _, p in ipairs(part) do
                local v = d(p)
                lo, hi  = math.min(lo, v), math.max(hi, v)
            end
            local above, below
            if lo < -config.heightTol and hi > config.heightTol then above, below = splitBy(part, d) end
            if above then
                nextParts[#nextParts + 1] = above
                nextParts[#nextParts + 1] = below
            else
                nextParts[#nextParts + 1] = part
            end
        end
        parts = nextParts
    end
    return parts
end

local function crosses(poly, e)
    local tmin, tmax = math.huge, -math.huge
    local n          = #poly
    for k = 1, n do
        local a, b = poly[k], poly[k % n + 1]
        local da   = e.dx * (a.y - e.y) - e.dy * (a.x - e.x)
        local db   = e.dx * (b.y - e.y) - e.dy * (b.x - e.x)
        if (da > 1e-9 and db < -1e-9) or (da < -1e-9 and db > 1e-9) then
            local f    = da / (da - db)
            local px   = a.x + (b.x - a.x) * f
            local py   = a.y + (b.y - a.y) * f
            local t    = (px - e.x) * e.dx + (py - e.y) * e.dy
            tmin, tmax = math.min(tmin, t), math.max(tmax, t)
        end
    end
    if tmin > tmax then return false end
    return tmax >= -config.edgeTol and tmin <= e.len + config.edgeTol
end

local function clipTriangle(tri, solid, winner)
    local a, b, c    = tri[1], tri[2], tri[3]
    local ux, uy, uz = b.x - a.x, b.y - a.y, b.z - a.z
    local vx, vy, vz = c.x - a.x, c.y - a.y, c.z - a.z
    local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    local nl         = math.sqrt(nx * nx + ny * ny + nz * nz)
    local flat       = nl > 1e-12 and math.abs(nz / nl) >= config.flatNormal
    local box        = polyBox(tri)
    local cand       = candidates(solid, box)
    if #cand == 0 then return nil end
    local lines = {}
    for _, idx in ipairs(cand) do
        local pr = solid.prisms[idx]
        if boxHit(box, pr.box, config.edgeTol) then
            for _, e in ipairs(pr.e) do
                if e.outer and crosses(tri, e) then lines[#lines + 1] = e end
            end
        end
    end
    local pieces = {tri}
    for _, e in ipairs(lines) do
        local nextPieces = {}
        for _, piece in ipairs(pieces) do
            local i, o = split(piece, e, 0.0)
            if i and o then
                nextPieces[#nextPieces + 1] = i
                nextPieces[#nextPieces + 1] = o
            else
                nextPieces[#nextPieces + 1] = piece
            end
        end
        pieces = nextPieces
    end
    local kept, removed, flicker = {}, false, false
    for _, piece in ipairs(pieces) do
        local ok, height = removable(solid, cand, piece, winner, flat)
        if ok then
            removed = true
            flicker = flicker or onBoundary(solid, cand, piece, flat)
        elseif height and not flat then
            local rest, any = {}, false
            for _, q in ipairs(heightCuts(solid, cand, piece)) do
                if removable(solid, cand, q, winner, flat) then
                    any     = true
                    flicker = flicker or onBoundary(solid, cand, q, flat)
                else
                    rest[#rest + 1] = q
                end
            end
            if any then
                removed = true
                for _, q in ipairs(rest) do kept[#kept + 1] = q end
            else
                kept[#kept + 1] = piece
            end
        elseif height and flat then
            local parts = {piece}
            local pbox  = polyBox(piece)
            for _, idx in ipairs(cand) do
                local pr = solid.prisms[idx]
                if boxHit(pbox, pr.box, config.edgeTol) then
                    for _, e in ipairs(pr.e) do
                        if e.station and crosses(piece, e) then
                            local nextParts = {}
                            for _, q in ipairs(parts) do
                                local i, o = split(q, e, 0.0)
                                if i and o then
                                    nextParts[#nextParts + 1] = i
                                    nextParts[#nextParts + 1] = o
                                else
                                    nextParts[#nextParts + 1] = q
                                end
                            end
                            parts = nextParts
                        end
                    end
                end
            end
            local rest, any = {}, false
            for _, q in ipairs(parts) do
                if removable(solid, cand, q, winner, flat) then
                    any     = true
                    flicker = flicker or onBoundary(solid, cand, q, flat)
                else
                    rest[#rest + 1] = q
                end
            end
            if any then
                removed = true
                for _, q in ipairs(rest) do kept[#kept + 1] = q end
            else
                kept[#kept + 1] = piece
            end
        else
            kept[#kept + 1] = piece
        end
    end
    if not removed then return nil end
    return kept, flicker
end

local function corner(sm, f)
    local v  = sm.verts[f.v + 1]
    local n  = sm.normals[f.n + 1] or {x = 0, y = 0, z = 1}
    local uv = sm.uvs[f.u + 1] or {u = 0, v = 0}
    return {x = v.x, y = v.y, z = v.z, nx = n.x, ny = n.y, nz = n.z, u = uv.u, v = uv.v}
end

local function emit(out, p)
    local i = #out.verts
    out.verts[i + 1]   = {x = p.x, y = p.y, z = p.z}
    out.normals[i + 1] = {x = p.nx, y = p.ny, z = p.nz}
    out.uvs[i + 1]     = {u = p.u, v = p.v}
    return i
end

local function emitTri(out, a, b, c)
    local ux, uy, uz = b.x - a.x, b.y - a.y, b.z - a.z
    local vx, vy, vz = c.x - a.x, c.y - a.y, c.z - a.z
    local cx, cy, cz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    if cx * cx + cy * cy + cz * cz < config.minArea then return end
    for _, p in ipairs({a, b, c}) do
        local i = emit(out, p)
        out.faces[#out.faces + 1] = {v = i, n = i, u = i}
    end
end

local function same(p, q)
    return math.abs(p.x - q.x) < 1e-6 and math.abs(p.y - q.y) < 1e-6 and math.abs(p.z - q.z) < 1e-6
       and math.abs(p.u - q.u) < 1e-6 and math.abs(p.v - q.v) < 1e-6
       and math.abs(p.nx - q.nx) < 1e-6 and math.abs(p.ny - q.ny) < 1e-6 and math.abs(p.nz - q.nz) < 1e-6
end

local function mergePair(t1, t2)
    local ax, ay, az = faceNormal(t1)
    local bx, by, bz = faceNormal(t2)
    if not ax or not bx or ax * bx + ay * by + az * bz < 0.9999 then return nil end
    for k = 1, 3 do
        local p, q = t1[k], t1[k % 3 + 1]
        for j = 1, 3 do
            if same(t2[j], q) and same(t2[j % 3 + 1], p) then
                local d    = t2[(j + 1) % 3 + 1]
                local poly = {}
                for m = 1, 3 do
                    poly[#poly + 1] = t1[m]
                    if m == k then poly[#poly + 1] = d end
                end
                for m = 1, 4 do
                    local o, n2, n3  = poly[m], poly[m % 4 + 1], poly[(m + 1) % 4 + 1]
                    local ux, uy, uz = n2.x - o.x, n2.y - o.y, n2.z - o.z
                    local vx, vy, vz = n3.x - n2.x, n3.y - n2.y, n3.z - n2.z
                    local cx, cy, cz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
                    if cx * ax + cy * ay + cz * az <= 1e-12 then return nil end
                end
                return poly
            end
        end
    end
    return nil
end

local function clipSubmesh(sm, solid, winner)
    local f    = sm.faces
    local tris = {}
    for k = 1, #f - 2, 3 do tris[#tris + 1] = {corner(sm, f[k]), corner(sm, f[k + 1]), corner(sm, f[k + 2])} end
    local groups, i = {}, 1
    while i <= #tris do
        local poly = (i < #tris) and mergePair(tris[i], tris[i + 1]) or nil
        if poly then
            groups[#groups + 1] = {tris = {tris[i], tris[i + 1]}, poly = poly}
            i = i + 2
        else
            groups[#groups + 1] = {tris = {tris[i]}, poly = tris[i]}
            i = i + 1
        end
    end
    local changed = false
    for _, g in ipairs(groups) do
        local result, flicker = clipTriangle(g.poly, solid, winner)
        g.result              = result
        if result then
            if not flicker then
                local count, fresh = 0, false
                for _, poly in ipairs(result) do
                    count = count + #poly - 2
                    for _, p in ipairs(poly) do
                        local known = false
                        for _, q in ipairs(g.poly) do
                            if math.abs(p.x - q.x) < 1e-6 and math.abs(p.y - q.y) < 1e-6 and math.abs(p.z - q.z) < 1e-6 then known = true end
                        end
                        if not known then fresh = true end
                    end
                end
                if fresh or count >= #g.tris then g.result = nil end
            end
        end
        if g.result then changed = true end
    end
    if not changed then return sm end
    local out = {verts = {}, faces = {}, normals = {}, uvs = {}, material = sm.material}
    for _, g in ipairs(groups) do
        if g.result then
            for _, poly in ipairs(g.result) do
                for q = 2, #poly - 1 do emitTri(out, poly[1], poly[q], poly[q + 1]) end
            end
        else
            for _, t in ipairs(g.tris) do emitTri(out, t[1], t[2], t[3]) end
        end
    end
    out._nv, out._nn, out._nu = #out.verts, #out.normals, #out.uvs
    return out
end

local function clipMeshes(meshes, solid, winner)
    local out = {}
    for _, sm in ipairs(meshes) do
        local c = sm.module and sm or clipSubmesh(sm, solid, winner)
        if #c.faces > 0 then out[#out + 1] = c end
    end
    return out
end

-- =============================================================================
-- BUILD
-- =============================================================================

local function built(road, buildFn, cache)
    local e = cache[road]
    if e then return e end
    mr.lastBuild      = nil
    local meshes, err = buildFn(road)
    local lb          = mr.lastBuild
    e                 = {meshes = meshes, err = err, solid = (meshes and lb and lb.isMesh) and solidOf(lb, meshes) or nil}
    cache[road]       = e
    return e
end

local function build(road, p, buildFn, cache)
    cache     = cache or {}
    local nbs = p and p.neighbors[road]
    if not nbs or #nbs == 0 then
        local e = cache[road]
        if e then return e.meshes, e.err end
        return buildFn(road)
    end
    local self = built(road, buildFn, cache)
    if not self.meshes then return nil, self.err end
    local meshes = self.meshes
    for _, nb in ipairs(nbs) do
        local other = built(nb, buildFn, cache)
        if other.solid then meshes = clipMeshes(meshes, other.solid, wins(road, nb)) end
    end
    if #meshes == 0 then return nil, self.err end
    return meshes, self.err
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.plan  = plan
M.build = build
M.wins  = wins

return M
