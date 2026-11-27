# freerdp-wasm — single-file browser RDP client

A standalone repository for the browser-side FreeRDP WASM client: one Go binary
that serves the embedded WASM site and proxies WebSocket <-> RDP TCP.

This repository is the WASM-only counterpart to the original FFmpeg/Python
bridge. It builds a single ~30 MB static binary (frontend embedded via
`go:embed`) — no nginx, no Python, no sidecar files at runtime.

Architecture:

```
Browser (congzhangzh freerdp-web WASM client)
   |  HTTP :8180 (static site, COOP/COEP) + WSS /ws
wsproxy  (one Go binary, CGO_ENABLED=0, FROM scratch)
   |  TCP 3389
Windows RDS (existing, independent sessions)
```

One binary does it all: static file server (with the COOP/COEP headers WASM
threads need) + websockify-compatible WebSocket↔TCP proxy. No nginx, no python
websockify. The upstream client asks for websockify's `binary` WebSocket
subprotocol and sends raw RDP bytes in binary frames; the proxy negotiates that
subprotocol and pipes the frames straight to TCP.

## Quick start (no auth; trusted networks only)

> [!WARNING]
> **No authentication is built in, and the proxy now listens on `0.0.0.0:8180`
> (all interfaces) by default.** Anyone who can reach that port can use `/ws`
> as a websockify-style bridge and connect through to the configured RDS host.
> **Use this PoC only on a trusted LAN or in a controlled lab environment.**
> **Never expose port 8180 directly to the public Internet.** If Internet
> access is required, you must either put an authenticating TLS layer in front
> (OIDC/Authelia + TLS, listening on a public interface) or reach the PoC over
> a VPN / SSH tunnel rather than opening the port. The proxy itself does not
> authenticate callers and `CheckOrigin` is permissive by design.

1. Build the single-file binary (no Emscripten toolchain needed):

   ```bash
   ./build.sh                   # -> dist-release/wsproxy
   ```

   `build.sh` fetches the **latest** upstream release kit into `proxy/site/`
   (SHA-256 verified), then re-applies our local `app.js` patch automatically.
   The patched frontend is also committed here as a reference copy. Pin a version
   with `KIT_TAG=<tag>`, keep the current copy with `SKIP_FETCH=1`, or skip the
   fetch only with `REUSE_SITE=1`.

   The script downloads the release kit's `freerdp-web-page.zip` with `curl`
   (retries + resume), verifies its SHA-256, and unpacks it into `proxy/site/`.
   The kit tag is resolved from GitHub's releases API via `curl` (streamed to a
   file, so the flaky `urllib` chunked-read that broke upstream `site.sh` is
   avoided). Downloads are cached in `~/.cache/freerdp-web-poc` (override with
   `CACHE=`), so re-running after a restart works offline and is instant.

   Useful overrides:

   | Variable | Purpose |
   | --- | --- |
   | `KIT_TAG=web-20261126.1-b8390ae2807a` | Pin a specific kit pre-release (skips API tag resolution) |
   | `SITE_ZIP_URL=... SITE_ZIP_SHA_URL=...` | Use a manually hosted zip + checksum (fully offline) |
   | `KIT_TAG=<tag>` | Pin a specific upstream kit release when fetching WASM |
   | `SITE_DIR=...` | Install into a different directory |
   | `CACHE=...` | Change the download cache location |

   If the direct download fails, the script falls back to `git clone` + the
   upstream `site.sh`. If GitHub's API is unavailable, pin `KIT_TAG` to a known
   good tag as shown above. The downloaded client and cache are gitignored and
   never committed.

