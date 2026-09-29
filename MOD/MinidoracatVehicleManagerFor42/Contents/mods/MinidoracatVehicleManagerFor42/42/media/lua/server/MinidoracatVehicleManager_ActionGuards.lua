-- Server 端動作防護（計畫 §8.0–§8.2、Phase 2）：
--   1. 原版 timed action 的 server lifecycle 包裝：第一個突變前 canUse，拒絕就不呼叫原函式並推回權威狀態
--   2. actor intent（§8.1.3）：NetTimedAction 的 character 可被冒充，受保護車的動作要求該連線先送過 prepareAction
--   3. 虛擬鑰匙三個 adapter（發動／解鎖／開門免警報，Phase 0 gate 15 實證）
--   4. AutoDrive 裝置槽唯一突變點 MDAD.applyDeviceChange（Phase 0 gate 25 實證）
--   5. 佔座 watchdog 與拖掛對帳（事後偵測，D 級）
-- 未受保護的車（無紀錄）一律照原版走，不要求 intent。
if isClient() then return end
require "MinidoracatVehicleManager_API"
require "MinidoracatVehicleManager_Actions"
require "MinidoracatVehicleManager_OwnershipSystem"
require "MinidoracatVehicleManager_Server"
for _, path in ipairs({ "ISInstallVehiclePart", "ISUninstallVehiclePart", "ISRepairEngine", "ISRepairLightbar",
    "ISTakeEngineParts", "ISAddGasolineToVehicle", "ISTakeGasolineFromVehicle", "ISRefuelFromGasPump", "ISDeflateTire",
    "ISInflateTire", "ISHotwireVehicle", "ISRemoveBurntVehicle", "ISStartVehicleEngine", "ISShutOffVehicleEngine", "ISLockDoors",
    "ISLockVehicleDoor", "ISUnlockVehicleDoor", "ISOpenVehicleDoor", "ISCloseVehicleDoor", "ISOpenCloseVehicleWindow", "ISSmashVehicleWindow" }) do
    require("Vehicles/TimedActions/" .. path)
end
require "TimedActions/ISFixVehiclePartAction"
require "TimedActions/ISSmashWindow"
require "TimedActions/Animals/ISAddAnimalInTrailer"
require "TimedActions/Animals/ISRemoveAnimalFromTrailer"

local MVM = MinidoracatVehicleManager
local O, S = MVM.Own, MVM.Srv
local G = {}
MVM.Guards = G

local INTENT_TTL_MS = 180000 -- 排入佇列到 server 執行：走位＋動作時間
local INTENTS_PER_ACTOR = 16
local WATCHDOG_BATCH = 10

local R = { intents = {}, wrapped = {}, marks = {}, due = {}, rewraps = 0, lastRun = 0 }
G.R = R

local function now() return getTimestampMs() end

