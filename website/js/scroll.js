// How the page scrolls. The browser still does the scrolling (the scroll
// bar, keyboard, touch and find-in-page work as usual); this only eases
// the mouse wheel and in-page links, and ties a few effects to the scroll
// position. Nothing here runs when the visitor prefers reduced motion.

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
const clamp = (v, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, v));
const easeInOut = (k) => (k < 0.5 ? 4 * k * k * k : 1 - (-2 * k + 2) ** 3 / 2);

/** Whether `el` (or a parent) would scroll itself for this wheel movement. */
function scrollsItself(el, dy) {
  for (
    let n = el;
    n && n !== document.body && n !== document.documentElement;
    n = n.parentElement
  ) {
    const style = getComputedStyle(n);
    if (!/(auto|scroll)/.test(style.overflowY) || n.scrollHeight <= n.clientHeight) continue;
    if (dy > 0 ? n.scrollTop + n.clientHeight < n.scrollHeight - 1 : n.scrollTop > 0) return true;
  }
  return false;
}

/**
 * Wheel scrolling that eases toward where the wheel points instead of
 * jumping, and in-page links that glide to their section. Returns
 * `{ to(element) }`, or `null` where it doesn't apply (touch, reduced motion).
 */
function smooth() {
  const root = document.documentElement;
  if (!matchMedia("(hover: hover) and (pointer: fine)").matches) return null;
  root.classList.add("is-smooth");

  let target = scrollY;
  let current = scrollY;
  let glide = null;
  let running = false;
  let last = 0;
  let set = scrollY;
  const max = () => root.scrollHeight - innerHeight;
  const offset = () => parseFloat(getComputedStyle(root).scrollPaddingTop) || 0;

  const frame = (t) => {
    // Something else moved the page (the scroll bar, a key): let it win.
    if (Math.abs(scrollY - set) > 2) {
      glide = null;
      current = target = scrollY;
      running = false;
      return;
    }
    const dt = Math.min(64, t - (last || t - 16.7));
    last = t;
    if (glide) {
      const k = clamp((t - glide.t0) / glide.ms);
      current = glide.from + (glide.to - glide.from) * easeInOut(k);
      if (k >= 1) {
        glide = null;
        target = current;
      }
    } else {
      // About 90% of the way in a quarter of a second, whatever the frame rate.
      current += (target - current) * (1 - 0.88 ** (dt / 16.7));
      if (Math.abs(target - current) < 0.4) current = target;
    }
    scrollTo(0, current);
    set = scrollY;
    if (glide || current !== target) requestAnimationFrame(frame);
    else running = false;
  };
  const start = () => {
    if (running) return;
    running = true;
    last = 0;
    set = scrollY;
    requestAnimationFrame(frame);
  };

  addEventListener(
    "wheel",
    (e) => {
      if (e.ctrlKey || e.defaultPrevented || Math.abs(e.deltaX) > Math.abs(e.deltaY)) return;
      if ($("dialog[open]") || scrollsItself(e.target, e.deltaY)) return;
      e.preventDefault();
      const unit = e.deltaMode === 1 ? 36 : e.deltaMode === 2 ? innerHeight : 1;
      if (!running) current = target = scrollY;
      glide = null;
      target = clamp(target + e.deltaY * unit, 0, max());
      start();
    },
    { passive: false },
  );
  // The scroll bar, the keyboard or find-in-page moved the page: follow it.
  addEventListener("scroll", () => !running && (current = target = scrollY), { passive: true });

  const to = (el) => {
    const y = clamp(el.getBoundingClientRect().top + scrollY - offset(), 0, max());
    const distance = Math.abs(y - scrollY);
    if (distance < 2) return;
    glide = {
      from: scrollY,
      to: y,
      t0: performance.now(),
      ms: Math.min(1500, 450 + distance * 0.22),
    };
    current = scrollY;
    start();
  };

  document.addEventListener("click", (e) => {
    const a = e.target.closest('a[href^="#"]');
    if (!a || e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey) return;
    if (a.classList.contains("skip")) return; // moves focus too: leave it to the browser
    const id = decodeURIComponent(a.getAttribute("href").slice(1));
    const el = id && document.getElementById(id);
    if (!el) return;
    e.preventDefault();
    history.pushState(null, "", `#${id}`);
    to(el);
  });
  return { to };
}

/** The hero eases away as it scrolls out: the copy lags and fades. */
function heroAway() {
  const hero = $("[data-field]");
  if (!hero) return () => {};
  return () => {
    const p = clamp(scrollY / Math.max(1, hero.offsetHeight));
    hero.style.setProperty("--away", p.toFixed(3));
  };
}

/**
 * Screenshots un-crop and settle as they come up the screen, in step with
 * the scroll (and back again when scrolling up).
 */
function scrub(queue) {
  const shots = $$("[data-scrub]");
  if (!shots.length) return () => {};
  const seen = new Set();
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) e.isIntersecting ? seen.add(e.target) : seen.delete(e.target);
      queue();
    },
    { rootMargin: "10% 0px" },
  );
  for (const s of shots) io.observe(s);
  return () => {
    for (const s of seen) {
      const top = s.getBoundingClientRect().top;
      // 0 as its top enters at the bottom, 1 once it is 45% up the screen.
      const r = clamp((innerHeight - top) / (innerHeight * 0.45));
      s.style.setProperty("--r", r.toFixed(3));
      s.classList.toggle("is-set", r >= 1);
    }
  };
}

export function initScroll() {
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  smooth();
  const updates = [];
  let queued = false;
  const update = () => {
    queued = false;
    for (const u of updates) u();
  };
  const queue = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(update);
  };
  updates.push(heroAway(), scrub(queue));
  document.documentElement.classList.add("has-scrollfx");
  update();
  addEventListener("scroll", queue, { passive: true });
  addEventListener("resize", queue);
}
