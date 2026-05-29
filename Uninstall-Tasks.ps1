<#
.SYNOPSIS
    移除所有 WiFi-* Scheduled Tasks（含選單建立的一次性任務）。

.NOTES
    還原檔：Uninstall-Tasks.ps1.bak
#>
[CmdletBinding()]
param()

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error '請以 系統管理員 身分執行此腳本。'
    exit 1
}

$tasks = @(Get-ScheduledTask -TaskName 'WiFi-*' -ErrorAction SilentlyContinue)
if (-not $tasks) {
    Write-Host '[SKIP] 找不到任何 WiFi-* 排程'
    exit 0
}

Write-Host '將移除以下排程：'
$tasks | ForEach-Object { Write-Host "  $($_.TaskName)" }
$confirm = Read-Host '確認移除? [y/N]'
if ($confirm -notmatch '^[Yy]$') { Write-Host '已取消。'; exit 0 }

foreach ($t in $tasks) {
    Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false
    Write-Host "[OK]   移除 $($t.TaskName)"
}
