-- Economy 選用整合：付費綁定名額（Economy API rev 2 通用權益＋rentals 與 setPlan 能力，產品 vehicle_slot，付款即生效）。
-- 只在 dedicated server、Economy 在場且宣告 entitlements、rentals、setPlan 能力時啟用；不 require Economy（它不在 mod.info require=）。
-- 分工：Economy 管錢包、幣別與收費流程（報價、扣款、退款、租約、自動續租）；方案（價格、幣別、上限、天數、開關）歸 VM，
-- 由 PaidSlots.lua 從設定檔與管理指令經 setPlan 送進 Economy。玩家付款由 client 直接走 Economy 的 quote／purchase。
-- 本檔只做三件事：註冊來源與產品、把 Economy 的可用名額（entitlement.usable）加到綁定上限、
-- 權益變更時重送該玩家的車隊快照。不可用（未安裝／舊版／註冊失敗／查詢失敗／欄位不合）＝付費名額 0：
-- 只擋新增綁定，既有綁定與紀錄一律不動（超額的車照樣受保護）。
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

-- 付費名額要能讓綁定變多才准購買：帳本 READY、伺服器沒因 DropOffWhiteListAfterDeath 擋新綁定。
-- 不以目前已用量擋：買名額正是為了提高上限。回 true 或 false, 原因碼（client 以 IGUI_MVM_Reason_* 顯示）
function E.validatePurchase(username, productId, kind, quantity, projected)
    local ok, reason = O.ready()
    if not ok then return false, reason end
    if O.configBlocked() then return false, "CONFIG_BLOCKED" end
    return true
end

-- Economy 在權益提交完成後通知：該玩家在線且有車隊串流時重送快照（名額與分項隨之更新）
function E.onChanged(username, productId)
    if productId ~= MVM.ECON_PRODUCT or type(username) ~= "string" or O.state() == nil or S.R.streams[username] == nil then return end
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
    local okP, res = pcall(src.registerProduct, { id = MVM.ECON_PRODUCT, nameKey = "IGUI_MVM_Product_vehicle_slot",
        defaults = E.DEFAULTS, instant = true, validatePurchase = E.validatePurchase })
    if not okP then return failed(res) end
    if type(res) ~= "table" or res.ok ~= true then return failed(type(res) == "table" and res.error or "register_failed") end
    if type(src.onEntitlementChanged) == "function" then
        local okChanged, changedErr = pcall(src.onEntitlementChanged, E.onChanged)
        if not okChanged then return failed(changedErr) end
    end
    E.src, E.status = src, "READY"
    MVM.log("Economy paid slots registered (" .. MVM.ECON_SOURCE .. "/" .. MVM.ECON_PRODUCT .. ").")
end

local function count(v) return (MVM.isInt(v) and v >= 0) and v or nil end
local lastReadErrorAt

-- 名額分項。paid 只信 server 正式欄位 usable（非負整數）；缺欄位／查詢失敗＝UNAVAILABLE、paid 0。
function E.summary(owner)
    local out = { economy = E.status, permanent = 0, rental = 0, paid = 0 }
    if E.src == nil or type(owner) ~= "string" then return out end
    local ok, res = pcall(E.src.getEntitlement, owner, MVM.ECON_PRODUCT)
    local ent, reason
    if not ok then reason = "exception: " .. tostring(res)
    elseif type(res) ~= "table" then reason = "invalid_response"
    elseif res.ok ~= true then reason = "rejected: " .. tostring(res.error)
    elseif type(res.entitlement) ~= "table" then reason = "invalid_entitlement"
    else ent = res.entitlement end
    local usable = ent and count(ent.usable)
    if usable == nil then
        out.economy = "UNAVAILABLE"
        local now = getTimestampMs()
        if lastReadErrorAt == nil or now - lastReadErrorAt >= 60000 then
            lastReadErrorAt = now
            MVM.log("Economy getEntitlement failed source=" .. MVM.ECON_SOURCE .. " product=" .. MVM.ECON_PRODUCT
                .. " owner=" .. owner .. ": " .. (reason or "invalid_usable"))
        end
        return out
    end
    out.paid, out.permanent, out.rental = usable, count(ent.permanent) or 0, count(ent.rental) or 0
    out.state = type(ent.state) == "string" and ent.state or nil
    return out
end

O.paidSlots = function(owner) return E.summary(owner).paid end

if Events.OnServerStarted then Events.OnServerStarted.Add(E.init) end
