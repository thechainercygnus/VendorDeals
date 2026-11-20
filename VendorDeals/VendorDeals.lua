local PAGE_SIZE = 12
local BATCH_SIZE = 100
local SCAN_COOLDOWN = 15 * 60
local RESPONSE_TIMEOUT = 45
local ITEM_TIMEOUT = 5

local RESALE_ITEMS = {
    -- Cooking supplies
    [2678] = true, -- Mild Spices
    [2692] = true, -- Hot Spices
    [3713] = true, -- Soothing Spices
    -- Tailoring supplies
    [2320] = true, -- Coarse Thread
    [2321] = true, -- Fine Thread
    [4291] = true, -- Silken Thread
    [2324] = true, -- Bleach
    [2604] = true, -- Red Dye
    [6260] = true, -- Blue Dye
    -- Blacksmithing supplies
    [2880] = true, -- Weak Flux
    [3466] = true, -- Strong Flux
    -- Alchemy supplies
    [3371] = true, -- Empty Vial
    [3372] = true, -- Leaded Vial
}
local ESTIMATED_CUT_PERCENT = 5

local events = CreateFrame("Frame")
local panel, scanButton, status, previousButton, nextButton, pageText
local toggleButton
local selectView
local rows = {}
local results = {}
local resaleResults = {}
local view = "deals"
local finishedAt
local page = 1
local activeScan
local auctionHouseOpen
local usingAuctionator
local auctionatorListener

local function CooldownRemaining()
    local now = GetServerTime()
    local snapshot = VendorDealsLastSnapshot
    if type(snapshot) ~= "number" or snapshot <= 0 or snapshot > now then return 0 end
    return math.max(0, SCAN_COOLDOWN - (now - snapshot))
end

local function UpdateScanButton()
    if usingAuctionator then return end
    local remaining = CooldownRemaining()
    local label = "Scan"
    if activeScan then
        label = "Scanning…"
    elseif remaining > 0 then
        label = ("Scan in %d:%02d"):format(math.floor(remaining / 60), remaining % 60)
    end
    if scanButton:GetText() ~= label then scanButton:SetText(label) end
    scanButton:SetEnabled(not activeScan and remaining == 0)
end

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

local function CaptureMerchantPrices()
    local vendor = UnitName("npc")
    if not vendor then return end
    local location = GetRealZoneText() or ""
    for index = 1, GetMerchantNumItems() do
        local itemID = GetMerchantItemID(index)
        if RESALE_ITEMS[itemID] then
            local info = C_MerchantFrame.GetItemInfo(index)
            if info and info.name and info.isPurchasable and not info.hasExtendedCost
                and (not info.currencyID or info.currencyID == 0)
                and info.numAvailable == -1 and info.price > 0 and info.stackCount > 0 then
                VendorDealsMerchantPrices[itemID] = {
                    name = info.name,
                    link = GetMerchantItemLink(index),
                    vendor = vendor,
                    location = location,
                    cost = info.price,
                    size = info.stackCount,
                    seenAt = GetServerTime(),
                }
            end
        end
    end
end

local function TrackResale(scan, itemID, quantity, buyout)
    if not RESALE_ITEMS[itemID] then return end
    local ask = scan.resale[itemID]
    if not ask or buyout * ask.stack < ask.buyout * quantity then
        scan.resale[itemID] = { buyout = buyout, stack = quantity, quantity = quantity }
    elseif buyout * ask.stack == ask.buyout * quantity then
        ask.quantity = ask.quantity + quantity
    end
end

local function RefreshResaleResults()
    resaleResults = {}
    local snapshot = VendorDealsResaleSnapshot
    if not snapshot then return end
    for itemID, ask in pairs(snapshot.asks) do
        local source = VendorDealsMerchantPrices[itemID]
        if source then
            local gross = math.floor(ask.buyout * source.size / ask.stack)
            local cut = math.ceil(gross * ESTIMATED_CUT_PERCENT / 100)
            local profit = gross - cut - source.cost
            if profit > 0 then
                resaleResults[#resaleResults + 1] = {
                    name = source.name, link = source.link, quantity = ask.quantity,
                    buyout = ask.buyout / ask.stack, vendor = source.cost, profit = profit,
                    source = source, gross = gross, cut = cut, itemID = itemID,
                }
            end
        end
    end
    table.sort(resaleResults, function(a, b)
        if a.profit ~= b.profit then return a.profit > b.profit end
        return a.itemID < b.itemID
    end)
