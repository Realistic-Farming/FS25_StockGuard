-- =========================================================
-- FS25_StockGuard - the ground kind and its save (SG2-4a)
-- =========================================================
-- SG-2 v2.3 :158-160 (the grain and the sparse record), :563 (extensions.sg2Ground),
-- :567-573 (the payload beside the native save, its completion and its reload).
--
-- THE KIND. Ground material is recorded per native terrain-height cell: a sparse map of
-- tracked cells, each with its canonical fill type, its litres, its generation and a
-- reference into a table of shared immutable property payloads. A cell is identified
-- by native grid x and z on the mission's height layer; the layer itself is identified
-- by a stable descriptor (the height file name, the grid size, the terrain size and the
-- height and type channels), never by a runtime density-map id, so a changed map cannot
-- inherit another map's ground history. Adjacent cells along x with identical contents
-- are stored as one run; that changes the storage only, never the grain.
--
-- THE SAVE. SGGround is SG2's own participant of SG_NATIVE_MATERIAL_SAVE_V1
-- (SGNativeMaterialSave) and the owner of the SG-1 save section "sg2Ground":
--   beginAttempt      resolves the layer identity for this attempt;
--   the section       serializes extensions.sg2Ground = {schema=1, attemptId, mapKey,
--                     layerDescriptor, nativeHeightFile, groundPayloadFile,
--                     payloadSchema=1, boundary=XML_HEIGHT_SAME_CALL} inside the career
--                     XML chain, with the attempt id SG-1's envelope carries;
--   freeze            at the end of that chain takes the immutable slice, writes the
--                     one ground payload (that header plus the runs and properties, as
--                     SG_VALUES_2 tokens) into the staging directory, and answers READY
--                     with the height image; an empty set is a valid READY payload;
--   finishAttempt     on ERROR_OK, a final directory and its own READY result, writes
--                     the completion field into the payload in the FINAL directory; a
--                     failed or interrupted save leaves the payload incomplete.
-- On reload the section's stageLoad (run by SG-1 at its post-original onFinishedLoading
-- observer) requires the envelope's attempt, the descriptor, the current map and layer,
-- the payload's own header and its completion field to agree. Anything missing or
-- mismatched leaves the ground binding UNAVAILABLE with its reason, while every other
-- section and stock record restores independently. The stage never refuses outright:
-- a refused section would travel on unchanged, and an old descriptor can never match a
-- later payload; so the section installs, carrying the ground binding's own readiness,
-- and the next save writes a fresh descriptor and payload.
--
-- NOT HERE: the ground producer. Nothing writes a cell yet; the brackets that observe
-- native ground mutations are SG2-4b, so in production this freezes the empty set.
-- =========================================================

SGGround = SGGround or {}
local GR = SGGround
local GR_mt = { __index = GR }

GR.KIND = "ground"                     -- SGRecords.STORE_KINDS.ground
GR.SECTION_ID = "sg2Ground"
GR.PARTICIPANT_ID = "sg2Ground"
GR.SECTION_SCHEMA = 1
GR.PAYLOAD_SCHEMA = 1
GR.BOUNDARY = "XML_HEIGHT_SAME_CALL"
GR.PAYLOAD_FILE = "stockGuardGround.xml"
GR.PAYLOAD_ROOT = "stockGuardGround"
GR.READY = "READY"
GR.UNAVAILABLE = "UNAVAILABLE"
GR.PENDING = "PENDING"

local isFinite = SGValues.isFinite
local isInteger = SGValues.isInteger
local copy = SGValues.copy

local function log(msg) print("[StockGuard] ground: " .. tostring(msg)) end

local function nonempty(s, maxBytes) return type(s) == "string" and s ~= "" and #s <= (maxBytes or 512) end

function GR.new(host)
    local self = setmetatable({}, GR_mt)
    self.host = host
    self.cells = {}          -- "x:z" -> { x, z, fillType, liters, generation, property? }
    self.properties = {}     -- property key -> immutable payload tree
    self.readiness = nil     -- set by the section's commit or clear
    self.attempt = nil       -- { attemptId, identity?, reason?, written }
    self.lastMarker = nil
    return self
end

function GR.cellKey(x, z) return tostring(x) .. ":" .. tostring(z) end

