<#
.SYNOPSIS
    Unregisters the StartupFolderLauncher scheduled tasks.
.DESCRIPTION
    Checks if StartupFolderLauncher and StartupFolderLauncher_Unlock exist and deletes them.
#>

$taskNames = @("StartupFolderLauncher", "StartupFolderLauncher_Unlock")

foreach ($taskName in $taskNames) {
    Write-Host "タスク '$taskName' の登録状況を確認しています..." -ForegroundColor Cyan
    $null = & schtasks.exe /Query /TN $taskName 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "タスク '$taskName' を削除しています..." -ForegroundColor Cyan
        & schtasks.exe /Delete /TN $taskName /F
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[成功] タスク '$taskName' を削除しました。" -ForegroundColor Green
        } else {
            Write-Host "[エラー] タスク '$taskName' の削除に失敗しました (エラーコード: $LASTEXITCODE)。" -ForegroundColor Red
        }
    } else {
        Write-Host "[情報] タスク '$taskName' は登録されていません。" -ForegroundColor Yellow
    }
}

Write-Host "============================================================" -ForegroundColor Green
Write-Host "[完了] タスクの削除処理が終了しました。" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
