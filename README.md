# Minidoracat Vehicle Manager for B42

提供車輛綁定、所有權保護、個人與陣營車隊管理，以及 MiniMap 追蹤與 Economy 租賃整合的車輛管理系統

Project Zomboid Build 42 MOD。

## 開發狀態

尚未首發。綁定、保護、分享、車隊視窗、小地圖追蹤與 MVCK 移轉已完成並通過本機多人實機測試。

## 功能

- 綁定車輛（綁帳號，角色死亡不失去），每人上限由伺服器設定
- 伺服器權威保護：未授權者的開關門、解鎖、上車、發動、加油抽油、放氣、裝拆零件、修理、砸窗、拖曳一律拒絕，並把車況推回原樣
- 車主虛擬鑰匙（可關閉）
- 分享給指定玩家或陣營，逐項授權；車主權限（改名、分享、解除、轉讓）不可分享
- 車隊視窗：我的車、分享給我、管理員頁
- 選用 MiniMap：自己的車與有「查看位置」權限的分享車顯示在地圖上；每台車可自訂圖示、顏色與大小（只存本機）
- 從 Mysterious Vehicle Claim Key 移轉既有綁定

**保護範圍的誠實說明**：保護的是一般玩家操作。武器、殭屍、碰撞造成的損傷不在範圍內；改機客戶端可能短暫坐上座位，伺服器巡查約一秒內發現並處置（可設定為只記錄或移出車外）。

規劃中（未做）：以道具或 Economy 貨幣增加綁定名額、日租／月租。

## 依賴

- **必要**：`MinidoracatUIFor42`（介面框架，需 API rev 9 以上：視窗、頁籤、輸入框、按鈕、開關、確認框、色盤、滑桿與車型圖示都來自框架）。
- **選用**：`MinidoracatMiniMapFor42`（地圖追蹤，需含 marker API v2 的版本）、`MinidoracatEconomyFor42`（尚未串接）。沒裝時核心照常運作。

## 從 Mysterious Vehicle Claim Key 移轉（伺服器管理員）

1. 先做完整備份（世界存檔資料夾一起備份）。
2. 把本 MOD 加進 `Mods=`（MVCK 可以先留著），啟動伺服器。
3. 管理員在車隊視窗管理頁按「從 MVCK 匯入全部綁定」：已載入的車當場轉入，其餘在車輛下次出現時自動轉入。畫面會顯示新匯入幾筆、已轉入幾台、還在等幾台。
4. 可以重複按：只會補進之後才在 MVCK 綁的車，不會重複匯入。**不會刪除 MVCK 的資料。**
5. 確認沒問題後，自行把 MVCK 從 `Mods=` 移除即可。兩個 MOD 並存期間，兩邊的保護都會生效。
6. 等不到車出現的待轉項，超過沙盒設定天數（預設 30）會刪除並寫入稽核記錄。MVCK 的權限欄位不匯入，分享需車主重新設定。

## 資料存在哪裡（伺服器）

| 內容 | 位置 |
|---|---|
| 帳本（綁定、分享、登入紀錄、名額、待轉） | 世界存檔資料夾 `gos_MinidoracatVehicleManagerOwnership*.bin`：主檔只存中繼資料，紀錄分散在 `_1`、`_2`… 分片，滿了自動開新分片，**沒有全服綁定上限** |
| 哨兵（偵測帳本遺失或被換成舊檔） | 世界存檔資料夾 `global_mod_data.bin` |
| 給人看的綁定清單（唯讀，改了不會回寫） | `Zomboid/Lua/MinidoracatVehicleManager/<伺服器名>/vehicles.json`，帳本變動後約 10 秒內更新 |
| 車輛位置日誌 | 同資料夾 `positions.txt` |
| 稽核記錄 | `Zomboid/Logs/*_MVM.txt` |

帳本和世界一起在存檔時寫出。伺服器崩潰沒存檔時，帳本回到上次存檔；但引擎在上下車、車上斷線時就已把車的座標寫進 `vehicles.db`，本 MOD 也在同時寫入 `positions.txt`，重啟時會用它把車的最後位置補回來。

**還原備份時**：一併刪掉 `positions.txt`，否則裡面比備份新的座標會先顯示出來（車被載入時會自動校正）。

稽核記錄在伺服器 `Logs/*_MVM.txt`。

## 安裝

- Steam Workshop：（首次上傳後補上連結）
- 手動安裝：把 `MOD/MinidoracatVehicleManagerFor42/Contents/mods/MinidoracatVehicleManagerFor42` 複製到 `%USERPROFILE%\Zomboid\mods\` 並將資料夾改名為 `MinidoracatVehicleManagerFor42`

## 開發

- `link_workshop.bat`：手動同步、狀態檢查與歸檔卸載（實體副本）
- `PZ_Test.bat`：啟動前自動同步 MOD 與家族依賴；Steam／no-Steam／Debug／多開皆保留。資料邊界見 `../pz-family-docs/tools.md`

## 版本

版本號格式：`{PZ 版本}-{mod 版本}`（例 `42.20.4-0.1.0`），詳見 [CHANGELOG.md](CHANGELOG.md)。

## 作者

Minidoracat — [Discord](https://discord.gg/Gur2V67) | [Twitch](https://www.twitch.tv/minidoracat)

### 發布到 Workshop

雙擊 `Publish_Workshop.bat`：先確認 Steam 用戶端已以作者帳號登入（未登入會喚起 Steam 並等你登入後重試），
再選擇更新 MOD 內容（含 `STEAM_CHANGELOG.md` 更新說明）／GIF 封面／簡介／全部；提交後回查 Steam，
任一不符即以非零碼結束。設定在 `scripts/workshop_publish.json`（Workshop ID、簡介語言槽來源、GIF 路徑）。

```
uv run --no-project python -B scripts/publish_workshop.py --mode all --yes       # 自動化／AI；或 content / preview / description
uv run --no-project python -B scripts/publish_workshop.py --mode all --dry-run   # 只檢查、顯示計畫
```

退出碼：`0` 成功／`2` 參數或取消／`3` 未登入、帳號不是擁有者／`4` 前置檢查失敗／`5` 提交失敗／`6` 已提交但回查不符。
網頁動態封面放 `MOD/<資料夾>/workshop/preview.gif`（不在 `Contents/`，不會下載給玩家）；遊戲內上傳器仍用 `preview.png`，
且每次會把網頁封面覆回靜態，需要動態封面時一律改用本工具發布。
