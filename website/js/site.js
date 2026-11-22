// The page's behaviour. Everything here is an enhancement: the content and
// the download links work without it.

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
const reduced = () => matchMedia("(prefers-reduced-motion: reduce)").matches;
const finePointer = () => matchMedia("(hover: hover) and (pointer: fine)").matches;

/** Runs `fn` at most once a frame. */
function perFrame(fn) {
  let queued = false;
  return () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      fn();
    });
  };
}

/* ------------------------------------------------------------- theme */
function theme() {
  const root = document.documentElement;
  const button = $("[data-theme-toggle]");
  const label = () =>
    button?.setAttribute(
      "aria-label",
      root.dataset.theme === "dark" ? "Switch to light theme" : "Switch to dark theme",
    );
  label();
  button?.addEventListener("click", () => {
    root.dataset.theme = root.dataset.theme === "dark" ? "light" : "dark";
    try {
      localStorage.setItem("squick-share.site.theme", root.dataset.theme);
    } catch {
      // Remembered for this page only.
    }
    label();
  });
}

/* --------------------------------------------------------------- nav */
function nav() {
  const menu = $("[data-menu]");
  const toggle = $("[data-menu-toggle]");
  const close = () => {
    menu?.classList.remove("is-open");
    toggle?.setAttribute("aria-expanded", "false");
  };
  toggle?.addEventListener("click", () => {
    const open = !menu.classList.contains("is-open");
    menu.classList.toggle("is-open", open);
    toggle.setAttribute("aria-expanded", String(open));
    if (open) $("a", menu)?.focus();
  });
  menu?.addEventListener("click", (e) => e.target.closest("a") && close());
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape" || !menu?.classList.contains("is-open")) return;
    close();
    toggle?.focus();
  });
  document.addEventListener("click", (e) => {
    if (menu?.classList.contains("is-open") && !e.target.closest("[data-nav]")) close();
  });

  // The section in view lights up in the menu and in the sidebar.
  const links = new Map();
  for (const a of $$('.nav__links a[href^="#"], [data-rail] a'))
    links.set(a, a.getAttribute("href").slice(1));
  const sections = $$("main > section[id]");
  const box = $("[data-namebox]");
  let shown = "top";
  const mark = (id) => {
    for (const [a, target] of links) {
      const on = target === id || (target === "install" && id === "download");
      a.classList.toggle("is-on", on);
      if (a.closest("[data-rail]")) a.toggleAttribute("aria-current", on);
    }
    if (!box || id === shown) return;
    shown = id;
    // The section's own glyph and name, like the menu bar icon's state.
    const section = document.getElementById(id);
    const glyph = $(".eyebrow__ref svg", section);
    $("[data-namebox-ref]", box).replaceChildren(
      glyph ? glyph.cloneNode(true) : $("[data-rail] svg").cloneNode(true),
    );
    $("[data-namebox-name]", box).textContent =
      $(".eyebrow__name", section)?.textContent ?? "Visible";
    box.classList.remove("is-swap");
    void box.offsetWidth; // restart the animation
    box.classList.add("is-swap");
  };
  const io = new IntersectionObserver(
    (entries) => {
      const seen = entries.filter((e) => e.isIntersecting);
      if (seen.length)
        mark(seen.sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0].target.id);
    },
    { rootMargin: "-35% 0px -55% 0px", threshold: [0, 0.2, 0.6] },
  );
  for (const s of sections) io.observe(s);

  // The sidebar shows once the hero has scrolled away.
  const rail = $("[data-rail]");
  const hero = $("[data-field]");
  if (rail && hero)
    new IntersectionObserver(([e]) => rail.classList.toggle("is-shown", !e.isIntersecting), {
      rootMargin: "-30% 0px 0px 0px",
    }).observe(hero);
}

