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

SandboxVars = { MinidoracatVehicleManager = { ClaimsPerPlayer = 3, MaxMembersPerVehicle = 6,
    ClaimDistance = 2.5, AllowFactionShare = true, InactivityReleaseDays = 0, InactivityGraceDays = 7,
    ReleaseFinalizeHours = 24, TombstoneRetentionDays = 14, NameMaxBytes = 32 } }
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
            if SBOX.saveOk then SBOX.file = { server = server, ClaimsPerPlayer = SandboxVars.MinidoracatVehicleManager.ClaimsPerPlayer } end
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
    local pt = { id = id, md = {} }
    if id:find("Door", 1, true) then pt.door = door() end
    function pt:getId() return self.id end
    function pt:getVehicle() return self.vehicle end
    function pt:getDoor() return self.door end
    function pt:hasModData() return true end
    function pt:getModData() return self.md end
    return pt
end
local function vehicle(id, sqlId, keyId, script, x, y, partIds)
    local v = { id = id, sqlId = sqlId, keyId = keyId, script = script or "Base.CarNormal", x = x or 0, y = y or 0, z = 0,
        parts = {}, order = {}, removed = false }
    for _, pid in ipairs(partIds or { "Engine", "Battery", "DoorFrontLeft" }) do
        local pt = part(pid); pt.vehicle = v; v.parts[pid] = pt; v.order[#v.order + 1] = pt
    end
    v.seats = {}
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
require("MinidoracatVehicleManager_Economy")
require("MinidoracatVehicleManager_ClaimTags")
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
    O.R.identityConflicts, steamActive = nil, false
    G.R.intents, G.R.due, G.R.lastRun = {}, {}, 0
    MVM.Tracking.last, MVM.Tracking.seat, MVM.Tracking.lastRun = {}, {}, 0
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
        and lastOf(ADMQ, "sandboxSync").claimsPerPlayer == 5, "存檔成功後通知每位線上客戶端同步沙盒值")
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
    MVM.clientReceive("sandboxSync", { to = "alice", claimsPerPlayer = 5 })
    local synced = SBOX.values[QN] == 5 and SB.ClaimsPerPlayer == 5
    MVM.clientReceive("sandboxSync", { to = "alice", claimsPerPlayer = "9" })
    check(synced and SB.ClaimsPerPlayer == 5, "客戶端收到 sandboxSync：set＋toLua 更新本機沙盒，非整數忽略")
    SB.ClaimsPerPlayer, SBOX.values = 3, {}
end
clientSent = {}
MVM.clientReceive("fleetDelta", { to = "alice", streamId = "s1", seq = 2, upserts = { { oid = "o2" } }, removes = {} })
check(Cl.buckets.alice.rows.o2 == nil and clientSent[1] and clientSent[1].command == "fleetResync", "跳號 → 丟棄並 resync")
MVM.clientReceive("fleetDelta", { to = "alice", streamId = "s1", seq = 1, upserts = { { oid = "o2" } }, removes = { "o1" } })
check(Cl.buckets.alice.rows.o2 and Cl.buckets.alice.rows.o1 == nil, "連續 seq 套用 upsert／remove")
do -- 失敗通知：有譯文顯示譯文；沒有譯文才用附代碼的通用說明（原本一律顯示原始代碼）
    local halo, realGetText = nil, getText
    HaloTextHelper.addBadText = function(_, t) halo = t end
    getText = function(key, ...) if key == "IGUI_MVM_Reason_TOO_FAR" then return "walk over" end return realGetText(key, ...) end
    MVM.clientReceive("mutationAck", { to = "alice", requestId = "r-far", ok = false, reason = "TOO_FAR" })
    check(halo == "walk over", "失敗通知顯示原因譯文，不是原始代碼")
    MVM.clientReceive("mutationAck", { to = "alice", requestId = "r-gone", ok = false, reason = "NO_SUCH_RECORD" })
    check(halo == "IGUI_MVM_Failed(NO_SUCH_RECORD)", "沒有譯文的原因退回附代碼的通用說明")
    getText, HaloTextHelper.addBadText = realGetText, function() end
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
-- inactivity
SB.InactivityReleaseDays = 10
online = {}
nowMs = nowMs + 11 * 86400000
O.maintain(true)
check(O.state().ownerActivity.alice.releaseWarnedAtMs > 0 and r.recordState == "ACTIVE", "超過天數先警告，不立刻釋放")
nowMs = nowMs + 8 * 86400000
O.maintain(true)
check(r.recordState == "PENDING_RELEASE" and r.releaseReason == "INACTIVITY", "寬限期後 → PENDING_RELEASE（unloaded 先 pending）")
SB.InactivityReleaseDays = 0

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
check(FU.locationText({ lastKnownX = 10.7, lastKnownY = 20.2, lastKnownAtMs = nowMs - 5 * 60000 }, nowMs) == "IGUI_MVM_Location_LastKnown(10,20,5)", "最後位置與經過分鐘")
check(FU.shareText({ role = "OWNER", grants = {} }) == "IGUI_MVM_Share_Private", "無分享＝私人")
check(FU.shareText({ role = "OWNER", grants = { {}, {} }, factionShare = true, factionState = "SUSPENDED", factionName = "W" })
    == "IGUI_MVM_Share_Members(2) / IGUI_MVM_Share_FactionSuspended(W)", "成員數與陣營暫停一起顯示")
