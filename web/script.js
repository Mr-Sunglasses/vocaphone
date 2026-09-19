document.documentElement.classList.add("js");

const menuToggle = document.querySelector("[data-menu-toggle]");
const navigation = document.querySelector("[data-navigation]");
const menuLabel = menuToggle?.querySelector(".sr-only");

if (menuToggle && navigation) {
  const closeNavigation = ({ returnFocus = false } = {}) => {
    menuToggle.setAttribute("aria-expanded", "false");
    if (menuLabel) menuLabel.textContent = "Open navigation";
    navigation.classList.remove("is-open");
    if (returnFocus) menuToggle.focus();
  };

  menuToggle.addEventListener("click", () => {
    const isOpen = menuToggle.getAttribute("aria-expanded") === "true";
    if (isOpen) {
      closeNavigation();
    } else {
      menuToggle.setAttribute("aria-expanded", "true");
      if (menuLabel) menuLabel.textContent = "Close navigation";
      navigation.classList.add("is-open");
    }
  });

  navigation.addEventListener("click", (event) => {
    if (event.target instanceof HTMLAnchorElement) {
      closeNavigation();
    }
  });

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && menuToggle.getAttribute("aria-expanded") === "true") {
      closeNavigation({ returnFocus: true });
    }
  });

  window.addEventListener("resize", () => {
    if (window.innerWidth > 920 && menuToggle.getAttribute("aria-expanded") === "true") {
      closeNavigation();
    }
  });
}

const timeNode = document.querySelector("[data-local-time]");
const yearNodes = document.querySelectorAll("[data-current-year]");

function updateClock() {
  const now = new Date();
  if (timeNode) {
    timeNode.textContent = new Intl.DateTimeFormat(undefined, {
      hour: "numeric",
      minute: "2-digit",
    }).format(now);
  }
  yearNodes.forEach((node) => {
    node.textContent = String(now.getFullYear());
  });
}

updateClock();
window.setInterval(updateClock, 30_000);

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
const revealNodes = document.querySelectorAll(".reveal");

if (reduceMotion.matches || !("IntersectionObserver" in window)) {
  revealNodes.forEach((node) => node.classList.add("is-visible"));
} else {
  const revealObserver = new IntersectionObserver(
    (entries, observer) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.14 },
  );

  revealNodes.forEach((node) => revealObserver.observe(node));

  // Content must never remain invisible in full-page capture tools, browser
  // restoration, or other cases where IntersectionObserver does not advance.
  window.setTimeout(() => {
    revealNodes.forEach((node) => node.classList.add("is-visible"));
  }, 900);
}

document.querySelectorAll(".faq-list details").forEach((detail) => {
  detail.addEventListener("toggle", () => {
    if (!detail.open) return;
    document.querySelectorAll(".faq-list details").forEach((other) => {
      if (other !== detail) other.open = false;
    });
  });
});

const demoControls = document.querySelector(".demo-controls");
const platformControls = document.querySelector(".demo-platforms");
if (demoControls && platformControls) {
  let selectedPlatform = "iphone";
  let selectedScreen = "keyboard";
  const updateDemo = () => {
    document.querySelectorAll("[data-demo-panel]").forEach((panel) => {
      panel.hidden = panel.dataset.demoPanel !== selectedScreen
        || panel.dataset.platform !== selectedPlatform;
    });
    demoControls.querySelectorAll("[data-demo-select]").forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.demoSelect === selectedScreen));
    });
    platformControls.querySelectorAll("[data-demo-platform]").forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.demoPlatform === selectedPlatform));
    });
  };
  demoControls.hidden = false;
  platformControls.hidden = false;
  updateDemo();
  demoControls.addEventListener("click", (event) => {
    const button = event.target.closest("[data-demo-select]");
    if (button) {
      selectedScreen = button.dataset.demoSelect;
      updateDemo();
    }
  });
  platformControls.addEventListener("click", (event) => {
    const button = event.target.closest("[data-demo-platform]");
    if (button) {
      selectedPlatform = button.dataset.demoPlatform;
      updateDemo();
    }
  });
}

const screenshotDialog = document.querySelector(".screenshot-dialog");
if (screenshotDialog && typeof screenshotDialog.showModal === "function") {
  document.querySelectorAll("[data-enlarge]").forEach((link) => {
    link.addEventListener("click", (event) => {
      if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      const preview = screenshotDialog.querySelector("img");
      preview.src = link.href;
      preview.alt = link.querySelector("img").alt;
      screenshotDialog.showModal();
    });
  });
  screenshotDialog.addEventListener("click", (event) => {
    if (event.target === screenshotDialog) screenshotDialog.close();
  });
}

