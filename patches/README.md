# Native playbar patch

This patch makes spotatui draw its **existing** playbar below plugin screens. It
is the same `draw_playbar` used by the main layout, the built-in lyrics view and
the cover-art view; the plugin screen simply reserves the playbar area instead
of taking the whole terminal.

## What it changes

- `src/tui/ui/plugin_screen.rs`: splits the terminal with
  `fullscreen_view_layout` and calls `draw_playbar` for the lower area.
- `src/core/plugin_api.rs`: adds `behavior.native_playbar = true` to the plugin
  configuration snapshot, so `spotatui-lyrics` hides its fallback progress row
  and lets the real playbar render.

It applies cleanly to spotatui **v0.48.0**.

## Build

```bash
scripts/build-patched-spotatui.sh
```

The script clones `v0.48.0`, applies this patch and builds a release binary with
the YouTube, scripting, streaming, local-files, Subsonic, radio, Qobuz, cover-art,
audio-visualizer and MCP features. It needs the PipeWire development headers for
`audio-viz` (`sudo apt install libpipewire-0.3-dev` on Debian/Ubuntu).

## Prebuilt asset

Release `v0.4.1` includes:

- `spotatui-0.48.0-native-playbar-linux-x86_64`
- `SHA256SUMS`

The binary is Linux x86_64 and was built on 2026-11-15 with rustc 1.100.0.
Keep `behavior.disable_auto_update: true` so an official update does not replace
it. The original binary can be restored from your own backup.

## Revert

If you no longer want the patched binary, restore the official build:

```bash
mv ~/.local/bin/spotatui-0.48.0-original ~/.local/bin/spotatui
```

The plugin still works without the patch; it falls back to its compact progress
line.
