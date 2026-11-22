// Browser checks for the website, with Playwright:
//   npm install --no-save playwright && npx playwright install chromium
//   node scripts/website.browser.mjs [--shots DIR]
// Serves website/ under /squick-share/ (as GitHub Pages does) and checks the page at
// phone, tablet, laptop and desktop widths in both themes, the theme toggle, the
// lightbox, the menu, the downloads for each kind of visitor, what happens when the
// GitHub API fails, and the page without JavaScript. The GitHub API is never called:
// every answer is made up here. With --shots, saves full-page screenshots.
import assert from "node:assert/strict";
import { createReadStream, existsSync, mkdirSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "website");
const args = process.argv.slice(2);
const shots = args.includes("--shots") ? args[args.indexOf("--shots") + 1] : null;
if (shots) mkdirSync(shots, { recursive: true });

/* ----------------------------------------------- a GitHub Pages stand-in */
const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css",
  ".js": "text/javascript",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".webp": "image/webp",
  ".woff2": "font/woff2",
  ".webmanifest": "application/manifest+json",
  ".xml": "application/xml",
  ".txt": "text/plain",
};
const server = createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url, "http://x").pathname);
  let file = null;
  if (path.startsWith("/squick-share/")) {
    file = normalize(join(root, path.slice("/squick-share/".length)));
    if (!file.startsWith(root)) file = null;
    else if (existsSync(file) && statSync(file).isDirectory()) file = join(file, "index.html");
  }
  if (!file || !existsSync(file)) {
    res.writeHead(404, { "content-type": TYPES[".html"] });
    return createReadStream(join(root, "404.html")).pipe(res);
  }
  res.writeHead(200, { "content-type": TYPES[extname(file)] ?? "application/octet-stream" });
  createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const BASE = `http://127.0.0.1:${server.address().port}/squick-share/`;

/* ------------------------------------------------- made-up API answers */
const dl = (name) => `https://github.com/Mukesh-devs/squick-share/releases/download/v9.8.7/${name}`;
const asset = (name, size) => ({ name, size, browser_download_url: dl(name) });
const RELEASE = {
  tag_name: "v9.8.7",
  name: "SQuick Share v9.8.7",
  html_url: "https://github.com/Mukesh-devs/squick-share/releases/tag/v9.8.7",
  published_at: "2026-11-15T17:00:21Z",
  body_html:
    '<h2>Download</h2><p>Pick a <strong>disk image</strong>.</p><script>window.hacked=1</script><img src=x onerror="window.hacked=1"><a href="javascript:window.hacked=1">bad</a><table><tr><td>File</td></tr></table>',
  assets: ["universal", "arm64", "x86_64"].flatMap((a) => [
    asset(`squick-share-9.8.7-${a}.dmg`, 4_000_000),
    asset(`squick-share-9.8.7-${a}.zip`, 3_500_000),
  ]),
};
const answers = {
  ok: (route) => route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(RELEASE) }),
  none: (route) => route.fulfill({ status: 404, contentType: "application/json", body: '{"message":"Not Found"}' }),
  limited: (route) => route.fulfill({ status: 403, contentType: "application/json", body: '{"message":"rate limit"}' }),
  offline: (route) => route.abort("internetdisconnected"),
};

const UA = {
  mac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36",
  android: "Mozilla/5.0 (Linux; Android 14; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Mobile Safari/537.36",
  windows: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36",
};

const browser = await chromium.launch(process.env.PW_CHANNEL ? { channel: process.env.PW_CHANNEL } : {});
let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`✔ ${name}`);
  } catch (e) {
    failures++;
    const detail = e.actual !== undefined ? JSON.stringify(e.actual, null, 1) : String(e.stack ?? e).split("\n").slice(0, 4).join("\n  ");
    console.log(`✖ ${name}\n  ${e.message.split("\n")[0]}\n  ${detail}`);
  }
}

/**
 * A page with the API answering `api`, as the given visitor. `arch` stands in for
 * what a Chromium browser says about the Mac's chip ("arm", "x86"), or null for a
 * browser that doesn't say (Safari, Firefox).
 */
