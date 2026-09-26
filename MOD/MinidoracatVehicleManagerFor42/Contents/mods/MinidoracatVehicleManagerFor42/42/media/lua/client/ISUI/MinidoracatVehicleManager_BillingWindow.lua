-- 綁定名額視窗（車隊視窗「名額」按鈕開啟）：基本／永久／租用／總計、租期與寬限、價格、錢包，
-- 以及買斷 +1、租用／續費、自動續費。付款全走 Economy client（MinidoracatEconomy.v1.Client.Entitlements，
-- late bind、不 require）：先 quote 取得 server 鎖定的報價，玩家看過摘要按「付款」才以同一張 quoteId purchase。
-- 規則：畫面只顯示 server 回來的狀態（不樂觀更新）；逾時＝結果未知，不自動重送、不換新報價，
-- 只提供「查詢購買結果」（唯讀讀同一筆 order）；自動續費預設關、勾選前先確認目前條款，送出後照 server 狀態顯示。
-- 伺服器整合狀態（fleetSnapshot 的 quota.economy）不是 READY 時只顯示原因、不呼叫 Economy（SP 也是）。
require "MinidoracatVehicleManager_API"
require "MinidoracatVehicleManager_Client"

local MVM = MinidoracatVehicleManager
local C = MVM.Client
local SRC, PROD = MVM.ECON_SOURCE, MVM.ECON_PRODUCT
local BU = {}
MVM.BillingUI = BU

-- ------------------------------------------------------------ 純邏輯（harness 可測） ---
-- Economy client 權益 facade；沒裝或舊版（rev < 2）回 nil
function BU.api()
    local EC = MinidoracatEconomy
    local CL = EC and EC.v1 and EC.v1.Client
    if CL and CL.API_MAJOR == 1 and (CL.API_REVISION or 0) >= 2 and type(CL.CAPABILITIES) == "table"
        and CL.CAPABILITIES.entitlements == true and type(CL.Entitlements) == "table" then
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

-- 租約仍有效：在期、寬限，或 paused_*（租約與到期時間有效，只是續租被條款變更／來源停用擋住）
local LEASE_LIVE = { active = true, grace = true, paused_terms = true, paused_system = true }

-- 已有有效租約時「租用」就是續費：延長同一組，不另外疊數量
function BU.renewing(ent)
    return (ent.rental or 0) > 0 and LEASE_LIVE[ent.state] == true
end

-- 暫停中的租約不能續租（server 會拒絕），按鈕停用
function BU.renewBlocked(ent)
    return ent.state == "paused_terms" or ent.state == "paused_system"
end

-- 舊授權即使因條款／系統暫停，仍須讓玩家取消；已送出取消則顯示未勾選。
function BU.autoRenewOn(ent)
    local state = ent.autoRenewState
    if state == "pending_off" then return false end
    return ent.autoRenew == true or state == "on" or state == "pending_on"
        or state == "paused_terms" or state == "paused_system"
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

local theme = UI.Theme.create({ colors = { surface = { r = 0.04, g = 0.045, b = 0.05, a = 0.95 } } })
local COL = theme.colors
local FS, FM = UIFont.Small, UIFont.Medium
local PAD, GAP, SCROLL_W = 12, 6, 6
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

local Body = ISPanel:derive("MVMSlotsBody")
function Body:prerender() self.slots:tick() end
-- 內容比可視高度高（大字級／小螢幕）時捲動：只畫完整落在可視範圍的列，右側畫細捲軸
function Body:render()
    local slots, h = self.slots, self.height
    for _, l in ipairs(slots.lines) do
        local y = l.y - slots.scroll
        if y >= 0 and y + fontH(l.font) <= h then
            local c = COL[l.token]
            self:drawText(l.text, PAD, y, c.r, c.g, c.b, c.a, l.font)
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
function Body:onMouseWheel(del)
    if self.slots.contentH <= self.height then return false end
    self.slots:setScroll(self.slots.scroll + del * (fontH(FS) + 2) * 3)
    return true
