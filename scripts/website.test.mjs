// node --test scripts/website.test.mjs
// The website's release logic (website/js/release-assets.js) and its files.
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  archFromHint,
  classifyAssets,
  detectPlatform,
  formatDate,
  formatSize,
  recommend,
  safeUrl,
  summarize,
} from "../website/js/release-assets.js";

const dl = (name) => `https://github.com/Mukesh-devs/squick-share/releases/download/v1.2.3/${name}`;
const asset = (name, size = 4_000_000) => ({ name, size, browser_download_url: dl(name) });

// The files the release workflow attaches (.github/workflows/release.yml), plus some that aren't the app.
const RELEASE = {
  tag_name: "v1.2.3",
  name: "SQuick Share v1.2.3",
  html_url: "https://github.com/Mukesh-devs/squick-share/releases/tag/v1.2.3",
  published_at: "2026-11-15T17:00:21Z",
  body: "Notes",
  assets: [
    asset("squick-share-1.2.3-arm64.dmg", 3_809_929),
    asset("squick-share-1.2.3-arm64.zip", 3_344_028),
    asset("squick-share-1.2.3-universal.dmg", 6_539_918),
    asset("squick-share-1.2.3-universal.zip", 5_762_414),
    asset("squick-share-1.2.3-x86_64.dmg", 3_954_256),
    asset("squick-share-1.2.3-x86_64.zip", 3_442_541),
    asset("SHA256SUMS.txt", 600),
    asset("build-log.txt", 9_000),
  ],
};

test("a release's files are sorted per kind of Mac, the disk image first", () => {
  const d = classifyAssets(RELEASE.assets);
  for (const arch of ["universal", "arm64", "x86_64"]) {
    assert.deepEqual(
      d[arch].map((a) => a.ext),
      [".dmg", ".zip"],
      arch,
    );
    assert.ok(d[arch].every((a) => a.arch === arch));
  }
  assert.equal(d.universal[0].url, dl("squick-share-1.2.3-universal.dmg"));
  assert.equal(d.universal[0].size, "6.5 MB");
  assert.equal(d.arm64[0].kind, "Disk image");
  assert.equal(d.checksums, dl("SHA256SUMS.txt"));
  const names = [...d.universal, ...d.arm64, ...d.x86_64].map((a) => a.name).join(" ");
  assert.doesNotMatch(names, /build-log|SHA256/);
});

test("files named another way, or for one chip only, are still found", () => {
  const d = classifyAssets([
    asset("SQuick-Share_2.0_aarch64.dmg"),
    asset("SQuick.Share.dmg"),
    asset("squick-share-2.0-intel.zip"),
    asset("squick-share-2.0.tar.gz"),
  ]);
  assert.deepEqual(
    d.arm64.map((a) => a.name),
    ["SQuick-Share_2.0_aarch64.dmg"],
  );
  // No chip in the name: taken to run on any Mac.
  assert.deepEqual(
    d.universal.map((a) => a.name),
    ["SQuick.Share.dmg"],
  );
  assert.deepEqual(
    d.x86_64.map((a) => a.ext),
    [".zip"],
  );
  assert.equal(d.checksums, null);
  assert.deepEqual(classifyAssets(undefined), {
    universal: [],
    arm64: [],
    x86_64: [],
    checksums: null,
  });
});

test("only downloads hosted by GitHub are offered", () => {
  const d = classifyAssets([
    {
      name: "squick-share-9-universal.dmg",
      size: 1,
      browser_download_url: "https://evil.example/squick-share-9-universal.dmg",
    },
    { name: "squick-share-9-arm64.dmg", size: 1, browser_download_url: "javascript:alert(1)" },
    { name: "squick-share-9-x86_64.dmg", size: 1, browser_download_url: "http://github.com/x.dmg" },
    { name: "squick-share-9-arm64.zip", size: 1, browser_download_url: "https://github.com.evil.example/x" },
  ]);
  assert.deepEqual([d.universal, d.arm64, d.x86_64], [[], [], []]);
  assert.equal(safeUrl("https://objects.githubusercontent.com/x"), "https://objects.githubusercontent.com/x");
});

test("the visitor's device is told from the browser", () => {
  const os = (userAgent, platform = "", maxTouchPoints = 0) =>
    detectPlatform({ userAgent, platform, maxTouchPoints });
  assert.equal(os("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", "MacIntel"), "mac");
  assert.equal(os("Mozilla/5.0 (Linux; Android 14; Pixel 9) Mobile"), "android");
  assert.equal(os("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Mobile/15E148"), "ios");
  // iPadOS calls itself a Mac, but has a touch screen.
  assert.equal(os("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", "MacIntel", 5), "ios");
  assert.equal(os("Mozilla/5.0 (Windows NT 10.0; Win64; x64)"), "windows");
  assert.equal(os("Mozilla/5.0 (X11; Linux x86_64)"), "linux");
  assert.equal(os("Mozilla/5.0 (X11; CrOS x86_64 14541.0.0)"), "linux");
  assert.equal(os(""), null);
});

test("the Mac's chip comes from client hints when the browser gives them", () => {
  assert.equal(archFromHint("arm"), "arm64");
  assert.equal(archFromHint("x86"), "x86_64");
  assert.equal(archFromHint(""), null);
  assert.equal(archFromHint(undefined), null);
});

