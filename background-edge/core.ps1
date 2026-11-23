# 美团桌面看板 · 公共模块（被栅栏脚本、登录脚本 dot-source 引用）
# 用独立配置文件夹的 Edge（不影响你平时用的 Edge），通过本机 DevTools 协议读取页面文字。

$Utf8 = New-Object System.Text.UTF8Encoding($false)
$MtBase = $env:LOCALAPPDATA
if (-not $MtBase) { $MtBase = Join-Path $HOME '.local/share' }
$MT = @{
  Home         = Join-Path $MtBase 'MeituanDesk'
  DashUrl      = 'https://waimaie.meituan.com/#https://waimaieapp.meituan.com/igate/bizdata/home'
  HeadlessPort = 9339
  LoginPort    = 9338
}
$MT.Profile    = Join-Path $MT.Home 'EdgeProfile'
$MT.CookieFile = Join-Path $MT.Home 'cookies.bin'
$MT.UaFile     = Join-Path $MT.Home 'ua.txt'
$MT.LockFile   = Join-Path $MT.Home 'login.lock'
$MT.ScrapeJs   = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'scrape.js'), $Utf8)
[void](New-Item -ItemType Directory -Force -Path $MT.Home)

# ---------- Edge ----------
function Find-Edge {
  if ($env:MTDESK_BROWSER) { return $env:MTDESK_BROWSER }
  $c = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
  )
  try {
    $reg = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction Stop).'(default)'
    if ($reg) { $c = @($reg) + $c }
  } catch { }
  foreach ($p in $c) { if ($p -and (Test-Path $p)) { return $p } }
  throw '没有找到 Microsoft Edge（msedge.exe）'
}

function Get-EdgeVersion {
  try { return (Get-Item (Find-Edge)).VersionInfo.ProductVersion } catch { return '' }
}

function Get-NormalUA {
  if (Test-Path $MT.UaFile) {
    $ua = ([IO.File]::ReadAllText($MT.UaFile, $Utf8)).Trim()
    if ($ua) { return ($ua -replace 'Headless', '') }
  }
  $v = Get-EdgeVersion
  if (-not $v) { $v = '131.0.0.0' }
  $major = $v.Split('.')[0]
  return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$major.0.0.0 Safari/537.36 Edg/$v"
}

# 结束所有使用本看板配置文件夹的 Edge 进程（不会动你平时用的 Edge）
function Stop-ProfileEdge {
  try {
    $procs = Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
      Where-Object { $_.CommandLine -and $_.CommandLine.Contains($MT.Profile) }
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($procs) { Start-Sleep -Milliseconds 800 }
  } catch { }
  if ($script:MtTestProc) { try { $script:MtTestProc.Kill() } catch { }; $script:MtTestProc = $null }
}

function Test-ProfileEdgeRunning {
  try {
    return [bool](Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
      Where-Object { $_.CommandLine -and $_.CommandLine.Contains($MT.Profile) -and $_.CommandLine -notmatch '--type=' })
  } catch { return $false }
}

# 让无界面 Edge 跟着本脚本一起退出（Windows 作业对象）
function Bind-ToJob($proc) {
  try {
    if (-not ('MtDeskJob' -as [type])) {
      Add-Type -ErrorAction Stop -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class MtDeskJob {
  [StructLayout(LayoutKind.Sequential)] struct BASIC { public long a; public long b; public uint LimitFlags; public UIntPtr c; public UIntPtr d; public uint e; public UIntPtr f; public uint g; public uint h; }
  [StructLayout(LayoutKind.Sequential)] struct IOC { public ulong a, b, c, d, e, f; }
  [StructLayout(LayoutKind.Sequential)] struct EXT { public BASIC Basic; public IOC Io; public UIntPtr a; public UIntPtr b; public UIntPtr c; public UIntPtr d; }
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attr, string name);
  [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int cls, IntPtr info, uint len);
  [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proc);
  static IntPtr job = IntPtr.Zero;
  public static bool Bind(IntPtr proc) {
    if (job == IntPtr.Zero) {
      job = CreateJobObject(IntPtr.Zero, null);
      EXT ext = new EXT(); ext.Basic.LimitFlags = 0x2000; // KILL_ON_JOB_CLOSE
      int len = Marshal.SizeOf(typeof(EXT)); IntPtr p = Marshal.AllocHGlobal(len);
      Marshal.StructureToPtr(ext, p, false);
      SetInformationJobObject(job, 9, p, (uint)len);
      Marshal.FreeHGlobal(p);
    }
    return AssignProcessToJobObject(job, proc);
  }
}
'@
    }
    return [MtDeskJob]::Bind($proc.Handle)
  } catch { return $false }
}

