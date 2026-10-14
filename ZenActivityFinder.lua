local addonName, ns = ...
local UI = ns.UI

local VERSION = "2.1.1"
local PREFIX = "|cffd9a441Zen Activity Finder:|r "
local HEARTBEAT_SECONDS = 5 * 60
local REMOTE_TIMEOUT_SECONDS = 12 * 60
local PEER_TIMEOUT_SECONDS = 12 * 60
local MANUAL_REFRESH_COOLDOWN_SECONDS = 30
local PRESENCE_REPLY_COOLDOWN_SECONDS = 8
local APPLICATION_COOLDOWN_SECONDS = 2 * 60
local INACTIVE_REMOVAL_SECONDS = 60 * 60
local EXPIRY_VALUES = { 5, 10, 15, 20, 25, 30 }

local COLORS = {
    background = { 0.035, 0.043, 0.055, 0.98 },
    panel = { 0.065, 0.075, 0.095, 0.98 },
    panelLight = { 0.090, 0.102, 0.125, 1 },
    border = { 0.22, 0.25, 0.30, 1 },
    gold = { 0.92, 0.63, 0.40, 1 },
    text = { 0.92, 0.92, 0.92, 1 },
    muted = { 0.58, 0.62, 0.68, 1 },
    green = { 0.35, 0.78, 0.48, 1 },
    red = { 0.88, 0.32, 0.30, 1 },
}

local ebon = EbonAPI and EbonAPI:NewAddon("ZenActivityFinder", 2, 1, {
    icon = "Interface\\Icons\\INV_Misc_GroupLooking",
    updates = true,
    version = VERSION,
})

local OPS = {
    LISTING = "L",
    REMOVE = "X",
    REQUEST = "R",
    RESPONSE = "A",
    REFRESH = "Q",
    PRESENCE = "H",
}

local categories = {
    { key = "ALL", name = "All Activities", short = "All" },
    { key = "ORB", name = "Orb Farms", short = "Orb" },
    { key = "RAID", name = "Raids", short = "Raid" },
    { key = "QUEST", name = "Group Quests", short = "Quest" },
    { key = "WORLD", name = "Open World", short = "World" },
    { key = "CUSTOM", name = "Custom", short = "Custom" },
}

local categoryByKey = {}
for _, category in ipairs(categories) do
    categoryByKey[category.key] = category
end

local gameModes = {
    { key = "NORMAL", name = "Normal" },
    { key = "HC1", name = "HC1" },
    { key = "HC2", name = "HC2" },
    { key = "HC3", name = "HC3" },
    { key = "HC4", name = "HC4" },
    { key = "HC5", name = "HC5" },
}

local gameModeByKey = {}
for _, gameMode in ipairs(gameModes) do
    gameModeByKey[gameMode.key] = gameMode
end

local state = {
    category = "ALL",
    search = "",
    selectedID = nil,
    page = 1,
    pageSize = 5,
}

local runtime = {
    remoteListings = {},
    applicants = {},
    declineLockouts = {},
    inviteReservations = {},
    seenListings = {},
    requested = {},
    pendingInvites = {},
    interested = {},
    notificationReadyAt = 0,
    peerGameModes = {},
    currentGameMode = nil,
    lastManualRefreshAt = 0,
    lastRefreshResponseAt = 0,
    pendingRefreshBroadcastAt = nil,
    pendingPresenceResponseAt = nil,
    lastPresenceResponseAt = 0,
    outboundMessagesSent = 0,
    compactListingsReceived = 0,
    elapsed = 0,
    heartbeatElapsed = 0,
    channelRetryElapsed = 0,
    peers = {},
    lastReceivedAt = 0,
    protocolMessages = 0,
    processedRemotePayloads = 0,
    importedListingPackets = 0,
    outboundListingPackets = 0,
    lastRemoteCommand = "",
    lastTransportSender = "",
}

local defaultSettings = {
    shareListings = true,
    autoClose = true,
    autoInvite = false,
    autoWhisperInviteErrors = true,
    inviteFailureWhisper = "Please go to {group_mode} to join.",
    notifications = true,
    listingWatchCategory = "ALL",
    listingToasts = true,
    launcherAlerts = true,
    sounds = true,
    expiryMinutes = 15,
    showLauncher = true,
    lockLauncher = false,
    linkQuestLog = false,
}

local mainFrame
local createFrame
local listingRows = {}
local categoryButtons = {}
local details = {}
local searchBox
local listSummary
local emptyState
local previousButton
local nextButton
local pageText
local questLogHooked = false
local questLogVisibilityHooked = false
local settingsFrame
local applicantsFrame
local launcherButton
local toastFrame
local shareMenuFrame
local appearanceFrame
local emptyCreateButton
local networkStatusText
local refreshButton
local BroadcastListing
local BroadcastRemoval
local BroadcastAllListings
local SendJoinRequest
local RefreshGroupState
local RefreshLauncher
local OpenSettingsFrame
local OpenApplicantsFrame
local AcceptApplicant
local DeclineApplicant
local EnsureChannel
local ToggleMainFrame
local ShowMainFrame
local RefreshSharedListings
local QueueDirectAction
local UpdateListings
local RefreshNotificationPresentation

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(message))
end

local function Trim(value)
    return (value or ""):match("^%s*(.-)%s*$")
end

local function StripChatFormatting(value)
    local text = tostring(value or "")
    text = text:gsub("|[cC]%x%x%x%x%x%x%x%x", "")
    text = text:gsub("|[rR]", "")
    text = text:gsub("|T.-|t", "")
    text = text:gsub("|A.-|a", "")
    text = text:gsub("|H.-|h(.-)|h", "%1")
    return text
end

