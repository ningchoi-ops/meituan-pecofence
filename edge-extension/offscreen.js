const frame = document.getElementById('f');
chrome.runtime.onMessage.addListener((m, sender, sendResponse) => {
  if (!m || m.target !== 'offscreen') return;
  if (m.type === 'load') {
    frame.src = 'about:blank';
    setTimeout(() => { frame.src = m.url; }, 100);
  } else if (m.type === 'unload') {
    frame.src = 'about:blank';
  }
  sendResponse({ ok: true });
});
