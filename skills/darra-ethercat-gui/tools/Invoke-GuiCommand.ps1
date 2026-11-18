<#
.SYNOPSIS
    向正在运行的 Darra EtherCAT Master GUI 发送一条 AI/自动化命令，并取回 DARRAGUI1R| JSON 回执。

.DESCRIPTION
    传输 = WM_COPYDATA (0x004A)，载荷 = "DARRAGUI1|<命令>"，UTF-16LE，无结尾 NUL。
    本脚本创建一个消息专用窗口 (HWND_MESSAGE)，把它的句柄放进 wParam；
    GUI 处理完后把 "DARRAGUI1R|<json>" 反向回发到该窗口，脚本再解析成对象输出。

    发送侧刻意只用 SMTO_ABORTIFHUNG，绝不加 SMTO_BLOCK —— 加了会在等待期间不处理
    sent message，GUI 的回执必然排队到超时，回执必丢。

    支持的命令（批 0）：
        query:session                 GUI/主站/当前选择/忙碌/上一条命令
        query:slaves[;limit=N]        从站列表（limit 1..1024，默认 256）
        query:slave;n=N               单从站（含 NO_SUCH_SLAVE 拒绝语义）
        query:master                  主站实时量（WKC 镜像 / 在线数 / 状态栏文本）
    通用可选参数：rid=<任意不含分号的串>（原样回显到 requestId）。

.PARAMETER Command
    要发送的命令串，例如 "query:session" 或 "query:slave;n=1;rid=check-1"。

.PARAMETER ProcessName
    目标 GUI 进程名，默认 Darra_EtherCAT_Master。

.PARAMETER WindowHandle
    直接指定 GUI 主窗口句柄（十进制或 0x 十六进制）。默认按进程名自动选
    "可见 + 无 Owner + 面积最大" 的顶层窗口。

.PARAMETER TimeoutMs
    等待 GUI 处理请求的毫秒数，默认 3000。必须大于 GUI 侧回执超时 1000ms。

.PARAMETER Raw
    只输出回执里的 JSON 原文（去掉 DARRAGUI1R| 前缀），不包一层诊断信封。

.OUTPUTS
    默认输出一个 JSON 对象（stdout）：
        sent        消息是否送达 GUI 窗口线程
        resultCode  GUI WndProc 的返回码（新语法：1 受理 / 0 拒绝）
        ok          回执里的 ok（正常时等于 resultCode==1）
        errorCode   传输层错误码（GUI_NOT_RUNNING / GUI_WINDOW_NOT_FOUND / NO_REPLY / TIMEOUT ...）
        errorMessage 传输层错误说明
        hwnd        实际使用的 GUI 窗口句柄
        command     本次请求
        reply       完整回执串（含 DARRAGUI1R| 前缀）
        response    解析后的回执对象 {ok, cmd, requestId, reason, data}
    退出码：0 = 收到回执；2 = 传输失败（没收到回执）；3 = 参数/环境错误。

.EXAMPLE
    .\Invoke-GuiCommand.ps1 -Command "query:session"

.EXAMPLE
    .\Invoke-GuiCommand.ps1 -Command "query:slaves;limit=64;rid=check-07" -Raw

.EXAMPLE
    .\Invoke-GuiCommand.ps1 -Command "query:slave;n=9" |
        ConvertFrom-Json | ForEach-Object { $_.response.reason.code }
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Command,

    [string]$ProcessName = 'Darra_EtherCAT_Master',

    [string]$WindowHandle = '',

    [int]$TimeoutMs = 3000,

    [switch]$Raw
)

$ErrorActionPreference = 'Stop'

