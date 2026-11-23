# <pecofence.type>streamable</pecofence.type>
# <pecofence.allow>run</pecofence.allow>
# 美团外卖 · 今日经营看板（扩展版，PecoFence 常驻脚本）
# 接收 Edge 扩展在后台隐藏读取的数据。支持多门店，并会从 GitHub 自动更新。
#
# ⚠ 不要直接改这个文件（自动更新会覆盖它）。要改设置，请编辑同一文件夹里的「设置.ps1」。
# 想每家店一个栅栏：把本文件复制一份，改名为「美团今日经营-店名关键字.ps1」（例如 美团今日经营-海南粉.ps1）。

$AppVersion = '2.2.0'
$UpdateRepo = 'ningchoi-ops/meituan-pecofence'   # GitHub 仓库（用户名/仓库名），自动更新从这里下载

# ---------- 默认设置（在「设置.ps1」里改，不要改这里） ----------
$ShopFilter    = ''         # 只显示店名或门店 ID 里包含这段文字的门店；留空 = 显示全部
$TitleOverride = ''         # 只显示一家店时，用这个代替美团上的店名
$Port          = 17890      # 与 Edge 扩展弹窗里的端口一致
$StaleMinutes  = 8          # 超过多少分钟没收到数据就提示
$EntryBarMax   = 0.15       # 进店转化率进度条满格 = 15%
$OrderBarMax   = 0.30       # 下单转化率进度条满格 = 30%
$ShowTop       = $true      # 显示实时热销前三（只有一家店时）
$ShowYday      = $true      # 显示昨日全天汇总（只有一家店时）
$ShowPeer      = $true      # 显示商圈同行转化率
$AutoUpdate    = $true      # 自动从 GitHub 更新
$BarOn         = '▰'        # 进度条字符；若显示成方框可改成 '■' / '□'
$BarOff        = '▱'
$GoalIncome    = 0          # 今日美团收入目标（元，按「预计订单收入」算）；0 = 不显示目标行
$GoalOrders    = 0          # 今日订单量目标（单）；0 = 不显示
$GoalNote      = ''         # 目标行的悬停说明，例如基准数据
$Plan          = @{}        # 每日任务：@{ '2026-11-24' = '要做的事'; '2026-11-25' = @('要做的事', '悬停显示的细节') }
$PlanDayStart  = 5          # 凌晨几点前仍算前一天（营业到凌晨时，01:00 还显示前一天的任务）

$SettingsFile = Join-Path $PSScriptRoot '设置.ps1'
if (-not (Test-Path $SettingsFile)) {
  $tpl = @(
    '# 美团桌面看板 · 设置（自动更新不会覆盖这个文件）',
    '# 去掉行首的 # 就会生效，改完后在 PecoFence 里重启栅栏。',
    '',
    "# `$TitleOverride = '小顺冰浆'     # 只显示一家店时的栅栏标题",
    "# `$StaleMinutes  = 8              # 超过多少分钟没数据就提示",
    "# `$ShowTop       = `$false        # 不显示热销前三",
    "# `$ShowYday      = `$false        # 不显示昨日全天",
    "# `$ShowPeer      = `$false        # 不显示商圈同行",
    "# `$AutoUpdate    = `$false        # 关闭自动更新",
    "# `$BarOn = '■'; `$BarOff = '□'    # 进度条显示成方框时改用这两个字符",
    "# `$GoalIncome = 1250              # 今日美团收入目标（元）；0 = 不显示目标行",
    "# `$GoalOrders = 62                # 今日订单量目标（单）",
    "# `$GoalNote   = '10月日均收入 920'  # 目标行的悬停说明",
    "# `$Plan = @{ '2026-11-24' = '今天要做的一件事'; '2026-11-25' = @('要做的事', '悬停显示的细节') }",
    "# `$PlanDayStart = 5               # 凌晨几点前仍算前一天"
  )
  try { [IO.File]::WriteAllText($SettingsFile, ($tpl -join "`r`n"), (New-Object System.Text.UTF8Encoding($true))) } catch { }
}
try { . $SettingsFile } catch { }
# 文件名「美团今日经营-关键字.ps1」→ 只显示店名含关键字的门店
$MyName = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
if ($MyName -match '^美团今日经营-(.+)$') { $ShopFilter = $Matches[1] }

