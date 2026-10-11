-- =============================================================================
-- MaGE - geometry builder
-- Version: 1.0.0
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local S         = require("editor/mage/config/Settings")
local smoothing = S.smoothing
local cr        = S.cr
local roundEnd  = S.roundEnd
local paths     = S.paths
local decal     = S.decal
local meshRoad  = S.meshRoad

local C           = require("editor/mage/core/Common")
local Gate        = require("editor/mage/core/Gate")
local Window      = require("editor/mage/core/Window")
local Modules     = require("editor/mage/core/Modules")
local clamp       = C.clamp
local levelDir    = C.levelDir
local md5Prefix32 = C.md5Prefix32
local readJson    = C.readJson
local v3          = C.v3

-- =============================================================================
-- STATE
-- =============================================================================

local styleFile = C.styleFile

local mrState = {turnScale = 1.0, up = nil, curbMat = nil, wallStyle = nil,
                 curbBand0 = false, note = nil, orient = false}

local mr       = {}
local features = {}

local stylePath = ""
local styleCfg  = nil
local styleErr  = nil

local curbKey, walkKey = nil, nil

-- =============================================================================
-- STYLES
-- =============================================================================


local function loadStyles()
    styleCfg, styleErr = nil, nil
    local dir          = levelDir()
    if not dir then styleErr = "no level loaded" return end
    stylePath  = C.stylePathIn(dir)
    local data = readJson(stylePath)
    if not data then
        styleErr = "no styles config in this level"
        return
    end
    if data.version ~= 1 then styleErr = "styles config version must be 1" return end
    styleCfg = data

end

