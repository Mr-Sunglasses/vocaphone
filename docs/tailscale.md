# Private Tailscale connectivity

Tailscale is the recommended private transport for a personal deployment, but
it is optional. vocaphone can also use a trusted LAN HTTP URL or an HTTPS VPS as
described in [deployment](deployment.md).

For private HTTPS, bind the gateway to `127.0.0.1:8765` and let Tailscale Serve
add tailnet-only ingress in front of it. This overrides the gateway's
all-interface default and avoids exposing port 8765 directly to the local
network. Never use Funnel for this project.

## Prerequisites

- Install and sign in to Tailscale on the gateway host and on the phone (iPhone
  or Android).
- Confirm both devices appear in the same tailnet.
- Start or publish the gateway on host loopback and verify liveness locally.

For a native macOS or Linux process:

```sh
cd server
VOCAPHONE_BIND_HOST=127.0.0.1 uv run vocaphone-server
```

For Docker, keep the Compose default in `server/.env`:

```dotenv
VOCAPHONE_PUBLISH_HOST=127.0.0.1
VOCAPHONE_PUBLISH_PORT=8765
```

Then verify the process before configuring Serve:

```sh
curl --fail http://127.0.0.1:8765/health/live
```

Create or inspect the tailnet-only HTTPS proxy with:

```sh
tailscale serve --bg 8765
tailscale serve status
```

Use the private HTTPS URL shown by `tailscale serve status` in the iPhone or
Android app. Do not use the local HTTP address from the phone.

The HTTPS endpoint can be live while transcription readiness is still `503`.
After downloading/selecting a model in the WebUI, verify both paths:

```sh
curl --fail http://127.0.0.1:8765/health/ready
curl --fail https://your-device.your-tailnet.ts.net/health/ready
```

To reverse the Serve configuration:

```sh
tailscale serve reset
```

Apply a restrictive tailnet policy so only the user's phone and administrative
devices can reach the gateway host. Tailscale identity is an additional network
layer; the vocaphone bearer token is still required.

Command syntax was checked against the current
[Tailscale Serve CLI reference](https://tailscale.com/docs/reference/tailscale-cli/serve).
