-- 綁定名額視窗（車隊視窗「名額」按鈕開啟）：基本／永久／租用／總計、價格、錢包，買斷 k 個、
-- 租約清單（每張租約各自續租、各自自動續費）與新租約 n 個。付款全走 Economy client
-- （MinidoracatEconomy.v1.Client.Entitlements，late bind、不 require）：先 quote 取得 server 鎖定的報價，
-- 玩家看過摘要按「付款」才以同一張 quoteId purchase。
-- 規則：畫面只顯示 server 回來的狀態（不樂觀更新）；逾時＝結果未知，不自動重送、不換新報價，
-- 只提供「查詢購買結果」（唯讀讀同一筆 order）；自動續費預設關、勾選前先確認該張租約的條款，送出後照 server 狀態顯示。
-- 一次只有一筆玩家發起的待確認購買（entitlement.pendingOrderId）；自動續費的待確認付款只擋同一張租約續租。
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

-- 耐久狀態 → 提示鍵；未列出的一律當「未知」，絕不冒充已保存
local DURABLE = { confirmed = "IGUI_MVM_Slots_Saved", pending = "IGUI_MVM_Slots_WaitSave",
    rolledback = "IGUI_MVM_Slots_RolledBack" }
function BU.durableKey(status) return DURABLE[status] or "IGUI_MVM_Slots_SaveUnknown" end

-- 購買回覆 → 提示鍵；server 拒絕回 nil（呼叫端顯示原因碼）。ok 只代表 server 受理，是否耐久看快照
function BU.purchaseKey(res)
    if res.unknown or res.error == "timeout" then return "IGUI_MVM_Slots_NoAnswer" end
    if not res.ok then return nil end
    if res.duplicate then return "IGUI_MVM_Slots_Duplicate" end
    local ent = type(res.snapshot) == "table" and res.snapshot.entitlement
    return BU.durableKey(type(ent) == "table" and type(ent.durable) == "table" and ent.durable.status or nil)
end

-- 拒絕碼：本 MOD 的原因（server validatePurchase 的 CONFIG_BLOCKED 等）→ Economy 的錯誤文字 → 原始碼
function BU.reasonText(code, E)
    local key = "IGUI_MVM_Reason_" .. tostring(code)
    local t = getText(key)
    if t ~= key then return t end
    if E and E.errorText then return E.errorText(code) end
    return getText("IGUI_MVM_Failed", tostring(code))
end

-- 剩餘時間（天, 時）；已到或缺欄位回 nil。時間是 server 的 epoch ms，與本機時鐘相差時僅影響顯示
function BU.timeLeft(untilMs, now)
    if type(untilMs) ~= "number" or untilMs <= now then return nil end
    local hours = math.ceil((untilMs - now) / 3600000)
    local days = math.floor(hours / 24)
    return days, hours - days * 24
end

function BU.currencyName(E, id)
    if E and E.currencyName then return E.currencyName(id) end
    local cur = MinidoracatEconomy and MinidoracatEconomy.CURRENCIES and MinidoracatEconomy.CURRENCIES[id]
    return cur and getText(cur.nameKey) or tostring(id)
end

-- 數量步進器的值夾在 1..hi（hi ≥ 1 才會畫步進器）
function BU.clamp(v, hi) return math.max(1, math.min(hi, math.floor(tonumber(v) or 1))) end

-- 一次能買斷幾個（0＝不能買）：每次最多 100 個，且買完不超過永久名額上限
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

-- 租用合計（有效＋等待存檔的租約名額，rentalCommitted）超過服主調低後的上限
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

-- 已到期的租約續租是從存檔確認起算、重新計入租用合計；租期中、寬限、暫停中的已經算在 rentalCommitted 裡
local function restarts(r) return r.state == "expired" or type(r.paidUntil) ~= "number" end

-- 這張租約不能續租的原因鍵，可續租回 nil（玩家自己的待確認購買另由 canPurchase 擋）
function BU.renewReason(env, r)
    local plan, ent = tbl(env.plan), tbl(env.entitlement)
    if r.pendingOrderId ~= nil then
        return r.autoPending and "IGUI_MVM_Slots_AutoPaySaving" or "IGUI_MVM_Slots_RenewPending"
    end
    local extra = restarts(r) and (r.quantity or 0) or 0
    if (ent.rentalCommitted or 0) + extra > (plan.rentalLimit or 0) then return "IGUI_MVM_Slots_RenewOver" end
    if env.available == false or not plan.rentalEnabled or r.state == "paused_terms" or r.state == "paused_system" then
        return "IGUI_MVM_Slots_RenewPaused"
    end
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

