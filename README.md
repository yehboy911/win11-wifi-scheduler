# Win11 Wi-Fi 定時排程

於 Windows 11 上以 PowerShell + Task Scheduler 自動 Enable/Disable
**Intel(R) Wi-Fi 6E AX211 160MHz** 網卡，模擬正常上下班時段的連線型態。

---

## 排程規則

| 動作 | Task Scheduler 觸發 | 腳本內隨機延遲 | 實際執行時間 | 對網卡 |
|---|---|---|---|---|
| 連線 (`netsh wlan connect`)    | 平日 08:00 | `Sleep Random(0, 3) min` | [08:00, 08:29] | radio 已開 → 直接連 SSID |
| 斷線 (`netsh wlan disconnect`) | 平日 19:30 | `Sleep Random(0, 3) min` | [19:30, 19:59] | **radio 不關**，只放掉 SSID |

> 注意：自 Phase 11 起改用純 `netsh wlan`，網卡 radio 保持開啟。副作用：工作列 Wi-Fi 圖示
> 在非工作時段也會亮著（就是空著沒 SSID 的扇形）。換來的好處是繞過了「Windows 把
> Disable-NetAdapter 解讀成主動斷線、之後不自動連」的 quirk。

- **平日** = 週一 ~ 週五，且不在 `holidays_<YYYY>.json` 名單內
- **每次連線時長**: 11h30m ~ 12h00m（自動滿足 ≥ 8.5h 的下限）
- **00:00 ~ 06:00 (Hour ∈ [0, 6))**: 即使手動觸發也會被腳本拒絕（安全保護）

---

## WiFi SSID 優先清單

`Enable-NetAdapter` 只負責把無線網卡通電；**真正能上網** 需要：
- L2: AP 關聯（Status=Up）
- L3: 802.1X 驗證通過 + DHCP 拿到 IP + NCSI 偵測到 Internet

實測 Windows `wlansvc` 自動連線偶發失敗，且 captive portal / 802.1X 認證待輸入會卡在
L2 而沒有真正 L3 連線。腳本內加了 wait + 強制連線 + L3 檢查：

```powershell
# Toggle-WiFi.ps1 頂端
$PreferredSSIDs = @('lenovo-5G', 'lenovo')   # 已排除 lenovo-internet (captive portal)
$AssocWaitSec   = 45   # 每個 SSID 給足 PEAP+DHCP+NCSI 完成 L3 偵測的秒數
```

### 前置：Win11 Location Services 必須開啟

`netsh wlan` 系列指令在 Win11 屬於 WLAN API，需要「位置權限」才能跑（否則回 `存取被拒`）。

```
Settings → Privacy & security → Location → 開啟「位置服務」
或 PowerShell: start ms-settings:privacy-location
```

未啟用時，腳本 log 會留下 `存取被拒` 字樣於 `netsh output:` 行 — 看到該關鍵字就先去開位置權限。

### 連線流程（Phase 11 起，純 netsh）

1. (防呆) 若網卡是 Disabled，先 Enable 並等 3 秒
2. 快速檢查：若已 online（用戶手動先連好了）→ ✓ 結束
3. 否則照 `$PreferredSSIDs` 順序直接 `netsh wlan connect name="..."`，每個試 45 秒
4. 任一達到 L3 上網 → CSV 寫 ✓；全失敗 → CSV 寫 ✗，task 標記 failed (exit 1)

最壞情況等 `2×45 ≈ 90` 秒（約 1.5 分鐘）就會有結論。

### 斷線流程

```powershell
netsh wlan disconnect interface="Wi-Fi"
```

只放掉 SSID，**不關 radio**。Get-NetAdapter Status 從 `Up` 變 `Disconnected`，但不會變 `Disabled`。

### 重要：成功標準是「真的上網」(L2 + L3)

L2 = `Get-NetAdapter` Status=Up；L3 = `Get-NetConnectionProfile` 滿足任一：
- `IPv4Connectivity = 'Internet'`（NCSI 偵測到對外網路）
- `NetworkCategory = 'DomainAuthenticated'`（連到 AD 公司網，即使 NCSI 還沒跟上）

| 狀態 | L2 | L3 | CSV |
|---|---|---|---|
| 真的上網 | Up | Internet 或 DomainAuthenticated | ✓ |
| 連到 AD 公司網（NCSI 未偵測完） | Up | DomainAuthenticated | ✓ |
| 卡 802.1X 認證待輸入 | Up | LocalNetwork / NoTraffic | ✗ |
| 連到 captive portal 但沒點頭 | Up | LocalNetwork | ✗ |
| 沒關聯到 AP | Disconnected | (n/a) | ✗ |

### 一次性設定（PEAP credential 儲存）

