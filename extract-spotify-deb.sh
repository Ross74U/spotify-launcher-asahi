#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  extract-spotify-deb.sh <spotify-client.deb> [output-dir]

Extract a Spotify .deb without installing it, then report likely Linux
executables and bundled shared-library dependencies.

Output layout:
  <output-dir>/rootfs/          extracted data.tar.* payload
  <output-dir>/control/         extracted control.tar.* metadata, if present
  <output-dir>/manifest.txt     executables, ELF files, shared objects, wrappers
  <output-dir>/run-spotify.sh   helper launcher using bundled library paths

Examples:
  ./extract-spotify-deb.sh spotify-client_1.x_amd64.deb
  ./extract-spotify-deb.sh spotify-client_1.x_amd64.deb ~/spotify-patch/spotify-extracted

Notes:
  This script does not install anything and does not need root.
  For amd64 Spotify on ARM Linux, run the extracted binary through your emulator
  or binfmt/qemu setup; this script only unpacks and identifies files.
USAGE
}

fail() { echo "error: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

DEB="${1:-}"
[[ -n "$DEB" ]] || { usage >&2; exit 2; }
[[ -f "$DEB" ]] || fail "deb file not found: $DEB"

if [[ $# -ge 2 ]]; then
  OUT="$2"
else
  base="$(basename "$DEB")"
  base="${base%.deb}"
  OUT="./${base}-extracted"
fi

ROOTFS="$OUT/rootfs"
CONTROL="$OUT/control"
MANIFEST="$OUT/manifest.txt"
RUNNER="$OUT/run-spotify.sh"
TMP="$OUT/.tmp"

rm -rf "$TMP"
mkdir -p "$ROOTFS" "$CONTROL" "$TMP"

extract_tar_stream() {
  local member="$1"
  local dest="$2"
  case "$member" in
    *.tar)    ar p "$DEB" "$member" | tar -x -C "$dest" ;;
    *.tar.gz) ar p "$DEB" "$member" | tar -xz -C "$dest" ;;
    *.tar.xz) ar p "$DEB" "$member" | tar -xJ -C "$dest" ;;
    *.tar.bz2) ar p "$DEB" "$member" | tar -xj -C "$dest" ;;
    *.tar.zst)
      have zstd || fail "data uses zstd; install zstd or bsdtar"
      ar p "$DEB" "$member" | zstd -dc | tar -x -C "$dest"
      ;;
    *) fail "unsupported tar member: $member" ;;
  esac
}

if have ar; then
  mapfile -t MEMBERS < <(ar t "$DEB")
elif have bsdtar; then
  # bsdtar can extract .deb directly on many systems; still prefer ar when present.
  bsdtar -tf "$DEB" > "$TMP/members"
  mapfile -t MEMBERS < "$TMP/members"
else
  fail "need 'ar' from binutils, or bsdtar"
fi

DATA_MEMBER=""
CONTROL_MEMBER=""
for m in "${MEMBERS[@]}"; do
  [[ "$m" == data.tar* ]] && DATA_MEMBER="$m"
  [[ "$m" == control.tar* ]] && CONTROL_MEMBER="$m"
done
[[ -n "$DATA_MEMBER" ]] || fail "no data.tar.* member found in deb"

if have ar; then
  echo "extracting payload: $DATA_MEMBER -> $ROOTFS"
  extract_tar_stream "$DATA_MEMBER" "$ROOTFS"
  if [[ -n "$CONTROL_MEMBER" ]]; then
    echo "extracting control: $CONTROL_MEMBER -> $CONTROL"
    extract_tar_stream "$CONTROL_MEMBER" "$CONTROL"
  fi
else
  echo "extracting payload with bsdtar -> $ROOTFS"
  bsdtar -xf "$DEB" -C "$TMP"
  extract_tar_stream "$DATA_MEMBER" "$ROOTFS"
  [[ -n "$CONTROL_MEMBER" ]] && extract_tar_stream "$CONTROL_MEMBER" "$CONTROL"
fi

# Some .deb tar payloads store paths as ./opt/..., normalize queries through ROOTFS.
SPOTIFY_BIN=""
for candidate in \
  "$ROOTFS/usr/share/spotify/spotify" \
  "$ROOTFS/opt/spotify/spotify" \
  "$ROOTFS/usr/bin/spotify"; do
  if [[ -e "$candidate" ]]; then
    SPOTIFY_BIN="$candidate"
    break
  fi
