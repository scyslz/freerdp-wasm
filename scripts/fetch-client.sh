#!/usr/bin/env bash
# Fetch the latest prebuilt WASM FreeRDP client release kit into ./proxy/site.
# No Emscripten toolchain needed -- we consume upstream prebuilt artifacts.
#
# The upstream site.sh uses python urllib to page through the GitHub releases
# API, which can die with http.client.IncompleteRead on large responses.  We
# avoid that entirely: curl downloads the release-kit zip with retries and
# resume support, we verify its SHA-256, and unzip it.  A git clone + site.sh
# remains as a fallback.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${REPO:-congzhangzh/freerdp-web}"
KIT="${KIT:-congzhangzh/rdp-release-kit}"
TAG="${TAG:-latest}"
SITE_DIR="${SITE_DIR:-$ROOT/proxy/site}"
CACHE="${CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/freerdp-web-poc}"

mkdir -p "$SITE_DIR" "$CACHE"

CURL=(curl -fsSL --retry 5 --retry-all-errors --retry-delay 2
          --connect-timeout 20 --max-time 0)

log() { echo "[freerdp-wasm] $*" >&2; }

# ---------------------------------------------------------------------------
# Fast path: download the release-kit's prebuilt web client zip directly.
# ---------------------------------------------------------------------------
# KIT_TAG pins a specific kit pre-release. SITE_ZIP_URL / SITE_ZIP_SHA_URL
# override the asset URLs completely (offline / flaky-API escape hatch).
if [[ -n "${KIT_TAG:-}" ]]; then
  : # explicit kit tag wins
elif [[ "$TAG" == web-* ]]; then
  KIT_TAG="$TAG"
else
  KIT_TAG="latest"
fi