/* ------------------------------- the hero: the Mac and the phones nearby */
/**
 * The rings are centred on the app's icon. With a mouse, the pointer is a
 * phone nearby: it snaps to the nearest ring, which lights up, and a beam
 * of data runs from it to the Mac.
 */
function field() {
  const box = $("[data-field]");
  if (!box) return;
  const center = $("[data-field-center]", box);
  const ring = $("[data-field-ring]", box);
  const beam = $("[data-field-beam]", box);
  const device = $("[data-field-device]", box);
  const tag = $("[data-field-tag]", box);
  let cx = 0;
  let cy = 0;
  let step = 78;

  const place = () => {
    step = parseFloat(getComputedStyle(box).getPropertyValue("--step")) || 78;
    const b = box.getBoundingClientRect();
    const c = center?.offsetParent ? center.getBoundingClientRect() : null;
    if (c && c.width) {
      // The icon floats; take its resting centre.
      cx = c.left + c.width / 2 - b.left;
      cy = c.top + c.height / 2 - b.top;
      box.style.setProperty("--cx", `${cx.toFixed(1)}px`);
      box.style.setProperty("--cy", `${cy.toFixed(1)}px`);
    } else {
      box.style.removeProperty("--cx");
      box.style.removeProperty("--cy");
      const s = getComputedStyle(box);
      const read = (v, total) => (v.endsWith("%") ? (parseFloat(v) / 100) * total : parseFloat(v));
      cx = read(s.getPropertyValue("--cx").trim(), b.width);
      cy = read(s.getPropertyValue("--cy").trim(), b.height);
    }
  };
  place();
  new ResizeObserver(perFrame(place)).observe(box);
  document.fonts?.ready.then(place);

  if (!finePointer() || !ring || !device) return;
  let last = "";
  box.addEventListener("pointermove", (e) => {
    const b = box.getBoundingClientRect();
    const x = e.clientX - b.left - cx;
    const y = e.clientY - b.top - cy;
    const d = Math.hypot(x, y) || 1;
    const k = Math.max(1, Math.round(d / step));
    const r = k * step;
    const angle = Math.atan2(y, x);
    const dx = cx + Math.cos(angle) * r;
    const dy = cy + Math.sin(angle) * r;
    box.classList.add("is-live");
    box.classList.toggle("is-near", k === 1);
    box.style.setProperty("--ring-r", `${r}px`);
    beam.style.setProperty("--beam", `${r}px`);
    // The beam points from the Mac to the phone; its dashes run inward.
    beam.style.setProperty("--angle", `${angle}rad`);
    device.style.setProperty("--dx", `${dx.toFixed(1)}px`);
    device.style.setProperty("--dy", `${dy.toFixed(1)}px`);
    const text = k === 1 ? "Sharing…" : k <= 3 ? "Nearby" : "Your phone";
    if (text !== last) tag.textContent = last = text;
  });
  box.addEventListener("pointerleave", () => {
    box.classList.remove("is-live", "is-near");
  });
}

/* ------------------------------------------------------------ reveals */
/**
 * Three kinds, all run once as they come into view:
 * `.reveal` rises into focus; `.sweep` (headings) is filled in behind a
 * transfer capsule that runs across; `[data-fill]` shows its rows one after
 * another, like files arriving.
 */
function reveals() {
  for (const h of $$(".sweep")) {
    const text = document.createElement("span");
    text.className = "sweep__text";
    text.append(...h.childNodes);
    h.append(text);
  }
  const items = $$(".reveal, .sweep, [data-fill]");
  // The capsule hugs the longest line, not the heading's whole width.
  const hug = (h) => {
    const range = document.createRange();
    range.selectNodeContents(h.firstElementChild);
    let right = 0;
    for (const r of range.getClientRects()) right = Math.max(right, r.right);
    const gap = h.getBoundingClientRect().right - right;
    if (right && gap > 0) h.style.setProperty("--gap", `${Math.round(gap)}px`);
  };
  const show = (el) => {
    if (el.classList.contains("sweep")) hug(el);
    if (el.hasAttribute("data-fill"))
      for (const [i, child] of [...el.children].entries())
        child.style.setProperty("--i", String(Math.min(i, 12)));
    el.classList.add("in");
  };
  if (reduced() || !("IntersectionObserver" in window)) {
    for (const el of items) el.classList.add("in");
    return;
  }
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        show(e.target);
        io.unobserve(e.target);
      }
    },
    { rootMargin: "0px 0px -10% 0px", threshold: 0.05 },
  );
  for (const el of items) io.observe(el);
}

