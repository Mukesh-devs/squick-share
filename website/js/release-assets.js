// What a GitHub release holds, sorted into downloads per kind of Mac.
// Pure functions (no DOM), so `node --test scripts/website.test.mjs` can check them.

/** The repository the site belongs to. */
export const REPO = "Mukesh-devs/squick-share";
export const REPO_URL = `https://github.com/${REPO}`;
export const RELEASES_URL = `${REPO_URL}/releases`;
export const LATEST_API = `https://api.github.com/repos/${REPO}/releases/latest`;

/**
 * The builds a release offers, one per kind of Mac, in the order the page
 * shows them. The universal build runs on every Mac, so it is the one to
 * offer when the visitor's chip isn't known.
 */
export const BUILDS = {
  universal: { name: "Universal", detail: "Any Mac, Apple silicon or Intel" },
  arm64: { name: "Apple silicon", detail: "M1 and later, a smaller download" },
  x86_64: { name: "Intel", detail: "Macs with an Intel processor, a smaller download" },
};
export const BUILD_ORDER = Object.keys(BUILDS);

/** Which build a file is, from its name. */
const ARCHES = [
  [/universal/i, "universal"],
  [/(arm64|aarch64|apple[-_]?silicon)/i, "arm64"],
  [/(x86[-_]64|x64|amd64|intel)/i, "x86_64"],
];

/** Which kind of file it is, best first. Anything else isn't a download. */
const TYPES = [
  { test: /\.dmg$/i, ext: ".dmg", kind: "Disk image", what: "Open it, drag the app to Applications" },
  { test: /\.zip$/i, ext: ".zip", kind: "Zip archive", what: "The same app, zipped" },
];

/** "6.5 MB", "980 KB". */
export function formatSize(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) return "";
  const mb = bytes / 1e6;
  if (mb >= 100) return `${Math.round(mb)} MB`;
  if (mb >= 1) return `${mb.toFixed(1)} MB`;
  return `${Math.max(1, Math.round(bytes / 1e3))} KB`;
}

/** Only links to GitHub are ever shown as downloads. */
export function safeUrl(url) {
  try {
    const u = new URL(url);
    return u.protocol === "https:" && /(^|\.)github(usercontent)?\.com$/.test(u.hostname)
      ? u.href
      : null;
  } catch {
    return null;
  }
}

/**
 * A release's assets as `{ universal: [], arm64: [], x86_64: [], checksums }`:
 * each download with its kind, URL and size, the disk image first. Files
 * that aren't the app (source archives, logs, signatures) are left out.
 */
export function classifyAssets(assets) {
  const out = { universal: [], arm64: [], x86_64: [], checksums: null };
  for (const asset of Array.isArray(assets) ? assets : []) {
    const name = String(asset?.name ?? "");
    const url = safeUrl(asset?.browser_download_url);
    if (!name || !url) continue;
    if (/^sha256sums|\.sha256$/i.test(name)) {
      out.checksums = url;
      continue;
    }
    const rank = TYPES.findIndex((t) => t.test.test(name));
    if (rank < 0) continue;
    // A file that doesn't say which chip it is for is taken to run on any Mac.
    const arch = ARCHES.find(([test]) => test.test(name))?.[1] ?? "universal";
    const type = TYPES[rank];
    out[arch].push({
      arch,
      rank,
      name,
      url,
      ext: type.ext,
      kind: type.kind,
      what: type.what,
      size: formatSize(Number(asset.size)),
    });
  }
  for (const arch of BUILD_ORDER) out[arch].sort((a, b) => a.rank - b.rank);
  return out;
}

/**
 * The visitor's device: "mac", "android", "ios", "windows", "linux", or null
 * when it can't be told.
 */
export function detectPlatform({ userAgent = "", platform = "", maxTouchPoints = 0 } = {}) {
  const ua = `${userAgent} ${platform}`;
  if (/Android/i.test(ua)) return "android";
  if (/iPhone|iPad|iPod/i.test(ua)) return "ios";
  // iPadOS says it is a Mac; a Mac has no touch screen.
  if (/Mac/i.test(ua)) return maxTouchPoints > 1 ? "ios" : "mac";
  if (/Win/i.test(ua)) return "windows";
  if (/Linux|X11|CrOS/i.test(ua)) return "linux";
  return null;
}

/**
 * The Mac's chip from the browser's client hints ("arm" or "x86"), as a
 * build name; null when the browser doesn't say (Safari and Firefox don't).
 */
export function archFromHint(architecture) {
  const a = String(architecture ?? "").toLowerCase();
  if (a === "arm" || a === "arm64") return "arm64";
  if (a === "x86" || a === "x86_64" || a === "x64") return "x86_64";
  return null;
}

/**
 * The file to offer this Mac: the disk image built for its chip when that is
 * known, else the universal one, else whatever the release has.
 */
export function recommend(downloads, arch = null) {
  const order = [arch, "universal", ...BUILD_ORDER].filter((a) => a && downloads?.[a]);
  for (const a of order) if (downloads[a].length) return downloads[a][0];
  return null;
}

/** What the site needs of a release from the API (null when it isn't one). */
export function summarize(release) {
  if (!release || typeof release !== "object" || !release.tag_name) return null;
  const downloads = classifyAssets(release.assets);
  const tag = String(release.tag_name);
  return {
    tag,
    version: tag.replace(/^v/i, ""),
    name: String(release.name || tag),
    url: safeUrl(release.html_url) ?? `${RELEASES_URL}/tag/${encodeURIComponent(tag)}`,
    publishedAt: release.published_at ?? null,
    downloads,
    hasDownloads: BUILD_ORDER.some((a) => downloads[a].length > 0),
    notesHtml: typeof release.body_html === "string" ? release.body_html : "",
    notesText: typeof release.body === "string" ? release.body : "",
  };
}

/** "15 November 2026" (or "" when the date is missing or wrong). */
export function formatDate(iso, locale = "en-GB") {
  const d = new Date(iso ?? NaN);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleDateString(locale, {
    day: "numeric",
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  });
}
