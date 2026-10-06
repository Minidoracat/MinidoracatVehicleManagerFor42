-- 車隊視窗（計畫 Phase 3、docs/VEHICLE_MANAGER_UI_DESIGN.md）：Owned／Shared／Admin 三頁、本機搜尋、
-- 詳情與操作。畫面只顯示 server 投影；所有變更送命令後等 ACK／delta，不做樂觀更新。
-- 外觀全部用 MinidoracatUIFor42 的現代元件（API rev 7：Window／Tabs／TextField／Button／Checkbox／Dialog、
-- VirtualList、FloatButton）。原生只剩元件內部的輸入框與 ISLayoutManager 的位置保存。
require "MinidoracatVehicleManager_API"
require "MinidoracatVehicleManager_Client"
require "MinidoracatVehicleManager_Appearance"

local MVM = MinidoracatVehicleManager
local C = MVM.Client
local F = {}
MVM.FleetUI = F

local SHAREABLE = { "PASSENGER", "DRIVE", "CARGO", "FUEL", "REPAIR", "SALVAGE", "TOW", "TRACK" }
F.SHAREABLE = SHAREABLE

-- ------------------------------------------------------------ 純邏輯（harness 可測） ---
function F.bitsToList(bits)
    local out = {}
    for _, a in ipairs(SHAREABLE) do if MVM.hasBit(bits or 0, MVM.ACTIONS[a]) then out[#out + 1] = a end end
    return out
end

-- 權限清單的顯示文字：短名稱＋語系分隔字（不顯示 PASSENGER 之類的原始代碼）
function F.actionsText(bits)
    local names = F.bitsToList(bits)
    for i, a in ipairs(names) do names[i] = getText("IGUI_MVM_ActionShort_" .. a) end
    return table.concat(names, getText("IGUI_MVM_ListSep"), 1, #names)
end

function F.listToBits(list)
    local bits = 0
    for _, a in ipairs(list) do bits = bits + MVM.ACTIONS[a] end
    return bits
end

-- 公開給所有人只能給 MVM.PUBLIC_MASK 內的動作（伺服器同樣驗）；其餘勾選的不帶
function F.publicBits(bits)
    local out = 0
    for _, a in ipairs(SHAREABLE) do
        local bit = MVM.ACTIONS[a]
        if MVM.hasBit(bits or 0, bit) and MVM.hasBit(MVM.PUBLIC_MASK, bit) then out = out + bit end
    end
    return out
end

-- 原始車名：原版車名鍵（去掉模組前綴）；沒有譯名就顯示 script 名
function F.modelName(row)
    local short = tostring(row.script or "?"):gsub("^.-%.", "")
    local key = "IGUI_VehicleName" .. short
    local t = getText(key)
    if t == key then return short end
    return t
end

function F.displayName(row)
    if row.name and row.name ~= "" then return row.name end
    return F.modelName(row)
end

-- 改過名才需要另外顯示原始車名
function F.renamed(row) return row.name ~= nil and row.name ~= "" end

-- 歷史紀錄：已解除／遺失／燒毀，只剩稽核用途
function F.isHistory(row) return row.state == "RELEASED" or row.state == "ORPHANED" or row.state == "DESTROYED" end

-- 會畫在地圖上的列：自己的車、或分享給我且有查看位置權限；歷史紀錄與待轉不畫
function F.onMap(row)
    if F.isHistory(row) or row.state == "PENDING_REBIND" then return false end
    return row.role == "OWNER" or MVM.bitsAllow(row.myBits or 0, "TRACK")
end

-- 狀態只照 server 的 recordState；釋放倒數以 server 給的到期時間換算。
-- removedAtMs：車暫時不在世界上（拖車裝走或被移除），紀錄仍受保護；待釋放與隔離照原狀態顯示。
-- 租用名額到期鎖住的（lock）在清單與詳情都寫「已鎖定」；寬限期結束被解除的（endReason＝RENT_EXPIRED）寫出原因
function F.stateText(row, now)
    local s = row.state
    if s == "PENDING_RELEASE" then
        local hours = math.max(0, math.ceil(((row.releaseDueAtMs or now) - now) / 3600000))
        return getText("IGUI_MVM_State_PENDING_RELEASE", hours)
    end
    if row.removedAtMs and (s == "ACTIVE" or s == "WITNESS_STALE") then return getText("IGUI_MVM_State_OUT_OF_WORLD") end
    if row.lock and (s == "ACTIVE" or s == "WITNESS_STALE") then return getText("IGUI_MVM_State_LOCKED") end
    if s == "RELEASED" and row.endReason == "RENT_EXPIRED" then return getText("IGUI_MVM_State_RELEASED_RENT_EXPIRED") end
    return getText("IGUI_MVM_State_" .. tostring(s))
end

-- 狀態字色：要玩家處理的用強調色、隔離與租用鎖定用錯誤色；暫時不在世界上是正常的受保護狀態，不用警示色
local STATE_TOKEN = { ACTIVE = "text", WITNESS_STALE = "accent", PENDING_RELEASE = "accent", PENDING_REBIND = "accent",
    QUARANTINED = "errorText" }
function F.stateToken(row)
    if row.removedAtMs and (row.state == "ACTIVE" or row.state == "WITNESS_STALE") then return "textMuted" end
    if row.lock and (row.state == "ACTIVE" or row.state == "WITNESS_STALE") then return "errorText" end
    return STATE_TOKEN[row.state] or "textFaint"
end

-- 多久以前：1 分鐘內「剛剛」、1 小時內幾分鐘、2 天內幾小時，再久用天
local MINUTE_MS, HOUR_MS, DAY_MS = 60000, 3600000, 86400000
function F.agoText(atMs, now)
    local d = math.max(0, now - atMs)
    if d < MINUTE_MS then return getText("IGUI_MVM_Ago_Now") end
    if d < HOUR_MS then return getText("IGUI_MVM_Ago_Minutes", math.floor(d / MINUTE_MS)) end
    if d < 2 * DAY_MS then return getText("IGUI_MVM_Ago_Hours", math.floor(d / HOUR_MS)) end
    return getText("IGUI_MVM_Ago_Days", math.floor(d / DAY_MS))
end

-- 位置：v1 只有 server 低頻收斂的最後已知點；沒有就明說未知，不畫假座標。MVCK 待轉列的座標是匯入時的，不寫時間
function F.locationText(row, now)
    if row.lastKnownX == nil or row.lastKnownY == nil then return getText("IGUI_MVM_Location_Unknown") end
    local x, y = math.floor(row.lastKnownX), math.floor(row.lastKnownY)
    if row.state == "PENDING_REBIND" then return getText("IGUI_MVM_Location_Imported", x, y) end
    if row.lastKnownAtMs == nil or row.lastKnownAtMs <= 0 then return getText("IGUI_MVM_Location_Unknown") end
    return getText("IGUI_MVM_Location_LastKnown", x, y, F.agoText(row.lastKnownAtMs, now))
end

-- 詳情卡上的座標點一下複製：x,y,z（同 MiniMap 的「複製座標」，原版 /teleportto 吃得下）；卡片沒寫座標時回 nil
function F.coordsText(row)
    if row == nil or row.lastKnownX == nil or row.lastKnownY == nil then return nil end
    if row.state ~= "PENDING_REBIND" and (row.lastKnownAtMs == nil or row.lastKnownAtMs <= 0) then return nil end
    return math.floor(row.lastKnownX) .. "," .. math.floor(row.lastKnownY) .. "," .. math.floor(row.lastKnownZ or 0)
end

local function two(n) return (n < 10 and "0" or "") .. n end

-- 閒置釋放的保留期限：伺服器每分鐘刷新在線玩家的最後在線，所以看得到視窗的人期限就是「現在＋天數」。
-- 日期排列跟著語系（IGUI_MVM_Date：%1 年、%2 月、%3 日，月日補零；本機時區，MVM.localTime）；天數 0＝關閉回 nil
function F.keptText(days, now)
    if type(days) ~= "number" or days <= 0 then return nil end
    local y, m, d = MVM.localTime(now + days * DAY_MS)
    return getText("IGUI_MVM_KeptUntil", getText("IGUI_MVM_Date", y, two(m), two(d)))
end

-- 被分享者看到的來源（車主的分享清單在詳情下方逐列列出，不再寫摘要）
function F.shareText(row)
    local key = row.role == "FACTION" and "IGUI_MVM_Share_ViaFaction" or "IGUI_MVM_Share_ViaMember"
    return getText(key, tostring(row.owner or "?"))
end

-- 停車保全（伺服器 MVM.Parked.state 給的列 guard：ON／OVER／nil）。車主：ALL 模式受保全的車一句；SLOTS 模式
-- 每台可保全的車寫開／暫停（名額不夠）／關，附保全名額已用／總數（g＝快照的 guard）；OFF 不寫。被分享的車只有 ON 才寫
local GUARDABLE = { ACTIVE = true, WITNESS_STALE = true, PENDING_RELEASE = true }
function F.guardText(row, g)
    local mode = g and g.mode or MVM.guardMode()
    if row.role ~= "OWNER" or mode ~= MVM.GUARD.SLOTS then
        return row.guard == "ON" and getText("IGUI_MVM_Guard_All") or nil
    end
    if not GUARDABLE[row.state] then return nil end
    local key = row.guard == "ON" and "IGUI_MVM_Guard_On" or row.guard == "OVER" and "IGUI_MVM_Guard_Over" or "IGUI_MVM_Guard_Off"
    return getText(key, g and g.used or 0, g and g.total or 0), row.guard == "OVER" and "accent" or nil
end

-- 租用名額到期鎖住（寬限期到 lockUntilMs；nil＝寬限期已過、即將解除）
function F.lockText(row)
    if row.lock == nil then return nil end
    if row.lockUntilMs then return getText("IGUI_MVM_Lock_Rent", MVM.dateTimeText(row.lockUntilMs)) end
    return getText("IGUI_MVM_Lock_RentEnded")
end

-- 陣營分享暫停列（FPAUSE＝我的車、FPAUSED_SHARED＝分享給我）的標題與副標，清單與詳情共用
function F.pausedTitle(row)
    if row.kind == "FPAUSED_SHARED" then return getText("IGUI_MVM_FactionPaused_SharedTitle", row.name) end
    return getText(row.changed and "IGUI_MVM_FactionPaused_Title" or "IGUI_MVM_FactionPaused_TitleOther", row.name)
end

function F.pausedSub(row)
    if row.kind == "FPAUSED_SHARED" then return getText("IGUI_MVM_FactionPaused_SharedCount", row.n) end
    return getText("IGUI_MVM_FactionPaused_Count", #row.rows)
end

-- 詳情卡的行（第一行是大字標題）。layoutDetail 算好存在 self.card，draw 只畫；b＝自己的資料桶
function F.cardLines(row, tab, b, query, now)
    local lines = {}
    local function add(s, token, big) lines[#lines + 1] = { text = s, token = token or "textMuted", big = big } end
    if b == nil or b.streamId == nil then
        add(getText("IGUI_MVM_Loading"))
    elseif row == nil then
        if query ~= "" then add(getText("IGUI_MVM_NoMatch", query))
        elseif tab == "ADMIN" then add(getText("IGUI_MVM_Admin_Empty"))
        elseif tab == "SHARED" then add(getText("IGUI_MVM_EmptyShared"), "text")
        elseif tab == "LOG" then
            add(getText("IGUI_MVM_Notice_Empty", MVM.NOTICE_KEEP_DAYS, MVM.NOTICE_MAX), "text")
            lines[#lines].wrap = true
        else add(getText("IGUI_MVM_Empty"), "text"); add(getText("IGUI_MVM_EmptyHint")) end
    elseif row.kind == "NOTICE" then -- 通知紀錄：時間＋全文（layoutDetail 依詳情寬度換行）
        add(MVM.dateTimeText(row.e.t or now), "text", true)
        add(row.text, "text")
        lines[#lines].wrap = true
    elseif row.kind == "FPAUSE" or row.kind == "FPAUSED_SHARED" then -- 陣營分享暫停：發生什麼、幾台、怎麼恢復
        add(F.pausedTitle(row), "text", true)
        add(F.pausedSub(row), "accent")
        if row.kind == "FPAUSE" then add(getText("IGUI_MVM_FactionPaused_Leader", tostring(row.leader)), "text") end
        add(getText(row.kind == "FPAUSE" and "IGUI_MVM_FactionPaused_Explain" or "IGUI_MVM_FactionPaused_SharedExplain"))
        lines[#lines].wrap = true
    elseif row.kind == "PLAYER" then
        add(row.user == "" and getText("IGUI_MVM_Admin_NoOwner") or row.user, "text", true)
        local info = row.info
        if info then
            add(getText("IGUI_MVM_Quota", info.used, info.limit), "text")
            local base = getText(info.custom and "IGUI_MVM_Admin_BaseCustom" or "IGUI_MVM_Admin_BaseDefault", info.base)
            if info.limit > info.base then base = base .. getText("IGUI_MVM_Sep") .. getText("IGUI_MVM_Admin_Paid", info.limit - info.base) end
            add(base)
            -- 保全名額：伺服器只在 SLOTS 模式填這幾個欄位
            if info.guardBase ~= nil then
                add(getText("IGUI_MVM_Admin_GuardUsed", info.guardUsed or 0, info.guardLimit or info.guardBase), "text")
                local guard = getText(info.guardCustom and "IGUI_MVM_Admin_GuardCustom" or "IGUI_MVM_Admin_GuardDefault", info.guardBase)
                if (info.guardPaid or 0) > 0 then
                    guard = guard .. getText("IGUI_MVM_Sep") .. getText("IGUI_MVM_Admin_GuardPaid", info.guardPaid)
                end
                add(guard)
            end
            if info.lastSeenAtMs then add(getText("IGUI_MVM_Admin_LastSeen", F.agoText(info.lastSeenAtMs, now))) end
        end
    else
        add(F.displayName(row), "text", true)
        if F.renamed(row) then add(getText("IGUI_MVM_ModelName", F.modelName(row))) end
        local state = F.stateText(row, now)
        local kept = tab ~= "ADMIN" and row.role == "OWNER" and not row.lock and (row.state == "ACTIVE" or row.state == "WITNESS_STALE")
            and F.keptText(b.releaseDays, now)
        add(kept and (state .. getText("IGUI_MVM_Sep") .. kept) or state, F.stateToken(row))
        local lock = F.lockText(row)
        if lock then
            add(lock, "errorText")
            if tab ~= "ADMIN" and row.role == "OWNER" then add(getText("IGUI_MVM_Lock_RentHint")) end
        end
        if tab ~= "ADMIN" then
            local guard, token = F.guardText(row, b.guard)
            if guard then add(guard, token) end
        end
        add(F.locationText(row, now))
        lines[#lines].copy = F.coordsText(row)
        if tab == "ADMIN" then
            add(getText("IGUI_MVM_AdminOwner", row.owner or getText("IGUI_MVM_Admin_NoOwner")))
        elseif row.role == "MEMBER" or row.role == "FACTION" then
            add(F.shareText(row))
            add(getText("IGUI_MVM_YourActions", F.actionsText(row.myBits)))
        end
    end
    return lines
end

-- 分頁過濾＋搜尋（大小寫不敏感、純字串比對，中文照原字比）；依名稱排序
function F.filter(rows, tab, query)
    local out, keys = {}, {}
    local q = query and query:lower() or ""
    for _, row in pairs(rows or {}) do
        local inTab = (tab == "OWNED" and row.role == "OWNER") or (tab == "SHARED" and row.role ~= "OWNER") or tab == "ADMIN"
        if inTab then
            local name = F.displayName(row):lower()
            local hay = name .. " " .. F.modelName(row):lower() .. " " .. tostring(row.owner or ""):lower() .. " "
                .. tostring(row.script or ""):lower()
            if q == "" or hay:find(q, 1, true) then
                out[#out + 1] = row
                keys[row] = name
            end
        end
    end
    return MVM.sortByKey(out, keys)
end

-- 玩家的車輛狀態摘要（只列非零）：受保護、等待解除、待轉入、隔離、歷史紀錄
function F.playerSummary(g)
    local c, parts = g.counts, {}
    local function add(n, key) if n > 0 then parts[#parts + 1] = getText(key, n) end end
    add((c.ACTIVE or 0) + (c.WITNESS_STALE or 0), "IGUI_MVM_Admin_Protected")
    add(c.PENDING_RELEASE or 0, "IGUI_MVM_Admin_Releasing")
    add(c.PENDING_REBIND or 0, "IGUI_MVM_Admin_Rebind")
    add(c.QUARANTINED or 0, "IGUI_MVM_Admin_Quarantined")
    add(c.HISTORY or 0, "IGUI_MVM_Admin_History")
    if #parts == 0 then return getText("IGUI_MVM_Admin_NoVehicles") end
    return table.concat(parts, getText("IGUI_MVM_Sep"), 1, #parts)
end

-- 「紀錄」分頁：通知新到舊（伺服器給舊到新），搜尋比對通知文字。readAt＝打開分頁當時的已讀時間：
-- 看的這段期間，離線時收到的通知照樣標成未讀（伺服器已讀時間在打開分頁時就往前推）
function F.noticeItems(b, query, readAt)
    local out, list = {}, b and b.notices or {}
    local q = query and query:lower() or ""
    for i = #list, 1, -1 do
        local e = list[i]
        local s = MVM.noticeText(b, e)
        if q == "" or s:lower():find(q, 1, true) then
            out[#out + 1] = { kind = "NOTICE", oid = "notice:" .. tostring(e.id), e = e, text = s,
                unread = not e.live and (e.t or 0) > (readAt or 0) }
        end
    end
    return out
end

-- 「我的車」最上面的陣營分享暫停列：陣營分享暫停中的自己的車，依陣營名分組（kind＝FPAUSE，選它就在詳情恢復）。
-- info(陣營名)＝客戶端看到的陣營 { leader＝現在的領袖, mine＝自己在這個陣營 }；陣營不在或自己已不在就沒辦法一鍵恢復，
-- 不列（車輛詳情照舊顯示「（已暫停）」，可停止陣營分享或分享給新陣營）。changed＝有車綁的領袖不是現在的領袖（換了領袖）
function F.pausedGroups(rows, info)
    local groups, list, keys = {}, {}, {}
    for _, row in pairs(rows or {}) do
        if row.role == "OWNER" and row.factionShare and row.factionState == "SUSPENDED" and type(row.factionName) == "string"
            and (row.factionActionBits or 0) > 0 and not F.isHistory(row) and row.state ~= "QUARANTINED" then
            local g = groups[row.factionName]
            if g == nil then
                local fi = info(row.factionName)
                g = false
                if fi and fi.mine then
                    g = { kind = "FPAUSE", oid = "fpause:" .. row.factionName, name = row.factionName, leader = fi.leader,
                        rows = {}, changed = false }
                    list[#list + 1] = g
                    keys[g] = row.factionName:lower()
                end
                groups[row.factionName] = g
            end
            if g then
                g.rows[#g.rows + 1] = row
                if row.factionLeader ~= g.leader then g.changed = true end
            end
        end
    end
    for _, g in ipairs(list) do
        local order = {}
        for _, row in ipairs(g.rows) do order[row] = F.displayName(row):lower() end
        g.rows = MVM.sortByKey(g.rows, order)
    end
    return MVM.sortByKey(list, keys)
end

-- 「分享給我」最上面的暫停提示列（kind＝FPAUSED_SHARED）：快照的 factionPaused，只有陣營名與台數
function F.sharedPausedItems(b)
    local out = {}
    for _, g in ipairs(b and b.factionPaused or {}) do
        out[#out + 1] = { kind = "FPAUSED_SHARED", oid = "fpshared:" .. g.name, name = g.name, n = #g.oids }
    end
    return out
end

-- 轉讓陣營領袖前的提醒台數：分享給我的陣營車（陣營成員看得到所有分享給陣營的車）＋自己分享給陣營的車
function F.factionShareCount(b)
    local n = 0
    for _, row in pairs(b and b.rows or {}) do
        if row.role == "FACTION" or (row.role == "OWNER" and row.factionShare and row.factionState == "GRANTED"
            and (row.factionActionBits or 0) > 0 and not F.isHistory(row)) then n = n + 1 end
    end
    return n
end

-- 管理頁清單：玩家列（kind＝PLAYER）後面接展開時的車輛列。名額以 server 的 players 為準；沒有車主的紀錄
-- （證據衝突的隔離紀錄）歸在 user＝"" 一組。搜尋：玩家名稱符合＝整組照常顯示；否則只留符合的車並自動展開。
-- 玩家依帳號排序；每組先列受保護與待處理的車，歷史紀錄排最後，各依名稱排序
function F.adminItems(rows, players, query, expanded)
    local q = query and query:lower() or ""
    local groups, list, keys = {}, {}, {}
    local function group(user)
        local g = groups[user]
        if g == nil then
            g = { kind = "PLAYER", oid = "player:" .. user, user = user, rows = {}, counts = {} } -- oid 只當清單選取鍵
            groups[user] = g
            list[#list + 1] = g
            keys[g] = user:lower()
        end
        return g
    end
    for _, p in ipairs(players or {}) do group(p.user).info = p end
    for _, row in pairs(rows or {}) do
        local g = group(row.owner or "")
        g.rows[#g.rows + 1] = row
        local k = F.isHistory(row) and "HISTORY" or row.state
        g.counts[k] = (g.counts[k] or 0) + 1
    end
    local out = {}
    for _, g in ipairs(MVM.sortByKey(list, keys)) do
        local nameHit = q == "" or g.user:lower():find(q, 1, true) ~= nil
        local shown = nameHit and g.rows or F.filter(g.rows, "ADMIN", q)
        if nameHit or #shown > 0 then
            g.open = expanded[g.user] == true or not nameHit
            g.summary = F.playerSummary(g)
            out[#out + 1] = g
            if g.open then
                local order = {}
                for _, row in ipairs(shown) do order[row] = (F.isHistory(row) and "1" or "0") .. F.displayName(row):lower() end
                for _, row in ipairs(MVM.sortByKey(shown, order)) do out[#out + 1] = row end
            end
        end
    end
    return out
end

-- 批次名額的選取：picked＝帳號 → true，跨搜尋與重建保留。沒有車主的隔離紀錄組（user＝""）不能選。
-- 伺服器一次最多收 BATCH_MAX 位（Server.lua S.BATCH_MAX）
F.BATCH_MAX = 500
function F.pickable(row) return row ~= nil and row.kind == "PLAYER" and row.user ~= "" end

function F.togglePick(picked, row)
    if not F.pickable(row) then return false end
    picked[row.user] = not picked[row.user] or nil
    return true
end

-- 全選目前清單：目前搜尋結果裡的玩家列
function F.pickShown(picked, items)
    for _, it in ipairs(items) do if F.pickable(it) then picked[it.user] = true end end
end

function F.clearPicks(picked) for user in pairs(picked) do picked[user] = nil end end

-- 送給伺服器的帳號清單（依帳號排序，長度就是已選人數）
function F.pickedList(picked)
    local list, keys = {}, {}
    for user in pairs(picked) do list[#list + 1] = user; keys[user] = user:lower() end
    return MVM.sortByKey(list, keys)
end

-- 找到身邊這筆紀錄的車（解除綁定／轉讓／重新核發需要車在身邊）。先以見證對 oid；
-- WITNESS_STALE 的見證可能不見或對錯，改找身邊同車型、沒有帶著自己其他有效列見證的車，交給 server 以 native 欄位驗證
function F.findLoaded(row)
    local player = getSpecificPlayer(0)
    local reach = MVM.sandbox("ClaimDistance", 2.5)
    local fallback
    local it = getCell():getVehicles():iterator()
    while it:hasNext() do
        local v = it:next()
        local proj = MVM.clientProjection(0, v)
        if proj and proj.oid == row.oid then return v end
        if row.state == "WITNESS_STALE" and fallback == nil and player and v:getScriptName() == row.script
            and (proj == nil or proj.role == "OTHER" or proj.state == "WITNESS_STALE")
            and math.floor(player:getZ()) == math.floor(v:getZ())
            and (player:getX() - v:getX()) ^ 2 + (player:getY() - v:getY()) ^ 2 <= reach * reach then
            fallback = v
        end
    end
    return fallback
end

-- ------------------------------------------------------------------ 視窗 ---
-- 框架由 mod.info require= 保證存在；版本不足（rev < 7）時不建立視窗，只記一行 log。harness 沒有框架，停在這裡
if not (MinidoracatUI and MinidoracatUI.v1) then pcall(require, "MinidoracatUI/V1") end
local UI = MinidoracatUI and MinidoracatUI.v1
local CAPS = UI and UI.CAPABILITIES
if not (UI and UI.API_MAJOR == 1 and UI.API_REVISION >= 7 and CAPS.window and CAPS.controls and CAPS.dialog
    and CAPS.virtualList and CAPS.floatButton) then
    if UI then MVM.log("fleet window needs MinidoracatUIFor42 API rev 7, found rev " .. tostring(UI.API_REVISION)) end
    return
end

-- 底色加深：預設 surface（a=0.8）會讓場景透出來、干擾文字
local theme = UI.Theme.create({ colors = { surface = { r = 0.04, g = 0.045, b = 0.05, a = 0.95 } } })
local COL = theme.colors
local FS, FM = UIFont.Small, UIFont.Medium
local PAD, GAP = 12, 6
local LAYOUT = "MinidoracatVehicleManagerFleet"

local function fontH(font) return getTextManager():getFontHeight(font) end
local function text(el, s, x, y, token, font)
    local c = COL[token]
    el:drawText(s, x, y, c.r, c.g, c.b, c.a, font or FS)
end

-- 超出寬度就截斷並加 "..."（完整文字在右側詳情）；只在綁定時量字寬，不在每幀。Kahlua 字串以字元計，中文不會切半
local function measure(s, font) return getTextManager():MeasureStringX(font, s) end
local function fit(s, w)
    local tm = getTextManager()
    if tm:MeasureStringX(FS, s) <= w then return s end
    local lo, hi = 0, #s
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if tm:MeasureStringX(FS, s:sub(1, mid) .. "...") <= w then lo = mid else hi = mid - 1 end
    end
    return s:sub(1, lo) .. "..."
end

-- 清單列：選取狀態存在 list，cell 只是投影；文字在 bind 時算好，render 不配置。
-- 管理頁的玩家列最左畫批次勾選框（BOX_W 寬的點擊區），再畫展開箭頭與右側「已用 / 上限」，車輛列縮排在玩家底下
local INDENT = 24
local BOX_W = 26
local Cell = ISPanel:derive("MVMFleetCell")
function Cell:render()
    local row = self.row
    if row == nil then return end
    local list = self.list
    local h = self.height
    if list:isSelected(self.index) then
        theme:fill(self, 0, 0, self.width, h, "selected")
    elseif list:isMouseOver() and list:indexAt(list:getMouseX(), list:getMouseY()) == self.index then
        theme:fill(self, 0, 0, self.width, h, "hover")
    end
    local fh = fontH(FS)
    local x = self.indent
    if self.player then
        if self.box then
            local by = math.floor((h - 14) / 2)
            if self.fleet.picked[row.user] then
                theme:fill(self, x + 6, by, 14, 14, "accent", "rect")
            else
                theme:border(self, x + 6, by, 14, 14, "textMuted", "rect")
            end
            x = x + BOX_W
        end
        if not UI.Icons.draw(self, row.open and "chevronDown" or "chevronRight", x + 10, math.floor((h - 16) / 2), 16, COL.textMuted, 1) then
            text(self, row.open and "-" or "+", x + 14, math.floor((h - fh) / 2), "textMuted")
        end
        text(self, self.count, self.width - 10 - self.countW, math.floor(h / 2) - fh - 1, "text")
    -- 車輛列左側畫這台車在地圖上的圖示與顏色（外觀設定），框架缺圖時退回狀態圓點
    elseif not UI.Icons.draw(self, self.icon, x + 8, math.floor((h - 20) / 2), 20, self.color, 1) then
        UI.Skin.dot(self, x + 12, math.floor(h / 2) - 4, 8, COL[self.token])
    end
    text(self, self.title, x + 36, math.floor(h / 2) - fh - 1, self.titleToken)
    text(self, self.sub, x + 36, math.floor(h / 2) + 1, "textMuted")
    -- 防破壞中的車：副標右側盾牌＋字，清單上一眼看得到（寬度在 build 量好）
    if self.tag then
        local f, y = self.fleet, math.floor(h / 2) + 1
        local tx = self.width - 10 - f.guardTagW
        UI.Icons.draw(self, "shieldCheck", tx, y + math.floor((fh - 14) / 2), 14, COL.text, 1)
        text(self, f.guardTag, tx + 18, y, "text")
    end
end

-- 內容區：每幀 tick（搜尋、走近車輛、資料變更），並畫詳情卡、段落標題與頁尾
local Body = ISPanel:derive("MVMFleetBody")
-- PZ 先畫子元件再呼叫 render：清單底色必須在 prerender 畫，否則會蓋在列文字上
function Body:prerender()
    local f = self.fleet
    f:tick()
    theme:fill(self, PAD, f.listTop, f.listW, f.listH, "well")
end
function Body:render() self.fleet:draw(self) end
-- 詳情卡的座標列（draw 記下 copyHit）：點一下複製座標
function Body:onMouseDown(x, y)
    local hit = self.fleet.copyHit
    if hit and x >= hit.x and x < hit.x + hit.w and y >= hit.y and y < hit.y + hit.h then
        self.fleet:copyCoords(hit.value)
        return true
    end
    return ISPanel.onMouseDown(self, x, y)
end
-- 詳情放不下時（layoutDetail 算出的 scrollMax）：滑鼠在詳情區上滾輪捲動
function Body:onMouseWheel(del)
    local f = self.fleet
    if (f.scrollMax or 0) <= 0 or self:getMouseX() < f.detailX then return false end
    f.scroll = (f.scroll or 0) + del * (f.fh + 2) * 3
    f:layoutDetail()
    f:keepFocus()
    return true
end
-- Focus 落點前呼叫（焦點描述的 scrollOwner）：把捲出可視範圍的控制項捲進來
function Body:scrollTo(control) self.fleet:scrollToControl(control) end

local FleetWindow = {}
FleetWindow.__index = FleetWindow
MVM.FleetWindow = FleetWindow

function FleetWindow.new()
    local self = setmetatable({ tab = "OWNED", query = "", selectedOid = nil, current = nil, pending = nil, message = nil,
        messageBad = false, dirty = true, lastNearCheck = 0, headings = {}, expanded = {}, picked = {} }, FleetWindow)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w = math.min(940, math.floor(sw * 0.92))
    local h = math.min(720, math.floor(sh * 0.9)) -- 1080p 下管理頁玩家詳情不用捲；720p 時是 648
    self.win = UI.Window.new({ x = math.floor((sw - w) / 2), y = math.floor((sh - h) / 2), width = w, height = h,
        title = getText("IGUI_MVM_FleetTitle"), icon = "steeringwheel", theme = theme })
    self:build()
    return self
end

function FleetWindow:getIsVisible() return self.win:getIsVisible() end

function FleetWindow:button(title, fn, style, icon)
    local b = UI.Button.new({ x = 0, y = 0, height = self.ch, title = title, style = style, icon = icon, theme = theme,
        target = self, onClick = fn })
    b:setVisible(false)
    self.body:addChild(b)
    return b
end

function FleetWindow:field(width, placeholder, numbers)
    local f = UI.TextField.new({ x = 0, y = 0, width = width, height = self.ch, placeholder = placeholder, onlyNumbers = numbers,
        theme = theme })
    f:setVisible(false)
    self.body:addChild(f)
    return f
end

function FleetWindow:build()
    local win = self.win
    local top = win:contentTop()
    local body = Body:new(0, top, win.width, win.height - top)
    body.background = false
    body.fleet = self
    body:initialise()
    win:addChild(body)
    self.body = body
    local fh = fontH(FS)
    self.fh, self.ch = fh, fh + 10
    self.guardTag = getText("IGUI_MVM_Guard_Tag")
    self.guardTagW = 18 + measure(self.guardTag, FS)
    local W, H = body.width, body.height

    self.tabs = UI.Tabs.new({ x = PAD, y = PAD, height = self.ch, theme = theme, target = self, onSelect = FleetWindow.onTab,
        selected = "OWNED", items = {
            { id = "OWNED", label = getText("IGUI_MVM_Tab_OWNED") },
            { id = "SHARED", label = getText("IGUI_MVM_Tab_SHARED") },
            { id = "LOG", label = getText("IGUI_MVM_Tab_LOG") },
            { id = "ADMIN", label = getText("IGUI_MVM_Tab_ADMIN") } } })
    self.tabs:setItemVisible("ADMIN", false)
    body:addChild(self.tabs)
    local searchW = math.min(260, math.floor(W * 0.3))
    self.search = UI.TextField.new({ x = W - PAD - searchW, y = PAD, width = searchW, height = self.ch, theme = theme,
        placeholder = getText("IGUI_MVM_Search"), onChange = function(_, t) self.query = t or ""; self.dirty = true end })
    body:addChild(self.search)
    -- 名額（付費名額視窗）：搜尋框左邊；Economy 不在場時視窗內說明原因
    self.btnSlots = UI.Button.new({ x = 0, y = PAD, height = self.ch, title = getText("IGUI_MVM_Btn_Slots"), icon = "coins",
        theme = theme, target = self, onClick = FleetWindow.onSlots })
    self.btnSlots:setX(W - PAD - searchW - GAP - self.btnSlots.width)
    body:addChild(self.btnSlots)

    self.footerH = fh * 2 + 20
    self.listTop = PAD + self.ch + PAD
    self.listW = math.floor(W * 0.36)
    self.listH = H - self.listTop - self.footerH - PAD
    self.list = UI.VirtualList.new({ x = PAD, y = self.listTop, width = self.listW, height = self.listH,
        rowHeight = fh * 2 + 16, padding = 4,
        createCell = function(l)
            local c = Cell:new(0, 0, 0, 0)
            c.background = false
            c.list, c.fleet = l, self
            return c
        end,
        bindCell = function(_, c, row, index)
            c.row, c.index = row, index
            c.player = row.kind == "PLAYER"
            c.box = self.tab == "ADMIN" and F.pickable(row)
            c.indent = (self.tab == "ADMIN" and not c.player) and INDENT or 0
            c.tag = nil
            local w = c.width - c.indent - 36 - 10 - (c.box and BOX_W or 0)
            if c.player then
                local info = row.info
                c.count = info and (info.used .. " / " .. info.limit) or ""
                c.countW = getTextManager():MeasureStringX(FS, c.count)
                c.title = fit(row.user == "" and getText("IGUI_MVM_Admin_NoOwner") or row.user, w - c.countW - GAP)
                c.sub, c.titleToken = fit(row.summary, w), "text"
            elseif row.kind == "FPAUSE" or row.kind == "FPAUSED_SHARED" then
                -- 陣營分享暫停列：陣營圖示與標題用強調色（要處理），副標寫幾台
                c.icon, c.color, c.token, c.titleToken = "users", COL.accent, "accent", "accent"
                c.title, c.sub = fit(F.pausedTitle(row), w), fit(F.pausedSub(row), w)
            elseif row.kind == "NOTICE" then
                -- 通知：圓點強調色＝未讀（離線時收到、打開分頁前沒看過），錯誤色＝車被攻擊
                local sub = F.agoText(row.e.t or 0, getTimestampMs())
                if not row.e.live then sub = sub .. getText("IGUI_MVM_Sep") .. getText("IGUI_MVM_Notice_WhileOffline") end
                c.icon, c.color = nil, nil
                c.title, c.sub = fit(row.text, w), fit(sub, w)
                c.token = row.unread and "accent" or (row.e.bad and "errorText" or "textFaint")
                c.titleToken = "text"
            else
                c.color, c.icon = MVM.Appearance.get(row)
                -- 狀態在前：清單寬度不夠時被截掉的是原始車名，不是狀態
                local sub = F.stateText(row, getTimestampMs())
                if F.renamed(row) then sub = sub .. getText("IGUI_MVM_Sep") .. F.modelName(row) end
                c.tag = row.guard == "ON"
                c.title, c.sub = fit(F.displayName(row), w), fit(sub, c.tag and w - self.guardTagW - GAP or w)
                c.token, c.titleToken = F.stateToken(row), F.isHistory(row) and "textMuted" or "text"
            end
        end,
        unbindCell = function(_, c) c.row = nil end,
        onSelect = function(_, row)
            self:select(row)
            -- 點玩家列（或焦點框上按 Enter／手把 A）＝選取並切換展開（清單在下一幀重建）
            if row and row.kind == "PLAYER" then self.expanded[row.user] = not row.open; self.dirty = true end
            self:layoutDetail()
        end,
        -- 鍵盤方向鍵／手把上下只移動反白：詳情跟著換，不切換展開（框架 rev 10）
        onHighlight = function(_, row)
            self:select(row)
            self:layoutDetail()
        end,
        onKey = function(_, key, row, index) return self:treeKey(key, row, index) end,
        colors = { thumb = COL.textFaint, thumbHover = COL.textMuted, track = COL.hover } })
    self.list:initialise()
    -- 點玩家列的勾選框只切換批次選取，不改反白與展開；其餘點擊照清單原本的選取
    local listDown = self.list.onMouseDown
    self.list.onMouseDown = function(l, x, y)
        local i = l:indexAt(x, y)
        local row = i and l:getItems()[i]
        if self.tab == "ADMIN" and x < BOX_W and F.pickable(row) then
            self:togglePick(row)
            return true
        end
        return listDown(l, x, y)
    end
    body:addChild(self.list)

    self.detailX = PAD * 2 + self.listW
    self.detailTop = self.listTop
    self.detailW = W - self.detailX - PAD
    self.infoH = 0 -- 詳情卡高度依內容行數（layoutDetail）
    -- 頁尾：保護範圍一句話（依停車保全模式，layoutDetail 模式變了才換；完整說明在綁定確認框）、越權中的提醒；
    -- 兩句都寫得夠短，不截字
    self.overrideActive = getText("IGUI_MVM_Override_Active")

    self.btnRename = self:button(getText("IGUI_MVM_Btn_Rename"), FleetWindow.onRename)
    self.userEntry = self:field(180, getText("IGUI_MVM_UserHint"))
    self.btnAddMember = self:button(getText("IGUI_MVM_Btn_AddMember"), FleetWindow.onAddMember, "primary")
    self.btnFaction = self:button(getText("IGUI_MVM_Btn_FactionOn"), FleetWindow.onFaction)
    self.btnPublic = self:button(getText("IGUI_MVM_Btn_PublicOn"), FleetWindow.onPublic)
    self.btnTransfer = self:button(getText("IGUI_MVM_Btn_Transfer"), FleetWindow.onTransfer)
    -- 新增分享時要給的權限：短名稱、寬度照標籤（欄數在 layoutDetail 依最寬的一個決定，各語系都不重疊）。
    -- 切換時重排：標題列的「全選／全不選」跟著現在勾的狀態
    self.checks = {}
    for i, a in ipairs(SHAREABLE) do
        local cb = UI.Checkbox.new({ x = 0, y = 0, label = getText("IGUI_MVM_ActionShort_" .. a), theme = theme, target = self,
            onChange = FleetWindow.onShareCheck })
        cb.internal = a
        cb:setVisible(false)
        body:addChild(cb)
        self.checks[i] = cb
    end
    self.btnCheckAll = self:button(getText("IGUI_MVM_Btn_CheckAll"), FleetWindow.onCheckAll)
    self.btnCheckAll:setTooltip(getText("IGUI_MVM_CheckAll_Tip"))
    -- 陣營分享暫停（「我的車」最上面那列）的恢復：全選／全不選、每台一個勾選（restoreBox 用到才建）、恢復 N 台
    self.btnRestoreAll = self:button(getText("IGUI_MVM_Btn_CheckAll"), FleetWindow.onRestoreAll)
    self.btnRestoreNone = self:button(getText("IGUI_MVM_Btn_CheckNone"), FleetWindow.onRestoreNone)
    self.btnRestore = self:button(getText("IGUI_MVM_Btn_RestoreN", 0), FleetWindow.onRestore, "primary")
    self.restoreBoxes, self.restorePick = {}, {}
    -- 目前的分享：所有人、陣營、每位成員各一顆停止／移除鈕（x 圖示，標題「對象：權限」，提示寫動作）
    self.btnPublicOff = self:button("", FleetWindow.onPublicOff, "normal", "close")
    self.btnFactionOff = self:button("", FleetWindow.onFactionOff, "normal", "close")
    self.memberButtons = {}
    for i = 1, 16 do self.memberButtons[i] = self:button("", FleetWindow.onRemoveMember, "normal", "close") end
    self.btnUnclaim = self:button(getText("IGUI_MVM_Btn_Unclaim"), FleetWindow.onUnclaim, "danger")
    self.btnReport = self:button(getText("IGUI_MVM_Btn_ReportLost"), FleetWindow.onReportLost, "danger")
    self.btnCancel = self:button(getText("IGUI_MVM_Btn_CancelRelease"), FleetWindow.onCancelRelease, "primary")
    self.btnReissue = self:button(getText("IGUI_MVM_Btn_Reissue"), FleetWindow.onReissue, "primary")
    self.btnDismiss = self:button(getText("IGUI_MVM_Btn_Dismiss"), FleetWindow.onDismiss)
    self.btnMap = self:button(getText("IGUI_MVM_Btn_Map"), FleetWindow.onMap, "normal", "locate")
    self.btnTeleport = self:button(getText("IGUI_MVM_Btn_Teleport"), FleetWindow.onTeleport, "normal", "pin")
    self.btnLook = self:button(getText("IGUI_MVM_Btn_Appearance"), FleetWindow.onAppearance, "normal", "sliders")
    self.btnLeave = self:button(getText("IGUI_MVM_Btn_Leave"), FleetWindow.onLeave, "danger")
    self.btnAdminRelease = self:button(getText("IGUI_MVM_Btn_AdminRelease"), FleetWindow.onAdminRelease, "danger")
    self.quotaEntry = self:field(80, nil, true)
    self.btnQuota = self:button(getText("IGUI_MVM_Btn_Quota"), FleetWindow.onQuota, "primary")
    self.btnQuotaDefault = self:button(getText("IGUI_MVM_Btn_QuotaDefault"), FleetWindow.onQuotaDefault)
    -- 手把沒有勾選框可點：玩家詳情的「加入批次／移出批次」
    self.btnPick = self:button(getText("IGUI_MVM_Btn_PickAdd"), FleetWindow.onPick)
    self.btnPickShown = self:button(getText("IGUI_MVM_Btn_PickShown"), FleetWindow.onPickShown)
    self.btnPickClear = self:button(getText("IGUI_MVM_Btn_PickClear"), FleetWindow.onPickClear)
    self.batchEntry = self:field(80, "0-100", true)
    self.btnBatch = self:button(getText("IGUI_MVM_Btn_BatchQuota"), FleetWindow.onBatchQuota)
    self.btnBatchDefault = self:button(getText("IGUI_MVM_Btn_QuotaDefault"), FleetWindow.onBatchDefault)
    self.defaultEntry = self:field(80, "0-20", true)
    self.btnDefaultQuota = self:button(getText("IGUI_MVM_Btn_Apply"), FleetWindow.onDefaultQuota)
    self.btnDefaultQuota:setTooltip(getText("IGUI_MVM_DefaultQuota_Tip"))
    self.releaseEntry = self:field(80, "0-365", true)
    self.btnReleaseDays = self:button(getText("IGUI_MVM_Btn_Apply"), FleetWindow.onReleaseDays)
    self.btnReleaseDays:setTooltip(getText("IGUI_MVM_ReleaseDays_Tip"))
    self.btnMigrate = self:button(getText("IGUI_MVM_Btn_ImportMVCK"), FleetWindow.onImportMVCK)
    self.btnIdentity = self:button(getText("IGUI_MVM_Btn_ImportIdentity"), FleetWindow.onImportIdentity)
    self.btnRebind = self:button("", FleetWindow.onRebindIdentity, "danger")
    self.btnPaidSlots = self:button(getText("IGUI_MVM_Btn_PaidSettings"), FleetWindow.onPaidSlots, "normal", "settings")
    self.btnPaidGuard = self:button(getText("IGUI_MVM_Btn_PaidGuardSettings"), FleetWindow.onPaidGuard, "normal", "settings")
    self.overrideBox = UI.Checkbox.new({ x = 0, y = 0, label = getText("IGUI_MVM_Override_Toggle"), theme = theme, target = self,
        onChange = FleetWindow.onOverride })
    self.overrideBox:setVisible(false)
    body:addChild(self.overrideBox)
    -- 停車保全模式（管理頁）：三顆 chip（框架 rev 11），亮起的是伺服器現在的值；按別顆先確認
    self.guardChips = {}
    for n = 1, 3 do
        local c = self:button(getText("IGUI_MVM_GuardMode_" .. n), FleetWindow.onGuardMode, "chip")
        c.internal, c._focusGroup = n, "guardMode"
        c:setTooltip(getText("IGUI_MVM_GuardMode_Tip"))
        self.guardChips[n] = c
    end
    self.guardSlotsEntry = self:field(80, "0-20", true)
    self.btnGuardSlotsDefault = self:button(getText("IGUI_MVM_Btn_Apply"), FleetWindow.onGuardSlotsDefault)
    self.btnGuardSlotsDefault:setTooltip(getText("IGUI_MVM_GuardSlots_Tip"))
    self.guardQuotaEntry = self:field(80, nil, true)
    self.btnGuardQuota = self:button(getText("IGUI_MVM_Btn_GuardQuota"), FleetWindow.onGuardQuota)
    self.btnGuardQuotaDefault = self:button(getText("IGUI_MVM_Btn_QuotaDefault"), FleetWindow.onGuardQuotaDefault)
    -- 車主的停車保全開關（SLOTS 模式）：Checkbox 沒有 tooltip，借原版按鈕的畫法（ISButton.lua:316-346；
    -- 開關隱藏時 ISToolTip 自己收掉：ISToolTip.lua:58-61）
    self.guardBox = UI.Checkbox.new({ x = 0, y = 0, label = getText("IGUI_MVM_Guard_Toggle"), theme = theme,
        target = self, onChange = FleetWindow.onGuard })
    self.guardBox.tooltip = getText("IGUI_MVM_Guard_Toggle_Tip")
    local boxPrerender = self.guardBox.prerender
    self.guardBox.prerender = function(cb) boxPrerender(cb); ISButton.updateTooltip(cb) end
    self.guardBox:setVisible(false)
    body:addChild(self.guardBox)
    self.btnGuardSlots = self:button(getText("IGUI_MVM_Btn_GuardSlots"), FleetWindow.onGuardSlots, "normal", "coins")
    self.actionButtons = { self.btnRename, self.btnAddMember, self.btnFaction, self.btnPublic, self.btnTransfer, self.btnUnclaim,
        self.btnReport, self.btnCancel, self.btnReissue, self.btnDismiss, self.btnLeave, self.btnAdminRelease, self.btnQuota,
        self.btnQuotaDefault, self.btnBatch, self.btnBatchDefault, self.btnDefaultQuota, self.btnReleaseDays, self.btnMigrate,
        self.btnIdentity, self.btnRebind, self.overrideBox, self.btnPublicOff, self.btnFactionOff, self.guardBox,
        self.btnGuardSlotsDefault, self.btnGuardQuota, self.btnGuardQuotaDefault, self.btnRestore }
    self.detailControls = { self.btnRename, self.userEntry, self.btnAddMember, self.btnFaction, self.btnPublic,
        self.btnTransfer, self.btnUnclaim, self.btnReport, self.btnCancel, self.btnReissue, self.btnDismiss, self.btnMap, self.btnTeleport,
        self.btnLeave, self.btnAdminRelease, self.quotaEntry, self.btnQuota, self.btnQuotaDefault, self.btnPick,
        self.btnPickShown, self.btnPickClear, self.batchEntry, self.btnBatch, self.btnBatchDefault, self.defaultEntry,
        self.btnDefaultQuota, self.releaseEntry, self.btnReleaseDays, self.btnMigrate, self.btnIdentity, self.btnRebind,
        self.btnLook, self.overrideBox, self.btnPaidSlots, self.btnPublicOff, self.btnFactionOff, self.btnPaidGuard,
        self.guardSlotsEntry, self.btnGuardSlotsDefault, self.guardQuotaEntry, self.btnGuardQuota, self.btnGuardQuotaDefault,
        self.guardBox, self.btnGuardSlots, self.btnCheckAll, self.btnRestoreAll, self.btnRestoreNone, self.btnRestore }
    for _, c in ipairs(self.guardChips) do
        self.actionButtons[#self.actionButtons + 1] = c
        self.detailControls[#self.detailControls + 1] = c
    end
    for _, cb in ipairs(self.checks) do self.detailControls[#self.detailControls + 1] = cb end
    for _, b in ipairs(self.memberButtons) do
        self.actionButtons[#self.actionButtons + 1] = b
        self.detailControls[#self.detailControls + 1] = b
    end
    self.detailSet, self.placed, self.focusList, self.focusPool = {}, {}, {}, {}
    for _, c in ipairs(self.detailControls) do
        self.detailSet[c] = true
        if c._entry then c.scrollTo = function(field) self:scrollToControl(field) end end
    end
    -- 鍵盤／手把：詳情要捲動時，捲出可視範圍的控制項也要走得到（keyboardTargets 帶 scrollOwner，落點前先捲過去）
    self.win.keyboardTargets = function(w) return self:focusTargets(w) end
end

function FleetWindow:who()
    local p = getSpecificPlayer(0)
    if p == nil then return nil end
    return isClient() and p:getUsername() or "local:0"
end

function FleetWindow:bucket()
    local who = self:who()
    return who and C.buckets[who] or nil
end

function FleetWindow:selectedRow() return self.current end

-- 換到另一列：詳情捲回頂端；權限開關是「這次要給的權限」、不是這台車現有的分享，換車就清空
function FleetWindow:select(row)
    local oid = row and row.oid
    if oid ~= self.selectedOid then
        self.scroll = 0
        for _, cb in ipairs(self.checks or {}) do cb:setChecked(false, true) end
    end
    self.selectedOid, self.current = oid, row
end

-- 鍵盤／手把把反白移到第 i 列（同滑鼠以外的移動：詳情跟著換，不切換展開）
function FleetWindow:highlight(i)
    local row = self.list:getItems()[i]
    if row == nil then return end
    self.list:setSelectedIndex(i)
    self.list:scrollToIndex(i)
    self:select(row)
    self:layoutDetail()
end

-- 管理頁樹狀清單的左右鍵（鍵盤焦點框與手把方向同）：右＝展開／進到第一台車，左＝收合／回到車主；
-- Space＝切換反白中玩家的批次選取（不展開）。回 false 的鍵交回框架（手把會移到上／下一個控制項）
function FleetWindow:treeKey(key, row, index)
    if self.tab ~= "ADMIN" or row == nil or index == nil then return false end
    if key == Keyboard.KEY_SPACE then return self:togglePick(row) end
    local right, left = key == Keyboard.KEY_RIGHT, key == Keyboard.KEY_LEFT
    if not (right or left) then return false end
    local items = self.list:getItems()
    if row.kind == "PLAYER" then
        if right and not row.open then
            self.expanded[row.user] = true
            self.dirty = true
            return true
        end
        if left and row.open then
            self.expanded[row.user] = false
            self.dirty = true
            return true
        end
        local nextRow = items[index + 1]
        if right and nextRow ~= nil and nextRow.kind ~= "PLAYER" then
            self:highlight(index + 1)
            return true
        end
        return false
    end
    if left then
        for i = index - 1, 1, -1 do
            if items[i].kind == "PLAYER" then
                self:highlight(i)
                return true
            end
        end
    end
    return false
end

-- 客戶端看到的陣營（原版同步給所有客戶端）：現在的領袖、自己在不在裡面
local function factionInfo(name)
    local f = Faction and Faction.getFaction(name)
    local p = getSpecificPlayer(0)
    if f == nil or p == nil then return nil end
    local me = p:getUsername()
    return { leader = f:getOwner(), mine = f:getOwner() == me or f:isMember(me) }
end

-- keyed replace：重建清單時保留選取的 oid（管理頁的玩家列以 player:帳號 當鍵）。沒在搜尋時，陣營分享暫停列排在最上面
-- （我的車：可一鍵恢復的；分享給我：暫停提示）
function FleetWindow:rebuild()
    self.dirty = false
    local b = self:bucket()
    local admin = b ~= nil and b.admin ~= nil
    self.tabs:setItemVisible("ADMIN", admin)
    if self.tab == "ADMIN" and not admin then self.tab = "OWNED"; self.tabs:setSelected("OWNED", true) end
    local rows
    if self.tab == "ADMIN" then
        rows = F.adminItems(b.admin, b.adminPlayers, self.query, self.expanded)
        local t = { players = 0, bound = 0 }
        for _, p in ipairs(b.adminPlayers or {}) do t.players, t.bound = t.players + 1, t.bound + p.used end
        self.totals = t
    elseif self.tab == "LOG" then
        rows = F.noticeItems(b, self.query, self.logReadAt)
        self:markNoticesRead(b)
    else
        rows = F.filter(b and b.rows, self.tab, self.query)
        if self.query == "" then
            local top = self.tab == "OWNED" and F.pausedGroups(b and b.rows, factionInfo) or F.sharedPausedItems(b)
            for _, row in ipairs(rows) do top[#top + 1] = row end
            rows = top
        end
    end
    local unread = MVM.noticeUnread(b)
    self.tabs:setItemLabel("LOG", unread > 0 and getText("IGUI_MVM_Tab_LOG_N", unread) or getText("IGUI_MVM_Tab_LOG"))
    local keep = nil
    for i, row in ipairs(rows) do if row.oid == self.selectedOid then keep = i end end
    if keep == nil and #rows > 0 then keep = 1 end
    self.list:setItems(rows)
    self.list:setSelectedIndex(keep)
    self.current = keep and rows[keep] or nil
    self.selectedOid = self.current and self.current.oid or nil
    self:layoutDetail()
end

-- 「紀錄」分頁打開時：已讀到最新一則（伺服器時間；合併的通知會更新最後一則的時間）。同一個時間只送一次，
-- ACK 成功才改本機的已讀時間（不樂觀更新）
function FleetWindow:markNoticesRead(b)
    local list = b and b.notices or {}
    local t = list[#list] and list[#list].t or 0
    if t <= (b and b.noticeRead or 0) or t == self.readSent then return end
    self.readSent = t
    C.request(getSpecificPlayer(0), "noticesRead", { upToMs = t }, function(ack)
        if ack.ok and (b.noticeRead or 0) < t then b.noticeRead = t end
        self.dirty = true
    end)
end

local function place(ctrl, x, y) ctrl:setX(x); ctrl:setY(y); ctrl:setVisible(true); return x + ctrl.width + GAP end

function FleetWindow:headingText(text, y)
    self.headings[#self.headings + 1] = { text = text, y = y }
    return y + self.fh + 4
end

function FleetWindow:heading(key, y, arg) return self:headingText(arg ~= nil and getText(key, arg) or getText(key), y) end

-- 一排控制項由左往右放，放不下就換到下一排（右緣留給捲軸）。回傳下一段的 y
function FleetWindow:flow(ctrls, y)
    local x0, right = self.detailX, self.detailX + self.detailW - 8
    local x, h = x0, 0
    for _, c in ipairs(ctrls) do
        if x > x0 and x + c.width > right then x, y, h = x0, y + h + GAP, 0 end
        x = place(c, x, y)
        h = math.max(h, c.height)
    end
    return y + h + GAP
end

-- 管理頁的列：「標題＋控制項」同一列，控制項對齊同一欄（這一組最寬的標題之後），放不下的列改成標題在上、
-- 控制項在下（左緣）。r.next＝同一列的第二排控制項；r.gap＝這一列前面多空一段（分組）。回傳下一段的 y
function FleetWindow:toolRows(rows, y)
    local x0, step, tm = self.detailX, self.ch + GAP, getTextManager()
    local right = x0 + self.detailW - 8 -- 右緣留給放不下時的捲軸
    local col = 0
    for _, r in ipairs(rows) do col = math.max(col, tm:MeasureStringX(FS, r.title)) end
    col = x0 + col + GAP * 2
    local function width(list)
        local w = 0
        for i, c in ipairs(list) do w = w + c.width + (i > 1 and GAP or 0) end
        return w
    end
    for _, r in ipairs(rows) do
        if r.gap then y = y + PAD end
        local inline = col + width(r.buttons) <= right
        local x = inline and col or x0
        if inline then
            self.headings[#self.headings + 1] = { text = r.title, y = y + math.floor((self.ch - self.fh) / 2) }
        else
            y = self:headingText(r.title, y)
        end
        for _, c in ipairs(r.buttons) do x = place(c, x, y) end
        y = y + step
        if r.next then
            x = (inline and col + width(r.next) <= right) and col or x0
            for _, c in ipairs(r.next) do x = place(c, x, y) end
            y = y + step
        end
    end
    return y
end

-- 管理頁詳情（資訊卡以下），全部一列一項、說明收進提示文字：選到的玩家（基本名額、保全名額）或車 → 批次 → 身分驗證
-- （Steam 伺服器）→ MVCK → 付費名額 → 全服預設名額 → 閒置解除天數 → 停車保全模式（＋全服保全名額）→ 越權。回傳內容底端 y
function FleetWindow:layoutAdmin(row, b, y)
    local rows = {}
    if row ~= nil and row.kind == "PLAYER" then
        local info = row.info
        if info then
            -- 預填目前基本名額；伺服器值變了（設定／恢復預設後的新快照）才重填，不蓋掉正在輸入的值
            local fill = row.user .. ":" .. info.base
            if self.quotaEntry.forKey ~= fill then self.quotaEntry.forKey = fill; self.quotaEntry:setText(tostring(info.base)) end
            local r = { title = getText("IGUI_MVM_Section_Quota"), buttons = { self.quotaEntry, self.btnQuota } }
            if info.custom then r.buttons[#r.buttons + 1] = self.btnQuotaDefault end
            if F.pickable(row) then
                self.btnPick:setTitle(getText(self.picked[row.user] and "IGUI_MVM_Btn_PickRemove" or "IGUI_MVM_Btn_PickAdd"))
                r.buttons[#r.buttons + 1] = self.btnPick
            end
            rows[#rows + 1] = r
            -- 保全名額（伺服器只在 SLOTS 模式給 guardBase）：同基本名額，-1＝恢復伺服器預設
            if info.guardBase ~= nil then
                local gfill = row.user .. ":" .. info.guardBase
                if self.guardQuotaEntry.forKey ~= gfill then
                    self.guardQuotaEntry.forKey = gfill
                    self.guardQuotaEntry:setText(tostring(info.guardBase))
                end
                local g = { title = getText("IGUI_MVM_Section_GuardQuota"), buttons = { self.guardQuotaEntry, self.btnGuardQuota } }
                if info.guardCustom then g.buttons[3] = self.btnGuardQuotaDefault end
                rows[#rows + 1] = g
            end
        end
    elseif row ~= nil then
        local r = { title = getText("IGUI_MVM_Section_Vehicle"), buttons = {} }
        if not F.isHistory(row) and row.state ~= "PENDING_REBIND" then r.buttons[#r.buttons + 1] = self.btnAdminRelease end
        if row.lastKnownX then
            r.buttons[#r.buttons + 1] = self.btnMap
            r.buttons[#r.buttons + 1] = self.btnTeleport
        end
        if #r.buttons > 0 then rows[#rows + 1] = r end
    end
    -- 伺服器工具：批次設定名額（全選目前清單常駐；有選取才多一排名額欄與送出按鈕）、身分驗證（只有 Steam
    -- 伺服器；匯入前沿用帳號名判定，所以標題顯示是否已匯入）、MVCK 匯入、付費名額設定
    local n = #F.pickedList(self.picked)
    local batch = { title = getText("IGUI_MVM_Section_Batch", n), buttons = { self.btnPickShown }, gap = #rows > 0 }
    if n > 0 then
        batch.buttons[2] = self.btnPickClear
        batch.next = { self.batchEntry, self.btnBatch, self.btnBatchDefault }
    end
    rows[#rows + 1] = batch
    if b ~= nil and b.identitySteam then
        local r = { title = getText(b.identityImported and "IGUI_MVM_Section_IdentityOn" or "IGUI_MVM_Section_IdentityPending"),
            buttons = { self.btnIdentity } }
        local c = b.identityConflicts and #b.identityConflicts or 0
        if c > 0 then
            self.btnRebind:setTitle(getText("IGUI_MVM_Btn_RebindIdentity", c))
            r.buttons[2] = self.btnRebind
        end
        rows[#rows + 1] = r
    end
    if b ~= nil and b.migrationAvailable then
        rows[#rows + 1] = { title = getText("IGUI_MVM_Section_MVCK"), buttons = { self.btnMigrate } }
    end
    local mode = b and b.adminGuardMode or MVM.guardModeFor(b)
    local paid = { title = getText("IGUI_MVM_Section_PaidSlots"), buttons = { self.btnPaidSlots } }
    if mode == MVM.GUARD.SLOTS then paid.buttons[2] = self.btnPaidGuard end
    rows[#rows + 1] = paid
    -- 全服設定：預填伺服器值，值變了才重填（不蓋掉正在輸入的值）
    local def, days = b and b.adminDefaultQuota, b and b.adminReleaseDays
    if def ~= nil and self.defaultEntry.forValue ~= def then self.defaultEntry.forValue = def; self.defaultEntry:setText(tostring(def)) end
    if days ~= nil and self.releaseEntry.forValue ~= days then self.releaseEntry.forValue = days; self.releaseEntry:setText(tostring(days)) end
    rows[#rows + 1] = { title = getText("IGUI_MVM_Section_DefaultQuota"), buttons = { self.defaultEntry, self.btnDefaultQuota }, gap = true }
    rows[#rows + 1] = { title = getText("IGUI_MVM_Section_ReleaseDays"), buttons = { self.releaseEntry, self.btnReleaseDays } }
    for n, c in ipairs(self.guardChips) do if c.setActive then c:setActive(n == mode) end end
    rows[#rows + 1] = { title = getText("IGUI_MVM_Section_Guard"), buttons = self.guardChips }
    if mode == MVM.GUARD.SLOTS then
        local slots = b and b.adminGuardSlots
        if slots ~= nil and self.guardSlotsEntry.forValue ~= slots then
            self.guardSlotsEntry.forValue = slots
            self.guardSlotsEntry:setText(tostring(slots))
        end
        rows[#rows + 1] = { title = getText("IGUI_MVM_Section_GuardSlots"), buttons = { self.guardSlotsEntry, self.btnGuardSlotsDefault } }
    end
    self.overrideBox:setChecked(b ~= nil and b.adminOverride == true, true)
    rows[#rows + 1] = { title = getText("IGUI_MVM_Section_Override"), buttons = { self.overrideBox } }
    return self:toolRows(rows, y)
end

-- 權限開關：欄寬＝最寬的標籤，放得下幾欄就排幾欄（最多 4），任何語系都不重疊
function FleetWindow:checkGrid(y)
    local widest = 0
    for _, cb in ipairs(self.checks) do widest = math.max(widest, cb.width) end
    local usable = self.detailW - 8
    local cols = math.max(1, math.min(4, math.floor((usable + GAP) / (widest + GAP * 2))))
    local colW = math.floor(usable / cols)
    for i, cb in ipairs(self.checks) do
        local col = (i - 1) % cols
        place(cb, self.detailX + col * colW, y)
        if col == cols - 1 or i == #self.checks then y = y + cb.height + GAP end
    end
    return y
end

-- 車主的車：動作列在最上面（最常用，也最不該被擠出視窗）→ 停車保全開關（SLOTS 模式）→ 目前分享給（所有人、陣營、
-- 成員各一顆停止鈕）→ 新增分享（先勾權限、再選對象）。回傳內容底端 y
function FleetWindow:layoutOwner(row, b, y)
    local near = F.findLoaded(row)
    self.nearVehicle = near
    local pending = row.state == "PENDING_RELEASE"
    local acts = {}
    if pending then acts[#acts + 1] = self.btnCancel end
    if row.state == "WITNESS_STALE" and near then acts[#acts + 1] = self.btnReissue end
    if row.lastKnownX then acts[#acts + 1] = self.btnMap end
    if F.onMap(row) then acts[#acts + 1] = self.btnLook end
    acts[#acts + 1] = self.btnRename
    if not pending then
        if near then acts[#acts + 1] = self.btnTransfer end
        -- 車不在身邊（客戶端沒載入這台車，F.findLoaded）時是「車已遺失，解除綁定」：等沙盒 ReleaseFinalizeHours 才解除
        -- （期間伺服器看到車就取消），提示寫清楚不會通知管理員
        if not near then self.btnReport:setTooltip(getText("IGUI_MVM_ReportLost_Tip", MVM.sandbox("ReleaseFinalizeHours", 24))) end
        acts[#acts + 1] = near and self.btnUnclaim or self.btnReport
    end
    y = self:flow(acts, y) + PAD
    -- 停車保全：勾＝這台現在有保全（伺服器的列 guard＝ON）；名額不夠的車（OVER）不勾，勾下去＝把名額移到這台。
    -- 保全名額視窗在 Economy 可用時才給
    if MVM.guardModeFor(b) == MVM.GUARD.SLOTS and GUARDABLE[row.state] then
        self.guardBox:setChecked(row.guard == "ON", true)
        local g = { self.guardBox }
        if b.guard and b.guard.economy == "READY" then g[2] = self.btnGuardSlots end
        y = self:flow(g, y) + PAD
    end
    local shares = {}
    local function share(btn, who, bits, tip)
        btn:setTitle(getText("IGUI_MVM_ShareRow", who, F.actionsText(bits)))
        btn:setTooltip(tip)
        shares[#shares + 1] = btn
    end
    if (row.publicBits or 0) > 0 then
        share(self.btnPublicOff, getText("IGUI_MVM_Everyone"), row.publicBits, getText("IGUI_MVM_StopPublic", F.actionsText(row.publicBits)))
    end
    if row.factionShare then
        local who = getText(row.factionState == "SUSPENDED" and "IGUI_MVM_Share_FactionSuspended" or "IGUI_MVM_Share_Faction",
            tostring(row.factionName or "?"))
        share(self.btnFactionOff, who, row.factionActionBits or 0, getText("IGUI_MVM_StopFaction", F.actionsText(row.factionActionBits or 0)))
    end
    for i, g in ipairs(row.grants or {}) do
        local mb = self.memberButtons[i]
        if mb == nil then break end
        mb.internal = g.user
        share(mb, g.user, g.bits, getText("IGUI_MVM_Btn_RemoveMember", g.user, F.actionsText(g.bits)))
    end
    if #shares > 0 then
        y = self:heading("IGUI_MVM_Section_Members", y)
        -- 等寬兩欄（看起來是一張清單，不是長短不一的按鈕）；標題太長時截字，提示文字有全文
        local cols = self.detailW >= 360 and 2 or 1
        local colW = math.floor((self.detailW - 8 - GAP * (cols - 1)) / cols)
        for i, c in ipairs(shares) do
            c:setWidth(colW)
            local col = (i - 1) % cols
            place(c, self.detailX + col * (colW + GAP), y)
            if col == cols - 1 or i == #shares then y = y + c.height + GAP end
        end
        y = y + PAD
    end
    y = self:shareHeading(y)
    y = self:checkGrid(y)
    return self:flow({ self.userEntry, self.btnAddMember, self.btnFaction, self.btnPublic }, y)
end

-- 「新增分享」標題列：右側放「全選／全不選」（全部打開時變全不選），標題與按鈕同一列、不多佔一列；
-- 寬度不夠時標題在上、按鈕另起一列
function FleetWindow:shareHeading(y)
    local all = true
    for _, cb in ipairs(self.checks) do if not cb:getChecked() then all = false end end
    local btn = self.btnCheckAll
    btn:setTitle(getText(all and "IGUI_MVM_Btn_CheckNone" or "IGUI_MVM_Btn_CheckAll"))
    local title = getText("IGUI_MVM_Section_Share")
    local right = self.detailX + self.detailW - 8 -- 右緣留給捲軸
    if self.detailX + measure(title, FS) + GAP * 2 + btn.width > right then
        return self:flow({ btn }, self:headingText(title, y))
    end
    self.headings[#self.headings + 1] = { text = title, y = y + math.floor((self.ch - self.fh) / 2) }
    place(btn, right - btn.width, y)
    return y + self.ch + GAP
end

-- 陣營分享暫停（「我的車」最上面那列）：每台一個勾選（預設全勾，記在 restorePick、跨重排保留）、全選／全不選，
-- 按「恢復 N 台」一次送出（伺服器 restoreFactionShare）。勾選標籤＝車名＋原本給陣營的權限，太長截字
function FleetWindow:layoutRestore(g, y)
    y = self:heading("IGUI_MVM_Section_Restore", y)
    y = self:flow({ self.btnRestoreAll, self.btnRestoreNone }, y)
    local n, labelW = 0, self.detailW - 8 - 44 -- 44＝開關寬 36＋間距 8（Checkbox）
    for i, row in ipairs(g.rows) do
        local cb = self:restoreBox(i)
        if self.restorePick[row.oid] == nil then self.restorePick[row.oid] = true end
        local label = fit(F.displayName(row) .. getText("IGUI_MVM_Sep") .. F.actionsText(row.factionActionBits), labelW)
        cb.internal = row.oid
        cb:setLabel(label)
        cb:setWidth(44 + measure(label, FS))
        cb:setChecked(self.restorePick[row.oid], true)
        place(cb, self.detailX, y)
        y = y + cb.height + GAP
        if self.restorePick[row.oid] then n = n + 1 end
    end
    self.btnRestore:setTitle(getText("IGUI_MVM_Btn_RestoreN", n))
    return self:flow({ self.btnRestore }, y + GAP)
end

-- 恢復清單的第 i 個勾選：用到才建，建好就登記成詳情控制項（隱藏、捲動、鍵盤目標都照其他詳情控制項）
function FleetWindow:restoreBox(i)
    local cb = self.restoreBoxes[i]
    if cb then return cb end
    cb = UI.Checkbox.new({ x = 0, y = 0, label = "", theme = theme, target = self, onChange = FleetWindow.onRestorePick })
    cb:setVisible(false)
    self.body:addChild(cb)
    self.restoreBoxes[i] = cb
    self.detailControls[#self.detailControls + 1] = cb
    self.detailSet[cb] = true
    return cb
end

function FleetWindow:layoutBody(row, b, y)
    if self.tab == "ADMIN" then return self:layoutAdmin(row, b, y) end
    if self.tab == "LOG" then return y end
    if row == nil or row.kind == "FPAUSED_SHARED" then return y end
    if row.kind == "FPAUSE" then return self:layoutRestore(row, y) end
    if row.state == "PENDING_REBIND" then -- MVCK 待轉：車被載入時自動轉正；車找不到（例：拖車裝卸後舊編號消失）時車主可以放棄、釋出名額
        local acts = {}
        if row.lastKnownX then acts[1] = self.btnMap end
        acts[#acts + 1] = self.btnUnclaim
        return self:flow(acts, y)
    elseif row.role ~= "OWNER" then
        local acts = {}
        if row.lastKnownX then acts[#acts + 1] = self.btnMap end
        if F.onMap(row) then acts[#acts + 1] = self.btnLook end
        if row.role == "MEMBER" then acts[#acts + 1] = self.btnLeave end
        return self:flow(acts, y)
    elseif F.isHistory(row) then
        return self:flow({ self.btnDismiss }, y)
    end
    return self:layoutOwner(row, b, y)
end

-- 依選取列與角色排詳情卡與控制項（選取變更、資料變更與每 2 秒走近／離開車輛時重排）。放不下時整段可用滑鼠滾輪捲動
-- （draw 畫捲軸）：捲出可視範圍的按鈕隱藏、輸入框停到畫面外（Focus 只對可見控制項落點），標題不畫
local PARK_X = -100000
function FleetWindow:layoutDetail()
    local row, b = self.current, self:bucket()
    local recovery = b ~= nil and b.status == "RECOVERY_REQUIRED"
    -- 長文字（通知內容、紀錄分頁的說明）依詳情寬度換行
    local card = {}
    for _, l in ipairs(F.cardLines(row, self.tab, b, self.query, getTimestampMs())) do
        if l.wrap then
            local parts = {}
            MVM.BillingUI.wrap(parts, l.text, self.detailW - 24, FS, measure)
            for _, s in ipairs(parts) do card[#card + 1] = { text = s, token = l.token } end
        else
            card[#card + 1] = l
        end
    end
    self.card = card
    local mode = MVM.guardModeFor(b)
    if mode ~= self.disclosureMode then self.disclosureMode, self.disclosure = mode, getText("IGUI_MVM_Disclosure_" .. mode) end
    local h = 20
    for _, l in ipairs(self.card) do h = h + (l.big and fontH(FM) + 4 or self.fh + 2) end
    self.infoH = h
    local top, bottom = self.detailTop + h + PAD, self.listTop + self.listH
    local function run(y)
        for _, c in ipairs(self.detailControls) do c:setVisible(false) end
        self.headings = {}
        return self:layoutBody(row, b, y)
    end
    local endY = run(top)
    local placed = self.placed
    for i = #placed, 1, -1 do placed[i] = nil end
    if endY - GAP > bottom then
        self.scrollMax = endY - GAP - bottom
        self.scroll = math.max(0, math.min(self.scroll or 0, self.scrollMax))
        run(top - self.scroll)
        for _, c in ipairs(self.detailControls) do
            if c:getIsVisible() then
                c.contentX, c.contentY = c:getX(), c:getY() + self.scroll
                -- 閱讀順序（由上而下、同列由左而右）插入；家族禁用 table.sort
                local i = #placed
                while i >= 1 and (placed[i].contentY > c.contentY or (placed[i].contentY == c.contentY and placed[i].contentX > c.contentX)) do
                    placed[i + 1] = placed[i]
                    i = i - 1
                end
                placed[i + 1] = c
                if c:getY() < top or c:getY() + c.height > bottom then
                    if c._entry then
                        if c:isFocused() then c._entry:unfocus() end
                        c:setX(PARK_X)
                    else
                        c:setVisible(false)
                    end
                end
            end
        end
        local kept = {}
        for _, hd in ipairs(self.headings) do if hd.y >= top and hd.y + self.fh <= bottom then kept[#kept + 1] = hd end end
        self.headings = kept
    else
        self.scrollMax, self.scroll = 0, 0
    end
    self:updateEnabled(recovery)
end

-- 把控制項連同它那一列捲進詳情區的可視範圍（contentY＝不捲動時的位置）。高度至少一列（ch）：
-- 管理頁同列標題垂直置中在列高裡，比開關底邊低，只對齊控制項底邊會把標題切掉
function FleetWindow:scrollToControl(c)
    if (self.scrollMax or 0) <= 0 or c.contentY == nil then return end
    local top, bottom = self.detailTop + self.infoH + PAD, self.listTop + self.listH
    local y, s, h = c.contentY - top, self.scroll or 0, math.max(c.height, self.ch)
    if y < s then s = y elseif y + h > s + (bottom - top) then s = y + h - (bottom - top) end
    s = math.max(0, math.min(s, self.scrollMax))
    if s ~= self.scroll then self.scroll = s; self:layoutDetail() end
end

-- 滑鼠把焦點下的控制項捲出可視範圍：焦點改到第一個看得見的詳情按鈕（否則 Focus 判失效、從頭重走）。
-- 輸入框的焦點在內層原生 entry（Focus.focused 回它），改焦點時不選輸入框（會開始打字）
function FleetWindow:keepFocus()
    local Focus = UI.Focus
    local c = Focus and Focus.focused and Focus.focused()
    if c ~= nil and not self.detailSet[c] then c = c.parent end
    if c == nil or not self.detailSet[c] or (c:getIsVisible() and c:getX() ~= PARK_X) then return end
    for _, p in ipairs(self.placed) do
        if p._entry == nil and p:getIsVisible() and Focus.focusControl(p, false) then return end
    end
end

-- 鍵盤／手把目標：不用捲動時就是框架的自動目標；要捲動時，詳情區以外照自動目標，詳情控制項照排版順序全部列出
-- （含捲出範圍的），描述帶 scrollOwner。描述 table 重用（Focus 每幀讀）
function FleetWindow:focusTargets(win)
    local Focus = UI.Focus
    local auto = Focus and Focus.collectTargets(win) or nil
    if auto == nil or (self.scrollMax or 0) <= 0 then return auto end
    local list, pool, n = self.focusList, self.focusPool, 0
    local function slot()
        n = n + 1
        local d = pool[n]
        if d == nil then d = {}; pool[n] = d end
        list[n] = d
        return d
    end
    for _, a in ipairs(auto) do
        local c = a.frame or a.control or (a.controls and a.controls[1])
        if not self.detailSet[c] then
            local d = slot()
            d.kind, d.control, d.controls, d.frame, d.label, d.captionSide, d.scrollOwner =
                a.kind, a.control, a.controls, a.frame, a.label, a.captionSide, nil
        end
    end
    for _, c in ipairs(self.placed) do
        local d = slot()
        if c._entry then
            d.kind, d.control, d.frame, d.scrollOwner = "entry", c._entry, c, c
        else
            d.kind, d.control, d.frame, d.scrollOwner = c._focusKind or "button", c, nil, self.body
        end
        d.controls, d.label, d.captionSide = nil, c._focusLabel, c._focusCaptionSide
    end
    for k = #list, n + 1, -1 do list[k] = nil end
    return list
end

-- 等待 ACK 期間或需要復原時停用所有變更按鈕
function FleetWindow:updateEnabled(recovery)
    local on = self.pending == nil and not recovery
    for _, b in ipairs(self.actionButtons) do b:setEnabled(on) end
end

function FleetWindow:tick()
    local now = getTimestampMs()
    if now - self.lastNearCheck > 2000 then self.lastNearCheck = now; self:layoutDetail() end
    if self.dirty then self:rebuild() end
end

function FleetWindow:draw(el)
    local fh = self.fh
    local b = self:bucket()
    local x, y = self.detailX, self.detailTop
    theme:fill(el, x, y, self.detailW, self.infoH, "well")
    theme:border(el, x, y, self.detailW, self.infoH, "border")
    x, y = x + 12, y + 10
    self.copyHit = nil
    for _, l in ipairs(self.card or {}) do
        local lh = l.big and fontH(FM) + 4 or fh + 2
        if l.copy then -- 座標列：滑鼠移上去反白，後面畫複製圖示，點一下複製（Body:onMouseDown）
            local w = getTextManager():MeasureStringX(FS, l.text) + 4 + fh
            local mx, my = el:getMouseX(), el:getMouseY()
            local over = el:isMouseOver() and mx >= x - 4 and mx < x + w + 4 and my >= y - 1 and my < y + lh
            if over then el:drawRect(x - 4, y - 1, w + 8, lh, COL.hover.a, COL.hover.r, COL.hover.g, COL.hover.b) end
            text(el, l.text, x, y, over and "text" or l.token, FS)
            UI.Icons.draw(el, "copy", x + w - fh, y + 1, fh - 2, over and COL.text or COL.textMuted, 1)
            self.copyHit = { x = x - 4, y = y - 1, w = w + 8, h = lh, value = l.copy }
        else
            text(el, l.text, x, y, l.token, l.big and FM or FS)
        end
        y = y + lh
    end
    for _, h in ipairs(self.headings) do text(el, h.text, self.detailX, h.y, "text") end
    if (self.scrollMax or 0) > 0 then -- 捲軸：提示詳情區下面還有內容（滾輪捲動）
        local top, bottom = self.detailTop + self.infoH + PAD, self.listTop + self.listH
        local vh = bottom - top
        local th = math.max(16, math.floor(vh * vh / (vh + self.scrollMax)))
        local ty = top + math.floor((vh - th) * (self.scroll or 0) / self.scrollMax)
        local tc, tt = COL.hover, COL.textFaint
        el:drawRect(self.detailX + self.detailW - 4, top, 4, vh, tc.a, tc.r, tc.g, tc.b)
        el:drawRect(self.detailX + self.detailW - 4, ty, 4, th, tt.a, tt.r, tt.g, tt.b)
    end
    local fy = el.height - self.footerH
    local bc = COL.border
    el:drawRect(PAD, fy, el.width - PAD * 2, 1, bc.a, bc.r, bc.g, bc.b)
    local q = b and b.quota
    local used, total = MVM.quotaNumbers(b)
    local quota
    if self.tab == "ADMIN" then -- 管理頁顯示全服總數，不顯示管理員自己的名額
        quota = self.totals and getText("IGUI_MVM_Admin_Totals", self.totals.players, self.totals.bound)
    elseif used ~= nil then
        quota = getText("IGUI_MVM_Quota", used, total)
        if q and (q.paid or 0) > 0 then
            -- 大字級左欄放不下分項就只顯示已用／上限（分項在名額視窗），不壓到右側說明
            local paid = getText("IGUI_MVM_QuotaPaid", used, total, q.base or 0, q.paid or 0)
            if getTextManager():MeasureStringX(FS, paid) <= self.detailX - PAD * 2 then quota = paid end
        end
    end
    if quota then text(el, quota, PAD, fy + 6, "text") end
    text(el, self.disclosure, self.detailX, fy + 6, "textMuted")
    if self.pending then
        text(el, getText("IGUI_MVM_Pending"), PAD, fy + 8 + fh, "textMuted")
    elseif b and b.status == "RECOVERY_REQUIRED" then
        text(el, getText("IGUI_MVM_Recovery"), PAD, fy + 8 + fh, "errorText")
    elseif self.message then
        text(el, self.message, PAD, fy + 8 + fh, self.messageBad and "errorText" or "text")
    end
    if MVM.clientOverride(0) then text(el, self.overrideActive, self.detailX, fy + 8 + fh, "errorText") end
end

-- ------------------------------------------------------------------ 操作 ---
function FleetWindow:say(key, bad)
    self.message, self.messageBad = getText(key), bad ~= false
end

-- okText(ack)：成功時的訊息（省略＝「完成」）
function FleetWindow:send(command, args, okText)
    if self.pending then return end
    self.pending = command
    self.message = nil
    self:updateEnabled(false)
    C.request(getSpecificPlayer(0), command, args, function(ack)
        self.pending = nil
        self.message = ack.ok and (okText and okText(ack) or getText("IGUI_MVM_Done")) or MVM.reasonText(ack.reason)
        self.messageBad = not ack.ok
        self.dirty = true
    end)
end

-- 確認框：框架 Dialog（模態、只回呼一次）；self.modal 留給 E2E 以 UI.Dialog.close 按確認。arg 可以是兩個參數的 table。
-- opts.ok＝確認鈕的文字鍵（寫出會發生什麼，opts.okArg＝它的參數）；opts.danger＝破壞性動作（紅色）；
-- opts.input＝輸入框 { text, placeholder }，確認時 fn(self, 輸入文字)
function FleetWindow:confirm(textKey, arg, fn, opts)
    opts = opts or {}
    local body = type(arg) == "table" and getText(textKey, arg[1], arg[2]) or getText(textKey, arg)
    self.modal = UI.Dialog.show({ title = getText("IGUI_MVM_FleetTitle"), text = body, theme = theme, input = opts.input,
        confirmText = getText(opts.ok or "UI_Ok", opts.okArg), cancelText = getText("UI_Cancel"), danger = opts.danger == true,
        onResult = function(ok, input) self.modal = nil; if ok then fn(self, input) end end })
end

function FleetWindow:onTab(id)
    self.tab = id
    self.selectedOid, self.current, self.scroll = nil, nil, 0
    self.dirty = true
    if id == "ADMIN" then C.request(getSpecificPlayer(0), "adminList", {}) end
    if id == "LOG" then
        local b = self:bucket()
        self.logReadAt = b and b.noticeRead or 0
    end
end

function FleetWindow:checkedBits()
    local list = {}
    for _, cb in ipairs(self.checks) do if cb:getChecked() then list[#list + 1] = cb.internal end end
    return F.listToBits(list)
end

-- 改名：對話框裡改（清空＝恢復原始車名）
function FleetWindow:onRename()
    local row = self.current; if not row then return end
    self:confirm("IGUI_MVM_RenamePrompt", F.modelName(row), function(w, name)
        w:send("rename", { expectedOid = row.oid, expectedEpoch = row.epoch, name = name or "" })
    end, { ok = "IGUI_MVM_Btn_Rename", input = { text = row.name or "", placeholder = F.modelName(row) } })
end

-- 分享送出成功就清空權限開關（和帳號欄）：它們是「這次要給的權限」，留著會被當成這台車現在的分享
function FleetWindow:sendShare(command, args)
    self:send(command, args, function()
        for _, cb in ipairs(self.checks) do cb:setChecked(false, true) end
        if command == "addMember" then self.userEntry:setText("") end
        return getText("IGUI_MVM_Done")
    end)
end

function FleetWindow:onAddMember()
    local row = self.current; if not row then return end
    local user, bits = self.userEntry:getText() or "", self:checkedBits()
    if user == "" or bits == 0 then return self:say("IGUI_MVM_NeedUserAndActions") end
    self:sendShare("addMember", { expectedOid = row.oid, username = user, actionBits = bits })
end

-- 陣營：開啟用勾選的權限；已開時再按＝改成勾選的權限
function FleetWindow:onFaction()
    local row = self.current; if not row then return end
    local bits = self:checkedBits()
    if bits == 0 then return self:say("IGUI_MVM_NeedActions") end
    self:sendShare("setFactionShare", { expectedOid = row.oid, expectedEpoch = row.epoch, enabled = true, actionBits = bits })
end

function FleetWindow:onFactionOff()
    local row = self.current; if not row then return end
    self:send("setFactionShare", { expectedOid = row.oid, expectedEpoch = row.epoch, enabled = false, actionBits = 0 })
end

-- 權限開關切換：重排（標題列的全選／全不選跟著變）
function FleetWindow:onShareCheck() self:layoutDetail() end

-- 全選／全不選：全部打開時按＝全部關掉，否則全部打開（含拆零件、拖曳、查看位置；公開給所有人時仍只帶允許公開的）
function FleetWindow:onCheckAll()
    local all = true
    for _, cb in ipairs(self.checks) do if not cb:getChecked() then all = false end end
    for _, cb in ipairs(self.checks) do cb:setChecked(not all, true) end
    self:layoutDetail()
end

-- 恢復清單的勾選：記在 restorePick（oid → 是否恢復），重排更新「恢復 N 台」
function FleetWindow:onRestorePick(checked, box)
    if box and box.internal then self.restorePick[box.internal] = checked == true end
    self:layoutDetail()
end

function FleetWindow:pickRestore(value)
    local g = self.current; if not (g and g.kind == "FPAUSE") then return end
    for _, row in ipairs(g.rows) do self.restorePick[row.oid] = value end
    self:layoutDetail()
end

function FleetWindow:onRestoreAll() self:pickRestore(true) end
function FleetWindow:onRestoreNone() self:pickRestore(false) end

-- 一次恢復勾選的車（伺服器逐台再驗：自己的、仍在同名陣營）；成功跳通知，有沒恢復的寫出台數與第一個原因。
-- 恢復過後剩下還暫停的車回到預設全勾（下次打開不是「恢復 0 台」）
function FleetWindow:onRestore()
    local g = self.current; if not (g and g.kind == "FPAUSE") then return end
    local oids = {}
    for _, row in ipairs(g.rows) do if self.restorePick[row.oid] then oids[#oids + 1] = row.oid end end
    if #oids == 0 then return self:say("IGUI_MVM_Restore_PickOne") end
    self:send("restoreFactionShare", { oids = oids }, function(ack)
        if ack.ok then self.restorePick = {} end
        local failed = ack.failed or 0
        local text = failed > 0 and getText("IGUI_MVM_Restore_Partial", ack.restored or 0, failed, MVM.reasonText(ack.failReason))
            or getText("IGUI_MVM_Restore_Done", ack.restored or 0)
        MVM.notify(getSpecificPlayer(0), text, failed > 0)
        return text
    end)
end

-- 公開給所有人：只帶得了公開允許的動作；先確認（陌生人也能用）
function FleetWindow:onPublic()
    local row = self.current; if not row then return end
    local bits = F.publicBits(self:checkedBits())
    if bits == 0 then return self:say("IGUI_MVM_NeedPublicActions") end
    self:confirm("IGUI_MVM_ConfirmPublic", F.actionsText(bits), function(w)
        w:sendShare("setPublicShare", { expectedOid = row.oid, expectedEpoch = row.epoch, actionBits = bits })
    end, { ok = "IGUI_MVM_Btn_PublicOn" })
end

function FleetWindow:onPublicOff()
    local row = self.current; if not row then return end
    self:send("setPublicShare", { expectedOid = row.oid, expectedEpoch = row.epoch, actionBits = 0 })
end

function FleetWindow:onRemoveMember(button)
    local row = self.current; if not row then return end
    local user = button.internal
    self:send("removeMember", { expectedOid = row.oid, username = user }, function() return getText("IGUI_MVM_MemberRemoved", user) end)
end

-- 轉讓：對話框裡輸入對方帳號（車要在身邊）
function FleetWindow:onTransfer()
    local row = self.current; if not row then return end
    local v = F.findLoaded(row)
    if v == nil then return self:say("IGUI_MVM_Reason_TOO_FAR") end
    self:confirm("IGUI_MVM_ConfirmTransfer", F.displayName(row), function(w, user)
        if user == nil or user == "" then return w:say("IGUI_MVM_NeedUser") end
        w:send("transfer", { vehicleId = v:getId(), expectedOid = row.oid, expectedEpoch = row.epoch, recipient = user })
    end, { ok = "IGUI_MVM_Btn_Transfer", danger = true, input = { placeholder = getText("IGUI_MVM_UserHint") } })
end

function FleetWindow:onUnclaim()
    local row = self.current; if not row then return end
    if row.state == "PENDING_REBIND" then
        return self:confirm("IGUI_MVM_ConfirmCancelRebind", F.displayName(row), function(w)
            w:send("cancelRebind", { expectedOid = row.oid })
        end, { ok = "IGUI_MVM_Btn_Unclaim", danger = true })
    end
    local v = F.findLoaded(row)
    if v == nil then return self:say("IGUI_MVM_Reason_TOO_FAR") end
    self:confirm("IGUI_MVM_ConfirmUnclaim", F.displayName(row), function(w)
        w:send("unclaim", { vehicleId = v:getId(), expectedOid = row.oid, expectedEpoch = row.epoch })
    end, { ok = "IGUI_MVM_Btn_Unclaim", danger = true })
end

function FleetWindow:onReportLost()
    local row = self.current; if not row then return end
    self:confirm("IGUI_MVM_ConfirmReportLost", { F.displayName(row), MVM.sandbox("ReleaseFinalizeHours", 24) },
        function(w) w:send("reportLost", { expectedOid = row.oid }) end, { ok = "IGUI_MVM_Btn_ReportLost", danger = true })
end

function FleetWindow:onCancelRelease()
    local row = self.current; if not row then return end
    self:send("cancelRelease", { expectedOid = row.oid })
end

function FleetWindow:onReissue()
    local row = self.current; if not row then return end
    local v = F.findLoaded(row)
    if v == nil then return self:say("IGUI_MVM_Reason_TOO_FAR") end
    self:send("reissueWitness", { vehicleId = v:getId(), expectedOid = row.oid })
end

function FleetWindow:onDismiss()
    local row = self.current; if not row then return end
    self:confirm("IGUI_MVM_ConfirmDismiss", F.displayName(row), function(w) w:send("dismissRecord", { expectedOid = row.oid }) end,
        { ok = "IGUI_MVM_Btn_Dismiss", danger = true })
end

function FleetWindow:onLeave()
    local row = self.current; if not row then return end
    self:confirm("IGUI_MVM_ConfirmLeave", F.displayName(row), function(w) w:send("leaveShared", { expectedOid = row.oid }) end,
        { ok = "IGUI_MVM_Btn_Leave", danger = true })
end

function FleetWindow:onMap()
    local row = self.current; if not row or not row.lastKnownX then return end
    if ISWorldMap.IsAllowed() then ISWorldMap.ShowWorldMap(0, row.lastKnownX, row.lastKnownY, 20) end
end

-- 管理員：傳送到這台車最後出現（或 MVCK 匯入時）的位置；原版管理員傳送指令，權限由伺服器判定
function FleetWindow:onTeleport()
    local row = self.current; if not (row and row.lastKnownX) then return end
    SendCommandToServer("/teleportto " .. math.floor(row.lastKnownX) .. "," .. math.floor(row.lastKnownY) .. ","
        .. math.floor(row.lastKnownZ or 0))
end

function FleetWindow:copyCoords(value)
    if Clipboard and Clipboard.setClipboard and pcall(Clipboard.setClipboard, value) then
        self.message, self.messageBad = getText("IGUI_MVM_CoordsCopied", value), false
    end
end

-- 越權開關：送出後以 server ACK／adminSnapshot 為準（layoutDetail 依 bucket 重設勾選狀態）
function FleetWindow:onOverride(checked)
    self:send("setAdminOverride", { enabled = checked == true }, function(ack)
        return getText(ack.enabled and "IGUI_MVM_Override_OnToast" or "IGUI_MVM_Override_OffToast")
    end)
end

-- 管理操作後重抓總表：同一連線依序處理，快照一定反映這次變更
function FleetWindow:adminSend(command, args, okText)
    self:send(command, args, okText)
    C.request(getSpecificPlayer(0), "adminList", {})
end

function FleetWindow:onAdminRelease()
    local row = self.current; if not row or row.kind == "PLAYER" then return end
    self:confirm("IGUI_MVM_ConfirmAdminRelease", row.owner or getText("IGUI_MVM_Admin_NoOwner"), function(w)
        w:adminSend("adminRecover", { expectedOid = row.oid, op = "RELEASE" })
    end, { ok = "IGUI_MVM_Btn_AdminRelease", danger = true })
end

-- 名額欄的整數；超出範圍或不是整數回 nil
local function wholeIn(field, lo, hi)
    local n = tonumber(field:getText() or "")
    if n == nil or n < lo or n > hi or n ~= math.floor(n) then return nil end
    return n
end

-- 基本名額（上限＝基本＋付費）；伺服器只收 0–100 的整數，-1＝恢復伺服器預設
function FleetWindow:onQuota()
    local row = self.current; if not (row and row.kind == "PLAYER" and row.info) then return end
    local n = wholeIn(self.quotaEntry, 0, 100)
    if n == nil then return self:say("IGUI_MVM_NeedQuotaRange") end
    self:adminSend("adminSetQuota", { usernames = { row.user }, amount = n })
end

function FleetWindow:onQuotaDefault()
    local row = self.current; if not (row and row.kind == "PLAYER" and row.info) then return end
    self:adminSend("adminSetQuota", { usernames = { row.user }, amount = -1 })
end

-- 批次選取變了：清單勾選框每幀讀 picked，詳情區的已選人數與按鈕要重排
function FleetWindow:togglePick(row)
    if not F.togglePick(self.picked, row) then return false end
    self:layoutDetail()
    return true
end

function FleetWindow:onPick() self:togglePick(self.current) end
function FleetWindow:onPickShown() F.pickShown(self.picked, self.list:getItems()); self:layoutDetail() end
function FleetWindow:onPickClear() F.clearPicks(self.picked); self:layoutDetail() end

-- 送出前確認；超過一次上限就請管理員改用全服預設名額
function FleetWindow:batch(amount, textKey)
    local users = F.pickedList(self.picked)
    if #users == 0 then return end
    if #users > F.BATCH_MAX then
        self.message, self.messageBad = getText("IGUI_MVM_BatchTooMany", F.BATCH_MAX), true
        return
    end
    self:confirm(textKey, { #users, amount }, function(w)
        w:adminSend("adminSetQuota", { usernames = users, amount = amount }, function(ack)
            return getText("IGUI_MVM_BatchDone", ack.count or #users)
        end)
    end, { ok = "IGUI_MVM_Btn_Apply" })
end

function FleetWindow:onBatchQuota()
    local n = wholeIn(self.batchEntry, 0, 100)
    if n == nil then return self:say("IGUI_MVM_NeedQuotaRange") end
    self:batch(n, "IGUI_MVM_ConfirmBatchQuota")
end

function FleetWindow:onBatchDefault() self:batch(-1, "IGUI_MVM_ConfirmBatchReset") end

-- 全服預設名額＝沙盒 ClaimsPerPlayer（0–20）；伺服器存檔成功才回 ok
function FleetWindow:onDefaultQuota()
    local n = wholeIn(self.defaultEntry, 0, 20)
    if n == nil then return self:say("IGUI_MVM_NeedDefaultRange") end
    self:adminSend("adminSetDefaultQuota", { amount = n }, function(ack) return getText("IGUI_MVM_DefaultQuotaSaved", ack.amount) end)
end

-- 閒置解除天數＝沙盒 InactivityReleaseDays（0–365，0＝不解除）；伺服器存檔成功才回 ok
function FleetWindow:onReleaseDays()
    local n = wholeIn(self.releaseEntry, 0, 365)
    if n == nil then return self:say("IGUI_MVM_NeedReleaseRange") end
    self:adminSend("adminSetReleaseDays", { amount = n }, function(ack) return getText("IGUI_MVM_ReleaseDaysSaved", ack.amount) end)
end

-- 停車保全模式＝沙盒 ParkedGuard（1 關、2 全部綁定的車、3 依保全名額）：按亮著的那顆不動；換模式先確認，
-- 關閉是破壞性的（所有車又會被武器打壞）。伺服器存檔成功才回 ok
function FleetWindow:onGuardMode(button)
    local b = self:bucket()
    local n, cur = button.internal, b and b.adminGuardMode or MVM.guardModeFor(b)
    if n == cur then return end
    local slots = n == MVM.GUARD.SLOTS and (b and b.adminGuardSlots or MVM.guardSlotsDefault()) or nil
    self:confirm("IGUI_MVM_ConfirmGuardMode_" .. n, slots, function(w)
        w:adminSend("adminSetGuardMode", { mode = n }, function(ack)
            return getText("IGUI_MVM_GuardModeSaved", getText("IGUI_MVM_GuardMode_" .. tostring(ack.mode or n)))
        end)
    end, { ok = "IGUI_MVM_Btn_SetGuardMode", okArg = getText("IGUI_MVM_GuardMode_" .. n), danger = n == MVM.GUARD.OFF })
end

-- 每位玩家的免費保全名額＝沙盒 GuardSlotsPerPlayer（0–20）；伺服器存檔成功才回 ok
function FleetWindow:onGuardSlotsDefault()
    local n = wholeIn(self.guardSlotsEntry, 0, 20)
    if n == nil then return self:say("IGUI_MVM_NeedDefaultRange") end
    self:adminSend("adminSetGuardSlots", { amount = n }, function(ack) return getText("IGUI_MVM_GuardSlotsSaved", ack.amount) end)
end

-- 單一玩家的保全名額（0–100），-1＝恢復伺服器預設
function FleetWindow:onGuardQuota()
    local row = self.current; if not (row and row.kind == "PLAYER" and row.info) then return end
    local n = wholeIn(self.guardQuotaEntry, 0, 100)
    if n == nil then return self:say("IGUI_MVM_NeedQuotaRange") end
    self:adminSend("adminSetGuardQuota", { usernames = { row.user }, amount = n })
end

function FleetWindow:onGuardQuotaDefault()
    local row = self.current; if not (row and row.kind == "PLAYER" and row.info) then return end
    self:adminSend("adminSetGuardQuota", { usernames = { row.user }, amount = -1 })
end

-- 車主的停車保全開關：送出後以 ACK 與重送的快照為準（layoutOwner 依列的 guard 重設勾選；名額滿等失敗時跳回）
function FleetWindow:onGuard(checked)
    local row = self.current; if not row then return end
    self:send("setGuard", { expectedOid = row.oid, enabled = checked == true }, function(ack)
        return getText(ack.enabled and "IGUI_MVM_Guard_Enabled" or "IGUI_MVM_Guard_Disabled")
    end)
end

function FleetWindow:onImportMVCK()
    self:confirm("IGUI_MVM_ConfirmImportMVCK", nil, function(w)
        w:adminSend("adminMigration", { op = "IMPORT" }, function(ack)
            return getText("IGUI_MVM_MVCKImported", ack.imported or 0, ack.rebound or 0, ack.pending or 0)
        end)
    end, { ok = "IGUI_MVM_Btn_Import" })
end

-- 身分匯入：向伺服器要帳號清單（requestUsers 需 SeeNetworkUsers：RequestNetworkUsersPacket.java:15；沒有能力送出，
-- 伺服器會記成越權封包：PacketTypes.java:300-312，所以先在本機擋），收到後只取 isInWhitelist 的帳號。不在 whitelist 的列是在線的
-- 分割畫面／改名名字，封包配的是該連線的 SteamID（NetworkUsersPacket.java:35-47）。原版管理面板同樣讀 getUsers（ISUsersList.lua:156,268,376）
local USERS_WAIT_MS = 30000
function FleetWindow:onImportIdentity()
    local p = getSpecificPlayer(0)
    local role = p and p:getRole()
    if not (role and role:hasCapability(Capability.SeeNetworkUsers)) then return self:say("IGUI_MVM_IdentityNeedUsers") end
    self:confirm("IGUI_MVM_ConfirmImportIdentity", nil, function(w)
        w.wantUsersAt = getTimestampMs()
        requestUsers()
    end, { ok = "IGUI_MVM_Btn_Import" })
end

-- 事件是全域的（原版管理面板也會要清單）：只接自己 30 秒內要的那一次
local function onUsersReceived()
    local w = FleetWindow.instance
    if w == nil or w.wantUsersAt == nil then return end
    local asked = w.wantUsersAt
    w.wantUsersAt = nil
    if getTimestampMs() - asked > USERS_WAIT_MS then return end
    local rows, users = {}, getUsers()
    for i = 0, users:size() - 1 do
        local u = users:get(i)
        if u:isInWhitelist() then
            local sid = u:getSteamid()
            if type(sid) ~= "string" or sid:match("^7656119%d%d%d%d%d%d%d%d%d%d$") == nil then sid = "" end
            rows[#rows + 1] = { u = u:getUsername(), s = sid }
        end
    end
    w:adminSend("adminIdentity", { op = "IMPORT", rows = rows }, function(ack)
        return getText("IGUI_MVM_IdentityImported", ack.bound or 0, ack.conflicts or 0, ack.reserved or 0, ack.missing or 0)
    end)
end
Events.OnNetworkUsersReceived.Add(onUsersReceived)

-- 衝突改綁：確認框列出前 10 個帳號
function FleetWindow:onRebindIdentity()
    local b = self:bucket()
    local names = b and b.identityConflicts or {}
    if #names == 0 then return end
    local shown = {}
    for i = 1, math.min(#names, 10) do shown[i] = names[i] end
    local list = table.concat(shown, ", ") .. (#names > 10 and ", ..." or "")
    self:confirm("IGUI_MVM_ConfirmRebindIdentity", { #names, list }, function(w)
        w:adminSend("adminIdentity", { op = "REBIND" }, function(ack) return getText("IGUI_MVM_IdentityRebound", ack.rebound or 0) end)
    end, { ok = "IGUI_MVM_Btn_Rebind", danger = true })
end

function FleetWindow:onSlots()
    if MVM.BillingWindow then MVM.BillingWindow.open() else self:say("IGUI_MVM_NeedFramework") end
end

function FleetWindow:onGuardSlots()
    if MVM.BillingWindow then MVM.BillingWindow.open(MVM.GUARD_PRODUCT) else self:say("IGUI_MVM_NeedFramework") end
end

function FleetWindow:onPaidSlots()
    if MVM.PaidSlotsWindow then MVM.PaidSlotsWindow.open(self.win, MVM.ECON_PRODUCT) else self:say("IGUI_MVM_NeedFramework") end
end

function FleetWindow:onPaidGuard()
    if MVM.PaidSlotsWindow then MVM.PaidSlotsWindow.open(self.win, MVM.GUARD_PRODUCT) else self:say("IGUI_MVM_NeedFramework") end
end

-- -------------------------------------------------------------- 外觀視窗 ---
-- 每台車在地圖上的圖示、顏色與大小，只存在本機（MVM.Appearance）。車型圖示、色盤與滑桿需要框架 rev 9
local BADGE = { r = 0.06, g = 0.06, b = 0.07, a = 0.92 }
local LookBody = ISPanel:derive("MVMLookBody")

-- 預覽：和地圖標記同一個構圖（彩色外環＋深色圓底＋彩色圖示＋同色名稱）
function LookBody:render()
    local L = self.look
    local c = L.color
    -- 預覽依所選大小縮放（最大 2.5 倍時剛好填滿預覽區）
    local k = MVM.Appearance.scale(L.size) / 2.5
    local cx, cy = PAD + 30, PAD + 30
    local ring, badge, icon = math.floor(56 * k), math.floor(50 * k), math.floor(34 * k)
    UI.Skin.dot(self, cx - math.floor(ring / 2), cy - math.floor(ring / 2), ring, c)
    UI.Skin.dot(self, cx - math.floor(badge / 2), cy - math.floor(badge / 2), badge, BADGE)
    UI.Icons.draw(self, L.icon, cx - math.floor(icon / 2), cy - math.floor(icon / 2), icon, c, 1)
    self:drawText(L.label, cx + 42, cy - math.floor(fontH(FM) / 2), c.r, c.g, c.b, 1, FM)
    for _, h in ipairs(L.headings) do text(self, h.text, PAD, h.y, "textMuted") end
end

local Look = {}
FleetWindow.Look = Look -- E2E 走同一條 pick／apply 路徑

-- 圖示格：框架按鈕的圖示跟字高一樣小，車型側視圖要 20px 以上才分得清，所以自繪 28px
local IconCell = ISPanel:derive("MVMLookIconCell")
function IconCell:prerender()
    local L = self.look
    if L.icon == self.internal then
        theme:fill(self, 0, 0, self.width, self.height, "selected")
        theme:border(self, 0, 0, self.width, self.height, "accent")
    elseif self:isMouseOver() then
        theme:fill(self, 0, 0, self.width, self.height, "hover")
    end
    local s = self.width - 12
    UI.Icons.draw(self, self.internal, 6, 6, s, L.icon == self.internal and L.color or COL.text, 1)
end
function IconCell:onMouseUp() Look.pick(self.look, self); return true end
function IconCell:onMouseDown() return true end
-- 鍵盤 Enter／手把 A（框架 Focus 的 activate）：與點擊同一條路徑
function IconCell:forceClick() Look.pick(self.look, self) end

function Look.pick(L, cell) L.icon = cell.internal end

function Look.apply(L) MVM.Appearance.set(L.oid, L.color, L.icon, L.size); L.fleet.dirty = true; L.win:close() end
function Look.reset(L) MVM.Appearance.reset(L.oid); L.fleet.dirty = true; L.win:close() end
function Look.cancel(L) L.win:close() end

function Look.open(fleet, row)
    local color, icon, _, size = MVM.Appearance.get(row)
    local L = { fleet = fleet, oid = row.oid, icon = icon, size = size, label = F.displayName(row), headings = {},
        color = { r = color.r, g = color.g, b = color.b }, iconButtons = {} }
    local W = 460
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local win = UI.Window.new({ x = math.floor((sw - W) / 2), y = math.floor(sh / 2 - 260), width = W, height = 520,
        title = getText("IGUI_MVM_AppearanceTitle", L.label), icon = "sliders", theme = theme,
        onClose = function(w)
            if fleet.look == L then fleet.look = nil end
            w:removeFromUIManager()
        end })
    L.win = win
    local top = win:contentTop()
    local body = LookBody:new(0, top, W, 400)
    body.background = false
    body.look = L
    body:initialise()
    win:addChild(body)
    local fh, ch = fontH(FS), fontH(FS) + 10
    local y = PAD + 60 + PAD
    L.headings[1] = { text = getText("IGUI_MVM_Section_Icon"), y = y }
    y = y + fh + 4
    local cell = 44
    local perRow = math.floor((W - PAD * 2 + GAP) / (cell + GAP))
    for i, key in ipairs(MVM.Appearance.ICONS) do
        local col, line = (i - 1) % perRow, math.floor((i - 1) / perRow)
        local b = IconCell:new(PAD + col * (cell + GAP), y + line * (cell + GAP), cell, cell)
        b.background = false
        -- 框架 Focus 的一組目標：方向鍵在圖示之間走、Enter／A 選取
        b.internal, b.look, b._focusKind, b._focusGroup = key, L, "button", "icons"
        b:initialise()
        body:addChild(b)
        L.iconButtons[i] = b
    end
    y = y + math.ceil(#MVM.Appearance.ICONS / perRow) * (cell + GAP) + GAP
    L.headings[2] = { text = getText("IGUI_MVM_Section_Size"), y = y }
    y = y + fh + 4
    local AP = MVM.Appearance
    L.sizeSlider = UI.Slider.new({ x = PAD, y = y, width = W - PAD * 2, min = AP.SIZE_MIN, max = AP.SIZE_MAX, step = AP.SIZE_STEP,
        value = L.size, theme = theme, target = L, onChange = function(t, v) t.size = v end,
        format = function(v) return math.floor(v + 0.5) .. "%" end })
    body:addChild(L.sizeSlider)
    y = y + L.sizeSlider:getHeight() + GAP
    L.headings[3] = { text = getText("IGUI_MVM_Section_Color"), y = y }
    y = y + fh + 4
    local picker = UI.ColorPicker.new({ x = PAD, y = y, width = W - PAD * 2, color = L.color, theme = theme, target = L,
        onChange = function(t, c) t.color = c end })
    body:addChild(picker)
    L.picker = picker
    y = y + picker:getHeight() + PAD
    local x = W - PAD
    for _, spec in ipairs({ { "UI_Cancel", Look.cancel, "normal" }, { "IGUI_MVM_Btn_ResetLook", Look.reset, "normal" },
        { "IGUI_MVM_Btn_Apply", Look.apply, "primary" } }) do
        local b = UI.Button.new({ x = 0, y = y, height = ch, title = getText(spec[1]), style = spec[3], theme = theme,
            target = L, onClick = spec[2] })
        x = x - b.width
        b:setX(x)
        x = x - GAP
        body:addChild(b)
    end
    y = y + ch + PAD
    body:setHeight(y)
    win:setHeight(top + y)
    win:addToUIManager()
    win:bringToTop()
    return L
end

function FleetWindow:onAppearance()
    local row = self.current; if not row then return end
    if not (UI.API_REVISION >= 9 and CAPS.colorPicker and CAPS.slider) then return self:say("IGUI_MVM_NeedFramework") end
    if self.look then self.look.win:close() end
    self.look = Look.open(self, row)
end

-- ------------------------------------------------------------ 陣營轉讓 ---
-- 原版陣營視窗「更改擁有者」（ISFactionAddPlayerUI changeOwnership 的確認鈕 → onClick → sendFactionChangeOwner，
-- ISFactionAddPlayerUI.lua:115-135）：有陣營分享的車時先提醒「轉讓後會暫停幾台、車主要恢復」。只是提醒——按轉讓照原版送出，
-- 伺服器照常暫停；取消就留在原版視窗。ISButton 建立面板時才存 onClick 參照，所以換掉類別方法即可。原版檔依路徑排序可能比本檔晚載入，
-- 進遊戲時再試一次（Client.lua 的 OnGameStart 呼叫 MVM.installTransferWarn）；每個類別只包一次（Lua 重載也是）
local function installTransferWarn()
    if ISFactionAddPlayerUI == nil or rawget(ISFactionAddPlayerUI, "_mvmTransferWarn") then return end
    local vanillaClick = ISFactionAddPlayerUI.onClick
    rawset(ISFactionAddPlayerUI, "_mvmTransferWarn", true)
    function ISFactionAddPlayerUI:onClick(button)
        local target = self.selectedPlayer
        if button and button.internal == "ADDPLAYER" and self.changeOwnership and self.faction and target then
            local p = getSpecificPlayer(0)
            local n = F.factionShareCount(p and C.buckets[p:getUsername()])
            if n > 0 then
                -- F.transferModal／transferText 留給 E2E（同 FleetWindow:confirm 的 self.modal）
                local panel, text = self, getText("IGUI_MVM_FactionTransfer_Warn", self.faction:getName(), target, n)
                F.transferText = text
                F.transferModal = UI.Dialog.show({ title = getText("IGUI_SafehouseUI_ChangeOwnership"), theme = theme, text = text,
                    confirmText = getText("IGUI_MVM_Btn_TransferFaction", target), cancelText = getText("UI_Cancel"),
                    onResult = function(ok)
                        F.transferModal = nil
                        if ok and panel.selectedPlayer == target then vanillaClick(panel, button) end
                    end })
                return
            end
        end
        return vanillaClick(self, button)
    end
end
MVM.installTransferWarn = installTransferWarn
installTransferWarn()

-- ------------------------------------------------------------------ 入口 ---
function FleetWindow.ensure()
    if FleetWindow.instance == nil then
        local f = FleetWindow.new()
        f.win:addToUIManager()
        f.win:setVisible(false)
        ISLayoutManager.RegisterWindow(LAYOUT, f.win, f.win) -- Window 自帶 SaveLayout／RestoreLayout
        FleetWindow.instance = f
    end
    return FleetWindow.instance
end

function FleetWindow.toggle()
    local f = FleetWindow.ensure()
    local show = not f.win:getIsVisible()
    f.win:setVisible(show)
    if show then
        f.win:bringToTop()
        f.dirty = true
        local p = getSpecificPlayer(0)
        if p then
            C.request(p, "fleetResync", {})
            C.request(p, "adminList", {}) -- 只有管理員會收到資料；其他人收到空結果，不顯示管理頁
        end
    end
end

MVM.onFleetChanged = function(to)
    local f = FleetWindow.instance
    if f and to == f:who() then f.dirty = true end
end

-- 車外右鍵「車輛管理」子選單加「開啟車隊」
MVM.clientMenuHooks = MVM.clientMenuHooks or {}
table.insert(MVM.clientMenuHooks, 1, function(player, sub)
    sub:addOption(getText("ContextMenu_MVM_OpenFleet"), nil, FleetWindow.toggle)
end)

-- 浮鈕：右緣，避開 MiniMap（0.35H）、公告（0.5H）、經濟（0.5H+40）
local FLOAT_SIZE = 40
local function floatDefault() return getCore():getScreenWidth() - FLOAT_SIZE - 8, math.floor(getCore():getScreenHeight() / 2 + 100) end
local FloatLayout = {}
function FloatLayout.SaveLayout(btn, name, layout)
    layout.x, layout.y = tostring(btn:getX()), tostring(btn:getY())
end
function FloatLayout.RestoreLayout(btn, name, layout)
    local x, y = tonumber(layout.x), tonumber(layout.y)
    if x and y then btn:setPosition(x, y) end
end

local function createFloat()
    if F.float then return end
    local x, y = floatDefault()
    local fallback = getText("IGUI_MVM_FloatFallback") -- 圖示載入失敗時畫的一個字（建立時取一次，不每幀查譯文）
    F.float = UI.FloatButton.new({
        size = FLOAT_SIZE, alwaysOnTop = false, x = x, y = y,
        colors = { surface = COL.surface, hover = COL.hover, border = COL.border },
        drawContent = function(btn)
            -- 越權中：圖示與外框改紅色，常駐提醒
            local on = MVM.clientOverride(0)
            local c = on and COL.errorText or COL.text
            if not UI.Icons.draw(btn, "steeringwheel", 6, 6, FLOAT_SIZE - 12, c, 1) then
                btn:drawTextCentre(fallback, FLOAT_SIZE / 2, FLOAT_SIZE / 2 - 8, c.r, c.g, c.b, 1, UIFont.Medium)
            end
            if on then
                btn:drawRectBorder(0, 0, FLOAT_SIZE, FLOAT_SIZE, 1, c.r, c.g, c.b)
                btn:drawRectBorder(1, 1, FLOAT_SIZE - 2, FLOAT_SIZE - 2, 1, c.r, c.g, c.b)
            end
        end,
        onClick = function() FleetWindow.toggle() end,
        onMoved = function() ISLayoutManager.OnPostSave() end,
        getTooltip = function()
            if MVM.clientOverride(0) then return getText("IGUI_MVM_FleetTitle") .. " <LINE> " .. getText("IGUI_MVM_Override_Active") end
            return getText("IGUI_MVM_FleetTitle")
        end,
    })
    ISLayoutManager.RegisterWindow("MinidoracatVehicleManagerFloat", FloatLayout, F.float)
end

-- 家族工具列（框架 rev 13 Dock）：登記成功就不建浮鈕；舊框架或登記失敗照舊用浮鈕。回呼每幀可能被呼叫，不建 table
local docked = CAPS.dock and UI.Dock and UI.Dock.register({
    id = "vehiclemanager", order = 40, iconKey = "steeringwheel",
    label = function() return getText("IGUI_MVM_FleetTitle") end,
    onClick = FleetWindow.toggle,
    isActive = function() local f = FleetWindow.instance; return f ~= nil and f.win:getIsVisible() end,
    getState = function() if MVM.clientOverride(0) then return "warn" end end, -- 越權中：紅框常駐提醒
    getBadge = function() return MVM.noticeUnreadLocal() end, -- 離線時收到、還沒在「紀錄」分頁看過的通知
    getStatus = function() if MVM.clientOverride(0) then return getText("IGUI_MVM_Override_Active") end end,
})
if not docked then
    Events.OnGameStart.Add(createFloat)
    Events.OnResolutionChange.Add(function()
        if F.float then
            F.float:setPosition(floatDefault())
            ISLayoutManager.TryRestore("MinidoracatVehicleManagerFloat")
        end
    end)
end
