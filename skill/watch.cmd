@echo off
rem agently-mail-watch control shim
rem   watch.cmd enable ^| disable ^| start ^| stop ^| status ^| logs [n] ^| run-once
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0watch.ps1" %*