end

local function DataAge(timestamp)
    local minutes = math.floor(math.max(0, GetServerTime() - timestamp) / 60)
    if minutes < 1 then return "<1 min ago" end
    if minutes < 60 then return ("%d min ago"):format(minutes) end
    if minutes < 1440 then return ("%dh %02dm ago"):format(math.floor(minutes / 60), minutes % 60) end
    return ("%dd %dh ago"):format(math.floor(minutes / 1440), math.floor(minutes / 60) % 24)
end

local function RecordedOffers()
    local offers = {}
    for itemID, source in pairs(VendorDealsMerchantPrices) do
        offers[#offers + 1] = { itemID = itemID, name = source.name, link = source.link, source = source }
    end
    table.sort(offers, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.itemID < b.itemID
    end)
    return offers
end

local function DrawPage()
    local visible = results
    if view == "resale" then
        visible = resaleResults
    elseif view == "offers" then
        visible = RecordedOffers()
        status:SetText(("%d recorded offers · Visit a trade supplier to learn prices."):format(#visible))
    end
    local pages = math.max(1, math.ceil(#visible / PAGE_SIZE))
    page = math.min(page, pages)
    for index, row in ipairs(rows) do
        local deal = visible[(page - 1) * PAGE_SIZE + index]
        row.deal = deal
        if deal and view == "offers" then
            local source = deal.source
            row.name:SetText(deal.name)
            row.quantity:SetText(source.size)
            row.buyout:SetText(("%.2fc"):format(source.cost / source.size))
            row.vendor:SetText(Money(source.cost))
            row.profit:SetText(source.location)
            row.profit:SetTextColor(1, 1, 1)
        elseif deal then
            row.name:SetText(deal.name)
            row.quantity:SetText(deal.quantity)
            row.buyout:SetText(view == "resale" and ("%.2fc"):format(deal.buyout) or Money(deal.buyout))
            row.vendor:SetText(Money(deal.vendor))
            row.profit:SetText(Money(deal.profit))
            row.profit:SetTextColor(0.45, 1, 0.45)
        end
        row:SetShown(deal ~= nil)
    end
    pageText:SetText(("%d / %d"):format(page, pages))
    previousButton:SetEnabled(page > 1)
    nextButton:SetEnabled(page < pages)
end

local function DrawSummary()
    if view == "offers" then return end
    if view == "resale" then
        if not next(VendorDealsMerchantPrices) then
            status:SetText("Visit a trade supplier to learn vendor prices.")
        elseif VendorDealsResaleSnapshot then
            status:SetText(("%d opportunities · Auction data %s · Est. %d%% cut"):format(
                #resaleResults, DataAge(VendorDealsResaleSnapshot.seenAt), ESTIMATED_CUT_PERCENT))
        else
            status:SetText("Run an Auction House scan to cache resale prices.")
        end
    elseif finishedAt then
        status:SetText(finishedAt.summary)
    elseif not auctionHouseOpen then
        status:SetText("Visit the Auction House to scan for below-vendor buyouts.")
    end
end

local function SetScanStatus(message)
    if view ~= "offers" then status:SetText(message) end
end

local function FinishScan(scan)
    if activeScan ~= scan then return end
    activeScan = nil
    events:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
    UpdateScanButton()
    results = scan.deals
    table.sort(results, function(a, b)
        if a.profit ~= b.profit then return a.profit > b.profit end
        if a.buyout ~= b.buyout then return a.buyout < b.buyout end
        return a.index < b.index
    end)
    page = 1
    VendorDealsResaleSnapshot = { seenAt = scan.seenAt, asks = scan.resale }
    RefreshResaleResults()
    local time = date("%H:%M")
    local summary = ("%d deals across %d listings · Last scan %s"):format(#results, scan.total, time)
    if scan.skipped > 0 then
        summary = summary .. (" · %d unavailable"):format(scan.skipped)
    end
    finishedAt = { time = time, summary = summary }
    DrawSummary()
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
    TrackResale(scan, itemID, quantity, buyout)

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
        SetScanStatus(("Checking listings… %d / %d"):format(last + 1, scan.total))
        C_Timer.After(0, function() ReadBatch(scan, last + 1) end)
        return
    end

    scan.readComplete = true
    if not next(scan.pending) then
        FinishScan(scan)
        return
    end
    SetScanStatus("Waiting for vendor prices…")
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
        resale = {},
        skipped = 0,
        playerName = playerName,
        playerFullName = playerName .. "-" .. (realm or GetNormalizedRealmName()),
    }
    activeScan = scan
    UpdateScanButton()
    return scan
end

local function StartScan()
    if activeScan or usingAuctionator then return end
    if CooldownRemaining() > 0 then
        UpdateScanButton()
        return
    end

    local scan = NewScan()
    scan.waiting = true
    events:RegisterEvent("ITEM_DATA_LOAD_RESULT")
    SetScanStatus("Requesting Auction House snapshot…")
    C_AuctionHouse.ReplicateItems()
    C_Timer.After(RESPONSE_TIMEOUT, function()
        if activeScan == scan and scan.waiting then
            activeScan = nil
            events:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
            UpdateScanButton()
            SetScanStatus("No snapshot received. Cooldown time is unknown.")
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

local function CreatePanel()
    panel = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    panel:SetFrameStrata("DIALOG")
    panel:SetSize(620, 432)
    local position = VendorDealsUISettings.window
    panel:SetPoint("CENTER", UIParent, "CENTER", position and position.x or 0, position and position.y or 0)
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
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
    local dragHandle = CreateFrame("Frame", nil, panel)
    dragHandle:SetPoint("TOPLEFT")
    dragHandle:SetSize(152, 37)
    dragHandle:EnableMouse(true)
    dragHandle:RegisterForDrag("LeftButton")
    local dragging
    dragHandle:SetScript("OnDragStart", function()
        dragging = true
        panel:StartMoving()
    end)
    local function StopWindowDrag()
        if not dragging then return end
        dragging = false
        panel:StopMovingOrSizing()
        panel:SetUserPlaced(false)
        local x, y = panel:GetCenter()
        local centerX, centerY = UIParent:GetCenter()
        if x and y and centerX and centerY then
            VendorDealsUISettings.window = { x = x - centerX, y = y - centerY }
        end
    end
    dragHandle:SetScript("OnDragStop", StopWindowDrag)
    dragHandle:SetScript("OnHide", StopWindowDrag)
    local ageElapsed = 0
    panel:SetScript("OnUpdate", function(_, delta)
        ageElapsed = ageElapsed + delta
        if ageElapsed >= 15 then
            ageElapsed = 0
            if view == "resale" and not activeScan then DrawSummary() end
        end
    end)

    Column(panel, "Vendor Deals", 16, -17, 142, "GameFontNormalLarge", "LEFT")
    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -3, -3)
    close:SetScript("OnClick", function() panel:Hide() end)
    status = Column(panel, "Scan the Auction House for below-vendor buyouts.", 16, -53, 465, "GameFontHighlightSmall", "LEFT")
    scanButton = Button(panel, 100, "Scan", StartScan)
    scanButton:Hide()
    scanButton:SetPoint("TOPRIGHT", -16, -45)
    local elapsed = 0
    scanButton:SetScript("OnShow", UpdateScanButton)
    scanButton:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + delta
        if elapsed >= 1 then
            elapsed = 0
            UpdateScanButton()
        end
    end)
    local views = {
        { "deals", "Below Vendor", { "Qty", "Buyout", "Vendor", "Profit" } },
        { "resale", "Vendor Resale", { "At ask", "Ask / unit", "Bundle cost", "Net / bundle" } },
        { "offers", "Recorded Offers", { "Bundle", "Cost / unit", "Bundle cost", "Zone" } },
    }
    local viewButtons, headings, headers = {}, {}, {}
    selectView = function(key)
        view = key
        page = 1
        for name, control in pairs(viewButtons) do
            control:SetEnabled(name ~= view)
        end
        for column, heading in ipairs(headings[key]) do
            headers[column + 1]:SetText(heading)
        end
        if activeScan then
            status:SetText("Checking Auction House listings…")
        else
            if not finishedAt then
                status:SetText(usingAuctionator and "Run a replicate scan in Auctionator." or "Scan the Auction House for below-vendor buyouts.")
            end
            DrawSummary()
        end
        DrawPage()
    end
    for index, spec in ipairs(views) do
        local key, label, labels = unpack(spec)
        headings[key] = labels
        local button = Button(panel, 122, label, function() selectView(key) end)
        button:SetPoint("TOPLEFT", 158 + (index - 1) * 126, -11)
        button:SetEnabled(key ~= view)
        viewButtons[key] = button
    end

    local columns = {
        { "Item", 16, 238, "LEFT" },
        { "Qty", 258, 44, "RIGHT" },
        { "Buyout", 307, 91, "RIGHT" },
        { "Vendor", 403, 91, "RIGHT" },
        { "Profit", 499, 105, "RIGHT" },
    }
    local fields = { "name", "quantity", "buyout", "vendor", "profit" }
    for index, spec in ipairs(columns) do
        headers[index] = Column(panel, spec[1], spec[2], -81, spec[3], "GameFontNormalSmall", spec[4])
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
            local deal = self.deal
            if not deal then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if deal.link then GameTooltip:SetHyperlink(deal.link) else GameTooltip:SetText(deal.name) end
            if deal.source then
                local source = deal.source
                GameTooltip:AddLine(source.vendor .. " · " .. source.location)
                GameTooltip:AddLine(("Vendor bundle: %d for %s (%.2fc each)"):format(source.size, Money(source.cost), source.cost / source.size))
                GameTooltip:AddLine("Vendor price recorded " .. DataAge(source.seenAt))
                if deal.gross then
                    GameTooltip:AddLine(("Bundle at asking price: %s gross, %s estimated cut"):format(Money(deal.gross), Money(deal.cut)))
                    local deposit
                    if auctionHouseOpen then
                        local key = C_AuctionHouse.GetItemKeyInfo(C_AuctionHouse.MakeItemKey(deal.itemID))
                        if key and key.isCommodity then
                            deposit = C_AuctionHouse.CalculateCommodityDeposit(deal.itemID, 1, source.size)
                        end
                    end
                    GameTooltip:AddLine("12-hour deposit at risk: " .. (deposit and Money(deposit) or "See the Sell tab"))
                end
                GameTooltip:Show()
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

local function TogglePanel()
    if not panel then CreatePanel() end
    if panel:IsShown() then
        panel:Hide()
        return
    end
    if not auctionHouseOpen then
        selectView("resale")
    elseif not activeScan then
        DrawSummary()
    end
    panel:Show()
end

local function PositionMinimapButton(button)
    local angle = VendorDealsUISettings.minimapAngle or -3 * math.pi / 4
    local x, y = math.cos(angle), math.sin(angle)
    if GetMinimapShape and GetMinimapShape() == "SQUARE" then
        local edge = math.max(math.abs(x), math.abs(y))
        x, y = x / edge, y / edge
    end
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER",
        x * (Minimap:GetWidth() / 2 + 5), y * (Minimap:GetHeight() / 2 + 5))
end

local function MoveMinimapButton(button)
    local centerX, centerY = Minimap:GetCenter()
    local width, height = Minimap:GetWidth(), Minimap:GetHeight()
    if not centerX or not centerY or width <= 0 or height <= 0 then return end
    local cursorX, cursorY = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    local x, y = cursorX / scale - centerX, cursorY / scale - centerY
    if x == 0 and y == 0 then return end
    VendorDealsUISettings.minimapAngle = math.atan2(y / height, x / width)
    PositionMinimapButton(button)
end

local function StopMinimapDrag(button)
    button:SetScript("OnUpdate", nil)
end

local function CreateMinimapButton()
    if not Minimap then return end
    local button = CreateFrame("Button", "VendorDealsMinimapButton", Minimap)
    button:SetSize(30, 30)
    button:SetFrameStrata("HIGH")
    button:SetFrameLevel(Minimap:GetFrameLevel() + 50)
    button:RegisterForClicks("LeftButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", MoveMinimapButton)
    end)
    button:SetScript("OnDragStop", StopMinimapDrag)
    button:SetScript("OnHide", StopMinimapDrag)
    button:SetScript("OnClick", function()
        GameTooltip:Hide()
        TogglePanel()
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Vendor Deals")
        GameTooltip:AddLine("Click to review vendor and auction prices", 1, 1, 1)
        GameTooltip:AddLine("Drag to move", 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function(self)
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(50, 50)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    PositionMinimapButton(button)
    Minimap:HookScript("OnSizeChanged", function() PositionMinimapButton(button) end)
end

local function SetupAuctionHouse()
    local auctionHouse = AuctionHouseFrame
    if not auctionHouseOpen or not auctionHouse then return end
    if not toggleButton then
        toggleButton = Button(auctionHouse, 108, "Vendor Deals", TogglePanel)
        toggleButton:SetHeight(20)
        toggleButton:SetPoint("BOTTOMRIGHT", auctionHouse, "BOTTOMRIGHT", -20, 8)
        toggleButton:SetFrameLevel(auctionHouse:GetFrameLevel() + 20)
    end
    if not panel then CreatePanel() end
    usingAuctionator = C_AddOns.IsAddOnLoaded("Auctionator")
    scanButton:SetShown(not usingAuctionator)
    UpdateScanButton()
    if usingAuctionator then
        local bus = Auctionator and Auctionator.EventBus
        local scanEvents = Auctionator and Auctionator.FullScan and Auctionator.FullScan.Events
        if not (bus and bus.Register and scanEvents and scanEvents.ScanComplete) then
            SetScanStatus("This Auctionator version does not expose completed full scans.")
            DrawPage()
            return
        end
        if not auctionatorListener then
            auctionatorListener = {
                ReceiveEvent = function(_, _, data)
                    if not auctionHouseOpen or not panel or type(data) ~= "table" then return end
                    local scan = NewScan()
                    scan.auctionatorData = data
                    scan.total = #data
                    scan.seenAt = VendorDealsLastSnapshot or GetServerTime()
                    SetScanStatus("Checking Auctionator’s completed scan…")
                    C_Timer.After(0, function() ReadBatch(scan, 0) end)
                end,
            }
            bus:Register(auctionatorListener, { scanEvents.ScanComplete })
        end
        if not finishedAt then
            status:SetText("Vendor deals appear after Auctionator’s replicate scan finishes.")
        end
    end
    DrawSummary()
    DrawPage()
end

SLASH_VENDORDEALS1 = "/vendordeals"
SlashCmdList.VENDORDEALS = TogglePanel

events:RegisterEvent("AUCTION_HOUSE_SHOW")
events:RegisterEvent("AUCTION_HOUSE_CLOSED")
events:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("MERCHANT_SHOW")
events:RegisterEvent("MERCHANT_UPDATE")
events:SetScript("OnEvent", function(_, event, itemID, success)
    local scan = activeScan
    if event == "ADDON_LOADED" and itemID == "VendorDeals" then
        if type(VendorDealsMerchantPrices) ~= "table" then VendorDealsMerchantPrices = {} end
        if type(VendorDealsUISettings) ~= "table" then VendorDealsUISettings = {} end
        local snapshot = VendorDealsResaleSnapshot
        if type(snapshot) ~= "table" or type(snapshot.asks) ~= "table" or type(snapshot.seenAt) ~= "number" then
            VendorDealsResaleSnapshot = nil
        end
        RefreshResaleResults()
        events:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        CreateMinimapButton()
        events:UnregisterEvent("PLAYER_LOGIN")
    elseif event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
        CaptureMerchantPrices()
        RefreshResaleResults()
        if panel and (view == "resale" or view == "offers") then
            DrawSummary()
            DrawPage()
        end
    elseif event == "AUCTION_HOUSE_SHOW" then
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
        panel:Hide()
        scanButton:Hide()
        status:SetText("Scan the Auction House for below-vendor buyouts.")
        DrawPage()
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
        VendorDealsLastSnapshot = GetServerTime()
        if scanButton then UpdateScanButton() end
        if auctionHouseOpen and panel and scan and scan.waiting then
            scan.waiting = false
            scan.seenAt = VendorDealsLastSnapshot
            scan.total = C_AuctionHouse.GetNumReplicateItems()
            ReadBatch(scan, 0)
        end
    elseif event == "ITEM_DATA_LOAD_RESULT" and scan then
        ResolvePending(scan, itemID, success)
    end
end)
