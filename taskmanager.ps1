<#
.SYNOPSIS
    Read-only TUI Task Manager in pure PowerShell, with five tabs.

.DESCRIPTION
    Runs as a normal (non-elevated) user. No processes are killed, no
    priorities are changed - display only.

    Tab 1: live process table with real per-process CPU% (computed via
           sampling, not the cumulative Get-Process CPU field).
    Tab 2: CPU history per core (sparkline per logical processor, plus
           the overall load), kept in the background while you look at
           the other tabs.
    Tab 3: Disk activity per physical disk: busy %, read/write speed,
           IOPS and a busy% history sparkline.
    Tab 4: Network activity per adapter: download/upload speed, link
           utilisation and a throughput history sparkline.
    Tab 5: Temperature sensors (if the system exposes any): current,
           min and max per sensor plus a history sparkline.

.CONTROLS
    Tab        cycle through the five views
    1 / p      process overview
    2 / h      CPU history per core
    3 / d      disk activity
    4 / n      network activity
    5 / t      temperature sensors
    c          sort processes by CPU %
    m          sort processes by memory (working set)
    UP/DOWN    scroll one row (in the current view)
    PGUP/PGDN  scroll one page
    HOME       jump to top
    q / Esc    quit

.NOTES
    Works in Windows PowerShell 5.1, in a real console host (Windows Terminal, conhost). Not designed for the ISE.
    This file is pure ASCII on purpose; the block characters of the sparkline are built from code points.
#>

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
$RefreshMs   = 1000      # sample interval (history gets 1 sample per interval)
$SortBy      = 'CPU'     # 'CPU' or 'Mem'
$View        = 'Proc'    # 'Proc', 'Hist', 'Disk' or 'Net'
$ViewOrder   = @('Proc', 'Hist', 'Disk', 'Net', 'Temp')
$Scroll      = @{ Proc = 0; Hist = 0; Disk = 0; Net = 0; Temp = 0 }   # first visible row per view
$HistoryLen  = 600       # samples kept per series (600 = 10 minutes at 1/s)
$AvgWindow   = 60        # samples used for the AVG column
$UseUnicode  = $true     # $false = plain ASCII sparkline (. : - = + * # @)

$SparkChars = if ($UseUnicode) {
    @(0x2581..0x2588 | ForEach-Object { [string][char]$_ })
} else {
    @('.', ':', '-', '=', '+', '*', '#', '@')
}

$CoreHistory  = @{}
$TotalHistory = New-Object 'System.Collections.Generic.List[double]'
$DiskHistory  = @{}      # disk name    -> busy % history
$NetHistory   = @{}      # adapter name -> (down + up) bytes/s history
$TempHistory  = @{}      # sensor key   -> degrees C history
$TempFail     = @{}      # temperature source -> $true when it failed (retried now and then)
$SampleNo     = 0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Format-Fit {
    <# Pad or cut a string to exactly $w characters. #>
    param([string]$s, [int]$w)
    if ($w -lt 1) { return '' }
    if ($s.Length -gt $w) { return $s.Substring(0, $w) }
    return $s.PadRight($w)
}

function Format-Rate {
    <# Bytes per second -> human readable string. #>
    param([double]$Bps)
    if ($Bps -ge 1GB)     { return ('{0:N1} GB/s' -f ($Bps / 1GB)) }
    elseif ($Bps -ge 1MB) { return ('{0:N1} MB/s' -f ($Bps / 1MB)) }
    elseif ($Bps -ge 1KB) { return ('{0:N1} KB/s' -f ($Bps / 1KB)) }
    else                  { return ('{0:N0} B/s'  -f $Bps) }
}

function Get-SystemSnapshot {
    <# Overall CPU load, per-core load and memory stats - all readonly. #>
    $cpuLoad = $null
    $cores   = @()

    try {
        # One query returns every logical processor plus the _Total instance.
        # Locale independent (unlike Get-Counter on a Dutch Windows).
        $perf  = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction Stop)
        $total = $perf | Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1
        if ($total) { $cpuLoad = [double]$total.PercentProcessorTime }

        # Names are "0","1",... (or "0,3" with processor groups): sort numerically.
        $cores = @($perf |
            Where-Object { $_.Name -notlike '*_Total' } |
            Sort-Object { ($_.Name -split ',' | ForEach-Object { '{0:D5}' -f [int]$_ }) -join '' } |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name; Pct = [double]$_.PercentProcessorTime } })
    } catch {
        $cpuLoad = $null
        $cores   = @()
    }

    if ($null -eq $cpuLoad) {
        try {
            $cpuLoad = (Get-CimInstance Win32_Processor |
                Measure-Object -Property LoadPercentage -Average).Average
        } catch { $cpuLoad = $null }
    }

    $os = Get-CimInstance Win32_OperatingSystem
    $totalMemKB = $os.TotalVisibleMemorySize
    $freeMemKB  = $os.FreePhysicalMemory
    $usedMemKB  = $totalMemKB - $freeMemKB

    [pscustomobject]@{
        CpuLoad     = $cpuLoad
        Cores       = $cores
        TotalMemGB  = [math]::Round($totalMemKB / 1MB, 2)
        UsedMemGB   = [math]::Round($usedMemKB  / 1MB, 2)
        UsedMemPct  = if ($totalMemKB) { [math]::Round(($usedMemKB / $totalMemKB) * 100, 1) } else { 0 }
    }
}

