# Win11 WiFi Scheduler — TODO

## Feature: WiFi-Menu.ps1 (branch: feature/wifi-menu)
**Status: AWAITING CONFIRM — 不編碼**

- [ ] 0. 建立 git branch `feature/wifi-menu`
- [ ] 1. 新增 `WiFi-Menu.ps1` (UTF-8 BOM)
  - [ ] 1a. Admin 檢測 helper function
  - [ ] 1b. 時間輸入 + 驗證 helper function (HH:mm, future, 00-06 warning)
  - [ ] 1c. 選項 1 — 立即連線 (call Toggle-WiFi.ps1 -NoDelay)
  - [ ] 1d. 選項 2 — 立即斷線 (call Toggle-WiFi.ps1 -NoDelay)
  - [ ] 1e. 選項 3 — 今天自訂連線時間 (Set-ScheduledTask -Once)
  - [ ] 1f. 選項 4 — 今天自訂斷線時間 (Set-ScheduledTask -Once)
  - [ ] 1g. 選項 5 — 查看排程狀態
  - [ ] 1h. 選項 6 — 還原預設排程 (08:00/19:30)
  - [ ] 1i. 選項 0 — 離開
  - [ ] 1j. 主選單 do-while loop
- [ ] 2. Bug fix: Toggle-WiFi.ps1 OEM codepage (確認 log 亂碼原因後修)
- [ ] 3. 更新 README.md — 新增 WiFi-Menu.ps1 段落
- [ ] 4. 手動測試全部 6 個選項
- [ ] 5. python-reviewer subagent on WiFi-Menu.ps1 → review.md (N/A — PS not Python)
- [ ] 6. 同步 Windows 端 C:\Tools\win11-wifi-scheduler\

## Pending (from S4U fix, 2026-05-21)
- [ ] 確認 13:00 自動連線 log (今天)
- [ ] 明天 08:00 確認正式排程觸發成功 (LastTaskResult=0)
- [ ] 確認 log 亂碼原因 (貼出 log 內容)
