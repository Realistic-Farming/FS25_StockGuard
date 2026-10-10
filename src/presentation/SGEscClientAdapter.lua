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

-- [REPAIR-365 major3] This guest's own UI state.
-- SG-5 :45 says the guest does not add APIs or expose private native internals, and the
-- published handle is shared by every consumer, so focus, last selection and command UI
-- state live in THIS module instead of on mission.stockGuard. The table is keyed weakly by
-- the handle, which is per-mission, so state is isolated per mission and per farm or
-- context exactly as before and a collected mission takes its entry with it.
local _uiState = setmetatable({}, { __mode = "k" })

--- This module's UI state for a host handle. nil host yields nil, never a shared default.
local function uiFor(host)
    if host == nil then return nil end
    local u = _uiState[host]
    if u == nil then
        u = {}
        _uiState[host] = u
    end
    return u
end

--- Store a focus state in this module. No-op without a handle, so no shared default.
local function setFocus(host, st)
    local u = uiFor(host)
    if u ~= nil then u.focus = st end
end

--- Drop this module's UI state. Used by the per-mission reset; never touches the handle.
function A.clearUiState(mission)
    local host = A.hostOf(mission)
    if host ~= nil then
        _uiState[host] = nil
    end
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

--- One stable consumer id for this guest's whole client-controller lifetime, per the
--- brief's catalogue lifecycle. Never per view, per farm or per paint.
A.SITE_CONSUMER_ID = "stockGuard.sg5"

--- Which parts of the published WT8 catalogue lifecycle this provider actually offers.
--- Absent methods are reported, never worked around.
--- @return boolean ok, string|nil reason
function A.siteLifecycle(mission)
    local wt = A.siteProvider(mission)
    if wt == nil then return false, "SITE_PROVIDER_ABSENT" end
    if type(wt.getSite) ~= "function" then return false, "SITE_GET_ABSENT" end
    if type(wt.subscribeSiteChanges) ~= "function" then return false, "SITE_SUBSCRIBE_ABSENT" end
    if type(wt.unsubscribeSiteChanges) ~= "function" then return false, "SITE_UNSUBSCRIBE_ABSENT" end
    return true, nil
end

--- This guest's own site lifecycle state. Lives in this module, like every other piece of
--- its UI state, and never on the published handle.
local function siteState(host)
    local u = uiFor(host)
    if u == nil then return nil end
    if type(u.site) ~= "table" then
        u.site = { bound = false, boundTo = nil, catalogueStale = false,
                   selectedStale = false, offeredRevision = nil }
    end
    return u.site
end

--- The invalidation callback. This is ALL it does.
--- It marks state stale and returns: no provider read, no request, no render, and the
--- notice payload is compared transiently and then dropped rather than stored or shown.
local function onSiteNotice(host, siteId, _revision, _kind, _ownerFarmId)
    local st = siteState(host)
    if st == nil then return end
    st.catalogueStale = true
    local u = uiFor(host)
    local sel = u ~= nil and u.lastSelection or nil
    local selId = nil
    if type(sel) == "table" and sel.selectionKind == "SITE" and type(sel.siteId) == "string" then
        selId = sel.siteId
    end
    if selId == nil then return end
    -- Names the selected site, or cannot be matched at all: the selected page is stale.
    if type(siteId) ~= "string" or siteId == selId then
        st.selectedStale = true
    end
end

