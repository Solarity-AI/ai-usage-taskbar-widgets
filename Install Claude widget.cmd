@echo off
rem Installs or updates the Claude usage widget for this Windows user (no admin rights needed).
rem Double-click this file in the unzipped folder. Running it again updates the widget and keeps your settings.
title Claude usage widget installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-usage-widget\install.ps1"
echo.
pause
