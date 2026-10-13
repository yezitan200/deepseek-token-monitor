@echo off
setlocal enabledelayedexpansion
set "ROOT=%~dp0"
set "FOUND=0"

if exist "%ROOT%data\proxy.pid" (
  set /p PID=<"%ROOT%data\proxy.pid"
  echo 正在结束代理进程 PID=!PID!
  taskkill /F /PID !PID! >nul 2>&1
  del "%ROOT%data\proxy.pid" >nul 2>&1
  set "FOUND=1"
)

if exist "%ROOT%data\widget.pid" (
  set /p WPID=<"%ROOT%data\widget.pid"
  echo 正在关闭悬浮窗 PID=!WPID!
  taskkill /F /PID !WPID! >nul 2>&1
  del "%ROOT%data\widget.pid" >nul 2>&1
  set "FOUND=1"
)

if "!FOUND!"=="0" echo 没有找到运行中的代理或悬浮窗。
pause