--- Bind the one consumer id. Idempotent, so a repeated show cannot leak a second binding.
--- @return boolean bound, string|nil reason
function A.bindSiteChanges(mission)
    local host = A.hostOf(mission)
    if host == nil then return false, "NO_HOST" end
    local st = siteState(host)
    if st == nil then return false, "NO_STATE" end
    local wt = A.siteProvider(mission)

    -- [NOTE-375] A bound flag is not enough: the provider handle can be REPLACED, and the
    -- replacement guarantees no callback of its own. If this is a different object then our
    -- subscription lives on the old one, so drop that id there first.
    -- [REPAIR-377] This release runs BEFORE the replacement is validated, and on
    -- disappearance as well as on a change of identity. It used to sit below the
    -- A.siteLifecycle check, so a complete provider replaced by nil, or by one missing
    -- getSite, returned on that check and left this consumer id subscribed on the old
    -- object while the state still claimed to be bound to it.
    if st.bound and (wt == nil or st.boundTo ~= wt) then
        if st.boundTo ~= nil and type(st.boundTo.unsubscribeSiteChanges) == "function" then
            pcall(function() st.boundTo.unsubscribeSiteChanges(A.SITE_CONSUMER_ID) end)
        end
        st.bound, st.boundTo = false, nil
        -- A new provider has told us nothing yet, so treat what we hold as unverified.
        st.catalogueStale, st.selectedStale = true, true
    end

    -- Only now is the replacement judged. A bad facade is reported as it always was; no
    -- fallback subscription is invented for it.
    local ok, why = A.siteLifecycle(mission)
    if not ok then return false, why end
    -- Same object, still bound: idempotent, so a repeated show cannot leak a second binding.
    if st.bound then return true, nil end

    local okCall, accepted = pcall(function()
        return wt.subscribeSiteChanges(A.SITE_CONSUMER_ID, function(siteId, revision, kind, ownerFarmId)
            onSiteNotice(host, siteId, revision, kind, ownerFarmId)
        end)
    end)
    if not okCall or accepted ~= true then return false, "SITE_SUBSCRIBE_REFUSED" end
    st.bound = true
    st.boundTo = wt
    -- A fresh binding has not verified anything yet, so the catalogue starts stale.
    st.catalogueStale = true
    return true, nil
end

--- Unbind THIS consumer id only. Idempotent and safe with no provider present.
function A.unbindSiteChanges(mission)
    local host = A.hostOf(mission)
    if host == nil then return false end
    local st = siteState(host)
    if st == nil or not st.bound then return false end
    -- [NOTE-375] Unsubscribe from the object we actually bound to, not merely whatever
    -- resolves now, so a replaced provider cannot leave this consumer id behind on the old
    -- one. Falls back to the current provider when we never recorded the binding target.
    local wt = st.boundTo or A.siteProvider(mission)
    if wt ~= nil and type(wt.unsubscribeSiteChanges) == "function" then
        pcall(function() wt.unsubscribeSiteChanges(A.SITE_CONSUMER_ID) end)
    end
    st.bound, st.boundTo = false, nil
    return true
end

--- True while the picker is showing state it has not re-verified since a notice.
function A.siteStale(mission)
    local st = siteState(A.hostOf(mission))
    if st == nil then return false, false end
    return st.catalogueStale == true, st.selectedStale == true
end

--- Remember the provider revision of the entry the picker offered, so a later change can be
--- noticed. The brief keeps this for that purpose only; it never rides a selection.
function A.noteOfferedSiteRevision(mission, revision)
    local st = siteState(A.hostOf(mission))
    if st ~= nil then st.offeredRevision = revision end
end

--- Drop every piece of picker state. Used on farm or local-actor invalidation and on
--- teardown, so another farm's site names can never be painted from a cached list.
function A.clearSiteState(mission)
    local host = A.hostOf(mission)
    if host == nil then return end
    local u = uiFor(host)
    if u ~= nil then u.site = nil end
end

