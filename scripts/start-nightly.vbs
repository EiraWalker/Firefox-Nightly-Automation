Option Explicit

' Windows Script Host has no console. Hide PowerShell when creating it rather
' than waiting for PowerShell to interpret -WindowStyle after startup.
Dim shell, files, command, argument
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
command = QuotePath(shell.ExpandEnvironmentStrings("%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe")) _
    & " -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " _
    & QuotePath(files.BuildPath(files.GetParentFolderName(WScript.ScriptFullName), "start-nightly.ps1"))
For Each argument In WScript.Arguments
    Select Case LCase(argument)
        Case "-noactivate"
            command = command & " -NoActivate"
        Case "-osautostart"
            command = command & " -NoActivate -Arguments ""-os-autostart"""
        Case Else
            WScript.Quit 2
    End Select
Next
shell.Run command, 0, False

Function QuotePath(value)
    QuotePath = """" & value & """"
End Function
