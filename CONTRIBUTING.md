# Contributing

Thanks for helping. The plugin is plain Lua 5.4 with no external runtime dependencies.

## Setup

```bash
git clone https://github.com/manumuxoz/spotatui-lyrics
cd spotatui-lyrics
lua5.4 tests/run.lua
```

For a live spotatui test, symlink the checkout into the plugin directory:

```bash
ln -s "$PWD" "${XDG_CONFIG_HOME:-$HOME/.config}/spotatui/plugins/spotatui-lyrics"
```

Add a binding in `config.yml`:

```yaml
plugin_commands:
  ytlyrics_open: "ctrl-l"
```

Restart spotatui. Use `spotatui --debug` and the `i` debug popup while iterating.

## Tests

The suite runs with the system Lua 5.4:

```bash
lua5.4 tests/run.lua
```

Guidelines:

- Add a test for every metadata shape, LRC edge case or scoring rule you change.
- Provider tests use `tests/harness.lua`; do not hit the network in the test suite.
- `scripts/smoke.sh` is the manual live-network check (requires `curl` and `jq`).
- Keep the test runner dependency-free; no luarocks packages in CI.

## Code style

- 2-space indentation, Lua 5.4.
- Modules under `ytlyrics/` with the `ytlyrics` prefix in `require` paths.
- No new runtime dependencies and no native code.
- Wrap risky parsing in `pcall`; never let a callback throw.
- Respect the API v6 limits: small callbacks, async HTTP, one timer, no blocking I/O.
- Keep new comments about behavior, not line-by-line narration.

## Adding a provider

1. Implement `search(query, ctx, done)` in `ytlyrics/providers/<name>.lua`.
2. Register it in `ytlyrics/engine.lua` and `ytlyrics/config.lua`.
3. Add fixtures/tests in `tests/test_providers.lua`.
4. Document endpoints, auth, timestamps and rate limits in `docs/PROVIDERS.md`.
5. State clearly whether the provider is official/unofficial and whether it returns timestamps.

Do not bundle lyrics, API keys or user credentials. Do not persist provider responses.

## Pull requests

- Keep the change focused; separate refactors from behavior changes.
- Run `lua5.4 tests/run.lua` and the syntax loop:
  ```bash
  for f in main.lua ytlyrics/*.lua ytlyrics/providers/*.lua; do
    lua5.4 -e "assert(loadfile('$f'))" || exit 1
  done
  ```
- Update `CHANGELOG.md` for user-visible changes.
- If you change a key, env var or provider default, update both `README.md` and `README.es.md`.
- Describe the user-visible effect and the test that covers it.

## Reporting

Use the issue templates. Include the spotatui version, OS, YouTube URL, enabled providers and the `i` debug output. Do not paste full lyrics into issues.
