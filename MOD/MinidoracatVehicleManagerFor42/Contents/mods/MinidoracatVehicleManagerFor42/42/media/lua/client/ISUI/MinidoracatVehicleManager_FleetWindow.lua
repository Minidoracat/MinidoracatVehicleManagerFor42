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

function F.listToBits(list)
    local bits = 0
    for _, a in ipairs(list) do bits = bits + MVM.ACTIONS[a] end
    return bits
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

-- 會畫在地圖上的列：自己的車、或分享給我且有查看位置權限；終態與待轉不畫
function F.onMap(row)
    if row.state == "RELEASED" or row.state == "ORPHANED" or row.state == "DESTROYED" or row.state == "PENDING_REBIND" then
        return false
    end
    return row.role == "OWNER" or MVM.bitsAllow(row.myBits or 0, "TRACK")
end

-- 狀態只照 server 的 recordState；釋放倒數以 server 給的到期時間換算
function F.stateText(row, now)
    local s = row.state
    if s == "PENDING_RELEASE" then
        local hours = math.max(0, math.ceil(((row.releaseDueAtMs or now) - now) / 3600000))
        return getText("IGUI_MVM_State_PENDING_RELEASE", hours)
    end
    return getText("IGUI_MVM_State_" .. tostring(s))
end

-- 位置：v1 只有 server 低頻收斂的最後已知點；沒有就明說未知，不畫假座標
function F.locationText(row, now)
    if row.lastKnownX == nil or row.lastKnownAtMs == nil or row.lastKnownAtMs <= 0 then
        return getText("IGUI_MVM_Location_Unknown")
    end
    local minutes = math.max(0, math.floor((now - row.lastKnownAtMs) / 60000))
    return getText("IGUI_MVM_Location_LastKnown", math.floor(row.lastKnownX), math.floor(row.lastKnownY), minutes)
end

