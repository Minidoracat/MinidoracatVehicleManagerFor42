-- MVCK clean-room 遷移（計畫 Phase 5）：只讀 MVCK 存下的資料形狀，不含其程式碼。
-- 管理員一鍵匯入（adminMigration op=IMPORT）：MVCKByVehicleSQLID 的白名單欄位（owner、車型、綁定時間、最後位置）
--   匯入 pendingRebindByLegacyKey；已載入的車當場轉正，其餘等車被載入時轉正。
--   可重複執行：已匯入過的舊 ID 不重複匯入（MVCK 還在時新綁的車，再按一次就補進來）。
--   **不刪 MVCK 的資料**：伺服器之後自行從 Mods= 移除 MVCK 即可；兩個 MOD 並存期間兩邊的保護都會生效。
-- 轉正（車身 SQLID 命中待轉項 E，且車型相同）：
--   規則 1：SQLID 內嵌的綁定當時 sqlId 等於此車 server 端 sqlId。
--   規則 2（換號，稽核 REBOUND_MOVED）：內嵌 sqlId 不同。正式服的 rSemiTruck 多槽拖車（MSW）裝車時刪車、卸車時
--     addVehicleDebug 生新車並還原整份 modData：車身 SQLID 與車型保留，sqlId 換新。必須同時：
--     (a) 此車 sqlId 不是另一筆同車型待轉項的內嵌 sqlId（那筆的原車很可能就是這台，留給規則 1）；
--     (b) 已載入的車裡沒有同車型、正好位在 E 內嵌 sqlId 的車（有的話那台才是原車，這台是偽造的）。
--   車身 modData 可被 client 覆寫（Phase 0 trust-mp），server sqlId 不行。規則 2 的取捨：原車沒載入時，
--   改過的 client 可以把 E 的 SQLID 寫到一台沒被占住的同車型車上搶先轉正。
if isClient() then return end
require "MinidoracatVehicleManager_OwnershipSystem"
require "MinidoracatVehicleManager_Server"

local MVM = MinidoracatVehicleManager
local O, S = MVM.Own, MVM.Srv
local M = { mismatched = {}, lastMaintMs = 0 }
MVM.Migration = M

local LEGACY_VEHICLES = "MVCKByVehicleSQLID"
local DAY_MS = 86400000

function M.available()
    return ModData.exists(LEGACY_VEHICLES)
end

local function now() return getTimestampMs() end

