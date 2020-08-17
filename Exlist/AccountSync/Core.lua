local accountSync = Exlist.accountSync
local L = Exlist.L
local PREFIX = "Exlist_AS"

local MSG_TYPE = {
    ping = "PING",
    pingSuccess = "PING_SUCCESS",
    pairRequest = "PAIR_REQUEST",
    pairRequestSuccess = "PAIR_REQUEST_SUCCESS",
    pairRequestFailed = "PAIR_REQUEST_FAILED",
    syncAll = "SYNC_ALL",
    syncAllResp = "SYNC_ALL_RESP",
    sync = "SYNC",
    logout = "LOGOUT"
}

local PROGRESS_TYPE = {
    success = "SUCCESS",
    warning = "WARNING",
    error = "ERROR",
    info = "INFO"
}

local dbState

local CHAR_STATUS = {ONLINE = "Online", OFFLINE = "Offline"}

local function getPairedCharacters()
    return Exlist.ConfigDB.accountSync.pairedCharacters
end

local function getAccountId()
    local accInfo = C_BattleNet.GetGameAccountInfoByGUID(UnitGUID('player'))

    return accInfo.gameAccountID
end

local function getFormattedRealm(realm)
    realm = realm or GetRealmName()
    return realm:gsub("[%p%c%s]", "")
end

local function isCharacterPaired(name, realm)
    local paired = getPairedCharacters()
    return paired[name .. '-' .. getFormattedRealm(realm)]
end

local function setCharStatus(char, status, accountID)
    local characters = Exlist.ConfigDB.accountSync.pairedCharacters
    local _, realm = strsplit("-", char)
    if (not realm) then char = char .. "-" .. getFormattedRealm() end
    if (characters[char]) then
        characters[char].status = status
        characters[char].accountID = accountID or characters[char].accountID
    elseif char and status and accountID then
        characters[char] = {status = status, accountID = accountID}
    end
end

--[[
----------------- DB Data -------------------
]]
local function getFilteredDB()
    local db = Exlist.copyTable(Exlist.DB)
    local paired = getPairedCharacters()

    -- Filter out all other account characters
    for dbRealm, realmData in pairs(db) do
        for dbChar in pairs(realmData) do
            for char in pairs(paired) do
                local name, realm = strsplit('-', char)
                if (name == dbChar and getFormattedRealm(dbRealm) == realm) then
                    db[dbRealm][dbChar] = nil
                    break
                end
            end
        end
    end

    db.global = nil
    return db
end

local function validateChanges(data)
    -- TODO: find something to validate against
    -- for _, realmData in pairs(data) do
    --     if realmData then
    --         for _, char in pairs(realmData) do
    --             if not char.character then
    --                 printProgress(PROGRESS_TYPE.error, "Invalid Table")
    --                 return
    --             end
    --         end
    --     end
    -- end
    return true
end

local function setInitialDBState()
    local db = getFilteredDB()
    dbState = db
end

local function getDbChanges()
    local filteredDb = getFilteredDB()
    local changeDb = Exlist.diffTable(dbState, filteredDb)
    dbState = filteredDb
    return changeDb
end

local function addMissingPairCharacters(changes, accountID)
    local paired = getPairedCharacters()
    for realm, realmData in pairs(changes) do
        for char in pairs(realmData) do
            local name = string.format("%s-%s", char, getFormattedRealm(realm))
            if (not paired[name]) then
                setCharStatus(name, CHAR_STATUS.OFFLINE, accountID)
            end
        end
    end
end

-- Changes follow same data structure as Exlist.DB
local function mergeInChanges(changes, accountID)
    if (validateChanges(changes)) then
        addMissingPairCharacters(changes, accountID)
        Exlist.tableMerge(Exlist.DB, changes)
        Exlist.AddMissingCharactersToSettings()
        Exlist.ConfigDB.settings.reorder = true
    end
end

--[[
----------------- COMMUNICATION -------------------
]]
local callbacks = {}

local LibDeflate = LibStub:GetLibrary("LibDeflate")
local LibSerialize = LibStub("LibSerialize")
local AceComm = LibStub:GetLibrary("AceComm-3.0")
local configForDeflate = {level = 9}
local configForLS = {errorOnUnserializableType = false}

local function getOnlineCharacters()
    local characters = getPairedCharacters()

    local onlineChar = {}
    for char, info in pairs(characters) do
        if (info.status == CHAR_STATUS.ONLINE) then
            table.insert(onlineChar, char)
        end
    end
    return onlineChar
end

