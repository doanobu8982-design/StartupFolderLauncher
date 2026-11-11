<#
.SYNOPSIS
    Status viewer and control panel for Startup Launcher.
.DESCRIPTION
    Provides a Windows Forms desktop GUI displaying registered items,
    their live process running status, latest log entries, quick action buttons,
    interactive watchdog toggle (ON/OFF), administrator privilege toggle,
    startup order reordering, double-buffered flicker-free rendering,
    2-second safe differential log monitoring, and a process picker dialog.
#>

# Singleton Execution Control (Prevent duplicate GUI instances)
$guiMutexName = "Global\StartupFolderLauncher_GUI_Mutex"
$guiWindowTitle = "スタートアップランチャー - ステータス管理"
$guiMutex = $null
$hasGuiMutex = $false

try {
    $guiMutex = New-Object System.Threading.Mutex($false, $guiMutexName)
    try {
        $hasGuiMutex = $guiMutex.WaitOne(0, $false)
    } catch [System.Threading.AbandonedMutexException] {
        $hasGuiMutex = $true
    }
} catch {
    try {
        $localMutexName = "StartupFolderLauncher_GUI_Mutex"
        $guiMutex = New-Object System.Threading.Mutex($false, $localMutexName)
        try {
            $hasGuiMutex = $guiMutex.WaitOne(0, $false)
        } catch [System.Threading.AbandonedMutexException] {
            $hasGuiMutex = $true
        }
    } catch {}
}

if (-not $hasGuiMutex) {
    if (-not ([System.Management.Automation.PSTypeName]'Win32GuiHelper').Type) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class Win32GuiHelper {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr lpdwProcessId);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    private static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    private const int SW_RESTORE = 9;
    private const uint SWP_FLAGS = 0x0001 | 0x0002 | 0x0040; // SWP_NOSIZE | SWP_NOMOVE | SWP_SHOWWINDOW

    public static void ForceActivateWindow(IntPtr hWnd) {
        if (hWnd == IntPtr.Zero) return;

        // 1. Restore minimized window
        ShowWindowAsync(hWnd, SW_RESTORE);

        // 2. Attach thread input to bypass Windows focus restrictions
        IntPtr foreWnd = GetForegroundWindow();
        uint foreThread = GetWindowThreadProcessId(foreWnd, IntPtr.Zero);
        uint curThread = GetCurrentThreadId();

        if (foreThread != 0 && foreThread != curThread) {
            AttachThreadInput(curThread, foreThread, true);
            SetForegroundWindow(hWnd);
            AttachThreadInput(curThread, foreThread, false);
        } else {
            SetForegroundWindow(hWnd);
        }

        // 3. Briefly bring to TopMost to pop above other windows, then revert TopMost
        SetWindowPos(hWnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_FLAGS);
        SetWindowPos(hWnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_FLAGS);
    }
}
"@
    }

    for ($i = 0; $i -lt 10; $i++) {
        $hWnd = [Win32GuiHelper]::FindWindow([string]$null, $guiWindowTitle)
        if ($hWnd -eq [IntPtr]::Zero) {
            $hWnd = [Win32GuiHelper]::FindWindow([string]$null, "スタートアップ 管理パネル")
        }
        if ($hWnd -ne [IntPtr]::Zero) {
            [Win32GuiHelper]::ForceActivateWindow($hWnd)
            break
        }
        Start-Sleep -Milliseconds 100
    }

    if ($null -ne $guiMutex) {
        $guiMutex.Dispose()
    }
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# Base paths
$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$startupDir        = Join-Path -Path $scriptRoot -ChildPath "スタートアップ"
$configFile        = Join-Path -Path $scriptRoot -ChildPath "config.json"
$defaultConfigFile = Join-Path -Path $scriptRoot -ChildPath "config.default.json"
$logFile           = Join-Path -Path $scriptRoot -ChildPath "launcher.log"
$launcherFile      = Join-Path -Path $scriptRoot -ChildPath "launcher.ps1"
$launcherExe       = Join-Path -Path $scriptRoot -ChildPath "launcher.exe"

