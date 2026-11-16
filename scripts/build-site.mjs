// Builds the website into dist/ for Netlify.
//
// Every address (/about, /venues/the-plough-and-harrow and so on) gets its own HTML file with the
// right title, description, canonical link and readable content, so search engines and link
// previews see a real page. The same app script then takes over in the browser.
// Also writes sitemap.xml and robots.txt. Run with: npm run site
import { readFileSync, writeFileSync, mkdirSync, rmSync, cpSync, existsSync } from "node:fs";
import { dirname } from "node:path";

const SRC = readFileSync("index.html", "utf8");
const OUT = "dist";

// ---- read the data the app already defines, so nothing is duplicated by hand ----
function literal(name) {
  // Finds `const NAME = [...]` or `{...}` and reads it by matching brackets, skipping over strings.
  const start = SRC.search(new RegExp(`const ${name}\\s*=\\s*[\\[{]`));
  if (start < 0) throw new Error(`Couldn't find ${name} in index.html`);
  let i = SRC.indexOf("=", start) + 1;
  while (/\s/.test(SRC[i])) i++;
  const from = i; let depth = 0, quote = null;
  for (; i < SRC.length; i++) {
    const c = SRC[i];
    if (quote) { if (c === "\\") i++; else if (c === quote) quote = null; continue; }
    if (c === '"' || c === "'" || c === "`") quote = c;
    else if (c === "[" || c === "{") depth++;
    else if ((c === "]" || c === "}") && --depth === 0) break;
  }
  return Function(`return ${SRC.slice(from, i + 1)}`)();
}
const constant = (name) => (SRC.match(new RegExp(`const ${name}\\s*=\\s*([^;]+);`)) || [])[1];
const VENUES = literal("VENUES");
const PAGES = literal("PAGES");
const RELEASES = literal("RELEASES");
const SITE = (process.env.SITE_URL || JSON.parse(constant("SITE_URL")) || process.env.URL || "").replace(/\/$/, "");
const INDEX_VENUES = constant("INDEX_VENUES") === "true";
const LD_RE = /<script type="application\/ld\+json">([\s\S]*?)<\/script>/;
const LD = JSON.parse(SRC.match(LD_RE)[1]);
const FAQ = LD["@graph"].find(g => g["@type"] === "FAQPage").mainEntity;

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const slugOf = (v) => v.name.toLowerCase().replace(/&/g, "and").replace(/['’]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const gbp = (n) => "£" + Math.round(n).toLocaleString("en-GB");
const full = (n) => n * 1.04;

// ---- page content seen before the app script runs ----
const DESC = {
  home: "Book pubs, bars, nightclubs, village halls, clubs and leisure centres for weddings, parties, wakes and christenings. See real availability. Every price includes all fees.",
  list: "List your pub, bar, club, hall or leisure centre on Vendo for free. Fill your function room on quiet nights and pay a small fee only when you get a booking.",
  about: "Vendo helps pubs, bars, village halls, clubs and leisure centres earn from rooms that sit empty most nights, and helps people find the right room for their event.",
  contact: "Get in touch with Vendo about a booking, listing your venue, or partnering with us.",
  terms: "The terms for booking and listing venues on Vendo.",
  privacy: "How Vendo collects, uses and protects your personal information.",
  cookies: "The cookies and local storage Vendo uses, and how to control them.",
  changelog: "Every Vendo release, from the first demo to the latest version.",
};
const homeBody = () => `<section class="wrap page">
  <h1>Every great party needs a room. Find yours.</h1>
  <p class="lead">Book function rooms, halls and private bars straight from the people who run them. See real availability, build a quote, and send a request in a couple of minutes.</p>
  <h2>Venues on Vendo</h2>
  <ul>${VENUES.map(v => `<li><a href="/venues/${slugOf(v)}">${esc(v.name)}</a>: ${esc(v.kind.toLowerCase())} in ${esc(v.place)}, for up to ${Math.max(v.seated, v.standing)} guests, from ${gbp(full(v.hour))} an hour.</li>`).join("")}</ul>
  <h2>How Vendo works</h2>
  <ol><li>Find your room: search by date, guests and place. Every price includes all fees.</li><li>Build your quote: choose hours and extras like food, bar staff or a DJ.</li><li>Book and relax: pay securely on Vendo and message the venue any time.</li></ol>
  <h2>Questions</h2>
  ${FAQ.map(q => `<h3>${esc(q.name)}</h3><p>${esc(q.acceptedAnswer.text)}</p>`).join("")}
  <p><a href="/list-your-venue">List your venue on Vendo</a></p></section>`;
const venueBody = (v) => `<section class="wrap page">
  <p>${esc(v.kind)} · ${esc(v.region)}</p><h1>${esc(v.name)}</h1>
  <p class="lead">${esc(v.place)} · rated ${v.rating.toFixed(1)} from ${v.reviews} reviews</p>
  <p>${v.seated} seated · ${v.standing} standing · ${gbp(full(v.hour))} an hour or ${gbp(full(v.day))} a day, including fees · ${v.minH} hours minimum</p>
  <h2>${esc(v.space)}</h2><p>${esc(v.blurb)}</p>
  <p>Ideal for: ${esc(v.suits.join(", "))}</p>
  <h2>What's included</h2><ul>${v.features.map(f => `<li>${esc(f)}</li>`).join("")}</ul>
  <h2>House rules</h2><ul>${v.rules.map(r => `<li>${esc(r)}</li>`).join("")}</ul>
  <p>Hosted by ${esc(v.host)}. ${esc(v.reply)}.</p>
  <p><a href="/">See more venues</a></p></section>`;
const infoBody = (key) => {
  const pg = PAGES[key];
  return `<section class="wrap page"><h1>${esc(pg.title)}</h1><p class="lead">${esc(pg.lead)}</p><div class="prose">${pg.body === "contact" ? "" : pg.body}</div></section>`;
};
const changelogBody = () => `<section class="wrap page"><h1>What's new</h1>${RELEASES.map(r => `<h2>${esc(r.v)} · ${esc(r.t)}</h2><p>${r.d}</p><ul>${r.n.map(n => `<li>${esc(n)}</li>`).join("")}</ul>`).join("")}</section>`;
const listBody = () => `<section class="wrap page"><h1>Turn your empty room into steady income.</h1><p class="lead">${esc(DESC.list)}</p>
  <ol><li>Tell us about your space.</li><li>We build your listing: photos, prices and your calendar.</li><li>Bookings come to you, and payments land in your bank.</li></ol></section>`;

// ---- every address on the site ----
const pages = [
  { path: "/", title: "Vendo: book pubs, bars, halls and clubs for your event", desc: DESC.home, body: homeBody(), index: true, faq: true, priority: "1.0" },
  { path: "/list-your-venue", title: "List your venue for free · Vendo", desc: DESC.list, body: listBody(), index: true, priority: "0.9" },
  ...["about", "contact", "terms", "privacy", "cookies"].map(k => ({ path: "/" + k, title: `${PAGES[k].title} · Vendo`, desc: DESC[k], body: infoBody(k), index: true, priority: "0.5" })),
  { path: "/whats-new", title: "What's new · Vendo", desc: DESC.changelog, body: changelogBody(), index: true, priority: "0.3" },
  ...VENUES.map(v => ({ path: `/venues/${slugOf(v)}`, title: `${v.name}, ${v.place.split(",")[0]}: ${v.kind.toLowerCase()} to hire · Vendo`,
    desc: `${v.space} for up to ${Math.max(v.seated, v.standing)} guests in ${v.place}. From ${gbp(full(v.hour))} an hour, including all fees. Ideal for ${v.suits.slice(0, 3).join(", ").toLowerCase()}.`,
    body: venueBody(v), index: INDEX_VENUES, priority: "0.8" })),
  // App screens: real files so a refresh works, but kept out of search results.
  ...VENUES.map(v => ({ path: `/book/${slugOf(v)}`, title: `Book: ${v.name} · Vendo`, desc: DESC.home, body: "", index: false })),
  { path: "/for-venues/dashboard", title: "Host dashboard · Vendo", desc: DESC.list, body: "", index: false },
  { path: "/for-venues/add", title: "Add your venue · Vendo", desc: DESC.list, body: "", index: false },
  { path: "/admin", title: "Admin · Vendo", desc: DESC.home, body: "", index: false },
  { path: "/account", title: "My account · Vendo", desc: DESC.home, body: "", index: false },
  { path: "/sign-in", title: "Sign in · Vendo", desc: "Sign in to Vendo with a link we email you. No password needed.", body: "", index: false },
  { path: "/create-account", title: "Create your account · Vendo", desc: "Create a free Vendo account to book venues, or to list your pub, hall, bar or club.", body: "", index: false },
];

// ---- write one HTML file per address ----
function setTag(html, re, tag) {
  if (!re.test(html)) throw new Error(`Couldn't find ${re} in index.html`);
  return html.replace(re, tag);
}
function render(pg) {
  const url = SITE + (pg.path === "/" ? "/" : pg.path);
  let h = SRC;
  h = setTag(h, /<title>[\s\S]*?<\/title>/, `<title>${esc(pg.title)}</title>`);
  h = setTag(h, /<meta name="description" content="[^"]*">/, `<meta name="description" content="${esc(pg.desc)}">`);
  h = setTag(h, /<meta name="robots" content="[^"]*">/, `<meta name="robots" content="${pg.index ? "index,follow" : "noindex,follow"}">`);
  h = setTag(h, /<link rel="canonical" href="[^"]*">/, `<link rel="canonical" href="${esc(url)}">`);
  h = setTag(h, /<meta property="og:url" content="[^"]*">/, `<meta property="og:url" content="${esc(url)}">`);
  h = setTag(h, /<meta property="og:title" content="[^"]*">/, `<meta property="og:title" content="${esc(pg.title.replace(/ · Vendo$/, ""))}">`);
  h = setTag(h, /<meta property="og:description" content="[^"]*">/, `<meta property="og:description" content="${esc(pg.desc)}">`);
  // Structured data: FAQ markup belongs on the home page only.
  const ld = { ...LD, "@graph": LD["@graph"].filter(g => pg.faq || g["@type"] !== "FAQPage") };
  h = h.replace(LD_RE, () => `<script type="application/ld+json">${JSON.stringify(ld)}</script>`);
  // Files live at the site root, so point to them from any folder.
  h = h.replace(/(href|src)="(favicon\.ico|favicon\.svg|apple-touch-icon\.png|manifest\.webmanifest)"/g, '$1="/$2"');
  h = h.replace('register("sw.js")', 'register("/sw.js")');
  if (pg.body) h = setTag(h, /<main id="app"><\/main>/, `<main id="app">${pg.body}</main>`);
  // Netlify serves about.html at /about with no redirect (a folder would redirect to /about/).
  const file = pg.path === "/" ? `${OUT}/index.html` : `${OUT}${pg.path}.html`;
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, h);
}

rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT);
pages.forEach(render);
// Unknown addresses: Netlify serves 404.html, and the app shows "We couldn't find that page".
render({ path: "/__404", title: "Page not found · Vendo", desc: DESC.home, body: "", index: false });
cpSync(`${OUT}/__404.html`, `${OUT}/404.html`); rmSync(`${OUT}/__404.html`);

