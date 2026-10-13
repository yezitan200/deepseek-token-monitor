# token-monitor 桌面悬浮窗
# 轮询本地代理的 /__stats 接口，把 token 用量显示为一个置顶的小窗。
# 用法： powershell -NoProfile -ExecutionPolicy Bypass -File widget.ps1 -Port 8788

param(
  [int]$Port = 8788,
  # 启动悬浮窗时自动打开的 DSH Web 界面（可在 config.json 里用 dshWebUrl 覆盖）
  [string]$DshUrl = 'http://127.0.0.1:3080',
  [switch]$NoOpenWeb,
  # 启动时就折叠到某条屏幕边缘：left / right / top / bottom（留空 = 不折叠，按上次记住的状态）
  [string]$Collapse = '',
  # 自检模式：把吸附逻辑跑一遍并写入 data\selftest.txt，然后退出（测试用）
  [switch]$SelfTest,
  # 预览模式：把两页的界面离屏渲染成 PNG，不显示窗口、不轮询代理（无头环境验证外观用）
  [switch]$Preview,
  # 预览时往数据里补一份 peakWindow（JSON，例如 {"peak":false,"percent":86,...}），
  # 用来把进度圆环画成指定的样子；不填就用"当前时段"的真实值
  [string]$PreviewPeakWindow = '',
  # 预览哪几页（默认两页都画）：1 / 2 / 12。文档里要单独的账户页图时用 -PreviewPages 1
  [string]$PreviewPages = '12',
  # 预览：强制把"余额低于设定值"的告警态画出来（例：-PreviewWarnThreshold 10）。
  # 只影响 -Preview 的绘制，不读也不写 config.json —— 所以给文档出图时不会惊动正在跑的悬浮窗。
  [string]$PreviewWarnThreshold = '',
  # 不在本进程里创建"性能监控"小窗（排查用；正式运行由 config.json 的 monitor 段决定）
  [switch]$NoMonitor
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }

# 当本脚本被以 -WindowStyle Hidden 拉起时，窗口会继承隐藏状态，
# 这里显式调用 Win32 / DWM 接口把窗口显示出来，并套用 Win11 的圆角与深色边框。
Add-Type -Namespace TokenMonitor -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

// ── 性能监控小窗要的三组系统数据 ──
// 这里只做"取原始值"，单位换算和格式化都留在 PowerShell 里，方便跟前两位小数对齐。
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetSystemTimes(out long idleTime, out long kernelTime, out long userTime);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX buffer);

[StructLayout(LayoutKind.Sequential)]
public struct MEMORYSTATUSEX
{
    public uint dwLength;
    public uint dwMemoryLoad;
    public ulong ullTotalPhys;
    public ulong ullAvailPhys;
    public ulong ullTotalPageFile;
    public ulong ullAvailPageFile;
    public ulong ullTotalVirtual;
    public ulong ullAvailVirtual;
    public ulong ullAvailExtendedVirtual;
}

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);

[StructLayout(LayoutKind.Sequential)]
public struct SYSTEM_POWER_STATUS
{
    public byte ACLineStatus;
    public byte BatteryFlag;
    public byte BatteryLifePercent;
    public byte SystemStatusFlag;
    public int BatteryLifeTime;
    public int BatteryFullLifeTime;
}
'@

# 高分屏自适应（2026-10-05 重做，前面两个极端都踩过）：
#   ① 声明 DPI 感知但不缩放布局 → 字体被系统放大、框没变，文字被切（用户第一次分享时遇到的）；
#   ② 干脆不声明感知 → 系统把整个窗口拉伸，完整但**发虚**，而且缩放率高的机器上整块变大（用户第二次反馈）。
# 现在两头都占：**声明感知**（清晰）+ 布局按 $script:UiScale 放大 + 字体按 $script:FontScale 反向换算。
# 两者相乘正好等于设计比例，所以"看起来多大"只由 UiScale 决定，跟机器的缩放率无关，也不会切字。
try { [void][TokenMonitor.Win]::SetProcessDPIAware() } catch { }

$script:Dpi = 96
try {
  $bmpDpi = New-Object System.Drawing.Bitmap 1, 1
  $gDpi = [System.Drawing.Graphics]::FromImage($bmpDpi)
  $script:Dpi = [int][Math]::Round($gDpi.DpiX)
  $gDpi.Dispose(); $bmpDpi.Dispose()
} catch { }
if ($script:Dpi -lt 96) { $script:Dpi = 96 }

# 尺寸与字号都固定为设计值（用户最终要求：窗口不放大、字号不变，只解决切字）。
# 这两个变量保留成常量，供布局代码和 New-Label 使用；**不要再接"按 DPI/屏幕缩放"的逻辑**——
# 那几版都被否掉了，来龙去脉见 README 9.1 第 10 条。
$script:UiScale = 1.0
$script:FontScale = 1.0

$script:Port = $Port
# 应用目录 = 本脚本所在目录。TOKEN_MONITOR_DIR 是留给探针脚本的逃生口：
# 用 [scriptblock]::Create 把本脚本当代码块跑时 $MyInvocation.MyCommand.Path 是 null，
# 那时由探针用环境变量指定目录；正常运行时永远走下面那一条。
$script:Root = $env:TOKEN_MONITOR_DIR
if (-not $script:Root) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:DataDir = Join-Path $script:Root 'data'
$script:GeomFile = Join-Path $script:DataDir 'widget.json'
if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }

$script:Online = $false
$script:Stats = $null
$script:LastGeometry = ''
$script:Page = 1                # 1 = 用量页，2 = 账户页
$script:PillText = '账户 ›'     # 右上角圆角按钮上的文字
$script:PillHover = $false
$script:DshWebState = ''
# -Preview 是"只看外观"的模式：不留 pid、不写位置记忆、不打开浏览器，免得把用户正在用的那份状态改掉
$script:PreviewOnly = [bool]$Preview
$script:SaveGeometry = -not $script:PreviewOnly
if ($script:PreviewOnly) { $script:OpenDshWeb = $false }
# -Preview 不能连代理（会和用户正在用的那份抢轮询，也没有意义），所以塞一份示例数据。
# -PreviewPeakWindow 可以覆盖其中的 peakWindow，用来把进度圆环画成指定的样子（核对外观用）。
$script:PreviewStats = $null
if ($script:PreviewOnly) {
  $sample = [pscustomobject]@{
    ok = $true
    totals = [pscustomobject]@{ requests = 128; prompt = 512345; completion = 98765; total = 611110; estimated = 0 }
    today = [pscustomobject]@{ total = 123456; requests = 12; cost = 0.42; costKnown = $true }
    rate = [pscustomobject]@{ completionPerSec = 38.4 }
    cost = [pscustomobject]@{ total = 6.21; known = $true; currency = '¥' }
    lastCost = 0.0132
    price = [pscustomobject]@{ model = 'deepseek-flash'; peak = $false; tierText = '空闲'; currency = '¥'; inputHit = 0.02; inputMiss = 1; output = 4 }
    balance = [pscustomobject]@{ fetchedAt = 0; keySource = 'config.json'; keyMasked = 'sk-dee****d57f'; balances = @([pscustomobject]@{ currency = 'CNY'; total = 5.44; granted = 0; toppedUp = 5.44 }) }
    peakNow = $false
    peakReason = '工作日非高峰时段'
    pricingLabel = '官网自动获取'
    pricingFetchedAt = 1791186369249      # 10-05 15:46 那次抓取（预览用真实量级的时间戳）
    pricingFetchedText = '10-05 15:46 更新'
    pricingSource = 'https://api-docs.deepseek.com/zh-cn/quick_start/pricing'
    pricingNextRefreshAt = 1791791169249
    holidays = [pscustomobject]@{ label = '自动获取（2026 年）+ 内置表' }
    dshUsage = [pscustomobject]@{ error = '（预览模式不读取 DSH 会话）' }
    conversation = [pscustomobject]@{ ok = $true; title = '预览示例'; tokens = [pscustomobject]@{ uncachedInputTokens = 44890; cacheReadTokens = 448256; cacheWriteTokens = 0; outputTokens = 3281; total = 496427 }; cost = 0.066979; costCurrency = '¥'; costModel = 'deepseek-flash'; costPeak = $false }
  }
  $priceObj = $sample.price
  $tierText = '空闲'
  if ($PreviewPeakWindow) {
    try {
      $pw = $PreviewPeakWindow | ConvertFrom-Json
      $sample | Add-Member -NotePropertyName peakWindow -NotePropertyValue $pw -Force
      if ($pw.peak) { $priceObj.peak = $true; $tierText = '高峰' } else { $priceObj.peak = $false; $tierText = '空闲' }
    } catch { }
  }
  if (-not $sample.peakWindow) {
    # 没给就现算一份真实的起止，保证预览里的倒计时/圆环跟当前时间对得上
    $nowDt = [datetime]::Now
    $start = $nowDt.Date.AddHours(12)
    $end = $nowDt.Date.AddHours(14)
    if ($nowDt.Hour -ge 14 -and $nowDt.Hour -lt 18) { $start = $nowDt.Date.AddHours(14); $end = $nowDt.Date.AddHours(18); $priceObj.peak = $true; $tierText = '高峰' }
    elseif ($nowDt.Hour -ge 18) { $start = $nowDt.Date.AddHours(18); $end = $nowDt.Date.AddDays(1).AddHours(9) }
    elseif ($nowDt.Hour -lt 9) { $start = $nowDt.Date.AddDays(-1).AddHours(18); $end = $nowDt.Date.AddHours(9) }
    $totalMs = ($end - $start).TotalMilliseconds
    $elapsedMs = ($nowDt - $start).TotalMilliseconds
    $sample | Add-Member -NotePropertyName peakWindow -NotePropertyValue ([pscustomobject]@{
      peak = [bool]$priceObj.peak; tierText = $tierText
      startAt = [int64](([datetimeoffset]$start).ToUnixTimeMilliseconds())
      endAt = [int64](([datetimeoffset]$end).ToUnixTimeMilliseconds())
      totalMs = [int64]$totalMs; elapsedMs = [int64]$elapsedMs
      remainMs = [int64]($totalMs - $elapsedMs); percent = [double](100 * $elapsedMs / $totalMs)
    }) -Force
  }
  $priceObj.tierText = $tierText
  $sample.balance.fetchedAt = [int64](([datetimeoffset][datetime]::Now).ToUnixTimeMilliseconds())
  $script:PreviewStats = $sample
}

# ── 贴边折叠：拖到屏幕边缘就缩成一个小标签（深色圆角 + 一个箭头），点它展开 ──
$script:Collapsed = $false
$script:Edge = ''                        # left / right / top / bottom
$script:ExpandedBounds = $null           # 展开时的位置与大小
$script:TabSize = 58                     # 折叠后长边的像素
$script:TabThick = 30                    # 折叠后厚度
$script:SnapTolerance = 12               # 距边缘多少像素内算"贴边"（原来 24，太容易一碰就折叠）
$script:DragThreshold = 6                # 鼠标移动超过这么多像素才算"拖动"，否则一律算"点一下"
$script:TabHover = $false                # 鼠标悬停在折叠标签上（提亮，便于发现）
$script:SuppressClick = $false           # 刚拖完的那一下不当成点击
$script:StatusDotBackup = $true

# ── 单实例保护：已经有一个悬浮窗在跑就直接退出，避免屏幕上出现两个 ──
# 用系统级互斥锁判断（比查进程可靠），进程退出时锁自动释放。
# ⚠️ -Preview 必须绕开这一整段：用户正开着悬浮窗时，这里会静默 exit 0，
# 看起来像"预览跑不起来"（踩过：一度以为是自己改坏了）。
if (-not $script:PreviewOnly) {
  try {
    $script:InstanceMutex = New-Object System.Threading.Mutex($true, 'token-monitor-widget-singleton', [ref]$script:MutexCreated)
    if (-not $script:MutexCreated) { exit 0 }   # 已有一个在跑
  } catch {
    # 互斥锁不可用时退回查 pid 文件
    try {
      $pidFile = Join-Path $script:DataDir 'widget.pid'
      if (Test-Path $pidFile) {
        $oldPid = 0
        [void][int]::TryParse((Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim(), [ref]$oldPid)
        if ($oldPid -gt 0 -and $oldPid -ne $PID) {
          $alive = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
          if ($alive -and $alive.ProcessName -eq 'powershell') { exit 0 }
        }
      }
    } catch { }
  }
}

# ── 余额提醒：余额低于设定值 → 第 1 页那个大数字变成红色 ──
# 开关与设定值由启动器的「设置 · 余额提醒」页写进 config.json（和其它设置一样是两个扁平字段）：
#   "balanceWarnEnabled": true, "balanceWarnThreshold": 20
# 默认关；设定值的单位是元，<= 0 视为不提醒。运行中每 5 秒跟着 config.json 重读一次
# （在 Read-MonitorConfig 里，和性能监控那套共用同一次读取），所以启动器改完设置不用重启悬浮窗。
$script:BalanceWarnEnabled = $false
$script:BalanceWarnThreshold = 0.0

# 把 config.json 里的这两项读进 $script:BalanceWarn*；缺项 / 写坏了都只是保持默认，不抛错。
function Set-BalanceWarnFromConfig {
  param($Cfg)
  if (-not $Cfg) { return }
  try {
    if ($null -ne $Cfg.PSObject.Properties['balanceWarnEnabled']) {
      $script:BalanceWarnEnabled = [bool]$Cfg.balanceWarnEnabled
    }
    if ($null -ne $Cfg.PSObject.Properties['balanceWarnThreshold']) {
      $d = 0.0
      if ([double]::TryParse([string]$Cfg.balanceWarnThreshold, [ref]$d)) {
        $script:BalanceWarnThreshold = [Math]::Abs($d)
      }
    }
  } catch { }
}

# 自动打开 DSH Web 界面：默认开，config.json 的 openDshWebOnStart / dshWebUrl 可调整；
# 命令行参数 -DshUrl / -NoOpenWeb 优先于 config.json
$configFile = Join-Path $script:Root 'config.json'
$script:OpenDshWeb = -not $NoOpenWeb
if (Test-Path $configFile) {
  try {
    $cfg = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.dshWebUrl -and -not $PSBoundParameters.ContainsKey('DshUrl')) { $DshUrl = [string]$cfg.dshWebUrl }
    if ($cfg.openDshWebOnStart -eq $false -and -not $NoOpenWeb) { $script:OpenDshWeb = $false }
    Set-BalanceWarnFromConfig -Cfg $cfg
  } catch { }
}
$script:DshUrl = $DshUrl

# -PreviewWarnThreshold：出图 / 自检用，强制进入"余额低于设定值"的样子（只影响预览，不碰配置文件）
if ($script:PreviewOnly -and $PreviewWarnThreshold -ne '') {
  $pd = 0.0
  if ([double]::TryParse($PreviewWarnThreshold, [ref]$pd)) {
    $script:BalanceWarnEnabled = $true
    $script:BalanceWarnThreshold = [Math]::Abs($pd)
  }
}

# ── 性能监控小窗（下方副窗）的配置 ──
# 开关与显示内容由启动器的「设置 · 性能监控」页写进 config.json：
#   "monitor": { "enabled": true, "items": ["cpu","memory","battery"] }
# 这里只轮询文件（5 秒一次，按修改时间判断要不要重读），所以启动器改完设置**不用重启悬浮窗**。
# 注意：config.json 里有明文 API Key，这个函数只取 monitor 段，绝不把内容打日志。
$script:MonitorEnabled = $false
$script:MonitorItems = @('cpu', 'memory', 'battery')
$script:MonitorShown = $false
$script:MonitorWin = $null
$script:MonitorRows = @{}
$script:MonitorNextCfgCheck = [datetime]::MinValue
$script:MonitorCfgStamp = [datetime]::MinValue
$script:MonitorNextDataAt = [datetime]::MinValue
$script:MonitorSample = $null
$script:MonitorCpuPct = $null
$script:MonitorCpuGhz = 0.0
$script:MonitorMemText = '—'
$script:MonitorMemPct = -1.0
$script:MonitorBatText = '—'
$script:MonitorBatState = ''
$script:MonitorBatPct = -1.0
$script:MonitorAvail = $true
$script:MonitorBatWatts = 0.0
$script:MonitorCpuMaxGhz = 0.0
$script:MonitorNextWmiAt = [datetime]::MinValue
# 后台采样（WMI：CPU 频率 / 电池瓦数）用的几个状态，见 Start-MonitorWmiSample
$script:MonWmi = $null                 # @{ Handle = <IAsyncResult>; At = <datetime> }
$script:MonWmiRunspace = $null         # 复用的后台 runspace（不新开进程）
$script:MonWmiPS = $null               # 复用的 PowerShell 实例
$script:MonWmiBackoffAt = [datetime]::MinValue
# 小窗所在屏幕的工作区缓存：Screen::FromPoint 单次 0.25ms，而拖动时每次鼠标移动都要用
$script:MonWa = $null
$script:MonWaX0 = 0; $script:MonWaY0 = 0; $script:MonWaX1 = 0; $script:MonWaY1 = 0
$script:MonDot = $null                 # 小窗标题行右侧那个在线状态点（省得每轮遍历控件找它）

