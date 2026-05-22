<#
.SYNOPSIS
    移除 WiFi-Connect / WiFi-Disconnect Scheduled Tasks。
#>
[CmdletBinding()]
param()

$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = [Security.Principal.WindowsPrincipal]::new($currentUser)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error '請以 系統管理員 身分執行此腳本。'
    exit 1
}

foreach ($name in 'WiFi-Connect', 'WiFi-Disconnect') {
    $existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Host "[OK]   移除 $name"
    } else {
        Write-Host "[SKIP] $name 不存在"
    }
}
