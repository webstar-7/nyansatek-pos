const CACHE_NAME = 'nyansatek-pos-v2'; // bumped so every device picks up this fix on next visit
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

// Fetch: only handle same-origin GET requests for the app shell.
// Everything else (Supabase API calls, CDN scripts, etc.) goes straight to the network
// so your live sales/inventory data is never served from a stale cache.
self.addEventListener('fetch', event => {
  const req = event.request;
  const url = new URL(req.url);

  if (req.method !== 'GET' || url.origin !== self.location.origin) {
    return; // let the browser handle it normally
  }

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

      // For navigation requests (loading the page itself) specifically,
      // fall back to the cached app shell root if this exact URL was
      // never cached -- handles the case where the browser requests
      // "/index.html" but only "/" (or vice versa) got precached.
      if (!cached && req.mode === 'navigate') {
        return network.catch(() => caches.match('./'));
      }

      return cached || network;
    })
  );
});