--- Re-read the selected site from the OWN-FARM public replica and say what it found.
--- Called from the existing show or light refresh, never from the notice callback.
--- @return string status  OK | CHANGED | GONE | WAITING | UNSUPPORTED | NOT_SITE | NO_HOST
function A.verifySelectedSite(mission)
    local host = A.hostOf(mission)
    if host == nil then return "NO_HOST" end
    local st = siteState(host)
    local u = uiFor(host)
    local sel = u ~= nil and u.lastSelection or nil
    if type(sel) ~= "table" or sel.selectionKind ~= "SITE" or type(sel.siteId) ~= "string" then
        if st ~= nil then st.catalogueStale = false st.selectedStale = false end
        return "NOT_SITE"
    end
    local wt = A.siteProvider(mission)
    if wt == nil or type(wt.getSite) ~= "function" then return "UNSUPPORTED" end

    -- Membership first, from the own-farm ACTIVE list. nil context is the local actor's
    -- replica (WorkplaceSiteService.lua :847-856), never the server store.
    local okList, sites, listWhy = pcall(function() return wt.getSitesForFarm(nil) end)
    if not okList then return "WAITING" end
    if sites == nil then
        -- A ready capability that still answers NOT_READY is waiting, not an empty list.
        return "WAITING"
    end
    if type(sites) ~= "table" then return "WAITING" end
    local listed, listedRevision = false, nil
    for _, s in ipairs(sites) do
        if type(s) == "table" and s.siteId == sel.siteId then
            listed, listedRevision = true, s.revision
            break
        end
    end

    -- Then the single authoritative record the brief names.
    local okOne, site, oneWhy = pcall(function() return wt.getSite(sel.siteId, nil) end)
    if not okOne then return "WAITING" end
    if site == nil then
        if tostring(oneWhy or "") == "NOT_READY" then return "WAITING" end
        return "GONE"
    end
    if type(site) ~= "table" then return "WAITING" end
    if not listed then return "GONE" end

    local rev = site.revision ~= nil and site.revision or listedRevision
    local changed = st ~= nil and st.offeredRevision ~= nil and rev ~= nil
        and tostring(rev) ~= tostring(st.offeredRevision)
    if st ~= nil then
        -- A verified read is what clears the stale marks, nothing else.
        st.catalogueStale = false
        st.selectedStale = false
        st.offeredRevision = rev
    end
    return changed and "CHANGED" or "OK"
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
    local u = uiFor(host)
    return u ~= nil and u.focus or nil
end

local function clearFocusState(host, reason)
    if host == nil then return end
    local u = uiFor(host)
    if u ~= nil then u.focus = nil end
end

--- [REPAIR-371] Put a previously captured focus state back, for the guest's own
--- snapshot-and-restore on a refused entry. The mirror of A.getFocusState, which the
--- snapshot already uses to capture it. Exists so the guest never has to reach for the
--- published handle to restore what this module owns.
function A.restoreFocusState(mission, st)
    local host = A.hostOf(mission)
    if host == nil then return false end
    setFocus(host, st)
    return true
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
    local u = uiFor(host)
    local st = u ~= nil and u.focus or nil
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
            setFocus(host, {
                mode = "PENDING",
                ownerObject = focus.ownerObject,
                carrierId = nil,
                expectedCarrierId = focus.carrierId,
                adopted = false,
            })
            local ok, why = A.requestSelection(mission, { route = "STOCK", selectionKind = "FARM" }, {})
            return ok, why or nil
        end
        setFocus(host, {
            mode = "FOCUSED",
            carrierId = focus.carrierId,
            ownerObject = focus.ownerObject,
            expectedCarrierId = focus.carrierId,
            adopted = true,
        })
        local ok, why = A.requestSelection(mission, { route = "STOCK", selectionKind = "FARM" }, {
            navigationCarrierId = focus.carrierId,
        })
        return ok, why
    end

    -- ownerObject live, address missing: pending local intention + FARM waiting.
    if not A.isOwnerObjectLive(focus.ownerObject) then
        return false, "FOCUS_UNAVAILABLE"
    end
    setFocus(host, {
        mode = "PENDING",
        ownerObject = focus.ownerObject,
        carrierId = nil,
        expectedCarrierId = nil,
        adopted = false,
    })
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
    local u = uiFor(host)
    local st = u ~= nil and u.focus or nil
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
    local u = uiFor(host)
    if u ~= nil then u.lastSelection = copySelection(norm) end
    return true, nil
end

