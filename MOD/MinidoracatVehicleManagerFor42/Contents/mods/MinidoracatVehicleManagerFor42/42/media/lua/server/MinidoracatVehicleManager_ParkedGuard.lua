-- 停車保全（server-only，SP 也跑）：PlayerHitVehicle 在 Java 直接扣零件耐久、中間沒有 Lua 入口（guards.md 已知坑），
-- 所以對「停著、沒有授權者在車上、沒被拖」的受保全車：
--   1. 布防：記下每個零件的基準（耐久、原件 id、型別、是否車窗、durability），durability > 0 的零件拉到 BIG
--      （武器傷害＝damage*50*(doorDamage/10)/durability 取整 → 0；durability <= 0 的 setDurability 不收，照原樣）
--   2. 每 RESTORE_MS 復原：同一原件（或兩次都沒有原件的零件，例：引擎、暖氣；槍擊從車頭會打到）耐久補回基準、
--      車窗原件不見了換一片同型新玻璃（清掉布防後才出現的碎玻璃）、
--      其他換件改認目前的為基準；durability 被重設（車重新載入、換件）就再拉高。油、電、貨物一律不補
--   3. 解除（有授權者上車、被拖、紀錄結束、模式不保全）：把拉高的 durability 寫回原值
-- 模式（沙盒 ParkedGuard）每次檢查重讀：OFF 不保全、ALL 所有綁定車、SLOTS 依保全名額：車主沒關掉的車（rec.guard ~= false）
-- 依順序前 limit 台生效（ON），其餘 OVER。limit＝基本（guardOverrides 或沙盒）＋付費；順序見 ranked。
-- 追蹤：生車、綁定成功、每 SCAN_MS 掃已載入車（O.R.bySqlId 先篩）→ discover；授權突變後 touch → 下次檢查重記基準。
-- 實機 API 驗證：E2E weapon-mp（vm-weapon-1005b，scenarios/weapon-mp/E2EScenarioServer.lua 的 snapshot／wpBoost／wpRestore）
if isClient() then return end
require "MinidoracatVehicleManager_API"
require "MinidoracatVehicleManager_OwnershipSystem"
require "MinidoracatVehicleManager_Server"

local MVM = MinidoracatVehicleManager
local O, S = MVM.Own, MVM.Srv
local P = {}
MVM.Parked = P

P.BIG = 1e9
P.TICK_MS = 250
P.CHECK_MS = 1000
P.RESTORE_MS = 10000
P.SCAN_MS = 60000
P.NOTICE_MS = 60000
-- ponytail: 每 tick 最多檢查 PER_TICK 台（約每秒 4×PER_TICK 台）；載入的受保全車多到檢查間隔明顯拉長時改分批輪詢
P.PER_TICK = 40

-- tracked：車輛 id → { v, id, oid, due, nextRestore, base（布防中才有）, glass0, touched }；byOid：oid → 同一個 entry。
-- overSeen：車主上次的 OVER 台數（變多才通知）。memo：一次 tick 內的車主排名快取
P.R = { tracked = {}, byOid = {}, overSeen = {}, attackNotified = {}, repairNotified = {}, errors = {},
    lastTick = 0, lastScan = 0, memo = nil }
local R = P.R

-- 可保全（也是保全名額計數）的紀錄狀態：QUARANTINED 不算（lookup 不是 AUTHORIZED）
P.GUARDABLE = { ACTIVE = true, WITNESS_STALE = true, PENDING_RELEASE = true }
local GUARDABLE = P.GUARDABLE

local function now() return getTimestampMs() end

local function notify(owner, payload)
    if S.notify then S.notify(owner, payload) end
end

-- ------------------------------------------------------------------ slots ---
-- 基本＝管理員個人設定（guardOverrides，絕對值）或沙盒 GuardSlotsPerPlayer；付費＝Economy（不可用時 0）
local function limitOf(owner)
    local o = O.state().guardOverrides[owner]
    local custom = MVM.isInt(o)
    local paid = MVM.Econ and MVM.Econ.guardPaid and MVM.Econ.guardPaid(owner) or 0
    return custom and o or MVM.guardSlotsDefault(), paid, custom
end

-- 名額變少（付費到期、管理員調降）讓 OVER 變多才通知車主（台數＝這次多出來的）；新綁的車排不進名額不算。第一次看到只記基準
local function noteOver(owner, n, limit)
    local old = R.overSeen[owner]
    R.overSeen[owner] = { n = n, limit = limit }
    if old ~= nil and n > old.n and limit < old.limit then
        notify(owner, { key = "IGUI_MVM_Guard_Paused", n = n - old.n, bad = true })
    end
