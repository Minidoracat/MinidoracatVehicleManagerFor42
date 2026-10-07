-- Client 端（計畫 §8.1.3、§8.0 U 級）：
--   1. 排入受保護類別的 timed action 時送 prepareAction（server 以連線身分記 intent）
--   2. 上車／換座／拖掛／MSW 拖車裝卸是 client 端判定的動作：依投影快取在 isValid 擋下（U 級；server watchdog 事後偵測）
--   3. 虛擬鑰匙入口：無實體鑰匙的授權者可從選單發動、解鎖
--   4. 顯示 server 送來的 enforcement；武器打到別人的車時回報 hitReport（server 據此通知車主）
--   5. 車上容器（後車廂、座位、置物箱…）依權限決定列不列出
-- 動作授權由 server 判定；容器限制僅作用於玩家端 Lua 存取入口，不是 server 搬物品權限驗證。
require "MinidoracatVehicleManager_API"
require "MinidoracatVehicleManager_Actions"
require "MinidoracatVehicleManager_Client"
require "TimedActions/ISTimedActionQueue"
require "Vehicles/TimedActions/ISEnterVehicle"
require "Vehicles/TimedActions/ISSwitchVehicleSeat"
require "Vehicles/TimedActions/ISAttachTrailerToVehicle"
require "Vehicles/TimedActions/ISDetachTrailerFromVehicle"

local MVM = MinidoracatVehicleManager
local C = MVM.Client

-- ------------------------------------------------------------------ intent ---
-- 受保護的車（本機投影看得到見證）各送一筆；spec.also 的車（例：拖吊的拖車）也要各送一筆
local function sendIntent(action)
    if not isClient() or type(action) ~= "table" then return end
    local spec = MVM.adapterFor(action.Type)
    if spec == nil or action.character == nil then return end
    local function send(vehicle, part)
        if vehicle == nil or MVM.clientProjection(action.character:getPlayerNum(), vehicle) == nil then return end
        sendClientCommand(action.character, MVM.MODULE, "prepareAction",
            { protocol = MVM.PROTOCOL, class = spec.class, vehicleId = vehicle:getId(), partId = part and part:getId() or nil })
    end
    send(spec.vehicleOf(action), spec.partOf and spec.partOf(action) or nil)
    for _, extra in ipairs(spec.also or {}) do send(extra.vehicleOf(action), nil) end
end

local queueAdd = ISTimedActionQueue.add
function ISTimedActionQueue.add(action)
    sendIntent(action)
    return queueAdd(action)
end
local queueAddAfter = ISTimedActionQueue.addAfter
if queueAddAfter then
    function ISTimedActionQueue.addAfter(previous, action)
        sendIntent(action)
        return queueAddAfter(previous, action)
    end
end

-- ------------------------------------------------------------ UX guards ---
-- 被拒的原因記在 lastReason：租用名額到期鎖住的車（RENT_LOCKED）提示要怎麼解鎖、陣營分享暫停中的車（FACTION_PAUSED）
-- 提示要車主恢復，都不是「沒有車主的分享」
local lastReason = nil
local function allowed(chr, vehicle, act)
    if vehicle == nil then return true end
    local ok, reason = MVM.clientCanUse(chr, vehicle, act)
    if not ok then lastReason = reason end
    return ok
end

-- 預設提示「受保護」；check 可在 action._mvmText 放別的文字（例：MSW 拖車沒綁定）
local function refuse(action)
    if not action._mvmTold then
        action._mvmTold = true
        MVM.notify(action.character, action._mvmText or MVM.protectedText(action.character), true)
    end
    return false
end

-- 每個實例只判定一次（isValid 每 tick 被呼叫）
local function guardValid(cls, check)
    local orig = cls.isValid
    cls.isValid = function(self)
        if self._mvmOk == nil then
            lastReason = nil
            self._mvmOk = check(self)
            if not self._mvmOk and (lastReason == "RENT_LOCKED" or lastReason == "FACTION_PAUSED") and self._mvmText == nil then
                self._mvmText = MVM.reasonText(lastReason)
            end
        end
        if not self._mvmOk then return refuse(self) end
        return orig(self)
    end
