@echo off
rem FLOW - lanceur portable : double-clic depuis n'importe quel emplacement du dossier.
rem Verifie PowerShell 7 AVANT de lancer quoi que ce soit ; s'il manque, dit quoi faire.
rem (FLOW_NOPAUSE=1 : pas de pause, pour les tests)
set "PWSH=pwsh"
where pwsh >nul 2>nul
if not errorlevel 1 goto found
rem pas dans le PATH de cette fenetre (installation recente, ou fenetre ouverte avant) : emplacements habituels
set "PWSH="
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe" set "PWSH=%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"
if not defined PWSH goto nopwsh
:found
where wt.exe >nul 2>nul
if %errorlevel%==0 goto withwt
start "" "%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0FLOW.ps1"
exit /b 0
:withwt
start "" wt.exe -w new --title FLOW "%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0FLOW.ps1"
exit /b 0

:nopwsh
echo.
echo   PowerShell 7 est introuvable : FLOW ne peut pas demarrer.
echo   Double-clique sur install.cmd (dans le dossier FLOW) : il l'installe, avec le reste.
echo.
if not defined FLOW_NOPAUSE pause
exit /b 1