api_releases() {
  # Stream the releases list with curl (one page at a time) into a small file.
  # curl handles the chunked transport; python only parses the saved bytes.
  local out="$1" page=1 batch
  : > "$out"
  while :; do
    batch="$CACHE/releases-page-$page.json"
    if ! "${CURL[@]}" -o "$batch" \
         "https://api.github.com/repos/$KIT/releases?per_page=100&page=$page"; then
      return 1
    fi
    python3 - "$batch" >> "$out" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    batch = json.load(f)
if not isinstance(batch, list):
    sys.exit("unexpected GitHub API response")
for r in batch:
    # Only the fields needed to pick the newest usable web-* release.
    print(json.dumps({
        "tag_name": r.get("tag_name"),
        "name": r.get("name") or "",
        "body": r.get("body") or "",
        "draft": r.get("draft"),
        "published_at": r.get("published_at"),
        "assets": [a["name"] for a in r.get("assets", [])],
    }))
PY
    # Stop when a short page is returned. Count items via python (the file is
    # JSON, not one-line-per-release, so `wc -l` is meaningless here).
    if [[ $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$batch") -lt 100 ]]; then break; fi
    page=$((page + 1))
  done
}

resolve_kit_tag() {
  # "latest" -> newest web-* pre-release with a freerdp-web-page.zip asset.
  [[ "$KIT_TAG" != "latest" ]] && { echo "$KIT_TAG"; return 0; }

  local releases="$CACHE/releases.json"
  if [[ -n "${KIT_RELEASES_FILE:-}" ]]; then
    cp "$KIT_RELEASES_FILE" "$releases"
  elif ! api_releases "$releases"; then
    log "GitHub API failed; set KIT_TAG=<web-tag> or KIT_RELEASES_FILE=<file> to retry offline."
    return 1
  fi

  python3 - "$releases" <<'PY'
import json, re, sys
found = []
with open(sys.argv[1]) as f:
    for line in f:
        r = json.loads(line)
        tag = r.get("tag_name") or ""
        if not re.fullmatch(r"web-\d{8}\.\d+-[0-9a-f]{12}", tag):
            continue
        if r.get("draft") or not r.get("published_at"):
            continue
        if (r.get("body") or "").startswith("WITHDRAWN"):
            continue
        if "freerdp-web-page.zip" not in r.get("assets", []):
            continue
        found.append(r)
if not found:
    sys.exit("no web client pre-release found in the release kit")
found.sort(key=lambda r: r["published_at"], reverse=True)
print(found[0]["tag_name"])
PY
}

download_asset() {
  local url="$1" dest="$2"
  log "downloading $url"
  # -C - resumes a partial file; retry-all-errors also retries mid-stream cuts.
  # Start from a clean partial if the server ignores Range and returns 200.
  "${CURL[@]}" -C - -o "$dest" "$url" || {
    log "resumed download failed; retrying from scratch"
    rm -f "$dest"
    "${CURL[@]}" -o "$dest" "$url"
  }
}

fetch_direct() {
  local tag zip_url sha_url zip sha
  if [[ -n "${SITE_ZIP_URL:-}" ]]; then
    zip_url="$SITE_ZIP_URL"
    sha_url="${SITE_ZIP_SHA_URL:-$SITE_ZIP_URL.sha256}"
    tag="${KIT_TAG:-manual}"
    log "using manually configured SITE_ZIP_URL"
  elif [[ "${REUSE_SITE:-0}" == "1" && -f "$SITE_DIR/CLIENT" && -f "$SITE_DIR/index.html" ]]; then
    # Only reuse the pinned tag when explicitly asked (REUSE_SITE=1).
    # Default is to resolve the newest upstream release on every build.
    tag="$(cat "$SITE_DIR/CLIENT")"
    [[ -n "$tag" && "$tag" != "manual" ]] || return 1
    local base="https://github.com/$KIT/releases/download/$tag"
    zip_url="$base/freerdp-web-page.zip"
    sha_url="$base/freerdp-web-page.zip.sha256"
    log "reusing existing site (kit: $tag); REUSE_SITE=1"
  else
    tag="$(resolve_kit_tag)" || return 1
    local base="https://github.com/$KIT/releases/download/$tag"
    zip_url="$base/freerdp-web-page.zip"
    sha_url="$base/freerdp-web-page.zip.sha256"
    log "release kit: $tag"
  fi

  zip="$CACHE/freerdp-web-page-$tag.zip"
  sha="$zip.sha256"

  expected=""
  if [[ -f "$sha" ]]; then expected="$(awk '{print $1}' "$sha")"; fi
  cached_digest=""
  if [[ -f "$zip" ]]; then
    if command -v sha256sum >/dev/null 2>&1; then
      cached_digest="$(sha256sum "$zip" | awk '{print $1}')"
    else
      cached_digest="$(shasum -a 256 "$zip" | awk '{print $1}')"
    fi
  fi
  if [[ -n "$expected" && "$cached_digest" == "$expected" ]]; then
    log "cache hit: $(basename "$zip") (SHA-256 OK)"
  else
    download_asset "$sha_url" "$sha" || return 1
    download_asset "$zip_url" "$zip" || return 1
  fi

  # The .sha256 file names the original asset ("freerdp-web-page.zip"), which
  # differs from our cache path, so compare digests directly rather than using
  # `sha256sum -c <file>` (which checks filenames).
  expected="$(awk '{print $1}' "$sha")"
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$zip" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "$zip" | awk '{print $1}')"
  fi
  if [[ -z "$expected" || "$actual" != "$expected" ]]; then
    log "SHA-256 mismatch for $(basename "$zip") (expected $expected, got $actual)"
    return 1
  fi
  log "SHA-256 OK"

  rm -rf "${SITE_DIR:?}"
  mkdir -p "$SITE_DIR"
  python3 -m zipfile -e "$zip" "$SITE_DIR"
  echo "$tag" > "$SITE_DIR/CLIENT"
}

# ---------------------------------------------------------------------------
# Fallback: the upstream workflow (git clone + site.sh), which needs the
# python API call to succeed but can work when the API is less congested.
# ---------------------------------------------------------------------------
fetch_upstream() {
  log "trying upstream site.sh fallback"
  local tmp rc=0
  tmp="$(mktemp -d)"
  (
    local clone_args=(--depth 1)
    if [[ -n "$TAG" && "$TAG" != "latest" ]]; then
      clone_args+=(--branch "$TAG")
    fi
    git clone "${clone_args[@]}" "https://github.com/$REPO.git" "$tmp/src" || exit 1

    if [[ -f "$tmp/src/site.sh" ]]; then
      (cd "$tmp/src" && SITE="$SITE_DIR" bash ./site.sh) || exit 1
    elif [[ -d "$tmp/src/dist/site" ]]; then
      mkdir -p "$SITE_DIR"
      cp -a "$tmp/src/dist/site/." "$SITE_DIR/"
    else
      exit 1
    fi
  ) || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

main() {
  log "target dir: $SITE_DIR"
  if ! fetch_direct; then
    log "direct kit download failed"
    if [[ -n "${SITE_ZIP_URL:-}" ]]; then
      log "SITE_ZIP_URL was set explicitly; refusing silent fallback."
      exit 1
    fi
    fetch_upstream || {
      log "upstream fallback failed too."
      log "If GitHub's API is broken, pin a known-good kit tag, e.g.:"
      log "  KIT_TAG=web-20261126.1-b8390ae2807a $0"
      exit 1
    }
  fi

  if [[ ! -f "$SITE_DIR/index.html" ]]; then
    log "no index.html in $SITE_DIR; upstream layout may have changed."
    exit 1
  fi
  if ! find "$SITE_DIR" -type f -name '*.wasm' -print -quit | grep -q .; then
    log "no .wasm client found in $SITE_DIR."
    exit 1
  fi
  echo
  log "Done. Static files in $SITE_DIR:"
  find "$SITE_DIR" -maxdepth 2 -type f | head -20 || true

}

main "$@"
