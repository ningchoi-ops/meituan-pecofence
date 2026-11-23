const DASH_URL = 'https://waimaie.meituan.com/#https://waimaieapp.meituan.com/igate/bizdata/home';
const DEFAULTS = { enabled: true, intervalMin: 2, port: 17890, mode: 'hidden', hoursMode: 'auto', open: '09:00', close: '02:00', peer: true, notify: true };
const $ = (id) => document.getElementById(id);
let curShop = null;

function toast(t) { const el = $('toast'); el.textContent = t; el.classList.add('show'); setTimeout(() => el.classList.remove('show'), 1600); }
function pill(id, cls, text) { const p = $(id); p.className = 'pill ' + cls; p.lastElementChild.textContent = text; }
const fmtMoney = (v) => v == null ? '—' : '¥' + v.toLocaleString('zh-CN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const fmtInt = (v) => v == null ? '—' : v.toLocaleString('zh-CN');
const fmtPct = (v) => v == null ? '—' : (v * 100).toFixed(2) + '%';
const ago = (ts) => { const m = Math.round((Date.now() - ts) / 60000); return m < 1 ? '刚刚' : m < 60 ? `${m} 分钟前` : `${Math.round(m / 60)} 小时前`; };
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function deltaHtml(m, money) {
  if (!m || m.delta == null) return '';
  const v = money ? m.delta.toFixed(2) : fmtInt(m.delta);
  if (m.trend === 'up') return `<span class="d up">▲ ${v}</span>`;
  if (m.trend === 'down') return `<span class="d down">▼ ${v}</span>`;
  if (m.trend === 'flat') return `<span class="d">持平</span>`;
  return `<span class="d">Δ ${v}</span>`;
}

function render(st) {
  const ids = Object.keys(st.last || {});
  const g = $('grid');
  $('shops').innerHTML = ids.length > 1 ? ids.map((id) => `<button data-id="${esc(id)}" class="${id === curShop ? 'on' : ''}">${esc((st.names || {})[id] || id)}</button>`).join('') : '';
  $('shops').querySelectorAll('button').forEach((b) => b.onclick = () => { curShop = b.dataset.id; render(st); });
  if (!curShop || !ids.includes(curShop)) curShop = st.lastPoi && ids.includes(st.lastPoi) ? st.lastPoi : ids[0];
  const last = curShop ? st.last[curShop] : null;
  if (!last || !last.rt) { g.innerHTML = '<div class="kpi" style="grid-column:span 2"><div class="k">还没有数据</div><div class="d">点「立即刷新」，扩展会在后台读取经营数据页</div></div>'; $('meta').textContent = ''; return; }
  const r = last.rt, peer = (st.peers || {})[curShop] || {};
  const paid = r.paid?.value, orders = r.orders?.value;
  const exp = r.exposure?.value, vis = r.visitors?.value, buy = r.buyers?.value;
  const pe = peer.entry ? `<div class="p">同行 ${fmtPct(peer.entry.peer)}</div>` : '';
  const po = peer.order ? `<div class="p">同行 ${fmtPct(peer.order.peer)}</div>` : '';
  const cards = [
    ['营业额（订单实付）', fmtMoney(paid), deltaHtml(r.paid, true)],
    ['收入（预计订单收入）', fmtMoney(r.income?.value), deltaHtml(r.income, true)],
    ['订单量', fmtInt(orders), deltaHtml(r.orders)],
    ['客单价', orders ? fmtMoney(paid / orders) : '—', ''],
    ['曝光人数', fmtInt(exp), deltaHtml(r.exposure)],
    ['进店转化率', exp ? fmtPct(vis / exp) : '—', pe || `<span class="d">入店 ${fmtInt(vis)}</span>`],
    ['下单转化率', vis ? fmtPct(buy / vis) : '—', po || `<span class="d">下单 ${fmtInt(buy)}</span>`],
  ];
  g.innerHTML = cards.map(([k, v, d]) => `<div class="kpi"><div class="k">${k}</div><div class="v">${v}</div>${d || '<div class="d">&nbsp;</div>'}</div>`).join('');
  $('meta').textContent = `美团 ${last.updateText || '—'} 更新 · 读取于 ${ago(last.receivedAt)}` + (peer.date ? ` · 同行数据 ${peer.date}` : '');
}

async function pingFence(port) {
  try {
    const r = await fetch(`http://127.0.0.1:${port}/ping`, { headers: { 'X-Mt-Dash': '1' } });
    pill('pFence', r.ok ? 'ok' : 'bad', r.ok ? '已连接' : '异常');
  } catch (e) { pill('pFence', 'bad', '未运行'); }
}

async function load() {
  const s = await chrome.storage.local.get(['cfg', 'st', 'lastDebug']);
  const raw = s.cfg || {};
  const cfg = { ...DEFAULTS, ...raw };
  if (!raw.hoursMode && raw.hoursOn === true) cfg.hoursMode = 'manual';
  const st = s.st || { last: {} };
  $('enabled').checked = cfg.enabled;
  $('interval').value = String(cfg.intervalMin);
  $('mode').value = cfg.mode === 'window' ? 'window' : 'hidden';
  $('hoursMode').value = cfg.hoursMode;
  $('open').value = cfg.open; $('close').value = cfg.close;
  $('hoursRow').style.display = cfg.hoursMode === 'manual' ? '' : 'none';
  $('notify').checked = cfg.notify;
  const status = (st.shopStatus || {})[st.lastPoi] || null;
  if (!status) pill('pShop', '', '—');
  else if (/营业中/.test(status)) pill('pShop', 'ok', status);
  else pill('pShop', 'warn', status + (cfg.hoursMode === 'auto' && st.nextRunAt ? '，' + new Date(st.nextRunAt).toTimeString().slice(0, 5) + ' 再看' : ''));
  $('peer').checked = cfg.peer;
  $('port').value = cfg.port;
  render(st);
  const fresh = st.lastOkAt && Date.now() - st.lastOkAt < cfg.intervalMin * 60000 * 3;
  if (st.paused) pill('pPage', 'warn', '时间段外暂停');
  else if (st.loginAt) pill('pPage', 'bad', '需重新登录');
  else if (fresh) pill('pPage', 'ok', '读取正常');
  else if (s.lastDebug || st.lastError) pill('pPage', 'warn', '读不到数据');
  else pill('pPage', 'warn', '等待中');
  if (cfg.mode === 'window') pill('pMode', 'warn', '最小化小窗口');
  else if (st.hiddenFails >= 2) pill('pMode', 'bad', '隐藏读取失败：请点「复制调试信息」发给开发者');
  else pill('pMode', 'ok', '完全隐藏');
  pingFence(cfg.port);
}

async function saveCfg() {
  const cfg = {
    ...DEFAULTS, enabled: $('enabled').checked, intervalMin: Number($('interval').value), port: Number($('port').value) || 17890,
    mode: $('mode').value, hoursMode: $('hoursMode').value, open: $('open').value || '09:00', close: $('close').value || '02:00', peer: $('peer').checked, notify: $('notify').checked,
  };
  await chrome.storage.local.set({ cfg });
  await chrome.runtime.sendMessage({ type: 'cfg-changed' });
  toast('已保存');
  load();
}

for (const id of ['enabled', 'interval', 'mode', 'hoursMode', 'open', 'close', 'peer', 'notify', 'port']) $(id).onchange = saveCfg;
$('refresh').onclick = async () => { await chrome.runtime.sendMessage({ type: 'refresh-now' }); toast('已在后台刷新，约 10 秒后更新'); };
$('open2').onclick = () => chrome.tabs.create({ url: DASH_URL });
$('resend').onclick = async () => { const r = await chrome.runtime.sendMessage({ type: 'resend' }); toast(r && r.ok ? '已推送到桌面' : '推送失败：栅栏没在运行？'); load(); };
$('debug').onclick = async () => {
  const s = await chrome.storage.local.get(['st', 'lastDebug', 'cfg']);
  const text = JSON.stringify({ ua: navigator.userAgent, ...s }, null, 2);
  await navigator.clipboard.writeText(text);
  toast('调试信息已复制');
};

chrome.storage.onChanged.addListener((c) => { if (c.st) load(); });
document.getElementById('sub').textContent = '后台隐藏读取 → PecoFence · v' + chrome.runtime.getManifest().version;
load();
