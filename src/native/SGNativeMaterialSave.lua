-- =========================================================
-- FS25_StockGuard - SG_NATIVE_MATERIAL_SAVE_V1, the native save boundary (SG2-4a)
-- =========================================================
-- SG-2 v2.3 :563-575 and "Current family native save composition" (:818-836). A
-- native save writes the career XML in one synchronous Lua call and the terrain height
-- image later: in a nonblocking save the controller only QUEUES the height preparation
-- (SavegameController.lua:556-568, an async task that calls prepareSaveDensityMapToFile
-- and then addSaveTask), and the game keeps running until the task comes round. Ground
-- material saved beside the XML would then describe a world the height image no longer
-- shows. This module closes that gap for every participant at once:
--
--   THE ATTEMPT. SavegameController:onSaveStartComplete (:373) is wrapped on the class
--   table; the engine reaches it by name (saveWriteSavegameStart(..., "onSaveStartComplete",
--   self), :726), so the call resolves through the class at call time. On a successful
--   start (errorCode == Savegame.ERROR_OK with a staging directory, :375) one attempt is
--   allocated from SG-1's own save counter (SGSave:openAttempt), so the StockGuard
--   envelope written inside the chain carries the same attempt id, and every registered
--   participant's beginAttempt runs BEFORE the original controller, which is then
--   called exactly once. A failed start opens nothing.
--
--   THE FREEZE. The career save is savegame:saveToXMLFile() (:384), FSCareerMissionInfo's
--   chain with every module's appends (StockGuard's own envelope among them). For the
--   length of the attempt an instance field on that one career-save object wraps the
--   whole chain as it resolved at that moment, and at the END of the chain, before it
--   returns to onSaveStartComplete, each participant's freezeAfterCareerXML runs. That
--   is before the controller's direct density-map writes in a blocking save (:400,
--   :415, :560), so the freeze sits beside them in the same call (brief :822). The
--   field is removed only while it still holds this wrapper.
--
--   THE IMAGES. A participant's READY answer names its payload file and its exact
--   images, {mapId, nativeFilename}. Each image must be one the controller will save
--   itself under that same map id: the controller saves one file per filename, the
--   first id met in its own order (fruit planes and haulms in g_fruitTypeManager's
--   order, :392-423, then the height map, :556), so the set is rebuilt in that order
--   and a descriptor naming another id for a file, or a file the controller does not
--   save, invalidates that participant. Only fruit, haulm and height images are
--   supported (the bounded participant contract, not an open framework). An image, or
--   a payload file, named by two participants invalidates every participant naming it
--   (DUPLICATE_MAP_PATH, PAYLOAD_FILE_CONFLICT), never keeping whichever came first
--   (brief :698).
--
--   THE SAME-CALL PREPARE (nonblocking only). Each distinct image of a READY participant
--   is prepared at the freeze, through the engine global as it is then resolved, and
--   the attempt keeps its {mapId, path}. When the controller's own queued closure later
--   calls prepareSaveDensityMapToFile for that exact map and path, the guard skips that
--   one call and the closure goes on to add its ordinary SAVE_TASK_DENSITY_MAP (:564-
--   566), so the prepared image is the one taken at the freeze and the disk write and
--   task order stay native. Every other call, map, path and save reaches the captured
--   predecessor. A blocking save prepares nothing: its direct writes follow in the same
--   call.
--
--   THE ENGINE GLOBAL. The controller's closures resolve prepareSaveDensityMapToFile
--   from the engine's environment when they run; it is not an upvalue. A mod's _G is
--   its own environment (mods.lua:489-495: modEnv._G = modEnv, metatable {__index = the
--   real _G}), so an assignment through _G would only shadow it for this mod. The guard
--   is written into the table that actually holds the callable, getmetatable(_G).__index,
--   and nowhere else; a mod-local same-named function is never wrapped. This writes a
--   real engine global: every unmatched call goes to the captured predecessor, the
--   guard is installed only while an attempt holds an association, and removal is
--   identity-checked, so a wrapper another mod put above it is never erased (brief
--   :824). A guard left under a later wrapper stays a pass-through and is reused.
--
--   THE RESULT. SavegameController:onSaveComplete(errorCode, finalSavegameDirectory)
--   (:672) is observed once per attempt: every participant that began receives
--   finishAttempt(context, errorCode, finalSavegameDirectory) with the actual values,
--   failures included, and context.results[participantId] says what SG2 decided for it.
--   A participant writes its completion marker only on ERROR_OK, a final directory and
--   its own READY result. The associations are then cleared and the guard removed.
--
--   THE SAME-CALL DEFERRALS (SG-2 :565). A supported material mutation that re-enters
--   the boundary is held until it exits; no across-frame lock is added. The boundary
--   opens when the career XML chain starts and closes when onSaveStartComplete returns,
--   so in a blocking save it also covers the direct height write that follows the XML
--   in the same call. This PR carries the two Combine drains: the due delay slot and
--   the bufferFillUnitIndex drain both run inside Combine:onUpdateTick (Combine.lua:459-
--   473 in 1.21.1.0 and 1.24.0.0; the brief cites them in Combine:onUpdate at the
--   official line numbers), a class event, so the deferral wraps that event on the
--   class, outside SGHarvestCapture's drain bracket, and holds the whole tick call with
--   its arguments; the held calls run once, in order, when the boundary closes. No
--   native path is known to reach that event inside the chain; this is the brief's named
--   guard for a re-entrant one, so a serialized fill unit and the delay slots saved with
--   it are one snapshot. The Leveler raycast callback and tipToGroundAroundLine are
--   SG2-4b's, beside their wraps.
--
-- NOT HERE (said on the PR): Soil's participant and CD-15's register through the same
-- calls in their own PRs; the ground producer (the brackets) is SG2-4b; the payload
-- written by the ground participant is SGGround's.
-- =========================================================

