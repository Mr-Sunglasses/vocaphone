# Gateway deployment

vocaphone uses the same HTTP API whether the gateway runs directly on macOS,
directly on Linux, or inside its Linux container. The meaningful differences are
the available speech engines, acceleration, isolation, and operational
portability.

## Which deployment should I choose?

| Consideration | Native macOS | Native Linux | Docker Compose |
| --- | --- | --- | --- |
| Recommended host | Apple silicon Mac | Linux desktop or home server | Linux `amd64`/`arm64` when you want an image |
| Engines | MLX Audio, WhisperKit, VocaMac, Handy, sherpa-onnx, `whisper.cpp` | sherpa-onnx, faster-whisper, Moonshine, optional `whisper.cpp` | sherpa-onnx, faster-whisper, Moonshine, `whisper.cpp` |
| Acceleration | Apple-native MLX and WhisperKit/Core ML paths | Host CPU (Python wheels); CUDA via Docker profiles | INT8 ONNX/OpenBLAS CPU; native CPU, CUDA, or Vulkan profiles |
| Performance | Recommended on Mac; no Linux VM | No container overhead on Linux | Slightly more isolation cost; strong for CUDA images |
| Portability | macOS LaunchAgent | systemd user unit | Reproducible across supported Linux architectures |
| Persistence | Files below `~/.local/share/vocaphone` | Same as native macOS | Named volume mounted at `/data` |
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
# ffmpeg (required), WhisperKit CLI, and the whisper.cpp CLI
brew install ffmpeg whisperkit-cli whisper-cpp
cd server
uv sync --all-groups --extra engines --extra apple
uv run vocaphone-server
```

The default listener is `0.0.0.0:8765`, while the local WebUI is
`http://127.0.0.1:8765/`. When Tailscale Serve is the only desired ingress,
override the listener:

```sh
VOCAPHONE_BIND_HOST=127.0.0.1 uv run vocaphone-server
```

The first run creates a mode-600 token file at
`~/.config/vocaphone/token`. Models default to
`~/.local/share/vocaphone/models`, the session database lives in the parent
data directory, and WebUI choices are stored in
`~/.config/vocaphone/config.json`.

### Run at login

```sh
cd server
./scripts/install-launch-agent.sh
launchctl print "gui/$(id -u)/com.vocahq.vocaphone.gateway"
```

Logs are written to `~/Library/Logs/Vocaphone/gateway.log` and
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
uv run vocaphone-server
```

Omit `--extra apple` on Linux. The default listener is `0.0.0.0:8765`. When
Tailscale Serve is the only desired ingress, override the listener:

```sh
VOCAPHONE_BIND_HOST=127.0.0.1 uv run vocaphone-server
```

Token, models, and config paths match the macOS native layout:

- token: `~/.config/vocaphone/token`
- models: `~/.local/share/vocaphone/models`
- config: `~/.config/vocaphone/config.json`

Phone clients need the bearer token (`cat ~/.config/vocaphone/token`) and a
reachable URL such as `http://192.168.1.20:8765` on a trusted LAN.

### Run as a systemd user service

```sh
cd server
./scripts/install-systemd-user.sh
systemctl --user status com.vocahq.vocaphone.gateway.service
journalctl --user -u com.vocahq.vocaphone.gateway.service -f
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
printf 'VOCAPHONE_TOKEN=%s\n' "$(openssl rand -hex 32)" > .env
printf 'VOCAPHONE_PUBLISH_HOST=127.0.0.1\n' >> .env
printf 'VOCAPHONE_PUBLISH_PORT=8765\n' >> .env
docker compose up --detach --build
```

[`server/.env.example`](../server/.env.example) is the annotated template for
the same file, covering the optional image tag, network mode and Swagger UI
settings. Copy it and append a generated token rather than committing either
file.

`VOCAPHONE_PUBLISH_HOST=127.0.0.1` is the safe default for Tailscale Serve. Set
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

Compose mounts the `vocaphone_vocaphone-data` named volume at `/data`. Inspect it
with:

```sh
docker volume inspect vocaphone_vocaphone-data
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
  --tag ghcr.io/your-user/vocaphone-gateway:latest \
  --push server
```

Set `VOCAPHONE_IMAGE` in `server/.env` to use that tag. Compose still includes a
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
VOCAPHONE_PUBLISH_HOST=0.0.0.0
VOCAPHONE_PUBLISH_PORT=8765
```

Protect port 8765 with the host firewall, ensure the hostname resolves from the
iPhone, and use a URL such as `http://homelabone:8765/`. Approve Local Network
access when iOS asks. Plain HTTP exposes recordings and the bearer token to
anyone who can inspect the network, so use it only on a trusted LAN or encrypted
VPN and never forward it from a router.

