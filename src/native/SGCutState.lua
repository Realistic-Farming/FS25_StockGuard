-- =========================================================
-- FS25_StockGuard - CUT_STATE_VOLUME_V1, the cut's source portions (SG2-3b)
-- =========================================================
-- SG-2 :497-512 and :539-544: for each direct FSDensityMapUtil.cutFruitArea call, the
-- source of what that call harvested, by growth state and by Soil cell, so SG-3 can
-- read maturity from the actual pixels rather than a dominant state or a field average.
--
-- WHY PIXEL BY PIXEL, AND WHY BY OBSERVED TRANSITION. The decompile of cutFruitArea
-- (FSDensityMapUtil.lua:22-201) omits the accumulators it returns, so its per-state
-- counts cannot be read back out of the engine (SG-2 :503). This producer reads the
-- pixels itself, with the engine's own point reads (the pattern of
-- FSDensityMapUtil.getFruitTypeIndexAtWorldPos, :2849-2860): the fruit plane's density type index
-- names the fruit, getGrowthStateByDensityState decodes its state (FruitTypeDesc.lua
-- :794-799). It reads every pixel of the envelope's bounding box plus a margin BEFORE
-- the native call, reads the same pixels AFTER, and counts a pixel only if it made
-- this fruit's harvest transition: the observed set, so the engine's own rasterisation
-- of the parallelogram decides which pixels were cut, never a prediction of it.
--
-- ADMITTED ONLY ON THE NATIVE'S OWN TOTAL. The state weight is w_s = c_s x
-- yieldScale_s, where yieldScale_s is the descriptor's own yieldScales[s] entry read
-- at the pre-cut boundary (FruitTypeDesc.lua:224 writes one per harvest-ready state).
-- A source state with no entry refuses the call: the helper's `or 1` default
-- (FruitTypeDesc.lua:800-801) is never native evidence, and a mixed total that
-- happens to match is not its proof (SG-2 :495). The profile is admitted for the call
-- only when the sum of w_s over the transitioned pixels equals the scaled area the
-- native call returned; otherwise the call's output is one UNKNOWN portion with the
-- reason (:511). A harvest target that is itself harvestable could be recut in the
-- same call, so one-time eligibility cannot be proved and the call is unavailable too.
--
-- SOIL IS OPTIONAL. With SoilFertilizer present the pre-cut N, P, K and pH at each pixel
-- (SoilFertilityManager:getSoilValueAtWorld, which returns nil when unavailable) split
-- a state into Soil cells, keyed by Soil's own grain. Without it a state is one portion
-- with no Soil snapshot: StockGuard never depends on Soil being installed.

SGCutState = SGCutState or {}
local CS = SGCutState

CS.PROFILE = "CUT_STATE_VOLUME_V1"
CS.MARGIN_PIXELS = 1
CS.MAX_PIXELS = 4096          -- a cutter call's envelope is a thin strip; more is a refusal
CS.TOLERANCE = 1e-6
CS.SOIL_KEYS = { "nitrogen", "phosphorus", "potassium", "pH" }
CS.stats = CS.stats or { calls = 0, admitted = 0, refused = {} }
CS.logged = CS.logged or {}

-- THE IN-GAME EVIDENCE. Nothing a player sees reads these portions, and whether the
-- engine's real cuts agree with the pixels this producer reads is exactly what an
-- offline bench cannot prove. So the first admitted cut says so once, and each kind
-- of refusal says so once, with the two totals: the log line an in-game check reads.
local function logOnce(key, fmt, ...)
    if CS.logged[key] then return end
    CS.logged[key] = true
    print("[StockGuard] harvest: " .. string.format(fmt, ...))
end

local function refuse(reason, detail)
    CS.stats.refused[reason] = (CS.stats.refused[reason] or 0) + 1
    logOnce("refused:" .. reason, "CUT_STATE_VOLUME_V1 refused a cut (%s)%s; that cut's output is an UNKNOWN portion. Logged once per reason.",
        reason, detail or "")
    return { admitted = false, reason = reason, detail = detail }
end

