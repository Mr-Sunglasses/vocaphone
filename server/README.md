# Local Flow gateway

The gateway accepts bounded recordings from the Local Flow iPhone app,
normalizes them with FFmpeg, invokes a local speech engine, and returns an
idempotent transcript. It includes an authenticated HTMX WebUI for setup, model
management, engine selection, microphone testing, and operational status.

## Deployment summary

| Mode | Engines | Recommended use |
| --- | --- | --- |
| Native macOS | Handy, WhisperKit, `whisper.cpp` | Best performance on Apple silicon |
| Docker Compose | CPU-only `whisper.cpp` | Linux `amd64`/`arm64` home servers |

Native WhisperKit is normally the fastest choice on an Apple silicon Mac.
Docker Desktop runs the portable Linux image in a VM, so it cannot use the
macOS WhisperKit/Core ML path. See [deployment.md](../docs/deployment.md) for the
performance explanation, operational commands, and persistence details.

## Native macOS quick start

```sh
brew install ffmpeg whisperkit-cli
cd server
uv sync --all-groups
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
`whisper.cpp` model, and check again:

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
- process uptime, active/queued work, outcomes, rejections, and latency
- hardware-aware model recommendations and disk-size/RAM guidance
- background downloads with scoped progress polling and cancellation
- model selection/deletion and persistent engine settings
- custom `.bin`/`.gguf` model downloads from HTTPS URLs
- microphone recording and real gateway transcription testing
- selected engine/model and readiness/warmup status

Operational counters stay in process memory, contain no audio or transcript
content, and reset when the gateway process restarts.

The catalog contains WhisperKit Core ML folders for Apple silicon and portable
`whisper.cpp` models. It also includes compact Whisper Medium, Whisper Large v3,
and Breeze ASR builds from
[Handy's documented model family](https://handy.computer/docs/models) that run
directly through `whisper.cpp`; Handy does not need to be installed.
Handy's Parakeet, Moonshine, SenseVoice, GigaAM, and Canary models use a different
ONNX path and are not presented as runnable until Local Flow gains a compatible
adapter.

## Engine selection

The `auto` engine preference uses the first runnable option in this order:

1. Handy when its macOS application binary is present
2. a downloaded WhisperKit model
3. a downloaded/configured `whisper.cpp` model

The WebUI can explicitly select an engine or installed model and persists that
choice in the runtime configuration file.

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
| `LOCALFLOW_ENGINE` | `auto` | `auto` | `auto`, `handy`, `whisperkit`, or `whisper.cpp` |
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

## Listener and private HTTPS

The native default listener is `0.0.0.0:8765`; the startup banner and WebUI show
that listener separately from the local browser URL. An all-interface listener
is reachable from connected networks, so keep the host firewall enabled.

For the smallest exposure, bind/publish on host loopback and use Tailscale Serve:

```sh
tailscale serve --bg 8765
tailscale serve status
```

Use the reported private HTTPS URL in the iPhone app. Do not use Funnel. See
[tailscale.md](../docs/tailscale.md).

## Health and readiness

- `GET /health/live` reports HTTP-process liveness and uptime without probing the
  selected engine.
- `GET /health/ready` returns `200` only when the engine/model can transcribe and
  returns `503` otherwise.
- `GET /health` is the backward-compatible iPhone health response.
- Authenticated `/v1/admin/status` exposes setup, metrics, and readiness details
  used by the WebUI.

Engine probes are cached for five seconds. At startup and after an engine/model
change, the gateway performs a fresh probe and asks the operating system to
prefetch up to 256 MiB of the selected model. This reduces cold disk reads; it
does not promise that the entire model remains resident in process memory.

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
uv sync --all-groups
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
