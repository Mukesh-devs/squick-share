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

## How it stays up to date

- **Version and downloads** are not written in the page. `js/releases.js` asks the GitHub
  Releases API for the latest release in the visitor's browser, sorts its files into Universal,
  Apple silicon and Intel builds (`js/release-assets.js`), and shows its notes. On a Mac it
  offers the disk image for that Mac's chip when the browser says which (Chrome and Edge do),
  else the universal one. Android visitors are told their phone needs nothing. Publishing a
  release updates the site; nothing is deployed again. If GitHub can't be reached, limits
  requests, or there is no release, the page says so and links to the releases page. Without
  JavaScript every download button goes to the latest release on GitHub.
- **The icon** (`assets/icon.svg`, `assets/favicon.svg`) is drawn from the same geometry as
  [`scripts/make-icon.swift`](../scripts/make-icon.swift); change both together. The PNG
  favicons are renders of the SVGs.
- **Screenshots** (`assets/shots/`) are the real app, rendered by
  [`scripts/make-screenshots.sh`](../scripts/make-screenshots.sh) with neutral sample data
  into `docs/images/`. To update them, run that script, then:

  ```bash
  for pair in window-send-busy:hero window-receive-busy:receive window-send:send window-history:history; do
    src=${pair%%:*}; dst=${pair##*:}
    for t in light dark; do
      cwebp -quiet -q 82 -m 6 -resize 1280 0 docs/images/$src-$t.png -o website/assets/shots/$dst-$t-1280.webp
      cwebp -quiet -q 80 -m 6 docs/images/$src-$t.png -o website/assets/shots/$dst-$t-2200.webp
    done
  done
  ```

  Each picture has a light and a dark version (`only-light` / `only-dark`) at 1280 px and at
  the full 2200 px the app renders (2× a 1100-point window). The lightbox shows the largest. The
  hero's callouts point at places in `hero-*`; check them if its layout changes.
- **The numbers** (35 MB/s, 30 MB/s, 1.05 GB in 30 s, 11 files in 14 s, about 1 MiB of
  memory, 81 tests) are the ones in the main README's "Tested and measured" table, measured
  with a real Android phone on 5 GHz Wi-Fi. Change them together.
- **The share image** (`assets/og.png`) is rendered from
  [`scripts/website-og.html`](../scripts/website-og.html) by `node scripts/website-og.mjs`.

## The design

It is the DataLiq site's design system (the same tokens, type, header, sections and motion),
told in SQuick Share's own world instead of a spreadsheet's. The page is your Mac, visible
to the phones around it:

| DataLiq (a spreadsheet) | SQuick Share (sharing nearby) |
| --- | --- |
| Cell grid behind the hero | Discovery rings around the Mac's icon, fading out downward |
| A cell follows the pointer, its column and row light up | The pointer is a phone nearby: it sits on the nearest ring, which lights up, with a beam of data running to the Mac |
| The icon in a "copied" cell with marching ants | The icon at the centre of the rings, sending out a wave every few seconds, with its name and a green "Visible" dot |
| "in seconds." as a selected range with the fill handle | "your Mac." as a transfer: a capsule whose progress bar fills, ending in a check |
| Section labels as cell references (A2 Speed) | Section labels as the menu bar icon's states: a glyph that pings as it arrives |
| The name box in the header | A status chip, like the menu bar icon, with the section in view |
| Headings filled in by a selection dragged by its fill handle | Headings filled in behind a transfer capsule and its progress knob |
| The speed figures as cells with a formula bar | The speed figures as tiles (selected like the app's device tiles) with a transfer row: direction, what, progress |
| The other features as a sheet with row numbers | A grouped macOS list whose icons light up |
| Row numbers of the sections on the left | The sections as a small sidebar, like the app's |

The colour is the app's blue (`AccentColor` in `SquickShare/Assets.xcassets`): `#0074f0` in
light, `#3096ff` in dark. In the light theme the site uses `#0066d6`, one step deeper, because
white text on `#0074f0` is 4.4:1, just under WCAG AA. Every text colour on every background
passes AA in both themes; the browser checks measure it.

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
| `css/site.css` | Tokens, then the pieces, then the sections top to bottom, then motion and breakpoints |
| `js/main.js` | Starts the parts below |
| `js/scroll.js` | Eased wheel scrolling, gliding in-page links, the hero easing away, screenshots un-cropping with the scroll |
| `js/site.js` | Theme, menu, sidebar and status chip, the hero's rings and pointer, reveals, the tilted showcase, the header's progress line, counters, the speed tiles' transfer row, ticker, terminal typing, lightbox, copy button, the footer's fitted wordmark |
| `js/releases.js` | The latest release: lookup, the file for this Mac, one column per build, release notes (sanitized) |
| `js/release-assets.js` | Pure functions: which file is which build, which device and chip the visitor has |
| `404.html`, `robots.txt`, `sitemap.xml`, `site.webmanifest` | For GitHub Pages and search engines |

## Checks

```bash
node --test scripts/website.test.mjs
```

covers the release logic (file names to builds, device and chip detection, only GitHub-hosted
links), that no version or download link is written into the page, that every file the page
names exists, and the basics a page needs to be found and read (one `h1`, alt text, working
in-page links, nothing loaded from other sites).

```bash
npm install --no-save --no-package-lock playwright && npx playwright install chromium
node scripts/website.browser.mjs --shots /tmp/site-shots
```

opens the page at 390, 820, 1440 and 1920 px in light and dark (no sideways scrolling, AA
contrast for every piece of text, every picture loaded, full-width buttons on phones), and
checks the theme toggle, the lightbox, the phone menu, the keyboard, the downloads for Apple
silicon, Intel, unknown Macs, Android and Windows, the release notes' sanitizing, what the page
says when the GitHub API has no release, limits requests or can't be reached, the page without
JavaScript, the reveals with motion on, and the 404 page. GitHub is never called: the answers
are made up. Both run in CI before every deployment.

## Rules the page keeps

- Only features the app has, shown with real screenshots.
- No third-party requests except the GitHub API call: fonts and images are served from here.
- Works without JavaScript (content and a download link), and with reduced motion.
