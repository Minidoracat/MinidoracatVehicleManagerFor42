-- 所有權帳本（server-only）：SGlobalObjectSystem 衍生系統只存單一鍵 state（計畫 §4.1），
-- 身分真相鏈 §4.2、狀態機 §4.5、sentinel §4.3、權限 §5（含租用名額到期鎖定 rec.lock）。Server.lua 只做命令驗證與投遞，所有判定在這裡。
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
O.SHARDED_MAPS = { "recordsByOid", "ownerActivity", "knownUsers", "quotaOverrides", "pendingRebindByLegacyKey", "migratedLegacyIds",
    "identityBindings", "guardOverrides" }
O.SHARD_LIMITS = { records = 2000, entries = 20000, shards = 60, systemBudget = 100 }
local DAY_MS, HOUR_MS = 86400000, 3600000
-- 授權裝車後拖車改 keyId 的認領期限（裝車命令與 keyId 改變在同一次處理，下一個 tick 就觀測；給重啟以外的延遲留餘裕）
O.KEYID_TOW_MS = 60000

O.AUTHORIZABLE = { ACTIVE = true, WITNESS_STALE = true, PENDING_RELEASE = true, QUARANTINED = true }
O.TOMBSTONE = { ORPHANED = true, DESTROYED = true, RELEASED = true }

-- RAM derived state（§4.1）：開機由 recordsByOid 重建，不存檔。outOfWorld＝已移出世界（removedAtMs）的可授權紀錄；
-- keyIdPending＝授權裝車後拖車紀錄 oid → { keyId＝被裝車的 keyId, atMs }（O.noteLoad）
local R = { bySqlId = {}, byKeyId = {}, byOwner = {}, status = "INIT", loaded = "none",
    denyAgg = {}, factionRefs = {}, suspectKeys = {}, lastMaintMs = 0, lastScanMs = 0,
    shards = {}, where = {}, st = nil, overrides = {}, outOfWorld = {}, keyIdPending = {} }
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
-- 家族約定 pz-family-docs/conventions.md「玩家身分」。MP：登入名；SP：本機 slot（SP 的 username 是角色姓名，換角色即變，§4.4）。
-- 伺服器上的 getUsername() 由客戶端決定（重生與分割畫面加入時設成 username，ConnectCoopPacket.java:72-97、
-- GameServer.java:2848），不能單獨當身分。所以分割畫面第 2～4 位玩家一律沒有身分；Steam 模式下名字要對上綁定表的
-- SteamID（連線驗證過的 Steam 帳號，GameServer.java:2843-2844）。
-- 第一次管理員匯入前，沒有綁定的名字沿用名字判定（既有玩家不會在匯入前全部失去身分）；no-steam 沒有驗證因子。
-- getSteamID 進 Lua 會捨入到 16 的倍數（Long→Double，KahluaNumberConverter.java:103-116）：只拿 number 比對，不轉字串
O.steamMode = function() return getSteamModeActive() == true end -- E2E 在 no-steam 伺服器覆寫
O.sidOf = function(player) return player:getSteamID() end

function O.principal(player)
    if player == nil then return nil end
    if not isServer() then return "local:" .. tostring(player:getPlayerNum()) end
    if player:getPlayerNum() ~= 0 then return nil end
    local name = player:getUsername()
    if type(name) ~= "string" or name == "" then return nil end
    if not O.steamMode() then return name end
    local st = O.state()
    if st == nil then return nil end
    local b = st.identityBindings[name]
    if b == nil then return st.identityImportedAtMs == nil and name or nil end
    if b.reserved or b.sid ~= O.sidOf(player) then return nil end
    return name
end

