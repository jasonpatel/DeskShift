Dim objShell, fso, currentDir, psScript
Set objShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
currentDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = fso.BuildPath(currentDir, "scripts\DeskShift.ps1")
objShell.CurrentDirectory = currentDir
objShell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -NoProfile -File """ & psScript & """ -Tray", 0, False
Set objShell = Nothing
Set fso = Nothing
