-- MinidoracatVehicleManager 共用常數與公開 API 表（client／server 都載入）。
-- 權威判定只在 server（OwnershipSystem 會把 canUse 換成真正的實作）；client 的 canUse 只看自己的投影快取，供選單置灰。
MinidoracatVehicleManager = MinidoracatVehicleManager or {}
local MVM = MinidoracatVehicleManager

MVM.MODULE = "MinidoracatVehicleManager"
MVM.PROTOCOL = 1
MVM.LOG_PREFIX = "[MinidoracatVehicleManagerFor42] "
-- Economy 選用整合（付費名額）：來源與產品 id，server 註冊與 client 查詢共用同一組字串。
-- ECON_PRODUCT＝綁定名額、GUARD_PRODUCT＝停車保全名額；PRODUCTS 是名額視窗與設定視窗的分頁順序
MVM.ECON_SOURCE = "MinidoracatVehicleManagerFor42"
MVM.ECON_PRODUCT = "vehicle_slot"
MVM.GUARD_PRODUCT = "guard_slot"
MVM.PRODUCTS = { MVM.ECON_PRODUCT, MVM.GUARD_PRODUCT }
-- 停車保全模式（沙盒 ParkedGuard）：OFF＝關閉、ALL＝所有綁定的車、SLOTS＝依保全名額（車主逐台開啟）
MVM.GUARD = { OFF = 1, ALL = 2, SLOTS = 3 }
-- 車主通知紀錄（server Notices.lua）：每人保留最近幾則、幾天內；車隊視窗「紀錄」分頁的說明也用這兩個數
MVM.NOTICE_MAX = 50
MVM.NOTICE_KEEP_DAYS = 30
-- 付費名額方案 12 欄，設定檔（paid-slots.json）的順序：key＝Economy 方案欄位（翻譯 IGUI_MVM_Paid_Name_<key>），
-- file＝設定檔鍵（群組.鍵），kind＝bool／int／currency。server 讀寫設定檔與 client 設定視窗共用這一份
MVM.PAID_FIELDS = {
    { key = "permanentEnabled", file = "buy.enabled", kind = "bool" },
    { key = "permanentPrice", file = "buy.price", kind = "int" },
    { key = "permanentCurrency", file = "buy.currency", kind = "currency" },
    { key = "permanentLimit", file = "buy.limit", kind = "int" },
    { key = "rentalEnabled", file = "rent.enabled", kind = "bool" },
    { key = "rentalPrice", file = "rent.price", kind = "int" },
    { key = "rentalCurrency", file = "rent.currency", kind = "currency" },
    { key = "rentalLimit", file = "rent.limit", kind = "int" },
    { key = "rentalDays", file = "rent.days", kind = "int" },
    { key = "graceHours", file = "rent.graceHours", kind = "int" },
    { key = "reminderHours", file = "rent.reminderHours", kind = "int" },
    { key = "autoRenewAllowed", file = "rent.autoRenew", kind = "bool" },
}

-- Lua 5.1／Kahlua 沒有位元運算：每個 action 是 2 的冪，以整數除法測位
MVM.ACTIONS = { PASSENGER = 1, DRIVE = 2, CARGO = 4, FUEL = 8, REPAIR = 16, SALVAGE = 32, TOW = 64, TRACK = 128, MANAGE = 256 }
MVM.SHAREABLE_MASK = 255 -- MANAGE 永不可分享
-- 公開分享（所有人）只開放搭乘、駕駛、置物、加油、修理（＝前五個位元）：位置會讓全服看到車在哪；拖曳含把車裝上
-- 別人的拖車載走，且 MSW 的名單沒有「所有人」（ClaimTags）；拆解沒有公開的用途
MVM.PUBLIC_MASK = 31
MVM.ACTION_ORDER = { "PASSENGER", "DRIVE", "CARGO", "FUEL", "REPAIR", "SALVAGE", "TOW", "TRACK", "MANAGE" }

function MVM.log(msg) print(MVM.LOG_PREFIX .. tostring(msg)) end

function MVM.hasBit(bits, bit)
    if type(bits) ~= "number" or type(bit) ~= "number" then return false end
    return math.floor(bits / bit) % 2 == 1
end

-- 有限整數判定（NaN／±Inf／小數皆否）
function MVM.isInt(n)
    return type(n) == "number" and n * 0 == 0 and n == math.floor(n)
end

