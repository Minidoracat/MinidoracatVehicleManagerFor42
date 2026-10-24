-- 即時位置（計畫 §7.3、Phase 4）：只追蹤有人駕駛的受保護車與它拖著的車，精確座標只在 server RAM；
-- 送 trackDelta 給有 TRACK 權限（owner 永遠有）且在線的人。每車最多 2 Hz、移動 ≥1 格才送，
-- 另每 5 秒心跳一次讓剛取得權限的人也拿得到「即時」。玩家下車時把最後位置收斂進帳本 lastKnown。
-- ponytail: trackDelta 是「最新值覆蓋」，不帶 seq；遺失只會讓標記暫時停在舊點，下一次取樣或快照即恢復。
if isClient() then return end
require "MinidoracatVehicleManager_OwnershipSystem"
require "MinidoracatVehicleManager_Server"

local MVM = MinidoracatVehicleManager
local O, S = MVM.Own, MVM.Srv
-- seat／who：IsoPlayer → 上次看到他坐的車／當時的 principal（只記在車上的人）；seen：IsoPlayer → 最後一次在在線清單看到的時間。
-- online：tick 進行中的 principal → 在線玩家。players／vehicles／count：這一輪的在線玩家與他們坐的車（重複使用的陣列）
local T = { last = {}, seat = {}, who = {}, seen = {}, lastRun = 0, online = nil, players = {}, vehicles = {}, count = 0 }
MVM.Tracking = T

local SAMPLE_MS, HEARTBEAT_MS = 500, 5000

local function now() return getTimestampMs() end

local TRACK = MVM.ACTIONS.TRACK

-- 這次 tick 的 principal → 在線玩家；tick 以外（直接呼叫 sample／leave）照舊每次重算
local function onlineNow()
    if T.online then return T.online end
    return S.online()
end

-- 非車主收得到位置＝S.row 會給他這一列（紀錄可授權、他是成員或陣營成員）且合併後的權限有 TRACK。
-- 直接算位元，不組整列（S.row 每次都要重算陣營成員、停車保全狀態並配一張表）
local function canTrack(rec, who, members)
    if not O.AUTHORIZABLE[rec.recordState] or rec.recordState == "QUARANTINED" then return false end
    if MVM.hasBit(O.grantBits(rec, who) or 0, TRACK) then return true end
    return members[who] == true and members[rec.ownerUser] == true and MVM.hasBit(rec.factionActionBits or 0, TRACK)
end

-- 會收到這台車即時位置的在線玩家：S.audience 的人（車主、分享成員、陣營成員）裡，車主一定收（S.row 對車主一律回 OWNER），
-- 其他人要有 TRACK。陣營成員一台車只算一次
local function trackers(rec)
    local online, out = onlineNow(), {}
    local owner = rec.ownerUser
    if owner ~= nil and online[owner] then out[owner] = online[owner] end
    local members = O.factionMembers(rec)
    for _, g in ipairs(rec.grants or {}) do
        local who = g.user
        if out[who] == nil and online[who] and canTrack(rec, who, members) then out[who] = online[who] end
    end
    for who in pairs(members) do
        if out[who] == nil and online[who] and canTrack(rec, who, members) then out[who] = online[who] end
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
    if last then last.x, last.y, last.z, last.t = x, y, z, t
    else T.last[rec.oid] = { x = x, y = y, z = z, t = t } end
    for who, player in pairs(trackers(rec)) do
        S.send(player, "trackDelta", { oid = rec.oid, x = x, y = y, z = z, t = t }, who)
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

-- 玩家離開座位（下車、換車、身分變了、離線）：最後一次取樣並寫入帳本 lastKnown（低頻持久化，§7.3）；
-- 引擎在下車與車上斷線時也把車與拖掛寫進 vehicles.db（GameServer.java:2594-2595）
local function unseat(player)
    local prev = T.seat[player]
    T.seat[player], T.who[player], T.seen[player] = nil, nil, nil
    T.leave(prev)
end

-- 一位在線玩家的座位變化與取樣。who＝這一輪解出的 principal；沒有身分的人照舊不追蹤（等同不在 S.online 裡）
local function visit(player, v, who, t)
    local prev = T.seat[player]
    if v == nil and prev == nil then return end
    if prev ~= nil and (prev ~= v or who == nil or who ~= T.who[player]) then
        unseat(player)
        prev = nil
    end
    if v == nil or who == nil then return end
    if prev == nil then T.seat[player], T.who[player] = v, who end
    T.seen[player] = t
    if v:isDriver(player) then
        T.sample(v, false)
        local towed = v:getVehicleTowing()
        if towed then T.sample(towed, false) end
    end
end

function T.tick()
    local t = now()
    if t - T.lastRun < SAMPLE_MS then return end
    T.lastRun = t
    if O.state() == nil then return end
    O.ready() -- 觸發載入判定；RECOVERY_REQUIRED 仍唯讀追蹤（lookup 唯讀分支、observeVehicle 自己擋寫入）
    T.online = nil
    -- 先只問每位在線玩家坐哪台車；沒人在車上、也沒有上次在車上的人，這一輪就不解任何身分
    local list, players, vehicles = S.players(), T.players, T.vehicles
    local n, busy = list:size(), false
    for i = 1, n do
        local p = list:get(i - 1)
        local v = p:getVehicle()
        players[i], vehicles[i] = p, v
        if v ~= nil then busy = true end
    end
    for i = n + 1, T.count do players[i], vehicles[i] = nil, nil end
    T.count = n
    for _ in pairs(T.seat) do busy = true; break end
    if not busy then return end
    -- 有人在車上：對全部在線玩家各解一次 principal（收件者要用），同一輪的座位判定與送出都用這一份
    local online, whoOf = {}, {}
    for i = 1, n do
        local who = O.principal(players[i])
        if who then online[who], whoOf[players[i]] = players[i], who end
    end
    T.online = online
    for i = 1, n do visit(players[i], vehicles[i], whoOf[players[i]], t) end
    -- 在車上直接斷線（或身分沒了）：同樣收斂最後位置
    local gone = nil
    for player in pairs(T.seat) do
        if T.seen[player] ~= t then gone = gone or {}; gone[#gone + 1] = player end
    end
    for _, player in ipairs(gone or {}) do unseat(player) end
    T.online = nil
end

Events.OnTick.Add(T.tick)
