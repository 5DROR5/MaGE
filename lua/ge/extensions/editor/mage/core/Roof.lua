-- =============================================================================
-- MaGE - pitched roofs over a building floor
-- Version: 1.0.2
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local Window = require("editor/mage/core/Window")

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local eps   = 1e-4
local step  = 1e-3
local gut   = {w = 0.12, h = 0.09}
local up    = vec3(0, 0, 1)
local down  = vec3(0, 0, -1)

-- =============================================================================
-- FRAMES
-- =============================================================================

local function horiz(v)
    local o = vec3(v.x, v.y, 0)
    local l = o:length()
    if l < 1e-9 then return o end
    return o / l
end

local function frames(stations, nc, np, tangents, grow, lift)
    local out, s = {}, 0.0
    for i = 1, np do
        local R, L = stations[i].top[1], stations[i].top[nc]
        local w    = vec3(L.x - R.x, L.y - R.y, 0)
        local c    = vec3((R.x + L.x) / 2.0, (R.y + L.y) / 2.0, 0)
        if i > 1 then s = s + (c - out[i - 1].c):length() end
        out[i] = {c = c, u = horiz(w), h = w:length() / 2.0 + grow, zr = R.z + lift, zl = L.z + lift, s = s, t = horiz(tangents[i]), lift = lift}
    end
    return out
end

local function beyond(a, ds)
    return {c = a.c + a.t * ds, u = a.u, h = a.h, zr = a.zr, zl = a.zl, t = a.t, lift = a.lift}
end

local function sample(F, s)
    local n = #F
    if s <= 0.0 then return beyond(F[1], s) end
    if s >= F[n].s then return beyond(F[n], s - F[n].s) end
    local k = 1
    while k < n - 1 and F[k + 1].s < s do k = k + 1 end
    local a, b = F[k], F[k + 1]
    local f    = (b.s - a.s > 1e-9) and (s - a.s) / (b.s - a.s) or 0.0
    return {c = a.c + (b.c - a.c) * f, u = horiz(a.u + (b.u - a.u) * f), h = a.h + (b.h - a.h) * f,
            zr = a.zr + (b.zr - a.zr) * f, zl = a.zl + (b.zl - a.zl) * f, t = horiz(a.t + (b.t - a.t) * f), lift = a.lift}
end

local function zTop(fr, d)
    return fr.zr + (fr.zl - fr.zr) * (d + fr.h) / math.max(1e-9, 2.0 * fr.h)
end

local function pt(fr, d, z)
    return vec3(fr.c.x + fr.u.x * d, fr.c.y + fr.u.y * d, z)
end

-- =============================================================================
-- SHAPE
-- =============================================================================

local function spec(m, L, grow, cut)
    local depth = Window.modValue(m, "depth")
    local hip   = m.shape == "hip"
    local sp    = {wa = -grow, wb = L + grow, oa = Window.modValue(m, "over"), hipA = hip, hipB = hip,
                   prof = (m.shape == "shed") and (m.high == "right" and "shedR" or "shedL") or "gable", depth = depth}
    sp.over        = sp.oa
    sp.oa          = m.gable or sp.oa
    sp.ob          = sp.oa
    sp.ridge       = (m.shape ~= "shed") and Window.modValue(m, "ridge") or 0.0
    if m.part == "start" then
        sp.wb, sp.ob, sp.hipB, sp.innerB = math.min(depth, L), 0.0, false, true
    elseif m.part == "end" then
        sp.wa, sp.oa, sp.hipA, sp.innerA = math.max(0.0, L - depth), 0.0, false, true
    elseif m.part == "right" or m.part == "left" then
        sp.side, sp.hipA, sp.hipB = m.part, false, false
    end
    if cut then
        if cut.start then sp.oa, sp.hipA = 0.0, false end
        if cut["end"] then sp.ob, sp.hipB = 0.0, false end
        sp.cutR, sp.cutL = cut.right, cut.left
    end
    return sp
end

local function inCut(list, s)
    for _, c in ipairs(list or {}) do
        if s >= c[1] - 1e-6 and s <= c[2] + 1e-6 then return true end
    end
    return false
end

