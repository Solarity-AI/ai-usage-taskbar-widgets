@echo off
rem Installs or updates the Codex usage widget for this Windows user (no admin rights needed).
rem Double-click this file in the unzipped folder. Running it again updates the widget and keeps your settings.
title Codex usage widget installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-usage-widget\install.ps1"
echo.
pause
