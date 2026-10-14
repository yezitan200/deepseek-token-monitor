# token-monitor 移植到 Linux · 方案（V1 定稿）

> 写于 2026-10-13，同日按用户决定更新。**这份文档只是方案，没有改动任何代码。**
> 目标读者：你和下一个接手这件事的会话。
>
> - **已定 ①**：分开维护 —— Windows 版冻结不动，Linux 版另立一份 → 第 3 节
> - **已定 ②**：桌面环境按"**GNOME-Wayland / GNOME-X11 / KDE 三个会话都能降级运行**"设计 → 第 5 节末
> - **已定 ③**：先定稿文档、暂不写代码（2026-10-13 用户指示）
> - **还开着**：先做 P0 还是直接上 Electron → 第 9 节
> - **已完成**：第 11 节（Linux 系统信息采集的实证做法）、第 12 节（跨平台工程与打包的实证做法）
> - **未做（用户 2026-10-13 决定到此为止）**：`refs\` 里还剩 **1 个**源码文件
>   （`源码\Customization\LinuxVariableProvider.cs`）**未通过** blob SHA 校验 ——
>   第 11.2 节引用它的行号与正文**不保证逐字准确**；其余 **22 个已全部通过**，
>   逐文件状态见 `refs\zmd-charge-plus\README.md`

---

## 0. 一页结论

1. **这不是"移植"，是"重写外壳"。** 后端 [proxy.js](proxy.js) 是一份干净的、跨平台的 Node 程序，
   **在 Linux 上今天就能跑**；要重写的是那 26 万字符的 Windows 专用界面
   （[widget.ps1](widget.ps1) 119KB + [Launcher.cs](launcher/Launcher.cs) 144KB）。
2. **PowerShell 这条路在 Linux 上是死的。** Linux 上有 pwsh 7，但**没有 WinForms、没有 GDI+、没有 user32/dwmapi**。
   把 widget.ps1 "翻译"成别的 GUI 是下策——那套界面（进度圆环、贴边折叠、胶囊按钮、悬停提示、
   性能小窗）重画一遍比翻译一遍便宜得多。
3. **因为你选了"发给别人"，我推荐 Electron，而且理由比"省事"更硬**：Electron 自带 Node 运行时，
   收件人**什么都不用装**；而现在的 Windows 包其实要求对方机器上有 Node.js ——在 Linux 上这个要求
   比 Windows 更难受（各发行版仓库的 Node 版本参差，不装开发环境的人多半一个都没有）。
4. **但不要一上来就重写界面。** 第 4 节的 P0 阶段**零代码改动**，就能让 Linux 上先有统计数据可看。
5. **一件必须先说清的事**：我这台机器是 Windows，**Linux 相关的东西我在本机无法真实验证**。
   按你们项目的铁律（"改完必须真跑一次"），Linux 版的验收只能由你或收件人在 Linux 上做，
   或者用 WSL2 + WSLg 跑一个近似环境（能截图，但**不能代表真实 Wayland 桌面**，见第 5 节）。

---

## 1. 现状盘点：哪些能带走、哪些必须换

| 现在的文件 | 大小 | Linux 上的命运 | 说明 |
|---|---|---|---|
| `proxy.js` | 70KB | **✅ 原样可用，零改动** | 纯 Node（http/https/fs/zlib/path）。时机计算是**手算 UTC+8**，不依赖系统时区；取主目录用的是 `process.env.USERPROFILE \|\| process.env.HOME`，Linux 上走 `HOME`。连 `startWidget()` 都已经写好了平台判断（非 win32 直接跳过）。 |
| `dashboard.html` | 7KB | **✅ 原样可用** | 浏览器页面，天然跨平台。 |
| `config.template.json` / `config.json` | 1KB | **✅ 能用，但位置要挪** | 见第 2 节的"配置放哪"。 |
| `widget.ps1` | 119KB | **❌ 必须重写** | PowerShell + WinForms + GDI+ + user32/dwmapi（置顶、圆角、DPI）+ WMI（CPU/内存/电池）+ 单实例互斥锁。 |
| `Launcher.cs` | 144KB | **❌ 必须重写** | WinForms 启动器 + 三页设置窗 + 自签名/签名校验 + `taskkill` + DWM。功能本身可以搬到别处（见下）。 |
| `start.cmd` / `stop.cmd` | 1.6KB | **❌ 换 shell 脚本** | 逻辑很简单（`node proxy.js` 后台起 + 写 pid + 关闭时按 pid kill），照抄成 `start.sh` / `stop.sh` 即可。 |
| `build-launcher.cmd`、`tools/sign-local.ps1`、`信任并签名.cmd`、`取消信任.cmd`、`swap-exe.ps1` | — | **❌ 整个丢掉** | Linux 不签名、没有"未知发布者"弹窗，改用 `chmod +x` + AppImage/deb。 |
| `token-monitor.exe`、`*.ico` | 430KB | 换 | exe → AppImage/deb；`.ico` → `.png` 图标集（AppImage 用 256/512 PNG）。 |
| 界面预览图 `preview-*.png` / `settings-*.png` | — | 重生成 | 换了 GUI 框架就必须重生成（维护手册 9.6 里那条"改了界面图就必须重生成"照样适用）。 |
| `经验\` 下那些探针脚本（共 40 个文件） | — | 大部分作废 | `.ps1` 探针靠 WinForms/PS 5.1 工作，Linux 下换成新的验证手段（第 8 节）。`probe-peakwindow.js`、`check-dashboard.js`、`fake-upstream.js` 这几个纯 Node 的**能继续用**。 |

### proxy.js 是怎么做到"零改动"的（证据）

- 时区：[proxy.js:459](proxy.js#L459) `beijingParts()` 用 `Date.now() + 8*3600*1000` 再取 UTC 字段——
  纯算术，不受系统时区影响。**这一点在 Linux 上尤其重要，因为服务器常见 UTC 时区**，
  要是当时图省事用了本地时间，这个移植就得连业务逻辑一起改。
- 平台分支：[proxy.js:1774](proxy.js#L1774) 已经写了 `if (process.platform !== 'win32')` 就跳过悬浮窗。
  → 所以 Linux 上 `node proxy.js` 直接就能跑，只是没有窗口。

---

## 2. Linux 上的目标形态

### 长什么样

```
用户双击 token-monitor.AppImage
   ├─ 统计代理自动起（127.0.0.1:8788，同现在）
   ├─ 桌面悬浮窗出现（置顶、可拖动、贴边折叠成小标签）
   ├─ 悬浮窗正下方的小窗（CPU / 内存 / 电池）
   ├─ 托盘图标（右键：开关面板 / 退出）—— 可选
   └─ 设置窗（照现在三页：API Key / 性能监控 / 余额提醒）
