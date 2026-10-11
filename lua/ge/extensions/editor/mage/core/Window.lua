-- =============================================================================
-- MaGE - MeshRoad windows
-- Version: 1.0.1
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local Gate = require("editor/mage/core/Gate")

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local styles   = {"round", "quarter", "rect", "pointed"}
local faceKeys = {"right", "left", "start", "end"}

local limits = {
    depth    = {0.01, 1000.0, 0.3},
    margin   = {0.0,  20.0,   0.2},
    floorGap = {0.0,  50.0,   1.9},
    width    = {0.1,  50.0,   1.2},
    gap      = {0.0,  50.0,   0.5},
    height   = {0.1,  50.0,   1.3},
    sill     = {0.05, 1000.0, 1.0},
}

local floorKeys   = {"width", "gap", "height", "sill"}
local globalKeys  = {"depth", "margin", "floorGap"}
local clearance   = 0.02
local endShare    = 0.45
local arcTol      = 0.05
local arcMinSteps = 8
local arcMaxDepth = 6
local snapTol     = 1e-4
local minJamb     = 0.01
local topClear    = 0.2
local doorGap     = 0.1
local trackStep   = 0.05

-- =============================================================================
-- DATA
-- =============================================================================

local function isStyle(s)
    for _, k in ipairs(styles) do
        if k == s then return true end
    end
    return false
end

local function num(v, key)
    local l = limits[key]
    local n = tonumber(v) or l[3]
    return math.max(l[1], math.min(l[2], n))
end

local function isFace(s)
    for _, k in ipairs(faceKeys) do
        if k == s then return true end
    end
    return false
end

local function cleanFloor(f)
    if type(f) ~= "table" or not isStyle(f.style) then return nil end
    local out = {style = f.style, dir = (f.dir == "right") and "right" or "left"}
    for _, k in ipairs(floorKeys) do out[k] = num(f[k], k) end
    if type(f.wall) == "string" and f.wall ~= "" then out.wall = f.wall end
    if type(f.dae) == "string" and f.dae ~= "" then out.dae = f.dae end
    if isFace(f.face) then out.face = f.face end
    if tonumber(f.at) then out.at = math.max(0.0, math.min(1.0, tonumber(f.at))) end
    return out
end

