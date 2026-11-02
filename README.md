# PowerShell Task Manager

A read-only, text-based Task Manager for the terminal, written in a single pure PowerShell script. No modules, no dependencies, no admin rights required.

It shows live system load in five tabs: processes, CPU history per core, disk activity, network activity and temperature sensors.

> **Display only.** The script never kills processes, changes priorities or modifies anything on your system.

## Features

- **Processes**: live process table with real per-process CPU % (computed by sampling, not the cumulative `Get-Process` CPU value), memory, threads and handles. Sort by CPU or memory.
- **CPU history**: one sparkline per logical processor plus the overall load, with the current value and a 60-second average. History is recorded in the background while you look at other tabs.
- **Disk**: per physical disk busy %, read speed, write speed and IOPS, with a busy % history sparkline.
- **Network**: per adapter download and upload speed, link utilisation and a throughput history sparkline that auto-scales to the adapter's own peak.
- **Temperatures**: current, min and max per sensor with a history sparkline, using whatever sensors your system exposes (see [Temperature sensors](#temperature-sensors)).
- Always-visible header with CPU and memory bars.
- Instant redraw on key press, resize-aware layout, scrolling in every tab.
- Locale independent: uses CIM/WMI performance classes instead of localized counter names, so it also works on non-English Windows.

## Requirements

- Windows 10 / 11 (or Windows Server)
- Windows PowerShell 5.1 or PowerShell 7+
- A real console host such as Windows Terminal or conhost. The PowerShell ISE is **not** supported.

## Usage

Download the script and run it from a PowerShell prompt:

```powershell
.\taskmanager.ps1
```

If script execution is blocked by your execution policy, either run it for this session only:

```powershell
powershell -ExecutionPolicy Bypass -File .\taskmanager.ps1
```

or unblock the downloaded file once:

```powershell
Unblock-File .\taskmanager.ps1
```

Run it as a normal user. Administrator rights are not needed (they only change which temperature sensors are visible).

## Controls

| Key | Action |
| --- | --- |
| `Tab` | Cycle through the tabs |
| `1` / `p` | Processes |
| `2` / `h` | CPU history per core |
| `3` / `d` | Disk activity |
| `4` / `n` | Network activity |
| `5` / `t` | Temperature sensors |
| `c` | Sort processes by CPU % |
| `m` | Sort processes by memory |
| `Up` / `Down` | Scroll one row |
| `PgUp` / `PgDn` | Scroll one page |
| `Home` | Jump to top |
| `q` / `Esc` | Quit |

## Temperature sensors

Windows has no built-in way to read most hardware temperatures without elevated rights, so the temperature tab tries several sources in order:

| Source | What it is | Notes |
| --- | --- | --- |
| `PERF` | Windows "Thermal Zone Information" performance counters | Often works without admin, but usually exposes only one or two ACPI zones, not individual CPU cores |
| `ACPI` | `MSAcpi_ThermalZoneTemperature` (WMI) | Usually needs admin. Only tried when `PERF` returns nothing, since it reports the same zones |
| `LHM` | [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) WMI provider | Used automatically while LibreHardwareMonitor is running |
| `OHM` | [OpenHardwareMonitor](https://openhardwaremonitor.org/) WMI provider | Used automatically while OpenHardwareMonitor is running |

For real CPU, GPU and disk temperatures, start LibreHardwareMonitor (as administrator) and leave it running in the background. Its sensors then show up in the tab on their own. If no source returns anything, the tab explains why instead of showing an empty list.

A source that fails is only retried every 15 samples, so a missing provider does not slow down the rest of the interface.

## Configuration

A few settings sit at the top of the script:

| Variable | Default | Meaning |
| --- | --- | --- |
| `$RefreshMs` | `1000` | Sample interval in milliseconds. History receives one sample per interval |
| `$HistoryLen` | `600` | Samples kept per series (600 = 10 minutes at 1 per second) |
| `$AvgWindow` | `60` | Samples used for the AVG column in the CPU history tab |
| `$UseUnicode` | `$true` | Set to `$false` for a plain ASCII sparkline (`. : - = + * # @`) |
| `$SortBy` | `'CPU'` | Initial process sort: `'CPU'` or `'Mem'` |

## How it works

- **Process CPU %**: two process snapshots are taken one interval apart. The difference in cumulative CPU seconds, divided by the elapsed time and the number of logical processors, gives a CPU % that is comparable to the total load shown in the header.
- **Per-core, disk, network and temperature data** come from `Get-CimInstance` on the `Win32_PerfFormattedData_*` classes (and the optional hardware monitor namespaces), which are locale independent.
- **Sparklines** are built from the Unicode block characters U+2581 to U+2588. The script file itself is pure ASCII; the characters are created from code points, so it survives any editor or encoding.
- The screen is redrawn in place without clearing, which avoids flicker. A key press redraws immediately without taking a new sample.

## Limitations

- Windows only (it relies on CIM/WMI).
- Per-process disk and network usage is not shown; the Disk and Network tabs are system-wide per device.
- No process control: you cannot end tasks or change priorities from this tool, by design.
- Temperature coverage depends entirely on what your hardware and drivers expose.

## License

Add the license of your choice here (for example MIT).
