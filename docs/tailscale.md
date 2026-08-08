# Private Tailscale connectivity

Tailscale is optional. Phone clients can use a trusted LAN HTTP URL or an HTTPS
VPS as described in the gateway deployment guide.

The full Tailscale Serve setup for the gateway lives with the gateway:

- [server/docs/tailscale.md](../server/docs/tailscale.md)
- [server/docs/deployment.md](../server/docs/deployment.md)

After the gateway is reachable, enter its HTTP/HTTPS URL and bearer token in the
iOS or Android app (or scan the pairing QR from the gateway WebUI).