function Get-DiskSnapshot {
    <# Per physical disk activity, plus an ALL row (the _Total instance). #>
    try {
        $perf = @(Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -ErrorAction Stop)
    } catch {
        return @()
    }
    $rows = foreach ($d in $perf) {
        $name = if ($d.Name -eq '_Total') { 'ALL' } else { [string]$d.Name }
        [pscustomobject]@{
            Name     = $name
            Busy     = [math]::Min([double]$d.PercentDiskTime, 100.0)
            ReadBps  = [double]$d.DiskReadBytesPersec
            WriteBps = [double]$d.DiskWriteBytesPersec
            Iops     = [double]$d.DiskReadsPersec + [double]$d.DiskWritesPersec
        }
    }
    $all   = @($rows | Where-Object { $_.Name -eq 'ALL' })
    $disks = @($rows | Where-Object { $_.Name -ne 'ALL' } | Sort-Object Name)
    return @($all + $disks)
}

function Get-NetSnapshot {
    <# Per network adapter throughput. Adapters without a link speed are hidden. #>
    try {
        $perf = @(Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop)
    } catch {
        return @()
    }
    $rows = foreach ($n in $perf) {
        $bw = [double]$n.CurrentBandwidth      # bits per second
        if ($bw -le 0) { continue }
        $rx = [double]$n.BytesReceivedPersec
        $tx = [double]$n.BytesSentPersec
        $util = [math]::Min((([math]::Max($rx, $tx) * 8) / $bw) * 100, 100.0)
        [pscustomobject]@{
            Name   = [string]$n.Name
            DownBps = $rx
            UpBps   = $tx
            LinkBps = $bw
            Util    = $util
        }
    }
    return @($rows | Sort-Object Name)
}

function Add-NamedHistory {
    <# Append a value to the history list stored under $Name in $Table. #>
    param($Table, [string]$Name, [double]$Value)
    if (-not $Table.ContainsKey($Name)) {
        $Table[$Name] = New-Object 'System.Collections.Generic.List[double]'
    }
    $h = $Table[$Name]
    $h.Add($Value)
    if ($h.Count -gt $script:HistoryLen) {
        $h.RemoveRange(0, $h.Count - $script:HistoryLen)
    }
}

function Add-History {
    <# Append the latest sample to the total and per-core histories. #>
    param($Sys)

    $t = 0.0
    if ($null -ne $Sys.CpuLoad) { $t = [double]$Sys.CpuLoad }
    $script:TotalHistory.Add($t)
    if ($script:TotalHistory.Count -gt $script:HistoryLen) {
        $script:TotalHistory.RemoveRange(0, $script:TotalHistory.Count - $script:HistoryLen)
    }

    foreach ($c in $Sys.Cores) {
        if (-not $script:CoreHistory.ContainsKey($c.Name)) {
            $script:CoreHistory[$c.Name] = New-Object 'System.Collections.Generic.List[double]'
        }
        $h = $script:CoreHistory[$c.Name]
        $h.Add([double]$c.Pct)
        if ($h.Count -gt $script:HistoryLen) {
            $h.RemoveRange(0, $h.Count - $script:HistoryLen)
        }
    }
}

function Get-RecentAvg {
    param($Hist, [int]$N)
    $count = $Hist.Count
    if ($count -eq 0) { return 0.0 }
    $take = [math]::Min($count, $N)
    $sum  = 0.0
    for ($i = $count - $take; $i -lt $count; $i++) { $sum += $Hist[$i] }
    return ($sum / $take)
}

function Get-HistMax {
    <# Highest value in a history list (0 when empty). #>
    param($Hist)
    $m = 0.0
    foreach ($v in $Hist) { if ($v -gt $m) { $m = $v } }
    return $m
}

