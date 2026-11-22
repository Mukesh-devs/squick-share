// The download section and buttons, filled from the latest GitHub release.
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

function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") node.className = v;
    else if (k === "text") node.textContent = v;
    else node.setAttribute(k, v);
  }
  for (const c of [].concat(children)) if (c) node.append(c);
  return node;
}

function icon(id) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS("http://www.w3.org/2000/svg", "use");
  use.setAttribute("href", `#${id}`);
  svg.append(use);
  return svg;
}

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
      // "full" adds the notes as HTML rendered by GitHub.
      headers: { Accept: "application/vnd.github.full+json" },
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

const ALLOWED = new Set([
  "P",
  "UL",
  "OL",
  "LI",
  "STRONG",
  "B",
  "EM",
  "I",
  "CODE",
  "PRE",
  "BR",
  "BLOCKQUOTE",
  "HR",
  "DEL",
  "A",
  "TABLE",
  "THEAD",
  "TBODY",
  "TR",
  "TH",
  "TD",
]);
const HEADINGS = new Set(["H1", "H2", "H3", "H4", "H5", "H6"]);
const DROPPED = new Set([
  "SCRIPT",
  "STYLE",
  "IFRAME",
  "OBJECT",
  "EMBED",
  "TEMPLATE",
  "SVG",
  "MATH",
  "HEAD",
  "TITLE",
  "IMG",
  "VIDEO",
  "AUDIO",
  "FORM",
]);

/**
 * Release notes as safe DOM: only text, lists, tables, emphasis, code and
 * links to web pages survive, without any attributes but a link's address;
 * everything else is unwrapped or dropped. The notes are written by the
 * project, but they still arrive over the network.
 */
export function sanitizeNotes(html) {
  const doc = new DOMParser().parseFromString(String(html), "text/html");
  const copy = (from, to) => {
    for (const node of from.childNodes) {
      if (node.nodeType === Node.TEXT_NODE) {
        to.append(document.createTextNode(node.textContent));
        continue;
      }
      if (node.nodeType !== Node.ELEMENT_NODE || DROPPED.has(node.tagName.toUpperCase())) continue;
      const tag = node.tagName.toUpperCase();
      let target = to;
      if (HEADINGS.has(tag)) target = to.appendChild(document.createElement("h4"));
      else if (ALLOWED.has(tag)) {
        target = document.createElement(tag.toLowerCase());
        if (tag === "A") {
          let href = null;
          try {
            const u = new URL(node.getAttribute("href") ?? "", RELEASES_URL);
            if (u.protocol === "https:" || u.protocol === "http:") href = u.href;
          } catch {
            // Not a link we show.
          }
          if (!href) target = document.createElement("span");
          else {
            target.setAttribute("href", href);
            target.setAttribute("rel", "noopener nofollow");
          }
        }
        to.append(target);
      }
      copy(node, target);
    }
  };
  const out = document.createDocumentFragment();
  copy(doc.body, out);
  return out;
}

function notesFragment(release) {
  if (release.notesHtml.trim()) {
    const frag = sanitizeNotes(release.notesHtml);
    if (frag.textContent.trim()) return frag;
  }
  // Plain text, one paragraph per blank-line block.
  const frag = document.createDocumentFragment();
  for (const block of release.notesText.split(/\n\s*\n/)) {
    if (block.trim()) frag.append(el("p", { text: block.trim() }));
  }
  return frag;
}

/* ------------------------------------------------ the recommended file */
function recPanel({ iconId, kicker, title, meta, action }) {
  const rec = $("[data-rec]");
  if (!rec) return;
  rec.classList.toggle("rec--plain", !action);
  rec.replaceChildren(
    el("span", { class: "rec__icon" }, [icon(iconId)]),
    el("div", { class: "rec__text" }, [
      el("p", { class: "rec__kicker", text: kicker }),
      el("h3", { class: "rec__title", text: title }),
      meta ? el("p", { class: "rec__meta" }, meta) : null,
    ]),
    ...(action ? [action] : []),
  );
}

function downloadButton(d, strong = true) {
  return el(
    "a",
    { class: strong ? "btn btn--primary" : "btn", href: d.url, rel: "noopener", download: "" },
    [
      icon("i-download"),
      el("span", { text: `Download ${d.ext}` }),
      d.size ? el("small", { text: d.size }) : null,
    ],
  );
}

function linkButton(href, text, iconId = "i-out") {
  return el("a", { class: "btn", href, rel: "noopener" }, [icon(iconId), el("span", { text })]);
}

/* -------------------------------------------- one column per kind of Mac */
/** A build's disk image: what it is, its file name, a full-width button. */
function mainBlock(d, strong) {
  return [
    el("p", { class: "build__kind" }, [
      el("b", { text: d.kind }),
      el("span", { class: "build__chip", text: "Recommended" }),
    ]),
    el("p", { class: "build__detail", text: d.what }),
    el("code", { class: "build__name", text: d.name, title: d.name }),
    downloadButton(d, strong),
  ];
}