-- ---------------------------------------------------------
-- The layer identity
-- ---------------------------------------------------------
--- The current map and height layer, or nil and a reason. The descriptor holds the
--- native file name, grid size, terrain size and channels (DensityMapHeightManager.lua
--- :351-378 reads the same), never the runtime id.
function GR.currentIdentity(mission)
    mission = mission or g_currentMission
    if mission == nil then return nil, "NO_MISSION" end
    local mapKey = mission.missionInfo ~= nil and mission.missionInfo.mapId or nil
    if not nonempty(mapKey, 256) then return nil, "NO_MAP_KEY" end
    local id = mission.terrainDetailHeightId
    if id == nil or getDensityMapFilename == nil or getDensityMapSize == nil then return nil, "NO_HEIGHT_MAP" end
    local okF, file = pcall(getDensityMapFilename, id)
    if not okF or not nonempty(file, 256) then return nil, "NO_HEIGHT_FILE" end
    local okS, size = pcall(getDensityMapSize, id)
    if not okS or not isFinite(size) or not isFinite(mission.terrainSize) then return nil, "NO_GRID" end
    if getDensityMapHeightFirstChannel == nil or getDensityMapHeightNumChannels == nil then return nil, "NO_CHANNELS" end
    local okC1, hFirst = pcall(getDensityMapHeightFirstChannel, id)
    local okC2, hNum = pcall(getDensityMapHeightNumChannels, id)
    local hm = g_densityMapHeightManager
    local tFirst = hm ~= nil and hm.heightTypeFirstChannel or nil
    local tNum = hm ~= nil and hm.heightTypeNumChannels or nil
    if not okC1 or not okC2 or not isInteger(hFirst) or not isInteger(hNum) or not isInteger(tFirst) or not isInteger(tNum) then return nil, "NO_CHANNELS" end
    local layer = string.format("height=%s;size=%.17g;terrain=%.17g;heightChannels=%d+%d;typeChannels=%d+%d", file, size, mission.terrainSize, hFirst, hNum, tFirst, tNum)
    return { mapKey = mapKey, layerDescriptor = layer, nativeHeightFile = file, heightId = id }
end

-- ---------------------------------------------------------
-- The record codec
-- ---------------------------------------------------------
--- A valid cell record, or nil and a reason.
function GR.validCell(c, properties)
    if type(c) ~= "table" then return nil, "NOT_TABLE" end
    if not isInteger(c.x) or not isInteger(c.z) or c.x < 0 or c.z < 0 then return nil, "COORDINATES" end
    if not nonempty(c.fillType, 128) then return nil, "FILL_TYPE" end
    if not isFinite(c.liters) or c.liters < 0 then return nil, "LITERS" end
    if not isInteger(c.generation) or c.generation < 1 then return nil, "GENERATION" end
    if c.property ~= nil and (not nonempty(c.property, 128) or type(properties) ~= "table" or properties[c.property] == nil) then return nil, "PROPERTY" end
    return c
end

local function sameContents(a, b)
    return a.fillType == b.fillType and a.liters == b.liters and a.generation == b.generation and a.property == b.property
end

