-- =============================================================================
-- MaGE - trims built from a section: swept along the wall, stretched up a corner, or made stone by stone
-- Version: 1.0.2
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local Profiles = require("editor/mage/config/Profiles")

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local defaults = {
    plinth     = "G_C_BP_01_150x50",
    course     = "G_C_SC_01_300x20",
    roofborder = "G_C_RC_01_300x90",
    corner     = "C_AP_G_CO_08_80x300",
    pilaster   = "G_C_WP_01_60x300",
}

local stoneTex = 0.5
local stoneRun = 0.37
local flatMat  = "m_plaster_worn_01"
local up       = vec3(0, 0, 1)

-- =============================================================================
-- STATE
-- =============================================================================

local caps   = {}
local shapes = {}
local bands  = {}
local names  = nil

-- =============================================================================
-- LIBRARY
-- =============================================================================

local function nameOf(v)
    local s = tostring(v or "")
    return s:match("([^/]+)%.[dD][aA][eE]$") or s:match("([^/]+)$") or s
end

local function flatPt(d, z, nd, nz)
    return {d, z, nd, nz, 0.0, (math.abs(nz) > 0.5) and d * stoneTex or -z * stoneTex, stoneTex, 0.0}
end

local function band(d, h)
    return {use = "", own = true, len = 1.0, d = d, h = h, wrap = true, flat = true,
            uses = {plinth = true, course = true, roofborder = true},
            segs = {{m = flatMat, a = flatPt(0.0, 0.0, 0, -1), b = flatPt(d, 0.0, 0, -1)},
                    {m = flatMat, a = flatPt(d, 0.0, 1, 0), b = flatPt(d, h, 1, 0)},
                    {m = flatMat, a = flatPt(d, h, 0, 1), b = flatPt(0.0, h, 0, 1)}}}
end

local function flatBand(d, h)
    local key = math.floor(d * 1e4 + 0.5) .. "x" .. math.floor(h * 1e4 + 0.5)
    bands[key] = bands[key] or band(d, h)
    return bands[key]
end

local flats = {
    flat_band_10x30     = band(0.1, 0.3),
    flat_pilaster_10x50 = {use = "", own = true, flat = true, uses = {pilaster = true}, d = 0.1, w = 0.5},
    flat_corner_8x50    = {use = "", own = true, flat = true, uses = {corner = true}, d = 0.08, w = 0.5, corner = true},
}

local function find(name)
    local f = flats[name]
    if f then return f, f.segs and "line" or "flat" end
    if Profiles.lines[name] then return Profiles.lines[name], "line" end
    if Profiles.uprights[name] then return Profiles.uprights[name], "upright" end
    if Profiles.quoins[name] then return Profiles.quoins[name], "quoin" end
    return nil
end

local function of(key, dae)
    local name     = nameOf(dae)
    local p, kind  = find(name)
    if not p or (p.use ~= key and not (p.uses and p.uses[key])) then
        name    = defaults[key]
        p, kind = find(name)
    end
    return p, kind, name
end

