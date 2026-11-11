<#
.SYNOPSIS
    High-performance startup launcher and watchdog for Windows.
.DESCRIPTION
    Launches applications from the unified 'スタートアップ' folder in configurable order
    (defined in config.json launch_order), dispatching each application to standard user
    privilege (via Shell.Application) or elevated privilege (direct execution) based on
    the run_as_admin setting. Includes Shell readiness check, mutex singleton control,
    and process watchdog checks. Compatible with PowerShell 5.1 and PowerShell 7+.
#>

param(
    [switch]$DryRun,
    [switch]$IsUnlockTrigger,
    [switch]$IsManual
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Define base paths
$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$startupDir = Join-Path -Path $scriptRoot -ChildPath "スタートアップ"
$configFile        = Join-Path -Path $scriptRoot -ChildPath "config.json"
$defaultConfigFile = Join-Path -Path $scriptRoot -ChildPath "config.default.json"
$logFile           = Join-Path -Path $scriptRoot -ChildPath "launcher.log"

# Determine trigger event name
$currentEvent = if ($IsUnlockTrigger) {
    "Unlock"
} elseif ($IsManual) {
    "Manual"
} elseif ($DryRun) {
    "DryRun"
} else {
    "Logon"
}

# Logging helper function (UTF-8 without BOM, with log rotation)
function Write-LauncherLog {
    param(
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)][string]$Privilege,
        [Parameter(Mandatory = $true)][string]$Result,
        [Parameter(Mandatory = $true)][string]$TargetName,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logLine = "[$timestamp] [$EventName] [$Privilege] [$Result] ${TargetName}: $Message"

    # Output to stdout
    [Console]::WriteLine($logLine)

    # Append to log file
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($logFile, $logLine + "`r`n", $utf8NoBom)
    } catch {
        [Console]::Error.WriteLine("Failed to write log: $($_.Exception.Message)")
        return
    }

    # Rotate log if needed
    Invoke-LauncherLogRotation
}

# Log rotation helper
function Invoke-LauncherLogRotation {
    if (-not (Test-Path -LiteralPath $logFile)) {
        return
    }

    $maxLines = 200
    if ($global:config -and $global:config.settings -and $global:config.settings.max_log_lines) {
        $maxLines = [int]$global:config.settings.max_log_lines
    }

    try {
        $lines = [System.IO.File]::ReadAllLines($logFile, [System.Text.Encoding]::UTF8)
        if ($lines.Length -gt $maxLines) {
            $trimmed = $lines[($lines.Length - $maxLines)..($lines.Length - 1)]
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllLines($logFile, $trimmed, $utf8NoBom)
        }
    } catch {
        # Suppress rotation errors to prevent blocking launcher execution
    }
}

# Load configuration with fallback defaults
function Get-LauncherConfig {
    $defaultConfig = [PSCustomObject]@{
        settings = [PSCustomObject]@{
            stagger_interval_ms = 500
            logon_check_shell   = $true
            shell_timeout_sec   = 30
            auto_close_timeout_sec = 300
            max_log_lines       = 200
            window_width        = 900
            window_height       = 550
            launch_order        = @()
        }
        overrides = @()
    }

    if (-not (Test-Path -LiteralPath $configFile)) {
        if (Test-Path -LiteralPath $defaultConfigFile) {
            try {
                Copy-Item -LiteralPath $defaultConfigFile -Destination $configFile -Force
            } catch {}
        }
        if (-not (Test-Path -LiteralPath $configFile)) {
            return $defaultConfig
        }
    }

    try {
        $rawJson = [System.IO.File]::ReadAllText($configFile, [System.Text.Encoding]::UTF8)
        $parsed = ConvertFrom-Json -InputObject $rawJson
        if ($null -eq $parsed) {
            return $defaultConfig
        }
        return $parsed
    } catch {
        Write-LauncherLog -EventName $currentEvent -Privilege "Normal" -Result "Warn" -TargetName "Config" -Message "config.json のパースに失敗したためデフォルト設定を使用します: $($_.Exception.Message)"
        return $defaultConfig
    }
}

$global:config = Get-LauncherConfig

# Mutex for singleton execution
$mutexName = "Global\StartupFolderLauncher_Mutex"
$mutex = $null
$hasHandle = $false