# Load config
function Get-LocalConfig {
    if (-not (Test-Path -LiteralPath $configFile)) {
        if (Test-Path -LiteralPath $defaultConfigFile) {
            try {
                Copy-Item -LiteralPath $defaultConfigFile -Destination $configFile -Force
            } catch {}
        }
        if (-not (Test-Path -LiteralPath $configFile)) {
            return $null
        }
    }
    try {
        $raw = [System.IO.File]::ReadAllText($configFile, [System.Text.Encoding]::UTF8)
        $cfg = ConvertFrom-Json -InputObject $raw
        if ($null -ne $cfg -and $null -ne $cfg.overrides) {
            foreach ($ov in $cfg.overrides) {
                if ($null -eq $ov.PSObject.Properties['auto_close_window']) {
                    $ov | Add-Member -MemberType NoteProperty -Name 'auto_close_window' -Value $false -Force
                }
            }
        }
        return $cfg
    } catch {
        return $null
    }
}

# Save config
function Save-Config {
    param([object]$ConfigObj)
    try {
        $jsonStr = $ConfigObj | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($configFile, $jsonStr, [System.Text.Encoding]::UTF8)
        return $true
    } catch {
        [System.Windows.Forms.MessageBox]::Show("設定の保存に失敗しました: $($_.Exception.Message)", "エラー", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return $false
    }
}

# Update or insert an override rule in config.json
function Set-ItemConfig {
    param(
        [string]$FileName,
        [string]$TargetPath,
        [Nullable[bool]]$EnabledWatch,
        [Nullable[bool]]$RunAsAdmin,
        [string]$WatchProcessName,
        [Nullable[bool]]$AutoCloseWindow
    )

    $cfg = Get-LocalConfig
    if ($null -eq $cfg) {
        $cfg = [PSCustomObject]@{
            settings = [PSCustomObject]@{
                stagger_interval_ms    = 500
                logon_check_shell      = $true
                shell_timeout_sec      = 30
                auto_close_timeout_sec = 300
                max_log_lines          = 200
                window_width           = 900
                window_height          = 550
                launch_order           = @()
            }
            overrides = @()
        }
    }
    if ($null -eq $cfg.overrides) {
        $cfg.overrides = @()
    }

    $overridesList = [System.Collections.ArrayList]::new()
    $matched = $false
    foreach ($ov in $cfg.overrides) {
        if ($null -ne $ov.match_name -and ($FileName -like $ov.match_name -or ([System.IO.Path]::GetFileName($TargetPath)) -like $ov.match_name)) {
            if ($null -ne $EnabledWatch) {
                $ov.enabled_watch = [bool]$EnabledWatch
            }
            if ($null -ne $RunAsAdmin) {
                $ov.run_as_admin = [bool]$RunAsAdmin
            }
            if (-not [string]::IsNullOrWhiteSpace($WatchProcessName)) {
                $ov.watch_process_name = $WatchProcessName
            }
            if ($null -ne $AutoCloseWindow) {
                $val = [bool]$AutoCloseWindow
                if ($null -ne $ov.PSObject.Properties['auto_close_window']) {
                    $ov.auto_close_window = $val
                } else {
                    $ov | Add-Member -MemberType NoteProperty -Name 'auto_close_window' -Value $val -Force
                }
            }
            $matched = $true
        }
        $overridesList.Add($ov) | Out-Null
    }

    if (-not $matched) {
        $targetBase = [System.IO.Path]::GetFileNameWithoutExtension($TargetPath)
        $watchToUse = if (-not [string]::IsNullOrWhiteSpace($WatchProcessName)) { $WatchProcessName } else { $targetBase }
        $watchFlag = if ($null -ne $EnabledWatch) { [bool]$EnabledWatch } else { $false }
        $adminFlag = if ($null -ne $RunAsAdmin) { [bool]$RunAsAdmin } else { $false }
        $closeFlag = if ($null -ne $AutoCloseWindow) { [bool]$AutoCloseWindow } else { $false }
        $newRule = [PSCustomObject]@{
            match_name         = $FileName
            enabled_watch      = $watchFlag
            run_as_admin       = $adminFlag
            auto_close_window  = $closeFlag
            watch_process_name = $watchToUse
            arguments          = ""
            hidden             = $false
        }
        $overridesList.Add($newRule) | Out-Null
    }

    $cfg.overrides = $overridesList.ToArray()
    return Save-Config -ConfigObj $cfg
}

# Resolve target item details
function Resolve-ItemDetails {
    param(
        [System.IO.FileInfo]$File,
        [object]$Config
    )

    $targetPath = $File.FullName
    if ($File.Extension -ieq ".lnk") {
        $wscript = $null
        $shortcut = $null
        try {
            $wscript = New-Object -ComObject WScript.Shell
            $shortcut = $wscript.CreateShortcut($File.FullName)
            $targetPath = $shortcut.TargetPath
        } catch {
            $targetPath = "(ショートカット読み取りエラー)"
        } finally {
            if ($null -ne $shortcut) {
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) | Out-Null
            }
            if ($null -ne $wscript) {
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wscript) | Out-Null
            }
        }
    }

    $isWatch = $false
    $runAsAdmin = $false
    $autoCloseWindow = $false
    $watchName = ""
    if ($null -ne $Config -and $null -ne $Config.overrides) {
        foreach ($ov in $Config.overrides) {
            if ($File.Name -like $ov.match_name -or ([System.IO.Path]::GetFileName($targetPath)) -like $ov.match_name) {
                if ($null -ne $ov.enabled_watch) {
                    $isWatch = [bool]$ov.enabled_watch
                }
                if ($null -ne $ov.run_as_admin) {
                    $runAsAdmin = [bool]$ov.run_as_admin
                }
                if ($null -ne $ov.PSObject.Properties['auto_close_window'] -and $null -ne $ov.auto_close_window) {
                    $autoCloseWindow = [bool]$ov.auto_close_window
                }
                if (-not [string]::IsNullOrWhiteSpace($ov.watch_process_name)) {
                    $watchName = $ov.watch_process_name
                }
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($watchName) -and (-not [string]::IsNullOrWhiteSpace($targetPath))) {
        $watchName = [System.IO.Path]::GetFileNameWithoutExtension($targetPath)
    }

    $isRunning = $false
    if (-not [string]::IsNullOrWhiteSpace($watchName)) {
        $procs = @(Get-Process -Name $watchName -ErrorAction SilentlyContinue)
        $isRunning = ($procs.Count -gt 0)
    }

    return [PSCustomObject]@{
        FileName        = $File.Name
        TargetPath      = $targetPath
        EnabledWatch    = $isWatch
        RunAsAdmin      = $runAsAdmin
        AutoCloseWindow = $autoCloseWindow
        WatchProcess    = $watchName
        IsRunning       = $isRunning
    }
}

# Modal dialog to choose or input a process name
function Show-ProcessPickerDialog {
    param(
        [string]$TargetFileName,
        [string]$CurrentWatchProcess,
        [string]$TargetPath
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "監視プロセスの変更"
    $dialog.Size = New-Object System.Drawing.Size(460, 540)
    $dialog.MinimumSize = New-Object System.Drawing.Size(400, 450)
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.Padding = New-Object System.Windows.Forms.Padding(12)
    $layout.RowCount = 6
    $layout.ColumnCount = 1
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30))) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 24))) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32))) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 24))) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 45))) | Out-Null
    $dialog.Controls.Add($layout)

    # Label: Target Application
    $lblApp = New-Object System.Windows.Forms.Label
    $lblApp.Text = "対象アプリ: $TargetFileName"
    $lblApp.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $lblApp.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lblApp.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $layout.Controls.Add($lblApp, 0, 0)

    # Label: Input Prompt
    $lblPrompt = New-Object System.Windows.Forms.Label
    $lblPrompt.Text = "監視するプロセス名 (拡張子なし):"
    $lblPrompt.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lblPrompt.TextAlign = [System.Drawing.ContentAlignment]::BottomLeft
    $layout.Controls.Add($lblPrompt, 0, 1)

    # TextBox: Direct input
    $txtInput = New-Object System.Windows.Forms.TextBox
    $txtInput.Text = $CurrentWatchProcess
    $txtInput.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.Controls.Add($txtInput, 0, 2)

    # Label: List Prompt
    $lblListPrompt = New-Object System.Windows.Forms.Label
    $lblListPrompt.Text = "実行中プロセス一覧 (選択またはダブルクリックで反映):"
    $lblListPrompt.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lblListPrompt.TextAlign = [System.Drawing.ContentAlignment]::BottomLeft
    $layout.Controls.Add($lblListPrompt, 0, 3)

    # ListBox: Running processes
    $listBox = New-Object System.Windows.Forms.ListBox
    $listBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $listBox.IntegralHeight = $false

    # Fetch running processes (access denied safe)
    $procList = Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            ($null -ne $_.MainWindowTitle -and $_.MainWindowTitle -ne "") -or
            ($_.ProcessName -notmatch '^(svchost|csrss|conhost|explorer|powershell)$')
        } |
        Select-Object -ExpandProperty ProcessName -Unique |
        Sort-Object

    foreach ($p in $procList) {
        $listBox.Items.Add($p) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($CurrentWatchProcess)) {
        $listBox.SelectedItem = $CurrentWatchProcess
    }

    $listBox.Add_SelectedIndexChanged({
        if ($null -ne $listBox.SelectedItem) {
            $txtInput.Text = $listBox.SelectedItem.ToString()
        }
    })
    $listBox.Add_DoubleClick({
        if ($null -ne $listBox.SelectedItem) {
            $txtInput.Text = $listBox.SelectedItem.ToString()
        }
    })
    $layout.Controls.Add($listBox, 0, 4)

    # Buttons FlowPanel
    $btnFlow = New-Object System.Windows.Forms.FlowLayoutPanel
    $btnFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
    $btnFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $btnFlow.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)

    $btnDlgCancel = New-Object System.Windows.Forms.Button
    $btnDlgCancel.Text = "キャンセル"
    $btnDlgCancel.Size = New-Object System.Drawing.Size(90, 32)
    $btnDlgCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $btnDlgSave = New-Object System.Windows.Forms.Button
    $btnDlgSave.Text = "保存"
    $btnDlgSave.Size = New-Object System.Drawing.Size(90, 32)
    $btnDlgSave.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)

    $btnDlgSave.Add_Click({
        $newProcName = $txtInput.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($newProcName)) {
            [System.Windows.Forms.MessageBox]::Show("プロセス名を入力するか、一覧から選択してください。", "入力確認", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        $saved = Set-ItemConfig -FileName $TargetFileName -TargetPath $TargetPath -WatchProcessName $newProcName
        if ($saved) {
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }
    })

    $btnFlow.Controls.Add($btnDlgCancel)
    $btnFlow.Controls.Add($btnDlgSave)
    $layout.Controls.Add($btnFlow, 0, 5)

    return $dialog.ShowDialog()
}