`lenovo` / `lenovo-5G` 是 WPA2-Enterprise + PEAP，profile 預設「認證已設定=否」，
所以自動連線會失敗（沒帶用戶帳密）。在 Win11 上做一次：

1. 點工作列 Wi-Fi → 選 `lenovo-5G` → 勾「自動連線」→ 點 連線
2. 輸入 AD 帳號密碼 → 勾「儲存」
3. 連上後跑 `netsh wlan show profile name="lenovo-5G" key=clear`，確認「**認證已設定: 是**」
4. 對 `lenovo` 重複一次（備援用）

之後排程觸發時，Windows 會帶儲存的 credential 自動完成 PEAP 驗證。

> 想加家裡 SSID？編 `$PreferredSSIDs` 陣列即可，其他邏輯不動。
> 順序越前面優先級越高，前面試成功就不會試後面。

---

## 檔案結構

```
C:\Tools\Win11-WiFi-Scheduler\
├── Toggle-WiFi.ps1         # 主腳本 (Connect / Disconnect)
├── Install-Tasks.ps1       # 一次性安裝 (admin)
├── Uninstall-Tasks.ps1     # 移除 Scheduled Tasks (admin)
├── holidays_2026.json      # 例假日清單 (年初手動更新)
├── README.md               # 本檔
├── wifi_scheduler.log      # 詳細執行紀錄 (runtime, append-only)
└── wifi_daily_summary.csv  # 一天一筆摘要 ✓/✗ (runtime, Excel 可開)
```

---

## 安裝步驟

1. 把整個 `win11-wifi-scheduler\` 資料夾複製/重新命名到 `C:\Tools\Win11-WiFi-Scheduler\`
2. **以系統管理員** 開啟 PowerShell（搜尋 PowerShell → 右鍵 → 以系統管理員身分執行）
3. 進入資料夾並執行安裝：
   ```powershell
   cd C:\Tools\Win11-WiFi-Scheduler
   .\Install-Tasks.ps1
   ```
4. 驗證：
   ```powershell
   Get-ScheduledTask -TaskName 'WiFi-*' | Format-Table TaskName, State, NextRunTime
   ```
   應該看到 `WiFi-Connect` 與 `WiFi-Disconnect` 兩個任務皆為 `Ready` 狀態。

---

## 解除安裝

```powershell
.\Uninstall-Tasks.ps1
```

---

## 手動測試

### 1. 乾跑（不動真網卡，但會寫 log）

```powershell
.\Toggle-WiFi.ps1 -Action Connect    -DryRun -Verbose
.\Toggle-WiFi.ps1 -Action Disconnect -DryRun -Verbose
```

### 2. 真跑（會 Sleep 0~29 分鐘後實際操作網卡）

```powershell
.\Toggle-WiFi.ps1 -Action Connect    -Verbose
.\Toggle-WiFi.ps1 -Action Disconnect -Verbose
```

### 2b. 真跑「測試模式」`-NoDelay`：跳過 Sleep，立即動網卡

```powershell
.\Toggle-WiFi.ps1 -Action Connect    -NoDelay -Verbose
.\Toggle-WiFi.ps1 -Action Disconnect -NoDelay -Verbose
```

⚠️ **僅限手動測試**。正式排程不要加 `-NoDelay` — 隨機 Sleep 是「模擬上下班」的關鍵設計。
- 會立刻 Enable/Disable + 寫 `wifi_daily_summary.csv` 一列
- log 內會看到 `NODELAY skip sleep (would have been N min)`

### 3. 直接手動觸發 Scheduled Task（會 Sleep 隨機後執行）

```powershell
Start-ScheduledTask -TaskName 'WiFi-Connect'
Start-ScheduledTask -TaskName 'WiFi-Disconnect'
```

---

## 例假日維護（每年初一次）

對照 [行政院人事行政總處](https://www.dgpa.gov.tw/) 公告：

1. 複製 `holidays_2026.json` → `holidays_2027.json`
2. 修改 `_meta.year` 為新年度
3. 更新 `dates` 陣列（**只列 Mon-Fri 之休假/補假日**，週末已自動跳過故不重複）
4. **不必動腳本** — `Toggle-WiFi.ps1` 會依 `(Get-Date).Year` 自動載入當年 JSON

> ⚠️ 內建的 `holidays_2026.json` 僅為 **best-effort**，請務必對照官方公告驗證日期。

---

## Log 範例

```
[2026-05-20 08:03:47] CONNECT    DELAY      11 min (random 0..29)
[2026-05-20 08:14:48] CONNECT    DONE       Enable adapter (Intel(R) Wi-Fi 6E AX211 160MHz)
[2026-05-20 19:38:21] DISCONNECT DELAY      8 min (random 0..29)
[2026-05-20 19:46:23] DISCONNECT DONE       Disable adapter (Intel(R) Wi-Fi 6E AX211 160MHz)
[2026-05-23 08:00:01] CONNECT    SKIP       weekend (Saturday)
[2026-05-26 08:00:01] CONNECT    SKIP       holiday (2026-05-26)
[2026-05-27 03:00:00] CONNECT    SKIP       forbidden-hours (current hour=3, blocked=[0..6))
```

---

## Daily Summary CSV (一天一筆查詢用)

除了 `wifi_scheduler.log` 這個詳細稽核日誌（含 SKIP / WARN / DRYRUN / ERROR），
腳本還會額外維護一份 `wifi_daily_summary.csv`，**一天一列** 用 ✓ / ✗ 標記成功與失敗，
方便用 Excel 開來日常檢查。

### 格式

| Date | Connect | ConnectTime | Disconnect | DisconnectTime |
|---|---|---|---|---|
| 2026-05-20 | ✓ | 08:11 | ✓ | 19:48 |
| 2026-05-21 | ✓ | 08:23 | ✗ | 19:31 |
| 2026-05-22 | ✓ | 08:05 | *(空)* | *(空)* |

### 規則

- **✓** = `Enable-NetAdapter` / `Disable-NetAdapter` 回傳成功
- **✗** = 拋出例外（網卡找不到、權限不足等；詳細錯誤訊息看 `wifi_scheduler.log` 同一時刻的 `ERROR` 行）
- **空格** = 當天該動作 **還沒發生**（例：中午翻看時下班尚未到，或關機/休眠錯過了下班觸發）
- **不寫入** 此 CSV 的情境：週末 / 例假日 / forbidden-hours / DryRun（因為網卡沒實際被操作）
- 寫入方式：upsert — 找到今天的 row 就更新對應欄位，沒有就 append
- 編碼：UTF-8 + BOM + CRLF → Excel 雙擊直接打開，✓/✗ 不會亂碼

### 用 Excel / PowerShell 查詢

```powershell
# 列出全部 (Excel 風格)
Import-Csv .\wifi_daily_summary.csv | Format-Table -AutoSize

