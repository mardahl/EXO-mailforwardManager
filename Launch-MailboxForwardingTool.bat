@echo off
rem Removes the "downloaded from the internet" block (Mark of the Web) from
rem every file next to this launcher, then starts MailboxForwardingTool.ps1
rem with Windows PowerShell 5.1 (already on every supported Windows box).
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse | Unblock-File"
powershell.exe -Sta -NoProfile -ExecutionPolicy Bypass -File "%~dp0MailboxForwardingTool.ps1" %*
