-- =============================================================================
-- MaGE - bridge walls
-- Version: 1.0.0
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local G = require("editor/mage/core/Geometry")
local W = require("editor/mage/modules/EdgeWall")

-- =============================================================================
-- CONFIG
-- =============================================================================

local config = {
    icon       = "bridgeWithRiver",
    label      = "bridge walls",
    dimensions = {
        thickness    = 0.25,
        railHeight   = 0.25,
        pillarHeight = 0.75,
        railLength   = 4.0,
        pillarLength = 1.0,
        rampLength   = 2.0,
    },
}

-- =============================================================================
-- PARAMS
-- =============================================================================

local fieldDefs = {
    {key = "pillarLength", label = "pillar length", min = 0.1,  max = 10.0},
    {key = "railLength",   label = "gap length",    min = 0.5,  max = 30.0},
    {key = "pillarHeight", label = "pillar height", min = 0.05, max = 8.0},
    {key = "railHeight",   label = "rail height",   min = 0.05, max = 5.0},
    {key = "thickness",    label = "fence width",   min = 0.05, max = 10.0},
    {key = "rampLength",   label = "ramp length",   min = 0.1,  max = 20.0},
}

local function defaults()
    local out = {}
    for k, v in pairs(config.dimensions) do out[k] = v end
    local styleCfg = G.getStyleCfg()
    local cfg      = styleCfg and styleCfg.bridge
    if type(cfg) == "table" then
        for k, v in pairs(cfg) do out[k] = v end
    end
    return out
end

-- =============================================================================
-- LAYOUT
-- =============================================================================

local function layout(length, bp)
    local ramp   = bp.rampLength
    local rail   = math.max(0.1, bp.railLength)
    local pillar = math.max(0.05, bp.pillarLength)
    local rh, ph = bp.railHeight, bp.pillarHeight
    if length <= 1e-3 then return {} end
    if length < 2.0 * ramp + 0.5 * rail then
        local half = length / 2.0
        return {{0.0, half, rh, ph}, {half, length, ph, rh}}
    end
    local inner   = length - 2.0 * ramp
    local n       = math.max(1, math.floor((inner + pillar) / (rail + pillar) + 0.5))
    local scale   = inner / (n * rail + (n - 1) * pillar)
    local railLen = rail * scale
    local pillLen = pillar * scale
    local pieces  = {{0.0, ramp, rh, ph}}
    local s       = ramp
    for k = 1, n do
        local e             = (k == n) and (length - ramp) or (s + railLen)
        pieces[#pieces + 1] = {s, e, rh, rh}
        s                   = e
        if k < n then
            pieces[#pieces + 1] = {s, s + pillLen, ph, ph}
            s                   = s + pillLen
        end
    end
    pieces[#pieces + 1] = {length - ramp, length, ph, rh}
    return pieces
end

-- =============================================================================
-- FEATURE
-- =============================================================================

local feature = {
    key      = "bridge",
    icon     = config.icon,
    label    = config.label,
    fields   = fieldDefs,
    defaults = defaults,
}

feature.build = function(stations, dists, tangents, sm, np, dims)
    if np < 2 then return end
    local bp    = dims or defaults()
    local s0    = dists[1]
    local knots = W.knotsFromPieces(layout(dists[np] - s0, bp))
    W.build(stations, dists, tangents, sm, np, knots, bp.thickness)
end

G.registerFeature(feature)

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.feature  = feature
M.defaults = defaults
M.layout   = layout

return M
