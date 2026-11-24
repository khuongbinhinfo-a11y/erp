/* Static application shell only; never cache business/API requests. */
const PREFIX = 'erp-static-';
const CACHE = PREFIX + '__VERSION__';
const ASSETS = __ASSETS__;
const ALLOW = new Set(ASSETS);
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(
    ASSETS.map(path => new Request(path, {cache:'reload', credentials:'omit'}))
  )));
  // No skipWaiting: open clients must not mix two different JS builds.
});
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(
    keys.filter(key => key.startsWith(PREFIX) && key !== CACHE).map(key => caches.delete(key))
  )));
});
self.addEventListener('fetch', event => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== self.location.origin ||
      request.headers.has('authorization') || url.search || url.pathname.startsWith('/v1/')) return;
  if (request.mode === 'navigate' && (url.pathname === '/' || url.pathname === '/index.html')) {
    event.respondWith(caches.open(CACHE).then(cache => cache.match('/index.html')).then(response => response || fetch(request)));
    return;
  }
  if (!ALLOW.has(url.pathname)) return;
  event.respondWith(caches.open(CACHE).then(cache => cache.match(url.pathname)).then(response => response || fetch(request)));
});
