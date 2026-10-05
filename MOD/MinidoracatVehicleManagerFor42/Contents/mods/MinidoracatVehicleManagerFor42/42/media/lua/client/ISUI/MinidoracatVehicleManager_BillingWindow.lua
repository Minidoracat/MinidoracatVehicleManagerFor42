-- 綁定名額視窗（車隊視窗「名額」按鈕開啟）：最上面是能綁幾台，下面是買斷／租用兩顆主按鈕與「我的租約」
-- （每張租約一張卡片：剩餘時間、續租、自動續租；只有需要處理時才多一行）。買斷、租用、續租、同意自動續租
-- 都在視窗內的確認頁（sheet）完成。付款全走 Economy client（MinidoracatEconomy.v1.Client.Entitlements，
-- late bind、不 require）：付款鈕先 quote，報價金額等於確認頁金額才立刻以同一張 quoteId purchase；
-- 不同（方案剛改）就不付款，確認頁換成新金額並提示。名額商品付款當下生效（Economy instant 商品）。
-- 規則：畫面只顯示 server 回來的狀態（不樂觀更新）；付款逾時＝結果未知，不自動重送、不換新報價，
-- 只提供「查詢購買結果」（唯讀讀同一筆 order）；自動續租預設關、開啟前先在確認頁同意該張租約的條款。
-- 伺服器整合狀態（fleetSnapshot 的 quota.economy）不是 READY 時只顯示原因、不呼叫 Economy（SP 也是）。
require "MinidoracatVehicleManager_API"
require "MinidoracatVehicleManager_Client"

local MVM = MinidoracatVehicleManager
local C = MVM.Client
local SRC, PROD = MVM.ECON_SOURCE, MVM.ECON_PRODUCT
local BU = {}
MVM.BillingUI = BU

-- ------------------------------------------------------------ 純邏輯（harness 可測） ---
local function tbl(t) return type(t) == "table" and t or {} end
local DAY_MS = 86400000

-- Economy client 權益 facade；沒裝、舊版（rev < 2）或還是單一租約（沒有 rentals 能力）回 nil
function BU.api()
    local EC = MinidoracatEconomy
    local CL = EC and EC.v1 and EC.v1.Client
    local caps = CL and CL.CAPABILITIES
    if CL and CL.API_MAJOR == 1 and (CL.API_REVISION or 0) >= 2 and type(caps) == "table"
        and caps.entitlements == true and caps.rentals == true and type(CL.Entitlements) == "table" then
        return CL.Entitlements, CL
    end
    return nil
end

local BLOCKERS = { OFF = "IGUI_MVM_Slots_SP", ABSENT = "IGUI_MVM_Slots_Absent", UNSUPPORTED = "IGUI_MVM_Slots_Unsupported",
    FAILED = "IGUI_MVM_Slots_Failed", UNAVAILABLE = "IGUI_MVM_Slots_Unavailable" }

-- 付費區塊不能用的原因（翻譯鍵），可用回 nil。server 的整合狀態優先，其次本機 Economy client 與報價資料
function BU.blocker(quota, hasApi, env)
    if quota == nil then return "IGUI_MVM_Loading" end
    if BLOCKERS[quota.economy] then return BLOCKERS[quota.economy] end
    if quota.economy ~= "READY" or not hasApi then return "IGUI_MVM_Slots_Unsupported" end
    if env == nil then return "IGUI_MVM_Slots_LoadingPrices" end
    return nil
end

-- 購買回覆 → 狀態列鍵；server 拒絕回 nil（呼叫端顯示原因碼）。名額付款當下生效，受理就是完成
function BU.purchaseKey(res)
    if res.unknown or res.error == "timeout" then return "IGUI_MVM_Slots_NoAnswer" end
    if not res.ok then return nil end
    if res.duplicate then return "IGUI_MVM_Slots_Duplicate" end
    return "IGUI_MVM_Slots_PaidDone"
end

-- 拒絕碼：本 MOD 的原因（server validatePurchase 的 CONFIG_BLOCKED 等）→ Economy 的錯誤文字 → 不帶代碼的通用說明
-- （代碼寫進客戶端 log 供回報）
function BU.reasonText(code, E)
    local key = "IGUI_MVM_Reason_" .. tostring(code)
    local t = getText(key)
    if t ~= key then return t end
    if E and E.errorText then return E.errorText(code) end
    MVM.log("no translation for reason " .. tostring(code))
    return getText("IGUI_MVM_Failed")
end

-- 狀態列訊息綁在這個權益／方案版本上：新狀態到達（任一版本變了）就清掉舊訊息
function BU.stateKey(env)
    local e, p = tbl(tbl(env).entitlement), tbl(tbl(env).plan)
    return tostring(e.revision) .. "/" .. tostring(p.revision)
end

-- 剩餘時間（天, 時）；已到或缺欄位回 nil。時間是 server 的 epoch ms，與本機時鐘相差時僅影響顯示
function BU.timeLeft(untilMs, now)
    if type(untilMs) ~= "number" or untilMs <= now then return nil end
    local hours = math.ceil((untilMs - now) / 3600000)
    local days = math.floor(hours / 24)
    return days, hours - days * 24
end

-- 剩餘時間文字：整天只寫天數，不到一天只寫小時
function BU.leftText(untilMs, now)
    local d, h = BU.timeLeft(untilMs, now)
    if d == nil then return nil end
    if d > 0 and h == 0 then return getText("IGUI_MVM_Slots_Days", d) end
    if d > 0 then return getText("IGUI_MVM_Slots_DaysHours", d, h) end
    return getText("IGUI_MVM_Slots_Hours", h)
end

function BU.currencyName(E, id)
    if E and E.currencyName then return E.currencyName(id) end
    local cur = MinidoracatEconomy and MinidoracatEconomy.CURRENCIES and MinidoracatEconomy.CURRENCIES[id]
    return cur and getText(cur.nameKey) or tostring(id)
end

-- 金額＋幣別（數字與幣別的順序交給譯文）
function BU.money(E, amount, currency) return getText("IGUI_MVM_Slots_Money", amount or 0, BU.currencyName(E, currency)) end

-- 數量步進器的值夾在 1..hi
function BU.clamp(v, hi) return math.max(1, math.min(hi, math.floor(tonumber(v) or 1))) end

-- 換行：規則同框架 MinidoracatUI/TextWrap.lua（內部模組、不對外，所以這裡照抄規則）。二分找最長放得下的前綴；
-- 截點兩側任一是空白、或任一是中日韓字（含全形標點）就在截點斷，否則往回找最近的斷點；整段都沒有斷點才硬切，
-- 硬切也不拆開英數字串（14 不會變成 1／4；整段都是英數字才照字切）。行首不放 UAX #14 CL／CP／EX／IS／NS 與
-- 收尾引號，行尾不放 OP 與起始引號。框架之外多兩條：數字和後面的中日文單位（7 日、7日）不拆開；片假名詞
-- 像英文單字一樣整個換行（サバイバーコイン 不會切成 コイ／ン）。中日文夾數字時不再退回最後一個空白斷，行不會
-- 只用到一半。字元邊界：Kahlua 字串是 UTF-16 code unit（string.byte 回碼元），harness 的標準 Lua 是 UTF-8
-- 位元組；本檔只能寫 ASCII 字面值，字一律寫碼位
local charOK, char256 = pcall(string.char, 256)
local UTF16 = charOK and string.byte(char256) == 256
local ASTRAL = 0x10000 -- 補充平面字（surrogate pair／4 位元組 UTF-8）一律當表意字
local function codeSet(codes)
    local t = {}
    for _, c in ipairs(codes) do t[c] = true end
    return t
