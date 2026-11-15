# Changelog

All notable changes to this project are documented here.

## [0.4.0] - 2026-11-15

### Added

- Native playbar patch for spotatui v0.48.0: the existing playbar is rendered below plugin screens, and `config().behavior.native_playbar` lets the plugin hide its fallback controls.
- `scripts/build-patched-spotatui.sh` to clone, patch and build spotatui with the recommended features.

### Changed

- With the patched build, the plugin publishes lyrics + a compact status line only; the real playbar provides title, artist, controls and progress.

## [0.3.0] - 2026-11-15

### Added

- lrcmux provider (LRCLIB-compatible + native endpoints) for a large jump in synced coverage, especially Latin/indie tracks. Enabled by default; MIT and self-hostable.
- Provider table, default provider list and smoke checks now include lrcmux.

## [0.2.2] - 2026-11-15

### Added

- `ytlyrics_open_alt` command. The recommended config now binds both `B` and `ctrl+b` to the plugin screen, with the built-in view moved to `F2`.

### Changed

- `ctrl+b`, the built-in lyrics key, now opens the plugin screen when the recommended config is applied; the old built-in view remains available on `F2`.

## [0.2.1] - 2026-11-15

### Added

- Playback-control hint row above the progress line (`p` prev, `space` play/pause, `n` next, `<`/`>` seek), closer to the main playbar.

### Changed

- Documentation now consistently describes the provider race and the playbar-style progress line.

## [0.2.0] - 2026-11-15

### Added

- YouTube Music (InnerTube) provider: exact `videoId`, `timedLyricsModel` cue ranges via the Android Music client, plain-text fallback when the entity has no cues, and an art-track search when the exact video only exposes text.
- Provider race: LRCLIB, YouTube Music, NetEase and Genius now start in parallel; the first usable result is rendered provisionally and upgraded when a synced source arrives.
- NetEase is enabled by default; the default provider list is `lrclib,ytmusic,netease,genius`.
- Base-title query priority for `Song // Subtitle`, `Song | Album` and similar shapes.
- Warm cache: after the first open, the next tracks are prefetched (`SPOTATUI_LYRICS_WARM`, default on).
- Automatic display bias based on the UI tick rate, plus `SPOTATUI_LYRICS_BIAS_MS` override.
- Calibration key `t`; fine offset steps `,`/`.` (`SPOTATUI_LYRICS_OFFSET_FINE`, default 50 ms); seek compensates for the display bias.
- Playbar-style progress row using the same `⣿`/`⣉` glyphs, time and remaining time as the main playbar.
- In-screen flash messages, because spotatui notifications are not drawn over plugin screens.

### Changed

- The lyrics window now follows a parallel race instead of a sequential provider chain.
- Automatic bias is one UI tick by default (≈250 ms) instead of a fixed 120 ms.
- The build now ships a YouTube Music provider and its live smoke check.

### Fixed

- The progress bar no longer uses the bordered `gauge` widget; it matches the main playbar's glyphs and ordering.
- Calibration accounts for the automatic bias while playing and paused.
- Plugin messages (calibration, match changes, errors) are visible on the plugin screen.

## [0.1.1] - 2026-11-15

### Added

- `scripts/doctor.sh` installation diagnostic: binary/version, installed files, plugin registration, command binding, running instance and log checks.
- Troubleshooting notes for the most common failure: spotatui was already open before the plugin was installed, so `B` still opened the built-in lyrics view until restart.

## [0.1.0] - 2026-11-13

### Added

- Custom lyrics screen for spotatui (Lua API v6) with current-line highlight, auto-follow, manual scroll and progress gauge.
- YouTube metadata repair: noise tags, featured credits, artist/title splitting (both directions), quoted titles, channel/curator cleanup, version suffixes and album tags.
- Ranked metadata query variants with `m` cycling and `r` reset/retry.
- Provider chain: LRCLIB (primary), Genius (plain fallback), NetEase (optional synced fallback).
- Match scoring by title, artist and duration; synced results are preferred, plain results are kept as fallback.
- Plain-text timeline estimation, clearly labelled as estimated.
- Per-video timing offset, persisted across restarts; seek to a line.
- Debug popup with raw metadata, queries, requests, scores and selected source.
- English and Spanish UI; `SPOTATUI_LYRICS_LANG` override.
- In-memory LRU cache; no lyrics written to disk.
- Test suite with a mock spotatui API v6, provider fixtures and a full plugin render test.
- CI, release packaging and issue templates.
