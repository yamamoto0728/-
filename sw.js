self.addEventListener('install', () => { self.skipWaiting(); });
self.addEventListener('activate', (e) => { e.waitUntil(self.clients.claim()); });

// アプリのアイコンの数字（2026-10-10、多摩キャン版）。通知に badge:true が付いていたら1つ増やす。
// 数は Cache Storage に入れておき、アプリを開くと本当の未読の数で上書きする（tama/index.html の setAppBadgeCount）
const BADGE_CACHE = 'chikaku-badge', BADGE_KEY = '/__badge';
async function bumpBadge() {
  if (!self.navigator || !('setAppBadge' in self.navigator)) return;
  try {
    const c = await caches.open(BADGE_CACHE);
    const r = await c.match(BADGE_KEY);
    const n = (r ? parseInt(await r.text(), 10) || 0 : 0) + 1;
    await c.put(BADGE_KEY, new Response(String(n)));
    await self.navigator.setAppBadge(n);
  } catch (e) {}
}

self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) { data = { title: 'ちかく', body: event.data ? event.data.text() : '' }; }
  const title = data.title || 'マッチしました！';
  const options = {
    body: data.body || '新しいマッチがあります。アプリを開いて確認しましょう。',
    icon: 'icons/icon-192.png',
    badge: 'icons/icon-192.png',
    data: { url: data.url || './index.html' },
    tag: data.tag || 'chikaku-match',
    renotify: true
  };
  // iPhone は通知を出さないと通知の許可を取り消すことがあるので、数字の更新が失敗しても通知は必ず出す
  event.waitUntil(Promise.all([
    self.registration.showNotification(title, options),
    data.badge ? bumpBadge() : Promise.resolve()
  ]));
});

// 通知を押した時（2026-10-10 に変更）：
//   前は、アプリを一度開いたことがあると、その画面を前に出すだけで、トークなど通知の中身の所には行かなかった。
//   いまは、同じ版（/tama/ など）の画面が開いていれば前に出して、開く所（url）を postMessage で伝える（アプリが受け取って移動する）。
//   開いていなければ url を新しく開く。url はこのサイトの中だけ（よそのページは開かない）
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  let target;
  try {
    target = new URL((event.notification.data && event.notification.data.url) || './index.html', self.location.origin);
    if (target.origin !== self.location.origin) target = new URL('/', self.location.origin);
  } catch (e) { target = new URL('/', self.location.origin); }
  const dir = target.pathname.replace(/[^/]*$/, '');   // 「/tama/?go=…」なら「/tama/」
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clients) => {
      const same = clients.find((c) => { try { return new URL(c.url).pathname.startsWith(dir); } catch (e) { return false; } });
      if (same && 'focus' in same) {
        return same.focus().then((c) => { (c || same).postMessage({ type: 'push-open', url: target.href }); });
      }
      if (self.clients.openWindow) return self.clients.openWindow(target.href);
    })
  );
});
