@echo off
rem FLOW - installation sur une nouvelle machine (double-clic) ; install.cmd -Check verifie sans rien modifier
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %errorlevel%

