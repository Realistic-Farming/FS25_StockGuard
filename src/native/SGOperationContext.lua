-- =========================================================
-- FS25_StockGuard - call-scoped operation context (SG2-1 kernel)
-- =========================================================
-- One transient context per (binding generation, primitive ordinal), opened
-- before a native mutation and closed after it, holding the observations that
-- belong to THAT call and nothing else.
--
-- WHY THIS EXISTS RATHER THAN A MODULE-LEVEL "CURRENT OPERATION". A single
-- current-operation variable is the obvious shape and it is wrong here in two
-- separate ways.
--
-- First, these calls NEST. A processing function can drive a fill-unit change
-- which drives a storage change, and each of those is a native mutation we
-- observe. With one shared slot the inner call's observations land on the outer
-- call's record, and the outer call then settles quantities it never caused.
-- So frames are a stack: a nested frame merges only its EXPLICIT outputs upward,
-- never its raw observations, and there is no global pending sample for a later
-- call to pick up by accident.
--
-- Second, a native call can THROW. WorkArea.lua:183 has no pcall around the
-- processing function, so a throw abandons the rest of onUpdateTick. A shared
-- slot left set by an abandoned call is then read by the NEXT call as if it were
-- its own, which is worse than losing the observation: it attributes real
-- material movement to the wrong operation. Frames are closed by the bracket
-- whether the native call returned or threw, and closing an inner frame while an
-- outer one is still open is the normal case rather than an error.
--
-- WHAT A CONTEXT IS NOT. It is not a quantity store and it holds no stock. It
-- carries observations until the bracket settles them through SG-1, and it is
-- discarded on close. Nothing outside a bracket may hold a reference to a frame
-- past its close; the depth/ordinal identity exists so a caller can prove which
-- call it is in, not so a frame can be resurrected.

SGOperationContext = SGOperationContext or {}
local C = SGOperationContext

C.MAX_DEPTH = 8   -- a native chain deeper than this is a bug, not a farm

--- A fresh, empty stack. One per mission; the caller owns it.
function C.new()
    return {
        frames    = {},
        depth     = 0,
        ordinal   = 0,      -- monotonic per stack, so every frame has an identity
        overflows = 0,      -- frames refused for depth, surfaced rather than hidden
    }
end

--- Open a frame for one native primitive.
---
--- `binding` identifies the physical thing being mutated (a vehicle, a storage,
--- a placeable). `kind` names the primitive. Neither is interpreted here; they
--- travel so the settling code can prove which call an observation came from.
---
--- Returns nil when the stack is already at MAX_DEPTH. A nil frame is a refusal
--- to observe, NOT a refusal to let the native work happen: the caller carries on
--- and the material moves, it is simply unobserved, which is the honest outcome
--- when we cannot tell whose call we are in.
---@return table|nil frame
function C.open(stack, binding, kind)
    if type(stack) ~= "table" then return nil end
    if stack.depth >= C.MAX_DEPTH then
        stack.overflows = stack.overflows + 1
        return nil
    end

    stack.ordinal = stack.ordinal + 1
    local frame = {
        ordinal      = stack.ordinal,
        depth        = stack.depth + 1,
        binding      = binding,
        kind         = kind,
        observations = {},   -- raw, this frame's own, never merged upward
        outputs      = {},   -- explicit results, the ONLY thing a parent sees
        closed       = false,
    }
    stack.depth = stack.depth + 1
    stack.frames[stack.depth] = frame
    return frame
end

--- The frame currently being observed, or nil outside any bracket.
function C.current(stack)
    if type(stack) ~= "table" or stack.depth == 0 then return nil end
    return stack.frames[stack.depth]
end

--- Record one observation against the CURRENT frame.
---
--- Refuses silently outside a bracket. That is deliberate: a native mutation we
--- did not bracket is one whose operation we cannot name, and attributing it to
--- whatever frame happens to be open would be worse than not recording it.
---@return boolean recorded
function C.observe(stack, observation)
    local frame = C.current(stack)
    if frame == nil or frame.closed then return false end
    frame.observations[#frame.observations + 1] = observation
    return true
end

--- Publish an explicit output from the current frame. Outputs are the only thing
--- that crosses a frame boundary.
---@return boolean published
function C.publish(stack, output)
    local frame = C.current(stack)
    if frame == nil or frame.closed then return false end
    frame.outputs[#frame.outputs + 1] = output
    return true
end

--- Close a frame and hand back what it observed.
---
--- Closing is BY FRAME, not "close the top", because a bracket must be able to
--- close its own frame even if something below it failed to close first. An
--- out-of-order close unwinds everything above it, marking those frames abandoned,
--- since their brackets cannot now settle them coherently.
---
--- A nested frame's OUTPUTS merge into its parent. Its raw observations do not:
--- the parent did not cause them and must not settle them.
---@return table|nil frame, number unwound
function C.close(stack, frame)
    if type(stack) ~= "table" or type(frame) ~= "table" then return nil, 0 end
    if frame.closed then return frame, 0 end

    local unwound = 0
    while stack.depth > frame.depth do
        local abandoned = stack.frames[stack.depth]
        if abandoned ~= nil then
            abandoned.closed = true
            abandoned.abandoned = true
        end
        stack.frames[stack.depth] = nil
        stack.depth = stack.depth - 1
        unwound = unwound + 1
    end

    if stack.frames[stack.depth] ~= frame then
        -- The frame is not on this stack at its stated depth. Close it in place
        -- rather than corrupting the stack to make it fit.
        frame.closed = true
        return frame, unwound
    end

    frame.closed = true
    stack.frames[stack.depth] = nil
    stack.depth = stack.depth - 1

    local parent = C.current(stack)
    if parent ~= nil and not parent.closed then
        for _, out in ipairs(frame.outputs) do
            parent.outputs[#parent.outputs + 1] = out
        end
    end
    return frame, unwound
end

--- True when nothing is open. The bracket asserts this between passes; a stack
--- that never returns to rest is a bracket that is not closing.
function C.isAtRest(stack)
    return type(stack) == "table" and stack.depth == 0
end