-- 這組條款（租約這期的 terms 或自動續費同意的 autoTerms）和目前方案的租金、幣別、天數不同；其他方案欄位不算
function BU.termsDiffer(plan, t)
    return type(t) == "table"
        and (t.price ~= plan.rentalPrice or t.currency ~= plan.rentalCurrency or t.days ~= plan.rentalDays)
end

-- 自動續費開著卻不會扣款的原因鍵：同意的條款與方案不同 → 租用合計超過上限 → 停租 → 不提供自動續費 →
-- server 說暫停但原因不在上面（通用說明）；沒有暫停回 nil
function BU.autoPauseReason(plan, ent, r)
    if not BU.autoRenewOn(r) then return nil end
    if BU.termsDiffer(plan, r.autoTerms) then return "IGUI_MVM_Slots_AutoTermsChanged" end
    if BU.overLimit(plan, ent) then return "IGUI_MVM_Slots_AutoPausedOver" end
    if not plan.rentalEnabled then return "IGUI_MVM_Slots_AutoPausedOff" end
    if not plan.autoRenewAllowed then return "IGUI_MVM_Slots_AutoPausedNotOffered" end
    if r.autoRenewState == "paused_terms" then return "IGUI_MVM_Slots_AutoRenewPausedTerms" end
    return nil
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

local theme = UI.Theme.create({ colors = { surface = { r = 0.04, g = 0.045, b = 0.05, a = 0.95 } } })
local COL = theme.colors
local FS, FM = UIFont.Small, UIFont.Medium
local PAD, GAP, SCROLL_W = 12, 6, 6
local DAY_MS = 86400000
local LAYOUT = "MinidoracatVehicleManagerSlots"

local function fontH(font) return getTextManager():getFontHeight(font) end
local function measure(s, font) return getTextManager():MeasureStringX(font, s) end
-- 避頭：這些全形標點不放行首。Kahlua 字串是 UTF-16，string.byte 回碼元；標準 Lua 回位元組，比不到、無副作用
local NO_LINE_START = { [12289] = true, [12290] = true, [65292] = true, [65307] = true, [65306] = true, [65281] = true,
    [65311] = true, [65289] = true, [12301] = true, [12303] = true, [12305] = true, [12299] = true }