function Read-MonitorConfig {
  # 返回 $true 表示配置发生了变化（调用方据此重建小窗）
  #
  # ⚠️ 字段形状必须和启动器写的一致：**扁平的** "monitorEnabled" / "monitorItems"。
  # （2026-10-08 踩过：这里一开始按嵌套的 monitor.enabled / monitor.items 读，
  #   启动器写的是扁平字段，两边对不上 → 小窗永远不显示，而且不报任何错。）
  # 顺手兼容一下嵌套写法，方便手工编辑配置的人。
  $now = [datetime]::Now
  if ($now -lt $script:MonitorNextCfgCheck) { return $false }
  $script:MonitorNextCfgCheck = $now.AddSeconds(5)

  $stamp = [datetime]::MinValue
  try { $stamp = (Get-Item $configFile -ErrorAction Stop).LastWriteTime } catch { return $false }
  if ($stamp -eq $script:MonitorCfgStamp) { return $false }
  $script:MonitorCfgStamp = $stamp

  $enabled = $false
  $rawItems = @()

  try {
    $cfg2 = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json

    if ($null -ne $cfg2.PSObject.Properties['monitorEnabled']) {
      $enabled = [bool]$cfg2.monitorEnabled
    }
    if ($null -ne $cfg2.PSObject.Properties['monitorItems']) {
      $rawItems = @([string]$cfg2.monitorItems -split ',')
    }

    # 兼容（可选）：{"monitor":{"enabled":true,"items":["cpu","memory"]}}
    $mon = $cfg2.PSObject.Properties['monitor']
    if ($mon -and $mon.Value) {
      if ($null -ne $mon.Value.PSObject.Properties['enabled']) { $enabled = [bool]$mon.Value.enabled }
      if ($null -ne $mon.Value.PSObject.Properties['items']) { $rawItems = @($mon.Value.items) }
    }
  } catch { return $false }

  # 顺手把"余额提醒"那两项也刷新一遍：同一份配置、同一次读取，不多花一次 IO。
  # 它变了不需要重建小窗，所以不计入 $changed —— 余额那个数字的颜色由 Update-Ui 每轮自己取当前值。
  Set-BalanceWarnFromConfig -Cfg $cfg2

  # 固定成 cpu → memory → battery 的顺序，未知项丢掉
  $picked = @()
  foreach ($k in @('cpu', 'memory', 'battery')) {
    foreach ($raw in $rawItems) {
      if ([string]$raw.Trim().ToLowerInvariant() -eq $k) { $picked += $k; break }
    }
  }

  # monitorItems 缺省（老配置里没这一项）时按三项全开处理；
  # 明确写成空串则表示"一项都不显示"，那就等于关掉。
  $hasItemsKey = ($null -ne $cfg2.PSObject.Properties['monitorItems']) -or ($mon -and $mon.Value -and $null -ne $mon.Value.PSObject.Properties['items'])
  if (-not $hasItemsKey) { $picked = @('cpu', 'memory', 'battery') }
  if ($picked.Count -eq 0) { $enabled = $false }

  $items = $picked
  $changed = ($enabled -ne $script:MonitorEnabled) -or (($items -join ',') -ne ($script:MonitorItems -join ','))
  $script:MonitorEnabled = $enabled
  $script:MonitorItems = $items
  return $changed
}

# 每格的原始数据（-Preview 时不调真实接口，用固定示例值，免得预览图和实物不一致）
function Get-MonitorSample {
  if ($script:PreviewOnly) {
    $nowT = [datetime]::Now
    return [pscustomobject]@{
      cpuPct = 23.0; cpuGhz = 2.90; memUsed = 9.8GB; memTotal = 16GB; memPct = 61.0
      hasBattery = $true; batWatts = 18.4; batVoltage = 12.31
      batState = 'discharging'; acOnline = $false
    }
  }
  return $null
}

function Get-CpuUsage {
  # 用两次 GetSystemTimes 的差值算整体占用率（kernel 时间里含 idle，要减掉）
  try {
    $idle = [int64]0; $kernel = [int64]0; $user = [int64]0
    if (-not [TokenMonitor.Win]::GetSystemTimes([ref]$idle, [ref]$kernel, [ref]$user)) { return $null }
    $prev = $script:MonitorSample
    $script:MonitorSample = @{ idle = $idle; kernel = $kernel; user = $user }
    if (-not $prev) { return $null }         # 第一次只留基准
    $idleD = $idle - $prev.idle
    $kernelD = $kernel - $prev.kernel
    $userD = $user - $prev.user
    $totalD = $kernelD + $userD
    if ($totalD -le 0) { return $null }
    $pct = ($userD + ($kernelD - $idleD)) / $totalD * 100.0
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    return [double]$pct
  } catch { return $null }
}

function Format-Bytes {
  param([double]$Bytes)
  if ($Bytes -ge 1GB) { return ('{0:0.0} GB' -f ($Bytes / 1GB)) }
  return ('{0:0} MB' -f ($Bytes / 1MB))
}

function Get-MemoryInfo {
  try {
    $m = New-Object TokenMonitor.Win+MEMORYSTATUSEX
    $m.dwLength = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($m)
    if (-not [TokenMonitor.Win]::GlobalMemoryStatusEx([ref]$m)) { return $null }
    $total = [double]$m.ullTotalPhys
    $avail = [double]$m.ullAvailPhys
    $used = $total - $avail
    $pct = 0.0
    if ($total -gt 0) { $pct = $used / $total * 100.0 }
    return @{ used = $used; total = $total; pct = $pct }
  } catch { return $null }
}

function Get-BatteryInfo {
  # 台式机没有电池时返回 $null，界面显示 "--"
  try {
    $st = New-Object TokenMonitor.Win+SYSTEM_POWER_STATUS
    if (-not [TokenMonitor.Win]::GetSystemPowerStatus([ref]$st)) { return $null }
    if ($st.BatteryFlag -eq 128) { return $null }        # 128 = 本机无电池
    if ($st.BatteryLifePercent -eq 255 -and $st.ACLineStatus -eq 255) { return $null }
    $ac = ($st.ACLineStatus -eq 1)
    $charging = (($st.BatteryFlag -band 8) -ne 0)
    $state = if ($charging) { 'charging' } elseif ($ac) { 'ac' } else { 'discharging' }
    return @{ acOnline = $ac; charging = $charging; state = $state; pct = [int]$st.BatteryLifePercent }
  } catch { return $null }
}

# ---------------- Windows 11 (Fluent) 深色配色 ----------------
# 参考 Win11 深色主题：底层 #202020、卡片层 #2B2B2B、描边 rgba(255,255,255,0.08)、
# 主文字 #FFFFFF、次要文字约 61% 白、强调色 #60CDFF、错误色 #FF99A4
$bgColor      = [System.Drawing.Color]::FromArgb(32, 32, 32)     # #202020
$cardColor    = [System.Drawing.Color]::FromArgb(255, 255, 255, 15)
$borderColor  = [System.Drawing.Color]::FromArgb(58, 58, 58)     # #3A3A3A
$dividerColor = [System.Drawing.Color]::FromArgb(48, 48, 48)     # 分隔线
$titleColor   = [System.Drawing.Color]::FromArgb(255, 255, 255)
$accentColor  = [System.Drawing.Color]::FromArgb(96, 205, 255)   # #60CDFF
$textColor    = [System.Drawing.Color]::FromArgb(240, 240, 240)
$mutedColor   = [System.Drawing.Color]::FromArgb(155, 155, 155)
$okColor      = [System.Drawing.Color]::FromArgb(108, 203, 95)   # #6CCB5F
$badColor     = [System.Drawing.Color]::FromArgb(255, 153, 164)  # #FF99A4
# 余额提醒用的红：比 $badColor（偏粉，用于"查询失败"）更实、更醒目，
# 用户要求的就是"低于设定值时变成红色"（见启动器「设置 · 余额提醒」）
$warnColor    = [System.Drawing.Color]::FromArgb(255, 90, 90)    # #FF5A5A
# 时段配色：空闲=蓝（强调色），高峰=红（Win11 深色错误色）
$idleColor    = [System.Drawing.Color]::FromArgb(96, 205, 255)
$peakColor    = [System.Drawing.Color]::FromArgb(255, 153, 164)
# 圆角胶囊按钮 / 关闭按钮
$pillFill      = [System.Drawing.Color]::FromArgb(45, 45, 45)    # 约等于 6% 白叠加
$pillHoverFill = [System.Drawing.Color]::FromArgb(58, 58, 58)
$pillBorder    = [System.Drawing.Color]::FromArgb(66, 66, 66)
$pillTextCol   = [System.Drawing.Color]::FromArgb(255, 255, 255)
$closeHoverFill = [System.Drawing.Color]::FromArgb(196, 43, 28)   # Win11 关闭键悬停红
# 注意：PowerShell 变量名不区分大小写，颜色变量一律带 Fill 后缀，
# 避免和 $script:CloseHover / $script:PillHover 这类布尔状态变量撞成同一个变量

# 字体：数字用 Segoe UI Variable（Win11 默认），中文用 Microsoft YaHei UI
$installedFonts = @()
try { $installedFonts = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name } } catch { }
$numFont = 'Segoe UI'
if ($installedFonts -contains 'Segoe UI Variable Display') { $numFont = 'Segoe UI Variable Display' }
elseif ($installedFonts -contains 'Segoe UI Variable Text') { $numFont = 'Segoe UI Variable Text' }
$uiFont = 'Microsoft YaHei UI'

# 大数字用到的字体（离线/出错时会临时换成小号，避免大号破折号看成一条粗线）
$fontBig   = New-Object System.Drawing.Font($numFont, (22 * $script:FontScale), [System.Drawing.FontStyle]::Bold)
$fontMid   = New-Object System.Drawing.Font($numFont, (15 * $script:FontScale), [System.Drawing.FontStyle]::Bold)
# 那个"花费"小字：比主数字更小、更暗，跟"本轮对话用量"标签同一行、靠右对齐
$fontSmall = New-Object System.Drawing.Font($uiFont, (8.5 * $script:FontScale), [System.Drawing.FontStyle]::Regular)
$fontOff   = New-Object System.Drawing.Font($uiFont, (12 * $script:FontScale), [System.Drawing.FontStyle]::Bold)
$fontTag   = New-Object System.Drawing.Font($uiFont, (8 * $script:FontScale), [System.Drawing.FontStyle]::Regular)
$fontTitle = New-Object System.Drawing.Font($uiFont, (9.5 * $script:FontScale), [System.Drawing.FontStyle]::Bold)
# 专门给"账户页第 4 行退回显示单价明细"用的小号字：那一格只有 180px 宽，
# 8.5pt 下那串单价要 225px 会被窗口边缘啃掉，7.5pt 才勉强放得下。
# 必须在这里建一次复用——Update-Ui 每 800ms 跑一遍，在函数里 New-Object 会一直漏 GDI 对象。
$fontTiny  = New-Object System.Drawing.Font($uiFont, (7.5 * $script:FontScale), [System.Drawing.FontStyle]::Regular)

$width = 300
$height = 176

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = $bgColor
$form.ClientSize = New-Object System.Drawing.Size($width, $height)
$form.Text = 'Token 用量'
$form.KeyPreview = $true
$form.Opacity = 0.98

# 默认位置：主屏右下角
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$defaultLocation = New-Object System.Drawing.Point(($screen.Right - $width - 24), ($screen.Bottom - $height - 24))
$form.Location = $defaultLocation

if (Test-Path $script:GeomFile) {
  try {
    $geom = Get-Content $script:GeomFile -Raw | ConvertFrom-Json
    if ($geom.page -eq 2) { $script:Page = 2 }
    if ($geom.x -ne $null -and $geom.y -ne $null) {
      $form.Location = New-Object System.Drawing.Point([int]$geom.x, [int]$geom.y)
      # 记忆的位置可能落在已拔掉的显示器上，这里校验一下是否还在可见范围内
      $onScreen = $false
      foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        if ($s.WorkingArea.IntersectsWith($form.Bounds)) { $onScreen = $true; break }
      }
      if (-not $onScreen) { $form.Location = $defaultLocation }
    }
    # 上次是折叠状态的话，启动时也折叠回去
    if ($geom.collapsed -eq $true -and $geom.edge) {
      $script:RestoreCollapsed = $true
      $script:RestoreEdge = [string]$geom.edge
    }
  } catch { $form.Location = $defaultLocation }
}

$form.Add_Paint({
  param($sender, $e)
  # Win11 风格：圆角描边（与 DWM 给的圆角半径一致），不再用左侧色条
  $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $w = $sender.ClientSize.Width
  $h = $sender.ClientSize.Height
  $radius = [int][Math]::Round(8 * $script:UiScale)
  if ($script:Collapsed) {
    # 折叠态：铺满背景（悬停时略亮）+ 更清楚的边框 + 指向屏幕内侧的箭头 + 在线状态点
    $tabBg = if ($script:TabHover) { [System.Drawing.Color]::FromArgb(44, 44, 44) } else { [System.Drawing.Color]::FromArgb(28, 28, 28) }
    $bgPath = New-RoundedPath -X 0 -Y 0 -W $w -H $h -R $radius
    $bgBrush = New-Object System.Drawing.SolidBrush($tabBg)
    $e.Graphics.FillPath($bgBrush, $bgPath)
    $bgBrush.Dispose(); $bgPath.Dispose()
  }
  $path = New-RoundedPath -X 0.5 -Y 0.5 -W ($w - 1) -H ($h - 1) -R $radius
  $edgeColor = if ($script:Collapsed -and $script:TabHover) { $accentColor }
               elseif ($script:Collapsed) { [System.Drawing.Color]::FromArgb(88, 88, 88) }
               else { $borderColor }
  $pen = New-Object System.Drawing.Pen($edgeColor, 1)
  $e.Graphics.DrawPath($pen, $path)
  $pen.Dispose(); $path.Dispose()
  if ($script:Collapsed) {
    # 箭头：贴在底边时指向上（^），顶边指向下，左边指向右，右边指向左
    $cx = $w / 2.0
    $cy = $h / 2.0
    $s = 5.5 * $script:UiScale
    $pts = switch ($script:Edge) {
      'bottom' { @((New-Object System.Drawing.PointF(($cx - $s), ($cy + $s * 0.6))), (New-Object System.Drawing.PointF($cx, ($cy - $s * 0.6))), (New-Object System.Drawing.PointF(($cx + $s), ($cy + $s * 0.6)))) }
      'top'    { @((New-Object System.Drawing.PointF(($cx - $s), ($cy - $s * 0.6))), (New-Object System.Drawing.PointF($cx, ($cy + $s * 0.6))), (New-Object System.Drawing.PointF(($cx + $s), ($cy - $s * 0.6)))) }
      'left'   { @((New-Object System.Drawing.PointF(($cx - $s * 0.6), ($cy - $s))), (New-Object System.Drawing.PointF(($cx + $s * 0.6), $cy)), (New-Object System.Drawing.PointF(($cx - $s * 0.6), ($cy + $s)))) }
      default  { @((New-Object System.Drawing.PointF(($cx + $s * 0.6), ($cy - $s))), (New-Object System.Drawing.PointF(($cx - $s * 0.6), $cy)), (New-Object System.Drawing.PointF(($cx + $s * 0.6), ($cy + $s)))) }
    }
    # 箭头用更亮的强调色，比原来的纯强调色更容易看见
    $arrowColor = if ($script:TabHover) { [System.Drawing.Color]::FromArgb(255, 255, 255) } else { [System.Drawing.Color]::FromArgb(155, 224, 255) }
    $arrowPen = New-Object System.Drawing.Pen($arrowColor, 2.6)
    $arrowPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $arrowPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $e.Graphics.DrawLines($arrowPen, [System.Drawing.PointF[]]$pts)
    $arrowPen.Dispose()

    # 在线状态点：绿=代理在线，红=离线（跟着折叠方向挪到合适的一角）
    $dotR = 3.0
    if ($script:Edge -eq 'left' -or $script:Edge -eq 'right') {
      $dotX = $w / 2.0
      $dotY = 8.0
    } else {
      $dotX = 9.0
      $dotY = $h / 2.0
    }
    $dotColor = if ($script:Online) { $okColor } else { $badColor }
    $dotBrush = New-Object System.Drawing.SolidBrush($dotColor)
    $e.Graphics.FillEllipse($dotBrush, [single]($dotX - $dotR), [single]($dotY - $dotR), [single]($dotR * 2), [single]($dotR * 2))
    $dotBrush.Dispose()
  }
})

# 生成一个圆角矩形路径（WinForms 的控件没有圆角属性，只能自己画）
function New-RoundedPath {
  param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  if ($R -lt 0.5) {
    $path.AddRectangle((New-Object System.Drawing.RectangleF($X, $Y, $W, $H)))
    return $path
  }
  $d = $R * 2
  $path.AddArc($X, $Y, $d, $d, 180, 90)
  $path.AddArc(($X + $W - $d), $Y, $d, $d, 270, 90)
  $path.AddArc(($X + $W - $d), ($Y + $H - $d), $d, $d, 0, 90)
  $path.AddArc($X, ($Y + $H - $d), $d, $d, 90, 90)
  $path.CloseFigure()
  return $path
}

