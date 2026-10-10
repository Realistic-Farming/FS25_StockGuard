-- =========================================================
-- SGEscClientAdapter - Esc client view projection (SG5)
-- Client path: requestView + getClientView only (never getManagementView).
-- STOCK FARM/SITE/GROUND and RECIPE_LIBRARY LIBRARY selections.
-- Projects STOCK/CARRIER/PROCESS/OBSERVATION; filters unknown kinds.
-- =========================================================

SGEscClientAdapter = SGEscClientAdapter or {}
local A = SGEscClientAdapter

local ALLOWED_STATES = {
    READY = true, WAITING = true, DENIED = true, UNAVAILABLE = true,
    ERROR = true, RETRYABLE = true, TERMINAL = true,
}

local SAFE_REASONS = {
    NO_HOST = true, NO_CLIENT_VIEW = true, CLIENT_VIEW_ERROR = true,
    MALFORMED_VIEW = true, UNAVAILABLE = true, DENIED = true,
    SELECTION_CHANGING = true, SERVER_SESSION_CHANGED = true, MISSION_END = true,
    -- BUILD-252: the clear a client's OWN request causes, one per route. The fallback
    -- route clears with SELECTION_CHANGING (SGTransport:expectSelection); on NS7 the
    -- client's requestScopedFull clears the module a second time with NEW_GENERATION
    -- (NetworkSyncScoped.lua:935), so NEW_GENERATION is the reason that actually
    -- survives on the route a joined client uses. Without it here the guest cannot
    -- tell its own empty view from a host refusal and reports both as unavailable.
    NEW_GENERATION = true,
    FARM_CHANGED = true, UI_INVALIDATE = true, NOT_SUBSCRIBED = true,
    INCOMPLETE_ROWS = true, UNSUPPORTED_ROW_KIND = true,
    STOCK_FILTERED = true, SELECTION_MISMATCH = true,
    SITE_PROVIDER_ABSENT = true, SITE_PROVIDER_WAITING = true,
    GROUND_FOCUS_ABSENT = true, LIBRARY_OWNER_ABSENT = true,
    OPEN_HOST_ABSENT = true, FOCUS_UNAVAILABLE = true,
    RECIPE_LIBRARY_OWNER_ABSENT = true,
}

local HOST_ROW_KINDS = {
    STOCK = true, CARRIER = true, PROCESS = true, OBSERVATION = true,
}

local LABEL_ABS_MAX = 4096

function A.hostOf(mission)
    mission = mission or g_currentMission
    if mission == nil then return nil end
    if mission.stockGuard ~= nil then return mission.stockGuard end
    if StockGuard ~= nil and type(StockGuard.hostOf) == "function" then
        return StockGuard.hostOf(mission)
    end
    return nil
end

--- WorkplaceTriggers site handle (WT8). Never invents site ids.
function A.siteProvider(mission)
    mission = mission or g_currentMission
    if mission == nil then return nil end
    local wt = mission.workplaceTriggers
    if wt == nil then return nil end
    if type(wt.getSitesForFarm) == "function" and type(wt.getSiteCapabilities) == "function" then
        return wt
    end
    return nil
end

local function copySelection(sel)
    if type(sel) ~= "table" then return { route = "STOCK", selectionKind = "FARM" } end
    local out = { route = sel.route or "STOCK", selectionKind = sel.selectionKind or "FARM" }
    if sel.siteId ~= nil then out.siteId = sel.siteId end
    if type(sel.groundFootprint) == "table" then
        out.groundFootprint = {
            x = sel.groundFootprint.x,
            z = sel.groundFootprint.z,
            radius = sel.groundFootprint.radius,
        }
    end
    if sel.libraryId ~= nil then out.libraryId = sel.libraryId end
    return out
end

--- Normalize a presentation selection for requestView.
function A.normalizeSelection(selection)
    selection = selection or { route = "STOCK", selectionKind = "FARM" }
    local kind = selection.selectionKind or "FARM"
    if kind == "FARM" then
        return { route = "STOCK", selectionKind = "FARM" }
    elseif kind == "SITE" then
        if type(selection.siteId) ~= "string" or selection.siteId == "" then
            return nil, "SITE_PARAMETERS"
        end
        return { route = "STOCK", selectionKind = "SITE", siteId = selection.siteId }
    elseif kind == "GROUND" then
        local f = selection.groundFootprint
        if type(f) ~= "table" or type(f.x) ~= "number" or type(f.z) ~= "number"
            or type(f.radius) ~= "number" or f.radius <= 0 then
            return nil, "GROUND_PARAMETERS"
        end
        return { route = "STOCK", selectionKind = "GROUND", groundFootprint = { x = f.x, z = f.z, radius = f.radius } }
    elseif kind == "LIBRARY" then
        local id = selection.libraryId or "@current"
        if type(id) ~= "string" or id == "" then return nil, "LIBRARY_PARAMETERS" end
        return { route = "RECIPE_LIBRARY", selectionKind = "LIBRARY", libraryId = id }
    end
    return nil, "SELECTION_KIND"
end

--- Admitted selection options from real providers only (no fabricated ids/coords).
--- Returns array of { selection, label, available, reasonCode }.
--- Admitted selection options from real providers only (no fabricated ids; no GROUND selector UI).
--- GROUND remains transport-compatible if an authorized provider ever supplies it; SG5 does not commission a GROUND picker.
--- Returns array of { selection, label, available, reasonCode, kind }.
function A.listSelectionOptions(mission)
    local out = {}
    out[#out + 1] = {
        selection = { route = "STOCK", selectionKind = "FARM" },
        labelKey = "sg5_sel_farm",
        label = "Farm",
        available = true,
        reasonCode = nil,
        kind = "FARM",
    }

    local provider = A.siteProvider(mission)
    if provider == nil then
        out[#out + 1] = {
            selection = nil,
            labelKey = "sg5_sel_site_absent",
            label = "Site (provider absent)",
            available = false,
            reasonCode = "SITE_PROVIDER_ABSENT",
            kind = "SITE",
        }
    else
        local capsOk, caps = pcall(function() return provider.getSiteCapabilities() end)
        if not capsOk or type(caps) ~= "table" or caps.ready ~= true then
            local reason = "SITE_PROVIDER_WAITING"
            if capsOk and type(caps) == "table" and type(caps.reasonCode) == "string" then
                reason = caps.reasonCode
            end
            out[#out + 1] = {
                selection = nil,
                labelKey = "sg5_sel_site_waiting",
                label = "Site (waiting)",
                available = false,
                reasonCode = reason,
                kind = "SITE",
            }
        else
            local sitesOk, sites, siteWhy = pcall(function() return provider.getSitesForFarm(nil) end)
            if not sitesOk then
                out[#out + 1] = {
                    selection = nil,
                    labelKey = "sg5_sel_site_waiting",
                    label = "Site (waiting)",
                    available = false,
                    reasonCode = "SITE_PROVIDER_ERROR",
                    kind = "SITE",
                }
            elseif sites == nil then
                out[#out + 1] = {
                    selection = nil,
                    labelKey = "sg5_sel_site_waiting",
                    label = "Site (waiting)",
                    available = false,
                    reasonCode = tostring(siteWhy or "NOT_READY"),
                    kind = "SITE",
                }
            elseif type(sites) ~= "table" then
                out[#out + 1] = {
                    selection = nil,
                    labelKey = "sg5_sel_site_waiting",
                    label = "Site (waiting)",
                    available = false,
                    reasonCode = "SITE_PROVIDER_MALFORMED",
                    kind = "SITE",
                }
            elseif #sites == 0 then
                out[#out + 1] = {
                    selection = nil,
                    labelKey = "sg5_sel_site_empty",
                    label = "Site (none listed)",
                    available = false,
                    reasonCode = "SITE_LIST_EMPTY",
                    kind = "SITE",
                }
            else
                for _, s in ipairs(sites) do
                    if type(s) == "table" and type(s.siteId) == "string" and s.siteId ~= "" then
                        local name = s.name
                        if type(name) ~= "string" or name == "" then name = s.siteId end
                        out[#out + 1] = {
                            selection = { route = "STOCK", selectionKind = "SITE", siteId = s.siteId },
                            labelKey = "sg5_sel_site",
                            label = name,
                            available = true,
                            reasonCode = nil,
                            kind = "SITE",
                            siteId = s.siteId,
                            siteRevision = s.revision,
                        }
                    end
                end
            end
        end
    end

    -- Library: honest unavailable on this pin when getRecipeLibraryView reports owner absent.
    -- Ready-provider recipe row rendering is not implemented in this slice (no fabricated RECIPE/LIBRARY schema).
    local host = A.hostOf(mission)
    local libReason = "LIBRARY_OWNER_ABSENT"
    if host ~= nil and type(host.getRecipeLibraryView) == "function" then
        local ok, snap = pcall(host.getRecipeLibraryView)
        if ok and type(snap) == "table" then
            libReason = tostring(snap.reason or libReason)
        end
    end
    out[#out + 1] = {
        selection = nil,
        labelKey = "sg5_sel_library_absent",
        label = "Recipe library (unavailable)",
        available = false,
        reasonCode = libReason,
        kind = "LIBRARY",
        blockedProvider = true,
    }
    return out
