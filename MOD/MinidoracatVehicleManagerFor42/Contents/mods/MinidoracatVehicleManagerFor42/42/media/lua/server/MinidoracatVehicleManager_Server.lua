-- 命令層（計畫 §6）：驗證 → 冪等 ACK → 限流 → 重解析車輛 → 距離 → 身分 → 權限 → quota → 白名單突變 → audit／ACK。
-- 投影只以 per-recipient stream 送出（§6.2），絕不全服廣播；SP 以直接 Lua 呼叫投遞（§4.4）。
if isClient() then return end
require "MinidoracatVehicleManager_API"
require "MinidoracatVehicleManager_OwnershipSystem"

local MVM = MinidoracatVehicleManager
local O = MVM.Own
local S = {}
MVM.Srv = S

local ATTEMPT_TTL_MS = 30000
local RATE_WINDOW_MS, RATE_MAX = 5000, 20
local ACK_PER_ACTOR = 32

local R = { acks = {}, ackOrder = {}, rate = {}, attempts = {}, streams = {} }
S.R = R

local function now() return getTimestampMs() end

-- ------------------------------------------------------------- delivery ---
function S.send(player, command, payload)
    payload.to = O.principal(player)
    if isServer() then
        sendServerCommand(player, MVM.MODULE, command, payload)
    elseif MVM.clientReceive then
        MVM.clientReceive(command, payload)
    end
end

-- principal → 目前在線的 IsoPlayer
function S.online()
    local out = {}
    if isServer() then
        local list = getOnlinePlayers()
        for i = 0, list:size() - 1 do
            local p = list:get(i)
            local who = O.principal(p)
            if who then out[who] = p end
        end
    else
        local p = getSpecificPlayer(0)
        if p then out[O.principal(p)] = p end
    end
    return out
end

-- -------------------------------------------------------------- projection ---
local function copyGrants(rec)
    local out = {}
    for i, g in ipairs(rec.grants or {}) do out[i] = { user = g.user, bits = g.bits } end
    return out
end

-- 收件者可見的一列；不可見回 nil。非 owner 不給 epoch、grants、陣營設定；沒有 TRACK 不給位置
function S.row(rec, who)
    local base = { oid = rec.oid, state = rec.recordState, name = rec.customName or "", script = rec.vehicleScript,
        witnessPartId = rec.witnessPartId }
    if who == rec.ownerUser then
        base.role = "OWNER"
        base.epoch = rec.epoch
        base.grants = copyGrants(rec)
        base.factionShare, base.factionState, base.factionName, base.factionActionBits =
            rec.factionShare == true, rec.factionState, rec.factionName, rec.factionActionBits or 0
        base.lastKnownX, base.lastKnownY, base.lastKnownZ, base.lastKnownAtMs =
            rec.lastKnownX, rec.lastKnownY, rec.lastKnownZ, rec.lastKnownAtMs
        base.releaseDueAtMs = rec.releaseDueAtMs
        return base
    end
    if not O.AUTHORIZABLE[rec.recordState] or rec.recordState == "QUARANTINED" then return nil end
    -- 有效權限＝指定成員權限 ∪ 有效的陣營權限（與 O.canUse 的合併語意一致）
    local named = O.grantBits(rec, who)
    local members = O.factionMembers(rec)
    local viaFaction = members[who] and members[rec.ownerUser]
    if named == nil and not viaFaction then return nil end
    local bits = MVM.bitsOr(named or 0, viaFaction and (rec.factionActionBits or 0) or 0)
    base.role = named ~= nil and "MEMBER" or "FACTION"
    base.myBits = bits
    base.owner = rec.ownerUser
    if MVM.bitsAllow(bits, "TRACK") then
        base.lastKnownX, base.lastKnownY, base.lastKnownZ, base.lastKnownAtMs =
            rec.lastKnownX, rec.lastKnownY, rec.lastKnownZ, rec.lastKnownAtMs
    end
    return base
