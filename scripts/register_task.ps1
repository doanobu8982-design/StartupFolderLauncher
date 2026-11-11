<#
.SYNOPSIS
    Registers the StartupFolderLauncher scheduled tasks.
.DESCRIPTION
    Generates Task Scheduler XML definitions for launcher.exe:
    - StartupFolderLauncher (LogonTrigger, no arguments)
    - StartupFolderLauncher_Unlock (SessionUnlock, argument: -IsUnlockTrigger)
    at HighestAvailable runlevel, and registers them using schtasks.exe.
#>

$ErrorActionPreference = "Stop"

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$rootDir = Split-Path -Path $scriptRoot -Parent
$launcherExePath = Join-Path -Path $rootDir -ChildPath "launcher.exe"

if (-not (Test-Path -LiteralPath $launcherExePath)) {
    Write-Host "[エラー] launcher.exe が見つかりません: $launcherExePath" -ForegroundColor Red
    exit 1
}

$tasks = @(
    @{
        Name        = "StartupFolderLauncher"
        Desc        = "High-performance startup launcher with admin privileges and watchdog (Logon)"
        TriggerXml  = "    <LogonTrigger>`r`n      <Enabled>true</Enabled>`r`n    </LogonTrigger>"
        ArgsXml     = ""
        TriggerDesc = "ログオン時 (最上位特権)"
    },
    @{
        Name        = "StartupFolderLauncher_Unlock"
        Desc        = "High-performance startup launcher with admin privileges and watchdog (Unlock)"
        TriggerXml  = "    <SessionStateChangeTrigger>`r`n      <StateChange>SessionUnlock</StateChange>`r`n      <Enabled>true</Enabled>`r`n    </SessionStateChangeTrigger>"
        ArgsXml     = "      <Arguments>-IsUnlockTrigger</Arguments>"
        TriggerDesc = "画面ロック解除時 (最上位特権)"
    }
)

$xmlPath = Join-Path $env:TEMP "StartupFolderLauncher_temp.xml"
$allSuccess = $true

try {
    foreach ($t in $tasks) {
        $xmlContent = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$($t.Desc)</Description>
  </RegistrationInfo>
  <Triggers>
$($t.TriggerXml)
  </Triggers>
  <Principals>
    <Principal id="Author">
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$launcherExePath</Command>
$($t.ArgsXml)
    </Exec>
  </Actions>
</Task>
"@
        # Write task definition in UTF-16 (Unicode) required by Task Scheduler
        [System.IO.File]::WriteAllText($xmlPath, $xmlContent, [System.Text.Encoding]::Unicode)

        Write-Host "タスク '$($t.Name)' を登録しています..." -ForegroundColor Cyan
        & schtasks.exe /Create /TN $t.Name /XML "$xmlPath" /F

        if ($LASTEXITCODE -eq 0) {
            Write-Host "[成功] タスク '$($t.Name)' が正常に登録されました ($($t.TriggerDesc))。" -ForegroundColor Green
        } else {
            Write-Host "[エラー] タスク '$($t.Name)' の登録に失敗しました (エラーコード: $LASTEXITCODE)。" -ForegroundColor Red
            $allSuccess = $false
        }
    }

    if ($allSuccess) {
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host "[完了] すべてのタスクが正常に登録されました。" -ForegroundColor Green
        Write-Host "実行対象: $launcherExePath (完全黒窓ゼロ)" -ForegroundColor Green
        Write-Host "============================================================" -ForegroundColor Green
    }
} catch {
    Write-Host "[例外エラー] タスク登録中にエラーが発生しました: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if (Test-Path -LiteralPath $xmlPath) {
        Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
    }
}