$DashUrl = 'https://waimaie.meituan.com/#https://waimaieapp.meituan.com/igate/bizdata/home'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Latin1 = [System.Text.Encoding]::GetEncoding(28591)
try { [Console]::OutputEncoding = $Utf8 } catch { }
$Base = $env:LOCALAPPDATA
if (-not $Base) { $Base = Join-Path $HOME '.local/share' }
$ShopDir = Join-Path $Base 'MeituanDesk\shops'
if ($env:MTDESK_SHOPDIR) { $ShopDir = $env:MTDESK_SHOPDIR }
[void](New-Item -ItemType Directory -Force -Path $ShopDir)

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

# 今日任务（设置.ps1 里的 $Plan）
function Plan-Line {
  if ($null -eq $Plan -or $Plan.Count -eq 0) { return $null }
  $day = (Get-Date).AddHours(-[double]$PlanDayStart).ToString('yyyy-MM-dd')
  $v = $Plan[$day]
  if ($null -eq $v) { return $null }
  $text = ''; $tip = ''
  if ($v -is [array]) { $text = [string]$v[0]; if ($v.Count -gt 1) { $tip = [string]$v[1] } } else { $text = [string]$v }
  if (-not $text) { return $null }
  $line = '今日：' + (Clean $text) + ' | icon=📌 color=orange'
  if ($tip) { $line += " tooltip='$(Clean $tip)'" }
  return $line
}

# 今日目标（设置.ps1 里的 $GoalIncome / $GoalOrders）
function Goal-Line($inc, $ord) {
  $gi = [double]$GoalIncome; $go = [double]$GoalOrders
  if ($gi -le 0 -and $go -le 0) { return $null }
  $parts = @()
  $done = $true
  if ($gi -gt 0) {
    $iv = 0.0
    if (Has $inc) { $iv = [double]$inc.value }
    $ratio = $iv / $gi
    $t = '收入 ' + [math]::Floor($ratio * 100).ToString('0') + '%  ' + (Bar $ratio 1)
    if ($iv -lt $gi) { $t += '  还差 ¥' + ($gi - $iv).ToString('N0'); $done = $false } else { $t += '  已达成' }
    $parts += $t
  }
  if ($go -gt 0) {
    $ov = 0.0
    if (Has $ord) { $ov = [double]$ord.value }
    if ($ov -lt $go) { $done = $false }
    $parts += '单量 ' + $ov.ToString('N0') + '/' + $go.ToString('N0')
  }
  $tip = '今日目标：'
  if ($gi -gt 0) { $tip += '收入 ' + (Money $gi) + ' ' }
  if ($go -gt 0) { $tip += '单量 ' + (Int $go) + ' 单' }
  if ($GoalNote) { $tip += '；' + $GoalNote }
  $icon = '🎯'; $color = ''
  if ($done) { $icon = '✅'; $color = ' color=green' }
  return '目　标　' + ($parts -join ' · ') + " | icon=$icon$color tooltip='$(Clean $tip)'"
}


# ---------- 门店数据（多个栅栏共享同一个文件夹） ----------
function Safe-Id([string]$id) { if (-not $id) { return 'default' }; return ($id -replace '[^\w\-]', '_') }

function Save-Shop($obj) {
  $file = Join-Path $ShopDir ((Safe-Id $obj.shop.id) + '.json')
  [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $obj -Depth 10 -Compress), $Utf8)
}

function Load-Shop([string]$id) {
  $file = Join-Path $ShopDir ((Safe-Id $id) + '.json')
  if (-not (Test-Path $file)) { return $null }
  try { return ([IO.File]::ReadAllText($file, $Utf8) | ConvertFrom-Json) } catch { return $null }
}