function F.shareText(row)
    if row.role ~= "OWNER" then
        local key = row.role == "FACTION" and "IGUI_MVM_Share_ViaFaction" or "IGUI_MVM_Share_ViaMember"
        return getText(key, tostring(row.owner or "?"))
    end
    local parts = {}
    if row.grants and #row.grants > 0 then parts[#parts + 1] = getText("IGUI_MVM_Share_Members", #row.grants) end
    if row.factionShare then
        parts[#parts + 1] = getText(row.factionState == "SUSPENDED" and "IGUI_MVM_Share_FactionSuspended" or "IGUI_MVM_Share_Faction",
            tostring(row.factionName or "?"))
    end
    if #parts == 0 then return getText("IGUI_MVM_Share_Private") end
    return table.concat(parts, " / ", 1, #parts)
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

local STATE_TOKEN = { ACTIVE = "text", WITNESS_STALE = "accent", PENDING_RELEASE = "accent", PENDING_REBIND = "accent",
    QUARANTINED = "errorText" }
local function stateToken(row) return STATE_TOKEN[row.state] or "textFaint" end
local function terminalState(row) return row.state == "RELEASED" or row.state == "ORPHANED" or row.state == "DESTROYED" end

-- 清單列：選取狀態存在 list，cell 只是投影；文字在 bind 時算好，render 不配置
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
    -- 左側畫這台車在地圖上的圖示與顏色（外觀設定），框架缺圖時退回狀態圓點
    if not UI.Icons.draw(self, self.icon, 8, math.floor((h - 20) / 2), 20, self.color, 1) then
        UI.Skin.dot(self, 12, math.floor(h / 2) - 4, 8, COL[self.token])
    end
    text(self, self.title, 36, math.floor(h / 2) - fh - 1, "text")
    text(self, self.sub, 36, math.floor(h / 2) + 1, "textMuted")
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

local FleetWindow = {}
FleetWindow.__index = FleetWindow
MVM.FleetWindow = FleetWindow

function FleetWindow.new()
    local self = setmetatable({ tab = "OWNED", query = "", selectedOid = nil, current = nil, pending = nil, message = nil,
        messageBad = false, dirty = true, lastNearCheck = 0, headings = {} }, FleetWindow)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w = math.min(940, math.floor(sw * 0.92))
    local h = math.min(680, math.floor(sh * 0.9))
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
    local W, H = body.width, body.height

    self.tabs = UI.Tabs.new({ x = PAD, y = PAD, height = self.ch, theme = theme, target = self, onSelect = FleetWindow.onTab,
        selected = "OWNED", items = {
            { id = "OWNED", label = getText("IGUI_MVM_Tab_OWNED") },
            { id = "SHARED", label = getText("IGUI_MVM_Tab_SHARED") },
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
            c.list = l
            return c
        end,
        bindCell = function(_, c, row, index)
            c.row, c.index = row, index
            c.title = F.displayName(row)
            c.color, c.icon = MVM.Appearance.get(row)
            local sub = F.stateText(row, getTimestampMs())
            if F.renamed(row) then sub = F.modelName(row) .. " - " .. sub end -- 改過名也看得到原始車名
            if self.tab == "ADMIN" then sub = tostring(row.owner or "?") .. " - " .. sub end
            c.sub, c.token = sub, stateToken(row)
        end,
        unbindCell = function(_, c) c.row = nil end,
        onSelect = function(_, row)
            self.selectedOid, self.current = row and row.oid, row
            self:layoutDetail()
        end,
        colors = { thumb = COL.textFaint, thumbHover = COL.textMuted, track = COL.hover } })
    self.list:initialise()
    body:addChild(self.list)

    self.detailX = PAD * 2 + self.listW
    self.detailTop = self.listTop
    self.detailW = W - self.detailX - PAD
    self.infoH = fontH(FM) + (fh + 2) * 5 + 20

    self.nameEntry = self:field(math.min(260, self.detailW - 120))
    self.btnRename = self:button(getText("IGUI_MVM_Btn_Rename"), FleetWindow.onRename, "primary")
    self.userEntry = self:field(180, getText("IGUI_MVM_UserHint"))
    self.btnAddMember = self:button(getText("IGUI_MVM_Btn_AddMember"), FleetWindow.onAddMember, "primary")
    self.btnFaction = self:button(getText("IGUI_MVM_Btn_FactionOn"), FleetWindow.onFaction)
    self.btnTransfer = self:button(getText("IGUI_MVM_Btn_Transfer"), FleetWindow.onTransfer)
    self.checks = {}
    local colW = math.floor(self.detailW / 4)
    for i, a in ipairs(SHAREABLE) do
        local cb = UI.Checkbox.new({ x = 0, y = 0, width = colW - GAP, label = getText("IGUI_MVM_Action_" .. a), theme = theme })
        cb.internal = a
        cb:setVisible(false)
        body:addChild(cb)
        self.checks[i] = cb
    end
    self.memberButtons = {}
    for i = 1, 16 do self.memberButtons[i] = self:button("", FleetWindow.onRemoveMember, "normal", "close") end
    self.btnUnclaim = self:button(getText("IGUI_MVM_Btn_Unclaim"), FleetWindow.onUnclaim, "danger")
    self.btnReport = self:button(getText("IGUI_MVM_Btn_ReportLost"), FleetWindow.onReportLost, "danger")
    self.btnCancel = self:button(getText("IGUI_MVM_Btn_CancelRelease"), FleetWindow.onCancelRelease, "primary")
    self.btnReissue = self:button(getText("IGUI_MVM_Btn_Reissue"), FleetWindow.onReissue, "primary")
    self.btnDismiss = self:button(getText("IGUI_MVM_Btn_Dismiss"), FleetWindow.onDismiss)
    self.btnMap = self:button(getText("IGUI_MVM_Btn_Map"), FleetWindow.onMap, "ghost", "locate")
    self.btnLook = self:button(getText("IGUI_MVM_Btn_Appearance"), FleetWindow.onAppearance, "ghost", "sliders")
    self.btnLeave = self:button(getText("IGUI_MVM_Btn_Leave"), FleetWindow.onLeave, "danger")
    self.btnAdminRelease = self:button(getText("IGUI_MVM_Btn_AdminRelease"), FleetWindow.onAdminRelease, "danger")
    self.quotaEntry = self:field(80, nil, true)
    self.btnQuota = self:button(getText("IGUI_MVM_Btn_Quota"), FleetWindow.onQuota)
    self.btnMigrate = self:button(getText("IGUI_MVM_Btn_ImportMVCK"), FleetWindow.onImportMVCK, "primary")
    self.actionButtons = { self.btnRename, self.btnAddMember, self.btnFaction, self.btnTransfer, self.btnUnclaim,
        self.btnReport, self.btnCancel, self.btnReissue, self.btnDismiss, self.btnLeave, self.btnAdminRelease, self.btnQuota,
        self.btnMigrate }
    self.detailControls = { self.nameEntry, self.btnRename, self.userEntry, self.btnAddMember, self.btnFaction,
        self.btnTransfer, self.btnUnclaim, self.btnReport, self.btnCancel, self.btnReissue, self.btnDismiss, self.btnMap,
        self.btnLeave, self.btnAdminRelease, self.quotaEntry, self.btnQuota, self.btnMigrate, self.btnLook }
    for _, cb in ipairs(self.checks) do self.detailControls[#self.detailControls + 1] = cb end
    for _, b in ipairs(self.memberButtons) do
        self.actionButtons[#self.actionButtons + 1] = b
        self.detailControls[#self.detailControls + 1] = b
    end
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

function FleetWindow:rows()
    local b = self:bucket()
    if b == nil then return nil end
    if self.tab == "ADMIN" then return b.admin end
    return b.rows
end

function FleetWindow:selectedRow() return self.current end

-- keyed replace：重建清單時保留選取的 oid
function FleetWindow:rebuild()
    self.dirty = false
    local b = self:bucket()
    local admin = b ~= nil and b.admin ~= nil
    self.tabs:setItemVisible("ADMIN", admin)
    if self.tab == "ADMIN" and not admin then self.tab = "OWNED"; self.tabs:setSelected("OWNED", true) end
    local rows = F.filter(self:rows(), self.tab, self.query)
    local keep = nil
    for i, row in ipairs(rows) do if row.oid == self.selectedOid then keep = i end end
    if keep == nil and #rows > 0 then keep = 1 end
    self.list:setItems(rows)
    self.list:setSelectedIndex(keep)
    self.current = keep and rows[keep] or nil
    self.selectedOid = self.current and self.current.oid or nil
    self:layoutDetail()
end

local function place(ctrl, x, y) ctrl:setX(x); ctrl:setY(y); ctrl:setVisible(true); return x + ctrl.width + GAP end

function FleetWindow:heading(key, y)
    self.headings[#self.headings + 1] = { text = getText(key), y = y }
    return y + self.fh + 4
end

-- 依選取列與角色擺放可用的控制項（選取變更、資料變更與每 2 秒走近／離開車輛時重排）
function FleetWindow:layoutDetail()
    for _, c in ipairs(self.detailControls) do c:setVisible(false) end
    self.headings = {}
    local row = self.current
    local b = self:bucket()
    local recovery = b ~= nil and b.status == "RECOVERY_REQUIRED"
    local x0, step = self.detailX, self.ch + GAP
    local y = self.detailTop + self.infoH + PAD
    if self.tab == "ADMIN" then
        if row ~= nil or (b ~= nil and b.migrationAvailable) then
            y = self:heading("IGUI_MVM_Section_Admin", y)
            local x = x0
            if b ~= nil and b.migrationAvailable then x = place(self.btnMigrate, x, y) end
            if row ~= nil and not terminalState(row) then place(self.btnAdminRelease, x, y) end
            y = y + step
        end
        if row ~= nil then
            local x = place(self.quotaEntry, x0, y)
            place(self.btnQuota, x, y)
        end
        self:updateEnabled(recovery)
        return
    end
    if row == nil then return end
    if row.state == "PENDING_REBIND" then -- MVCK 待轉：車被載入時自動轉正，沒有可用操作
        if row.lastKnownX then place(self.btnMap, x0, y) end
    elseif row.role ~= "OWNER" then
        local x = x0
        if row.lastKnownX then x = place(self.btnMap, x, y) end
        if F.onMap(row) then x = place(self.btnLook, x, y) end
        if row.role == "MEMBER" then place(self.btnLeave, x, y) end
    elseif terminalState(row) then
        place(self.btnDismiss, x0, y)
    else
        y = self:heading("IGUI_MVM_Section_Name", y)
        if self.nameEntry.forOid ~= row.oid then self.nameEntry.forOid = row.oid; self.nameEntry:setText(row.name or "") end
        place(self.btnRename, place(self.nameEntry, x0, y), y)
        y = self:heading("IGUI_MVM_Section_Share", y + step + 4)
        local x = place(self.userEntry, x0, y)
        x = place(self.btnAddMember, x, y)
        self.btnFaction:setTitle(getText(row.factionShare and "IGUI_MVM_Btn_FactionOff" or "IGUI_MVM_Btn_FactionOn"))
        x = place(self.btnFaction, x, y)
        place(self.btnTransfer, x, y)
        y = y + step
        local colW = math.floor(self.detailW / 4)
        for i, cb in ipairs(self.checks) do
            local col = (i - 1) % 4
            place(cb, x0 + col * colW, y)
            if col == 3 or i == #self.checks then y = y + cb.height + GAP end
        end
        if row.grants and #row.grants > 0 then
            y = self:heading("IGUI_MVM_Section_Members", y + 4)
            for i, g in ipairs(row.grants) do
                local mb = self.memberButtons[i]
                if mb == nil then break end
                local acts = F.bitsToList(g.bits)
                mb:setTitle(getText("IGUI_MVM_Btn_RemoveMember", g.user, table.concat(acts, ", ", 1, #acts)))
                mb.internal = g.user
                place(mb, x0, y)
                y = y + step
            end
        end
        y = self:heading("IGUI_MVM_Section_Vehicle", y + 4)
        local near = F.findLoaded(row)
        self.nearVehicle = near
        x = x0
        if row.state == "PENDING_RELEASE" then x = place(self.btnCancel, x, y)
        elseif near then x = place(self.btnUnclaim, x, y)
        else x = place(self.btnReport, x, y) end
        if row.state == "WITNESS_STALE" and near then x = place(self.btnReissue, x, y) end
        if row.lastKnownX then x = place(self.btnMap, x, y) end
        if F.onMap(row) then place(self.btnLook, x, y) end
    end
    self:updateEnabled(recovery)
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
    local row = self.current
    local x, y = self.detailX, self.detailTop
    theme:fill(el, x, y, self.detailW, self.infoH, "well")
    theme:border(el, x, y, self.detailW, self.infoH, "border")
    x, y = x + 12, y + 10
    local now = getTimestampMs()
    if b == nil or b.streamId == nil then
        text(el, getText("IGUI_MVM_Loading"), x, y, "textMuted")
    elseif row == nil then
        text(el, getText("IGUI_MVM_Empty"), x, y, "textMuted")
    else
        text(el, F.displayName(row), x, y, "text", FM)
        y = y + fontH(FM) + 4
        if F.renamed(row) then
            text(el, getText("IGUI_MVM_ModelName", F.modelName(row)), x, y, "textMuted")
            y = y + fh + 2
        end
        text(el, F.stateText(row, now), x, y, stateToken(row) == "text" and "accent" or stateToken(row))
        y = y + fh + 2
        text(el, F.locationText(row, now), x, y, "textMuted")
        y = y + fh + 2
        local share = self.tab == "ADMIN" and getText("IGUI_MVM_AdminOwner", tostring(row.owner or "?")) or F.shareText(row)
        text(el, share, x, y, "textMuted")
        if row.role == "MEMBER" or row.role == "FACTION" then
            local acts = F.bitsToList(row.myBits)
            text(el, getText("IGUI_MVM_YourActions", table.concat(acts, ", ", 1, #acts)), x, y + fh + 2, "textMuted")
        end
    end
    for _, h in ipairs(self.headings) do text(el, h.text, self.detailX, h.y, "textMuted") end
    local fy = el.height - self.footerH
    local bc = COL.border
    el:drawRect(PAD, fy, el.width - PAD * 2, 1, bc.a, bc.r, bc.g, bc.b)
    local q = b and b.quota
    local quota
    if q and ((q.paid or 0) > 0 or (q.pending or 0) > 0) then
        quota = getText("IGUI_MVM_QuotaPaid", q.used or 0, q.total or 0, q.base or 0, q.paid or 0)
        -- 大字級左欄放不下分項就只顯示已用／上限（分項在名額視窗），不壓到右側說明
        if getTextManager():MeasureStringX(FS, quota) > self.detailX - PAD * 2 then
            quota = getText("IGUI_MVM_Quota", q.used or 0, q.total or 0)
        end
    elseif b and b.quotaLimit then
        quota = getText("IGUI_MVM_Quota", b.quotaUsed or 0, b.quotaLimit)
    end
    if quota then text(el, quota, PAD, fy + 6, "text") end
    text(el, getText("IGUI_MVM_Disclosure"), self.detailX, fy + 6, "textFaint")
    if self.pending then
        text(el, getText("IGUI_MVM_Pending"), PAD, fy + 8 + fh, "accent")
    elseif b and b.status == "RECOVERY_REQUIRED" then
        text(el, getText("IGUI_MVM_Recovery"), PAD, fy + 8 + fh, "errorText")
    elseif self.message then
        text(el, self.message, PAD, fy + 8 + fh, self.messageBad and "errorText" or "accent")
    end
end

-- ------------------------------------------------------------------ 操作 ---
local function reasonText(reason)
    local key = "IGUI_MVM_Reason_" .. tostring(reason)
    local t = getText(key)
    if t == key then return getText("IGUI_MVM_Failed", tostring(reason)) end
    return t
end

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
        self.message = ack.ok and (okText and okText(ack) or getText("IGUI_MVM_Done")) or reasonText(ack.reason)
        self.messageBad = not ack.ok
        self.dirty = true
    end)
end

-- 確認框：框架 Dialog（模態、只回呼一次）；self.modal 留給 E2E 以 UI.Dialog.close 按確認
function FleetWindow:confirm(textKey, arg, fn)
    self.modal = UI.Dialog.show({ title = getText("IGUI_MVM_FleetTitle"), text = getText(textKey, arg), theme = theme,
        confirmText = getText("UI_Ok"), cancelText = getText("UI_Cancel"), danger = true,
        onResult = function(ok) self.modal = nil; if ok then fn(self) end end })
end

function FleetWindow:onTab(id)
    self.tab = id
    self.selectedOid, self.current = nil, nil
    self.dirty = true
    if id == "ADMIN" then C.request(getSpecificPlayer(0), "adminList", {}) end
end

function FleetWindow:checkedBits()
    local list = {}
    for _, cb in ipairs(self.checks) do if cb:getChecked() then list[#list + 1] = cb.internal end end
    return F.listToBits(list)
end

function FleetWindow:onRename()
    local row = self.current; if not row then return end
    self:send("rename", { expectedOid = row.oid, expectedEpoch = row.epoch, name = self.nameEntry:getText() or "" })
end

function FleetWindow:onAddMember()
    local row = self.current; if not row then return end
    local user, bits = self.userEntry:getText() or "", self:checkedBits()
    if user == "" or bits == 0 then return self:say("IGUI_MVM_NeedUserAndActions") end
    self:send("addMember", { expectedOid = row.oid, username = user, actionBits = bits })
end

function FleetWindow:onFaction()
    local row = self.current; if not row then return end
    local enable = not row.factionShare
    local bits = enable and self:checkedBits() or 0
    if enable and bits == 0 then return self:say("IGUI_MVM_NeedActions") end
    self:send("setFactionShare", { expectedOid = row.oid, expectedEpoch = row.epoch, enabled = enable, actionBits = bits })
end

function FleetWindow:onRemoveMember(button)
    local row = self.current; if not row then return end
    self:send("removeMember", { expectedOid = row.oid, username = button.internal })
end

function FleetWindow:onTransfer()
    local row = self.current; if not row then return end
    local user = self.userEntry:getText() or ""
    if user == "" then return self:say("IGUI_MVM_NeedUser") end
    local v = F.findLoaded(row)
    if v == nil then return self:say("IGUI_MVM_Reason_TOO_FAR") end
    self:confirm("IGUI_MVM_ConfirmTransfer", user, function(w)
        w:send("transfer", { vehicleId = v:getId(), expectedOid = row.oid, expectedEpoch = row.epoch, recipient = user })
    end)
end

function FleetWindow:onUnclaim()
    local row = self.current; if not row then return end
    local v = F.findLoaded(row)
    if v == nil then return self:say("IGUI_MVM_Reason_TOO_FAR") end
    self:confirm("IGUI_MVM_ConfirmUnclaim", F.displayName(row), function(w)
        w:send("unclaim", { vehicleId = v:getId(), expectedOid = row.oid, expectedEpoch = row.epoch })
    end)
end

function FleetWindow:onReportLost()
    local row = self.current; if not row then return end
    self:confirm("IGUI_MVM_ConfirmReportLost", F.displayName(row), function(w) w:send("reportLost", { expectedOid = row.oid }) end)
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
    self:confirm("IGUI_MVM_ConfirmDismiss", F.displayName(row), function(w) w:send("dismissRecord", { expectedOid = row.oid }) end)
end

function FleetWindow:onLeave()
    local row = self.current; if not row then return end
    self:confirm("IGUI_MVM_ConfirmLeave", F.displayName(row), function(w) w:send("leaveShared", { expectedOid = row.oid }) end)
end

function FleetWindow:onMap()
    local row = self.current; if not row or not row.lastKnownX then return end
    if ISWorldMap.IsAllowed() then ISWorldMap.ShowWorldMap(0, row.lastKnownX, row.lastKnownY, 20) end
end

function FleetWindow:onAdminRelease()
    local row = self.current; if not row then return end
    self:confirm("IGUI_MVM_ConfirmAdminRelease", tostring(row.owner or "?"), function(w)
        w:send("adminRecover", { expectedOid = row.oid, op = "RELEASE" })
        C.request(getSpecificPlayer(0), "adminList", {})
    end)
end

function FleetWindow:onQuota()
    local row = self.current; if not row or not row.owner then return end
    local n = tonumber(self.quotaEntry:getText() or "")
    if n == nil then return self:say("IGUI_MVM_NeedNumber") end
    self:send("adminSetQuota", { username = row.owner, amount = math.floor(n) })
end

function FleetWindow:onImportMVCK()
    self:confirm("IGUI_MVM_ConfirmImportMVCK", nil, function(w)
        w:send("adminMigration", { op = "IMPORT" }, function(ack)
            return getText("IGUI_MVM_MVCKImported", ack.imported or 0, ack.rebound or 0, ack.pending or 0)
        end)
        C.request(getSpecificPlayer(0), "adminList", {})
    end)
end

function FleetWindow:onSlots()
    if MVM.BillingWindow then MVM.BillingWindow.open() else self:say("IGUI_MVM_NeedFramework") end
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
        b.internal, b.look = key, L
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
    F.float = UI.FloatButton.new({
        size = FLOAT_SIZE, alwaysOnTop = false, x = x, y = y,
        colors = { surface = COL.surface, hover = COL.hover, border = COL.border },
        drawContent = function(btn)
            if not UI.Icons.draw(btn, "steeringwheel", 6, 6, FLOAT_SIZE - 12, COL.text, 1) then
                btn:drawTextCentre("V", FLOAT_SIZE / 2, FLOAT_SIZE / 2 - 8, 1, 1, 1, 1, UIFont.Medium)
            end
        end,
        onClick = function() FleetWindow.toggle() end,
        onMoved = function() ISLayoutManager.OnPostSave() end,
        getTooltip = function() return getText("IGUI_MVM_FleetTitle") end,
    })
    ISLayoutManager.RegisterWindow("MinidoracatVehicleManagerFloat", FloatLayout, F.float)
end

Events.OnGameStart.Add(createFloat)
Events.OnResolutionChange.Add(function()
    if F.float then
        F.float:setPosition(floatDefault())
        ISLayoutManager.TryRestore("MinidoracatVehicleManagerFloat")
    end
end)
