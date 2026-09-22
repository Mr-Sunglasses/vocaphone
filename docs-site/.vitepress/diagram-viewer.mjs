const VIEWER_CLASS = 'voca-diagram-viewer';
const OPEN_CLASS = 'voca-diagram-viewer-open';
const MIN_ZOOM = 0.5;
const MAX_ZOOM = 3;
const ZOOM_STEP = 0.25;
const FOCUSABLE_SELECTOR = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
].join(',');

let viewer;
let stage;
let canvas;
let zoomLabel;
let closeButton;
let zoom = 1;
let previousFocus;
let panStart;
let expandedDiagramCount = 0;
let backgroundInertStates;

function closestElement(target, selector) {
  return target instanceof Element ? target.closest(selector) : null;
}

function dialogFocusables() {
  return [...viewer.querySelectorAll(FOCUSABLE_SELECTOR)]
    .filter((element) => !element.hasAttribute('hidden') && element.getClientRects().length > 0);
}

function setBackgroundInert(isInert) {
  if (isInert) {
    backgroundInertStates = new Map();
    [...document.body.children]
      .filter((element) => element !== viewer)
      .forEach((element) => {
        backgroundInertStates.set(element, element.inert);
        element.inert = true;
      });
    return;
  }

  backgroundInertStates?.forEach((wasInert, element) => {
    element.inert = wasInert;
  });
  backgroundInertStates = undefined;
}

function createViewer() {
  if (viewer) return;

  viewer = document.createElement('div');
  viewer.className = VIEWER_CLASS;
  viewer.setAttribute('role', 'dialog');
  viewer.setAttribute('aria-modal', 'true');
  viewer.setAttribute('aria-labelledby', 'voca-diagram-viewer-title');
  viewer.hidden = true;
  viewer.innerHTML = `
    <div class="voca-diagram-viewer__backdrop" data-action="close"></div>
    <div class="voca-diagram-viewer__panel" role="document">
      <div class="voca-diagram-viewer__toolbar">
        <h2 id="voca-diagram-viewer-title">Expanded diagram</h2>
        <div class="voca-diagram-viewer__controls">
          <button type="button" data-action="zoom-out" aria-label="Zoom out">−</button>
          <span data-zoom aria-live="polite">100%</span>
          <button type="button" data-action="zoom-in" aria-label="Zoom in">+</button>
          <button type="button" data-action="reset">Reset</button>
          <button type="button" data-action="close">Close</button>
        </div>
      </div>
      <div class="voca-diagram-viewer__stage" tabindex="0" aria-label="Expanded diagram. Use the controls or mouse wheel to zoom.">
        <div class="voca-diagram-viewer__canvas"></div>
      </div>
    </div>
  `;

  document.body.append(viewer);
  stage = viewer.querySelector('.voca-diagram-viewer__stage');
  canvas = viewer.querySelector('.voca-diagram-viewer__canvas');
  zoomLabel = viewer.querySelector('[data-zoom]');
  closeButton = viewer.querySelector('[data-action="close"]');

  viewer.addEventListener('click', (event) => {
    const action = closestElement(event.target, '[data-action]')?.dataset.action;
    if (action === 'close') closeViewer();
    if (action === 'zoom-in') setZoom(zoom + ZOOM_STEP);
    if (action === 'zoom-out') setZoom(zoom - ZOOM_STEP);
    if (action === 'reset') setZoom(1);
  });

  stage.addEventListener('wheel', (event) => {
    event.preventDefault();
    setZoom(zoom + (event.deltaY < 0 ? ZOOM_STEP : -ZOOM_STEP));
  }, { passive: false });

  stage.addEventListener('pointerdown', (event) => {
    if (event.button !== 0) return;
    panStart = {
      x: event.clientX,
      y: event.clientY,
      scrollLeft: stage.scrollLeft,
      scrollTop: stage.scrollTop,
    };
    stage.setPointerCapture(event.pointerId);
    stage.classList.add('is-panning');
  });

  stage.addEventListener('pointermove', (event) => {
    if (!panStart) return;
    stage.scrollLeft = panStart.scrollLeft - (event.clientX - panStart.x);
    stage.scrollTop = panStart.scrollTop - (event.clientY - panStart.y);
  });

  const stopPanning = () => {
    panStart = undefined;
    stage.classList.remove('is-panning');
  };
  stage.addEventListener('pointerup', stopPanning);
  stage.addEventListener('pointercancel', stopPanning);
}

function setZoom(nextZoom) {
  zoom = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, nextZoom));
  canvas.style.transform = `scale(${zoom})`;
  zoomLabel.textContent = `${Math.round(zoom * 100)}%`;
}

function initialZoomFor(svg) {
  const viewBox = svg.viewBox?.baseVal;
  if (!viewBox?.width || !viewBox.height) return 1;
  const aspectRatio = viewBox.width / viewBox.height;
  if (aspectRatio >= 6) return 1.5;
  if (aspectRatio >= 3) return 1.25;
  return 1;
}

function centerStage() {
  stage.scrollLeft = Math.max(0, (stage.scrollWidth - stage.clientWidth) / 2);
  stage.scrollTop = Math.max(0, (stage.scrollHeight - stage.clientHeight) / 2);
}