function Get-Spark {
    <# Turn the last $Width samples into a string of block characters.
       Values are scaled against $Max (100 = percent). #>
    param($Hist, [int]$Width, [double]$Max = 100.0, [double]$Min = 0.0)
    $sb    = New-Object System.Text.StringBuilder
    $count = $Hist.Count
    $take  = [math]::Min($count, $Width)
    if ($take -lt $Width) { [void]$sb.Append(' ' * ($Width - $take)) }
    for ($i = $count - $take; $i -lt $count; $i++) {
        $idx = 0
        if ($Max -gt $Min) { $idx = [int][math]::Floor((($Hist[$i] - $Min) / ($Max - $Min)) * 8) }
        if ($idx -gt 7) { $idx = 7 }
        if ($idx -lt 0) { $idx = 0 }
        [void]$sb.Append($script:SparkChars[$idx])
    }
    return $sb.ToString()
}

function Get-ProcessSample {
    <# One sample of Id -> cumulative CPU seconds + working set, timestamped. #>
    $now = Get-Date
    $procs = Get-Process -ErrorAction SilentlyContinue
    $map = @{}
    foreach ($p in $procs) {
        $map[$p.Id] = [pscustomobject]@{
            Id     = $p.Id
            Name   = $p.ProcessName
            CpuSec = $p.CPU
            WS     = $p.WorkingSet64
            Handles= $p.Handles
            Threads= $p.Threads.Count
        }
    }
    [pscustomobject]@{ Time = $now; Procs = $map }
}

function Get-ProcessTable {
    <# Combine two samples into a live table with real CPU% per process. #>
    param($Prev, $Curr, [int]$CoreCount)

    $deltaT = ($Curr.Time - $Prev.Time).TotalSeconds
    if ($deltaT -le 0) { $deltaT = [double]::Epsilon }

    $rows = foreach ($id in $Curr.Procs.Keys) {
        $c = $Curr.Procs[$id]
        $p = $Prev.Procs[$id]
        $cpuPct = 0
        if ($p) {
            $deltaCpu = $c.CpuSec - $p.CpuSec
            if ($deltaCpu -lt 0) { $deltaCpu = 0 }
            $cpuPct = [math]::Round(($deltaCpu / $deltaT / [math]::Max($CoreCount,1)) * 100, 1)
        }
        [pscustomobject]@{
            Id      = $c.Id
            Name    = $c.Name
            CpuPct  = $cpuPct
            MemMB   = [math]::Round($c.WS / 1MB, 1)
            Threads = $c.Threads
            Handles = $c.Handles
        }
    }
    return $rows
}

function Write-Bar {
    param([double]$Pct, [int]$Width = 20)
    $filled = [math]::Round(($Pct / 100) * $Width)
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $Width) { $filled = $Width }
    $color = if ($Pct -ge 85) { 'Red' } elseif ($Pct -ge 60) { 'Yellow' } else { 'Green' }
    Write-Host ('[' ) -NoNewline
    Write-Host ('#' * $filled) -NoNewline -ForegroundColor $color
    Write-Host (' ' * ($Width - $filled)) -NoNewline
    Write-Host ('] {0,5:N1}%' -f $Pct) -NoNewline
}

function Write-TabBar {
    param([string]$View, [int]$Width)
    $tabs = @(
        @{ Key = 'Proc'; Label = ' 1 Processes ' },
        @{ Key = 'Hist'; Label = ' 2 CPU history ' },
        @{ Key = 'Disk'; Label = ' 3 Disk ' },
        @{ Key = 'Net';  Label = ' 4 Network ' },
        @{ Key = 'Temp'; Label = ' 5 Temps ' }
    )
    $used = 0
    foreach ($t in $tabs) {
        if ($t.Key -eq $View) {
            Write-Host $t.Label -NoNewline -ForegroundColor Black -BackgroundColor Cyan
        } else {
            Write-Host $t.Label -NoNewline -ForegroundColor White -BackgroundColor DarkBlue
        }
        Write-Host ' ' -NoNewline
        $used += $t.Label.Length + 1
    }
    $hint = '  [Tab] switch view'
    Write-Host (Format-Fit $hint ([math]::Max($Width - 1 - $used, 0))) -ForegroundColor DarkGray
}

function Write-SparkLine {
    <# A text prefix followed by a coloured sparkline filling the rest of the row. #>
    param(
        [string]$Prefix, $Hist, [int]$Width,
        [string]$PrefixColor = 'Gray', [string]$SparkColor = 'Green',
        [double]$Max = 100.0, [double]$Min = 0.0
    )
    $sparkW = [math]::Max($Width - 1 - $Prefix.Length, 5)
    $spark  = Get-Spark $Hist $sparkW $Max $Min
    Write-Host $Prefix -NoNewline -ForegroundColor $PrefixColor
    Write-Host $spark -ForegroundColor $SparkColor
}

