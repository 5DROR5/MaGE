-- =============================================================================
-- MaGE - Building Architect modules
-- Version: 1.0.0
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M      = {}
local logTag = 'mage'

local Collada = require("editor/mage/core/Collada")

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local root    = "/art/shapes/common/building_architect_modules/"
local kinds   = {windows = "windows", doors = "doors"}
local defWin  = root .. "windows/R_HS_A_WN_01_120x130.dae"
local defDoor = root .. "doors/R_HS_A_DR_01_100x210.dae"

-- =============================================================================
-- STATE
-- =============================================================================

local models = {}
local lists  = {}

-- =============================================================================
-- MODELS
-- =============================================================================

local function model(path)
    local hit = models[path]
    if hit ~= nil then return hit or nil end
    local text   = readFile(path)
    local meshes = type(text) == "string" and Collada.read(text) or nil
    if not meshes or #meshes == 0 then
        models[path] = false
        log('E', logTag, "cannot read module " .. tostring(path))
        return nil
    end
    local lo = {x = math.huge, y = math.huge, z = math.huge}
    local hi = {x = -math.huge, y = -math.huge, z = -math.huge}
    for _, sm in ipairs(meshes) do
        for _, v in ipairs(sm.verts) do
            lo.x, lo.y, lo.z = math.min(lo.x, v.x), math.min(lo.y, v.y), math.min(lo.z, v.z)
            hi.x, hi.y, hi.z = math.max(hi.x, v.x), math.max(hi.y, v.y), math.max(hi.z, v.z)
        end
    end
    local m      = {meshes = meshes, lo = lo, hi = hi}
    models[path] = m
    return m
end

local function size(path)
    local w, h = tostring(path):match("_(%d+)[xX](%d+)%.dae$")
    if not w then return nil end
    return tonumber(w) / 100.0, tonumber(h) / 100.0
end

local function list(kind)
    if lists[kind] then return lists[kind] end
    local out = {}
    for _, f in ipairs(FS:findFiles(root .. kinds[kind], "*.dae", -1, true, false) or {}) do
        local p = tostring(f)
        if p:sub(1, 1) ~= "/" then p = "/" .. p end
        if size(p) then out[#out + 1] = p end
    end
    table.sort(out)
    lists[kind] = out
    return out
end

local function label(path)
    local name = tostring(path):match("([^/]+)%.dae$") or tostring(path)
    local w, h = size(path)
    if not w then return name end
    return string.format("%s  (%g x %g)", (name:gsub("_%d+[xX]%d+$", "")), w, h)
end

-- =============================================================================
-- PLACING
-- =============================================================================

local function place(m, origin, inward)
    local Y   = vec3(inward.x, inward.y, 0):normalized()
    local Z   = vec3(0, 0, 1)
    local X   = Y:cross(Z)
    local out = {}
    for _, sm in ipairs(m.meshes) do
        local o = {verts = {}, normals = {}, uvs = sm.uvs, uvs2 = sm.uvs2, faces = sm.faces, material = sm.material, module = true}
        for i, v in ipairs(sm.verts) do
            o.verts[i] = origin + X * v.x + Y * v.y + Z * (v.z - m.lo.z)
        end
        for i, n in ipairs(sm.normals) do
            o.normals[i] = (X * n.x + Y * n.y + Z * n.z):normalized()
        end
        out[#out + 1] = o
    end
    return out
end

local function reset()
    models, lists = {}, {}
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.root    = root
M.defWin  = defWin
M.defDoor = defDoor
M.model   = model
M.size    = size
M.list    = list
M.label   = label
M.place   = place
M.reset   = reset

return M
