# 美团桌面看板（后台版）· 一键安装 + 登录 + 自检
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
. (Join-Path $src 'core.ps1')
Write-Host ''
Write-Host '美团桌面看板 · 一键安装' -ForegroundColor Cyan
Write-Host "安装位置：$($MT.Home)"
foreach ($f in @('core.ps1', 'scrape.js', '美团今日经营.ps1', '登录美团.ps1')) {
  Copy-Item (Join-Path $src $f) (Join-Path $MT.Home $f) -Force
  try { Unblock-File (Join-Path $MT.Home $f) } catch { }
}
Write-Host '文件已复制。' -ForegroundColor Green
Write-Host ''
& (Join-Path $MT.Home '登录美团.ps1') -Report
$fence = Join-Path $MT.Home '美团今日经营.ps1'
Write-Host ''
Write-Host '最后一步：PecoFence 托盘菜单 → 新建小工具 → 用自己的脚本…，选这个文件：' -ForegroundColor Cyan
Write-Host "  $fence" -ForegroundColor White
try { Start-Process explorer.exe "/select,`"$fence`"" } catch { }