local function span(sp, fr, s)
    local h, oR, oL = fr.h, sp.over, sp.over
    if s and inCut(sp.cutR, s) then oR = 0.0 end
    if s and inCut(sp.cutL, s) then oL = 0.0 end
    if sp.side == "right" then return -h - oR, math.min(h, -h + sp.depth), true, false end
    if sp.side == "left" then return math.max(-h, h - sp.depth), h + oL, false, true end
    return -h - oR, h + oL, true, true
end

local function rise(sp, fr, d)
    local h = fr.h
    if sp.side == "right" or (not sp.side and sp.prof == "shedL") then return d + h end
    if sp.side == "left" or (not sp.side and sp.prof == "shedR") then return h - d end
    local r = sp.ridge * h
    if r == 0 then return math.min(d + h, h - d) end
    return math.min(d + h, (h - d) * (h + r) / (h - r))
end

local function hipAt(sp, s)
    local b = math.huge
    if sp.hipA then b = math.min(b, s - sp.wa) end
    if sp.hipB then b = math.min(b, sp.wb - s) end
    return b
end

local function columns(sp, fr, s)
    local dA, dB = span(sp, fr, s)
    if sp.side or sp.prof ~= "gable" then return {dA, dB} end
    local b = hipAt(sp, s)
    local r = sp.ridge * fr.h
    if r == 0 then return {dA, math.max(dA, math.min(0.0, -fr.h + b)), 0.0, math.min(dB, math.max(0.0, fr.h - b)), dB} end
    local k = (fr.h + r) / (fr.h - r)
    return {dA, math.max(dA, math.min(r, -fr.h + b)), r, math.min(dB, math.max(r, fr.h - b / k)), dB}
end

