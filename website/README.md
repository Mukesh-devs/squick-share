# The SQuick Share website

The product site, published at <https://mukesh-devs.github.io/squick-share/> by
[`.github/workflows/website.yml`](../.github/workflows/website.yml) whenever this folder
changes on `main`. Plain HTML, CSS and JavaScript modules: no framework and no build step, so
what is in this folder is what is served.

**One-time setup on GitHub:** Settings › Pages › Build and deployment › Source: **GitHub
Actions**. (Until then Pages keeps serving `docs/` from the branch, as before.)

## Look at it locally

```bash
python3 -m http.server 4321 --directory website
```

Then open <http://localhost:4321/>. (Modules need a server; opening the file directly won't
work.) The 404 page uses absolute `/squick-share/` paths, as on GitHub Pages; the browser
checks below serve the site under that path.

## What's on the page

1. **Hero**: the headline, the download button, and an Android phone sharing three files and a
   link with a Mac, whose screen shows the real request in SQuick Share.
2. **How it works**: a step-by-step guide, with Android or with a Windows PC, to your Mac or
   from it: four guides of three steps. Steps on the Mac show real screenshots; steps on the
   phone or the PC show a simple drawing of Quick Share there. Each step plays like a short
   clip while it's on screen, again every 7 seconds: taps on the phone, the pointer clicking
   on the Mac or the PC, highlights, progress rings, the PIN appearing. No video: the pieces
   are elements (`fx-tap`, `fx-cursor`, `fx-box`, `fx-ring`, `fx-wave`) placed over the
   screenshot in percent of its size, so they stay sharp and follow the theme. With reduced
   motion, or without scripts, each step shows its finished state.
3. **Features**: six short cards.
4. **Privacy**: "0 servers in between", and three cards.
5. **Download**: one card with the Apple silicon, Intel and Universal disk images, then the
   three install steps.
6. **Questions**, then the footer.

The page states no transfer speeds: they depend on each Wi-Fi network (a unit test keeps it
that way).

## How it stays up to date

- **Version and downloads** are not written in the page. `js/releases.js` asks the GitHub
  Releases API for the latest release in the visitor's browser and sorts its disk images into
  Apple silicon, Intel and Universal (`js/release-assets.js`). On a Mac, the build for that
  Mac's chip is highlighted when the browser says which (Chrome and Edge do), else the
  universal one. Android, iPhone and Windows visitors get a short note above the card.
  Publishing a release updates the site; nothing is deployed again. If GitHub can't be
  reached, limits requests, or there is no release, the page says so and the buttons go to the
  releases page. Without JavaScript every download button goes to the latest release on GitHub.
- **The icon** (`assets/icon.svg`, `assets/favicon.svg`) is drawn from the same geometry as
  [`scripts/make-icon.swift`](../scripts/make-icon.swift); change both together. The PNG
  favicons are renders of the SVGs.
- **Screenshots** (`assets/shots/`) are the real app, rendered by
  [`scripts/make-screenshots.sh`](../scripts/make-screenshots.sh) with neutral sample data
  into `docs/images/`. To update them, run that script, then:

  ```bash
  for pair in window-send-busy:hero window-receive-busy:receive window-receive:visible window-send:send window-history:history; do
    src=${pair%%:*}; dst=${pair##*:}
    for t in light dark; do
      cwebp -quiet -q 82 -m 6 -resize 1280 0 docs/images/$src-$t.png -o website/assets/shots/$dst-$t-1280.webp
      cwebp -quiet -q 80 -m 6 docs/images/$src-$t.png -o website/assets/shots/$dst-$t-2200.webp
    done
  done
  ```

  Each picture has a light and a dark version (`only-light` / `only-dark`) at 1280 px and at
  the full 2200 px the app renders (2× a 1100-point window). Clicking a Mac's screen opens the
  largest. The phone's and the PC's screens are drawn in HTML and follow the page's theme.
- **The share image** (`assets/og.png`) is rendered from
  [`scripts/website-og.html`](../scripts/website-og.html) by `node scripts/website-og.mjs`.

## The design

It is the DataLiq site's design system (the same tokens, type, header, sections and motion),
told in SQuick Share's own world instead of a spreadsheet's:

