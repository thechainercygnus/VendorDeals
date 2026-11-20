local PAGE_SIZE = 12
local BATCH_SIZE = 100
local SCAN_COOLDOWN = 15 * 60
local RESPONSE_TIMEOUT = 45
local ITEM_TIMEOUT = 5

local events = CreateFrame("Frame")
local panel, scanButton, status, previousButton, nextButton, pageText
local toggleButton
local rows = {}
local results = {}
local page = 1
local activeScan
local lastSnapshot
local auctionHouseOpen
local usingAuctionator
local auctionatorListener

local function Money(copper)
    local gold = math.floor(copper / 10000)
    local silver = math.floor(copper / 100) % 100
    local remainder = copper % 100
    if gold > 0 then
        return ("%dg %02ds %02dc"):format(gold, silver, remainder)
    elseif silver > 0 then
        return ("%ds %02dc"):format(silver, remainder)
    end
    return ("%dc"):format(remainder)
end

local function DrawPage()
    local pages = math.max(1, math.ceil(#results / PAGE_SIZE))
    page = math.min(page, pages)
    for index, row in ipairs(rows) do
        local deal = results[(page - 1) * PAGE_SIZE + index]
        row.deal = deal
        if deal then
            row.name:SetText(deal.name)
            row.quantity:SetText(deal.quantity)
            row.buyout:SetText(Money(deal.buyout))
            row.vendor:SetText(Money(deal.vendor))
            row.profit:SetText(Money(deal.profit))
        end
        row:SetShown(deal ~= nil)
    end
    pageText:SetText(("%d / %d"):format(page, pages))
    previousButton:SetEnabled(page > 1)
    nextButton:SetEnabled(page < pages)
end

local function FinishScan(scan)
    if activeScan ~= scan then return end
    activeScan = nil
    events:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
    scanButton:Enable()
    results = scan.deals
    table.sort(results, function(a, b)
        if a.profit ~= b.profit then return a.profit > b.profit end
        if a.buyout ~= b.buyout then return a.buyout < b.buyout end
        return a.index < b.index
    end)
    page = 1
    local summary = ("%d deals across %d listings at %s"):format(#results, scan.total, date("%H:%M"))
    if scan.skipped > 0 then
        summary = summary .. (" · %d unavailable"):format(scan.skipped)
    end
    status:SetText(summary)
    DrawPage()
end

local function CompareListing(scan, listing, item)
    local vendor = item.sellPrice * listing.quantity
    if vendor > listing.buyout then
        listing.vendor = vendor
        listing.profit = vendor - listing.buyout
        listing.name = listing.name or item.name
        listing.link = listing.link or item.link
        table.insert(scan.deals, listing)
    end
end

local function ReadVendorInfo(itemID)
    local name, link, _, _, _, _, _, _, _, _, sellPrice = C_Item.GetItemInfo(itemID)
    if name and sellPrice ~= nil then
        return { name = name, link = link, sellPrice = sellPrice }
    end
end

local function ResolvePending(scan, itemID, success)
    local listings = scan.pending[itemID]
    if not listings then return end
    scan.pending[itemID] = nil

    local item = success and ReadVendorInfo(itemID)
    if item then
        scan.items[itemID] = item
        for _, listing in ipairs(listings) do
            CompareListing(scan, listing, item)
        end
    else
        scan.items[itemID] = false
        scan.skipped = scan.skipped + #listings
    end
    if scan.readComplete and not next(scan.pending) then
        FinishScan(scan)
    end
end

local function CompareAuction(scan, index, link, name, _, quantity, _, _, _, _, _, _, buyout, _, _, _, owner, ownerFullName, _, itemID)
    if not buyout or buyout <= 0 or not quantity or quantity <= 0 then return end
    if ownerFullName == scan.playerFullName or (not ownerFullName and owner == scan.playerName) then return end
    if not itemID or itemID <= 0 then
        scan.skipped = scan.skipped + 1
        return
    end

    if scan.items[itemID] == nil and not scan.pending[itemID] then
        scan.items[itemID] = ReadVendorInfo(itemID)
        if not scan.items[itemID] and not C_Item.DoesItemExistByID(itemID) then
            scan.items[itemID] = false
        end
    end
    local item = scan.items[itemID]
    if item == false then
        scan.skipped = scan.skipped + 1
    elseif not item or item.sellPrice * quantity > buyout then
        if not scan.auctionatorData then
            link = C_AuctionHouse.GetReplicateItemLink(index)
        end
        local listing = {
            index = index,
            name = name,
            link = link,
            quantity = quantity,
            buyout = buyout,
        }
        if item then
            CompareListing(scan, listing, item)
        elseif scan.auctionatorData then
            scan.items[itemID] = false
            scan.skipped = scan.skipped + 1
        elseif scan.pending[itemID] then
            table.insert(scan.pending[itemID], listing)
        else
            scan.pending[itemID] = { listing }
            C_Item.RequestLoadItemDataByID(itemID)
        end
    end
end

local function ReadBatch(scan, first)
    if activeScan ~= scan then return end
    local last = math.min(first + BATCH_SIZE - 1, scan.total - 1)
    for index = first, last do
        if scan.auctionatorData then
            local row = scan.auctionatorData[index + 1]
            CompareAuction(scan, index, row.itemLink, unpack(row.replicateInfo, 1, 17))
        else
            CompareAuction(scan, index, nil, C_AuctionHouse.GetReplicateItemInfo(index))
        end
    end
    if last + 1 < scan.total then
        status:SetText(("Checking listings… %d / %d"):format(last + 1, scan.total))
        C_Timer.After(0, function() ReadBatch(scan, last + 1) end)
        return
    end

    scan.readComplete = true
    if not next(scan.pending) then
        FinishScan(scan)
        return
    end
    status:SetText("Waiting for vendor prices…")
    C_Timer.After(ITEM_TIMEOUT, function()
        if activeScan ~= scan then return end
        for itemID in pairs(scan.pending) do
            ResolvePending(scan, itemID, true)
        end
    end)
end

local function NewScan()
    local playerName, realm = UnitFullName("player")
    local scan = {
        items = {},
        pending = {},
        deals = {},
        skipped = 0,
        playerName = playerName,
        playerFullName = playerName .. "-" .. (realm or GetNormalizedRealmName()),
    }
    activeScan = scan
    results = {}
    page = 1
    DrawPage()
    scanButton:Disable()
    return scan
end

local function StartScan()
    if activeScan or usingAuctionator then return end
    local remaining = lastSnapshot and SCAN_COOLDOWN - (GetTime() - lastSnapshot)
    if remaining and remaining > 0 then
        local seconds = math.ceil(remaining)
        status:SetText(("Scan available in %d:%02d."):format(math.floor(seconds / 60), seconds % 60))
        return
    end

    local scan = NewScan()
    scan.waiting = true
    events:RegisterEvent("ITEM_DATA_LOAD_RESULT")
    status:SetText("Requesting Auction House snapshot…")
    C_AuctionHouse.ReplicateItems()
    C_Timer.After(RESPONSE_TIMEOUT, function()
        if activeScan == scan and scan.waiting then
            activeScan = nil
            events:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
            scanButton:Enable()
            status:SetText("No snapshot received. The Auction House may be on cooldown.")
        end
    end)
end

local function Button(parent, width, label, callback)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 24)
    button:SetText(label)
    button:SetScript("OnClick", callback)
    return button
end

local function Column(parent, label, x, y, width, template, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", template)
    text:SetPoint("TOPLEFT", x, y)
    text:SetWidth(width)
    text:SetJustifyH(justify)
    text:SetWordWrap(false)
    text:SetText(label)
    return text
end

local function CreatePanel(auctionHouse)
    panel = CreateFrame("Frame", nil, auctionHouse, "BackdropTemplate")
    panel:SetFrameStrata("DIALOG")
    panel:SetSize(620, 432)
    panel:SetPoint("CENTER")
    panel:EnableMouse(true)
    panel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    panel:SetBackdropColor(0.08, 0.08, 0.08, 1)
    panel:SetBackdropBorderColor(0.6, 0.5, 0.31, 1)
    panel:Hide()

    Column(panel, "Vendor Deals", 16, -17, 260, "GameFontNormalLarge", "LEFT")
    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -3, -3)
    close:SetScript("OnClick", function() panel:Hide() end)
    status = Column(panel, "Scan the Auction House for below-vendor buyouts.", 16, -53, 465, "GameFontHighlightSmall", "LEFT")
    scanButton = Button(panel, 100, "Scan", StartScan)
    scanButton:SetPoint("TOPRIGHT", -16, -45)

    local columns = {
        { "Item", 16, 238, "LEFT" },
        { "Qty", 258, 44, "RIGHT" },
        { "Buyout", 307, 91, "RIGHT" },
        { "Vendor", 403, 91, "RIGHT" },
        { "Profit", 499, 105, "RIGHT" },
    }
    local fields = { "name", "quantity", "buyout", "vendor", "profit" }
    for _, spec in ipairs(columns) do
        Column(panel, spec[1], spec[2], -81, spec[3], "GameFontNormalSmall", spec[4])
    end
    for index = 1, PAGE_SIZE do
        local row = CreateFrame("Button", nil, panel)
        row:SetPoint("TOPLEFT", 0, -100 - (index - 1) * 24)
        row:SetSize(620, 24)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        for col, spec in ipairs(columns) do
            row[fields[col]] = Column(row, "", spec[2], -5, spec[3], "GameFontHighlight", spec[4])
        end
        row.profit:SetTextColor(0.45, 1, 0.45)
        row:SetScript("OnEnter", function(self)
            if self.deal and self.deal.link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(self.deal.link)
            end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnHide", function(self)
            if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
        end)
        rows[index] = row
    end
    previousButton = Button(panel, 80, "Previous", function() page = page - 1; DrawPage() end)
    previousButton:SetPoint("BOTTOMLEFT", 16, 12)
    nextButton = Button(panel, 80, "Next", function() page = page + 1; DrawPage() end)
    nextButton:SetPoint("BOTTOMRIGHT", -16, 12)
    pageText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pageText:SetPoint("BOTTOM", 0, 19)
    DrawPage()

end

local function SetupAuctionHouse()
    local auctionHouse = AuctionHouseFrame
    if not auctionHouseOpen or not auctionHouse then return end
    if not toggleButton then
        toggleButton = Button(auctionHouse, 108, "Vendor Deals", function()
            if panel then panel:SetShown(not panel:IsShown()) end
        end)
        toggleButton:SetHeight(20)
        toggleButton:SetPoint("BOTTOMRIGHT", auctionHouse, "BOTTOMRIGHT", -20, 8)
        toggleButton:SetFrameLevel(auctionHouse:GetFrameLevel() + 20)
    end
    if not panel then CreatePanel(auctionHouse) end
    usingAuctionator = C_AddOns.IsAddOnLoaded("Auctionator")
    scanButton:SetShown(not usingAuctionator)
    if usingAuctionator then
        local bus = Auctionator and Auctionator.EventBus
        local scanEvents = Auctionator and Auctionator.FullScan and Auctionator.FullScan.Events
        if not (bus and bus.Register and scanEvents and scanEvents.ScanComplete) then
            status:SetText("This Auctionator version does not expose completed full scans.")
            return
        end
        if not auctionatorListener then
            auctionatorListener = {
                ReceiveEvent = function(_, _, data)
                    if not auctionHouseOpen or not panel or type(data) ~= "table" then return end
                    local scan = NewScan()
                    scan.auctionatorData = data
                    scan.total = #data
                    status:SetText("Checking Auctionator’s completed scan…")
                    C_Timer.After(0, function() ReadBatch(scan, 0) end)
                end,
            }
            bus:Register(auctionatorListener, { scanEvents.ScanComplete })
        end
        status:SetText("Vendor deals appear after Auctionator’s replicate scan finishes.")
    end
end

SLASH_VENDORDEALS1 = "/vendordeals"
SlashCmdList.VENDORDEALS = function()
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
        print("Vendor Deals: Open the Auction House first.")
        return
    end
    if not auctionHouseOpen or not panel then
        auctionHouseOpen = true
        SetupAuctionHouse()
    end
    panel:SetShown(not panel:IsShown())
end

events:RegisterEvent("AUCTION_HOUSE_SHOW")
events:RegisterEvent("AUCTION_HOUSE_CLOSED")
events:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
events:SetScript("OnEvent", function(_, event, itemID, success)
    local scan = activeScan
    if event == "AUCTION_HOUSE_SHOW" then
        auctionHouseOpen = true
        if AuctionHouseFrame then
            SetupAuctionHouse()
        else
            C_Timer.After(0, SetupAuctionHouse)
        end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        auctionHouseOpen = false
        activeScan = nil
        events:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
        if not panel then return end
        results = {}
        page = 1
        panel:Hide()
        scanButton:Enable()
        status:SetText("Scan the Auction House for below-vendor buyouts.")
        DrawPage()
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
        lastSnapshot = GetTime()
        if auctionHouseOpen and panel and scan and scan.waiting then
            scan.waiting = false
            scan.total = C_AuctionHouse.GetNumReplicateItems()
            ReadBatch(scan, 0)
        end
    elseif event == "ITEM_DATA_LOAD_RESULT" and scan then
        ResolvePending(scan, itemID, success)
    end
end)
