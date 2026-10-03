-- =========================================================
-- Stock Guard Field Guide - Field Guide
-- =========================================================
-- REPAIR-209: StockGuard was the only framework guest with no onOpenHelp and no dialog of its own, so the
-- Esc Help footer button appeared on Stock (REPAIR-207 put stockGuard into the host's isFw set) and did
-- nothing at all. RfPdaMenuPage.onClickHelpFw asks the showing module to open its OWN guide and ignores
-- any return value, so Help has to be a dialog, not a returned table.
-- The chrome is FdGuideDialog's, which is SoilGuideDialog's, so every Realistic Farming guide reads as one
-- family; only the words differ.
-- Rows are { t = "H" | "B" | "S" | "COL", v = "text" }: header, body, spacer, column break.
-- =========================================================

---@class SgGuideDialog
SgGuideDialog = SgGuideDialog or {}
local SgGuideDialog_mt = Class(SgGuideDialog, ScreenElement)

local GUIDE_MOD_DIR = (StockGuardModDirectory or g_currentModDirectory)

SgGuideDialog.INSTANCE = nil
SgGuideDialog.GUI_NAME = "SgGuideDialog"

SgGuideDialog.SUBTITLES = {
    "Overview - what Stock Guard watches and what this page is",
    "Reading The Page - columns, rows, scrolling and the detail line",
    "Doing Things - actions, selectors, and common questions",
}

SgGuideDialog.PAGE1 = {
    { t="H", v="WHAT STOCK GUARD DOES" },
    { t="B", v="Stock Guard keeps track of the goods your" },
    { t="B", v="farm is holding and where they are being" },
    { t="B", v="held: in a trailer, in a silo, in a" },
    { t="B", v="production building." },
    { t="S", v=" " },
    { t="B", v="It is a record keeper. It watches what the" },
    { t="B", v="game already has and writes down what it" },
    { t="B", v="sees." },
    { t="S", v=" " },
    { t="H", v="WHAT THIS PAGE IS" },
    { t="B", v="This is the quiet view of that record. It" },
    { t="B", v="lists what is held right now, how much, and" },
    { t="B", v="how sure Stock Guard is about where it came" },
    { t="B", v="from." },
    { t="S", v=" " },
    { t="B", v="Anything that can be done from here is" },
    { t="B", v="offered as a chip at the bottom, and only" },
    { t="B", v="when it is genuinely available." },
    { t="COL", v="" },
    { t="H", v="OPENING THE PAGE" },
    { t="B", v="Press Esc for the in game menu, then pick" },
    { t="B", v="the Realistic Farming tab in the top row." },
    { t="S", v=" " },
    { t="B", v="A list of modules runs down the left side." },
    { t="B", v="Click STOCK in that list." },
    { t="S", v=" " },
    { t="H", v="IF THE TABLE IS EMPTY" },
    { t="B", v="An empty table is not the same as an empty" },
    { t="B", v="farm. The page says which it is." },
    { t="S", v=" " },
    { t="B", v="Updating means the server has been asked" },
    { t="B", v="and has not answered yet. Nothing listed" },
    { t="B", v="means the view really is empty. Cannot view" },
    { t="B", v="means this farm is not allowed to see it." },
    { t="S", v=" " },
    { t="B", v="Not available means Stock Guard itself is" },
    { t="B", v="not ready. That one usually clears on its" },
    { t="B", v="own in a moment." },
}

SgGuideDialog.PAGE2 = {
    { t="H", v="THE FOUR COLUMNS" },
    { t="B", v="Name: what the line is. For stock that is" },
    { t="B", v="the product; for a carrier or a process it" },
    { t="B", v="is the thing holding or making it." },
    { t="S", v=" " },
    { t="B", v="Amount: how much, with its unit. The unit" },
    { t="B", v="is inside this figure and is not repeated" },
    { t="B", v="in a column of its own." },
    { t="S", v=" " },
    { t="B", v="Status: for a stock line this is how well" },
    { t="B", v="its origin is known. For a carrier or a" },
    { t="B", v="process it is whether it is ready, partial," },
    { t="B", v="disabled or unavailable." },
    { t="S", v=" " },
    { t="B", v="Kind: Stock, Carrier, Process or Note." },
    { t="COL", v="" },
    { t="H", v="WHAT UNKNOWN MEANS" },
    { t="B", v="Unknown is about where the goods came from," },
    { t="B", v="not how much there is. The amount beside it" },
    { t="B", v="is the real, current figure read from the" },
    { t="B", v="vehicle or the store." },
    { t="S", v=" " },
    { t="B", v="So Unknown next to two thousand litres" },
    { t="B", v="means: two thousand litres are there, and" },
    { t="B", v="Stock Guard has no record of their origin." },
    { t="S", v=" " },
    { t="B", v="Known, Partial and Historical are the same" },
    { t="B", v="idea with more of the story recorded." },
    { t="S", v=" " },
    { t="H", v="REACHING EVERY ROW" },
    { t="B", v="The table scrolls. Use the mouse wheel or" },
    { t="B", v="the slider beside it." },
    { t="S", v=" " },
    { t="B", v="The comma and period keys move the" },
    { t="B", v="highlighted row one at a time. The count" },
    { t="B", v="line under the table names those keys." },
    { t="S", v=" " },
    { t="H", v="THE DETAIL LINE" },
    { t="B", v="Under the table, the highlighted row is" },
    { t="B", v="written out in full: its whole name, its" },
    { t="B", v="facts, and what each action would do." },
}

SgGuideDialog.PAGE3 = {
    { t="H", v="THE ACTION CHIPS" },
    { t="B", v="Up to three chips sit under the table. They" },
    { t="B", v="belong to the highlighted row, so changing" },
    { t="B", v="the row changes the chips." },
    { t="S", v=" " },
    { t="B", v="A chip only appears when the view is ready" },
    { t="B", v="and a row is highlighted. If an action" },
    { t="B", v="cannot be used, the chip says so and the" },
    { t="B", v="detail line gives the reason." },
    { t="S", v=" " },
    { t="B", v="More actions appears when a row publishes" },
    { t="B", v="more than three. Clicking it brings the" },
    { t="B", v="next ones round." },
    { t="S", v=" " },
    { t="H", v="OFFERS YOU CONFIRM" },
    { t="B", v="Some actions come back with an offer and a" },
    { t="B", v="countdown. Confirm and Cancel appear beside" },
    { t="B", v="it. Nothing happens until you confirm." },
    { t="COL", v="" },
    { t="H", v="THE TWO SELECTORS" },
    { t="B", v="A selector above the table picks which" },
    { t="B", v="place to show. It only appears when there" },
    { t="B", v="is more than one place to choose, because" },
    { t="B", v="one option is not a choice." },
    { t="S", v=" " },
    { t="B", v="A second selector appears at the bottom" },
    { t="B", v="only when the highlighted row can have its" },
    { t="B", v="output set, and it lists the outputs that" },
    { t="B", v="row actually offers." },
    { t="S", v=" " },
    { t="H", v="COMMON QUESTIONS" },
    { t="B", v="Why does every line say Unknown? Stock" },
    { t="B", v="Guard reads live holdings fresh when it has" },
    { t="B", v="no saved record for them. See page two." },
    { t="S", v=" " },
    { t="B", v="Why is a chip greyed out? The detail line" },
    { t="B", v="under the table gives the reason for that" },
    { t="B", v="row and that action." },
    { t="S", v=" " },
    { t="B", v="Is it multiplayer safe? Yes. The server" },
    { t="B", v="decides every action and every reading." },
}

SgGuideDialog.PAGE_CONTENT = { SgGuideDialog.PAGE1, SgGuideDialog.PAGE2, SgGuideDialog.PAGE3 }

-- -- Constructor ------------------------------------------

function SgGuideDialog.new(target, customMt)
    local self = ScreenElement.new(target, customMt or SgGuideDialog_mt)
    self._contentLineEls = {}
    self._currentPage = 1
    return self
end

--- Loads the dialog into g_gui once. Safe to call twice, and safe to call when some other path has
--- already registered the same name.
function SgGuideDialog.register(modDirectory)
    if g_gui == nil then return end
    if g_gui.guis ~= nil and g_gui.guis[SgGuideDialog.GUI_NAME] ~= nil then return end
    if modDirectory ~= nil then GUIDE_MOD_DIR = modDirectory end
    if GUIDE_MOD_DIR == nil then return end
    SgGuideDialog.INSTANCE = SgGuideDialog.new()
    local ok, err = pcall(function()
        g_gui:loadGui(GUIDE_MOD_DIR .. "xml/gui/SgGuideDialog.xml", SgGuideDialog.GUI_NAME,
            SgGuideDialog.INSTANCE)
    end)
    if not ok then
        print("[StockGuard] SgGuideDialog: loadGui failed: " .. tostring(err))
        SgGuideDialog.INSTANCE = nil
    end
end

function SgGuideDialog.show()
    if g_gui == nil then return end
    local loaded = g_gui.guis ~= nil and g_gui.guis[SgGuideDialog.GUI_NAME] ~= nil
    if not loaded then
        SgGuideDialog.register(GUIDE_MOD_DIR)
        loaded = g_gui.guis ~= nil and g_gui.guis[SgGuideDialog.GUI_NAME] ~= nil
    end
    if not loaded then return end
    -- REPAIR-211: one line, so a live test of X HELP can be settled from the log instead of from a
    -- screenshot. register() prints only on failure and showDialog is silent, so without this the only
    -- evidence that Help worked is a player saying so.
    print("[StockGuard] SgGuideDialog: opening the field guide")
    g_gui:showDialog(SgGuideDialog.GUI_NAME)
end

-- -- Lifecycle --------------------------------------------

function SgGuideDialog:onGuiSetupFinished()
    SgGuideDialog:superClass().onGuiSetupFinished(self)
    self._elCol1 = self:getDescendantById("sgGuide_col1")
    self._elCol2 = self:getDescendantById("sgGuide_col2")
    self._elSubtitle = self:getDescendantById("sgGuide_subtitle")
end

function SgGuideDialog:onOpen()
    SgGuideDialog:superClass().onOpen(self)
    self._currentPage = 1
    self:_selectPage(1)
end

function SgGuideDialog:onClose()
    SgGuideDialog:superClass().onClose(self)
    self:_clearContent()
    self._currentPage = 1
end

-- -- Tabs -------------------------------------------------

function SgGuideDialog:onClickTab1() self:_selectPage(1) end
function SgGuideDialog:onClickTab2() self:_selectPage(2) end
function SgGuideDialog:onClickTab3() self:_selectPage(3) end

function SgGuideDialog:_selectPage(pageNum)
    if self._currentPage == pageNum and #self._contentLineEls > 0 then return end
    self:_clearContent()
    self._currentPage = pageNum
    if self._elSubtitle ~= nil then
        self._elSubtitle:setText(SgGuideDialog.SUBTITLES[pageNum] or "")
    end
    self:_buildContent(pageNum)
end

-- -- Content ----------------------------------------------

function SgGuideDialog:_buildContent(pageNum)
    local profileH = g_gui:getProfile("sgGuide_colHeader")
    local profileB = g_gui:getProfile("sgGuide_colBody")
    local profileS = g_gui:getProfile("sgGuide_colSpacer")
    if not profileH or not profileB then
        print("[StockGuard] SgGuideDialog: column profiles not found")
        return
    end
    local content = SgGuideDialog.PAGE_CONTENT[pageNum]
    if content == nil then return end
    local currentBox = self._elCol1
    for _, row in ipairs(content) do
        if row.t == "COL" then
            if self._elCol1 ~= nil then self._elCol1:invalidateLayout() end
            currentBox = self._elCol2
        elseif currentBox ~= nil then
            local profile = (row.t == "H") and profileH
                         or (row.t == "S") and profileS
                         or profileB
            if profile ~= nil then
                local el = TextElement.new()
                el:loadProfile(profile, true)
                el:setText(row.v or "")
                currentBox:addElement(el)
                el:onGuiSetupFinished()
                table.insert(self._contentLineEls, { box = currentBox, el = el })
            end
        end
    end
    if self._elCol2 ~= nil then self._elCol2:invalidateLayout() end
end

function SgGuideDialog:_clearContent()
    for _, entry in ipairs(self._contentLineEls or {}) do
        if entry.box ~= nil then
            entry.box:removeElement(entry.el)
        end
    end
    self._contentLineEls = {}
    if self._elCol1 ~= nil then self._elCol1:invalidateLayout() end
    if self._elCol2 ~= nil then self._elCol2:invalidateLayout() end
end

-- -- Button -----------------------------------------------

function SgGuideDialog:onClickClose()
    g_gui:closeDialogByName(SgGuideDialog.GUI_NAME)
end
