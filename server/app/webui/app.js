/* Local Flow WebUI glue: token auth for HTMX, tab styling, mic recorder, toasts. */
(() => {
  "use strict";

  const TOKEN_KEY = "localflow.token";
  const overlay = document.getElementById("token-overlay");
  const tokenInput = document.getElementById("token-input");
  const tokenError = document.getElementById("token-error");
  const toast = document.getElementById("toast");

  const getToken = () => localStorage.getItem(TOKEN_KEY) || "";

  function showToast(message, isError = true) {
    toast.textContent = message;
    toast.classList.toggle("error", isError);
    toast.classList.remove("hidden");
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => toast.classList.add("hidden"), 5000);
  }

  function showOverlay(message = "") {
    tokenError.textContent = message;
    tokenError.classList.toggle("hidden", !message);
    overlay.classList.remove("hidden");
    overlay.setAttribute("aria-hidden", "false");
    tokenInput.focus();
  }

  function hideOverlay() {
    overlay.classList.add("hidden");
    overlay.setAttribute("aria-hidden", "true");
    tokenInput.value = "";
  }

  // ------------------------------------------------------------------ token

  document.getElementById("token-save").addEventListener("click", () => {
    const token = tokenInput.value.trim();
    if (token.length < 32) {
      showOverlay("The token is at least 32 characters long.");
      return;
    }
    localStorage.setItem(TOKEN_KEY, token);
    hideOverlay();
    htmx.ajax("GET", "/ui/partials/overview", { target: "#panel", swap: "innerHTML" });
    htmx.ajax("GET", "/ui/partials/engine-pill", { target: "#engine-pill", swap: "outerHTML" });
  });

  tokenInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter") document.getElementById("token-save").click();
  });

  document.body.addEventListener("click", (event) => {
    if (event.target.id === "forget-token") {
      localStorage.removeItem(TOKEN_KEY);
      showOverlay("Token removed from this browser.");
    }
  });

  // ------------------------------------------------------- htmx integration

  document.body.addEventListener("htmx:configRequest", (event) => {
    event.detail.headers["Authorization"] = `Bearer ${getToken()}`;
  });

  document.body.addEventListener("htmx:responseError", (event) => {
    if (event.detail.xhr.status === 401) {
      localStorage.removeItem(TOKEN_KEY);
      showOverlay("That token was rejected. Paste the current gateway token.");
      return;
    }
    let message = `Request failed (${event.detail.xhr.status}).`;
    try {
      const payload = JSON.parse(event.detail.xhr.responseText);
      if (payload.error && payload.error.message) message = payload.error.message;
    } catch (_) { /* keep default message */ }
    showToast(message);
  });

  // -------------------------------------------------------------------- tabs

  function activateTab(tab, updateLocation = true) {
    document.querySelectorAll(".tab").forEach((other) => {
      const active = other === tab;
      other.classList.toggle("active", active);
      other.setAttribute("aria-selected", String(active));
      other.tabIndex = active ? 0 : -1;
    });
    if (updateLocation) history.replaceState(null, "", `#${tab.dataset.tab}`);
  }

  document.querySelectorAll(".tab").forEach((tab) => {
    tab.addEventListener("click", () => {
      activateTab(tab);
    });
    tab.addEventListener("keydown", (event) => {
      if (!["ArrowLeft", "ArrowRight"].includes(event.key)) return;
      const tabs = [...document.querySelectorAll(".tab")];
      const offset = event.key === "ArrowRight" ? 1 : -1;
      const next = tabs[(tabs.indexOf(tab) + offset + tabs.length) % tabs.length];
      next.focus();
      next.click();
    });
  });

  document.body.addEventListener("htmx:beforeRequest", (event) => {
    if (event.detail.target && event.detail.target.id === "panel") {
      event.detail.target.setAttribute("aria-busy", "true");
    }
  });

  document.body.addEventListener("htmx:afterRequest", (event) => {
    if (event.detail.target && event.detail.target.id === "panel") {
      event.detail.target.setAttribute("aria-busy", "false");
    }
  });

  document.body.addEventListener("htmx:afterSwap", () => scheduleModelPoll());

  // ------------------------------------------------------------ model status

  let modelPollTimer = null;

  function formatBytes(size) {
    if (size >= 1_000_000_000) return `${(size / 1_000_000_000).toFixed(1)} GB`;
    if (size >= 1_000_000) return `${Math.round(size / 1_000_000)} MB`;
    if (size >= 1_000) return `${Math.round(size / 1_000)} KB`;
    return `${size} B`;
  }

  function scheduleModelPoll(delay = 1500) {
    clearTimeout(modelPollTimer);
    modelPollTimer = null;
    const downloading = document.querySelector('#models-list [data-state="downloading"]');
    if (!downloading || document.visibilityState !== "visible") return;
    modelPollTimer = setTimeout(pollModelProgress, delay);
  }

  async function pollModelProgress() {
    const cards = [...document.querySelectorAll('#models-list [data-state="downloading"]')];
    if (!cards.length || document.visibilityState !== "visible") return;
    try {
      const response = await fetch("/v1/admin/models", {
        headers: { Authorization: `Bearer ${getToken()}` },
        cache: "no-store",
      });
      if (response.status === 401) {
        localStorage.removeItem(TOKEN_KEY);
        showOverlay("Your gateway session expired. Paste the current token.");
        return;
      }
      if (!response.ok) throw new Error(`Model status failed (${response.status}).`);
      const entries = await response.json();
      const byId = new Map(entries.map((entry) => [entry.id, entry]));
      let needsRefresh = false;
      cards.forEach((card) => {
        const entry = byId.get(card.dataset.modelId);
        if (!entry || entry.state !== "downloading") {
          needsRefresh = true;
          return;
        }
        const percent = Math.round((entry.progress || 0) * 100);
        const progress = card.querySelector(".progress");
        const bar = card.querySelector(".bar");
        const copy = card.querySelector(".progress-copy");
        if (progress) progress.setAttribute("aria-valuenow", String(percent));
        if (bar) bar.style.width = `${percent}%`;
        if (copy) {
          copy.textContent = `${percent}% · ${formatBytes(entry.downloaded_bytes || 0)} / ` +
            formatBytes(entry.total_bytes || 0);
        }
      });
      if (needsRefresh && document.getElementById("models-list")) {
        htmx.ajax("GET", "/ui/partials/models-list", {
          target: "#models-list",
          swap: "innerHTML",
        });
        return;
      }
      scheduleModelPoll();
    } catch (_) {
      scheduleModelPoll(4000);
    }
  }

  document.addEventListener("visibilitychange", () => scheduleModelPoll());

  // ---------------------------------------------------------------- recorder

  let recorder = null;
  let chunks = [];
  let recordingTimer = null;
  let recordingStartedAt = 0;

  function stopRecordingTimer() {
    clearInterval(recordingTimer);
    recordingTimer = null;
  }

  function updateRecordingTimer(timer) {
    const elapsedSeconds = Math.floor((Date.now() - recordingStartedAt) / 1000);
    const minutes = Math.floor(elapsedSeconds / 60);
    timer.textContent = `${minutes}:${String(elapsedSeconds % 60).padStart(2, "0")}`;
  }

  function pickMimeType() {
    const candidates = ["audio/mp4", "audio/webm;codecs=opus", "audio/webm", "audio/ogg"];
    return candidates.find((type) => window.MediaRecorder && MediaRecorder.isTypeSupported(type));
  }

  document.body.addEventListener("click", async (event) => {
    if (event.target.id !== "record-toggle") return;
    const button = event.target;
    const status = document.getElementById("record-status");
    const result = document.getElementById("test-result");
    const errorBox = document.getElementById("test-error");
    const timer = document.getElementById("record-timer");
    const controls = document.getElementById("recorder-controls");
    const maximumSeconds = Number(controls.dataset.maximumSeconds) || 120;

    if (recorder && recorder.state === "recording") {
      recorder.stop();
      return;
    }

    const mimeType = pickMimeType();
    if (!mimeType) {
      errorBox.textContent = "This browser cannot record audio (MediaRecorder unavailable).";
      errorBox.classList.remove("hidden");
      return;
    }

    let stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (_) {
      errorBox.textContent = "Microphone permission denied.";
      errorBox.classList.remove("hidden");
      return;
    }

    chunks = [];
    recorder = new MediaRecorder(stream, { mimeType });
    recorder.ondataavailable = (chunk) => chunks.push(chunk.data);
    recorder.onstop = async () => {
      stopRecordingTimer();
      stream.getTracks().forEach((track) => track.stop());
      button.textContent = "Start recording";
      button.classList.remove("recording");
      button.disabled = true;
      timer.classList.add("hidden");
      status.textContent = "Transcribing…";
      const blob = new Blob(chunks, { type: mimeType.split(";")[0] });
      try {
        const language = document.getElementById("test-language").value;
        const response = await fetch(`/v1/admin/test-transcription?language=${language}`, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${getToken()}`,
            "Content-Type": blob.type,
          },
          body: blob,
        });
        const payload = await response.json();
        if (!response.ok) throw new Error(payload.error?.message || "Transcription failed.");
        document.getElementById("test-transcript").textContent = payload.transcript;
        document.getElementById("test-meta").textContent =
          `${payload.engine} · ${(payload.duration_ms / 1000).toFixed(1)}s`;
        result.classList.remove("hidden");
        errorBox.classList.add("hidden");
        status.textContent = "";
      } catch (error) {
        errorBox.textContent = error.message;
        errorBox.classList.remove("hidden");
        status.textContent = "";
      } finally {
        button.disabled = false;
      }
    };
    recorder.start();
    result.classList.add("hidden");
    errorBox.classList.add("hidden");
    button.textContent = "Stop & transcribe";
    button.classList.add("recording");
    recordingStartedAt = Date.now();
    timer.textContent = "0:00";
    timer.classList.remove("hidden");
    recordingTimer = setInterval(() => {
      updateRecordingTimer(timer);
      if (Date.now() - recordingStartedAt >= maximumSeconds * 1000) recorder.stop();
    }, 250);
    status.textContent = `Recording… maximum ${maximumSeconds} seconds.`;
  });

  document.body.addEventListener("click", async (event) => {
    if (event.target.id !== "copy-transcript") return;
    const transcript = document.getElementById("test-transcript").textContent;
    try {
      await navigator.clipboard.writeText(transcript);
      showToast("Transcript copied.", false);
    } catch (_) {
      showToast("Could not copy the transcript. Select it manually.");
    }
  });

  // ------------------------------------------------------------------ start

  if (!getToken()) {
    showOverlay();
  }

  const requestedTab = document.querySelector(`.tab[data-tab="${location.hash.slice(1)}"]`);
  const initialTab = requestedTab || document.querySelector(".tab.active");
  activateTab(initialTab, false);
  if (requestedTab) {
    document.getElementById("panel").setAttribute("hx-get", requestedTab.getAttribute("hx-get"));
  }
})();