-- 伺服器上 OnNewGame 只由 CreatePlayerPacket 觸發（首次進場、重生、分割畫面加入都會送），觸發前名字＝連線登入名、
-- SteamID＝連線（CreatePlayerPacket.java:296-301）→ 可信的綁定來源。已綁定（或保留）的名字不改，只記 BIND_CONFLICT
function O.onNewGame(player)
    if not isServer() or player == nil or not O.steamMode() or not O.ready() then return end
    local name, sid = player:getUsername(), O.sidOf(player)
    if type(name) ~= "string" or name == "" or type(sid) ~= "number" or sid <= 0 then return end
    local b = O.state().identityBindings[name]
    if b == nil then
        O.mapSet("identityBindings", name, { sid = sid, atMs = now(), src = "NEWGAME" })
        O.bump(nil)
        O.audit("INFO", "BIND", { actor = name, reason = "NEWGAME" })
    elseif b.reserved or b.sid ~= sid then
        O.audit("WARN", "BIND_CONFLICT", { actor = name, reason = b.reserved and "RESERVED" or "SID_MISMATCH" })
    end
end
Events.OnNewGame.Add(O.onNewGame)

-- 第一次匯入後，帳本要記一個還沒綁定的名字（MVCK 匯入的車主）→ 保留，日後同名新帳號不會被 OnNewGame 自動綁上
function O.reserveUnbound(name)
    local st = O.state()
    if name == nil or st.identityImportedAtMs == nil or st.identityBindings[name] ~= nil then return false end
    O.mapSet("identityBindings", name, { reserved = true, atMs = now(), src = "IMPORT" })
    O.audit("WARN", "BIND_RESERVED", { owner = name })
    return true
end

