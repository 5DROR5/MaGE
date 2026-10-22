-- =============================================================================
-- MaGE - walls from ready shapes
-- Version: 1.0.2
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local S = require("editor/mage/config/Settings")
local C = require("editor/mage/core/Common")

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local meshClass = "MeshRoad"
local marker    = "WarningMaterial"
local circleSeg = 24
local tol       = 1e-6

local order = {"circle", "ellipse", "rectangle", "polygon"}

local defaults = {
    kind   = "circle",
    radius = 10.0,
    sizeX  = 20.0,
    sizeY  = 12.0,
    sides  = 6,
    arc    = 360.0,
    turn   = 0.0,
    width  = 1.0,
    height = 4.0,
}

local limits = {
    radius = {1.0, 500.0},
    sizeX  = {1.0, 1000.0},
    sizeY  = {1.0, 1000.0},
    sides  = {3, 12},
    arc    = {1.0, 360.0},
    turn   = {-360.0, 360.0},
    width  = {0.1, 20.0},
    height = {0.2, 50.0},
}

local fieldsOf = {
    circle    = {"radius"},
    ellipse   = {"sizeX", "sizeY"},
    rectangle = {"sizeX", "sizeY"},
    polygon   = {"sides", "radius"},
}

-- =============================================================================
-- OUTLINE
-- =============================================================================

local function rotate(x, y, a)
    local c, s = math.cos(a), math.sin(a)
    return {x * c - y * s, x * s + y * c}
end

local function corners(o, turn)
    if o.kind == "rectangle" then
        local a, b = o.sizeX / 2.0, o.sizeY / 2.0
        local out  = {}
        for _, q in ipairs({{a, -b}, {a, b}, {-a, b}, {-a, -b}}) do out[#out + 1] = rotate(q[1], q[2], turn) end
        return out
    end
    local n   = math.floor(o.sides + 0.5)
    local out = {}
    for k = 0, n - 1 do
        local a = turn + (k / n) * 2.0 * math.pi
        if n == 4 then a = a + math.pi / 4.0 end
        out[#out + 1] = {math.cos(a) * o.radius, math.sin(a) * o.radius}
    end
    return out
end

local function walkSides(pts, frac)
    local n, total = #pts, 0.0
    local lens     = {}
    for k = 1, n do
        local a, b = pts[k], pts[k % n + 1]
        lens[k]    = math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
        total      = total + lens[k]
    end
    local left  = total * frac
    local sides = {}
    for k = 1, n do
        if left <= tol then break end
        local a, b = pts[k], pts[k % n + 1]
        local t    = math.min(1.0, left / lens[k])
        sides[#sides + 1] = {a, {a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t}}
        left = left - lens[k]
    end
    return sides
end

local function round(o, frac, turn)
    local rx, ry = o.radius, o.radius
    if o.kind == "ellipse" then rx, ry = o.sizeX / 2.0, o.sizeY / 2.0 end
    local seg = math.max(2, math.floor(circleSeg * frac + 0.5))
    local pts = {}
    for k = 0, seg do
        local a       = (k / seg) * frac * 2.0 * math.pi
        pts[#pts + 1] = rotate(math.cos(a) * rx, math.sin(a) * ry, turn)
    end
    if frac >= 1.0 - tol then pts[#pts] = {pts[1][1], pts[1][2]} end
    return {pts}
end

local function outline(o)
    local turn = math.rad(o.turn)
    local frac = math.max(limits.arc[1], math.min(limits.arc[2], o.arc)) / 360.0
    if o.kind == "circle" or o.kind == "ellipse" then return round(o, frac, turn) end
    return walkSides(corners(o, turn), frac)
end

-- =============================================================================
-- CREATING
-- =============================================================================

local function spawn(d)
    if d.id then SimObject.setForcedId(d.id) end
    d.id      = editor.createMesh(meshClass, d.nodes, {})
    local obj = scenetree.findObjectById(d.id)
    for _, key in ipairs(S.meshRoad.materialKeys) do obj:setField(key, 0, marker) end
    for name, value in pairs(d.dyn) do editor.setDynamicFieldValue(d.id, name, value, 0) end
end

local function unspawn(d)
    editor.deleteMesh(d.id)
end

local function create(at, o, dyn)
    local z, up = C.groundBelow(at) + o.height, vec3(0, 0, 1)
    local made  = {}
    C.transaction("MageShape", function()
        for _, line in ipairs(outline(o)) do
            local nodes = {}
            for _, q in ipairs(line) do
                nodes[#nodes + 1] = {pos = vec3(at.x + q[1], at.y + q[2], z), width = o.width, depth = o.height, normal = up}
            end
            local d = {nodes = nodes, dyn = dyn}
            editor.history:commitAction("MageShapeWall", d, unspawn, spawn)
            made[#made + 1] = d
        end
    end)
    local ids = {}
    for _, d in ipairs(made) do ids[#ids + 1] = d.id end
    return ids
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.defaults = defaults
M.limits   = limits
M.order    = order
M.fieldsOf = fieldsOf
M.outline  = outline
M.create   = create

return M
