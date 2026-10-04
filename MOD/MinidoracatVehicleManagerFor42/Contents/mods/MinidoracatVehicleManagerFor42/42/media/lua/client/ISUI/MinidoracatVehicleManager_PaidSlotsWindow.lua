-- 付費名額設定視窗（管理員；入口：車隊視窗管理頁、名額視窗頁尾）。方案（價格、幣別、上限、天數、開關）歸本 MOD，
-- 伺服器存在 paid-slots.json 並交給 Economy setPlan；這裡只透過 adminPaidSlots 指令讀（GET）與套用（SET）。
-- 版面照管理端設計稿：買斷／租用兩組，改過的欄位標「原 X」，寬限、提醒、允許自動續租收在「進階設定」；
-- 套用前列出變更前後與這次會影響的事，原因必填（寫入稽核）。
-- 伺服器方案版本變了（SET 回 STALE_REVISION，或 Economy 推播的方案版本與草稿基準不同）就重新 GET：
-- 沒改的欄位換成最新值、改過的保留，橫幅說明誰改了什麼。伺服器照樣比對版本，不會蓋掉別人的修改。
-- 內容放不下（大字級、小螢幕、展開進階設定）時捲動，頁尾（狀態、已修改 N 項、放棄／套用）固定在視窗底部；
-- 鍵盤／手把目標列出全部控制項，落點前先捲進可視範圍（同名額視窗，知識庫 guards.md「已知坑」）。
require "MinidoracatVehicleManager_API"
require "MinidoracatVehicleManager_Client"
require "ISUI/MinidoracatVehicleManager_BillingWindow"

local MVM = MinidoracatVehicleManager
local C = MVM.Client
local SRC, PROD = MVM.ECON_SOURCE, MVM.ECON_PRODUCT
local PS = {}
MVM.PaidSlotsUI = PS

-- ------------------------------------------------------------ 純邏輯（harness 可測） ---
local function tbl(t) return type(t) == "table" and t or {} end

-- 方案 12 欄（Economy P.FIELDS）與設定檔鍵名（契約第 4 節）
PS.FIELDS = {
    { key = "permanentEnabled", file = "buy.enabled", kind = "bool" },
    { key = "permanentPrice", file = "buy.price", kind = "int" },
    { key = "permanentCurrency", file = "buy.currency", kind = "currency" },
    { key = "permanentLimit", file = "buy.limit", kind = "int" },
    { key = "rentalEnabled", file = "rent.enabled", kind = "bool" },
    { key = "rentalPrice", file = "rent.price", kind = "int" },
    { key = "rentalCurrency", file = "rent.currency", kind = "currency" },
    { key = "rentalDays", file = "rent.days", kind = "int" },
    { key = "rentalLimit", file = "rent.limit", kind = "int" },
    { key = "graceHours", file = "rent.graceHours", kind = "int" },
    { key = "reminderHours", file = "rent.reminderHours", kind = "int" },
    { key = "autoRenewAllowed", file = "rent.autoRenew", kind = "bool" },
}
local SPEC, BY_FILE = {}, {}
for _, f in ipairs(PS.FIELDS) do SPEC[f.key], BY_FILE[f.file] = f, f end
PS.SPEC, PS.BY_FILE = SPEC, BY_FILE
-- 整數欄最多打幾位：要放得下 Economy 允許的最大價格 1000000000（10 位）；範圍由 Economy 驗證
PS.INPUT_DIGITS = 10

-- 由左而右排一串寬度：放不下（超過 right）就換到下一行、從 wrapX 開始；每行第一個一定放（不無限換行）。
-- 回 每個的 x, 每個在第幾行（0 起）, 總行數
function PS.flow(widths, x, wrapX, right, gap)
    local xs, rows, row = {}, {}, 0
    for i, w in ipairs(widths) do
        if x + w > right and x > wrapX then x, row = wrapX, row + 1 end
        xs[i], rows[i] = x, row
        x = x + w + gap
    end
    return xs, rows, row + 1
end

local function num(v)
    if type(v) == "number" then return v end
    local s = tostring(v or "")
    return s:match("^%d+$") and tonumber(s) or nil
end

function PS.name(key) return getText("IGUI_MVM_Paid_Name_" .. key) end

function PS.trim(s)
    local t = tostring(s or ""):gsub("^%s+", "")
    t = t:gsub("%s+$", "")
    return t
end

-- 草稿值 → 送出的型別；整數欄不是非負整數回 nil
function PS.typed(spec, v)
    if spec.kind == "int" then return num(v) end
    return v
end

-- 草稿與方案值相同（整數欄比數值；草稿不是整數就算不同）
function PS.same(spec, a, b)
    if spec.kind == "int" then
        local x = num(a)
        return x ~= nil and x == num(b)
    end
    return a == b
end

-- 方案 → 草稿：整數欄存成輸入框文字
function PS.draftOf(plan)
    local d = {}
    for _, f in ipairs(PS.FIELDS) do
        local v = plan[f.key]
        if f.kind == "int" then d[f.key] = type(v) == "number" and tostring(math.floor(v)) or "" else d[f.key] = v end
    end
    return d
end