function sizeExpandedSvg() {
  const expandedSvg = canvas?.querySelector('svg');
  if (!expandedSvg) return;

  const viewBox = expandedSvg.viewBox?.baseVal;
  const viewBoxWidth = viewBox?.width;
  const viewBoxHeight = viewBox?.height;
  const declaredWidth = Number.parseFloat(expandedSvg.getAttribute('width'));
  const diagramWidth = viewBoxWidth || declaredWidth || 1200;
  const diagramHeight = viewBoxHeight || diagramWidth;
  const aspectRatio = diagramWidth / diagramHeight;
  const stageStyle = getComputedStyle(stage);
  const horizontalPadding = Number.parseFloat(stageStyle.paddingLeft) + Number.parseFloat(stageStyle.paddingRight);
  const verticalPadding = Number.parseFloat(stageStyle.paddingTop) + Number.parseFloat(stageStyle.paddingBottom);
  const availableWidth = Math.max(320, stage.clientWidth - horizontalPadding);
  const availableHeight = Math.max(240, stage.clientHeight - verticalPadding);
  const targetWidth = Math.max(240, Math.min(1600, availableWidth, availableHeight * aspectRatio));
  expandedSvg.style.width = `${targetWidth}px`;
}

function cloneSvgWithStyles(sourceSvg) {
  const expandedSvg = sourceSvg.cloneNode(true);
  const sourceId = sourceSvg.id;
  if (!sourceId) return expandedSvg;

  const expandedId = `${sourceId}-expanded-${++expandedDiagramCount}`;
  expandedSvg.id = expandedId;
  expandedSvg.querySelectorAll('style').forEach((style) => {
    style.textContent = style.textContent.replaceAll(`#${sourceId}`, `#${expandedId}`);
  });
  return expandedSvg;
}

function openViewer(diagram) {
  createViewer();
  const sourceSvg = diagram.querySelector('svg');
  if (!sourceSvg) return;

  previousFocus = document.activeElement;
  canvas.replaceChildren(cloneSvgWithStyles(sourceSvg));
  const expandedSvg = canvas.querySelector('svg');
  expandedSvg.setAttribute('role', 'img');
  expandedSvg.style.maxWidth = 'none';
  expandedSvg.style.height = 'auto';
  viewer.hidden = false;
  setBackgroundInert(true);
  sizeExpandedSvg();
  setZoom(initialZoomFor(expandedSvg));
  requestAnimationFrame(centerStage);
  document.documentElement.classList.add(OPEN_CLASS);
  closeButton.focus();
}

function closeViewer() {
  if (!viewer || viewer.hidden) return;
  viewer.hidden = true;
  setBackgroundInert(false);
  canvas.replaceChildren();
  document.documentElement.classList.remove(OPEN_CLASS);
  if (previousFocus instanceof HTMLElement) previousFocus.focus();
  previousFocus = undefined;
}

function decorateDiagrams() {
  document.querySelectorAll('.vp-doc .mermaid').forEach((diagram) => {
    if (diagram.hasAttribute('tabindex')) return;
    diagram.tabIndex = 0;
    diagram.setAttribute('role', 'button');
    diagram.setAttribute('aria-label', 'Open diagram in an expanded viewer');
  });
}

export function installDiagramViewer(router) {
  if (typeof window === 'undefined' || window.__vocaDiagramViewerInstalled) return;
  window.__vocaDiagramViewerInstalled = true;

  document.addEventListener('click', (event) => {
    if (closestElement(event.target, `.${VIEWER_CLASS}`)) return;
    const diagram = closestElement(event.target, '.vp-doc .mermaid');
    if (diagram) openViewer(diagram);
  });

  document.addEventListener('keydown', (event) => {
    if (viewer && !viewer.hidden) {
      if (event.key === 'Tab') {
        const focusables = dialogFocusables();
        if (focusables.length === 0) return;
        const first = focusables[0];
        const last = focusables.at(-1);
        if (!viewer.contains(document.activeElement) || (!event.shiftKey && document.activeElement === last)) {
          event.preventDefault();
          first.focus();
        } else if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last.focus();
        }
      } else if (event.key === 'Escape') {
        event.preventDefault();
        closeViewer();
      } else if (event.key === '+' || event.key === '=') {
        event.preventDefault();
        setZoom(zoom + ZOOM_STEP);
      } else if (event.key === '-') {
        event.preventDefault();
        setZoom(zoom - ZOOM_STEP);
      } else if (event.key === '0') {
        event.preventDefault();
        setZoom(1);
      }
      return;
    }

    const diagram = closestElement(event.target, '.vp-doc .mermaid');
    if (diagram && (event.key === 'Enter' || event.key === ' ')) {
      event.preventDefault();
      openViewer(diagram);
    }
  });

  window.addEventListener('hashchange', closeViewer);
  window.addEventListener('popstate', closeViewer);
  window.addEventListener('resize', sizeExpandedSvg);
  if (router) {
    const previousAfterRouteChange = router.onAfterRouteChange;
    router.onAfterRouteChange = async (to) => {
      closeViewer();
      await previousAfterRouteChange?.(to);
    };
  }
  const observer = new MutationObserver(decorateDiagrams);
  observer.observe(document.body, { childList: true, subtree: true });
  decorateDiagrams();
}