function Start-ProfileEdge([int]$Port, [string]$Url, [switch]$Headless) {
  $a = @("--user-data-dir=`"$($MT.Profile)`"", "--remote-debugging-port=$Port",
         '--no-first-run', '--no-default-browser-check', '--disable-sync')
  if ($Headless -or $env:MTDESK_TEST) {
    $a += @('--headless=new', '--disable-gpu', '--mute-audio', '--window-size=1600,1200', "--user-agent=`"$(Get-NormalUA)`"")
  } else {
    $a += @('--new-window', '--window-size=1280,900')
  }
  if ($env:MTDESK_EXTRA_ARGS) { $a += $env:MTDESK_EXTRA_ARGS -split ';;' }
  $a += $Url
  if ($IsLinux) { $p = Start-Process -FilePath (Find-Edge) -ArgumentList $a -PassThru }
  elseif ($Headless) { $p = Start-Process -FilePath (Find-Edge) -ArgumentList $a -PassThru -WindowStyle Hidden }
  else { $p = Start-Process -FilePath (Find-Edge) -ArgumentList $a -PassThru }
  if ($IsLinux) { $script:MtTestProc = $p }
  return $p
}

function Get-Json([string]$url) {
  $wc = New-Object System.Net.WebClient
  $wc.Proxy = $null
  $wc.Encoding = $Utf8
  try { return ($wc.DownloadString($url) | ConvertFrom-Json) } finally { $wc.Dispose() }
}

function Wait-DevTools([int]$Port, [int]$Seconds = 20) {
  $end = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $end) {
    try { return Get-Json "http://127.0.0.1:$Port/json/version" } catch { Start-Sleep -Milliseconds 400 }
  }
  throw "Edge 的调试端口 $Port 没有响应"
}

# ---------- DevTools 协议（单连接，flatten 会话） ----------
$script:Cdp = $null

function Cdp-Open([string]$wsUrl) {
  Cdp-Close
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  try { $ws.Options.Proxy = $null } catch { }
  $ok = $ws.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None).Wait(10000)
  if (-not $ok -or $ws.State -ne 'Open') { throw '连接 Edge 调试接口失败' }
  $script:Cdp = @{ Ws = $ws; Id = 0; Buf = (New-Object byte[] 65536); Ms = (New-Object IO.MemoryStream); Rx = $null }
}

function Cdp-Close {
  if ($script:Cdp) {
    try { $script:Cdp.Ws.Abort() } catch { }
    try { $script:Cdp.Ws.Dispose() } catch { }
  }
  $script:Cdp = $null
}

function Cdp-Recv([int]$TimeoutMs) {
  $c = $script:Cdp
  $end = (Get-Date).AddMilliseconds($TimeoutMs)
  while ($true) {
    if (-not $c.Rx) {
      $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList (, $c.Buf)
      $c.Rx = $c.Ws.ReceiveAsync($seg, [Threading.CancellationToken]::None)
    }
    $left = [int]($end - (Get-Date)).TotalMilliseconds
    if ($left -le 0) { return $null }
    if (-not $c.Rx.Wait($left)) { return $null }
    $r = $c.Rx.Result
    $c.Rx = $null
    if ($r.MessageType -eq 'Close') { throw 'Edge 调试连接已关闭' }
    $c.Ms.Write($c.Buf, 0, $r.Count)
    if ($r.EndOfMessage) {
      $s = $Utf8.GetString($c.Ms.ToArray())
      $c.Ms.SetLength(0)
      return $s
    }
  }
}

