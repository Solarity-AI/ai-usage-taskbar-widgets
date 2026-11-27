@echo off
rem Installs or updates the Antigravity usage widget for this Windows user (no admin rights needed).
rem Double-click this file in the unzipped folder. Running it again updates the widget and keeps your settings.
rem Antigravity must be open for the widget to read its limits.
title Antigravity usage widget installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0antigravity-usage-widget\install.ps1"
echo.
pause
