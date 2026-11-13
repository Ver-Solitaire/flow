@echo off
rem FLOW - installation sur une nouvelle machine (double-clic)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
