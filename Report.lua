-- ============================================
-- AUTO ACCEPT + TELEGRAM TRADE REPORTER
-- Accepts incoming trades automatically, diffs inventory
-- before/after, and reports exactly what was received
-- to your Telegram chat via a bot.
-- ============================================

if not getgenv().TelegramReportConfig then
    error("❌ ERROR: No configuration found!\n\nExample:\n\ngetgenv().TelegramReportConfig = {\n    BOT_TOKEN = \"your_bot_token\",\n    CHAT_ID = \"your_chat_id\",\n    FROM_PLAYER = nil, -- nil = accept from anyone\n}")
end

local CONFIG = getgenv().TelegramReportConfig

if not CONFIG.BOT_TOKEN or CONFIG.BOT_TOKEN == "" then
    error("❌ BOT_TOKEN is required!")
end
if not CONFIG.CHAT_ID or tostring(CONFIG.CHAT_ID) == "" then
    error("❌ CHAT_ID is required!")
end

-- Heartbeat: periodic "still online" ping so you know it hasn't crashed.
-- Set to 0 to disable.
if CONFIG.HEARTBEAT_INTERVAL == nil then CONFIG.HEARTBEAT_INTERVAL = 900 end -- 15 min default

-- Server player reporting
if CONFIG.REPORT_JOINS == nil then CONFIG.REPORT_JOINS = true end            -- report who joins/leaves
if CONFIG.JOIN_REPORT_INTERVAL == nil then CONFIG.JOIN_REPORT_INTERVAL = 60 end -- batch joins/leaves into one message per X sec
if CONFIG.LIST_PLAYERS_ON_START == nil then CONFIG.LIST_PLAYERS_ON_START = true end

-- Optional: simulate clicks on the on-screen Accept/Confirm buttons (off by default)
if CONFIG.USE_CLICK_FALLBACK == nil then CONFIG.USE_CLICK_FALLBACK = false end

-- ============================================
-- SETUP
-- ============================================

repeat task.wait() until game:IsLoaded()
repeat task.wait(1) until game:GetService("ReplicatedStorage"):FindFirstChild("ClientModules")
task.wait(2)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer
local playerName = LocalPlayer.Name
local HttpService = game:GetService("HttpService")
local request = (syn and syn.request) or (http and http.request) or http_request

if not request then
    error("❌ No HTTP request function available in this executor!")
end

-- Anti-AFK
local VirtualUser = game:GetService("VirtualUser")
LocalPlayer.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
end)
print("✅ Anti-AFK enabled")

-- Dehash
print("🔧 Dehashing remotes...")

local function dehash()
    local router = require(ReplicatedStorage.ClientModules.Core.RouterClient.RouterClient)
    if type(router.init) ~= "function" then
        print("Router.init is not a function")
        return
    end
    local targetTable = nil
    for i = 1, 20 do
        local upv = debug.getupvalue(router.init, i)
        if type(upv) == "table" then
            local valid = true
            local count = 0
            for k, v in pairs(upv) do
                count = count + 1
                if typeof(v) ~= "Instance" then
                    valid = false
                    break
                end
            end
            if valid and count > 0 then
                targetTable = upv
                print("Found remotes table at index:", i)
                break
            end
        end
    end
    if not targetTable then
        print("🔴 Remotes table not found")
        return
    end
    for name, remote in pairs(targetTable) do
        pcall(function()
            remote.Name = name
        end)
    end
    print("✅ Dehash done")
end

dehash()
task.wait(1)

local Data = require(ReplicatedStorage.ClientModules.Core.ClientData)

-- ============================================
-- TELEGRAM SEND
-- ============================================