With the default bridge network, the container only ever sees its own private
bridge address (for example `172.19.0.2`), never the host's real Wi-Fi/Ethernet
interface — so the pairing card's auto-discovered candidate list won't include
a `192.168.x.x` address even after the change above. On Linux Docker Engine
(not Docker Desktop on macOS/Windows), share the host's network namespace
instead so discovery sees the real LAN IP directly:

```dotenv
VOCAPHONE_NETWORK_MODE=host
```

`VOCAPHONE_PUBLISH_HOST`/`VOCAPHONE_PUBLISH_PORT` are ignored in this mode —
Compose discards the `ports:` mapping and the container binds straight onto the
host per `VOCAPHONE_BIND_HOST` (`0.0.0.0` by default) and `VOCAPHONE_PORT`
(`8765` by default). That means the host firewall is now the only thing
standing between port 8765 and every interface on the box, including any
public one — lock it down before enabling this.

### Tailscale Serve

Both native and Compose deployments can remain on host loopback:

```sh
tailscale serve --bg 8765
tailscale serve status
```

Enter the reported private HTTPS URL in the iPhone app. Tailscale identity is an
additional network boundary; the vocaphone bearer token remains required. See
[Private Tailscale connectivity](tailscale.md) for the complete setup.

### VPS or public DNS

Keep the gateway published on `127.0.0.1`, place an HTTPS reverse proxy such as
Caddy or nginx in front of it, and use a trusted certificate for the public
hostname. Enter a URL such as `https://dictation.example.com/` in the app.

Keep bearer authentication enabled at the gateway even if the reverse proxy has
its own access control. Do not expose port 8765 directly or use unencrypted HTTP
over the public internet.

## Migrating from the Local Flow working name (v0.3.0)

The v0.3.0 release replaced the **Local Flow** working name with **vocaphone**
across all identifiers. Environment variable names, config paths, Docker
resources, and service units are a hard cutover — there are no long-lived
`LOCALFLOW_*` aliases.

Native gateway startups do perform a **one-time bootstrap migration** when they
find an old Local Flow token (or config file) and no vocaphone token yet: the
token is copied to `~/.config/vocaphone/token` so paired phones keep working.
If Local Flow data exists but no token can be found, startup fails instead of
minting a new secret. Still follow the steps below for env vars, data dirs,
Docker volumes, and client reinstalls.

### Environment variables

Rename every `LOCALFLOW_*` variable to `VOCAPHONE_*`. The common set:

```sh
# Before (obsolete)                         # After (current)
LOCALFLOW_TOKEN=…                            VOCAPHONE_TOKEN=…
LOCALFLOW_TOKEN_FILE=…                       VOCAPHONE_TOKEN_FILE=…
LOCALFLOW_BIND_HOST=127.0.0.1                VOCAPHONE_BIND_HOST=127.0.0.1
LOCALFLOW_PORT=8765                          VOCAPHONE_PORT=8765
LOCALFLOW_PUBLISH_HOST=127.0.0.1             VOCAPHONE_PUBLISH_HOST=127.0.0.1
LOCALFLOW_PUBLISH_PORT=8765                  VOCAPHONE_PUBLISH_PORT=8765
LOCALFLOW_NETWORK_MODE=host                  VOCAPHONE_NETWORK_MODE=host
LOCALFLOW_IMAGE=…                            VOCAPHONE_IMAGE=…
LOCALFLOW_DATA_DIR=…                         VOCAPHONE_DATA_DIR=…
LOCALFLOW_CONFIG_FILE=…                      VOCAPHONE_CONFIG_FILE=…
LOCALFLOW_MODELS_DIR=…                       VOCAPHONE_MODELS_DIR=…
LOCALFLOW_PUBLIC_URL=…                       VOCAPHONE_PUBLIC_URL=…
LOCALFLOW_PAIRING_URL=…                      VOCAPHONE_PAIRING_URL=…
LOCALFLOW_ENGINE=…                           VOCAPHONE_ENGINE=…
LOCALFLOW_WHISPER_BINARY=…                   VOCAPHONE_WHISPER_BINARY=…
LOCALFLOW_WHISPER_MODEL=…                    VOCAPHONE_WHISPER_MODEL=…
LOCALFLOW_HANDY_BINARY=…                     VOCAPHONE_HANDY_BINARY=…
LOCALFLOW_HANDY_MODEL=…                      VOCAPHONE_HANDY_MODEL=…
LOCALFLOW_HANDY_FALLBACK_MODEL=…             VOCAPHONE_HANDY_FALLBACK_MODEL=…
LOCALFLOW_VOCAMAC_APP=…                      VOCAPHONE_VOCAMAC_APP=…
LOCALFLOW_VOCAMAC_MODEL=…                    VOCAPHONE_VOCAMAC_MODEL=…
LOCALFLOW_WHISPERKIT_BINARY=…                VOCAPHONE_WHISPERKIT_BINARY=…
LOCALFLOW_RETENTION_HOURS=24                 VOCAPHONE_RETENTION_HOURS=24
LOCALFLOW_DELETE_SUCCESSFUL_AUDIO=true       VOCAPHONE_DELETE_SUCCESSFUL_AUDIO=true
LOCALFLOW_DEBUG=false                        VOCAPHONE_DEBUG=false
```

