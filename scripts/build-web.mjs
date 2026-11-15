// Copies the website files into www/, which Capacitor bundles into the iPhone app.
// The website itself is still served straight from the repository root (Netlify needs no build).
import { cpSync, mkdirSync, rmSync, existsSync } from "node:fs";
const FILES = ["index.html", "favicon.svg", "favicon.ico", "favicon-32.png", "apple-touch-icon.png",
  "icon-192.png", "icon-512.png", "icon-maskable-512.png", "manifest.webmanifest", "og-image.jpg"];
rmSync("www", { recursive: true, force: true });
mkdirSync("www");
for (const f of FILES) if (existsSync(f)) cpSync(f, `www/${f}`);
console.log(`Copied ${FILES.filter(existsSync).length} files to www/`);
