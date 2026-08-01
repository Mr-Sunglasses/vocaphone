# Gateway deployment

Local Flow uses the same HTTP API whether the gateway runs directly on macOS or
inside its Linux container. The meaningful differences are the available speech
engines, acceleration, isolation, and operational portability.

## Which deployment should I choose?

| Consideration | Native macOS | Docker Compose |
| --- | --- | --- |
| Recommended host | Apple silicon Mac | Linux `amd64` or `arm64` home server |
| Engines | WhisperKit, Handy, `whisper.cpp` | `whisper.cpp` |
| Acceleration | Apple-native WhisperKit/Core ML path | Portable CPU backend |
| Mac performance | Recommended; no Linux VM | Usually slower and uses Docker Desktop resources |
| Portability | macOS-specific service setup | Reproducible across supported Linux architectures |
| Persistence | Files below `~/.local/share/localflow` | Named volume mounted at `/data` |
| Updates | Pull code, sync dependencies, restart LaunchAgent | Pull/build image and recreate the service |

### Recommendation

- On an Apple silicon Mac, run natively and select a WhisperKit model. This
  avoids Docker Desktop's Linux VM and lets the gateway use the Apple-native
  engine path.
- On a Linux home server, use Docker Compose. The current image is intentionally
  CPU-first so the same build works on both `amd64` and `arm64`.
- Use Docker on a Mac when reproducibility and isolation matter more than the
  lowest transcription latency.

There is no honest fixed speed multiplier: model size, audio length, thermals,
and host hardware all matter. For an apples-to-apples comparison, dictate the
same saved recording several times with equivalent model sizes and compare the
dashboard's average and last transcription latency after the first warm run.

## Native macOS deployment

### Install and run

```sh
brew install ffmpeg whisperkit-cli
cd server
uv sync --all-groups
uv run localflow-server
```

The default listener is `0.0.0.0:8765`, while the local WebUI is
`http://127.0.0.1:8765/`. When Tailscale Serve is the only desired ingress,
override the listener:

```sh
LOCALFLOW_BIND_HOST=127.0.0.1 uv run localflow-server
```

The first run creates a mode-600 token file at
`~/.config/localflow/token`. Models default to
`~/.local/share/localflow/models`, the session database lives in the parent
data directory, and WebUI choices are stored in
`~/.config/localflow/config.json`.

### Run at login

```sh
cd server
./scripts/install-launch-agent.sh
launchctl print "gui/$(id -u)/com.example.localflow.gateway"
```

Logs are written to `~/Library/Logs/LocalFlow/gateway.log` and
`gateway-error.log`. Re-run the installer after changing the checkout location
or gateway executable.

## Docker Compose deployment

### Prerequisites

- Docker Engine with Compose v2, or Docker Desktop
- At least enough free memory and disk space for the selected model
- Tailscale on the host when the iPhone connects over the tailnet

The Compose project lives entirely in `server/`:

```sh
cd server
umask 077
printf 'LOCALFLOW_TOKEN=%s\n' "$(openssl rand -hex 32)" > .env
printf 'LOCALFLOW_PUBLISH_HOST=127.0.0.1\n' >> .env
printf 'LOCALFLOW_PUBLISH_PORT=8765\n' >> .env
docker compose up --detach --build
```

`LOCALFLOW_PUBLISH_HOST=127.0.0.1` is the safe default for Tailscale Serve. Set
it to `0.0.0.0` only when direct LAN access is intentional and protected by the
host firewall. Never forward the port from the public internet.

### First model

The container starts before a model is installed. Confirm process liveness,
then open the WebUI and download/select a `whisper.cpp` model:

```sh
docker compose ps
curl --fail http://127.0.0.1:8765/health/live
```

`/health/ready` returns HTTP `503` until the selected model is runnable. After
selection it should return HTTP `200` with `"status":"ready"`.

### Routine operations

```sh
# Follow gateway logs
docker compose logs --follow gateway

# Restart without deleting data
docker compose restart gateway

# Rebuild from an updated checkout
docker compose up --detach --build

# Stop the service while preserving the named volume
docker compose down
```

Do not add `--volumes` to `docker compose down` unless deleting every downloaded
model, stored configuration, and session record is intentional.

### Persistent data and backup

Compose mounts the `localflow_localflow-data` named volume at `/data`. Inspect it
with:

```sh
docker volume inspect localflow_localflow-data
```

Stop the gateway before taking a filesystem-level backup so the SQLite database
and model directory are captured consistently. A Docker or host-native backup
tool can then archive the volume shown by `docker volume inspect`. Keep backups
private because failed recordings may remain for the configured retry period.

WhisperKit model folders cannot run in the CPU-only container. Download a
compatible `whisper.cpp` model from the container WebUI instead of copying the
native macOS model directory blindly.

## Multi-architecture image

Build one tag for both supported Linux architectures from the repository root:

```sh
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag ghcr.io/your-user/localflow-gateway:latest \
  --push server
```

Set `LOCALFLOW_IMAGE` in `server/.env` to use that tag. Compose still includes a
local build definition; use `docker compose pull` followed by
`docker compose up --detach --no-build` when you explicitly want the registry
image.

## Private Tailscale ingress

Both deployments can remain on host loopback:

```sh
tailscale serve --bg 8765
tailscale serve status
```

Enter the reported private HTTPS URL in the iPhone app. Tailscale identity is an
additional network boundary; the Local Flow bearer token remains required. See
[Private Tailscale connectivity](tailscale.md) for the complete setup.