// Everything below is decorative. Each piece checks reduceMotion (declared
// above) and either does nothing or settles straight to its end state, so a
// visitor who asked for less motion still gets the same information.

// Reading progress in the fixed bar.
const progressBar = document.querySelector("[data-scroll-progress]");
if (progressBar) {
  let progressQueued = false;
  const paintProgress = () => {
    progressQueued = false;
    const scrollable = document.documentElement.scrollHeight - window.innerHeight;
    const ratio = scrollable > 0 ? window.scrollY / scrollable : 0;
    progressBar.style.setProperty(
      "--scroll-progress",
      `${Math.min(100, Math.max(0, ratio * 100)).toFixed(2)}%`,
    );
  };
  const queueProgress = () => {
    if (progressQueued) return;
    progressQueued = true;
    window.requestAnimationFrame(paintProgress);
  };
  paintProgress();
  window.addEventListener("scroll", queueProgress, { passive: true });
  window.addEventListener("resize", queueProgress);
}

// Mark the nav link for the section currently in view. aria-current tells
// assistive tech the same thing the underline tells everyone else.
const navLinks = [...document.querySelectorAll(".site-nav a[href^='#']")];
const navTargets = navLinks
  .map((link) => ({ link, section: document.querySelector(link.getAttribute("href")) }))
  .filter((entry) => entry.section);

if (navTargets.length && "IntersectionObserver" in window) {
  const visible = new Set();
  const syncCurrent = () => {
    const active = navTargets.find((entry) => visible.has(entry.section));
    navTargets.forEach((entry) => {
      if (entry === active) entry.link.setAttribute("aria-current", "true");
      else entry.link.removeAttribute("aria-current");
    });
  };
  const sectionObserver = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) visible.add(entry.target);
        else visible.delete(entry.target);
      });
      syncCurrent();
    },
    { rootMargin: "-45% 0px -50% 0px" },
  );
  navTargets.forEach((entry) => sectionObserver.observe(entry.section));
}

// Count the hero figures up once they are on screen. The final value is
// already in the markup, so this only ever replaces a number with itself.
const counters = [...document.querySelectorAll("[data-count-to]")];
if (counters.length) {
  const runCount = (node) => {
    const target = Number(node.dataset.countTo);
    if (!Number.isFinite(target) || reduceMotion.matches) {
      node.textContent = String(node.dataset.countTo);
      return;
    }
    const duration = 1100;
    const started = performance.now();
    const step = (now) => {
      const progress = Math.min(1, (now - started) / duration);
      const eased = 1 - (1 - progress) ** 3;
      node.textContent = String(Math.round(target * eased));
      if (progress < 1) window.requestAnimationFrame(step);
    };
    window.requestAnimationFrame(step);
  };

  if (!("IntersectionObserver" in window)) {
    counters.forEach((node) => runCount(node));
  } else {
    const countObserver = new IntersectionObserver(
      (entries, observer) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          runCount(entry.target);
          observer.unobserve(entry.target);
        });
      },
      { threshold: 0.6 },
    );
    counters.forEach((node) => countObserver.observe(node));
  }
}

// A few degrees of pointer parallax on the hero devices. Pointer-driven only,
// so touch and keyboard users see the frames sitting still.
const tiltNode = document.querySelector("[data-tilt]");
if (tiltNode && window.matchMedia("(hover: hover) and (pointer: fine)").matches) {
  const maxTilt = 4;
  const resetTilt = () => {
    tiltNode.style.removeProperty("--tilt-x");
    tiltNode.style.removeProperty("--tilt-y");
  };
  const applyTilt = (event) => {
    if (reduceMotion.matches) return;
    const box = tiltNode.getBoundingClientRect();
    const offsetX = (event.clientX - box.left) / box.width - 0.5;
    const offsetY = (event.clientY - box.top) / box.height - 0.5;
    tiltNode.style.setProperty("--tilt-y", `${(offsetX * maxTilt * 2).toFixed(2)}deg`);
    tiltNode.style.setProperty("--tilt-x", `${(-offsetY * maxTilt).toFixed(2)}deg`);
  };
  tiltNode.addEventListener("pointermove", applyTilt);
  tiltNode.addEventListener("pointerleave", resetTilt);
  reduceMotion.addEventListener("change", resetTilt);
}