async function open({ width = 1440, theme = "light", api = "ok", ua = "mac", arch = null, js = true, motion = "reduce" } = {}) {
  const context = await browser.newContext({
    viewport: { width, height: 900 },
    colorScheme: theme,
    reducedMotion: motion,
    javaScriptEnabled: js,
    userAgent: UA[ua],
    hasTouch: ua === "android",
    isMobile: ua === "android",
  });
  // The visitor's platform and chip, whatever machine runs the checks.
  const platform = { mac: "MacIntel", android: "Linux armv8l", windows: "Win32" }[ua];
  await context.addInitScript(([arch, platform]) => {
    const hints = arch ? { getHighEntropyValues: async () => ({ architecture: arch }), platform: "macOS" } : undefined;
    Object.defineProperty(Navigator.prototype, "userAgentData", { get: () => hints, configurable: true });
    Object.defineProperty(Navigator.prototype, "platform", { get: () => platform, configurable: true });
  }, [arch, platform]);
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => m.type() === "error" && !/api\.github\.com|Failed to load resource/.test(m.text()) && errors.push(m.text()));
  await page.route("https://api.github.com/**", answers[api]);
  await page.goto(BASE, { waitUntil: "networkidle" });
  if (js) await page.waitForFunction(() => !document.querySelector(".rec__loading"));
  return { page, context, errors };
}

/* ------------------------------------------- every width, both themes */
// Text against what is behind it, for every visible piece of text: WCAG AA.
async function contrastProblems(page) {
  return page.evaluate(() => {
    const parse = (c) => {
      const m = c.match(/rgba?\(([^)]+)\)/);
      if (!m) return null;
      const [r, g, b, a = 1] = m[1].split(/[ ,/]+/).filter(Boolean).map(Number);
      return { r, g, b, a };
    };
    const lum = ({ r, g, b }) => {
      const f = (v) => ((v /= 255) <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
      return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
    };
    const over = (top, under) => ({
      r: top.r * top.a + under.r * (1 - top.a),
      g: top.g * top.a + under.g * (1 - top.a),
      b: top.b * top.a + under.b * (1 - top.a),
      a: 1,
    });
    // The backgrounds painted behind an element, from the page up.
    const behind = (el) => {
      const layers = [];
      for (let n = el; n; n = n.parentElement) {
        const s = getComputedStyle(n);
        const c = parse(s.backgroundColor);
        if (c && c.a > 0) layers.push(c);
        // The always-dark speed section paints a gradient over its own colour.
        if (n.classList?.contains("speed")) layers.push({ r: 8, g: 11, b: 20, a: 1 });
        if (c && c.a === 1) break;
      }
      let color = parse(getComputedStyle(document.body).backgroundColor);
      for (const layer of layers.reverse()) color = over(layer, color);
      return color;
    };
    const problems = [];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const seen = new Set();
    for (let t = walker.nextNode(); t; t = walker.nextNode()) {
      const el = t.parentElement;
      if (!t.textContent.trim() || seen.has(el)) continue;
      seen.add(el);
      if (el.closest("[aria-hidden='true'], .sprite, script, style, noscript, dialog:not([open]), .footer__mark")) continue;
      const r = el.getBoundingClientRect();
      const s = getComputedStyle(el);
      if (!r.width || !r.height || s.visibility === "hidden" || +s.opacity === 0) continue;
      const fg = parse(s.color);
      if (!fg || fg.a === 0) continue;
      const bg = behind(el);
      const L1 = lum(over(fg, bg));
      const L2 = lum(bg);
      const ratio = (Math.max(L1, L2) + 0.05) / (Math.min(L1, L2) + 0.05);
      const size = parseFloat(s.fontSize);
      const large = size >= 24 || (size >= 18.66 && +s.fontWeight >= 700);
      if (ratio < (large ? 3 : 4.5))
        problems.push(`${ratio.toFixed(2)} "${t.textContent.trim().slice(0, 40)}" (${el.className || el.tagName})`);
    }
    return problems;
  });
}

for (const width of [390, 820, 1440, 1920]) {
  for (const theme of ["light", "dark"]) {
    await check(`${width} px, ${theme}: no sideways scrolling, nothing cut off, AA contrast`, async () => {
      const { page, context, errors } = await open({ width, theme });
      // Scroll through so every lazy picture loads.
      const height = await page.evaluate(() => document.documentElement.scrollHeight);
      for (let y = 0; y < height; y += 600) {
        await page.evaluate((y) => scrollTo(0, y), y);
        await page.waitForTimeout(40);
      }
      await page.evaluate(() => scrollTo(0, 0));
      await page.waitForLoadState("networkidle");
      await page.waitForFunction(() => [...document.images].every((i) => !i.offsetParent || i.complete));
      assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), theme);
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - innerWidth);
      assert.ok(overflow <= 0, `the page is ${overflow}px wider than the window`);
      // Nothing sticks out of the page sideways (the ticker and the wordmark clip on purpose).
      const wide = await page.evaluate(() =>
        [...document.querySelectorAll("main *, .nav *, .footer *")]
          .filter((el) => !el.closest(".ticker, .footer__mark, .sprite, .callouts, .term__body, .field") && el.getClientRects().length)
          .filter((el) => {
            const r = el.getBoundingClientRect();
            return r.right > innerWidth + 1 || r.left < -1;
          })
          .map((el) => el.className || el.tagName)
          .slice(0, 5),
      );
      assert.deepEqual(wide, []);
      assert.deepEqual(await contrastProblems(page), []);
      // Every picture has loaded, in this theme's version.
      const broken = await page.evaluate(() =>
        [...document.images].filter((i) => i.offsetParent && (!i.complete || !i.naturalWidth)).map((i) => i.src),
      );
      assert.deepEqual(broken, []);
      if (width <= 640) {
        const buttons = await page.$$eval(".hero__actions .btn", (b) => b.map((x) => x.getBoundingClientRect().width));
        const box = await page.$eval(".hero__actions", (x) => x.getBoundingClientRect().width);
        assert.ok(buttons.every((w) => Math.abs(w - box) < 1), "phone buttons are full width");
      }
      if (shots) await page.screenshot({ path: join(shots, `site-${width}-${theme}.png`), fullPage: true });
      assert.deepEqual(errors, []);
      await context.close();
    });
  }
}

