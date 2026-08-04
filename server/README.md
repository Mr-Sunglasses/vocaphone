# Local Flow gateway

The gateway accepts bounded recordings from the Local Flow iPhone app,
normalizes them with FFmpeg, invokes a local speech engine, and returns an
idempotent transcript. It includes an authenticated HTMX WebUI for setup, model
management, engine selection, microphone testing, and operational status.

## Deployment summary

| Mode | Engines | Recommended use |
| --- | --- | --- |
| Native macOS | MLX Audio, WhisperKit, Handy, sherpa-onnx, `whisper.cpp` | Best performance on Apple silicon |
| Native Linux | sherpa-onnx INT8, faster-whisper, Moonshine, optional `whisper.cpp` | Linux desktop or home server without Docker |
| Docker Compose | sherpa-onnx INT8, faster-whisper INT8, Moonshine, `whisper.cpp` | Reproducible Linux `amd64`/`arm64` images |

Native MLX Audio and WhisperKit are the accelerated choices on Apple silicon.
Docker Desktop runs the portable Linux image in a VM, so it cannot use the
macOS MLX/WhisperKit/Core ML paths. See [deployment.md](../docs/deployment.md) for the
performance explanation, operational commands, and persistence details.

## Native macOS quick start

Requires [Homebrew](https://brew.sh/), Python 3.12+, and
[uv](https://docs.astral.sh/uv/). Install the host dependencies first:

- `ffmpeg` — audio normalization (required by every engine)
- `whisperkit-cli` — WhisperKit/Core ML engine on Apple silicon
- `whisper-cpp` — provides `whisper-cli` for GGML `whisper.cpp` models,
  including the Handy model family, which runs without the Handy app

```sh
brew install ffmpeg whisperkit-cli whisper-cpp
cd server
uv sync --all-groups --extra engines --extra apple
uv run localflow-server
```

The first run creates `~/.config/localflow/token` with mode `600`. Open
`http://127.0.0.1:8765/`, enter the token, download a recommended model, select
it, and confirm the Overview shows **Ready for dictation**.

To keep the gateway running after terminal sessions and restart it after login:

```sh
./scripts/install-launch-agent.sh
```

The LaunchAgent uses the checkout's `.venv`, adds standard Homebrew paths, and
writes logs to `~/Library/Logs/LocalFlow/`.

MLX Audio and WhisperKit are recommended on Apple silicon. The `apple` extra
installs MLX only on an arm64 Mac; it is deliberately absent from Linux and
Docker. The standalone `whisper.cpp` engine uses the `whisper-cli` binary
installed above (override its location with `LOCALFLOW_WHISPER_BINARY`); on a
native Linux host it is optional and can be built from source instead.

## Native Linux quick start

Requires Python 3.12+, [uv](https://docs.astral.sh/uv/), and FFmpeg on the host.

```sh
# Debian / Ubuntu
sudo apt install ffmpeg
# Install uv if needed: curl -LsSf https://astral.sh/uv/install.sh | sh

cd server
uv sync --all-groups --extra engines
uv run localflow-server
```

Do not pass `--extra apple` on Linux. The first run creates
`~/.config/localflow/token` with mode `600`. The banner prints the WebUI URL and
token path; show the secret with `cat ~/.config/localflow/token`. Open
`http://127.0.0.1:8765/`, enter the token, download a recommended model
(SenseVoice Small INT8 or Parakeet TDT INT8 on CPU), select it, and confirm
**Ready for dictation**.

To keep the gateway running after the terminal closes:

```sh
./scripts/install-systemd-user.sh
# optional: keep the user session (and unit) after logout
loginctl enable-linger "$USER"
```

```sh
systemctl --user status com.example.localflow.gateway.service
journalctl --user -u com.example.localflow.gateway.service -f
```

The unit uses the checkout's `.venv`. Re-run the installer after moving the
repository or recreating the virtualenv.

Phone clients on the same LAN can use `http://<host-lan-ip>:8765` while the
gateway binds `0.0.0.0` (the default). For Tailscale Serve only, bind loopback:

```sh
LOCALFLOW_BIND_HOST=127.0.0.1 uv run localflow-server
```

### Phone pairing QR

After you authenticate in the WebUI, the Overview page shows a **Pair phone app**
QR. The iPhone and Android apps scan it to fill the gateway URL and bearer token.
The code encodes a versioned JSON payload:

```json
{"v":1,"url":"http://192.168.1.20:8765","token":"..."}
```

Discovery prefers private Wi‑Fi addresses (for example `192.168.x.x`). Override
with `LOCALFLOW_PUBLIC_URL` or `LOCALFLOW_PAIRING_URL` when automatic selection
is wrong. The QR is only available through the authenticated WebUI/API.

The same card can create a named per-device token and immediately show its own
QR instead of the shared bootstrap token, and a **Token to encode** dropdown
switches which one the QR (and the `/v1/admin/pairing` and
`/v1/admin/pairing/qr.svg` JSON/SVG endpoints, via `?token_id=`) currently
encodes. A device token's plaintext is cached in memory only for the life of
the gateway process — long enough to regenerate its QR at a different address
without creating a duplicate — and is dropped immediately on revoke.

## Docker Compose quick start

[compose.yaml](compose.yaml) is the canonical container deployment. It builds a
non-root Linux image containing FFmpeg, the gateway, and a pinned `whisper.cpp`
CLI. The same Dockerfile builds on Linux `amd64` and `arm64`.

```sh
cd server
umask 077
printf 'LOCALFLOW_TOKEN=%s\n' "$(openssl rand -hex 32)" > .env
printf 'LOCALFLOW_PUBLISH_HOST=127.0.0.1\n' >> .env
printf 'LOCALFLOW_PUBLISH_PORT=8765\n' >> .env
docker compose up --detach --build
docker compose ps
curl --fail http://127.0.0.1:8765/health/live
```

The token is provided as a Compose secret rather than a container environment
variable. Models, configuration, and the SQLite database persist in the
`localflow_localflow-data` named volume mounted at `/data`.

The container is live before a model is installed, so `/health/ready` initially
returns `503`. Open the WebUI, enter the token from `.env`, download/select a
recommended sherpa-onnx, Moonshine, or faster-whisper model, and check again:

```sh
curl --fail http://127.0.0.1:8765/health/ready
```

The default Compose publication is host loopback only. This is appropriate for
Tailscale Serve. To intentionally allow direct LAN access, set
`LOCALFLOW_PUBLISH_HOST=0.0.0.0` in `.env` and protect the port with the host
firewall. Never expose port 8765 to the public internet.

## WebUI

The authenticated WebUI provides:

- dependency, storage, model, and engine setup checks
- process uptime, active/queued work, outcomes, rejections, and stage-level latency
- detected CPU allocation/features, container state, and available accelerators
- hardware-aware model recommendations and disk-size/RAM guidance
- background downloads with scoped progress polling and cancellation
- model selection/deletion and persistent engine settings
- custom `.bin`/`.gguf` model downloads from HTTPS URLs
- one-run or three-run microphone benchmarks with normalization, model-load,
  inference, real-time-factor, and peak-memory results
- selected engine/model and readiness/warmup status
- a redacted diagnostics export for bug reports (Settings tab or
  `uv run localflow-diagnostics`); never includes the token, audio, transcripts,
  or session identifiers
- named, independently revocable per-device tokens (Settings tab), so losing
  one phone means revoking that device's token instead of rotating everyone
  else's; the bootstrap `LOCALFLOW_TOKEN` always keeps working alongside them

Operational counters stay in process memory, contain no audio or transcript
content, and reset when the gateway process restarts.

The catalog contains WhisperKit Core ML and MLX models for Apple silicon,
portable sherpa-onnx INT8 models, persistent CTranslate2 `faster-whisper`
models, Moonshine models for Arabic, English, Spanish, Japanese, Korean,
Mandarin Chinese, Ukrainian, and Vietnamese, and portable `whisper.cpp` models.
It also includes compact Whisper Medium,
Whisper Large v3, and Breeze ASR builds from
[Handy's documented model family](https://handy.computer/docs/models) that run
directly through `whisper.cpp`; Handy does not need to be installed.
SenseVoice, Parakeet, GigaAM, and Canary now all run independently of Handy
through sherpa-onnx; Parakeet also has an Apple-native MLX option. GigaAM
(Russian, CTC or RNNT) and Canary (English only in this build; the underlying
model also covers German, French, and Spanish, but source/target language is
fixed when the recognizer loads rather than per request) download individual
files directly from their Hugging Face model repos rather than a packaged
archive, since neither publishes one.

### Fast model guide

| Model | Best host | Download | Languages | Choose it when |
| --- | --- | ---: | --- | --- |
| SenseVoice Small INT8 | Linux or macOS CPU | ~240 MB | Mandarin, Cantonese, English, Japanese, Korean | Lowest portable latency and small-server memory use matter most |
| Parakeet TDT 0.6B v3 INT8 | Linux or macOS CPU | ~672 MB | 25 European languages | You want stronger multilingual accuracy, punctuation, and capitalization |
| MLX Whisper Large v3 Turbo 4-bit | Apple silicon | ~469 MB | Multilingual | You want compact high accuracy through the M-series GPU |
| MLX Parakeet TDT 0.6B v3 | Apple silicon with at least 8 GB RAM | ~2.51 GB | 25 European languages | You want the full MLX Parakeet path and have enough unified memory |

All four adapters keep their loaded model in the gateway process. Benchmark
three runs in the Test tab: the first includes model load, while runs two and
three show steady-state dictation speed. SenseVoice uses the FunASR Model
License; both Parakeet variants use CC BY 4.0; the quantized MLX Whisper model
inherits Whisper's MIT license. Review the license shown on each model card
before redistributing weights.

## Engine selection

The `auto` engine preference uses the first runnable option in this order:

1. Handy when its macOS application binary is present
2. a downloaded WhisperKit model kept resident in a managed loopback service
3. a downloaded MLX Audio model on Apple silicon
4. a downloaded sherpa-onnx model
5. a downloaded `faster-whisper` model kept resident in the gateway process
6. a downloaded/configured `whisper.cpp` model

On a CPU-only Linux host, start with SenseVoice Small INT8 when its five
languages cover your use case, or Parakeet TDT INT8 for its 25 European
languages. Keep faster-whisper Base as the broad Whisper fallback. Compute
device and precision settings affect faster-whisper; sherpa models are already
INT8 CPU exports. Use the Test tab's three-run benchmark after the first warm
run.

Moonshine's English Medium, Small, and Tiny Streaming tiers, and the sherpa-onnx
Streaming Zipformer English 20M INT8 model, accept float32 PCM over an
authenticated WebSocket while the iPhone records — real incremental decoding
with partial results, not a periodic re-transcription of the growing buffer.
Moonshine Medium favors accuracy, Small is the balanced Linux default, and Tiny
favors latency; the Zipformer model favors speed over accuracy at a fraction of
the download size. The ordinary WAV is still retained during the request and
automatically used by the batch API if streaming is unavailable or interrupted.
Streaming support is negotiated on that socket to avoid an extra network round
trip before every recording.

Every other model — the remaining Moonshine tiers, WhisperKit, faster-whisper,
and every other sherpa-onnx model above — uses its fast batch path after
recording. The server returns a structured unsupported response for those, so
the app immediately continues through the ordinary upload pipeline. In the
iPhone app or keyboard, **Automatic** uses the active gateway model. Choosing a
named language requires the active model to support that same language.

Moonshine's English code and weights use the MIT license. Its non-English weights
use the Moonshine Community License and are limited to non-commercial use; the
WebUI labels these models **personal use**. Review the current
[Moonshine licensing and model documentation](https://github.com/moonshine-ai/moonshine)
before deploying them outside a personal setup.

The WebUI can explicitly select an engine or installed model and persists that
choice in the runtime configuration file.

On Apple silicon, current WhisperKit CLIs expose a local `serve` mode. Local
Flow starts it on a random `127.0.0.1` port during warmup and reuses the loaded
Core ML model. If an older CLI does not support `serve`, transcription falls
back to the compatible one-shot command rather than becoming unavailable.

To force Handy from the environment:

```sh
export LOCALFLOW_ENGINE=handy
export LOCALFLOW_HANDY_MODEL='owner/repository/model.gguf'
export LOCALFLOW_HANDY_FALLBACK_MODEL='owner/repository/fallback-model.gguf'
uv run localflow-server
```

To force standalone `whisper.cpp`:

```sh
export LOCALFLOW_ENGINE=whisper.cpp
export LOCALFLOW_WHISPER_BINARY=/absolute/path/to/whisper-cli
export LOCALFLOW_WHISPER_MODEL=/absolute/path/to/ggml-model.bin
uv run localflow-server
```

## Configuration

| Variable | Native default | Container default | Purpose |
| --- | --- | --- | --- |
| `LOCALFLOW_BIND_HOST` | `0.0.0.0` | `0.0.0.0` inside container | Gateway listener |
| `LOCALFLOW_PORT` | `8765` | `8765` | Gateway listener port |
| `LOCALFLOW_TOKEN` | unset | unset | Direct token override; at least 32 characters |
| `LOCALFLOW_TOKEN_FILE` | `~/.config/localflow/token` | `/run/secrets/localflow_token` | Bearer-token file |
| `LOCALFLOW_DATA_DIR` | `~/.local/share/localflow` | `/data` | Sessions and application data |
| `LOCALFLOW_MODELS_DIR` | `<data>/models` | `/data/models` | Downloaded models |
| `LOCALFLOW_CONFIG_FILE` | `~/.config/localflow/config.json` | `/data/config/config.json` | WebUI engine/model choice |
| `LOCALFLOW_ENGINE` | `auto` | `auto` | `auto`, `handy`, `mlx-audio`, `whisperkit`, `sherpa-onnx`, `faster-whisper`, `moonshine`, or `whisper.cpp` |
| `LOCALFLOW_WHISPER_BINARY` | `/opt/homebrew/bin/whisper-cli` | `/usr/local/bin/whisper-cli` | `whisper.cpp` executable |
| `LOCALFLOW_WHISPER_MODEL` | base model path | base model path | Fallback `whisper.cpp` model |
| `LOCALFLOW_WHISPERKIT_BINARY` | `whisperkit-cli` | unavailable | WhisperKit executable |
| `LOCALFLOW_RETENTION_HOURS` | `24` | `24` | Failed-session retry retention |
| `LOCALFLOW_DELETE_SUCCESSFUL_AUDIO` | `true` | `true` | Delete source/normalized audio after success |

Compose-specific variables live in `server/.env`:

| Variable | Default | Purpose |
| --- | --- | --- |
| `LOCALFLOW_PUBLISH_HOST` | `127.0.0.1` | Host interface published by Docker |
| `LOCALFLOW_PUBLISH_PORT` | `8765` | Host port published by Docker |
| `LOCALFLOW_IMAGE` | `localflow-gateway:local` | Local or registry image tag |

Use [`.env.example`](.env.example) as a template and never commit the populated
`.env` file.

## Listener and network access

The native default listener is `0.0.0.0:8765`; the startup banner and WebUI show
that listener separately from the local browser URL. An all-interface listener
is reachable from connected networks, so keep the host firewall enabled.

The iPhone and Android apps accept ordinary HTTP and HTTPS gateway URLs; a
Tailscale hostname is not mandatory. Supported arrangements include:

- a trusted LAN hostname such as `http://homelabone:8765/`; for Docker, set
  `LOCALFLOW_PUBLISH_HOST=0.0.0.0` and protect the port with the host firewall
- a loopback listener exposed privately through Tailscale Serve
- a VPS loopback listener behind an HTTPS reverse proxy and trusted certificate

HTTP does not encrypt the bearer token or recording. Use it only on a trusted
LAN or encrypted VPN, never over the public internet.

For the smallest private exposure, bind/publish on host loopback and use
Tailscale Serve:

```sh
tailscale serve --bg 8765
tailscale serve status
```

Use the reported private HTTPS URL in the iPhone or Android app. Do not use
Funnel. See [deployment.md](../docs/deployment.md) for LAN/VPS alternatives and
[tailscale.md](../docs/tailscale.md) for the private Serve setup.

## Health and readiness

- `GET /health/live` reports HTTP-process liveness and uptime without probing the
  selected engine.
- `GET /health/ready` returns `200` only when the engine/model can transcribe and
  returns `503` otherwise.
- `GET /health` is the backward-compatible iPhone health response and includes
  `streaming_supported` for status display and capability discovery. The iOS
  recording path negotiates on the socket itself to avoid a separate preflight.
- Authenticated `/v1/admin/status` exposes setup, metrics, and readiness details
  used by the WebUI.

Engine probes are cached for five seconds. sherpa-onnx, MLX Audio,
`faster-whisper`, and Moonshine load their selected model once and keep it
resident. WhisperKit warmup starts its managed loopback service and keeps the
Core ML model resident there. Handy and `whisper.cpp` retain the
filesystem-prefetch warmup behavior.

## Docker performance profiles

Only run one gateway service at a time; every profile publishes the same port
and shares the same model volume.

```sh
# Portable CPU + OpenBLAS (default; amd64 and arm64)
docker compose up --detach --build gateway

# Build CPU kernels for this exact host (fastest CPU image, not portable)
docker compose --profile native up --detach --build gateway-native

# NVIDIA host with Container Toolkit
docker compose --profile cuda up --detach --build gateway-cuda

# Intel/AMD Vulkan device exposed as /dev/dri
docker compose --profile vulkan up --detach --build gateway-vulkan
```

The CUDA profile supports both faster-whisper CUDA and the CUDA `whisper.cpp`
binary. The Vulkan profile accelerates `whisper.cpp`; faster-whisper remains on
CPU there. The dashboard reports what devices the container can actually see.

## CLI and routine operations

```sh
# Query the local backward-compatible health response
uv run localflow-status

# Download a redacted diagnostics bundle for a bug report
uv run localflow-diagnostics

# Remove sessions older than the configured retention window
uv run localflow-cleanup

# Follow the native macOS LaunchAgent logs
tail -f ~/Library/Logs/LocalFlow/gateway.log

# Follow the native Linux systemd user unit logs
journalctl --user -u com.example.localflow.gateway.service -f

# Follow container logs
docker compose logs --follow gateway

# Recreate a container from the current checkout
docker compose up --detach --build

# Stop containers but retain the named data volume
docker compose down
```

Do not run `docker compose down --volumes` unless deleting every downloaded
model, configuration file, and stored session is intentional.

## Development checks

```sh
# On macOS add --extra apple when you need MLX / WhisperKit in the dev environment.
uv sync --all-groups --extra engines
uv run ruff check .
uv run ruff format --check .
uv run mypy app
uv run pytest
LOCALFLOW_TOKEN=test-token-with-at-least-thirty-two-characters docker compose config --quiet
docker build --tag localflow-gateway:test .
```

Build and publish one tag for both supported Linux architectures from the
repository root:

```sh
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag ghcr.io/your-user/localflow-gateway:latest \
  --push server
```

For backup, update, and native-vs-container guidance, continue with
[deployment.md](../docs/deployment.md). For failures, see
[troubleshooting.md](../docs/troubleshooting.md).
