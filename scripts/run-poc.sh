#!/usr/bin/env bash
# One-shot PoC: single Go binary serves the WASM site (COOP/COEP) and proxies
# /ws <-> RDP TCP. No nginx, no auth.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${RDP_TARGET:-127.0.0.1:3389}"
LISTEN="${PROXY_LISTEN:-0.0.0.0:8180}"
SITE="$ROOT/dist/site"

if [[ ! -f "$SITE/index.html" ]]; then
  echo "[freerdp-wasm] static site not found. Run scripts/fetch-client.sh first." >&2
  exit 1
fi

PROXY_BIN="$ROOT/proxy/wsproxy"
needs_build=0
if [[ ! -x "$PROXY_BIN" ]]; then
  needs_build=1
elif [[ "$ROOT/proxy/main.go" -nt "$PROXY_BIN" || "$ROOT/proxy/go.mod" -nt "$PROXY_BIN" || "$ROOT/proxy/go.sum" -nt "$PROXY_BIN" || -n "$(find "$ROOT/proxy/site" -newer "$PROXY_BIN" -type f -print -quit 2>/dev/null)" ]]; then
  echo "[freerdp-wasm] proxy sources changed; rebuilding..."
  needs_build=1
fi
if [[ "$needs_build" -eq 1 ]]; then
  echo "[freerdp-wasm] building Go proxy..."
  if command -v go >/dev/null 2>&1; then
    (cd "$ROOT/proxy" && CGO_ENABLED=0 go build -trimpath -o "$PROXY_BIN" .)
  elif command -v docker >/dev/null 2>&1; then
    docker build -t wasm-poc-wsproxy "$ROOT/proxy"
    CID="$(docker create wasm-poc-wsproxy)"
    docker cp "$CID:/wsproxy" "$PROXY_BIN"
    docker rm "$CID" >/dev/null
  else
    echo "[freerdp-wasm] neither go nor docker found; cannot build proxy." >&2
    exit 1
  fi
fi

echo "[freerdp-wasm] serving $SITE | binding $LISTEN (all interfaces by default; open http://localhost:${LISTEN##*:} locally) | ws -> $TARGET"
exec "$PROXY_BIN" -listen "$LISTEN" -target "$TARGET" -site "$SITE"