end

guardValid(ISEnterVehicle, function(a) return allowed(a.character, a.vehicle, a.seat == 0 and "DRIVE" or "PASSENGER") end)
guardValid(ISSwitchVehicleSeat, function(a) return allowed(a.character, a.character:getVehicle(), a.seatTo == 0 and "DRIVE" or "PASSENGER") end)
guardValid(ISAttachTrailerToVehicle, function(a)
    return allowed(a.character, a.vehicleA, "TOW") and allowed(a.character, a.vehicleB, "TOW")
end)
guardValid(ISDetachTrailerFromVehicle, function(a)
    local v = a.vehicle
    if v == nil then return true end
    return allowed(a.character, v, "TOW") and allowed(a.character, v:getVehicleTowing(), "TOW")
        and allowed(a.character, v:getVehicleTowedBy(), "TOW")
end)

-- MSW（rSemiTruck 多槽拖車）：裝車要被裝的車與拖車都有 TOW，卸車要拖車有 TOW；綁定的車只能裝上已綁定的拖車
-- （伺服器 CARRIER_UNBOUND，這裡依本機投影提早提示）。它的 perform 只送 msw 命令
-- （MSW_ISLoadVehicle.lua:27-33、MSW_ISLaunchVehicle.lua:39-45），伺服器端由指令防火牆（shared/…_CommandGate.lua）判定；
-- 這裡只是讓一般玩家在排入動作時就看到提示，不必等伺服器拒絕。
-- 類別定義在 MSW 自己的 client 檔，載入順序不保證：現在有就包，否則進遊戲時再包（每個類別只包一次）
function MVM.guardMsw()
    if MSW_ISLoadVehicle and not rawget(MSW_ISLoadVehicle, "_mvmGuarded") then
        rawset(MSW_ISLoadVehicle, "_mvmGuarded", true)
        guardValid(MSW_ISLoadVehicle, function(a)
            if not (allowed(a.character, a.vehicle, "TOW") and allowed(a.character, a.trailer, "TOW")) then return false end
            local n = a.character:getPlayerNum()
            if MVM.clientProjection(n, a.vehicle) ~= nil and MVM.clientProjection(n, a.trailer) == nil then
                a._mvmText = getText("IGUI_MVM_Reason_CARRIER_UNBOUND")
                return false
            end
            return true
        end)
    end
    if MSW_ISLaunchVehicle and not rawget(MSW_ISLaunchVehicle, "_mvmGuarded") then
        rawset(MSW_ISLaunchVehicle, "_mvmGuarded", true)
        guardValid(MSW_ISLaunchVehicle, function(a) return allowed(a.character, a.trailer, "TOW") end)
    end
end
MVM.guardMsw()
Events.OnGameStart.Add(MVM.guardMsw)

-- ------------------------------------------------------------ virtual key ---
local function hasKey(player, vehicle)
    return vehicle:isKeysInIgnition() or player:getInventory():haveThisKeyId(vehicle:getKeyId())
end

-- 自己的車、被分享的車與公開的車（公開表有這個動作）；管理員越權開別人的車不給虛擬鑰匙
local function virtualKeyFor(player, vehicle, act)
    if SandboxVars.VehicleEasyUse or not MVM.sandbox("VirtualKey", true) then return false end
    local row = MVM.clientProjection(player:getPlayerNum(), vehicle)
    if row == nil or (row.role == "OTHER" and not MVM.bitsAllow(row.publicBits or 0, act)) then return false end
    return MVM.clientCanUse(player, vehicle, act) == true and not hasKey(player, vehicle)
end

