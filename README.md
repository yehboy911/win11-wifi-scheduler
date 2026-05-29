# Win11 Wi-Fi 定時排程

於 Windows 11 上以 PowerShell + Task Scheduler 自動 Enable/Disable
**Intel(R) Wi-Fi 6E AX211 160MHz** 網卡，模擬正常上下班時段的連線型態。

---

## 排程規則

| 動作 | Task Scheduler 觸發 | 腳本內隨機延遲 | 實際執行時間 | 對網卡 |
|---|---|---|---|---|
| 連線 (`netsh wlan connect`)    | 平日 08:00（可於 `wifi_scheduler_config.json` 調整） | `Sleep Random(0, 9) min` | 約 10 分鐘窗 | radio 已開 → 直接連 SSID |
| 斷線 (`netsh wlan disconnect`) | 平日 19:30 | `Sleep Random(0, 9) min` | [19:30, 19:39] | **radio 不關**，只放掉 SSID |

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

### 一次性設定（PEAP credential 儲存）— **必做**

`lenovo` / `lenovo-5G` 是 WPA2-Enterprise + PEAP。僅勾「自動連線」**不夠**：
排程在背景 session 常無法完成 802.1X，會出現 log 裡 `netsh exit=0` 但 CSV 仍 ✗，
或假成功 `already online` 實際仍要在 Wi-Fi 面板手動點「連線」。

在 Win11 上做一次：

1. 點工作列 Wi-Fi → 選 `lenovo-5G` → 勾「自動連線」→ 點 連線
2. 輸入 AD 帳號密碼 → 勾「儲存」
3. 連上後跑 `netsh wlan show profile name="lenovo-5G" key=clear`，確認「**認證已設定: 是**」
4. 對 `lenovo` 重複一次（備援用）

之後排程觸發時，Windows 會帶儲存的 credential 自動完成 PEAP 驗證。

**排程必須用 Interactive 登入**（`Install-Tasks.ps1` 已設定）：
僅在「你已登入 Windows」時執行，才能讀取 DPAPI 保護的 Wi-Fi 密碼。
安裝時**不需輸入 Windows 帳號密碼**（以目前登入者自動註冊，與手動建任務相同）。
若曾用舊版安裝（背景 Password/S4U），請**以系統管理員重跑** `.\Install-Tasks.ps1`。

安裝後確認：

```powershell
Get-ScheduledTask -TaskName 'WiFi-*' | Select-Object TaskName, @{N='Logon';E={$_.Principal.LogonType}}
# WiFi-Connect     → Interactive（目前登入者，讀 PEAP 憑證）
# WiFi-Disconnect  → ServiceAccount（SYSTEM，鎖定螢幕也可斷線）
```

> 想加家裡 SSID？編 `$PreferredSSIDs` 陣列即可，其他邏輯不動。
> 順序越前面優先級越高，前面試成功就不會試後面。

---

## 檔案結構

```
C:\Tools\Win11-WiFi-Scheduler\
├── Toggle-WiFi.ps1         # 主腳本 (Connect / Disconnect)
├── Install-Tasks.ps1       # 一次性安裝 (admin)
├── Uninstall-Tasks.ps1     # 移除 Scheduled Tasks (admin)
├── Run-WiFi-Connect.cmd    # 排程啟動器（給 Task Scheduler 呼叫）
├── Run-WiFi-Disconnect.cmd
├── WiFi-Menu.ps1           # 互動選單（不覆蓋原腳本）
├── WiFi-Config.ps1         # 選單用設定 helper
├── wifi_scheduler_config.json  # 隨機 Sleep 等使用者設定
├── holidays_2026.json      # 例假日清單 (年初手動更新)
├── README.md               # 本檔
├── wifi_scheduler.log      # 詳細執行紀錄 (runtime, append-only)
└── wifi_daily_summary.csv  # 一天一筆摘要 ✓/✗ (runtime, Excel 可開)
```

---

## 安裝步驟