end

--- Local physical-entry / focus state (never networked or saved).
--- pending: live ownerObject without address yet.
--- focused: paired {carrierId, ownerObject} on STOCK FARM + navigationCarrierId.
function A.getFocusState(mission)
    local host = A.hostOf(mission)
    if host == nil then return nil end
    return host._sg5FocusState
end

local function clearFocusState(host, reason)
    if host == nil then return end
    host._sg5FocusState = nil
end

--- Resolve navigation address from a live owner via its protected getNavigationCarrierId.
function A.resolveOwnerAddress(ownerObject)
    if type(ownerObject) ~= "table" then return nil end
    if type(ownerObject.getNavigationCarrierId) ~= "function" then return nil end
    local ok, id = pcall(ownerObject.getNavigationCarrierId, ownerObject)
    if ok and type(id) == "string" and id ~= "" then return id end
    return nil
end

--- Supported live-owner check: optional isDeleted, optional NetworkUtil id round-trip, else table presence.
--- No invented engine APIs.
function A.isOwnerObjectLive(ownerObject)
    if type(ownerObject) ~= "table" then return false end
    if type(ownerObject.isDeleted) == "function" then
        local ok, deleted = pcall(ownerObject.isDeleted, ownerObject)
        if ok and deleted == true then return false end
    end
    if NetworkUtil ~= nil
        and type(NetworkUtil.getObjectId) == "function"
        and type(NetworkUtil.getObject) == "function" then
        local okId, oid = pcall(NetworkUtil.getObjectId, ownerObject)
        if not okId or oid == nil then return false end
        local okObj, obj = pcall(NetworkUtil.getObject, oid)
        if not okObj or obj ~= ownerObject then return false end
    end
    return true
end

--- Validate pending/focused intention on existing refresh. Withdrawal/change/owner-gone => clear + fallback reason.
--- Never silently retarget a FOCUSED carrierId.
function A.validatePhysicalFocus(mission)
    local host = A.hostOf(mission)
    if host == nil then return true, nil end
    local st = host._sg5FocusState
    if type(st) ~= "table" then return true, nil end

    if st.mode == "PENDING" then
        if not A.isOwnerObjectLive(st.ownerObject) then
            clearFocusState(host, "OWNER_GONE")
            return false, "STATION_UNAVAILABLE"
        end
        return true, nil
    end

    if st.mode == "FOCUSED" then
        if st.ownerObject == nil or type(st.carrierId) ~= "string" or st.carrierId == "" then
            clearFocusState(host, "FOCUS_INCOMPLETE")
            return false, "STATION_UNAVAILABLE"
        end
        if not A.isOwnerObjectLive(st.ownerObject) then
            clearFocusState(host, "OWNER_GONE")
            return false, "STATION_UNAVAILABLE"
        end
        local addr = A.resolveOwnerAddress(st.ownerObject)
        if addr == nil then
            clearFocusState(host, "ADDRESS_WITHDRAWN")
            return false, "STATION_UNAVAILABLE"
        end
        if addr ~= st.carrierId then
            clearFocusState(host, "ADDRESS_CHANGED")
            return false, "STATION_UNAVAILABLE"
        end
        return true, nil
    end

    clearFocusState(host, "FOCUS_UNKNOWN")
    return false, "STATION_UNAVAILABLE"
end

--- Public client presentation entry (SG5 brief ~433-435). Implemented here; published on mission.stockGuard.
--- opts nil/empty => normal host entry (FARM).
--- opts.focus is {siteId} XOR {carrierId, ownerObject}; never both.
--- Chemical FOCUSED form requires both carrierId and ownerObject; owner alone => PENDING.
function A.openHostModule(mission, opts)
    local host = A.hostOf(mission)
    if host == nil then return false, "NO_HOST" end

    -- Close-tablet-first / open Esc RF door / select stockGuard are guest responsibilities when called from handle.
    if type(opts) ~= "table" or opts.focus == nil then
        clearFocusState(host, "UNFOCUSED_FARM")
        local ok, why = A.requestSelection(mission, { route = "STOCK", selectionKind = "FARM" }, {})
        return ok, why
    end

    local focus = opts.focus
    if type(focus) ~= "table" then
        return false, "FOCUS_UNAVAILABLE"
    end

    local hasSite = type(focus.siteId) == "string" and focus.siteId ~= ""
    local hasCarrier = type(focus.carrierId) == "string" and focus.carrierId ~= ""
    local hasOwner = focus.ownerObject ~= nil

    if hasSite and (hasCarrier or hasOwner) then
        return false, "FOCUS_XOR"
    end
    if not hasSite and not hasCarrier and not hasOwner then
        return false, "FOCUS_UNAVAILABLE"
    end

    if hasSite then
        clearFocusState(host, "SITE_FOCUS")
        local ok, why = A.requestSelection(mission, {
            route = "STOCK",
            selectionKind = "SITE",
            siteId = focus.siteId,
        }, {})
        return ok, why
    end

    -- Chemical: brief form is {carrierId, ownerObject}. Live owner + missing address => PENDING (no nav request).
    -- Only FOCUSED + navigationCarrierId when resolveOwnerAddress validates the supplied carrierId.
    if hasCarrier then
        if not hasOwner then
            return false, "FOCUS_UNAVAILABLE"
        end
        if not A.isOwnerObjectLive(focus.ownerObject) then
            return false, "FOCUS_UNAVAILABLE"
        end
        local addr = A.resolveOwnerAddress(focus.ownerObject)
        if addr ~= nil and addr ~= focus.carrierId then
            return false, "FOCUS_UNAVAILABLE"
        end
        if addr == nil then
            -- Live owner, address not yet available: PENDING. Do not request an unvalidated carrier.
            host._sg5FocusState = {
                mode = "PENDING",
                ownerObject = focus.ownerObject,
                carrierId = nil,
                expectedCarrierId = focus.carrierId,
                adopted = false,
            }
            local ok, why = A.requestSelection(mission, { route = "STOCK", selectionKind = "FARM" }, {})
            return ok, why or nil
        end
        host._sg5FocusState = {
            mode = "FOCUSED",
            carrierId = focus.carrierId,
            ownerObject = focus.ownerObject,
            expectedCarrierId = focus.carrierId,
            adopted = true,
        }
        local ok, why = A.requestSelection(mission, { route = "STOCK", selectionKind = "FARM" }, {
            navigationCarrierId = focus.carrierId,
        })
        return ok, why
    end

    -- ownerObject live, address missing: pending local intention + FARM waiting.
    if not A.isOwnerObjectLive(focus.ownerObject) then
        return false, "FOCUS_UNAVAILABLE"
    end
    host._sg5FocusState = {
        mode = "PENDING",
        ownerObject = focus.ownerObject,
        carrierId = nil,
        expectedCarrierId = nil,
        adopted = false,
    }
    local ok, why = A.requestSelection(mission, { route = "STOCK", selectionKind = "FARM" }, {})
    return ok, why or nil