local function sendTelegram(text)
    local ok, response = pcall(function()
        return request({
            Url = "https://api.telegram.org/bot" .. CONFIG.BOT_TOKEN .. "/sendMessage",
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode({
                chat_id = CONFIG.CHAT_ID,
                text = text
            })
        })
    end)

    if not ok or not response then
        warn("❌ Telegram send failed: request error")
        return false
    end

    if response.StatusCode and response.StatusCode >= 200 and response.StatusCode < 300 then
        print("✅ Telegram report sent!")
        return true
    end

    warn("❌ Telegram send failed: HTTP " .. tostring(response.StatusCode) .. " - " .. tostring(response.Body))
    warn("   (Check BOT_TOKEN and CHAT_ID, and make sure you pressed Start on your bot)")
    return false
end

-- Split long messages (Telegram limit is ~4096 chars)
local function sendLong(text)
    if #text <= 3800 then return sendTelegram(text) end
    local chunk = ""
    for line in (text .. "\n"):gmatch("(.-)\n") do
        if #chunk + #line + 1 > 3800 then
            sendTelegram(chunk)
            chunk = ""
        end
        chunk = chunk .. line .. "\n"
    end
    if chunk ~= "" then sendTelegram(chunk) end
end

-- ============================================
-- KIND -> NAME + CATEGORY LOOKUP (from KindDB)
-- ============================================

local INVENTORY_CATEGORIES = { "pets", "vehicles", "toys", "food", "gifts", "eggs" }
local kindInfo = {}

local function buildKindInfo()
    local ok, db = pcall(function()
        return require(ReplicatedStorage:WaitForChild("ClientDB"):WaitForChild("Inventory"):WaitForChild("KindDB"))
    end)
    if not ok then
        warn("⚠️ Could not load KindDB for item names")
        return
    end
    for _, v in pairs(db) do
        if v.kind then
            kindInfo[v.kind] = { name = v.name or v.kind, category = v.category or "pets" }
        end
    end
end

buildKindInfo()

-- ============================================
-- INVENTORY SNAPSHOT (counts per kind, across all categories)
-- ============================================

local function snapshotInventory()
    local counts = {}
    local playerData = Data.get_data()[playerName]
    if not playerData or not playerData.inventory then return counts end

    for _, category in ipairs(INVENTORY_CATEGORIES) do
        local inv = playerData.inventory[category]
        if inv then
            for _, item in pairs(inv) do
                if item.kind then
                    counts[item.kind] = (counts[item.kind] or 0) + 1
                end
            end
        end
    end

    return counts
end

local function diffSnapshots(before, after)
    local gained = {} -- kind -> count gained
    for kind, afterCount in pairs(after) do
        local beforeCount = before[kind] or 0
        if afterCount > beforeCount then
            gained[kind] = afterCount - beforeCount
        end
    end
    return gained
end

-- ============================================
-- TRADE REMOTES + UI HELPERS
-- ============================================

local API = ReplicatedStorage:WaitForChild("API")
local GuiService = game:GetService("GuiService")
local VirtualInputManager = game:GetService("VirtualInputManager")

-- Print every trade-related remote so names can be verified if something fails
print("🔎 Trade remotes found:")
for _, child in ipairs(API:GetChildren()) do
    if child.Name:find("TradeAPI") then
        print("   " .. child.Name)
    end
end

local function fireRemote(name, ...)
    local remote = API:FindFirstChild(name)
    if not remote then return false end
    local args = { ... }
    task.spawn(function()
        pcall(function()
            if remote:IsA("RemoteFunction") then
                remote:InvokeServer(unpack(args))
            else
                remote:FireServer(unpack(args))
            end
        end)
    end)
    return true
end

local function acceptNegotiation() fireRemote("TradeAPI/AcceptNegotiation") end
local function confirmTrade() fireRemote("TradeAPI/ConfirmTrade") end

-- Is this GUI object actually visible on screen (all parents shown)?
local function isShown(obj)
    local p = obj
    while p and p ~= LocalPlayer.PlayerGui do
        if p:IsA("GuiObject") and not p.Visible then return false end
        if p:IsA("ScreenGui") and not p.Enabled then return false end
        p = p.Parent
    end
    if (obj:IsA("TextLabel") or obj:IsA("TextButton")) and obj.TextTransparency > 0.6 then
        return false -- faded/leftover text, not a live prompt
    end
    return obj.AbsoluteSize.X > 0
