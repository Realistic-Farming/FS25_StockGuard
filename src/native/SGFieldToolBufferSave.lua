-- =========================================================
-- FS25_StockGuard - the Tedder and Mower buffer save (SG2-5bc-save)
-- =========================================================
-- SG-2 :144 and :247, with :136, :138 and :364. A Tedder work area keeps what its passes
-- picked up and did not drop in workArea.litersToDrop (Tedder.lua:296-304), and a Mower
-- drop area keeps its cut output in dropArea.litersToDrop as dropArea.fillType
-- (Mower.lua:358-367). Native saves neither: neither specialization defines saveToXMLFile,
-- and each loadWorkAreaFromXML zeroes the buffer at load (Tedder.lua:242, Mower.lua:482).
-- So a save made with a remainder lost it, and SG-1's saved stock for that buffer (the
-- tedderBuffer and mowerBuffer kinds, SGNativeAdapters) stayed history. This module
-- persists the real native remainder with the vehicle's own save data and restores it
-- after native work-area setup, with StockGuard's buffer entry, so the goods and SG-1's
-- binding to them survive the save together (:138: the save data is the quantity-bearing
-- native representation, never a second tank or an instruction to create goods).
--
-- WHERE IT HANGS: SGCombineBufferSave's save and load places (its header cites the engine
-- lines), for two more class tables. Vehicle:saveToXMLFile calls each specialization's
-- saveToXMLFile from the class table under "<vehicle>.<specName>" (Vehicle.lua:1210-1214):
-- Tedder and Mower define none, so this module defines one on each, calling one another mod
-- put there first. onPostLoad is raised through the class table after onLoad built the work
-- areas (Vehicle.lua:903-906; SpecializationUtil.lua:2-16), and both register it
-- (Tedder.lua:33, Mower.lua:50): Tedder.onPostLoad and Mower.onPostLoad appended restore.
-- The class hooks install at each mission's native kernel install (SGNativeHost), on that map
-- load's class tables. Neither class registers a savegame path, so the paths are registered on
-- Vehicle.xmlSchemaSavegame from an append on Vehicle.init, on every map load (below, "WHEN THE
-- PATHS ARE REGISTERED"; Bob's addendum to the 5bc-save intake).
--
-- WHAT IS SAVED. A "stockGuardBuffer" element under the spec key, written only when a buffer
-- holds litres, with the layout: the version, the vehicle's configFileName and the count of
-- the kind's native areas (the Tedder's TEDDER work areas, Tedder.lua:238-251; the Mower's
-- spec_mower.dropAreas, Mower.lua:488-494). Then one child per area with a live remainder:
--   Tedder (:144): the work-area index, litersToDrop, lastDropFillType by canonical name, the
--     drop binding dropWindrowWorkAreaIndex and that drop area's lineOffset (:351-358), and
--     the StockGuard entry's material (the tedder kind's material is the entry's
--     fillTypeName, never native's, SGNativeAdapters tedderBufferKind).
--   Mower (:144; :247 "litersToDrop/fillType/workArea binding/dropLineOffset"): the drop-area
--     index, litersToDrop, fillType by canonical name, the cut work area that fed it
--     (dropArea.workAreaIndex, :360), dropLineOffset (:398), and the StockGuard entry's fresh
--     litres and soilFramed: "the original work's snapshot follows the buffer until actual
--     deposition" (:144; Bob's 5bc-save intake, section 4). Soil makes the fresh share's
--     birth at the deposit from the birth kind and the drop's fill type alone
--     (GroundConditionAdmission.birthPart), so the entry is all the drop needs.
-- The Tedder entry's pending is zero between frames, and a save runs between frames: the
-- career XML chain is one synchronous call (SGNativeMaterialSave's header).
--
-- WHAT RESTORE DOES AND DOES NOT (:144 "validate the mapping and do not use display/array
-- order alone when the vehicle configuration changed"). The configFileName and the area
-- count must be the saved ones, and each saved index must name an area of the kind with the
-- saved binding: a TEDDER work area whose dropWindrowWorkAreaIndex is the saved one; a drop
-- area in spec_mower.dropAreas, and its saved cut area a MOWER work area whose dropAreaIndex
-- names it. Then the native fields are set back, and the StockGuard entry is seeded with the
-- saved StockGuard fields (SGGroundObserver.seedTedderBuffer, seedMowerBuffer), so SG-1's
-- restore at the barrier resolves the carrier through it and reattaches the saved stock on
-- equal material and the float image of the amount (SGNativeAdapters restoredQuantityImage).
-- Load itself puts nothing on the ground. Anything else (another configuration or layout, an
-- unknown index or binding, a fill type name this game does not know, bad values) leaves
-- that buffer UNRESOLVED, logged once: nothing is set, nothing is seeded, and SG-1 keeps the
-- saved stock as history, as it did before this extension. A remainder saved without a
-- StockGuard entry (StockGuard never bound it) restores natively and seeds nothing: the next
-- frame binds over it as litres native already held. A savegame flagged resetVehicles
-- restores nothing (a vehicle reset reloads that way, Vehicle.lua:1175). A client has no
-- savegame and does nothing.
--
-- SALE OR DELETION (:136) stays destruction: SGNativeHost retires a removed vehicle's live
-- buffers through a REMOVE (SGGroundObserver.retireTedderBuffers, retireMowerBuffers).
--
-- A KIND IS ONE DESCRIPTOR in F.KINDS (its class name, spec table, collect, write, read,
-- restore and schema paths, and the load event its restore follows: onPostLoad unless it names
-- another); the hooks and the schema install are generic over it, so a later buffer save adds a
-- descriptor. The Baler overflow (SG2-5e-a) and the ForageWagon (SG2-5f, after onLoad) did.

SGFieldToolBufferSave = SGFieldToolBufferSave or {}
local F = SGFieldToolBufferSave

F.VERSION = 1
F.ELEMENT = "stockGuardBuffer"
F.MARKER = "_sgFieldToolBufferSave"
F.stats = F.stats or { saved = 0, restored = 0, seeded = 0, unresolved = 0 }
F.logged = F.logged or {}

local function packn(...) return select("#", ...), { ... } end

local function log(msg) print("[StockGuard] field tool buffer save: " .. tostring(msg)) end
local function logOnce(key, msg)
    if F.logged[key] then return end
    F.logged[key] = true
    log(msg)
end

local function isNumber(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

--- The canonical name of a fill type index (FillTypeManager), nil for none or UNKNOWN.
local function fillTypeName(index)
    local m = g_fillTypeManager
    if m == nil or not isNumber(index) or index <= 0 or (FillType ~= nil and index == FillType.UNKNOWN) then return nil end
    local ok, name = pcall(m.getFillTypeNameByIndex, m, index)
    return ok and type(name) == "string" and name ~= "" and name or nil
end
local function fillTypeIndex(name)
    local m = g_fillTypeManager
    if m == nil or type(name) ~= "string" then return nil end
    local ok, index = pcall(m.getFillTypeIndexByName, m, name)
    return ok and isNumber(index) and index > 0 and index or nil
end

local function configOf(vehicle) return type(vehicle.configFileName) == "string" and vehicle.configFileName or "" end
local function workAreasOf(vehicle)
    local spec = vehicle.spec_workArea
    return type(spec) == "table" and type(spec.workAreas) == "table" and spec.workAreas or {}
end

--- The name the vehicle's save uses for this kind's specialization (Vehicle.lua:1212).
local function specNameOf(vehicle, class, default)
    local specs, names = vehicle.specializations, vehicle.specializationNames
    if type(specs) == "table" and type(names) == "table" then
        for k, spec in pairs(specs) do
            if spec == class then return names[k] end
        end
    end
    return default
end

--- The StockGuard buffer entry of one area, when it is this vehicle's and this area's.
local function entryOf(entries, binding, vehicle, field, area)
    if binding == nil or type(entries) ~= "table" then return nil end
    local e = entries[SGRecords.carrierKeyString(binding.carrierKey)]
    if e ~= nil and e.vehicle == vehicle and e[field] == area then return e end
    return nil
end

-- The layout every kind writes first, and its check.
local function writeLayout(xmlFile, base, data)
    xmlFile:setValue(base .. "#version", data.version)
    xmlFile:setValue(base .. "#configFileName", data.configFileName)
    xmlFile:setValue(base .. "#areaCount", data.areaCount)
end
local function readLayout(xmlFile, base)
    return { version = xmlFile:getValue(base .. "#version"), configFileName = xmlFile:getValue(base .. "#configFileName"),
             areaCount = xmlFile:getValue(base .. "#areaCount"), buffers = {} }
end
local function layoutRefusal(vehicle, data, count)
    if data.version ~= F.VERSION then return "VERSION" end
    if data.configFileName ~= configOf(vehicle) then return "CONFIGURATION" end
    if data.areaCount ~= count then return "AREA_LAYOUT" end
    return nil
end
local function registerLayout(schema, base, T)
    schema:register(T.INT, base .. "#version", "StockGuard buffer save version")
    schema:register(T.STRING, base .. "#configFileName", "The vehicle's configuration file (the layout)")
    schema:register(T.INT, base .. "#areaCount", "The count of the specialization's buffer areas (the layout)")
end

F.KINDS = {}

-- ---------------------------------------------------------
-- The Tedder: one buffer per TEDDER work area
-- ---------------------------------------------------------
local TEDDER = { name = "tedder", className = "Tedder", specTable = "spec_tedder" }
F.KINDS[#F.KINDS + 1] = TEDDER

--- A work area Tedder:loadWorkAreaFromXML built as a TEDDER area (Tedder.lua:238-251).
local function isTedderArea(wa)
    return type(wa) == "table" and WorkAreaType ~= nil and WorkAreaType.TEDDER ~= nil and wa.type == WorkAreaType.TEDDER
end
local function tedderAreas(vehicle)
    local out = {}
    for _, wa in ipairs(workAreasOf(vehicle)) do if isTedderArea(wa) then out[#out + 1] = wa end end
    return out
end

function TEDDER.collect(vehicle)
    local A = SGNativeAdapters
    local areas, list = workAreasOf(vehicle), tedderAreas(vehicle)
    local out = { version = F.VERSION, configFileName = configOf(vehicle), areaCount = #list, buffers = {} }
    for _, wa in ipairs(list) do
        local held = wa.litersToDrop
        if isNumber(held) and held > 0 and isNumber(wa.index) then
            local entry = A ~= nil and entryOf(A.tedderBuffers, A.tedderBufferBinding(vehicle, wa.index), vehicle, "workArea", wa) or nil
            local drop = isNumber(wa.dropWindrowWorkAreaIndex) and areas[wa.dropWindrowWorkAreaIndex] or nil
            out.buffers[#out.buffers + 1] = { index = wa.index, litersToDrop = held, lastDropFillType = fillTypeName(wa.lastDropFillType),
                dropIndex = wa.dropWindrowWorkAreaIndex, lineOffset = drop ~= nil and isNumber(drop.lineOffset) and drop.lineOffset or nil,
                fillTypeName = entry ~= nil and entry.fillTypeName or nil }
        end
    end
    if #out.buffers == 0 then return nil end
    return out
end

function TEDDER.write(xmlFile, base, data)
    writeLayout(xmlFile, base, data)
    for n, s in ipairs(data.buffers) do
        local k = string.format("%s.area(%d)", base, n - 1)
        xmlFile:setValue(k .. "#index", s.index)
        xmlFile:setValue(k .. "#litersToDrop", s.litersToDrop)
        if s.lastDropFillType ~= nil then xmlFile:setValue(k .. "#lastDropFillType", s.lastDropFillType) end
        if isNumber(s.dropIndex) then xmlFile:setValue(k .. "#dropIndex", s.dropIndex) end
        if s.lineOffset ~= nil then xmlFile:setValue(k .. "#lineOffset", s.lineOffset) end
        if s.fillTypeName ~= nil then xmlFile:setValue(k .. "#fillType", s.fillTypeName) end
    end
end

function TEDDER.read(xmlFile, base)
    local data = readLayout(xmlFile, base)
    local n = 0
    while true do
        local k = string.format("%s.area(%d)", base, n)
        if not xmlFile:hasProperty(k) then break end
        data.buffers[#data.buffers + 1] = { index = xmlFile:getValue(k .. "#index"), litersToDrop = xmlFile:getValue(k .. "#litersToDrop"),
            lastDropFillType = xmlFile:getValue(k .. "#lastDropFillType"), dropIndex = xmlFile:getValue(k .. "#dropIndex"),
            lineOffset = xmlFile:getValue(k .. "#lineOffset"), fillTypeName = xmlFile:getValue(k .. "#fillType") }
        n = n + 1
    end
    return data
end

--- Restore into the work areas native just built. Returns restored, unresolved (reasons), seeded.
function TEDDER.restore(vehicle, data)
    local areas = workAreasOf(vehicle)
    local why = layoutRefusal(vehicle, data, #tedderAreas(vehicle))
    if why ~= nil then return 0, { why }, 0 end
    local restored, unresolved, seeded = 0, {}, 0
    for _, s in ipairs(data.buffers) do
        local wa = isNumber(s.index) and areas[s.index] or nil
        local last = s.lastDropFillType == nil and (FillType ~= nil and FillType.UNKNOWN or 0) or fillTypeIndex(s.lastDropFillType)
        if not isTedderArea(wa) then
            unresolved[#unresolved + 1] = "AREA_INDEX"
        elseif wa.dropWindrowWorkAreaIndex ~= s.dropIndex then
            unresolved[#unresolved + 1] = "DROP_BINDING"
        elseif last == nil or (s.fillTypeName ~= nil and fillTypeIndex(s.fillTypeName) == nil) then
            unresolved[#unresolved + 1] = "FILL_TYPE"
        elseif not isNumber(s.litersToDrop) or s.litersToDrop <= 0 or (s.lineOffset ~= nil and not isNumber(s.lineOffset)) then
            unresolved[#unresolved + 1] = "AREA_VALUES"
        elseif wa.litersToDrop ~= 0 then
            unresolved[#unresolved + 1] = "AREA_OCCUPIED"
        else
            wa.litersToDrop = s.litersToDrop
            wa.lastDropFillType = last
            local drop = areas[wa.dropWindrowWorkAreaIndex]
            if type(drop) == "table" and s.lineOffset ~= nil then drop.lineOffset = s.lineOffset end
            restored = restored + 1
            if s.fillTypeName ~= nil and SGGroundObserver ~= nil and SGGroundObserver.seedTedderBuffer(vehicle, wa, s.fillTypeName) then seeded = seeded + 1 end
        end
    end
    return restored, unresolved, seeded
end

function TEDDER.registerPaths(schema, base, T)
    local a = base .. ".area(?)"
    schema:register(T.INT, a .. "#index", "Tedder work area index")
    schema:register(T.FLOAT, a .. "#litersToDrop", "Tedder work area remainder (litersToDrop)")
    schema:register(T.STRING, a .. "#lastDropFillType", "Tedder work area lastDropFillType name")
    schema:register(T.INT, a .. "#dropIndex", "Tedder drop binding (dropWindrowWorkAreaIndex)")
    schema:register(T.FLOAT, a .. "#lineOffset", "Tedder drop area lineOffset")
    schema:register(T.STRING, a .. "#fillType", "StockGuard buffer material name")
end

-- ---------------------------------------------------------
-- The Mower: one buffer per drop area
-- ---------------------------------------------------------
local MOWER = { name = "mower", className = "Mower", specTable = "spec_mower" }
F.KINDS[#F.KINDS + 1] = MOWER

local function dropAreasOf(vehicle)
    local spec = vehicle.spec_mower
    return type(spec) == "table" and type(spec.dropAreas) == "table" and spec.dropAreas or {}
end
local function isDropArea(vehicle, area)
    if type(area) ~= "table" then return false end
    for _, d in ipairs(dropAreasOf(vehicle)) do if d == area then return true end end
    return false
end
--- Is `wa` a MOWER work area whose drop area is the one at `index` (Mower.lua:406-424)?
local function cutBinds(wa, index)
    return type(wa) == "table" and WorkAreaType ~= nil and WorkAreaType.MOWER ~= nil and wa.type == WorkAreaType.MOWER and wa.dropAreaIndex == index
end

function MOWER.collect(vehicle)
    local A = SGNativeAdapters
    local drops = dropAreasOf(vehicle)
    local out = { version = F.VERSION, configFileName = configOf(vehicle), areaCount = #drops, buffers = {} }
    for _, d in ipairs(drops) do
        local held = d.litersToDrop
        if isNumber(held) and held > 0 and isNumber(d.index) then
            local entry = A ~= nil and entryOf(A.mowerBuffers, A.mowerBufferBinding(vehicle, d.index), vehicle, "dropArea", d) or nil
            out.buffers[#out.buffers + 1] = { index = d.index, litersToDrop = held, fillType = fillTypeName(d.fillType),
                workAreaIndex = isNumber(d.workAreaIndex) and d.workAreaIndex or nil, dropLineOffset = isNumber(d.dropLineOffset) and d.dropLineOffset or nil,
                fresh = entry ~= nil and math.max(0, math.min(isNumber(entry.fresh) and entry.fresh or 0, held)) or nil,
                soilFramed = entry ~= nil and entry.soilFramed == true or nil }
        end
    end
    if #out.buffers == 0 then return nil end
    return out
end

function MOWER.write(xmlFile, base, data)
    writeLayout(xmlFile, base, data)
    for n, s in ipairs(data.buffers) do
        local k = string.format("%s.dropArea(%d)", base, n - 1)
        xmlFile:setValue(k .. "#index", s.index)
        xmlFile:setValue(k .. "#litersToDrop", s.litersToDrop)
        if s.fillType ~= nil then xmlFile:setValue(k .. "#fillType", s.fillType) end
        if s.workAreaIndex ~= nil then xmlFile:setValue(k .. "#workAreaIndex", s.workAreaIndex) end
        if s.dropLineOffset ~= nil then xmlFile:setValue(k .. "#dropLineOffset", s.dropLineOffset) end
        if s.fresh ~= nil then
            xmlFile:setValue(k .. "#fresh", s.fresh)
            xmlFile:setValue(k .. "#soilFramed", s.soilFramed == true)
        end
    end
end

function MOWER.read(xmlFile, base)
    local data = readLayout(xmlFile, base)
    local n = 0
    while true do
        local k = string.format("%s.dropArea(%d)", base, n)
        if not xmlFile:hasProperty(k) then break end
        data.buffers[#data.buffers + 1] = { index = xmlFile:getValue(k .. "#index"), litersToDrop = xmlFile:getValue(k .. "#litersToDrop"),
            fillType = xmlFile:getValue(k .. "#fillType"), workAreaIndex = xmlFile:getValue(k .. "#workAreaIndex"),
            dropLineOffset = xmlFile:getValue(k .. "#dropLineOffset"), fresh = xmlFile:getValue(k .. "#fresh"),
            soilFramed = xmlFile:getValue(k .. "#soilFramed") }
        n = n + 1
    end
    return data
end

function MOWER.restore(vehicle, data)
    local areas = workAreasOf(vehicle)
    local why = layoutRefusal(vehicle, data, #dropAreasOf(vehicle))
    if why ~= nil then return 0, { why }, 0 end
    local restored, unresolved, seeded = 0, {}, 0
    for _, s in ipairs(data.buffers) do
        local d = isNumber(s.index) and areas[s.index] or nil
        local ft = fillTypeIndex(s.fillType)
        if not isDropArea(vehicle, d) then
            unresolved[#unresolved + 1] = "AREA_INDEX"
        elseif s.workAreaIndex ~= nil and not (isNumber(s.workAreaIndex) and cutBinds(areas[s.workAreaIndex], s.index)) then
            unresolved[#unresolved + 1] = "WORK_AREA_BINDING"
        elseif ft == nil then
            unresolved[#unresolved + 1] = "FILL_TYPE"
        elseif not isNumber(s.litersToDrop) or s.litersToDrop <= 0 or (s.dropLineOffset ~= nil and not isNumber(s.dropLineOffset))
            or (s.fresh ~= nil and not (isNumber(s.fresh) and s.fresh >= 0)) then
            unresolved[#unresolved + 1] = "AREA_VALUES"
        elseif d.litersToDrop ~= 0 then
            unresolved[#unresolved + 1] = "AREA_OCCUPIED"
        else
            d.litersToDrop = s.litersToDrop
            d.fillType = ft
            if s.workAreaIndex ~= nil then d.workAreaIndex = s.workAreaIndex end
            if s.dropLineOffset ~= nil then d.dropLineOffset = s.dropLineOffset end
            restored = restored + 1
            if s.fresh ~= nil and SGGroundObserver ~= nil
                and SGGroundObserver.seedMowerBuffer(vehicle, d, math.min(s.fresh, s.litersToDrop), s.soilFramed == true) then seeded = seeded + 1 end
        end
    end
    return restored, unresolved, seeded
end

function MOWER.registerPaths(schema, base, T)
    local a = base .. ".dropArea(?)"
    schema:register(T.INT, a .. "#index", "Mower drop area index")
    schema:register(T.FLOAT, a .. "#litersToDrop", "Mower drop area remainder (litersToDrop)")
    schema:register(T.STRING, a .. "#fillType", "Mower drop area fill type name")
    schema:register(T.INT, a .. "#workAreaIndex", "Mower cut work area binding (dropArea.workAreaIndex)")
    schema:register(T.FLOAT, a .. "#dropLineOffset", "Mower drop area dropLineOffset")
    schema:register(T.FLOAT, a .. "#fresh", "StockGuard fresh litres still waiting for Soil's birth")
    schema:register(T.BOOL, a .. "#soilFramed", "StockGuard: every litre came through an admitted cut")
end

-- ---------------------------------------------------------
-- The Baler: its pending overflow (SG2-5e-a, SG-2 :477's overflow half)
-- ---------------------------------------------------------
--- Baler:saveToXMLFile (Baler.lua:621-656) saves the bales, the platform, the bale type and the
--- capacity, never spec.fillUnitOverflowFillLevel, and Baler:onLoad zeroes it (:407): native
--- discards a pending overflow at every reload. It is real pending volume native pours into the
--- chamber on its next positive fill (:1179-1182), so it is saved here with the layout native's own
--- fill unit and bale type define, and put back after the original Baler.onPostLoad. FillUnit
--- precedes Baler in the type's specialization order (vehicleTypes.xml: baseFillable's fillUnit,
--- then baler), so that is after FillUnit re-added the chamber and before onLoadFinished's deferred
--- finishBale (:570-575), as :477 asks. Only the overflow scalar is added: the chamber stays
--- FillUnit's and the bales native's. The round mirror and partial ejection (:473, :475, and :477's
--- partial-ejection half) are 5e-c and 5e-d.
---
--- SG2 bale family 2b, THE BALE-LIST TOKEN (SG-2 :477's last sentences, "a native saved bale-list
--- entry carries its exact token"). A square Baler saves its bale list itself (:621-640: filename,
--- variant, owner, type, level and time, no uniqueId), and its onLoadFinished recreates each entry
--- through createBale(..., true) (:576-581), so each comes back as a new object with a fresh id.
--- Beside the list, per entry, this saves the bale's StockGuard carrier key and its type, by list
--- index. At the load the tokens wait on the vehicle until onLoadFinished has made the new objects;
--- SGGroundObserver's load listener collects them in call order and applyBaleTokens maps each
--- saved key to the object it became (SGNativeAdapters.baleRestores), for SG-1's restore at the
--- barrier. That bale is restored, not born (:483). A count mismatch rejects every token, a type
--- mismatch or a failed create that one: never assigned by order alone.
local BALER = { name = "baler", className = "Baler", specTable = "spec_baler" }
F.KINDS[#F.KINDS + 1] = BALER

--- The layout a saved overflow belongs to: the chamber's fill unit, its capacity, the bale type.
local function balerLayout(vehicle)
    local spec = vehicle.spec_baler
    local idx = spec.fillUnitIndex
    local cap = nil
    if isNumber(idx) and type(vehicle.getFillUnitCapacity) == "function" then cap = vehicle:getFillUnitCapacity(idx) end
    return idx, cap, spec.currentBaleTypeIndex
end

--- 2b: per square bale-list entry, its StockGuard carrier key (when the bale is bindable) and its
--- type, by list index; nil for a round Baler or an empty list.
function F.collectBaleTokens(vehicle)
    local spec = vehicle.spec_baler
    if spec.hasUnloadingAnimation == true or type(spec.bales) ~= "table" or #spec.bales == 0 then return nil end
    local A = SGNativeAdapters
    local out = {}
    for k, b in ipairs(spec.bales) do
        local bale = type(b) == "table" and b.baleObject or nil
        local binding = A ~= nil and bale ~= nil and A.baleBinding(bale) or nil
        out[#out + 1] = { index = k, token = binding ~= nil and SGRecords.carrierKeyString(binding.carrierKey) or nil,
                          fillType = type(b) == "table" and fillTypeName(b.fillType) or nil }
    end
    return out
end

function BALER.collect(vehicle)
    local spec = vehicle.spec_baler
    local held = spec.fillUnitOverflowFillLevel
    local tokens = F.collectBaleTokens(vehicle)
    local hasOverflow = isNumber(held) and held > 0
    if not hasOverflow and tokens == nil then return nil end
    local idx, cap, bt = balerLayout(vehicle)
    local data = { version = F.VERSION, configFileName = configOf(vehicle), areaCount = 1, fillUnitIndex = idx, capacity = cap,
                   baleTypeIndex = bt, bales = tokens or {} }
    if hasOverflow then
        local A = SGNativeAdapters
        local entry = nil
        if A ~= nil then
            local b = A.balerOverflowBinding(vehicle)
            local e = b ~= nil and A.balerOverflows[SGRecords.carrierKeyString(b.carrierKey)] or nil
            if e ~= nil and e.vehicle == vehicle then entry = e end
        end
        data.overflow = held
        data.producedAs = entry ~= nil and entry.producedAs or nil
    end
    return data
end

function BALER.write(xmlFile, base, data)
    writeLayout(xmlFile, base, data)
    if isNumber(data.fillUnitIndex) then xmlFile:setValue(base .. "#fillUnitIndex", data.fillUnitIndex) end
    if isNumber(data.capacity) then xmlFile:setValue(base .. "#fillUnitCapacity", data.capacity) end
    if isNumber(data.baleTypeIndex) then xmlFile:setValue(base .. "#baleTypeIndex", data.baleTypeIndex) end
    if data.overflow ~= nil then
        xmlFile:setValue(base .. "#overflow", data.overflow)
        if data.producedAs ~= nil then xmlFile:setValue(base .. "#producedAs", data.producedAs) end
    end
    for n, t in ipairs(data.bales or {}) do
        local k = string.format("%s.bale(%d)", base, n - 1)
        xmlFile:setValue(k .. "#index", t.index)
        if t.token ~= nil then xmlFile:setValue(k .. "#token", t.token) end
        if t.fillType ~= nil then xmlFile:setValue(k .. "#fillType", t.fillType) end
    end
end

function BALER.read(xmlFile, base)
    local data = readLayout(xmlFile, base)
    data.fillUnitIndex = xmlFile:getValue(base .. "#fillUnitIndex")
    data.capacity = xmlFile:getValue(base .. "#fillUnitCapacity")
    data.baleTypeIndex = xmlFile:getValue(base .. "#baleTypeIndex")
    data.overflow = xmlFile:getValue(base .. "#overflow")
    data.producedAs = xmlFile:getValue(base .. "#producedAs")
    data.bales = {}
    local n = 0
    while true do
        local k = string.format("%s.bale(%d)", base, n)
        if not xmlFile:hasProperty(k) then break end
        data.bales[#data.bales + 1] = { index = xmlFile:getValue(k .. "#index"), token = xmlFile:getValue(k .. "#token"), fillType = xmlFile:getValue(k .. "#fillType") }
        n = n + 1
    end
    return data
end

--- Another controller, fill unit, capacity or bale type at the load restores nothing (:477: "Reject
--- incompatible controller/type/capacity bindings instead of assigning old overflow to a new load").
--- The capacity is written as a FLOAT, so it compares as images (SGValues.nativeFloatImage, both
--- sides): a capacity read back as a float32 or as a double has the image of the one written.
function BALER.restore(vehicle, data)
    local spec = vehicle.spec_baler
    -- 2b: the bale-list tokens wait for onLoadFinished's recreation (Baler.lua:576-581).
    spec.sgBaleTokens = (data.version == F.VERSION and type(data.bales) == "table" and #data.bales > 0) and data.bales or nil
    if data.overflow == nil then return 0, {}, 0 end
    local why = layoutRefusal(vehicle, data, 1)
    if why ~= nil then return 0, { why }, 0 end
    local idx, cap, bt = balerLayout(vehicle)
    if data.fillUnitIndex ~= idx or data.baleTypeIndex ~= bt then return 0, { "BALER_LAYOUT" }, 0 end
    if not isNumber(data.capacity) or not isNumber(cap) or SGValues.nativeFloatImage(cap) ~= SGValues.nativeFloatImage(data.capacity) then return 0, { "CAPACITY" }, 0 end
    if data.producedAs ~= nil and fillTypeIndex(data.producedAs) == nil then return 0, { "FILL_TYPE" }, 0 end
    if not isNumber(data.overflow) or data.overflow <= 0 then return 0, { "AREA_VALUES" }, 0 end
    if spec.fillUnitOverflowFillLevel ~= 0 then return 0, { "AREA_OCCUPIED" }, 0 end
    spec.fillUnitOverflowFillLevel = data.overflow
    local seeded = 0
    if data.producedAs ~= nil and SGGroundObserver ~= nil and SGGroundObserver.seedBalerOverflow(vehicle, data.producedAs) then seeded = 1 end
    return 1, {}, seeded
end

function BALER.registerPaths(schema, base, T)
    schema:register(T.INT, base .. "#fillUnitIndex", "Baler chamber fill unit index (the layout)")
    schema:register(T.FLOAT, base .. "#fillUnitCapacity", "Baler chamber capacity (the layout)")
    schema:register(T.INT, base .. "#baleTypeIndex", "Baler current bale type index (the layout)")
    schema:register(T.FLOAT, base .. "#overflow", "Baler pending overflow (fillUnitOverflowFillLevel)")
    schema:register(T.STRING, base .. "#producedAs", "StockGuard: the material the overflow was produced as")
    schema:register(T.INT, base .. ".bale(?)#index", "Baler bale list index (StockGuard bale token)")
    schema:register(T.STRING, base .. ".bale(?)#token", "StockGuard: the listed bale's carrier key")
    schema:register(T.STRING, base .. ".bale(?)#fillType", "StockGuard: the listed bale's fill type name")
end

--- 2b: after Baler.onLoadFinished, map each saved token to the bale its createBale(..., true) call
--- made, in call order (`created`, a failed call as false; never spec.bales indices). A count
--- mismatch rejects every token; a type mismatch or a failed create rejects that one. A rejected
--- bale stays unknown (enumerated fresh at the barrier). Returns the count mapped.
function F.applyBaleTokens(vehicle, created)
    local spec = type(vehicle) == "table" and vehicle.spec_baler or nil
    if spec == nil then return 0 end
    local tokens = spec.sgBaleTokens
    spec.sgBaleTokens = nil
    if type(tokens) ~= "table" or #tokens == 0 then return 0 end
    local A = SGNativeAdapters
    if A == nil then return 0 end
    created = type(created) == "table" and created or {}
    if #created ~= #tokens then
        F.stats.unresolved = F.stats.unresolved + 1
        logOnce("baleTokens:count:" .. configOf(vehicle), string.format("saved bale tokens not applied on %s: %d saved, %d recreated (BALE_TOKEN_COUNT); those bales are unknown. Logged once.",
            configOf(vehicle), #tokens, #created))
        return 0
    end
    local mapped, refused = 0, {}
    for i, t in ipairs(tokens) do
        local bale = created[i]
        if t.token ~= nil then
            local ft = nil
            if bale ~= false and bale ~= nil and A.isBale(bale) and type(bale.getFillType) == "function" then
                local ok, index = pcall(bale.getFillType, bale)
                if ok then ft = fillTypeName(index) end
            end
            if bale == false or bale == nil or not A.isBale(bale) then
                refused[#refused + 1] = "BALE_TOKEN_CREATE"
            elseif ft == nil or ft ~= t.fillType then
                refused[#refused + 1] = "BALE_TOKEN_TYPE"
            else
                A.baleRestores[t.token] = bale
                mapped = mapped + 1
            end
        end
    end
    F.stats.tokens = (F.stats.tokens or 0) + mapped
    if #refused > 0 then
        F.stats.unresolved = F.stats.unresolved + #refused
        logOnce("baleTokens:" .. table.concat(refused, ","), string.format("%d saved bale token(s) not applied on %s (%s); those bales are unknown. Logged once per reason set.",
            #refused, configOf(vehicle), table.concat(refused, ",")))
    end
    return mapped
end

-- ---------------------------------------------------------
-- The ForageWagon: its one buffer (SG2-5f; SG-2 :144's ForageWagon half and :364)
-- ---------------------------------------------------------
--- ForageWagon defines no saveToXMLFile, and its onLoad zeroes workAreaParameters.litersToFill
--- (ForageWagon.lua:82): native discards a remainder at every reload. It is saved here only while it
--- holds litres, with its binding (:144): the fill unit's index and identity (its supported fill type
--- names), litersToFill, lastFillType by canonical name, and the buffer token (the StockGuard carrier
--- key, when StockGuard had bound it). It is put back right after the original ForageWagon.onLoad,
--- which receives the savegame (Vehicle.lua:866) and has read its own fill units (:65-66), FillUnit
--- having loaded first; ForageWagon registers no onPostLoad (:38-51), so this descriptor's load event
--- is onLoad. The restore validates the layout, the fill unit, the type and the values; on success it
--- sets the native fields back and, when the token is this wagon's buffer key, seeds the entry, so
--- SG-1's restore at the barrier reattaches the saved stock and its account (:364; DESIGN-CHECK row 190).
local FORAGE = { name = "forageWagon", className = "ForageWagon", specTable = "spec_forageWagon", loadEvent = "onLoad" }
F.KINDS[#F.KINDS + 1] = FORAGE

--- The fill unit's identity: its supported fill type names, sorted and space-joined.
local function forageUnitTypes(vehicle, index)
    if type(vehicle.getFillUnitSupportedFillTypes) ~= "function" then return nil end
    local ok, types = pcall(vehicle.getFillUnitSupportedFillTypes, vehicle, index)
    if not ok or type(types) ~= "table" then return nil end
    local names = {}
    for ft, state in pairs(types) do
        local n = state and fillTypeName(ft) or nil
        if n ~= nil then names[#names + 1] = n end
    end
    table.sort(names)
    return table.concat(names, " ")
end

function FORAGE.collect(vehicle)
    local spec = vehicle.spec_forageWagon
    local wap = type(spec.workAreaParameters) == "table" and spec.workAreaParameters or nil
    local held = wap ~= nil and wap.litersToFill or nil
    if not isNumber(held) or held <= 0 then return nil end
    local A = SGNativeAdapters
    local token = nil
    if A ~= nil then
        local b = A.forageBufferBinding(vehicle)
        local key = b ~= nil and SGRecords.carrierKeyString(b.carrierKey) or nil
        local e = key ~= nil and A.forageBuffers[key] or nil
        if e ~= nil and e.vehicle == vehicle then token = key end
    end
    return { version = F.VERSION, configFileName = configOf(vehicle), areaCount = 1, fillUnitIndex = spec.fillUnitIndex,
             fillTypes = forageUnitTypes(vehicle, spec.fillUnitIndex), litersToFill = held, lastFillType = fillTypeName(spec.lastFillType), token = token }
end

function FORAGE.write(xmlFile, base, data)
    writeLayout(xmlFile, base, data)
    if isNumber(data.fillUnitIndex) then xmlFile:setValue(base .. "#fillUnitIndex", data.fillUnitIndex) end
    if data.fillTypes ~= nil then xmlFile:setValue(base .. "#fillTypes", data.fillTypes) end
    xmlFile:setValue(base .. "#litersToFill", data.litersToFill)
    if data.lastFillType ~= nil then xmlFile:setValue(base .. "#lastFillType", data.lastFillType) end
    if data.token ~= nil then xmlFile:setValue(base .. "#token", data.token) end
end

function FORAGE.read(xmlFile, base)
    local data = readLayout(xmlFile, base)
    data.fillUnitIndex = xmlFile:getValue(base .. "#fillUnitIndex")
    data.fillTypes = xmlFile:getValue(base .. "#fillTypes")
    data.litersToFill = xmlFile:getValue(base .. "#litersToFill")
    data.lastFillType = xmlFile:getValue(base .. "#lastFillType")
    data.token = xmlFile:getValue(base .. "#token")
    return data
end

--- Another configuration, a fill unit index naming no unit or another one, another set of supported
--- types, an unknown type, a type the unit does not support, or bad values restore nothing (:144
--- "validate the mapping").
function FORAGE.restore(vehicle, data)
    local spec = vehicle.spec_forageWagon
    local why = layoutRefusal(vehicle, data, 1)
    if why ~= nil then return 0, { why }, 0 end
    local idx = data.fillUnitIndex
    local unit = (isNumber(idx) and type(vehicle.getFillUnitByIndex) == "function") and vehicle:getFillUnitByIndex(idx) or nil
    if idx ~= spec.fillUnitIndex or unit == nil then return 0, { "FILL_UNIT" }, 0 end
    if data.fillTypes == nil or data.fillTypes ~= forageUnitTypes(vehicle, idx) then return 0, { "FILL_UNIT_TYPES" }, 0 end
    local ft = fillTypeIndex(data.lastFillType)
    if ft == nil then return 0, { "FILL_TYPE" }, 0 end
    if type(vehicle.getFillUnitSupportsFillType) ~= "function" or not vehicle:getFillUnitSupportsFillType(idx, ft) then return 0, { "FILL_TYPE_UNSUPPORTED" }, 0 end
    if not isNumber(data.litersToFill) or data.litersToFill <= 0 then return 0, { "AREA_VALUES" }, 0 end
    local wap = spec.workAreaParameters
    if type(wap) ~= "table" or wap.litersToFill ~= 0 then return 0, { "AREA_OCCUPIED" }, 0 end
    wap.litersToFill = data.litersToFill
    spec.lastFillType = ft
    local seeded = 0
    local A = SGNativeAdapters
    local b = A ~= nil and A.forageBufferBinding(vehicle) or nil
    if data.token ~= nil and b ~= nil and data.token == SGRecords.carrierKeyString(b.carrierKey) and SGGroundObserver ~= nil
        and SGGroundObserver.seedForageBuffer(vehicle) then seeded = 1 end
    return 1, {}, seeded
end

function FORAGE.registerPaths(schema, base, T)
    schema:register(T.INT, base .. "#fillUnitIndex", "ForageWagon fill unit index (the binding)")
    schema:register(T.STRING, base .. "#fillTypes", "ForageWagon fill unit supported fill types (its identity)")
    schema:register(T.FLOAT, base .. "#litersToFill", "ForageWagon buffer (workAreaParameters.litersToFill)")
    schema:register(T.STRING, base .. "#lastFillType", "ForageWagon lastFillType name")
    schema:register(T.STRING, base .. "#token", "StockGuard: the buffer carrier key")
end

-- ---------------------------------------------------------
-- The hooks, generic over a kind
-- ---------------------------------------------------------
--- Appended to the kind's class saveToXMLFile (Vehicle.lua:1212 hands it "<vehicle>.<specName>").
function F.onSave(kind, vehicle, xmlFile, key)
    if g_server == nil or type(key) ~= "string" or xmlFile == nil or type(vehicle) ~= "table" or vehicle[kind.specTable] == nil then return end
    local ok, data = pcall(kind.collect, vehicle)
    if not ok then logOnce("collect:" .. kind.name, kind.name .. " collect failed (" .. tostring(data) .. "); nothing written") return end
    if data == nil then return end
    local okW, err = pcall(kind.write, xmlFile, key .. "." .. F.ELEMENT, data)
    if not okW then logOnce("write:" .. kind.name, kind.name .. " write failed (" .. tostring(err) .. ")") return end
    F.stats.saved = F.stats.saved + 1
end

--- Appended to the kind's class load event, onPostLoad unless the kind names another (both queued
--- through raiseAsyncEvent with the savegame, Vehicle.lua:866 and :903-906; nil for a vehicle that was
--- not loaded from one).
function F.onPostLoad(kind, vehicle, savegame, class)
    if g_server == nil or type(savegame) ~= "table" or savegame.xmlFile == nil or type(savegame.key) ~= "string" then return end
    if savegame.resetVehicles then return end
    if type(vehicle) ~= "table" or vehicle[kind.specTable] == nil then return end
    local base = savegame.key .. "." .. tostring(specNameOf(vehicle, class, kind.name)) .. "." .. F.ELEMENT
    if not savegame.xmlFile:hasProperty(base) then return end
    local ok, data = pcall(kind.read, savegame.xmlFile, base)
    if not ok then logOnce("read:" .. kind.name, kind.name .. " read failed (" .. tostring(data) .. "); nothing restored") return end
    local okR, restored, unresolved, seeded = pcall(kind.restore, vehicle, data)
    if not okR then logOnce("restore:" .. kind.name, kind.name .. " restore failed (" .. tostring(restored) .. ")") return end
    vehicle[kind.specTable].sgBufferRestore = { restored = restored, unresolved = unresolved, seeded = seeded }
    F.stats.restored = F.stats.restored + restored
    F.stats.seeded = F.stats.seeded + seeded
    if #unresolved > 0 then
        F.stats.unresolved = F.stats.unresolved + #unresolved
        logOnce("unresolved:" .. kind.name .. ":" .. table.concat(unresolved, ","), string.format("a saved %s buffer could not be restored (%s) on %s; it is left unresolved, nothing set. Logged once per reason set.",
            kind.name, table.concat(unresolved, ","), configOf(vehicle)))
    end
    if restored > 0 then
        logOnce("restored:" .. kind.name, string.format("FIRST %s BUFFER RESTORED: %d remainder(s) survived the save on %s.", string.upper(kind.name), restored, configOf(vehicle)))
    end
end

--- Install one kind on its class table once (mechanism 3, read at call time). The class has
--- no saveToXMLFile of its own; one another mod put there runs first.
function F.installKind(kind, class)
    local event = kind.loadEvent or "onPostLoad"
    if type(class) ~= "table" or type(class[event]) ~= "function" then return false end
    if rawget(class, F.MARKER) ~= nil then return false end
    local originalSave, originalPostLoad = class.saveToXMLFile, class[event]
    if originalSave ~= nil and type(originalSave) ~= "function" then return false end
    class.saveToXMLFile = function(self, xmlFile, key, ...)
        local n, r = 0, {}
        if originalSave ~= nil then n, r = packn(originalSave(self, xmlFile, key, ...)) end
        local ok, err = pcall(F.onSave, kind, self, xmlFile, key)
        if not ok then logOnce("saveHook:" .. kind.name, kind.name .. " save hook failed (" .. tostring(err) .. ")") end
        return unpack(r, 1, n)
    end
    class[event] = function(self, savegame, ...)
        local n, r = packn(originalPostLoad(self, savegame, ...))
        local ok, err = pcall(F.onPostLoad, kind, self, savegame, class)
        if not ok then logOnce("postLoadHook:" .. kind.name, kind.name .. " post-load hook failed (" .. tostring(err) .. ")") end
        return unpack(r, 1, n)
    end
    rawset(class, F.MARKER, { saveToXMLFile = originalSave, [event] = originalPostLoad })
    return true
end

--- Install every kind whose class is given ({ Tedder = ..., Mower = ..., ForageWagon = ... }). Returns the count.
function F.installClassHooks(classes)
    local n = 0
    for _, kind in ipairs(F.KINDS) do
        if F.installKind(kind, type(classes) == "table" and classes[kind.className] or nil) then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------
-- The savegame schema
-- ---------------------------------------------------------
function F.savegameBase(kind) return "vehicles.vehicle(?)." .. kind.name .. "." .. F.ELEMENT end

--- Register every kind's paths, each with its real type, on a savegame schema, once per schema
--- and kind (a marker on the schema).
function F.registerSavegamePaths(schema)
    if type(schema) ~= "table" or type(schema.register) ~= "function" or type(XMLValueType) ~= "table" then return 0 end
    local n = 0
    for _, kind in ipairs(F.KINDS) do
        local mark = F.MARKER .. ":" .. kind.name
        if rawget(schema, mark) == nil then
            rawset(schema, mark, true)
            local base = F.savegameBase(kind)
            registerLayout(schema, base, XMLValueType)
            kind.registerPaths(schema, base, XMLValueType)
            n = n + 1
        end
    end
    return n
end

--- WHEN THE PATHS ARE REGISTERED. Not from Tedder's and Mower's initSpecialization: the engine
--- sources each specialization again into a NEW class table on every map load
--- (SpecializationManager:addSpecialization from loadMapData, SpecializationManager.lua:68-95;
--- MPLoadingScreen.lua:352), while StockGuard is sourced once per game process (loadMod returns
--- once g_modIsLoaded is set, mods.lua:974-979; only a mods reload clears it, :1173-1186). An
--- append on a specialization made when this file is sourced would reach the first map load
--- only. Vehicle is a base class, sourced once per process, and Vehicle.init builds a fresh
--- savegame schema on every map load (Vehicle.lua:222, :249; MPLoadingScreen.lua:767), before
--- initSpecializations (:776) and before the vehicles file is created or loaded with it
--- (VehicleSystem.lua:293, :324). So the paths are registered onto the schema the original
--- Vehicle.init just made, after it returns, through one SGClassHook record (MAINTENANCE row
--- 187): a mods reload rebinds the record, never stacks a second wrapper.
F.HOOK_ID = "fieldToolBufferSave"
function F.installSchemaHook(vehicleClass)
    if type(vehicleClass) ~= "table" or SGClassHook == nil then return false end
    return SGClassHook.wrap(vehicleClass, "init", F.HOOK_ID, SGClassHook.around(nil, function()
        local ok, err = pcall(F.registerSavegamePaths, vehicleClass.xmlSchemaSavegame)
        if not ok then logOnce("schema", "schema registration failed (" .. tostring(err) .. ")") end
    end), F)
end

-- Installed when this file is sourced: MPLoadingScreen.lua:735 sources a mod before Vehicle.init
-- at :767, so the first map load's schema carries the paths too, and every later one through the
-- same record.
if type(Vehicle) == "table" and type(Vehicle.init) == "function" then F.installSchemaHook(Vehicle) end