if (-not ('DarraGuiCommandClient' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class DarraGuiCommandClient
{
    public const int WM_COPYDATA = 0x004A;
    public const uint SMTO_ABORTIFHUNG = 0x0002;
    private const uint GW_OWNER = 4;
    private const uint MSGFLT_ADD = 1;
    private const int HWND_MESSAGE = -3;

    [StructLayout(LayoutKind.Sequential)]
    public struct COPYDATASTRUCT
    {
        public IntPtr dwData;
        public int cbData;
        public IntPtr lpData;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WNDCLASSEX
    {
        public uint cbSize;
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public string lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
    }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    public delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", SetLastError = true)]
    private static extern IntPtr SendMessageTimeoutCopyData(
        IntPtr hWnd, int msg, IntPtr wParam, ref COPYDATASTRUCT lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);

    [DllImport("user32.dll", EntryPoint = "DefWindowProcW", SetLastError = true)]
    private static extern IntPtr DefWindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", EntryPoint = "RegisterClassExW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ushort RegisterClassEx(ref WNDCLASSEX lpwcx);

    [DllImport("user32.dll", EntryPoint = "CreateWindowExW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowEx(
        uint dwExStyle, string lpClassName, string lpWindowName, uint dwStyle,
        int x, int y, int nWidth, int nHeight, IntPtr hWndParent, IntPtr hMenu,
        IntPtr hInstance, IntPtr lpParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyWindow(IntPtr hWnd);

    [DllImport("kernel32.dll", EntryPoint = "GetModuleHandleW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool ChangeWindowMessageFilter(uint message, uint dwFlag);

    private static readonly string _className = "DarraGuiCmdReplyWnd_" + Guid.NewGuid().ToString("N");
    private static ushort _classAtom = 0;
    private static WndProcDelegate _wndProc;          // 必须静态持有, 防 GC 回收回调
    private static string _reply;
    private static int _replyCount;

    public static IntPtr FindGuiWindow(string processName, out string error)
    {
        error = null;
        Process[] processes;
        try { processes = Process.GetProcessesByName(processName); }
        catch (Exception ex) { error = "枚举进程失败: " + ex.Message; return IntPtr.Zero; }

        if (processes == null || processes.Length == 0)
        {
            error = "GUI_NOT_RUNNING";
            return IntPtr.Zero;
        }

        IntPtr best = IntPtr.Zero;
        long bestScore = -1;
        try
        {
            foreach (Process p in processes)
            {
                int pid = p.Id;
                IntPtr localBest = IntPtr.Zero;
                long localScore = -1;
                EnumWindows(delegate(IntPtr h, IntPtr l)
                {
                    uint winPid;
                    GetWindowThreadProcessId(h, out winPid);
                    if (winPid != (uint)pid) return true;

                    RECT r;
                    if (!GetWindowRect(h, out r)) return true;
                    long area = (long)(r.Right - r.Left) * (long)(r.Bottom - r.Top);
                    if (area < 0) area = 0;
                    bool visible = IsWindowVisible(h);
                    bool unowned = GetWindow(h, GW_OWNER) == IntPtr.Zero;

                    // 与桥接器 GuiSession.SelectMain 同一取舍: 可见 + 无 Owner > 可见 > 任意, 再比面积。
                    long score = area;
                    if (visible) score += 1000000000000L;
                    if (unowned) score += 500000000000L;
                    if (score > localScore) { localScore = score; localBest = h; }
                    return true;
                }, IntPtr.Zero);

                if (localBest != IntPtr.Zero && localScore > bestScore)
                {
                    bestScore = localScore;
                    best = localBest;
                }
            }
        }
        finally
        {
            foreach (Process p in processes)
            {
                try { p.Dispose(); } catch { }
            }
        }

        if (best == IntPtr.Zero) error = "GUI_WINDOW_NOT_FOUND";
        return best;
    }

    public static bool SendCommand(IntPtr guiHwnd, string command, int timeoutMs,
        out int resultCode, out string reply, out string errorCode, out string errorMessage)
    {
        resultCode = 0;
        reply = null;
        errorCode = null;
        errorMessage = null;

        if (guiHwnd == IntPtr.Zero || !IsWindow(guiHwnd))
        {
            errorCode = "WINDOW_GONE";
            errorMessage = "目标窗口句柄无效或窗口已销毁";
            return false;
        }

        string payload = "DARRAGUI1|" + command;
        byte[] bytes = Encoding.Unicode.GetBytes(payload);
        if (bytes.Length <= 0 || bytes.Length > 4096)
        {
            errorCode = "PAYLOAD_TOO_LARGE";
            errorMessage = "载荷 " + bytes.Length + " 字节, 超出 GUI 接受上限 4096 字节";
            return false;
        }

        string createError;
        IntPtr hwnd = CreateReplyWindow(out createError);
        if (hwnd == IntPtr.Zero)
        {
            errorCode = "NO_REPLY_WINDOW";
            errorMessage = createError;
            return false;
        }

        _reply = null;
        _replyCount = 0;
        GCHandle handle = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        try
        {
            COPYDATASTRUCT cds = new COPYDATASTRUCT();
            cds.dwData = IntPtr.Zero;
            cds.cbData = bytes.Length;
            cds.lpData = handle.AddrOfPinnedObject();

            IntPtr result;
            IntPtr ok = SendMessageTimeoutCopyData(guiHwnd, WM_COPYDATA, hwnd, ref cds,
                SMTO_ABORTIFHUNG, (uint)Math.Max(100, timeoutMs), out result);
            if (ok == IntPtr.Zero)
            {
                int win32 = Marshal.GetLastWin32Error();
                errorCode = win32 == 1460 ? "TIMEOUT" : (win32 == 5 ? "ACCESS_DENIED" : "SEND_FAILED");
                errorMessage = "SendMessageTimeout 失败, GetLastError=" + win32;
                return false;
            }

            resultCode = result.ToInt32();
            if (_replyCount == 0)
            {
                /* legacy 13 条与 selectNic 用**返回码**应答, 协议上本来就没有 DARRAGUI1R 回执:
                 *   1 = 已派发; 0 = 未知命令 / 安全判据拒绝; 100..105 = selectNic 结果码。
                 * 这些都是明确答案, 不能报成"没收到回执" —— 否则 104(对话框未打开)会被
                 * 误诊成传输层问题, 使用者会去查 SMTO_BLOCK 而不是去打开对话框。
                 * 只有落在已定义集合之外的返回码才说明通道真的异常。 */
                bool codeIsAnswer = (resultCode == 0 || resultCode == 1 ||
                                     (resultCode >= 100 && resultCode <= 105));
                if (!codeIsAnswer)
                {
                    errorCode = "NO_REPLY";
                    errorMessage = "消息已送达但没收到 DARRAGUI1R| 回执, 且返回码 " + resultCode +
                                   " 不在已定义返回码集合 {0,1,100..105} 内 (调用方是否误用了 SMTO_BLOCK, 或 GUI 侧回执发送失败)";
                }
                return true;
            }

            reply = _reply;
            return true;
        }
        finally
        {
            handle.Free();
            DestroyWindow(hwnd);
        }
    }

    private static IntPtr CreateReplyWindow(out string error)
    {
        error = null;
        IntPtr instance = GetModuleHandle(null);

        if (_classAtom == 0)
        {
            _wndProc = new WndProcDelegate(ReplyWndProc);
            WNDCLASSEX wc = new WNDCLASSEX();
            wc.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
            wc.style = 0;
            wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc);
            wc.hInstance = instance;
            wc.lpszClassName = _className;
            ushort atom = RegisterClassEx(ref wc);
            if (atom == 0)
            {
                error = "RegisterClassEx 失败, GetLastError=" + Marshal.GetLastWin32Error();
                return IntPtr.Zero;
            }
            _classAtom = atom;
            // 若 GUI 与脚本完整性级别不同, 放行 WM_COPYDATA 穿越 UIPI (失败不致命)。
            try { ChangeWindowMessageFilter(WM_COPYDATA, MSGFLT_ADD); } catch { }
        }

        IntPtr hwnd = CreateWindowEx(0, _className, "", 0, 0, 0, 0, 0,
            new IntPtr(HWND_MESSAGE), IntPtr.Zero, instance, IntPtr.Zero);
        if (hwnd == IntPtr.Zero)
            error = "CreateWindowEx 失败, GetLastError=" + Marshal.GetLastWin32Error();
        return hwnd;
    }

    private static IntPtr ReplyWndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_COPYDATA && lParam != IntPtr.Zero)
        {
            COPYDATASTRUCT cds = (COPYDATASTRUCT)Marshal.PtrToStructure(lParam, typeof(COPYDATASTRUCT));
            if (cds.cbData > 0 && cds.lpData != IntPtr.Zero)
            {
                string text = Marshal.PtrToStringUni(cds.lpData, cds.cbData / 2);
                if (text != null && text.StartsWith("DARRAGUI1R|", StringComparison.Ordinal))
                {
                    _reply = text;
                    _replyCount++;
                }
            }
            return new IntPtr(1);
        }
        return DefWindowProc(hWnd, msg, wParam, lParam);
    }
}
'@
}

$hwnd = [IntPtr]::Zero
if ($WindowHandle) {
    $handleText = $WindowHandle.Trim()
    if ($handleText -match '^0[xX][0-9a-fA-F]+$') {
        $hwnd = [IntPtr]([long]::Parse($handleText.Substring(2), [Globalization.NumberStyles]::HexNumber))
    }
    else {
        $hwnd = [IntPtr]([long]$handleText)
    }
}

$findError = ''
if ($hwnd -eq [IntPtr]::Zero) {
    $hwnd = [DarraGuiCommandClient]::FindGuiWindow($ProcessName, [ref]$findError)
}

$resultCode = 0
$reply = ''
$transportCode = ''
$transportMessage = ''
$sent = $false

if ($hwnd -ne [IntPtr]::Zero) {
    $sent = [DarraGuiCommandClient]::SendCommand(
        $hwnd, $Command, $TimeoutMs,
        [ref]$resultCode, [ref]$reply, [ref]$transportCode, [ref]$transportMessage)
}
else {
    $findCode = 'GUI_NOT_FOUND'
    if ($findError) { $findCode = $findError }
    $transportCode = $findCode
    $transportMessage = "未找到进程 $ProcessName 的可用顶层窗口"
}

$response = $null
$ok = $null
$responseText = $null
$parseError = ''
if ($reply -and $reply.StartsWith('DARRAGUI1R|')) {
    $responseText = $reply.Substring(('DARRAGUI1R|').Length)
    try { $response = $responseText | ConvertFrom-Json }
    catch { $parseError = $_.Exception.Message }
}
elseif ($sent -and -not $transportCode) {
    # 返回码型应答: legacy 13 条与 selectNic 本来就只回返回码, 没有 DARRAGUI1R 回执。
    # 按码给结论, 不要把"协议正常形态"报成传输层故障。
    if ($Command -match '^selectNic(\||$)') {
        switch ($resultCode) {
            100 { $ok = $true;  $transportMessage = '已选中并回写主网口' }
            102 { $ok = $true;  $transportMessage = '已选中并回写 (快扫实测该口无从站); 仍需在对话框点「确认」' }
            101 { $ok = $false; $transportCode = 'NIC_NOT_FOUND' }
            103 { $ok = $false; $transportCode = 'NIC_SCAN_PENDING' }
            104 { $ok = $false; $transportCode = 'NIC_DIALOG_NOT_OPEN' }
            105 { $ok = $false; $transportCode = 'NIC_AMBIGUOUS' }
            default { $ok = $false; $transportCode = 'REJECTED' }
        }
        if (-not $transportMessage) {
            $transportMessage = "selectNic 未执行 (返回码 $resultCode)"
        }
    }
    elseif ($resultCode -eq 1) {
        $ok = $true
        $transportMessage = '已派发到 GUI UI 入口'
    }
    elseif ($resultCode -eq 0) {
        $ok = $false
        $transportCode = 'REJECTED'
        $transportMessage = '未知命令或 GUI 安全判据拒绝'
    }
    else {
        $transportCode = 'NO_REPLY'
        $transportMessage = "已送达但回执为空, 且返回码 $resultCode 不在已定义集合 {0,1,100..105} 内"
    }
}

if ($response -ne $null -and $response.PSObject.Properties.Match('ok').Count -gt 0) {
    $ok = [bool]$response.ok
    if (-not $transportCode -and $ok -ne ($resultCode -eq 1)) {
        $transportCode = 'REPLY_RESULT_MISMATCH'
        $transportMessage = "回执 ok=$ok 与返回码 $resultCode 不一致"
    }
}

if ($parseError) {
    $transportCode = 'BAD_REPLY_JSON'
    $transportMessage = $parseError
}

if ($Raw) {
    if ($responseText) { Write-Output $responseText }
    else { Write-Output '' }
}
else {
    $errorCode = $null
    $errorText = $null
    $hwndValue = 0
    if ($transportCode) { $errorCode = $transportCode }
    if ($transportMessage) { $errorText = $transportMessage }
    if ($hwnd -ne [IntPtr]::Zero) { $hwndValue = $hwnd.ToInt64() }
    $envelope = [pscustomobject]@{
        sent           = $sent
        resultCode     = $resultCode
        ok             = $ok
        errorCode      = $errorCode
        errorMessage   = $errorText
        hwnd           = $hwndValue
        command        = $Command
        reply          = $reply
        response       = $response
    }
    $envelope | ConvertTo-Json -Depth 12 -Compress
}

if (-not $sent -or -not $reply) { exit 2 }
exit 0