function New-Label {
  param(
    [int]$X, [int]$Y, [int]$W, [int]$H,
    [string]$Text, [single]$Size = 8.5, [System.Drawing.Color]$Color = $textColor,
    [string]$Style = 'Regular', [string]$FontFamily = $uiFont, $HostForm = $null
  )
  $label = New-Object System.Windows.Forms.Label
  $label.Location = New-Object System.Drawing.Point($X, $Y)
  $label.Size = New-Object System.Drawing.Size($W, $H)
  $label.Text = $Text
  $label.ForeColor = $Color
  # 用与窗体一致的纯色背景：WinForms 的 Transparent 背景在重绘时容易只画一次
  $label.BackColor = $bgColor
  $label.Font = New-Object System.Drawing.Font($FontFamily, ($Size * $script:FontScale), [System.Drawing.FontStyle]$Style)
  $label.AutoSize = $false
  # -HostForm 默认是主悬浮窗；性能监控小窗复用同一个构造函数，所以要能指定目标窗体
  $HostForm = if ($PSBoundParameters.ContainsKey('HostForm') -and $HostForm) { $HostForm } else { $form }
  $HostForm.Controls.Add($label)
  return $label
}

# ---------------- 第 1 页：用量（只显示总用量与今日用量） ----------------
$lblTitle    = New-Label -X 30 -Y 8 -W 138 -H 20 -Text 'TOKEN 用量' -Size 9.5 -Color $titleColor -Style Bold
$lblHint     = New-Label -X 12 -Y 8 -W 0 -H 0 -Text '' -Size 8
$lblTotalTag = New-Label -X 12 -Y 44 -W 200 -H 16 -Text '总 TOKEN 用量' -Size 8 -Color $mutedColor
$lblTotal    = New-Label -X 12 -Y 62 -W 276 -H 46 -Text '0' -Size 22 -Color $accentColor -Style Bold -FontFamily $numFont
$lblTodayTag = New-Label -X 12 -Y 116 -W 200 -H 16 -Text '本轮对话用量' -Size 8 -Color $mutedColor
$lblToday    = New-Label -X 12 -Y 131 -W 276 -H 32 -Text '0' -Size 15 -Color $textColor -Style Bold -FontFamily $numFont
# 本轮对话的"花费"：小一号灰字，跟在那个大数字右边同一行（X 每次刷新按数字实际宽度算）
$lblConvCost = New-Label -X 150 -Y 131 -W 120 -H 26 -Text '' -Size 8.5 -Color $mutedColor
$lblConvCost.TextAlign = 'MiddleLeft'
# 大数字那个标签宽 276（覆盖整行）且背景不透明，会盖住同一行的花费小字。
# 注意：这一行在窗体句柄建立之前调用，**实际上是空操作**——真正生效的那次在 Apply-Page() 里
# （由 Add_Shown 触发），详见 README 9.1 第 6 条；这里留着只是表明意图。
$lblConvCost.BringToFront()

# ---------------- 第 2 页：账户（只显示余额与当前价格） ----------------
$lblTitle2      = New-Label -X 30 -Y 8 -W 138 -H 20 -Text '账户' -Size 9.5 -Color $titleColor -Style Bold
$lblBalTag      = New-Label -X 12 -Y 44 -W 200 -H 16 -Text '账户余额' -Size 8 -Color $mutedColor
$lblBalanceBig  = New-Label -X 12 -Y 62 -W 276 -H 46 -Text '—' -Size 22 -Color $okColor -Style Bold -FontFamily $numFont
$lblPriceTag    = New-Label -X 12 -Y 118 -W 200 -H 16 -Text '当前价格' -Size 8 -Color $mutedColor
$lblPriceModel  = New-Label -X 12 -Y 134 -W 276 -H 22 -Text '—' -Size 10 -Color $idleColor -Style Bold
# 当前时段进度（"空闲时段剩余 00:25:46" + "已过 86%" + 右侧进度圆环）。
# 这一行原来是"输入 ¥1（命中 ¥0.02）· 输出 ¥4"那串单价明细——按用户要求换成时段进度，
# 单价没有丢，全部挪进「当前价格」和这一行的悬停提示里（见 Update-Ui）。
# 右边这两格是**按实测宽度收紧**的（用户反馈过"已过占比被遮挡"）：
#   "已过 86%" 用 8pt 粗体实测 72px，框给 78（右边缘顶到 x=270，圆环 270 起，差 0 也不重叠）；
#   左边"空闲时段剩余 01:49:45"用 8.5pt 实测 165px，框给 180（左边缘到 x=192 为止）；
#   圆环 15px 放在 270..285，离窗口右边 15px。
#   两格都是"框 ≥ 文字宽 + 6px"，因为 125% 缩放下中文按点算会略宽——**别再往里塞字**。
$lblPriceDetail = New-Label -X 12 -Y 156 -W 180 -H 18 -Text '—' -Size 8.5 -Color $mutedColor
$lblTierElapsed  = New-Label -X 192 -Y 156 -W 78 -H 18 -Text '' -Size 8 -Color $mutedColor -Style Bold
$lblTierElapsed.TextAlign = 'MiddleRight'
$ringTier = New-Object System.Windows.Forms.Panel
# 圆环从 18px 收到 15px 并左移，让"已过 xx%"更贴近左边的剩余时间（用户的建议）
$ringTier.Location = New-Object System.Drawing.Point(270, 157)
$ringTier.Size = New-Object System.Drawing.Size(15, 15)
$ringTier.BackColor = $bgColor
$form.Controls.Add($ringTier)
$script:TierPercent = -1          # 上一次画进圆环的百分比（-1 = 还没画过）
$script:TierRingColor = $idleColor
$script:TierRingVisible = $false
# 圆环怎么画：底圈是暗轨道，进度弧从 12 点方向顺时针走到"已过百分比"，圆心一个小圆点。
# 抽成独立函数是为了让 -Preview 能直接调它（Panel.OnPaint 在脚本里调不到），
# 否则预览图里这一行只剩文字、看不到圆环。
function Draw-TierRing {
  param($G, [single]$X, [single]$Y, [int]$W, [int]$H)
  $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  # 线宽跟着控件尺寸走：控件从 18px 收到 15px 后，原来固定 2.6px 的弧 + 3px 的圆心会糊成一团
  $d = [single][Math]::Min($W, $H)
  $box = [single]($d - 3)
  $trackW = [single][Math]::Max(1.2, $d * 0.11)
  $arcW = [single][Math]::Max(1.6, $d * 0.15)
  $dotD = [single][Math]::Max(2.0, $d * 0.17)
  $trackPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(70, 70, 70), $trackW)
  $G.DrawEllipse($trackPen, ($X + 1), ($Y + 1), $box, $box)
  $trackPen.Dispose()
  $pct = [double]$script:TierPercent
  if ($pct -lt 0) { $pct = 0 }
  if ($pct -gt 100) { $pct = 100 }
  if ($pct -gt 0) {
    $arcPen = New-Object System.Drawing.Pen($script:TierRingColor, $arcW)
    $arcPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $arcPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $G.DrawArc($arcPen, ($X + 1), ($Y + 1), $box, $box, -90, [single](360 * $pct / 100))
    $arcPen.Dispose()
  }
  $dotBrush = New-Object System.Drawing.SolidBrush($script:TierRingColor)
  $G.FillEllipse($dotBrush, [single]($X + ($W / 2) - ($dotD / 2)), [single]($Y + ($H / 2) - ($dotD / 2)), $dotD, $dotD)
  $dotBrush.Dispose()
}
$ringTier.Add_Paint({
  param($sender, $e)
  Draw-TierRing -G $e.Graphics -X 0 -Y 0 -W $sender.Width -H $sender.Height
})

# 顶部标题栏下方的分隔线（Win11 卡片式分层）
$divider = New-Label -X 0 -Y 32 -W 300 -H 1 -Text '' -Size 8
$divider.BackColor = $dividerColor

# 连接状态点：两页都显示，平时是绿色，离线时变红
$lblStatusDot = New-Label -X 168 -Y 11 -W 18 -H 14 -Text '●' -Size 8 -Color $okColor
$lblStatusDot.TextAlign = 'MiddleLeft'

$form.Controls.Remove($lblHint)

# 第一页 = 账户余额（余额放第一页），第二页 = 用量
$script:AccountControls = @($lblTitle2, $lblBalTag, $lblBalanceBig, $lblPriceTag, $lblPriceModel, $lblPriceDetail, $lblTierElapsed, $ringTier)
$script:UsageControls   = @($lblTitle, $lblTotalTag, $lblTotal, $lblTodayTag, $lblToday, $lblConvCost)
# 当前页要显示哪些控件。除了给 Apply-Page 用，-Preview 离屏合成时也靠它判断"这个控件该不该画"——
# 窗口没真正显示时 Control.Visible 一律返回 $false（GetState 也未必靠得住），
# 只有这份名单是准的（踩过：整张预览图只剩底色）。
$script:PageControls = if ($script:Page -eq 1) { $script:AccountControls } else { $script:UsageControls }

# 一开始就只显示记住的那一页，避免两页标签叠在一起闪一下
if ($script:Page -eq 1) {
  foreach ($c in $script:UsageControls) { $c.Visible = $false }
} else {
  foreach ($c in $script:AccountControls) { $c.Visible = $false }
}

$tooltip = New-Object System.Windows.Forms.ToolTip
$tooltip.AutoPopDelay = 20000
$tooltip.InitialDelay = 300
$tooltip.ReshowDelay = 100

# 左上角应用标记：强调色圆角小方块（Win11 图标风格）
$mark = New-Object System.Windows.Forms.Panel
$mark.Location = New-Object System.Drawing.Point(12, 11)
$mark.Size = New-Object System.Drawing.Size(12, 12)
$mark.BackColor = $bgColor
$form.Controls.Add($mark)
$mark.Add_Paint({
  param($sender, $e)
  $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $path = New-RoundedPath -X 0.5 -Y 0.5 -W ($sender.Width - 1) -H ($sender.Height - 1) -R 3
  $brush = New-Object System.Drawing.SolidBrush($accentColor)
  $e.Graphics.FillPath($brush, $path)
  $brush.Dispose(); $path.Dispose()
})

# 右上角关闭按钮：Win11 悬停时是圆角红底
$script:CloseHover = $false
$btnClose = New-Object System.Windows.Forms.Panel
$btnClose.Location = New-Object System.Drawing.Point(272, 6)
$btnClose.Size = New-Object System.Drawing.Size(22, 22)
$btnClose.BackColor = $bgColor
$btnClose.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnClose)
$closeFont = New-Object System.Drawing.Font($uiFont, (9 * $script:FontScale), [System.Drawing.FontStyle]::Regular)
$btnClose.Add_Paint({
  param($sender, $e)
  $g = $e.Graphics
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  if ($script:CloseHover) {
    $path = New-RoundedPath -X 0 -Y 0 -W $sender.Width -H $sender.Height -R 4
    $brush = New-Object System.Drawing.SolidBrush($closeHoverFill)
    $g.FillPath($brush, $path)
    $brush.Dispose(); $path.Dispose()
  }
  $sf = New-Object System.Drawing.StringFormat
  $sf.Alignment = [System.Drawing.StringAlignment]::Center
  $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
  $textBrush = New-Object System.Drawing.SolidBrush($pillTextCol)
  $g.DrawString('✕', $closeFont, $textBrush, (New-Object System.Drawing.RectangleF(0, 0, $sender.Width, $sender.Height)), $sf)
  $textBrush.Dispose(); $sf.Dispose()
})
$btnClose.Add_MouseEnter({ $script:CloseHover = $true; $btnClose.Invalidate() })
$btnClose.Add_MouseLeave({ $script:CloseHover = $false; $btnClose.Invalidate() })
$btnClose.Add_Click({ $form.Close() })

# 右上角的圆角切换按钮（用量页 ⇄ 账户页）
$pill = New-Object System.Windows.Forms.Panel
$pill.Location = New-Object System.Drawing.Point(184, 6)
$pill.Size = New-Object System.Drawing.Size(84, 22)
$pill.BackColor = $bgColor
$pill.Cursor = [System.Windows.Forms.Cursors]::Hand
$pillFont = New-Object System.Drawing.Font($uiFont, (8.5 * $script:FontScale), [System.Drawing.FontStyle]::Regular)
$form.Controls.Add($pill)
$pill.Add_Paint({
  param($sender, $e)
  $g = $e.Graphics
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  # Win11 胶囊按钮：全圆角 + 极淡描边
  $path = New-RoundedPath -X 0.5 -Y 0.5 -W ($sender.Width - 1) -H ($sender.Height - 1) -R (($sender.Height - 1) / 2)
  $fillColor = $pillFill
  if ($script:PillHover) { $fillColor = $pillHoverFill }
  $fill = New-Object System.Drawing.SolidBrush($fillColor)
  $g.FillPath($fill, $path)
  $pen = New-Object System.Drawing.Pen($pillBorder, 1)
  $g.DrawPath($pen, $path)
  $sf = New-Object System.Drawing.StringFormat
  $sf.Alignment = [System.Drawing.StringAlignment]::Center
  $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
  $textBrush = New-Object System.Drawing.SolidBrush($pillTextCol)
  $g.DrawString($script:PillText, $pillFont, $textBrush, (New-Object System.Drawing.RectangleF(0, 0, $sender.Width, $sender.Height)), $sf)
  $fill.Dispose(); $pen.Dispose(); $textBrush.Dispose(); $sf.Dispose(); $path.Dispose()
})
$pill.Add_Click({ Switch-Page })
$pill.Add_MouseEnter({ $script:PillHover = $true; $pill.Invalidate() })
$pill.Add_MouseLeave({ $script:PillHover = $false; $pill.Invalidate() })
try { $tooltip.SetToolTip($pill, '在「用量」与「账户余额 / 价格」两页之间切换（也可以右键菜单切换）') } catch { }

function Format-Num {
  param($Value)
  $n = [double]$Value
  if ($n -ge 1000000) { return ('{0:N2}M' -f ($n / 1000000)) }
  if ($n -ge 100000) { return ('{0:N1}k' -f ($n / 1000)) }
  return ('{0:N0}' -f $n)
}

function Format-Money {
  param($Currency, $Value)
  $symbol = switch ($Currency) { 'CNY' { '¥' } 'USD' { '$' } default { $Currency } }
  # 货币符号（¥ / $）紧贴数字；只有字母代码（CNY、USD 这类）才补一个空格，
  # 否则 config.json 里的 currency = "¥" 会渲染成 "¥ 0.10"，和余额那行 "¥7.13" 不一致
  $sep = if ([string]$symbol -match '^[A-Za-z]{2,}$') { ' ' } else { '' }
  return ('{0}{1}{2}' -f $symbol, $sep, $Value)
}

function Format-Price {
  param($Value)
  $n = [double]$Value
  if ($n -ge 1) { return ('{0:0.##}' -f $n) }
  return ('{0:0.####}' -f $n)
}

# 成本可能小到 0.0000x，按数量级决定小数位
function Format-Cost {
  param($Currency, $Value)
  if ($null -eq $Value) { return '—' }
  $v = [double]$Value
  if ($v -eq 0) { return (Format-Money $Currency '0') }
  $text = '{0:N4}' -f $v
  if ([math]::Abs($v) -lt 0.01) { $text = '{0:N6}' -f $v }
  return (Format-Money $Currency $text)
}

# 倒计时用的时长（秒 → HH:MM:SS）。超过一天的段就直接写"X天HH:MM:SS"，
# 免得"空闲时段剩余 122:00:00"这种读不出意思。
function Format-Countdown {
  param($Seconds)
  $s = [int][Math]::Max(0, [Math]::Floor([double]$Seconds))
  $days = [int][Math]::Floor($s / 86400)
  $s = $s % 86400
  $hh = [int][Math]::Floor($s / 3600)
  $mm = [int][Math]::Floor(($s % 3600) / 60)
  $ss = $s % 60
  if ($days -gt 0) { return ('{0}天{1:00}:{2:00}:{3:00}' -f $days, $hh, $mm, $ss) }
  return ('{0:00}:{1:00}:{2:00}' -f $hh, $mm, $ss)
}

# 把 /__stats 里的 peakWindow（当前时段的起止）换算成界面上要的那几样：
#   还有多久结束、已经过了百分之多少、起止两端的本地时间（给悬停提示用）
# 拿不到 peakWindow（例如代理是 --force-peak 起的，本来就没有真实起止）就返回 $null，
# 界面上会退回"只显示当前时段名"，不会空着。
function Get-TierProgress {
  param($Stats)
  if (-not $Stats -or -not $Stats.peakWindow) { return $null }
  try {
    $w = $Stats.peakWindow
    $startDt = [datetimeoffset]::FromUnixTimeMilliseconds([int64]$w.startAt).LocalDateTime
    $endDt = [datetimeoffset]::FromUnixTimeMilliseconds([int64]$w.endAt).LocalDateTime
    # 倒计时优先用代理给的 remainMs：它是"取快照那一刻"的剩余量，
    # 这样 -Preview 塞一份固定的 peakWindow 时也能显示出那个秒数（用 endAt 减当前时间会算出 0）。
    $remain = $null
    if ($null -ne $w.remainMs) { try { $remain = [double]$w.remainMs / 1000.0 } catch { $remain = $null } }
    if ($null -eq $remain -or $remain -lt 0) { $remain = ($endDt - [datetime]::Now).TotalSeconds }
    $pct = [double]$w.percent
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    $tier = if ($w.peak) { '高峰' } else { '空闲' }
    return @{
      peak = [bool]$w.peak
      tier = $tier
      text = ('{0}时段剩余 {1}' -f $tier, (Format-Countdown $remain))
      # 这一行右边只剩 66px（后面还跟着 18px 的进度圆环），写"空闲已过 86%"实测要 96px，
      # 尾巴会被窗口右边缘啃掉（125% 缩放下更宽）。所以屏上只写"已过 86%"，
      # 带时段名的完整说法放在悬停提示里（见 Update-Ui 里拼 $tip 的那段）。
      elapsedText = ('已过 {0}%' -f [int][Math]::Round($pct))
      percent = $pct
      range = ('{0} → {1}' -f $startDt.ToString('MM-dd HH:mm'), $endDt.ToString('MM-dd HH:mm'))
    }
  } catch { return $null }
}