```

### 文件放哪（这条是 Linux 上最容易踩的坑）

Windows 版是"绿色版"思路：`config.json` 和 `data\` 就放在程序目录里。
**AppImage 运行时的挂载点是只读的**，程序目录里根本写不进去——照搬这个思路，
第一次运行就会因为"写不了 config.json"直接崩。

Linux 上按 XDG 规范分开放：

| 内容 | 现在（Windows） | Linux |
|---|---|---|
| 配置 `config.json` | 程序目录 | `~/.config/token-monitor/config.json` |
| 数据 `data/`（usage.jsonl、pid、日志） | 程序目录 | `~/.local/share/token-monitor/` |
| 图标 / .desktop | 无 | `~/.local/share/icons/` + `~/.local/share/applications/` |
| 开机自启（可选） | 启动文件夹 / 计划任务 | `~/.config/autostart/token-monitor.desktop` |

> 也可以走"便携模式"（数据仍放程序目录旁），但那要用户自己解压出目录来跑，
> 和"双击 AppImage 就能用"的目标冲突。**默认按 XDG 走，留一个 `--portable` 开关给想放 U 盘的人。**
>
> 好处：`proxy.js` 那边只需要把 `ROOT`（数据目录的基准）改成"可配置的基准目录"，
> 大概十几行的事——这是 P0 阶段唯一需要动 proxy.js 的地方（**可选**，见 P0 说明）。

---

## 3. 三条路线

| | A. Electron | B. Tauri (Rust) | C. 只要代理 + 浏览器面板（可选托盘） |
|---|---|---|---|
| 包体积 | ~90–120MB（AppImage） | ~8–15MB | ~50–110MB（要自带一个 Node 二进制）或 300KB（要求对方自装 Node） |
| 收件人需要装什么 | **什么都不用装** | 什么都不用装 | 要么装 Node 18+，要么包里带 Node |
| 界面能力 | 完全够（现在的界面都能画出来） | 够，但要多写一套前端 | 没有悬浮窗，只有网页 |
| 复用现有资产 | `proxy.js` 直接跑、`dashboard.html` 样式直接抄 | `proxy.js` 得靠 sidecar（等于把 A 的复杂度再叠一层） | `proxy.js` 直接跑 |
| 三平台统一 | ✅ 一套代码出三平台（**已定"分开维护"后这条不再是理由**，见下） | ✅ 同样 | ✅ |
| 我估计的工作量 | **大**（主要花在重画悬浮窗 + 设置窗） | 更大（多一门语言 + 工具链） | **小**（P0 半天） |
| 风险 | 中：Wayland 下的置顶/定位要实测 | 高：Rust 工具链 + 交叉编译 | 低 |

### 我的推荐：**先 C，再 A**；B 不建议

- **B（Tauri）不建议**：省下的 100MB 对桌面小工具不值一提，多出来的 Rust 工具链、
  交叉编译、`proxy.js` 的 sidecar 集成，全是纯增量成本。
- **A（Electron）是终局**：因为你选的是"发给别人"。收件人不用装 Node、不用装 PowerShell，
  这一点在 Linux 上价值极大。
- **但先做 C 的 P0**：零风险、当天见效，而且 P0 补的启动/pid/配置逻辑，
  后面 Electron 版**一行都不用重写**（Electron 主进程照样要干这几件事）。

### 版本怎么分 ✅ 已定（2026-10-13）：分开维护，Windows 版冻结不动

**用户的决定（原话）**："我建议是分开版本，避免修改 win 端后出现新 bug。"

这个判断站得住，理由不是"省事"，而是**风险隔离**：Windows 版 V1.1.0 已经在别人机器上跑着了，
它是"已完成、已验证"的资产。把它的命运和一次 26 万字符的重写绑在一起，才是真正的不划算。
参考项目 `zmd-charge-plus` 最后也是这么走的（Windows / Linux / macOS / Android 各一个仓库，
`-for-linux` 那份连 UI 都是重新实现的）。

**目录与仓库怎么摆**（照参考项目的兄弟仓库模式）：

```
D:\little thing\token-monitor\          ← Windows 版：冻结。只修 bug，不加新功能
D:\little thing\token-monitor-linux\    ← Linux 版：新目录 + 独立仓库，自由演进
```

**切在哪一刀（这一刀决定后面省不省心）**：

| 层 | 怎么处理 | 为什么 |
|---|---|---|
| `widget.ps1` + `Launcher.cs`（26 万字符界面/启动器） | **完全不进 Linux 版**，Linux 版自己写 | 这层是**最容易出 bug、也改得最勤**的一层。分开之后，改 Linux 界面**在物理上不可能**碰到 Windows 那套 —— 这正是你要的效果 |
| `proxy.js`（70KB 后端） | **复制一份进 Linux 版**，之后在 Linux 版里独立改 | 见下面那条"代价" |
| `dashboard.html` | 复制，按 Linux 版的需要改 | 同上 |
| `*.cmd` / `*.ps1` 工具 / 签名那套 | 不带过去 | Linux 上本来就不需要 |
| 文档（README / 使用说明 / 分发包说明） | Linux 版**自己一套** | 版本号、安装步骤、界面截图都不一样了 |

**⚠️ 代价（我不藏着）：`proxy.js` 会变成两份，以后改一处要同步另一处。**
一份 70KB 里装着最值钱、也最微妙的东西（token 口径、价格抓取、节假日表、高峰判定、统计接口），
而这里恰恰是最可能出现"上游改版导致要修"的地方（比如 DeepSeek 改了价格页结构 → 抓取解析要跟进）。

不推荐为此把后端做成"共享库"：那等于又把两边耦回去，你担心的风险会原样回来。
**推荐的做法是"拷贝 + 极小的分叉点 + 一份同步备忘"**：

1. Linux 版从 Windows 版的某个版本**整体拷一份** `proxy.js`（记为上游 v1.1.0）。
2. Linux 版只允许改**三处**（XDG 数据目录、`startWidget()` 那段、非 Windows 的提示文案），
   每处用 `// [linux-fork]` 注释标出来。
3. Linux 版放一份 `上游同步.md`：写清上游版本、这三处的 diff、以及"上游修了 bug 时怎么同步"
   （`diff` 出来只应该看到这三处 → 重新拷贝 → 把三处补回 → 真跑一次）。
   **同步是一次 5 分钟的机械活，而不是每天都要付的成本。**

**这条决定带来的一个连锁结论**：既然是 Linux 单独一份，那 Electron 原本"一套代码出三平台"的
优势就用不上了。但 Electron **依然是对的**——理由换成另外两条，而且这两条才是要害：
① **自带 Node 运行时**，收件人什么都不用装（Linux 上没装 Node 的人比 Windows 还多）；
② 界面用 HTML/CSS 画，比重新学一门 GUI 框架便宜，你的 `dashboard.html` 还能直接复用。
（如果你的核心本来就是 C#，那 Avalonia 更顺——参考项目就是那样。我们的核心是 Node，所以不是。）

---

## 4. 分阶段计划

### P0 · "Linux 上先有统计"（零代码改动，半天内可验证）

**不写一行代码就能做的事**（你可以自己在任意 Linux 机器上验）：

