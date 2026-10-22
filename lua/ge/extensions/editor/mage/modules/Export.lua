-- =============================================================================
-- MaGE - DAE file writer
-- Version: 1.0.2
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M      = {}
local logTag = 'mage'

local G  = require("editor/mage/core/Geometry")
local C  = require("editor/mage/core/Common")
local P  = require("editor/mage/modules/Preview")
local O  = require("editor/mage/modules/Overlap")
local MD = require("editor/mage/core/Modules")
local tr = C.tr
local mr = G.mr

-- =============================================================================
-- DAE
-- =============================================================================

mr.daeDir         = "art/shapes/mage/"
mr.daePrefix      = "mage_"
mr.partPrefix     = "magepart_"
mr.legacyPrefixes = {"pit_sidewalk_"}
mr.daeCell        = 200.0
mr.partDir        = "models/"
mr.trashDir       = "trash/"
mr.partFiles      = {}
mr.twinPrefix     = "mage_t"
mr.twinRoom       = 0.05
mr.twinTol        = 0.005

mr.indexFile    = "mage_index.json"
mr.indexVersion = 4

function mr.buildingCell(key)
    return "b" .. mr.daeName(key)
end

function mr.chainCell(key)
    return "c" .. mr.daeName(key)
end

function mr.daeName(s)
    return (tostring(s):gsub("[^%w_%-]", "_"))
end

local nums = {map = {}, n = 0}

