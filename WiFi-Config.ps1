# WiFi-Config.ps1 - helpers for WiFi-Menu.ps1 (ASCII-only strings for PS 5.1)

function Get-WiFiSchedulerRoot {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return Split-Path -Parent $MyInvocation.MyCommand.Path
}

$script:WiFiRoot         = Get-WiFiSchedulerRoot
$script:ConfigPath       = Join-Path $script:WiFiRoot 'wifi_scheduler_config.json'
$script:ToggleScriptPath = Join-Path $script:WiFiRoot 'Toggle-WiFi.ps1'
$script:DefaultMaxDelay  = 10

function Get-SchedulerConfig {
    if (-not (Test-Path $script:ConfigPath)) {
        return [PSCustomObject]@{
            MaxDelayMinutes = $script:DefaultMaxDelay
            ConnectTimes    = @('08:00')
            DisconnectTime  = '19:30'
        }
    }
    try {
        $raw = Get-Content -Path $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return [PSCustomObject]@{
            MaxDelayMinutes = [int]$raw.MaxDelayMinutes
            ConnectTimes    = @($raw.ConnectTimes)
            DisconnectTime  = [string]$raw.DisconnectTime
        }
    } catch {
        Write-Warning "Config parse failed: $($_.Exception.Message)"
        return [PSCustomObject]@{
            MaxDelayMinutes = $script:DefaultMaxDelay
            ConnectTimes    = @('08:00')
            DisconnectTime  = '19:30'
        }
    }
}

function Save-SchedulerConfig {
    param(
        [int]$MaxDelayMinutes,
        [string[]]$ConnectTimes,
        [string]$DisconnectTime
    )
    $obj = [ordered]@{
        _help           = @{
            MaxDelayMinutes = 'exclusive max: 10 = sleep 0-9 min'
            ConnectTimes    = 'Install-Tasks.ps1'
            DisconnectTime  = 'Install-Tasks.ps1'
        }
        MaxDelayMinutes = $MaxDelayMinutes
        ConnectTimes    = $ConnectTimes
        DisconnectTime  = $DisconnectTime
    }
    $utf8 = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($script:ConfigPath, (($obj | ConvertTo-Json -Depth 4) + "`r`n"), $utf8)
}

function Get-ToggleWiFiMaxDelayMinutes {
    if (-not (Test-Path $script:ToggleScriptPath)) { return $null }
    foreach ($line in [System.IO.File]::ReadAllLines($script:ToggleScriptPath)) {
        if ($line -match 'MaxDelayMinutes\s*=\s*(\d+)') {
            return [int]$Matches[1]
        }
    }
    return $null
}

function Get-MaxDelaySleepRangeText {
    param([int]$MaxDelayMinutes)
    $high = $MaxDelayMinutes - 1
    if ($high -lt 0) { $high = 0 }
    return "0..$high"
}

function Get-ConnectScheduledTaskName {
    param([int]$Index)
    if ($Index -eq 0) { return 'WiFi-Connect' }
    return "WiFi-Connect-$($Index + 1)"
}