```bash
# 1. 解压包到一个目录，装 Node 18+（Ubuntu/Debian: sudo apt install nodejs）
# 2. 手动生成配置（Windows 上是启动器自动做的，Linux 上还没有启动器）
cp config.template.json config.json
# 3. 起代理
node proxy.js
# 4. 看数据
#    浏览器打开 http://127.0.0.1:8788/__dashboard
curl http://127.0.0.1:8788/__health
```

**P0 要补的东西**（工作量：小，1–2 小时 + 真机验证）：

| 要做 | 内容 |
|---|---|
| `linux/start.sh` | 照 `start.cmd` 的逻辑：查 node 在不在（**没有就给中文引导**，这正是维护手册 9.6 里"还没做"的那条）→ 缺 config.json 就从模板复制 → 后台起代理（`nohup`）→ 写 `data/proxy.pid` → 打印面板地址 |
| `linux/stop.sh` | 照 `stop.cmd`：读 `data/proxy.pid` → `kill` → 删 pid 文件（**注意：现在写的是 `taskkill /F`，Linux 上先 `kill` 再 `kill -9`**） |
| `proxy.js` 一小改（可选） | `startWidget()` 那句提示从"悬浮窗目前只支持 Windows，跳过"改成"Linux 版悬浮窗见 P1"；数据目录改成可配置（第 2 节） |
| `使用说明-Linux.txt` | 中文三步 + "只监听本机 + 别外发 config.json"那两条注意事项 |

**验收标准**：在一台真 Linux 上 `node proxy.js` 起来，浏览器面板能出数，
`node proxy.js --mock` + `node test-client.js` 能跑出一笔假用量。

### P1 · Electron 外壳（主要工作量）

| 模块 | 要做什么 | 难度 |
|---|---|---|
| 主进程 | 把 `proxy.js` 作为模块或子进程拉起来（**子进程要用 `process.execPath`，不能 `spawn('node')`**——Electron 里没有独立的 node）；单实例锁用 `app.requestSingleInstanceLock()` | 低 |
| 悬浮窗 | 无边框透明窗：`frame:false, transparent:true, alwaysOnTop:true, skipTaskbar:true, resizable:false`；置顶用 `setAlwaysOnTop(true,'screen-saver')`；圆角/阴影交给 CSS + 合成器 | 中 |
| 两页界面 | 账户页（余额、价格、时段进度环、余额变红）+ 用量页（总量、本轮、花费）；`dashboard.html` 的配色/排版可以直接搬过来 | 中 |
| 折叠吸附 | 拖动结束时读鼠标位置，距屏幕边缘 <阈值 → 缩成贴边小标签（现在这套几何逻辑在 widget.ps1 里，思路照抄） | 中 |
| 悬停提示 | 现在用 WinForms `ToolTip` → 改成 CSS 自绘（明细都在提示里，见 README 第三节） | 低 |
| 性能小窗 | 第二个 BrowserWindow，坐标按悬浮窗位置算（替代 `Move-MonitorToOwner`）；数据源：CPU `/proc/stat`、内存 `/proc/meminfo`、电池 `/sys/class/power_supply/BAT*/`（**WMI 那套整块换掉**） | 中 |
| 设置窗 | 三页（API Key / 性能监控 / 余额提醒）；现在的开关是自绘的（图一那套），CSS 重画即可 | 中 |
| 右键菜单 / 托盘 / 快捷键 | Esc 关闭、齿轮设置、右键那 8 项菜单；托盘可选 | 低 |
| 自检与预览 | 现在的 `-Preview`（离屏渲染）+ `--render-settings` + `--dump-settings-layout` 换成 `webContents.capturePage()` + 控件树 dump | 低 |

⚠️ **一条从维护手册里继承过来的铁律**：9.2d 那条"**离屏渲染图不是验收**——
`DrawToBitmap` 的绘制顺序和真窗口不一样，被盖住的按钮在预览图里照样看得见"。
在 Electron 里 `capturePage()` **同样是离屏**，同样的坑会再出现一次。真窗口截图才算验收。

**验收标准**：在真 Linux 桌面（见第 5 节的会话类型要求）上，悬浮窗能拖动、能贴边折叠、
两页数字与 `/__stats` 一致、余额变红逻辑和 Windows 版一致、设置窗三页能存能生效。

### P2 · 打包分发（1 天量级）

- `electron-builder` → **AppImage（主力，双击就跑，几乎全发行版通用）** + **.deb（Debian/Ubuntu 用户友好）**，
  可选 `.rpm`。
- 一份 Linux 版 `README.md`（从 `README-分发.md` 改）+ `使用说明.txt` 的 Linux 版。
- **"四道校验"的 Linux 版**（现在是"不含 Key / 不含 config.json 与 data\ / 每个 .ps1 带 BOM / 报告签名状态"，
  后两道在 Linux 上没意义了）：

| 新的校验 | 内容 |
|---|---|
| ① 不含 API Key | 同现在：文本 + 二进制都扫一遍 |
| ② 不含 `config.json` / `data/` 历史与日志 | 同现在 |
| ③ 配置与数据不在包内，走 XDG | **新增**：确认程序不会往只读的 AppImage 挂载点写 |
| ④ 图标与 .desktop 齐全、可执行位正确 | 替代原来的 BOM / 签名校验 |

### P3 · 收尾与长期维护（按已定的"分开维护"来）

