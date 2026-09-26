-- 即時位置（計畫 §7.3、Phase 4）：只追蹤有人駕駛的受保護車與它拖著的車，精確座標只在 server RAM；
-- 送 trackDelta 給有 TRACK 權限（owner 永遠有）且在線的人。每車最多 2 Hz、移動 ≥1 格才送，
-- 另每 5 秒心跳一次讓剛取得權限的人也拿得到「即時」。玩家下車時把最後位置收斂進帳本 lastKnown。
-- ponytail: trackDelta 是「最新值覆蓋」，不帶 seq；遺失只會讓標記暫時停在舊點，下一次取樣或快照即恢復。
if isClient() then return end
require "MinidoracatVehicleManager_OwnershipSystem"
require "MinidoracatVehicleManager_Server"

local MVM = MinidoracatVehicleManager
local O, S = MVM.Own, MVM.Srv
local T = { last = {}, seat = {}, lastRun = 0 }
MVM.Tracking = T

local SAMPLE_MS, HEARTBEAT_MS = 500, 5000

local function now() return getTimestampMs() end

-- 會收到這台車即時位置的在線玩家
local function trackers(rec)
    local out = {}
    local online = S.online()
    for who in pairs(S.audience(rec)) do
        local player = online[who]
        if player then
            local row = S.row(rec, who)
            if row and (row.role == "OWNER" or MVM.bitsAllow(row.myBits, "TRACK")) then out[who] = player end
        end
    end
    return out
end

function T.sample(vehicle, force)
    local verdict, rec = O.lookup(vehicle)
    if rec == nil or verdict ~= "AUTHORIZED" then return end
    local t = now()
    local x, y, z = vehicle:getX(), vehicle:getY(), vehicle:getZ()
    local last = T.last[rec.oid]
    if not force and last then
        local moved = math.abs(x - last.x) + math.abs(y - last.y) >= 1
        if t - last.t < SAMPLE_MS or (not moved and t - last.t < HEARTBEAT_MS) then return end
    end
    T.last[rec.oid] = { x = x, y = y, z = z, t = t }
    for _, player in pairs(trackers(rec)) do
        S.send(player, "trackDelta", { oid = rec.oid, x = x, y = y, z = z, t = t })
    end
end

-- 車（與它拖著的車）不再有人時：最後一次取樣並收斂進帳本
function T.leave(vehicle)
    if vehicle == nil or vehicle:isRemovedFromWorld() then return end
    T.sample(vehicle, true)
    O.observeVehicle(vehicle)
    local towed = vehicle:getVehicleTowing()
    if towed and not towed:isRemovedFromWorld() then T.sample(towed, true); O.observeVehicle(towed) end
end

function T.tick()
    local t = now()
    if t - T.lastRun < SAMPLE_MS then return end
    T.lastRun = t
    if O.state() == nil then return end
    O.ready() -- 觸發載入判定；RECOVERY_REQUIRED 仍唯讀追蹤（lookup 唯讀分支、observeVehicle 自己擋寫入）
    local online = S.online()
    for who, player in pairs(online) do
        local v = player:getVehicle()
        local prev = T.seat[who]
        if prev ~= v then
            -- 離車：最後一次取樣並寫入帳本 lastKnown（低頻持久化，§7.3）；引擎此時也把車與拖掛寫進 vehicles.db
            T.leave(prev)
            T.seat[who] = v
        end
        if v and v:isDriver(player) then
            T.sample(v, false)
            local towed = v:getVehicleTowing()
            if towed then T.sample(towed, false) end
        end
    end
    -- 在車上直接斷線：引擎斷線時同樣寫 vehicles.db（GameServer.java:2594-2595），這裡也收斂最後位置
    local gone = {}
    for who in pairs(T.seat) do if online[who] == nil then gone[#gone + 1] = who end end
    for _, who in ipairs(gone) do T.leave(T.seat[who]); T.seat[who] = nil end
end

Events.OnTick.Add(T.tick)
