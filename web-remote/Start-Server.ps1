$scriptDir = $PSScriptRoot
Set-Location $scriptDir

$nodeExe = "node.exe"
if (Test-Path "C:\Program Files\nodejs\node.exe") {
    $nodeExe = "C:\Program Files\nodejs\node.exe"
} elseif (Test-Path "C:\Program Files (x86)\nodejs\node.exe") {
    $nodeExe = "C:\Program Files (x86)\nodejs\node.exe"
}

$proc = Start-Process -FilePath $nodeExe -ArgumentList "server.js" -WorkingDirectory $scriptDir -WindowStyle Hidden -PassThru
Write-Host "Started DeskShift Web Remote with PID $($proc.Id)"
