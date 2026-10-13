-- =========================================================
-- FS25_StockGuard - one rebindable hook per engine method (MAINTENANCE row 187)
-- =========================================================
-- A mods reload at the main menu sources StockGuard again (reloadDlcsAndMods,
-- mods.lua:1173-1211), but the engine's own classes are sourced once per process and keep
-- whatever was written on them. On PC the mod also gets a FRESH environment
-- (loadModDesc, mods.lua:482-493): every module table and every "installed once" flag
-- starts over. On console the environment is reused (mods.lua:483-485), so the flags
-- survive while chunk locals do not. A wrapper that closes over the module that made it
-- then keeps calling that old module: a marker-guarded install skips and goes deaf, an
-- unguarded one stacks a second live copy.
--
-- THE RECORD. One table per engine class under K.KEY, "<name>#<id>" -> record:
--   { original, wrapper, around, owner }
-- The id names the hook site, so two sites on one method (the harvest drain bracket and
-- the save deferral on Combine.onUpdateTick) each keep their own wrapper, stacked in
-- install order, and each rebinds only itself.
-- The wrapper is a trampoline that reads its record when it is called and runs
-- record.around(record.original, ...). The first install wraps. Every later install, by
-- this module or by a re-sourced one, REBINDS around and owner on the same record: the
-- wrapper in the chain stays one, and the code that runs is always the newest install's.
-- `owner` names the module table that installed last, so K.boundTo tells a module whether
-- the live wrapper dispatches to it.
--
-- A PRE-FIX StockGuard's wrappers sit under older keys. They are not rebound: an install
-- here wraps on top of them. Class wrappers keyed by a marker then dispatch to an old
-- module whose host is gone, a pass-through; an old Utils.appendedFunction closure cannot
-- be unlinked by anyone, so a reload from a pre-fix version keeps its old copy until the
-- game restarts (the stated limit of row 187).
-- =========================================================

SGClassHook = SGClassHook or {}
local K = SGClassHook

K.KEY = "_sgClassHooks1"       -- a later record shape takes a new key and wraps on top

local function packn(...) return select("#", ...), { ... } end

local function records(class, create)
    local recs = rawget(class, K.KEY)
    if recs == nil and create then
        recs = {}
        rawset(class, K.KEY, recs)
    end
    return recs
end

local function slot(name, id) return name .. "#" .. tostring(id) end

--- Wrap class[name] for hook site `id` with around(original, ...), or rebind that site's
--- wrapper already there. Returns "INSTALLED" or "REBOUND", or false and the reason.
function K.wrap(class, name, id, around, owner)
    if type(class) ~= "table" or type(name) ~= "string" then return false, "NO_CLASS" end
    if type(id) ~= "string" or id == "" then return false, "NO_ID" end
    if type(around) ~= "function" then return false, "NO_AROUND" end
    local key = slot(name, id)
    local recs = records(class, false)
    local rec = recs ~= nil and recs[key] or nil
    if rec ~= nil then
        rec.around, rec.owner = around, owner
        return "REBOUND"
    end
    if type(class[name]) ~= "function" then return false, "NO_METHOD" end
    recs = records(class, true)
    rec = { original = class[name], around = around, owner = owner }
    rec.wrapper = function(...)
        local live = recs[key]
        return live.around(live.original, ...)
    end
    recs[key] = rec
    class[name] = rec.wrapper
    return "INSTALLED"
end

--- Utils.appendedFunction's shape (utils/Utils.lua: the original, then fn; no returns).
function K.append(class, name, id, fn, owner)
    return K.wrap(class, name, id, function(original, ...)
        original(...)
        fn(...)
    end, owner)
end

--- Utils.prependedFunction's shape (fn, then the original; no returns).
function K.prepend(class, name, id, fn, owner)
    return K.wrap(class, name, id, function(original, ...)
        fn(...)
        original(...)
    end, owner)
end

--- Utils.overwrittenFunction's shape (fn(self, original, ...), its returns).
function K.overwrite(class, name, id, fn, owner)
    return K.wrap(class, name, id, function(original, self, ...)
        return fn(self, original, ...)
    end, owner)
end

--- around with every return of the original kept: before(...) runs first, after(r, ...)
--- sees the packed returns.
function K.around(before, after)
    return function(original, ...)
        if before ~= nil then before(...) end
        local n, r = packn(original(...))
        if after ~= nil then after(r, ...) end
        return unpack(r, 1, n)
    end
end

--- Restore the original while the wrapper is still the method's value; otherwise leave it
--- in place (a later wrapper sits above it) and keep the record. Returns whether restored.
function K.unwrap(class, name, id)
    local recs = type(class) == "table" and records(class, false) or nil
    local rec = recs ~= nil and recs[slot(name, id)] or nil
    if rec == nil then return false, "NOT_INSTALLED" end
    if class[name] ~= rec.wrapper then return false, "WRAPPED_BY_ANOTHER" end
    class[name] = rec.original
    recs[slot(name, id)] = nil
    return true
end

--- Does the live wrapper of class[name] dispatch to `owner`?
function K.boundTo(class, name, id, owner)
    local recs = type(class) == "table" and records(class, false) or nil
    local rec = recs ~= nil and recs[slot(name, id)] or nil
    return rec ~= nil and rec.owner == owner and owner ~= nil
end

--- The record of class[name], for diagnostics and the bench.
function K.record(class, name, id)
    local recs = type(class) == "table" and records(class, false) or nil
    return recs ~= nil and recs[slot(name, id)] or nil
end
