-- Action adapter 清單（計畫 §8.0、§8.1.2）：client 用它送 intent，server 用它包 lifecycle。
-- 每個 adapter 描述「實際會被突變的車／零件」與所需 action；resolver 只讀 action 上的原版欄位，
-- server 端會再驗零件確實屬於該車。未列入的 action（含第三方）一律不宣稱受保護。
require "MinidoracatVehicleManager_API"

local MVM = MinidoracatVehicleManager
MVM.ADAPTERS = MVM.ADAPTERS or {}

local function partVehicle(field)
    return function(a)
        local part = a[field]
        return part and part:getVehicle() or nil
    end
end
local function partOf(field) return function(a) return a[field] end end
local function ownVehicle(a) return a.vehicle end
local function seatVehicle(a) return a.character and a.character:getVehicle() or nil end

-- 門：引擎蓋給維修／拆卸者開，後車廂給載貨者開，其他門是乘客權限
local function doorAction(a)
    local id = a.part and a.part:getId() or ""
    if id == "EngineDoor" then return { "REPAIR", "SALVAGE" } end
    if id:find("Trunk", 1, true) or id == "DoorRear" then return { "CARGO" } end
    return { "PASSENGER" }
end

local ITEM_PUSH = { "item", "condition" }

-- push：拒絕後要推回的權威狀態（server 端解讀）
local BUILTIN = {
    { class = "ISInstallVehiclePart", action = "REPAIR", vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete" }, push = ITEM_PUSH },
    { class = "ISUninstallVehiclePart", action = "SALVAGE", vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete" }, push = ITEM_PUSH },
    { class = "ISFixVehiclePartAction", action = "REPAIR", vehicleOf = partVehicle("vehiclePart"), partOf = partOf("vehiclePart"), stages = { "complete" }, push = ITEM_PUSH },
    { class = "ISRepairEngine", action = "REPAIR", vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete" }, push = { "condition" } },
    { class = "ISRepairLightbar", action = "REPAIR", vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete" }, push = ITEM_PUSH },
    { class = "ISTakeEngineParts", action = "SALVAGE", vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete" }, push = { "condition" } },
    { class = "ISAddGasolineToVehicle", action = "FUEL", vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "serverStart", "update", "complete", "serverStop" }, push = { "moddata", "can" } },
    { class = "ISTakeGasolineFromVehicle", action = "FUEL", vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "serverStart", "update", "complete", "serverStop" }, push = { "moddata", "can" } },
    { class = "ISRefuelFromGasPump", action = "FUEL", vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete", "serverStop" }, push = { "moddata" } },
    { class = "ISDeflateTire", action = "SALVAGE", vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete", "serverStop" }, push = { "moddata" } },
    { class = "ISInflateTire", action = "REPAIR", vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete", "serverStop" }, push = { "moddata" } },
    { class = "ISAddAnimalInTrailer", action = "CARGO", vehicleOf = ownVehicle, stages = { "complete" } },
    { class = "ISRemoveAnimalFromTrailer", action = "CARGO", vehicleOf = ownVehicle, stages = { "complete" } },
    { class = "ISHotwireVehicle", action = "DRIVE", vehicleOf = seatVehicle, stages = { "complete" } },
    { class = "ISStartVehicleEngine", action = "DRIVE", vehicleOf = seatVehicle, stages = { "complete" } },
    { class = "ISShutOffVehicleEngine", action = "DRIVE", vehicleOf = seatVehicle, stages = { "complete" } },
    { class = "ISLockDoors", action = "PASSENGER", vehicleOf = ownVehicle, stages = { "complete" }, push = { "alldoors" } },
    { class = "ISLockVehicleDoor", action = "PASSENGER", vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete" }, push = { "door" } },
    { class = "ISUnlockVehicleDoor", action = "PASSENGER", vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete" }, push = { "door" } },
    { class = "ISOpenVehicleDoor", action = doorAction, vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete" }, push = { "door" } },
    { class = "ISCloseVehicleDoor", action = doorAction, vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete" }, push = { "door" } },
    { class = "ISOpenCloseVehicleWindow", action = "PASSENGER", vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete" }, push = { "window" } },
    -- 燒毀車拆解：原版不檢查目標是否真的燒毀（ISRemoveBurntVehicle.lua:11-16,60-143），會產物並永久刪車。
    -- 受保護的車只准車主／管理員拆（MANAGE）；燒毀車本身不可綁定，所以一般燒毀車照原版
    { class = "ISRemoveBurntVehicle", action = "MANAGE", vehicleOf = ownVehicle, stages = { "serverStart", "complete" } },
    -- 砸窗：以 VehicleWindow:getPart() 解析，不信 vehiclePart 欄位；建築窗戶不經本 MOD
    { class = "ISSmashWindow", action = "SALVAGE", stages = { "serverStart", "complete" }, push = { "window" },
      vehicleOf = function(a)
          local w = a.window
          if w == nil or not instanceof(w, "VehicleWindow") then return nil end
          local part = w:getPart()
          return part and part:getVehicle() or nil
      end,
      partOf = function(a)
          local w = a.window
          if w == nil or not instanceof(w, "VehicleWindow") then return nil end
          return w:getPart()
      end },
}

local byClass = {}
for _, spec in ipairs(MVM.ADAPTERS) do byClass[spec.class] = spec end

local function valid(spec)
    return type(spec) == "table" and type(spec.class) == "string" and type(spec.vehicleOf) == "function"
        and (type(spec.action) == "function" or MVM.ACTIONS[spec.action] ~= nil)
        and type(spec.stages) == "table" and #spec.stages > 0
end

-- 公開：第三方在 client 與 server 都登記同一份 spec（class 名稱、requiredAction、vehicleOf、partOf、stages）
function MinidoracatVehicleManagerAPI.registerActionAdapter(spec)
    if not valid(spec) then
        MVM.log("registerActionAdapter rejected: need class, action, vehicleOf, stages")
        return false
    end
    if byClass[spec.class] == nil then MVM.ADAPTERS[#MVM.ADAPTERS + 1] = spec end
    byClass[spec.class] = spec
    return true
end

function MVM.adapterFor(className) return byClass[className] end

-- 所需 action 一律回傳清單（門依角色可接受多種）
function MVM.requiredActions(spec, action)
    local r = spec.action
    if type(r) == "function" then r = r(action) end
    if type(r) == "string" then return { r } end
    return r
end

for _, spec in ipairs(BUILTIN) do MinidoracatVehicleManagerAPI.registerActionAdapter(spec) end
