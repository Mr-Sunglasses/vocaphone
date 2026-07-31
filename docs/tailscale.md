# Private Tailscale connectivity

The gateway must remain bound to `127.0.0.1:8765`. Tailscale Serve should add
tailnet-only HTTPS in front of that loopback service. Never use Funnel for this
project.

## Prerequisites

- Install and sign in to Tailscale on both the Mac and iPhone.
- Confirm both devices appear in the same tailnet.
- Start the gateway and verify `http://127.0.0.1:8765/health` locally first.

The Tailscale CLI was not installed in the build environment, so the following
commands are setup instructions and remain unverified in this checkout:

```sh
tailscale serve --bg 8765
tailscale serve status
```

Use the private HTTPS URL shown by `tailscale serve status` in the iPhone app.
Do not use the local HTTP address from the phone.

To reverse the Serve configuration:

```sh
tailscale serve reset
```

Apply a restrictive tailnet policy so only the user's iPhone and administrative
devices can reach the Mac. Tailscale identity is an additional network layer;
the Local Flow bearer token is still required.

Command syntax was checked against the current
[Tailscale Serve CLI reference](https://tailscale.com/docs/reference/tailscale-cli/serve).
