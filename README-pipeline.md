# spotify-patch pipeline

This repo contains:

- `spotify-launcher/`: patched `kpcyrd/spotify-launcher` source. The patch adds:
  - `--architecture <ARCH>` to resolve/download a target Debian architecture such as `amd64`.
  - `--print-deb-url` to print the latest Spotify `.deb` URL without installing.
  - `--download-dir <DIR>` to download the `.deb` without installing or running Spotify.
- `extract-spotify-deb.sh`: extracts a Spotify `.deb` into `rootfs/` and writes a manifest.
- `bundle-system-deps-into-rootfs.sh`: copies `ldd`-resolved shared libraries and common runtime data into the extracted `rootfs`.
- `run-pipeline.sh`: builds the patched launcher, downloads latest Spotify client, extracts it, and tries to make it more self-contained.

Run:

```bash
./run-pipeline.sh --architecture amd64 --clean
```

Outputs:

```text
spotify-client-deb/spotify-client_*.deb
spotify-client-extracted/rootfs/usr/share/spotify/spotify
spotify-client-extracted/run-spotify.sh
spotify-client-extracted/run-spotify-portable.sh
```

`run-spotify-portable.sh` uses the dynamic loader and libraries copied into `rootfs` when bundling succeeds. It is more isolated than the plain `.deb` payload, but GUI applications still depend on the host kernel, display server, audio stack, network, GPU/devices, and any emulator/binfmt needed for foreign architecture execution.