-- 管理員匯入 whitelist：rows＝{ u＝帳號, s＝精確 SteamID 字串或 "" }（Server.lua 已驗格式）。
-- tonumber 就是 Double.parseDouble（KahluaUtil.java:293），和 Long→Double 同為就近捨入，得到同一個數。
-- 沒綁定的新增；SteamID 不同或保留中的列成衝突（記在記憶體，管理員確認後 rebindConflicts）；
-- 帳本裡有車、有分享或 MVCK 待轉，卻不在 whitelist 的名字（帳號已刪，或分割畫面／改名留下的）→ 保留
function O.importIdentities(rows, actor)
    local st, t = O.state(), now()
    local res = { bound = 0, same = 0, missing = 0, reserved = 0, conflicts = {}, collisions = {} }
    local listed, bySid, sids = {}, {}, {}
    for _, row in ipairs(rows) do
        local name = row.u
        listed[name] = true
        if row.s == "" then
            res.missing = res.missing + 1
        else
            local sid = tonumber(row.s)
            local first = bySid[sid]
            if first == nil then
                bySid[sid] = row
            elseif first.s ~= row.s then -- 兩個 Steam 帳號捨入成同一個數：彼此無法區分，列給管理員
                if not first.collided then first.collided = true; res.collisions[#res.collisions + 1] = first.u end
                res.collisions[#res.collisions + 1] = name
            end
            sids[name] = sid
            local b = st.identityBindings[name]
            if b == nil then
                O.mapSet("identityBindings", name, { sid = sid, atMs = t, src = "IMPORT" })
                res.bound = res.bound + 1
            elseif not b.reserved and b.sid == sid then
                res.same = res.same + 1
            else
                res.conflicts[#res.conflicts + 1] = name
            end
        end
    end
    st.identityImportedAtMs = t
    local function reserve(name)
        if name ~= nil and not listed[name] and O.reserveUnbound(name) then res.reserved = res.reserved + 1 end
    end
    for _, rec in pairs(st.recordsByOid) do
        if O.AUTHORIZABLE[rec.recordState] then
            reserve(rec.ownerUser)
            for _, g in ipairs(rec.grants or {}) do reserve(g.user) end
        end
    end
    for _, e in pairs(st.pendingRebindByLegacyKey) do reserve(e.ownerUser) end
    R.identityConflicts = { names = res.conflicts, sids = sids }
    O.bump(nil)
    O.audit("WARN", "IDENTITY_IMPORT", { actor = actor, role = "ADMIN", count = #rows, reason = "bound=" .. res.bound
        .. " same=" .. res.same .. " missing=" .. res.missing .. " reserved=" .. res.reserved
        .. " conflicts=" .. #res.conflicts .. " collisions=" .. #res.collisions })
    for _, name in ipairs(res.conflicts) do O.audit("WARN", "BIND_CONFLICT", { actor = actor, owner = name, reason = "IMPORT" }) end
    for _, name in ipairs(res.collisions) do O.audit("WARN", "BIND_CONFLICT", { actor = actor, owner = name, reason = "COLLISION" }) end
    return res
end

-- 管理員確認：上次匯入列出的衝突全部改綁成 whitelist 的 SteamID（保留名解除保留）。回改綁數；沒有匯入結果回 nil
function O.rebindConflicts(actor)
    local c = R.identityConflicts
    if c == nil then return nil end
    R.identityConflicts = nil
    for _, name in ipairs(c.names) do
        O.mapSet("identityBindings", name, { sid = c.sids[name], atMs = now(), src = "REBIND" })
        O.audit("WARN", "BIND_MOVE", { actor = actor, role = "ADMIN", owner = name })
    end
    if #c.names > 0 then O.bump(nil) end
    return #c.names
end

function O.isAdmin(player)
    if not isServer() or player == nil or Capability == nil then return false end
    return checkPermissions(player, Capability.ManipulateVehicle) == true
end

-- 管理員越權（面板開關）：只存記憶體，帳號 → 開啟當時的 IsoPlayer。重新登入（或死亡重生）換成新物件、
-- 伺服器重啟清空，都會自動失效；判定時仍要求目前有管理權限
function O.overrideActive(player)
    local who = O.principal(player)
    return who ~= nil and R.overrides[who] == player and O.isAdmin(player)
end

function O.setOverride(player, enabled)
    if not O.isAdmin(player) then return false end
    local who = O.principal(player)
    R.overrides[who] = enabled and player or nil
    O.audit("WARN", "ADMIN_OVERRIDE", { actor = who, role = "ADMIN", reason = enabled and "ON" or "OFF" })
    return true
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

-- 第三方車身標記（ClaimTags.lua 掛 O.syncClaimTags；vehicle＝nil 時它自己找已載入的車）
local function claimTags(rec, vehicle)
    if O.syncClaimTags then O.syncClaimTags(rec, vehicle) end
end

local function quarantine(rec, reason)
    if rec.recordState == "QUARANTINED" then return end
    rec.recordState = "QUARANTINED"
    rec.quarantineReason = reason
    O.bump(rec)
    O.audit("ERROR", "QUARANTINE", { oid = rec.oid, owner = rec.ownerUser, reason = reason })
    claimTags(rec, nil)
end

-- §4.2 規則 0／7：只索引可授權、仍在世界上的紀錄；同 sqlId 兩筆或缺必要欄位 → quarantine
function O.rebuildIndex()
    local st = O.state()
    R.bySqlId, R.byKeyId, R.byOwner, R.outOfWorld = {}, {}, {}, {}
    if st == nil then return end
    for _, rec in pairs(st.recordsByOid) do
        if rec.ownerUser ~= nil then addToList(R.byOwner, rec.ownerUser, rec) end
        if O.AUTHORIZABLE[rec.recordState] then
            if not MVM.isInt(rec.sqlIdHint) or not MVM.isInt(rec.keyIdHint) or type(rec.vehicleScript) ~= "string" then
                quarantine(rec, "SCHEMA_INVALID")
            end
            if rec.removedAtMs then
                R.outOfWorld[rec.oid] = rec
            else
                addToList(R.bySqlId, rec.sqlIdHint, rec)
                R.byKeyId[rec.keyIdHint] = rec.sqlIdHint
            end
        end
    end
    for _, list in pairs(R.bySqlId) do
        if #list > 1 then for _, rec in ipairs(list) do quarantine(rec, "DUPLICATE_SQLID") end end
    end
end

-- 冪等：重複呼叫（移出後又轉終態）不會出錯
local function unindex(rec)
    local list = R.bySqlId[rec.sqlIdHint]
    if list then
        for i = #list, 1, -1 do if list[i] == rec then table.remove(list, i) end end
        if #list == 0 then R.bySqlId[rec.sqlIdHint] = nil end
    end
end

function O.hasOutOfWorld()
    for _ in pairs(R.outOfWorld) do return true end
    return false
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

-- owner（車主帳號）只給玩家端右鍵顯示「車主：…」；授權只看帳本與 oid／epoch，不讀它
local function writeWitness(vehicle, part, rec)
    rawset(part:getModData(), WITNESS_KEY, { oid = rec.oid, epoch = rec.epoch, owner = rec.ownerUser })
    vehicle:transmitPartModData(part)
end

local function stripWitness(vehicle, part)
    claimTags(nil, vehicle) -- 見證剝除＝這台車不再受保護，第三方標記一起清
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
        R.outOfWorld[rec.oid] = nil
        rec.carrierSqlId = nil
    end
    if newState ~= "PENDING_RELEASE" then rec.pendingReleaseAtMs, rec.releaseDueAtMs, rec.releaseReason = 0, 0, nil end
    O.bump(rec)
    local f = fields or {}
    f.oid, f.epoch, f.owner, f.reason = rec.oid, rec.epoch, rec.ownerUser, (reason or old .. "->" .. newState)
    O.audit("INFO", newState == "PENDING_RELEASE" and "PENDING_RELEASE" or "STATE", f)
    if O.onRecordChanged then O.onRecordChanged(rec, nil) end
    if O.TOMBSTONE[newState] or newState == "QUARANTINED" or old == "QUARANTINED" then claimTags(rec, nil) end
end

local function markObserved(rec, vehicle)
    rec.lastObservedSqlIdAtMs = now()
    if rec.recordState == "PENDING_RELEASE" then
        -- 期間內觀測到同一台車 → 取消 finalize，owner 要到車旁 unclaim（§4.5）
        O.setState(rec, "ACTIVE", "RELEASE_CANCELLED_OBSERVED")
    end
end

local function verdictOf(rec) return rec.recordState == "QUARANTINED" and "QUARANTINED" or "AUTHORIZED" end

-- 車被永久移除（拖車 MOD 裝車、管理員刪車、燒毀車拆解…）：同一台車（三欄位一致）的可授權紀錄標成「已移出世界」，
-- 記下時間、原 sqlId 與最後位置並取消索引。重啟後 VehiclesDB2 會回收舊 sqlId（AGENTS API 表 allocateID 列），
-- 取消索引才不會把拿到舊號的別台車判成 SQLID_RECYCLED → ORPHANED。紀錄照常計入名額；車以同一份零件見證
-- 回到世界時由 lookup 接回。帳本不可寫（非 READY）就不處理
function O.onPermanentlyRemove(vehicle)
    if O.state() == nil or not O.ready() then return end
    local sqlId, keyId, script = native(vehicle)
    local hits = {}
    for _, rec in ipairs(R.bySqlId[sqlId] or {}) do
        if rec.keyIdHint == keyId and rec.vehicleScript == script and O.AUTHORIZABLE[rec.recordState] then hits[#hits + 1] = rec end
    end
    local t = now()
    for _, rec in ipairs(hits) do
        unindex(rec)
        if R.byKeyId[keyId] == sqlId then R.byKeyId[keyId] = nil end
        R.outOfWorld[rec.oid] = rec
        rec.removedAtMs, rec.removedSqlId = t, sqlId
        rec.lastKnownX, rec.lastKnownY, rec.lastKnownZ, rec.lastKnownAtMs = vehicle:getX(), vehicle:getY(), vehicle:getZ(), t
        O.bump(rec)
        O.audit("INFO", "REMOVED_FROM_WORLD", { oid = rec.oid, epoch = rec.epoch, owner = rec.ownerUser, vehicle = sqlId,
            x = rec.lastKnownX, y = rec.lastKnownY, z = rec.lastKnownZ })
        if O.onRecordChanged then O.onRecordChanged(rec, nil) end
    end
end

-- 見證指到「已移出世界」的同一台車（epoch、車型、keyId 都相同）＝拖車卸下的原車（MSW／Autotsar 卸車時還原零件 modData
-- 與 keyId），接回到新 sqlId。回 record；不符回 nil 與原因（被指到的紀錄本身不動）
local function adopt(vehicle, host, w, sqlId, keyId, script)
    local rec = O.state().recordsByOid[w.oid]
    if rec == nil then return nil, "NO_RECORD" end
    if not O.AUTHORIZABLE[rec.recordState] then return nil, "RECORD_ENDED" end
    if not rec.removedAtMs then return nil, "RECORD_IN_WORLD" end
    if rec.epoch ~= w.epoch then return nil, "EPOCH_MISMATCH" end
    if rec.vehicleScript ~= script then return nil, "SCRIPT_MISMATCH" end
    if rec.keyIdHint ~= keyId then return nil, "KEYID_MISMATCH" end
    local from = rec.removedSqlId
    rec.removedAtMs, rec.removedSqlId, rec.carrierSqlId = nil, nil, nil
    R.outOfWorld[rec.oid] = nil
    rec.sqlIdHint, rec.witnessPartId = sqlId, host:getId()
    R.bySqlId[sqlId] = { rec }
    R.byKeyId[keyId] = sqlId
    rec.lastKnownX, rec.lastKnownY, rec.lastKnownZ, rec.lastKnownAtMs = vehicle:getX(), vehicle:getY(), vehicle:getZ(), now()
    O.bump(rec)
    O.audit("INFO", "REATTACHED", { oid = rec.oid, epoch = rec.epoch, owner = rec.ownerUser, vehicle = sqlId,
        reason = "sqlId " .. s(from) .. "->" .. s(sqlId), x = rec.lastKnownX, y = rec.lastKnownY, z = rec.lastKnownZ })
    markObserved(rec, vehicle)
    if O.onRecordChanged then O.onRecordChanged(rec, nil) end
    claimTags(rec, vehicle)
    return rec
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
            local back, why = adopt(vehicle, host, w, sqlId, keyId, script)
            if back then return verdictOf(back), back end
            -- 規則 6：沒有可接回 record 的見證沒有權威，剝除即可
            stripWitness(vehicle, host)
            O.audit("WARN", "ORPHAN_WITNESS_STRIPPED", { vehicle = sqlId, oid = w.oid, reason = why })
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
    -- 授權裝車後 Autotsar 把被裝車的 keyId 寫到拖車上（CommonCommands.lua:511,634；ATAISLoadVehicle.lua:381,504）：
    -- O.noteLoad 記下的 keyId、期限內、同車型才認，紀錄改用新 keyId 並重寫見證
    local kp = R.keyIdPending[rec.oid]
    if kp ~= nil and kp.keyId == keyId and rec.vehicleScript == script and now() - kp.atMs <= O.KEYID_TOW_MS then
        R.keyIdPending[rec.oid] = nil
        local from = rec.keyIdHint
        if R.byKeyId[from] == sqlId then R.byKeyId[from] = nil end
        rec.keyIdHint = keyId
        R.byKeyId[keyId] = sqlId
        if host ~= nil then writeWitness(vehicle, host, rec) end
        markObserved(rec, vehicle)
        O.bump(rec)
        O.audit("INFO", "KEYID_TOW", { oid = rec.oid, epoch = rec.epoch, owner = rec.ownerUser, vehicle = sqlId,
            reason = "keyId " .. s(from) .. "->" .. s(keyId) })
        if O.onRecordChanged then O.onRecordChanged(rec, nil) end
        return verdictOf(rec), rec
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
    -- 拖車卸下的車拿到被回收的舊號：舊紀錄照常 ORPHANED，車上帶的若是另一筆移出紀錄的見證仍要接回
    local own = O.hostPart(vehicle, nil)
    local w2 = readWitness(own)
    if w2 ~= nil then
        local back = adopt(vehicle, own, w2, sqlId, keyId, script)
        if back then return verdictOf(back), back end
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
        factionState = "NONE", factionActionBits = 0, publicBits = 0,
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

-- 基本名額：管理員個人設定是絕對值，否則沙盒 ClaimsPerPlayer
function O.quotaBase(owner)
    local override = O.state().quotaOverrides[owner]
    if MVM.isInt(override) then return override end
    return MVM.sandbox("ClaimsPerPlayer", 3)
end

-- 上限＝基本＋Economy 已確認付費名額（Economy.lua 掛 O.paidSlots；不可用時為 0，只擋新增、不動既有綁定）
function O.quotaLimit(owner)
    return O.quotaBase(owner) + (O.paidSlots and O.paidSlots(owner) or 0)
end

-- claim 前置條件（不含車輛本身的檢查）。寬限中的租用名額（O.graceSlots，RentLock.lua）不能再拿來綁新車
function O.claimBlocked(owner)
    local ok, reason = O.ready()
    if not ok then return reason end
    if O.configBlocked() then return "CONFIG_BLOCKED" end
    if O.quotaUsed(owner) >= O.quotaLimit(owner) - (O.graceSlots and O.graceSlots(owner) or 0) then return "QUOTA_EXCEEDED" end
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
    if st.ownerActivity[owner] == nil then O.mapSet("ownerActivity", owner, { lastSuccessfulLoginAtMs = now() }) end
    writeWitness(vehicle, host, rec)
    O.bump(rec)
    claimTags(rec, vehicle)
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
    if st.ownerActivity[newOwner] == nil then O.mapSet("ownerActivity", newOwner, { lastSuccessfulLoginAtMs = now() }) end
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
-- 權威授權。回 allowed, reason, record。順序：租用到期鎖定（MANAGE 除外）→ 車主 → 分享／陣營／公開（MANAGE 除外）
-- → 管理員越權 → 拒絕。管理員身分本身不放行，要在車隊視窗開啟越權；有分享權限的管理員照一般成員記，不寫 ADMIN_BYPASS。
-- QUARANTINED 紀錄只有越權中的管理員能用。公開分享也要有身分（同分享：分割畫面與身分未確認的人不能用）
function O.canUse(actor, vehicle, action, context)
    if MVM.ACTIONS[action] == nil then return false, "UNKNOWN_ACTION" end
    if actor == nil or vehicle == nil then return false, "BAD_TARGET" end
    if O.state() == nil then return false, "NOT_READY" end
    local verdict, rec = O.lookup(vehicle)
    if rec == nil then return true, "UNCLAIMED" end
    return O.allowsRecord(actor, rec, action, context)
end

-- 已找到紀錄後的判定（canUse 與指令防火牆共用；不在世界上的紀錄，例如拖車載著的車，也用這個）
function O.allowsRecord(actor, rec, action, context)
    if MVM.ACTIONS[action] == nil then return false, "UNKNOWN_ACTION", rec end
    local who = O.principal(actor)
    -- 鎖定的車連車主也不能用（解除綁定、改名、分享等車主管理命令不經這裡）；越權中的管理員照常
    if rec.lock ~= nil and action ~= "MANAGE" and not O.overrideActive(actor) then
        O.deny(who, action, rec.oid, "RENT_LOCKED")
        return false, "RENT_LOCKED", rec
    end
    local quarantined = rec.recordState == "QUARANTINED"
    if not quarantined then
        if who ~= nil and who == rec.ownerUser then return true, "OWNER", rec end
        if action ~= "MANAGE" then
            local bits = O.grantBits(rec, who)
            if bits ~= nil and MVM.bitsAllow(bits, action) then return true, "MEMBER", rec end
            if MVM.bitsAllow(rec.factionActionBits or 0, action) and O.factionAllows(rec, who) then return true, "FACTION", rec end
            if who ~= nil and MVM.bitsAllow(rec.publicBits or 0, action) then return true, "PUBLIC", rec end
        end
    end
    if O.overrideActive(actor) then
        -- watchdog 每秒查（silent）：不重複寫 bypass
        if not (context ~= nil and context.silent == true) then
            O.audit("WARN", "ADMIN_BYPASS", { actor = who, oid = rec.oid, owner = rec.ownerUser,
                reason = action .. (context and context.mod and (" " .. s(context.mod)) or "") })
        end
        return true, "ADMIN", rec
    end
    local reason = quarantined and "QUARANTINED" or "NOT_AUTHORIZED"
    O.deny(who, action, rec.oid, reason)
    return false, reason, rec
end

-- 授權的拖車裝車（指令防火牆或 adapter 放行時，裝車之前）：受保護的拖車記下即將被寫上的 keyId（lookup 認 KEYID_TOW，
-- 下一個 tick 就觀測），受保護的被裝車記下在哪台拖車上（卸車時那台拖車載著的紀錄也要 TOW，O.carriedBy）
function O.noteLoad(trailer, vehicle)
    if trailer == nil or vehicle == nil or trailer == vehicle or not O.ready() then return end
    local _, tr = O.lookup(trailer)
    if tr ~= nil then
        R.keyIdPending[tr.oid] = { keyId = vehicle:getKeyId(), atMs = now() }
        if O.observeSoon then O.observeSoon(trailer) end
    end
    local _, vr = O.lookup(vehicle)
    if vr ~= nil and vr.carrierSqlId ~= trailer:getSqlId() then
        vr.carrierSqlId = trailer:getSqlId()
        O.bump(vr)
    end
end

-- 這台拖車載著（已移出世界、carrierSqlId 相同）的可授權紀錄
function O.carriedBy(trailer)
    local out = {}
    if trailer == nil then return out end
    local sqlId = trailer:getSqlId()
    for _, rec in pairs(R.outOfWorld) do
        if rec.carrierSqlId == sqlId then out[#out + 1] = rec end
    end
    return out
end

-- 這筆紀錄的車（仍在世界上）載著受保護紀錄：結束它會留下沒綁定、卻載著受保護車的拖車（整台能被掛走），
-- 解除綁定、回報遺失、管理員釋出都拒絕（CARRIER_HAS_CARGO），待釋放到期也先不結束
function O.hasCargo(rec)
    if rec.removedAtMs then return false end
    for _, r in pairs(R.outOfWorld) do
        if r.carrierSqlId == rec.sqlIdHint then return true end
    end
    return false
end

-- server 端公開 API 換成權威實作（§8.1.1）
MinidoracatVehicleManagerAPI.canUse = function(actor, vehicle, actionCode, context)
    local ok, reason = O.canUse(actor, vehicle, actionCode, context)
    return ok, reason
end

-- ----------------------------------------------------------- maintenance ---
-- 每分鐘（牆鐘節流）：finalize PENDING_RELEASE、清 tombstone、閒置釋放、聚合 DENY。
-- 閒置釋放：車主最後在線（O.observeLogin 每分鐘刷新）超過 InactivityReleaseDays 天，他的車直接解除綁定（玩家車隊視窗
-- 顯示的「保留到」就是這個時間）。伺服器停機或空服暫停（EveryOneMinute 不跑）的時間不算：兩次維護間隔超過 DOWNTIME_MS，
-- 所有車主的最後在線一起往後移，免得長時間停機後一開服就把所有人的車放掉
local DOWNTIME_MS = 10 * 60000
function O.maintain(force)
    local t = now()
    if not force and t - R.lastMaintMs < 60000 then return end
    R.lastMaintMs = t
    flushDenies()
    if not O.ready() then return end
    local st = O.state()
    local gap = t - (st.lastMaintAtMs or t)
    if gap > DOWNTIME_MS then
        for _, act in pairs(st.ownerActivity) do act.lastSuccessfulLoginAtMs = (act.lastSuccessfulLoginAtMs or t) + gap end
    end
    st.lastMaintAtMs = t
    local retention = MVM.sandbox("TombstoneRetentionDays", 14) * DAY_MS
    local idleMs = MVM.sandbox("InactivityReleaseDays", 30) * DAY_MS
    local expired = {}
    if idleMs > 0 then
        for owner, act in pairs(st.ownerActivity) do
            if t - (act.lastSuccessfulLoginAtMs or t) > idleMs then expired[owner] = true end
        end
    end
    local drop = {}
    for _, rec in pairs(st.recordsByOid) do
        local state = rec.recordState
        if expired[rec.ownerUser] and (state == "ACTIVE" or state == "WITNESS_STALE" or state == "PENDING_RELEASE") then
            -- 載著受保護紀錄的拖車先不放（CARRIER_HAS_CARGO）：同一位車主的被載車這一輪放掉後，下一輪再放拖車
            if not O.hasCargo(rec) then O.setState(rec, "RELEASED", "INACTIVITY") end
        elseif state == "PENDING_RELEASE" and t >= (rec.releaseDueAtMs or 0) then
            if not O.hasCargo(rec) then O.setState(rec, "RELEASED", "RELEASE_FINALIZED") end
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

-- 在線觀測：online 名單中的 owner 每分鐘更新最後在線時間（閒置釋放從這裡起算）
function O.observeLogin(owner)
    local st = O.state()
    local act = st and st.ownerActivity[owner]
    if act ~= nil then act.lastSuccessfulLoginAtMs = now() end
end

-- 已載入車輛：reconcile 身分並低頻收斂 lastKnown（§7.3：不存每次 sample）；第三方車身標記也在這裡比對修正
-- （陣營成員變動、client 經 transmitModData 竄改後，下次觀測修回）。見證的 owner 也在這裡補：舊見證沒有這欄
-- （加入前綁定的車），oid／epoch 對得上就照帳本重寫，不換 epoch、不改狀態
function O.observeVehicle(vehicle)
    if not O.ready() then return end
    local verdict, rec = O.lookup(vehicle)
    claimTags((verdict == "AUTHORIZED" or verdict == "QUARANTINED") and rec or nil, vehicle)
    if rec == nil or verdict ~= "AUTHORIZED" then return end
    local host = O.hostPart(vehicle, rec.witnessPartId)
    local w = readWitness(host)
    if w ~= nil and w.oid == rec.oid and w.epoch == rec.epoch and w.owner ~= rec.ownerUser then writeWitness(vehicle, host, rec) end
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

-- 伺服器（含 SP）包 BaseVehicle 方法表的 permanentlyRemove（同 ClientGuards 包 canAccessContainer 的做法：方法表在
-- __classmetatables[BaseVehicle.class].__index，KahluaUtil.java:132-134、LuaJavaClassExposer.java:224-231,287）。
-- MSW（MSW_Common_Commands.lua:2329）與 Autotsar（ATAISLoadVehicle.lua:50,54）都從 Lua 呼叫它；Java 內部呼叫不經過這裡。
-- 本 MOD 的處理包在 pcall 裡、在原函式之前做（車的三欄位還讀得到），原函式一定照常執行
local ORIG_REMOVE_KEY = "MinidoracatVehicleManager_permanentlyRemove"
function O.installRemoveHook()
    local methods = __classmetatables and BaseVehicle and BaseVehicle.class and __classmetatables[BaseVehicle.class]
    methods = methods and methods.__index
    local orig = methods and (rawget(methods, ORIG_REMOVE_KEY) or methods.permanentlyRemove)
    if orig == nil then
        MVM.log("vehicle removal hook NOT installed: BaseVehicle method table not found")
        return false
    end
    rawset(methods, ORIG_REMOVE_KEY, orig) -- Lua 重載時不疊包
    methods.permanentlyRemove = function(vehicle, ...)
        local ok, err = pcall(O.onPermanentlyRemove, vehicle)
        if not ok then MVM.log("removal hook failed: " .. tostring(err)) end
        return orig(vehicle, ...)
    end
    MVM.log("vehicle removal hook installed")
    return true
end
O.installRemoveHook()
