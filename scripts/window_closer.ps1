<#
.SYNOPSIS
    Background monitor to automatically close (minimize to tray) application main windows.
.DESCRIPTION
    Polls running processes for target applications, identifies true top-level main windows,
    sends WM_CLOSE (0x0010) and SC_CLOSE, falls back to SW_MINIMIZE if needed, and supports
    custom target profiles (e.g. wait_process) to eliminate interference with manual operations.
#>

param(
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TargetsJsonBase64,
    [Parameter(Mandatory = $false)][int]$TimeoutSec = 300,
    [Parameter(Mandatory = $false)][string]$LogFile = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Early return if no targets provided
if ([string]::IsNullOrWhiteSpace($TargetsJsonBase64)) {
    exit 0
}

$targets = @()
try {
    $bytes = [System.Convert]::FromBase64String($TargetsJsonBase64)
    $json = [System.Text.Encoding]::UTF8.GetString($bytes)
    $parsed = ConvertFrom-Json -InputObject $json
    if ($null -ne $parsed) {
        $targets = @($parsed)
    }
} catch {
    exit 1
}

if ($targets.Count -eq 0) {
    exit 0
}

# Resolve log file path if not provided
if ([string]::IsNullOrWhiteSpace($LogFile)) {
    $scriptRoot = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
        $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    $LogFile = Join-Path -Path (Split-Path -Parent $scriptRoot) -ChildPath "launcher.log"
}

# Win32 API declaration
if (-not ([System.Management.Automation.PSTypeName]'Win32CloseHelper').Type) {
    Add-Type -TypeDefinition @"
    using System;
    using System.Collections.Generic;
    using System.Runtime.InteropServices;

    public class Win32CloseHelper {
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern IntPtr GetParent(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        public class WindowCandidate {
            public IntPtr HWnd;
            public uint ProcessId;
            public IntPtr Parent;
            public int Width;
            public int Height;
            public bool IsVisible;
            public bool IsIconic;
        }

        public static List<WindowCandidate> GetProcessWindows(uint targetProcessId) {
            var result = new List<WindowCandidate>();
            EnumWindows((hWnd, lParam) => {
                uint pid;
                GetWindowThreadProcessId(hWnd, out pid);
                if (pid != targetProcessId) {
                    return true;
                }

                RECT rect;
                GetWindowRect(hWnd, out rect);

                result.Add(new WindowCandidate {
                    HWnd = hWnd,
                    ProcessId = pid,
                    Parent = GetParent(hWnd),
                    Width = rect.Right - rect.Left,
                    Height = rect.Bottom - rect.Top,
                    IsVisible = IsWindowVisible(hWnd),
                    IsIconic = IsIconic(hWnd)
                });
                return true;
            }, IntPtr.Zero);

            return result;
        }
    }
"@
}

# Logging helper
function Write-CloserLog {
    param(
        [Parameter(Mandatory = $true)][string]$Result,
        [Parameter(Mandatory = $true)][string]$TargetName,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logLine = "[$timestamp] [AutoClose] [Normal] [$Result] ${TargetName}: $Message"

    [Console]::WriteLine($logLine)

    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        try {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::AppendAllText($LogFile, $logLine + "`r`n", $utf8NoBom)
        } catch {}
    }
}

$WM_CLOSE = 0x0010
$WM_SYSCOMMAND = 0x0112
$SC_CLOSE = 0xF060
$SW_MINIMIZE = 6

$pendingTargets = [System.Collections.ArrayList]::new()
foreach ($t in $targets) {
    if ($null -ne $t.PSObject.Properties['ProcessName'] -and (-not [string]::IsNullOrWhiteSpace($t.ProcessName))) {
        $waitProc = ""
        $multiStage = $false
        if ($null -ne $t.PSObject.Properties['Profile'] -and $null -ne $t.Profile) {
            if ($null -ne $t.Profile.PSObject.Properties['wait_process'] -and (-not [string]::IsNullOrWhiteSpace($t.Profile.wait_process))) {
                $waitProc = [string]$t.Profile.wait_process
            }
            if ($null -ne $t.Profile.PSObject.Properties['multi_stage']) {
                $multiStage = [bool]$t.Profile.multi_stage
            }
        }

        $pendingTargets.Add([PSCustomObject]@{
            TargetName             = [string]$t.TargetName
            ProcessName            = [string]$t.ProcessName
            WaitProcess            = $waitProc
            MultiStage             = $multiStage
            SentCount              = 0
            LastSentTime           = [datetime]::MinValue
            ProcessFirstSeenTime   = [datetime]::MinValue
            ConsecutiveHiddenTicks = 0
        }) | Out-Null
    }
}

if ($pendingTargets.Count -eq 0) {
    exit 0
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$timeoutMs = [int64]$TimeoutSec * 1000
$noWindowMaxWaitSec = 45

while ($true) {
    # Check completion
    if ($pendingTargets.Count -eq 0) {
        Write-CloserLog -Result "OK" -TargetName "AutoClose" -Message "すべての対象ウィンドウのクローズ要求が完了しました"
        break
    }

    # Check overall timeout
    if ($stopwatch.ElapsedMilliseconds -ge $timeoutMs) {
        $remainingNames = ($pendingTargets | ForEach-Object { $_.TargetName }) -join ", "
        Write-CloserLog -Result "Warn" -TargetName "AutoClose" -Message "ウィンドウ監視がタイムアウトしました (${TimeoutSec}秒経過, 未完了: $remainingNames)"
        break
    }

    $toRemove = [System.Collections.ArrayList]::new()

    foreach ($target in $pendingTargets) {
        $pName = [string]$target.ProcessName
        $procs = @(Get-Process -Name $pName -ErrorAction SilentlyContinue)

        if ($procs.Count -eq 0) {
            continue
        }

        if ($target.ProcessFirstSeenTime -eq [datetime]::MinValue) {
            $target.ProcessFirstSeenTime = Get-Date
        }

        # Check wait_process if specified in profile (e.g. LineMediaPlayer for LINE)
        if (-not [string]::IsNullOrWhiteSpace($target.WaitProcess)) {
            $gateProcs = @(Get-Process -Name $target.WaitProcess -ErrorAction SilentlyContinue)
            if ($gateProcs.Count -eq 0) {
                # Target process is running, but gate process is not yet ready (splash screen / init phase)
                continue
            }
        }

        # Collect all windows for all matching processes
        $allWindows = [System.Collections.ArrayList]::new()
        foreach ($proc in $procs) {
            $wins = [Win32CloseHelper]::GetProcessWindows([uint32]$proc.Id)
            foreach ($w in $wins) {
                $allWindows.Add($w) | Out-Null
            }
        }

        # Filter candidates: top-level (Parent == 0), visible, not iconic, reasonable size (>= 150x150)
        $visibleCandidates = @($allWindows | Where-Object {
            $_.Parent -eq [IntPtr]::Zero -and
            $_.IsVisible -eq $true -and
            $_.IsIconic -eq $false -and
            $_.Width -ge 150 -and
            $_.Height -ge 150
        })

        # Required hidden ticks: 8 ticks (4s) only if MultiStage is explicitly requested, else 1 tick (500ms immediate exit)
        $requiredTicks = if ($target.MultiStage) { 8 } else { 1 }

        # Check state
        if ($target.SentCount -gt 0) {
            if ($visibleCandidates.Count -eq 0) {
                $target.ConsecutiveHiddenTicks++
                if ($target.ConsecutiveHiddenTicks -ge $requiredTicks) {
                    $triggerMsg = if (-not [string]::IsNullOrWhiteSpace($target.WaitProcess)) {
                        "(Process: $pName, 検知トリガー: $($target.WaitProcess))"
                    } else {
                        "(Process: $pName)"
                    }
                    Write-CloserLog -Result "OK" -TargetName $target.TargetName -Message "ウィンドウのクローズ（トレイ格納/最小化）を確認しました $triggerMsg"
                    $toRemove.Add($target) | Out-Null
                    continue
                }
            } else {
                # Window is still visible
                $target.ConsecutiveHiddenTicks = 0

                $elapsedSinceLastSent = ((Get-Date) - $target.LastSentTime).TotalSeconds
                if ($elapsedSinceLastSent -ge 1.5) {
                    foreach ($cand in $visibleCandidates) {
                        [Win32CloseHelper]::PostMessage($cand.HWnd, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
                        [Win32CloseHelper]::PostMessage($cand.HWnd, $WM_SYSCOMMAND, [IntPtr]$SC_CLOSE, [IntPtr]::Zero) | Out-Null

                        if ($target.SentCount -ge 3) {
                            [Win32CloseHelper]::ShowWindow($cand.HWnd, $SW_MINIMIZE) | Out-Null
                        }
                    }

                    $target.SentCount++
                    $target.LastSentTime = Get-Date
                    $first = $visibleCandidates[0]
                    Write-CloserLog -Result "OK" -TargetName $target.TargetName -Message "メインウィンドウへクローズ要求を再送信しました (PID: $($first.ProcessId), 試行: $($target.SentCount)回目)"
                }
            }
        } else {
            # Initial detection: send close command to all visible candidate windows
            if ($visibleCandidates.Count -gt 0) {
                foreach ($cand in $visibleCandidates) {
                    [Win32CloseHelper]::PostMessage($cand.HWnd, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
                    [Win32CloseHelper]::PostMessage($cand.HWnd, $WM_SYSCOMMAND, [IntPtr]$SC_CLOSE, [IntPtr]::Zero) | Out-Null
                }
                $target.SentCount = 1
                $target.LastSentTime = Get-Date
                $first = $visibleCandidates[0]
                Write-CloserLog -Result "OK" -TargetName $target.TargetName -Message "メインウィンドウへのクローズ要求 (WM_CLOSE + SC_CLOSE) を送信しました (PID: $($first.ProcessId))"
            } else {
                # Process is running, but no visible window has appeared yet
                $elapsedRunning = ((Get-Date) - $target.ProcessFirstSeenTime).TotalSeconds
                if ($elapsedRunning -ge $noWindowMaxWaitSec) {
                    Write-CloserLog -Result "OK" -TargetName $target.TargetName -Message "稼働中ですが可視メインウィンドウが存在しないため（すでにトレイ格納済みかバックグラウンド動作）、監視を完了しました (Process: $pName)"
                    $toRemove.Add($target) | Out-Null
                }
            }
        }
    }

    foreach ($rem in $toRemove) {
        $pendingTargets.Remove($rem)
    }

    if ($pendingTargets.Count -gt 0) {
        Start-Sleep -Milliseconds 500
    }
}

exit 0
