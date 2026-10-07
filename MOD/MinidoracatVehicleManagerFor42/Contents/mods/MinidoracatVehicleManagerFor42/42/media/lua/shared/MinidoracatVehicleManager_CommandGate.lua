-- 伺服器端車輛指令防火牆：原版與第三方 MOD 依客戶端指定的車輛 id 改車的 OnClientCommand 處理器，先在這裡檢查權限與距離
-- （各規則旁註出處）。專用伺服器先對所有 MOD 跑完 shared 再跑 server（GameServer.java:1469-1471；每一輪內原版檔在前、
-- 再依 MOD 順序，LuaManager.java:1151-1193），Event.trigger 依 Add 順序呼叫、所有回呼拿到同一個 args table
-- （Event.java:52-63）：本檔在 shared 註冊的回呼一定排在那些 server 檔處理器前面，拒絕時把 args 消掉，後面的處理器
-- 就安靜結束。伺服器上的 sendClientCommand 直接觸發本機 OnClientCommand（LuaManager.java:8936-8938）：TimedAction 的
-- complete 回送（ATAISLoadVehicle.lua:45、ISOpenTent.lua:46）也經過這裡，判定與 adapter 相同（同一人、同一台車）。
-- 沒有規則的指令立刻放行；目標都不受保護照原版；受保護的目標要有權限、送指令的人要在附近。
-- 放行後通知停車保全目標車是授權改的（MVM.Parked.touch）；拒絕砸窗與客戶端回報打到車（CG.onHit）時問停車保全這台車有沒有布防
-- （提示攻擊者、通知車主）
require "MinidoracatVehicleManager_API"
require "MinidoracatVehicleManager_Actions"

local MVM = MinidoracatVehicleManager
local CG = {}

-- 距離量到車身（CG.within）、同一樓層；10 格同原版掛拖車的遠距警告（BaseVehicle.java:10050-10057，原版只記 log 不擋）
CG.NEAR = 10
CG.LAUNCH_NEAR = 15 -- Autotsar 卸車的生車座標由客戶端決定（CommonCommands.lua:1001），受保護時限制在拖車附近
CG.NOTIFY_MS = 2000

local R = { notified = {}, logged = {} }
CG.R = R

-- id 不是整數：處理器的 getVehicleById 會把小數截斷成別台車（KahluaNumberConverter.java:28-31、LuaManager.java:10279-10281），一律拒絕
local BAD = false
local function veh(id)
    if id == nil then return nil end
    if not MVM.isInt(id) then return BAD end
    return getVehicleById(id)
end

local function on(field, action)
    return function(_, a) return { { vehicle = veh(a[field]), action = action } } end
end
local function one(action) return on("vehicle", action) end

-- 送指令的人坐在這台車上：他的客戶端自動送的（Autotsar 車內燈開燈失敗）只要 PASSENGER（佔座由 watchdog 管），否則要 outside
local function seated(field, outside)
    return function(p, a)
        local v = veh(a[field])
        return { { vehicle = v, action = (v and p:getVehicle() == v) and "PASSENGER" or outside } }
    end
end

-- 駕駛自己的客戶端自動送的（W900 裝甲補償 ArmorSync.dispatchRepair、KI5 CTIS 胎壓）：駕駛只要 DRIVE，否則要 outside
local function isDriver(p, v) return v and v.isDriver and v:isDriver(p) end

local function tows(field)
    return function(_, a)
        local v = veh(a[field])
        local out = { { vehicle = v, action = "TOW" } }
        if v then
            out[2] = { vehicle = v:getVehicleTowing(), action = "TOW" }
            out[3] = { vehicle = v:getVehicleTowedBy(), action = "TOW" }
        end
        return out
    end
end

