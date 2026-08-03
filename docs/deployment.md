# Gateway deployment

Local Flow uses the same HTTP API whether the gateway runs directly on macOS,
directly on Linux, or inside its Linux container. The meaningful differences are
the available speech engines, acceleration, isolation, and operational
portability.

## Which deployment should I choose?

| Consideration | Native macOS | Native Linux | Docker Compose |
| --- | --- | --- | --- |
| Recommended host | Apple silicon Mac | Linux desktop or home server | Linux `amd64`/`arm64` when you want an image |
| Engines | MLX Audio, WhisperKit, Handy, sherpa-onnx, `whisper.cpp` | sherpa-onnx, faster-whisper, Moonshine, optional `whisper.cpp` | sherpa-onnx, faster-whisper, Moonshine, `whisper.cpp` |
| Acceleration | Apple-native MLX and WhisperKit/Core ML paths | Host CPU (Python wheels); CUDA via Docker profiles | INT8 ONNX/OpenBLAS CPU; native CPU, CUDA, or Vulkan profiles |
| Performance | Recommended on Mac; no Linux VM | No container overhead on Linux | Slightly more isolation cost; strong for CUDA images |
| Portability | macOS LaunchAgent | systemd user unit | Reproducible across supported Linux architectures |
| Persistence | Files below `~/.local/share/localflow` | Same as native macOS | Named volume mounted at `/data` |
| Updates | Pull code, `uv sync`, restart LaunchAgent | Pull code, `uv sync`, restart systemd unit | Pull/build image and recreate the service |

### Recommendation

- On an Apple silicon Mac, run natively and compare MLX Whisper Turbo 4-bit,
  MLX Parakeet, and WhisperKit on the same recording. These avoid Docker
  Desktop's Linux VM and keep the chosen Apple-native model resident.
- On a Linux desktop or home server, run natively with
  `uv sync --all-groups --extra engines` when you already trust the host Python
  environment. Start with SenseVoice Small INT8 for its supported Asian languages
  plus English, or Parakeet TDT INT8 for 25 European languages. Both use
  sherpa-onnx wheels on `amd64` and `arm64`; faster-whisper remains the broad
  Whisper fallback.
- Use Docker on Linux when you want CUDA/Vulkan profiles, multi-arch images, or
  stronger isolation. Use Docker on a Mac only when reproducibility matters more
  than the lowest transcription latency.

There is no honest fixed speed multiplier: model size, audio length, thermals,
and host hardware all matter. For an apples-to-apples comparison, dictate the
same saved recording several times with equivalent model sizes and compare the
Test tab's three-run benchmark. It treats run 1 as model warmup/load and reports
the warm average of runs 2 and 3. Compare inference time and real-time factor,
not only end-to-end time.

## Native macOS deployment

### Install and run

```sh
brew install ffmpeg whisperkit-cli
cd server
uv sync --all-groups --extra engines --extra apple
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

## Native Linux deployment

### Install and run

```sh
# Debian / Ubuntu example
sudo apt install ffmpeg
# https://docs.astral.sh/uv/ — curl -LsSf https://astral.sh/uv/install.sh | sh
cd server
uv sync --all-groups --extra engines
uv run localflow-server
```

Omit `--extra apple` on Linux. The default listener is `0.0.0.0:8765`. When
Tailscale Serve is the only desired ingress, override the listener:

```sh
LOCALFLOW_BIND_HOST=127.0.0.1 uv run localflow-server
```

Token, models, and config paths match the macOS native layout:

- token: `~/.config/localflow/token`
- models: `~/.local/share/localflow/models`
- config: `~/.config/localflow/config.json`

Phone clients need the bearer token (`cat ~/.config/localflow/token`) and a
reachable URL such as `http://192.168.1.20:8765` on a trusted LAN.

### Run as a systemd user service

```sh
cd server
./scripts/install-systemd-user.sh
systemctl --user status com.example.localflow.gateway.service
journalctl --user -u com.example.localflow.gateway.service -f
```

To keep the unit after logout:

```sh
loginctl enable-linger "$USER"
```

Re-run the installer after moving the checkout or recreating `.venv`.

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
then open the WebUI and download/select a recommended sherpa-onnx, Moonshine,
or faster-whisper model:

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

WhisperKit model folders cannot run in a Linux container. Download a compatible
faster-whisper, Moonshine, or `whisper.cpp` model from the container WebUI
instead of copying the native macOS model directory blindly.

### Performance profiles

The default `gateway` is the portable CPU/OpenBLAS service. Stop it before
starting another profile because all services publish the same port and share
the named volume.

```sh
docker compose down

# Optimize CPU code for exactly this build host.
docker compose --profile native up --detach --build gateway-native

# NVIDIA Container Toolkit and a supported NVIDIA GPU are required.
docker compose --profile cuda up --detach --build gateway-cuda

# A working host Vulkan driver and /dev/dri are required.
docker compose --profile vulkan up --detach --build gateway-vulkan
```

The native CPU image is not a portable registry artifact; build it on the
machine that will run it. The CUDA and Vulkan images should be published only
for architectures supported by their base images and host drivers.

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

## Gateway URL and network placement

The iPhone app accepts any gateway URL with an explicit `http://` or `https://`
scheme and a valid hostname. Tailscale is one option rather than a requirement.

### Trusted local network

The native gateway already listens on all interfaces by default. For Docker,
set the Compose publication in `server/.env`:

```dotenv
LOCALFLOW_PUBLISH_HOST=0.0.0.0
LOCALFLOW_PUBLISH_PORT=8765
```

Protect port 8765 with the host firewall, ensure the hostname resolves from the
iPhone, and use a URL such as `http://homelabone:8765/`. Approve Local Network
access when iOS asks. Plain HTTP exposes recordings and the bearer token to
anyone who can inspect the network, so use it only on a trusted LAN or encrypted
VPN and never forward it from a router.

### Tailscale Serve

Both native and Compose deployments can remain on host loopback:

```sh
tailscale serve --bg 8765
tailscale serve status
```

Enter the reported private HTTPS URL in the iPhone app. Tailscale identity is an
additional network boundary; the Local Flow bearer token remains required. See
[Private Tailscale connectivity](tailscale.md) for the complete setup.

### VPS or public DNS

Keep the gateway published on `127.0.0.1`, place an HTTPS reverse proxy such as
Caddy or nginx in front of it, and use a trusted certificate for the public
hostname. Enter a URL such as `https://dictation.example.com/` in the app.

Keep bearer authentication enabled at the gateway even if the reverse proxy has
its own access control. Do not expose port 8765 directly or use unencrypted HTTP
over the public internet.
