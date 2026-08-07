from __future__ import annotations


def test_fragment(maximum_duration_seconds: int) -> str:
    return f"""
      <div class="card">
        <h2>Try your pipeline</h2>
        <p class="muted">Record a short clip with this browser's microphone. The audio is
          normalized with FFmpeg and transcribed by the active engine &mdash; exactly like
          an iPhone dictation.</p>
        <div class="row" id="recorder-controls"
             data-maximum-seconds="{maximum_duration_seconds}">
          <select id="test-language">
            <!-- Same languages, in the same order, as TranscriptionLanguage on iOS and
                 Android, so anything a client can ask for can also be tested here. -->
            <option value="auto">Detect language</option>
            <option value="ar">Arabic</option>
            <option value="as">Assamese</option>
            <option value="bn">Bengali</option>
            <option value="nl">Dutch</option>
            <option value="en">English</option>
            <option value="fr">French</option>
            <option value="de">German</option>
            <option value="gu">Gujarati</option>
            <option value="hi">Hindi</option>
            <option value="it">Italian</option>
            <option value="ja">Japanese</option>
            <option value="kn">Kannada</option>
            <option value="ko">Korean</option>
            <option value="ml">Malayalam</option>
            <option value="zh">Mandarin Chinese</option>
            <option value="mr">Marathi</option>
            <option value="ne">Nepali</option>
            <option value="pl">Polish</option>
            <option value="pt">Portuguese</option>
            <option value="pa">Punjabi</option>
            <option value="ru">Russian</option>
            <option value="es">Spanish</option>
            <option value="ta">Tamil</option>
            <option value="te">Telugu</option>
            <option value="uk">Ukrainian</option>
            <option value="ur">Urdu</option>
            <option value="vi">Vietnamese</option>
          </select>
          <select id="test-runs" aria-label="Benchmark repetitions">
            <option value="1">1 run</option>
            <option value="3">3-run benchmark</option>
          </select>
          <button id="record-toggle" type="button" class="primary">Start recording</button>
          <span id="record-timer" class="record-timer hidden">0:00</span>
        </div>
        <p id="record-status" class="muted" aria-live="polite"></p>
        <div id="test-result" class="result hidden">
          <div class="result-header">
            <h3>Transcript</h3>
            <button id="copy-transcript" type="button" class="ghost small">Copy</button>
          </div>
          <p id="test-transcript"></p>
          <p id="test-meta" class="muted"></p>
          <div id="benchmark-metrics" class="benchmark-grid" aria-label="Pipeline benchmark">
            <div><span>Total</span><strong id="benchmark-total">—</strong></div>
            <div><span>Normalize</span><strong id="benchmark-normalize">—</strong></div>
            <div><span>Model load</span><strong id="benchmark-load">—</strong></div>
            <div><span>Inference</span><strong id="benchmark-inference">—</strong></div>
            <div><span>RTF</span><strong id="benchmark-rtf">—</strong></div>
            <div><span>Peak memory</span><strong id="benchmark-memory">—</strong></div>
          </div>
        </div>
        <p id="test-error" class="error hidden" role="alert"></p>
      </div>
    """
