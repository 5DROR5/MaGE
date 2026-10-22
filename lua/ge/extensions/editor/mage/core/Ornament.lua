-- =============================================================================
-- MaGE - Building Architect trims around a building floor
-- Version: 1.0.2
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local Modules = require("editor/mage/core/Modules")
local Window  = require("editor/mage/core/Window")
local C       = require("editor/mage/core/Common")
local Texture = require("editor/mage/core/Texture")
local Trims   = require("editor/mage/core/Trims")

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local inset      = 0.02
local samePos    = 0.3
local clear      = 0.05
local minFace    = 0.05
local minHalf    = 0.075
local minRise    = 0.3
local bendDot    = 0.99996
local bendTol    = 0.005
local slabArc    = 4
local faceKeys   = {"right", "left", "start", "end"}
local propGap    = 0.15
local mountDepth = 0.1
local corbelStep = 0.05
local props      = {"ac", "dish"}
local arcStep    = 0.25
local arcMin     = 8
local seatGap    = 0.01
local rules      = {
    balcony  = {anchor = "windows", at = "under", doors = true},
    awning   = {anchor = "windows", at = "over", over = Modules.awningOver, drop = 0.3},
    stairs   = {anchor = "doors", at = "front"},
    flowers  = {anchor = "windows", at = "under", gap = 0.12, unless = "balcony"},
    ac       = {anchor = "windows", at = "beside", side = 1, gap = propGap, under = true},
    dish     = {anchor = "windows", at = "beside", side = -1, gap = 0.02, high = true, mount = true},
    pots     = {anchor = "edge", at = "on", inward = 0.45},
    corbel   = {anchor = "slab", at = "under", reach = {0.15, 3.0}},
    pillar   = {anchor = "slab", at = "under"},
    roofac   = {anchor = "top", at = "on", share = 0.35},
    roofdish = {anchor = "top", at = "on", share = 0.65},
    pipe     = {anchor = "corner", at = "beside", gap = 0.15, clear = 0.1},
}

-- =============================================================================
-- FACES
-- =============================================================================

local function flat(v)
    return vec3(v.x, v.y, 0)
end

local function horiz(v)
    local o = flat(v)
    if o:length() < 1e-9 then return o end
    return o:normalized()
end