--- The fruit plane's grid: the plane, its pixel size in metres and the terrain's half size.
local function grid()
    local ftm = g_fruitTypeManager
    if ftm == nil or type(ftm.getDefaultDataPlaneId) ~= "function" then return nil end
    local plane = ftm:getDefaultDataPlaneId()
    local mission = g_currentMission
    local terrainSize = mission ~= nil and tonumber(mission.terrainSize) or nil
    if plane == nil or terrainSize == nil or terrainSize <= 0 then return nil end
    local ok, size = pcall(getDensityMapSize, plane)
    if not ok or type(size) ~= "number" or size <= 0 then return nil end
    return { plane = plane, pixel = terrainSize / size, half = terrainSize * 0.5 }
end

--- The fruit and growth state at one world point, the engine's own way.
local function readPoint(g, x, z)
    local okT, typeIndex = pcall(getDensityTypeIndexAtWorldPos, g.plane, x, 0, z)
    if not okT then return nil, nil end
    local desc = g_fruitTypeManager:getFruitTypeByDensityTypeIndex(typeIndex)
    if desc == nil then return nil, nil end
    local okS, states = pcall(getDensityStatesAtWorldPos, g.plane, x, 0, z)
    if not okS then return desc.index, nil end
    return desc.index, desc:getGrowthStateByDensityState(states)
end

--- The Soil snapshot at a point, or nil with Soil absent or unavailable.
local function soilAt(x, z)
    local sfm = g_SoilFertilityManager
    if sfm == nil or type(sfm.getSoilValueAtWorld) ~= "function" then return nil, nil end
    local snapshot, grain = {}, nil
    for _, key in ipairs(CS.SOIL_KEYS) do
        local ok, v, g = pcall(sfm.getSoilValueAtWorld, sfm, key, x, z)
        if not ok or type(v) ~= "number" then return nil, nil end
        snapshot[key] = v
        if type(g) == "number" and g > 0 then grain = g end
    end
    return snapshot, grain
end

