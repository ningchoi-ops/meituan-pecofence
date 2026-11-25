// 后台：定时在「看不见的后台文档」里加载美团经营数据页，把读到的数据推送到本机 PecoFence 栅栏。
// 营业状态自动读取（页面顶部的「营业中 / 休息中」），休息时降低检查频率；
// 读取或推送失败时用 Windows 通知提醒你手动处理。
const DASH_URL = 'https://waimaie.meituan.com/#https://waimaieapp.meituan.com/igate/bizdata/home';
const CLOSED_CHECK_MIN = 15; // 休息中时，多少分钟检查一次是否开始营业
const DEFAULTS = {
  enabled: true, intervalMin: 2, port: 17890,
  mode: 'hidden',             // hidden（完全隐藏，默认）| window（最小化小窗口，只有你手动选才会用）
  hoursMode: 'auto',          // auto（跟随美团营业状态，默认）| manual（固定时间段）| off（一直刷新）
  open: '09:00', close: '02:00',
  peer: true,
  notify: true,
  alias: '',                  // 这个 Edge 配置文件对应的店铺名称（手动填写）；留空 = 用美团页面上读到的店名
};
// 门店 ID：页面地址里的 wmPoiId 才算数。没有 ID、或多店账号汇总视图给的 -1 / 0 都不可信。
// 以前这些情况一律记成 'default'：多个 Edge 配置文件（多个账号）同时推送时，
// 全都写进栅栏的同一条 default 记录，互相覆盖 → 栅栏只剩一家店、没法切换，店名和数据也对不上。
const validPoi = (id) => /^\d+$/.test(String(id || '')) && Number(id) > 0;
// 每个 Edge 配置文件一个固定的随机编号（一个配置文件 = 一套 cookie = 一个账号），拿不到门店 ID 时用它区分
async function profileShopId() {
  const s = await chrome.storage.local.get('profileKey');
  let k = s.profileKey;
  if (!k) {
    k = (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2) + Date.now()).replace(/\W/g, '').slice(0, 10);
    await chrome.storage.local.set({ profileKey: k });
  }
  return 'edge-' + k;
}
const ownKey = (id) => validPoi(id) || /^edge-\w+$/.test(String(id || ''));
async function shopIdOf(raw) { return validPoi(raw) ? String(raw) : profileShopId(); }

// 旧版存下的 default / -1 记录改到本配置文件自己的编号下
async function migrateIds() {
  const st = await getState();
  const fb = await profileShopId();
  let moved = false;
  for (const k of ['last', 'names', 'peers', 'shopStatus']) {
    const m = st[k] || {};
    for (const id of Object.keys(m)) {
      if (ownKey(id)) continue;
      if (!(fb in m)) m[fb] = m[id];
      delete m[id]; moved = true;
    }
  }
  if (st.lastPoi && !ownKey(st.lastPoi)) { st.lastPoi = fb; moved = true; }
  if (moved) await chrome.storage.local.set({ st });
}

// 栅栏上显示的店名：优先用弹窗里手动填写的名称
const nameOf = (st, id, cfg) => ((cfg && cfg.alias) || '').trim() || st.names[id] || null;

async function getCfg() {
  const s = await chrome.storage.local.get('cfg');
  const raw = s.cfg || {};
  const cfg = { ...DEFAULTS, ...raw };
  if (cfg.mode !== 'window') cfg.mode = 'hidden';                 // 旧版的 auto 一律当作完全隐藏
  if (!raw.hoursMode && raw.hoursOn === true) cfg.hoursMode = 'manual'; // 旧版手动设置的营业时间
  if (!['auto', 'manual', 'off'].includes(cfg.hoursMode)) cfg.hoursMode = 'auto';
  return cfg;
}
async function getState() {
  const s = await chrome.storage.local.get('st');
  return {
    modeInUse: null, hiddenFails: 0, pushFails: 0, lastLoadAt: 0, lastOkAt: 0, lastPoi: null, nextRunAt: 0,
    names: {}, peers: {}, last: {}, shopStatus: {}, ...(s.st || {}),
  };
}
async function setState(patch) {
  const st = await getState();
  Object.assign(st, patch);
  await chrome.storage.local.set({ st });
  return st;
}

// 所有操作逐个排队执行，避免并发时重复开窗口、状态互相覆盖
let queue = Promise.resolve();
const serial = (fn) => { const p = queue.then(fn, fn); queue = p.catch(() => {}); return p; };