-- 大整數轉十進位字串（不依賴格式化函式；舊 ID 約 1e11–1e15，仍在 double 精確範圍內）。
-- 不能用 %：Kahlua 的模除以 (int)(a/b) 算商（KahluaThread.java:1060-1066），商超過 int 就溢位成垃圾（E2E phase5-mp 實踩）
function M.intStr(n)
    n = math.floor(n)
    if n == 0 then return "0" end
    local neg, out = n < 0, {}
    if neg then n = -n end
    while n > 0 do
        local q = math.floor(n / 10)
        out[#out + 1] = tostring(math.floor(n - q * 10))
        n = q
    end
    local s = ""
    for i = #out, 1, -1 do s = s .. out[i] end
    return neg and ("-" .. s) or s
end

-- MVCK 的舊 ID＝tonumber(秒級時間戳 .. 綁定當時 sqlId)。時間戳固定 10 位，拆法唯一；sqlId 不會有前導 0
function M.embedded(legacyId)
    if not MVM.isInt(legacyId) or legacyId < 1e10 then return nil end
    local tail = M.intStr(legacyId):sub(11)
    if #tail > 1 and tail:sub(1, 1) == "0" then return nil end
    return tonumber(tail)
end

function M.embeddedSqlId(legacyId, sqlId)
    return MVM.isInt(sqlId) and sqlId >= 0 and M.embedded(legacyId) == sqlId
end

local function validOwner(v) return type(v) == "string" and #v >= 1 and #v <= 50 and not v:find("%c") end

-- 一鍵匯入全部；回傳 ok, 結果表（imported 新匯入、already 先前已匯入、skipped 欄位不合格、rebound 當場轉正、pending 等待載入）
function M.importAll(actor)
    local st = O.state()
    if st == nil or not O.ready() then return false, "NOT_READY" end
    if not ModData.exists(LEGACY_VEHICLES) then return false, "NO_SOURCE" end
    local src = ModData.get(LEGACY_VEHICLES)
    local pend, done = st.pendingRebindByLegacyKey, st.migratedLegacyIds
    local out = { imported = 0, already = 0, skipped = 0, rebound = 0, pending = 0 }
    local t = now()
    for id, e in pairs(src) do
        if done[id] then
            out.already = out.already + 1
        elseif MVM.isInt(id) and type(e) == "table" and validOwner(e.OwnerPlayerID) and type(e.CarModel) == "string" then
            O.mapSet("pendingRebindByLegacyKey", id, { legacyVehicleId = id, ownerUser = e.OwnerPlayerID, vehicleScript = e.CarModel,
                claimedAtMs = MVM.isInt(e.ClaimDateTime) and e.ClaimDateTime * 1000 or t,
                lastX = tonumber(e.LastLocationX), lastY = tonumber(e.LastLocationY), importedAtMs = t })
            O.mapSet("migratedLegacyIds", id, true)
            if st.ownerActivity[e.OwnerPlayerID] == nil then
                O.mapSet("ownerActivity", e.OwnerPlayerID, { lastSuccessfulLoginAtMs = t, releaseWarnedAtMs = 0 })
            end
            O.reserveUnbound(e.OwnerPlayerID) -- 身分已匯入但這個名字沒綁定：帳號已刪或是分割畫面名，別讓同名新帳號接收
            out.imported = out.imported + 1
        else
            out.skipped = out.skipped + 1
        end
    end
    if out.imported > 0 then O.bump(nil) end
    -- 已載入的車當場查一次（lookup 對無紀錄的車會呼叫 rebindHook）
    local cell = getCell()
    local it = cell and cell:getVehicles():iterator()
    while it and it:hasNext() do
        local v = it:next()
        local legacy = v:hasModData() and rawget(v:getModData(), "SQLID") or nil
        if legacy ~= nil and pend[legacy] ~= nil then
            O.lookup(v)
            if pend[legacy] == nil then out.rebound = out.rebound + 1 end
        end
    end
    for _ in pairs(pend) do out.pending = out.pending + 1 end
    st.migrationManifest = { lastImportAtMs = t, lastImported = out.imported, runs = ((st.migrationManifest or {}).runs or 0) + 1 }
    O.audit("WARN", "MIGRATE", { actor = actor, role = "ADMIN", count = out.imported, reason = "IMPORT imported=" .. out.imported
        .. " already=" .. out.already .. " skipped=" .. out.skipped .. " rebound=" .. out.rebound .. " pending=" .. out.pending })
    MVM.log("MVCK import: " .. out.imported .. " new, " .. out.rebound .. " bound now, " .. out.pending
        .. " waiting for their car to load. MVCK data is left untouched.")
    return true, out
end

-- 規則 2 的 (a)(b)：回 nil＝可以轉正，否則回拒絕原因。只在換號時才掃待轉項 O(P) 與已載入的車
local function movedRefusal(legacy, e, vehicle)
    local sqlId = vehicle:getSqlId()
    for id, other in pairs(O.state().pendingRebindByLegacyKey) do
        if id ~= legacy and other.vehicleScript == e.vehicleScript and M.embeddedSqlId(id, sqlId) then return "REBIND_MOVED_TAKEN" end
    end
    local original = M.embedded(legacy)
    local it = getCell():getVehicles():iterator()
    while it:hasNext() do
        local v = it:next()
        if v ~= vehicle and v:getSqlId() == original and v:getScriptName() == e.vehicleScript and not v:isRemovedFromWorld() then
            return "REBIND_MOVED_ORIGINAL_LOADED"
        end
    end
    return nil
end

-- lookup 對「無紀錄」的車呼叫：命中待轉項且車型相同，再依規則 1／2 轉正
function M.rebind(vehicle)
    local st = O.state()
    local pend = st and st.pendingRebindByLegacyKey
    if pend == nil or not vehicle:hasModData() then return nil end
    local legacy = rawget(vehicle:getModData(), "SQLID")
    if type(legacy) ~= "number" then return nil end
    local e = pend[legacy]
    if e == nil then return nil end
    local sqlId = vehicle:getSqlId()
    local reason, refused = "REBOUND", nil
    if vehicle:getScriptName() ~= e.vehicleScript then
        refused = "REBIND_MISMATCH"
    elseif not M.embeddedSqlId(legacy, sqlId) then
        reason, refused = "REBOUND_MOVED", movedRefusal(legacy, e, vehicle)
    end
    if refused then
        local key = tostring(legacy) .. "/" .. tostring(sqlId)
        if not M.mismatched[key] then
            M.mismatched[key] = true
            O.audit("WARN", "MIGRATE", { owner = e.ownerUser, vehicle = sqlId, reason = refused })
        end
        return nil
    end
    local host = O.hostPart(vehicle, nil)
    if host == nil then return nil end
    O.mapSet("pendingRebindByLegacyKey", legacy, nil)
    local rec = O.createRecord(e.ownerUser, vehicle, host)
    rec.claimedAtMs = e.claimedAtMs
    O.audit("INFO", "MIGRATE", { oid = rec.oid, epoch = rec.epoch, owner = rec.ownerUser, vehicle = rec.sqlIdHint, reason = reason })
    S.push({ [rec.ownerUser] = true }, { oid = M.rowId(legacy) }, true) -- 撤掉待轉列
    S.push(S.audience(rec), rec, false)
    return rec
end

function M.rowId(legacy) return "legacy-" .. M.intStr(legacy) end

-- 待轉項也算入 quota 與全服上限（計畫 §4.5）
function M.pendingCount(owner)
    local st = O.state()
    local n = 0
    for _, e in pairs(st and st.pendingRebindByLegacyKey or {}) do
        if owner == nil or e.ownerUser == owner then n = n + 1 end
    end
    return n
end

-- 待轉列（只讀，沒有可用操作）：車主快照只給自己的；who＝nil 給管理員總表全部
function M.pendingRows(who)
    local rows = {}
    local st = O.state()
    for id, e in pairs(st and st.pendingRebindByLegacyKey or {}) do
        if who == nil or e.ownerUser == who then
            rows[#rows + 1] = { oid = M.rowId(id), role = "OWNER", owner = e.ownerUser, state = "PENDING_REBIND", name = "",
                script = e.vehicleScript, lastKnownX = e.lastX, lastKnownY = e.lastY, lastKnownAtMs = e.importedAtMs, grants = {} }
        end
    end
    return rows
end

-- 逾期未對上車的待轉項刪除並寫入報告（audit）
function M.expire(force)
    local t = now()
    if not force and t - M.lastMaintMs < 60000 then return end
    M.lastMaintMs = t
    local st = O.state()
    if st == nil or not O.ready() then return end
    local limit = MVM.sandbox("RebindDeadlineDays", 30) * DAY_MS
    local drop = {}
    for id, e in pairs(st.pendingRebindByLegacyKey) do
        if t - (e.importedAtMs or t) > limit then drop[#drop + 1] = id end
    end
    for _, id in ipairs(drop) do
        local e = st.pendingRebindByLegacyKey[id]
        O.mapSet("pendingRebindByLegacyKey", id, nil)
        O.audit("WARN", "MIGRATE", { owner = e.ownerUser, reason = "REBIND_EXPIRED legacy=" .. M.intStr(id)
            .. " script=" .. tostring(e.vehicleScript) .. " last=" .. tostring(e.lastX) .. "," .. tostring(e.lastY) })
        S.push({ [e.ownerUser] = true }, { oid = M.rowId(id) }, true)
    end
    if #drop > 0 then O.bump(nil) end
end

O.rebindHook = M.rebind
O.pendingCount = M.pendingCount
S.extraRows = M.pendingRows

Events.EveryOneMinute.Add(function() M.expire(false) end)