| DataLiq (a spreadsheet) | SQuick Share (sharing nearby) |
| --- | --- |
| Cell grid behind the hero | Discovery rings around the headline, still, fading downward |
| The app's window, tilted | An Android phone sharing with a Mac, both standing behind the ticker |
| "in seconds." as a selected range with the fill handle | "your Mac." as a transfer: a capsule whose progress bar fills, ending in a check |
| Section labels as cell references (A2 Speed) | Section labels as the menu bar icon's states: a glyph that pings as it arrives |
| The name box in the header | A status chip, like the menu bar icon, with the section in view |
| Headings filled in by a selection dragged by its fill handle | Headings filled in behind a transfer capsule and its progress knob |
| Feature articles with screenshots | A guide in steps, one card at a time, with tabs for Android and Windows and for each direction; each step plays like a short clip |
| Row numbers of the sections on the left | The sections as a small sidebar, like the app's |

The colour is the app's blue (`AccentColor` in `SquickShare/Assets.xcassets`): `#0074f0` in
light, `#3096ff` in dark. In the light theme the site uses `#0066d6`, one step deeper, because
white text on `#0074f0` is 4.4:1, just under WCAG AA. Every text colour on every background
passes AA in both themes; the browser checks measure it. The phone is framed in the same blue.

Type is Geist (headings and text) with JetBrains Mono for data (file names, sizes, commands);
both are variable fonts under the SIL Open Font License, served from `assets/fonts/`. Light and
dark follow the system until the visitor picks one with the button in the header (remembered
in the browser, applied before the first paint).

Scrolling is the site's own (`js/scroll.js`, no library): the mouse wheel eases instead of
jumping and in-page links glide, while the browser still does the scrolling (scroll bar,
keyboard, touch and find-in-page behave as usual). With "reduce motion" set, none of the motion
runs and everything is shown at once.

## Files

| | |
| --- | --- |
| `index.html` | The page: every section, in order |
| `css/site.css` | Tokens, then the pieces (header, devices, the drawn Quick Share screens), then the sections top to bottom, then motion and breakpoints |
| `js/main.js` | Starts the parts below |
| `js/scroll.js` | Eased wheel scrolling, gliding in-page links, the hero's copy easing away |
| `js/site.js` | Theme, menu, sidebar and status chip, reveals, the step-by-step guide (tabs, arrows, dots, keys, swipe), the header's progress line, ticker, lightbox, copy button, the footer's fitted wordmark |
| `js/releases.js` | The latest release: lookup, the download card, the buttons |
| `js/release-assets.js` | Pure functions: which file is which build, which device and chip the visitor has |
| `404.html`, `robots.txt`, `sitemap.xml`, `site.webmanifest` | For GitHub Pages and search engines |

## Checks

```bash
node --test scripts/website.test.mjs
```

covers the release logic (file names to builds, device and chip detection, only GitHub-hosted
links), that no version, download link or transfer speed is written into the page, that every
file the page names exists, and the basics a page needs to be found and read (one `h1`, alt
text, working in-page links, nothing loaded from other sites).

```bash
npm install --no-save --no-package-lock playwright && npx playwright install chromium
node scripts/website.browser.mjs --shots /tmp/site-shots
```

opens the page at 390, 820, 1440 and 1920 px in light and dark (no sideways scrolling, AA
contrast for every piece of text, every picture loaded, full-width buttons on phones), and
checks the theme toggle, the lightbox, the phone menu, the keyboard, the guide (one step at a
time, tabs, arrows, dots, keys), the download card for Apple silicon, Intel, unknown Macs,
Android and Windows, what the page says when the GitHub API has no release, limits requests or
can't be reached, the page without JavaScript (every step listed), the reveals with motion on,
and the 404 page. GitHub is never called: the answers are made up. Both run in CI before every
deployment.

## Rules the page keeps

- Only features the app has. The Mac always shows real screenshots; the phone and PC drawings
  only show what Quick Share does there.
- No transfer speeds: they depend on the network.
- No third-party requests except the GitHub API call: fonts and images are served from here.
- Works without JavaScript (content, every step, and download links), and with reduced motion.
