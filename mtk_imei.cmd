@echo off
setlocal
%~d0
cd /d "%~dp0"

if not exist "bin\php.exe" (
    echo [-] Error: bin\php.exe not found in %~dp0bin!
    pause
    exit /b 1
)

bin\php.exe -d extension_dir="%~dp0bin" -c "%~dp0bin\php.ini" bin\mtk_imei.php
if errorlevel 1 (
    echo.
    echo [-] Execution failed with error code %errorlevel%.
)

echo.
pause
