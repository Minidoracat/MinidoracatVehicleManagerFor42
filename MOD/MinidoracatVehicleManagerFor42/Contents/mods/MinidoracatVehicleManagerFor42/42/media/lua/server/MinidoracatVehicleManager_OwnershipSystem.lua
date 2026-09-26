-- 所有權帳本（server-only）：SGlobalObjectSystem 衍生系統只存單一鍵 state（計畫 §4.1），
-- 身分真相鏈 §4.2、狀態機 §4.5、sentinel §4.3、權限 §5。Server.lua 只做命令驗證與投遞，所有判定在這裡。
-- 不讀車身 modData 做授權：client 可經 ObjectModDataPacket 覆寫車身 modData（E2E trust-mp 實證）；
-- 見證寫在零件 modData，只作一致性證據。
if isClient() then return end
require "MinidoracatVehicleManager_API"
require "Map/SGlobalObjectSystem"
require "Vehicles/TimedActions/ISRemoveBurntVehicle"

local MVM = MinidoracatVehicleManager
local O = {}
MVM.Own = O

local SYSTEM_NAME = "MinidoracatVehicleManagerOwnership"
local SENTINEL_KEY = "MinidoracatVehicleManagerSentinel"
local WITNESS_KEY = "MinidoracatVehicleManager"
local WITNESS_HOSTS = { "Engine", "Battery", "TrailerTrunk", "TruckBed" }
local SCHEMA_VERSION = 1
-- 分片（沒有全服綁定上限）：單一 GOS 系統存檔共用 10 MiB SliceBuffer、超過就在「已截斷檔案」後拋錯（SGlobalObjectSystem.java:273-298），
-- 所以大表分散到多個 GOS 系統檔。每片筆數上限依最壞情況估：16 位成員、名稱滿長約 2 KB／筆（Phase 0 實測全欄位 1,717 B），
-- 2000 筆約 4 MB；小項目（登入紀錄、名額、待轉）每筆 ≤150 B，20000 筆約 3 MB，合計仍在 10 MiB 內。
-- 全伺服器的 GOS 系統數（原版 5 個＋所有 MOD）以 1 byte 送給客戶端（SGlobalObjects.java:103-104），客戶端用有號 byte 讀
-- （CGlobalObjects.java:105），超過 127 所有 MOD 的客戶端 GOS 都會壞：開新分片前總數必須低於 systemBudget（留空間給別的 MOD）。
-- 本 MOD 自己最多 60 片（約 12 萬筆）。
O.SHARDED_MAPS = { "recordsByOid", "ownerActivity", "knownUsers", "quotaOverrides", "pendingRebindByLegacyKey", "migratedLegacyIds" }
O.SHARD_LIMITS = { records = 2000, entries = 20000, shards = 60, systemBudget = 100 }
local DAY_MS, HOUR_MS = 86400000, 3600000

O.AUTHORIZABLE = { ACTIVE = true, WITNESS_STALE = true, PENDING_RELEASE = true, QUARANTINED = true }
O.TOMBSTONE = { ORPHANED = true, DESTROYED = true, RELEASED = true }

-- RAM derived state（§4.1）：開機由 recordsByOid 重建，不存檔
local R = { bySqlId = {}, byKeyId = {}, byOwner = {}, status = "INIT", loaded = "none",
    denyAgg = {}, factionRefs = {}, suspectKeys = {}, lastMaintMs = 0, lastScanMs = 0,
    shards = {}, where = {}, st = nil }
O.R = R

local function now() return getTimestampMs() end
local function s(v) if v == nil then return "" end return tostring(v) end

-- ---------------------------------------------------------------- audit ---
-- §14：tab 分隔固定欄位，先清 \r\n\t[]；writeLog 每行 flush、超過 10 MB 截斷，所以 DENY 聚合
local function clean(v) return (s(v):gsub("[\r\n\t%[%]]", "_")) end

function O.audit(severity, event, f)
    f = f or {}
    local pos = ""
    if f.x then pos = math.floor(f.x) .. "," .. math.floor(f.y) .. "," .. math.floor(f.z or 0) end
    local line = table.concat({ clean(now()), clean(severity), clean(event), clean(f.actor), clean(f.role),
        clean(f.oid), clean(f.epoch), clean(f.owner), clean(f.vehicle), clean(pos), clean(f.reason),
        clean(f.count or 1) }, "\t", 1, 12)
    writeLog("MVM", line)
    if severity ~= "INFO" then MVM.log(event .. " " .. clean(f.reason) .. " oid=" .. clean(f.oid)) end
end

function O.deny(actor, action, oid, reason)
    local key = s(actor) .. "|" .. s(action) .. "|" .. s(oid) .. "|" .. s(reason)
    R.denyAgg[key] = (R.denyAgg[key] or 0) + 1
