<#
.SYNOPSIS
    Win11 Wi-Fi 排程開關 — Enable/Disable Intel(R) Wi-Fi 6E AX211 160MHz

.DESCRIPTION
    由 Task Scheduler 在平日 08:00 / 19:30 觸發。內部 Sleep Random(0,29) 分鐘後
    透過 `netsh wlan disconnect/connect` 切換 SSID **(不關閉網卡 radio)**，模擬
    正常上下班行為。週末、例假日 (holidays_YYYY.json) 及 00:00-06:00 自動跳過。

    Connect 路徑：直接 `netsh wlan connect` 逐一試 $PreferredSSIDs，每個給
    $AssocWaitSec 秒到 online。任一成功才寫 CSV ✓；全失敗 ✗ + exit 1。
    Disconnect 路徑：`netsh wlan disconnect` 只放掉 SSID，網卡 radio 不關。

    成功標準 = L2 Status=Up **且** (IPv4Connectivity=Internet **或** NetworkCategory=DomainAuthenticated)。
    後者讓「連到 AD 公司網但 NCSI 還沒偵測完」也算成功；captive portal 卡「需要採取動作」、
    802.1X 認證待輸入都會被視為失敗。

    **Win11 前置**：必須啟用 Location Services (Settings → Privacy → Location)，否則
    `netsh wlan` 系列指令會回「存取被拒」(WLAN API 在 Win11 需要位置權限)。

.PARAMETER Action
    Connect (Enable) 或 Disconnect (Disable)。

.PARAMETER DryRun
    乾跑：印出將執行的動作但不真的操作網卡，仍寫 log。不會寫 CSV。

.PARAMETER NoDelay
    測試用：跳過 Random(0,29) min 的 Sleep，立即執行 Enable/Disable。
    仍會寫 wifi_scheduler.log 與 wifi_daily_summary.csv，方便快速驗證。
    *** 僅供測試，正式排程請勿使用 — 隨機 Sleep 是模擬正常上下班的核心設計 ***

.EXAMPLE
    .\Toggle-WiFi.ps1 -Action Connect
    .\Toggle-WiFi.ps1 -Action Disconnect -DryRun  -Verbose
    .\Toggle-WiFi.ps1 -Action Connect    -NoDelay -Verbose
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Connect', 'Disconnect')]
    [string]$Action,

    [switch]$DryRun,

    # 測試用：跳過 Random Sleep，立即執行 (仍寫 log/CSV)
    [switch]$NoDelay
)

# ---------- 常數 ----------
$AdapterDesc     = 'Intel(R) Wi-Fi 6E AX211 160MHz'
$MaxDelayMinutes = 10   # Get-Random -Maximum 是 exclusive → 實際範圍 0..9
$ForbiddenStartH = 0    # 00:00 (inclusive)
$ForbiddenEndH   = 6    # 06:00 (exclusive)

$ScriptDir    = $PSScriptRoot
$LogFile      = Join-Path $ScriptDir 'wifi_scheduler.log'
$Year         = (Get-Date).Year
$HolidayFile  = Join-Path $ScriptDir "holidays_$Year.json"

# 每日摘要 CSV — 一天一筆 (✓/✗)，UTF-8 BOM + CRLF (Excel 友善)
$DailySummary = Join-Path $ScriptDir 'wifi_daily_summary.csv'
$SymbolOK     = [char]0x2713   # ✓
$SymbolFail   = [char]0x2717   # ✗

# Wi-Fi SSID 優先清單 — 純 netsh 模式，網卡 radio 不關
# 編輯這個陣列即可改變優先順序，不必動其他邏輯
# 註：已排除 lenovo-internet (captive portal 開放網路，要瀏覽器手動 sign-in)
$PreferredSSIDs = @('lenovo-5G', 'lenovo')
# 每個 SSID 給足時間完成 802.1X PEAP 認證 + DHCP + NCSI/L3 偵測
$AssocWaitSec      = 90    # PEAP + DHCP + NCSI 在排程背景 session 常需更久
$OnlineSustainSec  = 6     # 連上 preferred SSID 且 L3 OK 需連續維持幾秒才算真成功
$PreConnectPauseSec = 3    # 強制 disconnect 後等待秒數，讓 802.1X 重新握手

