# Changelog

All notable changes to this project are documented here.

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
