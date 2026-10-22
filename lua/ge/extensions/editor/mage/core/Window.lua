-- =============================================================================
-- MaGE - MeshRoad windows
-- Version: 1.0.2
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local Gate    = require("editor/mage/core/Gate")
local Modules = require("editor/mage/core/Modules")

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local styles   = {"round", "quarter", "rect", "pointed"}
local faceKeys = {"right", "left", "start", "end"}

local limits = {
    depth    = {0.01, 1000.0, 0.3},
    margin   = {0.0,  20.0,   0.2},
    floorGap = {0.0,  50.0,   1.9},
    width    = {0.1,  50.0,   1.2},
    gap      = {0.0,  50.0,   0.5},
    height   = {0.1,  50.0,   1.3},
    sill     = {0.05, 1000.0, 1.0},
    sink     = {0.0,  2.0,    0.0},
}

local modKeys = {"windows", "doors", "balcony", "stairs", "pillar", "corner", "pilaster", "plinth", "course", "roofborder", "roof", "gutter", "ac", "dish",
                 "awning", "flowers", "pots", "roofac", "roofdish", "corbel", "pipe"}

local modLimits = {
    every   = {1, 8, 2},
    lift    = {-3.0, 3.0, 0.0},
    space   = {0.5, 50.0, 3.0},
    margin  = {0.0, 20.0, 0.5},
    split   = {0, 8, 0},
    pitch   = {5.0, 60.0, 30.0},
    over    = {0.0, 2.0, 0.3},
    depth   = {0.5, 100.0, 3.0},
    tex     = {0.25, 10.0, 1.0},
    out     = {-2.0, 5.0, 0.0},
    size    = {0.25, 4.0, 1.0},
    thick   = {0.02, 1.0, 0.12},
    capW    = {0.02, 2.0, 0.14},
    capH    = {0.02, 2.0, 0.09},
    gable   = {0.0, 2.0, 0.3},
    ridge   = {-0.45, 0.45, 0.0},
    wide    = {0.0, 20.0, 0.0},
    step    = {0.3, 20.0, 1.5},
    count   = {1, 20, 1},
    from    = {0.0, 100.0, 0.0},
    to      = {0.0, 100.0, 0.0},
    deep    = {0.0, 5.0, 0.0},
    tall    = {0.0, 5.0, 0.0},
    grate   = {0.0, 20.0, 1.5},
    taperA  = {0.0, 20.0, 0.0},
    taperB  = {0.0, 20.0, 0.0},
    bulge   = {0.0, 1.0, 0.0},
    flatten = {0.0, 1.0, 0.0},
    peak    = {-0.9, 0.9, 0.0},
}

local moreKeys = {"lift", "from", "to", "count", "space", "deep", "tall", "wide", "grate", "taperA", "taperB", "bulge", "flatten", "peak"}
local ownKeys  = {"lift", "from", "to", "deep", "tall", "wide", "grate", "out", "taperA", "taperB", "bulge", "flatten", "peak"}
local ownSides = {"top", "side", "bottom"}
local moreMax  = 8

local roofShapes = {"gable", "hip", "shed"}

local roles = {
    balcony    = function(r) return not r.ground end,
    plinth     = function(r) return r.ground end,
    course     = function(r) return not r.ground end,
    roofborder = function(r) return r.roof end,
    roof       = function(r) return r.roof end,
    gutter     = function(r) return r.roof end,
    dish       = function(r) return r.roof end,
    pots       = function(r) return r.roof end,
    roofac     = function(r) return r.roof end,
    roofdish   = function(r) return r.roof end,
    pipe       = function(r) return r.roof end,
}

local floorKeys   = {"width", "gap", "height", "sill"}
local optKeys     = {rise = {0.05, 50.0}, lead = {0.0, 1000.0}, tail = {0.0, 1000.0}, count = {1, 200}, depth = {0.01, 1000.0}}
local aligns      = {start = true, ["end"] = true}
local globalKeys  = {"depth", "margin", "floorGap", "sink"}
local clearance   = 0.02
local endShare    = 0.45
local arcTol      = 0.05
local arcMinSteps = 8
local arcMaxDepth = 6
local snapTol     = 1e-4
local minJamb     = 0.01
local topClear    = 0.2
local doorGap     = 0.1
local trackStep   = 0.05
local backGap     = 0.05
local nicheBack   = 0.05
local kinds       = {through = true, niche = true}
local backs       = {wall = true, hall = true, open = true}
local moveLimit   = {s = 50.0, z = 10.0, v = 50.0}
local moveDims    = {w = {0.1, 50.0}, h = {0.1, 50.0}, rise = {0.05, 50.0}, depth = {0.01, 1000.0}}
local slotFaces   = {right = true, left = true, start = true, ["end"] = true, both = true, top = true}
local pinMax      = 64

-- =============================================================================
-- STATE
-- =============================================================================

local parsed    = {map = {}, n = 0}
local parsedMax = 256
local reports   = {}

-- =============================================================================
-- DATA
-- =============================================================================

local function isStyle(s)
    for _, k in ipairs(styles) do
        if k == s then return true end
    end
    return false
end

local function num(v, key)
    local l = limits[key]
    local n = tonumber(v) or l[3]
    return math.max(l[1], math.min(l[2], n))
end

local function isFace(s)
    for _, k in ipairs(faceKeys) do
        if k == s then return true end
    end
    return false
end

local function cleanMoves(src)
    if type(src) ~= "table" then return nil end
    local out = nil
    for key, mv in pairs(src) do
        local face = type(key) == "string" and key:match("^(%a+)|%d+$")
        if face and slotFaces[face] and type(mv) == "table" then
            local o = {}
            for k, l in pairs(moveLimit) do
                local v = tonumber(mv[k])
                if v and v == v and v ~= 0 then o[k] = math.max(-l, math.min(l, v)) end
            end
            if mv.off == true then o.off = true end
            if mv.off == true and mv.stay == true then o.stay = true end
            if type(mv.dae) == "string" and mv.dae ~= "" then o.dae = mv.dae end
            for k, l in pairs(moveDims) do
                local v = tonumber(mv[k])
                if v and v == v then o[k] = math.max(l[1], math.min(l[2], v)) end
            end
            if isStyle(mv.style) then o.style = mv.style end
            if mv.dir == "right" or mv.dir == "left" then o.dir = mv.dir end
            if type(mv.tex) == "string" and mv.tex ~= "" then o.tex = mv.tex end
            if backs[mv.back] then o.back = mv.back end
            if next(o) then
                out      = out or {}
                out[key] = o
            end
        end
    end
    return out
end

local function cleanFloor(f)
    if type(f) ~= "table" or not isStyle(f.style) then return nil end
    local out = {style = f.style, dir = (f.dir == "right") and "right" or "left"}
    for _, k in ipairs(floorKeys) do out[k] = num(f[k], k) end
    if type(f.wall) == "string" and f.wall ~= "" then out.wall = f.wall end
    if type(f.dae) == "string" and f.dae ~= "" then out.dae = f.dae end
    if isFace(f.face) then out.face = f.face end
    if tonumber(f.at) then out.at = math.max(0.0, math.min(1.0, tonumber(f.at))) end
    if kinds[f.kind] then out.kind = f.kind end
    if out.at and backs[f.back] then out.back = f.back end
    for k, l in pairs(optKeys) do
        local v = tonumber(f[k])
        if v then out[k] = math.max(l[1], math.min(l[2], v)) end
    end
    if out.count then out.count = math.floor(out.count + 0.5) end
    if out.style == "rect" then out.rise = nil end
    if aligns[f.align] then out.align = f.align end
    out.moves = cleanMoves(f.moves)
    return out
end

local function newMod()
    return {on = false, faces = {}}
end