/* ------------------------------------------------------------ features */
await check("one h1, and every picture has alt text", async () => {
  const { page, context } = await open();
  assert.equal(await page.locator("h1").count(), 1);
  assert.equal(await page.locator("img:not([alt])").count(), 0);
  await context.close();
});

await check("the theme toggle switches and is remembered", async () => {
  const { page, context } = await open({ theme: "light" });
  const toggle = page.locator("[data-theme-toggle]");
  assert.equal(await toggle.getAttribute("aria-label"), "Switch to dark theme");
  await toggle.click();
  assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), "dark");
  await page.reload({ waitUntil: "networkidle" });
  assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), "dark");
  assert.equal(await toggle.getAttribute("aria-label"), "Switch to light theme");
  assert.ok(await page.locator(".showcase img.only-dark").isVisible());
  assert.ok(!(await page.locator(".showcase img.only-light").isVisible()));
  await context.close();
});

await check("a screenshot opens full size, and closes with Escape", async () => {
  const { page, context } = await open();
  await page.locator(".showcase [data-zoom]").click();
  const dialog = page.locator("[data-lightbox]");
  assert.ok(await dialog.evaluate((d) => d.open));
  assert.match(await page.locator("[data-lightbox-img]").getAttribute("src"), /hero-light-2200\.webp$/);
  await page.keyboard.press("Escape");
  assert.ok(!(await dialog.evaluate((d) => d.open)));
  await context.close();
});

await check("the phone menu opens, moves focus, and closes with Escape", async () => {
  const { page, context } = await open({ width: 390 });
  const toggle = page.locator("[data-menu-toggle]");
  const menu = page.locator("[data-menu]");
  assert.ok(!(await menu.isVisible()));
  await toggle.click();
  assert.ok(await menu.isVisible());
  assert.equal(await toggle.getAttribute("aria-expanded"), "true");
  assert.equal(await page.evaluate(() => document.activeElement.textContent.trim()), "Features");
  await page.keyboard.press("Escape");
  assert.ok(!(await menu.isVisible()));
  assert.equal(await toggle.getAttribute("aria-expanded"), "false");
  await toggle.click();
  await menu.getByText("Install").click();
  assert.ok(!(await menu.isVisible()), "following a link closes the menu");
  await context.close();
});

await check("the keyboard reaches the skip link first, with a visible focus ring", async () => {
  const { page, context } = await open();
  await page.keyboard.press("Tab");
  await page.waitForTimeout(50); // reduced motion still runs a 0.01 ms transition
  const skip = await page.evaluate(() => {
    const a = document.activeElement;
    const r = a.getBoundingClientRect();
    return { text: a.textContent, top: r.top };
  });
  assert.equal(skip.text, "Skip to content");
  assert.ok(skip.top >= 0, `the skip link shows when focused (top ${skip.top})`);
  await page.keyboard.press("Tab");
  const ring = await page.evaluate(() => getComputedStyle(document.activeElement).outlineStyle);
  assert.notEqual(ring, "none");
  await context.close();
});

/* ----------------------------------------------- downloads, per visitor */
const primaryHrefs = (page) => page.$$eval("[data-download-primary]", (a) => a.map((x) => x.href));

await check("an Apple silicon Mac is offered the Apple silicon disk image", async () => {
  const { page, context } = await open({ arch: "arm" });
  for (const href of await primaryHrefs(page)) assert.equal(href, dl("squick-share-9.8.7-arm64.dmg"));
  assert.equal(await page.locator("[data-release-version]").first().textContent(), "v9.8.7");
  assert.match(await page.locator(".rec__title").textContent(), /Apple silicon/);
  assert.ok(await page.locator('[data-build="arm64"] [data-build-badge]').isVisible());
  assert.match(await page.locator("[data-download-note]").textContent(), /Apple silicon · \.dmg · 4\.0 MB/);
  await context.close();
});

