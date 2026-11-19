// Working-Bolt extension: loads the bundled wb.js (the same app the bookmark loads) into the Lightning Bolt
// tab's own page, so it reads with the session that page already has. It never sees or stores a password.
const LB = 'https://lblite.lightning-bolt.com/';

function openIn(tabId) {
  // wb.js shows itself again if it's already loaded in that tab, so re-running it is safe.
  return chrome.scripting.executeScript({ target: { tabId }, world: 'MAIN', files: ['wb.js'] }).catch(() => {});
}

chrome.runtime.onMessage.addListener((m, sender) => {
  if (m && m.open && sender.tab && sender.tab.id != null) openIn(sender.tab.id);
});

// Toolbar button: on a Lightning Bolt tab it opens Working-Bolt; anywhere else it opens Lightning Bolt.
chrome.action.onClicked.addListener(tab => {
  if (tab.url && tab.url.startsWith(LB)) openIn(tab.id);
  else chrome.tabs.create({ url: LB + 'dashboard/' });
});
