-- =========================================================
-- FS25_StockGuard - EP-1 chemical station: navigation address (pure logic)
-- =========================================================
-- The facility derives navigationCarrierId from the SG-1 carrier adapter's
-- actual RF_WIP binding (brief, "empty-facility navigation and native address
-- delivery"). Only an RF_WIP notification changes the anchor: READY installs
-- its carrierId; withdrawal, readiness loss or a failed mapping clears it.
-- Notifications for the other four roles never touch a healthy anchor.
--
-- An address is a nonempty UTF-8 string of at most 4096 bytes. An invalid or
-- oversized source or received address clears navigation readiness; it is
-- never truncated or hashed.
--
-- Wire shape, after the declared native role payload:
--   full stream:   Bool addressPresent, then String only when present
--   dirty update:  Bool addressChanged, then the same presence/string pair when true
-- The server writes; clients stage the field, validate it, then replace the
-- local value. Absence clears an older address. The field is never saved.
--
-- Engine stream functions (streamWriteBool/streamReadBool/streamWriteString/
-- streamReadString) are resolved at call time, so this file loads without
-- the engine. Dirty-flag allocation stays with the specialization owner.
-- =========================================================

ChemicalStationAddress = ChemicalStationAddress or {}

local Address = ChemicalStationAddress

Address.MAX_BYTES = 4096

Address.REASON_NOT_STRING = "ADDRESS_NOT_STRING"
Address.REASON_EMPTY = "ADDRESS_EMPTY"
Address.REASON_OVERSIZED = "ADDRESS_OVERSIZED"
Address.REASON_INVALID_UTF8 = "ADDRESS_INVALID_UTF8"

-- Binding notification states from the SG-1 carrier adapter.
Address.BINDING_READY = "READY"

local RF_WIP = "RF_WIP"

-- =========================================================
-- UTF-8 validation (Lua 5.1 has no utf8 library)
-- =========================================================

--- Strict UTF-8 check: rejects overlongs, surrogates and code points above U+10FFFF.
local function isValidUtf8(s)
    local i, n = 1, #s
    while i <= n do
        local c = string.byte(s, i)
        if c < 0x80 then
            i = i + 1
        elseif c >= 0xC2 and c <= 0xDF then
            local c2 = string.byte(s, i + 1)
            if c2 == nil or c2 < 0x80 or c2 > 0xBF then return false end
            i = i + 2
        elseif c >= 0xE0 and c <= 0xEF then
            local c2, c3 = string.byte(s, i + 1, i + 2)
            if c2 == nil or c3 == nil or c2 < 0x80 or c2 > 0xBF or c3 < 0x80 or c3 > 0xBF then return false end
            if c == 0xE0 and c2 < 0xA0 then return false end   -- overlong
            if c == 0xED and c2 > 0x9F then return false end   -- surrogate
            i = i + 3
        elseif c >= 0xF0 and c <= 0xF4 then
            local c2, c3, c4 = string.byte(s, i + 1, i + 3)
            if c2 == nil or c3 == nil or c4 == nil
                or c2 < 0x80 or c2 > 0xBF or c3 < 0x80 or c3 > 0xBF or c4 < 0x80 or c4 > 0xBF then
                return false
            end
            if c == 0xF0 and c2 < 0x90 then return false end   -- overlong
            if c == 0xF4 and c2 > 0x8F then return false end   -- above U+10FFFF
            i = i + 4
        else
            return false
        end
    end
    return true
end

--- Validate a candidate address. Returns ok, reason.
function Address.validate(addr)
    if type(addr) ~= "string" then
        return false, Address.REASON_NOT_STRING
    end
    if addr == "" then
        return false, Address.REASON_EMPTY
    end
    if #addr > Address.MAX_BYTES then
        return false, Address.REASON_OVERSIZED
    end
    if not isValidUtf8(addr) then
        return false, Address.REASON_INVALID_UTF8
    end
    return true, nil
end

-- =========================================================
-- Anchor state
-- =========================================================

--- New anchor state. address is nil until SG-1 reports an RF_WIP READY binding.
function Address.new()
    return { address = nil, invalidated = false }
end

--- Current navigation carrier id, or nil. Read-only.
function Address.get(state)
    if state == nil or state.invalidated then
        return nil
    end
    return state.address
end

--- Replace the address. Returns true when presence or value changed, which is
-- the only case the owner raises its dirty flag for.
function Address.set(state, newAddress)
    if state == nil or state.invalidated then
        return false
    end
    if newAddress ~= nil then
        local ok = Address.validate(newAddress)
        if not ok then
            newAddress = nil
        end
    end
    if state.address == newAddress then
        return false
    end
    state.address = newAddress
    return true
end

--- Teardown: the getter answers nil from now on, before native role objects go.
function Address.invalidate(state)
    if state == nil then
        return
    end
    state.address = nil
    state.invalidated = true
end

--- Apply an SG-1 onCarrierBindingChanged notification.
-- notification = { role = <fixed role name>, state = "READY" | other, carrierId = <string> }
-- The candidate is read in a protected local read; only the validated value or
-- nil is assigned. Returns changed (bool). Non-RF_WIP notifications never change
-- the anchor and return false.
function Address.onCarrierBindingChanged(state, notification)
    if state == nil or state.invalidated or type(notification) ~= "table" then
        return false
    end
    if notification.role ~= RF_WIP then
        return false
    end

    local candidate = nil
    if notification.state == Address.BINDING_READY then
        local ok, value = pcall(function() return notification.carrierId end)
        if ok then
            local valid = Address.validate(value)
            if valid then
                candidate = value
            end
        end
    end
    return Address.set(state, candidate)
end

-- =========================================================
-- Stream codec
-- =========================================================

--- Full stream: Bool presence, then the exact string only when present.
function Address.writeStream(state, streamId)
    local addr = Address.get(state)
    if addr ~= nil then
        streamWriteBool(streamId, true)
        streamWriteString(streamId, addr)
    else
        streamWriteBool(streamId, false)
    end
end

--- Full stream read. Returns the staged address or nil. The caller assigns
-- the result; an invalid received address stages nil and clears readiness.
function Address.readStream(streamId)
    local present = streamReadBool(streamId)
    if not present then
        return nil
    end
    local value = streamReadString(streamId)
    local ok = Address.validate(value)
    if not ok then
        return nil
    end
    return value
end

--- Dirty update: Bool changed, then the presence/string pair only when changed.
-- changed is the owner's dirty-mask test result for its own flag.
function Address.writeUpdateStream(state, streamId, changed)
    if changed then
        streamWriteBool(streamId, true)
        Address.writeStream(state, streamId)
    else
        streamWriteBool(streamId, false)
    end
end

--- Dirty update read. Returns changed, address. When changed is false the
-- client keeps its current address; when true it replaces it with address
-- (which may be nil, clearing an older one).
function Address.readUpdateStream(streamId)
    local changed = streamReadBool(streamId)
    if not changed then
        return false, nil
    end
    return true, Address.readStream(streamId)
end

--- Client-side apply of a staged read. Returns true when the local value changed.
function Address.applyReceived(state, address)
    return Address.set(state, address)
end
