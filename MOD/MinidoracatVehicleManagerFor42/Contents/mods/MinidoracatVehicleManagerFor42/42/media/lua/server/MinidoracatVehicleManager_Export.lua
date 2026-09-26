-- 伺服器 Lua 目錄下的兩個檔（Zomboid/Lua/MinidoracatVehicleManager/<伺服器名>/）：
-- 1. vehicles.json：給人看的綁定清單。帳本版本號有變才重寫、最多每 10 秒一次；單向輸出，改它不會回寫帳本。
-- 2. positions.txt：車輛位置日誌。帳本只在世界存檔時落盤，但引擎在上下車、車上斷線、區塊卸載時就把車的座標
--    commit 進 vehicles.db（BaseVehicle.java:2481-2483,2540-2542、VehiclesDB2.java:854-870）。這裡在同樣的時機
--    追加一行，伺服器崩潰重啟時讀一次、把比帳本新的座標補回帳本，讓地圖與車隊清單指向車真正會出現的位置。
--    平常只寫不讀；啟動時壓縮成每台車一行。
-- ponytail: 管理員手動還原舊備份時，日誌裡的座標會比還原後的 vehicles.db 新：車被載入時會自動校正；
--    要立即一致就在還原時一併刪掉 positions.txt（README 有寫）。
if isClient() then return end
require "MinidoracatVehicleManager_OwnershipSystem"
require "MinidoracatVehicleManager_Migration"

local MVM = MinidoracatVehicleManager
local O = MVM.Own
local X = { exportedRevision = nil, lastExportMs = 0, journalApplied = false }
MVM.Export = X

local EXPORT_MS = 10000

local function now() return getTimestampMs() end

-- 一個世界一個資料夾：dedicated 用伺服器名，單人用存檔名
function X.folder()
    local name = isServer() and getServerName() or ("sp_" .. tostring(getWorld():getWorld()))
    name = tostring(name or ""):gsub("[^%w%-_]", "_")
    if name == "" or name == "sp_" then name = "default" end
    return "MinidoracatVehicleManager/" .. name .. "/"
end

-- ------------------------------------------------------------------ JSON ---
local ARRAY = {}
local function arr(t) ARRAY[t] = true; return t end

local ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local HEX = "0123456789abcdef"
local function ctrl(c)
    if ESC[c] then return ESC[c] end
    local b = c:byte()
    local hi, lo = math.floor(b / 16), b - math.floor(b / 16) * 16
    return "\\u00" .. HEX:sub(hi + 1, hi + 1) .. HEX:sub(lo + 1, lo + 1)
end
local function str(s)
    return '"' .. (tostring(s):gsub('[%c"\\]', ctrl)) .. '"'
end

