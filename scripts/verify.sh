#!/usr/bin/env bash
# Non-destructive end-to-end checks for an existing install.
set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

ok=0
fail=0
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    green "✓ $name"; ok=$((ok+1))
  else
    red   "✗ $name"; fail=$((fail+1))
  fi
}

check "claude CLI present"        command -v claude
check "claude --version"          claude --version
check "credentials.json present"  test -f "$HOME/.claude/.credentials.json"
check "nanobot installed"         command -v nanobot
check "nanobot config exists"     test -f "$HOME/.nanobot/config.json"
check "shim systemd unit active"  systemctl --user is-active claude-shim
check "nanobot systemd unit active" systemctl --user is-active nanobot
check "shim /health"              curl -sfm 3 http://127.0.0.1:8787/health
check "nanobot /health"           curl -sfm 3 http://127.0.0.1:18790/health

echo
echo "  ok=$ok  fail=$fail"
[ "$fail" -eq 0 ] || exit 1
