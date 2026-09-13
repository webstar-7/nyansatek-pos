const CACHE_NAME = 'nyansatek-pos-v3'; // bumped: navigation is now network-first (see below)
const APP_SHELL = [
  './',              // the actual page, whatever it's served as (index.html) — was './pos.html', which doesn't exist and broke install entirely
  './manifest.json',
  './icon-192.png',
  './icon-512.png'
];

// Install: pre-cache the app shell. Each resource is fetched and cached
// individually (instead of one cache.addAll call) so that if any single
// item is missing or renamed later, it doesn't take down the whole
// install the way a single 404 did here -- that's what silently kept
// this service worker from ever registering at all.
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache =>
      Promise.all(
        APP_SHELL.map(url =>
          fetch(url)
            .then(res => {
              if (res && res.ok) return cache.put(url, res);
              console.warn('[sw] Skipping precache, bad response for', url, res && res.status);
            })
            .catch(err => console.warn('[sw] Skipping precache, fetch failed for', url, err))
        )
      )
    )
  );
  self.skipWaiting();
});

// Activate: clean up old caches
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
    )
  );
  self.clients.claim();
});

// Fetch: only handle same-origin GET requests. Everything else
// (Supabase API calls, CDN scripts, etc.) goes straight to the network
// so your live sales/inventory data is never served from a stale cache.
self.addEventListener('fetch', event => {
  const req = event.request;
  const url = new URL(req.url);

  if (req.method !== 'GET' || url.origin !== self.location.origin) {
    return; // let the browser handle it normally
  }

  // Navigation requests (loading the page itself) are NETWORK-FIRST.
  // This is an actively-developed app -- every reload while online
  // should show the latest deployed version immediately, not whatever
  // was cached before the last deploy. Falls back to the cached shell
  // only when the network request genuinely fails (i.e. offline).
  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req)
        .then(res => {
          if (res && res.ok) {
            const clone = res.clone();
            caches.open(CACHE_NAME).then(cache => cache.put(req, clone));
          }
          return res;
        })
        .catch(() => caches.match(req).then(cached => cached || caches.match('./')))
    );
    return;
  }

  // Everything else (icons, manifest, etc.) keeps the faster
  // cache-first-with-background-revalidation strategy -- these rarely
  // change, so serving the cached copy immediately is the right trade.
  event.respondWith(
    caches.match(req).then(cached => {
      const network = fetch(req)
        .then(res => {
          if (res && res.status === 200) {
            const clone = res.clone();
            caches.open(CACHE_NAME).then(cache => cache.put(req, clone));
          }
          return res;
        })
        .catch(() => cached); // offline fallback

      return cached || network;
    })
  );
});