local function encode(v, indent, out)
    local tv = type(v)
    if tv == "table" then
        local pad, inner = "\n" .. indent, "\n" .. indent .. "  "
        if ARRAY[v] then
            if #v == 0 then out[#out + 1] = "[]"; return end
            out[#out + 1] = "["
            for i = 1, #v do
                out[#out + 1] = (i > 1 and "," or "") .. inner
                encode(v[i], indent .. "  ", out)
            end
            out[#out + 1] = pad .. "]"
        else
            -- 物件：欄位依呼叫端給的 __order 輸出（可讀、穩定）
            local order = v.__order
            out[#out + 1] = "{"
            local first = true
            for _, k in ipairs(order or {}) do
                if v[k] ~= nil then
                    out[#out + 1] = (first and "" or ",") .. inner .. str(k) .. ": "
                    encode(v[k], indent .. "  ", out)
                    first = false
                end
            end
            out[#out + 1] = (first and "" or pad) .. "}"
        end
    elseif tv == "string" then
        out[#out + 1] = str(v)
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null"
        elseif v == math.floor(v) and math.abs(v) < 1e15 then out[#out + 1] = MVM.Migration.intStr(v)
        else out[#out + 1] = tostring(v) end
    elseif tv == "boolean" then
        out[#out + 1] = v and "true" or "false"
    else
        out[#out + 1] = "null"
    end
end

function X.json(v)
    local out = {}
    encode(v, "", out)
    return table.concat(out, "", 1, #out)
end

local function obj(order, t) t.__order = order; return t end

-- ms → "YYYY-MM-DD HH:MM:SS UTC"（Kahlua 沒有 os.date；公式見 Howard Hinnant civil_from_days）
function X.utc(ms)
    if type(ms) ~= "number" then return nil end
    local sec = math.floor(ms / 1000)
    local days = math.floor(sec / 86400)
    local rem = sec - days * 86400
    local z = days + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    local y = yoe + era * 400 + (m <= 2 and 1 or 0)
    local function p2(n) return (n < 10 and "0" or "") .. MVM.Migration.intStr(n) end
    local hh, mm = math.floor(rem / 3600), math.floor(rem / 60) - math.floor(rem / 3600) * 60
    return MVM.Migration.intStr(y) .. "-" .. p2(m) .. "-" .. p2(d) .. " " .. p2(hh) .. ":" .. p2(mm) .. ":" .. p2(rem - math.floor(rem / 60) * 60) .. " UTC"
end

-- ---------------------------------------------------------------- export ---
local VEHICLE_FIELDS = { "owner", "name", "model", "state", "claimedAt", "lastKnown", "sharedWith", "faction", "oid", "sqlId" }

local function actionsOf(bits)
    local out = arr({})
    for _, a in ipairs(MVM.ACTION_ORDER) do
        if a ~= "MANAGE" and MVM.hasBit(bits or 0, MVM.ACTIONS[a]) then out[#out + 1] = a end
    end
    return out
end

function X.document()
    local st = O.state()
    local vehicles, keys = {}, {}
    for oid, rec in pairs(st.recordsByOid) do
        local shared = arr({})
        for _, g in ipairs(rec.grants or {}) do
            shared[#shared + 1] = obj({ "user", "actions" }, { user = g.user, actions = actionsOf(g.bits) })
        end
        local row = obj(VEHICLE_FIELDS, {
            owner = rec.ownerUser, name = rec.customName ~= "" and rec.customName or nil,
            model = tostring(rec.vehicleScript or "?"):gsub("^.-%.", ""), state = rec.recordState,
            claimedAt = X.utc(rec.claimedAtMs), sharedWith = shared, oid = oid, sqlId = rec.sqlIdHint,
            lastKnown = rec.lastKnownX and obj({ "x", "y", "z", "at" }, { x = math.floor(rec.lastKnownX), y = math.floor(rec.lastKnownY),
                z = math.floor(rec.lastKnownZ or 0), at = X.utc(rec.lastKnownAtMs) }) or nil,
            faction = rec.factionShare and obj({ "name", "state", "actions" }, { name = rec.factionName, state = rec.factionState,
                actions = actionsOf(rec.factionActionBits) }) or nil,
        })
        vehicles[#vehicles + 1] = row
        keys[row] = tostring(rec.ownerUser) .. "\t" .. tostring(row.name or row.model) .. "\t" .. oid
    end
    vehicles = MVM.sortByKey(vehicles, keys)
    local pending, pkeys = {}, {}
    for id, e in pairs(st.pendingRebindByLegacyKey) do
        local row = obj({ "owner", "model", "lastX", "lastY", "legacyId" }, { owner = e.ownerUser,
            model = tostring(e.vehicleScript or "?"):gsub("^.-%.", ""), lastX = e.lastX, lastY = e.lastY,
            legacyId = MVM.Migration.intStr(id) })
        pending[#pending + 1] = row
        pkeys[row] = tostring(e.ownerUser) .. "\t" .. row.legacyId
    end
    pending = MVM.sortByKey(pending, pkeys)
    return obj({ "note", "generatedAt", "server", "ledgerId", "ledgerRevision", "count", "vehicles", "waitingForMVCKVehicle" }, {
        note = "Read-only export of the Minidoracat Vehicle Manager ledger. Editing this file changes nothing.",
        generatedAt = X.utc(now()), server = isServer() and getServerName() or nil, ledgerId = st.ledgerId,
        ledgerRevision = st.ledgerRevision, count = #vehicles, vehicles = arr(vehicles), waitingForMVCKVehicle = arr(pending) })
end

function X.writeExport()
    local w = getFileWriter(X.folder() .. "vehicles.json", true, false)
    if w == nil then return false end
    w:write(X.json(X.document()) .. "\n")
    w:close()
    return true
end

-- ------------------------------------------------------------ positions ---
local function journalPath() return X.folder() .. "positions.txt" end

local function num(n) return tostring(math.floor(n * 100 + 0.5) / 100) end

-- observeVehicle 寫入新的最後位置時呼叫（O.onPositionSaved）
function X.notePosition(rec)
    if rec.lastKnownX == nil then return end
    local path = journalPath()
    local probe = getFileReader(path, false)
    local fresh = probe == nil
    if probe then probe:close() end
    local w = getFileWriter(path, true, true)
    if w == nil then return end
    if fresh then w:write("ledger\t" .. tostring(O.state().ledgerId) .. "\n") end
    w:write(rec.oid .. "\t" .. num(rec.lastKnownX) .. "\t" .. num(rec.lastKnownY) .. "\t" .. num(rec.lastKnownZ or 0) .. "\t"
        .. MVM.Migration.intStr(rec.lastKnownAtMs or now()) .. "\n")
    w:close()
end

-- 啟動後帳本 READY 時做一次：日誌裡比帳本新的座標補回，之後把日誌壓成每台車一行
function X.applyJournal()
    local st = O.state()
    local latest = {}
    local r = getFileReader(journalPath(), false)
    if r ~= nil then
        local header = r:readLine()
        if header == "ledger\t" .. tostring(st.ledgerId) then
            while true do
                local line = r:readLine()
                if line == nil then break end
                local oid, x, y, z, t = line:match("^([%w%-]+)\t([%d%.%-]+)\t([%d%.%-]+)\t([%d%.%-]+)\t(%d+)$")
                t = tonumber(t)
                if oid and t and (latest[oid] == nil or t >= latest[oid].t) then
                    latest[oid] = { x = tonumber(x), y = tonumber(y), z = tonumber(z), t = t }
                end
            end
        end
        r:close()
    end
    local applied = 0
    for oid, p in pairs(latest) do
        local rec = st.recordsByOid[oid]
        if rec and O.AUTHORIZABLE[rec.recordState] and p.t > (rec.lastKnownAtMs or 0) then
            rec.lastKnownX, rec.lastKnownY, rec.lastKnownZ, rec.lastKnownAtMs = p.x, p.y, p.z, p.t
            O.bump(rec)
            applied = applied + 1
        end
    end
    local w = getFileWriter(journalPath(), true, false)
    if w ~= nil then
        w:write("ledger\t" .. tostring(st.ledgerId) .. "\n")
        for oid, rec in pairs(st.recordsByOid) do
            if rec.lastKnownX and O.AUTHORIZABLE[rec.recordState] then
                w:write(oid .. "\t" .. num(rec.lastKnownX) .. "\t" .. num(rec.lastKnownY) .. "\t" .. num(rec.lastKnownZ or 0) .. "\t"
                    .. MVM.Migration.intStr(rec.lastKnownAtMs or 0) .. "\n")
            end
        end
        w:close()
    end
    if applied > 0 then
        MVM.log("restored " .. applied .. " newer vehicle positions from positions.txt (server did not save before stopping)")
        O.audit("WARN", "POSITIONS_RESTORED", { count = applied })
    end
    return applied
end

O.onPositionSaved = X.notePosition

function X.tick()
    local st = O.state()
    if st == nil or not O.ready() then return end -- ready() 會觸發載入判定；RECOVERY_REQUIRED 時不改帳本也不匯出
    if not X.journalApplied then
        X.journalApplied = true
        X.applyJournal()
    end
    local t = now()
    if t - X.lastExportMs < EXPORT_MS or X.exportedRevision == st.ledgerRevision then return end
    X.lastExportMs = t
    if X.writeExport() then X.exportedRevision = st.ledgerRevision end
end

Events.OnTick.Add(X.tick)