end

-- 會看到這筆紀錄的 principal 集合
function S.audience(rec)
    local out = {}
    if rec.ownerUser then out[rec.ownerUser] = true end
    for _, g in ipairs(rec.grants or {}) do out[g.user] = true end
    for who in pairs(O.factionMembers(rec)) do out[who] = true end
    return out
end

local function union(a, b)
    local out = {}
    for k in pairs(a) do out[k] = true end
    for k in pairs(b) do out[k] = true end
    return out
end

local function deliver(who, player, upserts, removes)
    local st = R.streams[who]
    if st == nil then return end
    st.seq = st.seq + 1
    S.send(player, "fleetDelta", { streamId = st.streamId, seq = st.seq, upserts = upserts, removes = removes })
end

-- 對 before∪after 收件者推送：撤權者收 removes，新授權者收 upserts（§6.2）
function S.push(recipients, rec, removed)
    local online = S.online()
    for who in pairs(recipients) do
        local player = online[who]
        if player and R.streams[who] then
            local row = (not removed) and S.row(rec, who) or nil
            if row then deliver(who, player, { row }, {}) else deliver(who, player, {}, { rec.oid }) end
        end
    end
end

O.onRecordChanged = function(rec) S.push(S.audience(rec), rec, false) end

-- 改變收件者集合的突變：先記下舊集合
local function change(rec, fn)
    local before = S.audience(rec)
    fn()
    S.push(union(before, S.audience(rec)), rec, false)
end

