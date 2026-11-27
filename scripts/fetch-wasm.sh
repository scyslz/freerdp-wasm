#!/usr/bin/env bash
# Fetch only the prebuilt FreeRDP WASM binaries from the upstream release kit.
# All other site assets (JS/HTML/CSS, including our app.js patch) are tracked in git.
# Cached under $CACHE with SHA-256 verification; safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIT="${KIT:-congzhangzh/rdp-release-kit}"
SITE_DIR="${SITE_DIR:-$ROOT/proxy/site}"
CACHE="${CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/freerdp-web-poc}"

log() { echo "[freerdp-wasm] $*" >&2; }

mkdir -p "$SITE_DIR/jspi" "$CACHE"

CURL=(curl -fsSL --retry 5 --retry-all-errors --retry-delay 2
          --connect-timeout 20 --max-time 0)

# Pin the same release the tracked frontend was taken from, so the JS glue and
# the WASM binaries stay in sync. Override with KIT_TAG=<tag> when upgrading.
if [[ -f "$SITE_DIR/CLIENT" ]]; then
  TAG="$(cat "$SITE_DIR/CLIENT")"
else
  TAG="${KIT_TAG:-web-20261126.1-b8390ae2807a}"
fi

BASE="https://github.com/$KIT/releases/download/$TAG"
ASSET="freerdp-web-page.zip"
ZIP="$CACHE/freerdp-web-page-$TAG.zip"
SHA="$ZIP.sha256"

download() {
  local url="$1" dest="$2"
  "${CURL[@]}" -C - -o "$dest" "$url" || {
    log "resumed download failed; retrying from scratch"
    rm -f "$dest"
    "${CURL[@]}" -o "$dest" "$url"
  }
}

need_fetch=1
if [[ -s "$SITE_DIR/sdl-freerdp.wasm" && -s "$SITE_DIR/jspi/sdl-freerdp.wasm" ]]; then
  need_fetch=0
  log "WASM binaries present ($TAG); skipping fetch"
fi

if [[ "$need_fetch" -eq 1 ]]; then
  log "fetching release kit $TAG (this downloads the full kit once, then extracts only .wasm)"

  expected=""
  [[ -f "$SHA" ]] && expected="$(awk '{print $1}' "$SHA")"
  cached=""
  if [[ -f "$ZIP" ]]; then
    cached="$(sha256sum "$ZIP" | awk '{print $1}')"
  fi
  if [[ -n "$expected" && "$cached" == "$expected" ]]; then
    log "cache hit: $(basename "$ZIP") (SHA-256 OK)"
  else
    download "$BASE/$ASSET.sha256" "$SHA"
    download "$BASE/$ASSET" "$ZIP"
  fi

  expected="$(awk '{print $1}' "$SHA")"
  actual="$(sha256sum "$ZIP" | awk '{print $1}')"
  if [[ -z "$expected" || "$actual" != "$expected" ]]; then
    log "SHA-256 mismatch (expected $expected, got $actual)"
    exit 1
  fi
  log "SHA-256 OK; extracting WASM binaries only"

  # Extract only the two .wasm files into a temp dir, then copy into place.
  tmp="$(mktemp -d)"
  python3 - "$ZIP" "$tmp" <<'PY'
import sys, zipfile
z, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(z) as f:
    for name in f.namelist():
        if name.endswith('.wasm'):
            f.extract(name, out)
PY
  cp "$tmp/sdl-freerdp.wasm" "$SITE_DIR/sdl-freerdp.wasm"
  cp "$tmp/jspi/sdl-freerdp.wasm" "$SITE_DIR/jspi/sdl-freerdp.wasm"
  rm -rf "$tmp"
fi

echo "$TAG" > "$SITE_DIR/CLIENT"
log "ready: $(du -h "$SITE_DIR/sdl-freerdp.wasm" | cut -f1) + $(du -h "$SITE_DIR/jspi/sdl-freerdp.wasm" | cut -f1) WASM"
