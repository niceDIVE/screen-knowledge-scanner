' launch-console.vbs — hidden launcher for the Screen Scanner web console.
' Pure ASCII on purpose: WScript reads .vbs as ANSI, so no Chinese literals here.
' The project path is resolved at runtime from this file's own location.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
projRoot = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
sh.CurrentDirectory = projRoot
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & projRoot & "\bin\start-web.ps1"""
sh.Run cmd, 0, False