try {
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    try {
        $hasHandle = $mutex.WaitOne(0, $false)
    } catch [System.Threading.AbandonedMutexException] {
        $hasHandle = $true
    }

    if (-not $hasHandle) {
        Write-LauncherLog -EventName $currentEvent -Privilege "Normal" -Result "Skip" -TargetName "Launcher" -Message "排他制御により多重実行を抑止しました"
        exit 0
    }

    # Shell readiness check (only on Logon when enabled)
    $shouldCheckShell = ($currentEvent -eq "Logon") -and ($global:config.settings.logon_check_shell -eq $true)
    if ($shouldCheckShell) {
        if (-not ([System.Management.Automation.PSTypeName]'Win32FindWindow').Type) {
            Add-Type -TypeDefinition @"
            using System;
            using System.Runtime.InteropServices;
            public class Win32FindWindow {
                [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
                public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
            }
"@
        }

        $timeoutSec = if ($global:config.settings.shell_timeout_sec) { [int]$global:config.settings.shell_timeout_sec } else { 30 }
        $elapsed = 0
        $shellReady = $false

        while ($elapsed -lt $timeoutSec) {
            $hwnd = [Win32FindWindow]::FindWindow("Shell_TrayWnd", $null)
            if ($hwnd -ne [IntPtr]::Zero) {
                $shellReady = $true
                break
            }
            Start-Sleep -Seconds 1
            $elapsed++
        }

        if (-not $shellReady) {
            Write-LauncherLog -EventName $currentEvent -Privilege "Normal" -Result "Warn" -TargetName "Shell" -Message "タスクバー待機がタイムアウトしましたが処理を継続します"
        }
    }

    # Helper function to resolve target shortcut or binary
    function Resolve-TargetItem {
        param([System.IO.FileInfo]$File)

        $result = [PSCustomObject]@{
            ItemName         = $File.Name
            TargetPath       = $File.FullName
            Arguments        = ""
            WorkingDirectory = $File.DirectoryName
            IsValid          = $true
            ErrorMessage     = ""
        }

        if ($File.Extension -ieq ".lnk") {
            $wscript = $null
            $shortcut = $null
            try {
                $wscript = New-Object -ComObject WScript.Shell
                $shortcut = $wscript.CreateShortcut($File.FullName)
                $result.TargetPath = $shortcut.TargetPath
                $result.Arguments  = $shortcut.Arguments
                $result.WorkingDirectory = $shortcut.WorkingDirectory
            } catch {
                $result.IsValid = $false
                $result.ErrorMessage = "ショートカット情報の読み取りに失敗しました: $($_.Exception.Message)"
                return $result
            } finally {
                if ($null -ne $shortcut) {
                    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) | Out-Null
                }
                if ($null -ne $wscript) {
                    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wscript) | Out-Null
                }
            }
        }

        # Auto-complete working directory if missing
        if ([string]::IsNullOrWhiteSpace($result.WorkingDirectory) -and (-not [string]::IsNullOrWhiteSpace($result.TargetPath))) {
            $result.WorkingDirectory = [System.IO.Path]::GetDirectoryName($result.TargetPath)
        }

        # Validate existence of target entity
        if ([string]::IsNullOrWhiteSpace($result.TargetPath) -or (-not (Test-Path -LiteralPath $result.TargetPath))) {
            $result.IsValid = $false
            $result.ErrorMessage = "実体ファイルが存在しません: $($result.TargetPath)"
            return $result
        }

        return $result
    }

    # Helper to find override definition
    function Get-OverrideRule {
        param([string]$FileName, [string]$TargetPath)

        if (-not $global:config.overrides) {
            return $null
        }

        foreach ($ov in $global:config.overrides) {
            if (-not $ov.match_name) { continue }
            if ($FileName -like $ov.match_name -or ([System.IO.Path]::GetFileName($TargetPath)) -like $ov.match_name) {
                return $ov
            }
        }
        return $null
    }

    # Process items in unified startup directory
    function Invoke-StartupFolder {
        param(
            [string]$DirectoryPath
        )

        if (-not (Test-Path -LiteralPath $DirectoryPath)) {
            return
        }

        $supportedExtensions = @(".lnk", ".exe", ".bat", ".cmd")
        $allFiles = @(Get-ChildItem -LiteralPath $DirectoryPath -File -ErrorAction SilentlyContinue |
            Where-Object { $supportedExtensions -contains $_.Extension.ToLowerInvariant() })

        # Sort files by config.settings.launch_order
        $orderList = @()
        if ($global:config -and $global:config.settings -and $global:config.settings.launch_order) {
            $orderList = @($global:config.settings.launch_order)
        }

        $orderedFiles = [System.Collections.ArrayList]::new()
        $addedMap = @{}

        foreach ($orderName in $orderList) {
            $matched = $allFiles | Where-Object { $_.Name -ieq $orderName }
            foreach ($m in $matched) {
                if (-not $addedMap.ContainsKey($m.FullName.ToLowerInvariant())) {
                    $orderedFiles.Add($m) | Out-Null
                    $addedMap[$m.FullName.ToLowerInvariant()] = $true
                }
            }
        }

        $remainingFiles = $allFiles | Where-Object { -not $addedMap.ContainsKey($_.FullName.ToLowerInvariant()) } | Sort-Object Name
        foreach ($rem in $remainingFiles) {
            $orderedFiles.Add($rem) | Out-Null
        }

        $autoCloseTargets = New-Object System.Collections.Generic.List[psobject]

        foreach ($file in $orderedFiles) {
            # Check override definitions (match by file.Name first)
            $overrideRule = Get-OverrideRule -FileName $file.Name -TargetPath ""

            # If not matched by file name, try resolving target path to match target entity
            $resolved = $null
            if ($null -eq $overrideRule) {
                $resolved = Resolve-TargetItem -File $file
                if ($resolved.IsValid) {
                    $overrideRule = Get-OverrideRule -FileName $file.Name -TargetPath $resolved.TargetPath
                }
            }

            # 3.1 監視有効フラグの判定
            $isWatchEnabled = ($null -ne $overrideRule -and $overrideRule.enabled_watch -eq $true)
            $runAsAdmin = ($null -ne $overrideRule -and $overrideRule.run_as_admin -eq $true)
            $itemPrivilege = if ($runAsAdmin) { "Admin" } else { "Normal" }

            # 3.2 ロック解除トリガー（$IsUnlockTrigger）時の厳格ガード
            if ($IsUnlockTrigger) {
                if (-not $isWatchEnabled) {
                    # 監視が無効なアプリは、ロック解除時には一切何もしない（完全スキップ）
                    Write-LauncherLog -EventName $currentEvent -Privilege $itemPrivilege -Result "Skip" -TargetName $file.Name -Message "監視設定が無効(OFF)のためロック解除時はスキップ"
                    continue
                }
            }

            # If not resolved yet, resolve target item
            if ($null -eq $resolved) {
                $resolved = Resolve-TargetItem -File $file
            }

            if (-not $resolved.IsValid) {
                Write-LauncherLog -EventName $currentEvent -Privilege $itemPrivilege -Result "Error" -TargetName $file.Name -Message $resolved.ErrorMessage
                continue
            }

            $watchName = ""
            $finalArgs = $resolved.Arguments
            $isHidden = $false

            if ($null -ne $overrideRule) {
                if (-not [string]::IsNullOrWhiteSpace($overrideRule.watch_process_name)) {
                    $watchName = $overrideRule.watch_process_name
                }
                if ($null -ne $overrideRule.arguments) {
                    $finalArgs = $overrideRule.arguments
                }
                if ($null -ne $overrideRule.hidden) {
                    $isHidden = [bool]$overrideRule.hidden
                }
            }

            if ([string]::IsNullOrWhiteSpace($watchName)) {
                $watchName = [System.IO.Path]::GetFileNameWithoutExtension($resolved.TargetPath)
            }

            $isAutoClose = ($null -ne $overrideRule -and ($null -ne $overrideRule.PSObject.Properties['auto_close_window']) -and $overrideRule.auto_close_window -eq $true)
            $targetProfile = if ($null -ne $overrideRule -and ($null -ne $overrideRule.PSObject.Properties['auto_close_profile'])) {
                $overrideRule.auto_close_profile
            } else {
                $null
            }

            # Process watchdog check
            $runningProcesses = @(Get-Process -Name $watchName -ErrorAction SilentlyContinue)
            if ($runningProcesses.Count -gt 0) {
                $skipMsg = if ($DryRun) {
                    "すでに稼働中のためスキップ (シミュレーション, WatchProcess: $watchName)"
                } else {
                    "すでに稼働中のためスキップ (WatchProcess: $watchName)"
                }
                Write-LauncherLog -EventName $currentEvent -Privilege $itemPrivilege -Result "Skip" -TargetName $file.Name -Message $skipMsg

                continue
            }

            # Handle DryRun mode
            if ($DryRun) {
                Write-LauncherLog -EventName $currentEvent -Privilege $itemPrivilege -Result "OK" -TargetName $file.Name -Message "起動シミュレーション完了 (Target: $($resolved.TargetPath), Args: '$finalArgs', Hidden: $isHidden)"
                continue
            }

            # Launch process based on privilege
            if ($itemPrivilege -eq "Admin") {
                try {
                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName = $resolved.TargetPath
                    if (-not [string]::IsNullOrWhiteSpace($finalArgs)) {
                        $psi.Arguments = $finalArgs
                    }
                    if (-not [string]::IsNullOrWhiteSpace($resolved.WorkingDirectory) -and (Test-Path -LiteralPath $resolved.WorkingDirectory)) {
                        $psi.WorkingDirectory = $resolved.WorkingDirectory
                    }
                    if ($isHidden) {
                        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
                        $psi.CreateNoWindow = $true
                    }
                    [System.Diagnostics.Process]::Start($psi) | Out-Null
                    Write-LauncherLog -EventName $currentEvent -Privilege "Admin" -Result "OK" -TargetName $file.Name -Message "管理者権限で起動しました"

                    if ($isAutoClose) {
                        $autoCloseTargets.Add([PSCustomObject]@{
                            TargetName  = $file.Name
                            ProcessName = $watchName
                            Profile     = $targetProfile
                        })
                    }
                } catch {
                    Write-LauncherLog -EventName $currentEvent -Privilege "Admin" -Result "Error" -TargetName $file.Name -Message "管理者権限での起動に失敗しました: $($_.Exception.Message)"
                }
            } else {
                # Normal user privilege via Shell.Application
                $shellApp = $null
                try {
                    $shellApp = New-Object -ComObject Shell.Application
                    $vShow = if ($isHidden) { 0 } else { 1 }
                    $shellApp.ShellExecute($resolved.TargetPath, $finalArgs, $resolved.WorkingDirectory, "open", $vShow)
                    Write-LauncherLog -EventName $currentEvent -Privilege "Normal" -Result "OK" -TargetName $file.Name -Message "通常権限で起動しました"

                    if ($isAutoClose) {
                        $autoCloseTargets.Add([PSCustomObject]@{
                            TargetName  = $file.Name
                            ProcessName = $watchName
                            Profile     = $targetProfile
                        })
                    }
                } catch {
                    Write-LauncherLog -EventName $currentEvent -Privilege "Normal" -Result "Error" -TargetName $file.Name -Message "通常権限での起動に失敗しました: $($_.Exception.Message)"
                } finally {
                    if ($null -ne $shellApp) {
                        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shellApp) | Out-Null
                    }
                }
            }

            # Stagger interval delay
            $staggerMs = if ($global:config.settings.stagger_interval_ms) { [int]$global:config.settings.stagger_interval_ms } else { 500 }
            if ($staggerMs -gt 0) {
                Start-Sleep -Milliseconds $staggerMs
            }
        }

        # Trigger auto window closer if targets exist
        if ($autoCloseTargets.Count -gt 0 -and -not $DryRun) {
            $closerScript = Join-Path -Path $scriptRoot -ChildPath "scripts\window_closer.ps1"
            if (Test-Path -LiteralPath $closerScript) {
                $timeoutSec = if ($global:config.settings -and ($null -ne $global:config.settings.PSObject.Properties['auto_close_timeout_sec']) -and $global:config.settings.auto_close_timeout_sec) { [int]$global:config.settings.auto_close_timeout_sec } else { 300 }
                $jsonPayload = $autoCloseTargets | ConvertTo-Json -Compress
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonPayload)
                $base64Payload = [System.Convert]::ToBase64String($bytes)

                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "powershell.exe"
                $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$closerScript`" -TargetsJsonBase64 `"$base64Payload`" -TimeoutSec $timeoutSec -LogFile `"$logFile`""
                $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
                $psi.CreateNoWindow = $true
                $psi.UseShellExecute = $false
                [System.Diagnostics.Process]::Start($psi) | Out-Null

                Write-LauncherLog -EventName $currentEvent -Privilege "Normal" -Result "OK" -TargetName "AutoClose" -Message "ウィンドウ自動監視プロセスを非同期起動しました (対象: $($autoCloseTargets.Count)件)"
            } else {
                Write-LauncherLog -EventName $currentEvent -Privilege "Normal" -Result "Warn" -TargetName "AutoClose" -Message "window_closer.ps1 が見つからないため自動監視をスキップしました"
            }
        }
    }

    # Execute launches: unified Startup folder
    Invoke-StartupFolder -DirectoryPath $startupDir

} finally {
    if ($hasHandle -and ($null -ne $mutex)) {
        $mutex.ReleaseMutex()
    }
    if ($null -ne $mutex) {
        $mutex.Dispose()
    }
}

exit 0