end

-- Find a visible label/button whose text is exactly `wanted` (case-insensitive)
local function findButtonByText(root, wanted)
    if not root then return nil end
    for _, d in ipairs(root:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" and isShown(d) then
            local t = d.Text:lower():gsub("%s+", "")
            if t == wanted then return d end
        end
    end
    return nil
end

-- Simulate a real mouse click in the middle of a GUI object
local function clickGuiObject(obj)
    return pcall(function()
        local sg = obj:FindFirstAncestorOfClass("ScreenGui")
        local inset = (sg and sg.IgnoreGuiInset) and Vector2.new(0, 0) or GuiService:GetGuiInset()
        local pos = obj.AbsolutePosition + obj.AbsoluteSize / 2 + inset
        VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 1)
        task.wait(0.05)
        VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 1)
    end)
end

local function tradeGuiVisible()
    local gui = LocalPlayer.PlayerGui:FindFirstChild("TradeApp")
    return gui and gui.Frame and gui.Frame.Visible
end

-- ---- incoming trade request popup ----

-- Returns the DialogApp + its text if a trade request popup is showing (and allowed by FROM_PLAYER)
local function pendingTradeRequestDialog()
    local gui = LocalPlayer.PlayerGui:FindFirstChild("DialogApp")
    if not gui or not gui.Enabled then return nil end

    for _, d in ipairs(gui:GetDescendants()) do
        if d:IsA("TextLabel") and d.Text ~= "" and isShown(d) then
            local t = d.Text:lower()
            if t:find("trade request", 1, true) then
                if CONFIG.FROM_PLAYER then
                    local want = tostring(CONFIG.FROM_PLAYER):lower()
                    local plr = Players:FindFirstChild(CONFIG.FROM_PLAYER)
                    local okName = t:find(want, 1, true)
                    local okDisplay = plr and t:find(plr.DisplayName:lower(), 1, true)
                    if not okName and not okDisplay then return nil end
                end
                return gui, d.Text
            end
        end
    end
    return nil
end