- **Windows 版冻结**：`token-monitor\` 不再加新功能，只修 bug。它现在的打包脚本、
  `README-分发.md`、分发包**原样保留**，不因为 Linux 版而改动 —— 这正是你要的隔离。
- **Linux 版自己一套文档**：`README.md`、`使用说明.txt`、`README-分发.md`，
  版本号独立走（例如 Linux 版从 v1.0.0 起，不要和 Windows 的 V1.1.0 混着报）。
- Windows 版主 README 加一句："Linux 版是独立实现，在 `token-monitor-linux\`，
  两边外观与配置方式不完全一致"，免得以后自己看混。
- Linux 版自己一套验证脚本（参考项目的 `smoke-linux.sh` / `verify-linux-packages.sh` /
  `audit-linux-variables.sh` 就是这个路子，等第 11 节的研究结论回来再定具体清单）。

---

## 5. Linux 特有的坑（都是能预见的，不是猜的）

> 2026-10-13 补充：下面这张表是**设计期预判**。从参考实现里摘出来的**实证版**坑（依赖清单、
> Wayland 指针查询的原文注释、权限静默失败、容器无配额视图、CPU 百分比口径）在 **第 11.5 节**，
> 两处一起看。

| # | 坑 | 影响 | 对策 |
|---|---|---|---|
| 1 | **Wayland 会话** | GNOME 默认 Wayland **不允许客户端自己决定窗口位置**，`setPosition` 无效、置顶也可能受限 → **"拖到边缘 12px 折叠"直接废掉** | Electron 默认在 Wayland 会话下走 **XWayland**，这条路通常能保住置顶与定位；**若显式开原生 Wayland（`--ozone-platform=wayland`）就会失去**。→ 已按下面的"桌面兼容策略"设计成可降级；但**真机上仍必须三种会话各测一次**，这是全项目最大的未知数 |
| 2 | **AppImage 只读** | 程序无法在包内写 `config.json` / `data/` | 走 XDG 目录（第 2 节），或提供 `--portable` |
| 3 | **GNOME 没有系统托盘** | 托盘图标看不见（要装 AppIndicator 扩展） | **别把关键入口只放托盘**；悬浮窗 + 网页面板才是主入口 |
| 4 | **字体不同** | Windows 下量出来的字号（8pt / 8.5pt）是在微软雅黑下量的，Linux 没有雅黑 | 用 Noto Sans CJK / 思源黑体，**所有"实测字宽留框"的地方都要在 Linux 上重新量**（维护手册 9.1 那条"文字宽=xx"的自检逻辑照样要有） |
| 5 | **无边框透明窗** | 部分合成器下透明失效或出现黑底 | `transparent:true` + `backgroundColor:'#00000000'`；X11 下通常没问题 |
| 6 | **进程管理** | `taskkill` 不存在 | 已经用 `proxy.pid` 记录 pid → 换 `kill`；悬浮窗同理 |
| 7 | **节点运行时** | Electron 里没有独立的 `node` 可执行文件 | 子进程用 `process.execPath` + `ELECTRON_RUN_AS_NODE=1`，或直接把 proxy 作为模块 require 进主进程（**更推荐**，省一个进程） |
| 8 | **DPI / 缩放** | Windows 那套"进程声明 DPI 感知 + 手动乘 1.25"的代码全部作废 | Electron 的 CSS px 天然处理——**这反而是净收益**，顺手解决维护手册 9.2d 末尾那笔欠账 |
| 9 | **自启** | 启动文件夹 / 计划任务 | `~/.config/autostart/*.desktop` |
| 10 | **时区** | Linux 机器常常是 UTC | **已经安全**（UTC+8 手算），只有界面上 `toLocaleTimeString()` 的展示会跟系统时区——不影响计价 |
| 11 | **快捷键 / 焦点** | Windows 那套 `SetForegroundWindow` 没有对应 | 悬浮窗本身不需要抢焦点，一般无碍 |

### 桌面兼容策略 ✅ 已定（2026-10-13）：三个会话都要能跑

**用户的回答**：桌面环境"不确定 / 还没装 Linux"。那就不能只按一种会话设计，得按
"**最差的那个也要能降级运行**"来做。

| 会话 | 置顶 | 窗口定位 | 贴边折叠 | 我们怎么做 |
|---|---|---|---|---|
| GNOME / X11 | ✅ | ✅ | ✅ | 什么都不用改，按现有设计做 |
| KDE Plasma（Wayland 或 X11） | ✅ | ✅（KWin 支持） | ✅ | 同上；KDE 原生支持托盘 |
| GNOME / Wayland | ⚠️ 走 XWayland 通常可以 | ❌ 原生 Wayland 下客户端**不能自己定位窗口** | ⚠️ | **默认让 Electron 跑 XWayland**（不要开 `--ozone-platform=wayland`）；启动时自检，定位不生效就切"不贴边"模式 |

三条设计要求（直接写进 P1 的验收标准）：

1. **定位**：启动时先试着把窗口放到"记忆中的位置 / 默认右下角"，然后**读回实际位置来验证**；
   读回的值不是我们要的 → 判定"这个会话不允许自定位" → 降级为窗口居中 + 以网页面板为主界面，
   并在日志和界面上**明说**"当前桌面不允许悬浮窗自动定位"。**不许假装成功。**
2. **贴边折叠**：折叠前先确认"窗口能移动"。不能移动时，把折叠改成**按钮触发**
   （点一下收起 / 展开），而不是靠"拖到边缘 12px"。功能不丢，只是触发方式变了。
3. **托盘**：托盘图标只算锦上添花，**关键入口不能只放托盘**（GNOME 默认没有托盘，要装扩展）。
   悬浮窗和 `__dashboard` 网页面板必须各自都是完整的入口。

> 验收的硬要求（承接维护手册那条"离屏渲染不是验收"）：**三种会话各截一次真窗口的图**。
> 注意 **WSLg 是 Weston 模拟，不能当作 GNOME Wayland 的验收**（第 8 节那条）。

---

## 6. 打包产物清单（Linux 包里该有什么）

```
token-monitor-v2.0.0-x86_64.AppImage      ← 主力，双击就跑
token-monitor_2.0.0_amd64.deb             ← Debian/Ubuntu 用户
README.md                                 ← 给收件人的（Linux 版）
使用说明.txt                               ← 中文三步
（图标已内嵌，不需要额外文件）
```

**不应该有的**：`config.json`、`data/`、你们的 API Key、`*.bak`、探针脚本、维护手册
（维护手册是内部文档，和现在的规矩一致）。

### 打包与校验：照第 12.5 / 12.6 节那套来（实证过，可整套照抄）

一次构建出多种包 → **每种都解包自检** + `desktop-file-validate` +
**原生库 `ldd … | grep 'not found'`** + 真启动 smoke → 最后出 `SHA256SUMS`。另外四条：

- **必须在 Linux 文件系统上打包**（WSL / NTFS 会吃掉可执行位与软链，包是坏的）；
- **AppImage 的 FUSE 两头都要规避**：制作端 `--appimage-extract`、运行/测试端 `APPIMAGE_EXTRACT_AND_RUN=1`；
- **体积预期**：同量级产品（C# 自包含）的 `.deb` 是 **32.8 MiB、装完约 97MB**，Electron 与之相当
  —— 这也回答了你可能关心的"发给别人会不会太大"；
- 想让对方"像装软件一样装"，可以照他**自建 APT 源**那套（keyring + `install.sh` 一行命令 +
  域名/Pages 托管）；不想维护源就只发 AppImage + deb。

---

## 7. 文档要动的地方

| 文档 | 怎么改 |
|---|---|
| `README.md`（主） | 顶部加一行"Windows / Linux 都支持"；Linux 的安装与启动写进第一、二节 |
| `使用说明.txt` | 出 Linux 版（现在那句"Windows 10/11（悬浮窗和启动器是 Windows 专用）"要改） |
| `开发资料夹说明.md` | 新增 Linux 侧文件清单（`main.js` / `renderer/` / `linux/*.sh`） |
| `维护手册.md` | 新增一节 `9.10 Linux 端的坑`（第 5 节那张表直接搬进去），并写明"离屏渲染不是验收"在 Electron 下同样成立 |
| `README-分发.md` | 出 Linux 版 |
| `经验\v0.3-精简版（人格与印象）.txt` | **不写技术细节**（这是你们定下的规矩），只在收尾时记一句"接了 Linux 这件事、决定是什么" |

---

## 8. 我没法在本机验证的部分（如实交代）

- 我跑在 **Windows** 上。P0 的脚本我可以写、可以用 pwsh 做语法检查，
  **但"在 Linux 上真的起来了"这句话我不能说**——必须你在 Linux 上跑一次。
- 折中办法：**WSL2 + WSLg**（Windows 11 自带）能真跑 Linux 的 Node 和 GUI 程序、能截图，
  可以让我把 P1 的界面改到"看起来对了"。
  但 **WSLg 是 Weston/Wayland 的模拟环境，它的窗口定位行为与真实 GNOME Wayland / KDE 都不一样**，
  所以第 5 节第 1 条那个坑，**WSLg 验不出来**，只能上真机。
- 验收手段要跟着换：现在是 `grab-widget.ps1`（按 pid 截窗口）和像素计数。
  Linux 上对应的是 `grim`（Wayland）/ `import`/`scrot`（X11）配合 pid 找窗口，
  或者直接用 Electron 的 `--selftest` 输出几何数据（**不依赖截图，比像素计数更可靠**）。

---

## 9. 已定的事，与还开着的一条岔路

**① ✅ 分开维护**（2026-10-13 定）：Windows 版冻结不动；Linux 版在
`D:\little thing\token-monitor-linux\` 另立一份、独立仓库。
理由、切在哪一刀、`proxy.js` 两份怎么同步 → 全部在第 3 节"版本怎么分"。

**② ✅ 桌面按"三个会话都能跑"设计**（2026-10-13 定）：你回答的是"不确定 / 还没装 Linux"，
所以按**最差的会话**设计并给 X11 回退 → 第 5 节末"桌面兼容策略"。
这条路子有个好处：**不必等你买/装 Linux 机器才能开工**，三套会话的降级逻辑都是设计期就能定死的。

**③ ⏳ 还开着：先做哪一步？**

你 2026-10-13 的指示是"**先别写代码，先把文档定稿**"，所以代码一行没动。这份文档定稿之后，
要定的就只剩这一步：

- **先做 P0**：只有代理 + 浏览器面板，当天见效、零风险，先让 Linux 上"有数可看"；
- 或**直接上 Electron**：一次把悬浮窗做出来，但真机验证之前看不到东西。

两者不是二选一，是先后。P0 补的启动 / pid / 配置那套逻辑，Electron 版里**一行都不用重写**。

---

## 10. 附：文件级对照表（Windows → Linux）

| Windows 现在 | Linux 目标 | 说明 |
|---|---|---|
| `token-monitor.exe`（Launcher.cs 编译产物） | `token-monitor` AppImage | Electron 打包 |
| `widget.ps1` | `src/renderer/widget/*` | HTML/CSS/JS 重画 |
| Launcher.cs 的 `SettingsForm` | `src/renderer/settings/*` | 三页照搬 |
| Launcher.cs 的 `--check` / `--auto` / `--restart-widget` | 主进程内部函数 + `--check` / `--restart` 命令行开关 | 保留这些开关，方便排查 |
| `start.cmd` / `stop.cmd` | `linux/start.sh` / `stop.sh` | P0 就做 |
| `data/proxy.pid` / `widget.pid` | 同（放 `~/.local/share/token-monitor/`） | `kill` 替代 `taskkill` |
| `config.json`（程序目录） | `~/.config/token-monitor/config.json` | 首次运行从模板复制 |
| WMI（CPU/内存/电池） | `/proc/stat`（前 8 个计数器差分）、`/proc/meminfo`（kB×1024）、`/sys/class/power_supply/*`（`power_now` µW÷1e6，回落 `current_now`×`voltage_now`÷1e12） | 整块换 —— **具体做法与出处见第 11.2 节**，全程不用装任何东西 |
| 单实例互斥锁 | `app.requestSingleInstanceLock()` | 语义一致，顺带解决"静默退出被误判成起不来"那个老坑 |
| `DwmSetWindowAttribute`（圆角/深色） | CSS + 合成器 | 作废 |
| `tools/sign-local.ps1`、`信任并签名.cmd` | —— | 整体删除 |

---

## 11. 参考实现：别人是怎么在 Linux 上读系统信息的 ✅ 已完成（2026-10-13）

### 11.1 一句话结论（这条对我们最有利）

**整个 Linux 采集路径里，spawn 外部命令只有 2 处**——`nvidia-smi`（GPU）和开发者工具版本查询
（`node`/`python3`/`git`/`docker`…）。**其余全部是读 `/proc`、`/sys` 文件。**
`lm-sensors`、`upower`、`acpi`、`free`、`df`、`top`、`ps` **一个都没用**。

也就是说：**Linux 版的性能小窗不需要引入任何依赖、不需要提权、不需要装传感器服务**，
纯读文件就能做出来。这对我们是好消息——`proxy.js` 读文件本来就是强项。

> **材料在哪**：`refs\zmd-charge-plus\Linux系统信息采集技术报告.md`（56KB / 667 行，逐条带文件+行号出处），
> 同目录还有 10 个**解码出来的原始源码**（字节数与 GitHub API 的 `size` 核对过，7 个完全一致；
> **但这个校验挡不住"等长损坏"**，见本节末尾 ③ —— 引用行号以报告为准，别把源码文件当成逐字保真）。
> 研究对象是 [`zmd-charge-plus-for-linux`](https://github.com/GlacierGlimmer/zmd-charge-plus-for-linux)（C# + Avalonia）。
> ⚠️ 你给的那个 Windows 仓库里**没有 Linux 代码**：它的 csproj 写着
> `<Compile Remove="Customization\Linux*.cs;Interop\LinuxDesktop.cs" />`，而 Linux 实现在另一个仓库。

### 11.2 我们真正要的三项（性能小窗：CPU / 内存 / 电池功率）

| 我们要显示 | Linux 上怎么做 | 出处 |
|---|---|---|
| **CPU 占用** | 读 `/proc/stat` 的 `cpu ` 行，取**前 8 个**计数器（user,nice,system,idle,iowait,irq,softirq,steal），两次采样求差。**故意不取 `guest`/`guest_nice`——它们已经算进 user/nice，再算一遍是重复计数**（`/proc/stat` 的经典坑，原作者把注释写在代码里） | `LinuxVariableProvider.cs:53-72` |
| **内存占用** | 读 `/proc/meminfo` 的 `MemTotal`、`MemAvailable`（单位 kB，**×1024**）；`used = MemTotal − MemAvailable` | `LinuxVariableProvider.cs:140-154` |
| **电池功率** | 遍历 `/sys/class/power_supply/*`：优先 `power_now`（µW，**÷1e6** → W）；没有则回落 `current_now`（µA）× `voltage_now`（µV）**÷1e12**；取绝对值 | `LinuxVariableProvider.cs:231-235` |
| 电池百分比 | `energy_now`/`energy_full`（µWh **÷1000**）优先；缺失回落 `charge_*` × `voltage_min_design`（没有就用 `voltage_now`）÷1e9；再不行用各电池 `capacity` 的平均值（要求全部在 0–100） | `LinuxVariableProvider.cs:207-229` |
| 电池"插着电吗" | 遍历 `/sys/class/power_supply/*`，**跳过 `type == "Battery"` 的**，读它的 `online`（只认 0/1） | `LinuxVariableProvider.cs:175-190` |
| 电池状态字 | 各电池的 `status`，命中字面量 `Charging` / `Discharging` / `Full` | `LinuxVariableProvider.cs:194-203` |
| （顺带）CPU 温度 | 只认 hwmon 驱动名是 `coretemp` / `k10temp` / `cpu_thermal` 的 `temp*_input`，**÷1000**。因为绕开了 lm-sensors，代价是**别的驱动（acpitz/thinkpad/dell_smm/superio）即使能读也不采** | `LinuxVariableProvider.cs:103-108` |
| （顺带）磁盘容量 | 挂载表读 `/proc/self/mountinfo`（挂载点要解八进制转义），容量用 .NET `DriveInfo` —— **我们对应的是 Node 自带的 `fs.statfs()`（18.15+），不用 `df`** | `LinuxDisks.cs:19-63` |
| （顺带）网络速率 | `/sys/class/net/<if>/statistics/{rx,tx}_bytes` 差分；链路速率 `/sys/class/net/<if>/speed`（Mb/s ×1e6） | `LinuxNetwork.cs:19-22,60-70` |

### 11.3 四条值得直接抄的规矩（比具体路径更重要）

1. **差分只用单调时钟，并且每项都校验"新值 ≥ 旧值"**：`Stopwatch.GetTimestamp()`（Node 里对应
   `process.hrtime.bigint()`）。发现回绕/重置就**跳过本轮速率**，但旧值照常更新；
   速率**除以真实经过的秒数**，不是假定周期。
2. **第一次没有历史值：不出数。** 不猜、不给 0、不给缓存值——界面上就是不显示这一项。
   唯一的例外是"一个网卡都没有"时明确给 0（那确实是断网状态）。
3. **`null` 就不写这个键**：即"**变量不存在 = 硬件/权限不支持**"，而不是"值等于 0"。
   → 我们的 `__stats` 和小窗要照这个来：**拿不到就显示 `—`，绝不显示 0**
   （否则"电池 0W"和"这台机器没有电池"就分不出来了）。
4. **进程样本用"启动时间"当键**防 PID 复用；网络速率额外要求"**网卡名集合没变**"才出数
   （插拔网卡那一轮不出数）。

### 11.4 外部命令的统一封装（我们只有"读 GPU / 查版本"这种场景，但规矩照样有用）

参考实现的 `LinuxCommand`（42 行全文，`LinuxCommand.cs:1-42`）值得照抄的几条：
手扫 `PATH`（默认 `/usr/bin:/bin`）并**检查可执行位**；用参数数组而不是拼字符串（天然免 shell 注入）；
设 `LC_ALL=C` 保证输出可解析；**2500ms 超时后杀整个进程树**；非 0 退出码一律当成失败返回 `null`；
stdout 为空时回落 stderr。

### 11.5 从参考实现里摘出来的坑（补第 5 节那张表）

| 坑 | 说明 |
|---|---|
| **依赖清单** | 参考项目明确要求 **glibc 2.35+、OpenSSL 3、X11/XWayland**；不提供 ARM64 / 32 位 / Alpine(musl) 包。Ubuntu 上要装 `libx11-6 libxext6 libxrender1 libxrandr2 libxi6 libxcursor1 libice6 libsm6 libfontconfig1 libxcb1 libssl3 zlib1g fonts-noto-cjk xdg-utils` —— **这正是 Electron 在 Linux 上的依赖清单**，也印证了第 5 节第 4 条"字体"（`fonts-noto-cjk` 得让对方装上） |
| **原生 Wayland 不允许全局指针查询** | 原作者在 `Interop/LinuxDesktop.cs:6` 注释里原话：`native Wayland does not permit global pointer queries.` —— **这正面印证了第 5 节第 1 条**，也说明"跟着鼠标拖动窗口"那条路在原生 Wayland 上根本不通，必须交给合成器（Electron 里用 `-webkit-app-region: drag` / `startSystemMove`） |
| **托盘** | 需要桌面支持 AppIndicator / StatusNotifier；GNOME 没开扩展就看不见 → 与第 5 节第 3 条一致 |
| **权限静默失败** | `/proc/<pid>/io` 对**别人的进程**不可读；`Secure Boot` 读 efivars 通常要 root。两处都是 `catch` 吞掉、**不给任何提示**——这点他们做得不好，**我们该明确显示"权限不足"而不是空白** |
| **没有电池** | 台式机直接 `return`，整个电池区块不显示（不是显示 0）——与 11.3 第 3 条同一套哲学 |
| **容器无感知** | 他们**完全不读 cgroup**（没有 `cpu.max`/`memory.max` 配额视图），容器里看到的是宿主/命名空间视图。**如果 Linux 版可能跑在容器里，这一块得我们自己补** |
| **CPU 百分比口径** | 他们的进程 CPU% 是 `÷ 逻辑处理器数 × 100`：8 核机器上一个烧满单核的进程显示 **12.5%**。**我们得明确选一个口径并写进文档**（"总占用率"还是"单核 100%"），还要对照 Windows 版现在的口径，别两边不一致 |

### 11.6 他们"没做"的（也就意味着我们不必背的包袱）

Windows 专属变量整类移除；没有 lm-sensors / upower / acpi / df / free / top / ps 兜底；
CPU 温度只覆盖 3 个 hwmon 驱动名；磁盘"活动百分比"不含 await / aqu-sz；
没有网络丢包率与重传率；GPU 共享内存恒为 0；AMD/Intel GPU 没有核心/显存频率；
多电池时不采电压/循环/温度/化学体系；没有电池充电阈值与电源计划**写入**能力。

### 11.7 他们的验证边界（**我们写自己的验证文档时照这个格式**）

参考项目 `docs/linux-validation.md` 自己声明（2026-10-02）：

- 环境：**WSL2 Ubuntu 24.04 x86_64、.NET 8、普通用户、离线 Xvfb 会话**，列出 **339 项变量**；
- 「WSL2 的实时电池来自虚拟机设置，**不等于物理电池实测**」；
- 「**未笼统覆盖所有物理 AMD/Intel/NVIDIA 型号**」；
- 「**未使用用户真实 API Key 或余额**」；
- 「为元数据与解包运行验证，**未在 Fedora/RHEL 原生成安装**」；
- 「**没有验证 AppImage 的 FUSE 挂载模式**」；
- 英文结论原文：*"These are bounded tests on Ubuntu 24.04 under WSL2/Xvfb, **not certification for
  every distribution, compositor or physical GPU**."*

→ 这种"**我自己只测到了哪一步**"的坦白，正是第 8 节那个态度的最佳范例。Linux 版的验收文档
也要这样写边界：在哪个桌面、哪个发行版、哪种硬件上验的，其余一律写"没测"。

> ⚠️ 三处如实说明（含 2026-10-13 当天做的**复核**）：
> ① `VariableHub.cs`(91KB)、`VariableCatalog.cs`(96KB)、`AdvancedVariableProvider.cs`(78KB)
> **没拿到**（`web_fetch` 在 ~100KB 处截断、中转的 base64 还损坏了），所以"上层采样调度周期"
> 没有证据；
> ② **"字节数与 API 的 `size` 一致"不等于没损坏** —— 这是当天亲手验出来的：抄一份 394 字节的
> base64，中间走了一个字符，解出来是乱码，**而字节数照样是 394**（单字符替换不改变长度）。
> 于是改用 **git blob SHA-1** 复核（`sha1("blob <len>\0"+bytes)`）：第一批 12 个文件里
> **5 个没通过**（包括本表引用最多的 `LinuxVariableProvider.cs`，比官方少 2 字节）——
> 后来补齐了 4 个（`LinuxDesktop.cs`、`EndfieldChargePlus.csproj`、`LinuxSystemVariables.cs`、
> `linux-validation.md` 都换成了校验通过的副本），**只剩 `Customization\LinuxVariableProvider.cs`
> 一个没通过**（用户 2026-10-13 决定不再重抓）→ **第 11.2 节引用它的那几行行号按"未校验"对待**；
> 其余引用都落在已通过校验的文件上（`LinuxCommand.cs`、`LinuxDisks.cs`、`LinuxNetwork.cs`、
> `LinuxNvidia.cs`、`LinuxUiVariables.cs`）。
> ③ `docs/linux-validation.md` 现在是**校验通过的副本**（2711 B，SHA `23fbdc15…`），可以放心引用。
> 逐文件的校验状态见 `refs\zmd-charge-plus\README.md`。

---

## 12. 参考实现：跨平台工程与打包 ✅ 已完成（2026-10-13）

> **材料**：`refs\zmd-charge-plus\zmd-charge-plus-for-linux-跨平台与打包技术报告.md`（约 40KB），
> 以及 `refs\zmd-charge-plus\源码\` 下**按仓库原始路径归档、并通过 git blob SHA-1 校验**的源码。
> 校验方式：`sha1("blob <len>\0" + bytes)` 必须等于 GitHub API 给的 blob sha —— 这份材料 **15/15 通过**，
> 而且我**自己又独立重算了一遍**（没只信汇报）。所以下面引用的行号可信。

### 12.1 先纠正一个前提：不是"一套代码跨四平台"，是**四平台四仓库**

Windows = `zmd-charge-plus`、Linux = `...-for-linux`、macOS = `...-for-macos`、Android = `...-for-android`。
Linux 仓库本质上是 Windows 仓库的**移植分支**（`EndfieldChargePlus.csproj` 里仍是 `OutputType=WinExe`、
RID 里还留着 `win-x64;win-x86`、树里保留 4 个 `Interop/Windows*.cs`）。

**这正面印证了你 2026-10-13 那个决定**：一个 C# 老手做这件事，最后也是分仓维护，
而不是"一套代码硬扛四个平台"。我们走"Windows 冻结 + Linux 另立一份"是同一条路。

官方支持范围（`README.linux.md`）：glibc 2.35+ / OpenSSL 3 / **需要 X11，Wayland 走 XWayland**；
**不提供 ARM64、32 位、Alpine(musl) 包**（`scripts/package-linux.sh:7` 硬拒非 x86_64）。

### 12.2 Linux 的桌面行为，全靠 9 个 X11 调用

| 要做的事 | 它的做法 | 出处 |
|---|---|---|
| **点击穿透**（悬浮窗不吃鼠标、不挡操作） | X11 **SHAPE 扩展**：`XShapeCombineRectangles(kind=2)` 清空 `ShapeInput`（事件直接落到底层），再用**逐行圆角矩形**把"可见的那块胶囊"还原成可点区域 | `Interop/LinuxDesktop.cs:57-72`、`77-102` |
| **全局鼠标位置** | `XQueryPointer` | `Interop/LinuxDesktop.cs:39-55` |
| **剪贴板** | 预建 7 个 X11 atom（`CLIPBOARD`/`TARGETS`/`UTF8_STRING`…）—— 因为 Avalonia 11.2 假设 atom 已存在，全新 X server / 极简桌面上没有剪贴板管理器就会拿不到 | `Interop/LinuxDesktop.cs:12-30` |
| 定位 / 多显示器 | 平台无关抽象（0–8 贴工作区、9–17 贴整屏、margin 16、3×3 网格、Clamp） | `Views/HudPlacement.cs:6-20` |

两条对我们特别重要的结论：

1. 它只用 **`libX11.so.6` / `libXext.so.6`**（`Interop/LinuxDesktop.cs:113-123` 共 9 个 DllImport），
   而且**每个调用都 `catch DllNotFoundException / EntryPointNotFoundException` 静默降级**。
   → 这正是第 5 节"桌面兼容策略"要的写法：**能力探测 + 降级，不崩主流程**。
2. **"置顶 / 无边框 / 透明 / 拖动"在材料里找不到实现证据** —— 它们应该在未解码的
   `HudWindow.axaml(.cs)` 里；已校验的 `LinuxDesktop.cs` 全文**没有** `_NET_WM_STATE_ABOVE`、
   没有 XSendEvent、没有 wmctrl、没有 layer-shell 的痕迹。
   → 对我们反而是好消息：Electron 的 `alwaysOnTop` / `frame:false` / `transparent` 是框架自带能力，
   不用自己去写那套 X11。

### 12.3 托盘：连参考项目都没搞定

`Views/TrayMenuWindow.axaml.cs` 是自绘菜单，但它调的是 **`user32.dll` 的 `GetCursorPos`**（`:60-62`），
而且在 `:75` **没捕获异常** → 在 Linux 上会抛 `DllNotFoundException`。
**Linux 侧找不到托盘宿主实现**（应该在未解码的 `App.axaml.cs` 里）。
README 的说法：托盘需要桌面支持 StatusNotifier/AppIndicator，GNOME 没启用扩展就看不见，
兜底是"再启动一次唤回设置页"。

→ 与第 5 节第 3 条一致：**关键入口不能只放托盘**。

### 12.4 配置、数据、自启、密钥（都是实证做法，可直接抄）

| 主题 | 它的做法 | 出处 |
|---|---|---|
| **配置/数据目录** | `$XDG_DATA_HOME/EndfieldChargePlus`，回退 `~/.local/share/...`；Windows 用 `%LOCALAPPDATA%`。**故意不信任 `GetFolderPath`**（XDG 目录不存在时它可能返回空串），注释写明"首次启动绝不写在程序旁边" | `Interop/AppPaths.cs:9-16` |
| **开机自启（Linux）** | **XDG autostart 的 .desktop，不是 systemd**：`$XDG_CONFIG_HOME/autostart/<name>.desktop`，含 `X-GNOME-Autostart-enabled=true` | `Settings/StartupManager.cs:44-47`、`63-64` |
| 自启的三个好细节 | ① AppImage 场景优先用 **`$APPIMAGE` 原始路径**（挂载点是临时的）；② 先写 `.tmp` 再 `File.Move(overwrite)` **原子替换**；③ desktop-entry **两层转义**（`%`→`%%`）并清理改名前的旧条目 | `StartupManager.cs:55-57`、`65-66`、`69-76`、`51-53` |
| **API Key 怎么存** | **不是明文，也不是系统钥匙串**：`linux-aesgcm-v1:` + base64(nonce‖tag‖ct)，**AES-256-GCM**；主密钥 `<SettingsDirectory>/secrets/master.key`（32B 随机）；**强制权限校验**——目录 0700、文件创建 0600，读回来再比对一次 file mode，不符就抛异常。Windows 侧走 DPAPI。文档还如实声明"这不等于系统钥匙串" | `Customization/SecretStore.cs:16-23`、`26-27`、`70`、`75-79`、`87-89` |

→ **对我们的直接含义**：Linux 版的 `config.json` 里是**明文 API Key**（和 Windows 版一样）。
既然是独立一份，**这是顺手改掉的机会**：至少做到文件 0600 + 目录 0700；
条件允许就用 `secret-tool`（GNOME Keyring）存 Key。**这条要你点头才做，不擅自动。**

### 12.5 打包流水线（P2 可以直接照抄的部分）

`scripts/package-linux.sh`（116 行，SHA 已校验）**一次 publish 出四种包**：

```
dotnet publish -c Release -r linux-x64 --self-contained true -p:Version=... \
    -p:PublishSingleFile=false -p:PublishTrimmed=false        ← package-linux.sh:22-23
  └ 然后断言 libcoreclr.so 存在（:25）                          ← 少一个文件就拦下来
├── tar.gz       （tar --owner=0 --group=0）
├── .deb         （手写 control + dpkg-deb --root-owner-group --build；装到 /opt/…，
│                  /usr/bin 软链，applications / pixmaps / doc / copyright）
├── .rpm         （手写 spec + rpmbuild --define '_build_id_links none' --define '__os_install_post %{nil}'）
└── .AppImage    （手拼 AppDir + appimagetool 1.9.1「锁版本 + 硬编码 SHA-256 校验」:102-110
                  + 用 --appimage-extract 规避 FUSE :111）
收尾：SHA256SUMS
```

**校验脚本 `scripts/verify-linux-packages.sh`（33 行）的顺序值得整套照抄**：
`sha256sum -c` → 断言四类包各一个 → **四种格式全部解包** → 三处 `desktop-file-validate` →
每个可执行文件 `ldd libSkiaSharp.so | grep 'not found'`（**他们踩过原生库缺失的坑**）→
真启动 smoke → AppImage 用 `APPIMAGE_EXTRACT_AND_RUN=1` 再跑一遍。

**CI**（`.github/workflows/linux.yml`，44 行）：跑在 **ubuntu-22.04**（故意挑偏老的），
`permissions: contents: read`，装 xvfb / xdotool 和一批 X 库，
流程是 audit → package → verify → 上传 artifact，**不自动发 Release**。

**自建 APT 源**（`apt-repo/`，托管在 `apt.x-neko.com`）：`InRelease` / `Release.gpg` / keyring / `pool` / `Packages`，
配一键脚本 `apt-repo/install.sh` —— `curl -fsSL …/install.sh | sudo bash`，往 `sources.list.d` 写条目。

**体积实测**：v0.1.1 的 `.deb` = **34,366,734 B（32.8 MiB）**，`Installed-Size` 约 97MB
（这是 C# 自包含的代价；**Electron 大致同量级** —— 印证了第 3 节"~90–120MB"的估计）。
`Depends` 里有 `libc6(>=2.35) / libssl3 / libx11-6 / libxext6 / libicu70|72|74|76|78 / iputils-ping`，
其中 `libx11-6` + `libxext6` 正好对上那两个 DllImport。

### 12.6 他们在打包上踩过的坑（都有代码出处）

| 坑 | 说明 |
|---|---|
| **不能在 WSL / NTFS 上打包** | NTFS 会吃掉可执行位与软链 → 必须在 Linux 文件系统上打包（`package-linux.sh:14` 的注释） |
| **AppImage 的 FUSE** | 制作端用 `--appimage-extract`、测试端用 `APPIMAGE_EXTRACT_AND_RUN=1`，两头都要规避 |
| **原生依赖缺失** | 所以才要有 `ldd … grep 'not found'` 这道校验 |
| **打包要 root** | `dpkg-deb --root-owner-group`、rpmbuild 等 |
| **GUI 审计很慢** | 225 次 HUD 生命周期要 `timeout 600`，且脚本里 `unset WAYLAND_DISPLAY`（`scripts/audit-linux-variables.sh:10`）—— **等于承认测试必须走 X11/XWayland** |

### 12.7 照抄清单（8 条，都是我们能直接用的）

1. **分仓维护**（我们已定，见第 3 节）。
2. **平台差异收敛到一个 interop 层，原生调用一律"探测 + 静默降级"**，绝不让它崩主流程。
3. **self-contained 但不 PublishSingleFile、不裁剪** —— 少一个文件就断言失败，别让"单文件"引入玄学问题。
4. **系统包（deb/rpm）手写 control / spec**，不依赖花哨的打包器。
5. **打包之后四种格式全部解包自检** + `desktop-file-validate` + **原生库 ldd 检查** + 真启动 smoke + `SHA256SUMS`。
6. **第三方构建工具锁版本 + 硬编码哈希 + 规避 FUSE**（appimagetool 那套）。
7. **XDG 目录显式回退、不信任 `GetFolderPath`**；自启用 XDG autostart，写 `.tmp` 原子替换、两层转义、AppImage 用 `$APPIMAGE`。
8. **把"做不到的事"写进文档**（他们连"macOS 版尚未实机测试"都写在 README 里）。

### 12.8 没拿到证据的部分（如实）

**未解码**：`HudWindow.axaml.cs`(30KB) / `HudWindow.axaml`、`App.axaml.cs`、`Interop/WindowsTrayIcon.cs`、
`Settings/SettingsManager.cs`、`scripts/smoke-linux.sh`、`scripts/build-apt-repo.sh`、
`.github/workflows/build-apt-repo.yml`、`src/worker.js`、`wrangler.jsonc`、`docs/release-notes.md`、
`README*.md`、`Tests/*`。

→ 因此 **"置顶/无边框/透明/拖动"的实现、Linux 托盘宿主、APT 源的签名与部署方式、
`SettingsDirectory` 的精确定义**都没有证据；报告里一律写"没找到证据"，没有拿推测填补。
另外：本机没有 Linux 环境，**运行验证一次都没做**，全部是静态阅读。