done

{
  echo "# Spotify deb extraction manifest"
  echo "deb: $(realpath "$DEB" 2>/dev/null || printf '%s' "$DEB")"
  echo "output: $(realpath "$OUT" 2>/dev/null || printf '%s' "$OUT")"
  echo "data-member: $DATA_MEMBER"
  [[ -n "$CONTROL_MEMBER" ]] && echo "control-member: $CONTROL_MEMBER"
  echo

  if [[ -n "$SPOTIFY_BIN" ]]; then
    echo "# Likely main Spotify entrypoint"
    printf '%s\n' "${SPOTIFY_BIN#$ROOTFS/}"
    echo
  fi

  echo "# Executable files (-perm -111)"
  find "$ROOTFS" -type f -perm /111 -printf '%P\n' | sort || true
  echo

  echo "# ELF files detected by magic"
  if have file; then
    while IFS= read -r -d '' f; do
      desc="$(file -b "$f" || true)"
      case "$desc" in
        *ELF*) printf '%s\t%s\n' "${f#$ROOTFS/}" "$desc" ;;
      esac
    done < <(find "$ROOTFS" -type f -print0)
  else
    echo "file(1) not found; skipping ELF magic scan"
  fi
  echo

  echo "# Bundled shared libraries (*.so*)"
  find "$ROOTFS" -type f \( -name '*.so' -o -name '*.so.*' \) -printf '%P\n' | sort || true
  echo

  echo "# Wrapper/scripts mentioning spotify"
  grep -RIl --exclude-dir='.tmp' -e 'spotify' "$ROOTFS/usr/bin" "$ROOTFS/opt" "$ROOTFS/usr/share" 2>/dev/null | sed "s#^$ROOTFS/##" | sort || true
  echo

  echo "# Dynamic dependency hints for ELF executables"
  echo "# ldd is only reliable when architecture matches host/binfmt is configured."
  if have ldd; then
    while IFS= read -r exe; do
      full="$ROOTFS/$exe"
      [[ -f "$full" ]] || continue
      if have file && file -b "$full" | grep -q 'ELF'; then
        echo
        echo "## $exe"
        LD_LIBRARY_PATH="$ROOTFS/usr/share/spotify:$ROOTFS/opt/spotify:${LD_LIBRARY_PATH:-}" ldd "$full" 2>&1 | sed 's/^/  /' || true
      fi
    done < <(find "$ROOTFS" -type f -perm /111 -printf '%P\n' | sort)
  else
    echo "ldd not found; skipping"
  fi
} > "$MANIFEST"

# Build a helper runner. It deliberately uses paths relative to the extraction dir.
cat > "$RUNNER" <<'RUNNER_EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS="$HERE/rootfs"

pick() {
  for p in \
    "$ROOTFS/usr/share/spotify/spotify" \
    "$ROOTFS/opt/spotify/spotify" \
    "$ROOTFS/usr/bin/spotify"; do
    [[ -e "$p" ]] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

BIN="$(pick)" || { echo "Cannot find Spotify binary under $ROOTFS" >&2; exit 1; }
export LD_LIBRARY_PATH="$ROOTFS/usr/share/spotify:$ROOTFS/opt/spotify:${LD_LIBRARY_PATH:-}"
export PATH="$ROOTFS/usr/bin:$PATH"

# If BIN is an absolute symlink into /usr/share/spotify, resolve it inside ROOTFS.
if [[ -L "$BIN" ]]; then
  target="$(readlink "$BIN")"
  if [[ "$target" = /* && -e "$ROOTFS$target" ]]; then
    BIN="$ROOTFS$target"
  fi
fi

exec "$BIN" "$@"
RUNNER_EOF
chmod +x "$RUNNER"

rm -rf "$TMP"

echo "done"
echo "rootfs:   $ROOTFS"
echo "manifest: $MANIFEST"
echo "runner:   $RUNNER"
if [[ -n "$SPOTIFY_BIN" ]]; then
  echo "main:     ${SPOTIFY_BIN#$ROOTFS/}"
else
  echo "main:     not found; inspect manifest"
fi
