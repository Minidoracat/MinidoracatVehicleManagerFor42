-- 命令層（計畫 §6）：驗證 → 冪等 ACK → 限流 → 重解析車輛 → 距離 → 身分 → 權限 → quota → 白名單突變 → audit／ACK。
-- 投影只以 per-recipient stream 送出（§6.2），絕不全服廣播；SP 以直接 Lua 呼叫投遞（§4.4）。
-- 停車保全（ParkedGuard.lua）的車主開關、模式與名額管理命令也在這裡；車主通知走 S.notify（notice）。
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

local R = { acks = {}, ackOrder = {}, rate = {}, attempts = {}, streams = {}, unverified = {} }
S.R = R

local function now() return getTimestampMs() end

-- ------------------------------------------------------------- delivery ---
-- 沒通過 SteamID 驗證的主玩家也要收得到「身分未確認」與管理員身分匯入的回覆：以本機帳號名定址（客戶端依它分桶）。
-- 內容一律依 principal 產生，沒有身分就不會拿到任何車隊資料
function S.send(player, command, payload)
    payload.to = O.principal(player) or (isServer() and player:getPlayerNum() == 0 and player:getUsername() or nil)
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

-- 給車主的通知（notice：{ key, oid?, who?, n?, atMs?, bad }）：一律記進通知紀錄（Notices.lua），車主不在線也查得到；
-- 在線就即時送，帶這則的編號、時間、次數、是否離線收到（併進離線時的那則會是 false）與紀錄當下的車名
-- （客戶端用同一則更新「紀錄」分頁）
function S.notify(who, payload)
    local p = S.online()[who]
    local e = MVM.Notices and MVM.Notices.add(who, payload, p ~= nil)
    if p == nil then return end
    if e then
        payload.id, payload.t, payload.c, payload.live, payload.name, payload.script = e.id, e.t, e.c, e.live, e.name, e.script
    end
    S.send(p, "notice", payload)
end

-- -------------------------------------------------------------- projection ---
local function copyGrants(rec)
    local out = {}
    for i, g in ipairs(rec.grants or {}) do out[i] = { user = g.user, bits = g.bits } end
    return out
end

-- 收件者可見的一列；不可見回 nil。非 owner 不給 epoch、grants、陣營設定；沒有 TRACK 不給位置。
-- removedAtMs：車暫時不在世界上（拖車裝走或被移除，OwnershipSystem O.onPermanentlyRemove）。
-- guard：停車保全狀態（車主看 ON／OVER，其他人只看 ON）；lock／lockUntilMs：租用名額到期鎖定（RentLock.lua）
function S.row(rec, who)
    local base = { oid = rec.oid, state = rec.recordState, name = rec.customName or "", script = rec.vehicleScript,
        witnessPartId = rec.witnessPartId, removedAtMs = rec.removedAtMs, lock = rec.lock, lockUntilMs = rec.lockUntilMs,
        endReason = rec.endReason }
    local guard = MVM.Parked and MVM.Parked.state(rec) or nil
    if who == rec.ownerUser then
        base.role = "OWNER"
        base.epoch = rec.epoch
        base.grants = copyGrants(rec)
        -- factionLeader＝分享當下的陣營領袖：陣營分享暫停時，車隊視窗比對現在的領袖說明是不是換了領袖
        base.factionShare, base.factionState, base.factionName, base.factionActionBits, base.factionLeader =
            rec.factionShare == true, rec.factionState, rec.factionName, rec.factionActionBits or 0, rec.factionOwnerUser
        base.lastKnownX, base.lastKnownY, base.lastKnownZ, base.lastKnownAtMs =
            rec.lastKnownX, rec.lastKnownY, rec.lastKnownZ, rec.lastKnownAtMs
        base.releaseDueAtMs = rec.releaseDueAtMs
        base.publicBits = rec.publicBits or 0
        base.guard = guard
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
    base.guard = guard == "ON" and guard or nil
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

-- quotaUsed：收件者目前已用名額（綁定、解除、轉讓、拖車移出都會變；不帶的話名額顯示要等下一次快照）
local function deliver(who, player, upserts, removes)
    local st = R.streams[who]
    if st == nil then return end
    st.seq = st.seq + 1
    S.send(player, "fleetDelta", { streamId = st.streamId, seq = st.seq, upserts = upserts, removes = removes,
        quotaUsed = O.quotaUsed(who) })
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

-- 公開分享表（oid → 動作位元）：陌生人的客戶端靠它判斷能不能用，所以給所有線上玩家（快照帶整張、變動時送 publicDelta）。
-- 只有隨機 oid 與位元，不含車主、位置、車名；授權仍只看 O.allowsRecord。R.pub 是已送出的內容，開機時從帳本建一次。
-- 租用到期鎖定（rec.lock）的車一律 0（O.allowsRecord 也拒絕）
local function publicOf(rec)
    if not O.AUTHORIZABLE[rec.recordState] or rec.recordState == "QUARANTINED" or rec.lock ~= nil then return 0 end
    return rec.publicBits or 0
end

function S.publicTable()
    if R.pub == nil then
        R.pub = {}
        for oid, rec in pairs(O.state().recordsByOid) do
            local bits = publicOf(rec)
            if bits > 0 then R.pub[oid] = bits end
        end
    end
    return R.pub
end

function S.pushPublic(rec)
    local pub, bits = S.publicTable(), publicOf(rec)
    if (pub[rec.oid] or 0) == bits then return end
    pub[rec.oid] = bits > 0 and bits or nil
    for who, p in pairs(S.online()) do
        if R.streams[who] then S.send(p, "publicDelta", { oid = rec.oid, bits = bits }) end
    end
end

O.onRecordChanged = function(rec)
    S.push(S.audience(rec), rec, false)
    S.pushPublic(rec)
end

