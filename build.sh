#!/usr/bin/env bash
# Build the single-file freerdp-wasm binary (Go + embedded WASM client).
# The WASM binaries are fetched from upstream on demand; all other frontend
# assets (including our app.js gateway patch) are tracked in this repository.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$ROOT/dist-release/wsproxy}"

if ! command -v go >/dev/null 2>&1; then
  echo "[freerdp-wasm] Go toolchain not found in PATH (need >= 1.22)." >&2
  exit 1
fi

# Fetch the prebuilt WASM binaries if they are not present locally.
if [[ "${SKIP_WASM_FETCH:-0}" != "1" ]]; then
  "$ROOT/scripts/fetch-wasm.sh"
fi

if [[ ! -s "$ROOT/proxy/site/sdl-freerdp.wasm" ]]; then
  echo "[freerdp-wasm] missing proxy/site/sdl-freerdp.wasm (set SKIP_WASM_FETCH=0 or run scripts/fetch-wasm.sh)" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
echo "[freerdp-wasm] building $(go version) -> $OUT"
(cd "$ROOT/proxy" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$OUT" .)

echo "[freerdp-wasm] done: $(du -h "$OUT" | cut -f1) $OUT"
file "$OUT" 2>/dev/null || true
