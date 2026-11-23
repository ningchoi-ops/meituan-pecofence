# 登录美团（只需一次；登录失效时再运行）
# 打开一个独立的 Edge 窗口，你登录美团商家中心后，脚本自动检测到数据、保存登录状态并关闭窗口。
# 加 -Report 会再用后台无界面 Edge 测一遍，并生成自检报告。
param([switch]$Report)

. (Join-Path $PSScriptRoot 'core.ps1')
$ErrorActionPreference = 'Stop'
$log = New-Object System.Collections.Generic.List[string]
function Say([string]$s, [string]$color = 'Gray') { Write-Host $s -ForegroundColor $color; $log.Add($s) }
function Frames-Text($frames) { return (@($frames) | Where-Object { $_ } | ForEach-Object { '    ' + ($_.url -replace '\?.*$', '?…') }) -join "`r`n" }  # 去掉网址参数（里面有登录令牌）
function Data-Text($d) {
  if (-not $d -or -not $d.rt) { return '    （无）' }
  $r = $d.rt
  $f = { param($m) if ($m) { "$($m.value)（差 $($m.delta) $($m.trend)）" } else { '没读到' } }
  return @(
    "    美团更新时间: $($d.updateText)",
    "    订单实付: $(& $f $r.paid)", "    预计订单收入: $(& $f $r.income)", "    订单量: $(& $f $r.orders)",
    "    曝光人数: $(& $f $r.exposure)", "    入店人数: $(& $f $r.visitors)", "    下单人数: $(& $f $r.buyers)",
    "    热销榜: $(@($d.top).Count) 条    昨日汇总: $(if ($d.yday -and $null -ne $d.yday.paid) { '有' } else { '没读到' })"
  ) -join "`r`n"
}

$loginResult = $null; $headResult = $null; $fatal = $null
[IO.File]::WriteAllText($MT.LockFile, (Get-Date).ToString('o'))
try {
  Say '== 第 1 步：登录 ==' 'Cyan'
  Say ('Edge: ' + (Find-Edge) + '  版本 ' + (Get-EdgeVersion))
  Stop-ProfileEdge
  [void](Start-ProfileEdge -Port $MT.LoginPort -Url $MT.DashUrl)
  $v = Wait-DevTools $MT.LoginPort 30
  if ($v.'User-Agent') { [IO.File]::WriteAllText($MT.UaFile, $v.'User-Agent', $Utf8) }
  Cdp-Open $v.webSocketDebuggerUrl
  Start-Sleep -Seconds 2
  $s = Attach-ExistingPage
  Say '已打开一个独立的 Edge 窗口。请在里面登录美团商家中心（扫码或账号密码都行）。' 'Yellow'
  Say '登录成功、看到经营数据后，窗口会自动关闭。最多等 15 分钟。' 'Yellow'

  $end = (Get-Date).AddMinutes(15)
  $lastNav = Get-Date
  while ((Get-Date) -lt $end) {
    $r = Read-Dash $s 6
    if ($r.status -eq 'ok') { $loginResult = $r; break }
    $top = if ($r.frames) { $r.frames[0].url } else { '' }
    # 已登录但停在别的页面：每 20 秒带它去经营数据页（登录页上不会打扰你输入）
    if ($top -and $top -notmatch 'logon|login|passport|verify|captcha|yoda' -and $top -notlike '*bizdata*' -and ((Get-Date) - $lastNav).TotalSeconds -gt 20) {
      try { [void](Cdp-Call 'Page.navigate' @{ url = $MT.DashUrl } $s); $lastNav = Get-Date } catch { }
    }
    $loginResult = $r
  }
  if ($loginResult.status -ne 'ok') { throw '15 分钟内没有检测到经营数据，登录未完成' }
  $n = Save-Cookies
  Say "登录成功，已保存登录状态（$n 个 Cookie，已用 Windows 账户加密）。" 'Green'
  try { [void](Cdp-Call 'Browser.close' @{} $null 5000) } catch { }
  Cdp-Close
  Start-Sleep -Seconds 2
  Stop-ProfileEdge

  if ($Report) {
    Say '== 第 2 步：后台无界面读取测试 ==' 'Cyan'
    try {
      Start-Worker
      Navigate-Dash $script:Worker.Session
      $headResult = Read-Dash $script:Worker.Session 50
      if ($headResult.status -eq 'ok') { Say '后台读取成功。' 'Green' }
      else { Say "后台读取没有成功：$($headResult.status)" 'Red' }
    } catch { $headResult = @{ status = 'error'; detail = $_.Exception.Message }; Say "后台读取出错：$($_.Exception.Message)" 'Red' }
    finally { Stop-Worker; Stop-ProfileEdge }
  }
} catch {
  $fatal = $_.Exception.Message
  Say "出错：$fatal" 'Red'
  Cdp-Close
} finally {
  Remove-Item $MT.LockFile -Force -ErrorAction SilentlyContinue
}

if ($Report) {
  $os = $(try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { [Environment]::OSVersion.VersionString })
  $rep = @(
    ('美团桌面看板 · 自检报告  ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')),
    "系统: $os    PowerShell: $($PSVersionTable.PSVersion)    .NET: $([Environment]::Version)",
    "Edge: $(try { Find-Edge } catch { '未找到' })  版本 $(Get-EdgeVersion)",
    "致命错误: $(if ($fatal) { $fatal } else { '无' })",
    '',
    "[登录窗口读取] 结果: $(if ($loginResult) { $loginResult.status } else { '无' })",
    '  页面框架:', (Frames-Text $loginResult.frames),
    '  数据:', (Data-Text $loginResult.data),
    '',
    "[后台无界面读取] 结果: $(if ($headResult) { $headResult.status } else { '未执行' })",
    '  页面框架:', (Frames-Text $headResult.frames),
    '  数据:', (Data-Text $headResult.data)
  )
  foreach ($res in @($loginResult, $headResult)) {
    if ($res -and $res.status -ne 'ok' -and $res.detail) {
      $rep += ''
      $rep += '[读不到数据时的页面文字（前 4000 字）]'
      $rep += ($(if ($res.detail -is [string]) { $res.detail } else { "$($res.detail.url)`r`n$($res.detail.error)`r`n$($res.detail.text)" }))
    }
  }
  $rep += ''
  $rep += '[过程]'
  $rep += $log
  $text = $rep -join "`r`n"
  $desk = [Environment]::GetFolderPath('Desktop')
  if (-not $desk) { $desk = $MT.Home }
  $file = Join-Path $desk '美团看板自检报告.txt'
  [IO.File]::WriteAllText($file, $text, (New-Object System.Text.UTF8Encoding($true)))
  try { Set-Clipboard -Value $text } catch { }
  Write-Host ''
  Write-Host "自检报告已保存到桌面：$file（也已复制到剪贴板）" -ForegroundColor Cyan
}
if ($fatal) { exit 1 }
