-- 付費名額方案（Economy 選用整合）。方案歸 VM：唯一來源是伺服器 Lua 目錄的
-- MinidoracatVehicleManager/<伺服器名>/paid-slots.json，Economy 只存目前生效的一份（setPlan）。
-- 1. Economy READY 後每 POLL_MS 讀一次；文字跟上次處理過的相同就跳過，不同就解析 → setPlan(origin=file) → 狀態檔 → setPlanSource。
--    not_ready 不記為已處理（下輪再試）；其他錯誤記為已處理（同一份壞內容不每 5 秒重報）。
-- 2. 檔案不存在：用 Economy 目前生效的方案寫一份（新伺服器＝E.DEFAULTS，兩種販售都關閉）。
--    存在但讀不到：狀態 unreadable，方案不動、不覆寫。
-- 3. 管理員在遊戲內套用（adminPaidSlots SET）前先處理一次檔案（外部剛改的內容不被蓋掉），成功後寫回這份檔，
--    寫入的文字記為已處理；寫不進去時回 fileError，方案已在 Economy 生效，但重啟後會用檔案的舊值。
-- 4. paid-slots.status.json：每次處理後整份覆寫；外部程式或 AI 改檔後讀它就知道結果。
-- Economy 不在或不支援：開機寫一次 economy_unavailable，不建也不讀設定檔。數值範圍由 Economy 驗證，這裡只驗 JSON 形狀與型別。
if isClient() then return end
require "MinidoracatVehicleManager_Economy"
require "MinidoracatVehicleManager_Export"

local MVM = MinidoracatVehicleManager
local O, E, X = MVM.Own, MVM.Econ, MVM.Export
local PS = { lastText = nil, lastPollMs = 0, status = nil }
MVM.PaidSlots = PS
PS.POLL_MS = 5000