-- 車內圓盤選單：原版只在有鑰匙／熱線時給「發動」（ISVehicleMenu.lua:94-104）
local showRadial = ISVehicleMenu.showRadialMenu
function ISVehicleMenu.showRadialMenu(playerObj)
    local result = showRadial(playerObj)
    local vehicle = playerObj and playerObj:getVehicle()
    if vehicle == nil or playerObj:getPlayerNum() ~= 0 then return result end
    local menu = getPlayerRadialMenu(0)
    if menu:isReallyVisible() and vehicle:isDriver(playerObj) and not vehicle:isEngineStarted() and not vehicle:isHotwired()
        and virtualKeyFor(playerObj, vehicle, "DRIVE") then
        menu:addSlice(getText("ContextMenu_MVM_StartVirtualKey"), getTexture("media/ui/vehicles/vehicle_ignitionON.png"),
            ISVehicleMenu.onStartEngine, playerObj)
    end
    return result
end

local function lockedDoor(vehicle)
    local front = vehicle:getPartById("DoorFrontLeft")
    if front and front:getDoor() and front:getDoor():isLocked() then return front end
    for i = 0, vehicle:getPartCount() - 1 do
        local p = vehicle:getPartByIndex(i)
        if p and p:getDoor() and p:getDoor():isLocked() and p:getId() ~= "EngineDoor" then return p end
    end
    return nil
end

-- 車外右鍵子選單加「虛擬鑰匙解鎖」（Client.lua 已建「車輛管理」子選單）
MVM.clientMenuHooks = MVM.clientMenuHooks or {}
table.insert(MVM.clientMenuHooks, function(player, sub, vehicle, row)
    if row == nil or (row.role == "OTHER" and (row.publicBits or 0) == 0) then return end
    local door = lockedDoor(vehicle)
    if door and virtualKeyFor(player, vehicle, "PASSENGER") then
        sub:addOption(getText("ContextMenu_MVM_UnlockVirtualKey"), player, ISVehicleMenu.onUnlockDoor, door)
    end
end)

-- ------------------------------------------------------------ enforcement ---
MVM.clientHandlers = MVM.clientHandlers or {}
MVM.clientHandlers.enforcement = function(payload)
    local p = getSpecificPlayer(0)
    if p == nil or payload.to ~= (isClient() and p:getUsername() or "local:0") then return end
    local text
    if payload.reason == "RENT_LOCKED" or payload.reason == "FACTION_PAUSED" then text = MVM.reasonText(payload.reason)
    -- 武器打車被擋（砸窗、hitReport）：停車保全中說「打不壞」，否則說「已被綁定、車主會收到通知」（車照樣會壞，見 guards.md）
    elseif payload.guard ~= nil then
        text = getText(payload.guard == true and "IGUI_MVM_Guard_Hit" or "IGUI_MVM_Attack_Owned")
    elseif payload.reason == "NOT_AUTHORIZED" then text = MVM.protectedText(p)
    -- 其餘寫出原因與怎麼辦（離車太遠、拖車要先綁定、載著車不能再被裝、隔離、伺服器啟動中）；沒有譯文的碼正常操作碰不到，
    -- MVM.reasonText 退回不帶代碼的通用說明
    else text = MVM.reasonText(payload.reason) end
    MVM.notify(p, text, true)
    MVM.log("enforcement " .. tostring(payload.action) .. " " .. tostring(payload.reason))
end