/* ------------------------------------------- the showcase, tilted back */
function tilt() {
  const fig = $("[data-tilt]");
  const win = fig && $(".window", fig);
  if (!win || reduced()) return;
  const update = () => {
    const r = fig.getBoundingClientRect();
    const vh = innerHeight;
    // Flat once its top reaches a fifth of the window; tilted below that.
    const p = Math.min(1, Math.max(0, (vh - r.top) / (vh * 0.8)));
    win.style.setProperty("--tilt", `${(1 - p) * 18}deg`);
    win.style.setProperty("--zoom", String(0.94 + p * 0.06));
  };
  update();
  addEventListener("scroll", perFrame(update), { passive: true });
  addEventListener("resize", perFrame(update));
}

/* ------------------------------- how far down the page, in the header */
function progress() {
  const bar = $("[data-progress]");
  if (!bar) return;
  const update = () => {
    const max = document.documentElement.scrollHeight - innerHeight;
    bar.style.setProperty("--p", String(max > 0 ? Math.min(1, scrollY / max) : 0));
  };
  update();
  addEventListener("scroll", perFrame(update), { passive: true });
  addEventListener("resize", perFrame(update));
}

/* ----------------------------------------------------------- counters */
function counters() {
  const items = $$("[data-count]");
  if (reduced()) return;
  const run = (el) => {
    const to = Number(el.dataset.count);
    const dec = Number(el.dataset.decimals ?? 0);
    const t0 = performance.now();
    const step = (t) => {
      const k = Math.min(1, (t - t0) / 1100);
      const eased = 1 - (1 - k) ** 3;
      el.textContent = (to * eased).toFixed(dec);
      if (k < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  };
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        run(e.target);
        io.unobserve(e.target);
      }
    },
    { threshold: 0.6 },
  );
  for (const el of items) io.observe(el);
}

/* ------------------------------ the speed tiles and their transfer row */
function cells() {
  const row = $("[data-fx]");
  const ref = $("[data-fx-ref]");
  const text = $("[data-fx-text]");
  const all = $$("[data-cells] .cell");
  if (!row || !all.length) return;
  const pick = (c) => {
    for (const x of all) x.classList.toggle("is-on", x === c);
    if (ref.textContent === c.dataset.ref && text.textContent === c.dataset.fx) return;
    ref.textContent = c.dataset.ref;
    text.textContent = c.dataset.fx;
    row.classList.toggle("is-out", c.dataset.dir === "out");
    // Each one runs its transfer again.
    row.classList.remove("is-run");
    void row.offsetWidth;
    row.classList.add("is-run");
  };
  // The visitor takes over by moving the pointer or the focus; the page
  // scrolling under a resting pointer doesn't count.
  let touched = false;
  for (const c of all) {
    c.tabIndex = 0;
    c.addEventListener("pointermove", (e) => {
      if (!e.movementX && !e.movementY) return;
      touched = true;
      pick(c);
    });
    c.addEventListener("focus", () => {
      touched = true;
      pick(c);
    });
  }
  pick(all[0]);
  if (reduced()) return;
  const io = new IntersectionObserver(
    (entries) => {
      if (!entries.some((e) => e.isIntersecting)) return;
      io.disconnect();
      // Like a queue of transfers going through, one after another, then back to the first.
      const steps = [...all.slice(1), all[0]];
      steps.forEach((c, i) => setTimeout(() => !touched && pick(c), 500 + i * 260));
    },
    { threshold: 0.5 },
  );
  io.observe(row.closest(".wrap") ?? all[0]);
}

