-- 租用綁定名額到期（Economy 選用整合）：租約進入寬限或到期後，車主的綁定數超過「不含寬限名額」的上限時，
-- 由新到舊鎖住超出的車（rec.lock＝"RENT"：O.allowsRecord 擋使用，車主管理照常），續租或解除綁定夠多台就由舊到新解鎖；
-- 寬限、到期、待確認的租約都沒有了仍超額，才把最新的鎖定車釋出（RELEASED，endReason＝RENT_EXPIRED），其餘解鎖。
-- 只在 Economy READY 且查詢成功時動作，任何讀取錯誤都不改；Economy 沒裝（ABSENT）時清掉所有租約鎖定，免得永遠鎖著。
-- 觸發：綁定名額的權益變更（Economy.lua）、Server.lua 解除綁定／轉讓／管理員釋出後、每分鐘（有鎖定或觀察中的車主）、開服。
if isClient() then return end
require "MinidoracatVehicleManager_Economy"

local MVM = MinidoracatVehicleManager
local O, S, E = MVM.Own, MVM.Srv, MVM.Econ
-- watch＝還有寬限／到期／待確認租約的車主（RAM；重啟後由鎖定紀錄與 Economy 的變更通知補回）
local RL = { watch = {} }
MVM.RentLock = RL

-- 這位車主綁定名額的租約分項；Economy 不是 READY、查詢失敗或欄位不合回 nil（呼叫端什麼都不改）。
-- hold＝還有寬限、到期或待確認的租約（paused_system 可能是卡住的待確認續租，一併視為未定，不據以釋出）
local function rentals(owner)
    if E.status ~= "READY" then return nil end
    local ent = E.entitlement(owner, MVM.ECON_PRODUCT)
    if ent == nil or type(ent.rentals) ~= "table" then return nil end
    local r = { usable = ent.usable, grace = 0, expired = 0, hold = false, untilMs = nil }
    for _, x in ipairs(ent.rentals) do
        if type(x) ~= "table" or not MVM.isInt(x.quantity) or x.quantity < 0 then return nil end
        if x.state == "grace" then
            r.grace = r.grace + x.quantity
            if type(x.graceUntil) == "number" and (r.untilMs == nil or x.graceUntil > r.untilMs) then r.untilMs = x.graceUntil end
        elseif x.state == "expired" then
            r.expired = r.expired + x.quantity
        elseif x.state == "pending" or x.state == "paused_system" then
            r.hold = true
        end
    end
    r.hold = r.hold or r.grace + r.expired > 0
    return r
end

-- 寬限中的綁定名額（快要結束，不能拿來綁新車；OwnershipSystem O.claimBlocked 扣掉）；任何錯誤＝0
function O.graceSlots(owner)
    local r = type(owner) == "string" and rentals(owner)
    return r and r.grace or 0
end

local function changed(rec)
    O.bump(rec)
    if O.onRecordChanged then O.onRecordChanged(rec) end
end

local function audit(severity, event, rec, reason)
    O.audit(severity, event, { actor = "SYSTEM", role = "RENT", oid = rec.oid, epoch = rec.epoch, owner = rec.ownerUser,
        reason = reason })
end

local function lock(rec, t, untilMs, reason)
    rec.lock, rec.lockAtMs, rec.lockUntilMs = "RENT", t, untilMs
    audit("WARN", "RENT_LOCK", rec, reason)
    changed(rec)
end

local function unlock(rec, reason)
    rec.lock, rec.lockAtMs, rec.lockUntilMs = nil, nil, nil
    audit("INFO", "RENT_UNLOCK", rec, reason)
    changed(rec)
end

-- 綁定時間由新到舊，同時間依 oid（MVM.sortByKey 是穩定排序：先排 oid 再排時間）
local function newestFirst(list)
    local keys = {}
    for _, rec in ipairs(list) do keys[rec] = rec.oid end
    list = MVM.sortByKey(list, keys)
    for _, rec in ipairs(list) do keys[rec] = -(rec.claimedAtMs or 0) end
    return MVM.sortByKey(list, keys)
end

local function notify(owner, key, n, atMs, bad)
    local player = S.online()[owner]
    if player then S.send(player, "notice", { key = key, n = n, atMs = atMs, bad = bad }) end
end