// ---------- 自动更新：栅栏脚本从 GitHub 下载新版覆盖文件后，这里发现版本变了就自动重新加载 ----------
async function checkDiskUpdate() {
  try {
    const r = await fetch(chrome.runtime.getURL('manifest.json') + '?t=' + Date.now(), { cache: 'no-store' });
    const m = await r.json();
    if (m.version && m.version !== chrome.runtime.getManifest().version) {
      await chrome.storage.local.set({ updatedFrom: chrome.runtime.getManifest().version });
      chrome.runtime.reload();
      return true;
    }
  } catch (e) { /* 文件正在被替换时可能读失败，下一轮再试 */ }
  return false;
}

// ---------- 定时 ----------
async function schedule() {
  const cfg = await getCfg();
  await chrome.alarms.clear('tick');
  chrome.alarms.create('tick', { periodInMinutes: Math.max(1, cfg.intervalMin), delayInMinutes: 0.1 });
}
chrome.runtime.onInstalled.addListener(() => serial(async () => { await migrateIds(); await cleanupLegacy(); await schedule(); }));
chrome.runtime.onStartup.addListener(() => serial(async () => { await migrateIds(); await cleanupLegacy(); await schedule(); }));
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name !== 'tick') return;
  serial(async () => { if (!(await checkDiskUpdate())) await tick(); });
});

// 旧版留下的固定标签页、重复的小窗口统统关掉
async function cleanupLegacy() {
  try {
    const tabs = await chrome.tabs.query({ url: 'https://waimaie.meituan.com/*' });
    for (const t of tabs) if (t.pinned && (t.url || '').includes('bizdata')) await chrome.tabs.remove(t.id).catch(() => {});
  } catch (e) {}
  if ((await getCfg()).mode !== 'window') await closeAllOwnWindows();
  else await findOwnWindow(true);
}

// ---------- 营业时间 ----------
const toMin = (s) => { const [h, m] = String(s || '0:0').split(':').map(Number); return (h || 0) * 60 + (m || 0); };
function inManualHours(cfg, d = new Date()) {
  const now = d.getHours() * 60 + d.getMinutes();
  const o = toMin(cfg.open), c = toMin(cfg.close);
  if (o === c) return true;
  return o < c ? (now >= o && now < c) : (now >= o || now < c); // 支持跨午夜，如 09:00–02:00
}
const isOpenStatus = (s) => !s || /营业中/.test(s);

// ---------- 通知 ----------
const NOTE = {
  login: { title: '美团登录已失效', message: '桌面看板读不到数据了。点这里打开美团商家中心重新登录。', every: 3600000 },
  read: { title: '美团数据读取失败', message: '后台打开了经营数据页，但没读到今日数据。点这里打开页面看看，必要时在扩展里改用「最小化小窗口」。', every: 7200000 },
  fence: { title: '桌面栅栏没在运行', message: '数据推送不出去。请打开 PecoFence，确认「美团今日经营」栅栏在运行。', every: 7200000 },
};
async function notify(kind) {
  const cfg = await getCfg();
  if (!cfg.notify) return;
  const { lastNotify = {} } = await chrome.storage.local.get('lastNotify');
  if (Date.now() - (lastNotify[kind] || 0) < NOTE[kind].every) return;
  lastNotify[kind] = Date.now();
  await chrome.storage.local.set({ lastNotify });
  try {
    await chrome.notifications.create('mt-' + kind, {
      type: 'basic', iconUrl: 'icons/128.png', title: NOTE[kind].title, message: NOTE[kind].message, priority: 2,
    });
  } catch (e) {}
}
async function clearNote(kind) {
  try { await chrome.notifications.clear('mt-' + kind); } catch (e) {}
  const { lastNotify = {} } = await chrome.storage.local.get('lastNotify');
  if (lastNotify[kind]) { delete lastNotify[kind]; await chrome.storage.local.set({ lastNotify }); }
}
chrome.notifications.onClicked.addListener((id) => {
  if (id === 'mt-login' || id === 'mt-read') chrome.tabs.create({ url: DASH_URL });
  chrome.notifications.clear(id);
});

// ---------- 两种加载方式 ----------
async function ensureFrameRules() {
  // 只对“不属于任何标签页”的请求（即后台文档）去掉禁止嵌入的响应头，不影响你正常浏览
  await chrome.declarativeNetRequest.updateSessionRules({
    removeRuleIds: [1],
    addRules: [{
      id: 1, priority: 1,
      action: { type: 'modifyHeaders', responseHeaders: [
        { header: 'x-frame-options', operation: 'remove' },
        { header: 'content-security-policy', operation: 'remove' },
        { header: 'content-security-policy-report-only', operation: 'remove' },
      ] },
      condition: { requestDomains: ['meituan.com'], resourceTypes: ['sub_frame'], tabIds: [chrome.tabs.TAB_ID_NONE] },
    }],
  });
}