# ---------- Logging (UTF-8 BOM，Excel / 記事本友善) ----------
$_utf8Log = New-Object System.Text.UTF8Encoding $true

function Write-AuditLog {
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Message
    )
    $line = '[{0}] {1,-10} {2,-10} {3}' -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `
        $Action.ToUpper(), `
        $Status, `
        $Message
    if (Test-Path $LogFile) {
        [System.IO.File]::AppendAllText($LogFile, $line + "`r`n", $_utf8Log)
    } else {
        [System.IO.File]::WriteAllText($LogFile, $line + "`r`n", $_utf8Log)
    }
    Write-Verbose $line
}

# ---------- Daily Summary CSV (upsert) ----------
function Update-DailySummary {
    param(
        [Parameter(Mandatory)][ValidateSet('Connect', 'Disconnect')][string]$WhichAction,
        [Parameter(Mandatory)][ValidateSet('OK', 'FAIL')][string]$Result
    )

    $date   = Get-Date -Format 'yyyy-MM-dd'
    $time   = Get-Date -Format 'HH:mm'
    $symbol = if ($Result -eq 'OK') { $SymbolOK } else { $SymbolFail }

    # 讀現有 rows (壞檔 fail-open: 視為空)
    $rows = @()
    if (Test-Path $DailySummary) {
        try {
            $rows = @(Import-Csv -Path $DailySummary -Encoding UTF8)
        } catch {
            Write-AuditLog -Status 'WARN' -Message "daily summary parse failed, recreating: $($_.Exception.Message)"
            $rows = @()
        }
    }

    # Upsert today's row — 已有 ✓ 則保留第一次成功時間，不被後續手動測試覆寫
    $todayRow = $rows | Where-Object { $_.Date -eq $date } | Select-Object -First 1
    if ($todayRow) {
        $field     = if ($WhichAction -eq 'Connect') { 'Connect' } else { 'Disconnect' }
        $timeField = "${field}Time"
        $existing  = $todayRow.$field

        if ($existing -eq $SymbolOK) {
            Write-AuditLog -Status 'SUMMARY' -Message "daily $field unchanged (already $SymbolOK at $($todayRow.$timeField), skip $Result at $time)"
            return
        }

        $todayRow.$field     = $symbol
        $todayRow.$timeField = $time
    } else {
        $newRow = [PSCustomObject]@{
            Date           = $date
            Connect        = if ($WhichAction -eq 'Connect')    { $symbol } else { '' }
            ConnectTime    = if ($WhichAction -eq 'Connect')    { $time }   else { '' }
            Disconnect     = if ($WhichAction -eq 'Disconnect') { $symbol } else { '' }
            DisconnectTime = if ($WhichAction -eq 'Disconnect') { $time }   else { '' }
        }
        $rows = $rows + $newRow
    }

    # Atomic write: temp file + Move-Item，UTF-8 BOM + CRLF
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    $lines   = @('Date,Connect,ConnectTime,Disconnect,DisconnectTime')
    foreach ($r in $rows) {
        $lines += '{0},{1},{2},{3},{4}' -f $r.Date, $r.Connect, $r.ConnectTime, $r.Disconnect, $r.DisconnectTime
    }
    $content = ($lines -join "`r`n") + "`r`n"

    $temp = "$DailySummary.tmp"
    [System.IO.File]::WriteAllText($temp, $content, $utf8Bom)
    # PS 5.x Move-Item -Force bug: fails when destination exists → delete first
    if (Test-Path $DailySummary) { Remove-Item -Path $DailySummary -Force }
    Move-Item -Path $temp -Destination $DailySummary

    Write-AuditLog -Status 'SUMMARY' -Message "daily $symbol at $time -> $DailySummary"
}

# ---------- netsh 輸出解碼：讀 raw bytes，依 OEM/UTF-8 擇優（修正 log 亂碼）----------
function Get-ConsoleOemEncoding {
    try {
        $chcp = (cmd /c 'chcp' 2>$null | Out-String)
        if ($chcp -match '(\d{3,5})') {
            return [System.Text.Encoding]::GetEncoding([int]$Matches[1])
        }
    } catch { }
    return [System.Text.Encoding]::GetEncoding(950)
}

function Convert-FromNetshBytes {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return '' }

    $encodings = @(
        (Get-ConsoleOemEncoding),
        ([System.Text.Encoding]::GetEncoding(950)),
        ([System.Text.Encoding]::UTF8)
    )
    $bestText  = ''
    $bestScore = [int]::MaxValue

    foreach ($enc in $encodings) {
        try {
            $text = $enc.GetString($Bytes).Trim()
        } catch { continue }
        if (-not $text) { continue }

        $score = 0
        if ($text -match '\uFFFD') { $score += 100 }
        if ($text -match '嚙|ï¿½') { $score += 80 }
        if ($text -match '成功|完成|連線|斷開|存取|介面|設定') { $score -= 30 }
        if ($text -match 'successfully|completed|connected|disconnected') { $score -= 15 }

        if ($score -lt $bestScore) {
            $bestScore = $score
            $bestText  = $text
        }
    }
    return $bestText
}

function Read-ProcessStreamBytes {
    param([System.IO.Stream]$Stream)
    $ms     = New-Object System.IO.MemoryStream
    $buffer = New-Object byte[] 8192
    while (($read = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $ms.Write($buffer, 0, $read) | Out-Null
    }
    return $ms.ToArray()
}

function Invoke-NetshCapture {
    param([Parameter(Mandatory)][string]$ArgString)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'netsh.exe'
    $psi.Arguments              = $ArgString
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    # 不設 StandardOutputEncoding → 自行以 bytes 解碼

    $proc = [System.Diagnostics.Process]::Start($psi)
    $outB = Read-ProcessStreamBytes -Stream $proc.StandardOutput.BaseStream
    $errB = Read-ProcessStreamBytes -Stream $proc.StandardError.BaseStream
    $proc.WaitForExit()

    $allBytes = New-Object System.Collections.Generic.List[byte]
    if ($outB) { $allBytes.AddRange($outB) }
    if ($errB) { $allBytes.AddRange($errB) }

    [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Output   = (Convert-FromNetshBytes -Bytes $allBytes.ToArray())
    }
}

# ---------- Wi-Fi association helpers ----------
function Get-ConnectedWifiSsid {
    $r = Invoke-NetshCapture -ArgString 'wlan show interfaces'
    foreach ($line in ($r.Output -split "`r?`n")) {
        if ($line -match '^\s*SSID\s*:\s*(.+)\s*$') {
            $name = $Matches[1].Trim()
            if ($name) { return $name }
        }
    }
    return $null
}

function Get-WifiLinkDiagnostics {
    $ssid = Get-ConnectedWifiSsid
    $a    = Get-NetAdapter -InterfaceDescription $AdapterDesc -ErrorAction SilentlyContinue
    if (-not $a) { return 'adapter not found' }
    $prof = Get-NetConnectionProfile -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue
    $l3   = if ($prof) { $prof.IPv4Connectivity } else { 'n/a' }
    $cat  = if ($prof) { $prof.NetworkCategory } else { 'n/a' }
    return "ssid='$ssid' L2=$($a.Status) L3=$l3 cat=$cat"
}

# 必須：preferred SSID + L3。僅 DomainAuthenticated 且 NoTraffic/LocalNetwork 不算（避免 5/28 假成功）
function Test-WifiL3Ready {
    param(
        $Profile,
        [string]$ConnectedSsid
    )
    if (-not $Profile -or $ConnectedSsid -notin $PreferredSSIDs) { return $false }
    if ($Profile.IPv4Connectivity -eq 'Internet') { return $true }
    if ($Profile.NetworkCategory -eq 'DomainAuthenticated' -and
        $Profile.IPv4Connectivity -in @('LocalNetwork', 'Subnet')) {
        return $true
    }
    return $false
}

function Wait-WiFiOnline {
    param([int]$Seconds)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $ssid = Get-ConnectedWifiSsid
        $a    = Get-NetAdapter -InterfaceDescription $AdapterDesc -ErrorAction SilentlyContinue
        if ($a -and $a.Status -eq 'Up') {
            $prof = Get-NetConnectionProfile -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue
            if (Test-WifiL3Ready -Profile $prof -ConnectedSsid $ssid) { return $true }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

# 連續數秒維持 preferred SSID + L3，避免瞬間誤判「already online」
function Test-PreferredWifiOnline {
    param([int]$SustainSeconds = $OnlineSustainSec)
    $need     = [Math]::Max(2, [int][Math]::Ceiling($SustainSeconds / 2))
    $hits     = 0
    $deadline = (Get-Date).AddSeconds($SustainSeconds + 4)
    while ((Get-Date) -lt $deadline -and $hits -lt $need) {
        $ssid = Get-ConnectedWifiSsid
        $a    = Get-NetAdapter -InterfaceDescription $AdapterDesc -ErrorAction SilentlyContinue
        if ($a -and $a.Status -eq 'Up') {
            $prof = Get-NetConnectionProfile -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue
            if (Test-WifiL3Ready -Profile $prof -ConnectedSsid $ssid) {
                $hits++
                if ($hits -ge $need) { return $true }
            } else { $hits = 0 }
        } else { $hits = 0 }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Invoke-WiFiConnectAttempt {
    param(
        [string]$Ssid,
        [string]$IfaceName
    )
    $attempts = @(
        @{ Label = 'connect';  Args = 'wlan connect name="{0}" interface="{1}"' -f $Ssid, $IfaceName },
        @{ Label = 'reconnect'; Args = 'wlan reconnect name="{0}" interface="{1}"' -f $Ssid, $IfaceName }
    )
    foreach ($attempt in $attempts) {
        Write-AuditLog -Status 'ASSOC' -Message "netsh $($attempt.Label) '$Ssid' on '$IfaceName'"
        $r = Invoke-NetshCapture -ArgString $attempt.Args
        $flat = ($r.Output -replace "`r?`n", " | ")
        if ($flat) { Write-AuditLog -Status 'ASSOC' -Message "netsh output (exit=$($r.ExitCode)): $flat" }
        if (Wait-WiFiOnline -Seconds $AssocWaitSec) {
            Write-AuditLog -Status 'ASSOC' -Message "online via '$Ssid' ($($attempt.Label))"
            return $true
        }
    }
    return $false
}

function Invoke-WiFiAssociate {
    $ifaceName = (Get-NetAdapter -InterfaceDescription $AdapterDesc -ErrorAction SilentlyContinue).Name
    if (-not $ifaceName) {
        Write-AuditLog -Status 'ERROR' -Message "cannot find adapter '$AdapterDesc'"
        return $false
    }

    Write-AuditLog -Status 'DIAG' -Message (Get-WifiLinkDiagnostics)

    if (Test-PreferredWifiOnline) {
        Write-AuditLog -Status 'ASSOC' -Message "already on preferred SSID with L3 ($(Get-WifiLinkDiagnostics))"
        return $true
    }

    # 清掉殘留關聯，強迫 802.1X 重新握手（解決 netsh exit=0 但 PEAP 未完成的狀況）
    Write-AuditLog -Status 'ASSOC' -Message "not ready; disconnect then retry connect ($(Get-WifiLinkDiagnostics))"
    $disc = Invoke-NetshCapture -ArgString ('wlan disconnect interface="{0}"' -f $ifaceName)
    $flat = ($disc.Output -replace "`r?`n", " | ")
    if ($flat) { Write-AuditLog -Status 'ASSOC' -Message "pre-connect disconnect (exit=$($disc.ExitCode)): $flat" }
    Start-Sleep -Seconds $PreConnectPauseSec

    foreach ($ssid in $PreferredSSIDs) {
        if (Invoke-WiFiConnectAttempt -Ssid $ssid -IfaceName $ifaceName) { return $true }
    }

    Write-AuditLog -Status 'WARN' -Message "no preferred SSID online after $($PreferredSSIDs -join ', '); final $(Get-WifiLinkDiagnostics)"
    return $false
}

# ---------- Gate 1: weekday ----------
$dow = (Get-Date).DayOfWeek
if ($dow -in @('Saturday', 'Sunday')) {
    Write-AuditLog -Status 'SKIP' -Message "weekend ($dow)"
    exit 0
}

# ---------- Gate 2: holiday ----------
if (Test-Path $HolidayFile) {
    try {
        $today    = Get-Date -Format 'yyyy-MM-dd'
        $holidays = (Get-Content $HolidayFile -Raw -Encoding UTF8 | ConvertFrom-Json).dates
        if ($holidays -contains $today) {
            Write-AuditLog -Status 'SKIP' -Message "holiday ($today)"
            exit 0
        }
    } catch {
        Write-AuditLog -Status 'WARN' -Message "holiday json parse failed: $($_.Exception.Message)"
        # 解析失敗不阻擋當天執行 (fail-open)
    }
} else {
    Write-AuditLog -Status 'WARN' -Message "holiday file not found: $HolidayFile"
}

# ---------- Gate 3: forbidden hours ----------
$nowHour = (Get-Date).Hour
if ($nowHour -ge $ForbiddenStartH -and $nowHour -lt $ForbiddenEndH) {
    Write-AuditLog -Status 'SKIP' -Message "forbidden-hours (current hour=$nowHour, blocked=[$ForbiddenStartH..$ForbiddenEndH))"
    exit 0
}

# ---------- Random delay ----------
$delayMin = Get-Random -Minimum 0 -Maximum $MaxDelayMinutes
Write-AuditLog -Status 'DELAY' -Message "$delayMin min (random 0..$($MaxDelayMinutes - 1))"

# ---------- DryRun branch ----------
if ($DryRun) {
    Write-AuditLog -Status 'DRYRUN' -Message "would sleep $delayMin min then $Action adapter '$AdapterDesc'"
    exit 0
}

# ---------- Sleep (or skip if -NoDelay) ----------
if ($NoDelay) {
    Write-AuditLog -Status 'NODELAY' -Message "skip sleep (would have been $delayMin min)"
} else {
    Start-Sleep -Seconds ($delayMin * 60)
}

# ---------- Final adapter action ----------
try {
    if ($Action -eq 'Connect') {
        # 防呆：若 adapter 被外部 Disable 過 (例如手動操作)，先打開 radio
        $a = Get-NetAdapter -InterfaceDescription $AdapterDesc -ErrorAction SilentlyContinue
        if ($a -and $a.Status -eq 'Disabled') {
            Enable-NetAdapter -InterfaceDescription $AdapterDesc -Confirm:$false -ErrorAction Stop
            Write-AuditLog -Status 'INFO' -Message "adapter was Disabled, enabled radio"
            Start-Sleep -Seconds 3
        }
        Write-AuditLog -Status 'DONE' -Message "starting netsh connect flow"

        $associated = Invoke-WiFiAssociate
        Update-DailySummary -WhichAction $Action -Result $(if ($associated) { 'OK' } else { 'FAIL' })
        if (-not $associated) { exit 1 }
    } else {
        # Disconnect 路徑：只放掉 SSID，網卡 radio 不關
        $ifaceName = (Get-NetAdapter -InterfaceDescription $AdapterDesc -ErrorAction SilentlyContinue).Name
        if (-not $ifaceName) { throw "adapter '$AdapterDesc' not found" }
        $r = Invoke-NetshCapture -ArgString ('wlan disconnect interface="{0}"' -f $ifaceName)
        $flat = ($r.Output -replace "`r?`n", " | ")
        Write-AuditLog -Status 'DONE' -Message ("Disconnect SSID via netsh (exit=$($r.ExitCode))" + $(if ($flat) { ": $flat" } else { "" }))
        Update-DailySummary -WhichAction $Action -Result 'OK'
    }
} catch {
    Write-AuditLog -Status 'ERROR' -Message $_.Exception.Message
    Update-DailySummary -WhichAction $Action -Result 'FAIL'
    exit 1
}
