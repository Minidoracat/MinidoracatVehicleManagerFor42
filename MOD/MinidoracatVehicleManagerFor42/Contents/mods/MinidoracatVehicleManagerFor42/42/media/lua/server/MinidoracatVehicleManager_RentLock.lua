-- 租用名額到期（Economy 選用整合）：租約進入寬限或到期後，車主的綁定數超過「不含寬限名額」的上限時，
-- 由新到舊鎖住超出的車（rec.lock＝"RENT"：O.allowsRecord 擋使用，車主管理照常），續租或解除綁定夠多台就由舊到新解鎖。
-- 租約從 Economy 移除後仍超額的鎖定車進保留期（rec.lockKeepUntilMs＝進保留當下＋沙盒 RentKeepDays 天）：
-- 照樣綁定、鎖定、受保護；重新租用或解除其他車就解鎖，期滿才釋出（RELEASED，endReason＝RENT_EXPIRED）。
-- 鎖定數只跟著超額走：租約被移除不讓鎖定變少（改進保留）；要多鎖，Economy 上得還列著寬限／到期的名額。
-- 只在 Economy READY 且查詢成功時動作，任何讀取錯誤都不改；Economy 沒裝（ABSENT）時清掉所有租約鎖定，免得永遠鎖著。
-- 觸發：綁定名額的權益變更（Economy.lua）、Server.lua 解除綁定／轉讓／管理員釋出後、每分鐘（有鎖定或觀察中的車主）、開服。
if isClient() then return end
require "MinidoracatVehicleManager_Economy"

local MVM = MinidoracatVehicleManager
local O, S, E = MVM.Own, MVM.Srv, MVM.Econ
-- watch＝還有寬限／到期／待確認租約的車主（RAM；重啟後由鎖定紀錄與 Economy 的變更通知補回）
-- lastMs＝上次全表重算的牆鐘時間（0＝開服後還沒算過，開服那次一定跑）
local RL = { watch = {}, lastMs = 0 }
MVM.RentLock = RL

-- 這位車主綁定名額的租約分項；Economy 不是 READY、查詢失敗或欄位不合回 nil（呼叫端什麼都不改）。
-- hold＝還有寬限、到期或待確認的租約（RL.watch 用）；unsettled＝有待確認（paused_system 可能是卡住的待確認續租），
-- 一併視為未定：不進保留、不釋出
local function rentals(owner)
    if E.status ~= "READY" then return nil end
    local ent = E.entitlement(owner, MVM.ECON_PRODUCT)
    if ent == nil or type(ent.rentals) ~= "table" then return nil end
    local r = { usable = ent.usable, grace = 0, expired = 0, hold = false, unsettled = false, untilMs = nil }
    for _, x in ipairs(ent.rentals) do
        if type(x) ~= "table" or not MVM.isInt(x.quantity) or x.quantity < 0 then return nil end
        if x.state == "grace" then
            r.grace = r.grace + x.quantity
            if type(x.graceUntil) == "number" and (r.untilMs == nil or x.graceUntil > r.untilMs) then r.untilMs = x.graceUntil end
        elseif x.state == "expired" then
            r.expired = r.expired + x.quantity
        elseif x.state == "pending" or x.state == "paused_system" then
            r.unsettled = true
        end
    end
    r.hold = r.unsettled or r.grace + r.expired > 0
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
    rec.lock, rec.lockAtMs, rec.lockUntilMs, rec.lockKeepUntilMs = "RENT", t, untilMs, nil
    audit("WARN", "RENT_LOCK", rec, reason)
    changed(rec)
end

local function unlock(rec, reason)
    rec.lock, rec.lockAtMs, rec.lockUntilMs, rec.lockKeepUntilMs = nil, nil, nil, nil
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

-- 走 S.notify：一律記進通知紀錄（車主不在線時寬限、解除也查得到），在線才即時送
local function notify(owner, key, n, atMs, bad)
    S.notify(owner, { key = key, n = n, atMs = atMs, bad = bad })
end

local DAY_MS = 86400000

