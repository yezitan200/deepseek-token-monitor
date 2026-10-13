# 把一张图（ico/png）转换成多尺寸标准 ICO，供 csc /win32icon 使用。
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\make-ico.ps1 -In <源图> -Out <输出.ico>
param(
  [Parameter(Mandatory = $true)][string]$In,
  [Parameter(Mandatory = $true)][string]$Out,
  [int[]]$Sizes = @(16, 24, 32, 48, 64, 128, 256)
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function Get-SourceBitmap {
  param([string]$Path)
  $ext = [System.IO.Path]::GetExtension($Path).ToLower()
  if ($ext -eq '.ico') {
    $icon = New-Object System.Drawing.Icon($Path)
    return $icon.ToBitmap()
  }
  return [System.Drawing.Bitmap]::FromFile($Path)
}

function Get-FrameBytes {
  param([System.Drawing.Bitmap]$Source, [int]$Size)
  # 等比缩放（保持正方形），高质量插值
  $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.DrawImage($Source, (New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)))
  $g.Dispose()

  # 取 32bpp BGRA 像素
  $rect = New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)
  $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $stride = $data.Stride
  $buffer = New-Object byte[] ($stride * $Size)
  [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buffer, 0, $buffer.Length)
  $bmp.UnlockBits($data)

  # 组装 DIB：BITMAPINFOHEADER + 自下而上的像素 + AND 掩码
  $maskStride = [int][math]::Ceiling($Size / 8.0)
  if ($maskStride % 4 -ne 0) { $maskStride += 4 - ($maskStride % 4) }
  $pixelBytes = $Size * $Size * 4
  $maskBytes = $maskStride * $Size
  $frame = New-Object byte[] (40 + $pixelBytes + $maskBytes)
  $ms = New-Object System.IO.MemoryStream($frame, $true)
  $bw = New-Object System.IO.BinaryWriter($ms)
  $bw.Write([uint32]40)          # biSize
  $bw.Write([int32]$Size)        # biWidth
  $bw.Write([int32]($Size * 2))  # biHeight（ICO 约定含掩码，写两倍）
  $bw.Write([uint16]1)           # biPlanes
  $bw.Write([uint16]32)          # biBitCount
  $bw.Write([uint32]0)           # biCompression
  $bw.Write([uint32]$pixelBytes)
  $bw.Write([int32]0); $bw.Write([int32]0)
  $bw.Write([uint32]0); $bw.Write([uint32]0)
  # 像素：DIB 是自下而上，Bitmap 缓冲是自上而下
  for ($y = $Size - 1; $y -ge 0; $y--) {
    $bw.Write($buffer, ($y * $stride), ($Size * 4))
  }
  # AND 掩码全 0（不透明由 alpha 通道决定）
  $bw.Write((New-Object byte[] $maskBytes))
  $bw.Flush()
  $bmp.Dispose()
  # 注意：PowerShell 返回数组时会自动展开，必须用逗号包一层，否则调用方拿到的是 object[]
  return , $frame
}

$src = Get-SourceBitmap -Path $In
"源图: $($src.Width)x$($src.Height)"

$frames = @()
foreach ($s in ($Sizes | Sort-Object)) {
  $frames += , @{ Size = $s; Bytes = (Get-FrameBytes -Source $src -Size $s) }
}
$src.Dispose()

$outStream = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($outStream)
$bw.Write([uint16]0)                 # reserved
$bw.Write([uint16]1)                 # type = icon
$bw.Write([uint16]$frames.Count)     # count
$offset = 6 + 16 * $frames.Count
foreach ($f in $frames) {
  $dim = 0
  if ($f.Size -lt 256) { $dim = $f.Size }
  $bw.Write([byte]$dim)              # 宽（256 记作 0）
  $bw.Write([byte]$dim)              # 高
  $bw.Write([byte]0)                 # 调色板数
  $bw.Write([byte]0)                 # reserved
  $bw.Write([uint16]1)               # planes
  $bw.Write([uint16]32)              # bit count
  $bw.Write([uint32]$f.Bytes.Length)
  $bw.Write([uint32]$offset)
  $offset += $f.Bytes.Length
}
foreach ($f in $frames) { $bw.Write([byte[]]$f.Bytes) }
$bw.Flush()
[System.IO.File]::WriteAllBytes($Out, $outStream.ToArray())
$outStream.Dispose()

"已生成: $Out  ($([math]::Round((Get-Item $Out).Length/1KB)) KB，含尺寸 " + (($frames | ForEach-Object { $_.Size }) -join ',') + ")"
