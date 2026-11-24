$scriptDir = Split-Path $PSScriptRoot
$scriptPath = Join-Path $PSScriptRoot "DeskShift.ps1"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = "-ExecutionPolicy Bypass -NoProfile -File `"$scriptPath`" -Tray"
$psi.WorkingDirectory = $scriptDir
$psi.UseShellExecute = $true
$psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
[System.Diagnostics.Process]::Start($psi) | Out-Null
Write-Host "DeskShift tray process launched via ShellExecute."
