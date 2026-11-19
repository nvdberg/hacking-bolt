// Working-Bolt extension, on Lightning Bolt pages only.
// - Opens Working-Bolt when you reach the dashboard signed in (where Lightning Bolt lands you), unless you
//   closed it in this tab.
// - Adds a small ⚡ Working-Bolt button (bottom right) to open it again after you close it, from any LB page.
// - Stays out of the way on the sign-in page and inside frames.
(() => {
  if (window.top !== window) return;
  const open = () => { try { chrome.runtime.sendMessage({ open: true }); } catch (e) {} };
  const signInPage = () => !!document.querySelector('input[type="password"]');

  const btn = document.createElement('button');
  btn.type = 'button';
  btn.textContent = '⚡ Working-Bolt';
  btn.title = 'Open Working-Bolt';
  btn.style.cssText = 'all:initial;position:fixed;right:18px;bottom:18px;z-index:2147482000;cursor:pointer;' +
    'font:600 13px/1 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;color:#fff;background:#0A1216;' +
    'padding:10px 14px;border-radius:999px;box-shadow:0 2px 10px rgba(0,0,0,.25);';
  btn.addEventListener('click', open);

  let tries = 0, asked = false;
  const tick = () => {
    if (!btn.isConnected && document.body) document.body.appendChild(btn);
    btn.style.display = signInPage() ? 'none' : '';
    // Remember (per tab) when you close Working-Bolt, so it doesn't pop back up until you click ⚡ again.
    const wb = document.getElementById('working-bolt');
    try {
      if (wb && wb.style.display === 'none') sessionStorage.setItem('wb-ext-closed', '1');
      else if (wb) sessionStorage.removeItem('wb-ext-closed');
    } catch (e) {}
    let closed = false;
    try { closed = sessionStorage.getItem('wb-ext-closed') === '1'; } catch (e) {}
    if (!asked && !wb && !closed && /^\/dashboard/.test(location.pathname) && !signInPage()) { asked = true; open(); }
    if (++tries < 600) setTimeout(tick, 1000);   // Lightning Bolt changes pages without reloading; keep watching ~10 min
  };
  tick();
})();