end

local function flushDenies()
    for key, count in pairs(R.denyAgg) do
        local a, act, oid, reason = key:match("^(.-)|(.-)|(.-)|(.*)$")
        O.audit("WARN", "DENY", { actor = a, role = act, oid = oid, reason = reason, count = count })
    end
    R.denyAgg = {}
end

-- ------------------------------------------------------------- identity ---
-- MP：server username；SP：本機 slot（SP 的 username 是角色姓名，換角色即變，§4.4）
function O.principal(player)
    if player == nil then return nil end
    if isServer() then
        local name = player:getUsername()
        if type(name) ~= "string" or name == "" then return nil end
        return name
    end
    return "local:" .. tostring(player:getPlayerNum())
end

function O.isAdmin(player)
    if not isServer() or player == nil or Capability == nil then return false end
    return checkPermissions(player, Capability.ManipulateVehicle) == true
end

-- DropOffWhiteListAfterDeath=true 會刪帳號、同名可重註冊繼承舊車（§4.4）→ 拒新 claim
function O.configBlocked()
    if not isServer() then return false end
    local opts = getServerOptions and getServerOptions()
    return opts ~= nil and opts:getBoolean("DropOffWhiteListAfterDeath") == true
end

-- ------------------------------------------------------------------ GOS ---
local Ledger = SGlobalObjectSystem:derive("MVMOwnershipLedger")

function Ledger:new()
    return SGlobalObjectSystem.new(self, SYSTEM_NAME)
end

-- 主系統只存小的中繼資料（ledgerId、revision、schema、分片數、遷移摘要）；大表在分片系統
local function freshMeta()
    return { schemaVersion = SCHEMA_VERSION, ledgerId = getRandomUUID(), ledgerRevision = 0, shardCount = 1 }
end

-- 分片系統：只存 "data"，不持有全域物件；GOS 會對系統表呼叫下面兩個方法，缺了會拋錯（SGlobalObjectSystem.java:111-162）
local Shard = {}
Shard.__index = Shard
function Shard:getInitialStateForClient() return nil end
function Shard:OnClientCommand(command, playerObj)
    O.deny(playerObj and O.principal(playerObj), "GOS_COMMAND", nil, "GOS_COMMAND_REFUSED")
end
function Shard:isValidIsoObject() return false end
function Shard:OnChunkLoaded() end

local function openShard(k)
    local system = SGlobalObjects.registerSystem(SYSTEM_NAME .. "_" .. k) -- 已存在的分片檔在這裡載入
    system:setModDataKeys({ "data" })
    system:setObjectModDataKeys({})
    system:setObjectSyncKeys({})
    local md = system:getModData()
    setmetatable(md, Shard)
    if type(md.data) ~= "table" then md.data = {} end
    for _, m in ipairs(O.SHARDED_MAPS) do if type(md.data[m]) ~= "table" then md.data[m] = {} end end
    local sh = { data = md.data, records = 0, entries = 0 }
    R.shards[k] = sh
    return sh
end

local function countInto(sh, map, d)
    if map == "recordsByOid" then sh.records = sh.records + d else sh.entries = sh.entries + d end
end

-- 新項目放第一個還有空間的分片；都滿了就開新分片。項目寫入後不再搬動，所以存檔寫到一半當機不會讓項目在分片間遺失
local function pickShard(map)
    local lim = O.SHARD_LIMITS
    for k, sh in ipairs(R.shards) do
        if (map == "recordsByOid" and sh.records < lim.records) or (map ~= "recordsByOid" and sh.entries < lim.entries) then
            return k
        end
    end
    if #R.shards < lim.shards and SGlobalObjects.getSystemCount() < lim.systemBudget then
        local k = #R.shards + 1
        openShard(k)
        R.meta.shardCount = k
        O.audit("WARN", "LEDGER_SHARD", { reason = "opened shard " .. k })
        return k
    end
    -- ponytail: 分片數或全伺服器 GOS 系統數已達上限；只記錄錯誤，放進最空的分片（真的逼近 10 MiB 時要改成拒絕新綁定）
    local best = 1
    for k, sh in ipairs(R.shards) do if sh.records + sh.entries < R.shards[best].records + R.shards[best].entries then best = k end end
    O.audit("ERROR", "LEDGER_SHARD", { reason = "all shards full" })
    return best
end

-- 大表唯一的寫入口：同時改 RAM 的邏輯表與所屬分片（值是同一個 table，事後改欄位會一起存）
function O.mapSet(map, key, value)
    R.st[map][key] = value
    local where = R.where[map]
    local k = where[key]
    if k == nil then
        if value == nil then return end
        k = pickShard(map)
        where[key] = k
        countInto(R.shards[k], map, 1)
    elseif value == nil then
        where[key] = nil
        countInto(R.shards[k], map, -1)
    end
    R.shards[k].data[map][key] = value
