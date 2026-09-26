-- 每台車的地圖外觀（圖示＋顏色），只存在本機客戶端：純外觀、不影響權限，所以不進伺服器帳本與協定。
-- 存在 Zomboid/Lua/MinidoracatVehicleManager/appearance.txt，一列一台：oid<TAB>r<TAB>g<TAB>b<TAB>icon<TAB>size（色 0-255、大小為百分比）。
require "MinidoracatVehicleManager_API"

local MVM = MinidoracatVehicleManager
local A = { prefs = nil }
MVM.Appearance = A

local FILE = "MinidoracatVehicleManager/appearance.txt"

-- 可選圖示（框架 rev 8 art icon key）；依車型自動挑預設
A.ICONS = { "carSedan", "carHatchback", "carSports", "carSuv", "carPickup", "carVan", "carStepVan", "carTruck",
    "carAmbulance", "carPolice", "carFiretruck", "carTrailer", "markerStar", "markerHeart", "markerFlag", "markerCrown" }
local VALID = {}
for _, k in ipairs(A.ICONS) do VALID[k] = true end

-- 地圖標記大小：百分比，對應 MiniMap marker scale（上限 2.5）；預設 175%（車型側視圖 20px 以上才分得清）
A.SIZE_MIN, A.SIZE_MAX, A.SIZE_STEP, A.DEFAULT_SIZE = 100, 250, 5, 175
local function clampSize(v)
    v = tonumber(v)
    if v == nil then return nil end
    return math.max(A.SIZE_MIN, math.min(A.SIZE_MAX, math.floor(v + 0.5)))
end
function A.scale(size) return (clampSize(size) or A.DEFAULT_SIZE) / 100 end

-- 預設色避開 MiniMap 一般載具的青色：自己的車金黃、分享給我的車紫
A.OWN = { r = 1, g = 0.76, b = 0.18 }
A.SHARED = { r = 0.78, g = 0.48, b = 1 }

-- 依 script 名稱猜車型（順序有意義：警車皮卡算警車、救護廂型車算救護車）
local RULES = { { "Trailer", "carTrailer" }, { "Ambulance", "carAmbulance" }, { "Police", "carPolice" },
    { "Fire", "carFiretruck" }, { "StepVan", "carStepVan" }, { "PickUp", "carPickup" }, { "Van", "carVan" },
    { "SUV", "carSuv" }, { "OffRoad", "carSuv" }, { "Sports", "carSports" }, { "SmallCar", "carHatchback" },
    { "Truck", "carTruck" } }
function A.iconFor(script)
    local s = tostring(script or "")
    for _, rule in ipairs(RULES) do
        if s:find(rule[1], 1, true) then return rule[2] end
    end
    return "carSedan"
end

local function load()
    A.prefs = {}
    local r = getFileReader(FILE, false)
    if r == nil then return end
    while true do
        local line = r:readLine()
        if line == nil then break end
        local oid, cr, cg, cb, icon, size = line:match("^([%w%-]+)\t(%d+)\t(%d+)\t(%d+)\t(%w*)\t?(%d*)$")
        if oid then
            A.prefs[oid] = { r = math.min(255, tonumber(cr)) / 255, g = math.min(255, tonumber(cg)) / 255,
                b = math.min(255, tonumber(cb)) / 255, icon = VALID[icon] and icon or nil, size = clampSize(size) }
        end
    end
    r:close()
end

local function save()
    local w = getFileWriter(FILE, true, false)
    if w == nil then return end
    for oid, p in pairs(A.prefs) do
        w:write(oid .. "\t" .. math.floor(p.r * 255 + 0.5) .. "\t" .. math.floor(p.g * 255 + 0.5) .. "\t"
            .. math.floor(p.b * 255 + 0.5) .. "\t" .. (p.icon or "") .. "\t" .. (p.size or A.DEFAULT_SIZE) .. "\n")
    end
    w:close()
end

-- 這列目前的外觀（有自訂用自訂，否則依角色與車型的預設）；回傳 color, icon, custom, size
function A.get(row)
    if A.prefs == nil then load() end
    local p = A.prefs[row.oid]
    local color = p or (row.role == "OWNER" and A.OWN or A.SHARED)
    local icon = p and p.icon or A.iconFor(row.script)
    return color, icon, p ~= nil, p and p.size or A.DEFAULT_SIZE
end

-- ponytail: 已解除的車不自動清掉偏好，檔案只會慢慢變長；真的變大再依投影清理
function A.set(oid, color, icon, size)
    if A.prefs == nil then load() end
    A.prefs[oid] = { r = color.r, g = color.g, b = color.b, icon = VALID[icon] and icon or nil, size = clampSize(size) }
    save()
    A.rev = (A.rev or 0) + 1
end

function A.reset(oid)
    if A.prefs == nil then load() end
    A.prefs[oid] = nil
    save()
    A.rev = (A.rev or 0) + 1
end

function A._resetForTests() A.prefs = nil; A.rev = nil end