function Cdp-Call([string]$Method, $Params = @{}, [string]$Session = $null, [int]$TimeoutMs = 20000) {
  $c = $script:Cdp
  if (-not $c) { throw '未连接 Edge' }
  $c.Id++
  $id = $c.Id
  $msg = @{ id = $id; method = $Method; params = $Params }
  if ($Session) { $msg.sessionId = $Session }
  $bytes = $Utf8.GetBytes(($msg | ConvertTo-Json -Depth 20 -Compress))
  $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList (, $bytes)
  if (-not $c.Ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait(10000)) { throw '发送超时' }
  $end = (Get-Date).AddMilliseconds($TimeoutMs)
  while ($true) {
    $left = [int]($end - (Get-Date)).TotalMilliseconds
    if ($left -le 0) { throw "$Method 超时" }
    $s = Cdp-Recv $left
    if ($null -eq $s) { throw "$Method 超时" }
    if ($s.IndexOf('"id":' + $id + ',') -lt 0 -and $s.IndexOf('"id":' + $id + '}') -lt 0) { continue }
    $o = $s | ConvertFrom-Json
    if ($o.id -ne $id) { continue }
    if ($o.error) { throw "$Method 出错：$($o.error.message)" }
    return $o.result
  }
}

# ---------- 页面 ----------
function Open-NewPage {
  $t = Cdp-Call 'Target.createTarget' @{ url = 'about:blank' }
  $a = Cdp-Call 'Target.attachToTarget' @{ targetId = $t.targetId; flatten = $true }
  return $a.sessionId
}

function Attach-ExistingPage {
  $ts = (Cdp-Call 'Target.getTargets' @{}).targetInfos | Where-Object { $_.type -eq 'page' }
  $t = $ts | Where-Object { $_.url -like '*meituan*' } | Select-Object -First 1
  if (-not $t) { $t = $ts | Select-Object -First 1 }
  if (-not $t) { return Open-NewPage }
  return (Cdp-Call 'Target.attachToTarget' @{ targetId = $t.targetId; flatten = $true }).sessionId
}

function Get-Frames([string]$Session) {
  $tree = (Cdp-Call 'Page.getFrameTree' @{} $Session).frameTree
  $out = New-Object System.Collections.ArrayList
  $stack = New-Object System.Collections.Stack
  $stack.Push($tree)
  while ($stack.Count) {
    $n = $stack.Pop()
    [void]$out.Add($n.frame)
    foreach ($ch in @($n.childFrames)) { if ($ch) { $stack.Push($ch) } }
  }
  return , $out
}

function Invoke-Scrape([string]$Session, [string]$FrameId, [bool]$WantText) {
  $w = Cdp-Call 'Page.createIsolatedWorld' @{ frameId = $FrameId; worldName = 'mtdesk' } $Session
  $expr = $MT.ScrapeJs + '(' + $WantText.ToString().ToLower() + ')'
  $r = Cdp-Call 'Runtime.evaluate' @{ expression = $expr; contextId = $w.executionContextId; returnByValue = $true } $Session
  if ($r.result.value) { return ($r.result.value | ConvertFrom-Json) }
  return $null
}

function Navigate-Dash([string]$Session) {
  [void](Cdp-Call 'Page.navigate' @{ url = 'about:blank' } $Session)
  [void](Cdp-Call 'Page.navigate' @{ url = $MT.DashUrl } $Session)
}

# 读一次数据。返回 @{ status = ok|login|nodata; data; frames; detail }
function Read-Dash([string]$Session, [int]$Seconds = 45) {
  $end = (Get-Date).AddSeconds($Seconds)
  $detail = $null; $frames = @()
  while ((Get-Date) -lt $end) {
    Start-Sleep -Seconds 2
    try { $frames = Get-Frames $Session } catch { continue }
    $top = $frames[0]
    if ($top.url -match 'logon|login|passport') { return @{ status = 'login'; frames = $frames } }
    $cands = @($frames | Where-Object { $_.url -like 'https://*meituan.com*' } | Sort-Object { if ($_.url -like '*bizdata*') { 0 } else { 1 } })
    foreach ($f in $cands) {
      try { $o = Invoke-Scrape $Session $f.id ($f.url -like '*bizdata*') } catch { continue }
      if (-not $o) { continue }
      if ($o.status -eq 'ok') { return @{ status = 'ok'; data = $o; frames = $frames } }
      if ($o.status -eq 'login') { return @{ status = 'login'; frames = $frames } }
      if ($o.text -or $o.error) { $detail = $o }
    }
  }
  return @{ status = 'nodata'; frames = $frames; detail = $detail }
}