-- 綁定的車只能裝上已綁定的載具（使用者裁定 2026-10-03）：被裝的車有紀錄、拖車沒有 → CARRIER_UNBOUND。否則別人卸不下車，
-- 但 attachTrailer 只看兩台活車、拖行巡檢只看被拖的車，整台拖車連車能被掛走。「有紀錄」＝O.lookup 第二回傳（同 O.canUse）。
-- 指令防火牆的 load 與 Autotsar 裝車 adapter 共用
function CG.carrierUnbound(tr, v)
    local O = MVM.Own
    if tr == nil or v == nil then return nil end
    local _, rv = O.lookup(v)
    if rv == nil then return nil end
    local _, rt = O.lookup(tr)
    if rt == nil then return "CARRIER_UNBOUND" end
    return nil
end

-- 裝車：拖車與被裝的車各要 TOW；受保護時以拖車為錨點量距離、被裝的車也要在拖車附近。被裝的車自己還載著受保護的紀錄
-- （拖車再被裝上另一台拖車）一律拒絕：卸下時那些紀錄找不到原拖車。mark＝放行時記 keyId 延續與「在哪台拖車上」，
-- 也只有這種（整台車裝上去、之後接回）要求拖車已綁定（check，權限與距離都通過後才判，沒權限的人只看到 NOT_AUTHORIZED）
-- （W900 貨櫃轉移不還原 keyId 與見證、不會接回，不記也不要求，見 O.noteLoad）
local function load(field, mark)
    return function(_, a)
        local tr, v = veh(a.trailer), veh(a[field])
        if v and #MVM.Own.carriedBy(v) > 0 then return nil, nil, "CARRIER_LOADED" end
        local out = { { vehicle = tr, action = "TOW" }, { vehicle = v, action = "TOW" } }
        out.anchor, out.loaded = tr, v
        if mark then out.check = function() return CG.carrierUnbound(tr, v) end end
        return out, mark and function() MVM.Own.noteLoad(tr, v) end or nil
    end
end