local function mergePairedCharacters(accountChars, accountID)
    local paired = Exlist.ConfigDB.accountSync.pairedCharacters
    for _, char in ipairs(accountChars) do
        paired[char] = {status = CHAR_STATUS.OFFLINE, accountID = accountID}
    end
    Exlist.accountSync.AddOptions(true)
end

local function gatherAccountCharacterNames()
    local accountCharacters = {}
    local realms = Exlist.GetRealmNames()
    for _, realm in ipairs(realms) do
        local characters = Exlist.GetRealmCharacters(realm)
        for _, char in ipairs(characters) do
            if (not isCharacterPaired(char, realm)) then

                table.insert(accountCharacters, string.format("%s-%s", char,
                                                              getFormattedRealm(
                                                                  realm)))
            end
        end
    end

    return accountCharacters
end

local function dataToString(data)
    local serialized = LibSerialize:SerializeEx(configForLS, data)
    local compressed = LibDeflate:CompressDeflate(serialized, configForDeflate)
    return LibDeflate:EncodeForWoWAddonChannel(compressed)
end

local function stringToData(payload)
    local decoded = LibDeflate:DecodeForWoWAddonChannel(payload)
    if not decoded then return end
    local decrompressed = LibDeflate:DecompressDeflate(decoded)
    if not decrompressed then return end
    local success, data = LibSerialize:Deserialize(decrompressed)
    if not success then return end

    return data
end

local function printProgress(type, message)
    local color = "ffffff";
    if (type == PROGRESS_TYPE.success) then
        color = "00ff00"
    elseif (type == PROGRESS_TYPE.warning) then
        color = "fcbe03"
    elseif (type == PROGRESS_TYPE.error) then
        color = "ff0000"
    end

    print(string.format("|cff%s%s", color, message))
end

local function displayDataSentProgress(_, done, total)
    local color = "ff0000"
    local perc = (done / total) * 100
    if (perc > 80) then
        color = "00ff00"
    elseif (perc > 40) then
        color = "fcbe03"
    end
    return print(string.format("Exlist Sync: |cff%s %.1f%% ( %s / %s )", color,
                               perc, done, total))
end

local function sendMessage(data, distribution, target, prio, callbackFn)
    if not Exlist.ConfigDB.accountSync.enabled then return end
    data.rqTime = GetTime()
    data.userKey = Exlist.ConfigDB.accountSync.userKey
    data.accountID = getAccountId()

    AceComm:SendCommMessage(PREFIX, dataToString(data), distribution, target,
                            prio, callbackFn)

    return data.rqTime
end

local function pingCharacter(characterName, callbackFn)
    local rqTime = sendMessage({
        type = MSG_TYPE.ping,
        key = Exlist.ConfigDB.accountSync.userKey
    }, "WHISPER", characterName);
    if (callbackFn) then callbacks[rqTime] = callbackFn end
end

local function showPairRequestPopup(characterName, callbackFn)
    StaticPopupDialogs["Exlist_PairingPopup"] =
        {
            text = string.format(L["%s is requesting pairing Exlist DBs."],
                                 characterName),
            button1 = "Accept",
            button3 = "Cancel",
            hasEditBox = false,
            OnAccept = function() callbackFn(true) end,
            OnCancel = function() callbackFn(false) end,
            timeout = 0,
            cancels = "Exlist_PairingPopup",
            whileDead = true,
            hideOnEscape = 1,
            preferredIndex = 4,
            showAlert = 1,
            enterClicksFirstButton = 1
        }
    StaticPopup_Show("Exlist_PairingPopup")
end

-- Does account have any online characters
local accountStatus = {}
local loginDataSent = {}
local function pingAccountCharacters(accountID)
    local characters = Exlist.ConfigDB.accountSync.pairedCharacters
    local online = false
    local i = 1
    for char, info in pairs(characters) do
        local char = char
        if (info.accountID == accountID) then
            local found = false
            C_Timer.After(i * 0.1, function()
                pingCharacter(char, function()
                    found = true
                    characters[char].status = CHAR_STATUS.ONLINE
                    online = true
                    if not loginDataSent[char] then
                        accountSync.syncCompleteData(char)
                        loginDataSent[char] = true
                    end
                end)
            end)
            C_Timer.After(5, function()
                if (not found) then
                    characters[char].status = CHAR_STATUS.OFFLINE
                end
            end)
            i = i + 1
        end
    end
    C_Timer.After(10, function() accountStatus[accountID] = online end)
end

local function validateRequest(data)
    return data.userKey == Exlist.ConfigDB.accountSync.userKey
end

