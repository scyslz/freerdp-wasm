#!/usr/bin/env bash
# Apply our WSS-gateway workaround to the upstream app.js.
# Idempotent: skips if already patched; fails loudly if upstream anchors changed.
# The pristine upstream copy is saved as app.js.orig (refreshed on each upstream update).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_DIR="${SITE_DIR:-$ROOT/proxy/site}"
APP="$SITE_DIR/app.js"
ORIG="$SITE_DIR/app.js.orig"

if [[ ! -f "$APP" ]]; then
  echo "[freerdp-wasm] app.js not found at $APP" >&2
  exit 1
fi

if grep -q 'route.url ??' "$APP"; then
  echo "[freerdp-wasm] app.js already patched; skipping"
  exit 0
fi

# Save the pristine upstream copy before modifying.
cp "$APP" "$ORIG"

python3 - "$APP" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()

subs = [
    # 1. Pass the full URL (when provided) to Emscripten's WebSocket layer.
    (
        'if (!host.direct) Module.websocket.url = route.secure ? "wss://" : "ws://";',
        'if (!host.direct) Module.websocket.url = route.url ?? (route.secure ? "wss://" : "ws://");',
    ),
    # 2. Accept a path in the gateway URL.
    (
        'const m = /^(wss?):\\/\\/([^/?#]+)\\/?$/i.exec(a);',
        'const m = /^(wss?):\\/\\/([^/?#]+)(\\/[^?#]*)?$/i.exec(a);',
    ),
    # 3. Return the full URL alongside host/secure.
    (
        '  return { host: secure && !/:\\d+$/.test(hop) ? hop + ":443" : hop, secure };',
        '  const host = secure && !/:\\d+$/.test(hop) ? hop + ":443" : hop;\n'
        '  const url = m && m[3] ? `${m[1].toLowerCase()}://${m[2]}${m[3]}` : undefined;\n'
        '  return { host, secure, url };',
    ),
]
for old, new in subs:
    if old not in s:
        sys.exit(f"[freerdp-wasm] patch anchor missing in upstream app.js (upstream may have changed):\n  {old}")
    s = s.replace(old, new, 1)
open(p, 'w').write(s)
print("[freerdp-wasm] app.js patched for full WSS gateway URLs")
PY