-- 卸車：拖車與它載著的受保護紀錄各要 TOW；受保護時以拖車為錨點量距離，生車座標（spawn＝欄位名）也要在拖車附近
local function unload(carried, x, y, z)
    return function(_, a)
        local tr = veh(a.trailer)
        local out = { { vehicle = tr, action = "TOW" } }
        if tr and carried then for _, rec in ipairs(MVM.Own.carriedBy(tr)) do out[#out + 1] = { rec = rec, action = "TOW" } end end
        out.anchor = tr
        if x then out.spawn = { a[x], a[y], z and a[z] } end
        return out
    end
end

-- 容量類零件（setContainerContentAmount／setTirePressure）依真實零件分類：輪胎加壓 REPAIR、減壓 SALVAGE，
-- 駕駛自己的客戶端（KI5 CTIS 自動補胎壓，DAMN_Armor_Client.lua:30-48）在容量內只要 DRIVE；其他零件（油箱等）FUEL，
-- setTirePressure 對非輪胎零件一律拒絕（原版只有輪胎會送）
local function amount(field, tireOnly)
    return function(p, a)
        local v = veh(a.vehicle)
        local part = v and v:getPartById(a.part) or nil
        local n = a[field]
        if part ~= nil and part:getWheelIndex() < 0 then
            if tireOnly then return nil, nil, "NOT_TIRE" end
            return { { vehicle = v, action = "FUEL" } }
        end
        if part == nil then return { { vehicle = v, action = tireOnly and "REPAIR" or "FUEL" } } end
        local ok = type(n) == "number" and n >= 0 and n <= part:getContainerCapacity()
        if ok and isDriver(p, v) then return { { vehicle = v, action = "DRIVE" } } end
        return { { vehicle = v, action = (ok and n >= part:getContainerContentAmount()) and "REPAIR" or "SALVAGE" } }
    end
end

-- 警示燈與警笛模式：關掉（mode 0）是修警示燈前的步驟，要 REPAIR；打開比照車內儀表板，要 DRIVE
local function lightbar(_, a)
    return { { vehicle = veh(a.vehicle), action = tonumber(a.mode) == 0 and "REPAIR" or "DRIVE" } }
end

-- 規則：(player, args) → 目標清單 { vehicle＝活車 或 rec＝帳本紀錄, action＝動作碼或清單 }, 放行後要做的事, 一律拒絕的原因。
-- 目標清單可帶 anchor／loaded／spawn（距離錨點）與 check（權限、距離都通過後的額外條件，回拒絕原因或 nil）
local RULES = {
    -- 原版 server/Vehicles/VehicleCommands.lua。用玩家目前座位的指令由座位防護涵蓋；UseMechanicsCheat 系列只有管理員能用
    vehicle = {
        fixPart = one("REPAIR"), -- :28-58 設定零件耐久
        setContainerContentAmount = amount("amount", false), -- :76-89（damnlib CTIS 也用它補胎壓，DAMN_Parts.lua:463-469）
        setTirePressure = amount("psi", true), -- :132-148
        setDoorOpen = function(_, a) -- :150-167（damnlib 另以同一指令同步門動畫，DAMN_Server.lua:37-44）
            local v = veh(a.vehicle)
            return { { vehicle = v, action = MVM.doorAction({ part = v and v:getPartById(a.part) or nil }) } }
        end,
        damageWindow = one("SALVAGE"), -- :169-185
        putKeyOnDoor = one("PASSENGER"), removeKeyFromDoor = one("PASSENGER"), -- :264-280
        attachTrailer = function(_, a) -- :399-411
            return { { vehicle = veh(a.vehicleA), action = "TOW" }, { vehicle = veh(a.vehicleB), action = "TOW" } }
        end,
        detachTrailer = tows("vehicle"), detachTrailerSpontaneous = tows("vehicle"), -- :413-429
        setHSV = one("REPAIR"), setSkinIndex = one("REPAIR"), setBloodIntensity = one("REPAIR"), -- :339-346,440-458
        remove = one("MANAGE"), -- :372-379 移除整台車
    },
    -- tsarslib common/media/lua/server/CommonTemplates/CommonCommands.lua
    commonlib = {
        loadVehicle = load("vehicle", true), -- :955-978
        launchVehicle = unload(true, "x", "y"), -- :980-1101（生車座標 x, y 由客戶端決定）
        installTuning = one("REPAIR"), uninstallTuning = one("SALVAGE"), -- :858-885
        bulbSmash = seated("vehicle", "SALVAGE"), -- :832-841（正常呼叫者是車內開燈失敗，ISCommonMenu.lua:469-486）
        cabinlightsOn = one("PASSENGER"), -- :887-903
        usePortableMicrowave = one("CARGO"), -- :935-953
    },
    -- tsarslib 42.17 server/Tuning2/ATATuning2Commands.lua:85-121（拆下的零件交給送指令的人）
    atatuning2 = { installTuning = one("REPAIR"), uninstallTuning = one("SALVAGE"), usePart = one("PASSENGER") },
    -- rSemiTruck server/MSW_Common_Commands.lua
    msw = {
        loadVehicle = load("vehicle", true), -- :2257-2331
        loadContainer = load("container", false), -- :2224-2255（W900 貨櫃也是車；轉移不還原 keyId 與見證，貨櫃之後就不受保護）
        launchVehicle = unload(true, "x", "y"), -- :2333-2493（:2384 以 args.x, args.y 生車）
        unloadContainer = unload(false, "x", "y", "z"), -- :2148-2222（:2159 以 args.x, args.y, args.z 生貨櫃）
    },
    -- rSemiTruck server/W900Commands.lua
    W900 = {
        applyArmorRepair = function(p, a) -- :209-229 設定零件耐久；正常呼叫者是駕駛客戶端的裝甲補償（ArmorSync.dispatchRepair）
            -- 駕駛（seat 0）只要 DRIVE 的條件：零件有 rLib 裝甲表（logic 是 rLib／RotatorsLib）、送的耐久等於表上的 condition
            -- （rLib.Vehicles.Armor.lua:136-205 只送這個值）；其他情況（含 rSemiTruck.lua 防撞桿吸收傷害的其他值）要 REPAIR
            local v = veh(a.vehicle)
            local part = v and v:getPartById(a.part) or nil
            local armor = part and part:getTable("armor") or nil
            local want = type(armor) == "table" and (armor.logic == "rLib" or armor.logic == "RotatorsLib") and tonumber(armor.condition) or nil
            local auto = want ~= nil and a.condition == want and isDriver(p, v)
            return { { vehicle = v, action = auto and "DRIVE" or "REPAIR" } }
        end,
        setTrailerPhysicsDisabled = one("TOW"), -- :185-207
        toggleFreezer = one("CARGO"), toggleFridge = one("CARGO"), -- :66-183
        -- 卡住的車往上推並解開拖掛：目前的 Workshop 版（3409472393，2026-10-03 更新）只有客戶端送
        -- （client/VehicleEnterFix.lua:90），伺服器沒有處理器；09-24 舊版 W900Commands.lua:203 起有，只看 5 格與
        -- canPlayerUseMoveUp。預防作者加回來：能開或能拖的人可用
        moveVehicleImpulse = one({ "DRIVE", "TOW" }),
    },
    -- rSemiTruck server/rLib.Commands.lua:7-45（分派 Server_<cmd>，:61-88）；正常呼叫者是拖掛後同步拖車（rSemiTruck.lua:332-381）
    rLib = { SetVehicleBattery = on("vehicleId", "TOW"), SetVehicleHeadlights = on("vehicleId", "TOW") },
    -- damnlib 42.20 server/Commands
    that_damn_lib = {
        -- DAMN_Data.lua:45-64：改零件 modData（含本 MOD 見證、MSW 倉儲參照），沒有正常客戶端呼叫者 → 一律拒絕
        setPartModData = function() return nil, nil, "REFUSED" end,
        silentPartInstall = function(_, a) -- DAMN_Parts.lua:14-63：把零件換成指定的新物品（_vehicle 由 _vehicleId 解析，DAMN_Server.lua:24-34）
            return { { vehicle = veh(a._vehicleId), action = "REPAIR" } }
        end,
        updatePartConditions = on("_vehicleId", "REPAIR"), -- DAMN_Armor.lua:52-74：設定零件耐久
        savePartsCondition = on("_vehicleId", "REPAIR"), -- DAMN_Armor.lua:14-50
    },
    -- Vehicle Repair Overhaul（Workshop 2757712197）42/media/lua/server：修零件、重組引擎、修暖氣與警示燈都直接改零件耐久
    VRO_vehicle = { doFix = on("vehicleId", "REPAIR") }, -- VRO_VehicleCommands.lua:500-614
    EER_vehicle = { rebuildEngine = on("vehicleId", "REPAIR") }, -- EER_VehicleCommands.lua:50-117（也改引擎品質）
    EHR_vehicle = { repairHeater = one("REPAIR") }, -- EHR_VehicleCommands.lua:51-129
    ELR_vehicle = {
        repairLightbar = one("REPAIR"), -- ELR_VehicleCommands.lua:52-111
        -- :113-132；正常呼叫者是修警示燈前在車外關燈與警笛（ELRTurnOffLightbar.lua:51-52）
        setLightbarLightsMode = lightbar, setLightbarSirenMode = lightbar,
    },
}
CG.RULES = RULES

local function once(key, msg)
    if R.logged[key] then return end
    R.logged[key] = true
    MVM.log(msg)
end

-- (x, y, z) 在車 o 的車身 d 格內、同一樓層（z＝nil 不比樓層）；NaN 一律不算近。量到車身矩形（引擎 getClosestPointOnExtents：
-- 腳本 extents＋centerOfMassOffset、依車身朝向，BaseVehicle.java:4971-4997），不是物理原點：半掛拖車的原點在車身後段，
-- tsarslib 拖車選單與引擎自動脫鉤都從牽引車駕駛座送（W900＋貨櫃拖車掛正時駕駛座離拖車原點 9.9～11.4 格、離車身 1.3～2.7 格）。
-- 指令防火牆、Autotsar adapter、打車回報與綁定距離（Server.lua near、F.findLoaded）共用
local closest = nil
function CG.within(o, x, y, z, d)
    if type(x) ~= "number" or type(y) ~= "number" or x ~= x or y ~= y or o == nil then return false end
    if z ~= nil and (type(z) ~= "number" or math.floor(z) ~= math.floor(o:getZ())) then return false end
    closest = closest or Vector2f.new() -- Java 的輸出參數，值不用
    return o:getClosestPointOnExtents(x, y, closest) <= d * d
end
local function near(p, o, d) return CG.within(o, p:getX(), p:getY(), p:getZ(), d) end

-- 回 allow, reason, oid
function CG.decide(rule, module, command, player, args)
    local O = MVM.Own
    local targets, onAllow, refuse = rule(player, args)
    if refuse then return false, refuse end
    if targets == nil or O.state() == nil then return true end
    local ctx = { op = "CMD:" .. module .. "." .. command }
    local guarded = false
    for _, t in ipairs(targets) do
        if t.vehicle == BAD then return false, "BAD_ID" end
        local acts = type(t.action) == "string" and { t.action } or t.action
        local ok, reason, rec
        for _, act in ipairs(acts) do
            if t.rec then ok, reason, rec = O.allowsRecord(player, t.rec, act, ctx)
            elseif t.vehicle then ok, reason, rec = O.canUse(player, t.vehicle, act, ctx) end
            if ok then break end
        end
        if rec ~= nil then
            guarded = true
            if not ok then return false, reason, rec.oid end
            if t.vehicle and not near(player, t.vehicle, CG.NEAR) then return false, "TOO_FAR", rec.oid end
        end
    end
    -- 有受保護目標時以載具（拖車）為錨點：人要在拖車附近（拖車沒綁定也一樣）、被裝的車與生車座標要在拖車附近
    local anchor, spawn = targets.anchor, targets.spawn
    if guarded and anchor then
        if not near(player, anchor, CG.NEAR) then return false, "TOO_FAR" end
        if targets.loaded and not CG.within(anchor, targets.loaded:getX(), targets.loaded:getY(), targets.loaded:getZ(), CG.LAUNCH_NEAR) then
            return false, "TOO_FAR"
        end
        if spawn and not CG.within(anchor, spawn[1], spawn[2], spawn[3], CG.LAUNCH_NEAR) then return false, "BAD_POS" end
    end
    local why = targets.check and targets.check() or nil
    if why then return false, why end
    if onAllow then onAllow() end
    if MVM.Parked then
        for _, t in ipairs(targets) do if t.vehicle then MVM.Parked.touch(t.vehicle) end end
    end
    return true
end

-- 消掉請求：先收集鍵再清（不邊 pairs 邊改）。原版、damnlib、Vehicle Repair Overhaul 不先檢查欄位就 getVehicleById，收到 nil 會在 Java 端報錯：
-- id 欄位改成 -1（VehicleIDMap.get 對負數回 null，VehicleIDMap.java:65-67，處理器安靜結束）；rLib 先 assert 其他欄位型別，
-- 只改 id 不清空
local NEG_IDS = { vehicle = { "vehicle", "vehicleA", "vehicleB" }, that_damn_lib = { "_vehicleId", "vehicle" }, rLib = { "vehicleId" },
    VRO_vehicle = { "vehicleId" }, EER_vehicle = { "vehicleId" }, EHR_vehicle = { "vehicle" }, ELR_vehicle = { "vehicle" } }
local KEEP = { rLib = true }
function CG.neutralize(module, args)
    if not KEEP[module] then
        local keys = {}
        for k in pairs(args) do keys[#keys + 1] = k end
        for _, k in ipairs(keys) do args[k] = nil end
    end
    for _, k in ipairs(NEG_IDS[module] or {}) do args[k] = -1 end
end

-- guard：武器打車被擋（砸窗、CG.onHit）時這台車是否在停車保全布防中（客戶端據此顯示「保全擋下」或「別人的車」）
local function notify(player, label, reason, oid, guard)
    local S = MVM.Srv
    if S == nil or not instanceof(player, "IsoPlayer") then return end
    local key, t = tostring(player:getUsername()), getTimestampMs()
    if t - (R.notified[key] or 0) < CG.NOTIFY_MS then return end
    R.notified[key] = t
    S.send(player, "enforcement", { action = label, reason = reason, oid = oid, guard = guard })
end

function CG.onCommand(module, command, player, args)
    local rules = RULES[module]
    local rule = rules and rules[command]
    if rule == nil or type(args) ~= "table" then return end
    local O = MVM.Own
    if O == nil then return once("NO_LEDGER", "command gate inactive: ownership system not loaded") end
    local ok, allow, reason, oid = pcall(CG.decide, rule, module, command, player, args)
    local label = "CMD:" .. module .. "." .. command
    if not ok then
        once("ERR " .. label, "command gate error (refused) " .. label .. ": " .. tostring(allow))
        allow, reason, oid = false, "GATE_ERROR", nil
    end
    if allow then return end
    CG.neutralize(module, args)
    reason = reason or "NOT_AUTHORIZED"
    O.deny(O.principal(player) or ("?" .. tostring(player and player:getUsername())), label, oid, reason)
    -- 車主通知的節流在 ParkedGuard（同一台車＋同一攻擊者），這裡每次拒絕都要問
    local guard = nil
    if label == "CMD:vehicle.damageWindow" then guard = MVM.Parked and MVM.Parked.onAttack(player, oid) or false end
    notify(player, label, reason, oid, guard)
end

-- 打到沒有車窗的零件（引擎蓋、後車廂、車燈、輪胎、窗已破或搖下的門）時原版不送任何指令，伺服器處理 PlayerHitVehicle
-- 也沒有 Lua 事件（guards.md「攻擊通知」）：攻擊者客戶端看到自己的預測傷害就送 hitReport（ClientGuards）。
-- 範圍＝武器射程＋CG.NEAR，距離量到車身（CG.within）
function CG.hitReach(weapon) return CG.NEAR + weapon:getMaxRange() end

-- hitReport 只能報自己（通知寫的是送的人）：手上有武器、車在範圍內同一樓層、是綁定的車而自己不能拆零件（同 damageWindow
-- 的 SALVAGE）才算數。之後照砸窗被擋處理：車主通知（ParkedGuard 節流）、提示攻擊者
function CG.onHit(player, vehicleId)
    local O, v, w = MVM.Own, getVehicleById(vehicleId), player:getPrimaryHandItem()
    if v == nil or O.state() == nil or not instanceof(w, "HandWeapon") or not near(player, v, CG.hitReach(w)) then return end
    local _, rec = O.lookup(v)
    if rec == nil then return end
    local ok, reason = O.allowsRecord(player, rec, "SALVAGE")
    if ok then return end
    notify(player, "HIT", reason, rec.oid, MVM.Parked and MVM.Parked.onAttack(player, rec.oid) or false)
end

-- 只在伺服器註冊一次：Lua 重載時換掉 MVM.CommandGate，已註冊的轉接呼叫新版
local first = MVM.CommandGate == nil
MVM.CommandGate = CG
if first and isServer() then
    Events.OnClientCommand.Add(function(module, command, player, args) MVM.CommandGate.onCommand(module, command, player, args) end)
end
