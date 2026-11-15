#!/usr/bin/env bash
# Build spotatui v0.48.0 with the real playbar rendered below plugin screens.
#
# Usage:
#   scripts/build-patched-spotatui.sh [destination-dir]
#
# The resulting binary is at <destination-dir>/target/release/spotatui.
# Requires git, cargo, rustc >= 1.95 and the PipeWire development headers
# (`sudo apt install libpipewire-0.3-dev` on Debian/Ubuntu) for `audio-viz`.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="${1:-/tmp/opencode/spotatui-patched}"
version="${SPOTATUI_VERSION:-v0.48.0}"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo is required" >&2
  exit 1
fi

if ! rustc --version | awk '{ split($2, v, "."); exit !(v[1] > 1 || (v[1] == 1 && v[2] >= 95)) }'; then
  echo "rustc >= 1.95 is required (rustup update stable)" >&2
  exit 1
fi

rm -rf "$dest"
git clone --depth 1 --branch "$version" https://github.com/LargeModGames/spotatui "$dest"
git -C "$dest" apply "$root/patches/0001-playbar-on-plugin-screens.patch"

cd "$dest"
cargo build --release --features "scripting,youtube,local-files,subsonic,internet-radio,qobuz,soloist,cover-art,mcp-server,ai-dj,mpris,discord-rpc,self-update,audio-viz,audio-viz-cpal,queue,queue-download"

cat <<EOF

Built: $dest/target/release/spotatui

Install it (keeping the original binary):

  cp ~/.local/bin/spotatui ~/.local/bin/spotatui-0.48.0-original
  cp "$dest/target/release/spotatui" ~/.local/bin/spotatui

Then disable auto-update in config.yml so an official update does not replace
the patched binary:

  behavior:
    disable_auto_update: true

Restart spotatui. The plugin detects native_playbar=true and hides its compact
fallback progress line; the real playbar is drawn below the plugin screen.
EOF