await check("an Intel Mac gets the Intel build; a Mac that doesn't say gets the universal one", async () => {
  let { page, context } = await open({ arch: "x86" });
  assert.equal((await primaryHrefs(page))[0], dl("squick-share-9.8.7-x86_64.dmg"));
  await context.close();
  ({ page, context } = await open({ arch: null }));
  for (const href of await primaryHrefs(page)) assert.equal(href, dl("squick-share-9.8.7-universal.dmg"));
  assert.equal(await page.locator("[data-build-badge]:visible").count(), 0, "no 'This Mac' when it isn't known");
  assert.ok(await page.locator('[data-build="universal"].is-yours').count());
  await context.close();
});

await check("an Android phone is told it needs nothing, and every file is listed", async () => {
  const { page, context } = await open({ width: 390, ua: "android" });
  assert.match(await page.locator(".rec__title").textContent(), /already has Quick Share/);
  for (const href of await primaryHrefs(page)) assert.match(href, /#download$/);
  assert.equal(await page.locator("[data-build] .btn--primary").count(), 3);
  await context.close();
});

await check("a Windows computer is told SQuick Share is a Mac app", async () => {
  const { page, context } = await open({ ua: "windows" });
  assert.match(await page.locator(".rec__title").textContent(), /is a Mac app/);
  await context.close();
});

await check("release notes are shown, with anything unsafe removed", async () => {
  const { page, context } = await open();
  const notes = page.locator("[data-release-notes]");
  assert.ok(await notes.isVisible());
  await notes.locator("summary").click();
  const html = await page.locator("[data-release-body]").innerHTML();
  assert.match(html, /<h4>Download<\/h4>/);
  assert.match(html, /<strong>disk image<\/strong>/);
  assert.doesNotMatch(html, /script|onerror|<img|javascript:/i);
  assert.equal(await page.evaluate(() => window.hacked), undefined);
  await context.close();
});

for (const [api, text, link] of [
  ["none", /No release has been published yet/, /\/releases$/],
  ["limited", /limiting requests/, /\/releases\/latest$/],
  ["offline", /couldn't be looked up/, /\/releases\/latest$/],
]) {
  await check(`when the GitHub API says "${api}", the page says so and links to the releases`, async () => {
    const { page, context, errors } = await open({ api });
    assert.match(await page.locator("[data-release-meta]").textContent(), text);
    assert.match(await page.locator(".rec .btn").getAttribute("href"), link);
    assert.ok(!(await page.locator("[data-builds]").isVisible()));
    for (const href of await primaryHrefs(page)) assert.match(href, /#download$/);
    assert.deepEqual(errors, []);
    await context.close();
  });
}

await check("without JavaScript, everything is readable and downloads go to the releases", async () => {
  const { page, context } = await open({ js: false, motion: "no-preference" });
  for (const sel of ["h1", ".hero__lead", "#features .feature h3", ".list li", ".faq summary", ".showcase img.only-light"]) {
    const el = page.locator(sel).first();
    assert.ok(await el.isVisible(), `${sel} is visible`);
    assert.equal(await el.evaluate((e) => getComputedStyle(e).opacity), "1", `${sel} is not faded out`);
  }
  for (const href of await primaryHrefs(page))
    assert.equal(href, "https://github.com/Mukesh-devs/squick-share/releases/latest");
  assert.ok(await page.locator("noscript").count());
  assert.ok(!(await page.locator("[data-rec]").isVisible()), "the lookup panel is hidden");
  await context.close();
});

await check("with motion allowed, the reveals run and nothing stays hidden", async () => {
  const { page, context, errors } = await open({ motion: "no-preference" });
  const height = await page.evaluate(() => document.documentElement.scrollHeight);
  for (let y = 0; y < height; y += 500) {
    await page.mouse.wheel(0, 500);
    await page.waitForTimeout(60);
  }
  await page.waitForTimeout(2200);
  const hidden = await page.$$eval(".reveal:not(.in), .sweep:not(.in), [data-fill]:not(.in)", (els) => els.map((e) => e.className));
  assert.deepEqual(hidden, []);
  assert.ok(await page.evaluate(() => scrollY > 1000), "the wheel scrolls the page");
  assert.deepEqual(errors, []);
  await context.close();
});

await check("unknown addresses get the 404 page, which links home", async () => {
  const context = await browser.newContext();
  const page = await context.newPage();
  const res = await page.goto(`${BASE}nope`);
  assert.equal(res.status(), 404);
  await page.getByText("Go to the SQuick Share home page").click();
  await page.waitForURL(BASE);
  await context.close();
});

await browser.close();
server.close();
console.log(failures ? `\n${failures} check(s) failed` : "\nAll browser checks passed");
process.exit(failures ? 1 : 0);