end
local NO_START = codeSet({ 0x21, 0x29, 0x2C, 0x2E, 0x3A, 0x3B, 0x3F, 0x5D, 0x7D, 0x2019, 0x201D, 0x2026,
    0x3001, 0x3002, 0x3005, 0x3009, 0x300B, 0x300D, 0x300F, 0x3011, 0x3015, 0x3017, 0x3019, 0x301B, 0x301C,
    0x309B, 0x309C, 0x309D, 0x309E, 0x30A0, 0x30FB, 0x30FD, 0x30FE,
    0xFF01, 0xFF09, 0xFF0C, 0xFF0E, 0xFF1A, 0xFF1B, 0xFF1F, 0xFF3D, 0xFF5D, 0xFF61, 0xFF63, 0xFF64 })
local NO_END = codeSet({ 0x28, 0x5B, 0x7B, 0x2018, 0x201C, 0x3008, 0x300A, 0x300C, 0x300E, 0x3010, 0x3014,
    0x3016, 0x3018, 0x301A, 0x301D, 0xFF08, 0xFF3B, 0xFF5B, 0xFF62 })
local function ideographic(c)
    return (c >= 0x2E80 and c <= 0x9FFF) or (c >= 0xAC00 and c <= 0xD7AF) or (c >= 0xF900 and c <= 0xFAFF)
        or (c >= 0xFE30 and c <= 0xFE4F) or (c >= 0xFF00 and c <= 0xFFEF) or c >= ASTRAL
end
local function digit(c) return c ~= nil and c >= 48 and c <= 57 end
local function alnum(c) return digit(c) or (c ~= nil and ((c >= 65 and c <= 90) or (c >= 97 and c <= 122))) end
-- 片假名（含長音ー）與半形片假名
local function katakana(c) return c ~= nil and ((c >= 0x30A1 and c <= 0x30FA) or c == 0x30FC or (c >= 0xFF66 and c <= 0xFF9F)) end

-- n 退到字元邊界：前 n 個 unit 不切開一個字
local function boundary(s, n)
    if UTF16 then
        local u = n > 0 and s:byte(n) or 0
        if u >= 0xD800 and u <= 0xDBFF then n = n - 1 end -- 前綴結尾是 high surrogate
        return n
    end
    while n > 0 do
        local u = s:byte(n + 1)
        if not u or u < 128 or u >= 192 then break end
        n = n - 1 -- 下一個位元組是 continuation：退到字元開頭
    end
    return n
end

-- 從第 i 個 unit 開始的那個字的碼位（超出字串回 nil）。2 位元組 UTF-8 回首位元組：只需要知道它不是空白、數字、
-- 表意字或禁則字
local function codeAt(s, i)
    local u = s:byte(i)
    if u == nil or UTF16 then
        if u and u >= 0xD800 and u <= 0xDFFF then return ASTRAL end
        return u
    end
    if u < 0xE0 then return u end
    if u >= 0xF0 then return ASTRAL end
    local b2, b3 = s:byte(i + 1, i + 2)
    return (u - 0xE0) * 4096 + ((b2 or 0x80) - 0x80) * 64 + ((b3 or 0x80) - 0x80)
end

-- 第 n 個 unit 之後（n 是字元邊界、後面還有字）左右兩個字的碼位，與左邊那個字的起點
local function around(s, n)
    local li = boundary(s, n - 1) + 1
    return codeAt(s, li), codeAt(s, n + 1), li
end

local function breakable(s, n)
    local left, right, li = around(s, n)
    -- 數字和後面的中日文單位黏在一起：7|日、7| 日、7 |日 都不斷
    if digit(left) and ideographic((right == 32 and codeAt(s, n + 2)) or right or 0) then return false end
    if left == 32 and li > 1 and ideographic(right or 0) and digit(codeAt(s, boundary(s, li - 2) + 1)) then return false end
    if left == 32 or right == 32 then return true end
    if katakana(left) and katakana(right) then return false end
    return (ideographic(left) or ideographic(right)) and not NO_START[right] and not NO_END[left]
end

-- 一行：回 line, rest（line 去掉行尾空白、rest 去掉開頭空白）；連一個字都放不下時照樣放一個字
local function cutLine(text, width, font, measure)
    if measure(text, font) <= width then return text, "" end
    local low, high, best = 1, #text, 0
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local n = boundary(text, mid)
        if n >= 1 and measure(text:sub(1, n), font) <= width then best, low = n, mid + 1 else high = mid - 1 end
    end
    local n = best
    if best == 0 then
        repeat n = n + 1 until boundary(text, n) == n
    else
        while n > 0 and not breakable(text, n) do n = boundary(text, n - 1) end
        if n == 0 then -- 沒有斷點：硬切，但退到英數字串外
            n = best
            while n > 0 do
                local left, right = around(text, n)
                if not (alnum(left) and alnum(right)) then break end
                n = boundary(text, n - 1)
            end
            if n == 0 then n = best end
        end
    end
    return (text:sub(1, n):gsub("%s+$", "")), (text:sub(n + 1):gsub("^%s+", ""))
end

