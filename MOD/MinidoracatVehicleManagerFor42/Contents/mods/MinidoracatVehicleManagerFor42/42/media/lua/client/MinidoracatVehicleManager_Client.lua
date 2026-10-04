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

-- 失敗原因：有譯文用譯文；沒有就用附代碼的通用說明（含下一步）。通知與車隊視窗共用
function MVM.reasonText(reason)
    local key = "IGUI_MVM_Reason_" .. tostring(reason)
    local t = getText(key)
    if t == key then return getText("IGUI_MVM_Failed", tostring(reason)) end
    return t
end

-- 投影或越權狀態變了：清見證快取、重列物品欄的車上容器（ISInventoryPage.lua:1330 dirtyUI 對每位本機玩家 refreshBackpacks）
local witnessCache, witnessCacheAt = {}, 0
local function accessChanged()
    witnessCache = {}
    if ISInventoryPage and ISInventoryPage.dirtyUI then ISInventoryPage.dirtyUI() end
end

-- 伺服器存好新的全服預設名額後通知（沒有原版 Lua 廣播）：本機沙盒選項跟著改並投影到 SandboxVars，
-- 否則之後從原版沙盒 UI 存檔會把舊值整份送回伺服器（GameServer.java:1694-1708）
local function syncDefaultQuota(amount)
    getSandboxOptions():set("MinidoracatVehicleManager.ClaimsPerPlayer", amount)
    getSandboxOptions():toLua()
end