2. Start the single binary, pointing at your RDS host:

   ```bash
   RDP_TARGET=<RDS_HOST>:3389 ./scripts/run-poc.sh
   ```

   It listens on `0.0.0.0:8180` by default, i.e. on every interface, and is
   reachable from other machines on the same network. Override with
   `PROXY_LISTEN=127.0.0.1:8180` (or `-listen 127.0.0.1:8180`) if you want to
   bind loopback only.

   The WASM client is **embedded into the binary** via `go:embed`, so `wsproxy`
   is a single ~30 MB static file — no `proxy/site/` directory needed at
   runtime. A disk `proxy/site/` directory is used in preference when present,
   so you can hot-reload the frontend without rebuilding; delete/rename it to
   fall back to the embedded copy.

   If RDS is not reachable from your workstation, run the binary on a jump host
   that can reach TCP 3389 and forward the port to your local machine. The
   **local** side of the SSH tunnel stays on loopback, which is intentional:
   it keeps the PoC off your workstation's LAN interface while still reaching
   the remote proxy:

   ```bash
   # local browser -> 127.0.0.1:8180 -> gateway:8180 -> RDS
   ssh -N -L 127.0.0.1:8180:127.0.0.1:8180 user@<gateway>
   ```

   In that setup the browser page is open at `http://localhost:8180` and the
   gateway field in the page should be `127.0.0.1:8180` (the same port serves
   the page and `/ws`). The gateway on the remote side is still bound to
   `0.0.0.0:8180` by default; restrict it there with `PROXY_LISTEN` if it does
   not need to be reachable from other hosts on that network.

   For an **external WSS tunnel** (e.g. `wss://141-8180-i.fast.213470.xyz:443`
   forwarding to the local proxy), enter the full URL **including the `/ws`
   path** in the gateway field:

   ```
   wss://141-8180-i.fast.213470.xyz:443/ws
   ```

   The page passes this URL verbatim to the WASM client's WebSocket layer.
   This is a local workaround in `proxy/site/app.js` (the unmodified upstream
   copy is saved as `proxy/site/app.js.orig`) for a
   known Emscripten bug in the prebuilt kit
   ([emscripten#27886](https://github.com/emscripten-core/emscripten/issues/27886)):
   under `PROXY_TO_PTHREAD`, `gethostbyname()` writes its fake DNS entry into
   a worker's table, so `connect()` on the main thread cannot resolve it and
   falls back to the fake IP (e.g. `wss://172.29.1.0:443/`), which the tunnel
   rejects. Supplying a full URL also fixes the path mismatch, since the
   unpatched page always appended its own `/` (our proxy's endpoint is `/ws`).
   The upstream `web/app.js` only supports scheme prefixes (`wss://` / `ws://`)
   and a bare `host:port`; the full-URL form is PoC-only and not upstreamed.

   As a second safety net, the proxy also accepts a WebSocket upgrade on `/`
   (non-upgrade requests still serve the static site), so a client that falls
   back to `wss://<host>:443/` can still connect.

3. Open `http://localhost:8180` in **Chrome 137+** (or accept slower Asyncify).
   In the page's gateway field enter `127.0.0.1:8180` (the same port serves the
   page and `/ws`; adjust to the host:port you actually use). Fill RDS host,
   username, password. Watch two things:

   - **NLA login** passes?
   - **Picture appears** (H.264/AVC444 + WebCodecs)?

## What this PoC deliberately omits

- **Authentication** (requested out of scope). Do not treat this as a
  production service. If anything beyond a trusted LAN is involved, put an
  authenticating reverse proxy in front (OIDC/Authelia), terminate TLS there,
  or restrict access to VPN/SSH tunnels. Do not simply port-forward 8180 to the
  Internet: the WS endpoint will relay arbitrary TCP connections to the RDS
  target for anyone who can reach it.
- Replacing the existing Python/WebRTC stack. This is a parallel experiment.

## Files

- `scripts/fetch-client.sh` - fetches the latest upstream release kit (full frontend, curl-first, cached, SHA-256 verified)
- `scripts/patch-client.sh` - re-applies our WSS-gateway workaround to `app.js` (idempotent; fails loudly if upstream anchors change)
- `proxy/main.go` - single Go binary: static server + WS↔TCP proxy (stdlib + gorilla/websocket), negotiating websockify's `binary` subprotocol
- `proxy/Dockerfile` - builds a `FROM scratch` static binary and runs it
- `scripts/run-poc.sh` - builds the binary (go or docker fallback) and runs it

## Decision rule after the PoC

- NLA OK **and** picture renders -> WASM path is viable; consider productionising.
- NLA fails or black screen -> do not force it; keep the current architecture
  (optionally just swap Python orchestration for Go / shrink the image).