local function cleanMod(m)
    local out = newMod()
    if type(m) ~= "table" then return out end
    out.on = m.on == true
    if type(m.dae) == "string" and m.dae ~= "" then out.dae = m.dae end
    if m.snap == false then out.snap = false end
    if type(m.mat) == "string" and m.mat ~= "" then out.mat = m.mat end
    for _, k in ipairs(roofShapes) do
        if m.shape == k then out.shape = k end
    end
    if isFace(m.part) then out.part = m.part end
    if m.high == "right" or m.high == "left" then out.high = m.high end
    if m.cap == true then out.cap = true end
    if m.turn == true then out.turn = true end
    if m.skin == true then out.skin = true end
    if m.sides == true then out.sides = true end
    if m.bay == "arc" then out.bay = "arc" end
    for _, k in ipairs({"top", "bottom", "side"}) do
        if type(m[k]) == "string" and m[k] ~= "" then out[k] = m[k] end
    end
    for k, l in pairs(modLimits) do
        local v = tonumber(m[k])
        if v then out[k] = math.max(l[1], math.min(l[2], v)) end
    end
    if type(m.faces) == "table" then
        for _, k in ipairs(faceKeys) do
            if type(m.faces[k]) == "boolean" then out.faces[k] = m.faces[k] end
        end
    end
    if type(m.drop) == "table" then
        for key, v in pairs(m.drop) do
            if v == true and type(key) == "string" and key:match("^%a+|%d+$") then
                out.drop      = out.drop or {}
                out.drop[key] = true
            end
        end
    end
    out.moves = cleanMoves(m.moves)
    if type(m.own) == "table" then
        for slot, e in pairs(m.own) do
            local face = type(slot) == "string" and slot:match("^(%a+)|%d+$")
            if face and slotFaces[face] and type(e) == "table" then
                local o = {}
                for _, k in ipairs(ownKeys) do
                    local v = tonumber(e[k])
                    if v then o[k] = math.max(modLimits[k][1], math.min(modLimits[k][2], v)) end
                end
                if type(e.dae) == "string" and e.dae ~= "" then o.dae = e.dae end
                if e.bay == "arc" or e.bay == "rect" then o.bay = e.bay end
                if type(e.sides) == "boolean" then o.sides = e.sides end
                for _, k in ipairs(ownSides) do
                    if type(e[k]) == "string" and e[k] ~= "" then o[k] = e[k] end
                end
                if next(o) then
                    out.own       = out.own or {}
                    out.own[slot] = o
                end
            end
        end
    end
    if type(m.more) == "table" then
        for _, e in ipairs(m.more) do
            if type(e) == "table" and #(out.more or {}) < moreMax then
                local o = {}
                for _, k in ipairs(moreKeys) do
                    local v = tonumber(e[k])
                    if v then o[k] = math.max(modLimits[k][1], math.min(modLimits[k][2], v)) end
                end
                if type(e.dae) == "string" and e.dae ~= "" then o.dae = e.dae end
                if e.bay == "arc" then o.bay = "arc" end
                out.more              = out.more or {}
                out.more[#out.more + 1] = o
            end
        end
    end
    if type(m.pins) == "table" then
        for _, pin in ipairs(m.pins) do
            local ok      = type(pin) == "table"
            local u, v, z = ok and tonumber(pin.u), ok and tonumber(pin.v), ok and tonumber(pin.z)
            if u and v and z and u == u and v == v and z == z and #(out.pins or {}) < pinMax then
                local from              = type(pin.from) == "string" and pin.from:match("^%a+|%d+$") and pin.from or nil
                out.pins                = out.pins or {}
                local lift = type(pin.own) == "table" and tonumber(pin.own.lift)
                out.pins[#out.pins + 1] = {u = u, v = v, z = z, from = from, dae = (type(pin.dae) == "string" and pin.dae ~= "") and pin.dae or nil,
                                           own = (lift and lift == lift) and {lift = math.max(modLimits.lift[1], math.min(modLimits.lift[2], lift))} or nil}
            end
        end
    end
    return out
end

local function cleanMods(data)
    local src = type(data.mods) == "table" and data.mods or {}
    local out = {}
    for _, k in ipairs(modKeys) do out[k] = cleanMod(src[k]) end
    if data.modules == true and type(data.mods) ~= "table" then out.windows.on, out.doors.on = true, true end
    return out
end

local function anyMod(mods)
    for _, k in ipairs(modKeys) do
        local m = mods[k]
        if k ~= "windows" and k ~= "doors" then
            if m.on then return true end
            for _, f in ipairs(faceKeys) do
                if m.faces[f] then return true end
            end
        end
    end
    return false
end

local function modOf(cfg, key)
    local m = cfg and cfg.mods and cfg.mods[key]
    if not m then return nil end
    if m.on then return m end
    for _, f in ipairs(faceKeys) do
        if m.faces[f] then return m end
    end
    return nil
end

local function modAt(cfg, key, face, role)
    local m = cfg and cfg.mods and cfg.mods[key]
    if not m then return false end
    local v = m.faces[face]
    if v ~= nil then return v end
    return m.on and (not roles[key] or roles[key](role or {ground = true, roof = true})) or false
end

local function modValue(m, key)
    return m[key] or modLimits[key][3]
end

local function roofOf(cfg, role)
    for _, f in ipairs(faceKeys) do
        if modAt(cfg, "roof", f, role) then return cfg.mods.roof end
    end
    return nil
end

local function clean(data)
    if type(data) ~= "table" or type(data.floors) ~= "table" then return nil end
    local floors = {}
    for _, f in ipairs(data.floors) do
        local c = cleanFloor(f)
        if c then floors[#floors + 1] = c end
    end
    local mods = cleanMods(data)
    if #floors == 0 and not anyMod(mods) then return nil end
    local faces = type(data.faces) == "table" and data.faces or {right = true, left = true}
    local walls = type(data.walls) == "table" and data.walls or {}
    local off   = type(data.off) == "table" and data.off or {}
    local out   = {floors = floors, faces = {}, walls = {}, off = {}}
    for _, k in ipairs(faceKeys) do
        out.faces[k] = faces[k] == true
        out.off[k]   = off[k] == true or nil
        if type(walls[k]) == "string" and walls[k] ~= "" then out.walls[k] = walls[k] end
    end
    for _, k in ipairs(globalKeys) do out[k] = num(data[k], k) end
    out.mods  = mods
    out.doors = data.doors == true
    out.plain = data.plain == true or nil
    return out
end

local function copy(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = copy(x) end
    return o
end

local function parse(str)
    if type(str) ~= "string" or str == "" then return nil end
    local hit = parsed.map[str]
    if hit == nil then
        local ok, data = pcall(jsonDecode, str)
        hit = ok and clean(data) or false
        if parsed.n >= parsedMax then parsed.map, parsed.n = {}, 0 end
        parsed.map[str], parsed.n = hit, parsed.n + 1
    end
    return hit and copy(hit) or nil
end

local function peek(str)
    if type(str) ~= "string" or str == "" then return nil end
    if parsed.map[str] == nil then parse(str) end
    return parsed.map[str] or nil
end

local function round3(v) return math.floor(v * 1000 + 0.5) / 1000 end

local function encodeMoves(moves)
    local out = nil
    for key, mv in pairs(moves or {}) do
        local m = {s = mv.s and round3(mv.s) or nil, z = mv.z and round3(mv.z) or nil, v = mv.v and round3(mv.v) or nil, off = mv.off or nil, dae = mv.dae,
                   w = mv.w and round3(mv.w) or nil, h = mv.h and round3(mv.h) or nil, rise = mv.rise and round3(mv.rise) or nil,
                   depth = mv.depth and round3(mv.depth) or nil, style = mv.style, dir = mv.dir, tex = mv.tex, back = mv.back, stay = mv.stay or nil}
        if next(m) then
            out      = out or {}
            out[key] = m
        end
    end
    return out
end

local function encodeMods(cfg)
    local out = {}
    for _, k in ipairs(modKeys) do
        local m = cfg.mods and cfg.mods[k]
        if m then
            local o    = {on = m.on or nil, dae = m.dae, snap = m.snap, mat = m.mat, shape = m.shape, part = m.part, high = m.high, cap = m.cap, turn = m.turn, skin = m.skin, sides = m.sides,
                          bay = m.bay, top = m.top, bottom = m.bottom, side = m.side,
                          drop = (m.drop and next(m.drop)) and m.drop or nil, moves = encodeMoves(m.moves)}
            local keep = m.on or m.dae ~= nil or m.snap == false or m.mat ~= nil or m.shape ~= nil or m.part ~= nil or m.high ~= nil or m.cap or m.turn or m.skin or m.sides or m.bay or m.top or m.bottom or m.side or o.drop
                         or o.moves
            if m.pins and #m.pins > 0 then
                o.pins = {}
                for i, pin in ipairs(m.pins) do
                    local lift = pin.own and pin.own.lift
                    o.pins[i]  = {u = round3(pin.u), v = round3(pin.v), z = round3(pin.z), from = pin.from, dae = pin.dae, own = lift and {lift = round3(lift)} or nil}
                end
                keep = true
            end
            for key in pairs(modLimits) do
                if m[key] then o[key], keep = round3(m[key]), true end
            end
            if m.own and next(m.own) then
                o.own = {}
                for slot, e in pairs(m.own) do
                    local q = {dae = e.dae, bay = e.bay, sides = e.sides, top = e.top, side = e.side, bottom = e.bottom}
                    for _, key in ipairs(ownKeys) do q[key] = e[key] and round3(e[key]) or nil end
                    o.own[slot] = q
                end
                keep = true
            end
            if m.more and #m.more > 0 then
                o.more = {}
                for i, e in ipairs(m.more) do
                    local q = {dae = e.dae, bay = e.bay}
                    for _, key in ipairs(moreKeys) do q[key] = e[key] and round3(e[key]) or nil end
                    o.more[i] = q
                end
                keep = true
            end
            for _, f in ipairs(faceKeys) do
                if m.faces and m.faces[f] ~= nil then
                    o.faces    = o.faces or {}
                    o.faces[f] = m.faces[f]
                    keep       = true
                end
            end
            if keep then out[k] = o end
        end
    end
    return next(out) and out or nil
end

local function encode(cfg)
    if not cfg or not cfg.floors then return "" end
    if #cfg.floors == 0 and not (cfg.mods and anyMod(cleanMods(cfg))) then return "" end
    local floors = {}
    for _, f in ipairs(cfg.floors) do
        local o = {style = f.style, dir = (f.style == "quarter") and f.dir or nil, wall = f.wall, dae = f.dae, face = f.face,
                   at = f.at and round3(f.at) or nil, kind = f.kind, align = f.align, count = f.count, back = f.back}
        for _, k in ipairs(floorKeys) do o[k] = round3(f[k]) end
        for _, k in ipairs({"rise", "lead", "tail", "depth"}) do o[k] = f[k] and round3(f[k]) or nil end
        if f.style == "rect" then o.rise = nil end
        o.moves = encodeMoves(f.moves)
        floors[#floors + 1] = o
    end
    local faces, walls, off = {}, {}, {}
    for _, k in ipairs(faceKeys) do
        faces[k] = cfg.faces[k] == true
        walls[k] = cfg.walls and cfg.walls[k] or nil
        off[k]   = cfg.off and cfg.off[k] or nil
    end
    local out = {floors = floors, faces = faces, walls = next(walls) and walls or nil, off = next(off) and off or nil,
                 mods = encodeMods(cfg), doors = cfg.doors or nil, plain = cfg.plain or nil}
    for _, k in ipairs(globalKeys) do out[k] = round3(cfg[k]) end
    return jsonEncode(out)
end

local function fits(fl, wallHeight)
    return fl.sill + fl.height <= wallHeight - topClear
end

local function lowers(fl, wallHeight)
    return not fits(fl, wallHeight) and fl.height <= wallHeight - topClear
end

local function room(h, wallHeight)
    return wallHeight - topClear - h
end

local function above(fl, gap)
    local f = {}
    for k, v in pairs(fl) do f[k] = v end
    f.sill = fl.sill + fl.height + gap
    return f
end

local function below(fl, gap)
    local f = {}
    for k, v in pairs(fl) do f[k] = v end
    f.sill = fl.sill - gap - fl.height
    if f.sill < limits.sill[1] then return nil end
    return f
end

local function newFloor(style, dir)
    local f = {style = style, dir = dir or "left"}
    for _, k in ipairs(floorKeys) do f[k] = limits[k][3] end
    return f
end

local function newMods()
    local out = {}
    for _, k in ipairs(modKeys) do out[k] = newMod() end
    return out
end

local function newConfig(style, dir)
    local cfg = {floors = {newFloor(style, dir)}, faces = {right = true, left = true, start = false, ["end"] = false}, walls = {}, off = {},
                 mods = newMods()}
    for _, k in ipairs(globalKeys) do cfg[k] = limits[k][3] end
    return cfg
end

-- =============================================================================
-- LAYOUT
-- =============================================================================

local function slotKey(slots, fi, face)
    local id  = fi .. "|" .. face
    slots[id] = (slots[id] or 0) + 1
    return face .. "|" .. slots[id]
end

local function liftOf(fl, mv)
    return mv and mv.z and math.max(mv.z, limits.sill[1] - fl.sill) or 0.0
end

local function rowRange(fl, a, b, margin)
    return a + (fl.lead or margin), b - (fl.tail or margin)
end

local function rowSpans(fl, u0, u1)
    if fl.at then
        local w = math.min(fl.width, u1 - u0)
        if w < fl.width * 0.5 then return {} end
        local c = u0 + w / 2.0 + (u1 - u0 - w) * fl.at
        return {{c - w / 2.0 - u0, c + w / 2.0 - u0}}
    end
    local avail = u1 - u0
    local gap   = fl.gap
    local n     = math.floor((avail + gap) / (fl.width + gap) + 1e-9)
    if fl.count then
        n   = math.min(fl.count, math.floor(avail / fl.width + 1e-9))
        gap = (n > 1) and (avail - n * fl.width) / (n - 1) or 0.0
    end
    if n < 1 then return {} end
    local used = n * fl.width + (n - 1) * gap
    local off  = (avail - used) / 2.0
    if fl.count and n > 1 then
        off = 0.0
    elseif fl.align == "start" then
        off = 0.0
    elseif fl.align == "end" then
        off = avail - used
    end
    local out = {}
    for k = 1, n do
        local a = off + (k - 1) * (fl.width + gap)
        out[k]  = {a, a + fl.width}
    end
    return out
end

local function hiAt(win, u)
    local half = win.view.width / 2.0
    local d    = math.max(-half, math.min(half, u - win.c))
    local z    = Gate.openingZ(win.view, d) or win.lo
    return math.max(z, win.lo + minJamb)
end

local function rowSize(fl)
    if fl.at and fl.dae then
        local nw, nh = Modules.size(fl.dae)
        if nw and math.abs(nw - fl.width) < 1e-6 and math.abs(nh - fl.height) < 1e-6 then return Modules.hole(fl.dae) end
    end
    return fl.width, fl.height
end

local function newWin(a, b, lo, fl, idx, own)
    local w, h  = nil, nil
    local style = fl.style
    if own and own.dae then w, h = Modules.hole(own.dae) end
    if w then style = "rect" end
    if own then w, h, style = own.w or w, own.h or h, own.style or style end
    local mine   = own ~= nil and (own.w ~= nil or own.h ~= nil or own.style ~= nil or w ~= nil)
    local rw, rh = rowSize(fl)
    if not w and rw ~= fl.width then w = rw end
    h = h or rh
    if w then a, b = (a + b) / 2.0 - w / 2.0, (a + b) / 2.0 + w / 2.0 end
    local c = (a + b) / 2.0
    return {a = a, b = b, c = c, lo = lo, floor = idx, face = fl.face, single = fl.at ~= nil, depth = own and own.depth, tex = own and own.tex,
            own  = mine or nil,
            view = {style = style, width = b - a, dir = own and own.dir or fl.dir, apex = lo + (h or fl.height), floor = lo,
                    rise = (style ~= "rect") and (own and own.rise or fl.rise) or nil}}
end

local function samples(win)
    local out = {win.a, win.b}
    if win.view.style == "rect" then return out end
    local function refine(a, b, depth)
        local m = (a + b) / 2.0
        if depth < arcMaxDepth and math.abs(hiAt(win, m) - (hiAt(win, a) + hiAt(win, b)) / 2.0) > arcTol then
            refine(a, m, depth + 1)
            out[#out + 1] = m
            refine(m, b, depth + 1)
        end
    end
    local ms = {}
    for k = 0, arcMinSteps do ms[#ms + 1] = win.a + (win.b - win.a) * k / arcMinSteps end
    ms[#ms + 1] = win.c
    table.sort(ms)
    for k = 2, #ms - 1 do out[#out + 1] = ms[k] end
    for k = 1, #ms - 1 do refine(ms[k], ms[k + 1], 0) end
    table.sort(out)
    local uniq = {}
    for _, u in ipairs(out) do
        if #uniq == 0 or u - uniq[#uniq] > snapTol then uniq[#uniq + 1] = u end
    end
    return uniq
end

local function crossings(w1, w2, grid, out)
    local function f(u, a, b) return hiAt(a, u) - b.lo end
    for _, pair in ipairs({{w1, w2}, {w2, w1}}) do
        local a, b = pair[1], pair[2]
        for k = 1, #grid - 1 do
            local x0, x1 = grid[k], grid[k + 1]
            local f0, f1 = f(x0, a, b), f(x1, a, b)
            if f0 * f1 < 0 then
                for _ = 1, 40 do
                    local m  = (x0 + x1) / 2.0
                    local fm = f(m, a, b)
                    if fm * f0 < 0 then x1 = m else x0, f0 = m, fm end
                end
                out[#out + 1] = (x0 + x1) / 2.0
            end
        end
    end
end

-- =============================================================================
-- FACE TRACKS
-- =============================================================================

local function interp(xs, ys, x)
    if x <= xs[1] then return ys[1] end
    if x > xs[#xs] then return ys[#ys] end
    local lo, hi = 1, #xs - 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if x <= xs[mid + 1] then hi = mid else lo = mid + 1 end
    end
    local d = xs[lo + 1] - xs[lo]
    local f = (d > 1e-12) and ((x - xs[lo]) / d) or 0.0
    return ys[lo] + (ys[lo + 1] - ys[lo]) * f
end

local function faceTrack(path, w, h, tan, s, sign)
    local L = s[#s]
    local n = math.max(2, math.ceil(L / trackStep))
    local t = {s = {}, x = {}, y = {}, l = {}}
    for k = 0, n do
        local at           = L * k / n
        local q, wd, _, tv = Gate.sampleAt(path, w, h, tan, s, at)
        local off          = sign * wd / 2.0
        t.s[k + 1]        = at
        t.x[k + 1]        = q.x - tv.y * off
        t.y[k + 1]        = q.y + tv.x * off
        t.l[k + 1]        = (k == 0) and 0.0
                            or t.l[k] + math.sqrt((t.x[k + 1] - t.x[k]) ^ 2 + (t.y[k + 1] - t.y[k]) ^ 2)
    end
    return t
end

local function chord(t, c, width)
    local function d(m)
        local ax, ay = interp(t.s, t.x, c - m), interp(t.s, t.y, c - m)
        local bx, by = interp(t.s, t.x, c + m), interp(t.s, t.y, c + m)
        return math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
    end
    local lo, hi = 0.0, width * 4.0
    while hi - lo > 1e-7 do
        local m = (lo + hi) / 2.0
        if d(m) < width then lo = m else hi = m end
    end
    return c - hi, c + hi
end

-- =============================================================================
-- PLAN
-- =============================================================================

local function depths(cfg)
    local back = backGap
    for _, fl in ipairs(cfg.floors) do
        local m = fl.dae and Modules.model(fl.dae)
        if m then back = math.max(back, m.hi.y + 0.02) end
    end
    local out, sink = {}, {}
    for _, f in ipairs(faceKeys) do
        local on = modAt(cfg, "windows", f)
        out[f]   = on and math.max(limits.depth[1], cfg.sink + back) or cfg.depth
        sink[f]  = on and cfg.sink or 0.0
    end
    return out, sink
end

local function miss(p, fi, why)
    p.miss     = p.miss or {}
    p.miss[fi] = p.miss[fi] or why
end

local function hit(p, fi)
    p.hit     = p.hit or {}
    p.hit[fi] = true
end

local function plan(cfg, path, w, h, tan, gateAt)
    if not cfg or #path < 2 then return path, w, h, tan, gateAt, nil end
    local s         = Gate.along(path)
    local L         = s[#s]
    local fc        = cfg.faces
    local dep, sink = depths(cfg)
    local dS        = (fc.start and not cfg.plain) and math.min(dep.start, endShare * L) or 0.0
    local dE        = (fc["end"] and not cfg.plain) and math.min(dep["end"], endShare * L) or 0.0
    local p         = {cfg = cfg, wins = {}, ghosts = {}, dS = dS, dE = dE, depth = dep, sink = sink}
    if not (fc.right or fc.left) then return path, w, h, tan, gateAt, p end

    local function blocked(a, b, face)
        for _, f in ipairs({"right", "left"}) do
            if not face or face == f then
                for _, c in ipairs(cfg.skip and cfg.skip[f] or {}) do
                    if b > c[1] and a < c[2] then return true end
                end
            end
        end
        return false
    end
    local slots = {}
    local function make(a, b, fl, fi, face, mv, own)
        if a < 0.0 or b > L or blocked(a, b, face) then return nil end
        local q, _, hd = Gate.sampleAt(path, w, h, tan, s, (a + b) / 2.0)
        local win      = newWin(a, b, q.z - hd + fl.sill + liftOf(fl, mv), fl, fi, own)
        if win.a < 0.0 or win.b > L then return nil end
        win.face   = face or win.face
        local over = 0.0
        for _, u in ipairs({a, win.c, b}) do
            local qu = Gate.sampleAt(path, w, h, tan, s, u)
            over     = math.max(over, hiAt(win, u) - (qu.z - topClear))
        end
        if over > 0.0 then
            if win.lo - over < q.z - hd - 1e-9 then return nil, "too high for the wall" end
            win.lo, win.view.apex, win.view.floor = win.lo - over, win.view.apex - over, win.view.floor - over
        end
        return win
    end
    local function hall(win, fl, mv)
        if not fl.at then return end
        local back = (mv and mv.back) or fl.back
        local open = Modules.openDoor((mv and mv.dae) or fl.dae or "")
        if back == "wall" or (not back and not (open and modAt(cfg, "doors", win.face or "right"))) then return end
        win.depth = (mv and mv.depth) or fl.depth or open or Modules.hallMin
        win.hall  = true
        win.open  = back == "open" or nil
        win.tex   = (mv and mv.tex) or ((back ~= "open") and ("@" .. Modules.darkMat)) or nil
    end
    local function add(a, b, fl, fi, face)
        local key      = slotKey(slots, fi, face or "both")
        local mv       = fl.moves and fl.moves[key]
        local win, why = nil, nil
        if mv and (mv.s or mv.z) then win = make(a + (mv.s or 0.0), b + (mv.s or 0.0), fl, fi, face, mv, mv) end
        if win then
            win.home = {a = a, b = b, fl = fl, face = face}
        else
            win, why = make(a, b, fl, fi, face, nil, mv)
        end
        if mv and mv.off then
            if win and mv.stay then
                win.slot, win.gone        = key, true
                p.ghosts[#p.ghosts + 1] = win
            end
            return
        end
        if not win then
            if why then miss(p, fi, why) end
            return
        end
        win.slot, win.dae   = key, mv and mv.dae
        hall(win, fl, mv)
        p.wins[#p.wins + 1] = win
    end
    local tracks = {}
    for fi, fl in ipairs(cfg.floors) do
        local onSide = not fl.face or fl.face == "right" or fl.face == "left"
        local function open(f) return fc[f] and (fl.at ~= nil or not cfg.off[f]) end
        local u0, u1 = rowRange(fl, dS, L - dE, cfg.margin)
        if onSide and fl.dae then
            for _, f in ipairs({"right", "left"}) do
                if open(f) and (not fl.face or fl.face == f) then
                    tracks[f]    = tracks[f] or faceTrack(path, w, h, tan, s, (f == "right") and -1 or 1)
                    local t      = tracks[f]
                    local l0, l1 = interp(t.s, t.l, u0), interp(t.s, t.l, u1)
                    for _, ab in ipairs(rowSpans(fl, l0, l1)) do
                        local a, b = chord(t, interp(t.l, t.s, l0 + (ab[1] + ab[2]) / 2.0), fl.width)
                        add(a, b, fl, fi, f)
                    end
                end
            end
        elseif onSide and (open("right") or open("left")) then
            local face = fl.face or (fc.left and not open("left") and "right") or (fc.right and not open("right") and "left") or nil
            if fl.kind == "niche" and not face then face = open("right") and "right" or "left" end
            local spans = rowSpans(fl, u0, u1)
            if #spans == 0 then miss(p, fi, "no room") end
            for _, ab in ipairs(spans) do add(u0 + ab[1], u0 + ab[2], fl, fi, face) end
        end
    end
    if #p.wins == 0 then return path, w, h, tan, gateAt, p end
    for i, win in ipairs(p.wins) do
        if win.home then
            for j, o in ipairs(p.wins) do
                if j ~= i and not (win.own or o.own) and (not win.face or not o.face or win.face == o.face) and win.a < o.b and o.a < win.b
                   and win.lo < o.view.apex and o.lo < win.view.apex then
                    local mine = win.home.fl.moves and win.home.fl.moves[win.slot]
                    local back = make(win.home.a, win.home.b, win.home.fl, win.floor, win.home.face, nil, mine)
                    if back then
                        back.slot, back.dae = win.slot, win.dae
                        p.wins[i]           = back
                        hall(back, win.home.fl, mine)
                    end
                    break
                end
            end
        end
    end

    for i, w1 in ipairs(p.wins) do
        for j = i + 1, #p.wins do
            local w2 = p.wins[j]
            if (w1.own or w2.own) and (not w1.face or not w2.face or w1.face == w2.face) and w1.a < w2.b and w2.a < w1.b
               and w1.lo < w2.view.apex and w2.lo < w1.view.apex then
                p.touch                            = p.touch or {}
                p.touch[w1.slot], p.touch[w2.slot] = true, true
            end
        end
    end

    local events = {}
    for _, win in ipairs(p.wins) do
        win.grid = samples(win)
        for _, u in ipairs(win.grid) do events[#events + 1] = u end
    end
    for i = 1, #p.wins do
        for j = i + 1, #p.wins do
            local w1, w2 = p.wins[i], p.wins[j]
            local lo, hi = math.max(w1.a, w2.a), math.min(w1.b, w2.b)
            if w1.floor ~= w2.floor and hi > lo then
                local grid = {lo, hi}
                for _, g in ipairs({w1.grid, w2.grid}) do
                    for _, u in ipairs(g) do
                        if u > lo and u < hi then grid[#grid + 1] = u end
                    end
                end
                table.sort(grid)
                crossings(w1, w2, grid, events)
            end
        end
    end
    table.sort(events)

    local np, nw, nh, nt, ng, ns = {}, {}, {}, {}, gateAt and {} or nil, {}
    local function push(q, wd, hd, tv, gi, u)
        local k = #np + 1
        np[k], nw[k], nh[k], nt[k], ns[k] = q, wd, hd, tv, u
        if ng then ng[k] = gi or false end
    end
    local e = 1
    for i = 1, #path do
        while e <= #events and events[e] < s[i] - snapTol do
            local u = events[e]
            if #ns == 0 or u - ns[#ns] > snapTol then
                local q, wd, hd, tv = Gate.sampleAt(path, w, h, tan, s, u)
                push(q, wd, hd, tv, false, u)
            end
            e = e + 1
        end
        while e <= #events and events[e] <= s[i] + snapTol do e = e + 1 end
        push(path[i], w[i], h[i], tan[i], gateAt and gateAt[i], s[i])
    end

    local function indexOf(u)
        local best, bestD = nil, math.huge
        for k, v in ipairs(ns) do
            local d = math.abs(v - u)
            if d < bestD then best, bestD = k, d end
        end
        return best
    end
    local kept = {}
    for _, win in ipairs(p.wins) do
        win.ia, win.ib = indexOf(win.a), indexOf(win.b)
        if win.ib > win.ia then kept[#kept + 1] = win end
    end
    p.wins = kept
    return np, nw, nh, nt, ng, p
end

-- =============================================================================
-- MATERIALS
-- =============================================================================

local function overrides(cfg)
    local banded = false
    for _, f in ipairs(cfg.floors) do
        if f.wall then banded = true end
    end
    local any = banded
    for _, k in ipairs(faceKeys) do
        if cfg.walls[k] then any = true end
    end
    return banded, any
end

local function bands(cfg)
    local fl = {}
    for _, f in ipairs(cfg.floors) do fl[#fl + 1] = f end
    table.sort(fl, function(a, b) return a.sill < b.sill end)
    local out, prev = {}, -math.huge
    for k = 1, #fl - 1 do
        local v = math.max(prev, (fl[k].sill + fl[k].height + fl[k + 1].sill) / 2.0)
        out[k]  = v
        prev    = v
    end
    return fl, out
end

local function lerpItem(x, y, t)
    return {p = x.p + (y.p - x.p) * t, k = x.k, a = x.a + (y.a - x.a) * t, b = x.b + (y.b - x.b) * t, r = x.r + (y.r - x.r) * t}
end

local function cut(items, level, keepAbove)
    local out, n = {}, #items
    for i = 1, n do
        local A, B = items[i], items[i % n + 1]
        local inA  = keepAbove and (A.r >= level) or (not keepAbove and A.r <= level)
        local inB  = keepAbove and (B.r >= level) or (not keepAbove and B.r <= level)
        if inA then out[#out + 1] = A end
        if inA ~= inB then
            local lo, hi = A, B
            if B.r < A.r then lo, hi = B, A end
            out[#out + 1] = lerpItem(lo, hi, (level - lo.r) / (hi.r - lo.r))
        end
    end
    return out
end

local function uvOf(U, it)
    if it.k == "c" then return U.capCurbUV(it.a, 0.0, it.b) end
    return {U.curbU(it.a), U.curbFaceV(it.b)}
end

local function put(p, ctx, face, items, want, tex)
    local function emitKey(key, its)
        if #its < 3 then return end
        ctx.withStyle(key, function()
            local vs, uvs = {}, {}
            for i, it in ipairs(its) do vs[i], uvs[i] = it.p, uvOf(ctx.uv, it) end
            ctx.emitFace(ctx.smFor(key), vs, uvs, want)
        end)
    end
    if tex then return emitKey(tex, items) end
    local faceKey = p.useOverrides and p.cfg.walls[face] or nil
    if not (p.useOverrides and p.banded) then
        emitKey(faceKey, items)
        return
    end
    local fl = p.floorsSorted
    for k = 1, #fl do
        local piece = items
        if k > 1 then piece = cut(piece, p.bounds[k - 1], true) end
        if k < #fl and #piece >= 3 then piece = cut(piece, p.bounds[k], false) end
        emitKey(fl[k].wall or faceKey, piece)
    end
end

-- =============================================================================
-- FACES
-- =============================================================================

local function horiz(v)
    local o = vec3(v.x, v.y, 0)
    if o:length() < 1e-9 then return o end
    return o:normalized()
end

local function faceP(st, c, z)
    local b, t = st.bot[c], st.top[c]
    local dz   = t.z - b.z
    local f    = (math.abs(dz) > 1e-9) and ((z - b.z) / dz) or 0.0
    return b + (t - b) * f
end

local function depthFromTop(st, c, z)
    local b, t = st.bot[c], st.top[c]
    local dz   = t.z - b.z
    local f    = (math.abs(dz) > 1e-9) and ((z - b.z) / dz) or 0.0
    return st.height + (st.chamfer - st.height) * f
end

local function zipper(A, B, emit)
    local i, j, m, n = 1, 1, #A, #B
    while i < m or j < n do
        local advA
        if i == m then
            advA = false
        elseif j == n then
            advA = true
        else
            advA = (A[i + 1].p - B[j].p):length() <= (A[i].p - B[j + 1].p):length()
        end
        if advA then
            emit(A[i], A[i + 1], B[j])
            i = i + 1
        else
            emit(A[i], B[j + 1], B[j])
            j = j + 1
        end
    end
end

local function frameOf(st, nc, i)
    local O   = st.bot[1]
    local d   = st.bot[nc] - O
    local top = math.huge
    for ci = 1, nc do top = math.min(top, st.top[ci].z - O.z) end
    return {O = O, u = horiz(d), w = vec3(d.x, d.y, 0):length(), top = top, s = st.s, i = i}
end

local function frameLerp(A, B, t)
    return {O = A.O + (B.O - A.O) * t, u = horiz(A.u + (B.u - A.u) * t), w = A.w + (B.w - A.w) * t,
            top = A.top + (B.top - A.top) * t, s = A.s + (B.s - A.s) * t}
end

local function frameAtS(F, s)
    if s <= F[1].s then return F[1] end
    if s >= F[#F].s then return F[#F] end
    local k = 1
    while k < #F - 1 and F[k + 1].s < s do k = k + 1 end
    local A, B = F[k], F[k + 1]
    if math.abs(s - A.s) < 1e-9 then return A end
    if math.abs(s - B.s) < 1e-9 then return B end
    return frameLerp(A, B, (s - A.s) / math.max(1e-9, B.s - A.s))
end

local function mapPt(fr, x, z)
    return vec3(fr.O.x + fr.u.x * x, fr.O.y + fr.u.y * x, z)
end

local function tunnelFits(t, fr)
    return t.x0 >= clearance and t.x1 <= fr.w - clearance and t.zlo >= clearance and t.ztop <= fr.top - clearance
end

local function tunnels(p, stations, ctx)
    local nc, np, cfg = ctx.nc, ctx.np, p.cfg
    local rows        = {}
    for fi, fl in ipairs(cfg.floors) do
        if fl.face == "start" or fl.face == "end" then rows[#rows + 1] = fi end
    end
    if #rows == 0 then return {} end
    if ctx.seam then
        for _, fi in ipairs(rows) do miss(p, fi, "a closed wall has no ends") end
        return {}
    end
    local F = {}
    for i = 1, np do
        if not (stations[i].bot[1] and stations[i].bot[nc]) then return {} end
        F[i] = frameOf(stations[i], nc, i)
    end
    p.frames         = F
    local sMin, sMax = F[1].s, F[np].s
    local out        = {}
    for _, fi in ipairs(rows) do
        local fl     = cfg.floors[fi]
        local from   = (fl.face == "start") and F[1] or F[np]
        local u0, u1 = rowRange(fl, 0.0, from.w, cfg.margin)
        local spans  = rowSpans(fl, u0, u1)
        if #spans == 0 then miss(p, fi, "no room") end
        for _, ab in ipairs(spans) do
            local win  = newWin(u0 + ab[1], u0 + ab[2], fl.sill, fl, fi)
            local xs   = samples(win)
            local ztop = -math.huge
            for _, x in ipairs(xs) do ztop = math.max(ztop, hiAt(win, x)) end
            local t = {fi = fi, fl = fl, key = fl.face, through = fl.kind == "through", win = win, xs = xs, x0 = win.a, x1 = win.b,
                       zlo = win.lo, ztop = ztop, top0 = hiAt(win, win.a), top1 = hiAt(win, win.b), holes = {right = {}, left = {}}}
            local D = t.through and (sMax - sMin) or math.min(fl.depth or cfg.depth, sMax - sMin)
            if fl.face == "start" then t.sa, t.sb = sMin, sMin + D else t.sa, t.sb = sMax - D, sMax end
            local why   = nil
            local order = {}
            for i = 1, np do
                if F[i].s > t.sa - 1e-9 and F[i].s < t.sb + 1e-9 then order[#order + 1] = F[i] end
            end
            if fl.face == "end" then
                local r = {}
                for k = #order, 1, -1 do r[#r + 1] = order[k] end
                order = r
            end
            local good, cut = nil, false
            for _, fr in ipairs(order) do
                if not tunnelFits(t, fr) then
                    if not good then
                        why = "no room"
                    elseif t.through then
                        why = "does not fit inside the wall along its length"
                    elseif fl.face == "start" then
                        t.sb = good.s
                    else
                        t.sa = good.s
                    end
                    cut = true
                    break
                end
                good = fr
            end
            if good and not cut and not t.through and not tunnelFits(t, frameAtS(F, (fl.face == "start") and t.sb or t.sa)) then
                if fl.face == "start" then t.sb = good.s else t.sa = good.s end
            end
            if not why and t.sb - t.sa < 0.05 then why = "no room" end
            for _, o in ipairs(out) do
                if not why and t.sa < o.sb + clearance and o.sa < t.sb + clearance and t.x0 < o.x1 + clearance and o.x0 < t.x1 + clearance
                   and t.zlo < o.ztop + clearance and o.zlo < t.ztop + clearance then
                    why = "overlaps another opening"
                end
            end
            if why then
                miss(p, fi, why)
            else
                hit(p, fi)
                out[#out + 1] = t
            end
        end
    end
    return out
end

local function tunnelHit(p, win, stations, reach)
    for _, t in ipairs(p.tun or {}) do
        local sa, sb = stations[win.ia].s, stations[win.ib].s
        if sa < t.sb + clearance and t.sa < sb + clearance then
            local F, zOver = p.frames, false
            for i = win.ia, win.ib do
                local z0 = F[i].O.z
                if win.lo < z0 + t.ztop + clearance and win.hi[i] > z0 + t.zlo - clearance then zOver = true end
            end
            local into = {}
            if zOver then
                for i = win.ia, win.ib do
                    if reach.right and reach.right(i) > t.x0 - clearance then into.right = true end
                    if reach.left and reach.left(i) > F[i].w - t.x1 - clearance then into.left = true end
                end
            end
            if into.right or into.left then
                local fits = sa >= t.sa + clearance and sb <= t.sb - clearance
                for i = win.ia, win.ib do
                    local z0 = F[i].O.z
                    if win.lo < z0 + t.zlo + clearance then fits = false end
                    if into.right and win.hi[i] > z0 + t.top0 - clearance then fits = false end
                    if into.left and win.hi[i] > z0 + t.top1 - clearance then fits = false end
                end
                return t, into, fits
            end
        end
    end
    return nil
end

local function sides(p, stations, ctx)
    if not p then return nil end
    local nc, np, cfg = ctx.nc, ctx.np, p.cfg
    local banded, any = overrides(cfg)
    local gated       = false
    for i = 1, np do
        if ctx.gateAt and ctx.gateAt[i] then gated = true end
    end
    p.useOverrides           = any and not gated
    p.banded                 = banded
    p.floorsSorted, p.bounds = bands(cfg)
    p.tun                    = cfg.plain and tunnels(p, stations, ctx) or nil
    local faceName           = {[1] = "right", [nc] = "left"}
    local function needs(c) return p.useOverrides and (banded or cfg.walls[faceName[c]] ~= nil) end
    local fR, fL = cfg.faces.right, cfg.faces.left
    local other  = {[1] = nc, [nc] = 1}

    local kept = {}
    for _, win in ipairs(p.wins) do
        local ok = win.ia > 1 and win.ib < np
        if not ok then miss(p, win.floor, "too close to the end of the wall") end
        for i = math.max(1, win.ia - 1), math.min(np, win.ib + 1) do
            if ctx.gateAt and ctx.gateAt[i] then
                if ok then miss(p, win.floor, "meets a gate") end
                ok = false
            end
        end
        local tmin = math.huge
        if ok then
            win.hi = {}
            for i = win.ia, win.ib do
                local st = stations[i]
                if not (st.bot[1] and st.bot[nc]) then ok = false break end
                tmin      = math.min(tmin, (st.bot[nc] - st.bot[1]):length())
                win.hi[i] = hiAt(win, st.s)
            end
        end
        if ok then
            local fl    = cfg.floors[win.floor]
            local kind  = fl.kind
            win.through = not win.face and (kind == "through" or (kind == nil and ((fR and p.depth.right or 0.0) + (fL and p.depth.left or 0.0)) >= tmin - 1e-9))
            win.cap     = (kind == "niche" or win.hall) and math.max(0.0, tmin - nicheBack) or nil
            win.depth   = win.depth or fl.depth
            if p.tun and #p.tun > 0 then
                local function d(f) return math.min(win.depth or p.depth[f], win.cap or math.huge) end
                local reach = {}
                if win.through then
                    reach.right = function() return math.huge end
                    reach.left  = function() return math.huge end
                else
                    if fR and win.face ~= "left" then reach.right = function() return d("right") end end
                    if fL and win.face ~= "right" then reach.left = function() return d("left") end end
                end
                local t, into, fits = tunnelHit(p, win, stations, reach)
                if t and fits then
                    win.into, win.intoSides = t, into
                elseif t then
                    miss(p, win.floor, "meets a tunnel")
                    ok = false
                end
            end
            if ok then kept[#kept + 1] = win end
        end
    end

    local parent = {}
    for k = 1, #kept do parent[k] = k end
    local function find(k)
        while parent[k] ~= k do k = parent[k] end
        return k
    end
    for a = 1, #kept do
        for b = a + 1, #kept do
            local w1, w2 = kept[a], kept[b]
            for i = math.max(w1.ia, w2.ia), math.min(w1.ib, w2.ib) do
                if w1.lo <= w2.hi[i] + 1e-9 and w2.lo <= w1.hi[i] + 1e-9 then
                    parent[find(a)] = find(b)
                    break
                end
            end
        end
    end
    local compThrough = {}
    for k, win in ipairs(kept) do
        if win.through then compThrough[find(k)] = true end
    end
    for k, win in ipairs(kept) do win.through = compThrough[find(k)] == true and not win.into end

    local function facesOf(win)
        if win.into then
            local t = {}
            if win.intoSides.right then t[#t + 1] = 1 end
            if win.intoSides.left then t[#t + 1] = nc end
            return t
        end
        if win.through then return {1, nc} end
        local t = {}
        if fR and win.face ~= "left" then t[#t + 1] = 1 end
        if fL and win.face ~= "right" then t[#t + 1] = nc end
        return t
    end
    local function topOf(win)
        local z = win.lo
        for i = win.ia, win.ib do z = math.max(z, win.hi[i]) end
        return z
    end
    local function covered(win, c)
        if win.single then return false end
        for _, d in ipairs(kept) do
            if d.single and d.face == faceName[c] and win.a < d.b + doorGap and d.a < win.b + doorGap
               and win.lo < topOf(d) and d.lo < topOf(win) then
                return true
            end
        end
        return false
    end
    local final = {}
    for _, win in ipairs(kept) do
        local ok = true
        for _, c in ipairs(facesOf(win)) do
            for i = win.ia, win.ib do
                local st = stations[i]
                if not (st.bot[c] and st.top[c]) or win.lo < st.bot[c].z + clearance or win.hi[i] > st.top[c].z - clearance then
                    ok = false
                end
            end
        end
        if not ok then miss(p, win.floor, "too high for the wall") end
        if ok then
            hit(p, win.floor)
            win.run = {[win.ia] = 0.0}
            for i = win.ia + 1, win.ib do
                local ds   = stations[i].s - stations[i - 1].s
                local dz   = win.hi[i] - win.hi[i - 1]
                win.run[i] = win.run[i - 1] + math.sqrt(ds * ds + dz * dz)
            end
            final[#final + 1] = win
        end
    end
    for _, win in ipairs(final) do
        if win.into then
            for _, side in ipairs({"right", "left"}) do
                if win.intoSides[side] then table.insert(win.into.holes[side], win) end
            end
        end
    end
    p.placed = p.placed or {}
    for _, g in ipairs(p.ghosts or {}) do
        for _, c in ipairs({1, nc}) do
            if (c == 1 and fR and g.face ~= "left") or (c == nc and fL and g.face ~= "right") then
                local k = 1
                while k < np - 1 and stations[k + 1].s < g.c do k = k + 1 end
                local A, B = stations[k], stations[k + 1]
                if A and B and A.bot[c] and B.bot[c] and A.bot[other[c]] and B.bot[other[c]] then
                    local t   = (B.s - A.s > 1e-9) and math.max(0.0, math.min(1.0, (g.c - A.s) / (B.s - A.s))) or 0.0
                    local pa  = faceP(A, c, g.lo)
                    local pb  = faceP(B, c, g.lo)
                    local inA = horiz(A.bot[other[c]] - A.bot[c])
                    local inB = horiz(B.bot[other[c]] - B.bot[c])
                    p.placed[#p.placed + 1] = {row = cfg.floors[g.floor], origin = pa + (pb - pa) * t, inward = horiz(inA + (inB - inA) * t), face = faceName[c],
                                               slot = g.slot, fi = g.floor, along = horiz(pb - pa), width = g.view.width, height = g.view.apex - g.lo, gone = true}
                end
            end
        end
    end
    if #final == 0 and not (needs(1) or needs(nc)) then return nil end

    local taken = {}
    p.placed    = p.placed or {}
    for _, c in ipairs({1, nc}) do
        local wc = {}
        for _, win in ipairs(final) do
            for _, f in ipairs(facesOf(win)) do
                if f == c and not covered(win, c) then wc[#wc + 1] = win end
            end
        end
        if #wc > 0 or needs(c) then taken[c] = {wins = wc} end
        for _, win in ipairs(wc) do
            local k = win.ia
            while k < win.ib - 1 and stations[k + 1].s < win.c do k = k + 1 end
            local A, B = stations[k], stations[k + 1]
            local t    = (B.s - A.s > 1e-9) and math.max(0.0, math.min(1.0, (win.c - A.s) / (B.s - A.s))) or 0.0
            local pa   = faceP(A, c, win.lo)
            local pb   = faceP(B, c, win.lo)
            local inA  = horiz(A.bot[other[c]] - A.bot[c])
            local inB  = horiz(B.bot[other[c]] - B.bot[c])
            p.placed[#p.placed + 1] = {row = cfg.floors[win.floor], origin = pa + (pb - pa) * t,
                                       inward = horiz(inA + (inB - inA) * t), face = faceName[c], slot = win.slot, dae = win.dae, fi = win.floor,
                                       along = horiz(pb - pa), width = win.view.width, height = win.view.apex - win.lo}
        end
    end

    local function segGroups(wc, k)
        local act = {}
        for _, win in ipairs(wc) do
            if win.ia <= k and win.ib >= k + 1 then act[#act + 1] = win end
        end
        local par = {}
        for a = 1, #act do par[a] = a end
        local function root(a)
            while par[a] ~= a do a = par[a] end
            return a
        end
        local function touch(w1, w2, i) return w1.lo <= w2.hi[i] + 1e-9 and w2.lo <= w1.hi[i] + 1e-9 end
        for a = 1, #act do
            for b = a + 1, #act do
                if touch(act[a], act[b], k) or touch(act[a], act[b], k + 1) then par[root(a)] = root(b) end
            end
        end
        local byRoot, groups = {}, {}
        for a, win in ipairs(act) do
            local r = root(a)
            local g = byRoot[r]
            if not g then
                g         = {members = {}, through = win.through, lo = {}, hi = {}, run = {}}
                byRoot[r] = g
                groups[#groups + 1] = g
            end
            if win.cap then g.cap = math.min(g.cap or math.huge, win.cap) end
            if win.depth then g.depth = math.min(g.depth or math.huge, win.depth) end
            g.tex  = g.tex or win.tex
            g.open = g.open or win.open
            if win.into then g.into = win.into end
            g.members[#g.members + 1] = win
            for _, i in ipairs({k, k + 1}) do
                g.lo[i] = math.min(g.lo[i] or math.huge, win.lo)
                if not g.hi[i] or win.hi[i] > g.hi[i] then
                    g.hi[i], g.run[i] = win.hi[i], win.run[i]
                end
            end
        end
        table.sort(groups, function(x, y) return x.lo[k] < y.lo[k] end)
        return groups
    end

    for c, t in pairs(taken) do
        t.seg = {}
        for k = 1, np - 1 do t.seg[k] = segGroups(t.wins, k) end
        t.bp = {}
        for i = 1, np do
            local st = stations[i]
            local zs = {st.bot[c].z, st.top[c].z}
            for _, k in ipairs({i - 1, i}) do
                for _, g in ipairs(t.seg[k] or {}) do
                    if g.lo[i] then
                        zs[#zs + 1] = g.lo[i]
                        zs[#zs + 1] = g.hi[i]
                    end
                end
            end
            table.sort(zs)
            local out = {}
            for _, z in ipairs(zs) do
                if #out == 0 or z - out[#out] > 1e-7 then out[#out + 1] = z end
            end
            t.bp[i] = out
        end
        t.seg[0], t.seg[np] = {}, {}
        t.segs = {}
        for k = 1, np - 1 do
            t.segs[k] = needs(c) or #t.seg[k - 1] > 0 or #t.seg[k] > 0 or #t.seg[k + 1] > 0
        end
    end

    local up = vec3(0, 0, 1)

    local function within(list, z0, z1)
        local out = {}
        for _, z in ipairs(list) do
            if z >= z0 - 1e-7 and z <= z1 + 1e-7 then out[#out + 1] = z end
        end
        return out
    end
    local function base(i) return math.min(stations[i].bot[1].z, stations[i].bot[nc].z) end
    local function across(st, c) return horiz(st.bot[other[c]] - st.bot[c]) end
    local function item(i, c, z, q, da, db)
        local st = stations[i]
        return {p = q or faceP(st, c, z), k = "f", a = st.s + (da or 0.0), b = depthFromTop(st, c, z) + (db or 0.0), r = z - base(i)}
    end
    local function innerPoint(i, c, z, g)
        local st = stations[i]
        if g.into then return mapPt(p.frames[i], (c == 1) and g.into.x0 or g.into.x1, z) end
        if g.through then return faceP(st, other[c], z) end
        return faceP(st, c, z) + across(st, c) * math.min(g.depth or p.depth[faceName[c]], g.cap or math.huge)
    end
    local function tri(c, want, tex)
        return function(a, b, d) put(p, ctx, faceName[c], {a, b, d}, want, tex) end
    end
    local function complement(groups, i, st, c)
        local out, z = {}, st.bot[c].z
        for _, g in ipairs(groups) do
            out[#out + 1] = {z, g.lo[i]}
            z             = g.hi[i]
        end
        out[#out + 1] = {z, st.top[c].z}
        return out
    end

    for c, t in pairs(taken) do
        local outward = function(st) return st.side * ((c == 1) and -1 or 1) end
        for k = 1, np - 1 do
            local A, B = stations[k], stations[k + 1]
            if t.segs[k] and A.bot[c] and B.bot[c] then
                local groups = t.seg[k]
                local sa, sb = complement(groups, k, A, c), complement(groups, k + 1, B, c)
                for n = 1, #sa do
                    local ca, cb = {}, {}
                    for _, z in ipairs(within(t.bp[k], sa[n][1], sa[n][2])) do ca[#ca + 1] = item(k, c, z) end
                    for _, z in ipairs(within(t.bp[k + 1], sb[n][1], sb[n][2])) do cb[#cb + 1] = item(k + 1, c, z) end
                    if #ca > 0 and #cb > 0 then zipper(ca, cb, tri(c, outward(A))) end
                end
                for _, g in ipairs(groups) do
                    if not g.through or c == 1 then
                        local function wallQuad(zA, zB, aA, aB, want)
                            local ia, ib = innerPoint(k, c, zA, g), innerPoint(k + 1, c, zB, g)
                            local pa, pb = faceP(A, c, zA), faceP(B, c, zB)
                            local da, db = (ia - pa):length(), (ib - pb):length()
                            local qa, qb = item(k, c, zA, pa, aA - A.s), item(k + 1, c, zB, pb, aB - B.s)
                            local ra, rb = item(k, c, zA, ia, aA - A.s, da), item(k + 1, c, zB, ib, aB - B.s, db)
                            put(p, ctx, faceName[c], {qa, qb, rb, ra}, want, g.tex)
                        end
                        wallQuad(g.lo[k], g.lo[k + 1], A.s, B.s, up)
                        wallQuad(g.hi[k], g.hi[k + 1], A.s + g.run[k], A.s + g.run[k + 1], up * -1.0)
                        if not g.through and not g.into and not g.open then
                            local ca, cb = {}, {}
                            for _, z in ipairs(within(t.bp[k], g.lo[k], g.hi[k])) do ca[#ca + 1] = item(k, c, z, innerPoint(k, c, z, g)) end
                            for _, z in ipairs(within(t.bp[k + 1], g.lo[k + 1], g.hi[k + 1])) do cb[#cb + 1] = item(k + 1, c, z, innerPoint(k + 1, c, z, g)) end
                            if #ca > 0 and #cb > 0 then zipper(ca, cb, tri(c, outward(A), g.tex)) end
                        end
                    end
                end
            end
        end

        for i = 2, np - 1 do
            local L, R = t.seg[i - 1], t.seg[i]
            if #L > 0 or #R > 0 then
                local zs = {}
                for _, set in ipairs({L, R}) do
                    for _, g in ipairs(set) do
                        zs[#zs + 1] = g.lo[i]
                        zs[#zs + 1] = g.hi[i]
                    end
                end
                table.sort(zs)
                local function inside(set, z)
                    for _, g in ipairs(set) do
                        if z > g.lo[i] and z < g.hi[i] then return g end
                    end
                    return nil
                end
                local pieces = {}
                for n = 1, #zs - 1 do
                    local za, zb = zs[n], zs[n + 1]
                    if zb - za > 1e-7 then
                        local m      = (za + zb) / 2.0
                        local gl, gr = inside(L, m), inside(R, m)
                        if (gl ~= nil) ~= (gr ~= nil) then
                            local g, sd = gl or gr, gr and 1 or -1
                            local last  = pieces[#pieces]
                            if last and last.g == g and last.side == sd and math.abs(last.z1 - za) < 1e-7 then
                                last.z1 = zb
                            else
                                pieces[#pieces + 1] = {z0 = za, z1 = zb, g = g, side = sd}
                            end
                        end
                    end
                end
                local st  = stations[i]
                local fwd = horiz(stations[i + 1].bot[c] - stations[i - 1].bot[c])
                for _, pc in ipairs(pieces) do
                    if not pc.g.through or c == 1 then
                        local ca, cb = {}, {}
                        for _, z in ipairs(within(t.bp[i], pc.z0, pc.z1)) do ca[#ca + 1] = item(i, c, z) end
                        local src = pc.g.through and taken[other[c]].bp[i] or t.bp[i]
                        for _, z in ipairs(within(src, pc.z0, pc.z1)) do
                            local ip = innerPoint(i, c, z, pc.g)
                            cb[#cb + 1] = item(i, c, z, ip, (ip - faceP(st, c, z)):length())
                        end
                        if #ca > 0 and #cb > 0 then zipper(ca, cb, tri(c, fwd * pc.side, pc.g.tex)) end
                    end
                end
            end
        end
    end

    local out = {}
    for c, t in pairs(taken) do out[c] = t.segs end
    return out
end

-- =============================================================================
-- TRIANGULATION
-- =============================================================================

local function area2(a, b, c) return (b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x) end

local function same(a, b) return math.abs(a.x - b.x) < 1e-9 and math.abs(a.z - b.z) < 1e-9 end

local function bridge(P, poly, hole)
    local m, mx, mz = 1, -math.huge, math.huge
    for k, idx in ipairs(hole) do
        local q = P[idx]
        if q.x > mx + 1e-12 or (math.abs(q.x - mx) <= 1e-12 and q.z < mz) then m, mx, mz = k, q.x, q.z end
    end
    local Mp        = P[hole[m]]
    local bestX, vk = math.huge, nil
    for k = 1, #poly do
        local a, b = P[poly[k]], P[poly[k % #poly + 1]]
        if (a.z - Mp.z) * (b.z - Mp.z) <= 0 and math.abs(a.z - b.z) > 1e-12 then
            local t = (Mp.z - a.z) / (b.z - a.z)
            local x = a.x + (b.x - a.x) * t
            if x >= Mp.x - 1e-12 and x < bestX - 1e-12 then
                bestX = x
                if math.abs(a.z - Mp.z) < 1e-9 then
                    vk = k
                elseif math.abs(b.z - Mp.z) < 1e-9 then
                    vk = k % #poly + 1
                else
                    vk = (a.x >= b.x) and k or (k % #poly + 1)
                end
            end
        end
    end
    if not vk then return nil end
    local I                    = {x = bestX, z = Mp.z}
    local V                    = P[poly[vk]]
    local bestCos, bestD, pick = -math.huge, math.huge, vk
    for k = 1, #poly do
        local R = P[poly[k]]
        if k ~= vk and not same(R, V) and not (math.abs(I.x - V.x) < 1e-12 and math.abs(I.z - V.z) < 1e-12) then
            local pv, nx = P[poly[(k - 2) % #poly + 1]], P[poly[k % #poly + 1]]
            if area2(pv, R, nx) < 0 then
                local t1, t2, t3 = area2(Mp, I, R), area2(I, V, R), area2(V, Mp, R)
                local inTri      = (t1 >= 0 and t2 >= 0 and t3 >= 0) or (t1 <= 0 and t2 <= 0 and t3 <= 0)
                if inTri then
                    local dx, dz = R.x - Mp.x, R.z - Mp.z
                    local d      = math.sqrt(dx * dx + dz * dz)
                    local cs     = (d > 1e-12) and dx / d or 1.0
                    if cs > bestCos + 1e-12 or (math.abs(cs - bestCos) <= 1e-12 and d < bestD) then
                        bestCos, bestD, pick = cs, d, k
                    end
                end
            end
        end
    end
    vk       = pick
    local V2 = P[poly[vk]]
    for k = 1, #poly do
        if same(P[poly[k]], V2) then
            local pv, nx = P[poly[(k - 2) % #poly + 1]], P[poly[k % #poly + 1]]
            local s1, s2 = area2(pv, V2, Mp), area2(V2, nx, Mp)
            local inside
            if area2(pv, V2, nx) >= 0 then inside = s1 >= 0 and s2 >= 0 else inside = s1 >= 0 or s2 >= 0 end
            if inside then
                vk = k
                break
            end
        end
    end
    local out = {}
    for k = 1, vk do out[#out + 1] = poly[k] end
    for j = 0, #hole do out[#out + 1] = hole[(m - 1 + j) % #hole + 1] end
    out[#out + 1] = poly[vk]
    for k = vk + 1, #poly do out[#out + 1] = poly[k] end
    return out
end

local function earclip(P, poly, emitTri)
    local idx = {}
    for k, v in ipairs(poly) do idx[k] = v end
    local guard = 0
    while #idx > 3 and guard < 20000 do
        guard     = guard + 1
        local n   = #idx
        local cut = false
        for k = 1, n do
            local a, b, c = idx[(k - 2) % n + 1], idx[k], idx[k % n + 1]
            local A, B, C = P[a], P[b], P[c]
            if area2(A, B, C) > 1e-12 then
                local clean = true
                for _, o in ipairs(idx) do
                    local O = P[o]
                    if o ~= a and o ~= b and o ~= c and not same(O, A) and not same(O, B) and not same(O, C)
                       and area2(A, B, O) >= -1e-12 and area2(B, C, O) >= -1e-12 and area2(C, A, O) >= -1e-12 then
                        clean = false
                        break
                    end
                end
                if clean then
                    emitTri(a, b, c)
                    table.remove(idx, k)
                    cut = true
                    break
                end
            end
        end
        if not cut then return false end
    end
    if #idx == 3 then emitTri(idx[1], idx[2], idx[3]) end
    return true
end

local function triangulate(P, outer, holes, emitTri)
    table.sort(holes, function(x, y)
        local mx, my = -math.huge, -math.huge
        for _, i in ipairs(x) do mx = math.max(mx, P[i].x) end
        for _, i in ipairs(y) do my = math.max(my, P[i].x) end
        return mx > my
    end)
    local poly = outer
    for _, h in ipairs(holes) do
        local rev = {}
        for k = #h, 1, -1 do rev[#rev + 1] = h[k] end
        poly = bridge(P, poly, rev)
        if not poly then return false end
    end
    return earclip(P, poly, emitTri)
end

-- =============================================================================
-- ENDS
-- =============================================================================

local function uvAcross(st, nc, X)
    local uvTab = {}
    for ci = 1, nc do uvTab[#uvTab + 1] = {X(st.top[ci]), st.cols[ci].uvx} end
    table.sort(uvTab, function(a, b) return a[1] < b[1] end)
    return function(x)
        if x <= uvTab[1][1] then return uvTab[1][2] end
        for k = 1, #uvTab - 1 do
            local a, b = uvTab[k], uvTab[k + 1]
            if x <= b[1] then
                local t = (b[1] - a[1] > 1e-9) and ((x - a[1]) / (b[1] - a[1])) or 0.0
                return a[2] + (b[2] - a[2]) * t
            end
        end
        return uvTab[#uvTab][2]
    end
end

local function ringOf(t)
    local R = {}
    for _, x in ipairs(t.xs) do R[#R + 1] = {x = x, z = t.zlo} end
    for k = #t.xs, 1, -1 do R[#R + 1] = {x = t.xs[k], z = hiAt(t.win, t.xs[k])} end
    local per = {0.0}
    for k = 1, #R do
        local a, b = R[k], R[k % #R + 1]
        per[k + 1] = per[k] + math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
    end
    return R, per
end

local function tube(p, ctx, t, key)
    local F      = p.frames
    local G      = {frameAtS(F, t.sa)}
    for _, fr in ipairs(F) do
        if fr.s > t.sa + 1e-6 and fr.s < t.sb - 1e-6 then G[#G + 1] = fr end
    end
    G[#G + 1]    = frameAtS(F, t.sb)
    local R, per = ringOf(t)
    local n, nx  = #R, #t.xs
    local up     = vec3(0, 0, 1)
    local function at(fr, x, z, b) return {p = mapPt(fr, x, fr.O.z + z), k = "f", a = fr.s, b = b, r = z} end
    local walls  = {[nx] = {side = "left", x = t.x1, top = t.top1, b0 = per[nx], dir = 1.0, want = -1.0},
                    [n]  = {side = "right", x = t.x0, top = t.top0, b0 = per[n] + (t.top0 - t.zlo), dir = -1.0, want = 1.0}}
    local function active(wl, A, B)
        local out = {}
        if not (A.i and B.i) then return out end
        for _, win in ipairs(t.holes[wl.side]) do
            if win.ia <= A.i and win.ib >= B.i then out[#out + 1] = win end
        end
        table.sort(out, function(x, y) return x.lo < y.lo end)
        return out
    end
    local function bpAt(wl, fr)
        local zs = {fr.O.z + t.zlo, fr.O.z + wl.top}
        if fr.i then
            for _, win in ipairs(t.holes[wl.side]) do
                if win.ia <= fr.i and win.ib >= fr.i then
                    zs[#zs + 1] = win.lo
                    zs[#zs + 1] = win.hi[fr.i]
                end
            end
        end
        table.sort(zs)
        local out = {}
        for _, z in ipairs(zs) do
            if #out == 0 or z - out[#out] > 1e-7 then out[#out + 1] = z end
        end
        return out
    end
    local function wallItem(wl, fr, z)
        local zr = z - fr.O.z
        return {p = mapPt(fr, wl.x, z), k = "f", a = fr.s, b = wl.b0 + wl.dir * (zr - t.zlo), r = zr}
    end
    for j = 1, #G - 1 do
        local A, B = G[j], G[j + 1]
        for k = 1, n do
            local wl = walls[k]
            if wl then
                local holes = active(wl, A, B)
                local function spans(fr)
                    local out, z = {}, fr.O.z + t.zlo
                    for _, win in ipairs(holes) do
                        out[#out + 1] = {z, win.lo}
                        z             = win.hi[fr.i]
                    end
                    out[#out + 1] = {z, fr.O.z + wl.top}
                    return out
                end
                local sa, sb = spans(A), spans(B)
                local pa, pb = bpAt(wl, A), bpAt(wl, B)
                local want   = A.u * wl.want
                for m = 1, #sa do
                    local ca, cb = {}, {}
                    for _, z in ipairs(pa) do
                        if z >= sa[m][1] - 1e-7 and z <= sa[m][2] + 1e-7 then ca[#ca + 1] = wallItem(wl, A, z) end
                    end
                    for _, z in ipairs(pb) do
                        if z >= sb[m][1] - 1e-7 and z <= sb[m][2] + 1e-7 then cb[#cb + 1] = wallItem(wl, B, z) end
                    end
                    if #ca > 0 and #cb > 0 then
                        zipper(ca, cb, function(a, b, d) put(p, ctx, key, {a, b, d}, want) end)
                    end
                end
            else
                local a, b   = R[k], R[k % n + 1]
                local dx, dz = b.x - a.x, b.z - a.z
                local len    = math.sqrt(dx * dx + dz * dz)
                if len > 1e-9 then
                    local want = A.u * (-dz / len) + up * (dx / len)
                    put(p, ctx, key, {at(A, a.x, a.z, per[k]), at(A, b.x, b.z, per[k + 1]), at(B, b.x, b.z, per[k + 1]), at(B, a.x, a.z, per[k])}, want)
                end
            end
        end
    end
    if t.through then return end
    local back, prev = G[#G], G[#G - 1]
    if t.key == "end" then back, prev = G[1], G[2] end
    local want = horiz(back.O - prev.O) * -1.0
    local idx  = {}
    for k = 1, n do idx[k] = k end
    earclip(R, idx, function(a, b, c)
        local q = {}
        for m, v in ipairs({a, b, c}) do q[m] = {p = mapPt(back, R[v].x, back.O.z + R[v].z), k = "f", a = R[v].x, b = R[v].z, r = R[v].z} end
        put(p, ctx, key, q, want)
    end)
end

local function plainEnd(p, stations, ctx, idx, sign)
    local key  = (idx == 1) and "start" or "end"
    local mine = {}
    for _, t in ipairs(p.tun or {}) do
        if t.key == key or t.through then mine[#mine + 1] = t end
    end
    if #mine == 0 then return false end
    local nc, st  = ctx.nc, stations[idx]
    local fr      = p.frames[idx]
    local O       = fr.O
    local want    = ctx.tangents[idx] * sign
    local roadTop = O.z + st.height
    local function X(v) return (v - O):dot(fr.u) end
    local uvx = uvAcross(st, nc, X)
    local P   = {}
    local function add(x, z, v3)
        P[#P + 1] = {x = x, z = z, v = v3 or mapPt(fr, x, z)}
        return #P
    end
    local outer = {}
    for ci = 1, nc do
        if st.bot[ci] then outer[#outer + 1] = add(X(st.bot[ci]), st.bot[ci].z, st.bot[ci]) end
    end
    for ci = nc, 1, -1 do outer[#outer + 1] = add(X(st.top[ci]), st.top[ci].z, st.top[ci]) end
    local holes = {}
    for _, t in ipairs(mine) do
        local ring = {}
        for _, q in ipairs((ringOf(t))) do ring[#ring + 1] = add(q.x, O.z + q.z) end
        holes[#holes + 1] = ring
    end
    local base = math.min(st.bot[1].z, st.bot[nc].z)
    local function citem(q) return {p = q.v, k = "c", a = uvx(q.x), b = q.z - roadTop, r = q.z - base} end
    local okTri = triangulate(P, outer, holes, function(a, b, c)
        put(p, ctx, key, {citem(P[a]), citem(P[b]), citem(P[c])}, want)
    end)
    if not okTri then return false end
    for _, t in ipairs(mine) do
        if t.key == key then tube(p, ctx, t, key) end
    end
    return true
end

local function endFace(p, stations, ctx, idx, sign)
    if not p then return false end
    if p.cfg.plain then return plainEnd(p, stations, ctx, idx, sign) end
    local key   = (idx == 1) and "start" or "end"
    local needs = p.useOverrides and (p.banded or p.cfg.walls[key] ~= nil)
    if not (p.cfg.faces[key] or needs) then return false end
    local nc, st = ctx.nc, stations[idx]
    if not (st.bot[1] and st.bot[nc]) then return false end
    local cfg = p.cfg
    local D   = (idx == 1) and p.dS or p.dE

    local O       = st.bot[1]
    local sideU   = horiz(st.bot[nc] - st.bot[1])
    local want    = ctx.tangents[idx] * sign
    local inward  = horiz(want) * -1.0
    local roadTop = O.z + st.height
    local function X(v) return (v - O):dot(sideU) end
    local xMax = X(st.bot[nc])

    local uvx  = uvAcross(st, nc, X)
    local tops = {}
    for ci = 1, nc do tops[#tops + 1] = {X(st.top[ci]), st.top[ci].z} end
    table.sort(tops, function(a, b) return a[1] < b[1] end)
    local function topZ(x)
        if x <= tops[1][1] then return tops[1][2] end
        for k = 1, #tops - 1 do
            local a, b = tops[k], tops[k + 1]
            if x <= b[1] then
                local t = (b[1] - a[1] > 1e-9) and ((x - a[1]) / (b[1] - a[1])) or 0.0
                return a[2] + (b[2] - a[2]) * t
            end
        end
        return tops[#tops][2]
    end

    local accepted = {}
    local rows     = {}
    for fi, fl in ipairs((cfg.faces[key] and D > 1e-6) and cfg.floors or {}) do
        if (not fl.face or fl.face == key) and (fl.at or not cfg.off[key]) then rows[#rows + 1] = {fi = fi, fl = fl} end
    end
    table.sort(rows, function(x, y)
        if (x.fl.at ~= nil) ~= (y.fl.at ~= nil) then return x.fl.at ~= nil end
        return x.fi < y.fi
    end)
    local function try(a, b, fl, fi, mv, own)
        local win = newWin(a, b, O.z + fl.sill + liftOf(fl, mv), fl, fi, own)
        local xs  = samples(win)
        local ok  = win.a >= clearance and win.b <= xMax - clearance and win.lo >= O.z + clearance
        local why = "no room"
        for _, c in ipairs(cfg.skip and cfg.skip[key] or {}) do
            if win.b > c[1] and win.a < c[2] then ok, win.skipped = false, true end
        end
        local over = 0.0
        for _, x in ipairs(xs) do over = math.max(over, hiAt(win, x) - (topZ(x) - clearance)) end
        if over > 0.0 and win.lo - over >= O.z + clearance then
            win.lo, win.view.apex, win.view.floor = win.lo - over, win.view.apex - over, win.view.floor - over
        end
        local top = -math.huge
        for _, x in ipairs(xs) do
            local hz = hiAt(win, x)
            top      = math.max(top, hz)
            if hz > topZ(x) - clearance then ok = false end
        end
        local near = {}
        for _, o in ipairs(accepted) do
            local g = (o.win.single and not win.single) and doorGap or 0.0
            if ok and win.a < o.win.b + g and o.win.a < win.b + g and win.lo < o.top and o.win.lo < top then
                if win.own or o.win.own then
                    near[#near + 1] = o
                else
                    ok, why = false, "overlaps another opening"
                end
            end
        end
        if ok and #near > 0 then
            win.touch = true
            for _, o in ipairs(near) do o.win.touch = true end
        end
        return ok and {win = win, xs = xs, top = top} or nil, (not ok and not win.skipped) and why or nil
    end
    local slots, ghosts = {}, {}
    for _, rw in ipairs(rows) do
        local fi, fl = rw.fi, rw.fl
        local u0, u1 = rowRange(fl, 0.0, xMax, cfg.margin)
        for _, ab in ipairs(rowSpans(fl, u0, u1)) do
            local slot = slotKey(slots, fi, key)
            local mv   = fl.moves and fl.moves[slot]
            if mv and mv.off and mv.stay then
                local g        = newWin(u0 + ab[1] + (mv.s or 0.0), u0 + ab[2] + (mv.s or 0.0), O.z + fl.sill + liftOf(fl, mv), fl, fi, mv)
                g.slot, g.gone = slot, true
                ghosts[#ghosts + 1] = {win = g}
            elseif not (mv and mv.off) then
                local a, b     = u0 + ab[1], u0 + ab[2]
                local hit, why = nil, nil
                if mv and (mv.s or mv.z) then hit = try(a + (mv.s or 0.0), b + (mv.s or 0.0), fl, fi, mv, mv) end
                if not hit then hit, why = try(a, b, fl, fi, nil, mv) end
                if why then miss(p, fi, why) end
                if hit then
                    hit.win.slot, hit.win.dae = slot, mv and mv.dae
                    accepted[#accepted + 1]   = hit
                end
                for _, acc in ipairs(accepted) do
                    if acc.win.touch and acc.win.slot then
                        p.touch               = p.touch or {}
                        p.touch[acc.win.slot] = true
                    end
                end
            end
        end
    end
    p.placed = p.placed or {}
    for _, g in ipairs(ghosts) do
        local xc = (g.win.a + g.win.b) / 2.0
        p.placed[#p.placed + 1] = {row = cfg.floors[g.win.floor], origin = vec3(O.x + sideU.x * xc, O.y + sideU.y * xc, g.win.lo),
                                   inward = inward, face = key, slot = g.win.slot, fi = g.win.floor, along = sideU,
                                   width = g.win.view.width, height = g.win.view.apex - g.win.lo, gone = true}
    end
    if #accepted == 0 and not needs then return false end

    local xs0, xs1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
    for _, a in ipairs(accepted) do
        xs0, xs1 = math.min(xs0, a.win.a), math.max(xs1, a.win.b)
        z0, z1   = math.min(z0, a.win.lo), math.max(z1, a.top)
    end
    local P0    = (st.bot[1] + st.bot[nc]) * 0.5
    local xc    = X(P0)
    local step  = (idx == 1) and 1 or -1
    local prevT = 0.0
    local i     = idx + step
    while #accepted > 0 and stations[i] do
        local si = stations[i]
        local ok = si.bot[1] and si.bot[nc] and si.top[1] and si.top[nc]
        local t  = 0.0
        if ok then
            local ci = (si.bot[1] + si.bot[nc]) * 0.5
            local e  = (ci - P0):dot(sideU)
            local hw = (si.bot[nc] - si.bot[1]):length() / 2.0
            t        = (ci - P0):dot(inward)
            ok       = t > prevT - 1e-9
                       and (xs0 - xc) - e >= -hw + clearance and (xs1 - xc) - e <= hw - clearance
                       and z0 >= math.max(si.bot[1].z, si.bot[nc].z) + clearance
                       and z1 <= math.min(si.top[1].z, si.top[nc].z) - clearance
        end
        if not ok then
            D = math.min(D, prevT)
            break
        end
        if t >= D then break end
        prevT = t
        i     = i + step
    end
    if #accepted > 0 and D <= 0.01 then
        for _, a in ipairs(accepted) do miss(p, a.win.floor, "the wall bends here") end
        if not needs then return false end
        accepted = {}
    end
    for _, a in ipairs(accepted) do hit(p, a.win.floor) end

    local P = {}
    local function add(x, z, v3)
        P[#P + 1] = {x = x, z = z, v = v3 or vec3(O.x + sideU.x * x, O.y + sideU.y * x, z)}
        return #P
    end
    local outer = {}
    for ci = 1, nc do
        if st.bot[ci] then outer[#outer + 1] = add(X(st.bot[ci]), st.bot[ci].z, st.bot[ci]) end
    end
    for ci = nc, 1, -1 do outer[#outer + 1] = add(X(st.top[ci]), st.top[ci].z, st.top[ci]) end

    p.placed = p.placed or {}
    for _, a in ipairs(accepted) do
        local xc = (a.win.a + a.win.b) / 2.0
        p.placed[#p.placed + 1] = {row = cfg.floors[a.win.floor], origin = vec3(O.x + sideU.x * xc, O.y + sideU.y * xc, a.win.lo),
                                   inward = inward, face = key, slot = a.win.slot, dae = a.win.dae, fi = a.win.floor, along = sideU,
                                   width = a.win.view.width, height = a.win.view.apex - a.win.lo}
    end

    local holes = {}
    for _, a in ipairs(accepted) do
        local ring = {}
        for _, x in ipairs(a.xs) do ring[#ring + 1] = add(x, a.win.lo) end
        for k = #a.xs, 1, -1 do ring[#ring + 1] = add(a.xs[k], hiAt(a.win, a.xs[k])) end
        holes[#holes + 1] = ring
    end

    local base = math.min(st.bot[1].z, st.bot[nc].z)
    local function citem(q, v3, da, db)
        return {p = v3 or q.v, k = "c", a = uvx(q.x) + (da or 0.0), b = q.z - roadTop - (db or 0.0), r = q.z - base}
    end
    local holeCopies = {}
    for k, h in ipairs(holes) do
        local c = {}
        for j, v in ipairs(h) do c[j] = v end
        holeCopies[k] = c
    end
    local okTri = triangulate(P, outer, holeCopies, function(a, b, c)
        put(p, ctx, key, {citem(P[a]), citem(P[b]), citem(P[c])}, want)
    end)
    if not okTri then return false end

    for _, ring in ipairs(holes) do
        local n = #ring
        for k = 1, n do
            local a, b   = P[ring[k]], P[ring[k % n + 1]]
            local dx, dz = b.x - a.x, b.z - a.z
            local len    = math.sqrt(dx * dx + dz * dz)
            if len > 1e-9 then
                local nx, nz = -dz / len, dx / len
                local nw     = sideU * nx + vec3(0, 0, nz)
                local ai, bi = a.v + inward * D, b.v + inward * D
                local flat   = math.abs(dx) >= math.abs(dz)
                local da, db = flat and 0.0 or D, flat and D or 0.0
                put(p, ctx, key, {citem(a), citem(b), citem(b, bi, da, db), citem(a, ai, da, db)}, nw)
            end
        end
        earclip(P, ring, function(a, b, c)
            put(p, ctx, key, {citem(P[a], P[a].v + inward * D), citem(P[b], P[b].v + inward * D), citem(P[c], P[c].v + inward * D)}, want)
        end)
    end
    return true
end

-- =============================================================================
-- REPORTS
-- =============================================================================

local function report(ids, p, sig)
    local r = {sig = sig, miss = {}, touch = p and p.touch or {}}
    for fi, why in pairs(p and p.miss or {}) do
        if p.cfg.plain or not (p.hit and p.hit[fi]) then r.miss[fi] = why end
    end
    for _, id in ipairs(ids) do reports[id] = r end
end

local function reportOf(id)
    return reports[id]
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.modKeys   = modKeys
M.modLimits = modLimits
M.modOf     = modOf
M.modAt     = modAt
M.modValue  = modValue
M.roofOf    = roofOf
M.newMods   = newMods
M.cleanMod  = cleanMod
M.styles    = styles
M.kinds     = kinds
M.faceKeys  = faceKeys
M.limits    = limits
M.parse     = parse
M.peek      = peek
M.encode    = encode
M.clean     = clean
M.newFloor  = newFloor
M.fits      = fits
M.lowers    = lowers
M.room      = room
M.above     = above
M.below     = below
M.newConfig = newConfig
M.plan      = plan
M.rowSize   = rowSize
M.sides     = sides
M.endFace   = endFace
M.report    = report
M.reportOf  = reportOf

return M
