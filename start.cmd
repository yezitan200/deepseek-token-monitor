@echo off
cd /d "%~dp0"
where node >nul 2>&1
if errorlevel 1 (
  echo 没有找到 node，请先安装 Node.js 并确保它在 PATH 里。
  pause
  exit /b 1
)
if not exist "data" mkdir "data"
echo 正在启动 token-monitor 代理…
start "token-monitor proxy" /min cmd /c "node proxy.js >> data\proxy.log 2>&1"
rem 用 ping 代替 timeout：timeout 在没有控制台输入的环境下会直接报错
ping -n 3 127.0.0.1 >nul
echo 正在启动桌面悬浮窗…
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0widget.ps1" -Port 8788
ping -n 2 127.0.0.1 >nul
echo.
echo 已启动：悬浮窗可拖动，按 Esc 或点右上角关闭。
echo 网页面板： http://127.0.0.1:8788/__dashboard
echo 停止代理： 运行 stop.cmd
ping -n 9 127.0.0.1 >nul