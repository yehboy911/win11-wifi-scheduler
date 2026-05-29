<#
.SYNOPSIS
    手動驗證排程能否啟動 Toggle-WiFi（與 Install-Tasks 相同參數）。
#>
$Root = $PSScriptRoot
$ps   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script = Join-Path $Root 'Toggle-WiFi.ps1'

Write-Host "PowerShell: $ps"
Write-Host "Script:     $script"
Write-Host "WorkingDir: $Root"
Write-Host ''

& $ps -NoProfile -ExecutionPolicy Bypass -File $script -Action Connect -NoDelay -Verbose
Write-Host ''
Write-Host "Exit code: $LASTEXITCODE"
Write-Host "Log exists: $(Test-Path (Join-Path $Root 'wifi_scheduler.log'))"
if (Test-Path (Join-Path $Root 'wifi_scheduler.log')) {
    Get-Content (Join-Path $Root 'wifi_scheduler.log') -Tail 8
}