--- The cells as runs: sorted by z then x; a run extends over the next cell of the same
--- row at x + 1 with identical contents. Returns the runs, or nil and a reason.
function GR.encodeCells(cells, properties)
    local list = {}
    for _, c in pairs(cells) do
        local ok, why = GR.validCell(c, properties)
        if ok == nil then return nil, "CELL:" .. why end
        list[#list + 1] = c
    end
    table.sort(list, function(a, b) if a.z ~= b.z then return a.z < b.z end return a.x < b.x end)
    local runs = {}
    local run = nil
    for _, c in ipairs(list) do
        if run ~= nil and run.z == c.z and run.x + run.n == c.x and sameContents(run, c) then
            run.n = run.n + 1
        else
            run = { z = c.z, x = c.x, n = 1, fillType = c.fillType, liters = c.liters, generation = c.generation, property = c.property }
            runs[#runs + 1] = run
        end
    end
    return runs
end

--- Runs back to cells. Overlapping runs, a bad field or an unknown property refuse the
--- whole payload.
function GR.decodeRuns(runs, properties)
    if type(runs) ~= "table" then return nil, "RUNS" end
    local cells = {}
    for i, r in ipairs(runs) do
        if type(r) ~= "table" or not isInteger(r.n) or r.n < 1 then return nil, "RUN:" .. i end
        for k = 0, r.n - 1 do
            local c = { x = (tonumber(r.x) or -1) + k, z = r.z, fillType = r.fillType, liters = r.liters, generation = r.generation, property = r.property }
            local ok, why = GR.validCell(c, properties)
            if ok == nil then return nil, "RUN:" .. i .. ":" .. why end
            local key = GR.cellKey(c.x, c.z)
            if cells[key] ~= nil then return nil, "OVERLAP:" .. key end
            cells[key] = c
        end
    end
    return cells
end

-- ---------------------------------------------------------
-- The payload file
-- ---------------------------------------------------------
function GR.writePayload(path, attemptId, tokens)
    if XMLFile == nil or XMLFile.create == nil then return false, "NO_XML" end
    local xmlFile = XMLFile.create("stockGuardGround", path, GR.PAYLOAD_ROOT)
    if xmlFile == nil then return false, "CREATE" end
    local root = GR.PAYLOAD_ROOT
    xmlFile:setInt(root .. "#attemptId", attemptId)
    xmlFile:setInt(root .. "#count", #tokens)
    xmlFile:setString(root .. "#format", SGValues.FORMAT_TOKEN)
    for i, t in ipairs(tokens) do xmlFile:setString(string.format("%s.token(%d)#v", root, i - 1), t) end
    local saved = xmlFile:save()
    xmlFile:delete()
    if saved == false then return false, "SAVE" end
    return true
end

--- The completion field, in the payload now in the final directory.
function GR.writeMarker(path, attemptId)
    if XMLFile == nil or XMLFile.loadIfExists == nil then return false, "NO_XML" end
    local xmlFile = XMLFile.loadIfExists("stockGuardGround", path)
    if xmlFile == nil then return false, "PAYLOAD_NOT_IN_FINAL_DIRECTORY" end
    local root = GR.PAYLOAD_ROOT
    if xmlFile:getInt(root .. "#attemptId", nil) ~= attemptId then
        xmlFile:delete()
        return false, "PAYLOAD_ATTEMPT"
    end
    xmlFile:setInt(root .. "#completeAttemptId", attemptId)
    local saved = xmlFile:save()
    xmlFile:delete()
    if saved == false then return false, "SAVE" end
    return true
end

--- Read a payload: its attempt, its completion and its decoded tree, or nil and a reason.
function GR.readPayload(path)
    if XMLFile == nil or XMLFile.loadIfExists == nil then return nil, "NO_XML" end
    local xmlFile = XMLFile.loadIfExists("stockGuardGround", path)
    if xmlFile == nil then return nil, "PAYLOAD_MISSING" end
    local root = GR.PAYLOAD_ROOT
    local out = { attemptId = xmlFile:getInt(root .. "#attemptId", nil), completeAttemptId = xmlFile:getInt(root .. "#completeAttemptId", nil) }
    local count = xmlFile:getInt(root .. "#count", 0)
    local tokens = {}
    for i = 1, count do
        tokens[i] = xmlFile:getString(string.format("%s.token(%d)#v", root, i - 1), nil)
        if tokens[i] == nil then tokens = nil break end
    end
    xmlFile:delete()
    if tokens == nil then return nil, "PAYLOAD_TOKENS" end
    local tree, why = SGValues.decode(tokens)
    if why ~= nil then return nil, "PAYLOAD_DECODE:" .. tostring(why) end
    out.tree = tree
    return out
end

-- ---------------------------------------------------------
-- The participant (SG_NATIVE_MATERIAL_SAVE_V1)
-- ---------------------------------------------------------
function GR:beginAttempt(context)
    local identity, why = GR.currentIdentity(context.mission)
    self.attempt = { attemptId = context.attemptId, identity = identity, reason = why, written = false }
end

function GR:freezeAfterCareerXML(context)
    local a = self.attempt
    if a == nil or a.attemptId ~= context.attemptId then return { state = GR.UNAVAILABLE, reason = "NO_ATTEMPT" } end
    if a.identity == nil then return { state = GR.UNAVAILABLE, reason = a.reason } end
    local runs, whyRuns = GR.encodeCells(self.cells, self.properties)
    if runs == nil then return { state = GR.UNAVAILABLE, reason = "CELLS:" .. tostring(whyRuns) } end
    local tree = {
        payloadSchema = GR.PAYLOAD_SCHEMA, attemptId = a.attemptId, mapKey = a.identity.mapKey,
        layerDescriptor = a.identity.layerDescriptor, nativeHeightFile = a.identity.nativeHeightFile,
        boundary = GR.BOUNDARY, properties = copy(self.properties), runs = runs,
    }
    local tokens, whyEnc = SGValues.encode(tree)
    if tokens == nil then return { state = GR.UNAVAILABLE, reason = "PAYLOAD_ENCODE:" .. tostring(whyEnc) } end
    local dir = context.careerSave ~= nil and context.careerSave.savegameDirectory or context.stagingDirectory
    if not nonempty(dir, 1024) then return { state = GR.UNAVAILABLE, reason = "NO_STAGING_DIRECTORY" } end
    local ok, whyWrite = GR.writePayload(dir .. "/" .. GR.PAYLOAD_FILE, a.attemptId, tokens)
    if not ok then return { state = GR.UNAVAILABLE, reason = "PAYLOAD_WRITE:" .. tostring(whyWrite) } end
    a.written = true
    a.runs = #runs
    return { state = GR.READY, payloadFile = GR.PAYLOAD_FILE, images = { { mapId = a.identity.heightId, nativeFilename = a.identity.nativeHeightFile } } }
end

function GR:finishAttempt(context, errorCode, finalSavegameDirectory)
    local a = self.attempt
    if a == nil or a.attemptId ~= context.attemptId then return end
    self.attempt = nil
    local r = context.results ~= nil and context.results[GR.PARTICIPANT_ID] or nil
    local ok = Savegame ~= nil and Savegame.ERROR_OK ~= nil and errorCode == Savegame.ERROR_OK
    local reason = nil
    if not ok then reason = "SAVE_FAILED:" .. tostring(errorCode)
    elseif not nonempty(finalSavegameDirectory, 1024) then reason = "NO_FINAL_DIRECTORY"
    elseif r == nil or r.state ~= GR.READY then reason = "NOT_READY:" .. tostring(r and r.reason)
    elseif not a.written then reason = "NOT_WRITTEN" end
    if reason ~= nil then
        self.lastMarker = { attemptId = a.attemptId, written = false, reason = reason }
        log("attempt " .. tostring(a.attemptId) .. ": no completion marker (" .. reason .. "); the ground image of this save is unavailable on load")
        return
    end
    local written, why = GR.writeMarker(finalSavegameDirectory .. "/" .. GR.PAYLOAD_FILE, a.attemptId)
    self.lastMarker = { attemptId = a.attemptId, written = written, reason = why }
    if not written then log("attempt " .. tostring(a.attemptId) .. ": completion marker failed (" .. tostring(why) .. "); the ground image of this save is unavailable on load") end
end

-- ---------------------------------------------------------
-- The SG-1 save section "sg2Ground"
-- ---------------------------------------------------------
--- extensions.sg2Ground for the open attempt. Outside a native save attempt there is
--- no height image to couple to, and the descriptor says so.
function GR:descriptor()
    local a = self.attempt
    if a == nil or a.identity == nil then return { schema = GR.SECTION_SCHEMA, state = "NO_ATTEMPT" } end
    return {
        schema = GR.SECTION_SCHEMA, attemptId = a.attemptId, mapKey = a.identity.mapKey,
        layerDescriptor = a.identity.layerDescriptor, nativeHeightFile = a.identity.nativeHeightFile,
        groundPayloadFile = GR.PAYLOAD_FILE, payloadSchema = GR.PAYLOAD_SCHEMA, boundary = GR.BOUNDARY,
    }
end

local function unavailable(reason) return { state = GR.UNAVAILABLE, reason = reason } end

--- Stage a saved descriptor against the current map and its payload. Never nil: an
--- unusable ground image is an UNAVAILABLE candidate, not a refused section.
function GR:stage(d, context)
    if type(d) ~= "table" or d.schema ~= GR.SECTION_SCHEMA then return unavailable("DESCRIPTOR_SCHEMA") end
    if d.state == "NO_ATTEMPT" then return unavailable("SAVED_OUTSIDE_NATIVE_SAVE") end
    if not isInteger(d.attemptId) or not nonempty(d.mapKey, 256) or not nonempty(d.layerDescriptor) or not nonempty(d.nativeHeightFile, 256) then return unavailable("DESCRIPTOR_FIELDS") end
    if d.boundary ~= GR.BOUNDARY or d.payloadSchema ~= GR.PAYLOAD_SCHEMA or d.groundPayloadFile ~= GR.PAYLOAD_FILE then return unavailable("DESCRIPTOR_PROFILE") end
    if type(context) ~= "table" or context.saveAttemptId ~= d.attemptId then return unavailable("ATTEMPT_MISMATCH") end
    local mission = g_currentMission
    local identity, why = GR.currentIdentity(mission)
    if identity == nil then return unavailable(why) end
    if identity.mapKey ~= d.mapKey then return unavailable("MAP_CHANGED") end
    if identity.nativeHeightFile ~= d.nativeHeightFile then return unavailable("HEIGHT_FILE_CHANGED") end
    if identity.layerDescriptor ~= d.layerDescriptor then return unavailable("LAYER_INCOMPATIBLE") end
    local dir = mission.missionInfo ~= nil and mission.missionInfo.savegameDirectory or nil
    if not nonempty(dir, 1024) then return unavailable("NO_SAVEGAME_DIRECTORY") end
    local p, whyRead = GR.readPayload(dir .. "/" .. d.groundPayloadFile)
    if p == nil then return unavailable(whyRead) end
    if p.attemptId ~= d.attemptId then return unavailable("PAYLOAD_ATTEMPT") end
    if p.completeAttemptId ~= d.attemptId then return unavailable("NOT_COMPLETE") end
    local t = p.tree
    if type(t) ~= "table" or t.payloadSchema ~= GR.PAYLOAD_SCHEMA or t.attemptId ~= d.attemptId or t.mapKey ~= d.mapKey
       or t.layerDescriptor ~= d.layerDescriptor or t.nativeHeightFile ~= d.nativeHeightFile or t.boundary ~= d.boundary then
        return unavailable("PAYLOAD_HEADER")
    end
    local properties = type(t.properties) == "table" and t.properties or {}
    for key, value in pairs(properties) do
        if not nonempty(key, 128) or not SGRecords.isPayloadTree(value) then return unavailable("PROPERTY:" .. tostring(key)) end
    end
    local cells, whyCells = GR.decodeRuns(t.runs or {}, properties)
    if cells == nil then return unavailable("CELLS:" .. tostring(whyCells)) end
    local n = 0
    for _ in pairs(cells) do n = n + 1 end
    return { state = GR.READY, cells = cells, properties = properties, attemptId = d.attemptId, cellCount = n }
end

function GR:commit(candidate)
    self.cells = candidate.cells or {}
    self.properties = candidate.properties or {}
    self.readiness = { state = candidate.state, reason = candidate.reason }
    if candidate.state == GR.READY then
        log(string.format("ground image of attempt %s restored: %d cell(s)", tostring(candidate.attemptId), candidate.cellCount or 0))
    else
        log("ground binding UNAVAILABLE (" .. tostring(candidate.reason) .. "); no saved ground history is used, other sections restore independently")
    end
end

function GR:clearReadiness(reason)
    self.cells = {}
    self.properties = {}
    self.readiness = { state = GR.UNAVAILABLE, reason = reason }
end

--- The ground binding's readiness: its committed state, else what SG-1's load said
--- about the section (no saved section is READY with nothing recorded).
function GR:getReadiness()
    if self.readiness ~= nil then return copy(self.readiness) end
    local save = self.host ~= nil and self.host.save or nil
    if save == nil or save.loadResult == nil then return { state = GR.PENDING, reason = "NOT_LOADED" } end
    local st = save.sectionState[GR.SECTION_ID]
    if st ~= nil and st.ready then return { state = GR.READY, reason = st.reason or "NO_SAVED_DATA" } end
    return { state = GR.UNAVAILABLE, reason = (st and st.reason) or save.loadResult.reason or "NOT_LOADED" }
end

-- ---------------------------------------------------------
-- Attach (server, at the native kernel install)
-- ---------------------------------------------------------
--- Register the section and the participant through the public handle, then make the
--- boundary live. Returns the ground, or nil and a reason.
function GR.attach(sgHost)
    if sgHost == nil or sgHost.handle == nil or sgHost.nativeSave == nil then return nil, "NO_HOST" end
    if sgHost.ground ~= nil then return sgHost.ground end
    local ground = GR.new(sgHost)
    local lease, whySection = sgHost.handle.registerSaveSection(GR.SECTION_ID, {
        schemaVersion = GR.SECTION_SCHEMA,
        farmRestorePolicy = "INVARIANT",
        serialize = function(_) return ground:descriptor() end,
        stageLoad = function(payload, context) return ground:stage(payload, context) end,
        commitLoad = function(candidate) ground:commit(candidate) end,
        clearReadiness = function(reason) ground:clearReadiness(reason) end,
    })
    if lease == nil then return nil, "SECTION:" .. tostring(whySection) end
    ground.sectionLease = lease
    ground.participant = {
        beginAttempt = function(context) ground:beginAttempt(context) end,
        freezeAfterCareerXML = function(context) return ground:freezeAfterCareerXML(context) end,
        finishAttempt = function(context, errorCode, finalSavegameDirectory) ground:finishAttempt(context, errorCode, finalSavegameDirectory) end,
    }
    local ok, whyParticipant = sgHost.handle.registerNativeSaveParticipant(GR.PARTICIPANT_ID, ground.participant)
    if not ok then return nil, "PARTICIPANT:" .. tostring(whyParticipant) end
    sgHost.ground = ground
    sgHost.nativeSave:activate()
    return ground
end