/** One of a build's other files: a row you click to download. */
function fileRow(d) {
  return el(
    "a",
    {
      class: "build__file",
      href: d.url,
      rel: "noopener",
      download: "",
      "aria-label": `Download the ${BUILDS[d.arch].name} ${d.kind.toLowerCase()}${d.size ? `, ${d.size}` : ""}`,
    },
    [
      el("span", { class: "build__text" }, [
        el("b", { text: d.kind }),
        el("span", { text: d.what }),
        el("small", { text: d.name, title: d.name }),
      ]),
      el("span", { class: "build__get" }, [
        d.size ? el("small", { text: d.size }) : null,
        icon("i-download"),
      ]),
    ],
  );
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
  recPanel({
    iconId: "i-download",
    kicker: kind === "none" ? "Coming soon" : "On GitHub",
    title: "Get the app from GitHub",
    meta: [el("span", { text: "Disk images for every Mac, on the project's releases page." })],
    action: linkButton(href, kind === "none" ? "Releases" : "Latest release"),
  });
  const builds = $("[data-builds]");
  if (builds) builds.hidden = true;
  setPrimaryButtons({ href: "#download", label: "Download SQuick Share", note: "" });
}

/** The panel at the top of the downloads, for visitors not on a Mac. */
function elsewhere(platform) {
  if (platform === "android")
    return {
      iconId: "i-phone",
      kicker: "On your phone",
      title: "Your phone already has Quick Share",
      meta: [
        el("span", {
          text: "Nothing to install on Android. SQuick Share goes on your Mac: open this page there, or pick a file below.",
        }),
      ],
    };
  if (platform === "ios")
    return {
      iconId: "i-phone",
      kicker: "On an iPhone or iPad",
      title: "SQuick Share is for Macs",
      meta: [
        el("span", {
          text: "It lets a Mac share with Android phones. Open this page on your Mac to download it.",
        }),
      ],
    };
  return {
    iconId: "i-apple",
    kicker: platform === "windows" || platform === "linux" ? "Your computer" : "For Mac",
    title: "SQuick Share is a Mac app",
    meta: [el("span", { text: "For macOS 13 or later. Pick the build for your Mac below." })],
  };
}

function render(release, platform, arch) {
  const version = release.version;
  for (const node of $$("[data-release-version]")) node.textContent = `v${version}`;
  const date = formatDate(release.publishedAt);
  const meta = $("[data-release-meta]");
  if (meta)
    meta.textContent = `Version ${version}${date ? `, released ${date}` : ""}. For macOS 13 or later.`;

  // The file for this Mac, with one big button.
  const onMac = platform === "mac";
  const mine = recommend(release.downloads, arch);
  if (onMac && mine) {
    const build = BUILDS[mine.arch];
    recPanel({
      iconId: "i-apple",
      kicker: arch ? "Recommended for this Mac" : "Recommended for any Mac",
      title: `SQuick Share for Mac · ${build.name}`,
      meta: [el("span", { text: `${mine.kind} · ${build.detail}` }), el("code", { text: mine.name })],
      action: downloadButton(mine),
    });
  } else if (!release.hasDownloads) {
    recPanel({
      iconId: "i-apple",
      kicker: `Version ${version}`,
      title: "This release has no app files",
      meta: [el("span", { text: "Earlier releases have them." })],
      action: linkButton(RELEASES_URL, "All releases"),
    });
  } else {
    recPanel({ ...elsewhere(platform), action: null });
  }

  // Then every kind of Mac in its own column: its disk image, then the rest.
  for (const card of $$("[data-build]")) {
    const name = card.dataset.build;
    const items = release.downloads[name] ?? [];
    const yours = onMac && arch === name;
    const strong = onMac && mine?.arch === name;
    card.classList.toggle("is-yours", strong);
    const badge = $("[data-build-badge]", card);
    if (badge) badge.hidden = !yours;
    const main = $("[data-build-main]", card);
    const more = $("[data-build-more]", card);
    if (items.length === 0) {
      main.replaceChildren(
        el("p", { class: "build__wait" }, [
          document.createTextNode(`This release has no ${BUILDS[name].name} build. `),
          el("a", { href: RELEASES_URL, rel: "noopener", text: "See earlier releases" }),
        ]),
      );
      more.hidden = true;
      continue;
    }
    // The button is strong on the build offered to this Mac, or on every
    // column when the visitor isn't on a Mac.
    main.replaceChildren(...mainBlock(items[0], strong || !onMac));
    $("[data-build-list]", more).replaceChildren(...items.slice(1).map(fileRow));
    more.hidden = items.length < 2;
  }

  const sums = $("[data-release-checksums]");
  if (sums && release.downloads.checksums) {
    sums.href = release.downloads.checksums;
    sums.hidden = false;
  }

  const notes = $("[data-release-notes]");
  const frag = notesFragment(release);
  if (notes && frag.textContent.trim()) {
    $("[data-release-body]", notes).replaceChildren(frag);
    $("[data-release-name]", notes).textContent = `version ${version}`;
    $("[data-release-link]", notes).href = release.url;
    notes.hidden = false;
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
  // A release without app files (source only) still shows, with its links.
  if (result.release) render(result.release, platform, arch);
  else showProblem(result.none ? "none" : result.error);
}
