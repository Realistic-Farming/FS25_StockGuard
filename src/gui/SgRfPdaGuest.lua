-- =========================================================
-- SgRfPdaGuest - Esc Stock management floor (SG5)
-- Equal-bootstrap + fw table (8 rows) + host transport paging.
-- Controls: comma/period = page/focus; STORAGES / BUYERS / BACK chips = views (no bare [ ] keys).
-- REPAIR-215: there is NO selection control on this page. A yard only filters by position and stores
-- nothing, so switching to one on a stock check had no purpose; the selector is hidden in every state.
-- Step order: farm/permission clear → hint page → row focus → local window → transport page.
-- Selection: always FARM from this page. The adapter still lists provider SITE and LIBRARY options, and
-- openFromHostModule can still arrive with a site focus from another module, but nothing here offers a pick.
-- =========================================================

SgRfPdaGuest = SgRfPdaGuest or {}

local MOD_DIR = (StockGuardModDirectory or g_currentModDirectory)
local MOD_NAME = (StockGuardModName or g_currentModName or "FS25_StockGuard")
local PANEL_ID = "stockGuard"
local PANEL_ORDER = 55
local ROWS_PER_PAGE = 8
-- REPAIR-213: the Name cell went from 280px to 340px in the door's row template, so the clip that used to
-- cut "Round bale Net - MF RB 4160V Pr..." moves out with it. 47 chars filled 280px at this cell's 18px.
local LABEL_SOFT_MAX = 57
local HINT_CHARS = 180

local _registered = false
local _lastFarmId = nil
local _pendingRequest = false
local _hasFarmSeen = false
local _pageIndex = 1
local _actionChipOffset = 0
local _modePickIndex = 1
local _focusSlot = 1
local _hintSkip = 0
local _paintRows = {}
local _lastPaint = nil
local _lastContainer = nil
-- Transport page trail: stack of pageCursor values that led HERE (empty = first host page).
local _cursorTrail = {}
local _requestedCursor = nil
local _lastRequestedCursor = nil
-- Current presentation selection (Stock route FARM/SITE; focus lifecycle is adapter-owned).
local _selection = { route = "STOCK", selectionKind = "FARM" }
local _selectionIndex = 1
local _selectionOptions = nil
local _routePending = false
local _stationWaiting = false
local _entryHold = false
local seedSelectionSelector
local paintCommandChrome
local currentPageStart
-- REPAIR-209: the detail band names each action, and it is painted long before actionVerb's own
-- definition further down, so the name is declared here rather than resolving as a nil global.
local actionVerb
-- REPAIR-214: isActivePanel is defined near the bottom, below paintTable, but the chip draw hook created in
-- wireChipPaint has to see it as a LOCAL. Without this line the closure would resolve the name as a global
-- and get nil, which is how the REPAIR-213 detail band threw on actionVerb.
local isActivePanel
-- REPAIR-216: the chip draw hook also puts the shared geometry back when another module takes the page, and
-- wireChipPaint is defined above restoreSgLayout, so the name is declared here for the same reason
-- isActivePanel is.
local restoreSgLayout

local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[MOD_NAME]
    local i18n = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and type(text) == "string" and text ~= "" then
            local lower = text:lower()
            if lower ~= tostring(key):lower()
                and text ~= ("$l10n_" .. key)
                and not lower:find("^missing%s")
                and not lower:find("^missing_")
            then
                return text
            end
        end
    end
    return fallback or key
end

local function utf8Truncate(text, maxChars)
    if SGEscClientAdapter ~= nil and type(SGEscClientAdapter.utf8Truncate) == "function" then
        return SGEscClientAdapter.utf8Truncate(text, maxChars)
    end
    if type(text) ~= "string" then return "", false end
    if #text <= maxChars then return text, false end
    return text:sub(1, maxChars), true
end

