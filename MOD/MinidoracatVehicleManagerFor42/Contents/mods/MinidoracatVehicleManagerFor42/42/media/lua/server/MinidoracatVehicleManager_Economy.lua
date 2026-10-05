-- Economy 選用整合：付費名額（Economy API rev 2 通用權益＋rentals 與 setPlan 能力，付款即生效）。同一來源兩個產品：
-- vehicle_slot（綁定名額）與 guard_slot（停車保全名額，只在保全模式 SLOTS 時可購買）。
-- 只在 dedicated server、Economy 在場且宣告 entitlements、rentals、setPlan 能力時啟用；不 require Economy（它不在 mod.info require=）。
-- 分工：Economy 管錢包、幣別與收費流程（報價、扣款、退款、租約、自動續租）；方案（價格、幣別、上限、天數、開關）歸 VM，
-- 由 PaidSlots.lua 從設定檔與管理指令經 setPlan 送進 Economy。玩家付款由 client 直接走 Economy 的 quote／purchase。
-- 本檔：註冊來源與產品、把綁定名額的可用數（entitlement.usable）加到綁定上限、提供保全付費名額（MVM.Parked 用），
-- 權益變更時依產品分派（綁定 → RentLock 重算到期鎖定；保全 → 暫停通知）並重送該玩家的車隊快照。
-- 不可用（未安裝／舊版／註冊失敗／查詢失敗／欄位不合）＝付費名額 0：只擋新增綁定，既有綁定與紀錄一律不動；
-- 租約到期的鎖定與釋出只在 READY 且查詢成功時由 RentLock.lua 處理。
if isClient() then return end
require "MinidoracatVehicleManager_OwnershipSystem"
require "MinidoracatVehicleManager_Server"

local MVM = MinidoracatVehicleManager
local O, S = MVM.Own, MVM.Srv
-- status：OFF（SP，免費核心不串 Economy）／ABSENT（沒裝）／UNSUPPORTED（缺 rev 2 權益、rentals 或 setPlan 能力）／FAILED／READY
local E = { status = "OFF", src = nil, error = nil, currencies = {} }
MVM.Econ = E

-- Economy 還沒有這個商品的方案時用的初值：兩種販售預設關閉，由服主在設定檔或管理視窗開啟
E.DEFAULTS = {
    permanentEnabled = false, permanentCurrency = "survivor", permanentPrice = 1000, permanentLimit = 10,
    rentalEnabled = false, rentalCurrency = "survivor", rentalPrice = 250, rentalLimit = 5, rentalDays = 7,
    graceHours = 24, reminderHours = 24, autoRenewAllowed = true,
}
E.REASON_CODES = { "entitlement_purchase", "entitlement_renewal", "entitlement_refund" }

-- Economy server facade；舊版（rev 1）、缺權益能力、還是單一租約（沒有 rentals）或方案仍歸 Economy（沒有 setPlan）回 nil
function E.api()
    local api = MinidoracatEconomy and MinidoracatEconomy.v1
    local caps = api and api.CAPABILITIES
    if api and api.API_MAJOR == 1 and (api.API_REVISION or 0) >= 2 and type(caps) == "table"
        and caps.entitlements == true and caps.rentals == true and caps.setPlan == true and type(api.registerSource) == "function" then
        return api
    end
    return nil
end

-- 付費名額要能讓綁定變多才准購買：帳本 READY、伺服器沒因 DropOffWhiteListAfterDeath 擋新綁定；
-- 保全名額只在保全模式 SLOTS 時有用（其他模式沒有名額可加）。
-- 不以目前已用量擋：買名額正是為了提高上限。回 true 或 false, 原因碼（client 以 IGUI_MVM_Reason_* 顯示）
function E.validatePurchase(username, productId, kind, quantity, projected)
    local ok, reason = O.ready()
    if not ok then return false, reason end
    if O.configBlocked() then return false, "CONFIG_BLOCKED" end
    if productId == MVM.GUARD_PRODUCT and MVM.guardMode() ~= MVM.GUARD.SLOTS then return false, "GUARD_NOT_SLOTS" end
    return true
end

-- Economy 在權益提交完成後通知（同一來源的產品共用一個監聽；進入寬限、到期、租約移除也會通知）：
-- 綁定名額 → RentLock 重算到期鎖定；保全名額 → 超出名額的保全暫停時通知車主。之後該玩家在線且有車隊串流時重送快照
function E.onChanged(username, productId)
    if type(username) ~= "string" or O.state() == nil then return end
    if productId == MVM.ECON_PRODUCT then
        if MVM.RentLock then MVM.RentLock.evaluate(username) end
    elseif productId == MVM.GUARD_PRODUCT then
        E.guardFresh[username] = nil -- 下一次 guardPaid 重讀
        if MVM.Parked then MVM.Parked.limitChanged(username) end
    else
        return
    end
    if S.R.streams[username] == nil then return end
    local player = S.online()[username]
    if player then S.snapshot(player, username) end
end

local function failed(err)
    E.status, E.error = "FAILED", tostring(err)
    MVM.log("Economy paid slots unavailable: " .. E.error .. ". Free claim limits still apply.")
