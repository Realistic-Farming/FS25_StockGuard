-- SG4-2a-recipe_library_spec_test.lua
--
-- SG-4 Part 2a, the recipe library and its plumbing (SG-4 v2.4 build brief :62-72, :112-120,
-- :345-385, :407-417; Bob's SG-4 intake Part 2 and his R-15 of 2026-10-08; Tyson's split: the native
-- mixer GUIDANCE profile is 2b, after Design answers on its labels). The store (the "sg4" save section),
-- the preparation profile registry, the LIBRARY management owner (SAVE_RECIPE and RETIRE_RECIPE, QUOTED),
-- the RECIPE_LIBRARY view's rows through Part 1's owner hook, the server-local reads, and the farm
-- lifecycle.
--
-- THE ENTRY-POINT BAR IS GROUP J. A listen host booted through main.lua's own load path (SG-187's world,
-- with the savegame model, and the ground model's completed bit32 for the view's digest): SG-4 installs from main.lua's native kernel install. The profile is a
-- stand-in of a GUIDANCE profile's registration contract, registered on the handle as a mod's own
-- initialization would; production's first profile is 2b's native mixer profile. The host's player opens
-- the library through the real view request (@current, first use), and a SAVE_RECIPE QUOTE then EXECUTE go
-- through SG-1's own admission with the actor the server builds; the library then survives the savegame
-- controller's save and a fresh mission on the same directory. Nothing writes a library, a recipe, a
-- selection or a session.
--
-- Groups:
--   J  the entry-point bar
--   K  no profile: SAVE_RECIPE unavailable, a QUOTE answers UNAVAILABLE
--   R  a stale revision, an edit, a stale edit, a duplicate EXECUTE (the owner runs once), RETIRE
--   V  validation against the profile, then the profile's own refusal
--   L  a profile missing at reload (LOCKED, visible), a late registration (unlocked), a refusing profile,
--      a corrupt payload (UNAVAILABLE, the original kept), an initialized section without its payload
--   F  FARM_DELETED, a reused farm id, a singleplayer merge
--   X  privacy: another farm, an administrator, a remote player's command
--   N  a client decodes the library with the same row check
--
--!env: modenv
--!load: tools/test/lua/SG2-2-engine_model.lua, tools/test/lua/SG2-3-engine_model.lua, tools/test/lua/SG2-4a-savegame_model.lua, tools/test/lua/SG2-4b-ground_model.lua, src/core/SGClassHook.lua, src/capacity/SGSha256.lua, src/capacity/SGCanonicalProfile.lua, src/capacity/SGWireFormats.lua, src/capacity/SGCapacity.lua, src/core/SGValues.lua, src/core/SGRecords.lua, src/core/SGRegistry.lua, src/core/SGOperations.lua, src/core/SGFarmRestore.lua, src/core/SGSave.lua, src/core/SGSiteBinding.lua, src/core/SGViews.lua, src/core/SGCommands.lua, src/core/SGTransport.lua, src/StockGuard.lua, src/native/SGOperationContext.lua, src/native/SGWorkAreaInstaller.lua, src/native/SGStorageBracket.lua, src/native/SGFillUnitObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGStationAdapter.lua, src/native/SGDischargeCapture.lua, src/native/SGNativeSale.lua, src/native/SGCutState.lua, src/native/SGHarvestCapture.lua, src/native/SGCombineBufferSave.lua, src/native/SGNativeMaterialSave.lua, src/native/SGGround.lua, src/native/SGNativeHost.lua, src/placeables/ChemicalStationRoles.lua, src/placeables/ChemicalStationAddress.lua, src/placeables/ChemicalStationWipRoute.lua, src/placeables/ChemicalStationSaleGate.lua, src/sg4/SG4Schema.lua, src/sg4/SG4Profiles.lua, src/sg4/SG4Library.lua, src/sg4/SG4Owner.lua, src/sg4/SG4.lua, main.lua

