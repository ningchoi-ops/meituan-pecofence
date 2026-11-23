# <pecofence.type>streamable</pecofence.type>
# <pecofence.allow>run</pecofence.allow>
# 美团外卖 · 今日经营看板（后台版，PecoFence 常驻脚本）
# 在后台用一个看不见的独立 Edge 定时打开美团经营数据页读取数字；关掉平时用的 Edge 也照样更新。

# ======== 可修改的设置 ========
$ShopName     = '我的店铺'      # 栅栏标题
$IntervalSec  = 120             # 多少秒刷新一次美团数据
$StaleMinutes = 8               # 超过多少分钟没成功读取就提示
$EntryBarMax  = 0.15            # 进店转化率进度条满格 = 15%
$OrderBarMax  = 0.30            # 下单转化率进度条满格 = 30%
$ShowTop      = $true           # 显示实时热销前三
$ShowYday     = $true           # 显示昨日全天汇总
$BarOn        = '▰'             # 进度条字符；若显示成方框可改成 '■' / '□'
$BarOff       = '▱'
# ==============================

. (Join-Path $PSScriptRoot 'core.ps1')
try { [Console]::OutputEncoding = $Utf8 } catch { }
$DashUrl = $MT.DashUrl
$DataDir = $env:PECOFENCE_DATA
if (-not $DataDir) { $DataDir = Join-Path $MT.Home 'data' }
[void](New-Item -ItemType Directory -Force -Path $DataDir)
$CacheFile = Join-Path $DataDir 'latest.json'
$LoginScript = Join-Path $PSScriptRoot '登录美团.ps1'
$LoginRun = "run=powershell.exe param1=-NoProfile param2=-ExecutionPolicy param3=Bypass param4=-WindowStyle param5=Hidden param6=-File param7='$LoginScript'"

$script:Data = $null
$script:Phase = 'starting'      # starting | ok | login | nologin | logging-in | error
$script:LastError = ''
$script:LastTry = $null
if (Test-Path $CacheFile) {
  try { $script:Data = [IO.File]::ReadAllText($CacheFile, $Utf8) | ConvertFrom-Json } catch { }
}

# ---------- 格式化 ----------
function Clean([object]$s) {
  if ($null -eq $s) { return '' }
  return ([string]$s) -replace '[\|\r\n"]', ' ' -replace "'", [string][char]0x2032
}
function Has($m) { return ($null -ne $m) -and ($null -ne $m.value) }
function Money($v) { if ($null -eq $v) { return '—' }; return '¥' + ([double]$v).ToString('N2') }
function Int($v)   { if ($null -eq $v) { return '—' }; return ([double]$v).ToString('N0') }
function IntU($v, $u) { if ($null -eq $v) { return '—' }; return ([double]$v).ToString('N0') + ' ' + $u }
function Pct($v)   { if ($null -eq $v) { return '—' }; return ([double]$v * 100).ToString('0.00') + '%' }
function Bar($ratio, $max) {
  if ($null -eq $ratio) { return '' }
  $n = [int][math]::Round([math]::Min([math]::Max($ratio / $max, 0), 1) * 10)
  return ($BarOn * $n) + ($BarOff * (10 - $n))
}
function Delta($m, [switch]$IsMoney) {
  if ($null -eq $m -or $null -eq $m.delta) { return '' }
  if ($IsMoney) { $t = ([double]$m.delta).ToString('N2') } else { $t = ([double]$m.delta).ToString('N0') }
  switch ($m.trend) {
    'up'    { return "▲$t" }
    'down'  { return "▼$t" }
    'flat'  { return '持平' }
    default { return "±$t" }
  }
}
# 昨日同时段的数值 = 今日 ± 差值
function Prev($m) {
  if (-not (Has $m) -or $null -eq $m.delta) { return $null }
  switch ($m.trend) {
    'up'   { return [double]$m.value - [double]$m.delta }
    'down' { return [double]$m.value + [double]$m.delta }
    'flat' { return [double]$m.value }
  }
  return $null
}
function Ratio($a, $b) { if ($null -eq $a -or $null -eq $b -or [double]$b -eq 0) { return $null }; return [double]$a / [double]$b }
function PtChange($now, $before) {
  if ($null -eq $now -or $null -eq $before) { return '' }
  $d = ($now - $before) * 100
  if ([math]::Abs($d) -lt 0.005) { return '持平' }
  if ($d -gt 0) { return '▲' + $d.ToString('0.00') + 'pt' }
  return '▼' + (-$d).ToString('0.00') + 'pt'
}
function Join2($a, $b) { if ($b) { return "$a   $b" }; return $a }


