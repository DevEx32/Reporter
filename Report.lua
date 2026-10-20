-- ============================================
-- AUTO ACCEPT + TELEGRAM TRADE REPORTER  v2
-- * Accepts trades from anyone (or one player)
-- * Reports exactly what was received (neon / mega / fly-ride / age)
-- * Warns if items LEAVE your inventory in a trade
-- * Kick / disconnect alerts
-- * Telegram commands: /status /summary /players /pause /resume /help
-- * Server player list + batched join/leave reports
-- ============================================

if not getgenv().TelegramReportConfig then
    error("❌ ERROR: No configuration found!\n\nExample:\n\ngetgenv().TelegramReportConfig = {\n    BOT_TOKEN = \"your_bot_token\",\n    CHAT_ID = \"your_chat_id\",\n}")
end

local CONFIG = getgenv().TelegramReportConfig

if not CONFIG.BOT_TOKEN or CONFIG.BOT_TOKEN == "" then
    error("❌ BOT_TOKEN is required!")
end
if not CONFIG.CHAT_ID or tostring(CONFIG.CHAT_ID) == "" then
    error("❌ CHAT_ID is required!")
end

local function default(key, value)
    if CONFIG[key] == nil then CONFIG[key] = value end
end

default("FROM_PLAYER", nil)            -- nil = accept trades from anyone
default("HEARTBEAT_INTERVAL", 900)     -- "still online" ping, seconds (0 = off)
default("REPORT_JOINS", true)          -- report who joins/leaves the server
default("JOIN_REPORT_INTERVAL", 60)    -- batch joins/leaves into one message per X sec
default("LIST_PLAYERS_ON_START", true) -- send the player list on start
default("USE_CLICK_FALLBACK", true)    -- also click the on-screen Accept/Confirm buttons
default("COMMANDS_ENABLED", true)      -- Telegram commands (/status etc.)
default("COMMAND_POLL_INTERVAL", 3)    -- seconds between command checks
default("KICK_ALERTS", true)           -- message you when the account is kicked/disconnected
default("SAVE_LOG", true)              -- append trade reports to a local .txt (if executor supports it)
default("DEBUG_START_INFO", true)      -- send detected trade remotes to Telegram on start

-- ============================================
-- SETUP
-- ============================================

repeat task.wait() until game:IsLoaded()
repeat task.wait(1) until game:GetService("ReplicatedStorage"):FindFirstChild("ClientModules")
task.wait(2)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")
local VirtualInputManager
pcall(function() VirtualInputManager = game:GetService("VirtualInputManager") end)

local LocalPlayer = Players.LocalPlayer
local playerName = LocalPlayer.Name
local request = (syn and syn.request) or (http and http.request) or http_request or request

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
-- SESSION STATE
-- ============================================

local running = true
local paused = false
local tradesHandled = 0
local totalReceived = 0
local sessionReceived = {} -- label -> count
local startTime = os.time()
local currentTrader = nil
local popupState = { clicks = 0, ignoreUntil = 0 }

-- ============================================
-- TELEGRAM SEND (retries + rate-limit handling)
-- ============================================

local TG_BASE = "https://api.telegram.org/bot" .. CONFIG.BOT_TOKEN

local function sendTelegram(text)
    for attempt = 1, 3 do
        local ok, response = pcall(function()
            return request({
                Url = TG_BASE .. "/sendMessage",
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = HttpService:JSONEncode({
                    chat_id = CONFIG.CHAT_ID,
                    text = text
                })
            })
        end)

        if ok and response then
            local code = response.StatusCode
            if code and code >= 200 and code < 300 then
                return true
            end

            if code == 429 then
                -- Telegram rate limit: wait as long as it asks, then retry
                local delaySec = 3
                pcall(function()
                    local body = HttpService:JSONDecode(response.Body)
                    delaySec = math.min((body.parameters and body.parameters.retry_after) or 3, 30)
                end)
                task.wait(delaySec + 0.5)
            elseif code and code >= 400 and code < 500 then
                warn("❌ Telegram send failed: HTTP " .. tostring(code) .. " - " .. tostring(response.Body))
                warn("   (Check BOT_TOKEN and CHAT_ID, and make sure you pressed Start on your bot)")
                return false
            else
                task.wait(attempt)
            end
        else
            task.wait(attempt)
        end
    end

    warn("❌ Telegram send failed after 3 attempts")
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

