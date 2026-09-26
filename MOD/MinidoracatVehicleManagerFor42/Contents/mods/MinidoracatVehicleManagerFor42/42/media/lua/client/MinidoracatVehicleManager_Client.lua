-- Client：只表達意圖、快取自己收到的投影（§6.2）。沒有 ledger，UI 狀態一律等 server ACK／delta。
-- v1 只支援本機第一位玩家（計畫 §21 gate 16 關閉）：其他 slot 不顯示選單、不送命令。
require "MinidoracatVehicleManager_API"
require "TimedActions/ISBaseTimedAction"

local MVM = MinidoracatVehicleManager
local C = { buckets = {}, pending = {}, protocolMismatch = false }
MVM.Client = C

-- 框架（MinidoracatUIFor42）的 facade；mod.info require= 保證存在，版本與能力逐項探測
local function ui()
    if not (MinidoracatUI and MinidoracatUI.v1) then pcall(require, "MinidoracatUI/V1") end
    local UI = MinidoracatUI and MinidoracatUI.v1
    if UI and UI.API_MAJOR == 1 then return UI end
    return nil
end
MVM.ui = ui

-- 玩家通知走框架 Toast；只有能力缺席（離線 harness、舊框架）才退回原版頭頂文字
local toastColors = nil
function MVM.notify(player, text, bad)
    local UI = ui()
    if UI and UI.CAPABILITIES.toast and UI.Toast then
        if toastColors == nil then
            local c = UI.Theme.create().colors
            toastColors = { good = { border = c.accent, text = c.text }, bad = { border = c.errorText, text = c.text } }
        end
        UI.Toast.show({ message = text, colors = bad and toastColors.bad or toastColors.good, maxLines = 3 })
    elseif player then
        if bad then HaloTextHelper.addBadText(player, text) else HaloTextHelper.addGoodText(player, text) end
    end
end

local WITNESS_KEY = "MinidoracatVehicleManager"

local function principal(playerNum)
    local p = getSpecificPlayer(playerNum)
    if p == nil then return nil end
    if isClient() then return p:getUsername() end
    return "local:" .. tostring(playerNum)
end

local function bucket(who)
    local b = C.buckets[who]
    if b == nil then b = { rows = {} }; C.buckets[who] = b end
    return b
end

function C.request(player, command, args, onAck)
    if C.protocolMismatch then
        MVM.notify(player, getText("IGUI_MVM_ProtocolMismatch"), true)
        return
    end
    args = args or {}
    args.protocol = MVM.PROTOCOL
    if command ~= "fleetSubscribe" and command ~= "fleetResync" then
        args.requestId = getRandomUUID()
        C.pending[args.requestId] = onAck or true
    end
    sendClientCommand(player, MVM.MODULE, command, args)
end

local function resync(who)
    local p = getSpecificPlayer(0)
    if p and principal(0) == who then C.request(p, "fleetResync", {}) end
end

-- server → client（MP 經 OnServerCommand；SP 由 server adapter 直接呼叫）
function MVM.clientReceive(command, payload)
    if type(payload) ~= "table" or type(payload.to) ~= "string" then return end
    local b = bucket(payload.to)
    if command == "fleetSnapshot" then
        b.streamId, b.seq, b.rows, b.track = payload.streamId, payload.seq, {}, {}
        for _, row in ipairs(payload.rows or {}) do b.rows[row.oid] = row end
        b.quotaUsed, b.quotaLimit, b.status = payload.quotaUsed, payload.quotaLimit, payload.status
    elseif command == "fleetDelta" then
        -- 跳號或換 stream：丟棄並要求完整快照（keyed replace，不 append）
        if b.streamId ~= payload.streamId or payload.seq ~= (b.seq or -1) + 1 then return resync(payload.to) end
        b.seq = payload.seq
        for _, oid in ipairs(payload.removes or {}) do b.rows[oid] = nil end
        for _, row in ipairs(payload.upserts or {}) do b.rows[row.oid] = row end
    elseif command == "mutationAck" then
        if payload.reason == "PROTOCOL_MISMATCH" then C.protocolMismatch = true end
        local cb = C.pending[payload.requestId]
        C.pending[payload.requestId] = nil
        if type(cb) == "function" then cb(payload) end
        local p = getSpecificPlayer(0)
        if p and not payload.ok and principal(0) == payload.to then
            MVM.notify(p, getText("IGUI_MVM_Failed", tostring(payload.reason)), true)
        end
        MVM.log("ack " .. tostring(payload.requestKind) .. " ok=" .. tostring(payload.ok) .. " reason=" .. tostring(payload.reason))
    elseif command == "trackDelta" then
        -- 即時位置只存最新值；是否顯示仍以列的 TRACK 權限為準（撤權後列消失，位置自然不再用）
        if type(payload.oid) ~= "string" then return end
        b.track = b.track or {}
        b.track[payload.oid] = { x = payload.x, y = payload.y, z = payload.z, t = payload.t }
    elseif command == "adminSnapshot" then
        b.admin = payload.ok and payload.rows or nil
    elseif MVM.clientHandlers and MVM.clientHandlers[command] then
        MVM.clientHandlers[command](payload)
    end
    b.rev = (b.rev or 0) + 1
    if MVM.onFleetChanged and command ~= "trackDelta" then MVM.onFleetChanged(payload.to, command, payload) end
end

Events.OnServerCommand.Add(function(module, command, args)
    if module == MVM.MODULE then MVM.clientReceive(command, args) end
end)

