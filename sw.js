/* Field Officer · Livestock Inspector – service worker
   - Caches only the app shell (page, manifest, icons) and the Supabase JS library, for fast start-up and offline opening.
   - NEVER caches or intercepts Supabase sign-in or database requests (*.supabase.co): they always go straight to the network,
     so login sessions and records are never stale.
   - The page itself is loaded network-first, so a new index.html uploaded to GitHub is picked up on the next online visit.
   Change VERSION whenever you change this file, the icons or manifest.json. */
const VERSION = 'v2';
const CACHE = 'field-officer-' + VERSION;
const LIB = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.119.0';
const SHELL = [
  './',
  './index.html',
  './manifest.json',
  './icons/icon.svg',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/maskable-192.png',
  './icons/maskable-512.png',
  './icons/apple-touch-icon.png'
];

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    // add each file on its own so one missing icon cannot break installation
    await Promise.all(SHELL.map(url => cache.add(new Request(url, { cache: 'reload' })).catch(() => {})));
    try {
      const lib = await fetch(LIB, { mode: 'cors', cache: 'reload' });
      if (lib.ok) await cache.put(LIB, lib);
    } catch (e) { /* offline during install: the library is cached on first use instead */ }
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k.startsWith('field-officer-') && k !== CACHE).map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});

const isSupabase = url => /(^|\.)supabase\.(co|in|net)$/i.test(url.hostname);
const isAppPage = url => url.origin === self.location.origin &&
  (url.pathname.endsWith('/') || url.pathname.endsWith('/index.html'));

self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;                 // sign-in, saves and deletes: never touched
  const url = new URL(req.url);
  if (isSupabase(url)) return;                       // auth + database: always live network
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return;

  // 1) The app page: network first (fresh code), cached copy when offline
  if (req.mode === 'navigate') {
    event.respondWith((async () => {
      try {
        const res = await fetch(req);
        if (res.ok && isAppPage(url)) {
          const cache = await caches.open(CACHE);
          await cache.put('./index.html', res.clone());
        }
        return res;
      } catch (e) {
        return (await caches.match('./index.html')) || (await caches.match('./')) ||
          new Response('<h3 style="font-family:sans-serif;padding:20px">You are offline. Connect to the internet and open the app again.</h3>',
            { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8' } });
      }
    })());
    return;
  }

  // 2) Supabase JS library: serve cached copy instantly, refresh it in the background
  if (url.href === LIB) {
    event.respondWith((async () => {
      const cache = await caches.open(CACHE);
      const cached = await cache.match(LIB);
      const fresh = fetch(req).then(res => { if (res.ok || res.type === 'opaque') cache.put(LIB, res.clone()); return res; }).catch(() => null);
      if (cached) { event.waitUntil(fresh); return cached; }
      return (await fresh) || new Response('', { status: 503 });
    })());
    return;
  }

  // 3) Same-origin files (manifest, icons): cache first, then network
  if (url.origin === self.location.origin) {
    event.respondWith((async () => {
      const cached = await caches.match(req, { ignoreSearch: true });
      if (cached) return cached;
      try {
        const res = await fetch(req);
        if (res.ok) (await caches.open(CACHE)).put(req, res.clone());
        return res;
      } catch (e) {
        return new Response('', { status: 504 });
      }
    })());
  }
  // everything else (WhatsApp / SMS links, other sites) goes to the network untouched
});
