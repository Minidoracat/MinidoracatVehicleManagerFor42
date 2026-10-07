-- MiniMap 選用整合（計畫 §9、Phase 4）：MiniMap 有 markerApiVersion >= 1 才註冊 per-player provider；
-- 沒裝或版本舊就安靜不做（車隊視窗仍可用原版地圖定位）。名單只來自本人收到的投影：
-- owner 的車與有 TRACK 權限的分享車；有新鮮即時位置（10 秒內）標 live，否則用最後已知位置。
require "MinidoracatVehicleManager_API"
require "MinidoracatVehicleManager_Client"
require "ISUI/MinidoracatVehicleManager_FleetWindow"
require "MinidoracatVehicleManager_Appearance"

local MVM = MinidoracatVehicleManager
local C = MVM.Client
local B = {}
MVM.MiniMapBridge = B

local LIVE_MS = 10000
local A = MVM.Appearance
local BADGE = { r = 0.06, g = 0.06, b = 0.07, a = 0.92 } -- 深色圓底，讓彩色圖示在地圖上跳出來

local function ui() return MinidoracatUI and MinidoracatUI.v1 end

-- 圖示：框架 rev 8 車型 art；舊框架退回方向盤，再退回原版點火圖
local texCache = {}
local function iconTexture(key)
    local t = texCache[key]
    if t == nil then
        local UI = ui()
        t = UI and UI.Icons and (UI.API_REVISION >= 8 and UI.Icons.get(key) or UI.Icons.get("steeringwheel"))
            or getTexture("media/ui/vehicles/vehicle_ignitionON.png") or false
        texCache[key] = t
    end
    return t or nil
end

local dotTex = nil
local function badgeTexture()
    if dotTex == nil then dotTex = getTexture("media/ui/MinidoracatUI/mui_dot.png") or false end
    return dotTex or nil
end