function Write-HistRow {
    param([string]$Label, $Hist, [int]$Width, [string]$LabelColor = 'Gray')
    $now = 0.0
    if ($Hist.Count -gt 0) { $now = $Hist[$Hist.Count - 1] }
    $avg    = Get-RecentAvg $Hist $script:AvgWindow
    $prefix = '{0,-8}{1,7:N1}{2,8:N1}  ' -f $Label, $now, $avg
    $color  = if ($now -ge 85) { 'Red' } elseif ($now -ge 60) { 'Yellow' } else { 'Green' }
    Write-SparkLine -Prefix $prefix -Hist $Hist -Width $Width -PrefixColor $LabelColor -SparkColor $color
}

function Write-DiskRow {
    param($D, [int]$Width)
    $h = $script:DiskHistory[$D.Name]
    $label = if ($D.Name.Length -gt 13) { $D.Name.Substring(0, 13) } else { $D.Name }
    $prefix = '{0,-14}{1,7:N1}{2,13}{3,13}{4,9:N0}  ' -f $label, $D.Busy, (Format-Rate $D.ReadBps), (Format-Rate $D.WriteBps), $D.Iops
    $color  = if ($D.Busy -ge 85) { 'Red' } elseif ($D.Busy -ge 60) { 'Yellow' } else { 'Green' }
    $lblCol = if ($D.Name -eq 'ALL') { 'Cyan' } else { 'Gray' }
    Write-SparkLine -Prefix $prefix -Hist $h -Width $Width -PrefixColor $lblCol -SparkColor $color
}

function Write-NetRow {
    param($N, [int]$Width)
    $h = $script:NetHistory[$N.Name]
    $label = if ($N.Name.Length -gt 25) { $N.Name.Substring(0, 25) } else { $N.Name }
    $prefix = '{0,-26}{1,13}{2,13}{3,7:N1}  ' -f $label, (Format-Rate $N.DownBps), (Format-Rate $N.UpBps), $N.Util
    $color  = if ($N.Util -ge 85) { 'Red' } elseif ($N.Util -ge 60) { 'Yellow' } else { 'Green' }
    # Auto-scale to this adapter's own peak (with a 10 KB/s floor so idle
    # noise does not look like activity).
    $max = [math]::Max((Get-HistMax $h), 10KB)
    Write-SparkLine -Prefix $prefix -Hist $h -Width $Width -PrefixColor 'Gray' -SparkColor $color -Max $max
}

function Test-TempSource {
    <# A source that failed is only retried every 15th sample (saves slow WMI errors). #>
    param([string]$Key)
    if (-not $script:TempFail.ContainsKey($Key)) { return $true }
    return (($script:SampleNo % 15) -eq 0)
}