local function utf8Offset(text, skipChars)
    if SGEscClientAdapter ~= nil and type(SGEscClientAdapter.utf8Offset) == "function" then
        return SGEscClientAdapter.utf8Offset(text, skipChars)
    end
    return math.min(#(text or "") + 1, (skipChars or 0) + 1), true
end

local function getHost()
    if g_currentMission ~= nil and g_currentMission.rfEscModules ~= nil then
        return g_currentMission.rfEscModules
    end
    if type(getfenv) == "function" then
        local env = getfenv(0)
        if env ~= nil and env.g_rfEscModules ~= nil then
            return env.g_rfEscModules
        end
    end
    if RfEscModules ~= nil and type(RfEscModules.getOrCreate) == "function" then
        return RfEscModules.getOrCreate()
    end
    return nil
end

local function getHostPage()
    if g_inGameMenu == nil then return nil end
    return g_inGameMenu.menuRealisticFarming
end

local function findDescendant(root, id)
    if root == nil or id == nil then return nil end
    if root.getDescendantById then
        local el = root:getDescendantById(id)
        if el ~= nil then return el end
    end
    local page = getHostPage()
    if page and page.getDescendantById then
        return page:getDescendantById(id)
    end
    return nil
end

local function setText(el, text)
    if el ~= nil and type(el.setText) == "function" then el:setText(text or "") end
end

local function setVis(el, visible)
    if el ~= nil and type(el.setVisible) == "function" then el:setVisible(visible == true) end
end

local function localFarmId()
    if g_localPlayer ~= nil then
        if type(g_localPlayer.getFarmId) == "function" then
            local ok, id = pcall(g_localPlayer.getFarmId, g_localPlayer)
            if ok and id ~= nil then return id end
        end
        if g_localPlayer.farmId ~= nil then return g_localPlayer.farmId end
    end
    return nil
end

local function unitLabel(unit)
    if unit == "LITRE" then return tr("sg5_unit_litre", "L") end
    if unit == "KILOGRAM" then return tr("sg5_unit_kilogram", "kg") end
    if unit == "COUNT" then return tr("sg5_unit_count", "count") end
    if unit == "FRACTION" then return tr("sg5_unit_fraction", "fraction") end
    if unit == "CURRENCY" then return tr("sg5_unit_currency", "currency") end
    if unit == "UNAVAILABLE" then return tr("sg5_unit_unavailable", "unit unavailable") end
    if unit == nil or unit == "" then return tr("sg5_unit_unknown", "unit unknown") end
    return tostring(unit)
end

local function knowledgeLabel(k)
    if k == "KNOWN" then return tr("sg5_knowledge_known", "known") end
    if k == "PARTIAL" then return tr("sg5_knowledge_partial", "partial") end
    if k == "UNKNOWN" then return tr("sg5_knowledge_unknown", "unknown") end
    if k == "HISTORICAL" then return tr("sg5_knowledge_historical", "historical") end
    if k == "UNAVAILABLE" then return tr("sg5_knowledge_unavailable", "unavailable") end
    if k == nil then return "" end
    return tr("sg5_knowledge_unknown", "unknown")
end

local function formatAmount(amount, unit)
    if amount == nil then
        return tr("sg5_amount_unknown", "amount unknown")
    end
    local n = tonumber(amount)
    if n == nil then
        return tr("sg5_amount_unknown", "amount unknown")
    end
    local u = unitLabel(unit)
    if unit == nil or unit == "" or unit == "UNAVAILABLE" then
        return string.format(tr("sg5_amount_with_unknown_unit", "%.0f (%s)"), n, u)
    end
    return string.format("%.0f %s", n, u)
end

--- REPAIR-211: the row name says the PRODUCT and where it is, the way the Farm Tablet's row title does
--- (FS25_FarmTablet StockGuardApp.lua:43-82). Before this the Esc page printed the holder alone, so three
--- rows all read "MF RB 4160V Protec" while the Tablet named the hay, the net and the wrap inside it.
--- An internal profile id is never shown: it is not a name a player can use.
local function isProfileId(s, row)
    if type(s) ~= "string" or s == "" then return true end
    if type(row) == "table" and s == row.carrierKind then return true end
    return string.match(s, "^NATIVE_[A-Z0-9_]+_V%d+$") ~= nil
end

local function productTitle(row)
    if type(row) ~= "table" or type(row.materialRef) ~= "table" then return nil end
    local name = row.materialRef.fillTypeName
    if type(name) ~= "string" or name == "" then return nil end
    if g_fillTypeManager ~= nil and type(g_fillTypeManager.getFillTypeByName) == "function" then
        local ok, ft = pcall(g_fillTypeManager.getFillTypeByName, g_fillTypeManager, name)
        if ok and type(ft) == "table" and type(ft.title) == "string" and ft.title ~= "" then
            return ft.title
        end
    end
    return name
end

--- The full name, unclipped. The sheet clips it; the detail band shows all of it.
local function rowFullName(row)
    local product = productTitle(row)
    local place = (type(row) == "table" and not isProfileId(row.label, row)) and row.label or nil
    if product ~= nil and place ~= nil then
        -- REPAIR-213: "Seeds - Seeds" and "Solid Fertilizer - Solid Fertilizer Big bag" were the holder
        -- repeating the product. The holder is the native carrier's own name (SGViews stockRow), which is
        -- often the product's. Equal names collapse to the product; a holder that already begins with the
        -- product is strictly the more specific of the two, so it stands alone. Case-insensitive, and the
        -- comparison is on the whole product string so "Oat" can never swallow "Oatmeal silo".
        local lowerProduct, lowerPlace = product:lower(), place:lower()
        if lowerProduct == lowerPlace then return product end
        if lowerPlace:sub(1, #lowerProduct) == lowerProduct then return place end
        return string.format(tr("sg5_row_product_at", "%s - %s"), product, place)
    end
    if product ~= nil then return product end
    if place ~= nil then return place end
    return nil
end

local function shortLabel(label)
    if type(label) ~= "string" or label == "" then
        return tr("sg5_row_unnamed", "Stock")
    end
    local clipped, trunc = utf8Truncate(label, LABEL_SOFT_MAX)
    if trunc then
        return clipped .. "…"
    end
    return clipped
end

local function pageCount()
    local n = #_paintRows
    if n <= 0 then return 1 end
    return math.max(1, math.ceil(n / ROWS_PER_PAGE))
end

local function visibleCount()
    local start = (_pageIndex - 1) * ROWS_PER_PAGE + 1
    local last = math.min(#_paintRows, start + ROWS_PER_PAGE - 1)
    if last < start then return 0 end
    return last - start + 1
end


local function selectionSummary()
    local kind = _selection and _selection.selectionKind or "FARM"
    if kind == "SITE" then
        local id = _selection.siteId or ""
        return string.format(tr("sg5_sel_banner_site", "Site: %s"), id)
    end
    if _stationWaiting then
        return tr("sg5_station_waiting_title", "Stock")
    end
    return tr("sg5_sel_banner_farm", "Farm stock")
end

--- REPAIR-213: a disclosed property as one short readable phrase. propertyId is an SG identifier, so it is
--- looked up as an l10n key first and only falls back to a humanised form of itself ("SOIL_N_CONTENT" ->
--- "Soil n content"); the raw id never reaches the screen unchanged in the SHOUTING form it is stored in.
--- Coverage is shown when the record carries it, because "known on 120 of 500 L" is the honest shape of a
--- partial reading.
local function propertyLabel(id)
    local words = tostring(id):gsub("_", " "):lower()
    local pretty = words:sub(1, 1):upper() .. words:sub(2)
    return tr("sg5_prop_" .. tostring(id):lower(), pretty)
end

local function propertySummary(p)
    if type(p) ~= "table" then return "" end
    local text = propertyLabel(p.propertyId)
    local known, basis = tonumber(p.knownAmount), tonumber(p.basisAmount)
    if known ~= nil and basis ~= nil and basis > 0 then
        return string.format(tr("sg5_prop_coverage", "%s: %s of %s"), text,
            formatAmount(known, p.amountUnit), formatAmount(basis, p.amountUnit))
    end
    if type(p.knowledge) == "string" and p.knowledge ~= "" then
        return string.format(tr("sg5_prop_knowledge", "%s: %s"), text, knowledgeLabel(p.knowledge))
    end
    return text
end

local function rowKindLabel(kind)
    if kind == "CARRIER" then return tr("sg5_kind_carrier", "Carrier") end
    if kind == "PROCESS" then return tr("sg5_kind_process", "Process") end
    if kind == "OBSERVATION" then return tr("sg5_kind_observation", "Note") end
    return tr("sg5_kind_stock", "Stock")
end

local function processStateLabel(row)
    local key = row.processStateLabelKey
    if type(key) == "string" and key ~= "" then
        local mapped = tr(key, nil)
        if mapped ~= nil and mapped ~= key then return mapped end
    end
    if type(row.processState) == "string" and row.processState ~= "" then
        return tr("sg5_process_state_fallback", row.processState)
    end
    return tr("sg5_process_state_unknown", "state unknown")
end

--- REPAIR-213: Fill is only honest when the capacity is KNOWN, positive, and carried in the SAME unit as
--- the amount. Anything short of that is blank rather than a guess, because a wrong percentage is worse
--- than an empty cell.
---
--- REPAIR-215: and it is per HOLDER, not per stock row. One silo carrier can hold Oat, Wheat and Sorghum at
--- once, and n.capacity is the whole silo's, so dividing a single stock by it would read "20000 / 120000
--- (17%)" for the Oat while the silo is actually full of grain. Every stock on the carrier is summed first.
--- If two stocks on one carrier are in different units the carrier's Fill is blank, because there is no
--- number that would be true.
--- REPAIR-215, option 1 as ruled in NOTE-052. The holder is identified by holderKey, which SGViews sets from
--- carrier.native.nativeUniqueId, so several carriers standing on one silo map to one holder.
---
--- Fill is shown ONLY when a holder carries exactly ONE fill type. Storage:getCapacity returns
--- "capacities[fillType] or self.capacity", so a silo with no per-type capacity reports the WHOLE silo to
--- every fill type on it. With one fill type the percentage is certainly true. With several there is no
--- number that is true of the holder, because nothing on the row says whether that capacity is the type's own
--- or the silo's shared total, and those two want opposite arithmetic. So it is blank, and the heading goes
--- with it rather than labelling a column of nothing.
local _holderFill = {}

local function holderKeyOf(r)
    if type(r) ~= "table" then return nil end
    local key = r.holderKey
    if type(key) ~= "string" or key == "" then key = r.carrierId end
    return key
end

local function rebuildHolderFill(rows)
    _holderFill = {}
    for i = 1, #rows do
        local r = rows[i]
        local key = holderKeyOf(r)
        if key ~= nil then
            local e = _holderFill[key]
            if e == nil then
                e = { amount = 0, capacity = nil, capacityUnit = nil, amountUnit = nil,
                      fillTypes = {}, fillTypeCount = 0, known = false }
                _holderFill[key] = e
            end
            local mat = (type(r.materialRef) == "table") and r.materialRef.fillTypeName or nil
            if type(mat) == "string" and mat ~= "" and e.fillTypes[mat] == nil then
                e.fillTypes[mat] = true
                e.fillTypeCount = e.fillTypeCount + 1
            end
            if r.capacityKnown == true and tonumber(r.capacity) ~= nil then
                e.known = true
                e.capacity = tonumber(r.capacity)
                e.capacityUnit = r.capacityUnit
            end
            local amt = tonumber(r.amount)
            if amt ~= nil then
                e.amount = e.amount + amt
                e.amountUnit = e.amountUnit or r.amountUnit
            end
        end
    end
end

local function holderFillOf(r)
    local key = holderKeyOf(r)
    if key == nil then return nil end
    local e = _holderFill[key]
    if e == nil or e.known ~= true then return nil end
    if e.fillTypeCount ~= 1 then return nil end
    local cap = e.capacity
    if cap == nil or cap <= 0 then return nil end
    if e.capacityUnit ~= e.amountUnit then return nil end
    return e.amount, cap, e.amountUnit, math.floor((e.amount / cap) * 100 + 0.5)
end

--- The purpose rule (NOTE-052): no empty furniture. If nothing in the view has a Fill worth showing, the
--- heading goes blank too.
local function anyFillUsable(rows)
    for i = 1, #rows do
        if holderFillOf(rows[i]) ~= nil then return true end
    end
    return false
end

local function fillCell(r)
    local amt, cap, unit, pct = holderFillOf(r)
    if amt == nil then return "" end
    return string.format(tr("sg5_fill_of", "%s / %s (%d%%)"),
        formatAmount(amt, unit), formatAmount(cap, unit), pct)
end

--- REPAIR-213: the farmland the stock is standing on.
--- getFieldAtWorldPosition, which the design named, does not exist. FarmlandManager:getFarmlandAtWorldPosition
--- does, and returns the farmland object in one call, so the id-then-lookup pair is not needed. The name is a
--- FIELD on it (Farmland.new: self.name = name or tostring(self.id)), which is why an unnamed farmland still
--- reads as its number; a getName() is tried as a fallback because the decompiled build Brian quoted has one.
--- Everything is pcall'd, and answers are memoised by rounded x,z so one paint never asks twice for a spot.
local _whereCache = {}

local function whereCell(r)
    if r.positionKnown ~= true then return "" end
    local x, zz = tonumber(r.x), tonumber(r.z)
    if x == nil or zz == nil then return "" end
    local key = string.format("%.0f:%.0f", x, zz)
    local hit = _whereCache[key]
    if hit ~= nil then return hit end
    local text = ""
    local fm = g_farmlandManager
    if fm ~= nil and type(fm.getFarmlandAtWorldPosition) == "function" then
        local ok, land = pcall(fm.getFarmlandAtWorldPosition, fm, x, zz)
        if ok and type(land) == "table" then
            local name = land.name
            if (name == nil or name == "") and type(land.getName) == "function" then
                local okName, alt = pcall(land.getName, land)
                if okName then name = alt end
            end
            if name ~= nil and name ~= "" then
                text = string.format(tr("sg5_where_farmland", "Farmland %s"), tostring(name))
            end
        end
    end
    _whereCache[key] = text
    return text
end

--- ===================================================================================================
--- REPAIR-214: the farm planner's data layer. Read-only, pcall'd throughout, and correct on a client.
---
--- Every engine fact below is read from the decompiled extract at
--- "FS25 Game Files/extract/decompiled/scripts", which is the authority; the partial lua-source-index
--- does not contain these files at all.
--- ===================================================================================================

local VIEW_PLANNER, VIEW_STORAGES, VIEW_BUYERS = "PLANNER", "STORAGES", "BUYERS"
local _view = VIEW_PLANNER
--- The product the drill-down views are about, as a fillTypeName. nil in the planner view.
local _drillProduct = nil
--- Grouped planner rows, and the rows each view paints. Rebuilt on every paint.
local _plannerRows = {}
local _viewRows = {}
--- Per-paint caches. Cleared at the top of paintTable beside _whereCache, for the same reason: an answer
--- held longer than one paint goes stale the moment a price moves or a station is built.
local _priceCache = {}
local _stationCache = nil

--- PricingDynamics.TREND_PLATEAU = 1, TREND_CLIMBING = 2, TREND_FALLING = 3 (economy/PricingDynamics.lua:7-9).
--- The number reaches a client through SellingStation:getCurrentPricingTrend, which returns
--- fillTypePriceInfo[fillType] - the field both network streams carry.
local function trendLabel(trend)
    if PricingDynamics ~= nil then
        if trend == PricingDynamics.TREND_CLIMBING then return tr("sg6_trend_up", "up") end
        if trend == PricingDynamics.TREND_FALLING then return tr("sg6_trend_down", "down") end
        if trend == PricingDynamics.TREND_PLATEAU then return tr("sg6_trend_flat", "flat") end
    end
    return ""
end

local function fillTypeIndexOf(name)
    if type(name) ~= "string" or name == "" then return nil end
    local ftm = g_fillTypeManager
    if ftm == nil or type(ftm.getFillTypeIndexByName) ~= "function" then return nil end
    local ok, index = pcall(ftm.getFillTypeIndexByName, ftm, name)
    if ok and index ~= nil then return index end
    return nil
end

local function fillTypeDescOf(name)
    local ftm = g_fillTypeManager
    if ftm == nil or type(ftm.getFillTypeByName) ~= "function" then return nil end
    local ok, ft = pcall(ftm.getFillTypeByName, ftm, name)
    if ok and type(ft) == "table" then return ft end
    return nil
end

--- The player's map position, for the nearest-buyer tie-break. getMapPositionAndLookYaw is the cheapest
--- client-safe source. Returns nil,nil in a menu opened before the player exists, which is why the
--- tie-break falls back to name order rather than assuming a position of 0,0.
local function playerXZ()
    local p = g_localPlayer
    if p == nil or type(p.getMapPositionAndLookYaw) ~= "function" then return nil, nil end
    local ok, x, z = pcall(p.getMapPositionAndLookYaw, p)
    if ok and type(x) == "number" and type(z) == "number" then return x, z end
    return nil, nil
end

local function placeableXZ(placeable)
    if type(placeable) ~= "table" or type(placeable.getPosition) ~= "function" then return nil, nil end
    local ok, x, _y, z = pcall(placeable.getPosition, placeable)
    if ok and type(x) == "number" and type(z) == "number" then return x, z end
    return nil, nil
end

--- A station's display name. SellingStation:getName (:303-309) computes the owningPlaceable fallback and
--- then DISCARDS it, returning nil whenever stationName is nil, so the fallback is done here instead.
local function stationName(station)
    local n = station.stationName
    if type(n) == "string" and n ~= "" then return n end
    local p = station.owningPlaceable
    if type(p) == "table" and type(p.getName) == "function" then
        local ok, alt = pcall(p.getName, p)
        if ok and type(alt) == "string" and alt ~= "" then return alt end
    end
    return tr("sg6_buyer_unnamed", "Unnamed buyer")
end

--- Every selling station the prices page would list, built once per paint.
--- This follows vanilla's own loop, InGameMenuStatisticsFrame:updateStationData (:1433-1460), rather than
--- the reference mod: storageSystem:getUnloadingStations, isa(SellingStation), skip hideFromPricesMenu,
--- and group by owningPlaceable so several triggers on one shop are ONE buyer. hideFromPricesMenu is set
--- by PlaceableHusbandry (:73) and PlaceableProductionPoint (:65), so husbandries and production points are
--- deliberately absent, exactly as they are from vanilla's prices page.
local function allStations()
    if _stationCache ~= nil then return _stationCache end
    _stationCache = {}
    local mission = g_currentMission
    if mission == nil or type(mission.storageSystem) ~= "table" then return _stationCache end
    local ss = mission.storageSystem
    if type(ss.getUnloadingStations) ~= "function" then return _stationCache end
    local ok, list = pcall(ss.getUnloadingStations, ss)
    if not ok or type(list) ~= "table" then return _stationCache end
    local myFarm = localFarmId()
    local seenPlaceable = {}
    for _, station in pairs(list) do
        local keep = type(station) == "table"
        if keep and SellingStation ~= nil and type(station.isa) == "function" then
            local okIsa, isSelling = pcall(station.isa, station, SellingStation)
            keep = okIsa and isSelling == true
        elseif keep then
            -- No SellingStation class in scope: fall back to the fields only a selling station has.
            keep = type(station.acceptedFillTypes) == "table" and type(station.fillTypePrices) == "table"
        end
        if keep and station.hideFromPricesMenu == true then keep = false end
        if keep then
            local p = station.owningPlaceable
            -- Our own farm does not buy from us.
            if type(p) == "table" and p.ownerFarmId ~= nil and myFarm ~= nil and p.ownerFarmId == myFarm then
                keep = false
            end
        end
        if keep then
            local p = station.owningPlaceable
            local key = (p ~= nil) and tostring(p) or ("station:" .. tostring(station))
            if seenPlaceable[key] == nil then
                seenPlaceable[key] = true
                local x, z = placeableXZ(p)
                _stationCache[#_stationCache + 1] = {
                    station = station, placeable = p, name = stationName(station), x = x, z = z,
                }
            end
        end
    end
    return _stationCache
end

--- Buyers for one product, best price first. Price and trend both come from the station's own accessors,
--- which are correct on a client: getEffectiveFillTypePrice returns the synced fillTypePrices value when
--- self.isServer is false (:388-404), and the server wrote the FULL effective price into that field
--- (writeStream :167-183 sends getEffectiveFillTypePrice * 1000; readStream :154-166 stores it / 1000).
--- The synced value is quantised to 0.001 and capped at 65.535 per litre by the UInt16 in the stream, which
--- no base-game product comes near.
--- NOTE: with Market Dynamics loaded, SellingStation.getEffectiveFillTypePrice is overwritten
--- (FS25_MarketDynamics/src/PriceHook.lua:58-88) and returns a price per FILL TYPE with no station
--- argument, so every buyer ties. That is handled by the tie-break below rather than worked around.
local function buyersFor(fillTypeName)
    local index = fillTypeIndexOf(fillTypeName)
    if index == nil then return {} end
    local desc = fillTypeDescOf(fillTypeName)
    -- Vanilla's prices page skips fill types that are not on the price table; BALE_NET and BALE_WRAP are
    -- the two that matter here, and they correctly end up with no buyer rather than an invented price.
    if type(desc) == "table" and desc.showOnPriceTable == false then return {} end
    local out = {}
    for _, entry in ipairs(allStations()) do
        local station = entry.station
        local allowed = false
        if type(station.getIsFillTypeAllowed) == "function" then
            local okA, a = pcall(station.getIsFillTypeAllowed, station, index)
            allowed = okA and a == true
        elseif type(station.acceptedFillTypes) == "table" then
            allowed = station.acceptedFillTypes[index] == true
        end
        if allowed and type(station.getEffectiveFillTypePrice) == "function" then
            local okP, price = pcall(station.getEffectiveFillTypePrice, station, index)
            if okP and type(price) == "number" and price > 0 then
                local trend = nil
                if type(station.getCurrentPricingTrend) == "function" then
                    local okT, t = pcall(station.getCurrentPricingTrend, station, index)
                    if okT then trend = t end
                end
                out[#out + 1] = { name = entry.name, price = price, trend = trend, x = entry.x, z = entry.z }
            end
        end
    end
    -- Nearest-then-name tie-break, as ruled in NOTE-20261002-BOB-047. Prices are compared AFTER rounding to
    -- the three decimals the page shows, so two buyers that read the same on screen are treated as the same.
    local px, pz = playerXZ()
    local function dist(b)
        if px == nil or b.x == nil or b.z == nil then return nil end
        local dx, dz = b.x - px, b.z - pz
        return math.sqrt(dx * dx + dz * dz)
    end
    local function shown(p) return math.floor(p * 1000 + 0.5) end
    table.sort(out, function(a, b)
        local pa, pb = shown(a.price), shown(b.price)
        if pa ~= pb then return pa > pb end
        local da, db = dist(a), dist(b)
        if da ~= nil and db ~= nil and da ~= db then return da < db end
        if da ~= nil and db == nil then return true end
        if da == nil and db ~= nil then return false end
        return tostring(a.name) < tostring(b.name)
    end)
    -- How many buyers read the same price as the best one.
    local tied = 0
    if #out > 0 then
        local top = shown(out[1].price)
        for _, b in ipairs(out) do
            if shown(b.price) == top then tied = tied + 1 end
        end
    end
    return out, tied
end

local function bestBuyerFor(fillTypeName)
    local hit = _priceCache[fillTypeName]
    if hit ~= nil then return hit end
    local list, tied = buyersFor(fillTypeName)
    local best = list[1]
    local res = {
        price = best and best.price or nil,
        trend = best and best.trend or nil,
        name = best and best.name or nil,
        tied = tied or 0,
        count = #list,
        list = list,
    }
    _priceCache[fillTypeName] = res
    return res
end

--- The best month for this product, as an ESTIMATE, and deliberately labelled one on screen.
--- getFillTypeSeasonalFactor (economy/EconomyManager.lua:440-448) does NOT return month p's factor: it
--- returns MathUtil.catmullRom over four neighbouring months. So the ratio of a raw monthly factor to the
--- interpolated current factor is an approximation, not arithmetic, and the page says "est.".
--- The month name comes from the game's own I18N:formatPeriod (I18N.lua:625-643), which resolves ui_monthN,
--- so no month string is invented here.
local function peakFor(fillTypeName, currentPrice)
    local desc = fillTypeDescOf(fillTypeName)
    if type(desc) ~= "table" or type(desc.economy) ~= "table" then return nil end
    local factors = desc.economy.factors
    if type(factors) ~= "table" then return nil end
    local mission = g_currentMission
    if mission == nil or type(mission.environment) ~= "table" then return nil end
    local em = mission.economyManager
    if type(em) ~= "table" or type(em.getFillTypeSeasonalFactor) ~= "function" then return nil end
    if type(mission.environment.getPeriodAndAlphaIntoPeriod) ~= "function" then return nil end
    local okE, period, alpha = pcall(mission.environment.getPeriodAndAlphaIntoPeriod, mission.environment)
    if not okE or type(period) ~= "number" then return nil end
    local okF, factorNow = pcall(em.getFillTypeSeasonalFactor, em, desc, period, alpha)
    if not okF or type(factorNow) ~= "number" or factorNow <= 0 then return nil end
    local peak, peakPeriod = nil, nil
    for p = 1, 12 do
        local f = tonumber(factors[p])
        if f ~= nil and (peak == nil or f > peak) then peak, peakPeriod = f, p end
    end
    if peak == nil or peakPeriod == nil then return nil end
    local month = nil
    if g_i18n ~= nil and type(g_i18n.formatPeriod) == "function" then
        local okM, m = pcall(g_i18n.formatPeriod, g_i18n, peakPeriod, false)
        if okM and type(m) == "string" and m ~= "" then month = m end
    end
    local atPeak = nil
    if type(currentPrice) == "number" then atPeak = currentPrice * (peak / factorNow) end
    return { factorNow = factorNow, peak = peak, period = peakPeriod, month = month, priceAtPeak = atPeak }
end

--- One row per product, summed across every holder StockGuard can see.
--- Units are NEVER mixed: the first row's unit for a product wins, rows in any other unit are counted and
--- reported rather than added, because a litre plus a kilogram is not a number.
local function groupByProduct(rows)
    local order, byName = {}, {}
    for i = 1, #rows do
        local r = rows[i]
        if type(r) == "table" and (r.rowKind or "STOCK") == "STOCK" then
            local name = (type(r.materialRef) == "table") and r.materialRef.fillTypeName or nil
            local synthetic = false
            if type(name) ~= "string" or name == "" then
                -- REPAIR-214: a stock row with no fill type must NOT disappear. Dropping it would quietly
                -- remove its amount from the farm total, which is the one number this page exists for. It
                -- gets its own row keyed by the holder label, and no price, because without a fill type
                -- there is no buyer to look up either. The prefix cannot collide with a real fill type name.
                name = "sg6:nofilltype:" .. tostring(r.label or "?")
                synthetic = true
            end
            do
                local g = byName[name]
                if g == nil then
                    g = {
                        fillTypeName = name,
                        synthetic = synthetic,
                        title = synthetic and shortLabel(r.label) or (productTitle(r) or name),
                        amount = 0, amountUnit = r.amountUnit,
                        holders = 0, holderIds = {}, skipped = 0, rows = {},
                    }
                    byName[name] = g
                    order[#order + 1] = g
                end
                local amt = tonumber(r.amount)
                if amt ~= nil and r.amountUnit == g.amountUnit then
                    g.amount = g.amount + amt
                else
                    g.skipped = g.skipped + 1
                end
                local cid = r.carrierId
                if cid ~= nil and g.holderIds[cid] == nil then
                    g.holderIds[cid] = true
                    g.holders = g.holders + 1
                end
                g.rows[#g.rows + 1] = r
            end
        end
    end
    -- Price, value and the sort key.
    for _, g in ipairs(order) do
        if not g.synthetic then
            local b = bestBuyerFor(g.fillTypeName)
            g.price, g.trend, g.buyer = b.price, b.trend, b.name
            g.tied, g.buyerCount = b.tied, b.count
        else
            g.tied, g.buyerCount = 0, 0
        end
        g.value = (g.price ~= nil) and (g.price * g.amount) or nil
    end
    -- Highest value first; everything with no buyer sinks to the bottom in name order, so the rows a player
    -- can act on are always at the top.
    table.sort(order, function(a, b)
        local va, vb = a.value, b.value
        if va ~= nil and vb ~= nil and va ~= vb then return va > vb end
        if va ~= nil and vb == nil then return true end
        if va == nil and vb ~= nil then return false end
        return tostring(a.title) < tostring(b.title)
    end)
    return order
end

--- REPAIR-209: ONE source of truth for the four cell strings, used by the scrolling sheet and by the
--- legacy static slots, so a row can never read differently in the two places.
--- REPAIR-213 replaced the last two columns. C was the per-kind status and D was the kind, and on a real
--- save both were constant: every one of Wizard's fourteen rows read "unknown" and "Stock", because nothing
--- persisted provenance before REPAIR-208 and every row genuinely IS a stock. Two of four columns carrying
--- no information is a lot of width, so C is now Fill and D is Where. Knowledge did not disappear with the
--- column: it is still a fact in the detail band. CARRIER and PROCESS rows keep their own B and C strings,
--- since neither has an amount or a position to show.
local function rowCells(r)
    local kind = r.rowKind or "STOCK"
    local b, c
    if kind == "CARRIER" then
        if r.capacityKnown and r.capacity ~= nil then
            b = formatAmount(r.capacity, r.capacityUnit)
        else
            b = ""
        end
        if r.unavailable then
            c = tr("sg5_carrier_unavailable", "unavailable")
        elseif r.partial then
            c = tr("sg5_carrier_partial", "partial")
        else
            c = tr("sg5_carrier_ready", "ready")
        end
    elseif kind == "PROCESS" then
        b = processStateLabel(r)
        if r.unavailable then
            c = tr("sg5_process_unavailable", "unavailable")
        elseif r.partial then
            c = tr("sg5_process_partial", "partial")
        elseif r.enabled == false then
            c = tr("sg5_process_disabled", "disabled")
        else
            c = tr("sg5_process_enabled", "enabled")
        end
    else
        b = formatAmount(r.amount, r.amountUnit)
        c = knowledgeLabel(r.knowledge)
    end
    local d
    if kind == "CARRIER" or kind == "PROCESS" then
        -- These two never reach the Esc page on a stock route, but rowCells is the shared formatter, so they
        -- keep the kind in D rather than an empty cell that would read as a missing location.
        d = rowKindLabel(kind)
    else
        c = fillCell(r)
        d = whereCell(r)
    end
    return shortLabel(rowFullName(r) or r.label), b, c, d
end

--- ===================================================================================================
--- REPAIR-214: the three views, their cells, and the chip law.
--- ===================================================================================================

--- The product the drill-down views are titled with, kept beside _drillProduct so the heading can read
--- "Storages: Hay" rather than "Storages: DRYGRASS_WINDROW".
local _drillTitle = nil

local function moneyText(v)
    if type(v) ~= "number" then return "" end
    if g_i18n ~= nil and type(g_i18n.formatMoney) == "function" then
        local ok, s = pcall(g_i18n.formatMoney, g_i18n, v, 0, true, true)
        if ok and type(s) == "string" and s ~= "" then return s end
    end
    return string.format("%.0f", v)
end

--- Three decimals, which is exactly the precision the network stream carries: the synced price is an
--- integer number of thousandths (SellingStation writeStream/readStream). Showing more would be invented.
local function priceText(p)
    if type(p) ~= "number" then return "" end
    return string.format("%.3f", p)
end

--- NOTE-048 option 2: the four 213 cells are kept exactly as they are, because DairyCore, FertilizerDepot
--- and IncomeMod paint the same pooled cells and none of them states its own geometry. So price rides the
--- value cell instead of a fifth column: "8,640 @ 0.432 up".
local function plannerCells(g)
    local amount = formatAmount(g.amount, g.amountUnit)
    local valueCell, buyerCell
    if g.price == nil then
        valueCell = tr("sg6_no_buyer", "-")
        buyerCell = tr("sg6_no_buyer", "-")
    else
        local t = trendLabel(g.trend)
        valueCell = string.format(tr("sg6_value_at", "%s @ %s"), moneyText(g.value), priceText(g.price))
        if t ~= "" then valueCell = valueCell .. " " .. t end
        buyerCell = shortLabel(g.buyer or tr("sg6_buyer_unnamed", "Unnamed buyer"))
    end
    return shortLabel(g.title), amount, valueCell, buyerCell
end

--- One buyer, in the Buyers drill-down. The value column is what OUR amount would fetch there.
local function buyerCells(b)
    local t = trendLabel(b.trend)
    return shortLabel(b.name), priceText(b.price), (t ~= "" and t or tr("sg6_trend_unknown", "-")),
        moneyText(b.value)
end

local function headerTextsForView()
    if _view == VIEW_STORAGES then
        -- REPAIR-215: the Fill heading appears only when at least one row in this view really has a Fill. A
        -- column headed "Fill" over nothing but blanks is the empty furniture the purpose rule forbids.
        local fillHead = anyFillUsable(_viewRows) and tr("sg5_col_fill", "Fill") or ""
        return tr("sg6_col_holder", "Holder"), tr("sg5_col_amount", "Amount"),
            fillHead, tr("sg5_col_where", "Where")
    end
    if _view == VIEW_BUYERS then
        return tr("sg6_col_buyer", "Buyer"), tr("sg6_col_price", "Price"),
            tr("sg6_col_trend", "Trend"), tr("sg6_col_value", "Value")
    end
    return tr("sg6_col_product", "Product"), tr("sg5_col_amount", "Amount"),
        tr("sg6_col_value", "Value"), tr("sg6_col_best_buyer", "Best buyer")
end

--- The rows the current view paints, and the cell strings for them. Called once per paint.
local function buildViewRows()
    if _view == VIEW_STORAGES and _drillProduct ~= nil then
        -- The group already holds its own rows, so this is exact rather than a second match on fill type,
        -- and it works for a synthetic no-fill-type group as well.
        for _, g in ipairs(_plannerRows) do
            if g.fillTypeName == _drillProduct then return g.rows end
        end
        return {}
    end
    if _view == VIEW_BUYERS and _drillProduct ~= nil then
        local group = nil
        for _, g in ipairs(_plannerRows) do
            if g.fillTypeName == _drillProduct then
                group = g
                break
            end
        end
        local best = bestBuyerFor(_drillProduct)
        local out = {}
        for _, b in ipairs(best.list or {}) do
            out[#out + 1] = {
                rowKind = "BUYER", name = b.name, price = b.price, trend = b.trend,
                value = (group ~= nil and type(b.price) == "number") and (b.price * group.amount) or nil,
            }
        end
        return out
    end
    return _plannerRows
end

local function cellsForViewRow(r)
    if _view == VIEW_BUYERS then return buyerCells(r) end
    if _view == VIEW_STORAGES then return rowCells(r) end
    return plannerCells(r)
end

--- The count line, which names the view so the player always knows where they are.
local function countLineForView(rowCount)
    local n = #_viewRows
    if _view == VIEW_STORAGES then
        return string.format(tr("sg6_count_storages", "Storages: %s (%d)"),
            tostring(_drillTitle or _drillProduct or "?"), n)
    end
    if _view == VIEW_BUYERS then
        return string.format(tr("sg6_count_buyers", "Buyers: %s (%d)"),
            tostring(_drillTitle or _drillProduct or "?"), n)
    end
    return string.format(tr("sg6_count_planner", "Farm stock by product (%d)"), n)
end

--- ------------------------------------------------------------------ the chip law
--- Ported from the canonical implementation in FS25_SeasonalCropStress CsRfPdaGuest.lua:1502-1623, which is
--- where the law lives. The label is stored ON the element and the Button's own text is blanked, because a
--- TextElement label and a key chip must never draw at once.
local PIVOT_CHIP_TEXT = { 0.22323, 0.40724, 0.00368 }
local PIVOT_CHIP_BG = { 0.00913, 0.01033, 0.00651 }
local PIVOT_CHIP_GATED_TEXT = { 0.62, 0.64, 0.66 }
local PIVOT_CHIP_GATED_BG = { 0.06, 0.06, 0.065 }
local SG_CHIP_IDS = { "rfFwAct1", "rfFwAct2", "rfFwAct3" }

local function setPivotBtn(container, id, label, enabled, latched)
    local el = findDescendant(container, id)
    if el == nil then return end
    if el.setVisible then el:setVisible(true) end
    if el.setText then el:setText("") end
    el.rfPivotChipLabel = label
    el.rfPivotChipEnabled = enabled and true or false
    el.rfPivotChipLatched = latched and true or false
    if type(el.setDisabled) == "function" then el:setDisabled(not enabled) end
end

local function clearPivotBtn(container, id)
    local el = findDescendant(container, id)
    if el == nil then return end
    if el.setText then el:setText("") end
    el.rfPivotChipLabel = nil
    el.rfPivotChipEnabled = false
    el.rfPivotChipLatched = false
    setVis(el, false)
end

local function renderPivotChip(el, overlay)
    local label = el.rfPivotChipLabel
    if label == nil or label == "" then return end
    if el.absPosition == nil or el.absSize == nil then return end
    if el.visible == false then return end
    local height = el.absSize[2] * 0.72
    if height <= 0 then return end
    local enabled = el.rfPivotChipEnabled
    local t, b, ta, ba
    if enabled and el.rfPivotChipLatched then
        t, b, ta, ba = PIVOT_CHIP_BG, PIVOT_CHIP_TEXT, 1.0, 1.0
    elseif enabled then
        t, b, ta, ba = PIVOT_CHIP_TEXT, PIVOT_CHIP_BG, 1.0, 1.0
    else
        t, b, ta, ba = PIVOT_CHIP_GATED_TEXT, PIVOT_CHIP_GATED_BG, 0.45, 0.55
    end
    overlay:setColor(t[1], t[2], t[3], ta, b[1], b[2], b[3], ba)
    local width = overlay:getButtonWidth(label, height)
    local x = el.absPosition[1] + (el.absSize[1] - width) * 0.5
    local y = el.absPosition[2] + (el.absSize[2] - height) * 0.5
    overlay:renderButton(label, x, y, height, true)
end

--- The chips hang off rfFwTableBlock, which is SHARED with every other Table guest, so the draw hook is
--- guarded twice: once on the element's own visibility (the host hides all three on every refresh and only
--- this guest shows them again) and once on isActivePanel, so a chip of ours can never paint over Dairy.
local function wireChipPaint(container)
    local block = findDescendant(container, "rfFwTableBlock")
    if block == nil or block._sg6ChipWired then return end
    block._sg6ChipWired = true
    local prevDraw = block.draw
    function block:draw(...)
        if prevDraw ~= nil then prevDraw(self, ...) end
        if not isActivePanel() then
            -- REPAIR-216: this is the only reliable "on leave" there is. The host page says at its line 1702
            -- that no host ever calls a guest onHide, and grep agrees, so the shared geometry goes back here,
            -- on the first frame somebody else draws this block.
            restoreSgLayout(container)
            return
        end
        local idm = g_inputDisplayManager
        if idm == nil or type(idm.getKeyboardKeyOverlay) ~= "function" then return end
        local overlay = idm:getKeyboardKeyOverlay()
        if overlay == nil or type(overlay.renderButton) ~= "function" then return end
        for _, id in ipairs(SG_CHIP_IDS) do
            local el = findDescendant(self, id) or findDescendant(container, id)
            if el ~= nil then pcall(renderPivotChip, el, overlay) end
        end
        -- renderButton leaves the global text state set. Put the defaults back, exactly as the Crop Stress
        -- implementation does, because this draws outside the element order that would otherwise reset it.
        if setTextBold ~= nil then setTextBold(false) end
        if setTextAlignment ~= nil and RenderText ~= nil then setTextAlignment(RenderText.ALIGN_LEFT) end
        if setTextVerticalAlignment ~= nil and RenderText ~= nil then
            setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
        end
        if setTextColor ~= nil then setTextColor(1, 1, 1, 1) end
    end
end

--- Which chip does what, per view.
--- NOTE-047 ruled: view chips keep slots 1 and 2, actions take slot 3. Slots 1 and 2 are therefore always
--- Storages and Buyers, the chip for the CURRENT view is latched lime, and pressing the latched chip is what
--- goes Back. Slot 3 carries an explicit Back chip only when the focused row publishes no action, so Back is
--- always reachable either way and the ruling's allocation is never broken.
local function paintRowCells(container, slot, r)
    local a = findDescendant(container, "rfFwRow" .. slot .. "A")
    local b = findDescendant(container, "rfFwRow" .. slot .. "B")
    local c = findDescendant(container, "rfFwRow" .. slot .. "C")
    local d = findDescendant(container, "rfFwRow" .. slot .. "D")
    local ta, tb, tc, td = rowCells(r)
    setText(a, ta)
    setText(b, tb)
    setText(c, tc)
    setText(d, td)
    setVis(a, true); setVis(b, true); setVis(c, true); setVis(d, true)
end

local function clearHeaders(container)
    for _, id in ipairs({ "rfFwColA", "rfFwColB", "rfFwColC", "rfFwColD" }) do
        local el = findDescendant(container, id)
        setText(el, "")
        setVis(el, false)
    end
end

local function paintHeaders(container)
    local a = findDescendant(container, "rfFwColA")
    local b = findDescendant(container, "rfFwColB")
    local c = findDescendant(container, "rfFwColC")
    local d = findDescendant(container, "rfFwColD")
    -- REPAIR-214: the four headings follow the view. The CELLS keep the 213 geometry in every view,
    -- because three other guests render in the same pooled cells (NOTE-048).
    local ha, hb, hc, hd = headerTextsForView()
    setText(a, ha)
    setText(b, hb)
    setText(c, hc)
    setText(d, hd)
    setVis(a, true); setVis(b, true); setVis(c, true); setVis(d, true)
end

local function clearTable(container)
    for i = 1, ROWS_PER_PAGE do
        for _, c in ipairs({ "A", "B", "C", "D" }) do
            local el = findDescendant(container, "rfFwRow" .. i .. c)
            setText(el, "")
            setVis(el, false)
        end
    end
    setText(findDescendant(container, "rfFwMore"), "")
    setVis(findDescendant(container, "rfFwMore"), false)
    setText(findDescendant(container, "rfFwEmptyHint"), "")
    setVis(findDescendant(container, "rfFwEmptyHint"), false)
    setText(findDescendant(container, "rfFwHintTable"), "")
    setVis(findDescendant(container, "rfFwHintTable"), false)
    clearHeaders(container)
end

--- REPAIR-211: STATE OUR OWN GEOMETRY ON ENTRY. Every Table guest paints into the SAME shared door
--- elements and no host calls onHide, so whichever module ran last leaves its column X and width behind
--- (NpcRfPdaGuest.lua:612-615, and Income deliberately drops rfFwTableTitle to the bottom band). StockGuard
--- stated nothing, so its headers sat on another module's columns and the Farm/Site selector sat on the
--- header row.
---
--- The X and width below are the SHEET's own columns, so a heading always sits over the cell it names:
--- REPAIR-213 moved them in the door's row template to 0 / 360 / 580 / 840 (widths 340 / 200 / 240 / 272,
--- ending exactly on the 1112px row), and rfFwSheetBox is itself at x 10, hence the +10 here.
--- Y AND HEIGHT ARE HELD: each element's own current Y and height are read back and written unchanged, so
--- this can only ever move X and width. Positions are NORMALISED in FS25, so everything goes through
--- GuiUtils; a raw pixel integer would throw the element off the screen.
local SG_GRID_COLS = {
    { "A", "10px", "340px" },
    { "B", "370px", "200px" },
    { "C", "590px", "240px" },
    { "D", "850px", "272px" },
}
-- REPAIR-213: the selector is NOT placed from here any anymore, and SEL_X/SEL_Y/SEL_W/SEL_H are gone with
-- the call. REPAIR-211 moved the MultiTextOption itself, but MultiTextOptionElement:289 resizes only its
-- background child, so the two arrows and the value kept their own profile geometry and ended up outside the
-- frame. The door now wraps it in rfFwSelShell, a sized emptyPanel, and the profile's "100% + 56px" resolves
-- against that; this guest only ever sets visibility. Same for rfFwModeSelector in rfFwModeShell.
local _sgGridWarned = false

local function sgNormalizersPresent()
    return GuiUtils ~= nil and type(GuiUtils.getNormalizedXValue) == "function"
        and type(GuiUtils.getNormalizedYValue) == "function"
        and type(GuiUtils.getNormalizedScreenValues) == "function"
end

local function sgPlace(el, xPx, wPx, yPx, hPx)
    if el == nil then return end
    if type(el.setPosition) == "function" and el.position ~= nil then
        local x = GuiUtils.getNormalizedXValue(xPx, 0)
        local y = (yPx ~= nil) and GuiUtils.getNormalizedYValue(yPx, 0) or el.position[2]
        el:setPosition(x, y)
    end
    if wPx ~= nil and type(el.setSize) == "function" and el.size ~= nil then
        local norms = GuiUtils.getNormalizedScreenValues(wPx .. " " .. (hPx or "1px"))
        if type(norms) == "table" and norms[1] ~= nil then
            el:setSize(norms[1], (hPx ~= nil and norms[2] ~= nil) and norms[2] or el.size[2])
        end
    end
    if type(el.updateAbsolutePosition) == "function" then el:updateAbsolutePosition() end
end

--- Applied on every show. A literal 1..4 walk, not ipairs: NPC Favor records a hole in their table
--- truncating ipairs so only column A was ever placed.
local function applySgGrid(container)
    if not sgNormalizersPresent() then
        if not _sgGridWarned then
            _sgGridWarned = true
            print("[StockGuard] SgRfPdaGuest: GuiUtils normalizer absent - leaving the XML grid")
        end
        return
    end
    for i = 1, 4 do
        local c = SG_GRID_COLS[i]
        if c ~= nil then
            sgPlace(findDescendant(container, "rfFwCol" .. c[1]), c[2], c[3])
        end
    end
end

--- ===================================================================================================
--- REPAIR-216: the roomier bottom, and the 22px the page selector needs at the top.
---
--- Every element below is SHARED with DairyCore, FertilizerDepot and IncomeMod, none of which states its own
--- geometry, so StockGuard records each element's original position, size and textSize the first time it
--- touches it and puts them all back when it stops owning the page.
---
--- Restore does NOT happen in onHide. The host page says so itself at :1702 - "No host ever calls a guest
--- onHide" - and grep agrees: there is no call anywhere in any of the 11 copies. So the restore rides the
--- draw hook that REPAIR-214 already wired onto rfFwTableBlock: the first frame another module owns the page,
--- isActivePanel goes false and the originals go back. One frame of another guest's text at our sizes is
--- possible, which is honest and bounded, and is strictly better than a restore that never runs.
--- ===================================================================================================

--- Normalised screen values. TextElement:setTextSize assigns straight to self.textSize and calls updateSize
--- (extract gui/elements/TextElement.lua:375), and textSize at runtime is a NORMALISED height, not pixels -
--- the profile loader converts "21px" on the way in. Passing 21 would be 21 screens tall.
local function normY(px)
    if GuiUtils == nil or type(GuiUtils.getNormalizedScreenValues) ~= "function" then return nil end
    local norms = GuiUtils.getNormalizedScreenValues("0px " .. tostring(px) .. "px")
    if type(norms) ~= "table" then return nil end
    return norms[2]
end

--- The layout StockGuard imposes while it owns the page.
--- Headers drop from -40 to -56, the head rule from -64 to -80, and the sheet box from -60 to -82 at 458px
--- instead of 480. That frees the 0 to -52 band the page selector's MultiTextOption really occupies:
--- RF_WcSubnavSelector is "position 0px -10px" with "size 100% 42px", so it draws from -10 to -52, and its
--- arrows are a fixed 42px centred on it (fs25_buttonCircleArrowLeft, anchorMiddleLeft). The cost is 22px of
--- list, under half of one 48px row.
local SG_LAYOUT = {
    { id = "rfFwColA", y = "-56px" },
    { id = "rfFwColB", y = "-56px" },
    { id = "rfFwColC", y = "-56px" },
    { id = "rfFwColD", y = "-56px" },
    { id = "rfFwRuleHead", y = "-80px" },
    { id = "rfFwSheetBox", y = "-82px", h = "458px" },
    -- The bottom text, roomier, as Wizard asked: "a little bigger and give it some more room to breathe".
    { id = "rfFwMore", x = "10px", y = "-552px", w = "1120px", h = "30px", textSize = 22 },
    { id = "rfFwSheetBand", x = "10px", y = "-596px", w = "1120px", h = "150px", textSize = 21 },
}

--- id -> { position, size, textSize } as the door declared them. Captured once, before anything is changed.
local _sgGeomOriginals = nil
local _sgLayoutApplied = false

local function rememberOriginals(container)
    if _sgGeomOriginals ~= nil then return end
    _sgGeomOriginals = {}
    for _, spec in ipairs(SG_LAYOUT) do
        local el = findDescendant(container, spec.id)
        if el ~= nil then
            _sgGeomOriginals[spec.id] = {
                position = (type(el.position) == "table") and { el.position[1], el.position[2] } or nil,
                size = (type(el.size) == "table") and { el.size[1], el.size[2] } or nil,
                textSize = el.textSize,
            }
        end
    end
end

local function applySgLayout(container)
    if not sgNormalizersPresent() then return end
    rememberOriginals(container)
    for _, spec in ipairs(SG_LAYOUT) do
        local el = findDescendant(container, spec.id)
        if el ~= nil then
            -- Position: only the components this spec names, so the header grid's own X and width survive.
            if (spec.x ~= nil or spec.y ~= nil) and type(el.setPosition) == "function"
                and type(el.position) == "table" then
                local x = (spec.x ~= nil) and GuiUtils.getNormalizedXValue(spec.x, 0) or el.position[1]
                local y = (spec.y ~= nil) and GuiUtils.getNormalizedYValue(spec.y, 0) or el.position[2]
                el:setPosition(x, y)
            end
            if (spec.w ~= nil or spec.h ~= nil) and type(el.setSize) == "function"
                and type(el.size) == "table" then
                local norms = GuiUtils.getNormalizedScreenValues((spec.w or "1px") .. " " .. (spec.h or "1px"))
                if type(norms) == "table" then
                    local w = (spec.w ~= nil and norms[1] ~= nil) and norms[1] or el.size[1]
                    local h = (spec.h ~= nil and norms[2] ~= nil) and norms[2] or el.size[2]
                    el:setSize(w, h)
                end
            end
            if spec.textSize ~= nil and type(el.setTextSize) == "function" then
                local ts = normY(spec.textSize)
                if ts ~= nil then el:setTextSize(ts) end
            end
            if type(el.updateAbsolutePosition) == "function" then el:updateAbsolutePosition() end
        end
    end
    _sgLayoutApplied = true
end

--- Put the door's own numbers back. Called from the draw hook the moment another module owns the page, and
--- from onHide as well for the day a host starts calling it.
restoreSgLayout = function(container)
    if _sgGeomOriginals == nil or not _sgLayoutApplied then return end
    for id, g in pairs(_sgGeomOriginals) do
        local el = findDescendant(container, id)
        if el ~= nil then
            if g.position ~= nil and type(el.setPosition) == "function" then
                el:setPosition(g.position[1], g.position[2])
            end
            if g.size ~= nil and type(el.setSize) == "function" then
                el:setSize(g.size[1], g.size[2])
            end
            if g.textSize ~= nil and type(el.setTextSize) == "function" then
                el:setTextSize(g.textSize)
            end
            if type(el.updateAbsolutePosition) == "function" then el:updateAbsolutePosition() end
        end
    end
    _sgLayoutApplied = false
end

--- REPAIR-209: every row goes into the door's one SmoothList (rfFwSheetList) instead of the eight fixed
--- rfFwRow* lines, so a 14 row snapshot is reachable by wheel and slider rather than counted in a footer
--- nobody could act on. The 32 static cells stay declared in the door because Dairy, NPC Favor and Pro
--- Staff hide them by id; this guest simply stops writing to them. Same shape FdRfPdaGuest ships.
local _sheetRows = {}
local _sheetContainer = nil
local _sheetSig = nil

--- A cheap content fingerprint of the painted rows, used only to decide whether the list has to be
--- reloaded at all.
--- REPAIR-214: the view and the drilled product join the signature. Without them, switching from the
--- planner to a one-row drill-down whose single row happened to produce the same four strings would look
--- like "nothing changed" and the sheet would never reload.
local function rowsSignature(rows)
    local parts = {}
    parts[#parts + 1] = tostring(_view) .. "" .. tostring(_drillProduct)
    for i = 1, #rows do
        local r = rows[i]
        parts[#parts + 1] = table.concat({ tostring(r[1]), tostring(r[2]), tostring(r[3]),
                                           tostring(r[4]) }, "")
    end
    return tostring(#rows) .. "" .. table.concat(parts, "")
end

local sgSheetSource = {}

function sgSheetSource:getNumberOfItemsInSection(list, section)
    return #_sheetRows
end

function sgSheetSource:populateCellForItemInSection(list, section, index, cell)
    if cell == nil or type(cell.getDescendantByName) ~= "function" then return end
    local row = _sheetRows[index]
    if row == nil then return end
    setText(cell:getDescendantByName("rfFwSheetA"), row[1])
    setText(cell:getDescendantByName("rfFwSheetB"), row[2])
    setText(cell:getDescendantByName("rfFwSheetC"), row[3])
    setText(cell:getDescendantByName("rfFwSheetD"), row[4])
end

--- setDataSource by IDENTITY, so this guest never inherits whichever Table guest painted last, then
--- setDelegate explicitly because the XML loader made the host page the delegate, and reloadData only
--- once the engine says the list is loaded. Called from the show and selection paths only: no timer and
--- no light tick ever reaches it, which is the hang fence.
local function syncSheet(container, rows)
    _sheetRows = rows or {}
    -- The host hands onSheetRow an index and nothing else, so remember the container it was painted into.
    _sheetContainer = container
    local list = findDescendant(container, "rfFwSheetList")
    local box = findDescendant(container, "rfFwSheetBox")
    if list == nil then
        setVis(box, false)
        return false
    end
    if list.dataSource ~= sgSheetSource then
        -- REPAIR-211: the sheet is shared. If it was not ours when we arrived, another Table guest painted
        -- these cells and our content fingerprint no longer describes what is on screen, so it must not be
        -- allowed to skip the reload. This is what left Income's or Dairy's rows under a StockGuard detail
        -- band: the rows had not changed since OUR last paint, so the gate said nothing to do.
        _sheetSig = nil
        if type(list.setDataSource) == "function" then
            list:setDataSource(sgSheetSource)
        end
    end
    if type(list.setDelegate) == "function" then
        list:setDelegate(sgSheetSource)
    end
    setVis(box, #_sheetRows > 0)
    -- ANTI-THRASH FENCE. The host calls onShow with lightOnly TRUE on every timed refresh
    -- (RfPdaMenuPage: pcall(active.onShow, placeholder, not (rebuildLists or enteringSg))), so a flat
    -- "never reload on a light tick" rule would paint this sheet once on entry and then freeze it, and a
    -- changed amount would never appear. The rows are reloaded only when their CONTENT changed instead:
    -- that stops the repeated reload the fence exists to prevent, on the light path AND the full one,
    -- while keeping the figures live. No timer calls this.
    local sig = rowsSignature(_sheetRows)
    if sig ~= _sheetSig then
        _sheetSig = sig
        if list.isLoaded and type(list.reloadData) == "function" then
            pcall(list.reloadData, list)
        end
    end
    return true
end

local function clearSheet(container)
    _sheetRows = {}
    _sheetSig = nil
    setVis(findDescendant(container, "rfFwSheetBox"), false)
    setVis(findDescendant(container, "rfFwSheetBand"), false)
    setText(findDescendant(container, "rfFwSheetBand"), "")
end

--- REPAIR-209: the sheet shows every row, so focus is a single index into the row list. The start argument
--- is kept because existing call sites pass one, and is deliberately ignored.
--- REPAIR-214: that list is now _viewRows, which is the planner's grouped products, a product's holders, or
--- its buyers, depending on the view. _paintRows stays the raw snapshot, because the side panel totals and
--- the unit probe are about the whole farm rather than whatever the player has drilled into.
local function focusedRow(start)
    local n = #_viewRows
    if n <= 0 then return nil end
    if _focusSlot < 1 then _focusSlot = 1 end
    if _focusSlot > n then _focusSlot = n end
    return _viewRows[_focusSlot]
end

--- REPAIR-209: the focused row in full, in rfFwSheetBand (RF_SheetBand carries textMaxNumLines 3), so the
--- label no longer has to be paged through HINT_CHARS at a time with comma and period. Line 1 is the whole
--- label, line 2 the facts, line 3 what each action can do and why not when it cannot.
--- REPAIR-214: the planner's band. Four lines and no spare pixel, which is why each one is one fact:
--- what and how much, the best price and who pays it, value now against the seasonal estimate, and how many
--- holders it is spread over. "est." is on screen deliberately: the peak ratio compares a raw monthly factor
--- with an interpolated current one, so it is an approximation and says so.
local function paintPlannerBand(container, band)
    local g = _viewRows[_focusSlot]
    if type(g) ~= "table" or g.fillTypeName == nil then
        setText(band, "")
        setVis(band, false)
        return
    end
    local lines = {}
    local first = string.format(tr("sg5_detail_prefix", "Row %d: "), _focusSlot)
        .. tostring(g.title) .. " - " .. formatAmount(g.amount, g.amountUnit)
    if (g.skipped or 0) > 0 then
        -- Never added litres to kilograms; say so rather than quietly leaving them out of the sum.
        first = first .. "  " .. string.format(
            tr("sg6_detail_other_units", "(%d more in another unit, not added)"), g.skipped)
    end
    lines[#lines + 1] = first

    if g.price == nil then
        lines[#lines + 1] = tr("sg6_detail_no_buyer", "No buyer on the map takes this product.")
    else
        local t2 = trendLabel(g.trend)
        local priceLine = string.format(tr("sg6_detail_best", "Best %s%s at %s"),
            priceText(g.price), (t2 ~= "" and (" " .. t2) or ""), tostring(g.buyer))
        if (g.tied or 0) > 1 then
            priceLine = priceLine .. "  |  " .. string.format(
                tr("sg6_detail_tied", "same price at %d buyers"), g.tied)
        end
        lines[#lines + 1] = priceLine
    end

    local valueLine = string.format(tr("sg6_detail_value_now", "Value now %s"), moneyText(g.value))
    local peak = (g.price ~= nil) and peakFor(g.fillTypeName, g.price) or nil
    if peak ~= nil and peak.priceAtPeak ~= nil and g.amount ~= nil then
        valueLine = valueLine .. "  |  " .. string.format(
            tr("sg6_detail_value_peak", "est. %s at the %s peak"),
            moneyText(peak.priceAtPeak * g.amount), tostring(peak.month or ("period " .. tostring(peak.period))))
    end
    lines[#lines + 1] = valueLine

    local lastLine = string.format(tr("sg6_detail_holders", "%d holders"), g.holders or 0)
    if (g.buyerCount or 0) > 0 then
        lastLine = lastLine .. "  |  " .. string.format(tr("sg6_detail_buyers", "%d buyers"), g.buyerCount)
    end
    lines[#lines + 1] = lastLine

    setText(band, table.concat(lines, "\n"))
    setVis(band, true)
end

--- One buyer's band in the Buyers view.
local function paintBuyerBand(container, band)
    local b = _viewRows[_focusSlot]
    if type(b) ~= "table" or b.name == nil then
        setText(band, "")
        setVis(band, false)
        return
    end
    local t2 = trendLabel(b.trend)
    local lines = {
        string.format(tr("sg5_detail_prefix", "Row %d: "), _focusSlot) .. tostring(b.name),
        string.format(tr("sg6_buyer_price", "Price %s%s"),
            priceText(b.price), (t2 ~= "" and (" " .. t2) or "")),
        string.format(tr("sg6_buyer_value", "Our stock would fetch %s here"), moneyText(b.value)),
    }
    setText(band, table.concat(lines, "\n"))
    setVis(band, true)
end

local function paintDetailHint(container, start)
    local band = findDescendant(container, "rfFwSheetBand")
    local hint = findDescendant(container, "rfFwHintTable")
    -- REPAIR-214: the planner and the Buyers view have their own bands. The Storages view is a list of real
    -- STOCK rows, so it keeps the 213 band below unchanged, including its properties line.
    if _view == VIEW_PLANNER then
        setText(hint, "")
        setVis(hint, false)
        paintPlannerBand(container, band)
        _hintSkip = 0
        return false
    end
    if _view == VIEW_BUYERS then
        setText(hint, "")
        setVis(hint, false)
        paintBuyerBand(container, band)
        _hintSkip = 0
        return false
    end
    local row = focusedRow(start)
    if row == nil or type(row.label) ~= "string" or row.label == "" then
        setText(band, "")
        setVis(band, false)
        _hintSkip = 0
        return false
    end
    local kind = row.rowKind or "STOCK"
    local lines = {}
    lines[#lines + 1] = string.format(tr("sg5_detail_prefix", "Row %d: "), _focusSlot)
        .. (rowFullName(row) or row.label)

    local facts = {}
    facts[#facts + 1] = string.format(tr("sg5_detail_kind", "Kind: %s"), rowKindLabel(kind))
    if kind == "CARRIER" then
        if row.capacityKnown and row.capacity ~= nil then
            facts[#facts + 1] = string.format(tr("sg5_detail_capacity", "Capacity: %s"),
                formatAmount(row.capacity, row.capacityUnit))
        end
    elseif kind == "PROCESS" then
        facts[#facts + 1] = string.format(tr("sg5_detail_state", "State: %s"), processStateLabel(row))
    else
        facts[#facts + 1] = string.format(tr("sg5_detail_amount", "Amount: %s"),
            formatAmount(row.amount, row.amountUnit))
        facts[#facts + 1] = string.format(tr("sg5_detail_knowledge", "Knowledge: %s"),
            knowledgeLabel(row.knowledge))
    end
    -- REPAIR-213: this fact reports the FARM/SITE selection, not a map position. It was called "Where",
    -- which is now the name of a column that really does mean a place, so it is "Scope" here.
    facts[#facts + 1] = string.format(tr("sg5_detail_scope", "Scope: %s"), selectionSummary())
    lines[#lines + 1] = table.concat(facts, "  |  ")

    -- Each published action with its availability, and the reason when it is not available, so a greyed
    -- chip is never a mystery.
    if type(row.actions) == "table" and #row.actions > 0 then
        local acts = {}
        for _, a in ipairs(row.actions) do
            if type(a) == "table" then
                local one = actionVerb(a)
                if a.available ~= true then
                    local why = a.reasonCode or ""
                    if why == "CONTEXT_ABSENT" then
                        one = one .. ": " .. tr("sg5_action_context_absent", "provider absent")
                    elseif why == "ARGS_FORMS_ABSENT" then
                        one = one .. ": " .. tr("sg5_action_forms_absent", "needs arguments")
                    elseif why ~= "" then
                        one = one .. ": " .. tostring(why)
                    else
                        one = one .. ": " .. tr("sg5_action_unavailable", "unavailable")
                    end
                end
                acts[#acts + 1] = one
            end
        end
        if #acts > 0 then
            lines[#lines + 1] = string.format(tr("sg5_detail_actions", "Actions: %s"),
                table.concat(acts, "  |  "))
        end
    end

    -- REPAIR-213: disclosed properties, which the adapter used to drop whole. Readable entries only: the
    -- propertyId is routed through an l10n key with a humanised English fallback, so a raw SG id can never
    -- reach the screen, and the record's producerId, schemaVersion and revisions are not shown at all. The
    -- band is capped at four lines (the door was widened from three for this), so three entries then a
    -- count is the whole budget.
    if type(row.properties) == "table" and #row.properties > 0 then
        local shown = {}
        for i = 1, math.min(3, #row.properties) do
            shown[#shown + 1] = propertySummary(row.properties[i])
        end
        local extra = #row.properties - #shown
        local text = table.concat(shown, "  |  ")
        if extra > 0 then
            text = text .. "  " .. string.format(tr("sg5_detail_props_more", "+%d more"), extra)
        end
        lines[#lines + 1] = string.format(tr("sg5_detail_props", "Properties: %s"), text)
    end

    setText(hint, "")
    setVis(hint, false)
    setText(band, table.concat(lines, "\n"))
    setVis(band, true)
    _hintSkip = 0
    return false
end

local function hintCanAdvance()
    local start = (_pageIndex - 1) * ROWS_PER_PAGE + 1
    local row = focusedRow(start)
    if row == nil or type(row.label) ~= "string" then return false, false end
    local byteStart = utf8Offset(row.label, _hintSkip)
    local slice = row.label:sub(byteStart)
    local _, trunc = utf8Truncate(slice, HINT_CHARS)
    return trunc == true, _hintSkip > 0
end

--- REPAIR-213: one row's engine category, for the totals line.
--- The design asked for "Crops / Livestock / Supplies". FS25 has no such taxonomy: the categories in
--- data/maps/maps_fillTypes.xml are machine-capability groups (BULK, LIQUID, PIECE, WINDROW, COMBINE,
--- SPRAYER, FARMSILO and so on). Rather than invent a mapping and mislabel a row, the totals use the
--- engine's own membership through getIsFillTypeInCategory and name the groups after it. WINDROW is tested
--- before BULK because DRYGRASS_WINDROW is in both and the windrow is the more specific of the two.
--- Anything the engine does not categorise - BALE_NET and BALE_WRAP are in none - counts as Other, never as
--- a guess. The category list is read, not assumed: a name absent from nameToCategoryIndex simply never
--- matches.
local SG_CATEGORY_ORDER = {
    { "WINDROW", "sg5_cat_windrow", "Windrow" },
    { "LIQUID", "sg5_cat_liquid", "Liquid" },
    { "PIECE", "sg5_cat_piece", "Piece" },
    { "BULK", "sg5_cat_bulk", "Bulk" },
}

local function rowCategoryKey(r)
    if type(r) ~= "table" or type(r.materialRef) ~= "table" then return nil end
    local name = r.materialRef.fillTypeName
    if type(name) ~= "string" or name == "" then return nil end
    local ftm = g_fillTypeManager
    if ftm == nil or type(ftm.getFillTypeIndexByName) ~= "function"
        or type(ftm.getIsFillTypeInCategory) ~= "function" then
        return nil
    end
    local ok, index = pcall(ftm.getFillTypeIndexByName, ftm, name)
    if not ok or index == nil then return nil end
    for i = 1, #SG_CATEGORY_ORDER do
        local cat = SG_CATEGORY_ORDER[i]
        local okCat, inCat = pcall(ftm.getIsFillTypeInCategory, ftm, index, cat[1])
        if okCat and inCat == true then return i end
    end
    return nil
end

--- REPAIR-213: the side panel. rfSideInfoBody is a leaf Text with textMaxNumLines 36 at 16px in a
--- 368x644 shell, so there is room; the host blanks it for every framework module inside
--- _syncHostGuestChrome, which refreshContent calls BEFORE this guest's onShow on both the full and the
--- lightOnly path, so writing it here cannot be undone by the host on the same tick and cannot blink.
--- The totals live here rather than on rfFwMore, which is a single 20px line of RF_TreatTargetLine with no
--- textMaxNumLines and already carries the count and the keys: appending to it would have clipped.
--- This guest does NOT touch rfSideInfoShell. Hiding or showing an ancestor is what blanked the whole page
--- in REPAIR-209.
local function paintSideInfo(container, paint)
    local body = findDescendant(container, "rfSideInfoBody")
    if body == nil then return end
    local out = {}
    out[#out + 1] = tr("sg5_side_intro",
        "Stock your farm can see, with what StockGuard knows about each entry.")
    out[#out + 1] = tr("sg5_side_unknown",
        "\"unknown\" is the provenance, not the amount: it means no reading has been recorded for that "
        .. "stock yet. The figure beside it is still the live one.")
    out[#out + 1] = tr("sg5_side_keys",
        "Comma and full stop move the focused row. The wheel or the slider scrolls the list.")

    if type(paint) == "table" and paint.state == "READY" and #_paintRows > 0 then
        local holders, products, counts, other = {}, {}, {}, 0
        local holderCount, productCount = 0, 0
        for i = 1, #_paintRows do
            local r = _paintRows[i]
            local cid = r.carrierId
            if cid ~= nil and holders[cid] == nil then
                holders[cid] = true
                holderCount = holderCount + 1
            end
            local mat = (type(r.materialRef) == "table") and r.materialRef.fillTypeName or nil
            if mat ~= nil and products[mat] == nil then
                products[mat] = true
                productCount = productCount + 1
            end
            local key = rowCategoryKey(r)
            if key == nil then
                other = other + 1
            else
                counts[key] = (counts[key] or 0) + 1
            end
        end
        out[#out + 1] = string.format(
            tr("sg5_side_totals", "%d entries, %d holders, %d products."),
            #_paintRows, holderCount, productCount)

        -- REPAIR-214: what the farm is worth, and what it would be worth if every product sold in its own
        -- best month. The second number is an estimate and says so, for the reason paintPlannerBand gives.
        local valueNow, valuePeak, priced = 0, 0, 0
        for _, g in ipairs(_plannerRows) do
            if g.value ~= nil then
                priced = priced + 1
                valueNow = valueNow + g.value
                local peak = peakFor(g.fillTypeName, g.price)
                if peak ~= nil and peak.priceAtPeak ~= nil then
                    valuePeak = valuePeak + peak.priceAtPeak * g.amount
                else
                    valuePeak = valuePeak + g.value
                end
            end
        end
        if priced > 0 then
            out[#out + 1] = string.format(
                tr("sg6_side_value", "Worth %s now, est. %s at each product's peak month."),
                moneyText(valueNow), moneyText(valuePeak))
        end

        local parts = {}
        for i = 1, #SG_CATEGORY_ORDER do
            if (counts[i] or 0) > 0 then
                parts[#parts + 1] = string.format("%s %d",
                    tr(SG_CATEGORY_ORDER[i][2], SG_CATEGORY_ORDER[i][3]), counts[i])
            end
        end
        if other > 0 then
            parts[#parts + 1] = string.format("%s %d", tr("sg5_cat_other", "Other"), other)
        end
        if #parts > 0 then
            out[#out + 1] = table.concat(parts, " / ")
        end

        -- REPAIR-214: the two lists that make this a planner rather than a report. Only holders whose
        -- capacity is actually KNOWN can appear: a percentage computed against an unknown capacity would be
        -- an invention, and this is the panel a player would act on.
        -- REPAIR-215: one entry per HOLDER, not per stock row, and the holder is named by its label rather
        -- than by whichever product happened to be first. A silo holding three grains appears once.
        -- REPAIR-215: one entry per HOLDER, and only holders whose figure is certain. When none is, both
        -- lines are omitted entirely rather than printed empty (NOTE-052).
        local full, empty, seenHolder = {}, {}, {}
        for i = 1, #_paintRows do
            local r = _paintRows[i]
            local hk = holderKeyOf(r)
            if hk ~= nil and seenHolder[hk] == nil then
                local amt, cap, _unit, pct = holderFillOf(r)
                if amt ~= nil then
                    seenHolder[hk] = true
                    local name = shortLabel(r.label)
                    if pct >= 90 then
                        full[#full + 1] = { name = name, pct = pct }
                    elseif pct <= 10 then
                        empty[#empty + 1] = { name = name, pct = pct }
                    end
                end
            end
        end
        local function listLine(key, fallback, list, highestFirst)
            if #list == 0 then return nil end
            table.sort(list, function(a, b)
                if highestFirst then return a.pct > b.pct end
                return a.pct < b.pct
            end)
            local shown = {}
            for i = 1, math.min(5, #list) do
                shown[#shown + 1] = string.format("%s %d%%", list[i].name, math.floor(list[i].pct + 0.5))
            end
            local line = string.format(tr(key, fallback), table.concat(shown, ", "))
            if #list > 5 then
                line = line .. " " .. string.format(tr("sg6_side_and_more", "and %d more"), #list - 5)
            end
            return line
        end
        local fullLine = listLine("sg6_side_nearly_full", "Nearly full: %s", full, true)
        local emptyLine = listLine("sg6_side_nearly_empty", "Nearly empty: %s", empty, false)
        if fullLine ~= nil then out[#out + 1] = fullLine end
        if emptyLine ~= nil then out[#out + 1] = emptyLine end
    end

    setText(body, table.concat(out, "\n\n"))
end

--- REPAIR-213: a ONE-SHOT probe, because the Esc column showed "17.0 t" for a stock the save holds as
--- 20000 LITRE while Oat and Wheat, also 20000 LITRE, showed "20000 L". formatAmount is "%.0f %s" over a
--- unit token from SGRecords.AMOUNT_UNITS, which has no tonne and no metre, so those strings cannot have
--- come from this file and the open question is whose they are. This prints what the row actually carries
--- beside what the engine says about the same fill type. massPerLiter and unitShort are read defensively
--- with tostring: they are attributes of data/maps/maps_fillTypes.xml, not accessors I have proven on the
--- runtime descriptor, so a nil here is itself the answer.
local _unitProbeDone = false

local function unitProbe(rows)
    if _unitProbeDone or type(rows) ~= "table" or #rows == 0 then return end
    _unitProbeDone = true
    local ftm = g_fillTypeManager
    for i = 1, math.min(4, #rows) do
        local r = rows[i]
        local name = (type(r.materialRef) == "table") and r.materialRef.fillTypeName or nil
        local mass, unitShort, title = "no-filltype", "no-filltype", "no-filltype"
        if name ~= nil and ftm ~= nil and type(ftm.getFillTypeByName) == "function" then
            local ok, ft = pcall(ftm.getFillTypeByName, ftm, name)
            if ok and type(ft) == "table" then
                mass = tostring(ft.massPerLiter)
                unitShort = tostring(ft.unitShort)
                title = tostring(ft.title)
            else
                mass, unitShort, title = "lookup-failed", "lookup-failed", "lookup-failed"
            end
        end
        print(string.format(
            "[StockGuard] unit-probe: row=%d fillType=%s amount=%s unit=%s capacity=%s capacityUnit=%s "
            .. "capacityKnown=%s engineMassPerLiter=%s engineUnitShort=%s engineTitle=%s holder=%s",
            i, tostring(name), tostring(r.amount), tostring(r.amountUnit), tostring(r.capacity),
            tostring(r.capacityUnit), tostring(r.capacityKnown), mass, unitShort, title,
            tostring(r.label)))
    end
end

local function paintTable(container, paint)
    clearTable(container)
    -- REPAIR-214: the price and station caches live for one paint too, and for the same reason: a price
    -- held across paints is a price that has already moved, and a station list held across paints misses a
    -- shop the player just built.
    _priceCache = {}
    _stationCache = nil
    -- REPAIR-213: the farmland cache lives for ONE paint, not for the session. Keeping it longer would have
    -- gone stale the first time a farmland was bought or renamed, and the only guarantee that is needed is
    -- that two rows standing on the same spot do not each ask the manager.
    _whereCache = {}
    -- REPAIR-214: group BEFORE the side panel, because the panel's totals and its nearly-full and
    -- nearly-empty lists are computed from _plannerRows. Grouping inside the READY branch below left the
    -- panel reading last paint's groups, which on a first show is an empty table.
    -- REPAIR-215: the per-carrier fill map, before anything reads it. Same per-paint life as the caches
    -- above, for the same reason.
    rebuildHolderFill(_paintRows)
    _plannerRows = groupByProduct(_paintRows)
    paintSideInfo(container, paint)
    -- REPAIR-210: a REPAIR-209 line here hid rfFrameworkGlanceShell, believing it to be an empty left
    -- rail. It is the PARENT of rfFwTableBlock (rfHostPlaceholder > rfFrameworkGlanceShell >
    -- rfFwTableBlock > rfFwSheetBox) and its only two children are rfFwStatusBlock and rfFwTableBlock, so
    -- hiding it blanked the whole Stock page: no title, no headers, no rows. NOTHING in this guest may
    -- hide an ancestor of the table. The empty panel in Wizard's screenshot is rfSideInfoShell, whose one
    -- text leaf rfSideInfoBody the host deliberately blanks for every framework module, and that is not
    -- this guest's to hide either.
    local title = findDescendant(container, "rfFwTableTitle")
    local empty = findDescendant(container, "rfFwEmptyHint")
    local more = findDescendant(container, "rfFwMore")
    local tableBlock = findDescendant(container, "rfFwTableBlock")
    setVis(tableBlock, true)

    local state = paint.state or "UNAVAILABLE"

    if state == "READY" and paint.usable and paint.rowCount > 0 then
        -- REPAIR-211: the shared rfFwTableTitle is blanked and hidden, not painted. The host kills it for
        -- every module except Income and Depot (RfPdaMenuPage.lua:1918-1921, "rfPageTitle owns module
        -- name"), and DairyCore, NPCFavor and ProStaffCoOp each blank and hide it themselves. StockGuard
        -- was the only guest still painting it, which is why "FARM STOCK (14)" appeared in the middle of
        -- the table: it was sitting where Income had left the element, not where this page put it.
        setText(title, "")
        setVis(title, false)
        setVis(empty, false)
        -- REPAIR-216: the layout goes FIRST, because rememberOriginals has to capture the door's own
        -- numbers before applySgGrid overwrites the header widths with StockGuard's. Restoring a width we
        -- had already changed would leave our grid on Dairy's page. applySgGrid only sets X and width, so
        -- the Y this applies survives it.
        applySgLayout(container)
        applySgGrid(container)
        -- REPAIR-214: the groups were built at the top of this function, before the side panel needed
        -- them; the view's own rows are derived from them here.
        _viewRows = buildViewRows()
        if _view ~= VIEW_PLANNER and #_viewRows == 0 then
            -- The product the player drilled into has gone (sold, or the snapshot changed under them).
            -- Falling back to the planner is the only honest thing: an empty drill-down with a heading
            -- naming a product that is no longer there reads as a bug.
            _view = VIEW_PLANNER
            _drillProduct = nil
            _drillTitle = nil
            _viewRows = _plannerRows
            _focusSlot = 1
        end
        paintHeaders(container)
        wireChipPaint(container)
        unitProbe(_paintRows)

        -- REPAIR-209: every row goes onto the scrolling sheet. The eight static slots stay blank and
        -- hidden, so no row is ever counted but unreachable again.
        local start = 1
        local cells = {}
        for i = 1, #_viewRows do
            local ca, cb, cc, cd = cellsForViewRow(_viewRows[i])
            cells[i] = { ca, cb, cc, cd }
        end
        syncSheet(container, cells)

        if _focusSlot < 1 then _focusSlot = 1 end
        if _focusSlot > #_viewRows then _focusSlot = math.max(1, #_viewRows) end

        -- The count line names the keys, because this keyboard route existed before this build and no
        -- player could have known it: comma and period step the focus, and the sheet scrolls by wheel or
        -- slider.
        -- The summary the title used to carry now rides the count line, which is already on screen and
        -- already reads well.
        local moreParts = {}
        -- REPAIR-214: the count line names the VIEW, so "Storages: Hay (3)" tells the player where they
        -- are without needing the chips to be the only clue.
        moreParts[#moreParts + 1] = countLineForView(paint.rowCount)
        moreParts[#moreParts + 1] = string.format(
            tr("sg5_sheet_count_hint", "%d items - scroll, or , and . to move"), #_viewRows)
        if paint.nextPageCursor ~= nil then
            moreParts[#moreParts + 1] = tr("sg5_more_pages", "More stock pages available.")
        elseif #_cursorTrail > 0 then
            moreParts[#moreParts + 1] = tr("sg5_page_end", "End of stock pages.")
        end
        if #moreParts > 0 then
            setText(more, table.concat(moreParts, " "))
            setVis(more, true)
        end
        paintDetailHint(container, start)
        return
    end

    -- Not READY, so there is nothing to list: drop the sheet here rather than at the top of the paint,
    -- because clearing it resets the content signature and would make every light tick look like a change.
    setText(title, "")
    setVis(title, false)
    clearSheet(container)
    clearHeaders(container)
    if state == "READY" and paint.filteredOnly then
        setText(title, tr("sg5_filtered_title", "Stock"))
        setText(empty, tr(
            "sg5_filtered_body",
            "No stock lines on this page."
        ))
        setVis(empty, true)
        if paint.nextPageCursor ~= nil then
            setText(more, tr("sg5_more_pages", "More stock pages available."))
            setVis(more, true)
        end
    elseif state == "READY" and paint.readyEmpty then
        setText(title, tr("sg5_ready_empty_title", "Stock"))
        setText(empty, tr("sg5_ready_empty_body", "Nothing listed in this stock view yet. That does not mean the farm has no goods."))
        setVis(empty, true)
    elseif state == "WAITING" or (_pendingRequest and state ~= "DENIED" and state ~= "ERROR" and state ~= "UNAVAILABLE" and state ~= "TERMINAL") then
        setText(title, tr("sg5_pending_title", "Stock"))
        setText(empty, tr("sg5_pending_body", "Updating stock list..."))
        setVis(empty, true)
    elseif state == "DENIED" then
        setText(title, tr("sg5_denied_title", "Stock"))
        setText(empty, tr("sg5_denied_body", "You cannot view this stock from here."))
        setVis(empty, true)
    else
        setText(title, tr("sg5_unavailable_title", "Stock"))
        setText(empty, tr("sg5_unavailable_body", "Stock is not available right now. Try again in a moment."))
        setVis(empty, true)
    end
end

local function resetPagingLocal()
    _pageIndex = 1
    _focusSlot = 1
    _hintSkip = 0
    _paintRows = {}
    _lastPaint = nil
end

local function resetTransportTrail()
    _cursorTrail = {}
    _requestedCursor = nil
    _lastRequestedCursor = nil
end

local function handleFarmTransition(farmId)
    local changed = false
    if _hasFarmSeen then
        if _lastFarmId ~= farmId then changed = true end
    else
        _hasFarmSeen = true
        if farmId == nil then changed = true end
    end
    if changed and SGEscClientAdapter ~= nil then
        SGEscClientAdapter.invalidateLocal(g_currentMission, "FARM_CHANGED")
        _pendingRequest = false
        resetPagingLocal()
        resetTransportTrail()
        -- Clear painted private data immediately, before any new host reply.
        if _lastContainer ~= nil then
            clearTable(_lastContainer)
        end
    end
    _lastFarmId = farmId
    return changed
end

local function requestCursor(cursor)
    -- Hold host requests during door open until one authoritative entry request runs.
    if _entryHold then
        return false
    end
    if _pendingRequest then
        return false
    end
    if _lastRequestedCursor == cursor and _pendingRequest then
        return false
    end
    local opts = {}
    if cursor ~= nil then
        opts.pageCursor = cursor
    end
    -- Focused chemical entry: preserve navigationCarrierId on FARM requests without pageCursor.
    if cursor == nil and SGEscClientAdapter ~= nil
        and _selection ~= nil and _selection.selectionKind == "FARM" then
        local focus = SGEscClientAdapter.getFocusState(g_currentMission)
        if type(focus) == "table" and focus.mode == "FOCUSED"
            and type(focus.carrierId) == "string" and focus.carrierId ~= "" then
            opts.navigationCarrierId = focus.carrierId
        end
    end
    -- Route-level pending while paging: keep selection, only pageCursor changes.
    local ok = SGEscClientAdapter.requestSelection(g_currentMission, _selection, opts)
    _pendingRequest = ok and true or false
    _routePending = ok and true or false
    if ok then
        _requestedCursor = cursor
        _lastRequestedCursor = cursor
    end
    return ok
end

local function clearPrivateDisplay(reason)
    _paintRows = {}
    _lastPaint = nil
    resetPagingLocal()
    if reason == "SELECTION_CHANGED" then
        resetTransportTrail()
    end
    if _lastContainer ~= nil then
        clearTable(_lastContainer)
    end
    if SGEscClientAdapter ~= nil then
        SGEscClientAdapter.invalidateLocal(g_currentMission, reason or "SELECTION_CHANGED")
    end
    _pendingRequest = false
end

local function refreshSelectionOptions()
    if SGEscClientAdapter == nil then
        _selectionOptions = {
            { selection = { route = "STOCK", selectionKind = "FARM" }, available = true, label = "Farm" },
        }
        return _selectionOptions
    end
    _selectionOptions = SGEscClientAdapter.listSelectionOptions(g_currentMission)
    return _selectionOptions
end

local function selectionEquals(a, b)
    if a == nil or b == nil then return false end
    if a.selectionKind ~= b.selectionKind or (a.route or "STOCK") ~= (b.route or "STOCK") then
        return false
    end
    if a.selectionKind == "SITE" then return a.siteId == b.siteId end
    if a.selectionKind == "GROUND" then
        local fa, fb = a.groundFootprint, b.groundFootprint
        if type(fa) ~= "table" or type(fb) ~= "table" then return false end
        return fa.x == fb.x and fa.z == fb.z and fa.radius == fb.radius
    end
    if a.selectionKind == "LIBRARY" then
        return (a.libraryId or "@current") == (b.libraryId or "@current")
    end
    return true
end

local function applySelectionAt(index)
    local opts = refreshSelectionOptions()
    if #opts == 0 then return false end
    if index < 1 then index = #opts end
    if index > #opts then index = 1 end
    local choice = opts[index]
    if choice == nil then return false end
    if choice.available ~= true or type(choice.selection) ~= "table" then
        -- Skip unavailable: seek next available in direction later; here refuse.
        return false, choice.reasonCode or "SELECTION_UNAVAILABLE"
    end
    local nextSel = choice.selection
    local changed = not selectionEquals(_selection, nextSel)
    _selectionIndex = index
    -- Explicit unfocused FARM or named SITE clears physical intent even when selectionEquals
    -- (same-FARM while pending/focused must not leave intent alive for a late address pull-back).
    if nextSel.selectionKind == "FARM" or nextSel.selectionKind == "SITE" then
        if SGEscClientAdapter ~= nil then
            SGEscClientAdapter.clearPhysicalFocusIntent(g_currentMission, "EXPLICIT_SELECTION")
        end
        _stationWaiting = false
    end
    if changed then
        _selection = {
            route = nextSel.route,
            selectionKind = nextSel.selectionKind,
            siteId = nextSel.siteId,
        }
        clearPrivateDisplay("SELECTION_CHANGED")
    end
    return true, nil
end


--- Central snapshot refresh. farmChanged forces entry request (first host page).
--- REPAIR-212: nothing is painted while another module owns the page. The host hides this guest's FW chrome
--- on every refresh and only this guest shows it again, so a snapshot or cursor callback that lands after the
--- player has left STOCK would otherwise put the selector, the action chips or a live quote back on somebody
--- else's page. Permissive when the host cannot answer: a missing answer must never stop STOCK painting itself.
--- ------------------------------------------------------------------ the three pages
--- REPAIR-216: the selector slot carries the PAGE now, not a farm or a site. Products is the planner,
--- Storages and Buyers are the drill-downs, and they follow whichever product is focused on Products, the
--- way Market Dynamics' Contracts page follows the crop picked on Prices.
local SG_PAGES = {
    { view = VIEW_PLANNER, key = "sg6_page_products", fallback = "Products" },
    { view = VIEW_STORAGES, key = "sg6_page_storages", fallback = "Storages" },
    { view = VIEW_BUYERS, key = "sg6_page_buyers", fallback = "Buyers" },
}

local function pageIndexOfView()
    for i = 1, #SG_PAGES do
        if SG_PAGES[i].view == _view then return i end
    end
    return 1
end

local function pageTexts()
    local out = {}
    for i = 1, #SG_PAGES do
        out[i] = tr(SG_PAGES[i].key, SG_PAGES[i].fallback)
    end
    return out
end

--- Move to a page by its 1-based index, which is what the MultiTextOption hands the host. Both arrows arrive
--- here, because the host's only live path is onSelectionIndex: _rfFwSelectionStep, which would carry a
--- delta, is defined at RfPdaMenuPage.lua:3768 and called from nowhere in any of the 11 door copies.
local function gotoPage(index)
    local page = SG_PAGES[index]
    if page == nil then return false end
    if page.view == _view then return true end
    if page.view == VIEW_PLANNER then
        _view = VIEW_PLANNER
        _drillProduct = nil
        _drillTitle = nil
    else
        -- A drill-down page needs a product. The one focused on Products is the one it follows.
        if _drillProduct == nil then
            local g = (_view == VIEW_PLANNER) and _viewRows[_focusSlot] or nil
            if type(g) == "table" and g.fillTypeName ~= nil then
                _drillProduct = g.fillTypeName
                _drillTitle = g.title
            end
        end
        -- With no product at all the page still opens; its empty hint says why, because a selector that
        -- refuses to move is the dead control this page just had removed.
        _view = page.view
    end
    _focusSlot = 1
    _hintSkip = 0
    _sheetSig = nil
    if _lastContainer ~= nil and _lastPaint ~= nil then
        paintTable(_lastContainer, _lastPaint)
        paintCommandChrome(_lastContainer)
        -- Put the selector on the page we actually moved to. The engine sets its own state when the player
        -- clicks an arrow, but nothing does it when the page changes for any other reason.
        seedSelectionSelector(_lastContainer)
    end
    return true
end

isActivePanel = function()
    local host = getHost()
    if host == nil then return true end
    if type(host.getActivePanel) == "function" then
        local ok, active = pcall(host.getActivePanel, host)
        if ok and type(active) == "table" and active.id ~= nil then
            return active.id == PANEL_ID
        end
    end
    if host.activeModuleId ~= nil then
        return host.activeModuleId == PANEL_ID
    end
    return true
end

local function refreshSnapshot(container, lightOnly, farmChanged)
    if not isActivePanel() then return end
    local isLight = lightOnly == true
    if farmChanged then
        resetTransportTrail()
        requestCursor(nil)
        _pageIndex = 1
        _focusSlot = 1
        _hintSkip = 0
    elseif not isLight then
        requestCursor(_requestedCursor)
        _pageIndex = 1
        _focusSlot = 1
        _hintSkip = 0
    end

    local paint = (SGEscClientAdapter ~= nil) and SGEscClientAdapter.getPaintState(g_currentMission) or {
        state = "UNAVAILABLE", reasonKey = "NO_ADAPTER", usable = false,
        rows = {}, rowCount = 0, filteredNonStock = 0, filteredOnly = false,
        nextPageCursor = nil, pageCursor = nil,
    }
    if paint.state == "DENIED" or paint.state == "ERROR" or paint.state == "UNAVAILABLE" or paint.state == "TERMINAL"
        or paint.usable or paint.state == "READY" then
        _pendingRequest = false
    end
    if paint.state == "DENIED" or paint.state == "ERROR" then
        _paintRows = {}
        resetPagingLocal()
    else
        _paintRows = paint.rows or {}
    end
    -- Physical focus lifecycle on existing refresh: adopt pending once; validate FOCUSED address/owner.
    -- During openFromHostModule entry hold, do not adopt old pending or issue fallback requests
    -- (door selectModule -> notify -> onShow can race a newly resolved address before NEW focus applies).
    if SGEscClientAdapter ~= nil and not _entryHold then
        local focus = SGEscClientAdapter.getFocusState(g_currentMission)
        if type(focus) == "table" and focus.mode == "PENDING" and focus.ownerObject ~= nil then
            _stationWaiting = true
            local function resolveAddr(obj)
                return SGEscClientAdapter.resolveOwnerAddress(obj)
            end
            local adopted = SGEscClientAdapter.tryAdoptPendingAddress(g_currentMission, resolveAddr)
            if adopted then
                _stationWaiting = false
                paint = SGEscClientAdapter.getPaintState(g_currentMission) or paint
                if paint.state == "DENIED" or paint.state == "ERROR" then
                    _paintRows = {}
                else
                    _paintRows = paint.rows or {}
                end
            else
                local stillOk = SGEscClientAdapter.validatePhysicalFocus(g_currentMission)
                if not stillOk then
                    _stationWaiting = false
                    -- Fall back to unfocused FARM paint already requested / next paint.
                    paint = SGEscClientAdapter.getPaintState(g_currentMission) or paint
                end
            end
        elseif type(focus) == "table" and focus.mode == "FOCUSED" then
            local stillOk, why = SGEscClientAdapter.validatePhysicalFocus(g_currentMission)
            if not stillOk then
                _stationWaiting = false
                -- Explained fallback: clear intent already done; request plain FARM once.
                if why == "STATION_UNAVAILABLE" then
                    SGEscClientAdapter.requestSelection(g_currentMission, { route = "STOCK", selectionKind = "FARM" }, {})
                    _selection = { route = "STOCK", selectionKind = "FARM" }
                    paint = SGEscClientAdapter.getPaintState(g_currentMission) or paint
                    if paint.state == "DENIED" or paint.state == "ERROR" then
                        _paintRows = {}
                    else
                        _paintRows = paint.rows or {}
                    end
                end
            else
                _stationWaiting = false
            end
        end
    end

    _lastPaint = paint
    if container ~= nil then
        paintTable(container, paint)
        paintCommandChrome(container)
        if _stationWaiting then
            local empty = findDescendant(container, "rfFwEmptyHint")
            local title = findDescendant(container, "rfFwTableTitle")
            setText(title, tr("sg5_station_waiting_title", "Stock"))
            setText(empty, tr("sg5_station_waiting_body", "Waiting for this station address..."))
            setVis(empty, true)
        end
        seedSelectionSelector(container)
    end
    return paint
end

local function requestTransportNext()
    local paint = _lastPaint
    if paint == nil or paint.nextPageCursor == nil then
        return false
    end
    if _pendingRequest then
        return false
    end
    local nextCursor = paint.nextPageCursor
    -- Push current cursor (nil for first page) onto trail, then request next.
    _cursorTrail[#_cursorTrail + 1] = (_requestedCursor ~= nil) and _requestedCursor or false
    resetPagingLocal()
    if _lastContainer ~= nil then
        clearTable(_lastContainer)
    end
    local ok = requestCursor(nextCursor)
    if not ok then
        _cursorTrail[#_cursorTrail] = nil
        return false
    end
    if _lastContainer ~= nil then
        refreshSnapshot(_lastContainer, true, false)
    end
    return true
end

local function requestTransportPrev()
    if #_cursorTrail == 0 then
        return false
    end
    if _pendingRequest then
        return false
    end
    local prevSentinel = _cursorTrail[#_cursorTrail]
    _cursorTrail[#_cursorTrail] = nil
    local prev = prevSentinel
    if prev == false then prev = nil end
    resetPagingLocal()
    if _lastContainer ~= nil then
        clearTable(_lastContainer)
    end
    local ok = requestCursor(prev)
    if not ok then
        -- Preserve original sentinel (false for first page); nil cannot grow the trail.
        _cursorTrail[#_cursorTrail + 1] = prevSentinel
        return false
    end
    if _lastContainer ~= nil then
        refreshSnapshot(_lastContainer, true, false)
    end
    return true
end


local function closeTabletFirst()
    -- Established close route: FarmTablet main publishes manager as getfenv(0).g_FarmTablet
    -- (FarmTabletManager:closeTablet -> UI). mission.farmTablet is FarmTabletFocus (no close).
    local mgr = rawget(_G, "g_FarmTablet")
    if mgr == nil and type(getfenv) == "function" then
        local okEnv, env0 = pcall(getfenv, 0)
        if okEnv and type(env0) == "table" then
            mgr = env0.g_FarmTablet
        end
    end
    if mgr ~= nil and type(mgr.closeTablet) == "function" then
        pcall(mgr.closeTablet, mgr)
        return
    end
    -- Fallback: Focus charge-target UI when manager handle absent (same UI closeTablet).
    local focus = g_currentMission and g_currentMission.farmTablet
    if focus ~= nil and focus._chargeTarget ~= nil and type(focus._chargeTarget.closeTablet) == "function" then
        pcall(focus._chargeTarget.closeTablet, focus._chargeTarget)
    end
end

--- Open Esc RF stock door. Returns ok, reason. No focus/request mutation here.
--- Success = real page present + selectModule/selectPanel returned true + active module is stockGuard.
--- RfPdaMenuPage.show returns nil on success (RfPdaMenuPage.lua); inspect state, do not treat nil as failure.
local function openEscStockDoor()
    closeTabletFirst()
    -- Bootstrap/register before selecting a module that needs the door.
    SgRfPdaGuest.tryRegister()

    if RfPdaMenuPage == nil or type(RfPdaMenuPage.show) ~= "function" then
        return false, "GUI_UNAVAILABLE"
    end
    local okShow, showErr = pcall(RfPdaMenuPage.show)
    if not okShow then
        return false, "GUI_UNAVAILABLE"
    end

    local inGameMenu = nil
    if g_gui ~= nil and type(g_gui.screenControllers) == "table" and InGameMenu ~= nil then
        inGameMenu = g_gui.screenControllers[InGameMenu]
    end
    if inGameMenu == nil then
        inGameMenu = g_inGameMenu
    end
    if inGameMenu == nil then
        return false, "GUI_UNAVAILABLE"
    end
    local pageName = (RfPdaMenuPage.MENU_PAGE_NAME) or "menuRealisticFarming"
    local page = inGameMenu[pageName]
    if page == nil then
        return false, "GUI_UNAVAILABLE"
    end
    if g_gui ~= nil and g_gui.currentGuiName ~= nil and g_gui.currentGuiName ~= "InGameMenu" then
        return false, "GUI_UNAVAILABLE"
    end
    if inGameMenu.currentPage ~= nil and inGameMenu.currentPage ~= page then
        return false, "GUI_UNAVAILABLE"
    end

    local host = getHost()
    if host == nil then
        return false, "GUI_UNAVAILABLE"
    end
    local selectFn = nil
    if type(host.selectPanel) == "function" then
        selectFn = host.selectPanel
    elseif type(host.selectModule) == "function" then
        selectFn = host.selectModule
    else
        return false, "GUI_UNAVAILABLE"
    end
    local okSel, selected = pcall(selectFn, host, PANEL_ID)
    if not okSel then
        return false, "GUI_UNAVAILABLE"
    end
    -- Actual RfEscModules:selectModule returns false when absent/unavailable (RfEscModules.lua ~345-357).
    if selected ~= true then
        return false, "GUI_UNAVAILABLE"
    end
    if type(host.getActivePanel) == "function" then
        local active = host:getActivePanel()
        if active == nil or active.id ~= PANEL_ID then
            return false, "GUI_UNAVAILABLE"
        end
    elseif host.activeModuleId ~= nil and host.activeModuleId ~= PANEL_ID then
        return false, "GUI_UNAVAILABLE"
    end
    return true, nil
end


--- REPAIR-215: the Farm/Site selector is REMOVED from the stock page, on Wizard's call (22:16).
---
--- Why it had to go rather than be fixed: a yard is an SGSiteBinding, a WorkplaceTriggers centre and a
--- radius, and it only FILTERS rows by position. Nothing is ever stored in a yard, so switching to one on a
--- stock check cannot change what you own. The control had no purpose on this page.
---
--- What it actually did before this: SGEscClientAdapter.listSelectionOptions always emits Farm plus
--- placeholders whose available flag is false ("Site (waiting)", "Recipe library (unavailable)"), and the old
--- gate here counted ALL options and hid the selector only below two. So three options passed the gate, the
--- engine's own MultiTextOption cycled its displayed text when an arrow was pressed, and applySelectionAt
--- then refused the choice because available ~= true. The arrows changed a word and nothing else, which is
--- exactly what Wizard circled.
---
--- This function stays, and stays registered, so the host's onShow path is unchanged; it now only makes sure
--- both elements are hidden. The door XML and the host's hide list are untouched, so there is no 11-door
--- churn: the host already hides both on every refresh and this guest simply never shows them again.
--- REPAIR-216: the slot REPAIR-215 emptied now carries the page, which is what Wizard asked for after
--- seeing Market Dynamics: Products, Storages, Buyers, with the same RF_WcSubnavSelector profile MD uses, so
--- the arrows are the same lime ones and no profile is missing.
---
--- It is not a farm or site picker and never will be again: a yard only filters rows by position and stores
--- nothing, which is why it was removed. Three pages is a real choice, which is what the old control was not.
seedSelectionSelector = function(container)
    if container == nil then return end
    local shell = findDescendant(container, "rfFwSelShell")
    local sel = findDescendant(container, "rfFwSelSelector")
    if sel == nil then
        setVis(shell, false)
        return
    end
    local texts = pageTexts()
    if type(sel.setTexts) == "function" then
        pcall(sel.setTexts, sel, texts)
    elseif sel.texts ~= nil then
        sel.texts = texts
    end
    sel.disableButtonsOnSingleText = false
    if sel.setCanChangeState then pcall(sel.setCanChangeState, sel, true) end
    setVis(shell, true)
    if sel.setVisible then sel:setVisible(true) end
    setVis(sel, true)
    -- The MTO is told which page it is on, so the arrows move from where the player actually is rather than
    -- from wherever the element was left.
    if sel.setState then pcall(sel.setState, sel, pageIndexOfView(), false) end
end


--- Apply selection by 1-based index into listSelectionOptions (MTO path).
--- REPAIR-215: no selection UI, so no selection changes from one. Both entry points stay registered with
--- the host, because the descriptor is a contract, and both now refuse: STOCK is always the farm. The
--- adapter's own openFromHostModule path can still arrive carrying a site focus, and that is deliberately
--- left alone - it is a handoff from another module, not a picker on this page.
--- The host's live path: onClickRfFwSelSelector reads the MultiTextOption's own state and hands over the
--- absolute 1-based index, so BOTH arrows arrive here.
function SgRfPdaGuest.onSelectionIndex(index)
    if not isActivePanel() then return false end
    local idx = math.floor(tonumber(index) or 0)
    if idx < 1 or idx > #SG_PAGES then return false end
    return gotoPage(idx)
end

--- Snapshot guest entry context so refused GUI / invalid focus restore prior SITE/paging/pending.
local function captureEntryContext()
    local trail = {}
    for i = 1, #_cursorTrail do
        trail[i] = _cursorTrail[i]
    end
    local sel = nil
    if type(_selection) == "table" then
        sel = {
            route = _selection.route,
            selectionKind = _selection.selectionKind,
            siteId = _selection.siteId,
            libraryId = _selection.libraryId,
        }
        if type(_selection.groundFootprint) == "table" then
            sel.groundFootprint = {
                x = _selection.groundFootprint.x,
                z = _selection.groundFootprint.z,
                radius = _selection.groundFootprint.radius,
            }
        end
    end
    local focusSnap = nil
    if SGEscClientAdapter ~= nil and type(SGEscClientAdapter.getFocusState) == "function" then
        focusSnap = SGEscClientAdapter.getFocusState(g_currentMission)
    end
    return {
        selection = sel,
        selectionIndex = _selectionIndex,
        stationWaiting = _stationWaiting,
        pageIndex = _pageIndex,
        focusSlot = _focusSlot,
        hintSkip = _hintSkip,
        pendingRequest = _pendingRequest,
        routePending = _routePending,
        requestedCursor = _requestedCursor,
        lastRequestedCursor = _lastRequestedCursor,
        cursorTrail = trail,
        focusState = focusSnap,
    }
end

local function restoreEntryContext(snap)
    if type(snap) ~= "table" then return end
    if type(snap.selection) == "table" then
        _selection = {
            route = snap.selection.route or "STOCK",
            selectionKind = snap.selection.selectionKind or "FARM",
            siteId = snap.selection.siteId,
            libraryId = snap.selection.libraryId,
            groundFootprint = snap.selection.groundFootprint,
        }
    else
        _selection = { route = "STOCK", selectionKind = "FARM" }
    end
    _selectionIndex = snap.selectionIndex or 1
    _stationWaiting = snap.stationWaiting and true or false
    _pageIndex = snap.pageIndex or 1
    _focusSlot = snap.focusSlot or 1
    _hintSkip = snap.hintSkip or 0
    _pendingRequest = snap.pendingRequest and true or false
    _routePending = snap.routePending and true or false
    _requestedCursor = snap.requestedCursor
    _lastRequestedCursor = snap.lastRequestedCursor
    _cursorTrail = {}
    if type(snap.cursorTrail) == "table" then
        for i = 1, #snap.cursorTrail do
            _cursorTrail[i] = snap.cursorTrail[i]
        end
    end
    -- Restore prior focus intent; drop any half-applied chemical focus from a refused entry.
    if SGEscClientAdapter ~= nil then
        local host = g_currentMission and g_currentMission.stockGuard
        if host ~= nil then
            host._sg5FocusState = snap.focusState
        end
    end
end

--- Public entry from stockGuard.openHostModule(opts). Brief ~433-435.
--- Transactional: mutate only after snapshot; restore + release hold on any refusal/error.
--- Hold requests and pending-address adopt across door/selectModule notify; then ONE authoritative request.
function SgRfPdaGuest.openFromHostModule(opts)
    if SGEscClientAdapter == nil or type(SGEscClientAdapter.openHostModule) ~= "function" then
        return false, "NO_ADAPTER"
    end

    local prior = captureEntryContext()
    _entryHold = true

    local function fail(why)
        -- Always release hold even if restore or an optional provider throws.
        local okRestore, restoreErr = pcall(restoreEntryContext, prior)
        _entryHold = false
        if not okRestore then
            return false, why or ("RESTORE_ERROR:" .. tostring(restoreErr))
        end
        return false, why
    end

    -- Selection context BEFORE door (selectModule -> _notify -> onShow must not request old SITE/plain FARM).
    if type(opts) == "table" and type(opts.focus) == "table" and type(opts.focus.siteId) == "string" and opts.focus.siteId ~= "" then
        _selection = { route = "STOCK", selectionKind = "SITE", siteId = opts.focus.siteId }
        _stationWaiting = false
    else
        _selection = { route = "STOCK", selectionKind = "FARM" }
        local f = type(opts) == "table" and opts.focus or nil
        if type(f) == "table" and f.ownerObject ~= nil then
            -- Pending until address validates; FOCUSED only after adapter confirms.
            _stationWaiting = true
        else
            _stationWaiting = false
        end
    end
    resetTransportTrail()
    _pageIndex = 1
    _focusSlot = 1
    _hintSkip = 0
    _pendingRequest = false

    local doorPcallOk, doorOk, doorWhy = pcall(function()
        return openEscStockDoor()
    end)
    if not doorPcallOk then
        return fail("GUI_UNAVAILABLE")
    end
    if not doorOk then
        return fail(doorWhy or "GUI_UNAVAILABLE")
    end

    local adaptPcallOk, ok, why = pcall(function()
        return SGEscClientAdapter.openHostModule(g_currentMission, opts)
    end)
    if not adaptPcallOk then
        return fail("FOCUS_UNAVAILABLE")
    end
    if not ok then
        return fail(why or "FOCUS_UNAVAILABLE")
    end

    _entryHold = false

    local focus = SGEscClientAdapter.getFocusState(g_currentMission)
    if type(focus) == "table" and focus.mode == "PENDING" then
        _stationWaiting = true
    elseif type(focus) == "table" and focus.mode == "FOCUSED" then
        _stationWaiting = false
    end

    local optsList = refreshSelectionOptions()
    _selectionIndex = 1
    for i, o in ipairs(optsList) do
        if o.available and selectionEquals(o.selection, _selection) then
            _selectionIndex = i
            break
        end
    end
    if _lastContainer ~= nil then
        refreshSnapshot(_lastContainer, true, false)
        seedSelectionSelector(_lastContainer)
    end
    return true, nil
end

--- Cycle admitted selections. Skips unavailable provider entries.
--- Published because the descriptor publishes it, and implemented so it is correct if it is ever used. It
--- is NOT reachable today: the only caller would be RfPdaMenuPage:_rfFwSelectionStep (:3768), which is
--- defined in all 11 door copies and called from none of them. So no test can drive this through the host,
--- and it is disclosed rather than counted as covered.
function SgRfPdaGuest.onSelectionStep(delta)
    if not isActivePanel() then return false end
    local d = math.floor(tonumber(delta) or 0)
    if d == 0 then return false end
    local want = pageIndexOfView() + d
    while want < 1 do want = want + #SG_PAGES end
    while want > #SG_PAGES do want = want - #SG_PAGES end
    return gotoPage(want)
end

function SgRfPdaGuest.onPageStep(delta)
    _actionChipOffset = 0
    local d = tonumber(delta) or 0
    if d == 0 then return false end

    -- B: farm/permission context BEFORE using any cached READY paint.
    local farmId = localFarmId()
    local farmChanged = handleFarmTransition(farmId)
    if farmChanged then
        if _lastContainer ~= nil then
            refreshSnapshot(_lastContainer, false, true)
        else
            refreshSnapshot(nil, false, true)
        end
        return true
    end

    if _lastContainer ~= nil then
        refreshSnapshot(_lastContainer, true, false)
    else
        local paint = (SGEscClientAdapter ~= nil) and SGEscClientAdapter.getPaintState(g_currentMission) or {
            state = "UNAVAILABLE", usable = false, rows = {}, rowCount = 0
        }
        if paint.state == "DENIED" or paint.state == "ERROR" then
            _paintRows = {}
            _lastPaint = paint
            return false
        end
        _paintRows = paint.rows or {}
        _lastPaint = paint
    end

    -- Permission loss / denied after refresh: nothing to step.
    if _lastPaint ~= nil and (_lastPaint.state == "DENIED" or _lastPaint.state == "ERROR") then
        return false
    end

    -- REPAIR-209: the band now shows the whole label, so a step is never swallowed scrolling text, and
    -- the sheet shows every row, so there is no eight row window to page. Focus moves one row at a time
    -- across the WHOLE snapshot; only at the first or last row does a step fall through to the server's
    -- own stock pages below. The chrome is repainted too, so the action chips follow the focused row.
    local n = #_paintRows
    if n > 0 then
        local nextFocus = _focusSlot + d
        if nextFocus >= 1 and nextFocus <= n then
            _focusSlot = nextFocus
            _hintSkip = 0
            if _lastContainer ~= nil and _lastPaint ~= nil then
                paintDetailHint(_lastContainer, 1)
                paintCommandChrome(_lastContainer)
            end
            return true
        end
    end

    -- Transport host page at the edges of the local window.
    if d > 0 then
        return requestTransportNext()
    end
    return requestTransportPrev()
end

--- REPAIR-209: a click on a sheet row focuses it. The host hands only an index
--- (onClickFwSheetRow -> active.onSheetRow) and SmoothListElement publishes no setSelectedIndex, so the
--- focus lives here and the band and the action chips are repainted from it rather than from a list
--- selection that cannot be set.
---@param index number 1-based row index into the snapshot the sheet last painted
function SgRfPdaGuest.onSheetRow(index)
    local i = tonumber(index)
    if i == nil or i < 1 or i > #_paintRows then return false end
    _focusSlot = i
    _hintSkip = 0
    _actionChipOffset = 0
    if _lastContainer ~= nil then
        paintDetailHint(_lastContainer, 1)
        paintCommandChrome(_lastContainer)
    end
    return true
end

--- REPAIR-209: the Esc Help footer asks whichever module is showing to open its OWN guide, and
--- RfPdaMenuPage.onClickHelpFw ignores any return value, so this opens a StockGuard dialog rather than
--- handing back a table. StockGuard shipped no dialog at all before this build, which is why X HELP did
--- nothing on Stock.
---@param container table|nil
function SgRfPdaGuest.onOpenHelp(container)
    if SgGuideDialog ~= nil and type(SgGuideDialog.show) == "function" then
        SgGuideDialog.show()
        return true
    end
    return false
end

function SgRfPdaGuest.onShow(container, lightOnly)
    if g_dedicatedServer ~= nil then
        return
    end
    _lastContainer = container
    local farmId = localFarmId()
    local farmChanged = handleFarmTransition(farmId)
    refreshSnapshot(container, lightOnly, farmChanged)
end

function SgRfPdaGuest.onHide()
    if _lastContainer ~= nil then
        clearTable(_lastContainer)
        -- Belt and braces: no host calls this today (host page :1702), so the draw hook is what actually
        -- restores. If one ever starts, this is the cheaper path and runs first.
        restoreSgLayout(_lastContainer)
    end
    _lastContainer = nil
    _lastPaint = nil
end

function SgRfPdaGuest.tryRegister()
    if g_dedicatedServer ~= nil then return false end

    if g_inGameMenu ~= nil and g_inGameMenu.menuRealisticFarming == nil then
        if RfEscBootstrap ~= nil and type(RfEscBootstrap.ensureDoor) == "function" and MOD_DIR ~= nil then
            pcall(RfEscBootstrap.ensureDoor, MOD_DIR, {
                profilesXml = MOD_DIR .. "xml/gui/rfEscProfiles.xml",
                iconPath = "textures/ui/menuIcon.dds",
            })
        end
    end

    -- REPAIR-210: the guide is registered on EVERY attempt, not only when StockGuard happens to be the mod
    -- that builds the door. Eleven mods can build it, and in REPAIR-209 this call sat inside the
    -- door-absent gate above, so on any load order where another mod won the race the guide was never
    -- registered here and the only path left was the lazy one inside show() - the later load the engine
    -- note warns about. register() returns immediately when the GUI name is already loaded, so attempting
    -- it on every tick costs nothing.
    if MOD_DIR ~= nil and SgGuideDialog ~= nil and type(SgGuideDialog.register) == "function" then
        pcall(SgGuideDialog.register, MOD_DIR)
    end

    local host = getHost()
    if host == nil then return false end
    local registerFn = host.registerModule
    if type(registerFn) ~= "function" then return false end

    if not _registered then
        local accepted = registerFn(host, {
            id = PANEL_ID,
            order = PANEL_ORDER,
            title = tr("sg5_module_title", "Stock"),
            onShow = SgRfPdaGuest.onShow,
            onHide = SgRfPdaGuest.onHide,
            onPageStep = SgRfPdaGuest.onPageStep,
            onSelectionStep = SgRfPdaGuest.onSelectionStep,
            onSelectionIndex = SgRfPdaGuest.onSelectionIndex,
            onActionActivate = SgRfPdaGuest.onActionActivate,
            onQuoteConfirm = SgRfPdaGuest.onQuoteConfirm,
            onQuoteCancel = SgRfPdaGuest.onQuoteCancel,
            onModeStep = SgRfPdaGuest.onModeStep,
            onSheetRow = SgRfPdaGuest.onSheetRow,
            onOpenHelp = SgRfPdaGuest.onOpenHelp,
        })
        if accepted then
            _registered = true
        else
            return false
        end
    end
    return _registered and g_inGameMenu ~= nil and g_inGameMenu.menuRealisticFarming ~= nil
end

actionVerb = function(action)
    if type(action) ~= "table" then return "" end
    local key = "sg5_action_" .. tostring(action.actionId or "unknown"):lower()
    local mapped = tr(key, nil)
    if mapped ~= nil and mapped ~= "" and mapped ~= key then return mapped end
    return tr("sg5_action_generic", tostring(action.actionId or "Action"))
end

local function controlKindLabel(kind)
    if kind == "RECOVERY" then return tr("sg_control_recovery", "Recovery") end
    if kind == "ADMINISTRATIVE" then return tr("sg_control_administrative", "Administrative") end
    if kind == "CREATIVE" then return tr("sg_control_creative", "Creative") end
    if kind == "DIAGNOSTIC" then return tr("sg_control_diagnostic", "Diagnostic") end
    if kind == "ORDINARY" then return tr("sg_control_ordinary", "Ordinary") end
    return tr("sg5_action_unavailable", "Unavailable")
end

currentPageStart = function()
    -- REPAIR-209: no local window any more, so the first row is always the start. focusedRow ignores it.
    return 1
end

paintCommandChrome = function(container)
    if container == nil then return end
    -- REPAIR-212: the same guard. This is the one that paints the chips, the banner and the quote buttons,
    -- and it is reachable from the action and quote handlers as well as from a refresh.
    if not isActivePanel() then return end
    local cmd = (SGEscClientAdapter ~= nil) and SGEscClientAdapter.getCommandPaint(g_currentMission) or nil
    local banner = findDescendant(container, "rfFwCmdBanner")
    local quoteBody = findDescendant(container, "rfFwQuoteBody")
    local confirmBtn = findDescendant(container, "rfFwQuoteConfirm")
    local cancelBtn = findDescendant(container, "rfFwQuoteCancel")
    local text = ""
    local showQuote = false
    if type(cmd) == "table" and type(cmd.banner) == "table" then
        local b = cmd.banner
        if b.kind == "SENT_AWAITING" then
            text = tr("sg5_cmd_sent_awaiting", "Sent — waiting for owner...")
        elseif b.kind == "ACCEPTED_PENDING" then
            text = tr("sg5_cmd_accepted_pending", "Accepted — work still in progress...")
        elseif b.kind == "QUOTE" then
            showQuote = true
            local remain = cmd.remainingMs
            local sec = remain ~= nil and math.floor((remain / 1000) + 0.5) or 0
            text = string.format(tr("sg5_cmd_quote_banner", "Quoted offer — confirm within %ds"), sec)
        elseif b.kind == "TERMINAL" then
            local outcome = tostring(b.outcome or "")
            text = string.format(tr("sg5_cmd_terminal", "Result: %s"), outcome)
            if type(b.reasonCode) == "string" and b.reasonCode ~= "" then
                text = text .. " (" .. b.reasonCode .. ")"
            end
        end
    end
    setText(banner, text)
    setVis(banner, text ~= "")
    if showQuote and type(cmd.quote) == "table" and type(cmd.quote.offer) == "table" then
        local o = cmd.quote.offer
        local bits = {}
        bits[#bits + 1] = tostring(o.targetLabel or o.actionId or "")
        if type(o.cost) == "table" and o.cost.state == "KNOWN" and o.cost.amount ~= nil then
            bits[#bits + 1] = string.format(tr("sg5_quote_cost", "Cost %s"), tostring(o.cost.amount))
        elseif type(o.cost) == "table" and o.cost.state == "NOT_APPLICABLE" then
            bits[#bits + 1] = tr("sg5_quote_cost_na", "No money charge")
        elseif type(o.cost) == "table" and o.cost.state == "UNAVAILABLE" then
            bits[#bits + 1] = tr("sg5_quote_cost_unavailable", "Cost unavailable")
        end
        if type(o.warnings) == "table" and #o.warnings > 0 then
            bits[#bits + 1] = tr("sg5_quote_has_warnings", "Has warnings")
        end
        setText(quoteBody, table.concat(bits, " · "))
        setVis(quoteBody, true)
        if confirmBtn ~= nil and confirmBtn.setText then pcall(confirmBtn.setText, confirmBtn, tr("sg5_rfFwQuoteConfirm", "Confirm")) end
        if cancelBtn ~= nil and cancelBtn.setText then pcall(cancelBtn.setText, cancelBtn, tr("sg5_rfFwQuoteCancel", "Cancel")) end
        setVis(confirmBtn, true)
        setVis(cancelBtn, true)
    else
        setText(quoteBody, "")
        setVis(quoteBody, false)
        setVis(confirmBtn, false)
        setVis(cancelBtn, false)
    end

    -- REPAIR-214: slots 1 and 2 are the view chips, always STORAGES and BUYERS, with the chip for the
    -- CURRENT view latched lime. Pressing the latched chip is what goes Back, which is the toggle idiom the
    -- design named. Slot 3 carries a published action when the focused row has one and an explicit BACK chip
    -- in a drill-down when it does not, so Back is reachable either way and NOTE-047's allocation holds:
    -- view chips keep 1 and 2, actions take 3.
    -- REPAIR-209's rule still stands: chips appear only with a focused row AND a READY, usable paint, so an
    -- action can never be offered against a view that is pending, denied, errored or unavailable.
    local viewReady = _lastPaint ~= nil and _lastPaint.state == "READY" and _lastPaint.usable == true
    local focused = viewReady and focusedRow(currentPageStart()) or nil
    local actions = (type(focused) == "table" and type(focused.actions) == "table") and focused.actions or {}
    local total = #actions
    if _actionChipOffset < 0 then _actionChipOffset = 0 end
    if total == 0 then _actionChipOffset = 0 end
    if total > 0 and _actionChipOffset >= total then _actionChipOffset = 0 end

    -- REPAIR-216: the STORAGES / BUYERS / BACK view chips are gone. The page selector in the title strip
    -- does that job now, and three chips restating the three pages beside it would be duplicate furniture.
    -- Slots 1 and 2 are cleared and stay hidden; slot 3 still carries a published action under the chip law.
    clearPivotBtn(container, "rfFwAct1")
    clearPivotBtn(container, "rfFwAct2")

    local slot3 = findDescendant(container, "rfFwAct3")
    if slot3 ~= nil then
        slot3._sg5Action = nil
        slot3._sg5ActionMore = nil
    end
    if viewReady and total > 0 then
        -- One action at a time now that the view chips own two slots. The offset advances on each press, so
        -- every published action is still reachable; it just takes more presses than the old three-up row.
        local act = actions[_actionChipOffset + 1]
        if act ~= nil then
            local label = actionVerb(act)
            if act.available ~= true then
                local why = act.reasonCode or ""
                if why == "CONTEXT_ABSENT" then
                    label = label .. " (" .. tr("sg5_action_context_absent", "provider absent") .. ")"
                elseif why == "ARGS_FORMS_ABSENT" then
                    label = label .. " (" .. tr("sg5_action_forms_absent", "needs arguments") .. ")"
                else
                    label = label .. " (" .. tr("sg5_action_unavailable", "unavailable") .. ")"
                end
            else
                if (act.argumentSchemaId == "SG_NATIVE_SET_OUTPUT_MODE_1"
                        or act.argumentSchemaId == "SG_SET_OUTPUT_MODE_1")
                        and type(focused) == "table"
                        and type(focused.modeCatalogue) == "table" then
                    local choices = {}
                    for _, e in ipairs(focused.modeCatalogue) do
                        if type(e) == "table" and e.available == true then choices[#choices + 1] = e end
                    end
                    if #choices > 0 then
                        if _modePickIndex < 1 or _modePickIndex > #choices then _modePickIndex = 1 end
                        local e = choices[_modePickIndex]
                        local fill = e.outputMaterial and e.outputMaterial.fillTypeName or "?"
                        label = label .. " [" .. tostring(fill) .. ":" .. tostring(e.modeId) .. "]"
                        if #choices > 1 then
                            label = label .. " " .. tr("sg5_action_mode_cycle", "(cycle)")
                        end
                    end
                end
                if act.controlKind == "RECOVERY" then
                    label = controlKindLabel("RECOVERY") .. ": " .. label
                end
            end
            if total > 1 then
                label = string.format(tr("sg5_action_of", "%s (%d/%d)"),
                    label, _actionChipOffset + 1, total)
            end
            setPivotBtn(container, "rfFwAct3", label, act.available == true, false)
            if slot3 ~= nil then slot3._sg5Action = act end
        else
            clearPivotBtn(container, "rfFwAct3")
        end
    else
        clearPivotBtn(container, "rfFwAct3")
    end

    -- Mode catalogue MTO (contract SET_OUTPUT_MODE); controller-focusable.
    local modeSel = findDescendant(container, "rfFwModeSelector")
    -- REPAIR-213: same shell treatment as the selection MTO, and the same reason.
    local modeShell = findDescendant(container, "rfFwModeShell")
    if modeSel ~= nil then
        local choices = {}
        if type(focused) == "table" and type(focused.modeCatalogue) == "table" then
            local hasModeAct = false
            if type(focused.actions) == "table" then
                for _, a in ipairs(focused.actions) do
                    if type(a) == "table" and a.available == true
                        and (a.argumentSchemaId == "SG_NATIVE_SET_OUTPUT_MODE_1"
                            or a.argumentSchemaId == "SG_SET_OUTPUT_MODE_1") then
                        hasModeAct = true
                        break
                    end
                end
            end
            if hasModeAct then
                for _, e in ipairs(focused.modeCatalogue) do
                    if type(e) == "table" and e.available == true then
                        local fill = e.outputMaterial and e.outputMaterial.fillTypeName or "?"
                        choices[#choices + 1] = tostring(fill) .. " / " .. tostring(e.modeId)
                    end
                end
            end
        end
        if #choices > 0 then
            if modeSel.setTexts then pcall(modeSel.setTexts, modeSel, choices) end
            if _modePickIndex < 1 or _modePickIndex > #choices then _modePickIndex = 1 end
            if modeSel.setState then pcall(modeSel.setState, modeSel, _modePickIndex, false) end
            setVis(modeShell, true)
            setVis(modeSel, true)
        else
            if modeSel.setTexts then pcall(modeSel.setTexts, modeSel, {}) end
            setVis(modeSel, false)
            setVis(modeShell, false)
        end
    else
        setVis(modeShell, false)
    end
end

local function gatherArgsForAction(act, focused)
    if type(act) ~= "table" then return nil, "NO_ACTION" end
    local schema = act.argumentSchemaId
    if schema == "SG4_STOP_PREPARATION_1" or schema == "SG4_DISCARD_PREPARATION_1" then
        return {}, nil
    end
    if schema == "SG_SET_PRODUCTION_ENABLED_1" then
        return { enabled = not (type(focused) == "table" and focused.enabled == true) }, nil
    end
    if schema == "SG_NATIVE_SET_OUTPUT_MODE_1" or schema == "SG_SET_OUTPUT_MODE_1" then
        local cat = type(focused) == "table" and focused.modeCatalogue or nil
        if type(cat) ~= "table" or #cat < 1 then return nil, "CONTEXT_ABSENT" end
        local choices = {}
        for _, e in ipairs(cat) do
            if type(e) == "table" and e.available == true then
                choices[#choices + 1] = e
            end
        end
        if #choices < 1 then return nil, "CONTEXT_ABSENT" end
        if _modePickIndex < 1 or _modePickIndex > #choices then _modePickIndex = 1 end
        local e = choices[_modePickIndex]
        return {
            fillTypeName = e.outputMaterial.fillTypeName,
            modeId = e.modeId,
        }, nil
    end
    -- Destination/recipe forms need providers not present in this craft pin.
    return nil, "ARGS_FORMS_ABSENT"
end

--- Activate published action by 1-based chip index. One send; ignore while outstanding.
--- Chip 3 may be the More pager when more than 3 actions are published.

function SgRfPdaGuest.onActionActivate(index)
    local idx = tonumber(index) or 0
    if idx < 1 then return false end
    -- REPAIR-214: the host's onClickRfFwAct* handlers fall back to calling this guest DIRECTLY when they
    -- cannot resolve an active panel, so a chip press on another module's page can arrive here. Same law as
    -- REPAIR-212 applied to painting: if STOCK is not the active panel, this is not our click.
    if not isActivePanel() then return false end
    local focusedNow = focusedRow(currentPageStart())
    local actionsNow = (type(focusedNow) == "table" and type(focusedNow.actions) == "table")
        and focusedNow.actions or {}
    -- REPAIR-216: slots 1 and 2 are empty now, so a press on them is not ours. Until this build they were
    -- STORAGES and BUYERS, with the latched one acting as Back; the page selector replaced all three.
    if idx == 1 or idx == 2 then return false end
    if SGEscClientAdapter == nil then return false end
    local focused = focusedNow
    if type(focused) ~= "table" or type(focused.actions) ~= "table" then return false end
    local actions = focused.actions
    local total = #actions
    if total > 1 and idx == 3 then
        -- Slot 3 is the only action slot now, so one press advances by one and wraps.
        _actionChipOffset = _actionChipOffset + 1
        if _actionChipOffset >= total then _actionChipOffset = 0 end
        if _lastContainer ~= nil then paintCommandChrome(_lastContainer) end
        return true
    end
    local cmd = SGEscClientAdapter.getCommandPaint(g_currentMission)
    if type(cmd) == "table" and cmd.outstanding then
        return false
    end
    -- Slot 3 maps to the single offset action, not to idx.
    local act = actions[_actionChipOffset + 1]
    if act == nil or act.available ~= true then return false end
    local args, why = gatherArgsForAction(act, focused)
    if args == nil then return false end
    local ok = SGEscClientAdapter.beginAction(g_currentMission, act, args)
    if _lastContainer ~= nil then
        paintCommandChrome(_lastContainer)
    end
    return ok == true
end

--- Cycle modeCatalogue pick for SET_OUTPUT_MODE (contract: fillTypeName+modeId).
function SgRfPdaGuest.onModeStep(index)
    -- Absolute 1-based catalogue index from MultiTextOptionElement:getState (not delta/+1).
    local idx = math.floor(tonumber(index) or 0)
    if idx < 1 then return false end
    local focused = focusedRow(currentPageStart())
    if type(focused) ~= "table" or type(focused.modeCatalogue) ~= "table" then return false end
    local n = 0
    for _, e in ipairs(focused.modeCatalogue) do
        if type(e) == "table" and e.available == true then n = n + 1 end
    end
    if n < 1 or idx > n then return false end
    local has = false
    if type(focused.actions) == "table" then
        for _, a in ipairs(focused.actions) do
            if type(a) == "table" and a.available == true
                and (a.argumentSchemaId == "SG_NATIVE_SET_OUTPUT_MODE_1"
                    or a.argumentSchemaId == "SG_SET_OUTPUT_MODE_1") then
                has = true
                break
            end
        end
    end
    if not has then return false end
    if _modePickIndex == idx then return true end
    _modePickIndex = idx
    if _lastContainer ~= nil then paintCommandChrome(_lastContainer) end
    return true
end

function SgRfPdaGuest.onQuoteConfirm()
    if SGEscClientAdapter == nil then return false end
    local ok = SGEscClientAdapter.confirmQuote(g_currentMission)
    if _lastContainer ~= nil then paintCommandChrome(_lastContainer) end
    return ok == true
end

function SgRfPdaGuest.onQuoteCancel()
    if SGEscClientAdapter == nil then return false end
    SGEscClientAdapter.cancelUnusedQuote(g_currentMission, "USER_CANCEL")
    if _lastContainer ~= nil then paintCommandChrome(_lastContainer) end
    return true
end

function SgRfPdaGuest.resetForTests()
    -- REPAIR-214: a test that left the guest in a drill-down would carry it into the next test.
    _view = VIEW_PLANNER
    _drillProduct = nil
    _drillTitle = nil
    _plannerRows = {}
    _viewRows = {}
    _priceCache = {}
    _stationCache = nil
    -- REPAIR-213: the unit probe is one shot per LOAD, so without this a test could only ever observe it
    -- from the very first show in a run and the one-shot property itself would be untestable.
    _unitProbeDone = false
    _whereCache = {}
    _actionChipOffset = 0
    _modePickIndex = 1
    _registered = false
    _lastFarmId = nil
    _pendingRequest = false
    _hasFarmSeen = false
    resetPagingLocal()
    resetTransportTrail()
    _lastContainer = nil
    _selection = { route = "STOCK", selectionKind = "FARM" }
    _selectionIndex = 1
    _selectionOptions = nil
    _routePending = false
    _stationWaiting = false
    _entryHold = false
end

function SgRfPdaGuest.reset()
    SgRfPdaGuest.resetForTests()
end

function SgRfPdaGuest.isRegistered()
    return _registered
end

function SgRfPdaGuest._testState()
    return {
        pageIndex = _pageIndex,
        focusSlot = _focusSlot,
        hintSkip = _hintSkip,
        paintRowCount = #_paintRows,
        pendingRequest = _pendingRequest,
        cursorTrail = #_cursorTrail,
        requestedCursor = _requestedCursor,
        selectionKind = _selection and _selection.selectionKind or "FARM",
        selectionRoute = _selection and _selection.route or "STOCK",
        selectionSiteId = _selection and _selection.siteId or nil,
        selectionIndex = _selectionIndex,
        routePending = _routePending,
        stationWaiting = _stationWaiting,
        entryHold = _entryHold,
    }
end