-- 管理員總表分段（Server.lua S.sendAdminParts：引擎送出緩衝區固定 1 MB）。同一 id 收齊全部段才一次回傳 meta（第 1 段）
-- 與合併後的 rows／players；新 id 丟掉舊的未完成段；欄位不對、缺段都不回傳，不套用半套資料
local function adminParts(b, payload)
    local id, part, parts = payload.id, payload.part, payload.parts
    if type(id) ~= "string" or not MVM.isInt(parts) or parts < 1 or not MVM.isInt(part) or part < 1 or part > parts then return nil end
    local pend = b.adminPending
    if pend == nil or pend.id ~= id or pend.parts ~= parts then
        pend = { id = id, parts = parts, got = {}, n = 0 }
        b.adminPending = pend
    end
    if pend.got[part] == nil then pend.n = pend.n + 1 end
    pend.got[part] = payload
    if pend.n < parts then return nil end
    b.adminPending = nil
    local rows, players = {}, {}
    for i = 1, parts do
        for _, row in ipairs(pend.got[i].rows or {}) do rows[#rows + 1] = row end
        for _, pl in ipairs(pend.got[i].players or {}) do players[#players + 1] = pl end
    end
    return pend.got[1], rows, players
end

-- server → client（MP 經 OnServerCommand；SP 由 server adapter 直接呼叫）
function MVM.clientReceive(command, payload)
    if type(payload) ~= "table" or type(payload.to) ~= "string" then return end
    local b = bucket(payload.to)
    if command == "fleetSnapshot" then
        b.streamId, b.seq, b.rows, b.track = payload.streamId, payload.seq, {}, {}
        for _, row in ipairs(payload.rows or {}) do b.rows[row.oid] = row end
        b.quotaUsed, b.quotaLimit, b.quota, b.status = payload.quotaUsed, payload.quotaLimit, payload.quota, payload.status
    elseif command == "fleetDelta" then
        -- 跳號或換 stream：丟棄並要求完整快照（keyed replace，不 append）
        if b.streamId ~= payload.streamId or payload.seq ~= (b.seq or -1) + 1 then return resync(payload.to) end
        b.seq = payload.seq
        for _, oid in ipairs(payload.removes or {}) do b.rows[oid] = nil end
        for _, row in ipairs(payload.upserts or {}) do b.rows[row.oid] = row end
        if MVM.isInt(payload.quotaUsed) then
            b.quotaUsed = payload.quotaUsed
            if b.quota then b.quota.used = payload.quotaUsed end
        end
    elseif command == "mutationAck" then
        if payload.reason == "PROTOCOL_MISMATCH" then C.protocolMismatch = true end
        local cb = C.pending[payload.requestId]
        C.pending[payload.requestId] = nil
        if type(cb) == "function" then cb(payload) end
        local p = getSpecificPlayer(0)
        local mine = p ~= nil and principal(0) == payload.to
        if mine and not payload.ok then
            MVM.notify(p, MVM.reasonText(payload.reason), true)
        end
        if payload.requestKind == "setAdminOverride" and payload.ok then
            b.adminOverride = payload.enabled == true
            if mine then MVM.notify(p, getText(b.adminOverride and "IGUI_MVM_Override_OnToast" or "IGUI_MVM_Override_OffToast"), b.adminOverride) end
            accessChanged()
        end
        MVM.log("ack " .. tostring(payload.requestKind) .. " ok=" .. tostring(payload.ok) .. " reason=" .. tostring(payload.reason))
    elseif command == "trackDelta" then
        -- 即時位置只存最新值；是否顯示仍以列的 TRACK 權限為準（撤權後列消失，位置自然不再用）
        if type(payload.oid) ~= "string" then return end
        b.track = b.track or {}
        b.track[payload.oid] = { x = payload.x, y = payload.y, z = payload.z, t = payload.t }
    elseif command == "adminSnapshot" then
        local meta, rows, players = adminParts(b, payload)
        if meta == nil then return end
        local ok = meta.ok == true
        b.admin = ok and rows or nil
        b.adminPlayers = ok and players or nil
        b.adminDefaultQuota = ok and meta.defaultQuota or nil
        b.migrationAvailable = ok and meta.migrationAvailable == true
        b.adminOverride = ok and meta.override == true
        b.identitySteam = ok and meta.identitySteam == true
        b.identityImported = ok and meta.identityImported == true
        b.identityConflicts = ok and type(meta.identityConflicts) == "table" and meta.identityConflicts or nil
    elseif command == "sandboxSync" then
        if not MVM.isInt(payload.claimsPerPlayer) then return end
        local ok, err = pcall(syncDefaultQuota, payload.claimsPerPlayer)
        if not ok then MVM.log("sandbox sync failed: " .. tostring(err)) end
    elseif MVM.clientHandlers and MVM.clientHandlers[command] then
        MVM.clientHandlers[command](payload)
    end
    b.rev = (b.rev or 0) + 1
    if command == "fleetSnapshot" or command == "fleetDelta" or command == "adminSnapshot" then accessChanged() end
    if MVM.onFleetChanged and command ~= "trackDelta" then MVM.onFleetChanged(payload.to, command, payload) end
end

Events.OnServerCommand.Add(function(module, command, args)
    if module == MVM.MODULE then MVM.clientReceive(command, args) end
end)

-- 車上的零件見證只給 oid，用來對到自己的投影列；他人的車只知道「已被綁定」。
-- 宿主可能是任一零件（server 找不到 Engine 等時用第 0 個），要掃全部零件（≤128 個）。
-- 物品欄刷新時每個車上容器都會問一次（canAccessContainer），所以每台車的結果快取 1 秒；投影變動時整批清掉
local WITNESS_TTL_MS = 1000
local function scanWitness(vehicle)
    for i = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(i)
        if part and part:hasModData() then
            local w = rawget(part:getModData(), WITNESS_KEY)
            if type(w) == "table" and type(w.oid) == "string" then return w.oid end
        end
    end
    return nil
end

local function witnessOid(vehicle)
    local now = getTimestampMs()
    if now - witnessCacheAt > WITNESS_TTL_MS then witnessCache, witnessCacheAt = {}, now end
    local hit = witnessCache[vehicle]
    if hit ~= nil then return hit or nil end
    local oid = scanWitness(vehicle)
    witnessCache[vehicle] = oid or false
    return oid
end

function MVM.clientProjection(playerNum, vehicle)
    local who = principal(playerNum)
    if who == nil or vehicle == nil then return nil end
    local oid = witnessOid(vehicle)
    if oid == nil then return nil end
    local row = bucket(who).rows[oid]
    return row or { oid = oid, role = "OTHER" }
end

-- 本機玩家在 server 開著管理員越權（adminSnapshot 與 setAdminOverride ACK；重新登入後 client 狀態也歸零）
function MVM.clientOverride(playerNum)
    local who = principal(playerNum or 0)
    local b = who and C.buckets[who]
    return b ~= nil and b.adminOverride == true and MVM.clientIsAdmin(getSpecificPlayer(playerNum or 0))
end

-- 與 server 的 O.canUse 同順序：車主 → 分享（MANAGE 除外）→ 越權；QUARANTINED 只有越權能用
function MVM.clientCanUse(actor, vehicle, action)
    local row = MVM.clientProjection(actor:getPlayerNum(), vehicle)
    if row == nil then return true, "UNCLAIMED" end
    if row.state ~= "QUARANTINED" then
        if row.role == "OWNER" then return true, "OWNER" end
        if action ~= "MANAGE" and row.myBits and MVM.bitsAllow(row.myBits, action) then return true, row.role end
    end
    if MVM.clientOverride(actor:getPlayerNum()) then return true, "ADMIN" end
    return false, "NOT_AUTHORIZED"
end

-- 本機玩家有車輛管理權限：與 server O.isAdmin 同一個 Capability（IsoPlayer.getRole：IsoPlayer.java:7562、
-- Role.hasCapability：Role.java:185；原版 ISChat.lua:469 同法）。client 的 checkPermissions 一律回 true（LuaManager.java:3048-3057），不能用
function MVM.clientIsAdmin(player)
    if not (isClient() and player and Capability) then return false end
    local role = player:getRole()
    return role ~= nil and role:hasCapability(Capability.ManipulateVehicle) == true
end

-- 管理角色被撤銷時收回已列出的容器；ExtraInfoPacket.java:197,224／RolesPacket.java:103-128 先更新角色再觸發事件
local function refreshAdminAccess()
    local p = getSpecificPlayer(0)
    local who = principal(0)
    local b = who and C.buckets[who]
    if b and b.adminOverride and not MVM.clientIsAdmin(p) then
        b.adminOverride = false
        accessChanged()
        if MVM.onFleetChanged then MVM.onFleetChanged(who) end
    end
end
Events.RefreshCheats.Add(refreshAdminAccess)
Events.OnRolesReceived.Add(refreshAdminAccess)

-- 被車主保護擋下的提示；越權關閉的管理員多一句「到車隊視窗的管理頁開啟越權」
function MVM.protectedText(player)
    local admin = MVM.clientIsAdmin(player) and not MVM.clientOverride(player:getPlayerNum())
    return getText(admin and "IGUI_MVM_ProtectedAdmin" or "IGUI_MVM_Protected")
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

-- 目前已用／上限（車隊視窗頁尾與綁定確認視窗共用）：有付費名額時用 Economy 的 quota，否則快照的 quotaUsed／quotaLimit；
-- 還沒收到快照回 nil
function MVM.quotaNumbers(b)
    local q = b and b.quota
    if q and (q.paid or 0) > 0 then return q.used or 0, q.total or 0 end
    if b and b.quotaLimit then return b.quotaUsed or 0, b.quotaLimit end
    return nil
end

-- 綁定確認視窗內文：保護邊界＋名額（讀得到才加）＋能裝車的載具多一句「綁定的車只能裝上已綁定的拖車」
function MVM.claimText(playerNum, vehicle)
    local text = getText("IGUI_MVM_ClaimDisclosure")
    local used, total = MVM.quotaNumbers(C.buckets[principal(playerNum) or ""])
    if used ~= nil then text = text .. "\n" .. getText("IGUI_MVM_ClaimQuotaNote", used, total) end
    if MVM.isCarrier(vehicle) then text = text .. "\n" .. getText("IGUI_MVM_ClaimCarrierNote") end
    return text
end

-- 綁定前先揭露保護邊界（武器、殭屍、碰撞傷害無法完全阻止）與名額，確認後才送 prepareClaim（框架 Dialog）
local function startClaim(player, vehicle)
    local UI = ui()
    if not (UI and UI.API_REVISION >= 7 and UI.CAPABILITIES.dialog) then
        MVM.notify(player, getText("IGUI_MVM_NeedFramework"), true)
        return
    end
    UI.Dialog.show({ title = getText("ContextMenu_MVM_Menu"), text = MVM.claimText(player:getPlayerNum(), vehicle), width = 480,
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