SGNativeMaterialSave = SGNativeMaterialSave or {}
local M = SGNativeMaterialSave
local M_mt = { __index = M }

M.PROFILE = "SG_NATIVE_MATERIAL_SAVE_V1"
M.CAPABILITY = 1
M.READY = "READY"
M.UNAVAILABLE = "UNAVAILABLE"
M.PENDING = "PENDING"
M.HOOK_ID = "nativeMaterialSave"
M.GUARDED_GLOBAL = "prepareSaveDensityMapToFile"
M.SUPPORTED_IMAGES = { FRUIT = true, HAULM = true, HEIGHT = true }

-- Process-wide state (the class hooks outlive a mission; the boundary does not).
M.current = M.current             -- the live per-mission boundary, set by activate()
M.guard = M.guard                 -- { table, original, wrapper } while ours is in the chain
M.associations = M.associations or {}
M.deferral = M.deferral or { depth = 0, queue = {} }
M.hooks = M.hooks or { controller = false }
M.logged = M.logged or {}

local function packn(...) return select("#", ...), { ... } end

local function log(msg) print("[StockGuard] native save: " .. tostring(msg)) end
local function logOnce(key, msg)
    if M.logged[key] then return end
    M.logged[key] = true
    log(msg)
end

local function errorOk()
    return Savegame ~= nil and Savegame.ERROR_OK ~= nil and Savegame.ERROR_OK or nil
end