# Main Window Initialization with Saved Window Dimensions
$cfgInitial = Get-LocalConfig
$initWidth = 900
$initHeight = 550
if ($null -ne $cfgInitial -and $null -ne $cfgInitial.settings) {
    if ($cfgInitial.settings.window_width -and [int]$cfgInitial.settings.window_width -ge 860) {
        $initWidth = [int]$cfgInitial.settings.window_width
    }
    if ($cfgInitial.settings.window_height -and [int]$cfgInitial.settings.window_height -ge 500) {
        $initHeight = [int]$cfgInitial.settings.window_height
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = $guiWindowTitle
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.MinimumSize = New-Object System.Drawing.Size(860, 500)
$form.Size = New-Object System.Drawing.Size($initWidth, $initHeight)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

# Save Window Dimensions on Closing
$form.Add_FormClosing({
    param($s, $e)
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) {
        $w = [Math]::Max(860, $form.Width)
        $h = [Math]::Max(500, $form.Height)
        $c = Get-LocalConfig
        if ($null -ne $c) {
            if ($null -eq $c.settings) {
                $c.settings = [PSCustomObject]@{}
            }
            $c.settings.window_width = $w
            $c.settings.window_height = $h
            Save-Config -ConfigObj $c | Out-Null
        }
    }
})

# Layout Panels
$mainTable = New-Object System.Windows.Forms.TableLayoutPanel
$mainTable.Dock = [System.Windows.Forms.DockStyle]::Fill
$mainTable.RowCount = 4
$mainTable.ColumnCount = 1
$mainTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40))) | Out-Null
$mainTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 55))) | Out-Null
$mainTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 45))) | Out-Null
$mainTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 55))) | Out-Null
$form.Controls.Add($mainTable)

