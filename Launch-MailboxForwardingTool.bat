@echo off
rem Removes the "downloaded from the internet" block (Mark of the Web) from
rem every file next to this launcher, then starts MailboxForwardingTool.ps1
rem with Windows PowerShell 5.1 (already on every supported Windows box).
setlocal
rem Console closes when the script exits, erasing log output - tell the
rem script to pause before the window disappears (inherited by relaunches).
set EXOMFT_PAUSE_ON_EXIT=1
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse | Unblock-File"
powershell.exe -Sta -NoProfile -ExecutionPolicy Bypass -File "%~dp0MailboxForwardingTool.ps1" %*
