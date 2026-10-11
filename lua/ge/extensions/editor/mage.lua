-- =============================================================================
-- MaGE - Map Geometry Engine
-- Version: 1.0.1
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

local preview   = require('editor/mage/modules/Preview')
local exporter  = require('editor/mage/modules/Export')
local geometry  = require('editor/mage/core/Geometry')
local common    = require('editor/mage/core/Common')
local gate      = require('editor/mage/core/Gate')
local window    = require('editor/mage/core/Window')
local roadArch  = require('editor/mage/modules/RoadArchitect')
local buildArch = require('editor/mage/modules/BuildingArchitect')
local batFix    = require('editor/mage/modules/BatFix')
local building  = require('editor/mage/modules/Building')
local modules   = require('editor/mage/core/Modules')
local settings  = require('editor/mage/config/Settings')
local ffi       = require('ffi')

for _, name in ipairs({"Bridge", "Battlement"}) do require('editor/mage/modules/' .. name) end

local lookup = common.lookup
local tr     = common.tr
local imgui  = ui_imgui

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local toolWindowName = "mage"
local configName     = geometry.styleFile
local defaultPrefix  = common.fieldPrefix

local iconOf = {
    render       = "visibility",
    clearPreview = "visibility_off",
    autoRefresh  = "autorenew",
    expand       = "tb_height",
    collapse     = "vertical_align_center",
    markSidewalk = "format_paint",
    reload       = "refresh",
    update       = "sync",
    rebuild      = "build",
    selectMesh   = "create_road_mesh",
    selectDecals = "decalRoad",
    selectAll    = "forest_select",
    scan         = "search",
    createConfig = "note_add",
    addToConfig  = "add_box",
    bottom       = "vertical_align_bottom",
    roll         = "tb_bank_right",
    ends         = "crop_free",
}

local defaultProfileStyles = {
    walk   = {label = "sidewalk",       color = {0.45, 0.60, 0.80}, weight = 2},
    island = {label = "traffic island", color = {0.75, 0.55, 0.35}, weight = 1},
}

local flagIcons = {
    bottom = iconOf.bottom,
    roll   = iconOf.roll,
    ends   = iconOf.ends,
}

local defaultFlagStyles = {
    on  = {label = "on",  color = {0.35, 0.70, 0.40}, weight = 2},
    off = {label = "off", color = {0.55, 0.55, 0.55}, weight = 1},
}

local decalAxes = {"curb", "walk", "profile"}
local mrAxes    = {"wall", "bottom", "roll", "ends"}
local allAxes   = {"curb", "walk", "profile", "wall", "bottom", "roll", "ends"}