-- 重算一位車主的租約鎖定。deficit＝已用 −（基本＋可用付費 − 寬限中）；
-- 鎖定數＝deficit 夾在 0 到 max(現有鎖定, 寬限＋到期＋保留中)：超額下降才解鎖，租約移除不解鎖
function RL.evaluate(owner)
    if type(owner) ~= "string" or O.R.status ~= "READY" then return end
    local r = rentals(owner)
    if r == nil then return end
    RL.watch[owner] = r.hold or nil
    local list, locked, kept = {}, 0, 0
    for _, rec in ipairs(O.R.byOwner[owner] or {}) do
        if O.countsForQuota(rec) then
            list[#list + 1] = rec
            if rec.lock then
                locked = locked + 1
                if rec.lockKeepUntilMs then kept = kept + 1 end
            end
        elseif rec.lock then
            unlock(rec, "ENDED") -- 已結束的紀錄（解除綁定、遺失、釋出）不留鎖
        end
    end
    list = newestFirst(list)
    local t = getTimestampMs()
    local open = r.grace + r.expired -- Economy 上還列著、撐不了綁定的租用名額
    local deficit = O.quotaUsed(owner) - (O.quotaBase(owner) + r.usable - r.grace)
    local want = math.max(0, math.min(deficit, math.max(locked, open + kept)))
    local why = "deficit=" .. deficit .. " want=" .. want
    local added, freed, keptNew, released = 0, 0, 0, 0
    for _, rec in ipairs(list) do
        if locked >= want then break end
        if not rec.lock then
            lock(rec, t, r.untilMs, why)
            locked, added = locked + 1, added + 1
        end
    end
    for i = #list, 1, -1 do
        if locked <= want then break end
        local rec = list[i]
        if rec.lock then
            if rec.lockKeepUntilMs then kept = kept - 1 end
            unlock(rec, why)
            locked, freed = locked - 1, freed + 1
        end
    end
    -- 還沒進保留的鎖定車：超出 Economy 上還列著的名額（租約已移除）由新到舊進保留，其餘同步寬限截止
    local over = r.unsettled and 0 or locked - kept - open
    local keepUntil, fresh = t + MVM.sandbox("RentKeepDays", 7) * DAY_MS, {}
    for _, rec in ipairs(list) do
        if rec.lock and not rec.lockKeepUntilMs then
            if over > 0 then
                over = over - 1
                rec.lockUntilMs, rec.lockKeepUntilMs = nil, keepUntil
                audit("WARN", "RENT_KEEP", rec, why)
                changed(rec)
                kept, keptNew, fresh[rec] = kept + 1, keptNew + 1, true
            elseif rec.lockUntilMs ~= r.untilMs then
                rec.lockUntilMs = r.untilMs -- 寬限截止改變（部分續租、只剩到期的租約）
                changed(rec)
            end
        end
    end
    -- 保留期滿才釋出。載著受保護車的拖車（CARRIER_HAS_CARGO）保持鎖定，同 O.maintain：被載的車先處理，下一輪再放拖車
    if not r.unsettled then
        for _, rec in ipairs(list) do
            if rec.lock and rec.lockKeepUntilMs and t >= rec.lockKeepUntilMs and not O.hasCargo(rec) then
                rec.lock, rec.lockAtMs, rec.lockUntilMs, rec.lockKeepUntilMs = nil, nil, nil, nil
                rec.endReason = "RENT_EXPIRED"
                O.setState(rec, "RELEASED", "RENT_EXPIRED", { actor = "SYSTEM", role = "RENT" })
                released = released + 1
                if fresh[rec] then keptNew = keptNew - 1 end -- RentKeepDays＝0：同一輪進保留又釋出，只通知釋出
            end
        end
    end
    -- 只在有寬限截止時間時通知鎖定。沒有寬限中的租約（寬限 0 小時、或寬限在停機時過完）時 Economy 同一次排程就會
    -- 先報到期、再移除租約，玩家只會看到幾毫秒後的保留通知；鎖定照樣寫在車隊視窗與使用時的提示（E2E rentlock 實測）
    if added > 0 and r.untilMs then notify(owner, "IGUI_MVM_Rent_Locked", locked - kept, r.untilMs, true) end
    if freed > 0 then notify(owner, "IGUI_MVM_Rent_Unlocked", freed, nil, false) end
    if keptNew > 0 then notify(owner, "IGUI_MVM_Rent_Kept", keptNew, keepUntil, true) end
    if released > 0 then notify(owner, "IGUI_MVM_Rent_Released", released, nil, true) end
end

-- 每分鐘（牆鐘節流）與開服：重算有鎖定或觀察中的車主。Economy 沒裝（ABSENT）＝不會再有租約資料，清掉所有租約鎖定。
-- EveryOneMinute 是遊戲分鐘（一天 1 小時的伺服器每 2.5 秒一次，全員睡覺快轉時約 31 ms），所以照真實時間最多 60 秒一次；
-- 權益變更、解除綁定、轉讓、管理員釋出都直接呼叫 RL.evaluate，節流只讓租約時間到期最多晚 1 分鐘處理。
-- 帳本 READY 前不記時間：開服時帳本還沒好，好了之後下一次觸發就算
-- ponytail: 每 60 秒全表掃一次找鎖定（O.maintain 也是）；紀錄量大到一次掃描有感時改成維護 owner→鎖定數 索引
function RL.minute()
    if O.R.status ~= "READY" then return end
    local t = getTimestampMs()
    if MVM.recent(t, RL.lastMs, 60000) then return end
    RL.lastMs = t
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

-- 排在 S.minute（O.maintain 做載入判定）之後；開服這輪排在 E.init 之後（本檔 require Economy）
Events.EveryOneMinute.Add(RL.minute)
if Events.OnServerStarted then Events.OnServerStarted.Add(RL.minute) end
