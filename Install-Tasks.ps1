<#
.SYNOPSIS
    Install WiFi scheduled tasks from wifi_scheduler_config.json

.NOTES
    Run as Administrator. Does not require WiFi-Config.ps1 (self-contained).
#>
[CmdletBinding()]
param()

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Run as Administrator'
    exit 1
}

$Root         = $PSScriptRoot
$ConfigPath   = Join-Path $Root 'wifi_scheduler_config.json'
$ToggleScript = Join-Path $Root 'Toggle-WiFi.ps1'

if (-not (Test-Path $ToggleScript)) {
    Write-Error "Toggle-WiFi.ps1 not found: $ToggleScript"
    exit 1
}

# 從網路/壓縮檔複製的 .ps1 可能被 MOTW 擋住，排程執行會失敗且不產生 log
Get-ChildItem -Path $Root -Filter '*.ps1' -File | ForEach-Object {
    Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue
}
Write-Host 'Install-Tasks.ps1 2026-05-29c (pathOn/pathOff launcher fix)'
Write-Host 'Unblock-File applied to *.ps1 (Zone.Identifier cleared)'

function Read-InstallConfig {
    if (-not (Test-Path $ConfigPath)) {
        return @{
            MaxDelayMinutes = 10
            ConnectTimes    = @('08:00')
            DisconnectTime  = '19:30'
        }
    }
    try {
        $raw = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Warning "wifi_scheduler_config.json parse failed, using defaults: $($_.Exception.Message)"
        return @{ MaxDelayMinutes = 10; ConnectTimes = @('08:00'); DisconnectTime = '19:30' }
    }
    return @{
        MaxDelayMinutes = if ($null -ne $raw.MaxDelayMinutes) { [int]$raw.MaxDelayMinutes } else { 10 }
        ConnectTimes    = if ($raw.ConnectTimes) { @($raw.ConnectTimes) } else { @('08:00') }
        DisconnectTime  = if ($raw.DisconnectTime) { [string]$raw.DisconnectTime } else { '19:30' }
    }
}

function Sync-ToggleMaxDelay {
    param([int]$Minutes)
    if ($Minutes -lt 2 -or $Minutes -gt 61) {
        Write-Warning "MaxDelayMinutes=$Minutes out of range (2..61); skipping sync to Toggle-WiFi.ps1"
        return
    }
    $bak = "$ToggleScript.bak"
    if (-not (Test-Path $bak)) { Copy-Item $ToggleScript $bak -Force }
    $lines = [System.IO.File]::ReadAllLines($ToggleScript)
    $done  = $false
    $new   = foreach ($line in $lines) {
        if (-not $done -and $line -match 'MaxDelayMinutes\s*=\s*\d+') {
            $done = $true
            '$MaxDelayMinutes = {0}' -f $Minutes
        } else { $line }
    }
    if (-not $done) {
        Write-Warning 'MaxDelayMinutes line not found in Toggle-WiFi.ps1'
        return
    }
    $utf8 = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllLines($ToggleScript, $new, $utf8)
    $high = $Minutes - 1
    Write-Host "MaxDelayMinutes=$Minutes (sleep 0..$high min)"
}

function Get-ConnectTaskName {
    param([int]$Index)
    if ($Index -eq 0) { return 'WiFi-Connect' }
    return 'WiFi-Connect-{0}' -f ($Index + 1)
}