local REAL = getmetatable(_G).__index
local function engine(name, value) REAL[name] = value end
local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end
local function printed(fn)
    local lines, orig = {}, print
    REAL.print = function(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end lines[#lines + 1] = table.concat(t, " ") end
    local ok, err = pcall(fn)
    REAL.print = orig
    if not ok then error(err, 0) end
    return lines
end
local function count(lines, pattern) local n = 0 for _, l in ipairs(lines or {}) do if l:find(pattern, 1, true) then n = n + 1 end end return n end

-- ── the message center, as the decompile has it (MessageCenter.lua:27-110): subscribe(type, callback,
-- target); publish calls callback(target, ...); publishDelayed delivers later; unsubscribeAll(target).
local MC = { subscribers = {}, delayed = {} }
function MC:subscribe(t, cb, target) self.subscribers[t] = self.subscribers[t] or {} table.insert(self.subscribers[t], { cb = cb, target = target }) end
function MC:unsubscribeAll(target)
    for _, list in pairs(self.subscribers) do for i = #list, 1, -1 do if list[i].target == target then table.remove(list, i) end end end
end
function MC:publish(t, ...)
    local list = self.subscribers[t] or {}
    for i = 1, #list do local s = list[i] if s.target ~= nil then s.cb(s.target, ...) else s.cb(...) end end
end
function MC:publishDelayed(t, ...) self.delayed[#self.delayed + 1] = { t = t, args = { ... } } end
function MC:deliver() local d = self.delayed self.delayed = {} for _, e in ipairs(d) do self:publish(e.t, table.unpack(e.args)) end end
engine("g_messageCenter", MC)
REAL.MessageType = REAL.MessageType or {}
REAL.MessageType.FARM_DELETED = REAL.MessageType.FARM_DELETED or "FARM_DELETED"
REAL.MessageType.FARM_CREATED = REAL.MessageType.FARM_CREATED or "FARM_CREATED"

-- ── the world: a server (a listen host whose own player farms farm 1) ─────────
local Mission = {}
Mission.__index = Mission
function Mission:getIsServer() return self._server end
function Mission:getFarmId(connection) if connection == nil then return self._localFarm end return self._farms[connection] end
Mission.onFinishedLoading = function(m) return "parent" end

local function newMission(saveDir, index, server)
    local m = setmetatable({ _server = server ~= false, _localFarm = 1, _farms = {}, _users = {}, playerUserId = "host", missionDynamicInfo = { isMultiplayer = true },
        time = 1000, terrainSize = 256, terrainDetailHeightId = ENGINE_HEIGHT_ID, fieldGroundSystem = ENGINE_FIELD_GROUND, _placeables = {}, _vehicles = {} }, Mission)
    m.userManager = { getUserByConnection = function(_, c) return m._users[c] end }
    m.missionInfo = FSCareerMissionInfo.new({ savegameDirectory = saveDir, mapId = "MapUS", savegameIndex = index, savegameName = "bench" })
    m.accessHandler = { canFarmAccess = function() return true end }
    m.placeableSystem = { placeables = m._placeables, getPlaceableByUniqueId = function() return nil end }
    m.vehicleSystem = { vehicles = m._vehicles, getVehicleByUniqueId = function() return nil end }
    m.storageSystem = StorageSystem.newModel()
    return m
end

-- ── the stand-in preparation profile: a GUIDANCE profile of three roles, registered on the handle as a
-- mod's own initialization would, after StockGuard's member install and before the restore barrier ────
local PROFILE_ID = "BENCH_MIXER"
local STAND = { version = 1, validates = 0, reject = false }
local function editor()
    return { definitionSchemaVersion = 1, allowedIntents = { "GUIDANCE_TARGET" }, basis = { kind = "PROPORTION", unit = "FRACTION", total = 1 },
        roles = {
            { roleId = "grass", labelKey = "bench_grass", required = true, ingredients = { { ingredientId = "grass", labelKey = "bench_grass", unit = "FRACTION", min = 0.2, max = 0.8 } } },
            { roleId = "straw", labelKey = "bench_straw", required = false, ingredients = { { ingredientId = "straw", labelKey = "bench_straw", unit = "FRACTION", min = 0, max = 0.5 } } },
            { roleId = "mineral", labelKey = "bench_mineral", required = true, ingredients = { { ingredientId = "mineral", labelKey = "bench_mineral", unit = "FRACTION", min = 0.01, max = 0.3 } } } } }
end
local function registerStandIn(handle, version)
    version = version or STAND.version
    return handle.registerPreparationProfile("bench", PROFILE_ID, version, { mode = "GUIDANCE", labelKey = "bench_profile", editor = editor() }, {
        validate = function() STAND.validates = STAND.validates + 1 if STAND.reject then return false, "BENCH_REFUSED" end return true end,
        acceptSavedDefinition = function(_, storedVersion) if storedVersion == version then return "EXACT_ACCEPT" end return "UNAVAILABLE", "BENCH_PROFILE_CHANGED" end })
end
--- A ration on the stand-in's basis; `edit` changes it before use.
local function ration(label, grass, straw, mineral, edit)
    local d = { definitionSchemaVersion = 1, profileId = PROFILE_ID, profileVersion = STAND.version, label = label or "Dairy ration", intent = "GUIDANCE_TARGET",
                basis = { kind = "PROPORTION", unit = "FRACTION", total = 1 },
                ingredients = { { ingredientId = "grass", roleId = "grass", unit = "FRACTION", value = grass or 0.6 },
                                { ingredientId = "straw", roleId = "straw", unit = "FRACTION", value = straw or 0.3 },
                                { ingredientId = "mineral", roleId = "mineral", unit = "FRACTION", value = mineral or 0.1 } } }
    if edit ~= nil then edit(d) end
    return d
end

--- Boot through main.lua's own load path. The stand-in registers unless opts.noProfile.
local function boot(saveDir, index, opts)
    opts = opts or {}
    MC.subscribers, MC.delayed = {}, {}
    local m = newMission(saveDir, index)
    engine("g_server", {})
    engine("g_currentMission", m)
    Vehicle.init()
    g_specializationManager:initSpecializations()
    local lines = printed(function()
        Mission00.load(m)
        Mission00.loadMission00Finished(m)
        -- A mod registers only where the handle offers registration (SG-4 installed).
        STAND.token = nil
        if not opts.noProfile and m.stockGuard.registerPreparationProfile ~= nil then STAND.token = registerStandIn(m.stockGuard, opts.version) end
        m:onFinishedLoading()
    end)
    m._lines = lines
    return m, StockGuard.hostOf(m)
end
local function nativeSave(m, dir)
    ENGINE_SAVE.finalDir = dir
    REAL.g_savegameController:saveSavegame(m.missionInfo, false)
    ENGINE_RUN_FRAMES(nil)
end
engine("g_savegameController", SavegameController.new())
local function reload(m, dir, index, opts)
    FSBaseMission.delete(m)
    return boot(dir, index, opts)
end
local function tick(m) FSBaseMission.update(m, 16) end
--- The saved envelope, decoded, and a writer for a changed one (the own-XML backend's token list).
local function envelopeAt(dir)
    local d = ENGINE_DISK[dir .. "/stockGuard.xml"]
    if d == nil then return nil end
    local tokens = {}
    for i = 1, d["stockGuard#count"] do tokens[i] = d[string.format("stockGuard.token(%d)#v", i - 1)] end
    return SGValues.decode(tokens)
end
local function writeEnvelope(dir, e)
    local tokens = SGValues.encode(e)
    local d = { ["stockGuard#count"] = #tokens }
    for i = 1, #tokens do d[string.format("stockGuard.token(%d)#v", i - 1)] = tokens[i] end
    ENGINE_DISK[dir .. "/stockGuard.xml"] = d
end

-- ── the host's own library view and commands ─────────────────────────────────
local LIBRARY = { route = "RECIPE_LIBRARY", selectionKind = "LIBRARY", libraryId = "@current" }
local function open(m, selection) return m.stockGuard.requestView(selection or LIBRARY, {}) end
local function libView(m) return m.stockGuard.getClientView("RECIPE_LIBRARY") end
local function rowsOf(v, kind) local out = {} for _, r in ipairs(v.view and v.view.rows or {}) do if r.rowKind == kind then out[#out + 1] = r end end return out end
local function libRow(v) return rowsOf(v, "LIBRARY")[1] end
local function actionOf(v, id) for _, a in ipairs((libRow(v) or {}).actions or {}) do if a.actionId == id then return a end end return nil end
--- "label:rev:availability:reason[:retired]" for each RECIPE row.
local function recipes(v)
    local out = {}
    for _, r in ipairs(rowsOf(v, "RECIPE")) do
        out[#out + 1] = r.definition.label .. ":" .. r.recipeRevision .. ":" .. r.availability .. ":" .. r.reasonCode .. (r.retired and ":retired" or "")
    end
    return table.concat(out, ",")
end
local function shownLibrary(m)
    local v = libView(m)
    local lib = libRow(v) or {}
    return tostring(v.state) .. "/" .. tostring(lib.libraryId) .. "/" .. tostring(lib.libraryRevision) .. "/" .. #rowsOf(v, "RECIPE") .. "/" .. tostring(v.reason)
end
--- One SG_COMMAND_2 request from the host's own player, through the host's admission (the server
--- builds the actor). The session and sequence follow the last result.
local function cmd(m, phase, actionId, args, opts)
    opts = opts or {}
    local sg = StockGuard.hostOf(m)
    local v = libView(m)
    local lib = libRow(v) or {}
    local creds = v.credentials or {}
    local last = m._last or {}
    local req = { protocolVersion = 2, route = "RECIPE_LIBRARY", commandSessionId = opts.session or last.session or creds.commandSessionId,
        sequence = opts.sequence or last.nextSequence or creds.nextSequence, phase = phase, actionId = actionId, targetKind = "LIBRARY",
        targetId = opts.targetId or lib.libraryId, expectedRevision = opts.expectedRevision or lib.libraryRevision, arguments = args, quoteToken = opts.quoteToken }
    sg:onCommandRequest(nil, req)
    local res = sg.lastCommandResult or {}
    -- A refusal before the session (a malformed request) names no session or sequence: keep the request's.
    local function given(v) return v ~= nil and v ~= "" end
    m._last = { session = given(res.commandSessionId) and res.commandSessionId or req.commandSessionId, nextSequence = given(res.nextSequence) and res.nextSequence or req.sequence }
    return res, req
end
--- QUOTE, then EXECUTE with its token; the host republishes on the next tick.
local function quoteExecute(m, actionId, args)
    local q = cmd(m, "QUOTE", actionId, args)
    if q.outcome ~= "QUOTED" then return q, q end
    local e, req = cmd(m, "EXECUTE", actionId, args, { quoteToken = q.quoteToken, expectedRevision = q.offer.expectedRevision })
    tick(m)
    return e, q, req
end
local function outcome(r) return tostring(r.outcome) .. "/" .. tostring(r.reasonCode) end

-- ══════════════════════════════════════════════════════════════════════════
-- J. THE ENTRY-POINT BAR: main.lua's install, a profile, SAVE_RECIPE through SG-1, a save and reload
-- ══════════════════════════════════════════════════════════════════════════
group("J", function()
    local m, sg = boot("j1", 81)
    T.eq("J0 [reached] main.lua's load path installed SG-4: its section, its LIBRARY owner, the RECIPE_LIBRARY view's owner and the handle's profile registration",
        tostring(sg.registry:get(SGRegistry.KIND_SAVE_SECTION, "sg4") ~= nil) .. "/" .. tostring(sg.registry:get(SGRegistry.KIND_MANAGEMENT, "sg4") ~= nil)
        .. "/" .. tostring(sg.registry:libraryView() ~= nil and sg.registry:libraryView().ownerId) .. "/" .. tostring(STAND.token ~= nil)
        .. "/" .. count(m._lines, "[StockGuard] SG-4: installed"), "true/true/sg4/true/1")
    open(m)
    local v = libView(m)
    local save, retire = actionOf(v, "SAVE_RECIPE"), actionOf(v, "RETIRE_RECIPE")
    T.eq("J1 a first-use load gives the host's farm an empty library on its first @current view, with the stand-in's PROFILE row and SAVE_RECIPE admitted",
        shownLibrary(m) .. " | " .. #rowsOf(v, "PROFILE") .. ":" .. tostring((rowsOf(v, "PROFILE")[1] or {}).profileId) .. " | " .. tostring(save and save.available) .. "/" .. tostring(save and save.admission)
        .. " " .. tostring(retire and retire.available) .. "/" .. tostring(retire and retire.reasonCode), "READY/lib1/1/0/ | 1:BENCH_MIXER | true/QUOTED false/RECIPE_UNKNOWN")
    local caps = m.stockGuard.getCapabilities()
    T.eq("J1b getCapabilities names the library's owner, schema and readiness",
        tostring((caps.recipeLibrary or {}).ownerId) .. "/" .. tostring((caps.recipeLibrary or {}).schemaVersion) .. "/" .. tostring(((caps.recipeLibrary or {}).readiness or {}).state), "sg4/1/READY")
    local before = STAND.validates
    local e, q = quoteExecute(m, "SAVE_RECIPE", { definition = ration() })
    T.eq("J2 [entry point] NAMED (SG-4 Part 2a): a SAVE_RECIPE QUOTE then EXECUTE through SG-1's admission saves the ration, validated by its profile, and the host's view shows it",
        outcome(q) .. " " .. tostring(q.offer and q.offer.targetLabel) .. " | " .. outcome(e) .. " " .. tostring(e.resultingRevision) .. " | " .. shownLibrary(m) .. " " .. recipes(libView(m))
        .. " | " .. tostring(STAND.validates > before), "QUOTED/ Dairy ration | APPLIED/ 2 | READY/lib1/2/1/ Dairy ration:1:AVAILABLE: | true")
    nativeSave(m, "j1")
    local m2 = reload(m, "j1", 81)
    open(m2)
    T.eq("J3 the library survives an SG_SAVE_2 save and a reload: the same library, recipe and revision, available under its profile",
        shownLibrary(m2) .. " " .. recipes(libView(m2)), "READY/lib1/2/1/ Dairy ration:1:AVAILABLE:")
    FSBaseMission.delete(m2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- K. NO PROFILE REGISTERED: NOTHING TO SAVE AGAINST
-- ══════════════════════════════════════════════════════════════════════════
group("K", function()
    local m = boot("k1", 83, { noProfile = true })
    open(m)
    local save = actionOf(libView(m), "SAVE_RECIPE")
    local q = cmd(m, "QUOTE", "SAVE_RECIPE", { definition = ration() })
    T.eq("K1 with no profile registered at init, SAVE_RECIPE is unavailable with its reason, and a QUOTE answers UNAVAILABLE before the owner",
        tostring(save and save.available) .. "/" .. tostring(save and save.reasonCode) .. " | " .. outcome(q), "false/NO_PROFILE | UNAVAILABLE/NO_PROFILE")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. REVISIONS: STALE, EDIT, A DUPLICATE EXECUTE, RETIRE
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    local m = boot("r1", 84)
    open(m)
    quoteExecute(m, "SAVE_RECIPE", { definition = ration() })
    local stale = cmd(m, "QUOTE", "SAVE_RECIPE", { definition = ration("Late") }, { expectedRevision = "1" })
    T.eq("R1 a request at a stale library revision is STALE before any effect", outcome(stale) .. " | " .. shownLibrary(m), "STALE/TARGET_REVISION | READY/lib1/2/1/")
    local e = quoteExecute(m, "SAVE_RECIPE", { recipeId = "r2", recipeRevision = "1", definition = ration("Dairy ration", 0.5, 0.4, 0.1) })
    local old = m.stockGuard.readRecipe({ farmId = 1, userId = "host", actorState = "RESOLVED" }, "r2", 1)
    local new = m.stockGuard.readRecipe({ farmId = 1, userId = "host", actorState = "RESOLVED" }, "r2", 2)
    T.eq("R2 an edit at the recipe's current revision makes revision 2, immutable; the superseded revision is gone in this part (nothing references it)",
        outcome(e) .. " | " .. recipes(libView(m)) .. " | " .. tostring(old.state) .. "/" .. tostring(old.reason) .. " " .. tostring(new.state) .. ":" .. tostring(new.definition and new.definition.ingredients[1].value),
        "APPLIED/ | Dairy ration:2:AVAILABLE: | UNAVAILABLE/RECIPE_UNKNOWN READY:0.5")
    local staleEdit = cmd(m, "QUOTE", "SAVE_RECIPE", { recipeId = "r2", recipeRevision = "1", definition = ration() })
    T.eq("R3 an edit made from an older revision of the recipe refuses with its refresh reason", outcome(staleEdit), "REFUSED/RECIPE_STALE")
    local executions = 0
    local realExecute = SG4Owner.execute
    SG4Owner.execute = function(...) executions = executions + 1 return realExecute(...) end
    local q = cmd(m, "QUOTE", "SAVE_RECIPE", { definition = ration("Second") })
    local opts = { quoteToken = q.quoteToken, expectedRevision = q.offer.expectedRevision }
    local first, req = cmd(m, "EXECUTE", "SAVE_RECIPE", { definition = ration("Second") }, opts)
    StockGuard.hostOf(m):onCommandRequest(nil, req)
    local again = StockGuard.hostOf(m).lastCommandResult
    SG4Owner.execute = realExecute
    tick(m)
    T.eq("R4 a duplicate EXECUTE returns the retained result and runs the owner once",
        outcome(first) .. " " .. tostring(first.resultingRevision) .. " | " .. outcome(again) .. " " .. tostring(again.resultingRevision) .. " | " .. executions .. " | " .. #rowsOf(libView(m), "RECIPE"),
        "APPLIED/ 4 | APPLIED/ 4 | 1 | 2")
    local staleRetire = cmd(m, "QUOTE", "RETIRE_RECIPE", { recipeId = "r2", recipeRevision = "1" })
    T.eq("R5b a RETIRE made from an older revision of the recipe refuses with its refresh reason", outcome(staleRetire), "REFUSED/RECIPE_STALE")
    local r = quoteExecute(m, "RETIRE_RECIPE", { recipeId = "r2", recipeRevision = "2" })
    local kept = m.stockGuard.readRecipe({ farmId = 1, userId = "host", actorState = "RESOLVED" }, "r2", 2)
    T.eq("R5 RETIRE takes the recipe out of selection and keeps its revision readable",
        outcome(r) .. " | " .. recipes(libView(m)) .. " | " .. tostring(kept.state) .. "/" .. tostring(kept.retired), "APPLIED/ | Dairy ration:2:AVAILABLE::retired,Second:1:AVAILABLE: | READY/true")
    local editRetired = cmd(m, "QUOTE", "SAVE_RECIPE", { recipeId = "r2", recipeRevision = "2", definition = ration() })
    T.eq("R6 a retired recipe cannot be edited", outcome(editRetired), "REFUSED/RECIPE_RETIRED")
    -- The profile starts refusing between the quote and the execute: the execute revalidates before any effect.
    local q7 = cmd(m, "QUOTE", "SAVE_RECIPE", { definition = ration("Third") })
    STAND.reject = true
    local e7 = cmd(m, "EXECUTE", "SAVE_RECIPE", { definition = ration("Third") }, { quoteToken = q7.quoteToken, expectedRevision = q7.offer.expectedRevision })
    STAND.reject = false
    T.eq("R7 EXECUTE revalidates the quoted request: a definition its profile now refuses is STALE_QUOTE, nothing saved",
        outcome(q7) .. " " .. outcome(e7) .. " | " .. #rowsOf(libView(m), "RECIPE"), "QUOTED/ STALE_QUOTE/BENCH_REFUSED | 2")
    -- A client names another action's schema in its arguments: SG-1 stamps the resolved action's own over it.
    local forged = cmd(m, "QUOTE", "SAVE_RECIPE", { argumentSchemaId = "SG4_RETIRE_RECIPE_1", recipeId = "r3", recipeRevision = "1" })
    T.eq("R8 the arguments carry the resolved action's schema, never the client's: a SAVE with RETIRE's arguments is a SAVE without a definition",
        outcome(forged) .. " | " .. recipes(libView(m)), "REFUSED/DEFINITION_INVALID | Dairy ration:2:AVAILABLE::retired,Second:1:AVAILABLE:")
    local host = { farmId = 1, userId = "host", actorState = "RESOLVED" }
    T.eq("R9 listRecipes lists the farm's recipes, filtered by profile when one is named",
        #m.stockGuard.listRecipes(host).recipes .. "/" .. #m.stockGuard.listRecipes(host, PROFILE_ID).recipes .. "/" .. #m.stockGuard.listRecipes(host, "OTHER").recipes, "2/2/0")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- V. VALIDATION AGAINST THE PROFILE (:70, :381)
-- ══════════════════════════════════════════════════════════════════════════
group("V", function()
    local m = boot("v1", 85)
    open(m)
    local function refusal(edit)
        local q = cmd(m, "QUOTE", "SAVE_RECIPE", { definition = ration(nil, nil, nil, nil, edit) })
        return tostring(q.reasonCode)
    end
    local out = {
        refusal(function(d) d.ingredients[4] = { ingredientId = "grass", roleId = "grass", unit = "FRACTION", value = 0 } end),
        refusal(function(d) d.ingredients[2].ingredientId = "maize" end),
        refusal(function(d) d.ingredients[1].unit = "LITRE" end),
        refusal(function(d) d.ingredients[1].value = 0.9 d.ingredients[2].value = 0 end),
        refusal(function(d) d.ingredients[1].value = 0.5 end),
        refusal(function(d) d.ingredients[1].value = 0.7 table.remove(d.ingredients, 3) end),
        refusal(function(d) d.intent = "DRAFT" end),
        refusal(function(d) d.ingredients[1].value = 0 / 0 end),
        refusal(function(d) d.basis.total = 2 end),
        refusal(function(d) d.profileVersion = 2 end),
        refusal(function(d) d.label = string.rep("x", 65) end),
        refusal(function(d) d.dilution = { diluentId = "WATER", strength = 0.5 } end),
        refusal(function(d) d.defaultBatchAmount = { value = 1000, unit = "LITRE" } end),
    }
    STAND.reject = true
    out[#out + 1] = refusal(nil)
    STAND.reject = false
    T.eq("V1 a duplicate, an unknown ingredient, an unsupported unit, a value past its bounds, an incomplete total, a missing required role, an intent the profile does not admit, a non-finite value, another basis, another profile version, a label past 64 bytes, a dilution or a default batch the profile does not support, and the profile's own refusal",
        table.concat(out, " "), "INGREDIENT_INVALID INGREDIENT_INVALID INGREDIENT_INVALID VALUE_OUT_OF_BOUNDS TOTAL_INCOMPLETE REQUIRED_ROLE_MISSING INTENT_UNSUPPORTED ARGUMENTS DEFINITION_INVALID PROFILE_UNAVAILABLE DEFINITION_INVALID DEFINITION_INVALID DEFINITION_INVALID BENCH_REFUSED")
    T.eq("V2 nothing was saved", shownLibrary(m), "READY/lib1/1/0/")
    -- A library whose next save would pass the private view's row budget (the budget lowered to the empty
    -- library's own rows, a stand-in of a full one).
    local budget = SGViews.PAGE_TOKEN_BUDGET
    SGViews.PAGE_TOKEN_BUDGET = 40
    local full = cmd(m, "QUOTE", "SAVE_RECIPE", { definition = ration() })
    SGViews.PAGE_TOKEN_BUDGET = budget
    T.eq("V3 a save that would take the library past the view's row budget refuses LIBRARY_FULL", outcome(full), "REFUSED/LIBRARY_FULL")
    -- The registration contract (:66-70).
    local function reg(providerId, profileId, definition, callbacks)
        local token, why = m.stockGuard.registerPreparationProfile(providerId, profileId, 1, definition, callbacks)
        return tostring(token ~= nil) .. ":" .. tostring(why)
    end
    local cbs = { validate = function() return true end, acceptSavedDefinition = function() return "EXACT_ACCEPT" end }
    local function withEditor(edit) local e = editor() edit(e) return { mode = "GUIDANCE", labelKey = "x", editor = e } end
    local server = REAL.g_server
    local res = {
        reg("other", "X1", { mode = "EXECUTABLE", labelKey = "x", editor = editor() }, cbs),
        reg("other", "X2", withEditor(function(e) e.allowedIntents = { "EXECUTABLE_TARGET" } end), cbs),
        reg("other", "X3", withEditor(function(e) e.roles[2].roleId = "grass" end), cbs),
        reg("other", "X4", withEditor(function(e) e.roles[1].ingredients[1].min = 0.9 end), cbs),
        reg("bench", PROFILE_ID, { mode = "GUIDANCE", labelKey = "x", editor = editor() }, cbs),
        reg("other", PROFILE_ID, { mode = "GUIDANCE", labelKey = "x", editor = editor() }, cbs),
        reg("other", "X7", { mode = "GUIDANCE", labelKey = "x", editor = editor() }, { validate = cbs.validate }),
    }
    REAL.g_server = nil
    res[#res + 1] = reg("other", "X8", { mode = "GUIDANCE", labelKey = "x", editor = editor() }, cbs)
    REAL.g_server = server
    T.eq("P1 registerPreparationProfile refuses EXECUTABLE (no execution yet), an intent GUIDANCE cannot admit, a duplicate role, inverted bounds, a second registration, another provider's id, missing callbacks, and a client",
        table.concat(res, " "), "false:EXECUTION_UNBUILT false:EDITOR:INTENTS false:EDITOR:ROLE false:EDITOR:INGREDIENT_BOUNDS false:DUPLICATE_PROFILE false:PROFILE_CONFLICT false:CALLBACKS false:NOT_SERVER")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. THE LOAD: A MISSING PROFILE, A LATE ONE, A CORRUPT PAYLOAD, AN INITIALIZED SECTION WITHOUT ITS PAYLOAD
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    local m = boot("l1", 86)
    open(m)
    quoteExecute(m, "SAVE_RECIPE", { definition = ration() })
    nativeSave(m, "l1")
    local m2 = reload(m, "l1", 86, { noProfile = true })
    open(m2)
    T.eq("L1 a profile missing at reload stages its recipe LOCKED and visible, and SAVE_RECIPE waits for a profile",
        recipes(libView(m2)) .. " | " .. tostring(actionOf(libView(m2), "SAVE_RECIPE").reasonCode), "Dairy ration:1:UNAVAILABLE:PROFILE_ABSENT | NO_PROFILE")
    registerStandIn(m2.stockGuard)
    tick(m2)
    T.eq("L2 a later registration that answers EXACT_ACCEPT unlocks it", recipes(libView(m2)), "Dairy ration:1:AVAILABLE:")
    local m3 = reload(m2, "l1", 86, { noProfile = true })
    registerStandIn(m3.stockGuard, 2)
    open(m3)
    T.eq("L3 a profile whose acceptSavedDefinition refuses the saved version keeps the recipe LOCKED with the profile's reason", recipes(libView(m3)), "Dairy ration:1:UNAVAILABLE:BENCH_PROFILE_CHANGED")
    FSBaseMission.delete(m3)
    -- A corrupt sg4 payload: its schema version broken.
    local e = envelopeAt("l1")
    e.sections.sg4.payload.schemaVersion = 99
    writeEnvelope("l1", e)
    local m4 = boot("l1", 86)
    open(m4)
    T.eq("L4 a corrupt payload leaves the library UNAVAILABLE, never an empty library", shownLibrary(m4), "UNAVAILABLE/nil/nil/0/LIBRARY_UNAVAILABLE")
    nativeSave(m4, "l1")
    T.eq("L5 and the next save carries the original payload unchanged (SG-1 retains it)", tostring(envelopeAt("l1").sections.sg4.payload.schemaVersion), "99")
    FSBaseMission.delete(m4)
    -- An initialized sg4 section whose payload is missing: SG-1 refuses the envelope.
    local e2 = envelopeAt("l1")
    e2.sections.sg4 = nil
    writeEnvelope("l1", e2)
    local m5 = boot("l1", 86)
    open(m5)
    T.eq("L6 an initialized section with its payload missing is not first use: the library is UNAVAILABLE", shownLibrary(m5), "UNAVAILABLE/nil/nil/0/LIBRARY_UNAVAILABLE")
    local def = { libraryId = "lib1", recipeId = "r2", revision = 1, definition = ration() }
    local function staged(edit)
        local p = { schemaVersion = 1, nextSerial = 2, recipeDefinitions = { ["lib1|r2|1"] = SGValues.copy(def) },
            libraries = { lib1 = { ownerFarmId = 1, retired = false, libraryRevision = 2, recipes = { r2 = { currentRevision = 1, retired = false } } } } }
        edit(p)
        local cand, why = SG4Library.stage(p, {})
        return tostring(cand ~= nil) .. ":" .. tostring(why)
    end
    T.eq("L7 the staged payload is checked whole: a current revision without its definition, an orphan definition, a recipe id and a library id above the saved serial, a definition under another key",
        staged(function(p) p.recipeDefinitions = {} end) .. " " .. staged(function(p) p.recipeDefinitions["lib1|r9|1"] = { libraryId = "lib1", recipeId = "r9", revision = 1, definition = ration() } end)
        .. " " .. staged(function(p) p.nextSerial = 1 end) .. " " .. staged(function(p) p.libraries.lib9 = { ownerFarmId = 2, retired = false, libraryRevision = 1, recipes = {} } end)
        .. " " .. staged(function(p) p.recipeDefinitions["lib1|r2|1"].revision = 2 end) .. " " .. staged(function() end),
        "false:REFERENCE_MISSING false:ORPHAN_DEFINITION false:SERIAL false:SERIAL false:DEFINITION_KEY true:nil")
    FSBaseMission.delete(m5)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. FARMS (:363)
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    local m, sg = boot("f1", 87)
    open(m)
    quoteExecute(m, "SAVE_RECIPE", { definition = ration() })
    MC:publishDelayed(MessageType.FARM_DELETED, 1)
    MC:deliver()
    local lib1 = SG4.current.library.libraries.lib1
    open(m)
    T.eq("F1 FARM_DELETED retires the farm's library; a farm with that id then gets a new, empty library",
        tostring(lib1.retired) .. "/" .. tostring(lib1.retiredReason) .. " | " .. shownLibrary(m), "true/FARM_DELETED | READY/lib3/1/0/")
    local retiredView = m.stockGuard.getRecipeLibraryView({ farmId = 1, userId = "host", actorState = "RESOLVED" }, { libraryId = "lib1" })
    -- FARM_DELETED withdrew every command session (SG:onFarmDeleted): the reopened view's credentials are fresh.
    local fresh = libView(m).credentials
    local retiredCmd = cmd(m, "QUOTE", "SAVE_RECIPE", { definition = ration() },
        { targetId = "lib1", expectedRevision = tostring(lib1.libraryRevision), session = fresh.commandSessionId, sequence = fresh.nextSequence })
    T.eq("F1b the retired library is neither viewed nor reached by a command", tostring(retiredView.state) .. "/" .. tostring(retiredView.reason) .. " | " .. outcome(retiredCmd),
        "UNAVAILABLE/LIBRARY_RETIRED | REFUSED/UNAUTHORIZED")
    MC:publish(MessageType.FARM_CREATED, 1)
    open(m)
    T.eq("F2 a FARM_CREATED for an id that still has a live library retires it (its deletion was not seen), and the new farm gets its own",
        tostring(SG4.current.library.libraries.lib3.retiredReason) .. " | " .. shownLibrary(m), "FARM_ID_REUSED | READY/lib4/1/0/")
    local payload = { schemaVersion = 1, nextSerial = 9, recipeDefinitions = {},
        libraries = { lib7 = { ownerFarmId = 1, retired = false, libraryRevision = 1, recipes = {} }, lib8 = { ownerFarmId = 2, retired = false, libraryRevision = 3, recipes = {} } } }
    local cand = SG4Library.stage(payload, { farmRestore = { version = 1, phase = SGFarmRestore.PHASE_MERGED, sourceToTarget = { [2] = 1 }, targetFarmId = 1 } })
    T.eq("F3 a singleplayer opening of a multiplayer save retires the merged farm's library under its old owner at staged load; the survivor's is untouched",
        tostring(cand.libraries.lib8.retired) .. "/" .. tostring(cand.libraries.lib8.retiredReason) .. "/" .. cand.libraries.lib8.ownerFarmId .. "/" .. cand.libraries.lib8.libraryRevision
        .. " " .. tostring(cand.libraries.lib7.retired) .. "/" .. cand.libraries.lib7.libraryRevision, "true/FARM_MERGED/2/4 false/1")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- X. PRIVACY: ANOTHER FARM'S LIBRARY IS NEVER LISTED, READ OR REACHED
-- ══════════════════════════════════════════════════════════════════════════
group("X", function()
    local m, sg = boot("x1", 88)
    open(m)
    quoteExecute(m, "SAVE_RECIPE", { definition = ration() })
    local farm2 = { farmId = 2, userId = "u2", actorState = "RESOLVED", connectionId = "c2" }
    local seen = m.stockGuard.getRecipeLibraryView(farm2, { libraryId = "lib1" })
    local list = m.stockGuard.listRecipes(farm2)
    local read = m.stockGuard.readRecipe(farm2, "r2", 1)
    T.eq("X1 farm 2 neither views, lists nor reads farm 1's library", tostring(seen.state) .. "/" .. tostring(seen.reason) .. " | " .. tostring(list.state) .. ":" .. #list.recipes
        .. " | " .. tostring(read.state) .. "/" .. tostring(read.reason), "DENIED/LIBRARY_NOT_OWNED | READY:0 | UNAVAILABLE/RECIPE_UNKNOWN")
    local own = m.stockGuard.getRecipeLibraryView(farm2, { libraryId = "@current" })
    local adminView = m.stockGuard.getRecipeLibraryView({ farmId = 1, userId = "host", actorState = "RESOLVED", isMasterUser = true }, { libraryId = own.view.libraryId })
    T.eq("X2 an administrator of farm 1 gets no cross-farm library", tostring(own.state) .. "/" .. tostring(own.view.libraryId) .. " | " .. tostring(adminView.state) .. "/" .. tostring(adminView.reason),
        "READY/lib3 | DENIED/LIBRARY_NOT_OWNED")
    -- A remote player of farm 2 asks to retire farm 1's recipe through the admission path.
    local conn = { streamId = 22, getIsServer = function() return false end, sendEvent = function() end }
    m._users[conn] = MakeUser("u2", false)
    m._farms[conn] = 2
    local creds = sg.commands:credentialsFor(sg:resolveActorFor(conn), "RECIPE_LIBRARY")
    sg:onCommandRequest(conn, { protocolVersion = 2, route = "RECIPE_LIBRARY", commandSessionId = creds.commandSessionId, sequence = creds.nextSequence, phase = "QUOTE",
        actionId = "RETIRE_RECIPE", targetKind = "LIBRARY", targetId = "lib1", expectedRevision = "2", arguments = { recipeId = "r2", recipeRevision = "1" } })
    T.eq("X3 a farm 2 command on farm 1's library is refused at admission", outcome(sg.commands.sessions[creds.commandSessionId].latest.result), "REFUSED/UNAUTHORIZED")
    FSBaseMission.delete(m)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. A CLIENT DECODES THE LIBRARY WITH THE SAME CHECK
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    local m, sg = boot("n1", 89)
    open(m)
    quoteExecute(m, "SAVE_RECIPE", { definition = ration() })
    local page = m.stockGuard.getRecipeLibraryView({ farmId = 1, userId = "host", actorState = "RESOLVED" }, { libraryId = "@current" })
    local tokens = SGViews.encodeView(page.view)
    -- A pure client, booted through main.lua: its hook registers the library's row check.
    local c = newMission("n1c", 90, false)
    engine("g_server", nil)
    engine("g_currentMission", c)
    Mission00.load(c)
    Mission00.loadMission00Finished(c)
    c:onFinishedLoading()
    local csg = StockGuard.hostOf(c)
    local view, why = csg.views:decodeRouteView(tokens, "RECIPE_LIBRARY")
    local broken = SGValues.copy(page.view)
    broken.rows[2].definition.ingredients[1].unit = "PINT"
    local bad, whyBad = csg.views:decodeRouteView(SGViews.encodeView(broken), "RECIPE_LIBRARY")
    T.eq("N1 a client's own registration decodes the server's library view, and refuses a row its check refuses",
        tostring(csg.registry:libraryView() ~= nil and csg.registry:libraryView().ownerId) .. " | " .. tostring(view and view.availability) .. "/" .. #(view and view.rows or {}) .. "/" .. tostring(why)
        .. " | " .. tostring(bad) .. "/" .. tostring(whyBad), "sg4 | READY/3/nil | nil/MALFORMED_ROW")
    local twice = SGValues.copy(page.view)
    twice.rows[#twice.rows + 1] = SGValues.copy(twice.rows[1])
    local noLib = SGValues.copy(page.view)
    table.remove(noLib.rows, 1)
    local a = { csg.views:decodeRouteView(SGViews.encodeView(twice), "RECIPE_LIBRARY") }
    local b = { csg.views:decodeRouteView(SGViews.encodeView(noLib), "RECIPE_LIBRARY") }
    T.eq("N2 a READY library carries exactly one LIBRARY row, first", tostring(a[2]) .. " " .. tostring(b[2]), "MALFORMED_ROW MALFORMED_ROW")
    FSBaseMission.delete(c)
    engine("g_server", {})
    engine("g_currentMission", m)
    FSBaseMission.delete(m)
end)