function Get-TempSnapshot {
    <# Temperature sensors in degrees C, from whatever the system exposes:
         PERF  Windows "Thermal Zone Information" performance counters
         ACPI  MSAcpi_ThermalZoneTemperature (usually needs admin; only tried
               when PERF returned nothing, as it reports the same zones)
         LHM   LibreHardwareMonitor WMI provider, if that program is running
         OHM   OpenHardwareMonitor WMI provider, if that program is running #>
    $out = New-Object System.Collections.ArrayList

    if (Test-TempSource 'PERF') {
        try {
            $zones = @(Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop)
            $script:TempFail.Remove('PERF')
            foreach ($z in $zones) {
                $c = $null
                if ([double]$z.HighPrecisionTemperature -gt 0) { $c = [double]$z.HighPrecisionTemperature / 10 - 273.15 }
                elseif ([double]$z.Temperature -gt 0)          { $c = [double]$z.Temperature - 273.15 }
                if ($null -ne $c -and $c -gt -50 -and $c -lt 150) {
                    [void]$out.Add([pscustomobject]@{
                        Key  = 'PERF|' + $z.Name
                        Name = 'Thermal zone ' + ($z.Name -replace '^\\_TZ\.', '' -replace '^\\', '')
                        Src  = 'PERF'
                        Temp = [math]::Round($c, 1)
                    })
                }
            }
        } catch { $script:TempFail['PERF'] = $true }
    }

    if ($out.Count -eq 0 -and (Test-TempSource 'ACPI')) {
        try {
            $acpi = @(Get-CimInstance -Namespace 'root/wmi' -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)
            $script:TempFail.Remove('ACPI')
            foreach ($z in $acpi) {
                $c = [double]$z.CurrentTemperature / 10 - 273.15
                if ($c -gt -50 -and $c -lt 150) {
                    [void]$out.Add([pscustomobject]@{
                        Key  = 'ACPI|' + $z.InstanceName
                        Name = 'ACPI ' + ($z.InstanceName -replace '^ACPI\\', '')
                        Src  = 'ACPI'
                        Temp = [math]::Round($c, 1)
                    })
                }
            }
        } catch { $script:TempFail['ACPI'] = $true }
    }

    foreach ($m in @(@{ Src = 'LHM'; Ns = 'root/LibreHardwareMonitor' }, @{ Src = 'OHM'; Ns = 'root/OpenHardwareMonitor' })) {
        if (-not (Test-TempSource $m.Src)) { continue }
        try {
            $sensors = @(Get-CimInstance -Namespace $m.Ns -ClassName Sensor -Filter "SensorType='Temperature'" -ErrorAction Stop)
            $script:TempFail.Remove($m.Src)
            foreach ($s in $sensors) {
                if ($null -eq $s.Value) { continue }
                $c = [double]$s.Value
                if ($c -le -50 -or $c -ge 150) { continue }
                $hw = (([string]$s.Identifier) -split '/')[1]
                [void]$out.Add([pscustomobject]@{
                    Key  = $m.Src + '|' + $s.Identifier
                    Name = ('{0} ({1})' -f $s.Name, $hw)
                    Src  = $m.Src
                    Temp = [math]::Round($c, 1)
                })
            }
        } catch { $script:TempFail[$m.Src] = $true }
    }

    return @($out | Sort-Object Src, Name)
}