# ---------- 状态行 ----------
function Status-Lines($d) {
  $out = New-Object System.Collections.Generic.List[string]
  $now = [DateTimeOffset]::Now
  $recv = $null
  if ($d -and $d.receivedAt) { $recv = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$d.receivedAt).ToLocalTime() }
  $mins = 99999
  if ($recv) { $mins = [int][math]::Floor(($now - $recv).TotalMinutes) }
  $mt = ''
  if ($d -and $d.updateText) { $mt = ' · 美团 ' + (Clean $d.updateText) + ' 更新' }
  $err = Clean $script:LastError
  switch ($script:Phase) {
    'nologin'    { $out.Add("还没登录美团，点此登录（只需一次） | icon=🔑 color=orange $LoginRun tooltip='会弹出一个独立的 Edge 窗口，登录成功后自动关闭'"); return $out }
    'logging-in' { $out.Add("正在登录… 请在弹出的 Edge 窗口里登录美团 | icon=🔑 color=orange tooltip='登录成功后窗口会自动关闭'"); return $out }
    'login'      { $out.Add("美团登录已失效，点此重新登录 | icon=🔴 color=red $LoginRun tooltip='会弹出一个独立的 Edge 窗口，登录成功后自动关闭'"); return $out }
  }
  if (-not $recv) {
    if ($script:Phase -eq 'error') { $out.Add("后台读取失败，稍后自动重试 | icon=🟠 color=orange tooltip='$err'") }
    else { $out.Add("正在后台打开美团经营数据… | icon=⏳ color=gray tooltip='第一次大约需要 20 秒'") }
    return $out
  }
  if ($recv.Date -ne $now.Date) {
    $out.Add('这是 ' + $recv.ToString('M月d日 HH:mm') + " 的数据，今天还没读到 | icon=🟠 color=orange tooltip='$err'")
  } elseif ($mins -ge $StaleMinutes) {
    $out.Add("已 $mins 分钟没有读到新数据$mt | icon=🟠 color=orange href=$DashUrl tooltip='$err'")
  } else {
    $agoTxt = '刚刚'
    if ($mins -ge 1) { $agoTxt = "$mins 分钟前" }
    $out.Add('同步于 ' + $recv.ToString('HH:mm') + "（$agoTxt）$mt | icon=🟢 color=gray href=$DashUrl tooltip='后台每 $IntervalSec 秒读取一次；点击打开美团经营数据'")
  }
  return $out
}

# ---------- 画栅栏 ----------
function Build-Screen {
  $L = New-Object System.Collections.Generic.List[string]
  $L.Add('~~~')
  $d = $script:Data
  $now = [DateTimeOffset]::Now
  $title = (Clean $ShopName) + ' · 今日实时'

  if ($null -eq $d -or $null -eq $d.rt) {
    $L.Add("$title | icon=🛵 color=orange href=$DashUrl tooltip='点击打开美团经营数据'")
    $L.Add('---')
    foreach ($s in (Status-Lines $null)) { $L.Add($s) }
    return $L
  }

  $rt = $d.rt
  $L.Add("$title | icon=🛵 color=orange href=$DashUrl tooltip='点击打开美团经营数据'")
  $L.Add('---')

  # 收益
  $paid = $rt.paid; $inc = $rt.income; $ord = $rt.orders
  $avg = Ratio $paid.value $ord.value
  $avgPrev = Ratio (Prev $paid) (Prev $ord)
  $avgTxt = ''
  if ($null -ne $avg -and $null -ne $avgPrev) { $avgTxt = '昨同时段 ' + (Money $avgPrev) }

  $L.Add((Join2 ("营业额　" + (Money $paid.value)) (Delta $paid -IsMoney)) + ' | icon=💰 tooltip=''订单实付：顾客实际支付合计；箭头为比昨日同时段''')
  $L.Add((Join2 ("收　入　" + (Money $inc.value)) (Delta $inc -IsMoney)) + ' | icon=💵 tooltip=''预计订单收入：扣除平台服务费、配送费和活动补贴后的商家收入''')
  $L.Add((Join2 ("订单量　" + (IntU $ord.value '单')) (Delta $ord)) + ' | icon=🧾')
  $L.Add((Join2 ("客单价　" + (Money $avg)) $avgTxt) + ' | icon=🧮 tooltip=''客单价 = 订单实付 ÷ 订单量''')
  $L.Add('---')

  # 流量
  $exp = $rt.exposure; $vis = $rt.visitors; $buy = $rt.buyers
  $entry = Ratio $vis.value $exp.value
  $conv  = Ratio $buy.value $vis.value
  $entryPrev = Ratio (Prev $vis) (Prev $exp)
  $convPrev  = Ratio (Prev $buy) (Prev $vis)
  $L.Add((Join2 ("曝光量　" + (IntU $exp.value '人')) (Delta $exp)) + ' | icon=👀')
  $tipE = '入店 ' + (Int $vis.value) + ' 人 ÷ 曝光 ' + (IntU $exp.value '人')
  if ($null -ne $entryPrev) { $tipE += '；昨日同时段 ' + (Pct $entryPrev) }
  $L.Add("进店转化  " + (Pct $entry) + '  ' + (Bar $entry $EntryBarMax) + '  ' + (PtChange $entry $entryPrev) + " | icon=🚪 tooltip='$(Clean $tipE)'")
  $tipC = '下单 ' + (Int $buy.value) + ' 人 ÷ 入店 ' + (Int $vis.value) + ' 人'
  if ($null -ne $convPrev) { $tipC += '；昨日同时段 ' + (Pct $convPrev) }
  $L.Add("下单转化  " + (Pct $conv) + '  ' + (Bar $conv $OrderBarMax) + '  ' + (PtChange $conv $convPrev) + " | icon=🛒 tooltip='$(Clean $tipC)'")

  # 热销
  if ($ShowTop -and $d.top -and @($d.top).Count -gt 0) {
    $L.Add('---')
    $medals = @('🥇', '🥈', '🥉')
    $i = 0
    foreach ($t in @($d.top)) {
      $name = Clean $t.name
      $short = $name
      if ($short.Length -gt 12) { $short = $short.Substring(0, 12) + '…' }
      $L.Add("$short　" + (Money $t.sales) + ' × ' + (Int $t.qty) + " | icon=$($medals[$i]) tooltip='$name'")
      $i++
      if ($i -ge 3) { break }
    }
  }

  # 昨日全天
  if ($ShowYday -and $d.yday -and $null -ne $d.yday.paid) {
    $y = $d.yday
    $L.Add('---')
    $tip = '日期 ' + (Clean $y.date) + '；收入 ' + (Money $y.income) + '；优惠前 ' + (Money $y.gross) + '；补贴及支出 ' + (Money $y.subsidy)
    $L.Add('昨日全天  ' + (Money $y.paid) + ' · ' + (Int $y.orders) + ' 单 · 客单 ' + (Money $y.avg) + " | icon=📅 color=gray tooltip='$(Clean $tip)'")
  }

  # 状态
  $L.Add('---')
  foreach ($s in (Status-Lines $d)) { $L.Add($s) }
  return $L
}

