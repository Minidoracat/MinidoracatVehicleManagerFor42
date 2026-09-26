-- MinidoracatVehicleManager 共用常數與公開 API 表（client／server 都載入）。
-- 權威判定只在 server（OwnershipSystem 會把 canUse 換成真正的實作）；client 的 canUse 只看自己的投影快取，供選單置灰。
MinidoracatVehicleManager = MinidoracatVehicleManager or {}
local MVM = MinidoracatVehicleManager

MVM.MODULE = "MinidoracatVehicleManager"
MVM.PROTOCOL = 1
MVM.LOG_PREFIX = "[MinidoracatVehicleManagerFor42] "

-- Lua 5.1／Kahlua 沒有位元運算：每個 action 是 2 的冪，以整數除法測位
MVM.ACTIONS = { PASSENGER = 1, DRIVE = 2, CARGO = 4, FUEL = 8, REPAIR = 16, SALVAGE = 32, TOW = 64, TRACK = 128, MANAGE = 256 }
MVM.SHAREABLE_MASK = 255 -- MANAGE 永不可分享
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
