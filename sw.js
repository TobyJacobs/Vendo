/* Vendo service worker: makes the site installable and keeps it working with a weak signal. */
const VERSION = "0.22.0"; // kept in step with RELEASES in index.html by release.sh
const CACHE = "vendo-" + VERSION;
const SHELL = ["./", "index.html", "manifest.webmanifest", "favicon.svg", "favicon.ico", "apple-touch-icon.png", "icon-192.png", "icon-512.png"];
const CDN = ["cdnjs.cloudflare.com", "fonts.googleapis.com", "fonts.gstatic.com"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  // Map tiles and anything else from other sites go straight to the network.
  if (url.origin !== location.origin && !CDN.includes(url.hostname)) return;
  if (req.mode === "navigate") {
    // Pages: try the network first so new releases show straight away, fall back to the saved copy offline.
    e.respondWith(fetch(req).then(res => {
      const copy = res.clone(); caches.open(CACHE).then(c => c.put("index.html", copy)); return res;
    }).catch(() => caches.match("index.html")));
    return;
  }
  // Everything else: serve the saved copy at once and refresh it in the background.
  e.respondWith(caches.match(req).then(hit => {
    const net = fetch(req).then(res => {
      if (res.ok || res.type === "opaque") { const copy = res.clone(); caches.open(CACHE).then(c => c.put(req, copy)); }
      return res;
    }).catch(() => hit);
    return hit || net;
  }));
});