async function loadHidden() {
  await ensureFrameRules();
  if (!(await chrome.offscreen.hasDocument())) {
    await chrome.offscreen.createDocument({
      url: 'offscreen.html', reasons: ['DOM_SCRAPING'], justification: '在后台读取美团商家中心经营数据',
    });
  }
  await chrome.runtime.sendMessage({ target: 'offscreen', type: 'load', url: DASH_URL });
}

async function closeHidden() {
  try { if (await chrome.offscreen.hasDocument()) await chrome.offscreen.closeDocument(); } catch (e) {}
}

// 找扩展自己开的窗口（记录过的窗口 ID，或只装着美团页面的弹出式窗口）；dedupe=true 时把多余的关掉
async function ownWindows() {
  const { ownWins = [] } = await chrome.storage.local.get('ownWins');
  let wins = [];
  try { wins = await chrome.windows.getAll({ populate: true }); } catch (e) { return []; }
  const isMt = (t) => /meituan\.com/.test(t.url || t.pendingUrl || '');
  return wins.filter((w) => ownWins.includes(w.id) ||
    (w.type === 'popup' && (w.tabs || []).length > 0 && (w.tabs || []).every(isMt)));
}

async function findOwnWindow(dedupe) {
  const ours = await ownWindows();
  const { winId } = await chrome.storage.local.get('winId');
  const keep = ours.find((w) => w.id === winId) || ours[0] || null;
  if (dedupe) for (const w of ours) if (!keep || w.id !== keep.id) await chrome.windows.remove(w.id).catch(() => {});
  await chrome.storage.local.set({ winId: keep ? keep.id : null, ownWins: keep ? [keep.id] : [] });
  return keep;
}

async function closeAllOwnWindows() {
  for (const w of await ownWindows()) await chrome.windows.remove(w.id).catch(() => {});
  await chrome.storage.local.set({ winId: null, ownWins: [] });
}

async function loadWindow() {
  const w = await findOwnWindow(true);
  if (w && w.tabs && w.tabs[0]) {
    const t = w.tabs[0];
    if ((t.url || '').includes('bizdata')) await chrome.tabs.reload(t.id);
    else await chrome.tabs.update(t.id, { url: DASH_URL });
    return;
  }
  const { winCreatedAt = 0 } = await chrome.storage.local.get('winCreatedAt');
  if (Date.now() - winCreatedAt < 180000) return; // 刚开过一个，还没认出来就先不开
  const nw = await chrome.windows.create({ url: DASH_URL, type: 'popup', state: 'minimized', focused: false });
  await chrome.storage.local.set({ winCreatedAt: Date.now(), ownWins: [nw.id], winId: nw.id });
  try { if (nw.state !== 'minimized') await chrome.windows.update(nw.id, { state: 'minimized' }); } catch (e) {}
  try { if (nw.tabs && nw.tabs[0]) await chrome.tabs.update(nw.tabs[0].id, { autoDiscardable: false, muted: true }); } catch (e) {}
}

// ---------- 每一轮 ----------
async function tick(force) {
  const cfg = await getCfg();
  if (!cfg.enabled && !force) return;
  let st = await getState();

  // 固定时间段模式：时间段外暂停
  if (cfg.hoursMode === 'manual' && !inManualHours(cfg) && !force) {
    await closeHidden(); await closeAllOwnWindows();
    for (const id of Object.keys(st.last)) await push({ v: 2, shop: { id, name: nameOf(st, id, cfg) }, status: 'paused', resumeAt: cfg.open, statusAt: Date.now() });
    await setState({ paused: true });
    return;
  }
  // 跟随营业状态：休息中时每 15 分钟才检查一次
  if (cfg.hoursMode === 'auto' && st.nextRunAt && Date.now() < st.nextRunAt && !force) return;

  // 上一轮用隐藏方式加载却没读到数据 → 记一次失败；连续 2 次就提醒
  if (st.modeInUse === 'hidden' && st.lastLoadAt && st.lastOkAt < st.lastLoadAt && !st.loginAt) {
    st = await setState({ hiddenFails: st.hiddenFails + 1 });
    if (st.hiddenFails >= 2) await notify('read');
  }
  const mode = cfg.mode === 'window' ? 'window' : 'hidden';
  try {
    if (mode === 'hidden') { await closeAllOwnWindows(); await loadHidden(); }
    else { await closeHidden(); await loadWindow(); }
    await setState({ modeInUse: mode, lastLoadAt: Date.now(), loginAt: 0, paused: false, lastError: '' });
  } catch (e) {
    await setState({ lastError: String(e && e.message || e) });
  }
}

// ---------- 推送到 PecoFence ----------
async function push(payload) {
  if (!payload) return false;
  const cfg = await getCfg();
  let ok = false;
  try {
    const r = await fetch(`http://127.0.0.1:${cfg.port}/update`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Mt-Dash': '1' },
      body: JSON.stringify(payload),
    });
    ok = r.ok;
  } catch (e) { ok = false; }
  const st = await getState();
  st.pushFails = ok ? 0 : (st.pushFails || 0) + 1;
  await chrome.storage.local.set({ st, fenceOk: ok, fenceAt: Date.now() });
  if (ok) await clearNote('fence');
  else if (st.pushFails >= 2) await notify('fence');
  return ok;
}