1. 把整個 `win11-wifi-scheduler\` 資料夾複製/重新命名到 `C:\Tools\Win11-WiFi-Scheduler\`
2. **以系統管理員** 開啟 PowerShell（搜尋 PowerShell → 右鍵 → 以系統管理員身分執行）
3. （選用）編輯 `wifi_scheduler_config.json` 調整連線時間與隨機 Sleep。
4. 進入資料夾並執行安裝（會讀取設定檔並同步 `MaxDelayMinutes`）：
   ```powershell
   cd C:\Tools\Win11-WiFi-Scheduler
   .\Install-Tasks.ps1
   ```
5. 依下方 [安裝後驗證](#安裝後驗證) 跑一輪檢查。

---

## 常用指令速查

路徑以下皆假設 `cd C:\Tools\win11-wifi-scheduler`（或你的實際資料夾）。

| 用途 | 指令 | 需管理員 |
|------|------|----------|
| 安裝 / 重裝排程 | `.\Install-Tasks.ps1` | 是 |
| 移除排程 | `.\Uninstall-Tasks.ps1` | 是 |
| 互動選單 | `.\WiFi-Menu.ps1` | 部分選項 |
| 立即連線（跳過 Sleep） | `.\Toggle-WiFi.ps1 -Action Connect -NoDelay -Verbose` | 否 |
| 立即斷線（跳過 Sleep） | `.\Toggle-WiFi.ps1 -Action Disconnect -NoDelay -Verbose` | 否 |
| 乾跑（不動網卡） | `.\Toggle-WiFi.ps1 -Action Connect -DryRun -Verbose` | 否 |
| 測排程啟動方式 | `.\Test-ScheduledWiFi.ps1` | 否 |
| 強制觸發 Connect 排程 | `Start-ScheduledTask -TaskName 'WiFi-Connect'` | 否 |
| 強制觸發 Disconnect 排程 | `Start-ScheduledTask -TaskName 'WiFi-Disconnect'` | 否 |
| 看排程狀態 | `Get-ScheduledTask -TaskName 'WiFi-*'` | 否 |
| 看詳細 log | `Get-Content .\wifi_scheduler.log -Tail 15` | 否 |
| 看每日摘要 | `Import-Csv .\wifi_daily_summary.csv; Select-Object -Last 7` | 否 |

---

## 安裝後驗證

建議依序做 **四層**檢查；通過即代表安裝與腳本路徑正常。

### 1. 安裝輸出（`Install-Tasks.ps1`）

成功時應看到類似：

```
Install-Tasks.ps1 2026-05-29c (pathOn/pathOff launcher fix)
On launcher  (.cmd): C:\Tools\win11-wifi-scheduler\Run-WiFi-Connect.cmd
Off launcher (.cmd): C:\Tools\win11-wifi-scheduler\Run-WiFi-Disconnect.cmd
[OK] WiFi-Connect  (08:00  Run-WiFi-Connect.cmd  Logon=Interactive)
[OK] WiFi-Disconnect  (19:30  Run-WiFi-Disconnect.cmd  Logon=ServiceAccount)
```

新安裝時 `Last=1999/11/30`、`Result=267011`（尚未執行過）屬正常。

### 2. 排程動作路徑（必查）

Connect 的 `Execute` **必須是 `.cmd` 檔**，不能只有資料夾：

```powershell
(Get-ScheduledTask -TaskName 'WiFi-Connect').Actions | Format-List Execute, WorkingDirectory
(Get-ScheduledTask -TaskName 'WiFi-Disconnect').Actions | Format-List Execute, WorkingDirectory
```

| 任務 | Execute 預期 |
|------|----------------|
| WiFi-Connect | `...\Run-WiFi-Connect.cmd` |
| WiFi-Disconnect | `...\Run-WiFi-Disconnect.cmd` |

若 Connect 只有 `C:\Tools\win11-wifi-scheduler` 資料夾 → 請更新 `Install-Tasks.ps1` 後**以系統管理員重跑**安裝。

### 3. 排程總覽

```powershell
Get-ScheduledTask -TaskName 'WiFi-*' | ForEach-Object {
    $i = $_ | Get-ScheduledTaskInfo
    [PSCustomObject]@{
        Task   = $_.TaskName
        State  = $_.State
        Logon  = $_.Principal.LogonType
        Next   = $i.NextRunTime
        Last   = $i.LastRunTime
        Result = $i.LastTaskResult
    }
} | Format-Table -AutoSize
```

| 欄位 | 正常 |
|------|------|
| `State` | `Ready` |
| `Logon` | Connect=`Interactive`、Disconnect=`ServiceAccount` |
| `Result`（跑過後） | **`0`** = 成功 |

### 4. 手動腳本 + 排程觸發

見下一節 [手動測試與驗證](#手動測試與驗證)。

---

## 解除安裝

```powershell
.\Uninstall-Tasks.ps1
```

---

## 互動選單 WiFi-Menu.ps1

不需改原始碼時，用選單操作（**新增檔案**，不覆蓋 `Toggle-WiFi.ps1` / `Install-Tasks.ps1`）：

```powershell
cd C:\Tools\Win11-WiFi-Scheduler
.\WiFi-Menu.ps1
```

| 選項 | 功能 |
|------|------|
| 1 | 立即連線 (`Toggle-WiFi.ps1 -NoDelay`) |
| 2 | 立即斷線 |
| 3 | 今天一次性連線時間（需管理員，建立 `WiFi-Connect-AdHoc`） |
| 4 | 今天一次性斷線時間（需管理員） |
| **5** | **自訂隨機 Sleep** → 更新 `wifi_scheduler_config.json`，並只改 `Toggle-WiFi.ps1` 的 `$MaxDelayMinutes =` 一行（首次會備份 `Toggle-WiFi.ps1.bak`） |
| 6 | 查看所有 WiFi-* 排程狀態 |
| 7 | 還原預設排程（呼叫 `Install-Tasks.ps1`，需管理員） |
| 0 | 離開 |

### 調整隨機 Sleep 0~9 分鐘

- **選單**：`.\WiFi-Menu.ps1` → 選 `5`，輸入例如 `30`（表示 Sleep **0~29** 分鐘）
- **手動**：編輯 `wifi_scheduler_config.json` 的 `MaxDelayMinutes`，再執行選單 5 同步到腳本；或直接改 `Toggle-WiFi.ps1` 第 51 行

---

## 手動測試與驗證

### A. 乾跑（不動真網卡，但會寫 log）

```powershell
.\Toggle-WiFi.ps1 -Action Connect    -DryRun -Verbose
.\Toggle-WiFi.ps1 -Action Disconnect -DryRun -Verbose
```

**預期**：log 有 `DRYRUN`；**不**更新 CSV 的 ✓/✗（網卡未實際操作）。

---

### B. 真跑測試模式 `-NoDelay`（建議驗證用）

跳過隨機 Sleep，**立刻**連線 / 斷線。僅供手動測試，正式排程不會加 `-NoDelay`。

```powershell
.\Toggle-WiFi.ps1 -Action Connect    -NoDelay -Verbose
.\Toggle-WiFi.ps1 -Action Disconnect -NoDelay -Verbose
```

**預期 log（Connect 成功）**：

```
CONNECT    NODELAY    skip sleep (would have been N min)
CONNECT    DONE       starting netsh connect flow
CONNECT    ASSOC      ... online via 'lenovo-5G' ...
CONNECT    SUMMARY    daily ✓ at HH:mm -> ...\wifi_daily_summary.csv
```

**預期 log（Disconnect 成功）**：

```
DISCONNECT NODELAY    skip sleep ...
DISCONNECT DONE       Disconnect SSID via netsh (exit=0): ...
DISCONNECT SUMMARY    daily ✓ at HH:mm -> ...
```

**檢查 log 與 CSV**：

```powershell
Get-Content .\wifi_scheduler.log -Tail 12
Import-Csv .\wifi_daily_summary.csv | Select-Object -Last 1
```

| 欄位 | Connect 成功 | Disconnect 成功 |
|------|----------------|-----------------|
| CSV `Connect` / `Disconnect` | `✓` | `✓` |
| 不應出現 | `ERROR`（如 AddRange 型別錯誤） | 同上 |

若已連上 preferred SSID，Connect 可能顯示 `SUMMARY ... unchanged (already ✓ ...)` — 亦屬正常。

---

### C. 測排程啟動鏈（不經 Task Scheduler 介面）

模擬排程用 `.cmd` → `powershell.exe -File Toggle-WiFi.ps1` 的啟動方式：

```powershell
.\Test-ScheduledWiFi.ps1
```

**預期**：最後一行 `Exit code: 0`；log 有 `CONNECT` 相關 `DONE` / `ASSOC` / `SUMMARY`。

---

### D. 強制觸發 Scheduled Task（含隨機 Sleep）

與每天 08:00 / 19:30 **相同行為**：先 Sleep **0～9 分鐘**（`MaxDelayMinutes=10`），再執行。

```powershell
Start-ScheduledTask -TaskName 'WiFi-Connect'
# 或
Start-ScheduledTask -TaskName 'WiFi-Disconnect'
```

> ⏱ **觸發後請等約 10 分鐘** 再查結果（Sleep 期間 log 可能只有 `DELAY`，尚未連線/斷線）。

**檢查排程結果**：

```powershell
Get-ScheduledTask -TaskName 'WiFi-Connect' | Get-ScheduledTaskInfo |
    Format-List LastRunTime, LastTaskResult