check(FU.shareText({ role = "MEMBER", owner = "carol" }) == "IGUI_MVM_Share_ViaMember(carol)", "成員看到分享者")
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
MinidoracatMiniMapAPI = { markerApiVersion = 1, registerMarkerProvider = function(owner, fn) registered = { owner = owner, fn = fn } end }
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
        [1700000000102] = { OwnerPlayerID = "alice", CarModel = "Base.Van", ClaimDateTime = 1700000000, LastLocationX = 7, LastLocationY = 8 },
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
activeMods["Mysterious Vehicle Claim Key"] = true -- MVCK 還在也能匯入
local im = cmd(AD5, "adminMigration", { op = "IMPORT" })
activeMods["Mysterious Vehicle Claim Key"] = nil
check(im.ok and im.imported == 2 and im.skipped == 1 and im.rebound == 1 and im.pending == 1, "一鍵匯入：兩筆合格、一筆壞資料略過；已載入的車當場轉正")
check(gmd.MVCKByVehicleSQLID ~= nil and gmd.MVCKByVehicleSQLID[1700000000101] ~= nil and gmd.MVCKByPlayerID ~= nil, "不刪 MVCK 原始資料")
local verdict5, rec5 = O.lookup(real)
check(verdict5 == "AUTHORIZED" and rec5.ownerUser == "alice" and witness(real).oid == rec5.oid, "轉正為 alice 的受保護車並寫見證")
local pe = O.state().pendingRebindByLegacyKey[1700000000102]
check(pe.ownerUser == "alice" and pe.vehicleScript == "Base.Van" and pe.AllowDrive == nil and pe.claimedAtMs == 1700000000000,
    "未載入的車留為待轉項，只帶白名單欄位（權限欄位不匯入）")
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
local stepVan = car(6, 3379, "Base.85chevyStepVan", L.c1) -- 正式服撞號：2047 換到 3379，2047 回收給 F350
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
check(stage(a, "complete") == false and calls("ISSmashVehicleWindow.complete") == 0, "ISSmashVehicleWindow（原版無呼叫點、改機可排入）也要權限")
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
                    return { ok = true, entitlement = H.ents[user] or { usable = 0, permanent = 0, rental = 0, pendingQuantity = 0 } }
                end,
                onEntitlementChanged = function(fn)
                    if H.subscribeThrow then error("subscription failed") end
                    H.changed = fn
                end }
        end } }
end
local RICH = { entitlements = true, subscriptions = true }
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