local function list(key)
    if not names then
        names = {}
        for _, group in ipairs({Profiles.lines, Profiles.uprights, Profiles.quoins}) do
            for name, p in pairs(group) do
                names[p.use]                  = names[p.use] or {}
                names[p.use][#names[p.use] + 1] = name
            end
        end
        for name, p in pairs(flats) do
            for use in pairs(p.uses) do
                names[use]                = names[use] or {}
                names[use][#names[use] + 1] = name
            end
        end
        for _, l in pairs(names) do table.sort(l) end
    end
    return names[key] or {}
end

local function extent(key, dae)
    local p, kind = of(key, dae)
    if kind == "line" then return p.d, p.h end
    if kind == "quoin" then return p.out, math.max(p.long, p.short) end
    if kind == "flat" then return p.d, p.w end
    local out, xlo, xhi = 0.0, math.huge, -math.huge
    for _, part in ipairs(p.meshes) do
        for k = 1, #part.v, 3 do
            out      = math.max(out, -part.v[k + 1])
            xlo, xhi = math.min(xlo, part.v[k]), math.max(xhi, part.v[k])
        end
    end
    if p.corner then return out, math.max(0.0, -xlo) end
    return out, xhi - xlo
end

local function label(name)
    local p = find(name)
    local w, h = tostring(name):match("_(%d+)[xX](%d+)$")
    local base = tostring(name):gsub("_%d+[xX]%d+$", "")
    if p and p.own then base = "MaGE " .. base end
    if not w then return base end
    return string.format("%s  (%g x %g)", base, tonumber(w) / 100.0, tonumber(h) / 100.0)
end

-- =============================================================================
-- MESHES
-- =============================================================================

local function bucket(bk, key, mat, two)
    local id = key .. "|" .. mat
    local sm = bk[id]
    if not sm then
        sm                = {verts = {}, normals = {}, uvs = {}, uvs2 = two and {} or nil, faces = {}, material = mat, module = true, way = key}
        bk[id]            = sm
        bk.order          = bk.order or {}
        bk.order[#bk.order + 1] = id
    end
    return sm
end

local function tri(sm, a, b, c, n)
    if (b.p - a.p):cross(c.p - a.p):dot(n) > 0 then b, c = c, b end
    local i = #sm.verts
    for k, q in ipairs({a, b, c}) do
        sm.verts[i + k], sm.normals[i + k], sm.uvs[i + k] = q.p, q.n or n, q.uv
        if sm.uvs2 then sm.uvs2[i + k] = q.uv2 or {u = 0.0, v = 0.0} end
        sm.faces[#sm.faces + 1] = {v = i + k - 1, n = i + k - 1, u = i + k - 1}
    end
end

local function flush(out, bk)
    for _, id in ipairs(bk.order or {}) do
        local sm = bk[id]
        if #sm.faces > 0 then out[#out + 1] = sm end
    end
end

local function wayOf(nz)
    if nz > 0.7 then return "top" end
    if nz < -0.7 then return "bottom" end
    return "side"
end

-- =============================================================================
-- SECTIONS
-- =============================================================================

local function area(poly)
    local a = 0.0
    for k, p in ipairs(poly) do
        local q = poly[k % #poly + 1]
        a       = a + p[1] * q[2] - q[1] * p[2]
    end
    return a / 2.0
end

local function inside(p, a, b, c)
    local function side(u, v, w) return (v[1] - u[1]) * (w[2] - u[2]) - (v[2] - u[2]) * (w[1] - u[1]) end
    return side(a, b, p) >= 0 and side(b, c, p) >= 0 and side(c, a, p) >= 0
end

local function earcut(poly)
    local idx, out = {}, {}
    for k = 1, #poly do idx[k] = k end
    if area(poly) < 0 then
        local r = {}
        for k = #idx, 1, -1 do r[#r + 1] = idx[k] end
        idx = r
    end
    local guard = 0
    while #idx > 3 and guard < 1000 do
        guard = guard + 1
        local cut = false
        for k = 1, #idx do
            local ia, ib, ic = idx[(k - 2) % #idx + 1], idx[k], idx[k % #idx + 1]
            local a, b, c    = poly[ia], poly[ib], poly[ic]
            local turn       = (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
            if turn > 1e-12 then
                local ear = true
                for _, j in ipairs(idx) do
                    if j ~= ia and j ~= ib and j ~= ic and inside(poly[j], a, b, c) then
                        ear = false
                        break
                    end
                end
                if ear then
                    out[#out + 1] = {ia, ib, ic}
                    table.remove(idx, k)
                    cut = true
                    break
                end
            end
        end
        if not cut then break end
    end
    if #idx == 3 then out[#out + 1] = {idx[1], idx[2], idx[3]} end
    return out
end

local function capOf(p)
    if caps[p] then return caps[p] end
    local function key(q) return math.floor(q[1] * 1e4 + 0.5) .. "," .. math.floor(q[2] * 1e4 + 0.5) end
    local nodes, links = {}, {}
    for _, g in ipairs(p.segs) do
        local ka, kb = key(g.a), key(g.b)
        if ka ~= kb then
            nodes[ka], nodes[kb] = nodes[ka] or g.a, nodes[kb] or g.b
            links[ka], links[kb] = links[ka] or {}, links[kb] or {}
            links[ka][kb], links[kb][ka] = g, g
        end
    end
    local seen, best = {}, {}
    local order      = {}
    for k in pairs(nodes) do order[#order + 1] = k end
    table.sort(order)
    local function degree(k)
        local n = 0
        for _ in pairs(links[k]) do n = n + 1 end
        return n
    end
    for pass = 1, 2 do
        for _, k0 in ipairs(order) do
            if not seen[k0] and (pass == 2 or degree(k0) == 1) then
                local chain, k = {}, k0
                while k and not seen[k] do
                    seen[k]          = true
                    chain[#chain + 1] = {k = k, q = nodes[k]}
                    local nxt        = nil
                    local cand       = {}
                    for j in pairs(links[k]) do cand[#cand + 1] = j end
                    table.sort(cand)
                    for _, j in ipairs(cand) do
                        if not seen[j] then
                            nxt = j
                            break
                        end
                    end
                    k = nxt
                end
                if #chain > #best then best = chain end
            end
        end
    end
    local poly = {}
    for _, c in ipairs(best) do poly[#poly + 1] = {c.q[1], c.q[2], q = c.q} end
    local first, last = poly[1], poly[#poly]
    if #poly >= 2 and not links[best[1].k][best[#best].k] then
        local zlo, zhi = math.huge, -math.huge
        for _, q in ipairs(poly) do zlo, zhi = math.min(zlo, q[2]), math.max(zhi, q[2]) end
        local function wall(q) return math.abs(q[1]) < 1e-3 end
        local function at(q, z) return math.abs(q[2] - z) < 1e-3 end
        for _, z in ipairs({zlo, zhi}) do
            local q = (wall(first) and at(last, z) and not wall(last)) and last or (wall(last) and at(first, z) and not wall(first)) and first or nil
            if q then
                local s    = q.q
                local pt   = {0.0, z, s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10], s[11], s[12]}
                local item = {0.0, z, q = pt}
                if q == last then poly[#poly + 1] = item else table.insert(poly, 1, item) end
                break
            end
        end
    end
    caps[p] = {poly = poly, tris = (#poly >= 3) and earcut(poly) or {}, mat = p.segs[1] and p.segs[1].m}
    return caps[p]
end

local function vert(st, q, kd, kz, x, n, side)
    local e   = st.edge(q[1] * kd * (st.k or 1.0))
    local uv  = {u = q[5] + q[7] * x, v = q[6] + q[8] * x}
    local uv2 = q[9] and {u = q[9] + q[11] * x, v = q[10] + q[12] * x} or nil
    local fn  = st.fa and ((side == "a") and st.fa or st.fb)
    local nn  = n or (fn and (fn * q[3] + up * q[4]) or (st.n * (q[3] / kd) + up * (q[4] / kz))):normalized()
    return {p = vec3(e.x, e.y, st.z + q[2] * kz), n = nn, uv = uv, uv2 = uv2}
end

local function sweep(bk, p, sts, o)
    local kd, kz = o.kd or 1.0, o.kz or 1.0
    local two    = p.segs[1] and p.segs[1].a[9] ~= nil
    local s0     = o.s0 or sts[1].s
    for k = 1, #sts - 1 do
        local A, B = sts[k], sts[k + 1]
        local xa   = p.wrap and (A.s - s0) or A.x0
        local xb   = p.wrap and (B.s - s0) or B.x1
        for j, g in ipairs(p.segs) do
            if not o.only or o.only[j] then
                local sm     = bucket(bk, wayOf(g.a[4]), g.m, two)
                local aA, aB = vert(A, g.a, kd, kz, xa, nil, "b"), vert(B, g.a, kd, kz, xb, nil, "a")
                local bA, bB = vert(A, g.b, kd, kz, xa, nil, "b"), vert(B, g.b, kd, kz, xb, nil, "a")
                local n      = (aA.n + aB.n + bA.n + bB.n):normalized()
                for _, t in ipairs({{aA, aB, bB}, {aA, bB, bA}}) do
                    local c = (t[2].p - t[1].p):cross(t[3].p - t[1].p)
                    if c:dot(n) > 0 then c = c * -1.0 end
                    if c:dot(t[1].n) < 0 and c:dot(t[2].n) < 0 and c:dot(t[3].n) < 0 then tri(sm, t[1], t[2], t[3], n) end
                end
            end
        end
    end
    local cap = capOf(p)
    for e, on in ipairs({o.capA, o.capB}) do
        local st = (e == 1) and sts[1] or sts[#sts]
        if on and #cap.tris > 0 and (st.k or 1.0) > 1e-3 then
            local other = (e == 1) and sts[2] or sts[#sts - 1]
            local n     = vec3(st.p.x - other.p.x, st.p.y - other.p.y, 0):normalized()
            local x     = p.wrap and (st.s - s0) or ((e == 1) and st.x0 or st.x1)
            local sm    = bucket(bk, "side", cap.mat, two)
            for _, t in ipairs(cap.tris) do
                local v = {}
                for j = 1, 3 do v[j] = vert(st, cap.poly[t[j]].q, kd, kz, x, n) end
                tri(sm, v[1], v[2], v[3], n)
            end
        end
    end
end

-- =============================================================================
-- PARTS
-- =============================================================================

local function meshOf(p)
    if shapes[p] then return shapes[p] end
    local out = {}
    for _, part in ipairs(p.meshes) do
        local sm = {m = part.m, v = {}, n = {}, t = {}, t2 = part.t2 and {} or nil}
        for k = 1, #part.v / 3 do
            sm.v[k] = vec3(part.v[3 * k - 2], part.v[3 * k - 1], part.v[3 * k])
            sm.n[k] = vec3(part.n[3 * k - 2], part.n[3 * k - 1], part.n[3 * k])
            sm.t[k] = {u = part.t[2 * k - 1], v = part.t[2 * k]}
            if sm.t2 then sm.t2[k] = {u = part.t2[2 * k - 1], v = part.t2[2 * k]} end
        end
        out[#out + 1] = sm
    end
    shapes[p] = out
    return out
end

local function place(bk, meshes, map, turn)
    for _, part in ipairs(meshes) do
        local sm = bucket(bk, "side", part.m, part.t2 ~= nil)
        for k = 1, #part.v, 3 do
            local i = #sm.verts
            for j = 0, 2 do
                local jj   = (turn and j > 0) and (3 - j) or j
                local p, n = map(part.v[k + jj], part.n[k + jj])
                sm.verts[i + j + 1], sm.normals[i + j + 1], sm.uvs[i + j + 1] = p, n, part.t[k + jj]
                if sm.uvs2 then sm.uvs2[i + j + 1] = part.t2 and part.t2[k + jj] or {u = 0.0, v = 0.0} end
                sm.faces[#sm.faces + 1] = {v = i + j, n = i + j, u = i + j}
            end
        end
    end
end

local function grate(bk, p, o, u, n, kd, kz, ku, turn)
    place(bk, meshOf(p.grate), function(v, q)
        return o + u * (v.x * ku) + n * (v.y * kd) + up * (v.z * kz), (u * (q.x / ku) + n * (q.y / kd) + up * (q.z / kz)):normalized()
    end, turn)
end

local function zMap(p, H)
    local base, cap = p.base, p.h - p.top
    local body      = H - base - cap
    if body <= 0.05 or p.top - base <= 1e-6 then
        local k = H / p.h
        return function(z) return z * k, k end
    end
    local k = body / (p.top - base)
    return function(z)
        if z <= base then return z, 1.0 end
        if z >= p.top then return z - p.top + base + body, 1.0 end
        return base + (z - base) * k, k
    end
end

local function cross(a, b, z)
    local t = (z - a.p.z) / (b.p.z - a.p.z)
    local function mix(x, y) return x and y and {u = x.u + (y.u - x.u) * t, v = x.v + (y.v - x.v) * t} end
    return {p = a.p + (b.p - a.p) * t, n = (a.n + (b.n - a.n) * t):normalized(), uv = mix(a.uv, b.uv), uv2 = mix(a.uv2, b.uv2)}
end

local function keepSide(poly, z, below)
    local out = {}
    for k, a in ipairs(poly) do
        local b      = poly[k % #poly + 1]
        local ia, ib = (a.p.z <= z) == below, (b.p.z <= z) == below
        if ia then out[#out + 1] = a end
        if ia ~= ib then out[#out + 1] = cross(a, b, z) end
    end
    return out
end

local function chains(segs)
    local function spot(v) return math.floor(v.x * 1e4 + 0.5) .. "," .. math.floor(v.y * 1e4 + 0.5) end
    local ends, used, out = {}, {}, {}
    for i, sg in ipairs(segs) do
        for _, e in ipairs({sg[1], sg[2]}) do
            local k = spot(e)
            ends[k] = ends[k] or {}
            table.insert(ends[k], i)
        end
    end
    for i in ipairs(segs) do
        if not used[i] then
            used[i]    = true
            local line = {segs[i][1], segs[i][2]}
            local grow = true
            while grow do
                grow = false
                for _, j in ipairs(ends[spot(line[#line])] or {}) do
                    if not used[j] then
                        used[j]          = true
                        local a, b       = segs[j][1], segs[j][2]
                        line[#line + 1]  = (spot(a) == spot(line[#line])) and b or a
                        grow             = true
                        break
                    end
                end
            end
            if spot(line[1]) == spot(line[#line]) then line[#line] = nil end
            if #line >= 3 then out[#out + 1] = line end
        end
    end
    return out
end

local function clip(bk, tmp, gaps)
    for _, id in ipairs(tmp.order or {}) do
        local sm   = tmp[id]
        local dst  = bucket(bk, sm.way, sm.material, sm.uvs2 ~= nil)
        local cuts = {}
        for k = 1, #sm.faces, 3 do
            local poly = {}
            for j = 0, 2 do
                local f      = sm.faces[k + j]
                poly[j + 1]  = {p = sm.verts[f.v + 1], n = sm.normals[f.n + 1], uv = sm.uvs[f.u + 1], uv2 = sm.uvs2 and sm.uvs2[f.u + 1]}
            end
            local pieces = {poly}
            for _, g in ipairs(gaps) do
                local left = {}
                for _, pc in ipairs(pieces) do
                    for _, side in ipairs({{g[1], true}, {g[2], false}}) do
                        local kept = keepSide(pc, side[1], side[2])
                        if #kept >= 3 then left[#left + 1] = kept end
                    end
                end
                pieces = left
                for _, z in ipairs({g[1], g[2]}) do
                    local hit = {}
                    for j = 1, 3 do
                        local a, b = poly[j], poly[j % 3 + 1]
                        if (a.p.z < z) ~= (b.p.z < z) then hit[#hit + 1] = cross(a, b, z).p end
                    end
                    if #hit == 2 then
                        cuts[z] = cuts[z] or {}
                        table.insert(cuts[z], {hit[1], hit[2]})
                    end
                end
            end
            local n = (poly[1].n + poly[2].n + poly[3].n):normalized()
            for _, pc in ipairs(pieces) do
                for q = 2, #pc - 1 do tri(dst, pc[1], pc[q], pc[q + 1], n) end
            end
        end
        for _, g in ipairs(gaps) do
            for e, z in ipairs({g[1], g[2]}) do
                local n = (e == 1) and up or (up * -1.0)
                for _, line in ipairs(chains(cuts[z] or {})) do
                    local poly = {}
                    for _, v in ipairs(line) do poly[#poly + 1] = {v.x, v.y, q = v} end
                    for _, t in ipairs(earcut(poly)) do
                        local c = {}
                        for j = 1, 3 do
                            local v = poly[t[j]].q
                            c[j]    = {p = vec3(v.x, v.y, z), n = n, uv = {u = v.x * stoneTex, v = v.y * stoneTex}}
                        end
                        tri(dst, c[1], c[2], c[3], n)
                    end
                end
            end
        end
    end
end

local function merged(gaps)
    local all = {}
    for _, g in ipairs(gaps or {}) do all[#all + 1] = {g[1], g[2]} end
    table.sort(all, function(a, b) return a[1] < b[1] end)
    local out = {}
    for _, g in ipairs(all) do
        local last = out[#out]
        if last and g[1] <= last[2] then last[2] = math.max(last[2], g[2]) else out[#out + 1] = g end
    end
    return out
end

local function upright(bk, p, o, H, plan, turn, gaps)
    gaps      = merged(gaps)
    local zOf = zMap(p, H)
    local dst = (gaps and #gaps > 0) and {} or bk
    place(dst, meshOf(p), function(v, q)
        local off, nn = plan(v, q)
        local z, k    = zOf(v.z)
        return o + off + up * z, (nn + up * (q.z / k)):normalized()
    end, turn)
    if dst ~= bk then clip(bk, dst, gaps) end
end

-- =============================================================================
-- STONES
-- =============================================================================

local function meet(a, da, b, db)
    local den = da.x * db.y - da.y * db.x
    if math.abs(den) < 1e-9 then return nil end
    local w = b - a
    local t = (w.x * db.y - w.y * db.x) / den
    return a + da * t
end

local function outline(c, A1, A2, out, cut)
    local n1, n2 = c.n1, c.n2
    local mit    = (n1 + n2) * (1.0 / math.max(0.2, 1.0 + n1:dot(n2)))
    local front  = c.p + mit * out
    local pts    = {c.p + c.d2 * A2, c.p + c.d2 * A2 + n2 * out}
    if cut > 1e-4 then
        pts[#pts + 1] = front + c.d2 * cut
        pts[#pts + 1] = front + c.d1 * cut
    else
        pts[#pts + 1] = front
    end
    pts[#pts + 1] = c.p + c.d1 * A1 + n1 * out
    pts[#pts + 1] = c.p + c.d1 * A1
    return pts
end

local function shrink(pts, c, e)
    if e <= 1e-6 then return pts end
    local edges = {}
    for k = 1, #pts - 1 do
        local a, b = pts[k], pts[k + 1]
        local d    = vec3(b.x - a.x, b.y - a.y, 0):normalized()
        local mid  = (a + b) * 0.5
        local m    = vec3(-d.y, d.x, 0)
        if m:dot(c.p - mid) < 0 then m = m * -1.0 end
        edges[k] = {a = a + m * e, d = d}
    end
    local out = {meet(c.p, c.d2, edges[1].a, edges[1].d) or pts[1]}
    for k = 1, #edges - 1 do out[#out + 1] = meet(edges[k].a, edges[k].d, edges[k + 1].a, edges[k + 1].d) or pts[k + 1] end
    out[#out + 1] = meet(c.p, c.d1, edges[#edges].a, edges[#edges].d) or pts[#pts]
    return out
end

local function prism(bk, mat, rings, c, u0, two, uv2)
    local closed = {}
    for _, q in ipairs(rings[1].pts) do closed[#closed + 1] = q end
    closed[#closed + 1] = c.p
    local ccw = 0.0
    for k, q in ipairs(closed) do
        local r = closed[k % #closed + 1]
        ccw     = ccw + q.x * r.y - r.x * q.y
    end
    local sm = bucket(bk, "side", mat, two)
    local function v(q, z, n, run) return {p = vec3(q.x, q.y, z), n = n, uv = {u = u0 + run * stoneTex, v = -z * stoneTex}, uv2 = uv2} end
    for r = 1, #rings - 1 do
        local lo, hi = rings[r], rings[r + 1]
        local run    = 0.0
        for k = 1, #lo.pts - 1 do
            local a, b   = lo.pts[k], lo.pts[k + 1]
            local c2, d2 = hi.pts[k], hi.pts[k + 1]
            local e      = vec3(b.x - a.x, b.y - a.y, 0)
            local side   = vec3(e.y, -e.x, 0):normalized()
            if ccw < 0 then side = side * -1.0 end
            local n      = (vec3(b.x - a.x, b.y - a.y, 0):cross(vec3(c2.x - a.x, c2.y - a.y, hi.z - lo.z))):normalized()
            if n:dot(side) < 0 then n = n * -1.0 end
            local l      = e:length()
            local qa, qb = v(a, lo.z, n, run), v(b, lo.z, n, run + l)
            local qc, qd = v(d2, hi.z, n, run + l), v(c2, hi.z, n, run)
            tri(sm, qa, qb, qc, n)
            tri(sm, qa, qc, qd, n)
            run = run + l
        end
    end
    for e, ring in ipairs({rings[1], rings[#rings]}) do
        local poly = {}
        for _, q in ipairs(ring.pts) do poly[#poly + 1] = {q.x, q.y, q = q} end
        poly[#poly + 1] = {c.p.x, c.p.y, q = c.p}
        local n         = (e == 1) and (up * -1.0) or up
        local smc       = bucket(bk, (e == 1) and "bottom" or "top", mat, two)
        for _, t in ipairs(earcut(poly)) do
            local q = {}
            for j = 1, 3 do
                local pt = poly[t[j]].q
                q[j]     = {p = vec3(pt.x, pt.y, ring.z), n = n, uv = {u = u0 + pt.x * stoneTex, v = pt.y * stoneTex}, uv2 = uv2}
            end
            tri(smc, q[1], q[2], q[3], n)
        end
    end
end

local function quoin(bk, p, c, z0, H, o)
    local kd, kl  = o.kd or 1.0, o.kl or 1.0
    local pitch   = o.pitch or p.pitch
    local count   = math.max(1, math.floor(H / pitch + 0.5))
    local step    = H / count
    local joint   = math.min(p.joint, step * 0.3)
    local bevel   = math.min(p.bevel, (step - joint) * 0.3)
    local out     = p.out * kd
    local inset   = math.min(p.bevelIn * kd, out * 0.5)
    local long    = (o.long or p.long) * kl
    local short   = (o.short or p.short) * kl
    local two     = p.uv2 ~= nil
    local uv2     = p.uv2 and {u = p.uv2[1], v = p.uv2[2]} or nil
    local mortar  = outline(c, short, short, p.mortar * kd, math.max(0.0, p.chamfer * kd - (p.out - p.mortar) * kd))
    prism(bk, p.m, {{pts = mortar, z = z0}, {pts = mortar, z = z0 + H}}, c, 0.0, two, uv2)
    for k = 0, count - 1 do
        if not (o.skip and o.skip(z0 + k * step, z0 + (k + 1) * step)) then
            local a1, a2 = (k % 2 == 0) and long or short, (k % 2 == 0) and short or long
            local full   = outline(c, a1, a2, out, p.chamfer * kd)
            local small  = shrink(full, c, inset)
            local zb, zt = z0 + k * step + joint / 2.0, z0 + (k + 1) * step - joint / 2.0
            prism(bk, p.m, {{pts = small, z = zb}, {pts = full, z = zb + bevel}, {pts = full, z = zt - bevel}, {pts = small, z = zt}}, c, k * stoneRun, two, uv2)
        end
    end
end

-- =============================================================================
-- FLAT FRONTS
-- =============================================================================

local function frontOf(d, za, zb, zs, segs)
    local cuts = {za}
    for _, z in ipairs(zs) do
        if z > za + 1e-6 and z < zb - 1e-6 then cuts[#cuts + 1] = z end
    end
    table.sort(cuts)
    cuts[#cuts + 1] = zb
    for k = 1, #cuts - 1 do segs[#segs + 1] = {m = flatMat, a = flatPt(d, cuts[k], 1, 0), b = flatPt(d, cuts[k + 1], 1, 0)} end
    return segs
end

local function holeOf(p, z0, z1, zs)
    local d, h = p.d, p.h
    local segs = {}
    if not z0 then
        frontOf(d, 0.0, h, zs, segs)
        return {len = p.len, wrap = true, d = d, h = h, segs = segs}
    end
    frontOf(d, 0.0, z0, zs, segs)
    segs[#segs + 1] = {m = flatMat, a = flatPt(d, z0, 0, 1), b = flatPt(0.0, z0, 0, 1)}
    segs[#segs + 1] = {m = flatMat, a = flatPt(0.0, z1, 0, -1), b = flatPt(d, z1, 0, -1)}
    frontOf(d, z1, h, zs, segs)
    return {len = p.len, wrap = true, d = d, h = h, segs = segs}
end

local function reveal(bk, p, st, z0, z1, n, kd, kz)
    local sm = bucket(bk, "side", flatMat, false)
    local q  = {}
    for k, c in ipairs({{0.0, z0}, {p.d, z0}, {p.d, z1}, {0.0, z1}}) do
        local e = st.edge(c[1] * kd * (st.k or 1.0))
        q[k]    = {p = vec3(e.x, e.y, st.z + c[2] * kz), n = n, uv = {u = c[1] * stoneTex, v = -c[2] * stoneTex}}
    end
    tri(sm, q[1], q[2], q[3], n)
    tri(sm, q[1], q[3], q[4], n)
end

local function quad(sm, a, b, c, d, n)
    tri(sm, a, b, c, n)
    tri(sm, a, c, d, n)
end

local function panel(bk, A, B, za, zb, holes, n, depth, u0)
    local sm   = bucket(bk, "side", flatMat, false)
    local dir  = vec3(B.x - A.x, B.y - A.y, 0)
    local L    = dir:length()
    if L < 1e-6 then return end
    dir        = dir * (1.0 / L)
    local ts, zs = {0.0, L}, {za, zb}
    for _, h in ipairs(holes) do
        ts[#ts + 1], ts[#ts + 2] = h[1], h[2]
        zs[#zs + 1], zs[#zs + 2] = h[3], h[4]
    end
    table.sort(ts)
    table.sort(zs)
    local function pt(t, z, nn, back)
        local q = A + dir * t - n * (back or 0.0)
        return {p = vec3(q.x, q.y, z), n = nn, uv = {u = (u0 + t) * stoneTex, v = -z * stoneTex}}
    end
    for i = 1, #ts - 1 do
        for j = 1, #zs - 1 do
            local t0, t1, z0, z1 = ts[i], ts[i + 1], zs[j], zs[j + 1]
            if t1 - t0 > 1e-6 and z1 - z0 > 1e-6 then
                local tm, zm, open = (t0 + t1) / 2.0, (z0 + z1) / 2.0, false
                for _, h in ipairs(holes) do open = open or (tm > h[1] and tm < h[2] and zm > h[3] and zm < h[4]) end
                if not open then quad(sm, pt(t0, z0, n), pt(t1, z0, n), pt(t1, z1, n), pt(t0, z1, n), n) end
            end
        end
    end
    for _, h in ipairs(holes) do
        local t0, t1, z0, z1 = h[1], h[2], h[3], h[4]
        quad(sm, pt(t0, z0, up), pt(t1, z0, up), pt(t1, z0, up, depth), pt(t0, z0, up, depth), up)
        quad(sm, pt(t0, z1, up * -1.0), pt(t1, z1, up * -1.0), pt(t1, z1, up * -1.0, depth), pt(t0, z1, up * -1.0, depth), up * -1.0)
        quad(sm, pt(t0, z0, dir), pt(t0, z1, dir), pt(t0, z1, dir, depth), pt(t0, z0, dir, depth), dir)
        quad(sm, pt(t1, z0, dir * -1.0), pt(t1, z1, dir * -1.0), pt(t1, z1, dir * -1.0, depth), pt(t1, z0, dir * -1.0, depth), dir * -1.0)
    end
end

local function box(bk, pts, close, z0, z1, holes, depth)
    local ring = {}
    for _, q in ipairs(pts) do ring[#ring + 1] = q end
    if close then ring[#ring + 1] = close end
    local ccw = 0.0
    for k, q in ipairs(ring) do
        local r = ring[k % #ring + 1]
        ccw     = ccw + q.x * r.y - r.x * q.y
    end
    local run = 0.0
    for k = 1, #pts - 1 do
        local a, b = pts[k], pts[k + 1]
        local e    = vec3(b.x - a.x, b.y - a.y, 0)
        local n    = vec3(e.y, -e.x, 0):normalized()
        if ccw < 0 then n = n * -1.0 end
        local kept = {}
        for _, h in ipairs(holes[k] or {}) do
            if h[3] >= z0 - 1e-6 and h[4] <= z1 + 1e-6 then kept[#kept + 1] = h end
        end
        panel(bk, a, b, z0, z1, kept, n, depth, run)
        run = run + e:length()
    end
    local poly = {}
    for _, q in ipairs(ring) do poly[#poly + 1] = {q.x, q.y, q = q} end
    for e, z in ipairs({z0, z1}) do
        local n  = (e == 1) and (up * -1.0) or up
        local sm = bucket(bk, (e == 1) and "bottom" or "top", flatMat, false)
        for _, t in ipairs(earcut(poly)) do
            local q = {}
            for j = 1, 3 do
                local v = poly[t[j]].q
                q[j]    = {p = vec3(v.x, v.y, z), n = n, uv = {u = v.x * stoneTex, v = v.y * stoneTex}}
            end
            tri(sm, q[1], q[2], q[3], n)
        end
    end
end

local function flatUp(bk, pts, close, z0, H, holes, gaps, depth)
    local from = z0
    for _, g in ipairs(merged(gaps)) do
        if g[2] > from and g[1] < z0 + H then
            if g[1] - from > 1e-3 then box(bk, pts, close, from, g[1], holes, depth) end
            from = math.max(from, g[2])
        end
    end
    if z0 + H - from > 1e-3 then box(bk, pts, close, from, z0 + H, holes, depth) end
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.defaults = defaults
M.nameOf   = nameOf
M.find     = find
M.of       = of
M.list     = list
M.extent   = extent
M.label    = label
M.sweep    = sweep
M.grate    = grate
M.upright  = upright
M.quoin    = quoin
M.flush    = flush
M.flatBand = flatBand
M.outline  = outline
M.holeOf   = holeOf
M.reveal   = reveal
M.flatUp   = flatUp

return M
