-- 車主通知紀錄（2026-10-06 使用者：不在線時收不到的通知要有地方看）。S.notify 每則都記一筆，在線就照常即時送；
-- 快照帶整份紀錄與已讀時間，車隊視窗「紀錄」分頁顯示，看過送 noticesRead。
-- 存伺服器本機檔案，不放帳本也不放 GMD：帳本分片的容量模型假設小項目 ≤150 B（verify_mod「帳本分片容量」），
-- 而 GMD 不適合放私人資料（GlobalModData.java:171-205）——攻擊者帳號與車名是車主的私人紀錄。
-- 每位車主一個檔 <Export.folder>notices/<帳號逐字 4 位 hex>.txt（帳號可能有檔名不能用的字，Windows 檔名又不分大小寫）：
-- 第一行 read<TAB>已讀到的 ms<TAB>下一個編號，之後每行一則（舊到新）：
-- id t key oid who n at bad live c name script（字串欄位 % 編碼 % TAB CR LF）。
-- 保留最近 MVM.NOTICE_MAX 則、MVM.NOTICE_KEEP_DAYS 天內；同一台車、同一則訊息、同一攻擊者在 N.MERGE_MS 內再發生就併成一則（c 次）。
-- ponytail: 檔案只在寫入與該車主第一次被問到時讀，不掃資料夾；之後不再上線的車主的檔留在磁碟（每個最多數 KB）
if isClient() then return end
require "MinidoracatVehicleManager_API"
require "MinidoracatVehicleManager_Export"

local MVM = MinidoracatVehicleManager
local O = MVM.Own
local N = { cache = {} }
MVM.Notices = N
N.MAX = MVM.NOTICE_MAX
N.KEEP_MS = MVM.NOTICE_KEEP_DAYS * 86400000
N.MERGE_MS = 600000

local function now() return getTimestampMs() end
local function num(n) return MVM.Migration.intStr(n) end

-- 帳號 → 檔名：每個字（UTF-16 單位，最大 65535）寫成 4 位小寫 hex，不同帳號一定不同檔名
local HEX = "0123456789abcdef"
function N.fileName(who)
    local out = {}
    for i = 1, #who do
        local b = who:byte(i)
        for _, d in ipairs({ math.floor(b / 4096), math.floor(b / 256) % 16, math.floor(b / 16) % 16, b % 16 }) do
            out[#out + 1] = HEX:sub(d + 1, d + 1)
        end
    end
    return table.concat(out, "", 1, #out)
end

function N.path(who) return MVM.Export.folder() .. "notices/" .. N.fileName(who) .. ".txt" end

local function esc(v)
    if v == nil then return "" end
    return (tostring(v):gsub("[%%\t\r\n]", function(c)
        if c == "%" then return "%25" elseif c == "\t" then return "%09" elseif c == "\r" then return "%0D" end
        return "%0A"
    end))
end

local UNESC = { ["25"] = "%", ["09"] = "\t", ["0D"] = "\r", ["0A"] = "\n" }
local function unesc(s)
    if s == nil or s == "" then return nil end
    return (s:gsub("%%(%x%x)", function(h) return UNESC[h:upper()] or ("%" .. h) end))
end

local function split(line)
    local out, from = {}, 1
    while true do
        local i = line:find("\t", from, true)
        if i == nil then out[#out + 1] = line:sub(from); return out end
        out[#out + 1] = line:sub(from, i - 1)
        from = i + 1
    end
end

local function int(s)
    local v = tonumber(s)
    return MVM.isInt(v) and v or nil
end

-- 讀一位車主的紀錄（第一次問到時讀檔，之後用 RAM）
local function load(who)
    local c = N.cache[who]
    if c then return c end
    c = { read = 0, next = 1, list = {} }
    local r = getFileReader(N.path(who), false)
    if r then
        local head = r:readLine()
        local f = head and split(head)
        if f and f[1] == "read" then c.read, c.next = int(f[2]) or 0, int(f[3]) or 1 end
        local line = r:readLine()
        while line ~= nil do
            local x = split(line)
            local id, t, key = int(x[1]), int(x[2]), x[3]
            if id and t and type(key) == "string" and key:match("^IGUI_MVM_[%w_]+$") then
                c.list[#c.list + 1] = { id = id, t = t, key = key, oid = unesc(x[4]), who = unesc(x[5]), n = int(x[6]),
                    at = int(x[7]), bad = x[8] == "1", live = x[9] == "1", c = int(x[10]) or 1, name = unesc(x[11]),
                    script = unesc(x[12]) }
                if id >= c.next then c.next = id + 1 end
            end
            line = r:readLine()
        end
        r:close()
    end
    N.cache[who] = c
    return c
end

-- 只留最近 N.MAX 則、N.KEEP_MS 內的
local function prune(c, t)
    local keep = {}
    for i = math.max(1, #c.list - N.MAX + 1), #c.list do
        local e = c.list[i]
        if t - e.t <= N.KEEP_MS then keep[#keep + 1] = e end
    end
    c.list = keep
end

local function save(who, c)
    local w = getFileWriter(N.path(who), true, false)
    if w == nil then return false end
    local out = { "read\t" .. num(c.read) .. "\t" .. num(c.next) }
    for _, e in ipairs(c.list) do
        local f = { num(e.id), num(e.t), e.key, esc(e.oid), esc(e.who), e.n and num(e.n) or "", e.at and num(e.at) or "",
            e.bad and "1" or "0", e.live and "1" or "0", num(e.c or 1), esc(e.name), esc(e.script) }
        out[#out + 1] = table.concat(f, "\t", 1, #f)
    end
    w:write(table.concat(out, "\n", 1, #out) .. "\n")
    w:close()
    return true
end

-- 記一則通知（payload：{ key, oid?, who?, n?, atMs?, bad }；live＝車主此刻在線、會即時看到）。
-- 車名與車型記在紀錄裡：車之後解除綁定或換名，紀錄照樣寫得出當時是哪台車。回傳這則
function N.add(owner, payload, live)
    local t = now()
    local c = load(owner)
    local last = c.list[#c.list]
    local e
    if last and payload.oid and last.key == payload.key and last.oid == payload.oid and last.who == payload.who
        and t - last.t <= N.MERGE_MS then
        e = last
        e.t, e.c, e.live = t, (e.c or 1) + 1, e.live and live
    else
        local st = O.state()
        local rec = payload.oid and st and st.recordsByOid[payload.oid] or nil
        e = { id = c.next, t = t, key = payload.key, oid = payload.oid, who = payload.who, n = payload.n, at = payload.atMs,
            bad = payload.bad == true, live = live == true, c = 1,
            name = rec and rec.customName ~= "" and rec.customName or nil, script = rec and rec.vehicleScript or nil }
        c.next = c.next + 1
        c.list[#c.list + 1] = e
    end
    prune(c, t)
    save(owner, c)
    return e
end

-- 快照用：紀錄（舊到新）與已讀到的時間
function N.list(owner)
    local c = load(owner)
    prune(c, now())
    return c.list, c.read
end

-- 車主看過紀錄：已讀到 upTo（不超過現在、不倒退）
function N.markRead(owner, upTo)
    local c = load(owner)
    local t = math.min(upTo, now())
    if t <= c.read then return end
    c.read = t
    save(owner, c)
end
