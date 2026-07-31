# Local Flow gateway

The gateway accepts bounded recordings from the iPhone app, normalizes them with
FFmpeg, and invokes a local `whisper.cpp` binary. See the root `README.md` for
the verified setup path and `../docs/tailscale.md` before exposing the loopback
service through Tailscale Serve.