end

--- Explicit unfocused FARM or named SITE clears pending/focused chemical intention.
function A.clearPhysicalFocusIntent(mission, reason)
    A.invalidateOffers(mission, reason or "FOCUS_CLEARED")
    local host = A.hostOf(mission)
    clearFocusState(host, reason or "CLEARED")
end

--- On refresh: if pending and same live ownerObject now yields a validated address, adopt it once.
--- No new poll loop; caller invokes during existing onShow/light refresh. Never silent retarget after adopt.
function A.tryAdoptPendingAddress(mission, resolveAddressFn)
    local host = A.hostOf(mission)
    if host == nil then return false, "NO_HOST" end
    local st = host._sg5FocusState
    if type(st) ~= "table" or st.mode ~= "PENDING" or st.ownerObject == nil then
        return false, "NOT_PENDING"
    end
    if type(resolveAddressFn) ~= "function" then
        return false, "NO_RESOLVER"
    end
    if not A.isOwnerObjectLive(st.ownerObject) then
        clearFocusState(host, "OWNER_GONE")
        return false, "STATION_UNAVAILABLE"
    end
    local ok, carrierId = pcall(resolveAddressFn, st.ownerObject)
    if not ok or type(carrierId) ~= "string" or carrierId == "" then
        return false, "NO_ADDRESS"
    end
    if type(st.expectedCarrierId) == "string" and st.expectedCarrierId ~= "" and carrierId ~= st.expectedCarrierId then
        return false, "ADDRESS_MISMATCH"
    end
    -- Adopt once: PENDING -> FOCUSED with this address; later change uses validatePhysicalFocus fallback.
    st.mode = "FOCUSED"
    st.carrierId = carrierId
    st.adopted = true
    return A.requestSelection(mission, { route = "STOCK", selectionKind = "FARM" }, {
        navigationCarrierId = carrierId,
    })
end

function A.requestSelection(mission, selection, readOptions)
    local host = A.hostOf(mission)
    if host == nil then return false, "NO_HOST" end
    A.invalidateOffers(mission, "SELECTION_REQUEST")
    if type(host.requestView) ~= "function" then return false, "NO_REQUEST_VIEW" end
    local norm, why = A.normalizeSelection(selection)
    if norm == nil then return false, why end
    local opts = {}
    if type(readOptions) == "table" then
        if type(readOptions.pageCursor) == "string" and readOptions.pageCursor ~= "" then
            opts.pageCursor = readOptions.pageCursor
        end
        -- navigationCarrierId only with STOCK FARM and no pageCursor (SG1 grammar).
        if type(readOptions.navigationCarrierId) == "string" and readOptions.navigationCarrierId ~= ""
            and norm.selectionKind == "FARM" and opts.pageCursor == nil then
            opts.navigationCarrierId = readOptions.navigationCarrierId
        end
    end
    local okCall, aRes, bRes = pcall(host.requestView, norm, opts)
    if not okCall then return false, "REQUEST_ERROR" end
    if aRes == false then return false, tostring(bRes or "REQUEST_FALSE") end
    host._sg5LastSelection = copySelection(norm)
    return true, nil
end

function A.requestFarmStockView(mission, readOptions)
    return A.requestSelection(mission, { route = "STOCK", selectionKind = "FARM" }, readOptions)
end

function A.lastSelection(mission)
    local host = A.hostOf(mission)
    if host == nil or type(host._sg5LastSelection) ~= "table" then
        return { route = "STOCK", selectionKind = "FARM" }
    end
    return copySelection(host._sg5LastSelection)
end

local function sanitizeUnit(unit)
    if type(unit) ~= "string" or unit == "" then return nil end
    if unit == "l" or unit == "litre" or unit == "liter" then return "LITRE" end
    if unit == "kg" then return "KILOGRAM" end
    if unit == "LITRE" or unit == "KILOGRAM" or unit == "UNAVAILABLE"
        or unit == "COUNT" or unit == "FRACTION" or unit == "CURRENCY" then
        return unit
    end
    if #unit > 32 then return nil end
    return unit
end

function A.utf8Truncate(text, maxChars)
    if type(text) ~= "string" then return "", false end
    if type(maxChars) ~= "number" or maxChars < 1 then return "", true end
    local n, i = 0, 1
    local len = #text
    while i <= len do
        local c = text:byte(i)
        local step = 1
        if c >= 0xF0 then step = 4
        elseif c >= 0xE0 then step = 3
        elseif c >= 0xC0 then step = 2
        end
        if n + 1 > maxChars then
            return text:sub(1, i - 1), true
        end
        n = n + 1
        i = i + step
    end
    return text, false
end

function A.utf8Offset(text, skipChars)
    if type(text) ~= "string" then return 1, false end
    local n, i = 0, 1
    local len = #text
    while i <= len and n < skipChars do
        local c = text:byte(i)
        local step = 1
        if c >= 0xF0 then step = 4
        elseif c >= 0xE0 then step = 3
        elseif c >= 0xC0 then step = 2
        end
        i = i + step
        n = n + 1
    end
    return i, true
end

local function sanitizeLabel(label, fallback)
    if type(label) == "string" then
        local t = label:match("^%s*(.-)%s*$") or ""
        if t ~= "" and not t:find("[\r\n]") then
            if #t > LABEL_ABS_MAX then
                return t:sub(1, LABEL_ABS_MAX)
            end
            return t
        end
    end
    return fallback
end

