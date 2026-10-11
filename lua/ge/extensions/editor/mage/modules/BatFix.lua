-- =============================================================================
-- MaGE - Building Architect runtime fixes
-- Version: 1.0.0
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M      = {}
local logTag = 'mage'

-- =============================================================================
-- CONSTANTS
-- =============================================================================

local uiPath    = '/lua/ge/extensions/editor/gen/ui'
local worldPath = '/lua/ge/extensions/editor/gen/world'
local idWidgets = {'Checkbox', 'InputFloat', 'InputInt', 'SliderFloat', 'SliderInt'}

-- =============================================================================
-- STATE
-- =============================================================================

local im            = ui_imgui
local patched       = setmetatable({}, {__mode = 'k'})
local origRerequire = nil
local hookRerequire = nil

-- =============================================================================
-- UTILITIES
-- =============================================================================

local function pack(...)
    return select('#', ...), {...}
end

local function upvalueIndex(f, name)
    if type(f) ~= 'function' then return nil end
    for i = 1, 255 do
        local n = debug.getupvalue(f, i)
        if not n then return nil end
        if n == name then return i end
    end
    return nil
end

local function upvalue(f, name)
    local i = upvalueIndex(f, name)
    if not i then return nil end
    local _, v = debug.getupvalue(f, i)
    return v
end

-- =============================================================================
-- WINDOW
-- =============================================================================

local function wrapControl(control)
    return function(...)
        local api         = editor
        local origBegin   = api.beginWindow
        local origEnd     = api.endWindow
        local origIcon    = api.uiIconImageButton
        local origPush    = im.PushFont3
        local origPop     = im.PopFont
        local origWidgets = {}
        local windows     = 0
        local fonts       = 0
        local inner       = 0
        local seen        = {}

        local function scoped(f, keyOf)
            return function(...)
                local key = keyOf(...)
                local n   = (seen[key] or 0) + 1
                seen[key] = n
                im.PushID1('batFix_' .. key .. '_' .. n)
                local c, r = pack(f(...))
                im.PopID()
                return unpack(r, 1, c)
            end
        end
        local function labelKey(label) return tostring(label) end
        local function iconKey(icon, _, _, _, _, id) return tostring(icon) .. tostring(id) end

        api.beginWindow = function(...)
            inner      = inner + 1
            local n, r = pack(origBegin(...))
            inner      = inner - 1
            windows    = windows + 1
            return unpack(r, 1, n)
        end
        api.endWindow = function(...)
            inner      = inner + 1
            local n, r = pack(origEnd(...))
            inner      = inner - 1
            windows    = windows - 1
            return unpack(r, 1, n)
        end
        api.uiIconImageButton = scoped(origIcon, iconKey)
        im.PushFont3          = function(...)
            if inner == 0 then fonts = fonts + 1 end
            return origPush(...)
        end
        im.PopFont = function(...)
            if inner == 0 then fonts = fonts - 1 end
            return origPop(...)
        end
        for _, name in ipairs(idWidgets) do
            origWidgets[name] = im[name]
            im[name]          = scoped(im[name], labelKey)
        end

        local n, r = pack(xpcall(control, debug.traceback, ...))

        for _ = 1, fonts do origPop() end
        for _ = 1, windows do origEnd() end

        api.beginWindow       = origBegin
        api.endWindow         = origEnd
        api.uiIconImageButton = origIcon
        im.PushFont3          = origPush
        im.PopFont            = origPop
        for name, f in pairs(origWidgets) do im[name] = f end

        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
end

local function patchUi(UI)
    if type(UI.control) ~= 'function' then return end
    UI.control  = wrapControl(UI.control)
    patched[UI] = true
end

-- =============================================================================
-- DRAG
-- =============================================================================

local function stale(forDesc, forScope)
    if forScope() ~= 'building' then return false end
    local adesc = upvalue(forDesc, 'adesc')
    local cedit = upvalue(forDesc, 'cedit')
    return adesc ~= nil and cedit ~= nil and not cedit.forest and not adesc[cedit.mesh]
end

local function patchWorld(W)
    local onUpdate, forDesc, forScope = W.onUpdate, W.forDesc, W.forScope
    if type(onUpdate) ~= 'function' or type(forDesc) ~= 'function' or type(forScope) ~= 'function' then return end
    W.onUpdate = function(...)
        if not stale(forDesc, forScope) then return onUpdate(...) end
        local drag         = im.IsMouseDragging
        im.IsMouseDragging = function(button, ...)
            if button == 0 then return false end
            return drag(button, ...)
        end
        local n, r         = pack(xpcall(onUpdate, debug.traceback, ...))
        im.IsMouseDragging = drag
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
    patched[W] = true
end

-- =============================================================================
-- PATCHING
-- =============================================================================

local function apply(patch, mod)
    if type(mod) ~= 'table' or patched[mod] then return end
    local ok, err = pcall(patch, mod)
    if not ok then
        patched[mod] = true
        log('E', logTag, "Building Architect fix not applied: " .. tostring(err))
    end
end

local function installRerequire()
    if origRerequire or type(rerequire) ~= 'function' then return end
    origRerequire = rerequire
    hookRerequire = function(path, ...)
        local n, r = pack(origRerequire(path, ...))
        if path == uiPath then
            apply(patchUi, r[1])
        elseif path == worldPath then
            apply(patchWorld, r[1])
        end
        return unpack(r, 1, n)
    end
    rerequire = hookRerequire
end

local function attach()
    installRerequire()
    local be = rawget(_G, 'editor_buildingEditor')
    if type(be) ~= 'table' then return end
    apply(patchUi, upvalue(be.onEditorGui, 'UI'))
    apply(patchWorld, upvalue(be.onEditorGui, 'W'))
end

local function detach()
    if origRerequire and rerequire == hookRerequire then rerequire = origRerequire end
    origRerequire = nil
    hookRerequire = nil
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

M.attach = attach
M.detach = detach

return M
