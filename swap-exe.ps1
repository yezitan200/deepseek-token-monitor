# 一次性脚本：把新编译的 token-monitor.new.exe 换成正式版，重新签名，再把启动器打开。
# 用法（两步）：
#   1) 先关掉「token-monitor 启动器」窗口（任务栏里那个；关它不会影响悬浮窗和代理）
#   2) 在这个目录里右键本文件 → 「使用 PowerShell 运行」
# 想退回旧版：把 token-monitor.exe.before-settings-ui.bak 改名回 token-monitor.exe 即可。
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
Write-Host "已替换 token-monitor.exe（旧版备份：token-monitor.exe.before-settings-ui.bak）" -ForegroundColor Green

# 换完必须重新签名：新编译出来的 exe 是没有签名的，状态会从 Valid 掉成 NotSigned
Write-Host "重新签名..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'tools\sign-local.ps1')

Write-Host "重新打开启动器..."
Start-Process -FilePath $dst -WorkingDirectory $PSScriptRoot
Write-Host "完成。设置窗现在是「左侧导航 + 右侧卡片」的新样式（API Key / 性能监控）。" -ForegroundColor Green
Start-Sleep -Seconds 2