# ---------- Cookie（用 Windows DPAPI 加密，只有你这个 Windows 账户能解开） ----------
function Protect-Bytes([byte[]]$b) {
  try { Add-Type -AssemblyName System.Security -ErrorAction Stop; return [Security.Cryptography.ProtectedData]::Protect($b, $null, 'CurrentUser') }
  catch { if ($IsLinux) { return $b }; throw }
}
function Unprotect-Bytes([byte[]]$b) {
  try { Add-Type -AssemblyName System.Security -ErrorAction Stop; return [Security.Cryptography.ProtectedData]::Unprotect($b, $null, 'CurrentUser') }
  catch { if ($IsLinux) { return $b }; throw }
}

function Save-Cookies {
  $all = @((Cdp-Call 'Storage.getCookies' @{}).cookies)
  if (-not $all.Count) { return 0 }
  $json = ConvertTo-Json -InputObject $all -Depth 6 -Compress
  [IO.File]::WriteAllBytes($MT.CookieFile, (Protect-Bytes $Utf8.GetBytes($json)))
  return $all.Count
}

function ConvertTo-CookieParam($c) {
  $p = @{ name = [string]$c.name; value = [string]$c.value; domain = [string]$c.domain; path = [string]$c.path
          secure = [bool]$c.secure; httpOnly = [bool]$c.httpOnly }
  if (-not $p.path) { $p.path = '/' }
  if ($c.sameSite -in @('Strict', 'Lax', 'None')) { $p.sameSite = [string]$c.sameSite }
  if (-not $c.session -and [double]$c.expires -gt 0) { $p.expires = [double]$c.expires }
  return $p
}

function Load-Cookies {
  if (-not (Test-Path $MT.CookieFile)) { return 0 }
  $json = $Utf8.GetString((Unprotect-Bytes ([IO.File]::ReadAllBytes($MT.CookieFile))))
  # 注意：Windows PowerShell 5.1 会把 JSON 数组当成一个整体输出，必须用 -InputObject 再逐个展开
  $parsed = ConvertFrom-Json -InputObject $json
  if ($parsed -isnot [array] -and $null -ne $parsed.value -and $parsed.value -is [array]) { $parsed = $parsed.value }
  $list = New-Object System.Collections.ArrayList
  foreach ($c in $parsed) {
    if ($c -is [array]) { foreach ($cc in $c) { if ($cc.name) { [void]$list.Add((ConvertTo-CookieParam $cc)) } } }
    elseif ($c.name) { [void]$list.Add((ConvertTo-CookieParam $c)) }
  }
  if (-not $list.Count) { return 0 }
  try {
    [void](Cdp-Call 'Storage.setCookies' @{ cookies = $list.ToArray() })
    return $list.Count
  } catch {
    # 整批失败时逐个写入，跳过个别有问题的 Cookie
    $ok = 0
    foreach ($p in $list) {
      try { [void](Cdp-Call 'Storage.setCookies' @{ cookies = @(, $p) }); $ok++ } catch { }
    }
    if (-not $ok) { throw }
    return $ok
  }
}

# ---------- 无界面工作进程 ----------
$script:Worker = $null

function Start-Worker {
  Stop-Worker
  Stop-ProfileEdge
  $p = Start-ProfileEdge -Port $MT.HeadlessPort -Url 'about:blank' -Headless
  [void](Bind-ToJob $p)
  $v = Wait-DevTools $MT.HeadlessPort
  Cdp-Open $v.webSocketDebuggerUrl
  [void](Load-Cookies)
  $script:Worker = @{ Proc = $p; Session = (Open-NewPage) }
}

function Stop-Worker {
  if ($script:Worker) {
    try { [void](Cdp-Call 'Browser.close' @{} $null 3000) } catch { }
    try { if (-not $script:Worker.Proc.HasExited) { $script:Worker.Proc.Kill() } } catch { }
  }
  Cdp-Close
  $script:Worker = $null
}
