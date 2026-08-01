# Local Flow gateway

The gateway accepts bounded recordings from the Local Flow iPhone app,
normalizes them with FFmpeg, invokes a local speech engine, and returns an
idempotent transcript. It includes an authenticated HTMX WebUI for setup, model
management, engine selection, microphone testing, and operational status.

## Deployment summary

| Mode | Engines | Recommended use |
| --- | --- | --- |
| Native macOS | Handy, WhisperKit, `whisper.cpp` | Best performance on Apple silicon |
| Docker Compose | faster-whisper INT8, Moonshine, `whisper.cpp` | Linux `amd64`/`arm64` home servers |

Native WhisperKit is normally the fastest choice on an Apple silicon Mac.
Docker Desktop runs the portable Linux image in a VM, so it cannot use the
macOS WhisperKit/Core ML path. See [deployment.md](../docs/deployment.md) for the
performance explanation, operational commands, and persistence details.

## Native macOS quick start

```sh
brew install ffmpeg whisperkit-cli
cd server
uv sync --all-groups --extra engines
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

WhisperKit is recommended on Apple silicon. Standalone `whisper.cpp` is also
supported:

```sh
brew install ffmpeg whisper-cpp
```

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
recommended `faster-whisper` model, and check again:

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

Operational counters stay in process memory, contain no audio or transcript
content, and reset when the gateway process restarts.

The catalog contains WhisperKit Core ML folders for Apple silicon, persistent
CTranslate2 `faster-whisper` models for Linux, experimental Moonshine English,
and portable `whisper.cpp` models. It also includes compact Whisper Medium,
Whisper Large v3, and Breeze ASR builds from
[Handy's documented model family](https://handy.computer/docs/models) that run
directly through `whisper.cpp`; Handy does not need to be installed.
Handy's Parakeet, SenseVoice, GigaAM, and Canary models use other runtimes and
are not presented as runnable until Local Flow gains compatible adapters.

## Engine selection

The `auto` engine preference uses the first runnable option in this order:

1. Handy when its macOS application binary is present
2. a downloaded WhisperKit model kept resident in a managed loopback service
3. a downloaded `faster-whisper` model kept resident in the gateway process
4. a downloaded/configured `whisper.cpp` model

On a CPU-only Linux host, start with `faster-whisper Base EN` for English or
`faster-whisper Base` for multilingual dictation, Compute device **CPU**, and
Precision **INT8**. Tiny is the latency-first option; Small trades speed and RAM
for accuracy. Use the Test tab's three-run benchmark after the first warm run.

Moonshine is an experimental English path. When selected, the iPhone sends
float32 PCM over an authenticated WebSocket while it records. The ordinary WAV
is still retained during the request and automatically used by the batch API if
streaming is unavailable or interrupted. Batch-only engines such as WhisperKit
and faster-whisper no longer trigger a WebSocket attempt.

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
| `LOCALFLOW_ENGINE` | `auto` | `auto` | `auto`, `handy`, `whisperkit`, `faster-whisper`, `moonshine`, or `whisper.cpp` |
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

The iPhone app accepts ordinary HTTP and HTTPS gateway URLs; a Tailscale hostname
is not mandatory. Supported arrangements include:

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

Use the reported private HTTPS URL in the iPhone app. Do not use Funnel. See
[deployment.md](../docs/deployment.md) for LAN/VPS alternatives and
[tailscale.md](../docs/tailscale.md) for the private Serve setup.

## Health and readiness

- `GET /health/live` reports HTTP-process liveness and uptime without probing the
  selected engine.
- `GET /health/ready` returns `200` only when the engine/model can transcribe and
  returns `503` otherwise.
- `GET /health` is the backward-compatible iPhone health response and includes
  `streaming_supported`; clients open `/v1/stream` only when it is true.
- Authenticated `/v1/admin/status` exposes setup, metrics, and readiness details
  used by the WebUI.

Engine probes are cached for five seconds. `faster-whisper` and Moonshine load
their selected model once and keep it resident. WhisperKit warmup starts its
managed loopback service and keeps the Core ML model resident there. Handy and
`whisper.cpp` retain the filesystem-prefetch warmup behavior.

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

# Remove sessions older than the configured retention window
uv run localflow-cleanup

# Follow the native LaunchAgent logs
tail -f ~/Library/Logs/LocalFlow/gateway.log

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
