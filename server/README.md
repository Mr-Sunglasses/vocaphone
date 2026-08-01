# Local Flow gateway

The gateway accepts bounded recordings from the iPhone app, normalizes them with
FFmpeg, and invokes a local speech engine. It supports Handy, `whisper.cpp`, and
WhisperKit through a small HTMX-powered WebUI.

## First run

```sh
cd server
uv sync --all-groups
uv run localflow-server
```

The server creates `~/.config/localflow/token` with mode `600`. Open
`http://127.0.0.1:8765/` and paste the token when prompted.

The WebUI provides dependency checks, hardware-aware model recommendations,
background downloads with progress and cancellation, model selection and
deletion, custom `.bin` / `.gguf` downloads, persistent engine settings, and a
microphone test recorder.

WhisperKit is recommended on Apple silicon:

```sh
brew install ffmpeg whisperkit-cli
```

For standalone whisper.cpp:

```sh
brew install ffmpeg whisper-cpp
```

Models are stored in `~/.local/share/localflow/models` by default. WebUI choices
are stored in `~/.config/localflow/config.json`.

Useful environment variables include `LOCALFLOW_DATA_DIR`,
`LOCALFLOW_MODELS_DIR`, `LOCALFLOW_CONFIG_FILE`, `LOCALFLOW_TOKEN_FILE`,
`LOCALFLOW_ENGINE`, `LOCALFLOW_WHISPER_BINARY`, and
`LOCALFLOW_WHISPERKIT_BINARY`.

Keep the gateway bound to loopback and use Tailscale Serve for private HTTPS.
See the root `README.md` and `../docs/tailscale.md` before exposing the service.
