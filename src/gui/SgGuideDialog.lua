-- =========================================================
-- Stock Guard Field Guide - Field Guide
-- =========================================================
-- StockGuard was the only framework guest with no onOpenHelp and no dialog of its own, so the
-- Esc Help footer button appeared on Stock, because the host's isFw set includes stockGuard, and did
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
    "Reading The Page - the two pages, the columns, the order, the units, the detail line",
    "Doing Things - the selector, the action chip, offers, and common questions",
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
    { t="B", v="lists what is held right now, how much of" },
    { t="B", v="it, and how many places are holding it." },
    { t="S", v=" " },
    { t="B", v="It does not price stock and it does not" },
    { t="B", v="sell anything. Pricing belongs to Market" },
    { t="B", v="Dynamics." },
    { t="COL", v="" },
    { t="H", v="THE TWO PAGES" },
    { t="B", v="Products is the farm's stock, one line per" },
    { t="B", v="product, largest first." },
    { t="S", v=" " },
    { t="B", v="Storages opens one product and lists the" },
    { t="B", v="places holding it. It follows whichever" },
    { t="B", v="product is highlighted on Products." },
    { t="S", v=" " },
    { t="B", v="The selector above the table moves between" },
    { t="B", v="the two." },
    { t="S", v=" " },
    { t="H", v="OPENING THE PAGE" },
    { t="B", v="Press Esc for the in game menu, then pick" },
    { t="B", v="the Realistic Farming tab in the top row." },
    { t="B", v="A list of modules runs down the left side." },
    { t="B", v="Click STOCK in that list." },
    { t="S", v=" " },
    { t="H", v="IF THE TABLE IS EMPTY" },
    { t="B", v="An empty table is not the same as an empty" },
    { t="B", v="farm. The page says which it is." },
    { t="S", v=" " },
    { t="B", v="Updating means the server has been asked" },
    { t="B", v="and has not answered yet. Nothing listed" },
    { t="B", v="means the view really is empty. Cannot" },
    { t="B", v="view means this farm may not see it. Not" },
    { t="B", v="available means Stock Guard itself is not" },
    { t="B", v="ready, and that usually clears on its own." },
}

SgGuideDialog.PAGE2 = {
    { t="H", v="THE PRODUCTS PAGE" },
    { t="B", v="Product: what the line is." },
    { t="S", v=" " },
    { t="B", v="Amount: how much the farm holds, added up" },
    { t="B", v="across every place holding it. The unit is" },
    { t="B", v="inside this figure, not in a column of its" },
    { t="B", v="own." },
    { t="S", v=" " },
    { t="B", v="Holders: how many places hold it." },
    { t="S", v=" " },
    { t="H", v="THE STORAGES PAGE" },
    { t="B", v="Holder: the thing holding it, named with" },
    { t="B", v="the product inside it." },
    { t="S", v=" " },
    { t="B", v="Amount: how much is in that one place." },
    { t="S", v=" " },
    { t="B", v="Where: the place itself." },
    { t="S", v=" " },
    { t="H", v="LARGEST FIRST" },
    { t="B", v="Both lists put the largest amount at the" },
    { t="B", v="top, and so do the places under a product." },
    { t="S", v=" " },
    { t="B", v="Amounts in litres are compared with each" },
    { t="B", v="other and come first. Anything counted in" },
    { t="B", v="another unit sorts after them, grouped by" },
    { t="B", v="unit, because two figures in different" },
    { t="B", v="units are not the same measurement." },
    { t="COL", v="" },
    { t="H", v="THE UNITS" },
    { t="B", v="Dry goods read in tonnes, or kilograms" },
    { t="B", v="when small, if British Fill Units is on." },
    { t="S", v=" " },
    { t="B", v="Liquids read in litres. Bales and pallets" },
    { t="B", v="are counted as bales and pallets. A unit" },
    { t="B", v="that is not known is shown in brackets." },
    { t="S", v=" " },
    { t="H", v="THE DETAIL LINE" },
    { t="B", v="Under the table the highlighted row is" },
    { t="B", v="written out in full, and the two pages" },
    { t="B", v="write out different things." },
    { t="S", v=" " },
    { t="B", v="On Products: the total, how many holders," },
    { t="B", v="and a line saying the sale estimate comes" },
    { t="B", v="from Market Dynamics, not from here." },
    { t="S", v=" " },
    { t="B", v="On Storages: the full name, the kind, the" },
    { t="B", v="amount, how well the origin is known, and" },
    { t="B", v="the farm it is for, then every action the" },
    { t="B", v="row offers and whether it can be used." },
    { t="S", v=" " },
    { t="H", v="WHAT UNKNOWN MEANS" },
    { t="B", v="Unknown is about where goods came from," },
    { t="B", v="not how much there is: the amount beside" },
    { t="B", v="it is the real figure from the store." },
    { t="S", v=" " },
    { t="B", v="Known, Partial and Historical are the same" },
    { t="B", v="idea with more of the story recorded." },
}

SgGuideDialog.PAGE3 = {
    { t="H", v="REACHING EVERY ROW" },
    { t="B", v="The table scrolls. Use the mouse wheel or" },
    { t="B", v="the slider beside it." },
    { t="S", v=" " },
    { t="B", v="The comma and period keys move the" },
    { t="B", v="highlighted row one at a time. The count" },
    { t="B", v="line under the table names those keys." },
    { t="S", v=" " },
    { t="H", v="THE SELECTOR" },
    { t="B", v="The selector above the table carries the" },
    { t="B", v="page: Products or Storages. It does not" },
    { t="B", v="pick a farm or a site. STOCK always shows" },
    { t="B", v="the whole farm." },
    { t="S", v=" " },
    { t="B", v="Storages needs a product, and it takes the" },
    { t="B", v="one highlighted on Products. With no" },
    { t="B", v="product at all the page still opens, and" },
    { t="B", v="its hint says why it is empty." },
    { t="H", v="THE ACTION CHIPS" },
    { t="B", v="A chip under the table names the action" },
    { t="B", v="for the highlighted row, and pressing it" },
    { t="B", v="runs that action." },
    { t="S", v=" " },
    { t="B", v="When the row offers more than one, a Next" },
    { t="B", v="action chip appears and steps through" },
    { t="B", v="them, saying which you are on as 1/3." },
    { t="S", v=" " },
    { t="B", v="A greyed chip says why in brackets." },
    { t="COL", v="" },
    { t="H", v="OFFERS YOU CONFIRM" },
    { t="B", v="Some actions come back as an offer with" },
    { t="B", v="its cost and a countdown, and Confirm and" },
    { t="B", v="Cancel appear beside it. Nothing happens" },
    { t="B", v="until you confirm. The banner above says" },
    { t="B", v="whether it was sent, accepted, or done." },
    { t="S", v=" " },
    { t="H", v="SETTING AN OUTPUT" },
    { t="B", v="A second selector appears only when the" },
    { t="B", v="highlighted row can have its output set," },
    { t="B", v="and it lists the outputs that row offers." },
    { t="S", v=" " },
    { t="H", v="COMMON QUESTIONS" },
    { t="B", v="Why does a line say Unknown? Stock Guard" },
    { t="B", v="reads live holdings fresh when it has no" },
    { t="B", v="saved record for them. See page two." },
    { t="S", v=" " },
    { t="B", v="Where is the sale value, the best buyer" },
    { t="B", v="and the peak? Taken out. This page does" },
    { t="B", v="not price stock; Market Dynamics does." },
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
    -- One line, so a live test of X HELP can be settled from the log instead of from a
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