--- Before the native cut: every pixel centre of the envelope's bounding box plus a
--- margin, with its fruit, state and Soil snapshot. Returns the capture, or a refusal.
---@return table
function CS.before(fruitIndex, sx, sz, wx, wz, hx, hz, useMinForageState)
    CS.stats.calls = CS.stats.calls + 1
    local desc = g_fruitTypeManager ~= nil and g_fruitTypeManager:getFruitTypeByIndex(fruitIndex) or nil
    if desc == nil then return refuse("NO_FRUIT") end
    local g = grid()
    if g == nil then return refuse("NO_PLANE") end
    local minState = useMinForageState and desc.minForageGrowthState or desc.minHarvestingGrowthState
    local maxState = desc.maxHarvestingGrowthState
    local transitions = type(desc.harvestTransitions) == "table" and desc.harvestTransitions or {}
    local scaleTable = type(desc.yieldScales) == "table" and desc.yieldScales or {}
    -- A target that is itself a harvestable source could be cut twice in one call.
    for src, target in pairs(transitions) do
        if src >= minState and src <= maxState and target >= minState and target <= maxState and transitions[target] ~= nil then
            return refuse("RECUT_POSSIBLE")
        end
    end
    local x4, z4 = wx + hx - sx, wz + hz - sz
    local margin = CS.MARGIN_PIXELS * g.pixel
    local x0, x1 = math.min(sx, wx, hx, x4) - margin, math.max(sx, wx, hx, x4) + margin
    local z0, z1 = math.min(sz, wz, hz, z4) - margin, math.max(sz, wz, hz, z4) + margin
    local i0, i1 = math.floor((x0 + g.half) / g.pixel), math.floor((x1 + g.half) / g.pixel)
    local j0, j1 = math.floor((z0 + g.half) / g.pixel), math.floor((z1 + g.half) / g.pixel)
    if (i1 - i0 + 1) * (j1 - j0 + 1) > CS.MAX_PIXELS then return refuse("ENVELOPE_TOO_LARGE") end
    local pixels, scales = {}, {}
    for i = i0, i1 do
        for j = j0, j1 do
            local cx, cz = -g.half + (i + 0.5) * g.pixel, -g.half + (j + 0.5) * g.pixel
            local fruit, state = readPoint(g, cx, cz)
            if fruit == fruitIndex and state ~= nil and state >= minState and state <= maxState and transitions[state] ~= nil then
                -- The state's own validated scale, or no profile for this call.
                local scale = scaleTable[state]
                if type(scale) ~= "number" or scale ~= scale or scale < 0 or scale == math.huge then
                    return refuse("YIELD_SCALE_UNAVAILABLE", string.format(", growth state %d of fruit %d has no yieldScales entry", state, fruitIndex))
                end
                scales[state] = scale
                local soil, grain = soilAt(cx, cz)
                pixels[#pixels + 1] = { x = cx, z = cz, state = state, target = transitions[state], soil = soil, grain = grain }
            end
        end
    end
    return { admitted = nil, fruitIndex = fruitIndex, grid = g, pixels = pixels, scales = scales }
end

--- After the native cut: keep the pixels that made their harvest transition, group
--- them by state and Soil cell, and admit the profile only on the native's own total.
---@param returnedArea number  the scaled area the native call returned
function CS.after(cap, returnedArea)
    if cap == nil or cap.admitted == false then return cap end
    local g = cap.grid
    local groups, order, sum = {}, {}, 0
    for _, p in ipairs(cap.pixels) do
        local fruit, state = readPoint(g, p.x, p.z)
        if fruit == cap.fruitIndex and state == p.target then
            local cell = "none"
            if p.soil ~= nil and p.grain ~= nil then
                cell = tostring(math.floor((p.x + g.half) / p.grain)) .. ":" .. tostring(math.floor((p.z + g.half) / p.grain))
            end
            local key = tostring(p.state) .. "|" .. cell
            local grp = groups[key]
            if grp == nil then
                grp = { state = p.state, cell = cell, pixels = 0, yieldScale = cap.scales[p.state], soil = p.soil }
                groups[key] = grp
                order[#order + 1] = key
            end
            grp.pixels = grp.pixels + 1
            sum = sum + grp.yieldScale
        end
    end
    if type(returnedArea) ~= "number" or math.abs(sum - returnedArea) > CS.TOLERANCE * math.max(1, returnedArea) then
        return refuse("CUT_STATE_BASIS_MISMATCH", string.format(", observed %s against native %s", tostring(sum), tostring(returnedArea)))
    end
    local out = {}
    for _, key in ipairs(order) do
        local grp = groups[key]
        grp.weight = grp.pixels * grp.yieldScale
        out[#out + 1] = grp
    end
    CS.stats.admitted = CS.stats.admitted + 1
    logOnce("admitted", "FIRST CUT_STATE_VOLUME_V1 CUT ADMITTED: %d state/Soil portion(s) matched the native's own area %s. Cut output now carries its source states.",
        #out, tostring(returnedArea))
    return { admitted = true, fruitIndex = cap.fruitIndex, groups = out, weightSum = sum }
end

--- Bracket the engine's cutFruitArea table function (mechanism 4: the Cutter calls it
--- by table lookup, Cutter.lua:600), recording onto the witness entry of the cutter call
--- it runs inside. Outside a cutter call it is the native function, untouched.
function CS.installOn(util)
    if type(util) ~= "table" or type(util.cutFruitArea) ~= "function" then return false end
    if rawget(util, "_sgCutState") ~= nil then return false end
    local original = util.cutFruitArea
    local packn = function(...) return select("#", ...), { ... } end
    local wrapper = function(fruitIndex, sx, sz, wx, wz, hx, hz, destroySpray, useMinForageState, ...)
        local entry = SGHarvestCapture ~= nil and SGHarvestCapture.activeEntry or nil
        local cap = nil
        if entry ~= nil and g_server ~= nil then
            local ok, result = pcall(CS.before, fruitIndex, sx, sz, wx, wz, hx, hz, useMinForageState)
            if ok then cap = result end
        end
        local n, r = packn(pcall(original, fruitIndex, sx, sz, wx, wz, hx, hz, destroySpray, useMinForageState, ...))
        if cap ~= nil and r[1] then
            local ok, result = pcall(CS.after, cap, r[2])
            if ok and result ~= nil then
                entry.cutStates = entry.cutStates or {}
                -- Only a call that cut something is a source; the Cutter stops at the
                -- first fruit with a positive area (Cutter.lua:600-602).
                if type(r[2]) == "number" and r[2] > 0 then entry.cutStates[#entry.cutStates + 1] = result end
            end
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
    util.cutFruitArea = wrapper
    rawset(util, "_sgCutState", { original = original, wrapper = wrapper })
    return true
end
