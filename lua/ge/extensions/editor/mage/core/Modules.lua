-- =============================================================================
-- MaGE - Building Architect modules
-- Version: 1.0.2
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M      = {}
local logTag = 'mage'

local Collada = require("editor/mage/core/Collada")

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local root    = "/art/shapes/common/building_architect_modules/"
local modular = "/assets/meshes/architecture/modular/"
local own     = "/lua/ge/extensions/editor/mage/models/"
local defWin  = root .. "windows/R_HS_A_WN_01_120x130.dae"
local defDoor = root .. "doors/R_HS_A_DR_01_100x210.dae"

local kinds = {
    windows    = "windows",
    doors      = "doors",
    balcony    = "balcony",
    stairs     = "stairs",
    pillar     = "pillar",
}

local moved = {
    balcony = "decorative_elements/balconies",
    stairs  = "architectural_elements/stairs_platforms",
    pillar  = "architectural_elements/columns_pillars",
}

local defaults = {
    windows    = defWin,
    doors      = defDoor,
    balcony    = root .. "balcony/R_B_BA_01_200x110.dae",
    stairs     = root .. "stairs/R_HS_A_ST_01_130X60.dae",
    pillar     = root .. "pillar/C_HO_G_PL_01_100x400.dae",
    ac         = own .. "ac_unit.dae",
    dish       = own .. "sat_dish.dae",
    awning     = own .. "awning.dae",
    flowers    = own .. "flower_box.dae",
    pots       = own .. "plant_pot.dae",
    roofac     = own .. "roof_ac.dae",
    roofdish   = own .. "roof_dish.dae",
    corbel     = own .. "corbel.dae",
    pipe       = own .. "pipe_part.dae",
}

local extras = {
    windows = {own .. "window_ac_90x159.dae"},
    ac      = {own .. "ac_unit.dae", own .. "ac_box.dae"},
}

local pipeParts = {base = own .. "pipe_base.dae", head = own .. "pipe_head.dae"}

local mainMats    = "/art/main.materials.json"
local clutterMats = "/art/shapes/garage_and_dealership/Clutter/main.materials.json"

local tintSrc = {
    italy_bld_fabric        = mainMats,
    italy_guardrails        = "/art/shapes/objects/main.materials.json",
    generibush_leaves       = "/levels/italy/art/shapes/trees/trees_italy/main.materials.json",
    italy_bld_concrete      = mainMats,
    italy_bld_trim_concrete = mainMats,
    italy_terrain_dirt      = mainMats,
    italy_bld_details_metal = mainMats,
    italy_bld_metal         = clutterMats,
    italy_bld_trim_metal    = clutterMats,
}

local levelMats = {
    eca_bld_house_decoration = "/levels/east_coast_usa/art/shapes/buildings/main.materials.json",
    eca_doors_windows        = "/levels/east_coast_usa/art/shapes/buildings/main.materials.json",
    generibush_leaves        = "/levels/italy/art/shapes/trees/trees_italy/main.materials.json",
}

local tileEnd    = 0.25
local awningOver = 0.15
local hallMin    = 1.2
local hallGap    = 0.15
local openShare  = 0.5
local darkMat    = "mage_dark_entry"
local holePad    = 0.06

-- =============================================================================
-- STATE
-- =============================================================================

local models   = {}
local lists    = {}
local files    = {}
local trees    = {}
local resolved = {}
local doors    = {}

-- =============================================================================
-- MODELS
-- =============================================================================

local function lead(f)
    local p = tostring(f)
    return (p:sub(1, 1) == "/") and p or ("/" .. p)
end

local function tree(dir)
    if trees[dir] then return trees[dir] end
    local out = {}
    for _, f in ipairs(FS:findFiles(dir, "*.dae", -1, true, false) or {}) do
        local p    = lead(f)
        local name = p:match("([^/]+)$"):lower()
        out[name]  = out[name] or p
    end
    trees[dir] = out
    return out
end

