-- =============================================================================
-- MaGE - battlements
-- Version: 1.0.1
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local G = require("editor/mage/core/Geometry")
local W = require("editor/mage/modules/EdgeWall")

-- =============================================================================
-- CONFIG
-- =============================================================================

local config = {
    icon       = "account_balance",
    label      = "battlements",
    dimensions = {
        merlonLength = 2.0,
        gapLength    = 1.0,
        height       = 2.0,
        width        = 0.0,
    },
}

-- =============================================================================
-- PARAMS
-- =============================================================================

local fieldDefs = {
    {key = "merlonLength", label = "merlon length",                      min = 0.2,   max = 20.0},
    {key = "gapLength",    label = "gap length",                         min = 0.1,   max = 20.0},
    {key = "height",       label = "merlon height",                      min = 0.1,   max = 10.0},
    {key = "width",        label = "width change (+ wider, - narrower)", min = -20.0, max = 20.0},
}

local function defaults()
    local out = {}
    for k, v in pairs(config.dimensions) do out[k] = v end
    return out
end

-- =============================================================================
-- LAYOUT
-- =============================================================================

local function layout(length, dims)
    dims       = dims or config.dimensions
    local m, g = dims.merlonLength, dims.gapLength
    if length <= m then return {{0.0, length}} end
    local n     = math.max(1, math.floor((length + g) / (m + g) + 0.5))
    local scale = length / (n * m + (n - 1) * g)
    local out   = {}
    local s     = 0.0
    for i = 1, n do
        out[#out + 1] = {s, s + m * scale}
        s             = s + (m + g) * scale
    end
    out[#out][2] = length
    return out
end

-- =============================================================================
-- FEATURE
-- =============================================================================

local feature = {
    key      = "battlement",
    icon     = config.icon,
    label    = config.label,
    fields   = fieldDefs,
    defaults = defaults,
}

feature.build = function(stations, dists, tangents, sm, np, dims)
    if np < 2 then return end
    dims         = dims or defaults()
    local s0     = dists[1]
    local blocks = {}
    for _, b in ipairs(layout(dists[np] - s0, dims)) do blocks[#blocks + 1] = {s0 + b[1], s0 + b[2]} end
    W.buildBlocks(stations, dists, tangents, sm, np, blocks, dims.height, dims.width)
end

G.registerFeature(feature)

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.feature  = feature
M.defaults = defaults
M.layout   = layout

return M
