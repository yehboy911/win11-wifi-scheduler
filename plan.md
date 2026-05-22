# Plan: WiFi-Menu.ps1 — Interactive On-Demand Scheduler

**Branch:** `feature/wifi-menu` (base: `config-20260507`)
**Date:** 2026-05-21
**Status:** AWAITING CONFIRM

---

## Goal

Add `WiFi-Menu.ps1` — an interactive numbered menu for ad-hoc WiFi connect/disconnect
outside the normal scheduled hours, without modifying `Toggle-WiFi.ps1` core logic.

---

## Design

### New file: `WiFi-Menu.ps1`

Menu loop at the project directory `C:\Tools\win11-wifi-scheduler\`.

```
╔══════════════════════════════════════╗
║     Win11 WiFi 排程選單              ║
╠══════════════════════════════════════╣
║  1. 立即連線                         ║
║  2. 立即斷線                         ║
║  3. 今天自訂連線時間                 ║
║  4. 今天自訂斷線時間                 ║
║  5. 查看目前排程狀態                 ║
║  6. 還原預設排程 (08:00 / 19:30)     ║
║  0. 離開                             ║
╚══════════════════════════════════════╝
```

### Option behaviour

| # | Action | Admin? | Implementation |
|---|---|---|---|
| 1 | Connect now | No | `& .\Toggle-WiFi.ps1 -Action Connect -NoDelay` |
| 2 | Disconnect now | No | `& .\Toggle-WiFi.ps1 -Action Disconnect -NoDelay` |
| 3 | Schedule connect at HH:mm | Yes | `Set-ScheduledTask WiFi-Connect -Once -At <time>` |
| 4 | Schedule disconnect at HH:mm | Yes | `Set-ScheduledTask WiFi-Disconnect -Once -At <time>` |
| 5 | Show schedule status | No | `Get-ScheduledTaskInfo` both tasks |
| 6 | Restore default schedule | Yes | Re-register Mon-Fri 08:00/19:30 (inline logic from Install-Tasks.ps1) |
| 0 | Exit | — | `break` |

### Time input (options 3 & 4)
- `Read-Host` prompt: `輸入時間 (HH:mm)`
- Validate: regex `^\d{2}:\d{2}$` + range check (00:00-23:59)
- Check time is in the future (today); if past, show error and re-prompt
- Forbidden window 00:00-06:00 warning (same as Toggle-WiFi.ps1 Gate 3)

### Admin detection
- Options 3, 4, 6 require elevation
- Detect at selection time: `[Security.Principal.WindowsPrincipal]::new(...).IsInRole(Administrator)`
- If not admin: print warning + suggest re-open as Administrator

### Scope constraints
- No change to `Toggle-WiFi.ps1`
- No change to `Install-Tasks.ps1` / `Uninstall-Tasks.ps1`
- `WiFi-Menu.ps1` is standalone; user runs it manually from explorer or PS
- UTF-8 BOM required (same as other .ps1 files)

---

## Bug Fix (in same branch)

**Log mojibake in S4U mode:** `$_oemEncoding` may resolve to CP437 (US English)
in a non-interactive session instead of CP950 (Big5). Investigation needed after
user shares log content. Fix candidate: hardcode `950` with try/catch fallback.

---

## Files changed

| File | Change |
|---|---|
| `WiFi-Menu.ps1` | NEW |
| `Toggle-WiFi.ps1` | Bug fix only: OEM codepage hardcode if mojibake confirmed |
| `README.md` | Add section: "互動選單 WiFi-Menu.ps1" |

---

## Verification criteria

- [ ] `.\WiFi-Menu.ps1` shows menu correctly from non-admin PS
- [ ] Option 1/2 invoke Toggle-WiFi.ps1 and write log entries
- [ ] Option 3/4 produce correct `NextRunTime` in `Get-ScheduledTaskInfo`
- [ ] Option 3/4 reject invalid time input (letters, out-of-range, past time)
- [ ] Option 5 displays both task info in a readable table
- [ ] Option 6 restores NextRunTime to tomorrow 08:00 / 19:30
- [ ] No modification to Toggle-WiFi.ps1 core behaviour