# Header Label
$headerLabel = New-Object System.Windows.Forms.Label
$headerLabel.Text = "登録アプリ一覧と稼働状況"
$headerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$headerLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$headerLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$headerLabel.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
$mainTable.Controls.Add($headerLabel, 0, 0)

# DataGridView for items
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = [System.Windows.Forms.DockStyle]::Fill
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.ReadOnly = $false
$grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$grid.MultiSelect = $false
$grid.RowHeadersVisible = $false
$grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None
$grid.BackgroundColor = [System.Drawing.Color]::White

# Double-buffering to eliminate grid flickering
$prop = [System.Windows.Forms.Control].GetProperty("DoubleBuffered", [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance)
if ($null -ne $prop) {
    $prop.SetValue($grid, $true, $null)
}

# Col 0: 順序 (Text, Width: 45, ReadOnly, MiddleCenter)
$colOrder = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colOrder.HeaderText = "順序"
$colOrder.Width = 45
$colOrder.ReadOnly = $true
$colOrder.DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleCenter
$grid.Columns.Add($colOrder) | Out-Null

# Col 1: 監視 (Checkbox, Width: 50, ReadOnly=False)
$colWatchCheck = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colWatchCheck.HeaderText = "監視"
$colWatchCheck.Width = 50
$colWatchCheck.ReadOnly = $false
$colWatchCheck.Resizable = [System.Windows.Forms.DataGridViewTriState]::False
$grid.Columns.Add($colWatchCheck) | Out-Null

# Col 2: 管理者 (Checkbox, Width: 65, ReadOnly=False)
$colAdminCheck = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colAdminCheck.HeaderText = "管理者"
$colAdminCheck.Width = 65
$colAdminCheck.ReadOnly = $false
$colAdminCheck.Resizable = [System.Windows.Forms.DataGridViewTriState]::False
$grid.Columns.Add($colAdminCheck) | Out-Null

# Col 3: 窓閉じ (Checkbox, Width: 55, ReadOnly=False)
$colCloseCheck = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colCloseCheck.HeaderText = "窓閉じ"
$colCloseCheck.Width = 55
$colCloseCheck.ReadOnly = $false
$colCloseCheck.Resizable = [System.Windows.Forms.DataGridViewTriState]::False
$grid.Columns.Add($colCloseCheck) | Out-Null

# Col 4: ファイル名 (Text, Width: 180, ReadOnly)
$colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colName.HeaderText = "ファイル名"
$colName.Width = 180
$colName.ReadOnly = $true
$grid.Columns.Add($colName) | Out-Null

# Col 5: 状態 (Text, Width: 120, ReadOnly)
$colStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colStatus.HeaderText = "状態"
$colStatus.Width = 120
$colStatus.ReadOnly = $true
$grid.Columns.Add($colStatus) | Out-Null

# Col 6: 監視プロセス (Text, Width: 130, ReadOnly)
$colWatch = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colWatch.HeaderText = "監視プロセス"
$colWatch.Width = 130
$colWatch.ReadOnly = $true
$grid.Columns.Add($colWatch) | Out-Null

# Col 7: 実体パス (Text, Width: 280, ReadOnly)
$colPath = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colPath.HeaderText = "実体パス"
$colPath.Width = 280
$colPath.ReadOnly = $true
$grid.Columns.Add($colPath) | Out-Null

$mainTable.Controls.Add($grid, 0, 1)

# Middle Panel: Log Box
$logGroup = New-Object System.Windows.Forms.GroupBox
$logGroup.Text = "最新実行ログ"
$logGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
$logGroup.Padding = New-Object System.Windows.Forms.Padding(8)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$logBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$logBox.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 250)
$logBox.WordWrap = $false
$logGroup.Controls.Add($logBox)

