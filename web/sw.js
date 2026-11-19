// Working-Bolt web: shows the alerts the poller sends (stage2/webpush.mjs) — the same ones the apps get.
// No caching, no fetch handler: this worker only receives notifications.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Working-Bolt', {
    body: d.body || '',
    icon: 'apple-touch-icon.png',
    badge: 'icon.png',
    data: d.data || {},
  }));
});

// Clicking opens Lightning Bolt; the Working-Bolt bookmark then shows the shift.
self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(self.clients.openWindow('https://lblite.lightning-bolt.com/dashboard/'));
});