function mr.num(v)
    local hit = v == v and nums.map[v]
    if hit then return hit end
    local t = string.format("%.4f", v):gsub("0+$", ""):gsub("%.$", "")
    if t == "" or t == "-" or t == "-0" then t = "0" end
    if v ~= v then return t end
    if nums.n >= 200000 then nums.map, nums.n = {}, 0 end
    nums.map[v], nums.n = t, nums.n + 1
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
    local cols, cIdx           = {"1 1 1 1"}, {["1 1 1 1"] = 0}
    local function key(arr, map, k)
        local i = map[k]
        if not i then i = #arr arr[i + 1] = k map[k] = i end
        return i
    end
    for _, sm in ipairs(meshes) do
        local f           = sm.faces
        local mat         = mr.daeName(sm.material or "WarningMaterial")
        local pm, um, um2 = {}, {}, {}
        local col         = sm.tint and key(cols, cIdx, mr.num(sm.tint[1]) .. " " .. mr.num(sm.tint[2]) .. " " .. mr.num(sm.tint[3]) .. " 1") or 0
        for k = 1, #f - 2, 3 do
            local cs          = {f[k], f[k + 2], f[k + 1]}
            local pi, ui, u2i = {}, {}, {}
            for j, c in ipairs(cs) do
                local x = pm[c.v]
                if not x then
                    local v          = sm.verts[c.v + 1]
                    local lx, ly, lz = v.x - origin.x, v.y - origin.y, v.z - (origin.z or 0.0)
                    x                = key(pos, pIdx, mr.num(lx) .. " " .. mr.num(ly) .. " " .. mr.num(lz))
                    if not coord[x] then coord[x] = vec3(lx, ly, lz) end
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
                tris[#tris + 1] = {p = pi, u = ui, u2 = u2i, n = n, tag = mr.daeTag(n), mat = mat, col = col}
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
    return {pos = pos, coord = coord, uvs = uvs, uvs2 = second and uvs2 or nil, tris = tris, mats = order, dropped = dropped, cols = cols}
end

function mr.daeSmooth(d)
    local tris, coord = d.tris, d.coord
    local edges       = {}
    local span        = #d.pos + 1
    local function edgeKey(a, b)
        if a < b then return a * span + b end
        return b * span + a
    end
    for ti, t in ipairs(tris) do
        for j = 1, 3 do
            local k = edgeKey(t.p[j], t.p[j % 3 + 1])
            local e = edges[k]
            if not e then e = {} edges[k] = e end
            e[#e + 1] = ti
        end
    end
    local function soft(a, b)
        local e = edges[edgeKey(a, b)]
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
                    idx[#idx] = idx[#idx] .. " " .. t.col
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
        src("col", d.cols, 4, {"R", "G", "B", "A"}),
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
    if obj then
        obj:setField('shapeName', 0, file)
        obj:setPosition(pos)
        return false
    end
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

function mr.isBuilding(cell)
    return cell:sub(1, 1) == "b"
end

function mr.poseOf(inst)
    local Z = inst.z
    if math.abs(Z.z - 1.0) > 1e-6 or math.abs(inst.x.z) > 1e-6 or math.abs(inst.y.z) > 1e-6 then return nil end
    local ly = inst.y:length()
    local lx = inst.x:length()
    if ly < 1e-9 or lx < 1e-9 then return nil end
    local Y = inst.y / ly
    local X = Y:cross(Z)
    if X:dot(inst.x / lx) < 1.0 - 1e-6 then return nil end
    local s   = vec3(inst.s.x * lx, inst.s.y * ly, inst.s.z)
    local pos = inst.o - inst.x * (inst.pv.x * inst.s.x) - inst.y * (inst.pv.y * inst.s.y) - Z * (inst.pv.z * inst.s.z)
    return {pos = vec3(pos.x, pos.y, pos.z), dir = vec3(Y.x, Y.y, 0), scale = s}
end

function mr.matrixOf(pos, dir)
    local q   = quatFromDir(vec3(dir.x, dir.y, 0), vec3(0, 0, 1))
    local mtx = QuatF(q.x, q.y, q.z, q.w):getMatrix()
    mtx:setPosition(vec3(pos.x, pos.y, pos.z))
    return mtx
end

function mr.instOf(inst)
    local p = mr.poseOf(inst)
    if not p then return nil end
    return {path = inst.path, mtx = mr.matrixOf(p.pos, p.dir), scale = p.scale}
end

function mr.splitParts(meshes)
    local count, rest, parts, seen = {}, {}, {}, {}
    for _, sm in ipairs(meshes) do
        if sm.inst then count[sm.inst] = (count[sm.inst] or 0) + 1 end
    end
    for _, sm in ipairs(meshes) do
        local inst = sm.inst
        if inst and count[inst] == inst.n and mr.instOf(inst) then
            if not seen[inst] then
                seen[inst]        = true
                parts[#parts + 1] = inst
            end
        else
            rest[#rest + 1] = sm
        end
    end
    return rest, parts
end

local function unstamped(xml)
    return (tostring(xml):gsub("\r\n", "\n"):gsub("<created>[^<]*</created><modified>[^<]*</modified>", ""))
end

function mr.partFile(inst, dir)
    if inst.path:sub(1, #MD.own) ~= MD.own and not inst.key then return inst.path end
    local stem = inst.path:match("([^/]+)%.dae$") .. (inst.key and ("_" .. inst.key:gsub("[^%w]", "_")) or "")
    local file = dir .. mr.partDir .. stem .. ".dae"
    if mr.partFiles[file] then return file end
    local second = false
    for _, sm in ipairs(inst.model.meshes) do second = second or sm.uvs2 ~= nil end
    local xml = mr.buildDae({{road = {persistentId = stem}, meshes = inst.model.meshes, keepNormals = true, secondUv = second}}, vec3(0, 0, 0))
    local cur = readFile(file)
    if not (cur and unstamped(cur) == unstamped(xml)) and not mr.writeChecked(file, xml) then return nil end
    mr.partFiles[file] = true
    return file
end

local function lead(path)
    local p = tostring(path)
    return (p:sub(1, 1) == "/") and p or ("/" .. p)
end

local function norm(path)
    return lead(path):lower()
end

local function shapesIn(obj, used, seen)
    obj = obj and Sim.upcast(obj)
    if not obj or seen[obj:getID()] then return end
    seen[obj:getID()] = true
    local cls = obj:getClassName()
    if cls == "TSStatic" then
        used[norm(obj:getField("shapeName", 0))] = true
    elseif cls == "Prefab" then
        local file = obj:getField("filename", 0)
        for sh in (file and file ~= "" and readFile(lead(file)) or ""):gmatch('"shapeName"%s*:%s*"([^"]+)"') do used[norm(sh)] = true end
    elseif cls == "SimGroup" or cls == "SimSet" then
        for i = 0, obj:getCount() - 1 do shapesIn(obj:getObject(i), used, seen) end
    end
end

function mr.sweepFiles(levelPath)
    local dir  = levelPath .. mr.daeDir
    local used = {}
    local root = Sim.findObject("MissionGroup")
    if not root then return 0 end
    shapesIn(root, used, {})
    for _, nm in ipairs(scenetree.findClassObjects("TSStatic") or {}) do
        local o = scenetree.findObject(nm)
        if o then used[norm(o:getField("shapeName", 0))] = true end
    end
    for _, f in ipairs(FS:findFiles(dir, "*.prefab.json", 0, true, false) or {}) do
        for sh in (readFile(tostring(f)) or ""):gmatch('"shapeName"%s*:%s*"([^"]+)"') do used[norm(sh)] = true end
    end
    local function move(from, to)
        local data = readFile(from)
        return data ~= nil and mr.writeChecked(to, data) and C.removeFile(from)
    end
    for _, f in ipairs(FS:findFiles(dir .. mr.trashDir, "*.dae", 0, true, false) or {}) do
        local back = dir .. lead(f):match("([^/]+)$")
        if used[norm(back)] then move(lead(f), back) end
    end
    local gone = 0
    for _, f in ipairs(FS:findFiles(dir .. mr.partDir, "*.dae", 0, true, false) or {}) do
        if not used[norm(f)] and C.removeFile(lead(f)) then gone = gone + 1 end
    end
    for _, f in ipairs(FS:findFiles(dir .. mr.partDir, mr.twinPrefix .. "*.json", 0, true, false) or {}) do
        if not used[norm(lead(f):gsub("%.json$", ".dae"))] then C.removeFile(lead(f)) end
    end
    for _, pattern in ipairs({"mageBAT_*.dae", "mageRA_*.dae"}) do
        for _, f in ipairs(FS:findFiles(dir, pattern, 0, true, false) or {}) do
            if not used[norm(f)] and move(lead(f), dir .. mr.trashDir .. lead(f):match("([^/]+)$")) then gone = gone + 1 end
        end
    end
    if gone > 0 then mr.partFiles = {} end
    return gone
end

local function emptyTrash()
    local levelPath = editor.getLevelPath()
    if not levelPath or levelPath == "" then return end
    for _, f in ipairs(FS:findFiles(levelPath .. mr.daeDir .. mr.trashDir, "*.dae", 0, true, false) or {}) do C.removeFile(lead(f)) end
end

function mr.newStatic(file, mtx, scale)
    local obj = createObject('TSStatic')
    obj:setField('shapeName', 0, file)
    obj:setTransform(mtx)
    obj:setScale(scale)
    obj:setField('collisionType', 0, 'Collision Mesh')
    obj:setField('decalType', 0, 'Collision Mesh')
    return obj
end

function mr.placeGroup(file, name, kids)
    local old = scenetree.findObject(name)
    if old then old:delete() end
    local group = SimGroup()
    group:setField("groupPosition", "", "0 0 0")
    group:registerObject(Sim.getUniqueName(name .. "_parts"))
    for k, obj in ipairs(kids) do
        obj:setCanSave(true)
        obj:registerObject(Sim.getUniqueName(mr.partPrefix .. name:sub(#mr.daePrefix + 1) .. "_" .. k))
        group:addObject(obj)
    end
    local prefab = Prefab()
    prefab:setTransform(MatrixF(true))
    prefab:registerObject(name)
    scenetree.MissionGroup:addObject(prefab)
    prefab:setChildGroup(name, group)
    local ok = prefab:save(file, false)
    prefab.filename = String(file)
    prefab:setLoadMode(0)
    return ok, #kids - 1
end

function mr.placePrefab(file, shell, name, origin, parts)
    local dir, placed = file:match("^(.*/)[^/]*$"), {}
    for _, inst in ipairs(parts) do
        local path = mr.partFile(inst, dir)
        if not path then return false, 0 end
        placed[#placed + 1] = {p = mr.instOf(inst), path = path}
    end
    local base = MatrixF(true)
    base:setPosition(vec3(origin.x, origin.y, origin.z))
    local kids = {mr.newStatic(shell, base, vec3(1, 1, 1))}
    for _, e in ipairs(placed) do kids[#kids + 1] = mr.newStatic(e.path, e.p.mtx, e.p.scale) end
    return mr.placeGroup(file, name, kids)
end

function mr.stripOf(road)
    local pts, ws     = road.points or {}, road.widths or {}
    local right, left = {}, {}
    for i, p in ipairs(pts) do
        local a, b   = pts[math.max(1, i - 1)], pts[math.min(#pts, i + 1)]
        local tx, ty = b.x - a.x, b.y - a.y
        local l      = math.sqrt(tx * tx + ty * ty)
        local sx, sy = 0.0, 0.0
        if l > 1e-9 then sx, sy = ty / l, -tx / l end
        local h              = (ws[i] or 0.0) / 2.0
        right[#right + 1]    = {p.x + sx * h, p.y + sy * h}
        left[#pts - i + 1]   = {p.x - sx * h, p.y - sy * h}
    end
    for _, q in ipairs(left) do right[#right + 1] = q end
    return right
end

local function inStrip(poly, x, y)
    local hit, j = false, #poly
    for i = 1, #poly do
        local a, b = poly[i], poly[j]
        if (a[2] > y) ~= (b[2] > y) and x < (b[1] - a[1]) * (y - a[2]) / (b[2] - a[2]) + a[1] then hit = not hit end
        j = i
    end
    return hit
end

local function toEdges(poly, x, y)
    local best = math.huge
    for i = 1, #poly do
        local a, b   = poly[i], poly[i % #poly + 1]
        local dx, dy = b[1] - a[1], b[2] - a[2]
        local l2     = dx * dx + dy * dy
        local u      = (l2 > 1e-12) and math.max(0.0, math.min(1.0, ((x - a[1]) * dx + (y - a[2]) * dy) / l2)) or 0.0
        best         = math.min(best, math.sqrt((a[1] + dx * u - x) ^ 2 + (a[2] + dy * u - y) ^ 2))
    end
    return best
end

local function crossing(a, b, c, d)
    local function side(p, q, r) return (q[1] - p[1]) * (r[2] - p[2]) - (q[2] - p[2]) * (r[1] - p[1]) end
    local d1, d2 = side(a, b, c), side(a, b, d)
    local d3, d4 = side(c, d, a), side(c, d, b)
    return ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0))
end

function mr.bulgeOf(road)
    local pts, best = road.points or {}, 0.0
    for i = 2, #pts do
        local p0, p1, p2, p3 = pts[math.max(1, i - 2)], pts[i - 1], pts[i], pts[math.min(#pts, i + 1)]
        local mx             = 0.5 * (p1.x + p2.x) + (p0.x + p3.x - p1.x - p2.x) * -0.0625
        local my             = 0.5 * (p1.y + p2.y) + (p0.y + p3.y - p1.y - p2.y) * -0.0625
        local tx, ty         = p2.x - p1.x, p2.y - p1.y
        local l              = math.sqrt(tx * tx + ty * ty)
        if l > 1e-9 then best = math.max(best, math.abs((mx - p1.x) * ty - (my - p1.y) * tx) / l) end
    end
    return best
end

function mr.gapOf(a, b)
    for i = 1, #a do
        for j = 1, #b do
            if crossing(a[i], a[i % #a + 1], b[j], b[j % #b + 1]) then return 0.0 end
        end
    end
    local best = math.huge
    for _, v in ipairs(a) do
        if inStrip(b, v[1], v[2]) then return 0.0 end
        best = math.min(best, toEdges(b, v[1], v[2]))
    end
    for _, v in ipairs(b) do
        if inStrip(a, v[1], v[2]) then return 0.0 end
        best = math.min(best, toEdges(a, v[1], v[2]))
    end
    return best
end

function mr.reachOf(meshes, strips, from)
    local best = from or 0.0
    for _, sm in ipairs(meshes) do
        for _, v in ipairs(sm.verts or {}) do
            local d = math.huge
            for _, st in ipairs(strips) do
                if inStrip(st, v.x, v.y) then
                    d = 0.0
                    break
                end
                d = math.min(d, toEdges(st, v.x, v.y))
            end
            if d < math.huge then best = math.max(best, d) end
        end
    end
    return best
end

local function turn(x, y, a)
    local c, s = math.cos(a), math.sin(a)
    return x * c - y * s, x * s + y * c
end

function mr.sameShape(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
    for i = 1, #a do
        if type(a[i]) ~= "number" or math.abs(a[i] - b[i]) > mr.twinTol then return false end
    end
    return true
end

function mr.twinRecord(levelPath, twin, frame, origin, shell, parts, reach, vec)
    local dir = levelPath .. mr.daeDir
    local rec = {frame = frame, origin = {x = origin.x, y = origin.y, z = origin.z}, shell = shell, parts = {}, reach = reach, vec = vec}
    for _, inst in ipairs(parts) do
        local path = mr.partFile(inst, dir)
        local p    = mr.poseOf(inst)
        if not (path and p) then return nil end
        local x, y   = turn(p.pos.x - frame.x, p.pos.y - frame.y, -frame.r)
        local dx, dy = turn(p.dir.x, p.dir.y, -frame.r)
        rec.parts[#rec.parts + 1] = {path = path, x = x, y = y, z = p.pos.z - frame.z, dx = dx, dy = dy, sx = p.scale.x, sy = p.scale.y, sz = p.scale.z}
    end
    if not C.writeJson(dir .. mr.partDir .. mr.twinPrefix .. twin .. ".json", rec) then return nil end
    return rec
end

function mr.readTwin(levelPath, twin)
    local rec = C.readJson(levelPath .. mr.daeDir .. mr.partDir .. mr.twinPrefix .. twin .. ".json")
    if type(rec) ~= "table" or type(rec.frame) ~= "table" or type(rec.origin) ~= "table" or type(rec.shell) ~= "string" or type(rec.parts) ~= "table" then return nil end
    for _, k in ipairs({"x", "y", "z", "r"}) do
        if type(rec.frame[k]) ~= "number" then return nil end
    end
    for _, k in ipairs({"x", "y", "z"}) do
        if type(rec.origin[k]) ~= "number" then return nil end
    end
    if type(rec.reach) ~= "number" or type(rec.vec) ~= "table" then return nil end
    for _, p in ipairs(rec.parts) do
        if type(p) ~= "table" or type(p.path) ~= "string" then return nil end
        for _, k in ipairs({"x", "y", "z", "dx", "dy", "sx", "sy", "sz"}) do
            if type(p[k]) ~= "number" then return nil end
        end
    end
    if not readFile(lead(rec.shell)) then return nil end
    return rec
end

function mr.placeTwin(file, name, rec, frame)
    local d      = frame.r - rec.frame.r
    local ox, oy = turn(rec.frame.x - rec.origin.x, rec.frame.y - rec.origin.y, d)
    local sx, sy = turn(0.0, 1.0, d)
    local kids   = {mr.newStatic(rec.shell, mr.matrixOf(vec3(frame.x - ox, frame.y - oy, frame.z - (rec.frame.z - rec.origin.z)), vec3(sx, sy, 0)), vec3(1, 1, 1))}
    for _, p in ipairs(rec.parts) do
        local x, y   = turn(p.x, p.y, frame.r)
        local dx, dy = turn(p.dx, p.dy, frame.r)
        kids[#kids + 1] = mr.newStatic(p.path, mr.matrixOf(vec3(frame.x + x, frame.y + y, frame.z + p.z), vec3(dx, dy, 0)), vec3(p.sx, p.sy, p.sz))
    end
    return mr.placeGroup(file, name, kids)
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
        elseif t == "cdata" then
            parts[#parts + 1] = mr.num(v.x) .. "," .. mr.num(v.y) .. "," .. mr.num(v.z)
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
    if road.building and road.home then return mr.buildingCell(road.building), road.home end
    if road.chain then
        local lx, ly, hx, hy, lz = math.huge, math.huge, -math.huge, -math.huge, math.huge
        for i, p in ipairs(road.points) do
            lx, ly = math.min(lx, p.x), math.min(ly, p.y)
            hx, hy = math.max(hx, p.x), math.max(hy, p.y)
            lz     = math.min(lz, p.z - (road.depths and road.depths[i] or 0.0))
        end
        local function round(v) return math.floor(v * 100.0 + 0.5) / 100.0 end
        return mr.chainCell(road.chain), {x = round((lx + hx) / 2.0), y = round((ly + hy) / 2.0), z = round(lz)}
    end
    local pts = road.points or road.ring
    if not pts or #pts == 0 then return nil end
    local lx, ly, hx, hy = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(pts) do
        lx, ly = math.min(lx, p.x), math.min(ly, p.y)
        hx, hy = math.max(hx, p.x), math.max(hy, p.y)
    end
    local ix = math.floor((lx + hx) / 2.0 / mr.daeCell)
    local iy = math.floor((ly + hy) / 2.0 / mr.daeCell)
    return mr.cellTag(ix) .. "_" .. mr.cellTag(iy), {x = (ix + 0.5) * mr.daeCell, y = (iy + 0.5) * mr.daeCell, z = 0.0}
end

mr.cellOf = cellOf

local function unitsOf(paths)
    local list = {}
    for _, road in ipairs(paths) do
        local cell, origin = cellOf(road)
        if cell then
            local sig = sigOf(road)
            if mr.isBuilding(cell) then sig = C.hash(sig .. "|" .. MD.layout()) end
            list[#list + 1] = {
                road = road, cell = cell, origin = origin, sig = sig,
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
    for _, road in ipairs(P.collectUnits(ids or {}).paths) do
        if cells[cellOf(road) or ""] then
            for _, sid in ipairs(road.srcIds or {road.id}) do
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

local function nearCells(ids, cells)
    local boxes = {}
    for cell in pairs(cells) do
        local x, y = cell:match("^(m?%d+)_(m?%d+)$")
        if x then
            local ix = tonumber((x:gsub("^m", "-")))
            local iy = tonumber((y:gsub("^m", "-")))
            boxes[#boxes + 1] = {(ix - 1) * mr.daeCell, (iy - 1) * mr.daeCell, (ix + 2) * mr.daeCell, (iy + 2) * mr.daeCell}
        end
    end
    local out = {}
    for _, id in ipairs(ids) do
        local obj  = scenetree.findObjectById(id)
        local near = false
        for i = 0, (obj and obj:getNodeCount() or 0) - 1 do
            local p = obj:getNodePosition(i)
            for _, b in ipairs(boxes) do
                if p.x >= b[1] and p.y >= b[2] and p.x <= b[3] and p.y <= b[4] then near = true end
            end
            if near then break end
        end
        if near then out[#out + 1] = id end
    end
    return out
end

local function contextOf(sel, candidates)
    local cells = {}
    for _, road in ipairs(P.collectUnits(sel).paths) do
        local cell = cellOf(road)
        if cell and not cell:find("^[bc]") and scenetree.findObject(mr.daePrefix .. cell) then cells[cell] = true end
    end
    local out, seen = {}, {}
    for _, id in ipairs(sel) do
        seen[id]      = true
        out[#out + 1] = id
    end
    if next(cells) == nil then return out end
    local idx  = C.readJson(editor.getLevelPath() .. mr.daeDir .. mr.indexFile)
    local want = {}
    for _, u in pairs(type(idx) == "table" and type(idx.units) == "table" and idx.units or {}) do
        if type(u) == "table" and cells[u.cell] then
            if type(u.src) ~= "table" then
                want = nil
                break
            end
            for _, pid in ipairs(u.src) do want[tostring(pid)] = true end
        end
    end
    if want then
        for _, id in ipairs(candidates) do
            if not seen[id] and want[tostring(P.identOf(id))] then
                seen[id]      = true
                out[#out + 1] = id
            end
        end
        return out
    end
    for _, id in ipairs(sourcesOfCells(nearCells(candidates, cells), cells)) do
        if not seen[id] then
            seen[id]      = true
            out[#out + 1] = id
        end
    end
    return out
end

-- =============================================================================
-- UPDATE
-- =============================================================================

function mr.addEntries(entries, road, key, meshes)
    local own, mods, mods2 = {}, {}, {}
    for _, sm in ipairs(meshes) do
        local list = (not sm.module and own) or (sm.uvs2 and mods2) or mods
        list[#list + 1] = sm
    end
    if #own > 0 then entries[#entries + 1] = {road = road, meshes = own} end
    if #mods > 0 then entries[#entries + 1] = {road = {persistentId = key .. "_modules"}, meshes = mods, keepNormals = true} end
    if #mods2 > 0 then entries[#entries + 1] = {road = {persistentId = key .. "_modules_uv"}, meshes = mods2, keepNormals = true, secondUv = true} end
end

local function bake(ids, origin)
    if not G.getStyleCfg() then P.loadStyles() end
    if not G.getStyleCfg() then return nil, tostring(G.getStyleErr()) end
    local paths   = P.collectUnits(ids).paths
    local plan    = O.plan(paths)
    local cache   = {}
    local entries = {}
    for k, road in ipairs(paths) do
        local meshes = O.build(road, plan, P.buildUnit, cache)
        if meshes then
            for _, sm in ipairs(meshes) do
                if sm.module or sm.material == MD.darkMat then P.needMat(sm.material) end
            end
            mr.addEntries(entries, road, mr.daeName(road.persistentId or road.name or road.id) .. "_" .. k, meshes)
        end
    end
    if #entries == 0 then return nil, tr("nothing to build") end
    local xml, _, tris = mr.buildDae(entries, origin)
    return xml, tris
end

local function savePrefab(file, shell)
    local name  = Sim.getUniqueName("mage_export_prefab")
    local group = SimGroup()
    group:setField("groupPosition", "", "0 0 0")
    group:registerObject(Sim.getUniqueName(name .. "_parts"))
    local obj = mr.newStatic(shell, MatrixF(true), vec3(1, 1, 1))
    obj:setCanSave(true)
    obj:registerObject(Sim.getUniqueName("mage_export_shape"))
    group:addObject(obj)
    local prefab = Prefab()
    prefab:setTransform(MatrixF(true))
    prefab:registerObject(name)
    scenetree.MissionGroup:addObject(prefab)
    prefab:setChildGroup(name, group)
    local ok = prefab:save(file, false)
    prefab:delete()
    return ok ~= false
end

local function removeCell(cell, levelPath)
    local o = scenetree.findObject(mr.daePrefix .. cell)
    if levelPath then
        C.removeFile(levelPath .. mr.daeDir .. "mage_" .. cell .. ".dae")
        if mr.isBuilding(cell) then C.removeFile(levelPath .. mr.daeDir .. "mage_" .. cell .. ".prefab.json") end
    end
    if o then
        o:delete()
        return true
    end
    return false
end

local function update(ids, full)
    if not G.getStyleCfg() then P.loadStyles() end
    if not G.getStyleCfg() then return tostring(G.getStyleErr()), false end
    if not G.curbMaterialName() then return tr("curb.material is not set in the styles config"), false end
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
            c              = {origin = u.origin, units = {}}
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
            local o = scenetree.findObject(mr.daePrefix .. cell)
            if not o or (mr.isBuilding(cell) and o:getClassName() ~= "Prefab") then dirty[cell] = true end
        end
    end

    local order = {}
    for cell in pairs(dirty) do order[#order + 1] = cell end
    table.sort(order)

    local rebuilt, removed, placed, skipped, tris = 0, 0, 0, 0, 0
    local objects, shared                         = 0, 0
    local failed                                  = {}
    local twins                                   = {}
    local function twinOf(c, cell)
        local B                = require("editor/mage/modules/Building")
        local road             = c.units[1].road
        local home             = road.building and B.ofKey(road.building)
        local text, frame, vec = nil, nil, nil
        if home then text, frame, vec = B.twinOf(home) end
        if not text then return nil end
        return C.hash(text .. "|" .. MD.layout() .. "|" .. cfgSig):sub(1, 24), frame, vec
    end
    local function roomOf(c, cell)
        local room = math.huge
        for _, u in ipairs(c.units) do
            for _, nb in ipairs(plan.neighbors[u.road] or {}) do
                if cellOf(nb) ~= cell then room = math.min(room, mr.gapOf(mr.stripOf(u.road), mr.stripOf(nb)) - mr.bulgeOf(nb)) end
            end
        end
        return room
    end
    for _, cell in ipairs(order) do
        local c                = byCell[cell]
        local entries          = {}
        local parts            = {}
        local split            = mr.isBuilding(cell)
        local twin, frame, vec = nil, nil, nil
        if split and c then twin, frame, vec = twinOf(c, cell) end
        local rec    = twin and (twins[twin] or (not full and mr.readTwin(levelPath, twin)) or nil)
        local reused = false
        local room   = twin and roomOf(c, cell)
        if rec and (room <= rec.reach + mr.twinRoom or not mr.sameShape(rec.vec, vec)) then rec, twin = nil, nil end
        if rec then
            twins[twin] = rec
            local fresh = not scenetree.findObject(mr.daePrefix .. cell)
            local ok, n = mr.placeTwin(levelPath .. mr.daeDir .. "mage_" .. cell .. ".prefab.json", mr.daePrefix .. cell, rec, frame)
            if not ok then
                local status = tr("could not write %s", levelPath .. mr.daeDir .. "mage_" .. cell .. ".prefab.json")
                log('E', logTag, status)
                return status, false
            end
            C.removeFile(levelPath .. mr.daeDir .. "mage_" .. cell .. ".dae")
            if fresh then placed = placed + 1 end
            objects, shared, reused = objects + n, shared + 1, true
        end
        local strips, reach = {}, 0.0
        if c and not reused then
            table.sort(c.units, function(a, b) return a.key < b.key end)
            for _, u in ipairs(c.units) do
                local meshes, err = O.build(u.road, plan, P.buildUnit, buildCache)
                if twin then
                    strips[#strips + 1] = mr.stripOf(u.road)
                    reach               = math.max(reach, mr.reachOf((buildCache[u.road] and buildCache[u.road].meshes) or meshes or {}, {strips[#strips]}))
                end
                if not meshes then
                    skipped = skipped + 1
                    if err == P.buildError then failed[cell] = true end
                else
                    for _, sm in ipairs(meshes) do
                        if sm.module or sm.material == MD.darkMat then P.needMat(sm.material) end
                    end
                    if split then
                        local found
                        meshes, found = mr.splitParts(meshes)
                        for _, inst in ipairs(found) do parts[#parts + 1] = inst end
                    end
                    mr.addEntries(entries, u.road, u.key, meshes)
                end
            end
        end
        if reused then
            rebuilt = rebuilt + 1
        elseif failed[cell] then
            log('W', logTag, "kept the previous build of area " .. cell)
        elseif #entries == 0 and #parts == 0 then
            if removeCell(cell, levelPath) then removed = removed + 1 end
        else
            local origin    = c.origin
            local file      = levelPath .. mr.daeDir .. "mage_" .. cell .. ".dae"
            if twin and room <= reach + mr.twinRoom then twin = nil end
            if twin then file = levelPath .. mr.daeDir .. mr.partDir .. mr.twinPrefix .. twin .. ".dae" end
            local xml, _, t = mr.buildDae(entries, origin)
            if not mr.writeChecked(file, xml) then
                local status = tr("could not write %s", file)
                log('E', logTag, status)
                return status, false
            end
            local rec = twin and mr.twinRecord(levelPath, twin, frame, origin, file, parts, reach, vec)
            if rec then
                twins[twin] = rec
                C.removeFile(levelPath .. mr.daeDir .. "mage_" .. cell .. ".dae")
                local fresh = not scenetree.findObject(mr.daePrefix .. cell)
                local ok, n = mr.placeTwin(levelPath .. mr.daeDir .. "mage_" .. cell .. ".prefab.json", mr.daePrefix .. cell, rec, frame)
                if not ok then
                    local status = tr("could not write %s", levelPath .. mr.daeDir .. "mage_" .. cell .. ".prefab.json")
                    log('E', logTag, status)
                    return status, false
                end
                if fresh then placed = placed + 1 end
                objects = objects + n
            elseif twin then
                local status = tr("could not write %s", levelPath .. mr.daeDir .. mr.partDir .. mr.twinPrefix .. twin .. ".json")
                log('E', logTag, status)
                return status, false
            elseif split then
                local fresh = not scenetree.findObject(mr.daePrefix .. cell)
                local ok, n = mr.placePrefab(levelPath .. mr.daeDir .. "mage_" .. cell .. ".prefab.json", file, mr.daePrefix .. cell, origin, parts)
                if not ok then
                    local status = tr("could not write %s", levelPath .. mr.daeDir .. "mage_" .. cell .. ".prefab.json")
                    log('E', logTag, status)
                    return status, false
                end
                if fresh then placed = placed + 1 end
                objects = objects + n
            elseif mr.placeStatic(file, mr.daePrefix .. cell, vec3(origin.x, origin.y, origin.z)) then
                placed = placed + 1
            end
            rebuilt, tris = rebuilt + 1, tris + t
        end
    end

    if full then
        local names = scenetree.findClassObjects("TSStatic") or {}
        for _, nm in ipairs(scenetree.findClassObjects("Prefab") or {}) do names[#names + 1] = nm end
        for _, nm in ipairs(names) do
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
    for key, u in pairs(units) do
        if not failed[u.cell] then
            local src = {}
            for _, sid in ipairs(u.road.srcIds or {u.road.id}) do src[#src + 1] = P.identOf(sid) end
            table.sort(src)
            saved[key] = {cell = u.cell, sig = u.sig, src = src}
        end
    end
    local indexOk = C.writeJson(indexPath, {version = mr.indexVersion, config = cfgSig, units = saved})

    local swept = mr.sweepFiles(levelPath)
    local status
    if #order == 0 then
        status = tr("everything is up to date")
    else
        status = tr(full and "rebuilt all: %d changed, %d areas rebuilt, %d triangles"
                          or "updated: %d changed, %d areas rebuilt, %d triangles", changed, rebuilt, tris)
        if removed > 0 then status = status .. ", " .. tr("%d empty areas removed", removed) end
        if placed > 0 then status = status .. ", " .. tr("%d new area objects", placed) end
        if objects > 0 then status = status .. ", " .. tr("%d windows, doors and other parts placed as their own objects", objects) end
        if shared > 0 then status = status .. ", " .. tr("%d buildings use a model already built for a copy of them", shared) end
        if skipped > 0 then status = status .. ", " .. tr("%d skipped", skipped) end
        status = status .. string.format(" - %.1f s", os.clock() - t0)
    end
    if swept > 0 then status = status .. ", " .. tr("%d files no longer used removed", swept) end
    if not indexOk then status = status .. " " .. tr("(could not save the index - the next update rebuilds everything)") end
    return status, true
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.update         = update
M.bake           = bake
M.savePrefab     = savePrefab
M.emptyTrash     = emptyTrash
M.sourcesOfCells = sourcesOfCells
M.contextOf      = contextOf

return M
