# Troubleshooting

## First, get the debug view

Open the lyrics screen and press `i`. The popup shows:

- the current route, playback URI, status, provider, sync/estimate flags;
- offset, match variant and line count;
- the raw title/channel and the parsed candidates;
- every query, provider request, score and error;
- the selected result and its source URL.

This is the most useful thing to include in a bug report. The same information goes to the app log when `SPOTATUI_LYRICS_DEBUG=1`.

## Logs

spotatui prints the log path at startup:

```
Logging to: /tmp/spotatui_logs/spotatuilog<pid>
```

Useful lines:

- `[ytlyrics] ready · providers=... · sources=...` — the plugin loaded and read its config.
- `[ytlyrics] ...` — lookup and provider details (verbose with `SPOTATUI_LYRICS_DEBUG=1`).
- `plugin 'spotatui-lyrics' failed to load: ...` — a Lua syntax/load error. Check `lua5.4 -e "assert(loadfile('main.lua'))"` and the `require` paths.
- `error in ...` / `one strike` — a callback was disabled after an error. The debug popup and log identify which one.

## Plugin does not load

Run the doctor from the installed plugin:

```bash
~/.config/spotatui/plugins/spotatui-lyrics/scripts/doctor.sh
```

It checks the binary, installed files, `plugins.lock`, the command binding, the running instance and the latest log. `--network` also runs the provider smoke test.

1. `spotatui --version` must be **0.48+**.
2. `spotatui plugin --help` must work (the build has the `scripting` feature; official releases do).
3. `spotatui plugin list` must show `spotatui-lyrics`.
4. Restart spotatui: there is no hot reload.
5. Confirm the plugin directory has `main.lua` at its root and `ytlyrics/` next to it.

If you installed by symlink, check that the symlink target still exists.

## Key does nothing

- `B` is the built-in `lyrics_view`; a plugin command bound to `B` is skipped. Move `lyrics_view` first:
  ```yaml
  keybindings:
    lyrics_view: "ctrl-b"
  plugin_commands:
    ytlyrics_open: "B"
  ```
- The command name must be exactly `ytlyrics_open`.
- Reserved keys (`H`, `M`, `L`, arrows, `Backspace`, `Enter`) cannot be bound to plugin commands.
- Check the log for `skipping plugin command ...` warnings.

## “No lyrics found”

Try, in order:

1. `m` — the parser may have picked the wrong artist/title split. Variants include the raw YouTube row, swapped artist/title and title-only.
2. `r` — resets to match 1 and retries.
3. `SPOTATUI_LYRICS_PROVIDERS=lrclib,netease,genius spotatui` — NetEase adds synced coverage for some catalogues.
4. Check network access to the provider.
5. Press `i`: if every provider returns “no acceptable match”, the song is not in those databases (or the metadata is too far off).

For a non-music video (long mix, podcast, tutorial), the screen says so. `r` searches anyway.

## Wrong song

- `m` cycles variants. The footer shows `match N/M`.
- The debug popup shows exactly which title/artist each provider returned and its score.
- If the correct song is present but has a low score, open an issue with the debug output. Include the YouTube URL; it makes the metadata reproducible.

## Timing is off

- Synced lyrics: use `[` / `]` for 250 ms, `{` / `}` for 1 s, `0` to reset. The offset is saved per video.
- Plain lyrics (`text · estimated`): the timeline is a line-length estimate. It will never be exact; use a provider with timestamps if available.
- The default `SPOTATUI_LYRICS_BIAS_MS=120` compensates for spotatui's one-tick playback snapshot delay. Increase it if lines consistently appear late; decrease it if they appear early.

## Screen looks empty or clipped

- Plugin screens have a border and the app's playbar is not drawn; the plugin adds its own gauge and footer.
- On a very short terminal, reduce the context:
  ```bash
  SPOTATUI_LYRICS_CONTEXT=3 spotatui
  ```
- Long titles are shortened; the full title is in the debug popup.

## Provider errors

The debug popup shows HTTP status and transport errors.

- `403` from Genius: the browser-UA POST fallback may be disabled (`SPOTATUI_LYRICS_GENIUS_POST=0`) or blocked. Enable it or disable Genius.
- `429` from LRCLIB: wait and retry; the plugin stops the current lookup rather than hammering.
- NetEase timeouts/blocks: common in some regions; it is opt-in for that reason.
- `invalid JSON`: the provider returned an HTML challenge or a changed response; include the URL and status in the report.

## Reset plugin state

The plugin stores only offsets and match variants in spotatui's per-plugin store:

```
$XDG_CONFIG_HOME/spotatui/plugin-data/spotatui-lyrics.json
```

Removing that file (with spotatui closed) resets all offsets and variants. It does not contain lyrics or credentials.

## Reporting a bug

Include:

- spotatui version and OS,
- the YouTube URL (or a minimal reproduction),
- `SPOTATUI_LYRICS_PROVIDERS` and any non-default env vars,
- the debug popup text (or `SPOTATUI_LYRICS_DEBUG=1` log lines),
- whether `B`/`ctrl-l` opens the screen.

Open an issue at <https://github.com/manumuxoz/spotatui-lyrics/issues>.
