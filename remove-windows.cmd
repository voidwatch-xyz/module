@echo off
rem Removes the Voidwatch upload script from Windows: stops it, removes it from the startup items, deletes its files.
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*Voidwatch\upload.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Voidwatch upload.lnk" 2>nul
rmdir /S /Q "%LOCALAPPDATA%\Voidwatch" 2>nul
echo Voidwatch upload script removed. The module in your game client stays until you delete its folder.
pause
