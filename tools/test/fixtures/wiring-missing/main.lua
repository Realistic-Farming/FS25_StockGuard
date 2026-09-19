-- fixture entry: declares a hook in its config and never attaches it
local function onLoad() end
-- the append is deliberately absent
local _ = onLoad
