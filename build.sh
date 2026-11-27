#!/usr/bin/env bash
# Build the single-file freerdp-wasm binary.
# Every build: fetch the latest upstream frontend, re-apply our app.js patch,
# then compile the Go proxy with the frontend embedded.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$ROOT/dist-release/wsproxy}"

# Resolve to an absolute path: go build runs from proxy/, so a relative OUT
# would otherwise land inside proxy/ instead of the repo root.
case "$OUT" in
  /*) ;;
  *) OUT="$(pwd)/$OUT" ;;
esac

if ! command -v go >/dev/null 2>&1; then
  echo "[freerdp-wasm] Go toolchain not found in PATH (need >= 1.22)." >&2
  exit 1
fi

# 1. Fetch the newest upstream client into proxy/site/ (SHA-256 verified).
#    Set REUSE_SITE=1 to keep the current copy, or KIT_TAG=<tag> to pin.
if [[ "${SKIP_FETCH:-0}" != "1" ]]; then
  "$ROOT/scripts/fetch-client.sh"
fi

# 2. Re-apply our WSS gateway workaround (idempotent; fails if upstream changed).
"$ROOT/scripts/patch-client.sh"

if [[ ! -s "$ROOT/proxy/site/sdl-freerdp.wasm" ]]; then
  echo "[freerdp-wasm] missing proxy/site/sdl-freerdp.wasm" >&2
  exit 1
fi

# 3. Compile the single-file binary.
mkdir -p "$(dirname "$OUT")"
echo "[freerdp-wasm] building $(go version) -> $OUT"
(cd "$ROOT/proxy" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$OUT" .)

echo "[freerdp-wasm] done: $(du -h "$OUT" | cut -f1) $OUT"
file "$OUT" 2>/dev/null || true
