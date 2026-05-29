<#
.SYNOPSIS
    Win11 Wi-Fi 互動選單 — 立即連斷、調整隨機延遲、一次性排程、查看狀態。

.DESCRIPTION
    獨立於 Toggle-WiFi.ps1 / Install-Tasks.ps1，不覆蓋原檔。
    調整隨機 Sleep 會更新 wifi_scheduler_config.json，並只修改
    Toggle-WiFi.ps1 內的 `$MaxDelayMinutes =` 那一行（首次會產生 .bak 備份）。

.EXAMPLE
    .\WiFi-Menu.ps1
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'WiFi-Config.ps1')

$ToggleScript = Join-Path $PSScriptRoot 'Toggle-WiFi.ps1'
if (-not (Test-Path $ToggleScript)) {
    Write-Error "找不到 $ToggleScript"
    exit 1
}

function Show-Menu {
    Show-SchedulerSettingsSummary
    Write-Host @'

╔══════════════════════════════════════╗
║     Win11 WiFi 排程選單              ║
╠══════════════════════════════════════╣
║  1. 立即連線                         ║
║  2. 立即斷線                         ║
║  3. 今天自訂連線時間 (需管理員)      ║
║  4. 今天自訂斷線時間 (需管理員)      ║
║  5. 自訂隨機 Sleep 分鐘              ║
║  6. 查看目前排程狀態                 ║
║  7. 還原預設排程 (需管理員)          ║
║  0. 離開                             ║
╚══════════════════════════════════════╝
'@
}

function Invoke-ToggleNoDelay {
    param([ValidateSet('Connect', 'Disconnect')][string]$Action)
    Write-Host "執行: Toggle-WiFi.ps1 -Action $Action -NoDelay -Verbose"
    & $ToggleScript -Action $Action -NoDelay -Verbose
}

function Set-CustomMaxDelay {
    $cfg   = Get-SchedulerConfig
    $cur   = Get-ToggleWiFiMaxDelayMinutes
    $shown = if ($null -ne $cur) { $cur } else { $cfg.MaxDelayMinutes }
    Write-Host ''
    Write-Host "目前 MaxDelayMinutes = $shown → Sleep $(Get-MaxDelaySleepRangeText -MaxDelayMinutes $shown) 分鐘"
    Write-Host '說明: 數字是 Get-Random -Maximum 的上限 (exclusive)。例如 30 → Sleep 0~29 分鐘。'
    Write-Host ''

    $ans = Read-Host '輸入新的 MaxDelayMinutes (2~61，Enter 取消)'
    if ([string]::IsNullOrWhiteSpace($ans)) { return }
    if ($ans -notmatch '^\d+$') {
        Write-Host '請輸入整數' -ForegroundColor Red
        return
    }
    $n = [int]$ans
    try {
        Set-ToggleWiFiMaxDelayMinutes -MaxDelayMinutes $n
        Write-Host "已更新 → Sleep $(Get-MaxDelaySleepRangeText -MaxDelayMinutes $n) 分鐘" -ForegroundColor Green
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function Set-AdHocSchedule {
    param(
        [ValidateSet('Connect', 'Disconnect')][string]$Action
    )
    if (-not (Test-IsAdministrator)) {
        Write-Host '此選項需要以系統管理員開啟 PowerShell。' -ForegroundColor Yellow
        return
    }
    $label = if ($Action -eq 'Connect') { '連線' } else { '斷線' }
    $at    = Read-TimeInputHHmm -Prompt "輸入今天 $label 時間 (HH:mm)"
    $task  = if ($Action -eq 'Connect') { 'WiFi-Connect-AdHoc' } else { 'WiFi-Disconnect-AdHoc' }
    try {
        Register-WiFiAdHocTask -TaskName $task -At $at -ActionParam $Action
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function Restore-DefaultSchedule {
    if (-not (Test-IsAdministrator)) {
        Write-Host '此選項需要以系統管理員開啟 PowerShell。' -ForegroundColor Yellow
        return
    }
    $installer = Join-Path $PSScriptRoot 'Install-Tasks.ps1'
    if (-not (Test-Path $installer)) {
        Write-Host "找不到 $installer" -ForegroundColor Red
        return
    }
    Write-Host '將執行 Install-Tasks.ps1（依 wifi_scheduler_config.json 建立排程）...'
    & $installer
}

# ---------- 主迴圈 ----------
do {
    Show-Menu
    $choice = Read-Host '請選擇'
    switch ($choice) {
        '1' { Invoke-ToggleNoDelay -Action Connect }
        '2' { Invoke-ToggleNoDelay -Action Disconnect }
        '3' { Set-AdHocSchedule -Action Connect }
        '4' { Set-AdHocSchedule -Action Disconnect }
        '5' { Set-CustomMaxDelay }
        '6' { Show-WiFiScheduledTaskStatus }
        '7' { Restore-DefaultSchedule }
        '0' { Write-Host '再見。'; break }
        default { Write-Host '無效選項' -ForegroundColor Yellow }
    }
    if ($choice -ne '0') {
        Write-Host ''
        Read-Host '按 Enter 返回選單'
    }
} while ($choice -ne '0')