-- 重算一位車主的租約鎖定。deficit＝已用 −（基本＋可用付費 − 寬限中）；鎖定數＝deficit 夾在 0 到寬限＋到期名額之間
function RL.evaluate(owner)
    if type(owner) ~= "string" or O.R.status ~= "READY" then return end
    local r = rentals(owner)
    if r == nil then return end
    RL.watch[owner] = r.hold or nil
    local list, locked = {}, 0
    for _, rec in ipairs(O.R.byOwner[owner] or {}) do
        if O.countsForQuota(rec) then
            list[#list + 1] = rec
            if rec.lock then locked = locked + 1 end
        elseif rec.lock then
            unlock(rec, "ENDED") -- 已結束的紀錄（解除綁定、遺失、釋出）不留鎖
        end
    end
    list = newestFirst(list)
    local deficit = O.quotaUsed(owner) - (O.quotaBase(owner) + r.usable - r.grace)
    local added, freed, released = 0, 0, 0
    if r.hold then
        local want = math.max(0, math.min(deficit, r.grace + r.expired))
        local why = "deficit=" .. deficit .. " want=" .. want
        for _, rec in ipairs(list) do
            if locked >= want then break end
            if not rec.lock then
                lock(rec, getTimestampMs(), r.untilMs, why)
                locked, added = locked + 1, added + 1
            end
        end
        for i = #list, 1, -1 do
            if locked <= want then break end
            if list[i].lock then
                unlock(list[i], why)
                locked, freed = locked - 1, freed + 1
            end
        end
        -- 寬限截止改變（部分續租、只剩到期的租約）：既有鎖定同步
        for _, rec in ipairs(list) do
            if rec.lock and rec.lockUntilMs ~= r.untilMs then
                rec.lockUntilMs = r.untilMs
                changed(rec)
            end
        end
    elseif locked > 0 then
        -- 租約都結束了：仍超額就由新到舊釋出鎖定車，其餘解鎖。載著受保護車的拖車（CARRIER_HAS_CARGO）保持鎖定，
        -- 同 O.maintain：被載的車先處理，下一輪再放拖車
        local n = math.max(0, math.min(locked, deficit))
        for _, rec in ipairs(list) do
            if rec.lock then
                if n > 0 then
                    n = n - 1
                    if not O.hasCargo(rec) then
                        rec.lock, rec.lockAtMs, rec.lockUntilMs = nil, nil, nil
                        rec.endReason = "RENT_EXPIRED"
                        O.setState(rec, "RELEASED", "RENT_EXPIRED", { actor = "SYSTEM", role = "RENT" })
                        released = released + 1
                    end
                else
                    unlock(rec, "RENT_ENDED deficit=" .. deficit)
                    freed = freed + 1
                end
            end
        end
    end
    -- 只在有寬限截止時間時通知鎖定。沒有寬限中的租約（寬限 0 小時、或寬限在停機時過完）時 Economy 同一次排程就會
    -- 先報到期、再移除租約，玩家只會看到幾毫秒後的「已解除綁定」；鎖定照樣寫在車隊視窗與使用時的提示（E2E rentlock 實測）
    if added > 0 and r.untilMs then notify(owner, "IGUI_MVM_Rent_Locked", locked, r.untilMs, true) end
    if freed > 0 then notify(owner, "IGUI_MVM_Rent_Unlocked", freed, nil, false) end
    if released > 0 then notify(owner, "IGUI_MVM_Rent_Released", released, nil, true) end
end

-- 每分鐘與開服：重算有鎖定或觀察中的車主。Economy 沒裝（ABSENT）＝不會再有租約資料，清掉所有租約鎖定。
-- ponytail: 每分鐘全表掃一次找鎖定（O.maintain 也是）；紀錄量大到有感時改成維護 owner→鎖定數 索引
function RL.minute()
    if O.R.status ~= "READY" then return end
    local st = O.state()
    if E.status == "ABSENT" then
        for _, rec in pairs(st.recordsByOid) do
            if rec.lock then unlock(rec, "ECONOMY_ABSENT") end
        end
        return
    end
    if E.status ~= "READY" then return end
    local owners = {}
    for owner in pairs(RL.watch) do owners[owner] = true end
    for _, rec in pairs(st.recordsByOid) do
        if rec.lock and rec.ownerUser then owners[rec.ownerUser] = true end
    end
    for owner in pairs(owners) do RL.evaluate(owner) end
end

-- 排在 S.minute（O.maintain 做載入判定）之後；開服這輪排在 E.init 之後（本檔 require Economy）。帳本還沒 READY 就等下一分鐘
Events.EveryOneMinute.Add(RL.minute)
if Events.OnServerStarted then Events.OnServerStarted.Add(RL.minute) end