local function samples(sp, F)
    local sa, sb = sp.wa - sp.oa, sp.wb + sp.ob
    local list   = {sa, sb, sp.wa, sp.wb}
    for _, f in ipairs(F) do list[#list + 1] = f.s end
    if sp.hipA then list[#list + 1] = sp.wa + sample(F, sp.wa).h end
    if sp.hipB then list[#list + 1] = sp.wb - sample(F, sp.wb).h end
    if sp.hipA and sp.hipB then list[#list + 1] = (sp.wa + sp.wb) / 2.0 end
    for _, cuts in ipairs({sp.cutR or {}, sp.cutL or {}}) do
        for _, c in ipairs(cuts) do
            for _, v in ipairs({c[1] - step, c[1], c[2], c[2] + step}) do list[#list + 1] = v end
        end
    end
    table.sort(list)
    local out = {}
    for _, s in ipairs(list) do
        if s >= sa - eps and s <= sb + eps and (#out == 0 or s - out[#out] > eps) then out[#out + 1] = math.max(sa, math.min(sb, s)) end
    end
    return out
end

-- =============================================================================
-- RIDGE CAP
-- =============================================================================

local function cap(ctx, sm, pts, tn, uv, capW, capH)
    if #pts < 2 then return end
    local fr = {}
    for k, p in ipairs(pts) do
        local a, b = pts[math.max(1, k - 1)], pts[math.min(#pts, k + 1)]
        local t    = horiz(b - a)
        local u    = vec3(-t.y, t.x, 0)
        fr[k]      = {l = p - u * capW - vec3(0, 0, capW * tn), r = p + u * capW - vec3(0, 0, capW * tn), t = p + vec3(0, 0, capH), u = u}
    end
    local run = 0.0
    for k = 1, #pts - 1 do
        local A, B = fr[k], fr[k + 1]
        local len  = (pts[k + 1] - pts[k]):length()
        local ua   = {uv(run, -capW), uv(run, 0.0), uv(run, capW)}
        local ub   = {uv(run + len, -capW), uv(run + len, 0.0), uv(run + len, capW)}
        run        = run + len
        ctx.emit(sm, {A.l, B.l, B.t, A.t}, {ua[1], ub[1], ub[2], ua[2]}, up - A.u)
        ctx.emit(sm, {A.t, B.t, B.r, A.r}, {ua[2], ub[2], ub[3], ua[3]}, up + A.u)
        ctx.emit(sm, {A.l, A.r, B.r, B.l}, {ua[1], ua[3], ub[3], ub[1]}, down)
    end
    for _, e in ipairs({{1, 2}, {#pts, #pts - 1}}) do
        local f = fr[e[1]]
        ctx.emit(sm, {f.l, f.r, f.t}, {uv(0.0, -capW), uv(0.0, capW), uv(capH, 0.0)}, horiz(pts[e[1]] - pts[e[2]]))
    end
end

local function caps(ctx, sm, sp, secs, tn, uv, capW, capH)
    if sp.side or sp.prof ~= "gable" then return end
    local ridge = {}
    for _, sec in ipairs(secs) do
        if math.abs(sec.row[2].d - sec.row[3].d) < eps and math.abs(sec.row[4].d - sec.row[3].d) < eps then ridge[#ridge + 1] = sec.row[3].p end
    end
    cap(ctx, sm, ridge, tn, uv, capW, capH)
    for _, e in ipairs({{sp.hipA, 1, #secs, 1}, {sp.hipB, #secs, 1, -1}}) do
        if e[1] then
            for _, col in ipairs({2, 4}) do
                local line = {}
                for j = e[2], e[3], e[4] do
                    line[#line + 1] = secs[j].row[col].p
                    if math.abs(secs[j].row[col].d - secs[j].row[3].d) < eps then break end
                end
                cap(ctx, sm, line, tn, uv, capW, capH)
            end
        end
    end
end

-- =============================================================================
-- GUTTERS
-- =============================================================================

local function trough(ctx, sm, run, su)
    local lo = vec3(0, 0, gut.h)
    local s  = 0.0
    for j = 1, #run - 1 do
        local A, B = run[j], run[j + 1]
        local l    = (B.p - A.p):length()
        local u0   = s / su
        local u1   = (s + l) / su
        s          = s + l
        local ai, bi, ao, bo = A.p, B.p, A.p + A.o * gut.w, B.p + B.o * gut.w
        local o              = (A.o + B.o):normalized()
        ctx.emit(sm, {ao, bo, bo - lo, ao - lo}, {{u0, 0.0}, {u1, 0.0}, {u1, 1.0}, {u0, 1.0}}, o)
        ctx.emit(sm, {ai - lo, bi - lo, bo - lo, ao - lo}, {{u0, 0.0}, {u1, 0.0}, {u1, 1.0}, {u0, 1.0}}, down)
        ctx.emit(sm, {ai, bi, bi - lo, ai - lo}, {{u0, 0.0}, {u1, 0.0}, {u1, 1.0}, {u0, 1.0}}, o * -1.0)
        ctx.emit(sm, {ai, bi, bo, ao}, {{u0, 0.0}, {u1, 0.0}, {u1, 1.0}, {u0, 1.0}}, up)
    end
    for _, e in ipairs({{run[1], run[2]}, {run[#run], run[#run - 1]}}) do
        local P, t = e[1], (e[1].p - e[2].p):normalized()
        ctx.emit(sm, {P.p, P.p + P.o * gut.w, P.p + P.o * gut.w - lo, P.p - lo}, {{0.0, 0.0}, {1.0, 0.0}, {1.0, 1.0}, {0.0, 1.0}}, t)
    end
end

local function gutters(ctx, sp, secs, slab)
    local sm, su = ctx.gutterSm()
    local runs   = {}
    local function side(face, cutList, pick, sign)
        if not ctx.gutter[face] then return end
        local run = {}
        for _, sec in ipairs(secs) do
            if inCut(cutList, sec.s) then
                if #run >= 2 then runs[#runs + 1] = run end
                run = {}
            else
                local c       = pick(sec.row)
                run[#run + 1] = {p = c.p - slab, o = sec.fr.u * sign}
            end
        end
        if #run >= 2 then runs[#runs + 1] = run end
    end
    local flat = sp.side == nil
    if (sp.side ~= "left") and not (flat and sp.prof == "shedR") then
        side("right", sp.cutR, function(row) return row[1] end, -1.0)
    end
    if (sp.side ~= "right") and not (flat and sp.prof == "shedL") then
        side("left", sp.cutL, function(row) return row[#row] end, 1.0)
    end
    for _, e in ipairs({{sp.hipA, secs[1], -1.0, "start"}, {sp.hipB, secs[#secs], 1.0, "end"}}) do
        if e[1] and ctx.gutter[e[4]] then
            local run = {}
            for _, c in ipairs(e[2].row) do run[#run + 1] = {p = c.p - slab, o = e[2].fr.t * e[3]} end
            if #run >= 2 then runs[#runs + 1] = run end
        end
    end
    for _, run in ipairs(runs) do trough(ctx, sm, run, su) end
end

-- =============================================================================
-- BUILD
-- =============================================================================

local function build(m, stations, ctx)
    local F = frames(stations, ctx.nc, ctx.np, ctx.tangents, ctx.grow or 0.0, ctx.lift or 0.0)
    local L = F[#F].s
    if L < eps then return end
    local sp             = spec(m, L, ctx.grow or 0.0, ctx.cut)
    local thick          = Window.modValue(m, "thick")
    local slab           = vec3(0, 0, thick)
    local pitch          = math.rad(Window.modValue(m, "pitch"))
    local tn, co         = math.tan(pitch), math.cos(pitch)
    local sm, su, sv     = ctx.roofSm()
    local tex            = Window.modValue(m, "tex")
    su, sv               = su * tex, sv * tex
    local _, _, eaA, eaB = span(sp, F[1])
    local function face(a, b) if m.turn then return {b, a} end return {a, b} end
    local function uv(s, d) return face(s / su + 0.5, d / co / sv + 0.5) end
    local sa, sb, mid = sp.wa - sp.oa, sp.wb + sp.ob, (sp.wa + sp.wb) / 2.0
    local function plate(sec, d, k, first)
        local dA, dB = sec.row[1].d, sec.row[#sec.row].d
        local up     = (sp.side == "right" or (not sp.side and sp.prof == "shedL")) and 1 or (sp.side or sp.prof == "shedR") and -1 or nil
        if not up then
            if k == 1 then up = 1 elseif k == #sec.row - 1 then up = -1 end
        end
        if up then
            local v = (up > 0) and (d - dA) or (dB - d)
            return face(up * sec.s / su + 0.5, v / co / sv + 0.5)
        end
        if first then return face(-d / su + 0.5, (sec.s - sa) / co / sv + 0.5) end
        return face(d / su + 0.5, (sb - sec.s) / co / sv + 0.5)
    end
    local function wuv(s, fr, d, z) return {ctx.curbU(s), ctx.curbFaceV(zTop(fr, d) - z)} end

    local secs = {}
    for j, s in ipairs(samples(sp, F)) do
        local fr, b = sample(F, s), hipAt(sp, s)
        local sec   = {s = s, fr = fr, b = b, row = {}}
        sec.z       = function(d) return zTop(fr, d) + tn * math.min(rise(sp, fr, d), b) end
        for k, d in ipairs(columns(sp, fr, s)) do sec.row[k] = {d = d, p = pt(fr, d, sec.z(d))} end
        secs[j] = sec
    end
    if #secs < 2 then return end

    for j = 1, #secs - 1 do
        local A, B = secs[j], secs[j + 1]
        for k = 1, #A.row - 1 do
            local q  = {A.row[k].p, A.row[k + 1].p, B.row[k + 1].p, B.row[k].p}
            local fs = sp.hipA and (not sp.hipB or (A.s + B.s) / 2.0 < mid)
            local qu = {plate(A, A.row[k].d, k, fs), plate(A, A.row[k + 1].d, k, fs), plate(B, B.row[k + 1].d, k, fs), plate(B, B.row[k].d, k, fs)}
            ctx.emit(sm, q, qu, up)
            ctx.emit(sm, {q[1] - slab, q[2] - slab, q[3] - slab, q[4] - slab}, qu, down)
        end
        for _, e in ipairs({{1, -1.0, eaA}, {#A.row, 1.0, eaB}}) do
            local k, out = e[1], A.fr.u * e[2]
            local a, b   = A.row[k], B.row[k]
            ctx.emit(sm, {a.p, b.p, b.p - slab, a.p - slab}, {uv(A.s, a.d), uv(B.s, b.d), uv(B.s, b.d + thick), uv(A.s, a.d + thick)}, out)
            if not e[3] then
                local fa, fb = pt(A.fr, a.d, zTop(A.fr, a.d) - A.fr.lift), pt(B.fr, b.d, zTop(B.fr, b.d) - B.fr.lift)
                local ta, tb = pt(A.fr, a.d, math.max(fa.z, a.p.z - thick)), pt(B.fr, b.d, math.max(fb.z, b.p.z - thick))
                ctx.emit(ctx.wallSm(nil), {ta, tb, fb, fa},
                         {wuv(A.s, A.fr, a.d, ta.z), wuv(B.s, B.fr, b.d, tb.z), wuv(B.s, B.fr, b.d, fb.z), wuv(A.s, A.fr, a.d, fa.z)}, out)
            end
        end
        if A.s >= sp.wa - eps and B.s <= sp.wb + eps then
            for _, w in ipairs({{-1.0, "right"}, {1.0, "left"}}) do
                local da, db = A.fr.h * w[1], B.fr.h * w[1]
                local lo, hi = A.row[1].d, A.row[#A.row].d
                local inner  = (not eaA and math.abs(da - lo) < eps) or (not eaB and math.abs(da - hi) < eps)
                local fa, fb = pt(A.fr, da, zTop(A.fr, da)), pt(B.fr, db, zTop(B.fr, db))
                local za, zb = A.z(da) - thick, B.z(db) - thick
                if da > lo - eps and da < hi + eps and not inner and (za > fa.z + eps or zb > fb.z + eps) then
                    local ta, tb = pt(A.fr, da, math.max(za, fa.z)), pt(B.fr, db, math.max(zb, fb.z))
                    ctx.emit(ctx.wallSm(w[2]), {ta, tb, fb, fa},
                             {wuv(A.s, A.fr, da, ta.z), wuv(B.s, B.fr, db, tb.z), wuv(B.s, B.fr, db, fb.z), wuv(A.s, A.fr, da, fa.z)}, A.fr.u * w[1])
                end
            end
        end
    end

    for _, e in ipairs({{1, -1.0, sp.hipA, sp.wa, "start", sp.innerA}, {#secs, 1.0, sp.hipB, sp.wb, "end", sp.innerB}}) do
        local sec = secs[e[1]]
        local out = sec.fr.t * e[2]
        for k = 1, #sec.row - 1 do
            local a, b = sec.row[k], sec.row[k + 1]
            ctx.emit(sm, {a.p, b.p, b.p - slab, a.p - slab}, {uv(sec.s, a.d), uv(sec.s, b.d), uv(sec.s + thick, b.d), uv(sec.s + thick, a.d)}, out)
        end
        if not e[3] then
            local wall
            for _, w in ipairs(secs) do
                if math.abs(w.s - e[4]) < 2.0 * eps then wall = w end
            end
            if wall then
                local fr     = wall.fr
                local drop   = e[6] and fr.lift or 0.0
                local lo, hi = math.max(wall.row[1].d, -fr.h), math.min(wall.row[#wall.row].d, fr.h)
                local ds     = {hi}
                for k = #wall.row, 1, -1 do
                    local d = wall.row[k].d
                    if d < hi - eps and d > lo + eps and d < ds[#ds] - eps then ds[#ds + 1] = d end
                end
                ds[#ds + 1] = lo
                local vs, us = {pt(fr, lo, zTop(fr, lo) - drop), pt(fr, hi, zTop(fr, hi) - drop)}, {}
                for _, d in ipairs(ds) do
                    local p = pt(fr, d, math.max(zTop(fr, d) - drop, wall.z(d) - thick))
                    if (p - vs[#vs]):length() > eps and (p - vs[1]):length() > eps then vs[#vs + 1] = p end
                end
                for k, v in ipairs(vs) do us[k] = {ctx.curbU((v - pt(fr, lo, v.z)):length()), ctx.curbFaceV(zTop(fr, lo) - v.z)} end
                if #vs >= 3 then ctx.emit(ctx.wallSm(e[5]), vs, us, out) end
            end
        end
    end
    if m.cap then caps(ctx, sm, sp, secs, tn, uv, Window.modValue(m, "capW"), Window.modValue(m, "capH")) end
    if ctx.gutter then gutters(ctx, sp, secs, slab) end
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.build = build

return M