local function saveLog(text)
    if not CONFIG.SAVE_LOG or not appendfile then return end
    pcall(appendfile, "trade_log_" .. playerName .. ".txt",
        string.format("[%s]\n%s\n\n", os.date("%Y-%m-%d %H:%M:%S"), text))
end

-- ============================================
-- ITEM LABELS + INVENTORY DIFF
-- ============================================

-- <<PURE-START>>
local AGE_NAMES = { "Newborn", "Junior", "Pre-Teen", "Teen", "Post-Teen", "Full Grown" }

-- Returns (key, label). Pets get neon/mega, fly/ride and age in the label so
-- different versions of the same pet are counted separately.
local function describeItem(kindInfo, category, item)
    local info = kindInfo[item.kind] or { name = item.kind }
    local name = info.name

    if category ~= "pets" then
        return category .. "|" .. tostring(item.kind), name
    end

    local props = item.properties or {}
    local prefix = props.mega_neon and "Mega Neon " or (props.neon and "Neon " or "")

    local extras = {}
    local flags = ""
    if props.flyable then flags = flags .. "F" end
    if props.rideable then flags = flags .. "R" end
    if flags ~= "" then table.insert(extras, flags) end

    if not props.mega_neon and props.age and props.age >= 1 then
        table.insert(extras, AGE_NAMES[props.age] or ("age " .. tostring(props.age)))
    end

    local label = prefix .. name
    if #extras > 0 then
        label = label .. " (" .. table.concat(extras, ", ") .. ")"
    end

    return category .. "|" .. tostring(item.kind) .. "|" .. label, label
end

-- before/after: key -> { label = string, count = number }
local function diffSnapshots(before, after)
    local gained, lost = {}, {}

    for key, a in pairs(after) do
        local b = before[key] and before[key].count or 0
        if a.count > b then
            gained[a.label] = (gained[a.label] or 0) + (a.count - b)
        end
    end

    for key, b in pairs(before) do
        local a = after[key] and after[key].count or 0
        if b.count > a then
            lost[b.label] = (lost[b.label] or 0) + (b.count - a)
        end
    end

    return gained, lost
end

local function formatCounts(map)
    local lines, total = {}, 0
    for label, n in pairs(map) do
        table.insert(lines, string.format("• %dx %s", n, label))
        total = total + n
    end
    table.sort(lines)
    return lines, total
end

-- Returns message text (or "" if nothing changed), items gained, items lost
local function buildTradeReport(trader, gained, lost)
    local parts = {}

    local gl, gt = formatCounts(gained)
    if gt > 0 then
        local header = trader and ("🎁 Trade received from " .. trader .. ":") or "🎁 Trade received:"
        table.insert(parts, header .. "\n" .. table.concat(gl, "\n") .. string.format("\n\nTotal items: %d", gt))
    end

    local ll, lt = formatCounts(lost)
    if lt > 0 then
        local header = trader and ("⚠️ Items that LEFT your inventory (trade with " .. trader .. "):")
            or "⚠️ Items that LEFT your inventory:"
        table.insert(parts, header .. "\n" .. table.concat(ll, "\n") .. string.format("\n\nTotal items: %d", lt))
    end

    return table.concat(parts, "\n\n"), gt, lt
end
-- <<PURE-END>>

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

local function snapshotInventory()
    local snap = {}
    local playerData = Data.get_data()[playerName]
    if not playerData or not playerData.inventory then return snap end

    for _, category in ipairs(INVENTORY_CATEGORIES) do
        local inv = playerData.inventory[category]
        if inv then
            for _, item in pairs(inv) do
                if item.kind then
                    local key, label = describeItem(kindInfo, category, item)
                    if not snap[key] then snap[key] = { label = label, count = 0 } end
                    snap[key].count = snap[key].count + 1
                end
            end
        end
    end

    return snap
end

-- ============================================
-- TRADE REMOTES (auto-detected)
-- ============================================

local API = ReplicatedStorage:WaitForChild("API")

local function findRemote(exactName, patterns)
    local direct = API:FindFirstChild(exactName)
    if direct then return direct end
    for _, child in ipairs(API:GetChildren()) do
        local n = child.Name:lower()
        local match = true
        for _, pat in ipairs(patterns) do
            if not n:find(pat, 1, true) then match = false break end
        end
        if match then return child end
    end
    return nil
end

local requestRemote = findRemote("TradeAPI/AcceptOrDeclineTradeRequest", { "accept", "request" })
local negotiationRemote = findRemote("TradeAPI/AcceptNegotiation", { "acceptnegotiation" })
local confirmRemote = findRemote("TradeAPI/ConfirmTrade", { "confirmtrade" })

