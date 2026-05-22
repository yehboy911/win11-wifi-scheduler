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
$AssocWaitSec   = 45   # 每個 SSID 嘗試連線後等到「真的上網」的秒數

# netsh 輸出用 OEM codepage 解碼 (繁中 Windows = CP950/Big5)，避免寫進 UTF-8 log 亂碼
# S4U 背景 session 的 CurrentCulture 可能 fallback 到 en-US (OEMCodePage=437)，強制修正為 950
$_oemCodePage = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
if ($_oemCodePage -eq 437) { $_oemCodePage = 950 }
$_oemEncoding = [System.Text.Encoding]::GetEncoding($_oemCodePage)

# ---------- Logging ----------
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
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
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

    # Upsert today's row
    $todayRow = $rows | Where-Object { $_.Date -eq $date } | Select-Object -First 1
    if ($todayRow) {
        if ($WhichAction -eq 'Connect') {
            $todayRow.Connect        = $symbol
            $todayRow.ConnectTime    = $time
        } else {
            $todayRow.Disconnect     = $symbol
            $todayRow.DisconnectTime = $time
        }
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

# ---------- netsh 包裝：用 OEM codepage 明確解碼，避免寫進 UTF-8 log 亂碼 ----------
function Invoke-NetshCapture {
    param([Parameter(Mandatory)][string]$ArgString)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'netsh.exe'
    $psi.Arguments              = $ArgString
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = $_oemEncoding
    $psi.StandardErrorEncoding  = $_oemEncoding
    $psi.CreateNoWindow         = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $out  = $proc.StandardOutput.ReadToEnd()
    $err  = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Output   = ($out + $err).Trim()
    }
}

# ---------- Wi-Fi association helpers ----------
# 真的上網才算成功：L2 (Status=Up) + L3 任一條件
#   (a) IPv4Connectivity = 'Internet'              (NCSI 偵測到對外網路)
#   (b) NetworkCategory  = 'DomainAuthenticated'   (連到 AD 公司網, 即使 NCSI 還沒跟上)
# 這樣 captive portal 卡「需要採取動作」、802.1X 認證待輸入都會被偵測為失敗
function Wait-WiFiOnline {
    param([int]$Seconds)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $a = Get-NetAdapter -InterfaceDescription $AdapterDesc -ErrorAction SilentlyContinue
        if ($a -and $a.Status -eq 'Up') {
            $prof = Get-NetConnectionProfile -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue
            if ($prof) {
                if ($prof.IPv4Connectivity -eq 'Internet' -or $prof.NetworkCategory -eq 'DomainAuthenticated') {
                    return $true
                }
            }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Invoke-WiFiAssociate {
    $ifaceName = (Get-NetAdapter -InterfaceDescription $AdapterDesc -ErrorAction SilentlyContinue).Name
    if (-not $ifaceName) {
        Write-AuditLog -Status 'ERROR' -Message "cannot find adapter '$AdapterDesc'"
        return $false
    }

    # 邊角情境：可能已經 online (用戶手動先連好了)
    if (Wait-WiFiOnline -Seconds 2) {
        Write-AuditLog -Status 'ASSOC' -Message "already online (no connect needed)"
        return $true
    }

    # 依優先順序，直接 netsh wlan connect 每個 SSID (不等自動)
    foreach ($ssid in $PreferredSSIDs) {
        Write-AuditLog -Status 'ASSOC' -Message "netsh connect '$ssid' on '$ifaceName'"
        $r = Invoke-NetshCapture -ArgString ('wlan connect name="{0}" interface="{1}"' -f $ssid, $ifaceName)
        # 攤平 netsh 多行輸出供診斷（含「存取被拒」等錯誤），中文已用 OEM codepage 正確解碼
        $flat = ($r.Output -replace "`r?`n", " | ")
        if ($flat) { Write-AuditLog -Status 'ASSOC' -Message "netsh output (exit=$($r.ExitCode)): $flat" }

        if (Wait-WiFiOnline -Seconds $AssocWaitSec) {
            Write-AuditLog -Status 'ASSOC' -Message "online via '$ssid'"
            return $true
        }
    }

    Write-AuditLog -Status 'WARN' -Message "no SSID online after trying $($PreferredSSIDs -join ', ') (check 'netsh output:' lines above for 存取被拒 / 找不到設定檔 / etc.)"
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