function A.requestFarmStockView(mission, readOptions)
    return A.requestSelection(mission, { route = "STOCK", selectionKind = "FARM" }, readOptions)
end

function A.lastSelection(mission)
    local host = A.hostOf(mission)
    local u = uiFor(host)
    if u == nil or type(u.lastSelection) ~= "table" then
        return { route = "STOCK", selectionKind = "FARM" }
    end
    return copySelection(u.lastSelection)
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
            -- [REPAIR-365 major3] The expected-key check read host.transport.client, which
            -- the published handle does not expose (src/StockGuard.lua), so it never ran in
            -- production. It is also redundant: SG-1's own transport drops a late
            -- publication for another selection at SGTransport.lua:227, from the expectedKey
            -- it sets at :263 off the client's own request. The guest has no published way
            -- to compute that key and must not reach past the handle for it.
            -- selectionMismatch stays declared and reported so the paint contract is
            -- unchanged; nothing sets it here now, which is what production already did.
            do
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
    -- [REPAIR-365 major3] Clears only this guest's own offer state. This used to call
    -- host.transport.clearView, which the published handle does not expose, so it cleared
    -- nothing in production; and had the host ever resolved to the member it would have
    -- cleared EVERY route (SGTransport.lua:239-254), against SG-5 :101 which has the
    -- library shown unavailable while stock is unaffected.
    A.invalidateOffers(mission, reason or "INVALIDATED")
end


-- =========================================================
-- Command / quote / result presentation (SG_COMMAND_2 consumer)
-- Actor mutation remains host-owned. UI only sends published actions.
-- =========================================================

local function commandState(host)
    if host == nil then return nil end
    local u = uiFor(host)
    if u == nil then return nil end
    if type(u.command) ~= "table" then
        u.command = {
            outstanding = nil,
            unusedQuote = nil,
            routeBanner = nil,
            lastTerminal = nil,
            quoteDeadlineRealMs = nil,
        }
    end
    return u.command
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
    -- [REPAIR-371] The standard-library clock fallback that used to sit here is removed.
    -- That library's time functions are not available in the FS25 Lua sandbox, which the
    -- repo's own lint rule states, and this file is added by THIS PR, so it was our defect
    -- rather than inherited debt. With no authorized clock the honest answer is the zero
    -- below: a quote deadline is then not counted down at all, instead of being counted
    -- against a clock the sandbox does not provide.
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
    -- [REPAIR-365 major3] The transport credential refresh is gone. It wrote
    -- host.transport.client.credentials, which the published handle does not expose, so it
    -- never happened in production; had the host resolved to the member it would have
    -- replaced SG-1's per-view credentials (SGTransport.lua:235) against SG-5 :103, which
    -- makes those credentials the host's to issue per view. This guest keeps only its own
    -- copy in its own command state, written just above.
end

--- [REPAIR-365 major2] Is a command actually sendable right now?
--- SG-5 :103 sends commands only with commandSessionId and nextSequence on the current
--- view, and names "no action offered" as the fallback. This TESTS for a host capability;
--- it does not add, implement or stand in for one. The published handle
--- (src/StockGuard.lua) has no submitCommand, so today this refuses and the UI offers
--- nothing. If a host ever publishes submitCommand, this starts answering true on its own.
--- @return boolean ok, string|nil reason
function A.canSubmit(mission)
    local host = A.hostOf(mission)
    if host == nil then return false, "NO_HOST" end
    if type(host.submitCommand) ~= "function" then return false, "NO_SUBMIT" end
    local creds = credentialsOf(host)
    if type(creds) ~= "table" then return false, "NO_CREDENTIALS" end
    if type(creds.commandSessionId) ~= "string" or creds.commandSessionId == "" then
        return false, "NO_COMMAND_SESSION"
    end
    if creds.nextSequence == nil or tostring(creds.nextSequence) == "" then
        return false, "NO_NEXT_SEQUENCE"
    end
    return true, nil
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
        -- only for harnesses. UI keeps chips non-executable via projectActions.
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

