-- =============================================================================
-- MaGE - edge wall
-- Version: 1.0.0
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local G         = require("editor/mage/core/Geometry")
local emitFace  = G.emitFace
local curbU     = G.curbU
local curbFaceV = G.curbFaceV

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local stepGap = 0.002

-- =============================================================================
-- PROFILE
-- =============================================================================

local function knotsFromPieces(pieces)
    local knots = {}
    local g     = stepGap / 2.0
    for _, pc in ipairs(pieces) do
        local s0, s1, h0, h1 = pc[1], pc[2], pc[3], pc[4]
        local last           = knots[#knots]
        if last and math.abs(last[1] - s0) < 1e-6 then
            if math.abs(last[2] - h0) > 1e-6 then
                knots[#knots] = nil
                knots[#knots + 1] = {s0 - g, last[2]}
                knots[#knots + 1] = {s0 + g, h0}
            end
        else
            knots[#knots + 1] = {s0, h0}
        end
        knots[#knots + 1] = {s1, h1}
    end
    return knots
end

local function profileH(knots, sv)
    if sv <= knots[1][1] then return knots[1][2] end
    for k = 1, #knots - 1 do
        local sa, ha, sb, hb = knots[k][1], knots[k][2], knots[k + 1][1], knots[k + 1][2]
        if sv <= sb then
            if sb - sa <= 1e-12 then return ha end
            return ha + (hb - ha) * (sv - sa) / (sb - sa)
        end
    end
    return knots[#knots][2]
end

-- =============================================================================
-- BUILD
-- =============================================================================

local function build(stations, dists, tangents, sm, np, knots, thick)
    local s0 = dists[1]
    if #knots < 2 then return end
    local list = {}
    for _, k in ipairs(knots) do list[#list + 1] = s0 + k[1] end
    for i = 1, np do
        local far = true
        for _, k in ipairs(knots) do
            if math.abs(dists[i] - (s0 + k[1])) <= 2.0 * stepGap then far = false break end
        end
        if far then list[#list + 1] = dists[i] end
    end
    table.sort(list)
    local stn = {}
    for _, v in ipairs(list) do
        if #stn == 0 or math.abs(v - stn[#stn]) > 1e-12 then stn[#stn + 1] = v end
    end
    local function nz(v) return (v:length() > 1e-12) and v:normalized() or v end
    local function seg(sv)
        local j = 1
        while j < np - 1 and dists[j + 1] < sv do j = j + 1 end
        local span = dists[j + 1] - dists[j]
        local f    = 0.0
        if span > 1e-12 then f = math.max(0.0, math.min(1.0, (sv - dists[j]) / span)) end
        return j, f
    end
    for _, c in ipairs({1, #stations[1].top}) do
        local sign = (c == 1) and -1.0 or 1.0
        local rows = {}
        for _, sv in ipairs(stn) do
            local j, f = seg(sv)
            local A, B = stations[j], stations[j + 1]
            local o    = A.top[c] + (B.top[c] - A.top[c]) * f
            local up   = nz((A.down + (B.down - A.down) * f) * -1.0)
            local side = nz((A.side + (B.side - A.side) * f) * sign)
            side       = nz(side - up * side:dot(up))
            local ch   = A.chamfer + (B.chamfer - A.chamfer) * f
            local su   = A.s + (B.s - A.s) * f
            local tn   = nz(tangents[j] + (tangents[j + 1] - tangents[j]) * f)
            local h    = profileH(knots, sv - s0)
            local top  = o + up * ch
            rows[#rows + 1] = {s = sv, su = su, h = h, ch = ch, up = up, side = side, t = tn,
                               ob = o, ib = top - side * thick, ot = top + up * h,
                               it = top - side * thick + up * h}
        end
        for k = 1, #rows - 1 do
            local a, b   = rows[k], rows[k + 1]
            local side   = nz(a.side + b.side)
            local up     = nz(a.up + b.up)
            local ta, tb = a.su, b.su
            emitFace(sm, {a.ob, a.ot, b.ot, b.ob},
                     {{curbU(ta), curbFaceV(a.ch)}, {curbU(ta), curbFaceV(-a.h)},
                      {curbU(tb), curbFaceV(-b.h)}, {curbU(tb), curbFaceV(b.ch)}}, side)
            emitFace(sm, {a.ib, a.it, b.it, b.ib},
                     {{curbU(ta), curbFaceV(0.0)}, {curbU(ta), curbFaceV(-a.h)},
                      {curbU(tb), curbFaceV(-b.h)}, {curbU(tb), curbFaceV(0.0)}},
                     side * -1.0)
            local run = math.max(1e-9, b.s - a.s)
            if math.abs(b.h - a.h) < run then
                emitFace(sm, {a.ot, a.it, b.it, b.ot},
                         {{curbU(ta), curbFaceV(-a.h)}, {curbU(ta), curbFaceV(-a.h - thick)},
                          {curbU(tb), curbFaceV(-b.h - thick)}, {curbU(tb), curbFaceV(-b.h)}}, up)
            else
                emitFace(sm, {a.ot, a.it, b.it, b.ot},
                         {{curbU(ta), curbFaceV(-a.h)}, {curbU(ta + thick), curbFaceV(-a.h)},
                          {curbU(tb + thick), curbFaceV(-b.h)}, {curbU(tb), curbFaceV(-b.h)}}, up)
            end
        end
        local nc    = #stations[1].top
        local chCol = (c == 1) and 2 or (nc - 1)
        for _, e in ipairs({{rows[1], -1.0, stations[1]}, {rows[#rows], 1.0, stations[np]}}) do
            local r, sg, st = e[1], e[2], e[3]
            local col       = st.cols and st.cols[chCol]
            local cv        = (col and col.role and col.role:find("chamfer", 1, true)) and st.top[chCol] or nil
            if r.ch > 1e-6 and cv then
                local topO = r.ob + r.up * r.ch
                emitFace(sm, {r.ib, r.it, r.ot, topO},
                         {{curbU(r.su + thick), curbFaceV(0.0)}, {curbU(r.su + thick), curbFaceV(-r.h)},
                          {curbU(r.su), curbFaceV(-r.h)}, {curbU(r.su), curbFaceV(0.0)}}, r.t * sg)
                local cOff = math.abs((r.ob - cv):dot(r.side))
                emitFace(sm, {topO, r.ob, cv},
                         {{curbU(r.su), curbFaceV(0.0)}, {curbU(r.su), curbFaceV(r.ch)},
                          {curbU(r.su + cOff), curbFaceV(0.0)}}, r.t * sg)
            else
                emitFace(sm, {r.ib, r.it, r.ot, r.ob},
                         {{curbU(r.su + thick), curbFaceV(0.0)}, {curbU(r.su + thick), curbFaceV(-r.h)},
                          {curbU(r.su), curbFaceV(-r.h)}, {curbU(r.su), curbFaceV(r.ch)}}, r.t * sg)
            end
        end
    end
end

-- =============================================================================
-- BLOCKS
-- =============================================================================

local function nz(v)
    return (v:length() > 1e-12) and v:normalized() or v
end

local function rowAt(stations, dists, tangents, np, sv)
    local j = 1
    while j < np - 1 and dists[j + 1] < sv do j = j + 1 end
    local span = dists[j + 1] - dists[j]
    local f    = 0.0
    if span > 1e-12 then f = math.max(0.0, math.min(1.0, (sv - dists[j]) / span)) end
    local A, B = stations[j], stations[j + 1]
    local nc   = #A.top
    local pts  = {}
    for c = 1, nc do pts[c] = A.top[c] + (B.top[c] - A.top[c]) * f end
    local up = nz((A.down + (B.down - A.down) * f) * -1.0)
    local sR = nz(A.side + (B.side - A.side) * f)
    sR       = nz(sR - up * sR:dot(up))
    local ch = A.chamfer + (B.chamfer - A.chamfer) * f
    return {
        s   = sv, su = A.s + (B.s - A.s) * f, up = up, sideR = sR, sideL = sR * -1.0, ch = ch,
        pts = pts, t = nz(tangents[j] + (tangents[j + 1] - tangents[j]) * f),
    }
end

local function earClip(xy)
    local n   = #xy
    local idx = {}
    for i = 1, n do idx[i] = i end
    local area = 0.0
    for i = 1, n do
        local p, q = xy[i], xy[i % n + 1]
        area       = area + p[1] * q[2] - q[1] * p[2]
    end
    local sign = (area >= 0) and 1.0 or -1.0
    local function cross(o, a, b)
        return ((a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1])) * sign
    end
    local function inside(p, a, b, c)
        return cross(a, b, p) >= -1e-12 and cross(b, c, p) >= -1e-12 and cross(c, a, p) >= -1e-12
    end
    local tris, guard = {}, 0
    while #idx > 3 and guard < 4 * n do
        guard     = guard + 1
        local cut = false
        for k = 1, #idx do
            local i0, i1, i2 = idx[(k - 2) % #idx + 1], idx[k], idx[k % #idx + 1]
            local a, b, c    = xy[i0], xy[i1], xy[i2]
            if cross(a, b, c) > 1e-12 then
                local ear = true
                for _, j in ipairs(idx) do
                    if j ~= i0 and j ~= i1 and j ~= i2 and inside(xy[j], a, b, c) then
                        ear = false
                        break
                    end
                end
                if ear then
                    tris[#tris + 1] = {i0, i1, i2}
                    table.remove(idx, k)
                    cut = true
                    break
                end
            end
        end
        if not cut then break end
    end
    if #idx == 3 then tris[#tris + 1] = {idx[1], idx[2], idx[3]} end
    return tris
end

local function copyRow(r)
    local out = {}
    for k, v in pairs(r) do out[k] = v end
    return out
end

local function insetRow(r, inset, h)
    local nc     = #r.pts
    local p0, pn = r.pts[1], r.pts[nc]
    local width  = (pn - p0):length()
    local across = nz(pn - p0)
    inset        = math.min(inset, width / 2.0 - 0.05)
    local lo, hi = inset, width - inset
    local lat    = {}
    for c = 1, nc do lat[c] = (r.pts[c] - p0):dot(across) end
    local function at(cut)
        for c = 1, nc - 1 do
            local la, lb = lat[c], lat[c + 1]
            if cut >= la and cut <= lb and lb - la > 1e-9 then
                return r.pts[c] + (r.pts[c + 1] - r.pts[c]) * ((cut - la) / (lb - la))
            end
        end
        return nil
    end
    local pts = {}
    local function add(p)
        if p and (#pts == 0 or (p - pts[#pts]):length() > 1e-6) then pts[#pts + 1] = p end
    end
    add(at(lo))
    for c = 1, nc do
        if lat[c] > lo + 1e-6 and lat[c] < hi - 1e-6 then add(r.pts[c]) end
    end
    add(at(hi))
    local function lift(p)
        local f   = (width > 1e-9) and ((p - p0):dot(across) / width) or 0.0
        local ref = p0 + (pn - p0) * f
        return r.ch + h - (p - ref):dot(r.up)
    end
    local out = copyRow(r)
    out.pts   = pts
    out.lift1 = lift(pts[1])
    out.liftN = lift(pts[#pts])
    return out
end

local function overhangRow(r, half, h)
    local nc  = #r.pts
    local pts = {r.pts[1] + r.sideL * half}
    for c = 1, nc do pts[#pts + 1] = r.pts[c] end
    pts[#pts + 1] = r.pts[nc] + r.sideR * half
    local out  = copyRow(r)
    out.pts    = pts
    out.lift1  = r.ch + h
    out.liftN  = r.ch + h
    out.under1 = r.pts[1]
    out.underN = r.pts[nc]
    return out
end

local function blockCap(sm, r, h, want)
    local nc      = #r.pts
    local otL     = r.pts[1] + r.up * r.lift1
    local otR     = r.pts[nc] + r.up * r.liftN
    local base    = r.pts[1] + r.up * r.ch
    local across  = nz(otR - otL)
    local vs, uvs = {otL}, {{curbU(r.su), curbFaceV(-h)}}
    for c = 1, nc do
        local p = r.pts[c]
        vs[#vs + 1]   = p
        uvs[#uvs + 1] = {curbU(r.su + (p - r.pts[1]):dot(across)), curbFaceV((base - p):dot(r.up))}
    end
    vs[#vs + 1]   = otR
    uvs[#uvs + 1] = {curbU(r.su + (otR - otL):length()), curbFaceV(-h)}
    local xy = {}
    for i, p in ipairs(vs) do xy[i] = {(p - otL):dot(across), (p - base):dot(r.up)} end
    for _, t in ipairs(earClip(xy)) do
        emitFace(sm, {vs[t[1]], vs[t[2]], vs[t[3]]}, {uvs[t[1]], uvs[t[2]], uvs[t[3]]}, want)
    end
end

local function blockFaces(sm, rows, h)
    local nc = #rows[1].pts
    for k = 1, #rows - 1 do
        local a, b = rows[k], rows[k + 1]
        local up   = nz(a.up + b.up)
        for _, e in ipairs({{1, "sideL", "lift1"}, {nc, "sideR", "liftN"}}) do
            local c, key, lk = e[1], e[2], e[3]
            local aob, bob   = a.pts[c], b.pts[c]
            local aot, bot   = aob + a.up * a[lk], bob + b.up * b[lk]
            emitFace(sm, {aob, aot, bot, bob},
                     {{curbU(a.su), curbFaceV(a.ch)}, {curbU(a.su), curbFaceV(-h)},
                      {curbU(b.su), curbFaceV(-h)}, {curbU(b.su), curbFaceV(b.ch)}},
                     nz(a[key] + b[key]))
        end
        local aL, aR = a.pts[1] + a.up * a.lift1, a.pts[nc] + a.up * a.liftN
        local bL, bR = b.pts[1] + b.up * b.lift1, b.pts[nc] + b.up * b.liftN
        local wa, wb = (aR - aL):length(), (bR - bL):length()
        emitFace(sm, {aL, aR, bR, bL},
                 {{curbU(a.su), curbFaceV(-h)}, {curbU(a.su), curbFaceV(-h - wa)},
                  {curbU(b.su), curbFaceV(-h - wb)}, {curbU(b.su), curbFaceV(-h)}}, up)
    end
    if rows[1].under1 then
        for k = 1, #rows - 1 do
            local a, b = rows[k], rows[k + 1]
            local down = nz(a.up + b.up) * -1.0
            local na   = #a.pts
            emitFace(sm, {a.pts[1], a.under1, b.under1, b.pts[1]},
                     {{curbU(a.su), curbFaceV(0.0)}, {curbU(a.su), curbFaceV(-(a.under1 - a.pts[1]):length())},
                      {curbU(b.su), curbFaceV(-(b.under1 - b.pts[1]):length())}, {curbU(b.su), curbFaceV(0.0)}}, down)
            emitFace(sm, {a.underN, a.pts[na], b.pts[na], b.underN},
                     {{curbU(a.su), curbFaceV(0.0)}, {curbU(a.su), curbFaceV(-(a.underN - a.pts[na]):length())},
                      {curbU(b.su), curbFaceV(-(b.underN - b.pts[na]):length())}, {curbU(b.su), curbFaceV(0.0)}}, down)
        end
    end
    blockCap(sm, rows[1], h, rows[1].t * -1.0)
    blockCap(sm, rows[#rows], h, rows[#rows].t)
end

local function buildBlocks(stations, dists, tangents, sm, np, blocks, h, widen)
    widen = widen or 0.0
    for _, blk in ipairs(blocks) do
        local s0, s1 = blk[1], blk[2]
        if s1 - s0 > 1e-6 then
            local list = {s0}
            for i = 1, np do
                if dists[i] > s0 + 1e-6 and dists[i] < s1 - 1e-6 then list[#list + 1] = dists[i] end
            end
            list[#list + 1] = s1
            local rows = {}
            for _, sv in ipairs(list) do
                local r = rowAt(stations, dists, tangents, np, sv)
                r.lift1 = r.ch + h
                r.liftN = r.ch + h
                if widen > 1e-6 then
                    r = overhangRow(r, widen / 2.0, h)
                elseif widen < -1e-6 then
                    r = insetRow(r, -widen / 2.0, h)
                end
                rows[#rows + 1] = r
            end
            blockFaces(sm, rows, h)
        end
    end
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.knotsFromPieces = knotsFromPieces
M.build           = build
M.buildBlocks     = buildBlocks

return M
