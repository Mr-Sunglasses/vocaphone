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