local function newFace(pts, tops, inner)
    local P, T, I = {}, {}, {}
    for k, p in ipairs(pts) do
        if #P == 0 or flat(p - P[#P]):length() > 1e-3 then
            P[#P + 1], T[#T + 1], I[#I + 1] = p, tops[k], inner[k]
        end
    end
    if #P < 2 then return nil end
    local s = {0.0}
    for k = 2, #P do s[k] = s[k - 1] + flat(P[k] - P[k - 1]):length() end
    if s[#s] < minFace then return nil end
    return {pts = P, tops = T, inner = I, s = s, len = s[#s]}
end

local function faces(stations, nc, np, tangents)
    local out = {}
    local function mid(st) return (st.bot[1] + st.bot[nc]) * 0.5 end
    for _, c in ipairs({1, nc}) do
        local pts, tops, inner = {}, {}, {}
        for i = 1, np do
            local st = stations[i]
            if st.bot[1] and st.bot[nc] and st.top[c] then
                pts[#pts + 1], tops[#tops + 1], inner[#inner + 1] = st.bot[c], st.top[c].z, mid(st)
            end
        end
        out[(c == 1) and "right" or "left"] = newFace(pts, tops, inner)
    end
    for _, e in ipairs({{"start", 1, 1.0}, {"end", np, -1.0}}) do
        local st = stations[e[2]]
        if st.bot[1] and st.bot[nc] and st.top[1] and st.top[nc] then
            local ref    = mid(st) + horiz(tangents[e[2]]) * e[3]
            out[e[1]] = newFace({st.bot[1], st.bot[nc]}, {st.top[1].z, st.top[nc].z}, {ref, ref})
        end
    end
    return out
end

local function seg(f, s)
    local P, S   = f.pts, f.s
    local lo, hi = 1, #P - 1
    while lo < hi do
        local m = math.floor((lo + hi) / 2)
        if S[m + 1] < s then lo = m + 1 else hi = m end
    end
    local k = lo
    local d = S[k + 1] - S[k]
    return k, (d > 1e-9) and math.max(0.0, math.min(1.0, (s - S[k]) / d)) or 0.0
end

local function at(f, s)
    local k, t = seg(f, s)
    local p    = f.pts[k] + (f.pts[k + 1] - f.pts[k]) * t
    local ref  = f.inner[k] + (f.inner[k + 1] - f.inner[k]) * t
    return p, f.tops[k] + (f.tops[k + 1] - f.tops[k]) * t, ref
end

local function outward(u, p, ref)
    local n = vec3(u.y, -u.x, 0)
    if n:dot(flat(ref - p)) > 0 then n = n * -1.0 end
    return n
end

local function frameAt(f, s)
    local p, top, ref = at(f, s)
    local a, b        = at(f, math.max(0.0, s - 0.05)), at(f, math.min(f.len, s + 0.05))
    local u           = horiz(b - a)
    return p, top, u, outward(u, p, ref)
end

local function project(f, q)
    local best, bs = math.huge, 0.0
    local P, S     = f.pts, f.s
    local qx, qy   = q.x, q.y
    for k = 1, #P - 1 do
        local A, B   = P[k], P[k + 1]
        local ax, ay = A.x, A.y
        local bx, by = B.x - ax, B.y - ay
        local l2     = bx * bx + by * by
        local t      = (l2 > 1e-12) and math.max(0.0, math.min(1.0, ((qx - ax) * bx + (qy - ay) * by) / l2)) or 0.0
        local dx, dy = ax + bx * t - qx, ay + by * t - qy
        local dd     = math.sqrt(dx * dx + dy * dy)
        if dd < best then best, bs = dd, S[k] + (S[k + 1] - S[k]) * t end
    end
    return bs
end

-- =============================================================================
-- PLACING
-- =============================================================================

local function ownOf(m, e, slot)
    local o = m.own and m.own[slot]
    if not o then return e end
    local t = {}
    for k, v in pairs(o) do t[k] = v end
    return setmetatable(t, {__index = e})
end

local function emit(out, m, t)
    for _, sm in ipairs(Modules.put(m, t)) do out[#out + 1] = sm end
end

local function lookOf(m, look)
    return look and Modules.model(look) or m
end

local function slotOf(m, md, slot)
    if not slot then return nil end
    local mv = m.moves and m.moves[slot] or {}
    if mv.off or (m.drop and m.drop[slot]) then return nil end
    local es = ownOf(m, m, slot)
    return {mv = mv, es = es, look = md and lookOf(md, mv.dae), lift = Window.modValue(es, "lift"), away = Window.modValue(es, "out"), ds = mv.s or 0.0, dz = mv.z or 0.0}
end

local function merge(out, m, t)
    for _, sm in ipairs(Modules.put(m, t)) do
        sm.inst       = nil
        out[#out + 1] = sm
    end
end

local function wallT(m, width, p, u, n, z, mode, origin)
    local a, d, o = Modules.axes(m, width)
    local hand    = (u.x * n.y - u.y * n.x >= 0) and 1 or -1
    local sA      = (a == "x") and (o * hand) or (-o * hand)
    local t       = {o = vec3(p.x, p.y, z) - n * inset, z = vec3(0, 0, 1), pv = vec3(0, 0, 0)}
    if a == "x" then t.x, t.y = u * sA, n * o else t.x, t.y = n * o, u * sA end
    t.pv[a] = origin and 0.0 or (m.lo[a] + m.hi[a]) / 2.0
    t.pv[d] = origin and 0.0 or (o > 0) and m.lo[d] or m.hi[d]
    t.pv.z  = (mode == "lo") and m.lo.z or 0.0
    return t, a
end

local function cornerT(p, d1, d2, z, sx, sy)
    if d1.x * d2.y - d1.y * d2.x < 0 then d1, d2 = d2, d1 end
    local t = {o = vec3(p.x, p.y, z), z = vec3(0, 0, 1), pv = vec3(0, 0, 0)}
    if sx * sy > 0 then t.x, t.y = d1 * sx, d2 * sy else t.x, t.y = d2 * sx, d1 * sy end
    return t
end

local function corners(fs)
    local out  = {}
    local caps = {{fs.start, 1, "start"}, {fs["end"], -1, "end"}}
    for _, cap in ipairs(caps) do
        local f = cap[1]
        if f then
            for k, side in ipairs({fs.right, fs.left}) do
                local p   = f.pts[(k == 1) and 1 or #f.pts]
                local q   = f.pts[(k == 1) and #f.pts or 1]
                local top = f.tops[(k == 1) and 1 or #f.tops]
                if side then
                    local sp      = (cap[2] > 0) and side.pts[2] or side.pts[#side.pts - 1]
                    out[#out + 1] = {p = p, top = top, d1 = horiz(q - p), d2 = horiz(sp - p), a = cap[3], b = (k == 1) and "right" or "left"}
                end
            end
        end
    end
    return out
end

local function openings(p, fs, all)
    local out = {}
    for _, k in ipairs(faceKeys) do out[k] = {} end
    for _, pl in ipairs(p.placed or {}) do
        local f = fs[pl.face]
        if f and (all or not pl.gone) then
            local list      = out[pl.face]
            list[#list + 1] = {s = project(f, pl.origin), half = (pl.width or pl.row.width) / 2.0, pl = pl}
        end
    end
    for _, k in ipairs(faceKeys) do table.sort(out[k], function(x, y) return x.s < y.s end) end
    return out
end

local function pillar(out, m, f, s, width, under, taken, slot, mod)
    local st = slotOf(mod, m, slot)
    if not st then return end
    if st.mv.dae and Modules.model(st.mv.dae) then m, width = Modules.model(st.mv.dae), Modules.size(st.mv.dae) end
    s                = math.max(0.0, math.min(f.len, s + st.ds))
    local p, _, u, n = frameAt(f, s)
    local t, a       = wallT(m, width, p - n * inset + n * st.away, u, n * -1.0, 0.0, "lo")
    local d          = (a == "x") and "y" or "x"
    local mid        = vec3(0, 0, 0)
    for _, ca in ipairs({m.lo[a], m.hi[a]}) do
        for _, cd in ipairs({m.lo[d], m.hi[d]}) do
            local q    = vec3(0, 0, 0)
            q[a], q[d] = ca, cd
            local w    = t.o + t.x * (q.x - t.pv.x) + t.y * (q.y - t.pv.y)
            if C.inPoly(under[1].poly, w) or C.polyDist(under[1].poly, w) < clear then return end
            mid = mid + w * 0.25
        end
    end
    for _, q in ipairs(taken) do
        if flat(q - mid):length() < 2.0 * clear then return end
    end
    taken[#taken + 1] = mid
    local zb          = under[#under].base
    for _, fl in ipairs(under) do
        if C.inPoly(fl.poly, mid) then
            zb = fl.top
            break
        end
    end
    if p.z - zb < minRise then return end
    t.o        = vec3(t.o.x, t.o.y, zb)
    t.pv.z     = m.lo.z
    t.sz       = (p.z - zb) / math.max(1e-6, m.hi.z - m.lo.z)
    local from = #out + 1
    emit(out, m, t)
    for k = from, #out do out[k].slot, out[k].fi, out[k].along, out[k].out = slot, "pillar", u, n end
end

local function floorFrame(stations, nc, np)
    local function mid(st) return (st.bot[1] + st.bot[nc]) * 0.5 end
    local a, b = stations[1], stations[np]
    if not (a.bot[1] and a.bot[nc] and b.bot[1] and b.bot[nc]) then return {o = vec3(0, 0, 0), ax = vec3(1, 0, 0)} end
    local o  = mid(a)
    local ax = horiz(mid(b) - o)
    return {o = o, ax = (ax:length() > 1e-9) and ax or vec3(1, 0, 0), len = flat(mid(b) - o):length()}
end

local function propAt(out, m, f, s, z, key, slot, frame, front)
    local p, _, u, n = frameAt(f, s)
    local from       = #out + 1
    local y          = front and front.n or n
    local o          = vec3(p.x, p.y, z) + n * (front and front.off or 0.0) - y * inset
    emit(out, m, {o = o, x = vec3(y.y, -y.x, 0), y = y, z = vec3(0, 0, 1), pv = vec3(0, 0, 0)})
    for k = from, #out do
        local sm                   = out[k]
        sm.kind, sm.slot, sm.fi    = key, slot, key
        sm.along, sm.out, sm.frame = u, n, frame
        sm.at                      = o
    end
end

local function pinSpot(fs, pin, half, frame)
    local w                = frame.o + frame.ax * pin.u + vec3(-frame.ax.y, frame.ax.x, 0) * pin.v
    local best, bs, bd, bf = nil, 0.0, math.huge, nil
    for _, face in ipairs(faceKeys) do
        local f = fs[face]
        if f then
            local sf = project(f, w)
            local d  = flat(at(f, sf) - w):length()
            if d < bd then best, bs, bd, bf = f, sf, d, face end
        end
    end
    if not best then return nil end
    return best, math.max(math.min(half, best.len / 2.0), math.min(best.len - math.min(half, best.len / 2.0), bs)), bf
end

local function fits(list, a, b, z0, z1)
    for _, r in ipairs(list) do
        if a < r[2] and b > r[1] and z0 < r[4] and z1 > r[3] then return false end
    end
    return true
end

local function footprint(m, mount)
    if not mount then return {x0 = m.lo.x, x1 = m.hi.x, z0 = m.lo.z, z1 = m.hi.z} end
    if m.mount then return m.mount end
    local fp = {x0 = math.huge, x1 = -math.huge, z0 = math.huge, z1 = -math.huge}
    for _, sm in ipairs(m.meshes) do
        for _, v in ipairs(sm.verts) do
            if v.y <= m.lo.y + mountDepth then
                fp.x0, fp.x1 = math.min(fp.x0, v.x), math.max(fp.x1, v.x)
                fp.z0, fp.z1 = math.min(fp.z0, v.z), math.max(fp.z1, v.z)
            end
        end
    end
    m.mount = fp
    return fp
end

local function along(m)
    local a = Modules.axes(m, Modules.size(m.path))
    return math.max(m.hi[a] - m.lo[a], 0.1)
end

local function curved(f)
    if f.tg then return #f.tg > 0 end
    f.tg, f.nrm = {}, {}
    local P, bent = f.pts, false
    for k = 2, #P - 1 do
        if horiz(P[k] - P[k - 1]):dot(horiz(P[k + 1] - P[k])) < bendDot then bent = true end
    end
    if not bent then return false end
    for k = 1, #P do
        local u  = horiz(P[math.min(#P, k + 1)] - P[k]) + horiz(P[k] - P[math.max(1, k - 1)])
        f.tg[k]  = u:normalized()
        f.nrm[k] = outward(f.tg[k], P[k], f.inner[k])
    end
    return true
end

local function bendAt(f, s, zOf)
    local p, top = at(f, s)
    local k, t   = seg(f, s)
    local u      = (f.tg[k] + (f.tg[k + 1] - f.tg[k]) * t):normalized()
    local n      = (f.nrm[k] + (f.nrm[k + 1] - f.nrm[k]) * t):normalized()
    return vec3(p.x, p.y, zOf(p.z, p.z, top, top)), u, n
end

local function cross(a, b, c, d)
    local r, q = b - a, d - c
    local den  = r.x * q.y - r.y * q.x
    if math.abs(den) < 1e-12 then return nil end
    local w    = c - a
    local t, u = (w.x * q.y - w.y * q.x) / den, (w.x * r.y - w.y * r.x) / den
    if t <= 0 or t >= 1 or u <= 0 or u >= 1 then return nil end
    return t, u
end

local function tightest(f)
    if f.tight then return f.tight end
    local t = {}
    for k = 1, #f.pts - 1 do
        local a, b = f.tg[k], f.tg[k + 1]
        local ang  = math.acos(math.max(-1.0, math.min(1.0, a:dot(b))))
        if ang > 1e-6 then
            t[#t + 1] = {s = f.s[k + 1], r = (f.s[k + 1] - f.s[k]) / ang, ang = ang, side = ((b - a):dot(f.nrm[k]) > 0) and 1 or -1}
        end
    end
    f.tight = t
    return t
end

local function folds(f, o)
    local key = math.floor(o * 1e3 + 0.5)
    f.cut     = f.cut or {}
    if f.cut[key] ~= nil then return f.cut[key] end
    local reach, hot = 8.0 * math.abs(o) + 1.0, {}
    for _, b in ipairs(tightest(f)) do
        if b.side == ((o > 0) and 1 or -1) and b.r < 2.0 * math.abs(o) and math.abs(o) * math.tan(b.ang / 2.0) > 1e-3 then
            local w       = math.abs(o) * math.max(2.0, 1.5 * math.tan(math.min(b.ang, 3.0) / 2.0)) + 0.5
            hot[#hot + 1] = {b.s - w, b.s, b.s + w}
        end
    end
    if #hot == 0 then
        f.cut[key] = false
        return false
    end
    local function near(sv)
        local mid, to = nil, nil
        for _, h in ipairs(hot) do
            if sv >= h[1] and sv <= h[2] then mid, to = math.min(mid or h[2], h[2]), math.max(to or h[3], h[3]) end
        end
        return to, mid
    end
    local S, Q, U = {}, {}, {}
    local function add(sv)
        local p, u, n                    = bendAt(f, sv, function(z) return z end)
        S[#S + 1], Q[#Q + 1], U[#U + 1] = sv, flat(p) + n * o, u
    end
    local function back(i, j)
        for k = i, j do
            if (Q[k + 1] - Q[k]):dot(U[k]) < 0 then return true end
        end
        return false
    end
    for k = 1, #f.pts - 1 do
        for j = 0, 7 do add(f.s[k] + (f.s[k + 1] - f.s[k]) * j / 8) end
    end
    add(f.len)
    local cuts   = {}
    local i, top = 1, 1
    while i <= #Q - 2 do
        local hit = nil
        while top < #Q - 1 and S[top + 1] - S[i + 1] < reach do top = top + 1 end
        local to, mid = near(S[i])
        local last    = top
        while to and last > i + 2 and S[last] > to do last = last - 1 end
        local first   = i + 2
        while to and first < last and S[first + 1] < mid do first = first + 1 end
        for j = to and last or 0, first, -1 do
            local t, u = cross(Q[i], Q[i + 1], Q[j], Q[j + 1])
            if t and back(i, j) then
                hit = {a = S[i] + (S[i + 1] - S[i]) * t, b = S[j] + (S[j + 1] - S[j]) * u, x = Q[i] + (Q[i + 1] - Q[i]) * t, j = j}
                break
            end
        end
        if hit then
            cuts[#cuts + 1] = hit
            i               = hit.j
        end
        i = i + 1
    end
    f.cut[key] = (#cuts > 0) and {S = S, Q = Q, cuts = cuts} or false
    return f.cut[key]
end

local function offsetAt(f, s, p, n, o)
    local fo = math.abs(o) > 1e-3 and folds(f, o)
    if not fo then return p + n * o end
    for _, c in ipairs(fo.cuts) do
        if s >= c.a and s <= c.b then return vec3(c.x.x, c.x.y, p.z) end
    end
    local S, Q   = fo.S, fo.Q
    local lo, hi = 1, #S
    while hi - lo > 1 do
        local m = math.floor((lo + hi) / 2)
        if S[m] <= s then lo = m else hi = m end
    end
    local d = S[hi] - S[lo]
    local t = (d > 1e-12) and (s - S[lo]) / d or 0.0
    local q = Q[lo] + (Q[hi] - Q[lo]) * t
    return vec3(q.x, q.y, p.z)
end

local function part(c, d, t)
    local function uv(p, q) return p and q and {u = p.u + (q.u - p.u) * t, v = p.v + (q.v - p.v) * t} end
    return {p = c.p + (d.p - c.p) * t, n = c.n + (d.n - c.n) * t, uv = uv(c.uv, d.uv), uv2 = uv(c.uv2, d.uv2),
            ga = c.ga + (d.ga - c.ga) * t, gb = c.gb + (d.gb - c.gb) * t}
end

local function keep(poly, key, sign)
    local out = {}
    for k, c in ipairs(poly) do
        local d      = poly[k % #poly + 1]
        local ci, di = sign * c[key] >= 0, sign * d[key] >= 0
        if ci then out[#out + 1] = c end
        if ci ~= di then out[#out + 1] = part(c, d, c[key] / (c[key] - d[key])) end
    end
    return out
end

local function mitre(sm, f, sOf)
    local keys, spans = {}, {}
    for _, v in ipairs(sm.verts) do
        if math.abs(v.y) > 1e-3 then keys[math.floor(v.y * 1e3 + 0.5)] = v.y end
    end
    for _, o in pairs(keys) do
        for _, c in ipairs((folds(f, o) or {cuts = {}}).cuts) do spans[#spans + 1] = {a = c.a, b = c.b} end
    end
    if #spans == 0 then return sm end
    table.sort(spans, function(x, y) return x.a < y.a end)
    local corners = {}
    for _, c in ipairs(spans) do
        local last = corners[#corners]
        if last and c.a < last.b then last.b = math.max(last.b, c.b) else corners[#corners + 1] = {a = c.a, b = c.b} end
    end
    local lo, hi = math.huge, -math.huge
    for _, v in ipairs(sm.verts) do
        local sv = sOf(v.x)
        lo, hi   = math.min(lo, sv), math.max(hi, sv)
    end
    local polys = {}
    for k = 1, #sm.faces, 3 do
        local tri = {}
        for j = 0, 2 do
            local fc = sm.faces[k + j]
            tri[j + 1] = {p = sm.verts[fc.v + 1], n = sm.normals[fc.n + 1], uv = sm.uvs[fc.u + 1], uv2 = sm.uvs2 and sm.uvs2[fc.u + 1]}
        end
        polys[#polys + 1] = tri
    end
    for _, cr in ipairs(corners) do
        if cr.a < hi and cr.b > lo then
            local mid  = (cr.a + cr.b) / 2.0
            local kept = {}
            for _, poly in ipairs(polys) do
                for _, c in ipairs(poly) do
                    local a, b = mid, mid
                    local fo   = math.abs(c.p.y) > 1e-3 and folds(f, c.p.y)
                    for _, cut in ipairs(fo and fo.cuts or {}) do
                        if cut.a < cr.b and cut.b > cr.a then a, b = cut.a, cut.b end
                    end
                    local sv     = sOf(c.p.x)
                    c.ga, c.gb   = sv - a, sv - b
                end
                for _, piece in ipairs({keep(poly, "ga", -1), keep(poly, "gb", 1)}) do
                    if #piece >= 3 then kept[#kept + 1] = piece end
                end
            end
            polys = kept
        end
    end
    local r = {verts = {}, normals = {}, uvs = {}, uvs2 = sm.uvs2 and {}, faces = {}, material = sm.material, module = sm.module, tint = sm.tint}
    local function push(c)
        local i = #r.verts
        r.verts[i + 1], r.normals[i + 1], r.uvs[i + 1] = c.p, c.n:normalized(), c.uv
        if r.uvs2 then r.uvs2[i + 1] = c.uv2 end
        r.faces[#r.faces + 1] = {v = i, n = i, u = i}
    end
    for _, poly in ipairs(polys) do
        for q = 2, #poly - 1 do push(poly[1]) push(poly[q]) push(poly[q + 1]) end
    end
    return r
end

local function chordOff(a, b, list)
    local d = flat(b - a)
    local l = d:length()
    for _, q in ipairs(list) do
        local e = flat(q - a)
        if l > 1e-9 and math.abs(e.x * d.y - e.y * d.x) / l > bendTol then return true end
    end
    return false
end

local function bends(f, s0, s1)
    local out, inner = {}, {}
    local from       = at(f, s0)
    local prev       = nil
    for k = 1, #f.pts do
        local sk = f.s[k]
        if sk > s0 + 1e-6 and sk < s1 - 1e-6 then
            if prev then
                inner[#inner + 1] = prev.p
                if chordOff(from, f.pts[k], inner) then
                    out[#out + 1] = prev.s
                    from, inner   = prev.p, {}
                end
            end
            prev = {p = f.pts[k], s = sk}
        end
    end
    if prev then
        inner[#inner + 1] = prev.p
        if chordOff(from, at(f, s1), inner) then out[#out + 1] = prev.s end
    end
    return out
end

local function bend(out, m, W, len, f, s0, s1, zOf, origin)
    local a          = Modules.axes(m, W)
    local t          = wallT(m, W, vec3(0, 0, 0), vec3(1, 0, 0), vec3(0, 1, 0), 0.0, "raw", origin)
    local mid        = (s0 + s1) / 2.0
    local _, _, u, n = frameAt(f, mid)
    local hand       = (u.x * n.y - u.y * n.x >= 0) and 1 or -1
    local k          = (s1 - s0) / len
    local g          = (a == "x") and t.x.x or t.y.x
    local cuts       = {}
    for _, sk in ipairs(bends(f, s0, s1)) do cuts[#cuts + 1] = (sk - mid) / (hand * k) / g + t.pv[a] end
    local seen = {}
    local function sOf(x) return math.max(0.0, math.min(f.len, mid + hand * x * k)) end
    for _, piece in ipairs(Modules.put(Modules.cutAt(m, a, cuts), t)) do
        local sm = mitre(piece, f, sOf)
        for i, v in ipairs(sm.verts) do
            local key = math.floor(v.x * 1e5 + 0.5)
            local fr  = seen[key]
            if not fr then
                local sv  = sOf(v.x)
                fr        = {bendAt(f, sv, zOf)}
                fr[4]     = sv
                seen[key] = fr
            end
            local q       = sm.normals[i]
            sm.verts[i]   = offsetAt(f, fr[4], fr[1], fr[3], v.y) + vec3(0, 0, v.z)
            sm.normals[i] = (fr[2] * (hand * q.x / k) + fr[3] * q.y + vec3(0, 0, q.z)):normalized()
        end
        out[#out + 1] = sm
    end
end

local function runs(f, gaps)
    local out, from = {}, 0.0
    for _, g in ipairs(gaps or {}) do
        local a, b = math.max(0.0, g[1]), math.min(f.len, g[2])
        if b > a then
            if a - from >= minFace then out[#out + 1] = {from, a} end
            from = math.max(from, b)
        end
    end
    if f.len - from >= minFace then out[#out + 1] = {from, f.len} end
    return out
end

-- =============================================================================
-- BUILD
-- =============================================================================

local function retexture(sm, mat, su, sv, turn, st)
    local uvs = {}
    for k = 1, #sm.faces, 3 do
        local f    = {sm.faces[k], sm.faces[k + 1], sm.faces[k + 2]}
        local a, b = sm.verts[f[1].v + 1], sm.verts[f[2].v + 1]
        local c    = sm.verts[f[3].v + 1]
        local n    = (b - a):cross(c - a)
        n          = (n:length() > 1e-12) and n:normalized() or vec3(0, 0, 1)
        local t    = (math.abs(n.z) < 0.9) and horiz(vec3(-n.y, n.x, 0)) or (vec3(1, 0, 0) - n * n.x):normalized()
        local w    = n:cross(t)
        if w:length() > 1e-9 then w = w:normalized() end
        if w.z < 0 then w = w * -1.0 end
        for _, q in ipairs(f) do
            local p      = sm.verts[q.v + 1]
            local u, v   = Texture.place(p:dot(t), p:dot(w), su, sv, st)
            uvs[q.u + 1] = turn and {u = v, v = u} or {u = u, v = v}
        end
    end
    sm.material, sm.uvs, sm.uvs2, sm.inst, sm.tint = mat, uvs, nil, nil, nil
end

local function model(cfg, key)
    local m = Window.modOf(cfg, key)
    if not m then return nil end
    local path = m.dae or Modules.defaults[key]
    return Modules.model(path), m, path
end

local function tag(out, from, key)
    for k = from, #out do out[k].kind = out[k].kind or key end
end

local function outerLine(f, s0, s1, o)
    local n    = math.max(2, math.ceil((s1 - s0) / 0.1))
    local S, L = {}, {}
    local prev = nil
    for i = 0, n do
        local sv      = s0 + (s1 - s0) * i / n
        local p, _, w = bendAt(f, sv, function(z) return z end)
        local q       = flat(offsetAt(f, sv, p, w, o))
        S[#S + 1]     = sv
        L[#L + 1]     = prev and (L[#L] + (q - prev):length()) or 0.0
        prev          = q
    end
    local function sAt(l)
        if l <= 0.0 then return S[1] end
        for k = 2, #L do
            if L[k] >= l then
                local d = L[k] - L[k - 1]
                return S[k - 1] + (S[k] - S[k - 1]) * ((d > 1e-12) and (l - L[k - 1]) / d or 0.0)
            end
        end
        return S[#S]
    end
    return L[#L], sAt
end

local function chordAt(f, sAt, la, lb, o)
    local function on(l)
        local sv      = math.max(0.0, math.min(f.len, sAt(l)))
        local p, _, w = bendAt(f, sv, function(z) return z end)
        return offsetAt(f, sv, p, w, o), p, w
    end
    if la > lb then la, lb = lb, la end
    local qa, pa, wa = on(la)
    local qb, pb, wb = on(lb)
    local u          = horiz(qb - qa)
    if u:length() < 0.5 then return nil end
    local n   = vec3(u.y, -u.x, 0)
    if n:dot(wa + wb) < 0 then n = n * -1.0 end
    local mid = (qa + qb) * 0.5
    return vec3(mid.x, mid.y, (pa.z + pb.z) / 2.0) - n * o, u, n
end

local function reach(md, o, d)
    local lo, hi = math.huge, -math.huge
    for _, sm in ipairs(md.meshes) do
        for _, v in ipairs(sm.verts) do
            lo, hi = math.min(lo, o * v[d]), math.max(hi, o * v[d])
        end
    end
    return lo, hi
end

local function section(din, dout, zb, zt)
    local r   = math.min((zt - zb) * 0.4, (dout - din) * 0.4)
    local pts = {{d = din, z = zt, way = "top"}, {d = dout, z = zt, way = "side"}, {d = dout, z = zb + r, way = "side"}}
    for k = 1, slabArc do
        local t           = math.rad(90.0 * k / slabArc)
        pts[#pts + 1]     = {d = dout - r + r * math.cos(t), z = zb + r - r * math.sin(t), way = (k == slabArc) and "bottom" or "side"}
    end
    pts[#pts + 1] = {d = din, z = zb}
    return pts
end

local function slab(out, m, parts, rim, din, dout, z0, ctx)
    local sides = {}
    for _, way in ipairs({"top", "bottom", "side"}) do
        sides[way] = {verts = {}, normals = {}, uvs = {}, faces = {}, material = parts.mats[way], module = true, tint = parts.tints[parts.mats[way]]}
    end
    local sec = section(din, dout, z0 + parts.zb, z0 + parts.zt)
    local function tri(sm, a, b, c, n)
        local i = #sm.verts
        if (b.p - a.p):cross(c.p - a.p):dot(n) > 0 then b, c = c, b end
        for k, q in ipairs({a, b, c}) do
            sm.verts[i + k], sm.normals[i + k], sm.uvs[i + k] = q.p, q.n or n, {u = q.u, v = q.v}
            sm.faces[#sm.faces + 1]                           = {v = i + k - 1, n = i + k - 1, u = i + k - 1}
        end
    end
    local function edge(st, d) return st.edge and st.edge(d) or (vec3(st.at.x, st.at.y, 0) + st.n * d) end
    local function pt(st, q, u, v) local e = edge(st, q.d) return {p = vec3(e.x, e.y, q.z), u = u, v = v} end
    local run = 0.0
    for k = 1, #rim - 1 do
        local A, B = rim[k], rim[k + 1]
        local u0   = run
        run        = run + (flat(B.at) - flat(A.at)):length()
        local nA   = (A.n + B.n):normalized()
        local v    = 0.0
        for j = 1, #sec - 1 do
            local p, q = sec[j], sec[j + 1]
            local n    = (nA * (q.z - p.z) - vec3(0, 0, q.d - p.d)):normalized()
            local away = nA * ((p.d + q.d - din - dout) / 2.0) + vec3(0, 0, (p.z + q.z - sec[1].z - sec[#sec].z) / 2.0)
            if n:dot(away) < 0 then n = n * -1.0 end
            local l    = math.sqrt((q.d - p.d) ^ 2 + (q.z - p.z) ^ 2)
            local sm   = sides[p.way]
            local a, b = pt(A, p, u0, v), pt(B, p, run, v)
            local c, d = pt(B, q, run, v + l), pt(A, q, u0, v + l)
            tri(sm, a, b, c, n)
            tri(sm, a, c, d, n)
            v = v + l
        end
    end
    for e, st in ipairs({rim[1], rim[#rim]}) do
        local other = (e == 1) and rim[2] or rim[#rim - 1]
        local n     = flat(st.at - other.at):normalized()
        local hub   = pt(st, {d = (din + dout) / 2.0, z = (sec[1].z + sec[#sec].z) / 2.0}, (din + dout) / 2.0, 0.0)
        for j = 1, #sec do
            local p, q = sec[j], sec[j % #sec + 1]
            tri(sides.side, hub, pt(st, p, p.d, p.z), pt(st, q, q.d, q.z), n)
        end
    end
    for _, way in ipairs({"top", "bottom", "side"}) do
        local sm   = sides[way]
        local pick = m.sides and m[way]
        if pick and ctx.tileOf then
            local mat, su, sv, st = ctx.tileOf(pick)
            if mat then retexture(sm, mat, su, sv, nil, st) end
            sm.module = nil
        end
        out[#out + 1] = sm
    end
end

local function band(out, md, m, key, fs, ops, on, raise, fit, ctx, front)
    local every = Window.modValue(m, "every")
    local function shape(src, row, e, run)
        local wide    = Window.modValue(e or m, "wide")
        local W0      = Modules.size(src.path)
        local a, d, o = Modules.axes(src, W0)
        local W       = (wide > 0 and wide) or (fit and fit(row, run)) or nil
        return {src = src, a = a, d = d, o = o, W0 = W0, span = W or W0 or (src.hi[a] - src.lo[a])}
    end
    for _, face in ipairs(faceKeys) do
        local count, rows, order, nb = {}, {}, {}, 0
        local f                      = fs[face]
        local bent                   = f and curved(f)
        local lead                   = nil
        for _, w in ipairs(rules[key].doors and ops[face] or {}) do
            local r = w.pl.row
            if not r.at and (not lead or r.sill < lead.sill) then lead = r end
        end
        for _, w in ipairs(ops[face]) do
            local r      = w.pl.row
            local bucket = (not r.at) and r or (rules[key].doors and (lead or r)) or nil
            if bucket and on(key, face) then
                local n       = (count[bucket] or 0) + 1
                count[bucket] = n
                if (n - 1) % every == 0 then
                    if not rows[bucket] then
                        rows[bucket]      = {}
                        order[#order + 1] = bucket
                    end
                    table.insert(rows[bucket], w.pl)
                end
            end
        end
        for _, row in ipairs(order) do
            local own  = shape(md, row)
            local span = own.span
            local list = rows[row]
            local n0   = vec3(-list[1].inward.x, -list[1].inward.y, 0)
            local u    = vec3(-n0.y, n0.x, 0)
            table.sort(list, function(p, q) return p.origin:dot(u) < q.origin:dot(u) end)
            local runs = {{list[1]}}
            for k = 2, #list do
                local cur = runs[#runs]
                if (list[k].origin - cur[#cur].origin):dot(u) <= span + 1e-3 then cur[#cur + 1] = list[k] else runs[#runs + 1] = {list[k]} end
            end
            for _, run in ipairs(runs) do
                nb                = nb + 1
                local slot        = face .. "|" .. nb
                local st          = slotOf(m, md, slot) or {mv = {off = true}, es = ownOf(m, m, slot), look = md, away = 0.0, lift = 0.0}
                local mv, es      = st.mv, st.es
                local sh          = shape(st.look, row, es, run)
                local away, lift  = st.away, st.lift
                local first, last = run[1].origin, run[#run].origin
                local sa, sb      = project(f, first), project(f, last)
                if sa > sb then sa, sb = sb, sa end
                local zb = first.z
                for _, pl in ipairs(rules[key].doors and run or {}) do zb = math.min(zb, pl.origin.z) end
                local len    = bent and (sb - sa + sh.span) or ((last - first):dot(u) + sh.span)
                local extra  = math.max(0.0, away)
                local from   = #out + 1
                local ds     = mv.s or 0.0
                local z0     = zb + raise(row, run) + lift + (mv.z or 0.0)
                local parts  = (not mv.off) and key == "balcony" and Modules.split(sh.src) or nil
                local centre = (first + last) * 0.5 + u * ds
                local tu, tn = u, n0
                if key == "awning" then
                    local push = 0.0
                    for _, pl in ipairs(run) do push = math.max(push, pl.push or 0.0) end
                    local hit = front and not bent and front(face, sa + ds - sh.span / 2.0, sb + ds + sh.span / 2.0, z0 + sh.src.lo.z, z0 + sh.src.hi.z, (sa + sb) / 2.0 + ds)
                    if hit and hit.off > push then push = hit.off end
                    centre = centre + n0 * push
                    if #run == 1 and run[1].facing then
                        tn     = run[1].facing
                        tu     = vec3(-tn.y, tn.x, 0)
                        centre = vec3(run[1].front.x, run[1].front.y, centre.z) + tu * ds
                    end
                end
                local t      = wallT(sh.src, sh.W0, vec3(centre.x, centre.y, first.z) + tn * math.min(0.0, away), tu, tn, z0, "raw", true)
                if bent and not mv.off then
                    local _, _, tu, tn = frameAt(f, (sa + sb) / 2.0)
                    local turn         = (tu:dot(u) >= 0) and 1 or -1
                    local mid          = (sa + sb) / 2.0 + turn * ds
                    local s0, s1       = mid - len / 2.0, mid + len / 2.0
                    if not parts then
                        local whole = Modules.join(Modules.tile(sh.src, sh.a, sh.d, sh.o, len, extra), sh.a, sh.d)
                        bend(out, whole, len, len, f, s0, s1, function() return z0 end, true)
                    else
                        local probe     = wallT(sh.src, sh.W0, vec3(0, 0, 0), tu * turn, tn, 0.0, "raw", true)
                        local dir       = (((sh.a == "x") and probe.x or probe.y):dot(tu) >= 0) and 1 or -1
                        local din, hi   = reach(parts.floor, sh.o, sh.d)
                        local _, rhi    = reach(parts.rail, sh.o, sh.d)
                        local lout, sAt = outerLine(f, s0, s1, rhi + extra)
                        local railFrom  = #out + 1
                        for _, piece in ipairs(Modules.tile(parts.rail, sh.a, sh.d, sh.o, lout, extra)) do
                            local whole        = piece.m == parts.rail
                            local e0, e1       = whole and sh.src.lo[sh.a] or piece.a.c0, whole and sh.src.hi[sh.a] or piece.a.c1
                            local c            = (e0 + e1) / 2.0
                            local p, pu, pn    = chordAt(f, sAt, lout / 2.0 + dir * e0, lout / 2.0 + dir * e1, rhi + extra)
                            if not p then p, pu, pn = bendAt(f, math.max(0.0, math.min(f.len, sAt(lout / 2.0 + dir * c))), function(z) return z end) end
                            local rt           = wallT(sh.src, sh.W0, p, pu * turn, pn, z0, "raw", true)
                            local shifted      = {m = piece.m, a = {s0 = piece.a.s0, s1 = piece.a.s1, c0 = piece.a.c0 - c, c1 = piece.a.c1 - c}, d = piece.d}
                            emit(out, piece.m, Modules.fit(rt, shifted, sh.a, sh.d))
                        end
                        for j = railFrom, #out do out[j].inst = nil end
                        local rim  = {}
                        local cuts = bends(f, s0, s1)
                        table.insert(cuts, 1, s0)
                        cuts[#cuts + 1] = s1
                        for _, sv in ipairs(cuts) do
                            local p, _, w = bendAt(f, sv, function(z) return z end)
                            rim[#rim + 1] = {at = p, n = w, edge = function(dd) return offsetAt(f, sv, p, w, dd) end}
                        end
                        slab(out, es, parts, rim, din, hi + extra, z0, ctx)
                    end
                elseif parts then
                    local railFrom = #out + 1
                    for _, piece in ipairs(Modules.tile(parts.rail, sh.a, sh.d, sh.o, len, extra)) do merge(out, piece.m, Modules.fit(t, piece, sh.a, sh.d)) end
                    for j = railFrom, #out do out[j].inst = nil end
                    local din, hi = reach(parts.floor, sh.o, sh.d)
                    local base    = vec3(centre.x, centre.y, 0) + n0 * math.min(0.0, away)
                    slab(out, es, parts, {{at = base - u * (len / 2.0), n = n0}, {at = base + u * (len / 2.0), n = n0}}, din, hi + extra, z0, ctx)
                elseif not mv.off then
                    for _, piece in ipairs(Modules.tile(sh.src, sh.a, sh.d, sh.o, len, extra)) do emit(out, piece.m, Modules.fit(t, piece, sh.a, sh.d)) end
                end
                for j = from, #out do
                    local sm         = out[j]
                    sm.slot, sm.fi   = slot, key
                    sm.along, sm.out = u, n0
                end
            end
        end
    end
end

local function stand(p, n, z, front)
    local y = front and front.n or n
    return {o = vec3(p.x, p.y, z) + n * (front and front.off or 0.0) - y * inset, x = y:cross(vec3(0, 0, 1)), y = y, z = vec3(0, 0, 1), pv = vec3(0, 0, 0)}
end

local function tagSlot(out, from, slot, key, u, n)
    for j = from, #out do
        local sm                = out[j]
        sm.kind, sm.slot, sm.fi = key, slot, key
        sm.along, sm.out        = u, n
    end
end

local function anchors(key, m, ops, face)
    local list = {}
    if rules[key].anchor == "doors" then
        for _, w in ipairs(ops[face]) do
            if w.pl.row.at then list[#list + 1] = {w = w, slot = face .. "|" .. (#list + 1)} end
        end
        return list
    end
    local every    = Window.modValue(m, "every")
    local count, k = {}, 0
    for _, w in ipairs(ops[face]) do
        local row = w.pl.row
        if not row.at then
            local n    = (count[row] or 0) + 1
            count[row] = n
            if (n - 1) % every == 0 then
                k               = k + 1
                list[#list + 1] = {w = w, slot = face .. "|" .. k}
            end
        end
    end
    return list
end

local function pots(out, md, m, fs, on)
    local step  = Window.modValue(m, "step")
    local half  = math.max(-md.lo.x, md.hi.x)
    local taken = {}
    local function free(q)
        for _, o in ipairs(taken) do
            if flat(o - q):length() < 2.0 * half then return false end
        end
        taken[#taken + 1] = q
        return true
    end
    for _, face in ipairs(faceKeys) do
        local f = fs[face]
        if f and on("pots", face) and f.len >= 2.0 * half then
            local run = f.len - 2.0 * half
            local n   = math.floor(run / step + 1e-9) + 1
            for k = 1, n do
                local slot = face .. "|" .. k
                local st   = slotOf(m, md, slot)
                if st then
                    local s            = (n == 1) and f.len / 2.0 or (half + (k - 1) * run / (n - 1))
                    s                  = math.max(half, math.min(f.len - half, s + st.ds))
                    local p, top, u, w = frameAt(f, s)
                    local from         = #out + 1
                    if free(p - w * rules.pots.inward) then
                        emit(out, st.look, stand(p - w * rules.pots.inward, w, top))
                        tagSlot(out, from, slot, "pots", u, w)
                    end
                end
            end
        end
    end
end

local function topAt(fs, q)
    local best, bz = math.huge, q.z
    for _, face in ipairs(faceKeys) do
        local f = fs[face]
        if f then
            local p, top = at(f, project(f, q))
            local d      = flat(p - q):length()
            if d < best then best, bz = d, top end
        end
    end
    return bz
end

local function onTop(out, md, m, key, fs, frame)
    local slot = "top|1"
    local st   = slotOf(m, md, slot)
    if not st then return end
    local side = vec3(-frame.ax.y, frame.ax.x, 0)
    local c    = frame.o + frame.ax * (frame.len * rules[key].share + st.ds) + side * (st.mv.v or 0.0)
    local from = #out + 1
    emit(out, st.look, {o = vec3(c.x, c.y, topAt(fs, c)), x = frame.ax, y = side, z = vec3(0, 0, 1), pv = vec3(0, 0, 0)})
    tagSlot(out, from, slot, key, frame.ax, side)
end

local function corbels(out, md, m, fs, under, on)
    local step = Window.modValue(m, "step")
    local poly = under[1].poly
    for _, face in ipairs(faceKeys) do
        local f = fs[face]
        if f and on("corbel", face) then
            local n      = math.max(1, math.floor(f.len / step + 0.5))
            local lo, hi = rules.corbel.reach[1], rules.corbel.reach[2]
            for k = 1, n do
                local slot = face .. "|" .. k
                local st   = slotOf(m, md, slot)
                if st then
                    local p, _, _, w = frameAt(f, math.max(0.0, math.min(f.len, f.len * (k - 0.5) / n + st.ds)))
                    local d          = 0.0
                    while d <= hi and not C.inPoly(poly, p - w * d) do d = d + corbelStep end
                    if d >= lo and d <= hi then
                        local t    = stand(p - w * (d - inset), w, p.z - st.look.hi.z + st.dz)
                        local from = #out + 1
                        t.sy       = d / math.max(1e-6, st.look.hi.y)
                        emit(out, st.look, t)
                        tagSlot(out, from, slot, "corbel", horiz(vec3(w.y, -w.x, 0)), w)
                    end
                end
            end
        end
    end
end

-- =============================================================================
-- TRIMS
-- =============================================================================

local function keepZ(z) return z end

local function frameOf(f, s)
    local p, top = at(f, s)
    if curved(f) then
        local _, u, n = bendAt(f, s, keepZ)
        return p, top, u, n, true
    end
    local _, _, u, n = frameAt(f, s)
    return p, top, u, n, false
end

local function endNormal(f, e)
    local _, _, _, n = frameOf(f, (e == 0) and 0.0 or f.len)
    return n
end

local function links(fs)
    local out = {}
    for _, a in ipairs(faceKeys) do
        local fa = fs[a]
        for ea = 0, 1 do
            local pa = fa and fa.pts[(ea == 0) and 1 or #fa.pts]
            for _, b in ipairs(fa and faceKeys or {}) do
                local fb = fs[b]
                for eb = 0, 1 do
                    local pb = fb and b ~= a and fb.pts[(eb == 0) and 1 or #fb.pts]
                    if pb and flat(pa - pb):length() < 1e-3 then out[a .. ea] = {face = b, e = eb} end
                end
            end
        end
    end
    return out
end

local function sizeOf(e, m, field, base)
    local v = Window.modValue(e, field)
    if v <= 0 and e ~= m then v = Window.modValue(m, field) end
    return (v > 0 and base > 1e-6) and v / base or 1.0
end

local function entries(m)
    local list = {m}
    for _, e in ipairs(m.more or {}) do list[#list + 1] = e end
    return list
end


local function shapeOf(e, a, b, D)
    local L      = b - a
    local arc    = e.bay == "arc"
    local tA, tB = Window.modValue(e, "taperA"), Window.modValue(e, "taperB")
    if (not arc and tA <= 0 and tB <= 0) or L < minFace or D <= 1e-6 then return nil end
    local sh = {a = a, b = b, D = D, cuts = {}, breaks = {}}
    if arc then
        local c       = L / 2.0 * (1.0 + Window.modValue(e, "peak"))
        local bul, fl = Window.modValue(e, "bulge"), Window.modValue(e, "flatten")
        sh.k = function(sv)
            local t    = sv - a
            local h    = (t < c) and c or (L - c)
            local x    = math.min(1.0, math.abs(t - c) / math.max(h, 1e-9))
            local R    = (h * h + D * D) / (2.0 * D)
            local circ = (math.sqrt(math.max(0.0, R * R - (x * h) ^ 2)) - (R - D)) / D
            local ell  = math.sqrt(math.max(0.0, 1.0 - x * x))
            local v    = math.max(0.0, math.min(1.0, circ + (ell - circ) * bul))
            return 1.0 - (1.0 - v) ^ (1.0 + 3.0 * fl)
        end
        local n = math.max(arcMin, math.ceil(L / arcStep))
        for i = 1, n - 1 do sh.cuts[#sh.cuts + 1] = a + L * i / n end
        sh.cuts[#sh.cuts + 1] = a + c
        return sh
    end
    if tA + tB > L then
        local q = L / (tA + tB)
        tA, tB  = tA * q, tB * q
    end
    sh.k = function(sv)
        local t, k = sv - a, 1.0
        if tA > 0 then k = math.min(k, t / tA) end
        if tB > 0 then k = math.min(k, (L - t) / tB) end
        return math.max(0.0, math.min(1.0, k))
    end
    for _, t in ipairs({tA, L - tB}) do
        if t > 1e-6 and t < L - 1e-6 and (#sh.breaks == 0 or math.abs(sh.breaks[1] - (a + t)) > 1e-6) then sh.breaks[#sh.breaks + 1] = a + t end
    end
    for _, sk in ipairs(sh.breaks) do sh.cuts[#sh.cuts + 1] = sk end
    return sh
end

local function slopes(sh, sv)
    local ep    = 1e-4
    local k0    = sh.k(sv)
    local left  = (sv - ep >= sh.a) and (k0 - sh.k(sv - ep)) / ep or nil
    local right = (sv + ep <= sh.b) and (sh.k(sv + ep) - k0) / ep or nil
    return left or right or 0.0, right or left or 0.0
end

local function frontAt(f, e, sv)
    local _, _, u, n = frameOf(f, sv)
    local sh         = e.sh
    if not sh then return e.d - inset, n end
    local l, r = slopes(sh, math.max(sh.a, math.min(sh.b, sv)))
    return sh.D * sh.k(math.max(sh.a, math.min(sh.b, sv))) - inset, (n - u * (sh.D * (l + r) / 2.0)):normalized()
end

local function frontPt(f, sh, sv)
    local p, _, _, n = frameOf(f, sv)
    return flat(p) + n * (sh.D * sh.k(sv) - inset)
end

local function seat(f, sh, sc, half)
    local function chord(h) return (frontPt(f, sh, sc + h) - frontPt(f, sh, sc - h)):length() end
    local lo, hi = 0.0, half
    if sc - hi < sh.a - 1e-6 or sc + hi > sh.b + 1e-6 or chord(hi) < 2.0 * half then hi = math.min(sc - sh.a, sh.b - sc) end
    if hi <= 0.0 or chord(hi) < 2.0 * half - 1e-4 then return nil end
    for _ = 1, 40 do
        local m = (lo + hi) / 2.0
        if chord(m) < 2.0 * half then lo = m else hi = m end
    end
    local h = hi
    if sc - h < sh.a + 1e-3 or sc + h > sh.b - 1e-3 then return nil end
    if sh.D * math.min(sh.k(sc - h), sh.k(sc + h)) < inset + seatGap then return nil end
    local A, B       = frontPt(f, sh, sc - h), frontPt(f, sh, sc + h)
    local _, _, _, n = frameOf(f, sc)
    local d          = horiz(B - A)
    local fc         = vec3(d.y, -d.x, 0)
    if fc:dot(n) < 0 then fc = fc * -1.0 end
    return h, (A + B) * 0.5, fc
end

local function holeFor(f, w, a, b, d, sh)
    if not sh then
        local lo, hi = w.s - w.half, w.s + w.half
        if lo < a + 1e-3 or hi > b - 1e-3 then return nil end
        return lo, hi, function() w.pl.push = math.max(w.pl.push or 0.0, d - inset) end
    end
    local h, mid, fc = seat(f, sh, w.s, w.half)
    if not h or w.s - h < a + 1e-3 or w.s + h > b - 1e-3 then return nil end
    return w.s - h, w.s + h, function() w.pl.front, w.pl.facing = vec3(mid.x, mid.y, w.pl.origin.z), fc end
end

local function note(foot, face, e)
    if not foot then return end
    foot[face]                  = foot[face] or {}
    foot[face][#foot[face] + 1] = e
end

local function cover(f, ops, zOf, h, d, a, b, flatFront, sh)
    local gaps, holes = {}, {}
    for _, w in ipairs(ops) do
        local lo, hi = w.s - w.half, w.s + w.half
        if hi > a and lo < b then
            local p, top = at(f, w.s)
            local zb     = zOf(p.z, top)
            local zo, zt = w.pl.origin.z, w.pl.origin.z + (w.pl.height or w.pl.row.height)
            if zt > zb + 1e-3 and zo < zb + h - 1e-3 then
                local ha, hb, apply = nil, nil, nil
                if flatFront and zo >= zb + 1e-3 and zt <= zb + h - 1e-3 then ha, hb, apply = holeFor(f, w, a, b, d, sh) end
                if ha then
                    apply()
                    holes[#holes + 1] = {ha, hb, zo - zb, zt - zb}
                else
                    gaps[#gaps + 1] = {lo - clear, hi + clear}
                end
            end
        end
    end
    return gaps, holes
end

local function hitAlong(o, n, A, B)
    local e   = B - A
    local den = n.x * e.y - n.y * e.x
    if math.abs(den) < 1e-12 then return nil end
    local w = A - o
    local t = (w.x * e.y - w.y * e.x) / den
    local u = (w.x * n.y - w.y * n.x) / den
    if t > 1e-4 and u >= 0.0 and u <= 1.0 then return t end
    return nil
end

local function pockets(f, d)
    local out, P = {}, f.pts
    for k = 2, #P - 1 do
        if horiz(P[k] - P[k - 1]):dot(horiz(P[k + 1] - P[k])) < 0.0 then
            local lo, hi = f.s[k], f.s[k]
            local n      = math.max(1, math.ceil(f.len / corbelStep))
            for i = 0, n do
                local sv     = f.len * i / n
                local j0     = seg(f, sv)
                local nrm    = outward(horiz(P[j0 + 1] - P[j0]), P[j0], f.inner[j0])
                local from   = (sv < f.s[k]) and k or 1
                local to     = (sv < f.s[k]) and #P or k
                local room   = math.huge
                for j = from, to - 1 do
                    local t = hitAlong(flat(at(f, sv)), nrm, flat(P[j]), flat(P[j + 1]))
                    if t then room = math.min(room, t) end
                end
                if room < d + clear then lo, hi = math.min(lo, sv), math.max(hi, sv) end
            end
            out[#out + 1] = {math.max(0.0, lo - corbelStep), math.min(f.len, hi + corbelStep)}
        end
    end
    return out
end

local function grates(f, prof, e, a, b, kx)
    local out  = {}
    local step = Window.modValue(e, "grate")
    if not prof.grate or step <= 0 then return out end
    local W    = (prof.grate.to - prof.grate.from) * kx
    local run  = b - a
    local n    = math.floor(run / step + 0.5)
    if n > 0 and run / n < W + 2.0 * minFace then n = math.floor(run / (W + 2.0 * minFace)) end
    for k = 0, n - 1 do
        local c                = a + run * (k + 0.5) / n
        local _, _, ua         = frameAt(f, c - W / 2.0)
        local _, _, ub         = frameAt(f, c + W / 2.0)
        if ua:dot(ub) > 0.98 and flat(at(f, c + W / 2.0) - at(f, c - W / 2.0)):length() > W * 0.99 then
            out[#out + 1] = {c - W / 2.0, c + W / 2.0, grate = true, c = c}
        end
    end
    return out
end

local function stationsOf(f, prof, a, b, zOf, ends, cuts, sh)
    local list = {a}
    for _, sk in ipairs(bends(f, a, b)) do list[#list + 1] = sk end
    for _, sk in ipairs(cuts or {}) do
        if sk > a + 1e-6 and sk < b - 1e-6 then list[#list + 1] = sk end
    end
    for _, sk in ipairs(sh and sh.cuts or {}) do
        if sk > a + 1e-6 and sk < b - 1e-6 then list[#list + 1] = sk end
    end
    table.sort(list)
    local uniq = {}
    for _, sk in ipairs(list) do
        if #uniq == 0 or sk - uniq[#uniq] > 1e-6 then uniq[#uniq + 1] = sk end
    end
    list            = uniq
    list[#list + 1] = b
    local tiles = nil
    if not prof.wrap then
        local n = math.max(1, math.floor((b - a) / prof.len + 0.5))
        tiles   = {n = n, T = (b - a) / n}
        local k = 1
        for j = 1, n - 1 do
            local sv = a + tiles.T * j
            while k < #list and list[k + 1] < sv - 1e-6 do k = k + 1 end
            if math.abs(list[k] - sv) > 1e-6 and math.abs((list[k + 1] or b) - sv) > 1e-6 then table.insert(list, k + 1, sv) end
        end
    end
    local sts = {}
    for i, sv in ipairs(list) do
        local p, top, u, n, bent = frameOf(f, sv)
        local st = {p = p, n = n, s = sv, z = zOf(p.z, top)}
        if sh then
            local l, r = slopes(sh, sv)
            st.k       = sh.k(sv)
            st.fa      = (n - u * (sh.D * l)):normalized()
            st.fb      = (n - u * (sh.D * r)):normalized()
        end
        local m    = (i == 1 and ends[1]) or (i == #list and ends[2]) or nil
        local edge
        if m then
            edge = function(d) return p + m * (d - inset) end
        elseif bent then
            local k, t = seg(f, sv)
            local j    = (t < 1e-6) and k or (t > 1.0 - 1e-6) and (k + 1) or nil
            local mit  = nil
            if j and j > 1 and j < #f.pts then
                local n1 = outward(horiz(f.pts[j] - f.pts[j - 1]), f.pts[j], f.inner[j])
                local n2 = outward(horiz(f.pts[j + 1] - f.pts[j]), f.pts[j], f.inner[j])
                if n1:dot(n2) < bendDot then mit = (n1 + n2) * (1.0 / math.max(0.2, 1.0 + n1:dot(n2))) end
            end
            edge = function(d)
                if mit and not folds(f, d - inset) then return p + mit * (d - inset) end
                return offsetAt(f, sv, p, n, d - inset)
            end
        else
            edge = function(d) return p + n * (d - inset) end
        end
        st.edge = edge
        if tiles then
            local x   = (sv - a) / tiles.T
            local j   = math.floor(x + 1e-6)
            local r   = x - j
            st.x0     = ((r < 1e-6) and 0.0 or r) * prof.len
            st.x1     = ((r < 1e-6 and i > 1) and 1.0 or r) * prof.len
        end
        sts[#sts + 1] = st
    end
    return sts
end

local function paint(out, from, m, key, ctx)
    for k = from, #out do
        local sm   = out[k]
        local pick = m.sides and m[sm.way]
        if key == "roofborder" and ctx.roofMat and m.skin then
            retexture(sm, ctx.roofMat, ctx.roofTile[1], ctx.roofTile[2], ctx.roofTile[3], ctx.roofTile[4])
        elseif pick and ctx.tileOf then
            local mat, su, sv, st = ctx.tileOf(pick)
            if mat then
                retexture(sm, mat, su, sv, nil, st)
                sm.module = nil
            end
        end
        sm.way = nil
    end
end

local function flatSweep(bk, f, prof, r, zOf, ends, caps, holes, kd, kz, sh)
    local hs = {}
    for _, hl in ipairs(holes) do
        if hl[1] > r[1] and hl[2] < r[2] then hs[#hs + 1] = hl end
    end
    if #hs == 0 then
        Trims.sweep(bk, prof, stationsOf(f, prof, r[1], r[2], zOf, ends, nil, sh), {kd = kd, kz = kz, capA = caps[1], capB = caps[2]})
        return
    end
    table.sort(hs, function(x, y) return x[1] < y[1] end)
    local cuts, zs = {}, {}
    for _, hl in ipairs(hs) do
        cuts[#cuts + 1], cuts[#cuts + 2] = hl[1], hl[2]
        zs[#zs + 1], zs[#zs + 2]         = hl[3] / kz, hl[4] / kz
    end
    local front = Trims.holeOf(prof, nil, nil, zs)
    local o     = {kd = kd, kz = kz, s0 = r[1]}
    local sts   = stationsOf(f, prof, r[1], r[2], zOf, ends, cuts, sh)
    local rim   = {len = prof.len, wrap = true, d = prof.d, h = prof.h, segs = {prof.segs[1], prof.segs[3]}}
    for _, g in ipairs(front.segs) do rim.segs[#rim.segs + 1] = g end
    Trims.sweep(bk, prof, sts, {kd = kd, kz = kz, s0 = r[1], only = {[1] = true, [3] = true}})
    Trims.sweep(bk, rim, sts, {kd = kd, kz = kz, s0 = r[1], capA = caps[1], capB = caps[2], only = {}})
    local from = r[1]
    for q = 1, #hs + 1 do
        local to = hs[q] and hs[q][1] or r[2]
        if to - from > 1e-6 then
            local se = {(from == r[1]) and ends[1] or nil, (to == r[2]) and ends[2] or nil}
            Trims.sweep(bk, front, stationsOf(f, prof, from, to, zOf, se, nil, sh), o)
        end
        local hl = hs[q]
        if hl then
            local sts = stationsOf(f, prof, hl[1], hl[2], zOf, {}, nil, sh)
            Trims.sweep(bk, Trims.holeOf(prof, hl[3] / kz, hl[4] / kz, zs), sts, o)
            local u = horiz(sts[#sts].p - sts[1].p)
            Trims.reveal(bk, prof, sts[1], hl[3] / kz, hl[4] / kz, u, kd, kz)
            Trims.reveal(bk, prof, sts[#sts], hl[3] / kz, hl[4] / kz, u * -1.0, kd, kz)
            from = hl[2]
        end
    end
end

local function trimLines(out, cfg, key, fs, ops, on, ctx, foot)
    local m = Window.modOf(cfg, key)
    if not m then return end
    local link = links(fs)
    for ei, e in ipairs(entries(m)) do
        local count = math.max(1, math.floor(Window.modValue(e, "count") + 0.5))
        for j = 0, count - 1 do
            local plan = {}
            for _, face in ipairs(faceKeys) do
                local f = fs[face]
                if f and on(key, face) then
                    local slot = face .. "|" .. ((ei - 1) * 50 + j + 1)
                    local mv   = m.moves and m.moves[slot] or {}
                    local es   = ownOf(m, e, slot)
                    if not mv.off then
                        local prof   = Trims.of(key, es.dae or e.dae or m.dae)
                        local kd, kz = sizeOf(es, m, "deep", prof.d), sizeOf(es, m, "tall", prof.h)
                        local h, d   = prof.h * kz, prof.d * kd
                        local dz     = Window.modValue(es, "lift") + j * Window.modValue(e, "space") + (mv.z or 0.0)
                        local top    = key == "roofborder"
                        local zOf    = function(z, t) return (top and t or z) + dz end
                        local ds = mv.s or 0.0
                        local a  = math.max(0.0, math.min(f.len, Window.modValue(es, "from") + ds))
                        local b  = math.max(0.0, math.min(f.len, f.len - Window.modValue(es, "to") + ds))
                        if b - a >= minFace then
                            local sh          = prof.flat and shapeOf(es, a, b, d) or nil
                            local gaps, holes = cover(f, ops[face], zOf, h, d, a, b, prof.flat, sh)
                            gaps[#gaps + 1] = {-1.0, a}
                            gaps[#gaps + 1] = {b, f.len + 1.0}
                            for _, g in ipairs(pockets(f, d)) do gaps[#gaps + 1] = g end
                            table.sort(gaps, function(x, y) return x[1] < y[1] end)
                            local list, per, all = runs(f, gaps), {}, {}
                            for i, r in ipairs(list) do
                                per[i] = grates(f, prof, es, r[1], r[2], 1.0)
                                for _, g in ipairs(per[i]) do all[#all + 1] = g end
                            end
                            plan[face] = {f = f, zOf = zOf, slot = slot, dz = dz, runs = list, grates = per, all = all, holes = holes, sh = sh, prof = prof,
                                          kd = kd, kz = kz, h = h, d = d}
                        end
                    end
                end
            end
            local function kAt(face, e2)
                local pl = plan[face]
                return pl.sh and pl.sh.k((e2 == 0) and 0.0 or pl.f.len) or 1.0
            end
            local function touches(face, e2)
                local pl = plan[face]
                if not pl then return false end
                for _, r in ipairs(pl.runs) do
                    if (e2 == 0 and r[1] <= 1e-6) or (e2 == 1 and r[2] >= pl.f.len - 1e-6) then return true end
                end
                return false
            end
            for _, face in ipairs(faceKeys) do
                local pl = plan[face]
                if pl then
                    local bk                 = {}
                    local f                  = pl.f
                    local prof, kd, kz, h, d = pl.prof, pl.kd, pl.kz, pl.h, pl.d
                    for i, r in ipairs(pl.runs) do
                        local ends, caps = {}, {true, true}
                        for k, e2 in ipairs({0, 1}) do
                            local sv = (k == 1) and r[1] or r[2]
                            local lk = link[face .. e2]
                            if ((e2 == 0 and sv <= 1e-6) or (e2 == 1 and sv >= f.len - 1e-6)) and lk and plan[lk.face]
                               and math.abs(plan[lk.face].dz - pl.dz) < 1e-6 and touches(lk.face, lk.e) and math.abs(kAt(face, e2) - kAt(lk.face, lk.e)) < 1e-3
                               and plan[lk.face].prof == pl.prof and math.abs(plan[lk.face].kd - pl.kd) < 1e-6 and math.abs(plan[lk.face].kz - pl.kz) < 1e-6 then
                                local n1, n2 = endNormal(f, e2), endNormal(fs[lk.face], lk.e)
                                ends[k]      = (n1 + n2) * (1.0 / math.max(0.2, 1.0 + n1:dot(n2)))
                                caps[k]      = false
                            end
                        end
                        local gs       = pl.grates[i]
                        local pm, ptop = at(f, (r[1] + r[2]) / 2.0)
                        local zb       = pl.zOf(pm.z, ptop)
                        note(foot, face, {a = r[1], b = r[2], z0 = zb, z1 = zb + h, d = d, flat = prof.flat, key = key, sh = pl.sh})
                        if #gs == 0 then
                            flatSweep(bk, f, prof, r, pl.zOf, ends, caps, pl.holes, kd, kz, pl.sh)
                        else
                            local through, rest = {}, {}
                            for q = 1, #prof.segs do rest[q] = true end
                            for _, q in ipairs(prof.grate.through) do through[q], rest[q] = true, nil end
                            Trims.sweep(bk, prof, stationsOf(f, prof, r[1], r[2], pl.zOf, ends), {kd = kd, kz = kz, capA = caps[1], capB = caps[2], only = through})
                            local from = r[1]
                            for q = 1, #gs + 1 do
                                local to = gs[q] and gs[q][1] or r[2]
                                if to - from > 1e-6 then
                                    local se = {(from == r[1]) and ends[1] or nil, (to == r[2]) and ends[2] or nil}
                                    Trims.sweep(bk, prof, stationsOf(f, prof, from, to, pl.zOf, se), {kd = kd, kz = kz, only = rest})
                                end
                                from = gs[q] and gs[q][2] or r[2]
                            end
                        end
                    end
                    for _, g in ipairs(pl.all) do
                        local A, B     = at(f, g[1]), at(f, g[2])
                        local u        = horiz(B - A)
                        local p, top   = at(f, g.c)
                        local _, _, _, w = frameOf(f, g.c)
                        local n        = (w - u * w:dot(u)):normalized()
                        local mid      = (A + B) * 0.5
                        Trims.grate(bk, prof, vec3(mid.x, mid.y, pl.zOf(p.z, top)) - n * inset, u, n, kd, kz, 1.0, u:cross(n * -1.0):dot(vec3(0, 0, 1)) < 0)
                    end
                    local from = #out + 1
                    Trims.flush(out, bk)
                    local _, _, u, n = frameOf(f, f.len / 2.0)
                    tagSlot(out, from, pl.slot, key, u, n)
                    paint(out, from, ownOf(m, m, pl.slot), key, ctx)
                end
            end
        end
    end
end

local function flatHoles(list, A, B, z0, z1, gaps, d)
    local dir = vec3(B.x - A.x, B.y - A.y, 0)
    local L   = dir:length()
    local out = {}
    if L < 1e-6 then return out end
    dir = dir * (1.0 / L)
    for _, w in ipairs(list or {}) do
        local pl  = w.pl
        local nf  = horiz(pl.inward) * -1.0
        local par = math.abs(dir:dot(nf)) < 1e-3
        if math.abs(dir:dot(nf)) < 0.9 then
            local t0, t1
            if par then
                local ta = flat(pl.origin - pl.along * w.half - A):dot(dir)
                local tb = flat(pl.origin + pl.along * w.half - A):dot(dir)
                t0, t1   = math.min(ta, tb), math.max(ta, tb)
            else
                local q  = flat(pl.origin - A)
                local tc = (q.x * nf.y - q.y * nf.x) / (dir.x * nf.y - dir.y * nf.x)
                t0, t1   = tc - w.half, tc + w.half
            end
            local zo, zt = pl.origin.z, pl.origin.z + (pl.height or pl.row.height)
            if t1 > 0.0 and t0 < L and zt > z0 and zo < z1 then
                if t0 >= 1e-3 and t1 <= L - 1e-3 and zo >= z0 + 1e-3 and zt <= z1 - 1e-3 then
                    if par then
                        pl.push = math.max(pl.push or 0.0, d - inset)
                    else
                        local c  = A + dir * ((t0 + t1) / 2.0)
                        local fc = vec3(dir.y, -dir.x, 0)
                        if fc:dot(nf) < 0 then fc = fc * -1.0 end
                        pl.front, pl.facing = vec3(c.x, c.y, zo), fc
                    end
                    out[#out + 1] = {t0, t1, zo, zt}
                else
                    gaps[#gaps + 1] = {zo - clear, zt + clear}
                end
            end
        end
    end
    return out
end

local function armK(t, A, T, arc)
    if t <= A - T then return 1.0 end
    local u = math.min(1.0, (t - (A - T)) / math.max(T, 1e-9))
    return arc and math.sqrt(math.max(0.0, 1.0 - u * u)) or (1.0 - u)
end

local function cornerPts(c, A, out, T, arc)
    if T <= 1e-6 and not arc then return Trims.outline(c, A, A, out, 0.0), 3 end
    if T <= 1e-6 or T > A then T = A end
    local mit = (c.n1 + c.n2) * (1.0 / math.max(0.2, 1.0 + c.n1:dot(c.n2)))
    local n   = arc and math.max(arcMin, math.ceil(T / 0.05)) or 1
    local function arm(d, nn)
        local list = {}
        for i = 0, n do
            local t       = A - T + T * i / n
            list[#list + 1] = c.p + d * t + nn * (out * armK(t, A, T, arc))
        end
        return list
    end
    local pts, b = {}, arm(c.d2, c.n2)
    for i = #b, 1, -1 do pts[#pts + 1] = b[i] end
    pts[#pts + 1] = c.p + mit * out
    local front   = #pts
    for _, q in ipairs(arm(c.d1, c.n1)) do pts[#pts + 1] = q end
    return pts, front
end

local function holdsOpening(ops, face, f, fromEnd, span, z0, z1)
    local hit = false
    for _, w in ipairs(ops[face] or {}) do
        local lo, hi = w.s - w.half, w.s + w.half
        if fromEnd then lo, hi = f.len - hi, f.len - lo end
        if hi > 0.0 and lo < span then
            local zo, zt = w.pl.origin.z, w.pl.origin.z + (w.pl.height or w.pl.row.height)
            if zt > z0 and zo < z1 then
                hit = hit or {}
                hit[#hit + 1] = {zo, zt}
            end
        end
    end
    return hit
end

local function trimCorners(out, cfg, fs, ops, on, ctx, foot)
    local m0 = Window.modOf(cfg, "corner")
    if not m0 then return end
    local size = Window.modValue(m0, "size")
    for _, c in ipairs(corners(fs)) do
        if on("corner", c.a) or on("corner", c.b) then
            local slot       = c.b .. "|" .. ((c.a == "start") and 1 or 2)
            local mv         = m0.moves and m0.moves[slot] or {}
            local m          = ownOf(m0, m0, slot)
            local prof, kind = Trims.of("corner", m.dae)
            local d0, w0     = Trims.extent("corner", m.dae)
            local kd         = (Window.modValue(m, "deep") > 0) and Window.modValue(m, "deep") / d0 or size
            local kl         = (Window.modValue(m, "wide") > 0) and Window.modValue(m, "wide") / w0 or size
            local away       = Window.modValue(m, "out")
            if not mv.off then
                local fa, fb = fs[c.a], fs[c.b]
                local ea     = (flat(fa.pts[1] - c.p):length() < 1e-3) and 0 or 1
                local eb     = (flat(fb.pts[1] - c.p):length() < 1e-3) and 0 or 1
                local n1, n2 = endNormal(fa, ea), endNormal(fb, eb)
                local p      = c.p - (c.d1 + c.d2) * away
                local z0     = c.p.z + Window.modValue(m, "from") + (mv.z or 0.0)
                local H      = c.top - Window.modValue(m, "to") - z0
                if H > minRise then
                    local bk   = {}
                    local d    = ((kind == "quoin") and prof.out or d0) * kd
                    local arm  = ((kind == "quoin") and math.max(prof.long, prof.short) or w0) * kl
                    local hits = {}
                    for _, h in ipairs(holdsOpening(ops, c.a, fa, ea == 1, arm, z0, z0 + H) or {}) do hits[#hits + 1] = h end
                    for _, h in ipairs(holdsOpening(ops, c.b, fb, eb == 1, arm, z0, z0 + H) or {}) do hits[#hits + 1] = h end
                    local function skip(za, zb)
                        for _, h in ipairs(hits) do
                            if zb > h[1] and za < h[2] then return true end
                        end
                        return false
                    end
                    local T, arc = Window.modValue(m, "taperA"), m.bay == "arc"
                    if arc and (T <= 1e-6 or T > arm) then T = arm end
                    T = math.min(T, arm)
                    for _, side in ipairs({{fa, ea, c.a}, {fb, eb, c.b}}) do
                        local fc, e2 = side[1], side[2]
                        local a, b   = (e2 == 0) and 0.0 or (fc.len - arm), (e2 == 0) and arm or fc.len
                        local sh     = nil
                        if kind == "flat" and (T > 1e-6 or arc) then
                            sh = {a = a, b = b, D = d, cuts = {}, breaks = {}, k = function(sv)
                                return armK((e2 == 0) and sv or (fc.len - sv), arm, T, arc)
                            end}
                        end
                        note(foot, side[3], {a = a, b = b, z0 = z0, z1 = z0 + H, d = d, flat = kind == "flat", key = "corner", sh = sh})
                    end
                    if kind == "flat" then
                        local cf          = {p = vec3(p.x, p.y, 0), d1 = c.d1, d2 = c.d2, n1 = n1, n2 = n2}
                        local pts, front  = cornerPts(cf, arm, d - inset, T, arc)
                        local holes, gaps = {}, {}
                        for k = 1, #pts - 1 do holes[k] = flatHoles(ops[(k < front) and c.b or c.a], pts[k], pts[k + 1], z0, z0 + H, gaps, d) end
                        Trims.flatUp(bk, pts, cf.p, z0, H, holes, gaps, d - inset)
                    elseif kind == "quoin" then
                        Trims.quoin(bk, prof, {p = vec3(p.x, p.y, 0), d1 = c.d1, d2 = c.d2, n1 = n1, n2 = n2}, z0, H, {kd = kd, kl = kl, skip = skip})
                    else
                        local t = cornerT(p, c.d1, c.d2, 0.0, -1, 1)
                        Trims.upright(bk, prof, vec3(p.x, p.y, z0), H, function(v, q)
                            local kx = (v.x > 0) and kd or kl
                            local ky = (v.y < 0) and kd or kl
                            return t.x * (v.x * kx) + t.y * (v.y * ky), t.x * (q.x / kx) + t.y * (q.y / ky)
                        end, t.x:cross(t.y):dot(vec3(0, 0, 1)) < 0, (function()
                            local gaps = {}
                            for _, h in ipairs(hits) do gaps[#gaps + 1] = {h[1] - clear, h[2] + clear} end
                            return gaps
                        end)())
                    end
                    local from = #out + 1
                    Trims.flush(out, bk)
                    tagSlot(out, from, slot, "corner", c.d2, n2)
                    paint(out, from, m, "corner", ctx)
                end
            end
        end
    end
end

local function zChunks(z0, z1, gaps)
    table.sort(gaps, function(x, y) return x[1] < y[1] end)
    local out, from = {}, z0
    for _, g in ipairs(gaps) do
        if g[2] > from and g[1] < z1 then
            if g[1] - from > 1e-3 then out[#out + 1] = {from, g[1]} end
            from = math.max(from, g[2])
        end
    end
    if z1 - from > 1e-3 then out[#out + 1] = {from, z1} end
    return out
end

local function flatPilaster(bk, f, ops, e, s, hw, z0, H, D, foot, face)
    local a, b       = math.max(0.0, s - hw), math.min(f.len, s + hw)
    local sh         = shapeOf(e, a, b, D)
    local zg, inside = {}, {}
    for _, w in ipairs(ops) do
        local lo, hi = w.s - w.half, w.s + w.half
        local zo, zt = w.pl.origin.z, w.pl.origin.z + (w.pl.height or w.pl.row.height)
        if hi > a and lo < b and zt > z0 and zo < z0 + H then
            local ha, hb, apply = nil, nil, nil
            if zo >= z0 + 1e-3 and zt <= z0 + H - 1e-3 then ha, hb, apply = holeFor(f, w, a, b, D, sh) end
            if ha then inside[#inside + 1] = {ha, hb, zo, zt, apply} else zg[#zg + 1] = {zo - clear, zt + clear} end
        end
    end
    for _, hl in ipairs(inside) do
        for _, g in ipairs(zg) do
            if hl[4] > g[1] and hl[3] < g[2] then hl.gap = true end
        end
        if hl.gap then zg[#zg + 1] = {hl[3] - clear, hl[4] + clear} end
    end
    for _, ck in ipairs(zChunks(z0, z0 + H, zg)) do
        local holes = {}
        for _, hl in ipairs(inside) do
            if not hl.gap and hl[3] >= ck[1] + 1e-3 and hl[4] <= ck[2] - 1e-3 then
                hl[5]()
                holes[#holes + 1] = {hl[1], hl[2], hl[3] - ck[1], hl[4] - ck[1]}
            end
        end
        flatSweep(bk, f, Trims.flatBand(D, ck[2] - ck[1]), {a, b}, function() return ck[1] end, {}, {true, true}, holes, 1.0, 1.0, sh)
        note(foot, face, {a = a, b = b, z0 = ck[1], z1 = ck[2], d = D, flat = true, key = "pilaster", sh = sh})
    end
end

local function trimPilasters(out, cfg, fs, ops, on, ctx, foot)
    local m = Window.modOf(cfg, "pilaster")
    if not m then return end
    for ei, e in ipairs(entries(m)) do
        local _, ew = Trims.extent("pilaster", e.dae or m.dae)
        local eh    = ew * sizeOf(e, m, "wide", ew) / 2.0
        for _, key in ipairs(faceKeys) do
            local f = fs[key]
            if f and on("pilaster", key) and f.len > 4.0 * minHalf then
                local spots = {}
                if ei == 1 then
                    local split = math.floor(Window.modValue(m, "split") + 0.5)
                    local wins  = {}
                    for _, w in ipairs(ops[key]) do
                        if #wins == 0 or w.s - wins[#wins].s > samePos then wins[#wins + 1] = w end
                    end
                    local first = wins[1] and (wins[1].s - wins[1].half - clear) or f.len / 2.0
                    local last  = wins[1] and (f.len - wins[#wins].s - wins[#wins].half - clear) or f.len / 2.0
                    spots       = {{first / 2.0, true}, {last / 2.0, false}}
                    for j = 1, (split > 0) and #wins - 1 or 0 do
                        if j % split == 0 then
                            local a, b        = wins[j].s + wins[j].half + clear, wins[j + 1].s - wins[j + 1].half - clear
                            spots[#spots + 1] = {(b - a) / 2.0, (a + b) / 2.0}
                        end
                    end
                else
                    local count = math.max(1, math.floor(Window.modValue(e, "count") + 0.5))
                    for j = 0, count - 1 do spots[#spots + 1] = {math.huge, Window.modValue(e, "from") + eh + j * Window.modValue(e, "space")} end
                end
                for k, sp in ipairs(spots) do
                    local slot       = key .. "|" .. ((ei - 1) * 50 + k)
                    local mv         = m.moves and m.moves[slot] or {}
                    local es         = ownOf(m, e, slot)
                    local prof, kind = Trims.of("pilaster", es.dae or e.dae or m.dae)
                    local d0, w0     = Trims.extent("pilaster", es.dae or e.dae or m.dae)
                    local kd, kw     = sizeOf(es, m, "deep", d0), sizeOf(es, m, "wide", w0)
                    local half       = w0 * kw / 2.0
                    local hw         = math.min(half, sp[1])
                    local s          = (sp[2] == true) and hw or (sp[2] == false) and (f.len - hw) or sp[2]
                    s                = s + (mv.s or 0.0)
                    if hw >= minHalf and not mv.off and s - hw >= -1e-3 and s + hw <= f.len + 1e-3 then
                        local p, top, u, n = frameAt(f, s)
                        local z0           = p.z + ((ei == 1 and not (m.own and m.own[slot] and m.own[slot].lift)) and 0.0 or Window.modValue(es, "lift")) + (mv.z or 0.0)
                        local H            = top - Window.modValue(es, "to") - z0
                        local gaps         = {}
                        for _, w in ipairs(ops[key]) do
                            local lo, hi = w.s - w.half, w.s + w.half
                            local zo, zt = w.pl.origin.z, w.pl.origin.z + (w.pl.height or w.pl.row.height)
                            if hi > s - hw and lo < s + hw and zt > z0 and zo < z0 + H then
                                gaps[#gaps + 1] = {zo - clear, zt + clear}
                            end
                        end
                        if H > minRise and kind == "flat" then
                            local bk = {}
                            flatPilaster(bk, f, ops[key], es, s, hw, z0, H, d0 * kd, foot, key)
                            local from = #out + 1
                            Trims.flush(out, bk)
                            tagSlot(out, from, slot, "pilaster", u, n)
                            paint(out, from, ownOf(m, m, slot), "pilaster", ctx)
                        elseif H > minRise then
                            local bk = {}
                            local kx = kw * hw / half
                            note(foot, key, {a = s - hw, b = s + hw, z0 = z0, z1 = z0 + H, d = d0 * kd, flat = false, key = "pilaster"})
                            local o  = vec3(p.x, p.y, z0) - n * inset
                            Trims.upright(bk, prof, o, H, function(v, q)
                                return u * (v.x * kx) - n * (v.y * kd), u * (q.x / kx) - n * (q.y / kd)
                            end, u:cross(n * -1.0):dot(vec3(0, 0, 1)) < 0, gaps)
                            local from = #out + 1
                            Trims.flush(out, bk)
                            tagSlot(out, from, slot, "pilaster", u, n)
                            paint(out, from, ownOf(m, m, slot), "pilaster", ctx)
                        end
                    end
                end
            end
        end
    end
end

-- =============================================================================
-- WALL ITEMS
-- =============================================================================

local function clashes(foot, face, a, b, z0, z1, skip)
    local out = {}
    for _, e in ipairs(foot and foot[face] or {}) do
        if e.key ~= skip and a < e.b - 1e-6 and b > e.a + 1e-6 and z0 < e.z1 - 1e-6 and z1 > e.z0 + 1e-6 then out[#out + 1] = e end
    end
    return out
end

local function outOf(f, list, s)
    local best = nil
    for _, e in ipairs(list) do
        local off, n = frontAt(f, e, s)
        if not best or off > best.off then best = {off = off, n = n} end
    end
    return best
end

local function onFront(f, list, s, body)
    local carrier = nil
    for _, e in ipairs(list) do
        local whole = e.flat and body[1] >= e.a - 1e-6 and body[2] <= e.b + 1e-6 and body[3] >= e.z0 - 1e-6 and body[4] <= e.z1 + 1e-6
        for _, bk in ipairs(whole and e.sh and e.sh.breaks or {}) do
            if bk > body[1] + 1e-6 and bk < body[2] - 1e-6 then whole = false end
        end
        if whole and (not carrier or frontAt(f, e, s) > frontAt(f, carrier, s)) then carrier = e end
    end
    if not carrier then return nil end
    local off, n = frontAt(f, carrier, s)
    for _, e in ipairs(list) do
        if frontAt(f, e, s) > off + 1e-3 then return nil end
    end
    return {off = off, n = n}
end

local function pinAt(out, m, fs, pin, key, slot, frame, foot)
    local wide       = math.max(-m.lo.x, m.hi.x)
    local f, s, face = pinSpot(fs, pin, wide, frame)
    if not f then return end
    local p, top = at(f, s)
    local z      = math.max(p.z - m.lo.z, math.min(top - m.hi.z, frame.o.z + pin.z + Window.modValue(pin.own or {}, "lift")))
    propAt(out, m, f, s, z, key, slot, frame, outOf(f, clashes(foot, face, s - wide, s + wide, z + m.lo.z, z + m.hi.z), s))
end

local function fixtures(out, md, mod, key, fs, ops, on, taken, bodies, frame, foot)
    local rule = rules[key]
    local gap  = rule.gap
    for _, face in ipairs(faceKeys) do
        local f = fs[face]
        if f and on(key, face) then
            for _, e in ipairs(anchors(key, mod, ops, face)) do
                local st = slotOf(mod, md, e.slot)
                if st then
                    local w     = e.w
                    local slot  = e.slot
                    local m     = st.look
                    local fp    = footprint(m, rule.mount)
                    local half  = math.max(-fp.x0, fp.x1)
                    local wide  = math.max(-m.lo.x, m.hi.x)
                    local z0    = w.pl.origin.z
                    local side  = w.half + gap + half
                    local spots = {{w.s + rule.side * side}, {w.s - rule.side * side}}
                    if rule.under and not on("balcony", face) then spots[3] = {w.s, z0 - propGap - m.hi.z} end
                    local alt = nil
                    local function put(s, z, a, b, body, front)
                        propAt(out, m, f, s, z, key, slot, frame, front)
                        taken[face][#taken[face] + 1]   = {a, b, z + fp.z0, z + fp.z1}
                        bodies[face][#bodies[face] + 1] = body
                    end
                    for _, sp in ipairs(spots) do
                        local s      = sp[1]
                        local p, top = at(f, s)
                        local z      = (sp[2] or (rule.high and (top - propGap - m.hi.z) or z0)) + st.lift
                        local a, b   = s - half, s + half
                        local body   = {s - wide, s + wide, z + m.lo.z, z + m.hi.z}
                        if a >= gap and b <= f.len - gap and body[3] >= p.z and body[4] <= top
                           and fits(taken[face], a, b, z + fp.z0, z + fp.z1) and fits(bodies[face], body[1], body[2], body[3], body[4]) then
                            local hits = clashes(foot, face, body[1], body[2], body[3], body[4])
                            if #hits == 0 then
                                put(s, z, a, b, body)
                                alt = false
                                break
                            end
                            local front = onFront(f, hits, s, body)
                            if front and alt == nil then alt = {s, z, a, b, body, front} end
                        end
                    end
                    if alt then put(alt[1], alt[2], alt[3], alt[4], alt[5], alt[6]) end
                end
            end
        end
    end
end

local function flowers(out, md, m, fs, ops, on, foot)
    local half = math.max(-md.lo.x, md.hi.x)
    for _, face in ipairs(faceKeys) do
        local f = fs[face]
        if f and on("flowers", face) and not on(rules.flowers.unless, face) then
            for _, e in ipairs(anchors("flowers", m, ops, face)) do
                local st = slotOf(m, md, e.slot)
                if st then
                    local s          = math.max(0.0, math.min(f.len, e.w.s + st.ds))
                    local p, _, u, n = frameAt(f, s)
                    local z          = e.w.pl.origin.z - rules.flowers.gap + st.lift + st.dz
                    local body       = {s - half, s + half, z + md.lo.z, z + md.hi.z}
                    local hits       = clashes(foot, face, body[1], body[2], body[3], body[4])
                    local front      = nil
                    if #hits > 0 then front = (st.mv.s or st.mv.z) and outOf(f, hits, s) or onFront(f, hits, s, body) end
                    if #hits == 0 or front then
                        local from = #out + 1
                        emit(out, st.look, stand(p, n, z, front))
                        tagSlot(out, from, e.slot, "flowers", u, n)
                    end
                end
            end
        end
    end
end

local function downpipe(out, parts, f, s, zBase, slot, frame, foot, face)
    local p, top, u, n = frameAt(f, s)
    local head, base   = parts.head, parts.base
    local part         = parts.part
    local zh           = top - head.hi.z
    local run          = zh - zBase - base.hi.z
    if run < part.hi.z * 0.2 then return end
    local half  = math.max(-part.lo.x, part.hi.x)
    local front = outOf(f, clashes(foot, face, s - half, s + half, zBase, top, "roofborder"), s)
    if front then front.n = nil end
    local from = #out + 1
    emit(out, head, stand(p, n, zh, front))
    emit(out, base, stand(p, n, zBase, front))
    local count = math.max(1, math.floor(run / part.hi.z + 0.5))
    local sz    = run / (count * part.hi.z)
    for k = 0, count - 1 do
        local t = stand(p, n, zBase + base.hi.z + k * part.hi.z * sz, front)
        t.sz    = sz
        emit(out, part, t)
    end
    tagSlot(out, from, slot, "pipe", u, n)
    for j = from, #out do out[j].frame, out[j].at = frame, vec3(p.x, p.y, zBase) end
end

local function clearOf(list, s)
    for _, w in ipairs(list) do
        if math.abs(w.s - s) < w.half + rules.pipe.clear then return false end
    end
    return true
end

local function pipes(out, parts, m, fs, ops, on, frame, zBase, foot)
    for _, c in ipairs(corners(fs)) do
        local f   = fs[c.b]
        local gap = rules.pipe.gap
        if f and on("pipe", c.b) and f.len > 2.0 * gap then
            local first = c.a == "start"
            local s     = first and gap or (f.len - gap)
            local slot  = c.b .. "|" .. (first and 1 or 2)
            if slotOf(m, nil, slot) and clearOf(ops[c.b], s) then downpipe(out, parts, f, s, zBase or at(f, s).z, slot, frame, foot, c.b) end
        end
    end
    for i, pin in ipairs(m.pins or {}) do
        local f, s, face = pinSpot(fs, pin, rules.pipe.gap, frame)
        if f then downpipe(out, parts, f, s, zBase or at(f, s).z, "pin|" .. i, frame, foot, face) end
    end
end

-- =============================================================================
-- FLOOR
-- =============================================================================

local function build(p, stations, ctx)
    local cfg = p and p.cfg
    if not cfg or not cfg.mods then return {} end
    local fs  = faces(stations, ctx.nc, ctx.np, ctx.tangents)
    local ops = openings(p, fs)
    local all = openings(p, fs, true)
    local out = {}
    local function on(key, face) return Window.modAt(cfg, key, face, ctx.role) end

    local mark = #out + 1
    local md, m = model(cfg, "balcony")
    if md then band(out, md, m, "balcony", fs, all, on, function() return 0.0 end, nil, ctx) end
    tag(out, mark, "balcony")
    mark  = #out + 1
    md, m = model(cfg, "stairs")
    if md then
        for _, key in ipairs(faceKeys) do
            for _, e in ipairs(on("stairs", key) and anchors("stairs", m, all, key) or {}) do
                local st = slotOf(m, md, e.slot)
                if st then
                    local pl   = e.w.pl
                    local n0   = vec3(-pl.inward.x, -pl.inward.y, 0)
                    local u    = vec3(-n0.y, n0.x, 0)
                    local from = #out + 1
                    emit(out, st.look, (wallT(st.look, Modules.size(st.look.path), pl.origin + n0 * st.away + u * st.ds, u, n0, pl.origin.z + st.lift + st.dz, "raw", true)))
                    tagSlot(out, from, e.slot, "stairs", u, n0)
                end
            end
        end
    end

    tag(out, mark, "stairs")
    mark = #out + 1
    md, m = model(cfg, "pillar")
    if md and ctx.under and #ctx.under > 0 then
        local W           = Modules.size(md.path)
        local space, edge = Window.modValue(m, "space"), Window.modValue(m, "margin")
        local half        = along(md) / 2.0
        local taken       = {}
        for _, key in ipairs(faceKeys) do
            local f = fs[key]
            if f and on("pillar", key) and m.snap ~= false and f.len >= 2.0 * half then
                local run = f.len - 2.0 * half
                local n   = math.max(1, math.floor(run / space + 0.5))
                for k = 0, n do pillar(out, md, f, half + run * k / n, W, ctx.under, taken, key .. "|" .. (k + 1), m) end
            elseif f and on("pillar", key) and f.len - 2.0 * (edge + half) >= 0 then
                local left = edge + half + ((f.len - 2.0 * (edge + half)) % space) / 2.0
                local n    = math.floor((f.len - 2.0 * left) / space + 1e-9) + 1
                for k = 0, n - 1 do pillar(out, md, f, left + k * space, W, ctx.under, taken, key .. "|" .. (k + 1), m) end
            end
        end
    end

    tag(out, mark, "pillar")
    mark = #out + 1
    local foot = {}
    trimCorners(out, cfg, fs, ops, on, ctx, foot)

    tag(out, mark, "corner")
    mark = #out + 1
    trimPilasters(out, cfg, fs, ops, on, ctx, foot)

    tag(out, mark, "pilaster")
    local late = {}
    for _, key in ipairs({"plinth", "course", "roofborder"}) do
        local first = #late + 1
        trimLines(late, cfg, key, fs, ops, on, ctx, foot)
        tag(late, first, key)
    end
    mark  = #out + 1
    md, m = model(cfg, "awning")
    local function size(row, run, k)
        local v = nil
        for _, pl in ipairs(run or {}) do v = math.max(v or 0.0, pl[k] or row[k]) end
        return v or row[k]
    end
    local function front(face, a, b, z0, z1, sv) return outOf(fs[face], clashes(foot, face, a, b, z0, z1), sv) end
    if md then
        band(out, md, m, "awning", fs, all, on, function(row, run) return size(row, run, "height") - rules.awning.drop end,
             function(row, run) return size(row, run, "width") + 2.0 * rules.awning.over end, ctx, front)
    end
    tag(out, mark, "awning")
    local taken, bodies = {}, {}
    for _, key in ipairs(faceKeys) do
        taken[key], bodies[key] = {}, {}
        for _, w in ipairs(all[key]) do
            local z0 = w.pl.origin.z
            taken[key][#taken[key] + 1] = {w.s - w.half, w.s + w.half, z0, z0 + (w.pl.height or w.pl.row.height)}
        end
    end
    local frame = floorFrame(stations, ctx.nc, ctx.np)
    for _, key in ipairs(props) do
        mark  = #out + 1
        md, m = model(cfg, key)
        if md then
            fixtures(out, md, m, key, fs, all, on, taken, bodies, frame, foot)
            for i, pin in ipairs(m.pins or {}) do pinAt(out, lookOf(md, pin.dae), fs, pin, key, "pin|" .. i, frame, foot) end
        end
        tag(out, mark, key)
    end
    local pitched = false
    for _, face in ipairs(faceKeys) do pitched = pitched or on("roof", face) end
    md, m = model(cfg, "flowers")
    if md then flowers(out, md, m, fs, all, on, foot) end
    md, m = model(cfg, "pots")
    if md and not pitched then pots(out, md, m, fs, on) end
    for _, key in ipairs({"roofac", "roofdish"}) do
        local here = false
        for _, face in ipairs(faceKeys) do here = here or on(key, face) end
        md, m = model(cfg, key)
        if md and here and not pitched then onTop(out, md, m, key, fs, frame) end
    end
    mark  = #out + 1
    md, m = model(cfg, "corbel")
    if md and ctx.under and #ctx.under > 0 then corbels(out, md, m, fs, ctx.under, on) end
    tag(out, mark, "corbel")
    md, m = model(cfg, "pipe")
    if md then
        local parts = {part = md, base = Modules.model(Modules.pipeParts.base), head = Modules.model(Modules.pipeParts.head)}
        pipes(out, parts, m, fs, ops, on, frame, ctx.base, foot)
    end
    for _, sm in ipairs(late) do out[#out + 1] = sm end
    return out
end

local function border(cfg, role)
    local m = Window.modOf(cfg, "roofborder")
    if not m then return 0.0, 0.0 end
    local any = false
    for _, f in ipairs(faceKeys) do any = any or Window.modAt(cfg, "roofborder", f, role) end
    if not any then return 0.0, 0.0 end
    local prof = Trims.of("roofborder", m.dae)
    return prof.d * sizeOf(m, m, "deep", prof.d) - inset, prof.h * sizeOf(m, m, "tall", prof.h)
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.build  = build
M.border = border
M.rules  = rules

return M