-- 車上的零件見證只給 oid，用來對到自己的投影列；他人的車只知道「已被綁定」。
-- 宿主可能是任一零件（server 找不到 Engine 等時用第 0 個），選單開啟時掃一次（≤128 個）
local function witnessOid(vehicle)
    for i = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(i)
        if part and part:hasModData() then
            local w = rawget(part:getModData(), WITNESS_KEY)
            if type(w) == "table" and type(w.oid) == "string" then return w.oid end
        end
    end
    return nil
end

function MVM.clientProjection(playerNum, vehicle)
    local who = principal(playerNum)
    if who == nil or vehicle == nil then return nil end
    local oid = witnessOid(vehicle)
    if oid == nil then return nil end
    local row = bucket(who).rows[oid]
    return row or { oid = oid, role = "OTHER" }
end

function MVM.clientCanUse(actor, vehicle, action)
    local row = MVM.clientProjection(actor:getPlayerNum(), vehicle)
    if row == nil then return true, "UNCLAIMED" end
    if row.role == "OWNER" then return true, "OWNER" end
    if action ~= "MANAGE" and row.myBits and MVM.bitsAllow(row.myBits, action) then return true, row.role end
    return false, "NOT_AUTHORIZED"
end

-- --------------------------------------------------------- claim action ---
MVMClaimAction = ISBaseTimedAction:derive("MVMClaimAction")

function MVMClaimAction:isValid()
    return self.vehicle ~= nil and not self.vehicle:isRemovedFromWorld() and self.character:getVehicle() == nil
end

function MVMClaimAction:update() self.character:faceThisObject(self.vehicle) end
function MVMClaimAction:start() self:setActionAnim("VehicleWorkOnMid") end

function MVMClaimAction:perform()
    C.request(self.character, "claim", { claimAttemptId = self.attemptId }, function(ack)
        if ack.ok then MVM.notify(self.character, getText("IGUI_MVM_Claimed")) end
    end)
    ISBaseTimedAction.perform(self)
end

function MVMClaimAction:new(character, vehicle, attemptId)
    local o = ISBaseTimedAction.new(self, character)
    o.vehicle, o.attemptId, o.maxTime = vehicle, attemptId, 100
    return o
end

function C.claim(player, vehicle)
    C.request(player, "prepareClaim", { vehicleId = vehicle:getId() }, function(ack)
        if not ack.ok then return end
        ISTimedActionQueue.add(MVMClaimAction:new(player, vehicle, ack.claimAttemptId))
    end)
end

-- 綁定前先揭露保護邊界（武器、殭屍、碰撞傷害無法完全阻止），確認後才送 prepareClaim（框架 Dialog）
local function startClaim(player, vehicle)
    local UI = ui()
    if not (UI and UI.API_REVISION >= 7 and UI.CAPABILITIES.dialog) then
        MVM.notify(player, getText("IGUI_MVM_NeedFramework"), true)
        return
    end
    UI.Dialog.show({ title = getText("ContextMenu_MVM_Menu"), text = getText("IGUI_MVM_ClaimDisclosure"), width = 480,
        confirmText = getText("ContextMenu_MVM_Claim"), cancelText = getText("UI_Cancel"),
        onResult = function(ok) if ok then C.claim(player, vehicle) end end })
end

local function unclaim(player, vehicle, row)
    C.request(player, "unclaim", { vehicleId = vehicle:getId(), expectedOid = row.oid, expectedEpoch = row.epoch }, function(ack)
        if ack.ok then MVM.notify(player, getText("IGUI_MVM_Unclaimed")) end
    end)
end

local function reissue(player, vehicle, row)
    C.request(player, "reissueWitness", { vehicleId = vehicle:getId(), expectedOid = row.oid })
end

-- 原版車外選單之後附加一個子選單（ISVehicleMenu.lua:594）
local fillOutside = ISVehicleMenu.FillMenuOutsideVehicle
function ISVehicleMenu.FillMenuOutsideVehicle(playerNum, context, vehicle, test)
    local result = fillOutside(playerNum, context, vehicle, test)
    if test or playerNum ~= 0 or vehicle == nil then return result end
    local player = getSpecificPlayer(playerNum)
    local option = context:addOption(getText("ContextMenu_MVM_Menu"), nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    local row = MVM.clientProjection(playerNum, vehicle)
    if row == nil or row.role == "OTHER" then
        -- 見證不見或對錯時，自己的 WITNESS_STALE 車看起來會像未綁定／別人的：提供重新核發，由 server 以 native 欄位驗證
        for _, r in pairs(bucket(principal(playerNum) or "").rows) do
            if r.role == "OWNER" and r.state == "WITNESS_STALE" and r.script == vehicle:getScriptName() then
                sub:addOption(getText("ContextMenu_MVM_Reissue"), player, reissue, vehicle, r)
                break
            end
        end
    end
    if row == nil then
        sub:addOption(getText("ContextMenu_MVM_Claim"), player, startClaim, vehicle)
    elseif row.role == "OWNER" then
        sub:addOption(getText("ContextMenu_MVM_Unclaim"), player, unclaim, vehicle, row)
        if row.state == "WITNESS_STALE" then sub:addOption(getText("ContextMenu_MVM_Reissue"), player, reissue, vehicle, row) end
    else
        local o = sub:addOption(getText("ContextMenu_MVM_ClaimedByOther"), nil, nil)
        o.notAvailable = true
    end
    for _, hook in ipairs(MVM.clientMenuHooks or {}) do hook(player, sub, vehicle, row) end
    return result
end

-- 首個 OnTick 才訂閱：OnGameStart 當下 GameClient.ingame 尚未為 true，sendClientCommand 會誤走 SP 佇列（§6.2）
Events.OnGameStart.Add(function()
    local function first()
        Events.OnTick.Remove(first)
        local p = getSpecificPlayer(0)
        if p then C.request(p, "fleetSubscribe", {}) end
    end
    Events.OnTick.Add(first)
end)