-- ---------------------------------------------------------
-- The per-mission boundary and its participants
-- ---------------------------------------------------------
function M.new(host)
    local self = setmetatable({}, M_mt)
    self.host = host                 -- the StockGuard host (its SGSave allocates attempts)
    self.participants = {}           -- participantId -> spec (the owner's own table)
    self.attempt = nil
    self.lastAttempt = nil
    self.closed = false
    return self
end

--- registerNativeSaveParticipant(participantId, spec) -> true | false, reason. The same
--- spec again is idempotent; a different owner under a live id is refused.
function M:register(participantId, spec)
    if type(participantId) ~= "string" or participantId == "" or #participantId > 64 then return false, "INVALID_ID" end
    if type(spec) ~= "table" or type(spec.beginAttempt) ~= "function" or type(spec.freezeAfterCareerXML) ~= "function"
       or type(spec.finishAttempt) ~= "function" then
        return false, "INVALID_SPEC"
    end
    if self.closed then return false, "MISSION_ENDED" end
    local live = self.participants[participantId]
    if live ~= nil then
        if live == spec then return true end
        return false, "CONFLICT"
    end
    self.participants[participantId] = spec
    return true
end

--- unregisterNativeSaveParticipant(participantId, spec) -> true | false, reason. Removal
--- is by identity: only the registered spec removes itself.
function M:unregister(participantId, spec)
    local live = self.participants[participantId]
    if live == nil then return false, "NOT_REGISTERED" end
    if live ~= spec then return false, "NOT_OWNER" end
    self.participants[participantId] = nil
    return true
end

--- Publish this boundary as the live one: the class hooks answer to it and the
--- capability reads 1. Called after SG2's own participant registered.
function M:activate()
    if self.closed then return false end
    M.current = self
    return true
end

--- The nativeMaterialSave capability: 1 while this mission's boundary is the live one
--- and the controller hooks are installed, otherwise absent.
function M:capability()
    if self.closed or M.current ~= self or not M.hooks.controller then return nil end
    return M.CAPABILITY
end

--- Mission teardown: an open attempt is finished as failed (its participants clean up),
--- registrations are cleared, the associations dropped and the guard removed if ours.
function M:close(reason)
    if self.attempt ~= nil then
        local ok, err = pcall(self.finish, self, self.attempt, reason or "SG_TEARDOWN", nil)
        if not ok then log("teardown finish failed (" .. tostring(err) .. ")") end
    end
    self.participants = {}
    self.closed = true
    if M.current == self then M.current = nil end
    M.clearAssociations(nil)
    M.removeGuard()
    M.deferral.queue = {}
    M.deferral.depth = 0
end

-- ---------------------------------------------------------
-- The attempt
-- ---------------------------------------------------------
--- Open an attempt for a successful native save start. Returns the attempt, or nil when
--- this start is not one (a failed start, no live boundary, no career save).
function M.openAttempt(controller, errorCode, savegameDirectory)
    local self = M.current
    if self == nil or self.closed then return nil end
    local ok = errorOk()
    if ok == nil or errorCode ~= ok or savegameDirectory == nil then return nil end
    if type(controller) ~= "table" or type(controller.currentSavegame) ~= "table" then return nil end
    if self.attempt ~= nil then
        -- The previous attempt never saw its result: its participants clean up as failed.
        self:finish(self.attempt, "SG_ATTEMPT_SUPERSEDED", nil)
    end
    local save = self.host ~= nil and self.host.save or nil
    if save == nil or type(save.openAttempt) ~= "function" then return nil end
    local context = {
        attemptId = save:openAttempt(),
        mission = g_currentMission,
        controller = controller,
        careerSave = controller.currentSavegame,
        stagingDirectory = savegameDirectory,
        isBlocking = controller.isSavingBlocking == true,
        results = {},
    }
    local attempt = { context = context, controller = controller, members = {}, frozen = false, finished = false }
    local ids = {}
    for id in pairs(self.participants) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local spec = self.participants[id]
        attempt.members[#attempt.members + 1] = { id = id, spec = spec }
        local okBegin, err = pcall(spec.beginAttempt, context)
        if okBegin then
            context.results[id] = { state = M.PENDING }
        else
            context.results[id] = { state = M.UNAVAILABLE, reason = "BEGIN_FAILED" }
            log("participant " .. id .. " failed at begin (" .. tostring(err) .. "); only it is unavailable for attempt " .. tostring(context.attemptId))
        end
    end
    self.attempt = attempt
    return attempt
end

--- Mark every still-pending member of an attempt UNAVAILABLE with one reason.
function M.invalidatePending(attempt, reason)
    for _, m in ipairs(attempt.members) do
        local r = attempt.context.results[m.id]
        if r == nil or r.state == M.PENDING then attempt.context.results[m.id] = { state = M.UNAVAILABLE, reason = reason } end
    end
end

--- Wrap the attempt's career save for the length of the attempt: the whole chain as it
--- resolves now, then the freeze at its end. Only the first call on that object is the
--- attempt's chain; a later one passes straight through.
function M.wrapCareerSave(attempt)
    local careerSave = attempt.context.careerSave
    local chain = careerSave.saveToXMLFile
    if type(chain) ~= "function" then return false end
    local ownField = rawget(careerSave, "saveToXMLFile")
    local wrapper
    wrapper = function(obj, ...)
        if obj ~= careerSave or attempt.chainEntered then return chain(obj, ...) end
        attempt.chainEntered = true
        attempt.deferralOpen = true
        M.openDeferral()
        local n, r = packn(pcall(chain, obj, ...))
        if r[1] then
            local okFreeze, err = pcall(M.freeze, attempt)
            if not okFreeze then
                M.invalidatePending(attempt, "FREEZE_FAILED")
                log("freeze failed (" .. tostring(err) .. "); the native save continues, the enhanced sections of attempt " .. tostring(attempt.context.attemptId) .. " are unavailable")
            end
        else
            M.invalidatePending(attempt, "CAREER_XML_FAILED")
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
    rawset(careerSave, "saveToXMLFile", wrapper)
    attempt.careerWrap = { object = careerSave, wrapper = wrapper, ownField = ownField }
    return true
end

--- Remove the career-save field, only while it still holds this attempt's wrapper.
function M.unwrapCareerSave(attempt)
    local w = attempt.careerWrap
    if w == nil then return end
    attempt.careerWrap = nil
    if rawget(w.object, "saveToXMLFile") == w.wrapper then rawset(w.object, "saveToXMLFile", w.ownField) end
end

-- ---------------------------------------------------------
-- The native image set, in the controller's own order
-- ---------------------------------------------------------
--- filename -> { mapId, kind } for the density maps the controller saves and this
--- boundary supports, each file under the first id the controller meets for it.
function M.nativeImageSet(mission)
    local set = {}
    if getDensityMapFilename == nil then return set end
    local function claim(id, kind)
        if id == nil then return end
        local ok, filename = pcall(getDensityMapFilename, id)
        if ok and type(filename) == "string" and filename ~= "" and set[filename] == nil then set[filename] = { mapId = id, kind = kind } end
    end
    if g_fruitTypeManager ~= nil and type(g_fruitTypeManager.getFruitTypes) == "function" then
        for _, desc in pairs(g_fruitTypeManager:getFruitTypes()) do
            claim(desc.terrainDataPlaneId, "FRUIT")
            claim(desc.terrainDataPlaneIdHaulm, "HAULM")
        end
    end
    if mission ~= nil then claim(mission.terrainDetailHeightId, "HEIGHT") end
    return set
end

--- Validate one freeze answer. Returns the normalized answer, or nil and a reason.
function M.validateFreeze(out)
    if type(out) ~= "table" then return nil, "FREEZE_ANSWER" end
    if out.state == M.UNAVAILABLE then return { state = M.UNAVAILABLE, reason = tostring(out.reason or "UNAVAILABLE") } end
    if out.state ~= M.READY then return nil, "FREEZE_STATE" end
    local file = out.payloadFile
    if type(file) ~= "string" or file == "" or #file > 128 or file:find("..", 1, true) ~= nil or file:find("[/\\:]") ~= nil then
        return nil, "PAYLOAD_FILE"
    end
    if type(out.images) ~= "table" then return nil, "IMAGES" end
    local images = {}
    for i, img in ipairs(out.images) do
        if type(img) ~= "table" or img.mapId == nil or type(img.nativeFilename) ~= "string" or img.nativeFilename == "" then return nil, "IMAGE:" .. i end
        images[i] = { mapId = img.mapId, nativeFilename = img.nativeFilename }
    end
    return { state = M.READY, payloadFile = file, images = images }
end

--- The freeze, at the end of the career XML chain.
function M.freeze(attempt)
    if attempt.frozen then return end
    attempt.frozen = true
    local context = attempt.context
    local results = context.results
    -- 1. Each pending participant answers once.
    for _, m in ipairs(attempt.members) do
        if results[m.id].state == M.PENDING then
            local ok, out = pcall(m.spec.freezeAfterCareerXML, context)
            local answer, why
            if ok then answer, why = M.validateFreeze(out) else why = "FREEZE_THREW" end
            if answer == nil then
                results[m.id] = { state = M.UNAVAILABLE, reason = why }
                if not ok then log("participant " .. m.id .. " threw at freeze (" .. tostring(out) .. "); only it is unavailable") end
            else
                results[m.id] = answer
            end
        end
    end
    -- 2. Images against the controller's own set, then across participants: an image or
    -- a payload file named by two participants invalidates every participant naming it,
    -- never keeping whichever came first (brief :698).
    local native = M.nativeImageSet(context.mission)
    local claims = {}       -- filename -> set of participant ids naming it
    local payloads = {}     -- payloadFile -> list of participant ids
    for _, m in ipairs(attempt.members) do
        local r = results[m.id]
        if r.state == M.READY then
            payloads[r.payloadFile] = payloads[r.payloadFile] or {}
            table.insert(payloads[r.payloadFile], m.id)
            for _, img in ipairs(r.images) do
                local n = native[img.nativeFilename]
                if n == nil or n.mapId ~= img.mapId or not M.SUPPORTED_IMAGES[n.kind] then
                    results[m.id] = { state = M.UNAVAILABLE, reason = "IMAGE_NOT_NATIVE" }
                    break
                end
            end
            if results[m.id].state == M.READY then
                for _, img in ipairs(r.images) do
                    claims[img.nativeFilename] = claims[img.nativeFilename] or {}
                    claims[img.nativeFilename][m.id] = true
                end
            end
        end
    end
    local function invalidate(ids, reason)
        for _, id in ipairs(ids) do results[id] = { state = M.UNAVAILABLE, reason = reason } end
    end
    for _, set in pairs(claims) do
        local ids = {}
        for id in pairs(set) do ids[#ids + 1] = id end
        if #ids > 1 then invalidate(ids, "DUPLICATE_MAP_PATH") end
    end
    for _, ids in pairs(payloads) do
        if #ids > 1 then invalidate(ids, "PAYLOAD_FILE_CONFLICT") end
    end
    -- 3. The same-call prepare, nonblocking only.
    if context.isBlocking then return end
    local dir = context.careerSave.savegameDirectory or context.stagingDirectory
    local prepared = {}     -- filename -> true | false
    for _, m in ipairs(attempt.members) do
        local r = results[m.id]
        if r.state == M.READY then
            for _, img in ipairs(r.images) do
                if prepared[img.nativeFilename] == nil then
                    local path = dir .. "/" .. img.nativeFilename
                    local okPrep = M.prepareNow(img.mapId, path)
                    prepared[img.nativeFilename] = okPrep
                    if okPrep then
                        M.associations[#M.associations + 1] = { attemptId = context.attemptId, mapId = img.mapId, path = path, consumed = false }
                    end
                end
                if prepared[img.nativeFilename] == false then
                    results[m.id] = { state = M.UNAVAILABLE, reason = "PREPARE_FAILED" }
                end
            end
        end
    end
    if #M.associations > 0 then
        local okGuard, why = M.ensureGuard()
        if not okGuard then
            -- Without the guard the controller would prepare a second, later image.
            for _, m in ipairs(attempt.members) do
                local r = results[m.id]
                if r.state == M.READY and #r.images > 0 then results[m.id] = { state = M.UNAVAILABLE, reason = "GUARD_UNAVAILABLE:" .. tostring(why) } end
            end
            M.clearAssociations(context.attemptId)
        end
    end
end

-- ---------------------------------------------------------
-- The prepare guard on the engine global
-- ---------------------------------------------------------
--- The table that actually holds an engine global: the real global table behind this
--- mod's environment. A same-named function in the mod's own table is never returned.
function M.resolveEngineTable(name)
    local mt = getmetatable(_G)
    local base = mt ~= nil and type(mt.__index) == "table" and mt.__index or nil
    if base ~= nil then
        if type(rawget(base, name)) == "function" then return base, "ENGINE" end
        return nil, "ENGINE_GLOBAL_ABSENT"
    end
    -- No mod environment (a DLC's _G is the real one): this table is the engine's.
    if type(rawget(_G, name)) == "function" then return _G, "ROOT" end
    return nil, "ENGINE_GLOBAL_ABSENT"
end

--- Prepare one image now, through the global as it resolves at this moment.
function M.prepareNow(mapId, path)
    local t = M.resolveEngineTable(M.GUARDED_GLOBAL)
    if t == nil then return false end
    local ok, err = pcall(rawget(t, M.GUARDED_GLOBAL), mapId, path)
    if not ok then log("same-call prepare of " .. tostring(path) .. " failed (" .. tostring(err) .. ")") end
    return ok
end

function M.matchAssociation(mapId, path)
    for _, a in ipairs(M.associations) do
        if not a.consumed and a.mapId == mapId and a.path == path then return a end
    end
    return nil
end

function M.clearAssociations(attemptId)
    if attemptId == nil then M.associations = {} return end
    local keep = {}
    for _, a in ipairs(M.associations) do
        if a.attemptId ~= attemptId then keep[#keep + 1] = a
        elseif not a.consumed then
            log("the controller never asked to prepare " .. tostring(a.path) .. " for attempt " .. tostring(attemptId) .. "; the image prepared at the freeze was not written by it")
        end
    end
    M.associations = keep
end

--- Install the guard, or reuse ours if it is still in the chain.
function M.ensureGuard()
    if M.guard ~= nil then return true end
    local t, where = M.resolveEngineTable(M.GUARDED_GLOBAL)
    if t == nil then return false, where end
    local original = rawget(t, M.GUARDED_GLOBAL)
    local wrapper = function(mapId, path, ...)
        local a = M.matchAssociation(mapId, path)
        if a ~= nil then
            a.consumed = true      -- the one duplicate: the closure goes on to add its task
            return
        end
        return original(mapId, path, ...)
    end
    rawset(t, M.GUARDED_GLOBAL, wrapper)
    M.guard = { table = t, original = original, wrapper = wrapper }
    logOnce("guardTable", "prepare guard installed on the engine global " .. M.GUARDED_GLOBAL .. " (" .. tostring(where) .. " table, " .. (where == "ENGINE" and "getmetatable(_G).__index" or "_G") .. ")")
    return true
end

--- Remove the guard only while the slot still holds it; a later wrapper is never
--- erased, and ours then stays in the chain as a pass-through.
function M.removeGuard()
    local g = M.guard
    if g == nil then return true end
    if rawget(g.table, M.GUARDED_GLOBAL) == g.wrapper then
        rawset(g.table, M.GUARDED_GLOBAL, g.original)
        M.guard = nil
        return true
    end
    logOnce("guardUnder", "prepare guard left in place under a later wrapper of " .. M.GUARDED_GLOBAL .. "; it passes every call through")
    return false
end

-- ---------------------------------------------------------
-- The result
-- ---------------------------------------------------------
function M:finish(attempt, errorCode, finalSavegameDirectory)
    if attempt == nil or attempt.finished then return end
    attempt.finished = true
    if self.attempt == attempt then self.attempt = nil end
    local context = attempt.context
    M.invalidatePending(attempt, "NO_FREEZE")
    for _, m in ipairs(attempt.members) do
        local ok, err = pcall(m.spec.finishAttempt, context, errorCode, finalSavegameDirectory)
        if not ok then log("participant " .. m.id .. " failed at finish (" .. tostring(err) .. ")") end
    end
    M.clearAssociations(context.attemptId)
    M.removeGuard()
    local results = {}
    for id, r in pairs(context.results) do results[id] = { state = r.state, reason = r.reason } end
    self.lastAttempt = { attemptId = context.attemptId, errorCode = errorCode, results = results }
end

-- ---------------------------------------------------------
-- The same-call deferrals
-- ---------------------------------------------------------
function M.openDeferral() M.deferral.depth = M.deferral.depth + 1 end
function M.isDeferring() return M.deferral.depth > 0 end

function M.closeDeferral()
    local d = M.deferral
    if d.depth > 0 then d.depth = d.depth - 1 end
    if d.depth > 0 then return end
    local queue = d.queue
    d.queue = {}
    for _, call in ipairs(queue) do
        local ok, err = pcall(call.fn, unpack(call.args, 1, call.n))
        if not ok then log("held " .. call.name .. " failed when the boundary closed (" .. tostring(err) .. ")") end
    end
end

--- Hold a call while the boundary is open. Returns true when held.
function M.hold(name, fn, ...)
    if M.deferral.depth <= 0 then return false end
    local n, args = packn(...)
    table.insert(M.deferral.queue, { name = name, fn = fn, n = n, args = args })
    return true
end

-- ---------------------------------------------------------
-- Class hooks (mechanism 3: the class table read at call time)
-- ---------------------------------------------------------
local function aroundSaveStart(original, controller, errorCode, savegameDirectory, ...)
    local attempt = nil
    local okOpen, result = pcall(M.openAttempt, controller, errorCode, savegameDirectory)
    if okOpen then attempt = result else log("attempt open failed (" .. tostring(result) .. "); the native save runs unchanged") end
    if attempt ~= nil then
        local okWrap, wrapped = pcall(M.wrapCareerSave, attempt)
        if not okWrap or not wrapped then M.invalidatePending(attempt, "NO_CAREER_CHAIN") end
    end
    local n, r = packn(pcall(original, controller, errorCode, savegameDirectory, ...))
    if attempt ~= nil then
        M.unwrapCareerSave(attempt)
        if not attempt.chainEntered then M.invalidatePending(attempt, "NO_FREEZE") end
        local boundary = M.current
        if boundary ~= nil and boundary.host ~= nil and boundary.host.save ~= nil then boundary.host.save:closeAttempt(attempt.context.attemptId) end
        if attempt.deferralOpen then
            attempt.deferralOpen = false
            M.closeDeferral()
        end
    end
    if not r[1] then error(r[2], 0) end
    return unpack(r, 2, n)
end

local function aroundSaveComplete(original, controller, errorCode, finalSavegameDirectory, ...)
    local boundary = M.current
    if boundary ~= nil and boundary.attempt ~= nil and boundary.attempt.controller == controller then
        local ok, err = pcall(boundary.finish, boundary, boundary.attempt, errorCode, finalSavegameDirectory)
        if not ok then log("attempt finish failed (" .. tostring(err) .. ")") end
    end
    return original(controller, errorCode, finalSavegameDirectory, ...)
end

--- One wrapper per class and name for the process, rebound by every install (SGClassHook,
--- MAINTENANCE row 187): after a mods reload the live wrapper runs this module's code and
--- reads this module's M.current.
local function wrapClass(class, name, around)
    if type(class) ~= "table" or type(class[name]) ~= "function" then return false end
    return SGClassHook.wrap(class, name, M.HOOK_ID, around, M) ~= false
end

--- Install on the injected classes: SavegameController's start and result, and the
--- Combine drain deferral. Per class table, so a re-sourced Combine class (a new table
--- each mission load) takes it once; call it after SGHarvestCapture's hooks so the
--- deferral is the outermost wrapper of the drain event.
function M.installClassHooks(classes)
    if g_server == nil then return false end
    classes = classes or {}
    local SC = classes.SavegameController
    if type(SC) == "table" and type(SC.onSaveStartComplete) == "function" and type(SC.onSaveComplete) == "function" then
        wrapClass(SC, "onSaveStartComplete", aroundSaveStart)
        wrapClass(SC, "onSaveComplete", aroundSaveComplete)
        -- A wrapper that dispatches to THIS module, never merely "a mark exists".
        M.hooks.controller = SGClassHook.boundTo(SC, "onSaveStartComplete", M.HOOK_ID, M)
            and SGClassHook.boundTo(SC, "onSaveComplete", M.HOOK_ID, M)
    end
    wrapClass(classes.Combine, "onUpdateTick", function(original, self, ...)
        if M.hold("Combine.onUpdateTick", original, self, ...) then return end
        return original(self, ...)
    end)
    return M.hooks.controller
end
