-- =============================================================================
-- MaGE - battlements
-- Version: 1.0.2
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
        ends         = 0,
        shift        = 0.0,
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
    {key = "ends",         label = "at the ends",                        min = 0,     max = 1,
     choices = {{0, "a merlon", "mage.ends_merlon"}, {1, "a gap", "mage.ends_gap"}}},
    {key = "shift",        label = "move the pattern along the wall",    min = -50.0, max = 50.0},
}

local function defaults()
    local out = {}
    for k, v in pairs(config.dimensions) do out[k] = v end
    return out
end

-- =============================================================================
-- LAYOUT
-- =============================================================================

local function shifted(length, m, g, shift)
    local period = m + g
    local s      = shift % period - period
    local out    = {}
    while s < length do
        local a, b = math.max(0.0, s), math.min(length, s + m)
        if b - a > 1e-6 then out[#out + 1] = {a, b} end
        s = s + period
    end
    return out
end

local function gapEnds(length, m, g)
    local n     = math.max(1, math.floor((length - g) / (m + g) + 0.5))
    local scale = length / (n * m + (n + 1) * g)
    local out   = {}
    for i = 0, n - 1 do
        local a       = (g + i * (m + g)) * scale
        out[#out + 1] = {a, a + m * scale}
    end
    return out
end

local function layout(length, dims)
    dims       = dims or config.dimensions
    local m, g = dims.merlonLength, dims.gapLength
    local sh   = dims.shift or 0.0
    if math.abs(sh) > 1e-6 then return shifted(length, m, g, sh) end
    if (dims.ends or 0) >= 0.5 and length > m + 2.0 * g then return gapEnds(length, m, g) end
    if length <= m then return {{0.0, length}} end
    local n     = math.max(1, math.floor((length + g) / (m + g) + 0.5))
    local scale = length / (n * m + (n - 1) * g)
    local out   = {}
    local s     = 0.0
    for _ = 1, n do
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
