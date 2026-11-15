Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
sh.Run "pwsh -Sta -NoProfile -ExecutionPolicy Bypass -File """ & base & "\wx-gui.ps1""", 0, False
