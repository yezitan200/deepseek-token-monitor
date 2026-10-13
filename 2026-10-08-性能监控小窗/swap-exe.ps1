# 一次性脚本：把新编译的 token-monitor.new.exe 换成正式版，再重新打开启动器。
# 前提：先手动关掉启动器窗口（任务栏里那个），否则 exe 被占用、换不了。
# 用法：在本目录下双击本文件，或执行 .\swap-exe.ps1
# 想退回旧版：把 token-monitor.exe.before-monitor.bak 改名回 token-monitor.exe 即可。
# 说明：本文件必须带 UTF-8 BOM（PowerShell 5.1 会按 GBK 解无 BOM 的 UTF-8，中文会变乱码并报解析错）。

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$new = Join-Path $PSScriptRoot 'token-monitor.new.exe'
$dst = Join-Path $PSScriptRoot 'token-monitor.exe'

if (-not (Test-Path $new)) {
    Write-Host "找不到 token-monitor.new.exe —— 可能已经换过了。" -ForegroundColor Yellow
    exit 1
}

$open = Get-Process -Name 'token-monitor' -ErrorAction SilentlyContinue
if ($open) {
    Write-Host "启动器还开着（pid $($open.Id -join ',')）。请先关掉它的窗口，然后按回车继续..." -ForegroundColor Yellow
    Read-Host | Out-Null
}

$done = $false
for ($i = 0; $i -lt 20; $i++) {
    try {
        Copy-Item $new $dst -Force -ErrorAction Stop
        $done = $true
        break
    } catch {
        Start-Sleep -Milliseconds 500
    }
}

if (-not $done) {
    Write-Host "还是换不了：文件仍被占用。请确认启动器窗口已经关闭（不是最小化），再运行一次本脚本。" -ForegroundColor Red
    exit 1
}

Remove-Item $new -Force -ErrorAction SilentlyContinue
Write-Host "已替换 token-monitor.exe（旧版备份：token-monitor.exe.before-monitor.bak）" -ForegroundColor Green
Write-Host "重新打开启动器..."
Start-Process -FilePath $dst -WorkingDirectory $PSScriptRoot
Write-Host "完成。设置窗里现在有「API Key」和「性能监控」两个页签。" -ForegroundColor Green
Start-Sleep -Seconds 2
