-- =============================================================================
-- MaGE - geometry settings
-- Version: 1.0.1
-- License: AGPL-3.0 - https://www.gnu.org/licenses/agpl-3.0.html
-- =============================================================================

local M = {}

-- =============================================================================
-- GENERAL
-- =============================================================================

M.height    = 0.3
M.curbStrip = 0.15
M.zOffset   = 0.0
M.faceSign  = -1

M.smoothing = {
    segLen     = 0.75,
    maxTurnDeg = 4.0,
}

M.cr = {
    alpha   = 0.5,
    minSpan = 1e-9,
    dupEps  = 1e-6,
    dupFrac = 0.05,
}

M.roundEnd = {
    on          = true,
    maxTurnDeg  = 6.0,
    tipWidth    = 0.30,
    radiusScale = 1.0,
    maxWidth    = 5.0,
}

M.paths = {
    capTol         = 2.5,
    noJunctionCaps = true,
    minSpacing     = 0.02,
    loopTol        = 0.5,
}

-- =============================================================================
-- DECALS
-- =============================================================================

M.decal = {
    lift          = 0.10,
    joinTol       = 2.5,
    seamWeld      = 0.05,
    fanMinTurnDeg = 18.0,
    fanMaxReach   = 8.0,
}

M.fillet = {
    maxTrim       = 0.35,
    tangentProbe  = 1.2,
    minAdvance    = 0.4,
    maxTurnDeg    = 3.0,
    keepInside    = true,
    insideTol     = 0.005,
    innerBias     = 0.92,
    maxCornerDeg  = 115.0,
    maxWidthRatio = 1.6,
}

M.hairpin = {
    flushTips     = true,
    maxExtend     = 3.0,
    union         = true,
    unionMaxWidth = 1.3,
    notchRadius   = 0.35,
}

M.island = {
    build            = true,
    maxMarkerWidth   = 0.5,
    joinTol          = 0.5,
    minArea          = 0.5,
    miterMinCos      = 0.25,
    smoothing        = true,
    roundCorners     = true,
    cornerRadius     = 0.5,
    cornerMinTurnDeg = 30.0,
}

M.curbProfiles = {
    walk   = {angle = 15.0, exposed = 0.15},
    island = {angle = 34.6, exposed = 0.15},
    flat   = {angle = 0.0,  exposed = 0.0},
}

M.defaultAtlas = {
    bands     = 8, bandPx = 64,
    paintRows = {1.5, 35.0}, plainRows = {40.5, 60.0},
    paintOn   = "top", uScale = 5.89, originTop = true,
}

-- =============================================================================
-- BUILDING ARCHITECT
-- =============================================================================

M.buildingArchitect = {
    tile      = 1.0,
    backFaces = true,
}

-- =============================================================================
-- MESHROADS
-- =============================================================================

M.meshRoad = {
    untexturedOnly     = true,
    materialKeys       = {"topMaterial", "sideMaterial", "bottomMaterial"},
    smoothCorners      = true,
    segLen             = 0.75,
    depthStep          = 0.25,
    maxTurnDeg         = 2.0,
    minEdgeAdvanceFrac = 0.20,
    minRadiusMargin    = 1.5,
    relaxIters         = 400,
    sweptMinRatio      = 1.20,
    marginGrowth       = 1.12,
    relaxRounds        = 12,
    maxRelaxDisp       = 0.75,
    sharpCorners       = true,
    sharpRatio         = 1.0,
    sharpMaxGrowth     = 1.5,
    sharpMiterFit      = true,
    sharpFitHeadroom   = 0.95,
    sharpMaxHalfDeg    = 85.0,
    miterStrip         = true,
    miterStripFrac     = 0.5,
    forceMiterRings    = true,
    miterMatchDist     = 0.5,
    widthClamp         = true,
    widthLipschitz     = 0.35,
    minHalfWidth       = 0.35,
    widthClampHeadroom = 1.10,
    walkSplit          = true,
    walkSplitFoldDeg   = 10.0,
    walkSplitMax       = 6,
    roll               = true,
    endCaps            = true,
    miterComp          = true,
    miterLimit         = 3.0,
    foldGuard          = true,
    foldGuardEps       = 1e-4,
    simplify           = true,
    simplifyTol        = 0.02,
    simplifyMaxSpan    = 12.0,
    simplifyMaxTurnDeg = 1.5,
    uvxFromMedianDecal = false,
}

return M