# 进度圆环的显示状态（只有百分比变了才重画；-1 表示"没有进度可画"）
function Set-TierRing {
  param([double]$Percent, [bool]$Visible, [bool]$Peak)
  $script:TierRingColor = if ($Peak) { $peakColor } else { $idleColor }
  $script:TierRingVisible = $Visible
  try { if ($ringTier.Visible -ne $Visible) { $ringTier.Visible = $Visible } } catch { }
  if (-not $Visible) { $script:TierPercent = -1; return }
  $rounded = [Math]::Round($Percent, 1)
  if ($rounded -ne $script:TierPercent) {
    $script:TierPercent = $rounded
    try { $ringTier.Invalidate() } catch { }
  }
}

function Update-Ui {
  if (-not $script:Stats) {
    $lblStatusDot.ForeColor = $badColor
    $lblTitle.ForeColor = $badColor
    $lblTitle2.ForeColor = $badColor
    # 离线：数字位换成小号灰破折号，别让 20pt 的 "—" 看起来像一条绿/红粗线
    $lblTotal.Text = '—'
    $lblTotal.Font = $fontOff
    $lblTotal.ForeColor = $mutedColor
    $lblToday.Text = '—'
    $lblToday.Font = $fontOff
    $lblToday.ForeColor = $mutedColor
    $lblConvCost.Text = ''
    $lblConvCost.ForeColor = $mutedColor
    $lblBalanceBig.Text = '—'
    $lblBalanceBig.Font = $fontOff
    $lblBalanceBig.ForeColor = $mutedColor
    $lblPriceModel.Text = "代理未运行 · 端口 $script:Port"
    $lblPriceModel.ForeColor = $badColor
    $lblPriceDetail.Text = '启动代理后这里会显示时段进度'
    $lblPriceDetail.ForeColor = $mutedColor
    # 时段进度这一行和圆环在离线时没有意义，藏起来（否则会留着上一次的数字）
    Set-TierRing -Percent -1 -Visible $false -Peak $false
    $lblTierElapsed.Text = ''
    $lblTierElapsed.Visible = $false
    return
  }
  $stats = $script:Stats
  $t = $stats.totals
  $cur = ''
  if ($stats.cost) { $cur = $stats.cost.currency }
  $lblTitle.ForeColor = $titleColor
  $lblTitle2.ForeColor = $titleColor
  if ($script:Online) { $lblStatusDot.ForeColor = $okColor } else { $lblStatusDot.ForeColor = $badColor }

  # ================= 第 1 页：用量（只显示总用量与今日用量） =================
  # 数字 = 经代理统计的流量 + DSH 会话自身的用量（启动时从 DSH 投影缓存读取一次）
  $proxyTotal = $t.total
  $proxyToday = 0
  $proxyTodayReq = 0
  if ($stats.today) {
    $proxyToday = $stats.today.total
    $proxyTodayReq = $stats.today.requests
  }
  $showTotal = $proxyTotal
  $showToday = $proxyToday
  $dshTotal = 0
  $dshToday = 0
  $dshSessions = 0
  $dshInfo = $null
  if ($stats.combined) {
    $showTotal = $stats.combined.total
    $showToday = $stats.combined.today
    $dshTotal = $stats.combined.dshTotal
    $dshToday = $stats.combined.dshToday
  }
  if ($stats.dshUsage) {
    $dshInfo = $stats.dshUsage
    $dshSessions = $dshInfo.sessionCount
  }

  $mark = ''
  if ($t.estimated -gt 0 -and $t.requests -eq $t.estimated -and $dshTotal -eq 0) { $mark = '≈' }
  $lblTotal.Font = $fontBig
  $lblTotal.ForeColor = $accentColor
  $lblTotal.Text = ('{0}{1}' -f $mark, (Format-Num $showTotal))

  # ── 本轮对话：最近有更新的那个 DSH 会话（数据来自代理的 /__conversation）──
  $conv = $stats.conversation
  $convTitle = ''
  $convTok = 0
  $convCostText = ''
  $convCostLine = '花费 —'
  $convError = ''
  if ($conv -and $conv.ok) {
    if ($conv.title) { $convTitle = [string]$conv.title }
    if ($conv.tokens) { $convTok = [double]$conv.tokens.total }
    if ($null -ne $conv.cost) {
      $convCostText = Format-Money ([string]$conv.costCurrency) ([string]([Math]::Round([double]$conv.cost, 2)))
      $tier = if ($conv.costPeak) { '高峰价' } else { '空闲价' }
      $convCostLine = ('花费 {0}（{1} · {2}）' -f $convCostText, $tier, [string]$conv.costModel)
    } else {
      $convCostLine = '花费 未收录价格'
    }
  } elseif ($conv -and $conv.error) {
    $convError = [string]$conv.error
  }

  $lblToday.Font = $fontMid
  $lblToday.ForeColor = $textColor
  $numText = Format-Num $convTok
  $lblToday.Text = $numText
  # 花费：小一号灰字，紧跟数字右边、同一行。
  # X 按数字的实际宽度算（数字长短差别很大），竖直方向用数字字体的行高对齐，
  # 这样数字从 999 涨到 432.73M 时花费会跟着右移，不会压字也不会飘走。
  $lblConvCost.Font = $fontSmall
  $lblConvCost.ForeColor = $mutedColor
  $lblConvCost.Text = $convCostText
  $uiS = $script:UiScale
  $padL = [int][Math]::Round(12 * $uiS)
  $rightEdge = [int][Math]::Round(288 * $uiS)
  $numSize = [System.Windows.Forms.TextRenderer]::MeasureText($numText, $lblToday.Font)
  $costW = [System.Windows.Forms.TextRenderer]::MeasureText($convCostText, $fontSmall).Width
  $costX = $padL + $numSize.Width + [int][Math]::Round(8 * $uiS)
  if (($costX + $costW) -gt $rightEdge) { $costX = $rightEdge - $costW }   # 极端长的数字：贴右边，别跑出窗口
  if ($costX -lt $padL) { $costX = $padL }
  # 竖直方向跟着"本轮对话用量"那个数字走（Fit-Rows 可能把它往上收了一点）
  $lblConvCost.Location = New-Object System.Drawing.Point($costX, $lblToday.Location.Y)
  $lblConvCost.Size = New-Object System.Drawing.Size(($costW + [int][Math]::Round(4 * $uiS)), $numSize.Height)

  # 其余明细都收进悬停提示，界面上只留两个数字
  $todayCost = 0
  if ($stats.today -and $stats.today.costKnown) { $todayCost = $stats.today.cost }
  $avgCostText = '—'
  if ($stats.cost -and $stats.cost.known -and $t.requests -gt 0) {
    $avgCostText = Format-Cost $cur ($stats.cost.total / $t.requests)
  }
  $rate = 0
  if ($stats.rate) { $rate = $stats.rate.completionPerSec }

  $dshBlock = "`n—— DSH 会话（启动时读取）——`n没有读到 DSH 会话用量"
  if ($dshInfo -and -not $dshInfo.error -and $dshTotal -gt 0) {
    $dshTok = $dshInfo.totals
    $dshBlock = ("`n—— DSH 会话（启动时读取）——`n{0} 个会话 · 合计 {1} tok`n输入 {2} · 缓存读 {3} · 输出 {4}" -f $dshSessions, (Format-Num $dshTotal), (Format-Num $dshTok.uncachedInputTokens), (Format-Num $dshTok.cacheReadTokens), (Format-Num $dshTok.outputTokens))
  } elseif ($dshInfo -and $dshInfo.error) {
    $dshBlock = "`n—— DSH 会话 ——`n" + [string]$dshInfo.error
  }

  $tooltip.SetToolTip($lblTotal, ("总 TOKEN 用量 {0} = 经代理 {1} + DSH 会话 {2}`n—— 经代理统计 ——`n请求 {3} 次 · 输入 {4} · 输出 {5}{6}`n—— 成本 ——`n累计使用 {7} · 均次 {8}`n本次 {9} · {10} tok/s`n`n右键「刷新 DSH 用量」可重新读取" -f (Format-Num $showTotal), (Format-Num $proxyTotal), (Format-Num $dshTotal), $t.requests, (Format-Num $t.prompt), (Format-Num $t.completion), $dshBlock, (Format-Cost $cur $stats.cost.total), $avgCostText, (Format-Cost $cur $stats.lastCost), $rate))

  $convName = if ($convTitle) { "「$convTitle」" } else { '（未命名）' }
  $convErrLine = if ($convError) { "`n读取失败：$convError" } else { '' }
  $convTokLine = ''
  if ($conv -and $conv.ok -and $conv.tokens) {
    $convTokLine = ("`n未命中输入 {0} · 命中缓存 {1} · 输出 {2}" -f (Format-Num $conv.tokens.uncachedInputTokens), (Format-Num $conv.tokens.cacheReadTokens), (Format-Num $conv.tokens.outputTokens))
  }
  $peakWhyText = ''
  if ($stats.peakReason) {
    $tierName = if ($stats.peakNow) { '高峰' } else { '空闲' }
    $peakWhyText = ("`n当前时段：{0}（{1}）" -f $tierName, [string]$stats.peakReason)
  }
  $convTip = ("本轮对话 {0} = 最近有更新的那个 DSH 会话`n用量 {1} tok{2}`n{3}{4}{5}`n`n花费按「当前时段」的价估算（高峰/空闲切换会变），`n不是账单金额；会话文件更新时自动跟着变。" -f $convName, (Format-Num $convTok), $convTokLine, $convCostLine, $convErrLine, $peakWhyText)
  $tooltip.SetToolTip($lblToday, $convTip)
  $tooltip.SetToolTip($lblConvCost, $convTip)

  $tooltip.SetToolTip($lblTotalTag, ("总用量 = 经代理统计 + DSH 会话合计`n今日（经代理 {0} tok / {1} 次 + DSH {2} tok）花费 {3}" -f (Format-Num $proxyToday), $proxyTodayReq, (Format-Num $dshToday), (Format-Cost $cur $todayCost)))

  # ================= 第 2 页：账户（只显示余额与当前价格） =================
  $bal = $stats.balance
  if ($bal -and -not $bal.error -and $bal.balances -and $bal.balances.Count -gt 0) {
    $first = $bal.balances[0]
    $lblBalanceBig.Font = $fontBig
    $lblBalanceBig.Text = (Format-Money $first.currency $first.total)
    # 余额提醒：低于设定值（且开关开着）就把这个数字画成红色。
    # 判断用的就是屏幕上显示的那个数（balances[0].total），所以"看着是红的"和
    # "它确实低于你设的那个值"永远是一致的，不会出现"数字看着没到线却红了"的疑惑。
    $lowBalance = $false
    if ($script:BalanceWarnEnabled -and $script:BalanceWarnThreshold -gt 0) {
      try { $lowBalance = ([double]$first.total -lt $script:BalanceWarnThreshold) } catch { $lowBalance = $false }
    }
    $lblBalanceBig.ForeColor = if ($lowBalance) { $warnColor } else { $okColor }
    $when = ''
    if ($bal.fetchedAt) {
      try { $when = ([datetimeoffset]::FromUnixTimeMilliseconds([int64]$bal.fetchedAt)).LocalDateTime.ToString('HH:mm:ss') } catch { }
    }
    $srcShort = [string]$bal.keySource
    if ($srcShort -match 'config') { $srcShort = '配置文件' }
    elseif ($srcShort -match '环境变量') { $srcShort = '环境变量' }
    elseif ($srcShort -match '最近一次请求') { $srcShort = '请求自动带' }
    $detail = ($bal.balances | ForEach-Object { '{0} 总额 {1}（赠金 {2} / 充值 {3}）' -f $_.currency, $_.total, $_.granted, $_.toppedUp }) -join "`n"
    $detail += ("`nKey {0} · {1}" -f $bal.keyMasked, $srcShort)
    if ($when) { $detail += (' · ' + $when + ' 更新') }
    if ($stats.cost -and $stats.cost.known) { $detail += ("`n累计使用 " + (Format-Cost $cur $stats.cost.total)) }
    if ($lowBalance) {
      $detail += ("`n⚠ 余额已低于提醒值 {0}（启动器「设置 · 余额提醒」里可以改，也可以关掉）" -f
        (Format-Money $first.currency ('{0:0.##}' -f $script:BalanceWarnThreshold)))
    }
    $detail += "`n右键「刷新余额」可立即更新"
    $tooltip.SetToolTip($lblBalanceBig, $detail)
  } elseif ($bal -and $bal.error) {
    $lblBalanceBig.Text = '未获取'
    $lblBalanceBig.Font = $fontMid
    $lblBalanceBig.ForeColor = $badColor
    $tooltip.SetToolTip($lblBalanceBig, ([string]$bal.error + "`n右键 →「刷新余额」可重试"))
  } else {
    $lblBalanceBig.Text = '查询中…'
    $lblBalanceBig.Font = $fontMid
    $lblBalanceBig.ForeColor = $mutedColor
  }

  # 当前价格：空闲时段=蓝色，高峰时段=红色
  $price = $stats.price
  # 这一行（第 4 行）原本是"输入 ¥1（命中 ¥0.02）· 输出 ¥4"这串单价明细，
  # 现在按用户要求换成"当前时段还剩多久 + 已经过了百分之多少 + 进度圆环"；
  # 单价明细全都挪进「当前价格」和这一行的悬停提示里，一个字都没丢。
  $tier = Get-TierProgress $stats
  if ($price) {
    $lblPriceModel.Text = ('{0} · {1}时段' -f $price.model, $price.tierText)
    if ($price.peak) { $lblPriceModel.ForeColor = $peakColor } else { $lblPriceModel.ForeColor = $idleColor }
    if ($tier) {
      # 倒计时那一行用 8.5pt（默认字号，8pt 会显小），宽度固定回 180：
      # 右边要让出两格给"已过 xx%"和进度圆环
      try { $lblPriceDetail.Font = $fontSmall } catch { }
      try { $lblPriceDetail.Width = 180 } catch { }
      $lblPriceDetail.Text = $tier.text
      $lblPriceDetail.ForeColor = if ($tier.peak) { $peakColor } else { $idleColor }
      $lblTierElapsed.Text = $tier.elapsedText
      $lblTierElapsed.ForeColor = if ($tier.peak) { $peakColor } else { $idleColor }
      $lblTierElapsed.Visible = $true
      Set-TierRing -Percent $tier.percent -Visible $true -Peak $tier.peak
    } else {
      # 拿不到时段起止（例如代理是 --force-peak / --force-offpeak 起的）：退回显示单价明细，不留空。
      # ⚠️ 这一行比倒计时长（7.5pt 实测 199px，8.5pt 要 225px），而"倒计时"那套布局只给它 180px。
      # 所以回退时：字号降到 7.5pt **并且**把宽度放回 244 —— 这时右边没有百分比和圆环，占得住。
      $lblPriceDetail.Font = $fontTiny
      try { $lblPriceDetail.Width = 244 } catch { }
      $lblPriceDetail.Text = ('输入 {0}{1}（命中 {2}{3}）· 输出 {4}{5}' -f $price.currency, (Format-Price $price.inputMiss), $price.currency, (Format-Price $price.inputHit), $price.currency, (Format-Price $price.output))
      if ($lblPriceDetail.Text.Length -gt 42) { $lblPriceDetail.Text = $lblPriceDetail.Text.Substring(0, 41) + '…' }
      $lblPriceDetail.ForeColor = $textColor
      $lblTierElapsed.Text = ''
      $lblTierElapsed.Visible = $false
      Set-TierRing -Percent -1 -Visible $false -Peak ([bool]$price.peak)
    }
    # 「当前价格」的悬停提示：按用户要求**只留单价明细 + 获取时间 + 下一次获取时间**。
    # 原来这里还塞了"当前为高峰/空闲""为什么是高峰/空闲""本段时段起止""下次变价""节假日表""价格来源"，
    # 全删了——档位界面上已经用颜色写着了，重复一遍只会让提示变长。
    # 时段相关的那几句挪到「时段进度」那一行的提示里（见下面 $tierTip），那条提示上不再重复单价。
    $whenText = ''
    if ($stats.pricingFetchedAt) {
      # ⚠️ 用 pricingFetchedAt 这个毫秒时间戳格式化，别直接用 pricingFetchedText：
      # 那串"10-05 15:46 更新"是给旧的"价格来源"那行拼的，格式固定、也带"更新"字样。
      try { $whenText = '获取时间：' + ([datetimeoffset]::FromUnixTimeMilliseconds([int64]$stats.pricingFetchedAt)).LocalDateTime.ToString('MM-dd HH:mm') } catch { }
    }
    if (-not $whenText -and $stats.pricingFetchedText) { $whenText = '获取时间：' + [string]$stats.pricingFetchedText }
    $nextText = ''
    if ($stats.pricingNextRefreshAt) {
      # ⚠️ 必须是双引号：单引号的 '`n' 是**字面量**"`n"，会原样显示在提示里（踩过）
      try { $nextText = "`n下次获取时间：" + ([datetimeoffset]::FromUnixTimeMilliseconds([int64]$stats.pricingNextRefreshAt)).LocalDateTime.ToString('MM-dd HH:mm') } catch { }
    }
    $errText = ''
    if ($stats.pricingError) { $errText = "`n" + [string]$stats.pricingError }
    # ⚠️ 这行格式串有 7 个占位符 {0}..{6}，后面必须跟满 7 个参数——
    # 少一个 PowerShell 的 -f 会直接抛 FormatException，表现是"提示永远不显示"（外面看着一切正常）。
    $tip = ("每 100 万 token：`n输入(未命中缓存) {0}{1}`n输入(命中缓存) {2}{3}`n输出 {4}{5}`n{6}{7}{8}" -f $price.currency, (Format-Price $price.inputMiss), $price.currency, (Format-Price $price.inputHit), $price.currency, (Format-Price $price.output), $whenText, $nextText, $errText)
    $tooltip.SetToolTip($lblPriceModel, $tip)
    # 时段进度那一行（含圆环）用单独一条提示：当前时段与原因、本段起止、还剩多久、下次变价、节假日表。
    # 只有在"界面真的显示时段进度"时才挂这条（$tier 为空时那一行显示的是单价明细，挂时段提示就对不上了）。
    if ($tier) {
      $tierTip = ''
      if ($peakWhyText) { $tierTip = $peakWhyText.TrimStart("`n") } else { $tierTip = '当前时段：' + $tier.tier }
      $tierTip += ("`n本段时段：{0}（已过 {1}%）" -f $tier.range, [int][Math]::Round($tier.percent))
      if ($lblTierElapsed.Visible) { $tierTip += (" · 剩余 {0}" -f $tier.text) }
      if ($stats.peakNextChangeAt) {
        try { $tierTip += "`n下次变价：" + ([datetimeoffset]::FromUnixTimeMilliseconds([int64]$stats.peakNextChangeAt)).LocalDateTime.ToString('MM-dd HH:mm') } catch { }
      }
      if ($stats.holidays -and $stats.holidays.label) { $tierTip += ("`n节假日表：" + [string]$stats.holidays.label) }
      $tooltip.SetToolTip($lblPriceDetail, $tierTip)
      $tooltip.SetToolTip($lblTierElapsed, $tierTip)
      $tooltip.SetToolTip($ringTier, $tierTip)
    } else {
      $tooltip.SetToolTip($lblPriceDetail, $tip)
      $tooltip.SetToolTip($lblTierElapsed, $tip)
      $tooltip.SetToolTip($ringTier, $tip)
    }
  } else {
    $lblPriceModel.Text = '未收录该模型价格'
    $lblPriceModel.ForeColor = $peakColor
    $lblPriceDetail.Text = '可在 config.json 的 pricing 里补充'
    $lblPriceDetail.ForeColor = $mutedColor
    $lblTierElapsed.Text = ''
    $lblTierElapsed.Visible = $false
    Set-TierRing -Percent -1 -Visible $false -Peak $false
  }
}

