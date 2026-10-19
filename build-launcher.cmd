@echo off
rem 重新编译 token-monitor.exe（改过 launcher\Launcher.cs 或 deepseek.ico 之后运行）
setlocal
cd /d "%~dp0"

set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%CSC%" (
  echo 找不到 C# 编译器 csc.exe，请确认系统里有 .NET Framework 4.x
  pause
  exit /b 1
)

echo 正在编译 token-monitor.exe ...
"%CSC%" /nologo /target:winexe /platform:anycpu /optimize+ ^
  /out:token-monitor.exe ^
  /win32icon:deepseek.ico ^
  /win32manifest:launcher\app.manifest ^
  /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll ^
  launcher\Launcher.cs

if errorlevel 1 (
  echo 编译失败
  pause
  exit /b 1
)
rem 编译后自动用本地证书签名（证书不存在会先创建，不需要管理员）
rem 清掉“来自网络”的标记，避免 SmartScreen 因来源不明而拦截
powershell -NoProfile -Command "Unblock-File -Path '%~dp0token-monitor.exe'" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\sign-local.ps1"

echo 编译完成：token-monitor.exe
echo.
echo 自检：
token-monitor.exe --check
pause
