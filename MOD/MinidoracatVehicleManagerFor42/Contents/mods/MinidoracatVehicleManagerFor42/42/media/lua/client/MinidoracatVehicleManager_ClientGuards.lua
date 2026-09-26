-- Client 端（計畫 §8.1.3、§8.0 U 級）：
--   1. 排入受保護類別的 timed action 時送 prepareAction（server 以連線身分記 intent）
--   2. 上車／換座／拖掛是 client-only 動作：依投影快取在 isValid 擋下（U 級；server watchdog 事後偵測）
--   3. 虛擬鑰匙入口：無實體鑰匙的授權者可從選單發動、解鎖
--   4. 顯示 server 送來的 enforcement
-- 這些都只是 UX；權威判定一律在 server。
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
local function sendIntent(action)
    if not isClient() or type(action) ~= "table" then return end
    local spec = MVM.adapterFor(action.Type)
    if spec == nil or action.character == nil then return end
    local vehicle = spec.vehicleOf(action)
    if vehicle == nil or MVM.clientProjection(action.character:getPlayerNum(), vehicle) == nil then return end
    local part = spec.partOf and spec.partOf(action) or nil
    sendClientCommand(action.character, MVM.MODULE, "prepareAction",
        { protocol = MVM.PROTOCOL, class = spec.class, vehicleId = vehicle:getId(), partId = part and part:getId() or nil })
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
local function allowed(chr, vehicle, act)
    if vehicle == nil then return true end
    return (MVM.clientCanUse(chr, vehicle, act))
end

local function refuse(action)
    if not action._mvmTold then
        action._mvmTold = true
        MVM.notify(action.character, getText("IGUI_MVM_Protected"), true)
    end
    return false
end

-- 每個實例只判定一次（isValid 每 tick 被呼叫）
local function guardValid(cls, check)
    local orig = cls.isValid
    cls.isValid = function(self)
        if self._mvmOk == nil then self._mvmOk = check(self) end
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

-- ------------------------------------------------------------ virtual key ---
local function hasKey(player, vehicle)
    return vehicle:isKeysInIgnition() or player:getInventory():haveThisKeyId(vehicle:getKeyId())
end

local function virtualKeyFor(player, vehicle, act)
    if SandboxVars.VehicleEasyUse or not MVM.sandbox("VirtualKey", true) then return false end
    local row = MVM.clientProjection(player:getPlayerNum(), vehicle)
    return row ~= nil and row.role ~= "OTHER" and MVM.clientCanUse(player, vehicle, act) == true and not hasKey(player, vehicle)
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
    if row == nil or row.role == "OTHER" then return end
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
    local key = payload.reason == "NOT_AUTHORIZED" and "IGUI_MVM_Protected" or "IGUI_MVM_Refused"
    MVM.notify(p, getText(key), true)
    MVM.log("enforcement " .. tostring(payload.action) .. " " .. tostring(payload.reason))
end