-- ------------------------------------------------------------ hit report ---
-- 打到沒有車窗的零件（引擎蓋、後車廂、車燈、輪胎、窗已破或搖下的門）原版不送任何指令、伺服器也沒有事件；攻擊者客戶端在同一次
-- 攻擊裡先自己扣零件耐久（BaseVehicle.applyDamageToPart 的 client 分支），伺服器之後改回（guards.md「攻擊通知」）。攻擊當下記下
-- 範圍內、自己不能拆零件的綁定車的零件耐久，下一個 tick 有下降就回報；同一台車 2 秒一次（連射別撐爆伺服器限流）。
-- 只是盡力通知，防破壞本身在伺服器
local swing, reported = nil, {}
local first = MVM.hitWatch == nil
MVM.hitWatch = {}
function MVM.hitWatch.swing(owner, weapon)
    if not isClient() or not instanceof(owner, "IsoPlayer") or not owner:isLocalPlayer() or not instanceof(weapon, "HandWeapon") then return end
    local CG, cars = MVM.CommandGate, {}
    local reach = CG.hitReach(weapon)
    local it = getCell():getVehicles():iterator()
    while it:hasNext() do
        local v = it:next()
        if CG.within(v, owner:getX(), owner:getY(), owner:getZ(), reach) and not MVM.clientCanUse(owner, v, "SALVAGE") then
            local conds = {}
            for i = 0, v:getPartCount() - 1 do conds[i] = v:getPartByIndex(i):getCondition() end
            cars[#cars + 1] = { v = v, conds = conds }
        end
    end
    swing = cars[1] and { owner = owner, cars = cars } or nil
end
function MVM.hitWatch.tick()
    if swing == nil then return end
    local s, t = swing, getTimestampMs()
    swing = nil
    for _, c in ipairs(s.cars) do
        local id = c.v:getId()
        for i, before in pairs(c.conds) do
            local part = c.v:getPartByIndex(i)
            if part and part:getCondition() < before then
                if t - (reported[id] or 0) >= 2000 then
                    reported[id] = t
                    sendClientCommand(s.owner, MVM.MODULE, "hitReport", { protocol = MVM.PROTOCOL, vehicleId = id })
                end
                break
            end
        end
    end
end
-- Lua 重載只換函式、不重複註冊（同 CommandGate）
if first then
    Events.OnWeaponSwingHitPoint.Add(function(owner, weapon) MVM.hitWatch.swing(owner, weapon) end)
    Events.OnTick.Add(function() MVM.hitWatch.tick() end)
end

-- ------------------------------------------------------- vehicle storage ---
-- 下列原版 Lua 容器入口會先問 BaseVehicle.canAccessContainer（BaseVehicle.java:8329-8347 → 容器的 Lua test）：物品欄列容器
-- （ISInventoryPage.lua:1585,1609,1764）、製作取材、搬重物與屍體、開門後自動打開後車廂都走它。MOD 車的 test 函式各自命名、
-- 名稱存在沒有 getter 的 VehicleScript 欄位（VehicleScript.java:2169-2173），無法逐一包，所以包 Java 方法表：
-- Kahlua 把類別方法放在全域 __classmetatables[類別].__index（KahluaUtil.java:132-134、LuaJavaClassExposer.java:224-231），
-- `BaseVehicle.class` 是公開的類別物件（LuaJavaClassExposer.java:287）。只影響 Lua 呼叫端；Java 內部的二次檢查不經過這裡。
-- 這是玩家端防線：server 搬物品只檢查距離與容量（ItemTransactionPacket／TransactionManager.isConsistent），
-- 改過客戶端的人仍拿得到，與原版鎖車同級。
-- 只管有物品容器的零件（油箱、輪胎不管）：座位與置物箱要 PASSENGER，其餘（後車廂、車斗、拖車、MOD 貨箱）要 CARGO
function MVM.containerAction(part)
    if part == nil or part:getItemContainer() == nil then return nil end
    if part:getContainerSeatNumber() >= 0 or part:getId() == "GloveBox" then return "PASSENGER" end
    return "CARGO"
end

function MVM.storageAllowed(vehicle, partIndex, chr)
    if not (isClient() and instanceof(chr, "IsoPlayer") and chr:isLocalPlayer()) then return true end
    local act = MVM.containerAction(vehicle:getPartByIndex(partIndex))
    return act == nil or (MVM.clientCanUse(chr, vehicle, act))
end

if isClient() then
    local methods = __classmetatables and BaseVehicle and BaseVehicle.class and __classmetatables[BaseVehicle.class]
    methods = methods and methods.__index
    local vanillaAccess = methods and methods.canAccessContainer
    if vanillaAccess then
        methods.canAccessContainer = function(vehicle, partIndex, chr)
            return vanillaAccess(vehicle, partIndex, chr) and MVM.storageAllowed(vehicle, partIndex, chr)
        end
        MVM.log("vehicle storage guard installed")
    else
        MVM.log("vehicle storage guard NOT installed: BaseVehicle method table not found")
    end
end
