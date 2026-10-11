-- =============================================================================
-- MaGE - MeshRoad gates
-- Version: 1.0.1
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local styles       = {"round", "quarter", "rect", "pointed"}
local defaultWidth = 10.0
local minWidth     = 1.0
local maxWidth     = 50.0
local defaultTop   = 1.0
local maxOffset    = 100.0
local minOpening   = 0.5
local matchDist    = 0.5
local arcTol       = 0.05
local arcMinSteps  = 8
local arcMaxDepth  = 6
local jambGap      = 0.002

-- =============================================================================
-- DATA
-- =============================================================================

local function isStyle(s)
    for _, k in ipairs(styles) do
        if k == s then return true end
    end
    return false
end

local function clean(g)
    if type(g) ~= "table" or not isStyle(g.style) then return nil end
    local x, y, z = tonumber(g.x), tonumber(g.y), tonumber(g.z)
    if not (x and y and z) then return nil end
    local w = tonumber(g.width) or defaultWidth
    return {
        x     = x,
        y     = y,
        z     = z,
        node  = math.floor(tonumber(g.node) or -1),
        style = g.style,
        width = math.max(minWidth, math.min(maxWidth, w)),
        dir   = (g.dir == "right") and "right" or "left",
        top   = math.max(0.0, math.min(maxOffset, tonumber(g.top) or defaultTop)),
        sill  = math.max(0.0, math.min(maxOffset, tonumber(g.sill) or 0.0)),
    }
end

