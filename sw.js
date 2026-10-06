/* Front Porch Recovery — service worker
   Makes the site installable and lets it open without an internet
   connection. It stores a copy of the site's own public files on the
   device (no personal information) and nothing else.

   - The page itself is fetched fresh from the internet whenever possible,
     so every update you push to GitHub shows up the next time someone
     opens the app online. The saved copy is used only when the network
     is unavailable or very slow.
   - Icons and the app description file are served from the saved copy.
   - The site's font is saved after the first visit so the app still
     looks right offline.
   - Everything else (contact form, YouTube, Facebook, Etsy, Amazon, outside
     resources) goes straight to the internet and is never stored.

   If you ever change this file, bump CACHE_VERSION so old copies are
   cleared out. */
const CACHE_VERSION = 'v1';
const CORE_CACHE = 'fpr-core-' + CACHE_VERSION;
const FONT_CACHE = 'fpr-fonts-' + CACHE_VERSION;
const CORE_FILES = [
  './',
  './index.html',
  './manifest.webmanifest',
  './icon-192.png',
  './icon-512.png',
  './icon-maskable-512.png',
  './apple-touch-icon.png',
  './favicon-32.png'
];
const NETWORK_TIMEOUT_MS = 4000;

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CORE_CACHE)
      .then((cache) => cache.addAll(CORE_FILES.map((u) => new Request(u, { cache: 'reload' }))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys.filter((k) => k.startsWith('fpr-') && k !== CORE_CACHE && k !== FONT_CACHE)
            .map((k) => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

function isPageRequest(request, url) {
  return request.mode === 'navigate' ||
    (url.origin === self.location.origin && /\/(index\.html)?$/.test(url.pathname));
}

/* Network first for the page: fresh when online, saved copy when not. */
async function pageResponse(request) {
  const cache = await caches.open(CORE_CACHE);
  const network = fetch(request).then((res) => {
    if (res && res.ok) cache.put('./index.html', res.clone());
    return res;
  });
  network.catch(() => {}); // avoid an unhandled rejection if we already answered from the saved copy
  const timeout = new Promise((resolve) => setTimeout(resolve, NETWORK_TIMEOUT_MS, null));
  try {
    const res = await Promise.race([network, timeout]);
    if (res && res.ok) return res;
  } catch (err) { /* offline — fall through to the saved copy */ }
  const saved = await cache.match('./index.html');
  if (saved) return saved;
  return network; // nothing saved yet: let the browser show its normal error
}

/* Saved copy first for icons and the manifest. */
async function coreFileResponse(request) {
  const cache = await caches.open(CORE_CACHE);
  const saved = await cache.match(request, { ignoreSearch: true });
  if (saved) return saved;
  const res = await fetch(request);
  if (res && res.ok) cache.put(request, res.clone());
  return res;
}

/* Fonts: use the saved copy right away, refresh it in the background. */
async function fontResponse(request) {
  const cache = await caches.open(FONT_CACHE);
  const saved = await cache.match(request);
  const refresh = fetch(request).then((res) => {
    if (res && (res.ok || res.type === 'opaque')) cache.put(request, res.clone());
    return res;
  }).catch(() => saved);
  return saved || refresh;
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return; // contact form posts go straight to Formspree
  const url = new URL(request.url);

  if (isPageRequest(request, url)) {
    event.respondWith(pageResponse(request));
    return;
  }
  if (url.origin === self.location.origin) {
    const name = './' + url.pathname.split('/').pop();
    if (CORE_FILES.includes(name)) {
      event.respondWith(coreFileResponse(request));
    }
    return;
  }
  if (url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com') {
    event.respondWith(fontResponse(request));
  }
  // Anything else is left alone and goes to the network normally.
});
