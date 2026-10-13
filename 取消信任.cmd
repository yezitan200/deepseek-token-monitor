@echo off
rem ============================================================
rem  撤销本机对 token-monitor 的信任：从信任列表移除证书
rem  需要管理员权限（会弹一次 UAC）
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

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$s='CN=token-monitor 本地自签名';" ^
  "$n=0;" ^
  "foreach ($store in 'Root','TrustedPublisher') {" ^
  "  $c=Get-ChildItem ('Cert:\LocalMachine\' + $store) -ErrorAction SilentlyContinue | Where-Object { $_.Subject -eq $s };" ^
  "  foreach ($x in $c) { & certutil.exe -delstore $store $x.Thumbprint | Out-Null; Write-Host ('已从本机 ' + $store + ' 移除 ' + $x.Thumbprint); $n++ } }" ^
  "if ($n -eq 0) { Write-Host '本机信任列表里没有它的证书' }"

echo.
echo 已撤销。重新启动程序时会恢复显示“无法识别的应用”。
echo.
pause