# ════════════════════════════════════════════════════════════════════════
#  性能监控小窗（主悬浮窗下方那个等宽副窗）
#  开关与显示内容来自 config.json 的 monitor 段（启动器「设置 · 性能监控」页写入）。
#  设计约束（沿用主窗的既有结论，别再引入 DPI 缩放）：
#    · 宽度固定 300（与主窗等宽），高度按选中的行数算；字号固定。
#    · 行顺序固定 cpu → memory → battery；没选中的行不创建，窗口相应变矮。
#    · 不响应鼠标：主窗在拖动/折叠时它跟着变，但它自己不接收点击（避免抢焦点、挡住主窗）。
# ════════════════════════════════════════════════════════════════════════
$MonitorW = 300
$script:MonitorPad = 12
$script:MonitorRowH = 26
$script:MonitorGap = 8
$MonitorHeaderH = 18      # 标题行高度（标题在 y=9 开始）

$script:MonitorKeys = @()      # 本窗实际显示的行（顺序固定）


function Get-MonitorHeight {
  # 标题行 + 每行内容 + 上下留白 + 行间距；高度必须是偶数，免得边框画在半像素上
  $rows = @($script:MonitorKeys).Count
  if ($rows -lt 1) { $rows = 1 }
  $h = 28 + ($rows * $script:MonitorRowH) + (($rows - 1) * $script:MonitorGap) + 2 * $script:MonitorPad
  if ($h % 2 -ne 0) { $h++ }
  return [int]$h
}

function Build-MonitorWindow {
  # 按当前选中的行重建小窗（先拆旧的，避免重复调用后留下多个窗口）
  try { if ($script:MonitorWin) { $script:MonitorWin.Close(); $script:MonitorWin.Dispose() } } catch { }  $script:MonitorWin = $null
  # ⚠️ 旧窗已经被销毁了，显示状态必须一起清掉：否则下面 Sync-MonitorVisibility 会以为
  # "还显示着呢"，新建的这个小窗就永远不会 Show()（改完设置项后小窗会一直不出来）。
  $script:MonitorShown = $false
  $script:MonDot = $null
  $script:MonitorRows = @{}
  $script:MonitorKeys = @()
  if (-not $script:MonitorEnabled) { return }
  if (@($script:MonitorItems).Count -eq 0) { return }

  $mf = New-Object System.Windows.Forms.Form
  $mf.FormBorderStyle = 'None'
  $mf.StartPosition = 'Manual'
  $mf.TopMost = $true
  $mf.ShowInTaskbar = $false
  $mf.BackColor = $bgColor
  # ⚠️ 必须关掉 WinForms 的自动缩放：Form 默认 AutoScaleMode=Font，
  # 无边框小窗在 120 DPI 下会被它按字体差异缩放（实测 300x136 变成 267x68，文字全被裁），
  # 而且主窗、这个窗、标签控件各缩一次，比例还不一致。主窗是脚本手动摆的控件，所以没这问题。
  $mf.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
  # ClientSize 先给个占位值，控件摆完之后按实际行数收紧（见函数末尾）
  $mf.ClientSize = New-Object System.Drawing.Size($MonitorW, (Get-MonitorHeight))
  $mf.Text = 'Token 性能监控'
  $mf.Opacity = 0.98
  # 不接收鼠标：点上去等于点在底下的东西上，不会抢走主窗的拖动
  $mf.Enabled = $true
  try { $mf.SetStyle([System.Windows.Forms.ControlStyles]::Selectable, $false) } catch { }

  # 边框：和主窗同款圆角描边（自己画，WinForms 控件没有圆角属性）
  $mf.Add_Paint({
    param($sender, $e)
    Paint-MonitorSurface -G $e.Graphics -W $sender.ClientSize.Width -H $sender.ClientSize.Height
  })

  # 标题行：左侧一句话 + 右侧状态点（绿=代理在线）
  $title = New-Label -HostForm $mf -X $script:MonitorPad -Y 9 -W 150 -H 18 -Text '性能监控' -Size 8 -Color $mutedColor
  $dot = New-Label -HostForm $mf -X ($MonitorW - $script:MonitorPad - 12) -Y 12 -W 12 -H 12 -Text '●' -Size 8 -Color $mutedColor
  $dot.TextAlign = 'MiddleRight'
  $script:MonDot = $dot

  $y = $script:MonitorPad + $MonitorHeaderH
  foreach ($key in @($script:MonitorItems)) {
    $lblTag = New-Label -HostForm $mf -X $script:MonitorPad -Y $y -W 150 -H 18 -Text '—' -Size 8 -Color $mutedColor
    $lblVal = New-Label -HostForm $mf -X ($MonitorW - $script:MonitorPad - 180) -Y ($y - 2) -W 180 -H 20 -Text '—' -Size 10 -Color $textColor -Style Bold -FontFamily $numFont
    $lblVal.TextAlign = 'MiddleRight'
    $barY = $y + 19
    $script:MonitorRows[$key] = @{
      Tag = $lblTag; Val = $lblVal
      BarY = $barY; BarPct = -1.0; BarColor = $accentColor
    }
    $script:MonitorKeys += $key
    $y += $script:MonitorRowH + $script:MonitorGap
  }

  # 高度按摆完的行数收紧，最后一行下面不留空
  $need = ($y - $script:MonitorGap) + $script:MonitorPad
  if ($need -lt 60) { $need = 60 }
  if ($need % 2 -ne 0) { $need++ }
  $mf.ClientSize = New-Object System.Drawing.Size($MonitorW, [int]$need)

  $script:MonitorWin = $mf
  # 第一份后台采样（WMI：CPU 频率 / 电池瓦数）推迟 3 秒再要：
  # 建后台 runspace 那一下要 30~140ms，放在启动那会儿会把第一帧往后拖（用户反馈过"启动变慢"）。
  # 3 秒后窗口早就画好了，那点开销落在闲时。
  $script:MonitorNextWmiAt = [datetime]::Now.AddSeconds(3)
}

function Set-MonitorBar {
  param([string]$Key, [double]$Pct, [System.Drawing.Color]$Color)
  if (-not $script:MonitorRows.ContainsKey($Key)) { return }
  $row = $script:MonitorRows[$Key]
  $row.BarPct = $Pct
  $row.BarColor = $Color
}

function Paint-MonitorSurface {
  # 小窗的整块底色内容：圆角描边 + 每行底部的细进度条。
  # 抽成函数是因为 **-Preview 离屏合成时调不到控件的 OnPaint**（README 9.1 第 5 条），
  # 预览必须能直接调它，否则预览图里有文字没有边框和进度条。
  param($G, [int]$W, [int]$H)
  $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $radius = [int][Math]::Round(8 * $script:UiScale)
  $path = New-RoundedPath -X 0.5 -Y 0.5 -W ($W - 1) -H ($H - 1) -R $radius
  $pen = New-Object System.Drawing.Pen($borderColor, 1)
  $G.DrawPath($pen, $path)
  $pen.Dispose(); $path.Dispose()

  foreach ($key in @($script:MonitorKeys)) {
    $row = $script:MonitorRows[$key]
    if (-not $row) { continue }
    if ($null -eq $row.BarPct -or $row.BarPct -lt 0) { continue }
    $x = [single]$script:MonitorPad
    $y = [single]$row.BarY
    $bw = [single]($W - 2 * $script:MonitorPad)
    $track = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(58, 58, 58))
    $G.FillRectangle($track, $x, $y, $bw, 2)
    $track.Dispose()
    $pct = [double]$row.BarPct
    if ($pct -gt 100) { $pct = 100 }
    if ($pct -lt 0) { $pct = 0 }
    $fill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]$row.BarColor)
    $G.FillRectangle($fill, $x, $y, [single]($bw * $pct / 100.0), 2)
    $fill.Dispose()
  }
}

function Get-MonitorWorkArea {
  # 小窗所在屏幕的工作区（带缓存）。
  # 为什么缓存：Screen::FromPoint 单次要 0.25ms，而拖动时每次鼠标移动都要判一次边界；
  # 主窗中心还在缓存的那块屏幕里就继续用缓存，越界了（跨屏拖动）才重查一次。
  param([int]$CenterX, [int]$CenterY)
  if ($script:MonWa -eq $null -or $CenterX -lt $script:MonWaX0 -or $CenterX -gt $script:MonWaX1 -or
      $CenterY -lt $script:MonWaY0 -or $CenterY -gt $script:MonWaY1) {
    try {
      $scr = [System.Windows.Forms.Screen]::FromPoint([System.Drawing.Point]::new($CenterX, $CenterY))
      if (-not $scr) { $scr = [System.Windows.Forms.Screen]::PrimaryScreen }
      $script:MonWa = $scr.WorkingArea
      $script:MonWaX0 = [int]$script:MonWa.Left; $script:MonWaY0 = [int]$script:MonWa.Top
      $script:MonWaX1 = [int]$script:MonWa.Right; $script:MonWaY1 = [int]$script:MonWa.Bottom
    } catch { }
  }
  return $script:MonWa
}

function Move-MonitorToOwner {
  # 贴着主窗正下方（间距 8px）；下方放不下就翻到上方；上下都放不下时贴住工作区下边缘。
  # 拖动主窗时也会调它，所以小窗是跟手的，不用等下一个 tick。
  #
  # ⚠️ 这里是拖动热路径（每次鼠标移动都要走一遍），所以刻意避开了 PowerShell 的对象开销：
  #   · 用 SetBounds(x,y,w,h) 而不是 `Location = New-Object Point`：实测 0.17ms vs 0.65ms；
  #   · 工作区走缓存，不每次调 Screen::FromPoint（那一个调用单独就要 0.25ms）；
  #   · 调用方知道主窗刚挪到哪就传 -OwnerX/-OwnerY 进来，省掉一次 $form.Location 装箱。
  #   数字来自 经验\token-monitor\probe-move-cost.ps1。
  param([int]$OwnerX = [int]::MinValue, [int]$OwnerY = [int]::MinValue)
  $m = $script:MonitorWin
  if (-not $m) { return }
  if ($OwnerX -eq [int]::MinValue) { $OwnerX = $form.Location.X; $OwnerY = $form.Location.Y }
  $mw = $m.Width
  $mh = $m.Height
  $gap = $script:MonitorGap
  $tx = $OwnerX
  $ty = $OwnerY + $form.Height + $gap
  [void](Get-MonitorWorkArea -CenterX ($OwnerX + [int]($form.Width / 2)) -CenterY ($OwnerY + [int]($form.Height / 2)))
  if ($script:MonWa -ne $null) {
    $wal = $script:MonWaX0; $wat = $script:MonWaY0; $war = $script:MonWaX1; $wab = $script:MonWaY1
    if (($ty + $mh) -gt $wab) {
      $above = $OwnerY - $mh - $gap
      if ($above -ge $wat) { $ty = $above }
      else { $ty = [int]($wab - $mh) }
    }
    if ($ty -lt $wat) { $ty = $wat }
    if ($tx -lt $wal) { $tx = $wal }
    if (($tx + $mw) -gt $war) { $tx = [int]($war - $mw) }
  }
  try { $m.SetBounds($tx, $ty, $mw, $mh) } catch { }
}

function Update-MonitorRows {
  # 把 $script:Monitor* 里已经算好的值写进各行的标签与进度条。
  # 单独抽出来是为了让 -Preview 能复用同一套排版（预览只填值、不采数据）。
  # 返回 $true = 确实有格子变了（调用方据此决定要不要整窗重绘）。
  $dirty = $false
  foreach ($key in @($script:MonitorKeys)) {
    $row = $script:MonitorRows[$key]
    if (-not $row) { continue }
    $tagBefore = [string]$row.Tag.Text
    $valBefore = [string]$row.Val.Text
    $barBefore = [double]$row.BarPct
    $colBefore = $row.BarColor
    switch ($key) {
      'cpu' {
        $row.Tag.Text = 'CPU'
        if ($null -ne $script:MonitorCpuPct) {
          $row.Val.Text = ('{0:0}%  {1:0.00} GHz' -f [double]$script:MonitorCpuPct, [double]$script:MonitorCpuGhz)
          $row.Val.ForeColor = $textColor
          $barCol = if ($script:MonitorCpuPct -ge 90) { $badColor } elseif ($script:MonitorCpuPct -ge 75) { [System.Drawing.Color]::FromArgb(255, 184, 77) } else { $accentColor }
          Set-MonitorBar -Key $key -Pct ([double]$script:MonitorCpuPct) -Color $barCol
        } else {
          $row.Val.Text = '—'
          $row.Val.ForeColor = $mutedColor
          Set-MonitorBar -Key $key -Pct -1 -Color $accentColor
        }
      }
      'memory' {
        $row.Tag.Text = '内存'
        $row.Val.Text = $script:MonitorMemText
        $row.Val.ForeColor = $textColor
        if ($script:MonitorMemPct -ge 0) { Set-MonitorBar -Key $key -Pct $script:MonitorMemPct -Color $accentColor }
        else { Set-MonitorBar -Key $key -Pct -1 -Color $accentColor }
      }
      'battery' {
        $row.Tag.Text = '电池功率'
        if ($script:MonitorAvail) {
          $stateText = '空闲'
          if ($script:MonitorBatState -eq 'charging') { $stateText = '充电' }
          elseif ($script:MonitorBatState -eq 'discharging') { $stateText = '放电' }
          elseif ($script:MonitorBatState -eq 'ac') { $stateText = '已接电源' }
          if ($script:MonitorBatText -eq '—') { $row.Val.Text = ('— · {0}' -f $stateText) }
          else { $row.Val.Text = ('{0} · {1}' -f $script:MonitorBatText, $stateText) }
          $row.Val.ForeColor = $textColor
          if ($script:MonitorBatPct -ge 0) {
            $batCol = if ($script:MonitorBatPct -le 20) { $badColor } else { $accentColor }
            Set-MonitorBar -Key $key -Pct $script:MonitorBatPct -Color $batCol
          } else {
            Set-MonitorBar -Key $key -Pct -1 -Color $accentColor
          }
        } else {
          $row.Val.Text = '—'
          $row.Val.ForeColor = $mutedColor
          Set-MonitorBar -Key $key -Pct -1 -Color $accentColor
        }
      }
    }
    # 文字或进度条真的变了才算"脏"（没变就不重绘，省下一次 GDI+ 整窗重画）
    if ([string]$row.Tag.Text -ne $tagBefore -or [string]$row.Val.Text -ne $valBefore) { $dirty = $true }
    elseif ([Math]::Abs([double]$row.BarPct - $barBefore) -ge 0.25 -or $row.BarColor.ToArgb() -ne $colBefore.ToArgb()) { $dirty = $true }
  }
  return $dirty
}

