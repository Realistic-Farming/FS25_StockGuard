-- =========================================================
-- FS25_StockGuard - the Combine buffer save extension (SG2-3c)
-- =========================================================
-- SG-2 :132 (its save half), :136-140 and :148. Native Combine:saveToXMLFile
-- (Combine.lua:275-282) saves isSwathActive, workedHectars and numAttachedCutters and
-- nothing of the loading delay slots or the straw input buffer, so a save made while
-- grain is in flight loses it: on load, loadCombineSetup builds every delay slot
-- invalid (:517-525) and the input buffer empty (:589-599), and SG-1's saved stock for
-- such a slot finds no carrier and retires as absent. This module persists the real
-- native buffer with the vehicle's own save data and restores it after native setup,
-- so the physical goods and StockGuard's binding to them survive the save together
-- (:138): the save data is the quantity-bearing native representation, and SG-1's
-- stock is never a second tank or an instruction to create goods.
--
-- WHERE IT HANGS. Vehicle:saveToXMLFile calls each specialization's saveToXMLFile
-- from the class table (Vehicle.lua:1210-1212), under "<vehicle>.<specName>", so
-- Combine.saveToXMLFile appended writes under the combine's own key. On load the
-- onPostLoad event is raised through the class table as well: Vehicle.lua:903-906
-- queues SpecializationUtil.raiseAsyncEvent(self, "onPostLoad", self.savegame) after
-- onLoad built the native buffers at :866, and raiseAsyncEvent (SpecializationUtil.lua
-- :2-16) reads each listener's onPostLoad from its class table when the task runs:
-- Combine.onPostLoad appended restores into them. Both are the class table read at
-- call time (mechanism 3), so the hooks reach every combine of every vehicle type.
--
-- WHERE THE PATHS LIVE. The vehicles file is created and loaded with
-- Vehicle.xmlSchemaSavegame (VehicleSystem.lua:293 and :324), and XMLFile:setValue on
-- a path that schema does not know sets nothing and logs "Path not registered"
-- (XMLFile.lua:181-186, :273-294; getValue answers nil). Vehicle.init rebuilds that
-- schema on every mission load (Vehicle.lua:249, MPLoadingScreen.lua:767), so the
-- element's paths are registered where native Combine registers its own three
-- (Combine.lua:81-84): Combine.initSpecialization, appended through the class table
-- when this file is sourced (MPLoadingScreen.lua:735) and called after Vehicle.init by
-- SpecializationManager:initSpecializations (SpecializationManager.lua:97-104,
-- MPLoadingScreen.lua:776) on every mission load.
--
-- WHAT IS SAVED (:140, :148). Delay slots: only valid ones, each with its index, its
-- actual fillLevelDelta, its canonical fill type name and its remaining delay,
-- max(0, slot.time + loadingDelay - mission.time), plus the slot count as the layout
-- and loadingDelaySlotsDelayedInsert. The straw input buffer: each slot's remaining
-- liters, inputLiters, area, strawRatio and effectDensity (only liters is stock; the
-- rest is native process state, :148), each slot's straw identity the drop reads at
-- :1347-1348 (strawHaulmFruitTypeIndex by fruit name, strawGroundType by its
-- FieldChopperType member; both set at :983-991), the layout (slotCount), the cursors (fillIndex,
-- dropIndex, slotTimer, activeTimer) and the output selector the drop reads
-- (:1326-1350 takes the fill unit's last valid type, which is UNKNOWN again after a
-- load with an empty hopper, FillUnit.lua:1311): the combine's lastValidInputFruitType
-- (:414, the only last-valid record the server keeps; lastValidInputFillType is set
-- from the stream alone, :187, :289, :317), by canonical fruit name.
--
-- WHAT RESTORE DOES AND DOES NOT (:140). slot.time is rebuilt from the new mission
-- clock and the saved remaining delay, so a zero remainder is due in the normal
-- update; load itself adds nothing to any fill unit and cuts nothing. An incompatible
-- layout (another delay slot count, no delay slots at all, a straw buffer of another
-- slot count) or a fill type name this game does not know leaves that saved buffer
-- UNRESOLVED, logged once: nothing is reallocated to another slot, no fill unit is
-- duplicated, and SG-1 then retires that carrier's stock as absent, exactly as it did
-- before this extension. A savegame flagged resetVehicles restores nothing, as native
-- restores no attachment then (:232). A client has no savegame and does nothing.
--
-- SALE OR DELETION (:136) is destruction: SGNativeHost withdraws a removed vehicle's
-- slot carriers on VehicleSystem.removeVehicle, next to its fill units.