local function isFiniteNumber(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

--- The Esc projection carried no material at all, so the Stock page could only ever show the
--- holder while the Farm Tablet showed the product for the same stock. SGViews already puts materialRef on
--- the row (SGViews.lua:272); this forwards the one field the name needs, in the same shape the Tablet reads
--- (FS25_FarmTablet StockGuardApp.lua _productTitle): a table carrying a non-empty fillTypeName.
--- Properties reach the page stripped to the readable facts. The payload is a typed value tree
--- and causalState is bookkeeping, so NEITHER is forwarded: the page must not be able to print either, and
--- the detail band is built only from what survives here. SGRecords.isPropertyRecord requires propertyId,
--- schemaVersion, producerId, propertyRevision and knowledge; producerId and the revisions are identifiers
--- the player has no use for, so they are dropped too.
local function sanitizeProperties(list)
    if type(list) ~= "table" then return nil end
    local kept = {}
    for _, p in ipairs(list) do
        if type(p) == "table" and type(p.propertyId) == "string" and p.propertyId ~= ""
            and #p.propertyId <= 128 then
            kept[#kept + 1] = {
                propertyId = p.propertyId,
                knowledge = (type(p.knowledge) == "string") and p.knowledge or nil,
                knownAmount = isFiniteNumber(p.knownAmount) and p.knownAmount or nil,
                basisAmount = isFiniteNumber(p.basisAmount) and p.basisAmount or nil,
                amountUnit = sanitizeUnit(p.amountUnit),
                observedGameDay = isFiniteNumber(p.observedGameDay) and p.observedGameDay or nil,
            }
        end
        if #kept >= 16 then break end
    end
    if #kept == 0 then return nil end
    return kept
end

local function sanitizeMaterial(mat)
    if type(mat) ~= "table" then return nil end
    local name = mat.fillTypeName
    if type(name) ~= "string" or name == "" or #name > 64 or name:find("[\r\n]") then return nil end
    return { kind = type(mat.kind) == "string" and mat.kind or nil, fillTypeName = name }
end

local function sanitizeKnowledge(k)
    if type(k) ~= "string" then return nil end
    if k == "KNOWN" or k == "PARTIAL" or k == "UNKNOWN" or k == "HISTORICAL" or k == "UNAVAILABLE" then
        return k
    end
    return nil
end

local CONTROL_KINDS = {
    ORDINARY = true, ADMINISTRATIVE = true, CREATIVE = true, RECOVERY = true, DIAGNOSTIC = true,
}
local ADMISSIONS = { DIRECT_DESIRED_STATE = true, QUOTED = true }

local function projectModeCatalogue(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for _, e in ipairs(list) do
        if type(e) == "table"
            and type(e.modeId) == "string" and e.modeId ~= ""
            and type(e.outputMaterial) == "table"
            and e.outputMaterial.kind == "FILL_TYPE"
            and type(e.outputMaterial.fillTypeName) == "string"
            and e.outputMaterial.fillTypeName ~= "" then
            out[#out + 1] = {
                modeId = e.modeId,
                labelKey = type(e.labelKey) == "string" and e.labelKey or nil,
                outputMaterial = {
                    kind = "FILL_TYPE",
                    fillTypeName = e.outputMaterial.fillTypeName,
                },
                available = e.available == true,
                reason = type(e.reason) == "string" and e.reason or "",
            }
        end
    end
    return out
end

local function catalogueHasAvailable(cat)
    for _, e in ipairs(cat) do
        if e.available == true then return true end
    end
    return false
end

local function projectActions(list, modeCatalogue)
    local out = {}
    if type(list) ~= "table" then return out end
    for _, raw in ipairs(list) do
        if type(raw) == "table"
            and type(raw.actionId) == "string" and raw.actionId ~= ""
            and type(raw.targetKind) == "string" and raw.targetKind ~= ""
            and type(raw.targetId) == "string" and raw.targetId ~= ""
            and type(raw.expectedRevision) == "string" and raw.expectedRevision ~= ""
            and type(raw.argumentSchemaId) == "string" and raw.argumentSchemaId ~= "" then
            local controlKind = raw.controlKind
            local admission = raw.admission
            local available = raw.available == true
            local reasonCode = type(raw.reasonCode) == "string" and raw.reasonCode or ""
            if CONTROL_KINDS[controlKind] ~= true then
                available = false
                controlKind = "UNAVAILABLE"
                reasonCode = reasonCode ~= "" and reasonCode or "CONTROL_KIND_UNKNOWN"
            end
            if ADMISSIONS[admission] ~= true then
                available = false
                admission = "UNAVAILABLE"
                reasonCode = reasonCode ~= "" and reasonCode or "ADMISSION_UNKNOWN"
            end
            -- Executable only when this presentation can gather/validate required args.
            -- Empty-arg stop/discard and SET_PRODUCTION_ENABLED (row toggle) are supported.
            -- Other schemas stay published but non-executable until argument forms exist;
            -- library/recipe providers absent => CONTEXT_ABSENT, not a fake picker.
            local schema = raw.argumentSchemaId
            local ctx = raw.argumentContext
            if available then
                if schema == "SG_SET_PRODUCTION_ENABLED_1"
                    or schema == "SG4_STOP_PREPARATION_1"
                    or schema == "SG4_DISCARD_PREPARATION_1" then
                    -- supported forms
                elseif schema == "SG_NATIVE_SET_OUTPUT_MODE_1" or schema == "SG_SET_OUTPUT_MODE_1" then
                    -- Contract: PROCESS.modeCatalogue entries; args {fillTypeName, modeId}.
                    -- Catalogue is attached by projectProcess (not invented modes[]).
                    if not catalogueHasAvailable(modeCatalogue or {}) then
                        available = false
                        reasonCode = reasonCode ~= "" and reasonCode or "CONTEXT_ABSENT"
                    end
                elseif schema == "SG4_START_PREPARATION_1"
                    or schema == "SG4_RECOVER_PARTIAL_OUTPUT_1"
                    or schema == "SG4_PUMP_OUT_PREPARATION_1"
                    or schema == "SG4_SAVE_RECIPE_1"
                    or schema == "SG4_RETIRE_RECIPE_1" then
                    if ctx == nil then
                        available = false
                        reasonCode = reasonCode ~= "" and reasonCode or "CONTEXT_ABSENT"
                    else
                        -- Recipe/destination pickers need library/destination providers.
                        available = false
                        reasonCode = reasonCode ~= "" and reasonCode or "ARGS_FORMS_ABSENT"
                    end
                else
                    -- Unknown schema: do not expose as executable.
                    available = false
                    reasonCode = reasonCode ~= "" and reasonCode or "ARGS_FORMS_ABSENT"
                end
            end
            out[#out + 1] = {
                actionId = raw.actionId,
                targetKind = raw.targetKind,
                targetId = raw.targetId,
                expectedRevision = raw.expectedRevision,
                expectedGeneration = type(raw.expectedGeneration) == "string" and raw.expectedGeneration or nil,
                available = available,
                reasonCode = reasonCode,
                argumentSchemaId = raw.argumentSchemaId,
                argumentContext = raw.argumentContext,
                controlKind = controlKind,
                admission = admission,
            }
        end
    end
    return out
end

local function projectStock(row)
    local amount = row.amount
    if amount ~= nil and not isFiniteNumber(amount) then return nil, true end
    local stockId = nil
    if type(row.stockRef) == "table" and type(row.stockRef.stockId) == "string" then
        stockId = row.stockRef.stockId
    elseif type(row.stockId) == "string" then
        stockId = row.stockId
    end
    return {
        rowKind = "STOCK",
        label = sanitizeLabel(row.label, "Stock"),
        materialRef = sanitizeMaterial(row.materialRef),
        -- Where it is, and what is known about it. x and z are the server's own world position
        -- (SGViews stockRow sets positionKnown = n.x ~= nil); the page uses them for nothing but naming the
        -- farmland. properties were computed by disclosedProperties and then dropped here.
        positionKnown = row.positionKnown == true,
        x = isFiniteNumber(row.x) and row.x or nil,
        z = isFiniteNumber(row.z) and row.z or nil,
        properties = sanitizeProperties(row.properties),
        amount = amount,
        amountUnit = sanitizeUnit(row.amountUnit),
        knowledge = sanitizeKnowledge(row.knowledge),
        -- No capacity and no native identity on a STOCK row. A capacity belongs to the admitted CARRIER
        -- projection, which keeps its own below, and the native unique id is private to the server.
        stockId = stockId,
        carrierId = type(row.carrierId) == "string" and row.carrierId or nil,
        actions = projectActions(row.actions, nil),
    }, false
end

local function projectCarrier(row)
    return {
        rowKind = "CARRIER",
        label = sanitizeLabel(row.label, "Carrier"),
        amount = nil,
        amountUnit = nil,
        knowledge = nil,
        capacity = isFiniteNumber(row.capacity) and row.capacity or nil,
        capacityUnit = sanitizeUnit(row.capacityUnit),
        capacityKnown = row.capacityKnown == true,
        positionKnown = row.positionKnown == true,
        carrierId = type(row.carrierId) == "string" and row.carrierId or nil,
        carrierKind = type(row.carrierKind) == "string" and row.carrierKind or nil,
        readiness = type(row.readiness) == "string" and row.readiness or nil,
        partial = row.partial == true,
        unavailable = row.unavailable == true,
        actions = projectActions(row.actions, nil),
    }, false
end

local function projectProcess(row)
    local cat = projectModeCatalogue(row.modeCatalogue)
    local version = row.modeCatalogueVersion
    if version ~= nil and tonumber(version) ~= 1 then
        cat = {}
    end
    return {
        rowKind = "PROCESS",
        processId = row.processId,
        label = sanitizeLabel(row.label, row.processId),
        enabled = row.enabled == true,
        processState = type(row.processState) == "string" and row.processState or "",
        processStateLabelKey = type(row.processStateLabelKey) == "string" and row.processStateLabelKey or nil,
        knowledge = sanitizeKnowledge(row.knowledge),
        modeCatalogueVersion = (#cat > 0) and 1 or nil,
        modeCatalogue = (#cat > 0) and cat or nil,
        actions = projectActions(row.actions, cat),
    }
end

local function projectObservation(row)
    local amount = row.amount
    if amount ~= nil and not isFiniteNumber(amount) then return nil, true end
    return {
        rowKind = "OBSERVATION",
        label = sanitizeLabel(row.label, "Observation"),
        materialRef = sanitizeMaterial(row.materialRef),
        amount = amount,
        amountUnit = sanitizeUnit(row.amountUnit),
        knowledge = sanitizeKnowledge(row.knowledge),
        observationKind = type(row.observationKind) == "string" and row.observationKind or nil,
    }, false
end

--- Project host-admitted rows. Valid kinds paint; unknown kinds incomplete.
function A.projectRows(view)
    local out = {}
    local malformed = 0
    local unknownKind = 0
    local nextPageCursor = nil
    local pageCursor = nil
    if type(view) ~= "table" then
        return out, "NO_VIEW", {}
    end
    if type(view.nextPageCursor) == "string" and view.nextPageCursor ~= "" then
        nextPageCursor = view.nextPageCursor
    end
    if type(view.pageCursor) == "string" and view.pageCursor ~= "" then
        pageCursor = view.pageCursor
    end
    local selectionKind = type(view.selectionKind) == "string" and view.selectionKind or nil
    local route = type(view.route) == "string" and view.route or nil
    if type(view.rows) ~= "table" then
        return out, "NO_ROWS", {
            unknownKind = 0,
            nextPageCursor = nextPageCursor,
            pageCursor = pageCursor,
            selectionKey = type(view.selectionKey) == "string" and view.selectionKey or nil,
            selectionKind = selectionKind,
            route = route,
        }
    end
    for _, row in ipairs(view.rows) do
        if type(row) ~= "table" then
            malformed = malformed + 1
        else
            local kind = row.rowKind
            if kind == nil or HOST_ROW_KINDS[kind] ~= true then
                -- Recipe/library envelope rendering awaits a ready SG4 provider; do not fabricate schema.
                unknownKind = unknownKind + 1
            else
                local projected, bad = nil, false
                if kind == "STOCK" then
                    projected, bad = projectStock(row)
                elseif kind == "CARRIER" then
                    projected, bad = projectCarrier(row)
                elseif kind == "PROCESS" then
                    projected, bad = projectProcess(row)
                elseif kind == "OBSERVATION" then
                    projected, bad = projectObservation(row)
                end
                if bad or projected == nil then
                    malformed = malformed + 1
                else
                    out[#out + 1] = projected
                end
            end
        end
    end
    local meta = {
        unknownKind = unknownKind,
        nextPageCursor = nextPageCursor,
        pageCursor = pageCursor,
        selectionKey = type(view.selectionKey) == "string" and view.selectionKey or nil,
        selectionKind = selectionKind,
        route = route,
        filteredNonStock = 0,
    }
    if malformed > 0 and #out == 0 then
        return out, "MALFORMED", meta
    end
    if malformed > 0 then
        return out, "INCOMPLETE", meta
    end
    if unknownKind > 0 and #out == 0 then
        return out, "UNSUPPORTED", meta
    end
    if unknownKind > 0 and #out > 0 then
        return out, "INCOMPLETE", meta
    end
    return out, nil, meta
end

local function expectedKeyOf(host)
    if host == nil or host.transport == nil or host.transport.client == nil then return nil end
    return host.transport.client.expectedKey
end

function A.getPaintState(mission)
    local empty = {
        state = "UNAVAILABLE", reasonKey = "NO_HOST", usable = false,
        rows = {}, rowCount = 0, readyEmpty = false,
        filteredNonStock = 0, filteredOnly = false,
        nextPageCursor = nil, pageCursor = nil, selectionKey = nil,
        selectionKind = "FARM", route = "STOCK",
        transportPagingPending = false, selectionMismatch = false,
    }
    local host = A.hostOf(mission)
    if host == nil then
        return empty
    end
    if type(host.getClientView) ~= "function" then
        empty.reasonKey = "NO_CLIENT_VIEW"
        return empty
    end
    local ok, snap = pcall(host.getClientView)
    if not ok or type(snap) ~= "table" then
        return {
            state = "ERROR", reasonKey = "CLIENT_VIEW_ERROR", usable = false,
            rows = {}, rowCount = 0, readyEmpty = false,
            filteredNonStock = 0, filteredOnly = false,
            nextPageCursor = nil, pageCursor = nil, selectionKey = nil,
            selectionKind = "FARM", route = "STOCK",
            transportPagingPending = false, selectionMismatch = false,
        }
    end

    local rawState = snap.state
    local state = ALLOWED_STATES[rawState] and rawState or "UNAVAILABLE"
    local rawReason = snap.reason
    local reasonKey = nil
    if type(rawReason) == "string" and SAFE_REASONS[rawReason] then
        reasonKey = rawReason
    elseif type(rawReason) == "string" and rawReason:match("^TRANSPORT_") then
        reasonKey = "UNAVAILABLE"
    end

    local hostUsable = snap.usable == true
    local rows, rowProblem, meta = {}, nil, {}
    local readyEmpty = false
    local filteredOnly = false
    local selectionMismatch = false

    if state == "READY" then
        if type(snap.view) ~= "table" then
            state = "ERROR"
            reasonKey = "MALFORMED_VIEW"
            hostUsable = false
        else
            local expected = expectedKeyOf(host)
            local got = snap.view.selectionKey
            if expected ~= nil and (type(got) ~= "string" or got == "" or got ~= expected) then
                -- Missing/nonstring/wrong selectionKey while expected: do not paint private rows.
                selectionMismatch = true
                state = "WAITING"
                reasonKey = "SELECTION_MISMATCH"
                hostUsable = false
                rows = {}
            else
                rows, rowProblem, meta = A.projectRows(snap.view)
                meta = meta or {}
                if rowProblem == "NO_ROWS" or rowProblem == "NO_VIEW" then
                    if hostUsable and type(snap.view.rows) == "table" and #snap.view.rows == 0 then
                        readyEmpty = true
                    else
                        state = "ERROR"
                        reasonKey = "MALFORMED_VIEW"
                        hostUsable = false
                    end
                elseif rowProblem == "MALFORMED" then
                    state = "ERROR"
                    reasonKey = "MALFORMED_VIEW"
                    hostUsable = false
                    rows = {}
                elseif rowProblem == "INCOMPLETE" then
                    state = "ERROR"
                    reasonKey = "INCOMPLETE_ROWS"
                    hostUsable = false
                    rows = {}
                elseif rowProblem == "UNSUPPORTED" then
                    state = "ERROR"
                    reasonKey = "UNSUPPORTED_ROW_KIND"
                    hostUsable = false
                    rows = {}
                else
                    readyEmpty = hostUsable and #rows == 0
                end
            end
        end
    end

    local usable = hostUsable and state == "READY" and not selectionMismatch
    local nextCursor = meta.nextPageCursor
    local lastSel = A.lastSelection(mission)
    return {
        state = state,
        reasonKey = reasonKey,
        usable = usable,
        rows = rows,
        rowCount = #rows,
        readyEmpty = readyEmpty and usable,
        filteredNonStock = 0,
        filteredOnly = false,
        nextPageCursor = nextCursor,
        pageCursor = meta.pageCursor,
        selectionKey = meta.selectionKey,
        selectionKind = meta.selectionKind or lastSel.selectionKind,
        route = meta.route or lastSel.route,
        transportPagingPending = nextCursor ~= nil,
        selectionMismatch = selectionMismatch,
    }
end

function A.invalidateLocal(mission, reason)
    A.invalidateOffers(mission, reason or "INVALIDATED")
    local host = A.hostOf(mission)
    if host == nil or host.transport == nil then return end
    local why = reason or "UI_INVALIDATE"
    if type(host.transport.clearView) == "function" then
        pcall(host.transport.clearView, host.transport, why)
    end
end


-- =========================================================
-- Command / quote / result presentation (SG_COMMAND_2 consumer)
-- Actor mutation remains host-owned. UI only sends published actions.
-- =========================================================

local function commandState(host)
    if host == nil then return nil end
    if type(host._sg5CommandState) ~= "table" then
        host._sg5CommandState = {
            outstanding = nil,
            unusedQuote = nil,
            routeBanner = nil,
            lastTerminal = nil,
            quoteDeadlineRealMs = nil,
        }
    end
    return host._sg5CommandState
end

local function clearUnusedQuote(host, reason)
    local st = commandState(host)
    if st == nil then return end
    st.unusedQuote = nil
    st.quoteDeadlineRealMs = nil
    if reason ~= nil and st.routeBanner ~= nil and st.routeBanner.kind == "QUOTE" then
        st.routeBanner = nil
    end
end

--- Drop unused offers when page/focus/target/view/actor/farm changes. Never cancel outstanding send.
function A.invalidateOffers(mission, reason)
    local host = A.hostOf(mission)
    clearUnusedQuote(host, reason or "CONTEXT_CHANGED")
end

function A.getCommandState(mission)
    local host = A.hostOf(mission)
    return commandState(host)
end

local function credentialsOf(host)
    if host == nil or type(host.getClientView) ~= "function" then return nil end
    local ok, snap = pcall(host.getClientView)
    if not ok or type(snap) ~= "table" then return nil end
    local creds = snap.credentials
    if type(creds) ~= "table" and type(snap.view) == "table" then
        creds = {
            commandSessionId = snap.view.commandSessionId,
            nextSequence = snap.view.nextSequence,
        }
    end
    if type(creds) ~= "table" then return nil end
    local st = commandState(host)
    local sessionId = creds.commandSessionId
    local nextSeq = creds.nextSequence
    -- Prefer sequence adopted from the last correlated command result (SP may return
    -- before a view refresh). Never invent counters.
    if st ~= nil and type(st.clientNextSequence) == "string" and st.clientNextSequence ~= "" then
        if type(st.clientCommandSessionId) ~= "string" or st.clientCommandSessionId == sessionId then
            nextSeq = st.clientNextSequence
            if type(st.clientCommandSessionId) == "string" and st.clientCommandSessionId ~= "" then
                sessionId = st.clientCommandSessionId
            end
        end
    end
    if type(sessionId) ~= "string" or sessionId == "" then return nil end
    if type(nextSeq) ~= "string" and type(nextSeq) ~= "number" then return nil end
    return {
        commandSessionId = sessionId,
        nextSequence = tostring(nextSeq),
        route = type(snap.view) == "table" and snap.view.route or "STOCK",
    }
end

--- Real-seconds clock for quote display. Prefer getTimeSec (SGCommands / host);
--- it returns wall-clock seconds. Do not assume getTime() units.
local function realNowMs()
    -- Offline harness override (deterministic ms) wins when set.
    if type(_G) == "table" and type(_G._sg5NowMs) == "number" then
        return math.floor(_G._sg5NowMs)
    end
    -- Production: getTimeSec is wall-clock seconds (same source SGCommands uses).
    if type(getTimeSec) == "function" then
        local ok, t = pcall(getTimeSec)
        if ok and type(t) == "number" then return math.floor(t * 1000) end
    end
    if type(os) == "table" and type(os.clock) == "function" then
        return math.floor(os.clock() * 1000)
    end
    return 0
end

local function adoptResultSequence(host, res)
    if host == nil or type(res) ~= "table" then return end
    if res.nextSequence == nil then return end
    local st = commandState(host)
    if st ~= nil then
        st.clientNextSequence = tostring(res.nextSequence)
        if type(res.commandSessionId) == "string" and res.commandSessionId ~= "" then
            st.clientCommandSessionId = res.commandSessionId
        end
    end
    -- Refresh transport.client.credentials when present so next send sees result sequence.
    if host.transport ~= nil and host.transport.client ~= nil then
        local c = host.transport.client
        local sid = res.commandSessionId
        if type(sid) ~= "string" or sid == "" then
            sid = c.credentials and c.credentials.commandSessionId or nil
        end
        if type(sid) == "string" and sid ~= "" then
            c.credentials = { commandSessionId = sid, nextSequence = tostring(res.nextSequence) }
        end
    end
end

--- Apply a correlated command result. Mismatched results are discarded.
--- ACCEPTED_PENDING retains outstanding until a matching terminal completion
--- (same session/sequence/route/pendingId), matching SGCommands outstanding rules.
function A.applyCommandResult(mission, res)
    local host = A.hostOf(mission)
    local st = commandState(host)
    if st == nil or type(res) ~= "table" then return false, "NO_STATE" end
    if res.protocolVersion ~= nil and tonumber(res.protocolVersion) ~= 2 then
        return false, "PROTOCOL"
    end
    local out = st.outstanding

    -- Terminal completion of an accepted-pending command: matching identity required.
    if type(out) == "table" and out.pending == true then
        if res.protocolVersion ~= nil and tonumber(res.protocolVersion) ~= 2 then
            return false, "PROTOCOL"
        end
        if type(res.route) ~= "string" or res.route == "" then return false, "ROUTE_REQUIRED" end
        if out.route ~= nil and tostring(res.route) ~= tostring(out.route) then return false, "ROUTE_MISMATCH" end
        if res.commandSessionId ~= out.commandSessionId then return false, "SESSION_MISMATCH" end
        if tostring(res.sequence) ~= tostring(out.sequence) then return false, "SEQUENCE_MISMATCH" end
        -- actionId must match the outstanding send when present on the result.
        if type(res.actionId) == "string" and res.actionId ~= "" and res.actionId ~= out.actionId then
            return false, "ACTION_MISMATCH"
        end
        -- phase on completion results follows the original send when present.
        if type(res.phase) == "string" and res.phase ~= "" and res.phase ~= out.phase then
            return false, "PHASE_MISMATCH"
        end
        if type(out.pendingId) == "string" and out.pendingId ~= ""
            and type(res.actualPendingId) == "string" and res.actualPendingId ~= ""
            and res.actualPendingId ~= out.pendingId then
            return false, "PENDING_MISMATCH"
        end
        if res.outcome == "ACCEPTED_PENDING" then
            -- Duplicate pending ack: keep outstanding, refresh banner only.
            st.routeBanner = {
                kind = "ACCEPTED_PENDING",
                actionId = out.actionId,
                pendingId = out.pendingId or res.actualPendingId,
                outcome = "ACCEPTED_PENDING",
                reasonCode = res.reasonCode,
            }
            adoptResultSequence(host, res)
            return true, nil
        end
        -- Only allowed terminal outcomes clear an accepted-pending send.
        -- QUOTED / malformed / unknown must not end the operation.
        local TERMINAL_OK = {
            APPLIED = true, PARTIAL_UNAVAILABLE = true, REFUSED = true,
            STALE = true, UNAVAILABLE = true, STALE_QUOTE = true,
        }
        if TERMINAL_OK[res.outcome] ~= true then
            return false, "NOT_TERMINAL"
        end
        st.outstanding = nil
        st.lastTerminal = res
        clearUnusedQuote(host, "PENDING_COMPLETE")
        adoptResultSequence(host, res)
        st.routeBanner = {
            kind = "TERMINAL",
            actionId = out.actionId or res.actionId,
            outcome = tostring(res.outcome),
            reasonCode = res.reasonCode,
            effects = res.effects,
            currentTarget = res.currentTarget,
        }
        return true, nil
    end

    if type(out) ~= "table" then
        -- No open send: never accept unsolicited ACCEPTED_PENDING / terminals.
        return false, "NO_OUTSTANDING"
    end

    if res.commandSessionId ~= out.commandSessionId then return false, "SESSION_MISMATCH" end
    if tostring(res.sequence) ~= tostring(out.sequence) then return false, "SEQUENCE_MISMATCH" end
    if out.route ~= nil and res.route ~= nil and tostring(res.route) ~= tostring(out.route) then
        return false, "ROUTE_MISMATCH"
    end
    if res.phase ~= out.phase then return false, "PHASE_MISMATCH" end
    if res.actionId ~= out.actionId then return false, "ACTION_MISMATCH" end

    st.lastTerminal = res
    adoptResultSequence(host, res)

    if res.outcome == "QUOTED" and type(res.offer) == "table" and type(res.quoteToken) == "string" then
        -- Quote is not a blocking outstanding send; clear send marker and hold unused offer.
        st.outstanding = nil
        -- Drop late quotes if the client already left the originating selection.
        if type(out.selectionKey) == "string" and out.selectionKey ~= "" then
            local okSnap, snap = pcall(host.getClientView)
            if okSnap and type(snap) == "table" and type(snap.view) == "table"
                and snap.view.selectionKey ~= nil and snap.view.selectionKey ~= out.selectionKey then
                st.routeBanner = {
                    kind = "TERMINAL",
                    actionId = res.actionId,
                    outcome = "STALE_QUOTE",
                    reasonCode = "SELECTION_CHANGED",
                }
                return true, nil
            end
        end
        local remain = tonumber(res.validityRemainingMs) or 0
        if remain < 0 then remain = 0 end
        st.unusedQuote = {
            quoteToken = res.quoteToken,
            offer = res.offer,
            actionId = res.actionId,
            targetKind = out.targetKind,
            targetId = out.targetId,
            expectedRevision = out.expectedRevision,
            expectedGeneration = out.expectedGeneration,
            arguments = out.arguments,
            commandSessionId = res.commandSessionId or out.commandSessionId,
            nextSequence = res.nextSequence and tostring(res.nextSequence) or out.nextSequenceAfter,
            validityRemainingMs = remain,
            route = out.route,
            selectionKey = out.selectionKey,
            targetRevision = out.expectedRevision,
        }
        st.quoteDeadlineRealMs = realNowMs() + remain
        st.routeBanner = {
            kind = "QUOTE",
            actionId = res.actionId,
            validityRemainingMs = remain,
            offer = res.offer,
        }
        return true, nil
    end

    if res.outcome == "ACCEPTED_PENDING" then
        -- Retain outstanding + correlated pending identity (SGCommands keeps sequence).
        out.pending = true
        out.pendingId = res.actualPendingId
        out.phase = out.phase -- original send phase retained for correlation
        st.outstanding = out
        clearUnusedQuote(host, "ACCEPTED_PENDING")
        st.routeBanner = {
            kind = "ACCEPTED_PENDING",
            actionId = res.actionId,
            pendingId = res.actualPendingId,
            outcome = "ACCEPTED_PENDING",
            reasonCode = res.reasonCode,
        }
        return true, nil
    end

    -- Immediate terminal outcomes clear outstanding.
    st.outstanding = nil
    clearUnusedQuote(host, "RESULT")
    st.routeBanner = {
        kind = "TERMINAL",
        actionId = res.actionId,
        outcome = tostring(res.outcome or "UNAVAILABLE"),
        reasonCode = res.reasonCode,
        effects = res.effects,
        currentTarget = res.currentTarget,
    }
    return true, nil
end

function A.getQuoteRemainingMs(mission)
    local host = A.hostOf(mission)
    local st = commandState(host)
    if st == nil or st.unusedQuote == nil or st.quoteDeadlineRealMs == nil then return nil end
    local left = st.quoteDeadlineRealMs - realNowMs()
    if left < 0 then left = 0 end
    return left
end

--- Build and send one command. One outstanding only; repeats ignored while waiting.
function A.sendCommand(mission, phase, action, arguments)
    local host = A.hostOf(mission)
    if host == nil then return false, "NO_HOST" end
    local st = commandState(host)
    if st.outstanding ~= nil then
        return false, "OUTSTANDING"
    end
    if type(action) ~= "table" then return false, "NO_ACTION" end
    if action.available ~= true then return false, "ACTION_UNAVAILABLE" end
    local creds = credentialsOf(host)
    if creds == nil then return false, "NO_CREDENTIALS" end

    local req = {
        protocolVersion = 2,
        route = creds.route or "STOCK",
        commandSessionId = creds.commandSessionId,
        sequence = creds.nextSequence,
        phase = phase,
        actionId = action.actionId,
        targetKind = action.targetKind,
        targetId = action.targetId,
        expectedRevision = action.expectedRevision,
        expectedGeneration = action.expectedGeneration,
        arguments = type(arguments) == "table" and arguments or {},
    }
    if phase == "EXECUTE" then
        local q = st.unusedQuote
        if type(q) ~= "table" or type(q.quoteToken) ~= "string" then return false, "NO_QUOTE" end
        local left = A.getQuoteRemainingMs(mission)
        if left ~= nil and left <= 0 then
            clearUnusedQuote(host, "EXPIRED")
            return false, "QUOTE_EXPIRED"
        end
        req.quoteToken = q.quoteToken
        req.commandSessionId = q.commandSessionId or req.commandSessionId
        req.sequence = q.nextSequence or req.sequence
        req.actionId = q.actionId
        req.targetKind = q.targetKind
        req.targetId = q.targetId
        req.expectedRevision = q.expectedRevision
        req.expectedGeneration = q.expectedGeneration
        req.arguments = q.arguments or {}
    elseif phase == "QUOTE" then
        if action.admission ~= "QUOTED" then return false, "NOT_QUOTABLE" end
    elseif phase == "DIRECT" then
        if action.admission ~= "DIRECT_DESIRED_STATE" then return false, "QUOTE_REQUIRED" end
    else
        return false, "BAD_PHASE"
    end

    local selKey = nil
    do
        local okSnap, snap = pcall(host.getClientView)
        if okSnap and type(snap) == "table" and type(snap.view) == "table" then
            selKey = snap.view.selectionKey
        end
    end
    st.outstanding = {
        commandSessionId = req.commandSessionId,
        sequence = tostring(req.sequence),
        phase = req.phase,
        actionId = req.actionId,
        targetKind = req.targetKind,
        targetId = req.targetId,
        expectedRevision = req.expectedRevision,
        expectedGeneration = req.expectedGeneration,
        arguments = req.arguments,
        route = req.route,
        selectionKey = selKey,
        pending = false,
        pendingId = nil,
        nextSequenceAfter = nil,
    }
    st.routeBanner = {
        kind = "SENT_AWAITING",
        actionId = req.actionId,
        phase = req.phase,
    }

    if type(host.submitCommand) ~= "function" then
        st.outstanding = nil
        st.routeBanner = nil
        return false, "NO_SUBMIT"
    end
    local okCall, aRes, bRes = pcall(host.submitCommand, req)
    if not okCall then
        st.outstanding = nil
        st.routeBanner = { kind = "TERMINAL", actionId = req.actionId, outcome = "UNAVAILABLE", reasonCode = "SUBMIT_ERROR" }
        return false, "SUBMIT_ERROR"
    end
    if aRes == false then
        st.outstanding = nil
        st.routeBanner = { kind = "TERMINAL", actionId = req.actionId, outcome = "UNAVAILABLE", reasonCode = tostring(bRes or "SUBMIT_FALSE") }
        return false, tostring(bRes or "SUBMIT_FALSE")
    end
    -- Synchronous SP path may already deliver result via callback before return.
    return true, nil
end

--- Resolve a live published action from the current usable view (not a stale paint cache).
function A.findCurrentAction(mission, actionId, targetKind, targetId)
    local host = A.hostOf(mission)
    if host == nil or type(host.getClientView) ~= "function" then return nil, "NO_HOST" end
    local ok, snap = pcall(host.getClientView)
    if not ok or type(snap) ~= "table" or snap.usable ~= true or snap.state ~= "READY" then
        return nil, "VIEW_UNUSABLE"
    end
    if type(snap.view) ~= "table" or type(snap.view.rows) ~= "table" then
        return nil, "NO_ROWS"
    end
    for _, row in ipairs(snap.view.rows) do
        if type(row) == "table" and type(row.actions) == "table" then
            for _, raw in ipairs(row.actions) do
                if type(raw) == "table"
                    and raw.actionId == actionId
                    and raw.targetKind == targetKind
                    and raw.targetId == targetId then
                    local list = projectActions({ raw }, nil)
                    return list[1], nil
                end
            end
        end
    end
    return nil, "ACTION_GONE"
end

--- True when argumentSchema requires gathered args and none were supplied / context absent.
local function argumentsReady(action, arguments)
    if type(action) ~= "table" then return false, "NO_ACTION" end
    local schema = action.argumentSchemaId
    if schema == nil or schema == "" then return false, "NO_SCHEMA" end
    -- Empty argument map schemas (stop/discard) are ready with {}.
    if schema == "SG4_STOP_PREPARATION_1" or schema == "SG4_DISCARD_PREPARATION_1" then
        return true, nil
    end
    if schema == "SG_SET_PRODUCTION_ENABLED_1" then
        if type(arguments) == "table" and arguments.enabled ~= nil then return true, nil end
        return false, "ARGS_REQUIRED"
    end
    if schema == "SG_NATIVE_SET_OUTPUT_MODE_1" or schema == "SG_SET_OUTPUT_MODE_1" then
        if type(arguments) ~= "table" then return false, "ARGS_REQUIRED" end
        if type(arguments.fillTypeName) ~= "string" or arguments.fillTypeName == "" then
            return false, "ARGS_REQUIRED"
        end
        if type(arguments.modeId) ~= "string" or arguments.modeId == "" then
            return false, "ARGS_REQUIRED"
        end
        return true, nil
    end
    if schema == "SG4_START_PREPARATION_1"
        or schema == "SG4_RECOVER_PARTIAL_OUTPUT_1" or schema == "SG4_PUMP_OUT_PREPARATION_1"
        or schema == "SG4_SAVE_RECIPE_1" or schema == "SG4_RETIRE_RECIPE_1" then
        -- Presentation does not gather these yet; refuse empty. Non-empty args are
        -- only for harnesses — UI keeps chips non-executable via projectActions.
        if type(arguments) ~= "table" then return false, "ARGS_REQUIRED" end
        local n = 0
        for _ in pairs(arguments) do n = n + 1 end
        if n == 0 then
            if action.argumentContext == nil then return false, "CONTEXT_ABSENT" end
            return false, "ARGS_FORMS_ABSENT"
        end
        return true, nil
    end
    -- Unknown schema: refuse rather than send {}.
    if type(arguments) ~= "table" then return false, "ARGS_REQUIRED" end
    local n = 0
    for _ in pairs(arguments) do n = n + 1 end
    if n == 0 then return false, "ARGS_REQUIRED" end
    return true, nil
end

function A.beginAction(mission, action, arguments)
    if type(action) ~= "table" then return false, "NO_ACTION" end
    local live, why = A.findCurrentAction(mission, action.actionId, action.targetKind, action.targetId)
    if live == nil then return false, why or "ACTION_GONE" end
    if live.available ~= true then return false, "ACTION_UNAVAILABLE" end
    if live.expectedRevision ~= action.expectedRevision then
        -- Stale revision vs current publication.
        return false, "REVISION_STALE"
    end
    local ready, argWhy = argumentsReady(live, arguments)
    if not ready then return false, argWhy or "ARGS_REQUIRED" end
    if live.admission == "QUOTED" then
        return A.sendCommand(mission, "QUOTE", live, arguments)
    end
    return A.sendCommand(mission, "DIRECT", live, arguments)
end

function A.confirmQuote(mission)
    local host = A.hostOf(mission)
    local st = commandState(host)
    if st == nil or type(st.unusedQuote) ~= "table" then return false, "NO_QUOTE" end
    local q = st.unusedQuote
    -- Current-view / target / access check before execute.
    local live, why = A.findCurrentAction(mission, q.actionId, q.targetKind, q.targetId)
    if live == nil then
        clearUnusedQuote(host, "ACTION_GONE")
        return false, why or "ACTION_GONE"
    end
    if live.available ~= true then
        clearUnusedQuote(host, "ACTION_UNAVAILABLE")
        return false, "ACTION_UNAVAILABLE"
    end
    if live.expectedRevision ~= q.expectedRevision then
        clearUnusedQuote(host, "REVISION_STALE")
        return false, "REVISION_STALE"
    end
    local okSnap, snap = pcall(host.getClientView)
    if okSnap and type(snap) == "table" and type(snap.view) == "table" then
        if q.selectionKey ~= nil and snap.view.selectionKey ~= q.selectionKey then
            clearUnusedQuote(host, "SELECTION_CHANGED")
            return false, "SELECTION_CHANGED"
        end
        if snap.usable ~= true or snap.state ~= "READY" then
            clearUnusedQuote(host, "VIEW_UNUSABLE")
            return false, "VIEW_UNUSABLE"
        end
    end
    local action = {
        actionId = q.actionId,
        targetKind = q.targetKind,
        targetId = q.targetId,
        expectedRevision = q.expectedRevision,
        expectedGeneration = q.expectedGeneration,
        available = true,
        admission = "QUOTED",
        argumentSchemaId = live.argumentSchemaId or "EXECUTE",
        controlKind = live.controlKind or "ORDINARY",
        argumentContext = live.argumentContext,
    }
    return A.sendCommand(mission, "EXECUTE", action, q.arguments)
end

function A.cancelUnusedQuote(mission, reason)
    local host = A.hostOf(mission)
    clearUnusedQuote(host, reason or "CANCELLED")
    local st = commandState(host)
    if st ~= nil and st.routeBanner ~= nil and st.routeBanner.kind == "QUOTE" then
        st.routeBanner = nil
    end
    return true, nil
end

function A.getCommandPaint(mission)
    local host = A.hostOf(mission)
    local st = commandState(host)
    if st == nil then
        return { banner = nil, quote = nil, outstanding = false, remainingMs = nil }
    end
    local remaining = A.getQuoteRemainingMs(mission)
    if st.unusedQuote ~= nil and remaining ~= nil and remaining <= 0 then
        clearUnusedQuote(host, "EXPIRED")
        st.routeBanner = {
            kind = "TERMINAL",
            actionId = st.lastTerminal and st.lastTerminal.actionId or nil,
            outcome = "STALE_QUOTE",
            reasonCode = "QUOTE_EXPIRED",
        }
    end
    return {
        banner = st.routeBanner,
        quote = st.unusedQuote,
        outstanding = st.outstanding ~= nil,
        remainingMs = A.getQuoteRemainingMs(mission),
        lastTerminal = st.lastTerminal,
    }
end

