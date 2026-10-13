using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace TokenMonitorLauncher
{
    /// <summary>
    /// 高分屏：进程必须**自己声明 DPI 感知**，否则 Windows 会把整个窗口的位图拉伸到 125%，
    /// ClearType 的彩边被拉成糊边（"字发虚"），而且按 96 DPI 摆出来的框装不下被放大的字
    /// （"字被切掉半行"）。两个症状其实是同一件事。
    /// 静态构造在 Main 之前跑一次，保证任何窗口（包括启动期的错误弹窗）都已经是感知的。
    /// </summary>
    internal static class Dpi
    {
        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")]
        private static extern IntPtr GetDC(IntPtr hWnd);
        [DllImport("user32.dll")]
        private static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
        [DllImport("gdi32.dll")]
        private static extern int GetDeviceCaps(IntPtr hdc, int index);

        private const int LOGPIXELSX = 88;

        /// <summary>用户当前的缩放系数（96 DPI = 1.0，125% = 1.25）。手工缩放布局时乘它。</summary>
        public static readonly float Factor;
        /// <summary>声明感知后实测到的屏幕 DPI（96 / 120 / 144 …）。</summary>
        public static readonly int RawDpi;

        static Dpi()
        {
            try { SetProcessDPIAware(); } catch { }
            float f = 0f;
            // ⚠️ 必须用 GetDeviceCaps(GetDC(NULL), LOGPIXELSX)：声明感知后它给的是**真实**屏幕 DPI（120）。
            // 别用 Graphics.FromHwnd(IntPtr.Zero).DpiX —— 实测在这里照样返回 96，
            // 会把 Factor 算成 1（于是整套布局不缩放、字又被真 DPI 放大 → 还是被切）。
            try
            {
                IntPtr dc = GetDC(IntPtr.Zero);
                if (dc != IntPtr.Zero)
                {
                    int dpi = GetDeviceCaps(dc, LOGPIXELSX);
                    ReleaseDC(IntPtr.Zero, dc);
                    if (dpi > 0 && dpi <= 384) { f = dpi / 96f; RawDpi = dpi; }
                }
            }
            catch { }
            if (f <= 0f) f = 1f;
            Factor = f;
        }

        /// <summary>把一个"96 DPI 设计值"换算成当前 DPI 下的像素值。</summary>
        public static int S(int px) { return (int)Math.Round(px * Factor); }
    }

    internal static class Program
    {
        /// <summary>当前进程是否已经是管理员权限。</summary>
        private static bool IsElevated()
        {
            try
            {
                using (System.Security.Principal.WindowsIdentity id =
                       System.Security.Principal.WindowsIdentity.GetCurrent())
                {
                    return new System.Security.Principal.WindowsPrincipal(id)
                        .IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
                }
            }
            catch { return false; }
        }

        [STAThread]
        private static void Main(string[] args)
        {
            // 第一步：保证 config.json 存在（没有就从干净模板复制一份）
            Core.EnsureConfig();

            string arg = (args.Length > 0 ? args[0] : "").ToLowerInvariant();

            // 这里故意**不**申请管理员权限：
            // 要求提权会让 Windows SmartScreen 弹"已保护你的电脑 / 无法识别的应用"，
            // 而 token-monitor 并不需要管理员权限（DSH、代理、悬浮窗都是普通用户级别）。

            if (arg == "--open-dsh" || arg == "--start-monitor" || arg == "--check" ||
                arg == "--dry-run" || arg == "--start-dsh" || arg == "--dsh-url" ||
                arg == "--restart-dsh" || arg == "--auto" || arg == "--restart-widget")
            {
                Environment.ExitCode = Cli.Run(arg);
                return;
            }
            // 直接打开"设置 · API Key"窗口（不跑启动动作），方便只改 Key
            if (arg == "--settings")
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                LauncherForm.SuppressAutoRun = true;
                LauncherForm.OpenSettingsOnStart = true;
                Application.Run(new LauncherForm());
                return;
            }
            // 直接打开设置窗并切到"性能监控"那一页
            if (arg == "--settings-monitor")
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                LauncherForm.SuppressAutoRun = true;
                LauncherForm.OpenSettingsOnStart = true;
                LauncherForm.OpenMonitorTabOnStart = true;
                Application.Run(new LauncherForm());
                return;
            }
            // 直接打开设置窗并切到"余额提醒"那一页
            if (arg == "--settings-warn")
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                LauncherForm.SuppressAutoRun = true;
                LauncherForm.OpenSettingsOnStart = true;
                LauncherForm.OpenWarnTabOnStart = true;
                Application.Run(new LauncherForm());
                return;
            }
            // 命令行写入 API Key（代理在跑就顺手重启，让新 Key 立刻生效）
            if (arg == "--set-api-key")
            {
                string newKey = args.Length > 1 ? args[1] : "";
                if (!Core.SaveApiKey(newKey))
                {
                    Console.Error.WriteLine("写入 config.json 失败（检查目录权限）");
                    Environment.ExitCode = 1;
                    return;
                }
                Core.SaveBoolSetting("apiKeySetupDone", true);
                Console.WriteLine("已写入 config.json 的 apiKey：" + Core.MaskKey(newKey));
                if (Core.ProxyAlive()) Console.WriteLine(Core.RestartProxy(null));
                else Console.WriteLine("代理没在运行，下次启动时生效");
                Environment.ExitCode = 0;
                return;
            }
            // 命令行设置"余额提醒"（走的是设置窗「保存」用的同一个函数）：
            //   --set-balance-warn on 20   开，低于 20 元就变红
            //   --set-balance-warn off     关（金额保留，下次开不用重填）
            // 为什么要留这个口子：和 --set-api-key 一个道理——config.json 里有 ¥ 和中文路径，
            // 手改容易把编码写坏（见维护手册 9.3 第 6 条），让程序自己写最稳。
            if (arg == "--set-balance-warn")
            {
                string mode = args.Length > 1 ? args[1].Trim().ToLowerInvariant() : "";
                if (mode != "on" && mode != "off" && mode != "true" && mode != "false"
                    && mode != "1" && mode != "0" && mode != "开" && mode != "关")
                {
                    Console.Error.WriteLine("用法： token-monitor.exe --set-balance-warn on [金额]  /  --set-balance-warn off");
                    Environment.ExitCode = 2;
                    return;
                }
                bool on = (mode == "on" || mode == "true" || mode == "1" || mode == "开");
                double val = Core.BalanceWarnThreshold();
                if (args.Length > 2)
                {
                    double parsed;
                    if (!double.TryParse(args[2].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out parsed) || parsed < 0)
                    {
                        Console.Error.WriteLine("金额请填一个大于等于 0 的数字，例如 20 或 12.5");
                        Environment.ExitCode = 1;
                        return;
                    }
                    val = parsed;
                }
                if (on && val <= 0)
                {
                    Console.Error.WriteLine("开着提醒就得给个大于 0 的金额，例如： --set-balance-warn on 20");
                    Environment.ExitCode = 1;
                    return;
                }
                if (!Core.SaveBalanceWarnSettings(on, val))
                {
                    Console.Error.WriteLine("写入 config.json 失败（检查目录权限）");
                    Environment.ExitCode = 1;
                    return;
                }
                Console.WriteLine("已写入 config.json：余额提醒 " + (on ? "开" : "关")
                    + "，设定值 " + val.ToString("0.##", CultureInfo.InvariantCulture) + " 元");
                Console.WriteLine(Core.RestartWidget(null));
                Environment.ExitCode = 0;
                return;
            }
            // 离屏渲染设置窗（无头环境下验证外观用，不写入任何东西）
            // --render-settings [输出.png] [页]   页 = key / monitor / warn（默认 key）
            if (arg == "--render-settings")
            {
                try
                {
                    string outPath = args.Length > 1 ? args[1] : "settings-preview.png";
                    string page = args.Length > 2 ? args[2].ToLowerInvariant() : "key";
                    // 渲染用的示例值直接从配置里读：**任何真实 Key 都不许写进源码**
                    // （曾经图省事写死过一次，结果连编译出来的 exe 里都带着它——打包校验抓出来的）
                    // 余额提醒那两个是"演示值"（开 + 20 元），和性能监控那页一样：出图要能看出这个页面长什么样。
                    using (SettingsForm f = new SettingsForm(Core.CurrentApiKey(), false,
                        Core.MonitorItems().Length > 0 ? Core.MonitorItems() : "cpu,memory,battery",
                        true, page, true, 20))
                    {
                        f.StartPosition = FormStartPosition.Manual;
                        f.Location = new Point(-3200, -3200);
                        f.Show();
                        for (int i = 0; i < 8; i++) { Application.DoEvents(); System.Threading.Thread.Sleep(60); }
                        // ⚠️ 这条路径和 --render 必须一样：`DrawToBitmap` 会把**整个窗口**（含标题栏）画进
                        // 我们给的位图，只按客户区大小给位图的话，内容会比客户区高一截、底部被切
                        // （2026-10-09 踩到：设置窗预览图里「保存 / 取消」只露出上半截）。
                        // 所以先按"客户区 + 标题栏高度"画，再把上面那一条裁掉。
                        int off = f.RectangleToScreen(f.ClientRectangle).Top - f.Bounds.Top;
                        if (off < 0) off = 0;
                        using (Bitmap bmp = new Bitmap(f.ClientSize.Width, f.ClientSize.Height))
                        {
                            if (off > 0)
                            {
                                using (Bitmap full = new Bitmap(bmp.Width, bmp.Height + off))
                                {
                                    f.DrawToBitmap(full, new Rectangle(0, 0, full.Width, full.Height));
                                    using (Bitmap crop = full.Clone(new Rectangle(0, off, bmp.Width, bmp.Height), full.PixelFormat))
                                    {
                                        crop.Save(outPath, System.Drawing.Imaging.ImageFormat.Png);
                                    }
                                }
                            }
                            else
                            {
                                f.DrawToBitmap(bmp, new Rectangle(0, 0, bmp.Width, bmp.Height));
                                bmp.Save(outPath, System.Drawing.Imaging.ImageFormat.Png);
                            }
                        }
                        // 控件树落到同名 .tree.txt（UTF-8）：控制台是 GBK，中文会乱码，
                        // 预览图里"某个按钮看不见"这类问题就看这个文件。
                        File.WriteAllText(outPath + ".tree.txt", f.DumpTree(), new UTF8Encoding(true));
                        f.Close();
                    }
                    Console.WriteLine("已渲染设置窗: " + Path.GetFullPath(outPath));
                    Environment.ExitCode = 0;                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine("渲染失败：" + ex);
                    Environment.ExitCode = 1;
                }
                return;
            }
            // --dump-settings-layout：在"和真跑一模一样的进程环境"里（EnableVisualStyles +
            // SetCompatibleTextRenderingDefault）把设置窗建一遍，把 Show 前后的 ClientSize /
            // AutoScale 参数 / 每个控件的矩形写进 settings-layout.txt。
            // 为什么需要它：--render-settings 走的是另一条路（没有 EnableVisualStyles），
            // 排版可能和真窗口不一样 —— 2026-10-08 深夜"保存按钮不见了"就是这么被预览图骗过去的。
            if (arg == "--dump-settings-layout")
            {
                try
                {
                    Application.EnableVisualStyles();
                    Application.SetCompatibleTextRenderingDefault(false);
                    StringBuilder sb = new StringBuilder();
                    using (SettingsForm f = new SettingsForm(Core.CurrentApiKey(), false,
                        Core.MonitorItems().Length > 0 ? Core.MonitorItems() : "cpu,battery", true, "key", true, 20))
                    {
                        sb.AppendLine("AutoScaleMode=" + f.AutoScaleMode
                            + "  AutoScaleDimensions=" + f.AutoScaleDimensions
                            + "  CurrentAutoScaleDimensions=" + f.CurrentAutoScaleDimensions
                            + "  ClientSize=" + f.ClientSize);
                        sb.AppendLine("—— Show 之前 ——");
                        sb.AppendLine(f.DumpTree());
                        f.StartPosition = FormStartPosition.Manual;
                        f.Location = new Point(-3200, -3200);
                        f.Show();
                        for (int i = 0; i < 8; i++) { Application.DoEvents(); System.Threading.Thread.Sleep(60); }
                        sb.AppendLine("—— Show 之后 ——  ClientSize=" + f.ClientSize
                            + "  AutoScaleDimensions=" + f.AutoScaleDimensions
                            + "  CurrentAutoScaleDimensions=" + f.CurrentAutoScaleDimensions);
                        sb.AppendLine(f.DumpTree());
                        f.Close();
                    }
                    File.WriteAllText(Path.Combine(Core.AppDir, "settings-layout.txt"), sb.ToString(), new UTF8Encoding(true));
                    Console.WriteLine("已写出 settings-layout.txt");
                    Environment.ExitCode = 0;
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine("dump 失败：" + ex);
                    Environment.ExitCode = 1;
                }
                return;
            }
            // --dump-dpi：打印本进程的 DPI 感知状态与缩放系数（诊断"字发虚 / 被切"的第一步）。
            // 没有它就只能靠 1920x1080 与 1536x864 两个数字猜，很容易猜错方向。
            if (arg == "--dump-dpi")
            {
                float f = Dpi.Factor;
                Console.WriteLine("Dpi.Factor   = " + f.ToString("0.###"));
                Console.WriteLine("实测屏幕 DPI = " + Dpi.RawDpi + "（" + (f * 100f).ToString("0") + "% 缩放）");
                Console.WriteLine("设置窗 660x470 → " + Dpi.S(660) + "x" + Dpi.S(470) + " 像素");
                Console.WriteLine("启动器 410x190 → " + Dpi.S(410) + "x" + Dpi.S(190) + " 像素");
                try
                {
                    using (Graphics g = Graphics.FromHwnd(IntPtr.Zero))
                    {
                        Console.WriteLine("Graphics.DpiX = " + g.DpiX);
                        using (Font f9 = new Font("Microsoft YaHei UI", 9F))
                        using (Font f10 = new Font("Microsoft YaHei UI", 10F))
                        {
                            Console.WriteLine("9pt 行高 = " + f9.GetHeight(g).ToString("0.0")
                                + "   10pt 行高 = " + f10.GetHeight(g).ToString("0.0"));
                        }
                    }
                }
                catch (Exception ex) { Console.WriteLine("量字体失败：" + ex.Message); }
                Environment.ExitCode = 0;
                return;
            }
            // --dump-launcher-layout：启动器主窗的几何（不截图、不启动任何东西），
            // 和 --dump-settings-layout 一个用途：看真实进程环境下的坐标和 AutoScale 参数。
            if (arg == "--dump-launcher-layout")
            {
                try
                {
                    Application.EnableVisualStyles();
                    Application.SetCompatibleTextRenderingDefault(false);
                    LauncherForm.SuppressAutoRun = true;
                    using (LauncherForm f = new LauncherForm())
                    {
                        f.StartPosition = FormStartPosition.Manual;
                        f.Location = new Point(-3200, -3200);
                        f.Show();
                        for (int i = 0; i < 8; i++) { Application.DoEvents(); System.Threading.Thread.Sleep(60); }
                        StringBuilder sb = new StringBuilder();
                        sb.AppendLine("Dpi.Factor=" + Dpi.Factor.ToString("0.###"));
                        sb.AppendLine("几何: " + LauncherForm.LayoutInfo
                            + " | AutoScaleMode=" + f.AutoScaleMode
                            + " AutoScaleDimensions=" + f.AutoScaleDimensions
                            + " Current=" + f.CurrentAutoScaleDimensions
                            + " ClientSize=" + f.ClientSize);
                        sb.AppendLine("控件: " + f.DumpBounds());
                        File.WriteAllText(Path.Combine(Core.AppDir, "launcher-layout.txt"), sb.ToString(), new UTF8Encoding(true));
                        Console.WriteLine(sb.ToString());
                        Console.WriteLine("已写出 launcher-layout.txt");
                        f.Close();
                    }
                    Environment.ExitCode = 0;
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine("dump 失败：" + ex);
                    Environment.ExitCode = 1;
                }
                return;
            }
            if (arg == "--render")
            {
                LauncherForm.SuppressAutoRun = true;   // 预览模式不执行启动动作
                // 第二个参数可以塞一句结果文字，用来检查底部结果区在长消息下的高度（会不会被切）
                if (args.Length > 2) LauncherForm.PreviewMessage = args[2];
                // 离屏渲染界面成图片（无头环境下验证外观用）
                try
                {
                    string outPath = args.Length > 1 ? args[1] : "launcher-preview.png";
                    using (LauncherForm f = new LauncherForm())
                    {
                        // 移到屏幕外显示一次，子控件才会布局并绘制
                        f.StartPosition = FormStartPosition.Manual;
                        f.Location = new Point(-3200, -3200);
                        f.Show();
                        for (int i = 0; i < 8; i++) { Application.DoEvents(); System.Threading.Thread.Sleep(60); }
                        Console.WriteLine("几何: " + LauncherForm.LayoutInfo
                            + " | AutoScaleMode=" + f.AutoScaleMode
                            + " AutoScaleDimensions=" + f.AutoScaleDimensions
                            + " Current=" + f.CurrentAutoScaleDimensions
                            + " ClientSize=" + f.ClientSize);
                        Console.WriteLine("控件: " + f.DumpBounds());
                        // DrawToBitmap 在这台机器（125% 缩放 + 进程不感知 DPI）上会把**整个窗口**画进
                        // 客户区大小的位图里：内容比实际下移一个标题栏高度、底部被切掉，看着像文字被裁。
                        // 所以先按"客户区 + 标题栏高度"画，再把上面那一条裁掉，预览图才和真实窗口一致。
                        int off = f.RectangleToScreen(f.ClientRectangle).Top - f.Bounds.Top;
                        if (off < 0) off = 0;
                        using (Bitmap bmp = new Bitmap(f.ClientSize.Width, f.ClientSize.Height))
                        {
                            if (off > 0)
                            {
                                using (Bitmap full = new Bitmap(bmp.Width, bmp.Height + off))
                                {
                                    f.DrawToBitmap(full, new Rectangle(0, 0, full.Width, full.Height));
                                    using (Bitmap crop = full.Clone(new Rectangle(0, off, bmp.Width, bmp.Height), full.PixelFormat))
                                    {
                                        crop.Save(outPath, System.Drawing.Imaging.ImageFormat.Png);
                                    }
                                }
                            }
                            else
                            {
                                f.DrawToBitmap(bmp, new Rectangle(0, 0, bmp.Width, bmp.Height));
                                bmp.Save(outPath, System.Drawing.Imaging.ImageFormat.Png);
                            }
                        }
                        f.Close();
                    }
                    Console.WriteLine("已渲染界面: " + Path.GetFullPath(outPath));
                    Environment.ExitCode = 0;
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine("渲染失败：" + ex);
                    Environment.ExitCode = 1;
                }
                return;
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new LauncherForm());
        }
    }

    /// <summary>安装目录定位 + 配置读取 + 两个动作。命令行与界面按钮共用同一套实现。</summary>
    internal static class Core
    {
        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        private static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
            uint fuFlags, uint uTimeout, out IntPtr lpdwResult);

        public static string AppDir
        {
            get { return AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\'); }
        }

        public static string FindFile(string name)
        {
            string[] candidates = new string[]
            {
                Path.Combine(AppDir, name),
                Path.Combine(Path.Combine(AppDir, "token-monitor"), name),
                Path.Combine(Directory.GetParent(AppDir) == null ? AppDir : Directory.GetParent(AppDir).FullName, name)
            };
            foreach (string c in candidates) { if (File.Exists(c)) return c; }
            return null;
        }

        public static string DshWebUrl()
        {
            string config = FindFile("config.json");
            if (config != null)
            {
                try
                {
                    string text = File.ReadAllText(config, Encoding.UTF8);
                    Match m = Regex.Match(text, "\"dshWebUrl\"\\s*:\\s*\"([^\"]+)\"");
                    if (m.Success && m.Groups[1].Value.Trim().Length > 0) return m.Groups[1].Value.Trim();
                }
                catch { }
            }
            return "http://127.0.0.1:3080";
        }

        /// <summary>
        /// 启动 DSH 时命令行窗口的工作目录（决定 DSH 把会话归到哪个工作区）。
        /// config.json 里的 dshWorkDir 优先；没配就用用户主目录（= 手动开 cmd 时的默认位置）。
        /// </summary>
        public static string DshWorkDir()
        {
            string config = FindFile("config.json");
            if (config != null)
            {
                try
                {
                    string text = File.ReadAllText(config, Encoding.UTF8);
                    Match m = Regex.Match(text, "\"dshWorkDir\"\\s*:\\s*\"([^\"]*)\"");
                    if (m.Success && m.Groups[1].Value.Trim().Length > 0)
                    {
                        string dir = m.Groups[1].Value.Trim().Replace("\\\\", "\\");
                        if (Directory.Exists(dir)) return dir;
                    }
                }
                catch { }
            }
            return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);   // C:\Users\<用户名>
        }

        /// <summary>找 npm 全局安装的 dsh 命令。</summary>
        public static string FindDsh()
        {
            string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            string[] candidates = new string[]
            {
                Path.Combine(appData, "npm", "dsh.cmd"),
                Path.Combine(appData, "npm", "dsh")
            };
            foreach (string c in candidates) { if (File.Exists(c)) return c; }
            return null;
        }

        /// <summary>
        /// 直接找 DSH 的入口 js（用 node 跑：node ...\dsh\lib\bin.js web）。
        /// 这样启动 DSH 时完全不碰 .cmd / .bat —— 那些文件在这台机器上会弹
        /// "打开文件 - 安全警告（无法验证发布者）"。
        /// </summary>
        public static string FindDshBin()
        {
            string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            string p = Path.Combine(appData, "npm", "node_modules", "@deepseek-ai", "dsh", "lib", "bin.js");
            return File.Exists(p) ? p : null;
        }

        /// <summary>
        /// 这台机器上有没有可用的 DSH。没有就把 DSH 相关界面和动作全部收起来
        /// （这个应用是要发给别人的，别人不一定用 DSH，只想要"统计代理 + 悬浮窗"）。
        /// 设环境变量 TOKEN_MONITOR_SKIP_DSH=1 可以强制当成"没有"：本人装了 DSH 但不想让启动器碰它，
        /// 或者只是想看一眼没有 DSH 时的界面长什么样。
        /// </summary>
        public static bool DshAvailable()
        {
            string skip = Environment.GetEnvironmentVariable("TOKEN_MONITOR_SKIP_DSH");
            if (!string.IsNullOrEmpty(skip) && skip != "0") return false;
            return FindDshBin() != null || FindDsh() != null;
        }

        /// <summary>
        /// 确保 config.json 存在：没有就复制一份 config.template.json。
        /// 模板是"干净"的——不含任何人的 API Key、不含某台机器的路径——所以第一次运行这个应用的人
        /// 拿到的就是一份安全的默认配置（随后启动器会弹出"填写 API Key"）。
        /// 模板也不在时，写一份最小配置；proxy.js 启动时会按内置默认把缺的项补齐。
        /// **必须在任何读配置的动作之前调用**（Main 里第一件事就是这个）。
        /// </summary>
        public static void EnsureConfig()
        {
            try
            {
                string target = Path.Combine(AppDir, "config.json");
                if (File.Exists(target)) return;
                string template = FindFile("config.template.json");
                if (template != null)
                {
                    File.Copy(template, target, false);   // 字节复制，不经过任何解码（免得写坏中文）
                    return;
                }
                string minimal =
                    "{\r\n" +
                    "  \"port\": 8788,\r\n" +
                    "  \"host\": \"127.0.0.1\",\r\n" +
                    "  \"upstream\": \"https://api.deepseek.com\",\r\n" +
                    "  \"apiKey\": \"\",\r\n" +
                    "  \"dshWorkDir\": \"\",\r\n" +
                    "  \"openDshWebOnStart\": false\r\n" +
                    "}\r\n";
                File.WriteAllText(target, minimal, new UTF8Encoding(false));
            }
            catch { }
        }

        public static bool WaitForPort(string host, int port, int timeoutMs)
        {
            Stopwatch sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < timeoutMs)
            {
                if (PortOpen(host, port)) return true;
                System.Threading.Thread.Sleep(400);
            }
            return false;
        }

        /// <summary>启动 dsh web（DSH 网页服务本身）。会开一个控制台窗口，服务就活在那里。</summary>
        public static string StartDshWeb()
        {
            string dsh = FindDsh();
            if (dsh == null) return "找不到 dsh 命令，请先安装 DeepSeek Harness";
            ProcessStartInfo psi = new ProcessStartInfo(dsh, "web");
            psi.UseShellExecute = true;              // 开控制台窗口，服务日志留在那里
            psi.WorkingDirectory = DshWorkDir();
            try { Process.Start(psi); }
            catch (Exception ex) { return "启动 dsh web 失败：" + ex.Message; }
            if (WaitForPort("127.0.0.1", 3080, 30000))
                return "已启动 dsh web（它会自己打开带令牌的页面）；若没弹出，可再点一次本按钮";
            return "已启动 dsh web，但 30 秒内 3080 还没就绪，请看新开的那个控制台窗口";
        }

        // ---- 启动器自己带起来的 DSH 会话（记录带令牌的链接，不依赖浏览器 Cookie）----

        public static string SessionFile { get { return Path.Combine(AppDir, "data", "dsh-web.json"); } }
        public static string DshLogFile { get { return Path.Combine(AppDir, "data", "dsh-web.log"); } }

        /// <summary>请求一个 URL，返回 HTTP 状态码（不跟随重定向）。用来验证令牌链接是否有效。</summary>
        public static int ProbeUrl(string url)
        {
            try
            {
                System.Net.HttpWebRequest req = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(url);
                req.AllowAutoRedirect = false;
                req.Timeout = 5000;
                using (System.Net.HttpWebResponse resp = (System.Net.HttpWebResponse)req.GetResponse())
                {
                    return (int)resp.StatusCode;
                }
            }
            catch (System.Net.WebException ex)
            {
                if (ex.Response != null) { try { return (int)((System.Net.HttpWebResponse)ex.Response).StatusCode; } catch { } }
                return 0;
            }
            catch { return 0; }
        }

        public static string ReadSessionUrl()
        {
            try
            {
                if (!File.Exists(SessionFile)) return null;
                string text = File.ReadAllText(SessionFile, Encoding.UTF8);
                Match m = Regex.Match(text, "\"url\"\\s*:\\s*\"([^\"]+)\"");
                return m.Success ? m.Groups[1].Value.Replace("\\/", "/") : null;
            }
            catch { return null; }
        }

        private static void SaveSession(string url)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(SessionFile));
                string json = "{\"url\":\"" + url.Replace("\\", "\\\\") + "\",\"savedAt\":" +
                    DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + "}";
                File.WriteAllText(SessionFile, json, new UTF8Encoding(false));
            }
            catch { }
        }

        /// <summary>
        /// 能不能写 ~/.dsh —— 用来判断本程序是不是跑在受限环境（沙箱）里。
        /// 受限环境里写工作区外的文件会被拒，DSH 启动时就会报 EPERM；这种情况启动器无能为力，
        /// 只能提示用户换一个干净的位置启动（桌面快捷方式 / 开始菜单 / 正常的资源管理器窗口）。
        /// </summary>
        public static bool HasDshWriteAccess()
        {
            try
            {
                string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".dsh");
                if (!Directory.Exists(dir)) return true;      // 还没建过，交给 DSH 自己建
                string probe = Path.Combine(dir, ".token-monitor-write-probe");
                File.WriteAllText(probe, "probe");
                File.Delete(probe);
                return true;
            }
            catch { return false; }
        }

        /// <summary>
        /// DSH 的配置文件是否被占用（占用 = 已经有一份 DSH 在跑或在启动中）。
        /// 用来避免"端口还没起来就又去起一份"，两份抢同一个配置文件就会报 EPERM。
        /// </summary>
        public static bool DshProfileLocked()
        {
            try
            {
                string p = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                                        ".dsh", "profiles", "web", "cordis.yml");
                if (!File.Exists(p)) return false;
                using (FileStream fs = new FileStream(p, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
                {
                    return false;   // 能独占打开 = 没被占用
                }
            }
            catch (IOException) { return true; }    // 共享冲突 = 有进程占着
            catch { return false; }                 // 其他问题不作为"在运行"的证据
        }

        /// <summary>
        /// 已经有一份 DSH 在跑（或在启动中）时：不重复启动，只等它就绪并把页面打开。
        /// </summary>
        private static string WaitForOtherDsh(Action<string> progress, string lead)
        {
            if (progress != null) progress(lead + "，正在等它就绪…");
            if (WaitForPort("127.0.0.1", 3080, 40000))
            {
                string url = ReadSessionUrl();
                if (url != null && ProbeUrl(url) == 200)
                {
                    try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
                    catch { }
                    return lead + "；已用令牌链接把页面打开";
                }
                return lead + "；页面会由 DSH 自己打开（若没弹出，看下浏览器标签）";
            }
            return lead + "，但 40 秒内 3080 还没就绪；请看 data\\dsh-web.log";
        }

        /// <summary>
        /// 自己启动 dsh web。
        /// 注意：dsh 的输出重定向到文件时是块缓冲的，那条带 token 的链接可能很久不落盘，
        /// 所以这里以"端口就绪"为准，链接只是顺手捞一下（dsh 自己也会打开带令牌的页面）。
        /// progress 回调用来把"已等待 N 秒"写到界面上（本方法跑在后台线程）。
        /// </summary>
        public static string StartDshCaptured(Action<string> progress)
        {
            // 受限环境（沙箱）里写不了 ~/.dsh，启动 DSH 只会得到 EPERM：
            // 这种情况直接说清楚，不去启动，也不让用户看一串看不懂的报错。
            if (!HasDshWriteAccess())
                return "本程序运行在受限环境里（写不了 ~/.dsh），没法启动 DSH；请从桌面快捷方式或开始菜单重新打开本程序";

            // 已经有一份在跑（端口在听，或配置文件被占着）→ 别再起第二份
            if (PortOpen("127.0.0.1", 3080) || DshProfileLocked())
                return WaitForOtherDsh(progress, "DSH 已经在运行");

            // 启动锁（针对"启动 DSH"这个动作本身，任何入口都串行化）：
            // 自动执行、按钮、命令行同时触发时，只有一个真正去启动，避免两份 DSH 抢同一个配置文件。
            bool ownedStart = true;
            System.Threading.Mutex startGate = null;
            try
            {
                startGate = new System.Threading.Mutex(false, "token-monitor-start-dsh");
                try { ownedStart = startGate.WaitOne(0); }
                catch (System.Threading.AbandonedMutexException) { ownedStart = true; }
            }
            catch { ownedStart = true; }

            try
            {
                if (!ownedStart)
                {
                    if (progress != null) progress("另一个启动器正在启动 DSH，等它就绪…");
                    if (WaitForPort("127.0.0.1", 3080, 45000))
                        return "另一个启动器已经启动了 DSH；页面会由它打开";
                    return "另一个启动器正在启动 DSH，本次不重复启动";
                }
                return StartDshLocked(progress);
            }
            finally
            {
                try { if (startGate != null) startGate.ReleaseMutex(); } catch { }
                try { if (startGate != null) startGate.Close(); } catch { }
            }
        }

        private static string StartDshLocked(Action<string> progress)
        {
            // 拿到锁后再确认一次（这期间别人可能已经启动了）
            if (PortOpen("127.0.0.1", 3080) || DshProfileLocked())
                return WaitForOtherDsh(progress, "DSH 已经在运行");

            // DSH 启动要十几秒：这期间端口还没监听、配置文件也不一定锁上。
            // 先静观几秒，避开"别人正在启动的那一份"，否则两份会抢同一个配置文件（表现为 EPERM）。
            if (progress != null) progress("正在确认 DSH 是否已在启动…");
            for (int i = 0; i < 8; i++)
            {
                System.Threading.Thread.Sleep(1000);
                if (PortOpen("127.0.0.1", 3080) || DshProfileLocked())
                    return WaitForOtherDsh(progress, "检测到 DSH 正在启动（没有重复启动）");
            }

            // 按手动那套来：打开一个命令行窗口，在里面运行 DSH。
            // 优先用 node 直接跑入口 js（完全不碰 .cmd / .bat —— 那些文件在这台机器上会弹
            // "打开文件 - 安全警告 / 无法验证发布者"）；找不到 js 才退回 dsh.cmd。
            string bin = FindDshBin();
            string commandLine;
            if (bin != null)
            {
                if (progress != null) progress("正在打开命令行窗口启动 DSH…");
                commandLine = "/k node \"" + bin + "\" web";
            }
            else
            {
                string dsh = FindDsh();
                if (dsh == null) return "找不到 DSH，请先安装 DeepSeek Harness";
                if (progress != null) progress("正在打开命令行窗口启动 DSH…");
                commandLine = "/k \"\"" + dsh + "\" web\"";
            }
            ProcessStartInfo psi = new ProcessStartInfo("cmd.exe", commandLine);
            psi.UseShellExecute = true;                      // 开一个真正的新控制台窗口
            psi.WorkingDirectory = DshWorkDir();             // C:\Users\<用户名>
            try { Process.Start(psi); }
            catch (Exception ex) { return "打开命令行窗口失败：" + ex.Message; }

            Stopwatch sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < 60000)
            {
                System.Threading.Thread.Sleep(700);
                if (progress != null) progress("正在等 DSH 就绪…已等待 " + (sw.ElapsedMilliseconds / 1000) + " 秒");
                // 端口一起来就算成功（dsh 自己会打开带令牌的页面）
                if (PortOpen("127.0.0.1", 3080))
                {
                    string captured = TryReadTokenUrl();
                    if (captured != null)
                    {
                        SaveSession(captured);
                        try { Process.Start(new ProcessStartInfo(captured) { UseShellExecute = true }); }
                        catch { }
                        return "DSH 已启动（命令行窗口里），并用令牌链接打开页面";
                    }
                    return "DSH 已启动（命令行窗口里），它自己会打开页面；若没弹出，看那个窗口打印的链接";
                }
            }
            return "等了 60 秒 3080 还没就绪；请看刚打开的那个命令行窗口里的提示";
        }

        private static string TryReadLog()
        {
            try { return File.Exists(DshLogFile) ? File.ReadAllText(DshLogFile, Encoding.UTF8) : null; }
            catch { return null; }
        }

        private static string TryReadTokenUrl()
        {
            string text = TryReadLog();
            if (text == null) return null;
            Match m = Regex.Match(text, "https?://[^\\s\"'<>]*token=[^\\s\"'<>]+");
            return m.Success ? m.Value : null;
        }

        public static string StartDshCaptured()
        {
            return StartDshCaptured(null);
        }

        public static bool IsListening(string url, out string host, out int port)
        {
            host = "127.0.0.1";
            port = 80;
            try
            {
                Uri u = new Uri(url);
                host = u.Host;
                port = u.Port;
            }
            catch { return false; }
            return PortOpen(host, port);
        }

        public static bool PortOpen(string host, int port)
        {
            try
            {
                using (TcpClient c = new TcpClient())
                {
                    IAsyncResult ar = c.BeginConnect(host, port, null, null);
                    bool ok = ar.AsyncWaitHandle.WaitOne(700);
                    bool connected = ok && c.Connected;
                    if (connected) c.EndConnect(ar);
                    return connected;
                }
            }
            catch { return false; }
        }

        public static int FileCount(string dir, string filter)
        {
            try { return Directory.Exists(dir) ? Directory.GetFiles(dir, filter).Length : 0; }
            catch { return 0; }
        }

        /// <summary>结束占用某个端口的进程（用来重启自己管不着的那份 DSH）。</summary>
        public static bool KillPortOwner(int port)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo("netstat.exe", "-ano");
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                using (Process p = Process.Start(psi))
                {
                    string output = p.StandardOutput.ReadToEnd();
                    p.WaitForExit(5000);
                    foreach (string line in output.Split('\n'))
                    {
                        if (line.IndexOf("LISTENING", StringComparison.OrdinalIgnoreCase) < 0) continue;
                        if (line.IndexOf(":" + port, StringComparison.Ordinal) < 0) continue;
                        Match m = Regex.Match(line.Trim(), "(\\d+)\\s*$");
                        if (!m.Success) continue;
                        int pid = int.Parse(m.Groups[1].Value);
                        if (pid <= 4) continue;
                        try { Process.GetProcessById(pid).Kill(); } catch { }
                    }
                }
                return WaitForPortFree(port, 12000);
            }
            catch { return false; }
        }

        public static bool WaitForPortFree(int port, int timeoutMs)
        {
            Stopwatch sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < timeoutMs)
            {
                if (!PortOpen("127.0.0.1", port)) return true;
                System.Threading.Thread.Sleep(400);
            }
            return false;
        }

        /// <summary>
        /// 打开 DSH Web 界面。
        /// 本方法会做耗时操作（最多几十秒），**必须跑在后台线程**，progress/confirm 用于回界面。
        /// </summary>
        public static string OpenDshWeb(bool dryRun)
        {
            return OpenDshWeb(dryRun, null, null);
        }

        public static string OpenDshWeb(bool dryRun, Action<string> progress, Func<string, bool> confirm)
        {
            if (!DshAvailable()) return "已跳过：这台机器没有 DSH（本应用只用统计代理 + 悬浮窗）";
            string url = DshWebUrl();
            string host; int port;
            if (!IsListening(url, out host, out port))
            {
                // 刚开机就是这种情况：启动器自己把 DSH 拉起来
                if (dryRun) return "（演练）" + host + ":" + port + " 没在监听 → 会启动 dsh web 并打开页面";
                return StartDshCaptured(progress);
            }

            // DSH 已在运行：优先用之前保存的令牌链接（不依赖浏览器 Cookie）
            string saved = ReadSessionUrl();
            if (saved != null && (dryRun || ProbeUrl(saved) == 200))
            {
                if (dryRun) return "（演练）会用已保存的令牌链接打开：" + saved;
                try { Process.Start(new ProcessStartInfo(saved) { UseShellExecute = true }); }
                catch (Exception ex) { return "打开失败：" + ex.Message; }
                return "已用令牌链接打开 DSH（不依赖浏览器 Cookie）";
            }

            // 拿不到令牌：问一句是否重启 DSH（会话保存在磁盘上，不会丢）
            bool restart = false;
            if (confirm != null && !dryRun)
            {
                restart = confirm(
                    "DSH 已经在运行，但启动器拿不到它的登录令牌，直接打开可能提示“需要认证”。\n\n" +
                    "要不要重启 DSH？重启后启动器就能用新令牌直接打开页面。\n" +
                    "（对话记录保存在磁盘上，不会丢失）");
            }
            if (restart)
            {
                if (progress != null) progress("正在重启 DSH…");
                if (!KillPortOwner(port)) return "没能停掉正在运行的 DSH，请手动关闭后重试";
                return StartDshCaptured(progress);
            }

            if (dryRun) return "（演练）会打开：" + url;
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
            catch (Exception ex) { return "打开失败：" + ex.Message; }
            return "已打开 " + url + "；若页面提示需要认证，请再点一次本按钮并选择重启 DSH";
        }

        /// <summary>
        /// 启动悬浮窗。用 shell 正常启动（和你双击一样），确保窗口能显示出来。
        /// 带 -NoOpenWeb：DSH 页面由启动器/DSH 自己打开，悬浮窗再开一次就会变成两个页面。
        /// </summary>
        private static void StartWidget()
        {
            string widget = FindFile("widget.ps1");
            if (widget == null) return;
            ProcessStartInfo wpsi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + widget + "\" -Port 8788 -NoOpenWeb");
            wpsi.UseShellExecute = true;                     // 交给 shell，和双击行为一致
            wpsi.WindowStyle = ProcessWindowStyle.Hidden;    // 只隐藏控制台，窗体由脚本自己显示
            wpsi.WorkingDirectory = AppDir;
            Process.Start(wpsi);
        }

        /// <summary>
        /// 启动 token-monitor：代理 + 悬浮窗。
        /// 直接起 node 跑 proxy.js（不经过 start.cmd —— .cmd 在这台机器上会弹
        /// "打开文件 - 安全警告 / 无法验证发布者"），效果和双击 start.cmd 一样。
        /// </summary>
        public static string StartMonitor(bool dryRun, Action<string> progress)
        {
            if (FindFile("proxy.js") == null) return "找不到 proxy.js，请把本程序放在 token-monitor 目录里";
            if (dryRun) return "（演练）会启动代理（若未运行）+ 悬浮窗";

            if (ProxyAlive())
            {
                // 代理已在跑，别再起一个抢端口的进程，这里只补悬浮窗
                if (progress != null) progress("代理已在运行，正在打开悬浮窗…");
                StartWidget();
                return "代理已在运行（8788 在线）；已单独打开悬浮窗";
            }

            if (progress != null) progress("正在启动代理…");
            try { LaunchProxyProcess(); }
            catch (Exception ex) { return "启动代理失败：" + ex.Message; }

            if (!WaitForPort("127.0.0.1", 8788, 30000))
                return "代理 30 秒内没起来，请查看 data\\proxy.log";
            if (progress != null) progress("正在打开悬浮窗…");
            StartWidget();
            return "已启动：代理 + 悬浮窗（代理 8788 在线）";
        }


        public static string StartMonitor(bool dryRun)
        {
            return StartMonitor(dryRun, null);
        }

        /// <summary>
        /// 一键完成整套启动（等价于原来那套"开机自启动"做的事）：
        ///   1) DSH 网页服务没在跑就拉起来（它会自己打开带令牌的页面）
        ///   2) 统计代理没在跑就拉起 start.cmd，然后把悬浮窗打开（悬浮窗自带单实例保护，重复调用安全）
        /// 已经运行的部分会跳过，所以可以反复点。
        ///
        /// 用一把"启动锁"串行化：同时开了两个启动器窗口时，只有一个真正执行启动，
        /// 另一个只等待——否则两份 DSH 会抢同一个配置文件（表现为 EPERM）。
        /// </summary>
        public static string StartEverything(Action<string> progress, Func<string, bool> confirm)
        {
            bool owned = true;
            System.Threading.Mutex gate = null;
            try
            {
                gate = new System.Threading.Mutex(false, "token-monitor-start-all");
                try { owned = gate.WaitOne(0); }
                catch (System.Threading.AbandonedMutexException) { owned = true; }
            }
            catch { owned = true; }   // 拿不到锁就照常执行，不要因此卡住

            if (!owned)
            {
                if (progress != null) progress("另一个启动器正在启动，等它就绪…");
                WaitForPort("127.0.0.1", 3080, 30000);
                WaitForPort("127.0.0.1", 8788, 15000);
                return "另一个启动器已经在启动（本次不重复启动）";
            }

            try
            {
                string dshPart;
                bool dsh = DshAvailable();
                if (!dsh)
                {
                    // 这台机器没有 DSH：整套流程只剩"统计代理 + 悬浮窗"
                    dshPart = "已跳过 DSH（这台机器没装）";
                }
                else
                {
                    string host; int port;
                    if (IsListening(DshWebUrl(), out host, out port))
                    {
                        dshPart = "DSH 已在运行";
                    }
                    else
                    {
                        if (progress != null) progress("DSH 没在运行，正在启动…");
                        string r = StartDshCaptured(progress);
                        dshPart = r.IndexOf("已启动", StringComparison.Ordinal) >= 0 ? "DSH 已启动" : "DSH：" + r;
                    }
                }

                if (progress != null) progress("正在检查统计悬浮窗…");
                bool proxyWasRunning = ProxyAlive();
                string statResult = StartMonitor(false, progress);
                string statPart = statResult.IndexOf("已启动", StringComparison.Ordinal) >= 0
                    ? (proxyWasRunning ? "悬浮窗已打开" : "统计已启动")
                    : statResult;

                return dshPart + "；" + statPart;
            }
            finally
            {
                try { if (gate != null) gate.ReleaseMutex(); } catch { }
                try { if (gate != null) gate.Close(); } catch { }
            }
        }

        // ------------------------------------------------------------------
        // config.json 读写（"设置"里的 API Key 用）
        // 只改目标字段，其余内容和排版原样保留；始终写成不带 BOM 的 UTF-8（与原文件一致）
        // ------------------------------------------------------------------

        public static string ConfigPath()
        {
            return FindFile("config.json") ?? Path.Combine(AppDir, "config.json");
        }

        public static string ReadConfigText()
        {
            try
            {
                string p = ConfigPath();
                if (File.Exists(p)) return File.ReadAllText(p, new UTF8Encoding(false));
            }
            catch { }
            return "{\r\n}\r\n";
        }

        private static string JsonEscape(string s)
        {
            if (s == null) return "";
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"");
        }

        /// <summary>config.json 里的 apiKey（没配置就是空串）。</summary>
        public static string CurrentApiKey()
        {
            try
            {
                Match m = Regex.Match(ReadConfigText(), "\"apiKey\"\\s*:\\s*\"([^\"]*)\"");
                return m.Success ? m.Groups[1].Value : "";
            }
            catch { return ""; }
        }

        public static bool GetBoolSetting(string name)
        {
            try
            {
                Match m = Regex.Match(ReadConfigText(), "\"" + name + "\"\\s*:\\s*(true|false)", RegexOptions.IgnoreCase);
                return m.Success && m.Groups[1].Value.Equals("true", StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        public static bool SaveStringSetting(string name, string value)
        {
            try
            {
                string path = ConfigPath();
                string text = ReadConfigText();
                string json = JsonEscape(value ?? "");
                string pattern = "(\"" + name + "\"\\s*:\\s*\")[^\"]*(\")";
                if (Regex.IsMatch(text, pattern))
                    text = Regex.Replace(text, pattern, delegate(Match m) { return m.Groups[1].Value + json + m.Groups[2].Value; });
                else
                {
                    int i = text.IndexOf('{');
                    if (i < 0) return false;
                    text = text.Insert(i + 1, "\r\n  \"" + name + "\": \"" + json + "\",");
                }
                File.WriteAllText(path, text, new UTF8Encoding(false));
                return true;
            }
            catch { return false; }
        }

        public static bool SaveBoolSetting(string name, bool value)
        {
            try
            {
                string path = ConfigPath();
                string text = ReadConfigText();
                string lit = value ? "true" : "false";
                string pattern = "(\"" + name + "\"\\s*:\\s*)(true|false)";
                if (Regex.IsMatch(text, pattern))
                    text = Regex.Replace(text, pattern, delegate(Match m) { return m.Groups[1].Value + lit; });
                else
                {
                    int i = text.IndexOf('{');
                    if (i < 0) return false;
                    text = text.Insert(i + 1, "\r\n  \"" + name + "\": " + lit + ",");
                }
                File.WriteAllText(path, text, new UTF8Encoding(false));
                return true;
            }
            catch { return false; }
        }

        /// <summary>保存 API Key（顺手去掉首尾空白和误粘进来的 "Bearer "）。</summary>
        public static bool SaveApiKey(string key)
        {
            key = (key ?? "").Trim();
            if (key.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)) key = key.Substring(7).Trim();
            return SaveStringSetting("apiKey", key);
        }

        /// <summary>掩码成 sk-dee****d57f，界面和 --check 都用它，不回显完整 Key。</summary>
        public static string MaskKey(string key)
        {
            key = (key ?? "").Trim();
            if (key.Length == 0) return "（未设置）";
            if (key.Length <= 10) return key.Substring(0, Math.Min(3, key.Length)) + "****";
            return key.Substring(0, 6) + "****" + key.Substring(key.Length - 4);
        }

        /// <summary>是不是"还没绑过 Key"的初次使用状态（填过、或明确跳过过，就不再弹）。</summary>
        public static bool NeedsApiKeySetup()
        {
            return CurrentApiKey().Trim().Length == 0 && !GetBoolSetting("apiKeySetupDone");
        }

        /// <summary>性能监控小窗是否开启（config.json 的 monitor.enabled，缺省 = 关）。</summary>
        public static bool MonitorEnabled()
        {
            return GetBoolSetting("monitorEnabled");
        }

        /// <summary>
        /// 小窗要显示的内容："cpu" / "memory" / "battery" 的逗号串（config.json 的 monitorItems，缺省 = 三项全开）。
        /// </summary>
        public static string MonitorItems()
        {
            try
            {
                Match m = Regex.Match(ReadConfigText(), "\"monitorItems\"\\s*:\\s*\"([^\"]*)\"");
                if (!m.Success) return "cpu,memory,battery";
                string raw = m.Groups[1].Value.Trim();
                if (raw.Length == 0) return "";
                string[] parts = raw.Split(',');
                StringBuilder sb = new StringBuilder();
                foreach (string want in new string[] { "cpu", "memory", "battery" })
                {
                    foreach (string p in parts)
                    {
                        if (p.Trim().Equals(want, StringComparison.OrdinalIgnoreCase))
                        {
                            if (sb.Length > 0) sb.Append(',');
                            sb.Append(want);
                            break;
                        }
                    }
                }
                return sb.ToString();
            }
            catch { return "cpu,memory,battery"; }
        }

        /// <summary>直接起 node 跑 proxy.js（不经过 start.cmd，和 StartMonitor 里那套一致）。</summary>
        private static void LaunchProxyProcess()
        {
            ProcessStartInfo psi = new ProcessStartInfo("cmd.exe",
                "/c start \"token-monitor proxy\" /min cmd /c \"node proxy.js >> data\\proxy.log 2>&1\"");
            psi.UseShellExecute = true;                      // 交给 shell 创建独立控制台，进程能独立存活
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            psi.WorkingDirectory = AppDir;
            Process.Start(psi);
        }

        /// <summary>
        /// 重启统计代理。代理只在启动时读一次 config.json，所以改完 API Key 必须重启它才生效；
        /// 悬浮窗不用动——它的数据全部来自代理接口，会自己跟上。
        /// </summary>
        public static string RestartProxy(Action<string> progress)
        {
            if (FindFile("proxy.js") == null) return "找不到 proxy.js，请把本程序放在 token-monitor 目录里";
            if (ProxyAlive())
            {
                if (progress != null) progress("正在重启代理，让新 Key 生效…");
                KillPortOwner(8788);      // 内部会等端口释放
            }
            else if (progress != null) progress("正在启动代理…");
            try { LaunchProxyProcess(); }
            catch (Exception ex) { return "启动代理失败：" + ex.Message; }
            if (!WaitForPort("127.0.0.1", 8788, 30000)) return "代理 30 秒内没起来，请查看 data\\proxy.log";
            return "已保存；代理已重启（新 Key 生效）";
        }

        public static bool ProxyAlive()
        {
            return PortOpen("127.0.0.1", 8788);
        }

        /// <summary>
        /// 保存"性能监控小窗"的设置。写成两个扁平的标量字段而不是嵌套对象：
        /// 这样 apiKey 那套正则写法直接复用，config.json 里其它内容与排版一个字都不动。
        ///   monitorEnabled : true / false
        ///   monitorItems   : "cpu,memory,battery"（逗号串，空串 = 一项都不显示）
        /// </summary>
        public static bool SaveMonitorSettings(bool enabled, string items)
        {
            try
            {
                string path = ConfigPath();
                string text = ReadConfigText();
                text = UpsertJsonMember(text, "monitorEnabled", enabled ? "true" : "false");
                text = UpsertJsonMember(text, "monitorItems", "\"" + JsonEscape(items ?? "") + "\"");
                File.WriteAllText(path, text, new UTF8Encoding(false));
                return true;
            }
            catch { return false; }
        }

        /// <summary>
        /// 余额提醒：开关（config.json 的 balanceWarnEnabled，缺省 = 关）。
        /// 开着 + 余额低于 balanceWarnThreshold 时，悬浮窗第 1 页那个余额数字画成红色。
        /// </summary>
        public static bool BalanceWarnEnabled()
        {
            return GetBoolSetting("balanceWarnEnabled");
        }

        /// <summary>
        /// 余额提醒的设定值（元，config.json 的 balanceWarnThreshold）。
        /// 缺项 / 解析不出来 = 0，也就是"不提醒"（悬浮窗那边同样按 &gt; 0 才算数）。
        /// </summary>
        public static double BalanceWarnThreshold()
        {
            try
            {
                Match m = Regex.Match(ReadConfigText(), "\"balanceWarnThreshold\"\\s*:\\s*(-?[0-9]+(\\.[0-9]+)?)");
                double v;
                if (m.Success && double.TryParse(m.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out v))
                    return v;
            }
            catch { }
            return 0;
        }

        /// <summary>
        /// 保存"余额提醒"设置。和其它设置一样写成两个扁平字段（复用 UpsertJsonMember，
        /// config.json 里其它内容和排版一个字都不动）：
        ///   balanceWarnEnabled   : true / false
        ///   balanceWarnThreshold : 20（数字，不是字符串；单位元，&lt;= 0 视为不提醒）
        /// ⚠️ 阈值写成**数字**：悬浮窗那边用 [double] 直接比大小，写成字符串也能读，
        ///    但数字更符合"这是个数值设置"的直觉，手工编辑 config.json 时不容易写错。
        /// </summary>
        public static bool SaveBalanceWarnSettings(bool enabled, double threshold)
        {
            try
            {
                string path = ConfigPath();
                string text = ReadConfigText();
                text = UpsertJsonMember(text, "balanceWarnEnabled", enabled ? "true" : "false");
                text = UpsertJsonMember(text, "balanceWarnThreshold",
                    threshold.ToString("0.##", CultureInfo.InvariantCulture));
                File.WriteAllText(path, text, new UTF8Encoding(false));
                return true;
            }
            catch { return false; }
        }

        /// <summary>把 "name": value 写进 config.json（已存在就替换，否则插到第一个 { 之后）。</summary>
        private static string UpsertJsonMember(string text, string name, string literal)
        {
            string pattern = "(\"" + name + "\"\\s*:\\s*)(\"[^\"]*\"|true|false|null|-?[0-9]+(\\.[0-9]+)?)";
            if (Regex.IsMatch(text, pattern))
                return Regex.Replace(text, pattern, delegate(Match m) { return m.Groups[1].Value + literal; });

            int i = text.IndexOf('{');
            if (i < 0) return text;
            return text.Insert(i + 1, "\r\n  \"" + name + "\": " + literal + ",");
        }

        /// <summary>
        /// 重启悬浮窗让新的小窗设置生效。悬浮窗有单实例互斥锁，新起的那个会静默退出，
        /// 所以必须先让旧窗口真的消失：先发 WM_CLOSE（走正常 FormClosing：存位置、删 pid 文件），
        /// 等不到就按 pid 强杀——**旧进程卡在 HTTP 轮询里时，WM_CLOSE 可能好几秒都不被处理**
        /// （2026-10-08 实测：用户点了保存，配置写进去了，但悬浮窗一直是旧的那份代码）。
        /// </summary>
        public static string RestartWidget(Action<string> progress)
        {
            if (FindFile("widget.ps1") == null) return "找不到 widget.ps1，请把本程序放在 token-monitor 目录里";
            if (progress != null) progress("正在重启悬浮窗，让新设置生效…");

            int pid = ReadWidgetPid();
            bool existed = pid > 0 && ProcessAlive(pid);

            if (!CloseWidgetWindow(20000))
            {
                if (existed)
                {
                    if (progress != null) progress("旧悬浮窗没响应关闭请求，正在强制结束它…");
                    KillProcessById(pid);
                }
                // 等它彻底退出（单实例互斥锁要等进程结束才释放）
                DateTime gone = DateTime.UtcNow.AddSeconds(10);
                while (existed && ProcessAlive(pid) && DateTime.UtcNow < gone)
                    System.Threading.Thread.Sleep(200);
                if (existed && ProcessAlive(pid))
                    return "已保存；但旧悬浮窗关不掉（pid " + pid + "），请手动关掉它（Esc 或右上角 ✕）再点一次「一键启动」";
            }

            // 强杀时旧进程来不及删 pid 文件，留着会让"单实例保护"的兜底判断误判，这里清掉
            try
            {
                string pidFile = Path.Combine(AppDir, "data", "widget.pid");
                if (File.Exists(pidFile)) File.Delete(pidFile);
            }
            catch { }

            System.Threading.Thread.Sleep(500);
            StartWidget();
            return "已保存；悬浮窗已重启（新设置生效）";
        }

        /// <summary>data\widget.pid 里记的悬浮窗进程号（没有就是 0）。</summary>
        private static int ReadWidgetPid()
        {
            try
            {
                string pidFile = Path.Combine(AppDir, "data", "widget.pid");
                if (!File.Exists(pidFile)) return 0;
                int pid;
                return int.TryParse(File.ReadAllText(pidFile).Trim(), out pid) ? pid : 0;
            }
            catch { return 0; }
        }

        private static bool ProcessAlive(int pid)
        {
            try { return Process.GetProcessById(pid) != null; }
            catch { return false; }
        }

        /// <summary>按 pid 强杀（taskkill 只打这一个 pid，不碰别的进程）。</summary>
        private static void KillProcessById(int pid)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo("cmd.exe", "/c taskkill /F /PID " + pid);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.WindowStyle = ProcessWindowStyle.Hidden;
                Process.Start(psi);
            }
            catch { }
        }

        /// <summary>给悬浮窗发 WM_CLOSE（按窗口标题找）并等它消失；本来就没有窗口也算成功。</summary>
        private static bool CloseWidgetWindow(int timeoutMs)
        {
            IntPtr target = IntPtr.Zero;
            DateTime deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
            while (DateTime.UtcNow < deadline)
            {
                IntPtr found = FindWindow(null, "Token 用量");
                if (found != IntPtr.Zero) { target = found; break; }
                System.Threading.Thread.Sleep(150);
            }
            if (target == IntPtr.Zero) return true;

            IntPtr res;
            SendMessageTimeout(target, 0x0010, IntPtr.Zero, IntPtr.Zero, 0x0002, 4000, out res);

            // 等窗口真的消失：给足时间，旧进程可能在等一次 2 秒超时的 HTTP 请求
            DateTime gone = DateTime.UtcNow.AddSeconds(8);
            while (DateTime.UtcNow < gone)
            {
                if (FindWindow(null, "Token 用量") == IntPtr.Zero) return true;
                System.Threading.Thread.Sleep(200);
            }
            return false;
        }

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    }

    internal static class Cli
    {
        public static int Run(string arg)
        {
            try
            {
                bool dry = arg == "--dry-run";
                if (arg == "--check")
                {
                    Console.WriteLine("安装目录   : " + Core.AppDir);
                    Console.WriteLine("DSH 工作区 : " + Core.DshWorkDir());
                    Console.WriteLine("启动 DSH   : " + (!Core.DshAvailable()
                        ? "（这台机器没有 DSH，DSH 相关功能自动跳过）"
                        : (Core.FindDshBin() != null
                            ? "node \"" + Core.FindDshBin() + "\" web（不经过 .cmd）"
                            : "dsh.cmd（退回命令行脚本）")));
                    Console.WriteLine("config.json: " + (Core.FindFile("config.json") ?? "（未找到）"));
                    Console.WriteLine("API Key    : " + Core.MaskKey(Core.CurrentApiKey())
                        + (Core.NeedsApiKeySetup() ? "（还没绑过，下次打开启动器会提示填写）" : ""));
                    Console.WriteLine("DSH Web    : " + Core.DshWebUrl() + "  " + (Core.PortOpen("127.0.0.1", 3080) ? "在线" : "离线"));
                    Console.WriteLine("代理 8788  : " + (Core.ProxyAlive() ? "在线" : "离线"));
                    Console.WriteLine("写 ~/.dsh  : " + (Core.HasDshWriteAccess() ? "可以（不是受限环境）" : "被拒（受限环境！从桌面快捷方式启动）"));
                    return 0;
                }
                if (arg == "--dry-run")
                {
                    Console.WriteLine(Core.OpenDshWeb(true));
                    Console.WriteLine(Core.StartMonitor(true));
                    return 0;
                }
                if (arg == "--open-dsh") { Console.WriteLine(Core.OpenDshWeb(false)); return 0; }
                if (arg == "--start-monitor") { Console.WriteLine(Core.StartMonitor(dry)); return 0; }
                if (arg == "--restart-widget") { Console.WriteLine(Core.RestartWidget(null)); return 0; }
                if (arg == "--start-dsh") { Console.WriteLine(Core.StartDshCaptured()); return 0; }
                if (arg == "--auto") { Console.WriteLine(Core.StartEverything(null, null)); return 0; }
                if (arg == "--restart-dsh")
                {
                    if (Core.KillPortOwner(3080)) Console.WriteLine(Core.StartDshCaptured());
                    else Console.WriteLine("没有正在运行的 DSH（或停不掉），直接启动：" + Core.StartDshCaptured());
                    return 0;
                }
                if (arg == "--dsh-url")
                {
                    string saved = Core.ReadSessionUrl();
                    Console.WriteLine("保存的令牌链接: " + (saved ?? "（还没有）"));
                    if (saved != null) Console.WriteLine("该链接状态码: " + Core.ProbeUrl(saved) + "（200 = 仍然有效）");
                    return 0;
                }
                return 2;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("出错：" + ex.Message);
                return 1;
            }
        }
    }

    /// <summary>Win11 风格圆角按钮。</summary>
    internal class FluentButton : Button
    {
        public Color Fill = Color.FromArgb(45, 45, 45);
        public Color FillHover = Color.FromArgb(58, 58, 58);
        public Color FillPress = Color.FromArgb(36, 36, 36);
        public Color BorderColor = Color.FromArgb(66, 66, 66);
        public Color TextColor = Color.FromArgb(255, 255, 255);
        public int Radius = 6;

        private bool hover, press;

        public FluentButton()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            BackColor = Color.FromArgb(32, 32, 32);
            ForeColor = TextColor;
            Cursor = Cursors.Hand;
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; press = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { press = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { press = false; Invalidate(); base.OnMouseUp(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            Color fill = press ? FillPress : (hover ? FillHover : Fill);
            using (GraphicsPath path = Rounded(0, 0, Width, Height, Radius))
            using (SolidBrush b = new SolidBrush(fill))
            {
                g.FillPath(b, path);
                if (BorderColor.A > 0)
                {
                    using (Pen p = new Pen(BorderColor, 1)) { g.DrawPath(p, path); }
                }
            }
            TextRenderer.DrawText(g, Text, Font, new Rectangle(0, 0, Width, Height), TextColor,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }

        public static GraphicsPath Rounded(float x, float y, float w, float h, float r)
        {
            GraphicsPath path = new GraphicsPath();
            if (r < 0.5f) { path.AddRectangle(new RectangleF(x, y, w, h)); return path; }
            float d = r * 2;
            path.AddArc(x, y, d, d, 180, 90);
            path.AddArc(x + w - d - 1, y, d, d, 270, 90);
            path.AddArc(x + w - d - 1, y + h - d - 1, d, d, 0, 90);
            path.AddArc(x, y + h - d - 1, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }
    }

    /// <summary>
    /// 右上角的"设置"齿轮按钮：Win11 图标按钮的样子——无底无边，
    /// 平时是灰色齿轮描边，鼠标移上去变白并出现一个圆角悬停底色。
    /// </summary>
    internal class GearButton : Control
    {
        private bool hover, press;

        public GearButton()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Color.FromArgb(32, 32, 32);   // 和窗体底色一致，不用真透明，避免残影
            Cursor = Cursors.Hand;
            // 图标按钮的点击区：40x40（96 DPI 设计值）——图钉本身还是 8.6 半径，
            // 屏幕上的大小和收紧前一致（以前是 32px 控制像素被系统拉伸成 40）。
            Size = new Size(Dpi.S(40), Dpi.S(40));
            TabStop = false;
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; press = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { press = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { press = false; Invalidate(); base.OnMouseUp(e); }

        /// <summary>齿轮轮廓：一圈"齿顶弧 + 齿谷弧"交替连成的闭合路径。</summary>
        public static GraphicsPath GearPath(float cx, float cy, float rOut, float rIn, int teeth)
        {
            GraphicsPath path = new GraphicsPath();
            float step = 360f / teeth;
            float toothSweep = step * 0.42f;
            float valleySweep = step - toothSweep;
            for (int i = 0; i < teeth; i++)
            {
                float a0 = i * step - toothSweep / 2f;
                path.AddArc(cx - rOut, cy - rOut, rOut * 2f, rOut * 2f, a0, toothSweep);
                path.AddArc(cx - rIn, cy - rIn, rIn * 2f, rIn * 2f, a0 + toothSweep, valleySweep);
            }
            path.CloseFigure();
            return path;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            if (hover || press)
            {
                using (GraphicsPath bg = FluentButton.Rounded(2, 2, Width - 4, Height - 4, 5))
                using (SolidBrush b = new SolidBrush(Color.FromArgb(press ? 40 : 26, 255, 255, 255)))
                {
                    g.FillPath(b, bg);
                }
            }
            Color ink = (hover || press) ? Color.White : Color.FromArgb(205, 205, 205);
            float cx = Width / 2f, cy = Height / 2f;
            using (Pen p = new Pen(ink, 1.5f))
            {
                p.LineJoin = LineJoin.Round;
                using (GraphicsPath gear = GearPath(cx, cy, 8.6f, 6.5f, 8)) { g.DrawPath(p, gear); }
                g.DrawEllipse(p, cx - 3.1f, cy - 3.1f, 6.2f, 6.2f);
            }
        }
    }

    /// <summary>
    /// 图一那种开关：胶囊轨道 + 白色圆钮；关=灰、开=绿，切换时钮滑过去。
    /// WinForms 没有这个样子的控件，只能自绘。
    /// 尺寸 36×20（96 DPI 设计值），乘 Dpi.Factor 得到当前 DPI 的像素：
    /// 这台机器 125% → 45×25，正好和用户给的那张参考图一样大（以前是靠系统拉伸位图凑出来的，字会虚）。
    /// </summary>
    internal class ToggleSwitch : Control
    {
        public static readonly Color TrackOff = Color.FromArgb(100, 100, 100);
        public static readonly Color TrackOffHover = Color.FromArgb(124, 124, 124);
        public static readonly Color TrackOn = Color.FromArgb(50, 173, 82);
        public static readonly Color TrackOnHover = Color.FromArgb(62, 192, 100);
        public static readonly Color CardBg = Color.FromArgb(43, 43, 43);

        public event EventHandler CheckedChanged;

        private bool hover, press, isChecked;
        private float anim;              // 0=关 1=开，滑块当前的位置（动画用）
        private Timer timer;

        public ToggleSwitch()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw |
                     ControlStyles.Selectable, true);
            BackColor = CardBg;
            Size = new Size(Dpi.S(36), Dpi.S(20));
            Cursor = Cursors.Hand;
            TabStop = true;
        }

        public bool Checked
        {
            get { return isChecked; }
            set
            {
                if (isChecked == value) return;
                isChecked = value;
                StartAnim();
                EventHandler h = CheckedChanged;
                if (h != null) h(this, EventArgs.Empty);
            }
        }

        /// <summary>直接落位、不动画、不触发 CheckedChanged（初始化回填用）。</summary>
        public void SetCheckedSilent(bool value)
        {
            if (isChecked == value) return;
            isChecked = value;
            anim = value ? 1f : 0f;
            Invalidate();
        }

        private void StartAnim()
        {
            if (!IsHandleCreated) { anim = isChecked ? 1f : 0f; Invalidate(); return; }
            if (timer == null)
            {
                timer = new Timer();
                timer.Interval = 15;
                timer.Tick += delegate
                {
                    float target = isChecked ? 1f : 0f;
                    float d = target - anim;
                    if (Math.Abs(d) < 0.03f) { anim = target; timer.Stop(); }
                    else anim += d * 0.34f;
                    Invalidate();
                };
            }
            timer.Start();
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; press = false; Invalidate(); base.OnMouseLeave(e); }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left && Enabled)
            {
                press = true;
                Focus();
                Invalidate();
            }
            base.OnMouseDown(e);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            if (press && e.Button == MouseButtons.Left && Enabled && ClientRectangle.Contains(e.Location))
            {
                Checked = !Checked;
            }
            press = false;
            Invalidate();
            base.OnMouseUp(e);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (Enabled && (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter))
            {
                Checked = !Checked;
                e.Handled = true;
            }
            base.OnKeyDown(e);
        }

        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float w = Width, h = Height;
            Color track;
            if (!Enabled) track = Color.FromArgb(58, 58, 58);
            else if (isChecked) track = hover ? TrackOnHover : TrackOn;
            else track = hover ? TrackOffHover : TrackOff;

            using (GraphicsPath path = FluentButton.Rounded(0, 0, w - 1, h - 1, h / 2f))
            using (SolidBrush b = new SolidBrush(track))
            {
                g.FillPath(b, path);
            }

            float cur = Enabled ? anim : (isChecked ? 1f : 0f);
            float knob = h - 4;
            float x = 2f + (w - 4 - knob) * cur;
            using (SolidBrush kb = new SolidBrush(Enabled ? Color.White : Color.FromArgb(140, 140, 140)))
            {
                g.FillEllipse(kb, x, 2f, knob, knob);
            }
            using (Pen p = new Pen(Color.FromArgb(46, 0, 0, 0), 1f))
            {
                g.DrawEllipse(p, x, 2f, knob, knob);
            }
            if (Focused)
            {
                using (GraphicsPath fp = FluentButton.Rounded(-2.5f, -2.5f, w + 4, h + 4, h / 2f + 2.5f))
                using (Pen p = new Pen(Color.FromArgb(150, 96, 205, 255), 1f))
                {
                    g.DrawPath(p, fp);
                }
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && timer != null) { timer.Dispose(); timer = null; }
            base.Dispose(disposing);
        }
    }

    /// <summary>
    /// 左侧导航项（参考图二那种）：图标 + 文字，选中时一整条圆角高亮。
    /// </summary>
    internal class NavItem : Control
    {
        public string Kind = "key";      // key / chart / bell
        public bool Selected;

        private bool hover;

        public NavItem()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Color.FromArgb(32, 32, 32);
            Cursor = Cursors.Hand;
            Font = new Font("Microsoft YaHei UI", 10F);
            Size = new Size(Dpi.S(196), Dpi.S(38));
            TabStop = false;
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

            if (Selected || hover)
            {
                Color fill = Selected ? Color.FromArgb(51, 51, 51) : Color.FromArgb(41, 41, 41);
                using (GraphicsPath path = FluentButton.Rounded(0, 0, Width - 1, Height - 1, 8))
                using (SolidBrush b = new SolidBrush(fill))
                {
                    g.FillPath(b, path);
                }
            }

            Color ink = (Selected || hover) ? Color.White : Color.FromArgb(198, 198, 198);
            Color iconInk = Selected ? Color.FromArgb(96, 205, 255) : ink;
            // 图标/文字的横向位置也要跟着 DPI 走：框变宽了而文字还贴在 40px 处的话，
            // 高 DPI 下图标和文字会挤在一起（内部几何都是 96 DPI 设计值，统一乘 Dpi.Factor）。
            float u = Dpi.Factor;
            DrawIcon(g, iconInk, 18f * u, Height / 2f);
            TextRenderer.DrawText(g, Text, Font, new Rectangle((int)Math.Round(40f * u), 0, Width - (int)Math.Round(48f * u), Height), ink,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }

        /// <summary>没有图标字体可用，就自己画 16px 的线框图标（描边风格，跟参考图一致）。</summary>
        private void DrawIcon(Graphics g, Color ink, float cx, float cy)
        {
            float u = Dpi.Factor;
            using (Pen p = new Pen(ink, 1.6f * u))
            {
                p.StartCap = LineCap.Round;
                p.EndCap = LineCap.Round;
                p.LineJoin = LineJoin.Round;
                if (Kind == "bell")
                {
                    // 余额提醒：一口铃（上半圆顶 + 两侧外撇 + 底线 + 下面的小锤 + 顶上的挂钩）
                    g.DrawArc(p, cx - 5.5f * u, cy - 6f * u, 11f * u, 11f * u, 180f, 180f);
                    g.DrawLine(p, cx - 5.5f * u, cy - 0.5f * u, cx - 6.5f * u, cy + 3.5f * u);
                    g.DrawLine(p, cx + 5.5f * u, cy - 0.5f * u, cx + 6.5f * u, cy + 3.5f * u);
                    g.DrawLine(p, cx - 6.5f * u, cy + 3.5f * u, cx + 6.5f * u, cy + 3.5f * u);
                    g.DrawArc(p, cx - 2f * u, cy + 2.6f * u, 4f * u, 3.4f * u, 0f, 180f);
                    g.DrawLine(p, cx, cy - 8.2f * u, cx, cy - 6f * u);
                }
                else if (Kind == "chart")
                {
                    g.DrawLine(p, cx - 5f * u, cy + 5.5f * u, cx - 5f * u, cy + 0.5f * u);
                    g.DrawLine(p, cx, cy + 5.5f * u, cx, cy - 3f * u);
                    g.DrawLine(p, cx + 5f * u, cy + 5.5f * u, cx + 5f * u, cy - 6.5f * u);
                }
                else
                {
                    g.DrawEllipse(p, cx - 7f * u, cy - 3.6f * u, 7.2f * u, 7.2f * u);
                    g.DrawLine(p, cx + 0.1f * u, cy, cx + 6.2f * u, cy);
                    g.DrawLine(p, cx + 3f * u, cy, cx + 3f * u, cy + 3.2f * u);
                    g.DrawLine(p, cx + 6.2f * u, cy, cx + 6.2f * u, cy + 3.2f * u);
                }
            }
        }
    }

    /// <summary>卡片：自己画一块 #2B2B2B 的圆角底（参考图二里右侧那一大块）。</summary>
    internal class CardPanel : Panel
    {
        public Color CardColor = Color.FromArgb(43, 43, 43);
        public int Radius = 10;

        public CardPanel()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Color.FromArgb(32, 32, 32);   // 圆角外面露出来的就是窗体底色
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath path = FluentButton.Rounded(0, 0, Width - 1, Height - 1, Radius))
            using (SolidBrush b = new SolidBrush(CardColor))
            {
                e.Graphics.FillPath(b, path);
            }
        }
    }

    /// <summary>圆角输入框的壳（深底 + 一圈描边），里面放一个无边框 TextBox。</summary>
    internal class FieldPanel : Panel
    {
        public FieldPanel()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Color.FromArgb(43, 43, 43);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath path = FluentButton.Rounded(0.5f, 0.5f, Width - 1.5f, Height - 1.5f, 6))
            using (SolidBrush b = new SolidBrush(Color.FromArgb(26, 26, 26)))
            {
                e.Graphics.FillPath(b, path);
            }
            using (GraphicsPath path = FluentButton.Rounded(0.5f, 0.5f, Width - 1.5f, Height - 1.5f, 6))
            using (Pen p = new Pen(Color.FromArgb(64, 64, 64), 1f))
            {
                e.Graphics.DrawPath(p, path);
            }
        }
    }

    /// <summary>
    /// 设置窗口：布局照用户给的参考图二——左侧一列导航（图标 + 文字，选中整条高亮），
    /// 右侧一张卡片，卡片里一行行"标题 +（可选）说明 + 右边的开关 / 按钮"；
    /// 开关是参考图一那种胶囊开关。三个页面：① API Key；② 性能监控；③ 余额提醒。
    /// 底部仍是「取消 / 保存」——保存才落盘，行为跟以前一模一样。
    /// </summary>
    internal class SettingsForm : Form
    {
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        // 配色沿用悬浮窗那套 Win11 深色：窗体 #202020、卡片 #2B2B2B、次要文字 #A0A0A0、强调 #60CDFF
        private static readonly Color PageBg = Color.FromArgb(32, 32, 32);
        private static readonly Color CardBg = Color.FromArgb(43, 43, 43);
        private static readonly Color TextMain = Color.FromArgb(250, 250, 250);
        private static readonly Color TextMuted = Color.FromArgb(160, 160, 160);
        private static readonly Color Accent = Color.FromArgb(96, 205, 255);

        // ⚠️ 这些常量是"96 DPI 设计值"，**只准在构造函数里读一次**，
        //    再用 Dpi.S() 换算成当前 DPI 下的像素；控件用完就丢，别在别处直接用。
        // 2026-10-09 第二版：删掉五行小字之后整体收紧（用户："布局紧凑一些"）。
        //    窗口 740x560 → 660x470；行高 84/62 → 72/52/44；导航列 232 → 190。
        private const int NavX = 14;
        private const int ContentX = 190;     // 内容列左边缘 = 卡片左边缘
        private const int RightMargin = 24;
        private const int TitleY = 14;
        private const int CardY = 52;
        private const int RowPadX = 18;
        private const int RowTop = 10;

        // 构造函数里算好的当前 DPI 像素值（下面所有布局都用这几个）
        private readonly int navX, contentX, rightMargin, titleY, rowPadX, rowTop;
        private int cardY;                    // 会被 AddPageTitle 按标题实际高度往下推
        private readonly int pageH, pageTitleH, pageTitleW, cardH;
        private readonly int navY1, navY2, navY3, navW, navH;
        private readonly int btnW, btnH, btnGap, btnBottomMargin;
        private readonly int tipH, tipTop, tipGap, oneLineH;
        private readonly int fieldH, fieldGap, fieldTextX, fieldTextY, fieldTextH;
        private readonly int toggleW, toggleH, smallBtnW, smallBtnH;

        private const int NavItemW = 176, NavItemH = 34;
        private const int ToggleW = 36, ToggleH = 20;
        private const int SmallBtnW = 72, SmallBtnH = 30;

        /// <summary>用户点了保存时的 Key（取消时是 null）。</summary>
        public string SavedKey = null;
        /// <summary>用户点了保存时的小窗设置（取消时 Submitted 仍为 false）。</summary>
        public bool MonitorSubmitted = false;
        public bool MonitorEnabledResult = false;
        public string MonitorItems = null;
        /// <summary>用户点了保存时的余额提醒设置（只有点了保存才会有意义）。</summary>
        public bool WarnEnabledResult = false;
        public double WarnThresholdResult = 0;

        private readonly TextBox box = new TextBox();
        private readonly ToggleSwitch showKey = new ToggleSwitch();
        private readonly ToggleSwitch monEnabled = new ToggleSwitch();
        private readonly ToggleSwitch monCpu = new ToggleSwitch();
        private readonly ToggleSwitch monMem = new ToggleSwitch();
        private readonly ToggleSwitch monBat = new ToggleSwitch();
        private readonly ToggleSwitch warnEnabled = new ToggleSwitch();
        private readonly TextBox warnBox = new TextBox();
        private readonly NavItem navKey = new NavItem();
        private readonly NavItem navMon = new NavItem();
        private readonly NavItem navWarn = new NavItem();
        private readonly Panel pageKey = new Panel();
        private readonly Panel pageMon = new Panel();
        private readonly Panel pageWarn = new Panel();
        private FluentButton btnAll;
        private FluentButton btnNone;

        public SettingsForm(string currentKey, bool firstRun, string items, bool monitorEnabled,
            string openPage, bool warnEnabled, double warnThreshold)
        {
            // ---------- 先把"96 DPI 设计值"换算成当前 DPI 的像素 ----------
            // 为什么必须这么做：进程声明 DPI 感知后（见 Dpi 类），Windows 不再帮我们拉伸整窗，
            // 字会按真 DPI 变大（9pt 从 15px 变 19px），而按 96 DPI 摆的框纹丝不动 →
            // 标题、说明的下半截全被裁掉（用户截图里"明文显示"那行就是这样）。
            // 所以坐标和尺寸要跟着一起长，字的物理大小和现在屏幕上**一样**，只是不再发虚。
            navX = Dpi.S(NavX); contentX = Dpi.S(ContentX); rightMargin = Dpi.S(RightMargin);
            titleY = Dpi.S(TitleY); cardY = Dpi.S(CardY); rowPadX = Dpi.S(RowPadX); rowTop = Dpi.S(RowTop);
            pageH = Dpi.S(470) - Dpi.S(52);          // 客户区高 - 底部按钮区
            pageTitleH = Dpi.S(32); pageTitleW = Dpi.S(200); cardH = Dpi.S(200);
            navY1 = Dpi.S(20); navY2 = Dpi.S(20 + 38); navY3 = Dpi.S(20 + 76);
            navW = Dpi.S(NavItemW); navH = Dpi.S(NavItemH);
            btnW = Dpi.S(88); btnH = Dpi.S(32); btnGap = Dpi.S(10); btnBottomMargin = Dpi.S(44);
            tipH = Dpi.S(26); tipTop = Dpi.S(8); tipGap = Dpi.S(6); oneLineH = Dpi.S(24);
            fieldH = Dpi.S(32); fieldGap = Dpi.S(6); fieldTextX = Dpi.S(10); fieldTextY = Dpi.S(7);
            fieldTextH = Dpi.S(20);
            toggleW = Dpi.S(ToggleW); toggleH = Dpi.S(ToggleH);
            smallBtnW = Dpi.S(SmallBtnW); smallBtnH = Dpi.S(SmallBtnH);

            Text = firstRun ? "首次使用 · 填写 API Key" : "token-monitor 设置";
            // 窗口比内容高 52px（设计值）：底部那一条是留给「取消 / 保存」的，页面面板不许铺到这里来
            // （踩过：面板铺满整个客户区，把按钮整个盖住了，见下面面板尺寸那段的注释）。
            ClientSize = new Size(Dpi.S(660), Dpi.S(470));
            // ⚠️ 必须关掉 WinForms 的自动缩放（2026-10-08 深夜踩的坑）：
            // Form 默认 AutoScaleMode=Font，会拿"当前字体"和"建窗体时记下的字体"比一遍，
            // 比值不是 1 就**把内容整体缩放一遍**，而窗体自己的 ClientSize
            // 不一定跟着放大 → 内容溢出：开关飞到窗口右边外面、保存按钮掉到可视区下面。
            // **最坑的是渲染预览看不出来**：--render-settings 走 DrawToBitmap，不经过这一步缩放，
            // 所以我按预览图验收时一切正常，只有真窗口是坏的。
            // 改成 None 之后布局就是我写的像素值 —— 而"Dpi 感知 + 自己按 Dpi.S() 缩放"这套
            // （2026-10-09）比让 WinForms 自动缩放可控得多，别再打开它。
            AutoScaleMode = AutoScaleMode.None;
            BackColor = PageBg;
            ForeColor = Color.White;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.CenterParent;
            Font = new Font("Microsoft YaHei UI", 9F);
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            // ---------- 左侧导航 ----------
            navKey.Text = "API Key";
            navKey.Kind = "key";
            navKey.Size = new Size(navW, navH);
            navKey.Location = new Point(navX, navY1);
            navKey.Click += delegate { SelectPage("key"); };
            Controls.Add(navKey);

            navMon.Text = "性能监控";
            navMon.Kind = "chart";
            navMon.Size = new Size(navW, navH);
            navMon.Location = new Point(navX, navY2);
            navMon.Click += delegate { SelectPage("monitor"); };
            Controls.Add(navMon);

            navWarn.Text = "余额提醒";
            navWarn.Kind = "bell";
            navWarn.Size = new Size(navW, navH);
            navWarn.Location = new Point(navX, navY3);
            navWarn.Click += delegate { SelectPage("warn"); };
            Controls.Add(navWarn);

            // ---------- 右侧三个页面 ----------
            // ⚠️ 页面面板**绝对不能铺到窗口底部那一条**（底部 64px 是按钮区）。
            // 踩过的坑（2026-10-08 深夜，用户报"保存按钮不见了"）：WinForms 的 Controls.Add 是把控件加到
            // z 序的**最后（最底层）**，所以后加的面板反而压在先加的控件上面；面板铺满客户区时，
            // 右下角的「保存 / 取消」被整块盖住 —— 而 --render-settings 走 DrawToBitmap 的绘制顺序不同，
            // 预览图里按钮**照样看得见**，于是验收时完全没发现。所以：既不重叠，再顺手把按钮拉到最前。
            pageKey.Location = new Point(contentX, 0);
            pageKey.Size = new Size(ClientSize.Width - contentX - rightMargin, pageH);
            pageKey.BackColor = PageBg;
            Controls.Add(pageKey);

            pageMon.Location = new Point(contentX, 0);
            pageMon.Size = pageKey.Size;
            pageMon.BackColor = PageBg;
            pageMon.Visible = false;
            Controls.Add(pageMon);

            pageWarn.Location = new Point(contentX, 0);
            pageWarn.Size = pageKey.Size;
            pageWarn.BackColor = PageBg;
            pageWarn.Visible = false;
            Controls.Add(pageWarn);

            BuildKeyPage(currentKey, firstRun);
            BuildMonitorPage(items, monitorEnabled);
            BuildWarnPage(warnEnabled, warnThreshold);
            SelectPage(openPage);

            // ---------- 底部按钮 ----------
            FluentButton cancel = MakeButton("取消", btnW, false);
            cancel.Location = new Point(ClientSize.Width - rightMargin - btnW, ClientSize.Height - btnBottomMargin);
            cancel.BackColor = PageBg;
            cancel.DialogResult = DialogResult.Cancel;
            Controls.Add(cancel);

            FluentButton ok = MakeButton("保存", btnW, true);
            ok.Location = new Point(ClientSize.Width - rightMargin - btnW - btnGap - btnW, ClientSize.Height - btnBottomMargin);
            ok.BackColor = PageBg;
            ok.Click += delegate { Save(); };
            Controls.Add(ok);

            AcceptButton = ok;
            CancelButton = cancel;
            // 再兜一道：不管控件是按什么顺序加的，底部这两个按钮永远在最前
            // （2026-10-08 深夜的坑：页面面板盖住了它们，用户报"保存按钮不见了"）
            ok.BringToFront();
            cancel.BringToFront();

            Shown += delegate
            {
                try
                {
                    int round = 2;   // DWMWCP_ROUND
                    DwmSetWindowAttribute(Handle, 33, ref round, 4);
                    int dark = 1;    // 深色标题栏
                    DwmSetWindowAttribute(Handle, 20, ref dark, 4);
                }
                catch { }
                if (pageKey.Visible) { box.Focus(); box.SelectAll(); }
            };
        }

        // ───────────────────────── 页面搭建 ─────────────────────────

        private void AddPageTitle(Panel page, string title)
        {
            Label t = new Label();
            t.Text = title;
            t.Font = new Font("Microsoft YaHei UI", 13F, FontStyle.Bold);
            t.ForeColor = TextMain;
            t.BackColor = PageBg;
            // 标题继续用 AutoSize：实测量过（120 DPI 下），Label 自己算出来的是 34px，
            // 恰好等于 TrueType 行高、字一个像素都不缺；反而 TextRenderer.MeasureText(NoPadding)
            // 量出来是 38px，多出来的 4px 只是行距，会让标题看着往下掉。
            t.AutoSize = true;
            t.Location = new Point(0, titleY);
            page.Controls.Add(t);
            // 卡片跟着标题的实际高度往下让，保证任何 DPI 下标题都不会和卡片贴上
            // （125% 下标题底 64 + 8 = 72 正好压在卡片原来的 72 上，所以这里必须比大小，不能直接赋值）。
            int titleBottom = titleY + t.Height + Dpi.S(8);
            if (titleBottom > cardY) cardY = titleBottom;
        }

        private CardPanel AddCard(Panel page)
        {
            CardPanel card = new CardPanel();
            card.Location = new Point(0, cardY);
            // 高度按内容收紧，所以先把宽度定下来（后面所有行的排版都按 card.Width 算），
            // 高度最后再改。⚠️ 别把宽度留到最后设，否则中间算出来的尺寸全是默认的 200。
            card.Size = new Size(page.Width, cardH);
            page.Controls.Add(card);
            return card;
        }

        private void BuildKeyPage(string currentKey, bool firstRun)
        {
            AddPageTitle(pageKey, "API Key");
            CardPanel card = AddCard(pageKey);
            int y = rowTop;

            AddRow(card, ref y, firstRun ? "先填一下 API Key，余额那一页才能显示" : "API Key",
                null, null, 52);

            FieldPanel field = new FieldPanel();
            field.Location = new Point(rowPadX, y + fieldGap);
            field.Size = new Size(card.Width - rowPadX * 2, fieldH);
            box.Text = currentKey ?? "";
            box.UseSystemPasswordChar = true;
            box.BorderStyle = BorderStyle.None;
            box.BackColor = Color.FromArgb(26, 26, 26);
            box.ForeColor = Color.White;
            box.Font = new Font("Consolas", 10F);
            box.Location = new Point(fieldTextX, fieldTextY);
            box.Size = new Size(field.Width - fieldTextX * 2, fieldTextH);
            field.Controls.Add(box);
            card.Controls.Add(field);
            y += Dpi.S(40);

            showKey.Location = new Point(card.Width - rowPadX - showKey.Width, y + (Dpi.S(46) - showKey.Height) / 2);
            showKey.CheckedChanged += delegate { box.UseSystemPasswordChar = !showKey.Checked; };
            AddRow(card, ref y, "明文显示", null, showKey, 46);

            FluentButton clear = MakeFlatButton("清空");
            clear.Location = new Point(card.Width - rowPadX - clear.Width, y + (Dpi.S(44) - clear.Height) / 2);
            clear.Click += delegate { box.Text = ""; box.Focus(); };
            AddRow(card, ref y, "清空已填写的 Key", null, clear, 44);

            AddNote(card, ref y, "保存后会自动重启代理，新 Key 立刻生效；明文存在 config.json 里，别把这个目录分享给别人。");
            card.Height = y;
        }

        private void BuildMonitorPage(string items, bool monitorEnabled)
        {
            AddPageTitle(pageMon, "性能监控");
            CardPanel card = AddCard(pageMon);
            int y = rowTop;

            monEnabled.Location = new Point(card.Width - rowPadX - monEnabled.Width, y + (Dpi.S(44) - monEnabled.Height) / 2);
            monEnabled.SetCheckedSilent(monitorEnabled);
            monEnabled.CheckedChanged += delegate { SyncMonitorRows(); };
            AddRow(card, ref y, "性能监控小窗", null, monEnabled, 44);

            // CPU 那行保留小字（用户只点名了"内存占用 / 电池功率"），行高给 72 装得下说明
            monCpu.Location = new Point(card.Width - rowPadX - monCpu.Width, y + (Dpi.S(72) - monCpu.Height) / 2);
            monCpu.SetCheckedSilent(HasItem(items, "cpu"));
            AddRow(card, ref y, "CPU 信息", "占用率 + 当前频率（每秒刷新）", monCpu, 72);

            monMem.Location = new Point(card.Width - rowPadX - monMem.Width, y + (Dpi.S(44) - monMem.Height) / 2);
            monMem.SetCheckedSilent(HasItem(items, "memory"));
            AddRow(card, ref y, "内存占用", null, monMem, 44);

            monBat.Location = new Point(card.Width - rowPadX - monBat.Width, y + (Dpi.S(44) - monBat.Height) / 2);
            monBat.SetCheckedSilent(HasItem(items, "battery"));
            AddRow(card, ref y, "电池功率", null, monBat, 44);

            btnAll = MakeFlatButton("全选");
            btnNone = MakeFlatButton("全不选");
            int rightEdge = card.Width - rowPadX;
            int gap8 = Dpi.S(8);
            btnNone.Location = new Point(rightEdge - btnNone.Width, y + (Dpi.S(48) - btnNone.Height) / 2);
            btnAll.Location = new Point(rightEdge - btnNone.Width - gap8 - btnAll.Width, y + (Dpi.S(48) - btnAll.Height) / 2);
            btnAll.Click += delegate { monCpu.Checked = true; monMem.Checked = true; monBat.Checked = true; };
            btnNone.Click += delegate { monCpu.Checked = false; monMem.Checked = false; monBat.Checked = false; };
            card.Controls.Add(btnAll);
            card.Controls.Add(btnNone);
            AddRow(card, ref y, "显示内容", null, null, 48, btnAll.Width + gap8 + btnNone.Width);

            AddNote(card, ref y, "小窗内容每秒刷新一次。改完保存后悬浮窗会自动重启，不用手动关它。");
            card.Height = y;

            SyncMonitorRows();
        }

        /// <summary>
        /// "余额提醒"页：一个开关 + 一个金额输入框（单位元）。
        /// 开关关着的时候输入框**照样能填**——先填好数字再打开开关是更顺手的顺序；
        /// 校验只在点「保存」时做（见 Save），填了非法值就停下来问，不会悄悄存进去。
        /// </summary>
        private void BuildWarnPage(bool warnOn, double threshold)
        {
            AddPageTitle(pageWarn, "余额提醒");
            CardPanel card = AddCard(pageWarn);
            int y = rowTop;

            warnEnabled.Location = new Point(card.Width - rowPadX - warnEnabled.Width, y + (Dpi.S(48) - warnEnabled.Height) / 2);
            warnEnabled.SetCheckedSilent(warnOn);
            AddRow(card, ref y, "余额低于设定值时变红", null, warnEnabled, 48);

            FieldPanel field = new FieldPanel();
            field.Size = new Size(Dpi.S(120), fieldH);
            field.Location = new Point(card.Width - rowPadX - field.Width, y + (Dpi.S(52) - field.Height) / 2);
            warnBox.BorderStyle = BorderStyle.None;
            warnBox.BackColor = Color.FromArgb(26, 26, 26);
            warnBox.ForeColor = Color.White;
            warnBox.Font = new Font("Consolas", 10F);
            warnBox.TextAlign = HorizontalAlignment.Right;
            warnBox.Location = new Point(fieldTextX, fieldTextY);
            warnBox.Size = new Size(field.Width - fieldTextX * 2, fieldTextH);
            // 设定值 <= 0 就是"没设过"，输入框留空比显示一个 0 更不容易被误会
            if (threshold > 0) warnBox.Text = threshold.ToString("0.##", CultureInfo.InvariantCulture);
            field.Controls.Add(warnBox);
            AddRow(card, ref y, "提醒金额（元）", "低于这个数就变红", field, 52);

            AddNote(card, ref y, "单位是元，例如 20 或 12.5；开关关掉就不提醒。\r\n保存后悬浮窗会自动重启，余额那一行几秒内变色。");
            card.Height = y;
        }

        /// <summary>认全角数字和小数点（中文输入法很容易打出"２０"），顺手去掉货币符号和千分位逗号。</summary>
        private static string NormalizeNumber(string s)
        {
            if (s == null) return "";
            StringBuilder sb = new StringBuilder();
            foreach (char c in s.Trim())
            {
                if (c == '¥' || c == '￥' || c == ' ' || c == ',') continue;
                if (c >= '０' && c <= '９') sb.Append((char)('0' + (c - '０')));   // 全角 → 半角
                else if (c == '．') sb.Append('.');
                else sb.Append(c);
            }
            return sb.ToString();
        }

        /// <summary>
        /// 一行：标题 +（可选）说明 +（可选）右侧控件；返回后 y 前进到下一行。
        /// height / reserveRight 都是 **96 DPI 设计值**，里面统一换算成当前 DPI 的像素。
        /// reserveRight 给"右侧放好几个控件、但不想走 right 参数"的行用（例如显示内容那行的全选/全不选）：
        /// ⚠️ 标题标签是不透明底色，宽度没算够就会**盖住右边先加进去的控件**
        /// （第一版就这么把两个按钮盖成了一条缝）。
        /// </summary>
        private void AddRow(Panel card, ref int y, string title, string desc, Control right, int height, int reserveRight = 0)
        {
            int h = Dpi.S(height);
            int textW = card.Width - rowPadX * 2 - Dpi.S(reserveRight);
            if (right != null) textW -= right.Width + Dpi.S(16);

            Label l = new Label();
            l.Text = title;
            l.Font = new Font("Microsoft YaHei UI", 10F);
            l.ForeColor = TextMain;
            l.BackColor = CardBg;
            l.AutoSize = false;
            l.Size = new Size(textW, tipH);
            l.Location = new Point(rowPadX, desc == null ? y + (h - tipH) / 2 : y + tipTop);
            card.Controls.Add(l);

            if (desc != null)
            {
                Label d = new Label();
                d.Text = desc;
                d.Font = new Font("Microsoft YaHei UI", 8.5F);
                d.ForeColor = TextMuted;
                d.BackColor = CardBg;
                d.AutoSize = false;
                // 带说明的行分两种（135% 缩放是在这台机器上实测出来的，见维护手册 9.2d）：
                //   行高 ≥74（设计值）→ 说明按两行给；行高小的说明只有一句话，按一行给。
                // ⚠️ 这里给的是"标签框"的像素，必须 ≥ 字体在该 DPI 下的行高×行数，
                //    否则标签会把文字的下半截裁掉（用户截图里"明文显示"就是这么被切的）。
                bool twoLine = height >= 74;
                d.Size = new Size(textW, twoLine ? Dpi.S(40 + 8) : Dpi.S(24 + 6));
                d.Location = new Point(rowPadX, twoLine ? y + Dpi.S(32) : y + Dpi.S(30));
                card.Controls.Add(d);
            }
            if (right != null) { card.Controls.Add(right); }
            y += h;
        }

        private void AddNote(Panel card, ref int y, string text)
        {
            Label n = new Label();
            n.Text = text;
            n.Font = new Font("Microsoft YaHei UI", 8.5F);
            n.ForeColor = Color.FromArgb(140, 140, 140);
            n.BackColor = CardBg;
            n.AutoSize = false;
            n.Size = new Size(card.Width - rowPadX * 2, Dpi.S(46 + 6));
            n.Location = new Point(rowPadX, y + Dpi.S(6));
            card.Controls.Add(n);
            y += Dpi.S(58);
        }

        private static bool HasItem(string items, string key)
        {
            return items != null && items.IndexOf(key, StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private void SyncMonitorRows()
        {
            bool on = monEnabled.Checked;
            monCpu.Enabled = on;
            monMem.Enabled = on;
            monBat.Enabled = on;
            if (btnAll != null) btnAll.Enabled = on;
            if (btnNone != null) btnNone.Enabled = on;
        }

        /// <summary>切页：page = "key" / "monitor" / "warn"（其它值一律当 key 页）。</summary>
        private void SelectPage(string page)
        {
            bool warn = string.Equals(page, "warn", StringComparison.OrdinalIgnoreCase);
            bool monitor = !warn && string.Equals(page, "monitor", StringComparison.OrdinalIgnoreCase);
            bool key = !warn && !monitor;

            navKey.Selected = key;
            navMon.Selected = monitor;
            navWarn.Selected = warn;
            navKey.Invalidate();
            navMon.Invalidate();
            navWarn.Invalidate();
            pageKey.Visible = key;
            pageMon.Visible = monitor;
            pageWarn.Visible = warn;
            // 切到余额提醒页就把光标放进金额框：换页之后焦点还留在上一页那个已经隐藏的框里，
            // 用户直接敲键盘会"没反应"。
            if (warn) { try { warnBox.Focus(); warnBox.SelectAll(); } catch { } }
        }

        private void Save()
        {
            string key = (box.Text ?? "").Trim();
            if (key.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)) key = key.Substring(7).Trim();
            if (key.Length > 0 && !key.StartsWith("sk-", StringComparison.OrdinalIgnoreCase))
            {
                if (MessageBox.Show(this, "这串字符不像 DeepSeek 的 Key（通常以 sk- 开头）。仍然保存吗？",
                        "确认", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
            }
            SavedKey = key;

            StringBuilder sb = new StringBuilder();
            if (monCpu.Checked) sb.Append("cpu");
            if (monMem.Checked) { if (sb.Length > 0) sb.Append(','); sb.Append("memory"); }
            if (monBat.Checked) { if (sb.Length > 0) sb.Append(','); sb.Append("battery"); }
            MonitorSubmitted = true;
            MonitorEnabledResult = monEnabled.Checked;
            MonitorItems = sb.ToString();

            // 余额提醒：开关开着就必须有一个能看懂的金额——存下去不生效的话，用户只会以为功能坏了。
            // 开关关着就不较真：能解析就顺手存下来（下次打开不用重填），解析不了当没设，
            // **绝不让一个当前用不到的输入框拦住保存**。
            string warnText = NormalizeNumber(warnBox.Text);
            double warnValue = 0;
            bool warnParsed = warnText.Length > 0 &&
                double.TryParse(warnText, NumberStyles.Float, CultureInfo.InvariantCulture, out warnValue);
            if (warnEnabled.Checked && (!warnParsed || warnValue <= 0))
            {
                MessageBox.Show(this, "已经打开了余额提醒，就请填一个大于 0 的金额（单位：元），例如 20 或 12.5。\r\n"
                    + "不想要这个提醒的话，把上面的开关关掉再保存。",
                    "还差一个金额", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                warnBox.Focus();
                warnBox.SelectAll();
                return;
            }
            WarnEnabledResult = warnEnabled.Checked;
            WarnThresholdResult = warnParsed ? warnValue : 0;

            DialogResult = DialogResult.OK;
            Close();
        }

        // ───────────────────────── 按钮外观 ─────────────────────────

        private static FluentButton MakeButton(string text, int w, bool accent)
        {
            FluentButton b = new FluentButton();
            b.Text = text;
            b.Font = new Font("Microsoft YaHei UI", 9.5F, accent ? FontStyle.Bold : FontStyle.Regular);
            b.Size = new Size(w, Dpi.S(36));
            b.Radius = 6;
            if (accent)
            {
                b.Fill = Accent;
                b.FillHover = Color.FromArgb(126, 216, 255);
                b.FillPress = Color.FromArgb(70, 180, 230);
                b.BorderColor = Color.Transparent;
                b.TextColor = Color.FromArgb(10, 20, 26);
            }
            return b;
        }

        /// <summary>卡片里的小按钮（全选 / 清空这种）：底色跟卡片一致，别露出方角。</summary>
        private static FluentButton MakeFlatButton(string text)
        {
            FluentButton b = new FluentButton();
            b.Text = text;
            b.Font = new Font("Microsoft YaHei UI", 9F);
            b.Size = new Size(Dpi.S(SmallBtnW), Dpi.S(SmallBtnH));
            b.Radius = 6;
            b.BackColor = CardBg;
            b.Fill = Color.FromArgb(58, 58, 58);
            b.FillHover = Color.FromArgb(70, 70, 70);
            b.FillPress = Color.FromArgb(48, 48, 48);
            b.BorderColor = Color.Transparent;
            b.TextColor = Color.FromArgb(240, 240, 240);
            return b;
        }

        /// <summary>
        /// 把每个控件的实际矩形 / 文字 / 可见性打出来（--render-settings 用）。
        /// 预览图里"某个按钮看不到"这类问题，靠它一眼看出是没建、位置不对还是被盖住。
        /// </summary>
        public string DumpTree()
        {
            StringBuilder sb = new StringBuilder();
            DumpInto(sb, this, 0);
            return sb.ToString();
        }

        private static void DumpInto(StringBuilder sb, Control parent, int depth)
        {
            foreach (Control c in parent.Controls)
            {
                string text = c.Text ?? "";
                if (text.Length > 14) text = text.Substring(0, 14) + "…";
                text = text.Replace("\r", " ").Replace("\n", " ");
                sb.Append(new string(' ', depth * 2));
                sb.Append(string.Format("[{0} \"{1}\" {2} {3}x{4} vis={5} en={6} idx={7}]",
                    c.GetType().Name, text, c.Location, c.Width, c.Height, c.Visible, c.Enabled,
                    c.Parent == null ? -1 : c.Parent.Controls.GetChildIndex(c)));
                sb.Append("\n");
                if (c.Controls.Count > 0) DumpInto(sb, c, depth + 1);
            }
        }
    }

    internal class LauncherForm : Form
    {
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        private readonly Label statusDsh = new Label();
        private readonly Label statusProxy = new Label();
        private readonly Label result = new Label();
        private readonly Timer timer = new Timer();
        private FluentButton btnWeb;
        private FluentButton btnStart;
        private GearButton btnSettings;
        private readonly ToolTip tips = new ToolTip();
        private bool busy;
        /// <summary>预览渲染模式下不要真的执行启动动作。</summary>
        public static bool SuppressAutoRun = false;
        /// <summary>启动后直接打开"设置 · API Key"（--settings 用），不跑启动动作。</summary>
        public static bool OpenSettingsOnStart = false;
        /// <summary>打开设置窗时直接切到"性能监控"那一页（--settings-monitor 用）。</summary>
        public static bool OpenMonitorTabOnStart = false;
        /// <summary>打开设置窗时直接切到"余额提醒"那一页（--settings-warn 用）。</summary>
        public static bool OpenWarnTabOnStart = false;
        /// <summary>--render 预览时先塞进结果区的那句话（检查长消息下的底部高度）。</summary>
        public static string PreviewMessage = null;
        /// <summary>最近一次 FitResult 量到的几何数据，--render 会打出来（排查底部高度用）。</summary>
        public static string LayoutInfo = "";

        /// <summary>把主要控件的实际矩形打出来（--render 用；布局对不上时靠它定位）。</summary>
        public string DumpBounds()
        {
            StringBuilder sb = new StringBuilder();
            foreach (Control c in Controls)
            {
                string name = c.GetType().Name;
                string text = c.Text ?? "";
                if (text.Length > 12) text = text.Substring(0, 12) + "…";
                sb.Append(string.Format("[{0} {1} {2} {3}x{4} vis={5}] ", name, text, c.Location, c.Width, c.Height, c.Visible));
            }
            return sb.ToString();
        }

        /// <summary>把耗时操作丢到后台线程跑，界面保持响应（否则会显示“未响应”）。</summary>
        private void RunBusy(string busyText, Func<string> work)
        {
            if (busy) { Show("正在忙，请稍候再试"); return; }
            busy = true;
            btnWeb.Enabled = false;
            btnStart.Enabled = false;
            Show(busyText);
            System.Threading.ThreadPool.QueueUserWorkItem(delegate
            {
                string message;
                try { message = work(); }
                catch (Exception ex) { message = "出错：" + ex.Message; }
                try
                {
                    BeginInvoke((MethodInvoker)delegate
                    {
                        busy = false;
                        btnWeb.Enabled = true;
                        btnStart.Enabled = true;
                        Show(message);
                    });
                }
                catch { }
            });
        }

        private void Progress(string text)
        {
            try
            {
                if (InvokeRequired) { BeginInvoke((MethodInvoker)delegate { Show(text); }); return; }
                Show(text);
            }
            catch { }
        }

        private bool ConfirmRestart(string message)
        {
            try
            {
                if (InvokeRequired)
                {
                    bool answer = false;
                    Invoke((MethodInvoker)delegate
                    {
                        answer = MessageBox.Show(this, message, "token-monitor 启动器",
                            MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes;
                    });
                    return answer;
                }
                return MessageBox.Show(this, message, "token-monitor 启动器",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes;
            }
            catch { return false; }
        }

        public LauncherForm()
        {
            Text = "token-monitor 启动器";
            // 紧凑版（2026-10-05 用户要求"布局更紧凑一点"，随后又指出"最下面的空间留得太多"）：
            // 原来 430x292，现在宽度不变、高度按最下面那行结果文字的实际行数**动态**算（FitResult）。
            // 元素、字体、配色、宽度都没动，只收紧间距和底部留白。
            // 2026-10-09：以前屏上的大小是"系统把整窗位图拉伸 1.25 倍"凑出来的（所以发虚）；
            // 现在改成"进程声明 DPI 感知 + 自己乘 Dpi.S()"，屏上大小不变、字变清晰（见 Dpi 类）。
            // ⚠️ 不要开 WinForms 的自动缩放（AutoScaleMode.Font/Dpi）：和手工摆坐标混在一起会互相打架
            // （设置窗那边为这个坑专门写了注释）。
            // 2026-10-09 再收紧一次（用户："布局紧凑一些"）：430x210 → 410x190，
            // 按钮 40→36 高、行距 46→40、图标 40→34、底部留白 12→8。
            ClientSize = new Size(Dpi.S(410), Dpi.S(190));   // 初始值，真正的最终高度由末尾的 FitResult() 定
            AutoScaleMode = AutoScaleMode.None;
            BackColor = Color.FromArgb(32, 32, 32);
            ForeColor = Color.FromArgb(255, 255, 255);
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Microsoft YaHei UI", 9F);
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            // 顶部：图标 + 标题
            PictureBox logo = new PictureBox();
            logo.Location = new Point(Dpi.S(16), Dpi.S(10));
            logo.Size = new Size(Dpi.S(34), Dpi.S(34));
            logo.SizeMode = PictureBoxSizeMode.Zoom;
            logo.BackColor = Color.Transparent;
            try { if (Icon != null) logo.Image = Icon.ToBitmap(); } catch { }
            Controls.Add(logo);

            Label title = new Label();
            title.Text = "token-monitor";
            title.Font = new Font("Microsoft YaHei UI", 13F, FontStyle.Bold);
            title.ForeColor = Color.White;
            title.BackColor = Color.Transparent;
            title.Location = new Point(Dpi.S(58), Dpi.S(8));
            title.AutoSize = true;
            Controls.Add(title);

            Label sub = new Label();
            sub.Text = "DSH 用量监控 · 启动器";
            sub.Font = new Font("Microsoft YaHei UI", 8.5F);
            sub.ForeColor = Color.FromArgb(155, 155, 155);
            sub.BackColor = Color.Transparent;
            sub.Location = new Point(Dpi.S(60), Dpi.S(30));
            sub.AutoSize = true;
            Controls.Add(sub);

            // 右上角：设置（齿轮）
            btnSettings = new GearButton();
            btnSettings.Location = new Point(Dpi.S(352), Dpi.S(8));
            btnSettings.Click += delegate { OpenSettings(); };
            Controls.Add(btnSettings);
            tips.SetToolTip(btnSettings, "设置：API Key（查询账户余额用）");

            // 按钮 1：一键启动全部（等价于原来那套开机自启动做的事）
            btnWeb = new FluentButton();
            btnWeb.Text = "一键启动：DSH 网页 + 统计悬浮窗";
            btnWeb.Font = new Font("Microsoft YaHei UI", 10F, FontStyle.Bold);
            btnWeb.Location = new Point(Dpi.S(18), Dpi.S(52));
            btnWeb.Size = new Size(Dpi.S(374), Dpi.S(36));
            btnWeb.Fill = Color.FromArgb(96, 205, 255);      // Win11 强调色
            btnWeb.FillHover = Color.FromArgb(126, 216, 255);
            btnWeb.FillPress = Color.FromArgb(70, 180, 230);
            btnWeb.BorderColor = Color.Transparent;
            btnWeb.TextColor = Color.FromArgb(10, 20, 26);   // 强调色按钮用深色文字
            btnWeb.Radius = 6;
            btnWeb.Click += delegate
            {
                RunBusy("正在启动全部…", delegate
                {
                    return Core.StartEverything(Progress, ConfirmRestart);
                });
            };
            Controls.Add(btnWeb);

            // 按钮 2：只打开 DSH 网页（不碰统计）
            btnStart = new FluentButton();
            btnStart.Text = "只打开 DSH 网页";
            btnStart.Font = new Font("Microsoft YaHei UI", 10F);
            btnStart.Location = new Point(Dpi.S(18), Dpi.S(92));
            btnStart.Size = new Size(Dpi.S(374), Dpi.S(36));
            btnStart.Radius = 6;
            btnStart.Click += delegate
            {
                RunBusy("正在打开 DSH 页面…", delegate { return Core.OpenDshWeb(false, Progress, ConfirmRestart); });
            };
            Controls.Add(btnStart);

            // 状态行
            statusDsh.Text = "DSH Web ●";
            statusDsh.ForeColor = Color.FromArgb(155, 155, 155);
            statusDsh.BackColor = Color.Transparent;
            statusDsh.Location = new Point(Dpi.S(18), Dpi.S(138));
            statusDsh.AutoSize = true;
            Controls.Add(statusDsh);

            statusProxy.Text = "代理 ●";
            statusProxy.ForeColor = Color.FromArgb(155, 155, 155);
            statusProxy.BackColor = Color.Transparent;
            statusProxy.Location = new Point(Dpi.S(150), Dpi.S(138));
            statusProxy.AutoSize = true;
            Controls.Add(statusProxy);

            result.Text = "就绪";
            result.ForeColor = Color.FromArgb(120, 120, 120);
            result.BackColor = Color.Transparent;
            result.Location = new Point(Dpi.S(18), Dpi.S(156));
            result.Size = new Size(Dpi.S(374), Dpi.S(30));   // 高度由 FitResult() 按文字实际行数调整
            Controls.Add(result);

            // 没有 DSH 的机器：把 DSH 相关的东西收起来，界面只剩"统计代理 + 悬浮窗"，
            // 顺手把状态行和结果区往上收，别留一块空白（窗口高度最后由 FitResult() 定）
            if (!Core.DshAvailable())
            {
                btnStart.Visible = false;
                btnWeb.Text = "一键启动：统计代理 + 悬浮窗";
                sub.Text = "API 用量监控 · 启动器";   // 没 DSH 就别提 DSH
                statusDsh.Visible = false;
                statusProxy.Location = new Point(Dpi.S(18), Dpi.S(96));   // 顶到空出来的那行
                result.Location = new Point(Dpi.S(18), Dpi.S(118));
            }

            FitResult();   // 按"就绪"这两个字量一次，窗口底边就贴着它
            if (PreviewMessage != null) Show(PreviewMessage);   // --render 的预览消息（检查长消息高度）

            timer.Interval = 2000;
            timer.Tick += delegate { RefreshStatus(); };
            Shown += delegate
            {
                try
                {
                    int round = 2;   // DWMWCP_ROUND
                    DwmSetWindowAttribute(Handle, 33, ref round, 4);
                    int dark = 1;    // 深色标题栏
                    DwmSetWindowAttribute(Handle, 20, ref dark, 4);
                }
                catch { }
                RefreshStatus();
                timer.Start();

                if (OpenSettingsOnStart) { OpenSettings(); return; }   // --settings：只开设置窗
                if (SuppressAutoRun) return;   // --render 预览模式：只画界面，不动系统

                // 初次使用（还没绑过 Key）：先把设置窗弹出来（两个页签都在，可以顺手配好小窗），再跑启动
                bool needProxyRestart = false;
                bool needWidgetRestart = false;
                if (Core.NeedsApiKeySetup())
                {
                    string oldMon = (Core.MonitorEnabled() ? "1" : "0") + "|" + Core.MonitorItems();
                    string oldWarnSig = WarnSignature(Core.BalanceWarnEnabled(), Core.BalanceWarnThreshold());
                    using (SettingsForm f = new SettingsForm("", true,
                        Core.MonitorItems().Length > 0 ? Core.MonitorItems() : "cpu,memory,battery", false, "key",
                        Core.BalanceWarnEnabled(), Core.BalanceWarnThreshold()))
                    {
                        if (f.ShowDialog(this) == DialogResult.OK)
                        {
                            if (Core.SaveApiKey(f.SavedKey))
                            {
                                Core.SaveBoolSetting("apiKeySetupDone", true);
                                needProxyRestart = Core.ProxyAlive();   // 代理在跑就得重启才认新 Key
                            }
                            else
                            {
                                Show("写入 config.json 失败，请检查目录权限");
                            }
                            if (f.MonitorSubmitted && Core.SaveMonitorSettings(f.MonitorEnabledResult, f.MonitorItems ?? ""))
                            {
                                needWidgetRestart = ((f.MonitorEnabledResult ? "1" : "0") + "|" + (f.MonitorItems ?? "")) != oldMon;
                            }
                            // 初次使用时改了"余额提醒"：和上面小窗那条一样，得重启悬浮窗才生效
                            if (WarnSignature(f.WarnEnabledResult, f.WarnThresholdResult) != oldWarnSig
                                && Core.SaveBalanceWarnSettings(f.WarnEnabledResult, f.WarnThresholdResult))
                            {
                                needWidgetRestart = true;
                            }
                        }
                        else
                        {
                            Core.SaveBoolSetting("apiKeySetupDone", true);   // 明确跳过，下次不再弹
                            Show("已跳过设置（右上角齿轮里可以随时补上）");
                        }
                    }
                }

                // 双击打开即自动跑完整套启动（等价于"开机自启动"那套操作，已运行的部分会自动跳过）
                RunBusy("正在启动全部…", delegate
                {
                    string message = Core.StartEverything(Progress, ConfirmRestart);
                    if (needProxyRestart)
                    {
                        string restart = Core.RestartProxy(Progress);
                        if (restart.IndexOf("已保存", StringComparison.Ordinal) >= 0) restart = "代理已重启，新 Key 生效";
                        message = message + "；" + restart;
                    }
                    // 首次使用时改了"性能监控"设置：上面那套可能只补了一个已在跑的旧悬浮窗，
                    // 所以这里再走一次"关掉旧窗→按新配置重开"，保证小窗设置真的生效。
                    if (needWidgetRestart)
                    {
                        string w = Core.RestartWidget(Progress);
                        message = message + "；" + w;
                    }
                    return message;
                });
            };
        }

        /// <summary>
        /// 打开设置窗（页签：API Key / 性能监控）。保存后：
        ///   · Key 变了 → 重启代理（代理只在启动时读配置）；
        ///   · 小窗设置变了 → 重启悬浮窗（悬浮窗有单实例锁，必须让旧窗口先关掉）。
        /// </summary>
        private void OpenSettings()
        {
            string oldKey = Core.CurrentApiKey();
            string oldMon = (Core.MonitorEnabled() ? "1" : "0") + "|" + Core.MonitorItems();
            // 余额提醒也要留着旧值比对：只有真的变了才重启悬浮窗（重启是"关掉再开"，别白折腾一次）
            double oldWarnValue = Core.BalanceWarnThreshold();
            string oldWarn = WarnSignature(Core.BalanceWarnEnabled(), oldWarnValue);
            string openPage = OpenWarnTabOnStart ? "warn" : (OpenMonitorTabOnStart ? "monitor" : "key");
            OpenMonitorTabOnStart = false;
            OpenWarnTabOnStart = false;

            using (SettingsForm f = new SettingsForm(oldKey, false, Core.MonitorItems(), Core.MonitorEnabled(),
                openPage, Core.BalanceWarnEnabled(), oldWarnValue))
            {
                if (f.ShowDialog(this) != DialogResult.OK)
                {
                    Show("已取消，未做改动");
                    return;
                }

                string key = f.SavedKey;
                if (!Core.SaveApiKey(key))
                {
                    Show("写入 config.json 失败，请检查目录权限");
                    return;
                }
                Core.SaveBoolSetting("apiKeySetupDone", true);

                bool monitorChanged = false;
                if (f.MonitorSubmitted)
                {
                    string newMon = (f.MonitorEnabledResult ? "1" : "0") + "|" + (f.MonitorItems ?? "");
                    monitorChanged = newMon != oldMon;
                    if (!Core.SaveMonitorSettings(f.MonitorEnabledResult, f.MonitorItems ?? ""))
                    {
                        Show("写入 config.json 失败，请检查目录权限");
                        return;
                    }
                }

                bool warnChanged = WarnSignature(f.WarnEnabledResult, f.WarnThresholdResult) != oldWarn;
                if (warnChanged && !Core.SaveBalanceWarnSettings(f.WarnEnabledResult, f.WarnThresholdResult))
                {
                    Show("写入 config.json 失败，请检查目录权限");
                    return;
                }

                bool keyChanged = key != (oldKey ?? "").Trim();
                bool widgetChanged = monitorChanged || warnChanged;
                if (widgetChanged && keyChanged)
                {
                    RunBusy("正在重启代理与悬浮窗，让新设置生效…", delegate
                    {
                        string m1 = Core.RestartProxy(Progress);
                        string m2 = Core.RestartWidget(Progress);
                        return m1 + "；" + m2;
                    });
                    return;
                }
                if (widgetChanged)
                {
                    RunBusy("正在重启悬浮窗，让新设置生效…", delegate { return Core.RestartWidget(Progress); });
                    return;
                }
                if (!keyChanged)
                {
                    Show("已保存（没有变化）");
                    return;
                }
                if (!Core.ProxyAlive())
                {
                    Show("已保存 API Key " + Core.MaskKey(key) + "；代理没在运行，下次启动生效");
                    return;
                }
                RunBusy("正在重启代理，让新 Key 生效…", delegate { return Core.RestartProxy(Progress); });
            }
        }

        /// <summary>
        /// "余额提醒"设置的指纹：开关 + 金额拼成一串，只用来判断"这次保存有没有改动"。
        /// 金额按不变文化格式化（20 和 20.00 必须算出同一个指纹，否则每次保存都会白重启一次悬浮窗）。
        /// </summary>
        private static string WarnSignature(bool enabled, double threshold)
        {
            return (enabled ? "1" : "0") + "|" + threshold.ToString("0.##", CultureInfo.InvariantCulture);
        }

        private void Show(string message)
        {
            result.Text = message;
            bool good = message.StartsWith("已") || message.StartsWith("DSH 已") || message.IndexOf("已在运行") >= 0;
            result.ForeColor = good ? Color.FromArgb(108, 203, 95) : Color.FromArgb(255, 153, 164);
            FitResult();
            RefreshStatus();
        }

        /// <summary>
        /// 底部结果区按当前文字的实际行数收缩/伸展，窗口底边始终挨着文字。
        /// 用户 2026-10-05 的原话："最下面的空间留的太多了"——以前固定留 4~5 行的高度，
        /// 平时只有一行，看上去就是一大块空白（消息再长也不会被切）。
        /// </summary>
        private void FitResult()
        {
            int w = Math.Max(Dpi.S(120), result.Width);
            Size need = TextRenderer.MeasureText(
                result.Text ?? string.Empty,
                result.Font,
                new Size(w, int.MaxValue),
                TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);
            int h = Math.Max(need.Height + Dpi.S(2), result.Font.Height + Dpi.S(2));
            if (h > Dpi.S(96)) h = Dpi.S(96);            // 兜底：消息再长也不让窗口失控
            if (result.Height != h) result.Height = h;
            int want = result.Top + h + Dpi.S(8);         // 底边留 8px（设计值）
            if (ClientSize.Height != want) ClientSize = new Size(ClientSize.Width, want);
            LayoutInfo = string.Format("结果区 y={0} h={1} | 客户端 {2}x{3} | 字号高={4} 量得={5}x{6}",
                result.Top, h, ClientSize.Width, ClientSize.Height, result.Font.Height, need.Width, need.Height);
        }

        private void RefreshStatus()
        {
            string url = Core.DshWebUrl();
            string host; int port;
            bool dsh = Core.IsListening(url, out host, out port);
            bool proxy = Core.ProxyAlive();
            if (Core.DshAvailable())
            {
                statusDsh.Text = "DSH Web " + (dsh ? "● 在线" : "○ 离线");
                statusDsh.ForeColor = dsh ? Color.FromArgb(108, 203, 95) : Color.FromArgb(155, 155, 155);
            }
            else
            {
                statusDsh.Visible = false;   // 没装 DSH 就别显示"离线"误导人
            }
            statusProxy.Text = "代理 8788 " + (proxy ? "● 在线" : "○ 离线");
            statusProxy.ForeColor = proxy ? Color.FromArgb(108, 203, 95) : Color.FromArgb(155, 155, 155);
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            // 关启动器 = 只关启动器。它是配置/启动入口，**不要**顺手关掉用户的悬浮窗。
            // （改小窗设置时要重启悬浮窗，走的是 Core.RestartWidget：先关旧窗再按新配置重开，
            //   那是用户点「保存」才会发生的事。）
            base.OnFormClosing(e);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) timer.Dispose();
            base.Dispose(disposing);
        }
    }
}
