// Offline shell for BrowTech Kumasi. Bump VERSION when index.html changes.
const VERSION = "browtech-v47";
const FILES = ["./", "./index.html", "./config.js", "./manifest.webmanifest", "./manifest-book.webmanifest", "./btk-icon-192.png", "./btk-icon-512.png", "./btk-apple-touch-icon.png"];
self.addEventListener("install", e => e.waitUntil(caches.open(VERSION).then(c => c.addAll(FILES.map(f => new Request(f, { cache: "reload" })))).then(() => self.skipWaiting())));
self.addEventListener("activate", e => e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== VERSION).map(k => caches.delete(k)))).then(() => self.clients.claim())));
self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET" || new URL(req.url).origin !== location.origin) return; // never touch database calls
  // network first so updates arrive (no-cache: GitHub Pages lets browsers keep files for 10 minutes); saved copy when offline
  e.respondWith(fetch(req, { cache: "no-cache" }).then(res => { const copy = res.clone(); caches.open(VERSION).then(c => c.put(req, copy)); return res; })
    .catch(() => caches.match(req).then(hit => hit || caches.match("./index.html"))));
});