for (const f of ["favicon.ico", "favicon.svg", "favicon-32.png", "apple-touch-icon.png", "icon-192.png", "icon-512.png",
  "icon-maskable-512.png", "manifest.webmanifest", "og-image.jpg", "sw.js"]) if (existsSync(f)) cpSync(f, `${OUT}/${f}`);

const today = new Date().toISOString().slice(0, 10);
const listed = pages.filter(p => p.index);
if (SITE) {
  writeFileSync(`${OUT}/sitemap.xml`, `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${listed
    .map(p => `  <url><loc>${SITE}${p.path === "/" ? "/" : p.path}</loc><lastmod>${today}</lastmod><priority>${p.priority}</priority></url>`).join("\n")}\n</urlset>\n`);
}
writeFileSync(`${OUT}/robots.txt`, `User-agent: *\nAllow: /\nDisallow: /book/\nDisallow: /account\nDisallow: /sign-in\nDisallow: /create-account\nDisallow: /for-venues/dashboard\nDisallow: /for-venues/add\nDisallow: /admin\n${SITE ? `\nSitemap: ${SITE}/sitemap.xml\n` : ""}`);
writeFileSync(`${OUT}/_headers`, `/*\n  X-Content-Type-Options: nosniff\n  Referrer-Policy: strict-origin-when-cross-origin\n/sw.js\n  Cache-Control: no-cache\n/*.png\n  Cache-Control: public, max-age=604800\n/*.jpg\n  Cache-Control: public, max-age=604800\n`);
// Send visitors on the old Netlify address to the real domain, keeping the page they asked for.
const NETLIFY_HOST = "https://vendohire.netlify.app";
const hostMove = SITE && SITE !== NETLIFY_HOST ? `${NETLIFY_HOST}/*  ${SITE}/:splat  301!\n` : "";
writeFileSync(`${OUT}/_redirects`, `${hostMove}/index.html  /  301\n`);

console.log(`Built ${pages.length + 1} pages into ${OUT}/ (${listed.length} in the sitemap${SITE ? `, site ${SITE}` : ", no site address set"}; venue pages ${INDEX_VENUES ? "indexed" : "kept out of search results"}).`);