function Write-TempRow {
    param($T, [int]$Width)
    $h = $script:TempHistory[$T.Key]
    $min = $T.Temp; $max = $T.Temp
    foreach ($v in $h) { if ($v -lt $min) { $min = $v }; if ($v -gt $max) { $max = $v } }
    $label  = if ($T.Name.Length -gt 29) { $T.Name.Substring(0, 29) } else { $T.Name }
    $prefix = '{0,-30}{1,8:N1}{2,8:N1}{3,8:N1}  {4,-5}  ' -f $label, $T.Temp, $min, $max, $T.Src
    $color  = if ($T.Temp -ge 85) { 'Red' } elseif ($T.Temp -ge 70) { 'Yellow' } else { 'Green' }
    # Sparkline range 20..100 C so small changes stay visible.
    Write-SparkLine -Prefix $prefix -Hist $h -Width $Width -PrefixColor 'Gray' -SparkColor $color -Max 100 -Min 20
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
$CoreCount = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
if (-not $CoreCount) { $CoreCount = [Environment]::ProcessorCount }

[Console]::CursorVisible = $false
Clear-Host

$prevSample = Get-ProcessSample
Start-Sleep -Milliseconds 300   # tiny warm-up so the first CPU% isn't all zero

$sys        = $null
$disks      = @()
$nets       = @()
$temps      = @()
$rowsRaw    = @()
$lastSample = [datetime]::MinValue
$lastW      = 0
$lastH      = 0

try {
    while ($true) {

        # --- sample (at most once per refresh interval) ---
        if (((Get-Date) - $lastSample).TotalMilliseconds -ge $RefreshMs) {
            $sys        = Get-SystemSnapshot
            $currSample = Get-ProcessSample
            $rowsRaw    = @(Get-ProcessTable -Prev $prevSample -Curr $currSample -CoreCount $CoreCount)
            $prevSample = $currSample
            Add-History $sys

            $disks = @(Get-DiskSnapshot)
            foreach ($d in $disks) { Add-NamedHistory $DiskHistory $d.Name $d.Busy }
            $nets = @(Get-NetSnapshot)
            foreach ($n in $nets) { Add-NamedHistory $NetHistory $n.Name ($n.DownBps + $n.UpBps) }

            $SampleNo++
            $temps = @(Get-TempSnapshot)
            foreach ($t in $temps) { Add-NamedHistory $TempHistory $t.Key $t.Temp }

            $lastSample = Get-Date
        }

        $rows = if ($SortBy -eq 'Mem') {
            @($rowsRaw | Sort-Object MemMB -Descending)
        } else {
            @($rowsRaw | Sort-Object CpuPct -Descending)
        }

        # --- layout ---
        $consoleHeight = [Console]::WindowHeight
        $width         = [Console]::WindowWidth
        if ($width -ne $lastW -or $consoleHeight -ne $lastH) {
            Clear-Host
            $lastW = $width
            $lastH = $consoleHeight
        }

        $headerLines = 8
        $footerLines = 2
        $visibleRows = [math]::Max($consoleHeight - $headerLines - $footerLines, 3)
        $histVisible = [math]::Max($visibleRows - 1, 2)    # row 1 of the history view is the ALL line

        $coreList = @($sys.Cores)

        $maxProc = [math]::Max($rows.Count - $visibleRows, 0)
        if ($Scroll['Proc'] -gt $maxProc) { $Scroll['Proc'] = $maxProc }
        if ($Scroll['Proc'] -lt 0)        { $Scroll['Proc'] = 0 }

        $maxHist = [math]::Max($coreList.Count - $histVisible, 0)
        if ($Scroll['Hist'] -gt $maxHist) { $Scroll['Hist'] = $maxHist }
        if ($Scroll['Hist'] -lt 0)        { $Scroll['Hist'] = 0 }

        $maxDisk = [math]::Max($disks.Count - $visibleRows, 0)
        if ($Scroll['Disk'] -gt $maxDisk) { $Scroll['Disk'] = $maxDisk }
        if ($Scroll['Disk'] -lt 0)        { $Scroll['Disk'] = 0 }

        $maxNet = [math]::Max($nets.Count - $visibleRows, 0)
        if ($Scroll['Net'] -gt $maxNet) { $Scroll['Net'] = $maxNet }
        if ($Scroll['Net'] -lt 0)       { $Scroll['Net'] = 0 }

        $maxTemp = [math]::Max($temps.Count - $visibleRows, 0)
        if ($Scroll['Temp'] -gt $maxTemp) { $Scroll['Temp'] = $maxTemp }
        if ($Scroll['Temp'] -lt 0)        { $Scroll['Temp'] = 0 }

        # --- draw: shared header ---
        [Console]::SetCursorPosition(0, 0)

        Write-Host ('PowerShell Task Manager'.PadRight($width - 20)) -NoNewline -ForegroundColor Cyan
        Write-Host ((Get-Date).ToString('HH:mm:ss')) -ForegroundColor DarkGray
        Write-Host ('-' * ($width - 1)) -ForegroundColor DarkGray

        Write-Host ('CPU  ') -NoNewline
        if ($null -ne $sys.CpuLoad) { Write-Bar -Pct $sys.CpuLoad } else { Write-Host '  n/a' -NoNewline }
        Write-Host ('   Cores: {0}' -f $CoreCount)

        Write-Host ('MEM  ') -NoNewline
        Write-Bar -Pct $sys.UsedMemPct
        Write-Host ('   {0} / {1} GB' -f $sys.UsedMemGB, $sys.TotalMemGB)

        Write-Host ('-' * ($width - 1)) -ForegroundColor DarkGray
        Write-TabBar -View $View -Width $width

        if ($View -eq 'Proc') {
            # ---------------- tab 1: processes ----------------
            $slice  = @($rows | Select-Object -Skip $Scroll['Proc'] -First $visibleRows)
            $cpuHdr = if ($SortBy -eq 'CPU') { 'CPU%*' } else { 'CPU%' }
            $memHdr = if ($SortBy -eq 'Mem') { 'MEM(MB)*' } else { 'MEM(MB)' }
            $hdr    = '{0,-8}{1,-25}{2,10}{3,12}{4,10}{5,10}' -f 'PID','NAME',$cpuHdr,$memHdr,'THREADS','HANDLES'
            Write-Host (Format-Fit $hdr ($width - 1)) -ForegroundColor White

            foreach ($r in $slice) {
                $name  = if ($r.Name.Length -gt 24) { $r.Name.Substring(0,24) } else { $r.Name }
                $line  = '{0,-8}{1,-25}{2,10:N1}{3,12:N1}{4,10}{5,10}' -f $r.Id, $name, $r.CpuPct, $r.MemMB, $r.Threads, $r.Handles
                $color = if ($r.CpuPct -ge 50) { 'Red' } elseif ($r.CpuPct -ge 20) { 'Yellow' } else { 'Gray' }
                Write-Host (Format-Fit $line ($width - 1)) -ForegroundColor $color
            }
            for ($i = $slice.Count; $i -lt $visibleRows; $i++) {
                Write-Host (' ' * ($width - 1))
            }

            Write-Host ('-' * ($width - 1)) -ForegroundColor DarkGray
            $first  = if ($slice.Count -gt 0) { $Scroll['Proc'] + 1 } else { 0 }
            $footer = '[Tab] next view  [c] sort CPU  [m] sort MEM  [up/down/pgup/pgdn/home] scroll  [q] quit   showing {0}-{1} of {2}' -f `
                $first, ($Scroll['Proc'] + $slice.Count), $rows.Count
            Write-Host (Format-Fit $footer ($width - 1)) -ForegroundColor DarkGray
        }
        elseif ($View -eq 'Hist') {
            # ---------------- tab 2: CPU history ----------------
            $hdr = '{0,-8}{1,7}{2,8}  {3}' -f 'CORE', 'NOW%', ('AVG{0}s%' -f $AvgWindow), 'HISTORY (1 sample/s, newest on the right)'
            Write-Host (Format-Fit $hdr ($width - 1)) -ForegroundColor White

            Write-HistRow -Label 'ALL' -Hist $TotalHistory -Width $width -LabelColor 'Cyan'

            $coreSlice = @($coreList | Select-Object -Skip $Scroll['Hist'] -First $histVisible)
            foreach ($c in $coreSlice) {
                Write-HistRow -Label ('Core ' + $c.Name) -Hist $CoreHistory[$c.Name] -Width $width
            }
            for ($i = $coreSlice.Count; $i -lt $histVisible; $i++) {
                Write-Host (' ' * ($width - 1))
            }

            Write-Host ('-' * ($width - 1)) -ForegroundColor DarkGray
            $first  = if ($coreSlice.Count -gt 0) { $Scroll['Hist'] + 1 } else { 0 }
            $footer = '[Tab] next view  [up/down/pgup/pgdn/home] scroll cores  [q] quit   showing cores {0}-{1} of {2}' -f `
                $first, ($Scroll['Hist'] + $coreSlice.Count), $coreList.Count
            Write-Host (Format-Fit $footer ($width - 1)) -ForegroundColor DarkGray
        }
        elseif ($View -eq 'Disk') {
            # ---------------- tab 3: disk activity ----------------
            $hdr = '{0,-14}{1,7}{2,13}{3,13}{4,9}  {5}' -f 'DISK', 'BUSY%', 'READ', 'WRITE', 'IOPS', 'BUSY% HISTORY (1 sample/s)'
            Write-Host (Format-Fit $hdr ($width - 1)) -ForegroundColor White

            $diskSlice = @($disks | Select-Object -Skip $Scroll['Disk'] -First $visibleRows)
            foreach ($d in $diskSlice) {
                Write-DiskRow -D $d -Width $width
            }
            if ($disks.Count -eq 0) {
                Write-Host (Format-Fit 'No disk counters available.' ($width - 1)) -ForegroundColor DarkGray
            }
            $drawn = [math]::Max($diskSlice.Count, 1 * [int]($disks.Count -eq 0))
            for ($i = $drawn; $i -lt $visibleRows; $i++) {
                Write-Host (' ' * ($width - 1))
            }

            Write-Host ('-' * ($width - 1)) -ForegroundColor DarkGray
            $first  = if ($diskSlice.Count -gt 0) { $Scroll['Disk'] + 1 } else { 0 }
            $footer = '[Tab] next view  [up/down/pgup/pgdn/home] scroll  [q] quit   showing {0}-{1} of {2}' -f `
                $first, ($Scroll['Disk'] + $diskSlice.Count), $disks.Count
            Write-Host (Format-Fit $footer ($width - 1)) -ForegroundColor DarkGray
        }
        elseif ($View -eq 'Net') {
            # ---------------- tab 4: network activity ----------------
            $hdr = '{0,-26}{1,13}{2,13}{3,7}  {4}' -f 'ADAPTER', 'DOWN', 'UP', 'LINK%', 'DOWN+UP HISTORY (scaled to peak)'
            Write-Host (Format-Fit $hdr ($width - 1)) -ForegroundColor White

            $netSlice = @($nets | Select-Object -Skip $Scroll['Net'] -First $visibleRows)
            foreach ($n in $netSlice) {
                Write-NetRow -N $n -Width $width
            }
            if ($nets.Count -eq 0) {
                Write-Host (Format-Fit 'No network counters available.' ($width - 1)) -ForegroundColor DarkGray
            }
            $drawn = [math]::Max($netSlice.Count, 1 * [int]($nets.Count -eq 0))
            for ($i = $drawn; $i -lt $visibleRows; $i++) {
                Write-Host (' ' * ($width - 1))
            }

            Write-Host ('-' * ($width - 1)) -ForegroundColor DarkGray
            $first  = if ($netSlice.Count -gt 0) { $Scroll['Net'] + 1 } else { 0 }
            $footer = '[Tab] next view  [up/down/pgup/pgdn/home] scroll  [q] quit   showing {0}-{1} of {2}' -f `
                $first, ($Scroll['Net'] + $netSlice.Count), $nets.Count
            Write-Host (Format-Fit $footer ($width - 1)) -ForegroundColor DarkGray
        }
        else {
            # ---------------- tab 5: temperatures ----------------
            $hdr = '{0,-30}{1,8}{2,8}{3,8}  {4,-5}  {5}' -f 'SENSOR', 'NOW C', 'MIN', 'MAX', 'SRC', 'HISTORY (1 sample/s, scale 20-100 C)'
            Write-Host (Format-Fit $hdr ($width - 1)) -ForegroundColor White

            $tempSlice = @($temps | Select-Object -Skip $Scroll['Temp'] -First $visibleRows)
            foreach ($t in $tempSlice) {
                Write-TempRow -T $t -Width $width
            }
            $drawn = $tempSlice.Count
            if ($temps.Count -eq 0) {
                $msgs = @(
                    'No temperature sensors are exposed to this session.',
                    'Many PCs only publish ACPI thermal zones to administrators, and',
                    'CPU/GPU/disk sensors need a hardware monitor with a WMI provider.',
                    'Start LibreHardwareMonitor or OpenHardwareMonitor (as admin) and',
                    'leave it running: its sensors show up here automatically.'
                )
                foreach ($m in $msgs) {
                    if ($drawn -lt $visibleRows) {
                        Write-Host (Format-Fit $m ($width - 1)) -ForegroundColor DarkGray
                        $drawn++
                    }
                }
            }
            for ($i = $drawn; $i -lt $visibleRows; $i++) {
                Write-Host (' ' * ($width - 1))
            }

            Write-Host ('-' * ($width - 1)) -ForegroundColor DarkGray
            $first  = if ($tempSlice.Count -gt 0) { $Scroll['Temp'] + 1 } else { 0 }
            $footer = '[Tab] next view  [up/down/pgup/pgdn/home] scroll  [q] quit   showing {0}-{1} of {2}' -f `
                $first, ($Scroll['Temp'] + $tempSlice.Count), $temps.Count
            Write-Host (Format-Fit $footer ($width - 1)) -ForegroundColor DarkGray
        }

        # --- input handling (non-blocking). A key press redraws immediately
        #     without taking a new sample, so switching tabs feels instant. ---
        $pageRows = if ($View -eq 'Hist') { $histVisible } else { $visibleRows }
        $deadline = $lastSample.AddMilliseconds($RefreshMs)
        $quit     = $false
        $redraw   = $false

        while (-not $redraw -and (Get-Date) -lt $deadline) {
            if ([Console]::KeyAvailable) {
                while ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    switch ($key.Key) {
                        'C'         { $SortBy = 'CPU' }
                        'M'         { $SortBy = 'Mem' }
                        'Tab'       {
                            $i = [array]::IndexOf($ViewOrder, $View)
                            $View = $ViewOrder[($i + 1) % $ViewOrder.Count]
                        }
                        'D1'        { $View = 'Proc' }
                        'NumPad1'   { $View = 'Proc' }
                        'P'         { $View = 'Proc' }
                        'D2'        { $View = 'Hist' }
                        'NumPad2'   { $View = 'Hist' }
                        'H'         { $View = 'Hist' }
                        'D3'        { $View = 'Disk' }
                        'NumPad3'   { $View = 'Disk' }
                        'D'         { $View = 'Disk' }
                        'D4'        { $View = 'Net' }
                        'NumPad4'   { $View = 'Net' }
                        'N'         { $View = 'Net' }
                        'D5'        { $View = 'Temp' }
                        'NumPad5'   { $View = 'Temp' }
                        'T'         { $View = 'Temp' }
                        'UpArrow'   { $Scroll[$View] -= 1 }
                        'DownArrow' { $Scroll[$View] += 1 }
                        'PageUp'    { $Scroll[$View] -= $pageRows }
                        'PageDown'  { $Scroll[$View] += $pageRows }
                        'Home'      { $Scroll[$View] = 0 }
                        'Q'         { $quit = $true }
                        'Escape'    { $quit = $true }
                    }
                    if ($Scroll[$View] -lt 0) { $Scroll[$View] = 0 }
                }
                $redraw = $true
            } else {
                Start-Sleep -Milliseconds 30
            }
        }
        if ($quit) { break }
    }
}
finally {
    [Console]::CursorVisible = $true
    Clear-Host
    Write-Host 'Task manager gesloten.' -ForegroundColor Cyan
}