-- 貪婪換行：measure(s, font) 量字寬；每段（\n 分段）各自換行，空段留一行空白
function BU.wrap(out, s, width, font, measure)
    for para in (s .. "\n"):gmatch("(.-)\n") do
        local rest = para
        if rest == "" then out[#out + 1] = "" end
        while rest ~= "" do
            local line
            line, rest = cutLine(rest, width, font, measure)
            out[#out + 1] = line
        end
    end
end

-- 一次能買斷幾個（0＝不能買）：每次最多 100 個，且買完不超過買斷名額上限
function BU.permanentMax(plan, ent)
    return math.max(0, math.min(100, (plan.permanentLimit or 0) - (ent.permanent or 0)))
end

function BU.rentals(ent) return type(ent.rentals) == "table" and ent.rentals or {} end

function BU.findRental(ent, id)
    for _, r in ipairs(BU.rentals(ent)) do
        if r.id == id then return r end
    end
    return nil
end

-- 租用合計（有效租約的名額，rentalCommitted）超過服主調低後的上限
function BU.overLimit(plan, ent) return (ent.rentalCommitted or 0) > (plan.rentalLimit or 0) end

BU.RENTALS_MAX = 10 -- 快照缺 rentalsMax 時的保守值（Economy 的 E.RENTALS_MAX）

-- 新租約最多幾個名額；不能新租回 0, 原因鍵, 鍵的參數
function BU.newRental(plan, ent)
    local limit = plan.rentalLimit or 0
    if BU.overLimit(plan, ent) then return 0, "IGUI_MVM_Slots_OverLimit", limit end
    local room = limit - (ent.rentalCommitted or 0)
    if room <= 0 then return 0, "IGUI_MVM_Slots_RentalFull", limit end
    local max = ent.rentalsMax or BU.RENTALS_MAX
    if #BU.rentals(ent) >= max then return 0, "IGUI_MVM_Slots_RentalCount", max end
    return room
end

-- 確認頁數量上限（買斷／新租約）
function BU.sheetMax(env, kind)
    local plan, ent = tbl(env.plan), tbl(env.entitlement)
    if kind == "permanent" then return plan.permanentEnabled and BU.permanentMax(plan, ent) or 0 end
    return plan.rentalEnabled and (BU.newRental(plan, ent)) or 0
end

-- 已到期的租約續租從付款時重新起算、重新計入租用合計；租期中、寬限中的已經算在 rentalCommitted 裡
local function restarts(r) return r.state == "expired" or type(r.paidUntil) ~= "number" end
BU.restarts = restarts

-- 這張租約不能續租："OVER"＝續租後超過上限、"PAUSED"＝暫停販售／停租／系統暫停；可續租回 nil。
-- 原因文字由清單上方的說明（BU.notices）負責，卡片只在 OVER 而整體未超額時自己說明
function BU.renewReason(env, r)
    local plan, ent = tbl(env.plan), tbl(env.entitlement)
    local extra = restarts(r) and (r.quantity or 0) or 0
    if (ent.rentalCommitted or 0) + extra > (plan.rentalLimit or 0) then return "OVER" end
    if env.available == false or not plan.rentalEnabled or r.state == "paused_system" then return "PAUSED" end
    return nil
end

-- 舊授權即使因條款／系統暫停，仍須讓玩家取消；已送出取消則顯示未勾選。r 是一張租約
function BU.autoRenewOn(r)
    local state = r.autoRenewState
    if state == "pending_off" then return false end
    return r.autoRenew == true or state == "on" or state == "pending_on"
        or state == "paused_terms" or state == "paused_system"
end

-- 方案目前的租用條款，和租約記錄的 terms／同意的 autoTerms 同形
function BU.planTerms(plan) return { price = plan.rentalPrice, currency = plan.rentalCurrency, days = plan.rentalDays } end

-- 這組條款（租約這期的 terms 或自動續租同意的 autoTerms）和目前方案的租金、幣別、天數不同；其他方案欄位不算
function BU.termsDiffer(plan, t)
    return type(t) == "table"
        and (t.price ~= plan.rentalPrice or t.currency ~= plan.rentalCurrency or t.days ~= plan.rentalDays)
end

-- 自動續租開著但這期不會扣款（卡片的開關改寫「暫停」）
function BU.autoPaused(plan, ent, r)
    if not BU.autoRenewOn(r) then return false end
    local s = r.autoRenewState
    return s == "paused_terms" or s == "paused_system" or BU.termsDiffer(plan, r.autoTerms) or BU.overLimit(plan, ent)
        or not plan.rentalEnabled or not plan.autoRenewAllowed
end

-- 需要玩家重新同意：自動續租開著、同意的條款和方案不同，而且方案仍提供自動續租
function BU.needsConsent(plan, r)
    return BU.autoRenewOn(r) and BU.termsDiffer(plan, r.autoTerms) and plan.rentalEnabled == true
        and plan.autoRenewAllowed == true
end

-- 條款變更的一句話：只有租金變就寫租金，幣別或天數也變就連天數一起寫。t 是租約記下的條款
function BU.termsText(E, plan, t, qn)
    local new = BU.money(E, (plan.rentalPrice or 0) * qn, plan.rentalCurrency)
    local old = BU.money(E, (t.price or 0) * qn, t.currency)
    if t.currency == plan.rentalCurrency and t.days == plan.rentalDays then
        return getText("IGUI_MVM_Slots_NewPrice", new, old)
    end
    return getText("IGUI_MVM_Slots_NewTerms", new, plan.rentalDays or 0, old, t.days or 0)
end

-- 「我的租約」上方的說明，每種狀態只說一次：{ 鍵, 參數... }
function BU.notices(env)
    local plan, ent = tbl(env.plan), tbl(env.entitlement)
    local out, rentals = {}, BU.rentals(ent)
    if #rentals == 0 then return out end
    if BU.overLimit(plan, ent) then
        out[#out + 1] = { "IGUI_MVM_Slots_OverLimit", plan.rentalLimit or 0, ent.rentalCommitted or 0 }
    end
    if not plan.rentalEnabled then out[#out + 1] = { "IGUI_MVM_Slots_RentalStopped" } end
    local auto, system = false, false
    for _, r in ipairs(rentals) do
        if BU.autoRenewOn(r) then auto = true end
        if r.state == "paused_system" or r.autoRenewState == "paused_system" then system = true end
    end
    if auto and plan.rentalEnabled and not plan.autoRenewAllowed then out[#out + 1] = { "IGUI_MVM_Slots_AutoNotOffered" } end
    if system then out[#out + 1] = { "IGUI_MVM_Slots_SystemPaused" } end
    return out
end

-- 確認頁的金額：買斷／新租約＝數量 × 單價；續租與同意自動續租＝該張名額 × 目前租金。回 金額, 幣別, 名額數
function BU.sheetMoney(env, sheet)
    local plan, ent = tbl(env.plan), tbl(env.entitlement)
    if sheet.kind == "permanent" then return (plan.permanentPrice or 0) * sheet.qty, plan.permanentCurrency, sheet.qty end
    local n = sheet.qty
    if sheet.kind ~= "rental" then
        local r = BU.findRental(ent, sheet.rental)
        n = r and r.quantity or 0
    end
    return (plan.rentalPrice or 0) * n, plan.rentalCurrency, n
end

-- 報價和確認頁上的金額、幣別一致才付款
function BU.quoteMatches(q, expect)
    return type(q) == "table" and type(expect) == "table" and q.amount == expect.amount and q.currency == expect.currency
end

function BU.balance(env, currency)
    local b = type(env.balances) == "table" and env.balances[currency]
    return type(b) == "table" and b.available or 0
end

-- ------------------------------------------------------------------ 視窗 ---
if not (MinidoracatUI and MinidoracatUI.v1) then
    local ok, err = pcall(require, "MinidoracatUI/V1")
    if not ok then MVM.log("Billing UI framework load failed: " .. tostring(err)); return end
end
local UI = MinidoracatUI and MinidoracatUI.v1
local CAPS = UI and UI.CAPABILITIES
if not (UI and UI.API_MAJOR == 1 and (UI.API_REVISION or 0) >= 7 and CAPS and CAPS.window and CAPS.controls and CAPS.dialog) then
    MVM.log("Billing UI requires MinidoracatUI API 1 rev 7 with window/controls/dialog; found major="
        .. tostring(UI and UI.API_MAJOR) .. " revision=" .. tostring(UI and UI.API_REVISION))
    return
end
local Focus = CAPS.focus and UI.Focus or nil

-- 底色不透明；card＝租約卡片底色（比底色亮一階）
local theme = UI.Theme.create({ colors = { surface = { r = 0.04, g = 0.045, b = 0.05, a = 1 },
    card = { r = 0.085, g = 0.09, b = 0.1, a = 1 } } })
local COL = theme.colors
local FS, FM, FL = UIFont.Small, UIFont.Medium, UIFont.Large
local PAD, GAP, SCROLL_W = 12, 6, 6
local CARD_PAD, CARD_GAP = 8, 12
local LAYOUT = "MinidoracatVehicleManagerSlots"

local function fontH(font) return getTextManager():getFontHeight(font) end
local function measure(s, font) return getTextManager():MeasureStringX(font, s) end

-- 滑鼠把焦點下的控制項捲出可視範圍（它被隱藏）：焦點改到第一個看得見的控制項、不畫框。
-- 不處理的話 Focus 會把隱藏的控制項當失效目標，從第一個目標重走而把內容捲回頂端
local function keepFocus(slots)
    local c = Focus and Focus.focused()
    if c == nil or c.parent ~= slots.body or c:getIsVisible() then return end
    for _, p in ipairs(slots.placed) do
        if p:getIsVisible() and Focus.focusControl(p, false) then return end
    end
end

local Body = ISPanel:derive("MVMSlotsBody")
-- 卡片底色畫在控制項之前（prerender → children → render）；只畫可視範圍內的部分
function Body:prerender()
    local slots, h = self.slots, self.height
    slots:tick()
    for _, f in ipairs(slots.fills) do
        local y0, y1 = math.max(0, f.y - slots.scroll), math.min(h, f.y + f.h - slots.scroll)
        if y1 > y0 then theme:fill(self, PAD, y0, slots.innerW, y1 - y0, "card", "round") end
    end
end
-- 內容比可視高度高（大字級／小螢幕）時捲動：只畫完整落在可視範圍的列，右側畫細捲軸
function Body:render()
    local slots, h = self.slots, self.height
    for _, l in ipairs(slots.lines) do
        local y = l.y - slots.scroll
        if y >= 0 and y + fontH(l.font) <= h then
            local c = COL[l.token]
            self:drawText(l.text, l.x or PAD, y, c.r, c.g, c.b, c.a, l.font)
        end
    end
    local max = slots.contentH - h
    if max > 0 then
        local thumb = math.max(20, math.floor(h * h / slots.contentH))
        local t, c = COL.well, COL.textFaint
        self:drawRect(self.width - SCROLL_W, 0, 4, h, t.a, t.r, t.g, t.b)
        self:drawRect(self.width - SCROLL_W, math.floor((h - thumb) * slots.scroll / max), 4, thumb, c.a, c.r, c.g, c.b)
    end
end
-- Focus 落點前呼叫（目標描述的 scrollOwner）：把整列控制項連同說明文字捲進可視範圍；
-- 放不下就至少讓控制項那一列完整可見。setScroll 當場重放控制項，Focus 接著就看得到它
function Body:scrollTo(control)
    local s = self.slots
    local top, bottom = control.scrollTop or control.contentY, control.scrollBottom or (control.contentY + control.height)
    if bottom - top > self.height then top, bottom = control.contentY, control.contentY + control.height end
    if top < s.scroll then
        s:setScroll(top)
    elseif bottom > s.scroll + self.height then
        s:setScroll(bottom - self.height)
    end
end
function Body:onMouseWheel(del)
    if self.slots.contentH <= self.height then return false end
    self.slots:setScroll(self.slots.scroll + del * (fontH(FS) + 2) * 3)
    keepFocus(self.slots)
    return true
end
-- 右側留白＝捲軸點擊／拖曳區（控制項右緣不超過 PAD）；其餘位置維持 ISPanel 原行為
local function dragTo(body, y)
    body.slots:setScroll((body.slots.contentH - body.height) * y / body.height)
    keepFocus(body.slots)
end
local function stopDrag(body)
    if body.dragging then body.dragging = false; body:setCapture(false) end
end
function Body:onMouseDown(x, y)
    if self.slots.contentH <= self.height or x < self.width - PAD then return ISPanel.onMouseDown(self, x, y) end
    -- 同原版 ISScrollBar：拖曳期間捕捉滑鼠，放開事件一定回到這裡，不會被上層視窗吃掉而卡在拖曳中
    self.dragging = true
    self:setCapture(true)
    dragTo(self, y)
    return true
end
function Body:onMouseMove(dx, dy)
    if self.dragging then dragTo(self, self:getMouseY()) else ISPanel.onMouseMove(self, dx, dy) end
end
function Body:onMouseMoveOutside(dx, dy)
    if self.dragging then dragTo(self, self:getMouseY()) else ISPanel.onMouseMoveOutside(self, dx, dy) end
end
function Body:onMouseUp(x, y) stopDrag(self); return ISPanel.onMouseUp(self, x, y) end
function Body:onMouseUpOutside(x, y) stopDrag(self); return ISPanel.onMouseUpOutside(self, x, y) end

local W = {}
W.__index = W
MVM.BillingWindow = W

local function bucket()
    local p = getSpecificPlayer(0)
    if p == nil then return nil end
    local owner = isClient() and p:getUsername() or "local:0"
    return owner and C.buckets[owner] or nil
end

-- 勾選框寬度跟著標籤（框架只在建構時量一次）
local function relabel(box, label)
    box:setLabel(label)
    box:setWidth(box.extraW + measure(label, FS))
end

function W:checkbox(label, onChange)
    local box = self:adopt(UI.Checkbox.new({ x = 0, y = 0, label = label, theme = theme, target = self, onChange = onChange }))
    box.extraW = box.width - measure(label, FS)
    return box
end

function W.new()
    local self = setmetatable({ lines = {}, placed = {}, fills = {}, controls = {}, rows = {}, focusList = {}, focusPool = {},
        dirty = true, scroll = 0, contentH = 0, innerW = 0 }, W)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w = math.min(520, sw - 40)
    -- autoY：視窗還在我們放的位置（玩家沒拖、沒讀回上次的位置）時，每次重排依新高度垂直置中
    self.autoY = math.floor((sh - 200) / 2)
    self.win = UI.Window.new({ x = math.floor((sw - w) / 2), y = self.autoY, width = w, height = 200,
        title = getText("IGUI_MVM_SlotsTitle"), icon = "coins", theme = theme })
    -- 鍵盤／手把目標＝排版記下的控制項，含捲出可視範圍而暫時隱藏的；描述帶 scrollOwner，
    -- Focus 落點前請 body 捲過去（Body:scrollTo），所以看不到的控制項滑鼠點不到、鍵盤仍走得到
    self.win.keyboardTargets = function() return self.focusList end
    -- Esc／手把 B：在確認頁回總覽；在總覽交回框架（手把 B 關窗）
    self.win.onEscape = function()
        if self.sheet == nil then return false end
        self:closeSheet()
        return true
    end
    local top = self.win:contentTop()
    local body = Body:new(0, top, w, 100)
    body.background = false
    body.slots = self
    body:initialise()
    self.win:addChild(body)
    self.body = body
    self.ch = fontH(FS) + 10
    local step = math.max(28, self.ch)
    self.btnBuy = self:button(getText("IGUI_MVM_Btn_BuySlots"), W.onBuyPermanent, "primary")
    self.btnRent = self:button(getText("IGUI_MVM_Btn_RentSlots"), W.onRent, "primary")
    self.btnCheck = self:button(getText("IGUI_MVM_Btn_CheckOrder"), W.onCheckOrder)
    self.btnRefresh = self:button(getText("IGUI_MVM_Btn_Refresh"), W.onRefresh, "ghost", "reload")
    self.btnAdmin = self:button(getText("IGUI_MVM_Btn_PaidSettings"), W.onAdmin, "ghost", "settings")
    self.less = self:stepButton("-", -1, step)
    self.more = self:stepButton("+", 1, step)
    self.sheetAuto = self:checkbox(getText("IGUI_MVM_Slots_AutoRenew"), function(t, checked)
        if t.sheet then t.sheet.auto = checked; t.dirty = true end
    end)
    self.btnCancel = self:button(getText("UI_Cancel"), W.closeSheet)
    self.btnPay = self:button(nil, W.onPay, "primary")
    self.btnCheck._focusGroup, self.btnRefresh._focusGroup, self.btnAdmin._focusGroup = "tail", "tail", "tail"
    self.less._focusGroup, self.more._focusGroup = "qty", "qty"
    self.btnCancel._focusGroup, self.btnPay._focusGroup = "acts", "acts"
    return self
end

function W:adopt(c)
    c:setVisible(false)
    self.body:addChild(c)
    self.controls[#self.controls + 1] = c
    return c
end

function W:button(title, fn, style, icon, size)
    return self:adopt(UI.Button.new({ x = 0, y = 0, width = size, height = size or self.ch, title = title or "",
        style = style, icon = icon, theme = theme, target = self, onClick = fn }))
end

function W:stepButton(title, delta, size)
    local b = self:button(title, W.onStep, nil, nil, size)
    b.internal = delta
    return b
end

-- 每張租約：續租、自動續租開關、（需要時）同意新條款；用到才建（最多 rentalsMax 張）
function W:rentalRow(i)
    local row = self.rows[i]
    if row == nil then
        row = { renew = self:button(getText("IGUI_MVM_Btn_Renew"), W.onRenew),
            agree = self:button(getText("IGUI_MVM_Btn_AgreeTerms"), W.onAgree, "primary") }
        row.auto = self:checkbox(getText("IGUI_MVM_Slots_AutoRenew"), function(t, checked, box) t:onAutoRenew(checked, box) end)
        row.renew._focusGroup, row.auto._focusGroup, row.agree._focusGroup = "card" .. i, "card" .. i, "agree" .. i
        self.rows[i] = row
    end
    return row
end

function W:say(text, token)
    self.message, self.messageToken, self.messageAt, self.dirty = text, token or "text", false, true
end

-- 捲動並當場重放控制項：只有完整落在可視範圍的控制項顯示（看不到的不能用滑鼠點）
function W:setScroll(v)
    local h = self.body.height
    self.scroll = math.max(0, math.min(math.floor(v), self.contentH - h))
    for _, c in ipairs(self.placed) do
        local y = c.contentY - self.scroll
        c:setY(y)
        c:setVisible(y >= 0 and y + c.height <= h)
    end
end

function W:textAt(s, x, y, token, font)
    self.lines[#self.lines + 1] = { text = s, x = x, y = y, token = token or "text", font = font or FS }
end

-- 換行後逐行排；x／width 省略＝整個內容寬
function W:addText(s, token, font, x, width)
    font = font or FS
    local parts = {}
    BU.wrap(parts, s, width or self.innerW, font, measure)
    for _, t in ipairs(parts) do
        self:textAt(t, x or PAD, self.y, token, font)
        self.y = self.y + fontH(font) + 2
    end
end

function W:section(text)
    self.y = self.y + GAP
    self:addText(text, "text", FM)
end

-- 控制項排進目前這一列（列內垂直置中）；捲動時依 contentY 重放
function W:put(c, x, rowY, rowH)
    c:setX(x)
    c.contentY = rowY + math.floor((rowH - c.height) / 2)
    self.placed[#self.placed + 1] = c
end

-- 鍵盤落點時要一起捲進來的範圍：列上方的說明（top）到目前排版位置
function W:span(ctrls, top)
    for _, c in ipairs(ctrls) do
        if top then c.scrollTop = top end
        c.scrollBottom = self.y
    end
end

-- 由左至右擺一列控制項，放不下就換行
function W:placeRow(ctrls)
    local x, rowY, rowH = PAD, self.y, 0
    for _, c in ipairs(ctrls) do rowH = math.max(rowH, c.height) end
    for _, c in ipairs(ctrls) do
        if x > PAD and x + c.width > PAD + self.innerW then x, rowY = PAD, rowY + rowH + GAP end
        self:put(c, x, rowY, rowH)
        x = x + c.width + GAP
    end
    if rowH > 0 then self.y = rowY + rowH + GAP end
    self:span(ctrls, ctrls[1] and ctrls[1].contentY)
end

-- 一列：左邊文字（x0..right 之間換行），控制項靠右；剩給文字的寬度太窄就文字一行、控制項下一行靠右
function W:sideRow(text, token, ctrls, x0, right)
    local cw, ch = 0, 0
    for _, c in ipairs(ctrls) do cw, ch = cw + c.width + GAP, math.max(ch, c.height) end
    local tw = right - x0 - cw
    local stacked = tw < self.innerW / 3
    if stacked then tw = right - x0 end
    local parts = {}
    BU.wrap(parts, text, tw, FS, measure)
    local lh = fontH(FS) + 2
    local rowY, textH = self.y, #parts * lh
    local rowH = stacked and textH or math.max(ch, textH)
    local ty = rowY + math.floor((rowH - textH) / 2)
    for i, t in ipairs(parts) do self:textAt(t, x0, ty + (i - 1) * lh, token) end
    local cy = stacked and rowY + textH + GAP or rowY
    local x = right - cw + GAP
    for _, c in ipairs(ctrls) do
        self:put(c, x, cy, stacked and ch or rowH)
        x = x + c.width + GAP
    end
    self.y = (stacked and cy + ch or rowY + rowH) + GAP
    self:span(ctrls, rowY)
end

-- 主按鈕在左、右邊一行價格與上限（或不能用的原因）
function W:buttonLine(btn, info)
    local x = PAD + btn.width + GAP
    local parts = {}
    BU.wrap(parts, info, PAD + self.innerW - x, FS, measure)
    local lh = fontH(FS) + 2
    local rowY = self.y
    local rowH = math.max(btn.height, #parts * lh)
    self:put(btn, PAD, rowY, rowH)
    local ty = rowY + math.floor((rowH - #parts * lh) / 2)
    for i, t in ipairs(parts) do self:textAt(t, x, ty + (i - 1) * lh, "textMuted") end
    self.y = rowY + rowH + GAP
    self:span({ btn }, rowY)
end

-- 一列控制項靠右（確認頁的取消／付款）
function W:rowRight(ctrls)
    local w, h = -GAP, 0
    for _, c in ipairs(ctrls) do w, h = w + c.width + GAP, math.max(h, c.height) end
    local x, rowY = PAD + self.innerW - w, self.y
    for _, c in ipairs(ctrls) do
        self:put(c, x, rowY, h)
        x = x + c.width + GAP
    end
    self.y = rowY + h + GAP
    self:span(ctrls, rowY)
end

-- 焦點描述：排版順序中連續、同一 _focusGroup 的控制項併成一組（每列一組，左右鍵在組內走）。
-- control＝組內第一個可用的控制項，給 Focus 的 scrollOwner 捲動用；描述 table 重用（Focus 每幀讀）
function W:buildFocus()
    local list, pool, placed = self.focusList, self.focusPool, self.placed
    local n, i = 0, 1
    while i <= #placed do
        local group = placed[i]._focusGroup
        n = n + 1
        local d = pool[n]
        if d == nil then
            d = { kind = "group", controls = {}, scrollOwner = self.body }
            pool[n] = d
        end
        local m = 0
        d.control = nil
        while i <= #placed and placed[i]._focusGroup == group and (group ~= nil or m == 0) do
            local c = placed[i]
            m = m + 1
            d.controls[m] = c
            if d.control == nil and c.enable ~= false and c._enabled ~= false then d.control = c end
            i = i + 1
        end
        for k = #d.controls, m + 1, -1 do d.controls[k] = nil end
        d.control = d.control or d.controls[1]
        list[n] = d
    end
    for k = #list, n + 1, -1 do list[k] = nil end
end

-- 資料換了（Economy 快取的權益、車隊快照的名額、管理員清單）才重排；剩餘時間每分鐘重算一次
function W:tick()
    local b = bucket()
    local E = BU.api()
    local env = E and self.live and E.getState(SRC, PROD) or nil
    if self.dirty or env ~= self.env or (b and b.quota) ~= self.quota or (b and b.admin) ~= self.admin
        or getTimestampMs() - (self.laidOutAt or 0) > 60000 then
        self:layout()
    end
end

-- 狀態列訊息只描述說出它時的狀態：之後權益或方案版本變了（新狀態到達）就清掉
function W:syncMessage(key)
    if self.messageAt == false then
        self.messageAt = key
    elseif self.message ~= nil and self.messageAt ~= key then
        self.message = nil
    end
end

function W:layout()
    self.dirty, self.laidOutAt = false, getTimestampMs()
    local b = bucket()
    local q = b and b.quota
    local E = BU.api()
    -- 只有 server 整合 READY 才碰 Economy（SP／未安裝／失敗時不送任何 Economy 命令）
    self.live = E ~= nil and q ~= nil and q.economy == "READY"
    local env = self.live and E.getState(SRC, PROD) or nil
    self.env, self.quota, self.admin = env, q, b and b.admin
    if self.live and env == nil and not self.requested then self:requestState() end
    self:syncMessage(BU.stateKey(env))
    local blocker = BU.blocker(q, E ~= nil, env)
    local s = self.sheet
    if s and (blocker or env.ok == false or (s.rental and BU.findRental(tbl(env.entitlement), s.rental) == nil)
        or ((s.kind == "permanent" or s.kind == "rental") and BU.sheetMax(env, s.kind) < 1)) then
        self.sheet = nil
    end
    for _, c in ipairs(self.controls) do c:setVisible(false) end
    self.lines, self.placed, self.fills, self.y, self.innerW = {}, {}, {}, PAD, self.win.width - PAD * 2

    if self.sheet then
        self:layoutSheet(E, env, q)
    else
        self:layoutOverview(E, env, q, blocker)
    end

    local top = self.win:contentTop()
    local sh = getCore():getScreenHeight()
    self.contentH = self.y + PAD
    local h = math.min(self.contentH, sh - top - 20)
    self.body:setHeight(h)
    self.win:setHeight(top + h)
    if self.win:getY() == self.autoY then
        self.autoY = math.floor((sh - top - h) / 2)
        self.win:setY(self.autoY)
    end
    self:buildFocus()
    self:setScroll(self.scroll)
    keepFocus(self)
end

-- 狀態列：處理中（灰）或最後一則訊息（成功白、錯誤紅、需要你處理金）
function W:status()
    if self.busy then
        self:addText(getText("IGUI_MVM_Slots_Busy"), "textMuted")
    elseif self.message then
        self:addText(self.message, self.messageToken)
    end
end

-- 總覽：可綁定台數（大字）、分項、買斷／租用、我的租約、錢包、頁尾按鈕
function W:layoutOverview(E, env, q, blocker)
    if q then
        self:addText(getText("IGUI_MVM_Slots_Headline", q.total or 0, q.used or 0), "text", FL)
        self:addText(getText("IGUI_MVM_Slots_Breakdown", q.base or 0, q.permanent or 0, q.rental or 0), "textMuted")
    end
    self.y = self.y + GAP
    if blocker then
        local loading = blocker == "IGUI_MVM_Loading" or blocker == "IGUI_MVM_Slots_LoadingPrices"
        if loading and self.stateError then
            self:addText(self.stateError, "errorText")
        else
            self:addText(getText(blocker), loading and "textMuted" or "errorText")
        end
    elseif env.ok == false then
        self:addText(BU.reasonText(env.error, E), "errorText")
    else
        self:layoutOffer(E, env)
    end
    self.y = self.y + GAP
    self:status()
    local tail = {}
    if self.live and self.order ~= nil then
        self.btnCheck:setEnabled(self.busy == nil)
        tail[#tail + 1] = self.btnCheck
    end
    tail[#tail + 1] = self.btnRefresh
    if self.admin ~= nil then tail[#tail + 1] = self.btnAdmin end
    self:placeRow(tail)
end

function W:layoutOffer(E, env)
    local plan, ent = tbl(env.plan), tbl(env.entitlement)
    local canBuy = self:canPurchase()
    if env.available == false and (plan.permanentEnabled or plan.rentalEnabled) then
        self:addText(getText("IGUI_MVM_Slots_SalesPaused"), "text")
    end
    local hi, info = BU.permanentMax(plan, ent), nil
    if not plan.permanentEnabled then
        info = getText("IGUI_MVM_Slots_PermanentOff")
    elseif hi < 1 then
        info = getText("IGUI_MVM_Slots_BuyFull", ent.permanent or 0, plan.permanentLimit or 0)
    else
        info = getText("IGUI_MVM_Slots_BuyInfo", plan.permanentPrice or 0, BU.currencyName(E, plan.permanentCurrency),
            ent.permanent or 0, plan.permanentLimit or 0)
    end
    self.btnBuy:setEnabled(canBuy and plan.permanentEnabled == true and hi >= 1)
    self:buttonLine(self.btnBuy, info)

    local room, why, arg = BU.newRental(plan, ent)
    if not plan.rentalEnabled then
        info = getText("IGUI_MVM_Slots_RentalOff")
    elseif why == nil or why == "IGUI_MVM_Slots_OverLimit" then -- 超過上限的說明在租約清單上方
        info = getText("IGUI_MVM_Slots_RentInfo", plan.rentalPrice or 0, BU.currencyName(E, plan.rentalCurrency),
            plan.rentalDays or 0, ent.rentalCommitted or 0, plan.rentalLimit or 0)
    elseif why == "IGUI_MVM_Slots_RentalFull" then
        info = getText(why, ent.rentalCommitted or 0, arg)
    else
        info = getText(why, arg)
    end
    self.btnRent:setEnabled(canBuy and plan.rentalEnabled == true and room >= 1)
    self:buttonLine(self.btnRent, info)

    local rentals = BU.rentals(ent)
    if #rentals > 0 then
        self:section(getText("IGUI_MVM_Slots_Section_Rentals"))
        for _, n in ipairs(BU.notices(env)) do
            self:addText(n[2] ~= nil and getText(n[1], n[2], n[3]) or getText(n[1]), "text")
        end
        local now = getTimestampMs()
        for i, r in ipairs(rentals) do self:layoutCard(i, r, env, E, now, canBuy) end
    end

    -- 錢包：方案用到的幣別各一筆
    local parts, ids = {}, { plan.rentalCurrency }
    if plan.permanentEnabled and plan.permanentCurrency ~= plan.rentalCurrency then
        table.insert(ids, 1, plan.permanentCurrency)
    end
    for _, id in ipairs(ids) do
        parts[#parts + 1] = getText("IGUI_MVM_Slots_Wallet", BU.currencyName(E, id), BU.balance(env, id))
    end
    if #parts > 0 then
        self.y = self.y + GAP
        self:addText(table.concat(parts, getText("IGUI_MVM_Sep"), 1, #parts), "textMuted")
    end
end

-- 一張租約卡片：「N 個名額 · 剩 X」＋續租＋自動續租一列；要玩家同意新條款時多一行（金色＋同意鈕）
function W:layoutCard(i, r, env, E, now, canBuy)
    local plan, ent = tbl(env.plan), tbl(env.entitlement)
    local qn = r.quantity or 0
    local top = self.y + (i > 1 and CARD_GAP - GAP or 0)
    self.y = top + CARD_PAD
    local left, text, token = BU.leftText(r.paidUntil, now), nil, "text"
    if left then
        text = getText("IGUI_MVM_Slots_Card", qn, left)
    else
        local grace = BU.leftText(r.graceUntil, now)
        text = grace and getText("IGUI_MVM_Slots_CardGrace", qn, grace) or getText("IGUI_MVM_Slots_CardExpired", qn)
        if grace == nil then token = "textMuted" end
    end
    local row = self:rentalRow(i)
    row.renew.internal, row.auto.internal, row.agree.internal = r.id, r.id, r.id
    local why = BU.renewReason(env, r)
    row.renew:setEnabled(canBuy and why == nil)
    local ctrls = { row.renew }
    local on = BU.autoRenewOn(r)
    if plan.autoRenewAllowed or on or r.autoRenewState == "pending_off" then
        row.auto:setChecked(on, true)
        relabel(row.auto, getText(BU.autoPaused(plan, ent, r) and "IGUI_MVM_Slots_AutoPaused" or "IGUI_MVM_Slots_AutoRenew"))
        row.auto:setEnabled(self.live and self.busy == nil and (on or plan.autoRenewAllowed == true))
        ctrls[2] = row.auto
    end
    local x0, right = PAD + CARD_PAD, PAD + self.innerW - CARD_PAD
    self:sideRow(text, token, ctrls, x0, right)
    if BU.needsConsent(plan, r) then
        row.agree:setEnabled(self.live and self.busy == nil)
        self:sideRow(BU.termsText(E, plan, r.autoTerms, qn), "accent", { row.agree }, x0, right)
    end
    if why == "OVER" and not BU.overLimit(plan, ent) then
        self:addText(getText("IGUI_MVM_Slots_RenewOver", plan.rentalLimit or 0), "textMuted", FS, x0, right - x0)
    end
    self.y = self.y - GAP + CARD_PAD
    self.fills[#self.fills + 1] = { y = top, h = self.y - top }
    self.y = self.y + GAP
end

-- 確認頁：標題、（買斷／租用）數量、合計、付款後可綁定台數、餘額前後、（租用）到期自動續租、取消／付款
local SHEET_TITLES = { permanent = "IGUI_MVM_Btn_BuySlots", rental = "IGUI_MVM_Btn_RentSlots", renew = "IGUI_MVM_Btn_Renew",
    auto = "IGUI_MVM_Slots_AutoRenew" }

function W:layoutSheet(E, env, q)
    local s, plan, ent = self.sheet, tbl(env.plan), tbl(env.entitlement)
    self:addText(getText(SHEET_TITLES[s.kind]), "text", FM)
    self.y = self.y + GAP
    if s.kind == "permanent" or s.kind == "rental" then
        local hi = BU.sheetMax(env, s.kind)
        s.qty = BU.clamp(s.qty, hi)
        self:qtyRow(s.qty, hi)
    end
    local amount, cur, n = BU.sheetMoney(env, s)
    local name = BU.currencyName(E, cur)
    local days = plan.rentalDays or 0
    local r = s.rental and BU.findRental(ent, s.rental)
    if s.kind == "permanent" or s.kind == "rental" then
        self:addText(s.kind == "rental" and getText("IGUI_MVM_Slots_SheetRentTotal", days, amount, name)
            or getText("IGUI_MVM_Slots_SheetTotal", amount, name), "text")
        self:addText(getText("IGUI_MVM_Slots_SheetAfter", (q and q.total or 0) + n), "textMuted")
    elseif s.kind == "renew" then
        if restarts(r) then
            self:addText(getText("IGUI_MVM_Slots_SheetRestart", n, days), "text")
        else
            self:addText(getText("IGUI_MVM_Slots_SheetRenew", n, days,
                BU.leftText(r.paidUntil + days * DAY_MS, getTimestampMs()) or ""), "text")
        end
        if BU.termsDiffer(plan, r.terms) then self:addText(BU.termsText(E, plan, r.terms, n), "text") end
    else
        self:addText(getText("IGUI_MVM_Slots_SheetAuto", n, days, amount, name), "text")
        self:addText(getText("IGUI_MVM_Slots_SheetAutoNote"), "textMuted")
    end
    local have = BU.balance(env, cur)
    local short = s.kind ~= "auto" and have < amount
    if short then
        self:addText(getText("IGUI_MVM_Slots_QuoteShort", name, have, amount - have), "errorText")
    elseif s.kind ~= "auto" then
        self:addText(getText("IGUI_MVM_Slots_SheetBalance", name, have, have - amount), "textMuted")
    end
    if s.kind == "rental" and plan.autoRenewAllowed then
        self.y = self.y + GAP
        self.sheetAuto:setChecked(s.auto == true, true)
        self.sheetAuto:setEnabled(self.busy == nil)
        -- 開關標籤只放短句（標籤不換行）；每期金額另起一行灰字，照內容寬換行
        relabel(self.sheetAuto, getText("IGUI_MVM_Slots_SheetAutoBox"))
        self:placeRow({ self.sheetAuto })
        self:addText(getText("IGUI_MVM_Slots_SheetAutoEach", amount, name), "textMuted")
        self:span({ self.sheetAuto })
    end
    if s.notice then self:addText(getText("IGUI_MVM_Slots_PriceChanged"), "accent") end
    self.y = self.y + GAP
    self:status()
    if s.kind == "auto" then
        self.btnPay:setTitle(getText("IGUI_MVM_Btn_Agree"))
        self.btnPay:setEnabled(self.live and self.busy == nil and plan.autoRenewAllowed == true)
    else
        self.btnPay:setTitle(getText("IGUI_MVM_Btn_PayN", amount))
        self.btnPay:setEnabled(self:canPurchase() and not short and n >= 1)
    end
    self.btnCancel:setEnabled(self.busy == nil)
    self:rowRight({ self.btnCancel, self.btnPay })
end

-- 數量：標籤 [-] 數值 [+]；數值是文字，不是焦點目標
function W:qtyRow(value, hi)
    local less, more = self.less, self.more
    less:setEnabled(self.busy == nil and value > 1)
    more:setEnabled(self.busy == nil and value < hi)
    local rowY, rowH = self.y, less.height
    local textY = rowY + math.floor((rowH - fontH(FS)) / 2)
    local label, num, numW = getText("IGUI_MVM_Slots_Quantity"), tostring(value), measure("000", FS)
    local x = PAD
    self:textAt(label, x, textY)
    x = x + measure(label, FS) + GAP
    self:put(less, x, rowY, rowH)
    x = x + less.width + GAP
    self:textAt(num, x + math.floor((numW - measure(num, FS)) / 2), textY)
    x = x + numW + GAP
    self:put(more, x, rowY, rowH)
    self.y = rowY + rowH + GAP
    self:span({ less, more }, rowY)
end

-- ------------------------------------------------------------------ 操作 ---
-- 失敗（本機拒絕：invalid_args／pending／queue_full）時不改狀態，只顯示原因
function W:localRefusal(why)
    self.busy = nil
    self:say(BU.reasonText(why or "invalid_args", BU.api()), "errorText")
end

-- 付款結果未知（self.order）時不能再買，直到查回同一筆的結果
function W:canPurchase()
    local env = self.env
    return self.live == true and not self.busy and self.order == nil and env ~= nil and env.ok ~= false
        and env.available ~= false
end

function W:openSheet(kind, rental)
    if kind == "auto" then
        if not self.live or self.busy then return end
    elseif not self:canPurchase() then
        return
    end
    self.sheet = { kind = kind, rental = rental, qty = 1 }
    self:say(nil)
end

function W:closeSheet()
    if self.busy == "quote" or self.busy == "purchase" then return end
    self.sheet = nil
    self:say(nil)
end

-- 步進器：只改數量，下次排版夾回範圍
function W:onStep(b)
    if self.sheet then self.sheet.qty, self.dirty = (self.sheet.qty or 1) + b.internal, true end
end

function W:onBuyPermanent()
    if BU.sheetMax(tbl(self.env), "permanent") >= 1 then self:openSheet("permanent") end
end

function W:onRent()
    if BU.sheetMax(tbl(self.env), "rental") >= 1 then self:openSheet("rental") end
end

function W:onRenew(b)
    local env = tbl(self.env)
    local r = BU.findRental(tbl(env.entitlement), b.internal)
    if r ~= nil and BU.renewReason(env, r) == nil then self:openSheet("renew", r.id) end
end

function W:onAgree(b)
    local env = tbl(self.env)
    local r = BU.findRental(tbl(env.entitlement), b.internal)
    if r ~= nil and tbl(env.plan).autoRenewAllowed then self:openSheet("auto", r.id) end
end

-- 付款鈕：先報價；報價金額與確認頁一致才付款（onQuote）。同意自動續租直接送出
function W:onPay()
    local s, env = self.sheet, tbl(self.env)
    if s == nil then return end
    s.notice = nil
    local plan, ent = tbl(env.plan), tbl(env.entitlement)
    if s.kind == "auto" then return self:sendAutoRenew(true, ent.revision, plan.revision, s.rental) end
    if s.kind ~= "renew" then s.qty = BU.clamp(s.qty, BU.sheetMax(env, s.kind)) end
    local amount, cur, n = BU.sheetMoney(env, s)
    s.expect = { amount = amount, currency = cur }
    -- 續租不送數量：server 依該張租約的名額報價
    if s.kind == "renew" then return self:startQuote("rental", nil, s.rental) end
    self:startQuote(s.kind, n)
end

function W:startQuote(kind, quantity, rental)
    local E = BU.api()
    if E == nil or not self:canPurchase() then return end
    self.busy = "quote"
    self:say(nil)
    local rid, why = E.quote(SRC, PROD, kind, quantity, function(res) self:onQuote(res) end, rental)
    if rid == nil then self:localRefusal(why) end
end

-- 報價回來：金額、幣別等於確認頁上的就付款；不同（方案剛改）不付款，確認頁依新方案重算並提示
function W:onQuote(res)
    self.busy, self.dirty = nil, true
    if res.unknown then return self:say(getText("IGUI_MVM_Slots_QuoteNoAnswer"), "errorText") end
    if not res.ok or type(res.quote) ~= "table" then return self:say(BU.reasonText(res.error, BU.api()), "errorText") end
    local s = self.sheet
    if s == nil then return end
    if not BU.quoteMatches(res.quote, s.expect) then
        s.notice = true
        return
    end
    self:purchase(res.quote)
end

function W:purchase(q)
    local E = BU.api()
    if E == nil or not self:canPurchase() then return end
    local s = self.sheet
    self.busy = "purchase"
    self:say(nil)
    -- 付款前保留 server 指定的識別；查詢只讀同一筆，不用其他新訂單猜測付款結果。
    -- 新租約勾了到期自動續租：意圖跟著這筆訂單，直到它有最終結果（付款逾時後查回 paid 也照樣送同意）
    self.order = { quoteId = q.id, orderId = q.orderId,
        auto = s and s.kind == "rental" and s.auto and { terms = q.termsRevision } or nil }
    local rid, why = E.purchase(SRC, q.id, function(res) self:onPurchase(res) end)
    if rid == nil then
        self.order = nil
        self:localRefusal(why)
    end
end

-- 訂單有了最終結果：付款完成且勾了自動續租，就替這張新租約（id＝訂單 id）送同意，條款＝報價的方案版本，
-- 權益版本取這次回覆的快照；退款、未付款只說明結果
function W:finishOrder(o, res, key)
    self.order = nil
    local auto = o.auto
    if auto and o.orderId ~= nil and key == "IGUI_MVM_Slots_PaidDone" then
        local snap = tbl(res.snapshot)
        return self:sendAutoRenew(true, tbl(snap.entitlement).revision, tonumber(auto.terms) or tbl(snap.plan).revision,
            o.orderId, key)
    end
    self:say(getText(key), "text")
end

function W:onPurchase(res)
    self.busy, self.dirty = nil, true
    local key = BU.purchaseKey(res)
    local o = self.order
    if key == nil then
        self.order = nil
        return self:say(BU.reasonText(res.error, BU.api()), "errorText")
    end
    self.sheet = nil
    if o and res.orderId then o.orderId = o.orderId or res.orderId end
    if key == "IGUI_MVM_Slots_NoAnswer" then return self:say(getText(key), "accent") end
    self:finishOrder(o or {}, res, key)
end

-- 查詢只讀：優先查 server 在報價指定的 orderId；舊報價缺 orderId 時查原 quoteId，絕不重送購買。
function W:onCheckOrder()
    local E = BU.api()
    local o = self.order
    if E == nil or not self.live or self.busy or o == nil then return end
    local id = o.orderId or o.quoteId
    self.busy = "order"
    self:say(nil)
    local rid, why = E.getOrder(SRC, PROD, id, function(res) self:onOrder(res, id) end)
    if rid == nil then self:localRefusal(why) end
end

local OUTCOME_KEYS = { paid = "IGUI_MVM_Slots_PaidDone", refunded = "IGUI_MVM_Slots_Refunded",
    not_paid = "IGUI_MVM_Slots_NoOrder" }

-- 只有查回同一筆、而且 server 給了最終結果才解除付款鎖；其他一律維持「查詢購買結果」
function W:onOrder(res, requestedId)
    self.busy, self.dirty = nil, true
    if res.unknown then return self:say(getText("IGUI_MVM_Slots_NoAnswer"), "accent") end
    if not res.ok then return self:say(BU.reasonText(res.error, BU.api()), "errorText") end
    local pending = self.order
    local order = type(res.order) == "table" and res.order or {}
    if pending and pending.orderId == nil and requestedId == pending.quoteId and res.known == true then
        pending.orderId = order.orderId
    end
    local sameOrder = pending and order.orderId ~= nil and order.orderId == pending.orderId
    local E = BU.api()
    local key = sameOrder and res.known == true and E and E.orderOutcome and OUTCOME_KEYS[E.orderOutcome(res)]
    if not key then return self:say(getText("IGUI_MVM_Slots_NoAnswer"), "accent") end
    self:finishOrder(pending, res, key)
end

-- 勾選狀態只跟 server：點擊後先還原；關閉直接送，開啟先到確認頁同意該張租約的條款
function W:onAutoRenew(checked, box)
    local env = tbl(self.env)
    local plan, ent = tbl(env.plan), tbl(env.entitlement)
    local r = box and BU.findRental(ent, box.internal)
    local on = r ~= nil and BU.autoRenewOn(r)
    if box then box:setChecked(on, true) end
    if r == nil or not self.live or self.busy or checked == on then return end
    if not checked then return self:sendAutoRenew(false, ent.revision, plan.revision, r.id) end
    if plan.autoRenewAllowed then self:openSheet("auto", r.id) end
end

-- paidKey：付款後替新租約送同意（狀態列先說付款完成，同意失敗時一併說明）
function W:sendAutoRenew(enabled, revision, termsRevision, rental, paidKey)
    local E = BU.api()
    if E == nil or self.busy then return end
    self.busy = "autoRenew"
    self:say(nil)
    local function failed(text)
        self:say(paidKey and getText("IGUI_MVM_Slots_PaidAutoFailed", text) or text, "errorText")
    end
    local rid, why = E.setAutoRenew(SRC, PROD, enabled, revision, termsRevision, function(res)
        self.busy, self.dirty = nil, true
        if res.unknown then
            E.requestState(SRC, PROD)
            return failed(getText("IGUI_MVM_Slots_AutoRenewUnknown"))
        end
        if not res.ok then return failed(BU.reasonText(res.error, E)) end
        if self.sheet and self.sheet.kind == "auto" then self.sheet = nil end
        self:say(paidKey and getText(paidKey) or nil, "text")
    end, rental)
    if rid == nil then
        self.busy = nil
        failed(BU.reasonText(why or "invalid_args", E))
    end
end

-- requested 只限制自動載入一次；失敗後由重新整理明示重試，避免每幀重送。
function W:requestState()
    local E = BU.api()
    if E == nil or not self.live then return end
    self:say(nil)
    self.requested, self.stateError = true, nil
    local rid, why = E.requestState(SRC, PROD, function(res)
        if res.unknown or not res.ok then
            self.stateError = BU.reasonText(res.error or "timeout", E)
            self:say(self.stateError, "errorText")
        else
            self.stateError, self.dirty = nil, true
        end
    end)
    if rid == nil then
        self.stateError = BU.reasonText(why or "invalid_args", E)
        self:say(self.stateError, "errorText")
    end
end

function W:onRefresh()
    self:requestState()
    local p = getSpecificPlayer(0)
    if p then C.request(p, "fleetResync", {}) end
end

-- 付費名額設定（管理員）；伺服器也會檢查管理員資格。框架太舊（< rev 11）時設定視窗不存在，說明要更新
function W:onAdmin()
    if MVM.PaidSlotsWindow then MVM.PaidSlotsWindow.open(self.win) else self:say(getText("IGUI_MVM_NeedFramework"), "errorText") end
end

function W.open()
    local w = W.instance
    if w == nil then
        w = W.new()
        w.win:addToUIManager()
        ISLayoutManager.RegisterWindow(LAYOUT, w.win, w.win)
        W.instance = w
    end
    stopDrag(w.body)
    w.win:setVisible(true)
    w.win:bringToTop()
    w.requested, w.dirty, w.sheet = false, true, nil
    return w
end