SGCombineBufferSave = SGCombineBufferSave or {}
local B = SGCombineBufferSave

B.VERSION = 1
B.ELEMENT = "stockGuardBuffer"
B.MARKER = "_sgBufferSave"
B.stats = B.stats or { saved = 0, restored = 0, unresolved = 0 }
B.logged = B.logged or {}

local function log(msg) print("[StockGuard] buffer save: " .. tostring(msg)) end
local function logOnce(key, msg)
    if B.logged[key] then return end
    B.logged[key] = true
    log(msg)
end

local function isNumber(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function fillTypeName(index)
    local m = g_fillTypeManager
    if m == nil or not isNumber(index) or index <= 0 then return nil end
    local ok, name = pcall(m.getFillTypeNameByIndex, m, index)
    return ok and type(name) == "string" and name or nil
end
local function fillTypeIndex(name)
    local m = g_fillTypeManager
    if m == nil or type(name) ~= "string" then return nil end
    local ok, index = pcall(m.getFillTypeIndexByName, m, name)
    return ok and isNumber(index) and index > 0 and index or nil
end
local function fruitName(index)
    local m = g_fruitTypeManager
    if m == nil or not isNumber(index) or index <= 0 then return nil end
    local ok, desc = pcall(m.getFruitTypeByIndex, m, index)
    return ok and type(desc) == "table" and type(desc.name) == "string" and desc.name or nil
end
local function fruitIndex(name)
    local m = g_fruitTypeManager
    if m == nil or type(name) ~= "string" then return nil end
    local ok, index = pcall(m.getFruitTypeIndexByName, m, name)
    return ok and isNumber(index) and index > 0 and index or nil
end

--- The FieldChopperType member whose ground value this is, or nil. The value is the
--- mission's field ground system's (FieldChopperType.lua:5-7), so the member name is
--- what a save can carry across games.
local function chopperTypeName(value)
    if not isNumber(value) or type(FieldChopperType) ~= "table" or type(FieldChopperType.getValueByType) ~= "function" then return nil end
    for name, member in pairs(FieldChopperType) do
        if type(name) == "string" and isNumber(member) then
            local ok, v = pcall(FieldChopperType.getValueByType, member)
            if ok and v == value then return name end
        end
    end
    return nil
end
local function chopperTypeValue(name)
    if type(name) ~= "string" or type(FieldChopperType) ~= "table" or type(FieldChopperType.getValueByType) ~= "function" then return nil end
    local member = FieldChopperType[name]
    if not isNumber(member) then return nil end
    local ok, v = pcall(FieldChopperType.getValueByType, member)
    return ok and isNumber(v) and v or nil
end

local function now()
    local t = g_currentMission ~= nil and g_currentMission.time or nil
    return isNumber(t) and t or 0
end

--- The name the vehicle's save uses for its Combine specialization (Vehicle.lua:1212).
local function specNameOf(vehicle, combineClass)
    local specs, names = vehicle.specializations, vehicle.specializationNames
    if type(specs) == "table" and type(names) == "table" then
        for k, spec in pairs(specs) do
            if spec == combineClass then return names[k] end
        end
    end
    return "combine"
end

-- ---------------------------------------------------------
-- Collect and restore (pure, on the native tables)
-- ---------------------------------------------------------
--- What a save writes for this combine, or nil when no buffer is live.
function B.collect(vehicle, time)
    local spec = type(vehicle) == "table" and vehicle.spec_combine or nil
    if spec == nil then return nil end
    local out = { version = B.VERSION, delaySlots = {}, straw = nil }
    local slots = spec.loadingDelaySlots
    if type(slots) == "table" then
        out.slotCount = #slots
        out.delayedInsert = spec.loadingDelaySlotsDelayedInsert == true
        for i, slot in ipairs(slots) do
            if slot.valid == true and isNumber(slot.fillLevelDelta) and slot.fillLevelDelta > 0 then
                local remaining = math.max(0, (isNumber(slot.time) and slot.time or 0) + (isNumber(spec.loadingDelay) and spec.loadingDelay or 0) - time)
                out.delaySlots[#out.delaySlots + 1] = { index = i, fillLevelDelta = slot.fillLevelDelta,
                    fillTypeName = fillTypeName(slot.fillType), remainingDelay = remaining }
            end
        end
    end
    local ib = type(spec.processing) == "table" and spec.processing.inputBuffer or nil
    if type(ib) == "table" and type(ib.buffer) == "table" then
        local live = {}
        for i, s in ipairs(ib.buffer) do
            if (isNumber(s.liters) and s.liters > 0) or (isNumber(s.inputLiters) and s.inputLiters > 0) or (isNumber(s.area) and s.area > 0) then
                live[#live + 1] = { index = i, liters = s.liters or 0, inputLiters = s.inputLiters or 0, area = s.area or 0,
                    strawRatio = s.strawRatio or 0, effectDensity = s.effectDensity or 0,
                    haulmFruit = fruitName(s.strawHaulmFruitTypeIndex), groundType = chopperTypeName(s.strawGroundType) }
            end
        end
        if #live > 0 then
            out.straw = { slotCount = #ib.buffer, fillIndex = ib.fillIndex, dropIndex = ib.dropIndex, slotTimer = ib.slotTimer, activeTimer = ib.activeTimer,
                slots = live, fruitTypeName = fruitName(spec.lastValidInputFruitType) }
        end
    end
    if #out.delaySlots == 0 and out.straw == nil then return nil end
    return out
end

function B.write(xmlFile, base, data)
    xmlFile:setValue(base .. "#version", data.version)
    if data.slotCount ~= nil then
        xmlFile:setValue(base .. "#slotCount", data.slotCount)
        xmlFile:setValue(base .. "#delayedInsert", data.delayedInsert == true)
    end
    for n, s in ipairs(data.delaySlots) do
        local k = string.format("%s.delaySlot(%d)", base, n - 1)
        xmlFile:setValue(k .. "#index", s.index)
        xmlFile:setValue(k .. "#fillLevelDelta", s.fillLevelDelta)
        if s.fillTypeName ~= nil then xmlFile:setValue(k .. "#fillType", s.fillTypeName) end
        xmlFile:setValue(k .. "#remainingDelay", s.remainingDelay)
    end
    local st = data.straw
    if st ~= nil then
        local k = base .. ".straw"
        xmlFile:setValue(k .. "#slotCount", st.slotCount)
        xmlFile:setValue(k .. "#fillIndex", st.fillIndex)
        xmlFile:setValue(k .. "#dropIndex", st.dropIndex)
        xmlFile:setValue(k .. "#slotTimer", st.slotTimer)
        xmlFile:setValue(k .. "#activeTimer", st.activeTimer)
        if st.fruitTypeName ~= nil then xmlFile:setValue(k .. "#fruitType", st.fruitTypeName) end
        for n, s in ipairs(st.slots) do
            local sk = string.format("%s.slot(%d)", k, n - 1)
            xmlFile:setValue(sk .. "#index", s.index)
            xmlFile:setValue(sk .. "#liters", s.liters)
            xmlFile:setValue(sk .. "#inputLiters", s.inputLiters)
            xmlFile:setValue(sk .. "#area", s.area)
            xmlFile:setValue(sk .. "#strawRatio", s.strawRatio)
            xmlFile:setValue(sk .. "#effectDensity", s.effectDensity)
            if s.haulmFruit ~= nil then xmlFile:setValue(sk .. "#haulmFruit", s.haulmFruit) end
            if s.groundType ~= nil then xmlFile:setValue(sk .. "#groundType", s.groundType) end
        end
    end
end

--- The saved buffer under `base`, or nil when the save carries none.
function B.read(xmlFile, base)
    if xmlFile == nil or not xmlFile:hasProperty(base) then return nil end
    local data = { version = xmlFile:getValue(base .. "#version"), slotCount = xmlFile:getValue(base .. "#slotCount"),
                   delayedInsert = xmlFile:getValue(base .. "#delayedInsert", false), delaySlots = {} }
    local n = 0
    while true do
        local k = string.format("%s.delaySlot(%d)", base, n)
        if not xmlFile:hasProperty(k) then break end
        data.delaySlots[#data.delaySlots + 1] = { index = xmlFile:getValue(k .. "#index"), fillLevelDelta = xmlFile:getValue(k .. "#fillLevelDelta"),
            fillTypeName = xmlFile:getValue(k .. "#fillType"), remainingDelay = xmlFile:getValue(k .. "#remainingDelay") }
        n = n + 1
    end
    local k = base .. ".straw"
    if xmlFile:hasProperty(k) then
        data.straw = { slotCount = xmlFile:getValue(k .. "#slotCount"), fillIndex = xmlFile:getValue(k .. "#fillIndex"), dropIndex = xmlFile:getValue(k .. "#dropIndex"),
            slotTimer = xmlFile:getValue(k .. "#slotTimer"), activeTimer = xmlFile:getValue(k .. "#activeTimer"),
            fruitTypeName = xmlFile:getValue(k .. "#fruitType"), slots = {} }
        local m = 0
        while true do
            local sk = string.format("%s.slot(%d)", k, m)
            if not xmlFile:hasProperty(sk) then break end
            data.straw.slots[#data.straw.slots + 1] = { index = xmlFile:getValue(sk .. "#index"), liters = xmlFile:getValue(sk .. "#liters"),
                inputLiters = xmlFile:getValue(sk .. "#inputLiters"), area = xmlFile:getValue(sk .. "#area"),
                strawRatio = xmlFile:getValue(sk .. "#strawRatio"), effectDensity = xmlFile:getValue(sk .. "#effectDensity"),
                haulmFruit = xmlFile:getValue(sk .. "#haulmFruit"), groundType = xmlFile:getValue(sk .. "#groundType") }
            m = m + 1
        end
    end
    return data
end

--- Restore the saved buffer into the native tables the load just built. Returns the
--- number of slots restored and the list of unresolved parts (each a reason).
function B.restore(vehicle, data, time)
    local spec = type(vehicle) == "table" and vehicle.spec_combine or nil
    local restored, unresolved = 0, {}
    if spec == nil or type(data) ~= "table" then return 0, { "NO_COMBINE" } end
    if data.version ~= B.VERSION then return 0, { "VERSION" } end
    if #data.delaySlots > 0 then
        local slots = spec.loadingDelaySlots
        if type(slots) ~= "table" or #slots ~= data.slotCount then
            unresolved[#unresolved + 1] = "SLOT_LAYOUT"
        else
            local any = false
            for _, s in ipairs(data.delaySlots) do
                local slot = isNumber(s.index) and slots[s.index] or nil
                local ft = fillTypeIndex(s.fillTypeName)
                if slot == nil then
                    unresolved[#unresolved + 1] = "SLOT_INDEX"
                elseif ft == nil then
                    unresolved[#unresolved + 1] = "FILL_TYPE"
                elseif slot.valid == true then
                    unresolved[#unresolved + 1] = "SLOT_OCCUPIED"
                elseif not isNumber(s.fillLevelDelta) or s.fillLevelDelta <= 0 or not isNumber(s.remainingDelay) then
                    unresolved[#unresolved + 1] = "SLOT_VALUES"
                else
                    slot.valid = true
                    slot.fillLevelDelta = s.fillLevelDelta
                    slot.fillType = ft
                    -- Due when slot.time + loadingDelay < mission.time (Combine.lua:468).
                    slot.time = time + math.max(0, s.remainingDelay) - (isNumber(spec.loadingDelay) and spec.loadingDelay or 0)
                    restored, any = restored + 1, true
                end
            end
            if any then spec.loadingDelaySlotsDelayedInsert = data.delayedInsert == true end
        end
    end
    local st = data.straw
    if st ~= nil then
        local ib = type(spec.processing) == "table" and spec.processing.inputBuffer or nil
        if type(ib) ~= "table" or type(ib.buffer) ~= "table" or #ib.buffer ~= st.slotCount then
            unresolved[#unresolved + 1] = "STRAW_LAYOUT"
        elseif not (isNumber(st.fillIndex) and st.fillIndex >= 1 and st.fillIndex <= st.slotCount and isNumber(st.dropIndex) and st.dropIndex >= 1 and st.dropIndex <= st.slotCount) then
            unresolved[#unresolved + 1] = "STRAW_CURSORS"
        else
            for _, s in ipairs(st.slots) do
                local slot = isNumber(s.index) and ib.buffer[s.index] or nil
                local haulm, ground = fruitIndex(s.haulmFruit), chopperTypeValue(s.groundType)
                if slot == nil then
                    unresolved[#unresolved + 1] = "STRAW_INDEX"
                elseif (s.haulmFruit ~= nil and haulm == nil) or (s.groundType ~= nil and ground == nil) then
                    -- A straw identity this game does not know: that slot stays unresolved (:148).
                    unresolved[#unresolved + 1] = "STRAW_SELECTOR"
                else
                    slot.strawHaulmFruitTypeIndex, slot.strawGroundType = haulm, ground
                    slot.liters = isNumber(s.liters) and s.liters or 0
                    slot.inputLiters = isNumber(s.inputLiters) and s.inputLiters or 0
                    slot.area = isNumber(s.area) and s.area or 0
                    slot.strawRatio = isNumber(s.strawRatio) and s.strawRatio or 0
                    slot.effectDensity = isNumber(s.effectDensity) and s.effectDensity or slot.effectDensity
                    restored = restored + 1
                end
            end
            ib.fillIndex, ib.dropIndex = st.fillIndex, st.dropIndex
            if isNumber(st.slotTimer) then ib.slotTimer = st.slotTimer end
            if isNumber(st.activeTimer) then ib.activeTimer = st.activeTimer end
            -- The output selector: which fruit's straw the buffer holds (:148).
            local fruit = fruitIndex(st.fruitTypeName)
            if fruit ~= nil then spec.lastValidInputFruitType = fruit end
            if st.fruitTypeName ~= nil and fruit == nil then unresolved[#unresolved + 1] = "OUTPUT_SELECTOR" end
        end
    end
    return restored, unresolved
end

-- ---------------------------------------------------------
-- The hooks
-- ---------------------------------------------------------
--- Appended to Combine.saveToXMLFile (Vehicle.lua:1212 hands it "<vehicle>.combine").
function B.onSave(vehicle, xmlFile, key)
    if g_server == nil or type(key) ~= "string" or xmlFile == nil then return end
    local ok, data = pcall(B.collect, vehicle, now())
    if not ok then log("collect failed (" .. tostring(data) .. "); nothing written") return end
    if data == nil then return end
    local okW, err = pcall(B.write, xmlFile, key .. "." .. B.ELEMENT, data)
    if not okW then log("write failed (" .. tostring(err) .. ")") return end
    B.stats.saved = B.stats.saved + 1
end

--- Appended to Combine.onPostLoad (queued at Vehicle.lua:903-906 through
--- raiseAsyncEvent with the savegame, nil for a vehicle that was not loaded from one).
function B.onPostLoad(vehicle, savegame, combineClass)
    if g_server == nil or type(savegame) ~= "table" or savegame.xmlFile == nil or type(savegame.key) ~= "string" then return end
    if savegame.resetVehicles then return end
    local base = savegame.key .. "." .. specNameOf(vehicle, combineClass) .. "." .. B.ELEMENT
    local ok, data = pcall(B.read, savegame.xmlFile, base)
    if not ok then log("read failed (" .. tostring(data) .. "); nothing restored") return end
    if data == nil then return end
    local okR, restored, unresolved = pcall(B.restore, vehicle, data, now())
    if not okR then log("restore failed (" .. tostring(restored) .. ")") return end
    local spec = vehicle.spec_combine
    if spec ~= nil then spec.sgBufferRestore = { restored = restored, unresolved = unresolved } end
    B.stats.restored = B.stats.restored + restored
    if #unresolved > 0 then
        B.stats.unresolved = B.stats.unresolved + #unresolved
        logOnce("unresolved:" .. table.concat(unresolved, ","), string.format("a saved combine buffer could not be restored (%s) on %s; it is left unresolved, nothing reallocated. Logged once per reason set.",
            table.concat(unresolved, ","), tostring(vehicle.configFileName)))
    elseif restored > 0 then
        logOnce("restored", string.format("FIRST COMBINE BUFFER RESTORED: %d slot(s) of in-flight grain or straw survived the save on %s.", restored, tostring(vehicle.configFileName)))
    end
end

--- Install on the Combine class table once (mechanism 3, read at call time).
function B.installClassHooks(classes)
    local Combine = type(classes) == "table" and classes.Combine or nil
    if type(Combine) ~= "table" or type(Combine.saveToXMLFile) ~= "function" or type(Combine.onPostLoad) ~= "function" then return false end
    if rawget(Combine, B.MARKER) ~= nil then return false end
    local originalSave, originalPostLoad = Combine.saveToXMLFile, Combine.onPostLoad
    Combine.saveToXMLFile = function(self, xmlFile, key, ...)
        local packn = function(...) return select("#", ...), { ... } end
        local n, r = packn(originalSave(self, xmlFile, key, ...))
        local ok, err = pcall(B.onSave, self, xmlFile, key)
        if not ok then log("save hook failed (" .. tostring(err) .. ")") end
        return unpack(r, 1, n)
    end
    Combine.onPostLoad = function(self, savegame, ...)
        local packn = function(...) return select("#", ...), { ... } end
        local n, r = packn(originalPostLoad(self, savegame, ...))
        local ok, err = pcall(B.onPostLoad, self, savegame, Combine)
        if not ok then log("post-load hook failed (" .. tostring(err) .. ")") end
        return unpack(r, 1, n)
    end
    rawset(Combine, B.MARKER, { saveToXMLFile = originalSave, onPostLoad = originalPostLoad })
    return true
end

-- ---------------------------------------------------------
-- The savegame schema
-- ---------------------------------------------------------
B.SAVEGAME_BASE = "vehicles.vehicle(?).combine." .. B.ELEMENT

--- Register the element's paths, each with its real type, on a savegame schema.
--- Vehicle.init builds a fresh schema on every mission load (Vehicle.lua:249), so
--- this runs once per schema, never once per process.
function B.registerSavegamePaths(schema)
    if type(schema) ~= "table" or type(schema.register) ~= "function" or type(XMLValueType) ~= "table" then return false end
    if rawget(schema, B.MARKER) ~= nil then return false end
    rawset(schema, B.MARKER, true)
    local base, T = B.SAVEGAME_BASE, XMLValueType
    schema:register(T.INT, base .. "#version", "StockGuard buffer save version")
    schema:register(T.INT, base .. "#slotCount", "Loading delay slot count (the layout)")
    schema:register(T.BOOL, base .. "#delayedInsert", "loadingDelaySlotsDelayedInsert")
    local d = base .. ".delaySlot(?)"
    schema:register(T.INT, d .. "#index", "Delay slot index")
    schema:register(T.FLOAT, d .. "#fillLevelDelta", "Delay slot fill level delta")
    schema:register(T.STRING, d .. "#fillType", "Delay slot fill type name")
    schema:register(T.FLOAT, d .. "#remainingDelay", "Remaining delay in ms")
    local s = base .. ".straw"
    schema:register(T.INT, s .. "#slotCount", "Straw input buffer slot count (the layout)")
    schema:register(T.INT, s .. "#fillIndex", "Straw input buffer fill cursor")
    schema:register(T.INT, s .. "#dropIndex", "Straw input buffer drop cursor")
    schema:register(T.FLOAT, s .. "#slotTimer", "Straw input buffer slot timer")
    schema:register(T.FLOAT, s .. "#activeTimer", "Straw input buffer active timer")
    schema:register(T.STRING, s .. "#fruitType", "Last valid input fruit type name")
    local ss = s .. ".slot(?)"
    schema:register(T.INT, ss .. "#index", "Straw slot index")
    schema:register(T.FLOAT, ss .. "#liters", "Straw slot liters")
    schema:register(T.FLOAT, ss .. "#inputLiters", "Straw slot input liters")
    schema:register(T.FLOAT, ss .. "#area", "Straw slot area")
    schema:register(T.FLOAT, ss .. "#strawRatio", "Straw slot straw ratio")
    schema:register(T.FLOAT, ss .. "#effectDensity", "Straw slot effect density")
    schema:register(T.STRING, ss .. "#haulmFruit", "Straw slot haulm fruit type name")
    schema:register(T.STRING, ss .. "#groundType", "Straw slot ground type (FieldChopperType member)")
    return true
end

--- Append Combine.initSpecialization through the class table, once per process: the
--- call SpecializationManager:initSpecializations makes after Vehicle.init on every
--- mission load (SpecializationManager.lua:97-104; MPLoadingScreen.lua:767 and :776),
--- where native Combine registers its own savegame paths (Combine.lua:81-84). The
--- schema is read from the Vehicle class when the call comes, so it is that load's.
function B.installSchemaHook(combineClass, vehicleClass)
    if type(combineClass) ~= "table" or type(combineClass.initSpecialization) ~= "function" then return false end
    if rawget(combineClass, B.MARKER .. "Schema") ~= nil then return false end
    local original = combineClass.initSpecialization
    combineClass.initSpecialization = function(...)
        local packn = function(...) return select("#", ...), { ... } end
        local n, r = packn(original(...))
        local ok, err = pcall(B.registerSavegamePaths, type(vehicleClass) == "table" and vehicleClass.xmlSchemaSavegame or nil)
        if not ok then log("schema registration failed (" .. tostring(err) .. ")") end
        return unpack(r, 1, n)
    end
    rawset(combineClass, B.MARKER .. "Schema", original)
    return true
end

-- Installed when this file is sourced: MPLoadingScreen.lua:735 sources a mod before
-- Vehicle.init at :767 and initSpecializations at :776, so the first mission's schema
-- carries the paths too; the class-table marker keeps a re-source from wrapping twice.
if type(Combine) == "table" and type(Vehicle) == "table" then B.installSchemaHook(Combine, Vehicle) end
