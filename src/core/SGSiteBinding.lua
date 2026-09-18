-- =========================================================
-- FS25_StockGuard - SITE_V1 provider binding (SG-1 4.6)
-- =========================================================
-- One selected site-provider binding per mission. The current binding
-- resolves WT-8 through the existing mission.workplaceTriggers handle and
-- requires the SITE_V1 capability: getSiteCapabilities schema/readiness and
-- every admitted method, then a true registerSitePurpose("stockguard.yard",
-- {class="FARM", label=...}). All provider methods are dot-bound closures on
-- the handle (WorkplaceSiteService.installAdapters), so no implicit self is
-- supplied. Every call is guarded and pcalled; an exception, incompatible
-- schema, missing method or not-ready capability is unavailable and FARM
-- remains useful. StockGuard consumes detached reads, never the provider's
-- wire format, and never stores site geometry.
-- =========================================================

SGSiteBinding = SGSiteBinding or {}
local B = SGSiteBinding
local SGSiteBinding_mt = { __index = B }

B.SCHEMA = "SITE_V1"
B.PURPOSE = "stockguard.yard"
B.CONSUMER_ID = "stockGuard"
B.REQUIRED_METHODS = { "getSiteCapabilities", "getSitesForFarm", "getSite", "subscribeSiteChanges", "unsubscribeSiteChanges", "openSiteManager", "registerSitePurpose" }

local isFinite = SGValues.isFinite

function B.new()
    local self = setmetatable({}, SGSiteBinding_mt)
    self.handle = nil
    self.available = false
    self.reasonCode = "NOT_BOUND"
    self.purposeRegistered = false
    self.subscribed = false
    self.onChanged = nil     -- function(siteId, revision, kind, ownerFarmId)
    self.changeCount = 0
    return self
end

local function callDot(handle, name, ...)
    local fn = handle[name]
    if type(fn) ~= "function" then return false, "MISSING_METHOD" end
    return pcall(fn, ...)
end

--- Try to bind the provider on the mission handle. Returns available, reason.
function B:bind(mission, label)
    self.available = false
    local handle = mission ~= nil and mission.workplaceTriggers or nil
    if type(handle) ~= "table" then
        self.reasonCode = "NO_PROVIDER"
        return false, self.reasonCode
    end
    for _, m in ipairs(B.REQUIRED_METHODS) do
        if type(handle[m]) ~= "function" then
            self.reasonCode = "MISSING_METHOD"
            return false, self.reasonCode
        end
    end
    local ok, caps = callDot(handle, "getSiteCapabilities")
    if not ok or type(caps) ~= "table" then
        self.reasonCode = "CAPABILITY_ERROR"
        return false, self.reasonCode
    end
    if caps.schema ~= B.SCHEMA then
        self.reasonCode = "INCOMPATIBLE_SCHEMA"
        return false, self.reasonCode
    end
    if caps.ready ~= true then
        self.reasonCode = tostring(caps.reasonCode or "NOT_READY")
        self.handle = handle
        return false, self.reasonCode
    end
    if not self.purposeRegistered then
        local okReg, registered, why = callDot(handle, "registerSitePurpose", B.PURPOSE, { class = "FARM", label = label or B.PURPOSE })
        if not okReg or registered ~= true then
            self.reasonCode = "PURPOSE_REFUSED:" .. tostring(okReg and why or registered)
            self.handle = handle
            return false, self.reasonCode
        end
        self.purposeRegistered = true
    end
    self.handle = handle
    if not self.subscribed then
        local binding = self
        local okSub, subscribed = callDot(handle, "subscribeSiteChanges", B.CONSUMER_ID, function(siteId, revision, kind, ownerFarmId)
            binding.changeCount = binding.changeCount + 1
            if type(binding.onChanged) == "function" then pcall(binding.onChanged, siteId, revision, kind, ownerFarmId) end
        end)
        self.subscribed = okSub and subscribed == true
    end
    self.available = true
    self.reasonCode = "READY"
    return true, self.reasonCode
end

--- Validate one detached SITE_V1 definition; only ACTIVE with sane geometry
--- is admitted for grouping.
function B.validateSite(s)
    if type(s) ~= "table" then return nil end
    if not SGRecords.nonemptyString(s.siteId, 128) then return nil end
    if not SGRecords.isOrdinaryFarmId(s.ownerFarmId) then return nil end
    if type(s.name) ~= "string" or #s.name < 1 or #s.name > 128 then return nil end
    if not isFinite(s.centreX) or not isFinite(s.centreZ) or not isFinite(s.radiusMetres) or s.radiusMetres < 1 then return nil end
    if s.state ~= "ACTIVE" then return nil end
    return {
        siteId = s.siteId, ownerFarmId = s.ownerFarmId, purpose = s.purpose, name = s.name,
        centreX = s.centreX, centreZ = s.centreZ, radiusMetres = s.radiusMetres,
        revision = tostring(s.revision or ""), state = "ACTIVE",
    }
end

--- Actor-authorized ACTIVE sites, detached. On the server a trusted actor
--- context is required; on a client the provider uses its local replica.
function B:sitesFor(trustedActorContext)
    if not self.available or self.handle == nil then return nil, self.reasonCode end
    local ok, list, reason = callDot(self.handle, "getSitesForFarm", trustedActorContext)
    if not ok or type(list) ~= "table" then return nil, tostring(ok and reason or "PROVIDER_ERROR") end
    local out = {}
    for _, s in ipairs(list) do
        local v = B.validateSite(s)
        if v ~= nil then out[#out + 1] = v end
    end
    table.sort(out, function(a, b) return a.siteId < b.siteId end)
    return out, "OK"
end

function B:site(siteId, trustedActorContext)
    if not self.available or self.handle == nil then return nil, self.reasonCode end
    local ok, s, reason = callDot(self.handle, "getSite", siteId, trustedActorContext)
    if not ok or type(s) ~= "table" then return nil, tostring(ok and reason or "PROVIDER_ERROR") end
    local v = B.validateSite(s)
    if v == nil then return nil, "SITE_UNAVAILABLE" end
    return v, "OK"
end

--- Client-local navigation into the provider's editor.
function B:openSiteManager(selection)
    if self.handle == nil then return false end
    local ok, opened = callDot(self.handle, "openSiteManager", selection)
    return ok and opened == true
end

--- Pure membership test: a carrier at (x, z) is inside the site circle.
function B.contains(site, x, z)
    if site == nil or not isFinite(x) or not isFinite(z) then return false end
    local dx, dz = x - site.centreX, z - site.centreZ
    return dx * dx + dz * dz <= site.radiusMetres * site.radiusMetres
end

function B:unbind()
    if self.handle ~= nil and self.subscribed then
        pcall(function() self.handle.unsubscribeSiteChanges(B.CONSUMER_ID) end)
    end
    self.subscribed = false
    self.available = false
    self.handle = nil
    self.reasonCode = "NOT_BOUND"
end
