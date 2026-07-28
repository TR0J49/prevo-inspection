@echo off
REM ====================================================================
REM  NSDL Compliance Audit - Windows installer launcher
REM  Double-click this file. It asks for Administrator rights itself.
REM ====================================================================

net session >nul 2>&1
if %errorlevel%==0 goto RUN

echo.
echo  Requesting Administrator rights...
echo  Click YES on the prompt that appears.
echo.
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:RUN
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-audit.ps1"
if %errorlevel% neq 0 (
  echo.
  echo  Setup did not finish. See the messages above.
  pause
)