-- Players named in a visible "trade request" popup (the sender's name is in the text)
local function getRequesters()
    local found = {}
    local gui = LocalPlayer.PlayerGui:FindFirstChild("DialogApp")
    if gui then
        for _, d in ipairs(gui:GetDescendants()) do
            if d:IsA("TextLabel") and d.Text ~= "" and isShown(d) then
                local t = d.Text:lower()
                if t:find("trade request", 1, true) then
                    for _, p in ipairs(Players:GetPlayers()) do
                        if p ~= LocalPlayer and (t:find(p.Name:lower(), 1, true) or t:find(p.DisplayName:lower(), 1, true)) then
                            found[p] = true
                        end
                    end
                end
            end
        end
    end
    local list = {}
    for p in pairs(found) do table.insert(list, p) end
    return list
end

-- FROM_PLAYER = nil means accept trades from anyone
local function requesterAllowed(p)
    if not CONFIG.FROM_PLAYER then return true end
    return p.Name:lower() == tostring(CONFIG.FROM_PLAYER):lower()
end

local requestIndex = 0
local function acceptRequests()
    local targets = {}
    for _, p in ipairs(getRequesters()) do
        if requesterAllowed(p) then table.insert(targets, p) end
    end

    if #targets == 0 then
        -- popup not readable: cycle through a few players per tick instead
        local candidates = {}
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer and requesterAllowed(p) then table.insert(candidates, p) end
        end
        for _ = 1, math.min(3, #candidates) do
            requestIndex = (requestIndex % #candidates) + 1
            table.insert(targets, candidates[requestIndex])
        end
    end

    for _, p in ipairs(targets) do
        fireRemote("TradeAPI/AcceptOrDeclineTradeRequest", p, true)
    end
end

local popupState = { clicks = 0, ignoreUntil = 0 }
local MAX_POPUP_CLICKS = 3

local function handleIncomingRequests()
    acceptRequests()

    if not CONFIG.USE_CLICK_FALLBACK then return end

    local dialog, text = pendingTradeRequestDialog()
    if not dialog then
        popupState.clicks = 0
        return
    end
    if tradeGuiVisible() or os.clock() < popupState.ignoreUntil then return end
    if popupState.clicks >= MAX_POPUP_CLICKS then return end

    task.wait(1)
    dialog = pendingTradeRequestDialog()
    if dialog and not tradeGuiVisible() then
        local btn = findButtonByText(dialog, "accept")
        if btn then
            popupState.clicks = popupState.clicks + 1
            print(string.format("🖱️ Clicking Accept on popup (%d/%d): %s", popupState.clicks, MAX_POPUP_CLICKS, tostring(text)))
            clickGuiObject(btn)
        end
    end
end

-- ---- trade window: Accept and Confirm, once per second ----

local function handleTradeWindow()
    local gui = LocalPlayer.PlayerGui:FindFirstChild("TradeApp")

    acceptNegotiation()
    task.wait(0.5)
    confirmTrade()
    task.wait(0.5)

    if CONFIG.USE_CLICK_FALLBACK then
        local acceptBtn = findButtonByText(gui, "accept")
        if acceptBtn then clickGuiObject(acceptBtn) end
        local confirmBtn = findButtonByText(gui, "confirm")
        if confirmBtn then clickGuiObject(confirmBtn) end
    end
end

-- Work out who we're trading with by finding a player's name in the trade window text
local currentTrader = nil

local function guessTrader()
    local found = nil
    pcall(function()
        local gui = LocalPlayer.PlayerGui:FindFirstChild("TradeApp")
        if not gui then return end
        for _, d in ipairs(gui:GetDescendants()) do
            if d:IsA("TextLabel") and d.Text ~= "" then
                for _, p in ipairs(Players:GetPlayers()) do
                    if p ~= LocalPlayer and (d.Text:find(p.Name, 1, true) or d.Text:find(p.DisplayName, 1, true)) then
                        found = p.Name
                        return
                    end
                end
            end
        end
    end)
    return found
end

-- ============================================
-- HEADER
-- ============================================

print("\n" .. ("="):rep(50))
print("🤲 AUTO ACCEPT + TELEGRAM REPORTER - ACTIVE")
print(("="):rep(50))
print("Account: " .. playerName)
if CONFIG.FROM_PLAYER then
    print("Accepting trades from: " .. CONFIG.FROM_PLAYER)
else
    print("Accepting trades from: ANYONE")
end
print(("="):rep(50) .. "\n")

sendTelegram(string.format("🟢 %s is now online and auto-accepting trades.", playerName))

-- ============================================
-- MAIN LOOP: watch for trade open -> close transitions
-- ============================================

local running = true
local wasTradeOpen = false
local beforeSnapshot = nil
local tradesHandled = 0
local startTime = os.time()

-- ============================================
-- SERVER PLAYER REPORTING
-- ============================================

local function formatPlayer(p)
    if p.DisplayName ~= p.Name then
        return string.format("%s (@%s)", p.DisplayName, p.Name)
    end
    return "@" .. p.Name
end

local function serverSummary()
    local lines = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then table.insert(lines, "• " .. formatPlayer(p)) end
    end
    table.sort(lines)
    local header = string.format("👥 %d player%s in server (id %s)",
        #Players:GetPlayers(), #Players:GetPlayers() == 1 and "" or "s", string.sub(game.JobId, 1, 8))
    return header .. (#lines > 0 and ("\n" .. table.concat(lines, "\n")) or "")
end

if CONFIG.LIST_PLAYERS_ON_START then
    sendLong(serverSummary())
end

if CONFIG.REPORT_JOINS and CONFIG.JOIN_REPORT_INTERVAL > 0 then
    local joinedBuf, leftBuf = {}, {}

    Players.PlayerAdded:Connect(function(p)
        table.insert(joinedBuf, formatPlayer(p))
    end)
    Players.PlayerRemoving:Connect(function(p)
        if p ~= LocalPlayer then table.insert(leftBuf, formatPlayer(p)) end
    end)

    spawn(function()
        while running do
            task.wait(CONFIG.JOIN_REPORT_INTERVAL)
            if #joinedBuf > 0 or #leftBuf > 0 then
                local parts = {}
                if #joinedBuf > 0 then
                    table.insert(parts, string.format("➕ Joined (%d): %s", #joinedBuf, table.concat(joinedBuf, ", ")))
                end
                if #leftBuf > 0 then
                    table.insert(parts, string.format("➖ Left (%d): %s", #leftBuf, table.concat(leftBuf, ", ")))
                end
                table.insert(parts, string.format("👥 Now %d players in server", #Players:GetPlayers()))
                joinedBuf, leftBuf = {}, {}
                sendLong(table.concat(parts, "\n"))
            end
        end
    end)
end

-- Loop 1: watch for incoming trade requests
spawn(function()
    while running do
        pcall(handleIncomingRequests)
        task.wait(1)
    end
end)

-- Loop 2: while a trade window is open, accept -> confirm in order
spawn(function()
    while running do
        if tradeGuiVisible() then
            pcall(handleTradeWindow)
        else
            task.wait(0.5)
        end
    end
end)

if CONFIG.HEARTBEAT_INTERVAL and CONFIG.HEARTBEAT_INTERVAL > 0 then
    spawn(function()
        while running do
            task.wait(CONFIG.HEARTBEAT_INTERVAL)
            local uptimeMin = math.floor((os.time() - startTime) / 60)
            sendTelegram(string.format(
                "🟢 %s still online — up %dm, %d trade%s handled, %d players in server.",
                playerName, uptimeMin, tradesHandled, tradesHandled == 1 and "" or "s", #Players:GetPlayers()
            ))
        end
    end)
end

while running do
    local isOpen = tradeGuiVisible()

    if isOpen and not wasTradeOpen then
        -- Trade window just opened - snapshot inventory now, before anything is added
        print("📋 Trade window opened - taking before-snapshot")
        beforeSnapshot = snapshotInventory()
        task.delay(1.5, function() currentTrader = guessTrader() end)

    elseif not isOpen and wasTradeOpen then
        -- Trade window just closed - trade either completed or was cancelled
        print("📋 Trade window closed - checking what changed")
        popupState.ignoreUntil = os.clock() + 12
        task.wait(2) -- let inventory sync server-side before reading it

        local afterSnapshot = snapshotInventory()
        local gained = beforeSnapshot and diffSnapshots(beforeSnapshot, afterSnapshot) or {}

        local hasItems = false
        for _ in pairs(gained) do hasItems = true break end

        if hasItems then
            local lines = {}
            local totalCount = 0

            for kind, count in pairs(gained) do
                local info = kindInfo[kind] or { name = kind, category = "?" }
                table.insert(lines, string.format("• %dx %s", count, info.name))
                totalCount = totalCount + count
            end

            table.sort(lines)

            local header = currentTrader
                and string.format("🎁 Trade received from %s:", currentTrader)
                or "🎁 Trade received:"

            local message = header .. "\n" .. table.concat(lines, "\n")
                .. string.format("\n\nTotal items: %d", totalCount)

            print("\n" .. message .. "\n")
            sendTelegram(message)
            tradesHandled = tradesHandled + 1
        else
            print("ℹ️ No items gained (trade may have been declined/cancelled)")
        end

        currentTrader = nil
        beforeSnapshot = nil
    end

    wasTradeOpen = isOpen
    task.wait(0.5)
end