-- action bits 必須是 0..SHAREABLE_MASK 的整數
function MVM.validShareBits(bits)
    return MVM.isInt(bits) and bits >= 0 and bits <= MVM.SHAREABLE_MASK
end

function MVM.validPublicBits(bits)
    return MVM.isInt(bits) and bits >= 0 and bits <= MVM.PUBLIC_MASK
end

-- 能裝載其他車的載具：MSW 多槽拖車（零件 ATAMultiSlotWrecker，MSW_ISVehicleMenu.lua:43-46）或 Autotsar 拖吊車／拖車
-- （ATAVehicleWrecker／ATA2VehicleWrecker，ATA_ISVehicleMenu.lua:25-26）。綁定確認視窗用來提示「載綁定車的拖車也要綁定」
local CARRIER_PARTS = { "ATAMultiSlotWrecker", "ATAVehicleWrecker", "ATA2VehicleWrecker" }
function MVM.isCarrier(vehicle)
    if vehicle == nil then return false end
    for _, id in ipairs(CARRIER_PARTS) do
        if vehicle:getPartById(id) ~= nil then return true end
    end
    return false
end

-- 穩定合併排序（家族禁用 table.sort）：依 keys[item]（字串或數字）由小到大；車隊清單與伺服器匯出共用
function MVM.sortByKey(items, keys)
    local n = #items
    if n < 2 then return items end
    local src, dst, width = items, {}, 1
    while width < n do
        for lo = 1, n, width * 2 do
            local mid, hi = math.min(lo + width, n + 1), math.min(lo + width * 2, n + 1)
            local i, j, k = lo, mid, lo
            while k < hi do
                if i < mid and (j >= hi or keys[src[i]] <= keys[src[j]]) then dst[k] = src[i]; i = i + 1
                else dst[k] = src[j]; j = j + 1 end
                k = k + 1
            end
        end
        src, dst, width = dst, src, width * 2
    end
    return src
end

-- 兩組 action bits 的聯集（Kahlua 沒有位元運算）
function MVM.bitsOr(a, b)
    local out = 0
    for _, name in ipairs(MVM.ACTION_ORDER) do
        local bit = MVM.ACTIONS[name]
        if MVM.hasBit(a or 0, bit) or MVM.hasBit(b or 0, bit) then out = out + bit end
    end
    return out
end

-- DRIVE ⇒ PASSENGER；其餘互相獨立（§5.1）
function MVM.bitsAllow(bits, action)
    local bit = MVM.ACTIONS[action]
    if bit == nil then return false end
    if MVM.hasBit(bits, bit) then return true end
    return action == "PASSENGER" and MVM.hasBit(bits, MVM.ACTIONS.DRIVE)
end

function MVM.sandbox(name, default)
    local page = SandboxVars and SandboxVars.MinidoracatVehicleManager
    local v = page and page[name]
    if v == nil then return default end
    return v
end

-- 停車保全模式；沙盒值不是 1–3 時當成預設（所有綁定的車）
function MVM.guardMode()
    local m = MVM.sandbox("ParkedGuard", MVM.GUARD.ALL)
    if m ~= MVM.GUARD.OFF and m ~= MVM.GUARD.ALL and m ~= MVM.GUARD.SLOTS then return MVM.GUARD.ALL end
    return m
end

-- 每位玩家的免費保全名額（依保全名額模式；個人設定見伺服器 guardOverrides）
function MVM.guardSlotsDefault()
    local n = MVM.sandbox("GuardSlotsPerPlayer", 1)
    return MVM.isInt(n) and n >= 0 and n or 1
end

MinidoracatVehicleManagerAPI = MinidoracatVehicleManagerAPI or {}
local API = MinidoracatVehicleManagerAPI
API.apiVersion = 1

-- canUse(actor, vehicle, actionCode, context?) -> allowed, reasonCode
-- server：OwnershipSystem 載入時覆寫為權威實作。client：依投影快取回答，僅供 UX。
function API.canUse(actor, vehicle, actionCode, context)
    if MVM.ACTIONS[actionCode] == nil then return false, "UNKNOWN_ACTION" end
    if MVM.clientCanUse then return MVM.clientCanUse(actor, vehicle, actionCode) end
    return false, "NOT_READY"
end

-- client-only 摘要；server 端回 nil
function API.getLocalClaimProjection(playerNum, vehicle)
    if MVM.clientProjection then return MVM.clientProjection(playerNum, vehicle) end
    return nil
end