function Load-AllShops {
  $list = New-Object System.Collections.ArrayList
  foreach ($f in (Get-ChildItem $ShopDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
    try { $o = [IO.File]::ReadAllText($f.FullName, $Utf8) | ConvertFrom-Json } catch { continue }
    if (-not $o -or -not $o.shop) { continue }
    if ($ShopFilter) {
      $hay = [string]$o.shop.name + ' ' + [string]$o.shop.id
      if ($hay.IndexOf($ShopFilter, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
    }
    [void]$list.Add($o)
  }
  return , @($list | Sort-Object { [string]$_.shop.name })
}

function Set-Prop($o, [string]$name, $value) { $o | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }

# 合并扩展推送来的一条消息
function Merge-Payload($p) {
  if (-not $p.shop) { Set-Prop $p 'shop' ([pscustomobject]@{ id = 'default'; name = $null }) }
  if (-not $p.shop.id) { Set-Prop $p.shop 'id' 'default' }
  $old = Load-Shop $p.shop.id
  if (($p.status -eq 'login' -or $p.status -eq 'paused') -and -not $p.rt) {
    if (-not $old) { $old = [pscustomobject]@{ shop = $p.shop } }
    Set-Prop $old 'status' $p.status
    Set-Prop $old 'statusAt' $p.statusAt
    Set-Prop $old 'resumeAt' $p.resumeAt
    if ($p.shop.name) { Set-Prop $old.shop 'name' $p.shop.name }
    Save-Shop $old
    return
  }
  if ($old -and -not $p.peer -and $old.peer) { Set-Prop $p 'peer' $old.peer }
  if ($old -and -not $p.shop.name -and $old.shop.name) { Set-Prop $p.shop 'name' $old.shop.name }
  if (-not $p.status) { Set-Prop $p 'status' 'ok' }
  Save-Shop $p
  # 读到真实门店后，删掉首次安装时「未知门店」的占位记录
  if ($p.shop.id -ne 'default') { Remove-Item (Join-Path $ShopDir 'default.json') -Force -ErrorAction SilentlyContinue }
}


# ---------- 画栅栏 ----------
function Shop-Title($d, [bool]$single) {
  $n = $d.shop.name
  if ($single -and $TitleOverride) { $n = $TitleOverride }
  if (-not $n) { $n = '门店 ' + $d.shop.id }
  return (Clean $n)
}

function Status-Line($d) {
  $now = [DateTimeOffset]::Now
  $recv = $null
  if ($d.receivedAt) { $recv = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$d.receivedAt).ToLocalTime() }
  $mins = 99999
  if ($recv) { $mins = [int][math]::Floor(($now - $recv).TotalMinutes) }
  $mt = ''
  if ($d.updateText) { $mt = ' · 美团 ' + (Clean $d.updateText) + ' 更新' }
  if ($d.status -eq 'paused') {
    $when = ''
    if ($recv) { $when = '（数据截至 ' + $recv.ToString('HH:mm') + '）' }
    if ($d.pauseReason) { return (Clean $d.pauseReason) + "，每 15 分钟看一次是否开始营业$when | icon=🌙 color=gray tooltip='营业状态读取自美团商家中心顶部；可在 Edge 扩展弹窗里修改'" }
    $r = ''
    if ($d.resumeAt) { $r = '，' + (Clean $d.resumeAt) + ' 恢复' }
    return "不在设定的营业时间段，暂停读取$r$when | icon=🌙 color=gray tooltip='可在 Edge 扩展弹窗里修改营业时间'"
  }
  if ($d.status -eq 'login') { return "美团登录已失效，点此在 Edge 里重新登录 | icon=🔴 color=red href=$DashUrl" }
  if (-not $recv) { if (-not (Test-EdgeRunning)) { return (Edge-Row) }; return '等待数据… | icon=⏳ color=gray' }
  if ($recv.Date -ne $now.Date) {
    return '这是 ' + $recv.ToString('M月d日 HH:mm') + " 的数据，今天还没同步 | icon=🟠 color=orange href=$DashUrl tooltip='请打开 Edge 让扩展同步'"
  }
  if ($mins -ge $StaleMinutes) {
    if (-not (Test-EdgeRunning)) { return (Edge-Row) }
    return "已 $mins 分钟没有同步$mt | icon=🟠 color=orange href=$DashUrl tooltip='请确认 Edge 在运行（关掉窗口后可在后台运行），扩展开启了自动同步'"
  }
  $agoTxt = '刚刚'
  if ($mins -ge 1) { $agoTxt = "$mins 分钟前" }
  return '同步于 ' + $recv.ToString('HH:mm') + "（$agoTxt）$mt | icon=🟢 color=gray href=$DashUrl tooltip='点击打开美团经营数据'"
}

function Find-Edge {
  try {
    $reg = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction Stop).'(default)'
    if ($reg -and (Test-Path $reg)) { return $reg }
  } catch { }
  foreach ($c in @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")) { if (Test-Path $c) { return $c } }
  return 'msedge.exe'
}
function Test-EdgeRunning { return [bool](Get-Process -Name msedge -ErrorAction SilentlyContinue) }
function Edge-Row { return "Edge 没在运行，点此在后台启动 | icon=🟠 color=orange run='$(Find-Edge)' param1=--no-startup-window tooltip='扩展需要 Edge 在运行（不用开窗口）。建议在 edge://settings/system 开启「关闭后继续运行后台扩展和应用」'" }

function Peer-Text($pr, $peerRate) {
  if (-not $ShowPeer -or $null -eq $pr -or $null -eq $peerRate) { return '' }
  $mark = '≈'
  if ($null -ne $pr.now) {
    if ($pr.now - $peerRate -gt 0.0005) { $mark = '高于' } elseif ($peerRate - $pr.now -gt 0.0005) { $mark = '低于' } else { $mark = '持平' }
  }
  return "· $($mark)同行 " + (Pct $peerRate)
}

function Shop-Lines($d, [bool]$single) {
  $L = New-Object System.Collections.Generic.List[string]
  $title = Shop-Title $d $single
  $L.Add("$title | icon=🛵 color=orange href=$DashUrl tooltip='门店 ID：$(Clean $d.shop.id)；看板 v$AppVersion$(Clean $script:UpdateNote)；点击打开美团经营数据'")
  $rt = $d.rt
  if (-not $rt) { $L.Add((Status-Line $d)); return $L }

  $paid = $rt.paid; $inc = $rt.income; $ord = $rt.orders
  $exp = $rt.exposure; $vis = $rt.visitors; $buy = $rt.buyers
  $avg = Ratio $paid.value $ord.value
  $avgPrev = Ratio (Prev $paid) (Prev $ord)
  $entry = Ratio $vis.value $exp.value
  $conv = Ratio $buy.value $vis.value
  $entryPrev = Ratio (Prev $vis) (Prev $exp)
  $convPrev = Ratio (Prev $buy) (Prev $vis)
  $pe = $null; $po = $null; $pdate = ''
  if ($d.peer) {
    if ($d.peer.entry) { $pe = $d.peer.entry.peer }
    if ($d.peer.order) { $po = $d.peer.order.peer }
    if ($d.peer.date) { $pdate = Clean $d.peer.date }
  }
  $tipPeer = ''
  if ($pdate) { $tipPeer = "；商圈同行均值（$pdate）" }

  if ($single) {
    $L.Add('---')
    $avgTxt = ''
    if ($null -ne $avg -and $null -ne $avgPrev) { $avgTxt = '昨同时段 ' + (Money $avgPrev) }
    $L.Add((Join2 ('营业额　' + (Money $paid.value)) (Delta $paid -IsMoney)) + " | icon=💰 tooltip='订单实付：顾客实际支付合计；箭头为比昨日同时段'")
    $L.Add((Join2 ('收　入　' + (Money $inc.value)) (Delta $inc -IsMoney)) + " | icon=💵 tooltip='预计订单收入：扣除平台服务费、配送费和活动补贴后的商家收入'")
    $L.Add((Join2 ('订单量　' + (IntU $ord.value '单')) (Delta $ord)) + ' | icon=🧾')
    $L.Add((Join2 ('客单价　' + (Money $avg)) $avgTxt) + " | icon=🧮 tooltip='客单价 = 订单实付 ÷ 订单量'")
    $gl = Goal-Line $inc $ord
    if ($gl) { $L.Add($gl) }
    $L.Add('---')
    $L.Add((Join2 ('曝光量　' + (IntU $exp.value '人')) (Delta $exp)) + ' | icon=👀')
    $tipE = '入店 ' + (Int $vis.value) + ' 人 ÷ 曝光 ' + (Int $exp.value) + ' 人'
    if ($null -ne $entryPrev) { $tipE += '；昨日同时段 ' + (Pct $entryPrev) }
    if ($null -ne $pe) { $tipE += $tipPeer + ' ' + (Pct $pe) }
    $L.Add('进店转化  ' + (Pct $entry) + '  ' + (Bar $entry $EntryBarMax) + '  ' + (PtChange $entry $entryPrev) + ' ' + (Peer-Text @{ now = $entry } $pe) + " | icon=🚪 tooltip='$(Clean $tipE)'")
    $tipC = '下单 ' + (Int $buy.value) + ' 人 ÷ 入店 ' + (Int $vis.value) + ' 人'
    if ($null -ne $convPrev) { $tipC += '；昨日同时段 ' + (Pct $convPrev) }
    if ($null -ne $po) { $tipC += $tipPeer + ' ' + (Pct $po) }
    $L.Add('下单转化  ' + (Pct $conv) + '  ' + (Bar $conv $OrderBarMax) + '  ' + (PtChange $conv $convPrev) + ' ' + (Peer-Text @{ now = $conv } $po) + " | icon=🛒 tooltip='$(Clean $tipC)'")

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
    if ($ShowYday -and $d.yday -and $null -ne $d.yday.paid) {
      $y = $d.yday
      $L.Add('---')
      $tip = '日期 ' + (Clean $y.date) + '；收入 ' + (Money $y.income) + '；优惠前 ' + (Money $y.gross) + '；补贴及支出 ' + (Money $y.subsidy)
      $L.Add('昨日全天  ' + (Money $y.paid) + ' · ' + (Int $y.orders) + ' 单 · 客单 ' + (Money $y.avg) + " | icon=📅 color=gray tooltip='$(Clean $tip)'")
    }
    $L.Add('---')
  } else {
    $tip1 = '营业额（订单实付）' + (Delta $paid -IsMoney) + '；收入 ' + (Money $inc.value) + ' ' + (Delta $inc -IsMoney) + '；订单 ' + (Delta $ord)
    $L.Add((Money $paid.value) + ' · ' + (IntU $ord.value '单') + ' · 客单 ' + (Money $avg) + "   $(Delta $paid -IsMoney) | icon=💰 tooltip='$(Clean $tip1)'")
    $L.Add('收入 ' + (Money $inc.value) + ' · 曝光 ' + (Int $exp.value) + " | icon=💵 tooltip='曝光 $(Delta $exp)'")
    $pt = ''
    if ($ShowPeer -and ($null -ne $pe -or $null -ne $po)) { $pt = '（同行 ' + (Pct $pe) + ' / ' + (Pct $po) + '）' }
    $L.Add('进店 ' + (Pct $entry) + ' · 下单 ' + (Pct $conv) + " $pt | icon=🚪 tooltip='进店转化 / 下单转化$tipPeer'")
  }
  $L.Add((Status-Line $d))
  return $L
}

function Build-Screen {
  $L = New-Object System.Collections.Generic.List[string]
  $L.Add('~~~')
  $pl = Plan-Line
  if ($pl) { $L.Add($pl); $L.Add('---') }
  $shops = Load-AllShops
  if ($shops.Count -eq 0) {
    $t = '美团外卖 · 今日实时'
    if ($TitleOverride) { $t = Clean $TitleOverride }
    $L.Add("$t | icon=🛵 color=orange href=$DashUrl")
    $L.Add('---')
    if ($ShopFilter) { $L.Add("还没有店名包含「$(Clean $ShopFilter)」的门店数据 | icon=⏳ color=gray") }
    else { $L.Add("等待 Edge 扩展推送数据… | icon=⏳ color=gray tooltip='请确认 Edge 在运行、扩展已安装并开启自动同步'") }
    if (-not $script:IsReceiver) { $L.Add("端口 $Port 已被占用，本栅栏只读取共享数据 | icon=🔌 color=gray") }
    return $L
  }
  # 栅栏已更新、但 Edge 扩展还在跑旧版本（自动重新加载没生效）→ 提示手动重新加载
  $updatedAt = [DateTimeOffset]::new((Get-Item $PSCommandPath).LastWriteTimeUtc).ToUnixTimeMilliseconds()
  foreach ($d in $shops) {
    if ($d.ext -and $d.receivedAt -and [int64]$d.receivedAt -gt $updatedAt + 180000) {
      try { $old = [version]$d.ext -lt [version]$AppVersion } catch { $old = $false }
      if ($old) {
        $L.Add("Edge 扩展还是旧版 v$(Clean $d.ext)，请打开 edge://extensions 点它的「重新加载」 | icon=🧩 color=orange tooltip='栅栏已自动更新到 v$AppVersion，扩展没有自动重新加载'")
        $L.Add('---')
        break
      }
    }
  }
  $single = ($shops.Count -eq 1)
  $first = $true
  foreach ($d in $shops) {
    if (-not $first) { $L.Add('---') }
    $first = $false
    foreach ($x in (Shop-Lines $d $single)) { $L.Add($x) }
  }
  return $L
}

function Render { foreach ($line in (Build-Screen)) { Write-Output $line } }

# ---------- 极简本机 HTTP ----------
function Send-Resp($stream, [int]$code, [string]$body, [string]$origin) {
  $reason = @{ 200 = 'OK'; 204 = 'No Content'; 400 = 'Bad Request'; 403 = 'Forbidden'; 404 = 'Not Found' }[$code]
  $b = $Utf8.GetBytes($body)
  $h = "HTTP/1.1 $code $reason`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($b.Length)`r`nConnection: close`r`n"
  if ($origin) {
    $h += "Access-Control-Allow-Origin: $origin`r`nAccess-Control-Allow-Methods: GET, POST, OPTIONS`r`nAccess-Control-Allow-Headers: Content-Type, X-Mt-Dash`r`n"
  }
  $hb = $Latin1.GetBytes($h + "`r`n")
  $stream.Write($hb, 0, $hb.Length)
  if ($b.Length) { $stream.Write($b, 0, $b.Length) }
  $stream.Flush()
}

# 处理一个请求；收到新数据返回 $true
function Handle-Client($client) {
  $client.ReceiveTimeout = 3000
  $client.SendTimeout = 3000
  $stream = $client.GetStream()
  $buf = New-Object byte[] 16384
  $ms = New-Object System.IO.MemoryStream
  $headEnd = -1
  while ($headEnd -lt 0 -and $ms.Length -lt 65536) {
    $n = $stream.Read($buf, 0, $buf.Length)
    if ($n -le 0) { break }
    $ms.Write($buf, 0, $n)
    $headEnd = $Latin1.GetString($ms.ToArray()).IndexOf("`r`n`r`n")
  }
  if ($headEnd -lt 0) { return $false }
  $all = $ms.ToArray()
  $lines = $Latin1.GetString($all, 0, $headEnd) -split "`r`n"
  $first = $lines[0].Split(' ')
  $method = $first[0]; $path = $first[1]
  $hdr = @{}
  foreach ($l in $lines) {
    $i = $l.IndexOf(':')
    if ($i -gt 0 -and $l -notmatch '^[A-Z]+ /') { $hdr[$l.Substring(0, $i).Trim().ToLower()] = $l.Substring($i + 1).Trim() }
  }
  $origin = $hdr['origin']
  $extOrigin = $null
  if ($origin) {
    if ($origin -match '^(chrome|edge)-extension://') { $extOrigin = $origin }
    else { Send-Resp $stream 403 '{"ok":false}' $null; return $false }
  }
  if ($method -eq 'OPTIONS') { Send-Resp $stream 204 '' $extOrigin; return $false }
  if (-not $hdr.ContainsKey('x-mt-dash')) { Send-Resp $stream 403 '{"ok":false}' $null; return $false }
  if ($method -eq 'GET' -and $path -like '/ping*') { Send-Resp $stream 200 '{"ok":true,"app":"pecofence-meituan","v":2}' $extOrigin; return $false }
  if ($method -eq 'POST' -and $path -like '/update*') {
    $len = 0
    [void][int]::TryParse([string]$hdr['content-length'], [ref]$len)
    if ($len -le 0 -or $len -gt 1MB) { Send-Resp $stream 400 '{"ok":false}' $extOrigin; return $false }
    $start = $headEnd + 4
    while (($ms.Length - $start) -lt $len) {
      $n = $stream.Read($buf, 0, $buf.Length)
      if ($n -le 0) { break }
      $ms.Write($buf, 0, $n)
    }
    $all = $ms.ToArray()
    if (($all.Length - $start) -lt $len) { Send-Resp $stream 400 '{"ok":false}' $extOrigin; return $false }
    $body = $Utf8.GetString($all, $start, $len)
    try { $obj = ConvertFrom-Json -InputObject $body } catch { Send-Resp $stream 400 '{"ok":false}' $extOrigin; return $false }
    try { Merge-Payload $obj } catch { Send-Resp $stream 400 '{"ok":false}' $extOrigin; return $false }
    Send-Resp $stream 200 '{"ok":true}' $extOrigin
    return $true
  }
  Send-Resp $stream 404 '{"ok":false}' $extOrigin
  return $false
}

# ---------- 自动更新（只由负责接收的那个栅栏执行） ----------
$script:UpdateNote = ''
$script:NeedRestart = $false
$Root = Split-Path $PSScriptRoot -Parent
function Get-RemoteVersion {
  $hdr = @{ 'User-Agent' = 'meituan-pecofence' }
  foreach ($u in @("https://raw.githubusercontent.com/$UpdateRepo/main/edge-extension/manifest.json",
                   "https://api.github.com/repos/$UpdateRepo/contents/edge-extension/manifest.json?ref=main")) {
    try {
      $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 25 -Headers $hdr
      $o = $r.Content | ConvertFrom-Json
      if ($o.content) { $o = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($o.content -replace '\s', ''))) | ConvertFrom-Json }
      if ($o.version) { return [version]$o.version }
    } catch { }
  }
  return $null
}
function Check-Update {
  if (-not $AutoUpdate -or $UpdateRepo -notmatch '^[\w.-]+/[\w.-]+$') { return }
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
  $remote = Get-RemoteVersion
  if (-not $remote) { $script:UpdateNote = '（检查更新失败，可能连不上 GitHub）'; return }
  if ($remote -le [version]$AppVersion) { $script:UpdateNote = '（已是最新）'; return }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mtdesk-' + [guid]::NewGuid().ToString('N'))
  try {
    [void](New-Item -ItemType Directory -Path $tmp -Force)
    $zip = Join-Path $tmp 'main.zip'
    Invoke-WebRequest -Uri "https://github.com/$UpdateRepo/archive/refs/heads/main.zip" -OutFile $zip -UseBasicParsing -TimeoutSec 120 -Headers @{ 'User-Agent' = 'meituan-pecofence' }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem $tmp -Directory | Select-Object -First 1
    $newExt = Join-Path $src.FullName 'edge-extension'
    $newFence = Join-Path (Join-Path $src.FullName 'pecofence') '美团今日经营.ps1'
    if (-not (Test-Path (Join-Path $newExt 'manifest.json')) -or -not (Test-Path $newFence)) { throw '下载的更新包不完整' }
    # 先更新栅栏脚本（包括所有「美团今日经营*.ps1」副本），最后更新扩展：扩展发现版本变化后会自动重新加载
    foreach ($f in (Get-ChildItem $PSScriptRoot -Filter '美团今日经营*.ps1')) { Copy-Item $newFence $f.FullName -Force }
    $extDir = Join-Path $Root 'edge-extension'
    if (Test-Path (Join-Path $extDir 'manifest.json')) {
      Copy-Item (Join-Path $newExt '*') $extDir -Recurse -Force
      $script:UpdateNote = "（已更新到 v$remote）"
    } else { $script:UpdateNote = '（扩展文件夹不在栅栏脚本旁边，扩展需要手动更新）' }
    $script:NeedRestart = $true
  } catch {
    $script:UpdateNote = '（更新失败：' + $_.Exception.Message + '）'
  } finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# ---------- 主循环 ----------
# 第一个启动的栅栏负责接收数据；其余栅栏只读共享文件夹。接收者关掉后，其他栅栏会自动接手。
$script:Listener = $null
$script:IsReceiver = $false
function Try-Listen {
  if ($script:IsReceiver) { return }
  try {
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    $l.Start()
    $script:Listener = $l
    $script:IsReceiver = $true
  } catch { $script:IsReceiver = $false }
}
function Dir-Stamp {
  $s = 0
  foreach ($f in (Get-ChildItem $ShopDir -Filter '*.json' -ErrorAction SilentlyContinue)) { $s = $s -bxor $f.LastWriteTimeUtc.Ticks }
  return $s
}

Try-Listen
Render
$lastRender = Get-Date
$myStamp = (Get-Item $PSCommandPath).LastWriteTimeUtc
$nextUpdate = (Get-Date).AddSeconds(20)
if ($env:MTDESK_UPDATE_DELAY) { $nextUpdate = (Get-Date).AddSeconds([int]$env:MTDESK_UPDATE_DELAY) }
$lastListenTry = Get-Date
$stamp = Dir-Stamp
while ($true) {
  if ($script:IsReceiver -and $script:Listener.Pending()) {
    $c = $script:Listener.AcceptTcpClient()
    try { [void](Handle-Client $c) } catch { } finally { $c.Close() }
    continue
  }
  if (-not $script:IsReceiver -and ((Get-Date) - $lastListenTry).TotalSeconds -ge 15) { Try-Listen; $lastListenTry = Get-Date }
  if ($script:IsReceiver -and (Get-Date) -ge $nextUpdate) {
    Check-Update
    $nextUpdate = (Get-Date).AddHours(6)
  }
  # 脚本文件被更新了 → 退出，PecoFence 会用新版本重新启动
  if ($script:NeedRestart -or (Get-Item $PSCommandPath).LastWriteTimeUtc -ne $myStamp) {
    Write-Output '~~~'
    Write-Output "美团桌面看板已更新，正在重新启动… | icon=🔄 color=gray tooltip='PecoFence 会自动重新运行新版本'"
    try { if ($script:Listener) { $script:Listener.Stop() } } catch { }
    exit 0
  }
  $s2 = Dir-Stamp
  if ($s2 -ne $stamp -or ((Get-Date) - $lastRender).TotalSeconds -ge 30) {
    $stamp = $s2
    Render
    $lastRender = Get-Date
  }
  Start-Sleep -Milliseconds 400
}