function Get-TaskUserId {
    if ($env:USERDOMAIN -and $env:USERNAME) {
        $d = $env:USERDOMAIN
        if ($d -eq '.' -or $d -eq $env:COMPUTERNAME) { return $env:USERNAME }
        return "$d\$env:USERNAME"
    }
    return [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

$cfg = Read-InstallConfig
Sync-ToggleMaxDelay -Minutes $cfg.MaxDelayMinutes

$userId = Get-TaskUserId
# Connect 必須 Interactive：PEAP 憑證在登入者 DPAPI，SYSTEM 會 netsh exit=0 但永遠無 L3
$principalConnect    = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
# Disconnect 用 SYSTEM：螢幕鎖定時仍可斷線，且不需讀 Wi-Fi 密碼
$principalDisconnect = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount
$days      = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
$settings  = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -MultipleInstances IgnoreNew

# 用 .cmd 啟動（避免排程直接跑 .ps1 / powershell 參數被 0x800710E0 拒絕）
# PS 5.1 陷阱：變數名含 connect（如 $connectLeaf、$launcherConnect）會被拆成 $connect+Leaf → 路徑只剩 $Root
$leafOn  = 'Run-WiFi-{0}.cmd' -f 'Connect'
$leafOff = 'Run-WiFi-Disconnect.cmd'
$pathOn  = [System.IO.Path]::Combine($Root, $leafOn)
$pathOff = [System.IO.Path]::Combine($Root, $leafOff)
Write-Host ('On launcher  (.cmd): {0}' -f $pathOn)
Write-Host ('Off launcher (.cmd): {0}' -f $pathOff)
foreach ($p in @($pathOn, $pathOff)) {
    if (-not $p.EndsWith('.cmd', [StringComparison]::OrdinalIgnoreCase)) {
        Write-Error ('Launcher path must end with .cmd, got: {0}' -f $p)
        exit 1
    }
}

$_psExe = '"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Toggle-WiFi.ps1"'

if (-not (Test-Path -LiteralPath $pathOn)) {
    $c = "@echo off`r`ncd /d ""%~dp0""`r`n$_psExe -Action Connect`r`nexit /b %ERRORLEVEL%`r`n"
    [System.IO.File]::WriteAllText($pathOn, $c, [System.Text.Encoding]::ASCII)
    Write-Host '[CREATE] Run-WiFi-Connect.cmd'
}
if (-not (Test-Path -LiteralPath $pathOn)) {
    Write-Error ('On launcher not found: {0}' -f $pathOn)
    exit 1
}

if (-not (Test-Path -LiteralPath $pathOff)) {
    $c = "@echo off`r`ncd /d ""%~dp0""`r`n$_psExe -Action Disconnect`r`nexit /b %ERRORLEVEL%`r`n"
    [System.IO.File]::WriteAllText($pathOff, $c, [System.Text.Encoding]::ASCII)
    Write-Host '[CREATE] Run-WiFi-Disconnect.cmd'
}
if (-not (Test-Path -LiteralPath $pathOff)) {
    Write-Error ('Off launcher not found: {0}' -f $pathOff)
    exit 1
}

function Register-WiFiWeeklyTask {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$AtTime,
        [Parameter(Mandatory)][string]$LauncherPath,
        [Parameter(Mandatory)][Microsoft.Management.Infrastructure.CimInstance]$Principal
    )
    if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
        throw "Register-WiFiWeeklyTask: LauncherPath is empty for task '$Name'"
    }
    if (-not (Test-Path -LiteralPath $LauncherPath)) {
        throw "Register-WiFiWeeklyTask: launcher not found: $LauncherPath"
    }
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $days -At $AtTime
    $action  = New-ScheduledTaskAction -Execute $LauncherPath -WorkingDirectory $Root
    Register-ScheduledTask -TaskName $Name -Trigger $trigger -Action $action `
        -Settings $settings -Principal $Principal -Force -ErrorAction Stop | Out-Null
    $leaf = [System.IO.Path]::GetFileName($LauncherPath)
    Write-Host "[OK] $Name  ($AtTime  $leaf  Logon=$($Principal.LogonType))"
}

# 已廢止：中午驗證 / 第二條連線任務
foreach ($legacy in @('WiFi-Connect-Noon', 'WiFi-Connect-2', 'WiFi-Connect-3')) {
    $t = Get-ScheduledTask -TaskName $legacy -ErrorAction SilentlyContinue
    if ($t) {
        Unregister-ScheduledTask -TaskName $legacy -Confirm:$false
        Write-Host "[REMOVE] $legacy (deprecated)"
    }
}

$keepAdHoc = @('WiFi-Connect-AdHoc', 'WiFi-Disconnect-AdHoc')
Get-ScheduledTask -TaskName 'WiFi-*' -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -notin $keepAdHoc } |
    ForEach-Object {
        Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "[REMOVE] $($_.TaskName)"
    }

Write-Host "Installing Connect as: $userId (Interactive - required for PEAP)"
Write-Host 'Installing Disconnect as: SYSTEM (works when screen locked)'

$i = 0
foreach ($time in $cfg.ConnectTimes) {
    if ([string]::IsNullOrWhiteSpace($time)) { continue }
    Register-WiFiWeeklyTask -Name (Get-ConnectTaskName -Index $i) -AtTime $time `
        -LauncherPath $pathOn -Principal $principalConnect
    $i++
}

if ($cfg.DisconnectTime) {
    Register-WiFiWeeklyTask -Name 'WiFi-Disconnect' -AtTime $cfg.DisconnectTime `
        -LauncherPath $pathOff -Principal $principalDisconnect
}

Write-Host ''
Write-Host 'Done. Verify (LastRunTime / LastTaskResult after trigger time):'
Get-ScheduledTask -TaskName 'WiFi-*' | ForEach-Object {
    $info = $_ | Get-ScheduledTaskInfo
    Write-Host ('  {0,-18} {1,-12} Next={2}  Last={3}  Result={4}' -f `
        $_.TaskName, $_.Principal.LogonType, $info.NextRunTime, $info.LastRunTime, $info.LastTaskResult)
}
Write-Host "Log file: $(Join-Path $Root 'wifi_scheduler.log')"
