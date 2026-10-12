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

   - Milestone badges: the badge font, the picker thumbnails and all four
     full-size backgrounds are saved when the app is installed/first opened
     online, so badges can be made offline after that.
   - Milestone notifications (opt-in, on-device only): where the browser
     supports Periodic Background Sync (Chrome/Edge on Android with the app
     installed), it wakes this worker about once a day to check for a
     milestone day ON THE PHONE and show a private notification ("Front Porch
     / Something worth celebrating is waiting for you on the porch." unless
     the person chose to show their milestone). No server is involved and
     nothing is sent anywhere. The start date it reads is a device-only copy
     in IndexedDB ('fpr-local' → 'notify'), present only while notifications
     are on.

   If you ever change this file, bump CACHE_VERSION so old copies are
   cleared out. */
const CACHE_VERSION = 'v6';
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
  './favicon-32.png',
  './cinzel-700.woff',
  './badge-proud-victory-thumb.jpg',
  './badge-keep-going-thumb.jpg',
  './badge-built-this-recovery-thumb.jpg',
  './badge-showing-up-thumb.jpg',
  './badge-proud-victory.jpg',
  './badge-keep-going.jpg',
  './badge-built-this-recovery.jpg',
  './badge-showing-up.jpg'
];
const BADGE_CACHE = 'fpr-badges-' + CACHE_VERSION;
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
        keys.filter((k) => k.startsWith('fpr-') && ![CORE_CACHE, FONT_CACHE, BADGE_CACHE].includes(k))
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

/* Full-size badge backgrounds: saved the first time they're used. */
async function badgeImageResponse(request) {
  const cache = await caches.open(BADGE_CACHE);
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
    } else if (/^\.\/badge-[a-z-]+\.jpg$/.test(name)) {
      event.respondWith(badgeImageResponse(request));
    }
    return;
  }
  if (url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com') {
    event.respondWith(fontResponse(request));
  }
  // Anything else is left alone and goes to the network normally.
});

/* ---------- Milestone notifications ----------
   Same milestone rules as the page (FPRMilestones in index.html): badge
   milestones are 30/60/90 days, 6/9/18 months, then every year. A month or
   year milestone is reached on the same day-of-month (or the 1st of the
   next month when that day doesn't exist), matching the counter. */
const BADGE_MILESTONES = [
  { unit: 'day', n: 30 }, { unit: 'day', n: 60 }, { unit: 'day', n: 90 },
  { unit: 'month', n: 6 }, { unit: 'month', n: 9 }, { unit: 'month', n: 18 }
];
const PRIVATE_TEXT = { title: 'Front Porch', body: 'Something worth celebrating is waiting for you on the porch.' };

// --- tiny IndexedDB helper (same database the page uses) ---
function idb() {
  return new Promise((resolve) => {
    try {
      const req = indexedDB.open('fpr-local', 1);
      req.onupgradeneeded = () => { req.result.createObjectStore('kv'); };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => resolve(null);
    } catch (e) { resolve(null); }
  });
}
async function kv(mode, fn) {
  const db = await idb(); if (!db) return null;
  return new Promise((resolve) => {
    try {
      const t = db.transaction('kv', mode); const r = fn(t.objectStore('kv'));
      t.oncomplete = () => resolve(r && 'result' in r ? r.result : null);
      t.onerror = t.onabort = () => resolve(null);
    } catch (e) { resolve(null); }
  });
}
const kvGet = (k) => kv('readonly', (s) => s.get(k));
const kvSet = (k, v) => kv('readwrite', (s) => s.put(v, k));

function swUTC(d) { return Date.UTC(d.y, d.m - 1, d.d); }
function swMilestoneDate(start, ms) {
  if (ms.unit === 'day') {
    const t = new Date(swUTC(start) + ms.n * 86400000);
    return { y: t.getUTCFullYear(), m: t.getUTCMonth() + 1, d: t.getUTCDate() };
  }
  const months = ms.unit === 'year' ? ms.n * 12 : ms.n;
  let y = start.y, m = start.m + months;
  y += Math.floor((m - 1) / 12); m = ((m - 1) % 12) + 1;
  const dim = new Date(Date.UTC(y, m, 0)).getUTCDate();
  if (start.d <= dim) return { y, m, d: start.d };
  m += 1; if (m > 12) { m = 1; y += 1; }
  return { y, m, d: 1 };
}
function swLabel(ms) {
  const one = ms.n === 1;
  const word = ms.unit === 'day' ? (one ? 'Day' : 'Days') : ms.unit === 'month' ? (one ? 'Month' : 'Months') : (one ? 'Year' : 'Years');
  return ms.n + ' ' + word;
}
function swParseStart(str) {
  const p = String(str || '').split('-').map(Number);
  return p.length === 3 && p[0] ? { y: p[0], m: p[1], d: p[2] } : null;
}
function swList(start, now) {
  const list = BADGE_MILESTONES.slice();
  for (let n = 1; n <= now.getFullYear() - start.y + 2; n++) list.push({ unit: 'year', n });
  return list;
}
// Milestone reached today (or yesterday, if delivery ran late) that hasn't been notified yet.
function swMilestoneNow(state, now) {
  const start = swParseStart(state && state.start);
  if (!start) return null;
  const today = { y: now.getFullYear(), m: now.getMonth() + 1, d: now.getDate() };
  for (const ms of swList(start, now)) {
    const daysSince = Math.round((swUTC(today) - swUTC(swMilestoneDate(start, ms))) / 86400000);
    if (daysSince < 0 || daysSince > 1) continue;
    const key = state.start + '|' + ms.unit + ':' + ms.n;
    if (state.notified && state.notified[key]) continue;
    return { ms, key };
  }
  return null;
}
function notifOptions(body) {
  return { body, icon: 'icon-192.png', badge: 'favicon-32.png', tag: 'fpr-milestone', data: { url: './#home' } };
}
/* Background milestone check (Periodic Background Sync, where supported). */
async function checkMilestonesLocally() {
  const state = await kvGet('notify');
  if (!state || !state.enabled) return;
  const hit = swMilestoneNow(state, new Date());
  if (!hit) return;
  const text = state.privacy === 'detailed'
    ? { title: 'Front Porch', body: 'You reached ' + swLabel(hit.ms) + '. That matters.' } : PRIVATE_TEXT;
  await self.registration.showNotification(text.title, notifOptions(text.body));
  state.notified = Object.assign({}, state.notified, { [hit.key]: true });
  await kvSet('notify', state);
}
self.addEventListener('periodicsync', (event) => {
  if (event.tag === 'fpr-milestone-check') event.waitUntil(checkMilestonesLocally());
});

/* Tapping a notification opens (or focuses) the app on the home page. The
   app recalculates the milestone itself and shows the celebration. */
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = new URL('./#home', self.registration.scope).href;
  event.waitUntil((async () => {
    await kvSet('notifyTap', Date.now());   // lets the app skip "Maybe later" for this tap
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const w of wins) {
      if (w.url.startsWith(self.registration.scope)) {
        try { await w.focus(); w.postMessage({ type: 'fpr-milestone-open' }); return; } catch (e) {}
      }
    }
    await self.clients.openWindow(target);
  })());
});