local tradeRemoteNames = {}
for _, child in ipairs(API:GetChildren()) do
    if child.Name:lower():find("trade", 1, true) then
        table.insert(tradeRemoteNames, child.Name)
    end
end
table.sort(tradeRemoteNames)

print("🔎 Trade remotes found:")
for _, n in ipairs(tradeRemoteNames) do print("   " .. n) end
print("   request  -> " .. (requestRemote and requestRemote.Name or "NOT FOUND (click fallback only)"))
print("   accept   -> " .. (negotiationRemote and negotiationRemote.Name or "NOT FOUND"))
print("   confirm  -> " .. (confirmRemote and confirmRemote.Name or "NOT FOUND"))

local function fireRemote(remote, ...)
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

local function acceptNegotiation() fireRemote(negotiationRemote) end
local function confirmTrade() fireRemote(confirmRemote) end

-- ============================================
-- UI HELPERS (visibility checks + simulated clicks)
-- ============================================

local function isShown(obj)
    local p = obj
    while p and p ~= LocalPlayer.PlayerGui do
        if p:IsA("GuiObject") and not p.Visible then return false end
        if p:IsA("ScreenGui") and not p.Enabled then return false end
        p = p.Parent
    end
    if (obj:IsA("TextLabel") or obj:IsA("TextButton")) and obj.TextTransparency > 0.6 then
        return false -- faded / leftover text
    end
    return obj.AbsoluteSize.X > 0
end

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

local function clickGuiObject(obj)
    if not VirtualInputManager then return false end
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

-- ============================================
-- INCOMING TRADE REQUESTS
-- ============================================

-- Popup DialogApp + its text if a "trade request" popup is showing (respects FROM_PLAYER)
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

-- Players named in a visible trade-request popup
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

local function requesterAllowed(p)
    if not CONFIG.FROM_PLAYER then return true end
    return p.Name:lower() == tostring(CONFIG.FROM_PLAYER):lower()
end

local requestIndex = 0
local function acceptRequests()
    if not requestRemote then return end

    local targets = {}
    for _, p in ipairs(getRequesters()) do
        if requesterAllowed(p) then table.insert(targets, p) end
    end

    if #targets == 0 then
        -- popup not readable: cycle through a few players per tick
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
        fireRemote(requestRemote, p, true)
    end
end

local MAX_POPUP_CLICKS = 3

local function handleIncomingRequests()
    acceptRequests()

    if not CONFIG.USE_CLICK_FALLBACK then return end

    local dialog, text = pendingTradeRequestDialog()
    if not dialog then
        popupState.clicks = 0 -- popup gone: next request starts fresh
        return
    end

    -- A trade is running (or just finished): a popup still showing is a leftover
    if tradeGuiVisible() or os.clock() < popupState.ignoreUntil then return end
    if popupState.clicks >= MAX_POPUP_CLICKS then return end

    task.wait(1) -- give the remote a moment first
    dialog = pendingTradeRequestDialog()
    if dialog and not tradeGuiVisible() then
        local btn = findButtonByText(dialog, "accept")
        if btn then
            popupState.clicks = popupState.clicks + 1
            print(string.format("🖱️ Clicking Accept on popup (%d/%d): %s",
                popupState.clicks, MAX_POPUP_CLICKS, tostring(text)))
            clickGuiObject(btn)
        end
    end
end

-- ============================================
-- TRADE WINDOW: Accept -> Confirm
-- ============================================

local function handleTradeWindow()
    local gui = LocalPlayer.PlayerGui:FindFirstChild("TradeApp")

    acceptNegotiation()
    task.wait(1)
    if CONFIG.USE_CLICK_FALLBACK then
        local acceptBtn = findButtonByText(gui, "accept")
        if acceptBtn then clickGuiObject(acceptBtn) end
    end

    confirmTrade()
    task.wait(1)
    if CONFIG.USE_CLICK_FALLBACK then
        local confirmBtn = findButtonByText(gui, "confirm")
        if confirmBtn then clickGuiObject(confirmBtn) end
    end
end