-- 依投影建一份標記表；只在投影、外觀或 live 判定換時段時重建（provider 契約：回快取表）。labels＝false 時不帶車名
function B.build(bucket, now, labels)
    local markers = {}
    local API = MinidoracatMiniMapAPI
    local v2 = API and type(API.markerApiVersion) == "number" and API.markerApiVersion >= 2
    local badge = v2 and badgeTexture()
    for oid, row in pairs(bucket.rows or {}) do
        local track = row.role == "OWNER" or MVM.bitsAllow(row.myBits or 0, "TRACK")
        if track and MVM.FleetUI and row.state ~= "RELEASED" and row.state ~= "ORPHANED" and row.state ~= "DESTROYED" then
            local live = bucket.track and bucket.track[oid]
            local x, y, state = nil, nil, "lastKnown"
            if live and now - live.t <= LIVE_MS then x, y, state = live.x, live.y, "live"
            elseif row.lastKnownX then x, y = row.lastKnownX, row.lastKnownY end
            if x then
                local c, icon, _, size = A.get(row)
                -- 停好的車最後位置就是準的，不該變淡；只有狀態異常（待重新核發、待釋放、隔離、暫時不在世界上）才淡化
                local shown = (row.state == "ACTIVE" and not row.removedAtMs) and "live" or state
                local m = { id = oid, x = x, y = y, texture = iconTexture(icon), r = c.r, g = c.g, b = c.b,
                    label = labels ~= false and MVM.FleetUI.displayName(row) or nil, state = shown,
                    layer = B.layered and "bound" or nil }
                if badge then
                    m.scale = A.scale(size) -- 預設中（1.75）：車型側視圖 20px 以上才分得清
                    m.badge = { texture = badge, r = BADGE.r, g = BADGE.g, b = BADGE.b, a = BADGE.a }
                    m.ring = { r = c.r, g = c.g, b = c.b, a = 1 }
                    m.labelColor = { r = c.r, g = c.g, b = c.b }
                end
                markers[#markers + 1] = m
            end
        end
    end
    return markers
end

local cache = { key = nil, out = { revision = 0, markers = {} } }
cache.mini = cache.out

-- surface＝"mini"／"world"。舊 MiniMap：玩家關掉「小地圖顯示車名」時，小地圖拿不帶車名的那份，世界地圖照常。
-- 圖層模式（B.layered）：兩個面都拿同一份，車名開關由 MiniMap 依 layer＝"bound" 套用
function B.provider(playerNum, surface)
    if playerNum ~= 0 then return nil end -- v1 不支援分割畫面第二位玩家（計畫 §21 gate 16）
    local p = getSpecificPlayer(0)
    if p == nil then return nil end
    local b = C.buckets[isClient() and p:getUsername() or "local:0"]
    if b == nil then return nil end
    local now = getTimestampMs()
    local key = tostring(b.rev) .. ":" .. tostring(A.rev) .. ":" .. tostring(math.floor(now / 2000))
    if key ~= cache.key then
        cache.key = key
        local rev = cache.out.revision + 1
        cache.out = { revision = rev, markers = B.build(b, now, true) }
        cache.mini = (B.layered or A.showMiniLabels()) and cache.out or { revision = rev, markers = B.build(b, now, false) }
    end
    return surface == "mini" and cache.mini or cache.out
end

-- 開啟車隊視窗（MiniMap 設定的按鈕；已開著就拉到最上層，不像浮鈕那樣切換關掉）
function B.openFleet()
    local FW = MVM.FleetWindow
    local f = FW.ensure()
    if f.win:getIsVisible() then f.win:bringToTop() else FW.toggle() end
end

-- MiniMap 設定預覽用的範例車標：預設金黃轎車（同自己的車），帶深色圓底與外環
local function sampleMarker()
    local c, badge = A.OWN, badgeTexture()
    return { texture = iconTexture("carSedan"), r = c.r, g = c.g, b = c.b, label = getText("IGUI_MVM_Layer_Sample"),
        state = "live", scale = A.scale(nil), badge = badge and { texture = badge, r = BADGE.r, g = BADGE.g, b = BADGE.b, a = BADGE.a },
        ring = { r = c.r, g = c.g, b = c.b, a = 1 }, labelColor = { r = c.r, g = c.g, b = c.b } }
end

-- settingsApiVersion 5＋markerApiVersion 3：「綁定車輛」圖層的顯示、大小與車名開關都歸 MiniMap 管（值存 MiniMap），
-- 本 MOD 只在車標標 layer。小地圖車名的初值帶入玩家在舊版的選擇
function B.layerSpec()
    return { label = "IGUI_MVM_SourceName", icon = "carSedan", group = "addon", order = 40,
        layers = { { id = "bound", label = "IGUI_MVM_Layer_Bound", show = { mini = true, world = true }, size = 16,
            names = { mini = A.showMiniLabels() == true, world = true },
            namesMiniLabel = "IGUI_MVM_MiniMapNames", namesWorldLabel = "IGUI_MVM_MiniMapNamesWorld",
            sample = sampleMarker() } },
        actions = { { label = "IGUI_MVM_OpenFleet", tooltip = "IGUI_MVM_OpenFleet_tooltip", run = B.openFleet } } }
end

local function atLeast(v, n) return type(v) == "number" and v >= n end

function B.register()
    if B.registered then return end
    local API = MinidoracatMiniMapAPI
    if not (API and type(API.markerApiVersion) == "number" and API.markerApiVersion >= 1
        and type(API.registerMarkerProvider) == "function") then
        MVM.log("MiniMap marker API not available; vehicles are not drawn on the minimap")
        return
    end
    API.registerMarkerProvider("MinidoracatVehicleManagerFor42", B.provider)
    B.registered = true
    -- MiniMap 設定視窗（齒輪）的「車輛管理」分類。新版（v5＋marker v3）註冊圖層；被拒或舊版走舊分類：
    -- 車名勾選框的值存在本 MOD 的本機檔（Appearance），MiniMap 只呼叫 get／set
    local settings = atLeast(API.settingsApiVersion, 1) and type(API.registerSettingsSection) == "function"
    B.layered = settings and atLeast(API.settingsApiVersion, 5) and atLeast(API.markerApiVersion, 3)
        and API.registerSettingsSection("MinidoracatVehicleManagerFor42", B.layerSpec()) == true
    cache.key = nil -- 車標形狀（layer、小地圖那份）跟著換
    if settings and not B.layered then
        API.registerSettingsSection("MinidoracatVehicleManagerFor42", { label = "IGUI_MVM_SourceName", ticks = {
            { label = "IGUI_MVM_MiniMapNames", tooltip = "IGUI_MVM_MiniMapNames_tooltip", default = true,
                get = A.showMiniLabels, set = A.setMiniLabels } } })
    end
end

-- MiniMap 不在 require 內，載入序不保證：等所有 client Lua 載完再偵測
Events.OnGameStart.Add(B.register)
