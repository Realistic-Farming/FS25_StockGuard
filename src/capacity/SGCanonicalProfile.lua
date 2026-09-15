-- =========================================================
-- FS25_StockGuard - canonical capacity profile and admission header (SG-6)
-- =========================================================
-- The SG6_CAPACITY_2 profile identifies the realized loading result of one
-- peer: final width, registered fill names in index order, the map id, the
-- density channel layout, the format flags and the initialized ground
-- roster. Two peers may only exchange objects when their profiles agree.
--
-- Canonical input (section 4.6): every scalar is encoded as the decimal
-- UTF-8 BYTE length, a colon, then the bytes; items are concatenated with
-- nothing between them. Integers are plain base 10, booleans are the single
-- byte 0 or 1. The sequence is:
--   1. SG6_CAPACITY_2
--   2. profileVersion 2, widthBits, registeredCount, mapId
--   3. typeFirstChannel, typeNumChannels, heightFirstChannel, heightNumChannels
--   4. MATERIAL_COUNTS_2, STORAGE_2, integrationFlags, effectiveMaximumNativeIndex
--   5. nativePairCount, then index and canonical name for each native index
--   6. groundPairCount, then ground index, native fill name and canBeTipped 0/1
--
-- The header appended to BaseMissionFinishedLoadingEvent after its four
-- native Float32 fields is 41 bytes: Int32 magic 0x53473632, UInt8 version,
-- UInt8 width, UInt16 registeredCount, UInt8 formatFlags, 32 digest octets.
-- =========================================================

SGCanonicalProfile = SGCanonicalProfile or {}

SGCanonicalProfile.LITERAL          = "SG6_CAPACITY_2"
SGCanonicalProfile.PROFILE_VERSION  = 2
SGCanonicalProfile.MATERIAL_COUNTS  = "MATERIAL_COUNTS_2"
SGCanonicalProfile.STORAGE          = "STORAGE_2"
SGCanonicalProfile.HEADER_MAGIC     = 0x53473632
SGCanonicalProfile.HEADER_BYTES     = 41

-- integrationFlags bits
SGCanonicalProfile.FLAG_PRODUCTION_CONTROL = 1   -- bit0 (unbound in this build)
SGCanonicalProfile.FLAG_PUMPS_N_HOSES      = 2   -- bit1 (unbound in this build)
SGCanonicalProfile.FLAG_REALSILO_CEILING   = 4   -- bit2 (unbound in this build)
SGCanonicalProfile.FLAG_SOIL_GROUND_PREP   = 8   -- bit3
SGCanonicalProfile.KNOWN_INTEGRATION_MASK  = 15

-- formatFlags bits
SGCanonicalProfile.FORMAT_WIDE_COUNTS  = 1
SGCanonicalProfile.FORMAT_SELF_STORAGE = 2
SGCanonicalProfile.KNOWN_FORMAT_MASK   = 3