-- 貪婪換行：量字寬找最長可放前綴，有空白就在最後一個空白斷（中日文沒有空白就照字切）
local function wrap(out, s, width, font)
    for para in (s .. "\n"):gmatch("(.-)\n") do
        local rest = para
        if rest == "" then out[#out + 1] = "" end
        while rest ~= "" do
            local n = #rest
            if measure(rest, font) > width then
                local lo, hi = 1, n
                while lo < hi do
                    local mid = math.floor((lo + hi + 1) / 2)
                    if measure(rest:sub(1, mid), font) <= width then lo = mid else hi = mid - 1 end
                end
                local space = rest:sub(1, lo):find(" [^ ]*$")
                n = (space and space > lo / 2) and space or lo
                while n > 1 and NO_LINE_START[rest:byte(n + 1)] do n = n - 1 end
            end
            out[#out + 1] = (rest:sub(1, n):gsub("%s+$", ""))
            rest = (rest:sub(n + 1):gsub("^%s+", ""))
        end
    end
end

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
function Body:prerender() self.slots:tick() end
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

local function dialogWidth() return math.min(480, getCore():getScreenWidth() - 40) end

function W.new()
    local self = setmetatable({ lines = {}, placed = {}, controls = {}, rows = {}, focusList = {}, focusPool = {},
        dirty = true, scroll = 0, contentH = 0, buyQty = 1, rentQty = 1 }, W)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w = math.min(560, sw - 40)
    -- autoY：視窗還在我們放的位置（玩家沒拖、沒讀回存檔位置）時，每次重排依新高度垂直置中
    self.autoY = math.floor((sh - 200) / 2)
    self.win = UI.Window.new({ x = math.floor((sw - w) / 2), y = self.autoY, width = w, height = 200,
        title = getText("IGUI_MVM_SlotsTitle"), icon = "coins", theme = theme })
    -- 鍵盤／手把目標＝排版記下的控制項，含捲出可視範圍而暫時隱藏的；描述帶 scrollOwner，
    -- Focus 落點前請 body 捲過去（Body:scrollTo），所以看不到的控制項滑鼠點不到、鍵盤仍走得到
    self.win.keyboardTargets = function() return self.focusList end
    local top = self.win:contentTop()
    local body = Body:new(0, top, w, 100)
    body.background = false
    body.slots = self
    body:initialise()
    self.win:addChild(body)
    self.body = body
    self.ch = fontH(FS) + 10
    local step = math.max(28, self.ch)
    self.btnBuy = self:button(nil, W.onBuyPermanent, "primary")
    self.buyLess = self:stepButton("-", "buyQty", -1, step)
    self.buyMore = self:stepButton("+", "buyQty", 1, step)
    self.btnRent = self:button(nil, W.onRent, "primary")
    self.rentLess = self:stepButton("-", "rentQty", -1, step)
    self.rentMore = self:stepButton("+", "rentQty", 1, step)
    self.btnCheck = self:button(getText("IGUI_MVM_Btn_CheckOrder"), W.onCheckOrder)
    self.btnRefresh = self:button(getText("IGUI_MVM_Btn_Refresh"), W.onRefresh, "ghost", "reload")
    self.btnPlans = self:button(getText("IGUI_MVM_Btn_ManagePlans"), W.onAdminPlans, "ghost", "settings")
    self.buyLess._focusGroup, self.buyMore._focusGroup, self.btnBuy._focusGroup = "buy", "buy", "buy"
    self.rentLess._focusGroup, self.rentMore._focusGroup, self.btnRent._focusGroup = "rent", "rent", "rent"
    self.btnCheck._focusGroup, self.btnRefresh._focusGroup, self.btnPlans._focusGroup = "tail", "tail", "tail"
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

function W:stepButton(title, key, delta, size)
    local b = self:button(title, W.onStep, nil, nil, size)
    b.qtyKey, b.internal = key, delta
    return b
end

-- 每張租約一列：續租按鈕＋自動續費開關，用到才建（最多 rentalsMax 張）
function W:rentalRow(i)
    local row = self.rows[i]
    if row == nil then
        row = { renew = self:button(nil, W.onRenew) }
        row.auto = self:adopt(UI.Checkbox.new({ x = 0, y = 0, label = getText("IGUI_MVM_Slots_AutoRenew"), theme = theme,
            target = self, onChange = function(t, checked, box) t:onAutoRenew(checked, box) end }))
        row.renew._focusGroup, row.auto._focusGroup = "rental" .. i, "rental" .. i
        self.rows[i] = row
    end
    return row
end

function W:say(text, token)
    self.message, self.messageToken, self.dirty = text, token or "accent", true
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

function W:addText(s, token, font)
    font = font or FS
    local parts = {}
    wrap(parts, s, self.innerW, font)
    for _, t in ipairs(parts) do
        self:textAt(t, PAD, self.y, token, font)
        self.y = self.y + fontH(font) + 2
    end
end

function W:section(text)
    self.y = self.y + GAP
    self:addText(text, "textMuted", FM)
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

-- 由左至右擺一列控制項，放不下就換行。top＝這列說明文字的起點（捲動時一起帶進來）
function W:placeRow(ctrls, top)
    local x, rowY, rowH = PAD, self.y, 0
    for _, c in ipairs(ctrls) do rowH = math.max(rowH, c.height) end
    for _, c in ipairs(ctrls) do
        if x > PAD and x + c.width > PAD + self.innerW then x, rowY = PAD, rowY + rowH + GAP end
        self:put(c, x, rowY, rowH)
        x = x + c.width + GAP
    end
    if rowH > 0 then self.y = rowY + rowH + GAP end
    self:span(ctrls, top or ctrls[1] and ctrls[1].contentY)
end

-- 數量步進器：標籤 [-] 數值 [+] [動作 k 個]；數值是文字，不是焦點目標
function W:stepper(labelKey, value, hi, less, more, action, actionKey, enabled)
    action:setTitle(getText(actionKey, value))
    less:setEnabled(enabled and value > 1)
    more:setEnabled(enabled and value < hi)
    action:setEnabled(enabled)
    local rowY, rowH = self.y, math.max(less.height, action.height)
    local textY = rowY + math.floor((rowH - fontH(FS)) / 2)
    local label, num, numW = getText(labelKey), tostring(value), measure("000", FS)
    local x = PAD
    self:textAt(label, x, textY)
    x = x + measure(label, FS) + GAP
    self:put(less, x, rowY, rowH)
    x = x + less.width + GAP
    self:textAt(num, x + math.floor((numW - measure(num, FS)) / 2), textY)
    x = x + numW + GAP
    self:put(more, x, rowY, rowH)
    x = x + more.width + GAP
    if x + action.width > PAD + self.innerW then x, rowY = PAD, rowY + rowH + GAP end
    self:put(action, x, rowY, rowH)
    self.y = rowY + rowH + GAP
    local row = { less, more, action }
    self:span(row, less.contentY)
    return row
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
        while i <= #placed and placed[i]._focusGroup == group do
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

function W:layout()
    self.dirty, self.laidOutAt = false, getTimestampMs()
    local b = bucket()
    local q = b and b.quota
    local E, CL = BU.api()
    -- 只有 server 整合 READY 才碰 Economy（SP／未安裝／失敗時不送任何 Economy 命令）
    self.live = E ~= nil and q ~= nil and q.economy == "READY"
    local env = self.live and E.getState(SRC, PROD) or nil
    self.env, self.quota, self.admin = env, q, b and b.admin
    if self.live and env == nil and not self.requested then self:requestState() end
    for _, c in ipairs(self.controls) do c:setVisible(false) end
    self.lines, self.placed, self.y, self.innerW = {}, {}, PAD, self.win.width - PAD * 2

    self:addText(getText("IGUI_MVM_Slots_Section_Now"), "textMuted", FM)
    if q then
        self:addText(getText("IGUI_MVM_Slots_Base", q.base or 0))
        self:addText(getText("IGUI_MVM_Slots_Permanent", q.permanent or 0))
        self:addText(getText("IGUI_MVM_Slots_Rental", q.rental or 0))
        self:addText(getText("IGUI_MVM_Slots_Total", q.total or 0, q.used or 0), "accent")
        if (q.pending or 0) > 0 then self:addText(getText("IGUI_MVM_Slots_Pending", q.pending), "accent") end
    end

    local blocker = BU.blocker(q, E ~= nil, env)
    local ent = {}
    if blocker then
        self.y = self.y + GAP
        local loading = blocker == "IGUI_MVM_Loading" or blocker == "IGUI_MVM_Slots_LoadingPrices"
        if loading and self.stateError then
            self:addText(self.stateError, "errorText")
        else
            self:addText(getText(blocker), loading and "textMuted" or "errorText")
        end
    elseif env.ok == false then
        self.y = self.y + GAP
        self:addText(BU.reasonText(env.error, E), "errorText")
    else
        ent = tbl(env.entitlement)
        self:layoutOffer(E, env, q.total or 0)
    end

    -- 狀態列與查詢／重新整理／管理入口
    self.y = self.y + GAP
    if self.busy then
        self:addText(getText("IGUI_MVM_Pending"), "accent")
    elseif self.message then
        self:addText(self.message, self.messageToken)
    end
    local tail = {}
    if self.live and (self.order ~= nil or ent.pendingOrderId ~= nil) then
        self.btnCheck:setEnabled(self.busy == nil)
        tail[#tail + 1] = self.btnCheck
    end
    tail[#tail + 1] = self.btnRefresh
    if self.admin ~= nil and CL and CL.openAdminPlans then tail[#tail + 1] = self.btnPlans end
    self:placeRow(tail)

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

-- 價格與購買：玩家待確認提示、買斷步進器、租約清單、新租約步進器、錢包。total＝目前綁定上限
function W:layoutOffer(E, env, total)
    local plan, ent = tbl(env.plan), tbl(env.entitlement)
    local waiting = E.waitText(ent.wait)
    if waiting then self:addText(waiting, "accent") end
    if ent.pendingOrderId ~= nil or self.order ~= nil then self:addText(getText("IGUI_MVM_Slots_PendingBlock"), "accent") end
    if env.available == false then self:addText(getText("IGUI_MVM_Slots_Paused"), "accent") end
    local canBuy = self:canPurchase()

    self:section(getText("IGUI_MVM_Slots_Section_Buy"))
    local currencies = {}
    if plan.permanentEnabled then
        local name = BU.currencyName(E, plan.permanentCurrency)
        currencies[1] = plan.permanentCurrency
        self:addText(getText("IGUI_MVM_Slots_PermanentPrice", plan.permanentPrice or 0, name, ent.permanent or 0,
            plan.permanentLimit or 0))
        local hi = BU.permanentMax(plan, ent)
        if hi < 1 then
            self:addText(getText("IGUI_MVM_Slots_PermanentLimit", plan.permanentLimit or 0), "textMuted")
        else
            self.buyQty = BU.clamp(self.buyQty, hi)
            local k = self.buyQty
            local row = self:stepper("IGUI_MVM_Slots_Quantity", k, hi, self.buyLess, self.buyMore, self.btnBuy,
                "IGUI_MVM_Btn_BuyN", canBuy)
            self:addText(getText("IGUI_MVM_Slots_BuySubtotal", k * (plan.permanentPrice or 0), name, total + k), "textMuted")
            self:span(row)
        end
    else
        self:addText(getText("IGUI_MVM_Slots_PermanentOff"), "textMuted")
    end

    self:section(getText("IGUI_MVM_Slots_Section_Rental"))
    local name = BU.currencyName(E, plan.rentalCurrency)
    if plan.rentalEnabled then
        self:addText(getText("IGUI_MVM_Slots_RentalPlan", plan.rentalDays or 0, plan.rentalPrice or 0, name))
        if plan.rentalCurrency ~= currencies[1] then currencies[#currencies + 1] = plan.rentalCurrency end
    else
        self:addText(getText("IGUI_MVM_Slots_RentalOff"), "textMuted")
    end
    local rentals = BU.rentals(ent)
    if #rentals > 0 then
        self:addText(getText("IGUI_MVM_Slots_RentalSummary", ent.rentalCommitted or 0, plan.rentalLimit or 0))
        if BU.overLimit(plan, ent) then self:addText(getText("IGUI_MVM_Slots_OverLimit", plan.rentalLimit or 0), "accent") end
        if not plan.autoRenewAllowed then self:addText(getText("IGUI_MVM_Slots_AutoRenewNotOffered"), "textMuted") end
        local now = getTimestampMs()
        for i, r in ipairs(rentals) do self:layoutRental(i, r, env, E, now, canBuy) end
    elseif plan.rentalEnabled then
        self:addText(getText("IGUI_MVM_Slots_NoRentals", plan.rentalLimit or 0), "textMuted")
    end
    if plan.rentalEnabled then
        local hi, why, arg = BU.newRental(plan, ent)
        if why == nil then
            self.rentQty = BU.clamp(self.rentQty, hi)
            local n = self.rentQty
            local row = self:stepper("IGUI_MVM_Slots_NewRental", n, hi, self.rentLess, self.rentMore, self.btnRent,
                "IGUI_MVM_Btn_RentN", canBuy)
            self:addText(getText("IGUI_MVM_Slots_RentSubtotal", n * (plan.rentalPrice or 0), name, plan.rentalDays or 0,
                total + n), "textMuted")
            self:span(row)
        elseif why ~= "IGUI_MVM_Slots_OverLimit" then -- 超過上限的說明已在租約清單上方
            self:addText(getText(why, arg), "textMuted")
        end
    end

    self.y = self.y + GAP
    for _, id in ipairs(currencies) do
        local bal = type(env.balances) == "table" and env.balances[id]
        self:addText(getText("IGUI_MVM_Slots_Balance", BU.currencyName(E, id), bal and bal.available or 0), "textMuted")
    end
end

-- 一張租約：狀態行、續租＋自動續費一列、續租價格或不能續租的原因、自動續費狀態
function W:layoutRental(i, r, env, E, now, canBuy)
    local plan, ent = tbl(env.plan), tbl(env.entitlement)
    local qn, days = r.quantity or 0, plan.rentalDays or 0
    local top = self.y
    local function terms(key, t) -- 條款文字：每期金額（單價 × 名額）、幣別、天數
        return getText(key, (t.price or 0) * qn, BU.currencyName(E, t.currency), t.price or 0, qn, t.days or 0)
    end
    if type(r.paidUntil) ~= "number" then
        -- 新租約已付款、等存檔：還沒有租期，沒有可操作的東西
        self:addText(getText("IGUI_MVM_Slots_RentalNew", qn, type(r.terms) == "table" and r.terms.days or days), "accent")
        if type(r.terms) == "table" then self:addText(terms("IGUI_MVM_Slots_RentalTerms", r.terms), "textMuted") end
        return
    end
    local d, h = BU.timeLeft(r.paidUntil, now)
    if d then
        self:addText(getText("IGUI_MVM_Slots_RentalActive", qn, d, h))
    else
        local gd, gh = BU.timeLeft(r.graceUntil, now)
        if gd then
            self:addText(getText("IGUI_MVM_Slots_RentalGrace", qn, gd * 24 + gh), "accent")
        else
            self:addText(getText("IGUI_MVM_Slots_RentalExpired", qn), "textMuted")
        end
    end
    if type(r.terms) == "table" then self:addText(terms("IGUI_MVM_Slots_RentalTerms", r.terms), "textMuted") end
    local row = self:rentalRow(i)
    row.renew.internal, row.auto.internal = r.id, r.id
    row.renew:setTitle(getText("IGUI_MVM_Btn_Renew", days))
    local why = BU.renewReason(env, r)
    row.renew:setEnabled(canBuy and why == nil)
    local ctrls = { row.renew }
    local ar = r.autoRenewState or "off"
    local on = BU.autoRenewOn(r)
    if plan.autoRenewAllowed or on or ar == "pending_off" then
        row.auto:setChecked(on, true)
        row.auto:setEnabled(self.busy == nil and (on or plan.autoRenewAllowed == true))
        ctrls[2] = row.auto
    end
    self:placeRow(ctrls, top)
    local amount, name = qn * (plan.rentalPrice or 0), BU.currencyName(E, plan.rentalCurrency)
    if why then
        self:addText(getText(why), "textMuted")
    elseif restarts(r) then
        self:addText(getText("IGUI_MVM_Slots_RenewRestart", amount, name, days), "textMuted")
    else
        local nd, nh = BU.timeLeft(r.paidUntil + days * DAY_MS, now)
        self:addText(getText("IGUI_MVM_Slots_RenewPrice", amount, name, nd or 0, nh or 0), "textMuted")
    end
    if ctrls[2] then
        self:addText(getText("IGUI_MVM_Slots_AutoRenewState", E.autoRenewText and E.autoRenewText(ar) or ar), "textMuted")
        local pause = BU.autoPauseReason(plan, ent, r)
        if pause == "IGUI_MVM_Slots_AutoTermsChanged" then
            local was, now = r.autoTerms, BU.planTerms(plan)
            self:addText(getText(pause, (was.price or 0) * qn, BU.currencyName(E, was.currency), was.days or 0,
                (now.price or 0) * qn, BU.currencyName(E, now.currency), now.days or 0), "accent")
        elseif pause then
            self:addText(getText(pause), "accent")
        end
    end
    self:span(ctrls)
end

-- ------------------------------------------------------------------ 操作 ---
-- 失敗（本機拒絕：invalid_args／pending／queue_full）時不改狀態，只顯示原因
function W:localRefusal(why)
    self.busy = nil
    self:say(BU.reasonText(why or "invalid_args", BU.api()), "errorText")
end

-- 玩家自己的待確認購買（本機訂單或快照的 pendingOrderId）才擋；自動續費的待確認付款不擋新購買
function W:canPurchase()
    local env = self.env
    if not self.live or self.busy or self.order or not env or env.ok == false or env.available == false then return false end
    return tbl(env.entitlement).pendingOrderId == nil
end

-- 步進器：只改數量，下次排版夾回範圍
function W:onStep(b)
    self[b.qtyKey], self.dirty = (self[b.qtyKey] or 1) + b.internal, true
end

function W:onBuyPermanent()
    local env = tbl(self.env)
    local hi = BU.permanentMax(tbl(env.plan), tbl(env.entitlement))
    if hi >= 1 then self:startQuote("permanent", BU.clamp(self.buyQty, hi)) end
end

function W:onRent()
    local env = tbl(self.env)
    local hi = BU.newRental(tbl(env.plan), tbl(env.entitlement))
    if hi >= 1 then self:startQuote("rental", BU.clamp(self.rentQty, hi)) end
end

-- 續租不送數量：server 依該張租約的名額報價
function W:onRenew(b)
    local env = tbl(self.env)
    local r = BU.findRental(tbl(env.entitlement), b.internal)
    if r == nil or BU.renewReason(env, r) ~= nil then return end
    self:startQuote("rental", nil, r.id)
end

function W:startQuote(kind, quantity, rental)
    local E = BU.api()
    if E == nil or not self:canPurchase() then return end
    self.busy, self.quoting = "quote", { kind = kind, quantity = quantity, rental = rental }
    self:say(nil)
    local rid, why = E.quote(SRC, PROD, kind, quantity, function(res) self:onQuote(res) end, rental)
    if rid == nil then self:localRefusal(why) end
end

-- 報價摘要＝最後確認：動作與數量、起算方式、價格、付款前後餘額、付款後上限；餘額不足只告知缺額，不提供付款
function W:onQuote(res)
    self.busy, self.dirty = nil, true
    local ask = self.quoting or {}
    self.quoting = nil
    if res.unknown then return self:say(getText("IGUI_MVM_Slots_QuoteNoAnswer"), "accent") end
    if not res.ok or type(res.quote) ~= "table" then return self:say(BU.reasonText(res.error, BU.api()), "errorText") end
    local E = BU.api()
    local q = res.quote
    local env = type(res.snapshot) == "table" and res.snapshot or self.env or {}
    local plan, ent = tbl(env.plan), tbl(env.entitlement)
    local r = ask.rental and BU.findRental(ent, ask.rental)
    local n = tonumber(q.quantity) or ask.quantity or (r and r.quantity) or 1
    local days = plan.rentalDays or "?"
    local grow, first = n, nil
    if q.kind == "permanent" then
        first = getText("IGUI_MVM_Slots_QuotePermanent", n)
    elseif ask.rental == nil then
        first = getText("IGUI_MVM_Slots_QuoteRental", n, days)
    elseif r and restarts(r) then
        first = getText("IGUI_MVM_Slots_QuoteRenewExpired", n, days)
    else
        first, grow = getText("IGUI_MVM_Slots_QuoteRenew", n, days), 0
    end
    local name = BU.currencyName(E, q.currency)
    local bal = type(env.balances) == "table" and env.balances[q.currency]
    local have, amount = bal and bal.available or 0, q.amount or 0
    local parts = { first }
    if r and q.kind ~= "permanent" and BU.termsDiffer(plan, r.terms) then
        -- 續租用目前方案的條款：先寫出這張租約原本的條款 → 新條款
        local was = r.terms
        parts[2] = getText("IGUI_MVM_Slots_QuoteTermsChange", (was.price or 0) * n, BU.currencyName(E, was.currency),
            was.days or 0, (plan.rentalPrice or 0) * n, BU.currencyName(E, plan.rentalCurrency), plan.rentalDays or 0)
    end
    parts[#parts + 1] = getText("IGUI_MVM_Slots_QuotePrice", amount, name)
    local opts = { title = getText("IGUI_MVM_SlotsTitle"), theme = theme, width = dialogWidth() }
    if have < amount then
        parts[#parts + 1] = getText("IGUI_MVM_Slots_QuoteShort", name, have, amount - have)
        opts.confirmText = getText("UI_Ok")
        opts.onResult = function() self.modal = nil end
    else
        parts[#parts + 1] = getText("IGUI_MVM_Slots_QuoteBalance", have, name, have - amount)
        local total = self.quota and self.quota.total
        if grow > 0 and total then parts[#parts + 1] = getText("IGUI_MVM_Slots_QuoteLimit", total + grow) end
        parts[#parts + 1] = getText("IGUI_MVM_Slots_QuoteNote")
        opts.confirmText, opts.cancelText = getText("IGUI_MVM_Btn_Pay"), getText("UI_Cancel")
        opts.onResult = function(ok) self.modal = nil; if ok then self:purchase(q) end end
    end
    opts.text = table.concat(parts, "\n")
    self.modal = UI.Dialog.show(opts)
end

function W:purchase(q)
    local E = BU.api()
    if E == nil or not self:canPurchase() then return end
    self.busy = "purchase"
    self:say(nil)
    -- 付款前保留 server 指定的識別；查詢只讀同一筆，不用其他新訂單猜測付款結果。
    self.order = { quoteId = q.id, orderId = q.orderId }
    local rid, why = E.purchase(SRC, q.id, function(res) self:onPurchase(res) end)
    if rid == nil then self.order = nil; self:localRefusal(why) end
end

function W:onPurchase(res)
    self.busy = nil
    local key = BU.purchaseKey(res)
    if key == nil then
        self.order = nil
        return self:say(BU.reasonText(res.error, BU.api()), "errorText")
    end
    self.order.orderId = self.order.orderId or res.orderId
    if key == "IGUI_MVM_Slots_Saved" or key == "IGUI_MVM_Slots_RolledBack" then self.order = nil end
    self:say(getText(key), key == "IGUI_MVM_Slots_RolledBack" and "errorText" or "accent")
end

-- 查詢只讀：優先查 server 在報價指定的 orderId；舊報價缺 orderId 時查原 quoteId，絕不重送購買。
function W:onCheckOrder()
    local E = BU.api()
    if E == nil or not self.live or self.busy then return end
    local o = self.order
    local ent = self.env and tbl(self.env.entitlement) or {}
    local id = o and (o.orderId or o.quoteId) or ent.pendingOrderId
    if id == nil then return end
    if o == nil then self.order = { orderId = id } end
    self.busy = "order"
    self:say(nil)
    local rid, why = E.getOrder(SRC, PROD, id, function(res) self:onOrder(res, id) end)
    if rid == nil then self:localRefusal(why) end
end

function W:onOrder(res, requestedId)
    self.busy = nil
    if res.unknown then return self:say(getText("IGUI_MVM_Slots_NoAnswer"), "accent") end
    if not res.ok then return self:say(BU.reasonText(res.error, BU.api()), "errorText") end
    local pending = self.order
    local order = type(res.order) == "table" and res.order or {}
    if pending and pending.orderId == nil and requestedId == pending.quoteId and res.known == true then
        pending.orderId = order.orderId
    end
    local sameOrder = pending and order.orderId ~= nil and order.orderId == pending.orderId
    local E = BU.api()
    local outcome = E and E.orderOutcome and E.orderOutcome(res) or "unknown"
    if not sameOrder or res.known ~= true then
        return self:say(getText("IGUI_MVM_Slots_NoAnswer"), "accent")
    end
    if outcome == "paid" or outcome == "refunded" or outcome == "not_paid" then self.order = nil end
    if outcome == "not_paid" then return self:say(getText("IGUI_MVM_Slots_NoOrder"), "accent") end
    local key = BU.durableKey(type(order.durable) == "table" and order.durable.status or nil)
    local text = getText(key)
    if order.status ~= nil and E and E.orderStatusText then text = E.orderStatusText(order.status) .. " - " .. text end
    self:say(text, key == "IGUI_MVM_Slots_RolledBack" and "errorText" or "accent")
end

-- 勾選狀態只跟 server：點擊後先還原，開啟要先確認該張租約的條款，關閉直接送；結果等快照（取消顯示待確認）
function W:onAutoRenew(checked, box)
    local env = tbl(self.env)
    local plan, ent = tbl(env.plan), tbl(env.entitlement)
    local r = box and BU.findRental(ent, box.internal)
    local on = r ~= nil and BU.autoRenewOn(r)
    if box then box:setChecked(on, true) end
    local E = BU.api()
    if r == nil or E == nil or not self.live or self.busy or checked == on then return end
    if not checked then return self:sendAutoRenew(false, ent, plan, r.id) end
    if not plan.autoRenewAllowed then return end
    local qn = r.quantity or 0
    self.modal = UI.Dialog.show({ title = getText("IGUI_MVM_SlotsTitle"), theme = theme, width = dialogWidth(),
        text = getText("IGUI_MVM_Slots_ConfirmAutoRenew", qn * (plan.rentalPrice or 0), BU.currencyName(E, plan.rentalCurrency),
            qn, plan.rentalDays or 0, plan.rentalPrice or 0),
        confirmText = getText("IGUI_MVM_Btn_TurnOn"), cancelText = getText("UI_Cancel"),
        onResult = function(ok) self.modal = nil; if ok then self:sendAutoRenew(true, ent, plan, r.id) end end })
end

function W:sendAutoRenew(enabled, ent, plan, rental)
    local E = BU.api()
    if E == nil or self.busy then return end
    self.busy = "autoRenew"
    self:say(nil)
    local rid, why = E.setAutoRenew(SRC, PROD, enabled, ent.revision, plan.revision, function(res)
        self.busy = nil
        if res.unknown then
            E.requestState(SRC, PROD)
            return self:say(getText("IGUI_MVM_Slots_AutoRenewUnknown"), "accent")
        end
        if not res.ok then return self:say(BU.reasonText(res.error, E), "errorText") end
        self:say(getText("IGUI_MVM_Slots_AutoRenewSent"), "accent")
    end, rental)
    if rid == nil then self:localRefusal(why) end
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

-- 方案與價格只在 Economy 管理頁維護（沙盒同步也在那裡），這裡只開入口
function W:onAdminPlans()
    local _, CL = BU.api()
    if not (CL and CL.openAdminPlans and CL.openAdminPlans(SRC, PROD)) then
        self:say(getText("IGUI_MVM_Slots_NoEconomyAdmin"), "errorText")
    end
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
    w.requested, w.dirty = false, true
    return w
end