-- 沙盒雙向同步交給 Economy：每個方案欄位都要對到 sandbox-options.txt 的真實選項，且預設值一致
local P = H.product
local fh = io.open((MEDIA:gsub("/lua$", "")) .. "/sandbox-options.txt")
local txt = fh:read("*a")
fh:close()
local defaults = {}
for name, body in txt:gmatch("option MinidoracatVehicleManager%.(%w+)%s*(%b{})") do
    local d = (body:match("default%s*=%s*([^,}]*)"):gsub("%s+$", ""))
    local v = d
    if d == "true" then v = true elseif d == "false" then v = false elseif tonumber(d) then v = tonumber(d) end
    defaults["MinidoracatVehicleManager." .. name] = v
end
local fields, mapped = 0, true
for field, opt in pairs(P.sandbox) do
    if field ~= "revision" then
        fields = fields + 1
        if defaults[opt] == nil or defaults[opt] ~= P.defaults[field] then mapped = false end
    end
end
for field in pairs(P.defaults) do if P.sandbox[field] == nil then mapped = false end end
check(fields == 12 and mapped and P.defaults.revision == nil, "12 個方案欄位都對到真實沙盒選項、預設一致、不含 revision")
check(P.sandbox.revision == "MinidoracatVehicleManager.PaidSlotPlanRevision" and defaults[P.sandbox.revision] == 0,
    "沙盒包含 Economy 管理的版本欄位，購買方案 defaults 不包含 revision")
check(P.defaults.permanentEnabled == false and P.defaults.rentalEnabled == false, "預設兩種販售都關閉，由服主開啟")

-- 上限＝基本＋usable；pending 不計入
local AL = player("alice", 0, 0)
local ADM = player("admin", 0, 0, { admin = true })
local cars = {}
for i = 1, 4 do cars[i] = vehicle(i, 100 + i, 5000 + i, "Base.CarNormal", 1, 1) end
local a1 = claim(AL, cars[1])
check(a1.ok and cmd(AL, "prepareClaim", { vehicleId = 2 }).reason == "QUOTA_EXCEEDED", "沒有付費名額：基本 1 格用完")
check(E.validatePurchase("alice", MVM.ECON_PRODUCT, "permanent", 1, {}) == true, "名額用完仍可購買（買格就是為了提高上限）")
H.ents.alice = { usable = 0, permanent = 0, rental = 0, pendingQuantity = 1, state = "none" }
check(cmd(AL, "prepareClaim", { vehicleId = 2 }).reason == "QUOTA_EXCEEDED", "付款待確認（pending）不計入上限")
H.ents.alice = { usable = 2, permanent = 1, rental = 1, pendingQuantity = 0, state = "active" }
local a2, a3 = claim(AL, cars[2]), claim(AL, cars[3])
check(a2.ok and a3.ok, "已確認永久＋租用：上限＝基本＋usable")
cmd(AL, "fleetSubscribe", {}, false)
local snap = lastOf(AL, "fleetSnapshot")
local q = snap.quota
check(q.base == 1 and q.paid == 2 and q.permanent == 1 and q.rental == 1 and q.total == 3 and q.used == 3
    and q.economy == "READY" and snap.quotaLimit == 3, "fleetSnapshot 名額分項：基本／永久／租用／總計／整合狀態")
cmd(ADM, "adminSetQuota", { usernames = { "alice" }, amount = 0 })
check(O.quotaBase("alice") == 0 and O.quotaLimit("alice") == 2, "管理員個人上限取代基本（絕對值），付費名額照加")
cmd(ADM, "adminSetQuota", { usernames = { "alice" }, amount = -1 })

