// The page's behaviour. Everything here is an enhancement: the content and
// the download links work without it.

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
const reduced = () => matchMedia("(prefers-reduced-motion: reduce)").matches;

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
      const on = target === id;
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

/* ------------------------------------------------------------ reveals */
/**
 * Three kinds, all run once as they come into view:
 * `.reveal` rises into focus; `.sweep` (headings) is filled in behind a
 * transfer capsule that runs across; `[data-fill]` shows its items one after
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
  // The hero is the first screen: it plays as the page opens.
  const first = new Set($$(".hero .reveal"));
  requestAnimationFrame(() => requestAnimationFrame(() => first.forEach(show)));
  for (const el of items) if (!first.has(el)) io.observe(el);
}

/* ------------------------------------------------ the step-by-step guide */
/**
 * Two choices pick one of four guides (Android or Windows, to or from the
 * Mac); each guide shows one step at a time, with arrows, dots, the arrow
 * keys and a swipe to move. Without scripts every step is listed.
 */
function tour() {
  const root = $("[data-tour]");
  if (!root) return;
  const flows = $$("[data-flow]", root);
  const platformTabs = $$("[data-tour-platform] [role=tab]", root);
  const directionTabs = $$("[data-tour-direction] [role=tab]", root);
  const dots = $("[data-tour-dots]", root);
  const prev = $("[data-tour-prev]", root);
  const next = $("[data-tour-next]", root);
  const status = $("[data-tour-status]", root);
  const state = { platform: "android", direction: "to", index: 0 };
  let flow = null;
  let slides = [];

  const select = (tabs, value) => {
    for (const t of tabs) {
      const on = t.dataset.value === value;
      t.setAttribute("aria-selected", String(on));
      t.tabIndex = on ? 0 : -1;
    }
  };
  const show = (i, dir = 0) => {
    state.index = Math.max(0, Math.min(slides.length - 1, i));
    flow.style.setProperty("--dir", String(dir < 0 ? -1 : 1));
    for (const [k, s] of slides.entries()) s.classList.toggle("is-on", k === state.index);
    for (const [k, d] of [...dots.children].entries())
      if (k === state.index) d.setAttribute("aria-current", "step");
      else d.removeAttribute("aria-current");
    prev.disabled = state.index === 0;
    next.disabled = state.index === slides.length - 1;
    if (status) status.textContent = `Step ${state.index + 1} of ${slides.length}`;
  };
  const open = () => {
    flow = flows.find((f) => f.dataset.flow === `${state.platform}-${state.direction}`);
    for (const f of flows) f.hidden = f !== flow;
    slides = $$("[data-step]", flow);
    dots.replaceChildren(
      ...slides.map((_, k) => {
        const b = document.createElement("button");
        b.type = "button";
        b.setAttribute("aria-label", `Step ${k + 1}`);
        b.addEventListener("click", () => show(k, k - state.index));
        return b;
      }),
    );
    show(0);
  };

  // Tabs: click, or the arrow keys between them.
  const wire = (tabs, key) => {
    for (const t of tabs) {
      t.addEventListener("click", () => {
        if (state[key] === t.dataset.value) return;
        state[key] = t.dataset.value;
        select(tabs, state[key]);
        open();
      });
      t.addEventListener("keydown", (e) => {
        if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
        e.preventDefault();
        const i = tabs.indexOf(t) + (e.key === "ArrowRight" ? 1 : -1);
        const to = tabs[(i + tabs.length) % tabs.length];
        to.focus();
        to.click();
      });
    }
    select(tabs, state[key]);
  };
  wire(platformTabs, "platform");
  wire(directionTabs, "direction");

  prev.addEventListener("click", () => show(state.index - 1, -1));
  next.addEventListener("click", () => show(state.index + 1, 1));
  // The arrow keys move between steps when the guide has focus (not in the tabs).
  root.addEventListener("keydown", (e) => {
    if (e.target.closest("[role=tablist]")) return;
    if (e.key === "ArrowRight") show(state.index + 1, 1);
    else if (e.key === "ArrowLeft") show(state.index - 1, -1);
  });
  // A swipe across a step moves too.
  let x0 = null;
  const area = $(".flows", root);
  area.addEventListener("pointerdown", (e) => (x0 = e.pointerType === "mouse" ? null : e.clientX));
  area.addEventListener("pointerup", (e) => {
    if (x0 === null) return;
    const dx = e.clientX - x0;
    x0 = null;
    if (Math.abs(dx) > 50) show(state.index + (dx < 0 ? 1 : -1), dx < 0 ? 1 : -1);
  });

  // Load every step's pictures once the guide is near, so steps switch instantly.
  const io = new IntersectionObserver(
    (entries) => {
      if (!entries.some((e) => e.isIntersecting)) return;
      io.disconnect();
      for (const img of $$("img[loading=lazy]", root)) img.loading = "eager";
    },
    { rootMargin: "400px 0px" },
  );
  io.observe(root);

  open();
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
  reveals();
  tour();
  progress();
  ticker();
  lightbox();
  copyButtons();
  fitMark();
}
