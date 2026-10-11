-- =============================================================================
-- MaGE - COLLADA reader
-- Version: 1.0.1
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local skipNames = {"^colmesh", "^collision", "^col[%-_]", "^los[%-_]", "^los$", "^bounds$", "^nulldetail"}
local identity  = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
local yUp       = {1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1}

-- =============================================================================
-- XML
-- =============================================================================

local function parseXml(s)
    s           = s:gsub("<!%-%-.-%-%->", ""):gsub("<%?.-%?>", ""):gsub("<!%[CDATA%[(.-)%]%]>", "%1")
    local root  = {tag = "#root", attr = {}, kids = {}}
    local stack = {root}
    local pos   = 1
    while true do
        local a, b, close, tag, attrs, single = s:find("<(/?)([%w_:%-%.]+)(.-)(/?)>", pos)
        if not a then break end
        local top = stack[#stack]
        if a > pos then
            local chunk = s:sub(pos, a - 1)
            if chunk:find("%S") then top.text = (top.text or "") .. chunk end
        end
        if close == "/" then
            if #stack > 1 then stack[#stack] = nil end
        else
            local node = {tag = tag:gsub("^.*:", ""), attr = {}, kids = {}}
            for k, v in attrs:gmatch('([%w_:%-]+)%s*=%s*"([^"]*)"') do node.attr[k] = v end
            top.kids[#top.kids + 1] = node
            if single ~= "/" then stack[#stack + 1] = node end
        end
        pos = b + 1
    end
    return root
end

local function child(node, tag)
    for _, k in ipairs(node and node.kids or {}) do
        if k.tag == tag then return k end
    end
    return nil
end

local function children(node, tag)
    local out = {}
    for _, k in ipairs(node and node.kids or {}) do
        if k.tag == tag then out[#out + 1] = k end
    end
    return out
end

local function numbers(text)
    local out = {}
    for w in (text or ""):gmatch("%S+") do out[#out + 1] = tonumber(w) or 0 end
    return out
end

local function ref(url)
    return url and (url:gsub("^#", "")) or nil
end

-- =============================================================================
-- MATRICES
-- =============================================================================

local function mul(a, b)
    local r = {}
    for i = 0, 3 do
        for j = 0, 3 do
            local s = 0
            for k = 0, 3 do s = s + a[i * 4 + k + 1] * b[k * 4 + j + 1] end
            r[i * 4 + j + 1] = s
        end
    end
    return r
end

local function rotation(x, y, z, deg)
    local l = math.sqrt(x * x + y * y + z * z)
    if l < 1e-12 then return identity end
    x, y, z    = x / l, y / l, z / l
    local a    = math.rad(deg)
    local c, s = math.cos(a), math.sin(a)
    local t    = 1 - c
    return {t * x * x + c,     t * x * y - s * z, t * x * z + s * y, 0,
            t * x * y + s * z, t * y * y + c,     t * y * z - s * x, 0,
            t * x * z - s * y, t * y * z + s * x, t * z * z + c,     0,
            0, 0, 0, 1}
end

local function localMatrix(node)
    local m = identity
    for _, k in ipairs(node.kids) do
        local v = numbers(k.text)
        if k.tag == "matrix" and #v >= 16 then
            m = mul(m, v)
        elseif k.tag == "translate" and #v >= 3 then
            m = mul(m, {1, 0, 0, v[1], 0, 1, 0, v[2], 0, 0, 1, v[3], 0, 0, 0, 1})
        elseif k.tag == "rotate" and #v >= 4 then
            m = mul(m, rotation(v[1], v[2], v[3], v[4]))
        elseif k.tag == "scale" and #v >= 3 then
            m = mul(m, {v[1], 0, 0, 0, 0, v[2], 0, 0, 0, 0, v[3], 0, 0, 0, 0, 1})
        end
    end
    return m
end

local function point(m, x, y, z)
    return {x = m[1] * x + m[2] * y + m[3] * z + m[4],
            y = m[5] * x + m[6] * y + m[7] * z + m[8],
            z = m[9] * x + m[10] * y + m[11] * z + m[12]}
end

local function cofactor(m)
    local a, b, c = m[1], m[2], m[3]
    local d, e, f = m[5], m[6], m[7]
    local g, h, i = m[9], m[10], m[11]
    local det     = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    local s       = det < 0 and -1 or 1
    return {s * (e * i - f * h), s * (f * g - d * i), s * (d * h - e * g),
            s * (c * h - b * i), s * (a * i - c * g), s * (b * g - a * h),
            s * (b * f - c * e), s * (c * d - a * f), s * (a * e - b * d)}, det
end

local function direction(n, x, y, z)
    local rx = n[1] * x + n[2] * y + n[3] * z
    local ry = n[4] * x + n[5] * y + n[6] * z
    local rz = n[7] * x + n[8] * y + n[9] * z
    local l  = math.sqrt(rx * rx + ry * ry + rz * rz)
    if l < 1e-12 then return nil end
    return {x = rx / l, y = ry / l, z = rz / l}
end

-- =============================================================================
-- GEOMETRY
-- =============================================================================

local function sourcesOf(mesh)
    local out = {}
    for _, src in ipairs(children(mesh, "source")) do
        local arr        = child(src, "float_array")
        local acc        = child(child(src, "technique_common"), "accessor")
        local data       = numbers(arr and arr.text)
        local nPar       = acc and #children(acc, "param") or 0
        local str        = tonumber(acc and acc.attr.stride) or (nPar > 0 and nPar) or 1
        out[src.attr.id] = {data = data, stride = str}
    end
    for _, vs in ipairs(children(mesh, "vertices")) do
        local entry = {}
        for _, inp in ipairs(children(vs, "input")) do entry[inp.attr.semantic] = ref(inp.attr.source) end
        out[vs.attr.id] = entry
    end
    return out
end

local function primitives(mesh, src)
    local out = {}
    for _, prim in ipairs(mesh.kids) do
        local kind = prim.tag
        if kind == "triangles" or kind == "polylist" or kind == "polygons" then
            local ins, stride = {}, 0
            local tex         = {}
            for _, inp in ipairs(children(prim, "input")) do
                local off = tonumber(inp.attr.offset) or 0
                stride    = math.max(stride, off + 1)
                local sem = inp.attr.semantic
                local id  = ref(inp.attr.source)
                if sem == "VERTEX" then
                    local vs = src[id] or {}
                    ins.pos  = {src = src[vs.POSITION], off = off}
                    if vs.NORMAL then ins.nrm = {src = src[vs.NORMAL], off = off} end
                    if vs.TEXCOORD then tex[#tex + 1] = {src = src[vs.TEXCOORD], off = off, set = -1} end
                elseif sem == "NORMAL" then
                    ins.nrm = {src = src[id], off = off}
                elseif sem == "TEXCOORD" then
                    tex[#tex + 1] = {src = src[id], off = off, set = tonumber(inp.attr.set) or #tex}
                end
            end
            table.sort(tex, function(a, b) return a.set < b.set end)
            ins.uv, ins.uv2 = tex[1], tex[2]
            local polys     = {}
            if kind == "triangles" then
                local p = numbers(child(prim, "p") and child(prim, "p").text)
                for k = 0, math.floor(#p / (3 * stride)) - 1 do polys[#polys + 1] = {p = p, at = k * 3 * stride, n = 3} end
            elseif kind == "polylist" then
                local p  = numbers(child(prim, "p") and child(prim, "p").text)
                local at = 0
                for _, n in ipairs(numbers(child(prim, "vcount") and child(prim, "vcount").text)) do
                    polys[#polys + 1] = {p = p, at = at, n = n}
                    at                = at + n * stride
                end
            else
                for _, pe in ipairs(children(prim, "p")) do
                    local p = numbers(pe.text)
                    polys[#polys + 1] = {p = p, at = 0, n = math.floor(#p / math.max(stride, 1))}
                end
            end
            if ins.pos and ins.pos.src then
                out[#out + 1] = {symbol = prim.attr.material, ins = ins, stride = stride, polys = polys}
            end
        end
    end
    return out
end

local function fetch(input, p, base)
    if not input or not input.src then return nil end
    local i = p[base + input.off + 1]
    if not i then return nil end
    local d, s = input.src.data, input.src.stride
    return d[i * s + 1] or 0, d[i * s + 2] or 0, d[i * s + 3] or 0
end

local function emit(out, prim, m, nm, mirrored, material)
    local sm = out[material]
    if not sm then
        sm = {verts = {}, normals = {}, uvs = {}, faces = {}, material = material}
        if prim.ins.uv2 then sm.uvs2 = {} end
        out[material] = sm
        out[#out + 1] = sm
    end
    local ins = prim.ins
    for _, poly in ipairs(prim.polys) do
        local corners = {}
        for c = 0, poly.n - 1 do
            local base    = poly.at + c * prim.stride
            local x, y, z = fetch(ins.pos, poly.p, base)
            if not x then corners = nil break end
            local u, v       = fetch(ins.uv, poly.p, base)
            local u2, v2     = fetch(ins.uv2, poly.p, base)
            local nx, ny, nz = fetch(ins.nrm, poly.p, base)
            corners[#corners + 1] = {p = point(m, x, y, z), n = nx and direction(nm, nx, ny, nz),
                                     uv = {u = u or 0, v = 1 - (v or 0)}, uv2 = sm.uvs2 and {u = u2 or 0, v = 1 - (v2 or 0)}}
        end
        for k = 2, (corners and #corners or 0) - 1 do
            local a, b, c = corners[1], corners[k], corners[k + 1]
            local e1      = {x = b.p.x - a.p.x, y = b.p.y - a.p.y, z = b.p.z - a.p.z}
            local e2      = {x = c.p.x - a.p.x, y = c.p.y - a.p.y, z = c.p.z - a.p.z}
            local fx      = e1.y * e2.z - e1.z * e2.y
            local fy      = e1.z * e2.x - e1.x * e2.z
            local fz      = e1.x * e2.y - e1.y * e2.x
            local fl      = math.sqrt(fx * fx + fy * fy + fz * fz)
            local sign    = mirrored and -1 or 1
            local flat    = fl > 1e-12 and {x = sign * fx / fl, y = sign * fy / fl, z = sign * fz / fl} or {x = 0, y = 0, z = 1}
            local order   = mirrored and {a, b, c} or {a, c, b}
            for _, q in ipairs(order) do
                local i = #sm.verts
                sm.verts[i + 1]   = q.p
                sm.normals[i + 1] = q.n or flat
                sm.uvs[i + 1]     = q.uv
                if sm.uvs2 then sm.uvs2[i + 1] = q.uv2 end
                sm.faces[#sm.faces + 1] = {v = i, n = i, u = i}
            end
        end
    end
end

-- =============================================================================
-- SCENE
-- =============================================================================

local function nameOf(node)
    return node.attr.name or node.attr.id or ""
end

local function skipped(name)
    local n = name:lower()
    for _, p in ipairs(skipNames) do
        if n:find(p) then return true end
    end
    return false
end

local function isDts(scene)
    for _, n in ipairs(children(scene, "node")) do
        if nameOf(n):lower():find("^base%d*$") then
            for _, s in ipairs(children(n, "node")) do
                if nameOf(s):lower():find("^start%d*$") then return true end
            end
        end
    end
    return false
end

local function instancesOf(scene, libNodes, root)
    local out = {}
    local function walk(node, parent, depth)
        if depth > 32 or skipped(nameOf(node)) then return end
        local m = mul(parent, localMatrix(node))
        for _, ig in ipairs(children(node, "instance_geometry")) do
            local binds = {}
            for _, im in ipairs(children(child(child(ig, "bind_material"), "technique_common"), "instance_material")) do
                binds[im.attr.symbol or ""] = ref(im.attr.target)
            end
            out[#out + 1] = {geo = ref(ig.attr.url), binds = binds, m = m, name = nameOf(node)}
        end
        for _, inst in ipairs(children(node, "instance_node")) do
            local target = libNodes[ref(inst.attr.url)]
            if target then walk(target, m, depth + 1) end
        end
        for _, k in ipairs(children(node, "node")) do walk(k, m, depth + 1) end
    end
    for _, n in ipairs(children(scene, "node")) do walk(n, root, 0) end
    return out
end

local function sameMatrix(a, b)
    for i = 1, 16 do
        if math.abs(a[i] - b[i]) > 1e-6 then return false end
    end
    return true
end

local function topDetail(list)
    local best = {}
    for _, inst in ipairs(list) do
        local base, num = inst.name:match("^(.-)(%d+)$")
        base            = base or inst.name
        local d         = tonumber(num) or 0
        local cur       = best[base]
        if not cur or d > cur then best[base] = d end
        inst.base, inst.detail = base, d
    end
    local tops = {}
    for _, inst in ipairs(list) do
        if inst.detail == best[inst.base] then
            local l         = tops[inst.base] or {}
            tops[inst.base] = l
            l[#l + 1]       = inst
        end
    end
    local out = {}
    for _, inst in ipairs(list) do
        local keep = inst.detail == best[inst.base]
        if not keep then
            keep = true
            for _, t in ipairs(tops[inst.base]) do
                if sameMatrix(t.m, inst.m) then keep = false end
            end
        end
        if keep then out[#out + 1] = inst end
    end
    return out
end

-- =============================================================================
-- READ
-- =============================================================================

local function read(text)
    local doc   = child(parseXml(text), "COLLADA")
    if not doc then return nil, "not a COLLADA file" end
    local asset = child(doc, "asset")
    local unit  = tonumber(child(asset, "unit") and child(asset, "unit").attr.meter) or 1
    local up    = child(asset, "up_axis") and child(asset, "up_axis").text or "Z_UP"
    local root  = mul(up:find("Y_UP") and yUp or identity, {unit, 0, 0, 0, 0, unit, 0, 0, 0, 0, unit, 0, 0, 0, 0, 1})

    local matName = {}
    for _, mat in ipairs(children(child(doc, "library_materials"), "material")) do
        matName[mat.attr.id] = mat.attr.name or mat.attr.id
    end
    local geos = {}
    for _, g in ipairs(children(child(doc, "library_geometries"), "geometry")) do
        local mesh = child(g, "mesh")
        if mesh then geos[g.attr.id] = mesh end
    end
    local libNodes = {}
    for _, lib in ipairs(children(doc, "library_nodes")) do
        for _, n in ipairs(children(lib, "node")) do libNodes[n.attr.id or ""] = n end
    end
    local scenes = children(child(doc, "library_visual_scenes"), "visual_scene")
    local want   = ref(child(child(doc, "scene"), "instance_visual_scene") and child(child(doc, "scene"), "instance_visual_scene").attr.url)
    local scene  = scenes[1]
    for _, s in ipairs(scenes) do
        if s.attr.id == want then scene = s end
    end
    if not scene then return nil, "no visual scene" end

    local list = {}
    for _, inst in ipairs(instancesOf(scene, libNodes, root)) do
        if geos[inst.geo] then list[#list + 1] = inst end
    end
    if isDts(scene) then list = topDetail(list) end

    local out, cache = {}, {}
    for _, inst in ipairs(list) do
        local prims = cache[inst.geo]
        if not prims then
            local mesh      = geos[inst.geo]
            prims           = primitives(mesh, sourcesOf(mesh))
            cache[inst.geo] = prims
        end
        local nm, det = cofactor(inst.m)
        for _, prim in ipairs(prims) do
            local target = inst.binds[prim.symbol or ""] or prim.symbol or ""
            local name   = matName[target] or target:gsub("%-material$", "")
            emit(out, prim, inst.m, nm, det < 0, name)
        end
    end
    local meshes = {}
    for _, sm in ipairs(out) do
        if #sm.faces > 0 then meshes[#meshes + 1] = sm end
    end
    return meshes
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.read = read

return M
