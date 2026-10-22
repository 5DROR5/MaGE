-- =============================================================================
-- MaGE - Map Geometry Engine
-- Version: 1.0.2
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
local town      = require('editor/mage/modules/Town')
local exchange  = require('editor/mage/modules/Exchange')
local modules   = require('editor/mage/core/Modules')
local trims     = require('editor/mage/core/Trims')
local settings  = require('editor/mage/config/Settings')
local texture   = require('editor/mage/core/Texture')
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

local consts = {}

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
    up           = "arrow_upward",
    down         = "arrow_downward",
    remove       = "delete",
    sidewalks    = "roadSidewalkTransition",
    meshes       = "create_road_mesh",
    buildings    = "domain",
    coverage     = "data_usage",
    import       = "import",
    settings     = "settings",
    newBuilding  = "mage.create_building",
    addFloor     = "mage.add_floor",
    pushWall     = "mage.push_wall",
    addUnit      = "mage.add_unit",
    movePart     = "open_with",
    pickWorld    = "touch_app",
    unpick       = "highlight_off",
    focus        = "center_focus_weak",
    multi        = "done_all",
    help         = "help_outline",
    saved        = "collections_bookmark",
    place        = "location_city",
    random       = "casino",
    turnLeft     = "rotate_left",
    turnRight    = "rotate_right",
    addRoads     = "add_location",
    fill         = "timeline",
    fillAll      = "public",
    exportBones  = "file_upload",
    exportDae    = "archive",
    importPlace  = "get_app",
    toSaved      = "playlist_add",
    folder       = "folder_open",
    opened       = "keyboard_arrow_down",
    closed       = "keyboard_arrow_right",
    stop         = "stop",
    seed         = "shuffle",
    addWindows   = "add_box",
    rowAbove     = "publish",
    rowBelow     = "get_app",
    door         = "mage.door_leaf",
    doorHole     = "mage.door_hole",
    backHall     = "mage.back_hall",
    winNone      = "mage.win_none",
    winHole      = "mage.win_hole",
    winGlass     = "mage.win_glass",
    copy         = "content_copy",
    paste        = "content_paste",
    save         = "save",
    restore      = "restore",
    auto         = "brightness_auto",
    clear        = "format_clear",
    select       = "select_all",
    rename       = "edit",
    meshEditor   = "roadEditSolid",
    link         = "link",
    unlink       = "unlink",
    addOpening   = "mage.add_opening",
    through      = "mage.open_through",
    niche        = "mage.open_niche",
    nicheRight   = "mage.niche_right",
    nicheLeft    = "mage.niche_left",
    nicheStart   = "mage.niche_start",
    nicheEnd     = "mage.niche_end",
    tunnel       = "mage.tunnel",
    openOne      = "mage.open_one",
    openRow      = "mage.open_row",
    alignStart   = "mage.align_start",
    alignCenter  = "mage.align_center",
    alignEnd     = "mage.align_end",
    spaceGap     = "mage.space_gap",
    spaceCount   = "mage.space_count",
    newShape     = "mage.create_shape",
    roofGable    = "mage.roof_gable",
    roofHip      = "mage.roof_hip",
    roofShedL    = "mage.roof_shed_left",
    roofShedR    = "mage.roof_shed_right",
    shape        = {circle = "mage.shape_circle", ellipse = "mage.shape_ellipse", rectangle = "mage.shape_rectangle", polygon = "mage.shape_hexagon"},
    front        = {rect = "mage.front_rect", arc = "mage.front_arc"},
    mods         = {windows = "mage.win_glass", doors = "mage.door_leaf", balcony = "mage.balcony", stairs = "mage.stairs", pillar = "mage.pillars",
                    corner = "mage.corners", pilaster = "mage.pilasters", plinth = "mage.plinth", course = "mage.course",
                    roofborder = "mage.roofborder", roof = "mage.roof_gable", gutter = "mage.gutter", ac = "ac_unit", dish = "satellite",
                    awning = "beach_access", flowers = "local_florist", pots = "nature", roofac = "toys", roofdish = "settings_input_antenna",
                    corbel = "vertical_align_top", pipe = "invert_colors"},
}

consts.profileStyles = {
    walk   = {label = "sidewalk",       color = {0.45, 0.60, 0.80}, weight = 2},
    island = {label = "traffic island", color = {0.75, 0.55, 0.35}, weight = 1},
}

consts.flagIcons = {
    bottom = iconOf.bottom,
    roll   = iconOf.roll,
    ends   = iconOf.ends,
}

consts.defaultFlagStyles = {
    on  = {label = "on",  color = {0.35, 0.70, 0.40}, weight = 2},
    off = {label = "off", color = {0.55, 0.55, 0.55}, weight = 1},
}

consts.decalAxes = {"curb", "walk", "profile"}
consts.mrAxes    = {"wall", "bottom", "roll", "ends"}
consts.allAxes   = {"curb", "walk", "profile", "wall", "bottom", "roll", "ends"}

for _, f in ipairs(geometry.features) do
    consts.allAxes[#consts.allAxes + 1] = f.key
end

consts.mirrorMap = {
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
local layout       = {rtlConfig = false, cache = {}, n = 0, rtlCache = {}, rtlCacheN = 0, visualCache = {}, visualCacheN = 0}

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
        local m = consts.mirrorMap[rev[k]]
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
    local cached = layout.visualCache[s]
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

    layout.visualCacheN = layout.visualCacheN + 1
    if layout.visualCacheN > 512 then
        layout.visualCache  = {}
        layout.visualCacheN = 0
    end
    layout.visualCache[s] = result
    return result
end

local function rtl(s)
    if s == nil or s == "" then return s end
    local cached = layout.rtlCache[s]
    if cached then return cached end

    local label, idPart = s, ""
    local p             = s:find("##", 1, true)
    if p then
        label  = s:sub(1, p - 1)
        idPart = s:sub(p)
    end

    local result = visual(lookup(label) .. idPart)

    layout.rtlCacheN = layout.rtlCacheN + 1
    if layout.rtlCacheN > 512 then
        layout.rtlCache  = {}
        layout.rtlCacheN = 0
    end
    layout.rtlCache[s] = result
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

local readJson   = common.readJson
local readStyles = common.readStyles

local function color4(c, alpha)
    if c then
        return imgui.ImVec4(c[1], c[2], c[3], alpha or 1)
    end
    return imgui.ImVec4(0.35, 0.38, 0.45, alpha or 1)
end

local function luminance(c)
    if not c then return 0.35 end
    return 0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3]
end

local function buildAxis(styles, axis)
    local out = {}
    for name, st in pairs(styles or {}) do
        out[#out + 1] = {
            value      = name,
            label      = st.label or name,
            color      = st.color,
            band       = st.band,
            weight     = st.weight or 0,
            isSequence = st.sequence ~= nil,
        }
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
    return mat ~= nil and mat.atlas ~= nil
end

local function legacyLabel(label)
    if label == "walk centre" then return "top surface" end
    return label
end

local function loadConfigData()
    layout.rtlCache        = {}
    layout.rtlCacheN       = 0
    layout.visualCache     = {}
    layout.visualCacheN    = 0
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

    local data = readStyles(cfgPath)
    if not data and not common.fileExists(cfgPath) then
        local old = readStyles(dir .. common.legacyStyleFile)
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
    for _, ax in ipairs(consts.allAxes) do
        fieldOf[ax] = common.fieldName((axes[ax] or {}).field or (prefix .. ax))
    end
    fieldOf.priority = common.fieldName((axes.priority or {}).field or (prefix .. "priority"))
    fieldOf.gates    = common.fieldName((axes.gates or {}).field or (prefix .. "gates"))
    fieldOf.windows  = common.fieldName((axes.windows or {}).field or (prefix .. "windows"))
    fieldOf.building = common.fieldName((axes.building or {}).field or (prefix .. "building"))
    fieldOf.over     = common.fieldName((axes.over or {}).field or (prefix .. "over"))
    fieldOf.curbdims = common.fieldName((axes.curbdims or {}).field or (prefix .. "curbdims"))
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
            entries = buildAxis((data.profile or {}).styles or consts.profileStyles, "profile"),
        },
        wall = {
            label   = (axes.wall or {}).label or "MeshRoad material",
            entries = buildAxis((data.wall or {}).styles, "wall"),
        },
        bottom = {
            label   = (axes.bottom or {}).label or "bottom faces",
            entries = buildAxis(consts.defaultFlagStyles, "bottom"),
        },
        roll = {
            label   = (axes.roll or {}).label or "banking from nodes",
            entries = buildAxis(consts.defaultFlagStyles, "roll"),
        },
        ends = {
            label   = (axes.ends or {}).label or "end curbs",
            entries = buildAxis(consts.defaultFlagStyles, "ends"),
        },
    }
    for _, f in ipairs(geometry.features) do
        palette[f.key] = {
            label   = (axes[f.key] or {}).label or f.label,
            entries = buildAxis(consts.defaultFlagStyles, f.key),
        }
    end

    cfgEmpty = (#palette.curb.entries == 0 and #palette.walk.entries == 0
                and #palette.wall.entries == 0)

    for _, ax in ipairs(consts.allAxes) do
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

local matUi = {
    matFilter     = imgui.ImGuiTextFilter(),
    texCache      = {},
    texBudget     = 0,
    opaqueOnly    = imgui.BoolPtr(true),
    likelyOnly    = imgui.BoolPtr(false),
    asNewStyle    = imgui.BoolPtr(false),
    matClassCache = {},
    newScaleU     = imgui.FloatPtr(2.5),
    newScaleV     = imgui.FloatPtr(2.5),
    newBand       = imgui.IntPtr(0),
    newAxis       = imgui.IntPtr(1),
    alsoCurbMat   = imgui.BoolPtr(false),
    alsoMeshMat   = imgui.BoolPtr(false),
    labelBuf      = imgui.ArrayChar(64),
}

local selectedMat = nil

local function bufRead(arr)
    return ffi.string(arr)
end

local function bufWrite(arr, str)
    ffi.copy(arr, tostring(str or ""):sub(1, imgui.ArraySize(arr) - 1))
end

consts.vec32 = imgui.ImVec2(32, 32)
consts.vec40 = imgui.ImVec2(40, 40)

local function ensureMatSet()
    if matUi.matSet then return matUi.matSet end
    matUi.matSet = {}
    local set    = Sim.getMaterialSet()
    for i = 0, set:size() - 1 do
        matUi.matSet[#matUi.matSet + 1] = set:at(i)
    end
    return matUi.matSet
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
        if not mat.getPath then return nil end
        abs = mat:getPath() .. img
    end
    if matUi.texCache[abs] == nil and matUi.texBudget < 5 then
        matUi.texBudget     = matUi.texBudget + 1
        local tex           = editor.texObj(abs)
        matUi.texCache[abs] = (tex and tex.texId) and tex or false
    end
    return matUi.texCache[abs] or nil
end

local function matOpacityClass(mat)
    return texture.opacity(function(k) return matField(mat, k, 0) end)
end

local function matClass(mat, name)
    local c = matUi.matClassCache[name]
    if c == nil then
        c                         = matOpacityClass(mat)
        matUi.matClassCache[name] = c
    end
    return c
end

local function isSolidMaterial(mat, name)
    return matClass(mat, name) == "opaque"
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
    return mat ~= nil and mat.atlas ~= nil
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

consts.starterDir      = "/lua/ge/extensions/editor/mage/config/starter/"
consts.starterMats     = "mage.materials.json"
consts.starterSections = {"defaultScale", "materials", "atlases", "curb", "walk", "wall", "profile"}

local function starterConfigData()
    local data    = emptyConfigData()
    local starter = readStyles(consts.starterDir .. configName)
    if not starter then return data, false end
    for _, k in ipairs(consts.starterSections) do
        if starter[k] ~= nil then data[k] = starter[k] end
    end
    return data, true
end

local function installStarter(dir)
    if not dir then return false end
    local target = dir .. geometry.mr.daeDir .. consts.starterMats
    if not common.fileExists(target) then
        local text = readFile(consts.starterDir .. consts.starterMats)
        if type(text) ~= "string" or text == "" then return false end
        if not writeFile(target, text) then return false end
    end
    local defs    = readJson(target)
    local missing = false
    if defs then
        for name in pairs(defs) do
            if not scenetree.findObject(name) then missing = true end
        end
    end
    if missing then loadJsonMaterialsFile(target) end
    return true
end

local function styleCount(section)
    local n = 0
    for _ in pairs(section and section.styles or {}) do n = n + 1 end
    return n
end

local function fillFromStarter()
    local data = readStyles(cfgPath)
    if not data then
        statusText = "cannot read the config"
        return false
    end
    local starter = readStyles(consts.starterDir .. configName)
    if not starter then
        statusText = "the starter set is missing from the mod"
        return false
    end
    for _, k in ipairs({"curb", "walk", "wall"}) do
        if starter[k] ~= nil and styleCount(data[k]) == 0 then data[k] = starter[k] end
    end
    data.materials = data.materials or {}
    for name, m in pairs(starter.materials or {}) do
        if data.materials[name] == nil then data.materials[name] = m end
    end
    if data.atlases == nil then data.atlases = starter.atlases end
    if not commitConfig(data) then return false end
    local matsOk = installStarter(levelDir())
    matUi.matSet = nil
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
    local matsOk = starter and installStarter(levelDir())
    matUi.matSet = nil
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
    for _, ax in ipairs(consts.allAxes) do
        for k, st in pairs((data[ax] or {}).styles or {}) do
            if not (ax == skipAxis and k == skipKey) and st.material == matName then return true end
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
    local hist    = curb[histKey] or {}
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
    local hist    = curb[histKey] or {}
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

local function removeStyle(axis, key)
    local data = readStyles(cfgPath)
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
    for _, ax in ipairs(consts.allAxes) do
        for _, other in pairs((data[ax] or {}).styles or {}) do
            for i = #(other.sequence or {}), 1, -1 do
                if other.sequence[i] == key then
                    table.remove(other.sequence, i)
                    unlinked = unlinked + 1
                end
            end
        end
    end

    local restored = {}
    if matName then
        local usedByStyle = false
        for _, ax in ipairs(consts.allAxes) do
            for _, other in pairs((data[ax] or {}).styles or {}) do
                if other.material == matName then usedByStyle = true end
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
    local data = readStyles(cfgPath)
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
    texture.pinDefault(data, axis)

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
            style.band  = matUi.newBand[0]
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
                        label, matName, axis, matUi.newBand[0], key)
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

local trial = {map = nil}

local function dynValue(id, fieldName)
    local over = trial.map and trial.map[id]
    if over and over[fieldName] ~= nil then return (over[fieldName] ~= "") and over[fieldName] or nil end
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
    if trial.map then
        trial.map[id]            = trial.map[id] or {}
        trial.map[id][fieldName] = value
        return
    end
    local legacy = common.legacyField(fieldName)
    common.setDynWithUndo({id}, fieldName, value)
    if legacy and dynValue(id, legacy) then common.setDynWithUndo({id}, legacy, "") end
end

local function transaction(name, fn)
    if trial.map then return fn() end
    common.transaction(name, fn)
end

local function dirty()
    if not trial.map then editor.setDirty() end
end

local function applyValue(fieldName, value, idsIn)
    local ids = idsIn or getSelection()
    if #ids == 0 then
        statusText = "nothing selected"
        return
    end

    transaction("MageTag", function()
        for i = 1, #ids do writeField(ids[i], fieldName, value) end
    end)

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

consts.markerMaterial = "WarningMaterial"
consts.materialKeys   = settings.meshRoad.materialKeys

local function findUnskinned(kind)
    local ids = {}
    for _, nm in ipairs(scenetree.findClassObjects(kind) or {}) do
        local obj = scenetree.findObject(nm)
        if obj then
            local take
            if kind == "MeshRoad" then
                local real = false
                for _, key in ipairs(consts.materialKeys) do
                    local v = common.objField(obj, key)
                    if v and v ~= consts.markerMaterial then real = true end
                end
                take = not real
            else
                take = (common.objField(obj, "material") == consts.markerMaterial)
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
    for _, ax in ipairs(consts.allAxes) do coverage[ax] = {} end
    local ids    = findUnskinned("MeshRoad")
    local decals = findUnskinned("DecalRoad")
    for i = 1, #decals do ids[#ids + 1] = decals[i] end

    local known = {}
    for _, ax in ipairs(consts.allAxes) do known[ax] = knownValues(ax) end

    for _, id in ipairs(ids) do
        local obj = scenetree.findObjectById(id)
        if obj then
            coverage.total = coverage.total + 1
            local tagged   = false
            for _, axis in ipairs(consts.allAxes) do
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

consts.btnW   = 122
consts.perRow = 2

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
                                 imgui.ImVec2(consts.btnW, 0))

    for _ = 1, pushes do imgui.PopStyleColor() end

    if imgui.IsItemHovered() then
        imgui.SetTooltip(entry.value)
    end
    return clicked
end

local ui = {bufs = {}, edit = {}, held = {}, frame = 0, openOnce = {}, open = false, stretch = 8, keep = nil, log = {}, logMax = 12}

function ui.takeMain()
    local m = ui.main
    ui.main = false
    return m
end

local function sectionv(title, defaultOpen)
    if ui.openOnce[title] then
        imgui.SetNextItemOpen(true)
        ui.openOnce[title] = nil
    elseif sectionForce ~= nil then
        imgui.SetNextItemOpen(sectionForce)
    else
        imgui.SetNextItemOpen(defaultOpen == true, imgui.Cond_Appearing or imgui.Cond_FirstUseEver)
    end
    local v = visual(title)
    if rtlLayout then
        local st = imgui.GetStyle()
        local fh = imgui.CalcTextSize("X").y
        v        = layout.pad(v, availWidth() - fh - 4 * st.FramePadding.x) .. "###sec_" .. title
    end
    return imgui.CollapsingHeader1(v)
end

local function section(title, defaultOpen)
    return sectionv(lookup(title), defaultOpen)
end

local function drawAxis(axis, ids, mine)
    local hasSelection = #ids > 0
    local ax           = palette[axis]
    if not ax or #ax.entries == 0 then return end
    local field = fieldOf[axis]

    if not sectionv(lookup(ax.label) .. "  (" .. field .. ")", ui.takeMain()) then return end

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
        local rowEnd = math.min(rowStart + consts.perRow - 1, total)
        local inRow  = rowEnd - rowStart + 1
        alignRight(consts.btnW * inRow + 8 * (inRow - 1))

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
        rowStart = rowStart + consts.perRow
    end

    if mine then mine() end
    alignRight(ui.icon + 2 * imgui.GetStyle().FramePadding.x)
    if ui.smallIcon("clear_" .. axis, iconOf.clear, lookup("clear  X"), nil, ui.icon) and hasSelection then
        applyValue(field, "", ids)
    end
    return true
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

local iconLower = {src = nil, map = {}, own = {}, dir = "/lua/ge/extensions/editor/mage/icons/"}

local function findIcon(iconName)
    local icons = editor.icons
    if not iconName then return nil end
    if icons[iconName] then return icons[iconName] end
    if iconLower.src ~= icons then
        iconLower.src, iconLower.map = icons, {}
        for k in pairs(icons) do
            iconLower.map[k:lower()] = k
        end
    end
    local key = iconLower.map[iconName:lower()]
    return key and icons[key] or nil
end

function iconLower.ownIcon(iconName)
    if not iconName or iconName:sub(1, 5) ~= "mage." then return nil end
    local hit = iconLower.own[iconName]
    if hit == nil then
        local tex               = editor.texObj(iconLower.dir .. iconName:sub(6) .. ".png")
        hit                     = (tex and tex.texId) and tex or false
        iconLower.own[iconName] = hit
    end
    return hit or nil
end

function iconLower.has(iconName)
    return iconLower.ownIcon(iconName) ~= nil or findIcon(iconName) ~= nil
end

function iconLower.draw(id, iconName, size, tint, bg)
    local own = iconLower.ownIcon(iconName)
    if own then
        return true, imgui.ImageButton("##" .. id, own.texId, size, imgui.ImVec2(0, 0), imgui.ImVec2(1, 1), bg or imgui.ImVec4(0, 0, 0, 0),
                                       tint or imgui.GetStyleColorVec4(imgui.Col_Text))
    end
    local icon = findIcon(iconName)
    if icon then return true, editor.uiIconImageButton(icon, size, tint, nil, bg, "##" .. id) end
    return false, false
end

local function iconButton(id, iconName, label, tint, tipText)
    local drawn, clicked = iconLower.draw(id, iconName, imgui.ImVec2(36, 36), tint)
    if not drawn then
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
        if iconButton("pitflag_" .. axis, consts.flagIcons[axis] or "", label, getFlagCols()[st], line) then
            applyValue(field, (nxt == "default") and "" or nxt, ids)
        end
    end
end

-- =============================================================================
-- NUMBER FIELDS
-- =============================================================================

consts.dimStep   = 0.1
consts.dimFieldW = 110
consts.dimBtnW   = 24

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

ui.grey   = imgui.ImVec4(0.6, 0.6, 0.6, 1)
ui.blue   = imgui.ImVec4(0.55, 0.75, 1, 1)
ui.green  = imgui.ImVec4(0.31, 0.71, 0.48, 1)
ui.orange = imgui.ImVec4(1, 0.7, 0.2, 1)
ui.red    = imgui.ImVec4(1, 0.45, 0.35, 1)
ui.white  = imgui.ImVec4(1, 1, 1, 1)
ui.on     = imgui.ImVec4(0.16, 0.33, 0.55, 1)
ui.off    = imgui.ImVec4(0.14, 0.16, 0.22, 1)
ui.add    = imgui.ImVec4(0.18, 0.42, 0.28, 1)
ui.pick   = imgui.ImVec4(0.78, 0.39, 0.16, 1)
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
    local held = ui.held[id] and ui.held[id].at == ui.frame - 1 and ui.held[id].v or nil
    if not ui.edit[id] then buf[0] = held or cur end
    local newValue
    local lo1, hi1 = rtlLayout and "+##" .. inc or "-##" .. dec, rtlLayout and "-##" .. dec or "+##" .. inc
    local d1       = rtlLayout and consts.dimStep or -consts.dimStep
    if stepRepeat.button(lo1, imgui.ImVec2(consts.dimBtnW, 0)) then held = common.clamp((held or cur) + d1, lo, hi) end
    local down = imgui.IsItemActive()
    imgui.SameLine()
    imgui.PushItemWidth(math.max(40, availWidth() - consts.dimBtnW - gap))
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
    if stepRepeat.button(hi1, imgui.ImVec2(consts.dimBtnW, 0)) then held = common.clamp((held or cur) - d1, lo, hi) end
    down = down or imgui.IsItemActive()
    ui.held[id] = (held and down) and {v = held, at = ui.frame} or nil
    if held and not down then newValue = held end
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

