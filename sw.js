/* غيّر رقم النسخة عند كل رفع جديد ليصل التحديث للمستخدمين */
const VERSION = 'v1';
const CACHE = 'anwar-' + VERSION;
const SHELL = ['./', 'index.html', 'manifest.webmanifest', 'icons/icon-192.png', 'icons/icon-512.png'];

self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) { return c.addAll(SHELL); }).then(function () { return self.skipWaiting(); }));
});
self.addEventListener('activate', function (e) {
  e.waitUntil(
    caches.keys().then(function (ks) {
      return Promise.all(ks.filter(function (k) { return k.indexOf('anwar-') === 0 && k !== CACHE; }).map(function (k) { return caches.delete(k); }));
    }).then(function () { return self.clients.claim(); })
  );
});
self.addEventListener('fetch', function (e) {
  var r = e.request;
  if (r.method !== 'GET') return;
  var u = new URL(r.url);
  if (u.origin !== location.origin) return;            // لا نتدخل في Supabase ولا المكتبات الخارجية
  if (r.mode === 'navigate') {                          // الصفحة: الشبكة أولاً ثم النسخة المحفوظة عند انقطاع الإنترنت
    e.respondWith(
      fetch(r).then(function (res) {
        var cp = res.clone(); caches.open(CACHE).then(function (c) { c.put('index.html', cp); }); return res;
      }).catch(function () { return caches.match('index.html'); })
    );
    return;
  }
  e.respondWith(caches.match(r).then(function (hit) {
    return hit || fetch(r).then(function (res) {
      if (res.ok) { var cp = res.clone(); caches.open(CACHE).then(function (c) { c.put(r, cp); }); }
      return res;
    });
  }));
});