-- 陣營現在的領袖＋成員（帳號清單）
function S.factionUsers(f)
    local out = { f:getOwner() }
    local players = f:getPlayers()
    for i = 0, players:size() - 1 do out[#out + 1] = players:get(i) end
    return out
end

-- 陣營分享整批暫停之後（O.pauseFaction）：每位車主一則通知寫台數（陣營還在、換了領袖：到車隊視窗恢復；
-- 解散、改名或同名重建：另一句），再重送這些車主與陣營現在成員的快照——成員的「分享給我」立刻少掉這些車、出現暫停提示列
O.onFactionPaused = function(name, leader, recs)
    local count, users = {}, {}
    for _, rec in ipairs(recs) do
        local o = rec.ownerUser
        if count[o] == nil then count[o] = 0; users[#users + 1] = o end
        count[o] = count[o] + 1
    end
    local f = Faction.getFaction(name)
    local key = (f ~= nil and f:getOwner() ~= leader) and "IGUI_MVM_Notice_FactionPaused" or "IGUI_MVM_Notice_FactionGone"
    for _, o in ipairs(users) do S.notify(o, { key = key, who = name, n = count[o], bad = true }) end
    if f then
        for _, u in ipairs(S.factionUsers(f)) do if count[u] == nil then users[#users + 1] = u end end
    end
    S.resnapshot(users)
end

-- 改變收件者集合的突變（分享、陣營）：先記下舊集合；第三方車身標記（可拖曳名單）跟著更新
local function change(rec, fn)
    local before = S.audience(rec)
    fn()
    S.push(union(before, S.audience(rec)), rec, false)
    if O.syncClaimTags then O.syncClaimTags(rec, nil) end
end

-- quota：used／base（基本）／permanent／rental／paid（Economy 可用名額）／total，
-- economy＝整合狀態（MVM.Econ.status 或 UNAVAILABLE）。quotaUsed／quotaLimit 保留給舊 client。
-- pub＝公開分享表；releaseDays＝閒置釋放天數（0＝關閉；玩家在線時期限是「現在＋天數」，客戶端自己換算日期）；
-- guard＝停車保全名額分項（MVM.Parked.counts）；notices／noticeRead＝通知紀錄（舊到新）與已讀到的時間（Notices.lua）；
-- factionPaused＝分享給我（陣營成員）但陣營分享暫停中的車 { { name＝陣營名, oids }, ... }：只有陣營名與 oid，
-- 不給車名、車主、位置（「分享給我」的暫停提示列與上車被擋的原因用）
function S.snapshot(player, who)
    local ledger = O.state()
    -- 組清單前先把失效的陣營分享（換領袖、改名、解散）整批暫停：會通知車主並重送受影響玩家的快照，
    -- 所以放在建立這次的 stream 之前（巢狀重送的那份先到，這份最後到、stream 也是這份）
    if ledger then O.pauseStaleFactions() end
    local st = { streamId = getRandomUUID(), seq = 0 }
    R.streams[who] = st
    local rows, paused, pausedList = {}, {}, {}
    local quota = nil
    if ledger then
        for _, rec in pairs(ledger.recordsByOid) do
            local row = S.row(rec, who)
            if row then
                rows[#rows + 1] = row
            elseif O.factionPausedFor(rec, who) then
                local g = paused[rec.factionName]
                if g == nil then
                    g = { name = rec.factionName, oids = {} }
                    paused[rec.factionName], pausedList[#pausedList + 1] = g, g
                end
                g.oids[#g.oids + 1] = rec.oid
            end
        end
        for _, row in ipairs(S.extraRows and S.extraRows(who) or {}) do rows[#rows + 1] = row end
        quota = MVM.Econ and MVM.Econ.summary(who) or { economy = "OFF", permanent = 0, rental = 0, paid = 0 }
        quota.used, quota.base = O.quotaUsed(who), O.quotaBase(who)
        quota.total = quota.base + quota.paid
    end
    -- ponytail: 單一封包送出，列數＝自己的車＋被分享的車＋陣營分享車＋MVCK 待轉列，後兩者沒有上限；
    -- 約 1000 列（每列 0.4–1 KB）會碰到 1 MB 封包上限（見 S.sendAdminParts 的註解）。真有大陣營時照 sendAdminParts 分段
    local notices, noticeRead = nil, nil
    if MVM.Notices then notices, noticeRead = MVM.Notices.list(who) end
    S.send(player, "fleetSnapshot", { streamId = st.streamId, seq = 0, rows = rows,
        quotaUsed = quota and quota.used or 0, quotaLimit = quota and quota.total or 0, quota = quota,
        status = O.R.status, pub = ledger and S.publicTable() or nil, releaseDays = S.releaseDays(),
        guard = ledger and MVM.Parked and MVM.Parked.counts(who) or nil, notices = notices, noticeRead = noticeRead,
        factionPaused = pausedList })
end

-- 名額規則變了：重送這些線上玩家的快照（名額顯示即時更新）；users＝nil 表示全部線上玩家
function S.resnapshot(users)
    local online = S.online()
    if users == nil then
        for who, p in pairs(online) do S.snapshot(p, who) end
        return
    end
    for _, who in ipairs(users) do if online[who] then S.snapshot(online[who], who) end end
end

-- 全服預設名額＝沙盒 ClaimsPerPlayer、閒置釋放天數＝沙盒 InactivityReleaseDays、停車保全模式＝ParkedGuard、
-- 免費保全名額＝GuardSlotsPerPlayer（唯一真相，帳本不另存）。
-- R.sandboxSeen 是上次看到的值：原版沙盒 UI 送回整份選項（GameServer.java:1694-1708）會直接改掉它們，
-- 每分鐘比對一次，變了就重送快照（名額、期限與保全顯示即時更新）
local DEFAULT_QUOTA_OPTION = "MinidoracatVehicleManager.ClaimsPerPlayer"
local RELEASE_DAYS_OPTION = "MinidoracatVehicleManager.InactivityReleaseDays"
local GUARD_MODE_OPTION = "MinidoracatVehicleManager.ParkedGuard"
local GUARD_SLOTS_OPTION = "MinidoracatVehicleManager.GuardSlotsPerPlayer"
function S.defaultQuota() return MVM.sandbox("ClaimsPerPlayer", 3) end
function S.releaseDays() return MVM.sandbox("InactivityReleaseDays", 30) end

local function sandboxNow()
    return { quota = S.defaultQuota(), days = S.releaseDays(), guard = MVM.guardMode(), slots = MVM.guardSlotsDefault() }
end

function S.watchSandbox()
    local now2 = sandboxNow()
    local old = R.sandboxSeen
    R.sandboxSeen = now2
    if old == nil or (old.quota == now2.quota and old.days == now2.days and old.guard == now2.guard and old.slots == now2.slots) then
        return
    end
    if old.quota ~= now2.quota then
        O.audit("WARN", "ADMIN_QUOTA", { actor = "SANDBOX", role = "ADMIN", reason = "DEFAULT " .. tostring(old.quota) .. "->" .. now2.quota })
    end
    if old.days ~= now2.days then
        O.audit("WARN", "ADMIN_RELEASE_DAYS", { actor = "SANDBOX", role = "ADMIN", reason = tostring(old.days) .. "->" .. now2.days })
    end
    if old.guard ~= now2.guard then
        O.audit("WARN", "ADMIN_GUARD", { actor = "SANDBOX", role = "ADMIN", reason = "MODE " .. tostring(old.guard) .. "->" .. now2.guard })
    end
    if old.slots ~= now2.slots then
        O.audit("WARN", "ADMIN_GUARD", { actor = "SANDBOX", role = "ADMIN", reason = "SLOTS " .. tostring(old.slots) .. "->" .. now2.slots })
    end
    S.resnapshot(nil)
end

-- SandboxOptions.set／toLua／saveServerLuaFile（SandboxOptions.java:572-582,279-285,683-685）：
-- 存檔是 FileWriter，I/O 錯誤時回 false（:862-962），只有回 true 才算寫入
local function writeSandbox(opts, option, value)
    opts:set(option, value)
    opts:toLua()
    return opts:saveServerLuaFile(getServerName())
end

-- 管理頁改全服設定：寫沙盒並存伺服器沙盒檔。失敗時記憶體與檔案都盡力改回原值、回 false（呼叫端回 SAVE_FAILED、不廣播）。
-- 成功才通知線上客戶端同步 SandboxVars（伺服器沒有原版 Lua 廣播；客戶端副本舊了，原版沙盒 UI 存檔會蓋回舊值）並重送快照
local function saveSandbox(option, value, old)
    local opts = getSandboxOptions()
    local ok, saved = pcall(writeSandbox, opts, option, value)
    if ok and saved == true then
        R.sandboxSeen = sandboxNow()
        local seen = R.sandboxSeen
        local sync = { claimsPerPlayer = seen.quota, releaseDays = seen.days, parkedGuard = seen.guard, guardSlots = seen.slots }
        for _, p in pairs(S.online()) do S.send(p, "sandboxSync", sync) end
        S.resnapshot(nil)
        return true
    end
    pcall(writeSandbox, opts, option, old)
    MVM.log(option .. " save failed: " .. tostring(saved))
    return false
end

-- 管理員總表分段送出。每條連線的送出緩衝區固定 1,000,000 bytes、不會擴充（UdpConnection.java:40-41），
-- sendServerCommand（GameServer.java:3460-3482）在 startPacket 上鎖（UdpConnection.java:198-201）後序列化、
-- 只接 IOException：超過時丟 BufferOverflowException，封包沒送、鎖不釋放（解鎖在 endPacket :303-305）。
-- 所以每段最多 ADMIN_PART_ITEMS 筆（車輛列與玩家合計）：最壞一列約 0.5 KB（車名 64 bytes、帳號 50 字元），
-- 每段遠低於 200 KB（harness 以 TableNetworkUtils 格式量測）。同一次總表各段帶同一個 id 與 part／parts，
-- meta（ok、status、migrationAvailable、override、defaultQuota）只在第 1 段；client 收齊才替換（Client.lua）
S.ADMIN_PART_ITEMS = 200
function S.sendAdminParts(player, meta, rows, players)
    local per, nr = S.ADMIN_PART_ITEMS, #rows
    local total = nr + #players
    local parts = math.max(1, math.ceil(total / per))
    local id = getRandomUUID()
    for part = 1, parts do
        local pr, pp = {}, {}
        for i = (part - 1) * per + 1, math.min(part * per, total) do
            if i <= nr then pr[#pr + 1] = rows[i] else pp[#pp + 1] = players[i - nr] end
        end
        local payload = part == 1 and meta or {}
        payload.id, payload.part, payload.parts, payload.rows, payload.players = id, part, parts, pr, pp
        S.send(player, "adminSnapshot", payload)
    end
end

-- 管理員總表：只給 ManipulateVehicle；位置只給 owner 資訊與最後已知點（即時追蹤屬 Phase 4 的另一權限）。
-- players：每位車主、MVCK 待轉項或個人名額（含保全名額）設定的人，以及登入過但還沒有車的玩家（knownUsers），管理頁依此分組。
-- 已用名額在同一趟掃描裡累計（結果同 O.quotaUsed：計入 quota 的紀錄＋待轉項），不逐人重掃待轉項。
-- 保全名額欄位（guardBase／guardCustom／guardPaid／guardUsed／guardLimit）只在 SLOTS 模式填
function S.adminSnapshot(player)
    local st = O.state()
    if not O.isAdmin(player) or st == nil then
        return S.sendAdminParts(player, { ok = false, migrationAvailable = false, override = false }, {}, {})
    end
    local rows, used = {}, {}
    for _, rec in pairs(st.recordsByOid) do
        rows[#rows + 1] = { oid = rec.oid, owner = rec.ownerUser, state = rec.recordState, script = rec.vehicleScript,
            name = rec.customName or "", reason = rec.quarantineReason, lastKnownX = rec.lastKnownX, lastKnownY = rec.lastKnownY,
            lastKnownZ = rec.lastKnownZ, lastKnownAtMs = rec.lastKnownAtMs, releaseDueAtMs = rec.releaseDueAtMs, removedAtMs = rec.removedAtMs }
        local owner = rec.ownerUser
        if owner then used[owner] = (used[owner] or 0) + (O.countsForQuota(rec) and 1 or 0) end
    end
    -- extraRows 是 MVCK 待轉項，每筆都計入車主 quota（同 O.pendingCount）
    for _, row in ipairs(S.extraRows and S.extraRows(nil) or {}) do
        rows[#rows + 1] = row
        if row.owner then used[row.owner] = (used[row.owner] or 0) + 1 end
    end
    for user in pairs(st.quotaOverrides) do used[user] = used[user] or 0 end
    for user in pairs(st.guardOverrides) do used[user] = used[user] or 0 end
    local slots = MVM.Parked and MVM.guardMode() == MVM.GUARD.SLOTS
    for user in pairs(st.knownUsers) do used[user] = used[user] or 0 end
    local players = {}
    for user, n in pairs(used) do
        local base = O.quotaBase(user)
        local act = st.ownerActivity[user]
        local p = { user = user, used = n, base = base, limit = base + (O.paidSlots and O.paidSlots(user) or 0),
            custom = MVM.isInt(st.quotaOverrides[user]), lastSeenAtMs = act and act.lastSuccessfulLoginAtMs or nil }
        if slots then
            p.guardBase, p.guardPaid, p.guardCustom, p.guardUsed = MVM.Parked.slots(user)
            p.guardLimit = p.guardBase + p.guardPaid
        end
        players[#players + 1] = p
    end
    O.audit("INFO", "ADMIN_VIEW", { actor = O.principal(player), role = "ADMIN", count = #rows })
    local migrationAvailable = MVM.Migration ~= nil and MVM.Migration.available()
    local conflicts = O.R.identityConflicts
    S.sendAdminParts(player, { ok = true, status = O.R.status, migrationAvailable = migrationAvailable,
        override = O.overrideActive(player), defaultQuota = S.defaultQuota(), releaseDays = S.releaseDays(), identitySteam = O.steamMode(),
        identityImported = st.identityImportedAtMs ~= nil, identityConflicts = conflicts and conflicts.names or nil,
        guardMode = MVM.guardMode(), guardSlots = MVM.guardSlotsDefault() }, rows, players)
end

-- -------------------------------------------------------------- validation ---
local function validToken(v) return type(v) == "string" and #v >= 8 and #v <= 64 and v:match("^[%w%-_]+$") ~= nil end

local TYPES = {
    id = MVM.isInt,
    uuid = function(v) return type(v) == "string" and #v >= 8 and #v <= 64 and v:match("^[%w%-]+$") ~= nil end,
    token = validToken,
    bool = function(v) return type(v) == "boolean" end,
    bits = MVM.validShareBits,
    publicBits = MVM.validPublicBits,
    user = function(v) return type(v) == "string" and #v >= 1 and #v <= 50 and not v:find("%c") end,
    text = function(v) return type(v) == "string" and #v <= 256 end,
    amount = function(v) return MVM.isInt(v) and v >= -1 and v <= 100 end,
    defaultAmount = function(v) return MVM.isInt(v) and v >= 0 and v <= 20 end, -- 同沙盒 ClaimsPerPlayer 範圍
    releaseDays = function(v) return MVM.isInt(v) and v >= 0 and v <= 365 end, -- 同沙盒 InactivityReleaseDays 範圍
    op = function(v) return v == "RELEASE" or v == "ACTIVATE" end,
    migrationOp = function(v) return v == "IMPORT" end,
    identityOp = function(v) return v == "IMPORT" or v == "REBIND" end,
    name = function(v) return type(v) == "string" and #v >= 1 and #v <= 64 and v:match("^[%w_]+$") ~= nil end,
    paidOp = function(v) return v == "GET" or v == "SET" end,
    revision = function(v) return MVM.isInt(v) and v >= 0 and v <= 2147483647 end,
    paidPlan = function(v) return MVM.PaidSlots ~= nil and MVM.PaidSlots.validPlan(v) end,
    product = function(v) return v == MVM.ECON_PRODUCT or v == MVM.GUARD_PRODUCT end,
    guardMode = function(v) return MVM.isInt(v) and v >= MVM.GUARD.OFF and v <= MVM.GUARD.SLOTS end, -- 同沙盒 ParkedGuard
    legacyRow = function(v) return type(v) == "string" and #v <= 40 and v:match("^legacy%-%d+$") ~= nil end, -- MVCK 待轉列 oid
    ms = function(v) return MVM.isInt(v) and v >= 0 and v <= 1e15 end, -- 毫秒時間戳
}
-- 清單參數：1..max 個、連續陣列（沒有其他鍵）、每個都通過 valid 且不重複
local function uniqueList(v, max, valid)
    if type(v) ~= "table" then return false end
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    if n < 1 or n > max then return false end
    local seen = {}
    for i = 1, n do
        local item = v[i]
        if not valid(item) or seen[item] then return false end
        seen[item] = true
    end
    return true
end
-- 批次名額的帳號清單（最多 BATCH_MAX 位）；陣營分享一鍵恢復的紀錄清單（最多 RESTORE_MAX 筆，車主自己的車）
S.BATCH_MAX, S.RESTORE_MAX = 500, 200
function TYPES.users(v) return uniqueList(v, S.BATCH_MAX, TYPES.user) end
function TYPES.oids(v) return uniqueList(v, S.RESTORE_MAX, TYPES.uuid) end

-- 身分匯入列：1..IDENTITY_ROWS_MAX 列的連續陣列，每列 { u＝合法帳號（不重複）, s＝"" 或 SteamID64 字串 }。
-- 先驗格式才交給 tonumber：它就是 Double.parseDouble，也吃 7.6E16、前後空白、0x1p56（KahluaUtil.java:293）。
-- 上限只是防呆：伺服器送出的 whitelist 封包（NetworkUsersPacket）每帳號 34 bytes＋8 個字串，寫進 1,000,000 bytes 緩衝
-- （NetworkUser.java:163-180、UdpConnection.java:40），每帳號約 90 bytes 時約 1.1 萬帳號才會撞上限
S.IDENTITY_ROWS_MAX = 10000
function TYPES.identityRows(v)
    if type(v) ~= "table" then return false end
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    if n < 1 or n > S.IDENTITY_ROWS_MAX then return false end
    local seen = {}
    for i = 1, n do
        local r = v[i]
        if type(r) ~= "table" or not TYPES.user(r.u) or seen[r.u] or type(r.s) ~= "string" then return false end
        if r.s ~= "" and r.s:match("^7656119%d%d%d%d%d%d%d%d%d%d$") == nil then return false end
        seen[r.u] = true
    end
    return true
end

-- 欄位 → 型別；? 結尾＝選填。未列出的欄位一律拒收（不讓 client 夾帶 ownerUser 之類）
local SCHEMA = {
    prepareClaim = { vehicleId = "id" },
    claim = { claimAttemptId = "uuid" },
    unclaim = { vehicleId = "id", expectedOid = "uuid", expectedEpoch = "uuid" },
    reportLost = { expectedOid = "uuid" },
    cancelRebind = { expectedOid = "legacyRow" },
    cancelRelease = { expectedOid = "uuid" },
    reissueWitness = { vehicleId = "id", expectedOid = "uuid" },
    rename = { expectedOid = "uuid", expectedEpoch = "uuid", name = "text" },
    setFactionShare = { expectedOid = "uuid", expectedEpoch = "uuid", enabled = "bool", actionBits = "bits" },
    restoreFactionShare = { oids = "oids" },
    setPublicShare = { expectedOid = "uuid", expectedEpoch = "uuid", actionBits = "publicBits" },
    addMember = { expectedOid = "uuid", username = "user", actionBits = "bits" },
    removeMember = { expectedOid = "uuid", username = "user" },
    leaveShared = { expectedOid = "uuid" },
    transfer = { vehicleId = "id", expectedOid = "uuid", expectedEpoch = "uuid", recipient = "user" },
    dismissRecord = { expectedOid = "uuid" },
    adminSetQuota = { usernames = "users", amount = "amount" },
    adminSetDefaultQuota = { amount = "defaultAmount" },
    adminSetReleaseDays = { amount = "releaseDays" },
    adminRecover = { expectedOid = "uuid", op = "op", ["vehicleId?"] = "id" },
    fleetSubscribe = {},
    fleetResync = {},
    prepareAction = { class = "name", vehicleId = "id", ["partId?"] = "name" },
    adminList = {},
    adminMigration = { op = "migrationOp" },
    adminIdentity = { op = "identityOp", ["rows?"] = "identityRows" },
    setAdminOverride = { enabled = "bool" },
    adminPaidSlots = { op = "paidOp", ["values?"] = "paidPlan", ["expectedRevision?"] = "revision", ["reason?"] = "text",
        ["product?"] = "product" },
    setGuard = { expectedOid = "uuid", enabled = "bool" },
    adminSetGuardMode = { mode = "guardMode" },
    adminSetGuardSlots = { amount = "defaultAmount" }, -- 同沙盒 GuardSlotsPerPlayer 範圍 0..20
    adminSetGuardQuota = { usernames = "users", amount = "amount" },
    noticesRead = { upToMs = "ms" },
    hitReport = { vehicleId = "id" },
}
-- 不帶 requestId、不回 ACK 的命令
local QUERIES = { fleetSubscribe = true, fleetResync = true, prepareAction = true, adminList = true, hitReport = true }

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

-- 車旁：同層、到車身距離 ≤ ClaimDistance（§6.3；與指令防火牆同一個 CG.within，長拖車站在車旁任何一段都算）
local function near(player, vehicle)
    return MVM.CommandGate.within(vehicle, player:getX(), player:getY(), player:getZ(), MVM.sandbox("ClaimDistance", 2.5))
end

local function claimable(vehicle)
    if O.hostPart(vehicle, nil) == nil then return "NOT_CLAIMABLE" end
    if vehicle:getScriptName():find("Burnt", 1, true) then return "NOT_CLAIMABLE" end
    if vehicle:getVehicleTowedBy() ~= nil then return "NOT_CLAIMABLE_TOWED" end
    return nil
end

local UNCLAIMED = { UNCLAIMED = true, UNCLAIMED_WITNESS_STRIPPED = true, UNCLAIMED_ORPHANED_OLD = true }
-- 可以綁的車：沒有紀錄（lookup 也會順手把匯入後的 MVCK 待轉車轉給原車主），並存期間 MVCK 綁著、還沒匯入的車也不行
-- （否則匯入前別人能先綁走，匯入後原車主的待轉項永遠對不上；Migration.lua M.legacyClaimed）
local function claimRefusal(v)
    if not UNCLAIMED[O.lookup(v)] then return "ALREADY_CLAIMED" end
    if MVM.Migration and MVM.Migration.legacyClaimed(v) then return "LEGACY_CLAIMED" end
    return nil
end

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

function S.findFactionOf(user)
    local list = Faction.getFactions()
    for i = 0, list:size() - 1 do
        local f = list:get(i)
        if f:getOwner() == user or f:isMember(user) then return f end
    end
    return nil
end

-- 開關陣營共享（f＝nil 表示關閉）；車主指令與 MVCK 匯入共用，稽核由呼叫端寫
function S.applyFactionShare(rec, f, bits)
    change(rec, function()
        if f then
            rec.factionShare, rec.factionName, rec.factionOwnerUser, rec.factionState, rec.factionActionBits =
                true, f:getName(), f:getOwner(), "GRANTED", bits
            O.R.factionRefs[rec.oid] = f
        else
            rec.factionShare, rec.factionName, rec.factionOwnerUser, rec.factionState, rec.factionActionBits =
                false, nil, nil, "NONE", 0
            O.R.factionRefs[rec.oid] = nil
        end
        O.bump(rec)
    end)
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
    bad = claimRefusal(v)
    if bad then return fail(bad) end
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
    bad = claimRefusal(v)
    if bad then return fail(bad) end
    local rec = O.createRecord(who, v, O.hostPart(v, nil))
    O.audit("INFO", "CLAIM", { actor = who, role = "OWNER", oid = rec.oid, epoch = rec.epoch, owner = who,
        vehicle = rec.sqlIdHint, x = v:getX(), y = v:getY(), z = v:getZ() })
    S.push(S.audience(rec), rec, false)
    if MVM.Parked then MVM.Parked.discover(v) end
    return { ok = true, oid = rec.oid }
end

H.unclaim = function(player, who, a)
    local v, rec, reason = ownLiveRecord(player, who, a)
    if rec == nil then return fail(reason) end
    if rec.epoch ~= a.expectedEpoch then return fail("STALE_TARGET") end
    if O.hasCargo(rec) then return fail("CARRIER_HAS_CARGO") end -- 載著受保護的車：先卸下（方案 A）
    O.stripWitness(v, O.hostPart(v, rec.witnessPartId))
    O.setState(rec, "RELEASED", "UNCLAIM", { actor = who })
    O.audit("INFO", "UNCLAIM", { actor = who, oid = rec.oid, owner = who, vehicle = rec.sqlIdHint })
    if MVM.RentLock then MVM.RentLock.evaluate(who) end
    return { ok = true }
end

H.reportLost = function(player, who, a)
    local rec, reason = ownRecord(who, a.expectedOid)
    if rec == nil then return fail(reason) end
    if rec.recordState ~= "ACTIVE" and rec.recordState ~= "WITNESS_STALE" then return fail("INVALID_STATE") end
    if O.hasCargo(rec) then return fail("CARRIER_HAS_CARGO") end
    O.beginRelease(rec, "REPORT_LOST")
    return { ok = true, releaseDueAtMs = rec.releaseDueAtMs }
end

-- MVCK 待轉項：車主放棄（車找不到、舊編號消失而轉不了正）→ 刪掉、釋出名額（Migration.lua M.cancel）。
-- 待轉列的 oid 是 legacy-<舊 ID>，不是 UUID；車不在世界上，不看距離
H.cancelRebind = function(player, who, a)
    if MVM.Migration == nil then return fail("NO_SUCH_RECORD") end
    local bad = MVM.Migration.cancel(who, a.expectedOid)
    if bad then return fail(bad) end
    if MVM.RentLock then MVM.RentLock.evaluate(who) end
    return { ok = true }
end

H.cancelRelease = function(player, who, a)
    local rec, reason = ownRecord(who, a.expectedOid)
    if rec == nil then return fail(reason) end
    if rec.recordState ~= "PENDING_RELEASE" then return fail("INVALID_STATE") end
    O.setState(rec, "ACTIVE", "RELEASE_CANCELLED", { actor = who })
    return { ok = true }
end

-- 車主看過通知紀錄（車隊視窗「紀錄」分頁）：已讀到 upToMs（伺服器夾到現在、不倒退）。只動自己的紀錄
H.noticesRead = function(player, who, a)
    if MVM.Notices then MVM.Notices.markRead(who, a.upToMs) end
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
        f = S.findFactionOf(who)
        if f == nil then return fail("NO_FACTION") end
    end
    S.applyFactionShare(rec, f, a.actionBits)
    O.audit("INFO", "ACL_CHANGE", { actor = who, oid = rec.oid, owner = who,
        reason = a.enabled and ("FACTION " .. tostring(a.actionBits)) or "FACTION_OFF" })
    return { ok = true }
end

-- 恢復陣營分享的條件：自己的、可授權的、分享給陣營過（有權限位）、自己現在仍在同名陣營。回那個陣營或 nil, 原因
local function restorable(rec, who)
    if rec == nil then return nil, "NO_SUCH_RECORD" end
    if rec.ownerUser ~= who then return nil, "NOT_OWNER" end
    if not O.AUTHORIZABLE[rec.recordState] or rec.recordState == "QUARANTINED" or not rec.factionShare
        or (rec.factionActionBits or 0) == 0 then return nil, "INVALID_STATE" end
    local f = Faction.getFaction(rec.factionName)
    if f == nil then return nil, "FACTION_GONE" end
    if not (f:getOwner() == who or f:isMember(who)) then return nil, "FACTION_LEFT" end
    return f
end

-- 陣營換領袖（或同名重建）後車主一鍵恢復（車隊視窗「我的車」最上面那列）：改綁陣營現在的領袖，權限沿用原本的
-- factionActionBits（不必重勾）；已經恢復的算成功。一個命令恢復多台：逐台送 setFactionShare 會撞每 5 秒 RATE_MAX 個命令的限流。
-- 玩家只能在一個陣營，所以可恢復的車都屬同一個陣營；恢復後重送陣營現在成員的快照（暫停提示列跟著更新）
H.restoreFactionShare = function(player, who, a)
    if not MVM.sandbox("AllowFactionShare", true) then return fail("FACTION_SHARE_DISABLED") end
    local st = O.state()
    local restored, failed, why, faction = 0, 0, nil, nil
    for _, oid in ipairs(a.oids) do
        local rec = st.recordsByOid[oid]
        local f, reason = restorable(rec, who)
        if f == nil then
            failed, why = failed + 1, why or reason
        else
            if rec.factionState ~= "GRANTED" or O.factionStale(rec) then
                S.applyFactionShare(rec, f, rec.factionActionBits)
                O.audit("INFO", "ACL_CHANGE", { actor = who, oid = rec.oid, owner = who,
                    reason = "FACTION_RESTORED " .. tostring(rec.factionActionBits) })
            end
            restored, faction = restored + 1, f
        end
    end
    if restored == 0 then return fail(why) end
    S.resnapshot(S.factionUsers(faction))
    return { ok = true, restored = restored, failed = failed, failReason = why }
end

-- 公開給所有人（actionBits＝0 關閉）：只能是 MVM.PUBLIC_MASK 內的動作（TYPES.publicBits）。陌生人經公開表得知
H.setPublicShare = function(player, who, a)
    local rec, reason = ownManageable(who, a)
    if rec == nil then return fail(reason) end
    change(rec, function() rec.publicBits = a.actionBits; O.bump(rec) end)
    S.pushPublic(rec)
    O.audit("INFO", "ACL_CHANGE", { actor = who, oid = rec.oid, owner = who,
        reason = a.actionBits > 0 and ("PUBLIC " .. a.actionBits) or "PUBLIC_OFF" })
    return { ok = true }
end

-- 停車保全開關（只在 SLOTS 模式）。沒選過的車照綁定時間自動用名額（ParkedGuard.lua ranked），開關只是改順序：
-- 開＝這台排到沒選過的車前面（把名額移過來），車主手動開的車已佔滿名額 → GUARD_FULL（含名額調降後超出的那台再按一次）；
-- 關＝rec.guard=false，名額讓給下一台。一台的變動會讓別台 ON／OVER 互換，所以重送車主整份快照
H.setGuard = function(player, who, a)
    if MVM.Parked == nil or MVM.guardMode() ~= MVM.GUARD.SLOTS then return fail("GUARD_NOT_SLOTS") end
    local rec, reason = ownRecord(who, a.expectedOid)
    if rec == nil then return fail(reason) end
    if not MVM.Parked.GUARDABLE[rec.recordState] then return fail("INVALID_STATE") end
    if a.enabled then
        if MVM.Parked.state(rec) == "ON" then return { ok = true, enabled = true } end
        local base, paid, _, _, explicit = MVM.Parked.slots(who)
        if explicit - (rec.guard == true and 1 or 0) >= base + paid then return fail("GUARD_FULL") end
    elseif rec.guard == false then
        return { ok = true, enabled = false }
    end
    rec.guard, rec.guardAtMs = a.enabled, a.enabled and now() or nil
    O.bump(rec)
    O.audit("INFO", "GUARD_SET", { actor = who, oid = rec.oid, owner = who, reason = a.enabled and "ON" or "OFF" })
    S.push(S.audience(rec), rec, false)
    S.resnapshot({ who })
    return { ok = true, enabled = a.enabled }
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
    if MVM.Parked then MVM.Parked.discover(v) end
    if MVM.RentLock then
        MVM.RentLock.evaluate(who)
        MVM.RentLock.evaluate(a.recipient)
    end
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

-- 個人基本名額（絕對值；-1＝恢復全服預設），一次最多 BATCH_MAX 人；逐人稽核，重送受影響的線上玩家快照
H.adminSetQuota = function(player, who, a)
    if not O.isAdmin(player) then return fail("NOT_ADMIN") end
    local overrides = O.state().quotaOverrides
    local value = a.amount >= 0 and a.amount or nil
    for _, user in ipairs(a.usernames) do
        local old = overrides[user]
        O.mapSet("quotaOverrides", user, value)
        O.audit("WARN", "ADMIN_QUOTA", { actor = who, role = "ADMIN", owner = user,
            reason = "USER " .. tostring(old or "DEFAULT") .. "->" .. tostring(value or "DEFAULT") })
    end
    O.bump(nil)
    S.resnapshot(a.usernames)
    return { ok = true, count = #a.usernames }
end

-- 全服預設名額（沙盒 ClaimsPerPlayer）：存檔成功才回 ok（saveSandbox）
H.adminSetDefaultQuota = function(player, who, a)
    if not O.isAdmin(player) then return fail("NOT_ADMIN") end
    local old = S.defaultQuota()
    if not saveSandbox(DEFAULT_QUOTA_OPTION, a.amount, old) then return fail("SAVE_FAILED") end
    O.audit("WARN", "ADMIN_QUOTA", { actor = who, role = "ADMIN", reason = "DEFAULT " .. tostring(old) .. "->" .. a.amount })
    return { ok = true, amount = a.amount }
end

-- 閒置釋放天數（沙盒 InactivityReleaseDays，0＝關閉）：存檔成功才回 ok；下一次維護（每分鐘）就用新值
H.adminSetReleaseDays = function(player, who, a)
    if not O.isAdmin(player) then return fail("NOT_ADMIN") end
    local old = S.releaseDays()
    if not saveSandbox(RELEASE_DAYS_OPTION, a.amount, old) then return fail("SAVE_FAILED") end
    O.audit("WARN", "ADMIN_RELEASE_DAYS", { actor = who, role = "ADMIN", reason = tostring(old) .. "->" .. a.amount })
    return { ok = true, amount = a.amount }
end

-- 停車保全模式（沙盒 ParkedGuard 1..3）：存檔成功才回 ok；保全每秒依新模式重算
H.adminSetGuardMode = function(player, who, a)
    if not O.isAdmin(player) then return fail("NOT_ADMIN") end
    local old = MVM.guardMode()
    if not saveSandbox(GUARD_MODE_OPTION, a.mode, old) then return fail("SAVE_FAILED") end
    O.audit("WARN", "ADMIN_GUARD", { actor = who, role = "ADMIN", reason = "MODE " .. tostring(old) .. "->" .. a.mode })
    return { ok = true, mode = a.mode }
end

-- 每位玩家的免費保全名額（沙盒 GuardSlotsPerPlayer）：存檔成功才回 ok
H.adminSetGuardSlots = function(player, who, a)
    if not O.isAdmin(player) then return fail("NOT_ADMIN") end
    local old = MVM.guardSlotsDefault()
    if not saveSandbox(GUARD_SLOTS_OPTION, a.amount, old) then return fail("SAVE_FAILED") end
    O.audit("WARN", "ADMIN_GUARD", { actor = who, role = "ADMIN", reason = "SLOTS " .. tostring(old) .. "->" .. a.amount })
    return { ok = true, amount = a.amount }
end

-- 個人保全名額（絕對值；-1＝恢復全服預設），同 adminSetQuota：逐人稽核、重送受影響的線上玩家快照
H.adminSetGuardQuota = function(player, who, a)
    if not O.isAdmin(player) then return fail("NOT_ADMIN") end
    local overrides = O.state().guardOverrides
    local value = a.amount >= 0 and a.amount or nil
    for _, user in ipairs(a.usernames) do
        local old = overrides[user]
        O.mapSet("guardOverrides", user, value)
        O.audit("WARN", "ADMIN_GUARD", { actor = who, role = "ADMIN", owner = user,
            reason = "USER " .. tostring(old or "DEFAULT") .. "->" .. tostring(value or "DEFAULT") })
    end
    O.bump(nil)
    S.resnapshot(a.usernames)
    return { ok = true, count = #a.usernames }
end

-- RELEASE：任一非終態 → RELEASED。ACTIVATE：QUARANTINED 且車已載入、三欄位相符、同 sqlId 無其他可授權紀錄 → 重寫見證 ACTIVE
H.adminRecover = function(player, who, a)
    if not O.isAdmin(player) then return fail("NOT_ADMIN") end
    local rec = O.state().recordsByOid[a.expectedOid]
    if rec == nil then return fail("NO_SUCH_RECORD") end
    if O.TOMBSTONE[rec.recordState] then return fail("INVALID_STATE") end
    if a.op == "RELEASE" then
        -- 載著受保護的車：管理員開越權卸下後再釋出（不留下沒綁定、載著受保護車的拖車）
        if O.hasCargo(rec) then return fail("CARRIER_HAS_CARGO") end
        O.setState(rec, "RELEASED", "ADMIN_RELEASE", { actor = who, role = "ADMIN" })
        if MVM.RentLock then MVM.RentLock.evaluate(rec.ownerUser) end
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
        if MVM.Parked then MVM.Parked.discover(v) end
    end
    O.audit("WARN", "ADMIN_BYPASS", { actor = who, role = "ADMIN", oid = rec.oid, owner = rec.ownerUser, reason = a.op })
    return { ok = true }
end

-- 越權開關：只管 O.canUse 的放行；管理頁本身的功能（解除綁定、名額、匯入）照舊只看 O.isAdmin
H.setAdminOverride = function(player, who, a)
    if not O.setOverride(player, a.enabled) then return fail("NOT_ADMIN") end
    return { ok = true, enabled = a.enabled }
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

-- 付費名額方案（Economy 選用整合）：讀取、套用與寫回設定檔都在 PaidSlots.lua
H.adminPaidSlots = function(player, who, a)
    if not O.isAdmin(player) then return fail("NOT_ADMIN") end
    return MVM.PaidSlots.admin(who, a)
end

-- 身分匯入（whitelist → 綁定表）與確認改綁衝突；no-steam 沒有 SteamID，不收
H.adminIdentity = function(player, who, a)
    if not O.isAdmin(player) then return fail("NOT_ADMIN") end
    if not O.steamMode() then return fail("NOT_STEAM") end
    local out
    if a.op == "IMPORT" then
        if a.rows == nil then return fail("BAD_ARGS") end
        local res = O.importIdentities(a.rows, who)
        out = { ok = true, bound = res.bound, same = res.same, missing = res.missing, reserved = res.reserved,
            conflicts = #res.conflicts, collisions = #res.collisions }
    else
        local n = O.rebindConflicts(who)
        if n == nil then return fail("IMPORT_FIRST") end
        out = { ok = true, rebound = n }
    end
    S.resnapshot(nil) -- 剛通過驗證的線上玩家拿到自己的車隊
    return out
end

-- -------------------------------------------------------------- dispatch ---
-- 主玩家沒通過 SteamID 驗證（principal 回 nil）：管理員仍可看總表、匯入身分修好自己（角色來自連線、不看名字：
-- GameServer.java:2841），以 "?帳號" 記稽核；其他命令聚合進 DENY，每分鐘最多回一次原因。分割畫面玩家不回
local UNVERIFIED_ADMIN = { adminList = true, adminIdentity = true }
local function unverified(command, player, args)
    if not isServer() or player == nil or player:getPlayerNum() ~= 0 then return nil end
    local name = tostring(player:getUsername())
    if UNVERIFIED_ADMIN[command] and O.isAdmin(player) then return "?" .. name end
    local known = H[command] ~= nil or QUERIES[command] ~= nil
    O.deny("?" .. name, known and command or "UNKNOWN_COMMAND", nil, "IDENTITY_UNVERIFIED")
    local t = now()
    if t - (R.unverified[name] or 0) >= 60000 then
        R.unverified[name] = t
        S.send(player, "mutationAck", { ok = false, reason = "IDENTITY_UNVERIFIED", requestKind = command,
            requestId = type(args) == "table" and args.requestId or nil })
    end
    return nil
end

function S.handle(command, player, args)
    local who = O.principal(player) or unverified(command, player, args)
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
    if command == "hitReport" then return MVM.CommandGate.onHit(player, args.vehicleId) end
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
    for name, at in pairs(R.unverified) do if t - at >= 60000 then R.unverified[name] = nil end end
    O.maintain(false)
    O.scanLoaded(false)
    S.watchSandbox()
end

Events.EveryOneMinute.Add(S.minute)

-- 新生與 DB 載入的車都觸發（Phase 0 gate 10）：即時 reconcile 身分、取消 PENDING_RELEASE。
-- 拖車 MOD 卸車用 addVehicleDebug，本事件在它呼叫 addToWorld 時就觸發（42.21 LuaManager.java:10821 → BaseVehicle.java:7964
-- createPhysics → :904），此時還沒配 sqlId（:10822 才 VehiclesDB2.addVehicle），車身與零件 modData 也是之後才還原
-- （MSW_Common_Commands.lua launchVehicle 先 addVehicleDebug、再 restoreSlotDataToVehicle；ATAISLaunchVehicle.lua:66 生車、
-- :88-93 還原零件）：有「已移出世界」的紀錄（接回帶見證的車）或 MVCK 待轉項（車身 SQLID 是還原後才有）時，下一個 tick 再看一次。
-- 停車保全在這兩處開始追蹤（還沒有 sqlId 的車由 ParkedGuard 每分鐘掃描補上）
R.recheck = {}
Events.OnSpawnVehicleEnd.Add(function(vehicle)
    if O.state() == nil then return end
    O.observeVehicle(vehicle)
    if MVM.Parked then MVM.Parked.discover(vehicle) end
    if O.hasOutOfWorld() or (MVM.Migration and MVM.Migration.hasPending()) then R.recheck[#R.recheck + 1] = vehicle end
end)

-- 授權裝車後的拖車（O.noteLoad）：下一個 tick 觀測，趁 keyId 認領期限內接受 Autotsar 改寫的 keyId
function O.observeSoon(vehicle) R.recheck[#R.recheck + 1] = vehicle end

Events.OnTick.Add(function()
    if #R.recheck == 0 then return end
    local list = R.recheck
    R.recheck = {}
    for _, v in ipairs(list) do
        if not v:isRemovedFromWorld() then
            O.observeVehicle(v)
            if MVM.Parked then MVM.Parked.discover(v) end
        end
    end
end)

if Events.OnServerStarted then
    Events.OnServerStarted.Add(function()
        if O.configBlocked() then
            MVM.log("DropOffWhiteListAfterDeath=true: new claims are refused (CONFIG_BLOCKED). Existing claims are still enforced.")
            O.audit("ERROR", "CONFIG_BLOCKED", { reason = "DropOffWhiteListAfterDeath" })
        end
    end)
end
