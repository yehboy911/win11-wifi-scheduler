<#
.SYNOPSIS
    建立 WiFi-Connect / WiFi-Disconnect 兩個 Scheduled Task。

.DESCRIPTION
    使用儲存的帳密 (LogonType=Password)，解決公司 domain 機器 session-inject 限制。
    密碼更改後需重新執行此腳本。

.NOTES
    必須以系統管理員 PowerShell 執行。
#>
[CmdletBinding()]
param()

# ---------- Admin check ----------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Run as Administrator'
    exit 1
}

# ---------- Path check ----------
$ScriptDir    = $PSScriptRoot
$ToggleScript = Join-Path $ScriptDir 'Toggle-WiFi.ps1'
if (-not (Test-Path $ToggleScript)) {
    Write-Error "Toggle-WiFi.ps1 not found: $ToggleScript"
    exit 1
}

# ---------- Credentials ----------
Write-Host 'Enter your Windows login credentials (required for stored-credential tasks):'
$cred = Get-Credential -UserName $env:USERNAME -Message 'Windows login password'
if (-not $cred) { Write-Error 'Credentials required'; exit 1 }

$bstr     = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
$plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

$userId   = $cred.UserName

# ---------- Common task components ----------
$DaysOfWeek = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')

$TaskSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

# ---------- Task factory ----------
function New-WiFiTask {
    param(
        [string]$Name,
        [string]$AtTime,
        [string]$ActionParam
    )

    $trigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DaysOfWeek -At $AtTime
    $argStr    = "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$ToggleScript`" -Action $ActionParam"
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argStr

    Register-ScheduledTask `
        -TaskName  $Name `
        -Trigger   $trigger `
        -Action    $action `
        -Settings  $TaskSettings `
        -User      $userId `
        -Password  $plainPwd `
        -RunLevel  Limited `
        -Force | Out-Null

    Write-Host "[OK] $Name  (trigger=$AtTime  action=$ActionParam)"
}

New-WiFiTask -Name 'WiFi-Connect'    -AtTime '08:00' -ActionParam 'Connect'
New-WiFiTask -Name 'WiFi-Disconnect' -AtTime '19:30' -ActionParam 'Disconnect'

# Clear plaintext password from memory
$plainPwd = $null

Write-Host ''
Write-Host 'Done. Verify:'
Write-Host '  Get-ScheduledTask -TaskName WiFi-* | Format-Table TaskName, State, NextRunTime'
