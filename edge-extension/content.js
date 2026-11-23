// 运行在美团商家中心的每个 frame 里（包括扩展后台文档里隐藏加载的页面）。
// 只读取页面上显示的文字；读「商圈同行」时会点一下页面里的「流量」标签。
(() => {
  if (window.__mtDeskLoaded) return;
  window.__mtDeskLoaded = true;

  // ---------- 小工具 ----------
  const NUM_RE = /-?\d[\d,]*(?:\.\d+)?/;
  const squash = (s) => (s || '').replace(/\s+/g, '');
  // innerText 中 "52" 与 ".20" 可能被拆成两行，先拼回去
  const normText = (s) => (s || '').replace(/(\d)\s+\.(\d)/g, '$1.$2').replace(/ /g, ' ');
  const toNum = (s) => {
    if (s == null) return null;
    const n = parseFloat(String(s).replace(/,/g, ''));
    return Number.isFinite(n) ? n : null;
  };
  const visible = (el) => !!(el && el.getClientRects && el.getClientRects().length);
  const ownText = (el) => {
    let t = '';
    for (const n of el.childNodes) if (n.nodeType === 3) t += n.nodeValue;
    return squash(t);
  };

  // 找出文字恰好等于 label 的元素（取最深的那层）
  function findLabelEls(root, label) {
    const out = [];
    const w = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    let n;
    while ((n = w.nextNode())) {
      if (n.tagName === 'SCRIPT' || n.tagName === 'STYLE') continue;
      if (ownText(n) === label || (squash(n.textContent) === label && n.children.length === 0)) {
        if (visible(n)) out.push(n);
      }
    }
    return out;
  }

  // 从标题文字向上找到包含 mustInclude 全部文字的最小容器
  function findScope(title, mustInclude) {
    const heads = findLabelEls(document.body, title);
    for (const h of heads) {
      let el = h;
      for (let i = 0; i < 12 && el.parentElement; i++) {
        el = el.parentElement;
        const t = squash(el.innerText);
        if (mustInclude.every((k) => t.includes(k))) return el;
      }
    }
    return null;
  }

  // 根据颜色/箭头/类名判断涨跌（美团：红色↑涨，绿色↓跌）
  function trendNear(card, deltaStr) {
    const target = squash(deltaStr);
    const cands = [...card.querySelectorAll('*')].filter((e) => ownText(e).includes(target));
    for (const e of cands) {
      const ctx = squash((e.parentElement || e).innerText);
      if (/持平/.test(ctx)) return 'flat';
      if (/[↑▲]/.test(ctx)) return 'up';
      if (/[↓▼]/.test(ctx)) return 'down';
      const m = getComputedStyle(e).color.match(/\d+/g);
      if (m) {
        const [r, g] = m.map(Number);
        if (g - r > 40) return 'down';
        if (r - g > 40) return 'up';
      }
      const html = ((e.parentElement || e).innerHTML || '').toLowerCase();
      if (/(arrow-?down|icon-?down|decline|decrease|descend|\bdown\b)/.test(html)) return 'down';
      if (/(arrow-?up|icon-?up|increase|ascend|rise)/.test(html)) return 'up';
    }
    return null;
  }

  // 在 scope 里读取一组指标卡片
  function readMetrics(scope, labelMap) {
    const labels = Object.values(labelMap);
    const result = {};
    for (const [key, label] of Object.entries(labelMap)) {
      const els = findLabelEls(scope, label);
      for (const lab of els) {
        let el = lab, best = null;
        for (let i = 0; i < 6 && el.parentElement && el !== scope; i++) {
          el = el.parentElement;
          const t = normText(el.innerText);
          const flat = squash(t);
          // 越过了别的指标卡片就停
          if (labels.some((l) => l !== label && flat.includes(l))) break;
          const after = t.slice(t.indexOf(label) + label.length);
          const m = after.match(NUM_RE);
          if (m) best = { el, after };
        }
        if (!best) continue;
        const value = toNum(best.after.match(NUM_RE)[0]);
        const dm = best.after.match(/(?:比昨日同时段|比昨日|比前日|较昨日|较前日)\s*[↑↓▲▼+]?\s*(-?[\d,]+(?:\.\d+)?%?|--|持平)/);
        let delta = null, trend = null;
        if (dm) {
          if (dm[1] === '持平') { delta = 0; trend = 'flat'; }
          else if (dm[1] !== '--') {
            delta = toNum(dm[1]);
            trend = delta === 0 ? 'flat' : trendNear(best.el, dm[1]);
            if (delta < 0) { trend = 'down'; delta = -delta; }
          }
        }
        result[key] = { value, delta, trend };
        break;
      }
    }
    return result;
  }

  // 实时销售榜前几名
  function readTop(limit = 3) {
    const scope = findScope('实时销售榜', ['排名', '销量']);
    if (!scope) return [];
    const rows = [...scope.querySelectorAll('tr')].filter((r) => r.querySelectorAll('td').length >= 4);
    const out = [];
    for (const r of rows) {
      const td = r.querySelectorAll('td');
      const rank = toNum((td[0].innerText.match(/\d+/) || [])[0]);
      const nameEl = td[1].querySelector('[title]');
      const name = ((nameEl && nameEl.getAttribute('title')) || td[1].innerText || '').replace(/\s+/g, '');
      const sales = toNum((normText(td[2].innerText).match(NUM_RE) || [])[0]);
      const qty = toNum((normText(td[3].innerText).match(NUM_RE) || [])[0]);
      if (name) out.push({ rank: rank || out.length + 1, name, sales, qty });
      if (out.length >= limit) break;
    }
    return out;
  }

  function scrape() {
    const rtScope = findScope('今日实时数据', ['预计订单收入', '下单人数']);
    if (!rtScope) return null;
    const rt = readMetrics(rtScope, {
      income: '预计订单收入',
      orders: '订单量',
      paid: '订单实付',
      exposure: '曝光人数',
      visitors: '入店人数',
      buyers: '下单人数',
    });
    if (rt.paid == null && rt.income == null) return null;
    const upd = squash(rtScope.innerText).match(/(\d{1,2}-\d{1,2})(\d{1,2}:\d{2})更新/);

    let yday = null;
    const hScope = findScope('历史收益概览', ['订单收入', '实付单均价']);
    if (hScope) {
      const h = readMetrics(hScope, {
        income: '订单收入', gross: '优惠前总额', subsidy: '补贴及支出',
        paid: '订单实付', avg: '实付单均价', orders: '订单量',
      });
      const dm = squash(hScope.innerText).match(/已选时间[:：](\d{4}-\d{2}-\d{2})/) ||
                 squash(document.body.innerText).match(/已选时间[:：](\d{4}-\d{2}-\d{2})/);
      yday = { date: dm ? dm[1] : null };
      for (const [k, v] of Object.entries(h)) yday[k] = v.value;
    }

    return {
      v: 1,
      status: 'ok',
      updateText: upd ? `${upd[1]} ${upd[2]}` : null,
      rt,
      top: readTop(3),
      yday,
      shop: { id: new URLSearchParams(location.search).get('wmPoiId') || null },
    };
  }


  function looksLikeLogin() {
    if (/logon|login|passport|account\/unitivelogin/i.test(location.href)) return true;
    const t = squash(document.body && document.body.innerText).slice(0, 3000);
    return /(账号登录|扫码登录|短信登录|验证码登录)/.test(t) && /(密码|手机号)/.test(t);
  }

  // ---------- 外壳页：读店名 ----------
  const isShell = location.hostname === 'waimaie.meituan.com' && !/bizdata/.test(location.pathname + location.search);
  // 读顶部的店名和营业状态，返回 { name, status }
  const STATUSES = ['营业中', '休息中', '暂停营业', '已打烊', '停止营业', '已下线', '未营业'];
  function readShopInfo() {
    for (const st of STATUSES) {
      for (const el of findLabelEls(document.body, st)) {
        let p = el;
        for (let i = 0; i < 4 && p.parentElement; i++) {
          p = p.parentElement;
          const t = (p.innerText || '').trim();
          const idx = t.indexOf(st);
          if (idx <= 0) continue;
          const before = t.slice(0, idx).trim().split('\n').pop().trim();
          if (before.length >= 2 && before.length <= 40 && !/商家中心|美团外卖/.test(before)) return { name: before, status: st };
        }
        return { name: null, status: st };
      }
    }
    return null;
  }

  // ---------- 流量页：商圈同行 ----------
  function readRates(scope, label, other) {
    const vals = [];
    for (const el of findLabelEls(scope, label)) {
      let p = el;
      for (let i = 0; i < 4 && p.parentElement; i++) {
        p = p.parentElement;
        const t = normText(p.innerText);
        if (t.includes(other) || /比前日|比昨日/.test(t)) break;
        const m = t.match(/(\d+(?:\.\d+)?)\s*%/);
        if (m) { vals.push({ v: parseFloat(m[1]) / 100, x: el.getBoundingClientRect().left }); break; }
      }
    }
    vals.sort((a, b) => a.x - b.x);
    return vals.length >= 2 ? { mine: vals[0].v, peer: vals[vals.length - 1].v } : null;
  }

  function clickTab(name) {
    const el = findLabelEls(document.body, name).find((e) => {
      let p = e;
      for (let i = 0; i < 4 && p.parentElement; i++) { p = p.parentElement; const t = squash(p.innerText); if (t.includes('总览') && t.includes('营收')) return true; }
      return false;
    });
    if (el) { el.click(); return true; }
    return false;
  }

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  async function scrapePeer() {
    if (!clickTab('流量')) return null;
    for (let i = 0; i < 25; i++) {
      await sleep(800);
      const scope = findScope('流量转化', ['入店转化率', '下单转化率']);
      if (!scope || !squash(scope.innerText).includes('同行')) continue;
      const entry = readRates(scope, '入店转化率', '下单转化率');
      const order = readRates(scope, '下单转化率', '入店转化率');
      if (!entry && !order) continue;
      const dm = squash(document.body.innerText).match(/已选时间[:：](\d{4}-\d{2}-\d{2})/);
      return { date: dm ? dm[1] : null, entry, order };
    }
    return null;
  }

  // ---------- 调度 ----------
  let lastSig = '';
  let lastRun = 0;
  let debugSent = false;
  let loginSent = false;
  let nameSent = '';
  let peerState = 'unknown'; // unknown | want | busy | done
  const startedAt = Date.now();

  function send(msg) {
    try { return chrome.runtime.sendMessage(msg).catch(() => null); } catch (e) { return Promise.resolve(null); }
  }

  async function maybePeer(shopId) {
    if (peerState !== 'unknown') return;
    peerState = 'busy';
    const r = await send({ type: 'hello', shopId });
    if (!r || !r.wantPeer) { peerState = 'done'; return; }
    const peer = await scrapePeer().catch(() => null);
    peerState = 'done';
    if (peer) send({ type: 'peer', shopId, peer });
  }

  function run() {
    lastRun = Date.now();
    if (!document.body) return;
    if (isShell) {
      const n = readShopInfo();
      const sig = n ? n.name + '|' + n.status : '';
      if (n && sig !== nameSent) { nameSent = sig; send({ type: 'shopname', name: n.name, status: n.status }); }
    }
    if (peerState === 'busy') return;
    let data = null;
    try { data = scrape(); } catch (e) { /* 页面结构变化时忽略 */ }
    if (data) {
      const sig = JSON.stringify([data.rt, data.top, data.yday, data.updateText]);
      if (sig !== lastSig) { lastSig = sig; send({ type: 'data', data }); }
      maybePeer(data.shop.id);
      return;
    }
    if (!loginSent && looksLikeLogin()) {
      loginSent = true;
      send({ type: 'login', url: location.origin + location.pathname });
      return;
    }
    if (!debugSent && /bizdata/.test(location.href) && Date.now() - startedAt > 40000) {
      debugSent = true;
      send({ type: 'debug', url: location.origin + location.pathname, text: normText(document.body.innerText).slice(0, 5000) });
    }
  }

  const mo = new MutationObserver(() => { if (Date.now() - lastRun > 1500) run(); });
  const start = () => {
    mo.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
    run();
  };
  setInterval(run, 5000);
  chrome.runtime.onMessage.addListener((m) => {
    if (m && m.type === 'scrape-now') { lastSig = ''; run(); }
  });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
