// Builds the website into site/dist. No dependencies.
//   node site/build.mjs                 uses the brand named in site/brand.txt
//   node site/build.mjs --brand foundagain --out /tmp/preview
import { readFileSync, writeFileSync, mkdirSync, readdirSync, cpSync, rmSync, existsSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const option = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const brandId = option("--brand") ?? readFileSync(join(root, "brand.txt"), "utf8").trim();
const out = option("--out") ?? join(root, "dist");
const brand = JSON.parse(readFileSync(join(root, "brands", `${brandId}.json`), "utf8"));
const release = JSON.parse(readFileSync(join(root, "release.json"), "utf8"));
const origin = `https://${brand.domain}`;
const buildId = Date.now().toString(36);

const brewName = brand.id === "foundagain" ? "found-again" : brand.id === "rescueroll" ? "rescue-roll" : brand.id;

function tokens(palette) {
  return [
    `--paper:${palette.paper}`, `--paper2:${palette.paper2}`, `--card:${palette.card}`, `--ink:${palette.ink}`,
    `--muted:${palette.muted}`, `--line:${palette.line}`, `--accent:${palette.accent}`, `--accent-ink:${palette.accentInk}`,
    `--accent-soft:${palette.accentSoft}`, `--good:${palette.good}`, `--link:${palette.link ?? palette.accent}`,
  ].join(";");
}

const cssVars = [
  `:root{${tokens(brand.light)};--display:${brand.fonts.display};--display-weight:${brand.fonts.displayWeight};--display-transform:${brand.fonts.displayTransform};--display-tracking:${brand.fonts.displayTracking};color-scheme:light}`,
  `@media (prefers-color-scheme: dark){:root{${tokens(brand.dark)};color-scheme:dark}}`,
].join("");

const layout = readFileSync(join(root, "templates", "layout.html"), "utf8");

function fill(text, values) {
  return text.replace(/\{\{(\w+)\}\}/g, (match, key) => (key in values ? values[key] : match));
}

// Until the signed DMG is published, download pages say it's coming instead of linking to a missing file.
const available = release.available === true;
// The tip button only appears once a real payment link is set.
const tipsOpen = /^https:\/\//.test(release.tipUrl ?? "") && !release.tipUrl.includes("REPLACE");

const shared = {
  name: brand.name, APP: brand.name, DOMAIN: brand.domain, domain: brand.domain, origin, icon: brand.icon,
  heroTitle: brand.heroTitle, googleFamily: brand.fonts.googleFamily, cssVars, buildId, brewName,
  version: release.version, dmgSize: release.size, dmgFile: release.file, year: new Date().getFullYear(),
  themeColor: brand.light.paper, repo: release.repo,
  requirements: available
    ? `Version ${release.version} · macOS 14 or later<br>Apple silicon and Intel · ${release.size}`
    : `Coming very soon · macOS 14 or later<br>Apple silicon and Intel`,
};

/** Reads the <!-- key: value --> block at the top of a content fragment. */
function parse(file) {
  const raw = readFileSync(file, "utf8");
  const match = raw.match(/^\s*<!--([\s\S]*?)-->/);
  const meta = {};
  if (match) {
    for (const line of match[1].split("\n")) {
      const at = line.indexOf(":");
      if (at > 0) meta[line.slice(0, at).trim()] = line.slice(at + 1).trim();
    }
  }
  return { meta, body: match ? raw.slice(match[0].length) : raw };
}

function escapeHTML(text) {
  return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** FAQ structured data from <details><summary>…</summary><p>…</p></details> blocks. */
function faqSchema(html) {
  const items = [...html.matchAll(/<details>\s*<summary>([\s\S]*?)<\/summary>([\s\S]*?)<\/details>/g)].map((m) => ({
    "@type": "Question",
    name: m[1].replace(/<[^>]+>/g, "").trim(),
    acceptedAnswer: { "@type": "Answer", text: m[2].replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim() },
  }));
  return items.length ? { "@type": "FAQPage", mainEntity: items } : null;
}

const app = {
  "@type": "SoftwareApplication",
  name: brand.name,
  operatingSystem: "macOS 14 or later",
  applicationCategory: "UtilitiesApplication",
  url: origin,
  downloadUrl: `${origin}/download`,
  softwareVersion: release.version,
  offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
  publisher: { "@type": "Organization", name: "weio Ltd" },
};

const pages = [];
function page(slug, { title, description, body, ogType = "article", schema = [] }) {
  const canonical = slug ? `${origin}/${slug}` : `${origin}/`;
  const html = fill(layout, {
    ...shared,
    title: escapeHTML(fill(title, shared)),
    description: escapeHTML(fill(description, shared)),
    canonical,
    ogType,
    content: fill(body, shared),
    schema: JSON.stringify({ "@context": "https://schema.org", "@graph": schema.filter(Boolean) }).replace(/</g, "\\u003c"),
  });
  // Cloudflare Pages serves guide.html at /guide with no redirect, matching the canonical URL.
  // (guide/index.html would redirect /guide to /guide/.)
  writeFileSync(slug ? join(out, `${slug}.html`) : join(out, "index.html"), html);
  pages.push(canonical);
}

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
cpSync(join(root, "static"), out, { recursive: true });

// Home
page("", {
  title: `${brand.name} · Free photo and file recovery for Mac`,
  description: `Recover deleted photos, videos and files from SD cards, USB sticks and external drives on your Mac. Free, with no limits, no trial and no account.`,
  body: readFileSync(join(root, "templates", "home.html"), "utf8"),
  ogType: "website",
  schema: [app, faqSchema(fill(readFileSync(join(root, "templates", "home.html"), "utf8"), shared))],
});

// Guides and other written pages
const contentDir = join(root, "content");
const guides = [];
for (const name of existsSync(contentDir) ? readdirSync(contentDir).sort() : []) {
  if (!name.endsWith(".html")) continue;
  const slug = name.replace(/\.html$/, "");
  const { meta, body } = parse(join(contentDir, name));
  const isGuide = !["faq", "why-free", "privacy", "thanks", "download"].includes(slug);
  if (isGuide) guides.push({ slug, meta });
  const article = `
<article class="article"><div class="wrap">
  <nav class="crumbs" aria-label="Breadcrumb"><a href="/">{{name}}</a> › ${isGuide ? '<a href="/guides">Guides</a> › ' : ""}${escapeHTML(meta.h1 ?? slug)}</nav>
  <h1>${meta.h1 ?? slug}</h1>
  ${meta.updated ? `<p class="updated">Updated ${new Date(meta.updated).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" })}</p>` : ""}
  <div class="prose">${body.replace(/<table>/g, '<div class="table-scroll"><table>').replace(/<\/table>/g, "</table></div>")}</div>
</div></article>`;
  page(slug, {
    title: meta.title ?? slug,
    description: meta.description ?? "",
    body: article,
    schema: [
      isGuide ? { "@type": "Article", headline: meta.h1 ?? meta.title, dateModified: meta.updated, author: { "@type": "Organization", name: "weio Ltd" } } : null,
      // Structured data is read by search engines as-is, so placeholders must be filled first.
      faqSchema(fill(body, shared)),
    ],
  });
}

// Guide index
page("guides", {
  title: `Recovery guides for Mac · ${brand.name}`,
  description: "Step-by-step guides to getting deleted photos, videos and files back on a Mac, from SD cards, camera cards, USB sticks and external drives.",
  body: `<article class="article"><div class="wrap" style="max-width:980px">
  <h1>Guides</h1>
  <p class="updated">Plain answers for the moment you realise something's gone.</p>
  <ul class="guide-list">${guides.map((g) => `<li><a href="/${g.slug}"><b>${g.meta.h1 ?? g.slug}</b><span>${escapeHTML(g.meta.description ?? "")}</span></a></li>`).join("")}</ul>
</div></article>`,
});

// Download page: the button links straight at the signed DMG.
page("download", {
  title: `Download ${brand.name} for Mac`,
  description: `Download ${brand.name}, the free app for recovering deleted photos and files on Mac. Version ${release.version}, signed and notarized by Apple.`,
  body: `<article class="article"><div class="wrap">
  <h1>Download {{name}}</h1>
  <div class="prose">
    ${available ? `<p>Version {{version}} · {{dmgSize}} · macOS 14 Sonoma or later · Apple silicon and Intel.</p>
    <a class="download" href="/releases/{{dmgFile}}">Download {{name}} {{version}}</a>` : `<p><b>Coming very soon.</b> {{name}} is in its final checks, including Apple's security review, so it opens on any Mac without warnings. It'll be free to download here.</p>
    <p>It's open source, so you can read every line of it now on <a href="{{repo}}">GitHub</a>.</p>
    <p>While you wait, the most important thing is to stop using the card or drive. Our <a href="/sd-card-recovery-mac">step-by-step guide</a> explains why, and what else you can do today.</p>`}
    <h2>Install it</h2>
    <ol>
      <li>Open the downloaded file.</li>
      <li>Drag {{name}} into your Applications folder.</li>
      <li>Open it from Applications. It's signed and checked by Apple, so it opens without warnings.</li>
    </ol>
    <p>Prefer Homebrew? <code>brew install --cask {{brewName}}</code></p>
    <aside class="note"><b>Before you start:</b> stop using the card or drive the files were on. Don't take new photos, copy files to it, or format it.</aside>
    <p><a href="/sd-card-recovery-mac">How to recover photos from an SD card, step by step</a></p>
  </div>
</div></article>`,
  ogType: "website",
  schema: [app],
});

// Tip page
page("thanks", {
  title: `Say thanks · ${brand.name}`,
  description: `${brand.name} is free. If it got your files back, you can leave a tip to keep it that way.`,
  body: `<article class="article"><div class="wrap">
  <h1>Glad it helped</h1>
  <div class="prose">
    <p>{{name}} is free, and it'll stay free. There's no paid version and nothing to unlock. If it got your photos or files back, a tip of whatever feels right keeps it going for the next person.</p>
    ${tipsOpen ? `<a class="download" href="${release.tipUrl}">Leave a tip</a>` : `<p><b>Tips open very soon.</b> Thank you for wanting to.</p>`}
    <p class="muted">Tips go to weio Ltd, the small UK company that makes {{name}}. Payment is handled by the tip platform; we never see your card details.</p>
    <p>Can't tip? Telling one friend about {{name}} helps just as much.</p>
  </div>
</div></article>`,
  ogType: "website",
});

// Privacy
page("privacy", {
  title: `Privacy · ${brand.name}`,
  description: `${brand.name} collects nothing. The app never connects to the internet, and this website uses no cookies or trackers.`,
  body: `<article class="article"><div class="wrap">
  <h1>Privacy</h1>
  <div class="prose">
    <p><b>The app collects nothing.</b> {{name}} never connects to the internet. It has no analytics, no crash reporting and no account. Your files are read on your Mac and copied to a folder on your Mac, and nowhere else.</p>
    <p><b>This website uses no cookies and no tracking scripts.</b> It's hosted on Cloudflare, which keeps standard server logs (such as IP addresses and pages requested) for security and aggregate traffic counts.</p>
    <p><b>Tips</b> are handled by the tip platform under its own privacy policy. We receive your name and message only if you choose to give them.</p>
    <p>Questions: <a href="mailto:hello@{{domain}}">hello@{{domain}}</a>.</p>
  </div>
</div></article>`,
});

// 404
mkdirSync(out, { recursive: true });
writeFileSync(join(out, "404.html"), fill(layout, {
  ...shared, title: `Not found · ${brand.name}`, description: "", canonical: `${origin}/404`, ogType: "website",
  content: `<article class="article"><div class="wrap"><h1>That page isn't here</h1><div class="prose"><p>It may have moved. Try the <a href="/guides">guides</a> or the <a href="/">home page</a>.</p></div></div></article>`,
  schema: "{}",
}));

// Search engines and Cloudflare Pages settings
writeFileSync(join(out, "sitemap.xml"), `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${pages.map((url) => `  <url><loc>${url}</loc></url>`).join("\n")}
</urlset>
`);
writeFileSync(join(out, "robots.txt"), `User-agent: *\nAllow: /\nSitemap: ${origin}/sitemap.xml\n`);
writeFileSync(join(out, "_headers"), `/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=(), interest-cohort=()
  X-Frame-Options: DENY
/releases/*
  Content-Disposition: attachment
  Cache-Control: public, max-age=31536000, immutable
/img/*
  Cache-Control: public, max-age=604800
`);
writeFileSync(join(out, "_redirects"), `/help /guides 301\n/source ${release.repo} 302\n/latest ${available ? `/releases/${release.file}` : "/download"} 302\n`);

const size = (dir) => readdirSync(dir).reduce((sum, f) => { const p = join(dir, f); const s = statSync(p); return sum + (s.isDirectory() ? size(p) : s.size); }, 0);
console.log(`Built ${pages.length} pages for ${brand.name} (${brand.domain}) into ${out} — ${(size(out) / 1024).toFixed(0)} KB`);
