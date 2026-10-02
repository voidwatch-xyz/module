@echo off
rem Voidwatch setup for Windows: copies the upload script, starts it now and at every login. No admin rights needed.
rem Drop the folder the game message showed onto this file to add a client that is not in the usual place.
setlocal
set "DEST=%LOCALAPPDATA%\Voidwatch"
mkdir "%DEST%" 2>nul
copy /Y "%~dp0upload\upload.ps1" "%DEST%\upload.ps1" >nul
if not "%~1"=="" echo %~1>>"%DEST%\folders.txt"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s = (New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Startup') + '\Voidwatch upload.lnk'); $s.TargetPath = 'powershell.exe'; $s.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"' + $env:LOCALAPPDATA + '\Voidwatch\upload.ps1\"'; $s.WindowStyle = 7; $s.Save()"
start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%DEST%\upload.ps1"
echo.
echo Voidwatch is set up. It runs in the background now and starts with Windows from now on.
echo Start the game and log in: a game message shows a code and a link.
echo.
pause