Get-ScheduledTask -TaskName 'WiFi-Disconnect' | Get-ScheduledTaskInfo |
    Format-List LastRunTime, LastTaskResult
```

| 項目 | 預期 |
|------|------|
| `LastTaskResult` | **`0`** |
| `LastRunTime` | 約為 Sleep 結束後的時間 |

**檢查 log（Connect 範例）**：

```powershell
Get-Content .\wifi_scheduler.log -Tail 10
```

```
CONNECT    BOOT       user=DOMAIN\you
CONNECT    DELAY      N min (random 0..9)
CONNECT    DONE       starting netsh connect flow
CONNECT    ASSOC      ... online via 'lenovo-5G' ...
CONNECT    SUMMARY    daily ✓ at HH:mm -> ...
```

**檢查 log（Disconnect 範例）**：

```
DISCONNECT BOOT       user=...\SYSTEM
DISCONNECT DELAY      N min (random 0..9)
DISCONNECT DONE       Disconnect SSID via netsh (exit=0): ...
DISCONNECT SUMMARY    daily ✓ at HH:mm -> ...
```

**網路現象**：Disconnect 後 SSID  association 消失，但 **Wi‑Fi radio 仍開**（設計如此）。

```powershell
netsh wlan show interfaces
```

---

### E. 真跑含 Sleep（與排程相同，但不建議常態使用）

```powershell
.\Toggle-WiFi.ps1 -Action Connect    -Verbose
.\Toggle-WiFi.ps1 -Action Disconnect -Verbose
```

會真的 Sleep 0～9 分鐘；日常驗證請用 **B（-NoDelay）** 或 **D（Start-ScheduledTask）**。

---

### F. 日常監控（安裝完成後）

```powershell
# 最近 7 天摘要
Import-Csv .\wifi_daily_summary.csv | Select-Object -Last 7 | Format-Table -AutoSize

