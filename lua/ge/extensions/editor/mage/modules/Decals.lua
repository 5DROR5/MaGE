-- =============================================================================
-- MaGE - decal paths, junctions and traffic islands
-- Version: 1.0.0
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local S         = require("editor/mage/config/Settings")
local smoothing = S.smoothing
local roundEnd  = S.roundEnd
local paths     = S.paths
local decal     = S.decal
local fillet    = S.fillet
local hairpin   = S.hairpin
local island    = S.island

local C     = require("editor/mage/core/Common")
local clamp = C.clamp

local G                = require("editor/mage/core/Geometry")
local curbFaceV        = G.curbFaceV
local curbMaterialName = G.curbMaterialName
local curbTopV         = G.curbTopV
local curbU            = G.curbU
local newSubmesh       = G.newSubmesh
local pushNormal       = G.pushNormal
local pushQuad         = G.pushQuad
local pushTri          = G.pushTri
local pushUV           = G.pushUV
local pushVert         = G.pushVert
local pushWall         = G.pushWall
local smoothPath       = G.smoothPath
local terrainZ         = G.terrainZ
local walkMaterialName = G.walkMaterialName
local mr               = G.mr

-- =============================================================================
-- ISLANDS
-- =============================================================================

local function signedArea2D(pts)
    local sA, n = 0.0, #pts
    for i = 1, n do
        local a, b = pts[i], pts[(i % n) + 1]
        sA         = sA + (a.x * b.y - b.x * a.y)
    end
    return sA / 2.0
end

local function unit2(dx, dy)
    local L = math.sqrt(dx * dx + dy * dy)
    if L <= 1e-9 then return nil end
    return dx / L, dy / L
end

local function offsetPolygonInward(pts, dist)
    local n   = #pts
    local ccw = signedArea2D(pts) > 0
    local out = {}
    for i = 1, n do
        local pPrev    = pts[((i - 2) % n) + 1]
        local p        = pts[i]
        local pNext    = pts[(i % n) + 1]
        local d0x, d0y = unit2(p.x - pPrev.x, p.y - pPrev.y)
        local d1x, d1y = unit2(pNext.x - p.x, pNext.y - p.y)
        if not d0x or not d1x then
            out[i] = vec3(p.x, p.y, p.z)
        else
            local n0x, n0y, n1x, n1y
            if ccw then
                n0x, n0y = -d0y, d0x
                n1x, n1y = -d1y, d1x
            else
                n0x, n0y = d0y, -d0x
                n1x, n1y = d1y, -d1x
            end
            local mx, my = n0x + n1x, n0y + n1y
            local L      = math.sqrt(mx * mx + my * my)
            if L < 1e-9 then
                out[i] = vec3(p.x, p.y, p.z)
            else
                mx, my     = mx / L, my / L
                local cosv = mx * n1x + my * n1y
                local step = dist / math.max(cosv, island.miterMinCos)
                out[i]     = vec3(p.x + mx * step, p.y + my * step, p.z)
            end
        end
    end
    return out
end

local PolyIndex   = {}
PolyIndex.__index = PolyIndex

local function newPolyIndex(poly)
    local self  = setmetatable({}, PolyIndex)
    local n     = #poly
    self.n      = n
    local edges = {}
    for i = 1, n do
        local a, b = poly[i], poly[(i % n) + 1]
        edges[i]   = {a.x, a.y, b.x, b.y}
    end
    self.edges = edges
    if n == 0 then
        self.minx, self.miny, self.cs, self.nx, self.ny = 0, 0, 1, 1, 1
        self.cells, self.rows                           = {{}}, {{}}
        return self
    end

    local minx, maxx = math.huge, -math.huge
    local miny, maxy = math.huge, -math.huge
    for i = 1, n do
        local q = poly[i]
        if q.x < minx then minx = q.x end
        if q.x > maxx then maxx = q.x end
        if q.y < miny then miny = q.y end
        if q.y > maxy then maxy = q.y end
    end
    local w  = math.max(maxx - minx, 1e-9)
    local h  = math.max(maxy - miny, 1e-9)
    local cs = math.sqrt(w * h / math.max(n, 1))
    if not (cs > 1e-12) then cs = math.max(w, h) end
    local nx = math.floor(w / cs) + 1
    local ny = math.floor(h / cs) + 1
    if nx > 512 then nx = 512 end
    if ny > 512 then ny = 512 end
    cs = math.max(w / nx, h / ny, 1e-12)
    nx = math.min(512, math.floor(w / cs) + 1)
    ny = math.min(512, math.floor(h / cs) + 1)

    self.minx, self.miny, self.cs, self.nx, self.ny = minx, miny, cs, nx, ny
    local cells, rows                               = {}, {}
    for i = 1, nx * ny do cells[i] = {} end
    for i = 1, ny do rows[i] = {} end
    local function cl(v, lo, hi)
        if v < lo then return lo elseif v > hi then return hi end
        return v
    end
    for _, e in ipairs(edges) do
        local ax, ay, bx, by = e[1], e[2], e[3], e[4]
        local ix0            = cl(math.floor((math.min(ax, bx) - minx) / cs), 0, nx - 1)
        local ix1            = cl(math.floor((math.max(ax, bx) - minx) / cs), 0, nx - 1)
        local iy0            = cl(math.floor((math.min(ay, by) - miny) / cs), 0, ny - 1)
        local iy1            = cl(math.floor((math.max(ay, by) - miny) / cs), 0, ny - 1)
        for iy = iy0, iy1 do
            table.insert(rows[iy + 1], e)
            local base = iy * nx
            for ix = ix0, ix1 do table.insert(cells[base + ix + 1], e) end
        end
    end
    self.cells, self.rows = cells, rows
    return self
end

function PolyIndex:contains(px, py)
    if self.n == 0 then return false end
    local iy = math.floor((py - self.miny) / self.cs)
    if iy < 0 then iy = 0 elseif iy > self.ny - 1 then iy = self.ny - 1 end
    local inside = false
    for _, e in ipairs(self.rows[iy + 1]) do
        local x1, y1, x2, y2 = e[1], e[2], e[3], e[4]
        if (y1 > py) ~= (y2 > py) then
            if x1 + (py - y1) * (x2 - x1) / (y2 - y1) > px then inside = not inside end
        end
    end
    return inside
end