# 找所有失敗的日子
Import-Csv .\wifi_daily_summary.csv | Where-Object { $_.Connect -eq '✗' -or $_.Disconnect -eq '✗' }

# 找尚未斷線的 (機器關機/休眠錯過)
Import-Csv .\wifi_daily_summary.csv | Where-Object { $_.Connect -ne '' -and $_.Disconnect -eq '' }

# 統計本月成功率
Import-Csv .\wifi_daily_summary.csv |
    Where-Object { $_.Date -like '2026-05-*' } |
    Group-Object { $_.Connect } |
    Format-Table Name, Count
```

直接在 Excel 開啟即可看到對齊的表格與 ✓/✗ 符號。

---

## 故障排除

| 症狀 | 對策 |
|---|---|
| `Enable-NetAdapter` 找不到網卡 | 跑 `Get-NetAdapter` 確認名稱；把實際 `InterfaceDescription` 貼進 `Toggle-WiFi.ps1` 開頭的 `$AdapterDesc` |
| Scheduled Task 沒在預期時間觸發 | 開 `taskschd.msc` → 找 `WiFi-Connect` → 看「歷史記錄」是否有錯誤碼；確認登入帳號權限 |
| 觸發了但網卡沒動 | 看 `wifi_scheduler.log` 末行；若有 `ERROR` 多半是缺 admin token → 重跑 `Install-Tasks.ps1` |
| 想立即驗證觸發行為 | `Start-ScheduledTask -TaskName 'WiFi-Connect'` 強制觸發 |
| holidays JSON 失敗 | `Get-Content holidays_2026.json -Raw \| ConvertFrom-Json` 檢查 JSON 合法性；log 內會印 `WARN holiday json parse failed` |
| 想完全停掉排程 | `.\Uninstall-Tasks.ps1`（保留腳本檔以便日後重裝） |
| 跑 .ps1 出現「安全性警告」要每次按 R | `Unblock-File -Path C:\Tools\win11-wifi-scheduler\*.ps1`（一次性解除 MOTW；Scheduled Task 走 `-ExecutionPolicy Bypass` 不受此影響） |

---

## 已知限制

- **沒有跨夜支援**：若需要凌晨自動連線（如夜班），本腳本會被 `forbidden-hours` (00:00-06:00) 拒絕
- **單一網卡**：只處理 Intel Wi-Fi 6E AX211；若換網卡需改 `$AdapterDesc`
- **無通知**：純定時、無 Email/Teams 通知
- **依靠 Task Scheduler**：若 Win11 已停用工作排程器服務，本方案失效