function ui.segment(id, opts, cur, col, cols)
    local gap   = imgui.GetStyle().ItemSpacing.x
    local n     = math.min(#opts, cols or #opts)
    local w     = math.floor((availWidth() - (n - 1) * gap) / n)
    local items = {}
    for _, o in ipairs(opts) do
        local on          = (type(cur) == "table") and cur[o.key] or o.key == cur
        items[#items + 1] = ui.btnItem(o.label, id .. "_" .. o.key, on and (col or ui.pick) or ui.off, on and ui.white or ui.grey, w)
        items[#items].tip = o.tip
    end
    local hit = ui.row(items)
    return hit and hit:sub(#id + 2) or nil
end

function ui.smallIcon(id, iconName, label, tint, size, bg, tipText)
    local px       = size or 18
    local drawn, c = iconLower.draw(id, iconName, imgui.ImVec2(px, px), tint, bg)
    if not drawn then
        if bg then imgui.PushStyleColor2(imgui.Col_Button, bg) end
        if tint then imgui.PushStyleColor2(imgui.Col_Text, tint) end
        c = imgui.Button(rtl(label) .. "##" .. id)
        if tint then imgui.PopStyleColor() end
        if bg then imgui.PopStyleColor() end
    end
    if imgui.IsItemHovered() then imgui.SetTooltip(rtl(tipText or label)) end
    return c
end

function ui.back(id, label, on, fn)
    ui.prop(label)
    if not on then return end
    if ui.smallIcon(id, iconOf.restore, lookup("default"), nil, 18, nil, lookup("back to the default value")) then
        fn()
        statusText = tr("%s: %s", lookup(label), lookup("default"))
    end
    imgui.SameLine()
end

function ui.iconItem(id, iconName, label, tint, size, bg, tipText)
    local pad = 2 * imgui.GetStyle().FramePadding.x
    local w   = iconLower.has(iconName) and ((size or 18) + pad) or (imgui.CalcTextSize(rtl(label)).x + pad)
    return {w = w, draw = function() return ui.smallIcon(id, iconName, label, tint, size, bg, tipText) and id or nil end}
end

ui.icon = 24

function ui.act(id, iconName, label, bg)
    return ui.iconItem(id, iconName, lookup(label), nil, ui.icon, bg)
end

function ui.cycleItem(id, title, states, cur, tint)
    local k = 1
    for i, st in ipairs(states) do
        if st.key == cur then k = i end
    end
    local mixed   = cur == "mixed"
    local st      = states[k]
    local nx      = states[mixed and 1 or (k % #states + 1)]
    local tipText = tr("%s: %s - click for %s", lookup(title), lookup(mixed and "mixed" or st.label), lookup(nx.label))
    local it      = ui.iconItem(id, st.icon, lookup(mixed and "mixed" or st.label), mixed and ui.orange or st.tint or tint, ui.icon, st.bg, tipText)
    it.next       = nx.key
    return it
end

function ui.cycle(id, title, states, cur, tint)
    local it = ui.cycleItem(id, title, states, cur, tint)
    return ui.row({it}) and it.next or nil
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
-- PRESETS
-- =============================================================================

local presetUi = {bufs = {}, clip = nil}

function presetUi.list(kind)
    local all = cfg and cfg.presets and cfg.presets[kind]
    local out = {}
    for name, v in pairs(all or {}) do out[#out + 1] = {name = name, values = v} end
    table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return out
end

function presetUi.store(kind, name, values)
    local data = readStyles(cfgPath)
    if not data then
        statusText = "cannot read the config for writing"
        return false
    end
    data.presets             = data.presets or {}
    data.presets[kind]       = data.presets[kind] or {}
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
    local name = {w = consts.dimFieldW * 2, draw = function()
        imgui.PushItemWidth(consts.dimFieldW * 2)
        imgui.InputText("##presetname_" .. kind, buf, 64)
        imgui.PopItemWidth()
    end}
    if ui.row({ui.act("presetsave_" .. kind, iconOf.save, "save as preset"), name}) then
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
    for _, ax in ipairs(isMesh and consts.allAxes or consts.decalAxes) do keys[#keys + 1] = fieldOf[ax] end
    if not isMesh then keys[#keys + 1] = fieldOf.over end
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
    local n = 0
    transaction("MagePaste", function()
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
    end)
    statusText = tr("settings of %s pasted on %d roads", clip.name, n)
end

function presetUi.drawCopy(roadIds)
    local items = {}
    if #roadIds == 1 then
        items[1]     = ui.act("copysettings", iconOf.copy, "copy settings")
        items[1].tip = "every tag, flag and size of this road (gates stay on their nodes)"
    end
    local clip = presetUi.clip
    if clip and #roadIds > 0 then
        items[#items + 1] = ui.iconItem("pastesettings", iconOf.paste, tr("paste settings of %s", clip.name), nil, ui.icon)
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
    transaction("MageFeature", function()
        for _, id in ipairs(ids) do
            for _, f in ipairs(geometry.features) do
                local field = fieldOf[f.key]
                if field then
                    local want = (f.key == key) and "on" or ""
                    if (dynValue(id, field) or "") ~= want then writeField(id, field, want) end
                end
            end
        end
    end)
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
    transaction("MageDims", function()
        for _, id in ipairs(ids) do
            local over = {}
            if key ~= nil then
                over      = roadDims(id, f)
                over[key] = math.floor(value * 1000 + 0.5) / 1000
            end
            for k, v in pairs(over) do
                if base[k] and math.abs(base[k] - v) < 1e-6 then over[k] = nil end
            end
            writeField(id, dimsField(f), next(over) and jsonEncode(over) or "")
        end
    end)
end

local function drawFeaturePanel(ids, key)
    local f = featureByKey(key)
    if not f or not f.fields or #f.fields == 0 then return end
    if not sectionv(tr("%s settings", featureLabel(key)), false) then return end

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
            local v
            if fd.choices then
                local states, cur = {}, math.floor((shown[fd.key] or 0) + 0.5)
                for _, c in ipairs(fd.choices) do states[#states + 1] = {key = tostring(c[1]), label = c[2], icon = c[3]} end
                local hit = ui.cycle("dim_" .. id, fd.label, states, tostring(cur))
                v         = hit and tonumber(hit) or nil
            else
                v = ui.number("dim_" .. id, "dimdec_" .. id, "diminc_" .. id, shown[fd.key] or 0, fd.min, fd.max, base[fd.key] or 0)
            end
            if v then
                writeDims(ids, f, fd.key, v)
                statusText = tr("%s set to %s on %d roads", lookup(fd.label), string.format("%g", v), #ids)
            end
        end
        ui.endProps()
    end

    if ui.row({ui.act("dimreset_" .. key, iconOf.restore, "reset to defaults")}) then
        writeDims(ids, f, nil, nil)
        ui.edit    = {}
        statusText = tr("%s reset on %d roads", featureLabel(key), #ids)
    end
    tip("these sizes are stored on the road itself - other roads keep their own")

    local parts = {}
    for _, fd in ipairs(f.fields) do parts[#parts + 1] = string.format("%g", shown[fd.key] or 0) end
    presetUi.draw(key, shown, featureLabel(key) .. " " .. table.concat(parts, "/"), function(values)
        local base = f.defaults and f.defaults() or {}
        transaction("MageDims", function()
            for _, id in ipairs(ids) do
                local over = {}
                for _, fd in ipairs(f.fields) do
                    local v = tonumber(values[fd.key])
                    if v and not (base[fd.key] and math.abs(base[fd.key] - v) < 1e-6) then
                        over[fd.key] = common.clamp(v, fd.min, fd.max)
                    end
                end
                writeField(id, dimsField(f), next(over) and jsonEncode(over) or "")
            end
        end)
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
    transaction("MagePriority", function()
        for _, id in ipairs(ids) do
            if (dynValue(id, fieldOf.priority) or "") ~= want then writeField(id, fieldOf.priority, want) end
        end
    end)
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
        if ui.row({ui.act("priorityauto", iconOf.auto, "automatic")}) then priorityUi.writePriority(ids, priorityUi.min) end
    end
    tip("where MeshRoads overlap, the higher priority keeps the shared faces and the other road drops its hidden ones")
end

-- =============================================================================
-- VISIBILITY
-- =============================================================================

consts.visRefresh = 1.5
consts.raPrefix   = "mageRA_"

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
    if n > 0 then dirty() end
    visCache.at = -1
    return n
end

local function visGroups()
    local now = os.clock()
    if visCache.at >= 0 and now - visCache.at < consts.visRefresh then return visCache end
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
    local act  = (state == "selected" and "clear the selection") or (state == "shown" and "hide") or (noSelect and "show") or "show and select them"
    local tint = (state == "selected" and ui.blue) or (state == "shown" and cols.on) or (state == "mixed" and cols.mixed) or cols.default
    local line = tr("%s: %s - click to %s", lookup(label), lookup(state), lookup(act))
    if not iconButton(id, iconName, label, tint, line) then return end
    if #ids == 0 then
        statusText = "nothing found"
        return
    end
    if act == "clear the selection" or act == "hide" then
        local drop = {}
        for _, oid in ipairs(ids) do drop[oid] = true end
        local rest = {}
        for _, sid in ipairs(getSelection()) do
            if not drop[sid] then rest[#rest + 1] = sid end
        end
        if #rest > 0 then editor.selectObjects(rest) else editor.clearObjectSelection() end
    end
    if act == "clear the selection" then
        statusText = tr("%d objects no longer selected", #ids)
        return
    end
    local hide = act == "hide"
    local n    = setHidden(ids, hide)
    statusText = hide and tr("%d objects hidden", n) or tr("%d objects shown", n)
    if hide then return end
    enterEditMode(editMode)
    if act ~= "show and select them" then return end
    selectIds(ids)
    statusText = tr("%d objects shown and selected", n)
end

local function objName(id)
    local o = scenetree.findObjectById(id)
    return o and o:getName() or ""
end

local function builtObjects(ids)
    local out = {}
    for _, id in ipairs(ids) do
        if classOf(id) == "TSStatic" or classOf(id) == "Prefab" then
            local n = objName(id)
            if n:sub(1, #consts.raPrefix) == consts.raPrefix or n:sub(1, #geometry.mr.daePrefix) == geometry.mr.daePrefix then
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
        if n:sub(1, #consts.raPrefix) == consts.raPrefix then
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
            local cell = n:sub(#geometry.mr.daePrefix + 1)
            local root = cell:sub(1, 1) == "b" and building.ofKey(cell:sub(2))
            for _, id in ipairs(root and building.group(root) or {}) do
                if not seen[id] then
                    seen[id]      = true
                    ids[#ids + 1] = id
                end
            end
            if not root then cells[cell] = true end
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
    text("how many objects in the map carry each tag, and which ones", ui.grey)
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

    for _, axis in ipairs(consts.allAxes) do
        local rows = {}
        for value, b in pairs(coverage[axis]) do
            rows[#rows + 1] = {value = value, n = b.n, ids = b.ids, known = b.known}
        end
        if #rows > 0 then
            table.sort(rows, function(a, b) return a.n > b.n end)
            textv(lookup(palette[axis].label) .. ":")
            for _, r in ipairs(rows) do
                alignRight(250)
                if ui.smallIcon("sel_" .. axis .. "_" .. r.value, iconOf.select, lookup("select"), nil, ui.icon) then
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

local function drawArchitect()
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
    if sc then old = tr("   (config now: %.2f x %.2f)", sc[1], sc[2]) end
    return tr("U %.2f m/tile - %.1f tiles per 10 m along", su, 10.0 / su),
           tr("V %.2f m/tile - %.1f tiles per 10 m across%s", sv, 10.0 / sv, old)
end

local function drawAdvanced()
    if not section("add a material from the map", false) then return end

    text("add a material already in the map to the config", imgui.ImVec4(0.6, 0.6, 0.6, 1))

    local set = ensureMatSet()
    if #set == 0 then
        text("no materials found in the map", imgui.ImVec4(1, 0.45, 0.35, 1))
        return
    end

    imgui.PushID1("mageMatFilter")
    imgui.ImGuiTextFilter_Draw(matUi.matFilter, rtl("Search..."), 200)
    imgui.PopID()
    local opaque, likely = ui.markItem("opaqueonly", "solid materials only", matUi.opaqueOnly), ui.markItem("likelyonly", "likely candidates", matUi.likelyOnly)
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
                                      and imgui.ImGuiTextFilter_PassFilter(matUi.matFilter, name)
            if pass and matUi.opaqueOnly[0] and not isSolidMaterial(mat, name) then
                pass   = false
                hidden = hidden + 1
            end
            local info = pass and texture.info(name) or nil
            if pass and matUi.likelyOnly[0] and not info then
                pass     = false
                narrowed = narrowed + 1
            end
            if pass then
                rows[#rows + 1] = {mat = mat, name = name, info = info}
            end
        end

        if matUi.likelyOnly[0] then
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
                clicked = imgui.ImageButton("##tex_" .. name, tex.texId, consts.vec32)
                imgui.SameLine()
            end
            if imgui.Selectable1(name .. "##sel_" .. name, selectedMat == name) or clicked then
                selectedMat         = name
                matUi.asNewStyle[0] = false
                local known         = cfg and cfg.materials and cfg.materials[name]
                local sc            = known and known.scale
                if sc then matUi.newScaleU[0], matUi.newScaleV[0] = sc[1], sc[2] end
                local existing, existingScale = nil, nil
                for _, ax in ipairs({"walk", "curb", "wall"}) do
                    for _, st in pairs(cfg and cfg[ax] and cfg[ax].styles or {}) do
                        if st.material == name and st.label then
                            existing, existingScale = st.label, st.scale
                            break
                        end
                    end
                    if existing then break end
                end
                if existingScale then matUi.newScaleU[0], matUi.newScaleV[0] = existingScale[1], existingScale[2] end
                bufWrite(matUi.labelBuf, existing or name)
                if row.info then matUi.newAxis[0] = (row.info.axis == "curb" and 0)
                                                                            or (row.info.axis == "wall" and 2) or 1 end
            end
            if row.info and matUi.likelyOnly[0] then
                imgui.SameLine()
                text("[" .. row.info.axis .. "]", imgui.ImVec4(0.45, 0.55, 0.45, 1))
            end
        end
    end

    imgui.BeginChild1("mageMatList", imgui.ImVec2(0, 180), true)
    drawList()
    imgui.EndChild()
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
        for _, ax in ipairs(consts.allAxes) do
            for k, st in pairs(cfg[ax] and cfg[ax].styles or {}) do
                if st.material == selectedMat or (ax == "curb" and cfg.curb and cfg.curb.material == selectedMat and st.sequence == nil) then
                    uses[#uses + 1] = {axis = ax, key = k, label = st.label or k, scale = st.scale}
                end
            end
        end
    end

    if #uses > 0 then
        textv(#uses == 1 and tr("already used by 1 style:")
                          or tr("already used by %d styles:", #uses),
              imgui.ImVec4(1, 0.7, 0.2, 1))
        for _, u in ipairs(uses) do
            local sc   = u.scale and string.format("   %.2f x %.2f", u.scale[1], u.scale[2]) or ""
            local line = visual(string.format("%s . %s   (%s)%s", u.axis, u.key, lookup(u.label), sc))
            if ui.row({ui.textItem(line, imgui.ImVec4(0.75, 0.75, 0.75, 1)), ui.act("rm_" .. u.axis .. "_" .. u.key, iconOf.remove, "remove")}) then
                removeStyle(u.axis, u.key)
            end
        end
        ui.checkPtr("newstyle", "add as a new style", matUi.asNewStyle)
        tip("off: update the matching style in place.\n"
            .. "on: keep the existing one and add another, so the same\n"
            .. "material can appear at several scales.")
    end

    imgui.PushItemWidth(-1)
    imgui.InputText("##pitlabel", matUi.labelBuf, 64)
    imgui.PopItemWidth()
    text("display name - this is what appears on the palette button",
         imgui.ImVec4(0.5, 0.5, 0.5, 1))

    imgui.PushItemWidth(90)
    imgui.DragFloat(rtl("U##su"), matUi.newScaleU, 0.01, 0.05, 64.0, "%.2f")
    imgui.SameLine()
    imgui.DragFloat(rtl("V##sv"), matUi.newScaleV, 0.01, 0.05, 64.0, "%.2f")
    imgui.PopItemWidth()

    local hintU, hintV = scaleHint(matUi.newScaleU[0], matUi.newScaleV[0])
    text(hintU, imgui.ImVec4(0.5, 0.5, 0.5, 1))
    text(hintV, imgui.ImVec4(0.5, 0.5, 0.5, 1))

    ui.row({ui.markItem("axw", "top surface", matUi.newAxis, 1), ui.markItem("axc", "curb edge", matUi.newAxis, 0), ui.markItem("axwall", "MeshRoad wall", matUi.newAxis, 2)})

    if matUi.newAxis[0] == 0 then
        if curbUsesAtlas() then
            imgui.PushItemWidth(90)
            imgui.InputInt(rtl("band") .. "##curbband", matUi.newBand)
            imgui.PopItemWidth()
            if matUi.newBand[0] < 0 then matUi.newBand[0] = 0 end
            text("this map's curb material is an atlas, so a curb style selects a "
                 .. "band. The scale above is stored on the material only.",
                 imgui.ImVec4(0.5, 0.5, 0.5, 1))
        else
            text("this map's curb material has no atlas, so the scale above is "
                 .. "written into the curb style itself.",
                 imgui.ImVec4(0.5, 0.5, 0.5, 1))
        end
    end

    if matUi.newAxis[0] == 0 and cfg and cfg.curb and cfg.curb.material
          and cfg.curb.material ~= selectedMat then
        textv(tr("curb.material is %s - this style will be drawn with that material, not %s",
                 tostring(cfg.curb.material), selectedMat), imgui.ImVec4(1, 0.7, 0.2, 1))
        text("curb styles vary band or scale only. tick the box below to replace"
             .. " the map's kerb material instead", imgui.ImVec4(0.6, 0.6, 0.6, 1))
    end

    ui.checkPtr("ascurb", "also set as the map's curb material", matUi.alsoCurbMat)
    ui.checkPtr("asmesh", "also set as the map's MeshRoad material", matUi.alsoMeshMat)
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
        local label = bufRead(matUi.labelBuf)
        if label == "" then label = selectedMat end
        local axis = "walk"
        if matUi.newAxis[0] == 0 then axis = "curb"
        elseif matUi.newAxis[0] == 2 then axis = "wall" end
        addMaterialToConfig(selectedMat, axis, matUi.newScaleU[0], matUi.newScaleV[0], label,
                            matUi.alsoCurbMat[0], matUi.alsoMeshMat[0], matUi.asNewStyle[0])
        matUi.alsoCurbMat[0], matUi.alsoMeshMat[0] = false, false
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
    transaction("MageGate", function()
        writeField(id, fieldOf.gates, gate.encode(gates))
    end)
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
    {key = "rise", id = "gaterise", dec = "gaterisedec", inc = "gateriseinc", label = "height of the arch",
     min = function() return gate.minRise end, max = function() return gate.maxRise end, arch = true,
     default = function(g) return gateUi.riseOf(g) end},
}

function gateUi.riseOf(g)
    if not g or g.style == "rect" then return 0.0 end
    return math.floor(gate.riseOf({style = g.style, width = g.width or 1.0, apex = math.huge, floor = 0.0}) * 1000 + 0.5) / 1000
end

function gateUi.drawGateSettings(id, gates, ks)
    local g      = gates[ks[1]]
    local differ = false
    for _, k in ipairs(ks) do
        for _, f in ipairs(gateUi.fieldDefs) do
            if math.abs((gates[k][f.key] or f.default(gates[k])) - (g[f.key] or f.default(g))) > 1e-6 then differ = true end
        end
    end
    if differ then
        text("values differ between the selected gates - showing the first", imgui.ImVec4(1, 0.7, 0.2, 1))
    end
    if ui.beginProps("gate") then
        for _, f in ipairs(gateUi.fieldDefs) do
            if not (f.arch and g.style == "rect") then
                ui.prop(lookup(f.label))
                local v = ui.number(f.id, f.dec, f.inc, g[f.key] or f.default(g), f.min(), f.max(), f.default(g))
                if v then
                    for _, k in ipairs(ks) do gates[k][f.key] = v end
                    gateUi.writeGates(id, gates)
                    statusText = tr("%s set to %s on %d gates", lookup(f.label), string.format("%g", v), #ks)
                end
            end
        end
        ui.endProps()
    end
    local values = {style = g.style, dir = g.dir, width = g.width, top = g.top or gate.defaultTop, sill = g.sill or 0.0, rise = g.rise}
    local auto   = string.format("%s %g/%g/%g", lookup(gateUi.labels[gateUi.kindOf(g)]), values.width, values.top, values.sill)
    presetUi.draw("gate", values, auto, function(v)
        for _, k in ipairs(ks) do
            local t = gates[k]
            for _, key in ipairs({"style", "dir", "width", "top", "sill", "rise"}) do
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
    if not sectionv(lookup("gates"), false) then return end
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
        if not gateUi.inMeshRoadEditor() and ui.row({ui.act("gateeditor", iconOf.meshEditor, "open the Mesh Road Editor")}) then
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

local windowUi = {line = {}}

windowUi.order  = {"round", "quarter_left", "quarter_right", "rect", "pointed"}
windowUi.labels = {
    round         = "round arch",
    quarter_left  = "quarter arch, left",
    quarter_right = "quarter arch, right",
    rect          = "square opening",
    pointed       = "pointed arch",
}
windowUi.faceLabels = {right = "right side", left = "left side", start = "start face", ["end"] = "end face"}
windowUi.faceShort  = {right = "right", left = "left", start = "start", ["end"] = "end"}
windowUi.rowFields  = {
    {key = "width",  label = "window length"},
    {key = "gap",    label = "gap length"},
    {key = "height", label = "window height"},
    {key = "sill",   label = "bottom of the window above the floor"},
}

function windowUi.read(id)
    return window.parse(dynValue(id, fieldOf.windows))
end

function windowUi.peek(id)
    return window.peek(dynValue(id, fieldOf.windows))
end

function windowUi.drawRowMore(fl, pre, margin)
    local changed = false
    local function num(key, label, lo, hi, def)
        ui.prop(lookup(label))
        local v = ui.number(pre .. key, pre .. key .. "dec", pre .. key .. "inc", fl[key] or def, lo, hi, def)
        if v then
            fl[key]    = v
            changed    = true
            statusText = tr("%s set to %s", lookup(label), string.format("%g", v))
        end
    end
    if fl.style ~= "rect" then num("rise", "height of the arch", gate.minRise, gate.maxRise, gateUi.riseOf(fl)) end
    num("lead", "distance from the start of the face", 0.0, 1000.0, margin)
    num("tail", "distance from the end of the face", 0.0, 1000.0, margin)
    if fl.at then return changed end
    ui.prop(lookup("spacing"))
    local mode = ui.cycle(pre .. "space", "spacing", {{key = "gap", label = "by the gap length", icon = iconOf.spaceGap},
                                                     {key = "count", label = "by the number of openings", icon = iconOf.spaceCount}}, fl.count and "count" or "gap")
    if mode then
        fl.count = (mode == "count") and 3 or nil
        changed  = true
    end
    if fl.count then
        ui.prop(lookup("number of openings"))
        local v = ui.number(pre .. "count", pre .. "countdec", pre .. "countinc", fl.count, 1, 200, 3)
        if v then
            fl.count   = math.max(1, math.floor(v + 0.5))
            changed    = true
            statusText = tr("%s set to %s", lookup("number of openings"), tostring(fl.count))
        end
        return changed
    end
    ui.prop(lookup("alignment"))
    local al = ui.cycle(pre .. "align", "alignment", {{key = "start", label = "from the start of the face", icon = iconOf.alignStart},
                                                     {key = "center", label = "in the middle", icon = iconOf.alignCenter},
                                                     {key = "end", label = "from the end of the face", icon = iconOf.alignEnd}}, fl.align or "center")
    if al then
        fl.align = (al ~= "center") and al or nil
        changed  = true
    end
    return changed
end

function windowUi.write(id, cfg)
    if cfg then table.sort(cfg.floors, function(a, b) return a.sill < b.sill end) end
    transaction("MageWindows", function()
        writeField(id, fieldOf.windows, cfg and window.encode(cfg) or "")
    end)
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

function windowUi.nameOf(key, opts)
    for _, o in ipairs(opts) do
        if o.value == key then return o.label end
    end
    if key and key:sub(1, 1) == "@" then return buildArch.labelOf(key:sub(2)) end
    return key or opts[1].label
end

function windowUi.listPopup(id, p, write)
    local T     = windowUi.tex
    local gap   = imgui.GetStyle().ItemSpacing.x
    local lbl   = p.label and rtl(p.label) or ""
    local width = math.max(60, availWidth() - (p.label and (imgui.CalcTextSize(lbl).x + gap) or 0) - consts.dimBtnW - gap)
    local items = {}
    if p.label then items[1] = ui.textItem(lbl) end
    items[#items + 1] = ui.btnItem(p.text, id .. "_field", nil, nil, width)
    items[#items + 1] = ui.btnItem("...", id, nil, nil, consts.dimBtnW)
    if ui.row(items) then
        T.fresh[id], T.hot[id], T.dwell = true, nil, {}
        if T.q[id] then bufWrite(T.q[id], "") end
        if p.open then p.open() end
        imgui.OpenPopup(id .. "_popup")
    end
    if T.drawn[id] == T.frame or not imgui.BeginPopup(id .. "_popup") then
        if T.shown[id] and T.drawn[id] ~= T.frame then
            T.shown[id] = nil
            windowUi.texTryEnd()
        end
        return nil
    end
    T.shown[id], T.drawn[id] = true, T.frame
    if p.start then p.start(T.fresh[id]) end
    T.q[id] = T.q[id] or imgui.ArrayChar(64)
    if T.fresh[id] then imgui.SetKeyboardFocusHere(0) end
    imgui.PushItemWidth(p.w)
    imgui.InputText("##" .. id .. "_search", T.q[id], 64)
    imgui.PopItemWidth()
    local query = bufRead(T.q[id])
    local picked, hovered
    if p.head then picked, hovered, query = p.head(query) end
    local rows         = p.rows(query)
    local enter, close = windowUi.keyNav(id, #rows)
    if enter then picked = rows[T.hot[id]] end
    imgui.BeginChild1(id .. "_list", imgui.ImVec2(p.w, p.h), true)
    local key = p.scroll and p.scroll() or nil
    if key and T.fresh[id] and T.scroll[key] then imgui.SetScrollY(T.scroll[key]) end
    local heads, group = p.heads(query), nil
    for i, o in ipairs(rows) do
        if heads and o.group ~= group then
            group = o.group
            if group then text(group, ui.blue) else imgui.Separator() end
        end
        local hot       = T.hot[id] == i
        local hit, over = p.row(o, i, hot)
        if hit then picked = o end
        if over then hovered = o end
        if hot and T.keys[id] then imgui.SetScrollHereY(0.5) end
    end
    if key then T.scroll[key] = imgui.GetScrollY() end
    imgui.EndChild()
    if hovered then T.keys[id] = nil end
    local try = write and function(v) return windowUi.tryWrite(write, v) end or nil
    windowUi.dwell(id, hovered or (T.keys[id] and T.hot[id] and rows[T.hot[id]]) or nil, try, p.peek)
    T.fresh[id] = nil
    if picked or close then imgui.CloseCurrentPopup() end
    imgui.EndPopup()
    if close or not picked then
        if close then
            T.shown[id] = nil
            windowUi.texTryEnd()
        end
        return nil
    end
    T.shown[id]           = nil
    local ok, value, keep = p.take(picked)
    windowUi.texTryEnd(keep)
    if not ok then return nil, value end
    if write and value ~= nil then write(value) end
    return true, value
end

function windowUi.picker(id, label, cur, opts, shown, write)
    return windowUi.listPopup(id, {
        label = label,
        text  = shown or windowUi.nameOf(cur, opts),
        w     = 340,
        h     = 300,
        heads = function() return true end,
        peek  = function(o) return o.value end,
        rows  = function(query)
            local rows = {}
            for _, o in ipairs(opts) do
                if texture.matches(query, o.label, o.value) then rows[#rows + 1] = o end
            end
            return rows
        end,
        row   = function(o, i, hot)
            local mat = o.mat and (scenetree.findObject(o.mat) or (o.bat and scenetree.findObject(o.bat)))
            local tex = mat and texFor(mat)
            local hit = false
            if tex and tex.texId then
                hit = imgui.ImageButton("##" .. id .. "_tex" .. i, tex.texId, consts.vec32)
                imgui.SameLine()
            end
            if imgui.Selectable1(rtl(o.label) .. "##" .. id .. "_opt" .. i, o.value == cur or hot) then hit = true end
            return hit, imgui.IsItemHovered()
        end,
        take  = function(o)
            if not o.bat and not o.tex then return true, o.value, o.value or "" end
            local value = o.bat and buildArch.use(o.bat) or buildArch.useTex(o.tex)
            if not value then return false, "could not copy the material into the map", "" end
            return true, value, value
        end,
    }, write)
end

function windowUi.keyNav(id, n)
    local T        = windowUi.tex
    local down, up = imgui.IsKeyPressed(imgui.GetKeyIndex(imgui.Key_DownArrow)), imgui.IsKeyPressed(imgui.GetKeyIndex(imgui.Key_UpArrow))
    if (down or up) and n > 0 then
        local h    = T.hot[id] or (down and 0 or n + 1)
        T.hot[id]  = math.max(1, math.min(n, h + (down and 1 or -1)))
        T.keys[id] = true
    end
    if T.hot[id] and T.hot[id] > n then T.hot[id] = nil end
    local enter = imgui.IsKeyPressed(imgui.GetKeyIndex(imgui.Key_Enter)) and T.hot[id] ~= nil
    return enter, imgui.IsKeyPressed(imgui.GetKeyIndex(imgui.Key_Escape))
end

function windowUi.dwell(id, want, try, valueOf)
    local T   = windowUi.tex
    local key = want and (want.value or want.label) or nil
    if key ~= T.dwell.key then
        T.dwell = {key = key, at = os.clock()}
        if not want and T.trying == id then
            preview.tryEnd()
            T.trying = nil
        end
    elseif want and try and not T.dwell.done and os.clock() - T.dwell.at >= windowUi.tryDelay then
        T.dwell.done = true
        local v      = valueOf(want)
        if v then
            local map, show = try(v)
            preview.tryFields(map, show)
            T.trying = id
        end
    end
end

windowUi.tex      = {open = {}, lock = {}, bufs = {}, cats = {}, opts = {}, fresh = {}, hot = {}, keys = {}, q = {}, tab = {}, scroll = {},
                     shown = {}, dwell = {}, tried = {}, drawn = {}, frame = 0}
windowUi.tryDelay = 0.25

windowUi.texGroups = {
    mine   = "my configurations",
    bat    = "Building Architect textures",
    map    = "solid textures from the map",
    van    = "solid vanilla textures",
    allMap = "all the map's textures",
    allVan = "all vanilla textures",
}

windowUi.texKindLabel = {wall = "walls", walk = "top surface", curb = "curb edge", roof = "roof"}

function windowUi.matLabel(name)
    if buildArch.isTex(name) then return (name:sub(10):gsub("_", " ")) end
    return buildArch.labelOf(name)
end

function windowUi.texLabel(value, kind, empty)
    if not value or value == "" then return lookup(empty) end
    local t = texture.parse(value)
    if t then return windowUi.matLabel(t.mat) end
    local st = geometry.mr.styleFor(value, kind)
    return lookup(st and st.label or value)
end

function windowUi.texShows(axis, kind, st)
    if axis == kind then return true end
    if (axis == "wall" and kind == "walk") or (axis == "walk" and kind == "wall") then return st.material ~= nil end
    if kind == "roof" and axis == "walk" then return st.material ~= nil end
    for _, k in ipairs(st.also or {}) do
        if k == kind then return st.material ~= nil end
    end
    return false
end

function windowUi.texStyles(axis, kind, all, out)
    local styles = cfg and cfg[axis] and cfg[axis].styles
    local keys   = {}
    for k, st in pairs(styles or {}) do
        if windowUi.texShows(axis, kind, st) and (all or st.sequence == nil) and (axis == kind or st.sequence == nil) then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys, function(a, b) return lookup(styles[a].label or a) < lookup(styles[b].label or b) end)
    for _, k in ipairs(keys) do
        out[#out + 1] = {value = k, label = lookup(styles[k].label or k), mat = styles[k].material, style = true, group = windowUi.texGroups.mine}
    end
end

windowUi.texStyleAxes = {wall = {"wall", "walk", "curb", "roof"}, walk = {"walk", "wall", "curb", "roof"},
                         curb = {"curb", "walk", "wall", "roof"}, roof = {"roof", "walk", "wall", "curb"}}

function windowUi.texOptions(kind, empty, all)
    local out, seen = {{label = lookup(empty)}}, {}
    local bats      = {}
    for _, n in ipairs(buildArch.wallMaterials()) do bats[n], bats[buildArch.copyName(n)] = true, true end
    for _, n in ipairs(buildArch.roofMaterials()) do bats[n], bats[buildArch.copyName(n)] = true, true end
    local function add(o)
        if o.mat and o.value and o.value:sub(1, 1) == "@" then
            if seen[o.mat] then return end
            seen[o.mat] = true
        end
        out[#out + 1] = o
    end
    local lib, keys = texture.library().configs, {}
    for k, e in pairs(lib) do
        if texture.inKind(e, kind) then keys[#keys + 1] = k end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do out[#out + 1] = {value = "lib:" .. k, label = lib[k].label or k, mat = lib[k].mat, lib = k, group = windowUi.texGroups.mine} end
    for _, ax in ipairs(windowUi.texStyleAxes[kind]) do windowUi.texStyles(ax, kind, all, out) end
    local batList = (kind == "wall" and buildArch.wallMaterials()) or (kind == "roof" and buildArch.roofMaterials()) or {}
    for _, name in ipairs(batList) do
        local copy = buildArch.copyName(name)
        add({value = "@" .. copy, label = buildArch.labelOf(name), mat = copy, bat = name, group = windowUi.texGroups.bat})
    end
    local solid, rest = {}, {}
    for _, n in ipairs(scenetree.findClassObjects("Material") or {}) do
        if not bats[n] and not bats[n .. "_bat"] and not buildArch.isTex(n) then
            local _, set = texture.axesOf(n)
            local mat    = scenetree.findObject(n)
            if mat and set[kind] and n:sub(1, 5) ~= "mage_" and isSolidMaterial(mat, n) then solid[#solid + 1] = n else rest[#rest + 1] = n end
        end
    end
    table.sort(solid)
    table.sort(rest)
    for _, n in ipairs(solid) do add({value = "@" .. n, label = buildArch.labelOf(n), mat = n, group = windowUi.texGroups.map}) end
    for _, e in ipairs(buildArch.texturesFor(kind)) do
        add({value = "@" .. e.name, label = e.label, mat = e.name, tex = e.name, path = e.path, group = windowUi.texGroups.van})
    end
    for _, n in ipairs(rest) do add({value = "@" .. n, label = buildArch.labelOf(n), mat = n, group = windowUi.texGroups.allMap}) end
    for _, e in ipairs(buildArch.allTextures()) do
        add({value = "@" .. e.name, label = e.label, mat = e.name, tex = e.name, path = e.path, group = windowUi.texGroups.allVan})
    end
    return out
end

function windowUi.texSize(mat)
    local known = cfg and cfg.materials and cfg.materials[mat]
    local sc    = known and known.scale
    if sc then return sc[1], sc[2] end
    local k = texture.knownSize(mat) or (cfg and cfg.defaultScale) or 2.5
    return k, k
end

function windowUi.texStore(kind, c)
    local data = readStyles(cfgPath)
    if not data then
        statusText = "cannot read the config for writing"
        return nil
    end
    local rot, ou, ov = texture.turnOf(c.rot), c.ou or 0, c.ov or 0
    local also        = {}
    for _, k in ipairs(c.cats or {}) do
        if k ~= kind then also[#also + 1] = k end
    end
    local st = {material = c.mat, label = c.label, scale = {c.u, c.v}, rot = (rot ~= 0) and rot or nil,
                off = (ou ~= 0 or ov ~= 0) and {ou, ov} or nil, also = (#also > 0) and also or nil, from = c.from,
                weight = 0, color = {0.55, 0.55, 0.58}, config = true}
    texture.pinDefault(data, kind)
    data[kind]        = data[kind] or {}
    data[kind].styles = data[kind].styles or {}
    local key         = slug(c.label)
    if data[kind].styles[key] then key = styleKeyFor(data, kind, c.mat, c.label, true) end
    data[kind].styles[key] = st
    if not commitConfig(data) then return nil end
    loadConfig()
    return key
end

function windowUi.batOf(mat)
    for _, list in ipairs({buildArch.wallMaterials(), buildArch.roofMaterials()}) do
        for _, n in ipairs(list) do
            if buildArch.copyName(n) == mat then return n end
        end
    end
    return nil
end

function windowUi.texSource(mat)
    local bat = windowUi.batOf(mat)
    if bat then return {bat = bat} end
    if buildArch.isTex(mat) then return {tex = mat} end
    local obj = scenetree.findObject(mat)
    local img = obj and (matField(obj, "colorMap", 0) or "")
    if obj and img == "" then img = matField(obj, "baseColorMap", 0) or "" end
    local stem = img and (img:match("^(.-)_[dD]%.[%w%.]+$") or img:match("^(.-)_[bB]%.color%.%w+$"))
    if not stem then return nil end
    return {tex = "mage_tex_" .. (stem:match("[^/]+$"):lower():gsub("[^%w_]", "_"))}
end

function windowUi.texFromLib(key, kind)
    local e = texture.library().configs[key]
    if not e then return nil end
    local mat = e.mat
    if not scenetree.findObject(mat) then
        local v = (e.bat and buildArch.use(e.bat)) or (e.tex and buildArch.useTex(e.tex))
        if not v then return nil end
        mat = texture.material(v)
    end
    return windowUi.texStore(kind, {label = e.label, mat = mat, u = e.u, v = e.v, rot = e.rot, ou = e.ou, ov = e.ov, cats = e.cats, from = key})
end

function windowUi.texTake(o, kind)
    if o.lib then return windowUi.texFromLib(o.lib, kind) end
    if o.bat then return buildArch.use(o.bat) end
    if o.tex and not buildArch.useTex(o.tex) then return nil end
    if o.value and o.value:sub(1, 1) == "@" then
        local u, v = windowUi.texSize(o.mat)
        return texture.encode({mat = o.mat, u = u, v = v})
    end
    return o.value or ""
end

function windowUi.texSave(kind, t, label, cats)
    local src = windowUi.texSource(t.mat)
    local key = nil
    if src then
        local lib  = texture.library()
        key        = texture.slug(label)
        local base = key
        local n    = 2
        while lib.configs[key] and lib.configs[key].label ~= label do
            key, n = base .. "_" .. n, n + 1
        end
        lib.configs[key] = {label = label, mat = t.mat, bat = src.bat, tex = src.tex, u = t.u, v = t.v,
                            rot = texture.turnOf(t.rot), ou = t.ou or 0, ov = t.ov or 0, cats = cats}
        texture.saveLibrary()
    end
    return windowUi.texStore(kind, {label = label, mat = t.mat, u = t.u, v = t.v, rot = t.rot, ou = t.ou, ov = t.ov, cats = cats, from = key})
end

function windowUi.texStarred(o, kind)
    if o.lib then return true end
    for _, e in pairs(texture.library().configs) do
        if e.mat == o.mat and texture.inKind(e, kind) then return true end
    end
    return false
end

function windowUi.texStar(o, kind)
    if o.lib then
        texture.library().configs[o.lib] = nil
        texture.saveLibrary()
        return
    end
    local v = windowUi.texTake(o, kind)
    local t = v and texture.parse(v)
    if not t then
        local st = v and geometry.mr.styleFor(v, kind)
        if not (st and st.material) then return end
        local su, sv = geometry.mr.styleScale(st, st.material)
        t            = {mat = st.material, u = su, v = sv, rot = st.rot, ou = (st.off or {})[1], ov = (st.off or {})[2]}
    end
    if not t.u then t.u, t.v = geometry.mr.styleScale(geometry.mr.rawStyle(v), t.mat) end
    windowUi.texSave(kind, t, o.label, {kind})
end

function windowUi.thumb(o)
    local mat = o.mat and (scenetree.findObject(o.mat) or (o.bat and scenetree.findObject(o.bat)))
    if mat then return texFor(mat) end
    if not o.path then return nil end
    if matUi.texCache[o.path] == nil and matUi.texBudget < 5 then
        matUi.texBudget        = matUi.texBudget + 1
        local tex              = editor.texObj(o.path)
        matUi.texCache[o.path] = (tex and tex.texId) and tex or false
    end
    return matUi.texCache[o.path] or nil
end

function windowUi.texPeek(o)
    local T = windowUi.tex
    if o.lib then
        local e = texture.library().configs[o.lib]
        if not e then return nil end
        local mat = e.mat
        if not scenetree.findObject(mat) then
            local v = (e.bat and buildArch.use(e.bat)) or (e.tex and buildArch.useTex(e.tex))
            if not v then return nil end
            mat          = texture.material(v)
            T.tried[mat] = true
        end
        return texture.encode({mat = mat, u = e.u, v = e.v, rot = e.rot, ou = e.ou, ov = e.ov})
    end
    if o.bat and not scenetree.findObject(o.mat) then T.tried[o.mat] = true end
    if o.tex and not scenetree.findObject(o.tex) then T.tried[o.tex] = true end
    if o.bat then return buildArch.use(o.bat) end
    if o.tex and not buildArch.useTex(o.tex) then return nil end
    if o.value and o.value:sub(1, 1) == "@" then
        local u, v = windowUi.texSize(o.mat)
        return texture.encode({mat = o.mat, u = u, v = v})
    end
    return o.value or ""
end

function windowUi.texTryEnd(keep)
    local T = windowUi.tex
    if T.trying then
        T.redraw = preview.tryEnd(keep ~= nil)
        T.trying = nil
    end
    local drop = {}
    for name in pairs(T.tried) do
        if name ~= keep then drop[#drop + 1] = name end
    end
    T.tried = {}
    buildArch.unstore(drop)
end

function windowUi.texGroupsOf(opts)
    local out, seen = {}, {}
    for _, o in ipairs(opts) do
        if o.group and not seen[o.group] then
            seen[o.group], out[#out + 1] = true, o.group
        end
    end
    return out
end

function windowUi.texPick(id, kind, cur, empty, shown, all, write)
    local T                 = windowUi.tex
    local opts, tab, groups = nil, nil, nil
    return windowUi.listPopup(id, {
        text = shown or windowUi.texLabel(cur, kind, empty),
        w    = 380,
        h    = 340,
        open  = function() T.opts[id] = nil end,
        start = function(fresh)
            opts       = T.opts[id] or windowUi.texOptions(kind, empty, all)
            T.opts[id] = opts
            if fresh then
                for _, o in ipairs(opts) do
                    if o.value == cur and o.group then T.tab[kind] = o.group end
                end
            end
            groups   = windowUi.texGroupsOf(opts)
            tab      = T.tab[kind]
            local ok = false
            for _, g in ipairs(groups) do ok = ok or g == tab end
            if not ok then tab = groups[1] end
            T.tab[kind] = tab
        end,
        head  = function(query)
            local picked, hovered
            if imgui.Selectable1(rtl(lookup(empty)) .. "##" .. id .. "_empty", not cur or cur == "") then picked = opts[1] end
            if imgui.IsItemHovered() then hovered = opts[1] end
            local tabs = {}
            for _, g in ipairs(groups) do tabs[#tabs + 1] = ui.btnItem(lookup(g), id .. "_tab_" .. g, (g == tab and query == "") and ui.pick or ui.off) end
            local th = ui.row(tabs)
            if th then
                T.tab[kind], tab = th:sub(#id + 6), th:sub(#id + 6)
                bufWrite(T.q[id], "")
                query, T.hot[id] = "", nil
            end
            if buildArch.scanning() then text("reading the other maps' textures...", ui.grey) end
            return picked, hovered, query
        end,
        heads  = function(query) return query ~= "" end,
        scroll = function() return kind .. "|" .. tostring(tab) end,
        peek   = windowUi.texPeek,
        rows   = function(query)
            local rows = {}
            for _, o in ipairs(opts) do
                if o.group and ((query == "" and o.group == tab) or (query ~= "" and texture.matches(query, o.label, o.mat))) then rows[#rows + 1] = o end
            end
            return rows
        end,
        row    = function(o, i, hot)
            if o.mat then
                local on = windowUi.texStarred(o, kind)
                if ui.smallIcon(id .. "_star" .. i, on and "star" or "star_border", lookup(on and "remove from my configurations" or "add to my configurations"),
                                on and ui.orange or nil) then
                    windowUi.texStar(o, kind)
                    T.opts[id] = nil
                end
                imgui.SameLine()
            end
            local tex = imgui.IsRectVisible1(consts.vec40) and windowUi.thumb(o) or nil
            local hit = false
            if tex and tex.texId then
                hit = imgui.ImageButton("##" .. id .. "_tex" .. i, tex.texId, consts.vec40)
            else
                imgui.Dummy(consts.vec40)
            end
            local over = imgui.IsItemHovered()
            imgui.SameLine()
            if imgui.Selectable1(rtl(o.label) .. "##" .. id .. "_opt" .. i, o.value == cur or hot) then hit = true end
            return hit, over or imgui.IsItemHovered()
        end,
        take   = function(o)
            local value = windowUi.texTake(o, kind)
            if not value then return false, "could not copy the material into the map", nil end
            return true, value, texture.material(value) or value
        end,
    }, write)
end

function windowUi.texOf(value, kind)
    if not value or value == "" then return nil end
    local st = geometry.mr.styleFor(value, kind)
    if not (st and st.material) then return nil end
    local su, sv = geometry.mr.styleScale(st, st.material)
    local off    = st.off or {}
    return {mat = st.material, u = su, v = sv, rot = texture.turnOf(st.rot), ou = off[1] or 0, ov = off[2] or 0, label = st.label}
end

function windowUi.texControls(id, kind, t, save)
    local T      = windowUi.tex
    local on     = getFlagCols().on
    local turned = t.rot ~= 0
    local moved  = t.ou ~= 0 or t.ov ~= 0
    local items  = {
        ui.iconItem(id .. "_rot", "tb_rotate_right", tr("turn the texture: %d degrees - click for %d", t.rot, (t.rot + 90) % 360), turned and on or nil),
        ui.iconItem(id .. "_size", "format_size", lookup("texture size"), T.open[id .. "_size"] and on or nil),
        ui.iconItem(id .. "_off", "fastTravel", lookup("texture offset"), (moved or T.open[id .. "_off"]) and on or nil),
    }
    if save then items[#items + 1] = ui.iconItem(id .. "_save", "Save", lookup("save as a configuration"), T.open[id .. "_save"] and on or nil) end
    local hit = ui.row(items)
    if hit == id .. "_rot" then
        t.rot = (t.rot + 90) % 360
        return t
    elseif hit then
        T.open[hit] = not T.open[hit]
    end
    local out = nil
    local was = ui.open
    if T.open[id .. "_size"] and ui.beginProps(id .. "_sizep") then
        if T.lock[id] == nil then T.lock[id] = true end
        ui.prop(lookup("repeat length (m)"))
        local u = ui.number(id .. "_u", id .. "_udec", id .. "_uinc", t.u, 0.05, 100.0)
        ui.prop(lookup("repeat width (m)"))
        local v = ui.number(id .. "_v", id .. "_vdec", id .. "_vinc", t.v, 0.05, 100.0)
        ui.prop("")
        local lh, lv = ui.check(id .. "_lock", "keep the ratio", T.lock[id])
        if lh then T.lock[id] = lv end
        ui.endProps()
        ui.open = was
        if u then
            if T.lock[id] then t.v = math.floor(t.v * u / t.u * 1000 + 0.5) / 1000 end
            t.u, out = u, t
        elseif v then
            if T.lock[id] then t.u = math.floor(t.u * v / t.v * 1000 + 0.5) / 1000 end
            t.v, out = v, t
        end
    end
    if T.open[id .. "_off"] and ui.beginProps(id .. "_offp") then
        ui.prop(lookup("offset along (m)"))
        local a = ui.number(id .. "_ou", id .. "_oudec", id .. "_ouinc", t.ou, -100.0, 100.0, 0)
        ui.prop(lookup("offset across (m)"))
        local b = ui.number(id .. "_ov", id .. "_ovdec", id .. "_ovinc", t.ov, -100.0, 100.0, 0)
        ui.endProps()
        ui.open = was
        if a then t.ou, out = a, t elseif b then t.ov, out = b, t end
    end
    if save and T.open[id .. "_save"] then
        if not T.bufs[id] then
            T.bufs[id] = imgui.ArrayChar(64)
            bufWrite(T.bufs[id], t.label or windowUi.matLabel(t.mat))
        end
        T.cats[id] = T.cats[id] or {[kind] = true}
        local buf  = T.bufs[id]
        local name = {w = consts.dimFieldW * 2, draw = function()
            imgui.PushItemWidth(consts.dimFieldW * 2)
            imgui.InputText("##" .. id .. "_name", buf, 64)
            imgui.PopItemWidth()
        end}
        local marks = {}
        for _, k in ipairs(texture.kinds) do marks[#marks + 1] = {id .. "_cat_" .. k, windowUi.texKindLabel[k], T.cats[id][k] == true} end
        local ch, cv = ui.checks(marks)
        if ch then T.cats[id][ch:sub(#id + 6)] = cv or nil end
        if ui.row({name, ui.act(id .. "_savego", iconOf.save, "save", ui.add)}) then
            local label = bufRead(buf):gsub("^%s+", ""):gsub("%s+$", "")
            if label == "" then label = windowUi.matLabel(t.mat) end
            local cats = {kind}
            for _, k in ipairs(texture.kinds) do
                if T.cats[id][k] and k ~= kind then cats[#cats + 1] = k end
            end
            local key = windowUi.texSave(kind, t, label, cats)
            if key then
                T.open[id .. "_save"], T.bufs[id], T.cats[id] = nil, nil, nil
                statusText = tr("configuration %s saved", label)
                return t, key
            end
        end
    end
    return out
end

function windowUi.cfgEdit(fn)
    local data = readStyles(cfgPath)
    if not data then
        statusText = "cannot read the config for writing"
        return false
    end
    fn(data)
    if not commitConfig(data) then return false end
    loadConfig()
    return true
end

function windowUi.configRows()
    local rows, lib, keys = {}, texture.library().configs, {}
    for k in pairs(lib) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do rows[#rows + 1] = {id = "lib_" .. k, key = k, e = lib[k], cats = lib[k].cats or {}} end
    for _, ax in ipairs(texture.kinds) do
        local styles, sk = cfg and cfg[ax] and cfg[ax].styles or {}, {}
        for k, st in pairs(styles) do
            if st.config then sk[#sk + 1] = k end
        end
        table.sort(sk)
        for _, k in ipairs(sk) do
            local cats = {ax}
            for _, c in ipairs(styles[k].also or {}) do cats[#cats + 1] = c end
            rows[#rows + 1] = {id = ax .. "_" .. k, key = k, axis = ax, e = styles[k], cats = cats}
        end
    end
    return rows
end

function windowUi.configSet(r, fn)
    if r.axis then
        return windowUi.cfgEdit(function(data) fn(data[r.axis].styles[r.key], r.axis) end)
    end
    fn(texture.library().configs[r.key])
    texture.saveLibrary()
    return windowUi.cfgEdit(function(data)
        for _, ax in ipairs(texture.kinds) do
            for _, st in pairs(data[ax] and data[ax].styles or {}) do
                if st.from == r.key then fn(st, ax) end
            end
        end
    end)
end

function windowUi.drawConfigs()
    if not section("my configurations", true) then return end
    local T    = windowUi.tex
    local rows = windowUi.configRows()
    if #rows == 0 then
        text("no configurations yet - save one with the save icon under any texture, or with the star in the list", ui.grey)
        return
    end
    for _, r in ipairs(rows) do
        local e, names = r.e, {}
        for _, c in ipairs(r.cats) do names[#names + 1] = lookup(windowUi.texKindLabel[c] or c) end
        local sel = T.sel == r.id
        local hit = ui.row({ui.btnItem(e.label or r.key, "cfg_" .. r.id, sel and ui.pick or ui.off),
                            ui.textItem(rtl(table.concat(names, ", ") .. "  -  " .. lookup(r.axis and "this map" or "all maps")), ui.grey),
                            ui.iconItem("cfgdel_" .. r.id, iconOf.remove, lookup("remove"))})
        if hit == "cfg_" .. r.id then
            T.sel = (not sel) and r.id or nil
            sel   = T.sel == r.id
        elseif hit == "cfgdel_" .. r.id then
            if r.axis then
                windowUi.cfgEdit(function(data) data[r.axis].styles[r.key] = nil end)
            else
                texture.library().configs[r.key] = nil
                texture.saveLibrary()
            end
            statusText = tr("configuration %s removed", e.label or r.key)
            return
        end
        if sel then windowUi.drawConfig(r) end
    end
end

function windowUi.drawConfig(r)
    local T, e, id = windowUi.tex, r.e, "cfged_" .. r.id
    if not T.bufs[id] then
        T.bufs[id] = imgui.ArrayChar(64)
        bufWrite(T.bufs[id], e.label or r.key)
    end
    local buf  = T.bufs[id]
    local name = {w = consts.dimFieldW * 2, draw = function()
        imgui.PushItemWidth(consts.dimFieldW * 2)
        imgui.InputText("##" .. id .. "_name", buf, 64)
        imgui.PopItemWidth()
    end}
    if ui.row({name, ui.act(id .. "_rename", iconOf.rename, "rename")}) then
        local label = bufRead(buf):gsub("^%s+", ""):gsub("%s+$", "")
        if label ~= "" and windowUi.configSet(r, function(st) st.label = label end) then statusText = tr("configuration %s saved", label) end
        return
    end
    local on, marks = {}, {}
    for _, c in ipairs(r.cats) do on[c] = true end
    for _, k in ipairs(texture.kinds) do marks[#marks + 1] = {id .. "_cat_" .. k, windowUi.texKindLabel[k], on[k] == true} end
    local ch, cv = ui.checks(marks)
    if ch then
        local k = ch:sub(#id + 6)
        if r.axis and k == r.axis then return end
        on[k] = cv or nil
        local cats = {}
        for _, c in ipairs(texture.kinds) do
            if on[c] then cats[#cats + 1] = c end
        end
        if #cats == 0 then return end
        if r.axis then
            windowUi.cfgEdit(function(data)
                local also = {}
                for _, c in ipairs(cats) do
                    if c ~= r.axis then also[#also + 1] = c end
                end
                data[r.axis].styles[r.key].also = (#also > 0) and also or nil
            end)
        else
            texture.library().configs[r.key].cats = cats
            texture.saveLibrary()
        end
        return
    end
    local sc  = e.scale or {}
    local off = e.off or {}
    local t   = {mat = e.mat or e.material, u = e.u or sc[1] or 1.0, v = e.v or sc[2] or sc[1] or 1.0, rot = texture.turnOf(e.rot),
                 ou = e.ou or off[1] or 0, ov = e.ov or off[2] or 0}
    local nt  = windowUi.texControls(id, r.cats[1], t, false)
    if not nt then return end
    windowUi.configSet(r, function(st)
        local rot, moved = texture.turnOf(nt.rot), (nt.ou ~= 0 or nt.ov ~= 0)
        if st.material then
            st.scale, st.rot, st.off = {nt.u, nt.v}, (rot ~= 0) and rot or nil, moved and {nt.ou, nt.ov} or nil
        else
            st.u, st.v, st.rot, st.ou, st.ov = nt.u, nt.v, rot, nt.ou, nt.ov
        end
    end)
end

function windowUi.trying()
    return trial.map ~= nil
end

function windowUi.tryWrite(write, v)
    local status  = statusText
    trial.map     = {}
    local ok, err = pcall(write, v)
    local map     = trial.map
    trial.map     = nil
    statusText    = status
    if not ok then error(err, 0) end
    local show, seen = {}, {}
    for id in pairs(map) do
        local all = building.group(id)
        for _, fid in ipairs((#all > 0) and all or {id}) do
            if not seen[fid] then
                seen[fid]       = true
                show[#show + 1] = fid
            end
        end
    end
    table.sort(show, function(a, b) return tostring(a) < tostring(b) end)
    for id, f in pairs(map) do
        local same = true
        for k, val in pairs(f) do same = same and (dynValue(id, k) or "") == val end
        if same then map[id] = nil end
    end
    return map, show
end

function windowUi.texMine(axis, ids)
    local lib, keys = texture.library().configs, {}
    for k, e in pairs(lib) do
        if texture.inKind(e, axis) then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local pre   = "quick_" .. axis .. "_"
    local items = {}
    for _, k in ipairs(keys) do items[#items + 1] = ui.btnItem(lib[k].label or k, pre .. k, ui.add) end
    local hit = (#items > 0) and ui.row(items) or nil
    if hit then
        local key = windowUi.texFromLib(hit:sub(#pre + 1), axis)
        if key then applyValue(fieldOf[axis], key, ids) end
    end
end

function windowUi.texMore(axis, ids)
    local cur, state = selectionValue(ids, fieldOf[axis])
    local empty      = (axis == "walk") and "the config's top surface" or "the config's curb"
    windowUi.texField("more_" .. axis, axis, cur, empty, (state == "mixed") and lookup("(mixed)") or nil, nil, function(v)
        applyValue(fieldOf[axis], v or "", ids)
    end)
end

function windowUi.texField(id, kind, cur, empty, shown, all, write)
    local picked, value = windowUi.texPick(id, kind, cur, empty, shown, all, write)
    if picked or value then return picked, value end
    local t = (not shown) and windowUi.texOf(cur, kind) or nil
    if not t then return nil end
    local nt, key = windowUi.texControls(id, kind, t, true)
    local v       = key or (nt and texture.encode(nt))
    if not v then return nil end
    if write then write(v) end
    return true, v
end

function windowUi.kindButton(id, f)
    local cols = getFlagCols()
    local cur  = gateUi.kindOf(f)
    local nxt  = windowUi.order[1]
    for i, k in ipairs(windowUi.order) do
        if k == cur then nxt = windowUi.order[i % #windowUi.order + 1] end
    end
    local line = tr("%s: %s - click for %s", lookup("shape"), lookup(windowUi.labels[cur]), lookup(windowUi.labels[nxt]))
    return iconButton(id, gateUi.iconOf[cur], windowUi.labels[cur], cols.on, line) and nxt or nil
end

function windowUi.applyModule(fl, path)
    fl.dae     = path
    local w, h = modules.hole(path or "")
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
    cfg.depth, cfg.margin, cfg.floorGap, cfg.sink = base.depth, base.margin, base.floorGap, base.sink
    cfg.faces, cfg.walls, cfg.mods, cfg.off       = {}, {}, {}, {}
    for _, k in ipairs(window.modKeys) do cfg.mods[k] = window.cleanMod(base.mods[k]) end
    for _, k in ipairs(window.faceKeys) do
        cfg.faces[k] = base.faces[k]
        cfg.walls[k] = base.walls[k]
        cfg.off[k]   = base.off[k]
    end
    return cfg
end

function windowUi.pickLook(pid, ids, key, label, empty, kind)
    local cur, state = selectionValue(ids, fieldOf[key])
    ui.back(pid .. "_default", label, (cur ~= nil and cur ~= "") or state == "mixed", function()
        transaction("MageLook", function()
            for _, id in ipairs(ids) do writeField(id, fieldOf[key], "") end
        end)
    end)
    local picked, value = windowUi.texField(pid, kind, cur, empty, (state == "mixed") and lookup("(mixed)") or nil, true, function(v)
        transaction("MageLook", function()
            for _, id in ipairs(ids) do writeField(id, fieldOf[key], v or "") end
        end)
    end)
    if picked then
        statusText = tr("%s: %s", lookup(label), windowUi.texLabel(value, kind, empty))
    elseif value then
        statusText = value
    end
end

function windowUi.drawOpening(id, cfg, k, pre, edit)
    local fl      = cfg.floors[k]
    local door    = fl.at ~= nil
    local name    = windowUi.lineLabel(fl)
    local changed = false
    if not ui.beginProps(pre .. "props") then return false end
    if door and not edit then
        ui.prop(lookup("position along the face (0 = start, 1 = end)"))
        local v = ui.number("windoorat", "windoorat_dec", "windoorat_inc", fl.at, 0.0, 1.0, 0.5)
        if v then
            fl.at   = v
            changed = true
        end
    end
    ui.prop(lookup("shape"))
    local kind = windowUi.kindButton(pre .. "style", fl)
    if kind then
        gateUi.setKind(fl, kind)
        if kind ~= "rect" then fl.dae = nil else fl.rise = nil end
        statusText = tr("%s: %s", name, lookup(windowUi.labels[kind]))
        changed    = true
    end
    local mk = door and "doors" or "windows"
    if window.modOf(cfg, mk) and fl.style == "rect" then
        local opts = {}
        for _, path in ipairs(modules.list(mk)) do opts[#opts + 1] = {value = path, label = modules.label(path)} end
        ui.prop(lookup("model"))
        local picked, value = windowUi.picker(pre .. "model", nil, fl.dae and modules.resolve(fl.dae) or nil, opts, (not fl.dae) and lookup("choose a model") or nil, function(v)
            if edit then return edit(function(r) windowUi.applyModule(r, v) end) end
            if not windowUi.trying() then
                windowUi.applyModule(fl, v)
                changed = true
                return
            end
            local c = window.parse(window.encode(cfg))
            windowUi.applyModule(c.floors[k], v)
            windowUi.write(id, c)
        end)
        if picked and value then statusText = tr("%s: %s", name, modules.label(value)) end
    end
    local locked = window.modOf(cfg, mk) ~= nil and fl.dae ~= nil and fl.style == "rect"
    for _, f in ipairs(windowUi.rowFields) do
        local skip = ((door or fl.count) and f.key == "gap") or (locked and (f.key == "width" or f.key == "height"))
        if not skip then
            ui.prop(lookup(f.label))
            local v = windowUi.number(pre .. f.key, fl[f.key], f.key)
            if v then
                fl[f.key]  = v
                changed    = true
                statusText = tr("%s set to %s", lookup(f.label), string.format("%g", v))
            end
        end
    end
    if locked then
        ui.prop(lookup("size"))
        local rw, rh = window.rowSize(fl)
        textv(tr("%s x %s m, from the game's file", string.format("%g", rw), string.format("%g", rh)), ui.grey)
    end
    if windowUi.drawRowMore(fl, pre, cfg.margin) then changed = true end
    ui.prop(lookup("texture"))
    local picked, value = windowUi.texField(pre .. "wallf", "wall", fl.wall, "as the face", nil, nil, function(v)
        if edit then return edit(function(r) r.wall = (v ~= "") and v or nil end) end
        if not windowUi.trying() then
            fl.wall, changed = (v ~= "") and v or nil, true
            return
        end
        local c          = window.parse(window.encode(cfg))
        c.floors[k].wall = (v ~= "") and v or nil
        windowUi.write(id, c)
    end)
    tip("the config's wall materials or Building Architect's; the windows' own texture wins over its face's")
    if picked then
        statusText = tr("%s: %s", name, windowUi.texLabel(value, "wall", "as the face"))
    elseif value then
        statusText = value
    end
    ui.endProps()
    if changed and not edit then windowUi.write(id, cfg) end
    return changed
end

function windowUi.rowsOf(cfg)
    local out = {}
    for k, f in ipairs(cfg and cfg.floors or {}) do
        if not f.at then out[#out + 1] = k end
    end
    return out
end

function windowUi.freeAt(cfg, face)
    local ats = {0.0, 1.0}
    for _, f in ipairs(cfg.floors) do
        if f.at and (f.face or "right") == face then ats[#ats + 1] = f.at end
    end
    if #ats == 2 then return 0.5 end
    table.sort(ats)
    local best, at = -1, 0.5
    for i = 1, #ats - 1 do
        if ats[i + 1] - ats[i] > best then best, at = ats[i + 1] - ats[i], (ats[i] + ats[i + 1]) / 2.0 end
    end
    return math.floor(at * 1000 + 0.5) / 1000
end

function windowUi.drawRows(id, ids)
    local cfg  = windowUi.read(id)
    local rows = windowUi.rowsOf(cfg)
    if #rows == 0 then
        text("no windows on this floor yet", ui.grey)
        if ui.row({ui.act("winnew", iconOf.addWindows, "add windows", ui.add)}) then
            local base  = windowUi.base(ids, id)
            local added = building.defaultWindows(false).floors[1]
            if base and not window.modOf(base, "windows") then added.dae = nil end
            if not cfg then
                cfg        = windowUi.inherit(building.defaultWindows(false), base)
                cfg.floors = {}
            end
            cfg.floors[#cfg.floors + 1] = added
            windowUi.write(id, cfg)
            windowUi.line[id] = windowUi.indexOf(cfg, added)
            statusText        = "windows added"
        end
        tip(tr("a row of windows along every face, the size of the game's window: %s x %s m, 1 m above the floor", string.format("%g", building.defaults.winW),
               string.format("%g", building.defaults.winH)))
        presetUi.draw("windows", window.newConfig("round"), lookup("windows"), function(v)
            local fixed = window.clean(v)
            if fixed then windowUi.write(id, fixed) end
        end)
        return
    end

    local wallH = windowUi.wallHeight(id)
    local sel   = rows[1]
    for _, k in ipairs(rows) do
        if k == windowUi.line[id] then sel = k end
    end
    if #rows > 1 then
        local opts = {}
        for n, k in ipairs(rows) do
            local fl   = cfg.floors[k]
            opts[n] = {key = tostring(k), label = tr("row %d", n),
                       tip = (window.fits(fl, wallH) or window.lowers(fl, wallH)) and windowUi.lineLabel(fl) or lookup("does not fit in this floor's height")}
        end
        local hit = ui.segment("winline", opts, tostring(sel), nil, 4)
        if hit then
            sel, windowUi.line[id] = tonumber(hit), tonumber(hit)
        end
    end
    windowUi.drawMisses(id, cfg, function(_, fl) return windowUi.lineLabel(fl) end)
    if ui.beginProps("winrowgap") then
        ui.prop(lookup("gap between rows (for the next row added)"))
        local g = windowUi.number("bldfloorGap", cfg.floorGap, "floorGap")
        if g then
            cfg.floorGap = g
            windowUi.write(id, cfg)
            statusText = tr("%s set to %s", lookup("gap between rows (for the next row added)"), string.format("%g", g))
        end
        ui.endProps()
    end
    local hit = ui.row({ui.act("winaddabove", iconOf.rowAbove, "row above", ui.add), ui.act("winaddbelow", iconOf.rowBelow, "row below", ui.add)})
    tip("a new row copies the row next to it, the gap between rows apart, then can be changed on its own")
    local added, note
    if hit == "winaddabove" then
        local f = window.above(cfg.floors[rows[#rows]], cfg.floorGap)
        if window.fits(f, wallH) then added = f else note = "no room for windows above the highest ones" end
    elseif hit == "winaddbelow" then
        local f = window.below(cfg.floors[rows[1]], cfg.floorGap)
        if f then added = f else note = "no room for windows below the lowest ones" end
    end
    if note then statusText = note end
    if added then
        cfg.floors[#cfg.floors + 1] = added
        windowUi.write(id, cfg)
        windowUi.line[id] = windowUi.indexOf(cfg, added)
        statusText        = "windows added"
        return
    end

    local fl = cfg.floors[sel]
    if window.lowers(fl, wallH) then
        text("too high for this floor at this height: built lower, so it fits", ui.orange)
    elseif not window.fits(fl, wallH) then
        text("does not fit in this floor's height", ui.orange)
    end
    if windowUi.drawOpening(id, cfg, sel, "win") then
        sel               = windowUi.indexOf(cfg, fl)
        windowUi.line[id] = sel
    end
    if ui.row({ui.act("winfloordel", iconOf.remove, (#rows > 1) and "remove this row" or "remove the windows")}) then
        table.remove(cfg.floors, sel)
        windowUi.write(id, cfg)
        statusText = "windows removed"
        return
    end
    local first = cfg.floors[rows[1]]
    local auto  = string.format("%s %g/%g/%g", lookup(windowUi.labels[gateUi.kindOf(first)]), first.width, first.height, cfg.depth)
    presetUi.draw("windows", cfg, auto, function(v)
        local fixed = window.clean(v)
        if fixed then windowUi.write(id, fixed) end
    end)
end

-- =============================================================================
-- BUILDINGS
-- =============================================================================

local buildingUi = {current = nil, sel = {}, multi = false, mod = "windows", doorSel = {}, view = nil, picked = nil, open = false,
                    goneAt = -math.huge, goneEvery = 0.5, goneShells = nil, goneKeys = nil, optsCache = nil, optsAge = 1.0,
                    push = nil, pushStep = true, viewMin = 20.0, viewTilt = math.rad(20.0), partId = nil, pushFrom = false, pickWas = nil, wins = {}}

function buildingUi.cameraSpot()
    local p = core_camera.getPosition()
    return vec3(p.x, p.y, p.z)
end

function buildingUi.focus(id)
    local v    = building.view(id)
    local dist = math.max(buildingUi.viewMin, v.size)
    local pos  = v.center + v.right * (dist * math.cos(buildingUi.viewTilt)) + vec3(0, 0, dist * math.sin(buildingUi.viewTilt))
    local rot  = quatFromDir(v.center - pos)
    core_camera.setPosRot(0, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
end

function buildingUi.isOn(id)
    if building.dataOf(id) then return true end
    local cfg = windowUi.read(id)
    return cfg ~= nil and not cfg.plain
end

function buildingUi.floorsOf(id)
    if not buildingUi.isOn(id) then return {} end
    local ids = building.group(id)
    if #ids == 0 then ids = {id} end
    return ids
end

function buildingUi.setOn(id, on)
    transaction("MageBuilding", function()
        writeField(id, fieldOf.building, on and building.encode(building.newData(nil)) or "")
        if not on then writeField(id, fieldOf.windows, "") end
    end)
    building.index(true)
    statusText = on and "building on" or "building off"
end

function buildingUi.drawTop(id)
    if not id then return end
    local on    = buildingUi.isOn(id)
    local ptr   = imgui.BoolPtr(on)
    local items = {ui.markItem("bldon", "define as a building", ptr)}
    items[1].tip = "off: a plain MeshRoad. turning it off removes this MeshRoad's windows, doors and floor link (ctrl+z brings them back)"
    local bend  = imgui.BoolPtr(on and building.dataOf(id) ~= nil and town.bent(id))
    if on and building.dataOf(id) then
        items[2]     = ui.markItem("bldbent", "bend along the road", bend)
        items[2].tip = "the building follows the curve of the nearest road and keeps its distance from it. off: straight again, exactly as it was"
    end
    local hit = ui.row(items)
    if hit == "bldon" then
        buildingUi.setOn(id, ptr[0])
    elseif hit == "bldbent" then
        local ok, err
        if bend[0] then ok, err = town.bend(id) else ok = town.straighten(id) end
        building.index(true)
        if ok then
            dirty()
            buildingUi.show(id)
        end
        statusText = ok and (bend[0] and "bent along the road" or "straight again") or tostring(err)
    end
end

function buildingUi.drawSaved(lib, id)
    buildingUi.savedBuf = buildingUi.savedBuf or imgui.ArrayChar(64)
    local buf           = buildingUi.savedBuf
    local root          = id and building.dataOf(id) and building.homeOf(id) or nil
    local name          = {w = consts.dimFieldW * 2, draw = function()
        imgui.PushItemWidth(consts.dimFieldW * 2)
        imgui.InputText("##bldsavedname", buf, 64)
        imgui.PopItemWidth()
    end}
    local save = ui.act("bldsavedsave", iconOf.save, "save this building")
    save.tip   = "the building shown in the table, exactly as it is now: its floors, parts, sizes, models and materials"
    if ui.row({save, name}) then
        local text0 = bufRead(buf):gsub("^%s+", ""):gsub("%s+$", "")
        local t     = root and building.capture(root)
        if not t then
            statusText = "choose a building to save first"
        elseif text0 == "" then
            statusText = "give it a name first"
        elseif building.editSaved(function(d) d.items[text0] = t end) then
            bufWrite(buf, "")
            statusText = tr("building %s saved", text0)
        else
            statusText = "could not write the saved buildings file"
        end
    end
    local names = {}
    for k in pairs(lib.items) do names[#names + 1] = k end
    table.sort(names)
    local function entry(label, id, on)
        return ui.btnItem(label, id, on and ui.pick or ui.off, on and ui.white or ui.grey)
    end
    local hit = ui.row({entry(lookup("MaGE's defaults"), "bldsaveddef", lib.default == nil)})
    if hit and building.editSaved(function(d) d.default = nil end) then statusText = lookup("'create a building' makes MaGE's defaults") end
    local gen, marked = type(lib.gen) == "table" and lib.gen or {}, 0
    for k, n in ipairs(names) do
        local ptr  = imgui.BoolPtr(gen[n] == true)
        local mark = ui.markItem("bldsavedgen_" .. k, "in the generator", ptr)
        mark.tip   = "the random building and the buildings along roads are drawn from the marked ones"
        if gen[n] == true then marked = marked + 1 end
        hit = ui.row({entry(n, "bldsaveduse_" .. k, lib.default == n), mark, ui.act("bldsaveddel_" .. k, iconOf.remove, "delete")})
        if hit == "bldsaveduse_" .. k then
            if building.editSaved(function(d) d.default = n end) then statusText = tr("'create a building' makes %s", n) end
        elseif hit == "bldsavedgen_" .. k then
            local on = ptr[0]
            if building.editSaved(function(d)
                d.gen    = type(d.gen) == "table" and d.gen or {}
                d.gen[n] = on or nil
            end) then
                statusText = on and tr("%s is in the generator", n) or tr("%s is out of the generator", n)
            end
        elseif hit then
            if building.editSaved(function(d)
                d.items[n] = nil
                if type(d.gen) == "table" then d.gen[n] = nil end
            end) then
                statusText = tr("building %s deleted", n)
            end
        end
    end
    text("the marked one is what 'create a building' makes. saved buildings are kept for every map", ui.grey)
    if marked == 0 then
        text("none is in the generator, so it makes MaGE's building", ui.grey)
    else
        text(tr("the generator draws from the %d buildings in it", marked), ui.grey)
    end
end

function buildingUi.watchFrom(root)
    buildingUi.view = {root = root, sel = table.concat(getSelection(), ",")}
end

function buildingUi.group(root)
    local known = {root}
    return function()
        for _, id in ipairs(known) do
            local ids = building.group(id)
            if #ids > 0 then
                known = ids
                return ids
            end
        end
        return {}
    end
end

function buildingUi.show(root)
    local fn     = buildingUi.group(root)
    local status = preview.renderGroup(fn)
    preview.setLive(true)
    buildingUi.watchFrom(fn()[1] or root)
    return status
end

function buildingUi.pin(id)
    if id ~= buildingUi.current then buildingUi.partId = nil end
    local same = false
    for _, f in ipairs(buildingUi.current and buildingUi.floorsOf(buildingUi.current) or {}) do
        if f == id then same = true end
    end
    buildingUi.current = id
    if same or not id then return end
    buildingUi.sel = {}
    buildingUi.show(id)
end

function buildingUi.staticOf(id)
    if classOf(id) ~= "TSStatic" and classOf(id) ~= "Prefab" then return nil end
    local pre, n = geometry.mr.daePrefix .. "b", objName(id)
    return n:sub(1, #pre) == pre and building.ofKey(n:sub(#pre + 1)) or nil
end

function buildingUi.wholeOf(sel)
    local ids = buildingUi.open and buildingUi.current and buildingUi.floorsOf(buildingUi.current) or {}
    if #ids == 0 or #buildingUi.selected(ids) > 0 then return nil end
    local mine = {}
    for _, fid in ipairs(ids) do mine[fid] = true end
    for _, id in ipairs(sel) do
        if not mine[id] then return nil end
    end
    return ids[1]
end

function buildingUi.oneBuilding(sel)
    local root = nil
    for _, id in ipairs(sel) do
        local r = building.dataOf(id) and building.homeOf(id)
        if not r or (root and r ~= root) then return nil end
        root = r
    end
    return root
end

function buildingUi.render()
    local sel  = getSelection()
    local root = (#sel == 1 and buildingUi.staticOf(sel[1])) or buildingUi.wholeOf(sel) or buildingUi.oneBuilding(sel)
    if not root then return buildingUi.showRoads(sel) end
    return buildingUi.show(root)
end

function buildingUi.showRoads(sel)
    local all = findUnskinned("MeshRoad")
    for _, id in ipairs(findUnskinned("DecalRoad")) do all[#all + 1] = id end
    local core   = preview.chainOf(sel, all)
    local ids    = exporter.contextOf(core, all)
    local status = preview.renderGroup(function() return ids end, core)
    preview.setLive(#sel <= preview.liveMaxRoads())
    if not preview.isLive() then status = tr("rendered %d - auto refresh turned off above %d roads", #sel, preview.liveMaxRoads()) end
    return status
end

function buildingUi.select(id, edit)
    buildingUi.current = id
    for _, k in ipairs(ui.keep and ui.keep.peek and ui.keep.ids or {}) do preview.peekSource(k, false) end
    ui.keep = nil
    if not id then
        editor.clearObjectSelection()
        return
    end
    if edit then
        preview.peekSource(id, true)
        enterEditMode("meshRoadEditMode")
        ui.keep = {ids = {id}, frames = 10, peek = true}
    end
    editor.selectObjects({id})
end

function buildingUi.floorAction(fid, dir)
    local rest, pos = nil, 1
    for k, id in ipairs(building.chain(fid)) do
        if id == fid then pos = k end
    end
    preview.clearPreview()
    transaction("MageFloors", function()
        if dir == 0 then rest = building.removeFloor(fid) else building.moveFloor(fid, dir) end
    end)
    building.index(true)
    dirty()
    if dir == 0 then
        buildingUi.select(rest[math.max(pos - 1, 1)])
        if #rest > 0 then buildingUi.show(rest[1]) else preview.clearPreview() end
        statusText = "floor removed"
        return
    end
    buildingUi.show(fid)
    statusText = (dir > 0) and "floor moved up" or "floor moved down"
end

function buildingUi.pickerOpts(list)
    local c = buildingUi.optsCache
    if c and c.list == list and os.clock() - c.at < buildingUi.optsAge then return c.opts end
    local opts = {}
    for _, b in ipairs(list) do
        local name      = objName(b.id)
        opts[#opts + 1] = {value = b.id, label = tr("%s - %d floors", name ~= "" and name or tostring(b.id), b.floors)}
    end
    buildingUi.optsCache = {list = list, at = os.clock(), opts = opts}
    return opts
end

function buildingUi.drawPicker(id)
    local list = building.buildings()
    if #list == 0 then return end
    local home = id and building.homeOf(id)
    local opts = buildingUi.pickerOpts(list)
    local cur  = nil
    for _, b in ipairs(list) do
        if b.id == home then cur = b.id end
    end
    local picked, value = windowUi.picker("bldpick", lookup("building"), cur, opts, (not cur) and lookup("choose a building") or nil)
    if picked and value then
        local was = buildingUi.current and building.homeOf(buildingUi.current)
        buildingUi.pin(value)
        if was == value then buildingUi.show(value) end
        buildingUi.focus(value)
        local data = building.dataOf(value)
        local obj  = data and scenetree.findObject(geometry.mr.daePrefix .. geometry.mr.buildingCell(data.key))
        editor.selectObjects(obj and {obj:getID()} or buildingUi.floorsOf(value))
        buildingUi.picked = obj and obj:getID() or nil
        statusText        = tr("%s shown", windowUi.nameOf(value, opts))
    end
end

function buildingUi.key(fid, face)
    return tostring(fid) .. "|" .. face
end

function buildingUi.selected(ids)
    local out = {}
    for k, fid in ipairs(ids) do
        for _, face in ipairs(window.faceKeys) do
            if buildingUi.sel[buildingUi.key(fid, face)] then out[#out + 1] = {fid = fid, face = face, k = k} end
        end
    end
    return out
end

function buildingUi.cells(ids)
    local out = buildingUi.selected(ids)
    if #out > 0 then return out end
    for k, fid in ipairs(ids) do
        for _, face in ipairs(window.faceKeys) do out[#out + 1] = {fid = fid, face = face, k = k} end
    end
    return out
end

function buildingUi.prune(ids)
    local keep = {}
    for _, c in ipairs(buildingUi.selected(ids)) do keep[buildingUi.key(c.fid, c.face)] = true end
    buildingUi.sel = keep
end

function buildingUi.rowFull(fid)
    for _, face in ipairs(window.faceKeys) do
        if not buildingUi.sel[buildingUi.key(fid, face)] then return false end
    end
    return true
end

function buildingUi.colFull(ids, face)
    for _, fid in ipairs(ids) do
        if not buildingUi.sel[buildingUi.key(fid, face)] then return false end
    end
    return #ids > 0
end

function buildingUi.fullRows(ids)
    local rows = {}
    for _, fid in ipairs(ids) do
        if buildingUi.rowFull(fid) then rows[#rows + 1] = fid end
    end
    return rows, #rows > 0 and #rows * #window.faceKeys == #buildingUi.selected(ids)
end

function buildingUi.pick(keys)
    if not buildingUi.multi then
        local cur, same = 0, true
        for _ in pairs(buildingUi.sel) do cur = cur + 1 end
        for _, k in ipairs(keys) do
            if not buildingUi.sel[k] then same = false end
        end
        buildingUi.sel = {}
        if not (same and cur == #keys) then
            for _, k in ipairs(keys) do buildingUi.sel[k] = true end
        end
        return
    end
    local all = true
    for _, k in ipairs(keys) do
        if not buildingUi.sel[k] then all = false end
    end
    for _, k in ipairs(keys) do buildingUi.sel[k] = (not all) or nil end
end

function buildingUi.roleOf(ids, k)
    return {ground = k == 1, roof = k == #ids}
end

function buildingUi.valueAt(c, key, face, role)
    if key == "windows" then
        if not (c and c.faces[face]) or c.off[face] then return "off" end
        return window.modAt(c, "windows", face) and "on" or "hole"
    end
    return (c and window.modAt(c, key, face, role)) and "on" or "off"
end

function buildingUi.stateOf(ids, key)
    local cfgs = {}
    for _, fid in ipairs(ids) do cfgs[fid] = windowUi.peek(fid) end
    if #buildingUi.selected(ids) == 0 and key ~= "windows" then
        local ons, upT, upF = 0, false, false
        for _, fid in ipairs(ids) do
            local m = cfgs[fid] and cfgs[fid].mods[key]
            if m and m.on then ons = ons + 1 end
            for _, face in ipairs(window.faceKeys) do
                if m and m.faces[face] == true then upT = true end
                if m and m.faces[face] == false then upF = true end
            end
        end
        if ons == #ids and not upF then return "on" end
        if ons == 0 and not upT then return "off" end
        return "mixed"
    end
    local state
    for _, c in ipairs(buildingUi.cells(ids)) do
        local v = buildingUi.valueAt(cfgs[c.fid], key, c.face, buildingUi.roleOf(ids, c.k))
        if state and state ~= v then return "mixed" end
        state = v
    end
    return state or "off"
end

buildingUi.roofKeys = {roof = true, roofborder = true, gutter = true}
buildingUi.ownModel = {roof = true, gutter = true, dish = true, awning = true, flowers = true, pots = true, roofac = true, roofdish = true, corbel = true,
                       pipe = true}

function buildingUi.linkOn(p)
    local b = building.dataOf(p.ids[1])
    return not (b and b.free)
end

function buildingUi.linked(list, key, byFloor)
    local parts, k = buildingUi.partsNow, buildingUi.partNow
    if buildingUi.roofKeys[key] or not parts or #parts < 2 or not parts[k] or not buildingUi.linkOn(parts[k]) then return list end
    local out = {}
    for _, c in ipairs(list) do out[#out + 1] = c end
    for j, p in ipairs(parts) do
        if j ~= k and buildingUi.linkOn(p) then
            for _, c in ipairs(list) do
                local fid = c.k and p.ids[c.k]
                local dir = fid and building.faceDir(c.fid, c.face)
                local f   = dir and building.faceToward(fid, dir)
                local t   = f and building.touching(fid)
                if byFloor and fid then
                    out[#out + 1] = {fid = fid, face = f or c.face, k = c.k}
                elseif f and not (t and t.covered[f]) then
                    out[#out + 1] = {fid = fid, face = f, k = c.k}
                end
            end
        end
    end
    return out
end

function buildingUi.linkedIds(ids)
    local parts, k = buildingUi.partsNow, buildingUi.partNow
    if not parts or #parts < 2 or not parts[k] or not buildingUi.linkOn(parts[k]) then return ids end
    local out = {}
    for _, id in ipairs(ids) do out[#out + 1] = id end
    for j, p in ipairs(parts) do
        if j ~= k and buildingUi.linkOn(p) then
            for _, id in ipairs(p.ids) do out[#out + 1] = id end
        end
    end
    return out
end

windowUi.linkFn = buildingUi.linked

function buildingUi.writeCells(ids, list, fn, link, byFloor)
    local base, byFid, order = windowUi.base(ids, ids[1]), {}, {}
    for _, c in ipairs(link and buildingUi.linked(list, link, byFloor) or list) do
        if not byFid[c.fid] then
            byFid[c.fid]        = {}
            order[#order + 1] = c.fid
        end
        table.insert(byFid[c.fid], c)
    end
    transaction("MageWindows", function()
        for _, fid in ipairs(order) do
            local c = windowUi.read(fid)
            if not c then
                c        = windowUi.inherit(building.defaultWindows(false), base)
                c.floors = {}
            end
            for _, cell in ipairs(byFid[fid]) do fn(c, cell.face, cell) end
            writeField(fid, fieldOf.windows, window.encode(c))
        end
    end)
end

function buildingUi.floorsIn(list)
    local seen, out = {}, {}
    for _, c in ipairs(list) do
        if not seen[c.fid] then
            seen[c.fid]   = true
            out[#out + 1] = c
        end
    end
    return out
end

function buildingUi.setMod(ids, key, v)
    local whole = #buildingUi.selected(ids) == 0
    if whole and key ~= "windows" then
        buildingUi.writeCells(ids, buildingUi.floorsIn(buildingUi.cells(ids)), function(c)
            c.mods[key].on, c.mods[key].faces = v, {}
        end, key, true)
        return
    end
    buildingUi.writeCells(ids, buildingUi.cells(ids), function(c, face)
        if key ~= "windows" then
            c.mods[key].faces[face] = v
            return
        end
        c.off[face] = (v == "off") or nil
        if v ~= "off" then
            if #windowUi.rowsOf(c) == 0 then
                local row = building.defaultWindows(false).floors[1]
                if v ~= "on" then row.dae = nil end
                table.insert(c.floors, row)
            elseif v == "on" then
                for _, k in ipairs(windowUi.rowsOf(c)) do
                    local fl = c.floors[k]
                    if not fl.dae and fl.style == "rect" then windowUi.applyModule(fl, building.defaultWindows(false).floors[1].dae) end
                end
            end
            c.faces[face]                   = true
            c.mods.windows.faces[face]      = (v == "on")
            if whole then c.mods.windows.on = (v == "on") end
        end
    end, key)
end

buildingUi.modList = {
    {key = "windows", label = "windows"},
    {key = "doors", label = "doors"},
    {key = "balcony", label = "balconies"},
    {key = "awning", label = "awnings"},
    {key = "stairs", label = "stairs"},
    {key = "pillar", label = "pillars"},
    {key = "corbel", label = "corbels"},
    {key = "corner", label = "corners"},
    {key = "pilaster", label = "wall pilasters"},
    {key = "plinth", label = "plinth"},
    {key = "course", label = "string course"},
    {key = "roofborder", label = "roof border"},
    {key = "roof", label = "roof"},
    {key = "gutter", label = "gutters"},
    {key = "pipe", label = "downpipes"},
    {key = "ac", label = "air conditioners"},
    {key = "dish", label = "satellite dishes"},
    {key = "flowers", label = "flower boxes"},
    {key = "pots", label = "plant pots"},
    {key = "roofac", label = "air conditioners on the roof"},
    {key = "roofdish", label = "satellite dishes on the roof"},
}

buildingUi.notes = {
    windows    = "no windows, only openings in the wall, or openings with the window chosen here",
    doors      = "the doors' openings only, or with the door chosen here. doors are added in the cell of their face",
    balcony    = "under the windows. by default from the second floor up. chosen in the world it slides along its wall and up or down",
    stairs     = "in front of the doors, going down from their bottom",
    pillar     = "only under a floor that sticks out over the floor below, where a whole pillar fits",
    corner     = "on the corners of the floor, as high as the floor",
    pilaster   = "flat columns at the ends of each face, and between windows if you want",
    plinth     = "along the bottom. by default only on the ground floor",
    course     = "where one floor meets the next. by default from the second floor up",
    roofborder = "along the top. by default only on the top floor",
    roof       = "a pitched roof, by default only on the top floor. a lower floor partly under the one above: mark it, switch the roof on and keep it to part of the floor",
    gutter     = "along the eaves of a pitched roof. their material is the top surface's unless you pick one. mark a face to keep them to it. the downpipes are their own model",
    ac         = "beside the windows, at the window's bottom. with no room beside a window it goes under it, or is left out. chosen in the world it goes anywhere on the walls",
    dish       = "high on the wall, its bracket between two windows. by default only on the top floor. chosen in the world it goes anywhere on the walls",
    awning     = "over the windows, as wide as the window and a little more. by default on every floor. chosen in the world it slides along its wall and up or down",
    flowers    = "under the windows, not where there are balconies. chosen in the world it slides along its wall and up or down",
    pots       = "on the top of the floor, along its edge. by default only on the top floor, and not under a pitched roof. chosen in the world it slides along the edge",
    roofac     = "on the flat top of the top floor, not under a pitched roof. chosen in the world it moves anywhere on the roof",
    roofdish   = "on the flat top of the top floor, not under a pitched roof. chosen in the world it moves anywhere on the roof",
    corbel     = "under a floor that sticks out over the floor below, from the wall below up to the floor's bottom",
    pipe       = "from the ground up to the top of the top floor, with a head and clamps, near the corners where no window or door is in the way. chosen in the world it goes anywhere on the walls",
}

buildingUi.stateTint = {on = ui.white, off = imgui.ImVec4(0.38, 0.38, 0.38, 1), mixed = imgui.ImVec4(0.45, 0.82, 1, 1), hole = ui.white}
buildingUi.stateWord = {on = "on", off = "off", mixed = "mixed", hole = "openings only"}

function buildingUi.cellLabel(c, face)
    local mode  = buildingUi.valueAt(c, "windows", face)
    local word  = ({on = "windows", hole = "openings", off = "-"})[mode]
    local doors = 0
    for _, fl in ipairs(c and c.floors or {}) do
        if fl.at and (fl.face or "right") == face then doors = doors + 1 end
    end
    local own = c and c.walls[face] ~= nil
    for _, key in ipairs(window.modKeys) do
        if c and c.mods[key].faces[face] ~= nil and key ~= "windows" then own = true end
    end
    local out = lookup(word)
    if doors > 0 then out = out .. " +" .. doors end
    if own then out = out .. " *" end
    local tipText = tr("windows: %s", lookup(({on = "with a window", hole = "openings only", off = "no windows"})[mode])) .. "\n" .. tr("doors: %d", doors)
    if own then tipText = tipText .. "\n" .. lookup("* has its own settings") end
    return out, tipText
end

buildingUi.viewStates = {{key = "bones", label = "show the skeleton", icon = iconOf.meshes}, {key = "body", label = "show the building", icon = iconOf.buildings},
                         {key = "both", label = "show both", icon = iconOf.render}, {key = "none", label = "hide both", icon = iconOf.clearPreview}}
buildingUi.viewLabel  = {bones = "show the skeleton", body = "show the building", both = "show both", none = "hide both"}

function buildingUi.shells(id)
    local floors = buildingUi.floorsOf(id)
    local home   = building.homeOf(id)
    local data   = home and building.dataOf(home)
    local pf     = data and scenetree.findObject(geometry.mr.daePrefix .. geometry.mr.buildingCell(data.key))
    return floors, preview.meshList(floors), pf
end

function buildingUi.viewOf(id)
    local floors, meshes, pf = buildingUi.shells(id)
    local bones, body        = false, false
    for _, f in ipairs(floors) do
        local o = scenetree.findObjectById(f)
        if o and o.hidden ~= true then bones = true end
    end
    for _, m in ipairs(meshes) do
        if m.hidden ~= true then body = true end
    end
    if #meshes == 0 and pf then body = pf.hidden ~= true end
    return (bones and body) and "both" or (bones and "bones") or (body and "body") or "none"
end

function buildingUi.setView(id, state)
    local floors, meshes, pf = buildingUi.shells(id)
    local bones, body        = state == "bones" or state == "both", state == "body" or state == "both"
    for _, f in ipairs(floors) do
        local o = scenetree.findObjectById(f)
        if o then o.hidden = not bones end
    end
    for _, m in ipairs(meshes) do m.hidden = not body end
    if pf then pf.hidden = (#meshes > 0) or not body end
end

function buildingUi.syncGone()
    local now = os.clock()
    if now - buildingUi.goneAt < buildingUi.goneEvery then return end
    buildingUi.goneAt = now
    local pre         = geometry.mr.daePrefix .. "b"
    local shells      = {}
    for _, nm in ipairs(scenetree.findClassObjects("Prefab") or {}) do
        if nm:sub(1, #pre) == pre then shells[nm:sub(#pre + 1)] = true end
    end
    local keys = {}
    for _, e in ipairs(building.index().list) do
        if not e.data.below and not e.data.host then keys[e.data.key] = e.id end
    end
    preview.pruneGone()
    local wasShells, wasKeys                   = buildingUi.goneShells, buildingUi.goneKeys
    buildingUi.goneShells, buildingUi.goneKeys = shells, keys
    if not wasShells then return end
    local gone = {}
    for key in pairs(wasShells) do
        if not shells[key] and keys[key] and wasKeys[key] then gone[#gone + 1] = keys[key] end
    end
    for key in pairs(shells) do
        local o = wasKeys[key] and not keys[key] and scenetree.findObject(pre .. key)
        if o then
            o:delete()
            shells[key] = nil
        end
    end
    if #gone == 0 then return end
    transaction("MageRemoveBuilding", function()
        for _, id in ipairs(gone) do
            for _, fid in ipairs(building.group(id)) do common.deleteWithUndo(fid) end
        end
    end)
    building.index(true)
    if buildingUi.current and not scenetree.findObjectById(buildingUi.current) then buildingUi.current = nil end
    dirty()
    statusText = tr("%d buildings removed: their objects were deleted in the world", #gone)
end

function buildingUi.drawGrid(ids)
    local faces   = window.faceKeys
    local covered = {}
    local none    = #buildingUi.selected(ids) == 0
    local items   = {ui.textItem(rtl("floors and faces")), ui.iconItem("bldfaceinfo", iconOf.help, "?", nil, ui.icon),
                     ui.act("bldrender", iconOf.render, "render the building"),
                     ui.iconItem("bldpickworld", iconOf.pickWorld, lookup("choose in the world"), buildingUi.picking() and ui.white or nil, ui.icon,
                                 buildingUi.picking() and ui.pick or nil,
                                 lookup(buildingUi.picking() and "choose in the world: on - a click on the building marks what it hits, shift or ctrl adds. click to stop"
                                        or "choose in the world: a click on a wall, a floor's top or a balcony marks it in the table. a window or a door is also chosen on its own, to move, remove or change it"))}
    items[2].tip = "how to tell the faces apart: look at the No Texture writing on the MeshRoad and go clockwise:\n"
                   .. "right - the face where the writing faces right\nstart - the next face, to its left\n"
                   .. "left - the face where the writing faces left\nend - the next face, to its left"
    items[3].tip = "renders this building again with auto refresh, if it stopped rendering"
    local view   = ui.cycleItem("bldshow", "what is shown", buildingUi.viewStates, buildingUi.viewOf(ids[1]))
    items[5]     = view
    local top    = ui.row(items)
    if top == "bldshow" then
        buildingUi.setView(ids[1], view.next)
        statusText = lookup(buildingUi.viewLabel[view.next])
    elseif top == "bldpickworld" then
        buildingUi.pickMode(not buildingUi.picking())
    elseif top == "bldrender" then
        statusText = buildingUi.show(ids[1]) or ""
    end
    local hit
    local function cell(label, id, bg, fg, tipText)
        return function()
            local it = ui.btnItem(label, id, bg, fg, availWidth())
            if it.draw() then hit = id end
            if tipText then tip(tipText) end
        end
    end
    if ui.beginTable("bldgrid", {0.24, 0.19, 0.19, 0.19, 0.19}) then
        local head = {cell("the whole building", "ball", none and ui.pick or ui.off, none and ui.white or ui.grey)}
        for _, face in ipairs(faces) do
            local full = buildingUi.colFull(ids, face)
            head[#head + 1] = cell(windowUi.faceShort[face], "bcol_" .. face, full and ui.on or ui.off, full and ui.white or ui.grey)
        end
        ui.cells(head)
        for k = #ids, 1, -1 do
            local fid  = ids[k]
            local c    = windowUi.read(fid)
            local full = buildingUi.rowFull(fid)
            local t    = building.touching(fid)
            local row  = {cell(tr("floor %d", k), "brow_" .. k, full and ui.add or ui.off, full and ui.white or nil,
                              tr("%s m high", string.format("%.2f", building.height(fid))))}
            for _, face in ipairs(faces) do
                local id        = "bcell_" .. k .. "_" .. face
                local on        = buildingUi.sel[buildingUi.key(fid, face)]
                local label, tp = buildingUi.cellLabel(c, face)
                if t and t.covered[face] then
                    label, tp   = lookup("attached"), lookup("attached to another part: its windows and doors are left out and the roof stops at it")
                    covered[id] = true
                elseif t and t.walls[face] and #t.walls[face] > 0 then
                    label, tp = label .. " ~", tp .. "\n" .. lookup("partly attached to another part: no windows or doors where it touches")
                end
                row[#row + 1] = cell(label, id, on and ui.on or ui.off, (on and ui.white) or (covered[id] and ui.grey) or nil, tp)
            end
            ui.cells(row)
        end
        imgui.EndTable()
    end
    if not hit or covered[hit] then return end
    buildingUi.dropWins()
    if hit == "ball" then
        buildingUi.sel = {}
        return
    end
    local keys = {}
    if hit:sub(1, 5) == "bcol_" then
        for _, fid in ipairs(ids) do keys[#keys + 1] = buildingUi.key(fid, hit:sub(6)) end
    elseif hit:sub(1, 5) == "brow_" then
        local k   = tonumber(hit:sub(6))
        local fid = ids[k]
        if not buildingUi.multi and buildingUi.rowFull(fid) and not buildingUi.editing(fid) then return buildingUi.editNodes(ids, k) end
        for _, face in ipairs(faces) do keys[#keys + 1] = buildingUi.key(fid, face) end
        buildingUi.pick(keys)
        if buildingUi.rowFull(fid) then buildingUi.editNodes(ids, k) end
        return
    else
        local k, face = hit:match("^bcell_(%d+)_(.+)$")
        keys[1]       = buildingUi.key(ids[tonumber(k)], face)
    end
    buildingUi.pick(keys)
end

function buildingUi.editing(fid)
    local sel = getSelection()
    return #sel == 1 and sel[1] == building.driver(fid) and gateUi.inMeshRoadEditor()
end

function buildingUi.editNodes(ids, k)
    local d = building.driver(ids[k])
    buildingUi.select(d, true)
    if d == ids[k] then
        statusText = "the floor's MeshRoad is open in the Mesh Road Editor"
        return
    end
    for j, fid in ipairs(ids) do
        if fid == d then statusText = tr("floor %d follows floor %d: that floor's nodes are open", k, j) end
    end
end

function buildingUi.drawBar(ids, list, k)
    text(buildingUi.multi and "multiple choice: every click adds or takes away a cell, a floor or a face. the whole building clears it"
         or "a click chooses one cell, floor or face. a second click on it goes back to the whole building", ui.grey)
    local on    = buildingUi.multi
    local items = {ui.act("bldaddfloor", iconOf.addFloor, "add a floor", ui.add),
                   ui.iconItem("bldmulti", iconOf.multi, lookup("multiple choice"), on and ui.white or ui.grey, ui.icon, on and ui.pick or nil,
                               tr("%s: %s - click for %s", lookup("multiple choice"), lookup(on and "on" or "off"), lookup(on and "off" or "on"))),
                   ui.act("bldunit", iconOf.addUnit, "add an attached unit", ui.add)}
    local moving = buildingUi.push and buildingUi.push.kind == "move"
    items[#items + 1] = ui.iconItem("bldmove", iconOf.movePart, lookup("move this part"), moving and ui.white or nil, ui.icon, moving and ui.pick or nil,
                                    lookup(moving and "move this part: on - click to stop" or "move this part with the gizmo"))
    if list[k].kind ~= "main" then items[#items + 1] = ui.act("bldremovepart", iconOf.remove, "remove this part") end
    items[1].tip = "a new floor goes on top, a copy of the top floor without its door, its bottom held on the floor below"
    items[3].tip = "a smaller unit next to this part, on its right side, with its own floors and roof. move it to any wall with the gizmo"
    local hit = ui.row(items)
    if moving then text("drag the arrows: a unit slides along the walls of the part it stands by and goes round its corners. moving the main part moves the whole building", ui.grey) end
    if hit == "bldunit" then
        local nid = building.addUnit(ids[1])
        if nid then
            buildingUi.partId, buildingUi.sel = nid, {}
            dirty()
            buildingUi.show(nid)
            statusText = "unit added next to this part"
        else
            statusText = "could not create the MeshRoad"
        end
    elseif hit == "bldmove" then
        if moving then buildingUi.stopPush() else buildingUi.startMove(list, k) end
    elseif hit == "bldremovepart" then
        buildingUi.stopPush()
        preview.clearPreview()
        local root = list[1].ids[1]
        building.removePart(ids)
        buildingUi.partId, buildingUi.sel, buildingUi.current = nil, {}, root
        dirty()
        buildingUi.show(root)
        statusText = "part removed"
    elseif hit == "bldmulti" then
        buildingUi.multi = not on
    elseif hit == "bldaddfloor" then
        local nid = building.addFloor(ids[#ids])
        if nid then
            buildingUi.select(nid)
            buildingUi.sel = {}
            for _, face in ipairs(window.faceKeys) do buildingUi.sel[buildingUi.key(nid, face)] = true end
            dirty()
            buildingUi.show(nid)
            statusText = tr("floor %d added", #ids + 1)
        else
            statusText = "could not create the MeshRoad"
        end
    end
end

function buildingUi.drawScope(ids)
    local list = buildingUi.selected(ids)
    if #list == 0 then
        textv(lookup("the whole building") .. ": " .. lookup("every floor and face, except what has its own setting"), ui.orange)
        return
    end
    local parts, done = {}, {}
    for k, fid in ipairs(ids) do
        if buildingUi.rowFull(fid) then
            parts[#parts + 1] = tr("floor %d", k)
            for _, face in ipairs(window.faceKeys) do done[buildingUi.key(fid, face)] = true end
        end
    end
    for _, face in ipairs(window.faceKeys) do
        if buildingUi.colFull(ids, face) then
            local fresh = false
            for _, fid in ipairs(ids) do
                if not done[buildingUi.key(fid, face)] then fresh = true end
                done[buildingUi.key(fid, face)] = true
            end
            if fresh then parts[#parts + 1] = tr("%s on every floor", lookup(windowUi.faceShort[face])) end
        end
    end
    for _, c in ipairs(list) do
        if not done[buildingUi.key(c.fid, c.face)] then parts[#parts + 1] = tr("%s of floor %d", lookup(windowUi.faceShort[c.face]), c.k) end
    end
    local _, rows = buildingUi.fullRows(ids)
    textv(table.concat(parts, " | "), rows and ui.green or ui.blue)
end

function buildingUi.drawLook(ids)
    if not (section("look", true) and ui.beginProps("bldlook")) then return end
    windowUi.pickLook("bldlookwall", buildingUi.linkedIds(ids), "wall", "walls", "the config's wall", "wall")
    windowUi.pickLook("bldlookwalk", ids, "walk", "roof", "the config's top surface", "walk")
    ui.endProps()
end

function buildingUi.drawFloors(rows)
    if not section("floor", true) then return end
    local one   = (#rows == 1) and rows[1] or nil
    local items = {}
    if one then
        items[1] = ui.act("bldup", iconOf.up, "move this floor up")
        items[2] = ui.act("blddown", iconOf.down, "move this floor down")
    end
    items[#items + 1] = ui.iconItem("blddel", iconOf.remove, (#rows > 1) and tr("remove %d floors", #rows) or lookup("remove this floor"), nil, ui.icon)
    local hit = ui.row(items)
    if hit == "bldup" or hit == "blddown" then
        buildingUi.floorAction(one, (hit == "bldup") and 1 or -1)
        buildingUi.sel = {}
        for _, face in ipairs(window.faceKeys) do buildingUi.sel[buildingUi.key(one, face)] = true end
        return
    elseif hit == "blddel" then
        for _, fid in ipairs(rows) do buildingUi.floorAction(fid, 0) end
        buildingUi.sel = {}
        return
    end
    if not ui.beginProps("bldfloor") then return end
    ui.prop(lookup("floor height"))
    local h = ui.number("bldheight", "bldheightdec", "bldheightinc", building.height(rows[1]), 0.5, 100.0, building.defaults.floor)
    if h then
        for _, fid in ipairs(rows) do building.setHeight(fid, h) end
        statusText = tr("floor height set to %s", string.format("%g", h))
    end
    local b = one and building.dataOf(one)
    if b and b.below then
        ui.prop(lookup("hold on the floor below"))
        local labels = {height = "height", path = "path", width = "width"}
        local list   = {}
        for _, key in ipairs(building.snapKeys) do list[#list + 1] = {"bldsnap_" .. key, labels[key], b.snap[key]} end
        local hit2, v = ui.checks(list)
        if hit2 then
            local key   = hit2:sub(9)
            b.snap[key] = v
            building.setData(one, b)
            statusText = tr("%s: %s", lookup(labels[key]), lookup(v and "on" or "off"))
        end
    end
    ui.endProps()
end

function buildingUi.drawFaces(ids, list, open)
    if not (section("look", open) and ui.beginProps("bldfaces")) then return end
    local cur, mixed
    for _, c in ipairs(list) do
        local wc = windowUi.read(c.fid)
        local v  = wc and wc.walls[c.face] or false
        if cur == nil then cur = v elseif cur ~= v then mixed = true end
    end
    ui.back("blddefault_facewall", "walls of the marked faces", (cur ~= nil and cur ~= false) or mixed == true, function()
        buildingUi.writeCells(ids, list, function(c, face) c.walls[face] = nil end, true)
    end)
    local picked, value = windowUi.texField("bldfacewall", "wall", cur or nil, "as the floor", mixed and lookup("(mixed)") or nil, nil, function(v)
        buildingUi.writeCells(ids, list, function(c, face) c.walls[face] = (v ~= "") and v or nil end, true)
    end)
    tip("only the faces marked in the grid above take it. 'as the floor' gives them back the building's walls")
    if picked then
        if value == "" then value = nil end
        statusText = tr("%s: %s", lookup("walls"), windowUi.texLabel(value, "wall", "as the floor"))
    elseif value then
        statusText = value
    end
    ui.endProps()
end

function buildingUi.firstCfg(list)
    for _, c in ipairs(list) do
        local wc = windowUi.peek(c.fid)
        if wc then return wc end
    end
    return window.newConfig("rect")
end

function buildingUi.modelPicker(ids, key, list)
    if buildingUi.trimKeys[key] and buildingUi.trimChosen(key) then
        local opts = {}
        for _, path in ipairs(trims.list(key)) do opts[#opts + 1] = {value = path, label = trims.label(path)} end
        buildingUi.ownProp(ids, list, key, "dae", "section")
        local picked, value = windowUi.picker("bldmodel_" .. key, nil, select(3, trims.of(key, buildingUi.trimView(list, key).dae)), opts, nil, function(v)
            buildingUi.trimWrite(ids, list, key, nil, function(t) t.dae = v end)
        end)
        if picked and value then
            statusText = tr("%s: %s", lookup("section"), trims.label(value))
        end
        return
    end
    local floors     = buildingUi.floorsIn(list)
    local faces      = {}
    local cur, mixed = nil, false
    for _, c in ipairs(list) do faces[c.face] = true end
    local function rowsOf(wc)
        local out = {}
        for _, fl in ipairs(wc and wc.floors or {}) do
            local door = fl.at ~= nil
            if fl.style == "rect" and ((key == "windows" and not door) or (key == "doors" and door and faces[fl.face or "right"])) then
                out[#out + 1] = fl
            end
        end
        return out
    end
    for _, c in ipairs(floors) do
        local wc   = windowUi.read(c.fid)
        local vals = {}
        if key == "windows" or key == "doors" then
            for _, fl in ipairs(rowsOf(wc)) do vals[#vals + 1] = fl.dae and modules.resolve(fl.dae) or false end
        elseif buildingUi.trimKeys[key] then
            vals[1] = select(3, trims.of(key, wc and wc.mods[key].dae))
        else
            vals[1] = modules.resolve(wc and wc.mods[key].dae or modules.defaults[key])
        end
        for _, v in ipairs(vals) do
            if cur == nil then cur = v elseif cur ~= v then mixed = true end
        end
    end
    local opts = {}
    local labelOf = buildingUi.trimKeys[key] and trims.label or modules.label
    for _, path in ipairs(buildingUi.trimKeys[key] and trims.list(key) or modules.list(key)) do opts[#opts + 1] = {value = path, label = labelOf(path)} end
    ui.prop(lookup(buildingUi.trimKeys[key] and "section" or "model"))
    local shown         = mixed and lookup("(mixed)") or ((not cur) and lookup("choose a model")) or ((#opts == 0) and labelOf(cur)) or nil
    local function put(c, v)
        if key == "windows" or key == "doors" then
            for _, fl in ipairs(rowsOf(c)) do windowUi.applyModule(fl, v) end
        else
            c.mods[key].dae = v
        end
    end
    local function used(c, fid)
        local st   = building.stack(fid)
        local role = st and {ground = st.ground, roof = st.top} or nil
        for _, face in ipairs(window.faceKeys) do
            if window.modAt(c, key, face, role) then return true end
        end
        return false
    end
    local picked, value = windowUi.picker("bldmodel_" .. key, nil, cur or nil, opts, shown, function(v)
        buildingUi.writeCells(ids, floors, function(c, _, cell)
            if not windowUi.trying() or used(c, cell.fid) then put(c, v) end
        end, key, true)
    end)
    if not (picked and value) then return end
    statusText = tr("%s: %s", lookup(buildingUi.trimKeys[key] and "section" or "model"), labelOf(value))
end

buildingUi.ownKinds  = {balcony = true, awning = true, flowers = true, ac = true, dish = true, stairs = true, pillar = true, pots = true, corbel = true,
                        roofac = true, roofdish = true, pipe = true}
buildingUi.ownFields = {trim    = {"lift", "from", "to", "deep", "tall", "wide", "grate", "out", "taperA", "taperB", "bulge", "flatten", "peak"},
                        balcony = {"lift", "out", "wide"}, awning = {"lift", "out", "wide"}, flowers = {"lift"}, ac = {"lift"}, dish = {"lift"},
                        stairs  = {"lift", "out"}, pillar = {"out"}}

function buildingUi.pinOwn(c, key, w)
    local i = buildingUi.pinNo(w)
    local m = i and c and c.mods[key]
    return m and m.pins and m.pins[i] or nil
end

function buildingUi.seedOwn(key, mm, slot)
    local n    = tonumber(slot:match("|(%d+)$")) or 1
    local e    = (n > 50) and (mm.more or {})[math.floor((n - 1) / 50)] or mm
    local trim = buildingUi.trimKeys[key]
    local t    = {}
    for _, k in ipairs(buildingUi.ownFields[trim and "trim" or key] or {}) do t[k] = window.modValue(e, k) end
    if trim then
        t.dae = select(3, trims.of(key, e.dae or mm.dae))
        t.bay = (e.bay == "arc") and "arc" or "rect"
    end
    if trim or key == "balcony" then
        t.sides = mm.sides == true
        for _, way in ipairs({"top", "side", "bottom"}) do t[way] = mm[way] end
    end
    return t
end

function buildingUi.ownHas(key, field)
    for _, w in ipairs(buildingUi.trimChosen(key) or {}) do
        local c   = windowUi.peek(w.fid)
        local pin = buildingUi.pinOwn(c, key, w)
        local o   = pin and pin.own or (not pin and c and c.mods[key] and c.mods[key].own and c.mods[key].own[w.slot])
        if o and o[field] ~= nil then return true end
    end
    return false
end

function buildingUi.modSet(list, key, field)
    for _, c in ipairs(buildingUi.floorsIn(list)) do
        local wc = windowUi.peek(c.fid)
        if wc and wc.mods[key] and wc.mods[key][field] ~= nil then return true end
    end
    return false
end

function buildingUi.ownProp(ids, list, key, field, label)
    if not buildingUi.trimChosen(key) then
        return ui.back("blddefault_" .. field .. "_" .. key, label, buildingUi.modSet(list, key, field), function()
            buildingUi.writeCells(ids, buildingUi.floorsIn(list), function(c) c.mods[key][field] = nil end, key, true)
        end)
    end
    local own = buildingUi.ownHas(key, field)
    ui.prop(label, own and ui.blue or nil)
    if not own then return end
    if ui.smallIcon("bldownfield_" .. field .. "_" .. key, iconOf.restore, lookup("like the floor"), nil, 18, nil, lookup("this one takes the floor's value again")) then
        buildingUi.trimWrite(ids, list, key, nil, function(t) t[field] = nil end)
        statusText = tr("%s: %s", lookup(label), lookup("like the floor"))
    end
    imgui.SameLine()
end

function buildingUi.trimChosen(key)
    if not buildingUi.trimKeys[key] and not buildingUi.ownKinds[key] then return nil end
    local out = {}
    for _, w in ipairs(buildingUi.winList()) do
        if w.kind == key then out[#out + 1] = w end
    end
    return (#out > 0) and out or nil
end

function buildingUi.trimView(list, key, more)
    local m      = buildingUi.firstCfg(list).mods[key]
    local chosen = not more and buildingUi.trimChosen(key)
    if not chosen then return more and (m.more or {})[more] or m end
    local w   = chosen[1]
    local c   = windowUi.read(w.fid)
    local mm  = c and c.mods[key] or m
    local pin = buildingUi.pinOwn(c, key, w)
    if pin then
        local t = {}
        for k, v in pairs(pin.own or {}) do t[k] = v end
        return t
    end
    local n = tonumber(w.slot:match("|(%d+)$")) or 1
    local e = (n > 50) and (mm.more or {})[math.floor((n - 1) / 50)] or mm
    local t = {}
    for k, v in pairs(e) do t[k] = v end
    for k, v in pairs(mm.own and mm.own[w.slot] or {}) do t[k] = v end
    return t
end

function buildingUi.trimWrite(ids, list, key, more, fn)
    local chosen = not more and buildingUi.trimChosen(key)
    if not chosen then
        return buildingUi.writeCells(ids, buildingUi.floorsIn(list), function(c)
            local t = more and (c.mods[key].more or {})[more] or c.mods[key]
            if t then fn(t, false) end
        end, key, true)
    end
    local byFid, order = buildingUi.byFid(chosen)
    transaction("MageTrimOwn", function()
        for _, fid in ipairs(order) do
            local c = windowUi.read(fid)
            if c then
                local m = c.mods[key]
                for _, w in ipairs(byFid[fid]) do
                    local pin = buildingUi.pinOwn(c, key, w)
                    if pin then
                        pin.own = pin.own or {}
                        fn(pin.own, true)
                        if next(pin.own) == nil then pin.own = nil end
                    elseif not buildingUi.pinNo(w) then
                        m.own         = m.own or {}
                        m.own[w.slot] = m.own[w.slot] or buildingUi.seedOwn(key, m, w.slot)
                        fn(m.own[w.slot], true)
                        if next(m.own[w.slot]) == nil then m.own[w.slot] = nil end
                    end
                end
                if m.own and next(m.own) == nil then m.own = nil end
                writeField(fid, fieldOf.windows, window.encode(c))
            end
        end
    end)
end

function buildingUi.trimAlone(ids, list, key)
    local chosen = buildingUi.trimChosen(key)
    if not chosen then return false end
    ui.prop("")
    text(tr("only the %d chosen in the world change", #chosen), ui.blue)
    ui.prop("")
    if ui.row({ui.btnItem(lookup("same as the rest of the floor"), "bldownback_" .. key, ui.off)}) then
        buildingUi.trimWrite(ids, list, key, nil, function(t) for k in pairs(t) do t[k] = nil end end)
        statusText = tr("%s: %s", lookup(buildingUi.labelOf(key)), lookup("same as the rest of the floor"))
    end
    tip(lookup("the chosen ones take the floor's settings again"))
    return true
end

function buildingUi.modNumber(ids, list, key, field, label, def)
    local wc  = buildingUi.firstCfg(list)
    local lim = window.modLimits[field]
    local own = buildingUi.trimKeys[key] or buildingUi.trimChosen(key)
    local m   = own and buildingUi.trimView(list, key) or wc.mods[key]
    buildingUi.ownProp(ids, list, key, field, label)
    local v = ui.number("bldmod" .. field .. "_" .. key, "bldmod" .. field .. "dec_" .. key, "bldmod" .. field .. "inc_" .. key,
                        m[field] or def or lim[3], lim[1], lim[2], def or lim[3])
    if v then
        if own then
            buildingUi.trimWrite(ids, list, key, nil, function(t) t[field] = v end)
        else
            buildingUi.writeCells(ids, buildingUi.floorsIn(list), function(c) c.mods[key][field] = v end, key, true)
        end
        statusText = tr("%s set to %s", lookup(label), string.format("%g", v))
    end
end

buildingUi.trimKeys  = {corner = true, pilaster = true, plinth = true, course = true, roofborder = true}
buildingUi.lineKeys  = {plinth = true, course = true, roofborder = true}
buildingUi.trimSides = {{"top", "top of the trim"}, {"side", "front of the trim"}, {"bottom", "bottom of the trim"}}

function buildingUi.trimNumber(ids, list, key, field, label, base, scale, more)
    local e   = buildingUi.trimView(list, key, more)
    local lim = window.modLimits[field]
    local cur = e[field] or lim[3]
    if base and cur <= 0 then cur = base * (scale or 1.0) end
    local tag = key .. (more and ("_" .. more) or "")
    if more then ui.prop(lookup(label)) else buildingUi.ownProp(ids, list, key, field, label) end
    local v = ui.number("bldmod" .. field .. "_" .. tag, "bldmod" .. field .. "dec_" .. tag, "bldmod" .. field .. "inc_" .. tag, cur,
                        base and 0.01 or lim[1], lim[2], base or lim[3])
    if not v then return end
    local keep = (base and (math.abs(v - base) > 1e-3 or (scale or 1.0) ~= 1.0)) or (not base and math.abs(v - lim[3]) > 1e-9)
    buildingUi.trimWrite(ids, list, key, more, function(t, alone) t[field] = (keep or alone) and (math.floor(v * 1000 + 0.5) / 1000) or nil end)
    statusText = tr("%s set to %s", lookup(label), string.format("%g", v))
end

function buildingUi.trimSize(ids, list, key, more)
    local m      = buildingUi.firstCfg(list).mods[key]
    local e      = buildingUi.trimView(list, key, more)
    local d0, w0 = trims.extent(key, e.dae or m.dae)
    local scale  = (key == "corner") and window.modValue(m, "size") or 1.0
    buildingUi.trimNumber(ids, list, key, "deep", "depth from the wall", d0, scale, more)
    if buildingUi.lineKeys[key] then
        buildingUi.trimNumber(ids, list, key, "tall", "height of the trim", w0, scale, more)
    else
        buildingUi.trimNumber(ids, list, key, "wide", (key == "corner") and "length along each wall" or "width", w0, scale, more)
    end
end

function buildingUi.trimShape(ids, list, key, more)
    local m = buildingUi.firstCfg(list).mods[key]
    local e = buildingUi.trimView(list, key, more)
    if not trims.of(key, e.dae or m.dae).flat then return end
    local tag    = key .. (more and ("_" .. more) or "")
    local states = {{key = "rect", label = "straight or slanted sides", icon = iconOf.front.rect}, {key = "arc", label = "arc", icon = iconOf.front.arc}}
    if more then ui.prop(lookup("shape of the front")) else buildingUi.ownProp(ids, list, key, "bay", "shape of the front") end
    local hit = ui.cycle("bldbay_" .. tag, "shape of the front", states, (e.bay == "arc") and "arc" or "rect")
    if hit then
        buildingUi.trimWrite(ids, list, key, more, function(t, alone) t.bay = (hit == "arc") and "arc" or (alone and "rect" or nil) end)
        statusText = tr("%s: %s", lookup("shape of the front"), lookup((hit == "arc") and "arc" or "straight or slanted sides"))
        return
    end
    if key == "corner" then
        buildingUi.trimNumber(ids, list, key, "taperA", (e.bay == "arc") and "rounded part at the end of each arm (0: all of it)" or "slanted part at the end of each arm", nil, nil, more)
    elseif e.bay == "arc" then
        buildingUi.trimNumber(ids, list, key, "bulge", "0: part of a circle, 1: half an ellipse", nil, nil, more)
        buildingUi.trimNumber(ids, list, key, "flatten", "flatter top (0 to 1)", nil, nil, more)
        buildingUi.trimNumber(ids, list, key, "peak", "where the top of the arc is (0: the middle)", nil, nil, more)
    else
        buildingUi.trimNumber(ids, list, key, "taperA", "slanted part at the start", nil, nil, more)
        buildingUi.trimNumber(ids, list, key, "taperB", "slanted part at the end", nil, nil, more)
    end
end

function buildingUi.trimSpan(ids, list, key, more)
    local up = not buildingUi.lineKeys[key] and not more
    buildingUi.trimNumber(ids, list, key, "from", up and "start above the floor" or "start along each face", nil, nil, more)
    buildingUi.trimNumber(ids, list, key, "to", up and "end below the top" or "end before the end of each face", nil, nil, more)
end

function buildingUi.trimCopies(ids, list, key, more)
    local m = buildingUi.firstCfg(list).mods[key]
    local e = more and (m.more or {})[more] or m
    buildingUi.trimNumber(ids, list, key, "count", "copies", nil, nil, more)
    if window.modValue(e, "count") > 1 then
        buildingUi.trimNumber(ids, list, key, "space", buildingUi.lineKeys[key] and "height between the copies" or "space between the copies", nil, nil, more)
    end
end

function buildingUi.drawMore(ids, list, key)
    local m      = buildingUi.firstCfg(list).mods[key]
    local floors = buildingUi.floorsIn(list)
    for i = 1, #(m.more or {}) do
        ui.heading(tr("another %d", i))
        if ui.beginProps("bldmore_" .. key .. "_" .. i) then
            if buildingUi.lineKeys[key] then
                buildingUi.trimNumber(ids, list, key, "lift", "height up or down", nil, nil, i)
            else
                buildingUi.trimNumber(ids, list, key, "lift", "start above the floor", nil, nil, i)
            end
            buildingUi.trimSpan(ids, list, key, i)
            buildingUi.trimCopies(ids, list, key, i)
            buildingUi.trimSize(ids, list, key, i)
            buildingUi.trimShape(ids, list, key, i)
            ui.endProps()
        end
        if ui.row({ui.btnItem(lookup("remove"), "bldmoredel_" .. key .. "_" .. i, ui.off, nil, availWidth())}) then
            buildingUi.writeCells(ids, floors, function(c)
                if c.mods[key].more then table.remove(c.mods[key].more, i) end
                if c.mods[key].more and #c.mods[key].more == 0 then c.mods[key].more = nil end
            end, key, true)
            statusText = tr("%s: %s", lookup(buildingUi.labelOf(key)), lookup("removed"))
            return
        end
    end
    if ui.row({ui.btnItem(lookup("add another"), "bldmoreadd_" .. key, ui.off, nil, availWidth())}) then
        buildingUi.writeCells(ids, floors, function(c)
            c.mods[key].more = c.mods[key].more or {}
            local list2      = c.mods[key].more
            list2[#list2 + 1] = buildingUi.lineKeys[key] and {lift = 1.0} or {from = 1.0}
        end, key, true)
        statusText = tr("%s: %s", lookup(buildingUi.labelOf(key)), lookup("add another"))
    end
    tip(lookup("one more of this trim with its own place, length, copies and size"))
end

function buildingUi.sizeNumbers(ids, list, key)
    local wc     = buildingUi.firstCfg(list)
    local m      = buildingUi.trimView(list, key)
    local w0, d0 = modules.extent(m.dae or modules.defaults[key])
    if not w0 then return end
    if key == "awning" then
        for _, fl in ipairs(wc.floors or {}) do
            if not fl.at then
                w0 = fl.width + 2.0 * modules.awningOver
                break
            end
        end
    end
    local function field(name, label, base, cur, lo, hi, store)
        buildingUi.ownProp(ids, list, key, name, label)
        local v = ui.number("bldmod" .. name .. "_" .. key, "bldmod" .. name .. "dec_" .. key, "bldmod" .. name .. "inc_" .. key, cur, lo, hi, base)
        if v then
            buildingUi.trimWrite(ids, list, key, nil, function(t, alone) store(t, v, alone) end)
            statusText = tr("%s set to %s", lookup(label), string.format("%g", v))
        end
    end
    local out, wide = window.modLimits.out, window.modLimits.wide
    field("out", "depth from the wall", d0, d0 + window.modValue(m, "out"), math.max(0.05, d0 + out[1]), d0 + out[2], function(c, v, alone)
        c.out = (alone or math.abs(v - d0) > 1e-3) and (math.floor((v - d0) * 1000 + 0.5) / 1000) or nil
    end)
    field("wide", "width", w0, (window.modValue(m, "wide") > 0) and m.wide or w0, 0.3, wide[2], function(c, v, alone)
        c.wide = (alone or math.abs(v - w0) > 1e-3) and v or nil
    end)
end

function buildingUi.modCount(ids, list, key, field, label, from)
    local wc = buildingUi.firstCfg(list)
    buildingUi.ownProp(ids, list, key, field, label)
    local opts, cur = {}, math.floor(window.modValue(wc.mods[key], field) + 0.5)
    for n = from, 4 do opts[#opts + 1] = {key = tostring(n), label = tostring(n)} end
    local hit = ui.segment("bldmod" .. field .. "_" .. key, opts, tostring(cur))
    if hit then
        buildingUi.writeCells(ids, buildingUi.floorsIn(list), function(c) c.mods[key][field] = tonumber(hit) end, key, true)
        statusText = tr("%s set to %s", lookup(label), hit)
    end
end

function buildingUi.globalNumber(ids, list, field, label)
    local wc  = buildingUi.firstCfg(list)
    local def = window.limits[field][3]
    ui.back("blddefault_" .. field, label, math.abs((wc[field] or def) - def) > 1e-9, function()
        buildingUi.writeCells(ids, buildingUi.floorsIn(list), function(c) c[field] = def end, "windows", true)
    end)
    local v = windowUi.number("bld" .. field, wc[field], field)
    if v then
        buildingUi.writeCells(ids, buildingUi.floorsIn(list), function(c) c[field] = v end, "windows", true)
        statusText = tr("%s set to %s", lookup(label), string.format("%g", v))
    end
end

function buildingUi.drawSwitch(ids, key, state)
    local states
    if key == "windows" then
        states = {{key = "off", label = "no windows", icon = iconOf.winNone}, {key = "hole", label = "openings only", icon = iconOf.winHole},
                  {key = "on", label = "with a window", icon = iconOf.winGlass}}
    elseif key == "doors" then
        states = {{key = "off", label = "opening only", icon = iconOf.doorHole}, {key = "on", label = "with a door", icon = iconOf.door}}
    else
        states = {{key = "off", label = "off", icon = iconOf.mods[key], tint = ui.grey}, {key = "on", label = "on", icon = iconOf.mods[key], bg = ui.pick}}
    end
    local title = key == "windows" and "windows" or key == "doors" and "doors" or "state"
    ui.prop(lookup(title))
    local hit = ui.cycle("bldstate_" .. key, title, states, state)
    if state == "mixed" then
        ui.prop("")
        text("only on part of what is marked. a choice sets it for all of it", ui.orange)
    end
    if not hit then return end
    local v = hit
    if key ~= "windows" then v = (hit == "on") end
    buildingUi.setMod(ids, key, v)
    statusText = tr("%s: %s", lookup(buildingUi.labelOf(key)), lookup(buildingUi.stateWord[hit] or hit))
end

function buildingUi.labelOf(key)
    for _, m in ipairs(buildingUi.modList) do
        if m.key == key then return m.label end
    end
    return key
end

function buildingUi.drawModels(ids)
    buildingUi.modelsOpen = section("models", false)
    if not buildingUi.modelsOpen then return end
    local items, states = {}, {}
    for _, m in ipairs(buildingUi.modList) do
        local st   = buildingUi.stateOf(ids, m.key)
        states[m.key] = st
        items[#items + 1] = ui.iconItem("bldtab_" .. m.key, (st == "hole") and iconOf.winHole or iconOf.mods[m.key], lookup(m.label), buildingUi.stateTint[st],
                                        ui.icon, (m.key == buildingUi.mod) and ui.pick or nil)
        items[#items].tip = lookup(m.label) .. ": " .. tr("%s - click to open its settings", lookup(buildingUi.stateWord[st]))
    end
    local hit = ui.row(items)
    if hit then buildingUi.mod = hit:sub(#"bldtab_" + 1) end
    imgui.Separator()
    local key  = buildingUi.mod
    local st   = states[key] or buildingUi.stateOf(ids, key)
    local list = buildingUi.cells(ids)
    ui.heading(lookup(buildingUi.labelOf(key)))
    if buildingUi.winsInTab() and not buildingUi.winsTop then buildingUi.drawWins(ids) end
    if not ui.beginProps("bldmod_" .. key) then return end
    buildingUi.drawSwitch(ids, key, st)
    local alone = st ~= "off" and buildingUi.trimAlone(ids, list, key)
    if st ~= "off" and st ~= "hole" and not buildingUi.ownModel[key] and ((alone and buildingUi.trimKeys[key]) or not buildingUi.chosenKind(key)) then buildingUi.modelPicker(ids, key, list) end
    if key == "windows" or key == "doors" then buildingUi.drawMoves(ids, list, key) end
    if key == "doors" then buildingUi.drawBack(ids, list) end
    if key == "windows" then
        if st == "on" or st == "mixed" then buildingUi.globalNumber(ids, list, "sink", "how deep the window sits in the wall") end
        if st == "hole" or st == "mixed" then buildingUi.globalNumber(ids, list, "depth", "depth of the opening") end
        buildingUi.globalNumber(ids, list, "margin", "margin at the ends of each face")
    elseif key == "balcony" then
        if not alone then buildingUi.modCount(ids, list, key, "every", "a balcony under every n-th window or door", 1) end
        buildingUi.modNumber(ids, list, key, "lift", "height up or down")
        buildingUi.sizeNumbers(ids, list, key)
        buildingUi.drawPins(ids, list, key)
    elseif key == "awning" then
        if not alone then buildingUi.modCount(ids, list, key, "every", "an awning over every n-th window", 1) end
        buildingUi.modNumber(ids, list, key, "lift", "height up or down")
        buildingUi.sizeNumbers(ids, list, key)
        buildingUi.drawPins(ids, list, key)
    elseif key == "flowers" and st ~= "off" then
        if not alone then buildingUi.modCount(ids, list, key, "every", "one under every n-th window", 1) end
        buildingUi.modNumber(ids, list, key, "lift", "height up or down")
        buildingUi.drawPins(ids, list, key)
    elseif key == "pots" and st ~= "off" then
        if not alone then buildingUi.modNumber(ids, list, key, "step", "space between them") end
        buildingUi.drawPins(ids, list, key)
    elseif (key == "roofac" or key == "roofdish" or key == "pipe") and st ~= "off" then
        buildingUi.drawPins(ids, list, key)
    elseif key == "corbel" then
        if not alone then buildingUi.modNumber(ids, list, key, "step", "space between them") end
    elseif key == "stairs" and st ~= "off" then
        buildingUi.modNumber(ids, list, key, "lift", "height above the door's bottom")
        buildingUi.modNumber(ids, list, key, "out", "distance out from the wall")
    elseif key == "corner" and st ~= "off" then
        buildingUi.modNumber(ids, list, key, "out", "distance out from the corner")
        buildingUi.trimSize(ids, list, key)
        buildingUi.trimShape(ids, list, key)
        buildingUi.trimSpan(ids, list, key)
        buildingUi.drawPins(ids, list, key)
    elseif buildingUi.lineKeys[key] and st ~= "off" then
        buildingUi.modNumber(ids, list, key, "lift", "height up or down")
        buildingUi.trimSize(ids, list, key)
        buildingUi.trimShape(ids, list, key)
        buildingUi.trimSpan(ids, list, key)
        if not alone then buildingUi.trimCopies(ids, list, key) end
        local wc = buildingUi.firstCfg(list)
        if trims.of(key, buildingUi.trimView(list, key).dae or wc.mods[key].dae).grate then buildingUi.modNumber(ids, list, key, "grate", "space between the grates (0: none)") end
        buildingUi.drawPins(ids, list, key)
    elseif key == "pillar" then
        if not alone then buildingUi.modNumber(ids, list, key, "space", "space between pillars") end
        buildingUi.modNumber(ids, list, key, "out", "distance out from the wall")
        local wc = buildingUi.firstCfg(list)
        if wc.mods.pillar.snap == false and not alone then buildingUi.modNumber(ids, list, key, "margin", "margin at the ends of each face") end
    elseif (key == "ac" or key == "dish") and st ~= "off" then
        if not alone then buildingUi.modCount(ids, list, key, "every", "one next to every n-th window", 1) end
        buildingUi.modNumber(ids, list, key, "lift", "height above the window's bottom")
        buildingUi.drawPins(ids, list, key)
    elseif key == "pilaster" then
        if not alone then buildingUi.modCount(ids, list, key, "split", "one after every n-th window (0: only at the ends)", 0) end
        if st ~= "off" then
            buildingUi.trimSize(ids, list, key)
            buildingUi.trimShape(ids, list, key)
            buildingUi.trimNumber(ids, list, key, "to", "end below the top")
            buildingUi.drawPins(ids, list, key)
        end
    elseif key == "roof" and st ~= "off" then
        buildingUi.drawRoof(ids, list)
    elseif key == "gutter" and st ~= "off" then
        buildingUi.gutterMat(ids, list)
    end
    ui.endProps()
    if key == "roof" and st ~= "off" then buildingUi.drawRoofPart(ids, list) end
    if key == "pillar" and not alone then
        local wc          = buildingUi.firstCfg(list)
        local changed, on = ui.check("bldsnap_pillar", "snap the pillars to the corners", wc.mods.pillar.snap ~= false)
        tip("a pillar on every corner that has room for one, the rest spread evenly between them. off: Building Architect's spacing with a margin")
        if changed then
            buildingUi.writeCells(ids, buildingUi.floorsIn(list), function(c) if on then c.mods.pillar.snap = nil else c.mods.pillar.snap = false end end, "pillar", true)
            statusText = tr("%s: %s", lookup("snap the pillars to the corners"), lookup(on and "on" or "off"))
        end
    end
    if key == "balcony" and st ~= "off" then buildingUi.drawSlab(ids, list) end
    if buildingUi.trimKeys[key] and st ~= "off" then
        buildingUi.drawSlab(ids, list, key)
        if key ~= "corner" and not buildingUi.trimChosen(key) then buildingUi.drawMore(ids, list, key) end
    end
    if key == "roofborder" and st ~= "off" then
        local wc          = buildingUi.firstCfg(list)
        local changed, on = ui.check("bldskin_roofborder", "roof texture on the border", wc.mods.roofborder.skin == true)
        tip("the border takes the pitched roof's texture. off: the border keeps its own texture")
        if changed then
            buildingUi.writeCells(ids, buildingUi.floorsIn(list), function(c) c.mods.roofborder.skin = on or nil end)
            statusText = tr("%s: %s", lookup("roof texture on the border"), lookup(on and "on" or "off"))
        end
    end
    if key == "windows" then buildingUi.drawRows(ids) end
    if key == "doors" then buildingUi.drawFaceDoors(ids) end
    text(buildingUi.notes[key], ui.grey)
end

function buildingUi.drawSlab(ids, list, key)
    local trim   = key ~= nil
    key          = key or "balcony"
    local m      = buildingUi.trimView(list, key)
    local floors = buildingUi.floorsIn(list)
    local alone  = buildingUi.trimChosen(key) ~= nil
    local function put(fn)
        if trim or alone then return buildingUi.trimWrite(ids, list, key, nil, fn) end
        buildingUi.writeCells(ids, floors, function(c) fn(c.mods[key]) end)
    end
    local hit, own = ui.check("bldsides_" .. key, "a material for each side", m.sides == true)
    tip(trim and "a material of your own for the top, the front and the bottom of the trim. off: the section's materials"
              or "a material of your own for the top, the bottom and the edge of the floor. off: the model's materials")
    if hit then
        put(function(t, solo) t.sides = own or (solo and false) or nil end)
        statusText = tr("%s: %s", lookup("a material for each side"), lookup(own and "on" or "off"))
    end
    if not m.sides or not ui.beginProps(trim and ("bldtrimmats_" .. key) or "bldslabmats") then return end
    local ways = trim and buildingUi.trimSides or {{"top", "top of the floor"}, {"bottom", "bottom of the floor"}, {"side", "edge of the floor"}}
    for _, way in ipairs(ways) do
        local set = alone and buildingUi.ownHas(key, way[1]) or (not alone and m[way[1]] ~= nil)
        ui.back("blddefault_" .. key .. way[1], way[2], set, function() put(function(t) t[way[1]] = nil end) end)
        local picked, value = windowUi.texField((trim and ("bldtrim" .. key) or "bldslab") .. way[1], "roof", m[way[1]], "as the model", nil, nil, function(v)
            put(function(t) t[way[1]] = (v ~= "") and v or nil end)
        end)
        if picked then
            statusText = tr("%s: %s", lookup(way[2]), windowUi.texLabel(value, "roof", "as the model"))
        elseif value then
            statusText = value
        end
    end
    ui.endProps()
end

function buildingUi.gutterMat(ids, list)
    ui.back("blddefault_guttermat", "material of the gutters", buildingUi.modSet(list, "gutter", "mat"), function()
        buildingUi.writeCells(ids, buildingUi.floorsIn(list), function(c) c.mods.gutter.mat = nil end)
    end)
    local picked, value = windowUi.texField("bldguttermat", "roof", buildingUi.firstCfg(list).mods.gutter.mat, "as the top surface", nil, nil, function(v)
        buildingUi.writeCells(ids, buildingUi.floorsIn(list), function(c) c.mods.gutter.mat = (v ~= "") and v or nil end)
    end)
    if picked then
        statusText = tr("%s: %s", lookup("material of the gutters"), windowUi.texLabel(value, "roof", "as the top surface"))
    elseif value then
        statusText = value
    end
end

function buildingUi.roofField(ids, list, fn)
    buildingUi.writeCells(ids, buildingUi.floorsIn(list), function(c) fn(c.mods.roof) end)
end

function buildingUi.roofSegment(id, label, opts, cur, fn, back)
    if back then ui.back(id .. "_default", label, cur ~= opts[1][1], back) else ui.prop(lookup(label)) end
    local states = {}
    for _, o in ipairs(opts) do states[#states + 1] = {key = o[1], label = o[2], icon = o[3]} end
    local hit = ui.cycle(id, label, states, cur)
    if not hit then return end
    for _, o in ipairs(opts) do
        if o[1] == hit then statusText = tr("%s: %s", lookup(label), lookup(o[2])) end
    end
    fn(hit)
end

function buildingUi.drawRoof(ids, list)
    local m = buildingUi.firstCfg(list).mods.roof
    if m.part == "right" or m.part == "left" then
        ui.prop(lookup("shape"))
        text("along a long face the roof has one slope, leaning on the floor above", ui.grey)
    else
        local cur = (m.shape == "shed") and ("shed_" .. (m.high or "left")) or (m.shape or "gable")
        buildingUi.roofSegment("bldroofshape", "shape", {{"gable", "two slopes", iconOf.roofGable}, {"hip", "four slopes", iconOf.roofHip},
                                                          {"shed_left", "one slope, high on the left", iconOf.roofShedL},
                                                          {"shed_right", "one slope, high on the right", iconOf.roofShedR}}, cur, function(v)
            buildingUi.roofField(ids, list, function(r)
                r.shape = (v ~= "gable") and v:match("^%a+") or nil
                r.high  = (v == "shed_right") and "right" or nil
            end)
        end, function() buildingUi.roofField(ids, list, function(r) r.shape, r.high = nil, nil end) end)
    end
    buildingUi.modNumber(ids, list, "roof", "pitch", "pitch (degrees)")
    buildingUi.modNumber(ids, list, "roof", "over", "overhang past the walls")
    buildingUi.modNumber(ids, list, "roof", "gable", "overhang at the roof's ends", window.modValue(m, "over"))
    buildingUi.modNumber(ids, list, "roof", "thick", "thickness of the roof")
    if m.shape ~= "shed" and m.part ~= "right" and m.part ~= "left" then
        buildingUi.modNumber(ids, list, "roof", "ridge", "ridge off the middle (- right, + left, part of the half width)")
    end
    ui.back("blddefault_roofmat", "roof material", m.mat ~= nil or m.tex ~= nil or m.turn ~= nil, function()
        buildingUi.roofField(ids, list, function(r) r.mat, r.tex, r.turn = nil, nil, nil end)
    end)
    local cur = m.mat
    local t   = (m.tex or m.turn) and windowUi.texOf(cur, "roof") or nil
    if t then
        local k         = m.tex or 1.0
        t.u, t.v, t.rot = t.u * k, t.v * k, m.turn and 90 or t.rot
        cur             = texture.encode(t)
    end
    local picked, value = windowUi.texField("bldroofmat", "roof", cur, "as the top surface", nil, nil, function(v)
        buildingUi.roofField(ids, list, function(r) r.mat, r.tex, r.turn = (v ~= "") and v or nil, nil, nil end)
    end)
    if picked then
        statusText = tr("%s: %s", lookup("roof material"), windowUi.texLabel(value, "roof", "as the top surface"))
    elseif value then
        statusText = value
    end
end

function buildingUi.drawRoofPart(ids, list)
    local m = buildingUi.firstCfg(list).mods.roof
    if m.part ~= "right" and m.part ~= "left" and m.shape ~= "shed" then
        local hit, v = ui.check("bldroofcap", "ridge cap", m.cap == true)
        if hit then
            buildingUi.roofField(ids, list, function(r) r.cap = v or nil end)
            statusText = tr("%s: %s", lookup("ridge cap"), lookup(v and "on" or "off"))
        end
        if m.cap and ui.beginProps("bldroofcaps") then
            buildingUi.modNumber(ids, list, "roof", "capW", "ridge cap width")
            buildingUi.modNumber(ids, list, "roof", "capH", "ridge cap height")
            ui.endProps()
        end
    end
    local changed, on = ui.check("bldroofpart", "only on part of the floor", m.part ~= nil)
    if changed then
        buildingUi.roofField(ids, list, function(r) r.part = on and "start" or nil end)
        statusText = tr("%s: %s", lookup("only on part of the floor"), lookup(on and "on" or "off"))
        return
    end
    if not (m.part and ui.beginProps("bldroofparts")) then return end
    local faces = {}
    for _, f in ipairs(window.faceKeys) do faces[#faces + 1] = {f, windowUi.faceShort[f]} end
    buildingUi.roofSegment("bldroofface", "from the face", faces, m.part, function(v)
        buildingUi.roofField(ids, list, function(r) r.part = v end)
    end)
    buildingUi.modNumber(ids, list, "roof", "depth", "how far into the floor")
    ui.endProps()
end

buildingUi.rowKeys = {"style", "dir", "rise", "width", "height", "sill", "gap", "depth", "wall", "dae", "lead", "tail", "count", "align"}

function buildingUi.drawRowsAll(ids, list, key)
    local faces = {}
    for _, c in ipairs(list) do faces[c.face] = true end
    local function match(fl)
        if key == "doors" then return fl.at ~= nil and faces[fl.face or "right"] == true end
        return fl.at == nil
    end
    local floors        = buildingUi.floorsIn(list)
    local fid0, cfg, k0 = nil, nil, nil
    local n, differ     = 0, false
    for _, c in ipairs(floors) do
        local wc = windowUi.read(c.fid)
        for k, fl in ipairs(wc and wc.floors or {}) do
            if match(fl) then
                n = n + 1
                if not fid0 then fid0, cfg, k0 = c.fid, wc, k end
                for _, f in ipairs(buildingUi.rowKeys) do differ = differ or fl[f] ~= cfg.floors[k0][f] end
            end
        end
    end
    if not fid0 then return end
    ui.heading(tr((key == "doors") and "all %d doors here" or "all %d rows of windows here", n))
    if differ then text("they differ from each other: a value set here goes to all of them", ui.orange) end
    local function all(fn)
        if key == "doors" then
            return buildingUi.writeCells(ids, list, function(c, face)
                for _, fl in ipairs(c.floors) do
                    if fl.at and (fl.face or "right") == face then fn(fl) end
                end
            end, key, true)
        end
        buildingUi.writeCells(ids, floors, function(c)
            for _, fl in ipairs(c.floors) do
                if match(fl) then fn(fl) end
            end
        end, key, true)
    end
    local fl     = cfg.floors[k0]
    local before = {}
    for _, f in ipairs(buildingUi.rowKeys) do before[f] = fl[f] end
    if not windowUi.drawOpening(fid0, cfg, k0, (key == "doors") and "alldoor" or "allwin", all) then return end
    local diff = {}
    for _, f in ipairs(buildingUi.rowKeys) do
        if fl[f] ~= before[f] or (fl.style ~= before.style and (f == "dae" or f == "rise" or f == "dir")) then diff[#diff + 1] = f end
    end
    if #diff > 0 then all(function(r) for _, f in ipairs(diff) do r[f] = fl[f] end end) end
end

function buildingUi.drawRows(ids)
    local rows, only = buildingUi.fullRows(ids)
    if not (only and #rows == 1) then
        buildingUi.drawRowsAll(ids, buildingUi.cells(ids), "windows")
        text("for a floor's rows of windows one by one (how many, how high), mark that whole floor", ui.grey)
        return
    end
    ui.heading(lookup("rows of windows"))
    windowUi.drawRows(rows[1], ids)
end

function buildingUi.winsInTab()
    local kind = nil
    for _, w in pairs(buildingUi.wins) do
        if kind and w.kind ~= kind then return false end
        kind = w.kind
    end
    return kind ~= nil and kind == buildingUi.mod
end

function buildingUi.drawFaceDoors(ids)
    local sel = buildingUi.selected(ids)
    if #sel ~= 1 then
        buildingUi.drawRowsAll(ids, buildingUi.cells(ids), "doors")
        text("the doors one by one (add, place, size, model): mark one face", ui.grey)
        return
    end
    buildingUi.drawDoors(ids, sel[1])
end

function buildingUi.drawDoors(ids, cell)
    ui.heading(lookup("doors on this face"))
    local id    = cell.fid
    local wc    = windowUi.read(id)
    local doors = {}
    for k, fl in ipairs(wc and wc.floors or {}) do
        if fl.at and (fl.face or "right") == cell.face then doors[#doors + 1] = k end
    end
    local items = {}
    for n, k in ipairs(doors) do
        local on        = k == buildingUi.doorSel[id] or (n == 1 and not buildingUi.doorSel[id])
        items[#items + 1] = ui.btnItem(tr("door %d", n), "blddoor_" .. k, on and ui.on or ui.off, on and ui.white or nil)
    end
    items[#items + 1] = ui.act("blddooradd", iconOf.door, "a door on this face", ui.add)
    local hit = ui.row(items)
    if hit == "blddooradd" then
        buildingUi.writeCells(ids, {cell}, function(c, face)
            local added = building.defaultWindows(true).floors[1]
            for _, fl in ipairs(c.floors) do
                if fl.at and fl.dae then added.dae, added.width, added.height = fl.dae, fl.width, fl.height end
            end
            added.face, added.at = face, windowUi.freeAt(c, face)
            if not c.faces[face] then c.faces[face], c.off[face] = true, true end
            c.floors[#c.floors + 1] = added
        end)
        local fresh = windowUi.read(id)
        buildingUi.doorSel[id] = fresh and #fresh.floors or nil
        statusText             = "door added"
        return
    elseif hit then
        buildingUi.doorSel[id] = tonumber(hit:sub(#"blddoor_" + 1))
    end
    if #doors == 0 then
        text("no door on this face yet", ui.grey)
        return
    end
    local sel = doors[1]
    for _, k in ipairs(doors) do
        if k == buildingUi.doorSel[id] then sel = k end
    end
    local fl = wc.floors[sel]
    if windowUi.drawOpening(id, wc, sel, "windoor") then buildingUi.doorSel[id] = windowUi.indexOf(wc, fl) end
    if ui.row({ui.act("windoordel", iconOf.remove, "remove the door")}) then
        table.remove(wc.floors, sel)
        windowUi.write(id, wc)
        buildingUi.doorSel[id] = nil
        statusText             = "door removed"
    end
end

function buildingUi.faceOf(list)
    local face = list[1] and list[1].face
    for _, c in ipairs(list) do
        if c.face ~= face then return nil end
    end
    return face
end

function buildingUi.startPush(fid, face)
    ui.keep = nil
    editor.clearObjectSelection()
    buildingUi.push = {kind = "wall", fid = fid, face = face, align = editor.getAxisGizmoAlignment(), mode = editor.getAxisGizmoMode(),
                       from = buildingUi.pushFrom}
    editor.setAxisGizmoMode(editor.AxisGizmoMode_Translate)
    editor.setAxisGizmoAlignment(editor.AxisGizmoAlignment_Local)
    editor.setAxisGizmoTranslateLock(false, true, false)
    statusText = "drag the arrow on the wall"
end

function buildingUi.startMove(list, k)
    buildingUi.stopPush()
    ui.keep = nil
    editor.clearObjectSelection()
    buildingUi.push = {kind = "move", fid = list[k].ids[1], ids = list[k].ids, movers = building.movers(list, k), unit = list[k].kind == "unit",
                       align = editor.getAxisGizmoAlignment(), mode = editor.getAxisGizmoMode()}
    editor.setAxisGizmoMode(editor.AxisGizmoMode_Translate)
    editor.setAxisGizmoAlignment(editor.AxisGizmoAlignment_Local)
    editor.setAxisGizmoTranslateLock(true, true, false)
    statusText = "drag the arrows to move the part"
end

function buildingUi.stopPush()
    local p = buildingUi.push
    if not p then return end
    if p.drag then buildingUi.pushEnd() end
    buildingUi.push = nil
    editor.setAxisGizmoTranslateLock(true, true, true)
    editor.setAxisGizmoAlignment(p.align)
    editor.setAxisGizmoMode(p.mode)
end

function buildingUi.pushBegin()
    local p = buildingUi.push
    if not p then return end
    p.start = vec3(editor.getAxisGizmoTransform():getColumn(3))
    p.d     = 0.0
    if p.kind == "wins" then
        for _, w in pairs(buildingUi.wins) do
            local sm = buildingUi.winMesh(w)
            if sm then w.at, w.frame, w.along, w.out = sm.at, sm.frame, sm.along, sm.out end
        end
        p.ds, p.dz, p.shift, p.drag = 0.0, 0.0, vec3(0, 0, 0), true
        return
    end
    if p.kind == "move" then
        p.snaps, p.c0 = {}, building.view(p.ids).center
        for _, id in ipairs(p.movers) do
            local w = building.wallOf(id)
            if w then p.snaps[#p.snaps + 1] = w end
        end
        p.drag = #p.snaps > 0
        return
    end
    if p.from and building.driver(p.fid) ~= p.fid then
        local old, cut = building.detachData(p.fid)
        p.detach       = {old = old, new = cut}
        building.writeData(p.fid, cut)
    end
    p.snap = building.wallOf(p.fid)
    p.drag = p.snap ~= nil
end

function buildingUi.pushDrag()
    local p = buildingUi.push
    if not (p and p.drag) then return end
    if p.kind == "wins" then return buildingUi.winsShift(p) end
    local delta = vec3(editor.getAxisGizmoTransform():getColumn(3)) - p.start
    local step  = building.defaults.push
    if p.kind == "move" and p.unit then
        for _, m in ipairs(building.docked(p.fid, p.c0 + vec3(delta.x, delta.y, 0), buildingUi.pushStep and step or nil) or {}) do building.placeWall(m.id, m.new) end
        p.d = vec3(delta.x, delta.y, 0):length()
        return
    end
    if p.kind == "move" then
        local function snap(v) return buildingUi.pushStep and math.floor(v / step + 0.5) * step or v end
        local d = p.n * snap(delta:dot(p.n)) + p.r * snap(delta:dot(p.r))
        for _, w in ipairs(p.snaps) do building.placeWall(w.id, building.moved(w, d)) end
        p.d = d:length()
        return
    end
    local raw    = delta:dot(p.n)
    local new, d = building.pushed(p.snap, p.face, buildingUi.pushStep and math.floor(raw / step + 0.5) * step or raw)
    p.d          = d
    building.placeWall(p.snap.id, new)
end

function buildingUi.pushEnd()
    local p = buildingUi.push
    if not (p and p.drag) then return end
    p.drag = false
    dirty()
    if p.kind == "wins" then return buildingUi.winsEnd(p) end
    if p.kind == "move" then
        local list = {}
        for _, w in ipairs(p.snaps) do
            local now = building.wallOf(w.id)
            if now then list[#list + 1] = {id = w.id, old = w.nodes, new = now.nodes} end
        end
        building.commitMove(list)
        statusText, p.snaps = tr("part moved by %s m", string.format("%.2f", p.d)), nil
        return
    end
    local now = building.wallOf(p.fid)
    transaction("MagePushWall", function()
        if p.detach then building.commitDetach(p.fid, p.detach.old, p.detach.new) end
        if now then building.commitWall(p.snap.id, p.snap.nodes, now.nodes) end
    end)
    statusText       = tr("wall moved by %s m", string.format("%.2f", p.d))
    p.snap, p.detach = nil, nil
end

function buildingUi.pushFrame()
    local p = buildingUi.push
    if not p then return end
    if not buildingUi.open or not editor.isWindowVisible(toolWindowName) or #getSelection() > 0 or not scenetree.findObjectById(p.fid) then
        return buildingUi.stopPush()
    end
    if editor.getAxisGizmoMode() ~= editor.AxisGizmoMode_Translate then editor.setAxisGizmoMode(editor.AxisGizmoMode_Translate) end
    if p.kind == "wins" and not p.drag then
        local list = buildingUi.winList()
        local b    = list[1] and buildingUi.winBox(list[1])
        if not b then return end
        p.along   = list[1].along
        local q   = quatFromDir(list[1].out, vec3(0, 0, 1))
        local mtx = QuatF(q.x, q.y, q.z, q.w):getMatrix()
        mtx:setPosition((b[1] + b[2]) * 0.5)
        editor.setAxisGizmoTransform(mtx)
    elseif not p.drag then
        local snap = building.wallOf(p.fid)
        if not snap then return buildingUi.stopPush() end
        local pos, n
        if p.kind == "move" then
            local v = building.view(p.ids)
            pos, n  = v.center, vec3(-v.right.y, v.right.x, 0)
            p.r     = v.right
        else
            pos, n = building.anchor(snap, p.face, p.fid)
        end
        local q   = quatFromDir(n, vec3(0, 0, 1))
        local mtx = QuatF(q.x, q.y, q.z, q.w):getMatrix()
        mtx:setPosition(pos)
        editor.setAxisGizmoTransform(mtx)
        p.n = n
    end
    editor.updateAxisGizmo(buildingUi.pushBegin, buildingUi.pushEnd, buildingUi.pushDrag)
    editor.drawAxisGizmo()
end

function buildingUi.drawPush(list)
    local face = buildingUi.faceOf(list)
    local p    = buildingUi.push
    local fid  = face and list[1].fid
    if p and p.kind == "wall" and (p.face ~= face or p.fid ~= fid) then
        buildingUi.stopPush()
    end
    p = buildingUi.push and buildingUi.push.kind == "wall" and buildingUi.push or nil
    local snap = fid and building.wallOf(fid)
    if not snap then return end
    local isEnd = face == "start" or face == "end"
    local led   = building.driver(fid) ~= fid
    local from  = led and buildingUi.pushFrom
    local ptr   = imgui.BoolPtr(buildingUi.pushStep)
    local fptr  = imgui.BoolPtr(buildingUi.pushFrom)
    local items = {ui.iconItem("bldpush", iconOf.pushWall, lookup("push the wall"), p and ui.white or nil, ui.icon, p and ui.pick or nil,
                               lookup(p and "push the wall: on - click to stop" or "push the wall with an arrow on it")),
                   ui.markItem("bldpushstep", tr("steps of %s m", string.format("%g", building.defaults.push)), ptr)}
    if led then
        items[3]     = ui.markItem("bldpushfrom", lookup("only this floor and up"), fptr)
        items[3].tip = "off: the whole wall moves, from the floor this one follows. on: this floor gets its own path and width, the floors below stay"
    end
    local hit = ui.row(items)
    if hit == "bldpush" then
        if p then buildingUi.stopPush() else buildingUi.startPush(fid, face) end
    elseif hit == "bldpushstep" then
        buildingUi.pushStep = ptr[0]
    elseif hit == "bldpushfrom" then
        buildingUi.pushFrom = fptr[0]
        if p then
            buildingUi.stopPush()
            buildingUi.startPush(fid, face)
        end
    end
    if from then snap = building.ownNodes(fid) end
    local label = isEnd and "length" or "width"
    if ui.beginProps("bldpush") then
        ui.prop(lookup(label))
        local cur = building.span(snap, face)
        local v   = ui.number("bldwall", "bldwalldec", "bldwallinc", cur, building.defaults.least, 500.0, nil)
        ui.endProps()
        if v then
            local done = building.pushWall(fid, face, v - cur, from)
            dirty()
            statusText = tr("%s set to %s", lookup(label), string.format("%g", cur + done))
        end
    end
    text((p and from) and "drag the arrow on the wall. this floor and the floors that follow it move, the floors below stay"
         or p and "drag the arrow on the wall. the whole wall moves, on every floor that follows this one"
         or (isEnd and "moves this end of the building along its path" or "moves this side of the building, the opposite side stays"), ui.grey)
end

function buildingUi.partName(list, k)
    local p = list[k]
    if p.kind == "main" then return lookup("main part") end
    local n = 0
    for j = 1, k do
        if list[j].kind == "unit" then n = n + 1 end
    end
    return tr("attached unit %d", n)
end

function buildingUi.partOf(list, id)
    for k, p in ipairs(list) do
        if p.ids[1] == buildingUi.partId then return k end
    end
    for k, p in ipairs(list) do
        for _, fid in ipairs(p.ids) do
            if fid == id then return k end
        end
    end
    return 1
end

function buildingUi.drawParts(list, k)
    ui.heading(lookup("parts of the building"))
    local hit = nil
    if not ui.beginTable("bldparts", {0.74, 0.13, 0.13}) then return nil end
    for j, p in ipairs(list) do
        local on   = j == k
        local tied = buildingUi.linkOn(p)
        ui.cells({function()
            local it = ui.btnItem(buildingUi.partName(list, j) .. "  -  " .. tr("%d floors", #p.ids), "bldpart_" .. j, on and ui.pick or ui.off,
                                  on and ui.white or nil, availWidth())
            if it.draw() then hit = "bldpart_" .. j end
        end, function()
            if ui.smallIcon("bldlink_" .. j, tied and iconOf.link or iconOf.unlink, lookup(tied and "linked" or "not linked"), tied and ui.white or ui.grey, ui.icon, nil,
                            lookup(tied and "linked: changes to models and textures (not the roof or the floors) apply to every linked part - click to unlink"
                                   or "not linked: changes made in other parts leave this one as it is - click to link")) then
                hit = "bldlink_" .. j
            end
        end, function()
            if ui.smallIcon("bldfocus_" .. j, iconOf.focus, lookup("look at this part"), nil, ui.icon) then hit = "bldfocus_" .. j end
        end})
    end
    imgui.EndTable()
    return hit
end

buildingUi.hitCache = setmetatable({}, {__mode = "k"})
buildingUi.pickBias = 0.05

function buildingUi.cacheOf(sm)
    local c = buildingUi.hitCache[sm]
    if c then return c end
    local lo, hi = vec3(math.huge, math.huge, math.huge), vec3(-math.huge, -math.huge, -math.huge)
    local pts    = {}
    for i, v in ipairs(sm.verts) do
        pts[i]           = vec3(v.x, v.y, v.z)
        lo.x, lo.y, lo.z = math.min(lo.x, v.x), math.min(lo.y, v.y), math.min(lo.z, v.z)
        hi.x, hi.y, hi.z = math.max(hi.x, v.x), math.max(hi.y, v.y), math.max(hi.z, v.z)
    end
    c                       = {box = {lo, hi}, pts = pts}
    buildingUi.hitCache[sm] = c
    return c
end

function buildingUi.boxOf(sm)
    return buildingUi.cacheOf(sm).box
end

function buildingUi.together(o, sm)
    if sm.slot then return o.kind == sm.kind and o.slot == sm.slot and o.fi == sm.fi end
    return sm.inst ~= nil and o.inst == sm.inst
end

function buildingUi.groupBox(fid, sm)
    local b      = buildingUi.boxOf(sm)
    local lo, hi = vec3(b[1]), vec3(b[2])
    for _, o in ipairs(preview.meshesOf(fid) or {}) do
        if o ~= sm and buildingUi.together(o, sm) then
            local c          = buildingUi.boxOf(o)
            lo.x, lo.y, lo.z = math.min(lo.x, c[1].x), math.min(lo.y, c[1].y), math.min(lo.z, c[1].z)
            hi.x, hi.y, hi.z = math.max(hi.x, c[2].x), math.max(hi.y, c[2].y), math.max(hi.z, c[2].z)
        end
    end
    return {lo, hi}
end

function buildingUi.rayBox(pos, dir, b)
    local t0, t1 = 0.0, math.huge
    for _, a in ipairs({"x", "y", "z"}) do
        if math.abs(dir[a]) < 1e-12 then
            if pos[a] < b[1][a] or pos[a] > b[2][a] then return false end
        else
            local u, v = (b[1][a] - pos[a]) / dir[a], (b[2][a] - pos[a]) / dir[a]
            if u > v then u, v = v, u end
            t0, t1 = math.max(t0, u), math.min(t1, v)
            if t0 > t1 then return false end
        end
    end
    return true
end

function buildingUi.anyMesh()
    for _, fid in ipairs(building.group(buildingUi.current)) do
        if preview.meshesOf(fid) then return true end
    end
    return false
end

function buildingUi.pickHit(ray)
    local best, bestD, bestE = nil, math.huge, math.huge
    for _, fid in ipairs(buildingUi.current and building.group(buildingUi.current) or {}) do
        for _, sm in ipairs(preview.meshesOf(fid) or {}) do
            if #sm.faces > 0 and buildingUi.rayBox(ray.pos, ray.dir, buildingUi.boxOf(sm)) then
                local V = buildingUi.cacheOf(sm).pts
                for k = 1, #sm.faces, 3 do
                    local d = intersectsRay_Triangle(ray.pos, ray.dir, V[sm.faces[k].v + 1], V[sm.faces[k + 1].v + 1], V[sm.faces[k + 2].v + 1])
                    if d and d < math.huge then
                        local e = d - (sm.kind and buildingUi.pickBias or 0)
                        if e < bestE then best, bestD, bestE = {fid = fid, sm = sm, k = k}, d, e end
                    end
                end
            end
        end
    end
    if not best then return nil end
    local sm  = best.sm
    local V   = buildingUi.cacheOf(sm).pts
    local a   = V[sm.faces[best.k].v + 1]
    local n   = (V[sm.faces[best.k + 1].v + 1] - a):cross(V[sm.faces[best.k + 2].v + 1] - a)
    best.p    = ray.pos + ray.dir * bestD
    best.face = building.faceAt(best.fid, best.p)
    best.kind = sm.kind
    best.top  = not sm.kind and n:length() > 1e-12 and math.abs(n:normalized().z) > 0.7
    return best
end

function buildingUi.drawBox(b, col, shift)
    local d = shift or vec3(0, 0, 0)
    local c = {}
    for i = 0, 7 do c[i + 1] = vec3((i % 2 == 0) and b[1].x or b[2].x, (math.floor(i / 2) % 2 == 0) and b[1].y or b[2].y, (i < 4) and b[1].z or b[2].z) + d end
    for _, e in ipairs({{1, 2}, {2, 4}, {4, 3}, {3, 1}, {5, 6}, {6, 8}, {8, 7}, {7, 5}, {1, 5}, {2, 6}, {3, 7}, {4, 8}}) do debugDrawer:drawLine(c[e[1]], c[e[2]], col) end
end

function buildingUi.drawHit(hit, col)
    local function seg(p, q) debugDrawer:drawLine(p, q, col) end
    if hit.kind then return buildingUi.drawBox(buildingUi.groupBox(hit.fid, hit.sm), col) end
    local lines, lo, hi, poly = building.faceLines(hit.fid)
    if not lines then return end
    local l = hit.top and poly or lines[hit.face]
    for i = 1, #l - (hit.top and 0 or 1) do
        local p, q = l[i], l[i % #l + 1]
        seg(vec3(p.x, p.y, hi), vec3(q.x, q.y, hi))
        if not hit.top then seg(vec3(p.x, p.y, lo), vec3(q.x, q.y, lo)) end
    end
    if not hit.top then
        seg(vec3(l[1].x, l[1].y, lo), vec3(l[1].x, l[1].y, hi))
        seg(vec3(l[#l].x, l[#l].y, lo), vec3(l[#l].x, l[#l].y, hi))
    end
end

function buildingUi.pickApply(hit, add)
    local list = building.parts(buildingUi.current)
    local part
    for _, p in ipairs(list) do
        for _, fid in ipairs(p.ids) do
            if fid == hit.fid then part = p end
        end
    end
    if part.ids[1] ~= buildingUi.partId then
        buildingUi.partId, buildingUi.sel = part.ids[1], {}
        buildingUi.dropWins()
    end
    buildingUi.chooseWin(hit, add or buildingUi.multi)
    local keys = {}
    if hit.top then
        for _, f in ipairs(window.faceKeys) do keys[#keys + 1] = buildingUi.key(hit.fid, f) end
    elseif hit.face then
        keys[1] = buildingUi.key(hit.fid, hit.face)
    end
    for _, m in ipairs(buildingUi.modList) do
        if m.key == hit.kind then
            buildingUi.mod        = hit.kind
            buildingUi.modelsOpen = true
            ui.openOnce[lookup("models")] = true
        end
    end
    if add or buildingUi.multi then
        local multi      = buildingUi.multi
        buildingUi.multi = true
        buildingUi.pick(keys)
        buildingUi.multi = multi
    else
        buildingUi.sel = {}
        for _, k in ipairs(keys) do buildingUi.sel[k] = true end
    end
    statusText = hit.kind and tr("%s chosen", lookup(buildingUi.labelOf(hit.kind))) or "chosen in the world"
end

function buildingUi.picking()
    return editor.editModes.magePick ~= nil and editor.editMode == editor.editModes.magePick
end

function buildingUi.pickMode(on)
    if on and not buildingUi.picking() then
        buildingUi.stopPush()
        buildingUi.pickWas = editor.editMode
        editor.selectEditMode(editor.editModes.magePick)
    elseif not on and buildingUi.picking() then
        buildingUi.dropWins()
        editor.selectEditMode(buildingUi.pickWas or editor.editModes.objectSelect)
        buildingUi.pickWas = nil
    end
end

function buildingUi.pickUpdate()
    local p = buildingUi.push
    for _, w in pairs(buildingUi.wins) do
        local b = buildingUi.winBox(w)
        if b then buildingUi.drawBox(b, ColorF(0.2, 0.6, 1.0, 1.0), p and p.kind == "wins" and p.drag and p.shift or nil) end
    end
    if not buildingUi.current or not editor.isViewportHovered() or editor.isAxisGizmoHovered() then return end
    local ray = getCameraMouseRay()
    local hit = ray and buildingUi.pickHit(ray)
    if not hit then
        if imgui.IsMouseClicked(0) and not buildingUi.anyMesh() then statusText = "render the building to choose in it" end
        return
    end
    buildingUi.drawHit(hit, ColorF(1.0, 0.6, 0.1, 1.0))
    if imgui.IsMouseClicked(0) then buildingUi.pickApply(hit, buildingUi.adding()) end
end

function buildingUi.adding()
    local mods = editor.keyModifiers or {}
    return mods.shift == true or mods.ctrl == true or imgui.GetIO().KeyCtrl == true
end

function buildingUi.pickFrame()
    if buildingUi.picking() and not (buildingUi.open and editor.isWindowVisible(toolWindowName)) then buildingUi.pickMode(false) end
end

function buildingUi.winKey(w)
    return w.fid .. "#" .. w.fi .. "#" .. w.slot
end

function buildingUi.chooseWin(hit, add)
    local sm = hit.sm
    if not (sm.slot and buildingUi.winKinds[hit.kind]) then
        if not add then buildingUi.dropWins() end
        return
    end
    local w   = {fid = hit.fid, fi = sm.fi, slot = sm.slot, kind = hit.kind, along = sm.along, out = sm.out, at = sm.at, frame = sm.frame,
                 prop = buildingUi.winKinds[hit.kind] == "prop", slide = buildingUi.winKinds[hit.kind] == "slide" or buildingUi.winKinds[hit.kind] == "roof",
                 roof = buildingUi.winKinds[hit.kind] == "roof", flat = buildingUi.flatKinds[hit.kind]}
    local key = buildingUi.winKey(w)
    if add then
        buildingUi.wins[key] = (not buildingUi.wins[key]) and w or nil
    else
        buildingUi.wins = {[key] = w}
    end
    buildingUi.startWins()
end

buildingUi.winKinds  = {windows = "row", doors = "row", balcony = "slide", awning = "slide", flowers = "slide", pots = "slide", ac = "prop", dish = "prop",
                        pipe = "prop", roofac = "roof", roofdish = "roof", corner = "slide", pilaster = "slide", plinth = "slide", course = "slide",
                        roofborder = "slide", stairs = "slide", pillar = "slide", corbel = "slide"}
buildingUi.flatKinds = {doors = true, pots = true, roofac = true, roofdish = true, pipe = true, pillar = true}
buildingUi.lookKinds = {windows = true, doors = true, balcony = true, ac = true, dish = true, awning = true, flowers = true, pots = true, stairs = true,
                        pillar = true, corbel = true, roofac = true, roofdish = true}

function buildingUi.chosenKind(key)
    for _, w in pairs(buildingUi.wins) do
        if w.kind == key then return true end
    end
    return false
end

function buildingUi.dropWins()
    if buildingUi.push and buildingUi.push.kind == "wins" then buildingUi.stopPush() end
    buildingUi.wins = {}
end

function buildingUi.winMesh(w)
    for _, sm in ipairs(preview.meshesOf(w.fid) or {}) do
        if sm.slot == w.slot and sm.fi == w.fi and sm.kind == w.kind then return sm end
    end
    return nil
end

function buildingUi.winBox(w)
    local sm = buildingUi.winMesh(w)
    return sm and buildingUi.groupBox(w.fid, sm) or nil
end

function buildingUi.winList()
    local out = {}
    for _, w in pairs(buildingUi.wins) do out[#out + 1] = w end
    table.sort(out, function(a, b) return buildingUi.winKey(a) < buildingUi.winKey(b) end)
    return out
end

function buildingUi.byFid(list)
    local byFid, order = {}, {}
    for _, w in ipairs(list) do
        if not byFid[w.fid] then
            byFid[w.fid]      = {}
            order[#order + 1] = w.fid
        end
        table.insert(byFid[w.fid], w)
    end
    table.sort(order)
    return byFid, order
end

function buildingUi.applyWins(list, fn)
    local byFid, order = buildingUi.byFid(list)
    for _, fid in ipairs(order) do
        local c = windowUi.read(fid)
        if c then
            for _, w in ipairs(byFid[fid]) do
                local row = w.slide and c.mods[w.fi] or c.floors[w.fi]
                if row then
                    local mv = (row.moves and row.moves[w.slot]) or {}
                    fn(mv, row, w)
                    row.moves         = row.moves or {}
                    row.moves[w.slot] = next(mv) and mv or nil
                    if not next(row.moves) then row.moves = nil end
                end
            end
            writeField(fid, fieldOf.windows, window.encode(c))
        end
    end
    dirty()
end

function buildingUi.startWins()
    buildingUi.stopPush()
    ui.keep = nil
    editor.clearObjectSelection()
    local list     = buildingUi.winList()
    local side, up = true, true
    for _, w in ipairs(list) do
        side = side and (w.prop or w.roof)
        up   = up and not w.flat
    end
    if #list == 0 then return end
    buildingUi.push = {kind = "wins", fid = list[1].fid, align = editor.getAxisGizmoAlignment(), mode = editor.getAxisGizmoMode(), side = side, up = up}
    editor.setAxisGizmoMode(editor.AxisGizmoMode_Translate)
    editor.setAxisGizmoAlignment(editor.AxisGizmoAlignment_Local)
    editor.setAxisGizmoTranslateLock(true, side, up)
    statusText = (side and up and "drag the arrows: the chosen fittings go anywhere on the building's walls, they stay against them")
                 or (side and "drag the arrows: the chosen ones move sideways, their height stays")
                 or (up and "drag the arrows: the chosen ones slide along their wall and up or down") or "drag the arrow: the chosen ones slide along their wall"
end

function buildingUi.winsShift(p)
    local delta = vec3(editor.getAxisGizmoTransform():getColumn(3)) - p.start
    local step  = buildingUi.pushStep and building.defaults.push or nil
    local function snap(v) return step and math.floor(v / step + 0.5) * step or v end
    p.ds    = snap(delta:dot(p.along))
    p.dv    = snap(delta:dot(vec3(-p.along.y, p.along.x, 0)))
    p.dz    = p.up and snap(delta.z) or 0.0
    p.shift = p.side and vec3(snap(delta.x), snap(delta.y), p.dz) or p.along * p.ds + vec3(0, 0, p.dz)
end

function buildingUi.winsEnd(p)
    local all = buildingUi.winList()
    if p.shift:length() < 1e-6 then return end
    local list, props = buildingUi.splitWins(all)
    transaction("MageMoveWindows", function()
        if #props > 0 then buildingUi.moveProps(props, p.shift) end
        buildingUi.applyWins(list, function(mv, row, w)
            local k    = w.along:dot(p.along) >= 0 and 1.0 or -1.0
            local s, z = (mv.s or 0.0) + p.ds * k, (mv.z or 0.0) + p.dz
            local v    = (mv.v or 0.0) + (w.roof and p.dv * k or 0.0)
            if row.sill and row.height then z = math.min(z, window.room(mv.h or select(2, window.rowSize(row)), windowUi.wallHeight(w.fid)) - row.sill) end
            mv.s = math.abs(s) > 1e-6 and s or nil
            mv.z = math.abs(z) > 1e-6 and z or nil
            mv.v = math.abs(v) > 1e-6 and v or nil
        end)
    end)
    if #list == 0 then
        statusText = tr("%d moved", #props)
        return
    end
    statusText = tr("%d moved by %s m along the wall and %s m up", #all, string.format("%.2f", p.ds), string.format("%.2f", p.dz))
end

function buildingUi.pinOf(w, at)
    local f   = w.frame
    local rel = at - f.o
    return {u = rel:dot(f.ax), v = rel:dot(vec3(-f.ax.y, f.ax.x, 0)), z = at.z - f.o.z}
end

function buildingUi.pinNo(w)
    return tonumber(w.slot:match("^pin|(%d+)$"))
end

function buildingUi.applyProps(list, fn)
    local byFid, order = buildingUi.byFid(list)
    for _, fid in ipairs(order) do
        local c = windowUi.read(fid)
        if c then
            local ws = byFid[fid]
            table.sort(ws, function(a, b) return (buildingUi.pinNo(a) or 0) > (buildingUi.pinNo(b) or 0) end)
            for _, w in ipairs(ws) do
                local m = c.mods[w.fi]
                fn(m, w, buildingUi.pinNo(w))
                if m.drop and not next(m.drop) then m.drop = nil end
                if m.pins and #m.pins == 0 then m.pins = nil end
                if m.moves and not next(m.moves) then m.moves = nil end
            end
            writeField(fid, fieldOf.windows, window.encode(c))
        end
    end
    dirty()
end

function buildingUi.moveProps(list, shift)
    local keep = {}
    buildingUi.applyProps(list, function(m, w, i)
        local pin = buildingUi.pinOf(w, w.at + shift)
        if i then
            pin.from, pin.dae, pin.own = m.pins[i].from, m.pins[i].dae, m.pins[i].own
            m.pins[i]                  = pin
        else
            m.drop, m.pins      = m.drop or {}, m.pins or {}
            m.drop[w.slot]      = true
            pin.from, pin.dae   = w.slot, m.moves and m.moves[w.slot] and m.moves[w.slot].dae
            m.pins[#m.pins + 1] = pin
            i                   = #m.pins
            if m.moves then m.moves[w.slot] = nil end
        end
        keep[#keep + 1] = {w = w, slot = "pin|" .. i}
    end)
    for _, k in ipairs(keep) do
        buildingUi.wins[buildingUi.winKey(k.w)] = nil
        k.w.slot                                = k.slot
        buildingUi.wins[buildingUi.winKey(k.w)] = k.w
    end
end

function buildingUi.splitWins(list)
    local rows, props = {}, {}
    for _, w in ipairs(list) do
        if w.prop then props[#props + 1] = w else rows[#rows + 1] = w end
    end
    return rows, props
end

function buildingUi.removeWins()
    local list        = buildingUi.winList()
    local rows, props = buildingUi.splitWins(list)
    if #list == 0 then return end
    transaction("MageRemove", function()
        buildingUi.applyWins(rows, function(mv, _, w) mv.off, mv.stay = true, buildingUi.winKinds[w.kind] == "row" or nil end)
        buildingUi.applyProps(props, function(m, w, i)
            if i then
                table.remove(m.pins, i)
            else
                m.drop         = m.drop or {}
                m.drop[w.slot] = true
            end
        end)
    end)
    buildingUi.dropWins()
    statusText = tr("%d removed", #list)
end

function buildingUi.winModel(list, kind, value)
    local same = {}
    for _, w in ipairs(list) do
        if w.kind == kind then same[#same + 1] = w end
    end
    local rows, props = buildingUi.splitWins(same)
    local mw, mh      = modules.hole(value)
    transaction("MageWindowModel", function()
        buildingUi.applyWins(rows, function(mv)
            mv.dae = value
            if mw then mv.w, mv.h, mv.style, mv.dir, mv.rise = mw, mh, "rect", nil, nil end
        end)
        buildingUi.applyProps(props, function(m, w, i)
            if i then
                m.pins[i].dae = value
            else
                m.moves             = m.moves or {}
                m.moves[w.slot]     = m.moves[w.slot] or {}
                m.moves[w.slot].dae = value
            end
        end)
    end)
end

function buildingUi.drawWins(ids)
    local list = buildingUi.winList()
    if #list == 0 then return end
    local mine = {}
    for _, fid in ipairs(ids) do mine[fid] = true end
    for _, w in ipairs(list) do
        if not mine[w.fid] then return buildingUi.dropWins() end
    end
    text(tr("%d chosen in the world", #list), ui.blue)
    text("drag the gizmo's arrows to move them, delete removes them", ui.grey)
    local items = {ui.act("bldwinremove", iconOf.remove, "remove them"),
                   ui.act("bldwinback", iconOf.restore, "put them back"),
                   ui.act("bldwinunpick", iconOf.unpick, "choose none")}
    items[1].tip = "the chosen ones go. where a window or door was, the wall closes"
    items[2].tip = "the chosen ones go back to where the settings put them, a window or door with its row's model"
    local hit = ui.row(items)
    local rows, props = buildingUi.splitWins(list)
    if hit == "bldwinremove" then
        return buildingUi.removeWins()
    elseif hit == "bldwinback" then
        transaction("MageReset", function()
            buildingUi.applyWins(rows, function(mv) for k in pairs(mv) do mv[k] = nil end end)
            buildingUi.applyProps(props, function(m, w, i)
                local from = i and m.pins[i].from or w.slot
                if i then table.remove(m.pins, i) end
                if m.drop and from then m.drop[from] = nil end
                if m.moves and from then m.moves[from] = nil end
            end)
        end)
        if #props > 0 then buildingUi.dropWins() end
        statusText = tr("%d put back", #list)
    elseif hit == "bldwinunpick" then
        buildingUi.dropWins()
        return
    end
    local kind = list[1].kind
    if not buildingUi.lookKinds[kind] then return end
    local opts = {}
    for _, path in ipairs(modules.list(kind)) do opts[#opts + 1] = {value = path, label = modules.label(path)} end
    local picked, value = windowUi.picker("bldwinmodel", lookup("model"), nil, opts, lookup("choose a model"), function(v)
        buildingUi.winModel(list, kind, v)
    end)
    if picked and value then
        statusText = tr("%s: %s", lookup("model"), modules.label(value))
    end
    local only = true
    for _, w in ipairs(list) do only = only and buildingUi.winKinds[w.kind] == "row" end
    if only then buildingUi.drawWinOwn(list) end
end

buildingUi.backStates = {{key = "wall", label = "a wall right behind", icon = iconOf.niche},
                         {key = "hall", label = "a dark entrance hall", icon = iconOf.backHall},
                         {key = "open", label = "open, for an interior of your own", icon = iconOf.through}}
buildingUi.backAuto   = {key = "auto", label = "by the model: a hall behind an open door", icon = iconOf.door}

function buildingUi.backLabel(key)
    for _, st in ipairs(buildingUi.backStates) do
        if st.key == key then return st.label end
    end
    return buildingUi.backAuto.label
end

function buildingUi.drawBack(ids, list)
    local cur = nil
    for _, c in ipairs(buildingUi.floorsIn(list)) do
        for _, fl in ipairs((windowUi.peek(c.fid) or {floors = {}}).floors) do
            if fl.at and cur == nil then cur = fl.back or "auto" end
        end
    end
    if not cur then return end
    local states = {buildingUi.backAuto}
    for _, st in ipairs(buildingUi.backStates) do states[#states + 1] = st end
    ui.prop(lookup("behind the opening"))
    local hit = ui.cycle("blddoorbehind", "behind the opening", states, cur)
    tip("what is seen through a door that stands open. by the model: a dark entrance hall behind a door model that leaves its opening open, a wall right behind any other")
    if not hit then return end
    buildingUi.writeCells(ids, buildingUi.floorsIn(list), function(c)
        for _, fl in ipairs(c.floors) do
            if fl.at then fl.back = (hit ~= "auto") and hit or nil end
        end
    end, "doors", true)
    statusText = tr("%s: %s", lookup("behind the opening"), lookup(buildingUi.backLabel(hit)))
end

function buildingUi.winOwnSeed(mv, row)
    if mv.w or mv.h or mv.style or mv.depth then return end
    local w, h   = modules.hole(mv.dae or "")
    local rw, rh = window.rowSize(row)
    mv.w, mv.h   = w or rw, h or rh
    mv.style     = w and "rect" or row.style
    mv.dir       = (mv.style == "quarter") and row.dir or nil
    mv.rise      = (mv.style ~= "rect") and row.rise or nil
    mv.depth     = row.depth
end

function buildingUi.winOwnNow(w)
    local c   = windowUi.peek(w.fid)
    local row = c and c.floors[w.fi]
    if not row then return nil end
    local mv     = row.moves and row.moves[w.slot] or {}
    local x, y   = modules.hole(mv.dae or "")
    local rw, rh = window.rowSize(row)
    return {w = mv.w or x or rw, h = mv.h or y or rh, style = mv.style or (x and "rect") or row.style, dir = mv.dir or row.dir,
            rise = mv.rise or row.rise, depth = mv.depth or row.depth or c.depth, tex = mv.tex, mv = mv,
            back = mv.back or row.back or (modules.openDoor(mv.dae or row.dae or "") and "hall" or "wall")}
end

function buildingUi.winOwnWrite(rows, label, fn, plain)
    transaction("MageWindowOwn", function()
        buildingUi.applyWins(rows, function(mv, row)
            if not plain then buildingUi.winOwnSeed(mv, row) end
            fn(mv, row)
        end)
    end)
    statusText = label
end

function buildingUi.winOwnProp(rows, field, label)
    local own = false
    for _, w in ipairs(rows) do
        local now = buildingUi.winOwnNow(w)
        if now and now.mv[field] ~= nil then own = true end
    end
    ui.prop(label, own and ui.blue or nil)
    if not own then return end
    if ui.smallIcon("bldwinownback_" .. field, iconOf.restore, lookup("like the row"), nil, 18, nil, lookup("this one takes the row's value again")) then
        buildingUi.winOwnWrite(rows, tr("%s: %s", lookup(label), lookup("like the row")), function(mv)
            mv[field] = nil
            if field == "style" then mv.dir, mv.rise = nil, nil end
        end, true)
    end
    imgui.SameLine()
end

function buildingUi.drawWinOwn(rows)
    local now = buildingUi.winOwnNow(rows[1])
    if not now or not ui.beginProps("bldwinown") then return end
    local function num(field, label, lim, cur)
        buildingUi.winOwnProp(rows, field, label)
        local v = ui.number("bldwinown" .. field, "bldwinown" .. field .. "dec", "bldwinown" .. field .. "inc", cur, lim[1], lim[2], lim[3])
        if v then buildingUi.winOwnWrite(rows, tr("%s set to %s", lookup(label), string.format("%g", v)), function(mv) mv[field] = v end) end
    end
    num("w", "opening width", window.limits.width, now.w)
    num("h", "opening height", window.limits.height, now.h)
    local row0 = windowUi.peek(rows[1].fid)
    row0       = row0 and row0.floors[rows[1].fi]
    if row0 and not row0.at then
        buildingUi.winOwnProp(rows, "z", "bottom of the window above the floor")
        local lim = window.limits.sill
        local top = math.max(lim[1], window.room(now.h, windowUi.wallHeight(rows[1].fid)))
        local v   = ui.number("bldwinownz", "bldwinownzdec", "bldwinownzinc", math.min(top, row0.sill + (now.mv.z or 0.0)), lim[1], top, row0.sill)
        if v then
            buildingUi.winOwnWrite(rows, tr("%s set to %s", lookup("bottom of the window above the floor"), string.format("%g", v)), function(mv, row)
                local dz = v - row.sill
                mv.z     = math.abs(dz) > 1e-6 and dz or nil
            end)
        end
    end
    buildingUi.winOwnProp(rows, "style", "shape")
    local states = {}
    for _, k in ipairs(windowUi.order) do states[#states + 1] = {key = k, label = windowUi.labels[k], icon = gateUi.iconOf[k]} end
    local hit = ui.cycle("bldwinownstyle", "shape", states, gateUi.kindOf({style = now.style, dir = now.dir}))
    if hit then
        buildingUi.winOwnWrite(rows, tr("%s: %s", lookup("shape"), lookup(windowUi.labels[hit])), function(mv, row)
            mv.style = hit:match("^quarter") and "quarter" or hit
            mv.dir   = (mv.style == "quarter") and hit:match("_(%a+)$") or nil
            mv.rise  = (mv.style ~= "rect") and (mv.rise or row.rise or (mv.w or row.width) / 2.0) or nil
        end)
    end
    if now.style ~= "rect" then num("rise", "height of the arch", {0.05, 50.0, (now.w or 1.0) / 2.0}, now.rise or now.w / 2.0) end
    local touch = false
    for _, w in ipairs(rows) do
        local rep = window.reportOf(w.fid)
        touch     = touch or (rep and rep.touch and rep.touch[w.slot]) == true
    end
    if touch then
        ui.prop("")
        text("touches another window: both stay as they are, move or narrow one of them", ui.orange)
    end
    local side, doors = true, true
    for _, w in ipairs(rows) do
        side  = side and not (w.slot:find("^start|") or w.slot:find("^end|"))
        doors = doors and w.kind == "doors"
    end
    if side then buildingUi.drawWinSide(rows, now, num, doors) end
    ui.endProps()
end

function buildingUi.drawWinSide(rows, now, num, doors)
    num("depth", "depth of the opening", window.limits.depth, now.depth)
    buildingUi.winOwnProp(rows, "tex", "sides of the opening")
    local picked, value = windowUi.texField("bldwinowntex", "wall", now.tex, "as the wall", nil, nil, function(v)
        buildingUi.winOwnWrite(rows, tr("%s: %s", lookup("sides of the opening"), windowUi.texLabel(v, "wall", "as the wall")), function(mv)
            mv.tex = (v ~= "") and v or nil
        end)
    end)
    if not picked and value then
        statusText = value
    end
    if not doors then return end
    buildingUi.winOwnProp(rows, "back", "behind the opening")
    local hit = ui.cycle("bldwinownbehind", "behind the opening", buildingUi.backStates, now.back)
    if hit then
        buildingUi.winOwnWrite(rows, tr("%s: %s", lookup("behind the opening"), lookup(buildingUi.backLabel(hit))), function(mv) mv.back = hit end)
    end
end

function buildingUi.movesIn(c, face, key)
    local out = {}
    for fi, fl in ipairs(c and c.floors or {}) do
        if (fl.at ~= nil) == (key == "doors") then
            for slot in pairs(fl.moves or {}) do
                local f = slot:match("^(%a+)|")
                if f == face or f == "both" then out[#out + 1] = {fi = fi, slot = slot} end
            end
        end
    end
    return out
end

function buildingUi.drawMoves(ids, list, key)
    local n = 0
    for _, c in ipairs(list) do n = n + #buildingUi.movesIn(windowUi.read(c.fid), c.face, key) end
    if n == 0 then return end
    ui.prop(lookup("changed in the world"))
    local hit = ui.row({ui.btnItem(tr("put back all %d", n), "bldmovesback", ui.off, nil, availWidth())})
    tip(lookup("windows or doors moved, removed or given another model in the world, on the marked faces, go back to their row"))
    if not hit then return end
    buildingUi.writeCells(ids, list, function(c, face)
        for _, m in ipairs(buildingUi.movesIn(c, face, key)) do
            local fl          = c.floors[m.fi]
            fl.moves[m.slot]  = nil
            if not next(fl.moves) then fl.moves = nil end
        end
    end)
    buildingUi.wins, statusText = {}, tr("%d put back", n)
end

function buildingUi.drawPins(ids, list, key)
    local floors, n = buildingUi.floorsIn(list), 0
    for _, c in ipairs(floors) do
        local m = (windowUi.read(c.fid) or {mods = {}}).mods[key]
        for _ in pairs(m and m.drop or {}) do n = n + 1 end
        for _, pin in ipairs(m and m.pins or {}) do
            if not pin.from then n = n + 1 end
        end
        for _ in pairs(m and m.moves or {}) do n = n + 1 end
    end
    if n == 0 then return end
    ui.prop(lookup("changed in the world"))
    local hit = ui.row({ui.btnItem(tr("put back all %d", n), "bldpinsback_" .. key, ui.off, nil, availWidth())})
    tip(lookup("the ones moved or removed in the world, on the marked floors, go back to where the settings put them"))
    if not hit then return end
    buildingUi.writeCells(ids, floors, function(c) c.mods[key].drop, c.mods[key].pins, c.mods[key].moves = nil, nil, nil end)
    buildingUi.dropWins()
    statusText = tr("%d put back", n)
end

function buildingUi.draw(id)
    local list = building.parts(id)
    if #list == 0 then list = {{kind = "main", ids = buildingUi.floorsOf(id), lead = {id}}} end
    local k   = buildingUi.partOf(list, id)
    local hit = buildingUi.drawParts(list, k)
    local j   = hit and tonumber(hit:match("_(%d+)$"))
    if hit and hit:sub(1, 9) == "bldfocus_" then
        buildingUi.focus(list[j].ids)
        statusText = "camera on the part's right side"
    elseif hit and hit:sub(1, 8) == "bldlink_" then
        local b = building.dataOf(list[j].ids[1])
        b.free  = buildingUi.linkOn(list[j]) or nil
        building.setData(list[j].ids[1], b)
        statusText = b.free and "this part is not linked" or "this part is linked"
    elseif hit then
        k, buildingUi.sel = j, {}
    end
    buildingUi.partId                       = list[k].ids[1]
    buildingUi.partsNow, buildingUi.partNow = list, k
    local p           = buildingUi.push
    if p and p.kind == "move" and p.fid ~= list[k].ids[1] then buildingUi.stopPush() end
    local ids         = list[k].ids
    buildingUi.prune(ids)
    buildingUi.drawGrid(ids)
    buildingUi.drawBar(ids, list, k)
    buildingUi.winsTop = not (buildingUi.winsInTab() and buildingUi.modelsOpen)
    if buildingUi.winsTop then buildingUi.drawWins(ids) end
    buildingUi.drawScope(ids)
    local sel            = buildingUi.selected(ids)
    local rows, onlyRows = buildingUi.fullRows(ids)
    buildingUi.drawPush(sel)
    if #sel == 0 then buildingUi.drawLook(ids) else buildingUi.drawFaces(ids, sel, not onlyRows) end
    if onlyRows then buildingUi.drawFloors(rows) end
    buildingUi.drawModels(ids)
end

function windowUi.newOpening(cfg, kind)
    local f = window.newFloor("round")
    f.kind  = kind
    f.at    = windowUi.freeAt(cfg, "right")
    if kind == "niche" then f.face = "right" end
    return f
end

function windowUi.openingLine(n, fl)
    local where = fl.at and tr("at %s", string.format("%g", fl.at)) or lookup("a row along the wall")
    local kind  = lookup("through opening")
    if fl.kind == "niche" then
        kind = tr("niche, %s", lookup(windowUi.faceShort[fl.face or "right"]))
    elseif fl.face == "start" or fl.face == "end" then
        kind = lookup("tunnel")
    end
    return tr("%d: %s, %s, %s", n, kind, lookup(windowUi.labels[gateUi.kindOf(fl)]), where)
end

windowUi.missText = {
    ["no room"]                                      = "no room for it",
    ["too high for the wall"]                        = "too high for the wall",
    ["too close to the end of the wall"]             = "too close to the end of the wall",
    ["meets a gate"]                                 = "meets a gate",
    ["meets a tunnel"]                               = "meets a tunnel but does not fit in its side",
    ["does not fit inside the wall along its length"] = "does not fit inside the wall along its length",
    ["overlaps another opening"]                     = "overlaps another opening",
    ["a closed wall has no ends"]                    = "a closed wall has no ends",
}

windowUi.missText["the wall bends here"] = "the wall bends here"

function windowUi.drawMisses(id, cfg, nameOf)
    local rep = window.reportOf(id)
    if not (rep and rep.sig == window.encode(cfg)) then return end
    for n = 1, #cfg.floors do
        local why = rep.miss[n]
        if why then text(tr("%s: left out - %s", nameOf(n, cfg.floors[n]), lookup(windowUi.missText[why] or why)), ui.orange) end
    end
end

function windowUi.writeWall(ids, cfg)
    if cfg then table.sort(cfg.floors, function(a, b) return a.sill < b.sill end) end
    transaction("MageWindows", function()
        for _, id in ipairs(ids) do writeField(id, fieldOf.windows, cfg and window.encode(cfg) or "") end
    end)
end

function windowUi.drawOpenings(picked, ids, oneWall)
    if not fieldOf.windows then return end
    if not section("openings in the wall", false) then return end
    if #picked ~= 1 and not oneWall then
        text("select a single MeshRoad to add openings", ui.grey)
        return
    end
    local id = picked[1]
    if buildingUi.isOn(id) then return end
    local cfg = windowUi.read(id)
    local hit = ui.row({ui.act("openadd", iconOf.addOpening, "add an opening", ui.add)})
    tip("through: a hole from one side of the wall to the other, or a tunnel from one end to the other. niche: a recess in one face only")
    if hit then
        if not cfg then
            cfg        = window.newConfig("round")
            cfg.floors = {}
            cfg.plain  = true
            cfg.faces  = {right = true, left = true, start = false, ["end"] = false}
        end
        local added                 = windowUi.newOpening(cfg, "through")
        cfg.floors[#cfg.floors + 1] = added
        windowUi.writeWall(ids, cfg)
        windowUi.line[id] = windowUi.indexOf(cfg, added)
        statusText        = "opening added"
        return
    end
    if not cfg or #cfg.floors == 0 then
        text("no openings in this wall yet", ui.grey)
        return
    end
    local sel = windowUi.line[id]
    if not sel or not cfg.floors[sel] then sel = 1 end
    for n, fl in ipairs(cfg.floors) do
        local mark = (n == sel) and ui.pick or ui.off
        local r    = ui.row({ui.btnItem(windowUi.openingLine(n, fl), "openpick_" .. n, mark, ui.white), ui.btnItem("x", "opendel_" .. n)})
        if r == "opendel_" .. n then
            table.remove(cfg.floors, n)
            windowUi.writeWall(ids, (#cfg.floors > 0) and cfg or nil)
            windowUi.line[id] = math.max(1, n - 1)
            statusText        = "opening removed"
            return
        elseif r then
            sel, windowUi.line[id] = n, n
        end
    end
    windowUi.drawMisses(id, cfg, function(n) return tostring(n) end)
    local fl      = cfg.floors[sel]
    local changed = false
    local onEnd   = fl.face == "start" or fl.face == "end"
    local kindIt  = ui.cycleItem("openkind", "kind of opening", {{key = "through", label = "through opening", icon = iconOf.through},
                                                               {key = "niche", label = "niche", icon = iconOf.niche}}, fl.kind or "through")
    local faceIt
    if fl.kind == "niche" then
        faceIt = ui.cycleItem("openface", "side of the niche", {{key = "right", label = "right side", icon = iconOf.nicheRight},
                                                               {key = "left", label = "left side", icon = iconOf.nicheLeft},
                                                               {key = "start", label = "start face", icon = iconOf.nicheStart},
                                                               {key = "end", label = "end face", icon = iconOf.nicheEnd}}, fl.face or "right")
    else
        faceIt = ui.cycleItem("openface", "direction", {{key = "across", label = "across the wall, side to side", icon = iconOf.through},
                                                       {key = "along", label = "along the wall, a tunnel from end to end", icon = iconOf.tunnel}},
                              onEnd and "along" or "across")
    end
    hit = ui.row({kindIt, faceIt})
    if hit == "openkind" then
        fl.kind = kindIt.next
        if fl.kind == "niche" then fl.face = onEnd and fl.face or "right" else fl.face = onEnd and fl.face or nil end
        changed = true
    elseif hit == "openface" then
        if fl.kind == "niche" then
            fl.face = faceIt.next
        else
            fl.face = (faceIt.next == "along") and "start" or nil
        end
        changed = true
    end
    local place = ui.cycle("openplace", "placing", {{key = "one", label = "one opening", icon = iconOf.openOne},
                                                    {key = "row", label = "a row along the wall", icon = iconOf.openRow}}, fl.at and "one" or "row")
    if place == "one" and not fl.at then
        fl.at   = 0.5
        changed = true
    elseif place == "row" and fl.at then
        fl.at   = nil
        changed = true
    end
    if ui.beginProps("openprops") then
        ui.prop(lookup("shape"))
        local k = windowUi.kindButton("openstyle", fl)
        if k then
            gateUi.setKind(fl, k)
            changed = true
        end
        if fl.at then
            ui.prop(lookup(onEnd and "position across the end (0 = right, 1 = left)" or "position along the wall (0 = start, 1 = end)"))
            local v = ui.number("openat", "openat_dec", "openat_inc", fl.at, 0.0, 1.0, 0.5)
            if v then
                fl.at   = v
                changed = true
            end
        end
        for _, f in ipairs({{key = "width", label = "opening width"}, {key = "height", label = "opening height"},
                            {key = "sill", label = "bottom of the opening above the base"}, {key = "gap", label = "gap length"}}) do
            if f.key ~= "gap" or not (fl.at or fl.count) then
                ui.prop(lookup(f.label))
                local v = windowUi.number("open" .. f.key, fl[f.key], f.key)
                if v then
                    fl[f.key] = v
                    changed   = true
                end
            end
        end
        if windowUi.drawRowMore(fl, "open", cfg.margin) then changed = true end
        if fl.kind == "niche" then
            ui.prop(lookup(onEnd and "how deep into the wall" or "niche depth"))
            local v = windowUi.number("opendepth", fl.depth or cfg.depth, "depth")
            if v then
                fl.depth = v
                changed  = true
            end
        end
        ui.endProps()
    end
    if window.lowers(fl, windowUi.wallHeight(id)) then
        text("too high for the wall at this height: built lower, so it fits", ui.orange)
    elseif not window.fits(fl, windowUi.wallHeight(id)) then
        text("does not fit in the wall's height", ui.orange)
    end
    if changed then
        windowUi.writeWall(ids, cfg)
        windowUi.line[id] = windowUi.indexOf(cfg, fl)
    end
end

-- =============================================================================
-- PLACING
-- =============================================================================

local tabUi = {active = "sidewalks", shapes = require('editor/mage/modules/Shape'), shape = nil, sync = true, wallCache = nil, wallList = nil,
               objCache = {}, wallObj = nil}

local placeUi = {mode = nil, turn = 0, k = 0, ghost = nil, entry = nil, roads = {}, lines = nil, linesKey = nil, job = nil, spawn = nil,
                 seed     = 1, was = nil, r = nil, far = 2000, budget = 0.02, perFrame = 6, turnStep = 15, maxSeed = 99999, linesAt = -math.huge,
                 linesAge = 0.5, anchor = nil, dragMin = 1.0, atan2 = math.atan2 or math.atan,
                 xs       = {scope = "one", buf = nil, open = {}, pick = {}, hover = nil, space = 5.0}}

function placeUi.opts()
    local o, lib = {}, building.saved()
    for k, v in pairs(town.defaults) do o[k] = v end
    for k, v in pairs(type(lib.opts) == "table" and lib.opts or {}) do
        if town.defaults[k] ~= nil and type(v) == type(town.defaults[k]) then o[k] = v end
    end
    o.seed = placeUi.seed
    return o
end

function placeUi.setOpt(key, v)
    local ok = building.editSaved(function(d)
        d.opts      = type(d.opts) == "table" and d.opts or {}
        d.opts[key] = v
    end)
    if not ok then statusText = "could not write the saved buildings file" end
    return ok
end

function placeUi.pool()
    local lib, names, out = building.saved(), {}, {}
    local gen             = type(lib.gen) == "table" and lib.gen or {}
    for n, on in pairs(gen) do
        if on == true and lib.items[n] then names[#names + 1] = n end
    end
    table.sort(names)
    for _, n in ipairs(names) do
        if town.shapeOf(lib.items[n]) then out[#out + 1] = {name = n, t = lib.items[n]} end
    end
    if #out == 0 then out[1] = {t = building.defaultTemplate()} end
    return out
end

function placeUi.placing()
    return editor.editModes.magePlace ~= nil and editor.editMode == editor.editModes.magePlace
end

function placeUi.next()
    local e
    if placeUi.mode == "random" then
        local pool = placeUi.pool()
        e          = pool[math.min(#pool, math.floor(placeUi.r() * #pool) + 1)]
    else
        local lib = building.saved()
        local t   = lib.default and lib.items[lib.default]
        e         = t and {name = lib.default, t = t} or {t = building.defaultTemplate(), mod = true}
    end
    e.shape       = town.shapeOf(e.t)
    placeUi.entry = e
end

function placeUi.start(kind)
    if placeUi.mode == kind then return placeUi.stop() end
    buildingUi.pickMode(false)
    placeUi.mode = kind
    placeUi.r    = placeUi.r or town.rng(os.time())
    placeUi.next()
    if not placeUi.placing() then
        placeUi.was = editor.editMode
        editor.selectEditMode(editor.editModes.magePlace)
    end
    tabUi.active = "place"
    statusText   = "click in the world to place the building"
end

function placeUi.stop()
    placeUi.mode, placeUi.ghost, placeUi.anchor = nil, nil, nil
    if placeUi.placing() then editor.selectEditMode(placeUi.was or editor.editModes.objectSelect) end
    placeUi.was = nil
end

function placeUi.rotate(dir)
    placeUi.turn = (placeUi.turn + dir * placeUi.turnStep) % 360
    placeUi.k    = (placeUi.k + dir) % 4
end

function placeUi.roadName(id)
    local n = objName(id)
    return (n ~= "") and n or ("DecalRoad " .. tostring(id))
end

function placeUi.snapLines()
    local key = table.concat(placeUi.roads, ",")
    if placeUi.linesKey ~= key or os.clock() - placeUi.linesAt > placeUi.linesAge then
        placeUi.lines, placeUi.linesKey, placeUi.linesAt = {}, key, os.clock()
        for _, id in ipairs(placeUi.roads) do
            local l = town.roadOf(id)
            if l then placeUi.lines[#placeUi.lines + 1] = l end
        end
    end
    return placeUi.lines
end

function placeUi.spot(hit, e, free)
    if e.group then return placeUi.groupSpot(hit, e) end
    local o = placeUi.opts()
    if o.snap and not free then
        local s = town.snapAt(placeUi.snapLines(), hit, e, placeUi.k, o.setback)
        if s then
            return {at = s.at, yaw = s.yaw, polys = s.polys, base = town.standOn(s.polys, hit.z), snapped = true}
        end
    end
    local at    = {x = hit.x, y = hit.y}
    local yaw   = math.rad(placeUi.turn)
    local polys = town.outline(e.shape, at, yaw)
    return {at = at, yaw = yaw, polys = polys, base = town.standOn(polys, hit.z)}
end

function placeUi.drawGhost(g, e)
    if g.members then
        for _, m in ipairs(g.members) do placeUi.drawGhost({polys = m.polys, base = m.base, yaw = m.yaw, at = {x = m.x, y = m.y}, shape = m.shape}, e) end
        return
    end
    local col    = g.snapped and ColorF(0.3, 1.0, 0.4, 1.0) or ColorF(0.2, 0.6, 1.0, 1.0)
    local shape  = g.shape or e.shape
    local lo, hi = g.base, g.base + shape.hi
    for _, poly in ipairs(g.polys) do
        for i = 1, #poly do
            local a, b = poly[i], poly[i % #poly + 1]
            debugDrawer:drawLine(vec3(a[1], a[2], lo), vec3(b[1], b[2], lo), col)
            debugDrawer:drawLine(vec3(a[1], a[2], hi), vec3(b[1], b[2], hi), col)
            debugDrawer:drawLine(vec3(a[1], a[2], lo), vec3(a[1], a[2], hi), col)
        end
    end
    local f = g.yaw + shape.front
    debugDrawer:drawLine(vec3(g.at.x, g.at.y, lo + 0.2), vec3(g.at.x + math.cos(f) * 4, g.at.y + math.sin(f) * 4, lo + 0.2), ColorF(1.0, 0.6, 0.1, 1.0))
end

function placeUi.put(g, e)
    if g.members then return placeUi.putGroup(g, e) end
    local at = vec3(g.at.x, g.at.y, g.base)
    local id, lost
    if e.mod then
        id = building.create(at, {yaw = g.yaw, base = g.base})
    else
        id, lost = building.spawnSaved(e.t, at, {yaw = g.yaw, base = g.base, frame = true})
    end
    if not id then
        statusText = "could not create the MeshRoad"
        return
    end
    dirty()
    statusText = e.name and tr("building %s placed", e.name) or "building placed"
    if lost and #lost > 0 then statusText = tr("building created; not in this map: %s", table.concat(lost, ", ")) end
    if placeUi.mode == "random" then return placeUi.next() end
    placeUi.stop()
    buildingUi.pin(id)
    editor.selectObjects({id})
    tabUi.active = "buildings"
end

function placeUi.update()
    if not placeUi.mode then return end
    if imgui.IsKeyPressed(imgui.GetKeyIndex(imgui.Key_Escape)) then return placeUi.stop() end
    local e = placeUi.entry
    if not (e and e.shape) then return end
    if not editor.isViewportHovered() or editor.isAxisGizmoHovered() then return end
    local mods = editor.keyModifiers or {}
    local ray  = getCameraMouseRay()
    local d    = ray and castRayStatic(ray.pos, ray.dir, placeUi.far)
    if type(d) ~= "number" or d >= placeUi.far then
        placeUi.ghost = nil
        return
    end
    local hit = ray.pos + ray.dir * d
    local a   = placeUi.anchor
    if a then
        local dx, dy = hit.x - a.hit.x, hit.y - a.hit.y
        if not a.ghost.snapped and dx * dx + dy * dy > placeUi.dragMin * placeUi.dragMin then
            placeUi.turn = math.deg(placeUi.atan2(dy, dx) - e.shape.front) % 360
            a.ghost      = placeUi.spot(a.hit, e, true)
        end
        placeUi.ghost = a.ghost
    else
        placeUi.ghost = placeUi.spot(hit, e, mods.shift)
    end
    placeUi.drawGhost(placeUi.ghost, e)
    if not a and imgui.IsMouseClicked(0) then
        a              = {hit = hit, ghost = placeUi.ghost}
        placeUi.anchor = a
    end
    if a and not imgui.IsMouseDown(0) then
        placeUi.anchor = nil
        placeUi.put(a.ghost, e)
    end
end

function placeUi.run(kind)
    if placeUi.job or placeUi.spawn then return end
    local ids = (kind == "all") and town.drivable() or placeUi.roads
    if #ids == 0 then
        statusText = (kind == "all") and "no drivable roads in this map" or "choose roads first"
        return
    end
    placeUi.stop()
    placeUi.job = {kind = kind, plan = town.newJob(ids, town.obstacles(), placeUi.pool(), placeUi.opts())}
    statusText  = "planning the buildings"
end

function placeUi.build()
    local j       = placeUi.job
    placeUi.job   = nil
    placeUi.spawn = {list = j.plan.out, k = 0, made = {}, n = 0, roads = #j.plan.lines, lost = {}}
end

function placeUi.finish()
    local s       = placeUi.spawn
    placeUi.spawn = nil
    building.commitBatch(s.made)
    dirty()
    statusText = tr("%d buildings placed along %d roads (one undo step)", s.n, s.roads)
    if s.failed then statusText = statusText .. ", " .. tr("%d skipped", s.failed) end
    local lost = {}
    for name in pairs(s.lost) do lost[#lost + 1] = name end
    table.sort(lost)
    if #lost > 0 then statusText = statusText .. ". " .. tr("not in this map: %s", table.concat(lost, ", ")) end
end

function placeUi.cancel()
    if placeUi.spawn then return placeUi.finish() end
    placeUi.job = nil
    statusText  = "stopped"
end

function placeUi.frame()
    placeUi.xs.buf = placeUi.xs.buf or imgui.ArrayChar(64)
    placeUi.drawHover()
    placeUi.xs.hover = nil
    if placeUi.placing() and not (tabUi.active == "place" and editor.isWindowVisible(toolWindowName)) then placeUi.stop() end
    if not placeUi.placing() then placeUi.mode = nil end
    if placeUi.placing() and not placeUi.mode then editor.selectEditMode(editor.editModes.objectSelect) end
    local j = placeUi.job
    if j and not j.ready and town.stepJob(j.plan, placeUi.budget) then
        j.ready = true
        if #j.plan.out == 0 then
            placeUi.job = nil
            statusText  = "no free spot along these roads"
        elseif j.kind ~= "all" then
            placeUi.build()
        end
    end
    local s = placeUi.spawn
    if not s then return end
    local stop = math.min(#s.list, s.k + placeUi.perFrame)
    for i = s.k + 1, stop do
        local lot      = s.list[i]
        s.k            = i
        local ds, lost = nil, nil
        local ok       = pcall(function()
            ds, lost = building.instantiate(lot.t, vec3(lot.at.x, lot.at.y, lot.base), {yaw = lot.yaw, base = lot.base, frame = true})
            if ds then building.placeBatch(ds) end
        end)
        for _, d in ipairs(ds or {}) do
            if d.id then s.made[#s.made + 1] = d end
        end
        if ok and ds then
            for _, name in ipairs(lost or {}) do s.lost[name] = true end
            s.n = s.n + 1
        elseif not ok then
            s.failed = (s.failed or 0) + 1
        end
    end
    if s.k >= #s.list then placeUi.finish() end
end

function placeUi.addRoads()
    local have, added = {}, 0
    for _, id in ipairs(placeUi.roads) do have[id] = true end
    for _, id in ipairs(getSelection()) do
        if classOf(id) == "DecalRoad" and not have[id] then
            placeUi.roads[#placeUi.roads + 1] = id
            have[id], added                   = true, added + 1
        end
    end
    statusText = (added > 0) and tr("%d roads added", added) or lookup("select DecalRoads in the world first")
end

function placeUi.drawTop()
    local items = {
        ui.act("bldcreate", iconOf.newBuilding, "create a building", (placeUi.mode == "one") and ui.pick or ui.add),
        ui.act("bldrandom", iconOf.random, "random building", (placeUi.mode == "random") and ui.pick or nil),
        ui.act("bldturnl", iconOf.turnLeft, "turn left"),
        ui.act("bldturnr", iconOf.turnRight, "turn right"),
    }
    local lib    = building.saved()
    items[1].tip = lib.default and tr("click in the world to place the saved building %s", lib.default)
                   or lookup("click in the world to place MaGE's building:\nwhite stucco walls, a gable roof of roof tiles, windows on every side and a door")
    items[2].tip = "click in the world again and again: each click places another building drawn from the generator"
    local hit = ui.row(items)
    if hit == "bldcreate" then
        placeUi.start("one")
    elseif hit == "bldrandom" then
        placeUi.start("random")
    elseif hit == "bldturnl" then
        placeUi.rotate(-1)
    elseif hit == "bldturnr" then
        placeUi.rotate(1)
    end
    text(tr("turn: %d degrees", math.floor(placeUi.turn + 0.5) % 360), ui.grey)
    if placeUi.mode then
        text("click in the world to place it, or hold and drag to turn it toward the mouse. shift: not on the road, esc: stop", ui.grey)
    end
end

function placeUi.drawRoadList()
    local hit = ui.row({ui.act("bldroadsadd", iconOf.addRoads, "add the selected roads"), ui.act("bldroadsclear", iconOf.clear, "clear the list")})
    if hit == "bldroadsadd" then
        placeUi.addRoads()
    elseif hit == "bldroadsclear" then
        placeUi.roads = {}
    end
    local keep = {}
    for _, id in ipairs(placeUi.roads) do
        if scenetree.findObjectById(id) then keep[#keep + 1] = id end
    end
    placeUi.roads = keep
    for k, id in ipairs(placeUi.roads) do
        if ui.row({ui.textItem(rtl(placeUi.roadName(id))), ui.act("bldroaddel_" .. k, iconOf.remove, "remove")}) then
            table.remove(placeUi.roads, k)
            break
        end
    end
    if #placeUi.roads == 0 then text("no roads chosen: select DecalRoads in the world and add them here", ui.grey) end
end

function placeUi.drawOptions(o)
    local d    = town.defaults
    local c, v = ui.check("bldsnap", "snap to the chosen roads", o.snap)
    if c then placeUi.setOpt("snap", v) end
    local sides = ui.segment("bldsides", {{key = "front", label = lookup("front to the road"), tip = lookup("the side with the door faces the road")},
                                          {key = "all", label = lookup("any side to the road"), tip = lookup("any of the four sides faces the road: four times the variety")}}, o.sides)
    if sides then placeUi.setOpt("sides", sides) end
    if not ui.beginProps("bldgen") then return end
    for _, f in ipairs({{"setback", "distance from the road"}, {"gapMin", "smallest gap between buildings"}, {"gapMax", "largest gap between buildings"}}) do
        local key, label = f[1], f[2]
        ui.back("bldgendef_" .. key, label, math.abs(o[key] - d[key]) > 1e-9, function() placeUi.setOpt(key, d[key]) end)
        local n = ui.number("bldgen_" .. key, "bldgenm_" .. key, "bldgenp_" .. key, o[key], 0, 50, d[key])
        if n then
            if key == "gapMin" and n > o.gapMax then placeUi.setOpt("gapMax", n) end
            if key == "gapMax" and n < o.gapMin then placeUi.setOpt("gapMin", n) end
            placeUi.setOpt(key, n)
        end
    end
    ui.prop("seed")
    local hit = ui.row({ui.textItem(tostring(placeUi.seed)), ui.act("bldseed", iconOf.seed, "another seed")})
    if hit then placeUi.seed = math.random(1, placeUi.maxSeed) end
    ui.endProps()
    text("the same seed and the same roads give the same street again", ui.grey)
end

function placeUi.drawRun()
    local j, s = placeUi.job, placeUi.spawn
    if s then
        text(tr("building %d of %d", s.k, #s.list))
        imgui.ProgressBar(#s.list > 0 and s.k / #s.list or 1, imgui.ImVec2(-1, 0))
        if ui.row({ui.act("bldgenstop", iconOf.stop, "stop")}) then placeUi.cancel() end
        return
    end
    if j and not j.ready then
        text(tr("planning: %d of %d road sides", j.plan.k, j.plan.total))
        imgui.ProgressBar(j.plan.total > 0 and j.plan.k / j.plan.total or 1, imgui.ImVec2(-1, 0))
        if ui.row({ui.act("bldgenstop", iconOf.stop, "stop")}) then placeUi.cancel() end
        return
    end
    if j and j.ready then
        text(tr("%d buildings along %d roads (%.1f km). build them?", #j.plan.out, #j.plan.lines, j.plan.length / 1000.0), ui.orange)
        local hit = ui.buttons({{lookup("build"), "bldgenyes", ui.add}, {lookup("cancel"), "bldgenno"}})
        if hit == "bldgenyes" then
            placeUi.build()
        elseif hit == "bldgenno" then
            placeUi.cancel()
        end
        return
    end
    local items = {ui.act("bldfill", iconOf.fill, "fill the chosen roads"), ui.act("bldfillall", iconOf.fillAll, "fill every drivable road of the map")}
    items[1].tip = "buildings along both sides of the chosen roads, whatever their drivability"
    items[2].tip = "buildings along both sides of every drivable road of the map. you see how many first"
    local hit = ui.row(items)
    if hit == "bldfill" then
        placeUi.run("chosen")
    elseif hit == "bldfillall" then
        placeUi.run("all")
    end
    text("spots on another road, on a building or on an object, and ground too steep, are skipped", ui.grey)
end

function placeUi.groupSpot(hit, e)
    local yaw  = math.rad(placeUi.turn)
    local c, s = math.cos(yaw), math.sin(yaw)
    local out  = {at = {x = hit.x, y = hit.y}, yaw = yaw, members = {}, base = math.huge}
    for _, m in ipairs(e.group) do
        local wx, wy = hit.x + m.x * c - m.y * s, hit.y + m.x * s + m.y * c
        local my     = yaw + m.r
        local polys  = town.outline(m.shape, {x = wx, y = wy}, my)
        local base   = town.standOn(polys, hit.z + m.z)
        out.members[#out.members + 1] = {t = m.t, x = wx, y = wy, yaw = my, base = base, polys = polys, shape = m.shape}
        out.base                      = math.min(out.base, base)
    end
    return out
end

function placeUi.putGroup(g, e)
    if e.rec then
        local name, err = exchange.importDae(e.rec, vec3(g.at.x, g.at.y, g.base), g.yaw)
        placeUi.stop()
        statusText = name and tr("%s placed from its DAE, copied into this map", e.rec.name) or tostring(err)
        if name then dirty() end
        return
    end
    local made, lost, homes = {}, {}, {}
    for _, m in ipairs(g.members) do
        local ds, miss = building.instantiate(m.t, vec3(m.x, m.y, m.base), {yaw = m.yaw, base = m.base, frame = true})
        if ds then
            building.placeBatch(ds)
            homes[#homes + 1] = ds[1].id
            for _, d in ipairs(ds) do made[#made + 1] = d end
            for _, n in ipairs(miss or {}) do lost[n] = true end
        end
    end
    building.commitBatch(made)
    placeUi.stop()
    if #made == 0 then
        statusText = "could not create the MeshRoad"
        return
    end
    dirty()
    local ids = {}
    for _, d in ipairs(made) do ids[#ids + 1] = d.id end
    buildingUi.pin(homes[1])
    editor.selectObjects(ids)
    tabUi.active = "buildings"
    local names  = {}
    for n in pairs(lost) do names[#names + 1] = n end
    table.sort(names)
    statusText = tr("%d buildings imported (one undo step)", #homes)
    if #names > 0 then statusText = statusText .. ". " .. tr("not in this map: %s", table.concat(names, ", ")) end
end

function placeUi.short(st)
    local d = st.desc
    return st.name or tr("%d floors, %s x %s m", d.floors or 1, string.format("%g", d.len or 0), string.format("%g", d.wid or 0))
end

function placeUi.full(st)
    local d, lines = st.desc, {}
    if st.name then lines[#lines + 1] = st.name end
    lines[#lines + 1] = tr("%d floors, %s x %s m", d.floors or 1, string.format("%g", d.len or 0), string.format("%g", d.wid or 0))
    lines[#lines + 1] = d.roof and lookup(placeUi.roofLabel[d.roof] or "two slopes") or lookup("flat roof")
    if d.wall then lines[#lines + 1] = tr("walls: %s", d.wall) end
    if d.mods and #d.mods > 0 then
        local m = {}
        for _, k in ipairs(d.mods) do m[#m + 1] = lookup(buildingUi.labelOf(k)) end
        lines[#lines + 1] = table.concat(m, ", ")
    end
    if (d.units or 0) > 0 then lines[#lines + 1] = tr("%d attached units", d.units) end
    if #st.at > 1 then lines[#lines + 1] = tr("%d copies in this export", #st.at) end
    return table.concat(lines, "\n")
end

placeUi.roofLabel = {gable = "two slopes", hip = "four slopes", shed_left = "one slope, high on the left", shed_right = "one slope, high on the right"}
placeUi.roofIcon  = {gable = iconOf.roofGable, hip = iconOf.roofHip, shed_left = iconOf.roofShedL, shed_right = iconOf.roofShedR}

function placeUi.membersOf(st, all)
    local out, shape = {}, town.shapeOf(st.t)
    if not shape then return out end
    for k, a in ipairs(st.at) do
        if all or k == 1 then out[#out + 1] = {t = st.t, shape = shape, x = all and a.x or 0.0, y = all and a.y or 0.0, z = all and a.z or 0.0, r = all and a.r or 0.0} end
    end
    return out
end

function placeUi.arrange(units)
    local out, cursor = {}, 0.0
    for _, u in ipairs(units) do
        local lo, hi = math.huge, -math.huge
        for _, m in ipairs(u) do
            for _, poly in ipairs(town.outline(m.shape, {x = m.x, y = m.y}, m.r)) do
                for _, q in ipairs(poly) do lo, hi = math.min(lo, q[1]), math.max(hi, q[1]) end
            end
        end
        local shift = cursor - lo
        for _, m in ipairs(u) do
            out[#out + 1] = {t = m.t, shape = m.shape, x = m.x + shift, y = m.y, z = m.z, r = m.r}
        end
        cursor = hi + shift + placeUi.xs.space
    end
    local mid = 0.0
    for _, m in ipairs(out) do mid = mid + m.x / #out end
    for _, m in ipairs(out) do m.x = m.x - mid end
    return out
end

function placeUi.chosen()
    local units = {}
    for _, rec in ipairs(exchange.exports()) do
        local pk = placeUi.xs.pick[rec.file]
        if pk then
            if pk.all then
                local u = {}
                for _, st in ipairs(rec.buildings) do
                    for _, m in ipairs(placeUi.membersOf(st, true)) do u[#u + 1] = m end
                end
                units[#units + 1] = u
            else
                for j, st in ipairs(rec.buildings) do
                    if pk.rows[j] then units[#units + 1] = placeUi.membersOf(st, false) end
                end
            end
        end
    end
    return placeUi.arrange(units)
end

function placeUi.startGroup(members, rec)
    if #members == 0 then
        statusText = "choose buildings to import first"
        return
    end
    buildingUi.pickMode(false)
    placeUi.mode  = "import"
    placeUi.turn  = 0
    placeUi.entry = {group = members, rec = rec, shape = {front = math.pi / 2.0, hi = 0.0, polys = {}}}
    if not placeUi.placing() then
        placeUi.was = editor.editMode
        editor.selectEditMode(editor.editModes.magePlace)
    end
    tabUi.active = "place"
    statusText   = "click in the world to place the buildings"
end

function placeUi.homesFor(scope)
    if scope == "one" then
        local h = buildingUi.current and building.dataOf(buildingUi.current) and building.homeOf(buildingUi.current)
        return h and {h} or {}
    end
    if scope == "selected" then
        local ids = {}
        for _, id in ipairs(getSelection()) do ids[#ids + 1] = buildingUi.staticOf(id) or id end
        return exchange.homesOf(ids)
    end
    local out = {}
    for _, b in ipairs(building.buildings()) do out[#out + 1] = b.id end
    return out
end

function placeUi.labelFor(scope, homes)
    if scope == "one" then
        local n = homes[1] and objName(homes[1]) or ""
        return (n ~= "") and n or "building"
    end
    return (scope == "selected") and "selected" or "all"
end

function placeUi.doExport(dae)
    local xs    = placeUi.xs
    local homes = placeUi.homesFor(xs.scope)
    if #homes == 0 then
        statusText = (xs.scope == "one") and "choose a building first" or (xs.scope == "selected") and "select buildings in the scene first" or "no buildings in this map"
        return
    end
    local typed = bufRead(xs.buf):gsub("^%s+", ""):gsub("%s+$", "")
    local name  = (typed ~= "") and typed:gsub("[^%w_%-]", "_") or exchange.autoName(placeUi.labelFor(xs.scope, homes))
    local file, res
    if dae then file, res = exchange.exportDae(name, homes) else file, res = exchange.exportSkeleton(name, homes) end
    if not file then
        statusText = tostring(res)
        return
    end
    bufWrite(xs.buf, "")
    statusText = tr("%d buildings exported to %s", #homes, file)
end

function placeUi.drawExport()
    local xs    = placeUi.xs
    local scope = ui.segment("bldxscope", {{key = "one", label = lookup("the building in the tab")}, {key = "selected", label = lookup("selected in the scene")},
                                             {key = "all", label = lookup("all buildings")}}, xs.scope)
    if scope then xs.scope = scope end
    local homes = placeUi.homesFor(xs.scope)
    local field = {w = consts.dimFieldW * 2, draw = function()
        imgui.PushItemWidth(consts.dimFieldW * 2)
        imgui.InputText("##bldxname", xs.buf, 64)
        imgui.PopItemWidth()
    end}
    local items  = {ui.act("bldxbones", iconOf.exportBones, "export the skeleton"), ui.act("bldxdae", iconOf.exportDae, "export as a DAE"), field}
    items[1].tip = "the MeshRoads with all their settings, to build them with MaGE in another map"
    items[2].tip = "one DAE with everything baked in (windows and doors too), its materials and a prefab that places it: for any map, without MaGE. the skeleton is saved with it"
    local hit = ui.row(items)
    if hit == "bldxbones" then
        placeUi.doExport(false)
    elseif hit == "bldxdae" then
        placeUi.doExport(true)
    end
    if bufRead(xs.buf) == "" and #homes > 0 then text(tr("empty name: %s", exchange.autoName(placeUi.labelFor(xs.scope, homes))), ui.grey) end
    text(tr("%d buildings to export", #homes), ui.grey)
end

function placeUi.drawImport()
    local xs, list = placeUi.xs, exchange.exports()
    if #list == 0 then text("no exports yet", ui.grey) end
    for i, rec in ipairs(list) do
        local pk   = xs.pick[rec.file] or {rows = {}}
        local open = xs.open[rec.file]
        local n    = 0
        for _, st in ipairs(rec.buildings) do n = n + #st.at end
        local all   = imgui.BoolPtr(pk.all == true)
        local items = {ui.iconItem("bldxopen_" .. i, open and iconOf.opened or iconOf.closed, open and "-" or "+", nil, 18),
                       ui.markItem("bldxall_" .. i, tr("%s (%d buildings)", rec.name, n), all)}
        items[2].tip = "all of it, as it was laid out"
        if rec.dae then
            items[3]     = ui.act("bldxdaeput_" .. i, iconOf.importPlace, "place its DAE")
            items[3].tip = "the baked DAE of the whole export: copied into this map and placed with the mouse"
        end
        local hit = ui.row(items)
        if hit == "bldxopen_" .. i then
            xs.open[rec.file] = not open
        elseif hit == "bldxall_" .. i then
            pk.all            = all[0]
            xs.pick[rec.file] = pk
        elseif hit == "bldxdaeput_" .. i then
            local u = {}
            for _, st in ipairs(rec.buildings) do
                for _, m in ipairs(placeUi.membersOf(st, true)) do u[#u + 1] = m end
            end
            placeUi.startGroup(u, rec)
        end
        if xs.open[rec.file] then
            for j, st in ipairs(rec.buildings) do
                local ptr  = imgui.BoolPtr(pk.all == true or pk.rows[j] == true)
                local mark = ui.markItem("bldxrow_" .. i .. "_" .. j, placeUi.short(st), ptr)
                local draw = mark.draw
                mark.draw  = function()
                    local r = draw()
                    if imgui.IsItemHovered() then xs.hover = st end
                    return r
                end
                mark.tip  = placeUi.full(st)
                local row = {mark}
                if st.desc.roof and placeUi.roofIcon[st.desc.roof] then row[#row + 1] = ui.iconItem("bldxroof_" .. i .. "_" .. j, placeUi.roofIcon[st.desc.roof], lookup(placeUi.roofLabel[st.desc.roof]), ui.grey, 18) end
                for _, k in ipairs(st.desc.mods or {}) do
                    if iconOf.mods[k] then row[#row + 1] = ui.iconItem("bldxmod_" .. i .. "_" .. j .. "_" .. k, iconOf.mods[k], lookup(buildingUi.labelOf(k)), ui.grey, 18) end
                end
                if #st.at > 1 then row[#row + 1] = ui.textItem("x" .. #st.at, ui.grey) end
                row[#row + 1] = ui.act("bldxsave_" .. i .. "_" .. j, iconOf.toSaved, "add to the saved buildings")
                local h = ui.row(row)
                if h == "bldxrow_" .. i .. "_" .. j and not pk.all then
                    pk.rows[j]        = ptr[0] or nil
                    xs.pick[rec.file] = pk
                elseif h == "bldxsave_" .. i .. "_" .. j then
                    placeUi.toSaved(st)
                end
            end
        end
    end
    if ui.row({ui.act("bldxplace", iconOf.importPlace, "place the chosen buildings")}) then placeUi.startGroup(placeUi.chosen()) end
    text(tr("the exports are in your user folder: %s", exchange.root), ui.grey)
end

function placeUi.toSaved(st)
    local base    = placeUi.short(st)
    local lib     = building.saved()
    local name, k = base, 1
    while lib.items[name] do
        k    = k + 1
        name = base .. " " .. k
    end
    if building.editSaved(function(d) d.items[name] = st.t end) then
        statusText = tr("building %s saved", name)
    else
        statusText = "could not write the saved buildings file"
    end
end

function placeUi.drawHover()
    local st = placeUi.xs.hover
    if not st then return end
    local fwd = core_camera.getForward()
    local pos = core_camera.getPosition()
    local d   = castRayStatic(pos, vec3(fwd.x, fwd.y, fwd.z), placeUi.far)
    if not d or d >= placeUi.far then return end
    local hit = pos + vec3(fwd.x, fwd.y, fwd.z) * d
    local e   = {group = placeUi.membersOf(st, false)}
    if #e.group == 0 then return end
    placeUi.drawGhost(placeUi.groupSpot(hit, e), e)
end

function placeUi.draw()
    placeUi.drawTop()
    if section("saved buildings", true) then buildingUi.drawSaved(building.saved(), buildingUi.current) end
    if section("along roads", true) then
        local o = placeUi.opts()
        placeUi.drawRoadList()
        placeUi.drawOptions(o)
        placeUi.drawRun()
    end
    if section("export and import", true) then
        placeUi.drawExport()
        placeUi.drawImport()
    end
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
    if ok then preview.clearPreview(true) end
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
                statusText = buildingUi.render() or ""
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

local function drawStatus(built)
    local log = ui.log
    if statusText ~= "" and statusText ~= log.last then
        table.insert(log, 1, statusText)
        log[ui.logMax + 1], log.last = nil, statusText
    end
    local title = lookup("log") .. ((statusText ~= "") and ("  -  " .. lookup(statusText)) or "")
    imgui.SetNextItemOpen(false, imgui.Cond_FirstUseEver)
    if not imgui.CollapsingHeader1(visual(title) .. "###magelog") then return end
    if preview.renderedCount() > 0 then
        if preview.isLive() then
            textv(tr("auto: %d of %d rendered", preview.renderedCount(), preview.liveMaxRoads()),
                  imgui.ImVec4(0.4, 1, 0.4, 1))
        end
        text("preview only - it is not saved with the map.", imgui.ImVec4(0.5, 0.5, 0.5, 1))
    end
    for i, line in ipairs(log) do
        text(line, (i == 1) and imgui.ImVec4(0.4, 1, 0.4, 1) or ui.grey)
    end
    if #built > 0 then drawBuiltSources(built) end
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

function tabUi.wallPrefix()
    return geometry.mr.daePrefix .. "c"
end

function tabUi.endsKey(ids)
    local parts = {}
    for _, id in ipairs(ids) do
        local o = scenetree.findObjectById(id)
        local n = o and o:getNodeCount() or 0
        if n > 0 then
            local a, b = o:getNodePosition(0), o:getNodePosition(n - 1)
            parts[#parts + 1] = string.format("%d:%.2f,%.2f,%.2f,%.2f", id, a.x, a.y, b.x, b.y)
        end
    end
    return table.concat(parts, ";")
end

function tabUi.wallOf(picked)
    local key  = table.concat(picked, ",")
    local c    = tabUi.wallCache
    local ends = tabUi.endsKey(c and c.key == key and c.members or picked)
    if c and c.key == key and c.ends == ends then return c end
    local mine, members, seen, chains = {}, {}, {}, 0
    local function add(id)
        if seen[id] then return end
        seen[id]              = true
        members[#members + 1] = id
    end
    for _, id in ipairs(picked) do
        mine[id] = true
        add(id)
    end
    local near = preview.chainOf(picked, findUnskinned("MeshRoad"))
    for _, p in ipairs(preview.collectUnits(near).paths) do
        local hit = false
        for _, sid in ipairs(p.srcIds or {}) do
            if mine[sid] then hit = true end
        end
        if hit and p.chain then
            chains = chains + 1
            for _, sid in ipairs(p.srcIds) do add(sid) end
        end
    end
    c               = {key = key, members = members, chains = chains}
    c.ends          = tabUi.endsKey(members)
    tabUi.wallCache = c
    return c
end

function tabUi.membersOf(name)
    local hit = tabUi.objCache[name]
    if hit then return hit end
    local all      = findUnskinned("MeshRoad")
    local ids      = exporter.sourcesOfCells(all, {[name:sub(#geometry.mr.daePrefix + 1)] = true})
    tabUi.objCache = {[name] = ids}
    return ids
end

function tabUi.drawWallBar(wall)
    textv(tr("part of a wall of %d MeshRoads", #wall.members), ui.blue)
    local on    = tabUi.sync
    local items = {ui.act("wallrender", iconOf.render, "render the wall"),
                   ui.iconItem("wallsync", on and iconOf.link or iconOf.unlink, lookup("change the whole wall together"), nil, ui.icon, on and ui.pick or nil)}
    items[1].tip = "renders every MeshRoad of this wall again with auto refresh"
    items[2].tip = tr("%s: %s - click for %s", lookup("change the whole wall together"), lookup(on and "on" or "off"), lookup(on and "off" or "on"))
                   .. "\n" .. lookup("textures, tags and models go to every MeshRoad of the wall, so it stays one wall. off: only the selected MeshRoads change")
    local hit = ui.row(items)
    if hit == "wallsync" then
        tabUi.sync = not on
    elseif hit == "wallrender" then
        statusText = buildingUi.showRoads(wall.members) or ""
    end
end

function tabUi.walls(fresh)
    local L = tabUi.wallList
    if L and not fresh then return L end
    local roads = {}
    for _, id in ipairs(findUnskinned("MeshRoad")) do
        if not buildingUi.isOn(id) then roads[#roads + 1] = id end
    end
    local opts, byValue = {}, {}
    for _, p in ipairs(preview.collectUnits(roads).paths) do
        local ids  = p.srcIds or {p.id}
        local name = objName(ids[1])
        name       = (name ~= "") and name or tostring(ids[1])
        local o    = {value = p.id, ids = ids, chain = p.chain, group = lookup("walls"),
                      label = (#ids > 1) and tr("%s - %d MeshRoads", name, #ids) or name}
        opts[#opts + 1] = o
        byValue[p.id]   = o
    end
    local pre, ra = geometry.mr.daePrefix, consts.raPrefix
    for _, nm in ipairs(scenetree.findClassObjects("TSStatic") or {}) do
        local own = nm:sub(1, #pre) == pre and not nm:find("^[bc]", #pre + 1)
        if own or nm:sub(1, #ra) == ra then opts[#opts + 1] = {value = nm, label = nm, group = lookup("objects")} end
    end
    L              = {opts = opts, byValue = byValue}
    tabUi.wallList = L
    return L
end

function tabUi.drawWallPicker(picked)
    local T        = windowUi.tex
    local open     = (T.shown.wallpick or T.fresh.wallpick) and true or false
    local L        = open and tabUi.walls(not tabUi.wallOpen) or {opts = {}, byValue = {}}
    tabUi.wallOpen = open
    local cur      = nil
    local mine     = {}
    for _, id in ipairs(picked) do mine[id] = true end
    for _, o in ipairs(L.opts) do
        if o.ids and mine[o.ids[1]] then cur = o.value end
    end
    local name       = picked[1] and objName(picked[1]) or ""
    local shown      = (name ~= "") and name or (picked[1] and tostring(picked[1])) or lookup("choose a wall or an object")
    local hit, value = windowUi.picker("wallpick", lookup("wall"), cur, L.opts, shown)
    if not (hit and value) then return end
    local o = L.byValue[value]
    if o then
        local obj = o.chain and scenetree.findObject(geometry.mr.daePrefix .. geometry.mr.chainCell(o.chain))
        editor.selectObjects(obj and {obj:getID()} or o.ids)
        tabUi.wallObj = obj and obj:getID() or nil
        buildingUi.showRoads(o.ids)
        statusText = tr("%s shown", o.label)
        return
    end
    local obj = scenetree.findObject(value)
    if obj then editor.selectObjects({obj:getID()}) end
    statusText = tr("%s shown", value)
end

tabUi.shapeLabels = {circle = "circle", ellipse = "ellipse", rectangle = "rectangle", polygon = "polygon"}
tabUi.shapeFields = {radius = "radius (centre to wall)", sizeX = "length", sizeY = "width", sides = "number of sides",
                     arc = "how much of the shape (degrees, 360 = all of it)", turn = "turn (degrees)", width = "wall thickness", height = "wall height"}

function tabUi.drawShape()
    if not section("a new wall from a shape", false) then return end
    local sh = tabUi.shapes
    local o  = tabUi.shape
    if not o then
        o = {}
        for k, v in pairs(sh.defaults) do o[k] = v end
        tabUi.shape = o
    end
    local opts = {}
    for _, k in ipairs(sh.order) do opts[#opts + 1] = {key = k, label = tabUi.shapeLabels[k], icon = iconOf.shape[k]} end
    local kind = ui.cycle("shapekind", "shape", opts, o.kind)
    if kind then o.kind = kind end
    if ui.beginProps("shapeprops") then
        local keys = {}
        for _, k in ipairs(sh.fieldsOf[o.kind]) do keys[#keys + 1] = k end
        for _, k in ipairs({"arc", "turn", "width", "height"}) do keys[#keys + 1] = k end
        for _, key in ipairs(keys) do
            ui.prop(lookup(tabUi.shapeFields[key]))
            local lim = sh.limits[key]
            local v   = ui.number("shape" .. key, "shape" .. key .. "_dec", "shape" .. key .. "_inc", o[key], lim[1], lim[2], sh.defaults[key])
            if v then o[key] = (key == "sides") and math.floor(v + 0.5) or v end
        end
        ui.endProps()
    end
    if ui.row({ui.act("shapecreate", iconOf.newShape, "create the wall under the camera", ui.add)}) then
        local dyn = {[fieldOf.ends] = "on", [fieldOf.bottom] = "on"}
        local ids = sh.create(buildingUi.cameraSpot(), o, dyn)
        editor.selectObjects(ids)
        dirty()
        statusText = tr("%s created: %d MeshRoads", lookup(tabUi.shapeLabels[o.kind]), #ids)
    end
    tip("a shape with corners is made of one MeshRoad per side, joined end to end into one wall with sharp corners")
end

function tabUi.keepPick()
    local sel      = getSelection()
    local src, cls = preview.pickSources(sel)
    if src then
        enterEditMode((cls == "MeshRoad" and "meshRoadEditMode") or (cls == "DecalRoad" and "roadEditMode") or nil)
        ui.keep = {ids = src, frames = 10}
    end
    local p = ui.keep
    if p then
        sel        = getSelection()
        local same = #sel == #p.ids
        for i = 1, #p.ids do
            if sel[i] ~= p.ids[i] then same = false end
        end
        if not same then editor.selectObjects(p.ids) end
        p.frames = p.frames - 1
        if p.peek and p.frames <= 8 then
            for _, id in ipairs(p.ids) do preview.peekSource(id, false) end
            p.peek = nil
        end
        if p.frames <= 0 then ui.keep = nil end
    end
end

function tabUi.watch()
    local sel  = getSelection()
    local root = (#sel == 1) and buildingUi.staticOf(sel[1]) or nil
    if root and sel[1] ~= buildingUi.picked then
        tabUi.active = "buildings"
        local cur    = buildingUi.current and building.homeOf(buildingUi.current)
        if cur ~= root then buildingUi.current, buildingUi.sel = root, {} end
    end
    buildingUi.picked = root and sel[1] or nil

    local pre  = tabUi.wallPrefix()
    local wobj = (#sel == 1 and classOf(sel[1]) == "TSStatic" and objName(sel[1]):sub(1, #pre) == pre) and sel[1] or nil
    if wobj and wobj ~= tabUi.wallObj then tabUi.active = "meshes" end
    tabUi.wallObj = wobj

    local v = buildingUi.view
    if not v or table.concat(sel, ",") == v.sel then return end
    v.sel      = table.concat(sel, ",")
    local mine = {}
    for _, f in ipairs(building.group(v.root)) do mine[f] = true end
    for _, id in ipairs(sel) do
        if not mine[id] and buildingUi.staticOf(id) ~= v.root and not preview.pickSources({id}) and classOf(id) ~= "TerrainBlock" then
            buildingUi.view = nil
            if preview.renderedCount() > 0 then preview.clearPreview() end
            return
        end
    end
end

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

function tabUi.drawOver(ids)
    local cur, state = selectionValue(ids, fieldOf.over)
    local opts       = {
        {key = "ground",  label = lookup("ground"),      tip = lookup("the sidewalk follows the terrain under it")},
        {key = "on",      label = lookup("node height"), tip = lookup("the sidewalk keeps the height of the road's nodes")},
        {key = "surface", label = lookup("surface"),     tip = lookup("the sidewalk sits on the first surface under the nodes, like the DecalRoad's own 'over objects'. what most of its width sits on wins, so a railing at its edge is ignored")},
    }
    local key = nil
    if state ~= "mixed" then key = (cur == "on" or cur == "surface") and cur or "ground" end
    text("sidewalk height", ui.grey)
    local hit = ui.segment("decalover", opts, key)
    if state == "mixed" then text("only on part of what is marked. a choice sets it for all of it", ui.orange) end
    if hit and hit ~= key then applyValue(fieldOf.over, hit == "ground" and "" or hit, ids) end
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
        tabUi.drawOver(decalIds)
        presetUi.drawCopy(decalIds)
        tabUi.drawCurbSizes(decalIds)
        for _, ax in ipairs(consts.decalAxes) do
            local tex = ax == "walk" or ax == "curb"
            if drawAxis(ax, decalIds, tex and function() windowUi.texMine(ax, decalIds) end) and tex then windowUi.texMore(ax, decalIds) end
        end
    end
end

tabUi.curbFields = {
    {key = "height", label = "sidewalk height"},
    {key = "strip", label = "curb width"},
    {key = "angle", label = "slope of the curb edge (degrees)"},
    {key = "exposed", label = "height of the sloped part"},
    {key = "corner", label = "corner radius of an island"},
    {key = "tip", label = "width of a rounded end's tip"},
}

function tabUi.drawCurbSizes(ids)
    if not section("curb sizes", false) then return end
    local first  = geometry.curbDimsOf(dynValue(ids[1], fieldOf.curbdims)) or {}
    local differ = false
    for i = 2, #ids do
        if (dynValue(ids[i], fieldOf.curbdims) or "") ~= (dynValue(ids[1], fieldOf.curbdims) or "") then differ = true end
    end
    if differ then text("values differ between the selected roads - showing the first", ui.orange) end
    local prof = geometry.profileOf(dynValue(ids[1], fieldOf.profile) or "walk", "walk")
    local defs = {height = geometry.settings.height, strip = geometry.settings.curbStrip, angle = prof.angle, exposed = prof.exposed,
                  corner = geometry.settings.island.cornerRadius, tip = geometry.settings.roundEnd.tipWidth}
    if ui.beginProps("curbsizes") then
        for _, f in ipairs(tabUi.curbFields) do
            local lim = geometry.curbLimits[f.key]
            ui.prop(lookup(f.label))
            local v = ui.number("curb" .. f.key, "curb" .. f.key .. "dec", "curb" .. f.key .. "inc", first[f.key] or defs[f.key], lim[1], lim[2], defs[f.key])
            if v then
                transaction("MageCurbSizes", function()
                    for _, id in ipairs(ids) do
                        local d  = geometry.curbDimsOf(dynValue(id, fieldOf.curbdims)) or {}
                        d[f.key] = v
                        writeField(id, fieldOf.curbdims, jsonEncode(d))
                    end
                end)
                statusText = tr("%s set to %s on %d roads", lookup(f.label), string.format("%g", v), #ids)
            end
        end
        ui.endProps()
    end
    if ui.row({ui.act("curbreset", iconOf.restore, "reset to defaults")}) then
        transaction("MageCurbSizes", function()
            for _, id in ipairs(ids) do writeField(id, fieldOf.curbdims, "") end
        end)
        ui.edit    = {}
        statusText = tr("%s reset on %d roads", lookup("curb sizes"), #ids)
    end
    tip("these sizes are stored on the road itself - other roads keep their own")
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
    tabUi.drawShape()
    local picked, fromObj = {}, false
    for _, id in ipairs(sel.meshIds) do picked[#picked + 1] = id end
    local pre = tabUi.wallPrefix()
    for _, n in ipairs(sel.built) do
        if n:sub(1, #pre) == pre then
            fromObj = true
            for _, id in ipairs(tabUi.membersOf(n)) do picked[#picked + 1] = id end
        end
    end
    tabUi.drawWallPicker(picked)
    if #picked == 0 then
        text("select MeshRoads with the warning material in the SceneTree to give them walls, a top surface, bridges, battlements and gates", ui.grey)
        return
    end
    local wall    = tabUi.wallOf(picked)
    local meshIds = (tabUi.sync and wall.chains > 0) and wall.members or picked
    tabUi.drawMeshList(meshIds)
    if wall.chains > 0 then tabUi.drawWallBar(wall) end
    if #meshIds == 1 and buildingUi.isOn(meshIds[1]) then
        text("this MeshRoad is a floor of a building - its floors, windows and doors are in the buildings tab", ui.grey)
    end
    presetUi.drawCopy(meshIds)

    local slots = {}
    for _, ax in ipairs(consts.mrAxes) do
        if consts.flagIcons[ax] and palette[ax] and fieldOf[ax] then slots[#slots + 1] = flagSlot(ax, meshIds) end
    end
    if #geometry.features > 0 then slots[#slots + 1] = featureSlot(meshIds) end
    drawSlots(slots)

    if ui.beginProps("meshlook") then
        windowUi.pickLook("lookwall", meshIds, "wall", "walls", "the config's wall", "wall")
        windowUi.pickLook("lookwalk", meshIds, "walk", "top surface", "the config's top surface", "walk")
        ui.endProps()
    end
    for _, ax in ipairs(consts.mrAxes) do
        if not consts.flagIcons[ax] and ax ~= "wall" then drawAxis(ax, meshIds) end
    end
    drawAxis("profile", meshIds)

    local cur = selectionFeature(meshIds)
    if cur ~= "none" and cur ~= "mixed" then drawFeaturePanel(meshIds, cur) end
    gateUi.drawGates(fromObj and {} or picked)
    windowUi.drawOpenings(picked, meshIds, wall.chains == 1 and tabUi.sync)
    priorityUi.drawPriority(meshIds)
end

function tabUi.drawBuildingTab(sel)
    if not palette then return tabUi.drawNoConfig() end
    local meshIds = sel.meshIds
    local one     = (#meshIds == 1) and meshIds[1] or nil
    local loose   = nil
    if one and building.dataOf(one) then
        if one ~= buildingUi.current then buildingUi.pin(one) end
    elseif one then
        loose = one
    end
    if buildingUi.current and not scenetree.findObjectById(buildingUi.current) then buildingUi.current = nil end
    local id = loose or buildingUi.current
    buildingUi.drawTop(id)
    buildingUi.drawPicker(buildingUi.current)
    if not id then
        text("no building chosen: choose one from the list, select a floor of a building (a MeshRoad) in the SceneTree, or create a new building in the place buildings tab", ui.grey)
        return
    end
    if not buildingUi.isOn(id) then
        text("a MeshRoad becomes a building with floors, windows and doors once it is defined as a building", ui.grey)
        return
    end
    buildingUi.draw(id)
end

function tabUi.drawPlaceTab()
    if not palette then return tabUi.drawNoConfig() end
    placeUi.draw()
end

function tabUi.drawCoverageTab()
    if not palette then return tabUi.drawNoConfig() end
    drawCoverage()
end

function tabUi.drawImportTab()
    drawRoadArchitect()
    drawArchitect()
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
    windowUi.drawConfigs()
end

tabUi.list = {
    {key = "sidewalks", label = "sidewalks", draw = tabUi.drawSidewalkTab},
    {key = "meshes",    label = "MeshRoads", draw = tabUi.drawMeshTab},
    {key = "buildings", label = "buildings", draw = tabUi.drawBuildingTab},
    {key = "place",     label = "place buildings", draw = tabUi.drawPlaceTab},
    {key = "coverage",  label = "coverage",  draw = tabUi.drawCoverageTab},
    {key = "import",    label = "import",    draw = tabUi.drawImportTab},
    {key = "settings",  label = "settings",  draw = tabUi.drawSettingsTab},
}

function tabUi.drawTabs(sel)
    buildingUi.open = tabUi.active == "buildings"
    local items = {}
    for _, t in ipairs(tabUi.list) do
        local on          = t.key == tabUi.active
        items[#items + 1] = ui.iconItem("tab_" .. t.key, iconOf[t.key], lookup(t.label), on and ui.white or ui.grey, ui.icon, on and ui.pick or nil)
    end
    local hit = ui.row(items)
    if hit then tabUi.active = hit:sub(5) end
    imgui.Separator()
    for _, t in ipairs(tabUi.list) do
        if t.key == tabUi.active then
            imgui.BeginChild1("magebody_" .. t.key, imgui.ImVec2(0, 0), true)
            ui.main = true
            t.draw(sel)
            imgui.EndChild()
        end
    end
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
    matUi.texBudget = 0
    rtlLayout = layout.rtlConfig or isRtlText(lookup("sidewalks"))
    batFix.attach()
    buildArch.scanStep()
    windowUi.tex.frame = windowUi.tex.frame + 1
    ui.frame           = ui.frame + 1
    if windowUi.tex.redraw then
        windowUi.tex.redraw = false
        preview.rerender()
    end
    roadArch.install()
    preview.refreshLive()
    tabUi.keepPick()
    building.sync()
    tabUi.watch()
    buildingUi.pushFrame()
    buildingUi.pickFrame()
    buildingUi.syncGone()
    placeUi.frame()
    ensureRegistered()
    if not editor.isWindowVisible(toolWindowName) then return end

    if editor.beginWindow(toolWindowName, rtl("MaGE - Map Geometry Engine")) then
        ui.pushTheme()
        tabUi.drawTools()
        local sel = tabUi.selectionInfo()
        drawStatus(sel.built)
        if #sel.built == 0 then srcCache.key = nil end
        tabUi.drawTabs(sel)
        ui.popTheme()
    end
    editor.endWindow()
    sectionForce = nil
end

ensureRegistered = function()
    if registered then return end
    editor.editModes.magePick = {displayName = "MaGE building", onUpdate = function() buildingUi.pickUpdate() end, onActivate = function() end,
                                 onDeactivate = function() end, onDeleteSelection = function() buildingUi.removeWins() end,
                                 icon = findIcon(iconOf.pickWorld), iconTooltip = "MaGE building",
                                 auxShortcuts = {}, hideObjectIcons = true}
    editor.editModes.magePlace = {displayName = "MaGE placing", onUpdate = function() placeUi.update() end, onActivate = function() end,
                                  onDeactivate = function() placeUi.ghost = nil end, icon = findIcon(iconOf.place), iconTooltip = "MaGE placing",
                                  auxShortcuts = {}, hideObjectIcons = true}
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
    buildArch.repair()
    building.reset()
    buildingUi.current, buildingUi.view, buildingUi.picked = nil, nil, nil
    placeUi.roads, placeUi.job, placeUi.spawn, placeUi.mode = {}, nil, nil, nil
    placeUi.lines, placeUi.linesKey                         = nil, nil
    buildingUi.goneShells, buildingUi.goneKeys              = nil, nil
    visCache, srcCache                                     = {at = -1}, {key = nil}
    matUi.matSet, matUi.texCache, selectedMat              = nil, {}, nil
    preview.afterOpenLevel()
    exporter.emptyTrash()
    loadConfig()
    coverage   = nil
    statusText = ""
end

local function open()
    ensureRegistered()
    matUi.matClassCache = {}
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