function S.snapshot(player, who)
    local st = { streamId = getRandomUUID(), seq = 0 }
    R.streams[who] = st
    local rows = {}
    local ledger = O.state()
    if ledger then
        for _, rec in pairs(ledger.recordsByOid) do
            local row = S.row(rec, who)
            if row then rows[#rows + 1] = row end
        end
        for _, row in ipairs(S.extraRows and S.extraRows(who) or {}) do rows[#rows + 1] = row end
    end
    S.send(player, "fleetSnapshot", { streamId = st.streamId, seq = 0, rows = rows,
        quotaUsed = ledger and O.quotaUsed(who) or 0, quotaLimit = ledger and O.quotaLimit(who) or 0,
        status = O.R.status })
end

-- 管理員總表：只給 ManipulateVehicle；位置只給 owner 資訊與最後已知點（即時追蹤屬 Phase 4 的另一權限）
function S.adminSnapshot(player)
    if not O.isAdmin(player) or O.state() == nil then
        return S.send(player, "adminSnapshot", { ok = false, rows = {} })
    end
    local rows = {}
    for _, rec in pairs(O.state().recordsByOid) do
        rows[#rows + 1] = { oid = rec.oid, owner = rec.ownerUser, state = rec.recordState, script = rec.vehicleScript,
            name = rec.customName or "", reason = rec.quarantineReason, lastKnownX = rec.lastKnownX, lastKnownY = rec.lastKnownY,
            lastKnownAtMs = rec.lastKnownAtMs, releaseDueAtMs = rec.releaseDueAtMs }
    end
    O.audit("INFO", "ADMIN_VIEW", { actor = O.principal(player), role = "ADMIN", count = #rows })
    S.send(player, "adminSnapshot", { ok = true, rows = rows, status = O.R.status })
end

-- -------------------------------------------------------------- validation ---
local function validToken(v) return type(v) == "string" and #v >= 8 and #v <= 64 and v:match("^[%w%-_]+$") ~= nil end

local TYPES = {
    id = MVM.isInt,
    uuid = function(v) return type(v) == "string" and #v >= 8 and #v <= 64 and v:match("^[%w%-]+$") ~= nil end,
    token = validToken,
    bool = function(v) return type(v) == "boolean" end,
    bits = MVM.validShareBits,
    user = function(v) return type(v) == "string" and #v >= 1 and #v <= 50 and not v:find("%c") end,
    text = function(v) return type(v) == "string" and #v <= 256 end,
    amount = function(v) return MVM.isInt(v) and v >= -1 and v <= 100 end,
    op = function(v) return v == "RELEASE" or v == "ACTIVATE" end,
    migrationOp = function(v) return v == "IMPORT" end,
    name = function(v) return type(v) == "string" and #v >= 1 and #v <= 64 and v:match("^[%w_]+$") ~= nil end,
}

-- 欄位 → 型別；? 結尾＝選填。未列出的欄位一律拒收（不讓 client 夾帶 ownerUser 之類）
local SCHEMA = {
    prepareClaim = { vehicleId = "id" },
    claim = { claimAttemptId = "uuid" },
    unclaim = { vehicleId = "id", expectedOid = "uuid", expectedEpoch = "uuid" },
    reportLost = { expectedOid = "uuid" },
    cancelRelease = { expectedOid = "uuid" },
    reissueWitness = { vehicleId = "id", expectedOid = "uuid" },
    rename = { expectedOid = "uuid", expectedEpoch = "uuid", name = "text" },
    setFactionShare = { expectedOid = "uuid", expectedEpoch = "uuid", enabled = "bool", actionBits = "bits" },
    addMember = { expectedOid = "uuid", username = "user", actionBits = "bits" },
    removeMember = { expectedOid = "uuid", username = "user" },
    leaveShared = { expectedOid = "uuid" },
    transfer = { vehicleId = "id", expectedOid = "uuid", expectedEpoch = "uuid", recipient = "user" },
    dismissRecord = { expectedOid = "uuid" },
    adminSetQuota = { username = "user", amount = "amount" },
    adminRecover = { expectedOid = "uuid", op = "op", ["vehicleId?"] = "id" },
    fleetSubscribe = {},
    fleetResync = {},
    prepareAction = { class = "name", vehicleId = "id", ["partId?"] = "name" },
    adminList = {},
    adminMigration = { op = "migrationOp" },
}
-- 不帶 requestId、不回 ACK 的命令
local QUERIES = { fleetSubscribe = true, fleetResync = true, prepareAction = true, adminList = true }

local function validate(command, args)
    local schema = SCHEMA[command]
    if schema == nil then return "UNKNOWN_COMMAND" end
    if type(args) ~= "table" then return "BAD_ARGS" end
    if args.protocol ~= MVM.PROTOCOL then return "PROTOCOL_MISMATCH" end
    if not QUERIES[command] and not validToken(args.requestId) then return "BAD_REQUEST_ID" end
    for key, value in pairs(args) do
        if key ~= "protocol" and key ~= "requestId" then
            local t = schema[key] or schema[tostring(key) .. "?"]
            if t == nil or not TYPES[t](value) then return "BAD_ARGS" end
        end
    end
    for key, t in pairs(schema) do
        if key:sub(-1) ~= "?" and args[key] == nil then return "BAD_ARGS" end
    end
    return nil
end

local function rateLimited(who)
    local t = now()
    local r = R.rate[who]
    if r == nil or t - r.start >= RATE_WINDOW_MS then r = { start = t, n = 0 }; R.rate[who] = r end
    r.n = r.n + 1
    return r.n > RATE_MAX
end

local function cacheAck(who, command, requestId, ack)
    local bucket = R.acks[who]
    if bucket == nil then bucket = { map = {}, order = {} }; R.acks[who] = bucket end
    local key = command .. "|" .. requestId
    if bucket.map[key] == nil then
        bucket.order[#bucket.order + 1] = key
        if #bucket.order > ACK_PER_ACTOR then bucket.map[table.remove(bucket.order, 1)] = nil end
    end
    bucket.map[key] = ack
end

local function cachedAck(who, command, requestId)
    local bucket = R.acks[who]
    return bucket and bucket.map[command .. "|" .. requestId] or nil
end

-- ------------------------------------------------------------ vehicle gate ---
local function liveVehicle(id)
    local v = getVehicleById(id)
    if v == nil or v:isRemovedFromWorld() or v:getId() ~= id then return nil end
    return v
end

-- 車旁：同層、到車心距離 ≤ ClaimDistance（§6.3）
local function near(player, vehicle)
    if math.floor(player:getZ()) ~= math.floor(vehicle:getZ()) then return false end
    local dx, dy = player:getX() - vehicle:getX(), player:getY() - vehicle:getY()
    local d = MVM.sandbox("ClaimDistance", 2.5)
    return dx * dx + dy * dy <= d * d
end

local function claimable(vehicle)
    if O.hostPart(vehicle, nil) == nil then return "NOT_CLAIMABLE" end
    if vehicle:getScriptName():find("Burnt", 1, true) then return "NOT_CLAIMABLE" end
    if vehicle:getVehicleTowedBy() ~= nil then return "NOT_CLAIMABLE_TOWED" end
    return nil
end

local UNCLAIMED = { UNCLAIMED = true, UNCLAIMED_WITNESS_STRIPPED = true, UNCLAIMED_ORPHANED_OLD = true }

local function fail(reason) return { ok = false, reason = reason } end

-- owner 自己的紀錄（依 expectedOid）；member／faction／他人一律 NOT_OWNER
local function ownRecord(who, oid)
    local rec = O.state().recordsByOid[oid]
    if rec == nil then return nil, "NO_SUCH_RECORD" end
    if rec.ownerUser ~= who then return nil, "NOT_OWNER" end
    return rec
end

-- 車旁＋live lookup 命中且 oid 相符
local function ownLiveRecord(player, who, a)
    local v = liveVehicle(a.vehicleId)
    if v == nil then return nil, nil, "NO_SUCH_VEHICLE" end
    if not near(player, v) then return nil, nil, "TOO_FAR" end
    local verdict, rec = O.lookup(v)
    if rec == nil then return nil, nil, "NOT_CLAIMED" end
    if verdict == "QUARANTINED" then return nil, nil, "QUARANTINED" end
    if rec.oid ~= a.expectedOid then return nil, nil, "STALE_TARGET" end
    if rec.ownerUser ~= who then return nil, nil, "NOT_OWNER" end
    return v, rec
end

local function findFactionOf(user)
    local list = Faction.getFactions()
    for i = 0, list:size() - 1 do
        local f = list:get(i)
        if f:getOwner() == user or f:isMember(user) then return f end
    end
    return nil
end

-- 車名：去控制字元、頭尾空白，UTF-8 byte 上限
local function cleanName(name)
    local n = name:gsub("%c", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #n > MVM.sandbox("NameMaxBytes", 32) then return nil end
    return n
end

-- --------------------------------------------------------------- handlers ---
local H = {}

H.prepareClaim = function(player, who, a)
    local blocked = O.claimBlocked(who)
    if blocked then return fail(blocked) end
    local v = liveVehicle(a.vehicleId)
    if v == nil then return fail("NO_SUCH_VEHICLE") end
    if not near(player, v) then return fail("TOO_FAR") end
    local bad = claimable(v)
    if bad then return fail(bad) end
    local verdict = O.lookup(v)
    if not UNCLAIMED[verdict] then return fail("ALREADY_CLAIMED") end
    -- 每位 actor 同時一筆，新的取代舊的；綁定確切物件＋native 三欄位（§6.1）
    local attempt = { id = getRandomUUID(), actor = who, vehicle = v, vehicleId = a.vehicleId,
        sqlId = v:getSqlId(), keyId = v:getKeyId(), script = v:getScriptName(), expiresAtMs = now() + ATTEMPT_TTL_MS }
    R.attempts[who] = attempt
    return { ok = true, claimAttemptId = attempt.id, vehicleId = a.vehicleId }
end

H.claim = function(player, who, a)
    local att = R.attempts[who]
    if att == nil or att.id ~= a.claimAttemptId then return fail("ATTEMPT_UNKNOWN") end
    R.attempts[who] = nil
    if now() > att.expiresAtMs then return fail("ATTEMPT_EXPIRED") end
    local v = liveVehicle(att.vehicleId)
    -- 物件身分：runtime id 被別台車重用時，getVehicleById 回的是不同物件
    if v == nil or v ~= att.vehicle then return fail("ATTEMPT_STALE_VEHICLE") end
    if v:getSqlId() ~= att.sqlId or v:getKeyId() ~= att.keyId or v:getScriptName() ~= att.script then
        return fail("ATTEMPT_IDENTITY_CHANGED")
    end
    if not near(player, v) then return fail("TOO_FAR") end
    local blocked = O.claimBlocked(who)
    if blocked then return fail(blocked) end
    local bad = claimable(v)
    if bad then return fail(bad) end
    if not UNCLAIMED[O.lookup(v)] then return fail("ALREADY_CLAIMED") end
    local rec = O.createRecord(who, v, O.hostPart(v, nil))
    O.audit("INFO", "CLAIM", { actor = who, role = "OWNER", oid = rec.oid, epoch = rec.epoch, owner = who,
        vehicle = rec.sqlIdHint, x = v:getX(), y = v:getY(), z = v:getZ() })
    S.push(S.audience(rec), rec, false)
    return { ok = true, oid = rec.oid }
end

H.unclaim = function(player, who, a)
    local v, rec, reason = ownLiveRecord(player, who, a)
    if rec == nil then return fail(reason) end
    if rec.epoch ~= a.expectedEpoch then return fail("STALE_TARGET") end
    O.stripWitness(v, O.hostPart(v, rec.witnessPartId))
    O.setState(rec, "RELEASED", "UNCLAIM", { actor = who })
    O.audit("INFO", "UNCLAIM", { actor = who, oid = rec.oid, owner = who, vehicle = rec.sqlIdHint })
    return { ok = true }
end

H.reportLost = function(player, who, a)
    local rec, reason = ownRecord(who, a.expectedOid)
    if rec == nil then return fail(reason) end
    if rec.recordState ~= "ACTIVE" and rec.recordState ~= "WITNESS_STALE" then return fail("INVALID_STATE") end
    O.beginRelease(rec, "REPORT_LOST")
    return { ok = true, releaseDueAtMs = rec.releaseDueAtMs }
end

H.cancelRelease = function(player, who, a)
    local rec, reason = ownRecord(who, a.expectedOid)
    if rec == nil then return fail(reason) end
    if rec.recordState ~= "PENDING_RELEASE" then return fail("INVALID_STATE") end
    O.setState(rec, "ACTIVE", "RELEASE_CANCELLED", { actor = who })
    return { ok = true }
end

H.reissueWitness = function(player, who, a)
    local v, rec, reason = ownLiveRecord(player, who, a)
    if rec == nil then return fail(reason) end
    if rec.recordState ~= "ACTIVE" and rec.recordState ~= "WITNESS_STALE" then return fail("INVALID_STATE") end
    if not O.rewriteWitness(rec, v) then return fail("NOT_CLAIMABLE") end
    O.setState(rec, "ACTIVE", "WITNESS_REISSUED", { actor = who })
    return { ok = true }
end

local function ownManageable(who, a)
    local rec, reason = ownRecord(who, a.expectedOid)
    if rec == nil then return nil, reason end
    if not O.AUTHORIZABLE[rec.recordState] or rec.recordState == "QUARANTINED" then return nil, "INVALID_STATE" end
    if a.expectedEpoch ~= nil and rec.epoch ~= a.expectedEpoch then return nil, "STALE_TARGET" end
    return rec
end

H.rename = function(player, who, a)
    local rec, reason = ownManageable(who, a)
    if rec == nil then return fail(reason) end
    local name = cleanName(a.name)
    if name == nil then return fail("NAME_TOO_LONG") end
    rec.customName = name
    O.bump(rec)
    O.audit("INFO", "RENAME", { actor = who, oid = rec.oid, owner = who })
    S.push(S.audience(rec), rec, false)
    return { ok = true }
end

H.setFactionShare = function(player, who, a)
    if a.enabled and not MVM.sandbox("AllowFactionShare", true) then return fail("FACTION_SHARE_DISABLED") end
    local rec, reason = ownManageable(who, a)
    if rec == nil then return fail(reason) end
    local f = nil
    if a.enabled then
        f = findFactionOf(who)
        if f == nil then return fail("NO_FACTION") end
    end
    change(rec, function()
        if a.enabled then
            rec.factionShare, rec.factionName, rec.factionOwnerUser, rec.factionState, rec.factionActionBits =
                true, f:getName(), f:getOwner(), "GRANTED", a.actionBits
            O.R.factionRefs[rec.oid] = f
        else
            rec.factionShare, rec.factionName, rec.factionOwnerUser, rec.factionState, rec.factionActionBits =
                false, nil, nil, "NONE", 0
            O.R.factionRefs[rec.oid] = nil
        end
        O.bump(rec)
    end)
    O.audit("INFO", "ACL_CHANGE", { actor = who, oid = rec.oid, owner = who,
        reason = a.enabled and ("FACTION " .. tostring(a.actionBits)) or "FACTION_OFF" })
    return { ok = true }
end

H.addMember = function(player, who, a)
    local rec, reason = ownManageable(who, a)
    if rec == nil then return fail(reason) end
    if a.username == who then return fail("BAD_MEMBER") end
    if a.actionBits == 0 then return fail("BAD_ARGS") end
    local existing = nil
    for _, g in ipairs(rec.grants) do if g.user == a.username then existing = g end end
    if existing == nil and not O.knownUser(a.username, S.online()) then return fail("UNKNOWN_PLAYER") end
    if existing == nil and #rec.grants >= MVM.sandbox("MaxMembersPerVehicle", 6) then return fail("MEMBER_LIMIT") end
    change(rec, function()
        if existing then existing.bits = a.actionBits
        else rec.grants[#rec.grants + 1] = { user = a.username, bits = a.actionBits } end
        O.bump(rec)
    end)
    O.audit("INFO", "ACL_CHANGE", { actor = who, oid = rec.oid, owner = who, reason = "MEMBER " .. a.username .. " " .. a.actionBits })
    return { ok = true }
end

local function dropGrant(rec, user)
    for i = #rec.grants, 1, -1 do
        if rec.grants[i].user == user then table.remove(rec.grants, i); return true end
    end
    return false
end

H.removeMember = function(player, who, a)
    local rec, reason = ownRecord(who, a.expectedOid)
    if rec == nil then return fail(reason) end
    local removed = false
    change(rec, function() removed = dropGrant(rec, a.username); if removed then O.bump(rec) end end)
    if not removed then return fail("NOT_MEMBER") end
    O.audit("INFO", "ACL_CHANGE", { actor = who, oid = rec.oid, owner = who, reason = "UNMEMBER " .. a.username })
    return { ok = true }
end

H.leaveShared = function(player, who, a)
    local rec = O.state().recordsByOid[a.expectedOid]
    if rec == nil then return fail("NO_SUCH_RECORD") end
    local removed = false
    change(rec, function() removed = dropGrant(rec, who); if removed then O.bump(rec) end end)
    if not removed then return fail("NOT_MEMBER") end
    O.audit("INFO", "ACL_CHANGE", { actor = who, oid = rec.oid, owner = rec.ownerUser, reason = "LEAVE" })
    return { ok = true }
end

-- 只接受在線的收件者（server Lua 讀不到帳號 DB）；舊紀錄 RELEASED、新紀錄新 oid／epoch、清空分享（§7.2）
H.transfer = function(player, who, a)
    local v, rec, reason = ownLiveRecord(player, who, a)
    if rec == nil then return fail(reason) end
    if rec.epoch ~= a.expectedEpoch then return fail("STALE_TARGET") end
    if rec.recordState ~= "ACTIVE" and rec.recordState ~= "WITNESS_STALE" then return fail("INVALID_STATE") end
    if a.recipient == who then return fail("BAD_RECIPIENT") end
    if not O.knownUser(a.recipient, S.online()) then return fail("RECIPIENT_UNKNOWN") end
    local blocked = O.claimBlocked(a.recipient)
    if blocked then return fail(blocked == "QUOTA_EXCEEDED" and "RECIPIENT_QUOTA" or blocked) end
    O.setState(rec, "RELEASED", "TRANSFER_OUT", { actor = who }) -- setState 已推給舊收件者（非 owner 收 removes）
    local fresh = O.createRecord(a.recipient, v, O.hostPart(v, nil))
    fresh.customName = rec.customName
    O.audit("INFO", "TRANSFER", { actor = who, oid = fresh.oid, epoch = fresh.epoch, owner = a.recipient,
        vehicle = fresh.sqlIdHint, reason = "from " .. who .. " old " .. rec.oid })
    S.push(S.audience(fresh), fresh, false)
    return { ok = true, oid = fresh.oid }
end

H.dismissRecord = function(player, who, a)
    local rec, reason = ownRecord(who, a.expectedOid)
    if rec == nil then return fail(reason) end
    if not O.TOMBSTONE[rec.recordState] then return fail("INVALID_STATE") end
    local audience = S.audience(rec)
    O.removeRecord(rec)
    S.push(audience, rec, true)
    return { ok = true }
end

H.adminSetQuota = function(player, who, a)
    if not O.isAdmin(player) then return fail("NOT_ADMIN") end
    O.mapSet("quotaOverrides", a.username, a.amount >= 0 and a.amount or nil)
    O.bump(nil)
    O.audit("WARN", "ADMIN_BYPASS", { actor = who, role = "ADMIN", owner = a.username, reason = "QUOTA " .. a.amount })
    return { ok = true }
end

-- RELEASE：任一非終態 → RELEASED。ACTIVATE：QUARANTINED 且車已載入、三欄位相符、同 sqlId 無其他可授權紀錄 → 重寫見證 ACTIVE
H.adminRecover = function(player, who, a)
    if not O.isAdmin(player) then return fail("NOT_ADMIN") end
    local rec = O.state().recordsByOid[a.expectedOid]
    if rec == nil then return fail("NO_SUCH_RECORD") end
    if O.TOMBSTONE[rec.recordState] then return fail("INVALID_STATE") end
    if a.op == "RELEASE" then
        O.setState(rec, "RELEASED", "ADMIN_RELEASE", { actor = who, role = "ADMIN" })
    else
        if rec.recordState ~= "QUARANTINED" or rec.ownerUser == nil then return fail("INVALID_STATE") end
        local v = a.vehicleId and liveVehicle(a.vehicleId)
        if v == nil then return fail("NO_SUCH_VEHICLE") end
        if v:getSqlId() ~= rec.sqlIdHint or v:getKeyId() ~= rec.keyIdHint or v:getScriptName() ~= rec.vehicleScript then
            return fail("IDENTITY_MISMATCH")
        end
        for _, other in ipairs(O.R.bySqlId[rec.sqlIdHint] or {}) do
            if other ~= rec and O.AUTHORIZABLE[other.recordState] then return fail("DUPLICATE_SQLID") end
        end
        if not O.rewriteWitness(rec, v) then return fail("NOT_CLAIMABLE") end
        rec.quarantineReason = nil
        O.setState(rec, "ACTIVE", "ADMIN_ACTIVATE", { actor = who, role = "ADMIN" })
    end
    O.audit("WARN", "ADMIN_BYPASS", { actor = who, role = "ADMIN", oid = rec.oid, owner = rec.ownerUser, reason = a.op })
    return { ok = true }
end

-- Phase 5 階段 B：冷重啟驗證後由管理員執行
H.adminMigration = function(player, who, a)
    if not O.isAdmin(player) then return fail("NOT_ADMIN") end
    if MVM.Migration == nil then return fail("INVALID_STATE") end
    local ok, res = MVM.Migration.importAll(who)
    if not ok then return fail(res) end
    return { ok = true, imported = res.imported, already = res.already, skipped = res.skipped, rebound = res.rebound,
        pending = res.pending }
end

-- -------------------------------------------------------------- dispatch ---
function S.handle(command, player, args)
    local who = O.principal(player)
    if who == nil then return end
    local requestId = type(args) == "table" and args.requestId or nil
    local function ack(result)
        result.requestKind, result.requestId = command, requestId
        if result.reason == "PROTOCOL_MISMATCH" then result.serverProtocol = MVM.PROTOCOL end
        S.send(player, "mutationAck", result)
    end
    local bad = validate(command, args)
    if bad then
        -- 未知命令名是 client 任意字串：先吃限流，且不進 deny 聚合鍵，免得撐大 denyAgg
        local known = H[command] ~= nil or QUERIES[command] or command == "prepareAction" or command == "adminList"
        if rateLimited(who) then return end
        O.deny(who, known and command or "UNKNOWN_COMMAND", nil, bad)
        if not QUERIES[command] or bad == "PROTOCOL_MISMATCH" then ack(fail(bad)) end
        return
    end
    if not QUERIES[command] then
        local cached = cachedAck(who, command, requestId)
        if cached then
            local again = {}
            for k, v in pairs(cached) do again[k] = v end
            again.duplicate = true
            return ack(again)
        end
    end
    if rateLimited(who) then
        if not QUERIES[command] then ack(fail("RATE_LIMITED")) end
        return
    end
    if command == "prepareAction" then
        if MVM.Guards then MVM.Guards.onIntent(player, who, args) end
        return
    end
    if command == "adminList" then return S.adminSnapshot(player) end
    if QUERIES[command] then return S.snapshot(player, who) end
    local ready, notReady = O.ready()
    local result
    if not ready then
        result = fail(notReady)
    else
        result = H[command](player, who, args)
        if not result.ok then O.deny(who, command, args.expectedOid, result.reason) end
    end
    cacheAck(who, command, requestId, result)
    ack(result)
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MVM.MODULE then return end
    S.handle(command, player, args)
end)

-- --------------------------------------------------------------- schedule ---
-- 牆鐘節流在 OwnershipSystem；這裡再觀測登入、清過期 attempt 與離線 stream
function S.minute()
    if O.state() == nil then return end
    local online = S.online()
    if O.R.status == "READY" then for who in pairs(online) do O.observeLogin(who); O.noteUser(who) end end
    local t = now()
    for who, att in pairs(R.attempts) do if t > att.expiresAtMs then R.attempts[who] = nil end end
    for who in pairs(R.streams) do if online[who] == nil then R.streams[who] = nil end end
    O.maintain(false)
    O.scanLoaded(false)
end

Events.EveryOneMinute.Add(S.minute)

-- 新生與 DB 載入的車都觸發（Phase 0 gate 10）：即時 reconcile 身分、取消 PENDING_RELEASE
Events.OnSpawnVehicleEnd.Add(function(vehicle)
    if O.state() ~= nil then O.observeVehicle(vehicle) end
end)

if Events.OnServerStarted then
    Events.OnServerStarted.Add(function()
        if O.configBlocked() then
            MVM.log("DropOffWhiteListAfterDeath=true: new claims are refused (CONFIG_BLOCKED). Existing claims are still enforced.")
            O.audit("ERROR", "CONFIG_BLOCKED", { reason = "DropOffWhiteListAfterDeath" })
        end
    end)
end
