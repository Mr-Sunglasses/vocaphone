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
    tokenInput.focus();
  }

  function hideOverlay() {
    overlay.classList.add("hidden");
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

  document.querySelectorAll(".tab").forEach((tab) => {
    tab.addEventListener("click", () => {
      document.querySelectorAll(".tab").forEach((other) => other.classList.remove("active"));
      tab.classList.add("active");
    });
  });

  // ---------------------------------------------------------------- recorder

  let recorder = null;
  let chunks = [];

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
      stream.getTracks().forEach((track) => track.stop());
      button.textContent = "Start recording";
      button.classList.remove("recording");
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
      }
    };
    recorder.start();
    result.classList.add("hidden");
    errorBox.classList.add("hidden");
    button.textContent = "Stop & transcribe";
    button.classList.add("recording");
    status.textContent = "Recording… press Stop when done.";
  });

  // ------------------------------------------------------------------ start

  if (!getToken()) {
    showOverlay();
  }
})();
