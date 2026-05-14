#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./run-pipeline.sh [options]

Build the patched spotify-launcher, download the latest Spotify .deb for the
selected Debian architecture, extract it into this repo, and bundle dynamic
runtime dependencies into rootfs when possible.

Options:
  --architecture ARCH   Debian package architecture to download (default: amd64)
  --download-dir DIR    Where to place downloaded .deb (default: ./spotify-client-deb)
  --extract-dir DIR     Where to extract rootfs/control (default: ./spotify-client-extracted)
  --no-bundle-deps      Skip copying ldd-resolved system deps into rootfs
  --clean               Remove download/extract dirs before running
  -h, --help            Show this help

Outputs:
  spotify-client-deb/*.deb
  spotify-client-extracted/rootfs/usr/share/spotify/spotify
  spotify-client-extracted/run-spotify.sh
  spotify-client-extracted/run-spotify-portable.sh  if dependency bundling succeeds
USAGE
}

ARCH="amd64"
DOWNLOAD_DIR=""
EXTRACT_DIR=""
BUNDLE_DEPS=1
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --architecture) ARCH="${2:?missing value for --architecture}"; shift 2 ;;
    --download-dir) DOWNLOAD_DIR="${2:?missing value for --download-dir}"; shift 2 ;;
    --extract-dir) EXTRACT_DIR="${2:?missing value for --extract-dir}"; shift 2 ;;
    --no-bundle-deps) BUNDLE_DEPS=0; shift ;;
    --clean) CLEAN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HERE/spotify-client-deb}"
EXTRACT_DIR="${EXTRACT_DIR:-$HERE/spotify-client-extracted}"
LAUNCHER_DIR="$HERE/spotify-launcher"
EXTRACT_SCRIPT="$HERE/extract-spotify-deb.sh"
BUNDLE_SCRIPT="$HERE/bundle-system-deps-into-rootfs.sh"

[[ -d "$LAUNCHER_DIR" ]] || { echo "missing $LAUNCHER_DIR" >&2; exit 1; }
[[ -x "$EXTRACT_SCRIPT" ]] || { echo "missing executable $EXTRACT_SCRIPT" >&2; exit 1; }

if [[ "$CLEAN" -eq 1 ]]; then
  rm -rf "$DOWNLOAD_DIR" "$EXTRACT_DIR"
fi
mkdir -p "$DOWNLOAD_DIR"

echo "==> Building patched spotify-launcher"
(
  cd "$LAUNCHER_DIR"
  cargo build --release
)
LAUNCHER_BIN="$LAUNCHER_DIR/target/release/spotify-launcher"
[[ -x "$LAUNCHER_BIN" ]] || { echo "build did not produce $LAUNCHER_BIN" >&2; exit 1; }

echo "==> Resolving latest Spotify .deb URL for architecture=$ARCH"
URL="$($LAUNCHER_BIN --architecture "$ARCH" --print-deb-url)"
echo "$URL" | tee "$HERE/latest-${ARCH}-deb-url.txt"

echo "==> Downloading .deb into $DOWNLOAD_DIR"
"$LAUNCHER_BIN" --architecture "$ARCH" --download-dir "$DOWNLOAD_DIR"
DEB_PATH="$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -name 'spotify-client_*.deb' -printf '%T@ %p\n' | sort -n | tail -n1 | cut -d' ' -f2-)"
[[ -n "$DEB_PATH" && -f "$DEB_PATH" ]] || { echo "download did not create spotify-client_*.deb" >&2; exit 1; }
echo "deb=$DEB_PATH"

echo "==> Extracting .deb into $EXTRACT_DIR"
rm -rf "$EXTRACT_DIR"
"$EXTRACT_SCRIPT" "$DEB_PATH" "$EXTRACT_DIR"

if [[ "$BUNDLE_DEPS" -eq 1 ]]; then
  echo "==> Bundling ldd-resolved runtime dependencies into rootfs"
  if "$BUNDLE_SCRIPT" "$EXTRACT_DIR"; then
    echo "portable runner=$EXTRACT_DIR/run-spotify-portable.sh"
  else
    echo "warning: dependency bundling failed; plain runner remains at $EXTRACT_DIR/run-spotify.sh" >&2
  fi
fi

echo "==> Done"
echo "deb:       $DEB_PATH"
echo "rootfs:    $EXTRACT_DIR/rootfs"
echo "manifest:  $EXTRACT_DIR/manifest.txt"
echo "runner:    $EXTRACT_DIR/run-spotify.sh"
[[ -x "$EXTRACT_DIR/run-spotify-portable.sh" ]] && echo "portable:  $EXTRACT_DIR/run-spotify-portable.sh"
