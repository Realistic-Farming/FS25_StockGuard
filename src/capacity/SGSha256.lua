-- =========================================================
-- FS25_StockGuard - SHA-256 (SG-6)
-- =========================================================
-- An explicit, deterministic SHA-256 over a Lua string, returning the 32
-- raw octets as a table of integers 0..255 and as a lowercase hex string.
-- No native SHA API is guessed. Verified against the standard vectors in
-- the bench (empty string, "abc", the 56-byte two-block vector).
--
-- Bit operations use bit32 when the runtime has it (FS25 Lua 5.1 ships it;
-- Storage.lua uses bit32.band) and fall back to an arithmetic
-- implementation otherwise, so the same digest is produced under the
-- fengari bench.
-- =========================================================

SGSha256 = SGSha256 or {}

local MOD = 4294967296

local band, bor, bxor, bnot, rshift, lshift

if bit32 ~= nil then
    band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
    rshift, lshift = bit32.rshift, bit32.lshift
else
    -- Arithmetic fallback. Every input is first reduced to a non-negative
    -- float below 2^32 (runtimes with 32-bit integers wrap intermediates
    -- negative, and a floor division of a negative value is not a logical
    -- shift), and all accumulation stays in floats, exact below 2^53.
    local function norm(x) return x % MOD end
    local function bitop(a, b, f)
        a, b = norm(a), norm(b)
        local result, bitv = 0.0, 1.0
        for _ = 1, 32 do
            local abit, bbit = a % 2, b % 2
            if f(abit, bbit) == 1 then result = result + bitv end
            a = (a - abit) / 2
            b = (b - bbit) / 2
            bitv = bitv * 2
        end
        return result
    end
    band = function(a, b) return bitop(a, b, function(x, y) return (x == 1 and y == 1) and 1 or 0 end) end
    bor  = function(a, b) return bitop(a, b, function(x, y) return (x == 1 or y == 1) and 1 or 0 end) end
    bxor = function(a, b) return bitop(a, b, function(x, y) return (x ~= y) and 1 or 0 end) end
    bnot = function(a) return MOD - 1 - norm(a) end
    rshift = function(a, n) return math.floor(norm(a) / 2 ^ n) end
    lshift = function(a, n) return (norm(a) * 2 ^ n) % MOD end
end

local function rrot(x, n)
    return bor(rshift(x, n), lshift(x, 32 - n)) % MOD
end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function preprocess(msg)
    local len = #msg
    local bitLen = len * 8
    local padded = msg .. string.char(0x80)
    while (#padded % 64) ~= 56 do padded = padded .. string.char(0) end
    -- 64-bit big-endian length (messages here are far below 2^32 bits).
    local hi = math.floor(bitLen / MOD)
    local lo = bitLen % MOD
    local function be32(v)
        return string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256)
    end
    return padded .. be32(hi) .. be32(lo)
end

--- Digest a string. Returns octets (table of 32 integers) and hex.
function SGSha256.digest(msg)
    if type(msg) ~= "string" then return nil, nil end
    local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    local data = preprocess(msg)
    local w = {}
    for chunk = 1, #data, 64 do
        for i = 0, 15 do
            local b1, b2, b3, b4 = data:byte(chunk + i * 4, chunk + i * 4 + 3)
            w[i] = ((b1 * 256.0 + b2) * 256.0 + b3) * 256.0 + b4
        end
        for i = 16, 63 do
            local s0 = bxor(bxor(rrot(w[i - 15], 7), rrot(w[i - 15], 18)), rshift(w[i - 15], 3))
            local s1 = bxor(bxor(rrot(w[i - 2], 17), rrot(w[i - 2], 19)), rshift(w[i - 2], 10))
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % MOD
        end
        local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
        for i = 0, 63 do
            local S1 = bxor(bxor(rrot(e, 6), rrot(e, 11)), rrot(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = (h + S1 + ch + K[i + 1] + w[i]) % MOD
            local S0 = bxor(bxor(rrot(a, 2), rrot(a, 13)), rrot(a, 22))
            local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
            local temp2 = (S0 + maj) % MOD
            h = g; g = f; f = e
            e = (d + temp1) % MOD
            d = c; c = b; b = a
            a = (temp1 + temp2) % MOD
        end
        H[1] = (H[1] + a) % MOD; H[2] = (H[2] + b) % MOD; H[3] = (H[3] + c) % MOD; H[4] = (H[4] + d) % MOD
        H[5] = (H[5] + e) % MOD; H[6] = (H[6] + f) % MOD; H[7] = (H[7] + g) % MOD; H[8] = (H[8] + h) % MOD
    end
    local octets, hex = {}, {}
    for i = 1, 8 do
        local v = H[i]
        for shift = 3, 0, -1 do
            local byte = math.floor(v / 256 ^ shift) % 256
            octets[#octets + 1] = byte
            hex[#hex + 1] = string.format("%02x", byte)
        end
    end
    return octets, table.concat(hex)
end