end

-- 載入：主系統中繼資料＋全部分片合併成 RAM 邏輯帳本。舊版（未分片、大表在主系統 state 內）一次搬進分片
local function loadLedger(saved)
    R.shards, R.where = {}, {}
    for _, m in ipairs(O.SHARDED_MAPS) do R.where[m] = {} end
    local meta, legacy = nil, nil
    if type(saved) == "table" and type(saved.ledgerId) == "string" then
        meta = saved
        if type(saved.recordsByOid) == "table" then legacy = saved end
    end
    local fresh = meta == nil
    meta = meta or freshMeta()
    R.meta = meta
    -- 邏輯帳本：大表是自己的欄位，其餘欄位讀寫都落到中繼資料（主系統存檔的就是 meta）
    local st = setmetatable({}, { __index = meta, __newindex = meta })
    for _, m in ipairs(O.SHARDED_MAPS) do rawset(st, m, {}) end
    R.st = st
    for k = 1, math.max(1, MVM.isInt(meta.shardCount) and meta.shardCount or 1) do
        local sh = openShard(k)
        for _, m in ipairs(O.SHARDED_MAPS) do
            local t, where, dup = sh.data[m], R.where[m], nil
            for key, value in pairs(t) do
                if where[key] == nil then
                    where[key] = k
                    st[m][key] = value
                    countInto(sh, m, 1)
                else
                    dup = dup or {}
                    dup[#dup + 1] = key
                end
            end
            for _, key in ipairs(dup or {}) do t[key] = nil end -- 同鍵出現在兩片（不該發生）：留第一片
        end
    end
    meta.shardCount = #R.shards
    if legacy then
        for _, m in ipairs(O.SHARDED_MAPS) do
            local t = legacy[m]
            legacy[m] = nil
            for key, value in pairs(type(t) == "table" and t or {}) do O.mapSet(m, key, value) end
        end
    end
    meta.schemaVersion = meta.schemaVersion or SCHEMA_VERSION
    return fresh
end

function Ledger:initSystem()
    SGlobalObjectSystem.initSystem(self)
    -- 只白名單 state：漏掉這步＝本場正常、重啟後整庫消失（SGlobalObjectSystem.save 只存白名單）
    self.system:setModDataKeys({ "state" })
    self.system:setObjectModDataKeys({})
    self.system:setObjectSyncKeys({})
    local fresh = loadLedger(self.state)
    self.state = R.meta
    R.loaded = fresh and "fresh" or "disk"
    R.status = "INIT"
    -- 原版在 new() 回傳後才設 instance（SGlobalObjectSystem.lua:246），此時 O.state() 還是 nil：
    -- 不先設，rebuildIndex 空手而回，重啟後帳本在、索引空，車被當孤兒見證剝除（E2E phase1-mp 實踩）
    Ledger.instance = self
    O.rebuildIndex()
    MVM.log("ledger " .. R.loaded .. " ledgerId=" .. s(R.meta.ledgerId) .. " revision=" .. s(R.meta.ledgerRevision)
        .. " shards=" .. #R.shards)
end

function Ledger:getInitialStateForClient() return nil end
function Ledger:isValidIsoObject() return false end
function Ledger:newLuaObject() error("the ownership ledger owns no global objects") end
function Ledger:OnChunkLoaded() end
-- generic GlobalObjects client command 是真 C2S 入口（§4.3）：只計數＋audit，不改、不回
function Ledger:OnClientCommand(command, playerObj)
    -- 聚合進每分鐘的 DENY（逐包寫 audit 會被灌爆；命令名不進聚合鍵，避免任意字串撐大表）
    O.deny(playerObj and O.principal(playerObj), "GOS_COMMAND", nil, "GOS_COMMAND_REFUSED")
end

SGlobalObjectSystem.RegisterSystemClass(Ledger)
O.Ledger = Ledger

function O.state()
    return Ledger.instance and R.st or nil
end

-- ------------------------------------------------------------- sentinel ---
local function sentinel() return ModData.getOrCreate(SENTINEL_KEY) end

local function writeSentinel(st)
    local sn = sentinel()
    local n = 0
    for _ in pairs(st.recordsByOid) do n = n + 1 end
    sn.installed, sn.ledgerId, sn.ledgerRevision, sn.recordCount, sn.schemaVersion =
        true, st.ledgerId, st.ledgerRevision, n, st.schemaVersion
end

-- §4.3 載入判定；GOS 與 GMD 都載入後才可判斷，所以第一次需要帳本時才做
function O.ready()
    if R.status == "READY" then return true end
    if R.status == "RECOVERY_REQUIRED" then return false, "RECOVERY_REQUIRED" end
    local st = O.state()
    if st == nil then return false, "NOT_READY" end
    local sn = sentinel()
    local bad = nil
    if sn.installed then
        if R.loaded == "fresh" then bad = "SENTINEL_WITHOUT_LEDGER"
        elseif sn.ledgerId ~= st.ledgerId then bad = "LEDGER_ID_MISMATCH"
        elseif (sn.ledgerRevision or 0) > st.ledgerRevision then bad = "LEDGER_OLDER_THAN_SENTINEL" end
    end
    if bad then
        R.status = "RECOVERY_REQUIRED"
        O.audit("ERROR", "RECOVERY_REQUIRED", { reason = bad })
        MVM.log("RECOVERY REQUIRED (" .. bad .. "): all ownership changes are refused. Restore the whole world save, vehicles.db, gos_*.bin and global_mod_data.bin from one backup.")
        return false, "RECOVERY_REQUIRED"
    end
    writeSentinel(st)
    R.status = "READY"
    return true
end

-- ledgerRevision 只供 save／recovery 比對（§6.2）。READY 之前（載入判定尚未完成）不推進、不寫 sentinel：
-- 否則開機期的 quarantine 會蓋掉 sentinel、掩蓋「GOS 比 sentinel 舊」，全新安裝也會被誤判成缺帳本
function O.bump(record)
    if record then record.revision = (record.revision or 0) + 1 end
    if R.status ~= "READY" then return end
    local st = O.state()
    st.ledgerRevision = st.ledgerRevision + 1
    writeSentinel(st)
end

-- --------------------------------------------------------------- indexes ---
local function addToList(map, key, rec)
    local list = map[key]
    if list == nil then list = {}; map[key] = list end
    list[#list + 1] = rec
end

local function quarantine(rec, reason)
    if rec.recordState == "QUARANTINED" then return end
    rec.recordState = "QUARANTINED"
    rec.quarantineReason = reason
    O.bump(rec)
    O.audit("ERROR", "QUARANTINE", { oid = rec.oid, owner = rec.ownerUser, reason = reason })
end

-- §4.2 規則 0／7：只索引可授權狀態；同 sqlId 兩筆或缺必要欄位 → quarantine
function O.rebuildIndex()
    local st = O.state()
    R.bySqlId, R.byKeyId, R.byOwner = {}, {}, {}
    if st == nil then return end
    for _, rec in pairs(st.recordsByOid) do
        if rec.ownerUser ~= nil then addToList(R.byOwner, rec.ownerUser, rec) end
        if O.AUTHORIZABLE[rec.recordState] then
            if not MVM.isInt(rec.sqlIdHint) or not MVM.isInt(rec.keyIdHint) or type(rec.vehicleScript) ~= "string" then
                quarantine(rec, "SCHEMA_INVALID")
            end
            addToList(R.bySqlId, rec.sqlIdHint, rec)
            R.byKeyId[rec.keyIdHint] = rec.sqlIdHint
        end
    end
    for _, list in pairs(R.bySqlId) do
        if #list > 1 then for _, rec in ipairs(list) do quarantine(rec, "DUPLICATE_SQLID") end end
    end
end

local function unindex(rec)
    local list = R.bySqlId[rec.sqlIdHint]
    if list then
        for i = #list, 1, -1 do if list[i] == rec then table.remove(list, i) end end
        if #list == 0 then R.bySqlId[rec.sqlIdHint] = nil end
    end
end

-- -------------------------------------------------------------- witness ---
local function native(vehicle) return vehicle:getSqlId(), vehicle:getKeyId(), vehicle:getScriptName() end

function O.hostPart(vehicle, partId)
    if partId ~= nil then return vehicle:getPartById(partId) end
    for _, id in ipairs(WITNESS_HOSTS) do
        local part = vehicle:getPartById(id)
        if part ~= nil then return part end
    end
    if vehicle:getPartCount() > 0 then return vehicle:getPartByIndex(0) end
    return nil
end

-- modData 是 Kahlua table：用 rawget／rawset（家族踩坑）
local function readWitness(part)
    if part == nil or not part:hasModData() then return nil end
    local w = rawget(part:getModData(), WITNESS_KEY)
    if type(w) ~= "table" then return nil end
    return w
end

local function writeWitness(vehicle, part, rec)
    rawset(part:getModData(), WITNESS_KEY, { oid = rec.oid, epoch = rec.epoch })
    vehicle:transmitPartModData(part)
end

local function stripWitness(vehicle, part)
    if part == nil or readWitness(part) == nil then return end
    rawset(part:getModData(), WITNESS_KEY, nil)
    vehicle:transmitPartModData(part)
end
O.stripWitness = stripWitness

-- --------------------------------------------------------- transitions ---
-- 所有狀態轉移經此：寫 audit、推進 revision、維護索引；投影推送由呼叫端（Server）負責
function O.setState(rec, newState, reason, fields)
    local old = rec.recordState
    rec.recordState = newState
    if O.TOMBSTONE[newState] then
        rec.endedAtMs = now()
        unindex(rec)
    end
    if newState ~= "PENDING_RELEASE" then rec.pendingReleaseAtMs, rec.releaseDueAtMs, rec.releaseReason = 0, 0, nil end
    O.bump(rec)
    local f = fields or {}
    f.oid, f.epoch, f.owner, f.reason = rec.oid, rec.epoch, rec.ownerUser, (reason or old .. "->" .. newState)
    O.audit("INFO", newState == "PENDING_RELEASE" and "PENDING_RELEASE" or "STATE", f)
    if O.onRecordChanged then O.onRecordChanged(rec, nil) end
end

local function markObserved(rec, vehicle)
    rec.lastObservedSqlIdAtMs = now()
    if rec.recordState == "PENDING_RELEASE" then
        -- 期間內觀測到同一台車 → 取消 finalize，owner 要到車旁 unclaim（§4.5）
        O.setState(rec, "ACTIVE", "RELEASE_CANCELLED_OBSERVED")
    end
end

-- ---------------------------------------------------------------- lookup ---
-- §4.2 server lookup 規則 0-8。授權只看 ledger＋三個 native 欄位；見證只區分 ACTIVE／WITNESS_STALE 與規則 4／5。
-- 回傳 verdict, record：AUTHORIZED／QUARANTINED 帶 record，其餘為 UNCLAIMED*（record=nil）
function O.lookup(vehicle)
    local writable = O.ready()
    local sqlId, keyId, script = native(vehicle)
    local list = R.bySqlId[sqlId]
    if list ~= nil and #list > 1 then
        if writable then for _, rec in ipairs(list) do quarantine(rec, "DUPLICATE_SQLID") end end
        return "QUARANTINED", list[1]
    end
    if not writable then
        -- RECOVERY_REQUIRED／未就緒：以記憶體中的帳本照常執法，但不改任何狀態、不剝見證
        local r0 = list and list[1] or nil
        if r0 and r0.keyIdHint == keyId and r0.vehicleScript == script then
            return r0.recordState == "QUARANTINED" and "QUARANTINED" or "AUTHORIZED", r0
        end
        return "UNCLAIMED", nil
    end
    local rec = list and list[1] or nil
    local host = O.hostPart(vehicle, rec and rec.witnessPartId or nil)
    local w = readWitness(host)
    if rec == nil then
        if w ~= nil then
            -- 規則 6：沒有 record 的見證沒有權威，剝除即可
            stripWitness(vehicle, host)
            O.audit("WARN", "ORPHAN_WITNESS_STRIPPED", { vehicle = sqlId, oid = w.oid })
            return "UNCLAIMED_WITNESS_STRIPPED", nil
        end
        -- Phase 5：MVCK 待轉項在車第一次被觀測時轉正
        if O.rebindHook then
            local rebound = O.rebindHook(vehicle)
            if rebound then return "AUTHORIZED", rebound end
        end
        local other = R.byKeyId[keyId]
        if other ~= nil and other ~= sqlId and not R.suspectKeys[keyId] then
            R.suspectKeys[keyId] = true
            O.audit("WARN", "KEYID_COLLISION_SUSPECT", { vehicle = sqlId, reason = "keyId shared with sqlId " .. s(other) })
        end
        return "UNCLAIMED", nil
    end
    if rec.keyIdHint == keyId and rec.vehicleScript == script then
        -- 規則 2：三欄位一致＝就是這台車
        if rec.recordState == "QUARANTINED" then return "QUARANTINED", rec end
        markObserved(rec, vehicle)
        if w == nil or w.oid ~= rec.oid or w.epoch ~= rec.epoch then
            -- 規則 3：照常執法，只在第一次變化時記一筆
            if rec.recordState == "ACTIVE" then
                O.setState(rec, "WITNESS_STALE", "WITNESS_MISMATCH")
            end
        end
        return "AUTHORIZED", rec
    end
    -- 同 sqlId、keyId 或 script 不同：VehiclesDB2 回收了 sqlId
    O.setState(rec, "ORPHANED", "SQLID_RECYCLED", { vehicle = sqlId })
    if w ~= nil and w.oid == rec.oid then
        -- 規則 5：別台車帶著這筆紀錄的見證＝證據衝突
        local q = O.newRecord(nil, vehicle, host)
        q.recordState = "QUARANTINED"
        q.quarantineReason = "WITNESS_CONFLICT"
        O.mapSet("recordsByOid", q.oid, q)
        R.bySqlId[sqlId] = { q }
        O.bump(q)
        O.audit("ERROR", "QUARANTINE", { oid = q.oid, vehicle = sqlId, reason = "WITNESS_CONFLICT" })
        return "QUARANTINED", q
    end
    return "UNCLAIMED_ORPHANED_OLD", nil
end

-- ---------------------------------------------------------------- records ---
function O.newRecord(owner, vehicle, host)
    local sqlId, keyId, script = native(vehicle)
    local t = now()
    return { oid = getRandomUUID(), epoch = getRandomUUID(), recordState = "ACTIVE", ownerUser = owner,
        claimedAtMs = t, sqlIdHint = sqlId, keyIdHint = keyId, vehicleScript = script,
        witnessPartId = host and host:getId() or nil, customName = "", grants = {}, factionShare = false,
        factionState = "NONE", factionActionBits = 0,
        lastKnownX = vehicle:getX(), lastKnownY = vehicle:getY(), lastKnownZ = vehicle:getZ(), lastKnownAtMs = t,
        lastObservedSqlIdAtMs = t, pendingReleaseAtMs = 0, releaseDueAtMs = 0, revision = 1 }
end

function O.countsForQuota(rec) return O.AUTHORIZABLE[rec.recordState] == true end

function O.quotaUsed(owner)
    local n = 0
    for _, rec in ipairs(R.byOwner[owner] or {}) do if O.countsForQuota(rec) then n = n + 1 end end
    if O.pendingCount then n = n + O.pendingCount(owner) end
    return n
end

function O.quotaLimit(owner)
    local override = O.state().quotaOverrides[owner]
    if MVM.isInt(override) then return override end
    return MVM.sandbox("ClaimsPerPlayer", 3)
end

-- claim 前置條件（不含車輛本身的檢查）
function O.claimBlocked(owner)
    local ok, reason = O.ready()
    if not ok then return reason end
    if O.configBlocked() then return "CONFIG_BLOCKED" end
    if O.quotaUsed(owner) >= O.quotaLimit(owner) then return "QUOTA_EXCEEDED" end
    return nil
end

-- 綁定成功：寫 record、索引、見證（§7.1 step 5）
function O.createRecord(owner, vehicle, host)
    local st = O.state()
    local rec = O.newRecord(owner, vehicle, host)
    O.mapSet("recordsByOid", rec.oid, rec)
    R.bySqlId[rec.sqlIdHint] = { rec }
    R.byKeyId[rec.keyIdHint] = rec.sqlIdHint
    addToList(R.byOwner, owner, rec)
    if st.ownerActivity[owner] == nil then
        O.mapSet("ownerActivity", owner, { lastSuccessfulLoginAtMs = now(), releaseWarnedAtMs = 0 })
    end
    writeWitness(vehicle, host, rec)
    O.bump(rec)
    return rec
end

-- 換新 epoch 並重寫見證（reissueWitness／transfer／admin activate）
function O.rewriteWitness(rec, vehicle)
    local host = O.hostPart(vehicle, rec.witnessPartId) or O.hostPart(vehicle, nil)
    if host == nil then return false end
    rec.witnessPartId = host:getId()
    rec.epoch = getRandomUUID()
    writeWitness(vehicle, host, rec)
    return true
end

function O.removeRecord(rec)
    unindex(rec)
    O.mapSet("recordsByOid", rec.oid, nil)
    local list = R.byOwner[rec.ownerUser]
    if list then for i = #list, 1, -1 do if list[i] == rec then table.remove(list, i) end end end
    O.bump(nil)
end

-- 換 owner（transfer）：byOwner 索引跟著搬
function O.reown(rec, newOwner)
    local list = R.byOwner[rec.ownerUser]
    if list then for i = #list, 1, -1 do if list[i] == rec then table.remove(list, i) end end end
    rec.ownerUser = newOwner
    addToList(R.byOwner, newOwner, rec)
    local st = O.state()
    if st.ownerActivity[newOwner] == nil then
        O.mapSet("ownerActivity", newOwner, { lastSuccessfulLoginAtMs = now(), releaseWarnedAtMs = 0 })
    end
end

-- --------------------------------------------------------------- faction ---
local function factionHas(f, user) return f:getOwner() == user or f:isMember(user) end

-- §5.1 F10：同名陣營存在＋leader 未變＋owner 與 actor 都是成員。
-- rename／disband／換 leader／同進程內同名重建 → 持久化 SUSPENDED；owner 暫離只拒絕、回來即恢復
function O.factionAllows(rec, actorName)
    if not rec.factionShare or rec.factionState ~= "GRANTED" or not MVM.sandbox("AllowFactionShare", true) then return false end
    local f = Faction.getFaction(rec.factionName)
    local ref = R.factionRefs[rec.oid]
    if f == nil or f:getOwner() ~= rec.factionOwnerUser or (ref ~= nil and ref ~= f) then
        if R.status == "READY" then
            rec.factionState = "SUSPENDED"
            R.factionRefs[rec.oid] = nil
            O.bump(rec)
            O.audit("WARN", "ACL_CHANGE", { oid = rec.oid, owner = rec.ownerUser, reason = "FACTION_SUSPENDED" })
            if O.onRecordChanged then O.onRecordChanged(rec, nil) end
        end
        return false
    end
    R.factionRefs[rec.oid] = f
    return factionHas(f, rec.ownerUser) and factionHas(f, actorName)
end

-- 目前的陣營成員（供投影與追蹤收件者計算）；有效條件與 factionAllows 一致：
-- 沙盒允許、同名陣營存在、領袖未變、不是同進程內解散後重建的新物件。不成立時回空（不在這裡寫帳本）
function O.factionMembers(rec)
    local out = {}
    if not rec.factionShare or rec.factionState ~= "GRANTED" or not MVM.sandbox("AllowFactionShare", true) then return out end
    local f = Faction.getFaction(rec.factionName)
    local ref = R.factionRefs[rec.oid]
    if f == nil or f:getOwner() ~= rec.factionOwnerUser or (ref ~= nil and ref ~= f) then return out end
    out[f:getOwner()] = true
    local players = f:getPlayers()
    for i = 0, players:size() - 1 do out[players:get(i)] = true end
    return out
end

function O.grantBits(rec, user)
    for _, g in ipairs(rec.grants or {}) do if g.user == user then return g.bits end end
    return nil
end

-- --------------------------------------------------------------- canUse ---
-- 權威授權。回 allowed, reason, record
function O.canUse(actor, vehicle, action, context)
    if MVM.ACTIONS[action] == nil then return false, "UNKNOWN_ACTION" end
    if actor == nil or vehicle == nil then return false, "BAD_TARGET" end
    if O.state() == nil then return false, "NOT_READY" end
    local verdict, rec = O.lookup(vehicle)
    if rec == nil then return true, "UNCLAIMED" end
    local who = O.principal(actor)
    local admin = O.isAdmin(actor)
    local silent = context ~= nil and context.silent == true -- watchdog 每秒查：不重複寫 bypass
    if rec.recordState == "QUARANTINED" then
        if admin then
            if not silent then O.audit("WARN", "ADMIN_BYPASS", { actor = who, oid = rec.oid, owner = rec.ownerUser, reason = action }) end
            return true, "ADMIN", rec
        end
        O.deny(who, action, rec.oid, "QUARANTINED")
        return false, "QUARANTINED", rec
    end
    if who ~= nil and who == rec.ownerUser then return true, "OWNER", rec end
    if admin then
        if not silent then
            O.audit("WARN", "ADMIN_BYPASS", { actor = who, oid = rec.oid, owner = rec.ownerUser,
                reason = action .. (context and context.mod and (" " .. s(context.mod)) or "") })
        end
        return true, "ADMIN", rec
    end
    if action ~= "MANAGE" then
        local bits = O.grantBits(rec, who)
        if bits ~= nil and MVM.bitsAllow(bits, action) then return true, "MEMBER", rec end
        if MVM.bitsAllow(rec.factionActionBits or 0, action) and O.factionAllows(rec, who) then return true, "FACTION", rec end
    end
    O.deny(who, action, rec.oid, "NOT_AUTHORIZED")
    return false, "NOT_AUTHORIZED", rec
end

-- server 端公開 API 換成權威實作（§8.1.1）
MinidoracatVehicleManagerAPI.canUse = function(actor, vehicle, actionCode, context)
    local ok, reason = O.canUse(actor, vehicle, actionCode, context)
    return ok, reason
end

-- ----------------------------------------------------------- maintenance ---
-- 每分鐘（牆鐘節流）：finalize PENDING_RELEASE、清 tombstone、inactivity、聚合 DENY
function O.maintain(force)
    local t = now()
    if not force and t - R.lastMaintMs < 60000 then return end
    R.lastMaintMs = t
    flushDenies()
    if not O.ready() then return end
    local st = O.state()
    local retention = MVM.sandbox("TombstoneRetentionDays", 14) * DAY_MS
    local inactDays = MVM.sandbox("InactivityReleaseDays", 0)
    local graceMs = MVM.sandbox("InactivityGraceDays", 7) * DAY_MS
    local expiredOwners = {}
    if inactDays > 0 then
        for owner, act in pairs(st.ownerActivity) do
            if t - (act.lastSuccessfulLoginAtMs or t) > inactDays * DAY_MS then
                if (act.releaseWarnedAtMs or 0) == 0 then
                    act.releaseWarnedAtMs = t
                    O.bump(nil)
                    O.audit("WARN", "INACTIVITY_WARNING", { owner = owner })
                elseif t - act.releaseWarnedAtMs > graceMs then
                    expiredOwners[owner] = true
                end
            end
        end
    end
    local drop = {}
    for _, rec in pairs(st.recordsByOid) do
        local state = rec.recordState
        if state == "PENDING_RELEASE" and t >= (rec.releaseDueAtMs or 0) then
            O.setState(rec, "RELEASED", "RELEASE_FINALIZED")
        elseif (state == "ACTIVE" or state == "WITNESS_STALE") and expiredOwners[rec.ownerUser] then
            O.beginRelease(rec, "INACTIVITY")
        elseif O.TOMBSTONE[state] and t - (rec.endedAtMs or t) > retention then
            drop[#drop + 1] = rec
        end
    end
    for _, rec in ipairs(drop) do O.removeRecord(rec) end
    -- ownerActivity 只留仍有紀錄的 owner（§4.1 容量上界）
    local idle = {}
    for owner in pairs(st.ownerActivity) do
        local list = R.byOwner[owner]
        if list == nil or #list == 0 then idle[#idle + 1] = owner end
    end
    for _, owner in ipairs(idle) do O.mapSet("ownerActivity", owner, nil) end
end

function O.beginRelease(rec, reason)
    local t = now()
    rec.pendingReleaseAtMs = t
    rec.releaseDueAtMs = t + MVM.sandbox("ReleaseFinalizeHours", 24) * HOUR_MS
    rec.releaseReason = reason
    O.setState(rec, "PENDING_RELEASE", reason)
end

-- 曾登入過本伺服器的帳號（本 MOD 啟用後）：伺服器 Lua 查不到離線帳號（白名單只以封包送給管理員客戶端，
-- NetworkUsersPacket.java:26-60），分享與轉讓用這份名單擋掉打錯的名字，免得日後同名新帳號拿到權限。
-- ponytail: 名單只增不減，每人幾十 bytes；上萬人才需要依最後上線時間清理
function O.noteUser(who)
    local st = O.state()
    if st == nil or R.status ~= "READY" or st.knownUsers[who] ~= nil then return end
    O.mapSet("knownUsers", who, now())
    O.bump(nil)
end

-- 分享／轉讓對象是否存在：在線、曾登入過、或本來就是車主
function O.knownUser(who, online)
    local st = O.state()
    return (online and online[who] ~= nil) or (st ~= nil and (st.knownUsers[who] ~= nil or st.ownerActivity[who] ~= nil))
end

-- 登入觀測：online 名單中的 owner 更新 lastSuccessfulLoginAtMs、清 warning
function O.observeLogin(owner)
    local st = O.state()
    local act = st and st.ownerActivity[owner]
    if act == nil then return end
    act.lastSuccessfulLoginAtMs = now()
    if (act.releaseWarnedAtMs or 0) ~= 0 then act.releaseWarnedAtMs = 0; O.bump(nil) end
end

-- 已載入車輛：reconcile 身分並低頻收斂 lastKnown（§7.3：不存每次 sample）
function O.observeVehicle(vehicle)
    if not O.ready() then return end
    local verdict, rec = O.lookup(vehicle)
    if rec == nil or verdict ~= "AUTHORIZED" then return end
    local x, y = vehicle:getX(), vehicle:getY()
    if math.abs(x - (rec.lastKnownX or 0)) + math.abs(y - (rec.lastKnownY or 0)) >= 2 then
        rec.lastKnownX, rec.lastKnownY, rec.lastKnownZ, rec.lastKnownAtMs = x, y, vehicle:getZ(), now()
        O.bump(rec)
        if O.onRecordChanged then O.onRecordChanged(rec, nil) end
        if O.onPositionSaved then O.onPositionSaved(rec) end -- 位置日誌：崩潰沒存檔時用來補回（Export.lua）
    end
end

-- 每 10 分鐘掃一次已載入車輛；IsoCell.getVehicles 在 42.20.4 是 Set，只能用 iterator
function O.scanLoaded(force)
    local t = now()
    if not force and t - R.lastScanMs < 600000 then return end
    R.lastScanMs = t
    local it = getCell():getVehicles():iterator()
    while it:hasNext() do O.observeVehicle(it:next()) end
end

-- 燒毀車移除（§4.2）：只有對同一物件三欄位全合時才 DESTROYED；不做 keyId 推論式終態
local removeBurnt = ISRemoveBurntVehicle.complete
function ISRemoveBurntVehicle:complete()
    local rec = nil
    if self.vehicle and O.state() and O.ready() then
        local verdict, r = O.lookup(self.vehicle)
        if verdict == "AUTHORIZED" then rec = r end
    end
    local result = removeBurnt(self)
    if rec and self.vehicle:isRemovedFromWorld() and O.AUTHORIZABLE[rec.recordState] then
        O.setState(rec, "DESTROYED", "BURNT_REMOVED", { actor = O.principal(self.character) })
    end
    return result
end
