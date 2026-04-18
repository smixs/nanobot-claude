#!/usr/bin/env bash
# Reverts whatever install.sh set up. Leaves ~/.claude/.credentials.json alone.
set -euo pipefail

systemctl --user disable --now nanobot.service      2>/dev/null || true
systemctl --user disable --now claude-shim.service  2>/dev/null || true

rm -f "$HOME/.config/systemd/user/nanobot.service"
rm -f "$HOME/.config/systemd/user/claude-shim.service"
systemctl --user daemon-reload || true

rm -rf "$HOME/nanobot-claude-oauth/shim"
rm -rf "$HOME/.local/state/claude-shim" "$HOME/.local/state/nanobot"

echo "Removed units and state. Run 'uv tool uninstall nanobot-ai' to remove nanobot, and 'rm -rf ~/.nanobot' to drop config."