for _, f in ipairs(geometry.features) do
    allAxes[#allAxes + 1] = f.key
end

local mirrorMap = {
    ["("] = ")", [")"] = "(",
    ["["] = "]", ["]"] = "[",
    ["{"] = "}", ["}"] = "{",
    ["<"] = ">", [">"] = "<",
}

-- =============================================================================
-- STATE
-- =============================================================================

local registered   = false
local statusText   = ""
local sectionForce = nil
local allOpen      = false
local rtlLayout    = false
local layout       = {rtlConfig = false, cache = {}, n = 0}
local rtlCache     = {}
local rtlCacheN    = 0
local visualCache  = {}
local visualCacheN = 0

local ensureRegistered

-- =============================================================================
-- TRANSLATION
-- =============================================================================

local function isLtrChar(ch)
    if #ch ~= 1 then return false end
    return ch:match("[%a%d_%.]") ~= nil
end

local isRtlText = common.isRtlText

local function utf8Split(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local b   = s:byte(i)
        local len = 1
        if b >= 0xF0 then len = 4
        elseif b >= 0xE0 then len = 3
        elseif b >= 0xC0 then len = 2 end
        out[#out + 1] = s:sub(i, i + len - 1)
        i = i + len
    end
    return out
end

local function flipToVisual(s)
    local chars = utf8Split(s)
    local count = #chars

    local rev = {}
    for i = count, 1, -1 do
        rev[#rev + 1] = chars[i]
    end

    local i = 1
    while i <= count do
        if isLtrChar(rev[i]) then
            local a = i
            while i <= count and isLtrChar(rev[i]) do i = i + 1 end
            local b = i - 1
            while a < b do
                rev[a], rev[b] = rev[b], rev[a]
                a, b = a + 1, b - 1
            end
        else
            i = i + 1
        end
    end

    for k = 1, count do
        local m = mirrorMap[rev[k]]
        if m then rev[k] = m end
    end

    return table.concat(rev)
end

local function flipLines(s)
    if not s:find("\n", 1, true) then return flipToVisual(s) end
    local out = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = flipToVisual(line)
    end
    return table.concat(out, "\n")
end

local function visual(s)
    if s == nil or s == "" then return s end
    local cached = visualCache[s]
    if cached then return cached end

    local label, idPart = s, ""
    local p             = s:find("##", 1, true)
    if p then
        label  = s:sub(1, p - 1)
        idPart = s:sub(p)
    end

    local result
    if isRtlText(label) then
        result = flipLines(label) .. idPart
    else
        result = label .. idPart
    end

    visualCacheN = visualCacheN + 1
    if visualCacheN > 512 then
        visualCache  = {}
        visualCacheN = 0
    end
    visualCache[s] = result
    return result
end

local function rtl(s)
    if s == nil or s == "" then return s end
    local cached = rtlCache[s]
    if cached then return cached end

    local label, idPart = s, ""
    local p             = s:find("##", 1, true)
    if p then
        label  = s:sub(1, p - 1)
        idPart = s:sub(p)
    end

    local result = visual(lookup(label) .. idPart)

    rtlCacheN = rtlCacheN + 1
    if rtlCacheN > 512 then
        rtlCache  = {}
        rtlCacheN = 0
    end
    rtlCache[s] = result
    return result
end

-- =============================================================================
-- DRAWING
-- =============================================================================

local function availWidth()
    return imgui.GetContentRegionAvailWidth()
end

local function alignRight(width)
    if not rtlLayout then return end
    local offset = availWidth() - width
    if offset > 0 then
        imgui.SetCursorPosX(imgui.GetCursorPosX() + offset)
    end
end

local function drawText(v, col)
    if rtlLayout then alignRight(imgui.CalcTextSize(v).x) end
    if col then
        imgui.TextColored(col, v)
    else
        imgui.TextUnformatted(v)
    end
end

function layout.lines(s, width)
    local key = s .. "\1" .. math.floor(width)
    local hit = layout.cache[key]
    if hit then return hit end
    local lines = {}
    for para in (s .. "\n"):gmatch("([^\n]*)\n") do
        local cur = ""
        for word in para:gmatch("%S+") do
            local try = (cur == "") and word or (cur .. " " .. word)
            if cur ~= "" and imgui.CalcTextSize(try).x > width then
                lines[#lines + 1] = cur
                cur               = word
            else
                cur = try
            end
        end
        lines[#lines + 1] = cur
    end
    layout.n = layout.n + 1
    if layout.n > 512 then layout.cache, layout.n = {}, 0 end
    layout.cache[key] = lines
    return lines
end

function layout.pad(v, width)
    if not rtlLayout then return v end
    local sw = imgui.CalcTextSize(" ").x
    if sw <= 0 then return v end
    local n = math.floor((width - imgui.CalcTextSize(v).x) / sw) - 1
    if n <= 0 then return v end
    return string.rep(" ", n) .. v
end

function layout.wrapped(s, col)
    for _, line in ipairs(layout.lines(s, availWidth())) do drawText(visual(line), col) end
end

local function text(s, col)
    layout.wrapped(lookup(s), col)
end

local function textv(s, col)
    layout.wrapped(s, col)
end

local function tip(s)
    if imgui.IsItemHovered() then
        imgui.SetTooltip(rtl(s))
    end
end

-- =============================================================================
-- LEVEL CONFIG
-- =============================================================================

local cfg        = nil
local cfgPath    = ""
local cfgError   = nil
local cfgMissing = false
local cfgEmpty   = false
local palette    = nil
local fieldOf    = {}

local levelDir = common.levelDir

local readJson = common.readJson

local function color4(c, alpha)
    if type(c) == "table" and #c >= 3 then
        return imgui.ImVec4(c[1], c[2], c[3], alpha or 1)
    end
    return imgui.ImVec4(0.35, 0.38, 0.45, alpha or 1)
end

local function luminance(c)
    if type(c) ~= "table" or #c < 3 then return 0.35 end
    return 0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3]
end

local function buildAxis(styles, axis)
    local out = {}
    if type(styles) ~= "table" then return out end
    for name, st in pairs(styles) do
        if type(st) == "table" then
            out[#out + 1] = {
                value      = name,
                label      = st.label or name,
                color      = st.color,
                band       = st.band,
                weight     = st.weight or 0,
                isSequence = st.sequence ~= nil,
            }
        end
    end
    table.sort(out, function(a, b)
        if a.isSequence ~= b.isSequence then return b.isSequence end
        if axis == "curb" and a.band and b.band and a.band ~= b.band then
            return a.band < b.band
        end
        if a.weight ~= b.weight then return a.weight > b.weight end
        return a.value < b.value
    end)
    return out
end

local function curbUsesAtlas()
    local name = cfg and cfg.curb and cfg.curb.material
    local mat  = name and cfg.materials and cfg.materials[name]
    return type(mat) == "table" and mat.atlas ~= nil
end

local function legacyLabel(label)
    if label == "walk centre" then return "top surface" end
    return label
end

local function loadConfigData()
    rtlCache               = {}
    rtlCacheN              = 0
    visualCache            = {}
    visualCacheN           = 0
    cfg, palette, cfgError = nil, nil, nil
    cfgMissing             = false
    cfgEmpty               = false
    fieldOf                = {}
    layout.rtlConfig       = false

    local dir = levelDir()
    if not dir then
        cfgError = "no level loaded"
        return
    end
    cfgPath = dir .. configName

    local data = readJson(cfgPath)
    if not data and not common.fileExists(cfgPath) then
        local old = readJson(dir .. common.legacyStyleFile)
        if old then
            data = old
            common.writeJson(cfgPath, old)
        end
    end
    if not data then
        cfgMissing = not FS:fileExists(cfgPath)
        cfgError   = cfgMissing and "no config in this level yet" or "file malformed"
        return
    end
    if data.version ~= 1 then
        cfgError = "version must be 1"
        return
    end

    local axes   = data.axes or {}
    local prefix = data.fieldPrefix or defaultPrefix
    for _, ax in ipairs(allAxes) do
        fieldOf[ax] = common.fieldName((axes[ax] or {}).field or (prefix .. ax))
    end
    fieldOf.priority = common.fieldName((axes.priority or {}).field or (prefix .. "priority"))
    fieldOf.gates    = common.fieldName((axes.gates or {}).field or (prefix .. "gates"))
    fieldOf.windows  = common.fieldName((axes.windows or {}).field or (prefix .. "windows"))
    fieldOf.building = common.fieldName((axes.building or {}).field or (prefix .. "building"))
    building.configure(fieldOf)
    preview.setStack(building.stack)

    palette = {
        curb = {
            label   = (axes.curb or {}).label or "curb edge",
            entries = buildAxis((data.curb or {}).styles, "curb"),
        },
        walk = {
            label   = legacyLabel((axes.walk or {}).label) or "top surface",
            entries = buildAxis((data.walk or {}).styles, "walk"),
        },
        profile = {
            label   = (axes.profile or {}).label or "curb profile",
            entries = buildAxis((data.profile or {}).styles or defaultProfileStyles, "profile"),
        },
        wall = {
            label   = (axes.wall or {}).label or "MeshRoad material",
            entries = buildAxis((data.wall or {}).styles, "wall"),
        },
        bottom = {
            label   = (axes.bottom or {}).label or "bottom faces",
            entries = buildAxis(defaultFlagStyles, "bottom"),
        },
        roll = {
            label   = (axes.roll or {}).label or "banking from nodes",
            entries = buildAxis(defaultFlagStyles, "roll"),
        },
        ends = {
            label   = (axes.ends or {}).label or "end curbs",
            entries = buildAxis(defaultFlagStyles, "ends"),
        },
    }
    for _, f in ipairs(geometry.features) do
        palette[f.key] = {
            label   = (axes[f.key] or {}).label or f.label,
            entries = buildAxis(defaultFlagStyles, f.key),
        }
    end

    cfgEmpty = (#palette.curb.entries == 0 and #palette.walk.entries == 0
                and #palette.wall.entries == 0)

    for _, ax in ipairs(allAxes) do
        if isRtlText(palette[ax].label) then layout.rtlConfig = true end
        for _, e in ipairs(palette[ax].entries) do
            if isRtlText(e.label) then layout.rtlConfig = true end
        end
    end

    cfg = data
end

local function loadConfig()
    loadConfigData()
    preview.loadStyles()
end

-- =============================================================================
-- MATERIALS
-- =============================================================================

local matSet        = nil
local matFilter     = imgui.ImGuiTextFilter()
local texCache      = {}
local texBudget     = 0
local opaqueOnly    = imgui.BoolPtr(true)
local likelyOnly    = imgui.BoolPtr(false)
local asNewStyle    = imgui.BoolPtr(false)
local matClassCache = {}
local newScaleU     = imgui.FloatPtr(2.5)
local newScaleV     = imgui.FloatPtr(2.5)
local newBand       = imgui.IntPtr(0)
local newAxis       = imgui.IntPtr(1)
local alsoCurbMat   = imgui.BoolPtr(false)
local alsoMeshMat   = imgui.BoolPtr(false)
local selectedMat   = nil
local matError      = nil
local labelBuf      = imgui.ArrayChar(64)

local function bufRead(arr)
    return ffi.string(arr)
end

local function bufWrite(arr, str)
    ffi.copy(arr, tostring(str or ""):sub(1, imgui.ArraySize(arr) - 1))
end

local vec32 = imgui.ImVec2(32, 32)

local function ensureMatSet()
    if matSet then return matSet end
    matSet    = {}
    local set = Sim.getMaterialSet()
    for i = 0, set:size() - 1 do
        matSet[#matSet + 1] = set:at(i)
    end
    return matSet
end

local function matField(mat, name, idx)
    return mat:getField(name, idx or 0)
end

local function texFor(mat)
    local img = matField(mat, "baseColorMap", 0)
    if not img or img == "" then img = matField(mat, "diffuseMap", 0) end
    if not img or img == "" then img = matField(mat, "colorMap", 0) end
    if not img or img == "" then return nil end
    local abs = img
    if not img:find("/") then
        abs = mat:getPath() .. img
    end
    if texCache[abs] == nil and texBudget < 5 then
        texBudget     = texBudget + 1
        local tex     = editor.texObj(abs)
        texCache[abs] = (tex and tex.texId) and tex or false
    end
    return texCache[abs] or nil
end

local nonCoveringBlend = {
    Add = true, AddAlpha = true, Mul = true, Sub = true, PreMulAlpha = true,
}

local function matOpacityClass(mat)
    local function on(k)
        local v = matField(mat, k, 0)
        return v == "1" or v == "true"
    end
    local function filled(k)
        local v = matField(mat, k, 0)
        return v ~= nil and v ~= ""
    end

    if on("alphaTest") or filled("opacityMap") or filled("opacityDetailMap") then
        return "cutout"
    end
    local of = tonumber(matField(mat, "opacityFactor", 0) or "1")
    if of and of < 1 then return "faded" end
    if on("emissive") then return "glow" end

    local op = matField(mat, "translucentBlendOp", 0)
    if op and nonCoveringBlend[op] then return "glow" end
    if op == "LerpAlpha" and not on("translucentZWrite") then return "blended" end

    return "opaque"
end

local function matClass(mat, name)
    local c = matClassCache[name]
    if c == nil then
        c                   = matOpacityClass(mat)
        matClassCache[name] = c
    end
    return c
end

local function isSolidMaterial(mat, name)
    return matClass(mat, name) == "opaque"
end

local candidateDeny = {
    "annotation", "checkpoint", "marker", "rooftile", "roof_tile", "invisible",
    "unmapped", "noshape", "default", "editor", "debug", "test", "lod",
    "decal", "damage", "eroded", "destroyed", "leak", "dirty",
}

local candidateRules = {
    {axis = "curb", rank = 1, keys = {"curb", "kerb", "gutter"}},
    {axis = "walk", rank = 1, keys = {"sidewalk", "pavement", "walkway"}},
    {axis = "walk", rank = 2, keys = {"slab", "paver", "floortile"}},
    {axis = "walk", rank = 3, keys = {"tiles", "cobble"}},
    {axis = "wall", rank = 1, keys = {"concrete", "retaining"}},
    {axis = "wall", rank = 2, keys = {"stone", "wall", "blockwall"}},
    {axis = "wall", rank = 3, keys = {"brick", "cladding"}},
}

local candidateCache = {}

local function candidateInfo(name)
    local hit = candidateCache[name]
    if hit ~= nil then
        if hit == false then return nil end
        return hit
    end
    local n = name:lower()
    for _, d in ipairs(candidateDeny) do
        if n:find(d, 1, true) then
            candidateCache[name] = false
            return nil
        end
    end
    for _, r in ipairs(candidateRules) do
        for _, k in ipairs(r.keys) do
            if n:find(k, 1, true) then
                local info           = {axis = r.axis, key = k, rank = r.rank}
                candidateCache[name] = info
                return info
            end
        end
    end
    candidateCache[name] = false
    return nil
end

-- =============================================================================
-- CONFIG EDIT
-- =============================================================================

local writeJson = common.writeJson

local function slug(s)
    s = tostring(s or ""):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    return s ~= "" and s or "style"
end

local function commitConfig(data)
    if cfgPath == "" then
        statusText = "no level loaded"
        return false
    end
    local okEnc, text = pcall(jsonEncode, data)
    if not okEnc or not pcall(jsonDecode, text) then
        statusText = "file malformed"
        return false
    end
    if not writeJson(cfgPath, data) then
        statusText = "write failed - no permission on the level folder?"
        return false
    end
    if not readJson(cfgPath) then
        statusText = "writing the config failed"
        return false
    end
    return true
end

local function dataCurbUsesAtlas(data)
    local name = data and data.curb and data.curb.material
    local mat  = name and data.materials and data.materials[name]
    return type(mat) == "table" and mat.atlas ~= nil
end

local function styleKeyFor(data, axis, matName, label, forceNew)
    local styles = (data[axis] or {}).styles or {}
    local base   = slug(label ~= "" and label or matName)

    if not forceNew then
        local st = styles[base]
        if st and (st.material == matName or st.material == nil) then return base end
        if not st then return base end
    end

    local i = 2
    while styles[base .. "_" .. i] do i = i + 1 end
    return base .. "_" .. i
end

local function emptyConfigData()
    local data = {
        version      = 1,
        seed         = math.floor(os.time() % 100000000),
        fieldPrefix  = defaultPrefix,
        defaultScale = 2.5,
        axes         = {
            curb    = {field = defaultPrefix .. "curb",    label = "curb edge"},
            walk    = {field = defaultPrefix .. "walk",    label = "top surface"},
            wall    = {field = defaultPrefix .. "wall",    label = "MeshRoad material"},
            bottom  = {field = defaultPrefix .. "bottom",  label = "bottom faces"},
            roll    = {field = defaultPrefix .. "roll",    label = "banking from nodes"},
            ends    = {field = defaultPrefix .. "ends",    label = "end curbs"},
            profile = {field = defaultPrefix .. "profile", label = "curb profile"},
        },
        materials = {},
        curb      = {styles = {}},
        walk      = {styles = {}},
        wall      = {styles = {}},
    }
    for _, f in ipairs(geometry.features) do
        data.axes[f.key] = {field = defaultPrefix .. f.key, label = f.label}
    end
    return data
end

local starterDir      = "/lua/ge/extensions/editor/mage/config/starter/"
local starterMats     = "mage.materials.json"
local starterSections = {"defaultScale", "materials", "atlases", "curb", "walk", "wall", "profile"}

local function starterConfigData()
    local data    = emptyConfigData()
    local starter = readJson(starterDir .. configName)
    if type(starter) ~= "table" then return data, false end
    for _, k in ipairs(starterSections) do
        if starter[k] ~= nil then data[k] = starter[k] end
    end
    return data, true
end

local function installStarterMaterials(dir)
    if not dir then return false end
    local target = dir .. geometry.mr.daeDir .. starterMats
    if not common.fileExists(target) then
        local text = readFile(starterDir .. starterMats)
        if type(text) ~= "string" or text == "" then return false end
        if not writeFile(target, text) then return false end
    end
    local defs    = readJson(target)
    local missing = false
    if type(defs) == "table" then
        for name in pairs(defs) do
            if not scenetree.findObject(name) then missing = true end
        end
    end
    if missing then loadJsonMaterialsFile(target) end
    return true
end

local function styleCount(section)
    local styles = type(section) == "table" and section.styles
    local n      = 0
    if type(styles) == "table" then for _ in pairs(styles) do n = n + 1 end end
    return n
end

local function fillFromStarter()
    local data = readJson(cfgPath)
    if not data then
        statusText = "cannot read the config"
        return false
    end
    local starter = readJson(starterDir .. configName)
    if type(starter) ~= "table" then
        statusText = "the starter set is missing from the mod"
        return false
    end
    for _, k in ipairs({"curb", "walk", "wall"}) do
        if starter[k] ~= nil and styleCount(data[k]) == 0 then data[k] = starter[k] end
    end
    data.materials = type(data.materials) == "table" and data.materials or {}
    for name, m in pairs(starter.materials or {}) do
        if data.materials[name] == nil then data.materials[name] = m end
    end
    if data.atlases == nil then data.atlases = starter.atlases end
    if not commitConfig(data) then return false end
    local matsOk = installStarterMaterials(levelDir())
    matSet       = nil
    loadConfig()
    statusText = lookup("filled from the starter set")
    if not matsOk then
        statusText = statusText .. "\n" .. lookup("the starter materials could not be copied into the level")
    end
    return true
end

local function createEmptyConfig()
    if cfgPath == "" then
        statusText = "no level loaded"
        return false
    end
    if readJson(cfgPath) then
        statusText = "a config already exists - not overwriting it"
        return false
    end
    local data, starter = starterConfigData()
    if not commitConfig(data) then return false end
    local matsOk = starter and installStarterMaterials(levelDir())
    matSet       = nil
    loadConfig()
    if not starter then
        statusText = tr("created %s", configName)
    elseif matsOk then
        statusText = tr("created %s from the starter set", configName)
    else
        statusText = tr("created %s from the starter set", configName) .. "\n"
            .. lookup("the starter materials could not be copied into the level")
    end
    return true
end

local function materialStillUsed(data, matName, skipAxis, skipKey)
    for _, ax in ipairs(allAxes) do
        local styles = (data[ax] or {}).styles
        if type(styles) == "table" then
            for k, st in pairs(styles) do
                if not (ax == skipAxis and k == skipKey) and type(st) == "table"
                      and st.material == matName then
                    return true
                end
            end
        end
    end
    local curb = data.curb or {}
    if curb.material == matName or curb.meshroadMaterial == matName then return true end
    return false
end

local function pushMapMaterial(curb, field, matName)
    local old = curb[field]
    if old == nil or old == matName then
        curb[field] = matName
        return
    end
    local histKey = field .. "History"
    local hist    = type(curb[histKey]) == "table" and curb[histKey] or {}
    for i = #hist, 1, -1 do
        if hist[i] == old or hist[i] == matName then table.remove(hist, i) end
    end
    hist[#hist + 1] = old
    while #hist > 8 do table.remove(hist, 1) end
    curb[histKey] = hist
    curb[field]   = matName
end

local function restoreMapMaterial(data, field, matName, allowUnset)
    local curb = data.curb or {}
    if curb[field] ~= matName then return nil end
    local histKey = field .. "History"
    local hist    = type(curb[histKey]) == "table" and curb[histKey] or {}
    while #hist > 0 do
        local cand = table.remove(hist)
        if cand ~= matName then
            curb[field]   = cand
            curb[histKey] = (#hist > 0) and hist or nil
            return cand
        end
    end
    curb[histKey] = nil
    if not allowUnset then return nil end
    curb[field] = nil
    return false
end

local function removeStyleFromConfig(axis, key)
    local data = readJson(cfgPath)
    if not data then
        statusText = "cannot read the config"
        return
    end
    local styles = (data[axis] or {}).styles
    local st     = styles and styles[key]
    if not st then
        statusText = tr("style not found: %s", tostring(key))
        return
    end

    local matName = st.material
    styles[key]   = nil

    local unlinked = 0
    for _, ax in ipairs(allAxes) do
        local s2 = (data[ax] or {}).styles
        if type(s2) == "table" then
            for _, other in pairs(s2) do
                if type(other) == "table" and type(other.sequence) == "table" then
                    for i = #other.sequence, 1, -1 do
                        if other.sequence[i] == key then
                            table.remove(other.sequence, i)
                            unlinked = unlinked + 1
                        end
                    end
                end
            end
        end
    end

    local restored = {}
    if matName then
        local usedByStyle = false
        for _, ax in ipairs(allAxes) do
            local s3 = (data[ax] or {}).styles
            if type(s3) == "table" then
                for _, other in pairs(s3) do
                    if type(other) == "table" and other.material == matName then usedByStyle = true end
                end
            end
        end
        if not usedByStyle then
            for _, field in ipairs({"meshroadMaterial", "material"}) do
                local r = restoreMapMaterial(data, field, matName, field == "meshroadMaterial")
                if r ~= nil then
                    restored[#restored + 1] = {field, r}
                elseif (data.curb or {})[field] == matName then
                    restored[#restored + 1] = {field, matName, true}
                end
            end
        end
    end

    if matName and data.materials and not materialStillUsed(data, matName) then
        data.materials[matName] = nil
    end

    if not commitConfig(data) then return end
    loadConfig()
    local links = ""
    if unlinked == 1 then
        links = tr(" (1 sequence link cleared)")
    elseif unlinked > 1 then
        links = tr(" (%d sequence links cleared)", unlinked)
    end
    statusText = tr("removed %s from %s", key, axis) .. links
    for _, r in ipairs(restored) do
        if r[3] then
            statusText = statusText .. "\n" .. tr("map %s is still %s - no earlier value to restore", r[1], r[2])
        else
            statusText = statusText .. "\n" .. tr("map %s restored to %s", r[1],
                                                      r[2] and tostring(r[2]) or tr("(unset)"))
        end
    end
end

local function addMaterialToConfig(matName, axis, su, sv, label, asCurbMat, asMeshMat, forceNew)
    label      = (label and label ~= "") and label or matName
    local data = readJson(cfgPath)
    if not data then
        if not cfgMissing then
            statusText = "cannot read the config for writing"
            return
        end
        data = emptyConfigData()
    end

    data.materials          = data.materials or {}
    data.materials[matName] = data.materials[matName] or {}

    data.curb = data.curb or {}

    if asCurbMat or (axis == "curb" and not data.curb.material) then
        pushMapMaterial(data.curb, "material", matName)
    end
    if asMeshMat or (axis == "wall" and not data.curb.meshroadMaterial) then
        pushMapMaterial(data.curb, "meshroadMaterial", matName)
    end

    data[axis]        = data[axis] or {}
    data[axis].styles = data[axis].styles or {}

    local key      = styleKeyFor(data, axis, matName, label, forceNew)
    local matEntry = data.materials[matName]
    if matEntry.scale == nil or (axis == "curb" and dataCurbUsesAtlas(data))
          or not materialStillUsed(data, matName, axis, key) then
        matEntry.scale = {su, sv}
    end
    local style = data[axis].styles[key]
    if style then
        style.label = label
    else
        style = {
            material = matName,
            weight   = 0,
            label    = label,
            color    = {0.55, 0.55, 0.58},
        }
        data[axis].styles[key] = style
    end

    if axis == "curb" then
        style.material = nil
        if dataCurbUsesAtlas(data) then
            style.band  = newBand[0]
            style.scale = nil
        else
            style.scale = {su, sv}
            style.band  = nil
        end
    else
        style.scale = {su, sv}
    end

    if not commitConfig(data) then return end

    local wasAtlas = dataCurbUsesAtlas(data)
    loadConfig()
    if axis == "curb" and wasAtlas then
        statusText = tr("%s (%s) added to %s as band %d  [%s]",
                        label, matName, axis, newBand[0], key)
    else
        statusText = tr("%s (%s) added to %s at scale %.2f x %.2f  [%s]",
                        label, matName, axis, su, sv, key)
    end
end

-- =============================================================================
-- SELECTION
-- =============================================================================

local function getSelection()
    return editor.selection.object or {}
end

local function classOf(id)
    local obj = scenetree.findObjectById(id)
    if not obj then return "" end
    return obj:getClassName()
end

local function dynValue(id, fieldName)
    local fields = editor.getDynamicFields(id)
    if not fields then return nil end
    for _, f in ipairs({fieldName, common.legacyField(fieldName)}) do
        for i = 1, #fields do
            if fields[i] == f then
                local val = editor.getFieldValue(id, f)
                if val ~= "" then return val end
            end
        end
    end
    return nil
end

local function selectionValue(ids, fieldName)
    if #ids == 0 then return nil, "none" end
    local first = dynValue(ids[1], fieldName)
    for i = 2, #ids do
        if dynValue(ids[i], fieldName) ~= first then return nil, "mixed" end
    end
    if first == nil then return nil, "none" end
    return first, "all"
end

local function writeField(id, fieldName, value)
    local legacy = common.legacyField(fieldName)
    common.setDynWithUndo({id}, fieldName, value)
    if legacy and dynValue(id, legacy) then common.setDynWithUndo({id}, legacy, "") end
end

local function applyValue(fieldName, value, idsIn)
    local ids = idsIn or getSelection()
    if #ids == 0 then
        statusText = "nothing selected"
        return
    end

    editor.history:beginTransaction("MageTag")
    for i = 1, #ids do writeField(ids[i], fieldName, value) end
    editor.history:endTransaction()

    statusText = (value == "")
        and tr("cleared %s from %d objects", fieldName, #ids)
        or tr("%s = %s written to %d objects", fieldName, value, #ids)
end

-- =============================================================================
-- COVERAGE
-- =============================================================================

local coverage = nil

local function objDynValue(obj, fieldName)
    for _, f in ipairs({fieldName, common.legacyField(fieldName)}) do
        local v = obj:getDynDataFieldbyName(f, 0)
        if v ~= nil and v ~= "" then return v end
    end
    return nil
end

local function knownValues(axis)
    local set = {}
    if palette then
        for _, e in ipairs(palette[axis].entries) do set[e.value] = true end
    end
    return set
end

local markerMaterial = "WarningMaterial"
local materialKeys   = settings.meshRoad.materialKeys

local function objField(obj, name)
    local v = obj:getField(name, 0)
    if v ~= nil and v ~= "" then return tostring(v) end
    return nil
end

local function findUnskinned(kind)
    local ids = {}
    for _, nm in ipairs(scenetree.findClassObjects(kind)) do
        local obj = scenetree.findObject(nm)
        if obj then
            local take
            if kind == "MeshRoad" then
                local real = false
                for _, key in ipairs(materialKeys) do
                    local v = objField(obj, key)
                    if v and v ~= markerMaterial then real = true end
                end
                take = not real
            else
                take = (objField(obj, "material") == markerMaterial)
            end
            if take then
                ids[#ids + 1] = obj:getID()
            end
        end
    end
    return ids
end

local function scanCoverage()
    coverage = {total = 0, untagged = 0}
    for _, ax in ipairs(allAxes) do coverage[ax] = {} end
    local ids    = findUnskinned("MeshRoad")
    local decals = findUnskinned("DecalRoad")
    for i = 1, #decals do ids[#ids + 1] = decals[i] end

    local known = {}
    for _, ax in ipairs(allAxes) do known[ax] = knownValues(ax) end

    for _, id in ipairs(ids) do
        local obj = scenetree.findObjectById(id)
        if obj then
            coverage.total = coverage.total + 1
            local tagged   = false
            for _, axis in ipairs(allAxes) do
                local v = objDynValue(obj, fieldOf[axis])
                if v then
                    tagged       = true
                    local bucket = coverage[axis][v]
                    if not bucket then
                        bucket            = {n = 0, ids = {}, known = known[axis][v] or false}
                        coverage[axis][v] = bucket
                    end
                    bucket.n = bucket.n + 1
                    if id then bucket.ids[#bucket.ids + 1] = id end
                end
            end
            if not tagged then coverage.untagged = coverage.untagged + 1 end
        end
    end
    statusText = tr("scanned %d objects", coverage.total)
end

local function selectIds(ids)
    if not ids or #ids == 0 then return end
    editor.selectObjects(ids)
    statusText = tr("selected %d objects", #ids)
end

-- =============================================================================
-- BUTTONS
-- =============================================================================

local btnW   = 122
local perRow = 2

local function paletteButton(entry, axis, isActive)
    local pushes = 0
    if entry.color then
        imgui.PushStyleColor2(imgui.Col_Button, color4(entry.color, 1))
        imgui.PushStyleColor2(imgui.Col_ButtonHovered, color4(entry.color, 0.85))
        imgui.PushStyleColor2(imgui.Col_ButtonActive, color4(entry.color, 0.7))
        imgui.PushStyleColor2(imgui.Col_Text, (luminance(entry.color) < 0.5)
                              and imgui.ImVec4(1, 1, 1, 1) or imgui.ImVec4(0.05, 0.05, 0.05, 1))
        pushes = 4
    end

    local label   = lookup(entry.label) .. (isActive and "  <" or "")
    local clicked = imgui.Button(visual(label) .. "##" .. axis .. "_" .. entry.value,
                                 imgui.ImVec2(btnW, 0))

    for _ = 1, pushes do imgui.PopStyleColor() end

    if imgui.IsItemHovered() then
        imgui.SetTooltip(entry.value)
    end
    return clicked
end

local function sectionv(title, defaultOpen)
    if sectionForce ~= nil then
        imgui.SetNextItemOpen(sectionForce)
    elseif defaultOpen then
        imgui.SetNextItemOpen(true, imgui.Cond_FirstUseEver)
    end
    local v = visual(title)
    if rtlLayout then
        local st = imgui.GetStyle()
        local fh = imgui.CalcTextSize("X").y
        v        = layout.pad(v, availWidth() - fh - 4 * st.FramePadding.x) .. "##sec_" .. title
    end
    return imgui.CollapsingHeader1(v)
end

local function section(title, defaultOpen)
    return sectionv(lookup(title), defaultOpen)
end

local function drawAxis(axis, ids)
    local hasSelection = #ids > 0
    local ax           = palette[axis]
    if not ax or #ax.entries == 0 then return end
    local field = fieldOf[axis]

    if not sectionv(lookup(ax.label) .. "  (" .. field .. ")", true) then return end

    local current, state = selectionValue(ids, field)

    if state == "mixed" then
        text("current: mixed", imgui.ImVec4(1, 0.7, 0.2, 1))
    elseif state == "all" then
        local known = false
        for _, e in ipairs(ax.entries) do
            if e.value == current then
                known = true
                break
            end
        end
        textv(tr("current: %s%s", tostring(current),
                 known and "" or tr("  (not in config)")),
              known and imgui.ImVec4(0.4, 1, 0.4, 1) or imgui.ImVec4(1, 0.45, 0.35, 1))
    else
        text("current: (untagged - default)", imgui.ImVec4(0.6, 0.6, 0.6, 1))
    end

    local total    = #ax.entries
    local rowStart = 1
    while rowStart <= total do
        local rowEnd = math.min(rowStart + perRow - 1, total)
        local inRow  = rowEnd - rowStart + 1
        alignRight(btnW * inRow + 8 * (inRow - 1))

        if rtlLayout then
            for k = rowEnd, rowStart, -1 do
                if k < rowEnd then imgui.SameLine() end
                local entry  = ax.entries[k]
                local active = (state == "all" and current == entry.value)
                if paletteButton(entry, axis, active) and hasSelection then
                    applyValue(field, entry.value, ids)
                end
            end
        else
            for k = rowStart, rowEnd do
                if k > rowStart then imgui.SameLine() end
                local entry  = ax.entries[k]
                local active = (state == "all" and current == entry.value)
                if paletteButton(entry, axis, active) and hasSelection then
                    applyValue(field, entry.value, ids)
                end
            end
        end
        rowStart = rowStart + perRow
    end

    alignRight(btnW)
    if imgui.Button(rtl("clear  X") .. "##clear_" .. axis, imgui.ImVec2(btnW, 0)) and hasSelection then
        applyValue(field, "", ids)
    end
end

-- =============================================================================
-- ICONS
-- =============================================================================

local flagCols = nil

local function getFlagCols()
    if flagCols then return flagCols end
    flagCols = {
        on      = imgui.ImVec4(0.286, 0.714, 0.447, 1),
        off     = imgui.ImVec4(0.86, 0.25, 0.22, 1),
        default = imgui.ImVec4(0.55, 0.55, 0.55, 1),
        mixed   = imgui.ImVec4(1, 0.7, 0.2, 1),
    }
    return flagCols
end

local function flagState(current, state)
    if state == "mixed" then return "mixed" end
    if state == "all" and current == "on" then return "on" end
    if state == "all" and current == "off" then return "off" end
    return "default"
end

local nextFlag = {default = "on", on = "off", off = "default", mixed = "on"}

local function iconSize()
    local st = imgui.GetStyle()
    return 36 * imgui.uiscale[0] + 2 * st.FramePadding.x, st.ItemSpacing.x
end

local function iconRowWidth(n)
    local w, gap = iconSize()
    return n * w + (n - 1) * gap
end

local iconLower = {src = nil, map = {}}

local function findIcon(iconName)
    local icons = editor.icons
    if type(icons) ~= "table" or not iconName then return nil end
    if icons[iconName] then return icons[iconName] end
    if iconLower.src ~= icons then
        iconLower.src, iconLower.map = icons, {}
        for k in pairs(icons) do
            if type(k) == "string" then iconLower.map[k:lower()] = k end
        end
    end
    local key = iconLower.map[iconName:lower()]
    return key and icons[key] or nil
end

local function iconButton(id, iconName, label, tint, tipText)
    local icon = findIcon(iconName)
    local clicked
    if icon then
        clicked = editor.uiIconImageButton(icon, imgui.ImVec2(36, 36), tint, nil, nil, "##" .. id)
    else
        if tint then imgui.PushStyleColor2(imgui.Col_Text, tint) end
        clicked = imgui.Button(rtl(label) .. "##" .. id)
        if tint then imgui.PopStyleColor() end
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip(rtl(tipText or lookup(label)))
    end
    return clicked
end

local function drawSlots(slots)
    if #slots == 0 then return end
    alignRight(iconRowWidth(#slots))
    local first, last, step = 1, #slots, 1
    if rtlLayout then first, last, step = #slots, 1, -1 end
    for k = first, last, step do
        if k ~= first then imgui.SameLine() end
        slots[k]()
    end
end

local function flagSlot(axis, ids)
    return function()
        local field          = fieldOf[axis]
        local label          = palette[axis].label or axis
        local current, state = selectionValue(ids, field)
        local st             = flagState(current, state)
        local nxt            = nextFlag[st]
        local line           = tr("%s: %s - click for %s", lookup(label), lookup(st), lookup(nxt))
        if iconButton("pitflag_" .. axis, flagIcons[axis] or "", label, getFlagCols()[st], line) then
            applyValue(field, (nxt == "default") and "" or nxt, ids)
        end
    end
end

-- =============================================================================
-- NUMBER FIELDS
-- =============================================================================

local dimStep   = 0.1
local dimFieldW = 110
local dimBtnW   = 24

local stepRepeat = {}

function stepRepeat.button(label, size)
    imgui.PushButtonRepeat(true)
    local clicked = imgui.Button(label, size)
    imgui.PopButtonRepeat()
    return clicked
end

-- =============================================================================
-- LAYOUT
-- =============================================================================

local ui = {bufs = {}, edit = {}, open = false, stretch = 8}


ui.grey   = imgui.ImVec4(0.6, 0.6, 0.6, 1)
ui.blue   = imgui.ImVec4(0.55, 0.75, 1, 1)
ui.green  = imgui.ImVec4(0.31, 0.71, 0.48, 1)
ui.orange = imgui.ImVec4(1, 0.7, 0.2, 1)
ui.red    = imgui.ImVec4(1, 0.45, 0.35, 1)
ui.white  = imgui.ImVec4(1, 1, 1, 1)
ui.on     = imgui.ImVec4(0.16, 0.33, 0.55, 1)
ui.off    = imgui.ImVec4(0.14, 0.16, 0.22, 1)
ui.add    = imgui.ImVec4(0.18, 0.42, 0.28, 1)
ui.rowBg  = imgui.TableFlags_RowBg
ui.theme  = {
    {imgui.Col_FrameBg,          imgui.ImVec4(0.165, 0.19, 0.26, 1)},
    {imgui.Col_FrameBgHovered,   imgui.ImVec4(0.21, 0.25, 0.34, 1)},
    {imgui.Col_FrameBgActive,    imgui.ImVec4(0.24, 0.29, 0.40, 1)},
    {imgui.Col_CheckMark,        imgui.ImVec4(0.89, 0.54, 0.25, 1)},
    {imgui.Col_Header,           imgui.ImVec4(0.20, 0.25, 0.35, 1)},
    {imgui.Col_HeaderHovered,    imgui.ImVec4(0.24, 0.30, 0.42, 1)},
    {imgui.Col_HeaderActive,     imgui.ImVec4(0.28, 0.35, 0.50, 1)},
}

function ui.pushTheme()
    for _, c in ipairs(ui.theme) do imgui.PushStyleColor2(c[1], c[2]) end
end

function ui.popTheme()
    for _ = 1, #ui.theme do imgui.PopStyleColor() end
end

function ui.beginProps(id)
    if not imgui.BeginTable("props_" .. id, 2) then return false end
    if rtlLayout then
        imgui.TableSetupColumn("##v", ui.stretch, 0.58)
        imgui.TableSetupColumn("##l", ui.stretch, 0.42)
    else
        imgui.TableSetupColumn("##l", ui.stretch, 0.42)
        imgui.TableSetupColumn("##v", ui.stretch, 0.58)
    end
    ui.open = true
    return true
end

function ui.endProps()
    if ui.open then imgui.EndTable() end
    ui.open = false
end

function ui.prop(label, col)
    if not ui.open then
        text(label, col or ui.grey)
        return
    end
    imgui.TableNextRow()
    imgui.TableSetColumnIndex(rtlLayout and 1 or 0)
    layout.wrapped(lookup(label), col or ui.grey)
    imgui.TableSetColumnIndex(rtlLayout and 0 or 1)
end

function ui.number(id, dec, inc, cur, lo, hi, def)
    local gap = imgui.GetStyle().ItemSpacing.x
    local buf = ui.bufs[id]
    if not buf then
        buf         = imgui.FloatPtr(0)
        ui.bufs[id] = buf
    end
    if not ui.edit[id] then buf[0] = cur end
    local newValue
    local lo1, hi1 = rtlLayout and "+##" .. inc or "-##" .. dec, rtlLayout and "-##" .. dec or "+##" .. inc
    local d1       = rtlLayout and dimStep or -dimStep
    if stepRepeat.button(lo1, imgui.ImVec2(dimBtnW, 0)) then newValue = cur + d1 end
    imgui.SameLine()
    imgui.PushItemWidth(math.max(40, availWidth() - dimBtnW - gap))
    if imgui.DragFloat("##" .. id, buf, 0.01, lo, hi, "%.2f") then
        buf[0]      = common.clamp(buf[0], lo, hi)
        ui.edit[id] = true
    end
    if imgui.IsItemDeactivatedAfterEdit() then
        ui.edit[id] = nil
        newValue    = buf[0]
    end
    if def and imgui.IsItemHovered() then
        imgui.SetTooltip(rtl(tr("default: %s", string.format("%g", def))))
    end
    imgui.PopItemWidth()
    imgui.SameLine()
    if stepRepeat.button(hi1, imgui.ImVec2(dimBtnW, 0)) then newValue = cur - d1 end
    if newValue then return math.floor(common.clamp(newValue, lo, hi) * 1000 + 0.5) / 1000 end
    return nil
end


function ui.beginTable(id, weights, flags)
    if not imgui.BeginTable(id, #weights, flags or 0) then return false end
    local n = #weights
    for k = 1, n do
        local w = weights[rtlLayout and (n - k + 1) or k]
        imgui.TableSetupColumn("##c" .. k, ui.stretch, w)
    end
    return true
end

function ui.cells(fns)
    imgui.TableNextRow()
    local n = #fns
    for k = 1, n do
        imgui.TableSetColumnIndex(rtlLayout and (n - k) or (k - 1))
        fns[k]()
    end
end

function ui.row(items)
    local gap    = imgui.GetStyle().ItemSpacing.x
    local avail  = availWidth()
    local x0     = imgui.GetCursorPosX()
    local lines  = {}
    local cur, w = {}, 0
    for _, it in ipairs(items) do
        if #cur > 0 and w + gap + it.w > avail then
            lines[#lines + 1] = {items = cur, w = w}
            cur, w            = {}, 0
        end
        w             = (#cur > 0) and (w + gap + it.w) or it.w
        cur[#cur + 1] = it
    end
    if #cur > 0 then lines[#lines + 1] = {items = cur, w = w} end
    local hit
    for _, ln in ipairs(lines) do
        local xs = {}
        if rtlLayout then
            local right = x0 + math.max(ln.w, avail)
            for k, it in ipairs(ln.items) do
                xs[k] = right - it.w
                right = xs[k] - gap
            end
        else
            local x = x0
            for k, it in ipairs(ln.items) do
                xs[k] = x
                x     = x + it.w + gap
            end
        end
        for k, it in ipairs(ln.items) do
            if k > 1 then imgui.SameLine() end
            imgui.SetCursorPosX(xs[k])
            local r = it.draw()
            if it.tip then tip(it.tip) end
            if r then hit = r end
        end
    end
    return hit
end

function ui.btnItem(label, id, bg, fg, width)
    local v = rtl(label)
    local w = width or (imgui.CalcTextSize(v).x + 2 * imgui.GetStyle().FramePadding.x)
    return {w = w, draw = function()
        if bg then imgui.PushStyleColor2(imgui.Col_Button, bg) end
        if fg then imgui.PushStyleColor2(imgui.Col_Text, fg) end
        local c = imgui.Button(v .. "##" .. id, width and imgui.ImVec2(width, 0) or nil)
        if fg then imgui.PopStyleColor() end
        if bg then imgui.PopStyleColor() end
        return c and id or nil
    end}
end

function ui.button(label, id, bg, fg)
    return ui.row({ui.btnItem(label, id, bg, fg)}) ~= nil
end

function ui.buttons(list)
    local items = {}
    for _, b in ipairs(list) do items[#items + 1] = ui.btnItem(b[1], b[2], b[3], b[4]) end
    return ui.row(items)
end

function ui.textItem(v, col)
    return {w = imgui.CalcTextSize(v).x, draw = function()
        if col then imgui.TextColored(col, v) else imgui.TextUnformatted(v) end
    end}
end

function ui.markItem(id, label, ptr, radio)
    local v  = rtl(label)
    local st = imgui.GetStyle()
    local fh = imgui.CalcTextSize("X").y + 2 * st.FramePadding.y
    local tw = imgui.CalcTextSize(v).x
    local sp = st.ItemInnerSpacing.x
    local function mark(lbl)
        if radio then return imgui.RadioButton2(lbl, ptr, radio) end
        return imgui.Checkbox(lbl, ptr)
    end
    return {w = fh + sp + tw, draw = function()
        if not rtlLayout then return mark(v .. "##" .. id) and id or nil end
        local x = imgui.GetCursorPosX()
        imgui.SetCursorPosX(x + tw + sp)
        local c = mark("##" .. id)
        imgui.SameLine()
        imgui.SetCursorPosX(x)
        imgui.TextUnformatted(v)
        return c and id or nil
    end}
end

function ui.checkPtr(id, label, ptr)
    return ui.row({ui.markItem(id, label, ptr)}) ~= nil
end

function ui.check(id, label, value)
    local ptr = imgui.BoolPtr(value == true)
    if ui.checkPtr(id, label, ptr) then return true, ptr[0] end
    return false, value
end

function ui.checks(list)
    local items, ptrs = {}, {}
    for _, c in ipairs(list) do
        ptrs[c[1]]        = imgui.BoolPtr(c[3] == true)
        items[#items + 1] = ui.markItem(c[1], c[2], ptrs[c[1]])
    end
    local hit = ui.row(items)
    if hit then return hit, ptrs[hit][0] end
    return nil
end

ui.pad = layout.pad

function ui.heading(title)
    drawText(rtl(title), ui.green)
    imgui.Separator()
end

-- =============================================================================
-- PRESETS AND COPY
-- =============================================================================

local presetUi = {bufs = {}, clip = nil}

function presetUi.list(kind)
    local all = cfg and type(cfg.presets) == "table" and cfg.presets[kind]
    local out = {}
    if type(all) ~= "table" then return out end
    for name, v in pairs(all) do
        if type(v) == "table" then out[#out + 1] = {name = name, values = v} end
    end
    table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return out
end

function presetUi.store(kind, name, values)
    local data = readJson(cfgPath)
    if not data then
        statusText = "cannot read the config for writing"
        return false
    end
    data.presets             = type(data.presets) == "table" and data.presets or {}
    data.presets[kind]       = type(data.presets[kind]) == "table" and data.presets[kind] or {}
    data.presets[kind][name] = values
    if not commitConfig(data) then return false end
    loadConfig()
    return true
end

function presetUi.draw(kind, values, autoName, apply)
    if not cfg then return end
    for k, p in ipairs(presetUi.list(kind)) do
        local hit = ui.buttons({{tostring(p.name), "preset_" .. kind .. "_" .. k}, {"x", "presetdel_" .. kind .. "_" .. k}})
        if hit == "preset_" .. kind .. "_" .. k then
            apply(p.values)
            statusText = tr("preset %s applied", tostring(p.name))
        elseif hit and presetUi.store(kind, p.name, nil) then
            statusText = tr("preset %s deleted", tostring(p.name))
        end
    end
    if not presetUi.bufs[kind] then presetUi.bufs[kind] = imgui.ArrayChar(64) end
    local buf  = presetUi.bufs[kind]
    local name = {w = dimFieldW * 2, draw = function()
        imgui.PushItemWidth(dimFieldW * 2)
        imgui.InputText("##presetname_" .. kind, buf, 64)
        imgui.PopItemWidth()
    end}
    if ui.row({ui.btnItem("save as preset", "presetsave_" .. kind), name}) then
        local name = bufRead(buf):gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then name = autoName end
        local copy = {}
        for k, v in pairs(values) do copy[k] = v end
        if presetUi.store(kind, name, copy) then
            bufWrite(buf, "")
            statusText = tr("preset %s saved", name)
        end
    end
    tip("presets are kept in this map's config, so every road and gate in the map can use them")
end

function presetUi.fieldsOf(isMesh)
    local keys = {}
    for _, ax in ipairs(isMesh and allAxes or decalAxes) do keys[#keys + 1] = fieldOf[ax] end
    if isMesh then
        for _, f in ipairs(geometry.features) do
            if fieldOf[f.key] then
                keys[#keys + 1] = fieldOf[f.key]
                keys[#keys + 1] = fieldOf[f.key] .. "_dims"
            end
        end
        keys[#keys + 1] = fieldOf.priority
        keys[#keys + 1] = fieldOf.windows
    end
    return keys
end

function presetUi.copy(id)
    local isMesh = classOf(id) == "MeshRoad"
    local vals   = {}
    for _, k in ipairs(presetUi.fieldsOf(isMesh)) do
        if k then vals[k] = dynValue(id, k) or "" end
    end
    local obj     = scenetree.findObjectById(id)
    local name    = obj and obj:getName() or tostring(id)
    presetUi.clip = {values = vals, name = tostring(name), mesh = isMesh}
    statusText    = tr("settings of %s copied", presetUi.clip.name)
end

function presetUi.paste(ids)
    local clip = presetUi.clip
    if not clip then return end
    editor.history:beginTransaction("MagePaste")
    local n = 0
    for _, id in ipairs(ids) do
        local isMesh = classOf(id) == "MeshRoad"
        local allow  = {}
        for _, k in ipairs(presetUi.fieldsOf(isMesh)) do if k then allow[k] = true end end
        local any = false
        for k, v in pairs(clip.values) do
            if allow[k] and (dynValue(id, k) or "") ~= v then
                writeField(id, k, v)
                any = true
            end
        end
        if any then n = n + 1 end
    end
    editor.history:endTransaction()
    statusText = tr("settings of %s pasted on %d roads", clip.name, n)
end

function presetUi.drawCopy(roadIds)
    local items = {}
    if #roadIds == 1 then
        items[1]     = ui.btnItem("copy settings", "copysettings")
        items[1].tip = "every tag, flag and size of this road (gates stay on their nodes)"
    end
    local clip = presetUi.clip
    if clip and #roadIds > 0 then
        items[#items + 1] = ui.btnItem(tr("paste settings of %s", clip.name), "pastesettings")
        if clip.mesh then items[#items].tip = "decals only take the curb, top surface and profile tags" end
    end
    if #items == 0 then return end
    local hit = ui.row(items)
    if hit == "copysettings" then presetUi.copy(roadIds[1]) end
    if hit == "pastesettings" then presetUi.paste(roadIds) end
end

-- =============================================================================
-- EDGE FEATURES
-- =============================================================================

local function featureByKey(key)
    for _, f in ipairs(geometry.features) do
        if f.key == key then return f end
    end
    return nil
end

local function dimsField(f)
    return fieldOf[f.key] .. "_dims"
end

local function featureOf(id)
    for _, f in ipairs(geometry.features) do
        if fieldOf[f.key] and geometry.mr.flagValue(dynValue(id, fieldOf[f.key])) == true then return f.key end
    end
    return "none"
end

local function selectionFeature(ids)
    if #ids == 0 then return "none" end
    local first = featureOf(ids[1])
    for i = 2, #ids do
        if featureOf(ids[i]) ~= first then return "mixed" end
    end
    return first
end

local function nextFeature(cur)
    local order = {"none"}
    for _, f in ipairs(geometry.features) do order[#order + 1] = f.key end
    if cur == "mixed" then return order[2] or "none" end
    for i, k in ipairs(order) do
        if k == cur then return order[i % #order + 1] end
    end
    return "none"
end

local function featureLabel(key)
    local f = featureByKey(key)
    if f then return lookup((palette and palette[key] and palette[key].label) or f.label) end
    return lookup(key)
end

local function applyFeature(ids, key)
    if #ids == 0 then return end
    editor.history:beginTransaction("MageFeature")
    for _, id in ipairs(ids) do
        for _, f in ipairs(geometry.features) do
            local field = fieldOf[f.key]
            if field then
                local want = (f.key == key) and "on" or ""
                if (dynValue(id, field) or "") ~= want then writeField(id, field, want) end
            end
        end
    end
    editor.history:endTransaction()
    statusText = (key == "none") and tr("edge feature cleared from %d roads", #ids)
                                   or tr("%s set on %d roads", featureLabel(key), #ids)
end

local function featureSlot(ids)
    return function()
        local cur  = selectionFeature(ids)
        local nxt  = nextFeature(cur)
        local cols = getFlagCols()
        local f    = featureByKey(cur) or featureByKey(featureOf(ids[1] or -1)) or geometry.features[1]
        local tint = (cur == "mixed" and cols.mixed) or (cur == "none" and cols.default) or cols.on
        local line = tr("%s: %s - click for %s", lookup("edge feature"), featureLabel(cur), featureLabel(nxt))
        if iconButton("pitfeature", f and f.icon or "", "edge feature", tint, line) then
            applyFeature(ids, nxt)
        end
    end
end

local function roadDims(id, f)
    return geometry.featureOverrides(f, dynValue(id, dimsField(f))) or {}
end

local function writeDims(ids, f, key, value)
    local base = f.defaults and f.defaults() or {}
    editor.history:beginTransaction("MageDims")
    for _, id in ipairs(ids) do
        local over = {}
        if key ~= nil then
            over      = roadDims(id, f)
            over[key] = math.floor(value * 1000 + 0.5) / 1000
        end
        for k, v in pairs(over) do
            if type(base[k]) == "number" and math.abs(base[k] - v) < 1e-6 then over[k] = nil end
        end
        writeField(id, dimsField(f), next(over) and jsonEncode(over) or "")
    end
    editor.history:endTransaction()
end

local function drawFeaturePanel(ids, key)
    local f = featureByKey(key)
    if not f or not f.fields or #f.fields == 0 then return end
    if not sectionv(tr("%s settings", featureLabel(key)), true) then return end

    local first  = roadDims(ids[1], f)
    local differ = false
    for i = 2, #ids do
        local other = roadDims(ids[i], f)
        for _, fd in ipairs(f.fields) do
            if other[fd.key] ~= first[fd.key] then differ = true end
        end
    end
    if differ then
        text("values differ between the selected roads - showing the first",
             imgui.ImVec4(1, 0.7, 0.2, 1))
    end

    local shown = geometry.featureDims(f, first)
    local base  = f.defaults and f.defaults() or {}
    if ui.beginProps("dims_" .. key) then
        for _, fd in ipairs(f.fields) do
            local id = key .. "_" .. fd.key
            ui.prop(lookup(fd.label))
            local v = ui.number("dim_" .. id, "dimdec_" .. id, "diminc_" .. id, shown[fd.key] or 0, fd.min, fd.max, base[fd.key] or 0)
            if v then
                writeDims(ids, f, fd.key, v)
                statusText = tr("%s set to %s on %d roads", lookup(fd.label), string.format("%g", v), #ids)
            end
        end
        ui.endProps()
    end

    if ui.button("reset to defaults", "dimreset_" .. key) then
        writeDims(ids, f, nil, nil)
        ui.edit    = {}
        statusText = tr("%s reset on %d roads", featureLabel(key), #ids)
    end
    tip("these sizes are stored on the road itself - other roads keep their own")

    local parts = {}
    for _, fd in ipairs(f.fields) do parts[#parts + 1] = string.format("%g", shown[fd.key] or 0) end
    presetUi.draw(key, shown, featureLabel(key) .. " " .. table.concat(parts, "/"), function(values)
        local base = f.defaults and f.defaults() or {}
        editor.history:beginTransaction("MageDims")
        for _, id in ipairs(ids) do
            local over = {}
            for _, fd in ipairs(f.fields) do
                local v = tonumber(values[fd.key])
                if v and not (type(base[fd.key]) == "number" and math.abs(base[fd.key] - v) < 1e-6) then
                    over[fd.key] = common.clamp(v, fd.min, fd.max)
                end
            end
            writeField(id, dimsField(f), next(over) and jsonEncode(over) or "")
        end
        editor.history:endTransaction()
    end)
end

-- =============================================================================
-- RENDER PRIORITY
-- =============================================================================

local priorityUi = {min = -1.0, max = 1.0}

function priorityUi.roadPriority(id)
    local v = tonumber(dynValue(id, fieldOf.priority))
    if not v then return priorityUi.min end
    return common.clamp(v, priorityUi.min, priorityUi.max)
end

function priorityUi.writePriority(ids, value)
    value      = math.floor(common.clamp(value, priorityUi.min, priorityUi.max) * 1000 + 0.5) / 1000
    local want = (value <= priorityUi.min + 1e-6) and "" or string.format("%g", value)
    editor.history:beginTransaction("MagePriority")
    for _, id in ipairs(ids) do
        if (dynValue(id, fieldOf.priority) or "") ~= want then writeField(id, fieldOf.priority, want) end
    end
    editor.history:endTransaction()
    statusText = (want == "") and tr("render priority set to automatic on %d roads", #ids)
                               or tr("render priority set to %s on %d roads", want, #ids)
end

function priorityUi.drawPriority(ids)
    if not fieldOf.priority or #ids == 0 then return end
    if not sectionv(lookup("render priority"), false) then return end

    local first  = priorityUi.roadPriority(ids[1])
    local differ = false
    for i = 2, #ids do
        if math.abs(priorityUi.roadPriority(ids[i]) - first) > 1e-6 then differ = true end
    end
    if differ then
        text("values differ between the selected roads - showing the first",
             imgui.ImVec4(1, 0.7, 0.2, 1))
    end

    if ui.beginProps("priority") then
        ui.prop(lookup("priority"))
        local v = ui.number("priority", "prioritydec", "priorityinc", first, priorityUi.min, priorityUi.max)
        if imgui.IsItemHovered() then imgui.SetTooltip(rtl("-1 = automatic: more tags wins, then the name")) end
        ui.endProps()
        if v then priorityUi.writePriority(ids, v) end
    end
    if first > priorityUi.min + 1e-6 or differ then
        if ui.button("automatic", "priorityauto") then priorityUi.writePriority(ids, priorityUi.min) end
    end
    tip("where MeshRoads overlap, the higher priority keeps the shared faces and the other road drops its hidden ones")
end

-- =============================================================================
-- VISIBILITY
-- =============================================================================

local visRefresh = 1.5
local raPrefix   = "mageRA_"

local visCache = {at = -1}
local srcCache = {key = nil}

local function visState(ids)
    local shown, hidden = 0, 0
    for _, id in ipairs(ids) do
        local o = scenetree.findObjectById(id)
        if o then
            if o.hidden == true then hidden = hidden + 1 else shown = shown + 1 end
        end
    end
    if shown + hidden == 0 then return "none" end
    if hidden == 0 then return "shown" end
    if shown == 0 then return "hidden" end
    return "mixed"
end

local function setHidden(ids, value)
    local n = 0
    for _, id in ipairs(ids) do
        local o = scenetree.findObjectById(id)
        if o then
            o.hidden = value
            n        = n + 1
        end
    end
    if n > 0 then editor.setDirty() end
    visCache.at = -1
    return n
end

local function visGroups()
    local now = os.clock()
    if visCache.at >= 0 and now - visCache.at < visRefresh then return visCache end
    local mesh  = findUnskinned("MeshRoad")
    local decal = findUnskinned("DecalRoad")
    local all   = {}
    for _, id in ipairs(mesh) do all[#all + 1] = id end
    for _, id in ipairs(decal) do all[#all + 1] = id end
    visCache = {
        at    = now,
        mesh  = {ids = mesh, state = visState(mesh)},
        decal = {ids = decal, state = visState(decal)},
        all   = {ids = all, state = visState(all)},
    }
    return visCache
end

local function enterEditMode(key)
    local modes = editor.editModes
    if not key or not modes[key] then return end
    editor.selectEditMode(modes[key])
end

local function visToggle(id, iconName, label, ids, state, editMode, noSelect)
    local cols = getFlagCols()
    local sel  = {}
    for _, sid in ipairs(getSelection()) do sel[sid] = true end
    local all = #ids > 0 and not noSelect
    for _, oid in ipairs(ids) do
        if not sel[oid] then all = false end
    end
    if state == "shown" and all then state = "selected" end
    local act  = (state == "selected" and "hide") or (state == "shown" and (noSelect and "hide" or "select them")) or "show"
    local tint = (state == "selected" and ui.blue) or (state == "shown" and cols.on) or (state == "mixed" and cols.mixed) or cols.default
    local line = tr("%s: %s - click to %s", lookup(label), lookup(state), lookup(act))
    if not iconButton(id, iconName, label, tint, line) then return end
    if #ids == 0 then
        statusText = "nothing found"
        return
    end
    if act == "select them" then
        selectIds(ids)
        return
    end
    if act == "hide" then
        local drop = {}
        for _, oid in ipairs(ids) do drop[oid] = true end
        local rest = {}
        for _, sid in ipairs(getSelection()) do
            if not drop[sid] then rest[#rest + 1] = sid end
        end
        if #rest > 0 then editor.selectObjects(rest) else editor.clearObjectSelection() end
    end
    local hide = act == "hide"
    local n    = setHidden(ids, hide)
    statusText = hide and tr("%d objects hidden", n) or tr("%d objects shown", n)
    if not hide then enterEditMode(editMode) end
end

local function objName(id)
    local o = scenetree.findObjectById(id)
    return o and o:getName() or ""
end

local function builtObjects(ids)
    local out = {}
    for _, id in ipairs(ids) do
        if classOf(id) == "TSStatic" then
            local n = objName(id)
            if n:sub(1, #raPrefix) == raPrefix or n:sub(1, #geometry.mr.daePrefix) == geometry.mr.daePrefix then
                out[#out + 1] = n
            end
        end
    end
    table.sort(out)
    return out
end

local function sourcesFor(built)
    local key = table.concat(built, "|")
    if srcCache.key == key then return srcCache.ids, srcCache.note end
    local cells, ids, seen, note = {}, {}, {}, nil
    for _, n in ipairs(built) do
        if n:sub(1, #raPrefix) == raPrefix then
            local objs = roadArch.sourcesOf(n)
            if #objs == 0 then note = "Road Architect meshes are only known in the session that built them" end
            for _, o in ipairs(objs) do
                local id = o:getID()
                if not seen[id] then
                    seen[id]      = true
                    ids[#ids + 1] = id
                end
            end
        else
            cells[n:sub(#geometry.mr.daePrefix + 1)] = true
        end
    end
    if next(cells) then
        local all = findUnskinned("MeshRoad")
        for _, id in ipairs(findUnskinned("DecalRoad")) do all[#all + 1] = id end
        for _, id in ipairs(exporter.sourcesOfCells(all, cells)) do
            if not seen[id] then
                seen[id]      = true
                ids[#ids + 1] = id
            end
        end
    end
    srcCache = {key = key, ids = ids, note = note}
    return ids, note
end

local function drawBuiltSources(built)
    text("built objects", imgui.ImVec4(0.55, 0.75, 1, 1))
    local ids, note = sourcesFor(built)
    if note then text(note, imgui.ImVec4(0.6, 0.6, 0.6, 1)) end
    if #ids == 0 then
        text("no source roads found for this object", imgui.ImVec4(0.6, 0.6, 0.6, 1))
        return
    end
    textv(tr("built from %d objects", #ids))
    alignRight(iconRowWidth(1))
    visToggle("srcvis", iconOf.render, "source objects", ids, visState(ids), nil, true)
end

-- =============================================================================
-- COVERAGE UI
-- =============================================================================

local function drawVisRow()
    local groups = visGroups()
    alignRight(iconRowWidth(3))
    visToggle("vismesh", iconOf.selectMesh, "MeshRoad", groups.mesh.ids, groups.mesh.state, "meshRoadEditMode")
    imgui.SameLine()
    visToggle("visdecal", iconOf.selectDecals, "marked decals", groups.decal.ids, groups.decal.state, "roadEditMode")
    imgui.SameLine()
    visToggle("visall", iconOf.selectAll, "all marked objects", groups.all.ids, groups.all.state)
end

local function drawCoverage()
    if not section("tag coverage in the map", false) then return end

    alignRight(iconRowWidth(1))
    if iconButton("scan", iconOf.scan, "scan now") then
        scanCoverage()
    end

    if not coverage then
        text("the scan walks the whole map, so it only runs on click",
             imgui.ImVec4(0.6, 0.6, 0.6, 1))
        return
    end

    textv(tr("total: %d   untagged: %d", coverage.total, coverage.untagged))

    for _, axis in ipairs(allAxes) do
        local rows = {}
        for value, b in pairs(coverage[axis]) do
            rows[#rows + 1] = {value = value, n = b.n, ids = b.ids, known = b.known}
        end
        if #rows > 0 then
            table.sort(rows, function(a, b) return a.n > b.n end)
            textv(lookup(palette[axis].label) .. ":")
            for _, r in ipairs(rows) do
                alignRight(250)
                if imgui.Button(rtl("select") .. "##sel_" .. axis .. "_" .. r.value, imgui.ImVec2(56, 0)) then
                    selectIds(r.ids)
                end
                imgui.SameLine()
                imgui.TextColored(r.known and imgui.ImVec4(0.75, 0.75, 0.75, 1)
                                           or imgui.ImVec4(1, 0.45, 0.35, 1),
                                  string.format("%s = %s   %d", axis, r.value, r.n))
            end
        end
    end
end

-- =============================================================================
-- ROAD ARCHITECT
-- =============================================================================

local raSnap = imgui.BoolPtr(true)

local function drawRoadArchitect()
    ui.heading("Road Architect")
    text("finalise roads in Road Architect, then save them here as permanent objects",
         imgui.ImVec4(0.6, 0.6, 0.6, 1))
    raSnap[0] = roadArch.snap()
    if ui.checkPtr("rasnap", "snap to terrain", raSnap) then roadArch.setSnap(raSnap[0]) end
    tip("while Road Architect builds, the ground under each point is taken from the terrain,\n"
        .. "so objects under the sidewalk are ignored. objects more than 2 m above the terrain,\n"
        .. "like bridges, are kept. finalise the road again after changing this")
    local nRoads, nMeshes = roadArch.counts()
    textv(tr("captured this session: %d roads, %d meshes", nRoads, nMeshes))
    if ui.button("save Road Architect roads", "rabake") then
        statusText = roadArch.bake()
    end
end

-- =============================================================================
-- BUILDING ARCHITECT
-- =============================================================================

local function drawBuildingArchitect()
    ui.heading("Building Architect")
    text("finish the buildings in Building Architect, then save them here as permanent objects",
         imgui.ImVec4(0.6, 0.6, 0.6, 1))
    local n = buildArch.counts()
    if not n then
        text("Building Architect is not open", imgui.ImVec4(0.6, 0.6, 0.6, 1))
    else
        textv(tr("buildings in Building Architect: %d", n))
    end
    if ui.button("save Building Architect buildings", "batbake") then
        statusText = buildArch.bake()
    end
    tip("walls, roofs, windows and doors go into one DAE per building, with collision.\n"
        .. "the saved buildings leave Building Architect with their temporary windows,\n"
        .. "so nothing of them is saved twice with the map.\n"
        .. "Building Architect's materials are copied into the map under new names, unchanged")
end

-- =============================================================================
-- ADVANCED
-- =============================================================================

local function scaleHint(su, sv)
    local old   = ""
    local known = cfg and cfg.materials and cfg.materials[selectedMat]
    local sc    = known and known.scale
    if type(sc) == "table" and #sc >= 2 then
        old = tr("   (config now: %.2f x %.2f)", sc[1], sc[2])
    elseif type(sc) == "number" then
        old = tr("   (config now: %.2f)", sc)
    end
    return tr("U %.2f m/tile - %.1f tiles per 10 m along", su, 10.0 / su),
           tr("V %.2f m/tile - %.1f tiles per 10 m across%s", sv, 10.0 / sv, old)
end

local function drawAdvanced()
    if not section("add a material from the map", true) then return end

    text("add a material already in the map to the config", imgui.ImVec4(0.6, 0.6, 0.6, 1))

    local set = ensureMatSet()
    if #set == 0 then
        text("no materials found in the map", imgui.ImVec4(1, 0.45, 0.35, 1))
        return
    end

    imgui.PushID1("mageMatFilter")
    imgui.ImGuiTextFilter_Draw(matFilter, rtl("Search..."), 200)
    imgui.PopID()
    local opaque, likely = ui.markItem("opaqueonly", "solid materials only", opaqueOnly), ui.markItem("likelyonly", "likely candidates", likelyOnly)
    opaque.tip           = "keeps only materials that fully cover a surface.\n"
                 .. "hides alpha cutouts, glows and blended overlays.\n"
                 .. "solid decal roads stay."
    likely.tip = "narrows the list to paving and walling materials by name.\n"
                 .. "a suggestion, not a rule - switch it off to see everything."
    ui.row({opaque, likely})

    local hidden   = 0
    local narrowed = 0

    local function drawList()
        local rows = {}
        for i = 1, #set do
            local mat  = set[i]
            local name = mat:getName()
            local pass = name ~= ""
                                      and imgui.ImGuiTextFilter_PassFilter(matFilter, name)
            if pass and opaqueOnly[0] and not isSolidMaterial(mat, name) then
                pass   = false
                hidden = hidden + 1
            end
            local info = pass and candidateInfo(name) or nil
            if pass and likelyOnly[0] and not info then
                pass     = false
                narrowed = narrowed + 1
            end
            if pass then
                rows[#rows + 1] = {mat = mat, name = name, info = info}
            end
        end

        if likelyOnly[0] then
            table.sort(rows, function(a, b)
                if a.info.axis ~= b.info.axis then return a.info.axis < b.info.axis end
                if a.info.rank ~= b.info.rank then return a.info.rank < b.info.rank end
                return #a.name < #b.name
            end)
        end

        for _, row in ipairs(rows) do
            local name    = row.name
            local clicked = false
            local tex     = texFor(row.mat)
            if tex and tex.texId then
                clicked = imgui.ImageButton("##tex_" .. name, tex.texId, vec32)
                imgui.SameLine()
            end
            if imgui.Selectable1(name .. "##sel_" .. name, selectedMat == name) or clicked then
                selectedMat   = name
                asNewStyle[0] = false
                local known   = cfg and cfg.materials and cfg.materials[name]
                local sc      = known and known.scale
                if type(sc) == "table" and #sc >= 2 then
                    newScaleU[0], newScaleV[0] = sc[1], sc[2]
                elseif type(sc) == "number" then
                    newScaleU[0], newScaleV[0] = sc, sc
                end
                local existing, existingScale = nil, nil
                for _, ax in ipairs({"walk", "curb", "wall"}) do
                    local styles = cfg and cfg[ax] and cfg[ax].styles
                    if type(styles) == "table" then
                        for _, st in pairs(styles) do
                            if type(st) == "table" and st.material == name and st.label then
                                existing, existingScale = st.label, st.scale
                                break
                            end
                        end
                    end
                    if existing then break end
                end
                if type(existingScale) == "table" and #existingScale >= 2 then
                    newScaleU[0], newScaleV[0] = existingScale[1], existingScale[2]
                elseif type(existingScale) == "number" then
                    newScaleU[0], newScaleV[0] = existingScale, existingScale
                end
                bufWrite(labelBuf, existing or name)
                if row.info then newAxis[0] = (row.info.axis == "curb" and 0)
                                                                            or (row.info.axis == "wall" and 2) or 1 end
            end
            if row.info and likelyOnly[0] then
                imgui.SameLine()
                text("[" .. row.info.axis .. "]", imgui.ImVec4(0.45, 0.55, 0.45, 1))
            end
        end
    end

    imgui.BeginChild1("mageMatList", imgui.ImVec2(0, 180), true)
    local okList, listErr = pcall(drawList)
    imgui.EndChild()
    if not okList then
        matError = tostring(listErr)
    end
    if matError then
        textv(tr("list error: %s", matError), imgui.ImVec4(1, 0.45, 0.35, 1))
    end
    if hidden > 0 or narrowed > 0 then
        local parts = {}
        if hidden > 0 then parts[#parts + 1] = tr("%d transparent", hidden) end
        if narrowed > 0 then parts[#parts + 1] = tr("%d off-topic", narrowed) end
        textv(tr("%s hidden", table.concat(parts, ", ")), imgui.ImVec4(0.6, 0.6, 0.6, 1))
    end

    if not selectedMat then
        text("pick a material from the list", imgui.ImVec4(0.6, 0.6, 0.6, 1))
        return
    end

    imgui.Separator()
    imgui.TextUnformatted(selectedMat)

    local uses = {}
    if cfg then
        for _, ax in ipairs(allAxes) do
            local styles = cfg[ax] and cfg[ax].styles
            if type(styles) == "table" then
                for k, st in pairs(styles) do
                    if type(st) == "table" and (st.material == selectedMat
                       or (ax == "curb" and cfg.curb and cfg.curb.material == selectedMat
                           and st.sequence == nil)) then
                        uses[#uses + 1] = {axis = ax, key = k, label = st.label or k, scale = st.scale}
                    end
                end
            end
        end
    end

    if #uses > 0 then
        textv(#uses == 1 and tr("already used by 1 style:")
                          or tr("already used by %d styles:", #uses),
              imgui.ImVec4(1, 0.7, 0.2, 1))
        for _, u in ipairs(uses) do
            local sc = ""
            if type(u.scale) == "table" and #u.scale >= 2 then
                sc = string.format("   %.2f x %.2f", u.scale[1], u.scale[2])
            elseif type(u.scale) == "number" then
                sc = string.format("   %.2f", u.scale)
            end
            local line = visual(string.format("%s . %s   (%s)%s", u.axis, u.key, lookup(u.label), sc))
            if ui.row({ui.textItem(line, imgui.ImVec4(0.75, 0.75, 0.75, 1)), ui.btnItem("remove", "rm_" .. u.axis .. "_" .. u.key, nil, nil, 70)}) then
                removeStyleFromConfig(u.axis, u.key)
            end
        end
        ui.checkPtr("newstyle", "add as a new style", asNewStyle)
        tip("off: update the matching style in place.\n"
            .. "on: keep the existing one and add another, so the same\n"
            .. "material can appear at several scales.")
    end

    imgui.PushItemWidth(-1)
    imgui.InputText("##pitlabel", labelBuf, 64)
    imgui.PopItemWidth()
    text("display name - this is what appears on the palette button",
         imgui.ImVec4(0.5, 0.5, 0.5, 1))

    imgui.PushItemWidth(90)
    imgui.DragFloat(rtl("U##su"), newScaleU, 0.01, 0.05, 64.0, "%.2f")
    imgui.SameLine()
    imgui.DragFloat(rtl("V##sv"), newScaleV, 0.01, 0.05, 64.0, "%.2f")
    imgui.PopItemWidth()

    local hintU, hintV = scaleHint(newScaleU[0], newScaleV[0])
    text(hintU, imgui.ImVec4(0.5, 0.5, 0.5, 1))
    text(hintV, imgui.ImVec4(0.5, 0.5, 0.5, 1))

    ui.row({ui.markItem("axw", "top surface", newAxis, 1), ui.markItem("axc", "curb edge", newAxis, 0), ui.markItem("axwall", "MeshRoad wall", newAxis, 2)})

    if newAxis[0] == 0 then
        if curbUsesAtlas() then
            imgui.PushItemWidth(90)
            imgui.InputInt(rtl("band") .. "##curbband", newBand)
            imgui.PopItemWidth()
            if newBand[0] < 0 then newBand[0] = 0 end
            text("this map's curb material is an atlas, so a curb style selects a "
                 .. "band. The scale above is stored on the material only.",
                 imgui.ImVec4(0.5, 0.5, 0.5, 1))
        else
            text("this map's curb material has no atlas, so the scale above is "
                 .. "written into the curb style itself.",
                 imgui.ImVec4(0.5, 0.5, 0.5, 1))
        end
    end

    if newAxis[0] == 0 and cfg and cfg.curb and cfg.curb.material
          and cfg.curb.material ~= selectedMat then
        textv(tr("curb.material is %s - this style will be drawn with that material, not %s",
                 tostring(cfg.curb.material), selectedMat), imgui.ImVec4(1, 0.7, 0.2, 1))
        text("curb styles vary band or scale only. tick the box below to replace"
             .. " the map's kerb material instead", imgui.ImVec4(0.6, 0.6, 0.6, 1))
    end

    ui.checkPtr("ascurb", "also set as the map's curb material", alsoCurbMat)
    ui.checkPtr("asmesh", "also set as the map's MeshRoad material", alsoMeshMat)
    text("these write curb.material and meshroadMaterial, not a style. the first"
         .. " kerb or wall material added sets them automatically",
         imgui.ImVec4(0.5, 0.5, 0.5, 1))
    if cfg and cfg.curb then
        textv(tr("now: curb.material = %s   meshroadMaterial = %s",
                 tostring(cfg.curb.material or tr("(unset)")),
                 tostring(cfg.curb.meshroadMaterial or tr("(unset)"))),
             (cfg.curb.material and imgui.ImVec4(0.5, 0.5, 0.5, 1))
                                or imgui.ImVec4(1, 0.45, 0.35, 1))
    end

    alignRight(iconRowWidth(1))
    if iconButton("addmat", iconOf.addToConfig, "add to config") then
        local label = bufRead(labelBuf)
        if label == "" then label = selectedMat end
        local axis = "walk"
        if newAxis[0] == 0 then axis = "curb"
        elseif newAxis[0] == 2 then axis = "wall" end
        addMaterialToConfig(selectedMat, axis, newScaleU[0], newScaleV[0], label,
                            alsoCurbMat[0], alsoMeshMat[0], asNewStyle[0])
        alsoCurbMat[0], alsoMeshMat[0] = false, false
    end
end

-- =============================================================================
-- GATES
-- =============================================================================

local gateUi = {}

gateUi.order  = {"none", "round", "quarter_left", "quarter_right", "rect", "pointed"}
gateUi.labels = {
    none          = "no gate",
    round         = "round arch",
    quarter_left  = "quarter arch, left",
    quarter_right = "quarter arch, right",
    rect          = "square opening",
    pointed       = "pointed arch",
}
gateUi.iconOf  = {
    none          = "terrain_reall_smooth_new",
    round         = "terrain_reall_smooth_new",
    quarter_left  = "tb_left_curve_shorter",
    quarter_right = "tb_right_curve_shorter",
    rect          = "crop_portrait",
    pointed       = "roadOutline",
}
gateUi.nodeTol  = 0.01

function gateUi.nodePositions(id)
    local obj = scenetree.findObjectById(id)
    if not obj then return nil end
    local pts = {}
    for i = 0, obj:getNodeCount() - 1 do
        local p       = obj:getNodePosition(i)
        pts[#pts + 1] = vec3(p.x, p.y, p.z)
    end
    return pts
end

function gateUi.inMeshRoadEditor()
    local modes = editor.editModes
    return modes.meshRoadEditMode ~= nil and editor.editMode == modes.meshRoadEditMode
end

gateUi.lastSet    = {}
gateUi.lastSingle = {}

function gateUi.selectedNodes(pts, id)
    if not pts or not gateUi.inMeshRoadEditor() then return nil end
    local g   = editor.getAxisGizmoTransform():getColumn(3)
    local tol = 0.002
    local function avgIs(list)
        if #list == 0 then return false end
        local x, y, z = 0.0, 0.0, 0.0
        for _, i in ipairs(list) do x, y, z = x + pts[i].x, y + pts[i].y, z + pts[i].z end
        local n = #list
        return math.abs(x / n - g.x) < tol and math.abs(y / n - g.y) < tol and math.abs(z / n - g.z) < tol
    end
    local found
    for i = 1, #pts do
        if avgIs({i}) then found = {i} break end
    end
    local last = gateUi.lastSet[id]
    local function tryToggle()
        if found or not last then return end
        local valid = true
        for _, i in ipairs(last) do if not pts[i] then valid = false end end
        if valid and avgIs(last) then found = last end
        if valid and not found then
            local has = {}
            for _, i in ipairs(last) do has[i] = true end
            for k = 1, #pts do
                local list = {}
                for _, i in ipairs(last) do if i ~= k then list[#list + 1] = i end end
                if not has[k] then list[#list + 1] = k end
                table.sort(list)
                if avgIs(list) then found = list break end
            end
        end
    end
    local function tryRange()
        if found then return end
        local s0 = gateUi.lastSingle[id]
        local best
        for a = 1, #pts - 1 do
            local sx, sy, sz = pts[a].x, pts[a].y, pts[a].z
            for b = a + 1, #pts do
                sx, sy, sz = sx + pts[b].x, sy + pts[b].y, sz + pts[b].z
                local n    = b - a + 1
                if math.abs(sx / n - g.x) < tol and math.abs(sy / n - g.y) < tol and math.abs(sz / n - g.z) < tol then
                    local anchored = (s0 == a or s0 == b)
                    if not best or (anchored and not best.anchored) then best = {a = a, b = b, anchored = anchored} end
                end
            end
        end
        if best then
            found = {}
            for i = best.a, best.b do found[#found + 1] = i end
        end
    end
    if last and #last == 1 then
        tryRange()
        tryToggle()
    else
        tryToggle()
        tryRange()
    end
    if found and #found == 1 then gateUi.lastSingle[id] = found[1] end
    if found then gateUi.lastSet[id] = found end
    return found
end

function gateUi.roadGates(id)
    return gate.parse(dynValue(id, fieldOf.gates))
end

function gateUi.gateAt(gates, pts, i)
    for k, g in ipairs(gates) do
        if gate.nodeOf(pts, g) == i then return k end
    end
    return nil
end

function gateUi.writeGates(id, gates)
    editor.history:beginTransaction("MageGate")
    writeField(id, fieldOf.gates, gate.encode(gates))
    editor.history:endTransaction()
end

function gateUi.kindOf(g)
    if not g then return "none" end
    if g.style == "quarter" then return (g.dir == "right") and "quarter_right" or "quarter_left" end
    return g.style
end

function gateUi.nextKind(cur)
    for i, k in ipairs(gateUi.order) do
        if k == cur then return gateUi.order[i % #gateUi.order + 1] end
    end
    return gateUi.order[2]
end

function gateUi.setKind(g, kind)
    if kind == "quarter_left" or kind == "quarter_right" then
        g.style, g.dir = "quarter", (kind == "quarter_right") and "right" or "left"
    else
        g.style = kind
    end
end

gateUi.fieldDefs = {
    {key = "width", id = "gatewidth", dec = "gatedec", inc = "gateinc", label = "gate width",
     min = function() return gate.minWidth end, max = function() return gate.maxWidth end, default = function() return gate.defaultWidth end},
    {key = "top", id = "gatetop", dec = "gatetopdec", inc = "gatetopinc", label = "top of the opening below the top surface",
     min = function() return 0.0 end, max = function() return gate.maxOffset end, default = function() return gate.defaultTop end},
    {key = "sill", id = "gatesill", dec = "gatesilldec", inc = "gatesillinc", label = "bottom of the opening above the wall's base (0 = gate, more = window)",
     min = function() return 0.0 end, max = function() return gate.maxOffset end, default = function() return 0.0 end},
}

function gateUi.drawGateSettings(id, gates, ks)
    local g      = gates[ks[1]]
    local differ = false
    for _, k in ipairs(ks) do
        for _, f in ipairs(gateUi.fieldDefs) do
            if math.abs((gates[k][f.key] or f.default()) - (g[f.key] or f.default())) > 1e-6 then differ = true end
        end
    end
    if differ then
        text("values differ between the selected gates - showing the first", imgui.ImVec4(1, 0.7, 0.2, 1))
    end
    if ui.beginProps("gate") then
        for _, f in ipairs(gateUi.fieldDefs) do
            ui.prop(lookup(f.label))
            local v = ui.number(f.id, f.dec, f.inc, g[f.key] or f.default(), f.min(), f.max(), f.default())
            if v then
                for _, k in ipairs(ks) do gates[k][f.key] = v end
                gateUi.writeGates(id, gates)
                statusText = tr("%s set to %s on %d gates", lookup(f.label), string.format("%g", v), #ks)
            end
        end
        ui.endProps()
    end
    local values = {style = g.style, dir = g.dir, width = g.width, top = g.top or gate.defaultTop, sill = g.sill or 0.0}
    local auto   = string.format("%s %g/%g/%g", lookup(gateUi.labels[gateUi.kindOf(g)]), values.width, values.top, values.sill)
    presetUi.draw("gate", values, auto, function(v)
        for _, k in ipairs(ks) do
            local t = gates[k]
            for _, key in ipairs({"style", "dir", "width", "top", "sill"}) do
                if v[key] ~= nil then t[key] = v[key] end
            end
            local fixed = gate.parse(jsonEncode({t}))[1]
            if fixed then gates[k] = fixed end
        end
        gateUi.writeGates(id, gates)
    end)
end

function gateUi.drawGates(meshIds)
    if not fieldOf.gates then return end
    if not sectionv(lookup("gates"), true) then return end
    if #meshIds ~= 1 then
        text("select a single MeshRoad to add gates", imgui.ImVec4(0.6, 0.6, 0.6, 1))
        return
    end
    local id  = meshIds[1]
    local pts = gateUi.nodePositions(id)
    if not pts then return end
    local gates = gateUi.roadGates(id)
    local nodes = gateUi.selectedNodes(pts, id)

    if nodes then
        local moved = false
        for _, node in ipairs(nodes) do
            local k = gateUi.gateAt(gates, pts, node)
            if k then
                local g = gates[k]
                local p = pts[node]
                if math.abs(g.x - p.x) > 1e-3 or math.abs(g.y - p.y) > 1e-3 or math.abs(g.z - p.z) > 1e-3 or g.node ~= node - 1 then
                    g.x, g.y, g.z, g.node = p.x, p.y, p.z, node - 1
                    moved                 = true
                end
            end
        end
        if moved then gateUi.writeGates(id, gates) end

        local names = {}
        for _, node in ipairs(nodes) do names[#names + 1] = tostring(node - 1) end
        if #nodes == 1 then
            textv(tr("selected node: %d", nodes[1] - 1))
        else
            textv(tr("selected nodes: %s", table.concat(names, ", ")))
        end
        local cur
        for _, node in ipairs(nodes) do
            local k    = gateUi.gateAt(gates, pts, node)
            local kind = gateUi.kindOf(k and gates[k] or nil)
            if cur == nil then cur = kind elseif cur ~= kind then cur = "mixed" end
        end
        local nxt  = (cur == "mixed") and gateUi.order[2] or gateUi.nextKind(cur)
        local cols = getFlagCols()
        local tint = (cur == "none" and cols.default) or (cur == "mixed" and cols.mixed) or cols.on
        local line = tr("%s: %s - click for %s", lookup("gate"), lookup(gateUi.labels[cur] or "mixed"), lookup(gateUi.labels[nxt]))
        drawSlots({function()
            if iconButton("pitgate", gateUi.iconOf[cur] or gateUi.iconOf[nxt], "gate", tint, line) then
                for _, node in ipairs(nodes) do
                    local k = gateUi.gateAt(gates, pts, node)
                    local p = pts[node]
                    if nxt == "none" then
                        if k then table.remove(gates, k) end
                    else
                        if not k then
                            gates[#gates + 1] = {x = p.x, y = p.y, z = p.z, node = node - 1, width = gate.defaultWidth}
                            k                 = #gates
                        end
                        gateUi.setKind(gates[k], nxt)
                    end
                end
                gateUi.writeGates(id, gates)
                statusText = (nxt == "none") and tr("gates removed from %d nodes", #nodes)
                                              or tr("%s on %d nodes", lookup(gateUi.labels[nxt]), #nodes)
            end
        end})
        local ks = {}
        for _, node in ipairs(nodes) do
            local k = gateUi.gateAt(gates, pts, node)
            if k then ks[#ks + 1] = k end
        end
        if #ks > 0 then gateUi.drawGateSettings(id, gates, ks) end
        tip("the opening is centred on the node and measured from the wall's top surface and its base there")
    else
        text("select nodes in the Mesh Road Editor to put gates on them (ctrl or shift for several)", imgui.ImVec4(0.6, 0.6, 0.6, 1))
        if not gateUi.inMeshRoadEditor() and ui.button("open the Mesh Road Editor", "gateeditor") then
            enterEditMode("meshRoadEditMode")
        end
    end

    for k, g in ipairs(gates) do
        local i    = gate.nodeOf(pts, g)
        local kind = gateUi.kindOf(g)
        local line = i and tr("node %d: %s, %s m", i - 1, lookup(gateUi.labels[kind]), string.format("%g", g.width))
                        or tr("%s: its node was not found", lookup(gateUi.labels[kind]))
        if ui.row({ui.textItem(visual(line), (not i) and imgui.ImVec4(1, 0.7, 0.2, 1) or nil), ui.btnItem("x", "gatedel_" .. k)}) then
            table.remove(gates, k)
            gateUi.writeGates(id, gates)
            statusText = "gate removed"
            break
        end
    end
end

-- =============================================================================
-- MESHROAD WINDOWS
-- =============================================================================

local windowUi = {filter = imgui.ImGuiTextFilter(), line = {}}

windowUi.order  = {"round", "quarter_left", "quarter_right", "rect", "pointed"}
windowUi.labels = {
    round         = "round arch",
    quarter_left  = "quarter arch, left",
    quarter_right = "quarter arch, right",
    rect          = "square opening",
    pointed       = "pointed arch",
}
windowUi.faceLabels = {right = "right side", left = "left side", start = "start face", ["end"] = "end face"}
windowUi.rowFields  = {
    {key = "width",  label = "window length"},
    {key = "gap",    label = "gap length"},
    {key = "height", label = "window height"},
    {key = "sill",   label = "bottom of the window above the floor"},
}
windowUi.globalFields = {
    {key = "depth",    label = "depth into the wall (more than the wall = through)"},
    {key = "margin",   label = "margin at the ends of each face"},
    {key = "floorGap", label = "gap between windows above each other (for new ones)"},
}

function windowUi.read(id)
    return window.parse(dynValue(id, fieldOf.windows))
end

function windowUi.write(id, cfg)
    if cfg then table.sort(cfg.floors, function(a, b) return a.sill < b.sill end) end
    editor.history:beginTransaction("MageWindows")
    writeField(id, fieldOf.windows, cfg and window.encode(cfg) or "")
    editor.history:endTransaction()
end

function windowUi.number(id, cur, key)
    local lim = window.limits[key]
    return ui.number(id, id .. "dec", id .. "inc", cur, lim[1], lim[2], lim[3])
end

function windowUi.wallHeight(id)
    local obj = scenetree.findObjectById(id)
    local h   = math.huge
    for i = 0, obj:getNodeCount() - 1 do h = math.min(h, obj:getNodeDepth(i)) end
    return h
end

function windowUi.styleOptions(axis, all)
    local out = {}
    for _, e in ipairs(palette and palette[axis] and palette[axis].entries or {}) do
        if all or not e.isSequence then out[#out + 1] = e end
    end
    return out
end

function windowUi.options(empty, kind, all)
    local out  = {{label = lookup(empty)}}
    local axis = (kind == "roof") and "walk" or "wall"
    for _, e in ipairs(windowUi.styleOptions(axis, all)) do
        local st      = cfg and cfg[axis] and cfg[axis].styles and cfg[axis].styles[e.value]
        out[#out + 1] = {value = e.value, label = lookup(e.label), mat = type(st) == "table" and st.material or nil}
    end
    local batList = (kind == "roof") and buildArch.roofMaterials() or buildArch.wallMaterials()
    for _, name in ipairs(batList) do
        local copy    = buildArch.copyName(name)
        out[#out + 1] = {value = "@" .. copy, label = buildArch.labelOf(name), mat = copy, bat = name, group = "Building Architect"}
    end
    return out
end

function windowUi.moduleOptions(kind)
    local out = {{label = lookup((kind == "doors") and "no game door" or "no game window")}}
    for _, path in ipairs(modules.list(kind)) do out[#out + 1] = {value = path, label = modules.label(path)} end
    return out
end

function windowUi.nameOf(key, opts)
    for _, o in ipairs(opts) do
        if o.value == key then return o.label end
    end
    if key and key:sub(1, 1) == "@" then return buildArch.labelOf(key:sub(2)) end
    return key or opts[1].label
end

function windowUi.picker(id, label, cur, opts, shown)
    local gap   = imgui.GetStyle().ItemSpacing.x
    local lbl   = label and rtl(label) or ""
    local width = math.max(60, availWidth() - (label and (imgui.CalcTextSize(lbl).x + gap) or 0) - dimBtnW - gap)
    local items = {}
    if label then items[1] = ui.textItem(lbl) end
    items[#items + 1] = ui.btnItem(shown or windowUi.nameOf(cur, opts), id .. "_field", nil, nil, width)
    items[#items + 1] = ui.btnItem("...", id, nil, nil, dimBtnW)
    if ui.row(items) then imgui.OpenPopup(id .. "_popup") end
    if not imgui.BeginPopup(id .. "_popup") then return nil end
    imgui.PushID1(id .. "_filter")
    imgui.ImGuiTextFilter_Draw(windowUi.filter, rtl("Search..."), 240)
    imgui.PopID()
    local picked
    local group
    imgui.BeginChild1(id .. "_list", imgui.ImVec2(340, 300), true)
    for i, o in ipairs(opts) do
        if imgui.ImGuiTextFilter_PassFilter(windowUi.filter, o.label) then
            if o.group and o.group ~= group then
                group = o.group
                text(o.group, ui.blue)
            end
            local mat = o.mat and (scenetree.findObject(o.mat) or (o.bat and scenetree.findObject(o.bat)))
            local tex = mat and texFor(mat)
            local hit = false
            if tex and tex.texId then
                hit = imgui.ImageButton("##" .. id .. "_tex" .. i, tex.texId, vec32)
                imgui.SameLine()
            end
            if imgui.Selectable1(rtl(o.label) .. "##" .. id .. "_opt" .. i, o.value == cur) or hit then picked = o end
        end
    end
    imgui.EndChild()
    if picked then imgui.CloseCurrentPopup() end
    imgui.EndPopup()
    if not picked then return nil end
    if not picked.bat then return true, picked.value end
    local value = buildArch.use(picked.bat)
    if not value then return nil, "could not copy the material into the map" end
    return true, value
end

function windowUi.kindButton(id, f)
    local cols = getFlagCols()
    if not f then
        local line = tr("%s: %s", lookup("windows"), lookup(windowUi.labels.round))
        return iconButton(id, gateUi.iconOf.round, "window", cols.default, line) and "round" or nil
    end
    local cur = gateUi.kindOf(f)
    local nxt = windowUi.order[1]
    for i, k in ipairs(windowUi.order) do
        if k == cur then nxt = windowUi.order[i % #windowUi.order + 1] end
    end
    local line = tr("%s: %s - click for %s", lookup("window"), lookup(windowUi.labels[cur]), lookup(windowUi.labels[nxt]))
    return iconButton(id, gateUi.iconOf[cur], "window", cols.on, line) and nxt or nil
end

function windowUi.applyModule(fl, path)
    fl.dae     = path
    local w, h = modules.size(path or "")
    if w then
        fl.style, fl.width, fl.height = "rect", w, h
    end
end

function windowUi.lineLabel(fl)
    if fl.at then return lookup("door") end
    return tr("windows %s m above the floor", string.format("%g", fl.sill))
end

function windowUi.indexOf(cfg, fl)
    for k, f in ipairs(cfg.floors) do
        if f == fl then return k end
    end
    return nil
end

function windowUi.base(ids, id)
    local cfg = windowUi.read(id)
    if cfg then return cfg end
    for _, fid in ipairs(ids) do
        cfg = windowUi.read(fid)
        if cfg then return cfg end
    end
    return nil
end

function windowUi.inherit(cfg, base)
    if not base then return cfg end
    cfg.depth, cfg.margin, cfg.floorGap, cfg.modules = base.depth, base.margin, base.floorGap, base.modules
    cfg.faces, cfg.walls                             = {}, {}
    for _, k in ipairs(window.faceKeys) do
        cfg.faces[k] = base.faces[k]
        cfg.walls[k] = base.walls[k]
    end
    return cfg
end

function windowUi.writeAll(ids, fn)
    editor.history:beginTransaction("MageWindows")
    for _, fid in ipairs(ids) do
        local c = windowUi.read(fid)
        if c then
            fn(c)
            writeField(fid, fieldOf.windows, window.encode(c))
        end
    end
    editor.history:endTransaction()
end

function windowUi.pickLook(pid, ids, key, label, empty, kind)
    local cur, state = selectionValue(ids, fieldOf[key])
    local opts       = windowUi.options(empty, kind, true)
    ui.prop(lookup(label))
    local picked, value = windowUi.picker(pid, nil, cur, opts, (state == "mixed") and lookup("(mixed)") or nil)
    if picked then
        editor.history:beginTransaction("MageLook")
        for _, id in ipairs(ids) do writeField(id, fieldOf[key], value or "") end
        editor.history:endTransaction()
        statusText = tr("%s: %s", lookup(label), windowUi.nameOf(value, opts))
    elseif value then
        statusText = value
    end
end

function windowUi.drawFaces(ids, cfg)
    local items = {}
    local gap   = imgui.GetStyle().ItemSpacing.x
    local w     = math.floor((availWidth() - 3 * gap) / 4)
    for _, key in ipairs(window.faceKeys) do
        local on, name    = cfg.faces[key], lookup(windowUi.faceLabels[key])
        items[#items + 1] = ui.btnItem(windowUi.faceLabels[key], "winface_" .. key, on and ui.on or ui.off, on and ui.white or ui.grey, w)
        items[#items].tip = tr("%s: %s - click for %s", name, lookup(on and "on" or "off"), lookup(on and "off" or "on"))
    end
    local hit = ui.row(items)
    local key = hit and hit:sub(9)
    if not key then return end
    local on = cfg.faces[key]
    windowUi.writeAll(ids, function(c) c.faces[key] = not on end)
    statusText = tr("%s: %s", lookup(windowUi.faceLabels[key]), lookup((not on) and "on" or "off"))
end

function windowUi.drawGlobals(id, ids)
    local cfg = windowUi.base(ids, id)
    if not cfg then return end
    ui.heading(lookup((#ids > 1) and "windows and doors on all floors" or "windows and doors"))
    local changed, on = ui.check("winmodules", "windows and doors from the game", cfg.modules)
    tip("square openings get the game's own window or door, like Building Architect. off: only the openings")
    if changed then
        windowUi.writeAll(ids, function(c) c.modules = on end)
        statusText = on and "game windows on" or "game windows off"
    end
    windowUi.drawFaces(ids, cfg)

    if ui.beginProps("winglobal") then
        for _, f in ipairs(windowUi.globalFields) do
            ui.prop(lookup(f.label))
            local v = windowUi.number("win" .. f.key, cfg[f.key], f.key)
            if v then
                windowUi.writeAll(ids, function(c) c[f.key] = v end)
                statusText = tr("%s set to %s", lookup(f.label), string.format("%g", v))
            end
        end
        ui.endProps()
    end

    if section("texture per face", false) and ui.beginProps("winfaces") then
        for _, key in ipairs(window.faceKeys) do
            local face = lookup(windowUi.faceLabels[key])
            ui.prop(face)
            local opts          = windowUi.options("regular wall", "wall")
            local picked, value = windowUi.picker("winwall_" .. key, nil, cfg.walls[key], opts)
            tip("the config's wall materials or Building Architect's; the windows' own texture wins over its face's")
            if picked then
                windowUi.writeAll(ids, function(c) c.walls[key] = value end)
                statusText = tr("%s: %s", face, windowUi.nameOf(value, opts))
            elseif value then
                statusText = value
            end
        end
        ui.endProps()
    end
end

function windowUi.drawLine(id, cfg, k)
    local fl   = cfg.floors[k]
    local door = fl.at ~= nil
    local name = windowUi.lineLabel(fl)
    local nxt
    drawSlots({function() nxt = windowUi.kindButton("winstyle", fl) end})
    if ui.button(door and "remove the door" or "remove these windows", "winfloordel") then
        table.remove(cfg.floors, k)
        windowUi.write(id, (#cfg.floors > 0) and cfg or nil)
        statusText = door and "door removed" or "windows removed"
        return true
    end
    if nxt then
        gateUi.setKind(fl, nxt)
        if nxt ~= "rect" then fl.dae = nil end
        windowUi.write(id, cfg)
        statusText = tr("%s: %s", name, lookup(windowUi.labels[nxt]))
        return true
    end
    if not ui.beginProps("winline") then return false end
    local changed = false
    if cfg.modules and fl.style == "rect" then
        ui.prop(lookup(door and "game door" or "game window"))
        local opts          = windowUi.moduleOptions(door and "doors" or "windows")
        local picked, value = windowUi.picker("winmod", nil, fl.dae, opts)
        if picked then
            windowUi.applyModule(fl, value)
            statusText = tr("%s: %s", name, windowUi.nameOf(value, opts))
            changed    = true
        end
    end
    if door then
        ui.prop(lookup("door on"))
        local face = fl.face or "right"
        if ui.button(windowUi.faceLabels[face], "windoorface") then
            fl.face = (face == "right") and "left" or "right"
            changed = true
        end
        ui.prop(lookup("position along the face (0 = start, 1 = end)"))
        local v = ui.number("windoorat", "windoorat_dec", "windoorat_inc", fl.at, 0.0, 1.0, 0.5)
        if v then
            fl.at   = v
            changed = true
        end
    end
    local locked = cfg.modules and fl.dae ~= nil
    for _, f in ipairs(windowUi.rowFields) do
        local skip = (door and f.key == "gap") or (locked and (f.key == "width" or f.key == "height"))
        if not skip then
            ui.prop(lookup(f.label))
            local v = windowUi.number("win" .. f.key, fl[f.key], f.key)
            if v then
                fl[f.key]  = v
                changed    = true
                statusText = tr("%s set to %s", lookup(f.label), string.format("%g", v))
            end
        end
    end
    if locked then
        ui.prop(lookup("size"))
        textv(tr("%s x %s m, from the game's file", string.format("%g", fl.width), string.format("%g", fl.height)), ui.grey)
    end
    ui.prop(lookup("texture"))
    local opts          = windowUi.options("as the face", "wall")
    local picked, value = windowUi.picker("winwallf", nil, fl.wall, opts)
    tip("the config's wall materials or Building Architect's; the windows' own texture wins over its face's")
    if picked then
        fl.wall    = value
        changed    = true
        statusText = tr("%s: %s", name, windowUi.nameOf(value, opts))
    elseif value then
        statusText = value
    end
    ui.endProps()
    if changed then
        windowUi.write(id, cfg)
        return true
    end
    return false
end

function windowUi.drawAdd(id, cfg, wallH)
    local rows, hasDoor = {}, false
    for _, f in ipairs(cfg.floors) do
        if f.at then hasDoor = true else rows[#rows + 1] = f end
    end
    local list = {}
    if #rows > 0 then
        list[1], list[2] = {"add windows above", "winaddabove"}, {"add windows below", "winaddbelow"}
    end
    if not hasDoor then list[#list + 1] = {"add a door", "winadddoor"} end
    local hit = ui.buttons(list)
    if #rows > 0 then
        tip("new windows copy the windows next to them and go right above or below them, the gap between windows apart, then can be changed on their own")
    end
    local added, note
    if hit == "winaddabove" then
        local f = window.above(rows[#rows], cfg.floorGap)
        if window.fits(f, wallH) then added = f else note = "no room for windows above the highest ones" end
    elseif hit == "winaddbelow" then
        local f = window.below(rows[1], cfg.floorGap)
        if f then added = f else note = "no room for windows below the lowest ones" end
    elseif hit == "winadddoor" then
        added     = building.defaultWindows(true).floors[1]
        added.dae = cfg.modules and added.dae or nil
    end
    if note then statusText = note end
    if not added then return false end
    cfg.floors[#cfg.floors + 1] = added
    windowUi.write(id, cfg)
    windowUi.line[id] = windowUi.indexOf(cfg, added)
    statusText        = added.at and "door added" or "windows added"
    return true
end

function windowUi.drawLines(id, ids)
    local cfg = windowUi.read(id)
    if not cfg then
        text("no windows or doors on this floor yet", ui.grey)
        local nxt
        drawSlots({function() nxt = windowUi.kindButton("winnew", nil) end})
        if nxt then
            windowUi.write(id, windowUi.inherit(window.newConfig(nxt), windowUi.base(ids, id)))
            windowUi.line[id] = 1
            statusText        = "windows added"
        end
        tip("windows along the wall, sized like the game's Building Architect: 1.2 x 1.3 m, 0.5 m apart, 1 m above the floor")
        presetUi.draw("windows", window.newConfig("round"), lookup("windows"), function(v)
            local fixed = window.clean(v)
            if fixed then windowUi.write(id, fixed) end
        end)
        return
    end

    local wallH = windowUi.wallHeight(id)
    local sel   = math.min(windowUi.line[id] or 1, #cfg.floors)
    if ui.beginTable("winlines", {0.62, 0.38}, ui.rowBg) then
        for k = #cfg.floors, 1, -1 do
            local fl   = cfg.floors[k]
            local fits = window.fits(fl, wallH)
            ui.cells({
                function()
                    if not fits then imgui.PushStyleColor2(imgui.Col_Text, ui.orange) end
                    if imgui.Selectable1(ui.pad(rtl(windowUi.lineLabel(fl)), availWidth()) .. "##winline_" .. k, k == sel) then
                        sel, windowUi.line[id] = k, k
                    end
                    if not fits then imgui.PopStyleColor() end
                    if not fits and imgui.IsItemHovered() then
                        imgui.SetTooltip(rtl(lookup("does not fit in this floor's height")))
                    end
                end,
                function() drawText(string.format("%g x %g", fl.width, fl.height), ui.grey) end,
            })
        end
        imgui.EndTable()
    end
    if windowUi.drawAdd(id, cfg, wallH) then return end

    local fl = cfg.floors[sel]
    ui.heading(windowUi.lineLabel(fl))
    if windowUi.drawLine(id, cfg, sel) then
        windowUi.line[id] = windowUi.indexOf(cfg, fl) or 1
        return
    end

    local first = cfg.floors[1]
    local auto  = string.format("%s %g/%g/%g", lookup(windowUi.labels[gateUi.kindOf(first)]), first.width, first.height, cfg.depth)
    presetUi.draw("windows", cfg, auto, function(v)
        local fixed = window.clean(v)
        if fixed then windowUi.write(id, fixed) end
    end)
end

-- =============================================================================
-- BUILDINGS
-- =============================================================================

local buildingUi = {current = nil, folded = false}

function buildingUi.cameraSpot()
    local p = core_camera.getPosition()
    return vec3(p.x, p.y, p.z)
end

function buildingUi.create()
    local id = building.create(buildingUi.cameraSpot())
    if not id then
        statusText = "could not create the MeshRoad"
        return
    end
    buildingUi.current, buildingUi.folded = id, false
    editor.selectObjects({id})
    editor.setDirty()
    preview.renderSelection({id})
    statusText = "building created under the camera"
end

function buildingUi.createButton()
    local hit = ui.button("+  " .. lookup("create a building"), "bldcreate", ui.add)
    tip("one floor under the camera with the game's Building Architect defaults: 10 x 8 m, 3.2 m high,\n"
        .. "brick walls, a white roof, windows on every side and a door")
    if hit then buildingUi.create() end
end

function buildingUi.isOn(id)
    return building.dataOf(id) ~= nil or windowUi.read(id) ~= nil
end

function buildingUi.floorsOf(id)
    if not buildingUi.isOn(id) then return {} end
    local ids = building.chain(id)
    if #ids == 0 then ids = {id} end
    return ids
end

function buildingUi.setOn(id, on)
    editor.history:beginTransaction("MageBuilding")
    writeField(id, fieldOf.building, on and building.encode(building.newData(nil)) or "")
    if not on then writeField(id, fieldOf.windows, "") end
    editor.history:endTransaction()
    building.index(true)
    statusText = on and "objects on" or "objects off"
end

function buildingUi.drawFloors(id, ids)
    local pos = 1
    for k, fid in ipairs(ids) do
        if fid == id then pos = k end
    end
    if ui.beginTable("bldfloors", {0.3, 0.45, 0.25}, ui.rowBg) then
        ui.cells({
            function() drawText(rtl("floor"), ui.grey) end,
            function() drawText(rtl("MeshRoad"), ui.grey) end,
            function() drawText(rtl("height"), ui.grey) end,
        })
        for k = #ids, 1, -1 do
            local fid  = ids[k]
            local name = objName(fid)
            ui.cells({
                function()
                    local open = fid == id and not buildingUi.folded
                    if imgui.Selectable1(ui.pad(rtl(tr("floor %d", k)), availWidth()) .. "##bldfloor_" .. k, open) then
                        if fid == id then
                            buildingUi.folded = not buildingUi.folded
                        else
                            buildingUi.current, buildingUi.folded = fid, false
                            editor.selectObjects({fid})
                            statusText = tr("floor %d selected", k)
                        end
                    end
                end,
                function() drawText(name ~= "" and name or tostring(fid), ui.blue) end,
                function() drawText(string.format("%.2f m", building.height(fid)), ui.grey) end,
            })
        end
        imgui.EndTable()
    end
    if ui.button("+  " .. lookup("add a floor"), "bldaddfloor", ui.add) then
        local nid = building.addFloor(id)
        if nid then
            buildingUi.current, buildingUi.folded = nid, false
            editor.selectObjects({nid})
            editor.setDirty()
            preview.renderSelection(building.chain(nid))
            statusText = tr("floor %d added", #ids + 1)
        else
            statusText = "could not create the MeshRoad"
        end
    end
    tip("a new floor goes on top, a copy of the top floor without its door, its bottom held on the floor below.\n"
        .. "click a floor to open its settings, click it again to close them")
    return pos
end

function buildingUi.drawFloor(id, pos, ids)
    local b = building.dataOf(id)
    ui.heading(tr("floor %d", pos))
    if ui.beginProps("bldfloor") then
        ui.prop(lookup("floor height"))
        local h = ui.number("bldheight", "bldheightdec", "bldheightinc", building.height(id), 0.5, 100.0, building.defaults.floor)
        if h then
            building.setHeight(id, h)
            statusText = tr("floor height set to %s", string.format("%g", h))
        end
        if b and b.below then
            ui.prop(lookup("hold on the floor below"))
            local labels = {height = "height", path = "path", width = "width"}
            local list   = {}
            for _, key in ipairs(building.snapKeys) do list[#list + 1] = {"bldsnap_" .. key, labels[key], b.snap[key]} end
            local hit, v = ui.checks(list)
            if hit then
                local key   = hit:sub(9)
                b.snap[key] = v
                building.setData(id, b)
                statusText = tr("%s: %s", lookup(labels[key]), lookup(v and "on" or "off"))
            end
        end
        if #ids > 1 then windowUi.pickLook("bldwall", {id}, "wall", "walls of this floor", "the config's wall", "wall") end
        ui.endProps()
    end
    windowUi.drawLines(id, ids)
end

function buildingUi.draw(id)
    ui.heading(lookup("objects"))
    local on         = buildingUi.isOn(id)
    local changed, v = ui.check("bldon", "add objects (floors, windows, doors)", on)
    tip("off: a plain MeshRoad. turning it off removes this MeshRoad's windows, doors and floor link (ctrl+z brings them back)")
    if changed then buildingUi.setOn(id, v) end
    if not buildingUi.isOn(id) then return end
    local ids = buildingUi.floorsOf(id)
    windowUi.drawGlobals(id, ids)
    ui.heading(lookup("floors"))
    local pos = buildingUi.drawFloors(id, ids)
    if not buildingUi.folded then buildingUi.drawFloor(id, pos, ids) end
end

-- =============================================================================
-- WINDOW
-- =============================================================================

local function runUpdate(full)
    local ids    = findUnskinned("MeshRoad")
    local decals = findUnskinned("DecalRoad")
    for i = 1, #decals do ids[#ids + 1] = decals[i] end
    local status, ok = exporter.update(ids, full)
    statusText       = status or ""
    if ok then preview.clearPreview() end
end

local function toolbarSlots()
    local rendered = preview.renderedCount() > 0
    local live     = preview.isLive()
    return {
        function()
            if iconButton("pvconv", iconOf.markSidewalk, "apply the warning material") then
                statusText = preview.convertSelection() or ""
            end
        end,
        function()
            if rendered then
                if iconButton("pvrender", iconOf.clearPreview, "clear preview") then
                    preview.clearPreview()
                    statusText = "preview cleared"
                end
            elseif iconButton("pvrender", iconOf.render, "render selection") then
                statusText = preview.renderSelection() or ""
            end
        end,
        function()
            if not rendered then
                local w = iconSize()
                imgui.Dummy(imgui.ImVec2(w, 36 * imgui.uiscale[0] + 2 * imgui.GetStyle().FramePadding.y))
                return
            end
            local cols    = getFlagCols()
            local liveTip = tr("%s: %s - click for %s", lookup("auto refresh"),
                               lookup(live and "on" or "off"), lookup(live and "off" or "on"))
            if iconButton("pvlive", iconOf.autoRefresh, "auto refresh", live and cols.on or cols.default, liveTip) then
                preview.setLive(not live)
                statusText = (not live) and "auto refresh on" or "auto refresh off"
            end
        end,
        function()
            if iconButton("pvupdate", iconOf.update, "update objects") then runUpdate(false) end
        end,
        function()
            if iconButton("pvrebuild", iconOf.rebuild, "rebuild all objects") then runUpdate(true) end
        end,
        function()
            if iconButton("reload", iconOf.reload, "reload config") then
                loadConfig()
                coverage = nil
                preview.loadStyles()
                statusText = cfgError and tr("error: %s", tr(cfgError)) or "config loaded"
            end
        end,
        function()
            if allOpen then
                if iconButton("openall", iconOf.collapse, "collapse all") then
                    allOpen, sectionForce = false, false
                end
            elseif iconButton("openall", iconOf.expand, "expand all") then
                allOpen, sectionForce = true, true
            end
        end,
    }
end

local function drawStatus()
    if preview.renderedCount() > 0 then
        if preview.isLive() then
            textv(tr("auto: %d of %d rendered", preview.renderedCount(), preview.liveMaxRoads()),
                  imgui.ImVec4(0.4, 1, 0.4, 1))
        end
        text("preview only - it is not saved with the map.", imgui.ImVec4(0.5, 0.5, 0.5, 1))
    end
    if statusText ~= "" then
        text(statusText, imgui.ImVec4(0.4, 1, 0.4, 1))
    end
end

local function drawConfigProblem()
    if cfgMissing then
        text("no config in this level yet", imgui.ImVec4(0.8, 0.8, 0.8, 1))
        textv(cfgPath ~= "" and cfgPath or configName, imgui.ImVec4(0.6, 0.6, 0.6, 1))
        text("create one from the starter set, then adjust it under 'advanced'",
             imgui.ImVec4(0.6, 0.6, 0.6, 1))
        alignRight(iconRowWidth(1))
        if iconButton("mkcfg", iconOf.createConfig, "create config") then
            createEmptyConfig()
        end
        drawAdvanced()
    else
        textv(tr("config not loaded: %s", tr(tostring(cfgError))), imgui.ImVec4(1, 0.45, 0.35, 1))
        textv(cfgPath ~= "" and cfgPath or configName, imgui.ImVec4(0.6, 0.6, 0.6, 1))
        text("fix or delete the file - nothing is written while it is unreadable",
             imgui.ImVec4(0.6, 0.6, 0.6, 1))
    end
end

local tabUi = {}

function tabUi.selectionInfo()
    local ids               = getSelection()
    local decalIds, meshIds = {}, {}
    for i = 1, #ids do
        local cls = classOf(ids[i])
        if cls == "DecalRoad" then decalIds[#decalIds + 1] = ids[i] end
        if cls == "MeshRoad" then meshIds[#meshIds + 1] = ids[i] end
    end
    return {ids = ids, decalIds = decalIds, meshIds = meshIds, built = builtObjects(ids)}
end

function tabUi.drawNoConfig()
    text("the styles config is not loaded - see the settings tab", ui.orange)
end

function tabUi.drawSidewalkTab(sel)
    if not palette then return tabUi.drawNoConfig() end
    if cfgEmpty then
        text("this config has no styles yet - fill it from the starter set or add materials in the settings tab", ui.orange)
        alignRight(iconRowWidth(1))
        if iconButton("mkstarter", iconOf.createConfig, "fill from the starter set") then fillFromStarter() end
    end
    local decalIds = sel.decalIds
    if #decalIds == 0 then
        text("select DecalRoads with the warning material in the SceneTree to make sidewalks and islands from them", ui.grey)
    else
        textv(tr("selected DecalRoads: %d", #decalIds))
        presetUi.drawCopy(decalIds)
        for _, ax in ipairs(decalAxes) do drawAxis(ax, decalIds) end
    end
    drawCoverage()
end

function tabUi.drawMeshList(meshIds)
    if #meshIds == 1 then
        local name = objName(meshIds[1])
        textv(name ~= "" and name or tostring(meshIds[1]), ui.blue)
        return
    end
    textv(tr("selected MeshRoads: %d", #meshIds))
    if not imgui.BeginTable("meshsel", 1) then return end
    for k, id in ipairs(meshIds) do
        imgui.TableNextRow()
        imgui.TableNextColumn()
        if k > 8 then
            textv(tr("and %d more", #meshIds - 8), ui.grey)
            break
        end
        local name = objName(id)
        imgui.TextUnformatted(name ~= "" and name or tostring(id))
    end
    imgui.EndTable()
end

function tabUi.drawMeshTab(sel)
    if not palette then return tabUi.drawNoConfig() end
    buildingUi.createButton()
    local meshIds = sel.meshIds
    if #meshIds == 0 and #sel.ids == 0 and buildingUi.current and scenetree.findObjectById(buildingUi.current) then
        meshIds = {buildingUi.current}
    end
    if #meshIds == 0 then
        text("select MeshRoads with the warning material in the SceneTree to give them walls, a top surface, bridges, battlements, gates, windows and floors", ui.grey)
        return
    end
    if #meshIds == 1 and meshIds[1] ~= buildingUi.current then
        buildingUi.current, buildingUi.folded = meshIds[1], false
    end
    tabUi.drawMeshList(meshIds)
    presetUi.drawCopy(meshIds)

    local slots = {}
    for _, ax in ipairs(mrAxes) do
        if flagIcons[ax] and palette[ax] and fieldOf[ax] then slots[#slots + 1] = flagSlot(ax, meshIds) end
    end
    if #geometry.features > 0 then slots[#slots + 1] = featureSlot(meshIds) end
    drawSlots(slots)

    local single = (#meshIds == 1) and meshIds[1] or nil
    local floors = single and buildingUi.floorsOf(single) or {}
    local all    = #floors > 1
    local ids    = all and floors or meshIds
    if ui.beginProps("meshlook") then
        windowUi.pickLook("lookwall", ids, "wall", all and "walls of all floors" or "walls", "the config's wall", "wall")
        windowUi.pickLook("lookwalk", ids, "walk", all and "top surface of all floors" or "top surface", "the config's top surface", "roof")
        ui.endProps()
    end
    for _, ax in ipairs(mrAxes) do
        if not flagIcons[ax] and ax ~= "wall" then drawAxis(ax, meshIds) end
    end
    drawAxis("profile", meshIds)

    if single then buildingUi.draw(single) end

    local cur = selectionFeature(meshIds)
    if cur ~= "none" and cur ~= "mixed" then drawFeaturePanel(meshIds, cur) end
    gateUi.drawGates(meshIds)
    priorityUi.drawPriority(meshIds)
end

function tabUi.drawImportTab()
    drawRoadArchitect()
    drawBuildingArchitect()
end

function tabUi.drawSettingsTab()
    if not palette then
        drawConfigProblem()
        return
    end
    ui.heading("styles config")
    textv(cfgPath ~= "" and cfgPath or configName, ui.grey)
    if cfgEmpty then
        alignRight(iconRowWidth(1))
        if iconButton("mkstarter2", iconOf.createConfig, "fill from the starter set") then fillFromStarter() end
    end
    drawAdvanced()
end

tabUi.list = {
    {key = "sidewalks", label = "sidewalks", draw = tabUi.drawSidewalkTab},
    {key = "meshes",    label = "MeshRoads", draw = tabUi.drawMeshTab},
    {key = "import",    label = "import",    draw = tabUi.drawImportTab},
    {key = "settings",  label = "settings",  draw = tabUi.drawSettingsTab},
}

function tabUi.drawTabs(sel)
    if rtlLayout then
        local st, total = imgui.GetStyle(), 0
        for k, t in ipairs(tabUi.list) do
            total = total + imgui.CalcTextSize(rtl(t.label)).x + 2 * st.FramePadding.x + ((k > 1) and st.ItemInnerSpacing.x or 0)
        end
        local offset = availWidth() - total - 4
        if offset > 0 then imgui.SetCursorPosX(imgui.GetCursorPosX() + offset) end
    end
    if not imgui.BeginTabBar("magetabs") then return end
    local first, last, step = 1, #tabUi.list, 1
    if rtlLayout then first, last, step = #tabUi.list, 1, -1 end
    for k = first, last, step do
        local t = tabUi.list[k]
        if imgui.BeginTabItem(rtl(t.label) .. "##tab_" .. t.key) then
            imgui.BeginChild1("magebody_" .. t.key, imgui.ImVec2(0, 0), true)
            t.draw(sel)
            imgui.EndChild()
            imgui.EndTabItem()
        end
    end
    imgui.EndTabBar()
end

function tabUi.drawTools()
    local st = imgui.GetStyle()
    local rh = 36 * imgui.uiscale[0] + 2 * st.FramePadding.y
    imgui.BeginChild1("magetools", imgui.ImVec2(0, 2 * rh + st.ItemSpacing.y + 2 * st.WindowPadding.y + 2), true)
    drawSlots(toolbarSlots())
    drawVisRow()
    imgui.EndChild()
end

local function onEditorGui()
    texBudget = 0
    rtlLayout = layout.rtlConfig or isRtlText(lookup("sidewalks"))
    batFix.attach()
    roadArch.install()
    preview.refreshLive()
    building.sync()
    ensureRegistered()
    if not editor.isWindowVisible(toolWindowName) then return end

    if editor.beginWindow(toolWindowName, rtl("MaGE - Map Geometry Engine")) then
        ui.pushTheme()
        tabUi.drawTools()
        drawStatus()
        local sel = tabUi.selectionInfo()
        if #sel.built > 0 then drawBuiltSources(sel.built) else srcCache.key = nil end
        tabUi.drawTabs(sel)
        ui.popTheme()
    end
    editor.endWindow()
    sectionForce = nil
end

ensureRegistered = function()
    if registered then return end
    editor.registerWindow(toolWindowName, imgui.ImVec2(380, 560))
    editor.addWindowMenuItem(rtl("Map Geometry Engine"), function()
        editor.showWindow(toolWindowName)
    end, {groupMenuName = "MaGE"})
    registered = true
end

-- =============================================================================
-- LIFECYCLE
-- =============================================================================

local function onEditorInitialized()
    ensureRegistered()
    loadConfig()
end

local function onEditorAfterOpenLevel()
    roadArch.reset()
    buildArch.reset()
    building.reset()
    visCache, srcCache            = {at = -1}, {key = nil}
    matSet, texCache, selectedMat = nil, {}, nil
    preview.afterOpenLevel()
    loadConfig()
    coverage   = nil
    statusText = ""
end

local function open()
    ensureRegistered()
    matClassCache = {}
    if not palette then loadConfig() end
    editor.showWindow(toolWindowName)
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.onEditorInspectorFieldChanged = preview.fieldChanged
M.onEditorGui                   = onEditorGui
M.onEditorInitialized           = onEditorInitialized
M.onEditorAfterOpenLevel        = onEditorAfterOpenLevel
M.onClientEndMission            = preview.endMission
M.onEditorBeforeSaveLevel       = preview.beforeSave
M.onEditorAfterSaveLevel        = preview.afterSave
M.open                          = open
M.onExtensionUnloaded           = function()
    batFix.detach()
    roadArch.uninstall()
    preview.clearPreview()
end

return M
