@echo off
rem FLOW — lanceur portable : double-clic depuis n'importe quel emplacement du dossier
where wt.exe >nul 2>nul
if %errorlevel%==0 (
  start "" wt.exe -w new --title FLOW pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0FLOW.ps1"
) else (
  start "" pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0FLOW.ps1"
)
