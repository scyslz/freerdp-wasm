#!/usr/bin/env bash
# Build the single-file freerdp-wasm binary (Go + embedded WASM client).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$ROOT/dist-release/wsproxy}"

if ! command -v go >/dev/null 2>&1; then
  echo "[freerdp-wasm] Go toolchain not found in PATH (need >= 1.22)." >&2
  exit 1
fi

if [[ ! -f "$ROOT/proxy/site/index.html" ]]; then
  echo "[freerdp-wasm] embedded site missing: proxy/site/ (run scripts/fetch-client.sh first)" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
echo "[freerdp-wasm] building $(go version) -> $OUT"
(cd "$ROOT/proxy" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$OUT" .)

echo "[freerdp-wasm] done: $(du -h "$OUT" | cut -f1) $OUT"
file "$OUT" 2>/dev/null || true