end
-- 右側留白＝捲軸點擊／拖曳區（控制項右緣不超過 PAD）；其餘位置維持 ISPanel 原行為
local function dragTo(body, y) body.slots:setScroll((body.slots.contentH - body.height) * y / body.height) end
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
    local self = setmetatable({ lines = {}, dirty = true, scroll = 0, contentH = 0 }, W)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w = math.min(560, sw - 40)
    self.win = UI.Window.new({ x = math.floor((sw - w) / 2), y = math.floor(sh / 4), width = w, height = 200,
        title = getText("IGUI_MVM_SlotsTitle"), icon = "coins", theme = theme })
    local top = self.win:contentTop()
    local body = Body:new(0, top, w, 100)
    body.background = false
    body.slots = self
    body:initialise()
    self.win:addChild(body)
    self.body = body
    local ch = fontH(FS) + 10
    local function button(key, fn, style, icon)
        local b = UI.Button.new({ x = 0, y = 0, height = ch, title = getText(key), style = style, icon = icon, theme = theme,
            target = self, onClick = fn })
        b:setVisible(false)
        body:addChild(b)
        return b
    end
    self.btnBuy = button("IGUI_MVM_Btn_BuyPermanent", W.onBuyPermanent, "primary")
    self.btnRent = button("IGUI_MVM_Btn_Rent", W.onRent, "primary")
    self.btnCheck = button("IGUI_MVM_Btn_CheckOrder", W.onCheckOrder)
    self.btnRefresh = button("IGUI_MVM_Btn_Refresh", W.onRefresh, "ghost", "reload")
    self.btnPlans = button("IGUI_MVM_Btn_ManagePlans", W.onAdminPlans, "ghost", "settings")
    self.autoBox = UI.Checkbox.new({ x = 0, y = 0, label = getText("IGUI_MVM_Slots_AutoRenew"), theme = theme, target = self,
        onChange = function(t, checked) t:onAutoRenew(checked) end })
    self.autoBox:setVisible(false)
    body:addChild(self.autoBox)
    self.controls = { self.btnBuy, self.btnRent, self.btnCheck, self.btnRefresh, self.btnPlans, self.autoBox }
    return self
end

function W:say(text, token)
    self.message, self.messageToken, self.dirty = text, token or "accent", true
end

function W:setScroll(v)
    local s = math.max(0, math.min(math.floor(v), self.contentH - self.body.height))
    if s ~= self.scroll then self.scroll, self.dirty = s, true end
end

