// The download card and buttons, filled from the latest GitHub release.
// Nothing here is hard-coded: publishing a release updates the site.
import {
  BUILDS,
  LATEST_API,
  RELEASES_URL,
  archFromHint,
  detectPlatform,
  formatDate,
  recommend,
  summarize,
} from "./release-assets.js";

const CACHE_KEY = "squick-share.release.v1";
/** Minutes a looked-up release is reused within a tab (GitHub allows 60 lookups an hour). */
const CACHE_MINUTES = 10;
const TIMEOUT_MS = 8000;

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

function readCache() {
  try {
    const hit = JSON.parse(sessionStorage.getItem(CACHE_KEY) ?? "null");
    if (hit && Date.now() - hit.at < CACHE_MINUTES * 60_000) return hit.data;
  } catch {
    // No storage (private mode): just ask again.
  }
  return undefined;
}

function writeCache(data) {
  try {
    sessionStorage.setItem(CACHE_KEY, JSON.stringify({ at: Date.now(), data }));
  } catch {
    // Fine without it.
  }
}

/**
 * The latest published release: `{ release }`, `{ none: true }` when the
 * project has none yet, or `{ error }` when GitHub can't be reached or
 * limits requests.
 */
export async function latestRelease(fetchImpl = fetch) {
  const cached = readCache();
  if (cached !== undefined) return cached;
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), TIMEOUT_MS);
  try {
    const res = await fetchImpl(LATEST_API, {
      headers: { Accept: "application/vnd.github+json" },
      signal: abort.signal,
    });
    if (res.status === 404) {
      const none = { none: true };
      writeCache(none);
      return none;
    }
    if (!res.ok) return { error: res.status === 403 || res.status === 429 ? "limited" : "failed" };
    const release = summarize(await res.json());
    if (!release) return { error: "failed" };
    const out = { release };
    writeCache(out);
    return out;
  } catch {
    return { error: "failed" };
  } finally {
    clearTimeout(timer);
  }
}

function setPrimaryButtons({ href, label, note }) {
  for (const a of $$("[data-download-primary]")) {
    a.setAttribute("href", href);
    const text = $("[data-download-label]", a);
    if (text)
      text.textContent = a.classList.contains("nav__get")
        ? label.replace(/^Download for /, "Get for ")
        : label;
  }
  const noteEl = $("[data-download-note]");
  if (noteEl && note) noteEl.textContent = note;
}

function setNote(text) {
  const note = $("[data-dl-note]");
  if (!note) return;
  note.textContent = text ?? "";
  note.hidden = !text;
}

/** A word for visitors who aren't on a Mac, above the download card. */
function noteFor(platform) {
  if (platform === "android")
    return "On your phone? Nothing to install there: Quick Share is already on it. SQuick Share goes on your Mac.";
  if (platform === "ios") return "SQuick Share is for Macs. Open this page on your Mac to download it.";
  if (platform === "windows")
    return "SQuick Share goes on your Mac. On your PC, Google's Quick Share app for Windows talks to it.";
  if (platform === "linux") return "SQuick Share is a Mac app, for macOS 13 or later.";
  return null;
}

function showProblem(kind) {
  const meta = $("[data-release-meta]");
  const text =
    kind === "none"
      ? "No release has been published yet. The app will appear here as soon as one is."
      : kind === "limited"
        ? "GitHub is limiting requests from your network right now. The downloads are on the releases page."
        : "The latest release couldn't be looked up just now. The downloads are on the releases page.";
  if (meta) meta.textContent = text;
  const href = kind === "none" ? RELEASES_URL : `${RELEASES_URL}/latest`;
  for (const link of $$("[data-dl-link]")) link.href = href;
  setPrimaryButtons({ href: "#download", label: "Download SQuick Share", note: "" });
}

function render(release, platform, arch) {
  const version = release.version;
  for (const node of $$("[data-release-version]")) node.textContent = `v${version}`;
  const date = formatDate(release.publishedAt);
  const meta = $("[data-release-meta]");
  if (meta)
    meta.textContent = `Version ${version}${date ? `, released ${date}` : ""}. Free for macOS 13 or later.`;

  const onMac = platform === "mac";
  const mine = recommend(release.downloads, arch);
  setNote(onMac ? null : noteFor(platform));

  // One card, a disk image per kind of Mac; the one for this Mac stands out
  // (the universal one when the chip isn't known, or for other visitors).
  for (const opt of $$("[data-build]")) {
    const build = opt.dataset.build;
    const file = release.downloads[build]?.[0];
    const link = $("[data-dl-link]", opt);
    const size = $("[data-dl-size]", opt);
    const badge = $("[data-dl-badge]", opt);
    const picked = mine?.arch === build;
    opt.classList.toggle("is-yours", picked);
    link.classList.toggle("btn--primary", picked);
    if (badge) {
      badge.hidden = !picked;
      badge.textContent = onMac && arch === build ? "This Mac" : "Recommended";
    }
    if (file) {
      link.href = file.url;
      link.setAttribute("download", "");
      link.setAttribute(
        "aria-label",
        `Download SQuick Share for ${BUILDS[build].name}, ${file.name}${file.size ? `, ${file.size}` : ""}`,
      );
      link.title = file.name;
      if (size) size.textContent = file.size;
    } else {
      link.href = RELEASES_URL;
      link.removeAttribute("download");
      if (size) size.textContent = "";
      $("span", link).textContent = "Not in this release";
    }
  }

  const sums = $("[data-release-checksums]");
  if (sums && release.downloads.checksums) {
    sums.href = release.downloads.checksums;
    sums.hidden = false;
  }
  const news = $("[data-release-link]");
  if (news) {
    news.href = release.url;
    news.textContent = `What's new in ${version}`;
  }

  if (onMac && mine) {
    setPrimaryButtons({
      href: mine.url,
      label: "Download for Mac",
      note: `For Mac · ${BUILDS[mine.arch].name} · ${mine.ext}${mine.size ? ` · ${mine.size}` : ""}`,
    });
  } else {
    setPrimaryButtons({
      href: "#download",
      label: "Download for Mac",
      note:
        platform === "android"
          ? "Goes on your Mac · nothing to install on your phone"
          : `Version ${version} · for macOS 13 or later`,
    });
  }
}

export async function initReleases() {
  const platform = detectPlatform({
    userAgent: navigator.userAgent,
    platform: navigator.userAgentData?.platform ?? navigator.platform ?? "",
    maxTouchPoints: navigator.maxTouchPoints ?? 0,
  });
  // Chromium browsers can tell an Apple silicon Mac from an Intel one.
  let arch = null;
  if (platform === "mac" && navigator.userAgentData?.getHighEntropyValues) {
    try {
      const hints = await navigator.userAgentData.getHighEntropyValues(["architecture"]);
      arch = archFromHint(hints.architecture);
    } catch {
      // Not told: the universal build is offered.
    }
  }
  const result = await latestRelease();
  if (result.release) render(result.release, platform, arch);
  else showProblem(result.none ? "none" : result.error);
}