local function scalar(v)
    local s
    if type(v) == "boolean" then s = v and "1" or "0"
    elseif type(v) == "number" then s = string.format("%d", v)
    else s = tostring(v) end
    return tostring(#s) .. ":" .. s
end
SGCanonicalProfile.scalar = scalar

local function isInt(n) return type(n) == "number" and n == math.floor(n) and n == n end

--- Build the canonical byte string. Returns bytes or nil, reason.
--- p = { widthBits, mapId, typeFirstChannel, typeNumChannels, heightFirstChannel,
---       heightNumChannels, integrationFlags, effectiveMaximumNativeIndex,
---       names = { [1] = "UNKNOWN", ... }, ground = { { index, name, canBeTipped }, ... } }
function SGCanonicalProfile.canonicalBytes(p)
    if type(p) ~= "table" then return nil, "INVALID_PROFILE" end
    if not isInt(p.widthBits) or p.widthBits < 8 or p.widthBits > 15 then return nil, "INVALID_WIDTH" end
    if type(p.mapId) ~= "string" or p.mapId == "" then return nil, "INVALID_MAP_ID" end
    for _, k in ipairs({ "typeFirstChannel", "typeNumChannels", "heightFirstChannel", "heightNumChannels" }) do
        if not isInt(p[k]) or p[k] < 0 then return nil, "INVALID_CHANNELS" end
    end
    if not isInt(p.integrationFlags) or p.integrationFlags < 0 then return nil, "INVALID_FLAGS" end
    if p.integrationFlags - (p.integrationFlags % 16) ~= 0 then return nil, "UNKNOWN_INTEGRATION_FLAG" end
    if not isInt(p.effectiveMaximumNativeIndex) or p.effectiveMaximumNativeIndex < 1 then return nil, "INVALID_MAXIMUM" end
    local names = p.names
    if type(names) ~= "table" or #names < 1 then return nil, "INVALID_NAMES" end
    local registeredCount = #names
    if registeredCount > 2 ^ p.widthBits - 1 then return nil, "COUNT_EXCEEDS_WIDTH" end
    local seen = {}
    local seq = { SGCanonicalProfile.LITERAL, SGCanonicalProfile.PROFILE_VERSION, p.widthBits, registeredCount, p.mapId,
        p.typeFirstChannel, p.typeNumChannels, p.heightFirstChannel, p.heightNumChannels,
        SGCanonicalProfile.MATERIAL_COUNTS, SGCanonicalProfile.STORAGE, p.integrationFlags, p.effectiveMaximumNativeIndex,
        registeredCount }
    for i = 1, registeredCount do
        local n = names[i]
        if type(n) ~= "string" or n == "" or seen[n] then return nil, "INVALID_NAME" end
        seen[n] = true
        seq[#seq + 1] = i
        seq[#seq + 1] = n
    end
    local ground = p.ground or {}
    seq[#seq + 1] = #ground
    local lastIndex, seenG = 0, {}
    for _, g in ipairs(ground) do
        if type(g) ~= "table" or not isInt(g.index) or g.index <= lastIndex or type(g.name) ~= "string" or g.name == "" or seenG[g.name] then
            return nil, "INVALID_GROUND"
        end
        lastIndex = g.index
        seenG[g.name] = true
        seq[#seq + 1] = g.index
        seq[#seq + 1] = g.name
        seq[#seq + 1] = g.canBeTipped and 1 or 0
    end
    local out = {}
    for _, v in ipairs(seq) do out[#out + 1] = scalar(v) end
    return table.concat(out), nil
end

--- Build the complete profile record: canonical bytes, digest and header fields.
function SGCanonicalProfile.build(p, formatFlags)
    local bytes, why = SGCanonicalProfile.canonicalBytes(p)
    if bytes == nil then return nil, why end
    if not isInt(formatFlags) or formatFlags < 0 or formatFlags > SGCanonicalProfile.KNOWN_FORMAT_MASK then return nil, "INVALID_FORMAT_FLAGS" end
    local octets, hex = SGSha256.digest(bytes)
    return {
        version = SGCanonicalProfile.PROFILE_VERSION,
        widthBits = p.widthBits,
        registeredCount = #p.names,
        formatFlags = formatFlags,
        digest = octets,
        digestHex = hex,
        canonical = bytes,
        mapId = p.mapId,
    }, nil
end

--- Compare two header records. Returns true, or false and the first
--- mismatched component name.
function SGCanonicalProfile.compare(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false, "header" end
    if a.magic ~= nil and a.magic ~= SGCanonicalProfile.HEADER_MAGIC then return false, "magic" end
    if b.magic ~= nil and b.magic ~= SGCanonicalProfile.HEADER_MAGIC then return false, "magic" end
    if a.version ~= b.version then return false, "version" end
    if a.widthBits ~= b.widthBits then return false, "width" end
    if a.registeredCount ~= b.registeredCount then return false, "registeredCount" end
    if a.formatFlags ~= b.formatFlags then return false, "formatFlags" end
    if type(a.digest) ~= "table" or type(b.digest) ~= "table" or #a.digest ~= 32 or #b.digest ~= 32 then return false, "digest" end
    for i = 1, 32 do
        if a.digest[i] ~= b.digest[i] then return false, "digest" end
    end
    return true, nil
end

-- =========================================================
-- Header codec (native stream primitives)
-- =========================================================
function SGCanonicalProfile.writeHeader(streamId, h)
    streamWriteInt32(streamId, SGCanonicalProfile.HEADER_MAGIC)
    streamWriteUInt8(streamId, h.version)
    streamWriteUInt8(streamId, h.widthBits)
    streamWriteUInt16(streamId, h.registeredCount)
    streamWriteUInt8(streamId, h.formatFlags)
    for i = 1, 32 do streamWriteUInt8(streamId, h.digest[i]) end
end

--- Read a header. Returns the record; validity is judged by compare().
function SGCanonicalProfile.readHeader(streamId)
    local h = {}
    h.magic = streamReadInt32(streamId)
    h.version = streamReadUInt8(streamId)
    h.widthBits = streamReadUInt8(streamId)
    h.registeredCount = streamReadUInt16(streamId)
    h.formatFlags = streamReadUInt8(streamId)
    h.digest = {}
    for i = 1, 32 do h.digest[i] = streamReadUInt8(streamId) end
    return h
end

--- Reserved format flags refuse.
function SGCanonicalProfile.headerIsWellFormed(h)
    if type(h) ~= "table" then return false end
    if h.magic ~= SGCanonicalProfile.HEADER_MAGIC then return false end
    if h.version ~= SGCanonicalProfile.PROFILE_VERSION then return false end
    if not isInt(h.widthBits) or h.widthBits < 8 or h.widthBits > 15 then return false end
    if not isInt(h.registeredCount) or h.registeredCount < 1 or h.registeredCount > 32767 then return false end
    if not isInt(h.formatFlags) or h.formatFlags < 0 or h.formatFlags > SGCanonicalProfile.KNOWN_FORMAT_MASK then return false end
    return type(h.digest) == "table" and #h.digest == 32
end