$mainTable.Controls.Add($logGroup, 0, 2)

# Bottom Button Panel
$buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$buttonPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$buttonPanel.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)

$btnReload = New-Object System.Windows.Forms.Button
$btnReload.Text = "再読み込み"
$btnReload.Size = New-Object System.Drawing.Size(100, 36)
$btnReload.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)

$btnOpenFolder = New-Object System.Windows.Forms.Button
$btnOpenFolder.Text = "スタートアップを開く"
$btnOpenFolder.Size = New-Object System.Drawing.Size(155, 36)
$btnOpenFolder.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)

$btnMoveUp = New-Object System.Windows.Forms.Button
$btnMoveUp.Text = "▲ 上へ"
$btnMoveUp.Size = New-Object System.Drawing.Size(80, 36)
$btnMoveUp.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)

$btnMoveDown = New-Object System.Windows.Forms.Button
$btnMoveDown.Text = "▼ 下へ"
$btnMoveDown.Size = New-Object System.Drawing.Size(80, 36)
$btnMoveDown.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)

$btnEditWatch = New-Object System.Windows.Forms.Button
$btnEditWatch.Text = "監視プロセス変更"
$btnEditWatch.Size = New-Object System.Drawing.Size(135, 36)
$btnEditWatch.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)

$btnSyncNow = New-Object System.Windows.Forms.Button
$btnSyncNow.Text = "スタートアップ実行"
$btnSyncNow.Size = New-Object System.Drawing.Size(135, 36)
$btnSyncNow.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)

