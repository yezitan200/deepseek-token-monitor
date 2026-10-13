@echo off
rem ============================================================
rem  让本机信任 token-monitor：创建本地签名证书 -> 装进信任列表 -> 给程序签名
rem  需要管理员权限（会弹一次 UAC）
rem  想撤销：运行「取消本地信任.cmd」
rem ============================================================
setlocal
cd /d "%~dp0"

net session >nul 2>&1
if errorlevel 1 (
  echo 需要管理员权限。
  echo 请右键本文件，选择“以管理员身份运行”。
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\sign-local.ps1" -InstallTrust
echo.
echo 完成。以后重新编译程序后，再运行一次本脚本即可重新签名。
echo.
pause