function Render {
  foreach ($line in (Build-Screen)) { Write-Output $line }
}

# ---------- 读取一次 ----------
function Refresh-Once {
  $script:LastTry = Get-Date
  if (-not (Test-Path $MT.CookieFile)) { $script:Phase = 'nologin'; return }
  try {
    if (-not $script:Worker) { Start-Worker }
    $s = $script:Worker.Session
    Navigate-Dash $s
    $r = Read-Dash $s 45
    switch ($r.status) {
      'ok' {
        $obj = $r.data
        $obj | Add-Member -NotePropertyName receivedAt -NotePropertyValue ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -Force
        $obj.PSObject.Properties.Remove('raw')
        $script:Data = $obj
        $script:Phase = 'ok'
        $script:LastError = ''
        try { [IO.File]::WriteAllText($CacheFile, (ConvertTo-Json -InputObject $obj -Depth 8 -Compress), $Utf8) } catch { }
        try { [void](Save-Cookies) } catch { }
      }
      'login' { $script:Phase = 'login' }
      default { $script:Phase = 'error'; $script:LastError = '页面打开了，但没读到今日实时数据' }
    }
    try { [void](Cdp-Call 'Page.navigate' @{ url = 'about:blank' } $s) } catch { }
  } catch {
    $script:Phase = 'error'
    $script:LastError = $_.Exception.Message
    Stop-Worker
  }
}

# ---------- 主循环 ----------
Render
$lastRender = Get-Date
$nextRun = Get-Date
while ($true) {
  $lockAge = $null
  if (Test-Path $MT.LockFile) { $lockAge = ((Get-Date) - (Get-Item $MT.LockFile).LastWriteTime).TotalMinutes }
  if ($null -ne $lockAge -and $lockAge -lt 20) {
    # 正在登录：让出配置文件夹，登录结束后马上读取
    if ($script:Phase -ne 'logging-in') { Stop-Worker; $script:Phase = 'logging-in'; Render; $lastRender = Get-Date }
    $nextRun = Get-Date
    Start-Sleep -Seconds 2
    continue
  }
  if ((Get-Date) -ge $nextRun) {
    Refresh-Once
    $nextRun = (Get-Date).AddSeconds($IntervalSec)
    if ($script:Phase -eq 'nologin' -or $script:Phase -eq 'login') { $nextRun = (Get-Date).AddSeconds(15) }
    Render
    $lastRender = Get-Date
  }
  if (((Get-Date) - $lastRender).TotalSeconds -ge 30) { Render; $lastRender = Get-Date }
  Start-Sleep -Seconds 1
}