local function KeepAllowedNameCharacters(value)
    local result = {}
    local index = 1
    value = tostring(value or "")
    while index <= #value do
        local byte = value:byte(index)
        if (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) then
            result[#result + 1] = value:sub(index, index)
            index = index + 1
        elseif byte >= 195 and byte <= 197 and index < #value then
            local continuation = value:byte(index + 1)
            if continuation and continuation >= 128 and continuation <= 191 then
                result[#result + 1] = value:sub(index, index + 1)
                index = index + 2
            else
                index = index + 1
            end
        else
            index = index + 1
        end
    end
    return table.concat(result, "")
end

local function SanitizePlayerName(value)
    local raw = tostring(value or "")
    local linkedName = raw:match("|Hplayer:([^:|]+)")
    local text = StripChatFormatting(linkedName or raw)
    local lastBracket
    for bracket in text:gmatch("%[([^%]]+)%]") do lastBracket = bracket end
    text = Trim(text:gsub("%b[]", " "))
    if text == "" then text = lastBracket or "" end
    text = text:gsub(":%s*$", "")
    text = text:match("([^%s]+)%s*$") or text
    text = text:match("^([^-]+)") or text
    local clean = KeepAllowedNameCharacters(text)
    return clean ~= "" and clean or "Unknown"
end

local function IsLocalPlayerName(value)
    local candidate = SanitizePlayerName(value)
    local playerName = SanitizePlayerName(UnitName("player") or "")
    return candidate ~= "Unknown"
        and playerName ~= "Unknown"
        and candidate:lower() == playerName:lower()
end

local function NormalizeExpiryMinutes(value)
    value = tonumber(value)
    for _, allowed in ipairs(EXPIRY_VALUES) do
        if value == allowed then return allowed end
    end
    return 15
end

local function NormalizeGameMode(value)
    value = tostring(value or "NORMAL"):upper():gsub("[%s%-_]", "")
    if value == "NORMAL" or value == "HC1" or value == "HC2" or value == "HC3" or value == "HC4" or value == "HC5" then
        return value
    end
    return "NORMAL"
end

local function GetGameModeName(value)
    local gameMode = gameModeByKey[NormalizeGameMode(value)]
    return gameMode and gameMode.name or "Normal"
end

local function GetEbonholdHardmodeService()
    if ProjectEbonhold and ProjectEbonhold.HardmodeService then
        return ProjectEbonhold.HardmodeService
    end
end

local function ReadEbonholdGameMode()
    local service = GetEbonholdHardmodeService()
    if not service then return nil end

    local tier
    if type(service.GetCurrentDifficulty) == "function" then
        local ok, value = pcall(service.GetCurrentDifficulty)
        if ok then tier = tonumber(value) end
    end
    if not tier and ProjectEbonhold then
        tier = tonumber(ProjectEbonhold.currentHardmodeTier)
    end
    if not tier or tier < 1 or tier > 6 then return nil end
    if tier == 1 then return "NORMAL" end
    return "HC" .. tostring(tier - 1)
end

local function RequestEbonholdGameMode()
    local service = GetEbonholdHardmodeService()
    if service and type(service.RequestHardmodeData) == "function" then
        pcall(service.RequestHardmodeData)
    end
end

local function ApplyDetectedGameMode(mode)
    mode = NormalizeGameMode(mode)
    if not gameModeByKey[mode] then return end
    local previous = runtime.currentGameMode
    runtime.currentGameMode = mode
    if createFrame and createFrame.modeButton then
        createFrame.modeButton.value = mode
        createFrame.modeButton.label:SetText(GetGameModeName(mode) .. " (Detected)")
        if createFrame.error and createFrame.error:GetText() == "Detecting your current game mode..." then
            createFrame.error:SetText("")
        end
    end
    if previous ~= mode and ZenActivityFinderDB
        and ZenActivityFinderDB.listings then
        for _, listing in ipairs(ZenActivityFinderDB.listings) do
            if listing.status == "OPEN" or listing.status == "FULL" then
                listing.gameMode = mode
                if BroadcastListing then BroadcastListing(listing) end
            end
        end
        if mainFrame then UpdateListings() end
    end
end

local function GetDetectedGameMode()
    local serviceMode = ReadEbonholdGameMode()
    if serviceMode then ApplyDetectedGameMode(serviceMode) end
    return serviceMode or runtime.currentGameMode or "NORMAL"
end

local function HideOtherSecondaryWindows(keep)
    if createFrame and createFrame ~= keep then createFrame:Hide() end
    if settingsFrame and settingsFrame ~= keep then settingsFrame:Hide() end
    if applicantsFrame and applicantsFrame ~= keep then applicantsFrame:Hide() end
end

local function GetActivePeerCount()
    local count = 0
    local now = time()
    for name, lastSeen in pairs(runtime.peers) do
        if now - lastSeen <= PEER_TIMEOUT_SECONDS then
            count = count + 1
        else
            runtime.peers[name] = nil
        end
    end
    return count
end

local function GetManualRefreshRemaining()
    if runtime.lastManualRefreshAt <= 0 then return 0 end
    return math.max(0, MANUAL_REFRESH_COOLDOWN_SECONDS - (time() - runtime.lastManualRefreshAt))
end

local function UpdateRefreshButton()
    if not refreshButton then return end
    local remaining = GetManualRefreshRemaining()
    refreshButton.label:SetText(remaining > 0 and ("Refresh " .. remaining .. "s") or "Refresh")
    refreshButton:SetButtonEnabled(remaining <= 0)
end

local function UpdateConnectionStatus()
    local connected = ebon and ebon:IsChannelJoined() or false
    local peerCount = GetActivePeerCount()
    if networkStatusText then
        if not connected then
            networkStatusText:SetText("OFFLINE")
            networkStatusText:SetTextColor(COLORS.red[1], COLORS.red[2], COLORS.red[3])
        elseif peerCount == 0 then
            networkStatusText:SetText("EBONAPI READY")
            local r, g, b = UI:Accent()
            networkStatusText:SetTextColor(r, g, b)
        else
            networkStatusText:SetText(peerCount .. " ZEN USERS")
            networkStatusText:SetTextColor(COLORS.green[1], COLORS.green[2], COLORS.green[3])
        end
    end
    if settingsFrame and settingsFrame.connection then
        if connected then
            settingsFrame.connection:SetText("EbonAPI connected - " .. peerCount .. " ZenActivityFinder user(s) detected")
        else
            settingsFrame.connection:SetText("Waiting for EbonAPI shared channel")
        end
    end
end

local function SetColor(texture, color)
    texture:SetTexture(color[1], color[2], color[3], color[4] or 1)
end

local function AddBackground(frame, color, borderColor)
    local kind = "section"
    if color == COLORS.background then kind = "panel" end
    if color == COLORS.panelLight then kind = "button" end
    UI:StyleSurface(frame, kind)
    if borderColor == COLORS.gold then
        frame._zenBorderAccent = true
        UI:RefreshSurface(frame)
    end
end

local function CreateText(parent, text, size, color, justify)
    color = color or COLORS.text
    local label
    if color == COLORS.gold or color == COLORS.green or color == COLORS.red then
        label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetText(text or "")
        label._zenSize = size or 12
        label._zenSemanticColor = color
        UI:BindStyle(label, function(fs)
            fs:SetFont(UI:FontPath(), fs._zenSize)
            local c = fs._zenSemanticColor
            if c == COLORS.gold then
                local r, g, b = UI:Accent()
                fs:SetTextColor(r, g, b, 1)
            else
                fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
            end
            fs:SetShadowColor(0, 0, 0, 0.5)
            fs:SetShadowOffset(1, -1)
        end)
    else
        label = UI:CreateText(parent, text or "", size or 12, color == COLORS.muted)
    end
    label:SetJustifyH(justify or "LEFT")
    label:SetJustifyV("MIDDLE")
    return label
end

local function CreateButton(parent, text, width, height)
    local button = UI:CreateButton(parent, text or "", width or 120, height or 28)
    function button:SetButtonEnabled(enabled)
        if enabled then
            self:Enable()
            self.label:SetAlpha(1)
        else
            self:Disable()
            self.label:SetAlpha(0.45)
        end
    end
    return button
end

local function CreateInput(parent, width, height, maxLetters)
    local input = UI:CreateEditBox(parent, "", width or 220, height or 28)
    input:SetMaxLetters(maxLetters or 80)
    input:SetJustifyH("LEFT")
    input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    input:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    input.input = input
    return input, input
end

local function GetCurrentGroupSize()
    local raidCount = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raidCount > 0 then return raidCount end
    local partyCount = GetNumPartyMembers and GetNumPartyMembers() or 0
    return partyCount > 0 and (partyCount + 1) or 1
end

local function IsPlayerInGroup(name)
    if not name or name == "" then return false end
    local lowered = name:lower()
    local raidCount = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raidCount > 0 then
        for index = 1, raidCount do
            if (UnitName("raid" .. index) or ""):lower() == lowered then return true end
        end
    else
        local partyCount = GetNumPartyMembers and GetNumPartyMembers() or 0
        for index = 1, partyCount do
            if (UnitName("party" .. index) or ""):lower() == lowered then return true end
        end
    end
    return false
end

local function GetStatusLabel(status)
    if status == "FULL" then return "Full" end
    if status == "CLOSED" then return "Closed" end
    if status == "EXPIRED" then return "Expired" end
    return "Open"
end

local function GetListingKey(owner, id)
    return (owner or "Unknown"):lower() .. "#" .. tostring(id or "0")
end

local function Notify(message, sound)
    if not ZenActivityFinderDB or not ZenActivityFinderDB.settings.notifications then return end
    Print(message)
    if sound and ZenActivityFinderDB.settings.sounds and PlaySound then PlaySound("TellMessage") end
end

local function NormalizeListingWatchCategory(value)
    value = tostring(value or "OFF"):upper()
    if value == "ALL" or value == "ORB" or value == "RAID" or value == "QUEST"
        or value == "WORLD" or value == "CUSTOM" then
        return value
    end
    return "OFF"
end

local function GetListingWatchName(value)
    value = NormalizeListingWatchCategory(value)
    if value == "OFF" then return "Off" end
    if value == "ALL" then return "All Activities" end
    local category = categoryByKey[value]
    return category and category.name or "Off"
end

local function ShouldNotifyAboutListing(listing)
    if not listing or IsLocalPlayerName(listing.owner) then return false end
    if (listing.status or "OPEN") ~= "OPEN" then return false end
    if not ZenActivityFinderDB or not ZenActivityFinderDB.settings.notifications then return false end
    local watched = NormalizeListingWatchCategory(
        ZenActivityFinderDB.settings.listingWatchCategory)
    return watched == "ALL" or watched == listing.category
end

local function GetListingsSource()
    if not ZenActivityFinderDB then return {} end
    local result = {}
    for _, listing in ipairs(ZenActivityFinderDB.listings) do
        table.insert(result, listing)
    end
    for _, listing in pairs(runtime.remoteListings) do
        if not IsLocalPlayerName(listing.owner)
            and (listing.status == "OPEN" or listing.status == "FULL") then
            table.insert(result, listing)
        end
    end
    return result
end

local function GetCategoryName(key)
    local category = categoryByKey[key]
    return category and category.name or "Custom"
end

local function GetCategoryShortName(key)
    local category = categoryByKey[key]
    return category and category.short or "Custom"
end

local ORB_EVENT_NAMES = {
    ["Coren Direbrew"] = true,
    ["The Headless Horseman"] = true,
    ["Ahune"] = true,
    ["Crown Chemical Co."] = true,
}

local ORB_CLASS_ROLES = {
    WARRIOR = { tank = true, dps = true },
    PALADIN = { tank = true, healer = true, dps = true },
    HUNTER = { dps = true },
    ROGUE = { dps = true },
    PRIEST = { healer = true, dps = true },
    DEATHKNIGHT = { tank = true, dps = true },
    SHAMAN = { healer = true, dps = true },
    MAGE = { dps = true },
    WARLOCK = { dps = true },
    DRUID = { tank = true, healer = true, dps = true },
}

local function DetectSelectedOrbEvent()
    local queueID = LFDQueueFrame and LFDQueueFrame.type
    if type(queueID) ~= "number" or type(GetLFGDungeonInfo) ~= "function" then return nil end
    local name = GetLFGDungeonInfo(queueID)
    if name and ORB_EVENT_NAMES[name] then return name end
    return nil
end

local function GetOrbPreset()
    local eventName = DetectSelectedOrbEvent()
    if eventName then
        return "EVENT", eventName, "Orb Farm - Event Boss: " .. eventName, eventName
    end
    return "TOC", "", "Orb Farm", "Trial of the Champion"
end

local function GetPartyRoleCapabilities(extraClassToken)
    local result = {}
    local _, playerClass = UnitClass("player")
    if playerClass and ORB_CLASS_ROLES[playerClass] then
        result[#result + 1] = ORB_CLASS_ROLES[playerClass]
    end
    local count = GetNumPartyMembers and (GetNumPartyMembers() or 0) or 0
    for index = 1, count do
        local unit = "party" .. index
        if not UnitExists or UnitExists(unit) then
            local _, classToken = UnitClass(unit)
            if classToken and ORB_CLASS_ROLES[classToken] then
                result[#result + 1] = ORB_CLASS_ROLES[classToken]
            end
        end
    end
    if extraClassToken and ORB_CLASS_ROLES[extraClassToken] then
        result[#result + 1] = ORB_CLASS_ROLES[extraClassToken]
    end
    return result
end

local function HasTankHealerAssignment(extraClassToken)
    local caps = GetPartyRoleCapabilities(extraClassToken)
    for tankIndex, tankRoles in ipairs(caps) do
        if tankRoles.tank then
            for healerIndex, healerRoles in ipairs(caps) do
                if healerIndex ~= tankIndex and healerRoles.healer then return true end
            end
        end
    end
    return false
end

local function GetOrbNeedCode()
    local partyMembers = GetNumPartyMembers and (GetNumPartyMembers() or 0) or 0
    if partyMembers < 3 then return "EVERYTHING" end
    if partyMembers >= 4 then return "NONE" end
    if HasTankHealerAssignment() then return "ANY" end

    local hasTank, hasHealer = false, false
    for _, roles in ipairs(GetPartyRoleCapabilities()) do
        hasTank = hasTank or roles.tank == true
        hasHealer = hasHealer or roles.healer == true
    end
    if hasTank and hasHealer then return "TANKHEALER" end
    if not hasTank and not hasHealer then return "TANKHEALER" end
    if not hasTank then return "TANK" end
    return "HEALER"
end

local function GetOrbNeedLabel(code)
    code = tostring(code or ""):upper()
    if code == "TANK" then return "Tank" end
    if code == "HEALER" then return "Healer" end
    if code == "TANKHEALER" then return "Tank / Healer" end
    if code == "EVERYTHING" then return "All roles" end
    if code == "ANY" then return "Any role" end
    if code == "NONE" then return "Group full" end
    return "Any role"
end

local function NormalizeOrbNeedCode(value)
    local text = tostring(value or ""):upper():gsub("[%s%p]", "")
    if text == "TANK" or text == "TANKROLE" then return "TANK" end
    if text == "HEALER" or text == "HEALERROLE" then return "HEALER" end
    if text == "TANKHEALER" or text == "TANKHEALERROLE" then return "TANKHEALER" end
    if text == "EVERYTHING" or text == "ALLROLES" then return "EVERYTHING" end
    if text == "NONE" or text == "FULL" or text == "GROUPFULL" then return "NONE" end
    return "ANY"
end

local function OrbRoleIcon(role)
    if GetTexCoordsForRoleSmallCircle then
        local left, right, top, bottom = GetTexCoordsForRoleSmallCircle(role)
        if left then
            return string.format("|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:16:16:0:0:64:64:%d:%d:%d:%d|t",
                left * 64, right * 64, top * 64, bottom * 64)
        end
    end
    if role == "TANK" then return "[T]" end
    if role == "HEALER" then return "[H]" end
    return "[D]"
end

local function GetClassRoleMarkup(classToken)
    local roles = ORB_CLASS_ROLES[classToken]
    if not roles then return "[?]" end
    local parts = {}
    if roles.tank then parts[#parts + 1] = OrbRoleIcon("TANK") end
    if roles.healer then parts[#parts + 1] = OrbRoleIcon("HEALER") end
    if roles.dps then parts[#parts + 1] = OrbRoleIcon("DAMAGER") end
    return table.concat(parts, " ")
end

local function CanClassFillOrbNeed(classToken, need)
    local roles = ORB_CLASS_ROLES[classToken]
    need = tostring(need or "ANY"):upper()
    if need == "NONE" then return false end
    if need == "EVERYTHING" or need == "ANY" or need == "" then return true end
    if not roles then return false end
    if need == "TANK" then return roles.tank == true end
    if need == "HEALER" then return roles.healer == true end
    if need == "TANKHEALER" then return roles.tank == true or roles.healer == true end
    if need == "DPS" then return roles.dps == true end
    return true
end

local function CanLocalPlayerFillOrbNeed(listing)
    if not listing or listing.category ~= "ORB" then return true end
    local _, classToken = UnitClass("player")
    return CanClassFillOrbNeed(classToken, listing.orbNeed)
end

local function GetOrbActivityText(listing)
    if not listing or listing.category ~= "ORB" then return listing and listing.activity or "" end
    if tostring(listing.orbMode or "TOC"):upper() == "EVENT" then
        local eventName = Trim(listing.orbEvent or listing.activity or "")
        return eventName ~= "" and ("Event Boss: " .. eventName) or "Event Boss Orb Farm"
    end
    return "Trial of the Champion Orb Farm"
end

local function ApplyOrbPresetToCreateFrame(force)
    if not createFrame then return end
    local mode, eventName, title, activity = GetOrbPreset()
    createFrame.orbMode = mode
    createFrame.orbEvent = eventName
    if createFrame.categoryButton then
        createFrame.categoryButton.value = "ORB"
        createFrame.categoryButton.label:SetText(GetCategoryName("ORB"))
    end
    if createFrame.sizeInput then createFrame.sizeInput:SetText("5") end
    if createFrame.titleInput and (force or Trim(createFrame.titleInput:GetText()) == "") then
        createFrame.titleInput:SetText(title)
    end
    if createFrame.activityInput and (force or Trim(createFrame.activityInput:GetText()) == "") then
        createFrame.activityInput:SetText(activity)
    end
    if createFrame.startInput and (force or Trim(createFrame.startInput:GetText()) == "") then
        createFrame.startInput:SetText("Now")
    end
    if createFrame.subtitle then
        createFrame.subtitle:SetText("Orb Farms are 5-player groups. The currently selected RDF event is detected automatically.")
    end
end

local function GetAgeText(listing)
    if listing.ageText then
        return listing.ageText
    end
    local elapsed = math.max(0, time() - (listing.createdAt or time()))
    if elapsed < 60 then
        return "just now"
    elseif elapsed < 3600 then
        return math.floor(elapsed / 60) .. " min ago"
    elseif elapsed < 86400 then
        return math.floor(elapsed / 3600) .. " hr ago"
    end
    return math.floor(elapsed / 86400) .. " days ago"
end

local function MatchesSearch(listing, search)
    if search == "" then return true end
    local haystack = table.concat({
        listing.title or "",
        listing.activity or "",
        listing.owner or "",
        listing.notes or "",
        listing.startTime or "",
        listing.orbEvent or "",
        GetOrbNeedLabel(listing.orbNeed),
        GetGameModeName(listing.gameMode),
        GetCategoryName(listing.category),
    }, " "):lower()
    return haystack:find(search, 1, true) ~= nil
end

local function GetFilteredListings()
    local source = GetListingsSource()
    local filtered = {}
    local search = Trim(state.search):lower()
    for _, listing in ipairs(source) do
        if (state.category == "ALL" or listing.category == state.category) and MatchesSearch(listing, search) then
            table.insert(filtered, listing)
        end
    end
    table.sort(filtered, function(a, b)
        local aOpen = (a.status or "OPEN") == "OPEN" and 1 or 0
        local bOpen = (b.status or "OPEN") == "OPEN" and 1 or 0
        if aOpen ~= bOpen then return aOpen > bOpen end
        return (a.createdAt or 0) > (b.createdAt or 0)
    end)
    return filtered
end

local function FindListingByID(id)
    if not id then return nil end
    local source = GetListingsSource()
    for _, listing in ipairs(source) do
        if listing.id == id then return listing end
    end
    return nil
end

local function FindOwnedListingByID(id)
    if not ZenActivityFinderDB or not id then return nil end
    for _, listing in ipairs(ZenActivityFinderDB.listings) do
        if tostring(listing.id) == tostring(id) then return listing end
    end
    return nil
end

local function IsOwnedListing(listing)
    if not listing then return false end
    if listing.isOwner == true then return true end
    local playerGUID = UnitGUID and UnitGUID("player")
    if playerGUID and listing.ownerGUID then return listing.ownerGUID == playerGUID end
    return IsLocalPlayerName(listing.owner)
end

local function FindActiveOwnedListing(exceptID)
    if not ZenActivityFinderDB then return nil end
    for _, listing in ipairs(ZenActivityFinderDB.listings or {}) do
        if tostring(listing.id) ~= tostring(exceptID)
            and IsOwnedListing(listing)
            and (listing.status == "OPEN" or listing.status == "FULL") then
            return listing
        end
    end
    return nil
end


local function CountTableEntries(values)
    local count = 0
    for _ in pairs(values or {}) do count = count + 1 end
    return count
end

local function GetInterestCount(listing)
    if not listing then return 0 end
    if IsOwnedListing(listing) then
        return CountTableEntries(runtime.interested[tostring(listing.id)])
    end
    return tonumber(listing.interestCount) or 0
end

local function NotifyRavioliMenuBadgeChanged()
    if RavioliMenu and type(RavioliMenu.Refresh) == "function" then
        RavioliMenu:Refresh()
    end
end

local function GetUnreadCount()
    if not ZenActivityFinderDB or not ZenActivityFinderDB.settings.notifications then return 0 end
    return math.max(0, tonumber(ZenActivityFinderDB.unreadCount) or 0)
end

local function SetUnreadCount(value)
    if not ZenActivityFinderDB then return end
    ZenActivityFinderDB.unreadCount = math.max(0, tonumber(value) or 0)
    if RefreshNotificationPresentation then RefreshNotificationPresentation() end
    NotifyRavioliMenuBadgeChanged()
end

local function ClearUnreadListings()
    SetUnreadCount(0)
end

local function OpenListingFromAlert(listingID)
    local listing = FindListingByID(listingID)
    if not listing then return end
    state.category = "ALL"
    state.search = ""
    state.page = 1
    state.selectedID = listing.id
    if searchBox then searchBox:SetText("") end
    if ShowMainFrame then ShowMainFrame(true) end
    UpdateListings()
end

local function BuildToastFrame()
    if toastFrame then return end
    toastFrame = CreateFrame("Frame", "ZenActivityFinderToast", UIParent)
    toastFrame:SetWidth(390)
    toastFrame:SetHeight(112)
    toastFrame:SetPoint("TOP", UIParent, "TOP", 0, -110)
    toastFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    toastFrame:EnableMouse(true)
    AddBackground(toastFrame, COLORS.background, COLORS.gold)
    toastFrame:Hide()

    toastFrame.heading = CreateText(toastFrame, "NEW FAMILY ACTIVITY", 9, COLORS.gold)
    toastFrame.heading:SetPoint("TOPLEFT", 14, -12)
    toastFrame.title = CreateText(toastFrame, "", 14, COLORS.text)
    toastFrame.title:SetPoint("TOPLEFT", 14, -32)
    toastFrame.title:SetWidth(350)
    toastFrame.meta = CreateText(toastFrame, "", 10, COLORS.muted)
    toastFrame.meta:SetPoint("TOPLEFT", 14, -55)
    toastFrame.meta:SetWidth(350)

    toastFrame.view = CreateButton(toastFrame, "View", 76, 26)
    toastFrame.view:SetPoint("BOTTOMRIGHT", -96, 10)
    toastFrame.view.label:SetTextColor(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
    toastFrame.view:SetScript("OnClick", function(self)
        local id = self:GetParent().listingID
        self:GetParent():Hide()
        OpenListingFromAlert(id)
    end)
    toastFrame.dismiss = CreateButton(toastFrame, "Dismiss", 76, 26)
    toastFrame.dismiss:SetPoint("BOTTOMRIGHT", -12, 10)
    toastFrame.dismiss:SetScript("OnClick", function(self) self:GetParent():Hide() end)
    toastFrame:SetScript("OnUpdate", function(self, elapsed)
        if not self:IsShown() then return end
        self.remaining = (self.remaining or 0) - elapsed
        if self.remaining <= 0 then self:Hide() end
    end)
end

local function ShowListingToast(listing)
    if not listing or not ZenActivityFinderDB.settings.notifications
        or not ZenActivityFinderDB.settings.listingToasts then return end
    BuildToastFrame()
    toastFrame.listingID = listing.id
    toastFrame.title:SetText(listing.title or "Untitled activity")
    toastFrame.meta:SetText((listing.owner or "Unknown") .. "  -  "
        .. GetCategoryShortName(listing.category) .. "  -  "
        .. tostring(listing.currentSize or 1) .. "/" .. tostring(listing.groupSize or 5))
    toastFrame.remaining = 12
    toastFrame:Show()
end

local function HandleNewRemoteListing(listing, isNew)
    if not isNew or not ShouldNotifyAboutListing(listing) then return end
    if runtime.notificationReadyAt > 0 and GetTime and GetTime() < runtime.notificationReadyAt then return end
    if mainFrame and mainFrame:IsShown() then return end
    SetUnreadCount(GetUnreadCount() + 1)
    ShowListingToast(listing)
    Notify("New " .. GetCategoryShortName(listing.category) .. " listing from "
        .. (listing.owner or "Unknown") .. ": " .. (listing.title or "Untitled activity"), true)
end

local function BuildShareText(listing)
    if not listing then return "" end
    local roleText = listing.category == "ORB" and (" - Need " .. GetOrbNeedLabel(listing.orbNeed)) or ""
    return "[Zen] " .. (listing.title or "Activity") .. " - "
        .. tostring(listing.currentSize or 1) .. "/" .. tostring(listing.groupSize or 5)
        .. " players" .. roleText .. " - " .. ((listing.startTime and listing.startTime ~= "") and listing.startTime or "Now")
        .. ". Open ZenActivityFinder to join."
end

local function ShareListingTo(listing, channel)
    local message = BuildShareText(listing)
    if message == "" then return end
    if channel == "PREPARE" then
        if ChatFrame_OpenChat then ChatFrame_OpenChat(message) end
        return
    end
    if SendChatMessage then SendChatMessage(message, channel) end
end

local function OpenShareMenu(listing)
    if not listing then return end
    if not shareMenuFrame then
        shareMenuFrame = CreateFrame("Frame", "ZenActivityFinderShareMenu", UIParent, "UIDropDownMenuTemplate")
    end
    local raidCount = GetNumRaidMembers and GetNumRaidMembers() or 0
    local partyCount = GetNumPartyMembers and GetNumPartyMembers() or 0
    local menu = {
        { text = "Share Activity", isTitle = true, notCheckable = true },
        { text = "Guild", notCheckable = true, disabled = IsInGuild and not IsInGuild(), func = function() ShareListingTo(listing, "GUILD") end },
        { text = "Party", notCheckable = true, disabled = partyCount == 0 or raidCount > 0, func = function() ShareListingTo(listing, "PARTY") end },
        { text = "Raid", notCheckable = true, disabled = raidCount == 0, func = function() ShareListingTo(listing, "RAID") end },
        { text = "Prepare chat message", notCheckable = true, func = function() ShareListingTo(listing, "PREPARE") end },
    }
    EasyMenu(menu, shareMenuFrame, "cursor", 0, 0, "MENU", 2)
end

local function IsListingInterested(listing)
    return listing and ZenActivityFinderDB.interestedListings
        and ZenActivityFinderDB.interestedListings[listing.id] == true
end

local function ToggleListingInterest(listing)
    if not listing or IsOwnedListing(listing) then return end
    ZenActivityFinderDB.interestedListings = ZenActivityFinderDB.interestedListings or {}
    local interested = not IsListingInterested(listing)
    if interested then
        ZenActivityFinderDB.interestedListings[listing.id] = true
    else
        ZenActivityFinderDB.interestedListings[listing.id] = nil
    end
    QueueDirectAction(OPS.RESPONSE,
        { listing.owner, "I", listing.remoteID or listing.id, interested and "1" or "0" })
    UpdateListings()
end
local function IsPlayerLeadingCurrentGroup()
    local raidCount = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raidCount > 0 then
        if IsRaidLeader then return IsRaidLeader() and true or false end
        if GetRaidRosterInfo then
            local playerName = (UnitName("player") or ""):lower()
            for index = 1, raidCount do
                local name, rank = GetRaidRosterInfo(index)
                if name and name:lower() == playerName then return rank == 2 end
            end
        end
        return false
    end

    local partyCount = GetNumPartyMembers and GetNumPartyMembers() or 0
    if partyCount > 0 then
        if IsPartyLeader then return IsPartyLeader() and true or false end
        if UnitIsPartyLeader then return UnitIsPartyLeader("player") and true or false end
        if GetPartyLeaderIndex then return GetPartyLeaderIndex() == 0 end
        return false
    end
    return true
end

local function IsOwnListedGroup(listing)
    if IsPlayerLeadingCurrentGroup() then return true end
    local reservations = runtime.inviteReservations[tostring(listing.id)] or {}
    for name in pairs(reservations) do
        if IsPlayerInGroup(name) then return true end
    end
    return false
end

local function GetApplicationCooldownRemaining(listingID)
    local requestedAt = runtime.requested[listingID]
    if not requestedAt then return 0 end
    return math.max(0, APPLICATION_COOLDOWN_SECONDS - (time() - requestedAt))
end

local function GetApplicantKey(name)
    return SanitizePlayerName(name):lower()
end

local function RemoveApplicantFromListing(listing, applicant)
    if not listing or not applicant then return end
    local applicants = runtime.applicants[tostring(listing.id)] or {}
    local targetKey = GetApplicantKey(applicant.name)
    for index = #applicants, 1, -1 do
        if applicants[index] == applicant or GetApplicantKey(applicants[index].name) == targetKey then
            table.remove(applicants, index)
            return
        end
    end
end

local function SetDeclineLockout(listing, name)
    if not listing then return end
    local listKey = tostring(listing.id)
    runtime.declineLockouts[listKey] = runtime.declineLockouts[listKey] or {}
    runtime.declineLockouts[listKey][GetApplicantKey(name)] = time()
end

local function HasDeclineLockout(listing, name)
    if not listing then return false end
    local listLockouts = runtime.declineLockouts[tostring(listing.id)]
    if not listLockouts then return false end
    local applicantKey = GetApplicantKey(name)
    local declinedAt = listLockouts[applicantKey]
    if not declinedAt then return false end
    if time() - declinedAt < APPLICATION_COOLDOWN_SECONDS then return true end
    listLockouts[applicantKey] = nil
    return false
end

local function SavePosition()
    if not mainFrame or not ZenActivityFinderDB then return end
    local point, _, relativePoint, x, y = mainFrame:GetPoint(1)
    ZenActivityFinderDB.position = { point = point, relativePoint = relativePoint, x = x, y = y }
end

local function UpdateCategoryButtons()
    for key, button in pairs(categoryButtons) do
        if key == state.category then
            button.active:Show()
            button.accent:Show()
            button.label:SetTextColor(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
        else
            button.active:Hide()
            button.accent:Hide()
            button.label:SetTextColor(COLORS.muted[1], COLORS.muted[2], COLORS.muted[3])
        end
    end
end

local function UpdateDetails(listing)
    if not listing then
        details.content:Hide()
        details.empty:Show()
        return
    end

    details.empty:Hide()
    details.content:Show()
    details.category:SetText(GetCategoryName(listing.category):upper() .. "  |  " .. GetGameModeName(listing.gameMode):upper())
    details.title:SetText(listing.title or "Untitled activity")
    if listing.category == "ORB" then
        details.activity:SetText(GetOrbActivityText(listing) .. "  |  Need " .. GetOrbNeedLabel(listing.orbNeed))
    else
        details.activity:SetText(listing.activity ~= "" and listing.activity or GetCategoryName(listing.category))
    end
    if listing.questLink and listing.questLink ~= "" then details.quest:Show() else details.quest:Hide() end
    details.owner:SetText(listing.owner or "Unknown")
    details.groupSize:SetText(tostring(listing.currentSize or 1) .. " / " .. tostring(listing.groupSize or 5))
    details.status:SetText(GetStatusLabel(listing.status))
    if (listing.status or "OPEN") == "OPEN" then
        details.status:SetTextColor(COLORS.green[1], COLORS.green[2], COLORS.green[3])
    else
        details.status:SetTextColor(COLORS.muted[1], COLORS.muted[2], COLORS.muted[3])
    end
    details.startTime:SetText((listing.startTime and listing.startTime ~= "") and listing.startTime or "Now")
    details.notes:SetText((listing.notes and listing.notes ~= "") and listing.notes or "No additional details provided.")
    local interestCount = GetInterestCount(listing)
    details.interestSummary:SetText(interestCount > 0 and (interestCount .. " interested") or "")

    if IsOwnedListing(listing) then
        details.edit:Show()
        details.statusButton:Show()
        details.statusButton.label:SetText((listing.status == "CLOSED" or listing.status == "EXPIRED") and "Reopen Listing" or "Close Listing")
        details.applicants:Show()
        local applicantList = runtime.applicants[tostring(listing.id)] or {}
        details.applicants.label:SetText("Applicants (" .. #applicantList .. ")")
        details.remove:Show()
        details.request:Hide()
        details.interested:Hide()
        details.share:Hide()
        details.whisper:Hide()
        details.ownerShare:Show()
        details.ownerNotice:Hide()
    else
        details.edit:Hide()
        details.statusButton:Hide()
        details.applicants:Hide()
        details.remove:Hide()
        details.request:Show()
        details.interested:Show()
        details.share:Show()
        details.whisper:Show()
        details.ownerShare:Hide()
        details.interested.label:SetText(IsListingInterested(listing) and "Interested X" or "Interested")
        local requestedBefore = runtime.requested[listing.id] ~= nil
        local cooldown = GetApplicationCooldownRemaining(listing.id)
        if cooldown > 0 then
            details.request.label:SetText("Re-apply in " .. cooldown .. "s")
        else
            details.request.label:SetText(requestedBefore and "Re-apply" or "Request Invite")
        end
        local roleEligible = CanLocalPlayerFillOrbNeed(listing)
        if listing.category == "ORB" and not roleEligible then
            details.request.label:SetText("Role not currently needed")
        end
        details.request:SetButtonEnabled(cooldown <= 0
            and roleEligible
            and (listing.status or "OPEN") == "OPEN"
            and (listing.currentSize or 1) < (listing.groupSize or 5))
        details.whisper:Show()
        details.ownerNotice:Hide()
    end
end

UpdateListings = function()
    if not mainFrame then return end

    local filtered = GetFilteredListings()
    local totalPages = math.max(1, math.ceil(#filtered / state.pageSize))
    state.page = math.max(1, math.min(state.page, totalPages))
    local startIndex = ((state.page - 1) * state.pageSize) + 1

    listSummary:SetText(#filtered .. (#filtered == 1 and " listing" or " listings"))
    if #filtered == 0 then
        emptyState:Show()
        if emptyCreateButton then emptyCreateButton:Show() end
    else
        emptyState:Hide()
        if emptyCreateButton then emptyCreateButton:Hide() end
    end

    for rowIndex, row in ipairs(listingRows) do
        local listing = filtered[startIndex + rowIndex - 1]
        if listing then
            row.listingID = listing.id
            row.title:SetText(listing.title or "Untitled activity")
            if listing.category == "ORB" then
                row.meta:SetText("Orb  |  Need " .. GetOrbNeedLabel(listing.orbNeed) .. "  |  " .. (listing.owner or "Unknown"))
            else
                row.meta:SetText(GetCategoryShortName(listing.category) .. "  |  " .. GetGameModeName(listing.gameMode) .. "  |  " .. (listing.owner or "Unknown"))
            end
            row.age:SetText(GetAgeText(listing))
            row.count:SetText(tostring(listing.currentSize or 1) .. "/" .. tostring(listing.groupSize or 5))
            row.status:SetText(GetStatusLabel(listing.status))
            if (listing.status or "OPEN") == "OPEN" then
                row.status:SetTextColor(COLORS.green[1], COLORS.green[2], COLORS.green[3])
            else
                row.status:SetTextColor(COLORS.muted[1], COLORS.muted[2], COLORS.muted[3])
            end
            if listing.id == state.selectedID then
                row.selected:Show()
                row._zenBorderAccent = true
                row._zenHover = true
            else
                row.selected:Hide()
                row._zenBorderAccent = false
                row._zenHover = false
            end
            UI:RefreshSurface(row)
            row:Show()
        else
            row.listingID = nil
            row:Hide()
        end
    end

    local selectedInFilter = false
    for _, listing in ipairs(filtered) do
        if listing.id == state.selectedID then selectedInFilter = true break end
    end
    if not selectedInFilter then
        state.selectedID = filtered[1] and filtered[1].id or nil
        if state.selectedID then
            return UpdateListings()
        end
    end

    previousButton:SetButtonEnabled(state.page > 1)
    nextButton:SetButtonEnabled(state.page < totalPages)
    pageText:SetText("Page " .. state.page .. " / " .. totalPages)
    UpdateDetails(FindListingByID(state.selectedID))
    UpdateCategoryButtons()
end

local function SelectCategory(key)
    state.category = key
    state.page = 1
    state.selectedID = nil
    UpdateListings()
end

local function RemoveSelectedListing()
    if not ZenActivityFinderDB or not state.selectedID then return end
    for index, listing in ipairs(ZenActivityFinderDB.listings) do
        if tostring(listing.id) == tostring(state.selectedID) then
            if not IsOwnedListing(listing) then return end
            local removedID = listing.id
            table.remove(ZenActivityFinderDB.listings, index)
            runtime.applicants[tostring(removedID)] = nil
            runtime.declineLockouts[tostring(removedID)] = nil
            runtime.inviteReservations[tostring(removedID)] = nil
            state.selectedID = nil
            state.page = 1
            UpdateListings()
            if BroadcastRemoval then BroadcastRemoval(removedID) end
            Print("Listing removed.")
            return
        end
    end
end

local function BuildCategoryNavigation(parent)
    local heading = CreateText(parent, "BROWSE", 10, COLORS.muted)
    heading:SetPoint("TOPLEFT", 16, -18)

    for index, category in ipairs(categories) do
        local button = CreateFrame("Button", nil, parent)
        button:SetPoint("TOPLEFT", 8, -38 - ((index - 1) * 40))
        button:SetWidth(136)
        button:SetHeight(34)

        button.active = button:CreateTexture(nil, "BACKGROUND")
        button.active:SetPoint("TOPLEFT", 0, 0)
        button.active:SetPoint("BOTTOMRIGHT", 0, 0)
        SetColor(button.active, { 0.12, 0.115, 0.09, 1 })

        button.accent = button:CreateTexture(nil, "ARTWORK")
        button.accent:SetPoint("TOPLEFT", 0, 0)
        button.accent:SetPoint("BOTTOMLEFT", 0, 0)
        button.accent:SetWidth(3)
        SetColor(button.accent, COLORS.gold)
        button.accent:Hide()

        button.label = CreateText(button, category.name, 12, COLORS.muted)
        button.label:SetPoint("LEFT", 12, 0)

        button:SetScript("OnClick", function() SelectCategory(category.key) end)
        button:SetScript("OnEnter", function(self)
            if category.key ~= state.category then
                self.label:SetTextColor(COLORS.text[1], COLORS.text[2], COLORS.text[3])
            end
        end)
        button:SetScript("OnLeave", function(self)
            if category.key ~= state.category then
                self.label:SetTextColor(COLORS.muted[1], COLORS.muted[2], COLORS.muted[3])
            end
        end)
        categoryButtons[category.key] = button
    end
end

local function BuildListingRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetWidth(375)
    row:SetHeight(58)
    row:SetPoint("TOPLEFT", 0, -((index - 1) * 64))
    AddBackground(row, COLORS.panel, { 0.15, 0.17, 0.20, 1 })

    row.selected = row:CreateTexture(nil, "ARTWORK")
    row.selected:SetPoint("TOPLEFT", 0, 0)
    row.selected:SetPoint("BOTTOMLEFT", 0, 0)
    row.selected:SetWidth(3)
    SetColor(row.selected, COLORS.gold)

    row.title = CreateText(row, "", 13, COLORS.text)
    row.title:SetPoint("TOPLEFT", 12, -8)
    row.title:SetPoint("TOPRIGHT", -105, -8)
    row.title:SetHeight(16)
    row.title:SetJustifyH("LEFT")

    row.meta = CreateText(row, "", 10, COLORS.muted)
    row.meta:SetPoint("BOTTOMLEFT", 12, 8)
    row.meta:SetWidth(260)
    row.meta:SetHeight(14)
    row.meta:SetJustifyH("LEFT")
    row.meta:SetWordWrap(false)

    row.age = CreateText(row, "", 9, COLORS.muted, "RIGHT")
    row.age:SetPoint("BOTTOMRIGHT", -10, 7)

    row.status = CreateText(row, "", 9, COLORS.green, "RIGHT")
    row.status:SetPoint("TOPRIGHT", -10, -8)

    row.count = CreateText(row, "", 11, COLORS.text, "RIGHT")
    row.count:SetPoint("RIGHT", -10, -1)

    row:SetScript("OnClick", function(self)
        state.selectedID = self.listingID
        UpdateListings()
    end)
    row:SetScript("OnEnter", function(self)
        self._zenHover = true
        UI:RefreshSurface(self)
    end)
    row:SetScript("OnLeave", function(self)
        self._zenHover = self.listingID == state.selectedID
        UI:RefreshSurface(self)
    end)
    return row
end

local function BuildDetailsPanel(parent)
    local heading = CreateText(parent, "DETAILS", 10, COLORS.muted)
    heading:SetPoint("TOPLEFT", 16, -18)

    details.empty = CreateText(parent, "Select a listing to see its details.", 12, COLORS.muted, "CENTER")
    details.empty:SetPoint("CENTER", 0, 20)
    details.empty:SetWidth(220)
    details.empty:SetHeight(50)

    details.content = CreateFrame("Frame", nil, parent)
    details.content:SetPoint("TOPLEFT", 16, -42)
    details.content:SetPoint("BOTTOMRIGHT", -16, 16)

    details.category = CreateText(details.content, "", 10, COLORS.gold)
    details.category:SetPoint("TOPLEFT", 0, 0)

    details.title = CreateText(details.content, "", 17, COLORS.text)
    details.title:SetPoint("TOPLEFT", 0, -22)
    details.title:SetWidth(232)
    details.title:SetHeight(42)
    details.title:SetJustifyV("TOP")
    details.title:SetWordWrap(true)

    local activityLabel = CreateText(details.content, "ACTIVITY", 9, COLORS.muted)
    activityLabel:SetPoint("TOPLEFT", 0, -76)
    details.activity = CreateText(details.content, "", 12, COLORS.text)
    details.activity:SetPoint("TOPLEFT", 0, -91)

    details.quest = CreateButton(details.content, "Quest", 54, 22)
    details.quest:SetPoint("TOPRIGHT", 0, -83)
    details.quest:SetScript("OnEnter", function(self)
        local listing = FindListingByID(state.selectedID)
        if listing and listing.questLink and listing.questLink ~= "" then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetHyperlink(listing.questLink)
            GameTooltip:Show()
        end
    end)
    details.quest:SetScript("OnLeave", function() GameTooltip:Hide() end)
    details.quest:SetScript("OnClick", function()
        local listing = FindListingByID(state.selectedID)
        if not listing or not listing.questLink or not SetItemRef then return end
        local linkType = listing.questLink:match("|H(.-)|h")
        if linkType then SetItemRef(linkType, listing.questLink, "LeftButton") end
    end)

    local ownerLabel = CreateText(details.content, "ORGANIZER", 9, COLORS.muted)
    ownerLabel:SetPoint("TOPLEFT", 0, -124)
    details.owner = CreateText(details.content, "", 12, COLORS.text)
    details.owner:SetPoint("TOPLEFT", 0, -139)

    local sizeLabel = CreateText(details.content, "GROUP", 9, COLORS.muted)
    sizeLabel:SetPoint("TOPLEFT", 130, -124)
    details.groupSize = CreateText(details.content, "", 12, COLORS.text)
    details.groupSize:SetPoint("TOPLEFT", 130, -139)

    local statusLabel = CreateText(details.content, "STATUS", 9, COLORS.muted)
    statusLabel:SetPoint("TOPLEFT", 0, -170)
    details.status = CreateText(details.content, "", 11, COLORS.green)
    details.status:SetPoint("TOPLEFT", 0, -185)

    local startLabel = CreateText(details.content, "START", 9, COLORS.muted)
    startLabel:SetPoint("TOPLEFT", 130, -170)
    details.startTime = CreateText(details.content, "", 11, COLORS.text)
    details.startTime:SetPoint("TOPLEFT", 130, -185)

    local notesLabel = CreateText(details.content, "NOTES", 9, COLORS.muted)
    notesLabel:SetPoint("TOPLEFT", 0, -214)
    details.notes = CreateText(details.content, "", 11, { 0.76, 0.78, 0.82, 1 })
    details.notes:SetPoint("TOPLEFT", 0, -230)
    details.notes:SetWidth(232)
    details.notes:SetHeight(106)
    details.notes:SetJustifyV("TOP")
    details.notes:SetWordWrap(true)

    details.interestSummary = CreateText(details.content, "", 9, COLORS.gold, "CENTER")
    details.interestSummary:SetPoint("BOTTOM", 0, 94)
    details.interestSummary:SetWidth(232)

    details.ownerNotice = CreateText(details.content, "Only the organizer can edit this listing.", 9, COLORS.muted, "CENTER")
    details.ownerNotice:SetPoint("BOTTOM", 0, 14)
    details.ownerNotice:SetWidth(230)

    details.edit = CreateButton(details.content, "Edit", 112, 28)
    details.edit:SetPoint("BOTTOMLEFT", 0, 31)
    details.edit:SetFrameLevel(details.content:GetFrameLevel() + 3)
    details.edit.label:SetTextColor(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
    details.edit:SetScript("OnClick", function()
        local listing = FindOwnedListingByID(state.selectedID)
        if not IsOwnedListing(listing) then return end
        createFrame.editingID = listing.id
        createFrame:Show()
    end)

    details.statusButton = CreateButton(details.content, "Close Listing", 112, 28)
    details.statusButton:SetPoint("BOTTOMRIGHT", 0, 31)
    details.statusButton:SetFrameLevel(details.content:GetFrameLevel() + 3)
    details.statusButton:SetScript("OnClick", function()
        local listing = FindOwnedListingByID(state.selectedID)
        if not IsOwnedListing(listing) then return end
        if listing.status == "CLOSED" or listing.status == "EXPIRED" then
            local activeListing = FindActiveOwnedListing(listing.id)
            if activeListing then
                Print("You already have an active listing. Close or remove it before reopening another.")
                return
            end
            if GetCurrentGroupSize() > 1 and not IsPlayerLeadingCurrentGroup() then
                Print("You cannot reopen a listing while grouped under another leader.")
                return
            end
            listing.status = "OPEN"
            listing.closedAt = nil
            listing.createdAt = time()
            listing.updatedAt = time()
            listing.expiresAt = time() + (NormalizeExpiryMinutes(ZenActivityFinderDB.settings.expiryMinutes) * 60)
        else
            listing.status = "CLOSED"
            listing.closedAt = time()
        end
        UpdateListings()
        if BroadcastListing then BroadcastListing(listing) end
        Print(listing.status == "OPEN" and "Listing reopened." or "Listing closed.")
    end)

    details.applicants = CreateButton(details.content, "Applicants (0)", 112, 28)
    details.applicants:SetPoint("BOTTOMLEFT", 0, 0)
    details.applicants:SetFrameLevel(details.content:GetFrameLevel() + 3)
    details.applicants:SetScript("OnClick", function()
        local listing = FindOwnedListingByID(state.selectedID)
        if IsOwnedListing(listing) and OpenApplicantsFrame then OpenApplicantsFrame(listing) end
    end)

    details.remove = CreateButton(details.content, "Remove", 112, 28)
    details.remove:SetPoint("BOTTOMRIGHT", 0, 0)
    details.remove:SetFrameLevel(details.content:GetFrameLevel() + 3)
    details.remove.label:SetTextColor(COLORS.red[1], COLORS.red[2], COLORS.red[3])
    details.remove:SetScript("OnClick", RemoveSelectedListing)

    details.request = CreateButton(details.content, "Request Invite", 232, 30)
    details.request:SetPoint("BOTTOM", 0, 31)
    details.request.label:SetTextColor(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
    details.request:SetScript("OnClick", function()
        local listing = FindListingByID(state.selectedID)
        if listing and not IsOwnedListing(listing) and SendJoinRequest then SendJoinRequest(listing) end
    end)

    details.interested = CreateButton(details.content, "Interested", 74, 26)
    details.interested:SetPoint("BOTTOMLEFT", 0, 0)
    details.interested:SetScript("OnClick", function()
        local listing = FindListingByID(state.selectedID)
        if listing then ToggleListingInterest(listing) end
    end)

    details.share = CreateButton(details.content, "Share", 74, 26)
    details.share:SetPoint("BOTTOM", 0, 0)
    details.share:SetScript("OnClick", function()
        local listing = FindListingByID(state.selectedID)
        if listing then OpenShareMenu(listing) end
    end)

    details.whisper = CreateButton(details.content, "Whisper", 74, 26)
    details.whisper:SetPoint("BOTTOMRIGHT", 0, 0)
    details.whisper:SetScript("OnClick", function()
        local listing = FindListingByID(state.selectedID)
        if listing and ChatFrame_OpenChat then ChatFrame_OpenChat("/w " .. (listing.owner or "") .. " ") end
    end)

    details.ownerShare = CreateButton(details.content, "Share", 88, 24)
    details.ownerShare:SetPoint("BOTTOM", 0, 66)
    details.ownerShare:SetScript("OnClick", function()
        local listing = FindListingByID(state.selectedID)
        if listing then OpenShareMenu(listing) end
    end)

end

local function CreateCategoryDropdown(parent)
    local values = { "ORB", "RAID", "QUEST", "WORLD", "CUSTOM" }
    local dropdown = CreateButton(parent, "Raids", 184, 30)
    dropdown.value = "RAID"

    dropdown.arrow = CreateText(dropdown, "v", 11, COLORS.gold, "CENTER")
    dropdown.arrow:SetPoint("RIGHT", -10, 0)
    dropdown.arrow:SetWidth(14)

    dropdown.menu = CreateFrame("Frame", nil, parent)
    dropdown.menu:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 0, -2)
    dropdown.menu:SetWidth(184)
    dropdown.menu:SetHeight((#values * 28) + 4)
    dropdown.menu:SetFrameLevel(parent:GetFrameLevel() + 20)
    AddBackground(dropdown.menu, COLORS.panel, COLORS.gold)
    dropdown.menu:Hide()

    for index, key in ipairs(values) do
        local option = CreateFrame("Button", nil, dropdown.menu)
        option:SetPoint("TOPLEFT", 2, -2 - ((index - 1) * 28))
        option:SetWidth(180)
        option:SetHeight(28)
        option.value = key

        option.highlight = option:CreateTexture(nil, "BACKGROUND")
        option.highlight:SetAllPoints()
        SetColor(option.highlight, { 0.14, 0.16, 0.20, 1 })
        option.highlight:Hide()

        option.label = CreateText(option, GetCategoryName(key), 11, COLORS.text)
        option.label:SetPoint("LEFT", 10, 0)

        option:SetScript("OnEnter", function(self) self.highlight:Show() end)
        option:SetScript("OnLeave", function(self) self.highlight:Hide() end)
        option:SetScript("OnClick", function(self)
            dropdown.value = self.value
            dropdown.label:SetText(GetCategoryName(self.value))
            dropdown.menu:Hide()
            if self.value == "ORB" then
                ApplyOrbPresetToCreateFrame(false)
            elseif createFrame and not createFrame.editingID then
                createFrame.orbMode = nil
                createFrame.orbEvent = nil
                createFrame.subtitle:SetText("Type a title, or shift-click a quest in your quest log.")
            end
        end)
    end

    dropdown:SetScript("OnClick", function(self)
        if createFrame and createFrame.modeButton then createFrame.modeButton.menu:Hide() end
        if self.menu:IsShown() then self.menu:Hide() else self.menu:Show() end
    end)
    return dropdown
end

local function CreateGameModeDropdown(parent)
    local dropdown = CreateButton(parent, "Detecting...", 184, 30)
    dropdown.value = GetDetectedGameMode()
    dropdown.menu = CreateFrame("Frame", nil, parent)
    dropdown.menu:Hide()
    dropdown:SetButtonEnabled(false)
    dropdown.label:SetTextColor(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
    return dropdown
end

local function EnableQuestLogClickCapture()
    if questLogHooked or type(QuestLogTitleButton_OnClick) ~= "function" then return end

    local originalQuestLogTitleButton_OnClick = QuestLogTitleButton_OnClick
    QuestLogTitleButton_OnClick = function(self, button)
        if createFrame and createFrame:IsShown()
            and IsShiftKeyDown()
            and self
            and not self.isHeader
            and (button == "LeftButton" or button == nil) then
            local questIndex = self:GetID()
            local questTitle = GetQuestLogTitle(questIndex)
            if questTitle and questTitle ~= "" then
                createFrame.titleInput:SetText(Trim(questTitle))
                createFrame.titleInput:HighlightText()
                createFrame.questLink = GetQuestLink and GetQuestLink(questIndex) or nil
                createFrame.error:SetText("")
                if QuestLog_SetSelection then QuestLog_SetSelection(questIndex) end
                return
            end
        end
        return originalQuestLogTitleButton_OnClick(self, button)
    end
    questLogHooked = true
end

local function EnableQuestLogVisibilityLink()
    if questLogVisibilityHooked or not QuestLogFrame or not QuestLogFrame.HookScript then return end
    QuestLogFrame:HookScript("OnShow", function()
        if ZenActivityFinderDB
            and ZenActivityFinderDB.settings.linkQuestLog
            and mainFrame
            and not mainFrame:IsShown()
            and (not createFrame or not createFrame:IsShown())
            and ShowMainFrame then
            ShowMainFrame(false)
        end
    end)
    QuestLogFrame:HookScript("OnHide", function()
        if ZenActivityFinderDB
            and ZenActivityFinderDB.settings.linkQuestLog
            and mainFrame
            and mainFrame:IsShown() then
            mainFrame:Hide()
        end
    end)
    questLogVisibilityHooked = true
end

local function ShowLinkedQuestLog()
    EnableQuestLogVisibilityLink()
    if QuestLogFrame and not QuestLogFrame:IsShown() then
        if ShowUIPanel then ShowUIPanel(QuestLogFrame) else QuestLogFrame:Show() end
    elseif not QuestLogFrame and ToggleQuestLog then
        ToggleQuestLog()
        EnableQuestLogVisibilityLink()
    end
end

local function HideLinkedQuestLog()
    if QuestLogFrame and QuestLogFrame:IsShown() then
        if HideUIPanel then HideUIPanel(QuestLogFrame) else QuestLogFrame:Hide() end
    end
end

local function BuildCreateFrame()
    createFrame = CreateFrame("Frame", "ZenActivityFinderCreateFrame", UIParent)
    createFrame:SetWidth(430)
    createFrame:SetHeight(490)
    createFrame:SetPoint("CENTER")
    createFrame:SetFrameStrata("DIALOG")
    createFrame:EnableMouse(true)
    AddBackground(createFrame, COLORS.background, COLORS.gold)
    createFrame:Hide()
    table.insert(UISpecialFrames, "ZenActivityFinderCreateFrame")

    createFrame.heading = CreateText(createFrame, "Create a Listing", 18, COLORS.text)
    createFrame.heading:SetPoint("TOPLEFT", 20, -18)
    createFrame.subtitle = CreateText(createFrame, "Type a title, or shift-click a quest in your quest log.", 10, COLORS.muted)
    createFrame.subtitle:SetPoint("TOPLEFT", 20, -43)

    local close = CreateButton(createFrame, "X", 28, 28)
    close:SetPoint("TOPRIGHT", -12, -12)
    close:SetScript("OnClick", function() createFrame:Hide() end)

    local categoryLabel = CreateText(createFrame, "CATEGORY", 9, COLORS.muted)
    categoryLabel:SetPoint("TOPLEFT", 20, -79)

    local categoryButton = CreateCategoryDropdown(createFrame)
    categoryButton:SetPoint("TOPLEFT", 20, -94)
    createFrame.categoryButton = categoryButton

    local sizeLabel = CreateText(createFrame, "TARGET GROUP SIZE", 9, COLORS.muted)
    sizeLabel:SetPoint("TOPLEFT", 226, -79)
    local sizeHolder, sizeInput = CreateInput(createFrame, 184, 30, 2)
    sizeHolder:SetPoint("TOPLEFT", 226, -94)
    sizeInput:SetNumeric(true)
    sizeInput:SetText("10")
    createFrame.sizeInput = sizeInput

    local titleLabel = CreateText(createFrame, "LISTING TITLE", 9, COLORS.muted)
    titleLabel:SetPoint("TOPLEFT", 20, -139)
    local titleHolder, titleInput = CreateInput(createFrame, 390, 30, 60)
    titleHolder:SetPoint("TOPLEFT", 20, -154)
    createFrame.titleInput = titleInput

    local activityLabel = CreateText(createFrame, "ACTIVITY OR LOCATION", 9, COLORS.muted)
    activityLabel:SetPoint("TOPLEFT", 20, -199)
    local activityHolder, activityInput = CreateInput(createFrame, 390, 30, 60)
    activityHolder:SetPoint("TOPLEFT", 20, -214)
    createFrame.activityInput = activityInput

    local startLabel = CreateText(createFrame, "START TIME", 9, COLORS.muted)
    startLabel:SetPoint("TOPLEFT", 20, -259)
    local startHolder, startInput = CreateInput(createFrame, 184, 30, 30)
    startHolder:SetPoint("TOPLEFT", 20, -274)
    createFrame.startInput = startInput

    local modeLabel = CreateText(createFrame, "GAME MODE", 9, COLORS.muted)
    modeLabel:SetPoint("TOPLEFT", 226, -259)
    local modeButton = CreateGameModeDropdown(createFrame)
    modeButton:SetPoint("TOPLEFT", 226, -274)
    createFrame.modeButton = modeButton

    local notesLabel = CreateText(createFrame, "NOTES", 9, COLORS.muted)
    notesLabel:SetPoint("TOPLEFT", 20, -319)
    local notesHolder, notesInput = CreateInput(createFrame, 390, 80, 180)
    notesHolder:SetPoint("TOPLEFT", 20, -334)
    notesInput:SetMultiLine(true)
    notesInput:SetJustifyV("TOP")
    createFrame.notesInput = notesInput

    createFrame.error = CreateText(createFrame, "", 10, COLORS.red)
    createFrame.error:SetPoint("BOTTOMLEFT", 20, 57)
    createFrame.error:SetWidth(250)

    local cancel = CreateButton(createFrame, "Cancel", 90, 30)
    cancel:SetPoint("BOTTOMRIGHT", -142, 18)
    cancel:SetScript("OnClick", function() createFrame:Hide() end)

    createFrame.submitButton = CreateButton(createFrame, "Create Listing", 122, 30)
    createFrame.submitButton:SetPoint("BOTTOMRIGHT", -20, 18)
    createFrame.submitButton.label:SetTextColor(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
    createFrame.submitButton:SetScript("OnClick", function()
        local listingTitle = Trim(createFrame.titleInput:GetText())
        local activity = Trim(createFrame.activityInput:GetText())
        local groupSize = tonumber(createFrame.sizeInput:GetText()) or 0
        local isOrb = createFrame.categoryButton.value == "ORB"
        if isOrb then
            groupSize = 5
            createFrame.sizeInput:SetText("5")
            if not createFrame.orbMode then
                local mode, eventName = GetOrbPreset()
                createFrame.orbMode = mode
                createFrame.orbEvent = eventName
            end
        end
        if listingTitle == "" then
            createFrame.error:SetText("Enter a title for your listing.")
            return
        elseif groupSize < 2 or groupSize > 40 then
            createFrame.error:SetText("Group size must be between 2 and 40.")
            return
        elseif not runtime.currentGameMode then
            createFrame.error:SetText("Detecting your current game mode...")
            QueueDirectAction(OPS.PRESENCE)
            return
        end

        local listing = FindListingByID(createFrame.editingID)
        local wasEditing = listing ~= nil
        if listing and not IsOwnedListing(listing) then return end
        if not listing and FindActiveOwnedListing(nil) then
            createFrame.error:SetText("You already have an active listing. Close or remove it first.")
            return
        elseif GetCurrentGroupSize() > 1 and not IsPlayerLeadingCurrentGroup() then
            createFrame.error:SetText("You cannot advertise while grouped under another leader.")
            return
        end

        if listing then
            listing.category = createFrame.categoryButton.value
            listing.title = listingTitle
            listing.activity = activity
            listing.groupSize = groupSize
            listing.gameMode = GetDetectedGameMode()
            listing.startTime = Trim(createFrame.startInput:GetText())
            listing.notes = Trim(createFrame.notesInput:GetText())
            listing.questLink = createFrame.questLink or listing.questLink
            if isOrb then
                listing.orbMode = createFrame.orbMode or "TOC"
                listing.orbEvent = createFrame.orbEvent or ""
                listing.orbNeed = GetOrbNeedCode()
            else
                listing.orbMode, listing.orbEvent, listing.orbNeed = nil, nil, nil
            end
            listing.expiresAt = time() + (NormalizeExpiryMinutes(ZenActivityFinderDB.settings.expiryMinutes) * 60)
            listing.updatedAt = time()
        else
            local id = ZenActivityFinderDB.nextID
            ZenActivityFinderDB.nextID = id + 1
            listing = {
                id = id,
                category = createFrame.categoryButton.value,
                title = listingTitle,
                activity = activity,
                owner = UnitName("player") or "You",
                ownerGUID = UnitGUID and UnitGUID("player"),
                isOwner = true,
                groupSize = groupSize,
                currentSize = GetCurrentGroupSize(),
                gameMode = GetDetectedGameMode(),
                startTime = Trim(createFrame.startInput:GetText()),
                notes = Trim(createFrame.notesInput:GetText()),
                questLink = createFrame.questLink,
                orbMode = isOrb and (createFrame.orbMode or "TOC") or nil,
                orbEvent = isOrb and (createFrame.orbEvent or "") or nil,
                orbNeed = isOrb and GetOrbNeedCode() or nil,
                status = "OPEN",
                autoClose = ZenActivityFinderDB.settings.autoClose,
                autoInvite = ZenActivityFinderDB.settings.autoInvite,
                expiresAt = time() + (NormalizeExpiryMinutes(ZenActivityFinderDB.settings.expiryMinutes) * 60),
                createdAt = time(),
            }
            table.insert(ZenActivityFinderDB.listings, 1, listing)
        end

        state.category = "ALL"
        state.search = ""
        state.page = 1
        searchBox:SetText("")
        state.selectedID = listing.id
        createFrame:Hide()
        Print((wasEditing and "Updated listing: " or "Created listing: ") .. listingTitle)
        if BroadcastListing then BroadcastListing(listing) end
        UpdateListings()
    end)

    createFrame:SetScript("OnShow", function(self)
        if mainFrame and not mainFrame:IsShown() and ShowMainFrame then ShowMainFrame(true) end
        HideOtherSecondaryWindows(self)
        EnableQuestLogClickCapture()
        self.categoryButton.menu:Hide()
        self.modeButton.menu:Hide()
        local listing = FindListingByID(self.editingID)
        if listing and IsOwnedListing(listing) then
            self.heading:SetText("Edit Listing")
            self.subtitle:SetText("Update your listing, or shift-click a quest to replace its title.")
            self.submitButton.label:SetText("Save Changes")
            self.categoryButton.value = listing.category or "CUSTOM"
            self.categoryButton.label:SetText(GetCategoryName(self.categoryButton.value))
            self.sizeInput:SetText(tostring(listing.groupSize or 5))
            self.modeButton.value = GetDetectedGameMode()
            self.modeButton.label:SetText(runtime.currentGameMode
                and (GetGameModeName(self.modeButton.value) .. " (Detected)") or "Detecting...")
            self.titleInput:SetText(listing.title or "")
            self.activityInput:SetText(listing.activity or "")
            self.startInput:SetText(listing.startTime or "Now")
            self.notesInput:SetText(listing.notes or "")
            self.questLink = listing.questLink
            self.orbMode = listing.orbMode
            self.orbEvent = listing.orbEvent
            if listing.category == "ORB" then
                self.sizeInput:SetText("5")
                self.subtitle:SetText("Orb Farms are 5-player groups. Role need updates automatically from the party.")
            end
        else
            self.editingID = nil
            self.heading:SetText("Create a Listing")
            self.subtitle:SetText("Type a title, or shift-click a quest in your quest log.")
            self.submitButton.label:SetText("Create Listing")
            self.categoryButton.value = "RAID"
            self.categoryButton.label:SetText("Raids")
            self.sizeInput:SetText("10")
            self.modeButton.value = GetDetectedGameMode()
            self.modeButton.label:SetText(runtime.currentGameMode
                and (GetGameModeName(self.modeButton.value) .. " (Detected)") or "Detecting...")
            self.titleInput:SetText("")
            self.activityInput:SetText("")
            self.startInput:SetText("Now")
            self.notesInput:SetText("")
            self.questLink = nil
            self.orbMode = nil
            self.orbEvent = nil
            if self.prefillOrb then ApplyOrbPresetToCreateFrame(true) end
        end
        self.prefillOrb = nil
        self.error:SetText("")
        if not runtime.currentGameMode then QueueDirectAction(OPS.PRESENCE) end
        self.titleInput:SetFocus()
        self.titleInput:HighlightText()
    end)
    createFrame:SetScript("OnHide", function(self)
        self.categoryButton.menu:Hide()
        self.modeButton.menu:Hide()
        self.editingID = nil
    end)
end

local function BuildMainFrame()
    mainFrame = CreateFrame("Frame", "ZenActivityFinderFrame", UIParent)
    mainFrame:SetWidth(860)
    mainFrame:SetHeight(540)
    mainFrame:SetPoint("CENTER")
    mainFrame:SetFrameStrata("HIGH")
    mainFrame:SetMovable(true)
    mainFrame:SetClampedToScreen(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    mainFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition() end)
    AddBackground(mainFrame, COLORS.background, COLORS.border)
    mainFrame:Hide()
    table.insert(UISpecialFrames, "ZenActivityFinderFrame")
    mainFrame:SetScript("OnHide", function()
        HideOtherSecondaryWindows(nil)
        if ZenActivityFinderDB
            and ZenActivityFinderDB.settings.linkQuestLog then
            HideLinkedQuestLog()
        end
    end)

    local header = CreateFrame("Frame", nil, mainFrame)
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(60)
    local headerTexture = header:CreateTexture(nil, "BACKGROUND")
    headerTexture:SetAllPoints()
    SetColor(headerTexture, { 0.055, 0.062, 0.078, 1 })

    local title = CreateText(header, "ZenActivityFinder", 19, COLORS.text)
    title:SetPoint("TOPLEFT", 18, -13)
    local subtitle = CreateText(header, "Community group listings", 10, COLORS.muted)
    subtitle:SetPoint("TOPLEFT", 18, -38)

    local localBadge = CreateFrame("Frame", nil, header)
    localBadge:SetWidth(100)
    localBadge:SetHeight(20)
    localBadge:SetPoint("LEFT", title, "RIGHT", 12, 0)
    AddBackground(localBadge, { 0.11, 0.10, 0.065, 1 }, { 0.35, 0.29, 0.15, 1 })
    networkStatusText = CreateText(localBadge, "CONNECTING", 8, COLORS.gold, "CENTER")
    networkStatusText:SetAllPoints()

    refreshButton = CreateButton(header, "Refresh", 84, 28)
    refreshButton:SetPoint("TOPRIGHT", -132, -12)
    refreshButton:SetScript("OnClick", function()
        if RefreshSharedListings then RefreshSharedListings(true) end
    end)

    local settings = CreateButton(header, "Settings", 76, 28)
    settings:SetPoint("TOPRIGHT", -48, -12)
    settings:SetScript("OnClick", function() if OpenSettingsFrame then OpenSettingsFrame() end end)

    local close = CreateButton(header, "X", 28, 28)
    close:SetPoint("TOPRIGHT", -12, -12)
    close:SetScript("OnClick", function() mainFrame:Hide() end)

    local nav = CreateFrame("Frame", nil, mainFrame)
    nav:SetPoint("TOPLEFT", 1, -61)
    nav:SetPoint("BOTTOMLEFT", 1, 1)
    nav:SetWidth(152)
    AddBackground(nav, { 0.045, 0.052, 0.066, 1 }, { 0.10, 0.11, 0.14, 1 })
    BuildCategoryNavigation(nav)

    local orbButton = CreateButton(nav, "+  Orb Farm", 124, 30)
    orbButton:SetPoint("BOTTOM", 0, 56)
    orbButton.label:SetTextColor(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
    orbButton:SetScript("OnClick", function()
        local activeListing = FindActiveOwnedListing(nil)
        if activeListing then
            state.category = "ALL"
            state.search = ""
            state.selectedID = activeListing.id
            state.page = 1
            if searchBox then searchBox:SetText("") end
            UpdateListings()
            Print("You already have an active listing. Edit, close, or remove it before creating another.")
            return
        end
        createFrame.editingID = nil
        createFrame.prefillOrb = true
        createFrame:Show()
    end)

    local createButton = CreateButton(nav, "+  Create Listing", 124, 32)
    createButton:SetPoint("BOTTOM", 0, 18)
    createButton.label:SetTextColor(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
    createButton:SetScript("OnClick", function()
        local activeListing = FindActiveOwnedListing(nil)
        if activeListing then
            state.category = "ALL"
            state.search = ""
            state.selectedID = activeListing.id
            state.page = 1
            searchBox:SetText("")
            UpdateListings()
            Print("You already have an active listing. Edit, close, or remove it before creating another.")
            return
        end
        createFrame.editingID = nil
        createFrame:Show()
    end)

    local listPanel = CreateFrame("Frame", nil, mainFrame)
    listPanel:SetPoint("TOPLEFT", 153, -61)
    listPanel:SetPoint("BOTTOMLEFT", 153, 1)
    listPanel:SetWidth(426)

    local searchLabel = CreateText(listPanel, "SEARCH", 9, COLORS.muted)
    searchLabel:SetPoint("TOPLEFT", 18, -15)
    local searchHolder
    searchHolder, searchBox = CreateInput(listPanel, 375, 30, 80)
    searchHolder:SetPoint("TOPLEFT", 18, -30)
    searchBox:SetScript("OnTextChanged", function(self)
        state.search = self:GetText() or ""
        state.page = 1
        state.selectedID = nil
        UpdateListings()
    end)

    listSummary = CreateText(listPanel, "0 listings", 10, COLORS.muted)
    listSummary:SetPoint("TOPLEFT", 18, -72)

    local rowsParent = CreateFrame("Frame", nil, listPanel)
    rowsParent:SetPoint("TOPLEFT", 18, -90)
    rowsParent:SetWidth(375)
    rowsParent:SetHeight(378)
    for index = 1, state.pageSize do
        listingRows[index] = BuildListingRow(rowsParent, index)
    end

    emptyState = CreateText(rowsParent, "No listings found.\n\nCreate one to get a group started.", 12, COLORS.muted, "CENTER")
    emptyState:SetPoint("CENTER", 0, 20)
    emptyState:SetWidth(300)
    emptyState:SetHeight(80)

    emptyCreateButton = CreateButton(rowsParent, "+  Create Activity", 150, 30)
    emptyCreateButton:SetPoint("CENTER", 0, -42)
    emptyCreateButton.label:SetTextColor(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
    emptyCreateButton:SetScript("OnClick", function()
        local activeListing = FindActiveOwnedListing(nil)
        if activeListing then
            state.selectedID = activeListing.id
            UpdateListings()
            Print("You already have an active listing. Edit, close, or remove it before creating another.")
            return
        end
        createFrame.editingID = nil
        createFrame:Show()
    end)
    emptyCreateButton:Hide()

    previousButton = CreateButton(listPanel, "<", 28, 24)
    previousButton:SetPoint("BOTTOMRIGHT", -92, 10)
    previousButton:SetScript("OnClick", function()
        state.page = math.max(1, state.page - 1)
        state.selectedID = nil
        UpdateListings()
    end)
    pageText = CreateText(listPanel, "Page 1 / 1", 9, COLORS.muted, "CENTER")
    pageText:SetPoint("BOTTOMRIGHT", -35, 10)
    pageText:SetWidth(58)
    pageText:SetHeight(24)
    nextButton = CreateButton(listPanel, ">", 28, 24)
    nextButton:SetPoint("BOTTOMRIGHT", -5, 10)
    nextButton:SetScript("OnClick", function()
        state.page = state.page + 1
        state.selectedID = nil
        UpdateListings()
    end)

    local detailsPanel = CreateFrame("Frame", nil, mainFrame)
    detailsPanel:SetPoint("TOPLEFT", 579, -61)
    detailsPanel:SetPoint("BOTTOMRIGHT", -1, 1)
    AddBackground(detailsPanel, { 0.047, 0.054, 0.068, 1 }, { 0.10, 0.11, 0.14, 1 })
    BuildDetailsPanel(detailsPanel)

    if ZenActivityFinderDB and ZenActivityFinderDB.position then
        local position = ZenActivityFinderDB.position
        mainFrame:ClearAllPoints()
        mainFrame:SetPoint(position.point or "CENTER", UIParent, position.relativePoint or "CENTER", position.x or 0, position.y or 0)
    end
end

local function EscapeField(value)
    local escaped = tostring(value or ""):gsub("[%%|~\r\n]", function(character)
        return string.format("%%%02X", string.byte(character))
    end)
    return escaped
end

local function UnescapeField(value)
    local decoded = tostring(value or ""):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    return decoded
end

local function EncodeFields(values)
    local fields = {}
    for index, value in ipairs(values or {}) do
        fields[index] = EscapeField(value)
    end
    return table.concat(fields, "~")
end

local function DecodeFields(payload)
    local fields = {}
    for field in (tostring(payload or "") .. "~"):gmatch("(.-)~") do
        fields[#fields + 1] = UnescapeField(field)
    end
    return fields
end

local function CompactText(value, maximumLength)
    local text = tostring(value or ""):gsub("[\r\n]", " ")
    return Trim(text):sub(1, maximumLength or 80)
end

local function MarkPeer(sender, gameMode)
    local cleanSender = SanitizePlayerName(sender)
    if cleanSender == "Unknown" or IsLocalPlayerName(cleanSender) then return cleanSender end
    runtime.peers[cleanSender:lower()] = time()
    runtime.lastReceivedAt = time()
    runtime.lastTransportSender = cleanSender
    if gameMode and gameMode ~= "" then
        runtime.peerGameModes[cleanSender:lower()] = NormalizeGameMode(gameMode)
    end
    UpdateConnectionStatus()
    return cleanSender
end

local function SendEbon(op, values)
    if not ebon then return false, "ebonapi_unavailable" end
    local ok, reason = ebon:Say(op, EncodeFields(values))
    if ok then
        runtime.outboundMessagesSent = runtime.outboundMessagesSent + 1
    end
    return ok, reason
end

QueueDirectAction = function(op, values)
    local payload = {}
    for index, value in ipairs(values or {}) do payload[index] = value end
    if op == OPS.PRESENCE then
        payload[1] = payload[1] or ""
        payload[2] = GetDetectedGameMode()
    elseif op == OPS.REFRESH then
        payload[1] = GetDetectedGameMode()
    end
    return SendEbon(op, payload)
end

local function FindOwnedListingByWireID(id)
    return FindOwnedListingByID(id)
end

BroadcastListing = function(listing)
    if not listing or not IsOwnedListing(listing) then return false end
    if listing.category == "ORB" then
        listing.groupSize = 5
        listing.currentSize = GetCurrentGroupSize()
        listing.orbNeed = GetOrbNeedCode()
        if not listing.orbMode then
            local mode, eventName = GetOrbPreset()
            listing.orbMode = mode
            listing.orbEvent = eventName
        end
    end
    if listing.status ~= "OPEN" and listing.status ~= "FULL" then
        if BroadcastRemoval then BroadcastRemoval(listing.id) end
        return false
    end
    if not ZenActivityFinderDB.settings.shareListings then return false end

    listing.currentSize = GetCurrentGroupSize()
    local ok = SendEbon(OPS.LISTING, {
        tostring(listing.id or "0"),
        (listing.category and listing.category ~= "ALL" and categoryByKey[listing.category]) and listing.category or "CUSTOM",
        tostring(listing.title or "Untitled activity"):sub(1, 60),
        tostring(listing.activity or ""):sub(1, 60),
        tostring(listing.currentSize or 1),
        tostring(listing.groupSize or 5),
        listing.status or "OPEN",
        tostring(listing.startTime or "Now"):sub(1, 30),
        tostring(listing.notes or ""):sub(1, 180),
        tostring(listing.createdAt or time()),
        tostring(listing.expiresAt or 0),
        tostring(listing.questLink or ""),
        NormalizeGameMode(listing.gameMode),
        tostring(GetInterestCount(listing)),
        tostring(listing.orbMode or ""),
        tostring(listing.orbEvent or ""),
        tostring(listing.orbNeed or ""),
    })
    if ok then runtime.outboundListingPackets = runtime.outboundListingPackets + 1 end
    return ok
end

BroadcastRemoval = function(id)
    return SendEbon(OPS.REMOVE, { tostring(id or "") })
end

BroadcastAllListings = function()
    if not ZenActivityFinderDB or not ZenActivityFinderDB.settings.shareListings then return end
    for _, listing in ipairs(ZenActivityFinderDB.listings) do
        if listing.status == "OPEN" or listing.status == "FULL" then
            BroadcastListing(listing)
        end
    end
end

AcceptApplicant = function(listing, applicant)
    if not listing or not applicant or not IsOwnedListing(listing) then return end
    if listing.status ~= "OPEN" then
        Print("Reopen the listing before inviting applicants.")
        return
    end
    local listKey = tostring(listing.id)
    local pendingInvites = 0
    for _, existing in ipairs(runtime.applicants[listKey] or {}) do
        if existing.status == "Inviting"
            or (existing.status == "Invited" and time() - (existing.invitedAt or time()) < 120) then
            pendingInvites = pendingInvites + 1
        end
    end
    runtime.inviteReservations[listKey] = runtime.inviteReservations[listKey] or {}
    for name, invitedAt in pairs(runtime.inviteReservations[listKey]) do
        if time() - invitedAt < 120 and not IsPlayerInGroup(name) then
            pendingInvites = pendingInvites + 1
        else
            runtime.inviteReservations[listKey][name] = nil
        end
    end
    if (listing.currentSize or GetCurrentGroupSize()) + pendingInvites >= (listing.groupSize or 5) then
        applicant.status = "Full"
        return
    end
    if not InviteUnit then
        Print("This game client does not provide the group invite function.")
        return
    end
    local inviteKey = (applicant.name or "Unknown"):lower()
    applicant.status = "Inviting"
    runtime.pendingInvites[inviteKey] = {
        applicant = applicant,
        listing = listing,
        attemptedAt = GetTime and GetTime() or time(),
    }
    InviteUnit(applicant.name)
    if applicantsFrame and applicantsFrame:IsShown() and OpenApplicantsFrame then OpenApplicantsFrame(listing) end
end

local function IsLikelyInviteFailure(message)
    local text = tostring(message or ""):lower()
    local markers = {
        "cannot", "can't", "could not", "failed", "not found", "not online",
        "already in", "declines", "declined", "not the party leader",
        "not the raid leader", "group is full", "party is full", "raid is full",
        "hardcore", "hc level", "hc mode", "different hc", "prestige",
        "incompatible", "unable to invite", "may not invite",
    }
    for _, marker in ipairs(markers) do
        if text:find(marker, 1, true) then return true end
    end
    return false
end

local function ContainsAnyInviteError(text, markers)
    for _, marker in ipairs(markers) do
        if text:find(marker, 1, true) then return true end
    end
    return false
end

local function ExpandInviteFailureTemplate(template, cleanError, applicantMode, groupMode)
    local whisper = template:gsub("{applicant_mode}", applicantMode)
    whisper = whisper:gsub("{applicant mode}", applicantMode)
    whisper = whisper:gsub("{group_mode}", groupMode)
    whisper = whisper:gsub("{group mode}", groupMode)
    whisper = whisper:gsub("{error}", cleanError)
    return CompactText(whisper, 220)
end

local function BuildSmartInviteFailureWhisper(cleanError, applicant, listing)
    local text = tostring(cleanError or ""):lower()
    if ContainsAnyInviteError(text, {
        "already in your group", "already in the group", "already in this group",
    }) then
        return "You are already in this group."
    end
    if ContainsAnyInviteError(text, {
        "already in a group", "already in a party", "already in a raid",
        "is in a group", "is in a party", "is in a raid",
    }) then
        return "You are already in a group."
    end
    if ContainsAnyInviteError(text, {
        "group is full", "party is full", "raid is full", "too many players",
    }) then
        return "This group is already full."
    end
    if ContainsAnyInviteError(text, { "not the party leader", "not the raid leader" }) then
        return "I cannot invite you because I am not the group leader."
    end

    local applicantMode = GetGameModeName(applicant.gameMode
        or runtime.peerGameModes[GetApplicantKey(applicant.name)] or "NORMAL")
    local groupMode = GetGameModeName((listing and listing.gameMode) or GetDetectedGameMode())
    local explicitModeError = ContainsAnyInviteError(text, {
        "hardcore", "hardmode", "hc level", "hc mode", "different hc",
        "different mode", "same mode", "game mode", "difficulty", "prestige",
        "incompatible mode",
    })
    local ambiguousModeError = ContainsAnyInviteError(text, {
        "cannot invite", "can't invite", "could not invite", "unable to invite",
        "may not invite", "incompatible",
    })
    if explicitModeError or (applicantMode ~= groupMode and ambiguousModeError) then
        local template = Trim(ZenActivityFinderDB.settings.inviteFailureWhisper or "")
        if template == "" then return nil end
        return ExpandInviteFailureTemplate(template, cleanError, applicantMode, groupMode)
    end

    return CompactText("Invite failed: " .. cleanError, 220)
end

local function FindPendingInvite(message)
    local text = tostring(message or ""):lower()
    local now = GetTime and GetTime() or time()
    local newestKey
    local newestAttempt = 0
    for key, pending in pairs(runtime.pendingInvites) do
        local age = now - (pending.attemptedAt or now)
        if age <= 4 then
            if text:find(key, 1, true) then return key, pending end
            if (pending.attemptedAt or 0) >= newestAttempt then
                newestKey = key
                newestAttempt = pending.attemptedAt or 0
            end
        end
    end
    return newestKey, newestKey and runtime.pendingInvites[newestKey] or nil
end

local function HandleInviteFailureMessage(message, trustMessage)
    if type(message) ~= "string" or message == "" then return end
    if not trustMessage and not IsLikelyInviteFailure(message) then return end
    local inviteKey, pending = FindPendingInvite(message)
    if not pending then return end

    runtime.pendingInvites[inviteKey] = nil
    local applicant = pending.applicant
    local listing = pending.listing
    if applicant then applicant.status = "Invite Failed" end
    local cleanError = CompactText(message, 150)
    if ZenActivityFinderDB.settings.autoWhisperInviteErrors
        and SendChatMessage and applicant and applicant.name then
        local whisper = BuildSmartInviteFailureWhisper(cleanError, applicant, listing)
        if whisper and whisper ~= "" then
            SendChatMessage(whisper, "WHISPER", nil, applicant.name)
        end
    end
    Print("Invite to " .. ((applicant and applicant.name) or "the applicant")
        .. " failed: " .. cleanError)
    if applicantsFrame and applicantsFrame:IsShown() and listing and OpenApplicantsFrame then
        OpenApplicantsFrame(listing)
    end
end

local function CompletePendingInvites()
    local now = GetTime and GetTime() or time()
    local refreshListing
    for key, pending in pairs(runtime.pendingInvites) do
        if now - (pending.attemptedAt or now) >= 1.5 then
            runtime.pendingInvites[key] = nil
            local applicant = pending.applicant
            local listing = pending.listing
            if applicant and listing then
                applicant.status = IsPlayerInGroup(applicant.name) and "Joined" or "Invited"
                applicant.invitedAt = time()
                local listKey = tostring(listing.id)
                runtime.inviteReservations[listKey] = runtime.inviteReservations[listKey] or {}
                runtime.inviteReservations[listKey][GetApplicantKey(applicant.name)] = time()
                QueueDirectAction(OPS.RESPONSE,
                    { applicant.name, "A", listing.id, listing.title or "Activity" })
                Notify("Invitation sent to " .. applicant.name .. ".", false)
                refreshListing = listing
            end
        end
    end
    if refreshListing then
        UpdateListings()
        if applicantsFrame and applicantsFrame:IsShown() and OpenApplicantsFrame then
            OpenApplicantsFrame(refreshListing)
        end
    end
end

DeclineApplicant = function(listing, applicant)
    if not listing or not applicant or not IsOwnedListing(listing) then return end
    runtime.pendingInvites[(applicant.name or "Unknown"):lower()] = nil
    SetDeclineLockout(listing, applicant.name)
    QueueDirectAction(OPS.RESPONSE,
        { applicant.name, "D", listing.id, listing.title or "Activity" })
    RemoveApplicantFromListing(listing, applicant)
    UpdateListings()
    if applicantsFrame and applicantsFrame:IsShown() and OpenApplicantsFrame then OpenApplicantsFrame(listing) end
end

SendJoinRequest = function(listing)
    if not listing then return end
    if IsOwnedListing(listing) or IsLocalPlayerName(listing.owner) then
        Print("You cannot apply to your own listing.")
        return
    end
    local cooldown = GetApplicationCooldownRemaining(listing.id)
    if cooldown > 0 then
        Print("You can re-apply to this listing in " .. cooldown .. " seconds.")
        return
    end
    local playerLevel = UnitLevel("player") or 1
    local className, classToken = UnitClass("player")
    className = className or "Unknown"
    classToken = classToken or ""
    if listing.category == "ORB" and not CanLocalPlayerFillOrbNeed(listing) then
        Print("That Orb Farm is not currently recruiting a role your class can fill.")
        return
    end
    local queued = QueueDirectAction(OPS.REQUEST,
        { listing.owner, listing.remoteID or listing.id, playerLevel, className, GetDetectedGameMode(), classToken })
    if queued then
        runtime.requested[listing.id] = time()
        Print("Invite request sent to " .. (listing.owner or "the organizer") .. ".")
        UpdateListings()
    else
        Print("Invite request could not be sent. Refresh the finder and try again.")
    end
end

local transportStarted = false

local function OnEbonListing(sender, body)
    local fields = DecodeFields(body)
    if #fields < 13 then return end
    local cleanSender = MarkPeer(sender, fields[13])
    if cleanSender == "Unknown" or IsLocalPlayerName(cleanSender) then return end

    runtime.protocolMessages = runtime.protocolMessages + 1
    runtime.processedRemotePayloads = runtime.processedRemotePayloads + 1
    runtime.compactListingsReceived = runtime.compactListingsReceived + 1
    runtime.lastRemoteCommand = "L"

    local wireID = fields[1]
    local key = GetListingKey(cleanSender, wireID)
    local isNew = runtime.remoteListings[key] == nil
    for existingKey, existing in pairs(runtime.remoteListings) do
        if existingKey ~= key and (existing.owner or ""):lower() == cleanSender:lower() then
            runtime.remoteListings[existingKey] = nil
        end
    end

    local status = fields[7]
    if status ~= "OPEN" and status ~= "FULL" then
        runtime.remoteListings[key] = nil
        if state.selectedID == key then state.selectedID = nil end
        UpdateListings()
        return
    end

    local category = fields[2]
    if category == "ALL" or not categoryByKey[category] then category = "CUSTOM" end
    local targetSize = math.max(2, math.min(40, tonumber(fields[6]) or 5))
    local currentSize = math.max(1, math.min(targetSize, tonumber(fields[5]) or 1))
    local createdAt = tonumber(fields[10]) or time()
    if createdAt <= 0 or createdAt > time() + 60 then createdAt = time() end
    local expiresAt = tonumber(fields[11]) or 0
    local maximumRemoteExpiry = createdAt + (30 * 60)
    if expiresAt <= 0 or expiresAt > maximumRemoteExpiry then expiresAt = maximumRemoteExpiry end

    local remoteListing = {
        id = key,
        remoteID = wireID,
        remote = true,
        isOwner = false,
        category = category,
        title = tostring(fields[3] or "Untitled activity"):sub(1, 60),
        activity = tostring(fields[4] or ""):sub(1, 60),
        owner = cleanSender,
        currentSize = currentSize,
        groupSize = targetSize,
        status = status,
        startTime = tostring(fields[8] or "Now"):sub(1, 30),
        notes = tostring(fields[9] or ""):sub(1, 180),
        createdAt = createdAt,
        expiresAt = expiresAt,
        questLink = fields[12] or "",
        gameMode = NormalizeGameMode(fields[13]),
        interestCount = tonumber(fields[14]) or 0,
        orbMode = category == "ORB" and tostring(fields[15] or "TOC"):upper() or nil,
        orbEvent = category == "ORB" and tostring(fields[16] or ""):sub(1, 60) or nil,
        orbNeed = category == "ORB" and tostring(fields[17] or "ANY"):upper() or nil,
        lastSeen = time(),
    }
    runtime.remoteListings[key] = remoteListing
    runtime.importedListingPackets = runtime.importedListingPackets + 1
    HandleNewRemoteListing(remoteListing, isNew)
    UpdateListings()
end

local function OnEbonRemoval(sender, body)
    local fields = DecodeFields(body)
    local cleanSender = MarkPeer(sender)
    local wireID = fields[1]
    if not wireID or wireID == "" then return end
    local key = GetListingKey(cleanSender, wireID)
    runtime.remoteListings[key] = nil
    if state.selectedID == key then state.selectedID = nil end
    UpdateListings()
end

local function OnEbonRefresh(sender, body)
    local fields = DecodeFields(body)
    MarkPeer(sender, fields[1])
    local now = GetTime and GetTime() or time()
    if (runtime.lastRefreshResponseAt == 0
        or now - runtime.lastRefreshResponseAt >= MANUAL_REFRESH_COOLDOWN_SECONDS)
        and not runtime.pendingRefreshBroadcastAt then
        runtime.pendingRefreshBroadcastAt = now + (math.random(0, 30) / 10)
    end
end

local function OnEbonPresence(sender, body)
    local fields = DecodeFields(body)
    local kind = fields[1] or ""
    local cleanSender = MarkPeer(sender, fields[2])
    if cleanSender == "Unknown" then return end
    if kind == "H" then
        local now = GetTime and GetTime() or time()
        local replyAt = now + (math.random(2, 20) / 10)
        if runtime.lastPresenceResponseAt > 0 then
            local cooldownEnds = runtime.lastPresenceResponseAt + PRESENCE_REPLY_COOLDOWN_SECONDS
            if replyAt < cooldownEnds then replyAt = cooldownEnds end
        end
        if not runtime.pendingPresenceResponseAt or replyAt < runtime.pendingPresenceResponseAt then
            runtime.pendingPresenceResponseAt = replyAt
        end
    end
end

local function OnEbonRequest(sender, body)
    local fields = DecodeFields(body)
    if #fields < 4 then return end
    local cleanSender = MarkPeer(sender, fields[5])
    if IsLocalPlayerName(cleanSender) then return end
    local playerName = SanitizePlayerName(UnitName("player") or "Unknown")
    if SanitizePlayerName(fields[1]):lower() ~= playerName:lower() then return end

    local listing = FindOwnedListingByWireID(fields[2])
    if not listing or listing.status ~= "OPEN" then return end
    if HasDeclineLockout(listing, cleanSender) then return end

    local listKey = tostring(listing.id)
    runtime.applicants[listKey] = runtime.applicants[listKey] or {}
    local applicants = runtime.applicants[listKey]
    local applicant
    for _, existing in ipairs(applicants) do
        if (existing.name or ""):lower() == cleanSender:lower() then
            applicant = existing
            break
        end
    end
    if not applicant then
        applicant = {
            name = cleanSender,
            level = tonumber(fields[3]) or 1,
            className = fields[4] or "Unknown",
            gameMode = NormalizeGameMode(fields[5]),
            classToken = fields[6] or "",
            createdAt = time(),
            status = "Waiting",
        }
        table.insert(applicants, 1, applicant)
        Notify(cleanSender .. " requested an invite for " .. (listing.title or "your activity") .. ".", true)
    elseif applicant.status ~= "Joined" then
        applicant.status = "Waiting"
        applicant.gameMode = NormalizeGameMode(fields[5])
        applicant.classToken = fields[6] or applicant.classToken or ""
        applicant.createdAt = time()
        applicant.declinedAt = nil
        Notify(cleanSender .. " re-applied for " .. (listing.title or "your activity") .. ".", true)
    end
    if listing.autoInvite and applicant.status == "Waiting" then AcceptApplicant(listing, applicant) end
    UpdateListings()
end

local function OnEbonResponse(sender, body)
    local fields = DecodeFields(body)
    if #fields < 3 then return end
    local cleanSender = MarkPeer(sender)
    local playerName = SanitizePlayerName(UnitName("player") or "Unknown")
    if SanitizePlayerName(fields[1]):lower() ~= playerName:lower() then return end

    local action = fields[2]
    local listingID = fields[3]
    local value = fields[4] or ""
    if action == "A" then
        Notify("You were invited to " .. (value ~= "" and value or "an activity") .. ".", true)
    elseif action == "D" then
        runtime.requested[GetListingKey(cleanSender, listingID)] = time()
        Notify("Your request for " .. (value ~= "" and value or "an activity") .. " was declined.", true)
        UpdateListings()
    elseif action == "I" then
        local listing = FindOwnedListingByWireID(listingID)
        if listing then
            local listKey = tostring(listing.id)
            runtime.interested[listKey] = runtime.interested[listKey] or {}
            if value == "1" then
                local wasInterested = runtime.interested[listKey][cleanSender] ~= nil
                runtime.interested[listKey][cleanSender] = time()
                if not wasInterested then
                    Notify(cleanSender .. " is interested in " .. (listing.title or "your activity") .. ".", false)
                end
            else
                runtime.interested[listKey][cleanSender] = nil
            end
            listing.interestCount = GetInterestCount(listing)
            BroadcastListing(listing)
            UpdateListings()
        end
    end
end

local function StartEbonTransport()
    if transportStarted or not ebon then return false end
    transportStarted = true
    ebon:OnChannel(OPS.LISTING, OnEbonListing)
    ebon:OnChannel(OPS.REMOVE, OnEbonRemoval)
    ebon:OnChannel(OPS.REQUEST, OnEbonRequest)
    ebon:OnChannel(OPS.RESPONSE, OnEbonResponse)
    ebon:OnChannel(OPS.REFRESH, OnEbonRefresh)
    ebon:OnChannel(OPS.PRESENCE, OnEbonPresence)
    ebon:On("CHANNEL_JOINED", function()
        UpdateConnectionStatus()
        QueueDirectAction(OPS.PRESENCE, { "H" })
        QueueDirectAction(OPS.REFRESH)
        BroadcastAllListings()
    end)
    ebon:On("CHANNEL_LOST", function()
        UpdateConnectionStatus()
    end)
    return true
end

EnsureChannel = function()
    if EbonAPI and EbonAPI.Channel and EbonAPI.Channel.require then
        EbonAPI.Channel.require()
    end
    local connected = ebon and ebon:IsChannelJoined() or false
    UpdateConnectionStatus()
    return connected
end

RefreshSharedListings = function(showMessage)
    EnsureChannel()
    if showMessage then
        local remaining = GetManualRefreshRemaining()
        if remaining > 0 then
            Print("Refresh is available again in " .. remaining .. " seconds.")
            UpdateRefreshButton()
            return
        end
    end

    local queued = QueueDirectAction(OPS.REFRESH)
    if showMessage and queued then
        runtime.lastManualRefreshAt = time()
        UpdateRefreshButton()
        Print("Refresh requested through EbonAPI. " .. GetActivePeerCount() .. " ZenActivityFinder user(s) detected.")
    elseif showMessage and not queued then
        Print("EbonAPI is still connecting. Refresh will run automatically when the shared channel is ready.")
    end
end

RefreshGroupState = function()
    if not ZenActivityFinderDB then return end
    local currentSize = GetCurrentGroupSize()
    local now = time()
    local changed = false
    local refreshApplicantsListing
    for index = #ZenActivityFinderDB.listings, 1, -1 do
        local listing = ZenActivityFinderDB.listings[index]
        local inactive = listing.status == "CLOSED" or listing.status == "EXPIRED"
        local inactiveSince = listing.closedAt or listing.updatedAt or listing.expiresAt or listing.createdAt or now
        if inactive and now - inactiveSince >= INACTIVE_REMOVAL_SECONDS then
            BroadcastRemoval(listing.id)
            runtime.applicants[tostring(listing.id)] = nil
            runtime.declineLockouts[tostring(listing.id)] = nil
            runtime.inviteReservations[tostring(listing.id)] = nil
            if tostring(state.selectedID) == tostring(listing.id) then state.selectedID = nil end
            table.remove(ZenActivityFinderDB.listings, index)
            changed = true
        else
            local listingChanged = listing.currentSize ~= currentSize
            listing.currentSize = currentSize
            if listing.category == "ORB" then
                listing.groupSize = 5
                local orbNeed = GetOrbNeedCode()
                if listing.orbNeed ~= orbNeed then
                    listing.orbNeed = orbNeed
                    listingChanged = true
                end
            end
            local abandonedListing = (listing.status == "OPEN" or listing.status == "FULL")
                and currentSize > 1 and not IsOwnListedGroup(listing)
            if abandonedListing then
                listing.status = "CLOSED"
                listing.closedAt = now
                listingChanged = true
                runtime.applicants[tostring(listing.id)] = {}
                runtime.inviteReservations[tostring(listing.id)] = {}
                for key, pending in pairs(runtime.pendingInvites) do
                    if pending.listing == listing then runtime.pendingInvites[key] = nil end
                end
                Print("Your active listing was closed because you joined another leader's group.")
            else
                local applicants = runtime.applicants[tostring(listing.id)] or {}
                for applicantIndex = #applicants, 1, -1 do
                    local applicant = applicants[applicantIndex]
                    if IsPlayerInGroup(applicant.name) then
                        table.remove(applicants, applicantIndex)
                        refreshApplicantsListing = listing
                        changed = true
                    end
                end
                local reservations = runtime.inviteReservations[tostring(listing.id)] or {}
                for name, invitedAt in pairs(reservations) do
                    if IsPlayerInGroup(name) or now - invitedAt >= 120 then reservations[name] = nil end
                end
                if listing.status ~= "EXPIRED" and listing.expiresAt and listing.expiresAt > 0 and now >= listing.expiresAt then
                    listing.status = "EXPIRED"
                    listing.closedAt = listing.closedAt or now
                    listingChanged = true
                elseif listing.status == "OPEN" and currentSize >= (listing.groupSize or 5) then
                    if listing.autoClose then
                        listing.status = "CLOSED"
                        listing.closedAt = now
                    else
                        listing.status = "FULL"
                    end
                    listingChanged = true
                elseif listing.status == "FULL" and currentSize < (listing.groupSize or 5) then
                    listing.status = "OPEN"
                    listing.closedAt = nil
                    listingChanged = true
                end
            end
            if listingChanged then BroadcastListing(listing) end
            changed = changed or listingChanged
        end
    end
    if changed then UpdateListings() end
    if refreshApplicantsListing and applicantsFrame and applicantsFrame:IsShown()
        and OpenApplicantsFrame then
        OpenApplicantsFrame(refreshApplicantsListing)
    end
end

local function CreateSettingToggle(parent, label, key, y, callback)
    local button = CreateFrame("Button", nil, parent)
    button:SetPoint("TOPLEFT", 20, y)
    button:SetWidth(340)
    button:SetHeight(28)
    button.box = CreateFrame("Frame", nil, button)
    button.box:SetPoint("LEFT", 0, 0)
    button.box:SetWidth(20)
    button.box:SetHeight(20)
    AddBackground(button.box, COLORS.panelLight, COLORS.border)
    button.mark = CreateText(button.box, "", 12, COLORS.gold, "CENTER")
    button.mark:SetAllPoints()
    button.label = CreateText(button, label, 11, COLORS.text)
    button.label:SetPoint("LEFT", 30, 0)
    button.key = key
    function button:Refresh()
        local enabled = ZenActivityFinderDB.settings[self.key] == true
        self.mark:SetText(enabled and "X" or "")
        if enabled then
            local r, g, b = UI:Accent()
            UI:ColorBorder(self.box, r, g, b, 1)
        else
            UI:RefreshSurface(self.box)
        end
    end
    button:SetScript("OnClick", function(self)
        ZenActivityFinderDB.settings[self.key] = not ZenActivityFinderDB.settings[self.key]
        self:Refresh()
        if callback then callback(ZenActivityFinderDB.settings[self.key]) end
    end)
    return button
end

local function CreateListingWatchDropdown(parent)
    local values = { "OFF", "ALL", "ORB", "RAID", "QUEST", "WORLD", "CUSTOM" }
    local dropdown = CreateButton(parent, "Off", 360, 28)

    dropdown.arrow = CreateText(dropdown, "v", 11, COLORS.gold, "CENTER")
    dropdown.arrow:SetPoint("RIGHT", -10, 0)
    dropdown.arrow:SetWidth(14)

    dropdown.menu = CreateFrame("Frame", nil, parent)
    dropdown.menu:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 0, -2)
    dropdown.menu:SetWidth(360)
    dropdown.menu:SetHeight((#values * 28) + 4)
    dropdown.menu:SetFrameLevel(parent:GetFrameLevel() + 30)
    AddBackground(dropdown.menu, COLORS.panel, COLORS.gold)
    dropdown.menu:Hide()

    for index, key in ipairs(values) do
        local option = CreateFrame("Button", nil, dropdown.menu)
        option:SetPoint("TOPLEFT", 2, -2 - ((index - 1) * 28))
        option:SetWidth(356)
        option:SetHeight(28)
        option.value = key
        option.highlight = option:CreateTexture(nil, "BACKGROUND")
        option.highlight:SetAllPoints()
        SetColor(option.highlight, { 0.14, 0.16, 0.20, 1 })
        option.highlight:Hide()
        option.label = CreateText(option, GetListingWatchName(key), 11, COLORS.text)
        option.label:SetPoint("LEFT", 10, 0)
        option:SetScript("OnEnter", function(self) self.highlight:Show() end)
        option:SetScript("OnLeave", function(self) self.highlight:Hide() end)
        option:SetScript("OnClick", function(self)
            ZenActivityFinderDB.settings.listingWatchCategory = self.value
            if self.value == "OFF" then SetUnreadCount(0) end
            dropdown.label:SetText(GetListingWatchName(self.value))
            dropdown.menu:Hide()
            RefreshNotificationPresentation()
        end)
    end

    dropdown:SetScript("OnClick", function(self)
        if self.menu:IsShown() then self.menu:Hide() else self.menu:Show() end
    end)
    return dropdown
end

local function BuildSettingsFrame()
    settingsFrame = CreateFrame("Frame", "ZenActivityFinderSettingsFrame", UIParent)
    settingsFrame:SetWidth(400)
    settingsFrame:SetHeight(690)
    settingsFrame:SetPoint("CENTER")
    settingsFrame:SetFrameStrata("DIALOG")
    settingsFrame:EnableMouse(true)
    AddBackground(settingsFrame, COLORS.background, COLORS.gold)
    settingsFrame:Hide()
    table.insert(UISpecialFrames, "ZenActivityFinderSettingsFrame")

    local heading = CreateText(settingsFrame, "ZenActivityFinder Settings", 18, COLORS.text)
    heading:SetPoint("TOPLEFT", 20, -18)
    settingsFrame.connection = CreateText(settingsFrame, "Waiting for EbonAPI shared channel", 10, COLORS.muted)
    settingsFrame.connection:SetPoint("TOPLEFT", 20, -44)

    local close = CreateButton(settingsFrame, "X", 28, 28)
    close:SetPoint("TOPRIGHT", -12, -12)
    close:SetScript("OnClick", function() settingsFrame:Hide() end)

    settingsFrame.toggles = {}
    settingsFrame.whisperMessageLabel = CreateText(settingsFrame,
        "HC MISMATCH MESSAGE: {applicant_mode}  {group_mode}  {error}", 9, COLORS.muted)
    settingsFrame.whisperMessageLabel:SetPoint("TOPLEFT", 50, -214)
    settingsFrame.whisperMessageHolder, settingsFrame.whisperMessageInput =
        CreateInput(settingsFrame, 330, 30, 180)
    settingsFrame.whisperMessageHolder:SetPoint("TOPLEFT", 50, -228)
    settingsFrame.whisperMessageInput:SetScript("OnTextChanged", function(self)
        ZenActivityFinderDB.settings.inviteFailureWhisper = self:GetText() or ""
    end)

    local function RefreshWhisperMessageEditor()
        local visible = ZenActivityFinderDB.settings.autoWhisperInviteErrors == true
        if visible then
            settingsFrame.whisperMessageLabel:Show()
            settingsFrame.whisperMessageHolder:Show()
        else
            settingsFrame.whisperMessageLabel:Hide()
            settingsFrame.whisperMessageHolder:Hide()
        end
    end

    local function AddToggle(label, key, y, callback)
        local toggle = CreateSettingToggle(settingsFrame, label, key, y, callback)
        table.insert(settingsFrame.toggles, toggle)
    end
    AddToggle("Share my active listing with other addon users", "shareListings", -78, function(enabled)
        if enabled then BroadcastAllListings() else for _, listing in ipairs(ZenActivityFinderDB.listings) do BroadcastRemoval(listing.id) end end
    end)
    AddToggle("Automatically close my listing when the group is full", "autoClose", -112, function(enabled)
        for _, listing in ipairs(ZenActivityFinderDB.listings) do listing.autoClose = enabled end
        RefreshGroupState()
    end)
    AddToggle("Automatically invite eligible applicants", "autoInvite", -146, function(enabled)
        for _, listing in ipairs(ZenActivityFinderDB.listings) do
            listing.autoInvite = enabled
            if enabled and listing.status == "OPEN" then
                for _, applicant in ipairs(runtime.applicants[tostring(listing.id)] or {}) do
                    if applicant.status == "Waiting" then AcceptApplicant(listing, applicant) end
                end
            end
        end
    end)
    AddToggle("Whisper applicants when an invite fails", "autoWhisperInviteErrors", -180, function()
        RefreshWhisperMessageEditor()
    end)
    AddToggle("Enable activity notifications", "notifications", -270, function(enabled)
        if not enabled then SetUnreadCount(0) end
        RefreshNotificationPresentation()
    end)
    AddToggle("Show pop-up toasts for new activities", "listingToasts", -304, function() RefreshNotificationPresentation() end)
    AddToggle("Glow launchers when activities are unread", "launcherAlerts", -338, function() RefreshNotificationPresentation() end)
    local watchLabel = CreateText(settingsFrame, "NEW LISTING ALERT CATEGORIES", 9, COLORS.muted)
    watchLabel:SetPoint("TOPLEFT", 20, -376)
    settingsFrame.listingWatch = CreateListingWatchDropdown(settingsFrame)
    settingsFrame.listingWatch:SetPoint("TOPLEFT", 20, -389)
    AddToggle("Play notification sounds", "sounds", -429)
    AddToggle("Show the floating finder button", "showLauncher", -463, function() RefreshLauncher() end)
    AddToggle("Lock the floating finder button", "lockLauncher", -497, function() RefreshLauncher() end)
    AddToggle("Keep the Zen Activity Finder and Quest Log synchronized", "linkQuestLog", -531, function(enabled)
        if enabled and mainFrame and mainFrame:IsShown() then ShowLinkedQuestLog() end
    end)

    local expiryLabel = CreateText(settingsFrame, "AUTO-EXPIRE MY LISTING", 9, COLORS.muted)
    expiryLabel:SetPoint("TOPLEFT", 20, -579)
    settingsFrame.expiry = CreateButton(settingsFrame, "15 minutes", 360, 28)
    settingsFrame.expiry:SetPoint("TOPLEFT", 20, -594)
    settingsFrame.expiry:SetScript("OnClick", function(self)
        local current = NormalizeExpiryMinutes(ZenActivityFinderDB.settings.expiryMinutes)
        local nextValue = EXPIRY_VALUES[1]
        for index, value in ipairs(EXPIRY_VALUES) do
            if value == current then nextValue = EXPIRY_VALUES[(index % #EXPIRY_VALUES) + 1] break end
        end
        ZenActivityFinderDB.settings.expiryMinutes = nextValue
        self.label:SetText(nextValue .. " minutes")
        for _, listing in ipairs(ZenActivityFinderDB.listings) do
            if listing.status ~= "EXPIRED" then
                listing.expiresAt = time() + (nextValue * 60)
                BroadcastListing(listing)
            end
        end
    end)

    local appearanceButton = CreateButton(settingsFrame, "Appearance", 110, 28)
    appearanceButton:SetPoint("BOTTOMRIGHT", -20, 14)
    appearanceButton:SetScript("OnClick", function()
        if not appearanceFrame then
            appearanceFrame = UI:CreateAppearancePanel(UIParent)
        end
        appearanceFrame:Show()
        if appearanceFrame.Raise then appearanceFrame:Raise() end
    end)

    local warning = CreateText(settingsFrame, "Listings expire after 5-30 minutes. Networking is handled by EbonAPI.", 9, COLORS.muted)
    warning:SetPoint("BOTTOMLEFT", 20, 18)
    warning:SetWidth(235)

    settingsFrame:SetScript("OnShow", function(self)
        if mainFrame and not mainFrame:IsShown() and ShowMainFrame then ShowMainFrame(true) end
        HideOtherSecondaryWindows(self)
        EnsureChannel()
        for _, toggle in ipairs(self.toggles) do toggle:Refresh() end
        self.whisperMessageInput:SetText(ZenActivityFinderDB.settings.inviteFailureWhisper or "")
        RefreshWhisperMessageEditor()
        local watched = NormalizeListingWatchCategory(
            ZenActivityFinderDB.settings.listingWatchCategory)
        ZenActivityFinderDB.settings.listingWatchCategory = watched
        self.listingWatch.label:SetText(GetListingWatchName(watched))
        local expiry = NormalizeExpiryMinutes(ZenActivityFinderDB.settings.expiryMinutes)
        ZenActivityFinderDB.settings.expiryMinutes = expiry
        self.expiry.label:SetText(expiry .. " minutes")
    end)
    settingsFrame:SetScript("OnHide", function(self)
        if self.listingWatch and self.listingWatch.menu then self.listingWatch.menu:Hide() end
    end)
end

OpenSettingsFrame = function()
    if settingsFrame:IsShown() then
        settingsFrame:Hide()
    else
        if mainFrame and not mainFrame:IsShown() and ShowMainFrame then ShowMainFrame(true) end
        HideOtherSecondaryWindows(settingsFrame)
        settingsFrame:Show()
    end
end

local function BuildApplicantsFrame()
    applicantsFrame = CreateFrame("Frame", "ZenActivityFinderApplicantsFrame", UIParent)
    applicantsFrame:SetWidth(490)
    applicantsFrame:SetHeight(390)
    applicantsFrame:SetPoint("CENTER")
    applicantsFrame:SetFrameStrata("DIALOG")
    applicantsFrame:EnableMouse(true)
    AddBackground(applicantsFrame, COLORS.background, COLORS.gold)
    applicantsFrame:Hide()
    table.insert(UISpecialFrames, "ZenActivityFinderApplicantsFrame")
    applicantsFrame:SetScript("OnShow", function(self)
        if mainFrame and not mainFrame:IsShown() and ShowMainFrame then ShowMainFrame(true) end
        HideOtherSecondaryWindows(self)
    end)

    applicantsFrame.heading = CreateText(applicantsFrame, "Applicants", 18, COLORS.text)
    applicantsFrame.heading:SetPoint("TOPLEFT", 20, -18)
    applicantsFrame.summary = CreateText(applicantsFrame, "", 10, COLORS.muted)
    applicantsFrame.summary:SetPoint("TOPLEFT", 20, -44)
    local close = CreateButton(applicantsFrame, "X", 28, 28)
    close:SetPoint("TOPRIGHT", -12, -12)
    close:SetScript("OnClick", function() applicantsFrame:Hide() end)

    applicantsFrame.rows = {}
    for index = 1, 6 do
        local row = CreateFrame("Frame", nil, applicantsFrame)
        row:SetPoint("TOPLEFT", 20, -76 - ((index - 1) * 48))
        row:SetWidth(450)
        row:SetHeight(42)
        AddBackground(row, COLORS.panel, COLORS.border)
        row.name = CreateText(row, "", 12, COLORS.text)
        row.name:SetPoint("TOPLEFT", 10, -6)
        row.meta = CreateText(row, "", 9, COLORS.muted)
        row.meta:SetPoint("BOTTOMLEFT", 10, 6)
        row.status = CreateText(row, "", 9, COLORS.gold, "RIGHT")
        row.status:SetPoint("RIGHT", -224, 0)
        row.invite = CreateButton(row, "Invite", 64, 26)
        row.invite:SetPoint("RIGHT", -150, 0)
        row.decline = CreateButton(row, "Decline", 68, 26)
        row.decline:SetPoint("RIGHT", -76, 0)
        row.whisper = CreateButton(row, "Whisper", 70, 26)
        row.whisper:SetPoint("RIGHT", -4, 0)
        row.invite:SetScript("OnClick", function() AcceptApplicant(applicantsFrame.listing, row.applicant) end)
        row.decline:SetScript("OnClick", function() DeclineApplicant(applicantsFrame.listing, row.applicant) end)
        row.whisper:SetScript("OnClick", function()
            if row.applicant and ChatFrame_OpenChat then ChatFrame_OpenChat("/w " .. row.applicant.name .. " ") end
        end)
        applicantsFrame.rows[index] = row
    end
end

OpenApplicantsFrame = function(listing)
    if mainFrame and not mainFrame:IsShown() and ShowMainFrame then ShowMainFrame(true) end
    HideOtherSecondaryWindows(applicantsFrame)
    applicantsFrame.listing = listing
    applicantsFrame.heading:SetText("Applicants - " .. (listing.title or "Activity"))
    local applicants = runtime.applicants[tostring(listing.id)] or {}
    applicantsFrame.summary:SetText(#applicants .. (#applicants == 1 and " applicant" or " applicants"))
    for index, row in ipairs(applicantsFrame.rows) do
        local applicant = applicants[index]
        if applicant then
            row.applicant = applicant
            row.name:SetText(applicant.name)
            local roleText = ""
            if listing.category == "ORB" and applicant.classToken and applicant.classToken ~= "" then
                roleText = "  " .. GetClassRoleMarkup(applicant.classToken)
            end
            row.meta:SetText("Level " .. tostring(applicant.level or 1) .. " " .. (applicant.className or "Unknown") .. roleText)
            row.status:SetText(applicant.status or "Waiting")
            row:Show()
        else
            row.applicant = nil
            row:Hide()
        end
    end
    applicantsFrame:Show()
end

local function BuildLauncherButton()
    launcherButton = CreateFrame("Button", "ZenActivityFinderLauncher", UIParent)
    launcherButton:SetWidth(44)
    launcherButton:SetHeight(44)
    launcherButton:SetPoint("RIGHT", UIParent, "RIGHT", -24, 80)
    launcherButton:SetMovable(true)
    launcherButton:SetClampedToScreen(true)
    launcherButton:EnableMouse(true)
    launcherButton:RegisterForDrag("LeftButton")
    AddBackground(launcherButton, COLORS.panel, COLORS.gold)
    launcherButton.icon = launcherButton:CreateTexture(nil, "ARTWORK")
    launcherButton.icon:SetPoint("TOPLEFT", 5, -5)
    launcherButton.icon:SetPoint("BOTTOMRIGHT", -5, 5)
    launcherButton.icon:SetTexture("Interface\\Icons\\INV_Misc_GroupLooking")
    launcherButton.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    launcherButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    launcherButton.alertGlow = launcherButton:CreateTexture(nil, "OVERLAY")
    launcherButton.alertGlow:SetPoint("TOPLEFT", -5, 5)
    launcherButton.alertGlow:SetPoint("BOTTOMRIGHT", 5, -5)
    launcherButton.alertGlow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    launcherButton.alertGlow:SetBlendMode("ADD")
    launcherButton.alertGlow:Hide()
    launcherButton.badge = CreateText(launcherButton, "", 10, COLORS.gold, "CENTER")
    launcherButton.badge:SetPoint("TOPRIGHT", 7, 7)
    launcherButton.badge:SetWidth(24)
    launcherButton.badge:SetHeight(18)
    launcherButton.alertElapsed = 0
    launcherButton:SetScript("OnUpdate", function(self, elapsed)
        if not self.alertGlow or not self.alertGlow:IsShown() then return end
        self.alertElapsed = (self.alertElapsed or 0) + elapsed
        local alpha = 0.45 + (0.35 * math.abs(math.sin(self.alertElapsed * 3)))
        self.alertGlow:SetAlpha(alpha)
    end)

    launcherButton:SetScript("OnDragStart", function(self)
        if not ZenActivityFinderDB.settings.lockLauncher then
            self.dragging = true
            self:StartMoving()
        end
    end)
    launcherButton:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint(1)
        ZenActivityFinderDB.launcherPosition = { point = point, relativePoint = relativePoint, x = x, y = y }
        if self.dragging then self.justDraggedAt = GetTime() end
        self.dragging = false
    end)
    launcherButton:SetScript("OnClick", function(_, button)
        if launcherButton.justDraggedAt and GetTime() - launcherButton.justDraggedAt < 0.25 then return end
        if button == "RightButton" then OpenSettingsFrame() else ToggleMainFrame() end
    end)
    launcherButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    launcherButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("ZenActivityFinder", 1, 0.82, 0.3)
        GameTooltip:AddLine("Left-click: open finder", 1, 1, 1)
        GameTooltip:AddLine("Right-click: settings", 1, 1, 1)
        GameTooltip:AddLine(ZenActivityFinderDB.settings.lockLauncher and "Position locked" or "Drag to move", 0.65, 0.65, 0.65)
        GameTooltip:Show()
    end)
    launcherButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    if ZenActivityFinderDB.launcherPosition then
        local position = ZenActivityFinderDB.launcherPosition
        launcherButton:ClearAllPoints()
        launcherButton:SetPoint(position.point or "RIGHT", UIParent, position.relativePoint or "RIGHT", position.x or -24, position.y or 80)
    end
end

RefreshNotificationPresentation = function()
    if not ZenActivityFinderDB then return end
    local unread = GetUnreadCount()
    if launcherButton then
        launcherButton.badge:SetText(unread > 0 and tostring(math.min(unread, 99)) or "")
        local alert = unread > 0 and ZenActivityFinderDB.settings.notifications
            and ZenActivityFinderDB.settings.launcherAlerts
        if alert then launcherButton.alertGlow:Show() else launcherButton.alertGlow:Hide() end
    end
    if (not ZenActivityFinderDB.settings.notifications
        or not ZenActivityFinderDB.settings.listingToasts)
        and toastFrame then toastFrame:Hide() end
end

RefreshLauncher = function()
    if not launcherButton or not ZenActivityFinderDB then return end
    if ZenActivityFinderDB.settings.showLauncher then launcherButton:Show() else launcherButton:Hide() end
    RefreshNotificationPresentation()
end

ShowMainFrame = function(openLinkedQuestLog)
    if not mainFrame then return end
    mainFrame:Show()
    ClearUnreadListings()
    UpdateListings()
    if openLinkedQuestLog ~= false
        and ZenActivityFinderDB.settings.linkQuestLog then
        ShowLinkedQuestLog()
    end
end

ToggleMainFrame = function()
    if not mainFrame then return end
    if mainFrame:IsShown() then
        mainFrame:Hide()
    else
        ShowMainFrame(true)
    end
end

-- Native Orb Farm helpers. These are intentionally private to ZenActivityFinder;
-- no external Orb addon is required or contacted.
local function OpenOrbFinder()
    if not mainFrame then return false end
    state.category = "ORB"
    state.search = ""
    state.page = 1
    state.selectedID = nil
    if searchBox then searchBox:SetText("") end
    ShowMainFrame(true)
    UpdateListings()
    return true
end

local function ApplyNativeOrbPresetToListing(listing)
    local mode, eventName, title, activity = GetOrbPreset()
    listing.category = "ORB"
    listing.groupSize = 5
    listing.currentSize = GetCurrentGroupSize()
    listing.orbMode = mode
    listing.orbEvent = eventName
    listing.orbNeed = GetOrbNeedCode()
    listing.title = title
    listing.activity = activity
    listing.startTime = "Now"
    listing.notes = listing.notes or ""
    listing.gameMode = GetDetectedGameMode()
    listing.status = "OPEN"
    listing.closedAt = nil
    listing.updatedAt = time()
    listing.expiresAt = time() + (NormalizeExpiryMinutes(ZenActivityFinderDB.settings.expiryMinutes) * 60)
    return listing
end

local function CreateOrRefreshOrbListing()
    if not ZenActivityFinderDB then return false end
    if GetCurrentGroupSize() > 1 and not IsPlayerLeadingCurrentGroup() then
        Print("You cannot host an Orb Farm listing while grouped under another leader.")
        return false
    end

    local listing = FindActiveOwnedListing(nil)
    if listing and listing.category ~= "ORB" then
        Print("You already have another active listing. Close or remove it before hosting an Orb Farm.")
        return false
    end

    if not listing then
        local id = ZenActivityFinderDB.nextID
        ZenActivityFinderDB.nextID = id + 1
        listing = {
            id = id,
            owner = UnitName("player") or "You",
            ownerGUID = UnitGUID and UnitGUID("player"),
            isOwner = true,
            autoClose = ZenActivityFinderDB.settings.autoClose,
            autoInvite = ZenActivityFinderDB.settings.autoInvite,
            createdAt = time(),
        }
        table.insert(ZenActivityFinderDB.listings, 1, listing)
    end

    ApplyNativeOrbPresetToListing(listing)
    listing.createdAt = listing.createdAt or time()
    state.category = "ORB"
    state.search = ""
    state.page = 1
    state.selectedID = listing.id
    if searchBox then searchBox:SetText("") end
    BroadcastListing(listing)
    UpdateListings()
    return true
end

-- Ravioli Integration API v1. These global entry points let Ravioli Menu
-- discover and open this addon entirely from .toc metadata.
local function ApplyZenAppearanceScale()
    local scale = (UI:GetSettings() and UI:GetSettings().scale) or 1
    for _, frame in ipairs({ mainFrame, createFrame, settingsFrame, applicantsFrame }) do
        if frame then frame:SetScale(scale) end
    end
end
UI:OnAppearanceChanged(ApplyZenAppearanceScale)

function ZenActivityFinder_Open()
    if not mainFrame then return false end
    ShowMainFrame(true)
    return true
end

function ZenActivityFinder_OpenSettings()
    if not settingsFrame then return false end
    HideOtherSecondaryWindows(settingsFrame)
    settingsFrame:Show()
    return true
end

function ZenActivityFinder_GetUnreadCount()
    return GetUnreadCount()
end

-- Runtime Ravioli Menu registration. This deliberately repeats the important
-- integration metadata so the menu receives the correct icon even when a
-- stale .toc metadata value was previously observed during the session.
local function RegisterWithRavioliMenu()
    local registration = {
        key = "ZenActivityFinder",
        folder = "ZenActivityFinder",
        addon = "ZenActivityFinder",
        title = "ZenActivityFinder",
        description = "Create and browse shared family activity listings.",
        icon = "Interface\\Icons\\INV_Misc_GroupLooking",
        open = "ZenActivityFinder_Open",
        settings = "ZenActivityFinder_OpenSettings",
        badge = "ZenActivityFinder_GetUnreadCount",
        launcherFrames = { "ZenActivityFinderLauncher" },
        category = "Social",
        order = 30,
        version = VERSION,
        integrationVersion = 1,
    }

    if RavioliMenu and type(RavioliMenu.RegisterAddon) == "function" then
        RavioliMenu:RegisterAddon("ZenActivityFinder", registration)
    else
        RavioliMenuPendingRegistrations = RavioliMenuPendingRegistrations or {}
        table.insert(RavioliMenuPendingRegistrations, registration)
    end
end

RegisterWithRavioliMenu()

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
local initialized = false

eventFrame:SetScript("OnUpdate", function(_, elapsed)
    if not initialized then return end
    CompletePendingInvites()
    local preciseNow = GetTime and GetTime() or time()

    if runtime.pendingPresenceResponseAt and preciseNow >= runtime.pendingPresenceResponseAt then
        runtime.pendingPresenceResponseAt = nil
        runtime.lastPresenceResponseAt = preciseNow
        QueueDirectAction(OPS.PRESENCE, { "R" })
    end
    if runtime.pendingRefreshBroadcastAt and preciseNow >= runtime.pendingRefreshBroadcastAt then
        runtime.pendingRefreshBroadcastAt = nil
        runtime.lastRefreshResponseAt = preciseNow
        QueueDirectAction(OPS.PRESENCE, { "R" })
        BroadcastAllListings()
    end

    runtime.elapsed = runtime.elapsed + elapsed
    runtime.heartbeatElapsed = runtime.heartbeatElapsed + elapsed
    runtime.channelRetryElapsed = runtime.channelRetryElapsed + elapsed
    if runtime.elapsed < 1 then return end
    runtime.elapsed = 0

    local serviceMode = ReadEbonholdGameMode()
    if serviceMode then ApplyDetectedGameMode(serviceMode) end
    UpdateRefreshButton()
    local selectedListing = FindListingByID(state.selectedID)
    if selectedListing and not IsOwnedListing(selectedListing)
        and runtime.requested[selectedListing.id] then
        UpdateDetails(selectedListing)
    end

    if (not ebon or not ebon:IsChannelJoined()) and runtime.channelRetryElapsed >= 5 then
        runtime.channelRetryElapsed = 0
        EnsureChannel()
    end

    RefreshGroupState()
    if runtime.heartbeatElapsed >= HEARTBEAT_SECONDS then
        runtime.heartbeatElapsed = 0
        EnsureChannel()
        if ebon and ebon:IsChannelJoined() then
            QueueDirectAction(OPS.PRESENCE, { "H" })
            BroadcastAllListings()
        end
        UpdateConnectionStatus()
    end

    local now = time()
    local changed = false
    for key, listing in pairs(runtime.remoteListings) do
        if (listing.lastSeen and now - listing.lastSeen > REMOTE_TIMEOUT_SECONDS)
            or (listing.expiresAt and listing.expiresAt > 0 and now >= listing.expiresAt) then
            runtime.remoteListings[key] = nil
            if state.selectedID == key then state.selectedID = nil end
            changed = true
        end
    end
    if changed then UpdateListings() end
end)

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon ~= addonName then
            if initialized then EnableQuestLogVisibilityLink() end
            return
        end

        if type(ZenActivityFinderDB) ~= "table" then ZenActivityFinderDB = {} end
        if type(ZenActivityFinderDB.listings) ~= "table" then ZenActivityFinderDB.listings = {} end
        if type(ZenActivityFinderDB.settings) ~= "table" then ZenActivityFinderDB.settings = {} end
        if type(ZenActivityFinderDB.interestedListings) ~= "table" then ZenActivityFinderDB.interestedListings = {} end
        ZenActivityFinderDB.unreadCount = math.max(0, tonumber(ZenActivityFinderDB.unreadCount) or 0)
        -- Ignore-list support was removed in 0.4.5; clear legacy saved entries.
        ZenActivityFinderDB.blocked = nil
        local legacyNotifyListings = ZenActivityFinderDB.settings.notifyListings
        for key, value in pairs(defaultSettings) do
            if ZenActivityFinderDB.settings[key] == nil then ZenActivityFinderDB.settings[key] = value end
        end
        if ZenActivityFinderDB.settings.engagementNotificationsInitialized == nil then
            ZenActivityFinderDB.settings.engagementNotificationsInitialized = true
            if NormalizeListingWatchCategory(ZenActivityFinderDB.settings.listingWatchCategory) == "OFF" then
                ZenActivityFinderDB.settings.listingWatchCategory = "ALL"
            end
        end
        if legacyNotifyListings ~= nil then
            ZenActivityFinderDB.settings.listingWatchCategory = legacyNotifyListings and "ALL" or "OFF"
            ZenActivityFinderDB.settings.notifyListings = nil
        end
        ZenActivityFinderDB.settings.listingWatchCategory = NormalizeListingWatchCategory(
            ZenActivityFinderDB.settings.listingWatchCategory)
        if ZenActivityFinderDB.settings.inviteFailureWhisper
                == "Sorry, I couldn't invite you because: {error}"
            or ZenActivityFinderDB.settings.inviteFailureWhisper
                == "Sorry, I couldn't invite you: your mode is {applicant_mode}, while this group is {group_mode}." then
            ZenActivityFinderDB.settings.inviteFailureWhisper = defaultSettings.inviteFailureWhisper
        end
        ZenActivityFinderDB.settings.expiryMinutes = NormalizeExpiryMinutes(ZenActivityFinderDB.settings.expiryMinutes)
        local maximumLocalExpiry = time() + (ZenActivityFinderDB.settings.expiryMinutes * 60)
        local activeListingFound = false
        for _, listing in ipairs(ZenActivityFinderDB.listings) do
            if listing.category == "PVP" then listing.category = "CUSTOM" end
            listing.roles = nil
            listing.isOwner = true
            listing.ownerGUID = listing.ownerGUID or (UnitGUID and UnitGUID("player"))
            listing.currentSize = listing.currentSize or GetCurrentGroupSize()
            listing.minimumLevel = nil
            listing.startTime = listing.startTime or "Now"
            listing.gameMode = NormalizeGameMode(listing.gameMode)
            listing.tags = nil
            if listing.category == "ORB" then
                listing.groupSize = 5
                listing.orbMode = tostring(listing.orbMode or "TOC"):upper()
                if listing.orbMode ~= "EVENT" then listing.orbMode = "TOC" end
                listing.orbEvent = tostring(listing.orbEvent or "")
                listing.orbNeed = NormalizeOrbNeedCode(listing.orbNeed or GetOrbNeedCode())
            else
                listing.orbMode, listing.orbEvent, listing.orbNeed = nil, nil, nil
            end
            listing.status = listing.status or "OPEN"
            if listing.status == "OPEN" or listing.status == "FULL" then
                if activeListingFound then
                    listing.status = "CLOSED"
                    listing.closedAt = listing.closedAt or listing.updatedAt or listing.createdAt or time()
                else
                    activeListingFound = true
                end
            end
            listing.autoClose = listing.autoClose == nil and ZenActivityFinderDB.settings.autoClose or listing.autoClose
            listing.autoInvite = listing.autoInvite == nil and ZenActivityFinderDB.settings.autoInvite or listing.autoInvite
            listing.expiresAt = tonumber(listing.expiresAt) or 0
            if listing.status ~= "EXPIRED"
                and (listing.expiresAt <= 0 or listing.expiresAt > maximumLocalExpiry) then
                listing.expiresAt = maximumLocalExpiry
            end
            if listing.status == "CLOSED" then
                listing.closedAt = tonumber(listing.closedAt) or listing.updatedAt or listing.createdAt or time()
            elseif listing.status == "EXPIRED" then
                listing.closedAt = tonumber(listing.closedAt)
                    or (listing.expiresAt > 0 and listing.expiresAt)
                    or listing.updatedAt or listing.createdAt or time()
            else
                listing.closedAt = nil
            end
        end
        ZenActivityFinderDB.nextID = tonumber(ZenActivityFinderDB.nextID) or 1
        if type(ZenActivityFinderDB.appearance) ~= "table" then
            ZenActivityFinderDB.appearance = UI.DefaultAppearance()
            ZenActivityFinderDB.appearance.mode = "GLOBAL"
        end
        UI:AttachSettings(ZenActivityFinderDB.appearance)

        BuildCreateFrame()
        BuildMainFrame()
        BuildSettingsFrame()
        BuildApplicantsFrame()
        BuildLauncherButton()
        ApplyZenAppearanceScale()
        EnableQuestLogVisibilityLink()
        RefreshLauncher()
        UpdateListings()

        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("PARTY_MEMBERS_CHANGED")
        self:RegisterEvent("RAID_ROSTER_UPDATE")
        self:RegisterEvent("UI_ERROR_MESSAGE")
        self:RegisterEvent("CHAT_MSG_SYSTEM")
        initialized = true
        StartEbonTransport()
        RequestEbonholdGameMode()
        local serviceMode = ReadEbonholdGameMode()
        if serviceMode then ApplyDetectedGameMode(serviceMode) end
        EnsureChannel()
        runtime.notificationReadyAt = (GetTime and GetTime() or 0) + 5
        RefreshNotificationPresentation()
    elseif not initialized then
        return
    elseif event == "PLAYER_ENTERING_WORLD" then
        EnableQuestLogVisibilityLink()
        RequestEbonholdGameMode()
        local serviceMode = ReadEbonholdGameMode()
        if serviceMode then ApplyDetectedGameMode(serviceMode) end
        EnsureChannel()
        if ebon and ebon:IsChannelJoined() then
            QueueDirectAction(OPS.PRESENCE, { "H" })
            QueueDirectAction(OPS.REFRESH)
        end
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        RefreshGroupState()
    elseif event == "UI_ERROR_MESSAGE" then
        local first, second = ...
        local message = type(second) == "string" and second or first
        HandleInviteFailureMessage(message, true)
    elseif event == "CHAT_MSG_SYSTEM" then
        HandleInviteFailureMessage((...), false)
    end
end)

SLASH_ZENACTIVITYFINDER1 = "/zaf"
SLASH_ZENACTIVITYFINDER2 = "/zenactivity"
SLASH_ZENACTIVITYFINDER3 = "/ravfinder"
SlashCmdList.ZENACTIVITYFINDER = function(message)
    local command = Trim(message):lower()
    if command == "reset" then
        ZenActivityFinderDB.position = nil
        ZenActivityFinderDB.launcherPosition = nil
        if mainFrame then
            mainFrame:ClearAllPoints()
            mainFrame:SetPoint("CENTER")
        end
        if launcherButton then
            launcherButton:ClearAllPoints()
            launcherButton:SetPoint("RIGHT", UIParent, "RIGHT", -24, 80)
        end
        Print("Window and launcher positions reset.")
    elseif command == "clear" then
        for _, listing in ipairs(ZenActivityFinderDB.listings) do BroadcastRemoval(listing.id) end
        ZenActivityFinderDB.listings = {}
        state.selectedID = nil
        state.page = 1
        UpdateListings()
        Print("Local listings cleared.")
    elseif command == "settings" then
        OpenSettingsFrame()
    elseif command == "orb" or command == "orbs" then
        OpenOrbFinder()
    elseif command == "orbhost" or command == "hostorb" then
        if ZenActivityFinder_CreateOrbListing({ source = "ZenActivityFinder" }) then
            OpenOrbFinder()
            Print("Orb Farm listing created or refreshed.")
        end
    elseif command == "appearance" or command == "style" then
        if not appearanceFrame then appearanceFrame = UI:CreateAppearancePanel(UIParent) end
        appearanceFrame:Show()
        if appearanceFrame.Raise then appearanceFrame:Raise() end
    elseif command == "notifications" or command == "notify" then
        ZenActivityFinderDB.settings.notifications = not ZenActivityFinderDB.settings.notifications
        if not ZenActivityFinderDB.settings.notifications then SetUnreadCount(0) end
        RefreshNotificationPresentation()
        Print("Activity notifications " .. (ZenActivityFinderDB.settings.notifications and "enabled." or "disabled."))
    elseif command == "channel" or command == "network" then
        EnsureChannel()
        local apiVersion = EbonAPI and EbonAPI.GetVersion and select(1, EbonAPI:GetVersion()) or "unknown"
        local connected = ebon and ebon:IsChannelJoined() or false
        Print("Version " .. VERSION .. "; EbonAPI " .. tostring(apiVersion) .. "; shared channel: "
            .. (connected and "connected" or "connecting") .. ".")
        Print("Detected ZenActivityFinder users: " .. GetActivePeerCount() .. ".")
        local remoteListingCount = 0
        for _ in pairs(runtime.remoteListings) do remoteListingCount = remoteListingCount + 1 end
        local activeLocalListings = 0
        for _, listing in ipairs(ZenActivityFinderDB.listings) do
            if listing.status == "OPEN" or listing.status == "FULL" then activeLocalListings = activeLocalListings + 1 end
        end
        Print("Listing sharing: " .. (ZenActivityFinderDB.settings.shareListings and "enabled" or "disabled")
            .. "; active local listings: " .. activeLocalListings
            .. "; remote listings: " .. remoteListingCount .. ".")
        Print("EbonAPI messages sent: " .. runtime.outboundMessagesSent
            .. "; listing broadcasts: " .. runtime.outboundListingPackets
            .. "; listings imported: " .. runtime.importedListingPackets .. ".")
        if runtime.lastTransportSender ~= "" then
            Print("Last ZenActivityFinder sender: " .. runtime.lastTransportSender .. ".")
        end
    elseif command == "lock" then
        ZenActivityFinderDB.settings.lockLauncher = not ZenActivityFinderDB.settings.lockLauncher
        RefreshLauncher()
        Print("Floating button " .. (ZenActivityFinderDB.settings.lockLauncher and "locked." or "unlocked."))
    elseif command == "help" then
        Print("/zaf - toggle the window")
        Print("/zaf reset - reset the window position")
        Print("/zaf clear - clear local listings")
        Print("/zaf settings - open settings")
        Print("/zaf orb - open the Orb Farms category")
        Print("/zaf orbhost - create or refresh your Orb Farm listing")
        Print("/zaf appearance - open Zen styling controls")
        Print("/zaf notifications - toggle all activity notifications")
        Print("/zaf network - show EbonAPI network status")
        Print("/zaf lock - lock or unlock the floating button")
    else
        ToggleMainFrame()
    end
end
