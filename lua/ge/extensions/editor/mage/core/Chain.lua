-- =============================================================================
-- MaGE - MeshRoads joined end to end
-- Version: 1.0.2
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local S      = require("editor/mage/config/Settings")
local Window = require("editor/mage/core/Window")

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local tol     = S.paths.loopTol
local tagKeys = {"curb", "walk", "wall", "roll", "bottom", "ends", "profile", "priority"}

-- =============================================================================
-- MATCHING
-- =============================================================================

local function tagOf(r, features)
    local parts = {}
    for _, k in ipairs(tagKeys) do parts[#parts + 1] = tostring(r[k]) end
    for _, f in ipairs(features) do
        parts[#parts + 1] = tostring(r[f.key])
        local dims = r[f.key .. "Dims"] or {}
        for _, fd in ipairs(f.fields or {}) do parts[#parts + 1] = tostring(dims[fd.key]) end
    end
    parts[#parts + 1] = Window.encode(r.windows)
    return table.concat(parts, "|")
end

local function closed(r)
    local p = r.points
    return #p >= 3 and (p[1] - p[#p]):length() < tol
end

local function endPos(r, side)
    return (side == 0) and r.points[1] or r.points[#r.points]
end

local function cellKey(x, y)
    return math.floor(x / tol) .. "," .. math.floor(y / tol)
end

local function findLinks(list, features)
    local grid, ends = {}, {}
    for _, r in ipairs(list) do
        for side = 0, 1 do
            local p = endPos(r, side)
            local e = {r = r, side = side, p = p}
            local k = cellKey(p.x, p.y)
            grid[k] = grid[k] or {}
            table.insert(grid[k], e)
            ends[#ends + 1] = e
        end
    end
    local tags, link = {}, {}
    for _, r in ipairs(list) do
        tags[r] = tagOf(r, features)
        link[r] = {}
    end
    for _, e in ipairs(ends) do
        local near = {}
        local cx   = math.floor(e.p.x / tol)
        local cy   = math.floor(e.p.y / tol)
        for dx = -1, 1 do
            for dy = -1, 1 do
                for _, o in ipairs(grid[(cx + dx) .. "," .. (cy + dy)] or {}) do
                    if o ~= e and (o.p - e.p):length() < tol then near[#near + 1] = o end
                end
            end
        end
        if #near == 1 then
            local o    = near[1]
            local flip = (e.side == o.side)
            local ok   = o.r ~= e.r and tags[o.r] == tags[e.r] and not (flip and (e.r.windows or o.r.windows))
            if ok then link[e.r][e.side] = {r = o.r, side = o.side} end
        end
    end
    for r, l in pairs(link) do
        for side, o in pairs(l) do
            local back = link[o.r][o.side]
            if not back or back.r ~= r or back.side ~= side then l[side] = nil end
        end
    end
    return link
end

-- =============================================================================
-- JOINING
-- =============================================================================

local function walk(start, link, flip0)
    local seq, seen = {}, {}
    local r, flip   = start, flip0
    while r and not seen[r] do
        seen[r]       = true
        seq[#seq + 1] = {r = r, flip = flip}
        local o       = link[r][flip and 0 or 1]
        if not o then break end
        r, flip = o.r, (o.side == 1)
    end
    local loop = r ~= nil and r == start and #seq > 1
    return seq, loop
end

local function headOf(r, link)
    local cur, flip, seen = r, false, {}
    while not seen[cur] do
        seen[cur] = true
        local o   = link[cur][flip and 1 or 0]
        if not o then return cur, flip end
        cur, flip = o.r, (o.side == 0)
    end
    return r, false, true
end

local function pick(arr, i, n, flip)
    return arr and arr[flip and (n - i + 1) or i]
end

local function spread(cfg, lens)
    if not cfg or not cfg.floors or #lens < 2 then return cfg end
    local total = 0.0
    for _, l in ipairs(lens) do total = total + l end
    local copy, floors, extra = {}, {}, {}
    for k, v in pairs(cfg) do copy[k] = v end
    for _, fl in ipairs(cfg.floors) do
        local lead, tail = fl.lead or cfg.margin or 0.0, fl.tail or cfg.margin or 0.0
        local u0, u1     = lead, total - tail
        local w          = math.min(fl.width, u1 - u0)
        if fl.at and u1 - u0 - w > 1e-6 then
            local from = 0.0
            for k, l in ipairs(lens) do
                local a, b = from + lead, from + l - tail
                local wk   = math.max(0.0, math.min(fl.width, b - a))
                local mid  = a + wk / 2.0 + math.max(0.0, b - a - wk) * fl.at
                local c    = {}
                for key, v in pairs(fl) do c[key] = v end
                c.at = math.max(0.0, math.min(1.0, (mid - u0 - w / 2.0) / (u1 - u0 - w)))
                if k == 1 then floors[#floors + 1] = c else extra[#extra + 1] = c end
                from = from + l
            end
        else
            floors[#floors + 1] = fl
        end
    end
    for _, c in ipairs(extra) do floors[#floors + 1] = c end
    copy.floors = floors
    return copy
end

local function merge(seq, loop)
    local first = seq[1].r
    local out   = {}
    local key   = nil
    for k, v in pairs(first) do out[k] = v end
    local pts, ws, ds, ups, gates, src, joints, lens = {}, {}, {}, {}, {}, {}, {}, {}
    for m, item in ipairs(seq) do
        local r, flip = item.r, item.flip
        local n       = #r.points
        local base    = #pts
        local from    = (m == 1) and 1 or 2
        if m > 1 then
            local a, b    = pts[base], pick(r.points, 1, n, flip)
            pts[base]     = (a + b) * 0.5
            joints[base]  = true
        end
        for i = from, n do
            pts[#pts + 1] = pick(r.points, i, n, flip)
            ws[#ws + 1]   = pick(r.widths, i, n, flip)
            ds[#ds + 1]   = pick(r.depths, i, n, flip)
            ups[#ups + 1] = pick(r.ups, i, n, flip)
        end
        for _, g in ipairs(r.gates or {}) do
            local c = {}
            for k, v in pairs(g) do c[k] = v end
            if flip and c.dir then c.dir = (c.dir == "right") and "left" or "right" end
            if c.node >= 0 then
                local i = flip and (n - c.node) or (c.node + 1)
                c.node  = (i >= from) and (base + i - from) or (base - 1)
            end
            gates[#gates + 1] = c
        end
        local len = 0.0
        for i = 2, n do len = len + (r.points[i] - r.points[i - 1]):length() end
        lens[#lens + 1] = len
        src[#src + 1]   = r.id
        local pid     = tostring(r.persistentId or r.name or r.id)
        if not key or pid < key then key = pid end
    end
    if loop then
        local a, b        = pts[#pts], pts[1]
        local mid         = (a + b) * 0.5
        pts[1], pts[#pts] = mid, mid
        joints[1]         = true
    end
    out.windows = spread(first.windows, lens)
    out.points  = pts
    out.widths  = ws
    out.depths  = ds
    out.ups     = ups
    out.gates   = (#gates > 0) and gates or nil
    out.srcIds  = src
    out.joints  = joints
    out.chain   = key
    return out
end

local function join(roads, features)
    local list, rest = {}, {}
    for _, r in ipairs(roads) do
        if not r.building and #r.points >= 2 and not closed(r) then list[#list + 1] = r else rest[#rest + 1] = r end
    end
    local link = findLinks(list, features)
    local done = {}
    local out  = {}
    for _, r in ipairs(list) do
        if not done[r] then
            local head, flip = headOf(r, link)
            local seq, loop  = walk(head, link, flip)
            for _, it in ipairs(seq) do done[it.r] = true end
            if #seq == 1 then
                out[#out + 1] = r
            else
                out[#out + 1] = merge(seq, loop)
            end
        end
    end
    for _, r in ipairs(rest) do out[#out + 1] = r end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.join = join

return M