end

-- SLOTS 的順序：先排車主手動開的（guard==true，依 guardAtMs），再排沒選過的（guard==nil，依綁定時間 claimedAtMs）；
-- 車主關掉的（guard==false）不排。免費改成依保全名額、新綁的車、買到名額都不必玩家設定（最早綁定的車先用名額），
-- 車主手動開一台＝排到沒選過的前面（把名額移過來），關掉＝讓給下一台。
-- sortByKey 是穩定排序：先排 oid、再排時間、最後排群組＝(群組, 時間, oid) 字典序
local function ranked(owner)
    local hit = R.memo and R.memo[owner]
    if hit then return hit end
    local list, byOid, byAt, byGroup, explicit = {}, {}, {}, {}, 0
    for _, rec in ipairs(O.R.byOwner[owner] or {}) do
        if rec.guard ~= false and GUARDABLE[rec.recordState] then
            local mine = rec.guard == true
            list[#list + 1] = rec
            if mine then explicit = explicit + 1 end
            byOid[rec], byGroup[rec] = rec.oid, mine and 0 or 1
            byAt[rec] = (mine and rec.guardAtMs or rec.claimedAtMs) or 0
        end
    end
    list = MVM.sortByKey(MVM.sortByKey(MVM.sortByKey(list, byOid), byAt), byGroup)
    local base, paid = limitOf(owner)
    local limit = base + paid
    local out = { n = math.min(#list, limit), explicit = explicit, on = {} }
    for i, rec in ipairs(list) do out.on[rec.oid] = i <= limit end
    noteOver(owner, math.max(0, #list - limit), limit)
    if R.memo then R.memo[owner] = out end
    return out
end

-- "ON"／"OVER"／nil（不保全：模式 OFF、紀錄不可保全、SLOTS 車主關掉）
function P.state(rec)
    local mode = MVM.guardMode()
    if mode == MVM.GUARD.OFF or rec == nil or rec.ownerUser == nil or not GUARDABLE[rec.recordState] then return nil end
    if mode == MVM.GUARD.ALL then return "ON" end
    if rec.guard == false then return nil end
    return ranked(rec.ownerUser).on[rec.oid] and "ON" or "OVER"
end

-- 名額：base, paid, custom（有個人設定）, used（SLOTS 下正在保全的台數，其他模式 0）, explicit（車主手動開的台數）。
-- 管理頁逐人用，不碰 Economy 摘要
function P.slots(owner)
    local base, paid, custom = limitOf(owner)
    if MVM.guardMode() ~= MVM.GUARD.SLOTS then return base, paid, custom, 0, 0 end
    local r = ranked(owner)
    return base, paid, custom, r.n, r.explicit
end

-- 快照用的名額分項。paid 用實際生效的 guardPaid（Economy 短暫讀不到時沿用上次值），其餘分項來自 Economy 摘要
function P.counts(owner)
    local base, paid, custom, used = P.slots(owner)
    local sum = MVM.Econ and MVM.Econ.summary and MVM.Econ.summary(owner, MVM.GUARD_PRODUCT) or {}
    return { mode = MVM.guardMode(), used = used, base = base, paid = paid, permanent = sum.permanent or 0,
        rental = sum.rental or 0, total = base + paid, economy = sum.economy or "OFF", custom = custom }
end

-- Economy 的保全名額變了：OVER 變多就通知（noteOver）
function P.limitChanged(owner)
    if O.state() == nil or MVM.guardMode() ~= MVM.GUARD.SLOTS then return end
    ranked(owner)
end

-- ------------------------------------------------------------------ parts ---
local function hasGlass(v)
    local sq = v:getSquare()
    return sq ~= nil and sq:getBrokenGlass() ~= nil
end

-- 記基準並把 durability 拉高。已是 BIG 的零件（布防中重記）沿用舊基準的原值
local function capture(e)
    local v, old, base = e.v, e.base or {}, {}
    for i = 0, v:getPartCount() - 1 do
        local part = v:getPartByIndex(i)
        local id, item, dur = part:getId(), part:getInventoryItem(), part:getDurability()
        if dur >= P.BIG and old[id] then dur = old[id].dur end
        base[id] = { cond = part:getCondition(), itemId = item and item:getID() or -1, full = item and item:getFullType() or "",
            win = part:getWindow() ~= nil, dur = dur }
        if dur > 0 and part:getDurability() < P.BIG then part:setDurability(P.BIG) end
    end
    e.base, e.glass0 = base, hasGlass(v)
end

-- 只寫回仍是 BIG 的（換過件的 durability 已被 doInventoryItemStats 重設成新件的值）
local function disarm(e)
    local v, base = e.v, e.base
    e.base = nil
    if base == nil then return end
    for i = 0, v:getPartCount() - 1 do
        local part = v:getPartByIndex(i)
        local b = base[part:getId()]
        if b and b.dur > 0 and b.dur < P.BIG and part:getDurability() >= P.BIG then part:setDurability(b.dur) end
    end
end

local function restore(e)
    local v, base, log, glass = e.v, e.base, {}, false
    for i = 0, v:getPartCount() - 1 do
        local part = v:getPartByIndex(i)
        local id, item = part:getId(), part:getInventoryItem()
        local b = base[id]
        local itemId = item and item:getID() or -1
        if b == nil then
            b = { cond = part:getCondition(), itemId = itemId, full = item and item:getFullType() or "", win = part:getWindow() ~= nil,
                dur = part:getDurability() }
            base[id] = b
        elseif itemId == b.itemId then
            if part:getCondition() < b.cond then
                log[#log + 1] = id .. ":" .. part:getCondition() .. "->" .. b.cond
                part:setCondition(b.cond)
                v:transmitPartCondition(part)
                if part:getWindow() then v:transmitPartWindow(part) end
            end
        elseif item == nil and b.itemId >= 0 and b.win and b.full ~= "" then
            local pane = instanceItem(b.full)
            if pane then
                pane:setCondition(b.cond, false)
                part:setInventoryItem(pane)
                part:setCondition(b.cond)
                v:transmitPartItem(part)
                v:transmitPartCondition(part)
                v:transmitPartWindow(part)
                b.itemId, glass = pane:getID(), true
                log[#log + 1] = id .. ":REINSTALL"
            end
        else
            -- 換件或其他原件不見了：不重建，改認目前的為基準
            b.cond, b.itemId, b.full = part:getCondition(), itemId, item and item:getFullType() or ""
        end
        local dur = part:getDurability()
        if dur > 0 and dur < P.BIG then
            b.dur = dur
            part:setDurability(P.BIG)
        end
    end
    if glass and not e.glass0 then
        local sq = v:getSquare()
        local g = sq and sq:getBrokenGlass()
        if g then sq:transmitRemoveItemFromSquare(g) end
    end
    if #log == 0 then return end
    local rec = O.state().recordsByOid[e.oid]
    O.audit("WARN", "GUARD_RESTORE", { actor = "SYSTEM", role = "GUARD", oid = e.oid, owner = rec and rec.ownerUser,
        reason = table.concat(log, " "), x = v:getX(), y = v:getY(), z = v:getZ() })
    local t = now()
    if rec and t - (R.repairNotified[e.oid] or 0) >= P.NOTICE_MS then
        R.repairNotified[e.oid] = t
        notify(rec.ownerUser, { key = "IGUI_MVM_Guard_Repaired", oid = e.oid, bad = false })
    end
end

-- ------------------------------------------------------------------ track ---
-- 有授權者在車上（車主或有該座位權限的人）就不布防；沒權限的乘客不算（佔座由 watchdog 處理）
local function occupied(v, rec)
    for seat = 0, v:getMaxPassengers() - 1 do
        local chr = v:getCharacter(seat)
        if chr and instanceof(chr, "IsoPlayer") then
            if O.principal(chr) == rec.ownerUser then return true end
            if O.allowsRecord(chr, rec, seat == 0 and "DRIVE" or "PASSENGER", { silent = true }) then return true end
        end
    end
    return false
end

local function drop(e)
    R.tracked[e.id] = nil
    if R.byOid[e.oid] == e then R.byOid[e.oid] = nil end
end

-- 回 true＝不再追蹤（呼叫端在走完 pairs 後移除）
local function check(e, t)
    local v = e.v
    if v:isRemovedFromWorld() or getVehicleById(e.id) ~= v then return true end -- 車不在了：durability 不存檔，不必寫回
    local rec = O.state().recordsByOid[e.oid]
    if rec == nil or not GUARDABLE[rec.recordState] or rec.removedAtMs then
        disarm(e)
        return true
    end
    local want = P.state(rec) == "ON" and v:getVehicleTowedBy() == nil and not occupied(v, rec)
    if want and e.base == nil then
        capture(e)
        e.nextRestore = t + P.RESTORE_MS
    elseif not want and e.base ~= nil then
        disarm(e)
    elseif e.base ~= nil and e.touched then
        capture(e)
    end
    e.touched = false
    if e.base ~= nil and t >= e.nextRestore then
        e.nextRestore = t + P.RESTORE_MS
        restore(e)
    end
    return false
end

-- 授權突變之後呼叫（ActionGuards、AutoDrive、指令防火牆）：O(1)，沒追蹤的車無事
function P.touch(vehicle)
    local e = vehicle and R.tracked[vehicle:getId()]
    if e and e.v == vehicle then e.touched = true end
end

-- 開始追蹤一台已綁定（AUTHORIZED）的車；是否布防由每秒檢查決定
function P.discover(v)
    if v == nil or O.state() == nil then return end
    local id = v:getId()
    local e = R.tracked[id]
    if e and e.v == v then return end
    if O.R.bySqlId[v:getSqlId()] == nil then return end
    local verdict, rec = O.lookup(v)
    if verdict ~= "AUTHORIZED" or not GUARDABLE[rec.recordState] then return end
    if e then drop(e) end -- 同一 id 換了車物件：舊物件已不在世界上
    local old = R.byOid[rec.oid]
    if old then
        if not old.v:isRemovedFromWorld() then disarm(old) end
        drop(old)
    end
    e = { v = v, id = id, oid = rec.oid, due = 0, nextRestore = 0 }
    R.tracked[id], R.byOid[rec.oid] = e, e
end

-- 指令防火牆拒絕砸窗時呼叫：回這台車目前是否布防中；通知車主（同一台車＋同一攻擊者 NOTICE_MS 一次；不在線也記進通知紀錄）
function P.onAttack(attacker, oid)
    local e = oid and R.byOid[oid]
    local guarded = e ~= nil and e.base ~= nil
    local st = O.state()
    local rec = oid and st and st.recordsByOid[oid]
    local who = O.principal(attacker) or tostring(attacker and attacker:getUsername())
    if rec and rec.ownerUser and rec.ownerUser ~= who then -- 車主自己被擋（太遠）不算被攻擊
        local key, t = oid .. "|" .. who, now()
        if t - (R.attackNotified[key] or 0) >= P.NOTICE_MS then
            R.attackNotified[key] = t
            notify(rec.ownerUser, { key = guarded and "IGUI_MVM_Attack_Guarded" or "IGUI_MVM_Attack_Unguarded", oid = oid,
                who = who, bad = true })
        end
    end
    return guarded
end

-- ------------------------------------------------------------------ tick ---
local function prune(map, t)
    local old = {}
    for k, at in pairs(map) do if t - at >= P.NOTICE_MS then old[#old + 1] = k end end
    for _, k in ipairs(old) do map[k] = nil end
end

-- IsoCell.getVehicles 是 Set，只能用 iterator（O.scanLoaded 同）
function P.scan(t)
    local it = getCell():getVehicles():iterator()
    while it:hasNext() do
        local v = it:next()
        local e = R.tracked[v:getId()]
        if not (e and e.v == v) then P.discover(v) end
    end
    prune(R.attackNotified, t)
    prune(R.repairNotified, t)
end

function P.tick()
    local t = now()
    if t - R.lastTick < P.TICK_MS or O.state() == nil then return end
    R.lastTick = t
    if t - R.lastScan >= P.SCAN_MS then
        R.lastScan = t
        P.scan(t)
    end
    R.memo = {}
    local n, gone = 0, {}
    for _, e in pairs(R.tracked) do
        if n >= P.PER_TICK then break end
        if e.due <= t then
            n = n + 1
            e.due = t + P.CHECK_MS
            local ok, res = pcall(check, e, t)
            if not ok and not R.errors[e.oid] then
                R.errors[e.oid] = true
                MVM.log("parked guard check failed (dropped) oid=" .. tostring(e.oid) .. ": " .. tostring(res))
            end
            if not ok or res then gone[#gone + 1] = e end
        end
    end
    R.memo = nil
    for _, e in ipairs(gone) do drop(e) end
end

Events.OnTick.Add(P.tick)
