@echo off
setlocal

set "OCES_GUI=%~dp0OpenClawEasySetup.Gui.ps1"
set "OCES_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%OCES_GUI%" (
  echo OpenClaw Easy Setup GUI file was not found.
  echo Expected: %OCES_GUI%
  pause
  exit /b 99
)

if not exist "%OCES_POWERSHELL%" (
  echo Windows PowerShell was not found at the trusted system path.
  pause
  exit /b 99
)

"%OCES_POWERSHELL%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%OCES_GUI%"
set "OCES_EXIT_CODE=%ERRORLEVEL%"

if not "%OCES_EXIT_CODE%"=="0" (
  echo.
  echo OpenClaw Easy Setup exited with code %OCES_EXIT_CODE%.
  pause
)

exit /b %OCES_EXIT_CODE%