function Set-ToggleWiFiMaxDelayMinutes {
    param([Parameter(Mandatory)][int]$MaxDelayMinutes)
    if ($MaxDelayMinutes -lt 2 -or $MaxDelayMinutes -gt 61) {
        throw 'MaxDelayMinutes must be 2..61'
    }
    if (-not (Test-Path $script:ToggleScriptPath)) {
        throw "Toggle-WiFi.ps1 not found: $script:ToggleScriptPath"
    }
    $bak = "$script:ToggleScriptPath.bak"
    if (-not (Test-Path $bak)) {
        Copy-Item $script:ToggleScriptPath $bak -Force
        Write-Host "Backup: $bak"
    }
    $lines = [System.IO.File]::ReadAllLines($script:ToggleScriptPath)
    $hit   = $false
    $out   = foreach ($line in $lines) {
        if (-not $hit -and $line -match 'MaxDelayMinutes\s*=\s*\d+') {
            $hit = $true
            '$MaxDelayMinutes = {0}' -f $MaxDelayMinutes
        } else { $line }
    }
    if (-not $hit) { throw 'MaxDelayMinutes line not found in Toggle-WiFi.ps1' }
    $utf8 = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllLines($script:ToggleScriptPath, $out, $utf8)
    $cfg = Get-SchedulerConfig
    Save-SchedulerConfig -MaxDelayMinutes $MaxDelayMinutes `
        -ConnectTimes $cfg.ConnectTimes -DisconnectTime $cfg.DisconnectTime
}

function Test-IsAdministrator {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-TimeInputHHmm {
    param([string]$Prompt)
    while ($true) {
        $answer = Read-Host $Prompt
        if ($answer -notmatch '^\d{2}:\d{2}$') {
            Write-Host 'Use HH:mm (example 14:30)' -ForegroundColor Yellow
            continue
        }
        $h = [int]$answer.Substring(0, 2)
        $m = [int]$answer.Substring(3, 2)
        if ($h -gt 23 -or $m -gt 59) {
            Write-Host 'Time out of range' -ForegroundColor Yellow
            continue
        }
        if ($h -lt 6) {
            Write-Host 'Warning: 00:00-05:59 blocked by Toggle-WiFi forbidden-hours' -ForegroundColor Yellow
        }
        $at = (Get-Date).Date.AddHours($h).AddMinutes($m)
        if ($at -le (Get-Date)) {
            Write-Host 'Enter a future time today' -ForegroundColor Yellow
            continue
        }
        return $at
    }
}

function Get-InteractiveTaskPrincipal {
    if ($env:USERDOMAIN -and $env:USERNAME) {
        $d = $env:USERDOMAIN
        $uid = if ($d -eq '.' -or $d -eq $env:COMPUTERNAME) { $env:USERNAME } else { "$d\$env:USERNAME" }
    } else {
        $uid = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    return New-ScheduledTaskPrincipal -UserId $uid -LogonType Interactive -RunLevel Limited
}

function Register-WiFiAdHocTask {
    param(
        [string]$TaskName,
        [datetime]$At,
        [ValidateSet('Connect', 'Disconnect')][string]$ActionParam
    )
    $toggle = Join-Path $script:WiFiRoot 'Toggle-WiFi.ps1'
    $argStr = "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$toggle`" -Action $ActionParam"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argStr
    $trigger = New-ScheduledTaskTrigger -Once -At $At
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    $p = Get-InteractiveTaskPrincipal
    Register-ScheduledTask -TaskName $TaskName -Trigger $trigger -Action $action `
        -Settings $set -Principal $p -Force -ErrorAction Stop | Out-Null
    Write-Host "[OK] $TaskName at $($At.ToString('yyyy-MM-dd HH:mm'))"
}

function Show-WiFiScheduledTaskStatus {
    $tasks = @(Get-ScheduledTask -TaskName 'WiFi-*' -ErrorAction SilentlyContinue)
    if (-not $tasks) {
        Write-Host 'No WiFi-* tasks. Run Install-Tasks.ps1 first.'
        return
    }
    foreach ($t in $tasks) {
        $i = $t | Get-ScheduledTaskInfo
        [PSCustomObject]@{
            Task           = $t.TaskName
            State          = $t.State
            LogonType      = $t.Principal.LogonType
            NextRunTime    = $i.NextRunTime
            LastTaskResult = $i.LastTaskResult
        }
    } | Format-Table -AutoSize
}

function Show-SchedulerSettingsSummary {
    $cfg    = Get-SchedulerConfig
    $inFile = Get-ToggleWiFiMaxDelayMinutes
    $range  = Get-MaxDelaySleepRangeText -MaxDelayMinutes $cfg.MaxDelayMinutes
    Write-Host ''
    Write-Host '--- Settings ---'
    Write-Host "  Sleep range (min)  : $range  (MaxDelayMinutes=$($cfg.MaxDelayMinutes))"
    if ($null -ne $inFile) {
        Write-Host "  Toggle-WiFi.ps1    : $inFile"
    }
    Write-Host "  Connect times      : $($cfg.ConnectTimes -join ', ')"
    Write-Host "  Disconnect time    : $($cfg.DisconnectTime)"
    Write-Host "  Config             : $script:ConfigPath"
    Write-Host ''
}

function Get-ToggleScriptPath {
    return $script:ToggleScriptPath
}