-- ------------------------------------------------------------------ intent ---
-- 連線身分由 OnClientCommand 的 player 決定（GameServer 以 connection 反查），client 不能替別人送
function G.onIntent(player, who, a)
    local v = getVehicleById(a.vehicleId)
    if v == nil then return end
    local list = R.intents[who]
    if list == nil then list = {}; R.intents[who] = list end
    local t = now()
    for i = #list, 1, -1 do if list[i].exp < t then table.remove(list, i) end end
    if #list >= INTENTS_PER_ACTOR then table.remove(list, 1) end
    list[#list + 1] = { cls = a.class, sqlId = v:getSqlId(), partId = a.partId, exp = t + INTENT_TTL_MS }
end

local function takeIntent(who, cls, vehicle, part)
    local list = R.intents[who]
    if list == nil then return false end
    local t, sqlId, partId = now(), vehicle:getSqlId(), part and part:getId() or nil
    for i, it in ipairs(list) do
        if it.exp >= t and it.cls == cls and it.sqlId == sqlId and (partId == nil or it.partId == partId) then
            table.remove(list, i)
            return true
        end
    end
    return false
end

-- ------------------------------------------------------------------ pushback ---
local function pushback(spec, a, vehicle, part)
    if vehicle == nil then return end
    for _, kind in ipairs(spec.push or {}) do
        if part and kind == "item" then vehicle:transmitPartItem(part)
        elseif part and kind == "condition" then vehicle:transmitPartCondition(part)
        elseif part and kind == "moddata" then vehicle:transmitPartModData(part)
        elseif part and kind == "door" then vehicle:transmitPartDoor(part)
        elseif part and kind == "window" then vehicle:transmitPartWindow(part)
        elseif kind == "can" and a.item and a.item.syncItemFields then a.item:syncItemFields()
        elseif kind == "alldoors" then
            for i = 0, vehicle:getPartCount() - 1 do
                local p = vehicle:getPartByIndex(i)
                if p and p:getDoor() then vehicle:transmitPartDoor(p) end
            end
        end
    end
end

local function enforce(player, action, reason, oid)
    if player and instanceof(player, "IsoPlayer") then
        S.send(player, "enforcement", { action = action, reason = reason, oid = oid })
    end
end

local function canUseAny(actor, vehicle, actions, context)
    local ok, reason, rec
    for _, act in ipairs(actions) do
        ok, reason, rec = O.canUse(actor, vehicle, act, context)
        if ok then return true, reason, rec, act end
    end
    return false, reason, rec, actions[1]
end

-- 每個突變 stage 都重新判定目前的目標與權限（中途撤權、轉讓、剛被綁定都要擋）；
-- 只有 intent 的消費記在 action 實例上（一個動作只消費一次，雙層包裝也一樣）。一旦拒絕就整個動作都拒絕。
function G.decide(spec, a)
    if a._mvmAllow == false then return false end
    local allow, rec, reason, act = true, nil, nil, nil
    local vehicle = spec.vehicleOf(a)
    local part = spec.partOf and spec.partOf(a) or nil
    if vehicle ~= nil and O.state() ~= nil then
        if part ~= nil and part:getVehicle() ~= vehicle then
            allow, reason = false, "TARGET_MISMATCH"
        elseif a.vehicle ~= nil and a.vehicle ~= vehicle then
            allow, reason = false, "TARGET_MISMATCH" -- action 自帶的 vehicle 與實際目標不一致
        else
            local ok
            ok, reason, rec, act = canUseAny(a.character, vehicle, MVM.requiredActions(spec, a),
                { part = part, op = spec.class, silent = a._mvmIntent == true })
            if rec == nil then
                allow = true
            elseif not ok then
                allow = false
            elseif isServer() and not a._mvmIntent then
                if takeIntent(O.principal(a.character), spec.class, vehicle, part) then
                    a._mvmIntent = true
                else
                    allow, reason = false, "ACTOR_MISMATCH"
                    O.audit("WARN", "ACTOR_MISMATCH", { actor = O.principal(a.character), oid = rec.oid, owner = rec.ownerUser,
                        reason = spec.class })
                end
            end
        end
    end
    a._mvmRec, a._mvmReason, a._mvmAct = rec, reason, act
    if not allow then
        a._mvmAllow = false
        pushback(spec, a, vehicle, part)
        if not a._mvmNotified then
            a._mvmNotified = true
            enforce(a.character, spec.class, reason or "NOT_AUTHORIZED", rec and rec.oid)
        end
    end
    return allow
end

-- ------------------------------------------------------------------ wrapping ---
-- 特別處理：虛擬鑰匙三個 adapter（只對受保護且已授權的車）
local function virtualKey(a) return MVM.sandbox("VirtualKey", true) and a._mvmRec ~= nil end

local SPECIAL = {
    ISStartVehicleEngine = { complete = function(a, orig)
        local v = a.character:getVehicle()
        if virtualKey(a) and v and v:isDriver(a.character) then
            v:tryStartEngine(true) -- ACL DRIVE 取代實體鑰匙（BaseVehicle.java:7509-7535）
            return true
        end
        return orig(a)
    end },
    ISUnlockVehicleDoor = { complete = function(a, orig)
        local door = a.part and a.part:getDoor()
        if virtualKey(a) and door then
            door:setLocked(false) -- 權威解鎖，不經 canUnlockDoor 的鑰匙檢查
            a.part:getVehicle():transmitPartDoor(a.part)
            return true
        end
        return orig(a)
    end },
    ISOpenVehicleDoor = { complete = function(a, orig)
        if virtualKey(a) and a.part then a.part:getVehicle():setPreviouslyEntered(true) end -- 授權者開門不觸發警報
        return orig(a)
    end },
}

local function makeWrapper(spec, stage, orig)
    local special = SPECIAL[spec.class] and SPECIAL[spec.class][stage]
    return function(a, ...)
        if not G.decide(spec, a) then
            if stage == "complete" then return false end
            return
        end
        if special then return special(a, orig) end
        return orig(a, ...)
    end
end

local function wrapUpdate(spec, orig)
    return function(a, ...)
        -- update 在 client 也會跑（本機預覽）；權威端每次都重驗，撤權後停止扣油／加油
        if isClient() or G.decide(spec, a) then return orig(a, ...) end
    end
end

-- 冪等：目前方法若已是本 MOD 的 wrapper 就不動；被後載 MOD 換掉就重包並稽核
function G.install(reason)
    for _, spec in ipairs(MVM.ADAPTERS) do
        local cls = _G[spec.class]
        if type(cls) == "table" then
            for _, stage in ipairs(spec.stages) do
                local cur = cls[stage]
                if type(cur) == "function" and not R.marks[cur] then
                    local w = stage == "update" and wrapUpdate(spec, cur) or makeWrapper(spec, stage, cur)
                    R.marks[w] = true
                    cls[stage] = w
                    local key = spec.class .. "." .. stage
                    if R.wrapped[key] then
                        R.rewraps = R.rewraps + 1
                        O.audit("WARN", "ADAPTER_REWRAPPED", { reason = key })
                    end
                    R.wrapped[key] = true
                end
            end
        end
    end
    G.wrapAutoDrive()
    if reason ~= "recheck" then MVM.log("action guards installed (" .. tostring(reason) .. ")") end
end

-- ------------------------------------------------------------------ AutoDrive ---
-- AutoDrive 把原版面板的裝置槽動作改派成 Device 命令，最後都到 applyDeviceChange（Phase 0 gate 25）。
-- actor 已是連線身分，不需 intent。安裝＝REPAIR、卸除＝SALVAGE。
function G.wrapAutoDrive()
    if type(MDAD) ~= "table" or type(MDAD.applyDeviceChange) ~= "function" or R.marks[MDAD.applyDeviceChange] then return end
    local orig = MDAD.applyDeviceChange
    local w = function(player, vehicle, kind, install, itemId)
        if vehicle ~= nil and O.state() ~= nil and type(MDAD.getDevicePart) == "function" then
            local part = MDAD.getDevicePart(vehicle, kind)
            local ok, reason, rec = O.canUse(player, vehicle, install == true and "REPAIR" or "SALVAGE",
                { part = part, op = install == true and "install" or "uninstall", mod = "MinidoracatAutoDrive" })
            if rec ~= nil and not ok then
                if part then vehicle:transmitPartItem(part) end
                enforce(player, "MDADDevice", reason, rec.oid)
                return false, MDAD.FAIL_GENERIC or "UI_MinidoracatAutoDrive_InstallFailed"
            end
        end
        return orig(player, vehicle, kind, install, itemId)
    end
    R.marks[w] = true
    if R.wrapped["MDAD.applyDeviceChange"] then O.audit("WARN", "ADAPTER_REWRAPPED", { reason = "MDAD.applyDeviceChange" }) end
    R.wrapped["MDAD.applyDeviceChange"] = true
    MDAD.applyDeviceChange = w
end

-- dedicated：所有 MOD 的 server Lua 載完後才有 OnServerStarted；SP：進遊戲才載入 server Lua
if Events.OnServerStarted then Events.OnServerStarted.Add(function() G.install("OnServerStarted") end) end
Events.OnGameStart.Add(function() if not isServer() then G.install("OnGameStart") end end)
Events.EveryOneMinute.Add(function() G.install("recheck") end)

-- ------------------------------------------------------------------ watchdog ---
-- 每位在線玩家各自到期（不用全域 tick 取模，Phase 0 gate 11），每 tick 最多查 WATCHDOG_BATCH 人
local function occupantCheck(player)
    local v = player:getVehicle()
    if v == nil then return end
    local seat = v:getSeat(player)
    local ok, reason, rec = O.canUse(player, v, seat == 0 and "DRIVE" or "PASSENGER", { silent = true })
    if rec ~= nil and not ok then
        O.deny(O.principal(player), "OCCUPANCY", rec.oid, "DENY_OCCUPANCY")
        enforce(player, "OCCUPANCY", reason, rec.oid)
        if MVM.sandbox("WatchdogAction", 1) >= 2 then
            -- 原版 permanentlyRemove 的順序：先 S2C 讓 client 下車，再 server exit（Phase 0 gate 9）
            player:sendObjectChange(IsoObjectChange.EXIT_VEHICLE)
            v:exit(player)
            O.audit("WARN", "EJECT_REQUEST", { actor = O.principal(player), oid = rec.oid, owner = rec.ownerUser })
        end
        return
    end
    -- 拖掛對帳：駕駛拖著受保護車卻沒有 TOW → 解除（事後處置，同原版 detachTrailer）
    local towed = seat == 0 and v:getVehicleTowing() or nil
    if towed ~= nil then
        local tok, _, trec = O.canUse(player, towed, "TOW", { silent = true })
        if trec ~= nil and not tok then
            v:breakConstraint(true, false)
            O.audit("WARN", "DENY", { actor = O.principal(player), role = "TOW", oid = trec.oid, owner = trec.ownerUser,
                reason = "TOW_DETACHED" })
            enforce(player, "TOW", "NOT_AUTHORIZED", trec.oid)
        end
    end
end

function G.watchdog()
    -- 重啟後可能還沒有任何命令觸發載入判定：由 watchdog 自己觸發，否則沒人操作前完全不巡查
    if O.state() == nil then return end
    local t = now()
    if t - R.lastRun < 100 then return end
    -- 觸發載入判定；RECOVERY_REQUIRED 時帳本不可寫，但仍以記憶體帳本唯讀執法（lookup 的唯讀分支）
    O.ready()
    R.lastRun = t
    local interval = MVM.sandbox("WatchdogIntervalSeconds", 1) * 1000
    local online = S.online()
    local checked = 0
    for who, player in pairs(online) do
        local due = R.due[who]
        if due == nil then due = t; R.due[who] = t end
        if due <= t and checked < WATCHDOG_BATCH then
            checked = checked + 1
            R.due[who] = t + interval
            occupantCheck(player)
        end
    end
    for who in pairs(R.due) do if online[who] == nil then R.due[who] = nil end end
end

Events.OnTick.Add(G.watchdog)