# ── 后台采样：把 WMI 那两项（CPU 频率 / 电池瓦数）搬出 UI 线程 ──
# 为什么必须搬：Get-CimInstance 单次要几十~几百毫秒，还要算上 CimCmdlets 模块的首次加载，
#   而它原先是在 800ms 的 tick 里**同步**跑的 —— 拖动时正好撞上，整个窗口就定住一下
#   （用户反馈的"不跟手"）；启动时那一次还会把第一帧往后拖。
# 做法：用同一个进程里的另一个 runspace 去查（不新开进程），tick 只负责把结果收下来。
#   结果用 JSON 字符串往回带：跨 runspace 传活对象容易出怪问题，字符串最稳。
$script:MonWmiCode = @'
$r = @{ cpuGhz = 0.0; maxMhz = 0.0; watts = 0.0; ok = $false }
try {
  $p = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop
  $m = [double]($p | Measure-Object -Property MaxClockSpeed -Maximum).Maximum
  if ($m -gt 0) { $r.maxMhz = $m }
} catch { }
try {
  $perf = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop
  $ratio = [double]$perf.PercentProcessorPerformance
  if ($r.maxMhz -gt 0 -and $ratio -gt 0) { $r.cpuGhz = $r.maxMhz / 1000.0 * $ratio / 100.0; $r.ok = $true }
  elseif ($perf.ProcessorFrequency) { $r.cpuGhz = [double]$perf.ProcessorFrequency / 1000.0; $r.ok = $true }
} catch { }
try {
  $bs = Get-CimInstance -Namespace 'root\WMI' -ClassName BatteryStatus -ErrorAction Stop | Select-Object -First 1
  if ($bs) {
    $chg = [double]$bs.ChargeRate / 1000.0
    $dis = [double]$bs.DischargeRate / 1000.0
    if ($bs.Charging) { $r.watts = $chg } elseif ($bs.Discharging) { $r.watts = $dis } else { $r.watts = [Math]::Max($chg, $dis) }
    $r.ok = $true
  }
} catch { }
$r | ConvertTo-Json -Compress
'@

function Start-MonitorWmiSample {
  # 起一轮后台采样（同一时刻只跑一个）。后台起不来就退化成"频率/瓦数显示 —"，30 秒后再试。
  if ($script:MonWmi) { return }
  if ([datetime]::Now -lt $script:MonWmiBackoffAt) { return }
  # 第一次要建后台 runspace（实测 30~140ms），正在拖窗口时先别干这事，免得顶掉一帧；
  # 下一轮 tick 再来（runspace 建好之后就不再花这个钱）。
  if (-not $script:MonWmiRunspace -and ($script:Pressing -or $script:Dragging)) {
    $script:MonitorNextWmiAt = [datetime]::Now.AddSeconds(1)
    return
  }
  try {
    if (-not $script:MonWmiRunspace) {
      $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
      $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
      $rs.Open()
      $script:MonWmiRunspace = $rs
    }
    # 复用同一个 PowerShell 实例：每轮新建一个要 8ms 左右，复用只要 1ms 级
    if (-not $script:MonWmiPS) {
      $ps = [System.Management.Automation.PowerShell]::Create()
      $ps.Runspace = $script:MonWmiRunspace
      $script:MonWmiPS = $ps
    }
    $script:MonWmiPS.Commands.Clear()
    [void]$script:MonWmiPS.AddScript($script:MonWmiCode)
    $script:MonWmi = @{ Handle = $script:MonWmiPS.BeginInvoke(); At = [datetime]::Now }
  } catch {
    try { if ($script:MonWmiPS) { $script:MonWmiPS.Dispose() } } catch { }
    try { if ($script:MonWmiRunspace) { $script:MonWmiRunspace.Dispose() } } catch { }
    $script:MonWmiPS = $null
    $script:MonWmiRunspace = $null
    $script:MonWmi = $null
    $script:MonWmiBackoffAt = [datetime]::Now.AddSeconds(30)
  }
}

function Stop-MonitorWmiSample {
  # 丢掉这一轮的后台管道（**runspace 留着**：它建一次要几十毫秒，下一轮还要用）
  $script:MonWmi = $null
  try { if ($script:MonWmiPS) { $script:MonWmiPS.Dispose() } } catch { }
  $script:MonWmiPS = $null
}

function Receive-MonitorWmiSample {
  # 后台跑完了就把结果收下来（返回 $true = 拿到新数据）；还没跑完就先放着。
  $a = $script:MonWmi
  if (-not $a) { return $false }
  if (-not $a.Handle.IsCompleted) {
    if (([datetime]::Now - $a.At).TotalSeconds -gt 8) { Stop-MonitorWmiSample }   # 卡太久就丢掉，下一轮到点重来
    return $false
  }
  $ok = $false
  try {
    $out = $script:MonWmiPS.EndInvoke($a.Handle)
    $json = [string]($out | Select-Object -Last 1)
    if ($json) {
      $r = $json | ConvertFrom-Json
      if ([double]$r.maxMhz -gt 0) { $script:MonitorCpuMaxGhz = [double]$r.maxMhz / 1000.0 }
      if ([double]$r.cpuGhz -gt 0) { $script:MonitorCpuGhz = [double]$r.cpuGhz }
      $script:MonitorBatWatts = [double]$r.watts
      $ok = $true
    }
  } catch {
    Stop-MonitorWmiSample      # 这一轮管道坏了：实例丢掉，runspace 留着
  }
  $script:MonWmi = $null
  return $ok
}

function Update-MonitorData {
  # 数据每秒算一次就够（界面 800ms 刷一遍，这里做节流）。
  # **这里只做便宜的事**：CPU 占用 / 内存 / 电池百分比全是 P/Invoke（不到 1ms）；
  # 要查 WMI 的 CPU 频率与电池瓦数扔给后台，这里只收上一轮的结果。
  # 返回 $true = 收到新的后台数据（值得重绘一次）。
  $now = [datetime]::Now
  if ($now -lt $script:MonitorNextDataAt) { return $false }
  $script:MonitorNextDataAt = $now.AddSeconds(1)

  $dirty = $false
  if (-not $script:PreviewOnly -and $now -ge $script:MonitorNextWmiAt) {
    # 后台一份 5 秒一次，够用了（频率和瓦数都不是秒级变化的东西）
    $script:MonitorNextWmiAt = $now.AddSeconds(5)
    Start-MonitorWmiSample
  }
  if (Receive-MonitorWmiSample) { $dirty = $true }

  $sample = Get-MonitorSample

  # ---- CPU ----
  # 占用率 = 两次 GetSystemTimes 的差分（kernel 时间里含 idle，要减掉）；
  # 当前频率由后台采样更新（Win32_Processor.CurrentClockSpeed 在新 CPU 上常年是标称值，
  # 所以用性能计数器的"有效性能比"折算，纯展示，和主窗的价格逻辑无关）。
  if ($sample) { $script:MonitorCpuPct = [double]$sample.cpuPct }
  else { $script:MonitorCpuPct = Get-CpuUsage }

  # ---- 内存 ----
  if ($sample) {
    $script:MonitorMemText = ('{0} / {1}' -f (Format-Bytes $sample.memUsed), (Format-Bytes $sample.memTotal))
    $script:MonitorMemPct = [double]$sample.memPct
  } else {
    $mem = Get-MemoryInfo
    if ($mem) {
      $script:MonitorMemText = ('{0} / {1}' -f (Format-Bytes $mem.used), (Format-Bytes $mem.total))
      $script:MonitorMemPct = [double]$mem.pct
    } else {
      $script:MonitorMemText = '—'
      $script:MonitorMemPct = -1.0
    }
  }

  # ---- 电池功率 ----
  # 百分比与交流状态用 GetSystemPowerStatus（便宜且准）；瓦数来自后台的
  # root\WMI BatteryStatus（ChargeRate / DischargeRate，单位是毫瓦）。
  if ($sample) {
    $script:MonitorBatPct = 78.0
    $script:MonitorBatState = 'discharging'
    $script:MonitorBatText = '18.4 W'
    $script:MonitorAvail = $true
  } else {
    $bat = Get-BatteryInfo
    if (-not $bat) {
      $script:MonitorAvail = $false
      $script:MonitorBatText = '无电池'
      $script:MonitorBatPct = -1.0
      $script:MonitorBatState = ''
    } else {
      $script:MonitorAvail = $true
      $watts = [double]$script:MonitorBatWatts
      if ($watts -ne 0) { $script:MonitorBatText = ('{0:0.0} W' -f [Math]::Abs($watts)) }
      else { $script:MonitorBatText = '—' }
      $script:MonitorBatPct = [double]$bat.pct
      $script:MonitorBatState = [string]$bat.state
    }
  }
  return $dirty
}

function Update-Monitor {
  # 每轮 tick 调：处理配置变化、跟随主窗位置、刷新文字与线条、决定显示/隐藏
  if ($NoMonitor) { return }
  $changed = Read-MonitorConfig
  if ($changed -or (-not $script:MonitorWin -and $script:MonitorEnabled)) { Build-MonitorWindow }

  # -Preview：一次性把小窗也画出来（见 Show-PreviewPages），平时不走这里
  if ($script:PreviewOnly) { return }

  if (-not (Sync-MonitorVisibility)) { return }

  $m = $script:MonitorWin
  $dirty = Update-MonitorData
  if (Update-MonitorRows) { $dirty = $true }

  # 状态点：主窗那个在线点同步过来（绿=代理在线）
  if ($script:MonDot) {
    $dotCol = if ($script:Online) { $okColor } else { $badColor }
    if ($script:MonDot.ForeColor -ne $dotCol) { $script:MonDot.ForeColor = $dotCol; $dirty = $true }
  }

  # ── 位置：贴着主窗正下方（间距 8px）──
  Move-MonitorToOwner

  # 什么都没变就不重绘：整窗重画一次要 1.6ms（还带 GDI+ 对象分配）
  if ($dirty) { try { $m.Invalidate() } catch { } }
}

function Sync-MonitorVisibility {
  # 收起 / 放出小窗，并让它贴好主窗。返回 $true 表示"小窗现在应该显示着"。
  #
  # 为什么要有这个函数：原来这件事只在 800ms 的 tick 里做，于是折叠之后小窗会在原地
  # 多留最多 0.8 秒（还在屏幕中间晃着），展开也要等最多 0.8 秒才出现 —— 用户反馈的
  # "折叠、展开时卡顿"有一部分就是它。现在折叠 / 展开的那一刻直接调这里。
  if ($NoMonitor) { return $false }
  $m = $script:MonitorWin
  if (-not $m) { return $false }
  $want = $script:MonitorEnabled -and (-not $script:Collapsed) -and $form.Visible
  if (-not $want) {
    if ($script:MonitorShown) {
      try { $m.Hide() } catch { }
      $script:MonitorShown = $false
    }
    return $false
  }
  if (-not $script:MonitorShown) {
    try {
      $m.Show()
      $script:MonitorShown = $true
      # 圆角和深色边框：和主窗一致（要在句柄建立后才生效）
      try {
        $round = 2; [void][TokenMonitor.Win]::DwmSetWindowAttribute($m.Handle, 33, [ref]$round, 4)
        $dark = 1; [void][TokenMonitor.Win]::DwmSetWindowAttribute($m.Handle, 20, [ref]$dark, 4)
      } catch { }
    } catch { return $false }
  }
  return $true
}

# ---------------- 窗口位置记忆 ----------------
function Save-Geometry {
  if (-not $script:SaveGeometry) { return }   # -Preview 时不写记忆文件
  try {
    # 折叠状态下也记展开时的尺寸，下次展开才不会变形
    $sw = $width; $sh = $height
    if ($script:Collapsed -and $script:ExpandedBounds -ne $null) {
      $sw = $script:ExpandedBounds.Width; $sh = $script:ExpandedBounds.Height
    }
    $sx = $form.Location.X; $sy = $form.Location.Y
    if ($script:Collapsed -and $script:ExpandedBounds -ne $null) {
      $sx = $script:ExpandedBounds.X; $sy = $script:ExpandedBounds.Y
    }
    @{
      x = $sx; y = $sy; width = $sw; height = $sh; pid = $PID; page = $script:Page
      dsh = $script:DshWebState
      collapsed = $script:Collapsed; edge = $script:Edge
    } | ConvertTo-Json -Compress | Set-Content -Path $script:GeomFile -Encoding UTF8
    $script:LastGeometry = '{0},{1}' -f $form.Location.X, $form.Location.Y
  } catch { }
}

# ---------------- 页面切换 ----------------
function Apply-Page {
  $balancePage = ($script:Page -eq 1)      # 第 1 页 = 账户余额
  foreach ($c in $script:AccountControls) { try { $c.Visible = $balancePage } catch { } }
  foreach ($c in $script:UsageControls) { try { $c.Visible = (-not $balancePage) } catch { } }
  $script:PageControls = if ($balancePage) { $script:AccountControls } else { $script:UsageControls }
  if ($balancePage) { $script:PillText = '用量 ›' } else { $script:PillText = '‹ 余额' }
  # 「本轮对话」的花费小字和那个大数字在同一行，而大数字标签宽 276、背景不透明，会把它整块盖住。
  # BringToFront() 在**窗体句柄还没建立**时是空操作（构建期那次调用就是这种情况，曾因此让花费"消失"），
  # 所以必须在这里再提一次：Apply-Page 由 Add_Shown 调用，那时句柄已经存在。
  try { if ($form.IsHandleCreated) { $lblConvCost.BringToFront() } } catch { }
  try { $pill.Invalidate() } catch { }
  Update-Ui
}

function Switch-Page {
  if ($script:Page -eq 1) { $script:Page = 2 } else { $script:Page = 1 }
  Apply-Page
  Save-Geometry
}

# ---------------- 贴边折叠 ----------------
# 拖到屏幕边缘就缩成一个小标签（深色圆角 + 指向屏幕内的箭头），点它展开

function Get-NearbyEdge {
  try {
    $b = $form.Bounds
    $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $t = $script:SnapTolerance
    if ($b.Left -le ($wa.Left + $t)) { return 'left' }
    if ($b.Right -ge ($wa.Right - $t)) { return 'right' }
    if ($b.Top -le ($wa.Top + $t)) { return 'top' }
    if ($b.Bottom -ge ($wa.Bottom - $t)) { return 'bottom' }
  } catch { }
  return ''
}

function Get-TabBounds {
  param([string]$Edge)
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $long = $script:TabSize
  $thick = $script:TabThick
  $x = $form.Location.X
  $y = $form.Location.Y
  switch ($Edge) {
    'left'   { $w = $thick; $h = $long;  $x = $wa.Left;         $y = [Math]::Min([Math]::Max($y, $wa.Top), $wa.Bottom - $h) }
    'right'  { $w = $thick; $h = $long;  $x = $wa.Right - $w;   $y = [Math]::Min([Math]::Max($y, $wa.Top), $wa.Bottom - $h) }
    'top'    { $w = $long;  $h = $thick; $y = $wa.Top;          $x = [Math]::Min([Math]::Max($x, $wa.Left), $wa.Right - $w) }
    'bottom' { $w = $long;  $h = $thick; $y = $wa.Bottom - $h;  $x = [Math]::Min([Math]::Max($x, $wa.Left), $wa.Right - $w) }
    default  { $w = $long;  $h = $thick }
  }
  return (New-Object System.Drawing.Rectangle($x, $y, [int]$w, [int]$h))
}

function Set-Collapsed {
  param([string]$Edge, [switch]$Remember)
  if ([string]::IsNullOrEmpty($Edge)) { $Edge = 'right' }
  if (-not $script:Collapsed) { $script:ExpandedBounds = $form.Bounds }
  $script:Collapsed = $true
  $script:Edge = $Edge
  foreach ($c in $form.Controls) { try { $c.Visible = $false } catch { } }
  $tab = Get-TabBounds -Edge $Edge
  $form.ClientSize = New-Object System.Drawing.Size($tab.Width, $tab.Height)
  $form.Location = New-Object System.Drawing.Point($tab.X, $tab.Y)
  $form.Cursor = [System.Windows.Forms.Cursors]::Hand
  $form.Invalidate()
  # 小窗立刻收起来（别等下一个 tick，否则它会杵在原地最多 0.8 秒）
  try { [void](Sync-MonitorVisibility) } catch { }
  if ($Remember) { Save-Geometry }
}