local function resolve(path)
    if type(path) ~= "string" then return path end
    local hit = resolved[path]
    if hit then return hit end
    local low   = path:lower()
    local other = (low:sub(1, #root) == root) and modular or (low:sub(1, #modular) == modular) and root or nil
    local out   = path
    if other and not FS:fileExists(path) then out = tree(other)[(path:match("([^/]+)$") or ""):lower()] or path end
    resolved[path] = out
    return out
end

local function layout()
    return next(tree(modular)) and "modular" or "classic"
end

local function model(path)
    local hit = models[path]
    if hit ~= nil then return hit or nil end
    local file   = resolve(path)
    local text   = readFile(file)
    local meshes = type(text) == "string" and Collada.read(text) or nil
    if not meshes or #meshes == 0 then
        models[path] = false
        log('E', logTag, "cannot read module " .. tostring(path))
        return nil
    end
    local lo   = {x = math.huge, y = math.huge, z = math.huge}
    local hi   = {x = -math.huge, y = -math.huge, z = -math.huge}
    local ours = file:sub(1, #own) == own
    for _, sm in ipairs(meshes) do
        if ours then sm.tint = nil end
        for _, v in ipairs(sm.verts) do
            lo.x, lo.y, lo.z = math.min(lo.x, v.x), math.min(lo.y, v.y), math.min(lo.z, v.z)
            hi.x, hi.y, hi.z = math.max(hi.x, v.x), math.max(hi.y, v.y), math.max(hi.z, v.z)
        end
    end
    local m      = {meshes = meshes, lo = lo, hi = hi, path = file}
    models[path] = m
    models[file] = m
    return m
end

local function size(path)
    local w, h = tostring(path):match("_(%d+)[xX](%d+)%.dae$")
    if not w then return nil end
    return tonumber(w) / 100.0, tonumber(h) / 100.0
end

local function hole(path)
    local w, h = size(path)
    local p    = tostring(path)
    if not w or not (p:find("/doors/", 1, true) or p:find("_DR_", 1, true)) then return w, h end
    local m = model(path)
    if not m then return w, h end
    return (m.hi.x - m.lo.x) - 2.0 * holePad, (m.hi.z - m.lo.z) - holePad
end

local function sill(path)
    local p = tostring(path)
    if not size(path) or p:find("/doors/", 1, true) or p:find("_DR_", 1, true) or resolve(path):sub(1, #own) == own then return 0.0 end
    return holePad
end

local function found(kind)
    if files[kind] then return files[kind] end
    local out, seen = {}, {}
    for _, dir in ipairs(kinds[kind] and {root .. kinds[kind], moved[kind] and (modular .. moved[kind])} or {}) do
        for _, f in ipairs(FS:findFiles(dir, "*.dae", -1, true, false) or {}) do
            local p    = lead(f)
            local name = p:match("([^/]+)$"):lower()
            if size(p) and not seen[name] then
                seen[name]    = true
                out[#out + 1] = p
            end
        end
    end
    table.sort(out)
    for _, p in ipairs(extras[kind] or {}) do out[#out + 1] = p end
    files[kind] = out
    return out
end

local function list(kind)
    if lists[kind] then return lists[kind] end
    local out = {}
    for _, p in ipairs(found(kind)) do out[#out + 1] = p end
    lists[kind] = out
    return out
end

local function label(path)
    local name = tostring(path):match("([^/]+)%.dae$") or tostring(path)
    if tostring(path):sub(1, #own) == own then name = "MaGE " .. name end
    local w, h = size(path)
    if not w then return name end
    return string.format("%s  (%g x %g)", (name:gsub("_%d+[xX]%d+$", "")), w, h)
end

-- =============================================================================
-- PLACING
-- =============================================================================

local function put(m, t)
    local o, X, Y, Z = t.o, t.x, t.y, t.z
    local sx, sy, sz = t.sx or 1.0, t.sy or 1.0, t.sz or 1.0
    local pv         = t.pv
    local out        = {}
    local inst       = (m.path and (models[m.path] == m or m.key)) and {path = m.path, key = m.key, model = m, o = vec3(o), x = vec3(X), y = vec3(Y), z = vec3(Z),
                                                                     pv = vec3(pv), s = vec3(sx, sy, sz), n = #m.meshes} or nil
    local ox, oy, oz    = o.x, o.y, o.z
    local xx, xy, xz    = X.x * sx, X.y * sx, X.z * sx
    local yx, yy, yz    = Y.x * sy, Y.y * sy, Y.z * sy
    local zx, zy, zz    = Z.x * sz, Z.y * sz, Z.z * sz
    local nx1, ny1, nz1 = X.x / sx, X.y / sx, X.z / sx
    local nx2, ny2, nz2 = Y.x / sy, Y.y / sy, Y.z / sy
    local nx3, ny3, nz3 = Z.x / sz, Z.y / sz, Z.z / sz
    local px, py, pz    = pv.x, pv.y, pv.z
    for _, sm in ipairs(m.meshes) do
        local r = {verts = {}, normals = {}, uvs = sm.uvs, uvs2 = sm.uvs2, faces = sm.faces, material = sm.material, module = true, inst = inst, tint = sm.tint}
        for i, v in ipairs(sm.verts) do
            local a, b, c = v.x - px, v.y - py, v.z - pz
            r.verts[i]    = vec3(ox + xx * a + yx * b + zx * c, oy + xy * a + yy * b + zy * c, oz + xz * a + yz * b + zz * c)
        end
        for i, n in ipairs(sm.normals) do
            local x, y, z = nx1 * n.x + nx2 * n.y + nx3 * n.z, ny1 * n.x + ny2 * n.y + ny3 * n.z, nz1 * n.x + nz2 * n.y + nz3 * n.z
            local l       = math.sqrt(x * x + y * y + z * z)
            r.normals[i]  = (l > 1e-30) and vec3(x / l, y / l, z / l) or vec3(0, 0, 0)
        end
        out[#out + 1] = r
    end
    return out
end

local function mix(p, q, t)
    return {x = p.x + (q.x - p.x) * t, y = p.y + (q.y - p.y) * t, z = p.z + (q.z - p.z) * t}
end

local function corner(sm, i)
    return {p = sm.verts[i], n = sm.normals[i], uv = sm.uvs[i], uv2 = sm.uvs2 and sm.uvs2[i]}
end

local function cross(c, d, a, at)
    local t = (at - c.p[a]) / (d.p[a] - c.p[a])
    local n = mix(c.n, d.n, t)
    local l = math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
    if l > 1e-12 then n = {x = n.x / l, y = n.y / l, z = n.z / l} end
    local function uv(p, q) return p and q and {u = p.u + (q.u - p.u) * t, v = p.v + (q.v - p.v) * t} end
    return {p = mix(c.p, d.p, t), n = n, uv = uv(c.uv, d.uv), uv2 = uv(c.uv2, d.uv2)}
end

local function clip(poly, a, at, keep)
    local out = {}
    for k, c in ipairs(poly) do
        local d      = poly[k % #poly + 1]
        local ci, di = keep * (c.p[a] - at) >= 0, keep * (d.p[a] - at) >= 0
        if ci then out[#out + 1] = c end
        if ci ~= di then out[#out + 1] = cross(c, d, a, at) end
    end
    return out
end

local function cutMeshes(m, a, cutsOf)
    local meshes = {}
    for _, sm in ipairs(m.meshes) do
        local r = {verts = {}, normals = {}, uvs = {}, uvs2 = sm.uvs2 and {}, faces = {}, material = sm.material, tint = sm.tint}
        local function push(c)
            local i       = #r.verts
            r.verts[i + 1], r.normals[i + 1], r.uvs[i + 1] = c.p, c.n, c.uv
            if r.uvs2 then r.uvs2[i + 1] = c.uv2 end
            r.faces[#r.faces + 1] = {v = i, n = i, u = i}
        end
        for k = 1, #sm.faces, 3 do
            local tri    = {corner(sm, sm.faces[k].v + 1), corner(sm, sm.faces[k + 1].v + 1), corner(sm, sm.faces[k + 2].v + 1)}
            local lo, hi = math.huge, -math.huge
            for _, c in ipairs(tri) do lo, hi = math.min(lo, c.p[a]), math.max(hi, c.p[a]) end
            local cuts = {lo}
            for _, c in ipairs(cutsOf(lo, hi)) do
                if c > lo + 1e-6 and c < hi - 1e-6 then cuts[#cuts + 1] = c end
            end
            cuts[#cuts + 1] = hi
            if #cuts == 2 then
                for _, c in ipairs(tri) do push(c) end
            else
                for j = 1, #cuts - 1 do
                    local poly = tri
                    if j > 1 then poly = clip(poly, a, cuts[j], 1) end
                    if j < #cuts - 1 then poly = clip(poly, a, cuts[j + 1], -1) end
                    for q = 2, #poly - 1 do push(poly[1]) push(poly[q]) push(poly[q + 1]) end
                end
            end
        end
        meshes[#meshes + 1] = r
    end
    return {meshes = meshes, lo = m.lo, hi = m.hi, path = m.path}
end

local function cutAt(m, a, list)
    table.sort(list)
    return cutMeshes(m, a, function() return list end)
end

local function place(m, origin, inward)
    local Y = vec3(inward.x, inward.y, 0):normalized()
    local Z = vec3(0, 0, 1)
    return put(m, {o = origin, x = Y:cross(Z), y = Y, z = Z, pv = vec3(0, 0, m.lo.z)})
end

local function axes(m, width)
    local ex, ey = m.hi.x - m.lo.x, m.hi.y - m.lo.y
    local a      = (ey > ex) and "y" or "x"
    if width and math.abs(ex - ey) > 1e-6 then
        a = (math.abs(ey - width) < math.abs(ex - width)) and "y" or "x"
    end
    local d   = (a == "x") and "y" or "x"
    local out = (math.abs(m.hi[d]) >= math.abs(m.lo[d])) and 1 or -1
    return a, d, out
end

local function cells(m, a, ca, d, cd)
    local key = a .. table.concat(ca, ",") .. d .. table.concat(cd, ",")
    m.tiles   = m.tiles or {}
    if m.tiles[key] then return m.tiles[key] end
    local cut  = cutMeshes(cutMeshes(m, a, function() return ca end), d, function() return cd end)
    local grid = {}
    local function slot(list, v)
        local k = 1
        while k <= #list and v > list[k] do k = k + 1 end
        return k
    end
    for _, sm in ipairs(cut.meshes) do
        for k = 1, #sm.faces, 3 do
            local tri = {corner(sm, sm.faces[k].v + 1), corner(sm, sm.faces[k + 1].v + 1), corner(sm, sm.faces[k + 2].v + 1)}
            local i   = slot(ca, (tri[1].p[a] + tri[2].p[a] + tri[3].p[a]) / 3.0)
            local j   = slot(cd, (tri[1].p[d] + tri[2].p[d] + tri[3].p[d]) / 3.0)
            grid[i]    = grid[i] or {}
            grid[i][j] = grid[i][j] or {meshes = {}, byMat = {}, path = m.path, key = (m.key and (m.key .. "_") or "") .. "t" .. a .. i .. d .. j .. ((#cd > 0) and "s" or "")}
            local cell = grid[i][j]
            local r    = cell.byMat[sm.material]
            if not r then
                r                          = {verts = {}, normals = {}, uvs = {}, uvs2 = sm.uvs2 and {}, faces = {}, material = sm.material, tint = sm.tint}
                cell.byMat[sm.material]    = r
                cell.meshes[#cell.meshes + 1] = r
            end
            for _, c in ipairs(tri) do
                local n                          = #r.verts
                r.verts[n + 1], r.normals[n + 1] = vec3(c.p.x, c.p.y, c.p.z), c.n
                r.uvs[n + 1]                     = c.uv or {u = 0.0, v = 0.0}
                if r.uvs2 then r.uvs2[n + 1] = c.uv2 or {u = 0.0, v = 0.0} end
                r.faces[#r.faces + 1] = {v = n, n = n, u = n}
            end
        end
    end
    m.tiles[key] = grid
    return grid
end

local function spans(lo, hi, L, anchor)
    local e   = (hi - lo) * tileEnd
    local mid = (hi - lo) - 2.0 * e
    local c0  = anchor or ((lo + hi) / 2.0 - L / 2.0)
    local out = {}
    local function add(i, s0, s1, w)
        out[#out + 1] = {i = i, s0 = s0, s1 = s1, c0 = c0, c1 = c0 + w}
        c0            = c0 + w
    end
    local n = (L - 2.0 * e > mid * 0.25) and math.max(1, math.floor((L - 2.0 * e) / mid + 0.5)) or 0
    local k = (n == 0) and L / (2.0 * e) or 1.0
    add(1, lo, lo + e, e * k)
    for _ = 1, n do add(2, lo + e, hi - e, (L - 2.0 * e) / n) end
    add(3, hi - e, hi, e * k)
    return out
end

local function tile(m, a, d, o, len, extra)
    local depth = m.hi[d] - m.lo[d]
    if math.abs(len - (m.hi[a] - m.lo[a])) < 1e-3 and extra < 1e-3 then
        return {{m = m, a = {s0 = 0.0, s1 = 1.0, c0 = 0.0, c1 = 1.0}, d = {s0 = 0.0, s1 = 1.0, c0 = 0.0, c1 = 1.0}}}
    end
    local ea   = (m.hi[a] - m.lo[a]) * tileEnd
    local ed   = depth * tileEnd
    local ca   = {m.lo[a] + ea, m.hi[a] - ea}
    local cd   = (extra > 1e-3) and {m.lo[d] + ed, m.hi[d] - ed} or {}
    local grid = cells(m, a, ca, d, cd)
    local da   = spans(m.lo[a], m.hi[a], len)
    local dd   = (extra > 1e-3) and spans(m.lo[d], m.hi[d], depth + extra, (o > 0) and m.lo[d] or (m.lo[d] - extra))
                 or {{i = 1, s0 = 0.0, s1 = 1.0, c0 = 0.0, c1 = 1.0}}
    local out = {}
    for _, sa in ipairs(da) do
        for _, sd in ipairs(dd) do
            local cell = grid[sa.i] and grid[sa.i][(#cd > 0) and sd.i or 1]
            if cell then out[#out + 1] = {m = cell, a = sa, d = sd} end
        end
    end
    return out
end

local function fit(t, piece, a, d)
    local r = {o = t.o, x = t.x, y = t.y, z = t.z, pv = vec3(t.pv), sz = t.sz}
    for _, e in ipairs({{a, piece.a}, {d, piece.d}}) do
        local k        = (e[2].c1 - e[2].c0) / (e[2].s1 - e[2].s0)
        r.pv[e[1]]     = e[2].s0 - (e[2].c0 - t.pv[e[1]]) / k
        r["s" .. e[1]] = k
    end
    return r
end

local function join(pieces, a, d)
    local meshes = {}
    local lo     = {x = math.huge, y = math.huge, z = math.huge}
    local hi     = {x = -math.huge, y = -math.huge, z = -math.huge}
    local base   = {o = vec3(0, 0, 0), x = vec3(1, 0, 0), y = vec3(0, 1, 0), z = vec3(0, 0, 1), pv = vec3(0, 0, 0)}
    for _, piece in ipairs(pieces) do
        for _, sm in ipairs(put(piece.m, fit(base, piece, a, d))) do
            sm.inst              = nil
            meshes[#meshes + 1]  = sm
            for _, v in ipairs(sm.verts) do
                lo.x, lo.y, lo.z = math.min(lo.x, v.x), math.min(lo.y, v.y), math.min(lo.z, v.z)
                hi.x, hi.y, hi.z = math.max(hi.x, v.x), math.max(hi.y, v.y), math.max(hi.z, v.z)
            end
        end
    end
    return {meshes = meshes, lo = lo, hi = hi}
end

local function split(m)
    if m.parts ~= nil then return m.parts or nil end
    local levels, top = {}, nil
    local mid         = m.lo.z + (m.hi.z - m.lo.z) * 0.5
    local foot        = (m.hi.x - m.lo.x) * (m.hi.y - m.lo.y)
    for _, sm in ipairs(m.meshes) do
        for k = 1, #sm.faces, 3 do
            local A, B, C = vec3(sm.verts[sm.faces[k].v + 1]), vec3(sm.verts[sm.faces[k + 1].v + 1]), vec3(sm.verts[sm.faces[k + 2].v + 1])
            local n       = (B - A):cross(C - A)
            local z       = (A.z + B.z + C.z) / 3.0
            if n:length() > 1e-12 and math.abs(n.z) > 0.99 * n:length() and z < mid then
                local key   = math.floor(z * 1e3 + 0.5)
                levels[key] = (levels[key] or 0) + n:length() / 2.0
            end
        end
    end
    for key, area in pairs(levels) do
        if area > foot * 0.3 and (not top or key > top) then top = key end
    end
    local zt    = top and (top / 1e3 > m.lo.z + 1e-2) and top / 1e3 or nil
    local parts = {floor = {meshes = {}, lo = m.lo, hi = m.hi, path = m.path, key = (m.key and (m.key .. "_") or "") .. "floor"},
                   rail  = {meshes = {}, lo = m.lo, hi = m.hi, path = m.path, key = (m.key and (m.key .. "_") or "") .. "rail"},
                   zt = zt, zb = m.lo.z, mats = {}, tints = {}}
    local area = {top = {}, bottom = {}, side = {}}
    for _, sm in ipairs(zt and m.meshes or {}) do
        local into = {}
        for k = 1, #sm.faces, 3 do
            local tri = {corner(sm, sm.faces[k].v + 1), corner(sm, sm.faces[k + 1].v + 1), corner(sm, sm.faces[k + 2].v + 1)}
            local low = true
            for _, c in ipairs(tri) do low = low and c.p.z <= zt + 1e-3 end
            local side = low and "floor" or "rail"
            if not into[side] then
                into[side] = {verts = {}, normals = {}, uvs = {}, uvs2 = sm.uvs2 and {}, faces = {}, material = sm.material, tint = sm.tint}
                table.insert(parts[side].meshes, into[side])
            end
            local r = into[side]
            for _, c in ipairs(tri) do
                local i                          = #r.verts
                r.verts[i + 1], r.normals[i + 1] = c.p, c.n
                r.uvs[i + 1]                     = c.uv or {u = 0.0, v = 0.0}
                if r.uvs2 then r.uvs2[i + 1] = c.uv2 or {u = 0.0, v = 0.0} end
                r.faces[#r.faces + 1] = {v = i, n = i, u = i}
            end
            if low then
                local A, B, C = vec3(tri[1].p), vec3(tri[2].p), vec3(tri[3].p)
                local nz      = (tri[1].n.z + tri[2].n.z + tri[3].n.z) / 3.0
                local way     = (nz > 0.7 and "top") or (nz < -0.7 and "bottom") or "side"
                area[way][sm.material]   = (area[way][sm.material] or 0) + (B - A):cross(C - A):length()
                parts.tints[sm.material] = parts.tints[sm.material] or sm.tint
            end
        end
    end
    local any
    for way, byMat in pairs(area) do
        local best = 0
        for mat, v in pairs(byMat) do
            if v > best then parts.mats[way], best, any = mat, v, mat end
        end
    end
    if #parts.floor.meshes == 0 or #parts.rail.meshes == 0 then
        m.parts = false
        return nil
    end
    for _, way in ipairs({"top", "bottom", "side"}) do parts.mats[way] = parts.mats[way] or any end
    m.parts = parts
    return parts
end

local function extent(path)
    local m = model(path)
    if not m then return nil end
    local a, d = axes(m, size(path))
    return size(path) or (m.hi[a] - m.lo[a]), m.hi[d] - m.lo[d]
end

local function covers(t, x, z)
    local function side(x1, z1, x2, z2) return (x - x2) * (z1 - z2) - (x1 - x2) * (z - z2) end
    local d1, d2, d3 = side(t[1], t[2], t[3], t[4]), side(t[3], t[4], t[5], t[6]), side(t[5], t[6], t[1], t[2])
    return not ((d1 < 0 or d2 < 0 or d3 < 0) and (d1 > 0 or d2 > 0 or d3 > 0))
end

local function openDoor(path)
    local key = tostring(path)
    if doors[key] ~= nil then return doors[key] or nil end
    local w, h = size(key)
    doors[key] = false
    local m    = w and model(path)
    if not m then return nil end
    local tris = {}
    for _, sm in ipairs(m.meshes) do
        for k = 1, #sm.faces - 2, 3 do
            local a, b, c   = sm.verts[sm.faces[k].v + 1], sm.verts[sm.faces[k + 1].v + 1], sm.verts[sm.faces[k + 2].v + 1]
            tris[#tris + 1] = {a.x, a.z, b.x, b.z, c.x, c.z, math.min(a.x, b.x, c.x), math.max(a.x, b.x, c.x), math.min(a.z, b.z, c.z), math.max(a.z, b.z, c.z)}
        end
    end
    local n, hit = 0, 0
    for i = 0, 23 do
        for j = 0, 31 do
            local x, z = w * (-0.4 + 0.8 * (i + 0.5) / 24), m.lo.z + h * (0.05 + 0.85 * (j + 0.5) / 32)
            n          = n + 1
            for _, t in ipairs(tris) do
                if x >= t[7] and x <= t[8] and z >= t[9] and z <= t[10] and covers(t, x, z) then
                    hit = hit + 1
                    break
                end
            end
        end
    end
    if hit / n < openShare then doors[key] = math.max(hallMin, m.hi.y + hallGap) end
    return doors[key] or nil
end

local function reset()
    models, lists, files, trees, resolved, doors = {}, {}, {}, {}, {}, {}
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.root       = root
M.own        = own
M.defWin     = defWin
M.defDoor    = defDoor
M.defaults   = defaults
M.pipeParts  = pipeParts
M.levelMats  = levelMats
M.tintSrc    = tintSrc
M.model      = model
M.resolve    = resolve
M.layout     = layout
M.size       = size
M.hole       = hole
M.sill       = sill
M.list       = list
M.label      = label
M.put        = put
M.place      = place
M.cutAt      = cutAt
M.axes       = axes
M.tile       = tile
M.fit        = fit
M.join       = join
M.split      = split
M.extent     = extent
M.awningOver = awningOver
M.openDoor   = openDoor
M.hallMin    = hallMin
M.darkMat    = darkMat
M.reset      = reset

return M