$buttonPanel.Controls.Add($btnReload)
$buttonPanel.Controls.Add($btnOpenFolder)
$buttonPanel.Controls.Add($btnMoveUp)
$buttonPanel.Controls.Add($btnMoveDown)
$buttonPanel.Controls.Add($btnEditWatch)
$buttonPanel.Controls.Add($btnSyncNow)

$mainTable.Controls.Add($buttonPanel, 0, 3)

# Data Refresh Function
$script:isLoading = $false
$script:lastLogLength = 0

$refreshData = {
    $script:isLoading = $true
    $grid.SuspendLayout()
    try {
        $cfg = Get-LocalConfig
        $grid.Rows.Clear()

        $supportedExts = @(".lnk", ".exe", ".bat", ".cmd")

        if (Test-Path -LiteralPath $startupDir) {
            $allFiles = @(Get-ChildItem -LiteralPath $startupDir -File -ErrorAction SilentlyContinue |
                Where-Object { $supportedExts -contains $_.Extension.ToLowerInvariant() })

            $orderList = @()
            if ($null -ne $cfg -and $null -ne $cfg.settings -and $null -ne $cfg.settings.launch_order) {
                $orderList = @($cfg.settings.launch_order)
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

            $idxCounter = 1
            foreach ($f in $orderedFiles) {
                $info = Resolve-ItemDetails -File $f -Config $cfg
                $displayFileName = if ($info.FileName -match '\.lnk$') {
                    [System.IO.Path]::GetFileNameWithoutExtension($info.FileName)
                } else {
                    $info.FileName
                }

                $rowIndex = $grid.Rows.Add(
                    $idxCounter.ToString(),
                    $info.EnabledWatch,
                    $info.RunAsAdmin,
                    $info.AutoCloseWindow,
                    $displayFileName,
                    $(if ($info.IsRunning) { "🟢 稼働中" } else { "⚪ 停止中" }),
                    $info.WatchProcess,
                    $info.TargetPath
                )
                $row = $grid.Rows[$rowIndex]
                $row.Tag = $info.FileName
                if ($info.IsRunning) {
                    $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::DarkGreen
                } else {
                    $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
                }
                $idxCounter++
            }
        }

        # Refresh log preview (latest 30 lines) and track log file length
        if (Test-Path -LiteralPath $logFile) {
            try {
                $lines = [System.IO.File]::ReadAllLines($logFile, [System.Text.Encoding]::UTF8)
                $count = $lines.Length
                $start = [Math]::Max(0, $count - 30)
                $latest = $lines[$start..($count - 1)]
                $logBox.Text = [string]::Join("`r`n", $latest)
                if ($logBox.Text.Length -gt 0) {
                    $logBox.AppendText("`r`n")
                }
                $logBox.SelectionStart = $logBox.TextLength
                $logBox.SelectionLength = 0
                $logBox.ScrollToCaret()

                $fi = New-Object System.IO.FileInfo($logFile)
                $script:lastLogLength = $fi.Length
            } catch {
                $logBox.Text = "ログ読み込みエラー: $($_.Exception.Message)"
            }
        } else {
            $logBox.Text = "（ログファイルはまだ生成されていません）"
            $script:lastLogLength = 0
        }
    } finally {
        $grid.ResumeLayout()
        $script:isLoading = $false
    }
}

# Differential Log Monitoring Function (Timer-driven)
$updateLogDiff = {
    if (-not (Test-Path -LiteralPath $logFile)) {
        return
    }

    try {
        $fileInfo = New-Object System.IO.FileInfo($logFile)
        $currentLength = $fileInfo.Length

        # If log was rotated or truncated
        if ($currentLength -lt $script:lastLogLength) {
            $script:lastLogLength = 0
            $logBox.Clear()
        }

        if ($currentLength -gt $script:lastLogLength) {
            $fs = [System.IO.File]::Open($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $fs.Seek($script:lastLogLength, [System.IO.SeekOrigin]::Begin) | Out-Null
                $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                $diffText = $reader.ReadToEnd()
                if (-not [string]::IsNullOrEmpty($diffText)) {
                    $logBox.AppendText($diffText)
                    $logBox.SelectionStart = $logBox.TextLength
                    $logBox.SelectionLength = 0
                    $logBox.ScrollToCaret()
                }
                $script:lastLogLength = $fs.Position
            } finally {
                $fs.Close()
                $fs.Dispose()
            }
        }
    } catch {
        # Suppress read/sharing exceptions safely
    }
}

# 2-second safe differential log monitoring timer
$logTimer = New-Object System.Windows.Forms.Timer
$logTimer.Interval = 2000
$logTimer.Add_Tick({
    & $updateLogDiff
})

# Grid Checkbox Auto-Commit and Event Handling
$grid.Add_CurrentCellDirtyStateChanged({
    if ($grid.IsCurrentCellDirty -and ($grid.CurrentCell.ColumnIndex -in 1, 2, 3)) {
        $grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
    }
})

$grid.Add_CellValueChanged({
    param($s, $e)
    if ($script:isLoading) { return }
    if ($e.RowIndex -lt 0) { return }

    $row = $grid.Rows[$e.RowIndex]
    $fn = if ($null -ne $row.Tag -and [string]$row.Tag -ne "") { [string]$row.Tag } else { [string]$row.Cells[4].Value }
    $tp = [string]$row.Cells[7].Value

    if ($e.ColumnIndex -eq 1) {
        $newChecked = [bool]$row.Cells[1].Value
        Set-ItemConfig -FileName $fn -TargetPath $tp -EnabledWatch $newChecked | Out-Null
    } elseif ($e.ColumnIndex -eq 2) {
        $newAdmin = [bool]$row.Cells[2].Value
        Set-ItemConfig -FileName $fn -TargetPath $tp -RunAsAdmin $newAdmin | Out-Null
    } elseif ($e.ColumnIndex -eq 3) {
        $newClose = [bool]$row.Cells[3].Value
        Set-ItemConfig -FileName $fn -TargetPath $tp -AutoCloseWindow $newClose | Out-Null
    }
})

# Helper function to save current grid order to config.json
$saveCurrentOrder = {
    $newOrder = @()
    for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
        $r = $grid.Rows[$i]
        $r.Cells[0].Value = ($i + 1).ToString()
        $fn = if ($null -ne $r.Tag -and [string]$r.Tag -ne "") { [string]$r.Tag } else { [string]$r.Cells[4].Value }
        $newOrder += $fn
    }

    $c = Get-LocalConfig
    if ($null -ne $c) {
        if ($null -eq $c.settings) {
            $c.settings = [PSCustomObject]@{}
        }
        $c.settings.launch_order = $newOrder
        Save-Config -ConfigObj $c | Out-Null
    }
}

