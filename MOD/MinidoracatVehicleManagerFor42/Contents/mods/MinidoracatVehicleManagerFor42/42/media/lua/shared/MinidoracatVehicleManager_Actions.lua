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
MVM.doorAction = doorAction -- 指令防火牆的 vehicle.setDoorOpen 共用

local ITEM_PUSH = { "item", "condition" }
local TUNING_PUSH = { "item", "condition", "moddata" }

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
    -- 燒毀車拆解會產出材料並永久刪車（ISRemoveBurntVehicle.lua:60-143）。
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
    -- 另一個砸車窗類別：原版沒有呼叫點，但伺服器依客戶端送來的類別名稱建動作（NetTimedAction.parse），一樣要列入；
    -- complete 會 window:hit（ISSmashVehicleWindow.lua:55-68）
    { class = "ISSmashVehicleWindow", action = "SALVAGE", vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete" }, push = { "window" } },
    -- Autotsar 拖吊（tsarslib，Workshop 3402491515）：complete 在伺服器執行（MP 下只有伺服器跑），把車的零件換進拖車後
    -- permanentlyRemove（ATAISLoadVehicle.lua:35-58）；卸車以 addVehicleDebug 生新車還原（ATAISLaunchVehicle.lua:38-157）。
    -- also＝同一個動作還要檢查的其他車（各自要 TOW、受保護時各自要 intent）。裝車的主目標是 a.vehicle（被裝的車），
    -- 這樣 G.decide 的「a.vehicle 與目標不同」檢查不會誤擋。onAllow＝放行時記下拖車 keyId 延續與被裝車在哪台拖車上；
    -- carrier＝這台拖車載著的受保護紀錄（O.carriedBy）也各要 TOW
    { class = "ATAISLoadVehicle", action = "TOW", vehicleOf = ownVehicle, stages = { "complete" },
      also = { { vehicleOf = function(a) return a.trailer end, action = "TOW" } },
      onAllow = function(a) MVM.Own.noteLoad(a.trailer, a.vehicle) end,
      -- 被裝的車還載著受保護紀錄一律拒絕；受保護時人要在拖車與被裝車附近、被裝車要在拖車附近（同指令防火牆的 load）；
      -- 最後才看拖車有沒有綁定（CARRIER_UNBOUND，check 只在權限通過後呼叫；不靠 guarded 早退）
      check = function(a, guarded)
          if a.vehicle and #MVM.Own.carriedBy(a.vehicle) > 0 then return "CARRIER_LOADED" end
          local CG, p, tr, v = MVM.CommandGate, a.character, a.trailer, a.vehicle
          if guarded then
              if not (CG.within(tr, p:getX(), p:getY(), p:getZ(), CG.NEAR) and CG.within(v, p:getX(), p:getY(), p:getZ(), CG.NEAR)) then
                  return "TOO_FAR"
              end
              if not CG.within(tr, v:getX(), v:getY(), v:getZ(), CG.LAUNCH_NEAR) then return "TOO_FAR" end
          end
          return CG.carrierUnbound(tr, v)
      end },
    { class = "ATAISLaunchVehicle", action = "TOW", vehicleOf = function(a) return a.trailer end, stages = { "complete" },
      carrier = function(a) return a.trailer end,
      check = function(a, guarded) -- 受保護時人要在拖車附近、生車格（a.square，客戶端決定）要在拖車附近
          if not guarded then return nil end
          local CG, p, tr, sq = MVM.CommandGate, a.character, a.trailer, a.square
          if not CG.within(tr, p:getX(), p:getY(), p:getZ(), CG.NEAR) then return "TOO_FAR" end
          if sq == nil or not CG.within(tr, sq:getX(), sq:getY(), sq:getZ(), CG.LAUNCH_NEAR) then return "BAD_POS" end
      end },
    -- Autotsar 調校零件（tsarslib 42.17 shared，SVU3 與 ATA 車都用）：complete 在伺服器換零件物品、耐久與 modData，
    -- 拆下的零件交給執行者（ATATuning2Commands.lua:7-81；ISInstallTuningVehiclePart.lua:72-79、ISUninstallTuningVehiclePart.lua:56-62）
    { class = "ISInstallTuningVehiclePart", action = "REPAIR", vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete" }, push = TUNING_PUSH },
    { class = "ISUninstallTuningVehiclePart", action = "SALVAGE", vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete" }, push = TUNING_PUSH },
    -- 動畫門（ATAISAnimatedPartOpen／Close.lua:37-46）：門 setOpen 後 transmitPartDoor
    { class = "ATAISAnimatedPartOpen", action = doorAction, vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete" }, push = { "door" } },
    { class = "ATAISAnimatedPartClose", action = doorAction, vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete" }, push = { "door" } },
    -- 換塗裝（ISPaintBus.lua:31-35）
    { class = "ISPaintBus", action = "REPAIR", vehicleOf = ownVehicle, stages = { "complete" } },
    -- 油罐車與車之間抽油（TsarLiqudTanker_ISRefuelFromFuelTruck.lua:56-81）：兩台車的油量都改，油罐車放 also
    { class = "ISRefuelFromLiqudTanker", action = "FUEL", vehicleOf = partVehicle("part"), partOf = partOf("part"), stages = { "complete", "serverStop" },
      push = { "moddata" }, also = { { vehicleOf = function(a) return a.tank and a.tank:getVehicle() or nil end, action = "FUEL" } } },
}

local byClass = {}
for _, spec in ipairs(MVM.ADAPTERS) do byClass[spec.class] = spec end

local function valid(spec)
    return type(spec) == "table" and type(spec.class) == "string" and type(spec.vehicleOf) == "function"
        and (type(spec.action) == "function" or MVM.ACTIONS[spec.action] ~= nil)
        and type(spec.stages) == "table" and #spec.stages > 0
end

-- 公開：第三方在 client 與 server 都登記同一份 spec（class 名稱、requiredAction、vehicleOf、partOf、stages；
-- 選填 also＝{ { vehicleOf, action }, … } 同一動作要一併檢查的其他車）
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