test("the file offered is the one for this Mac's chip, else the universal one", () => {
  const d = classifyAssets(RELEASE.assets);
  assert.equal(recommend(d, "arm64").name, "squick-share-1.2.3-arm64.dmg");
  assert.equal(recommend(d, "x86_64").name, "squick-share-1.2.3-x86_64.dmg");
  assert.equal(recommend(d, null).name, "squick-share-1.2.3-universal.dmg");
  // A release without a universal build still offers something.
  const only = classifyAssets([asset("squick-share-1-arm64.dmg")]);
  assert.equal(recommend(only, null).name, "squick-share-1-arm64.dmg");
  assert.equal(recommend(only, "x86_64").name, "squick-share-1-arm64.dmg");
  assert.equal(recommend(classifyAssets([]), "arm64"), null);
});

test("a release is summarized for the page; anything else is not a release", () => {
  const r = summarize(RELEASE);
  assert.equal(r.version, "1.2.3");
  assert.equal(r.hasDownloads, true);
  assert.equal(r.url, RELEASE.html_url);
  assert.equal(formatDate(r.publishedAt), "15 November 2026");
  assert.equal(summarize({ tag_name: "v2.0.0", assets: [] }).hasDownloads, false);
  assert.equal(
    summarize({ tag_name: "v2.0.0", html_url: "https://evil.example/" }).url,
    "https://github.com/Mukesh-devs/squick-share/releases/tag/v2.0.0",
  );
  assert.equal(summarize({ message: "Not Found" }), null);
  assert.equal(summarize(null), null);
  assert.equal(formatDate("nonsense"), "");
});

test("sizes read plainly", () => {
  assert.equal(formatSize(6_539_918), "6.5 MB");
  assert.equal(formatSize(123_456_789), "123 MB");
  assert.equal(formatSize(900), "1 KB");
  assert.equal(formatSize(0), "");
});

/* ------------------------------------------------------------ the page */
const site = join(dirname(fileURLToPath(import.meta.url)), "..", "website");
const pages = ["index.html", "404.html"].filter((p) => existsSync(join(site, p)));
const read = (p) => readFileSync(join(site, p), "utf8");

test("the page has no version or download link written into it", () => {
  for (const page of pages) {
    const html = read(page);
    assert.doesNotMatch(html, /releases\/download\//, `${page}: download links come from the API`);
    // Not counting drawings (SVG path data) and the structured data block.
    const text = html.replace(/<svg[\s\S]*?<\/svg>/g, "").replace(/<script[\s\S]*?<\/script>/g, "");
    assert.doesNotMatch(text, /\bv?\d+\.\d+\.\d+\b/, `${page}: no version number in the page`);
  }
});

test("the page states no transfer speeds", () => {
  // Speed depends on each Wi-Fi network, so the page doesn't promise one.
  const html = read("index.html").replace(/<svg[\s\S]*?<\/svg>/g, "");
  assert.doesNotMatch(html, /\d\s*(MB\/s|Mbps|Mbit|GB\/s)/i);
});

test("every local file the page names exists", () => {
  const html = read("index.html");
  const refs = new Set();
  for (const m of html.matchAll(/(?<![-\w])(?:src|href)="([^"#:]+)"/g)) refs.add(m[1]);
  for (const m of html.matchAll(/(?:srcset|imagesrcset)="([^"]+)"/g))
    for (const part of m[1].split(",")) refs.add(part.trim().split(/\s+/)[0]);
  const css = read("css/site.css");
  for (const m of css.matchAll(/url\("(\.\.\/[^"]+)"\)/g)) refs.add(join("css", m[1]));
  const manifest = existsSync(join(site, "site.webmanifest"))
    ? JSON.parse(read("site.webmanifest"))
    : { icons: [] };
  for (const icon of manifest.icons) refs.add(icon.src);
  assert.ok(refs.size > 20);
  for (const ref of refs) assert.ok(existsSync(join(site, ref)), `${ref} is missing`);
});

test("the page is built to be found and read", () => {
  const html = read("index.html");
  assert.equal(html.match(/<h1[\s>]/g)?.length, 1, "one h1");
  assert.match(html, /<title>SQuick Share — [^<]+<\/title>/);
  for (const tag of ['rel="canonical"', 'property="og:image"', 'name="twitter:card"', '"@type": "SoftwareApplication"'])
    assert.ok(html.includes(tag), `${tag} is missing`);
  // Every picture says what it shows, or says it is decoration.
  for (const img of html.matchAll(/<img\b[^>]*>/g)) assert.match(img[0], /\balt="/, img[0]);
  // In-page links lead somewhere.
  const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]));
  for (const m of html.matchAll(/href="#([^"]+)"/g)) assert.ok(ids.has(m[1]), `#${m[1]} has no target`);
  // Nothing is loaded from another site: no CDN, fonts or trackers (the
  // GitHub API is asked from the script, not the markup).
  for (const m of html.matchAll(/\bsrc="(https?:[^"]+)"/g)) assert.fail(`${m[1]} is loaded from another site`);
  for (const m of html.matchAll(/<link\b[^>]*>/g)) {
    const rel = m[0].match(/\brel="([^"]+)"/)?.[1] ?? "";
    const href = m[0].match(/\bhref="([^"]+)"/)?.[1] ?? "";
    if (/stylesheet|preload|icon|manifest|modulepreload/.test(rel))
      assert.doesNotMatch(href, /^https?:/, `${href} is loaded from another site`);
  }
});
