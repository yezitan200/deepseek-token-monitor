<#
  本地代码签名（自签名证书方案）
  ---------------------------------------------------------------
  -InstallTrust : 把证书装进本机"受信任的根"和"受信任的发布者"（需要管理员）
                  装完后 Windows 会认这个发布者，不再显示"无法识别的应用"
  不带参数      : 只签名（证书不存在就创建），不需要管理员
#>
param(
  [switch]$InstallTrust
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $root 'token-monitor.exe'))) { $root = $PSScriptRoot }

$subject = 'CN=token-monitor 本地自签名'
$friendly = 'token-monitor 本地代码签名'
$cerPath = Join-Path $root 'token-monitor-codesign.cer'
$exe = Join-Path $root 'token-monitor.exe'
$widget = Join-Path $root 'widget.ps1'

Write-Host '=== 1) 查找或创建代码签名证书 ===' -ForegroundColor Cyan
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $subject } | Select-Object -First 1
if ($cert) {
  Write-Host ("  已有证书: " + $cert.Thumbprint)
} else {
  $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject `
            -FriendlyName $friendly -CertStoreLocation Cert:\CurrentUser\My `
            -NotAfter (Get-Date).AddYears(5) -KeyUsage DigitalSignature `
            -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3')
  Write-Host ("  已创建证书: " + $cert.Thumbprint)
}

if ($InstallTrust) {
  Write-Host '=== 2) 让本机信任这个发布者 ===' -ForegroundColor Cyan
  Export-Certificate -Cert $cert -FilePath $cerPath -Force | Out-Null
  # 用 certutil 加，避免 Import-Certificate 在非交互场景要求弹窗确认
  foreach ($store in @('Root', 'TrustedPublisher')) {
    & certutil.exe -addstore -f $store $cerPath | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "  已导入本机 $store" }
    else { Write-Host "  导入 $store 失败（退出码 $LASTEXITCODE）" -ForegroundColor Yellow }
  }
  Write-Host ("  公钥证书: " + $cerPath)
} else {
  Write-Host '=== 2) 跳过信任安装（加 -InstallTrust 并提权才会装）===' -ForegroundColor DarkGray
}

Write-Host '=== 3) 给程序签名 ===' -ForegroundColor Cyan
# 只签 exe。
# 不要签 widget.ps1：给 .ps1 签名会在文件尾部追加签名块，如果最后一行没有换行符，
# 就会把最后一行代码吃掉（曾经把 $timer.Dispose() 变成 $timer.Dispose( 导致悬浮窗无法启动）。
# 悬浮窗本来是用 -ExecutionPolicy Bypass 运行的，不需要签名。
foreach ($f in @($exe)) {
  if (Test-Path $f) {
    if (-not (Get-Content $f -Raw -ErrorAction SilentlyContinue)) { }
    $r = Set-AuthenticodeSignature -FilePath $f -Certificate $cert -HashAlgorithm SHA256
    Write-Host ("  " + (Split-Path -Leaf $f) + " -> " + $r.Status)
  }
}
if (Test-Path $widget) {
  try {
    $wsig = Get-AuthenticodeSignature $widget
    if ($wsig.Status -ne 'NotSigned') {
      Write-Host '  说明: widget.ps1 上残留的签名块不影响运行（是注释），不再重新签名以免破坏文件。' -ForegroundColor DarkGray
    }
  } catch { }
}

Write-Host '=== 4) 验证 ===' -ForegroundColor Cyan
$sig = Get-AuthenticodeSignature $exe
Write-Host ("  状态      : " + $sig.Status)
Write-Host ("  发布者    : " + $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '(无)' }))
Write-Host ("  指纹      : " + $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Thumbprint } else { '(无)' }))
if ($sig.Status -ne 'Valid') {
  Write-Host '  提示: 状态不是 Valid 时，说明还没安装信任（用管理员运行带 -InstallTrust 的那条）。' -ForegroundColor Yellow
}
