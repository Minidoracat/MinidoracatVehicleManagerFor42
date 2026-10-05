--[[
煙霧測試：用假的 PZ 全域載入**真正的** MOD Lua（API／OwnershipSystem／Server／Client），跑行為情境並斷言結果。

    lua scripts/smoke_harness.lua        （repo 根目錄執行；標準 Lua 5.x 即可）

限制：這是標準 Lua，不是 Kahlua；引擎行為（GOS 落盤、封包、Faction 真實物件）只能靠實機 E2E。
寫情境的原則：安全邊界要有反面斷言；新防線先植入違規證明它會抓。
]]

local MEDIA = "MOD/MinidoracatVehicleManagerFor42/Contents/mods/MinidoracatVehicleManagerFor42/42/media/lua"

-- ===== 假的 PZ 全域 =====
local nowMs = 5000000
local logLines = {}
local serverMode = true -- false＝SP（isServer false）

function getTimestampMs() return nowMs end
function isClient() return false end
function isServer() return serverMode end
function writeLog(_, text) logLines[#logLines + 1] = text end
function getText(key, ...)
    local args = { ... }
    if #args == 0 then return key end
    for i, v in ipairs(args) do args[i] = tostring(v) end
    return key .. "(" .. table.concat(args, ",") .. ")"
end
local realPrint = print
print = function(...) end -- MOD 的 log 不洗版；測試輸出走 out()
local function out(s) realPrint(s) end

local uuidN = 0
function getRandomUUID() uuidN = uuidN + 1; return string.format("uuid-%08d", uuidN) end

local handlers = {}
Events = setmetatable({}, { __index = function(t, name)
    local ev = { Add = function(fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end,
        Remove = function(fn)
            for i, f in ipairs(handlers[name] or {}) do if f == fn then table.remove(handlers[name], i) return end end
        end }
    rawset(t, name, ev)
    return ev
end })
local function fire(name, ...) for _, fn in ipairs(handlers[name] or {}) do fn(...) end end

local function javaList(items)
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end,
        iterator = function()
            local i = 0
            return { hasNext = function() return i < #items end, next = function() i = i + 1; return items[i] end }
        end }
end

-- GOS：照原版順序——new() 內 modData（含存檔 state）已就緒、呼叫 initSystem，
-- instance 要等 new() 回傳後才由 OnSGlobalObjectSystemInit 設定（SGlobalObjectSystem.lua:11-28,246）
local sysKeys, pendingDisk = nil, nil
SGlobalObjectSystem = { new = function(cls, name)
    local o = setmetatable({ name = name, state = pendingDisk, system = {
        setModDataKeys = function(_, k) sysKeys = k end, setObjectModDataKeys = function() end,
        setObjectSyncKeys = function() end } }, cls)
    o:initSystem()
    return o
end, initSystem = function() end, RegisterSystemClass = function(cls) SGlobalObjectSystem.registered = cls end }
-- 分片系統：registerSystem(name) 回傳帶 modData 的系統；gosDisk＝上次存檔（每系統只存白名單鍵）
-- （主 chunk 區域變數已近 200 上限：分片 mock 收在單一表 GOS）
local GOS = { disk = {}, live = {} }
function GOS.copy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = GOS.copy(v) end
    return c
end
SGlobalObjects = { others = 5, getSystemCount = function()
    local n = SGlobalObjects.others + 1 -- 原版 5 個＋主帳本
    for _ in pairs(GOS.live) do n = n + 1 end
    return n
end, registerSystem = function(name)
    if GOS.live[name] then return GOS.live[name] end
    local sys = { md = GOS.copy(GOS.disk[name] or {}), keys = nil }
    function sys:setModDataKeys(k) self.keys = k end
    function sys:setObjectModDataKeys() end
    function sys:setObjectSyncKeys() end
    function sys:getModData() return self.md end
    GOS.live[name] = sys
    return sys
end }
function GOS.save()
    for name, sys in pairs(GOS.live) do
        local out = {}
        for _, k in ipairs(sys.keys or {}) do out[k] = GOS.copy(rawget(sys.md, k)) end
        GOS.disk[name] = out
    end
end

function SGlobalObjectSystem:derive(name)
    local cls = setmetatable({ Type = name }, { __index = self })
    cls.__index = cls
    return cls
end

local gmd = {}
ModData = { getOrCreate = function(key) gmd[key] = gmd[key] or {}; return gmd[key] end,
    exists = function(key) return gmd[key] ~= nil end, get = function(key) return gmd[key] end,
    remove = function(key) gmd[key] = nil end }
local activeMods = {}
function getActivatedMods() return { contains = function(_, id) return activeMods[id] == true end } end
local files = {}
function getServerName() return "servertest" end
function getWorld() return { getWorld = function() return "world" end } end
function getFileWriter(path, _, append)
    local buf = append and files[path] or {}
    files[path] = buf
    return { write = function(_, s) buf[#buf + 1] = s end, close = function() end } end
function getFileReader(path)
    local buf = files[path]
    if buf == nil then return nil end
    local lines = {}
    for line in table.concat(buf):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    local i = 0
    return { readLine = function() i = i + 1; return lines[i] end, close = function() end }
end
function cacheFileExists(path) return files[path] ~= nil end -- 與 getFileReader 同一個 Lua 目錄根

SandboxVars = { MinidoracatVehicleManager = { ClaimsPerPlayer = 3, MaxMembersPerVehicle = 6,
    ClaimDistance = 2.5, AllowFactionShare = true, InactivityReleaseDays = 0,
    ReleaseFinalizeHours = 24, TombstoneRetentionDays = 14, NameMaxBytes = 32, ParkedGuard = 2, GuardSlotsPerPlayer = 1 } }
local SB = SandboxVars.MinidoracatVehicleManager
-- SandboxOptions：set 只改 Java 端的值，toLua 才投影到 SandboxVars；saveServerLuaFile 回 SBOX.saveOk，成功才記下「檔案」內容
SBOX = { values = {}, saveOk = true, saves = 0, sets = 0, file = nil }
function getSandboxOptions()
    return { set = function(_, name, v) SBOX.sets = SBOX.sets + 1; SBOX.values[name] = v end,
        toLua = function()
            for name, v in pairs(SBOX.values) do
                local page, key = name:match("^(.-)%.(.+)$")
                SandboxVars[page][key] = v
            end
        end,
        saveServerLuaFile = function(_, server)
            SBOX.saves = SBOX.saves + 1
            if SBOX.saveOk then
                local page = SandboxVars.MinidoracatVehicleManager
                SBOX.file = { server = server, ClaimsPerPlayer = page.ClaimsPerPlayer, InactivityReleaseDays = page.InactivityReleaseDays,
                    ParkedGuard = page.ParkedGuard, GuardSlotsPerPlayer = page.GuardSlotsPerPlayer }
            end
            return SBOX.saveOk
        end }
end

local serverOpts = {}
function getServerOptions() return { getBoolean = function(_, k) return serverOpts[k] == true end } end
Capability = { ManipulateVehicle = "ManipulateVehicle" }
function checkPermissions(p, cap) return p.admin == true and cap == "ManipulateVehicle" end
local steamActive = false -- true＝Steam 伺服器（身分要對上綁定的 SteamID）
function getSteamModeActive() return steamActive end
-- Kahlua 的數字都是 double：tonumber 是 Double.parseDouble（KahluaUtil.java:293），Long 轉 Lua 也是 double。
-- Lua 5.4 對整數字串回 64 位元整數，SteamID 這種超過 2^53 的值要照 Kahlua 捨入，身分比對才測得到捨入
local rawTonumber = tonumber
function tonumber(v, base)
    local n = rawTonumber(v, base)
    if math.type(n) == "integer" and (n > 2 ^ 53 or n < -2 ^ 53) then return n + 0.0 end
    return n
end

-- 陣營
local factions = {}
local function newFaction(name, owner, members)
    local f = { name = name, owner = owner, members = members or {} }
    function f:getName() return self.name end
    function f:getOwner() return self.owner end
    function f:isMember(u) for _, m in ipairs(self.members) do if m == u then return true end end return false end
    function f:getPlayers() return javaList(self.members) end
    factions[#factions + 1] = f
    return f
end
Faction = { getFaction = function(name) for _, f in ipairs(factions) do if f.name == name then return f end end end,
    getFactions = function() return javaList(factions) end }

-- 玩家
local online, outbox = {}, {}
local function player(name, x, y, opts)
    local p = { _cls = "IsoPlayer", name = name, x = x or 0, y = y or 0, z = 0, num = 0, admin = opts and opts.admin,
        sid = opts and opts.sid or 0 }
    function p:getSteamID() return self.sid + 0.0 end
    function p:getUsername() return self.name end
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:getZ() return self.z end
    function p:getPlayerNum() return self.num end
    function p:getVehicle() return self.vehicle end
    function p:sendObjectChange(kind) self.objectChanges = (self.objectChanges or 0) + 1; self.lastChange = kind end
    function p:getInventory() return { haveThisKeyId = function() return self.hasKey == true end } end
    outbox[name] = outbox[name] or {}
    online[#online + 1] = p
    return p
end
function getOnlinePlayers() return javaList(online) end
function getSpecificPlayer(i) return online[i + 1] end
function sendServerCommand(p, module, command, payload)
    outbox[p.name][#outbox[p.name] + 1] = { module = module, command = command, payload = payload }
end

-- 車輛
local world, vehicleList = {}, {}
local transmits = 0
local tx = {}
local function door()
    local d = { locked = true, open = false }
    function d:isLocked() return self.locked end
    function d:setLocked(b) self.locked = b end
    function d:isOpen() return self.open end
    function d:setOpen(b) self.open = b end
    return d
end
local function part(id)
    -- cond／dur／item／window：停車保全用（VehiclePart 的 condition、durability、原件、車窗）；預設 durability 0＝保全不碰
    local pt = { _cls = "VehiclePart", id = id, md = {}, cond = 100, dur = 0 }
    if id:find("Door", 1, true) then pt.door = door() end
    function pt:getId() return self.id end
    function pt:getVehicle() return self.vehicle end
    function pt:getDoor() return self.door end
    function pt:hasModData() return true end
    function pt:getModData() return self.md end
    function pt:getCondition() return self.cond end
    function pt:setCondition(c) self.cond = c end
    function pt:getInventoryItem() return self.item end
    -- 換件走 doInventoryItemStats：durability 重設成新件的值（VehiclePart.java）
    function pt:setInventoryItem(it) self.item = it; if it and it.dur then self.dur = it.dur end end
    function pt:getDurability() return self.dur end
    function pt:setDurability(d) if d > 0 then self.dur = d end end -- Java 不收 <= 0
    function pt:getWindow() return self.window end
    return pt
end
do -- InventoryItemFactory.CreateItem 的替身：每件新 id；dur＝裝上零件時 doInventoryItemStats 給的 durability
    local n = 90000
    function instanceItem(full, dur)
        n = n + 1
        local it = { id = n, full = full, cond = 100, dur = dur or 3 }
        function it:getID() return self.id end
        function it:getFullType() return self.full end
        function it:setCondition(c) self.cond = c end
        function it:getCondition() return self.cond end
        return it
    end
end
local function vehicle(id, sqlId, keyId, script, x, y, partIds)
    local v = { id = id, sqlId = sqlId, keyId = keyId, script = script or "Base.CarNormal", x = x or 0, y = y or 0, z = 0,
        parts = {}, order = {}, removed = false }
    for _, pid in ipairs(partIds or { "Engine", "Battery", "DoorFrontLeft" }) do
        local pt = part(pid); pt.vehicle = v; v.parts[pid] = pt; v.order[#v.order + 1] = pt
    end
    v.seats, v.maxPass = {}, 4
    -- 車下的格子：碎玻璃（IsoBrokenGlass）與移除紀錄
    v.square = { removed = {} }
    function v.square:getBrokenGlass() return self.glass end
    function v.square:transmitRemoveItemFromSquare(o) self.removed[#self.removed + 1] = o; if self.glass == o then self.glass = nil end end
    function v:getSquare() return self.square end
    function v:getMaxPassengers() return self.maxPass end
    function v:getCharacter(seat) return self.seats[seat] end
    local function count(kind) tx[kind] = (tx[kind] or 0) + 1 end
    function v:transmitPartItem() count("item") end
    function v:transmitPartCondition() count("condition") end
    function v:transmitPartDoor() count("door") end
    function v:transmitPartWindow() count("window") end
    function v:tryStartEngine(haveKey) self.started = haveKey end
    function v:setPreviouslyEntered(b) self.previouslyEntered = b end
    function v:getSeat(chr) for i, c in pairs(self.seats) do if c == chr then return i end end return -1 end
    function v:isDriver(chr) return self.seats[0] == chr end
    function v:exit(chr) for i, c in pairs(self.seats) do if c == chr then self.seats[i] = nil end end chr.vehicle = nil end
    function v:getVehicleTowing() return self.towing end
    function v:breakConstraint() self.broken = (self.broken or 0) + 1 end
    function v:getId() return self.id end
    function v:getSqlId() return self.sqlId end
    function v:getKeyId() return self.keyId end
    function v:getScriptName() return self.script end
    function v:getX() return self.x end
    function v:getY() return self.y end
    function v:getZ() return self.z end
    function v:getPartById(pid) return self.parts[pid] end
    function v:getPartCount() return #self.order end
    function v:getPartByIndex(i) return self.order[i + 1] end
    function v:transmitPartModData() transmits = transmits + 1; count("moddata") end
    function v:isRemovedFromWorld() return self.removed end
    function v:getVehicleTowedBy() return self.towedBy end
    function v:hasModData() return self.bodyMd ~= nil end
    function v:getModData() self.bodyMd = self.bodyMd or {}; return self.bodyMd end
    function v:transmitModData() count("body") end
    -- 經 Java 方法表呼叫（伺服器包 permanentlyRemove 的方法表，見 VEHICLE_METHODS）
    function v:permanentlyRemove() return VEHICLE_METHODS.permanentlyRemove(self) end
    world[id] = v
    vehicleList[#vehicleList + 1] = v
    return v
end
function getVehicleById(id) return world[id] end
function getCell() return { getVehicles = function() return javaList(vehicleList) end } end

-- 原版 timed action 與 UI（server 包 ISRemoveBurntVehicle，client 包選單）
-- BaseVehicle 的 Java 方法表（__classmetatables[BaseVehicle.class].__index）：OwnershipSystem 載入時包 permanentlyRemove
VEHICLE_METHODS = { permanentlyRemove = function(v) v.removed = true end }
BaseVehicle, __classmetatables = { class = "BaseVehicleClass" }, { BaseVehicleClass = { __index = VEHICLE_METHODS } }
ISRemoveBurntVehicle = { complete = function(self) self.vehicle:permanentlyRemove(); return true end }
ISBaseTimedAction = { derive = function(self, name) local c = setmetatable({ Type = name }, { __index = self }); c.__index = c; return c end,
    new = function(cls, chr) return setmetatable({ character = chr }, cls) end, perform = function() end }
ISVehicleMenu = { FillMenuOutsideVehicle = function() end }
HaloTextHelper = { addBadText = function() end, addGoodText = function() end }
local clientSent = {}
function sendClientCommand(p, module, command, args) clientSent[#clientSent + 1] = { command = command, args = args } end

-- 原版 vehicle timed action 的假類別：每個 lifecycle 只記呼叫次數（complete 回 true）
local vanillaCalls = {}
local function vclass(name, stages, impl)
    local c = { Type = name }
    for _, st in ipairs(stages) do
        c[st] = function(self)
            vanillaCalls[name .. "." .. st] = (vanillaCalls[name .. "." .. st] or 0) + 1
            if impl and impl[st] then return impl[st](self) end
            if st == "complete" then return true end
        end
    end
    _G[name] = c
end
for _, n in ipairs({ "ISInstallVehiclePart", "ISUninstallVehiclePart", "ISFixVehiclePartAction", "ISRepairEngine", "ISRepairLightbar",
    "ISTakeEngineParts", "ISHotwireVehicle", "ISShutOffVehicleEngine", "ISLockDoors", "ISLockVehicleDoor",
    "ISOpenVehicleDoor", "ISCloseVehicleDoor", "ISOpenCloseVehicleWindow", "ISAddAnimalInTrailer", "ISRemoveAnimalFromTrailer" }) do
    vclass(n, { "update", "complete" })
end
for _, n in ipairs({ "ISAddGasolineToVehicle", "ISTakeGasolineFromVehicle" }) do vclass(n, { "serverStart", "update", "complete", "serverStop" }) end
for _, n in ipairs({ "ISRefuelFromGasPump", "ISDeflateTire", "ISInflateTire" }) do vclass(n, { "update", "complete", "serverStop" }) end
vclass("ISSmashWindow", { "serverStart", "update", "complete" })
vclass("ISSmashVehicleWindow", { "complete" })
vclass("ISStartVehicleEngine", { "update", "complete" }, { complete = function(a) a.character:getVehicle():tryStartEngine(false); return true end })
vclass("ISUnlockVehicleDoor", { "update", "complete" })
IsoObjectChange = { EXIT_VEHICLE = "EXIT_VEHICLE" }
function instanceof(o, cls) return type(o) == "table" and o._cls == cls end

local STUB = { ["Map/SGlobalObjectSystem"] = true }
local loaded = {}
function require(name)
    if loaded[name] or STUB[name] or name:find("/", 1, true) then return true end
    loaded[name] = true
    for _, dir in ipairs({ "shared", "server", "client" }) do
        local chunk = loadfile(MEDIA .. "/" .. dir .. "/" .. name .. ".lua")
        if chunk then chunk() return true end
    end
    error("require 找不到: " .. name)
end
require("MinidoracatVehicleManager_API")
require("MinidoracatVehicleManager_OwnershipSystem")
require("MinidoracatVehicleManager_Server")
require("MinidoracatVehicleManager_ActionGuards")
require("MinidoracatVehicleManager_Tracking")
require("MinidoracatVehicleManager_Migration")
require("MinidoracatVehicleManager_Export")
require("MinidoracatVehicleManager_Notices")
require("MinidoracatVehicleManager_Economy")
require("MinidoracatVehicleManager_PaidSlots")
require("MinidoracatVehicleManager_ClaimTags")
require("MinidoracatVehicleManager_RentLock")
require("MinidoracatVehicleManager_ParkedGuard")
require("MinidoracatVehicleManager_CommandGate") -- shared：真遊戲排在所有 server 檔之前；本 harness 的第三方假處理器在情境內才註冊
BaseVehicle, __classmetatables = nil, nil
local MVM = MinidoracatVehicleManager
local O, S = MVM.Own, MVM.Srv
local G = MVM.Guards
local Ledger = SGlobalObjectSystem.registered

-- ===== 測試工具 =====
local failures, passes = 0, 0
local function check(ok, label)
    if ok then passes = passes + 1; out("  PASS  " .. label)
    else failures = failures + 1; out("  FAIL  " .. label) end
end

-- 新世界；diskState＝上次存檔的主系統 state（模擬重啟），keepGmd＝保留 GlobalModData，keepGos＝保留分片存檔
local function boot(diskState, keepGmd, keepGos)
    if not keepGmd then gmd = {} end
    if not keepGos then GOS.disk = {} end
    GOS.live = {}
    online, outbox, world, vehicleList, factions, logLines = {}, {}, {}, {}, {}, {}
    serverOpts, transmits = {}, 0
    for k in pairs(O.R.denyAgg) do O.R.denyAgg[k] = nil end
    O.R.factionRefs, O.R.suspectKeys, O.R.lastMaintMs, O.R.lastScanMs, O.R.overrides = {}, {}, 0, 0, {}
    S.R.acks, S.R.rate, S.R.attempts, S.R.streams, S.R.unverified, S.R.recheck = {}, {}, {}, {}, {}, {}
    S.R.pub, S.R.sandboxSeen = nil, nil
    O.R.identityConflicts, steamActive = nil, false
    G.R.intents, G.R.due, G.R.lastRun = {}, {}, 0
    MVM.Tracking.last, MVM.Tracking.seat, MVM.Tracking.lastRun = {}, {}, 0
    for k in pairs(MVM.Parked.R) do
        local v = MVM.Parked.R[k]
        if type(v) == "table" then MVM.Parked.R[k] = {} elseif type(v) == "number" then MVM.Parked.R[k] = 0 end
    end
    MVM.Parked.R.memo, MVM.RentLock.watch, MVM.Econ.guardFresh = nil, {}, {}
    for k in pairs(tx) do tx[k] = nil end
    for k in pairs(vanillaCalls) do vanillaCalls[k] = nil end
    Ledger.instance = nil
    pendingDisk = diskState
    Ledger.instance = Ledger:new()
    return Ledger.instance
end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deepcopy(v) end
    return c
end

-- 舊版單檔格式的存檔快照（大表都在主 state 內）：boot 時走「舊檔搬進分片」路徑
function GOS.snapshot()
    local flat = GOS.copy(O.R.meta)
    for _, m in ipairs(O.SHARDED_MAPS) do flat[m] = GOS.copy(O.state()[m]) end
    return flat
end

local function lastOf(p, command)
    local box = outbox[p.name]
    for i = #box, 1, -1 do if box[i].command == command then return box[i].payload end end
    return nil
end

local function cmd(p, command, args, requestId)
    nowMs = nowMs + 300
    args = args or {}
    if args.protocol == nil then args.protocol = MVM.PROTOCOL end
    if requestId ~= false and args.requestId == nil then args.requestId = requestId or getRandomUUID() end
    local before = #outbox[p.name]
    fire("OnClientCommand", MVM.MODULE, command, p, args)
    for i = #outbox[p.name], before + 1, -1 do
        if outbox[p.name][i].command == "mutationAck" then return outbox[p.name][i].payload end
    end
    return nil
end

local function claim(p, v)
    local a = cmd(p, "prepareClaim", { vehicleId = v.id })
    if not (a and a.ok) then return a end
    return cmd(p, "claim", { claimAttemptId = a.claimAttemptId })
end

local function records()
    local n = 0
    for _ in pairs(O.state().recordsByOid) do n = n + 1 end
    return n
end

local function rec(oid) return O.state().recordsByOid[oid] end
local function witness(v, pid) return rawget(v.parts[pid or "Engine"].md, "MinidoracatVehicleManager") end

-- ===== 情境 =====
out("情境 1：prepare／commit claim 與 GOS 只存 state")
boot()
local A = player("alice", 0, 0)
local car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
local ack = claim(A, car)
check(ack and ack.ok and rec(ack.oid).ownerUser == "alice", "claim 成功，owner＝server username")
check(sysKeys and #sysKeys == 1 and sysKeys[1] == "state", "GOS 只白名單 state")
check(Ledger.instance:getInitialStateForClient() == nil, "client initial state 為 nil")
check(witness(car).oid == ack.oid, "見證寫在 Engine 零件 modData")
check(rawget(car, "MinidoracatVehicleManager") == nil, "不寫車身 modData")
local r1 = rec(ack.oid)
check(r1.sqlIdHint == 101 and r1.keyIdHint == 5001 and r1.vehicleScript == "Base.CarNormal", "record 記三個 native 欄位")
check(logLines[#logLines]:find("\tCLAIM\t", 1, true) ~= nil, "寫 CLAIM audit")

out("情境 2：prepared target 被移除／runtime id 重用／身分改變")
boot()
A = player("alice", 0, 0)
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
local a = cmd(A, "prepareClaim", { vehicleId = 1 })
local impostor = vehicle(1, 102, 5002, "Base.CarNormal", 1, 1) -- 同 runtime id 被另一台車取代
check(cmd(A, "claim", { claimAttemptId = a.claimAttemptId }).reason == "ATTEMPT_STALE_VEHICLE", "runtime id 重用 → 拒絕")
check(records() == 0 and witness(impostor) == nil, "被重用的車沒有被綁")
world[1] = car
a = cmd(A, "prepareClaim", { vehicleId = 1 })
car.keyId = 9999
check(cmd(A, "claim", { claimAttemptId = a.claimAttemptId }).reason == "ATTEMPT_IDENTITY_CHANGED", "native 欄位改變 → 拒絕")
car.keyId = 5001
a = cmd(A, "prepareClaim", { vehicleId = 1 })
nowMs = nowMs + 31000
check(cmd(A, "claim", { claimAttemptId = a.claimAttemptId }).reason == "ATTEMPT_EXPIRED", "attempt 過期 → 拒絕")
local B = player("bob", 0, 0)
a = cmd(A, "prepareClaim", { vehicleId = 1 })
check(cmd(B, "claim", { claimAttemptId = a.claimAttemptId }).reason == "ATTEMPT_UNKNOWN", "別人的 attempt 不能用")
check(records() == 0, "以上全部 0 mutation")

out("情境 3：遠距／不存在／超 quota／不可綁定")
boot()
A = player("alice", 0, 0)
local far = vehicle(1, 101, 5001, "Base.CarNormal", 10, 10)
check(cmd(A, "prepareClaim", { vehicleId = 1 }).reason == "TOO_FAR", "超距 → TOO_FAR")
check(cmd(A, "prepareClaim", { vehicleId = 77 }).reason == "NO_SUCH_VEHICLE", "不存在 → NO_SUCH_VEHICLE")
local burnt = vehicle(2, 102, 5002, "Base.CarNormalBurnt", 1, 1, {})
check(cmd(A, "prepareClaim", { vehicleId = 2 }).reason == "NOT_CLAIMABLE", "零零件燒毀車 → NOT_CLAIMABLE")
local towed = vehicle(3, 103, 5003, "Base.CarNormal", 1, 1)
towed.towedBy = far
check(cmd(A, "prepareClaim", { vehicleId = 3 }).reason == "NOT_CLAIMABLE_TOWED", "被拖中 → 拒絕")
SB.ClaimsPerPlayer = 1
local c1 = vehicle(4, 104, 5004, "Base.CarNormal", 1, 1)
local c2 = vehicle(5, 105, 5005, "Base.CarNormal", 1, 1)
check(claim(A, c1).ok, "quota 內可綁")
check(cmd(A, "prepareClaim", { vehicleId = 5 }).reason == "QUOTA_EXCEEDED", "超 quota → QUOTA_EXCEEDED")
check(records() == 1 and witness(c2) == nil, "超 quota 0 mutation")
SB.ClaimsPerPlayer = 3
check(claim(player("bob", 1, 1), c1).reason == "ALREADY_CLAIMED", "已綁定 → ALREADY_CLAIMED（不透露 owner）")

out("情境 4／5：requestId 與冪等")
boot()
A = player("alice", 0, 0)
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
a = cmd(A, "prepareClaim", { vehicleId = 1 })
local first = cmd(A, "claim", { claimAttemptId = a.claimAttemptId }, "req-same-0001")
local again = cmd(A, "claim", { claimAttemptId = a.claimAttemptId }, "req-same-0001")
check(first.ok and again.ok and again.duplicate and again.oid == first.oid, "相同 requestId 回原 ACK")
check(records() == 1, "只 mutation 一次")
check(cmd(A, "claim", { claimAttemptId = a.claimAttemptId }, "req-other-0002").reason == "ATTEMPT_UNKNOWN", "不同 requestId 由語意冪等擋下")
check(cmd(A, "reportLost", { expectedOid = first.oid }, false).reason == "BAD_REQUEST_ID", "缺 requestId → 拒絕")
check(cmd(A, "reportLost", { expectedOid = first.oid }, string.rep("x", 65)).reason == "BAD_REQUEST_ID", "過長 requestId → 拒絕")
check(rec(first.oid).recordState == "ACTIVE", "被拒的請求沒有改狀態")

out("情境 6：偽造欄位與協定")
local forged = cmd(A, "rename", { expectedOid = first.oid, expectedEpoch = rec(first.oid).epoch, name = "x", ownerUser = "mallory" })
check(forged.reason == "BAD_ARGS" and rec(first.oid).ownerUser == "alice" and rec(first.oid).customName == "", "夾帶 ownerUser → BAD_ARGS、ledger 不變")
local nanAck = cmd(A, "prepareClaim", { vehicleId = 0 / 0 })
check(nanAck.reason == "BAD_ARGS", "NaN vehicleId → BAD_ARGS")
local pm = cmd(A, "reportLost", { expectedOid = first.oid, protocol = 99 })
check(pm.reason == "PROTOCOL_MISMATCH" and pm.serverProtocol == MVM.PROTOCOL, "協定不符 → PROTOCOL_MISMATCH＋serverProtocol")
check(cmd(A, "dropTable", {}).reason == "UNKNOWN_COMMAND" and records() == 1, "未知命令 → UNKNOWN_COMMAND、不改")

out("情境 7：sqlId 回收（keyId 不同）→ ORPHANED、新車 unclaimed、quota 釋放")
local disk = GOS.snapshot()
local gmdSaved = deepcopy(gmd)
boot(disk, true)
gmd = gmdSaved
A = player("alice", 0, 0)
local newcar = vehicle(9, 101, 7777, "Base.CarNormal", 1, 1)
local verdict = O.lookup(newcar)
check(verdict == "UNCLAIMED_ORPHANED_OLD" and rec(first.oid).recordState == "ORPHANED", "舊 record → ORPHANED")
check(O.quotaUsed("alice") == 0, "quota 立即釋放")
check(claim(player("bob", 1, 1), newcar).ok, "新車任何人可綁")

out("情境 8：見證 wipe／clone／orphan")
boot()
A = player("alice", 0, 0)
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
ack = claim(A, car)
rawset(car.parts.Engine.md, "MinidoracatVehicleManager", nil)
B = player("bob", 1, 1)
check(O.canUse(B, car, "DRIVE") == false, "見證被清後非 owner 仍被拒")
check(rec(ack.oid).recordState == "WITNESS_STALE", "record → WITNESS_STALE")
check(cmd(B, "reissueWitness", { vehicleId = 1, expectedOid = ack.oid }).reason == "NOT_OWNER", "非 owner 不能重新核發")
local oldEpoch = rec(ack.oid).epoch
check(cmd(A, "reissueWitness", { vehicleId = 1, expectedOid = ack.oid }).ok and rec(ack.oid).recordState == "ACTIVE"
    and rec(ack.oid).epoch ~= oldEpoch and witness(car).epoch == rec(ack.oid).epoch, "owner 自助重新核發：新 epoch、ACTIVE")
-- 車身 modData 被覆寫不影響授權（在 clone 之前測：clone 會依規則 5 把這筆變 ORPHANED）
car.bodyMd = { MinidoracatVehicleManager = { oid = "x" } }
check(O.canUse(A, car, "DRIVE") == true and O.canUse(B, car, "DRIVE") == false, "授權不讀車身 modData")
-- clone：同 sqlId 但 keyId 不同的車帶著這筆見證 → quarantine
local clone = vehicle(2, 101, 6666, "Base.CarNormal", 1, 1)
rawset(clone.parts.Engine.md, "MinidoracatVehicleManager", { oid = ack.oid, epoch = rec(ack.oid).epoch })
local v2, qrec = O.lookup(clone)
check(v2 == "QUARANTINED" and qrec.recordState == "QUARANTINED" and qrec.ownerUser == nil, "clone 見證 → 新車 QUARANTINED")
check(O.canUse(B, clone, "DRIVE") == false and O.canUse(A, clone, "DRIVE") == false, "quarantine 對所有人（含原 owner）fail closed")
check(claim(B, clone).reason == "ALREADY_CLAIMED", "攻擊者也不能綁 quarantine 車")
-- orphan：無 record 的見證被剝除，車可正常綁
local stray = vehicle(3, 303, 3003, "Base.CarNormal", 1, 1)
rawset(stray.parts.Engine.md, "MinidoracatVehicleManager", { oid = "uuid-fake0001", epoch = "uuid-fake0002" })
local tx0 = transmits
check(O.lookup(stray) == "UNCLAIMED_WITNESS_STRIPPED" and witness(stray) == nil and transmits == tx0 + 1, "orphan 見證被剝除並 transmit")
check(claim(B, stray).ok, "剝除後可正常 claim（無不可綁 DoS）")
check(rec(ack.oid).recordState == "ORPHANED", "clone 情境中原紀錄依規則 5 轉 ORPHANED")

out("情境 9／14：同 sqlId 兩筆可授權 → quarantine；索引重建一致")
boot()
ack = claim(player("alice", 0, 0), vehicle(1, 101, 5001, "Base.CarNormal", 1, 1))
disk = GOS.snapshot()
local dup = deepcopy(rec(ack.oid)); dup.oid = "uuid-dup00001"; dup.ownerUser = "mallory"
disk.recordsByOid[dup.oid] = dup
boot(disk, true)
check(rec(ack.oid).recordState == "QUARANTINED" and rec(dup.oid).recordState == "QUARANTINED", "重複 sqlId 兩筆都 quarantine")
local before = 0
for _ in pairs(O.R.bySqlId) do before = before + 1 end
O.rebuildIndex()
local after = 0
for _ in pairs(O.R.bySqlId) do after = after + 1 end
check(before == after, "刪掉 derived index 重建結果相同")

out("情境 10／11／29：private／member／faction action 矩陣")
boot()
A, B = player("alice", 0, 0), player("bob", 1, 1)
local Cp, D = player("carol", 1, 1), player("dave", 1, 1)
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
ack = claim(A, car)
local r = rec(ack.oid)
check(O.canUse(B, car, "PASSENGER") == false, "私人預設：他人被拒")
check(cmd(A, "addMember", { expectedOid = r.oid, username = "bob", actionBits = MVM.ACTIONS.DRIVE + MVM.ACTIONS.TRACK }).ok, "加 member")
check(O.canUse(B, car, "DRIVE") and O.canUse(B, car, "PASSENGER") and O.canUse(B, car, "TRACK"), "member DRIVE／隱含 PASSENGER／TRACK")
check(not O.canUse(B, car, "SALVAGE") and not O.canUse(B, car, "MANAGE"), "member 沒給的 action 與 MANAGE 被拒")
check(cmd(B, "unclaim", { vehicleId = 1, expectedOid = r.oid, expectedEpoch = r.epoch }).reason == "NOT_OWNER", "member 不能 unclaim")
check(cmd(B, "rename", { expectedOid = r.oid, expectedEpoch = r.epoch, name = "mine" }).reason == "NOT_OWNER", "member 不能改名")
check(cmd(A, "addMember", { expectedOid = r.oid, username = "carol", actionBits = MVM.ACTIONS.MANAGE }).reason == "BAD_ARGS", "MANAGE 位不可分享")
local denied, why = O.canUse(B, car, "FLY")
check(denied == false and why == "UNKNOWN_ACTION", "未知 action fail closed")
SB.MaxMembersPerVehicle = 1
check(cmd(A, "addMember", { expectedOid = r.oid, username = "carol", actionBits = 1 }).reason == "MEMBER_LIMIT", "成員上限")
SB.MaxMembersPerVehicle = 6
check(cmd(B, "leaveShared", { expectedOid = r.oid }).ok and not O.canUse(B, car, "DRIVE"), "member 可自行離開")
-- faction（§5.1 F10）
local fac = newFaction("Wolves", "alice", { "carol" })
check(cmd(A, "setFactionShare", { expectedOid = r.oid, expectedEpoch = r.epoch, enabled = true, actionBits = MVM.ACTIONS.CARGO }).ok, "開陣營共享")
check(O.canUse(Cp, car, "CARGO") and not O.canUse(Cp, car, "DRIVE") and not O.canUse(D, car, "CARGO"), "陣營成員只得 CARGO，非成員拒")
fac.owner = "dave"; fac.members = { "carol", "alice" }
check(not O.canUse(Cp, car, "CARGO") and r.factionState == "SUSPENDED", "換 leader → SUSPENDED")
fac.owner = "alice"; fac.members = { "carol" }
check(not O.canUse(Cp, car, "CARGO"), "SUSPENDED 不會自動恢復")
check(cmd(A, "setFactionShare", { expectedOid = r.oid, expectedEpoch = r.epoch, enabled = true, actionBits = MVM.ACTIONS.CARGO }).ok
    and O.canUse(Cp, car, "CARGO"), "owner 重新確認後恢復")
-- owner 離開陣營 → 拒；回來 → 恢復（§12.1-19）
local wolves2 = newFaction("Other", "zed", { "alice" })
fac.owner = "alice"
factions[1] = fac
-- alice 仍是 Wolves leader；模擬 alice 讓出 leader 前先測「owner 不再是成員」：改用 member-owner 的陣營
local g = newFaction("Guild", "gary", { "alice", "carol" })
local car2 = vehicle(2, 102, 5002, "Base.CarNormal", 1, 1)
local ack2 = claim(A, car2)
local r2 = rec(ack2.oid)
cmd(A, "setFactionShare", { expectedOid = r2.oid, expectedEpoch = r2.epoch, enabled = true, actionBits = MVM.ACTIONS.CARGO })
check(r2.factionName == "Wolves" or r2.factionName == "Guild", "setFactionShare 綁 owner 所在陣營")
-- 直接指定 Guild 以測成員資格
r2.factionName, r2.factionOwnerUser, r2.factionState = "Guild", "gary", "GRANTED"
O.R.factionRefs[r2.oid] = nil
check(O.canUse(Cp, car2, "CARGO"), "owner 與 actor 都在 Guild → 允許")
g.members = { "carol" }
check(not O.canUse(Cp, car2, "CARGO") and r2.factionState == "GRANTED", "owner 離開 → 拒絕但不 SUSPENDED")
g.members = { "carol", "alice" }
check(O.canUse(Cp, car2, "CARGO"), "owner 回來 → 恢復")
-- 同進程內解散後同 leader 同名重建 → SUSPENDED
for i, f in ipairs(factions) do if f == g then table.remove(factions, i) end end
newFaction("Guild", "gary", { "alice", "carol" })
check(not O.canUse(Cp, car2, "CARGO") and r2.factionState == "SUSPENDED", "同名重建（新物件）→ SUSPENDED")
SB.AllowFactionShare = false
check(cmd(A, "setFactionShare", { expectedOid = r.oid, expectedEpoch = r.epoch, enabled = true, actionBits = 1 }).reason == "FACTION_SHARE_DISABLED", "沙盒關閉陣營共享")
check(not O.canUse(Cp, car, "CARGO"), "沙盒關閉後既有陣營授權也失效")
check(S.row(r, "carol") == nil and next(O.factionMembers(r)) == nil, "沙盒關閉後陣營成員也收不到投影與位置")
SB.AllowFactionShare = true
check(cmd(A, "addMember", { expectedOid = r.oid, username = "carol", actionBits = MVM.ACTIONS.PASSENGER }).ok
    and O.canUse(Cp, car, "CARGO"), "陣營成員另被指定較窄權限：server 仍允許陣營給的 CARGO")
local crow = S.row(r, "carol")
check(crow and MVM.bitsAllow(crow.myBits, "CARGO") and MVM.bitsAllow(crow.myBits, "PASSENGER"), "投影 myBits＝指定成員 ∪ 陣營權限")

out("情境 12：transfer")
boot()
A, B = player("alice", 0, 0), player("bob", 1, 1)
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
ack = claim(A, car)
r = rec(ack.oid)
cmd(A, "addMember", { expectedOid = r.oid, username = "carol", actionBits = 1 })
check(cmd(A, "transfer", { vehicleId = 1, expectedOid = r.oid, expectedEpoch = r.epoch, recipient = "ghost" }).reason == "RECIPIENT_UNKNOWN", "沒登入過的收件者 → 拒")
check(cmd(A, "addMember", { expectedOid = r.oid, username = "alicee", actionBits = 1 }).reason == "UNKNOWN_PLAYER"
    and #r.grants == 0, "分享給沒登入過的名字（打錯字）→ 拒，不寫進名單")
do
    local dave = player("dave", 1, 1)
    S.minute() -- 登入觀測：記進曾登入名單
    for i = #online, 1, -1 do if online[i] == dave then table.remove(online, i) end end
    check(O.state().knownUsers.dave ~= nil and cmd(A, "addMember", { expectedOid = r.oid, username = "dave", actionBits = 1 }).ok,
        "曾登入過、現在離線的玩家可以加入分享")
    local disk = GOS.snapshot()
    check(disk.knownUsers.dave ~= nil, "曾登入名單存在帳本裡（跨重啟保留）")
    cmd(A, "removeMember", { expectedOid = r.oid, username = "dave" })
end
SB.ClaimsPerPlayer = 0
check(cmd(A, "transfer", { vehicleId = 1, expectedOid = r.oid, expectedEpoch = r.epoch, recipient = "bob" }).reason == "RECIPIENT_QUOTA", "收件者 quota 滿 → 拒")
SB.ClaimsPerPlayer = 3
car.x = 30
check(cmd(A, "transfer", { vehicleId = 1, expectedOid = r.oid, expectedEpoch = r.epoch, recipient = "bob" }).reason == "TOO_FAR", "owner 不在車旁 → 拒")
car.x = 1
local t = cmd(A, "transfer", { vehicleId = 1, expectedOid = r.oid, expectedEpoch = r.epoch, recipient = "bob" })
local nr = rec(t.oid)
check(t.ok and r.recordState == "RELEASED" and nr.ownerUser == "bob" and nr.epoch ~= r.epoch and #nr.grants == 0, "舊 RELEASED、新 owner、新 epoch、分享清空")
check(witness(car).oid == nr.oid and O.canUse(B, car, "MANAGE") and not O.canUse(A, car, "DRIVE"), "見證換成新紀錄；原 owner 失去權限")

out("情境 13：admin capability＋越權開關＋audit")
boot()
A, B = player("alice", 0, 0), player("bob", 1, 1)
local ADM = player("admin", 1, 1, { admin = true })
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
ack = claim(A, car)
do
    local function logged(event, from, extra)
        for i = from + 1, #logLines do
            if logLines[i]:find(event, 1, true) and (extra == nil or logLines[i]:find(extra, 1, true)) then return true end
        end
        return false
    end
    local n0 = #logLines
    check(O.canUse(ADM, car, "DRIVE") == false and not logged("ADMIN_BYPASS", n0), "越權關閉：沒有權限的管理員被拒，不寫 ADMIN_BYPASS")
    local ADM2 = player("admin2", 1, 1, { admin = true })
    cmd(A, "addMember", { expectedOid = ack.oid, username = "admin2", actionBits = MVM.ACTIONS.PASSENGER })
    n0 = #logLines
    local ok, why = O.canUse(ADM2, car, "PASSENGER")
    check(ok and why == "MEMBER" and not logged("ADMIN_BYPASS", n0), "分享者兼管理員：走 MEMBER，不記越權")
    check(cmd(B, "setAdminOverride", { enabled = true }).reason == "NOT_ADMIN" and O.canUse(B, car, "DRIVE") == false,
        "非管理員設定越權被拒")
    n0 = #logLines
    local on = cmd(ADM, "setAdminOverride", { enabled = true })
    check(on.ok and on.enabled == true and logged("ADMIN_OVERRIDE", n0, "\tON\t"), "開啟越權：ACK 帶 enabled、寫 ADMIN_OVERRIDE ON")
    cmd(ADM, "adminList", {}, false)
    cmd(B, "adminList", {}, false)
    check(lastOf(ADM, "adminSnapshot").override == true and lastOf(B, "adminSnapshot").override == false,
        "adminSnapshot 回報自己的越權狀態")
    rec(ack.oid).lastKnownZ = 2
    cmd(ADM, "adminList", {}, false)
    local arow = nil
    for _, r in ipairs(lastOf(ADM, "adminSnapshot").rows or {}) do if r.oid == ack.oid then arow = r end end
    check(arow and arow.lastKnownZ == 2, "管理頁的車輛列帶樓層（傳送過去要用）")
    n0 = #logLines
    ok, why = O.canUse(ADM, car, "DRIVE")
    check(ok and why == "ADMIN" and logged("ADMIN_BYPASS", n0), "越權中：放行並寫 ADMIN_BYPASS")
    cmd(ADM2, "setAdminOverride", { enabled = true })
    n0 = #logLines
    ok, why = O.canUse(ADM2, car, "PASSENGER")
    check(ok and why == "MEMBER" and not logged("ADMIN_BYPASS", n0), "分享者兼管理員開著越權：有分享的動作仍走 MEMBER，不記越權")
    cmd(ADM2, "setAdminOverride", { enabled = false })
    check(O.canUse(player("admin", 1, 1, { admin = true }), car, "DRIVE") == false, "重新登入（新的 IsoPlayer 物件）：越權自動失效")
    ADM.admin = false
    check(O.canUse(ADM, car, "DRIVE") == false, "管理權限被拔掉：越權跟著失效")
    ADM.admin = true
    rec(ack.oid).recordState = "QUARANTINED"
    check(O.canUse(A, car, "DRIVE") == false and O.canUse(ADM2, car, "PASSENGER") == false and O.canUse(ADM, car, "DRIVE"),
        "QUARANTINED：車主、分享者都拒，只有越權中的管理員能用")
    rec(ack.oid).recordState = "ACTIVE"
    n0 = #logLines
    local off = cmd(ADM, "setAdminOverride", { enabled = false })
    check(off.ok and off.enabled == false and logged("ADMIN_OVERRIDE", n0, "\tOFF\t") and O.canUse(ADM, car, "DRIVE") == false,
        "關閉越權：寫 ADMIN_OVERRIDE OFF，之後又被拒")
end
check(cmd(B, "adminSetQuota", { usernames = { "bob" }, amount = 10 }).reason == "NOT_ADMIN", "非 admin 不能設 quota")
check(cmd(ADM, "adminSetQuota", { usernames = { "bob" }, amount = 10 }).ok and O.quotaLimit("bob") == 10, "admin 設個人 quota")
serverMode = false
check(O.isAdmin(ADM) == false, "SP 不把 checkPermissions 當 admin")
serverMode = true
check(cmd(ADM, "adminRecover", { expectedOid = ack.oid, op = "RELEASE" }).ok and rec(ack.oid).recordState == "RELEASED", "admin RELEASE")

out("情境 13b：全服預設名額（沙盒同步）與批次個人名額")
do
    boot()
    local ADMQ, BOB, ALI = player("admin", 1, 1, { admin = true }), player("bob", 1, 1), player("alice", 0, 0)
    claim(ALI, vehicle(1, 101, 5001, "Base.CarNormal", 1, 1))
    local function count(p, command)
        local n = 0
        for _, m in ipairs(outbox[p.name]) do if m.command == command then n = n + 1 end end
        return n
    end
    local function logged(from, ...)
        local want = { ... }
        for i = from + 1, #logLines do
            local hit = true
            for _, w in ipairs(want) do if not logLines[i]:find(w, 1, true) then hit = false end end
            if hit then return true end
        end
        return false
    end
    local QN = "MinidoracatVehicleManager.ClaimsPerPlayer"
    S.minute() -- 記下目前的預設值作為比對基準
    -- 非管理員、超出沙盒範圍
    local sets0 = SBOX.sets
    check(cmd(BOB, "adminSetDefaultQuota", { amount = 5 }).reason == "NOT_ADMIN" and SBOX.sets == sets0 and SB.ClaimsPerPlayer == 3,
        "非管理員不能改全服預設名額，沙盒不動")
    check(cmd(ADMQ, "adminSetDefaultQuota", { amount = 21 }).reason == "BAD_ARGS" and cmd(ADMQ, "adminSetDefaultQuota", { amount = -1 }).reason == "BAD_ARGS"
        and cmd(ADMQ, "adminSetDefaultQuota", { amount = 2.5 }).reason == "BAD_ARGS" and SBOX.sets == sets0,
        "預設名額只收 0–20 的整數（同沙盒範圍）")
    -- 存檔失敗：記憶體改回原值、回 SAVE_FAILED、不廣播也不重送快照
    SBOX.saveOk = false
    local bobSnaps, n0 = count(BOB, "fleetSnapshot"), #logLines
    local failed = cmd(ADMQ, "adminSetDefaultQuota", { amount = 5 })
    check(failed.reason == "SAVE_FAILED" and SB.ClaimsPerPlayer == 3 and SBOX.values[QN] == 3 and O.quotaBase("bob") == 3,
        "沙盒存檔失敗：Java 端與 SandboxVars 都改回原值並回 SAVE_FAILED")
    check(count(BOB, "sandboxSync") == 0 and count(ALI, "sandboxSync") == 0 and count(BOB, "fleetSnapshot") == bobSnaps
        and not logged(n0, "ADMIN_QUOTA"), "存檔失敗時不通知客戶端、不重送快照、不記 ADMIN_QUOTA")
    -- 成功：寫沙盒並存檔、通知線上客戶端、重送所有線上玩家快照、稽核舊值→新值
    SBOX.saveOk = true
    n0 = #logLines
    local aliSnaps = count(ALI, "fleetSnapshot")
    local okSet = cmd(ADMQ, "adminSetDefaultQuota", { amount = 5 })
    check(okSet.ok and okSet.amount == 5 and SB.ClaimsPerPlayer == 5 and SBOX.file.ClaimsPerPlayer == 5
        and SBOX.file.server == "servertest" and O.quotaBase("bob") == 5, "管理員改預設名額：寫入沙盒並存進伺服器沙盒檔")
    check(lastOf(BOB, "sandboxSync").claimsPerPlayer == 5 and lastOf(ALI, "sandboxSync").claimsPerPlayer == 5
        and lastOf(ADMQ, "sandboxSync").claimsPerPlayer == 5 and lastOf(ALI, "sandboxSync").releaseDays == 0
        and lastOf(ALI, "sandboxSync").parkedGuard == 2 and lastOf(ALI, "sandboxSync").guardSlots == 1,
        "存檔成功後通知每位線上客戶端同步沙盒值（名額、閒置天數、保全模式與免費保全名額一起帶）")
    check(count(ALI, "fleetSnapshot") == aliSnaps + 1 and lastOf(ALI, "fleetSnapshot").quota.base == 5
        and lastOf(ALI, "fleetSnapshot").quota.used == 1 and lastOf(BOB, "fleetSnapshot").quota.base == 5,
        "預設名額改變後重送所有線上玩家的快照，名額即時變")
    check(logged(n0, "ADMIN_QUOTA", "DEFAULT 3->5", "admin"), "稽核 ADMIN_QUOTA 含舊值→新值")
    cmd(ADMQ, "adminList", {}, false)
    check(lastOf(ADMQ, "adminSnapshot").defaultQuota == 5, "管理員總表回報目前的全服預設名額")
    -- 原版沙盒 UI 直接改值：每分鐘比對發現就重送快照；沒變就不送
    SB.ClaimsPerPlayer = 7
    aliSnaps, n0 = count(ALI, "fleetSnapshot"), #logLines
    S.minute()
    check(count(ALI, "fleetSnapshot") == aliSnaps + 1 and lastOf(ALI, "fleetSnapshot").quota.base == 7
        and logged(n0, "ADMIN_QUOTA", "DEFAULT 5->7", "SANDBOX"), "原版途徑改了沙盒：每分鐘 tick 偵測到並重送快照")
    S.minute()
    check(count(ALI, "fleetSnapshot") == aliSnaps + 1, "沙盒值沒變：tick 不重送")
    SB.ClaimsPerPlayer, SBOX.values = 3, {}
    S.minute()
    -- 閒置釋放天數：同一條存檔路徑（非管理員、範圍、存檔失敗回滾、成功同步並重送快照、原版沙盒 UI 改值）
    local DN = "MinidoracatVehicleManager.InactivityReleaseDays"
    check(cmd(BOB, "adminSetReleaseDays", { amount = 30 }).reason == "NOT_ADMIN" and SB.InactivityReleaseDays == 0,
        "非管理員不能改閒置釋放天數")
    check(cmd(ADMQ, "adminSetReleaseDays", { amount = 366 }).reason == "BAD_ARGS" and cmd(ADMQ, "adminSetReleaseDays", { amount = 1.5 }).reason == "BAD_ARGS"
        and cmd(ADMQ, "adminSetReleaseDays", { amount = -1 }).reason == "BAD_ARGS", "閒置釋放天數只收 0–365 的整數")
    SBOX.saveOk = false
    n0 = #logLines
    check(cmd(ADMQ, "adminSetReleaseDays", { amount = 30 }).reason == "SAVE_FAILED" and SB.InactivityReleaseDays == 0 and SBOX.values[DN] == 0
        and not logged(n0, "ADMIN_RELEASE_DAYS"), "閒置天數存檔失敗：改回原值、回 SAVE_FAILED、不記稽核")
    SBOX.saveOk = true
    aliSnaps, n0 = count(ALI, "fleetSnapshot"), #logLines
    local okDays = cmd(ADMQ, "adminSetReleaseDays", { amount = 45 })
    check(okDays.ok and SB.InactivityReleaseDays == 45 and SBOX.file.InactivityReleaseDays == 45
        and lastOf(ALI, "sandboxSync").releaseDays == 45 and lastOf(ALI, "sandboxSync").claimsPerPlayer == 3
        and count(ALI, "fleetSnapshot") == aliSnaps + 1 and lastOf(ALI, "fleetSnapshot").releaseDays == 45
        and logged(n0, "ADMIN_RELEASE_DAYS", "0->45", "admin"),
        "管理員改閒置天數：寫入並存檔、同步客戶端沙盒（含名額）、重送快照帶新天數、稽核舊值→新值")
    cmd(ADMQ, "adminList", {}, false)
    check(lastOf(ADMQ, "adminSnapshot").releaseDays == 45, "管理員總表回報目前的閒置天數")
    SB.InactivityReleaseDays = 60
    aliSnaps, n0 = count(ALI, "fleetSnapshot"), #logLines
    S.minute()
    check(count(ALI, "fleetSnapshot") == aliSnaps + 1 and lastOf(ALI, "fleetSnapshot").releaseDays == 60
        and logged(n0, "ADMIN_RELEASE_DAYS", "45->60", "SANDBOX"), "原版沙盒 UI 改天數：每分鐘偵測並重送快照")
    SB.InactivityReleaseDays, SBOX.values = 0, {}
    S.minute()

    -- 批次個人名額：usernames 清單驗證
    local function bad(list) return cmd(ADMQ, "adminSetQuota", { usernames = list, amount = 4 }).reason == "BAD_ARGS" end
    local big = {}
    for i = 1, 501 do big[i] = "user" .. i end
    check(bad({}) and bad({ "carl", "carl" }) and bad(big), "批次名單：空、重複、超過 500 位都拒收")
    check(bad({ "" }) and bad({ "a\nb" }) and bad({ string.rep("x", 51) }) and bad({ 7 }), "批次名單：不合法的帳號拒收")
    check(bad({ x = "carl" }) and bad({ [1] = "carl", [3] = "dan" }) and bad("carl"), "批次名單：只能是連續陣列")
    big[501] = nil
    check(cmd(ADMQ, "adminSetQuota", { usernames = big, amount = 4 }).count == 500 and O.quotaBase("user500") == 4,
        "剛好 500 位可以送出")
    cmd(ADMQ, "adminSetQuota", { usernames = big, amount = -1 })
    check(cmd(BOB, "adminSetQuota", { usernames = { "bob" }, amount = 9 }).reason == "NOT_ADMIN" and O.quotaBase("bob") == 3,
        "非管理員不能批次設定名額")
    bobSnaps, aliSnaps, n0 = count(BOB, "fleetSnapshot"), count(ALI, "fleetSnapshot"), #logLines
    local set8 = cmd(ADMQ, "adminSetQuota", { usernames = { "bob", "carl", "dan" }, amount = 8 })
    local ov = O.state().quotaOverrides
    check(set8.ok and set8.count == 3 and ov.bob == 8 and ov.carl == 8 and ov.dan == 8 and ov.alice == nil,
        "批次設定：三位都寫入個人名額，未選的不動")
    check(logged(n0, "ADMIN_QUOTA", "\tbob\t", "USER DEFAULT->8") and logged(n0, "ADMIN_QUOTA", "\tcarl\t")
        and logged(n0, "ADMIN_QUOTA", "\tdan\t"), "批次設定逐人寫 ADMIN_QUOTA（舊值→新值）")
    check(count(BOB, "fleetSnapshot") == bobSnaps + 1 and lastOf(BOB, "fleetSnapshot").quota.base == 8
        and count(ALI, "fleetSnapshot") == aliSnaps, "只重送受影響的線上玩家快照（離線者略過）")
    n0 = #logLines
    local reset = cmd(ADMQ, "adminSetQuota", { usernames = { "bob", "carl", "dan" }, amount = -1 })
    check(reset.ok and reset.count == 3 and ov.bob == nil and ov.carl == nil and ov.dan == nil
        and lastOf(BOB, "fleetSnapshot").quota.base == 3 and logged(n0, "ADMIN_QUOTA", "\tcarl\t", "USER 8->DEFAULT"),
        "-1 批次恢復預設：清除個人名額並重送快照")
    -- 管理頁列出登入過但還沒有車的玩家（已用 0）；一次掃完的已用與逐人計算相同（alice 一台受保護＋一台已解除）
    local a2 = claim(ALI, vehicle(2, 102, 5002, "Base.CarNormal", 1, 1))
    local r2 = rec(a2.oid)
    cmd(ALI, "unclaim", { vehicleId = 2, expectedOid = r2.oid, expectedEpoch = r2.epoch })
    O.noteUser("newbie")
    cmd(ADMQ, "adminList", {}, false)
    local newbie, same = nil, true
    for _, pl in ipairs(lastOf(ADMQ, "adminSnapshot").players) do
        if pl.user == "newbie" then newbie = pl end
        if pl.used ~= O.quotaUsed(pl.user) or pl.limit ~= O.quotaLimit(pl.user) then same = false end
    end
    check(newbie and newbie.used == 0 and newbie.limit == 3 and not newbie.custom, "登入過但沒有車的玩家也列在管理員總表，已用 0")
    check(same and r2.recordState == "RELEASED" and O.quotaUsed("alice") == 1, "總表的已用／上限與逐人 O.quotaUsed／O.quotaLimit 相同（已解除不計）")
end

out("情境 15／17：sentinel 與重啟")
boot()
A = player("alice", 0, 0)
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
ack = claim(A, car)
local st = O.state()
check(gmd.MinidoracatVehicleManagerSentinel.ledgerRevision == st.ledgerRevision and gmd.MinidoracatVehicleManagerSentinel.recordCount == 1, "sentinel 同步 revision／count")
local sentinelDump = deepcopy(gmd.MinidoracatVehicleManagerSentinel)
for k, v in pairs(sentinelDump) do if k == "owner" or k == "oid" then check(false, "sentinel 不含敏感欄位") end end
-- 正常重啟：引擎存檔（主系統只存中繼資料、大表在分片檔）→ 重新載入
GOS.save()
disk, gmdSaved = deepcopy(O.R.meta), deepcopy(gmd)
check(disk.recordsByOid == nil and disk.shardCount == 1, "主系統存檔只含中繼資料，大表不在主檔")
boot(disk, true, true); gmd = gmdSaved
check(O.ready() == true and O.R.loaded == "disk" and rec(ack.oid) ~= nil and rec(ack.oid).ownerUser == "alice",
    "完整備份還原：同 ledgerId／revision → READY，紀錄從分片檔載回")
-- 重啟後車輛從 vehicles.db 帶著零件見證重新載入：索引必須已由 disk 重建
A = player("alice", 0, 0)
local reloaded = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
rawset(reloaded.parts.Engine.md, "MinidoracatVehicleManager", { oid = ack.oid, epoch = O.state().recordsByOid[ack.oid].epoch })
check(O.lookup(reloaded) == "AUTHORIZED" and witness(reloaded) ~= nil, "重啟後同一台車仍 AUTHORIZED、見證未被剝除")
check(O.canUse(player("bob", 1, 1), reloaded, "DRIVE") == false, "重啟後他人仍被拒")
-- GOS 較新（GMD 未存就崩潰）→ 接受
disk = GOS.snapshot(); gmdSaved = deepcopy(gmd); disk.ledgerRevision = disk.ledgerRevision + 5
boot(disk, true); gmd = gmdSaved
check(O.ready() == true and gmd.MinidoracatVehicleManagerSentinel.ledgerRevision == disk.ledgerRevision, "GOS revision 較新 → 接受並修正 sentinel")
-- GOS 較舊 → RECOVERY_REQUIRED
disk = GOS.snapshot(); gmdSaved = deepcopy(gmd); disk.ledgerRevision = disk.ledgerRevision - 3
boot(disk, true); gmd = gmdSaved
A = player("alice", 0, 0)
vehicle(2, 202, 5002, "Base.CarNormal", 1, 1)
check(O.ready() == false and cmd(A, "prepareClaim", { vehicleId = 2 }).reason == "RECOVERY_REQUIRED", "GOS 較舊 → RECOVERY_REQUIRED、mutation fail closed")
-- sentinel 已裝但 GOS 空（10 MiB 截斷後載成空帳本）
gmdSaved = deepcopy(gmd)
boot(nil, true); gmd = gmdSaved
check(O.ready() == false and O.R.status == "RECOVERY_REQUIRED", "sentinel 在但 GOS 全新 → RECOVERY_REQUIRED")
-- ledgerId 不同
gmdSaved = deepcopy(gmd)
local other = deepcopy(disk); other.ledgerId = "uuid-other0001"; other.ledgerRevision = 9999
boot(other, true); gmd = gmdSaved
check(O.ready() == false, "ledgerId 不同 → RECOVERY_REQUIRED")
-- 開機期 quarantine 不得蓋掉 sentinel、掩蓋較舊的 GOS
gmdSaved = deepcopy(gmd)
local older = deepcopy(disk)
older.ledgerId = gmdSaved.MinidoracatVehicleManagerSentinel.ledgerId
older.ledgerRevision = gmdSaved.MinidoracatVehicleManagerSentinel.ledgerRevision - 1
local d1 = { oid = "uuid-dupa0001", recordState = "ACTIVE", ownerUser = "x", sqlIdHint = 555, keyIdHint = 1, vehicleScript = "Base.CarNormal" }
local d2 = { oid = "uuid-dupb0001", recordState = "ACTIVE", ownerUser = "y", sqlIdHint = 555, keyIdHint = 2, vehicleScript = "Base.CarNormal" }
older.recordsByOid = { [d1.oid] = d1, [d2.oid] = d2 }
boot(older, true); gmd = gmdSaved
check(O.ready() == false and O.R.status == "RECOVERY_REQUIRED", "開機期 quarantine 不掩蓋「GOS 比 sentinel 舊」")
check(gmd.MinidoracatVehicleManagerSentinel.ledgerRevision == older.ledgerRevision + 1, "RECOVERY 期間 sentinel 不被改寫")
-- 首次安裝
boot(nil)
check(O.ready() == true and gmd.MinidoracatVehicleManagerSentinel.installed == true, "首次安裝建立 sentinel")

do
out("情境 16：沒有全服上限；分片滿了自動開新分片，項目不搬動，存讀後完整")
boot()
A = player("alice", 0, 0)
O.mapSet("quotaOverrides", "alice", 100)
local lim = O.SHARD_LIMITS.records
O.SHARD_LIMITS.records = 20 -- 縮小每片上限以測擴充
for i = 1, 49 do O.createRecord("filler", vehicle(100 + i, 1000 + i, 9000 + i, "Base.CarNormal", 1, 1), part("Engine")) end
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
local capAck = claim(A, car)
check(capAck.ok and records() == 50 and #O.R.shards == 3 and O.R.meta.shardCount == 3, "50 筆、每片 20 筆：自動開到 3 片，綁定不被擋")
check(O.R.shards[1].records == 20 and O.R.shards[2].records == 20 and O.R.shards[3].records == 10, "先填滿前面的分片")
local firstOid = nil
for oid, k in pairs(O.R.where.recordsByOid) do if k == 1 then firstOid = oid end end
O.removeRecord(rec(firstOid))
check(O.R.shards[1].records == 19, "刪除只影響所在分片")
local refill = O.createRecord("filler", vehicle(300, 3000, 9300, "Base.CarNormal", 1, 1), part("Engine"))
check(O.R.where.recordsByOid[refill.oid] == 1 and O.R.where.recordsByOid[capAck.oid] == 3, "新項目補進第一片空位，既有項目不搬動")
rec(capAck.oid).customName = "after-insert" -- 事後改欄位：同一個 table，存檔要帶到
GOS.save()
local shardMeta = deepcopy(O.R.meta)
boot(shardMeta, true, true)
A = player("alice", 0, 0)
check(records() == 50 and #O.R.shards == 3 and rec(capAck.oid).customName == "after-insert" and O.quotaLimit("alice") == 100,
    "三個分片檔與主檔存讀後，紀錄、事後修改與名額調整完整")
check(getmetatable(GOS.live.MinidoracatVehicleManagerOwnership_2.md).__index.getInitialStateForClient ~= nil,
    "分片系統有 GOS 會呼叫的方法（缺了引擎會拋錯）")
-- 其他 MOD 已註冊很多系統：全伺服器快到預算就不再開新分片（客戶端以有號 byte 讀系統數）
SGlobalObjects.others = O.SHARD_LIMITS.systemBudget
for i = 1, 25 do O.createRecord("filler", vehicle(400 + i, 4000 + i, 9400 + i, "Base.CarNormal", 1, 1), part("Engine")) end
check(#O.R.shards == 3, "全伺服器 GOS 系統數達預算：不再開新分片")
SGlobalObjects.others = 5
O.SHARD_LIMITS.records = lim
end

out("情境 18／20／26：per-recipient stream、隱私、撤權 delta")
boot()
A, B = player("alice", 0, 0), player("bob", 1, 1)
local E = player("eve", 1, 1)
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
cmd(A, "fleetSubscribe", {}, false); cmd(B, "fleetSubscribe", {}, false); cmd(E, "fleetSubscribe", {}, false)
ack = claim(A, car)
r = rec(ack.oid)
local aSnap = lastOf(A, "fleetDelta")
check(aSnap and aSnap.upserts[1].oid == r.oid and aSnap.upserts[1].epoch == r.epoch and aSnap.to == "alice", "owner 收到自己的列（含 epoch，to＝username）")
check(lastOf(E, "fleetDelta") == nil, "無關玩家收不到 delta")
cmd(E, "fleetResync", {}, false)
check(#lastOf(E, "fleetSnapshot").rows == 0, "未授權 recipient snapshot 0 列")
local eSeq = #outbox.eve
cmd(A, "addMember", { expectedOid = r.oid, username = "bob", actionBits = MVM.ACTIONS.PASSENGER })
local bRow = lastOf(B, "fleetDelta").upserts[1]
check(bRow and bRow.role == "MEMBER" and bRow.epoch == nil and bRow.grants == nil and bRow.lastKnownX == nil, "member 列不含 epoch／grants；無 TRACK 不給位置")
check(#outbox.eve == eSeq, "他人的 mutation 不推進無關者的 seq")
cmd(A, "addMember", { expectedOid = r.oid, username = "bob", actionBits = MVM.ACTIONS.PASSENGER + MVM.ACTIONS.TRACK })
check(lastOf(B, "fleetDelta").upserts[1].lastKnownX ~= nil, "有 TRACK 才給位置")
cmd(A, "removeMember", { expectedOid = r.oid, username = "bob" })
local rm = lastOf(B, "fleetDelta")
check(rm.removes[1] == r.oid and #rm.upserts == 0, "撤權者收到 removes")
local seqs = {}
for _, m in ipairs(outbox.alice) do if m.command == "fleetDelta" then seqs[#seqs + 1] = m.payload.seq end end
local mono = true
for i = 2, #seqs do if seqs[i] ~= seqs[i - 1] + 1 then mono = false end end
check(mono and #seqs >= 3, "owner stream seq 單調連續")
local broadcast = false
for _, box in pairs(outbox) do for _, m in ipairs(box) do if m.payload.to == nil then broadcast = true end end end
check(not broadcast, "每則 S2C 都帶 to（沒有全服廣播）")

out("情境 19／20／26：client 分桶、keyed replace、跳號 resync")
local serverIsClient = isClient
isClient = function() return true end -- client 以 MP 身分判斷 principal
require("MinidoracatVehicleManager_Client")
local Cl = MVM.Client
local snap = { to = "alice", streamId = "s1", seq = 0, rows = { { oid = "o1", role = "OWNER" } } }
MVM.clientReceive("fleetSnapshot", snap)
MVM.clientReceive("fleetSnapshot", snap)
local n = 0
for _ in pairs(Cl.buckets.alice.rows) do n = n + 1 end
check(n == 1, "同一快照重播兩次不增加列")
MVM.clientReceive("fleetSnapshot", { to = "bob", streamId = "s2", seq = 0, rows = { { oid = "o9" } } })
MVM.clientReceive("adminSnapshot", { to = "alice", id = "snap-a", part = 1, parts = 1, ok = true, rows = {}, migrationAvailable = true })
check(Cl.buckets.alice.migrationAvailable and #Cl.buckets.alice.admin == 0,
    "管理員快照保留 MVCK 來源可用狀態，沒有車輛列也能顯示匯入入口")
check(Cl.buckets.alice.rows.o9 == nil, "不同 username 分桶")
do -- 客戶端收到 sandboxSync：本機沙盒選項改值並投影到 SandboxVars；不是整數就不動
    local QN = "MinidoracatVehicleManager.ClaimsPerPlayer"
    MVM.clientReceive("sandboxSync", { to = "alice", claimsPerPlayer = 5, releaseDays = 40, parkedGuard = 3, guardSlots = 4 })
    local synced = SBOX.values[QN] == 5 and SB.ClaimsPerPlayer == 5 and SB.InactivityReleaseDays == 40
        and SB.ParkedGuard == 3 and SB.GuardSlotsPerPlayer == 4
    MVM.clientReceive("sandboxSync", { to = "alice", claimsPerPlayer = "9", parkedGuard = "1" })
    check(synced and SB.ClaimsPerPlayer == 5 and SB.ParkedGuard == 3,
        "客戶端收到 sandboxSync：名額、閒置天數、保全模式與名額 set＋toLua 更新本機沙盒，非整數忽略")
    SB.ClaimsPerPlayer, SB.InactivityReleaseDays, SB.ParkedGuard, SB.GuardSlotsPerPlayer, SBOX.values = 3, 0, 2, 1, {}
end
clientSent = {}
MVM.clientReceive("fleetDelta", { to = "alice", streamId = "s1", seq = 2, upserts = { { oid = "o2" } }, removes = {} })
check(Cl.buckets.alice.rows.o2 == nil and clientSent[1] and clientSent[1].command == "fleetResync", "跳號 → 丟棄並 resync")
MVM.clientReceive("fleetDelta", { to = "alice", streamId = "s1", seq = 1, upserts = { { oid = "o2" } }, removes = { "o1" } })
check(Cl.buckets.alice.rows.o2 and Cl.buckets.alice.rows.o1 == nil, "連續 seq 套用 upsert／remove")
do -- 失敗通知：有譯文顯示譯文；沒有譯文用不帶代碼的通用說明，代碼只進客戶端 log
    local halo, realGetText = nil, getText
    HaloTextHelper.addBadText = function(_, t) halo = t end
    getText = function(key, ...) if key == "IGUI_MVM_Reason_TOO_FAR" then return "walk over" end return realGetText(key, ...) end
    MVM.clientReceive("mutationAck", { to = "alice", requestId = "r-far", ok = false, reason = "TOO_FAR" })
    check(halo == "walk over", "失敗通知顯示原因譯文，不是原始代碼")
    local logged, realLog = {}, MVM.log
    MVM.log = function(msg) logged[#logged + 1] = tostring(msg) end
    MVM.clientReceive("mutationAck", { to = "alice", requestId = "r-gone", ok = false, reason = "NO_SUCH_RECORD" })
    local codeLogged = false
    for _, l in ipairs(logged) do if l:find("NO_SUCH_RECORD", 1, true) then codeLogged = true end end
    MVM.log = realLog
    check(halo == "IGUI_MVM_Failed" and codeLogged, "沒有譯文的原因退回不帶代碼的通用說明，代碼只寫進客戶端 log")
    getText, HaloTextHelper.addBadText = realGetText, function() end
end
do -- 伺服器會回給玩家的每個原因碼，四語都有 IGUI_MVM_Reason_*（從程式掃出來，不靠手列清單；目前 47 個）
    local function readAll(path)
        local fh = assert(io.open(path, "rb"))
        local s = fh:read("a")
        fh:close()
        return s
    end
    local codes, n = {}, 0
    local function add(text, pattern)
        for c in text:gmatch(pattern) do
            if not codes[c] then codes[c], n = true, n + 1 end
        end
    end
    local srv = readAll(MEDIA .. "/server/MinidoracatVehicleManager_Server.lua")
    for _, p in ipairs({ 'fail%("([A-Z_]+)"', 'return "([A-Z_]+)"', 'return nil, "([A-Z_]+)"', 'return nil, nil, "([A-Z_]+)"',
        'ok = false, reason = "([A-Z_]+)"', 'fail%([^)]- and "([A-Z_]+)" or [%w_]+%)' }) do add(srv, p) end
    add(readAll(MEDIA .. "/server/MinidoracatVehicleManager_PaidSlots.lua"), 'fail%("([A-Z_]+)"')
    add(readAll(MEDIA .. "/server/MinidoracatVehicleManager_Migration.lua"), 'return false, "([A-Z_]+)"')
    -- 帳本：只有載入判定與綁定前置條件的回傳會進 mutationAck（其他是 enforcement 或 lookup 結果）
    local os = readAll(MEDIA .. "/server/MinidoracatVehicleManager_OwnershipSystem.lua")
    for _, fn in ipairs({ "O%.ready%(%)", "O%.claimBlocked%(owner%)" }) do
        local body = assert(os:match("function " .. fn .. "(.-)\nend\n"), fn)
        add(body, 'return false, "([A-Z_]+)"')
        add(body, 'return "([A-Z_]+)"')
    end
    local missing = {}
    for _, lang in ipairs({ "CH", "CN", "EN", "JP" }) do
        local json = readAll(MEDIA .. "/shared/Translate/" .. lang .. "/IG_UI.json")
        for c in pairs(codes) do
            if not json:find('"IGUI_MVM_Reason_' .. c .. '": "', 1, true) then missing[#missing + 1] = lang .. ":" .. c end
        end
    end
    check(n >= 47 and codes.NOT_CLAIMABLE_TOWED and codes.RECIPIENT_QUOTA and codes.INVALID_PLAN and #missing == 0,
        "伺服器回給玩家的原因碼（" .. n .. " 個）四語都有 IGUI_MVM_Reason_*" .. (#missing > 0 and (" 缺 " .. table.concat(missing, " ")) or ""))
end
MVM.clientReceive("mutationAck", { to = "alice", requestId = "r", ok = false, reason = "PROTOCOL_MISMATCH" })
clientSent = {}
Cl.request(getSpecificPlayer(0), "reportLost", { expectedOid = "o2" })
check(#clientSent == 0, "收到 PROTOCOL_MISMATCH 後 client 停止送 mutation")
do -- 越權狀態（client）＋車上容器依權限開放（ClientGuards 包 BaseVehicle.canAccessContainer 的方法表）
    online = {}
    local me = player("carl", 1, 1)
    function me:isLocalPlayer() return self.remote ~= true end
    function me:getRole() return { hasCapability = function(_, cap) return me.admin == true and cap == "ManipulateVehicle" end } end
    local dirty = 0
    ISInventoryPage = { dirtyUI = function() dirty = dirty + 1 end }
    ISTimedActionQueue = { add = function() end, addAfter = function() end }
    for _, n in ipairs({ "ISEnterVehicle", "ISSwitchVehicleSeat", "ISAttachTrailerToVehicle", "ISDetachTrailerFromVehicle" }) do
        _G[n] = { isValid = function() return true end }
    end
    local vanilla = { canAccessContainer = function(v) return v.vanillaNo ~= true end }
    BaseVehicle = { class = "BaseVehicleClass" }
    __classmetatables = { BaseVehicleClass = { __index = vanilla } }
    assert(loadfile(MEDIA .. "/client/MinidoracatVehicleManager_ClientGuards.lua"))()
    local access = vanilla.canAccessContainer
    -- 零件：座位（容器座號 1）、置物箱、車斗、MOD 貨箱、油箱（有 script 容器但不是物品容器）
    local ids = { "Engine", "SeatFrontRight", "GloveBox", "TruckBed", "ModCargoBox", "GasTank" }
    local spec = { SeatFrontRight = 1, GloveBox = -1, TruckBed = -1, ModCargoBox = -1 }
    local function car4(id)
        local v = vehicle(id, 900 + id, 9900 + id, "Base.PickUp", 1, 1, ids)
        for pid, seat in pairs(spec) do
            v.parts[pid].getItemContainer = function() return {} end
            v.parts[pid].getContainerSeatNumber = function() return seat end
        end
        v.parts.GasTank.getItemContainer = function() return nil end
        v.parts.GasTank.getContainerSeatNumber = function() return -1 end
        local count = v.getPartCount
        v.scans = 0
        function v:getPartCount() self.scans = self.scans + 1; return count(self) end
        return v
    end
    local function idx(v, pid) for i, pt in ipairs(v.order) do if pt.id == pid then return i - 1 end end end
    local function can(v, pid, who) return access(v, idx(v, pid), who or me) end
    local free, bound = car4(41), car4(42)
    rawset(bound.parts.Engine.md, "MinidoracatVehicleManager", { oid = "oS" })
    check(MVM.containerAction(bound.parts.SeatFrontRight) == "PASSENGER" and MVM.containerAction(bound.parts.GloveBox) == "PASSENGER"
        and MVM.containerAction(bound.parts.TruckBed) == "CARGO" and MVM.containerAction(bound.parts.ModCargoBox) == "CARGO"
        and MVM.containerAction(bound.parts.GasTank) == nil, "容器對應：座位／置物箱→PASSENGER、其餘物品容器→CARGO、非物品容器不管")
    check(can(free, "TruckBed") and can(free, "SeatFrontRight"), "未綁定的車：容器照原版開放")
    check(not can(bound, "TruckBed") and not can(bound, "ModCargoBox") and not can(bound, "SeatFrontRight")
        and not can(bound, "GloveBox") and can(bound, "GasTank"), "他人的車：物品容器都不列出，油箱照原版")
    local remote = player("dora", 1, 1)
    function remote:isLocalPlayer() return false end
    check(can(bound, "TruckBed", remote), "只管本機玩家：別人的角色照原版")
    MVM.clientReceive("fleetSnapshot", { to = "carl", streamId = "k1", seq = 0,
        rows = { { oid = "oS", role = "MEMBER", state = "ACTIVE", myBits = MVM.ACTIONS.PASSENGER } } })
    check(can(bound, "SeatFrontRight") and can(bound, "GloveBox") and not can(bound, "TruckBed") and not can(bound, "ModCargoBox"),
        "只有搭乘：座位與置物箱可用，後車廂與 MOD 貨箱不列出")
    local d0 = dirty
    MVM.clientReceive("fleetDelta", { to = "carl", streamId = "k1", seq = 1, removes = {},
        upserts = { { oid = "oS", role = "MEMBER", state = "ACTIVE", myBits = MVM.ACTIONS.PASSENGER + MVM.ACTIONS.CARGO } } })
    check(dirty > d0 and can(bound, "TruckBed") and can(bound, "ModCargoBox"), "補上後車廂權限：重列物品欄，貨箱可用")
    MVM.clientReceive("fleetDelta", { to = "carl", streamId = "k1", seq = 2, removes = {},
        upserts = { { oid = "oS", role = "OWNER", state = "ACTIVE", grants = {} } } })
    bound.vanillaNo = true
    check(not can(bound, "TruckBed"), "原版 test 不給（門關著、距離）時照原版拒絕")
    bound.vanillaNo = nil
    check(can(bound, "TruckBed") and can(bound, "SeatFrontRight"), "車主：全部可用")
    MVM.clientReceive("fleetDelta", { to = "carl", streamId = "k1", seq = 3, removes = { "oS" }, upserts = {} })
    check(MVM.protectedText(me) == "IGUI_MVM_Protected", "一般玩家被擋：只說受車主保護")
    me.admin = true
    check(not can(bound, "TruckBed") and MVM.protectedText(me) == "IGUI_MVM_ProtectedAdmin",
        "管理員越權關閉：一樣不列出，提示多一句去管理頁開啟越權")
    d0 = dirty
    MVM.clientReceive("adminSnapshot", { to = "carl", id = "snap-c", part = 1, parts = 1, ok = true, rows = {}, players = {}, override = true })
    check(MVM.clientOverride(0) and dirty > d0 and can(bound, "TruckBed") and MVM.clientCanUse(me, bound, "DRIVE"),
        "越權中（adminSnapshot）：容器與動作都放行、重列物品欄")
    local toast
    HaloTextHelper.addBadText = function(_, t) toast = t end
    HaloTextHelper.addGoodText = HaloTextHelper.addBadText
    MVM.clientReceive("mutationAck", { to = "carl", requestId = "r-ov", requestKind = "setAdminOverride", ok = true, enabled = false })
    check(not MVM.clientOverride(0) and toast == "IGUI_MVM_Override_OffToast" and not can(bound, "TruckBed"),
        "關閉越權（ACK）：跳通知，容器回到不列出")
    HaloTextHelper.addBadText, HaloTextHelper.addGoodText = function() end, function() end
    MVM.clientReceive("mutationAck", { to = "carl", requestId = "r-ov2", requestKind = "setAdminOverride", ok = true, enabled = true })
    me.admin = false
    check(not MVM.clientOverride(0) and not can(bound, "TruckBed"), "撤銷管理員角色：舊越權 ACK 不得繼續開別人的容器")
    d0 = dirty
    fire("RefreshCheats")
    check(not Cl.buckets.carl.adminOverride and dirty > d0, "收到角色更新事件：清掉越權快取並重列物品欄")
    -- 見證快取：同一秒內問多個容器只掃一次零件，過了 1 秒才重掃
    local s0 = bound.scans
    for _ = 1, 5 do can(bound, "TruckBed"); can(bound, "GloveBox") end
    local once = bound.scans - s0
    nowMs = nowMs + 1100
    can(bound, "TruckBed")
    check(once <= 1 and bound.scans - s0 == once + 1, "見證快取：1 秒內多次查詢只掃一次零件，逾時才重掃")
    -- 公開分享：陌生人的客戶端靠公開表（快照 pub、publicDelta）知道能用哪些動作；撤權後回到他人的車
    me.admin = nil
    MVM.clientReceive("fleetSnapshot", { to = "carl", streamId = "k2", seq = 0, rows = {}, pub = { oS = MVM.ACTIONS.PASSENGER } })
    local pubOk, pubWhy = MVM.clientCanUse(me, bound, "PASSENGER")
    check(pubOk and pubWhy == "PUBLIC" and can(bound, "SeatFrontRight") and not can(bound, "TruckBed")
        and not MVM.clientCanUse(me, bound, "DRIVE") and MVM.clientProjection(0, bound).publicBits == MVM.ACTIONS.PASSENGER,
        "公開搭乘：陌生人可用座位與置物箱，後車廂與駕駛照擋")
    MVM.clientReceive("publicDelta", { to = "carl", oid = "oS", bits = MVM.ACTIONS.DRIVE + MVM.ACTIONS.CARGO })
    check(can(bound, "TruckBed") and MVM.clientCanUse(me, bound, "DRIVE") and MVM.clientCanUse(me, bound, "PASSENGER"),
        "publicDelta 改公開內容：立即生效（駕駛含搭乘）")
    MVM.clientReceive("publicDelta", { to = "carl", oid = "oS", bits = 0 })
    check(not can(bound, "SeatFrontRight") and Cl.buckets.carl.pub.oS == nil and not MVM.clientCanUse(me, bound, "PASSENGER"),
        "公開關閉：回到他人的車")
    me.admin = nil
    ISInventoryPage, ISTimedActionQueue, BaseVehicle, __classmetatables = nil, nil, nil, nil
    for _, n in ipairs({ "ISEnterVehicle", "ISSwitchVehicleSeat", "ISAttachTrailerToVehicle", "ISDetachTrailerFromVehicle" }) do _G[n] = nil end
end
isClient = serverIsClient

out("情境 25／31：reportLost finalize／cancel、inactivity")
boot()
A = player("alice", 0, 0)
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
ack = claim(A, car)
r = rec(ack.oid)
check(cmd(A, "reportLost", { expectedOid = r.oid }).ok and r.recordState == "PENDING_RELEASE", "reportLost → PENDING_RELEASE")
O.canUse(player("bob", 1, 1), car, "DRIVE")
check(r.recordState == "ACTIVE", "期間觀測到車 → 取消回 ACTIVE（lookup 觸發）")
cmd(A, "reportLost", { expectedOid = r.oid })
world[1], vehicleList = nil, {}
nowMs = nowMs + 23 * 3600000
O.maintain(true)
check(r.recordState == "PENDING_RELEASE", "未到 ReleaseFinalizeHours 維持 PENDING_RELEASE")
nowMs = nowMs + 2 * 3600000
O.maintain(true)
check(r.recordState == "RELEASED" and O.quotaUsed("alice") == 0, "到期未觀測 → RELEASED 釋放 quota")
nowMs = nowMs + 15 * 86400000
O.maintain(true)
check(rec(r.oid) == nil, "tombstone 保留期到 → 清除")
-- cancelRelease
car = vehicle(2, 102, 5002, "Base.CarNormal", 1, 1)
ack = claim(A, car)
r = rec(ack.oid)
cmd(A, "reportLost", { expectedOid = r.oid })
check(cmd(A, "cancelRelease", { expectedOid = r.oid }).ok and r.recordState == "ACTIVE", "cancelRelease → ACTIVE")
do -- 閒置釋放：車主最後在線超過天數 → 車直接解除綁定；在線時每分鐘刷新；伺服器停機的時間不算（主 chunk 區域變數已滿，用區塊）
SB.InactivityReleaseDays = 10
local function running(days) -- 伺服器一直在跑：上一次維護在一分鐘前
    nowMs = nowMs + days * 86400000
    O.state().lastMaintAtMs = nowMs - 60000
    O.maintain(true)
end
online = {}
O.state().ownerActivity.alice.lastSuccessfulLoginAtMs = nowMs
running(9)
check(r.recordState == "ACTIVE", "離線未滿天數：照常保護")
online = { A }
S.minute()
online = {}
running(9)
check(r.recordState == "ACTIVE", "在線時每分鐘刷新最後在線：從下線起重新算")
running(2)
check(r.recordState == "RELEASED" and O.quotaUsed("alice") == 0, "離線超過天數：直接解除綁定、釋放名額")
car = vehicle(3, 103, 5003, "Base.CarNormal", 1, 1)
r = rec(claim(A, car).oid)
O.state().ownerActivity.alice.lastSuccessfulLoginAtMs = nowMs
O.state().lastMaintAtMs = nowMs
nowMs = nowMs + 20 * 86400000
O.maintain(true)
check(r.recordState == "ACTIVE" and O.state().ownerActivity.alice.lastSuccessfulLoginAtMs == nowMs,
    "伺服器停機 20 天（兩次維護相隔很久）：停機時間不算，最後在線一起往後移")
SB.InactivityReleaseDays = 0
running(400)
check(r.recordState == "ACTIVE", "天數 0：關閉，不釋放")
end

out("情境 28：audit 清洗")
O.audit("INFO", "TEST", { actor = "evil\tname\r\n[x]", reason = "a\tb" })
local line = logLines[#logLines]
local fields = 0
for _ in line:gmatch("[^\t]*") do fields = fields + 1 end
check(not line:find("[\r\n%[%]]") and select(2, line:gsub("\t", "")) == 11, "username 中的 \\r\\n\\t[] 被清洗，欄位數固定")

out("情境 30／39：燒毀移除 → DESTROYED；終態不復活")
boot()
A = player("alice", 0, 0)
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
ack = claim(A, car)
ISRemoveBurntVehicle.complete({ vehicle = car, character = A })
check(rec(ack.oid).recordState == "DESTROYED", "同一物件三欄位全合 → DESTROYED")
car.removed = false
check(O.lookup(car):find("^UNCLAIMED") and rec(ack.oid).recordState == "DESTROYED", "終態 record 不因車晚載入而復活")
-- 別台車（keyId 不同）被移除不影響 record
boot()
A = player("alice", 0, 0)
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
ack = claim(A, car)
local lookalike = vehicle(2, 222, 5001, "Base.CarNormal", 1, 1)
ISRemoveBurntVehicle.complete({ vehicle = lookalike, character = A })
check(rec(ack.oid).recordState == "ACTIVE", "只靠 keyId 的車被移除不會終結 record")

out("情境 37：DropOffWhiteListAfterDeath → CONFIG_BLOCKED")
boot()
A = player("alice", 0, 0)
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
serverOpts.DropOffWhiteListAfterDeath = true
check(cmd(A, "prepareClaim", { vehicleId = 1 }).reason == "CONFIG_BLOCKED", "新 claim 被拒")
serverOpts.DropOffWhiteListAfterDeath = false

out("情境 38：SP adapter")
boot()
serverMode = false
local SPp = player("尼塔亨特", 0, 0)
local spGot = {}
local keepReceive = MVM.clientReceive
MVM.clientReceive = function(command, payload) spGot[#spGot + 1] = { command = command, payload = payload } end
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
local pa = nil
fire("OnClientCommand", MVM.MODULE, "prepareClaim", SPp, { protocol = MVM.PROTOCOL, requestId = "req-sp-000001", vehicleId = 1 })
for _, m in ipairs(spGot) do if m.command == "mutationAck" then pa = m.payload end end
check(pa and pa.ok and pa.to == "local:0", "SP：ACK 直接投遞，principal＝local:0")
check(#outbox["尼塔亨特"] == 0, "SP 不走 sendServerCommand")
fire("OnClientCommand", MVM.MODULE, "claim", SPp, { protocol = MVM.PROTOCOL, requestId = "req-sp-000002", claimAttemptId = pa.claimAttemptId })
local spRec = nil
for _, rr in pairs(O.state().recordsByOid) do spRec = rr end
check(spRec and spRec.ownerUser == "local:0", "SP owner 以 slot 保存，不隨角色姓名變動")
MVM.clientReceive = keepReceive
serverMode = true

out("情境 43：見證宿主選擇")
boot()
A = player("alice", 0, 0)
local trailer = vehicle(1, 101, 5001, "Base.Trailer", 1, 1, { "TrailerTrunk", "Wheel" })
ack = claim(A, trailer)
check(rec(ack.oid).witnessPartId == "TrailerTrunk", "無 Engine／Battery 時用 TrailerTrunk")
local odd = vehicle(2, 102, 5002, "Base.Odd", 1, 1, { "Seat" })
ack = claim(A, odd)
check(rec(ack.oid).witnessPartId == "Seat", "都沒有時用第 0 個 part")
odd.parts.Seat = nil
odd.order = { part("Other") }
check(O.canUse(player("bob", 1, 1), odd, "DRIVE") == false and rec(ack.oid).recordState == "WITNESS_STALE", "宿主消失 → WITNESS_STALE、照常執法")

out("情境：限流、unclaim、rename、dismiss")
boot()
A = player("alice", 0, 0)
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
ack = claim(A, car)
r = rec(ack.oid)
check(cmd(A, "rename", { expectedOid = r.oid, expectedEpoch = r.epoch, name = string.rep("長", 11) }).reason == "NAME_TOO_LONG", "車名超過 byte 上限")
check(cmd(A, "rename", { expectedOid = r.oid, expectedEpoch = r.epoch, name = "  My\tCar  " }).ok and r.customName == "MyCar", "車名去控制字元與頭尾空白")
check(cmd(A, "unclaim", { vehicleId = 1, expectedOid = r.oid, expectedEpoch = "uuid-stale0001" }).reason == "STALE_TARGET", "epoch 不符 → STALE_TARGET")
check(cmd(A, "unclaim", { vehicleId = 1, expectedOid = r.oid, expectedEpoch = r.epoch }).ok and r.recordState == "RELEASED" and witness(car) == nil, "unclaim：RELEASED 並清見證")
check(cmd(A, "dismissRecord", { expectedOid = r.oid }).ok and rec(r.oid) == nil, "dismiss tombstone")
local limited = nil
for i = 1, 25 do
    local p = { protocol = MVM.PROTOCOL, requestId = "req-rate-" .. string.format("%04d", i), expectedOid = "uuid-none0001" }
    fire("OnClientCommand", MVM.MODULE, "reportLost", A, p)
end
limited = lastOf(A, "mutationAck")
check(limited.reason == "RATE_LIMITED", "短時間大量請求 → RATE_LIMITED")


out("情境 P3：車隊視窗純邏輯")
ISCollapsableWindow = { derive = function(self, name) local c = setmetatable({ Type = name }, { __index = self }); c.__index = c; return c end }
isClient = function() return true end
assert(loadfile(MEDIA .. "/client/ISUI/MinidoracatVehicleManager_FleetWindow.lua"))()
isClient = function() return false end
local FU = MVM.FleetUI
local rowsT = {
    a = { oid = "a", role = "OWNER", name = "zeta truck", script = "Base.PickUpTruck", state = "ACTIVE", grants = {} },
    b = { oid = "b", role = "OWNER", name = "", script = "Base.CarNormal", state = "ACTIVE", grants = { { user = "bob", bits = 3 } } },
    c = { oid = "c", role = "MEMBER", name = "Alpha van", owner = "carol", state = "ACTIVE", myBits = 2 },
    d = { oid = "d", role = "FACTION", name = "beta", owner = "dave", state = "ACTIVE", myBits = 4 },
}
local owned = FU.filter(rowsT, "OWNED", "")
check(#owned == 2 and owned[1].oid == "b" and owned[2].oid == "a", "我的車分頁只含 owner 列，依名稱排序（無名稱用車型）")
local shared = FU.filter(rowsT, "SHARED", "")
check(#shared == 2 and shared[1].oid == "c" and shared[2].oid == "d", "分享給我分頁含成員與陣營列")
check(#FU.filter(rowsT, "SHARED", "CAROL") == 1 and #FU.filter(rowsT, "OWNED", "TRUCK") == 1, "搜尋不分大小寫、可搜車主")
check(#FU.filter(nil, "OWNED", "") == 0, "快照未到時回空清單")
local l = FU.bitsToList(MVM.ACTIONS.DRIVE + MVM.ACTIONS.TRACK + MVM.ACTIONS.MANAGE)
check(#l == 2 and l[1] == "DRIVE" and l[2] == "TRACK", "權限位轉清單（MANAGE 不列）")
check(FU.actionsText(MVM.ACTIONS.CARGO + MVM.ACTIONS.PASSENGER) == "IGUI_MVM_ActionShort_PASSENGERIGUI_MVM_ListSepIGUI_MVM_ActionShort_CARGO"
    and FU.actionsText(0) == "", "權限名稱顯示語系短名稱，依固定順序以語系分隔字連接，不露出原始代碼")
check(FU.listToBits({ "CARGO", "FUEL" }) == 12, "清單轉權限位")
check(FU.stateText({ state = "PENDING_RELEASE", releaseDueAtMs = nowMs + 90 * 60000 }, nowMs) == "IGUI_MVM_State_PENDING_RELEASE(2)", "等待釋放剩餘小時無條件進位")
check(FU.stateText({ state = "QUARANTINED" }, nowMs) == "IGUI_MVM_State_QUARANTINED", "狀態文字照 server 狀態")
check(FU.locationText({}, nowMs) == "IGUI_MVM_Location_Unknown", "沒有最後位置就說未知，不畫假座標")
check(FU.locationText({ lastKnownX = 10.7, lastKnownY = 20.2, lastKnownAtMs = nowMs - 5 * 60000 }, nowMs)
    == "IGUI_MVM_Location_LastKnown(10,20,IGUI_MVM_Ago_Minutes(5))", "最後位置與多久以前")
check(FU.locationText({ state = "PENDING_REBIND", lastKnownX = 7, lastKnownY = 8, lastKnownAtMs = nowMs }, nowMs)
    == "IGUI_MVM_Location_Imported(7,8)", "MVCK 待轉列：寫匯入時的位置，不寫時間（那是匯入時間，不是車被看到的時間）")
check(FU.agoText(nowMs - 30000, nowMs) == "IGUI_MVM_Ago_Now" and FU.agoText(nowMs - 3 * 3600000, nowMs) == "IGUI_MVM_Ago_Hours(3)"
    and FU.agoText(nowMs - 5 * 86400000, nowMs) == "IGUI_MVM_Ago_Days(5)", "多久以前：剛剛／小時／天，不出現上千分鐘")
check(FU.shareText({ role = "MEMBER", owner = "carol" }) == "IGUI_MVM_Share_ViaMember(carol)", "成員看到分享者")
check(FU.publicBits(MVM.SHAREABLE_MASK) == MVM.PUBLIC_MASK and FU.publicBits(MVM.ACTIONS.TRACK + MVM.ACTIONS.TOW) == 0,
    "公開給所有人只帶得了公開允許的動作（位置、拖曳、拆解不帶）")
do -- 保留期限：天數 0 不顯示；日期照語系排列、月日補零
    local at = os.time({ year = 2026, month = 1, day = 2, hour = 12 }) * 1000
    check(FU.keptText(0, at) == nil and FU.keptText(30, at) == "IGUI_MVM_KeptUntil(IGUI_MVM_Date(2026,02,01))",
        "保留到＝現在＋天數，天數 0 不顯示")
    local b = { streamId = "s", releaseDays = 30 }
    local function line(rows, needle) for _, l in ipairs(rows) do if l.text:find(needle, 1, true) then return l end end end
    local own = FU.cardLines({ role = "OWNER", state = "ACTIVE", name = "", script = "Base.CarNormal" }, "OWNED", b, "", at)
    local shared = FU.cardLines({ role = "MEMBER", owner = "carol", myBits = 1, state = "ACTIVE", script = "Base.CarNormal" }, "SHARED", b, "", at)
    check(line(own, "IGUI_MVM_KeptUntil") ~= nil and line(shared, "IGUI_MVM_KeptUntil") == nil and line(shared, "IGUI_MVM_YourActions") ~= nil,
        "詳情卡：車主看得到保留期限，被分享的人看到你能做什麼")
    local empty = FU.cardLines(nil, "OWNED", b, "", at)
    check(empty[1].text == "IGUI_MVM_Empty" and empty[2].text == "IGUI_MVM_EmptyHint" and FU.cardLines(nil, "SHARED", b, "", at)[1].text == "IGUI_MVM_EmptyShared",
        "空清單：我的車指出怎麼綁定，分享給我另一句")
    local loc = FU.cardLines({ role = "OWNER", state = "ACTIVE", name = "", script = "Base.CarNormal", lastKnownX = 8184.7,
        lastKnownY = 11279.2, lastKnownZ = 1, lastKnownAtMs = at - 60000 }, "OWNED", b, "", at)
    local copied = nil
    for _, l in ipairs(loc) do if l.copy then copied = l end end
    check(copied and copied.text:find("IGUI_MVM_Location_LastKnown", 1, true) and copied.copy == "8184,11279,1",
        "詳情卡的位置列可以點擊複製：x,y,z 取整")
    check(FU.coordsText({ state = "PENDING_REBIND", lastKnownX = 11871, lastKnownY = 7044 }) == "11871,7044,0"
        and FU.coordsText({ state = "ACTIVE", lastKnownX = 1, lastKnownY = 2 }) == nil and FU.coordsText({ state = "ACTIVE" }) == nil,
        "待轉入複製匯入時的位置（樓層記 0）；卡片寫「位置不明」時沒有複製")
end
local many, names = {}, { "g", "c", "e", "a", "f", "b", "d" }
for i, nm in ipairs(names) do many["o" .. i] = { oid = "o" .. i, role = "OWNER", name = nm, state = "ACTIVE", grants = {} } end
local sorted, seq = FU.filter(many, "OWNED", ""), ""
for _, row in ipairs(sorted) do seq = seq .. row.name end
check(seq == "abcdefg", "奇數筆亂序名稱排序正確（合併排序）")
do -- 管理頁：依車主分組（玩家依帳號排序、沒有車主的隔離紀錄自成一組），點開才列車；車先列受保護與待處理、歷史紀錄最後
    local adminRows = {
        { oid = "r1", owner = "bob", name = "", script = "Base.Van", state = "ACTIVE" },
        { oid = "r2", owner = "alice", name = "Zed", script = "Base.CarNormal", state = "RELEASED" },
        { oid = "r3", owner = "alice", name = "Yak", script = "Base.CarNormal", state = "ACTIVE" },
        { oid = "r4", name = "", script = "Base.CarNormal", state = "QUARANTINED" },
        { oid = "legacy-1", owner = "alice", name = "", script = "Base.PickUpTruck", state = "PENDING_REBIND" },
    }
    local adminPlayers = { { user = "bob", used = 1, base = 3, limit = 3 }, { user = "alice", used = 2, base = 3, limit = 3 },
        { user = "carl", used = 0, base = 5, limit = 5, custom = true } }
    local function adminSeq(query, expanded)
        local s = ""
        for _, it in ipairs(FU.adminItems(adminRows, adminPlayers, query, expanded)) do
            s = s .. (it.kind == "PLAYER" and ("[" .. it.user .. (it.open and "+" or "") .. "]") or it.oid)
        end
        return s
    end
    check(adminSeq("", {}) == "[][alice][bob][carl]", "管理頁預設只列玩家，依帳號排序；只有名額設定的玩家也在")
    check(adminSeq("", { alice = true }) == "[][alice+]legacy-1r3r2[bob][carl]", "展開的玩家底下先列受保護與待轉的車，歷史紀錄最後")
    check(adminSeq("yak", {}) == "[alice+]r3" and adminSeq("PICKUP", {}) == "[alice+]legacy-1",
        "搜尋車名或車型：只留符合的車，所屬玩家自動展開")
    check(adminSeq("BOB", {}) == "[bob]" and adminSeq("zzz", {}) == "", "搜尋玩家帳號列出該玩家；沒有結果時清單為空")
    local items = FU.adminItems(adminRows, adminPlayers, "", {})
    check(items[2].summary == "IGUI_MVM_Admin_Protected(1)IGUI_MVM_SepIGUI_MVM_Admin_Rebind(1)IGUI_MVM_SepIGUI_MVM_Admin_History(1)"
        and items[4].summary == "IGUI_MVM_Admin_NoVehicles", "玩家摘要只列非零的狀態筆數，沒有車時明說")
    -- 批次選取：切換、沒有車主的組不能選、全選目前清單（只含搜尋結果裡的玩家）、清除、計數
    local picked = {}
    local function names() return table.concat(FU.pickedList(picked), ",") end
    check(FU.togglePick(picked, items[2]) and names() == "alice" and FU.togglePick(picked, items[2]) and names() == "",
        "勾選框切換：選取後再按一次取消")
    check(not FU.togglePick(picked, items[1]) and names() == "", "沒有車主的隔離紀錄組不能選")
    check(not FU.togglePick(picked, { kind = nil, oid = "r1", owner = "bob" }) and names() == "", "車輛列不能選")
    FU.pickShown(picked, FU.adminItems(adminRows, adminPlayers, "BOB", {}))
    check(names() == "bob", "全選目前清單只加入搜尋結果裡的玩家")
    FU.pickShown(picked, FU.adminItems(adminRows, adminPlayers, "", { alice = true }))
    check(names() == "alice,bob,carl" and #FU.pickedList(picked) == 3, "全選目前清單：所有玩家列（略過車輛列與無車主組），依帳號排序計數")
    FU.clearPicks(picked)
    check(names() == "" and next(picked) == nil, "清除選取")
end
-- 見證遺失的 WITNESS_STALE 車：身邊同車型、沒有見證的車當作候選；別車型、太遠的不選
boot()
local me = player("alice", 1, 1)
local farCar = vehicle(1, 101, 5001, "Base.CarNormal", 30, 30)
local otherType = vehicle(2, 102, 5002, "Base.Van", 1, 2)
local nearCar = vehicle(3, 103, 5003, "Base.CarNormal", 2, 1)
local realProj = MVM.clientProjection
MVM.clientProjection = function() return nil end
check(FU.findLoaded({ oid = "x", state = "WITNESS_STALE", script = "Base.CarNormal" }) == nearCar, "WITNESS_STALE：找身邊同車型的車交給 server 驗證")
check(FU.findLoaded({ oid = "x", state = "ACTIVE", script = "Base.CarNormal" }) == nil, "ACTIVE 仍只認見證 oid，不猜車")
MVM.clientProjection = realProj


out("情境 P4-1：即時位置只送給有 TRACK 的人，節流與心跳")
boot()
local TK = MVM.Tracking
local AO, BT, DN, EX = player("owner", 1, 1), player("tracker", 1, 1), player("notrack", 1, 1), player("stranger", 1, 1)
local tcar = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
local tack = claim(AO, tcar)
cmd(AO, "addMember", { expectedOid = tack.oid, username = "tracker", actionBits = MVM.ACTIONS.PASSENGER + MVM.ACTIONS.TRACK })
cmd(AO, "addMember", { expectedOid = tack.oid, username = "notrack", actionBits = MVM.ACTIONS.DRIVE })
local function tracks(p) local n = 0; for _, m in ipairs(outbox[p.name]) do if m.command == "trackDelta" then n = n + 1 end end; return n end
tcar.seats[0] = AO; AO.vehicle = tcar
nowMs = nowMs + 600; TK.tick()
check(tracks(AO) == 1 and tracks(BT) == 1 and tracks(DN) == 0 and tracks(EX) == 0, "開車時只有 owner 與 TRACK 成員收到位置")
nowMs = nowMs + 100; TK.tick()
check(tracks(AO) == 1, "500 ms 內不重送")
nowMs = nowMs + 600; TK.tick()
check(tracks(AO) == 1, "沒移動不送")
tcar.x = 4; nowMs = nowMs + 600; TK.tick()
check(tracks(AO) == 2 and lastOf(AO, "trackDelta").x == 4, "移動 ≥1 格就送新位置")
nowMs = nowMs + 5100; TK.tick()
check(tracks(AO) == 3, "5 秒心跳重送（剛取得權限的人也拿得到即時）")
tcar.x = 40; tcar.seats[0] = nil; AO.vehicle = nil
nowMs = nowMs + 600; TK.tick()
check(tracks(AO) == 4 and rec(tack.oid).lastKnownX == 40, "下車：最後一次取樣並寫入帳本 lastKnown")

out("情境 P4-2：MiniMap provider 只畫自己的車與 TRACK 分享車")
local registered = nil
MinidoracatMiniMapAPI = { markerApiVersion = 1, registerMarkerProvider = function(owner, fn) registered = { owner = owner, fn = fn } end,
    settingsApiVersion = 2, registerSettingsSection = function(owner, spec) registered.settings = { owner = owner, spec = spec } end }
function getTexture(path) return path end
isClient = function() return true end
online = {}
local me = player("alice", 1, 1)
assert(loadfile(MEDIA .. "/client/MinidoracatVehicleManager_MiniMapBridge.lua"))()
MVM.MiniMapBridge.register()
check(registered and registered.owner == "MinidoracatVehicleManagerFor42", "偵測到 markerApiVersion 就註冊 provider")
MVM.clientReceive("fleetSnapshot", { to = "alice", streamId = "t1", seq = 0, rows = {
    { oid = "own", role = "OWNER", name = "Mine", state = "ACTIVE", lastKnownX = 10, lastKnownY = 20, lastKnownAtMs = nowMs },
    { oid = "trk", role = "MEMBER", name = "Tracked", state = "ACTIVE", myBits = MVM.ACTIONS.TRACK, lastKnownX = 30, lastKnownY = 40, lastKnownAtMs = nowMs },
    { oid = "hid", role = "MEMBER", name = "Hidden", state = "ACTIVE", myBits = MVM.ACTIONS.DRIVE },
    { oid = "rel", role = "OWNER", name = "Gone", state = "RELEASED", lastKnownX = 1, lastKnownY = 1, lastKnownAtMs = nowMs },
} })
MVM.clientReceive("trackDelta", { to = "alice", oid = "own", x = 11, y = 21, z = 0, t = nowMs })
local res = registered.fn(0, "mini")
local byId = {}
for _, m in ipairs(res.markers) do byId[m.id] = m end
check(#res.markers == 2 and byId.own and byId.trk, "只有自己的車與 TRACK 分享車（無 TRACK、已釋放不畫）")
check(byId.own.x == 11 and byId.trk.x == 30 and byId.own.state == "live" and byId.trk.state == "live",
    "位置優先用新鮮的即時座標，否則用最後已知；正常受保護的車都不淡化")
check(registered.fn(0, "world") == res, "投影未變時回同一張快取表")
check(registered.fn(1, "mini") == nil, "分割畫面第二位玩家不給標記（v1 不支援）")
nowMs = nowMs + 11000
do
    local ms = registered.fn(0, "mini").markers
    local own = ms[1].id == "own" and ms[1] or ms[2]
    check(own.x == 10, "即時位置超過 10 秒改用最後已知座標")
end
MVM.clientReceive("fleetDelta", { to = "alice", streamId = "t1", seq = 1, upserts = {
    { oid = "trk", role = "MEMBER", name = "Tracked", state = "PENDING_RELEASE", myBits = MVM.ACTIONS.TRACK, lastKnownX = 30, lastKnownY = 40, lastKnownAtMs = nowMs } },
    removes = {} })
do
    local dim = nil
    for _, m in ipairs(registered.fn(0, "mini").markers) do if m.id == "trk" then dim = m end end
    check(dim and dim.state ~= "live", "狀態異常（待釋放）的車才淡化")
end
MVM.clientReceive("fleetDelta", { to = "alice", streamId = "t1", seq = 2, upserts = {}, removes = { "trk" } })
check(#registered.fn(0, "mini").markers == 1, "撤權（列被移除）後標記消失")
do
-- 外觀：v1 MiniMap 不帶 v2 欄位；預設依角色著色、依車型挑圖示；自訂後持久化並立刻換快取
local AP = MVM.Appearance
local m1 = registered.fn(0, "mini").markers[1]
check(m1.badge == nil and m1.ring == nil and m1.r == AP.OWN.r and m1.g == AP.OWN.g, "MiniMap v1：不送 v2 欄位，自己的車用預設金黃")
check(AP.iconFor("Base.PickUpVanLightsPolice") == "carPolice" and AP.iconFor("Base.PickUpTruck") == "carPickup"
    and AP.iconFor("Base.StepVan") == "carStepVan" and AP.iconFor("Base.TrailerCover") == "carTrailer"
    and AP.iconFor("Base.CarNormal") == "carSedan", "依 script 猜車型圖示（警用皮卡算警車）")
MinidoracatMiniMapAPI = { markerApiVersion = 2 }
AP.set("own", { r = 0.2, g = 0.4, b = 0.6 }, "markerStar", 250)
local m2 = registered.fn(0, "mini").markers[1]
check(m2.r == 0.2 and m2.b == 0.6 and m2.ring and m2.ring.g == 0.4 and m2.badge and m2.scale == 2.5,
    "MiniMap v2：自訂顏色與大小套到圖示與外環，帶深色圓底")
AP._resetForTests()
local cr, ci, custom, cs = AP.get({ oid = "own", role = "OWNER", script = "Base.CarNormal" })
check(custom and cr.g == 0.4 and ci == "markerStar" and cs == 250, "自訂外觀（含大小）從本機檔案讀回")
check(AP.scale(nil) == 1.75 and AP.scale(90) == 1 and AP.scale(999) == 2.5, "大小缺值用預設 175%，超界夾在 100%～250%")
AP.reset("own")
local _, ci2, custom2 = AP.get({ oid = "own", role = "OWNER", script = "Base.CarNormal" })
check(not custom2 and ci2 == "carSedan", "恢復預設後回到依車型的圖示")
check(MVM.FleetUI.renamed({ name = "Mine" }) and not MVM.FleetUI.renamed({ name = "" })
    and MVM.FleetUI.modelName({ script = "Base.CarNormal" }) == "CarNormal", "改名判定與原始車名（無譯名時用 script 名）")
end
do -- 小地圖車名：MiniMap 設定視窗「車輛管理」分類的勾選框；關掉時小地圖的車標不帶車名、世界地圖照常，偏好存本機檔
    local AP = MVM.Appearance
    local settingsSpec = registered.settings
    local tick = settingsSpec and settingsSpec.spec.ticks and settingsSpec.spec.ticks[1]
    check(settingsSpec and settingsSpec.owner == "MinidoracatVehicleManagerFor42" and settingsSpec.spec.label == "IGUI_MVM_SourceName"
        and tick and tick.label == "IGUI_MVM_MiniMapNames" and tick.default == true and tick.get() == true,
        "在 MiniMap 設定視窗註冊「車輛管理」分類，車名預設開")
    local function labels(surface)
        local n, ms = 0, registered.fn(0, surface).markers
        for _, m in ipairs(ms) do if m.label then n = n + 1 end end
        return n, #ms
    end
    tick.set(false)
    local mn, mt = labels("mini")
    local wn, wt = labels("world")
    check(mt > 0 and mn == 0 and wt == mt and wn == wt, "關掉後小地圖的車標不帶車名，世界地圖照常帶")
    AP._resetForTests()
    check(tick.get() == false and labels("mini") == 0, "偏好存在本機檔，重新讀回仍是關")
    tick.set(true)
    check(labels("mini") == mt, "打開後小地圖恢復車名")
end
MVM.MiniMapBridge.registered = nil
MinidoracatMiniMapAPI = nil
check(pcall(MVM.MiniMapBridge.register) and not MVM.MiniMapBridge.registered, "沒有 MiniMap 時安靜不註冊")
isClient = function() return false end


do
out("情境 P5：MVCK 遷移")
local MG = MVM.Migration
check(MG.embeddedSqlId(1700000000174, 174) and not MG.embeddedSqlId(1700000000174, 74) and not MG.embeddedSqlId(1700000000174, 999)
    and not MG.embeddedSqlId(1700000000174, -1), "舊 ID 內嵌 sqlId 拆法唯一（10 位時間戳）")
check(MG.intStr(1777000123000456) == "1777000123000456", "大整數轉字串不失精度")
local function seedLegacy()
    gmd.MVCKByVehicleSQLID = {
        [1700000000101] = { OwnerPlayerID = "alice", CarModel = "Base.CarNormal", ClaimDateTime = 1700000000, LastLocationX = 5, LastLocationY = 6,
            AllowDrive = true },
        [1700000000102] = { OwnerPlayerID = "alice", CarModel = "Base.Van", ClaimDateTime = 1700000000, LastLocationX = 7, LastLocationY = 8,
            AllowPassenger = true, AllowUninstallParts = true, AllowAttachVehicle = true },
        [1700000000103] = { OwnerPlayerID = "bad\nname", CarModel = "Base.Van" },
    }
    gmd.MVCKByPlayerID = { alice = { [1700000000101] = true, LastKnownLogonTime = 1 } }
end
boot()
local AD5 = player("admin5", 1, 1, { admin = true })
cmd(AD5, "adminList", {}, false)
check(lastOf(AD5, "adminSnapshot").migrationAvailable == false, "沒有 MVCK 舊資料時不提供匯入入口")
seedLegacy()
cmd(AD5, "adminList", {}, false)
local migrationSnapshot = lastOf(AD5, "adminSnapshot")
check(migrationSnapshot.migrationAvailable and #migrationSnapshot.rows == 0,
    "偵測到 MVCK 舊資料時提供匯入入口，不依賴已有車輛紀錄")
check(cmd(player("eve2", 1, 1), "adminMigration", { op = "IMPORT" }).reason == "NOT_ADMIN", "非管理員不能匯入")
check(cmd(AD5, "adminMigration", { op = "FINALIZE" }).reason == "BAD_ARGS", "只接受 IMPORT")
-- 已載入的真車：按下匯入就當場轉正
local real = vehicle(1, 101, 7001, "Base.CarNormal", 1, 1)
real:getModData().SQLID = 1700000000101
-- 並存期間、匯入前：MVCK 綁著的車誰都不能先綁（否則別人先綁走，匯入後原車主的待轉項永遠對不上）
activeMods["Mysterious Vehicle Claim Key"] = true
local bob5, alice5 = player("bob5", 1, 1), player("alice", 1, 1)
check(claim(bob5, real).reason == "LEGACY_CLAIMED" and claim(alice5, real).reason == "LEGACY_CLAIMED" and O.lookup(real) == "UNCLAIMED",
    "MVCK 還在、還沒匯入：MVCK 綁著的車陌生人與原車主都不能綁（LEGACY_CLAIMED）")
local plain5 = vehicle(5, 105, 7005, "Base.CarNormal", 1, 1)
check(cmd(bob5, "prepareClaim", { vehicleId = plain5.id }).ok, "沒有 MVCK 舊 ID 的車照常可綁")
activeMods["Mysterious Vehicle Claim Key"] = nil
check(cmd(bob5, "prepareClaim", { vehicleId = real.id }).ok, "MVCK 已從 Mods= 拿掉：舊表還在也不擋（沒匯入的伺服器照常綁）")
activeMods["Mysterious Vehicle Claim Key"] = true -- MVCK 還在也能匯入
local im = cmd(AD5, "adminMigration", { op = "IMPORT" })
check(claim(bob5, real).reason == "ALREADY_CLAIMED", "匯入後：那台車已轉給原車主，別人綁回 ALREADY_CLAIMED")
activeMods["Mysterious Vehicle Claim Key"] = nil
check(im.ok and im.imported == 2 and im.skipped == 1 and im.rebound == 1 and im.pending == 1, "一鍵匯入：兩筆合格、一筆壞資料略過；已載入的車當場轉正")
check(gmd.MVCKByVehicleSQLID ~= nil and gmd.MVCKByVehicleSQLID[1700000000101] ~= nil and gmd.MVCKByPlayerID ~= nil, "不刪 MVCK 原始資料")
local verdict5, rec5 = O.lookup(real)
check(verdict5 == "AUTHORIZED" and rec5.ownerUser == "alice" and witness(real).oid == rec5.oid, "轉正為 alice 的受保護車並寫見證")
check(rec5.publicBits == MVM.ACTIONS.DRIVE and S.publicTable()[rec5.oid] == MVM.ACTIONS.DRIVE,
    "MVCK 的公共權限（允許駕駛）轉正時帶成公開分享，進公開表")
local pe = O.state().pendingRebindByLegacyKey[1700000000102]
check(pe.ownerUser == "alice" and pe.vehicleScript == "Base.Van" and pe.AllowPassenger == nil and pe.claimedAtMs == 1700000000000
    and pe.publicBits == MVM.ACTIONS.PASSENGER,
    "未載入的車留為待轉項：只帶白名單欄位；公共權限轉成公開位元（拆零件、掛拖車不帶入）")
local again = cmd(AD5, "adminMigration", { op = "IMPORT" })
check(again.ok and again.imported == 0 and again.already == 2 and O.state().pendingRebindByLegacyKey[1700000000101] == nil,
    "重複執行不重複匯入，已轉正的不會變回待轉")
gmd.MVCKByVehicleSQLID[1700000000104] = { OwnerPlayerID = "alice", CarModel = "Base.CarNormal", ClaimDateTime = 1700000100 }
check(cmd(AD5, "adminMigration", { op = "IMPORT" }).imported == 1, "MVCK 之後新增的綁定，再按一次會補進來")
check(O.quotaUsed("alice") == 3, "待轉項與已轉正的車都計入 quota")
-- 管理員總表：待轉列帶車主一起列出；每位玩家附已用／基本／上限，只設定過名額的玩家也在
local function adminPlayer(user)
    cmd(AD5, "adminList", {}, false)
    local snap = lastOf(AD5, "adminSnapshot")
    local pend = 0
    for _, row in ipairs(snap.rows) do if row.state == "PENDING_REBIND" and row.owner == "alice" then pend = pend + 1 end end
    for _, pl in ipairs(snap.players) do if pl.user == user then return pl, pend end end
    return nil, pend
end
local ap, pendRows = adminPlayer("alice")
check(pendRows == 2 and ap and ap.used == 3 and ap.base == 3 and ap.limit == 3 and not ap.custom,
    "管理員總表列出待轉車與每位玩家的已用／基本／上限")
do -- 總表一次掃完累計的已用／上限，要跟逐人 O.quotaUsed／O.quotaLimit 一樣（alice 有轉正的車＋待轉項）
    cmd(AD5, "adminList", {}, false)
    local same, n = true, 0
    for _, pl in ipairs(lastOf(AD5, "adminSnapshot").players) do
        n = n + 1
        if pl.used ~= O.quotaUsed(pl.user) or pl.limit ~= O.quotaLimit(pl.user) then same = false end
    end
    check(same and n == 1, "總表一次掃完的已用／上限與逐人計算相同（含待轉項）")
end
check(cmd(AD5, "adminSetQuota", { usernames = { "alice" }, amount = 5 }).ok and adminPlayer("alice").custom
    and adminPlayer("alice").base == 5 and adminPlayer("alice").limit == 5, "管理員設定的基本名額標為自訂並算進上限")
check(cmd(AD5, "adminSetQuota", { usernames = { "alice" }, amount = -1 }).ok and not adminPlayer("alice").custom
    and adminPlayer("alice").base == 3, "恢復預設後回到沙盒基本名額")
cmd(AD5, "adminSetQuota", { usernames = { "zed" }, amount = 2 })
local zp = adminPlayer("zed")
check(zp and zp.used == 0 and zp.custom and zp.limit == 2, "還沒有車、只設定過名額的玩家也列在總表")
cmd(AD5, "adminSetQuota", { usernames = { "zed" }, amount = -1 })
local A5 = player("alice", 0, 0)
cmd(A5, "fleetSubscribe", {}, false)
local prow = nil
for _, r in ipairs(lastOf(A5, "fleetSnapshot").rows) do if r.oid == "legacy-1700000000102" then prow = r end end
check(prow and prow.state == "PENDING_REBIND", "車主快照含待轉列")
-- 重啟：待轉項跟著帳本保存
disk, gmdSaved = GOS.snapshot(), deepcopy(gmd)
boot(disk, true); gmd = gmdSaved
A5 = player("alice", 0, 0)
cmd(A5, "fleetSubscribe", {}, false)
check(O.state().pendingRebindByLegacyKey[1700000000102] ~= nil and O.ready(), "待轉項跨重啟保留")
-- 偽造：別台同型車身寫同一個舊 ID（server sqlId 不是內嵌的 102），原車在場 → 規則 2 的 (b) 擋下
local van = vehicle(3, 102, 7003, "Base.Van", 1, 1)
van:getModData().SQLID = 1700000000102
local decoy = vehicle(2, 555, 7002, "Base.Van", 1, 1)
decoy:getModData().SQLID = 1700000000102
check(O.lookup(decoy) == "UNCLAIMED" and O.state().pendingRebindByLegacyKey[1700000000102] ~= nil, "車身 SQLID 被偽造到別台同型車、原車在場：不轉正")
local nlog = #logLines
O.lookup(decoy)
check(#logLines == nlog, "不符只記一次")
local v5, r5 = O.lookup(van)
check(v5 == "AUTHORIZED" and r5.ownerUser == "alice" and O.state().pendingRebindByLegacyKey[1700000000102] == nil,
    "原車被查到：轉正為 ACTIVE、刪待轉項")
local removedPending = false
for _, m in ipairs(outbox.alice) do if m.command == "fleetDelta" then for _, r in ipairs(m.payload.removes) do if r == "legacy-1700000000102" then removedPending = true end end end end
check(removedPending, "車主收到撤掉待轉列的 delta")
check(O.canUse(player("eve", 1, 1), van, "DRIVE") == false, "轉正後他人被拒")
-- 車主放棄待轉項（使用者 2026-10-06：W900 貨櫃裝卸後舊編號消失、轉不了正的車主不用等 RebindDeadlineDays）
O.mapSet("pendingRebindByLegacyKey", 1700000000777, { legacyVehicleId = 1700000000777, ownerUser = "alice", vehicleScript = "Base.Van",
    importedAtMs = nowMs })
local used7, log7 = O.quotaUsed("alice"), #logLines
check(cmd(player("eve", 1, 1), "cancelRebind", { expectedOid = "legacy-1700000000777" }).reason == "NOT_OWNER"
    and O.state().pendingRebindByLegacyKey[1700000000777] ~= nil, "別人不能放棄這筆待轉項：NOT_OWNER，待轉項還在")
check(cmd(A5, "cancelRebind", { expectedOid = "legacy-12x" }).reason == "BAD_ARGS"
    and cmd(A5, "cancelRebind", { expectedOid = r5.oid }).reason == "BAD_ARGS", "待轉列 oid 格式不對（含一般紀錄的 UUID）：BAD_ARGS")
check(cmd(A5, "cancelRebind", { expectedOid = "legacy-1700000000778" }).reason == "NO_SUCH_RECORD", "沒有這筆待轉項：NO_SUCH_RECORD")
local cr = cmd(A5, "cancelRebind", { expectedOid = "legacy-1700000000777" })
local dropped, audited = false, false
for _, m in ipairs(outbox.alice) do if m.command == "fleetDelta" then for _, r in ipairs(m.payload.removes) do if r == "legacy-1700000000777" then dropped = true end end end end
for i = log7 + 1, #logLines do if logLines[i]:find("REBIND_CANCELLED legacy=1700000000777", 1, true) then audited = true end end
check(cr.ok and O.state().pendingRebindByLegacyKey[1700000000777] == nil and O.quotaUsed("alice") == used7 - 1 and dropped and audited,
    "車主放棄待轉項：刪掉、名額立刻少 1、車主收到撤列 delta、稽核 REBIND_CANCELLED")
local late = vehicle(9, 777, 7777, "Base.Van", 1, 1)
late:getModData().SQLID = 1700000000777
check(O.lookup(late) == "UNCLAIMED", "放棄後那台車才出現：不再轉給原車主（是沒綁定的車）")
-- 逾期
SB.RebindDeadlineDays = 1
nowMs = nowMs + 2 * 86400000
MG.expire(true)
check(O.state().pendingRebindByLegacyKey[1700000000104] == nil and O.quotaUsed("alice") == 2, "逾期未對上的待轉項刪除並釋放 quota")
SB.RebindDeadlineDays = 30
end

do
out("情境 P5b：換號的車（MSW 拖車裝卸後 sqlId 換新、車身 SQLID 與車型保留）")
boot()
local ADm = player("adminM", 1, 1, { admin = true })
local L = { moved = 1700000000201, mm = 1700000000301, a1 = 1700000000401, a2 = 1700000000402, b = 1700000000501,
    c1 = 17000000012047, c2 = 17000000022047 }
local function entry(owner, model) return { OwnerPlayerID = owner, CarModel = model, ClaimDateTime = 1700000000 } end
gmd.MVCKByVehicleSQLID = { [L.moved] = entry("bob", "Base.SemiTruck"), [L.mm] = entry("bob", "Base.Van"),
    [L.a1] = entry("carol", "Base.Truck"), [L.a2] = entry("dave", "Base.Truck"), [L.b] = entry("erin", "Base.Pickup"),
    [L.c1] = entry("p0159", "Base.85chevyStepVan"), [L.c2] = entry("p0164", "Base.93fordF350") }
local function car(id, sqlId, model, legacy)
    local v = vehicle(id, sqlId, 8000 + id, model, 1, 1)
    v:getModData().SQLID = legacy
    return v
end
local moved = car(1, 700, "Base.SemiTruck", L.moved)   -- 換號：內嵌 201，現在 700
local wrongModel = car(2, 800, "Base.CarNormal", L.mm) -- 車型不同
local taken = car(3, 402, "Base.Truck", L.a1)          -- 換號後的 402 是 a2（同車型）內嵌的 sqlId
local fake = car(4, 900, "Base.Pickup", L.b)           -- 偽造：同型、b 的原車在場
local orig = car(5, 501, "Base.Pickup", L.b)
local stepVan = car(6, 3379, "Base.85chevyStepVan", L.c1) -- 撞號：2047 換到 3379，2047 回收給 F350
local f350 = car(7, 2047, "Base.93fordF350", L.c2)
local pend = O.state().pendingRebindByLegacyKey
local im = cmd(ADm, "adminMigration", { op = "IMPORT" })
local function owner(v) local verdict, rec = O.lookup(v); return verdict == "AUTHORIZED" and rec.ownerUser or nil end
local function logged(text) for _, l in ipairs(logLines) do if l:find(text, 1, true) then return true end end return false end
check(im.ok and im.imported == 7 and im.rebound == 4 and im.pending == 3, "匯入：規則 1／2 當場轉正 4 台，3 筆留待轉")
check(owner(moved) == "bob" and pend[L.moved] == nil and logged("REBOUND_MOVED"), "換號的車以規則 2 轉正（稽核 REBOUND_MOVED）")
check(owner(wrongModel) == nil and pend[L.mm] ~= nil and logged("REBIND_MISMATCH"), "車型不同一律不轉正")
check(owner(taken) == nil and pend[L.a1] ~= nil and pend[L.a2] ~= nil and logged("REBIND_MOVED_TAKEN"),
    "換號後的 sqlId 是另一筆同車型待轉項的內嵌 sqlId：不轉正")
taken:getModData().SQLID = L.a2
check(owner(taken) == "dave" and pend[L.a2] == nil and pend[L.a1] ~= nil, "那一筆的原車照規則 1 轉正")
check(owner(fake) == nil and owner(orig) == "erin" and logged("REBIND_MOVED_ORIGINAL_LOADED"),
    "原車在場時，偽造 SQLID 的同型車不轉正，原車照規則 1 轉正")
check(owner(stepVan) == "p0159" and owner(f350) == "p0164", "2047 撞號：換號的 StepVan 與拿到回收 2047 的 F350 各歸其主")
check(MVM.Migration.embedded(17000000012047) == 2047 and MVM.Migration.embedded(17000000010) == 0
    and MVM.Migration.embedded(1700000000) == nil and MVM.Migration.embedded(17000000010047) == nil, "內嵌 sqlId 拆出（前導 0 不是 sqlId）")
-- 匯入時還在 MSW 倉儲裡的車：卸車 addVehicleDebug 生車時（OnSpawnVehicleEnd）車身還沒有 SQLID，MSW 之後才還原 modData
L.stored = 1700000000601
gmd.MVCKByVehicleSQLID[L.stored] = entry("gina", "Base.Van")
check(cmd(ADm, "adminMigration", { op = "IMPORT" }).imported == 1 and pend[L.stored] ~= nil and not O.hasOutOfWorld(),
    "匯入時車在拖車倉儲裡：留為待轉項（帳本沒有移出世界的紀錄）")
local unloaded = vehicle(8, 777, 8008, "Base.Van", 1, 1)
local before = #logLines
fire("OnSpawnVehicleEnd", unloaded)
unloaded:getModData().SQLID = L.stored -- MSW 生車之後才還原車身 modData
fire("OnTick")
local got, moved2 = O.R.bySqlId[777] and O.R.bySqlId[777][1], false
for i = before + 1, #logLines do if logLines[i]:find("REBOUND_MOVED", 1, true) then moved2 = true end end
check(pend[L.stored] == nil and got ~= nil and got.ownerUser == "gina" and moved2,
    "卸下後下一個 tick 自行轉正（規則 2），不必等有人碰車或 10 分鐘掃描")
end

do
out("情境 44：SteamID 身分——改名與分割畫面不能冒用；綁定只來自 OnNewGame、管理員匯入與確認改綁")
boot()
local SID = { alice = 76561198000000016, alice2 = 76561198000000080, bob = 76561198000000032,
    eve = 76561198000000048, admin = 76561198000000064 }
local function newGame(name, sid) -- CreatePlayerPacket 的暫時物件：名字＝登入名、SteamID＝連線，不在線上名單
    local p = { name = name, sid = sid }
    function p:getUsername() return self.name end
    function p:getPlayerNum() return 0 end
    function p:getSteamID() return self.sid + 0.0 end
    fire("OnNewGame", p)
end
local function bind(name) return O.state().identityBindings[name] end
local function audited(text) for _, l in ipairs(logLines) do if l:find(text, 1, true) then return true end end return false end
local A = player("alice", 1, 1, { sid = SID.alice })
local AD = player("admin", 1, 1, { admin = true, sid = SID.admin })
local GH = player("ghost", 1, 1, { sid = SID.eve })
local v, gv = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1), vehicle(2, 102, 5002, "Base.CarNormal", 1, 1)
local c = claim(A, v)
check(O.principal(A) == "alice" and c.ok and claim(GH, gv).ok, "no-steam：帳號名即身分")
newGame("alice", SID.alice)
check(bind("alice") == nil, "no-steam：OnNewGame 不綁定（沒有驗證因子）")
steamActive = true
check(O.principal(A) == "alice" and O.principal(GH) == "ghost", "Steam 模式、第一次匯入前：沒綁定的名字照舊，既有玩家不失去身分")
newGame("alice", SID.alice)
check(bind("alice") ~= nil and bind("alice").sid == SID.alice and bind("alice").src == "NEWGAME", "OnNewGame 以登入名與連線 SteamID 綁定")
newGame("alice", SID.eve)
check(bind("alice").sid == SID.alice and audited("BIND_CONFLICT"), "已綁定的名字換 SteamID 再進場：不改綁，記 BIND_CONFLICT")
local spoof = player("alice", 1, 1, { sid = SID.eve }) -- 重生後改名成 alice，SteamID 仍是自己的
check(O.principal(spoof) == nil and not O.canUse(spoof, v, "DRIVE"), "改名成 alice、SteamID 不符：沒有身分，不能開 alice 的車")
check(O.principal(A) == "alice" and O.canUse(A, v, "DRIVE") and S.online().alice == A, "本尊照常；在線名單只有本尊，推播不會送給冒名者")
local real = O.principal
O.principal = function(p) if p:getPlayerNum() ~= 0 then return nil end return p:getUsername() end
check(O.canUse(spoof, v, "DRIVE") == true, "（預期）植入只看名字的舊判定讓冒名者通過——證明斷言能分辨")
O.principal = real
local epoch = rec(c.oid).epoch
local deny = cmd(spoof, "unclaim", { vehicleId = v.id, expectedOid = c.oid, expectedEpoch = epoch })
check(deny ~= nil and deny.reason == "IDENTITY_UNVERIFIED" and deny.to == "alice" and rec(c.oid).recordState == "ACTIVE",
    "冒名者的命令被拒並收到「身分未確認」，車照舊")
check(cmd(spoof, "unclaim", { vehicleId = v.id, expectedOid = c.oid, expectedEpoch = epoch }) == nil, "一分鐘內不重複通知")
local coop = player("carl", 1, 1, { sid = SID.alice })
coop.num = 1
check(O.principal(coop) == nil and cmd(coop, "prepareClaim", { vehicleId = 2 }) == nil, "分割畫面玩家（序號 1）沒有身分，也不回")

rec(c.oid).grants = { { user = "friend", bits = 1 } }
O.mapSet("pendingRebindByLegacyKey", 1700000000999, { legacyVehicleId = 1700000000999, ownerUser = "mvckOld", vehicleScript = "Base.Van" })
local rows = { { u = "alice", s = "76561198000000016" }, { u = "bob", s = "76561198000000030" },
    { u = "dan", s = "76561198000000031" }, { u = "carol", s = "" }, { u = "admin", s = "76561198000000064" } }
check(cmd(A, "adminIdentity", { op = "IMPORT", rows = rows }).reason == "NOT_ADMIN", "一般玩家不能匯入")
check(cmd(AD, "adminIdentity", { op = "IMPORT", rows = { { u = "bob", s = "7.6561198E16" } } }).reason == "BAD_ARGS"
    and cmd(AD, "adminIdentity", { op = "IMPORT", rows = { { u = "bob", s = " 76561198000000030" } } }).reason == "BAD_ARGS",
    "SteamID 不是 17 位數字字串就拒收（tonumber 會吃科學記號與空白）")
local im = cmd(AD, "adminIdentity", { op = "IMPORT", rows = rows })
check(im.ok and im.bound == 3 and im.same == 1 and im.missing == 1 and im.conflicts == 0 and im.collisions == 2,
    "匯入：新綁 3、相同 1、沒有 SteamID 1；bob 與 dan 精確值不同卻捨入成同一個數，列為碰撞")
check(bind("bob").sid == SID.bob and O.principal(player("bob", 1, 1, { sid = 76561198000000030 })) == "bob",
    "精確字串 tonumber 後等於連線 SteamID 進 Lua 的值（同樣捨入到 16 的倍數）")
check(im.reserved == 3 and bind("ghost").reserved and bind("friend").reserved and bind("mvckOld").reserved,
    "帳本有車、有分享或 MVCK 待轉，卻不在 whitelist 的名字鎖定")
check(O.principal(GH) == nil and O.principal(player("carol", 1, 1, { sid = SID.eve })) == nil
    and O.principal(player("zed", 1, 1, { sid = SID.eve })) == nil, "匯入後：鎖定、沒有 SteamID、從沒出現過的名字都沒有身分")
newGame("ghost", SID.eve)
check(bind("ghost").reserved and bind("ghost").sid == nil, "鎖定的名字不會被 OnNewGame 綁走（同名新帳號拿不到舊車）")
newGame("zed", SID.eve)
check(bind("zed") ~= nil and bind("zed").sid == SID.eve and O.principal(player("zed", 1, 1, { sid = SID.eve })) == "zed",
    "匯入後的新帳號由 OnNewGame 綁定，立刻有身分")

local im2 = cmd(AD, "adminIdentity", { op = "IMPORT", rows = { { u = "alice", s = "76561198000000080" }, { u = "ghost", s = "76561198000000048" },
    { u = "admin", s = "76561198000000064" } } })
check(im2.ok and im2.conflicts == 2 and bind("alice").sid == SID.alice and bind("ghost").reserved,
    "whitelist 的 SteamID 變了、或鎖定的名字出現在 whitelist：列為衝突，確認前不改")
cmd(AD, "adminList", {}, false)
local meta = lastOf(AD, "adminSnapshot")
check(meta.identitySteam == true and meta.identityImported == true and #meta.identityConflicts == 2, "管理頁總表帶身分狀態與衝突名單")
local A2 = player("alice", 1, 1, { sid = SID.alice2 })
check(O.principal(A2) == nil, "換了 Steam 帳號的 alice 在確認前沒有身分")
local rb = cmd(AD, "adminIdentity", { op = "REBIND" })
check(rb.ok and rb.rebound == 2 and O.principal(A2) == "alice" and O.principal(A) == nil and bind("ghost").sid == SID.eve,
    "確認改綁：新 Steam 帳號取得 alice、舊的失去；鎖定的名字解除並綁定")
check(cmd(AD, "adminIdentity", { op = "REBIND" }).reason == "IMPORT_FIRST", "沒有待確認的匯入結果時不能改綁")

nowMs = nowMs + 61000
local AD2 = player("admin", 1, 1, { admin = true, sid = SID.alice2 }) -- 管理員換 Steam 帳號登入
cmd(AD2, "adminList", {}, false)
local snap = lastOf(AD2, "adminSnapshot")
check(O.principal(AD2) == nil and snap.ok and snap.to == "admin", "身分不符的管理員仍可看總表（角色來自連線、不看名字）")
check(cmd(AD2, "adminIdentity", { op = "IMPORT", rows = { { u = "admin", s = "76561198000000080" } } }).ok
    and cmd(AD2, "adminIdentity", { op = "REBIND" }).ok and O.principal(AD2) == "admin", "也能匯入並確認改綁，修好自己")
local notice = cmd(spoof, "adminIdentity", { op = "REBIND" })
check(notice and notice.reason == "IDENTITY_UNVERIFIED", "沒通過驗證的一般玩家送管理命令：只收到身分未確認")
steamActive = false
check(cmd(AD2, "adminIdentity", { op = "REBIND" }).reason == "NOT_STEAM", "no-steam 伺服器不收身分匯入")
steamActive = true

GOS.save()
boot(deepcopy(O.R.meta), true, true)
steamActive = true
check(O.principal(player("alice", 1, 1, { sid = SID.alice2 })) == "alice" and O.principal(player("alice", 1, 1, { sid = SID.alice })) == nil
    and O.state().identityImportedAtMs ~= nil, "綁定與「已匯入」存檔後重啟仍在")
local AD3 = player("admin", 1, 1, { admin = true, sid = SID.alice2 })
gmd.MVCKByVehicleSQLID = { [1700000000777] = { OwnerPlayerID = "mvckNew", CarModel = "Base.Van", ClaimDateTime = 1700000000 } }
local mi = cmd(AD3, "adminMigration", { op = "IMPORT" })
check(mi.ok and mi.imported == 1 and bind("mvckNew") ~= nil and bind("mvckNew").reserved, "身分匯入後才匯入 MVCK：沒綁定的車主名稱鎖定")
end

out("情境 13c：管理員總表分段（引擎送出緩衝區 1 MB）")
do
    -- TableNetworkUtils 格式：型別 1 byte；字串 2 byte 長度＋UTF-8；數字 8 byte；布林 1 byte；table 4 byte 筆數＋鍵值
    local function sz(v)
        local t = type(v)
        if t == "string" then return 1 + 2 + #v end
        if t == "number" then return 1 + 8 end
        if t == "boolean" then return 1 + 1 end
        if t == "table" then
            local n = 1 + 4
            for k, x in pairs(v) do n = n + sz(k) + sz(x) end
            return n
        end
        return 0
    end
    boot()
    local ADMC = player("admin", 1, 1, { admin = true })
    -- 最壞情況：5000 位 50 字元帳號各一台車，車名 64 bytes、車型 100 字元、隔離原因、四個時間座標欄位都有值
    local users = {}
    for i = 1, 5000 do
        local u = string.format("%s%05d", string.rep("u", 45), i)
        users[i] = u
        local p = player(u, 1, 1)
        local a = claim(p, vehicle(i, 100000 + i, 500000 + i, "Base." .. string.rep("V", 95), 1, 1))
        local r = rec(a.oid)
        r.customName, r.quarantineReason = string.rep("n", 64), string.rep("R", 32)
        r.lastKnownX, r.lastKnownY, r.lastKnownAtMs, r.releaseDueAtMs = 12345.678, 9876.543, nowMs, nowMs + 86400000
        online[#online] = nil
    end
    local function parts(p)
        local box, last = outbox[p.name], nil
        for i = #box, 1, -1 do if box[i].command == "adminSnapshot" then last = box[i].payload.id; break end end
        local list = {}
        for _, m in ipairs(box) do if m.command == "adminSnapshot" and m.payload.id == last then list[#list + 1] = m.payload end end
        return list
    end
    local function sameList(a, b, key)
        if a == nil or b == nil or #a ~= #b then return false end
        local idx = {}
        for _, x in ipairs(b) do idx[x[key]] = x end
        for _, x in ipairs(a) do
            local y = idx[x[key]]
            if y == nil then return false end
            for k, v in pairs(x) do if type(v) ~= "table" and y[k] ~= v then return false end end
            for k, v in pairs(y) do if type(v) ~= "table" and x[k] ~= v then return false end end
        end
        return true
    end
    local function deliver(list, order)
        for _, i in ipairs(order) do MVM.clientReceive("adminSnapshot", list[i]) end
    end
    local function range(a, b) local o = {}; for i = a, b do o[#o + 1] = i end; return o end
    -- 不分段的同一份資料作為比對基準
    local per0 = S.ADMIN_PART_ITEMS
    S.ADMIN_PART_ITEMS = 1e9
    cmd(ADMC, "adminList", {}, false)
    local whole = parts(ADMC)[1]
    S.ADMIN_PART_ITEMS = per0
    cmd(ADMC, "adminList", {}, false)
    local ps = parts(ADMC)
    local maxSize, shape = 0, #ps >= 3
    for i, pt in ipairs(ps) do
        maxSize = math.max(maxSize, sz(pt))
        if pt.part ~= i or pt.parts ~= #ps then shape = false end
    end
    out(string.format("  info  5000 位＋5000 筆：%d 段，最大一段 %d bytes（不分段 %d bytes）", #ps, maxSize, sz(whole)))
    check(shape and maxSize < 200 * 1024 and sz(whole) > 1000000, "最壞情況（不分段會超過 1 MB）：每段依序編號，序列化後都小於 200 KB")
    check(ps[1].ok == true and ps[1].defaultQuota == 3 and ps[2].ok == nil and ps[2].defaultQuota == nil, "meta 只放在第 1 段")
    local CB = MVM.Client.buckets
    CB.admin = nil
    deliver(ps, range(1, #ps))
    local b = CB.admin
    check(sameList(b.admin, whole.rows, "oid") and sameList(b.adminPlayers, whole.players, "user") and #b.adminPlayers == 5000
        and b.adminDefaultQuota == 3 and b.adminPending == nil, "client 收齊後重組的列與玩家和不分段時完全相同")
    cmd(ADMC, "adminList", {}, false)
    local rev = parts(ADMC)
    CB.admin = nil
    local order = {}
    for i = #rev, 1, -1 do order[#order + 1] = i end
    deliver(rev, order)
    check(CB.admin ~= nil and sameList(CB.admin.admin, whole.rows, "oid") and sameList(CB.admin.adminPlayers, whole.players, "user"),
        "段到達順序不同也依段號重組成同一份資料")
    -- 缺段：其他段都到了也不套用
    b = CB.admin
    local before = b.adminPlayers
    cmd(ADMC, "adminList", {}, false)
    local miss = parts(ADMC)
    local most = range(1, #miss)
    table.remove(most, 2)
    deliver(miss, most)
    check(b.adminPlayers == before and b.adminPending ~= nil, "缺一段：不套用半套資料，保留上一份完整總表")
    -- 新 id 丟掉舊的未完成段：A 前半＋B 後半不能湊成一份；B 補齊前半才套用 B
    cmd(ADMC, "adminList", {}, false)
    local A = parts(ADMC)
    O.mapSet("quotaOverrides", users[1], 9)
    cmd(ADMC, "adminList", {}, false)
    local B = parts(ADMC)
    local k = math.floor(#A / 2)
    deliver(A, range(1, k))
    deliver(B, range(k + 1, #B))
    local mixed = b.adminPlayers ~= before
    deliver(B, range(1, k))
    local custom = false
    for _, pl in ipairs(b.adminPlayers) do if pl.user == users[1] then custom = pl.custom == true and pl.base == 9 end end
    check(#A == #B and not mixed and custom and #b.adminPlayers == 5000, "收到新 id 就丟掉舊的未完成段，只套用收齊的新總表")
    O.mapSet("quotaOverrides", users[1], nil)
    CB.admin = nil
end

out("植入違規自檢：授權若讀車身 modData 會被情境 8 抓到")
do
    local realCanUse = O.canUse
    O.canUse = function(actor, v, action)
        if v.bodyMd and v.bodyMd.MinidoracatVehicleManager then return true, "BODY" end
        return realCanUse(actor, v, action)
    end
    boot()
    A, B = player("alice", 0, 0), player("bob", 1, 1)
    car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
    claim(A, car)
    car.bodyMd = { MinidoracatVehicleManager = { oid = "x" } }
    check(O.canUse(B, car, "DRIVE") == true, "（預期）植入的錯誤實作讓 bob 通過——證明斷言能分辨")
    O.canUse = realCanUse
    check(O.canUse(B, car, "DRIVE") == false, "還原後 bob 被拒")
end

-- ===== Phase 2：動作防護 =====
MDAD = { FAIL_GENERIC = "UI_FAIL", applied = 0 }
function MDAD.getDevicePart(v, kind) return v:getPartById(kind == "nav" and "MDADGPS" or "MDADAutopilot") end
function MDAD.applyDeviceChange(player, vehicle, kind, install) MDAD.applied = MDAD.applied + 1; return true end
fire("OnServerStarted")

local function A(cls, fields) fields.Type = cls; return fields end
local function stage(a, st) return _G[a.Type][st](a) end
local function intent(p, cls, v, partId)
    cmd(p, "prepareAction", { class = cls, vehicleId = v.id, partId = partId }, false)
end
local function calls(key) return vanillaCalls[key] or 0 end
local function lastEnforcement(p) return lastOf(p, "enforcement") end

out("情境 P2-1：未綁定車照原版走，不要求 intent")
boot()
local OW, ST = player("owner", 1, 1), player("stranger", 1, 1)
local car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1, { "Engine", "Battery", "DoorFrontLeft", "EngineDoor", "TrunkDoor", "TireFrontLeft", "GasTank", "MDADGPS" })
local a = A("ISUninstallVehiclePart", { character = ST, part = car.parts.Battery, vehicle = car })
check(stage(a, "complete") == true and calls("ISUninstallVehiclePart.complete") == 1, "未綁定車：陌生人拆零件照原版")

out("情境 P2-2：受保護車——owner 需 intent；陌生人拒絕並推回")
local claimAck = claim(OW, car)
check(claimAck and claimAck.ok, "owner 綁定")
intent(OW, "ISUninstallVehiclePart", car, "Battery")
a = A("ISUninstallVehiclePart", { character = OW, part = car.parts.Battery, vehicle = car })
check(stage(a, "complete") == true and calls("ISUninstallVehiclePart.complete") == 2, "owner 有 intent → 放行")
a = A("ISUninstallVehiclePart", { character = OW, part = car.parts.Battery, vehicle = car })
check(stage(a, "complete") == false and calls("ISUninstallVehiclePart.complete") == 2, "intent 已消費：再來一次（冒充）被拒")
check(logLines[#logLines]:find("ACTOR_MISMATCH", 1, true) ~= nil, "冒充寫 ACTOR_MISMATCH audit")
local txBefore = (tx.item or 0)
a = A("ISUninstallVehiclePart", { character = ST, part = car.parts.Battery, vehicle = car })
check(stage(a, "complete") == false and calls("ISUninstallVehiclePart.complete") == 2, "陌生人拆零件：原版 complete 未執行")
check((tx.item or 0) == txBefore + 1 and (tx.condition or 0) >= 1, "拒絕後推回零件與耐久")
local enf = lastEnforcement(ST)
check(enf and enf.reason == "NOT_AUTHORIZED" and enf.to == "stranger", "拒絕原因只送給動作者")
-- intent 綁 class／車／零件：別的零件或別台車不能挪用
intent(OW, "ISUninstallVehiclePart", car, "Engine")
a = A("ISUninstallVehiclePart", { character = OW, part = car.parts.Battery, vehicle = car })
check(stage(a, "complete") == false, "intent 的 partId 不符 → 拒")

out("情境 P2-3：REPAIR／SALVAGE 互不隱含")
local RP = player("repairer", 1, 1)
local r = rec(claimAck.oid)
cmd(OW, "addMember", { expectedOid = r.oid, username = "repairer", actionBits = MVM.ACTIONS.REPAIR })
intent(RP, "ISInstallVehiclePart", car, "Battery")
check(stage(A("ISInstallVehiclePart", { character = RP, part = car.parts.Battery, vehicle = car }), "complete") == true, "REPAIR 可安裝")
intent(RP, "ISUninstallVehiclePart", car, "Battery")
check(stage(A("ISUninstallVehiclePart", { character = RP, part = car.parts.Battery, vehicle = car }), "complete") == false, "REPAIR 不能拆")
intent(RP, "ISDeflateTire", car, "TireFrontLeft")
check(stage(A("ISDeflateTire", { character = RP, part = car.parts.TireFrontLeft, vehicle = car }), "complete") == false, "REPAIR 不能放氣")
intent(RP, "ISInflateTire", car, "TireFrontLeft")
check(stage(A("ISInflateTire", { character = RP, part = car.parts.TireFrontLeft, vehicle = car }), "complete") == true, "REPAIR 可打氣")
intent(RP, "ISOpenVehicleDoor", car, "EngineDoor")
check(stage(A("ISOpenVehicleDoor", { character = RP, part = car.parts.EngineDoor, vehicle = car }), "complete") == true, "REPAIR 可開引擎蓋")
intent(RP, "ISOpenVehicleDoor", car, "DoorFrontLeft")
check(stage(A("ISOpenVehicleDoor", { character = RP, part = car.parts.DoorFrontLeft, vehicle = car }), "complete") == false, "REPAIR 不能開車門")
cmd(OW, "addMember", { expectedOid = r.oid, username = "repairer", actionBits = MVM.ACTIONS.REPAIR + MVM.ACTIONS.CARGO })
intent(RP, "ISOpenVehicleDoor", car, "TrunkDoor")
check(stage(A("ISOpenVehicleDoor", { character = RP, part = car.parts.TrunkDoor, vehicle = car }), "complete") == true, "CARGO 可開後車廂")

out("情境 P2-4：加油／抽油四個 lifecycle 全擋")
local can = { synced = 0 }
function can:syncItemFields() self.synced = self.synced + 1 end
a = A("ISTakeGasolineFromVehicle", { character = ST, part = car.parts.GasTank, vehicle = car, item = can })
stage(a, "serverStart"); stage(a, "update"); local cres = stage(a, "complete"); stage(a, "serverStop")
check(calls("ISTakeGasolineFromVehicle.serverStart") == 0 and calls("ISTakeGasolineFromVehicle.update") == 0
    and calls("ISTakeGasolineFromVehicle.serverStop") == 0 and cres == false, "抽油：serverStart／update／complete／serverStop 都沒呼叫原版")
check(can.synced >= 1 and (tx.moddata or 0) >= 1, "抽油拒絕後推回油箱與油桶")
local enfCount = 0
for _, m in ipairs(outbox.stranger) do if m.command == "enforcement" then enfCount = enfCount + 1 end end
a = A("ISAddGasolineToVehicle", { character = ST, part = car.parts.GasTank, vehicle = car, item = can })
stage(a, "serverStart"); stage(a, "update"); stage(a, "complete"); stage(a, "serverStop")
local enfCount2 = 0
for _, m in ipairs(outbox.stranger) do if m.command == "enforcement" then enfCount2 = enfCount2 + 1 end end
check(enfCount2 == enfCount + 1, "同一動作四個 stage 只通知一次")

out("情境 P2-5：目標不一致與砸窗解析")
local other = vehicle(2, 202, 5002, "Base.CarNormal", 1, 1)
intent(OW, "ISUninstallVehiclePart", car, "Battery")
a = A("ISUninstallVehiclePart", { character = OW, part = car.parts.Battery, vehicle = other })
check(stage(a, "complete") == false and a._mvmReason == "TARGET_MISMATCH", "action.vehicle 與零件所屬車不同 → 拒")
local win = { _cls = "VehicleWindow", part = car.parts.DoorFrontLeft }
function win:getPart() return self.part end
a = A("ISSmashWindow", { character = ST, window = win, vehiclePart = other.parts.Engine })
check(stage(a, "complete") == false and calls("ISSmashWindow.complete") == 0, "砸窗以 window 所屬車判定，不信 vehiclePart")
a = A("ISSmashWindow", { character = ST, window = { _cls = "IsoWindow" } })
check(stage(a, "complete") == true, "建築窗戶不經本 MOD")
a = A("ISSmashVehicleWindow", { character = ST, part = car.parts.DoorFrontLeft, vehicle = car })
check(stage(a, "complete") == false and calls("ISSmashVehicleWindow.complete") == 0, "ISSmashVehicleWindow（原版無呼叫點）也要權限")
intent(OW, "ISSmashVehicleWindow", car, "DoorFrontLeft")
a = A("ISSmashVehicleWindow", { character = OW, part = car.parts.DoorFrontLeft, vehicle = car })
check(stage(a, "complete") == true and calls("ISSmashVehicleWindow.complete") == 1, "車主有 intent 時照原版砸自己的車窗")
do -- 分割畫面第 2～4 位玩家的名稱由客戶端自由填：與車主同名也不是車主
    local coop = { num = 1 }
    function coop:getUsername() return "owner" end
    function coop:getPlayerNum() return self.num end
    check(O.principal(coop) == nil and O.canUse(coop, car, "DRIVE") == false, "分割畫面玩家沒有身分：與車主同名也不能駕駛")
    coop.num = 0
    check(O.principal(coop) == "owner" and O.canUse(coop, car, "DRIVE") == true, "同名的主玩家（序號 0）才是車主")
end

out("情境 P2-6：虛擬鑰匙三個 adapter")
car.seats[0] = OW; OW.vehicle = car
intent(OW, "ISStartVehicleEngine", car)
local sa = A("ISStartVehicleEngine", { character = OW })
check(stage(sa, "complete") == true and car.started == true and calls("ISStartVehicleEngine.complete") == 0, "owner 無鑰匙：tryStartEngine(true)")
SB.VirtualKey = false
car.started = nil
intent(OW, "ISStartVehicleEngine", car)
stage(A("ISStartVehicleEngine", { character = OW }), "complete")
check(car.started == false and calls("ISStartVehicleEngine.complete") == 1, "VirtualKey 關閉 → 原版鑰匙規則")
SB.VirtualKey = true
car.seats[0] = nil; OW.vehicle = nil
car.parts.DoorFrontLeft.door.locked = true
intent(OW, "ISUnlockVehicleDoor", car, "DoorFrontLeft")
local doorTx = tx.door or 0
check(stage(A("ISUnlockVehicleDoor", { character = OW, part = car.parts.DoorFrontLeft, vehicle = car }), "complete") == true
    and car.parts.DoorFrontLeft.door.locked == false and (tx.door or 0) == doorTx + 1, "owner 權威解鎖並 transmitPartDoor")
intent(OW, "ISOpenVehicleDoor", car, "DoorFrontLeft")
stage(A("ISOpenVehicleDoor", { character = OW, part = car.parts.DoorFrontLeft, vehicle = car }), "complete")
check(car.previouslyEntered == true, "owner 開門前 setPreviouslyEntered(true)（不觸發警報）")
car.previouslyEntered = nil
intent(ST, "ISOpenVehicleDoor", car, "DoorFrontLeft")
stage(A("ISOpenVehicleDoor", { character = ST, part = car.parts.DoorFrontLeft, vehicle = car }), "complete")
check(car.previouslyEntered == nil, "陌生人開門被拒，不動警報狀態")

out("情境 P2-7：包裝冪等與被覆寫後重包")
local before = calls("ISInstallVehiclePart.complete")
G.install("again")
intent(OW, "ISInstallVehiclePart", car, "Battery")
stage(A("ISInstallVehiclePart", { character = OW, part = car.parts.Battery, vehicle = car }), "complete")
check(calls("ISInstallVehiclePart.complete") == before + 1, "重跑 install 不會重複包裝")
local ours = ISInstallVehiclePart.complete
ISInstallVehiclePart.complete = function(self) return ours(self) end -- 後載 MOD 覆寫且呼叫下游
local nrew = G.R.rewraps
G.install("recheck")
check(G.R.rewraps == nrew + 1 and logLines[#logLines]:find("ADAPTER_REWRAPPED", 1, true) ~= nil, "被覆寫 → 重包並 audit")
intent(OW, "ISInstallVehiclePart", car, "Battery")
check(stage(A("ISInstallVehiclePart", { character = OW, part = car.parts.Battery, vehicle = car }), "complete") == true,
    "雙層包裝下 intent 只消費一次，owner 仍放行")
check(stage(A("ISInstallVehiclePart", { character = ST, part = car.parts.Battery, vehicle = car }), "complete") == false,
    "雙層包裝下陌生人仍被拒")

out("情境 P2-8：AutoDrive 裝置槽")
local applied = MDAD.applied
local ok1 = MDAD.applyDeviceChange(ST, car, "nav", true, 1)
check(ok1 == false and MDAD.applied == applied, "陌生人裝 GPS → 拒，AutoDrive 未執行")
check(MDAD.applyDeviceChange(RP, car, "nav", true, 1) == true, "REPAIR grantee 可裝")
check(MDAD.applyDeviceChange(RP, car, "nav", false) == false, "REPAIR grantee 不能卸（需 SALVAGE）")
check(MDAD.applyDeviceChange(ST, other, "nav", true, 1) == true, "未綁定車照 AutoDrive 原行為")

out("情境 P2-9：prepareAction 驗證")
local nIntent = #(G.R.intents.stranger or {})
cmd(ST, "prepareAction", { class = "IS Bad;Class", vehicleId = 1 }, false)
check(#(G.R.intents.stranger or {}) == nIntent, "非法 class 名稱不記 intent")
cmd(ST, "prepareAction", { class = "ISOpenVehicleDoor", vehicleId = 1, partId = "DoorFrontLeft", owner = "x" }, false)
check(#(G.R.intents.stranger or {}) == nIntent, "夾帶未知欄位不記 intent")
for i = 1, 20 do G.onIntent(ST, "stranger", { class = "ISOpenVehicleDoor", vehicleId = 1 }) end
check(#G.R.intents.stranger == 16, "每人 intent 有上限")
check(lastOf(ST, "mutationAck") == nil or lastOf(ST, "mutationAck").requestKind ~= "prepareAction", "prepareAction 不回 ACK")

out("情境 P2-10：watchdog 佔座與拖掛")
boot()
OW, ST = player("owner", 1, 1), player("stranger", 1, 1)
local ADM = player("admin", 1, 1, { admin = true })
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
claim(OW, car)
car.seats[1] = ST; ST.vehicle = car
G.watchdog()
check(lastEnforcement(ST) and lastEnforcement(ST).action == "OCCUPANCY" and ST.vehicle == car, "action 1：只通知不移出")
nowMs = nowMs + 500
G.watchdog()
local n1 = 0
for _, m in ipairs(outbox.stranger) do if m.command == "enforcement" then n1 = n1 + 1 end end
check(n1 == 1, "未到 WatchdogIntervalSeconds 不重查")
SB.WatchdogAction = 2
nowMs = nowMs + 1000
G.watchdog()
check(ST.vehicle == nil and ST.lastChange == "EXIT_VEHICLE", "action 2：先 EXIT_VEHICLE 再 server exit")
SB.WatchdogAction = 1
cmd(ADM, "setAdminOverride", { enabled = true })
car.seats[0] = ADM; ADM.vehicle = car
local logs = #logLines
nowMs = nowMs + 1000; G.watchdog(); nowMs = nowMs + 1000; G.watchdog()
local bypass = 0
for i = logs + 1, #logLines do if logLines[i]:find("ADMIN_BYPASS", 1, true) then bypass = bypass + 1 end end
check(bypass == 0 and lastEnforcement(ADM) == nil, "越權中的 admin 在車上：watchdog 不執法、也不洗 ADMIN_BYPASS")
car.seats[0] = nil; ADM.vehicle = nil
local tower = vehicle(2, 202, 5002, "Base.CarNormal", 1, 1)
tower.seats[0] = ST; ST.vehicle = tower; tower.towing = car
nowMs = nowMs + 1000; G.watchdog()
check(tower.broken == 1, "陌生人拖走受保護車 → breakConstraint")
local ownTow = vehicle(3, 303, 5003, "Base.CarNormal", 1, 1)
ownTow.seats[0] = OW; OW.vehicle = ownTow; ownTow.towing = car
nowMs = nowMs + 1000; G.watchdog()
check(ownTow.broken == nil, "owner 拖自己的車不解除")
-- coverage：64 人、每 tick 最多 10 人，一個週期內全數檢查
boot()
for i = 1, 64 do player("p" .. i, 1, 1) end
local t1 = nowMs + 100
for _ = 1, 7 do nowMs = nowMs + 100; G.watchdog() end
local cnt = 0
for _, due in pairs(G.R.due) do if due > t1 then cnt = cnt + 1 end end
check(cnt == 64, "64 位在線玩家、每 tick 10 人：7 tick 內全數檢查過")

out("情境 P2-11：燒毀車拆解入口不能拆受保護車")
boot()
OW, ST = player("owner", 1, 1), player("stranger", 1, 1)
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
local bAck = claim(OW, car)
local bres = ISRemoveBurntVehicle.complete(A("ISRemoveBurntVehicle", { character = ST, vehicle = car }))
check(bres == false and not car.removed and rec(bAck.oid).recordState == "ACTIVE", "陌生人對受保護的好車用燒毀拆解 → 拒，車與紀錄不變")
intent(OW, "ISRemoveBurntVehicle", car)
ISRemoveBurntVehicle.complete(A("ISRemoveBurntVehicle", { character = OW, vehicle = car }))
check(car.removed and rec(bAck.oid).recordState == "DESTROYED", "車主自己拆 → 照原版移除並 DESTROYED")

out("情境 P2-12：動作進行中撤權，後續 stage 停止")
boot()
OW = player("owner", 1, 1)
local FU2 = player("fueler", 1, 1)
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1, { "Engine", "Battery", "GasTank" })
local fAck = claim(OW, car)
cmd(OW, "addMember", { expectedOid = fAck.oid, username = "fueler", actionBits = MVM.ACTIONS.FUEL })
intent(FU2, "ISTakeGasolineFromVehicle", car, "GasTank")
local fcan = { syncItemFields = function() end }
local fa = A("ISTakeGasolineFromVehicle", { character = FU2, part = car.parts.GasTank, vehicle = car, item = fcan })
local u0 = calls("ISTakeGasolineFromVehicle.update")
stage(fa, "serverStart"); stage(fa, "update")
check(calls("ISTakeGasolineFromVehicle.update") == u0 + 1, "有 FUEL 的成員：抽油照常進行")
cmd(OW, "removeMember", { expectedOid = fAck.oid, username = "fueler" })
stage(fa, "update"); local fres = stage(fa, "complete")
check(calls("ISTakeGasolineFromVehicle.update") == u0 + 1 and fres == false, "中途撤權：後續 update／complete 不再呼叫原版")

out("情境 P2-13：RECOVERY_REQUIRED 期間 watchdog 仍依記憶體帳本執法")
boot()
OW = player("owner", 1, 1)
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
claim(OW, car)
local rdisk, rgmd = GOS.snapshot(), deepcopy(gmd)
rdisk.ledgerRevision = rdisk.ledgerRevision - 3
boot(rdisk, true); gmd = rgmd
ST = player("stranger", 1, 1)
car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
car.seats[1] = ST; ST.vehicle = car
SB.WatchdogAction = 2
nowMs = nowMs + 1000; G.watchdog()
check(O.R.status == "RECOVERY_REQUIRED" and ST.vehicle == nil, "RECOVERY_REQUIRED：陌生人佔座仍被移出")
SB.WatchdogAction = 1

(function() -- 主 chunk 區域變數已滿 200：本情境用自己的函式作用域
out("情境 P6：位置日誌（崩潰沒存檔也能補回座標）與 vehicles.json 匯出")
local P = { X = MVM.Export, TK2 = MVM.Tracking }
for k in pairs(files) do files[k] = nil end
boot()
P.X.journalApplied, P.X.exportedRevision, P.X.lastExportMs = false, nil, 0
P.OW6 = player("owner", 1, 1)
P.car6 = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
P.ack6 = claim(P.OW6, P.car6)
P.saved = GOS.snapshot()          -- 上次世界存檔（車還在 1,1）
P.gmd6 = deepcopy(gmd)
P.car6.seats[0] = P.OW6; P.OW6.vehicle = P.car6
nowMs = nowMs + 600; P.TK2.tick()
P.car6.x, P.car6.y = 50, 60               -- 開走後下車：引擎此時把座標寫進 vehicles.db
P.car6.seats[0] = nil; P.OW6.vehicle = nil
nowMs = nowMs + 600; P.TK2.tick()
P.jpath = P.X.folder() .. "positions.txt"
check(rec(P.ack6.oid).lastKnownX == 50 and files[P.jpath] ~= nil and table.concat(files[P.jpath]):find(P.ack6.oid, 1, true) ~= nil,
    "下車：帳本最後位置更新，同時追加一行位置日誌")
-- 伺服器崩潰：帳本回到上次存檔，Lua 目錄的日誌還在
boot(P.saved, true); gmd = P.gmd6
P.X.journalApplied = false
check(rec(P.ack6.oid).lastKnownX ~= 50, "崩潰後帳本是舊座標（前提）")
player("owner", 1, 1)
P.X.tick()
check(rec(P.ack6.oid).lastKnownX == 50 and rec(P.ack6.oid).lastKnownY == 60, "重啟時從位置日誌補回崩潰前的最後座標")
P.lines = 0
for _ in table.concat(files[P.jpath]):gmatch("\n") do P.lines = P.lines + 1 end
check(P.lines == 2, "啟動後日誌壓縮成表頭＋每台車一行")
-- 在車上直接斷線
P.OW7 = player("owner", 1, 1)
P.car6.seats[0] = P.OW7; P.OW7.vehicle = P.car6
nowMs = nowMs + 600; P.TK2.tick()
P.car6.x, P.car6.y = 80, 90
for i = #online, 1, -1 do if online[i].name == "owner" then table.remove(online, i) end end -- 同名帳號全部離線
nowMs = nowMs + 600; P.TK2.tick()
check(rec(P.ack6.oid).lastKnownX == 80, "在車上直接斷線也收斂最後位置")
-- 別的世界的日誌不套用
files[P.jpath] = { "ledger\tuuid-other\n", P.ack6.oid .. "\t999\t999\t0\t" .. MVM.Migration.intStr(nowMs + 99999) .. "\n" }
P.X.journalApplied = false
P.X.tick()
check(rec(P.ack6.oid).lastKnownX == 80, "帳本 ID 不同的日誌不套用")
-- 匯出
rec(P.ack6.oid).customName = 'say "hi"\nnow'
O.bump(rec(P.ack6.oid))
nowMs = nowMs + 20000; P.X.tick()
P.doc = table.concat(files[P.X.folder() .. "vehicles.json"] or {})
check(P.doc:find('"owner": "owner"', 1, true) and P.doc:find('"model": "CarNormal"', 1, true)
    and P.doc:find('"name": "say \\"hi\\"\\nnow"', 1, true) and P.doc:find('"x": 80', 1, true), "vehicles.json：車主、原始車型、跳脫後的名稱與座標")
P.jsonBuf = files[P.X.folder() .. "vehicles.json"]
nowMs = nowMs + 20000; P.X.tick()
check(files[P.X.folder() .. "vehicles.json"] == P.jsonBuf, "帳本沒變就不重寫")
check(P.X.utc(0) == "1970-01-01 00:00:00 UTC" and P.X.utc(1790439302927) == "2026-09-26 16:15:02 UTC", "UTC 時間格式")
end)(); -- 分號：下一個情境也是 IIFE，避免被解析成連續呼叫

(function() -- 主 chunk 區域變數已滿 200：本情境用自己的函式作用域
out("情境 E1：Economy 付費名額（rev 2 權益 consumer 邊界）")
local E = MVM.Econ
local H = { ents = {}, calls = 0, productResult = { ok = true } }
-- 假 Economy server facade：只模擬 VM 用到的 source-bound 方法，權益快照由情境直接指定
local function fake(rev, caps)
    MinidoracatEconomy = { CURRENCIES = { survivor = { id = "survivor" }, cat = { id = "cat" } },
        v1 = { API_MAJOR = 1, API_REVISION = rev, CAPABILITIES = caps, registerSource = function(spec)
            H.calls, H.source = H.calls + 1, spec
            return { modId = spec.modId,
                registerProduct = function(p) H.product = p; return H.productResult end,
                getEntitlement = function(user, productId)
                    if H.throw then error("economy read failed") end
                    if H.fail then return { ok = false, error = H.fail } end
                    if productId ~= MVM.ECON_PRODUCT then return { ok = false, error = "unknown_product" } end
                    return { ok = true, entitlement = H.ents[user] or { usable = 0, permanent = 0, rental = 0 } }
                end,
                onEntitlementChanged = function(fn)
                    if H.subscribeThrow then error("subscription failed") end
                    H.changed = fn
                end }
        end } }
end
local RICH = { entitlements = true, subscriptions = true, rentals = true, setPlan = true }
boot()
SB.ClaimsPerPlayer = 1
fake(2, RICH)
serverMode = false
E.init()
check(E.status == "OFF" and H.calls == 0, "SP：不註冊 Economy 來源，維持免費核心")
serverMode = true
MinidoracatEconomy = nil
E.init()
check(E.status == "ABSENT" and E.src == nil, "沒裝 Economy：ABSENT，不報錯")
fake(1, { post = true })
E.init()
check(E.status == "UNSUPPORTED" and H.calls == 0, "舊版 rev 1（無 entitlements 能力）：不註冊")
fake(2, { entitlements = true, subscriptions = true })
E.init()
check(E.status == "UNSUPPORTED" and H.calls == 0, "rev 2 但仍是單一租約（無 rentals 能力）：不註冊")
fake(2, { entitlements = true, subscriptions = true, rentals = true })
E.init()
check(E.status == "UNSUPPORTED" and H.calls == 0, "舊版 Economy（沒有 setPlan 能力，方案仍歸 Economy）：不註冊")
fake(2, RICH)
H.productResult = { ok = false, error = "invalid_args" }
E.init()
check(E.status == "FAILED" and E.src == nil and O.quotaLimit("alice") == 1, "產品註冊被拒：FAILED，只剩免費基本上限")
H.productResult = { ok = true }
H.subscribeThrow = true
E.init()
check(E.status == "FAILED" and E.src == nil and O.quotaLimit("alice") == 1,
    "權益通知訂閱失敗：FAILED，不啟用付費名額")
H.subscribeThrow = nil
E.init()
check(E.status == "READY" and type(H.changed) == "function", "註冊成功才 READY，並訂閱權益變更")
local cur = {}
for _, id in ipairs(H.source.currencies) do cur[id] = true end
check(cur.survivor and cur.cat, "來源允許所有 Economy 幣別（服主可改用任一幣別計價）")
check(H.source.nameKey == "IGUI_MVM_SourceName", "registerSource 帶來源名稱翻譯鍵 nameKey（經濟管理台用翻譯顯示來源）")

-- 付款即生效、方案由 VM 經 setPlan 送：registerProduct 帶 instant，不帶沙盒對應
local P = H.product
check(P.instant == true and P.sandbox == nil, "registerProduct 帶 instant、不帶 sandbox")
check(P.defaults.permanentEnabled == false and P.defaults.rentalEnabled == false and P.defaults.revision == nil,
    "預設兩種販售都關閉（由服主開啟），defaults 不含 revision")

-- 上限＝基本＋usable
local AL = player("alice", 0, 0)
local ADM = player("admin", 0, 0, { admin = true })
local cars = {}
for i = 1, 4 do cars[i] = vehicle(i, 100 + i, 5000 + i, "Base.CarNormal", 1, 1) end
local a1 = claim(AL, cars[1])
check(a1.ok and cmd(AL, "prepareClaim", { vehicleId = 2 }).reason == "QUOTA_EXCEEDED", "沒有付費名額：基本 1 格用完")
check(E.validatePurchase("alice", MVM.ECON_PRODUCT, "permanent", 1, {}) == true, "名額用完仍可購買（買格就是為了提高上限）")
H.ents.alice = { usable = 2, permanent = 1, rental = 1, state = "active" }
local a2, a3 = claim(AL, cars[2]), claim(AL, cars[3])
check(a2.ok and a3.ok, "已確認永久＋租用：上限＝基本＋usable")
cmd(AL, "fleetSubscribe", {}, false)
local snap = lastOf(AL, "fleetSnapshot")
local q = snap.quota
check(q.base == 1 and q.paid == 2 and q.permanent == 1 and q.rental == 1 and q.total == 3 and q.used == 3
    and q.economy == "READY" and q.pending == nil and snap.quotaLimit == 3, "fleetSnapshot 名額分項：基本／永久／租用／總計／整合狀態（沒有待確認欄位）")
cmd(ADM, "adminSetQuota", { usernames = { "alice" }, amount = 0 })
check(O.quotaBase("alice") == 0 and O.quotaLimit("alice") == 2, "管理員個人上限取代基本（絕對值），付費名額照加")
cmd(ADM, "adminSetQuota", { usernames = { "alice" }, amount = -1 })

-- 權益變更推送：只重送該玩家的快照
local n = #outbox.alice
H.ents.alice = { usable = 3, permanent = 2, rental = 1, state = "active" }
H.changed("alice", MVM.ECON_PRODUCT, {})
check(#outbox.alice == n + 1 and lastOf(AL, "fleetSnapshot").quota.total == 4, "權益變更：重送該玩家快照，名額即時更新")
H.changed("alice", "other_product", {})
H.changed("bob", MVM.ECON_PRODUCT, {})
check(#outbox.alice == n + 1, "別的產品、沒訂閱的玩家都不推送")

-- 到期／退款／Economy 不可用：只擋新增，既有綁定與管理照常
H.ents.alice = { usable = 1, permanent = 1, rental = 0, state = "expired" }
check(cmd(AL, "prepareClaim", { vehicleId = 4 }).reason == "QUOTA_EXCEEDED", "租約到期後超額：拒絕新綁定")
check(records() == 3 and rec(a2.oid).recordState == "ACTIVE" and rec(a3.oid).recordState == "ACTIVE", "超額的既有綁定不解除")
H.throw = true
check(O.quotaLimit("alice") == 1 and E.summary("alice").economy == "UNAVAILABLE", "Economy 查詢出錯：付費 0、UNAVAILABLE，不當成功")
check(cmd(AL, "rename", { expectedOid = a3.oid, expectedEpoch = rec(a3.oid).epoch, name = "mine" }).ok, "Economy 不可用時既有車照常管理")
H.throw = nil
H.fail = "source_disabled"
check(O.quotaLimit("alice") == 1, "權益查詢被拒：付費 0")
H.fail = nil
local badOk = true
for _, bad in ipairs({ { usable = 1.5, permanent = 1 }, { usable = "2", permanent = 2 }, { permanent = 3, rental = 1 } }) do
    H.ents.alice = bad
    if O.quotaLimit("alice") ~= 1 or E.summary("alice").economy ~= "UNAVAILABLE" then badOk = false end
end
check(badOk, "usable 缺或不是非負整數：不猜 permanent＋rental，付費 0")

-- 購買前驗證：付費名額用不到時拒購
serverOpts.DropOffWhiteListAfterDeath = true
local okv, why = E.validatePurchase("alice", MVM.ECON_PRODUCT, "permanent", 1, {})
check(okv == false and why == "CONFIG_BLOCKED", "伺服器擋新綁定時拒絕購買")
serverOpts.DropOffWhiteListAfterDeath = nil
local rdisk, rgmd = GOS.snapshot(), deepcopy(gmd)
rdisk.ledgerRevision = rdisk.ledgerRevision - 3
boot(rdisk, true); gmd = rgmd
okv, why = E.validatePurchase("alice", MVM.ECON_PRODUCT, "rental", 1, {})
check(okv == false and why == "RECOVERY_REQUIRED", "帳本需復原時拒絕購買")

-- client：API 探測、可用性提示、名額視窗純邏輯（BU）與付費名額設定視窗純邏輯（PS）
do
isClient = function() return true end
assert(loadfile(MEDIA .. "/client/ISUI/MinidoracatVehicleManager_BillingWindow.lua"))()
isClient = function() return false end
local BU = MVM.BillingUI
MinidoracatEconomy = { v1 = { Client = { API_MAJOR = 1, API_REVISION = 1, CAPABILITIES = { wallet = true } } } }
check(BU.api() == nil, "client：舊版 Economy（rev 1）視為不支援")
local ENT = {}
MinidoracatEconomy.v1.Client = { API_MAJOR = 1, API_REVISION = 2, CAPABILITIES = { entitlements = true }, Entitlements = ENT }
check(BU.api() == nil, "client：rev 2 但仍是單一租約（無 rentals 能力）視為不支援")
MinidoracatEconomy.v1.Client.CAPABILITIES.rentals = true
check(BU.api() == ENT, "client：rev 2＋entitlements＋rentals 能力才使用權益 API")
check(BU.blocker(nil, true, {}) == "IGUI_MVM_Loading" and BU.blocker({ economy = "OFF" }, true, {}) == "IGUI_MVM_Slots_SP"
    and BU.blocker({ economy = "UNAVAILABLE" }, true, {}) == "IGUI_MVM_Slots_Unavailable"
    and BU.blocker({ economy = "READY" }, false, nil) == "IGUI_MVM_Slots_Unsupported"
    and BU.blocker({ economy = "READY" }, true, nil) == "IGUI_MVM_Slots_LoadingPrices"
    and BU.blocker({ economy = "READY" }, true, {}) == nil, "付費區塊可用性：server 整合狀態優先，缺 client API 明確提示")
check(BU.purchaseKey({ ok = false, error = "timeout", unknown = true }) == "IGUI_MVM_Slots_NoAnswer"
    and BU.purchaseKey({ ok = false, error = "insufficient_funds" }) == nil
    and BU.purchaseKey({ ok = true, duplicate = true }) == "IGUI_MVM_Slots_Duplicate"
    and BU.purchaseKey({ ok = true, snapshot = { entitlement = { durable = { status = "pending" } } } }) == "IGUI_MVM_Slots_PaidDone",
    "購買結果：逾時＝未知、拒絕回原因碼；受理即完成，不看存檔狀態（付款當下生效）")
check(BU.stateKey(nil) == "nil/nil" and BU.stateKey({ entitlement = { revision = 4 }, plan = { revision = 2 } }) == "4/2",
    "狀態列訊息綁定權益／方案版本")
local HOUR, DAY, T0 = 3600000, 86400000, 1000000
check(BU.leftText(T0 + 7 * DAY, T0) == "IGUI_MVM_Slots_Days(7)"
    and BU.leftText(T0 + 6 * DAY + 23 * HOUR, T0) == "IGUI_MVM_Slots_DaysHours(6,23)"
    and BU.leftText(T0 + 5 * HOUR - 1, T0) == "IGUI_MVM_Slots_Hours(5)"
    and BU.leftText(T0, T0) == nil and BU.leftText(nil, T0) == nil,
    "剩餘時間：整天只寫天數（不寫 0 小時）、不到一天只寫小時、已到期不顯示")

-- 上限、續租、自動續租暫停與清單說明
local PLAN = { permanentEnabled = true, permanentLimit = 10, permanentPrice = 1000, permanentCurrency = "survivor",
    rentalLimit = 5, rentalEnabled = true, rentalPrice = 250, rentalCurrency = "survivor", rentalDays = 7,
    autoRenewAllowed = true, revision = 3 }
check(BU.permanentMax(PLAN, { permanent = 2 }) == 8 and BU.permanentMax({ permanentLimit = 500 }, { permanent = 0 }) == 100
    and BU.permanentMax(PLAN, { permanent = 10 }) == 0 and BU.clamp(12, 8) == 8 and BU.clamp(0, 8) == 1,
    "買斷數量：1..min(100, 上限－已買)，買滿就不給買")
local function rentalsOf(n)
    local t = {}
    for i = 1, n do t[i] = { id = "r" .. i, quantity = 1 } end
    return t
end
local room, roomWhy = BU.newRental(PLAN, { rentalCommitted = 3, rentals = rentalsOf(2) })
local _, fullWhy = BU.newRental(PLAN, { rentalCommitted = 5, rentals = rentalsOf(2) })
local _, overWhy = BU.newRental(PLAN, { rentalCommitted = 6, rentals = rentalsOf(3) })
local _, countWhy, countMax = BU.newRental({ rentalLimit = 50 }, { rentalCommitted = 10, rentalsMax = 10, rentals = rentalsOf(10) })
check(room == 2 and roomWhy == nil and fullWhy == "IGUI_MVM_Slots_RentalFull" and overWhy == "IGUI_MVM_Slots_OverLimit"
    and countWhy == "IGUI_MVM_Slots_RentalCount" and countMax == 10, "新租約：上限－租用合計；滿額、超過上限、張數已滿各自說明")
local function envOf(ent, available, plan) return { ok = true, available = available, plan = plan or PLAN, entitlement = ent } end
check(BU.sheetMax(envOf({ permanent = 2, rentalCommitted = 3, rentals = rentalsOf(2) }), "permanent") == 8
    and BU.sheetMax(envOf({ rentalCommitted = 3, rentals = rentalsOf(2) }), "rental") == 2
    and BU.sheetMax(envOf({}, nil, { permanentLimit = 10 }), "permanent") == 0,
    "確認頁數量上限：買斷看剩餘上限、租用看 newRental；不開放就是 0")
local liveR = { id = "a", quantity = 2, state = "active", paidUntil = 1 }
local endedR = { id = "b", quantity = 2, state = "expired", paidUntil = 1 }
check(BU.renewReason(envOf({ rentalCommitted = 5 }), liveR) == nil
    and BU.renewReason(envOf({ rentalCommitted = 6 }), liveR) == "OVER"
    and BU.renewReason(envOf({ rentalCommitted = 3 }), endedR) == nil
    and BU.renewReason(envOf({ rentalCommitted = 4 }), endedR) == "OVER"
    and BU.renewReason(envOf({ rentalCommitted = 2 }, false), liveR) == "PAUSED"
    and BU.renewReason(envOf({ rentalCommitted = 2 }), { quantity = 1, state = "paused_system", paidUntil = 1 }) == "PAUSED",
    "續租：有效租約看合計是否超過上限，已到期的要加回自己的名額；暫停販售／系統暫停不能續租")
local agreed = { price = 250, currency = "survivor", days = 7 }
local function autoOn(terms) return { autoRenew = true, autoRenewState = "paused_terms", autoTerms = terms, quantity = 2 } end
local noAuto = { rentalLimit = 5, rentalEnabled = true, rentalPrice = 250, rentalCurrency = "survivor", rentalDays = 7 }
local raised = autoOn({ price = 200, currency = "survivor", days = 7 })
check(not BU.autoPaused(PLAN, { rentalCommitted = 2 }, { autoRenew = true, autoRenewState = "on", autoTerms = agreed })
    and BU.autoPaused(PLAN, { rentalCommitted = 2 }, raised) and BU.needsConsent(PLAN, raised)
    and BU.autoPaused(PLAN, { rentalCommitted = 6 }, { autoRenewState = "on", autoTerms = agreed })
    and not BU.needsConsent(PLAN, { autoRenewState = "on", autoTerms = agreed })
    and BU.autoPaused(noAuto, { rentalCommitted = 2 }, { autoRenewState = "on", autoTerms = agreed })
    and not BU.needsConsent(noAuto, raised)
    and not BU.autoPaused(PLAN, { rentalCommitted = 2 }, { autoRenewState = "pending_off", autoTerms = { price = 1 } }),
    "自動續租：條款變了才要玩家同意（且方案仍提供）；超額、不提供只顯示暫停；已關閉的不算")
check(BU.termsText(nil, PLAN, { price = 200, currency = "survivor", days = 7 }, 2)
        == "IGUI_MVM_Slots_NewPrice(IGUI_MVM_Slots_Money(500,survivor),IGUI_MVM_Slots_Money(400,survivor))"
    and BU.termsText(nil, PLAN, { price = 250, currency = "survivor", days = 5 }, 1)
        == "IGUI_MVM_Slots_NewTerms(IGUI_MVM_Slots_Money(250,survivor),7,IGUI_MVM_Slots_Money(250,survivor),5)",
    "條款變更一句話：只有租金變寫每期金額（原值）；天數或幣別也變才連天數一起寫")
local over2 = BU.notices(envOf({ rentalCommitted = 6, rentals = { liveR, endedR } }))
local stopped = BU.notices(envOf({ rentalCommitted = 2, rentals = { { autoRenewState = "on" },
    { state = "paused_system", autoRenewState = "paused_system" } } }, nil,
    { rentalLimit = 5, rentalEnabled = false, autoRenewAllowed = false }))
local offer = BU.notices(envOf({ rentalCommitted = 2, rentals = { { autoRenewState = "on" } } }, nil, noAuto))
check(#over2 == 1 and over2[1][1] == "IGUI_MVM_Slots_OverLimit" and over2[1][2] == 5 and over2[1][3] == 6
    and #stopped == 2 and stopped[1][1] == "IGUI_MVM_Slots_RentalStopped" and stopped[2][1] == "IGUI_MVM_Slots_SystemPaused"
    and #offer == 1 and offer[1][1] == "IGUI_MVM_Slots_AutoNotOffered"
    and #BU.notices(envOf({ rentalCommitted = 6, rentals = {} })) == 0,
    "租約清單說明：每種狀態只說一次（兩張租約超額只一句）；停租時不另說不提供自動續租；沒有租約不說")
local renewEnv = envOf({ rentals = { { id = "r9", quantity = 3 } } })
local amount, cur, n = BU.sheetMoney(renewEnv, { kind = "renew", rental = "r9" })
local pAmount, pCur, pN = BU.sheetMoney(renewEnv, { kind = "permanent", qty = 2 })
local rAmount = BU.sheetMoney(renewEnv, { kind = "rental", qty = 4 })
check(amount == 750 and cur == "survivor" and n == 3 and pAmount == 2000 and pCur == "survivor" and pN == 2 and rAmount == 1000
    and BU.quoteMatches({ amount = 750, currency = "survivor" }, { amount = 750, currency = "survivor" })
    and not BU.quoteMatches({ amount = 900, currency = "survivor" }, { amount = 750, currency = "survivor" })
    and not BU.quoteMatches({ amount = 750, currency = "cat" }, { amount = 750, currency = "survivor" }),
    "確認頁金額：買斷／新租約＝數量×單價、續租＝該張名額×目前租金；報價金額或幣別不同就不算相符")
local wrapped = {}
BU.wrap(wrapped, "-------12 days", 8, nil, function(s) return #s end)
check(wrapped[1] == "-------" and wrapped[2] == "12 days" and wrapped[3] == nil,
    "名額視窗換行：照字切時不從數字中間斷，數字和後面緊接的字一起換到下一行")
wrapped = {}
BU.wrap(wrapped, "abcdefghij", 4, nil, function(s) return #s end)
check(wrapped[1] == "abcd" and wrapped[2] == "efgh" and wrapped[3] == "ij", "名額視窗換行：整行都是英數字時照字切")
wrapped = {}
BU.wrap(wrapped, "------\227\128\129" .. "7 \230\151\165\233\150\147", 12, nil, function(s) return #s end)
check(wrapped[1] == "------\227\128\129" and wrapped[2] == "7 \230\151\165\233\150\147",
    "名額視窗換行：數字和後面的中日文單位（中間有空白）一起換到下一行")
wrapped = {}
BU.wrap(wrapped, "租金調為每期 300 倖存幣（原 250 倖存幣）", 48, nil, function(s) return #s end)
check(wrapped[1] == "租金調為每期 300 倖存幣（原 250 倖" and wrapped[2] == "存幣）" and wrapped[3] == nil,
    "名額視窗換行：中文夾數字時在放得下的最後一個字斷，不退回最後一個空白（舊版只排到「（原」，行只用到一半）")
wrapped = {}
BU.wrap(wrapped, "あいうサバイバーコイン", 30, nil, function(s) return #s end)
check(wrapped[1] == "あいう" and wrapped[2] == "サバイバーコイン" and wrapped[3] == nil,
    "名額視窗換行：片假名詞像英文單字一樣整個換到下一行，不切成「サバイバーコイ／ン」")

-- 付費名額設定視窗純邏輯：變更清單、整份送出、草稿 rebase、影響說明
isClient = function() return true end
assert(loadfile(MEDIA .. "/client/ISUI/MinidoracatVehicleManager_PaidSlotsWindow.lua"))()
isClient = function() return false end
local PS = MVM.PaidSlotsUI
local BASE = { permanentEnabled = true, permanentPrice = 1000, permanentCurrency = "survivor", permanentLimit = 10,
    rentalEnabled = true, rentalPrice = 250, rentalCurrency = "survivor", rentalDays = 7, rentalLimit = 5,
    graceHours = 24, reminderHours = 24, autoRenewAllowed = true, revision = 4 }
local draft = PS.draftOf(BASE)
check(#PS.FIELDS == 12 and draft.permanentPrice == "1000" and draft.rentalCurrency == "survivor" and draft.autoRenewAllowed == true
    and #PS.changes(BASE, draft) == 0 and PS.BY_FILE["rent.price"].key == "rentalPrice"
    and PS.same(PS.SPEC.rentalDays, "007", 7) and not PS.same(PS.SPEC.rentalDays, "", 0),
    "設定草稿：12 欄、整數存成文字；剛載入沒有變更；設定檔鍵名對回方案欄位；整數比數值、空白不等於 0")
draft.rentalPrice, draft.rentalCurrency, draft.rentalLimit = "300", "cat", "2"
local changed = PS.changes(BASE, draft)
local values = PS.payload(draft)
draft.graceHours = "1x"
local bad, badKey = PS.payload(draft)
draft.graceHours = "24"
check(#changed == 3 and changed[1] == "rentalPrice" and changed[2] == "rentalCurrency" and changed[3] == "rentalLimit"
    and values.rentalPrice == 300 and values.rentalLimit == 2 and values.permanentEnabled == true and values.revision == nil
    and bad == nil and badKey == "graceHours",
    "套用：變更依欄位順序列出；送出整份 12 欄、型別正確；有欄位不是整數就不送並指出那一欄")
local NEWER = {}
for k, v in pairs(BASE) do NEWER[k] = v end
NEWER.permanentPrice, NEWER.rentalLimit, NEWER.revision = 1200, 4, 5
local rebased, others = PS.rebase(BASE, NEWER, draft)
check(rebased.permanentPrice == "1200" and rebased.rentalPrice == "300" and rebased.rentalLimit == "2"
    and rebased.graceHours == "24" and #others == 2 and others[1] == "permanentPrice" and others[2] == "rentalLimit",
    "rebase：沒改的欄位換成最新值、我改過的保留（含別人也改了的欄位）；回報別人改了哪些欄位")
local function keysOf(list)
    local t = {}
    for i, m in ipairs(list) do t[i] = m[1] .. (m[2] ~= nil and ("=" .. tostring(m[2])) or "") end
    return table.concat(t, " ")
end
local function withDraft(edit)
    local d = PS.draftOf(BASE)
    for k, v in pairs(edit) do d[k] = v end
    return keysOf(PS.impacts(BASE, d))
end
check(withDraft({ rentalPrice = "300", rentalLimit = "2" })
        == "IGUI_MVM_Paid_Impact_RentTerms IGUI_MVM_Paid_Impact_RentLimit=2"
    and withDraft({ permanentPrice = "1200", rentalLimit = "9", graceHours = "48" }) == ""
    and withDraft({ rentalEnabled = false, rentalPrice = "300" }) == "IGUI_MVM_Paid_Impact_RentOff"
    and withDraft({ autoRenewAllowed = false }) == "IGUI_MVM_Paid_Impact_AutoOff"
    and withDraft({ permanentEnabled = false }) == "IGUI_MVM_Paid_Impact_BuyOff"
    and withDraft({ permanentLimit = "3" }) == "IGUI_MVM_Paid_Impact_BuyLimit=3",
    "影響說明只列這次會發生的：改租金才提自動續租、調低上限才提超額；漲買斷價、調高上限、改寬限不列")
local function name(id) return "<" .. tostring(id) .. ">" end
check(PS.changeLine("rentalCurrency", "survivor", "cat", name)
        == "IGUI_MVM_Paid_ChangeLine(IGUI_MVM_Paid_Name_rentalCurrency,<survivor>,<cat>)"
    and PS.changeLine("rentalEnabled", true, false, name)
        == "IGUI_MVM_Paid_ChangeLine(IGUI_MVM_Paid_Name_rentalEnabled,IGUI_MVM_Paid_On,IGUI_MVM_Paid_Off)"
    and PS.bannerText({ actor = "test2" }, { "permanentPrice" }, BASE, NEWER, true, name)
        == "IGUI_MVM_Paid_BannerKept(test2,IGUI_MVM_Paid_ChangeShort(IGUI_MVM_Paid_Name_permanentPrice,1000,1200))"
    and PS.bannerText({ origin = "file", actor = "file" }, { "rentalLimit" }, BASE, NEWER, false, name)
        == "IGUI_MVM_Paid_Banner(IGUI_MVM_Paid_FileActor,IGUI_MVM_Paid_ChangeShort(IGUI_MVM_Paid_Name_rentalLimit,5,4))"
    and PS.lastText({ actor = "test", reason = "  " }) == "IGUI_MVM_Paid_LastByNoReason(test)"
    and PS.trim("  summer \n") == "summer",
    "變更前後與橫幅：誰（設定檔另外標示）、哪個欄位、舊值改為新值；原因只有空白視為沒寫")
local paidLog, realPaidLog = {}, MVM.log
MVM.log = function(msg) paidLog[#paidLog + 1] = tostring(msg) end
local unknownText = PS.fileErrorText("unknown_product", "rent.price")
MVM.log = realPaidLog
check(PS.fileErrorText("invalid_plan", "rent.limit")
        == "IGUI_MVM_Paid_FileErr_invalid_plan(IGUI_MVM_Paid_Name_rentalLimit,rent.limit)"
    and PS.fileErrorText("missing_field", "buy") == "IGUI_MVM_Paid_FileErr_missing_field(buy,buy)"
    and PS.fileErrorText("unknown_field", "buy.discount") == "IGUI_MVM_Paid_FileErr_unknown_field(buy.discount,buy.discount)"
    and PS.fileErrorText("invalid_json", "rent.price") == "IGUI_MVM_Paid_FileErr_invalid_json"
    and unknownText == "IGUI_MVM_Paid_FileErr_other" and not unknownText:find("unknown_product", 1, true)
    and paidLog[1] ~= nil and paidLog[1]:find("unknown_product", 1, true) ~= nil,
    "設定檔錯誤句：%1＝欄位顯示名稱（對不到方案欄位就是檔案鍵）、%2＝檔案鍵；沒有欄位的碼不帶參數；未知碼走不帶參數的 other，原碼只進 log")
do -- 錯誤句的四語字串：每個碼都有、帶欄位的有 %1 與 %2、沒有欄位與 other 不帶參數（Economy 以同一組參數組句）
    local bad = {}
    for _, lang in ipairs({ "CH", "CN", "EN", "JP" }) do
        local fh = assert(io.open(MEDIA .. "/shared/Translate/" .. lang .. "/IG_UI.json", "rb"))
        local text = fh:read("a")
        fh:close()
        local function value(code) return text:match('"IGUI_MVM_Paid_FileErr_' .. code .. '": "([^\n]-)",?\n') end
        for _, code in ipairs({ "invalid_json", "unreadable", "write_failed", "other" }) do
            local v = value(code)
            if v == nil or v:find("%", 1, true) then bad[#bad + 1] = lang .. ":" .. code end
        end
        for _, code in ipairs({ "missing_field", "invalid_type", "invalid_plan" }) do
            local v = value(code)
            if v == nil or not v:find("%1", 1, true) or not v:find("%2", 1, true) then bad[#bad + 1] = lang .. ":" .. code end
        end
        for _, code in ipairs({ "unknown_field" }) do
            local v = value(code)
            if v == nil or not v:find("%2", 1, true) then bad[#bad + 1] = lang .. ":" .. code end
        end
        if not text:find('"IGUI_MVM_SourceName": "', 1, true) then bad[#bad + 1] = lang .. ":SourceName" end
    end
    check(#bad == 0, "設定檔錯誤句四語：參數照約定（欄位名 %1、檔案鍵 %2；沒有欄位與 other 不帶參數）、來源名稱有譯文" .. (#bad > 0 and (" " .. table.concat(bad, " ")) or ""))
end
check(PS.INPUT_DIGITS >= #tostring(1000000000),
    "設定視窗整數欄打得下 Economy 允許的最大價格 1000000000（10 位）")
local fxs, frows, fn = PS.flow({ 100, 90, 40 }, 300, 200, 480, 6)
local oxs, _, on = PS.flow({ 50, 50 }, 300, 200, 480, 6)
check(fxs[1] == 300 and frows[1] == 0 and fxs[2] == 200 and frows[2] == 1 and fxs[3] == 296 and frows[3] == 1 and fn == 2
    and on == 1 and oxs[2] == 356,
    "設定視窗價格列：幣別與註記放不下就換到下一行、對齊輸入框左緣；放得下維持一行")

-- 載入真正視窗操作方法；只替代未啟動遊戲時不存在的 UI 建構依賴與 Economy 傳輸。
local savedUI, savedPanel, savedFont, savedCore = MinidoracatUI, ISPanel, UIFont, getCore
getCore = function() return { getScreenWidth = function() return 1920 end } end
local savedWindow, savedBillingUI = MVM.BillingWindow, MVM.BillingUI
MinidoracatUI = { v1 = { API_MAJOR = 1, API_REVISION = 7,
    CAPABILITIES = { window = true, controls = true, dialog = true },
    Theme = { create = function(options) return options end },
    Dialog = { show = function(opts) return opts end } } }
ISPanel = { derive = function() return {} end }
UIFont = { Small = 1, Medium = 2, Large = 3 }
isClient = function() return true end
assert(loadfile(MEDIA .. "/client/ISUI/MinidoracatVehicleManager_BillingWindow.lua"))()
isClient = function() return false end
-- 設定視窗用到 rev 11 的 Button:setActive：框架較舊時不建視窗，名額視窗的管理員入口改說明要更新框架
local savedPaid = MVM.PaidSlotsWindow
MVM.PaidSlotsWindow = nil
MinidoracatUI.v1.API_REVISION = 10
isClient = function() return true end
assert(loadfile(MEDIA .. "/client/ISUI/MinidoracatVehicleManager_PaidSlotsWindow.lua"))()
local rev10 = MVM.PaidSlotsWindow
MinidoracatUI.v1.API_REVISION = 11
assert(loadfile(MEDIA .. "/client/ISUI/MinidoracatVehicleManager_PaidSlotsWindow.lua"))()
isClient = function() return false end
local rev11 = MVM.PaidSlotsWindow
MVM.PaidSlotsWindow = nil
local adminProbe = setmetatable({}, MVM.BillingWindow)
adminProbe:onAdmin()
check(rev10 == nil and rev11 ~= nil and adminProbe.message == "IGUI_MVM_NeedFramework" and adminProbe.messageToken == "errorText",
    "設定視窗需要框架 rev 11：rev 10 不建視窗，入口按下說明要更新框架")
do -- 設定視窗捲動：內容高於可視就捲、只顯示完整在可視範圍的控制項、輸入框停到畫面外並放掉鍵盤、頁尾不捲
    local function ctl(y, entry)
        local c = { contentY = y, contentX = 20, height = 30, x = 20, visible = true }
        function c:setY(v) self.y = v end
        function c:setX(v) self.x = v end
        function c:setVisible(v) self.visible = v end
        if entry then
            c.focused = true
            c._entry = { unfocus = function() c.focused = false end }
            c._entry.parent = c
            function c:isFocused() return self.focused end
        end
        return c
    end
    local first, field, last, footBtn = ctl(10), ctl(400, true), ctl(600), ctl(0)
    footBtn.y = 5
    local pw = setmetatable({ body = { height = 300 }, contentH = 700, scroll = 0, placed = { first, field, last },
        footPlaced = { footBtn }, focusList = {}, focusPool = {} }, rev11)
    pw:setScroll(9999)
    local bottomView = pw.scroll == 400 and not first.visible and last.visible and last.y == 200 and field.x == 20
        and field.y == 0
    pw:setScroll(0)
    check(bottomView and first.visible and not last.visible and field.visible and field.x < -1000 and field.focused == false
        and footBtn.y == 5,
        "設定視窗捲動：捲到底夾在內容高－可視高；捲出的按鈕隱藏、輸入框停到畫面外仍可見並放掉鍵盤；頁尾不跟著捲")
    pw:buildFocus()
    local d = pw.focusList
    field.scrollTo = function(f) pw:scrollTo(f) end
    local owner = d[2].scrollOwner
    if owner and owner.scrollTo then owner:scrollTo(d[2].control) end
    check(#d == 4 and d[1].kind == "group" and d[1].scrollOwner == pw.body and d[2].kind == "entry"
        and d[2].control == field._entry and d[2].frame == field and owner == field and d[2].control.parent == owner
        and d[4].controls[1] == footBtn and d[4].scrollOwner == nil and pw.scroll == 130 and field.x == 20 and field.y == 270,
        "設定視窗焦點：輸入框描述的 scrollOwner 是它的 TextField（entry 的 parent），落點前捲進可視範圍；頁尾描述不捲動")
end
do -- 手把開窗：GET 回來第一次排出表單後落到第一個目標，只落一次；不是手把就不落
    local focused
    local v1 = MinidoracatUI.v1
    v1.API_REVISION, v1.CAPABILITIES.focus = 11, true
    v1.Focus = { holdsJoypad = function(win) return win.joy end,
        focusControl = function(c, ring) focused = { c = c, ring = ring } end,
        onFocus = function(root) focused = { root = root } end }
    isClient = function() return true end
    assert(loadfile(MEDIA .. "/client/ISUI/MinidoracatVehicleManager_PaidSlotsWindow.lua"))()
    isClient = function() return false end
    local P2, first = MVM.PaidSlotsWindow, {}
    local early = setmetatable({ landPending = true, win = { joy = true }, focusList = {} }, P2)
    early:landJoypad()
    local lw = setmetatable({ landPending = true, win = { joy = true }, focusList = { { control = first } } }, P2)
    lw:landJoypad()
    local once = focused ~= nil and focused.c == first and focused.ring == true and lw.landPending == nil
    focused = nil
    lw:landJoypad()
    local mouse = setmetatable({ landPending = true, win = { joy = false }, focusList = { { control = first } } }, P2)
    mouse:landJoypad()
    check(early.landPending == true and once and focused == nil and mouse.landPending == nil,
        "設定視窗手把開窗：表單排出後落到第一個目標（畫框），只落一次；還沒有目標時等下一次；滑鼠開窗不落")
    -- 關閉設定視窗：前景與鍵盤交回開它的視窗（Focus.onFocus 會 bringToTop 並成為作用中 root）；
    -- 開啟者已關、或不是從視窗開的就不動
    local function fakeWin(shown)
        local o = { javaObject = {}, shown = shown }
        function o:getIsVisible() return self.shown end
        function o:setVisible(v) self.shown = v end
        return o
    end
    local billingWin, cw = fakeWin(true), setmetatable({ win = fakeWin(true) }, P2)
    cw:watchClose()
    cw.opener = billingWin
    focused = nil
    cw.win:setVisible(true)
    local stillOpen = focused == nil
    cw.win:setVisible(false)
    local back = focused and focused.root == billingWin and cw.opener == nil
    focused = nil
    cw.win:setVisible(true)
    cw.opener = fakeWin(false)
    cw.win:setVisible(false)
    local hiddenOpener = focused == nil
    cw.win:setVisible(true)
    cw.win:setVisible(false)
    check(stillOpen and back and hiddenOpener and focused == nil,
        "關閉設定視窗：前景與鍵盤交回開它的視窗；開啟者已關或沒有開啟者時不動")
    v1.CAPABILITIES.focus, v1.Focus = nil, nil
end
MVM.PaidSlotsWindow = savedPaid
MinidoracatUI.v1.API_REVISION = 7
local w = setmetatable({ live = true, env = { ok = true, entitlement = {}, plan = {} } }, MVM.BillingWindow)
do -- 租用確認頁在窄視窗（長語言、大字級）不超出內容寬：開關標籤只放短句，每期金額另起一行換行
    local savedTM = getTextManager
    getTextManager = function()
        return { MeasureStringX = function(_, _, s) return #s * 7 end, getFontHeight = function() return 10 end }
    end
    local function fake(width)
        local c = { width = width, height = 20 }
        function c:setEnabled() end
        function c:setChecked() end
        function c:setTitle(t) self.title = t end
        function c:setLabel(l) self.label = l end
        function c:setWidth(v) self.width = v end
        function c:setX(v) self.x = v end
        return c
    end
    local box = fake(0)
    box.extraW = 44
    local sw = setmetatable({ live = true, lines = {}, placed = {}, y = 12, innerW = 260,
        env = { ok = true, plan = PLAN, entitlement = { rentalCommitted = 3, rentals = {} },
            balances = { survivor = { available = 99999 } } },
        sheet = { kind = "rental", qty = 1, auto = true },
        less = fake(20), more = fake(20), sheetAuto = box, btnPay = fake(60), btnCancel = fake(60) }, MVM.BillingWindow)
    sw:layoutSheet(ENT, sw.env, { total = 5 })
    local right, over = 12 + 260, {}
    for _, l in ipairs(sw.lines) do
        if l.x + #l.text * 7 > right then over[#over + 1] = l.text end
    end
    for _, c in ipairs(sw.placed) do
        if c.x + c.width > right then over[#over + 1] = tostring(c.label or c.title) end
    end
    getTextManager = savedTM
    check(#over == 0 and box.label == "IGUI_MVM_Slots_SheetAutoBox",
        "租用確認頁：每行文字與控制項都在內容寬內；到期自動續租開關只放短句，每期金額另起一行")
end
local purchaseReply, orderReply, requestedOrder, lastQuote
local purchaseCount, quoteCount = 0, 0
ENT.purchase = function(_, quoteId, cb) purchaseCount = purchaseCount + 1; purchaseReply = cb; lastQuote.paid = quoteId; return "purchase" end
ENT.quote = function(_, _, kind, qty, cb, rental)
    quoteCount = quoteCount + 1
    lastQuote = { kind = kind, qty = qty, rental = rental, cb = cb }
    return "quote"
end
ENT.getOrder = function(_, _, id, cb) requestedOrder, orderReply = id, cb; return "order" end
-- instant 商品：paid／refunded 直接是最終結果（Economy orderOutcome）
ENT.orderOutcome = function(reply)
    local order = reply.order
    if not reply.ok or reply.known ~= true or not order then return "unknown" end
    if order.paid == false and order.final == true then return "not_paid" end
    if order.status == "paid" or order.status == "refunded" then return order.status end
    return "processing"
end
lastQuote = {}
local quote = { id = "quote-1", orderId = "order-1" }
w:purchase(quote)
purchaseReply({ ok = false, error = "timeout", unknown = true })
w:startQuote("permanent", 1)
w:purchase(quote)
check(not w:canPurchase() and w.order.quoteId == "quote-1" and w.order.orderId == "order-1"
    and purchaseCount == 1 and quoteCount == 0 and w.message == "IGUI_MVM_Slots_NoAnswer" and w.messageToken == "accent",
    "付款逾時保留原識別，按鈕與直接操作都不能重購；狀態列（金色）請玩家查詢購買結果")
w:onCheckOrder()
orderReply({ ok = true, known = false, quoteState = "gone" })
check(not w:canPurchase() and requestedOrder == "order-1" and w.order.orderId == "order-1",
    "查無訂單或 gone 不是未付款證明，付款鎖不解除")
w:onCheckOrder()
orderReply({ ok = false, unknown = true, error = "timeout" })
check(not w:canPurchase() and w.order.orderId == "order-1", "查詢再次逾時仍保留原付款鎖")
w:onCheckOrder()
orderReply({ ok = true, known = true, order = { orderId = "unrelated-renewal", status = "paid" } })
check(not w:canPurchase(), "另一筆已付款訂單不能解除本筆未知付款")
w:onCheckOrder()
orderReply({ ok = true, known = true, order = { orderId = "order-1", status = "processing" } })
check(not w:canPurchase(), "同筆訂單還沒有最終結果，仍禁止再買")
w:onCheckOrder()
orderReply({ ok = true, known = true, order = { orderId = "order-1", status = "paid" } })
check(w:canPurchase() and w.order == nil and w.message == "IGUI_MVM_Slots_PaidDone" and w.messageToken == "text",
    "查回同筆 paid：解除付款鎖，狀態列白字說付款完成")
w:purchase(quote)
purchaseReply({ ok = true, orderId = "order-1" })
check(w:canPurchase() and w.order == nil and w.message == "IGUI_MVM_Slots_PaidDone",
    "付款受理就完成（付款當下生效），可以馬上再買")
w:purchase(quote)
purchaseReply({ ok = false, error = "insufficient_funds" })
check(w:canPurchase() and w.messageToken == "errorText", "server 明確拒絕購買時解除付款鎖並以紅字顯示原因")
w:say("old")
w:syncMessage("1/3")
w:syncMessage("1/3")
local kept = w.message
w:syncMessage("2/3")
check(kept == "old" and w.message == nil, "新狀態到達（權益或方案版本變了）就清掉舊的狀態列訊息")

-- 確認頁：數量、報價金額相符才付款，不同就不付並提示；續租只送租約 id
local renewed = { id = "r1", quantity = 2, state = "active", paidUntil = 1,
    terms = { price = 200, amount = 400, currency = "survivor", days = 7 } }
w.env = { ok = true, plan = PLAN, entitlement = { permanent = 2, rentalCommitted = 3, revision = 4, rentals = { renewed } } }
w:onBuyPermanent()
w.sheet.qty = 50
w:onPay()
check(w.sheet.kind == "permanent" and lastQuote.kind == "permanent" and lastQuote.qty == 8 and lastQuote.rental == nil
    and w.sheet.expect.amount == 8000, "買斷確認頁：送出數量夾回可買上限，記下畫面上的金額")
local before = purchaseCount
lastQuote.cb({ ok = true, quote = { id = "q-p1", orderId = "o-p1", kind = "permanent", quantity = 8, amount = 9600, currency = "survivor" } })
check(purchaseCount == before and w.sheet ~= nil and w.sheet.notice == true and w.order == nil,
    "報價金額和確認頁不同（方案剛改）：不付款，留在確認頁提示價格已變更")
w:onPay()
lastQuote.cb({ ok = true, quote = { id = "q-p2", orderId = "o-p2", kind = "permanent", quantity = 8, amount = 8000, currency = "survivor" } })
check(purchaseCount == before + 1 and lastQuote.paid == "q-p2" and w.sheet.notice == nil,
    "報價金額相符：立刻以同一張報價付款")
purchaseReply({ ok = true, orderId = "o-p2" })
check(w.sheet == nil and w.message == "IGUI_MVM_Slots_PaidDone", "付款成功回總覽")
w:onRenew({ internal = "r1" })
w:onPay()
check(w.sheet.kind == "renew" and lastQuote.kind == "rental" and lastQuote.qty == nil and lastQuote.rental == "r1"
    and w.sheet.expect.amount == 500, "續租只送租約 id，金額＝該張名額×目前租金")
w.busy = "quote"
w:closeSheet()
local heldWhileQuoting = w.sheet ~= nil
w.busy = nil
w:closeSheet()
check(heldWhileQuoting and w.sheet == nil, "確認頁：報價／付款進行中不能關，否則 Esc／取消回總覽")
w.env.entitlement.rentalCommitted = 6
w:onRenew({ internal = "r1" })
check(w.sheet == nil, "租用合計超過上限：續租按鈕不開確認頁")

-- 新租約勾了到期自動續租：付款成功後替這張新租約（id＝訂單 id）送同意，條款＝報價的方案版本
local consent
ENT.setAutoRenew = function(_, _, enabled, revision, terms, cb, rental)
    consent = { enabled = enabled, revision = revision, terms = terms, rental = rental, cb = cb }
    return "consent"
end
w.env.entitlement.rentalCommitted = 3
w:onRent()
w.sheet.qty, w.sheet.auto = 2, true
w:onPay()
lastQuote.cb({ ok = true, quote = { id = "q-r", orderId = "o-r", kind = "rental", quantity = 2, amount = 500,
    currency = "survivor", termsRevision = 3 } })
purchaseReply({ ok = true, orderId = "o-r", snapshot = { entitlement = { revision = 9 }, plan = { revision = 3 } } })
check(consent and consent.enabled == true and consent.rental == "o-r" and consent.revision == 9 and consent.terms == 3
    and w.busy == "autoRenew", "新租約勾自動續租：付款後用新權益版本與報價的條款版本替新租約送同意")
consent.cb({ ok = false, error = "terms_changed" })
check(w.busy == nil and w.messageToken == "errorText" and w.message:find("IGUI_MVM_Slots_PaidAutoFailed", 1, true) == 1,
    "付款後同意失敗：說明付款已完成、自動續租沒開與原因")
consent = nil
w:onRent()
w:onPay()
lastQuote.cb({ ok = true, quote = { id = "q-r2", orderId = "o-r2", kind = "rental", quantity = 1, amount = 250, currency = "survivor" } })
purchaseReply({ ok = true, orderId = "o-r2" })
check(consent == nil and w.message == "IGUI_MVM_Slots_PaidDone", "沒勾自動續租就不送同意")

-- 勾了自動續租但付款逾時：意圖跟著訂單，查回同一筆 paid 才補送同意；查回未付款就不送
local function rentTimedOut(orderId)
    w:onRent()
    w.sheet.qty, w.sheet.auto = 1, true
    w:onPay()
    lastQuote.cb({ ok = true, quote = { id = "q-" .. orderId, orderId = orderId, kind = "rental", quantity = 1, amount = 250,
        currency = "survivor", termsRevision = 3 } })
    purchaseReply({ ok = false, error = "timeout", unknown = true })
end
rentTimedOut("o-r3")
local heldIntent = consent == nil and w.order and w.order.auto ~= nil
w:onCheckOrder()
orderReply({ ok = true, known = true, order = { orderId = "o-r3", status = "paid" }, snapshot = { entitlement = { revision = 11 } } })
check(heldIntent and consent and consent.enabled == true and consent.rental == "o-r3" and consent.revision == 11
    and consent.terms == 3 and w.order == nil and w.busy == "autoRenew",
    "付款逾時後查回同筆 paid：用查詢回覆的權益版本與報價的條款版本替新租約送同意")
consent.cb({ ok = true })
check(w.busy == nil and w.message == "IGUI_MVM_Slots_PaidDone", "補送同意成功：狀態列說付款完成")
consent = nil
rentTimedOut("o-r4")
w:onCheckOrder()
orderReply({ ok = true, known = true, order = { orderId = "o-r4", status = "unsubmitted", paid = false, final = true } })
check(consent == nil and w.order == nil and w.message == "IGUI_MVM_Slots_NoOrder",
    "付款逾時後查回未付款：解除付款鎖、不送自動續租同意")

-- 自動續租開關：關閉直接送；開啟先到確認頁，同意才送
local box = { internal = "r1", setChecked = function() end }
w.env = { ok = true, plan = { autoRenewAllowed = false, revision = 2 }, entitlement = { revision = 1, rentals = {
    { id = "r1", quantity = 2, autoRenewState = "paused_terms", autoRenew = true } } } }
w:onAutoRenew(false, box)
check(consent and consent.enabled == false and consent.rental == "r1" and w.sheet == nil,
    "不准新開自動續租時，暫停中的原授權仍可逐張取消（不經確認頁）")
consent.cb({ ok = true })
consent = nil
w.env = { ok = true, plan = PLAN, entitlement = { revision = 1, rentals = { { id = "r1", quantity = 2, autoRenewState = "off" } } } }
w:onAutoRenew(true, box)
check(consent == nil and w.sheet and w.sheet.kind == "auto" and w.sheet.rental == "r1",
    "開啟自動續租先到確認頁，不直接送出")
w:onPay()
check(consent and consent.enabled == true and consent.rental == "r1" and consent.terms == 3, "同意後才送出該張租約的自動續租")
consent.cb({ ok = true })
check(w.sheet == nil and w.message == nil, "同意成功回總覽，狀態以開關顯示（不另留訊息）")
local stateReply
ENT.requestState = function() return nil, "queue_full" end
w:requestState()
check(w.stateError ~= nil and w.requested, "初次狀態請求本機拒送，顯示錯誤且不每幀重送")
ENT.requestState = function(_, _, cb) stateReply = cb; return "state" end
w:requestState()
stateReply({ ok = false, unknown = true, error = "timeout" })
check(w.stateError ~= nil, "狀態查詢逾時明示錯誤，不永遠顯示載入")
w:requestState()
stateReply({ ok = true })
check(w.stateError == nil and w.dirty, "玩家明示重新整理成功，清除先前讀取錯誤")
MinidoracatUI, ISPanel, UIFont, getCore = savedUI, savedPanel, savedFont, savedCore
MVM.BillingWindow, MVM.BillingUI = savedWindow, savedBillingUI
end

MinidoracatEconomy = nil
E.init()
SB.ClaimsPerPlayer = 3
end)(); -- 分號：下一個情境也是 IIFE

(function() -- 主 chunk 區域變數已滿 200：本情境用自己的函式作用域
out("情境 E2：付費名額設定檔、狀態檔與 adminPaidSlots（方案歸 VM，經 setPlan 送 Economy）")
local E, PS, X = MVM.Econ, MVM.PaidSlots, MVM.Export
local KEYS = {}
for k in pairs(E.DEFAULTS) do KEYS[#KEYS + 1] = k end
table.sort(KEYS)
local function copy(t) local c = {}; for k, v in pairs(t) do c[k] = v end; return c end
-- 假 Economy：只存一份方案；驗證只模擬兩條（租金 ≥1、幣別已註冊），判斷順序照契約（not_ready → 驗證 → 相同 → 版本）
local F = { rev = 0, calls = 0 }
local CAPS = { entitlements = true, rentals = true, setPlan = true }
MinidoracatEconomy = { CURRENCIES = { survivor = {}, cat = {} }, v1 = { API_MAJOR = 1, API_REVISION = 2, CAPABILITIES = CAPS,
    registerSource = function()
        return { registerProduct = function(p) F.product, F.plan = p, copy(p.defaults); return { ok = true } end,
            getEntitlement = function() return { ok = true, entitlement = { usable = 0 } } end,
            getPlan = function()
                local p = copy(F.plan)
                p.revision = F.rev
                return { ok = true, plan = p, lastChange = F.last }
            end,
            setPlan = function(_, values, opts)
                F.calls, F.opts = F.calls + 1, opts
                if F.notReady then return { ok = false, error = "not_ready" } end
                if F.weird then return { ok = false, error = F.weird } end
                if values.rentalPrice < 1 then return { ok = false, error = "invalid_plan", field = "rentalPrice" } end
                if values.permanentCurrency ~= "survivor" and values.permanentCurrency ~= "cat" then
                    return { ok = false, error = "invalid_plan", field = "permanentCurrency" }
                end
                local changed = {}
                for _, k in ipairs(KEYS) do if F.plan[k] ~= values[k] then changed[#changed + 1] = k end end
                if #changed == 0 then return { ok = true, updated = false, revision = F.rev } end
                if opts.expectedRevision ~= nil and opts.expectedRevision ~= F.rev then return { ok = false, error = "stale_revision" } end
                F.plan, F.rev = copy(values), F.rev + 1
                F.last = { actor = opts.actor, origin = opts.origin, at = nowMs, reason = opts.reason, revision = F.rev }
                return { ok = true, updated = true, revision = F.rev, changed = changed }
            end,
            -- 照 Economy 驗 problem：nil 或 { key, field?, ref? }，key／field 是翻譯鍵格式、ref ≤64；字串一律拒收
            setPlanSource = function(_, src)
                local p = src.problem
                local function tkey(v) return type(v) == "string" and #v >= 1 and #v <= 96 and v:match("^[%w_]+$") ~= nil end
                if p ~= nil and (type(p) ~= "table" or not tkey(p.key) or (p.field ~= nil and not tkey(p.field))
                    or (p.ref ~= nil and (type(p.ref) ~= "string" or #p.ref > 64))) then
                    F.sourceRejected = true
                    return { ok = false, error = "invalid_args", field = "problem" }
                end
                F.source = src
                return { ok = true }
            end }
    end } }
boot()
for k in pairs(files) do files[k] = nil end
serverMode = true
E.init()
PS.start()
local CFG = X.folder() .. "paid-slots.json"
local STATUS = X.folder() .. "paid-slots.status.json"
local C = PS.of[MVM.ECON_PRODUCT] -- 綁定名額這份檔的輪詢狀態（保全名額另一份，G6 測）
local function text(path) return files[path] and table.concat(files[path]) or nil end
local function put(s) files[CFG] = { s .. "\n" } end
local function poll() nowMs = nowMs + PS.POLL_MS; fire("OnTickEvenPaused") end
check(E.status == "READY" and text(STATUS) == nil and text(CFG) == nil, "Economy READY：開機不寫 economy_unavailable")
local onTick = false
for _, fn in ipairs(handlers.OnTick or {}) do if fn == PS.tick then onTick = true end end
check(not onTick, "輪詢掛 OnTickEvenPaused（PauseEmpty 空服暫停時照常讀檔），不掛 OnTick")

poll()
local created = PS.parse(text(CFG):sub(1, -2))
local same = created ~= nil
for _, k in ipairs(KEYS) do if created == nil or created[k] ~= E.DEFAULTS[k] then same = false end end
check(same and F.calls == 0 and C.status.state == "ok" and C.status.source == "created" and C.status.revision == 0,
    "設定檔不存在：用目前生效的方案（預設、兩種販售關閉）建一份，不呼叫 setPlan")
check(text(STATUS):find('"state": "ok"', 1, true) and text(STATUS):find('"source": "created"', 1, true)
    and text(STATUS):find('"error": null', 1, true) and text(STATUS):find('"field": null', 1, true)
    and text(STATUS):find('"at": "', 1, true) and text(STATUS):find('"economy": "READY"', 1, true),
    "狀態檔：state／source／revision／error／field／at／economy，空欄位明確寫 null")
check(PS.parse(text(X.folder() .. "guard-slots.json"):sub(1, -2)) ~= nil and PS.of[MVM.GUARD_PRODUCT].status.source == "created"
    and text(X.folder() .. "guard-slots.status.json"):find('"source": "created"', 1, true),
    "保全名額另一份設定檔 guard-slots.json 與狀態檔：第一次輪詢一起建")
poll()
check(F.calls == 0, "自己建的檔不當成新內容重送")

local BASE = '{"buy": {"enabled": false, "price": 1000, "currency": "survivor", "limit": 10}, "rent": {"enabled": true, '
    .. '"price": %s, "currency": "survivor", "limit": 5, "days": 7, "graceHours": 24, "reminderHours": 24, "autoRenew": true}%s}'
local function cfg(price, tail) return BASE:format(price, tail or "") end
put(cfg("300", ', "reason": "spring \\"sale\\" \\u0041\\u590f"'))
nowMs = nowMs + 1000; PS.tick()
check(F.calls == 0, "改檔後未滿 5 秒不讀")
poll()
check(F.plan.rentalPrice == 300 and F.plan.rentalEnabled == true and F.opts.origin == "file" and F.opts.actor == "file"
    and F.opts.reason == 'spring "sale" A' .. utf8.char(0x590F) and C.status.state == "ok" and C.status.source == "file"
    and C.status.revision == 1,
    "改檔：5 秒輪詢讀到 → setPlan(origin=file、actor=file、reason=檔內 reason，含跳脫字元與 Python 預設的非 ASCII \\u 跳脫）")
check(F.source.file == "Zomboid/Lua/" .. CFG and F.source.problem == nil and not F.sourceRejected, "setPlanSource：設定檔路徑、沒有錯誤")
local function isProblem(p, key, field, ref)
    return type(p) == "table" and p.key == key and p.field == field and p.ref == ref
end
local PLAN_OF = {}
for _, f in ipairs(MVM.PAID_FIELDS) do PLAN_OF[f.file] = f.key end
poll()
check(F.calls == 1, "內容沒變：不重送")

local function bad(s, err, field, label)
    put(s)
    local n = F.calls
    poll()
    check(F.calls == n and C.status.state == "error" and C.status.error == err and C.status.field == field
        and isProblem(F.source.problem, "IGUI_MVM_Paid_FileErr_" .. err,
            PLAN_OF[field or ""] and ("IGUI_MVM_Paid_Name_" .. PLAN_OF[field]) or nil, field)
        and not F.sourceRejected and F.plan.rentalPrice == 300, label)
end
bad('{"buy": ', "invalid_json", nil, "壞 JSON：invalid_json，不送 Economy，方案維持")
local st0 = C.status
poll()
check(C.status == st0, "同一份壞內容不每 5 秒重報")
bad((cfg("300"):gsub('"days": 7, ', "")), "missing_field", "rent.days", "缺鍵：missing_field rent.days")
bad((cfg("300"):gsub('"limit": 10', '"limit": 10, "discount": 5')), "unknown_field", "buy.discount", "多鍵：unknown_field buy.discount")
bad(cfg("300", ', "note": 1'), "unknown_field", "note", "頂層多鍵：unknown_field note")
bad(cfg('"300"'), "invalid_type", "rent.price", "型別錯（字串價格）：invalid_type rent.price")
bad(cfg("2.5"), "invalid_type", "rent.price", "型別錯（小數）：invalid_type rent.price")
bad(cfg("300", ', "reason": 5'), "invalid_type", "reason", "reason 不是字串：invalid_type reason")
bad(cfg("300", ', "note": null'), "unknown_field", "note", "頂層多鍵即使值是 null：unknown_field note")
bad((cfg("300"):gsub('"limit": 10', '"limit": 10, "discount": null')), "unknown_field", "buy.discount",
    "群組多鍵即使值是 null：unknown_field buy.discount")
bad(cfg("null"), "invalid_type", "rent.price", "已知欄位是 null：invalid_type rent.price")
bad(cfg("0250"), "invalid_json", nil, "數字多餘前導零（0250）：invalid_json")
bad(cfg("250."), "invalid_json", nil, "小數點後沒有數字（250.）：invalid_json")
bad(cfg("25e"), "invalid_json", nil, "指數沒有數字（25e）：invalid_json")
bad(cfg("-"), "invalid_json", nil, "只有負號：invalid_json")
bad(cfg("300x"), "invalid_json", nil, "數字後面黏著字元：invalid_json")
put(cfg("3.0e2", ', "reason": null'))
poll()
check(C.status.state == "ok" and F.opts.reason == nil and F.plan.rentalPrice == 300, "合法的 3.0e2 照收（型別檢查判整數）、reason: null 當作沒給")
put(cfg("0"))
poll()
check(C.status.error == "invalid_plan" and C.status.field == "rent.price"
    and isProblem(F.source.problem, "IGUI_MVM_Paid_FileErr_invalid_plan", "IGUI_MVM_Paid_Name_rentalPrice", "rent.price")
    and text(STATUS):find('"field": "rent.price"', 1, true) and F.plan.rentalPrice == 300,
    "Economy 回 invalid_plan：field 從 rentalPrice 轉回檔案鍵名 rent.price；problem 送翻譯鍵（句子與欄位名）與檔案鍵")
local mapOk, seenFile, nRows = true, {}, 0
for _, f in ipairs(MVM.PAID_FIELDS) do
    nRows = nRows + 1
    local group = f.file:match("^(%a+)%.%a+$")
    if E.DEFAULTS[f.key] == nil or seenFile[f.file] or (group ~= "buy" and group ~= "rent") then
        mapOk = false
    end
    seenFile[f.file] = true
end
check(mapOk and nRows == 12 and PLAN_OF["buy.enabled"] == "permanentEnabled" and PLAN_OF["rent.autoRenew"] == "autoRenewAllowed"
    and PLAN_OF["rent.graceHours"] == "graceHours",
    "共用欄位對照 MVM.PAID_FIELDS：12 欄、對到預設方案、檔案鍵不重複，server 的對照就是這一份")
check(isProblem(PS.problem("missing_field", "buy"), "IGUI_MVM_Paid_FileErr_missing_field", nil, "buy")
    and isProblem(PS.problem("invalid_type", "rent.autoRenew"), "IGUI_MVM_Paid_FileErr_invalid_type",
        "IGUI_MVM_Paid_Name_autoRenewAllowed", "rent.autoRenew")
    and isProblem(PS.problem("write_failed"), "IGUI_MVM_Paid_FileErr_write_failed", nil, nil) and PS.problem(nil) == nil,
    "problem：對不到方案欄位（群組名）時沒有 field、ref 仍是檔案鍵；沒有欄位的碼沒有 ref；沒有錯誤＝nil")
local missingKeys = {}
local wantKeys = { "IGUI_MVM_SourceName", "IGUI_MVM_Paid_FileErr_other" }
for _, c in ipairs({ "invalid_json", "unreadable", "write_failed", "missing_field", "invalid_type", "unknown_field", "invalid_plan" }) do
    wantKeys[#wantKeys + 1] = "IGUI_MVM_Paid_FileErr_" .. c
end
for _, f in ipairs(MVM.PAID_FIELDS) do wantKeys[#wantKeys + 1] = "IGUI_MVM_Paid_Name_" .. f.key end
for _, lang in ipairs({ "CH", "CN", "EN", "JP" }) do
    local fh = io.open(MEDIA .. "/shared/Translate/" .. lang .. "/IG_UI.json")
    local json = fh and fh:read("*a") or ""
    if fh then fh:close() end
    for _, k in ipairs(wantKeys) do
        if not json:find('"' .. k .. '"', 1, true) then missingKeys[#missingKeys + 1] = lang .. ":" .. k end
    end
end
check(#missingKeys == 0, "server 送出的翻譯鍵（來源名稱、設定檔錯誤句、欄位名）四語都有（缺：" .. table.concat(missingKeys, ",") .. "）")
F.weird = "unknown_product"
local serverLog, realServerLog = {}, MVM.log
MVM.log = function(msg) serverLog[#serverLog + 1] = tostring(msg) end
put(cfg("290"))
poll()
MVM.log = realServerLog
F.weird = nil
local codeInLog = false
for _, l in ipairs(serverLog) do if l:find("unknown_product", 1, true) then codeInLog = true end end
check(C.status.error == "unknown_product" and isProblem(F.source.problem, "IGUI_MVM_Paid_FileErr_other", nil, nil)
    and text(STATUS):find('"error": "unknown_product"', 1, true) and codeInLog,
    "沒有專屬句子的錯誤碼：problem 只送不帶參數的 FileErr_other（沒有 field／ref）；原碼寫進伺服器 log，狀態檔照記原碼")
put(cfg("0"))
poll()
F.notReady = true
put(cfg("280"))
poll()
local n0 = F.calls
check(F.plan.rentalPrice == 300 and C.status.error == "invalid_plan", "not_ready：不寫狀態")
F.notReady = nil
poll()
check(F.calls == n0 + 1 and F.plan.rentalPrice == 280 and C.status.state == "ok" and F.source.problem == nil,
    "not_ready 不記為已處理：下輪重試成功、清掉錯誤")
local realR = getFileReader
getFileReader = function(path, ...) if path == CFG then return nil end return realR(path, ...) end
local before, n3 = text(CFG), F.calls
poll()
check(C.status.state == "error" and C.status.error == "unreadable" and F.calls == n3 and text(CFG) == before
    and F.plan.rentalPrice == 280 and isProblem(F.source.problem, "IGUI_MVM_Paid_FileErr_unreadable", nil, nil),
    "設定檔存在但讀不到：unreadable，方案不動、不用目前方案覆寫")
local st1 = C.status
poll()
check(C.status == st1, "讀不到：同一狀態不重複報")
getFileReader = realR
poll()
check(C.status.state == "ok" and C.status.error == nil and F.calls == n3 + 1, "恢復可讀：重新處理同一份內容，清掉錯誤")

-- adminPaidSlots
local AD, PL = player("admin", 1, 1, { admin = true }), player("pleb", 1, 1)
check(cmd(PL, "adminPaidSlots", { op = "GET" }).reason == "NOT_ADMIN", "非管理員 GET：NOT_ADMIN")
local g = cmd(AD, "adminPaidSlots", { op = "GET" })
local nk = 0
for _ in pairs(g.plan) do nk = nk + 1 end
check(g.ok and g.economy == "READY" and nk == 12 and g.plan.rentalPrice == 280 and g.revision == F.rev and #g.currencies == 2
    and g.file == "Zomboid/Lua/" .. CFG and g.status.state == "ok" and g.lastChange.origin == "file" and g.lastChange.actor == "file",
    "GET：12 欄方案、revision、幣別、設定檔路徑、狀態、最後修改")
local function vals(over) local v = copy(g.plan); for k, x in pairs(over or {}) do v[k] = x end; return v end
local n1 = F.calls
check(cmd(AD, "adminPaidSlots", { op = "SET", values = vals({ permanentEnabled = true }), expectedRevision = g.revision }).reason
    == "NEED_REASON" and cmd(AD, "adminPaidSlots", { op = "SET", values = vals({ permanentEnabled = true }),
    expectedRevision = g.revision, reason = "   " }).reason == "NEED_REASON" and F.calls == n1, "SET 缺原因或只有空白：NEED_REASON，不送")
check(cmd(PL, "adminPaidSlots", { op = "SET", values = vals({ permanentEnabled = true }), expectedRevision = g.revision,
    reason = "x" }).reason == "NOT_ADMIN" and F.calls == n1, "非管理員 SET：NOT_ADMIN")
local schemaOk = true
local extra = vals()
extra.discount = 5
local wrongType = vals({ rentalPrice = "300" })
local missing = vals()
missing.graceHours = nil
for _, args in ipairs({ { op = "SET", values = extra, expectedRevision = g.revision, reason = "x" },
    { op = "SET", values = wrongType, expectedRevision = g.revision, reason = "x" },
    { op = "SET", values = missing, expectedRevision = g.revision, reason = "x" },
    { op = "SET", values = vals({ rentalCurrency = "bad-id" }), expectedRevision = g.revision, reason = "x" },
    { op = "SET", values = vals(), expectedRevision = -1, reason = "x" },
    { op = "DELETE" }, { op = "GET", owner = "x" } }) do
    if cmd(AD, "adminPaidSlots", args).reason ~= "BAD_ARGS" then schemaOk = false end
end
check(schemaOk and F.calls == n1, "SCHEMA：多欄位、錯型別、缺欄位、壞幣別字串、負版本、未知 op、夾帶欄位一律 BAD_ARGS")
check(cmd(AD, "adminPaidSlots", { op = "SET", values = vals({ permanentEnabled = true }), expectedRevision = g.revision - 1,
    reason = "x" }).reason == "STALE_REVISION" and F.plan.permanentEnabled == false, "SET 版本過期：STALE_REVISION，不套用")
local inv = cmd(AD, "adminPaidSlots", { op = "SET", values = vals({ rentalPrice = 0 }), expectedRevision = g.revision, reason = "x" })
check(inv.reason == "INVALID_PLAN" and inv.field == "rent.price", "SET 範圍錯：INVALID_PLAN，field 用檔案鍵名")
local l0 = #logLines
local s = cmd(AD, "adminPaidSlots", { op = "SET", values = vals({ permanentEnabled = true }), expectedRevision = g.revision,
    reason = "  open sales  " })
local back, backReason = PS.parse(text(CFG):sub(1, -2))
local audited = false
for i = l0 + 1, #logLines do
    if logLines[i]:find("ADMIN_PAID_SLOTS", 1, true) and logLines[i]:find("permanentEnabled open sales", 1, true)
        and logLines[i]:find("admin", 1, true) then audited = true end
end
check(s.ok and s.revision == g.revision + 1 and #s.changed == 1 and s.changed[1] == "permanentEnabled" and s.fileError == nil
    and F.last.origin == "admin" and F.last.actor == "admin" and F.last.reason == "open sales",
    "SET 成功：setPlan(origin=admin、actor=principal、去空白的 reason、expectedRevision)，回 revision 與 changed")
check(back and back.permanentEnabled == true and back.rentalPrice == 280 and backReason == "open sales"
    and C.status.source == "admin" and C.status.state == "ok" and audited, "SET 成功：寫回設定檔（含 reason）、狀態檔 source=admin、稽核 ADMIN_PAID_SLOTS")
local n2 = F.calls
poll()
check(F.calls == n2, "寫回的設定檔記為已處理：輪詢不重送")
-- 外部 5 秒內改檔、還沒輪詢到時管理員套用：先處理檔案，外部修改不被蓋掉
local extText = PS.encode(vals({ permanentEnabled = true, rentalPrice = 260 }), "external")
files[CFG] = { extText .. "\n" }
local stale = cmd(AD, "adminPaidSlots", { op = "SET", values = vals({ permanentEnabled = true, permanentPrice = 950 }),
    expectedRevision = s.revision, reason = "admin edit" })
check(stale.reason == "STALE_REVISION" and F.plan.rentalPrice == 260 and F.plan.permanentPrice == 1000
    and text(CFG) == extText .. "\n" and C.status.source == "file" and F.last.reason == "external",
    "外部剛改檔就 SET：先套用外部內容，管理員舊版本 STALE_REVISION，檔案沒被覆寫")
put('{"buy": ')
local ov = cmd(AD, "adminPaidSlots", { op = "SET", values = vals({ permanentEnabled = true, rentalPrice = 265 }),
    expectedRevision = F.rev, reason = "fix file" })
check(ov.ok and F.plan.rentalPrice == 265 and PS.parse(text(CFG):sub(1, -2)) ~= nil and C.status.source == "admin",
    "外部剛改成壞檔就 SET：壞檔照常記錯，管理員的方案套用並覆寫壞檔")
local realW = getFileWriter
-- PrintWriter 吞 I/O 錯誤：寫入「成功」但檔案內容沒變，要讀回比對才知道
getFileWriter = function(path, ...)
    if path == CFG then return { write = function() end, close = function() end } end
    return realW(path, ...)
end
local fe = cmd(AD, "adminPaidSlots", { op = "SET", values = vals({ permanentEnabled = true, permanentPrice = 900 }),
    expectedRevision = F.rev, reason = "cheaper" })
getFileWriter = realW
poll()
check(fe.ok and fe.fileError == "write_failed" and F.plan.permanentPrice == 900 and C.status.state == "error"
    and C.status.error == "write_failed" and text(STATUS):find('"error": "write_failed"', 1, true),
    "寫回失敗：方案已生效、回 fileError、狀態檔顯示，舊檔不會在下次輪詢蓋回")

-- 舊版 Economy（沒有 setPlan）：UNSUPPORTED，開機寫一次 economy_unavailable，不建也不讀設定檔
CAPS.setPlan = nil
for k in pairs(files) do files[k] = nil end
E.init()
PS.start()
poll()
check(E.status == "UNSUPPORTED" and text(CFG) == nil and text(STATUS):find('"state": "economy_unavailable"', 1, true)
    and text(STATUS):find('"economy": "UNSUPPORTED"', 1, true), "舊版 Economy：UNSUPPORTED，狀態檔 economy_unavailable，不建設定檔")
local ug = cmd(AD, "adminPaidSlots", { op = "GET" })
check(ug.ok and ug.economy == "UNSUPPORTED" and ug.plan == nil and cmd(AD, "adminPaidSlots", { op = "SET", values = vals(),
    expectedRevision = 0, reason = "x" }).reason == "ECONOMY_UNAVAILABLE", "Economy 不可用：GET 只回狀態、SET 回 ECONOMY_UNAVAILABLE")
MinidoracatEconomy = nil
E.init()
end)();

(function() -- 主 chunk 區域變數已滿 200：本情境用自己的函式作用域
-- from 起有一行同時含全部字串
local function logged(from, ...)
    local want = { ... }
    for i = from, #logLines do
        local all = true
        for _, w in ipairs(want) do if not logLines[i]:find(w, 1, true) then all = false end end
        if all then return true end
    end
    return false
end
local function mark() return #logLines + 1 end
local WK = "MinidoracatVehicleManager"
local function carry(v, w) rawset(v.parts.Engine.md, WK, w); return v end

out("情境 T1：MVCK 匯入帶入陣營共享（旗標在匯入時記下，陣營在轉正當下才查）")
boot()
local ADT = player("adminT", 1, 1, { admin = true })
local function legacyCar(id, sqlId)
    local v = vehicle(id, sqlId, 7000 + id, "Base.CarNormal", 1, 1)
    v:getModData().SQLID = 1700000000000 + sqlId
    return v
end
local function importWith(mvck, entries)
    gmd.MVCKByVehicleSQLID = gmd.MVCKByVehicleSQLID or {}
    for sqlId, owner in pairs(entries) do
        gmd.MVCKByVehicleSQLID[1700000000000 + sqlId] = { OwnerPlayerID = owner, CarModel = "Base.CarNormal", ClaimDateTime = 1700000000 }
    end
    SandboxVars.MVCK = mvck
    local ack = cmd(ADT, "adminMigration", { op = "IMPORT" })
    SandboxVars.MVCK = nil
    return ack
end
local function recOf(v) local verdict, r = O.lookup(v); return verdict == "AUTHORIZED" and r or nil end
newFaction("Wolves", "fo1", { "fm1" })
newFaction("Bears", "bo", { "fo2", "fo3", "fo5" })
local FM = player("fm1", 1, 1)
local c1, c2 = legacyCar(1, 101), legacyCar(2, 102)
local l0 = mark()
local im = importWith({ AllowFaction = true }, { [101] = "fo1", [102] = "nf1", [104] = "fo4" })
local r1, r2 = recOf(c1), recOf(c2)
check(im.ok and im.rebound == 2 and im.pending == 1 and r1 and r2, "AllowFaction=true 匯入：已載入的兩台當場轉正、一筆待轉")
check(r1.factionShare and r1.factionState == "GRANTED" and r1.factionActionBits == MVM.SHAREABLE_MASK
    and O.canUse(FM, c1, "DRIVE") and O.canUse(FM, c1, "TOW") and not O.canUse(FM, c1, "MANAGE")
    and logged(l0, "ACL_CHANGE", r1.oid, "MVCK_IMPORT"), "車主有陣營：開陣營共享，成員拿到管理以外的全部權限，稽核 MVCK_IMPORT")
check(not r2.factionShare and not logged(l0, r2.oid, "MVCK_IMPORT"), "車主沒有陣營：不開陣營共享，也不寫陣營稽核")
local c3 = legacyCar(3, 103)
importWith({ AllowFaction = false }, { [103] = "fo2" })
local r3 = recOf(c3)
check(r3 and not r3.factionShare, "MVCK 沙盒 AllowFaction=false：車主有陣營也不開")
local c5 = legacyCar(5, 105)
importWith(nil, { [105] = "fo3" })
local r5 = recOf(c5)
check(r5 and r5.factionShare and r5.factionActionBits == MVM.SHAREABLE_MASK, "讀不到 MVCK 沙盒（MVCK 不在）：照 MVCK 預設開")
newFaction("Deer", "fo4", {})
SandboxVars.MVCK = { AllowFaction = false }
local r4 = recOf(legacyCar(4, 104))
SandboxVars.MVCK = nil
check(r4 and r4.ownerUser == "fo4" and r4.factionShare and r4.factionName == "Deer",
    "匯入時沒陣營、轉正前才加入：旗標用匯入當時的，陣營看轉正當下")
SB.AllowFactionShare = false
local c6 = legacyCar(6, 106)
importWith({ AllowFaction = true }, { [106] = "fo5" })
SB.AllowFactionShare = true
local r6 = recOf(c6)
check(r6 and not r6.factionShare, "VM 沙盒關閉陣營共享：不開")

out("情境 T2：拖車裝走（移出世界）與依見證接回")
boot()
local OW, ST = player("tow1", 1, 1), player("tstr", 1, 1)
cmd(OW, "fleetSubscribe", {}, false)
local car = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
local r = rec(claim(OW, car).oid)
l0 = mark()
local free, look = vehicle(2, 102, 5002, "Base.CarNormal", 1, 1), vehicle(3, 101, 9999, "Base.CarNormal", 1, 1)
free:permanentlyRemove(); look:permanentlyRemove()
check(free.removed and look.removed and r.removedAtMs == nil and not logged(l0, "REMOVED_FROM_WORLD"),
    "未綁定的車、同 sqlId 但 keyId 不同的車被移除：照原版移除，紀錄不動")
check(cmd(OW, "reportLost", { expectedOid = r.oid }).ok and r.recordState == "PENDING_RELEASE", "車主先回報遺失（待釋放）")
car.x, car.y = 7, 8
car:permanentlyRemove()
local drow = lastOf(OW, "fleetDelta").upserts[1]
check(car.removed and r.removedAtMs == nowMs and r.removedSqlId == 101 and r.lastKnownX == 7 and r.recordState == "PENDING_RELEASE"
    and logged(l0, "REMOVED_FROM_WORLD", r.oid), "受保護的車被移除：記下移出時間、原 sqlId、最後位置並稽核，狀態不變")
check(drow.oid == r.oid and drow.removedAtMs == r.removedAtMs and O.quotaUsed("tow1") == 1, "車主收到帶 removedAtMs 的列；照常計入名額")
local l1 = mark()
O.lookup(vehicle(4, 104, 5001, "Base.CarNormal", 1, 1)) -- 卸車剛生出的車，零件見證還沒還原
check(not logged(l1, "KEYID_COLLISION_SUSPECT"), "移出時一併取消 keyId 索引：同 keyId 的新車不當成撞號")
check(O.lookup(vehicle(5, 101, 7777, "Base.CarNormal", 1, 1)) == "UNCLAIMED" and r.recordState == "PENDING_RELEASE",
    "移出時取消 sqlId 索引：同號的別台車不會讓紀錄 ORPHANED")
local car2 = vehicle(6, 201, 6001, "Base.CarNormal", 1, 1)
local rIn = rec(claim(OW, car2).oid)
local clone = carry(vehicle(7, 202, 6001, "Base.CarNormal", 1, 1), { oid = rIn.oid, epoch = rIn.epoch })
l1 = mark()
check(O.lookup(clone) == "UNCLAIMED_WITNESS_STRIPPED" and witness(clone) == nil and logged(l1, "ORPHAN_WITNESS_STRIPPED", "RECORD_IN_WORLD")
    and rIn.sqlIdHint == 201 and rIn.removedAtMs == nil and O.lookup(car2) == "AUTHORIZED",
    "見證被複製到同型同 keyId 的別台車、原車仍在世界上：剝除，紀錄不動")
local W = { oid = r.oid, epoch = r.epoch }
for _, b in ipairs({ { carry(vehicle(8, 301, 5001, "Base.Van", 1, 1), W), "SCRIPT_MISMATCH", "車型不同" },
    { carry(vehicle(9, 302, 5999, "Base.CarNormal", 1, 1), W), "KEYID_MISMATCH", "keyId 不同" },
    { carry(vehicle(10, 303, 5001, "Base.CarNormal", 1, 1), { oid = r.oid, epoch = "uuid-old-epoch" }), "EPOCH_MISMATCH", "epoch 不同" } }) do
    l1 = mark()
    check(O.lookup(b[1]) == "UNCLAIMED_WITNESS_STRIPPED" and witness(b[1]) == nil and logged(l1, "ORPHAN_WITNESS_STRIPPED", b[2])
        and r.removedAtMs ~= nil and r.sqlIdHint == 101, b[3] .. "：見證剝除，紀錄仍是移出中")
end
local disk, g2 = GOS.snapshot(), deepcopy(gmd)
boot(disk, true); gmd = g2
OW, ST = player("tow1", 1, 1), player("tstr", 1, 1)
cmd(OW, "fleetSubscribe", {}, false)
r = rec(r.oid)
check(O.ready() and r.removedAtMs ~= nil and O.lookup(vehicle(1, 101, 8888, "Base.CarNormal", 1, 1)) == "UNCLAIMED"
    and r.recordState == "PENDING_RELEASE", "重啟後舊號回收給別台車：移出中的紀錄不索引，不會 ORPHANED")
local back = vehicle(11, 555, 5001, "Base.CarNormal", 4, 4)
l1 = mark()
fire("OnSpawnVehicleEnd", back)
local early = r.removedAtMs ~= nil
carry(back, { oid = r.oid, epoch = r.epoch }) -- 拖車 MOD 生車之後才還原零件 modData
fire("OnTick")
check(early and r.removedAtMs == nil and r.sqlIdHint == 555 and logged(l1, "REATTACHED", r.oid, "sqlId 101->555"),
    "卸下的車（新 sqlId）在生車後下一個 tick 依見證接回")
check(r.recordState == "ACTIVE" and O.canUse(OW, back, "DRIVE") and not O.canUse(ST, back, "DRIVE"),
    "接回時取消待釋放；車主可用、他人仍被拒")
drow = lastOf(OW, "fleetDelta").upserts[1]
check(drow.oid == r.oid and drow.removedAtMs == nil, "車主收到接回後的列（沒有 removedAtMs）")
local YO = player("yown", 1, 1)
local car3 = vehicle(12, 401, 9401, "Base.CarNormal", 1, 1)
local r3t = rec(claim(OW, car3).oid)
local rY = rec(claim(YO, vehicle(13, 402, 9402, "Base.CarNormal", 1, 1)).oid)
car3:permanentlyRemove()
world[13].removed = true -- Y 的車被引擎直接刪掉（不經 Lua），之後 402 回收
local vLand, got = O.lookup(carry(vehicle(14, 402, 9401, "Base.CarNormal", 1, 1), { oid = r3t.oid, epoch = r3t.epoch }))
check(rY.recordState == "ORPHANED" and vLand == "AUTHORIZED" and got == r3t and r3t.sqlIdHint == 402 and r3t.removedAtMs == nil,
    "卸下的車拿到回收號：舊紀錄照常 ORPHANED，車上見證的移出紀錄照樣接回")
l1 = mark()
intent(OW, "ISRemoveBurntVehicle", back)
ISRemoveBurntVehicle.complete(A("ISRemoveBurntVehicle", { character = OW, vehicle = back }))
check(back.removed and r.recordState == "DESTROYED" and not logged(l1, "REATTACHED") and not O.hasOutOfWorld(),
    "燒毀車拆解移除：照樣 DESTROYED，不會被當成拖車接回")
local rdisk, rg = GOS.snapshot(), deepcopy(gmd)
rdisk.ledgerRevision = rdisk.ledgerRevision - 3
boot(rdisk, true); gmd = rg
local car2b = vehicle(6, 201, 6001, "Base.CarNormal", 1, 1)
G.watchdog()
car2b:permanentlyRemove()
check(O.R.status == "RECOVERY_REQUIRED" and car2b.removed and rec(rIn.oid).removedAtMs == nil, "帳本 RECOVERY_REQUIRED：照原版移除、不改紀錄")
boot()
local origHook = O.onPermanentlyRemove
O.onPermanentlyRemove = function() error("boom") end
local ev = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
local okCall = pcall(function() ev:permanentlyRemove() end)
local nHook = 0
O.onPermanentlyRemove = function() nHook = nHook + 1 end
BaseVehicle, __classmetatables = { class = "BaseVehicleClass" }, { BaseVehicleClass = { __index = VEHICLE_METHODS } }
O.installRemoveHook()
BaseVehicle, __classmetatables = nil, nil
vehicle(2, 102, 5002, "Base.CarNormal", 1, 1):permanentlyRemove()
O.onPermanentlyRemove = origHook
check(okCall and ev.removed, "移除 hook 出錯：原函式照常執行")
check(nHook == 1, "Lua 重載後再裝一次 hook：不疊包")

out("情境 T3：Autotsar 拖吊（ATAISLoadVehicle／ATAISLaunchVehicle）")
vclass("ATAISLoadVehicle", { "complete" })
vclass("ATAISLaunchVehicle", { "complete" })
G.install("T3")
boot()
local AO, AS, AM = player("aow", 1, 1), player("astr", 1, 1), player("amem", 1, 1)
local acar, atr = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1), vehicle(2, 102, 5002, "Base.TrailerWrecker", 1, 1)
local stTr, loose = vehicle(3, 103, 5003, "Base.TrailerWrecker", 1, 1), vehicle(4, 104, 5004, "Base.CarNormal", 1, 1)
local rc, rt = rec(claim(AO, acar).oid), rec(claim(AO, atr).oid)
local function loadA(p, trailer, v) return A("ATAISLoadVehicle", { character = p, trailer = trailer, vehicle = v }) end
-- 卸車格（a.square）：Autotsar 卸車 adapter 受保護時要在拖車附近
function GOS.square(x, y) return { getX = function() return x end, getY = function() return y end, getZ = function() return 0 end } end
local function launchA(p, trailer) return A("ATAISLaunchVehicle", { character = p, trailer = trailer, square = GOS.square(2, 1) }) end
check(stage(loadA(AS, stTr, loose), "complete") == true and calls("ATAISLoadVehicle.complete") == 1, "車與拖車都沒綁定：照原版，不要求 intent")
check(stage(loadA(AS, stTr, acar), "complete") == false and lastEnforcement(AS).reason == "NOT_AUTHORIZED",
    "陌生人把受保護的車裝上自己的拖車 → 拒")
check(stage(loadA(AS, atr, loose), "complete") == false and calls("ATAISLoadVehicle.complete") == 1, "陌生人用別人受保護的拖車裝車 → 拒")
check(stage(launchA(AS, atr), "complete") == false and calls("ATAISLaunchVehicle.complete") == 0, "陌生人從受保護的拖車卸車 → 拒")
intent(AO, "ATAISLoadVehicle", acar)
l0 = mark()
local la = loadA(AO, atr, acar)
check(stage(la, "complete") == false and la._mvmReason == "ACTOR_MISMATCH" and logged(l0, "ACTOR_MISMATCH"),
    "車主只替被裝的車送 intent、沒替拖車送 → ACTOR_MISMATCH")
intent(AO, "ATAISLoadVehicle", acar); intent(AO, "ATAISLoadVehicle", atr)
la = loadA(AO, atr, acar)
check(stage(la, "complete") == true and la._mvmReason ~= "TARGET_MISMATCH" and calls("ATAISLoadVehicle.complete") == 2,
    "車與拖車都有 intent：車主裝自己的車（主目標是被裝的車，不會 TARGET_MISMATCH）")
check(stage(loadA(AO, atr, acar), "complete") == false, "intent 已消費：同一動作再來一次（冒充）被拒")
intent(AO, "ATAISLoadVehicle", atr)
check(stage(loadA(AO, atr, loose), "complete") == true, "車主把未綁定的車裝上自己的拖車：只要拖車的 intent")
cmd(AO, "addMember", { expectedOid = rc.oid, username = "amem", actionBits = MVM.ACTIONS.TOW })
cmd(AO, "addMember", { expectedOid = rt.oid, username = "amem", actionBits = MVM.ACTIONS.DRIVE })
claim(AM, stTr) -- 綁定的車只能裝上已綁定的拖車（CARRIER_UNBOUND）：成員先綁定自己的拖車
intent(AM, "ATAISLoadVehicle", acar); intent(AM, "ATAISLoadVehicle", stTr)
check(stage(loadA(AM, stTr, acar), "complete") == true, "有 TOW 的成員：可把車裝上自己已綁定的拖車")
intent(AM, "ATAISLaunchVehicle", atr)
check(stage(launchA(AM, atr), "complete") == false, "拖車成員沒有 TOW：不能卸車")
intent(AO, "ATAISLaunchVehicle", atr)
check(stage(launchA(AO, atr), "complete") == true and calls("ATAISLaunchVehicle.complete") == 1, "車主有 intent：卸車")

out("情境 T4：MSW 相容車身鍵（SDVCOwner／SDVCAllowedEnter）")
boot()
local CT = MVM.ClaimTags
activeMods.rSemiTruck = true
local CO = player("cow", 1, 1)
for _, n in ipairs({ "cbob", "ccar", "cdan", "p,q", "cfm" }) do player(n, 1, 1) end
local function md(v, k) return v.bodyMd and rawget(v.bodyMd, k) end
local tcar = vehicle(1, 101, 5001, "Base.CarNormal", 1, 1)
local b0 = tx.body or 0
local rT = rec(claim(CO, tcar).oid)
check(md(tcar, "SDVCOwner") == "cow" and md(tcar, "SDVCAllowedEnter") == nil and md(tcar, CT.MARK) == true and tx.body == b0 + 1,
    "綁定：寫車主與標記鍵並 transmitModData")
cmd(CO, "addMember", { expectedOid = rT.oid, username = "ccar", actionBits = MVM.ACTIONS.TOW + MVM.ACTIONS.DRIVE })
cmd(CO, "addMember", { expectedOid = rT.oid, username = "cbob", actionBits = MVM.ACTIONS.TOW })
cmd(CO, "addMember", { expectedOid = rT.oid, username = "cdan", actionBits = MVM.ACTIONS.DRIVE })
cmd(CO, "addMember", { expectedOid = rT.oid, username = "p,q", actionBits = MVM.ACTIONS.TOW })
check(md(tcar, "SDVCAllowedEnter") == "cbob,ccar", "分享變更當下同步：只列有 TOW 的成員、依帳號排序，含逗號的名字不寫")
newFaction("Crows", "cow", { "cfm" })
cmd(CO, "setFactionShare", { expectedOid = rT.oid, expectedEpoch = rT.epoch, enabled = true, actionBits = MVM.ACTIONS.TOW })
check(md(tcar, "SDVCAllowedEnter") == "cbob,ccar,cfm", "陣營共享有 TOW：陣營成員也列入")
local b1 = tx.body
O.observeVehicle(tcar)
check(tx.body == b1, "內容相同：觀測時不重寫")
rawset(tcar.bodyMd, "SDVCOwner", "cdan"); rawset(tcar.bodyMd, "SDVCAllowedEnter", "cdan")
O.observeVehicle(tcar)
check(md(tcar, "SDVCOwner") == "cow" and md(tcar, "SDVCAllowedEnter") == "cbob,ccar,cfm" and tx.body == b1 + 1, "玩家端竄改：下次觀測修回")
O.setState(rT, "QUARANTINED", "TEST")
check(md(tcar, "SDVCOwner") == CT.LOCKED .. rT.oid and md(tcar, "SDVCAllowedEnter") == nil, "QUARANTINED：車主寫成鎖定值、名單清空")
O.setState(rT, "ACTIVE", "TEST")
check(md(tcar, "SDVCOwner") == "cow" and md(tcar, "SDVCAllowedEnter") == "cbob,ccar,cfm", "離開 QUARANTINED：恢復")
local unsafe = true
for _, n in ipairs({ "", "false", "a,b", "a@b", "a;b", " a", "a ", CT.LOCKED .. rT.oid }) do if CT.safe(n) then unsafe = false end end
check(unsafe and CT.safe("alice") and CT.safe("Mr Smith"), "名字檢查：空字串、false、逗號、@、;、頭尾空白都不收")
local odd = vehicle(2, 102, 5002, "Base.CarNormal", 1, 1)
local rOdd = O.createRecord("cbob,cow", odd, odd.parts.Engine) -- MVCK 匯入的車主名沒經過帳號規則
check(md(odd, "SDVCOwner") == CT.LOCKED .. rOdd.oid and md(odd, "SDVCAllowedEnter") == nil, "車主名不能寫進 MSW：整台寫成鎖定值")
tcar.bodyMd.owner, tcar.bodyMd.WG_Claim_Owner = "x", "y"
check(cmd(CO, "unclaim", { vehicleId = 1, expectedOid = rT.oid, expectedEpoch = rT.epoch }).ok and md(tcar, "SDVCOwner") == nil
    and md(tcar, "SDVCAllowedEnter") == nil and md(tcar, CT.MARK) == nil and md(tcar, "owner") == "x" and md(tcar, "WG_Claim_Owner") == "y",
    "解除綁定：只清本 MOD 寫的鍵，別的 MOD 的鍵不動")
local foreign = vehicle(3, 103, 5003, "Base.CarNormal", 1, 1)
foreign:getModData().SDVCOwner = "someone"
O.observeVehicle(foreign)
check(md(foreign, "SDVCOwner") == "someone", "沒有本 MOD 標記的 SDVCOwner（別的 MOD 寫的）不動")
local stray = carry(vehicle(4, 104, 5004, "Base.CarNormal", 1, 1), { oid = "uuid-gone", epoch = "e" })
stray:getModData().SDVCOwner, stray:getModData()[CT.MARK] = "cow", true
O.observeVehicle(stray)
check(witness(stray) == nil and md(stray, "SDVCOwner") == nil and md(stray, CT.MARK) == nil, "孤兒見證被剝除時，本 MOD 的鍵一起清")
local mcar = vehicle(5, 105, 5005, "Base.CarNormal", 1, 1)
local rM = rec(claim(CO, mcar).oid)
mcar:permanentlyRemove()
local mback = carry(vehicle(6, 555, 5005, "Base.CarNormal", 1, 1), { oid = rM.oid, epoch = rM.epoch })
O.observeVehicle(mback)
check(rM.sqlIdHint == 555 and md(mback, "SDVCOwner") == "cow" and md(mback, CT.MARK) == true, "接回的車寫上車主")
activeMods.rSemiTruck = nil
local plain = vehicle(7, 107, 5007, "Base.CarNormal", 1, 1)
claim(CO, plain)
check(not CT.enabled() and plain.bodyMd == nil, "MSW 沒啟用：不寫車身鍵")
activeMods.rSemiTruck, serverMode = true, false
check(not CT.enabled(), "單人（非伺服器）：不寫車身鍵")
activeMods.rSemiTruck, serverMode = nil, true

out("情境 T5：客戶端 MSW 裝卸防護與拖吊 also intent")
local savedIsClient = isClient
isClient = function() return true end
online = {}
local me = player("kow", 1, 1)
function me:getRole() return nil end
local queued = 0
ISTimedActionQueue = { add = function() queued = queued + 1 end, addAfter = function() end }
for _, n in ipairs({ "ISEnterVehicle", "ISSwitchVehicleSeat", "ISAttachTrailerToVehicle", "ISDetachTrailerFromVehicle" }) do
    _G[n] = { isValid = function() return true end }
end
MSW_ISLoadVehicle, MSW_ISLaunchVehicle = nil, nil
handlers.OnGameStart = handlers.OnGameStart or {}
local nStart = #handlers.OnGameStart
assert(loadfile(MEDIA .. "/client/MinidoracatVehicleManager_ClientGuards.lua"))()
-- MSW 的類別在本 MOD 之後才載入：進遊戲時補包
MSW_ISLoadVehicle = { isValid = function() return true end }
MSW_ISLaunchVehicle = { isValid = function() return true end }
for i = nStart + 1, #handlers.OnGameStart do handlers.OnGameStart[i]() end
local myCar = carry(vehicle(61, 901, 9901, "Base.CarNormal", 1, 1), { oid = "kMyCar" })
local myTr = carry(vehicle(62, 902, 9902, "Base.Trailer", 1, 1), { oid = "kMyTr" })
local theirCar = carry(vehicle(63, 903, 9903, "Base.CarNormal", 1, 1), { oid = "kTheirCar" })
local theirTr = carry(vehicle(64, 904, 9904, "Base.Trailer", 1, 1), { oid = "kTheirTr" })
local looseC = vehicle(65, 905, 9905, "Base.CarNormal", 1, 1)
MVM.clientReceive("fleetSnapshot", { to = "kow", streamId = "kt", seq = 0, rows = {
    { oid = "kMyCar", role = "OWNER", state = "ACTIVE" }, { oid = "kMyTr", role = "OWNER", state = "ACTIVE" } } })
local function mswLoad(tr, v) return setmetatable({ character = me, trailer = tr, vehicle = v }, { __index = MSW_ISLoadVehicle }):isValid() end
local function mswLaunch(tr) return setmetatable({ character = me, trailer = tr }, { __index = MSW_ISLaunchVehicle }):isValid() end
check(mswLoad(myTr, myCar) and mswLoad(myTr, looseC) and mswLaunch(myTr), "MSW：自己的車裝上自己的拖車、自己的拖車卸車都放行")
check(not mswLoad(myTr, theirCar), "MSW：別人受保護的車不能裝上拖車")
check(not mswLoad(theirTr, myCar) and not mswLoad(theirTr, looseC), "MSW：別人受保護的拖車不能拿來裝車（進遊戲時補包的類別）")
check(not mswLaunch(theirTr), "MSW：不能從別人受保護的拖車卸車")
local told, realNotify = nil, MVM.notify
MVM.notify = function(_, text) told = text end
local looseTr = vehicle(66, 906, 9906, "Base.SemiTrailerCartrailer", 1, 1)
check(not mswLoad(looseTr, myCar) and told == "IGUI_MVM_Reason_CARRIER_UNBOUND",
    "MSW：自己綁定的車不能裝上沒綁定的拖車，提示「已綁定的車只能裝上已綁定的拖車」")
told = nil
check(mswLoad(looseTr, looseC) and told == nil, "MSW：沒綁定的車裝上沒綁定的拖車照常")
check(not mswLoad(looseTr, theirCar) and told == "IGUI_MVM_Protected", "MSW：別人的車裝上沒綁定的拖車：仍是「受保護」提示")
MVM.clientHandlers.enforcement({ to = "kow", action = "CMD:msw.loadVehicle", reason = "CARRIER_UNBOUND" })
local unboundText = told
MVM.clientHandlers.enforcement({ to = "kow", action = "CMD:msw.loadVehicle", reason = "TOO_FAR" })
check(unboundText == "IGUI_MVM_Reason_CARRIER_UNBOUND" and told == "IGUI_MVM_Refused",
    "伺服器拒絕 CARRIER_UNBOUND：顯示請先綁定拖車；其他原因照舊")
MVM.notify = realNotify
local function withParts(id, parts) return vehicle(id, 900 + id, 9900 + id, "Base.X", 1, 1, parts) end
check(MVM.isCarrier(withParts(67, { "Engine", "ATAMultiSlotWrecker" })) and MVM.isCarrier(withParts(68, { "ATAVehicleWrecker" }))
    and MVM.isCarrier(withParts(69, { "ATA2VehicleWrecker" })) and not MVM.isCarrier(looseC) and not MVM.isCarrier(nil),
    "MVM.isCarrier：MSW 多槽拖車、兩種 Autotsar 拖吊零件為真；一般車、nil 為假")
check(MVM.claimText(0, looseC) == "IGUI_MVM_ClaimDisclosure\nIGUI_MVM_ClaimRisk_2", "綁定確認視窗：還沒收到名額就不加名額行；一般車不加載具行")
MVM.clientReceive("fleetSnapshot", { to = "kow", streamId = "kt2", seq = 0, quotaUsed = 2, quotaLimit = 3, rows = {
    { oid = "kMyCar", role = "OWNER", state = "ACTIVE" }, { oid = "kMyTr", role = "OWNER", state = "ACTIVE" } } })
check(MVM.claimText(0, withParts(70, { "ATAMultiSlotWrecker" }))
    == "IGUI_MVM_ClaimDisclosure\nIGUI_MVM_ClaimRisk_2\nIGUI_MVM_ClaimQuotaNote(2,3)\nIGUI_MVM_ClaimCarrierNote", "綁定確認視窗：名額行（已用／上限）＋能裝車的載具多一行")
MVM.clientReceive("fleetDelta", { to = "kow", streamId = "kt2", seq = 1, upserts = {}, removes = {}, quotaUsed = 3 })
check(MVM.claimText(0, looseC) == "IGUI_MVM_ClaimDisclosure\nIGUI_MVM_ClaimRisk_2\nIGUI_MVM_ClaimQuotaNote(3,3)", "增量帶目前已用名額：綁定後名額行立即更新，不等下一次快照")
MVM.clientReceive("fleetSnapshot", { to = "kow", streamId = "kt3", seq = 0, quotaUsed = 2, quotaLimit = 3,
    quota = { used = 4, total = 5, base = 3, paid = 2 }, rows = {
    { oid = "kMyCar", role = "OWNER", state = "ACTIVE" }, { oid = "kMyTr", role = "OWNER", state = "ACTIVE" } } })
check(MVM.claimText(0, looseC) == "IGUI_MVM_ClaimDisclosure\nIGUI_MVM_ClaimRisk_2\nIGUI_MVM_ClaimQuotaNote(4,5)", "有付費名額時用 Economy 的已用／總計")
MVM.clientReceive("fleetDelta", { to = "kow", streamId = "kt3", seq = 1, upserts = {}, removes = {}, quotaUsed = 5 })
check(MVM.claimText(0, looseC) == "IGUI_MVM_ClaimDisclosure\nIGUI_MVM_ClaimRisk_2\nIGUI_MVM_ClaimQuotaNote(5,5)", "增量的已用名額也更新付費名額分項的已用")
clientSent = {}
ISTimedActionQueue.add(A("ATAISLoadVehicle", { character = me, trailer = myTr, vehicle = theirCar }))
local sentFor = {}
for _, m in ipairs(clientSent) do if m.command == "prepareAction" then sentFor[m.args.vehicleId] = m.args.class end end
check(queued == 1 and sentFor[63] == "ATAISLoadVehicle" and sentFor[64] == nil and sentFor[62] == "ATAISLoadVehicle",
    "拖吊裝車排入佇列：被裝的車與拖車（also）各送一筆 intent")
clientSent = {}
ISTimedActionQueue.add(A("ATAISLoadVehicle", { character = me, trailer = myTr, vehicle = looseC }))
check(#clientSent == 1 and clientSent[1].args.vehicleId == 62, "未綁定的車不送 intent，只送拖車的")
isClient = savedIsClient
ISTimedActionQueue, MSW_ISLoadVehicle, MSW_ISLaunchVehicle = nil, nil, nil
for _, n in ipairs({ "ISEnterVehicle", "ISSwitchVehicleSeat", "ISAttachTrailerToVehicle", "ISDetachTrailerFromVehicle" }) do _G[n] = nil end
end)();

(function() -- 主 chunk 區域變數已滿 200：本情境用自己的函式作用域
out("情境 F1：車輛指令防火牆（每條規則：陌生人擋、車主與有權成員放行、不受保護照常）")
boot()
local CG = MVM.CommandGate
for k in pairs(CG.R.notified) do CG.R.notified[k] = nil end
for k in pairs(O.R.keyIdPending) do O.R.keyIdPending[k] = nil end
local function logged(text, from)
    for i = from or 1, #logLines do if logLines[i]:find(text, 1, true) then return true end end
    return false
end
local function denied(label, reason)
    for key in pairs(O.R.denyAgg) do
        if key:find(label, 1, true) and (reason == nil or key:find(reason, 1, true)) then return true end
    end
    return false
end
-- 第三方處理器的替身（在防火牆之後註冊，同一個 args）：回報它會不會動到車，以及它會不會因欄位被清空而報錯
-- （原版、damnlib、rLib 不檢查欄位就 getVehicleById／assert，Java 收到 nil 會拋錯）
local ID_FIELDS = { "vehicle", "vehicleA", "vehicleB", "trailer", "container", "vehicleId", "_vehicleId" }
local function strictFields(m, c)
    if m == "vehicle" then return c == "attachTrailer" and { vehicleA = "number", vehicleB = "number" } or { vehicle = "number" } end
    if m == "rLib" then return c == "SetVehicleBattery" and { vehicleId = "number", battery = "number" } or { vehicleId = "number", set = "boolean" } end
    if m == "that_damn_lib" and c == "setPartModData" then return { vehicle = "number" } end
    return {}
end
local last = nil
local MODS = { vehicle = true, commonlib = true, atatuning2 = true, msw = true, W900 = true, rLib = true, that_damn_lib = true }
local function third(m, c, _, args)
    if not MODS[m] then return end -- 不看 CG.RULES：拿掉規則的突變也要測得出來
    last = { hit = nil, err = false }
    for f, ty in pairs(strictFields(m, c)) do if type(args[f]) ~= ty then last.err = true end end
    for _, f in ipairs(ID_FIELDS) do
        local id = args[f] -- Java 的 getVehicleById(int) 把小數截斷（KahluaNumberConverter.java:28-31）
        local n = type(id) == "number" and id == id and (id >= 0 and math.floor(id) or math.ceil(id)) or nil
        if n ~= nil and world[n] ~= nil then last.hit = world[n] end
    end
end
Events.OnClientCommand.Add(third)
local function send(p, m, c, args)
    nowMs = nowMs + 300
    last = nil
    fire("OnClientCommand", m, c, p, args)
    return last or { hit = nil, err = false }
end

local OW, ST, MB = player("fow", 1, 1), player("fstr", 1, 1), player("fmem", 1, 1)
local PARTS = { "Engine", "Battery", "DoorFrontLeft", "EngineDoor", "TrunkDoor", "TireFrontLeft" }
local ARMOR = { Engine = { logic = "rLib", condition = "80" }, Battery = { logic = "custom", condition = "80" } } -- part:getTable("armor")
local function tvehicle(id, sqlId)
    local v = vehicle(id, sqlId, 7000 + id, "Base.CarNormal", 1, 1, PARTS)
    for _, pt in pairs(v.parts) do
        function pt:getWheelIndex() return self.id == "TireFrontLeft" and 0 or -1 end
        function pt:getTable(k) return k == "armor" and ARMOR[self.id] or nil end
    end
    function v.parts.TireFrontLeft:getContainerContentAmount() return 30 end
    function v.parts.TireFrontLeft:getContainerCapacity() return 40 end
    return v
end
local pv, uv, ut = tvehicle(21, 201), tvehicle(31, 301), tvehicle(32, 302)
local dv, ud = tvehicle(41, 401), tvehicle(42, 402)
pv.towing, dv.towedBy, uv.towing, ud.towedBy = dv, pv, ud, uv -- detach 以被拖的車送：拖著它的受保護車也要 TOW
local rp = rec(claim(OW, pv).oid)
-- 受保護的車只能裝上已綁定的拖車（CARRIER_UNBOUND，F7 另測）：整車裝車情境的拖車用車主綁定、成員有 TOW 的 bt
local bt = tvehicle(33, 303)
rec(claim(OW, bt).oid).grants = { { user = "fmem", bits = MVM.ACTIONS.TOW } }
local function carrierFor(V, O2) return V == pv and bt or O2 end
local function args1(extra) return function(V) local t = { vehicle = V.id }; for k, x in pairs(extra) do t[k] = x end; return t end end
local CASES = {
    { "vehicle", "fixPart", args1({ part = "Engine", condition = 100 }), { "REPAIR" } },
    { "vehicle", "setContainerContentAmount", args1({ part = "Engine", amount = 0 }), { "FUEL" } },
    { "vehicle", "setContainerContentAmount", args1({ part = "TireFrontLeft", amount = 0 }), { "SALVAGE" } },
    { "vehicle", "setContainerContentAmount", args1({ part = "TireFrontLeft", amount = 35 }), { "REPAIR" } },
    { "vehicle", "setTirePressure", args1({ part = "TireFrontLeft", psi = 0 }), { "SALVAGE" } },
    { "vehicle", "setTirePressure", args1({ part = "TireFrontLeft", psi = 35 }), { "REPAIR" } },
    { "vehicle", "setTirePressure", args1({ part = "TireFrontLeft", psi = 99 }), { "SALVAGE" } }, -- 超過容量當作破壞
    { "vehicle", "setDoorOpen", args1({ part = "DoorFrontLeft", open = true }), { "PASSENGER" } },
    { "vehicle", "setDoorOpen", args1({ part = "EngineDoor", open = true }), { "REPAIR", "SALVAGE" } },
    { "vehicle", "setDoorOpen", args1({ part = "TrunkDoor", open = true }), { "CARGO" } },
    { "vehicle", "damageWindow", args1({ part = "DoorFrontLeft", amount = 100 }), { "SALVAGE" } },
    { "vehicle", "putKeyOnDoor", args1({}), { "PASSENGER" } },
    { "vehicle", "removeKeyFromDoor", args1({}), { "PASSENGER" } },
    { "vehicle", "attachTrailer", function(V, O2) return { vehicleA = O2.id, vehicleB = V.id } end, { "TOW" } },
    { "vehicle", "detachTrailer", function(V) return { vehicle = V.towing.id } end, { "TOW" } },
    { "vehicle", "detachTrailerSpontaneous", function(V) return { vehicle = V.towing.id } end, { "TOW" } },
    { "vehicle", "setHSV", args1({ h = 0, s = 0, v = 0 }), { "REPAIR" } },
    { "vehicle", "setSkinIndex", args1({ index = 2 }), { "REPAIR" } },
    { "vehicle", "setBloodIntensity", args1({ id = 0, intensity = 1 }), { "REPAIR" } },
    { "vehicle", "remove", args1({}), { "MANAGE" } },
    { "commonlib", "loadVehicle", function(V, O2) return { trailer = carrierFor(V, O2).id, vehicle = V.id } end, { "TOW" } },
    { "commonlib", "launchVehicle", function(V) return { trailer = V.id, x = V.x + 3, y = V.y } end, { "TOW" } },
    { "commonlib", "installTuning", args1({ part = "Engine", model = "m" }), { "REPAIR" } },
    { "commonlib", "uninstallTuning", args1({ part = "Engine" }), { "SALVAGE" } },
    { "commonlib", "bulbSmash", args1({}), { "SALVAGE" } },
    { "commonlib", "cabinlightsOn", args1({}), { "PASSENGER" } },
    { "commonlib", "usePortableMicrowave", args1({ oven = "Engine", on = true, timer = 5 }), { "CARGO" } },
    { "atatuning2", "installTuning", args1({ partName = "Engine", modelName = "m" }), { "REPAIR" } },
    { "atatuning2", "uninstallTuning", args1({ partName = "Engine" }), { "SALVAGE" } },
    { "atatuning2", "usePart", args1({ partName = "Engine" }), { "PASSENGER" } },
    { "msw", "loadVehicle", function(V, O2) return { trailer = carrierFor(V, O2).id, vehicle = V.id, slot = 1 } end, { "TOW" } },
    { "msw", "loadContainer", function(V, O2) return { trailer = O2.id, container = V.id } end, { "TOW" } },
    { "msw", "launchVehicle", function(V) return { trailer = V.id, slot = 1, x = V.x + 3, y = V.y } end, { "TOW" } },
    { "msw", "unloadContainer", function(V) return { trailer = V.id, x = V.x, y = V.y } end, { "TOW" } },
    { "W900", "applyArmorRepair", args1({ part = "Engine", condition = 100 }), { "REPAIR" } },
    { "W900", "setTrailerPhysicsDisabled", args1({ disabled = true }), { "TOW" } },
    { "W900", "toggleFreezer", args1({ part = "Engine", active = true }), { "CARGO" } },
    { "W900", "toggleFridge", args1({ part = "Engine", active = true }), { "CARGO" } },
    { "W900", "moveVehicleImpulse", args1({}), { "DRIVE", "TOW" } },
    { "rLib", "SetVehicleBattery", function(V) return { vehicleId = V.id, battery = 0 } end, { "TOW" } },
    { "rLib", "SetVehicleHeadlights", function(V) return { vehicleId = V.id, set = true } end, { "TOW" } },
    { "that_damn_lib", "silentPartInstall", function(V) return { _vehicleId = V.id, part = "Engine", item = "Base.X" } end, { "REPAIR" } },
    { "that_damn_lib", "updatePartConditions", function(V) return { _vehicleId = V.id, conditions = { Engine = 100 } } end, { "REPAIR" } },
    { "that_damn_lib", "savePartsCondition", function(V) return { _vehicleId = V.id } end, { "REPAIR" } },
}
local covered = { ["that_damn_lib.setPartModData"] = true } -- 一律拒絕，F2 另測
for _, k in ipairs(CASES) do covered[k[1] .. "." .. k[2]] = true end
local missing = {}
for m, cmds in pairs(CG.RULES) do for c in pairs(cmds) do if not covered[m .. "." .. c] then missing[#missing + 1] = m .. "." .. c end end end
check(#missing == 0, "規則表每一條都有情境（缺：" .. table.concat(missing, ",") .. "）")
local function grant(bits) rp.grants = { { user = "fmem", bits = bits } } end
local function bitsOf(names)
    local n = 0
    for _, a in ipairs(names) do n = n + MVM.ACTIONS[a] end
    return n
end
for _, k in ipairs(CASES) do
    local m, c, mk, need = k[1], k[2], k[3], k[4]
    local label = "CMD:" .. m .. "." .. c
    for key in pairs(O.R.denyAgg) do O.R.denyAgg[key] = nil end
    rp.grants = {}
    local s = send(ST, m, c, mk(pv, ut))
    local okStranger = s.hit == nil and not s.err and denied(label, "NOT_AUTHORIZED")
    local okOwner = send(OW, m, c, mk(pv, ut)).hit ~= nil
    local okMember = true
    if need[1] ~= "MANAGE" then
        grant(bitsOf({ need[1] }))
        okMember = send(MB, m, c, mk(pv, ut)).hit ~= nil
        local others = MVM.SHAREABLE_MASK - bitsOf(need)
        for _, a in ipairs(need) do if a == "PASSENGER" then others = others - MVM.ACTIONS.DRIVE end end -- DRIVE 含 PASSENGER
        grant(others)
        local mn = send(MB, m, c, mk(pv, ut))
        okMember = okMember and mn.hit == nil and not mn.err
    end
    rp.grants = {}
    local okLoose = send(ST, m, c, mk(uv, ut)).hit ~= nil
    check(okStranger and okOwner and okMember and okLoose, label .. " " .. table.concat(need, "/")
        .. "：陌生人被擋（處理器看不到車、不報錯、DENY）、車主與只有該權限的成員放行、缺該權限擋、不受保護照常")
end
grant(MVM.ACTIONS.TOW)
local towImpulse = send(MB, "W900", "moveVehicleImpulse", { vehicle = pv.id }).hit ~= nil
rp.grants = {}
check(towImpulse, "W900.moveVehicleImpulse：只有 TOW 的成員也放行（DRIVE 或 TOW 任一）")

out("情境 F2：距離、解析不到、壞 id、出錯、見證鍵、通知、未載入")
for key in pairs(O.R.denyAgg) do O.R.denyAgg[key] = nil end
OW.x = 40
local far = send(OW, "vehicle", "fixPart", { vehicle = pv.id, part = "Engine", condition = 100 })
check(far.hit == nil and not far.err and denied("CMD:vehicle.fixPart", "TOO_FAR"), "車主在 10 格外：受保護的車拒絕（TOO_FAR）")
check(send(OW, "vehicle", "fixPart", { vehicle = uv.id, part = "Engine" }).hit == uv, "10 格外對不受保護的車：照常")
OW.x, OW.z = 1, 1
check(send(OW, "W900", "toggleFreezer", { vehicle = pv.id, part = "Engine", active = true }).hit == nil, "車主在不同樓層：拒絕")
OW.z = 0
for key in pairs(O.R.denyAgg) do O.R.denyAgg[key] = nil end
local okNone = pcall(function()
    send(ST, "vehicle", "fixPart", { vehicle = 999, part = "Engine" })
    send(ST, "commonlib", "loadVehicle", {})
    send(ST, "msw", "launchVehicle", { trailer = 999 })
    send(ST, "vehicle", "attachTrailer", { vehicleA = 999 })
end)
check(okNone and not denied("CMD:"), "解析不到的車與缺欄位：不出錯、不拒絕（處理器自己會略過）")
world[1] = uv
local frac = send(OW, "vehicle", "fixPart", { vehicle = 21.5, part = "Engine" })
local str = send(OW, "W900", "applyArmorRepair", { vehicle = "21", part = "Engine", condition = 100 })
check(frac.hit == nil and not frac.err and str.hit == nil and denied("CMD:vehicle.fixPart", "BAD_ID") and denied("CMD:W900.applyArmorRepair", "BAD_ID"),
    "id 不是整數（Java 會截斷成別台車）：連車主也拒絕（BAD_ID）")
world[1] = nil
local saved, prints, rp0 = CG.RULES.W900.toggleFreezer, 0, print
CG.RULES.W900.toggleFreezer = function() error("boom") end
print = function() prints = prints + 1 end
local e1 = send(OW, "W900", "toggleFreezer", { vehicle = uv.id, part = "Engine", active = true })
local e2 = send(OW, "W900", "toggleFreezer", { vehicle = uv.id, part = "Engine", active = true })
print, CG.RULES.W900.toggleFreezer = rp0, saved
check(e1.hit == nil and e2.hit == nil and denied("CMD:W900.toggleFreezer", "GATE_ERROR") and prints == 1,
    "規則出錯：視同拒絕（連不受保護的車也擋），同一種錯誤只記一次 log")
local wk = send(OW, "that_damn_lib", "setPartModData", { _vehicleId = uv.id, part = "Engine", data = { x = 1 } })
local wk2 = send(OW, "that_damn_lib", "setPartModData", { vehicle = pv.id, part = "Engine", data = { MinidoracatVehicleManager = { oid = rp.oid } } })
check(wk.hit == nil and not wk.err and wk2.hit == nil and not wk2.err and denied("CMD:that_damn_lib.setPartModData", "REFUSED")
    and witness(pv).oid == rp.oid, "damnlib setPartModData（改零件 modData，沒有正常呼叫者）：不論車是否受保護、連車主都拒絕")
local nt = send(OW, "vehicle", "setTirePressure", { vehicle = uv.id, part = "Engine", psi = 0 })
check(nt.hit == nil and denied("CMD:vehicle.setTirePressure", "NOT_TIRE"), "setTirePressure 指到非輪胎零件（油箱等）：一律拒絕")
outbox[ST.name] = {}
for k in pairs(CG.R.notified) do CG.R.notified[k] = nil end
send(ST, "vehicle", "fixPart", { vehicle = pv.id, part = "Engine" })
send(ST, "vehicle", "damageWindow", { vehicle = pv.id, part = "DoorFrontLeft" })
local n1 = 0
for _, msg in ipairs(outbox[ST.name]) do if msg.command == "enforcement" then n1 = n1 + 1 end end
nowMs = nowMs + 2100
send(ST, "vehicle", "fixPart", { vehicle = pv.id, part = "Engine" })
local n2 = 0
for _, msg in ipairs(outbox[ST.name]) do if msg.command == "enforcement" then n2 = n2 + 1 end end
check(n1 == 1 and n2 == 2 and lastOf(ST, "enforcement").action == "CMD:vehicle.fixPart" and lastOf(ST, "enforcement").reason == "NOT_AUTHORIZED",
    "拒絕時通知送指令的人（同一人 2 秒內最多一次）")
local launchFar = send(OW, "commonlib", "launchVehicle", { trailer = pv.id, x = pv.x + 40, y = pv.y })
local launchBad = send(OW, "commonlib", "launchVehicle", { trailer = pv.id, x = 0 / 0, y = pv.y })
local launchStr = send(OW, "commonlib", "launchVehicle", { trailer = pv.id, x = "1", y = pv.y })
check(launchFar.hit == nil and launchBad.hit == nil and launchStr.hit == nil and denied("CMD:commonlib.launchVehicle", "BAD_POS")
    and send(ST, "commonlib", "launchVehicle", { trailer = uv.id, x = uv.x + 40, y = uv.y }).hit == uv,
    "Autotsar 卸車座標：受保護時要在拖車 15 格內（NaN、字串也擋）；不受保護照常")
MB.vehicle = pv
grant(MVM.ACTIONS.PASSENGER)
local seatedBulb = send(MB, "commonlib", "bulbSmash", { vehicle = pv.id }).hit ~= nil
local seatedArmor = send(MB, "that_damn_lib", "updatePartConditions", { _vehicleId = pv.id, conditions = { Engine = 1 } }).hit
MB.vehicle = nil
local outsideBulb = send(MB, "commonlib", "bulbSmash", { vehicle = pv.id }).hit
check(seatedBulb and outsideBulb == nil and seatedArmor == nil,
    "坐在車上的 PASSENGER 成員：車內燈放行、不在車上要 SALVAGE；零件耐久（KI5 裝甲同步）一律要 REPAIR")
grant(MVM.ACTIONS.DRIVE)
pv.seats[0] = MB
local ctis = send(MB, "vehicle", "setContainerContentAmount", { vehicle = pv.id, part = "TireFrontLeft", amount = 35 }).hit ~= nil
local ctisOver = send(MB, "vehicle", "setContainerContentAmount", { vehicle = pv.id, part = "TireFrontLeft", amount = 99 }).hit
local ctisFuel = send(MB, "vehicle", "setContainerContentAmount", { vehicle = pv.id, part = "Engine", amount = 0 }).hit
local armor = send(MB, "W900", "applyArmorRepair", { vehicle = pv.id, part = "Engine", condition = 80 }).hit ~= nil
local armorAny = send(MB, "W900", "applyArmorRepair", { vehicle = pv.id, part = "Engine", condition = 100 }).hit
local armorLogic = send(MB, "W900", "applyArmorRepair", { vehicle = pv.id, part = "Battery", condition = 80 }).hit
local armorNone = send(MB, "W900", "applyArmorRepair", { vehicle = pv.id, part = "DoorFrontLeft", condition = 80 }).hit
pv.seats[0], pv.seats[1] = nil, MB
local armorSeat1 = send(MB, "W900", "applyArmorRepair", { vehicle = pv.id, part = "Engine", condition = 80 }).hit
pv.seats[1] = nil
local armorOut = send(MB, "W900", "applyArmorRepair", { vehicle = pv.id, part = "Engine", condition = 80 }).hit
local ctisOut = send(MB, "vehicle", "setContainerContentAmount", { vehicle = pv.id, part = "TireFrontLeft", amount = 35 }).hit
rp.grants = {}
check(ctis and ctisOver == nil and ctisFuel == nil and ctisOut == nil,
    "只有 DRIVE 的駕駛：容量內補胎壓（KI5 CTIS）放行；超過容量、油箱、不在駕駛座都擋")
check(armor and armorAny == nil and armorLogic == nil and armorNone == nil and armorSeat1 == nil and armorOut == nil,
    "只有 DRIVE 的駕駛：W900 裝甲補償只放行 rLib 裝甲零件、耐久等於裝甲表 condition；其他值、其他 logic、沒有裝甲表、非駕駛座、不在車上都要 REPAIR")
local savedOwn = MVM.Own
MVM.Own = nil
prints = 0
print = function() prints = prints + 1 end
local noLedger = send(ST, "vehicle", "fixPart", { vehicle = pv.id, part = "Engine" })
send(ST, "vehicle", "fixPart", { vehicle = pv.id, part = "Engine" })
print, MVM.Own = rp0, savedOwn
check(noLedger.hit == pv and prints == 1, "所有權系統沒載入：不擋全服，只記一次 log")

out("情境 F3：canUse 與 allowsRecord 一致")
local AD = player("fadm", 1, 1, { admin = true })
local FM = player("ffac", 1, 1)
newFaction("FWolves", "fow", { "ffac" })
cmd(OW, "setFactionShare", { expectedOid = rp.oid, expectedEpoch = rp.epoch, enabled = true, actionBits = MVM.ACTIONS.DRIVE })
grant(MVM.ACTIONS.CARGO + MVM.ACTIONS.TOW)
local qv = tvehicle(25, 205)
local rq = rec(claim(OW, qv).oid)
O.setState(rq, "QUARANTINED", "TEST")
local same, total = true, 0
for round = 1, 2 do
    if round == 2 then O.setOverride(AD, true) end
    for _, actor in ipairs({ OW, ST, MB, FM, AD }) do
        for _, act in ipairs(MVM.ACTION_ORDER) do
            for _, pair in ipairs({ { pv, rp }, { qv, rq } }) do
                total = total + 1
                local a1, r1 = O.canUse(actor, pair[1], act)
                local a2, r2 = O.allowsRecord(actor, pair[2], act)
                if a1 ~= a2 or r1 ~= r2 then same = false end
            end
        end
    end
end
O.setOverride(AD, false)
check(same and total == 180, "車主／陌生人／成員／陣營／管理員（越權開關）× 每種動作 × 一般與隔離紀錄：兩者結果與原因相同")
check(not O.allowsRecord(OW, rp, "NOPE") and select(2, O.allowsRecord(OW, rp, "NOPE")) == "UNKNOWN_ACTION", "未知動作碼：拒絕")
Events.OnClientCommand.Remove(third)
end)();

(function() -- 主 chunk 區域變數已滿 200：本情境用自己的函式作用域
out("情境 F4：拖車裝卸（keyId 延續、在哪台車上、卸車要載著的車的權限、TimedAction 回送）")
boot()
local quota0 = SB.ClaimsPerPlayer
SB.ClaimsPerPlayer = 20
for k in pairs(O.R.keyIdPending) do O.R.keyIdPending[k] = nil end
local function logged(text, from)
    for i = from or 1, #logLines do if logLines[i]:find(text, 1, true) then return true end end
    return false
end
local seen = nil
-- tsarslib／MSW 處理器替身：裝車把被裝車的 keyId 寫到拖車（CommonCommands.lua:511,634）並移除，卸車只回報看到的拖車
local function fakeTow(m, c, _, args)
    if m ~= "commonlib" and m ~= "msw" then return end
    if c == "loadVehicle" and args.trailer and args.vehicle then
        local tr, v = world[args.trailer], world[args.vehicle]
        seen = { c = c, tr = tr }
        if tr and v and not v.removed then
            if m == "commonlib" then tr.keyId = v.keyId end
            v:permanentlyRemove()
        end
    elseif c == "launchVehicle" and args.trailer then
        seen = { c = c, tr = world[args.trailer] }
    end
end
Events.OnClientCommand.Add(fakeTow)
local function send(p, m, c, args)
    nowMs = nowMs + 300
    seen = nil
    fire("OnClientCommand", m, c, p, args)
    return seen
end
local OW, ST, MB = player("tow", 1, 1), player("tstr", 1, 1), player("tmem", 1, 1)
local tr = vehicle(51, 501, 7501, "Base.TestWrecker", 1, 1)
local car = vehicle(52, 502, 7502, "Base.CarNormal", 1, 1)
local rTr, rCar = rec(claim(OW, tr).oid), rec(claim(OW, car).oid)
local s1 = send(ST, "commonlib", "loadVehicle", { trailer = tr.id, vehicle = car.id })
check(s1 == nil and not car.removed and O.R.keyIdPending[rTr.oid] == nil and rCar.carrierSqlId == nil,
    "陌生人裝車被擋：不記 keyId 延續、不記在哪台車上")
local l0 = #logLines + 1
send(OW, "commonlib", "loadVehicle", { trailer = tr.id, vehicle = car.id })
check(car.removed and tr.keyId == 7502 and rCar.removedAtMs ~= nil and rCar.carrierSqlId == 501 and O.R.keyIdPending[rTr.oid] ~= nil,
    "車主裝車：被裝的車移出世界並記下拖車 sqlId，拖車記 keyId 延續")
fire("OnTick")
check(rTr.recordState == "ACTIVE" and rTr.keyIdHint == 7502 and logged("KEYID_TOW", l0) and O.R.keyIdPending[rTr.oid] == nil
    and witness(tr).oid == rTr.oid and O.canUse(OW, tr, "DRIVE") and not O.canUse(ST, tr, "DRIVE"),
    "下一個 tick 觀測拖車：keyId 改成被裝車的（KEYID_TOW），仍受保護，不判 SQLID_RECYCLED")
check(send(ST, "commonlib", "launchVehicle", { trailer = tr.id, x = 2, y = 1 }) == nil, "陌生人從受保護的拖車卸車：擋")
rTr.grants = { { user = "tmem", bits = MVM.ACTIONS.TOW } }
check(send(MB, "commonlib", "launchVehicle", { trailer = tr.id, x = 2, y = 1 }) == nil, "成員只有拖車的 TOW、沒有載著的車的 TOW：擋")
rCar.grants = { { user = "tmem", bits = MVM.ACTIONS.TOW } }
check(send(MB, "commonlib", "launchVehicle", { trailer = tr.id, x = 2, y = 1 }) ~= nil, "兩者都有 TOW：放行")
local back = vehicle(53, 503, 7502, "Base.CarNormal", 2, 1)
rawset(back.parts.Engine.md, "MinidoracatVehicleManager", { oid = rCar.oid, epoch = rCar.epoch })
fire("OnSpawnVehicleEnd", back)
fire("OnTick")
check(rCar.removedAtMs == nil and rCar.sqlIdHint == 503 and rCar.carrierSqlId == nil and #O.carriedBy(tr) == 0,
    "卸下的車依見證接回，清掉在哪台車上")
local car2 = vehicle(54, 504, 7504, "Base.CarNormal", 1, 1)
claim(OW, car2)
send(OW, "commonlib", "loadVehicle", { trailer = tr.id, vehicle = car2.id })
nowMs = nowMs + O.KEYID_TOW_MS + 1
fire("OnTick")
check(rTr.recordState == "ORPHANED", "keyId 延續過期才觀測到：照舊判 SQLID_RECYCLED")
local tr3 = vehicle(55, 505, 7505, "Base.TestWrecker", 1, 1)
local car3 = vehicle(56, 506, 7506, "Base.CarNormal", 1, 1)
local rTr3 = rec(claim(OW, tr3).oid)
send(OW, "commonlib", "loadVehicle", { trailer = tr3.id, vehicle = car3.id })
tr3.keyId = 9999
fire("OnTick")
check(rTr3.recordState == "ORPHANED", "拖車 keyId 變成記下以外的值：不認")

out("情境 F5：MSW 公用拖車載著受保護的車")
local mt = vehicle(61, 601, 7601, "Base.SemiTrailerCartrailer", 1, 1)
local car4 = vehicle(62, 602, 7602, "Base.CarNormal", 1, 1)
local rCar4, rMt = rec(claim(OW, car4).oid), rec(claim(OW, mt).oid)
send(OW, "msw", "loadVehicle", { trailer = mt.id, vehicle = car4.id, slot = 1 })
check(car4.removed and rCar4.carrierSqlId == 601 and mt.keyId == 7601, "車主用自己綁定的拖車裝車：記下在哪台車上（MSW 不改拖車 keyId）")
-- 拖車紀錄被擋不了的流程結束（open-issues：sqlId 回收、拖車 keyId 延續逾時等）→ 沒綁定的公用拖車載著受保護的車
O.setState(rMt, "RELEASED", "TEST")
check(O.lookup(mt) ~= "AUTHORIZED" and #O.carriedBy(mt) == 1, "拖車紀錄結束後：拖車沒綁定、仍載著車主的車")
check(send(ST, "msw", "launchVehicle", { trailer = mt.id, slot = 1 }) == nil, "陌生人從公用拖車卸下別人的車：擋")
local mt2 = vehicle(63, 603, 7603, "Base.SemiTrailerCartrailer", 1, 1)
check(send(ST, "msw", "launchVehicle", { trailer = mt2.id, slot = 1 }) ~= nil, "另一台空的公用拖車：照常（只看這台拖車載著的）")
vclass("ATAISLaunchVehicle", { "complete" })
G.install("F5")
local la = A("ATAISLaunchVehicle", { character = ST, trailer = mt, square = GOS.square(2, 1) })
check(stage(la, "complete") == false and calls("ATAISLaunchVehicle.complete") == 0 and la._mvmReason == "NOT_AUTHORIZED",
    "Autotsar 卸車 adapter：拖車不受保護但載著別人的車 → 擋")
check(stage(A("ATAISLaunchVehicle", { character = OW, trailer = mt, square = GOS.square(2, 1) }), "complete") == true
    and send(OW, "msw", "launchVehicle", { trailer = mt.id, slot = 1, x = 2, y = 1 }) ~= nil, "車主卸自己的車：adapter 與指令都放行")
local mt3 = vehicle(64, 604, 7604, "Base.SemiTrailerCartrailer", 1, 1)
local car5b = vehicle(65, 605, 7605, "Base.CarNormal", 1, 1)
claim(OW, car5b); claim(OW, mt3)
send(OW, "msw", "loadVehicle", { trailer = mt3.id, vehicle = car5b.id, slot = 1 })
local outerTr = vehicle(66, 606, 7606, "Base.TestWrecker", 1, 1)
check(#O.carriedBy(mt3) == 1 and send(OW, "commonlib", "loadVehicle", { trailer = outerTr.id, vehicle = mt3.id }) == nil
    and send(OW, "msw", "loadVehicle", { trailer = outerTr.id, vehicle = mt3.id, slot = 1 }) == nil and not mt3.removed,
    "載著受保護紀錄的拖車不能再被裝上另一台拖車（連車主也擋，CARRIER_LOADED）")
local cont, ctr = vehicle(67, 607, 7607, "Base.W900Container", 1, 1), vehicle(68, 608, 7608, "Base.SemiTrailerVan", 1, 1)
local rCont = rec(claim(OW, cont).oid)
send(OW, "msw", "loadContainer", { trailer = ctr.id, container = cont.id })
cont:permanentlyRemove() -- MSW 載入貨櫃後移除貨櫃車（MSW_Common_Commands.lua:2254）
local function cmdDenied(label)
    for key in pairs(O.R.denyAgg) do if key:find(label, 1, true) then return true end end
    return false
end
send(ST, "msw", "unloadContainer", { trailer = ctr.id, x = 2, y = 1 })
check(cont.removed and rCont.carrierSqlId == nil and #O.carriedBy(ctr) == 0 and not cmdDenied("CMD:msw.unloadContainer"),
    "W900 貨櫃轉移不記在哪台車上（不會接回），公用貨櫃拖車之後換人卸貨照常")
local farTr = vehicle(69, 609, 7609, "Base.SemiTrailerCartrailer", 40, 1)
send(OW, "msw", "unloadContainer", { trailer = ctr.id, x = 2, y = 1, z = 1 })
check(send(OW, "msw", "launchVehicle", { trailer = farTr.id, slot = 1, x = 40, y = 1 }) ~= nil and not cmdDenied("CMD:msw.unloadContainer"),
    "拖車與貨櫃拖車都沒綁定、沒載受保護的車：不看距離與座標")
OW.x = 30 -- 公用拖車 mt 仍載著車主的 car4（替身卸車不會接回）：人離拖車太遠
send(OW, "msw", "launchVehicle", { trailer = mt.id, slot = 1, x = 2, y = 1 })
local anchorFar = cmdDenied("tow|CMD:msw.launchVehicle||TOO_FAR")
OW.x = 18
local trG, carG = vehicle(70, 610, 7610, "Base.TestWrecker", 1, 1), vehicle(71, 611, 7611, "Base.CarNormal", 18, 1)
claim(OW, carG)
OW.x = 9.5 -- 人離拖車與車都在 10 格內，但車離拖車 17 格
send(OW, "commonlib", "loadVehicle", { trailer = trG.id, vehicle = carG.id })
OW.x = 1
check(#O.carriedBy(mt) >= 1 and anchorFar, "公用拖車載著受保護的車：卸車的人不在拖車附近 → TOO_FAR")
check(carG.removed == false and cmdDenied("tow|CMD:commonlib.loadVehicle||TOO_FAR") and not cmdDenied("CARRIER_UNBOUND"),
    "被裝的車離拖車太遠 → TOO_FAR（拖車沒綁定也先回距離）")

out("情境 F6：TimedAction 回送與 tsarslib 新 adapter")
local savedSend = sendClientCommand
sendClientCommand = function(p, m, c, args) fire("OnClientCommand", m, c, p, args) end -- 伺服器上直接觸發 OnClientCommand
-- 照原版：回送之後 complete 自己再換零件、permanentlyRemove（ATAISLoadVehicle.lua:45-55），回送被擋也擋不住後面
vclass("ATAISLoadVehicle", { "complete" }, { complete = function(a)
    sendClientCommand(a.character, "commonlib", "loadVehicle", { trailer = a.trailer:getId(), vehicle = a.vehicle:getId() })
    a.trailer.keyId = a.vehicle.keyId
    if not a.vehicle.removed then a.vehicle:permanentlyRemove() end
    return true
end })
for _, n in ipairs({ "ISInstallTuningVehiclePart", "ISUninstallTuningVehiclePart", "ATAISAnimatedPartOpen", "ATAISAnimatedPartClose", "ISPaintBus" }) do
    vclass(n, { "complete" })
end
vclass("ISRefuelFromLiqudTanker", { "update", "complete", "serverStop" })
G.install("F6")
local tr5 = vehicle(71, 701, 7701, "Base.TestWrecker", 1, 1)
local car5 = vehicle(72, 702, 7702, "Base.CarNormal", 1, 1)
local rTr5, rCar5 = rec(claim(OW, tr5).oid), rec(claim(OW, car5).oid)
seen = nil
check(stage(A("ATAISLoadVehicle", { character = ST, trailer = tr5, vehicle = car5 }), "complete") == false and seen == nil and not car5.removed,
    "陌生人：adapter 擋下，不會回送")
intent(OW, "ATAISLoadVehicle", car5); intent(OW, "ATAISLoadVehicle", tr5)
seen = nil
check(stage(A("ATAISLoadVehicle", { character = OW, trailer = tr5, vehicle = car5 }), "complete") == true and seen ~= nil and car5.removed
    and rCar5.carrierSqlId == 701, "車主：adapter 放行後 complete 回送的 commonlib 指令也放行（同一人、同一台車）")
fire("OnTick")
check(rTr5.recordState == "ACTIVE" and rTr5.keyIdHint == 7702, "回送路徑的 keyId 延續也成立")
local tr7, car7 = vehicle(75, 705, 7705, "Base.TestWrecker", 1, 1), vehicle(76, 706, 7706, "Base.CarNormal", 1, 1)
claim(OW, tr7); claim(OW, car7)
intent(OW, "ATAISLoadVehicle", car7); intent(OW, "ATAISLoadVehicle", tr7)
OW.x = 30
local farLoad = A("ATAISLoadVehicle", { character = OW, trailer = tr7, vehicle = car7 })
local farOk = stage(farLoad, "complete") == false and farLoad._mvmReason == "TOO_FAR" and not car7.removed and tr7.keyId == 7705
OW.x = 9.5 -- 人離拖車與車都在 10 格內，但車離拖車 17 格
car7.x = 18
intent(OW, "ATAISLoadVehicle", car7); intent(OW, "ATAISLoadVehicle", tr7)
local farCar = A("ATAISLoadVehicle", { character = OW, trailer = tr7, vehicle = car7 })
farOk = farOk and stage(farCar, "complete") == false and farCar._mvmReason == "TOO_FAR" and not car7.removed
car7.x, OW.x = 1, 1
intent(OW, "ATAISLaunchVehicle", tr7)
local farSq = A("ATAISLaunchVehicle", { character = OW, trailer = tr7, square = GOS.square(40, 1) })
check(farOk and stage(farSq, "complete") == false and farSq._mvmReason == "BAD_POS",
    "Autotsar adapter 在原 complete 之前擋距離：人不在拖車與車附近、車離拖車太遠、卸車格離拖車太遠 → 車沒被裝走")
check(stage(A("ATAISLoadVehicle", { character = OW, trailer = outerTr, vehicle = mt3 }), "complete") == false and not mt3.removed,
    "Autotsar 裝車 adapter：載著受保護紀錄的拖車不能被裝上去（CARRIER_LOADED）")
sendClientCommand = savedSend
local tr6 = vehicle(73, 703, 7703, "Base.TestWrecker", 1, 1)
local car6 = vehicle(74, 704, 7704, "Base.CarNormal", 1, 1)
local rTr6, rCar6 = rec(claim(OW, tr6).oid), rec(claim(OW, car6).oid)
intent(OW, "ATAISLoadVehicle", car6); intent(OW, "ATAISLoadVehicle", tr6)
check(stage(A("ATAISLoadVehicle", { character = OW, trailer = tr6, vehicle = car6 }), "complete") == true
    and O.R.keyIdPending[rTr6.oid] ~= nil and O.R.keyIdPending[rTr6.oid].keyId == 7704 and rCar6.carrierSqlId == 703,
    "adapter 放行時自己也記 keyId 延續與在哪台車上（不靠回送）")
local sv = vehicle(81, 801, 7801, "Base.SVU3Car", 1, 1, { "Engine", "Battery", "DoorFrontLeft", "TrunkDoor" })
local lv = vehicle(82, 802, 7802, "Base.CarNormal", 1, 1)
claim(OW, sv)
local function tun(cls, p) return A(cls, { character = p, vehicle = sv, part = sv.parts.Battery }) end
check(stage(tun("ISUninstallTuningVehiclePart", ST), "complete") == false and stage(tun("ISInstallTuningVehiclePart", ST), "complete") == false
    and calls("ISUninstallTuningVehiclePart.complete") == 0 and calls("ISInstallTuningVehiclePart.complete") == 0,
    "陌生人拆／裝受保護車的調校零件：擋（拿不到零件）")
intent(OW, "ISUninstallTuningVehiclePart", sv, "Battery")
check(stage(tun("ISUninstallTuningVehiclePart", OW), "complete") == true and calls("ISUninstallTuningVehiclePart.complete") == 1, "車主拆調校零件：放行")
local function door(cls, p, v, pt) return A(cls, { character = p, vehicle = v, part = pt }) end
check(stage(door("ATAISAnimatedPartOpen", ST, sv, sv.parts.DoorFrontLeft), "complete") == false
    and stage(door("ATAISAnimatedPartClose", ST, sv, sv.parts.TrunkDoor), "complete") == false
    and stage(door("ATAISAnimatedPartOpen", OW, lv, sv.parts.DoorFrontLeft), "complete") == false
    and calls("ATAISAnimatedPartOpen.complete") == 0 and calls("ATAISAnimatedPartClose.complete") == 0,
    "Autotsar 動畫門：陌生人開關受保護車的門擋、a.vehicle 與門所屬車不同擋")
check(stage(A("ISPaintBus", { character = ST, vehicle = sv, skinIndex = 2 }), "complete") == false and calls("ISPaintBus.complete") == 0,
    "陌生人替受保護的車換塗裝：擋")
local tank = A("ISRefuelFromLiqudTanker", { character = ST, vehicle = lv, part = lv.parts.Engine, tank = sv.parts.Battery })
check(stage(tank, "complete") == false and stage(tank, "serverStop") == nil and calls("ISRefuelFromLiqudTanker.complete") == 0
    and calls("ISRefuelFromLiqudTanker.serverStop") == 0, "陌生人從受保護的油罐車抽油：擋（also）")
intent(OW, "ISRefuelFromLiqudTanker", sv)
check(stage(A("ISRefuelFromLiqudTanker", { character = OW, vehicle = lv, part = lv.parts.Engine, tank = sv.parts.Battery }), "complete") == true,
    "車主從自己的油罐車加油給沒綁定的車：放行")
Events.OnClientCommand.Remove(fakeTow)
SB.ClaimsPerPlayer = quota0
end)();

(function() -- 主 chunk 區域變數已滿 200：本情境用自己的函式作用域
out("情境 F7：綁定的車只能裝上已綁定的載具（CARRIER_UNBOUND）、載著受保護紀錄不能結束拖車紀錄（CARRIER_HAS_CARGO）")
boot()
local quota0 = SB.ClaimsPerPlayer
SB.ClaimsPerPlayer = 20
for k in pairs(MVM.CommandGate.R.notified) do MVM.CommandGate.R.notified[k] = nil end
-- 處理器替身：裝車（整車或貨櫃）就移除被裝的車
local function stand(m, c, _, args)
    if (m ~= "commonlib" and m ~= "msw") or (c ~= "loadVehicle" and c ~= "loadContainer") then return end
    local v = world[args.vehicle or args.container]
    if v and world[args.trailer] and not v.removed then v:permanentlyRemove() end
end
Events.OnClientCommand.Add(stand)
local function send(p, m, c, args) nowMs = nowMs + 2100; fire("OnClientCommand", m, c, p, args) end -- 跨過通知節流
local function denied(text) for key in pairs(O.R.denyAgg) do if key:find(text, 1, true) then return true end end return false end
local function clear() for key in pairs(O.R.denyAgg) do O.R.denyAgg[key] = nil end end
local function back(v, r) -- 拖車 MOD 卸車：新 sqlId、零件見證還原 → 接回
    local nv = vehicle(v.id + 50, v.sqlId + 50, v.keyId, v.script, 1, 1)
    rawset(nv.parts.Engine.md, "MinidoracatVehicleManager", { oid = r.oid, epoch = r.epoch })
    O.lookup(nv)
    return nv
end
local OW, ST, AD = player("uow", 1, 1), player("ustr", 1, 1), player("uadm", 1, 1, { admin = true })
cmd(OW, "fleetSubscribe", {}, false)
local function veh(id, script) return vehicle(id, 800 + id, 8800 + id, script, 1, 1) end
local loaded = {}
for i, m in ipairs({ "commonlib", "msw" }) do
    local b = 100 + i * 10
    local c, ut, bt, lc = veh(b + 1, "Base.CarNormal"), veh(b + 2, "Base.TestWrecker"), veh(b + 3, "Base.TestWrecker"), veh(b + 4, "Base.CarNormal")
    local rc, rbt = rec(claim(OW, c).oid), rec(claim(OW, bt).oid)
    local label = "CMD:" .. m .. ".loadVehicle"
    clear()
    send(ST, m, "loadVehicle", { trailer = ut.id, vehicle = c.id, slot = 1 })
    check(not c.removed and denied(label .. "|" .. rc.oid .. "|NOT_AUTHORIZED") and not denied("CARRIER_UNBOUND")
        and lastOf(ST, "enforcement").reason == "NOT_AUTHORIZED",
        label .. "：沒有被裝車 TOW 的陌生人 → 沒綁定的拖車：NOT_AUTHORIZED（不提示綁定拖車）")
    send(OW, m, "loadVehicle", { trailer = ut.id, vehicle = c.id, slot = 1 })
    check(not c.removed and rc.carrierSqlId == nil and denied(label .. "||CARRIER_UNBOUND")
        and lastOf(OW, "enforcement").reason == "CARRIER_UNBOUND", label .. "：車主把綁定的車裝上沒綁定的拖車 → CARRIER_UNBOUND，車沒被移除")
    O.setOverride(AD, true)
    send(AD, m, "loadVehicle", { trailer = ut.id, vehicle = c.id, slot = 1 })
    O.setOverride(AD, false)
    check(not c.removed and lastOf(AD, "enforcement").reason == "CARRIER_UNBOUND", label .. "：管理員開越權也一樣 CARRIER_UNBOUND")
    send(ST, m, "loadVehicle", { trailer = ut.id, vehicle = lc.id, slot = 1 })
    check(lc.removed, label .. "：沒綁定的車裝上沒綁定的拖車照常")
    send(OW, m, "loadVehicle", { trailer = bt.id, vehicle = c.id, slot = 1 })
    check(c.removed and rc.carrierSqlId == bt.sqlId, label .. "：車主裝上已綁定、有 TOW 的拖車 → 放行")
    loaded[m] = { c = c, rc = rc, bt = bt, rbt = rbt }
end
local qd = lastOf(OW, "fleetDelta")
check(qd ~= nil and qd.quotaUsed == O.quotaUsed("uow") and qd.quotaUsed == 4, "車主收到的增量帶目前已用名額（車移出世界仍計入）")
local cont, ctr = veh(131, "Base.W900Container"), veh(132, "Base.SemiTrailerVan")
claim(OW, cont)
send(ST, "msw", "loadContainer", { trailer = ctr.id, container = cont.id })
local contStranger = not cont.removed
send(OW, "msw", "loadContainer", { trailer = ctr.id, container = cont.id })
check(contStranger and cont.removed and not denied("CMD:msw.loadContainer||CARRIER_UNBOUND"),
    "msw.loadContainer 不變：陌生人擋、車主把綁定的貨櫃裝上沒綁定的貨櫃拖車照常")

vclass("ATAISLoadVehicle", { "complete" })
local n0 = calls("ATAISLoadVehicle.complete")
G.install("F7")
local ac, aut, abt, alc = veh(141, "Base.CarNormal"), veh(142, "Base.TestWrecker"), veh(143, "Base.TestWrecker"), veh(144, "Base.CarNormal")
local rac = rec(claim(OW, ac).oid)
claim(OW, abt)
local function loadA(p, tr, v) return A("ATAISLoadVehicle", { character = p, trailer = tr, vehicle = v }) end
local la = loadA(ST, aut, ac)
check(stage(la, "complete") == false and la._mvmReason == "NOT_AUTHORIZED" and calls("ATAISLoadVehicle.complete") == n0,
    "Autotsar adapter：陌生人 → 沒綁定的拖吊車：NOT_AUTHORIZED")
intent(OW, "ATAISLoadVehicle", ac)
la = loadA(OW, aut, ac)
check(stage(la, "complete") == false and la._mvmReason == "CARRIER_UNBOUND" and lastEnforcement(OW).reason == "CARRIER_UNBOUND"
    and calls("ATAISLoadVehicle.complete") == n0 and rac.carrierSqlId == nil, "Autotsar adapter：車主 → 沒綁定的拖吊車：CARRIER_UNBOUND，原 complete 沒跑")
O.setOverride(AD, true)
intent(AD, "ATAISLoadVehicle", ac)
la = loadA(AD, aut, ac)
local adminWhy = stage(la, "complete") == false and la._mvmReason
O.setOverride(AD, false)
check(adminWhy == "CARRIER_UNBOUND", "Autotsar adapter：管理員開越權也 CARRIER_UNBOUND")
check(stage(loadA(ST, aut, alc), "complete") == true, "Autotsar adapter：沒綁定的車 → 沒綁定的拖吊車照常")
intent(OW, "ATAISLoadVehicle", ac); intent(OW, "ATAISLoadVehicle", abt)
check(stage(loadA(OW, abt, ac), "complete") == true and rac.carrierSqlId == abt.sqlId, "Autotsar adapter：車主 → 已綁定的拖吊車放行")

local L = loaded.commonlib
local function unclaimBt(r) return cmd(OW, "unclaim", { vehicleId = L.bt.id, expectedOid = r.oid, expectedEpoch = r.epoch }) end
check(unclaimBt(L.rbt).reason == "CARRIER_HAS_CARGO" and L.rbt.recordState == "ACTIVE" and witness(L.bt) ~= nil,
    "解除綁定：拖車載著受保護紀錄 → CARRIER_HAS_CARGO，紀錄與見證不動")
check(cmd(OW, "reportLost", { expectedOid = L.rbt.oid }).reason == "CARRIER_HAS_CARGO" and L.rbt.recordState == "ACTIVE",
    "回報遺失：載著受保護紀錄 → CARRIER_HAS_CARGO")
check(cmd(AD, "adminRecover", { expectedOid = L.rbt.oid, op = "RELEASE" }).reason == "CARRIER_HAS_CARGO" and L.rbt.recordState == "ACTIVE",
    "管理員釋出：載著受保護紀錄 → CARRIER_HAS_CARGO（開越權卸下再釋出）")
O.beginRelease(L.rbt, "REPORT_LOST")
nowMs = nowMs + 25 * 3600000
O.maintain(true)
check(L.rbt.recordState == "PENDING_RELEASE", "待釋放到期但仍載著受保護紀錄：先不結束")
back(L.c, L.rc)
O.maintain(true)
check(L.rc.removedAtMs == nil and L.rbt.recordState == "RELEASED", "卸下（接回）之後：待釋放到期照常結束")
local M = loaded.msw
check(cmd(OW, "unclaim", { vehicleId = M.bt.id, expectedOid = M.rbt.oid, expectedEpoch = M.rbt.epoch }).reason == "CARRIER_HAS_CARGO",
    "MSW 拖車載著受保護紀錄：解除綁定被拒")
back(M.c, M.rc)
check(cmd(OW, "unclaim", { vehicleId = M.bt.id, expectedOid = M.rbt.oid, expectedEpoch = M.rbt.epoch }).ok and M.rbt.recordState == "RELEASED",
    "卸下之後：解除綁定成功")
-- 閒置釋放遇到載著自己車的拖車：被載的車先解除，拖車在仍載著受保護紀錄時不放，下一輪再放
local c9, bt9 = veh(151, "Base.CarNormal"), veh(153, "Base.TestWrecker")
local rc9, rbt9 = rec(claim(OW, c9).oid), rec(claim(OW, bt9).oid)
send(OW, "msw", "loadVehicle", { trailer = bt9.id, vehicle = c9.id, slot = 1 })
SB.InactivityReleaseDays = 1
O.state().ownerActivity.uow.lastSuccessfulLoginAtMs = nowMs - 2 * 86400000
O.state().lastMaintAtMs = nowMs - 60000
O.maintain(true)
local carrierFirst = rbt9.recordState == "RELEASED" and rc9.recordState ~= "RELEASED"
nowMs = nowMs + 60000
O.maintain(true)
check(c9.removed and rc9.carrierSqlId == nil and not carrierFirst and rc9.recordState == "RELEASED" and rbt9.recordState == "RELEASED",
    "閒置釋放：被載的車先解除，拖車不會在仍載著受保護紀錄時被放")
SB.InactivityReleaseDays = 0
Events.OnClientCommand.Remove(stand)
SB.ClaimsPerPlayer = quota0
end)(); -- 分號：下一個情境也是 IIFE

(function()
out("情境 PS：公開分享（所有人）")
boot()
local OWp, STp = player("pown", 1, 1), player("pstr", 1, 1)
cmd(OWp, "fleetSubscribe", {}, false)
cmd(STp, "fleetSubscribe", {}, false)
local car = vehicle(61, 961, 9961, "Base.CarNormal", 1, 1)
local r = rec(claim(OWp, car).oid)
local function setPub(bits, p) return cmd(p or OWp, "setPublicShare", { expectedOid = r.oid, expectedEpoch = r.epoch, actionBits = bits }) end
check(not O.canUse(STp, car, "PASSENGER") and lastOf(STp, "fleetSnapshot").pub[r.oid] == nil, "沒公開：陌生人不能用，公開表沒有")
check(setPub(MVM.ACTIONS.TRACK).reason == "BAD_ARGS" and setPub(MVM.ACTIONS.TOW).reason == "BAD_ARGS"
    and setPub(MVM.ACTIONS.SALVAGE).reason == "BAD_ARGS" and setPub(MVM.ACTIONS.MANAGE).reason == "BAD_ARGS" and r.publicBits == 0,
    "公開只收搭乘、駕駛、置物、加油、修理（位置、拖曳、拆解、管理不行）")
check(setPub(MVM.ACTIONS.PASSENGER, STp).reason == "NOT_OWNER" and r.publicBits == 0, "只有車主能設定公開")
local pub5 = MVM.ACTIONS.PASSENGER + MVM.ACTIONS.CARGO
local ok = setPub(pub5)
local pd = lastOf(STp, "publicDelta")
check(ok.ok and r.publicBits == pub5 and pd and pd.oid == r.oid and pd.bits == pub5
    and lastOf(OWp, "fleetDelta").upserts[1].publicBits == pub5,
    "公開搭乘與置物：寫入紀錄、推 publicDelta 給所有線上玩家、車主的列帶 publicBits")
local allowed, why = O.canUse(STp, car, "PASSENGER")
check(allowed and why == "PUBLIC" and O.canUse(STp, car, "CARGO") and not O.canUse(STp, car, "DRIVE")
    and not O.canUse(STp, car, "SALVAGE") and not O.canUse(STp, car, "MANAGE"), "陌生人可用公開的動作，其餘照擋")
local split = player("pstr", 1, 1)
split.num = 1
check(not O.canUse(split, car, "PASSENGER"), "沒有身分的人（分割畫面）不能用公開分享")
local NEW = player("pnew", 1, 1)
cmd(NEW, "fleetSubscribe", {}, false)
local snapNew = lastOf(NEW, "fleetSnapshot")
check(snapNew.pub[r.oid] == pub5 and #snapNew.rows == 0, "新上線玩家的快照帶公開表，公開車不進他的車輛列")
local before = #outbox[STp.name]
setPub(pub5)
check(#outbox[STp.name] == before, "公開內容沒變：不重送 publicDelta")
O.setState(r, "QUARANTINED", "TEST")
check(lastOf(STp, "publicDelta").bits == 0 and S.publicTable()[r.oid] == nil and not O.canUse(STp, car, "PASSENGER"),
    "隔離：公開表撤掉，陌生人不能用")
O.setState(r, "ACTIVE", "TEST")
check(lastOf(STp, "publicDelta").bits == pub5, "解除隔離：公開表恢復")
check(setPub(0).ok and r.publicBits == 0 and lastOf(STp, "publicDelta").bits == 0 and not O.canUse(STp, car, "PASSENGER"),
    "設成 0：停止公開")
setPub(MVM.ACTIONS.DRIVE)
local tr = cmd(OWp, "transfer", { vehicleId = car.id, expectedOid = r.oid, expectedEpoch = r.epoch, recipient = "pnew" })
local fresh = tr.ok and rec(tr.oid)
check(fresh and fresh.publicBits == 0 and lastOf(STp, "publicDelta").oid == r.oid and lastOf(STp, "publicDelta").bits == 0,
    "轉讓：舊紀錄的公開撤掉，新車主從私人開始")
end)();

(function()
out("情境 DK：家族工具列（框架 rev 13 Dock）與舊框架浮鈕退回")
local saved = { UI = MinidoracatUI, panel = ISPanel, font = UIFont, core = getCore, layout = ISLayoutManager,
    override = MVM.clientOverride, win = MVM.FleetWindow, fui = MVM.FleetUI, changed = MVM.onFleetChanged, hooks = MVM.clientMenuHooks }
local regs, floats = {}, {}
local function loadFleet(capabilities, accept)
    MinidoracatUI = { v1 = { API_MAJOR = 1, API_REVISION = 13, CAPABILITIES = capabilities,
        Theme = { create = function(options) return options end },
        FloatButton = { new = function(opts) floats[#floats + 1] = opts; return opts end },
        Dock = { register = function(spec) regs[#regs + 1] = spec; return accept end } } }
    MVM.clientMenuHooks = {}
    local n = {}
    for _, ev in ipairs({ "OnGameStart", "OnResolutionChange", "OnNetworkUsersReceived" }) do
        handlers[ev] = handlers[ev] or {}; n[ev] = #handlers[ev]
    end
    isClient = function() return true end
    assert(loadfile(MEDIA .. "/client/ISUI/MinidoracatVehicleManager_FleetWindow.lua"))()
    isClient = function() return false end
    local added = { start = #handlers.OnGameStart - n.OnGameStart, res = #handlers.OnResolutionChange - n.OnResolutionChange }
    for i = n.OnGameStart + 1, #handlers.OnGameStart do handlers.OnGameStart[i]() end -- 進遊戲
    for ev, k in pairs(n) do while #handlers[ev] > k do table.remove(handlers[ev]) end end
    return added
end
ISPanel = { derive = function() return {} end }
UIFont = { Small = 1, Medium = 2, Large = 3 }
getCore = function() return { getScreenWidth = function() return 1920 end, getScreenHeight = function() return 1080 end } end
ISLayoutManager = { RegisterWindow = function() end, TryRestore = function() end, OnPostSave = function() end }
local function caps(dock) return { window = true, controls = true, dialog = true, virtualList = true, floatButton = true, dock = dock } end

local docked = loadFleet(caps(true), true)
local spec = regs[1]
check(#regs == 1 and #floats == 0 and docked.start == 0 and docked.res == 0 and MVM.FleetUI.float == nil,
    "有 Dock：只登記一個入口，進遊戲不建浮鈕、不掛換解析度處理")
check(spec.id == "vehiclemanager" and spec.order == 40 and spec.iconKey == "steeringwheel" and spec.label() == "IGUI_MVM_FleetTitle",
    "Dock 入口：id、排序 40、方向盤圖示、名稱是車隊視窗標題")
local W = MVM.FleetWindow
check(spec.isActive() == false, "車隊視窗還沒建立：入口不是開啟中")
local shown = true
W.instance = { win = { getIsVisible = function() return shown end, setVisible = function(_, v) shown = v end } }
check(spec.isActive() == true, "車隊視窗開著：入口顯示開啟中")
spec.onClick({})
check(shown == false and spec.isActive() == false, "點入口：切換車隊視窗（開著就關）")
MVM.clientOverride = function() return false end
check(spec.getState() == nil and spec.getStatus() == nil, "沒越權：入口無警示、無狀態行")
MVM.clientOverride = function(n) return n == 0 end
check(spec.getState() == "warn" and spec.getStatus() == "IGUI_MVM_Override_Active", "越權中：入口紅框警示，提示寫越權中")

regs = {}
local old = loadFleet(caps(nil), true)
check(#regs == 0 and #floats == 1 and old.start == 1 and old.res == 1 and MVM.FleetUI.float == floats[1] and floats[1].size == 40,
    "舊框架（沒有 dock 能力）：不登記，照舊建浮鈕並處理換解析度")
regs, floats = {}, {}
local refused = loadFleet(caps(true), false)
check(#regs == 1 and #floats == 1 and refused.res == 1, "Dock 拒絕登記：退回浮鈕")

MinidoracatUI, ISPanel, UIFont, getCore, ISLayoutManager = saved.UI, saved.panel, saved.font, saved.core, saved.layout
MVM.clientOverride, MVM.FleetWindow, MVM.FleetUI, MVM.onFleetChanged, MVM.clientMenuHooks =
    saved.override, saved.win, saved.fui, saved.changed, saved.hooks
end)(); -- 分號：下一個情境也是 IIFE

-- ===== 停車保全與租用到期（G1..G7）=====
-- 共用工具放全域表 GH（主 chunk 區域變數已滿 200）
GH = {}
-- 受保全測試車：引擎沒有原件（durability 5）、電池 durability 0（保全不碰）、車窗原件（durability 3）、車門原件（durability 4）
function GH.car(id, x, y)
    local v = vehicle(id, 800 + id, 8800 + id, "Base.CarNormal", x or 1, y or 1, { "Engine", "Battery", "WindowFrontLeft", "DoorFrontLeft" })
    local p = v.parts
    p.Engine.cond, p.Engine.dur = 90, 5
    p.Battery:setInventoryItem(instanceItem("Base.CarBattery1", 0))
    p.WindowFrontLeft.window = {}
    p.WindowFrontLeft:setInventoryItem(instanceItem("Base.FrontWindow1", 3))
    p.DoorFrontLeft:setInventoryItem(instanceItem("Base.FrontCarDoor1", 4))
    p.DoorFrontLeft.cond = 80
    return v
end
function GH.tick(ms) nowMs = nowMs + (ms or MVM.Parked.CHECK_MS); MVM.Parked.tick() end
function GH.armed(v) return v.parts.Engine.dur == MVM.Parked.BIG end
function GH.count(p, command)
    local n = 0
    for _, m in ipairs(outbox[p.name]) do if m.command == command then n = n + 1 end end
    return n
end
-- from 之後有一行同時含全部字串
function GH.logged(from, ...)
    local want = { ... }
    for i = from + 1, #logLines do
        local hit = true
        for _, w in ipairs(want) do if not logLines[i]:find(w, 1, true) then hit = false end end
        if hit then return true end
    end
    return false
end

(function()
out("情境 G1：停車保全核心（布防、解除、復原、touch、紀錄結束）")
boot()
local P, BIG = MVM.Parked, MVM.Parked.BIG
SB.ParkedGuard = MVM.GUARD.ALL
local OW, ST, MB = player("gown", 1, 1), player("gstr", 1, 1), player("gmem", 1, 1)
local gv, loose = GH.car(81), GH.car(82)
local pt = gv.parts
local r = rec(claim(OW, gv).oid)
GH.tick()
check(pt.Engine.dur == BIG and pt.WindowFrontLeft.dur == BIG and pt.DoorFrontLeft.dur == BIG and pt.Battery.dur == 0,
    "ALL：沒人在車上的綁定車布防，durability > 0 的零件（含沒有原件的引擎）拉到 BIG，durability 0 的不碰")
check(loose.parts.Engine.dur == 5 and P.R.tracked[82] == nil, "沒綁定的車：不追蹤、durability 不動")
SB.ParkedGuard = MVM.GUARD.OFF
GH.tick()
check(pt.Engine.dur == 5 and pt.WindowFrontLeft.dur == 3 and pt.DoorFrontLeft.dur == 4 and pt.Battery.dur == 0,
    "OFF：解除，durability 寫回原值")
SB.ParkedGuard = MVM.GUARD.ALL
GH.tick()
gv.seats[1] = ST
GH.tick()
check(GH.armed(gv), "沒權限的人坐在車上：不解除（佔座由 watchdog 處理）")
gv.seats[1], gv.seats[0] = nil, OW
GH.tick()
check(pt.Engine.dur == 5 and pt.DoorFrontLeft.dur == 4, "車主在駕駛座：解除")
gv.seats[0] = nil
GH.tick()
check(cmd(OW, "addMember", { expectedOid = r.oid, username = "gmem", actionBits = MVM.ACTIONS.PASSENGER }).ok, "車主給成員搭乘權限")
gv.seats[0] = MB
GH.tick()
check(GH.armed(gv), "只有搭乘權限的成員坐駕駛座（要 DRIVE）：不算授權者，不解除")
gv.seats[0], gv.seats[2] = nil, MB
GH.tick()
check(pt.Engine.dur == 5, "有搭乘權限的成員坐乘客座：解除")
gv.seats[2] = nil
GH.tick()
check(GH.armed(gv), "下車後重新布防")
gv.towedBy = loose
GH.tick()
check(pt.Engine.dur == 5, "被拖著：解除")
gv.towedBy = nil
GH.tick()

-- 布防中被打：同一原件掉耐久、沒原件的引擎掉耐久、車窗原件被打掉且格子出現碎玻璃
local pane0, glass = pt.WindowFrontLeft.item, { kind = "IsoBrokenGlass" }
pt.DoorFrontLeft.cond, pt.Engine.cond = 30, 40
pt.WindowFrontLeft.item, pt.WindowFrontLeft.cond = nil, 0
gv.square.glass = glass
local tx0 = { item = tx.item or 0, condition = tx.condition or 0, window = tx.window or 0 }
local l0, n0 = #logLines, GH.count(OW, "notice")
GH.tick(P.RESTORE_MS)
local pane = pt.WindowFrontLeft.item
check(pt.DoorFrontLeft.cond == 80 and pt.Engine.cond == 90, "RESTORE_MS 到：同一原件與沒有原件的零件耐久補回基準")
check(pane ~= nil and pane ~= pane0 and pane.full == "Base.FrontWindow1" and pane.cond == 100 and pt.WindowFrontLeft.cond == 100
    and pt.WindowFrontLeft.dur == BIG, "車窗原件不見：裝一片同型新玻璃（同耐久），新件重設的 durability 再拉高")
check(gv.square.removed[1] == glass and gv.square.glass == nil, "布防後才出現的碎玻璃：補窗時一併清掉")
check((tx.item or 0) == tx0.item + 1 and (tx.condition or 0) >= tx0.condition + 3 and (tx.window or 0) >= tx0.window + 1,
    "復原送出零件原件／耐久／車窗同步")
check(GH.logged(l0, "GUARD_RESTORE", r.oid, "REINSTALL") and GH.count(OW, "notice") == n0 + 1
    and lastOf(OW, "notice").key == "IGUI_MVM_Guard_Repaired" and lastOf(OW, "notice").oid == r.oid,
    "復原：稽核 GUARD_RESTORE（零件清單），通知在線車主 IGUI_MVM_Guard_Repaired")

-- 換件：改認目前的為基準（不重建舊件），換件重設的 durability 再拉高；解除時寫回新件的值
local door2 = instanceItem("Base.FrontCarDoor2", 6)
pt.DoorFrontLeft:setInventoryItem(door2)
pt.DoorFrontLeft.cond = 60
GH.tick(P.RESTORE_MS)
check(pt.DoorFrontLeft.item == door2 and pt.DoorFrontLeft.cond == 60 and pt.DoorFrontLeft.dur == BIG,
    "換件：改認目前的件為基準（不重建、不補成舊件耐久），durability 再拉高")
pt.DoorFrontLeft.cond = 45
l0 = #logLines
GH.tick(P.RESTORE_MS)
check(pt.DoorFrontLeft.cond == 60 and GH.logged(l0, "GUARD_RESTORE", "DoorFrontLeft:45->60") and GH.count(OW, "notice") == n0 + 1,
    "換件後再被打：補回新基準；稽核照記，車主通知 60 秒內不重送")
pt.Engine:setDurability(5) -- 車重新載入：doInventoryItemStats 把 durability 重設
GH.tick(P.RESTORE_MS)
check(pt.Engine.dur == BIG, "durability 被重設：下次復原再拉高")
SB.ParkedGuard = MVM.GUARD.OFF
GH.tick()
check(pt.DoorFrontLeft.dur == 6 and pt.Engine.dur == 5 and pt.WindowFrontLeft.dur == 3, "解除：寫回目前件的原值（換上的門＝6）")

-- 布防前就有的碎玻璃不是保全造成的：補窗不清
local glass2 = { kind = "IsoBrokenGlass" }
gv.square.glass, gv.square.removed = glass2, {}
SB.ParkedGuard = MVM.GUARD.ALL
GH.tick()
pt.WindowFrontLeft.item = nil
GH.tick(P.RESTORE_MS)
check(pt.WindowFrontLeft.item ~= nil and gv.square.glass == glass2 and #gv.square.removed == 0, "布防時已有的碎玻璃：補窗但不清")

-- touch：授權的改動（車主砸自己的窗）下次檢查改認為基準，不復原
pt.WindowFrontLeft.item = nil
P.touch(gv)
GH.tick()
GH.tick(P.RESTORE_MS)
check(pt.WindowFrontLeft.item == nil and GH.armed(gv), "touch 後的改動：下次檢查重記基準，車窗保持打破的樣子，仍布防")
P.touch(loose) -- 沒追蹤的車：無事
check(P.R.tracked[82] == nil, "touch 沒追蹤的車：不出錯、不開始追蹤")

-- 紀錄結束：一次檢查內解除並丟掉
check(cmd(OW, "unclaim", { vehicleId = gv.id, expectedOid = r.oid, expectedEpoch = r.epoch }).ok, "車主解除綁定")
GH.tick()
check(pt.Engine.dur == 5 and pt.DoorFrontLeft.dur == 6 and P.R.tracked[81] == nil and P.R.byOid[r.oid] == nil,
    "紀錄已結束：解除（durability 寫回）並停止追蹤")
SB.ParkedGuard = MVM.GUARD.ALL
end)();

(function()
out("情境 G2：保全名額 SLOTS（setGuard、排名 ON／OVER、管理指令、總表）")
boot()
local P = MVM.Parked
SB.ParkedGuard, SB.GuardSlotsPerPlayer = MVM.GUARD.SLOTS, 1
local ADM, OW, ST, MB = player("sadm", 1, 1, { admin = true }), player("sown", 1, 1), player("sstr", 1, 1), player("smem", 1, 1)
cmd(OW, "fleetSubscribe", {}, false)
local c1, c2, c3 = GH.car(91), GH.car(92), GH.car(93)
local r1 = rec(claim(OW, c1).oid); nowMs = nowMs + 1000
local r2 = rec(claim(OW, c2).oid); nowMs = nowMs + 1000
local r3 = rec(claim(OW, c3).oid)
GH.tick()
check(P.state(r1) == "ON" and P.state(r2) == "OVER" and P.state(r3) == "OVER" and r1.guard == nil
    and GH.armed(c1) and not GH.armed(c2) and not GH.armed(c3),
    "SLOTS 預設：沒選過的車照綁定時間用名額，最早綁定的那台布防、其餘 OVER（車主不必設定）")
local snaps = GH.count(OW, "fleetSnapshot")
local on3 = cmd(OW, "setGuard", { expectedOid = r3.oid, enabled = true })
local g = lastOf(OW, "fleetSnapshot").guard
check(on3.ok and on3.enabled == true and r3.guard == true and r3.guardAtMs == nowMs and GH.count(OW, "fleetSnapshot") == snaps + 1
    and P.state(r3) == "ON" and P.state(r1) == "OVER"
    and g.mode == MVM.GUARD.SLOTS and g.used == 1 and g.base == 1 and g.total == 1 and g.custom == false,
    "車主開一台：排到沒選過的車前面（名額移過來）；ACK enabled，重送車主快照帶 guard（已用＝正在保全的台數）")
GH.tick()
check(GH.armed(c3) and not GH.armed(c1) and c1.parts.Engine.dur == 5, "名額移走的車解除布防、durability 寫回，開的那台布防")
check(cmd(ST, "setGuard", { expectedOid = r2.oid, enabled = true }).reason == "NOT_OWNER" and r2.guard == nil, "別人的車：NOT_OWNER")
check(cmd(OW, "setGuard", { expectedOid = r2.oid, enabled = true }).reason == "GUARD_FULL" and r2.guard == nil,
    "名額都被車主手動開的車用掉再開：GUARD_FULL")
local at3 = r3.guardAtMs
nowMs = nowMs + 1000
check(cmd(OW, "setGuard", { expectedOid = r3.oid, enabled = true }).ok and r3.guardAtMs == at3, "已在保全的車再開：不變（順序不往後排）")
local l0 = #logLines
check(cmd(OW, "adminSetGuardQuota", { usernames = { "sown" }, amount = 2 }).reason == "NOT_ADMIN"
    and O.state().guardOverrides.sown == nil, "非管理員不能設個人保全名額")
local q = cmd(ADM, "adminSetGuardQuota", { usernames = { "sown" }, amount = 2 })
check(q.ok and q.count == 1 and O.state().guardOverrides.sown == 2 and lastOf(OW, "fleetSnapshot").guard.total == 2
    and lastOf(OW, "fleetSnapshot").guard.custom == true and GH.logged(l0, "ADMIN_GUARD", "USER DEFAULT->2", "sadm"),
    "管理員設個人保全名額：guardOverrides、重送該玩家快照、稽核 ADMIN_GUARD")
check(P.state(r3) == "ON" and P.state(r1) == "ON" and P.state(r2) == "OVER", "名額變 2：手動開的那台＋最早綁定的那台，自動補上")
GH.tick()
check(GH.armed(c1) and GH.armed(c3) and not GH.armed(c2), "兩台布防")
local n0 = GH.count(OW, "notice")
cmd(ADM, "adminSetGuardQuota", { usernames = { "sown" }, amount = 1 })
check(P.state(r3) == "ON" and P.state(r1) == "OVER" and r1.guard == nil, "名額調降：手動開的留著，沒選過的先讓出")
check(GH.count(OW, "notice") == n0 + 1 and lastOf(OW, "notice").key == "IGUI_MVM_Guard_Paused" and lastOf(OW, "notice").n == 1,
    "名額變少讓 OVER 變多：通知車主 IGUI_MVM_Guard_Paused（這次多出來的台數）")
GH.tick()
check(GH.armed(c3) and not GH.armed(c1) and c1.parts.Engine.dur == 5, "OVER 的車解除布防、durability 寫回")
nowMs = nowMs + 1000
O.mapSet("quotaOverrides", "sown", 5)
local c4 = GH.car(94)
local r4 = rec(claim(OW, c4).oid)
GH.tick()
check(P.state(r4) == "OVER" and GH.count(OW, "notice") == n0 + 1, "新綁的車排不進名額：OVER，不通知（名額沒變少）")
check(cmd(OW, "addMember", { expectedOid = r3.oid, username = "smem", actionBits = MVM.ACTIONS.PASSENGER }).ok
    and cmd(OW, "addMember", { expectedOid = r1.oid, username = "smem", actionBits = MVM.ACTIONS.PASSENGER }).ok, "分享兩台給成員")
check(S.row(r1, "sown").guard == "OVER" and S.row(r3, "sown").guard == "ON" and S.row(r3, "smem").guard == "ON"
    and S.row(r1, "smem").guard == nil, "列：車主看 ON／OVER，成員只看 ON")
check(cmd(OW, "setGuard", { expectedOid = r3.oid, enabled = false }).ok and r3.guard == false and r3.guardAtMs == nil
    and P.state(r3) == nil and S.row(r3, "sown").guard == nil and P.state(r1) == "ON",
    "關掉手動開的那台：記成關掉（false）不保全，名額讓給最早綁定的車")
GH.tick()
check(not GH.armed(c3) and GH.armed(c1), "關掉的車解除，接手的車布防")
nowMs = nowMs + 1000
GH.tick()
check(P.state(r3) == nil and not GH.armed(c3), "關掉的車之後也不會被自動排回名額")
check(cmd(OW, "setGuard", { expectedOid = r2.oid, enabled = true }).ok and P.state(r2) == "ON" and P.state(r1) == "OVER",
    "沒選過、排不進名額的車開啟：排到前面，原本用名額的預設車讓出")
SB.ParkedGuard = MVM.GUARD.ALL
check(cmd(OW, "setGuard", { expectedOid = r4.oid, enabled = true }).reason == "GUARD_NOT_SLOTS" and r4.guard == nil,
    "模式不是 SLOTS：GUARD_NOT_SLOTS")
check(P.state(r3) == "ON" and P.state(r4) == "ON", "所有綁定的車：不看保全開關，每台都有保全")
SB.ParkedGuard = MVM.GUARD.SLOTS
cmd(ADM, "adminRecover", { expectedOid = r4.oid, op = "RELEASE" })
check(r4.recordState == "RELEASED" and cmd(OW, "setGuard", { expectedOid = r4.oid, enabled = true }).reason == "INVALID_STATE",
    "已結束的紀錄：INVALID_STATE")
-- 使用者 2026-10-06 問「免費改成付費，玩家要重新設定嗎」：不用。所有綁定的車模式下綁的車，切到依保全名額後
-- 最早綁定的直接用名額
local FR = player("sfree", 1, 1)
SB.ParkedGuard = MVM.GUARD.ALL
local f1 = rec(claim(FR, GH.car(95)).oid); nowMs = nowMs + 1000
local f2 = rec(claim(FR, GH.car(96)).oid)
check(P.state(f1) == "ON" and P.state(f2) == "ON", "所有綁定的車：兩台都有保全")
SB.ParkedGuard = MVM.GUARD.SLOTS
check(P.state(f1) == "ON" and P.state(f2) == "OVER" and f1.guard == nil and f2.guard == nil,
    "改成依保全名額（免費 1 台）：不必重新設定，最早綁定的那台直接有保全")
check(cmd(ADM, "adminSetGuardQuota", { usernames = { "sown" }, amount = -1 }).ok and O.state().guardOverrides.sown == nil,
    "個人保全名額 -1：恢復全服預設")

-- 模式與免費名額（沙盒）
local mode0 = SBOX.saves
check(cmd(OW, "adminSetGuardMode", { mode = MVM.GUARD.ALL }).reason == "NOT_ADMIN" and SB.ParkedGuard == MVM.GUARD.SLOTS
    and SBOX.saves == mode0, "非管理員不能改保全模式")
check(cmd(ADM, "adminSetGuardMode", { mode = 4 }).reason == "BAD_ARGS" and cmd(ADM, "adminSetGuardMode", { mode = 0 }).reason == "BAD_ARGS"
    and SBOX.saves == mode0, "保全模式只收 1..3")
SBOX.saveOk = false
local syncs, l1 = GH.count(ST, "sandboxSync"), #logLines
check(cmd(ADM, "adminSetGuardMode", { mode = MVM.GUARD.ALL }).reason == "SAVE_FAILED" and SB.ParkedGuard == MVM.GUARD.SLOTS
    and GH.count(ST, "sandboxSync") == syncs and not GH.logged(l1, "ADMIN_GUARD"), "存檔失敗：改回原值、SAVE_FAILED、不廣播不稽核")
SBOX.saveOk = true
local m = cmd(ADM, "adminSetGuardMode", { mode = MVM.GUARD.ALL })
check(m.ok and m.mode == MVM.GUARD.ALL and SB.ParkedGuard == MVM.GUARD.ALL and SBOX.file.ParkedGuard == MVM.GUARD.ALL
    and lastOf(ST, "sandboxSync").parkedGuard == MVM.GUARD.ALL and lastOf(ST, "sandboxSync").guardSlots == 1
    and GH.logged(l1, "ADMIN_GUARD", "MODE 3->2", "sadm"), "管理員改保全模式：存沙盒檔、廣播 sandboxSync（parkedGuard／guardSlots）、稽核")
check(cmd(ADM, "adminSetGuardSlots", { amount = 21 }).reason == "BAD_ARGS", "免費保全名額只收 0..20")
local s = cmd(ADM, "adminSetGuardSlots", { amount = 4 })
check(s.ok and s.amount == 4 and SB.GuardSlotsPerPlayer == 4 and SBOX.file.GuardSlotsPerPlayer == 4
    and lastOf(ST, "sandboxSync").guardSlots == 4 and GH.logged(l1, "ADMIN_GUARD", "SLOTS 1->4"), "管理員改免費保全名額：存檔、同步、稽核")
l1 = #logLines
SB.ParkedGuard = MVM.GUARD.SLOTS -- 原版沙盒 UI 直接改掉
S.watchSandbox()
check(GH.logged(l1, "ADMIN_GUARD", "SANDBOX", "MODE 2->3"), "每分鐘比對沙盒：原版 UI 改了保全模式也稽核（actor SANDBOX）")
cmd(ADM, "adminSetGuardQuota", { usernames = { "smem" }, amount = 0 })
cmd(ADM, "adminList", {}, false)
local meta = lastOf(ADM, "adminSnapshot")
local pl = {}
for _, p in ipairs(meta.players) do pl[p.user] = p end
check(meta.guardMode == MVM.GUARD.SLOTS and meta.guardSlots == 4 and pl.sown.guardBase == 4 and pl.sown.guardCustom == false
    and pl.sown.guardUsed == 2 and pl.sown.guardLimit == 4 and pl.smem.guardBase == 0 and pl.smem.guardCustom == true,
    "管理員總表：模式、免費名額；SLOTS 時每位玩家帶保全名額（基本、個人設定、已用＝正在保全的台數：預設 1＋手動開 1，關掉與已結束的不算）")
SB.ParkedGuard = MVM.GUARD.ALL
cmd(ADM, "adminList", {}, false)
meta = lastOf(ADM, "adminSnapshot")
pl = {}
for _, p in ipairs(meta.players) do pl[p.user] = p end
check(meta.guardMode == MVM.GUARD.ALL and pl.sown.guardBase == nil and pl.sown.guardUsed == nil, "不是 SLOTS：玩家不帶保全名額欄位")
SB.ParkedGuard, SB.GuardSlotsPerPlayer, SBOX.values = MVM.GUARD.ALL, 1, {}
end)();

(function()
out("情境 G3：砸窗被指令防火牆擋（保全中／沒保全的提示與車主通知、節流、車主自己的指令 touch）")
boot()
local CG, P = MVM.CommandGate, MVM.Parked
for k in pairs(CG.R.notified) do CG.R.notified[k] = nil end
SB.ParkedGuard = MVM.GUARD.ALL
local OW, ST, ST2 = player("wown", 1, 1), player("wstr", 1, 1), player("wstr2", 1, 1)
local v = GH.car(101)
local r = rec(claim(OW, v).oid)
GH.tick()
local function hit(p)
    nowMs = nowMs + CG.NOTIFY_MS
    fire("OnClientCommand", "vehicle", "damageWindow", p, { vehicle = v.id, part = "WindowFrontLeft", amount = 100 })
end
hit(ST)
local enf, note = lastOf(ST, "enforcement"), lastOf(OW, "notice")
check(enf and enf.action == "CMD:vehicle.damageWindow" and enf.guard == true and enf.oid == r.oid,
    "陌生人砸布防中的車：enforcement 帶 guard = true")
check(note and note.key == "IGUI_MVM_Attack_Guarded" and note.oid == r.oid and note.who == "wstr" and note.bad == true,
    "車主收到 IGUI_MVM_Attack_Guarded（哪台車、誰）")
local n0, e0 = GH.count(OW, "notice"), GH.count(ST, "enforcement")
hit(ST)
check(GH.count(OW, "notice") == n0 and GH.count(ST, "enforcement") == e0 + 1 and lastOf(ST, "enforcement").guard == true,
    "同一攻擊者 60 秒內再砸：攻擊者照樣收到提示，車主不重複通知")
v.seats[0] = OW
GH.tick()
hit(ST2)
enf, note = lastOf(ST2, "enforcement"), lastOf(OW, "notice")
check(enf and enf.guard == false and note.key == "IGUI_MVM_Attack_Unguarded" and note.who == "wstr2" and GH.count(OW, "notice") == n0 + 1,
    "受保護但沒布防（車主在車上）：guard = false，車主收到 IGUI_MVM_Attack_Unguarded")
v.seats[0] = nil
GH.tick()
local e1 = GH.count(OW, "enforcement")
hit(OW)
check(GH.count(OW, "enforcement") == e1 and GH.count(OW, "notice") == n0 + 1, "車主自己砸：放行，不提示也不算被攻擊")
v.parts.WindowFrontLeft.item = nil -- 原版處理器接著把窗打破
GH.tick()
GH.tick(P.RESTORE_MS)
check(v.parts.WindowFrontLeft.item == nil and GH.armed(v), "放行的指令 touch：下次檢查改認為基準，不補窗")
end)();

(function()
out("情境 G4：車上收音機（ISRadioAction adapter：耳機＝置物、其他＝搭乘；手持收音機不管）")
boot()
vclass("ISRadioAction", { "complete" })
G.install("G4")
local OW, ST, MB = player("rdown", 1, 1), player("rdstr", 1, 1), player("rdmem", 1, 1)
local v = vehicle(111, 1101, 9101, "Base.CarNormal", 1, 1, { "Engine", "Radio" })
local r = rec(claim(OW, v).oid)
cmd(OW, "addMember", { expectedOid = r.oid, username = "rdmem", actionBits = MVM.ACTIONS.PASSENGER })
local function radio(p, mode, device)
    intent(p, "ISRadioAction", v, "Radio")
    return stage(A("ISRadioAction", { character = p, mode = mode, device = device or v.parts.Radio }), "complete")
end
local function ran() return calls("ISRadioAction.complete") end
local n = ran()
check(radio(ST, "AddHeadphones") == false and radio(ST, "RemoveHeadphones") == false and radio(ST, "ToggleOnOff") == false and ran() == n
    and lastOf(ST, "enforcement").reason == "NOT_AUTHORIZED", "陌生人：受保護車上的收音機裝／拆耳機、開關都拒絕，原版 complete 沒跑")
check(radio(OW, "RemoveHeadphones") == true and radio(OW, "ToggleOnOff") == true and ran() == n + 2, "車主：放行")
check(stage(A("ISRadioAction", { character = OW, mode = "AddHeadphones", device = v.parts.Radio }), "complete") == false and ran() == n + 2,
    "車主沒有 intent（冒充）：拒絕")
check(radio(MB, "ToggleOnOff") == true and ran() == n + 3, "只有搭乘權限的成員：可以開關、調台")
check(radio(MB, "RemoveHeadphones") == false and radio(MB, "AddHeadphones") == false and ran() == n + 3, "只有搭乘權限的成員：不能拿走或裝上耳機（要置物）")
local handheld = { _cls = "Radio" }
check(stage(A("ISRadioAction", { character = ST, mode = "RemoveHeadphones", device = handheld }), "complete") == true and ran() == n + 4,
    "手持／擺在地上的收音機（不是車輛零件）：照原版")
ISRadioAction = nil
end)();

(function()
out("情境 G5：租用名額到期鎖定與釋出（RentLock）")
local E, RL = MVM.Econ, MVM.RentLock
local ENT, H = {}, {}
MinidoracatEconomy = { CURRENCIES = { survivor = {} }, v1 = { API_MAJOR = 1, API_REVISION = 2,
    CAPABILITIES = { entitlements = true, rentals = true, setPlan = true },
    registerSource = function()
        return { registerProduct = function() return { ok = true } end,
            getEntitlement = function(user, product)
                if H.throw then error("economy down") end
                if H.fail then return { ok = false, error = H.fail } end
                local e = product == MVM.ECON_PRODUCT and ENT[user] or nil
                return { ok = true, entitlement = e or { usable = 0, rentals = {} } }
            end }
    end } }
boot()
serverMode = true
E.init()
check(E.status == "READY", "假 Economy READY")
local function rent(usable, state, qty, untilMs)
    return { usable = usable, rentals = state and { { id = "r", quantity = qty, state = state, graceUntil = untilMs } } or {} }
end
local ADM, OW, MB, ST = player("radm", 1, 1, { admin = true }), player("rown", 1, 1), player("rmem", 1, 1), player("rstr", 1, 1)
O.mapSet("quotaOverrides", "rown", 1)
ENT.rown = rent(2, "active", 2)
local cars, recs = {}, {}
for i = 1, 3 do
    cars[i] = vehicle(120 + i, 1200 + i, 9200 + i, "Base.CarNormal", 1, 1)
    recs[i] = rec(claim(OW, cars[i]).oid)
end
check(recs[3] and O.quotaLimit("rown") == 3 and O.quotaUsed("rown") == 3, "基本 1＋租用 2：綁滿 3 台")
cmd(OW, "addMember", { expectedOid = recs[3].oid, username = "rmem", actionBits = MVM.ACTIONS.DRIVE })
cmd(OW, "setPublicShare", { expectedOid = recs[3].oid, expectedEpoch = recs[3].epoch, actionBits = MVM.ACTIONS.PASSENGER })
check(S.publicTable()[recs[3].oid] == MVM.ACTIONS.PASSENGER and O.canUse(MB, cars[3], "DRIVE"), "鎖定前：公開與成員權限有效")

local GU = nowMs + 86400000
ENT.rown = rent(2, "grace", 2, GU)
local l0 = #logLines
E.onChanged("rown", MVM.ECON_PRODUCT)
local note = lastOf(OW, "notice")
check(recs[3].lock == "RENT" and recs[2].lock == "RENT" and recs[1].lock == nil and recs[3].lockUntilMs == GU and recs[2].lockUntilMs == GU,
    "租約進入寬限：由新到舊鎖住超出的 2 台，lockUntilMs＝寬限截止")
check(note.key == "IGUI_MVM_Rent_Locked" and note.n == 2 and note.atMs == GU and GH.logged(l0, "RENT_LOCK", recs[3].oid),
    "通知車主 IGUI_MVM_Rent_Locked（台數、截止），稽核 RENT_LOCK")
local ok, why = O.canUse(OW, cars[3], "DRIVE")
check(not ok and why == "RENT_LOCKED" and O.canUse(OW, cars[1], "DRIVE"), "鎖定的車：車主也不能用（RENT_LOCKED）；沒鎖的照常")
ok, why = O.canUse(MB, cars[3], "DRIVE")
check(not ok and why == "RENT_LOCKED" and not O.canUse(ST, cars[3], "PASSENGER") and S.publicTable()[recs[3].oid] == nil,
    "鎖定的車：成員、公開都不能用，公開表撤掉")
check(O.canUse(OW, cars[3], "MANAGE") and cmd(OW, "rename", { expectedOid = recs[3].oid, expectedEpoch = recs[3].epoch, name = "kept" }).ok,
    "鎖定的車：車主管理（MANAGE、改名）照常")
cmd(ADM, "setAdminOverride", { enabled = true })
check(O.canUse(ADM, cars[3], "DRIVE"), "越權中的管理員：可用")
cmd(ADM, "setAdminOverride", { enabled = false })
local row = S.row(recs[3], "rown")
check(row.lock == "RENT" and row.lockUntilMs == GU and S.row(recs[3], "rmem").lock == "RENT", "車隊列帶 lock／lockUntilMs（車主與成員）")
RL.minute()
check(recs[3].recordState == "ACTIVE" and recs[2].recordState == "ACTIVE" and recs[3].lock == "RENT" and RL.watch.rown == true,
    "寬限中每分鐘重算：鎖定不變，絕不釋出")
H.fail = "not_ready"
E.onChanged("rown", MVM.ECON_PRODUCT)
RL.minute()
H.fail, H.throw = nil, true
RL.evaluate("rown")
H.throw = nil
check(recs[3].lock == "RENT" and recs[2].lock == "RENT" and recs[1].lock == nil and recs[3].recordState == "ACTIVE",
    "Economy 讀取失敗或丟錯：什麼都不改")
local n0 = GH.count(OW, "notice")
check(cmd(OW, "unclaim", { vehicleId = cars[1].id, expectedOid = recs[1].oid, expectedEpoch = recs[1].epoch }).ok
    and recs[2].lock == nil and recs[3].lock == "RENT" and lastOf(OW, "notice").key == "IGUI_MVM_Rent_Unlocked"
    and lastOf(OW, "notice").n == 1 and GH.count(OW, "notice") == n0 + 1, "車主解除另一台：最舊的鎖定車解鎖，通知 IGUI_MVM_Rent_Unlocked")
ENT.rown = rent(0, "expired", 2)
E.onChanged("rown", MVM.ECON_PRODUCT)
check(recs[3].lock == "RENT" and recs[3].lockUntilMs == nil and recs[3].recordState == "ACTIVE", "租約到期（還在 Economy 上）：保持鎖定，沒有截止時間")
ENT.rown = rent(0, "pending", 2)
E.onChanged("rown", MVM.ECON_PRODUCT)
check(recs[3].recordState == "ACTIVE" and recs[2].recordState == "ACTIVE", "續租待確認（pending）：不釋出")
ENT.rown = rent(2, "active", 2)
E.onChanged("rown", MVM.ECON_PRODUCT)
check(recs[3].lock == nil and recs[2].lock == nil and O.canUse(OW, cars[3], "DRIVE") and S.publicTable()[recs[3].oid] == MVM.ACTIONS.PASSENGER
    and RL.watch.rown == nil, "續租：全部解鎖，公開恢復")
cars[4] = vehicle(124, 1204, 9204, "Base.CarNormal", 1, 1)
recs[4] = rec(claim(OW, cars[4]).oid)
ENT.rown = rent(2, "grace", 2, GU)
E.onChanged("rown", MVM.ECON_PRODUCT)
check(recs[4].lock == "RENT" and recs[3].lock == "RENT" and recs[2].lock == nil, "再進寬限：最新的兩台鎖住")
cmd(ADM, "adminSetQuota", { usernames = { "rown" }, amount = 2 })
ENT.rown = rent(0, nil)
local box0 = #outbox.rown
E.onChanged("rown", MVM.ECON_PRODUCT)
check(recs[4].recordState == "RELEASED" and recs[4].endReason == "RENT_EXPIRED" and recs[4].lock == nil
    and recs[3].recordState == "ACTIVE" and recs[3].lock == nil and recs[2].recordState == "ACTIVE",
    "租約移除仍超額：釋出 min(鎖定數, 超額) 台最新的鎖定車（RELEASED、RENT_EXPIRED），其餘解鎖")
local keys = {}
for i = box0 + 1, #outbox.rown do
    local m = outbox.rown[i]
    if m.command == "notice" then keys[m.payload.key] = m.payload.n end
end
check(keys.IGUI_MVM_Rent_Released == 1 and keys.IGUI_MVM_Rent_Unlocked == 1 and S.row(recs[4], "rown").endReason == "RENT_EXPIRED",
    "通知 IGUI_MVM_Rent_Released 與 Rent_Unlocked；列帶 endReason")

-- 載著受保護車的拖車：不釋出，保持鎖定
local CO = player("rcar", 1, 1)
O.mapSet("quotaOverrides", "rcar", 1)
ENT.rcar = rent(1, "active", 1)
local cargo, tr = vehicle(131, 1301, 9301, "Base.CarNormal", 1, 1), vehicle(132, 1302, 9302, "Base.Trailer", 1, 1)
local rc, rt = rec(claim(CO, cargo).oid), rec(claim(CO, tr).oid)
O.noteLoad(tr, cargo)
cargo:permanentlyRemove()
check(O.hasCargo(rt), "拖車載著受保護的車")
ENT.rcar = rent(1, "grace", 1, GU)
E.onChanged("rcar", MVM.ECON_PRODUCT)
check(rt.lock == "RENT" and rc.lock == nil, "寬限：鎖住最新的拖車")
ENT.rcar = rent(0, nil)
E.onChanged("rcar", MVM.ECON_PRODUCT)
check(rt.recordState == "ACTIVE" and rt.lock == "RENT" and rc.recordState == "ACTIVE", "租約移除：載著貨的拖車不釋出，保持鎖定")

-- 管理員調降名額、沒有租約：不鎖
local LO = player("rlow", 1, 1)
for i = 1, 3 do claim(LO, vehicle(140 + i, 1400 + i, 9400 + i, "Base.CarNormal", 1, 1)) end
cmd(ADM, "adminSetQuota", { usernames = { "rlow" }, amount = 1 })
E.onChanged("rlow", MVM.ECON_PRODUCT)
RL.evaluate("rlow")
local lowLocked = 0
for _, rr in ipairs(O.R.byOwner.rlow or {}) do if rr.lock then lowLocked = lowLocked + 1 end end
check(O.quotaUsed("rlow") == 3 and lowLocked == 0, "管理員調降名額（沒有租約）：超額也不鎖")

-- 寬限中的名額不能拿來綁新車
local GR = player("rgr", 1, 1)
O.mapSet("quotaOverrides", "rgr", 1)
ENT.rgr = rent(1, "grace", 1, GU)
check(claim(GR, vehicle(151, 1501, 9501, "Base.CarNormal", 1, 1)).ok and O.graceSlots("rgr") == 1, "寬限中：基本名額照常可綁")
local blocked = claim(GR, vehicle(152, 1502, 9502, "Base.CarNormal", 1, 1))
check(blocked.reason == "QUOTA_EXCEEDED" and O.quotaLimit("rgr") == 2, "寬限中的租用名額不能綁新車：QUOTA_EXCEEDED")
H.fail = "x"
check(O.graceSlots("rgr") == 0, "讀取失敗：graceSlots 為 0")
H.fail = nil
ENT.rgr = rent(1, "active", 1)
check(claim(GR, world[152]).ok, "續租後：可以綁")

-- Economy 沒裝：清掉所有租約鎖定
MinidoracatEconomy = nil
E.init()
l0 = #logLines
RL.minute()
check(E.status == "ABSENT" and rt.lock == nil and GH.logged(l0, "RENT_UNLOCK", rt.oid, "ECONOMY_ABSENT"), "Economy 沒裝（ABSENT）：清掉所有租約鎖定並稽核")
end)();

(function()
out("情境 G6：Economy 兩個產品（綁定名額＋保全名額）：註冊、摘要、guardPaid、購買驗證、變更分派、各自的設定檔")
local E, PS, X, P = MVM.Econ, MVM.PaidSlots, MVM.Export, MVM.Parked
local GP = MVM.GUARD_PRODUCT
local function copy(t) local c = {}; for k, v in pairs(t) do c[k] = v end; return c end
local REG, PLANS, REV, CALLS, ENT, H = {}, {}, {}, {}, { [MVM.ECON_PRODUCT] = {}, [GP] = {} }, {}
MinidoracatEconomy = { CURRENCIES = { survivor = {} }, v1 = { API_MAJOR = 1, API_REVISION = 2,
    CAPABILITIES = { entitlements = true, rentals = true, setPlan = true },
    registerSource = function()
        return { registerProduct = function(p)
                REG[#REG + 1] = p
                PLANS[p.id], REV[p.id], CALLS[p.id] = copy(p.defaults), 0, 0
                return { ok = true }
            end,
            getEntitlement = function(user, product)
                if H.fail then return { ok = false, error = H.fail } end
                return { ok = true, entitlement = ENT[product] and ENT[product][user] or { usable = 0, rentals = {} } }
            end,
            getPlan = function(product)
                if PLANS[product] == nil then return { ok = false, error = "unknown_product" } end
                local p = copy(PLANS[product])
                p.revision = REV[product]
                return { ok = true, plan = p }
            end,
            setPlan = function(product, values, opts)
                if PLANS[product] == nil then return { ok = false, error = "unknown_product" } end
                CALLS[product] = CALLS[product] + 1
                if opts.expectedRevision ~= nil and opts.expectedRevision ~= REV[product] then return { ok = false, error = "stale_revision" } end
                PLANS[product], REV[product] = copy(values), REV[product] + 1
                return { ok = true, updated = true, revision = REV[product], changed = { "rentalEnabled" } }
            end,
            setPlanSource = function() return { ok = true } end }
    end } }
boot()
serverMode = true
check(E.guardPaid("g6new") == 0, "Economy 不是 READY、從沒讀到過：guardPaid 0")
for k in pairs(files) do files[k] = nil end
E.init()
local byId = {}
for _, p in ipairs(REG) do byId[p.id] = p end
check(E.status == "READY" and #REG == 2 and byId[MVM.ECON_PRODUCT] and byId[GP] and byId[GP].nameKey == "IGUI_MVM_Product_guard_slot"
    and byId[MVM.ECON_PRODUCT].nameKey == "IGUI_MVM_Product_" .. MVM.ECON_PRODUCT and byId[GP].instant == true
    and byId[MVM.ECON_PRODUCT].instant == true and byId[GP].validatePurchase == E.validatePurchase and byId[GP].defaults == E.DEFAULTS,
    "同一來源註冊兩個產品：nameKey IGUI_MVM_Product_<id>、instant、共用 validatePurchase 與預設方案")
ENT[MVM.ECON_PRODUCT].gp1 = { usable = 3, permanent = 1, rental = 2, rentals = {} }
ENT[GP].gp1 = { usable = 2, permanent = 2, rental = 0, rentals = {} }
local sc, sg = E.summary("gp1"), E.summary("gp1", GP)
check(sc.paid == 3 and sc.rental == 2 and sg.paid == 2 and sg.permanent == 2 and sg.rental == 0 and O.quotaLimit("gp1") == 3 + 3,
    "摘要分產品：綁定名額加到綁定上限，保全名額另計")
check(E.guardPaid("gp1") == 2, "guardPaid：保全產品的 usable")
ENT[GP].gp1.usable = 3
local cachedGP = E.guardPaid("gp1")
E.onChanged("gp1", GP)
check(cachedGP == 2 and E.guardPaid("gp1") == 3,
    "guardPaid 留 GUARD_TTL_MS 不重讀（停車保全每秒排名不打 Economy）；權益變更通知立刻作廢，下一次就是新值")
nowMs = nowMs + E.GUARD_TTL_MS
H.fail = "not_ready"
check(E.guardPaid("gp1") == 3 and E.summary("gp1", GP).economy == "UNAVAILABLE" and E.guardPaid("gp2") == 0,
    "讀取失敗：沿用上次讀到的值（不讓付費保全暫停）；從沒讀到過的人 0")
H.fail = nil
ENT[GP].gp1.usable = 2
E.onChanged("gp1", GP)
SB.ParkedGuard = MVM.GUARD.ALL
local okG, whyG = E.validatePurchase("gp1", GP, "permanent", 1, 3)
check(okG == false and whyG == "GUARD_NOT_SLOTS" and E.validatePurchase("gp1", MVM.ECON_PRODUCT, "permanent", 1, 4) == true,
    "不是 SLOTS：拒絕買保全名額（GUARD_NOT_SLOTS），綁定名額照常")
SB.ParkedGuard = MVM.GUARD.SLOTS
check(E.validatePurchase("gp1", GP, "permanent", 1, 3) == true, "SLOTS：可以買保全名額")

-- 變更分派：保全產品 → 暫停通知；綁定產品 → RentLock 重算
local G3p = player("gp3", 1, 1)
ENT[GP].gp3 = { usable = 1, rentals = {} }
local a1, a2 = rec(claim(G3p, GH.car(161)).oid), rec(claim(G3p, GH.car(162)).oid)
cmd(G3p, "setGuard", { expectedOid = a1.oid, enabled = true })
cmd(G3p, "setGuard", { expectedOid = a2.oid, enabled = true })
check(P.state(a1) == "ON" and P.state(a2) == "ON", "基本 1＋付費 1：兩台都 ON")
ENT[GP].gp3 = { usable = 0, rentals = {} }
-- 沒開車隊視窗（沒有串流）：變更後不重送快照，暫停通知只能來自保全產品的 limitChanged
S.R.streams.gp3 = nil
local n0 = GH.count(G3p, "notice")
E.onChanged("gp3", MVM.ECON_PRODUCT)
check(GH.count(G3p, "notice") == n0, "綁定名額的變更：不走保全暫停通知")
E.onChanged("gp3", GP)
check(GH.count(G3p, "notice") == n0 + 1 and lastOf(G3p, "notice").key == "IGUI_MVM_Guard_Paused" and P.state(a2) == "OVER",
    "保全名額的變更：OVER 變多，通知 IGUI_MVM_Guard_Paused")
local G4p = player("gp4", 1, 1)
O.mapSet("quotaOverrides", "gp4", 0)
ENT[MVM.ECON_PRODUCT].gp4 = { usable = 1, rentals = { { quantity = 1, state = "active" } } }
local b1 = rec(claim(G4p, GH.car(163)).oid)
ENT[MVM.ECON_PRODUCT].gp4 = { usable = 1, rentals = { { quantity = 1, state = "grace", graceUntil = nowMs + 3600000 } } }
E.onChanged("gp4", GP)
check(b1.lock == nil, "保全名額的變更：不重算租約鎖定")
E.onChanged("gp4", MVM.ECON_PRODUCT)
check(b1.lock == "RENT", "綁定名額的變更：RentLock 重算（寬限超額就鎖）")

-- 各自的設定檔與 adminPaidSlots product
local function text(path) return files[path] and table.concat(files[path]) or nil end
PS.start()
nowMs = nowMs + PS.POLL_MS
fire("OnTickEvenPaused")
local CF, GF = X.folder() .. "paid-slots.json", X.folder() .. "guard-slots.json"
check(text(CF) and text(GF) and PS.of[GP].status.source == "created" and PS.of[MVM.ECON_PRODUCT].status.source == "created",
    "兩個產品各建一份設定檔與狀態")
local AD, PL = player("g6adm", 1, 1, { admin = true }), player("g6pl", 1, 1)
local gg, gc = cmd(AD, "adminPaidSlots", { op = "GET", product = GP }), cmd(AD, "adminPaidSlots", { op = "GET" })
check(gg.ok and gg.product == GP and gg.file == "Zomboid/Lua/" .. GF and gg.plan.rentalEnabled == false and gc.product == MVM.ECON_PRODUCT
    and gc.file == "Zomboid/Lua/" .. CF, "GET：product 省略＝綁定名額；guard_slot 回自己的檔案")
check(cmd(PL, "adminPaidSlots", { op = "GET", product = GP }).reason == "NOT_ADMIN", "非管理員：NOT_ADMIN")
local vals = copy(gg.plan)
vals.rentalEnabled = true
local c0 = CALLS[MVM.ECON_PRODUCT]
check(cmd(AD, "adminPaidSlots", { op = "SET", product = "bogus", values = vals, expectedRevision = gg.revision, reason = "x" }).reason
    == "BAD_ARGS" and CALLS[GP] == 0 and CALLS[MVM.ECON_PRODUCT] == c0, "未知產品：BAD_ARGS（SCHEMA），不送 Economy")
local l0 = #logLines
local set = cmd(AD, "adminPaidSlots", { op = "SET", product = GP, values = vals, expectedRevision = gg.revision, reason = "guard sale" })
local back = PS.parse(text(GF):sub(1, -2))
check(set.ok and PLANS[GP].rentalEnabled == true and PLANS[MVM.ECON_PRODUCT].rentalEnabled == false and back.rentalEnabled == true
    and PS.parse(text(CF):sub(1, -2)).rentalEnabled == false and PS.of[GP].status.source == "admin"
    and PS.of[MVM.ECON_PRODUCT].status.source == "created" and GH.logged(l0, "ADMIN_PAID_SLOTS", GP, "guard sale"),
    "SET guard_slot：只改保全產品的方案、寫 guard-slots.json 與它自己的狀態，綁定名額不動；稽核帶產品")
files[GF] = { (PS.encode(PLANS[GP], "external"):gsub('"price": 250', '"price": 300')) .. "\n" }
local g0 = CALLS[GP]
nowMs = nowMs + PS.POLL_MS
fire("OnTickEvenPaused")
check(CALLS[GP] == g0 + 1 and PLANS[GP].rentalPrice == 300 and PLANS[MVM.ECON_PRODUCT].rentalPrice == 250 and PS.of[GP].status.source == "file",
    "外部改 guard-slots.json：輪詢送保全產品的 setPlan")
MinidoracatEconomy = nil
E.init()
SB.ParkedGuard = MVM.GUARD.ALL
end)();

(function()
out("情境 G7：客戶端（保全／鎖定文字、狀態、RENT_LOCKED、通知參數、提示、綁定確認的風險行）")
local F = MVM.FleetUI
local slots = { mode = MVM.GUARD.SLOTS, used = 1, total = 2 }
local own = { role = "OWNER", state = "ACTIVE" }
local function with(t, k, v) local c = {}; for a, b in pairs(t) do c[a] = b end; c[k] = v; return c end
local overText, overToken = F.guardText(with(own, "guard", "OVER"), slots)
check(F.guardText(with(own, "guard", "ON"), slots) == "IGUI_MVM_Guard_On(1,2)" and overText == "IGUI_MVM_Guard_Over(1,2)" and overToken == "accent"
    and F.guardText(own, slots) == "IGUI_MVM_Guard_Off(1,2)" and F.guardText({ role = "OWNER", state = "RELEASED" }, slots) == nil,
    "車主 SLOTS：開／暫停（強調色）／關附已用／總數；已結束的車不寫")
check(F.guardText(with(own, "guard", "ON"), { mode = MVM.GUARD.ALL }) == "IGUI_MVM_Guard_All"
    and F.guardText(own, { mode = MVM.GUARD.OFF }) == nil, "ALL：一句保全中；OFF：不寫")
local mem = { role = "MEMBER", state = "ACTIVE" }
check(F.guardText(with(mem, "guard", "ON"), slots) == "IGUI_MVM_Guard_All" and F.guardText(mem, slots) == nil, "被分享的車：只有 ON 才寫")
local AT = 1790439302927
local t = os.date("*t", math.floor(AT / 1000))
local when = string.format("IGUI_MVM_Date(%d,%02d,%02d) %02d:%02d", t.year, t.month, t.day, t.hour, t.min)
check(F.lockText({ lock = "RENT", lockUntilMs = AT }) == "IGUI_MVM_Lock_Rent(" .. when .. ")" and F.lockText({ lock = "RENT" }) == "IGUI_MVM_Lock_RentEnded"
    and F.lockText({}) == nil, "鎖定行：有截止時間寫日期時間（本機時區）、沒有寫即將解除、沒鎖不寫")
check(F.stateText({ state = "RELEASED", endReason = "RENT_EXPIRED" }, nowMs) == "IGUI_MVM_State_RELEASED_RENT_EXPIRED"
    and F.stateText({ state = "RELEASED" }, nowMs) == "IGUI_MVM_State_RELEASED", "狀態：租用到期釋出另有說法，一般解除照舊")
check(F.stateText({ state = "ACTIVE", lock = "RENT" }, nowMs) == "IGUI_MVM_State_LOCKED" and F.stateToken({ state = "ACTIVE", lock = "RENT" }) == "errorText"
    and F.stateText({ state = "PENDING_RELEASE", lock = "RENT", releaseDueAtMs = nowMs }, nowMs) == "IGUI_MVM_State_PENDING_RELEASE(0)"
    and F.stateToken({ state = "ACTIVE" }) == "text", "狀態：租用鎖定的車在清單與詳情都寫已鎖定（錯誤色）；回報遺失的倒數優先")

local savedIsClient, savedBad, savedGood = isClient, HaloTextHelper.addBadText, HaloTextHelper.addGoodText
isClient = function() return true end
local toast, toastBad
HaloTextHelper.addBadText = function(_, s) toast, toastBad = s, true end
HaloTextHelper.addGoodText = function(_, s) toast, toastBad = s, false end
online = {}
local me = player("gcl", 1, 1)
function me:getRole() return { hasCapability = function(_, cap) return me.admin == true and cap == "ManipulateVehicle" end } end
local function car(id, oid) local v = vehicle(id, 1700 + id, 9700 + id, "Base.CarNormal", 1, 1); rawset(v.parts.Engine.md, "MinidoracatVehicleManager", { oid = oid }); return v end
local vLock, vFree, vMem = car(171, "gLock"), car(172, "gFree"), car(173, "gMem")
MVM.clientReceive("fleetSnapshot", { to = "gcl", streamId = "g7a", seq = 0, guard = { mode = MVM.GUARD.OFF }, rows = {
    { oid = "gLock", role = "OWNER", state = "ACTIVE", name = "Red Truck", lock = "RENT", lockUntilMs = AT },
    { oid = "gFree", role = "OWNER", state = "ACTIVE" },
    { oid = "gMem", role = "MEMBER", state = "ACTIVE", owner = "x", myBits = MVM.ACTIONS.DRIVE, lock = "RENT" } } })
local ok, why = MVM.clientCanUse(me, vLock, "DRIVE")
local okM, whyM = MVM.clientCanUse(me, vMem, "DRIVE")
check(not ok and why == "RENT_LOCKED" and not okM and whyM == "RENT_LOCKED" and MVM.clientCanUse(me, vLock, "MANAGE")
    and MVM.clientCanUse(me, vFree, "DRIVE"), "客戶端：鎖定的車車主與成員都 RENT_LOCKED，MANAGE 照常，沒鎖的照常")
me.admin = true
MVM.clientReceive("adminSnapshot", { to = "gcl", id = "g7s", part = 1, parts = 1, ok = true, rows = {}, players = {}, override = true })
ok, why = MVM.clientCanUse(me, vLock, "DRIVE")
check(ok and why == "ADMIN", "客戶端：越權中的管理員可用鎖定的車")
me.admin = false
MVM.clientReceive("adminSnapshot", { to = "gcl", id = "g7t", part = 1, parts = 1, ok = true, rows = {}, players = {}, override = false })

local notice = MVM.clientHandlers.notice
notice({ to = "gcl", key = "IGUI_MVM_Attack_Guarded", oid = "gLock", who = "mallory", bad = true })
check(toast == "IGUI_MVM_Attack_Guarded(Red Truck,mallory)" and toastBad == true, "通知：參數依序是車名（自己車隊的列）、對方帳號；紅字")
notice({ to = "gcl", key = "K", oid = "nope", who = "w", n = 3, atMs = AT, bad = false })
check(toast == "K(IGUI_MVM_FloatFallback,w,3," .. when .. ")" and toastBad == false, "通知：對不到的車用 FloatFallback；數量、日期時間依序接在後面")
notice({ to = "gcl", key = "IGUI_MVM_Rent_Locked", n = 2, atMs = AT, bad = true })
check(toast == "IGUI_MVM_Rent_Locked(2," .. when .. ")", "通知：只放有的參數（沒有車名與帳號）")
toast = nil
notice({ to = "someone", key = "IGUI_MVM_Guard_Repaired", oid = "gLock" })
notice({ to = "gcl", key = 5 })
check(toast == nil, "通知：不是給本機玩家或沒有 key：不顯示")
local enf = MVM.clientHandlers.enforcement
enf({ to = "gcl", action = "CMD:vehicle.damageWindow", reason = "NOT_AUTHORIZED", guard = true })
local hitText = toast
enf({ to = "gcl", action = "CMD:vehicle.damageWindow", reason = "NOT_AUTHORIZED", guard = false })
local ownedText = toast
local realGetText = getText
getText = function(k, ...) if k == "IGUI_MVM_Reason_RENT_LOCKED" then return "RENT_LOCKED text" end return realGetText(k, ...) end
enf({ to = "gcl", action = "ISUninstallVehiclePart", reason = "RENT_LOCKED" })
getText = realGetText
check(hitText == "IGUI_MVM_Guard_Hit" and ownedText == "IGUI_MVM_Attack_Owned" and toast == "RENT_LOCKED text",
    "提示：砸窗保全中說打不壞、沒保全說已被綁定；RENT_LOCKED 說怎麼解鎖（IGUI_MVM_Reason_RENT_LOCKED）")
local missing = {}
local want = { "IGUI_MVM_Reason_RENT_LOCKED", "IGUI_MVM_Reason_GUARD_FULL", "IGUI_MVM_Reason_GUARD_NOT_SLOTS",
    "IGUI_MVM_State_RELEASED_RENT_EXPIRED", "IGUI_MVM_State_LOCKED", "IGUI_MVM_Product_" .. MVM.ECON_PRODUCT,
    "IGUI_MVM_Product_" .. MVM.GUARD_PRODUCT }
for i = 1, 3 do want[#want + 1] = "IGUI_MVM_ClaimRisk_" .. i; want[#want + 1] = "IGUI_MVM_Disclosure_" .. i end
for _, lang in ipairs({ "CH", "CN", "EN", "JP" }) do
    local fh = io.open(MEDIA .. "/shared/Translate/" .. lang .. "/IG_UI.json")
    local json = fh and fh:read("*a") or ""
    if fh then fh:close() end
    for _, k in ipairs(want) do if not json:find('"' .. k .. '"', 1, true) then missing[#missing + 1] = lang .. ":" .. k end end
end
check(#missing == 0, "組字串用到的翻譯鍵（原因、狀態、產品名、風險行、揭露）四語都有（缺：" .. table.concat(missing, ",") .. "）")

local loose = vehicle(174, 1774, 9774, "Base.CarNormal", 1, 1)
local function snap(id, guard) MVM.clientReceive("fleetSnapshot", { to = "gcl", streamId = id, seq = 0, guard = guard, rows = {} }) end
snap("g7b", { mode = MVM.GUARD.OFF })
local offText = MVM.claimText(0, loose)
snap("g7c", { mode = MVM.GUARD.ALL })
local allText = MVM.claimText(0, loose)
snap("g7d", { mode = MVM.GUARD.SLOTS, used = 1, total = 3 })
local slotText = MVM.claimText(0, loose)
snap("g7e", nil)
SB.ParkedGuard = MVM.GUARD.OFF
local localText = MVM.claimText(0, loose)
SB.ParkedGuard = MVM.GUARD.ALL
check(offText == "IGUI_MVM_ClaimDisclosure\nIGUI_MVM_ClaimRisk_1" and allText == "IGUI_MVM_ClaimDisclosure\nIGUI_MVM_ClaimRisk_2"
    and slotText == "IGUI_MVM_ClaimDisclosure\nIGUI_MVM_ClaimRisk_3(1,3)" and localText == "IGUI_MVM_ClaimDisclosure\nIGUI_MVM_ClaimRisk_1",
    "綁定確認：風險行依伺服器模式（SLOTS 帶保全名額已用／總數），還沒收到快照用本機沙盒")
isClient, HaloTextHelper.addBadText, HaloTextHelper.addGoodText = savedIsClient, savedBad, savedGood
end)();

(function()
out("情境 N1：車主通知紀錄（離線也記、合併、上限與保留天數、已讀、檔案、快照與即時通知帶編號、客戶端未讀與紀錄分頁）")
boot()
local N, P = MVM.Notices, MVM.Parked
for k in pairs(N.cache) do N.cache[k] = nil end
SB.ParkedGuard = MVM.GUARD.ALL
local OW, A1, A2 = player("nown", 1, 1), player("natk", 1, 1), player("natk2", 1, 1)
local v = GH.car(181)
local r = rec(claim(OW, v).oid)
r.customName = "Blue\tVan\n%41" -- 車名可含 TAB、換行（TYPES.text）與 %：檔案逐欄編碼
GH.tick()
local function offline(p) for i = #online, 1, -1 do if online[i] == p then table.remove(online, i) end end end
local function back(p) online[#online + 1] = p end
offline(OW)
local sent0 = GH.count(OW, "notice")
P.onAttack(A1, r.oid)
local list = N.list("nown")
local e = list[1]
check(GH.count(OW, "notice") == sent0 and #list == 1 and e.key == "IGUI_MVM_Attack_Guarded" and e.oid == r.oid and e.who == "natk"
    and e.live == false and e.c == 1 and e.name == "Blue\tVan\n%41" and e.script == r.vehicleScript,
    "車主不在線被攻擊：不送通知，記一筆（哪台車、誰、當時的車名與車型、離線收到）")
nowMs = nowMs + P.NOTICE_MS
P.onAttack(A1, r.oid)
list = N.list("nown")
check(#list == 1 and list[1].c == 2 and list[1].t == nowMs, "同一台車、同一攻擊者 10 分鐘內再攻擊：併成一則（2 次），時間改成最近一次")
nowMs = nowMs + P.NOTICE_MS
P.onAttack(A2, r.oid)
list = N.list("nown")
check(#list == 2 and list[2].who == "natk2" and list[2].c == 1, "換一個攻擊者：另記一則")
nowMs = nowMs + N.MERGE_MS + 1
P.onAttack(A2, r.oid)
list = N.list("nown")
check(#list == 3 and list[3].c == 1 and list[3].id == list[2].id + 1, "隔了 10 分鐘以上：另記一則，編號接續")
for k in pairs(N.cache) do N.cache[k] = nil end
local again = N.list("nown")
check(#again == 3 and again[1].c == 2 and again[1].name == "Blue\tVan\n%41" and again[1].live == false and again[3].id == list[3].id,
    "伺服器重開（清快取）從檔案讀回：次數、車名（TAB、換行、%）、離線旗標、編號都在")
back(OW)
cmd(OW, "fleetSubscribe", {}, false)
local snap = lastOf(OW, "fleetSnapshot")
check(#snap.notices == 3 and snap.noticeRead == 0 and snap.notices[1].who == "natk", "上線：快照帶自己的通知紀錄（舊到新）與已讀時間")
cmd(A1, "fleetSubscribe", {}, false)
check(#lastOf(A1, "fleetSnapshot").notices == 0, "別人的快照不帶這位車主的紀錄")
local n1 = GH.count(OW, "notice")
nowMs = nowMs + P.NOTICE_MS
P.onAttack(A1, r.oid)
local live = lastOf(OW, "notice")
list = N.list("nown")
check(GH.count(OW, "notice") == n1 + 1 and live.id == list[#list].id and live.t == nowMs and live.c == 1 and live.live == true
    and live.name == "Blue\tVan\n%41" and list[#list].live == true,
    "車主在線：即時送通知並記一筆，通知帶紀錄的編號、時間、次數與車名（紀錄分頁同一則）")
offline(OW)
nowMs = nowMs + P.NOTICE_MS
P.onAttack(A1, r.oid)
list = N.list("nown")
check(#list == 4 and list[4].c == 2 and list[4].live == false, "在線看過的那則之後離線又被同一人攻擊：併進同一則，改成離線收到（算未讀）")
back(OW)
local bad1 = cmd(OW, "noticesRead", { upToMs = -1 })
local bad2 = cmd(OW, "noticesRead", { upToMs = "1" })
local bad3 = cmd(OW, "noticesRead", { upToMs = 5, extra = 1 })
check(bad1.reason == "BAD_ARGS" and bad2.reason == "BAD_ARGS" and bad3.reason == "BAD_ARGS" and N.cache.nown.read == 0,
    "noticesRead：只收非負整數毫秒，不收多的欄位")
local ok1 = cmd(OW, "noticesRead", { upToMs = nowMs + 3600000 })
check(ok1.ok and N.cache.nown.read == nowMs, "已讀時間夾到伺服器現在（不能先把之後的通知標成已讀）")
local readAt = N.cache.nown.read
cmd(OW, "noticesRead", { upToMs = 1 })
check(N.cache.nown.read == readAt, "已讀時間不倒退")
for k in pairs(N.cache) do N.cache[k] = nil end
check(select(2, N.list("nown")) == readAt, "已讀時間存在檔案裡")
player("ncap", 1, 1)
offline(online[#online])
for i = 1, N.MAX + 5 do S.notify("ncap", { key = "IGUI_MVM_Rent_Unlocked", n = i, bad = false }) end
list = N.list("ncap")
check(#list == N.MAX and list[1].n == 6 and list[#list].n == N.MAX + 5, "最多留 " .. N.MAX .. " 則：最舊的先刪（沒有車的通知不合併）")
nowMs = nowMs + N.KEEP_MS + 1
check(#N.list("ncap") == 0, "超過保留天數的通知不再列出")
check(N.fileName("Alice") ~= N.fileName("alice") and N.fileName("a/b:c\\d"):match("^%x+$") ~= nil,
    "檔名：大小寫不同的帳號不同檔（Windows 檔名不分大小寫），沒有路徑或保留字元")

local savedIsClient, savedBad, savedGood = isClient, HaloTextHelper.addBadText, HaloTextHelper.addGoodText
isClient = function() return true end
local toasts = {}
HaloTextHelper.addBadText = function(_, s) toasts[#toasts + 1] = s end
HaloTextHelper.addGoodText = function(_, s) toasts[#toasts + 1] = s end
online = {}
player("ncl", 1, 1)
MVM.Client.noticeHinted = nil
local NS = { { id = 1, t = 100, key = "IGUI_MVM_Attack_Guarded", oid = "gone", who = "x", live = false, c = 3, name = "Old Car" },
    { id = 2, t = 200, key = "IGUI_MVM_Guard_Repaired", oid = "here", live = true, c = 1 },
    { id = 3, t = 300, key = "IGUI_MVM_Rent_Unlocked", n = 1, live = false, c = 1 } }
MVM.clientReceive("fleetSnapshot", { to = "ncl", streamId = "n1", seq = 0,
    rows = { { oid = "here", role = "OWNER", state = "ACTIVE", name = "Mine" } }, notices = NS, noticeRead = 150 })
local b = MVM.Client.buckets.ncl
check(MVM.noticeUnread(b) == 1 and MVM.noticeUnreadLocal() == 1 and #toasts == 1 and toasts[1] == "IGUI_MVM_Notice_Offline(1)",
    "登入快照：離線時收到、比已讀時間新的才算未讀（在線看過的不算），提示一次")
check(MVM.noticeText(b, NS[1]) == "IGUI_MVM_Attack_Guarded(Old Car,x)IGUI_MVM_Notice_Times(3)"
    and MVM.noticeText(b, NS[2]) == "IGUI_MVM_Guard_Repaired(Mine)"
    and MVM.noticeText(b, { key = "K", oid = "gone2", script = "Base.Van" }) == "K(Van)",
    "紀錄文字：車還在車隊用現在的名稱，不在了用當時記的車名或車型；併過的加次數")
local notice = MVM.clientHandlers.notice
notice({ to = "ncl", id = 3, t = 400, key = "IGUI_MVM_Rent_Unlocked", n = 1, c = 2, live = false })
notice({ to = "ncl", id = 4, t = 500, key = "IGUI_MVM_Guard_Repaired", oid = "here", c = 1, live = true })
check(#b.notices == 4 and b.notices[3].c == 2 and b.notices[3].t == 400 and b.notices[4].id == 4
    and toasts[#toasts] == "IGUI_MVM_Guard_Repaired(Mine)",
    "即時通知：同編號（伺服器併過）更新原本那則，新的接在最後，照樣跳通知")
local F = MVM.FleetUI
local items = F.noticeItems(b, "", 150)
check(#items == 4 and items[1].e.id == 4 and items[4].e.id == 1 and items[2].unread == true and items[4].unread == false
    and items[1].unread == false, "紀錄分頁：新到舊；打開分頁當時的已讀時間之後、離線時收到的標未讀")
check(#F.noticeItems(b, "old car", 0) == 1, "紀錄分頁：搜尋比對通知文字（不分大小寫）")
MVM.clientReceive("fleetSnapshot", { to = "ncl", streamId = "n2", seq = 0, rows = {}, notices = NS, noticeRead = 0 })
check(#toasts == 3, "之後的快照不再提示離線通知")
isClient, HaloTextHelper.addBadText, HaloTextHelper.addGoodText = savedIsClient, savedBad, savedGood
SB.ParkedGuard = MVM.GUARD.ALL
end)();
out("")
if failures > 0 then
    out(failures .. " 項失敗，" .. passes .. " 項通過")
    os.exit(1)
end
out("全部通過（" .. passes .. " 項）")