local function parse(str)
    if type(str) ~= "string" or str == "" then return {} end
    local ok, data = pcall(jsonDecode, str)
    if not ok or type(data) ~= "table" then return {} end
    local out = {}
    for _, g in ipairs(data) do
        local c = clean(g)
        if c then out[#out + 1] = c end
    end
    return out
end

local function encode(list)
    if not list or #list == 0 then return "" end
    local out = {}
    for _, g in ipairs(list) do
        local r = math.floor
        out[#out + 1] = {
            x     = r(g.x * 1000 + 0.5) / 1000,
            y     = r(g.y * 1000 + 0.5) / 1000,
            z     = r(g.z * 1000 + 0.5) / 1000,
            node  = g.node,
            style = g.style,
            width = r(g.width * 1000 + 0.5) / 1000,
            dir   = (g.style == "quarter") and g.dir or nil,
            top   = (math.abs((g.top or defaultTop) - defaultTop) > 1e-6) and r(g.top * 1000 + 0.5) / 1000 or nil,
            sill  = ((g.sill or 0) > 1e-6) and r(g.sill * 1000 + 0.5) / 1000 or nil,
        }
    end
    return jsonEncode(out)
end

local function nodeOf(points, g)
    local best, bestD = nil, matchDist
    for i, p in ipairs(points) do
        local d = math.sqrt((p.x - g.x) ^ 2 + (p.y - g.y) ^ 2 + (p.z - g.z) ^ 2)
        if d < bestD then best, bestD = i, d end
    end
    if best then return best end
    if g.node and g.node >= 0 and g.node < #points then return g.node + 1 end
    return nil
end

-- =============================================================================
-- SHAPE
-- =============================================================================

local function openingZ(g, d)
    local half = g.width / 2.0
    if d < -half - 1e-9 or d > half + 1e-9 then return nil end
    local apex = g.apex
    local z
    if g.style == "rect" then
        z = apex
    elseif g.style == "round" then
        local r = half
        z       = apex - r + math.sqrt(math.max(0.0, r * r - d * d))
    elseif g.style == "pointed" then
        local R    = g.width
        local rise = R * math.sqrt(3.0) / 2.0
        local cx   = (d <= 0) and half or -half
        z          = apex - rise + math.sqrt(math.max(0.0, R * R - (d - cx) ^ 2))
    else
        local rv = math.min(g.width, apex - g.floor)
        local t  = (g.dir == "right") and ((half - d) / g.width) or ((d + half) / g.width)
        z        = apex - rv + rv * math.sqrt(math.max(0.0, 1.0 - t * t))
    end
    return z
end

-- =============================================================================
-- RESOLVE
-- =============================================================================

local function resolve(spl)
    local gates = spl and spl.gates
    if not gates or #gates == 0 or not spl.depths then return nil, spl and spl.depths end
    local pts, ds = spl.points, spl.depths
    local depths  = {}
    for i = 1, #ds do depths[i] = ds[i] end
    local out, used = {}, {}
    for _, g in ipairs(gates) do
        local i = nodeOf(pts, g)
        if i and not used[i] then
            used[i]       = true
            out[#out + 1] = {g = g, i = i}
        end
    end
    for _, r in ipairs(out) do
        local i    = r.i
        local a, b = i - 1, i + 1
        while a >= 1 and used[a] do a = a - 1 end
        while b <= #ds and used[b] do b = b + 1 end
        local wall
        if a >= 1 and b <= #ds then
            local da = (pts[i] - pts[a]):length()
            local db = (pts[b] - pts[i]):length()
            wall     = (da + db > 1e-9) and (ds[a] + (ds[b] - ds[a]) * da / (da + db)) or ds[a]
        elseif a >= 1 then
            wall = ds[a]
        elseif b <= #ds then
            wall = ds[b]
        end
        if wall and ds[i] < wall - minOpening then depths[i] = wall end
    end
    return out, depths
end

-- =============================================================================
-- APPLY
-- =============================================================================

local function lerp(a, b, t) return a + (b - a) * t end

local function along(path)
    local s = {0.0}
    for i = 2, #path do s[i] = s[i - 1] + (path[i] - path[i - 1]):length() end
    return s
end

local function sampleAt(path, w, h, tan, s, at)
    local n = #path
    if at <= 0 then return path[1], w[1], h[1], tan[1] end
    if at >= s[n] then return path[n], w[n], h[n], tan[n] end
    local k = 1
    while k < n - 1 and s[k + 1] < at do k = k + 1 end
    local span = s[k + 1] - s[k]
    local t    = (span > 1e-9) and ((at - s[k]) / span) or 0.0
    local tv   = tan[k] * (1.0 - t) + tan[k + 1] * t
    if tv:length() > 1e-9 then tv = tv:normalized() else tv = tan[k] end
    return path[k] + (path[k + 1] - path[k]) * t, lerp(w[k], w[k + 1], t), lerp(h[k], h[k + 1], t), tv
end

local function project(path, s, q)
    local best, bestS = math.huge, 0.0
    for k = 1, #path - 1 do
        local a, b   = path[k], path[k + 1]
        local ex, ey = b.x - a.x, b.y - a.y
        local l2     = ex * ex + ey * ey
        local t      = (l2 > 1e-12) and math.max(0.0, math.min(1.0, ((q.x - a.x) * ex + (q.y - a.y) * ey) / l2)) or 0.0
        local px, py = a.x + ex * t, a.y + ey * t
        local d      = (px - q.x) ^ 2 + (py - q.y) ^ 2
        if d < best then best, bestS = d, s[k] + (s[k + 1] - s[k]) * t end
    end
    return bestS
end

local function apply(resolved, spl, path, w, h, tan)
    if not resolved or #resolved == 0 or #path < 2 then return path, w, h, tan, nil end
    local s     = along(path)
    local spans = {}
    for _, r in ipairs(resolved) do
        local g    = r.g
        local c    = project(path, s, spl.points[r.i])
        local half = g.width / 2.0
        local a, b = math.max(0.0, c - half), math.min(s[#s], c + half)
        if b - a > 1e-3 then
            local p, _, hd = sampleAt(path, w, h, tan, s, c)
            local floor    = p.z - hd
            local apex     = p.z - g.top
            local lower    = (g.sill > 1e-6) and (floor + g.sill) or nil
            if apex > (lower or floor) + 1e-3 then
                spans[#spans + 1] = {g = g, c = c, a = a, b = b, apex = apex, lower = lower,
                                     view = {style = g.style, width = g.width, dir = g.dir, apex = apex, floor = lower or floor}}
            end
        end
    end
    if #spans == 0 then return path, w, h, tan, nil end
    table.sort(spans, function(x, y) return x.c < y.c end)

    local function station(at, sp, outer)
        local p, wd, hd, tv = sampleAt(path, w, h, tan, s, at)
        if not sp then return {at = at, p = p, w = wd, h = hd, t = tv} end
        local floor = p.z - hd
        local low   = sp.lower or floor
        local z     = (not outer) and openingZ(sp.view, at - sp.c) or nil
        local open  = z ~= nil and z > low + 1e-3
        local info  = {open = open, floor = hd, sill = sp.lower and (p.z - sp.lower) or nil}
        local depth = open and math.max(0.0, p.z - math.min(z, p.z)) or hd
        return {at = at, p = p, w = wd, h = depth, t = tv, info = info, sp = sp}
    end

    local marks = {}
    local function add(at, sp, outer) marks[#marks + 1] = {at = at, sp = sp, outer = outer} end
    local function inside(at)
        for _, sp in ipairs(spans) do
            if at > sp.a - 1e-6 and at < sp.b + 1e-6 then return true end
        end
        return false
    end
    for i = 1, #path do
        if not inside(s[i]) then add(s[i], nil, false) end
    end
    for _, sp in ipairs(spans) do
        add(sp.a, sp, true)
        add(math.min(sp.a + jambGap, sp.b), sp, false)
        if sp.g.style ~= "rect" then
            local function zAt(at) return openingZ(sp.view, at - sp.c) or sp.view.floor end
            local function refine(a, b, depth)
                local m = (a + b) / 2.0
                if depth < arcMaxDepth and math.abs(zAt(m) - (zAt(a) + zAt(b)) / 2.0) > arcTol then
                    refine(a, m, depth + 1)
                    add(m, sp, false)
                    refine(m, b, depth + 1)
                end
            end
            local a0, b0 = sp.a + jambGap, sp.b - jambGap
            local ms     = {a0}
            for k = 1, arcMinSteps - 1 do ms[#ms + 1] = a0 + (b0 - a0) * k / arcMinSteps end
            if sp.c > a0 and sp.c < b0 then ms[#ms + 1] = sp.c end
            ms[#ms + 1] = b0
            table.sort(ms)
            for k = 2, #ms - 1 do add(ms[k], sp, false) end
            for k = 1, #ms - 1 do refine(ms[k], ms[k + 1], 0) end
        end
        add(math.max(sp.b - jambGap, sp.a), sp, false)
        add(sp.b, sp, true)
    end
    for _, m in ipairs(marks) do m.q = math.floor(m.at * 1e9 + 0.5) end
    table.sort(marks, function(x, y)
        if x.q ~= y.q then return x.q < y.q end
        return (x.sp and 1 or 0) < (y.sp and 1 or 0)
    end)

    local rows, last = {}, -math.huge
    for idx, m in ipairs(marks) do
        if m.at - last > 1e-6 or idx == 1 then
            rows[#rows + 1] = station(m.at, m.sp, m.outer)
            last            = m.at
        end
    end

    local out = {}
    for k, r in ipairs(rows) do
        local prev = out[#out]
        if prev and prev.sp and r.sp == prev.sp and prev.info.open ~= r.info.open and r.at - prev.at > 4 * jambGap then
            local lo, hi = prev.at, r.at
            for _ = 1, 30 do
                local mid = (lo + hi) / 2.0
                if station(mid, r.sp, false).info.open == prev.info.open then lo = mid else hi = mid end
            end
            out[#out + 1] = station(lo, r.sp, false)
            out[#out + 1] = station(hi, r.sp, false)
        end
        out[#out + 1] = r
    end

    local np, nw, nh, nt, info = {}, {}, {}, {}, {}
    for k, r in ipairs(out) do
        np[k], nw[k], nh[k], nt[k], info[k] = r.p, r.w, r.h, r.t, r.info or false
    end
    return np, nw, nh, nt, info
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.styles       = styles
M.defaultWidth = defaultWidth
M.minWidth     = minWidth
M.maxWidth     = maxWidth
M.defaultTop   = defaultTop
M.maxOffset    = maxOffset
M.parse        = parse
M.encode       = encode
M.nodeOf       = nodeOf
M.openingZ     = openingZ
M.resolve      = resolve
M.apply        = apply
M.along        = along
M.sampleAt     = sampleAt

return M