function W:addText(s, token, font)
    font = font or FS
    local parts = {}
    wrap(parts, s, self.innerW, font)
    for _, t in ipairs(parts) do
        self.lines[#self.lines + 1] = { text = t, y = self.y, token = token or "text", font = font }
        self.y = self.y + fontH(font) + 2
    end
end

function W:section(key)
    self.y = self.y + GAP
    self:addText(getText(key), "textMuted", FM)
end

-- 由左至右擺一列控制項，放不下就換行
function W:placeRow(ctrls)
    local x, rowH = PAD, 0
    for _, c in ipairs(ctrls) do
        if x > PAD and x + c.width > PAD + self.innerW then x, self.y, rowH = PAD, self.y + rowH + GAP, 0 end
        c:setX(x)
        c.contentY = self.y
        c:setVisible(true)
        x = x + c.width + GAP
        rowH = math.max(rowH, c.height)
    end
    if rowH > 0 then self.y = self.y + rowH + GAP end
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
    self.env, self.quota, self.admin = env, b and b.quota, b and b.admin
    if self.live and env == nil and not self.requested then self:requestState() end
    for _, c in ipairs(self.controls) do c:setVisible(false) end
    self.lines, self.y, self.innerW = {}, PAD, self.win.width - PAD * 2

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
        local plan = type(env.plan) == "table" and env.plan or {}
        ent = type(env.entitlement) == "table" and env.entitlement or {}
        local st = ent.state or "none"
        local waiting = E.waitText(ent.wait)
        if waiting then self:addText(waiting, "accent") end
        -- termsRevision 只屬於租約或待確認租用；state 的 active／pending 也包含永久權益。
        if ent.termsRevision ~= nil then
            self:section("IGUI_MVM_Slots_Section_Rental")
            self:addText(getText("IGUI_MVM_Slots_RentalState", E.stateText and E.stateText(st) or st))
            local now = getTimestampMs()
            if st == "active" or BU.renewBlocked(ent) then
                local d, h = BU.timeLeft(ent.paidUntil, now)
                if d then self:addText(getText("IGUI_MVM_Slots_TimeLeft", d, h)) end
            elseif st == "grace" then
                local d, h = BU.timeLeft(ent.graceUntil, now)
                if d then self:addText(getText("IGUI_MVM_Slots_GraceLeft", d * 24 + h), "accent") end
            elseif st == "expired" then
                self:addText(getText("IGUI_MVM_Slots_Expired"), "textMuted")
            end
            local ar = ent.autoRenewState or "off"
            local on = BU.autoRenewOn(ent)
            if plan.autoRenewAllowed or on or ar == "pending_off" then
                self.autoBox:setChecked(on, true)
                self.autoBox:setEnabled(self.busy == nil and (on or plan.autoRenewAllowed == true))
                self:placeRow({ self.autoBox })
                self:addText(getText("IGUI_MVM_Slots_AutoRenewState", E.autoRenewText and E.autoRenewText(ar) or ar), "textMuted")
                if ar == "paused_terms" then self:addText(getText("IGUI_MVM_Slots_AutoRenewPausedTerms"), "accent") end
            else
                self:addText(getText("IGUI_MVM_Slots_AutoRenewNotOffered"), "textMuted")
            end
        end
        -- 購買：價格、上限、錢包
        self:section("IGUI_MVM_Slots_Section_Buy")
        if env.available == false then self:addText(getText("IGUI_MVM_Slots_Paused"), "accent") end
        local row, currencies = {}, {}
        if plan.permanentEnabled then
            self:addText(getText("IGUI_MVM_Slots_PermanentPrice", plan.permanentPrice, BU.currencyName(E, plan.permanentCurrency)))
            currencies[#currencies + 1] = plan.permanentCurrency
            if (ent.permanent or 0) >= (plan.permanentLimit or 0) then
                self:addText(getText("IGUI_MVM_Slots_PermanentLimit", plan.permanentLimit or 0), "textMuted")
            else
                row[#row + 1] = self.btnBuy
            end
        else
            self:addText(getText("IGUI_MVM_Slots_PermanentOff"), "textMuted")
        end
        if plan.rentalEnabled then
            self:addText(getText("IGUI_MVM_Slots_RentalPrice", plan.rentalQuantity, plan.rentalDays, plan.rentalPrice,
                BU.currencyName(E, plan.rentalCurrency)))
            if plan.rentalCurrency ~= plan.permanentCurrency or not plan.permanentEnabled then
                currencies[#currencies + 1] = plan.rentalCurrency
            end
            self.btnRent:setTitle(getText(BU.renewing(ent) and "IGUI_MVM_Btn_Renew" or "IGUI_MVM_Btn_Rent"))
            row[#row + 1] = self.btnRent
        else
            self:addText(getText("IGUI_MVM_Slots_RentalOff"), "textMuted")
        end
        for _, id in ipairs(currencies) do
            local bal = type(env.balances) == "table" and env.balances[id]
            self:addText(getText("IGUI_MVM_Slots_Balance", BU.currencyName(E, id), bal and bal.available or 0), "textMuted")
        end
        -- 任何未結清購買（包含 pending）都擋新購買；按鈕與操作入口共用同一判定。
        local canBuy = self:canPurchase()
        for _, bt in ipairs(row) do bt:setEnabled(canBuy and not (bt == self.btnRent and BU.renewBlocked(ent))) end
        self:placeRow(row)
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
    self.contentH = self.y + PAD
    local h = math.min(self.contentH, getCore():getScreenHeight() - top - 20)
    -- 控制項放到捲動後的位置；不完整可見的暫時隱藏（看不到的不能點）
    self.scroll = math.max(0, math.min(self.scroll, self.contentH - h))
    for _, c in ipairs(self.controls) do
        if c:getIsVisible() then
            local y = c.contentY - self.scroll
            c:setY(y)
            if y < 0 or y + c.height > h then c:setVisible(false) end
        end
    end
    self.body:setHeight(h)
    self.win:setHeight(top + h)
end

-- ------------------------------------------------------------------ 操作 ---
-- 失敗（本機拒絕：invalid_args／pending／queue_full）時不改狀態，只顯示原因
function W:localRefusal(why)
    self.busy = nil
    self:say(BU.reasonText(why or "invalid_args", BU.api()), "errorText")
end

function W:canPurchase()
    local env = self.env
    if not self.live or self.busy or self.order or not env or env.ok == false or env.available == false then return false end
    local ent = type(env.entitlement) == "table" and env.entitlement or {}
    return ent.pendingOrderId == nil and (ent.pendingQuantity or 0) == 0
end

function W:onBuyPermanent() self:startQuote("permanent") end
function W:onRent() self:startQuote("rental") end

function W:startQuote(kind)
    local E = BU.api()
    if E == nil or not self:canPurchase() then return end
    self.busy = "quote"
    self:say(nil)
    local rid, why = E.quote(SRC, PROD, kind, 1, function(res) self:onQuote(res) end)
    if rid == nil then self:localRefusal(why) end
end

-- 報價摘要＝最後確認：付款、數量、期間、幣別與付款後餘額；餘額不足只告知缺額，不提供付款
function W:onQuote(res)
    self.busy, self.dirty = nil, true
    if res.unknown then return self:say(getText("IGUI_MVM_Slots_QuoteNoAnswer"), "accent") end
    if not res.ok or type(res.quote) ~= "table" then return self:say(BU.reasonText(res.error, BU.api()), "errorText") end
    local E = BU.api()
    local q = res.quote
    local env = type(res.snapshot) == "table" and res.snapshot or self.env or {}
    local plan = type(env.plan) == "table" and env.plan or {}
    local ent = type(env.entitlement) == "table" and env.entitlement or {}
    local name = BU.currencyName(E, q.currency)
    local bal = type(env.balances) == "table" and env.balances[q.currency]
    local have = bal and bal.available or 0
    local parts = {}
    if q.kind == "permanent" then
        parts[1] = getText("IGUI_MVM_Slots_QuotePermanent")
    else
        parts[1] = getText(BU.renewing(ent) and "IGUI_MVM_Slots_QuoteRenew" or "IGUI_MVM_Slots_QuoteRental",
            plan.rentalQuantity or q.quantity, plan.rentalDays or "?")
    end
    parts[2] = getText("IGUI_MVM_Slots_QuotePrice", q.amount, name)
    local opts = { title = getText("IGUI_MVM_SlotsTitle"), theme = theme, width = dialogWidth() }
    if have < (q.amount or 0) then
        parts[3] = getText("IGUI_MVM_Slots_QuoteShort", name, have, q.amount - have)
        opts.text, opts.confirmText = table.concat(parts, "\n", 1, 3), getText("UI_Ok")
        opts.onResult = function() self.modal = nil end
    else
        parts[3] = getText("IGUI_MVM_Slots_QuoteBalance", have, name, have - q.amount)
        parts[4] = getText("IGUI_MVM_Slots_QuoteNote")
        opts.text, opts.confirmText, opts.cancelText = table.concat(parts, "\n", 1, 4), getText("IGUI_MVM_Btn_Pay"), getText("UI_Cancel")
        opts.onResult = function(ok) self.modal = nil; if ok then self:purchase(q) end end
    end
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
    local ent = self.env and type(self.env.entitlement) == "table" and self.env.entitlement or {}
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

-- 勾選狀態只跟 server：點擊後先還原，開啟要先確認目前條款，關閉直接送；結果等快照（取消顯示待確認）
function W:onAutoRenew(checked)
    local env = self.env or {}
    local plan = type(env.plan) == "table" and env.plan or {}
    local ent = type(env.entitlement) == "table" and env.entitlement or {}
    local on = BU.autoRenewOn(ent)
    self.autoBox:setChecked(on, true)
    local E = BU.api()
    if E == nil or not self.live or self.busy or checked == on then return end
    if not checked then return self:sendAutoRenew(false, ent, plan) end
    if not plan.autoRenewAllowed then return end
    self.modal = UI.Dialog.show({ title = getText("IGUI_MVM_SlotsTitle"), theme = theme, width = dialogWidth(),
        text = getText("IGUI_MVM_Slots_ConfirmAutoRenew", plan.rentalPrice, BU.currencyName(E, plan.rentalCurrency),
            plan.rentalQuantity, plan.rentalDays),
        confirmText = getText("IGUI_MVM_Btn_TurnOn"), cancelText = getText("UI_Cancel"),
        onResult = function(ok) self.modal = nil; if ok then self:sendAutoRenew(true, ent, plan) end end })
end

function W:sendAutoRenew(enabled, ent, plan)
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
    end)
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
