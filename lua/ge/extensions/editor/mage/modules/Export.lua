-- =============================================================================
-- MaGE - DAE file writer
-- Version: 1.0.0
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M      = {}
local logTag = 'mage'

local G  = require("editor/mage/core/Geometry")
local C  = require("editor/mage/core/Common")
local P  = require("editor/mage/modules/Preview")
local O  = require("editor/mage/modules/Overlap")
local tr = C.tr
local mr = G.mr

-- =============================================================================
-- DAE
-- =============================================================================

mr.daeDir         = "art/shapes/mage/"
mr.daePrefix      = "mage_"
mr.legacyPrefixes = {"pit_sidewalk_"}
mr.daeCell        = 200.0

mr.indexFile    = "mage_index.json"
mr.indexVersion = 3

function mr.daeName(s)
    return (tostring(s):gsub("[^%w_%-]", "_"))
end

function mr.num(v)
    local t = string.format("%.4f", v):gsub("0+$", ""):gsub("%.$", "")
    if t == "" or t == "-" or t == "-0" then return "0" end
    return t
end

mr.daeCreaseCos = math.cos(math.rad(30))

function mr.daeTag(n)
    if n.z > 0.05 then return 1 end
    if n.z < -0.05 then return -1 end
    return 0
end

function mr.daeCollect(meshes, origin, keep, second)
    local pos, pIdx, coord     = {}, {}, {}
    local uvs, uIdx            = {}, {}
    local uvs2, u2Idx          = {}, {}
    local tris, order, dropped = {}, {}, 0
    local function key(arr, map, k)
        local i = map[k]
        if not i then i = #arr arr[i + 1] = k map[k] = i end
        return i
    end
    for _, sm in ipairs(meshes) do
        local f           = sm.faces
        local mat         = mr.daeName(sm.material or "WarningMaterial")
        local pm, um, um2 = {}, {}, {}
        for k = 1, #f - 2, 3 do
            local cs          = {f[k], f[k + 2], f[k + 1]}
            local pi, ui, u2i = {}, {}, {}
            for j, c in ipairs(cs) do
                local x = pm[c.v]
                if not x then
                    local v      = sm.verts[c.v + 1]
                    local lx, ly = v.x - origin.x, v.y - origin.y
                    x            = key(pos, pIdx, mr.num(lx) .. " " .. mr.num(ly) .. " " .. mr.num(v.z))
                    if not coord[x] then coord[x] = vec3(lx, ly, v.z) end
                    pm[c.v] = x
                end
                pi[j]   = x
                local y = um[c.u]
                if not y then
                    local t = sm.uvs[c.u + 1]
                    y       = key(uvs, uIdx, mr.num(t.u) .. " " .. mr.num(1.0 - t.v))
                    um[c.u] = y
                end
                ui[j] = y
                if second then
                    local z = um2[c.u]
                    if not z then
                        local t  = (sm.uvs2 or sm.uvs)[c.u + 1]
                        z        = key(uvs2, u2Idx, mr.num(t.u) .. " " .. mr.num(1.0 - t.v))
                        um2[c.u] = z
                    end
                    u2i[j] = z
                end
            end
            local a, b2, c3 = coord[pi[1]], coord[pi[2]], coord[pi[3]]
            local cr        = (b2 - a):cross(c3 - a)
            if pi[1] == pi[2] or pi[2] == pi[3] or pi[1] == pi[3] or cr:length() < 1e-10 then
                dropped = dropped + 1
            else
                local sn = sm.normals[cs[1].n + 1]
                local n  = vec3(sn.x, sn.y, sn.z)
                tris[#tris + 1] = {p = pi, u = ui, u2 = u2i, n = n, tag = mr.daeTag(n), mat = mat}
                if keep then
                    local cn = {}
                    for j, c in ipairs(cs) do
                        local q = sm.normals[c.n + 1]
                        local w = vec3(q.x, q.y, q.z)
                        cn[j]   = (w:length() > 1e-12) and w:normalized() or cr:normalized()
                    end
                    tris[#tris].cn = cn
                end
                if not order[mat] then order[#order + 1] = mat order[mat] = true end
            end
        end
    end
    return {pos = pos, coord = coord, uvs = uvs, uvs2 = second and uvs2 or nil, tris = tris, mats = order, dropped = dropped}
end

function mr.daeSmooth(d)
    local tris, coord = d.tris, d.coord
    local edges       = {}
    for ti, t in ipairs(tris) do
        for j = 1, 3 do
            local a, b = t.p[j], t.p[j % 3 + 1]
            local k    = (a < b) and (a .. ":" .. b) or (b .. ":" .. a)
            local e    = edges[k]
            if not e then e = {} edges[k] = e end
            e[#e + 1] = ti
        end
    end
    local function soft(a, b)
        local k = (a < b) and (a .. ":" .. b) or (b .. ":" .. a)
        local e = edges[k]
        if not e or #e ~= 2 then return nil end
        local t1, t2 = tris[e[1]], tris[e[2]]
        if t1.tag ~= t2.tag then return nil end
        if t1.tag == 0 and t1.n:dot(t2.n) < mr.daeCreaseCos then return nil end
        return e[1], e[2]
    end
    local around = {}
    for ti, t in ipairs(tris) do
        for j = 1, 3 do
            local v = t.p[j]
            local l = around[v]
            if not l then l = {} around[v] = l end
            l[#l + 1] = ti * 4 + j
        end
    end
    local nrm, nIdx = {}, {}
    local cornerN   = {}
    for v, list in pairs(around) do
        local parent = {}
        for _, c in ipairs(list) do parent[c] = c end
        local function find(x)
            while parent[x] ~= x do parent[x] = parent[parent[x]] x = parent[x] end
            return x
        end
        local byTri = {}
        for _, c in ipairs(list) do byTri[math.floor(c / 4)] = c end
        for _, c in ipairs(list) do
            local ti, j = math.floor(c / 4), c % 4
            local t     = tris[ti]
            for _, other in ipairs({t.p[j % 3 + 1], t.p[(j + 1) % 3 + 1]}) do
                local t1, t2 = soft(v, other)
                if t1 then
                    local o  = (t1 == ti) and t2 or t1
                    local oc = byTri[o]
                    if oc then
                        local ra, rb = find(c), find(oc)
                        if ra ~= rb then parent[ra] = rb end
                    end
                end
            end
        end
        local sum = {}
        for _, c in ipairs(list) do
            local ti, j  = math.floor(c / 4), c % 4
            local t      = tris[ti]
            local p0     = coord[t.p[j]]
            local e1     = coord[t.p[j % 3 + 1]] - p0
            local e2     = coord[t.p[(j + 1) % 3 + 1]] - p0
            local l1, l2 = e1:length(), e2:length()
            local ang    = 0.0
            if l1 > 1e-12 and l2 > 1e-12 then
                ang = math.acos(math.max(-1.0, math.min(1.0, e1:dot(e2) / (l1 * l2))))
            end
            local r = find(c)
            sum[r]  = (sum[r] or vec3(0, 0, 0)) + t.n * ang
        end
        for _, c in ipairs(list) do
            local sv = sum[find(c)]
            local n  = (sv:length() > 1e-12) and sv:normalized() or tris[math.floor(c / 4)].n
            local k  = mr.num(n.x) .. " " .. mr.num(n.y) .. " " .. mr.num(n.z)
            local i  = nIdx[k]
            if not i then i = #nrm nrm[i + 1] = k nIdx[k] = i end
            cornerN[c] = i
        end
    end
    d.nrm, d.cornerN = nrm, cornerN
end

function mr.daeKeepNormals(d)
    local nrm, nIdx, cornerN = {}, {}, {}
    for ti, t in ipairs(d.tris) do
        for j = 1, 3 do
            local n = t.cn[j]
            local k = mr.num(n.x) .. " " .. mr.num(n.y) .. " " .. mr.num(n.z)
            local i = nIdx[k]
            if not i then i = #nrm nrm[i + 1] = k nIdx[k] = i end
            cornerN[ti * 4 + j] = i
        end
    end
    d.nrm, d.cornerN = nrm, cornerN
end

function mr.daeGeometry(gid, meshes, out, used, origin, keep, second)
    local d = mr.daeCollect(meshes, origin, keep, second)
    if #d.tris == 0 then return 0, d.dropped end
    if keep then mr.daeKeepNormals(d) else mr.daeSmooth(d) end
    local blocks = {}
    for _, mat in ipairs(d.mats) do
        local idx, n3 = {}, 0
        for ti, t in ipairs(d.tris) do
            if t.mat == mat then
                for j = 1, 3 do
                    idx[#idx + 1] = t.p[j] .. " " .. d.cornerN[ti * 4 + j] .. " " .. t.u[j]
                    if d.uvs2 then idx[#idx] = idx[#idx] .. " " .. t.u2[j] end
                    idx[#idx] = idx[#idx] .. " 0"
                end
                n3 = n3 + 1
            end
        end
        used[mat] = true
        blocks[#blocks + 1] = table.concat({
            '        <triangles material="', mat, '-material" count="', n3, '">\n',
            '          <input semantic="VERTEX" source="#', gid, '-verts" offset="0"/>\n',
            '          <input semantic="NORMAL" source="#', gid, '-nrm" offset="1"/>\n',
            '          <input semantic="TEXCOORD" source="#', gid, '-uv" offset="2" set="0"/>\n',
            d.uvs2 and ('          <input semantic="TEXCOORD" source="#' .. gid .. '-uv2" offset="3" set="1"/>\n') or '',
            '          <input semantic="COLOR" source="#', gid, '-col" offset="', d.uvs2 and 4 or 3, '" set="0"/>\n',
            '          <p>', table.concat(idx, " "), '</p>\n',
            '        </triangles>\n'})
    end
    local function src(id, arr, stride, params)
        local ps = {}
        for _, nm in ipairs(params) do ps[#ps + 1] = '<param name="' .. nm .. '" type="float"/>' end
        return table.concat({
            '        <source id="', gid, '-', id, '">\n',
            '          <float_array id="', gid, '-', id, '-array" count="', #arr * stride, '">', table.concat(arr, " "), '</float_array>\n',
            '          <technique_common><accessor source="#', gid, '-', id, '-array" count="', #arr,
            '" stride="', stride, '">', table.concat(ps), '</accessor></technique_common>\n',
            '        </source>\n'})
    end
    out[#out + 1] = table.concat({
        '    <geometry id="', gid, '-mesh" name="', gid, '">\n      <mesh>\n',
        src("pos", d.pos, 3, {"X", "Y", "Z"}),
        src("nrm", d.nrm, 3, {"X", "Y", "Z"}),
        src("uv", d.uvs, 2, {"S", "T"}),
        d.uvs2 and src("uv2", d.uvs2, 2, {"S", "T"}) or '',
        src("col", {"1 1 1 1"}, 4, {"R", "G", "B", "A"}),
        '        <vertices id="', gid, '-verts"><input semantic="POSITION" source="#', gid, '-pos"/></vertices>\n',
        table.concat(blocks),
        '      </mesh>\n    </geometry>\n'})
    return #d.tris, d.dropped
end

function mr.daeNode(name, gid, mats)
    local im = {}
    for _, m in ipairs(mats) do
        im[#im + 1] = '<instance_material symbol="' .. m .. '-material" target="#' .. m .. '-material"/>'
    end
    return table.concat({
        '          <node id="', name, '" name="', name, '" type="NODE">\n',
        '            <matrix sid="transform">1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1</matrix>\n',
        '            <instance_geometry url="#', gid, '-mesh" name="', name, '">',
        '<bind_material><technique_common>', table.concat(im), '</technique_common></bind_material>',
        '</instance_geometry>\n',
        '          </node>\n'})
end

function mr.buildDae(entries, origin)
    local keyed = {}
    for _, b in ipairs(entries) do
        local r = b.road
        keyed[#keyed + 1] = {key = mr.daeName(r.persistentId or r.name or r.id), b = b}
    end
    table.sort(keyed, function(x, y) return x.key < y.key end)
    local geos, nodes, allUsed   = {}, {}, {}
    local objects, tris, dropped = 0, 0, 0
    local seen                   = {}
    local second                 = false
    for _, b in ipairs(entries) do
        if b.secondUv then second = true end
    end
    for _, e in ipairs(keyed) do
        local b    = e.b
        local base = "mage_" .. e.key
        local n0   = (seen[base] or 0) + 1
        seen[base] = n0
        if n0 > 1 then base = base .. "_" .. string.char(96 + n0) end
        base          = base .. "_M"
        local used    = {}
        local n, drop = mr.daeGeometry(base, b.meshes, geos, used, origin, b.keepNormals, second)
        dropped       = dropped + (drop or 0)
        if n > 0 then
            local mats = {}
            for m in pairs(used) do mats[#mats + 1] = m allUsed[m] = true end
            table.sort(mats)
            nodes[#nodes + 1] = mr.daeNode(base, base, mats)
            nodes[#nodes + 1] = mr.daeNode("Colmesh_" .. base .. "-1", base, mats)
            objects, tris = objects + 1, tris + n
        end
    end
    local effects, materials = {}, {}
    local matNames           = {}
    for m in pairs(allUsed) do matNames[#matNames + 1] = m end
    table.sort(matNames)
    for _, m in ipairs(matNames) do
        effects[#effects + 1] = '    <effect id="' .. m .. '-effect"><profile_COMMON><technique sid="common"><lambert>'
            .. '<diffuse><color sid="diffuse">0.8 0.8 0.8 1</color></diffuse></lambert></technique></profile_COMMON></effect>\n'
        materials[#materials + 1] = '    <material id="' .. m .. '-material" name="' .. m .. '"><instance_effect url="#'
            .. m .. '-effect"/></material>\n'
    end
    local ident = "1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1"
    local stamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local xml   = table.concat({
        '<?xml version="1.0" encoding="utf-8"?>\n',
        '<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">\n',
        '  <asset><contributor><authoring_tool>MaGE</authoring_tool></contributor>',
        '<created>', stamp, '</created><modified>', stamp, '</modified>',
        '<unit name="meter" meter="1"/><up_axis>Z_UP</up_axis></asset>\n',
        '  <library_effects>\n', table.concat(effects), '  </library_effects>\n',
        '  <library_materials>\n', table.concat(materials), '  </library_materials>\n',
        '  <library_geometries>\n', table.concat(geos), '  </library_geometries>\n',
        '  <library_visual_scenes>\n    <visual_scene id="Scene" name="Scene">\n',
        '      <node id="base00" name="base00" type="NODE">\n',
        '        <matrix sid="transform">', ident, '</matrix>\n',
        '        <node id="start01" name="start01" type="NODE">\n',
        '          <matrix sid="transform">', ident, '</matrix>\n',
        table.concat(nodes),
        '        </node>\n      </node>\n',
        '    </visual_scene>\n  </library_visual_scenes>\n',
        '  <scene><instance_visual_scene url="#Scene"/></scene>\n',
        '</COLLADA>\n'})
    return xml, objects, tris, dropped
end

function mr.placeStatic(file, name, pos)
    local obj = scenetree.findObject(name)
    if obj then return false end
    obj = createObject('TSStatic')
    obj:setField('shapeName', 0, file)
    obj:setPosition(pos)
    obj.scale = vec3(1, 1, 1)
    obj:setField('collisionType', 0, 'Collision Mesh')
    obj:setField('decalType', 0, 'Collision Mesh')
    obj.canSave = true
    obj:registerObject(name)
    scenetree.MissionGroup:addObject(obj)
    return true
end

function mr.cellTag(i)
    return (i < 0) and ("m" .. tostring(-i)) or tostring(i)
end

function mr.writeChecked(file, xml)
    writeFile(file, xml)
    local back = readFile(file)
    return type(back) == "string" and back:gsub("\r\n", "\n") == xml
end

-- =============================================================================
-- UNITS
-- =============================================================================

local sigSkip = {id = true, srcIds = true, presets = true}

local function sigOf(value)
    local parts, seen = {}, {}
    local function put(v, depth)
        local t = type(v)
        if t == "number" then
            parts[#parts + 1] = mr.num(v)
        elseif t == "string" then
            parts[#parts + 1] = v
        elseif t == "boolean" then
            parts[#parts + 1] = v and "T" or "F"
        elseif t == "cdata" or t == "userdata" then
            local ok, x, y, z = pcall(function() return v.x, v.y, v.z end)
            if ok and type(x) == "number" then
                parts[#parts + 1] = mr.num(x) .. "," .. mr.num(y) .. "," .. mr.num(z)
            end
        elseif t == "table" then
            if seen[v] or depth > 4 then
                parts[#parts + 1] = "@"
                return
            end
            seen[v]    = true
            local keys = {}
            for k in pairs(v) do
                if not sigSkip[k] then keys[#keys + 1] = k end
            end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            parts[#parts + 1] = "{"
            for _, k in ipairs(keys) do
                parts[#parts + 1] = tostring(k)
                put(v[k], depth + 1)
            end
            parts[#parts + 1] = "}"
        end
    end
    put(value, 0)
    return C.hash(table.concat(parts, "|"))
end

local function cellOf(road)
    local pts = road.points or road.ring
    if not pts or #pts == 0 then return nil end
    local lx, ly, hx, hy = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(pts) do
        lx, ly = math.min(lx, p.x), math.min(ly, p.y)
        hx, hy = math.max(hx, p.x), math.max(hy, p.y)
    end
    local ix = math.floor((lx + hx) / 2.0 / mr.daeCell)
    local iy = math.floor((ly + hy) / 2.0 / mr.daeCell)
    return mr.cellTag(ix) .. "_" .. mr.cellTag(iy), ix, iy
end

local function unitsOf(paths)
    local list = {}
    for _, road in ipairs(paths) do
        local cell, ix, iy = cellOf(road)
        if cell then
            list[#list + 1] = {
                road = road, cell = cell, ix = ix, iy = iy, sig = sigOf(road),
                base = mr.daeName(road.persistentId or road.name or road.id),
            }
        end
    end
    table.sort(list, function(a, b)
        if a.base ~= b.base then return a.base < b.base end
        return a.sig < b.sig
    end)
    local units, seen = {}, {}
    for _, u in ipairs(list) do
        local n      = (seen[u.base] or 0) + 1
        seen[u.base] = n
        u.key        = (n > 1) and (u.base .. "_" .. n) or u.base
        units[u.key] = u
    end
    return units
end

local function sourcesOfCells(ids, cells)
    local out, seen = {}, {}
    for _, u in pairs(unitsOf(P.collectUnits(ids or {}).paths)) do
        if cells[u.cell] then
            for _, sid in ipairs(u.road.srcIds or {u.road.id}) do
                if not seen[sid] then
                    seen[sid]     = true
                    out[#out + 1] = sid
                end
            end
        end
    end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

-- =============================================================================
-- UPDATE
-- =============================================================================

local function removeCell(cell, levelPath)
    local o = scenetree.findObject(mr.daePrefix .. cell)
    if levelPath then C.removeFile(levelPath .. mr.daeDir .. "mage_" .. cell .. ".dae") end
    if o then
        o:delete()
        return true
    end
    return false
end

local function update(ids, full)
    if not G.getStyleCfg() then P.loadStyles() end
    if not G.getStyleCfg() then return tostring(G.getStyleErr()), false end
    local levelPath = editor.getLevelPath()
    if not levelPath or levelPath == "" then return "no level path", false end
    local t0 = os.clock()

    local paths   = P.collectUnits(ids or {}).paths
    local units   = unitsOf(paths)
    local plan    = O.plan(paths)
    local baseSig = {}
    for _, u in pairs(units) do baseSig[u.road] = u.sig end
    for _, u in pairs(units) do
        local nbs = plan.neighbors[u.road]
        if nbs and #nbs > 0 then
            local parts = {u.sig}
            for _, nb in ipairs(nbs) do parts[#parts + 1] = baseSig[nb] or "" end
            u.sig = C.hash(table.concat(parts, "|"))
        end
    end
    local buildCache = {}
    local indexPath  = levelPath .. mr.daeDir .. mr.indexFile
    local cfgSig     = sigOf({cfg = G.getStyleCfg(), version = mr.indexVersion, cell = mr.daeCell})
    local old        = (not full) and C.readJson(indexPath) or nil
    if not old or old.version ~= mr.indexVersion or old.config ~= cfgSig or type(old.units) ~= "table" then
        old, full = nil, true
    end

    local byCell = {}
    for _, u in pairs(units) do
        local c = byCell[u.cell]
        if not c then
            c              = {ix = u.ix, iy = u.iy, units = {}}
            byCell[u.cell] = c
        end
        c.units[#c.units + 1] = u
    end

    local dirty, changed = {}, 0
    if full then
        for cell in pairs(byCell) do dirty[cell] = true end
        changed = 0
        for _ in pairs(units) do changed = changed + 1 end
    else
        for key, u in pairs(units) do
            local o = old.units[key]
            if not o or o.sig ~= u.sig or o.cell ~= u.cell then
                dirty[u.cell] = true
                if o and o.cell then dirty[o.cell] = true end
                changed = changed + 1
            end
        end
        for key, o in pairs(old.units) do
            if not units[key] and type(o) == "table" and o.cell then
                dirty[o.cell] = true
                changed       = changed + 1
            end
        end
        for cell in pairs(byCell) do
            if not scenetree.findObject(mr.daePrefix .. cell) then dirty[cell] = true end
        end
    end

    local order = {}
    for cell in pairs(dirty) do order[#order + 1] = cell end
    table.sort(order)

    local rebuilt, removed, placed, skipped, tris = 0, 0, 0, 0, 0
    for _, cell in ipairs(order) do
        local c       = byCell[cell]
        local entries = {}
        if c then
            table.sort(c.units, function(a, b) return a.key < b.key end)
            for _, u in ipairs(c.units) do
                local meshes = O.build(u.road, plan, P.buildUnit, buildCache)
                if meshes then
                    local own, mods, mods2 = {}, {}, {}
                    for _, sm in ipairs(meshes) do
                        local list = (not sm.module and own) or (sm.uvs2 and mods2) or mods
                        list[#list + 1] = sm
                    end
                    if #own > 0 then entries[#entries + 1] = {road = u.road, meshes = own} end
                    if #mods > 0 then entries[#entries + 1] = {road = {persistentId = u.key .. "_modules"}, meshes = mods, keepNormals = true} end
                    if #mods2 > 0 then
                        entries[#entries + 1] = {road = {persistentId = u.key .. "_modules_uv"}, meshes = mods2, keepNormals = true, secondUv = true}
                    end
                else
                    skipped = skipped + 1
                end
            end
        end
        if #entries == 0 then
            if removeCell(cell, levelPath) then removed = removed + 1 end
        else
            local origin    = {x = (c.ix + 0.5) * mr.daeCell, y = (c.iy + 0.5) * mr.daeCell}
            local file      = levelPath .. mr.daeDir .. "mage_" .. cell .. ".dae"
            local xml, _, t = mr.buildDae(entries, origin)
            if not mr.writeChecked(file, xml) then
                local status = tr("could not write %s", file)
                log('E', logTag, status)
                return status, false
            end
            if mr.placeStatic(file, mr.daePrefix .. cell, vec3(origin.x, origin.y, 0)) then placed = placed + 1 end
            rebuilt, tris = rebuilt + 1, tris + t
        end
    end

    if full then
        for _, nm in ipairs(scenetree.findClassObjects("TSStatic")) do
            local cell = nm:sub(1, #mr.daePrefix) == mr.daePrefix and nm:sub(#mr.daePrefix + 1)
            if cell and not byCell[cell] and removeCell(cell, levelPath) then removed = removed + 1 end
            for _, prefix in ipairs(mr.legacyPrefixes) do
                if nm:sub(1, #prefix) == prefix then
                    local o = scenetree.findObject(nm)
                    if o then
                        o:delete()
                        removed = removed + 1
                    end
                end
            end
        end
    end

    if (rebuilt + removed) > 0 then editor.setDirty() end

    local saved = {}
    for key, u in pairs(units) do saved[key] = {cell = u.cell, sig = u.sig} end
    local indexOk = C.writeJson(indexPath, {version = mr.indexVersion, config = cfgSig, units = saved})

    local status
    if #order == 0 then
        status = tr("everything is up to date")
    else
        status = tr(full and "rebuilt all: %d changed, %d areas rebuilt, %d triangles"
                          or "updated: %d changed, %d areas rebuilt, %d triangles", changed, rebuilt, tris)
        if removed > 0 then status = status .. ", " .. tr("%d empty areas removed", removed) end
        if placed > 0 then status = status .. ", " .. tr("%d new area objects", placed) end
        if skipped > 0 then status = status .. ", " .. tr("%d skipped", skipped) end
        status = status .. string.format(" - %.1f s", os.clock() - t0)
    end
    if not indexOk then status = status .. " " .. tr("(could not save the index - the next update rebuilds everything)") end
    log('I', logTag, status)
    return status, true
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.update         = update
M.sourcesOfCells = sourcesOfCells

return M