-- 草稿和基準不同的欄位（依 FIELDS 順序）
function PS.changes(base, draft)
    local out = {}
    for _, f in ipairs(PS.FIELDS) do
        if not PS.same(f, draft[f.key], base[f.key]) then out[#out + 1] = f.key end
    end
    return out
end

-- 整份 12 欄、型別正確；有整數欄不合法回 nil, 那一欄
function PS.payload(draft)
    local out = {}
    for _, f in ipairs(PS.FIELDS) do
        local v = PS.typed(f, draft[f.key])
        if v == nil then return nil, f.key end
        out[f.key] = v
    end
    return out
end

-- 伺服器方案從 oldBase 變成 newBase：草稿裡沒改的欄位跟新值、改過的保留。回 新草稿, 別人改了的欄位
function PS.rebase(oldBase, newBase, draft)
    local fresh, out, others = PS.draftOf(newBase), {}, {}
    for _, f in ipairs(PS.FIELDS) do
        local k = f.key
        if PS.same(f, draft[k], oldBase[k]) then out[k] = fresh[k] else out[k] = draft[k] end
        if not PS.same(f, newBase[k], oldBase[k]) then others[#others + 1] = k end
    end
    return out, others
end

-- 這次變更會影響的事（只列真的會發生的）：{ 鍵, 參數? }
function PS.impacts(base, draft)
    local out = {}
    local function changed(k) return not PS.same(SPEC[k], draft[k], base[k]) end
    local function lowered(k)
        local n = num(draft[k])
        return n ~= nil and n < (num(base[k]) or 0) and n
    end
    if base.rentalEnabled and draft.rentalEnabled == false then
        out[#out + 1] = { "IGUI_MVM_Paid_Impact_RentOff" }
    else
        if changed("rentalPrice") or changed("rentalCurrency") or changed("rentalDays") then
            out[#out + 1] = { "IGUI_MVM_Paid_Impact_RentTerms" }
        end
        local n = lowered("rentalLimit")
        if n then out[#out + 1] = { "IGUI_MVM_Paid_Impact_RentLimit", n } end
        if base.autoRenewAllowed and draft.autoRenewAllowed == false then out[#out + 1] = { "IGUI_MVM_Paid_Impact_AutoOff" } end
    end
    if base.permanentEnabled and draft.permanentEnabled == false then
        out[#out + 1] = { "IGUI_MVM_Paid_Impact_BuyOff" }
    else
        local n = lowered("permanentLimit")
        if n then out[#out + 1] = { "IGUI_MVM_Paid_Impact_BuyLimit", n } end
    end
    return out
end

function PS.valueText(spec, v, currencyName)
    if spec.kind == "bool" then return getText(v and "IGUI_MVM_Paid_On" or "IGUI_MVM_Paid_Off") end
    if spec.kind == "currency" then return currencyName(v) end
    return tostring(num(v) or v or "")
end

-- 一筆變更：「名稱：舊 改為 新」（short＝橫幅用的短格式）
function PS.changeLine(key, from, to, currencyName, short)
    local spec = SPEC[key]
    return getText(short and "IGUI_MVM_Paid_ChangeShort" or "IGUI_MVM_Paid_ChangeLine", PS.name(key),
        PS.valueText(spec, from, currencyName), PS.valueText(spec, to, currencyName))
end

local function actorText(lc)
    if lc.origin == "file" then return getText("IGUI_MVM_Paid_FileActor") end
    return tostring(lc.actor or "?")
end

-- 上次修改：誰（設定檔或管理員）與原因
function PS.lastText(lc)
    local reason = type(lc.reason) == "string" and PS.trim(lc.reason) or ""
    if reason == "" then return getText("IGUI_MVM_Paid_LastByNoReason", actorText(lc)) end
    return getText("IGUI_MVM_Paid_LastBy", actorText(lc), reason)
end

-- 別人改了方案的橫幅：誰、改了什麼；kept＝我有未套用的修改（保留）
function PS.bannerText(lc, others, oldBase, newBase, kept, currencyName)
    local parts = {}
    for i, k in ipairs(others) do parts[i] = PS.changeLine(k, oldBase[k], newBase[k], currencyName, true) end
    return getText(kept and "IGUI_MVM_Paid_BannerKept" or "IGUI_MVM_Paid_Banner", actorText(tbl(lc)),
        table.concat(parts, getText("IGUI_MVM_Sep"), 1, #parts))
end

-- 狀態檔的錯誤碼 → 說明（field 用設定檔鍵名）；沒有譯文的碼照原樣列出
function PS.fileErrorText(code, field)
    local key = "IGUI_MVM_Paid_FileErr_" .. tostring(code)
    if getText(key) == key then return getText("IGUI_MVM_Paid_FileErr_other", tostring(code), tostring(field or "")) end
    return getText(key, tostring(field or ""))
end

-- ------------------------------------------------------------------ 視窗 ---
local BU = MVM.BillingUI
local UI = MinidoracatUI and MinidoracatUI.v1
local CAPS = UI and UI.CAPABILITIES
-- 幣別選擇用 chip 樣式與 Button:setActive（框架 rev 11）；不足時不建視窗，入口改說明需要更新框架
if not (BU and UI and UI.API_MAJOR == 1 and (UI.API_REVISION or 0) >= 11 and CAPS and CAPS.window and CAPS.controls
    and CAPS.dialog) then
    MVM.log("Paid slot settings need MinidoracatUI API 1 rev 11 with window/controls/dialog")
    return
end

local Focus = CAPS.focus and UI.Focus or nil
local theme = UI.Theme.create({ colors = { surface = { r = 0.04, g = 0.045, b = 0.05, a = 1 },
    card = { r = 0.085, g = 0.09, b = 0.1, a = 1 } } })
local COL = theme.colors
local FS, FM = UIFont.Small, UIFont.Medium
local PAD, GAP, SCROLL_W = 12, 6, 6
-- 捲出可視範圍的輸入框停到這裡（仍可見）：Focus 只在描述的 scrollOwner 可用時才先請它捲動（Focus.lua land），
-- 輸入框描述的 control 是內層原生 entry，它的 parent 是 TextField，所以 scrollOwner 只能是 TextField 本身
local PARK_X = -100000
local LAYOUT = "MinidoracatVehicleManagerPaidSlots"
local ADVANCED = { "graceHours", "reminderHours", "autoRenewAllowed" }

local function fontH(font) return getTextManager():getFontHeight(font) end
local function measure(s, font) return getTextManager():MeasureStringX(font, s) end
local function currencyName(id) return BU.currencyName(BU.api(), id) end

local P = {}
P.__index = P
MVM.PaidSlotsWindow = P

function P:inView(c)
    local y = c.contentY - self.scroll
    return y >= 0 and y + c.height <= self.body.height
end

-- 滑鼠把焦點下的控制項捲出可視範圍：焦點改到第一個看得見的控制項、不畫框（同名額視窗的 keepFocus）。
-- 輸入框的焦點在內層原生 entry，先換回 body 底下的 TextField 再判斷
local function keepFocus(w)
    local c = Focus and Focus.focused()
    if c == nil then return end
    if c.parent ~= w.body then c = c.parent end
    if c == nil or c.parent ~= w.body or c.contentY == nil or w:inView(c) then return end
    for _, p in ipairs(w.placed) do
        if p._entry == nil and w:inView(p) and Focus.focusControl(p, false) then return end
    end
end

local Body = ISPanel:derive("MVMPaidSlotsBody")
-- 改過的欄位底色＋左側色條、橫幅外框畫在控制項之前；只畫可視範圍內的部分
function Body:prerender()
    local w = self.owner
    if w.dirty then w:layout() end
    local h, s = self.height, w.scroll
    for _, f in ipairs(w.fills) do
        local y0, y1 = math.max(0, f.y - s), math.min(h, f.y + f.h - s)
        if f.border then
            if y0 == f.y - s and y1 == f.y + f.h - s then theme:border(self, f.x, y0, f.w, f.h, f.token, "round") end
        elseif y1 > y0 then
            theme:fill(self, f.x, y0, f.w, y1 - y0, f.token, "rect")
        end
    end
end
-- 只畫完整落在可視範圍的文字列；內容比可視高度高時右側畫細捲軸
function Body:render()
    local w, h = self.owner, self.height
    for _, l in ipairs(w.lines) do
        local y = l.y - w.scroll
        if y >= 0 and y + fontH(l.font) <= h then
            local c = COL[l.token]
            self:drawText(l.text, l.x, y, c.r, c.g, c.b, c.a, l.font)
        end
    end
    local max = w.contentH - h
    if max > 0 then
        local thumb = math.max(20, math.floor(h * h / w.contentH))
        local t, c = COL.well, COL.textFaint
        self:drawRect(self.width - SCROLL_W, 0, 4, h, t.a, t.r, t.g, t.b)
        self:drawRect(self.width - SCROLL_W, math.floor((h - thumb) * w.scroll / max), 4, thumb, c.a, c.r, c.g, c.b)
    end
end
-- Focus 落點前呼叫（描述的 scrollOwner；輸入框經 TextField.scrollTo 轉來）：整列捲進可視範圍
function Body:scrollTo(control) self.owner:scrollTo(control) end
function Body:onMouseWheel(del)
    local w = self.owner
    if w.contentH <= self.height then return false end
    w:setScroll(w.scroll + del * (fontH(FS) + 2) * 3)
    keepFocus(w)
    return true
end
-- 右側留白＝捲軸點擊／拖曳區（控制項右緣不超過 PAD）；拖曳期間捕捉滑鼠（同原版 ISScrollBar）
local function dragTo(body, y)
    local w = body.owner
    w:setScroll((w.contentH - body.height) * y / body.height)
    keepFocus(w)
end
local function stopDrag(body)
    if body.dragging then body.dragging = false; body:setCapture(false) end
end
function Body:onMouseDown(x, y)
    if self.owner.contentH <= self.height or x < self.width - PAD then return ISPanel.onMouseDown(self, x, y) end
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

-- 頁尾（狀態訊息、已修改 N 項、放棄修改／套用變更）固定在視窗底部，不隨內容捲動
local Foot = ISPanel:derive("MVMPaidSlotsFoot")
function Foot:prerender()
    theme:fill(self, PAD, 0, self.width - PAD * 2, 1, "border", "rect")
end
function Foot:render()
    for _, l in ipairs(self.owner.footLines) do
        local c = COL[l.token]
        self:drawText(l.text, l.x, l.y, c.r, c.g, c.b, c.a, FS)
    end
end

function P.new()
    local self = setmetatable({ lines = {}, fills = {}, controls = {}, chipPool = {}, placed = {}, footLines = {},
        footPlaced = {}, footControls = {}, focusList = {}, focusPool = {}, dirty = true, scroll = 0, contentH = 0 }, P)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w = math.min(600, sw - 40)
    self.autoY = math.floor((sh - 400) / 2)
    self.win = UI.Window.new({ x = math.floor((sw - w) / 2), y = self.autoY, width = w, height = 200,
        title = getText("IGUI_MVM_Btn_PaidSettings"), icon = "settings", theme = theme })
    -- 鍵盤／手把目標＝排版記下的全部控制項（含捲出可視範圍的），描述帶 scrollOwner，落點前先捲過去
    self.win.keyboardTargets = function() return self.focusList end
    local body = Body:new(0, self.win:contentTop(), w, 100)
    body.background = false
    body.owner = self
    body:initialise()
    self.win:addChild(body)
    self.body = body
    local foot = Foot:new(0, self.win:contentTop() + 100, w, 40)
    foot.background = false
    foot.owner = self
    foot:initialise()
    self.win:addChild(foot)
    self.foot = foot
    self.ch = fontH(FS) + 10
    self.boxes, self.inputs, self.labelW = {}, {}, 0
    for _, f in ipairs(PS.FIELDS) do
        local k = f.key
        if f.kind == "bool" then
            self.boxes[k] = self:adopt(UI.Checkbox.new({ x = 0, y = 0, label = PS.name(k), theme = theme, target = self,
                onChange = function(t, checked) t:edit(k, checked) end }))
        elseif f.kind == "int" then
            local input = self:adopt(UI.TextField.new({ x = 0, y = 0, width = 90, height = self.ch, onlyNumbers = true,
                maxLength = PS.INPUT_DIGITS, theme = theme, onChange = function(_, text) self:edit(k, text) end }))
            input.scrollTo = function(field) self:scrollTo(field) end
            self.inputs[k] = input
            self.labelW = math.max(self.labelW, measure(PS.name(k), FS))
        end
    end
    self.btnAdvanced = self:button(getText("IGUI_MVM_Paid_Advanced"), P.onAdvanced, "ghost")
    self.btnReload = self:footButton(getText("IGUI_MVM_Btn_Refresh"), P.load, "ghost", "reload")
    self.btnDiscard = self:footButton(getText("IGUI_MVM_Btn_Discard"), P.onDiscard)
    self.btnApply = self:footButton(getText("IGUI_MVM_Btn_ApplyChanges"), P.onApply, "primary")
    self.btnDiscard._focusGroup, self.btnApply._focusGroup = "foot", "foot"
    return self
end

function P:adopt(c)
    c:setVisible(false)
    self.body:addChild(c)
    self.controls[#self.controls + 1] = c
    return c
end

function P:button(title, fn, style, icon)
    return self:adopt(UI.Button.new({ x = 0, y = 0, height = self.ch, title = title, style = style, icon = icon,
        theme = theme, target = self, onClick = fn }))
end

function P:footButton(title, fn, style, icon)
    local b = UI.Button.new({ x = 0, y = 0, height = self.ch, title = title, style = style, icon = icon,
        theme = theme, target = self, onClick = fn })
    b:setVisible(false)
    self.foot:addChild(b)
    self.footControls[#self.footControls + 1] = b
    return b
end

-- 幣別選擇鈕（chip）：伺服器註冊的幣別，加上方案與草稿目前用的（萬一它已不在清單裡）
function P:chips(key)
    local ids, seen = {}, {}
    local function add(id)
        if type(id) == "string" and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
    end
    for _, id in ipairs(tbl(self.data.currencies)) do add(id) end
    add(self.base[key])
    add(self.draft[key])
    local pool = self.chipPool[key] or {}
    self.chipPool[key] = pool
    local out = {}
    for i, id in ipairs(ids) do
        local b = pool[i]
        if b == nil then
            b = self:adopt(UI.Button.new({ x = 0, y = 0, height = self.ch, title = "", style = "chip", theme = theme,
                target = self, onClick = P.onChip }))
            b.fieldKey, b._focusGroup = key, "chips_" .. key
            pool[i] = b
        end
        b.internal = id
        b:setTitle(currencyName(id))
        b:setActive(self.draft[key] == id)
        b:setEnabled(self.busy == nil)
        out[i] = b
    end
    return out
end

function P:say(text, token)
    self.message, self.messageToken, self.dirty = text, token or "text", true
end

function P:textAt(s, x, y, token, font)
    self.lines[#self.lines + 1] = { text = s, x = x, y = y, token = token or "text", font = font or FS }
end

function P:addText(s, token, x, width)
    local parts = {}
    BU.wrap(parts, s, width or self.innerW, FS, measure)
    for _, t in ipairs(parts) do
        self:textAt(t, x or PAD, self.y, token)
        self.y = self.y + fontH(FS) + 2
    end
end

-- 控制項排進內容的這一列（列內垂直置中）；捲動時依 contentY 重放。輸入框一排上就保持可見（見 PARK_X）
function P:put(c, x, rowY, rowH)
    c.contentX, c.contentY = x, rowY + math.floor((rowH - c.height) / 2)
    c.scrollTop, c.scrollBottom = rowY, rowY + rowH
    c:setX(x)
    if c._entry then c.onPage = true; c:setVisible(true) end
    self.placed[#self.placed + 1] = c
    return x + c.width + GAP
end

-- 捲動並當場重放：按鈕與開關只在完整落在可視範圍時顯示（看不到的不能用滑鼠點）；輸入框改停到畫面外，
-- 正在輸入的先放掉鍵盤，看不見的框不吃按鍵
function P:setScroll(v)
    local h = self.body.height
    self.scroll = math.max(0, math.min(math.floor(v), self.contentH - h))
    for _, c in ipairs(self.placed) do
        local seen = self:inView(c)
        c:setY(c.contentY - self.scroll)
        if c._entry then
            c:setX(seen and c.contentX or PARK_X)
            if not seen and c:isFocused() then c._entry:unfocus() end
        else
            c:setVisible(seen)
        end
    end
end

-- 把控制項那一列連同它上方的說明（scrollTop）捲進可視範圍；放不下就至少讓控制項完整可見
function P:scrollTo(control)
    local h = self.body.height
    local top, bottom = control.scrollTop or control.contentY, control.scrollBottom or (control.contentY + control.height)
    if bottom - top > h then top, bottom = control.contentY, control.contentY + control.height end
    if top < self.scroll then
        self:setScroll(top)
    elseif bottom > self.scroll + h then
        self:setScroll(bottom - h)
    end
end

-- 焦點描述（排版順序）：輸入框一個 entry 描述（scrollOwner＝TextField 本身），其餘連續同 _focusGroup 的
-- 併成一組（scrollOwner＝body）；頁尾控制項排最後、不捲動。描述 table 重用（Focus 每幀讀）
function P:buildFocus()
    local list, pool, n = self.focusList, self.focusPool, 0
    local function run(cs, owner)
        local i = 1
        while i <= #cs do
            n = n + 1
            local d = pool[n]
            if d == nil then d = { controls = {} }; pool[n] = d end
            list[n] = d
            local c = cs[i]
            if c._entry then
                d.kind, d.control, d.frame, d.scrollOwner = "entry", c._entry, c, c
                i = i + 1
            else
                d.kind, d.control, d.frame, d.scrollOwner = "group", nil, nil, owner
                local m, group = 0, c._focusGroup
                while i <= #cs and cs[i]._entry == nil and (m == 0 or (group ~= nil and cs[i]._focusGroup == group)) do
                    local g = cs[i]
                    m = m + 1
                    d.controls[m] = g
                    if d.control == nil and g.enable ~= false and g._enabled ~= false then d.control = g end
                    i = i + 1
                end
                for k = #d.controls, m + 1, -1 do d.controls[k] = nil end
                d.control = d.control or d.controls[1]
            end
        end
    end
    run(self.placed, self.body)
    run(self.footPlaced, nil)
    for k = #list, n + 1, -1 do list[k] = nil end
end

function P:changed(key) return not PS.same(SPEC[key], self.draft[key], self.base[key]) end

-- 改過的列：整列底色＋左側金色色條
function P:markRow(rowY, rowH)
    self.fills[#self.fills + 1] = { x = PAD, y = rowY - 2, w = self.innerW, h = rowH + 4, token = "card" }
    self.fills[#self.fills + 1] = { x = PAD, y = rowY - 2, w = 3, h = rowH + 4, token = "accent" }
end

-- 欄位右邊的註記：伺服器不接受／不是整數（紅）或「原 X」（灰）；沒有註記回 nil
function P:noteText(keys)
    local text, token, was = nil, "textMuted", {}
    for _, k in ipairs(keys) do
        if self.badField == k then
            text, token = getText("IGUI_MVM_Paid_Rejected"), "errorText"
        elseif text == nil and PS.typed(SPEC[k], self.draft[k]) == nil then
            text, token = getText("IGUI_MVM_Paid_NeedInt"), "errorText"
        elseif self:changed(k) then
            was[#was + 1] = PS.valueText(SPEC[k], self.base[k], currencyName)
        end
    end
    if text == nil and #was > 0 then text = getText("IGUI_MVM_Paid_Was", table.concat(was, " ", 1, #was)) end
    return text, token
end

function P:note(keys, x, rowY, rowH)
    local text, token = self:noteText(keys)
    if text then self:textAt(text, x, rowY + math.floor((rowH - fontH(FS)) / 2), token) end
end

-- 段標題（白字）＋開放開關
function P:sectionRow(titleKey, key)
    self.y = self.y + GAP
    local title, box = getText(titleKey), self.boxes[key]
    box:setChecked(self.draft[key] == true, true)
    local rowY, rowH = self.y, math.max(fontH(FM), box.height)
    if self:changed(key) then self:markRow(rowY, rowH) end
    self:textAt(title, PAD + 8, rowY + math.floor((rowH - fontH(FM)) / 2), "text", FM)
    local x = self:put(box, PAD + 8 + measure(title, FM) + 12, rowY, rowH)
    self:note({ key }, x, rowY, rowH)
    self.y = rowY + rowH + GAP
end

-- 一列：名稱、數字欄、（價格列）幣別選擇、註記。幣別與註記放不下就換到下一行、對齊輸入框左緣
function P:fieldRow(key, curKey)
    local rowY, rowH = self.y, self.ch
    local input = self.inputs[key]
    input:setEnabled(self.busy == nil)
    local ix = PAD + 8 + self.labelW + GAP
    local chips = curKey and self:chips(curKey) or {}
    local text, token = self:noteText({ key, curKey })
    local widths = {}
    for i, b in ipairs(chips) do widths[i] = b.width end
    if text then widths[#widths + 1] = measure(text, FS) end
    local xs, rows, n = PS.flow(widths, ix + input.width + GAP, ix, PAD + self.innerW, GAP)
    local h = n * rowH + (n - 1) * GAP
    if self:changed(key) or (curKey and self:changed(curKey)) then self:markRow(rowY, h) end
    self:textAt(PS.name(key), PAD + 8, rowY + math.floor((rowH - fontH(FS)) / 2), "text")
    self:put(input, ix, rowY, rowH)
    for i, b in ipairs(chips) do
        self:put(b, xs[i], rowY + rows[i] * (rowH + GAP), rowH)
        b.scrollTop = rowY -- 落點時連同這一欄的名稱一起捲進來
    end
    if text then
        local i = #widths
        self:textAt(text, xs[i], rowY + rows[i] * (rowH + GAP) + math.floor((rowH - fontH(FS)) / 2), token)
    end
    self.y = rowY + h + GAP
end

function P:boxRow(key)
    local box, rowY = self.boxes[key], self.y
    local rowH = math.max(self.ch, box.height)
    box:setChecked(self.draft[key] == true, true)
    if self:changed(key) then self:markRow(rowY, rowH) end
    local x = self:put(box, PAD + 8, rowY, rowH)
    self:note({ key }, x, rowY, rowH)
    self.y = rowY + rowH + GAP
end

function P:layoutForm(d)
    self:addText(getText("IGUI_MVM_Paid_File", tostring(d.file or "")), "textMuted")
    local st = tbl(d.status)
    if st.state == "error" then self:addText(getText("IGUI_MVM_Paid_FileError", PS.fileErrorText(st.error, st.field)), "errorText") end
    if type(d.lastChange) == "table" and d.lastChange.actor ~= nil then self:addText(PS.lastText(d.lastChange), "textMuted") end
    for _, b in pairs(self.boxes) do b:setEnabled(self.busy == nil) end

    self:sectionRow("IGUI_MVM_Btn_BuySlots", "permanentEnabled")
    self.boxes.permanentEnabled.scrollTop = 0 -- 第一列落點時連同上方的設定檔路徑與橫幅一起捲回頂端
    self:fieldRow("permanentPrice", "permanentCurrency")
    self:fieldRow("permanentLimit")
    self:sectionRow("IGUI_MVM_Btn_RentSlots", "rentalEnabled")
    self:fieldRow("rentalPrice", "rentalCurrency")
    self:fieldRow("rentalDays")
    self:fieldRow("rentalLimit")

    -- 進階設定：收起時一行摘要（有改過也標色條）
    self.y = self.y + GAP
    local rowY, rowH = self.y, self.ch
    self.btnAdvanced:setTitle(getText(self.advanced and "IGUI_MVM_Paid_AdvancedHide" or "IGUI_MVM_Paid_Advanced"))
    if not self.advanced then
        for _, k in ipairs(ADVANCED) do
            if self:changed(k) then self:markRow(rowY, rowH); break end
        end
    end
    local x = self:put(self.btnAdvanced, PAD + 8, rowY, rowH)
    if not self.advanced then
        local draft = self.draft
        self:textAt(getText("IGUI_MVM_Paid_AdvancedSummary", draft.graceHours, draft.reminderHours,
            getText(draft.autoRenewAllowed and "IGUI_MVM_Paid_Name_autoRenewAllowed" or "IGUI_MVM_Paid_AutoNotAllowed")),
            x, rowY + math.floor((rowH - fontH(FS)) / 2), "textMuted")
    end
    self.y = rowY + rowH + GAP
    if self.advanced then
        self:fieldRow("graceHours")
        self:fieldRow("reminderHours")
        self:boxRow("autoRenewAllowed")
    end
end

-- 頁尾一列文字（頁尾面板自己的座標）
function P:footText(s, token, y)
    local parts = {}
    BU.wrap(parts, s, self.innerW, FS, measure)
    for _, t in ipairs(parts) do
        self.footLines[#self.footLines + 1] = { text = t, x = PAD, y = y, token = token }
        y = y + fontH(FS) + 2
    end
    return y
end

local function putFoot(w, c, x, y)
    c:setX(x)
    c:setY(y)
    c:setVisible(true)
    w.footPlaced[#w.footPlaced + 1] = c
end

function P:layout()
    self.dirty = false
    -- 輸入框不在這裡隱藏：正在輸入的框每打一個字都會重排，隱藏再顯示會打斷輸入；沒排上的最後才收
    for _, c in ipairs(self.controls) do
        if c._entry then c.onPage = false else c:setVisible(false) end
    end
    for _, c in ipairs(self.footControls) do c:setVisible(false) end
    self.lines, self.fills, self.placed, self.footLines, self.footPlaced = {}, {}, {}, {}, {}
    self.y, self.innerW = PAD, self.win.width - PAD * 2
    if self.banner then
        local top = self.y
        self.y = self.y + 4
        self:addText(self.banner, "accent", PAD + 8, self.innerW - 16)
        self.y = self.y + 2
        self.fills[#self.fills + 1] = { x = PAD, y = top, w = self.innerW, h = self.y - top, token = "accent", border = true }
        self.y = self.y + GAP
    end
    local d = self.data
    local form = d ~= nil and d.economy == "READY" and self.base ~= nil
    if form then
        self:layoutForm(d)
    elseif d ~= nil and d.economy ~= "READY" then
        self:addText(getText("IGUI_MVM_Reason_ECONOMY_UNAVAILABLE"), "errorText")
    elseif self.busy then
        self:addText(getText("IGUI_MVM_Paid_Loading"), "textMuted")
    end
    self.contentH = self.y + PAD
    for _, input in pairs(self.inputs) do
        if not input.onPage then
            if input:isFocused() then input._entry:unfocus() end
            input:setVisible(false)
        end
    end

    -- 頁尾：狀態訊息、已修改 N 項 [放棄修改][套用變更...]；沒有表單時只有重新整理
    local fy = GAP
    if self.busy and form then
        fy = self:footText(getText("IGUI_MVM_Slots_Busy"), "textMuted", fy)
    elseif self.message then
        fy = self:footText(self.message, self.messageToken, fy)
    end
    local rowH = self.ch
    if form then
        local n = #PS.changes(self.base, self.draft)
        if n > 0 then
            self.footLines[#self.footLines + 1] = { text = getText("IGUI_MVM_Paid_Modified", n), x = PAD,
                y = fy + math.floor((rowH - fontH(FS)) / 2), token = "textMuted" }
        end
        self.btnDiscard:setEnabled(n > 0 and self.busy == nil)
        self.btnApply:setEnabled(n > 0 and self.busy == nil)
        local ax = PAD + self.innerW - self.btnApply.width
        putFoot(self, self.btnDiscard, ax - GAP - self.btnDiscard.width, fy)
        putFoot(self, self.btnApply, ax, fy)
    else
        self.btnReload:setEnabled(self.busy == nil)
        putFoot(self, self.btnReload, PAD, fy)
    end
    local footH = fy + rowH + PAD

    -- 內容放不下就捲動：視窗不超出畫面，頁尾永遠在視窗底部
    local top = self.win:contentTop()
    local sh = getCore():getScreenHeight()
    local h = math.max(0, math.min(self.contentH, sh - 20 - top - footH))
    self.body:setHeight(h)
    self.foot:setY(top + h)
    self.foot:setHeight(footH)
    local winH = top + h + footH
    self.win:setHeight(winH)
    if self.win:getY() == self.autoY then
        self.autoY = math.floor((sh - winH) / 2)
        self.win:setY(self.autoY)
    elseif self.win:getY() + winH > sh then
        self.win:setY(math.max(0, sh - winH))
    end
    self:buildFocus()
    self:setScroll(self.scroll)
    keepFocus(self)
    if form then self:landJoypad() end
end

-- 手把開窗時目標要等 GET 回來才有：第一次排出表單後，視窗仍持有手把焦點就落到第一個目標（同 Dialog.show 末段）
function P:landJoypad()
    if not self.landPending or #self.focusList == 0 then return end
    self.landPending = nil
    local d = self.focusList[1]
    if Focus and Focus.holdsJoypad(self.win) and d.control then Focus.focusControl(d.control, true) end
end

-- 輸入框顯示草稿（相同文字是 no-op，不動正在打字的欄位）
function P:loadFields()
    for k, input in pairs(self.inputs) do input:setText(self.draft[k] or "") end
end

-- ------------------------------------------------------------------ 操作 ---
function P:edit(key, value)
    if self.draft == nil or self.draft[key] == value then return end
    self.draft[key] = value
    if self.badField == key then self.badField = nil end
    self:say(nil)
end

function P:onChip(b) self:edit(b.fieldKey, b.internal) end

function P:onAdvanced()
    self.advanced, self.dirty = not self.advanced, true
end

function P:onDiscard()
    if self.base == nil or self.busy then return end
    self.draft, self.badField, self.banner = PS.draftOf(self.base), nil, nil
    self:loadFields()
    self:say(nil)
end

function P:load()
    local p = getSpecificPlayer(0)
    if p == nil or self.busy then return end
    self.busy, self.dirty = "get", true
    C.request(p, "adminPaidSlots", { op = "GET" }, function(ack) self:onGet(ack) end)
end

function P:onGet(ack)
    self.busy, self.dirty = nil, true
    if not ack.ok then return self:say(MVM.reasonText(ack.reason), "errorText") end
    self.data = ack
    if ack.economy ~= "READY" or type(ack.plan) ~= "table" then
        self.base, self.draft = nil, nil
        return
    end
    local base = {}
    for _, f in ipairs(PS.FIELDS) do base[f.key] = ack.plan[f.key] end
    base.revision = ack.revision
    if self.base == nil or self.draft == nil then
        self.draft, self.banner = PS.draftOf(base), nil
    elseif self.base.revision ~= base.revision then
        local draft, others = PS.rebase(self.base, base, self.draft)
        self.draft = draft
        if #others > 0 then
            self.banner = PS.bannerText(ack.lastChange, others, self.base, base, #PS.changes(base, draft) > 0, currencyName)
        end
    end
    self.base = base
    self:loadFields()
end

function P:onApply()
    if self.busy or self.base == nil then return end
    local keys = PS.changes(self.base, self.draft)
    if #keys == 0 then return end
    local values, bad = PS.payload(self.draft)
    if values == nil then
        self.badField = bad
        return self:say(getText("IGUI_MVM_Paid_NeedInt"), "errorText")
    end
    self:confirm(keys, values, self.base.revision, nil)
end

-- 確認框：變更前後、會影響的事、原因（必填；空白就再問一次，不送出）
function P:confirm(keys, values, revision, warn)
    local lines = {}
    if warn then lines[1], lines[2] = warn, "" end
    for _, k in ipairs(keys) do lines[#lines + 1] = PS.changeLine(k, self.base[k], self.draft[k], currencyName) end
    local impacts = PS.impacts(self.base, self.draft)
    if #impacts > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = getText("IGUI_MVM_Paid_ImpactHead")
        for _, m in ipairs(impacts) do
            lines[#lines + 1] = "- " .. (m[2] ~= nil and getText(m[1], m[2]) or getText(m[1]))
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = getText("IGUI_MVM_Paid_ReasonPrompt")
    UI.Dialog.show({ title = getText("IGUI_MVM_Paid_ApplyTitle"), theme = theme,
        width = math.min(480, getCore():getScreenWidth() - 40), text = table.concat(lines, "\n", 1, #lines),
        input = { placeholder = getText("IGUI_MVM_Paid_ReasonHint") },
        confirmText = getText("IGUI_MVM_Btn_Apply"), cancelText = getText("UI_Cancel"),
        onResult = function(ok, text)
            if not ok then return end
            local reason = PS.trim(text)
            if reason == "" then return self:confirm(keys, values, revision, getText("IGUI_MVM_Reason_NEED_REASON")) end
            self:send(values, revision, reason)
        end })
end

function P:send(values, revision, reason)
    local p = getSpecificPlayer(0)
    if p == nil or self.busy then return end
    self.busy = "set"
    self:say(nil)
    C.request(p, "adminPaidSlots", { op = "SET", values = values, expectedRevision = revision, reason = reason },
        function(ack) self:onSet(ack) end)
end

function P:onSet(ack)
    self.busy, self.dirty = nil, true
    if ack.ok then
        self:say(getText(ack.fileError and "IGUI_MVM_Paid_AppliedFileError" or "IGUI_MVM_Paid_Applied"),
            ack.fileError and "errorText" or "text")
        self.base, self.banner, self.badField = nil, nil, nil
        return self:load()
    end
    local f = BY_FILE[tostring(ack.field)]
    self.badField = f and f.key or nil
    local text = MVM.reasonText(ack.reason)
    if f then text = text .. getText("IGUI_MVM_Sep") .. PS.name(f.key) end
    self:say(text, "errorText")
    -- 別人先改了：重新讀，沒改的欄位換成最新值、改過的保留，橫幅說明
    if ack.reason == "STALE_REVISION" then self:load() end
end

-- Economy 推播的方案版本和草稿基準不同：重新讀（別的管理員或設定檔剛改了）
function P.onEconomyChanged(env)
    local w = P.instance
    if w == nil or w.busy or w.base == nil or not w.win:getIsVisible() then return end
    if type(env) ~= "table" or env.sourceMod ~= SRC or env.productId ~= PROD or type(env.plan) ~= "table" then return end
    if env.plan.revision ~= nil and env.plan.revision ~= w.base.revision then w:load() end
end

-- 關閉（關閉鈕、Esc／手把 B、程式呼叫 setVisible(false) 都走 Window:setVisible）後把前景與鍵盤交回開啟者：
-- 原生 UI 清單只照 bringToTop 排序，關掉最上層的視窗不會自動讓開它的視窗回到前景
function P:watchClose()
    local win = self.win
    local base = win.setVisible
    win.setVisible = function(el, visible)
        local was = el.javaObject ~= nil and el:getIsVisible()
        base(el, visible)
        if was and not visible then self:returnToOpener() end
    end
end

function P:returnToOpener()
    local o = self.opener
    self.opener = nil
    if o == nil or o.javaObject == nil or not o:getIsVisible() then return end
    if Focus then Focus.onFocus(o) else o:bringToTop() end
end

-- opener＝開它的視窗（名額視窗或車隊視窗的框架 Window）；關閉時前景與鍵盤交回它
function P.open(opener)
    local w = P.instance
    if w == nil then
        w = P.new()
        w.win:addToUIManager()
        ISLayoutManager.RegisterWindow(LAYOUT, w.win, w.win)
        w:watchClose()
        P.instance = w
    end
    w.opener = opener
    w.win:setVisible(true)
    w.win:bringToTop()
    w.busy, w.base, w.draft, w.data, w.banner, w.badField, w.message = nil, nil, nil, nil, nil, nil, nil
    w.dirty, w.scroll, w.landPending = true, 0, true
    stopDrag(w.body)
    -- 讓本機持有這個商品的權益快取：方案變更的公開推播只會重讀已持有的商品
    local E = BU.api()
    if E then
        if not P.listening then E.onChanged(P.onEconomyChanged); P.listening = true end
        E.requestState(SRC, PROD)
    end
    w:load()
    return w
end
