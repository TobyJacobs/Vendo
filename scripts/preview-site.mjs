// Serves dist/ on http://localhost:8000 the way Netlify does: /about is served from about.html,
// unknown addresses get 404.html. For checking the built site before pushing.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
const ROOT = "dist", PORT = Number(process.env.PORT || 8000);
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png",
  ".jpg": "image/jpeg", ".ico": "image/x-icon", ".xml": "application/xml", ".txt": "text/plain", ".webmanifest": "application/manifest+json" };
createServer(async (req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname)).replace(/^(\.\.[/\\])+/, "");
  const tries = path.endsWith("/") ? [join(path, "index.html")] : [path, path + ".html"];
  for (const t of tries) {
    try { const body = await readFile(join(ROOT, t)); res.writeHead(200, { "content-type": TYPES[extname(t)] || "application/octet-stream" }); return res.end(body); } catch {}
  }
  res.writeHead(404, { "content-type": TYPES[".html"] }); res.end(await readFile(join(ROOT, "404.html")));
}).listen(PORT, "127.0.0.1", () => console.log(`Previewing dist/ at http://localhost:${PORT}`));