function Expand-Widget {
  param([switch]$Remember)
  if (-not $script:Collapsed) { return }
  $form.Cursor = [System.Windows.Forms.Cursors]::Default
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $b = $script:ExpandedBounds
  if ($b -eq $null) { $b = New-Object System.Drawing.Rectangle(($wa.Right - $width - 24), ($wa.Bottom - $height - 24), $width, $height) }
  $w = $b.Width; $h = $b.Height
  $x = [Math]::Min([Math]::Max($b.X, $wa.Left), $wa.Right - $w)
  $y = [Math]::Min([Math]::Max($b.Y, $wa.Top), $wa.Bottom - $h)
  switch ($script:Edge) {   # 展开时往屏幕内侧挪一点，别立刻又贴边
    # 内缩量要比折叠判定（SnapTolerance）明显大，否则刚展开还站在"折叠区"里，手一碰又折回去
    'left'   { $x = $wa.Left + $script:SnapTolerance + 10 }
    'right'  { $x = $wa.Right - $w - $script:SnapTolerance - 10 }
    'top'    { $y = $wa.Top + $script:SnapTolerance + 10 }
    'bottom' { $y = $wa.Bottom - $h - $script:SnapTolerance - 10 }
  }
  $script:Collapsed = $false
  $script:Edge = ''
  $form.ClientSize = New-Object System.Drawing.Size($w, $h)
  $form.Location = New-Object System.Drawing.Point($x, $y)
  foreach ($c in $form.Controls) { try { $c.Visible = $true } catch { } }
  Apply-Page
  $form.Invalidate()
  # 小窗立刻放出来并贴好位置（别等下一个 tick，否则展开后要空等最多 0.8 秒）
  try { if (Sync-MonitorVisibility) { Move-MonitorToOwner } } catch { }
  if ($Remember) { Save-Geometry }
}

function Get-NearestEdge {
  # 离哪条屏幕边最近（用于折叠后拖动时自动换边）
  try {
    $b = $form.Bounds
    $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $d = @{
      left   = ($b.Left - $wa.Left)
      right  = ($wa.Right - $b.Right)
      top    = ($b.Top - $wa.Top)
      bottom = ($wa.Bottom - $b.Bottom)
    }
    $best = 'right'
    $min = [int]::MaxValue
    foreach ($k in $d.Keys) { if ($d[$k] -lt $min) { $min = $d[$k]; $best = $k } }
    return $best
  } catch { return 'right' }
}

function Set-CollapseByEdge {   # 拖完松手时调用
  if ($script:Collapsed) {
    # 折叠状态下拖动：始终保持折叠，只自动吸附到最近的那条边
    Set-Collapsed -Edge (Get-NearestEdge) -Remember
    return
  }
  $edge = Get-NearbyEdge
  if ($edge) { Set-Collapsed -Edge $edge -Remember }
}

# ---------------- 自动打开 DSH Web 界面 ----------------
function Test-UrlAlive {
  param([string]$Url)
  try {
    $u = [System.Uri]$Url
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect($u.Host, $u.Port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(1200)
    $connected = ($ok -and $client.Connected)
    $client.Close()
    return $connected
  } catch { return $false }
}

function Open-DshWeb {
  if (-not $script:OpenDshWeb) { return }
  if (Test-UrlAlive $script:DshUrl) {
    Start-Process $script:DshUrl
    $script:DshWebState = '已打开 ' + $script:DshUrl
  } else {
    $script:DshWebState = '无响应，未打开（' + $script:DshUrl + '）'
  }
  try { $tooltip.SetToolTip($lblTitle2, "DSH 界面：$script:DshWebState") } catch { }
}

# ── 行距自适应：窗口和字号都不动，只把行距重新分配一遍 ──
# 为什么需要：字体按 point 渲染，125% 下每行行高都比设计框高（9pt 那行需要约 21px、设计框只有 18px），
# 最后一行就被窗口下边缘啃掉几个像素（用户看到的"切字"）。
# **第一版写的"把超出的部分往上收"是错的**：上面那行的框变高后会盖住下面那行
# （实测"当前价格"的框压住了 deepseek-flash 的上沿）。现在改成按实际行高重排：
#   多出来的空间按比例从行距里扣；行距扣到 0 还不够，才把窗口长高那几像素。
#   100% 缩放下行高正好等于设计值 → 比例=1 → 位置和以前一模一样（零回归）。
function Fit-Rows {
  param([array]$Rows, [int]$BottomLimit)
  $n = $Rows.Count
  $need = New-Object System.Collections.ArrayList
  foreach ($r in $Rows) {
    $h = 0
    try { $h = [System.Windows.Forms.TextRenderer]::MeasureText([string]$r.C.Text, $r.C.Font).Height } catch { }
    if ($h -lt 1) { $h = [int]$r.H }
    [void]$need.Add([Math]::Max([int]$r.H, [int][Math]::Ceiling($h)))
  }
  $gap = New-Object System.Collections.ArrayList
  $sumGap = 0
  for ($i = 0; $i -lt $n - 1; $i++) {
    $g = [int]$Rows[$i + 1].Y - ([int]$Rows[$i].Y + [int]$Rows[$i].H)
    [void]$gap.Add($g); $sumGap += $g
  }
  $sumNeed = 0; foreach ($h in $need) { $sumNeed += $h }
  $free = ($BottomLimit - [int]$Rows[0].Y) - $sumNeed
  $factor = 1.0
  if ($sumGap -ne 0) { $factor = [double]$free / [double]$sumGap }
  $use = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $n - 1; $i++) {
    $g = [int][Math]::Floor($gap[$i] * $factor)
    if ($g -lt 0) { $g = 0 }
    [void]$use.Add($g)
  }
  # 先按算好的间距"试摆"一遍，看超出多少
  $y0 = [int]$Rows[0].Y
  $y = $y0
  for ($i = 0; $i -lt $n; $i++) { $y += $need[$i]; if ($i -lt $n - 1) { $y += $use[$i] } }
  $over = $y - $BottomLimit
  if ($over -lt 0) { $over = 0 }
  # 超出了先"整体往上借"：标题分隔线（y=32）下面本来就留着 12px 空白，借几像素看不出来，
  # 这样窗口高度通常根本不用变；借不动了才真的长高那一点点。
  $shiftUp = [Math]::Min($over, [Math]::Max(0, $y0 - 34))
  $over -= $shiftUp
  $y = $y0 - $shiftUp
  for ($i = 0; $i -lt $n; $i++) {
    $c = $Rows[$i].C
    $c.Location = New-Object System.Drawing.Point($c.Location.X, $y)
    $c.Size = New-Object System.Drawing.Size($c.Size.Width, $need[$i])
    $y += $need[$i]
    if ($i -lt $n - 1) { $y += $use[$i] }
  }
  return $over
}

# 每条"行"按设计顺序列出：Y/H 是设计坐标，实际高度由字体实测决定
$fitUsage = @(
  @{ C = $lblTotalTag;   Y = 44;  H = 16 },
  @{ C = $lblTotal;      Y = 62;  H = 46 },
  @{ C = $lblTodayTag;   Y = 116; H = 16 },
  @{ C = $lblToday;      Y = 131; H = 32 }
)
$fitAccount = @(
  @{ C = $lblBalTag;      Y = 44;  H = 16 },
  @{ C = $lblBalanceBig;  Y = 62;  H = 46 },
  @{ C = $lblPriceTag;    Y = 118; H = 16 },
  @{ C = $lblPriceModel;  Y = 134; H = 22 },
  @{ C = $lblPriceDetail; Y = 156; H = 18 }
)
$over = [Math]::Max((Fit-Rows -Rows $fitUsage -BottomLimit ($height - 2)), (Fit-Rows -Rows $fitAccount -BottomLimit ($height - 2)))
if ($over -gt 0) {
  $height += $over
  $form.ClientSize = New-Object System.Drawing.Size($width, $height)
}

# 拖动窗口
# 判定：按下之后必须真的移动超过 $script:DragThreshold 才算"拖"；
# 手抖、轻点一律算"点一下"——否则点一下也会被判成拖完：既会把这次点击吞掉
# （折叠标签就永远点不开），又会在贴边时顺手把它折起来（一碰就折叠）。这两条都踩过。
$script:Pressing = $false                 # 左键按着（还没超过阈值）
$script:Dragging = $false                 # 已经真的在拖
$script:DragMoved = $false
$script:DragOffset = New-Object System.Drawing.Point(0, 0)
$script:PressOrigin = New-Object System.Drawing.Point(0, 0)
$script:DragWinX = 0                      # 主窗当前（拖动时=目标）坐标，避免每次 MouseMove 都读 $form.Location
$script:DragWinY = 0

function Add-Drag {
  param($Control)
  $Control.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      $script:Pressing = $true
      $script:Dragging = $false
      $script:DragMoved = $false
      $script:SuppressClick = $false                    # 新的一次按下，先清掉可能残留的"吞点击"标记
      $cp = [System.Windows.Forms.Cursor]::Position
      # 偏移统一用屏幕坐标算：不管抓的是窗体还是某个标签，窗口都不会"跳一下"
      $script:DragOffset = New-Object System.Drawing.Point(($cp.X - $form.Location.X), ($cp.Y - $form.Location.Y))
      $script:PressOrigin = $cp
      $script:DragWinX = $form.Location.X               # 记下起点，MouseMove 里就不用再读 $form.Location（读一次要装一个 Point）
      $script:DragWinY = $form.Location.Y
    }
  })
  $Control.Add_MouseMove({
    param($sender, $e)
    if (-not $script:Pressing) { return }
    $cp = [System.Windows.Forms.Cursor]::Position
    if (-not $script:Dragging) {
      $dx = [Math]::Abs($cp.X - $script:PressOrigin.X)
      $dy = [Math]::Abs($cp.Y - $script:PressOrigin.Y)
      if ($dx -lt $script:DragThreshold -and $dy -lt $script:DragThreshold) { return }   # 还没到阈值：当没动
      $script:Dragging = $true
    }
    $script:DragMoved = $true
    # 用屏幕绝对坐标算，窗口才会精确跟着鼠标走。
    # ⚠️ 这是每次鼠标移动都要走的路径：一律用 SetBounds + 缓存坐标，
    #    别写 `Location = New-Object Point`（实测 0.65ms vs 0.17ms，见 probe-move-cost.ps1）。
    $nx = $cp.X - $script:DragOffset.X
    $ny = $cp.Y - $script:DragOffset.Y
    if ($nx -ne $script:DragWinX -or $ny -ne $script:DragWinY) {
      $script:DragWinX = $nx
      $script:DragWinY = $ny
      $form.SetBounds($nx, $ny, $form.Width, $form.Height)
      # 性能监控小窗跟着走（不等下一个 tick，拖动时是跟手的）；
      # 顺手把主窗的新坐标传过去，小窗那边就省掉一次 $form.Location 装箱。
      try { Move-MonitorToOwner -OwnerX $nx -OwnerY $ny } catch { }
    }
  })
  $Control.Add_MouseUp({
    param($sender, $e)
    $wasPressing = $script:Pressing
    $moved = $script:DragMoved
    $script:Pressing = $false
    $script:Dragging = $false
    $script:DragMoved = $false
    if ($wasPressing -and $moved) {
      $script:SuppressClick = $true      # 真的拖过：这一下不当成"点击"（否则折叠标签会直接展开）
      Set-CollapseByEdge
    }
  })
}

foreach ($ctl in @($form, $lblTitle, $lblTitle2, $lblStatusDot, $lblTotalTag, $lblTotal, $lblTodayTag, $lblToday, $lblConvCost,
    $lblBalTag, $lblBalanceBig, $lblPriceTag, $lblPriceModel, $lblPriceDetail, $lblTierElapsed, $ringTier)) {
  try { Add-Drag -Control $ctl } catch { }
}

# 折叠状态下左键单击 = 展开（刚拖完的那一下不算点击）
$form.Add_Click({
  if ($script:SuppressClick) { $script:SuppressClick = $false; return }
  if ($script:Collapsed) { Expand-Widget -Remember }
})

# 折叠标签的悬停高亮（让它更容易被注意到）
$form.Add_MouseEnter({
  if ($script:Collapsed -and -not $script:TabHover) { $script:TabHover = $true; $form.Invalidate() }
})
$form.Add_MouseLeave({
  if ($script:TabHover) { $script:TabHover = $false; $form.Invalidate() }
})