# Button Click Handlers
$btnReload.Add_Click({
    & $refreshData
})

$btnOpenFolder.Add_Click({
    if (-not (Test-Path -LiteralPath $startupDir)) {
        [System.IO.Directory]::CreateDirectory($startupDir) | Out-Null
    }
    [System.Diagnostics.Process]::Start("explorer.exe", "`"$startupDir`"") | Out-Null
})

$btnMoveUp.Add_Click({
    if ($grid.SelectedRows.Count -eq 0) { return }
    $idx = $grid.SelectedRows[0].Index
    if ($idx -le 0) { return }

    $row = $grid.Rows[$idx]
    $grid.Rows.RemoveAt($idx)
    $grid.Rows.Insert($idx - 1, $row)
    $grid.ClearSelection()
    $grid.Rows[$idx - 1].Selected = $true
    $grid.CurrentCell = $grid.Rows[$idx - 1].Cells[0]

    & $saveCurrentOrder
})

$btnMoveDown.Add_Click({
    if ($grid.SelectedRows.Count -eq 0) { return }
    $idx = $grid.SelectedRows[0].Index
    if ($idx -ge $grid.Rows.Count - 1) { return }

    $row = $grid.Rows[$idx]
    $grid.Rows.RemoveAt($idx)
    $grid.Rows.Insert($idx + 1, $row)
    $grid.ClearSelection()
    $grid.Rows[$idx + 1].Selected = $true
    $grid.CurrentCell = $grid.Rows[$idx + 1].Cells[0]

    & $saveCurrentOrder
})

$btnEditWatch.Add_Click({
    if ($grid.SelectedRows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("監視プロセスを変更したいアプリの行を選択してください。", "情報", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    $selRow = $grid.SelectedRows[0]
    $selFileName = if ($null -ne $selRow.Tag -and [string]$selRow.Tag -ne "") { [string]$selRow.Tag } else { [string]$selRow.Cells[4].Value }
    $selWatchName = [string]$selRow.Cells[6].Value
    $selTargetPath = [string]$selRow.Cells[7].Value

    $dlgRes = Show-ProcessPickerDialog -TargetFileName $selFileName -CurrentWatchProcess $selWatchName -TargetPath $selTargetPath
    if ($dlgRes -eq [System.Windows.Forms.DialogResult]::OK) {
        & $refreshData
    }
})

$btnSyncNow.Add_Click({
    try {
        if (Test-Path -LiteralPath $launcherExe) {
            [System.Diagnostics.Process]::Start($launcherExe, "-IsManual") | Out-Null
        } else {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "powershell.exe"
            $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherFile`" -IsManual"
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            [System.Diagnostics.Process]::Start($psi) | Out-Null
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("スタートアップ実行の開始に失敗しました: $($_.Exception.Message)", "エラー", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})

# Initial Data Load and Start Timer
$form.Add_Shown({
    & $refreshData
    $logTimer.Start()
})

# Cleanup on form exit
$form.Add_FormClosed({
    param($s, $e)
    if ($null -ne $logTimer) {
        $logTimer.Stop()
        $logTimer.Dispose()
    }
})

try {
    [System.Windows.Forms.Application]::Run($form)
} finally {
    if ($hasGuiMutex -and ($null -ne $guiMutex)) {
        try {
            $guiMutex.ReleaseMutex()
        } catch {}
    }
    if ($null -ne $guiMutex) {
        try {
            $guiMutex.Dispose()
        } catch {}
    }
}
