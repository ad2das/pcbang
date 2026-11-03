@echo off
rem PC-bang LoL latency kit: opens the kit window (downloads and checks the kit first).
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "[Net.ServicePointManager]::SecurityProtocol=3072; irm https://ad2das.github.io/pcbang/gui.ps1 | iex"