local function orderedStyleNames(axis)
    local styles = styleCfg and styleCfg[axis] and styleCfg[axis].styles
    if type(styles) ~= "table" then return {} end
    local out = {}
    for nm in pairs(styles) do out[#out + 1] = nm end
    table.sort(out)
    return out
end

local function weightedPick(axis, weights, names, key)
    local total = 0
    for _, nm in ipairs(names) do total = total + (weights[nm] or 0) end
    if total <= 0 then return names[1] end
    local seed = (styleCfg and styleCfg.seed) or 20260812
    local raw  = tostring(seed) .. "|" .. axis .. "|" .. tostring(key)
    local r    = md5Prefix32(raw) % total
    for _, nm in ipairs(names) do
        r = r - (weights[nm] or 0)
        if r < 0 then return nm end
    end
    return names[#names]
end

local function resolveStyle(road)
    local key        = road.persistentId or road.name or tostring(road.id)
    local curb, walk = road.curb, road.walk

    if not curb then
        local names, weights = {}, {}
        for _, nm in ipairs(orderedStyleNames("curb")) do
            local st = styleCfg.curb.styles[nm]
            if type(st) == "table" and st.sequence == nil then
                names[#names + 1] = nm
                weights[nm] = st.weight or 0
            end
        end
        if #names > 0 then curb = weightedPick("curb", weights, names, key) end
    end

    if not walk then

        local names, weights = {}, {}
        for _, nm in ipairs(orderedStyleNames("walk")) do
            local st = styleCfg.walk.styles[nm]
            if type(st) == "table" and st.material then
                names[#names + 1] = nm
                weights[nm] = st.weight or 0
            end
        end
        if #names > 0 then walk = weightedPick("walk", weights, names, key) end
    end

    return curb, walk
end

local function curbMaterialName()
    if mrState.curbMat then return mrState.curbMat end
    return styleCfg and styleCfg.curb and styleCfg.curb.material or nil
end

function mr.rawStyle(key)
    if type(key) == "string" and key:sub(1, 1) == "@" then
        return {material = key:sub(2), scale = S.buildingArchitect.tile}
    end
    return nil
end

function mr.wallMaterialFor(key)
    local raw = mr.rawStyle(key)
    if raw then return raw.material end
    local styles = styleCfg and styleCfg.wall and styleCfg.wall.styles
    local st     = styles and key and styles[key]
    if type(st) == "table" and st.material then return st.material end
    return nil
end

function mr.meshroadCurbMaterial(road)
    local tagged = mr.wallMaterialFor(road and road.wall)
    if tagged then return tagged end
    local curb = styleCfg and styleCfg.curb
    return (curb and (curb.meshroadMaterial or curb.material)) or nil
end

local function heaviestStyle(axis)
    local styles = styleCfg and styleCfg[axis] and styleCfg[axis].styles
    if type(styles) ~= "table" then return nil end
    local best, bestW = nil, -1
    for k, st in pairs(styles) do
        if type(st) == "table" and st.sequence == nil then
            local w = st.weight or 0
            if w > bestW or (w == bestW and best and k < best) then
                best, bestW = k, w
            end
        end
    end
    return best
end

function mr.walkStyle()
    local raw = mr.rawStyle(walkKey)
    if raw then return raw end
    local styles = styleCfg and styleCfg.walk and styleCfg.walk.styles
    local st     = styles and walkKey and styles[walkKey]
    if type(st) == "table" and st.material then return st end
    local fb   = heaviestStyle("walk")
    local fbSt = fb and styles and styles[fb]
    if type(fbSt) == "table" and fbSt.material then return fbSt end
    return nil
end

local function walkMaterialName()
    local st = mr.walkStyle()
    return st and st.material or nil
end

local function matScale(name)
    local def = styleCfg and styleCfg.defaultScale or 2.5
    local m   = name and styleCfg and styleCfg.materials and styleCfg.materials[name]
    local sc  = type(m) == "table" and m.scale or nil
    if type(sc) == "table" then
        return sc[1] or def, sc[2] or sc[1] or def
    elseif type(sc) == "number" then
        return sc, sc
    end
    return def, def
end

function mr.styleScale(st, matName)
    local sc = type(st) == "table" and st.scale or nil
    if type(sc) == "table" and sc[1] then
        return sc[1], sc[2] or sc[1]
    elseif type(sc) == "number" then
        return sc, sc
    end
    return matScale(matName)
end

function mr.walkScale()
    return mr.styleScale(mr.walkStyle(), walkMaterialName())
end

function mr.curbScale()
    if mrState.curbMat then
        return mr.styleScale(mrState.wallStyle, mrState.curbMat)
    end
    local styles = styleCfg and styleCfg.curb and styleCfg.curb.styles
    local st     = styles and curbKey and styles[curbKey]
    return mr.styleScale(st, curbMaterialName())
end

local function curbBottomUV(uvx, sVal)
    local su, sv = mr.curbScale()
    return uvx / su + 0.5, sVal / sv + 0.5
end

local function curbAtlas()
    local name = curbMaterialName()
    local m    = name and styleCfg and styleCfg.materials and styleCfg.materials[name]
    local key  = type(m) == "table" and m.atlas or nil
    if not key then return nil end
    local reg = styleCfg.atlases
    if type(reg) == "table" and type(reg[key]) == "table" then return reg[key] end
    return S.defaultAtlas
end

local function curbBand()
    if mrState.curbBand0 then return 0 end
    local styles = styleCfg and styleCfg.curb and styleCfg.curb.styles
    local st     = styles and curbKey and styles[curbKey]
    if type(st) == "table" and type(st.band) == "number" then return st.band end
    local fb   = heaviestStyle("curb")
    local fbSt = fb and styles and styles[fb]
    if type(fbSt) == "table" and type(fbSt.band) == "number" then return fbSt.band end
    return 0
end

local function rowSpan(rows, k)
    return rows[1] + clamp(k, 0.0, 1.0) * (rows[2] - rows[1])
end

local function curbBandV(atlas, row)
    local band = curbBand() % atlas.bands
    local v    = (band * atlas.bandPx + row) / (atlas.bands * atlas.bandPx)
    if atlas.originTop ~= false then return 1.0 - v end
    return v
end

local function curbU(s)
    local atlas  = curbAtlas()
    local su, sv = mr.curbScale()
    if not atlas then return s / su + 0.5 end
    local sc = atlas.uScale or sv
    return s / sc + 0.5
end

local function curbTopV(w)
    local atlas = curbAtlas()
    if not atlas then
        local _, sv = mr.curbScale()
        return (w - S.curbStrip) / sv + 0.5
    end
    local k = (S.curbStrip > 1e-9) and (w / S.curbStrip) or 0.0
    if atlas.paintOn == "top" then
        return curbBandV(atlas, rowSpan(atlas.paintRows, k))
    end
    return curbBandV(atlas, rowSpan(atlas.plainSlice or atlas.plainRows, k))
end

local function curbFaceV(depth)
    local atlas = curbAtlas()
    if not atlas then
        local _, sv = mr.curbScale()
        return depth / sv + 0.5
    end
    local k = (S.height > 1e-9) and (depth / S.height) or 0.0
    if atlas.paintOn == "top" then
        return curbBandV(atlas, rowSpan(atlas.plainRows, k))
    end
    return curbBandV(atlas, rowSpan({atlas.paintRows[1], atlas.plainRows[2]}, k))
end

local function walkUV(localX, s)
    local su, sv = mr.walkScale()
    return localX / su + 0.5, s / sv + 0.5
end

-- =============================================================================
-- SMOOTHING
-- =============================================================================

local function crKnots(p0, p1, p2, p3)
    if cr.alpha <= 0.0 then return nil end
    local lens  = {(p1 - p0):length(), (p2 - p1):length(), (p3 - p2):length()}
    local ref   = math.max(lens[1], lens[2], lens[3])
    local floor = cr.minSpan
    if ref > 0.0 then floor = math.max(cr.minSpan, ref * cr.dupFrac) end
    local t = {0.0}
    for i = 1, 3 do
        local L = lens[i]
        if L <= cr.dupEps then L = floor end
        t[#t + 1] = t[#t] + L ^ cr.alpha
    end
    return t
end

local function crPoint(p0, p1, p2, p3, t, kn)
    if not kn then
        local t2 = t * t
        local t3 = t2 * t
        return (p1 * 2.0
                + (p2 - p0) * t
                + (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * t2
                + (p1 * 3.0 - p0 - p2 * 3.0 + p3) * t3) * 0.5
    end
    local k0, k1, k2, k3 = kn[1], kn[2], kn[3], kn[4]
    local u              = k1 + (k2 - k1) * t

    local function lerp(a, b, ta, tb)
        if tb - ta < 1e-12 then return b end
        local f = (u - ta) / (tb - ta)
        return a * (1.0 - f) + b * f
    end

    local a1 = lerp(p0, p1, k0, k1)
    local a2 = lerp(p1, p2, k1, k2)
    local a3 = lerp(p2, p3, k2, k3)
    local b1 = lerp(a1, a2, k0, k2)
    local b2 = lerp(a2, a3, k1, k3)
    return lerp(b1, b2, k1, k2)
end

local function segmentTValues(p0, p1, p2, p3, spacing, kn, maxTurnDeg)
    local limit  = maxTurnDeg or smoothing.maxTurnDeg
    local segLen = (p2 - p1):length()
    if limit >= 180.0 then
        local steps = math.max(1, math.floor(segLen / spacing + 0.5))
        local ts    = {}
        for s = 1, steps do ts[s] = s / steps end
        return ts
    end

    local dense = math.max(16, math.min(256, math.floor(segLen / 0.05)))
    local pts   = {}
    for i = 0, dense do
        pts[i + 1] = crPoint(p0, p1, p2, p3, i / dense, kn)
    end

    local ts, accD, accA, prevDir = {}, 0.0, 0.0, nil
    for i = 1, dense do
        local d   = pts[i + 1] - pts[i]
        local dl  = d:length()
        accD      = accD + dl
        local cur = (dl > 1e-9) and (d / dl) or nil
        if prevDir and cur then
            accA = accA + math.deg(math.acos(clamp(prevDir:dot(cur), -1.0, 1.0)))
        end
        if cur then prevDir = cur end
        if i == dense or accD >= spacing or accA >= limit * mrState.turnScale then
            ts[#ts + 1] = i / dense
            accD, accA = 0.0, 0.0
        end
    end
    return ts
end

local function smoothPath(points, spacing)
    local n = #points
    if n < 3 or spacing <= 0 then
        local out = {}
        for i = 1, n do out[i] = v3(points[i]) end
        return out
    end

    local padded = {points[1] * 2.0 - points[2]}
    for i = 1, n do padded[#padded + 1] = points[i] end
    padded[#padded + 1] = points[n] * 2.0 - points[n - 1]

    local result = {v3(points[1])}
    for i = 2, #padded - 2 do
        local p0, p1, p2, p3 = padded[i - 1], padded[i], padded[i + 1], padded[i + 2]
        if (p2 - p1):length() >= 1e-6 then
            local kn = crKnots(p0, p1, p2, p3)
            for _, t in ipairs(segmentTValues(p0, p1, p2, p3, spacing, kn)) do
                result[#result + 1] = crPoint(p0, p1, p2, p3, t, kn)
            end
        end
    end
    return result
end

local function resampleSectionTangents(points, sec, spacing)
    if not sec or #sec ~= #points or #points < 3 or spacing <= 0 then return nil end
    local n      = #points
    local padded = {points[1] * 2.0 - points[2]}
    for i = 1, n do padded[#padded + 1] = points[i] end
    padded[#padded + 1] = points[n] * 2.0 - points[n - 1]

    local out = {sec[1]}
    for i = 2, #padded - 2 do
        local p0, p1, p2, p3 = padded[i - 1], padded[i], padded[i + 1], padded[i + 2]
        if (p2 - p1):length() >= 1e-6 then
            local ta, tb = sec[i - 1], sec[i]
            local kn     = crKnots(p0, p1, p2, p3)
            for _, t in ipairs(segmentTValues(p0, p1, p2, p3, spacing, kn)) do
                if not ta or not tb then
                    out[#out + 1] = (t > 0.999) and tb or false
                else
                    local v = ta * (1.0 - t) + tb * t
                    out[#out + 1] = (v:length() > 1e-9) and v:normalized() or tb
                end
            end
        end
    end
    return out
end

mr.depthRingKeys = {}

function mr.ringKey(v)
    return string.format("%.4f,%.4f,%.4f", v.x, v.y, v.z)
end

function mr.pchipSlope(h0, h1, d0, d1, d2)
    if h0 <= 1e-9 or h1 <= 1e-9 then return 0.0 end
    local s0, s1 = (d1 - d0) / h0, (d2 - d1) / h1
    if s0 * s1 <= 0.0 then return 0.0 end
    local w0, w1 = 2.0 * h1 + h0, h1 + 2.0 * h0
    return (w0 + w1) / (w0 / s0 + w1 / s1)
end

function mr.depthHermite(d1, d2, m1, m2, span, f)
    local f2 = f * f
    local f3 = f2 * f
    return (2.0 * f3 - 3.0 * f2 + 1.0) * d1 + (f3 - 2.0 * f2 + f) * span * m1
              + (3.0 * f2 - 2.0 * f3) * d2 + (f3 - f2) * span * m2
end

local function smoothPathWithWidths(points, widths, spacing, depths, maxTurnDeg, depthStep)
    local n = #points
    if n < 3 or spacing <= 0 then
        local op, ow, od = {}, {}, (depths and {} or nil)
        for i = 1, n do
            op[i] = v3(points[i]); ow[i] = widths[i]
            if od then od[i] = depths[i] end
        end
        return op, ow, od
    end

    local pp = {points[1] * 2.0 - points[2]}
    local pw = {widths[1]}
    local pd = depths and {depths[1]} or nil
    for i = 1, n do
        pp[#pp + 1] = points[i]
        pw[#pw + 1] = widths[i]
        if pd then pd[#pd + 1] = depths[i] end
    end
    pp[#pp + 1] = points[n] * 2.0 - points[n - 1]
    pw[#pw + 1] = widths[n]
    if pd then pd[#pd + 1] = depths[n] end

    local rp, rw = {v3(points[1])}, {widths[1]}
    local rd     = depths and {depths[1]} or nil
    for i = 2, #pp - 2 do
        local p0, p1, p2, p3 = pp[i - 1], pp[i], pp[i + 1], pp[i + 2]
        local w0, w1, w2, w3 = pw[i - 1], pw[i], pw[i + 1], pw[i + 2]
        if (p2 - p1):length() >= 1e-6 then
            local kn   = crKnots(p0, p1, p2, p3)
            local ts   = segmentTValues(p0, p1, p2, p3, spacing, kn, maxTurnDeg)
            local segP = {}
            if rd then
                local d0, d1, d2, d3 = pd[i - 1], pd[i], pd[i + 1], pd[i + 2]
                local h1             = (p2 - p1):length()
                local m1             = mr.pchipSlope((p1 - p0):length(), h1, d0, d1, d2)
                local m2             = mr.pchipSlope(h1, (p3 - p2):length(), d1, d2, d3)
                local function segDepths(tl)
                    local ps, acc, run, prev = {}, {}, 0.0, p1
                    for k, t in ipairs(tl) do
                        ps[k]  = crPoint(p0, p1, p2, p3, t, kn)
                        run    = run + (ps[k] - prev):length()
                        acc[k] = run
                        prev   = ps[k]
                    end
                    local dv = {}
                    for k, t in ipairs(tl) do
                        dv[k] = mr.depthHermite(d1, d2, m1, m2, run, (run > 1e-12) and (acc[k] / run) or t)
                    end
                    return ps, dv
                end
                local segD
                segP, segD = segDepths(ts)
                if depthStep and math.abs(d2 - d1) > depthStep then
                    local baseT = {}
                    for _, t in ipairs(ts) do baseT[t] = true end
                    for _ = 1, 10 do
                        local grown, tPrev, vPrev = {}, 0.0, d1
                        for k, t in ipairs(ts) do
                            if math.abs(segD[k] - vPrev) > depthStep and t - tPrev > 1e-4 then
                                grown[#grown + 1] = (tPrev + t) * 0.5
                            end
                            grown[#grown + 1] = t
                            tPrev, vPrev = t, segD[k]
                        end
                        if #grown == #ts then break end
                        ts         = grown
                        segP, segD = segDepths(ts)
                    end
                    for k, t in ipairs(ts) do
                        if not baseT[t] then mr.depthRingKeys[mr.ringKey(segP[k])] = true end
                    end
                end
                for k = 1, #segD do rd[#rd + 1] = segD[k] end
            else
                for k, t in ipairs(ts) do segP[k] = crPoint(p0, p1, p2, p3, t, kn) end
            end
            for k, t in ipairs(ts) do
                rp[#rp + 1] = segP[k]
                rw[#rw + 1] = crPoint(w0, w1, w2, w3, t, kn)
            end
        end
    end
    return rp, rw, rd
end

-- =============================================================================
-- TANGENTS
-- =============================================================================

local function terrainZ(x, y, fallback)
    local ok, h = pcall(core_terrain.getTerrainHeight, vec3(x, y, 0))
    if ok and type(h) == "number" then return h end
    return fallback or 0.0
end

function mr.computeTangents(points)
    local n   = #points
    local out = {}
    for i = 1, n do
        local a, b
        if i > 1 then
            local d = points[i] - points[i - 1]
            d       = vec3(d.x, d.y, 0)
            if d:length() > 1e-9 then a = d:normalized() end
        end
        if i < n then
            local d = points[i + 1] - points[i]
            d       = vec3(d.x, d.y, 0)
            if d:length() > 1e-9 then b = d:normalized() end
        end
        local d
        if a and b then
            d = a + b
            if d:length() < 1e-9 then d = b end
        else
            d = a or b
        end
        if not d or d:length() < 1e-9 then d = vec3(1, 0, 0) end
        out[i] = d:normalized()
    end
    return out
end

function mr.cumulativeDistances(points)
    local out = {0.0}
    for i = 2, #points do
        out[i] = out[i - 1] + (points[i] - points[i - 1]):length()
    end
    return out
end

function mr.interpDepthRingTangents(points, tangents)
    if next(mr.depthRingKeys) == nil or #points ~= #tangents then return tangents end
    local n          = #points
    local added, any = {}, false
    for i = 1, n do
        added[i] = mr.depthRingKeys[mr.ringKey(points[i])] == true
        any      = any or added[i]
    end
    if not any then return tangents end
    local dists = mr.cumulativeDistances(points)
    local out   = {}
    for i = 1, n do out[i] = tangents[i] end
    for i = 1, n do
        if added[i] then
            local a, b = i - 1, i + 1
            while a >= 1 and added[a] do a = a - 1 end
            while b <= n and added[b] do b = b + 1 end
            if a >= 1 and b <= n then
                local span = dists[b] - dists[a]
                local f    = (span > 1e-12) and ((dists[i] - dists[a]) / span) or 0.0
                local t    = tangents[a] * (1.0 - f) + tangents[b] * f
                if t:length() > 1e-9 then out[i] = t:normalized() end
            end
        end
    end
    return out
end

function mr.tangents3d(points, closed)
    local out = {}
    for i = 1, #points do out[i] = mr.tangent3d(points, i, closed) end
    return mr.interpDepthRingTangents(points, out)
end

function mr.tangent3d(points, i, closed)
    local n = #points
    if n < 2 then return vec3(1, 0, 0) end
    local d
    if closed then
        d = points[(i % n) + 1] - points[((i - 2) % n) + 1]
    elseif i == 1 then d = points[2] - points[1]
    elseif i == n then d = points[n] - points[n - 1]
    else d = points[i + 1] - points[i - 1] end
    if d:length() > 1e-9 then return d:normalized() end
    return vec3(1, 0, 0)
end

function mr.upAt(ups, dists, s)
    if not ups or #ups == 0 then return vec3(0, 0, 1) end
    if #ups == 1 or not dists or #dists == 0 then return ups[1] end
    if s <= dists[1] then return ups[1] end
    local lim = math.min(#dists, #ups)
    for i = 2, lim do
        if s <= dists[i] then
            local span = dists[i] - dists[i - 1]
            local f    = (span <= 1e-9) and 0.0 or ((s - dists[i - 1]) / span)
            local v    = ups[i - 1] * (1.0 - f) + ups[i] * f
            if v:length() > 1e-6 then return v:normalized() end
            return ups[i]
        end
    end
    return ups[lim]
end

-- =============================================================================
-- CORNERS
-- =============================================================================

function mr.xyRadius(a, b, c)
    local ar      = math.abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2.0
    local A, B, C = (b - a):length(), (c - b):length(), (c - a):length()
    if ar < 1e-12 or A < 1e-9 or B < 1e-9 then return math.huge end
    return A * B * C / (4.0 * ar)
end

function mr.dedupe(points, widths, depths)
    local op = {points[1]}
    local ow = {widths[1]}
    local od = depths and {depths[1]} or nil
    for i = 2, #points do
        if (points[i] - op[#op]):length() > 1e-6 then
            op[#op + 1] = points[i]
            ow[#ow + 1] = widths[i]
            if od then od[#od + 1] = depths[i] end
        end
    end
    return op, ow, od
end

function mr.densify(points, widths, depths, spacing, maxTurnDeg)
    local dn, dw = smoothPathWithWidths(points, widths, spacing, depths, maxTurnDeg)
    dn, dw       = mr.dedupe(dn, dw, nil)
    return dn, dw
end

function mr.dupSharp(points, widths, depths, sharp)
    local cp, cw, cd = {}, {}, (depths and {} or nil)
    local n          = #points
    for i = 1, n do
        local reps = (i > 1 and i < n and sharp[i]) and 2 or 1
        for _ = 1, reps do
            cp[#cp + 1] = points[i]
            cw[#cw + 1] = widths[i]
            if cd then cd[#cd + 1] = depths[i] end
        end
    end
    return cp, cw, cd
end

function mr.minRadiusRatio(points, widths)
    local worst, at = math.huge, nil
    for i = 2, #points - 1 do
        local hw = ((widths and widths[i]) or 0.0) / 2.0
        if hw > 1e-6 then
            local r = mr.xyRadius(points[i - 1], points[i], points[i + 1]) / hw
            if r < worst then worst, at = r, points[i] end
        end
    end
    return worst, at
end

function mr.sweptRatio(points, widths, depths, spacing, maxTurnDeg)
    if #points < 3 then return math.huge, nil end
    local dense, dwid = smoothPathWithWidths(points, widths, spacing, depths, maxTurnDeg)
    return mr.minRadiusRatio(dense, dwid)
end

function mr.relaxTightCorners(points, widths, margin, maxIter)
    local n = #points
    if n < 3 or not widths or #widths == 0 then return points, 0.0, 0 end
    margin          = margin or meshRoad.minRadiusMargin
    maxIter         = maxIter or meshRoad.relaxIters
    local pts, orig = {}, {}
    for i = 1, n do
        pts[i]  = vec3(points[i].x, points[i].y, points[i].z)
        orig[i] = vec3(points[i].x, points[i].y, points[i].z)
    end

    local used = 0
    for _ = 1, maxIter do
        local bad, nbad = {}, 0
        for i = 2, n - 1 do
            local hw = ((i <= #widths) and widths[i] or widths[#widths]) / 2.0
            if hw > 1e-6 and mr.xyRadius(pts[i - 1], pts[i], pts[i + 1]) < hw * margin then
                nbad      = nbad + 1
                bad[nbad] = i
            end
        end
        if nbad == 0 then break end
        local mark = {}
        for _, i in ipairs(bad) do
            for _, j in ipairs({i - 1, i, i + 1}) do
                if j > 1 and j < n then mark[j] = true end
            end
        end
        local upd = {}
        for j in pairs(mark) do
            local mid = (pts[j - 1] + pts[j + 1]) * 0.5
            upd[j]    = vec3(pts[j].x + (mid.x - pts[j].x) * 0.25,
                          pts[j].y + (mid.y - pts[j].y) * 0.25,
                          pts[j].z)
        end
        for j, v in pairs(upd) do pts[j] = v end
        used = used + 1
    end
    local disp = 0.0
    for i = 1, n do
        local d = (pts[i] - orig[i]):length()
        if d > disp then disp = d end
    end
    return pts, disp, used
end

function mr.reparamVertical(orig, moved, widths, depths)
    local function cum(p)
        local s = {0.0}
        for i = 2, #p do
            local dx, dy = p[i].x - p[i - 1].x, p[i].y - p[i - 1].y
            s[i]         = s[i - 1] + math.sqrt(dx * dx + dy * dy)
        end
        return s
    end
    local n = #orig
    if n ~= #moved or n < 2 then return moved, widths, depths end
    local so, sn = cum(orig), cum(moved)
    if so[n] < 1e-9 or sn[n] < 1e-9 then return moved, widths, depths end
    local hasW                = widths ~= nil and #widths == n
    local hasD                = depths ~= nil and #depths == n
    local outP, outW, outD, j = {}, {}, {}, 2
    for i = 1, n do
        local t = sn[i] / sn[n] * so[n]
        while j < n and so[j] < t do j = j + 1 end
        local a, b = j - 1, j
        local span = so[b] - so[a]
        local f    = (span < 1e-12) and 0.0 or ((t - so[a]) / span)
        outP[i]    = vec3(moved[i].x, moved[i].y, orig[a].z + (orig[b].z - orig[a].z) * f)
        if hasW then outW[i] = widths[a] + (widths[b] - widths[a]) * f end
        if hasD then outD[i] = depths[a] + (depths[b] - depths[a]) * f end
    end
    return outP, (hasW and outW or widths), (hasD and outD or depths)
end

function mr.relaxForSweptPath(points, widths, depths, spacing, maxTurnDeg)
    if #points < 3 or not widths or #widths == 0 then
        return points, widths, depths, 0.0, 0, math.huge, nil
    end
    local ratio, at                 = mr.sweptRatio(points, widths, depths, spacing, maxTurnDeg)
    local bP, bW, bD, bDisp, bIters = points, widths, depths, 0.0, 0
    if ratio >= meshRoad.sweptMinRatio then
        return bP, bW, bD, bDisp, bIters, ratio, at
    end
    local wmax = widths[1]
    for _, w in ipairs(widths) do if w > wmax then wmax = w end end
    local dispCap = meshRoad.maxRelaxDisp * (wmax / 2.0)
    local margin  = meshRoad.minRadiusMargin
    for _ = 1, math.max(1, meshRoad.relaxRounds) do
        local relaxed, disp, iters = mr.relaxTightCorners(points, widths, margin)
        if disp > dispCap then break end
        local moved, w, d = mr.reparamVertical(points, relaxed, widths, depths)
        local r, a        = mr.sweptRatio(moved, w, d, spacing, maxTurnDeg)
        if r > ratio then
            bP, bW, bD, bDisp, bIters = moved, w, d, disp, iters
            ratio, at                 = r, a
        end
        if r >= meshRoad.sweptMinRatio then break end
        margin = margin * meshRoad.marginGrowth
    end
    return bP, bW, bD, bDisp, bIters, ratio, at
end

function mr.mitreRun(points, widths, i)
    local n = #points
    if i <= 1 or i >= n then return 0.0 end
    local a      = points[i] - points[i - 1]
    local b      = points[i + 1] - points[i]
    local la, lb = a:length(), b:length()
    if la < 1e-9 or lb < 1e-9 then return 0.0 end
    local cosT = clamp((a.x * b.x + a.y * b.y) / (la * lb), -1.0, 1.0)
    local half = math.min(math.acos(cosT) / 2.0, math.rad(meshRoad.sharpMaxHalfDeg))
    local hw   = ((widths and widths[i]) or 0.0) / 2.0
    return hw * math.tan(half)
end

function mr.mitreFits(points, widths, i)
    local n = #points
    if i <= 1 or i >= n then return false end
    local need = mr.mitreRun(points, widths, i)
    if need <= 0.0 then return true end
    local legs = {{i - 1, (points[i] - points[i - 1]):length()},
                  {i + 1, (points[i + 1] - points[i]):length()}}
    for k = 1, 2 do
        local j, leg = legs[k][1], legs[k][2]
        local other  = 0.0
        if j > 1 and j < n then other = mr.mitreRun(points, widths, j) end
        if need + other > leg * meshRoad.sharpFitHeadroom then return false end
    end
    return true
end

function mr.stripMitreTail(points, widths, heights, mitres, frac)
    local f = frac or meshRoad.miterStripFrac
    local n = #points
    if n < 3 or not mitres or #mitres == 0 or f <= 0.0 then
        return points, widths, heights, 0
    end
    local protect = {}
    for k = 1, #mitres do
        local mp          = mitres[k][1]
        local best, bestD = nil, math.huge
        for i = 1, n do
            local dx, dy = points[i].x - mp.x, points[i].y - mp.y
            local d      = math.sqrt(dx * dx + dy * dy)
            if d < bestD then best, bestD = i, d end
        end
        if best then protect[best] = true end
    end
    local keep = {}
    for i = 1, n do
        local drop = false
        if not protect[i] and i > 1 and i < n then
            for k = 1, #mitres do
                local mp, run = mitres[k][1], mitres[k][2]
                local r       = run * f
                if r > 1e-6 then
                    local dx, dy = points[i].x - mp.x, points[i].y - mp.y
                    if math.sqrt(dx * dx + dy * dy) < r then drop = true; break end
                end
            end
        end
        if not drop then keep[#keep + 1] = i end
    end
    if #keep < 3 or #keep == n then return points, widths, heights, 0 end
    local np, nw, nh = {}, {}, nil
    if heights then nh = {} end
    for k = 1, #keep do
        np[k] = points[keep[k]]
        nw[k] = widths[keep[k]]
        if nh then nh[k] = heights[keep[k]] end
    end
    return np, nw, nh, n - #keep
end

function mr.sharpenUnroundableCorners(points, widths, depths, spacing, maxTurnDeg, ratio)
    local n     = #points
    local sharp = {}
    for i = 1, n do sharp[i] = false end
    if n < 3 then return points, widths, depths, 0, nil end

    local blocked = {}
    for i = 1, n do blocked[i] = false end
    if meshRoad.sharpMiterFit then
        for i = 2, n - 1 do
            if not mr.mitreFits(points, widths, i) then blocked[i] = true end
        end
    end

    local baseDense = #(mr.densify(points, widths, depths, spacing, maxTurnDeg))
    local capDense  = baseDense * meshRoad.sharpMaxGrowth

    for _ = 1, n do
        local cp, cw, cd = mr.dupSharp(points, widths, depths, sharp)
        local dn, dw     = smoothPathWithWidths(cp, cw, spacing, cd, maxTurnDeg)
        dn, dw           = mr.dedupe(dn, dw, nil)

        local anyFree = false
        for m = 2, n - 1 do
            if not sharp[m] and not blocked[m] then anyFree = true; break end
        end

        local worst, at = math.huge, nil
        if anyFree then
            for k = 2, #dn - 1 do
                local hw = ((dw and dw[k]) or 0.0) / 2.0
                if hw > 1e-6 then
                    local bestD, near = math.huge, nil
                    for m = 2, n - 1 do
                        if not sharp[m] and not blocked[m] then
                            local d   = dn[k] - points[m]
                            local man = math.abs(d.x) + math.abs(d.y)
                            if man < bestD then bestD, near = man, m end
                        end
                    end
                    if near and (dn[k] - points[near]):length() <= spacing * 3.0 then
                        local r = mr.xyRadius(dn[k - 1], dn[k], dn[k + 1]) / hw
                        if r < worst then worst, at = r, near end
                    end
                end
            end
        end

        if not at or worst >= ratio then break end
        sharp[at] = true
        if baseDense > 0 and #dn > capDense then
            return points, widths, depths, 0, {runaway = true, from = baseDense, to = #dn}
        end
    end

    local count = 0
    for i = 1, n do if sharp[i] then count = count + 1 end end
    if count == 0 then return points, widths, depths, 0, nil end

    local cp, cw, cd = mr.dupSharp(points, widths, depths, sharp)
    local grown      = #(mr.densify(cp, cw, cd, spacing, maxTurnDeg))
    if baseDense > 0 and grown > capDense then
        return points, widths, depths, 0, {runaway = true, from = baseDense, to = grown}
    end
    local mitres = {}
    for i = 1, n do
        if sharp[i] then
            mitres[#mitres + 1] = {points[i], mr.mitreRun(points, widths, i)}
        end
    end
    return cp, cw, cd, count, nil, mitres
end

-- =============================================================================
-- SIMPLIFY
-- =============================================================================

function mr.ptLineDist(p, a, b)
    local ab = b - a
    local l2 = ab:dot(ab)
    if l2 < 1e-12 then return (p - a):length() end
    local s = clamp((p - a):dot(ab) / l2, 0.0, 1.0)
    return (p - (a + ab * s)):length()
end

function mr.simplifyIndices(points, widths, heights, tol, forced, maxSpan, maxTurnDeg)
    local n = #points
    if n < 3 or tol <= 0 then
        local all = {}
        for i = 1, n do all[i] = i end
        return all
    end

    local turnPrefix = {0.0}
    for k = 2, n - 1 do
        local d0     = points[k] - points[k - 1]
        local d1     = points[k + 1] - points[k]
        local ang    = 0.0
        local l0, l1 = d0:length(), d1:length()
        if l0 > 1e-9 and l1 > 1e-9 then
            ang = math.deg(math.acos(clamp(d0:dot(d1) / (l0 * l1), -1.0, 1.0)))
        end
        turnPrefix[k] = turnPrefix[k - 1] + ang
    end
    turnPrefix[n] = turnPrefix[n - 1] or 0.0

    local function ok(i, j)
        local a, b = points[i], points[j]
        if (b - a):length() > maxSpan then return false end
        if maxTurnDeg < 180.0 and (turnPrefix[j - 1] - turnPrefix[i]) > maxTurnDeg then
            return false
        end
        local span = j - i
        for k = i + 1, j - 1 do
            if forced and forced[k] then return false end
            if mr.ptLineDist(points[k], a, b) > tol then return false end
            local f = (k - i) / span
            if widths then
                if math.abs(widths[k] - (widths[i] + (widths[j] - widths[i]) * f)) > tol then
                    return false
                end
            end
            if heights then
                if math.abs(heights[k] - (heights[i] + (heights[j] - heights[i]) * f)) > tol then
                    return false
                end
            end
        end
        return true
    end

    local keep = {1}
    local i    = 1
    while i < n do
        local best = i + 1
        local j    = i + 2
        while j <= n and ok(i, j) do
            best = j
            j    = j + 1
        end
        keep[#keep + 1] = best
        i = best
    end
    return keep
end

function mr.applySimplify(points, widths, heights, forced)
    if not meshRoad.simplify or #points < 3 then return points, widths, heights end
    local w    = (widths and #widths == #points) and widths or nil
    local h    = (heights and #heights == #points) and heights or nil
    local keep = mr.simplifyIndices(points, w, h, meshRoad.simplifyTol * mrState.turnScale,
                                 forced, meshRoad.simplifyMaxSpan,
                                 meshRoad.simplifyMaxTurnDeg * mrState.turnScale)
    if #keep == #points then return points, widths, heights end
    local np, nw, nh = {}, (w and {} or widths), (h and {} or heights)
    for k, i in ipairs(keep) do
        np[k] = points[i]
        if w then nw[k] = widths[i] end
        if h then nh[k] = heights[i] end
    end
    return np, nw, nh
end

function mr.widthClampRatio()
    local frac  = clamp(meshRoad.minEdgeAdvanceFrac, 0.0, 0.9)
    local guard = meshRoad.widthClampHeadroom / math.max(1e-6, 1.0 - frac)
    return math.max(meshRoad.sweptMinRatio, guard)
end

function mr.clampWidthsToRadius(points, widths, closed, ratio, slope, floorHw)
    local n = #points
    if n < 3 or not widths or #widths ~= n then return widths, 0.0 end
    ratio   = ratio or mr.widthClampRatio()
    slope   = slope or meshRoad.widthLipschitz
    floorHw = floorHw or meshRoad.minHalfWidth

    local hw = {}
    for i = 1, n do
        local a, b, c
        if closed then
            a = points[((i - 2) % n) + 1]; b = points[i]; c = points[(i % n) + 1]
        elseif i == 1 then
            a, b, c = points[1], points[2], points[3]
        elseif i == n then
            a, b, c = points[n - 2], points[n - 1], points[n]
        else
            a, b, c = points[i - 1], points[i], points[i + 1]
        end
        local cap = (ratio > 0) and (mr.xyRadius(a, b, c) / ratio) or math.huge
        hw[i]     = math.max(floorHw, math.min(widths[i] / 2.0, cap))
    end

    local seg = {0.0}
    for i = 2, n do
        local dx, dy = points[i].x - points[i - 1].x, points[i].y - points[i - 1].y
        seg[i]       = math.sqrt(dx * dx + dy * dy)
    end
    local wrap = 0.0
    if closed then
        local dx, dy = points[1].x - points[n].x, points[1].y - points[n].y
        wrap         = math.sqrt(dx * dx + dy * dy)
    end

    for _ = 1, (closed and 3 or 1) do
        for i = 2, n do hw[i] = math.min(hw[i], hw[i - 1] + slope * seg[i]) end
        for i = n - 1, 1, -1 do hw[i] = math.min(hw[i], hw[i + 1] + slope * seg[i + 1]) end
        if closed then
            hw[1] = math.min(hw[1], hw[n] + slope * wrap)
            hw[n] = math.min(hw[n], hw[1] + slope * wrap)
        end
    end

    local out, worst = {}, -math.huge
    for i = 1, n do
        out[i]  = 2.0 * hw[i]
        local d = (widths[i] - out[i]) / 2.0
        if d > worst then worst = d end
    end
    return out, worst
end

function mr.offsetAdvances(points, tangents, offsets, j, i, minFrac)
    local tj, ti = tangents[j], tangents[i]
    local need   = meshRoad.foldGuardEps
    if minFrac and minFrac > 0.0 then
        local dx, dy = points[i].x - points[j].x, points[i].y - points[j].y
        need         = math.max(need, minFrac * math.sqrt(dx * dx + dy * dy))
    end
    for _, s in ipairs({-1.0, 1.0}) do
        local oj, oi = s * offsets[j], s * offsets[i]
        local dx     = (points[i].x - ti.y * oi) - (points[j].x - tj.y * oj)
        local dy     = (points[i].y + ti.x * oi) - (points[j].y + tj.x * oj)
        if dx * tj.x + dy * tj.y <= need then return false end
        if dx * ti.x + dy * ti.y <= need then return false end
    end
    return true
end

function mr.nonFoldingKeep(points, tangents, offsets, closed, forced, minFrac)
    local n = #points
    if n < 3 or not offsets or #offsets ~= n then
        local all = {}
        for i = 1, n do all[i] = i end
        return all
    end
    local keep = {1}
    for i = 2, n do
        local j = keep[#keep]
        if (forced and forced[i]) or mr.offsetAdvances(points, tangents, offsets, j, i, minFrac) then
            keep[#keep + 1] = i
        elseif i == n and not closed then
            if #keep > 1 and not (forced and forced[j]) then
                keep[#keep] = i
            else
                keep[#keep + 1] = i
            end
        end
    end
    if closed then
        while #keep > 3 and not mr.offsetAdvances(points, tangents, offsets, keep[#keep], keep[1], minFrac) do
            if forced and forced[keep[#keep]] then break end
            keep[#keep] = nil
        end
    end
    return keep
end

function mr.miterScales(points, tangents, closed, radial)
    local n   = #points
    local out = {}
    for i = 1, n do out[i] = 1.0 end
    if not meshRoad.miterComp or n < 3 then return out end
    for i = 1, n do
        if not (radial and radial[i]) then
            local j = closed and ((i % n) + 1) or math.min(i + 1, n)
            if j ~= i then
                local d = points[j] - points[i]
                local L = math.sqrt(d.x * d.x + d.y * d.y)
                if L >= 1e-9 then
                    local cosHalf = (d.x * tangents[i].x + d.y * tangents[i].y) / L
                    if cosHalf > 1e-3 then
                        out[i] = math.min(meshRoad.miterLimit, 1.0 / cosHalf)
                    end
                end
            end
        end
    end
    if not closed then
        out[1] = 1.0
        out[n] = 1.0
    end
    return out
end

function mr.edgeAdvance(points, tangents, i, j, off)
    local ti, tj = tangents[i], tangents[j]
    local ax     = points[i].x - ti.y * off
    local ay     = points[i].y + ti.x * off
    local bx     = points[j].x - tj.y * off
    local by     = points[j].y + tj.x * off
    local dx, dy = bx - ax, by - ay
    return math.min(dx * ti.x + dy * ti.y, dx * tj.x + dy * tj.y)
end

function mr.spanGeometry(points, tangents, widths, i, j)
    local hw = math.max(0.0, math.min(widths[i], widths[j]) / 2.0 - S.curbStrip)
    if hw <= 1e-6 then return 0.0, 0.0, 0.0, 0.0 end
    local a  = mr.edgeAdvance(points, tangents, i, j, -hw)
    local b  = mr.edgeAdvance(points, tangents, i, j, hw)
    local dz = math.abs(points[j].z - points[i].z)
    return a, b, dz, hw
end

function mr.spanFoldDeg(a, b, dz)
    local lo, hi = a, b
    if lo > hi then lo, hi = b, a end
    if dz < 1e-9 or lo <= 1e-9 or hi <= 1e-9 then return 0.0 end
    return math.deg(math.atan(dz / lo) - math.atan(dz / hi))
end

function mr.walkSplitFracs(n, a, b, dz, hw)
    if n < 2 then return {} end
    local lo, hi = a, b
    if lo > hi then lo, hi = b, a end
    local out = {}
    if hw <= 1e-6 or dz < 1e-9 or lo <= 1e-9 or (hi - lo) <= 1e-9 then
        for i = 1, n - 1 do out[i] = 2.0 * i / n - 1.0 end
        return out
    end
    local R      = hw * (hi + lo) / (hi - lo)
    local K      = dz * R * 2.0 / (hi + lo)
    local phiIn  = math.atan(K / math.max(1e-9, R - hw))
    local phiOut = math.atan(K / (R + hw))
    if math.abs(phiIn - phiOut) < 1e-9 then
        for i = 1, n - 1 do out[i] = 2.0 * i / n - 1.0 end
        return out
    end
    for k = 1, n - 1 do
        local phi = phiIn + (phiOut - phiIn) * k / n
        local x   = K / math.tan(phi) - R
        out[k]    = clamp(x / hw, -0.999, 0.999)
    end
    if a > b then
        for k = 1, #out do out[k] = -out[k] end
    end
    table.sort(out)
    return out
end

-- =============================================================================
-- CROSS SECTION
-- =============================================================================

local function sectionLayout(width, profile, insetOverride, capShrink, height, uvHw, walkFracs)
    local hw = width * 0.5
    height   = height or S.height
    local inset
    if insetOverride == nil then
        inset = math.max(0.0, hw - S.curbStrip)
    else
        inset = math.max(0.0, math.min(insetOverride, hw))
    end

    local prof    = S.curbProfiles[profile] or S.curbProfiles.walk
    local chamfer = math.min(prof.exposed, height)
    local slopeH  = math.min(math.tan(math.rad(prof.angle)) * chamfer,
                            math.max(0.0, (hw - inset) * 0.9))

    local chX = nil
    if slopeH > 1e-6 and chamfer > 1e-6 then
        chX = hw - slopeH
        if capShrink then
            chX = math.max(inset, math.min(capShrink(slopeH), hw))
        end
    else
        chamfer, slopeH = 0.0, 0.0
    end

    local useUv   = uvHw ~= nil
    local uvh     = uvHw or hw
    local uvInset = math.max(0.0, uvh - S.curbStrip)

    local cols = {}

    local function add(x, ux, drop, kind, hasBottom, role)
        cols[#cols + 1] = {x = x, uvx = (useUv and ux or x),
                           drop = drop, kind = kind, bottom = hasBottom, role = role}
    end

    if chX then
        add(-hw, -uvh, chamfer, "chamfer", true, "outer_near")
        add(-chX, -uvh + slopeH, 0.0, "curbtop", false, "outer_near_chamfer")
    else
        add(-hw, -uvh, chamfer, "curbtop", true, "outer_near")
    end
    add(-inset, -uvInset, 0.0, "walk", true, "inner_near")
    if walkFracs then
        for k, f in ipairs(walkFracs) do
            add(inset * f, uvInset * f, 0.0, "walk", false, "walk_" .. k)
        end
    end
    add(inset, uvInset, 0.0, "curbtop", true, "inner_far")
    if chX then
        add(chX, uvh - slopeH, 0.0, "chamfer", false, "outer_far_chamfer")
    end
    add(hw, uvh, chamfer, nil, true, "outer_far")
    return cols, hw, chamfer
end

-- =============================================================================
-- CAPS
-- =============================================================================

local function capEllipseShrink(aOut, bOut, adv)
    return function(sv)
        local aS, bS = aOut - sv, bOut - sv
        if aS <= 1e-6 or bS <= 0.0 or adv >= aS then return 0.0 end
        local r = adv / aS
        return bS * math.sqrt(math.max(0.0, 1.0 - r * r))
    end
end

local function addRoundedEnds(points, tangents, dists, widths, closed,
                              noCapStart, noCapEnd)
    local n    = #points
    local caps = {}
    for i = 1, n do caps[i] = false end
    if closed or not roundEnd.on or n < 2 then
        return points, tangents, dists, widths, caps
    end

    local function fan(idx, direction)
        local w0 = widths[idx]
        local hw = w0 / 2.0
        if hw <= 1e-6 then return {} end
        if roundEnd.maxWidth and w0 >= roundEnd.maxWidth then return {} end

        local tip      = math.max(roundEnd.tipWidth, 2.0 * S.curbStrip + 0.01)
        tip            = math.max(1e-4, math.min(tip, w0 * 0.9))
        local thetaMax = math.acos(clamp(tip / w0, -1.0, 1.0))
        local steps    = math.max(1, math.ceil(math.deg(thetaMax)
                                            / math.max(0.5, roundEnd.maxTurnDeg)))

        local aOut = hw * roundEnd.radiusScale
        local bOut = hw
        local aIn  = aOut - S.curbStrip
        local bIn  = bOut - S.curbStrip

        local thetas = {}
        for k = 1, steps do thetas[#thetas + 1] = thetaMax * k / steps end
        if aIn > 0.0 and aIn < aOut then
            local thClose = math.asin(clamp(aIn / aOut, -1.0, 1.0))
            if thClose > 1e-4 and thClose < thetaMax - 1e-4 then
                thetas[#thetas + 1] = thClose

                local seen, uniq = {}, {}
                for _, x in ipairs(thetas) do
                    local r = math.floor(x * 1e9 + 0.5) / 1e9
                    if not seen[r] then seen[r] = true; uniq[#uniq + 1] = r end
                end
                table.sort(uniq)
                thetas = uniq
            end
        end

        local minStep     = math.max(2e-3, 0.01 * hw)
        local keep        = {}
        local pAdv, pHalf = 0.0, hw
        for _, th in ipairs(thetas) do
            local adv, half = aOut * math.sin(th), bOut * math.cos(th)
            local dx, dy    = adv - pAdv, half - pHalf
            if math.sqrt(dx * dx + dy * dy) >= minStep then
                keep[#keep + 1] = th
                pAdv, pHalf = adv, half
            end
        end
        if #thetas > 0 and (#keep == 0 or keep[#keep] ~= thetas[#thetas]) then
            if #keep > 0 then keep[#keep] = thetas[#thetas] else keep = {thetas[#thetas]} end
        end
        thetas = keep

        local tan               = tangents[idx]
        local out               = {}
        local arc               = 0.0
        local prevAdv, prevHalf = 0.0, hw
        for _, th in ipairs(thetas) do
            local adv  = aOut * math.sin(th)
            local half = bOut * math.cos(th)

            local inset = 0.0
            if aIn > 1e-6 and bIn > 0.0 and adv < aIn then
                local r = adv / aIn
                inset   = bIn * math.sqrt(math.max(0.0, 1.0 - r * r))
            end
            inset = math.min(half * 0.999, math.max(inset, half * 0.005))

            local dx, dy      = adv - prevAdv, half - prevHalf
            arc               = arc + math.sqrt(dx * dx + dy * dy)
            prevAdv, prevHalf = adv, half

            out[#out + 1] = {
                p   = points[idx] + tan * (direction * adv),
                t   = tan,
                d   = dists[idx] + direction * adv,
                w   = 2.0 * half,
                cap = {inset = inset, uvHw = hw,
                       uvS    = dists[idx] + direction * arc,
                       shrink = capEllipseShrink(aOut, bOut, adv)},
            }
        end
        return out
    end

    local head = {}
    if not noCapStart then
        local f = fan(1, -1)
        for i = #f, 1, -1 do head[#head + 1] = f[i] end
    end
    local tail = noCapEnd and {} or fan(n, 1)
    if #head == 0 and #tail == 0 then
        return points, tangents, dists, widths, caps
    end

    local op, ot, od, ow, oc = {}, {}, {}, {}, {}
    local function push(p, t, d, w, c)
        op[#op + 1] = p; ot[#ot + 1] = t; od[#od + 1] = d; ow[#ow + 1] = w
        oc[#oc + 1] = c
    end
    for _, r in ipairs(head) do push(r.p, r.t, r.d, r.w, r.cap) end
    for i = 1, n do push(points[i], tangents[i], dists[i], widths[i], false) end
    for _, r in ipairs(tail) do push(r.p, r.t, r.d, r.w, r.cap) end
    return op, ot, od, ow, oc
end

-- =============================================================================
-- MESH
-- =============================================================================

local function newSubmesh(material)
    return {verts = {}, faces = {}, normals = {}, uvs = {}, material = material,
            _nv = 0, _nn = 0, _nu = 0}
end

local function pushVert(sm, p)
    sm.verts[sm._nv + 1] = {x = p.x, y = p.y, z = p.z}
    sm._nv = sm._nv + 1
    return sm._nv - 1
end

local function pushNormal(sm, n)
    sm.normals[sm._nn + 1] = {x = n.x, y = n.y, z = n.z}
    sm._nn = sm._nn + 1
    return sm._nn - 1
end

local uvFlipV = true

local function pushUV(sm, u, v)
    if uvFlipV then v = 1.0 - v end
    sm.uvs[sm._nu + 1] = {u = u, v = v}
    sm._nu = sm._nu + 1
    return sm._nu - 1
end

local function pushTri(sm, a, b, c, n, ua, ub, uc)
    local f = sm.faces
    f[#f + 1] = {v = a, n = n, u = ua}
    f[#f + 1] = {v = b, n = n, u = ub}
    f[#f + 1] = {v = c, n = n, u = uc}
end

local function windingNormal(vs)
    local n = vec3(0, 0, 0)
    local m = #vs
    for i = 1, m do
        local a, b = vs[i], vs[(i % m) + 1]
        n          = n + a:cross(b)
    end
    return n
end


local function emitFace(sm, vs, uvs, want, tag)
    local m = #vs
    if m < 3 then return end
    local n = windingNormal(vs)
    if n:length() < 1e-9 then return end
    if want and (n:dot(want) * S.faceSign) < 0 then
        local rv, ru = {}, {}
        for i = m, 1, -1 do
            rv[#rv + 1] = vs[i]
            ru[#ru + 1] = uvs[i]
        end
        vs, uvs = rv, ru
        n       = n * -1
    end
    local shade  = n:normalized() * S.faceSign
    local nIdx   = pushNormal(sm, shade)
    local vi, ui = {}, {}
    for i = 1, m do
        vi[i] = pushVert(sm, vs[i])
        ui[i] = pushUV(sm, uvs[i][1], uvs[i][2])
    end
    for i = 2, m - 1 do
        pushTri(sm, vi[1], vi[i], vi[i + 1], nIdx, ui[1], ui[i], ui[i + 1])
    end
end

local function pushQuad(sm, pA1, pA2, pB2, pB1, uvA1, uvA2, uvB2, uvB1, want, tag)
    if mrState.orient then
        emitFace(sm, {pA1, pA2, pB2, pB1}, {uvA1, uvA2, uvB2, uvB1},
                 want or vec3(0, 0, 1), tag)
        return
    end
    local e1 = pA2 - pA1
    local e2 = pB1 - pA1
    local n  = e1:cross(e2)
    if n:length() < 1e-9 then return end
    n = n:normalized()
    if n.z < 0 then n = n * -1 end

    local nIdx = pushNormal(sm, n)
    local i1   = pushVert(sm, pA1)
    local i2   = pushVert(sm, pA2)
    local i3   = pushVert(sm, pB2)
    local i4   = pushVert(sm, pB1)
    local t1   = pushUV(sm, uvA1[1], uvA1[2])
    local t2   = pushUV(sm, uvA2[1], uvA2[2])
    local t3   = pushUV(sm, uvB2[1], uvB2[2])
    local t4   = pushUV(sm, uvB1[1], uvB1[2])

    pushTri(sm, i1, i2, i3, nIdx, t1, t2, t3)
    pushTri(sm, i1, i3, i4, nIdx, t1, t3, t4)
end

local function pushWall(sm, pA1, pA2, pB2, pB1, uvA1, uvA2, uvB2, uvB1, outward)
    if mrState.orient then
        emitFace(sm, {pA1, pA2, pB2, pB1}, {uvA1, uvA2, uvB2, uvB1}, outward)
        return
    end
    local e1 = pA2 - pA1
    local e2 = pB1 - pA1
    local n  = e1:cross(e2)
    if n:length() < 1e-9 then return end
    n = n:normalized()
    if outward and n:dot(outward) < 0 then n = n * -1 end

    local nIdx = pushNormal(sm, n)
    local i1   = pushVert(sm, pA1)
    local i2   = pushVert(sm, pA2)
    local i3   = pushVert(sm, pB2)
    local i4   = pushVert(sm, pB1)
    local t1   = pushUV(sm, uvA1[1], uvA1[2])
    local t2   = pushUV(sm, uvA2[1], uvA2[2])
    local t3   = pushUV(sm, uvB2[1], uvB2[2])
    local t4   = pushUV(sm, uvB1[1], uvB1[2])

    pushTri(sm, i1, i2, i3, nIdx, t1, t2, t3)
    pushTri(sm, i1, i3, i4, nIdx, t1, t3, t4)
end

function mr.pushCapRing(sm, st, ring, uvFor, want)
    local n   = #ring
    local out = {}
    for k = 1, n do
        local e, nx = ring[k], ring[k % n + 1]
        out[#out + 1] = e
        if e.bottom == nx.bottom and math.abs(nx.ci - e.ci) > 1 then
            local step = (nx.ci > e.ci) and 1 or -1
            for ci = e.ci + step, nx.ci - step, step do
                local v = e.bottom and st.bot[ci] or (not e.bottom and st.top[ci]) or nil
                if v then out[#out + 1] = {v = v, uv = uvFor(ci, e.bottom), bottom = e.bottom, ci = ci} end
            end
        end
    end
    local nx, ny, nz = 0.0, 0.0, 0.0
    for k = 1, #out do
        local a, b = out[k].v, out[k % #out + 1].v
        nx         = nx + (a.y - b.y) * (a.z + b.z)
        ny         = ny + (a.z - b.z) * (a.x + b.x)
        nz         = nz + (a.x - b.x) * (a.y + b.y)
    end
    local ax, ay, az = math.abs(nx), math.abs(ny), math.abs(nz)
    local function p2(v)
        if az >= ax and az >= ay then return v.x, v.y, nz end
        if ax >= ay then return v.y, v.z, nx end
        return v.z, v.x, ny
    end
    local idx = {}
    for k = 1, #out do idx[k] = k end
    local function cross(a, b, c)
        local x1, y1, sg = p2(out[a].v)
        local x2, y2     = p2(out[b].v)
        local x3, y3     = p2(out[c].v)
        return ((x2 - x1) * (y3 - y1) - (y2 - y1) * (x3 - x1)) * ((sg >= 0) and 1 or -1)
    end
    local guard = 0
    while #idx > 3 and guard < 1000 do
        guard     = guard + 1
        local cut = false
        for k = 1, #idx do
            local a, b, c = idx[(k - 2) % #idx + 1], idx[k], idx[k % #idx + 1]
            if cross(a, b, c) > 1e-10 then
                local clean = true
                for _, o in ipairs(idx) do
                    if o ~= a and o ~= b and o ~= c and cross(a, b, o) >= -1e-10 and cross(b, c, o) >= -1e-10 and cross(c, a, o) >= -1e-10 then
                        clean = false
                        break
                    end
                end
                if clean then
                    emitFace(sm, {out[a].v, out[b].v, out[c].v}, {out[a].uv, out[b].uv, out[c].uv}, want)
                    table.remove(idx, k)
                    cut = true
                    break
                end
            end
        end
        if not cut then break end
    end
    if #idx == 3 then
        emitFace(sm, {out[idx[1]].v, out[idx[2]].v, out[idx[3]].v}, {out[idx[1]].uv, out[idx[2]].uv, out[idx[3]].uv}, want)
    elseif #idx > 3 then
        local vs, uvs = {}, {}
        for k, i in ipairs(idx) do vs[k], uvs[k] = out[i].v, out[i].uv end
        emitFace(sm, vs, uvs, want)
    end
end

function mr.capCurbUV(localX, htLocal, zLocal)
    local depth = math.max(0.0, htLocal - zLocal)
    local atlas = curbAtlas()
    local _, sv = mr.curbScale()
    local sc    = (atlas and atlas.uScale) or sv
    return {localX / sc + 0.5, curbFaceV(depth)}
end

function mr.capWalkUV(edgeDist, sign, localX, htLocal, zLocal)
    local wrap   = edgeDist + sign * (htLocal - zLocal)
    local su, sv = mr.walkScale()
    return {localX / su + 0.5, wrap / sv + 0.5}
end

-- =============================================================================
-- END CURBS
-- =============================================================================

function mr.isClosedLoop(points)
    return #points >= 3 and (points[1] - points[#points]):length() < paths.loopTol
end

mr.endFrameMinBody = 0.10

function mr.endFrameSlope(width, height, profile)
    local hw      = width * 0.5
    local strip   = hw - math.max(0.0, hw - S.curbStrip)
    local prof    = S.curbProfiles[profile] or S.curbProfiles.walk
    local chamfer = math.min(prof.exposed, height)
    local slopeH  = math.min(math.tan(math.rad(prof.angle)) * chamfer, math.max(0.0, strip * 0.9))
    if slopeH <= 1e-6 or chamfer <= 1e-6 or slopeH >= S.curbStrip - 1e-3 then return 0.0 end
    return slopeH
end

function mr.endFrameRings(path, pathW, pathH, tangents, dists, profile)
    local n = #path
    if n < 2 then return nil end
    if dists[n] - dists[1] < 2.0 * S.curbStrip + mr.endFrameMinBody then return nil end

    local function sample(d)
        local j = 1
        while j < n - 1 and dists[j + 1] < d do j = j + 1 end
        local span = dists[j + 1] - dists[j]
        local f    = 0.0
        if span > 1e-12 then f = math.max(0.0, math.min(1.0, (d - dists[j]) / span)) end
        local t = tangents[j] * (1.0 - f) + tangents[j + 1] * f
        t       = (t:length() > 1e-9) and t:normalized() or tangents[j]
        return {path[j] + (path[j + 1] - path[j]) * f, t, d,
                pathW[j] + (pathW[j + 1] - pathW[j]) * f,
                pathH[j] + (pathH[j + 1] - pathH[j]) * f}
    end
    local function row(i) return {path[i], tangents[i], dists[i], pathW[i], pathH[i]} end

    local sh0 = mr.endFrameSlope(pathW[1], pathH[1], profile)
    local sh1 = mr.endFrameSlope(pathW[n], pathH[n], profile)
    local lo  = dists[1] + S.curbStrip + 1e-4
    local hi  = dists[n] - S.curbStrip - 1e-4

    local rows = {row(1)}
    if sh0 > 0.0 then rows[#rows + 1] = sample(dists[1] + sh0) end
    rows[#rows + 1] = sample(dists[1] + S.curbStrip)
    for i = 2, n - 1 do
        if dists[i] > lo and dists[i] < hi then rows[#rows + 1] = row(i) end
    end
    rows[#rows + 1] = sample(dists[n] - S.curbStrip)
    if sh1 > 0.0 then rows[#rows + 1] = sample(dists[n] - sh1) end
    rows[#rows + 1] = row(n)

    local p, t, d, w, h = {}, {}, {}, {}, {}
    for k, r in ipairs(rows) do
        p[k], t[k], d[k], w[k], h[k] = r[1], r[2], r[3], r[4], r[5]
    end
    return p, w, h, t, d
end

function mr.frameTris(e)
    local a, b, c = e, (e % 4) + 1, ((e + 1) % 4) + 1
    local d       = ((e + 2) % 4) + 1
    return {{a, b, c}, {a, c, d}}
end

-- =============================================================================
-- MESHROAD
-- =============================================================================

function mr.prepareMeshRoad(spl)
    mr.depthRingKeys      = {}
    local note            = {}
    local raw, rawW, rawH = spl.points, spl.widths, spl.depths
    local closed          = mr.isClosedLoop(raw)

    local p, w, h = {}, {}, {}
    local last    = closed and (#raw - 1) or #raw
    for i = 1, last do
        p[i] = raw[i]
        w[i] = rawW[i]
        h[i] = rawH and rawH[i] or S.height
    end
    if #p < 2 then return nil end

    mrState.up, mrState.turnScale, mrState.mitres = nil, 1.0, nil
    local ups                                     = spl.ups
    local tilted                                  = false
    if ups then
        for _, u in ipairs(ups) do
            if math.sqrt(u.x * u.x + u.y * u.y) > 1e-6 then tilted = true break end
        end
    end
    if meshRoad.roll and spl.roll and tilted then
        local nodeD = {0.0}
        for k = 2, #raw do
            local a, b = raw[k - 1], raw[k]
            nodeD[k]   = nodeD[k - 1] + math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
        end
        mrState.up       = function(s) return mr.upAt(ups, nodeD, s) end
        local lever, hw0 = 0.0, (rawW[1] or 2.0) / 2.0
        for k, u in ipairs(ups) do
            local hw  = (rawW[k] or rawW[1] or 2.0) / 2.0
            local dep = (rawH and rawH[k]) or 0.0
            local lv  = hw + math.abs(dep) * math.sqrt(u.x * u.x + u.y * u.y)
            if lv > lever then lever = lv end
        end
        mrState.turnScale = (lever > 1e-6) and clamp(hw0 / lever, 0.12, 1.0) or 1.0
        note.roll         = true
    end

    local spacing = meshRoad.smoothCorners and meshRoad.segLen or 0.0
    local turn    = meshRoad.maxTurnDeg

    if meshRoad.minRadiusMargin > 0 and not closed then
        local disp, iters, ratio, at
        p, w, h, disp, iters, ratio, at = mr.relaxForSweptPath(p, w, h, spacing, turn)
        note.relaxDisp, note.relaxIters = disp, iters
        note.sweptRatio, note.sweptAt   = ratio, at
    end

    if meshRoad.smoothCorners then
        if meshRoad.sharpCorners then
            local nSharp, runaway, mitres
            p, w, h, nSharp, runaway, mitres = mr.sharpenUnroundableCorners(
                p, w, h, meshRoad.segLen, turn, meshRoad.sharpRatio)
            note.sharp, note.sharpRunaway = nSharp, runaway
            mrState.mitres                = mitres
        end
        p, w, h = smoothPathWithWidths(p, w, meshRoad.segLen, h, turn,
                                       meshRoad.depthStep)
        p, w, h = mr.dedupe(p, w, h)
        if meshRoad.miterStrip and mrState.mitres then
            local nStrip
            p, w, h, nStrip    = mr.stripMitreTail(p, w, h, mrState.mitres)
            note.mitreStripped = nStrip
        end
    end

    local before    = #p
    p, w, h         = mr.applySimplify(p, w, h, nil)
    note.simplified = before - #p

    if meshRoad.widthClamp and not closed then
        local narrowed
        w, narrowed   = mr.clampWidthsToRadius(p, w, closed)
        note.narrowed = narrowed
    end

    local tangents = mr.interpDepthRingTangents(p, mr.computeTangents(p))
    local dists    = mr.cumulativeDistances(p)

    if meshRoad.foldGuard and #p > 2 then
        local offsets = {}
        for i = 1, #p do offsets[i] = w[i] / 2.0 end
        local forced = nil
        if meshRoad.forceMiterRings and mrState.mitres and #mrState.mitres > 0 then
            if not forced then
                forced = {}
                for i = 1, #p do forced[i] = false end
            end
            for k = 1, #mrState.mitres do
                local mp          = mrState.mitres[k][1]
                local best, bestD = nil, meshRoad.miterMatchDist
                for i = 1, #p do
                    local dx, dy = p[i].x - mp.x, p[i].y - mp.y
                    local d      = math.sqrt(dx * dx + dy * dy)
                    if d < bestD then best, bestD = i, d end
                end
                if best then forced[best] = true end
            end
        end
        local keep = mr.nonFoldingKeep(p, tangents, offsets, closed, forced,
                                    meshRoad.minEdgeAdvanceFrac)
        if #keep > 2 and #keep < #p then
            note.foldDropped         = #p - #keep
            local np, nw, nh, nt, nd = {}, {}, {}, {}, {}
            for k, i in ipairs(keep) do
                np[k], nw[k], nh[k], nt[k], nd[k] = p[i], w[i], h[i], tangents[i], dists[i]
            end
            p, w, h, tangents, dists = np, nw, nh, nt, nd
        end
    end

    return p, w, h, tangents, dists, closed, note
end

-- =============================================================================
-- BUILD
-- =============================================================================

local function buildRoadMesh(spl)
    mr.lastBuild  = nil
    local pts, ws = spl.points, spl.widths
    if #pts < 2 then return nil end

    local isMesh = (spl.source == "meshroad")
    local path, pathW, pathH, tangents, dists, isClosed, caps, note

    local framed  = false
    local gateAt  = nil
    local winPlan = nil
    if isMesh then
        local gates, gateDepths                             = Gate.resolve(spl)
        local rawDepths                                     = spl.depths
        spl.depths                                          = gateDepths
        path, pathW, pathH, tangents, dists, isClosed, note = mr.prepareMeshRoad(spl)
        spl.depths                                          = rawDepths
        if not path or #path < 2 then return nil end
        if spl.ends == true and not isClosed then
            local fp, fw, fh, ft, fd = mr.endFrameRings(path, pathW, pathH, tangents, dists,
                                                        spl.profile or "walk")
            if fp then
                path, pathW, pathH, tangents, dists = fp, fw, fh, ft, fd
                framed                              = true
            elseif note then
                note.endsTooShort = true
            end
        end
        if gates and not isClosed then
            path, pathW, pathH, tangents, gateAt = Gate.apply(gates, spl, path, pathW, pathH, tangents)
            if gateAt then dists = mr.cumulativeDistances(path) end
        end
        if spl.windows and not isClosed then
            path, pathW, pathH, tangents, gateAt, winPlan = Window.plan(spl.windows, path, pathW, pathH, tangents, gateAt)
            dists                                         = mr.cumulativeDistances(path)
        end
        caps = {}
        for i = 1, #path do caps[i] = false end
    else
        mrState.up, mrState.turnScale = nil, 1.0
        local sp, spW                 = smoothPathWithWidths(pts, ws, smoothing.segLen)
        path, pathW                   = sp, spW
        if #path < 2 then return nil end

        isClosed = spl.closed
        if isClosed == nil then
            isClosed = #path >= 3
                              and (path[1] - path[#path]):length() < paths.loopTol
        end

        local np   = #path
        local secT = nil
        if spl.sectionTangents then
            secT = resampleSectionTangents(pts, spl.sectionTangents, smoothing.segLen)
            if secT and #secT ~= np then secT = nil end
        end

        if meshRoad.simplify and np >= 3 then
            local forced = nil
            if secT then
                forced = {}
                for i = 1, np do forced[i] = secT[i] ~= nil end
            end
            local w    = (pathW and #pathW == np) and pathW or nil
            local keep = mr.simplifyIndices(path, w, nil, meshRoad.simplifyTol * mrState.turnScale, forced,
                                            meshRoad.simplifyMaxSpan, meshRoad.simplifyMaxTurnDeg * mrState.turnScale)
            if #keep < np then
                local p2, w2, s2 = {}, {}, (secT and {} or nil)
                for k, i in ipairs(keep) do
                    p2[k] = path[i]
                    w2[k] = pathW[i]
                    if secT then s2[k] = secT[i] end
                end
                path, pathW, secT = p2, w2, s2
                np                = #path
            end
        end

        tangents, dists = {}, {}
        local acc       = 0.0
        for i = 1, np do
            local tn
            if isClosed then
                tn = path[(i % np) + 1] - path[((i - 2) % np) + 1]
            elseif i == 1 then tn = path[2] - path[1]
            elseif i == np then tn = path[np] - path[np - 1]
            else tn = path[i + 1] - path[i - 1] end
            tn = vec3(tn.x, tn.y, 0)
            if tn:length() < 1e-9 then tn = vec3(1, 0, 0) end
            tangents[i] = (secT and secT[i]) or tn:normalized()
            if i > 1 then acc = acc + (path[i] - path[i - 1]):length() end
            dists[i] = acc
        end

        if spl.roundEnds ~= false then
            path, tangents, dists, pathW, caps =
              addRoundedEnds(path, tangents, dists, pathW, isClosed,
                             spl.noCapStart, spl.noCapEnd)
        else
            caps = {}
            for i = 1, np do caps[i] = false end
        end
        pathH = {}
        for i = 1, #path do pathH[i] = S.height end
    end

    local np = #path

    local bodyW = {}
    for i = 1, np do
        if not caps[i] then bodyW[#bodyW + 1] = pathW[i] end
    end
    if #bodyW == 0 then for i = 1, np do bodyW[i] = pathW[i] end end
    table.sort(bodyW)
    local uvHw = bodyW[math.floor(#bodyW / 2) + 1] / 2.0

    local prof        = spl.profile or "walk"
    local overObjects = spl.overObjects and true or false
    local keepBottom  = isMesh and (spl.bottom == true)
    local uvRef       = (isMesh or meshRoad.uvxFromMedianDecal) and uvHw or nil

    local miter = nil
    if isMesh then miter = mr.miterScales(path, tangents, isClosed, nil) end

    local walkFracs, walkBands
    if isMesh and meshRoad.walkSplit and np >= 3 then
        local spans = {}
        for i = 1, np do
            local j = isClosed and ((i % np) + 1) or math.min(i + 1, np)
            if j ~= i then
                spans[i] = {mr.spanGeometry(path, tangents, pathW, i, j)}
            else
                spans[i] = {0.0, 0.0, 0.0, 0.0}
            end
        end
        if not isClosed and np >= 2 then spans[np] = spans[np - 1] end
        local worst, worstAt = 0.0, 1
        for i = 1, np do
            local f = mr.spanFoldDeg(spans[i][1], spans[i][2], spans[i][3])
            if f > worst then worst, worstAt = f, i end
        end
        if worst > meshRoad.walkSplitFoldDeg then
            walkBands = math.min(meshRoad.walkSplitMax,
                                 math.ceil(worst / meshRoad.walkSplitFoldDeg))
            local s   = spans[worstAt]
            walkFracs = mr.walkSplitFracs(walkBands, s[1], s[2], s[3], s[4])
            if note then note.walkBands, note.walkFold = walkBands, worst end
        end
    end

    local cols0 = sectionLayout(pathW[1], prof, caps[1] and caps[1].inset or nil,
                                caps[1] and caps[1].shrink or nil,
                                pathH[1], uvRef, walkFracs)
    local nc = #cols0

    local walkMat = walkMaterialName()
    local curbMat = curbMaterialName()
    if not curbMat then return nil, "curb.material is not set in the styles config" end

    local smWalk = newSubmesh(walkMat or curbMat)
    local smCurb = newSubmesh(curbMat)

    local stations = {}
    local tan3s    = nil
    for i = 1, np do
        local p       = path[i]
        local tn      = tangents[i]
        local m       = miter and miter[i] or 1.0
        local side    = vec3(-tn.y, tn.x, 0) * m
        local downDir = vec3(0, 0, -1)

        if isMesh and mrState.up then
            local upw  = mrState.up(dists[i])
            tan3s      = tan3s or mr.tangents3d(path, isClosed)
            local tan3 = tan3s[i]
            local u    = upw - tan3 * upw:dot(tan3)
            if u:length() > 1e-6 then
                u        = u:normalized()
                local sd = u:cross(tan3)
                if sd:length() > 1e-9 then
                    side    = sd:normalized()
                    downDir = u * -1.0
                end
            end
        end

        local c                 = caps[i]
        local hgt               = pathH[i]
        local cols, hw, chamfer = sectionLayout(pathW[i], prof,
                                                c and c.inset or nil,
                                                c and c.shrink or nil,
                                                hgt, uvRef, walkFracs)
        if #cols ~= nc then
            cols, hw, chamfer = sectionLayout(pathW[i], prof, nil, nil,
                                              hgt, uvRef, walkFracs)
        end

        local top, bot = {}, {}
        local endDrop  = (framed and (i == 1 or i == np)) and chamfer or 0.0
        for k = 1, nc do
            if isMesh then
                local q    = p + side * cols[k].x
                local lift = vec3(0, 0, S.zOffset)
                top[k]     = q + lift + downDir * math.max(cols[k].drop, endDrop)
                if cols[k].bottom or keepBottom or (gateAt and gateAt[i]) then
                    bot[k] = q + lift + downDir * hgt
                end
            else
                local q      = p + side * cols[k].x
                local ground = overObjects and p.z or terrainZ(q.x, q.y, p.z)
                local base   = ground + S.zOffset + decal.lift
                top[k]       = vec3(q.x, q.y, base - cols[k].drop)
                if cols[k].bottom then bot[k] = vec3(q.x, q.y, base - hgt) end
            end
        end

        local uvS   = (c and c.uvS) or dists[i]
        stations[i] = {top = top, bot = bot, s = uvS, side = side, down = downDir,
                       cols = cols, hw = hw, chamfer = chamfer, height = hgt,
                       gate = gateAt and gateAt[i] or nil}
    end

    mr.lastBuild = {stations = stations, closed = isClosed, isMesh = isMesh}

    local segCount = isClosed and np or (np - 1)
    local wrapS    = isClosed
                            and (stations[np].s + (path[1] - path[np]):length()) or 0.0
    local zoneLo  = dists[1] + S.curbStrip + 1e-4
    local zoneHi  = dists[np] - S.curbStrip - 1e-4
    local topSegs = (isMesh and spl.noTop) and 0 or segCount

    for i = 1, topSegs do
        local A, B       = stations[i], stations[(i % np) + 1]
        local sA         = A.s
        local sB         = (i == np) and wrapS or B.s
        local inZone     = framed and (dists[i + 1] <= zoneLo or dists[i] >= zoneHi)
        local endA, endB = framed and i == 1, framed and i + 1 == np
        local slopeSeg   = (endA or endB) and A.chamfer > 1e-6 and B.chamfer > 1e-6
        for c = 1, nc - 1 do
            local kind      = A.cols[c].kind or "curbtop"
            local frameWalk = inZone and kind == "walk"
            local sm        = (kind == "walk" and not frameWalk) and smWalk or smCurb
            local xa, xb    = A.cols[c].x, A.cols[c + 1].x
            local xa2, xb2  = B.cols[c].x, B.cols[c + 1].x

            local uvA1, uvA2, uvB2, uvB1
            if frameWalk then
                local ua, ub   = A.cols[c].uvx, A.cols[c + 1].uvx
                local ua2, ub2 = B.cols[c].uvx, B.cols[c + 1].uvx
                if slopeSeg then
                    local da   = endA and A.chamfer or 0.0
                    local db   = endB and B.chamfer or 0.0
                    uvA1, uvA2 = {curbU(ua), curbFaceV(da)}, {curbU(ub), curbFaceV(da)}
                    uvB2, uvB1 = {curbU(ub2), curbFaceV(db)}, {curbU(ua2), curbFaceV(db)}
                else
                    local wa   = S.curbStrip - math.max(0.0, math.min(sA - dists[1], dists[np] - sA))
                    local wb   = S.curbStrip - math.max(0.0, math.min(sB - dists[1], dists[np] - sB))
                    uvA1, uvA2 = {curbU(ua), curbTopV(wa)}, {curbU(ub), curbTopV(wa)}
                    uvB2, uvB1 = {curbU(ub2), curbTopV(wb)}, {curbU(ua2), curbTopV(wb)}
                end
            elseif kind == "walk" then
                local ua1, va1         = walkUV(xa, sA)
                local ua2, va2         = walkUV(xb, sA)
                local ub2, vb2         = walkUV(xb2, sB)
                local ub1, vb1         = walkUV(xa2, sB)
                uvA1, uvA2, uvB2, uvB1 = {ua1, va1}, {ua2, va2}, {ub2, vb2}, {ub1, vb1}
            elseif kind == "chamfer" then
                local da, db = A.cols[c].drop, A.cols[c + 1].drop
                uvA1         = {curbU(sA), curbFaceV(da)}
                uvA2         = {curbU(sA), curbFaceV(db)}
                uvB2         = {curbU(sB), curbFaceV(db)}
                uvB1         = {curbU(sB), curbFaceV(da)}
            else
                local ua, ub     = A.cols[c].uvx, A.cols[c + 1].uvx
                local ua2c, ub2c = B.cols[c].uvx, B.cols[c + 1].uvx
                local wa         = S.curbStrip - (uvHw - math.abs(ua))
                local wb         = S.curbStrip - (uvHw - math.abs(ub))
                local wa2        = S.curbStrip - (uvHw - math.abs(ua2c))
                local wb2        = S.curbStrip - (uvHw - math.abs(ub2c))
                uvA1             = {curbU(sA), curbTopV(wa)}
                uvA2             = {curbU(sA), curbTopV(wb)}
                uvB2             = {curbU(sB), curbTopV(wb2)}
                uvB1             = {curbU(sB), curbTopV(wa2)}
            end

            local want
            if isMesh then
                local up = A.down * -1
                if kind == "chamfer" then
                    local mid  = (A.cols[c].x + A.cols[c + 1].x) * 0.5
                    local outv = A.side:normalized() * ((mid < 0) and -1.0 or 1.0)
                    want       = (outv + up):normalized()
                else
                    want = up
                end
            end

            if slopeSeg and kind == "chamfer" then
                local outerFirst = (A.cols[c].role == "outer_near" or A.cols[c].role == "outer_far")
                local e
                if endA then e = outerFirst and 1 or 2 else e = outerFirst and 4 or 3 end
                local vq = {A.top[c], A.top[c + 1], B.top[c + 1], B.top[c]}
                local uq = {uvA1, uvA2, uvB2, uvB1}
                for _, t in ipairs(mr.frameTris(e)) do
                    emitFace(sm, {vq[t[1]], vq[t[2]], vq[t[3]]}, {uq[t[1]], uq[t[2]], uq[t[3]]},
                             want, kind)
                end
            else
                pushQuad(sm, A.top[c], A.top[c + 1], B.top[c + 1], B.top[c],
                         uvA1, uvA2, uvB2, uvB1, want, kind)
            end
        end
    end

    local winSubs = {}
    local winCtx  = winPlan and {nc = nc, np = np, gateAt = gateAt, tangents = tangents, emitFace = emitFace,
                                 uv = {curbU = curbU, curbFaceV = curbFaceV, capCurbUV = mr.capCurbUV}}
    if winCtx then
        local function styleOf(key)
            local raw = mr.rawStyle(key)
            if raw then return raw end
            local styles = styleCfg and styleCfg.wall and styleCfg.wall.styles
            local st     = styles and key and styles[key]
            if type(st) == "table" and st.material then return st end
            return nil
        end
        winCtx.smFor = function(key)
            local st = styleOf(key)
            if not st or st.material == smCurb.material then return smCurb end
            if not winSubs[st.material] then winSubs[st.material] = newSubmesh(st.material) end
            return winSubs[st.material]
        end
        winCtx.withStyle = function(key, fn)
            local st = styleOf(key)
            if not st then return fn() end
            local pm, ps      = mrState.curbMat, mrState.wallStyle
            mrState.curbMat   = st.material
            mrState.wallStyle = st
            fn()
            mrState.curbMat, mrState.wallStyle = pm, ps
        end
    end
    local winTaken = winCtx and Window.sides(winPlan, stations, winCtx) or nil
    local winEnds  = winCtx and {[1] = Window.endFace(winPlan, stations, winCtx, 1, -1),
                                 [np] = Window.endFace(winPlan, stations, winCtx, np, 1)} or {}

    local function at(st, c, depth)
        if not depth then return st.bot[c] end
        return st.bot[c] + st.down * (depth - st.height)
    end
    local function sillCut(i, j)
        local gA, gB = gateAt and gateAt[i], gateAt and gateAt[j]
        if not (gA and gB and (gA.open or gB.open)) then return nil, nil, false end
        return (not gA.open and gB.open) and gA.sill or nil, (not gB.open and gA.open) and gB.sill or nil, true
    end

    local function splitAt(k)
        local g = gateAt and gateAt[k]
        if not (g and not g.open and g.sill) then return nil end
        local p = gateAt[k - 1]
        local n = gateAt[k + 1]
        if (p and p.open) or (n and n.open) then return g.sill end
        return nil
    end

    for i = 1, segCount do
        local j      = (i % np) + 1
        local A, B   = stations[i], stations[j]
        local sA     = A.s
        local sB     = (i == np) and wrapS or B.s
        local dA, dB = sillCut(i, j)
        local kA     = not dA and splitAt(i)
        local kB     = not dB and splitAt(j)
        for _, c in ipairs({1, nc}) do
            if A.bot[c] and B.bot[c] and not (winTaken and winTaken[c] and winTaken[c][i]) then
                local outward = A.side * ((c == 1) and -1 or 1)
                if (kA or kB) and mrState.orient then
                    local tA, tB = {A.top[c], {curbU(sA), curbFaceV(A.chamfer)}}, {B.top[c], {curbU(sB), curbFaceV(B.chamfer)}}
                    local bA, bB = {A.bot[c], {curbU(sA), curbFaceV(A.height)}}, {B.bot[c], {curbU(sB), curbFaceV(B.height)}}
                    local mA     = kA and {at(A, c, kA), {curbU(sA), curbFaceV(kA)}}
                    local mB     = kB and {at(B, c, kB), {curbU(sB), curbFaceV(kB)}}
                    local polys
                    if mA and mB then
                        polys = {{tA, mA, mB}, {tA, mB, tB}, {mA, bA, bB}, {mA, bB, mB}}
                    elseif mA then
                        polys = {{tB, tA, mA}, {tB, mA, bA}, {tB, bA, bB}}
                    else
                        polys = {{tA, bA, bB}, {tA, bB, mB}, {tA, mB, tB}}
                    end
                    for _, poly in ipairs(polys) do
                        local vs, uvs = {}, {}
                        for k, e in ipairs(poly) do vs[k], uvs[k] = e[1], e[2] end
                        emitFace(smCurb, vs, uvs, outward)
                    end
                else
                    pushWall(smCurb, A.top[c], at(A, c, dA), at(B, c, dB), B.top[c],
                             {curbU(sA), curbFaceV(A.chamfer)},
                             {curbU(sA), curbFaceV(dA or A.height)},
                             {curbU(sB), curbFaceV(dB or B.height)},
                             {curbU(sB), curbFaceV(B.chamfer)},
                             outward)
                end
            end
        end
    end

    if keepBottom or gateAt then
        local run = stations[1].s
        for i = 1, segCount do
            local j              = (i % np) + 1
            local A, B           = stations[i], stations[j]
            local dA, dB, inGate = sillCut(i, j)
            local ds             = ((i == np) and wrapS or B.s) - A.s
            local dh             = (dB or B.height) - (dA or A.height)
            local sA             = run
            local sB             = run + math.sqrt(ds * ds + dh * dh)
            run                  = sB
            local want           = A.down
            if inGate then
                local up  = A.down * -1.0
                local fwd = A.side:cross(up)
                if fwd:dot(B.top[1] - A.top[1]) < 0 then fwd = fwd * -1.0 end
                local e = at(B, 1, dB) - at(A, 1, dA)
                local a = e:dot(fwd)
                local b = e:dot(up)
                local n = fwd * b - up * a
                if n:length() > 1e-9 then want = n end
            end
            for c = 1, nc - 1 do
                if (keepBottom or inGate) and A.bot[c] and A.bot[c + 1] and B.bot[c] and B.bot[c + 1] then
                    local ua1, va1 = curbBottomUV(A.cols[c].uvx, sA)
                    local ua2, va2 = curbBottomUV(A.cols[c + 1].uvx, sA)
                    local ub2, vb2 = curbBottomUV(B.cols[c + 1].uvx, sB)
                    local ub1, vb1 = curbBottomUV(B.cols[c].uvx, sB)
                    pushQuad(smCurb, at(A, c, dA), at(A, c + 1, dA), at(B, c + 1, dB), at(B, c, dB),
                             {ua1, va1}, {ua2, va2}, {ub2, vb2}, {ub1, vb1}, want)
                end
            end
        end
        if gateAt then
            local function sillSeg(k)
                local gA, gB = gateAt[k], gateAt[k + 1]
                return gA and gB and gA.sill and gB.sill and (gA.open or gB.open)
                       and stations[k].bot[1] and stations[k + 1].bot[1] and true or false
            end
            local function straight(a, b)
                for m = a + 1, b - 1 do
                    local t = (stations[m].s - stations[a].s) / math.max(1e-9, stations[b].s - stations[a].s)
                    for _, c in ipairs({1, nc}) do
                        for _, key in ipairs({"sill", "floor"}) do
                            local pa = at(stations[a], c, gateAt[a][key])
                            local pb = at(stations[b], c, gateAt[b][key])
                            local pm = at(stations[m], c, gateAt[m][key])
                            if (pa + (pb - pa) * t - pm):length() > 1e-3 then return false end
                        end
                    end
                end
                return true
            end
            local k = 1
            while k < np do
                if sillSeg(k) then
                    local e = k + 1
                    while e < np and sillSeg(e) and straight(k, e + 1) do e = e + 1 end
                    local A, B   = stations[k], stations[e]
                    local gA, gB = gateAt[k], gateAt[e]
                    local sA, sB = A.s, B.s
                    for c = 1, nc - 1 do
                        if A.bot[c + 1] and B.bot[c + 1] then
                            local ua1, va1 = curbBottomUV(A.cols[c].uvx, sA)
                            local ua2, va2 = curbBottomUV(A.cols[c + 1].uvx, sA)
                            local ub2, vb2 = curbBottomUV(B.cols[c + 1].uvx, sB)
                            local ub1, vb1 = curbBottomUV(B.cols[c].uvx, sB)
                            pushQuad(smCurb, at(A, c, gA.sill), at(A, c + 1, gA.sill), at(B, c + 1, gB.sill), at(B, c, gB.sill),
                                     {ua1, va1}, {ua2, va2}, {ub2, vb2}, {ub1, vb1}, A.down * -1.0)
                            if keepBottom then
                                pushQuad(smCurb, at(A, c, gA.floor), at(A, c + 1, gA.floor), at(B, c + 1, gB.floor), at(B, c, gB.floor),
                                         {ua1, va1}, {ua2, va2}, {ub2, vb2}, {ub1, vb1}, A.down)
                            end
                        end
                    end
                    for _, c in ipairs({1, nc}) do
                        local outward = A.side * ((c == 1) and -1 or 1)
                        pushWall(smCurb, at(A, c, gA.sill), at(A, c, gA.floor), at(B, c, gB.floor), at(B, c, gB.sill),
                                 {curbU(sA), curbFaceV(gA.sill)},
                                 {curbU(sA), curbFaceV(gA.floor)},
                                 {curbU(sB), curbFaceV(gB.floor)},
                                 {curbU(sB), curbFaceV(gB.sill)},
                                 outward)
                    end
                    k = e
                else
                    k = k + 1
                end
            end
        end
    end

    if isMesh and meshRoad.endCaps and not isClosed then
        local roleIdx = {}
        for k = 1, nc do
            if cols0[k].role then roleIdx[cols0[k].role] = k end
        end
        local defs = {
            {"outer_near", "inner_near", true},
            {"inner_near", "inner_far", false},
            {"inner_far", "outer_far", true},
        }
        if framed then
            local mid = {"inner_near"}
            for k = 1, nc do
                local r = cols0[k].role
                if r and r:sub(1, 5) == "walk_" then mid[#mid + 1] = r end
            end
            mid[#mid + 1] = "inner_far"
            for _, endSpec in ipairs({{1, -1.0}, {np, 1.0}}) do
                local idx, sign = endSpec[1], endSpec[2]
                local st        = stations[idx]
                local drop, hgt = st.chamfer, st.height
                local want      = tangents[idx] * sign
                for _, d in ipairs(winEnds[idx] and {} or defs) do
                    local roleA, roleB, outerSide = d[1], d[2], d[3]
                    local ring                    = {{roleA, false}}
                    if outerSide then
                        ring[#ring + 1] = {roleA, true}
                        if drop > 1e-6 then
                            local outerRole = (roleA == "outer_near" or roleA == "outer_far") and roleA or roleB
                            ring[#ring + 1] = {outerRole .. "_chamfer", true}
                        end
                        ring[#ring + 1] = {roleB, true}
                    else
                        for _, r in ipairs(mid) do ring[#ring + 1] = {r, true} end
                    end
                    ring[#ring + 1] = {roleB, false}
                    local pts, okRing = {}, true
                    for _, e in ipairs(ring) do
                        local ci = roleIdx[e[1]]
                        local v  = ci and (e[2] and st.top[ci] or st.bot[ci]) or nil
                        if not v then okRing = false break end
                        pts[#pts + 1] = {v = v, uv = mr.capCurbUV(st.cols[ci].uvx, 0.0, e[2] and -drop or -hgt),
                                         bottom = not e[2], ci = ci}
                    end
                    if okRing then
                        mr.pushCapRing(smCurb, st, pts, function(ci, bottom)
                            return mr.capCurbUV(st.cols[ci].uvx, 0.0, bottom and -hgt or -drop)
                        end, want)
                    end
                end
            end
            defs = {}
        end
        for _, endSpec in ipairs({{1, -1.0}, {np, 1.0}}) do
            local idx, sign = endSpec[1], endSpec[2]
            local st        = stations[idx]
            local edgeDist  = st.s
            local hgt       = st.height
            local hasCh     = st.chamfer > 1e-6
            local want      = tangents[idx] * sign
            for _, d in ipairs(winEnds[idx] and {} or defs) do
                local roleA, roleB, outerSide = d[1], d[2], d[3]
                local sm                      = outerSide and smCurb or smWalk
                local outerRole               = (roleA == "outer_near" or roleA == "outer_far") and roleA or roleB
                local ring
                if hasCh and outerSide and roleIdx[outerRole .. "_chamfer"] then
                    local ch = outerRole .. "_chamfer"
                    if roleA == outerRole then
                        ring = {{roleB, -hgt}, {roleB, 0.0}, {ch, 0.0},
                                {roleA, -st.chamfer}, {roleA, -hgt}}
                    else
                        ring = {{roleB, -hgt}, {roleB, -st.chamfer}, {ch, 0.0},
                                {roleA, 0.0}, {roleA, -hgt}}
                    end
                else
                    if sign < 0 then
                        ring = {{roleB, -hgt}, {roleB, 0.0}, {roleA, 0.0}, {roleA, -hgt}}
                    else
                        ring = {{roleA, -hgt}, {roleA, 0.0}, {roleB, 0.0}, {roleB, -hgt}}
                    end
                end
                if #ring == 5 and sign < 0 then
                    local r = {}
                    for k = #ring, 1, -1 do r[#r + 1] = ring[k] end
                    ring = r
                end
                local function uvOf(ci, z)
                    local lx = outerSide and st.cols[ci].uvx or st.cols[ci].x
                    return outerSide and mr.capCurbUV(lx, 0.0, z) or mr.capWalkUV(edgeDist, sign, lx, 0.0, z)
                end
                local pts, okRing = {}, true
                for _, e in ipairs(ring) do
                    local ci = roleIdx[e[1]]
                    local v  = ci and ((e[2] == -hgt) and st.bot[ci] or st.top[ci]) or nil
                    if not v then okRing = false break end
                    pts[#pts + 1] = {v = v, uv = uvOf(ci, e[2]), bottom = (e[2] == -hgt), ci = ci}
                end
                if okRing then
                    mr.pushCapRing(sm, st, pts, function(ci, bottom)
                        return uvOf(ci, bottom and -hgt or -(st.cols[ci].drop or 0.0))
                    end, want)
                end
            end
        end
    end

    if isMesh and not isClosed then
        for _, f in ipairs(features) do
            if spl[f.key] == true then
                f.build(stations, dists, tangents, smCurb, np, M.featureDims(f, spl[f.key .. "Dims"]))
            end
        end
    end


    local out = {}
    if #smCurb.faces > 0 then out[#out + 1] = smCurb end
    if #smWalk.faces > 0 then out[#out + 1] = smWalk end
    local mats = {}
    for mat in pairs(winSubs or {}) do mats[#mats + 1] = mat end
    table.sort(mats)
    for _, mat in ipairs(mats) do
        if winSubs[mat] ~= smCurb and winSubs[mat] ~= smWalk and #winSubs[mat].faces > 0 then out[#out + 1] = winSubs[mat] end
    end
    if winPlan and winPlan.cfg.modules then
        for _, pl in ipairs(winPlan.placed or {}) do
            local m = pl.row.dae and Modules.model(pl.row.dae)
            if m then
                for _, sm in ipairs(Modules.place(m, pl.origin, pl.inward)) do out[#out + 1] = sm end
            end
        end
    end
    if #out == 0 then return nil end
    return out, nil, note
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.buildRoadMesh    = buildRoadMesh
M.curbFaceV        = curbFaceV
M.curbMaterialName = curbMaterialName
M.curbTopV         = curbTopV
M.curbU            = curbU
M.emitFace         = emitFace
M.loadStyles       = loadStyles
M.mrState          = mrState
M.newSubmesh       = newSubmesh
M.pushNormal       = pushNormal
M.pushQuad         = pushQuad
M.pushTri          = pushTri
M.pushUV           = pushUV
M.pushVert         = pushVert
M.pushWall         = pushWall
M.resolveStyle     = resolveStyle
M.smoothPath       = smoothPath
M.terrainZ         = terrainZ
M.walkMaterialName = walkMaterialName
M.mr               = mr
M.mrState          = mrState
M.features         = features

M.styleFile        = styleFile
M.getStyleCfg      = function() return styleCfg end
M.getStyleErr      = function() return styleErr end
M.setStyleKeys     = function(curb, walk) curbKey, walkKey = curb, walk end
M.featureOverrides = function(f, raw)
    if type(raw) == "string" and raw ~= "" then
        local ok, v = pcall(jsonDecode, raw)
        raw         = ok and v or nil
    end
    if type(raw) ~= "table" then return nil end
    local out, any = {}, false
    for _, fd in ipairs(f.fields or {}) do
        local v = raw[fd.key]
        if type(v) == "number" then
            out[fd.key] = clamp(v, fd.min, fd.max)
            any         = true
        end
    end
    return any and out or nil
end
M.featureDims = function(f, over)
    local out = {}
    if f.defaults then
        for k, v in pairs(f.defaults()) do out[k] = v end
    end
    for k, v in pairs(M.featureOverrides(f, over) or {}) do out[k] = v end
    return out
end
M.registerFeature = function(f)
    for i, g in ipairs(features) do
        if g.key == f.key then features[i] = f return end
    end
    features[#features + 1] = f
end

return M
