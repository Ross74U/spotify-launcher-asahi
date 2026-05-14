#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  bundle-system-deps-into-rootfs.sh <extracted-dir>

Copy the dynamic-loader and shared-library dependencies resolved by ldd into
<extracted-dir>/rootfs, then generate run-spotify-portable.sh.

This makes the Spotify client much more self-contained than the plain .deb
payload. It still uses the host kernel/display/audio/network devices.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 ]]; then
  usage
  exit 0
fi

EXTRACTED="$(cd "$1" && pwd)"
ROOTFS="$EXTRACTED/rootfs"
BIN="$ROOTFS/usr/share/spotify/spotify"
[[ -x "$BIN" ]] || { echo "missing executable: $BIN" >&2; exit 1; }

ARCH="$(uname -m)"
FILE_OUT="$(file -b "$BIN")"
if [[ "$FILE_OUT" == *"x86-64"* && "$ARCH" != "x86_64" ]]; then
  echo "warning: Spotify is x86-64 but host is $ARCH; ldd may need binfmt/qemu." >&2
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

export LD_LIBRARY_PATH="$ROOTFS/usr/share/spotify:$ROOTFS/opt/spotify:${LD_LIBRARY_PATH:-}"
ldd "$BIN" > "$TMP"

copy_one() {
  local src="$1"
  [[ -e "$src" ]] || return 0
  case "$src" in
    "$ROOTFS"/*) return 0 ;;
  esac
  local dest="$ROOTFS$src"
  mkdir -p "$(dirname "$dest")"
  if [[ -L "$src" ]]; then
    cp -a --no-dereference "$src" "$dest"
    local real
    real="$(readlink -f "$src")"
    if [[ -n "$real" && -e "$real" && "$real" != "$src" ]]; then
      mkdir -p "$ROOTFS$(dirname "$real")"
      cp -a --dereference "$real" "$ROOTFS$real"
    fi
  else
    cp -a --dereference "$src" "$dest"
  fi
}

# ldd formats include:
#   libfoo.so => /usr/lib/libfoo.so (0x...)
#   /lib64/ld-linux-x86-64.so.2 => /usr/lib64/ld-linux-x86-64.so.2 (...)
#   /lib64/ld-linux-x86-64.so.2 (...)
mapfile -t DEPS < <(
  awk '
    /=> \/.*\(/ { print $3; next }
    /^\s*\/.*\(/ { print $1; next }
  ' "$TMP" | sort -u
)

printf '# Bundled dependency copy log\n' > "$EXTRACTED/bundled-deps.txt"
for dep in "${DEPS[@]}"; do
  [[ -n "$dep" && "$dep" == /* ]] || continue
  echo "$dep" >> "$EXTRACTED/bundled-deps.txt"
  copy_one "$dep"
done

# Some systems print the requested interpreter through readelf more reliably than ldd.
INTERP="$(readelf -l "$BIN" | sed -n 's@.*Requesting program interpreter: \(.*\)]@\1@p' | head -n1 || true)"
if [[ -n "$INTERP" ]]; then
  copy_one "$INTERP"
  echo "$INTERP" >> "$EXTRACTED/bundled-deps.txt"
fi

# Copy common runtime data that GUI/NSS/TLS stacks often require. Missing dirs are okay.
for p in \
  /etc/ssl/certs \
  /etc/ca-certificates \
  /usr/share/ca-certificates \
  /usr/share/glib-2.0/schemas \
  /usr/lib/gdk-pixbuf-2.0 \
  /usr/lib/gtk-3.0 \
  /usr/share/fonts \
  /etc/fonts \
  /usr/share/fontconfig; do
  if [[ -e "$p" && ! -e "$ROOTFS$p" ]]; then
    mkdir -p "$ROOTFS$(dirname "$p")"
    cp -a "$p" "$ROOTFS$p"
    echo "$p" >> "$EXTRACTED/bundled-deps.txt"
  fi
done

cat > "$EXTRACTED/run-spotify-portable.sh" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS="$HERE/rootfs"
BIN="$ROOTFS/usr/share/spotify/spotify"

LD_SO=""
for p in \
  "$ROOTFS/lib64/ld-linux-x86-64.so.2" \
  "$ROOTFS/usr/lib64/ld-linux-x86-64.so.2" \
  "$ROOTFS/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" \
  "$ROOTFS/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"; do
  [[ -x "$p" ]] && { LD_SO="$p"; break; }
done
[[ -n "$LD_SO" ]] || { echo "Cannot find bundled x86-64 dynamic loader in rootfs" >&2; exit 1; }

LIBPATH="$ROOTFS/usr/share/spotify:$ROOTFS/opt/spotify:$ROOTFS/usr/lib:$ROOTFS/usr/lib64:$ROOTFS/lib:$ROOTFS/lib64:$ROOTFS/usr/lib/x86_64-linux-gnu:$ROOTFS/lib/x86_64-linux-gnu"
export PATH="$ROOTFS/usr/bin:${PATH:-}"
export XDG_DATA_DIRS="$ROOTFS/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export FONTCONFIG_PATH="$ROOTFS/etc/fonts"
export SSL_CERT_DIR="$ROOTFS/etc/ssl/certs"
export GSETTINGS_SCHEMA_DIR="$ROOTFS/usr/share/glib-2.0/schemas"

exec "$LD_SO" --library-path "$LIBPATH" "$BIN" "$@"
RUNNER
chmod +x "$EXTRACTED/run-spotify-portable.sh"

echo "Bundled $(wc -l < "$EXTRACTED/bundled-deps.txt") dependency/data entries into $ROOTFS"
echo "Generated: $EXTRACTED/run-spotify-portable.sh"