end

-- 開服偵測一次（Economy 允許在它的 ModData 初始化前註冊，不需重試）
function E.init()
    E.src, E.error = nil, nil
    if not isServer() then E.status = "OFF"; return end
    if MinidoracatEconomy == nil then E.status = "ABSENT"; return end
    local api = E.api()
    if api == nil then
        E.status = "UNSUPPORTED"
        MVM.log("Economy found without entitlement API rev 2 with rentals and setPlan: paid slots disabled.")
        return
    end
    local currencies = {}
    for id in pairs(MinidoracatEconomy.CURRENCIES or {}) do currencies[#currencies + 1] = id end
    E.currencies = currencies
    local ok, src, err = pcall(api.registerSource, { modId = MVM.ECON_SOURCE, nameKey = "IGUI_MVM_SourceName",
        displayName = { EN = "Vehicle Manager" }, currencies = currencies, reasonCodes = E.REASON_CODES })
    if not ok then return failed(src) end
    if type(src) ~= "table" or type(src.registerProduct) ~= "function" or type(src.getEntitlement) ~= "function" then
        return failed(err or "no_entitlement_methods")
    end
    for _, id in ipairs(MVM.PRODUCTS) do
        local okP, res = pcall(src.registerProduct, { id = id, nameKey = "IGUI_MVM_Product_" .. id,
            defaults = E.DEFAULTS, instant = true, validatePurchase = E.validatePurchase })
        if not okP then return failed(res) end
        if type(res) ~= "table" or res.ok ~= true then return failed(type(res) == "table" and res.error or "register_failed") end
    end
    if type(src.onEntitlementChanged) == "function" then
        local okChanged, changedErr = pcall(src.onEntitlementChanged, E.onChanged)
        if not okChanged then return failed(changedErr) end
    end
    E.src, E.status = src, "READY"
    MVM.log("Economy paid slots registered (" .. MVM.ECON_SOURCE .. "/" .. table.concat(MVM.PRODUCTS, ",") .. ").")
end

local function count(v) return (MVM.isInt(v) and v >= 0) and v or nil end
local lastReadErrorAt = {}

-- 讀一個產品的權益。只信 server 正式欄位 usable（非負整數）：查詢失敗或欄位不合回 nil（每個產品每分鐘最多記一次 log）
function E.entitlement(owner, product)
    if E.src == nil or type(owner) ~= "string" then return nil end
    local ok, res = pcall(E.src.getEntitlement, owner, product)
    local ent, reason
    if not ok then reason = "exception: " .. tostring(res)
    elseif type(res) ~= "table" then reason = "invalid_response"
    elseif res.ok ~= true then reason = "rejected: " .. tostring(res.error)
    elseif type(res.entitlement) ~= "table" then reason = "invalid_entitlement"
    else ent = res.entitlement end
    if ent and count(ent.usable) then return ent end
    local now = getTimestampMs()
    if lastReadErrorAt[product] == nil or now - lastReadErrorAt[product] >= 60000 then
        lastReadErrorAt[product] = now
        MVM.log("Economy getEntitlement failed source=" .. MVM.ECON_SOURCE .. " product=" .. tostring(product)
            .. " owner=" .. owner .. ": " .. (reason or "invalid_usable"))
    end
    return nil
end

-- 名額分項（product 省略＝綁定名額）。缺欄位／查詢失敗＝UNAVAILABLE、paid 0。
function E.summary(owner, product)
    local out = { economy = E.status, permanent = 0, rental = 0, paid = 0 }
    if E.src == nil or type(owner) ~= "string" then return out end
    local ent = E.entitlement(owner, product or MVM.ECON_PRODUCT)
    if ent == nil then
        out.economy = "UNAVAILABLE"
        return out
    end
    out.paid, out.permanent, out.rental = ent.usable, count(ent.permanent) or 0, count(ent.rental) or 0
    out.state = type(ent.state) == "string" and ent.state or nil
    return out
end

O.paidSlots = function(owner) return E.summary(owner).paid end

-- 保全付費名額：查詢失敗時沿用這位車主上次讀到的值（RAM），Economy 短暫出錯不會讓付費保全暫停；從沒讀到過＝0。
-- 停車保全每秒排名都要問（依保全名額模式）：讀到的值留 GUARD_TTL_MS，權益變更通知（E.onChanged）時作廢，
-- 購買、到期即時生效；getEntitlement 每次組整份快照（含訂單與錢包），不能每秒每位車主都叫
local guardLast = {}
E.guardFresh = {}
E.GUARD_TTL_MS = 10000
function E.guardPaid(owner)
    if type(owner) ~= "string" then return 0 end
    local t = getTimestampMs()
    local at = E.guardFresh[owner]
    if at and t - at < E.GUARD_TTL_MS then return guardLast[owner] or 0 end
    local ent = E.entitlement(owner, MVM.GUARD_PRODUCT)
    if ent then guardLast[owner] = ent.usable end
    E.guardFresh[owner] = t
    return guardLast[owner] or 0
end

if Events.OnServerStarted then Events.OnServerStarted.Add(E.init) end