const ymd = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const yesterday = () => ymd(new Date(Date.now() - 86400000));
let shellInfo = {}; // 来源（标签页 id / 后台文档）→ 外壳页读到的 { name, status }
let srcPoi = {};    // 来源 → 最近读到的门店 ID

function payloadFor(st, id, cfg) {
  const d = st.last[id];
  if (!d) return null;
  const status = st.shopStatus[id] || null;
  const closed = cfg.hoursMode === 'auto' && !isOpenStatus(status);
  return {
    ...d, v: 2, ext: chrome.runtime.getManifest().version,
    shop: { id, name: nameOf(st, id, cfg), status }, peer: st.peers[id] || null,
    status: closed ? 'paused' : 'ok', pauseReason: closed ? `美团显示「${status}」` : null,
    statusAt: Date.now(),
  };
}

// 根据营业状态安排下一次读取
function planNext(st, cfg, id) {
  const closed = cfg.hoursMode === 'auto' && !isOpenStatus(st.shopStatus[id]);
  st.nextRunAt = closed ? Date.now() + CLOSED_CHECK_MIN * 60000 : 0;
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || !msg.type || msg.target === 'offscreen') return;
  serial(async () => {
    const cfg = await getCfg();
    const src = sender.tab ? 'tab' + sender.tab.id : 'hidden';
    if (msg.type === 'shopname') {
      shellInfo[src] = { name: msg.name, status: msg.status };
      const id = srcPoi[src];
      if (id) {
        const st = await getState();
        const changed = (msg.name && st.names[id] !== msg.name) || (msg.status && st.shopStatus[id] !== msg.status);
        if (msg.name) st.names[id] = msg.name;
        if (msg.status) st.shopStatus[id] = msg.status;
        planNext(st, cfg, id);
        await chrome.storage.local.set({ st });
        if (changed) await push(payloadFor(st, id, cfg));
      }
    } else if (msg.type === 'data') {
      const st = await getState();
      const id = await shopIdOf(msg.data.shop && msg.data.shop.id);
      srcPoi[src] = id;
      const info = shellInfo[src] || {};
      if (info.name) st.names[id] = info.name;
      if (info.status) st.shopStatus[id] = info.status;
      const { shop, ...rest } = msg.data;
      st.last[id] = { ...rest, receivedAt: Date.now() };
      Object.assign(st, { lastOkAt: Date.now(), lastPoi: id, hiddenFails: 0, loginAt: 0 });
      planNext(st, cfg, id);
      await chrome.storage.local.set({ st });
      await clearNote('login'); await clearNote('read');
      await push(payloadFor(st, id, cfg));
    } else if (msg.type === 'hello') {
      const st = await getState();
      const id = await shopIdOf(msg.shopId);
      const p = st.peers[id];
      sendResponse({ wantPeer: !!cfg.peer && (!p || p.date !== yesterday()) && (!p || Date.now() - (p.tryAt || 0) > 3600000) });
      if (cfg.peer) { st.peers[id] = { ...(p || {}), tryAt: Date.now() }; await chrome.storage.local.set({ st }); }
      return;
    } else if (msg.type === 'peer') {
      const st = await getState();
      const id = await shopIdOf(msg.shopId);
      st.peers[id] = { ...msg.peer, tryAt: Date.now() };
      await chrome.storage.local.set({ st });
      await push(payloadFor(st, id, cfg));
    } else if (msg.type === 'login') {
      const st = await setState({ loginAt: Date.now() });
      const id = st.lastPoi || await profileShopId();
      await push({ v: 2, shop: { id, name: nameOf(st, id, cfg) }, status: 'login', statusAt: Date.now() });
      await notify('login');
    } else if (msg.type === 'debug') {
      await chrome.storage.local.set({ lastDebug: { ...msg, at: Date.now() } });
    } else if (msg.type === 'refresh-now') {
      await setState({ nextRunAt: 0 });
      await tick(true);
    } else if (msg.type === 'cfg-changed') {
      await setState({ hiddenFails: 0, nextRunAt: 0 });
      if ((await getCfg()).mode !== 'window') await closeAllOwnWindows();
      await schedule();
    } else if (msg.type === 'resend') {
      const st = await getState();
      let ok = false;
      for (const id of Object.keys(st.last)) ok = (await push(payloadFor(st, id, cfg))) || ok;
      sendResponse({ ok });
      return;
    }
    sendResponse({ ok: true });
  });
  return true;
});