# 排程下次執行時間
Get-ScheduledTask -TaskName 'WiFi-*' | ForEach-Object {
    $i = $_ | Get-ScheduledTaskInfo
    '{0,-18} Next={1}  Last={2}  Result={3}' -f $_.TaskName, $i.NextRunTime, $i.LastRunTime, $i.LastTaskResult
}

# 今日 log 末段
Get-Content .\wifi_scheduler.log -Tail 8
```

**每天粗看**：CSV 當天 Connect / Disconnect 是否皆為 `✓`；`Result=0`；log 無 `ERROR`。

也可用 `.\WiFi-Menu.ps1` → 選 **6** 看排程狀態。

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
[2026-05-20 19:46:23] DISCONNECT DONE       Disconnect SSID via netsh (exit=0): ...
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

- **✓** = Connect 達 L3 / Disconnect 的 `netsh wlan disconnect` 流程完成且無例外
- **✗** = 拋出例外或 Connect 未達 L3（詳細看 `wifi_scheduler.log` 的 `ERROR` 行）
- **空格** = 當天該動作 **還沒發生**（例：中午翻看時下班尚未到，或關機/休眠錯過了下班觸發）
- **不寫入** 此 CSV 的情境：週末 / 例假日 / forbidden-hours / DryRun（因為網卡沒實際被操作）
- 寫入方式：upsert — 找到今天的 row 就更新對應欄位，沒有就 append
- **保留首次成功**：若當天 Connect/Disconnect 已是 ✓，後續手動測試不會覆寫時間（log 會寫 `unchanged`）
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
| `netsh exit=0` 但 Connect ✗ | 常見：**排程用 SYSTEM**（PEAP 讀不到 DPAPI）→ 重跑 `Install-Tasks.ps1`；Connect 應為 **Interactive** |
| log 有 `wlan reconnect` exit=1 | 已改為第二次 `wlan connect`；同步新版 `Toggle-WiFi.ps1` |
| CSV ✓ 但仍要手動點連線 | 舊版假成功；更新 `Toggle-WiFi.ps1` 後看 log 的 `DIAG` 行與 preferred SSID |
| log 有 `pre-connect disconnect` | 正常：腳本先斷線再重連，強迫 802.1X 握手 |
| 想立即驗證觸發行為 | 見 [手動測試與驗證](#手動測試與驗證)；`Start-ScheduledTask` 後需等 0～9 分鐘 |
| Connect 的 Execute 只有資料夾 | 更新並重跑 `Install-Tasks.ps1`（勿用含 `connect` 的 PS 變數名） |
| log `AddRange` / `Object[]` 轉型錯誤 | 更新 `Toggle-WiFi.ps1` |
| `LastTaskResult` = **267011** | 任務尚未執行過，非錯誤 |
| holidays JSON 失敗 | `Get-Content holidays_2026.json -Raw \| ConvertFrom-Json` 檢查 JSON 合法性；log 內會印 `WARN holiday json parse failed` |
| log 內 netsh 中文亂碼 | 更新 `Toggle-WiFi.ps1`（raw bytes 解碼）；舊 log 行不會自動修復 |
| `LastTaskResult` = **2147946720** (0x800710E0) | 排程拒絕啟動 → 用 `Run-WiFi-Connect.cmd` 啟動器，重跑 `Install-Tasks.ps1` |
| 有 Last 時間但沒有 log | 同上；用 `.\Test-ScheduledWiFi.ps1` 確認手動可寫 log |
| 想完全停掉排程 | `.\Uninstall-Tasks.ps1`（保留腳本檔以便日後重裝） |
| 跑 .ps1 出現「安全性警告」/ 排程無 log | **安裝前**執行 `Unblock-File -Path C:\Tools\Win11-WiFi-Scheduler\*.ps1`（MOTW 會讓排程靜默失敗；`Install-Tasks.ps1` 已會自動 Unblock） |

---

## 已知限制

- **沒有跨夜支援**：若需要凌晨自動連線（如夜班），本腳本會被 `forbidden-hours` (00:00-06:00) 拒絕
- **單一網卡**：只處理 Intel Wi-Fi 6E AX211；若換網卡需改 `$AdapterDesc`
- **無通知**：純定時、無 Email/Teams 通知
- **依靠 Task Scheduler**：若 Win11 已停用工作排程器服務，本方案失效
