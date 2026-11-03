' launch-v2.vbs - hidden launcher for the V2 workbench (C# / ASP.NET Core).
' Pure ASCII on purpose: WScript reads .vbs as ANSI.
' Resolves the project root from this file's own location, then starts
' screen-v2\scripts\run-windows.ps1 in a hidden console; that script builds
' and runs the app, which opens the browser at http://127.0.0.1:8788 itself.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
projRoot = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
runner = projRoot & "\screen-v2\scripts\run-windows.ps1"
If Not fso.FileExists(runner) Then
  MsgBox "screen-v2 is missing at:" & vbCrLf & projRoot & "\screen-v2" & vbCrLf & vbCrLf & "Clone the branch first:", vbExclamation, "Screen V2"
  WScript.Quit 1
End If
sh.CurrentDirectory = projRoot & "\screen-v2"
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & runner & """", 0, False