--[[
    ---------------------- MSG RECEIVE -------------------------------
]]
local function messageReceive(prefix, message, distribution, sender)
    if not Exlist.ConfigDB.accountSync.enabled then return end
    local userKey = Exlist.ConfigDB.accountSync.userKey
    local data = stringToData(message)
    if not data then return end
    local msgType = data.type
    print("Msg Received ", msgType, sender)
    Exlist.Switch(msgType, {
        [MSG_TYPE.ping] = function()
            if (validateRequest(data)) then
                sendMessage(
                    {type = MSG_TYPE.pingSuccess, resTime = data.rqTime},
                    distribution, sender)
                setCharStatus(sender, CHAR_STATUS.ONLINE, data.accountID)
            end
        end,
        [MSG_TYPE.pingSuccess] = function()
            local cb = callbacks[data.resTime]
            if (cb) then
                cb(data)
                cb = nil
            end
        end,
        [MSG_TYPE.pairRequest] = function()
            showPairRequestPopup(sender, function(success)
                if success then
                    Exlist.ConfigDB.accountSync.userKey = data.userKey
                    sendMessage({
                        type = MSG_TYPE.pairRequestSuccess,
                        accountCharacters = gatherAccountCharacterNames(),
                        accountID = getAccountId()
                    }, distribution, sender)
                    mergePairedCharacters(data.accountCharacters, data.accountID)
                    pingAccountCharacters(data.accountID)
                else
                    sendMessage({
                        type = MSG_TYPE.pairRequestFailed,
                        userKey = userKey
                    }, distribution, sender)
                end
            end)
        end,
        [MSG_TYPE.pairRequestSuccess] = function()
            if validateRequest(data) then
                printProgress(PROGRESS_TYPE.success,
                              L["Pair request has been successful"])
                mergePairedCharacters(data.accountCharacters, data.accountID)
                pingAccountCharacters(data.accountID)
            end
        end,
        [MSG_TYPE.pairRequestFailed] = function()
            if (validateRequest(data)) then
                printProgress(PROGRESS_TYPE.error,
                              L["Pair request has been cancelled"])
            end
        end,
        [MSG_TYPE.syncAll] = function()
            if (validateRequest(data)) then
                if (data.changes) then
                    mergeInChanges(data.changes, data.accountID)
                    accountSync.syncCompleteData(sender, true)
                end
            end
        end,
        [MSG_TYPE.sync] = function()
            if (validateRequest(data)) then
                if (data.changes) then
                    mergeInChanges(data.changes, data.accountID)
                end
            end
        end,
        [MSG_TYPE.syncAllResp] = function()
            if (validateRequest(data)) then
                if (data.changes) then
                    mergeInChanges(data.changes, data.accountID)
                end
            end
        end,
        default = function()
            -- Do Nothing for now
        end
    })
end
AceComm:RegisterComm(PREFIX, messageReceive)

function accountSync.pairAccount(characterName, userKey)
    sendMessage({
        type = MSG_TYPE.pairRequest,
        userKey = userKey,
        accountCharacters = gatherAccountCharacterNames(),
        accountID = getAccountId()
    }, "WHISPER", characterName)
end

function accountSync.syncCompleteData(characterName, response)
    local myData = getFilteredDB()
    local type = response and MSG_TYPE.syncAllResp or MSG_TYPE.syncAll
    sendMessage({type = type, changes = myData}, "WHISPER", characterName,
                "BULK", displayDataSentProgress)
end

function accountSync.pingEveryone()
    local characters = getPairedCharacters()
    local pingedAccounts = {}
    local i = 1
    for _, info in pairs(characters) do
        if (not pingedAccounts[info.accountID]) then
            C_Timer.After(0.5 * i,
                          function()
                pingAccountCharacters(info.accountID)
            end)
            pingedAccounts[info.accountID] = true
            i = i + 1
        end
    end
end

local PING_INTERVAL = 60 * 60 * 3 -- Every 3 minutes

accountSync.coreInit = function()
    setInitialDBState()
    accountSync.pingEveryone()
    C_Timer.NewTicker(PING_INTERVAL, function()
        local characters = getOnlineCharacters()
        local i = 1
        for _, char in ipairs(characters) do
            local char = char
            local online = false
            C_Timer.After(i * 0.1, function()
                pingCharacter(char, function()
                    local changes = getDbChanges()
                    if (changes) then
                        sendMessage({type = MSG_TYPE.sync, changes = changes},
                                    "WHISPER", char, "BULK",
                                    displayDataSentProgress)
                    end
                    online = true
                end)
            end)

            C_Timer.After(5, function()
                if not online then
                    setCharStatus(char, CHAR_STATUS.OFFLINE)
                end
            end)
            i = i + 1
        end
    end)
end
