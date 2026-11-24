Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
currentDir = fso.GetParentFolderName(WScript.ScriptFullName)
serverJs = fso.BuildPath(currentDir, "server.js")

nodePath = "node.exe"
If fso.FileExists("C:\Program Files\nodejs\node.exe") Then
    nodePath = "C:\Program Files\nodejs\node.exe"
ElseIf fso.FileExists("C:\Program Files (x86)\nodejs\node.exe") Then
    nodePath = "C:\Program Files (x86)\nodejs\node.exe"
End If

WshShell.CurrentDirectory = currentDir
WshShell.Run """" & nodePath & """ """ & serverJs & """", 0, False