/* ------------------------------------------------------- the ticker */
function ticker() {
  const track = $("[data-ticker]");
  if (!track) return;
  // A second copy makes the loop seamless; it isn't read twice.
  for (const li of [...track.children]) {
    const copy = li.cloneNode(true);
    copy.setAttribute("aria-hidden", "true");
    track.append(copy);
  }
}

/* ------------------------------------------------ terminal, typed out */
function terminal() {
  const term = $("[data-term]");
  if (!term || reduced()) return;
  const lines = $$("[data-type]", term);
  const texts = lines.map((l) => l.textContent);
  // Keep the box its final size while it types.
  term.style.minHeight = `${term.offsetHeight}px`;
  for (const l of lines) l.textContent = "";
  const type = async () => {
    for (const [i, l] of lines.entries()) {
      l.classList.add("is-typing");
      for (const ch of texts[i]) {
        l.textContent += ch;
        await new Promise((r) => setTimeout(r, 18 + Math.random() * 30));
      }
      l.classList.remove("is-typing");
      await new Promise((r) => setTimeout(r, 260));
    }
  };
  const io = new IntersectionObserver(
    (entries) => {
      if (!entries.some((e) => e.isIntersecting)) return;
      io.disconnect();
      void type();
    },
    { threshold: 0.4 },
  );
  io.observe(term);
}

/* ---------------------------------------------------------- lightbox */
function lightbox() {
  const dialog = $("[data-lightbox]");
  const img = $("[data-lightbox-img]");
  if (!dialog || typeof dialog.showModal !== "function") return;
  for (const button of $$("[data-zoom]")) {
    button.addEventListener("click", () => {
      const shown = [...button.querySelectorAll("img")].find((i) => i.offsetParent !== null);
      if (!shown) return;
      // The largest version in its srcset.
      const big = (shown.getAttribute("srcset") ?? "").split(",").pop()?.trim().split(/\s+/)[0];
      img.src = big || shown.currentSrc || shown.src;
      img.alt = shown.alt;
      dialog.showModal();
    });
  }
  $("[data-lightbox-close]")?.addEventListener("click", () => dialog.close());
  dialog.addEventListener("click", (e) => e.target === dialog && dialog.close());
}

/* ------------------------------------------- copy a command to paste */
function copyButtons() {
  for (const button of $$("[data-copy]")) {
    const code = $("[data-copy-text]", button.parentElement);
    if (!code || !navigator.clipboard) {
      button.hidden = true;
      continue;
    }
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(code.textContent.trim());
        button.classList.add("is-done");
        button.setAttribute("aria-label", "Copied");
        setTimeout(() => {
          button.classList.remove("is-done");
          button.setAttribute("aria-label", "Copy the command");
        }, 1600);
      } catch {
        // Selecting the text by hand still works.
      }
    });
  }
}

/* --------------------------- the footer's wordmark, fitted to its width */
function fitMark() {
  const word = $("[data-fit]");
  const box = word?.parentElement;
  if (!word || !box) return;
  const fit = () => {
    const style = getComputedStyle(box);
    const room = box.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
    const size = parseFloat(style.fontSize);
    const width = word.getBoundingClientRect().width;
    if (width > 0) box.style.fontSize = `${Math.floor(size * (room / width) * 0.995)}px`;
  };
  document.fonts?.ready.then(fit);
  new ResizeObserver(perFrame(fit)).observe(box);
}

export function initSite() {
  theme();
  nav();
  field();
  reveals();
  tilt();
  progress();
  counters();
  cells();
  ticker();
  terminal();
  lightbox();
  copyButtons();
  fitMark();
}
