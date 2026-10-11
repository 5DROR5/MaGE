-- =============================================================================
-- MaGE - Road Architect capture
-- Version: 1.0.0
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M      = {}
local logTag = 'mage'

local G  = require("editor/mage/core/Geometry")
local C  = require("editor/mage/core/Common")
local mr = G.mr
local tr = C.tr

require("editor/mage/modules/Export")

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local raModule    = "editor/tech/roadArchitect/roadMesh"
local objPrefix   = "mageRA_"
local snapMaxLift = 2.0

-- =============================================================================
-- STATE
-- =============================================================================

local installedFor = nil
local hooks        = {}
local roads        = {}
local bridges      = {}
local snapTerrain  = true

-- =============================================================================
-- CAPTURE
-- =============================================================================

local function proxyFor(real, onMesh)
    local proxy = {}
    return setmetatable(proxy, {
        __index = function(_, k)
            if k == "createMesh" then
                return function(_, data)
                    onMesh(real, data)
                    return real:createMesh(data)
                end
            end
            local v = real[k]
            if type(v) == "function" then
                return function(self, ...)
                    if self == proxy then return v(real, ...) end
                    return v(self, ...)
                end
            end
            return v
        end,
        __newindex = function(_, k, v) real[k] = v end,
    })
end

local function terrainRay(orig)
    return function(p, dir, len, ...)
        local hit    = orig(p, dir, len, ...)
        local isDown = (type(dir) == "cdata" or type(dir) == "table") and type(dir.z) == "number" and dir.z < -0.99
        if not isDown then return hit end
        local ok, tz = pcall(core_terrain.getTerrainHeight, vec3(p.x, p.y, 0))
        if not ok or type(tz) ~= "number" then return hit end
        local down = p.z - tz
        if down < 0 or (type(len) == "number" and down > len) then return hit end
        if type(hit) == "number" and down - hit > snapMaxLift then return hit end
        return down
    end
end

local function capture(fn, ...)
    local parts = {}
    local orig  = createObject
    local ray   = castRayStatic
    if snapTerrain and type(ray) == "function" then castRayStatic = terrainRay(ray) end
    createObject = function(cls, ...)
        local o = orig(cls, ...)
        if cls ~= "ProceduralMesh" or not o then return o end
        return proxyFor(o, function(real, data)
            local list = type(data) == "table" and data[1]
            if type(list) ~= "table" then return end
            for _, sm in ipairs(list) do
                if type(sm) == "table" and type(sm.verts) == "table" then
                    parts[#parts + 1] = {obj = real, mesh = sm}
                end
            end
        end)
    end
    local ok, err = pcall(fn, ...)
    createObject  = orig
    castRayStatic = ray
    if not ok then error(err, 0) end
    return parts
end

local function hook(rm, key, make)
    local f = rm[key]
    if type(f) ~= "function" then return end
    local w = make(f)
    hooks[#hooks + 1] = {key = key, orig = f, wrap = w}
    rm[key] = w
end

local function install()
    local rm = package.loaded[raModule]
    if type(rm) ~= "table" or rm == installedFor then return end
    installedFor, hooks = rm, {}

    hook(rm, "createRoad", function(f)
        return function(r, ...)
            local parts = capture(f, r, ...)
            if type(r) == "table" and r.name then roads[r.name] = parts end
        end
    end)
    hook(rm, "updateBridge", function(f)
        return function(r, ...)
            local parts = capture(f, r, ...)
            if type(r) == "table" and r.name then bridges[r.name] = parts end
        end
    end)
    hook(rm, "tryRemove", function(f)
        return function(name, ...)
            roads[name] = nil
            return f(name, ...)
        end
    end)
    hook(rm, "tryRemoveBridge", function(f)
        return function(name, ...)
            bridges[name] = nil
            return f(name, ...)
        end
    end)
    hook(rm, "clearBridges", function(f)
        return function(...)
            bridges = {}
            return f(...)
        end
    end)
end

local function uninstall()
    if installedFor then
        for _, h in ipairs(hooks) do
            if installedFor[h.key] == h.wrap then installedFor[h.key] = h.orig end
        end
    end
    installedFor, hooks = nil, {}
end

-- =============================================================================
-- BAKE
-- =============================================================================

local function capturedNames()
    local names, seen = {}, {}
    for _, set in ipairs({roads, bridges}) do
        for name, parts in pairs(set) do
            if #parts > 0 and not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
    end
    table.sort(names, function(a, b) return tostring(a) < tostring(b) end)
    return names
end

local function counts()
    local meshes = 0
    for _, set in ipairs({roads, bridges}) do
        for _, parts in pairs(set) do meshes = meshes + #parts end
    end
    return #capturedNames(), meshes
end

local function bake()
    local levelPath = C.levelDir()
    if not levelPath then return "no level loaded" end
    local names = capturedNames()
    if #names == 0 then return "no Road Architect meshes captured yet - finalise the roads first" end

    local written, tris = 0, 0
    for _, name in ipairs(names) do
        local meshes, objs           = {}, {}
        local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
        for _, set in ipairs({roads, bridges}) do
            for _, p in ipairs(set[name] or {}) do
                meshes[#meshes + 1] = p.mesh
                objs[#objs + 1]     = p.obj
                for _, v in ipairs(p.mesh.verts) do
                    minX, maxX = math.min(minX, v.x), math.max(maxX, v.x)
                    minY, maxY = math.min(minY, v.y), math.max(maxY, v.y)
                end
            end
        end
        local origin    = {x = (minX + maxX) / 2, y = (minY + maxY) / 2}
        local key       = objPrefix .. mr.daeName(name)
        local file      = levelPath .. mr.daeDir .. key .. ".dae"
        local xml, _, t = mr.buildDae({{road = {name = name}, meshes = meshes, keepNormals = true}}, origin)
        if (t or 0) > 0 and mr.writeChecked(file, xml) then
            local pos = vec3(origin.x, origin.y, 0)
            local obj = scenetree.findObject(key)
            if obj then
                obj:setField('shapeName', 0, file)
                obj:setPosition(pos)
            else
                mr.placeStatic(file, key, pos)
            end
            for _, o in ipairs(objs) do o.hidden = true end
            written, tris = written + 1, tris + t
        else
            log('E', logTag, "writing failed: " .. file)
        end
    end
    editor.setDirty()
    return tr("saved %d Road Architect roads, %d triangles", written, tris)
end

local function sourcesOf(objName)
    local out, seen = {}, {}
    for _, set in ipairs({roads, bridges}) do
        for name, parts in pairs(set) do
            if objPrefix .. mr.daeName(name) == objName then
                for _, p in ipairs(parts) do
                    if not seen[p.obj] then
                        seen[p.obj]   = true
                        out[#out + 1] = p.obj
                    end
                end
            end
        end
    end
    return out
end

local function reset()
    roads, bridges = {}, {}
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.install   = install
M.uninstall = uninstall
M.bake      = bake
M.counts    = counts
M.reset     = reset
M.sourcesOf = sourcesOf
M.snap      = function() return snapTerrain end
M.setSnap   = function(v) snapTerrain = v and true or false end

return M