local function clean(data)
    if type(data) ~= "table" or type(data.floors) ~= "table" then return nil end
    local floors = {}
    for _, f in ipairs(data.floors) do
        local c = cleanFloor(f)
        if c then floors[#floors + 1] = c end
    end
    if #floors == 0 then return nil end
    local faces = type(data.faces) == "table" and data.faces or {right = true, left = true}
    local walls = type(data.walls) == "table" and data.walls or {}
    local out   = {floors = floors, faces = {}, walls = {}}
    for _, k in ipairs(faceKeys) do
        out.faces[k] = faces[k] == true
        if type(walls[k]) == "string" and walls[k] ~= "" then out.walls[k] = walls[k] end
    end
    for _, k in ipairs(globalKeys) do out[k] = num(data[k], k) end
    out.modules = data.modules == true
    return out
end

local function parse(str)
    if type(str) ~= "string" or str == "" then return nil end
    local ok, data = pcall(jsonDecode, str)
    if not ok then return nil end
    return clean(data)
end

local function round3(v) return math.floor(v * 1000 + 0.5) / 1000 end

local function encode(cfg)
    if not cfg or not cfg.floors or #cfg.floors == 0 then return "" end
    local floors = {}
    for _, f in ipairs(cfg.floors) do
        local o = {style = f.style, dir = (f.style == "quarter") and f.dir or nil, wall = f.wall, dae = f.dae, face = f.face,
                   at = f.at and round3(f.at) or nil}
        for _, k in ipairs(floorKeys) do o[k] = round3(f[k]) end
        floors[#floors + 1] = o
    end
    local faces, walls = {}, {}
    for _, k in ipairs(faceKeys) do
        faces[k] = cfg.faces[k] == true
        walls[k] = cfg.walls and cfg.walls[k] or nil
    end
    local out = {floors = floors, faces = faces, walls = next(walls) and walls or nil, modules = cfg.modules or nil}
    for _, k in ipairs(globalKeys) do out[k] = round3(cfg[k]) end
    return jsonEncode(out)
end

local function fits(fl, wallHeight)
    return fl.sill + fl.height <= wallHeight - topClear
end

local function above(fl, gap)
    local f = {}
    for k, v in pairs(fl) do f[k] = v end
    f.sill = fl.sill + fl.height + gap
    return f
end

local function below(fl, gap)
    local f = {}
    for k, v in pairs(fl) do f[k] = v end
    f.sill = fl.sill - gap - fl.height
    if f.sill < limits.sill[1] then return nil end
    return f
end

local function newFloor(style, dir)
    local f = {style = style, dir = dir or "left"}
    for _, k in ipairs(floorKeys) do f[k] = limits[k][3] end
    return f
end

local function newConfig(style, dir)
    local cfg = {floors = {newFloor(style, dir)}, faces = {right = true, left = true, start = false, ["end"] = false}, walls = {}}
    for _, k in ipairs(globalKeys) do cfg[k] = limits[k][3] end
    return cfg
end

-- =============================================================================
-- LAYOUT
-- =============================================================================

local function layout(avail, w, g)
    if avail < w * 0.5 then return {} end
    local n     = math.max(1, math.floor((avail + g) / (w + g) + 0.5))
    local scale = avail / (n * w + (n - 1) * g)
    local out   = {}
    for k = 1, n do
        local a = (k - 1) * (w + g) * scale
        out[k]  = {a, a + w * scale}
    end
    return out
end

local function rowSpans(fl, u0, u1)
    if fl.at then
        local w = math.min(fl.width, u1 - u0)
        if w < fl.width * 0.5 then return {} end
        local c = u0 + w / 2.0 + (u1 - u0 - w) * fl.at
        return {{c - w / 2.0 - u0, c + w / 2.0 - u0}}
    end
    if fl.dae then
        local avail = u1 - u0
        local n     = math.floor((avail + fl.gap) / (fl.width + fl.gap) + 1e-9)
        local off   = (avail - (n * fl.width + (n - 1) * fl.gap)) / 2.0
        local out   = {}
        for k = 1, n do
            local a = off + (k - 1) * (fl.width + fl.gap)
            out[k]  = {a, a + fl.width}
        end
        return out
    end
    return layout(u1 - u0, fl.width, fl.gap)
end

local function hiAt(win, u)
    local half = win.view.width / 2.0
    local d    = math.max(-half, math.min(half, u - win.c))
    local z    = Gate.openingZ(win.view, d) or win.lo
    return math.max(z, win.lo + minJamb)
end

local function newWin(a, b, lo, fl, idx)
    local c = (a + b) / 2.0
    return {a = a, b = b, c = c, lo = lo, floor = idx, face = fl.face, single = fl.at ~= nil,
            view = {style = fl.style, width = b - a, dir = fl.dir, apex = lo + fl.height, floor = lo}}
end

local function samples(win)
    local out = {win.a, win.b}
    if win.view.style == "rect" then return out end
    local function refine(a, b, depth)
        local m = (a + b) / 2.0
        if depth < arcMaxDepth and math.abs(hiAt(win, m) - (hiAt(win, a) + hiAt(win, b)) / 2.0) > arcTol then
            refine(a, m, depth + 1)
            out[#out + 1] = m
            refine(m, b, depth + 1)
        end
    end
    local ms = {}
    for k = 0, arcMinSteps do ms[#ms + 1] = win.a + (win.b - win.a) * k / arcMinSteps end
    ms[#ms + 1] = win.c
    table.sort(ms)
    for k = 2, #ms - 1 do out[#out + 1] = ms[k] end
    for k = 1, #ms - 1 do refine(ms[k], ms[k + 1], 0) end
    table.sort(out)
    local uniq = {}
    for _, u in ipairs(out) do
        if #uniq == 0 or u - uniq[#uniq] > snapTol then uniq[#uniq + 1] = u end
    end
    return uniq
end

local function crossings(w1, w2, grid, out)
    local function f(u, a, b) return hiAt(a, u) - b.lo end
    for _, pair in ipairs({{w1, w2}, {w2, w1}}) do
        local a, b = pair[1], pair[2]
        for k = 1, #grid - 1 do
            local x0, x1 = grid[k], grid[k + 1]
            local f0, f1 = f(x0, a, b), f(x1, a, b)
            if f0 * f1 < 0 then
                for _ = 1, 40 do
                    local m  = (x0 + x1) / 2.0
                    local fm = f(m, a, b)
                    if fm * f0 < 0 then x1 = m else x0, f0 = m, fm end
                end
                out[#out + 1] = (x0 + x1) / 2.0
            end
        end
    end
end

-- =============================================================================
-- FACE TRACKS
-- =============================================================================

local function interp(xs, ys, x)
    if x <= xs[1] then return ys[1] end
    for k = 1, #xs - 1 do
        if x <= xs[k + 1] then
            local d = xs[k + 1] - xs[k]
            local f = (d > 1e-12) and ((x - xs[k]) / d) or 0.0
            return ys[k] + (ys[k + 1] - ys[k]) * f
        end
    end
    return ys[#ys]
end

local function faceTrack(path, w, h, tan, s, sign)
    local L = s[#s]
    local n = math.max(2, math.ceil(L / trackStep))
    local t = {s = {}, x = {}, y = {}, l = {}}
    for k = 0, n do
        local at           = L * k / n
        local q, wd, _, tv = Gate.sampleAt(path, w, h, tan, s, at)
        local off          = sign * wd / 2.0
        t.s[k + 1]        = at
        t.x[k + 1]        = q.x - tv.y * off
        t.y[k + 1]        = q.y + tv.x * off
        t.l[k + 1]        = (k == 0) and 0.0
                            or t.l[k] + math.sqrt((t.x[k + 1] - t.x[k]) ^ 2 + (t.y[k + 1] - t.y[k]) ^ 2)
    end
    return t
end

local function chord(t, c, width)
    local function d(m)
        local ax, ay = interp(t.s, t.x, c - m), interp(t.s, t.y, c - m)
        local bx, by = interp(t.s, t.x, c + m), interp(t.s, t.y, c + m)
        return math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
    end
    local lo, hi = 0.0, width * 4.0
    for _ = 1, 50 do
        local m = (lo + hi) / 2.0
        if d(m) < width then lo = m else hi = m end
    end
    return c - hi, c + hi
end

-- =============================================================================
-- PLAN
-- =============================================================================

local function plan(cfg, path, w, h, tan, gateAt)
    if not cfg or #path < 2 then return path, w, h, tan, gateAt, nil end
    local s  = Gate.along(path)
    local L  = s[#s]
    local fc = cfg.faces
    local dS = fc.start and math.min(cfg.depth, endShare * L) or 0.0
    local dE = fc["end"] and math.min(cfg.depth, endShare * L) or 0.0
    local p  = {cfg = cfg, wins = {}, dS = dS, dE = dE}
    if not (fc.right or fc.left) then return path, w, h, tan, gateAt, p end

    local u0, u1 = cfg.margin + dS, L - cfg.margin - dE
    local function add(a, b, fl, fi, face)
        if a < 0.0 or b > L then return end
        local q, _, hd = Gate.sampleAt(path, w, h, tan, s, (a + b) / 2.0)
        local win      = newWin(a, b, q.z - hd + fl.sill, fl, fi)
        win.face       = face or win.face
        for _, u in ipairs({a, win.c, b}) do
            local qu = Gate.sampleAt(path, w, h, tan, s, u)
            if hiAt(win, u) > qu.z - topClear then return end
        end
        p.wins[#p.wins + 1] = win
    end
    local tracks = {}
    for fi, fl in ipairs(cfg.floors) do
        local onSide = not fl.face or fl.face == "right" or fl.face == "left"
        if onSide and fl.dae then
            for _, f in ipairs({"right", "left"}) do
                if fc[f] and (not fl.face or fl.face == f) then
                    tracks[f]    = tracks[f] or faceTrack(path, w, h, tan, s, (f == "right") and -1 or 1)
                    local t      = tracks[f]
                    local l0, l1 = interp(t.s, t.l, u0), interp(t.s, t.l, u1)
                    for _, ab in ipairs(rowSpans(fl, l0, l1)) do
                        local a, b = chord(t, interp(t.l, t.s, l0 + (ab[1] + ab[2]) / 2.0), fl.width)
                        add(a, b, fl, fi, f)
                    end
                end
            end
        elseif onSide then
            for _, ab in ipairs(rowSpans(fl, u0, u1)) do add(u0 + ab[1], u0 + ab[2], fl, fi) end
        end
    end
    if #p.wins == 0 then return path, w, h, tan, gateAt, p end

    local events = {}
    for _, win in ipairs(p.wins) do
        win.grid = samples(win)
        for _, u in ipairs(win.grid) do events[#events + 1] = u end
    end
    for i = 1, #p.wins do
        for j = i + 1, #p.wins do
            local w1, w2 = p.wins[i], p.wins[j]
            local lo, hi = math.max(w1.a, w2.a), math.min(w1.b, w2.b)
            if w1.floor ~= w2.floor and hi > lo then
                local grid = {lo, hi}
                for _, g in ipairs({w1.grid, w2.grid}) do
                    for _, u in ipairs(g) do
                        if u > lo and u < hi then grid[#grid + 1] = u end
                    end
                end
                table.sort(grid)
                crossings(w1, w2, grid, events)
            end
        end
    end
    table.sort(events)

    local np, nw, nh, nt, ng, ns = {}, {}, {}, {}, gateAt and {} or nil, {}
    local function push(q, wd, hd, tv, gi, u)
        local k = #np + 1
        np[k], nw[k], nh[k], nt[k], ns[k] = q, wd, hd, tv, u
        if ng then ng[k] = gi or false end
    end
    local e = 1
    for i = 1, #path do
        while e <= #events and events[e] < s[i] - snapTol do
            local u = events[e]
            if #ns == 0 or u - ns[#ns] > snapTol then
                local q, wd, hd, tv = Gate.sampleAt(path, w, h, tan, s, u)
                push(q, wd, hd, tv, false, u)
            end
            e = e + 1
        end
        while e <= #events and events[e] <= s[i] + snapTol do e = e + 1 end
        push(path[i], w[i], h[i], tan[i], gateAt and gateAt[i], s[i])
    end

    local function indexOf(u)
        local best, bestD = nil, math.huge
        for k, v in ipairs(ns) do
            local d = math.abs(v - u)
            if d < bestD then best, bestD = k, d end
        end
        return best
    end
    local kept = {}
    for _, win in ipairs(p.wins) do
        win.ia, win.ib = indexOf(win.a), indexOf(win.b)
        if win.ib > win.ia then kept[#kept + 1] = win end
    end
    p.wins = kept
    return np, nw, nh, nt, ng, p
end

-- =============================================================================
-- MATERIALS
-- =============================================================================

local function overrides(cfg)
    local banded = false
    for _, f in ipairs(cfg.floors) do
        if f.wall then banded = true end
    end
    local any = banded
    for _, k in ipairs(faceKeys) do
        if cfg.walls[k] then any = true end
    end
    return banded, any
end

local function bands(cfg)
    local fl = {}
    for _, f in ipairs(cfg.floors) do fl[#fl + 1] = f end
    table.sort(fl, function(a, b) return a.sill < b.sill end)
    local out, prev = {}, -math.huge
    for k = 1, #fl - 1 do
        local v = math.max(prev, (fl[k].sill + fl[k].height + fl[k + 1].sill) / 2.0)
        out[k]  = v
        prev    = v
    end
    return fl, out
end

local function lerpItem(x, y, t)
    return {p = x.p + (y.p - x.p) * t, k = x.k, a = x.a + (y.a - x.a) * t, b = x.b + (y.b - x.b) * t, r = x.r + (y.r - x.r) * t}
end

local function cut(items, level, keepAbove)
    local out, n = {}, #items
    for i = 1, n do
        local A, B = items[i], items[i % n + 1]
        local inA  = keepAbove and (A.r >= level) or (not keepAbove and A.r <= level)
        local inB  = keepAbove and (B.r >= level) or (not keepAbove and B.r <= level)
        if inA then out[#out + 1] = A end
        if inA ~= inB then
            local lo, hi = A, B
            if B.r < A.r then lo, hi = B, A end
            out[#out + 1] = lerpItem(lo, hi, (level - lo.r) / (hi.r - lo.r))
        end
    end
    return out
end

local function uvOf(U, it)
    if it.k == "c" then return U.capCurbUV(it.a, 0.0, it.b) end
    return {U.curbU(it.a), U.curbFaceV(it.b)}
end

local function put(p, ctx, face, items, want)
    local function emitKey(key, its)
        if #its < 3 then return end
        ctx.withStyle(key, function()
            local vs, uvs = {}, {}
            for i, it in ipairs(its) do vs[i], uvs[i] = it.p, uvOf(ctx.uv, it) end
            ctx.emitFace(ctx.smFor(key), vs, uvs, want)
        end)
    end
    local faceKey = p.useOverrides and p.cfg.walls[face] or nil
    if not (p.useOverrides and p.banded) then
        emitKey(faceKey, items)
        return
    end
    local fl = p.floorsSorted
    for k = 1, #fl do
        local piece = items
        if k > 1 then piece = cut(piece, p.bounds[k - 1], true) end
        if k < #fl and #piece >= 3 then piece = cut(piece, p.bounds[k], false) end
        emitKey(fl[k].wall or faceKey, piece)
    end
end

-- =============================================================================
-- FACES
-- =============================================================================

local function horiz(v)
    local o = vec3(v.x, v.y, 0)
    if o:length() < 1e-9 then return o end
    return o:normalized()
end

local function faceP(st, c, z)
    local b, t = st.bot[c], st.top[c]
    local dz   = t.z - b.z
    local f    = (math.abs(dz) > 1e-9) and ((z - b.z) / dz) or 0.0
    return b + (t - b) * f
end

local function depthFromTop(st, c, z)
    local b, t = st.bot[c], st.top[c]
    local dz   = t.z - b.z
    local f    = (math.abs(dz) > 1e-9) and ((z - b.z) / dz) or 0.0
    return st.height + (st.chamfer - st.height) * f
end

local function zipper(A, B, emit)
    local i, j, m, n = 1, 1, #A, #B
    while i < m or j < n do
        local advA
        if i == m then
            advA = false
        elseif j == n then
            advA = true
        else
            advA = (A[i + 1].p - B[j].p):length() <= (A[i].p - B[j + 1].p):length()
        end
        if advA then
            emit(A[i], A[i + 1], B[j])
            i = i + 1
        else
            emit(A[i], B[j + 1], B[j])
            j = j + 1
        end
    end
end

local function sides(p, stations, ctx)
    if not p then return nil end
    local nc, np, cfg = ctx.nc, ctx.np, p.cfg
    local banded, any = overrides(cfg)
    local gated       = false
    for i = 1, np do
        if ctx.gateAt and ctx.gateAt[i] then gated = true end
    end
    p.useOverrides           = any and not gated
    p.banded                 = banded
    p.floorsSorted, p.bounds = bands(cfg)
    local faceName           = {[1] = "right", [nc] = "left"}
    local function needs(c) return p.useOverrides and (banded or cfg.walls[faceName[c]] ~= nil) end
    local fR, fL = cfg.faces.right, cfg.faces.left
    local other  = {[1] = nc, [nc] = 1}

    local kept = {}
    for _, win in ipairs(p.wins) do
        local ok = win.ia > 1 and win.ib < np
        for i = math.max(1, win.ia - 1), math.min(np, win.ib + 1) do
            if ctx.gateAt and ctx.gateAt[i] then ok = false end
        end
        local tmin = math.huge
        if ok then
            win.hi = {}
            for i = win.ia, win.ib do
                local st = stations[i]
                if not (st.bot[1] and st.bot[nc]) then ok = false break end
                tmin      = math.min(tmin, (st.bot[nc] - st.bot[1]):length())
                win.hi[i] = hiAt(win, st.s)
            end
        end
        if ok then
            win.through       = ((fR and cfg.depth or 0.0) + (fL and cfg.depth or 0.0)) >= tmin - 1e-9
            kept[#kept + 1]   = win
        end
    end

    local parent = {}
    for k = 1, #kept do parent[k] = k end
    local function find(k)
        while parent[k] ~= k do k = parent[k] end
        return k
    end
    for a = 1, #kept do
        for b = a + 1, #kept do
            local w1, w2 = kept[a], kept[b]
            for i = math.max(w1.ia, w2.ia), math.min(w1.ib, w2.ib) do
                if w1.lo <= w2.hi[i] + 1e-9 and w2.lo <= w1.hi[i] + 1e-9 then
                    parent[find(a)] = find(b)
                    break
                end
            end
        end
    end
    local compThrough = {}
    for k, win in ipairs(kept) do
        if win.through then compThrough[find(k)] = true end
    end
    for k, win in ipairs(kept) do win.through = compThrough[find(k)] == true end

    local function facesOf(win)
        if win.through then return {1, nc} end
        local t = {}
        if fR and win.face ~= "left" then t[#t + 1] = 1 end
        if fL and win.face ~= "right" then t[#t + 1] = nc end
        return t
    end
    local function topOf(win)
        local z = win.lo
        for i = win.ia, win.ib do z = math.max(z, win.hi[i]) end
        return z
    end
    local function covered(win, c)
        if win.single then return false end
        for _, d in ipairs(kept) do
            if d.single and d.face == faceName[c] and win.a < d.b + doorGap and d.a < win.b + doorGap
               and win.lo < topOf(d) and d.lo < topOf(win) then
                return true
            end
        end
        return false
    end
    local final = {}
    for _, win in ipairs(kept) do
        local ok = true
        for _, c in ipairs(facesOf(win)) do
            for i = win.ia, win.ib do
                local st = stations[i]
                if not (st.bot[c] and st.top[c]) or win.lo < st.bot[c].z + clearance or win.hi[i] > st.top[c].z - clearance then
                    ok = false
                end
            end
        end
        if ok then
            win.run = {[win.ia] = 0.0}
            for i = win.ia + 1, win.ib do
                local ds   = stations[i].s - stations[i - 1].s
                local dz   = win.hi[i] - win.hi[i - 1]
                win.run[i] = win.run[i - 1] + math.sqrt(ds * ds + dz * dz)
            end
            final[#final + 1] = win
        end
    end
    if #final == 0 and not (needs(1) or needs(nc)) then return nil end

    local taken = {}
    p.placed    = p.placed or {}
    for _, c in ipairs({1, nc}) do
        local wc = {}
        for _, win in ipairs(final) do
            for _, f in ipairs(facesOf(win)) do
                if f == c and not covered(win, c) then wc[#wc + 1] = win end
            end
        end
        if #wc > 0 or needs(c) then taken[c] = {wins = wc} end
        for _, win in ipairs(wc) do
            local k = win.ia
            while k < win.ib - 1 and stations[k + 1].s < win.c do k = k + 1 end
            local A, B = stations[k], stations[k + 1]
            local t    = (B.s - A.s > 1e-9) and math.max(0.0, math.min(1.0, (win.c - A.s) / (B.s - A.s))) or 0.0
            local pa   = faceP(A, c, win.lo)
            local pb   = faceP(B, c, win.lo)
            local inA  = horiz(A.bot[other[c]] - A.bot[c])
            local inB  = horiz(B.bot[other[c]] - B.bot[c])
            p.placed[#p.placed + 1] = {row = cfg.floors[win.floor], origin = pa + (pb - pa) * t,
                                       inward = horiz(inA + (inB - inA) * t), face = faceName[c]}
        end
    end

    local function segGroups(wc, k)
        local act = {}
        for _, win in ipairs(wc) do
            if win.ia <= k and win.ib >= k + 1 then act[#act + 1] = win end
        end
        local par = {}
        for a = 1, #act do par[a] = a end
        local function root(a)
            while par[a] ~= a do a = par[a] end
            return a
        end
        local function touch(w1, w2, i) return w1.lo <= w2.hi[i] + 1e-9 and w2.lo <= w1.hi[i] + 1e-9 end
        for a = 1, #act do
            for b = a + 1, #act do
                if touch(act[a], act[b], k) or touch(act[a], act[b], k + 1) then par[root(a)] = root(b) end
            end
        end
        local byRoot, groups = {}, {}
        for a, win in ipairs(act) do
            local r = root(a)
            local g = byRoot[r]
            if not g then
                g         = {members = {}, through = win.through, lo = {}, hi = {}, run = {}}
                byRoot[r] = g
                groups[#groups + 1] = g
            end
            g.members[#g.members + 1] = win
            for _, i in ipairs({k, k + 1}) do
                g.lo[i] = math.min(g.lo[i] or math.huge, win.lo)
                if not g.hi[i] or win.hi[i] > g.hi[i] then
                    g.hi[i], g.run[i] = win.hi[i], win.run[i]
                end
            end
        end
        table.sort(groups, function(x, y) return x.lo[k] < y.lo[k] end)
        return groups
    end

    for c, t in pairs(taken) do
        t.seg = {}
        for k = 1, np - 1 do t.seg[k] = segGroups(t.wins, k) end
        t.bp = {}
        for i = 1, np do
            local st = stations[i]
            local zs = {st.bot[c].z, st.top[c].z}
            for _, k in ipairs({i - 1, i}) do
                for _, g in ipairs(t.seg[k] or {}) do
                    if g.lo[i] then
                        zs[#zs + 1] = g.lo[i]
                        zs[#zs + 1] = g.hi[i]
                    end
                end
            end
            table.sort(zs)
            local out = {}
            for _, z in ipairs(zs) do
                if #out == 0 or z - out[#out] > 1e-7 then out[#out + 1] = z end
            end
            t.bp[i] = out
        end
        t.seg[0], t.seg[np] = {}, {}
        t.segs = {}
        for k = 1, np - 1 do
            t.segs[k] = needs(c) or #t.seg[k - 1] > 0 or #t.seg[k] > 0 or #t.seg[k + 1] > 0
        end
    end

    local depth = cfg.depth
    local up    = vec3(0, 0, 1)

    local function within(list, z0, z1)
        local out = {}
        for _, z in ipairs(list) do
            if z >= z0 - 1e-7 and z <= z1 + 1e-7 then out[#out + 1] = z end
        end
        return out
    end
    local function base(i) return math.min(stations[i].bot[1].z, stations[i].bot[nc].z) end
    local function across(st, c) return horiz(st.bot[other[c]] - st.bot[c]) end
    local function item(i, c, z, q, da, db)
        local st = stations[i]
        return {p = q or faceP(st, c, z), k = "f", a = st.s + (da or 0.0), b = depthFromTop(st, c, z) + (db or 0.0), r = z - base(i)}
    end
    local function innerPoint(i, c, z, g)
        local st = stations[i]
        if g.through then return faceP(st, other[c], z) end
        return faceP(st, c, z) + across(st, c) * depth
    end
    local function tri(c, want)
        return function(a, b, d) put(p, ctx, faceName[c], {a, b, d}, want) end
    end
    local function complement(groups, i, st, c)
        local out, z = {}, st.bot[c].z
        for _, g in ipairs(groups) do
            out[#out + 1] = {z, g.lo[i]}
            z             = g.hi[i]
        end
        out[#out + 1] = {z, st.top[c].z}
        return out
    end

    for c, t in pairs(taken) do
        local outward = function(st) return st.side * ((c == 1) and -1 or 1) end
        for k = 1, np - 1 do
            local A, B = stations[k], stations[k + 1]
            if t.segs[k] and A.bot[c] and B.bot[c] then
                local groups = t.seg[k]
                local sa, sb = complement(groups, k, A, c), complement(groups, k + 1, B, c)
                for n = 1, #sa do
                    local ca, cb = {}, {}
                    for _, z in ipairs(within(t.bp[k], sa[n][1], sa[n][2])) do ca[#ca + 1] = item(k, c, z) end
                    for _, z in ipairs(within(t.bp[k + 1], sb[n][1], sb[n][2])) do cb[#cb + 1] = item(k + 1, c, z) end
                    if #ca > 0 and #cb > 0 then zipper(ca, cb, tri(c, outward(A))) end
                end
                for _, g in ipairs(groups) do
                    if not g.through or c == 1 then
                        local function wallQuad(zA, zB, aA, aB, want)
                            local ia, ib = innerPoint(k, c, zA, g), innerPoint(k + 1, c, zB, g)
                            local pa, pb = faceP(A, c, zA), faceP(B, c, zB)
                            local da, db = (ia - pa):length(), (ib - pb):length()
                            local qa, qb = item(k, c, zA, pa, aA - A.s), item(k + 1, c, zB, pb, aB - B.s)
                            local ra, rb = item(k, c, zA, ia, aA - A.s, da), item(k + 1, c, zB, ib, aB - B.s, db)
                            put(p, ctx, faceName[c], {qa, qb, rb, ra}, want)
                        end
                        wallQuad(g.lo[k], g.lo[k + 1], A.s, B.s, up)
                        wallQuad(g.hi[k], g.hi[k + 1], A.s + g.run[k], A.s + g.run[k + 1], up * -1.0)
                        if not g.through then
                            local ca, cb = {}, {}
                            for _, z in ipairs(within(t.bp[k], g.lo[k], g.hi[k])) do ca[#ca + 1] = item(k, c, z, innerPoint(k, c, z, g)) end
                            for _, z in ipairs(within(t.bp[k + 1], g.lo[k + 1], g.hi[k + 1])) do cb[#cb + 1] = item(k + 1, c, z, innerPoint(k + 1, c, z, g)) end
                            if #ca > 0 and #cb > 0 then zipper(ca, cb, tri(c, outward(A))) end
                        end
                    end
                end
            end
        end

        for i = 2, np - 1 do
            local L, R = t.seg[i - 1], t.seg[i]
            if #L > 0 or #R > 0 then
                local zs = {}
                for _, set in ipairs({L, R}) do
                    for _, g in ipairs(set) do
                        zs[#zs + 1] = g.lo[i]
                        zs[#zs + 1] = g.hi[i]
                    end
                end
                table.sort(zs)
                local function inside(set, z)
                    for _, g in ipairs(set) do
                        if z > g.lo[i] and z < g.hi[i] then return g end
                    end
                    return nil
                end
                local pieces = {}
                for n = 1, #zs - 1 do
                    local za, zb = zs[n], zs[n + 1]
                    if zb - za > 1e-7 then
                        local m      = (za + zb) / 2.0
                        local gl, gr = inside(L, m), inside(R, m)
                        if (gl ~= nil) ~= (gr ~= nil) then
                            local g, sd = gl or gr, gr and 1 or -1
                            local last  = pieces[#pieces]
                            if last and last.g == g and last.side == sd and math.abs(last.z1 - za) < 1e-7 then
                                last.z1 = zb
                            else
                                pieces[#pieces + 1] = {z0 = za, z1 = zb, g = g, side = sd}
                            end
                        end
                    end
                end
                local st  = stations[i]
                local fwd = horiz(stations[i + 1].bot[c] - stations[i - 1].bot[c])
                for _, pc in ipairs(pieces) do
                    if not pc.g.through or c == 1 then
                        local ca, cb = {}, {}
                        for _, z in ipairs(within(t.bp[i], pc.z0, pc.z1)) do ca[#ca + 1] = item(i, c, z) end
                        local src = pc.g.through and taken[other[c]].bp[i] or t.bp[i]
                        for _, z in ipairs(within(src, pc.z0, pc.z1)) do
                            local ip = innerPoint(i, c, z, pc.g)
                            cb[#cb + 1] = item(i, c, z, ip, (ip - faceP(st, c, z)):length())
                        end
                        if #ca > 0 and #cb > 0 then zipper(ca, cb, tri(c, fwd * pc.side)) end
                    end
                end
            end
        end
    end

    local out = {}
    for c, t in pairs(taken) do out[c] = t.segs end
    return out
end

-- =============================================================================
-- TRIANGULATION
-- =============================================================================

local function area2(a, b, c) return (b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x) end

local function same(a, b) return math.abs(a.x - b.x) < 1e-9 and math.abs(a.z - b.z) < 1e-9 end

local function bridge(P, poly, hole)
    local m, mx, mz = 1, -math.huge, math.huge
    for k, idx in ipairs(hole) do
        local q = P[idx]
        if q.x > mx + 1e-12 or (math.abs(q.x - mx) <= 1e-12 and q.z < mz) then m, mx, mz = k, q.x, q.z end
    end
    local Mp        = P[hole[m]]
    local bestX, vk = math.huge, nil
    for k = 1, #poly do
        local a, b = P[poly[k]], P[poly[k % #poly + 1]]
        if (a.z - Mp.z) * (b.z - Mp.z) <= 0 and math.abs(a.z - b.z) > 1e-12 then
            local t = (Mp.z - a.z) / (b.z - a.z)
            local x = a.x + (b.x - a.x) * t
            if x >= Mp.x - 1e-12 and x < bestX - 1e-12 then
                bestX = x
                if math.abs(a.z - Mp.z) < 1e-9 then
                    vk = k
                elseif math.abs(b.z - Mp.z) < 1e-9 then
                    vk = k % #poly + 1
                else
                    vk = (a.x >= b.x) and k or (k % #poly + 1)
                end
            end
        end
    end
    if not vk then return nil end
    local I                    = {x = bestX, z = Mp.z}
    local V                    = P[poly[vk]]
    local bestCos, bestD, pick = -math.huge, math.huge, vk
    for k = 1, #poly do
        local R = P[poly[k]]
        if k ~= vk and not same(R, V) and not (math.abs(I.x - V.x) < 1e-12 and math.abs(I.z - V.z) < 1e-12) then
            local pv, nx = P[poly[(k - 2) % #poly + 1]], P[poly[k % #poly + 1]]
            if area2(pv, R, nx) < 0 then
                local t1, t2, t3 = area2(Mp, I, R), area2(I, V, R), area2(V, Mp, R)
                local inTri      = (t1 >= 0 and t2 >= 0 and t3 >= 0) or (t1 <= 0 and t2 <= 0 and t3 <= 0)
                if inTri then
                    local dx, dz = R.x - Mp.x, R.z - Mp.z
                    local d      = math.sqrt(dx * dx + dz * dz)
                    local cs     = (d > 1e-12) and dx / d or 1.0
                    if cs > bestCos + 1e-12 or (math.abs(cs - bestCos) <= 1e-12 and d < bestD) then
                        bestCos, bestD, pick = cs, d, k
                    end
                end
            end
        end
    end
    vk       = pick
    local V2 = P[poly[vk]]
    for k = 1, #poly do
        if same(P[poly[k]], V2) then
            local pv, nx = P[poly[(k - 2) % #poly + 1]], P[poly[k % #poly + 1]]
            local s1, s2 = area2(pv, V2, Mp), area2(V2, nx, Mp)
            local inside
            if area2(pv, V2, nx) >= 0 then inside = s1 >= 0 and s2 >= 0 else inside = s1 >= 0 or s2 >= 0 end
            if inside then
                vk = k
                break
            end
        end
    end
    local out = {}
    for k = 1, vk do out[#out + 1] = poly[k] end
    for j = 0, #hole do out[#out + 1] = hole[(m - 1 + j) % #hole + 1] end
    out[#out + 1] = poly[vk]
    for k = vk + 1, #poly do out[#out + 1] = poly[k] end
    return out
end

local function earclip(P, poly, emitTri)
    local idx = {}
    for k, v in ipairs(poly) do idx[k] = v end
    local guard = 0
    while #idx > 3 and guard < 20000 do
        guard     = guard + 1
        local n   = #idx
        local cut = false
        for k = 1, n do
            local a, b, c = idx[(k - 2) % n + 1], idx[k], idx[k % n + 1]
            local A, B, C = P[a], P[b], P[c]
            if area2(A, B, C) > 1e-12 then
                local clean = true
                for _, o in ipairs(idx) do
                    local O = P[o]
                    if o ~= a and o ~= b and o ~= c and not same(O, A) and not same(O, B) and not same(O, C)
                       and area2(A, B, O) >= -1e-12 and area2(B, C, O) >= -1e-12 and area2(C, A, O) >= -1e-12 then
                        clean = false
                        break
                    end
                end
                if clean then
                    emitTri(a, b, c)
                    table.remove(idx, k)
                    cut = true
                    break
                end
            end
        end
        if not cut then return false end
    end
    if #idx == 3 then emitTri(idx[1], idx[2], idx[3]) end
    return true
end

local function triangulate(P, outer, holes, emitTri)
    table.sort(holes, function(x, y)
        local mx, my = -math.huge, -math.huge
        for _, i in ipairs(x) do mx = math.max(mx, P[i].x) end
        for _, i in ipairs(y) do my = math.max(my, P[i].x) end
        return mx > my
    end)
    local poly = outer
    for _, h in ipairs(holes) do
        local rev = {}
        for k = #h, 1, -1 do rev[#rev + 1] = h[k] end
        poly = bridge(P, poly, rev)
        if not poly then return false end
    end
    return earclip(P, poly, emitTri)
end

-- =============================================================================
-- ENDS
-- =============================================================================

local function endFace(p, stations, ctx, idx, sign)
    if not p then return false end
    local key   = (idx == 1) and "start" or "end"
    local needs = p.useOverrides and (p.banded or p.cfg.walls[key] ~= nil)
    if not (p.cfg.faces[key] or needs) then return false end
    local nc, st = ctx.nc, stations[idx]
    if not (st.bot[1] and st.bot[nc]) then return false end
    local cfg = p.cfg
    local D   = (idx == 1) and p.dS or p.dE

    local O       = st.bot[1]
    local sideU   = horiz(st.bot[nc] - st.bot[1])
    local want    = ctx.tangents[idx] * sign
    local inward  = horiz(want) * -1.0
    local roadTop = O.z + st.height
    local function X(v) return (v - O):dot(sideU) end
    local xMax = X(st.bot[nc])

    local uvTab = {}
    for ci = 1, nc do uvTab[#uvTab + 1] = {X(st.top[ci]), st.cols[ci].uvx} end
    table.sort(uvTab, function(a, b) return a[1] < b[1] end)
    local function uvx(x)
        if x <= uvTab[1][1] then return uvTab[1][2] end
        for k = 1, #uvTab - 1 do
            local a, b = uvTab[k], uvTab[k + 1]
            if x <= b[1] then
                local t = (b[1] - a[1] > 1e-9) and ((x - a[1]) / (b[1] - a[1])) or 0.0
                return a[2] + (b[2] - a[2]) * t
            end
        end
        return uvTab[#uvTab][2]
    end
    local tops = {}
    for ci = 1, nc do tops[#tops + 1] = {X(st.top[ci]), st.top[ci].z} end
    table.sort(tops, function(a, b) return a[1] < b[1] end)
    local function topZ(x)
        if x <= tops[1][1] then return tops[1][2] end
        for k = 1, #tops - 1 do
            local a, b = tops[k], tops[k + 1]
            if x <= b[1] then
                local t = (b[1] - a[1] > 1e-9) and ((x - a[1]) / (b[1] - a[1])) or 0.0
                return a[2] + (b[2] - a[2]) * t
            end
        end
        return tops[#tops][2]
    end

    local accepted = {}
    local rows     = {}
    for fi, fl in ipairs((cfg.faces[key] and D > 1e-6) and cfg.floors or {}) do
        if not fl.face or fl.face == key then rows[#rows + 1] = {fi = fi, fl = fl} end
    end
    table.sort(rows, function(x, y)
        if (x.fl.at ~= nil) ~= (y.fl.at ~= nil) then return x.fl.at ~= nil end
        return x.fi < y.fi
    end)
    for _, rw in ipairs(rows) do
        local fi, fl = rw.fi, rw.fl
        local u0, u1 = cfg.margin, xMax - cfg.margin
        for _, ab in ipairs(rowSpans(fl, u0, u1)) do
            local win = newWin(u0 + ab[1], u0 + ab[2], O.z + fl.sill, fl, fi)
            local xs  = samples(win)
            local ok  = win.a >= clearance and win.b <= xMax - clearance and win.lo >= O.z + clearance
            local top = -math.huge
            for _, x in ipairs(xs) do
                local hz = hiAt(win, x)
                top      = math.max(top, hz)
                if hz > topZ(x) - clearance then ok = false end
            end
            for _, o in ipairs(accepted) do
                local g = (o.win.single and not win.single) and doorGap or 0.0
                if win.a < o.win.b + g and o.win.a < win.b + g and win.lo < o.top and o.win.lo < top then ok = false end
            end
            if ok then accepted[#accepted + 1] = {win = win, xs = xs, top = top} end
        end
    end
    if #accepted == 0 and not needs then return false end

    local xs0, xs1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
    for _, a in ipairs(accepted) do
        xs0, xs1 = math.min(xs0, a.win.a), math.max(xs1, a.win.b)
        z0, z1   = math.min(z0, a.win.lo), math.max(z1, a.top)
    end
    local P0    = (st.bot[1] + st.bot[nc]) * 0.5
    local xc    = X(P0)
    local step  = (idx == 1) and 1 or -1
    local prevT = 0.0
    local i     = idx + step
    while #accepted > 0 and stations[i] do
        local si = stations[i]
        local ok = si.bot[1] and si.bot[nc] and si.top[1] and si.top[nc]
        local t  = 0.0
        if ok then
            local ci = (si.bot[1] + si.bot[nc]) * 0.5
            local e  = (ci - P0):dot(sideU)
            local hw = (si.bot[nc] - si.bot[1]):length() / 2.0
            t        = (ci - P0):dot(inward)
            ok       = t > prevT - 1e-9
                       and (xs0 - xc) - e >= -hw + clearance and (xs1 - xc) - e <= hw - clearance
                       and z0 >= math.max(si.bot[1].z, si.bot[nc].z) + clearance
                       and z1 <= math.min(si.top[1].z, si.top[nc].z) - clearance
        end
        if not ok then
            D = math.min(D, prevT)
            break
        end
        if t >= D then break end
        prevT = t
        i     = i + step
    end
    if #accepted > 0 and D <= 0.01 then
        if not needs then return false end
        accepted = {}
    end

    local P = {}
    local function add(x, z, v3)
        P[#P + 1] = {x = x, z = z, v = v3 or vec3(O.x + sideU.x * x, O.y + sideU.y * x, z)}
        return #P
    end
    local outer = {}
    for ci = 1, nc do
        if st.bot[ci] then outer[#outer + 1] = add(X(st.bot[ci]), st.bot[ci].z, st.bot[ci]) end
    end
    for ci = nc, 1, -1 do outer[#outer + 1] = add(X(st.top[ci]), st.top[ci].z, st.top[ci]) end

    p.placed = p.placed or {}
    for _, a in ipairs(accepted) do
        local xc = (a.win.a + a.win.b) / 2.0
        p.placed[#p.placed + 1] = {row = cfg.floors[a.win.floor], origin = vec3(O.x + sideU.x * xc, O.y + sideU.y * xc, a.win.lo),
                                   inward = inward, face = key}
    end

    local holes = {}
    for _, a in ipairs(accepted) do
        local ring = {}
        for _, x in ipairs(a.xs) do ring[#ring + 1] = add(x, a.win.lo) end
        for k = #a.xs, 1, -1 do ring[#ring + 1] = add(a.xs[k], hiAt(a.win, a.xs[k])) end
        holes[#holes + 1] = ring
    end

    local base = math.min(st.bot[1].z, st.bot[nc].z)
    local function citem(q, v3, da, db)
        return {p = v3 or q.v, k = "c", a = uvx(q.x) + (da or 0.0), b = q.z - roadTop - (db or 0.0), r = q.z - base}
    end
    local holeCopies = {}
    for k, h in ipairs(holes) do
        local c = {}
        for j, v in ipairs(h) do c[j] = v end
        holeCopies[k] = c
    end
    local okTri = triangulate(P, outer, holeCopies, function(a, b, c)
        put(p, ctx, key, {citem(P[a]), citem(P[b]), citem(P[c])}, want)
    end)
    if not okTri then return false end

    for _, ring in ipairs(holes) do
        local n = #ring
        for k = 1, n do
            local a, b   = P[ring[k]], P[ring[k % n + 1]]
            local dx, dz = b.x - a.x, b.z - a.z
            local len    = math.sqrt(dx * dx + dz * dz)
            if len > 1e-9 then
                local nx, nz = -dz / len, dx / len
                local nw     = sideU * nx + vec3(0, 0, nz)
                local ai, bi = a.v + inward * D, b.v + inward * D
                local flat   = math.abs(dx) >= math.abs(dz)
                local da, db = flat and 0.0 or D, flat and D or 0.0
                put(p, ctx, key, {citem(a), citem(b), citem(b, bi, da, db), citem(a, ai, da, db)}, nw)
            end
        end
        earclip(P, ring, function(a, b, c)
            put(p, ctx, key, {citem(P[a], P[a].v + inward * D), citem(P[b], P[b].v + inward * D), citem(P[c], P[c].v + inward * D)}, want)
        end)
    end
    return true
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.styles    = styles
M.faceKeys  = faceKeys
M.limits    = limits
M.parse     = parse
M.encode    = encode
M.clean     = clean
M.newFloor  = newFloor
M.fits      = fits
M.above     = above
M.below     = below
M.newConfig = newConfig
M.layout    = layout
M.plan      = plan
M.sides     = sides
M.endFace   = endFace

return M
