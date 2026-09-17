-- SG-1-host_spec_test.lua - SITE_V1 binding, views and paging, command
-- sessions, transport (NS-7 join, fallback events) and the mission handle
-- lifecycle including the SG-6 finished-loading chain.
--
--!load: src/capacity/SGSha256.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua

FarmManager = FarmManager or { SPECTATOR_FARM_ID = 0, SINGLEPLAYER_FARM_ID = 1, GUIDED_TOUR_FARM_ID = 14, INVALID_FARM_ID = 15, MAX_FARM_ID = 8, MAX_NUM_FARMS = 8 }
local clock = 100
getTimeSec = function() return clock end

local wheat = { kind = "FILL_TYPE", fillTypeName = "WHEAT" }
local function binding(owner, comp)
    return { carrierKey = { adapterId = "sg2", nativeOwnerKey = owner, componentKey = comp }, adapterVersion = 1, profileId = "silo", profileVersion = 1, quantityBasisKey = owner .. "/" .. comp }
end

-- (G) SITE_V1 binding through a dot-bound handle
do
    local calls = {}
    local subscribed = nil
    local function handle(overrides)
        local h = {
            getSiteCapabilities = function(...) calls[#calls + 1] = { "caps", select("#", ...) } return { schema = "SITE_V1", ready = true, reasonCode = "READY" } end,
            getSitesForFarm = function(ctx) return { { siteId = "s1", ownerFarmId = 1, name = "Main Yard", centreX = 0, centreZ = 0, radiusMetres = 50, revision = "3", state = "ACTIVE" },
                { siteId = "s2", ownerFarmId = 1, name = "Gone", centreX = 500, centreZ = 0, radiusMetres = 50, revision = "1", state = "UNAVAILABLE" } } end,
            getSite = function(siteId, ctx) if siteId == "s1" then return { siteId = "s1", ownerFarmId = 1, name = "Main Yard", centreX = 0, centreZ = 0, radiusMetres = 50, revision = "3", state = "ACTIVE" } end return nil, "NOT_FOUND" end,
            subscribeSiteChanges = function(consumerId, cb) subscribed = { consumerId, cb } return true end,
            unsubscribeSiteChanges = function(consumerId) subscribed = nil return true end,
            openSiteManager = function(sel) return sel ~= nil end,
            registerSitePurpose = function(token, spec) calls[#calls + 1] = { "purpose", token, spec.class, spec.label } return true end,
        }
        for k, v in pairs(overrides or {}) do h[k] = v end
        return h
    end
    local b = SGSiteBinding.new()
    T.eq("G1 no provider handle is unavailable", select(2, b:bind({}, "Yard")), "NO_PROVIDER")
    local missing = handle()
    missing.getSite = nil
    T.eq("G2 a missing method is unavailable", select(2, b:bind({ workplaceTriggers = missing }, "Yard")), "MISSING_METHOD")
    T.eq("G3 a wrong schema is unavailable", select(2, b:bind({ workplaceTriggers = handle({ getSiteCapabilities = function() return { schema = "SITE_V2", ready = true } end }) }, "Yard")), "INCOMPATIBLE_SCHEMA")
    T.eq("G4 not ready keeps its reason", select(2, b:bind({ workplaceTriggers = handle({ getSiteCapabilities = function() return { schema = "SITE_V1", ready = false, reasonCode = "NOT_READY" } end }) }, "Yard")), "NOT_READY")
    T.eq("G5 a refused purpose keeps SITE off", select(2, b:bind({ workplaceTriggers = handle({ registerSitePurpose = function() return false, "UNKNOWN_CLASS" end }) }, "Yard")):sub(1, 15), "PURPOSE_REFUSED")
    local ok, reason = b:bind({ workplaceTriggers = handle() }, "Yard")
    T.eq("G6 bound when capability, methods and purpose agree", tostring(ok) .. "/" .. reason, "true/READY")
    T.eq("G7 capabilities were called with no implicit self", calls[#calls - 1] and calls[#calls - 1][2] or -1, 0)
    T.eq("G8 purpose registered as stockguard.yard FARM with the label", calls[#calls][2] .. "/" .. calls[#calls][3] .. "/" .. calls[#calls][4], "stockguard.yard/FARM/Yard")
    T.eq("G9 subscribed under the stockGuard consumer id", subscribed[1], "stockGuard")
    local sites = b:sitesFor({ farmId = 1 })
    T.eq("G10 only ACTIVE definitions are admitted", #sites .. "/" .. sites[1].siteId, "1/s1")
    T.ok("G11 membership is geometric", SGSiteBinding.contains(sites[1], 30, 40) and not SGSiteBinding.contains(sites[1], 30, 41))
    local notices = 0
    b.onChanged = function() notices = notices + 1 end
    subscribed[2]("s1", "4", "UPSERT", 1)
    T.eq("G12 provider notices reach the binding", notices, 1)
    b:unbind()
    T.ok("G13 unbind unsubscribes and drops the handle", subscribed == nil and not b.available)
end

-- (H) Views: selection, keys, paging and the codec
local registry = SGRegistry.new("1")
local ops = SGOperations.new(registry, "1")
local sites = SGSiteBinding.new()
local views = SGViews.new(registry, ops, sites)
local adapter = registry:registerCarrierAdapter("sg2", { version = 1, carrierKinds = { "silo" }, resolveCarrier = function() end, readNativeState = function() end, enumerateCarriers = function() return {} end,
    hasAccess = function(binding, actor) return actor.farmId == 1 end, getNavigationCarrierId = function(b) if b.carrierKey.nativeOwnerKey == "station" then return "nav:station", b.carrierKey.componentKey end return nil end })
registry:registerProperty("sf.moisture", { schemaVersion = 1, producerId = "soil", residency = "STORED", validate = function() return true end, combine = function() return nil end, transform = function() return nil end,
    disclosure = function(ctx, r) if ctx.purpose ~= "PLAYER_VIEW" then return nil end return { propertyId = r.propertyId, schemaVersion = 1, producerId = "soil", propertyRevision = r.propertyRevision, knowledge = r.knowledge, payload = { moisture = r.payload.moisture } } end })
local farmer = { farmId = 1, userId = "u1", actorState = "RESOLVED", connectionId = "c1" }
do
    T.eq("H1 FARM with a site id is a cross-kind refusal", select(2, SGViews.normalizeSelection("STOCK", { selectionKind = "FARM", siteId = "s1" })), "CROSS_KIND_PARAMETERS")
    T.eq("H2 RECIPE_LIBRARY needs LIBRARY", select(2, SGViews.normalizeSelection("RECIPE_LIBRARY", { selectionKind = "FARM" })), "LIBRARY_PARAMETERS")
    local farm = SGViews.normalizeSelection("STOCK", { selectionKind = "FARM" })
    T.eq("H3 cursor on the recipe route refuses", select(2, SGViews.normalizeReadOptions(SGViews.normalizeSelection("RECIPE_LIBRARY", { selectionKind = "LIBRARY", libraryId = "L1" }), { pageCursor = "c1" }, true)), "CURSOR_ROUTE")
    T.eq("H4 navigation with a cursor refuses", select(2, SGViews.normalizeReadOptions(farm, { pageCursor = "c1", navigationCarrierId = "n" }, true)), "NAVIGATION_WITH_CURSOR")
    T.eq("H5 rowKinds from an untrusted source refuses", select(2, SGViews.normalizeReadOptions(farm, { rowKinds = { "STOCK" } }, false)), "ROW_KINDS_NOT_TRUSTED")
    T.eq("H6 empty cursor string is malformed, never first page", select(2, SGViews.normalizeReadOptions(farm, { pageCursor = "" }, true)), "CURSOR_MALFORMED")
    local k1 = SGViews.selectionKey(farm, {})
    local k2 = SGViews.selectionKey(farm, { navigationCarrierId = "nav:station" })
    T.ok("H7 selectionKey changes with the navigation focus", k1 ~= k2 and k1:find("FARM", 1, true) ~= nil)
    T.eq("H8 waiting actor gives a WAITING page without rows", views:getManagementView({ actorState = "WAITING" }, { route = "STOCK", selectionKind = "FARM" }).state, "WAITING")
    T.eq("H9 spectator is DENIED", views:getManagementView({ farmId = 0, actorState = "SPECTATOR" }, { route = "STOCK", selectionKind = "FARM" }).state, "DENIED")
    T.eq("H10 before the barrier the view is WAITING", views:getManagementView(farmer, { route = "STOCK", selectionKind = "FARM" }).state, "WAITING")
    views.ready = true
    -- 70 carriers with stock on farm 1, plus one station carrier and one foreign farm carrier.
    for i = 1, 70 do
        ops:bindCarrier(adapter, binding("silo", string.format("%02d", i)), { materialRef = wheat, amount = 100 + i, unit = "l", label = "Silo " .. i, x = i, z = 0, ownerFarmId = 1 })
    end
    ops:bindCarrier(adapter, binding("station", "PRODUCT_A"), { amount = 0, unit = "l", label = "Bay A", x = 200, z = 200 })
    local first = ops.stocks[ops.carriers[SGRecords.carrierKeyString(binding("silo", "01").carrierKey)].stockId]
    first.properties["sf.moisture"] = { propertyId = "sf.moisture", schemaVersion = 1, producerId = "soil", propertyRevision = 1, knowledge = "KNOWN", payload = { moisture = 0.14, secret = "internal" } }
    local page = views:getManagementView(farmer, { route = "STOCK", selectionKind = "FARM" })
    T.eq("H11 first page is READY, within the row cap and byte budget, with a continuation", page.state .. "/" .. tostring(#page.view.rows <= 64 and #page.view.rows > 0) .. "/" .. tostring(#SGViews.encodeView(page.view) <= SGTransport.MAX_TOKENS) .. "/" .. tostring(page.view.nextPageCursor ~= nil), "READY/true/true/true")
    T.eq("H12 rows are in identity order and STOCK kind", page.view.rows[1].rowKind .. "/" .. page.view.rows[1].label, "STOCK/Silo 1")
    T.eq("H13 disclosed property omits producer internals", tostring(page.view.rows[1].properties[1].payload.secret) .. "/" .. page.view.rows[1].properties[1].payload.moisture, "nil/0.14")
    local total, pages, cursor, page2 = #page.view.rows, 1, page.view.nextPageCursor, nil
    while cursor ~= nil and pages < 10 do
        page2 = views:getManagementView(farmer, { route = "STOCK", selectionKind = "FARM" }, { pageCursor = cursor })
        total = total + #page2.view.rows
        pages = pages + 1
        cursor = page2.view.nextPageCursor
    end
    T.eq("H14 continuation returns every remaining row and ends exhausted (no next cursor)", page2.state .. "/" .. total .. "/" .. tostring(page2.view.nextPageCursor), "READY/70/nil")
    T.eq("H15 the empty station bay is not enumerated without context", (function() for _, r in ipairs(page2.view.rows) do if r.rowKind == "CARRIER" then return "carrier" end end return "none" end)(), "none")
    local other = { farmId = 2, userId = "u2", actorState = "RESOLVED", connectionId = "c2" }
    T.eq("H16 another farm sees an empty READY page, not another farm's rows", #views:getManagementView(other, { route = "STOCK", selectionKind = "FARM" }).view.rows, 0)
    T.eq("H17 a cursor from another actor is stale", views:getManagementView(other, { route = "STOCK", selectionKind = "FARM" }, { pageCursor = page.view.nextPageCursor }).state, "STALE")
    views:resetDomain()
    T.eq("H18 a domain reset invalidates cursors", views:getManagementView(farmer, { route = "STOCK", selectionKind = "FARM" }, { pageCursor = page.view.nextPageCursor }).state, "STALE")
    local focus = views:getManagementView(farmer, { route = "STOCK", selectionKind = "FARM" }, { navigationCarrierId = "nav:station" })
    T.eq("H19 navigation focus enumerates the empty station bay with its role", #focus.view.rows .. "/" .. focus.view.rows[1].rowKind .. "/" .. tostring(focus.view.rows[1].navigationRole), "1/CARRIER/PRODUCT_A")
    T.eq("H20 unknown focus is keyed unavailable, never farm rows", views:getManagementView(farmer, { route = "STOCK", selectionKind = "FARM" }, { navigationCarrierId = "nav:nowhere" }).reason, "NAVIGATION_UNKNOWN")
    local stockOnly = views:getManagementView(farmer, { route = "STOCK", selectionKind = "FARM" }, { rowKinds = { "STOCK" } }, true)
    T.eq("H21 trusted rowKinds STOCK gives stock rows only", (function() for _, r in ipairs(stockOnly.view.rows) do if r.rowKind ~= "STOCK" then return "mixed" end end return "stock" end)(), "stock")
    T.eq("H22 recipe route is unavailable until its owner joins", views:getManagementView(farmer, { route = "RECIPE_LIBRARY", selectionKind = "LIBRARY", libraryId = "@current" }).state, "UNAVAILABLE")
    -- Site selection through the binding.
    sites.available = true
    sites.handle = { getSite = function(siteId, ctx) if siteId == "yard" then return { siteId = "yard", ownerFarmId = 1, name = "Yard", centreX = 10, centreZ = 0, radiusMetres = 5.5, revision = "1", state = "ACTIVE" } end return nil, "NOT_FOUND" end }
    local site = views:getManagementView(farmer, { route = "STOCK", selectionKind = "SITE", siteId = "yard" })
    T.eq("H23 site selection groups the carriers inside the circle", site.state .. "/" .. #site.view.rows, "READY/11")
    T.eq("H24 an unavailable site refuses instead of showing the farm", views:getManagementView(farmer, { route = "STOCK", selectionKind = "SITE", siteId = "gone" }).state, "UNAVAILABLE")
    local ground = views:getManagementView(farmer, { route = "STOCK", selectionKind = "GROUND", groundFootprint = { x = 2, z = 0, radius = 1.5 } })
    T.eq("H25 ground footprint selects by position", #ground.view.rows, 3)
    -- Codec.
    local tokens = SGViews.encodeView(page.view)
    T.ok("H26 view encodes to string tokens", SGValues.isTokenArray(tokens))
    local back, why, terminal = SGViews.decodeView(tokens)
    T.eq("H27 view decodes with rows and keys intact", tostring(#back.rows == #page.view.rows) .. "/" .. tostring(back.selectionKey == page.view.selectionKey) .. "/" .. tostring(back.rows[1].stockRef.contentsGeneration), "true/true/1")
    local bad = SGValues.copy(page.view)
    bad.schemaVersion = 3
    local _, whyB, termB = SGViews.decodeView(SGViews.encodeView(bad))
    T.eq("H28 unsupported schema is terminal before any row parse", whyB .. "/" .. tostring(termB), "UNSUPPORTED_APPLICATION_VERSION/true")
    local nonReady = SGValues.copy(page.view)
    nonReady.availability = "DENIED"
    T.eq("H29 private rows on a non-READY view refuse", select(2, SGViews.decodeView(SGViews.encodeView(nonReady))), "PRIVATE_ROWS_ON_NON_READY")
    local caps = views:getCapabilities()
    T.eq("H30 capabilities advertise the schemas and paging", caps.applicationSchema .. "/" .. caps.materialSchema .. "/" .. caps.managementPagingVersion .. "/" .. tostring(caps.quoteSchema), "SG_APPLICATION_2/STOCK_MATERIAL_V2/1/nil")
end

-- (I) Command sessions and the admission path
local commands = SGCommands.new(registry, function() return clock end)
do
    local state = { enabled = false, revision = "1" }
    local invoked, executed, quoted = 0, 0, 0
    pendingState = { state = "PENDING" }
    pendingCompleted = 0
    registry:registerManagementOwner("native", { version = 1, targetKinds = { "PROCESS", "STOCK" },
        readPending = function(pendingId) if pendingState.state == "COMPLETE" then return { state = "COMPLETE", outcome = "APPLIED", detail = { resultingRevision = "9" } } end return { state = "PENDING" } end,
        onPendingComplete = function(pendingId, outcome) pendingCompleted = pendingCompleted + 1 end,
        enumerateTargets = function() return { state = "READY", targets = { { targetKind = "PROCESS", targetId = "p1" } }, exhausted = true } end,
        resolveTarget = function(id) if id == "p1" or id == "s1" then return { id = id } end return nil end,
        readTarget = function(b) return { rowKind = "PROCESS", processId = b.id, label = "Mill", enabled = state.enabled, processStateLabelKey = "sg_native_inactive" } end,
        hasAccess = function(b, actor) return actor.farmId == 1 end,
        getActions = function(b, actor)
            return {
                { actionId = "SET_PRODUCTION_ENABLED", targetKind = "PROCESS", targetId = "p1", expectedRevision = state.revision, argumentSchemaId = "SG_NATIVE_SET_PRODUCTION_ENABLED_1", controlKind = "ORDINARY", admission = "DIRECT_DESIRED_STATE", available = true },
                { actionId = "START_PREP", targetKind = "STOCK", targetId = "s1", expectedRevision = "5", expectedGeneration = "2", argumentSchemaId = "SG4_START_1", controlKind = "ORDINARY", admission = "QUOTED", available = true },
                { actionId = "PENDING_THING", targetKind = "PROCESS", targetId = "p1", expectedRevision = state.revision, argumentSchemaId = "X", controlKind = "ORDINARY", admission = "DIRECT_DESIRED_STATE", available = true },
            }
        end,
        invoke = function(b, actor, action, args)
            invoked = invoked + 1
            if action.actionId == "PENDING_THING" then return "ACCEPTED_PENDING", { pendingId = "pend1" } end
            if type(args.enabled) ~= "boolean" then return "REFUSED", { reasonCode = "ARGUMENTS" } end
            state.enabled = args.enabled
            state.revision = SGValues.incrementDecimal(state.revision)
            return "APPLIED", { resultingRevision = state.revision }
        end,
        quoteAction = function(b, actor, args) quoted = quoted + 1 return { offer = { schemaVersion = 1, actionId = "START_PREP", targetKind = "STOCK", targetId = "s1", targetLabel = "Bin", expectedRevision = "5", expectedGeneration = "2", inputs = {}, cost = { state = "KNOWN", amount = 120 }, duration = { state = "KNOWN", value = 2, unit = "GAME_HOUR" }, warnings = {} }, ownerQuoteRef = "q-ref", readSet = { n = 1 }, validitySeconds = 60 } end,
        validateQuote = function(b, actor, args, ref, readSet) return ref == "q-ref" end,
        executeAction = function(b, actor, args, ref, dispatch) executed = executed + 1 return "APPLIED", { resultingRevision = "6" } end,
    })
    local session = commands:issueSession(farmer, "STOCK")
    T.ok("I1 a resolved actor gets a session", session ~= nil and session.nextSequence == 1)
    T.eq("I2 same actor and route reuse the session", commands:issueSession(farmer, "STOCK").commandSessionId, session.commandSessionId)
    T.ok("I3 routes have independent sessions", commands:issueSession(farmer, "RECIPE_LIBRARY").commandSessionId ~= session.commandSessionId)
    T.eq("I4 a spectator gets no session", select(2, commands:issueSession({ farmId = 0, actorState = "SPECTATOR" }, "STOCK")), "ACTOR_DENIED")
    local function req(seq, phase, extra)
        local r = { protocolVersion = 2, route = "STOCK", commandSessionId = session.commandSessionId, sequence = tostring(seq), phase = phase, actionId = "SET_PRODUCTION_ENABLED", targetKind = "PROCESS", targetId = "p1", expectedRevision = state.revision, arguments = { enabled = true } }
        for k, v in pairs(extra or {}) do r[k] = v end
        return r
    end
    T.eq("I5 protocol 1 refuses", commands:handle(farmer, req(1, "DIRECT", { protocolVersion = 1 })).reasonCode, "UNSUPPORTED_PROTOCOL")
    T.eq("I6 a sequence ahead refuses", commands:handle(farmer, req(2, "DIRECT")).reasonCode, "SEQUENCE_AHEAD")
    local first = req(1, "DIRECT")
    local r1 = commands:handle(farmer, first)
    T.eq("I7 DIRECT desired state applies and advances", r1.outcome .. "/" .. r1.nextSequence .. "/" .. tostring(state.enabled), "APPLIED/2/true")
    T.eq("I8 a duplicate of the latest request returns the retained result without another invoke", commands:handle(farmer, first).outcome .. "/" .. invoked, "APPLIED/1")
    T.eq("I9 conflicting reuse of the sequence refuses", commands:handle(farmer, req(1, "DIRECT", { arguments = { enabled = false } })).reasonCode, "SEQUENCE_CONFLICT")
    T.eq("I10 a stale expected revision is STALE with the current target identity and revision, no owner row", (function() local r = commands:handle(farmer, req(2, "DIRECT", { expectedRevision = "1" })) return r.outcome .. "/" .. tostring(r.currentTarget and r.currentTarget.targetId) .. "/" .. tostring(r.currentTarget and r.currentTarget.currentRevision) .. "/" .. tostring(r.currentTarget and r.currentTarget.row) end)(), "STALE/p1/2/nil")
    T.eq("I11 a refused command still consumed its sequence", commands:credentialsFor(farmer, "STOCK").nextSequence, "3")
    T.eq("I12 another actor cannot use this session", commands:handle({ farmId = 2, userId = "u2", actorState = "RESOLVED", connectionId = "c2" }, req(3, "DIRECT")).reasonCode, "SESSION_INVALID")
    -- QUOTE / EXECUTE.
    local function qreq(seq, phase, extra)
        local r = { protocolVersion = 2, route = "STOCK", commandSessionId = session.commandSessionId, sequence = tostring(seq), phase = phase, actionId = "START_PREP", targetKind = "STOCK", targetId = "s1", expectedRevision = "5", expectedGeneration = "2", arguments = { recipe = "R1" } }
        for k, v in pairs(extra or {}) do r[k] = v end
        return r
    end
    T.eq("I13 DIRECT on a quoted action refuses", commands:handle(farmer, qreq(3, "DIRECT")).reasonCode, "QUOTE_REQUIRED")
    local noGen = qreq(4, "QUOTE")
    noGen.expectedGeneration = nil
    T.eq("I14 a STOCK target without expected generation refuses", commands:handle(farmer, noGen).reasonCode, "EXPECTED_GENERATION_REQUIRED")
    local q = commands:handle(farmer, qreq(5, "QUOTE"))
    T.eq("I15 QUOTE returns the offer and a token, validity capped at 30 s", q.outcome .. "/" .. q.offer.cost.amount .. "/" .. q.validityRemainingMs, "QUOTED/120/30000")
    T.eq("I16 EXECUTE with a wrong payload is STALE_QUOTE", commands:handle(farmer, qreq(6, "EXECUTE", { quoteToken = q.quoteToken, arguments = { recipe = "R2" } })).outcome, "STALE_QUOTE")
    local q2 = commands:handle(farmer, qreq(7, "QUOTE"))
    clock = clock + 31
    T.eq("I17 an expired quote is STALE_QUOTE and never executes", commands:handle(farmer, qreq(8, "EXECUTE", { quoteToken = q2.quoteToken })).reasonCode .. "/" .. executed, "QUOTE_EXPIRED/0")
    local q3 = commands:handle(farmer, qreq(9, "QUOTE"))
    clock = clock + 10
    local ex = commands:handle(farmer, qreq(10, "EXECUTE", { quoteToken = q3.quoteToken }))
    T.eq("I18 EXECUTE with the exact token applies once", ex.outcome .. "/" .. executed, "APPLIED/1")
    T.eq("I19 a consumed token cannot execute again", commands:handle(farmer, qreq(11, "EXECUTE", { quoteToken = q3.quoteToken })).outcome .. "/" .. executed, "STALE_QUOTE/1")
    -- Pending holds the sequence.
    local pend = commands:handle(farmer, req(12, "DIRECT", { actionId = "PENDING_THING", arguments = {} }))
    T.eq("I20 ACCEPTED_PENDING keeps the outstanding sequence", pend.outcome .. "/" .. pend.nextSequence .. "/" .. pend.actualPendingId, "ACCEPTED_PENDING/12/pend1")
    T.eq("I21 no new command while one is pending", commands:handle(farmer, req(13, "DIRECT")).reasonCode, "COMMAND_PENDING")
    -- Completion clears the outstanding command only through the owner's pending path.
    pendingState.state = "PENDING"
    T.eq("I21b polling while the owner still reports PENDING clears nothing", commands:pollPending() .. "/" .. tostring(session.outstanding ~= nil), "0/true")
    pendingState.state = "COMPLETE"
    T.eq("I21c owner completion clears the outstanding command and advances", commands:pollPending() .. "/" .. tostring(session.outstanding) .. "/" .. session.nextSequence, "1/nil/13")
    T.eq("I21d the completion result is the retained result for that sequence", commands:handle(farmer, req(12, "DIRECT", { actionId = "PENDING_THING", arguments = {} })).outcome, "APPLIED")
    T.eq("I21e the owner was told once", pendingCompleted, 1)
    T.eq("I21f a later command is admitted again", commands:handle(farmer, req(13, "DIRECT")).outcome, "APPLIED")
    -- Exhaustion.
    session.outstanding = nil
    session.nextSequence = SGCommands.SEQUENCE_LIMIT
    local last = commands:handle(farmer, req(SGCommands.SEQUENCE_LIMIT, "DIRECT"))
    T.ok("I22 reaching the end opens a fresh session instead of wrapping", last.outcome == "APPLIED" and last.commandSessionId ~= "cs1" and last.nextSequence == "1")
    commands:withdrawActor(farmer, "FARM_CHANGED")
    T.eq("I23 a withdrawn session rejects old commands", commands:handle(farmer, req(1, "DIRECT")).reasonCode, "SESSION_INVALID")
    T.eq("I24 an offer with an unavailable required cost cannot quote", select(2, SGCommands.validateOffer({ schemaVersion = 1, actionId = "a", targetKind = "STOCK", targetId = "s", targetLabel = "l", expectedRevision = "1", inputs = {}, cost = { state = "UNAVAILABLE" }, duration = { state = "NOT_APPLICABLE" }, warnings = {} })), "COST_UNAVAILABLE")
end

-- (J) Transport: NS-7 producer/consumer and the fallback events
do
    local transport = SGTransport.new(views, commands)
    local conn1 = { streamId = 1 }
    local ctx = function(state, cid) return { connection = conn1, connectionId = cid or "c1", userId = "u1", farmId = 1, actorState = state or "RESOLVED", serverSession = "1", subscriptionId = "1", modId = "stockGuard" } end
    T.eq("J1 waiting actor builds WAITING with no values", transport:buildView(ctx("WAITING"), nil, true).state, "WAITING")
    T.eq("J2 spectator builds DENIED", transport:buildView(ctx("SPECTATOR"), nil, true).state, "DENIED")
    local full = transport:buildView(ctx(), nil, true)
    T.eq("J3 resolved actor builds READY FULL with string tokens", full.state .. "/" .. full.mode .. "/" .. tostring(SGValues.isTokenArray(full.values)), "READY/FULL/true")
    local again = transport:buildView(ctx(), { viewKey = full.viewKey, dataRevision = full.dataRevision }, false)
    T.eq("J4 unchanged material answers UNCHANGED", again.mode, "UNCHANGED")
    ops:reconcileCarrier(SGRecords.carrierKeyString(binding("silo", "01").carrierKey), { materialRef = wheat, amount = 50, unit = "l" })
    local changed = transport:buildView(ctx(), { viewKey = full.viewKey, dataRevision = full.dataRevision }, false)
    T.eq("J5 a material change answers FULL with a new revision", changed.mode .. "/" .. tostring(changed.dataRevision ~= full.dataRevision), "FULL/true")
    T.ok("J6 selection change per connection object changes the view key", transport:setSelection(conn1, { route = "STOCK", selectionKind = "GROUND", groundFootprint = { x = 2, z = 0, radius = 1.5 } }) and transport:buildView(ctx(), nil, true).viewKey ~= full.viewKey)
    T.eq("J6b another connection object keeps its own default selection", transport:buildView({ connection = { streamId = 2 }, connectionId = "c2", userId = "u1", farmId = 1, actorState = "RESOLVED" }, nil, true).viewKey, full.viewKey)
    T.eq("J7 an invalid selection is refused and grants nothing", select(2, transport:setSelection(conn1, { route = "STOCK", selectionKind = "FARM", siteId = "x" })), "CROSS_KIND_PARAMETERS")
    -- Client side.
    local client = SGTransport.new(views, commands)
    client:expectSelection({ route = "STOCK", selectionKind = "FARM" })
    local mismatch = client:applyView({ mode = "FULL", values = transport:buildView(ctx(), nil, true).values, dataRevision = "x" })
    T.eq("J8 a publication for another selection is not applied", mismatch.outcome .. "/" .. mismatch.reason, "RETRYABLE/SELECTION_MISMATCH")
    transport:setSelection(conn1, { route = "STOCK", selectionKind = "FARM" })
    local pub = transport:buildView(ctx(), nil, true)
    local applied = client:applyView({ mode = "FULL", values = pub.values, dataRevision = pub.dataRevision })
    T.eq("J9 the matching publication applies with its revision", applied.outcome .. "/" .. tostring(applied.dataRevision == pub.dataRevision) .. "/" .. tostring(client.client.usable), "APPLIED/true/true")
    T.ok("J10 credentials travel on the READY private view", client.client.credentials ~= nil and client.client.credentials.nextSequence ~= nil)
    local badTokens = SGValues.copy(pub.values)
    for i = 1, #badTokens do if badTokens[i] == "SG_APPLICATION_2" then badTokens[i] = "SG_APPLICATION_9" end end
    local term = client:applyView({ mode = "FULL", values = badTokens, dataRevision = "r" })
    T.eq("J11 unsupported application is TERMINAL and clears the replica", term.outcome .. "/" .. term.reason .. "/" .. tostring(client.client.usable), "TERMINAL/UNSUPPORTED_APPLICATION_VERSION/false")
    client:clearView("FARM_CHANGED")
    T.eq("J12 clearView revokes usability with the reason", tostring(client.client.usable) .. "/" .. client.client.reason, "false/FARM_CHANGED")
    -- Route selection.
    local registered = nil
    local ns = { getScopedCapabilities = function(self) return { bootstrapVersion = 1, protocolVersions = { 1 }, ready = true, reasonCode = "READY" } end,
        registerScopedModule = function(self, id, spec) registered = { id = id, spec = spec } return true end, unregisterScopedModule = function(self, id) registered = nil return true end, markDirty = function() end }
    local t2 = SGTransport.new(views, commands)
    T.eq("J13 a ready NS-7 is selected and the module registered", t2:selectRoute({ networkSync = ns }) .. "/" .. registered.id, "NS7/stockGuard")
    T.eq("J14 the registered buildView is a plain function of (context, previous, forceFull)", registered.spec.buildView(ctx(), nil, true).state, "READY")
    local t3 = SGTransport.new(views, commands)
    T.eq("J15 a waiting NS-7 keeps waiting, never a unilateral fallback", tostring(t3:selectRoute({ networkSync = { getScopedCapabilities = function() return { bootstrapVersion = 1, protocolVersions = { 1 }, ready = false, waiting = true, reasonCode = "WAITING_MISSION_LOAD" } end, registerScopedModule = function() end } })), "nil")
    local t4 = SGTransport.new(views, commands)
    T.eq("J16 absent NS-7 selects the dedicated fallback", t4:selectRoute({}), "FALLBACK")
    local t5 = SGTransport.new(views, commands)
    T.eq("J16b a present NS-7 that refuses the registration is UNAVAILABLE, never fallback", t5:selectRoute({ networkSync = { getScopedCapabilities = function() return { bootstrapVersion = 1, protocolVersions = { 1 }, ready = true } end, registerScopedModule = function() return false, "MODULE_LIMIT" end } }) .. "/" .. t5.routeReason, "UNAVAILABLE/NS7_REGISTRATION_REFUSED:MODULE_LIMIT")
    t2:teardown()
    T.eq("J17 teardown unregisters the scoped module", tostring(registered), "nil")
    -- Events.
    local ev = SGViewRequestEvent.new({ route = "STOCK", selectionKind = "SITE", siteId = "yard" }, { pageCursor = "c1.2" })
    local s = NewStream()
    ev:writeStream(s, nil)
    local got = nil
    local orig = SGViewRequestEvent.run
    SGViewRequestEvent.run = function(self) got = self end
    SGViewRequestEvent.emptyNew():readStream(s, nil)
    SGViewRequestEvent.run = orig
    T.eq("J18 view request roundtrips selection and paging tail", got.selection.selectionKind .. "/" .. got.selection.siteId .. "/" .. got.readOptions.pageCursor .. "/" .. got.pagingVersion, "SITE/yard/c1.2/1")
    local st = SGViewStateEvent.new("1", "2", "3", "READY", "", pub.values)
    local s2 = NewStream()
    st:writeStream(s2, nil)
    local gotState = nil
    local origS = SGViewStateEvent.run
    SGViewStateEvent.run = function(self) gotState = self end
    SGViewStateEvent.emptyNew():readStream(s2, nil)
    SGViewStateEvent.run = origS
    T.eq("J19 view state roundtrips the token array exactly", #gotState.tokens .. "/" .. tostring(gotState.tokens[#gotState.tokens] == pub.values[#pub.values]), #pub.values .. "/true")
    local cev = SGCommandRequestEvent.new({ protocolVersion = 2, route = "STOCK", sequence = "1" })
    local s3 = NewStream()
    cev:writeStream(s3, nil)
    local gotCmd = nil
    local origC = SGCommandRequestEvent.run
    SGCommandRequestEvent.run = function(self) gotCmd = SGValues.decode(self.tokens) end
    SGCommandRequestEvent.emptyNew():readStream(s3, nil)
    SGCommandRequestEvent.run = origC
    T.eq("J20 command request roundtrips through the codec", gotCmd.route .. "/" .. gotCmd.sequence, "STOCK/1")
    -- Oversize token counts are refused without allocation.
    local s4 = NewStream()
    streamWriteInt32(s4, SGTransport.MAX_TOKENS + 1)
    T.eq("J21 an oversize token count is refused before any string is read", select(2, SGTransport.readTokens(s4)), "OVERSIZE")
    T.eq("J22 a decoded string above the byte bound refuses", select(2, SGValues.decode({ "SG_VALUES", "2", "S", string.rep("x", SGValues.MAX_STRING_BYTES + 1) })), "STRING_TOO_LONG")
end

-- (K) The mission handle and the SG-6 finished-loading chain
do
    local superCalls, sg6Suppress = 0, false
    local Mission = {}
    Mission.__index = Mission
    function Mission:getIsServer() return self._server end
    function Mission:getFarmId(connection) if connection == nil then return self._localFarm end return self._farms[connection] end
    -- SG-6's class wrapper: conditional overwrite that suppresses the parent call on failure.
    local parent = function(m) superCalls = superCalls + 1 return "parent" end
    Mission.onFinishedLoading = function(m, ...)
        if sg6Suppress then return end
        return parent(m, ...)
    end
    local mission = setmetatable({ _server = true, _localFarm = 1, _farms = {}, playerUserId = "host", missionDynamicInfo = { isMultiplayer = false }, missionInfo = {}, userManager = { getUserByConnection = function(_, c) return c.user end } }, Mission)
    local sg = StockGuard.attach(mission)
    T.ok("K1 a separate handle is published on the mission; the host is not reachable through it", mission.stockGuard ~= sg and StockGuard.hostOf(mission) == sg and type(mission.stockGuard.registerCarrierAdapter) == "function" and mission.stockGuard.operations == nil and mission.stockGuard.registry == nil)
    T.eq("K2 attach is idempotent", StockGuard.attach(mission), sg)
    local h = mission.stockGuard
    -- SG2-1 join: enumeration names a binding and the core reads the carrier
    -- through resolveCarrier and readNativeState; the entry carries no state.
    local lease = h.registerCarrierAdapter("sg2", { version = 1, carrierKinds = { "silo" }, resolveCarrier = function() return { bin = true } end, readNativeState = function() return { materialRef = wheat, amount = 10, unit = "l" } end,
        enumerateCarriers = function() return { { binding = binding("bin", "1") } } end, hasAccess = function() return true end })
    T.ok("K3 dot-bound registration works without self", lease ~= nil and lease.ownerId == "sg2")
    T.eq("K4 a colon call is refused by the first bound parameter", select(2, h:registerCarrierAdapter("sg2", {})), "INVALID_ID")
    sg:installFinishedLoadingObserver()
    T.ok("K5 observer installed on the instance, class chain untouched", rawget(mission, "onFinishedLoading") ~= nil and Mission.onFinishedLoading ~= mission.onFinishedLoading)
    sg6Suppress = true
    StockGuardCapacity = { isReady = function() return false end }
    mission:onFinishedLoading()
    T.eq("K6 SG-6 suppression: parent not called, barrier not marked", superCalls .. "/" .. tostring(sg.finishedLoadingObserved) .. "/" .. tostring(sg.views.ready), "0/false/false")
    sg6Suppress = false
    StockGuardCapacity = { isReady = function() return true end }
    T.eq("K7 original body runs first and its return is preserved", mission:onFinishedLoading(), "parent")
    T.eq("K8 after the original body the barrier is observed once: carriers enumerated, views READY, capacity published", superCalls .. "/" .. tostring(sg.views.ready) .. "/" .. tostring(sg.capacity ~= nil) .. "/" .. h.getStatus().carriers, "1/true/true/1")
    mission:onFinishedLoading()
    T.eq("K9 a repeat finished-loading does not re-enumerate", superCalls .. "/" .. h.getStatus().carriers, "2/1")
    T.eq("K10 farm phase resolved UNCHANGED without a merge in singleplayer", sg.coordinator.phase, "UNCHANGED")
    -- Actor resolution.
    local conn = { user = MakeUser("u7", false), streamId = 7 }
    mission._farms[conn] = 3
    local a = h.resolveActor(conn)
    T.eq("K11 remote actor resolved from the connection", a.actorState .. "/" .. a.farmId .. "/" .. a.userId, "RESOLVED/3/u7")
    mission._farms[conn] = 0
    T.eq("K12 spectator farm is SPECTATOR", h.resolveActor(conn).actorState, "SPECTATOR")
    T.eq("K13 unknown user is WAITING", h.resolveActor({ streamId = 8 }).actorState, "WAITING")
    T.eq("K14 local host resolves its own farm", h.resolveActor(nil).actorState .. "/" .. h.resolveActor(nil).farmId, "RESOLVED/1")
    g_dedicatedServer = {}
    T.eq("K15 a dedicated server has no implicit local farmer", h.resolveActor(nil).actorState, "INVALID")
    g_dedicatedServer = nil
    -- Fallback publication to a connection.
    local sent = {}
    local remote = { user = MakeUser("u9", false), streamId = 9, isReadyForEvents = true, sendEvent = function(self, e) sent[#sent + 1] = e end }
    mission._farms[remote] = 1
    sg.transport.route = "FALLBACK"
    sg:onViewRequest(remote, { route = "STOCK", selectionKind = "FARM" }, {})
    T.eq("K16 a view request answers this connection only with a READY state event", #sent .. "/" .. sent[1].state .. "/" .. tostring(#sent[1].tokens > 0), "1/READY/true")
    sg:onViewRequest(remote, { route = "STOCK", selectionKind = "FARM", siteId = "x" }, {})
    T.eq("K17 an invalid request answers UNAVAILABLE with no private bytes", sent[2].state .. "/" .. #sent[2].tokens, "UNAVAILABLE/0")
    -- Teardown restores only what is still ours.
    local ours = mission.onFinishedLoading
    mission.onFinishedLoading = function(m, ...) return ours(m, ...) end
    local foreign = mission.onFinishedLoading
    sg:delete()
    T.eq("K18 delete leaves a foreign instance wrapper in place and drops the handle", tostring(mission.onFinishedLoading == foreign) .. "/" .. tostring(mission.stockGuard), "true/nil")
    T.ok("K19 leases are dead after delete", not sg.registry:isLive(lease))
    SGFarmRestore.removeHooks()
end

-- (L) The host end to end: the wired farm-restore path, NS-7 request
-- handling, publication ordering, per-player farm changes, connection
-- close, event direction, client gates, pending polling from update (#2 review).
do
    local Mission = {}
    Mission.__index = Mission
    function Mission:getIsServer() return self._server end
    function Mission:getFarmId(connection) if connection == nil then return self._localFarm end return self._farms[connection] end
    Mission.onFinishedLoading = function(m) return "parent" end
    local unsubscribed = 0
    g_messageCenter = { subscribe = function() end, unsubscribeAll = function(_, target) unsubscribed = unsubscribed + 1 end }
    MessageType = { PLAYER_FARM_CHANGED = 1, FARM_DELETED = 2 }
    StockGuardCapacity = { isReady = function() return true end }
    local mission = setmetatable({ _server = true, _localFarm = 1, _farms = {}, playerUserId = "host", missionDynamicInfo = { isMultiplayer = false }, missionInfo = { savegameDirectory = "sg" }, userManager = { getUserByConnection = function(_, c) return c.user end } }, Mission)
    local sg = StockGuard.attach(mission)
    local h = mission.stockGuard
    -- A merged conversion observed by the coordinator; sections through the handle.
    local stagedPhase, committedIds = nil, {}
    h.registerSaveSection("own", { schemaVersion = 1, farmRestorePolicy = "OWNER", serialize = function() return { n = 1 } end,
        stageLoad = function(payload, context) stagedPhase = context.farmRestore and context.farmRestore.phase return { ok = true } end,
        commitLoad = function() committedIds[#committedIds + 1] = "own" end, clearReadiness = function() end })
    h.registerSaveSection("plain", { schemaVersion = 1, serialize = function() return { n = 2 } end, stageLoad = function() return { ok = true } end, commitLoad = function() committedIds[#committedIds + 1] = "plain" end, clearReadiness = function() end })
    local adapterLease = h.registerCarrierAdapter("sg2", { version = 1, carrierKinds = { "silo" }, resolveCarrier = function() return { bin = true } end, readNativeState = function() return { materialRef = wheat, amount = 10, unit = "l" } end,
        enumerateCarriers = function() return { { binding = binding("bin", "1") } } end, hasAccess = function() return true end })
    sg.save.backendId = SGSave.BACKEND_XML
    local env = sg.save:buildEnvelope({})
    sg:installFinishedLoadingObserver()
    sg:onLoadMission00Finished()
    sg.coordinator:observeBeforeMerge({ farms = { { farmId = 1 }, { farmId = 2 } } })
    sg.coordinator:observeAfterMerge({ farms = {}, mergedFarms = { [2] = 1 }, farmIdToFarm = { [1] = {} } })
    sg.coordinator:retainPayload(SGValues.decode(SGValues.encode(env)), "xml")
    mission:onFinishedLoading()
    T.eq("L1 through the host the OWNER section is staged with context.farmRestore MERGED", tostring(stagedPhase), "MERGED")
    T.eq("L1b the undeclared section is retained under the conversion, the OWNER section installed", tostring(sg.save.sectionState.plain.reason) .. "/" .. tostring(sg.save.sectionState.own.ready), "FARM_RESTORE_UNSUPPORTED/true")
    T.eq("L1c the next envelope carries the receipt and the pending unit for the retained section", (function() local e = sg.save:buildEnvelope({}) return tostring(e.farmRestore ~= nil and e.farmRestore.pendingUnits["section:plain"] ~= nil) end)(), "true")
    T.eq("L1d the status reports the load state", h.getStatus().loadState .. "/" .. h.getStatus().farmPhase, "READY/MERGED")
    -- NS-7 route: a view request sets the selection and marks dirty; no state event is sent.
    local dirtyMarks, sent = 0, {}
    sg.transport.route = "NS7"
    sg.transport.networkSync = { markDirty = function() dirtyMarks = dirtyMarks + 1 end }
    local remote = { user = MakeUser("u9", false), streamId = 9, isReadyForEvents = true, sendEvent = function(self, e) sent[#sent + 1] = e end }
    mission._farms[remote] = 1
    sg:onViewRequest(remote, { route = "STOCK", selectionKind = "GROUND", groundFootprint = { x = 0, z = 0, radius = 5 } }, {})
    T.eq("L2 on NS7 a view request only sets the selection and marks dirty, never a state event", #sent .. "/" .. tostring(dirtyMarks > 0) .. "/" .. sg.transport:selectionFor(remote).normalized.selectionKind, "0/true/GROUND")
    T.eq("L2b the selection is keyed by the connection object NS-7 hands to the producer", sg.transport:buildView({ connection = remote, connectionId = "c77", userId = "u9", farmId = 1, actorState = "RESOLVED" }, nil, true).state, "READY")
    -- [B16] ONE CONNECTION IDENTITY FOR BOTH ROUTES.
    -- NS-7 builds its producer context with its OWN scoped connection id, "c" plus a
    -- serial (NetworkSyncScoped:_scopedConnectionId). The command session must not be
    -- minted under that: every command event rebuilds the actor from the connection
    -- object, which yields the streamId string, so a session keyed on the scoped serial
    -- refuses every command that player sends for the whole mission and the disconnect
    -- withdraw never reaches it. FALLBACK was unaffected because it used the streamId
    -- string on both sides, which is why only the NS7 route carried this.
    local ns7Ctx = { connection = remote, connectionId = "c77", userId = "u9", farmId = 1, actorState = "RESOLVED", serverSession = "1", subscriptionId = "1", modId = "stockGuard" }
    local ns7Res = sg.transport:buildView(ns7Ctx, nil, true)
    local ns7View = SGViews.decodeView(ns7Res.values)
    T.ok("L2c the NS-7 view advertises command credentials", ns7View ~= nil and type(ns7View.commandSessionId) == "string")
    local minted = ns7View ~= nil and sg.commands.sessions[ns7View.commandSessionId] or nil
    T.eq("L2d the session is keyed on the resolved connection identity", tostring(minted and minted.connectionId), SGTransport.connectionIdOf(remote))
    T.ok("L2e DIFFERENCE: NS-7's scoped serial never reaches the session key", minted ~= nil and minted.actorKey:find("c77", 1, true) == nil)
    T.eq("L2f DIFFERENCE: a session minted under the scoped serial would not match the real actor",
        tostring(("c77|u9|1|STOCK") == (minted and minted.actorKey)), "false")
    -- End to end through the real host entry, with the actor resolved from the
    -- connection the way a live command does it, not hand built.
    local prevResultEvent = SGCommandResultEvent
    SGCommandResultEvent = { new = function(res) return { result = res } end }
    local ns7Req = { protocolVersion = 2, route = "STOCK", commandSessionId = ns7View and ns7View.commandSessionId, sequence = tostring(ns7View and ns7View.nextSequence or 1), phase = "DIRECT", actionId = "SET_PRODUCTION_ENABLED", targetKind = "PROCESS", targetId = "p1", expectedRevision = "1", arguments = { enabled = true } }
    sg:onCommandRequest(remote, ns7Req)
    local delivered = sent[#sent] ~= nil and sent[#sent].result or nil
    T.ok("L2g onCommandRequest on the NS7 route is answered at all", delivered ~= nil)
    T.ok("L2h and it is NOT refused for the session, which is the whole blocker", delivered ~= nil and delivered.reasonCode ~= "SESSION_INVALID")
    SGCommandResultEvent = prevResultEvent
    -- The disconnect withdraw reaches an NS7-minted session. A separate connection, so
    -- the fallback assertions below still have their own live one.
    local remote2 = { user = MakeUser("u8", false), streamId = 8, isReadyForEvents = true, sendEvent = function() end }
    mission._farms[remote2] = 1
    local view2 = SGViews.decodeView(sg.transport:buildView({ connection = remote2, connectionId = "c78", userId = "u8", farmId = 1, actorState = "RESOLVED" }, nil, true).values)
    T.ok("L2i a second connection gets its own session", view2 ~= nil and view2.commandSessionId ~= (ns7View and ns7View.commandSessionId))
    sg:onConnectionClosed(remote2)
    T.eq("L2j closing the connection withdraws the NS7-keyed session instead of leaking it", tostring(sg.commands.sessions[view2 and view2.commandSessionId]), "nil")
    T.ok("L2k and the other connection's session is untouched", sg.commands.sessions[ns7View and ns7View.commandSessionId] ~= nil)
    -- Fallback publication ordering on the client side.
    local client = StockGuard.attach(setmetatable({ _server = false, _localFarm = 1, _farms = {}, missionDynamicInfo = { isMultiplayer = true }, missionInfo = {} }, Mission))
    local ch = client.mission.stockGuard
    T.eq("L3 material mutators refuse on a client", select(2, ch.bindCarrier(nil, nil, nil)) .. "/" .. select(2, ch.settleOperation(nil, nil)) .. "/" .. select(2, ch.getManagementView(nil, nil)), "NOT_SERVER/NOT_SERVER/NOT_SERVER")
    client.transport.route = "FALLBACK"
    client.transport:expectSelection({ route = "STOCK", selectionKind = "FARM" })
    sg.transport.route = "FALLBACK"
    sg:onViewRequest(remote, { route = "STOCK", selectionKind = "FARM" }, {})
    local pub1 = sent[#sent]
    sg.transport:markDirty()
    sg:publishAllFallback()
    local pub2 = sent[#sent]
    T.ok("L3b two ordered publications were sent", pub1 ~= nil and pub2 ~= nil and pub1 ~= pub2 and SGValues.compareDecimal(pub2.publicationId, pub1.publicationId) > 0)
    client:onViewState(pub2)
    local rev2 = client.transport.client.replica and client.transport.client.replica.dataRevision
    client:onViewState(pub1)
    T.eq("L3c an older publication of the same session and epoch is ignored", tostring(client.transport.client.replica.dataRevision == rev2), "true")
    local otherSession = SGViewStateEvent.new("s-other", "1", "1", "READY", "", pub1.tokens)
    client:onViewState(otherSession)
    T.eq("L3d a different server session resets the ordering baseline and applies", tostring(client.transport.client.usable) .. "/" .. client.clientOrder.serverSession, "true/s-other")
    -- Per-player farm change and connection close.
    local farmerA = h.resolveActor(remote)
    local sessionA = sg.commands:issueSession(farmerA, "STOCK")
    local remoteB = { user = MakeUser("u10", false), streamId = 10, isReadyForEvents = true, sendEvent = function() end }
    mission._farms[remoteB] = 1
    local sessionB = sg.commands:issueSession(h.resolveActor(remoteB), "STOCK")
    sg:onPlayerFarmChanged({ getUserId = function() return "u9" end })
    T.eq("L4 a player's farm change withdraws only that player's sessions", tostring(sg.commands.sessions[sessionA.commandSessionId]) .. "/" .. tostring(sg.commands.sessions[sessionB.commandSessionId] ~= nil), "nil/true")
    sg:onConnectionClosed(remoteB)
    T.eq("L5 a closed connection withdraws its command sessions and selection", tostring(sg.commands.sessions[sessionB.commandSessionId]) .. "/" .. tostring(rawget(sg.transport.selections, remoteB)), "nil/nil")
    -- Event direction: a result event is accepted only from the server.
    local resultsSeen = 0
    client.onCommandResultCallback = function() resultsSeen = resultsSeen + 1 end
    g_currentMission = client.mission
    local ev = SGCommandResultEvent.new({ outcome = "APPLIED" })
    local s = NewStream()
    ev:writeStream(s, nil)
    local fromClient = SGCommandResultEvent.emptyNew()
    fromClient.tokens = SGTransport.readTokens(s)
    fromClient:run({ getIsServer = function() return false end })
    T.eq("L6 a command result from a non-server connection is ignored", resultsSeen, 0)
    fromClient:run({ getIsServer = function() return true end })
    T.eq("L6b a command result from the server is applied", resultsSeen, 1)
    g_currentMission = mission
    -- Pending completion is polled from the host tick.
    local pendingDone = false
    h.registerManagementOwner("mill", { version = 1, targetKinds = { "PROCESS" },
        enumerateTargets = function() return { state = "READY", targets = {}, exhausted = true } end,
        resolveTarget = function(id) return { id = id } end, readTarget = function(b) return { rowKind = "PROCESS", processId = b.id, label = "Mill", processStateLabelKey = "k" } end,
        hasAccess = function() return true end,
        getActions = function() return { { actionId = "START", targetKind = "PROCESS", targetId = "p1", expectedRevision = "1", argumentSchemaId = "S", controlKind = "ORDINARY", admission = "DIRECT_DESIRED_STATE", available = true } } end,
        invoke = function() return "ACCEPTED_PENDING", { pendingId = "pend9" } end,
        readPending = function() if pendingDone then return { state = "COMPLETE", outcome = "APPLIED", detail = {} } end return { state = "PENDING" } end })
    local actorA = h.resolveActor(remote)
    local sess = sg.commands:issueSession(actorA, "STOCK")
    local res = sg.commands:handle(actorA, { protocolVersion = 2, route = "STOCK", commandSessionId = sess.commandSessionId, sequence = "1", phase = "DIRECT", actionId = "START", targetKind = "PROCESS", targetId = "p1", expectedRevision = "1", arguments = {} })
    T.eq("L7 the owner's pending command is outstanding", res.outcome .. "/" .. tostring(sess.outstanding ~= nil), "ACCEPTED_PENDING/true")
    sg:update(16)
    T.eq("L7b the host tick leaves it outstanding while the owner reports PENDING", tostring(sess.outstanding ~= nil), "true")
    pendingDone = true
    sg:update(16)
    T.eq("L7c the host tick clears it once the owner reports completion", tostring(sess.outstanding) .. "/" .. sess.nextSequence, "nil/2")
    -- Route retry from update and teardown.
    local retries = SGTransport.new(sg.views, sg.commands)
    sg.transport = retries
    sg.transport.stockGuard = sg
    sg.mission.networkSync = { getScopedCapabilities = function() return { bootstrapVersion = 1, protocolVersions = { 1 }, ready = false, reasonCode = "WAITING_MISSION_LOAD" } end, registerScopedModule = function() return true end }
    sg.routeLogged = false
    sg:tryRoute()
    T.eq("L8 a waiting NS-7 leaves the route unresolved with its reason", tostring(sg.transport.route) .. "/" .. sg.transport.routeReason, "nil/WAITING_MISSION_LOAD")
    sg.mission.networkSync.getScopedCapabilities = function() return { bootstrapVersion = 1, protocolVersions = { 1 }, ready = true } end
    for _ = 1, StockGuard.RETRY_TICKS do sg:update(16) end
    T.eq("L8b the update tick retries until the route resolves", tostring(sg.transport.route), "NS7")
    sg:delete()
    T.eq("L9 delete removes the message subscriptions and the handle", unsubscribed .. "/" .. tostring(mission.stockGuard) .. "/" .. tostring(StockGuard.hostOf(mission)), "1/nil/nil")
    client:delete()
    g_messageCenter, MessageType = nil, nil
    SGFarmRestore.removeHooks()
end
