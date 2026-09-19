-- fixture entry: attaches the hook its config declares
local function onLoad() end
Mission00.load = Utils.appendedFunction(Mission00.load, onLoad)