Security defaults (loopback binding, mode-600 token files, per-device bearer
authentication, success-audio deletion) are preserved unchanged.

### Config and data paths

Move existing data into the new locations or let the first run re-create them:

| Old path | New path |
| --- | --- |
| `~/.config/localflow/token` | `~/.config/vocaphone/token` |
| `~/.config/localflow/config.json` | `~/.config/vocaphone/config.json` |
| `~/.local/share/localflow/` | `~/.local/share/vocaphone/` |
| `~/Library/Logs/LocalFlow/` | `~/Library/Logs/Vocaphone/` |

The token file and config are portable; copy them into the new location under
the same permissions (or let `vocaphone-server` / `scripts/setup-token.sh`
perform the one-time token and config copy described above). Models can be
moved or re-downloaded — the WebUI catalog keeps the same model URLs. If you
move an existing sherpa-onnx or Moonshine model, rename its
`.localflow-model.json` marker to `.vocaphone-model.json`; otherwise the
gateway will treat that model as not installed.

### Docker volume

The Compose named volume was renamed from `localflow_localflow-data` to
`vocaphone_vocaphone-data`. Docker named volumes cannot be renamed directly;
copy the data into a newly created volume or let the gateway download it again:

```sh
cd server
docker compose down
docker volume create vocaphone_vocaphone-data
docker run --rm \
  -v localflow_localflow-data:/from:ro \
  -v vocaphone_vocaphone-data:/to \
  alpine sh -c 'cp -a /from/. /to/'
# Rename model markers inside the copied volume when you keep existing models:
docker run --rm -v vocaphone_vocaphone-data:/data alpine \
  sh -c 'find /data -name .localflow-model.json -exec sh -c \
  "mv \"\$1\" \"\${1%.localflow-model.json}.vocaphone-model.json\"" _ {} \;'
# or omit the copy and let it download fresh:
docker compose up --detach --build
```

### LaunchAgent / systemd units

The install helpers remove the obsolete Local Flow unit and install the renamed
one. You can also do it manually:

**macOS:**
```sh
# install-launch-agent.sh boots out com.example.localflow.gateway automatically
cd server && ./scripts/install-launch-agent.sh
```

**Linux:**
```sh
# install-systemd-user.sh disables com.example.localflow.gateway.service automatically
cd server && ./scripts/install-systemd-user.sh
```

### iOS / Android installations

Due to changed bundle identifiers (`com.vocahq.vocaphone*`), App Group
(`group.com.vocahq.vocaphone`), and application ID (`com.vocahq.vocaphone`),
existing iOS and Android installations are not upgraded in place:

- **iOS**: Delete the old app from the device. Rebuild the renamed Xcode project
  (`ios/VocaPhone.xcodeproj`) with the new bundle IDs, re-register the App Group
  capability, install, and pair again.
- **iOS Apple Developer registration**: Register the new bundle identifiers and
  App Group under your existing team in the Apple Developer portal. See
  [decisions.md](decisions.md) for the final identifiers.
- **Android**: Uninstall the old APK (`io.github.mrsunglasses.localflow`) before
  installing the new one. `adb install -r` will **not** replace it — the
  application ID changed to `com.vocahq.vocaphone`, so a side-by-side install
  leaves both apps on the device. The Android Keystore token ciphertext is not
  portable between application IDs — re-enter the token and re-pair.

### CLI entry points

| Old command | New command |
| --- | --- |
| `uv run localflow-server` | `uv run vocaphone-server` |
| `uv run localflow-status` | `uv run vocaphone-status` |
| `uv run localflow-diagnostics` | `uv run vocaphone-diagnostics` |
| `uv run localflow-cleanup` | `uv run vocaphone-cleanup` |

The WebUI, API routes (`/v1/*`, `/health/*`), pairing protocol, and engine IDs
are unchanged.