# 右键菜单
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemSwitch = $menu.Items.Add('切换页面（账户 / 用量）')
$itemDash = $menu.Items.Add('打开网页面板')
$itemDsh = $menu.Items.Add('打开 DSH 界面')
$itemBalance = $menu.Items.Add('刷新余额')
$itemTopUp = $menu.Items.Add('打开充值页面')
$itemPricing = $menu.Items.Add('查看官方价格页')
$itemPricingUpdate = $menu.Items.Add('立即从官网更新价格')
$itemDshUsage = $menu.Items.Add('刷新 DSH 用量')
$itemReset = $menu.Items.Add('复位统计')
$menu.Items.Add('-') | Out-Null
$itemCollapse = $menu.Items.Add('折叠到最近的屏幕边缘')
$itemQuit = $menu.Items.Add('退出悬浮窗')
$itemSwitch.Add_Click({ Switch-Page })
$itemDsh.Add_Click({ Open-DshWeb })
$itemDash.Add_Click({ Start-Process "http://127.0.0.1:$script:Port/__dashboard" })
$itemBalance.Add_Click({
  try {
    $result = Invoke-RestMethod -Uri "http://127.0.0.1:$script:Port/__balance?force=1" -TimeoutSec 15
    if ($result.error) { [System.Windows.Forms.MessageBox]::Show([string]$result.error, '余额查询失败', 'OK', 'Warning') | Out-Null }
  } catch {
    [System.Windows.Forms.MessageBox]::Show('无法连接代理：' + $_.Exception.Message, '余额查询失败', 'OK', 'Warning') | Out-Null
  }
})
$itemTopUp.Add_Click({ Start-Process 'https://platform.deepseek.com/top_up' })
$itemPricing.Add_Click({ Start-Process 'https://api-docs.deepseek.com/zh-cn/quick_start/pricing' })
$itemDshUsage.Add_Click({
  try {
    $result = Invoke-RestMethod -Uri "http://127.0.0.1:$script:Port/__dsh-usage/refresh" -TimeoutSec 15
    if ($result.error) {
      [System.Windows.Forms.MessageBox]::Show([string]$result.error, 'DSH 用量读取失败', 'OK', 'Warning') | Out-Null
    } else {
      [System.Windows.Forms.MessageBox]::Show(("已读取 {0} 个 DSH 会话，合计 {1:N0} tok" -f $result.sessionCount, $result.totals.total), 'DSH 用量已刷新', 'OK', 'Information') | Out-Null
    }
  } catch {
    [System.Windows.Forms.MessageBox]::Show('无法连接代理：' + $_.Exception.Message, 'DSH 用量读取失败', 'OK', 'Warning') | Out-Null
  }
})
$itemPricingUpdate.Add_Click({
  try {
    $result = Invoke-RestMethod -Uri "http://127.0.0.1:$script:Port/__pricing/refresh" -TimeoutSec 40
    $models = ($result.table.PSObject.Properties.Name) -join '、'
    if ($result.error) {
      [System.Windows.Forms.MessageBox]::Show([string]$result.error, '价格更新失败', 'OK', 'Warning') | Out-Null
    } else {
      [System.Windows.Forms.MessageBox]::Show("已更新：$models`n$($result.fetchedText)", '价格更新成功', 'OK', 'Information') | Out-Null
    }
  } catch {
    [System.Windows.Forms.MessageBox]::Show('无法连接代理：' + $_.Exception.Message, '价格更新失败', 'OK', 'Warning') | Out-Null
  }
})
$itemReset.Add_Click({
  $answer = [System.Windows.Forms.MessageBox]::Show('确定要清空所有累计统计吗？', 'token-monitor', 'YesNo', 'Question')
  if ($answer -eq 'Yes') {
    try { Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$script:Port/__reset" -TimeoutSec 3 | Out-Null } catch { }
  }
})
$itemCollapse.Add_Click({
  if ($script:Collapsed) { Expand-Widget -Remember }
  else { Set-Collapsed -Edge (Get-NearestEdge) -Remember }
})
$itemQuit.Add_Click({ $form.Close() })
$form.ContextMenuStrip = $menu

$form.Add_KeyDown({
  param($sender, $e)
  if ($e.KeyCode -eq 'Escape') { $form.Close() }
})

$form.Add_FormClosing({
  try { if ($script:MonitorWin) { $script:MonitorWin.Close(); $script:MonitorWin.Dispose(); $script:MonitorWin = $null } } catch { }
  Save-Geometry
  try { Remove-Item (Join-Path $script:DataDir 'widget.pid') -ErrorAction SilentlyContinue } catch { }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 800
$timer.Add_Tick({
  try {
    $script:Stats = Invoke-RestMethod -Uri "http://127.0.0.1:$script:Port/__stats" -TimeoutSec 2
    $script:Online = $true
  } catch {
    $script:Online = $false
  }
  Update-Ui
  # 性能监控小窗：读配置变化 → 跟随位置 → 刷新数据与显示状态
  try { Update-Monitor } catch { }

  # 位置变化时记录，便于外部截图/脚本定位
  try {
    $now = '{0},{1}' -f $form.Location.X, $form.Location.Y
    if ($now -ne $script:LastGeometry) { Save-Geometry }
  } catch { }
})

# ── -Preview：把两页离屏画成 PNG（无头环境验证外观；不显示窗口、不连代理）──
# 返回 $true 表示"这是预览模式，画完就该退出"。
#
# 调用点在 ShowDialog 之前（脚本末尾）：受限会话里 Add_Shown 根本不会触发
# （ShowDialog 立刻返回，README 9.2 末尾记着这条），只放在 Shown 里的话预览永远是空的。
function Show-PreviewPages {
  if (-not $Preview) { return $false }
  # 结果同时写进 data\_preview\render.log：受限会话里 Write-Host 根本看不到
  # （子进程被拦、宿主控制台也读不到），只有落到文件里才验证得了。
  $logFile = Join-Path $script:DataDir '_preview\render.log'
  function Write-PreviewLog {
    param([string]$Line)
    try {
      $dirNow = Split-Path -Parent $logFile
      if (-not (Test-Path $dirNow)) { New-Item -ItemType Directory -Path $dirNow -Force | Out-Null }
      Add-Content -Path $logFile -Value $Line -Encoding UTF8
    } catch { }
    try { Write-Host $Line } catch { }
  }
  # 把一个控件画进整窗位图。
  # ⚠️ **不能用 Control.DrawToBitmap**：在"没真正显示过"的窗口上它对每个控件都返回空白
  # （实测两张预览图只有底色，README 9.3 第 4 条说的就是这件事）。所以分两种处理：
  #   Label → 自己按 TextAlign/字体/前景色把文字画进它的矩形（Label 的 OnPaint 是 protected，脚本调不到）
  #   Panel → 调它自己的 OnPaint（胶囊按钮、关闭键、应用标记、进度圆环都是自绘的），
  #           先把原点平移到控件位置，否则自绘内容会画在左上角。
  function Add-ControlImage {
    param($G, $Ctrl, $W, $H)
    if ($Ctrl -is [System.Windows.Forms.Label]) {
      $text = [string]$Ctrl.Text
      if ($text -eq '') { return }
      $sf = New-Object System.Drawing.StringFormat
      switch ([string]$Ctrl.TextAlign) {
        'MiddleRight'  { $sf.Alignment = [System.Drawing.StringAlignment]::Near;   $sf.LineAlignment = [System.Drawing.StringAlignment]::Center }
        'MiddleLeft'   { $sf.Alignment = [System.Drawing.StringAlignment]::Near;   $sf.LineAlignment = [System.Drawing.StringAlignment]::Center }
        'MiddleCenter' { $sf.Alignment = [System.Drawing.StringAlignment]::Center; $sf.LineAlignment = [System.Drawing.StringAlignment]::Center }
        default        { $sf.Alignment = [System.Drawing.StringAlignment]::Near;   $sf.LineAlignment = [System.Drawing.StringAlignment]::Near }
      }
      $brush = New-Object System.Drawing.SolidBrush($Ctrl.ForeColor)
      $rect = New-Object System.Drawing.RectangleF([single]$Ctrl.Location.X, [single]$Ctrl.Location.Y, [single]$W, [single]$H)
      $G.DrawString($text, $Ctrl.Font, $brush, $rect, $sf)
      $brush.Dispose(); $sf.Dispose()
      return
    }
    if ($Ctrl -eq $ringTier) {
      Draw-TierRing -G $G -X ([single]$Ctrl.Location.X) -Y ([single]$Ctrl.Location.Y) -W $Ctrl.Width -H $Ctrl.Height
      return
    }    try {
      $state = $G.Save()
      $G.TranslateTransform([single]$Ctrl.Location.X, [single]$Ctrl.Location.Y)
      $paintArgs = New-Object System.Windows.Forms.PaintEventArgs($G, (New-Object System.Drawing.Rectangle(0, 0, $Ctrl.Width, $Ctrl.Height)))
      $Ctrl.OnPaint($paintArgs)
      $G.Restore($state)
    } catch { }
  }
  try {
    if ($script:PreviewStats) {
      $script:Stats = $script:PreviewStats
      # 不传 -PreviewPeakWindow 时故意把 peakWindow 去掉，顺便验证"代理没给时段数据"的退路。
      if ($PreviewPeakWindow -eq '') { $script:Stats.PSObject.Properties.Remove('peakWindow') }
      $script:Online = ($PreviewPeakWindow -ne '')
    }
    # 预览也要把小窗画出来（否则改了小窗无从验证）。这里强制按"三项全开"渲染示例值，
    # 走的排版函数和真跑时是同一个（Update-MonitorRows），所以预览图能代表真实外观。
    $script:MonitorEnabled = $true
    $script:MonitorItems = @('cpu', 'memory', 'battery')
    Build-MonitorWindow
    $script:MonitorCpuPct = 23.0
    $script:MonitorCpuGhz = 2.90
    $script:MonitorMemText = '9.8 GB / 16.0 GB'
    $script:MonitorMemPct = 61.0
    $script:MonitorBatText = '18.4 W'
    $script:MonitorBatState = 'discharging'
    $script:MonitorBatPct = 78.0
    $script:MonitorAvail = $true
    Update-MonitorRows
    $dir = Join-Path $script:DataDir '_preview'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path $logFile) { Remove-Item $logFile -Force -ErrorAction SilentlyContinue }
    # 画哪几页：默认两页，-PreviewPages 1 只画账户页（文档里要单独一张图时用）
    $pages = @()
    foreach ($ch in $PreviewPages.ToCharArray()) { if ($ch -eq '1' -or $ch -eq '2') { $pages += [int][string]$ch } }
    if ($pages.Count -eq 0) { $pages = @(1, 2) }
    foreach ($pg in $pages) {
      $script:Page = $pg
      Apply-Page                       # 这一步会把 $script:PageControls 设成当前页该显示的控件
      try { $form.Refresh() } catch { }
      [System.Windows.Forms.Application]::DoEvents()
      $w = $form.ClientSize.Width
      $h = $form.ClientSize.Height
      # 预览图把小窗一起画进去：画布高度 = 主窗 + 8px 间距 + 小窗
      $mw = 0; $mh = 0
      if ($script:MonitorWin) {
        $mw = $script:MonitorWin.ClientSize.Width
        $mh = $script:MonitorWin.ClientSize.Height
      }
      $canvasW = [Math]::Max($w, $mw)
      $canvasH = $h
      if ($mh -gt 0) { $canvasH = $h + 8 + $mh }
      $visNames = @()
      foreach ($c in $script:PageControls) {
        # 顺带量一下文字实际宽度：这一行（倒计时 + 已过百分比 + 圆环）是新增的，
        # 一旦文字比预留的框宽就会被窗口右边啃掉，光看坐标看不出来。
        $measured = ''
        try { $measured = ' 文字宽=' + [System.Windows.Forms.TextRenderer]::MeasureText([string]$c.Text, $c.Font).Width } catch { }
        $visNames += ($c.GetType().Name + '[' + [string]$c.Text + ']@' + $c.Location.X + ',' + $c.Location.Y + ' ' + $c.Width + 'x' + $c.Height + $measured)
      }
      Write-PreviewLog ('第 ' + $pg + ' 页可见控件 ' + $visNames.Count + ' 个: ' + ($visNames -join ' | '))
      $bmp = New-Object System.Drawing.Bitmap($canvasW, $canvasH)
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
      $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
      $g.Clear($bgColor)
      foreach ($c in $form.Controls) {
        if ($script:PageControls -notcontains $c) { continue }
        try {
          Add-ControlImage -G $g -Ctrl $c -W $c.Width -H $c.Height
        } catch {
          Write-PreviewLog ('  画控件失败 [' + $c.GetType().Name + ' @' + $c.Location.X + ',' + $c.Location.Y + ']: ' + $_.Exception.Message)
        }
      }
      # 小窗（叠在主窗下方 8px 处）
      if ($script:MonitorWin -and $mh -gt 0) {
        try {
          $mTop = $h + 8
          $state = $g.Save()
          $g.TranslateTransform(0, [single]$mTop)
          Paint-MonitorSurface -G $g -W $mw -H $mh
          $g.Restore($state)
          $mInfo = @()
          foreach ($mc in $script:MonitorWin.Controls) {
            if ($mc -isnot [System.Windows.Forms.Label]) { continue }
            $state2 = $g.Save()
            $g.TranslateTransform(0, [single]$mTop)
            Add-ControlImage -G $g -Ctrl $mc -W $mc.Width -H $mc.Height
            $g.Restore($state2)
            $mInfo += ('[' + $mc.Text + ']@' + $mc.Location.X + ',' + $mc.Location.Y + ' 文字宽=' + [System.Windows.Forms.TextRenderer]::MeasureText([string]$mc.Text, $mc.Font).Width)
          }
          Write-PreviewLog ('小窗 ' + $mw + 'x' + $mh + ' 控件: ' + ($mInfo -join ' | '))
        } catch {
          Write-PreviewLog ('  画小窗失败: ' + $_.Exception.Message)
        }
      }
      $g.Dispose()
      $out = Join-Path $dir ('widget-preview-page{0}.png' -f $pg)
      $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
      $bmp.Dispose()
      Write-PreviewLog ('预览已保存: ' + $out + '  (' + $canvasW + 'x' + $canvasH + ')')
    }
    Write-PreviewLog ('倒计时文字 = [' + $lblPriceDetail.Text + ']  已过 = [' + $lblTierElapsed.Text + ']  圆环可见 = ' + $ringTier.Visible + '  圆环百分比 = ' + $script:TierPercent)
    # 悬停提示也要看一眼：提示是拼字符串拼出来的，格式串少一个参数就会整条抛异常、界面上静默没有提示
    Write-PreviewLog ('当前价格提示行 = [' + ($tooltip.GetToolTip($lblPriceModel) -replace "`r?`n", ' | ') + ']')
    Write-PreviewLog ('时段进度提示行 = [' + ($tooltip.GetToolTip($lblPriceDetail) -replace "`r?`n", ' | ') + ']')
  } catch {
    Write-PreviewLog ('预览失败: ' + $_.Exception.Message)
    try { Write-PreviewLog ([string]$_.ScriptStackTrace) } catch { }
  }
  return $true
}

$form.Add_Shown({
  # 强制显示：SW_SHOW=5，SetWindowPos 标志 NOSIZE|NOMOVE|SHOWWINDOW|NOACTIVATE
  try {
    $handle = $form.Handle
    [void][TokenMonitor.Win]::ShowWindow($handle, 5)
    [void][TokenMonitor.Win]::SetWindowPos($handle, [IntPtr]::Zero, 0, 0, 0, 0, 0x0043)
  } catch { }
  # Win11 外观：窗口圆角 + 深色边框（老系统上这两个调用会失败，忽略即可）
  try {
    $corner = 2   # DWMWCP_ROUND
    [void][TokenMonitor.Win]::DwmSetWindowAttribute($form.Handle, 33, [ref]$corner, 4)
    $dark = 1     # DWMWA_USE_IMMERSIVE_DARK_MODE
    [void][TokenMonitor.Win]::DwmSetWindowAttribute($form.Handle, 20, [ref]$dark, 4)
  } catch { }
  try { if (-not $script:PreviewOnly) { Set-Content -Path (Join-Path $script:DataDir 'widget.pid') -Value $PID -Encoding ASCII } } catch { }

  # ── 预览模式：把两页离屏画成 PNG 后退出（无头环境验证外观；不显示窗口、不连代理）──
  # 注意：这里自己建 Bitmap + 调控件的 DrawToBitmap 来合成整窗，
  # 因为 Form.DrawToBitmap 在"没真正显示的窗口"上只给一张白图（README 9.3 第 4 条）。
  if (Show-PreviewPages) { $form.Close(); return }

  # ── 自检模式：把吸附/折叠逻辑真跑一遍，结果写文件后退出 ──
  if ($SelfTest) {
    $out = New-Object System.Collections.ArrayList
    [void]$out.Add('token-monitor 悬浮窗吸附自检  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    [void]$out.Add('屏幕工作区: ' + $wa.Width + 'x' + $wa.Height + ' @(' + $wa.Left + ',' + $wa.Top + ')')
    [void]$out.Add('')
    [void]$out.Add('【1】把窗口摆到各边附近，看能不能认出是哪条边')
    foreach ($edge in @('left', 'right', 'top', 'bottom')) {
      $x = if ($edge -eq 'left') { $wa.Left + 5 } elseif ($edge -eq 'right') { $wa.Right - $form.Width - 5 } else { [int]($wa.Left + ($wa.Width - $form.Width) / 2) }
      $y = if ($edge -eq 'top') { $wa.Top + 5 } elseif ($edge -eq 'bottom') { $wa.Bottom - $form.Height - 5 } else { [int]($wa.Top + ($wa.Height - $form.Height) / 2) }
      $form.Location = New-Object System.Drawing.Point([int]$x, [int]$y)
      $detected = Get-NearbyEdge
      $ok = if ($detected -eq $edge) { '✔' } else { '✘' }
      [void]$out.Add('  摆到 ' + $edge.PadRight(6) + ' -> 识别为 ' + $detected.PadRight(6) + ' ' + $ok)
    }
    [void]$out.Add('')
    [void]$out.Add('【2】折叠到每条边，检查是否贴齐屏幕边')
    foreach ($edge in @('bottom', 'left', 'right', 'top')) {
      Set-Collapsed -Edge $edge
      $b = $form.Bounds
      $flush = switch ($edge) {
        'bottom' { $b.Bottom -eq $wa.Bottom }
        'top'    { $b.Top -eq $wa.Top }
        'left'   { $b.Left -eq $wa.Left }
        'right'  { $b.Right -eq $wa.Right }
      }
      $ok = if ($flush) { '✔' } else { '✘' }
      [void]$out.Add('  贴 ' + $edge.PadRight(6) + ': ' + $b.Width + 'x' + $b.Height + ' @(' + $b.X + ',' + $b.Y + ')  贴齐=' + $flush + ' ' + $ok)
    }
    [void]$out.Add('')
    [void]$out.Add('【3】折叠状态下拖到另一侧，应当自动换边（这就是"自动吸附"）')
    foreach ($target in @('top', 'bottom', 'left', 'right')) {
      $form.Location = New-Object System.Drawing.Point([int]($wa.Left + 200), [int]($wa.Top + 120))
      $before = $script:Edge
      $x = if ($target -eq 'left') { $wa.Left + 3 } elseif ($target -eq 'right') { $wa.Right - $script:TabThick - 3 } else { [int]($wa.Left + 300) }
      $y = if ($target -eq 'top') { $wa.Top + 3 } elseif ($target -eq 'bottom') { $wa.Bottom - $script:TabThick - 3 } else { [int]($wa.Top + 300) }
      $form.Location = New-Object System.Drawing.Point([int]$x, [int]$y)
      Set-CollapseByEdge
      $ok = if ($script:Edge -eq $target) { '✔' } else { '✘' }
      [void]$out.Add('  从 ' + $before + ' 拖到 ' + $target.PadRight(6) + ' 附近 -> 现在贴 ' + $script:Edge.PadRight(6) + ' ' + $ok)
    }
    [void]$out.Add('')
    [void]$out.Add('【4】点击展开，应回到 300x176 且保持可用')
    Expand-Widget
    $ok = if ((-not $script:Collapsed) -and $form.Width -eq 300) { '✔' } else { '✘' }
    [void]$out.Add('  展开后: ' + $form.Width + 'x' + $form.Height + '  折叠状态=' + $script:Collapsed + ' ' + $ok)
    [void]$out.Add('')
    [void]$out.Add('【5】折叠状态是否能被记住（写进 widget.json）')
    Set-Collapsed -Edge 'right' -Remember
    $json = Get-Content $script:GeomFile -Raw -ErrorAction SilentlyContinue
    $ok = if ($json -match '"collapsed":true' -and $json -match '"edge":"right"') { '✔' } else { '✘' }
    [void]$out.Add('  widget.json: ' + $json.Trim())
    [void]$out.Add('  记忆检查: ' + $ok)

    $out | Set-Content -Path (Join-Path $script:DataDir 'selftest.txt') -Encoding UTF8
    try { Remove-Item (Join-Path $script:DataDir 'widget.pid') -ErrorAction SilentlyContinue } catch { }
    $form.Close()
    return
  }

  Apply-Page          # 按上次记住的页面显示
  # 折叠状态：命令行 -Collapse 优先，其次按上次记住的
  if ($Collapse -ne '') { Set-Collapsed -Edge $Collapse }
  elseif ($script:RestoreCollapsed -and $script:RestoreEdge) { Set-Collapsed -Edge $script:RestoreEdge }
  # 性能监控小窗：立刻按配置建好并显示，别等第一个 tick（否则会有近 1 秒的空档）
  try { Update-Monitor } catch { }
  $timer.Start()
  Open-DshWeb         # 启动统计弹窗时自动打开 DSH Web 界面
})

# -Preview 要在 ShowDialog 之前跑完并退出：受限会话里 ShowDialog 会立刻返回、Add_Shown 也不触发，
# 放在 Shown 里的话预览永远是空的；而且这样 Preview 模式绝不会进消息循环（不会挂住）。
if ($Preview) {
  [void](Show-PreviewPages)
  exit 0
}

[void]$form.ShowDialog()
$timer.Stop()
$timer.Dispose()