-- Work out who we're trading with from names shown in the trade window
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
-- SERVER PLAYER INFO
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
    local total = #Players:GetPlayers()
    local header = string.format("👥 %d player%s in server (id %s)",
        total, total == 1 and "" or "s", string.sub(game.JobId, 1, 8))
    return header .. (#lines > 0 and ("\n" .. table.concat(lines, "\n")) or "")
end

-- ============================================
-- TELEGRAM COMMANDS
-- ============================================

local function statusText()
    local uptimeMin = math.floor((os.time() - startTime) / 60)
    return string.format(
        "📊 %s\nState: %s\nUptime: %dm\nTrades handled: %d (%d items received)\nPlayers in server: %d\nIn a trade now: %s",
        playerName,
        paused and "⏸️ PAUSED" or "🟢 Active",
        uptimeMin, tradesHandled, totalReceived,
        #Players:GetPlayers(),
        tradeGuiVisible() and "yes" or "no"
    )
end

local function summaryText()
    local lines, total = formatCounts(sessionReceived)
    if total == 0 then return "📦 Nothing received this session yet." end
    return string.format("📦 Received this session (%d items):\n%s", total, table.concat(lines, "\n"))
end

local HELP_TEXT = "Commands:\n/status - uptime, trades, state\n/summary - everything received this session\n/players - who's in the server\n/pause - stop accepting trades\n/resume - start accepting again\n/help - this list"

local function handleCommand(text)
    local cmd = text:lower():match("^/(%w+)")
    if not cmd then return end

    if cmd == "status" then
        sendLong(statusText())
    elseif cmd == "summary" then
        sendLong(summaryText())
    elseif cmd == "players" then
        sendLong(serverSummary())
    elseif cmd == "pause" then
        paused = true
        sendTelegram("⏸️ " .. playerName .. " paused - not accepting trades. Send /resume to continue.")
    elseif cmd == "resume" then
        paused = false
        sendTelegram("▶️ " .. playerName .. " resumed - accepting trades again.")
    elseif cmd == "help" or cmd == "start" then
        sendTelegram(HELP_TEXT)
    else
        sendTelegram("Unknown command.\n\n" .. HELP_TEXT)
    end
end

local function commandLoop()
    local warned409 = false

    local function getUpdates(offset)
        local ok, response = pcall(function()
            return request({
                Url = TG_BASE .. "/getUpdates?timeout=0&offset=" .. tostring(offset),
                Method = "GET"
            })
        end)
        if not ok or not response then return nil, nil end
        if response.StatusCode ~= 200 then return nil, response.StatusCode end
        local okd, data = pcall(HttpService.JSONDecode, HttpService, response.Body)
        if not okd or type(data) ~= "table" or not data.ok then return nil, nil end
        return data.result, 200
    end

    -- Skip anything sent before the script started
    local offset = 0
    local first = getUpdates(-1)
    if first and #first > 0 then offset = first[#first].update_id + 1 end

    while running do
        local updates, code = getUpdates(offset)
        if updates then
            for _, u in ipairs(updates) do
                offset = u.update_id + 1
                local m = u.message
                -- Only obey messages from YOUR chat
                if m and m.text and m.chat and tostring(m.chat.id) == tostring(CONFIG.CHAT_ID) then
                    pcall(handleCommand, m.text)
                end
            end
        elseif code == 409 and not warned409 then
            warned409 = true
            warn("⚠️ Telegram commands: another script is polling this bot (409). Use one bot per account, or set COMMANDS_ENABLED = false on the others.")
        end
        task.wait(CONFIG.COMMAND_POLL_INTERVAL)
    end
end

-- ============================================
-- KICK / DISCONNECT ALERTS
-- ============================================

local lastKickAlert = -100

local function reportDisconnect(reason)
    if os.clock() - lastKickAlert < 20 then return end
    lastKickAlert = os.clock()
    local uptimeMin = math.floor((os.time() - startTime) / 60)
    sendTelegram(string.format("🔴 %s was disconnected / kicked.\nReason: %s\nUptime %dm, %d trade%s handled.",
        playerName, tostring(reason), uptimeMin, tradesHandled, tradesHandled == 1 and "" or "s"))
end

if CONFIG.KICK_ALERTS then
    pcall(function()
        GuiService.ErrorMessageChanged:Connect(function()
            local msg = GuiService:GetErrorMessage()
            if msg and msg ~= "" then reportDisconnect(msg) end
        end)
    end)

    task.spawn(function()
        pcall(function()
            local overlay = game:GetService("CoreGui"):WaitForChild("RobloxPromptGui", 10):WaitForChild("promptOverlay", 10)
            overlay.ChildAdded:Connect(function(child)
                if child.Name == "ErrorPrompt" then
                    task.wait(0.5)
                    local best = ""
                    for _, d in ipairs(child:GetDescendants()) do
                        if d:IsA("TextLabel") and #d.Text > #best then best = d.Text end
                    end
                    reportDisconnect(best ~= "" and best or "Unknown reason")
                end
            end)
        end)
    end)
end

-- ============================================
-- HEADER + START MESSAGES
-- ============================================

print("\n" .. ("="):rep(50))
print("🤲 AUTO ACCEPT + TELEGRAM REPORTER v2 - ACTIVE")
print(("="):rep(50))
print("Account: " .. playerName)
print("Accepting trades from: " .. (CONFIG.FROM_PLAYER and tostring(CONFIG.FROM_PLAYER) or "ANYONE"))
print("Click fallback: " .. (CONFIG.USE_CLICK_FALLBACK and "ON" or "OFF"))
print("Commands: " .. (CONFIG.COMMANDS_ENABLED and "ON" or "OFF"))
print(("="):rep(50) .. "\n")

task.spawn(function()
    sendTelegram(string.format("🟢 %s is now online and auto-accepting trades.\nSend /help for commands.", playerName))

    if CONFIG.DEBUG_START_INFO then
        sendLong("🔎 Trade remotes detected:\n"
            .. (#tradeRemoteNames > 0 and table.concat(tradeRemoteNames, "\n") or "(none)")
            .. "\n\nrequest  -> " .. (requestRemote and requestRemote.Name or "NOT FOUND")
            .. "\naccept   -> " .. (negotiationRemote and negotiationRemote.Name or "NOT FOUND")
            .. "\nconfirm  -> " .. (confirmRemote and confirmRemote.Name or "NOT FOUND"))
    end

    if CONFIG.LIST_PLAYERS_ON_START then
        sendLong(serverSummary())
    end
end)

-- ============================================
-- BACKGROUND LOOPS
-- ============================================

-- Incoming trade requests
spawn(function()
    while running do
        if not paused then
            pcall(handleIncomingRequests)
        end
        task.wait(1)
    end
end)

-- Trade window: accept -> confirm
spawn(function()
    while running do
        if tradeGuiVisible() and not paused then
            pcall(handleTradeWindow)
        else
            task.wait(0.5)
        end
    end
end)

-- Heartbeat
if CONFIG.HEARTBEAT_INTERVAL and CONFIG.HEARTBEAT_INTERVAL > 0 then
    spawn(function()
        while running do
            task.wait(CONFIG.HEARTBEAT_INTERVAL)
            local uptimeMin = math.floor((os.time() - startTime) / 60)
            sendTelegram(string.format(
                "🟢 %s still online — up %dm, %d trade%s handled, %d players in server.%s",
                playerName, uptimeMin, tradesHandled, tradesHandled == 1 and "" or "s",
                #Players:GetPlayers(), paused and " ⏸️ PAUSED" or ""
            ))
        end
    end)
end

-- Joins / leaves (batched)
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

-- Telegram commands
if CONFIG.COMMANDS_ENABLED then
    spawn(commandLoop)
end

-- ============================================
-- MAIN LOOP: watch trade window open -> close
-- ============================================

local wasTradeOpen = false
local beforeSnapshot = nil

while running do
    local isOpen = tradeGuiVisible() and true or false

    if isOpen and not wasTradeOpen then
        print("📋 Trade window opened - taking before-snapshot")
        beforeSnapshot = snapshotInventory()
        task.delay(1.5, function() currentTrader = guessTrader() end)

    elseif not isOpen and wasTradeOpen then
        print("📋 Trade window closed - checking what changed")
        popupState.ignoreUntil = os.clock() + 12 -- any popup still showing is a leftover
        task.wait(2) -- let inventory sync before reading it

        local afterSnapshot = snapshotInventory()
        local gained, lost = {}, {}
        if beforeSnapshot then gained, lost = diffSnapshots(beforeSnapshot, afterSnapshot) end

        local message, gainedCount, lostCount = buildTradeReport(currentTrader, gained, lost)

        if message ~= "" then
            print("\n" .. message .. "\n")
            tradesHandled = tradesHandled + 1
            totalReceived = totalReceived + gainedCount
            for label, n in pairs(gained) do
                sessionReceived[label] = (sessionReceived[label] or 0) + n
            end
            saveLog(message)
            task.spawn(sendLong, message)
        else
            print("ℹ️ No items changed (trade may have been declined/cancelled)")
        end

        currentTrader = nil
        beforeSnapshot = nil
    end

    wasTradeOpen = isOpen
    task.wait(0.5)
end
