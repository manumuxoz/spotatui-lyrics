#!/usr/bin/env bash
# Diagnose a spotatui-lyrics installation.
# Usage: scripts/doctor.sh [--network]

set -u

network=0
if [ "${1:-}" = "--network" ]; then
  network=1
fi

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/spotatui"
config="$config_dir/config.yml"
plugin_dir="$config_dir/plugins/spotatui-lyrics"
log_dir="${TMPDIR:-/tmp}/spotatui_logs"
problems=0
warnings=0

ok() { printf 'OK   %s\n' "$1"; }
warn() { printf 'WARN %s\n' "$1"; warnings=$((warnings + 1)); }
bad() { printf 'FAIL %s\n' "$1"; problems=$((problems + 1)); }

echo "spotatui-lyrics doctor"
echo

if command -v spotatui >/dev/null 2>&1; then
  ok "spotatui: $(spotatui --version 2>/dev/null | head -1)"
else
  bad "spotatui is not on PATH"
fi

if [ -f "$plugin_dir/main.lua" ]; then
  ok "plugin files: $plugin_dir"
else
  bad "plugin files missing: $plugin_dir"
  echo "     install with: spotatui plugin add manumuxoz/spotatui-lyrics"
fi

if command -v spotatui >/dev/null 2>&1; then
  if spotatui plugin list 2>/dev/null | grep -q "spotatui-lyrics"; then
    ok "plugin registered in spotatui"
  else
    bad "plugin is not registered; run: spotatui plugin add manumuxoz/spotatui-lyrics"
  fi
fi

if [ -f "$config" ]; then
  if grep -q '^[[:space:]]*ytlyrics_open:' "$config"; then
    ok "command binding present: ytlyrics_open"
  else
    bad "no ytlyrics_open binding in $config"
    echo "     add under plugin_commands:"
    echo "       ytlyrics_open: \"ctrl-l\""
  fi

  if grep -Eq '^[[:space:]]*lyrics_view:[[:space:]]*B[[:space:]]*$' "$config"; then
    if grep -q '^[[:space:]]*ytlyrics_open:[[:space:]]*B' "$config"; then
      bad "B is still bound to lyrics_view and to ytlyrics_open"
      echo "     move the built-in view first: keybindings.lyrics_view: ctrl-b"
    else
      warn "lyrics_view is still B; the plugin can use ctrl-l but not B"
    fi
  fi
else
  bad "config not found: $config"
fi

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/spotatui"
if [ -f "$state_dir/instance.pid" ]; then
  running_pid="$(cat "$state_dir/instance.pid" 2>/dev/null || true)"
  if [ -n "$running_pid" ] && kill -0 "$running_pid" 2>/dev/null; then
    running_log="$log_dir/spotatuilog$running_pid"
    if [ -f "$running_log" ] && grep -q "no lua plugin files found" "$running_log"; then
      warn "running spotatui (pid $running_pid) started before the plugin was installed"
      echo "     restart spotatui to load it"
    fi
  fi
fi

if [ -d "$log_dir" ]; then
  latest="$(ls -t "$log_dir"/spotatuilog* 2>/dev/null | head -1 || true)"
  if [ -n "$latest" ] && grep -q "launching interactive terminal ui" "$latest"; then
    if grep -q "loaded .* lua plugin file" "$latest"; then
      ok "latest TUI log shows a loaded Lua plugin: $latest"
    else
      warn "latest TUI log has no 'loaded lua plugin' line: $latest"
      echo "     if spotatui was already open when you installed, restart it"
    fi
    if grep -Eq "plugin 'spotatui-lyrics' failed to load|ytlyrics.*error" "$latest"; then
      bad "latest TUI log contains a plugin load/runtime error"
      grep -E "spotatui-lyrics|ytlyrics" "$latest" | tail -10
    fi
  fi
fi

if [ "$network" -eq 1 ]; then
  echo
  echo "Network checks"
  if bash "$(dirname "$0")/smoke.sh"; then
    ok "provider endpoints reachable"
  else
    bad "one or more provider endpoints failed"
  fi
fi

echo
if [ "$problems" -gt 0 ]; then
  echo "$problems problem(s), $warnings warning(s)"
  echo "After fixing the config or installing the plugin, restart spotatui."
  exit 1
fi
echo "No blocking problems ($warnings warning(s))."
echo "If you just installed or changed the config, restart spotatui: plugins load at startup."