-- 權益變更推送：只重送該玩家的快照
local n = #outbox.alice
H.ents.alice = { usable = 3, permanent = 2, rental = 1, pendingQuantity = 0, state = "active" }
H.changed("alice", MVM.ECON_PRODUCT, {})
check(#outbox.alice == n + 1 and lastOf(AL, "fleetSnapshot").quota.total == 4, "權益變更：重送該玩家快照，名額即時更新")
H.changed("alice", "other_product", {})
H.changed("bob", MVM.ECON_PRODUCT, {})
check(#outbox.alice == n + 1, "別的產品、沒訂閱的玩家都不推送")

-- 到期／退款／Economy 不可用：只擋新增，既有綁定與管理照常
H.ents.alice = { usable = 1, permanent = 1, rental = 0, pendingQuantity = 0, state = "expired" }
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

-- client：API 探測、可用性提示與購買結果判讀
isClient = function() return true end
assert(loadfile(MEDIA .. "/client/ISUI/MinidoracatVehicleManager_BillingWindow.lua"))()
isClient = function() return false end
local BU = MVM.BillingUI
MinidoracatEconomy = { v1 = { Client = { API_MAJOR = 1, API_REVISION = 1, CAPABILITIES = { wallet = true } } } }
check(BU.api() == nil, "client：舊版 Economy（rev 1）視為不支援")
local ENT = {}
MinidoracatEconomy.v1.Client = { API_MAJOR = 1, API_REVISION = 2, CAPABILITIES = { entitlements = true }, Entitlements = ENT }
check(BU.api() == ENT, "client：rev 2＋entitlements 能力才使用權益 API")
check(BU.blocker(nil, true, {}) == "IGUI_MVM_Loading" and BU.blocker({ economy = "OFF" }, true, {}) == "IGUI_MVM_Slots_SP"
    and BU.blocker({ economy = "UNAVAILABLE" }, true, {}) == "IGUI_MVM_Slots_Unavailable"
    and BU.blocker({ economy = "READY" }, false, nil) == "IGUI_MVM_Slots_Unsupported"
    and BU.blocker({ economy = "READY" }, true, nil) == "IGUI_MVM_Slots_LoadingPrices"
    and BU.blocker({ economy = "READY" }, true, {}) == nil, "付費區塊可用性：server 整合狀態優先，缺 client API 明確提示")
local function durable(s) return { ok = true, snapshot = { entitlement = { durable = { status = s } } } } end
check(BU.purchaseKey({ ok = false, error = "timeout", unknown = true }) == "IGUI_MVM_Slots_NoAnswer"
    and BU.purchaseKey({ ok = false, error = "insufficient_funds" }) == nil
    and BU.purchaseKey(durable("pending")) == "IGUI_MVM_Slots_WaitSave"
    and BU.purchaseKey(durable("confirmed")) == "IGUI_MVM_Slots_Saved"
    and BU.purchaseKey(durable("rolledback")) == "IGUI_MVM_Slots_RolledBack"
    and BU.purchaseKey({ ok = true }) == "IGUI_MVM_Slots_SaveUnknown", "購買結果：逾時＝未知；沒有耐久證明不冒充已保存")

-- 載入真正視窗操作方法；只替代未啟動遊戲時不存在的 UI 建構依賴與 Economy 傳輸。
local savedUI, savedPanel, savedFont = MinidoracatUI, ISPanel, UIFont
local savedWindow, savedBillingUI = MVM.BillingWindow, MVM.BillingUI
MinidoracatUI = { v1 = { API_MAJOR = 1, API_REVISION = 7,
    CAPABILITIES = { window = true, controls = true, dialog = true },
    Theme = { create = function(options) return options end } } }
ISPanel = { derive = function() return {} end }
UIFont = { Small = 1, Medium = 2 }
isClient = function() return true end
assert(loadfile(MEDIA .. "/client/ISUI/MinidoracatVehicleManager_BillingWindow.lua"))()
isClient = function() return false end
local w = setmetatable({ live = true, env = { ok = true, entitlement = {}, plan = {} } }, MVM.BillingWindow)
local purchaseReply, orderReply, requestedOrder
local purchaseCount, quoteCount = 0, 0
ENT.purchase = function(_, _, cb) purchaseCount = purchaseCount + 1; purchaseReply = cb; return "purchase" end
ENT.quote = function() quoteCount = quoteCount + 1; return "quote" end
ENT.getOrder = function(_, _, id, cb) requestedOrder, orderReply = id, cb; return "order" end
ENT.orderOutcome = function(reply)
    local order = reply.order
    if not reply.ok or reply.known ~= true or not order then return "unknown" end
    if order.paid == false and order.final == true then return "not_paid" end
    if (order.status == "paid" or order.status == "refunded") and order.durable.status == "confirmed" then return order.status end
    return "processing"
end
local quote = { id = "quote-1", orderId = "order-1" }
w:purchase(quote)
purchaseReply({ ok = false, error = "timeout", unknown = true })
w:startQuote("permanent")
w:purchase(quote)
check(not w:canPurchase() and w.order.quoteId == "quote-1" and w.order.orderId == "order-1"
    and purchaseCount == 1 and quoteCount == 0, "付款逾時保留原識別，按鈕與直接操作都不能重購")
w.env.entitlement.lastOrderId = "unrelated-renewal"
w:onCheckOrder()
orderReply({ ok = true, known = false, quoteState = "gone" })
check(not w:canPurchase() and requestedOrder == "order-1" and w.order.orderId == "order-1",
    "查無訂單或 gone 不是未付款證明，不能拿別筆續費解鎖")
w:onCheckOrder()
orderReply({ ok = false, unknown = true, error = "timeout" })
check(not w:canPurchase() and w.order.orderId == "order-1", "查詢再次逾時仍保留原付款鎖")
w:onCheckOrder()
orderReply({ ok = true, known = true, order = { orderId = "unrelated-renewal", status = "paid", durable = { status = "confirmed" } } })
check(not w:canPurchase(), "另一筆已保存訂單不能解除本筆未知付款")
w:onCheckOrder()
orderReply({ ok = true, known = true, order = { orderId = "order-1", status = "paid", durable = { status = "pending" } } })
check(not w:canPurchase(), "找到同筆付款但尚待保存，仍禁止再買同商品")
w:onCheckOrder()
orderReply({ ok = true, known = true, order = { orderId = "order-1", status = "rolledback",
    paid = false, final = true, durable = { status = "rolledback" } } })
check(w:canPurchase() and w.order == nil, "server 確認同筆付款回滾才解除付款鎖")
w:purchase(quote)
purchaseReply({ ok = true, orderId = "order-1", snapshot = { entitlement = { durable = { status = "pending" } } } })
check(not w:canPurchase(), "購買受理但 pending 不能再次購買")
w:onCheckOrder()
orderReply({ ok = true, known = true, order = { orderId = "order-1", status = "paid", durable = { status = "confirmed" } } })
check(w:canPurchase(), "查回同筆 paid 且 confirmed 後才開放下一次購買")
w.env.entitlement.pendingOrderId = "server-pending"
w:startQuote("permanent")
check(not w:canPurchase() and quoteCount == 0, "沒有本機訂單但快照仍有 pending，一樣不能重新報價")
w.env.entitlement.pendingOrderId = nil
w:purchase(quote)
purchaseReply({ ok = false, error = "insufficient_funds" })
check(w:canPurchase(), "server 明確拒絕購買且未動款時解除付款鎖")

local consent
w.autoBox = { setChecked = function() end }
ENT.setAutoRenew = function(_, _, enabled, _, _, cb) consent = enabled; cb({ ok = true }); return "consent" end
w.env.plan = { autoRenewAllowed = false, revision = 2 }
w.env.entitlement = { autoRenewState = "paused_terms", autoRenew = true, revision = 1 }
w:onAutoRenew(false)
check(consent == false and w.busy == nil, "不准新開自動續費時，暫停中的原授權仍可取消")
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
MinidoracatUI, ISPanel, UIFont = savedUI, savedPanel, savedFont
MVM.BillingWindow, MVM.BillingUI = savedWindow, savedBillingUI

MinidoracatEconomy = nil
E.init()
SB.ClaimsPerPlayer = 3
end)(); -- 分號：下一個情境也是 IIFE

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
local function launchA(p, trailer) return A("ATAISLaunchVehicle", { character = p, trailer = trailer }) end
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
intent(AM, "ATAISLoadVehicle", acar)
check(stage(loadA(AM, stTr, acar), "complete") == true, "有 TOW 的成員：可把車裝上未綁定的拖車")
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
end)()

out("")
if failures > 0 then
    out(failures .. " 項失敗，" .. passes .. " 項通過")
    os.exit(1)
end
out("全部通過（" .. passes .. " 項）")
