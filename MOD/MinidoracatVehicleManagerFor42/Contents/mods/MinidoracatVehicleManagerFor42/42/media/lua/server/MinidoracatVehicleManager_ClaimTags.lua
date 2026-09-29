-- MSW（rSemiTruck 多槽拖車，Workshop 3409472393）相容：只在 MSW 啟用時，於伺服器車身 modData 寫它認得的綁定鍵，
-- 讓它自己的載車檢查擋下沒有拖曳權限的人（MSW_Common_Commands.lua canPlayerLoadVehicleByClaims:1699-1728 →
-- hasSDVCAccess:1611-1634、hasGenericOwnerKeyAccess:1678-1697；兩者都放行 access level admin／moderator）。
-- MSW 的卸車（launchVehicle:2243-2379）完全不檢查，這裡擋不到；玩家端另有 ClientGuards 擋一般客戶端。
--
-- 注意：車身 modData 是玩家端可竄改的資料（ObjectModDataPacket 會覆寫 server 值，E2E trust-mp），這層防護與原版鎖車同級；
-- 本 MOD 自己的授權仍只看帳本。寫入也會讓車主與可拖曳者的帳號出現在車身資料裡（所有玩家端都讀得到）。
--
-- 鍵：SDVCOwner＋SDVCAllowedEnter（逗號分隔）。這是 SDVC 綁車 MOD 的鍵，正式服沒裝 SDVC；正式服已裝的 MOD 中只有 MSW
-- 讀它們（伺服器載車檢查，以及玩家端拖掛檢查 rLib.Events/Vehicle.lua:99-146），並在裝卸時隨快照保存還原（:1504-1520）。
-- MSW 的比對（:1534-1548,1611-1634）：owner 去頭尾空白後與玩家名相等才放行，空字串或 "false" 當成沒綁；名單以逗號切開、
-- 每段去空白。車主名不一定是登入帳號（MVCK 匯入的 OwnerPlayerID、no-steam 伺服器重生後的名字都沒經過
-- ServerWorldDatabase.isValidUserName），所以寫入前先檢查 T.safe：可拖曳名單裡不安全的名字不寫（只會少放行）；
-- 車主名不安全或車被隔離時，owner 寫成帶這筆紀錄 oid 的鎖定值（含 @ 與 ;，T.safe 不收，不會等於任何寫進去的名字），
-- 名單留空，MSW 對管理員以外的人一律拒絕。MSW 以玩家名認人，分割畫面的名字由客戶端填：這層防護與原版鎖車同級。
-- 標記鍵 MARK 記錄「這是本 MOD 寫的」，紀錄結束時只清自己寫的。
if isClient() then return end
require "MinidoracatVehicleManager_OwnershipSystem"

local MVM = MinidoracatVehicleManager
local O = MVM.Own
local T = { OWNER = "SDVCOwner", ALLOWED = "SDVCAllowedEnter", MARK = "MinidoracatVehicleManagerTags", LOCKED = "@MVM;locked;" }
MVM.ClaimTags = T

-- SP 的帳號是 local:N，MSW 比對不到玩家名稱：只在 dedicated／主機伺服器寫
function T.enabled()
    return isServer() and getActivatedMods():contains("rSemiTruck")
end

-- 能原樣寫進 MSW 名單的名字：非空、不是 "false"、沒有逗號（切段）、@ 與 ;（鎖定值用）、頭尾沒有空白（MSW 會去掉）
function T.safe(name)
    return type(name) == "string" and name ~= "" and name ~= "false" and not name:find("[,@;]")
        and not name:find("^%s") and not name:find("%s$")
end

-- 目前經指定分享或有效陣營共享而有 TOW 的帳號（不含車主、不含管理員越權、不含 T.safe 不收的名字），依帳號排序以便比對
function T.allowedOf(rec)
    local set = {}
    for _, g in ipairs(rec.grants or {}) do
        if MVM.bitsAllow(g.bits, "TOW") then set[g.user] = true end
    end
    if MVM.bitsAllow(rec.factionActionBits or 0, "TOW") then
        local members = O.factionMembers(rec)
        if members[rec.ownerUser] then for who in pairs(members) do set[who] = true end end
    end
    local list, keys = {}, {}
    for who in pairs(set) do
        if who ~= rec.ownerUser and T.safe(who) then list[#list + 1] = who; keys[who] = who end
    end
    list = MVM.sortByKey(list, keys)
    return #list > 0 and table.concat(list, ",") or nil
end

-- 已載入、三欄位一致的那台車（移出世界的紀錄沒有車）
function T.findLoaded(rec)
    if rec.removedAtMs then return nil end
    local it = getCell():getVehicles():iterator()
    while it:hasNext() do
        local v = it:next()
        if v:getSqlId() == rec.sqlIdHint and v:getKeyId() == rec.keyIdHint and v:getScriptName() == rec.vehicleScript
            and not v:isRemovedFromWorld() then
            return v
        end
    end
    return nil
end

-- rec＝nil 或已結束：清掉本 MOD 寫的鍵。只有內容不同才寫入並 transmitModData（讓玩家端副本一致：
-- 玩家端送回整份車身 modData 時不會把鍵洗掉，MSW 玩家端的拖掛檢查也讀得到）
function T.sync(rec, vehicle)
    if not T.enabled() then return end
    if vehicle == nil then
        vehicle = rec and T.findLoaded(rec)
        if vehicle == nil then return end
    end
    local owner, allowed = nil, nil
    if rec and O.AUTHORIZABLE[rec.recordState] then
        if rec.recordState == "QUARANTINED" or not T.safe(rec.ownerUser) then owner = T.LOCKED .. rec.oid
        else owner, allowed = rec.ownerUser, T.allowedOf(rec) end
    end
    if owner == nil and not vehicle:hasModData() then return end
    local md = vehicle:getModData()
    if owner == nil then
        if rawget(md, T.MARK) == nil then return end
    elseif rawget(md, T.MARK) == true and rawget(md, T.OWNER) == owner and rawget(md, T.ALLOWED) == allowed then
        return
    end
    rawset(md, T.OWNER, owner)
    rawset(md, T.ALLOWED, allowed)
    rawset(md, T.MARK, owner ~= nil or nil)
    vehicle:transmitModData()
end

O.syncClaimTags = T.sync

if Events.OnServerStarted then
    Events.OnServerStarted.Add(function()
        MVM.log("MSW claim tags " .. (T.enabled() and "enabled" or "off (rSemiTruck not active)"))
    end)
end