-- 檔案鍵（群組.鍵）→ Economy 方案欄位；kind 是 JSON 型別
local FIELDS = {
    { "buy", "enabled", "permanentEnabled", "bool" }, { "buy", "price", "permanentPrice", "int" },
    { "buy", "currency", "permanentCurrency", "id" }, { "buy", "limit", "permanentLimit", "int" },
    { "rent", "enabled", "rentalEnabled", "bool" }, { "rent", "price", "rentalPrice", "int" },
    { "rent", "currency", "rentalCurrency", "id" }, { "rent", "limit", "rentalLimit", "int" },
    { "rent", "days", "rentalDays", "int" }, { "rent", "graceHours", "graceHours", "int" },
    { "rent", "reminderHours", "reminderHours", "int" }, { "rent", "autoRenew", "autoRenewAllowed", "bool" },
}
local FILE_KEY, ORDER, BY_PLAN, KNOWN = {}, { buy = {}, rent = {} }, {}, {}
for _, f in ipairs(FIELDS) do
    FILE_KEY[f[3]] = f[1] .. "." .. f[2]
    KNOWN[f[1] .. "." .. f[2]] = true
    ORDER[f[1]][#ORDER[f[1]] + 1] = f[2]
    BY_PLAN[f[3]] = f
end

local function typeOk(kind, v)
    if kind == "bool" then return type(v) == "boolean" end
    if kind == "int" then return MVM.isInt(v) end
    return type(v) == "string" and #v >= 1 and #v <= 16 and v:match("^[%w_]+$") ~= nil
end

-- adminPaidSlots 的 values：剛好 12 個方案欄位、型別正確（範圍交給 Economy）
function PS.validPlan(v)
    if type(v) ~= "table" then return false end
    local n = 0
    for k, x in pairs(v) do
        local f = BY_PLAN[k]
        if f == nil or not typeOk(f[4], x) then return false end
        n = n + 1
    end
    return n == #FIELDS
end

-- ------------------------------------------------------------------ JSON ---
-- 最小 JSON 解析（物件、字串、數字、true／false／null；設定檔用不到陣列，遇到就當壞 JSON）。失敗丟錯。
-- null 解成 NULL（不是 nil），鍵才不會消失：多出來的鍵不論值都要報錯。X.json 也把 NULL 寫成 null
local NULL = function() end
local UNESC = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
local function decode(s)
    -- 有些編輯器（Windows PowerShell 5.1 的 Set-Content -Encoding UTF8）會寫 BOM；Java 讀成 U+FEFF，Kahlua 字串是 UTF-16
    if s:byte(1) == 65279 then s = s:sub(2) end
    local pos = 1
    local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
    local function str()
        local out = {}
        pos = pos + 1
        while true do
            local c = s:sub(pos, pos)
            if c == "" or c:byte() < 32 then error("bad string") end
            if c == '"' then pos = pos + 1; return table.concat(out) end
            if c == "\\" then
                local e = s:sub(pos + 1, pos + 1)
                if e == "u" then
                    local hex = s:sub(pos + 2, pos + 5)
                    if hex:match("^%x%x%x%x$") == nil then error("bad escape") end
                    local n = tonumber(hex, 16)
                    -- Python json.dumps 預設把非 ASCII 寫成 \uXXXX：Kahlua 的 string.char 收 UTF-16 碼元（StringLib），離線 Lua 用 utf8.char
                    out[#out + 1] = (n >= 128 and utf8 and utf8.char) and utf8.char(n) or string.char(n)
                    pos = pos + 6
                elseif UNESC[e] then
                    out[#out + 1] = UNESC[e]
                    pos = pos + 2
                else error("bad escape") end
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
    end
    local value
    value = function()
        ws()
        local c = s:sub(pos, pos)
        if c == "{" then
            local t = {}
            pos = pos + 1
            ws()
            if s:sub(pos, pos) == "}" then pos = pos + 1; return t end
            while true do
                ws()
                if s:sub(pos, pos) ~= '"' then error("bad key") end
                local k = str()
                ws()
                if s:sub(pos, pos) ~= ":" then error("missing colon") end
                pos = pos + 1
                t[k] = value()
                ws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "}" then return t end
                if d ~= "," then error("missing comma") end
            end
        elseif c == '"' then return str()
        elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
        elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return NULL
        end
        -- JSON 數字文法：-?(0|[1-9]\d*)(\.\d+)?([eE][-+]?\d+)?，之後要是 token 邊界（tonumber 也吃 0250、250.）
        local rest = s:sub(pos)
        local num = rest:match("^-?%d+")
        if num == nil or num:match("^-?0%d") then error("bad number") end
        num = num .. (rest:sub(#num + 1):match("^%.%d+") or "")
        num = num .. (rest:sub(#num + 1):match("^[eE][-+]?%d+") or "")
        local after = rest:sub(#num + 1, #num + 1)
        if after ~= "" and after:match("^[ \t\r\n,}]") == nil then error("bad number") end
        pos = pos + #num
        return tonumber(num)
    end
    local v = value()
    ws()
    if pos <= #s then error("trailing data") end
    return v
end

-- 設定檔文字 → values, reason；錯誤回 nil, 錯誤碼, 檔案鍵名
function PS.parse(text)
    local ok, doc = pcall(decode, text)
    if not ok or type(doc) ~= "table" then return nil, "invalid_json" end
    local values = {}
    for _, f in ipairs(FIELDS) do
        local group = doc[f[1]]
        if group == nil then return nil, "missing_field", f[1] end
        if type(group) ~= "table" then return nil, "invalid_type", f[1] end
        local v = group[f[2]]
        if v == nil then return nil, "missing_field", FILE_KEY[f[3]] end
        if not typeOk(f[4], v) then return nil, "invalid_type", FILE_KEY[f[3]] end
        values[f[3]] = v
    end
    local reason = doc.reason
    if reason == NULL then reason = nil end
    if reason ~= nil and type(reason) ~= "string" then return nil, "invalid_type", "reason" end
    for k, v in pairs(doc) do
        if ORDER[k] == nil and k ~= "reason" then return nil, "unknown_field", tostring(k):sub(1, 64) end
        if ORDER[k] then
            for k2 in pairs(v) do
                local key = k .. "." .. tostring(k2)
                if not KNOWN[key] then return nil, "unknown_field", key:sub(1, 64) end
            end
        end
    end
    return values, reason
end

function PS.encode(values, reason)
    local doc = { __order = { "buy", "rent", "reason" }, buy = { __order = ORDER.buy }, rent = { __order = ORDER.rent },
        reason = reason }
    for _, f in ipairs(FIELDS) do doc[f[1]][f[2]] = values[f[3]] end
    return X.json(doc)
end

-- ----------------------------------------------------------------- files ---
function PS.path() return X.folder() .. "paid-slots.json" end
function PS.displayPath() return "Zomboid/Lua/" .. PS.path() end

-- readLine 去掉行尾（含 \r）：比對用的文字一律以 \n 接回、不含最後換行。
-- 回 text，或 nil 與 "missing"／"unreadable"：getFileReader 把開檔的 IOException 吞掉回 nil（LuaManager.java:5949-5960），
-- 要用同一個 Lua 目錄根的 cacheFileExists（:5541-5549）分辨，讀不到的檔不能當成不存在而覆寫
local function readText(path)
    local ok, r = pcall(getFileReader, path, false)
    if not ok or r == nil then
        local checked, exists = pcall(cacheFileExists, path)
        if checked and not exists then return nil, "missing" end
        return nil, "unreadable"
    end
    local lines = {}
    while true do
        local line = r:readLine()
        if line == nil then break end
        lines[#lines + 1] = line
    end
    r:close()
    return table.concat(lines, "\n")
end

-- getFileWriter 底下的 PrintWriter 吞 I/O 錯誤：close 後讀回比對才算寫成功
local function writeText(path, text)
    local ok = pcall(function()
        local w = getFileWriter(path, true, false)
        if w == nil then error("no writer") end
        w:write(text .. "\n")
        w:close()
    end)
    return ok and readText(path) == text
end

local STATUS_ORDER = { "state", "source", "revision", "error", "field", "at", "economy" }

-- 寫狀態檔並告訴 Economy 設定檔有沒有錯（唯讀總覽顯示）
local function report(st)
    st.at, st.economy = X.utc(getTimestampMs()), E.status
    PS.status = st
    local doc = { __order = STATUS_ORDER }
    for _, k in ipairs(STATUS_ORDER) do doc[k] = st[k] == nil and NULL or st[k] end
    if not writeText(X.folder() .. "paid-slots.status.json", X.json(doc)) then MVM.log("paid-slots.status.json write failed") end
    if E.src then
        local problem = st.error and (st.error .. (st.field and (" " .. st.field) or "")) or nil
        pcall(E.src.setPlanSource, MVM.ECON_PRODUCT, { file = PS.displayPath(), problem = problem })
    end
end

local function call(name, ...)
    local ok, res = pcall(E.src[name], ...)
    if not ok or type(res) ~= "table" then return { ok = false, error = ok and "invalid_response" or "exception" } end
    return res
end

local function planOf(p)
    local out = {}
    for _, f in ipairs(FIELDS) do out[f[3]] = p[f[3]] end
    return out
end

-- 檔案不存在：寫一份目前生效的方案。provisional（舊方案欄位不合）不記為已處理，下輪讀回後經 setPlan 取代
function PS.create()
    local res = call("getPlan", MVM.ECON_PRODUCT)
    if res.ok ~= true or type(res.plan) ~= "table" then return end
    local text = PS.encode(res.plan)
    if not writeText(PS.path(), text) then
        if PS.status == nil or PS.status.error ~= "write_failed" then
            report({ state = "error", source = "created", error = "write_failed" })
        end
        return
    end
    if not res.plan.provisional then PS.lastText = text end
    report({ state = "ok", source = "created", revision = res.plan.revision })
end

function PS.poll()
    if E.status ~= "READY" or E.src == nil then return end
    local text, why = readText(PS.path())
    if why == "missing" then return PS.create() end
    if text == nil then
        -- 存在但讀不到：方案不動、不覆寫；恢復可讀時重新處理（同一份內容也要清掉錯誤）
        PS.lastText = nil
        if PS.status == nil or PS.status.error ~= "unreadable" then
            report({ state = "error", source = "file", error = "unreadable" })
        end
        return
    end
    if text == PS.lastText then return end
    local values, reason, field = PS.parse(text)
    local st
    if values == nil then
        st = { state = "error", source = "file", error = reason, field = field }
    else
        local res = call("setPlan", MVM.ECON_PRODUCT, values, { actor = "file", origin = "file", reason = reason })
        if res.error == "not_ready" then return end
        if res.ok == true then
            st = { state = "ok", source = "file", revision = res.revision }
        else
            st = { state = "error", source = "file", error = tostring(res.error), field = FILE_KEY[res.field] or res.field }
        end
    end
    PS.lastText = text
    report(st)
end

function PS.tick()
    if E.status ~= "READY" then return end
    local t = getTimestampMs()
    if t - PS.lastPollMs < PS.POLL_MS then return end
    PS.lastPollMs = t
    PS.poll()
end

-- 排在 E.init 之後（本檔 require Economy，它先註冊 OnServerStarted）
function PS.start()
    PS.lastText, PS.lastPollMs, PS.status = nil, 0, nil
    if E.status ~= "READY" and E.status ~= "OFF" then report({ state = "economy_unavailable", source = "file" }) end
end

-- ----------------------------------------------------------------- admin ---
local function fail(reason, field) return { ok = false, reason = reason, field = field } end

-- Server.lua 的 H.adminPaidSlots 已驗過管理員與 SCHEMA
function PS.admin(who, a)
    local ready = E.status == "READY" and E.src ~= nil
    if a.op == "GET" then
        if not ready then return { ok = true, economy = E.status } end
        local res = call("getPlan", MVM.ECON_PRODUCT)
        if res.ok ~= true or type(res.plan) ~= "table" then return fail("ECONOMY_UNAVAILABLE") end
        local lc = res.lastChange
        return { ok = true, economy = E.status, plan = planOf(res.plan), revision = res.plan.revision,
            provisional = res.plan.provisional, currencies = E.currencies, file = PS.displayPath(), status = PS.status,
            lastChange = type(lc) == "table" and { actor = lc.actor, origin = lc.origin, at = lc.at, reason = lc.reason } or nil }
    end
    if a.values == nil or a.expectedRevision == nil then return fail("BAD_ARGS") end
    local reason = type(a.reason) == "string" and a.reason:match("^%s*(.-)%s*$") or ""
    if #reason < 1 or #reason > 256 then return fail("NEED_REASON") end
    if not ready then return fail("ECONOMY_UNAVAILABLE") end
    -- 先處理還沒輪詢到的外部修改：合法就讓 revision 前進（管理員的舊版本變成 STALE_REVISION），不合法照常記錯
    PS.poll()
    local values = planOf(a.values)
    local res = call("setPlan", MVM.ECON_PRODUCT, values,
        { actor = who, origin = "admin", reason = reason, expectedRevision = a.expectedRevision })
    if res.ok ~= true then
        if res.error == "stale_revision" then return fail("STALE_REVISION") end
        if res.error == "invalid_plan" or res.error == "unknown_fields" then
            return fail("INVALID_PLAN", FILE_KEY[res.field] or res.field)
        end
        return fail("ECONOMY_UNAVAILABLE")
    end
    local changed = type(res.changed) == "table" and res.changed or {}
    local text = PS.encode(values, reason)
    local fileError
    if writeText(PS.path(), text) then PS.lastText = text else fileError = "write_failed" end
    report({ state = fileError and "error" or "ok", source = "admin", revision = res.revision, error = fileError })
    O.audit("WARN", "ADMIN_PAID_SLOTS", { actor = who, role = "ADMIN", reason = table.concat(changed, ",") .. " " .. reason,
        count = #changed })
    return { ok = true, revision = res.revision, changed = changed, fileError = fileError }
end

if Events.OnServerStarted then Events.OnServerStarted.Add(PS.start) end
-- PauseEmpty 空服暫停時 OnTick 不跑，但 Economy 的自動續租排程照常收費：讀檔要跟它一樣用 OnTickEvenPaused（LuaEventManager.java:594）
Events.OnTickEvenPaused.Add(PS.tick)