function PolyIndex:dist(px, py)
    if self.n == 0 then return 1e18 end
    local cs, nx, ny = self.cs, self.nx, self.ny
    local cx         = math.floor((px - self.minx) / cs)
    local cy         = math.floor((py - self.miny) / cs)
    if cx < 0 then cx = 0 elseif cx > nx - 1 then cx = nx - 1 end
    if cy < 0 then cy = 0 elseif cy > ny - 1 then cy = ny - 1 end

    local best = 1e18
    local span = (nx > ny) and nx or ny
    local r    = 0
    while true do
        local block = {}
        if r == 0 then
            block[1] = {cx, cy}
        else
            local x0, x1, y0, y1 = cx - r, cx + r, cy - r, cy + r
            for ix = x0, x1 do
                if ix >= 0 and ix < nx then
                    if y0 >= 0 and y0 < ny then block[#block + 1] = {ix, y0} end
                    if y1 >= 0 and y1 < ny then block[#block + 1] = {ix, y1} end
                end
            end
            for iy = y0 + 1, y1 - 1 do
                if iy >= 0 and iy < ny then
                    if x0 >= 0 and x0 < nx then block[#block + 1] = {x0, iy} end
                    if x1 >= 0 and x1 < nx then block[#block + 1] = {x1, iy} end
                end
            end
        end
        for _, ce in ipairs(block) do
            for _, e in ipairs(self.cells[ce[2] * nx + ce[1] + 1]) do
                local ax, ay, bx, by = e[1], e[2], e[3], e[4]
                local dx, dy         = bx - ax, by - ay
                local l2             = dx * dx + dy * dy
                local d
                if l2 < 1e-15 then
                    d = math.sqrt((px - ax) ^ 2 + (py - ay) ^ 2)
                else
                    local t = ((px - ax) * dx + (py - ay) * dy) / l2
                    if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
                    d = math.sqrt((px - (ax + dx * t)) ^ 2 + (py - (ay + dy * t)) ^ 2)
                end
                if d < best then best = d end
            end
        end
        local loX   = self.minx + (cx - r) * cs
        local hiX   = self.minx + (cx + r + 1) * cs
        local loY   = self.miny + (cy - r) * cs
        local hiY   = self.miny + (cy + r + 1) * cs
        local reach = math.min(px - loX, hiX - px, py - loY, hiY - py)
        if best <= reach then break end
        r = r + 1
        if r > span then break end
    end
    return best
end

local function fitInnerRing(outer, cand, target)
    local n                   = #outer
    local idx                 = newPolyIndex(outer)
    local dirs, lens, samples = {}, {}, {}

    for i = 1, n do
        local p, q   = outer[i], cand[i]
        local vx, vy = q.x - p.x, q.y - p.y
        local L      = math.sqrt(vx * vx + vy * vy)
        if L < 1e-9 then
            dirs[i] = {0.0, 0.0}; lens[i] = 0.0; samples[i] = {}
        else
            local ux, uy   = vx / L, vy / L
            dirs[i]        = {ux, uy}; lens[i] = L
            local probeD   = target / 0.45
            local cfx, cfy = p.x + vx, p.y + vy
            local cpx, cpy = p.x + ux * probeD, p.y + uy * probeD
            if idx:contains(cfx, cfy) and idx:dist(cfx, cfy) >= target * 0.999
                  and idx:contains(cpx, cpy) and idx:dist(cpx, cpy) >= target * 0.999 then
                samples[i] = false
            else
                local row = {}
                for k = 1, 40 do
                    local dAlong   = L * 4.0 * k / 40.0
                    local cxp, cyp = p.x + ux * dAlong, p.y + uy * dAlong
                    if not idx:contains(cxp, cyp) then break end
                    row[#row + 1] = {dAlong, idx:dist(cxp, cyp)}
                end
                samples[i] = row
            end
        end
    end

    local want = {}
    for i = 1, n do
        local row = samples[i]
        if row == false then
            want[i] = target
        else
            local h = 0.0
            for _, e in ipairs(row) do if e[2] > h then h = e[2] end end
            want[i] = (h > 0) and math.min(target, 0.45 * h) or 0.0
        end
    end

    local seg = {}
    for i = 1, n do
        local a, b = outer[i], outer[(i % n) + 1]
        seg[i]     = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
    end
    for _ = 1, 2 do
        for i = 1, n do
            local j = (i % n) + 1
            want[j] = math.min(want[j], want[i] + seg[i])
        end
        for i = n, 1, -1 do
            local j = (i % n) + 1
            want[i] = math.min(want[i], want[j] + seg[i])
        end
    end

    local out, nNarrow = {}, 0
    for i = 1, n do
        local p, w, row = outer[i], want[i], samples[i]
        if row == false and w >= target * 0.999 then
            out[i] = cand[i]
        else
            if row == false then
                row = {}
                for k = 1, 40 do
                    local dAlong = lens[i] * 4.0 * k / 40.0
                    local cxp    = p.x + dirs[i][1] * dAlong
                    local cyp    = p.y + dirs[i][2] * dAlong
                    if not idx:contains(cxp, cyp) then break end
                    row[#row + 1] = {dAlong, idx:dist(cxp, cyp)}
                end
            end
            if #row == 0 or w <= 1e-6 then
                out[i]  = vec3(p.x + dirs[i][1] * 0.01, p.y + dirs[i][2] * 0.01, cand[i].z)
                nNarrow = nNarrow + 1
            else
                if w < target * 0.999 then nNarrow = nNarrow + 1 end
                local lo, hi = 0.0, row[#row][1]
                for _, e in ipairs(row) do
                    if e[2] >= w then hi = e[1] break end
                    lo = e[1]
                end
                for _ = 1, 12 do
                    local mid = (lo + hi) / 2.0
                    local cxp = p.x + dirs[i][1] * mid
                    local cyp = p.y + dirs[i][2] * mid
                    if idx:contains(cxp, cyp) and idx:dist(cxp, cyp) >= w then hi = mid
                    else lo = mid end
                end
                out[i] = vec3(p.x + dirs[i][1] * hi, p.y + dirs[i][2] * hi, cand[i].z)
            end
        end
    end
    return out, nNarrow
end

local function triangulatePolygon(ptsIn)

    local pts = {}
    for i = 1, #ptsIn do
        local q    = ptsIn[i]
        local prev = pts[#pts]
        if not prev or math.sqrt((q.x - prev.x) ^ 2 + (q.y - prev.y) ^ 2) > 1e-6 then
            pts[#pts + 1] = q
        end
    end
    while #pts > 3 do
        local a, b = pts[1], pts[#pts]
        if math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) > 1e-6 then break end
        table.remove(pts)
    end

    local n = #pts
    if n < 3 then return {}, pts end
    local order = {}
    for i = 1, n do order[i] = i end
    if signedArea2D(pts) < 0 then
        local r = {}
        for i = n, 1, -1 do r[#r + 1] = order[i] end
        order = r
    end
    local m = #order

    local prv, nxt, alive = {}, {}, {}
    for i = 1, m do
        prv[i]   = ((i - 2) % m) + 1
        nxt[i]   = (i % m) + 1
        alive[i] = true
    end

    local function ptOf(i) return pts[order[i]] end
    local function area2(a, b, c)
        return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    end
    local function inTri(p, a, b, c)
        return area2(a, b, p) >= -1e-12 and area2(b, c, p) >= -1e-12
                      and area2(c, a, p) >= -1e-12
    end
    local function cost(i)
        local a, b, c = ptOf(prv[i]), ptOf(i), ptOf(nxt[i])
        local function h(u, v) return math.sqrt((u.x - v.x) ^ 2 + (u.y - v.y) ^ 2) end
        return math.max(h(b, a), h(c, b), h(a, c))
    end
    local function isEar(i)
        local a, b, c = ptOf(prv[i]), ptOf(i), ptOf(nxt[i])
        if area2(a, b, c) <= 1e-12 then return false end
        local j = nxt[nxt[i]]
        while j ~= prv[i] do
            if inTri(ptOf(j), a, b, c) then return false end
            j = nxt[j]
        end
        return true
    end

    local tris      = {}
    local remaining = m
    local guard     = 0
    while remaining > 3 and guard < 8 * m + 64 do
        guard              = guard + 1
        local chosen, best = nil, math.huge
        for i = 1, m do
            if alive[i] and isEar(i) then
                local c = cost(i)
                if c < best then best, chosen = c, i end
            end
        end

        if not chosen then
            local bestArea = -math.huge
            for i = 1, m do
                if alive[i] then
                    local a, b, c = ptOf(prv[i]), ptOf(i), ptOf(nxt[i])
                    local ar      = area2(a, b, c)
                    if ar > bestArea then bestArea, chosen = ar, i end
                end
            end
            if not chosen or bestArea <= 0.0 then break end
        end
        local a, b = prv[chosen], nxt[chosen]
        tris[#tris + 1] = {order[a], order[chosen], order[b]}
        alive[chosen] = false
        nxt[a]        = b
        prv[b]        = a
        remaining     = remaining - 1
    end
    if remaining == 3 then
        for k = 1, m do
            if alive[k] then
                tris[#tris + 1] = {order[prv[k]], order[k], order[nxt[k]]}
                break
            end
        end
    end
    return tris, pts
end

local function arcPoints(cx, cy, pFrom, pTo, z, maxTurnDeg, through)
    local a0 = math.atan2(pFrom.y - cy, pFrom.x - cx)
    local a1 = math.atan2(pTo.y - cy, pTo.x - cx)
    local r0 = math.sqrt((pFrom.x - cx) ^ 2 + (pFrom.y - cy) ^ 2)
    local r1 = math.sqrt((pTo.x - cx) ^ 2 + (pTo.y - cy) ^ 2)
    local d
    if through then

        local at    = math.atan2(through.y - cy, through.x - cx)
        local twoPi = 2 * math.pi
        local span  = (a1 - a0) % twoPi
        local rel   = (at - a0) % twoPi
        d           = (rel < span) and span or (span - twoPi)
    else
        d = a1 - a0
        while d > math.pi do d = d - 2 * math.pi end
        while d < -math.pi do d = d + 2 * math.pi end
    end
    local steps = math.max(2, math.ceil(math.abs(math.deg(d)) / math.max(0.5, maxTurnDeg)))
    local pts   = {}
    for k = 1, steps - 1 do
        local f   = k / steps
        local ang = a0 + d * f
        local r   = r0 + (r1 - r0) * f
        pts[#pts + 1] = vec3(cx + math.cos(ang) * r, cy + math.sin(ang) * r, z)
    end
    return pts
end

local function roundPolylineCorners(ring, radius, minTurnDeg)
    local n = #ring
    if n < 3 or radius <= 0 then return ring end
    local ccw = signedArea2D(ring) > 0

    local seg, total = {}, 0.0
    for i = 1, n do
        local a, b = ring[i], ring[(i % n) + 1]
        seg[i]     = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
        total      = total + seg[i]
    end
    if total < 1e-6 then return ring end
    local arcAt = {0.0}
    for i = 2, n do arcAt[i] = arcAt[i - 1] + seg[i - 1] end

    local corners = {}
    for i = 1, n do
        local a        = ring[((i - 2) % n) + 1]
        local p        = ring[i]
        local b        = ring[(i % n) + 1]
        local d0x, d0y = unit2(p.x - a.x, p.y - a.y)
        local d1x, d1y = unit2(b.x - p.x, b.y - p.y)
        if d0x and d1x then
            local crossz   = d0x * d1y - d0y * d1x
            local isConvex = (crossz > 0) == ccw
            if isConvex then
                local cosv = clamp(d0x * d1x + d0y * d1y, -1.0, 1.0)
                local turn = math.deg(math.acos(cosv))
                if turn >= minTurnDeg then
                    corners[#corners + 1] = {i = i, turn = turn}
                end
            end
        end
    end
    if #corners == 0 then return ring end

    local trims = {}
    local nc    = #corners
    for k = 1, nc do
        local i, turn = corners[k].i, corners[k].turn
        local half    = math.rad((180.0 - turn) / 2.0)
        local tlen    = radius / math.max(math.tan(half), 1e-6)
        local prevI   = corners[((k - 2) % nc) + 1].i
        local nextI   = corners[(k % nc) + 1].i
        local gapPrev = (arcAt[i] - arcAt[prevI]) % total
        local gapNext = (arcAt[nextI] - arcAt[i]) % total
        if nc == 1 then gapPrev, gapNext = total, total end
        tlen = math.min(tlen, gapPrev * 0.45, gapNext * 0.45, total * 0.3)
        if tlen > 1e-4 then trims[i] = tlen end
    end
    if next(trims) == nil then return ring end

    local function pointAt(arcS)
        local sv = arcS % total
        for i = 1, n do
            if sv <= arcAt[i] + seg[i] + 1e-12 then
                local f    = (seg[i] > 1e-12) and ((sv - arcAt[i]) / seg[i]) or 0.0
                f          = clamp(f, 0.0, 1.0)
                local a, b = ring[i], ring[(i % n) + 1]
                return vec3(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f,
                            a.z + (b.z - a.z) * f)
            end
        end
        return ring[n]
    end

    local dropped = {}
    for i, tlen in pairs(trims) do
        for j = 1, n do
            local d = (arcAt[j] - arcAt[i] + total / 2.0) % total - total / 2.0
            if math.abs(d) <= tlen + 1e-9 then dropped[j] = true end
        end
    end

    local out = {}
    for i = 1, n do
        local tlen = trims[i]
        if tlen then
            local p        = ring[i]
            local sPt      = pointAt(arcAt[i] - tlen)
            local ePt      = pointAt(arcAt[i] + tlen)
            local d0x, d0y = unit2(p.x - sPt.x, p.y - sPt.y)
            local d1x, d1y = unit2(ePt.x - p.x, ePt.y - p.y)
            if not d0x or not d1x then
                out[#out + 1] = p
            else
                local cosv   = clamp(d0x * d1x + d0y * d1y, -1.0, 1.0)
                local half   = (math.pi - math.acos(cosv)) / 2.0
                local mx, my = d1x - d0x, d1y - d0y
                local L      = math.sqrt(mx * mx + my * my)
                if math.sin(half) < 1e-6 or L < 1e-9 then
                    out[#out + 1] = p
                else
                    local rEff = tlen * math.tan(half)
                    local cx   = p.x + (mx / L) * (rEff / math.sin(half))
                    local cy   = p.y + (my / L) * (rEff / math.sin(half))
                    out[#out + 1] = sPt
                    for _, q in ipairs(arcPoints(cx, cy, sPt, ePt, p.z,
                                                 fillet.maxTurnDeg)) do
                        out[#out + 1] = q
                    end
                    out[#out + 1] = ePt
                end
            end
        elseif not dropped[i] then
            out[#out + 1] = ring[i]
        end
    end

    local clean = {}
    for _, q in ipairs(out) do
        local last = clean[#clean]
        if not last or math.sqrt((q.x - last.x) ^ 2 + (q.y - last.y) ^ 2) >= 1e-4 then
            clean[#clean + 1] = q
        end
    end
    return (#clean >= 4) and clean or ring
end

local function flatDir(v)
    local d = vec3(v.x, v.y, 0.0)
    if d:length() < 1e-9 then return vec3(1.0, 0.0, 0.0) end
    return d:normalized()
end

local function roundReflexCorners(ring, radius, minTurnDeg)
    local n = #ring
    if n < 4 or radius <= 0 then return ring end
    minTurnDeg = minTurnDeg or 45.0
    local ccw  = signedArea2D(ring) > 0
    local out  = {}
    for i = 1, n do
        local a        = ring[((i - 2) % n) + 1]
        local p        = ring[i]
        local b        = ring[(i % n) + 1]
        local d0x, d0y = unit2(p.x - a.x, p.y - a.y)
        local d1x, d1y = unit2(b.x - p.x, b.y - p.y)
        local handled  = false
        if d0x and d1x then
            local crossz = d0x * d1y - d0y * d1x
            if (crossz > 0) ~= ccw then
                local cosv = clamp(d0x * d1x + d0y * d1y, -1.0, 1.0)
                local turn = math.deg(math.acos(cosv))
                if turn >= minTurnDeg then
                    local half = math.rad((180.0 - turn) / 2.0)
                    if math.tan(half) >= 1e-6 then
                        local tlen = radius / math.tan(half)
                        local la   = math.sqrt((p.x - a.x) ^ 2 + (p.y - a.y) ^ 2)
                        local lb   = math.sqrt((b.x - p.x) ^ 2 + (b.y - p.y) ^ 2)
                        tlen       = math.min(tlen, la * 0.45, lb * 0.45)
                        if tlen >= 1e-4 then
                            local mx, my = d0x - d1x, d0y - d1y
                            local L      = math.sqrt(mx * mx + my * my)
                            if L >= 1e-9 then
                                local sp   = vec3(p.x - d0x * tlen, p.y - d0y * tlen, p.z)
                                local ep   = vec3(p.x + d1x * tlen, p.y + d1y * tlen, p.z)
                                local rEff = tlen * math.tan(half)
                                local cx   = p.x + (mx / L) * (rEff / math.sin(half))
                                local cy   = p.y + (my / L) * (rEff / math.sin(half))
                                out[#out + 1] = sp
                                for _, q in ipairs(arcPoints(cx, cy, sp, ep, p.z,
                                                             fillet.maxTurnDeg)) do
                                    out[#out + 1] = q
                                end
                                out[#out + 1] = ep
                                handled = true
                            end
                        end
                    end
                end
            end
        end
        if not handled then out[#out + 1] = p end
    end
    return out
end

local function offsetPolyline(points, widths, side)
    local n   = #points
    local out = {}
    for i = 1, n do
        local tn
        if i == 1 then tn = points[2] - points[1]
        elseif i == n then tn = points[n] - points[n - 1]
        else tn = points[i + 1] - points[i - 1] end
        tn           = flatDir(tn)
        local nx, ny = -tn.y, tn.x
        local p, w   = points[i], widths[i]
        out[i]       = vec3(p.x + nx * side * w / 2.0, p.y + ny * side * w / 2.0, p.z)
    end
    return out
end

local function polylineCross(pa, pb)
    for i = 1, #pa - 1 do
        local a0, a1   = pa[i], pa[i + 1]
        local d1x, d1y = a1.x - a0.x, a1.y - a0.y
        for j = 1, #pb - 1 do
            local b0, b1   = pb[j], pb[j + 1]
            local d2x, d2y = b1.x - b0.x, b1.y - b0.y
            local den      = d1x * d2y - d1y * d2x
            if math.abs(den) >= 1e-12 then
                local dx, dy = b0.x - a0.x, b0.y - a0.y
                local sPar   = (dx * d2y - dy * d2x) / den
                local uPar   = (dx * d1y - dy * d1x) / den
                if sPar >= -1e-9 and sPar <= 1 + 1e-9
                      and uPar >= -1e-9 and uPar <= 1 + 1e-9 then
                    return vec3(a0.x + d1x * sPar, a0.y + d1y * sPar,
                                a0.z + (a1.z - a0.z) * sPar), i, j
                end
            end
        end
    end
    return nil
end

local function hairpinUnionRing(rdI, eI, rdJ, eJ, tip)
    local function ordered(rd, atEnd)
        local p, w = {}, {}
        if atEnd then
            for i = 1, #rd.points do p[i] = rd.points[i]; w[i] = rd.widths[i] end
        else
            for i = #rd.points, 1, -1 do p[#p + 1] = rd.points[i]; w[#w + 1] = rd.widths[i] end
        end
        return p, w
    end

    local pa, wa = ordered(rdI, eI)
    local pb, wb = ordered(rdJ, eJ)
    if #pa < 2 or #pb < 2 then return nil end

    local hwa, hwb = wa[#wa] / 2.0, wb[#wb] / 2.0
    if math.max(hwa, hwb) / math.max(math.min(hwa, hwb), 1e-6)
          > hairpin.unionMaxWidth then
        return nil
    end

    local da     = flatDir(pa[#pa] - pa[#pa - 1])
    local db     = flatDir(pb[#pb] - pb[#pb - 1])
    local crossz = da.x * db.y - da.y * db.x
    if math.abs(crossz) < 1e-6 then return nil end
    local sideAOut = (crossz < 0) and -1 or 1
    local sideBOut = -sideAOut

    local aOut = offsetPolyline(pa, wa, sideAOut)
    local aIn  = offsetPolyline(pa, wa, -sideAOut)
    local bOut = offsetPolyline(pb, wb, sideBOut)
    local bIn  = offsetPolyline(pb, wb, -sideBOut)

    local K, ia, ib = polylineCross(aIn, bIn)
    if not K then return nil end

    local zt     = pa[#pa].z
    local bis    = flatDir(da + db)
    local tipVia = vec3(tip.x + bis.x * hwa, tip.y + bis.y * hwa, zt)

    local function freeCap(pts, ws, pFrom, pTo)
        local d0  = flatDir(pts[2] - pts[1])
        local hw0 = ws[1] / 2.0
        local c   = pts[1]
        local via = vec3(c.x - d0.x * hw0, c.y - d0.y * hw0, c.z)
        return arcPoints(c.x, c.y, pFrom, pTo, pts[1].z, roundEnd.maxTurnDeg, via)
    end

    local ring = {}
    local function push(q) ring[#ring + 1] = q end
    for i = 1, #aOut do push(aOut[i]) end
    for _, q in ipairs(arcPoints(tip.x, tip.y, aOut[#aOut], bOut[#bOut], zt,
                                 roundEnd.maxTurnDeg, tipVia)) do push(q) end
    for i = #bOut, 1, -1 do push(bOut[i]) end
    if not (eJ and rdJ.noCapStart or rdJ.noCapEnd) then
        for _, q in ipairs(freeCap(pb, wb, bOut[1], bIn[1])) do push(q) end
    end
    for i = 1, ib do push(bIn[i]) end
    push(K)
    for i = ia, 1, -1 do push(aIn[i]) end
    if not (eI and rdI.noCapStart or rdI.noCapEnd) then
        for _, q in ipairs(freeCap(pa, wa, aIn[1], aOut[1])) do push(q) end
    end

    local clean = {}
    for _, q in ipairs(ring) do
        local last = clean[#clean]
        if not last or math.sqrt((q.x - last.x) ^ 2 + (q.y - last.y) ^ 2) >= 1e-6 then
            clean[#clean + 1] = q
        end
    end
    while #clean > 3 and math.sqrt((clean[#clean].x - clean[1].x) ^ 2
                                   + (clean[#clean].y - clean[1].y) ^ 2) < 1e-6 do
        table.remove(clean)
    end
    if #clean < 4 or math.abs(signedArea2D(clean)) < island.minArea then return nil end
    return roundReflexCorners(clean, hairpin.notchRadius)
end

local function extractIslands(roads)
    if not island.build then return {}, roads end

    local thin, thick = {}, {}
    for _, rd in ipairs(roads) do
        local maxW = 0.0
        for _, w in ipairs(rd.widths) do if w > maxW then maxW = w end end
        if maxW < island.maxMarkerWidth and #rd.points >= 2 then
            thin[#thin + 1] = rd
        else
            thick[#thick + 1] = rd
        end
    end
    if #thin == 0 then return {}, roads end

    local tol = island.joinTol
    local function endp(rd, last)
        return last and rd.points[#rd.points] or rd.points[1]
    end
    local function near(a, b)
        local dx, dy = a.x - b.x, a.y - b.y
        return math.sqrt(dx * dx + dy * dy) <= tol
    end

    local used               = {}
    local islands, leftovers = {}, {}

    for startI = 1, #thin do
        if not used[startI] then
            used[startI]      = true
            local chain       = {{i = startI, rev = false}}
            local ringStart   = endp(thin[startI], false)
            local cur         = endp(thin[startI], true)
            local closed      = false
            local selfClosing = #thin[startI].points >= 3

            while true do
                if near(cur, ringStart) and (#chain >= 2 or selfClosing) then
                    closed = true
                    break
                end
                local nxtI, nxtRev = nil, false
                for j = 1, #thin do
                    if not used[j] then
                        if near(cur, endp(thin[j], false)) then nxtI, nxtRev = j, false break end
                        if near(cur, endp(thin[j], true)) then nxtI, nxtRev = j, true break end
                    end
                end
                if not nxtI then break end
                used[nxtI] = true
                chain[#chain + 1] = {i = nxtI, rev = nxtRev}
                cur = endp(thin[nxtI], not nxtRev)
            end

            if not closed then
                for _, c in ipairs(chain) do leftovers[#leftovers + 1] = thin[c.i] end
            else
                local pts = {}
                for _, c in ipairs(chain) do
                    local seq = {}
                    local src = thin[c.i].points
                    if c.rev then
                        for k = #src, 1, -1 do seq[#seq + 1] = src[k] end
                    else
                        for k = 1, #src do seq[k] = src[k] end
                    end
                    if island.smoothing and #seq >= 3 then
                        seq = smoothPath(seq, smoothing.segLen)
                    end
                    local from = 1
                    if #pts > 0 and near(seq[1], pts[#pts]) then from = 2 end
                    for k = from, #seq do
                        local p = seq[k]
                        if #pts == 0 or math.sqrt((p.x - pts[#pts].x) ^ 2
                                                  + (p.y - pts[#pts].y) ^ 2) >= 1e-3 then
                            pts[#pts + 1] = p
                        end
                    end
                end
                while #pts > 3 and near(pts[#pts], pts[1]) do table.remove(pts) end

                if island.roundCorners and #pts >= 3 then
                    pts = roundPolylineCorners(pts, island.cornerRadius,
                                               island.cornerMinTurnDeg)
                end

                local area = math.abs(signedArea2D(pts))
                if #pts < 3 or area < island.minArea then
                    for _, c in ipairs(chain) do leftovers[#leftovers + 1] = thin[c.i] end
                else
                    local base   = thin[chain[1].i]
                    local srcIds = {}
                    for _, c in ipairs(chain) do srcIds[#srcIds + 1] = thin[c.i].id end
                    islands[#islands + 1] = {
                        id          = base.id, name = base.name, persistentId = base.persistentId,
                        srcIds      = srcIds,
                        ring        = pts, area = area, parts = #chain,
                        curb        = base.curb, walk = base.walk,
                        profile     = base.profile or "island",
                        overObjects = base.overObjects,
                        isIsland    = true,
                    }
                end
            end
        end
    end

    local rest = {}
    for _, r in ipairs(thick) do rest[#rest + 1] = r end
    for _, r in ipairs(leftovers) do rest[#rest + 1] = r end
    return islands, rest
end

-- =============================================================================
-- JUNCTIONS
-- =============================================================================

local function polylineLength(pts)
    local acc = 0.0
    for i = 2, #pts do acc = acc + (pts[i] - pts[i - 1]):length() end
    return acc
end

local function dirAtEnd(pts, probe)
    local n = #pts
    if n < 2 then return vec3(1.0, 0.0, 0.0) end
    local ref = pts[1]
    local acc = 0.0
    for i = n, 2, -1 do
        acc = acc + (pts[i] - pts[i - 1]):length()
        if acc >= probe then ref = pts[i - 1] break end
    end
    return flatDir(pts[n] - ref)
end

local function trimFromEnd(pts, ws, length)
    if length <= 0.0 then
        local p, w = {}, {}
        for i = 1, #pts do p[i] = pts[i]; w[i] = ws[i] end
        return p, w
    end
    local n          = #pts
    local remain     = length
    local outP, outW = {}, {}
    for i = 1, n do outP[i] = pts[i]; outW[i] = ws[i] end
    while #outP >= 2 do
        local last = #outP
        local seg  = (outP[last] - outP[last - 1]):length()
        if seg <= remain + 1e-12 then
            remain = remain - seg
            table.remove(outP); table.remove(outW)
            if remain <= 1e-12 then break end
        else
            local f    = (seg - remain) / seg
            outP[last] = outP[last - 1] + (outP[last] - outP[last - 1]) * f
            outW[last] = outW[last - 1] + (outW[last] - outW[last - 1]) * f
            break
        end
    end
    return outP, outW
end

local function trimFromStart(pts, ws, length)
    local rp, rw = {}, {}
    for i = #pts, 1, -1 do rp[#rp + 1] = pts[i]; rw[#rw + 1] = ws[i] end
    local tp, tw = trimFromEnd(rp, rw, length)
    local op, ow = {}, {}
    for i = #tp, 1, -1 do op[#op + 1] = tp[i]; ow[#ow + 1] = tw[i] end
    return op, ow
end

local function junctionState(A, wA, B, wB, ta, tb)
    local a2, wa2 = trimFromEnd(A, wA, ta)
    local b2, wb2 = trimFromStart(B, wB, tb)
    if #a2 < 2 or #b2 < 2 then return nil end
    local dA = dirAtEnd(a2, fillet.tangentProbe)
    local rb = {}
    for i = #b2, 1, -1 do rb[#rb + 1] = b2[i] end
    local dB = dirAtEnd(rb, fillet.tangentProbe) * -1.0
    return a2[#a2], dA, wa2[#wa2] / 2.0, b2[1], dB, wb2[1] / 2.0
end

local function cornerTrims(pA, dA, hwA, pB, dB, hwB)
    local cross = dA.x * dB.y - dA.y * dB.x
    if math.abs(cross) < 0.02 then return nil end
    local sign  = (cross > 0.0) and 1.0 or -1.0
    local nA    = vec3(dA.y, -dA.x, 0.0) * sign
    local nB    = vec3(dB.y, -dB.x, 0.0) * sign
    local a0    = pA - nA * hwA
    local b0    = pB - nB * hwB
    local rhs   = b0 - a0
    local sPar  = (rhs.x * dB.y - rhs.y * dB.x) / cross
    local inner = a0 + dA * sPar
    local footA = inner + nA * hwA
    local footB = inner + nB * hwB
    return {trimA = (pA - footA):dot(dA), trimB = (footB - pB):dot(dB),
            inner = inner, nA = nA, nB = nB, sign = sign,
            wA    = hwA * 2.0, wB = hwB * 2.0, zA = pA.z, zB = pB.z}
end

local function hermite(p0, m0, p1, m1, t)
    local t2, t3 = t * t, t * t * t
    return p0 * (2 * t3 - 3 * t2 + 1) + m0 * (t3 - 2 * t2 + t)
                  + p1 * (-2 * t3 + 3 * t2) + m1 * (t3 - t2)
end

local function bridgeSamples(pA, dA, pB, dB, magScale, count)
    count        = count or 96
    local chordV = pB - pA
    local chord  = vec3(chordV.x, chordV.y, 0.0):length()
    if chord < 1e-4 then return nil end
    local theta = math.acos(clamp(dA:dot(dB), -1.0, 1.0))
    local ratio = (theta < 1e-3) and 1.0
                                or (2.0 * math.tan(theta / 4.0) / math.sin(theta / 2.0))
    local mag = chord * ratio * magScale
    if dA:dot(chordV) <= 0.0 or dB:dot(chordV) <= 0.0 then
        mag = math.min(mag, chord * 0.5)
    end
    local p0     = vec3(pA.x, pA.y, 0.0)
    local p1     = vec3(pB.x, pB.y, 0.0)
    local m0, m1 = dA * mag, dB * mag
    local out    = {}
    for i = 0, count do out[i + 1] = hermite(p0, m0, p1, m1, i / count) end
    return out
end

local function outwardNormals(dA, dB)
    local crossZ = dA.x * dB.y - dA.y * dB.x
    if math.abs(crossZ) < 1e-4 then return nil end
    local sign = (crossZ > 0.0) and 1.0 or -1.0
    return vec3(dA.y, -dA.x, 0.0) * sign, vec3(dB.y, -dB.x, 0.0) * sign
end

local function outwardViolation(samples, pA, pB, nA, nB)
    if not nA then return -1.0 end
    local worst = -1e9
    for _, q in ipairs(samples) do
        worst = math.max(worst, (q - pA):dot(nA), (q - pB):dot(nB))
    end
    return worst
end

local function bridgeHalfwidths(samples, pA, dA, hwA, pB, dB, hwB)
    local n       = #samples
    local nA, nB  = outwardNormals(dA, dB)
    local floorHw = math.min(hwA, hwB)
    local tol     = fillet.insideTol
    local out     = {}
    for i = 1, n do
        local u  = (n > 1) and ((i - 1) / (n - 1)) or 0.0
        local hw = hwA + (hwB - hwA) * u
        if nA and fillet.keepInside then
            local j0     = math.max(1, i - 1)
            local j1     = math.min(n, i + 1)
            local d      = flatDir(samples[j1] - samples[j0])
            local sign   = ((dA.x * dB.y - dA.y * dB.x) > 0.0) and 1.0 or -1.0
            local nrm    = vec3(d.y, -d.x, 0.0) * sign
            local limits = {{pA + nA * hwA, nA}, {pB + nB * hwB, nB}}
            for _, lb in ipairs(limits) do
                local proj = nrm:dot(lb[2])
                if proj > 1e-6 then
                    hw = math.min(hw, (tol - (samples[i] - lb[1]):dot(lb[2])) / proj)
                end
            end
            hw = math.max(hw, floorHw)
        end
        out[i] = hw
    end
    return out
end

local function filletBridge(pA, dA, wA, pB, dB, wB, spacing, magScale)
    local dense = bridgeSamples(pA, dA, pB, dB, magScale or 1.0)
    if not dense then return {} end

    local cum, turnTotal = {0.0}, 0.0
    for i = 2, #dense do
        cum[i] = cum[i - 1] + (dense[i] - dense[i - 1]):length()
    end
    for i = 2, #dense - 1 do
        local a, b = flatDir(dense[i] - dense[i - 1]), flatDir(dense[i + 1] - dense[i])
        turnTotal  = turnTotal + math.deg(math.acos(clamp(a:dot(b), -1.0, 1.0)))
    end
    local total = cum[#cum]
    if total < 1e-4 then return {} end

    local stepsLen = math.floor(total / math.max(spacing, 1e-3) + 0.5)
    local stepsAng = math.ceil(turnTotal / math.max(fillet.maxTurnDeg, 0.1))
    local steps    = math.max(2, stepsLen, math.min(stepsAng, 200))

    local pts, flats = {}, {}
    for sIdx = 1, steps - 1 do
        local target = total * sIdx / steps
        local j      = 2
        while j <= #cum and cum[j] < target do j = j + 1 end
        j         = math.min(j, #cum)
        local seg = cum[j] - cum[j - 1]
        local f   = (seg > 1e-12) and ((target - cum[j - 1]) / seg) or 0.0
        local p   = dense[j - 1] + (dense[j] - dense[j - 1]) * f
        local u   = sIdx / steps
        pts[#pts + 1] = vec3(p.x, p.y, pA.z + (pB.z - pA.z) * u)
        flats[#flats + 1] = p
    end
    local hws = bridgeHalfwidths(flats, pA, dA, wA / 2.0, pB, dB, wB / 2.0)
    local out = {}
    for i = 1, #pts do out[i] = {p = pts[i], w = hws[i] * 2.0} end
    return out
end

local function pinches(pA, dA, hwA, pB, dB, hwB, scale)
    local sm = bridgeSamples(pA, dA, pB, dB, scale)
    if not sm then return false end
    local n = #sm
    for i = 2, n - 1 do
        local seg = ((sm[i] - sm[i - 1]):length() + (sm[i + 1] - sm[i]):length()) / 2.0
        if seg >= 1e-9 then
            local a, b = flatDir(sm[i] - sm[i - 1]), flatDir(sm[i + 1] - sm[i])
            local ang  = math.acos(clamp(a:dot(b), -1.0, 1.0))
            local hw   = hwA + (hwB - hwA) * ((i - 1) / (n - 1))
            if ang > 1e-9 and seg / ang < hw * 0.98 then return true end
        end
    end
    return false
end

local function solveInwardScale(pA, dA, hwA, pB, dB, hwB)
    if not fillet.keepInside then return 1.0 end
    local nA, nB = outwardNormals(dA, dB)
    if not nA then return 1.0 end
    local tol = fillet.insideTol

    local function ok(scale)
        local sm = bridgeSamples(pA, dA, pB, dB, scale)
        return sm ~= nil and outwardViolation(sm, pA, pB, nA, nB) <= tol
    end

    if ok(1.0) then return 1.0 end
    local lo = 0.15
    if not ok(lo) then return nil end
    local hi = 1.0
    for _ = 1, 12 do
        local mid = (lo + hi) / 2.0
        if ok(mid) then lo = mid else hi = mid end
    end
    return lo
end

local function tryFan(A, wA, B, wB, capA, capB)
    local ta, tb = 0.0, 0.0
    local frame  = nil
    for _ = 1, 8 do
        local pA, dA, hwA, pB, dB, hwB = junctionState(A, wA, B, wB, ta, tb)
        if not pA then return nil end
        local turn = math.deg(math.acos(clamp(dA:dot(dB), -1.0, 1.0)))
        if turn < decal.fanMinTurnDeg then return nil end
        local ref = cornerTrims(pA, dA, hwA, pB, dB, hwB)
        if not ref then return nil end
        if (ref.inner - pA):length() > decal.fanMaxReach * math.max(hwA, hwB) then
            return nil
        end
        local dTa, dTb = ref.trimA, ref.trimB
        if math.abs(dTa) < 1e-3 and math.abs(dTb) < 1e-3 then
            frame = ref
            break
        end
        local nta, ntb = ta + dTa, tb + dTb
        if nta < -1e-6 or ntb < -1e-6 or nta > capA or ntb > capB then return nil end
        ta, tb = nta, ntb
    end
    if not frame then return nil end
    return {ta = ta, tb = tb, scale = 1.0, frame = frame}
end

local function fanCorner(inner, nA, wA, nB, wB, sign, spacing, zA, zB)
    local cz   = nA.x * nB.y - nA.y * nB.x
    local turn = math.atan2(cz, clamp(nA:dot(nB), -1.0, 1.0))
    if math.abs(turn) < 1e-4 then return {} end

    local steps = math.max(2, math.ceil(math.abs(math.deg(turn))
                                        / math.max(fillet.maxTurnDeg, 0.1)))
    steps = math.max(steps,
                     math.floor(math.abs(turn) * math.max(wA, wB)
                                / math.max(spacing, 1e-3) + 0.5), 2)
    steps = math.min(steps, 240)

    local capOk = (wB >= wA * math.cos(turn) - 1e-6)
                                and (wA >= wB * math.cos(turn) - 1e-6)

    local out = {}
    for i = 0, steps do
        local t     = i / steps
        local phi   = turn * t
        local c, sn = math.cos(phi), math.sin(phi)
        local u     = vec3(nA.x * c - nA.y * sn, nA.x * sn + nA.y * c, 0.0)

        local smooth = t * t * (3.0 - 2.0 * t)
        local r      = wA + (wB - wA) * smooth
        if capOk then
            local ca, cb = math.cos(phi), math.cos(turn - phi)
            if ca > 0.05 then r = math.min(r, wA / ca) end
            if cb > 0.05 then r = math.min(r, wB / cb) end
        end
        if i == 0 then r = wA elseif i == steps then r = wB end
        r = math.max(r, 1e-3)

        local center = inner + u * (r / 2.0)
        if zA and zB then center = vec3(center.x, center.y, zA + (zB - zA) * smooth) end

        local tangent = vec3(-u.y, u.x, 0.0) * sign
        out[#out + 1] = {p = center, w = r, t = tangent}
    end
    return out
end

local function solveJunction(ptsA, wsA, ptsB, wsB)
    local capA = fillet.maxTrim * polylineLength(ptsA)
    local capB = fillet.maxTrim * polylineLength(ptsB)

    local pA, dA, hwA, _, dB, hwB = junctionState(ptsA, wsA, ptsB, wsB, 0.0, 0.0)
    if not pA then return nil, "decal too short" end
    local turn0 = math.deg(math.acos(clamp(dA:dot(dB), -1.0, 1.0)))
    if turn0 > fillet.maxCornerDeg then
        return nil, "turn too sharp (V/hairpin)"
    end

    local fan = tryFan(ptsA, wsA, ptsB, wsB, capA, capB)
    if fan then return fan end

    local ratio = math.max(hwA, hwB) / math.max(math.min(hwA, hwB), 1e-6)
    if ratio > fillet.maxWidthRatio then
        return nil, "width ratio with no corner to fan from"
    end

    local ta, tb = 0.0, 0.0
    for _ = 1, 6 do
        local qA, qdA, qhwA, qB, qdB, qhwB = junctionState(ptsA, wsA, ptsB, wsB, ta, tb)
        if not qA then return nil, "decal too short" end
        local ref = cornerTrims(qA, qdA, qhwA, qB, qdB, qhwB)
        if not ref then break end
        if math.abs(ref.trimA) < 1e-3 and math.abs(ref.trimB) < 1e-3 then break end
        ta = math.max(0.0, math.min(capA, ta + ref.trimA))
        tb = math.max(0.0, math.min(capB, tb + ref.trimB))
    end
    ta = ta * fillet.innerBias
    tb = tb * fillet.innerBias

    local advance  = fillet.minAdvance
    local advanced = false
    for _ = 1, 16 do
        local qA, qdA, _, qB, qdB = junctionState(ptsA, wsA, ptsB, wsB, ta, tb)
        if not qA then return nil, "decal too short" end
        local chordV = qB - qA
        local chord  = vec3(chordV.x, chordV.y, 0.0)
        local defA   = advance - qdA:dot(chord)
        local defB   = advance - qdB:dot(chord)
        if defA <= 1e-3 and defB <= 1e-3 then advanced = true break end
        if ta >= capA - 1e-6 and tb >= capB - 1e-6 then
            return nil, "overlap exceeds the trim budget"
        end
        ta = math.min(capA, ta + math.max(0.0, defA) * 0.5 + 1e-3)
        tb = math.min(capB, tb + math.max(0.0, defB) * 0.5 + 1e-3)
    end
    if not advanced then return nil, "overlap exceeds the trim budget" end

    local last = "outward bulge / inner curb pinch"
    for _ = 1, 6 do
        local qA, qdA, qhwA, qB, qdB, qhwB = junctionState(ptsA, wsA, ptsB, wsB, ta, tb)
        if not qA then return nil, "decal too short" end
        local scale = solveInwardScale(qA, qdA, qhwA, qB, qdB, qhwB)
        if scale == nil then
            last = "outward bulge unavoidable"
        elseif pinches(qA, qdA, qhwA, qB, qdB, qhwB, scale) then
            last = "radius smaller than the half-width (pinch)"
        else
            return {ta = ta, tb = tb, scale = scale, frame = nil}
        end
        if ta >= capA - 1e-6 and tb >= capB - 1e-6 then return nil, last end
        local step = math.max(0.25, 0.15 * (qhwA + qhwB))
        ta         = math.min(capA, ta + step)
        tb         = math.min(capB, tb + step)
    end
    return nil, last
end

local function clusterEndpoints(endpoints, tol)
    local n      = #endpoints
    local parent = {}
    for i = 1, n do parent[i] = i end

    local function find(a)
        while parent[a] ~= a do
            parent[a] = parent[parent[a]]
            a         = parent[a]
        end
        return a
    end

    for i = 1, n do
        for j = i + 1, n do
            if (endpoints[i].pos - endpoints[j].pos):length() <= tol then
                local ra, rb = find(i), find(j)
                if ra ~= rb then parent[rb] = ra end
            end
        end
    end

    local groups, order = {}, {}
    for i = 1, n do
        local r = find(i)
        if not groups[r] then groups[r] = {} order[#order + 1] = r end
        table.insert(groups[r], i)
    end
    local out = {}
    for _, r in ipairs(order) do out[#out + 1] = groups[r] end
    return out
end

local function keyOf(r, e) return r .. ":" .. e end

local function chainOrder(nRoads, partner)
    local chains, used = {}, {}

    local function walk(startRoad, enterEnd)
        local chain = {}
        local r, e  = startRoad, enterEnd
        while true do
            if used[r] then return chain, true end
            used[r] = true
            chain[#chain + 1] = {road = r, rev = (e == 1)}
            local nxt = partner[keyOf(r, 1 - e)]
            if not nxt then return chain, false end
            r, e = nxt[1], nxt[2]
            if r == startRoad and e == enterEnd then return chain, true end
        end
    end

    for r = 1, nRoads do
        if not used[r] then
            local free = nil
            for _, e in ipairs({0, 1}) do
                if not partner[keyOf(r, e)] then free = e break end
            end
            if free ~= nil then
                local c, cyc = walk(r, free)
                chains[#chains + 1] = {chain = c, cycle = cyc}
            end
        end
    end
    for r = 1, nRoads do
        if not used[r] then
            local c, cyc = walk(r, 0)
            chains[#chains + 1] = {chain = c, cycle = cyc}
        end
    end
    return chains
end

local function oriented(prep, e)
    local p, w = {}, {}
    if e == 1 then
        for i = 1, #prep.pts do p[i] = prep.pts[i]; w[i] = prep.ws[i] end
    else
        for i = #prep.pts, 1, -1 do p[#p + 1] = prep.pts[i]; w[#w + 1] = prep.ws[i] end
    end
    return p, w
end

local function weldShortSegments(pts, ws, ts, minLen, closed)
    if #pts < 3 then return pts, ws, ts end
    local kp, kw, kt = {pts[1]}, {ws[1]}, {ts[1]}
    local last       = #pts
    for i = 2, last do
        if i ~= last and (pts[i] - kp[#kp]):length() < minLen then
            if ts[i] then kt[#kt] = ts[i] end
            kw[#kw] = ws[i]
        else
            kp[#kp + 1] = pts[i]
            kw[#kw + 1] = ws[i]
            kt[#kt + 1] = ts[i]
        end
    end
    if #kp >= 3 and (kp[#kp] - kp[#kp - 1]):length() < minLen then
        if not kt[#kt] then kt[#kt] = kt[#kt - 1] end
        table.remove(kp, #kp - 1)
        table.remove(kw, #kw - 1)
        table.remove(kt, #kt - 1)
    end
    if closed and #kp >= 4 then
        local dxy = math.sqrt((kp[#kp].x - kp[1].x) ^ 2 + (kp[#kp].y - kp[1].y) ^ 2)
        if dxy < decal.seamWeld then
            if not kt[1] and kt[#kt] then kt[1] = kt[#kt] end
            table.remove(kp)
            table.remove(kw)
            table.remove(kt)
        end
    end
    return kp, kw, kt
end

local function markJoinedEnds(roads)
    if not paths.noJunctionCaps then return 0 end

    local ends = {}
    for _, rd in ipairs(roads) do
        if not rd.isIsland and #rd.points >= 2 then
            ends[#ends + 1] = {rd = rd, key = "noCapStart", p = rd.points[1]}
            ends[#ends + 1] = {rd = rd, key = "noCapEnd",   p = rd.points[#rd.points]}
        end
    end

    local marked = 0
    for i = 1, #ends do
        for j = i + 1, #ends do
            local a, b = ends[i], ends[j]
            if a.rd ~= b.rd
                  and math.sqrt((a.p.x - b.p.x) ^ 2 + (a.p.y - b.p.y) ^ 2) <= paths.capTol then
                for _, e in ipairs({a, b}) do
                    if not e.rd[e.key] then
                        e.rd[e.key] = true
                        marked      = marked + 1
                    end
                end
            end
        end
    end
    return marked
end

local function endInfo(rd, atEnd)
    local pts = rd.points
    if #pts < 2 then return nil end
    local tip      = atEnd and pts[#pts] or pts[1]
    local probe    = math.max(0.05, fillet.tangentProbe)
    local acc, ref = 0.0, nil
    if atEnd then
        for k = #pts - 1, 1, -1 do
            acc = acc + (pts[k + 1] - pts[k]):length()
            ref = pts[k]
            if acc >= probe then break end
        end
    else
        for k = 2, #pts do
            acc = acc + (pts[k] - pts[k - 1]):length()
            ref = pts[k]
            if acc >= probe then break end
        end
    end
    if not ref then return nil end
    return tip, flatDir(tip - ref)
end

local function flushHairpinTips(roads)
    if not (hairpin.flushTips and roundEnd.on) then return 0 end

    local ends = {}
    for _, rd in ipairs(roads) do
        if not rd.isIsland and #rd.points >= 2 then
            ends[#ends + 1] = {rd = rd, e = true}
            ends[#ends + 1] = {rd = rd, e = false}
        end
    end

    local done, handled, pairs_ = {}, 0, {}
    local function key(rd, e) return tostring(rd.id) .. ":" .. tostring(e) end

    for i = 1, #ends do
        local rdI, eI = ends[i].rd, ends[i].e
        if not done[key(rdI, eI)] then
            for j = i + 1, #ends do
                local rdJ, eJ = ends[j].rd, ends[j].e
                if rdI ~= rdJ and not done[key(rdJ, eJ)] then
                    local pI, dI = endInfo(rdI, eI)
                    local pJ, dJ = endInfo(rdJ, eJ)
                    if pI and pJ
                          and math.sqrt((pI.x - pJ.x) ^ 2 + (pI.y - pJ.y) ^ 2) <= paths.capTol then
                        local cosv = clamp(dI.x * -dJ.x + dI.y * -dJ.y, -1.0, 1.0)
                        local turn = math.deg(math.acos(cosv))
                        if turn > fillet.maxCornerDeg then
                            local den = dI.x * dJ.y - dI.y * dJ.x
                            if math.abs(den) >= 1e-9 then
                                local dx, dy = pJ.x - pI.x, pJ.y - pI.y
                                local sPar   = (dx * dJ.y - dy * dJ.x) / den
                                local uPar   = (dx * dI.y - dy * dI.x) / den
                                local hwI    = (eI and rdI.widths[#rdI.widths] or rdI.widths[1]) / 2.0
                                local hwJ    = (eJ and rdJ.widths[#rdJ.widths] or rdJ.widths[1]) / 2.0
                                local reach  = hairpin.maxExtend * math.max(hwI, hwJ)
                                if sPar > 0.0 and sPar <= reach and uPar > 0.0 and uPar <= reach then
                                    local ix = pI.x + dI.x * sPar
                                    local iy = pI.y + dI.y * sPar

                                    local function extend(rd, atEnd, hw)
                                        local src  = atEnd and rd.points[#rd.points] or rd.points[1]
                                        local node = vec3(ix, iy, src.z)
                                        if atEnd then
                                            rd.points[#rd.points + 1] = node
                                            rd.widths[#rd.widths + 1] = hw * 2.0
                                        else
                                            table.insert(rd.points, 1, node)
                                            table.insert(rd.widths, 1, hw * 2.0)
                                        end
                                    end
                                    extend(rdI, eI, hwI)
                                    extend(rdJ, eJ, hwJ)

                                    local lenI = polylineLength(rdI.points)
                                    local lenJ = polylineLength(rdJ.points)
                                    local keep, keepE, drop, dropE
                                    if lenI >= lenJ then
                                        keep, keepE, drop, dropE = rdI, eI, rdJ, eJ
                                    else
                                        keep, keepE, drop, dropE = rdJ, eJ, rdI, eI
                                    end
                                    if keepE then keep.noCapEnd = false else keep.noCapStart = false end
                                    if dropE then drop.noCapEnd = true else drop.noCapStart = true end

                                    done[key(rdI, eI)] = true
                                    done[key(rdJ, eJ)] = true
                                    pairs_[#pairs_ + 1] = {rdI, eI, rdJ, eJ, vec3(ix, iy, 0)}
                                    handled = handled + 1
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return handled, pairs_
end

local function mergeJunctions(roads)
    local prepared = {}
    for _, rd in ipairs(roads) do
        if #rd.points >= 2 then
            prepared[#prepared + 1] = {pts = rd.points, ws = rd.widths, src = rd}
        end
    end
    if #prepared < 2 then return roads end

    local endpoints = {}
    for i, p in ipairs(prepared) do
        endpoints[#endpoints + 1] = {road = i, e = 0, pos = p.pts[1]}
        endpoints[#endpoints + 1] = {road = i, e = 1, pos = p.pts[#p.pts]}
    end

    local partner = {}
    for _, grp in ipairs(clusterEndpoints(endpoints, decal.joinTol)) do
        if #grp == 2 then
            local a, b = endpoints[grp[1]], endpoints[grp[2]]
            if not (a.road == b.road and a.e == b.e) then
                partner[keyOf(a.road, a.e)] = {b.road, b.e}
                partner[keyOf(b.road, b.e)] = {a.road, a.e}
            end
        end

    end
    if next(partner) == nil then return roads end

    local trims = {}
    for k, v in pairs(partner) do
        if not trims[k] then
            local r, e      = k:match("^(%d+):(%d+)$")
            r, e            = tonumber(r), tonumber(e)
            local r2, e2    = v[1], v[2]
            local ptsA, wsA = oriented(prepared[r], e)
            local ptsB, wsB = oriented(prepared[r2], e2)
            local rb, rw    = {}, {}
            for i = #ptsB, 1, -1 do rb[#rb + 1] = ptsB[i]; rw[#rw + 1] = wsB[i] end
            local sol = solveJunction(ptsA, wsA, rb, rw)
            if sol then
                local flip = nil
                if sol.frame then
                    local f = sol.frame
                    flip    = {inner = f.inner, nA = f.nB, nB = f.nA, wA = f.wB, wB = f.wA,
                            sign = -f.sign, zA = f.zB, zB = f.zA}
                end
                trims[k] = {t = sol.ta, scale = sol.scale, frame = sol.frame}
                trims[keyOf(r2, e2)] = {t = sol.tb, scale = sol.scale, frame = flip}
            else
                partner[k] = nil
                partner[keyOf(r2, e2)] = nil
            end
        end
    end
    if next(partner) == nil then return roads end

    local out = {}
    for _, entry in ipairs(chainOrder(#prepared, partner)) do
        local chain, isCycle = entry.chain, entry.cycle
        if #chain == 1 and not isCycle then
            out[#out + 1] = prepared[chain[1].road].src
        else
            local segs = {}
            for _, node in ipairs(chain) do
                local p       = prepared[node.road]
                local pts, ws = {}, {}
                if node.rev then
                    for i = #p.pts, 1, -1 do pts[#pts + 1] = p.pts[i]; ws[#ws + 1] = p.ws[i] end
                else
                    for i = 1, #p.pts do pts[i] = p.pts[i]; ws[i] = p.ws[i] end
                end
                local tin  = trims[keyOf(node.road, node.rev and 1 or 0)]
                local tout = trims[keyOf(node.road, node.rev and 0 or 1)]
                pts, ws    = trimFromStart(pts, ws, tin and tin.t or 0.0)
                pts, ws    = trimFromEnd(pts, ws, tout and tout.t or 0.0)
                segs[#segs + 1] = {pts = pts, ws = ws, src = p.src,
                                   scaleOut = tout and tout.scale or 1.0,
                                   frameOut = tout and tout.frame or nil}
            end

            local outP, outW, outT = {}, {}, {}
            for i = 1, #segs[1].pts do
                outP[i] = segs[1].pts[i]; outW[i] = segs[1].ws[i]; outT[i] = false
            end
            local nJoin = isCycle and #segs or (#segs - 1)
            for k = 1, nJoin do
                local nxt    = segs[(k % #segs) + 1]
                local pA, wA = outP[#outP], outW[#outW]
                local dA     = dirAtEnd(outP, fillet.tangentProbe)
                local pB, wB = nxt.pts[1], nxt.ws[1]
                local rnxt   = {}
                for i = #nxt.pts, 1, -1 do rnxt[#rnxt + 1] = nxt.pts[i] end
                local dB = dirAtEnd(rnxt, fillet.tangentProbe) * -1.0

                local fr = segs[k].frameOut
                local bridge
                if fr then
                    bridge = fanCorner(fr.inner, fr.nA, fr.wA, fr.nB, fr.wB, fr.sign,
                                       smoothing.segLen, fr.zA, fr.zB)
                else
                    bridge = filletBridge(pA, dA, wA, pB, dB, wB,
                                          smoothing.segLen, segs[k].scaleOut)
                end

                for j, b in ipairs(bridge) do
                    local weld = (j == 1) and decal.seamWeld or 1e-5
                    if (b.p - outP[#outP]):length() > weld then
                        outP[#outP + 1] = b.p
                        outW[#outW + 1] = b.w
                        outT[#outT + 1] = b.t or false
                    else
                        outW[#outW] = b.w
                        if b.t then outT[#outT] = b.t end
                    end
                end
                if k + 1 <= #segs then
                    for j = 1, #nxt.pts do
                        local weld = (j == 1) and decal.seamWeld or 1e-5
                        if (nxt.pts[j] - outP[#outP]):length() > weld then
                            outP[#outP + 1] = nxt.pts[j]
                            outW[#outW + 1] = nxt.ws[j]
                            outT[#outT + 1] = false
                        else
                            outW[#outW] = nxt.ws[j]
                        end
                    end
                end
            end

            outP, outW, outT = weldShortSegments(outP, outW, outT, paths.minSpacing, isCycle)

            local base   = segs[1].src
            local srcIds = {}
            for _, sg in ipairs(segs) do srcIds[#srcIds + 1] = sg.src.id end
            out[#out + 1] = {
                id          = base.id, name = base.name, persistentId = base.persistentId,
                srcIds      = srcIds,
                points      = outP, widths = outW, sectionTangents = outT,
                closed      = isCycle,
                curb        = base.curb, walk = base.walk, profile = base.profile,
                overObjects = base.overObjects,
                merged      = #segs,
            }
        end
    end
    return out
end

-- =============================================================================
-- ISLAND BUILD
-- =============================================================================

local function buildIslandMesh(isl)
    local outer = {}
    for i, p in ipairs(isl.ring) do outer[i] = p end
    if signedArea2D(outer) < 0 then
        local r = {}
        for i = #outer, 1, -1 do r[#r + 1] = outer[i] end
        outer = r
    end
    local n = #outer
    if n < 3 then return nil end

    local prof   = S.curbProfiles[isl.profile] or S.curbProfiles.island
    local slopeV = math.min(prof.exposed, S.height)
    local slopeH = math.min(math.tan(math.rad(prof.angle)) * slopeV, S.curbStrip * 0.9)

    local slopeRing = nil
    if slopeH > 1e-6 then
        local cand      = fitInnerRing(outer, offsetPolygonInward(outer, slopeH), slopeH)
        local aOut, aIn = signedArea2D(outer), signedArea2D(cand)
        if #cand == n and aIn > 0.0 and aIn < aOut then
            slopeRing = cand
        else
            slopeH, slopeV = 0.0, 0.0
        end
    end

    local inner, innerTris, fillRing = nil, nil, nil
    if S.curbStrip > 1e-6 then
        local cand = fitInnerRing(outer, offsetPolygonInward(outer, S.curbStrip),
                                  S.curbStrip)
        local aOut, aIn = signedArea2D(outer), signedArea2D(cand)
        if aIn > island.minArea * 0.05 and aIn < aOut then

            local tris, used = triangulatePolygon(cand)
            inner            = cand
            innerTris        = tris
            fillRing         = used
        end
    end

    local curbMat = curbMaterialName()
    if not curbMat then return nil, "curb.material is not set in the styles config" end
    local walkMat = walkMaterialName()
    local smCurb  = newSubmesh(curbMat)
    local smWalk  = newSubmesh(walkMat or curbMat)

    local overObjects = isl.overObjects and true or false
    local function mkz(p, drop)
        local ground = overObjects and p.z or terrainZ(p.x, p.y, p.z)
        return vec3(p.x, p.y, ground + S.zOffset + decal.lift - drop)
    end

    local topRing          = slopeRing or outer
    local oBot, oTop, oMid = {}, {}, {}
    for i = 1, n do
        oBot[i] = mkz(outer[i], S.height)
        oTop[i] = mkz(topRing[i], 0.0)
        oMid[i] = slopeRing and mkz(outer[i], slopeV) or oTop[i]
    end
    local iTop = {}
    if inner then
        for i = 1, n do iTop[i] = mkz(inner[i], 0.0) end
    end
    local fTop = {}
    if fillRing then
        for i = 1, #fillRing do fTop[i] = mkz(fillRing[i], 0.0) end
    end

    local perim = {0.0}
    for i = 2, n do
        perim[i] = perim[i - 1] + math.sqrt((outer[i].x - outer[i - 1].x) ^ 2
                                            + (outer[i].y - outer[i - 1].y) ^ 2)
    end
    local totalPerim = perim[n] + math.sqrt((outer[1].x - outer[n].x) ^ 2
                                            + (outer[1].y - outer[n].y) ^ 2)

    local flatW = S.curbStrip - slopeH

    for i = 1, n do
        local j       = (i % n) + 1
        local s0      = perim[i]
        local s1      = (j == 1) and totalPerim or perim[j]
        local outward = vec3(outer[j].y - outer[i].y, outer[i].x - outer[j].x, 0)

        pushWall(smCurb, oBot[i], oMid[i], oMid[j], oBot[j],
                 {curbU(s0), curbFaceV(S.height)},
                 {curbU(s0), curbFaceV(slopeV)},
                 {curbU(s1), curbFaceV(slopeV)},
                 {curbU(s1), curbFaceV(S.height)},
                 outward)

        if slopeRing then
            pushWall(smCurb, oMid[i], oTop[i], oTop[j], oMid[j],
                     {curbU(s0), curbFaceV(slopeV)},
                     {curbU(s0), curbFaceV(0.0)},
                     {curbU(s1), curbFaceV(0.0)},
                     {curbU(s1), curbFaceV(slopeV)},
                     outward)
        end

        if inner then
            pushQuad(smCurb, iTop[i], iTop[j], oTop[j], oTop[i],
                     {curbU(s0), curbTopV(0.0)},
                     {curbU(s1), curbTopV(0.0)},
                     {curbU(s1), curbTopV(flatW)},
                     {curbU(s0), curbTopV(flatW)})
        end
    end

    if inner and innerTris then
        local su, sv = mr.walkScale()
        local function uvFill(p) return p.x / su + 0.5, p.y / sv + 0.5 end
        for _, t in ipairs(innerTris) do
            local a, b, c = t[1], t[2], t[3]

            a, b, c          = a, c, b
            local pa, pb, pc = fTop[a], fTop[b], fTop[c]
            local nrm        = (pb - pa):cross(pc - pa)
            if nrm:length() > 1e-9 then
                nrm = nrm:normalized()
                if nrm.z < 0 then nrm = nrm * -1 end

                local ni     = pushNormal(smWalk, nrm)
                local i1     = pushVert(smWalk, pa)
                local i2     = pushVert(smWalk, pb)
                local i3     = pushVert(smWalk, pc)
                local ua, va = uvFill(fillRing[a])
                local ub, vb = uvFill(fillRing[b])
                local uc, vc = uvFill(fillRing[c])
                local t1     = pushUV(smWalk, ua, va)
                local t2     = pushUV(smWalk, ub, vb)
                local t3     = pushUV(smWalk, uc, vc)
                pushTri(smWalk, i1, i2, i3, ni, t1, t2, t3)
            end
        end
    end

    local out = {}
    if #smCurb.faces > 0 then out[#out + 1] = smCurb end
    if #smWalk.faces > 0 then out[#out + 1] = smWalk end
    if #out == 0 then return nil end
    return out
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.buildIslandMesh  = buildIslandMesh
M.extractIslands   = extractIslands
M.flushHairpinTips = flushHairpinTips
M.hairpinUnionRing = hairpinUnionRing
M.markJoinedEnds   = markJoinedEnds
M.mergeJunctions   = mergeJunctions
M.signedArea2D     = signedArea2D

return M
