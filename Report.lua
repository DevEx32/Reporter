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

local function sendMessengerText(text)
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
-- TRADE REMOTES
-- ============================================

local API = ReplicatedStorage:WaitForChild("API")

local function acceptTradeRequest()
    pcall(function()
        local remote = API:FindFirstChild("TradeAPI/AcceptTradeRequest")
        if remote then remote:FireServer() end
    end)
end

local function readyTrade()
    pcall(function()
        local remote = API:FindFirstChild("TradeAPI/SetPlayerReady")
        if remote then remote:FireServer() end
    end)
end

local function confirmTrade()
    pcall(function()
        local remote = API:FindFirstChild("TradeAPI/ConfirmTrade")
        if remote then remote:FireServer({}) end
    end)
end

local function tradeGuiVisible()
    local gui = LocalPlayer.PlayerGui:FindFirstChild("TradeApp")
    return gui and gui.Frame and gui.Frame.Visible
end

-- ============================================
-- TRACK WHO SENT THE CURRENT TRADE
-- ============================================

local currentTrader = nil

local TradeEvents = ReplicatedStorage:FindFirstChild("TradeEvents")
if TradeEvents then
    local tradeRequestEvent = TradeEvents:FindFirstChild("TradeRequest")
    if tradeRequestEvent then
        tradeRequestEvent.OnClientEvent:Connect(function(traderUsername)
            print(string.format("\n📨 Trade request from: %s", tostring(traderUsername)))

            if CONFIG.FROM_PLAYER and traderUsername ~= CONFIG.FROM_PLAYER then
                print("❌ Ignoring (not from " .. CONFIG.FROM_PLAYER .. ")")
                return
            end

            currentTrader = traderUsername
            task.wait(0.5)
            acceptTradeRequest()
        end)
    end
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

sendMessengerText(string.format("🟢 %s is now online and auto-accepting trades.", playerName))

-- ============================================
-- MAIN LOOP: watch for trade open -> close transitions
-- ============================================

local running = true
local wasTradeOpen = false
local beforeSnapshot = nil
local tradesHandled = 0
local startTime = os.time()

spawn(function()
    while running do
        -- Background accept/ready/confirm spam while a trade window is open
        acceptTradeRequest()
        readyTrade()
        confirmTrade()
        task.wait(0.4)
    end
end)

if CONFIG.HEARTBEAT_INTERVAL and CONFIG.HEARTBEAT_INTERVAL > 0 then
    spawn(function()
        while running do
            task.wait(CONFIG.HEARTBEAT_INTERVAL)
            local uptimeMin = math.floor((os.time() - startTime) / 60)
            sendMessengerText(string.format(
                "🟢 %s still online — up %dm, %d trade%s handled.",
                playerName, uptimeMin, tradesHandled, tradesHandled == 1 and "" or "s"
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

    elseif not isOpen and wasTradeOpen then
        -- Trade window just closed - trade either completed or was cancelled
        print("📋 Trade window closed - checking what changed")
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
            sendMessengerText(message)
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
