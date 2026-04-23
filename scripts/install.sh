#!/usr/bin/env bash
#
# Idempotent installer for nanobot-claude-oauth on a Linux VPS with systemd.
#
# Steps:
#   1. Verify prerequisites (uv, node/npm, claude CLI, systemd --user, linger)
#   2. Install nanobot (`uv tool install nanobot-ai`) if missing
#   3. Run `nanobot onboard` to scaffold ~/.nanobot/config.json
#   4. Patch config.json to point at the local shim (jq)
#   5. Sync shim venv, install both systemd-user units, start them
#   6. Smoke-test end-to-end (shim /health, nanobot /health)
#
# This script never touches the user's ~/.claude/.credentials.json — claude
# CLI must already be signed in (run `claude` once interactively if not).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TG_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
MODEL="${NANOBOT_MODEL:-claude-sonnet-4-6}"
TZ_NAME="${NANOBOT_TZ:-UTC}"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ---------- 1. prereqs ----------
step "Checking prerequisites"

for bin in uv jq curl systemctl; do
  if ! command -v "$bin" >/dev/null; then
    red "missing: $bin"
    exit 1
  fi
done

if ! command -v claude >/dev/null; then
  red "claude CLI not found. Install from https://claude.com/product/claude-code and sign in first."
  exit 1
fi

if ! claude --version >/dev/null 2>&1; then
  red "claude CLI present but not responding to --version"
  exit 1
fi

if [ ! -f "$HOME/.claude/.credentials.json" ]; then
  red "~/.claude/.credentials.json not found. Run 'claude' once to sign in, then re-run this script."
  exit 1
fi

if ! systemctl --user is-system-running >/dev/null 2>&1; then
  yellow "systemd --user reports not-running — continuing, but double-check your session has a user bus."
fi

# ---------- 2. nanobot ----------
step "Installing nanobot"
if ! command -v nanobot >/dev/null; then
  uv tool install nanobot-ai
else
  green "nanobot already present ($(nanobot --version 2>/dev/null || echo 'unknown'))"
fi

# ---------- 3. onboard ----------
step "Onboarding nanobot (safe to re-run)"
if [ ! -f "$HOME/.nanobot/config.json" ]; then
  nanobot onboard
else
  green "~/.nanobot/config.json already exists — leaving intact"
fi

# ---------- 4. patch config ----------
step "Patching ~/.nanobot/config.json (custom provider → shim)"
TMP="$(mktemp)"
jq --arg model "custom/$MODEL" \
   --arg tz "$TZ_NAME" \
   --arg tok "$TG_TOKEN" \
   '
     .providers.custom.apiBase = "http://127.0.0.1:8787/v1"
     | .providers.custom.apiKey = "dummy-not-checked-by-shim"
     | .agents.defaults.model = $model
     | .agents.defaults.timezone = $tz
     | if $tok != "" then
         .channels.telegram.enabled = true
         | .channels.telegram.token = $tok
         | .channels.telegram.allowFrom = (if (.channels.telegram.allowFrom // [] | length) == 0 then ["*"] else .channels.telegram.allowFrom end)
         | .channels.telegram.streaming = false
       else . end
   ' "$HOME/.nanobot/config.json" > "$TMP"
mv "$TMP" "$HOME/.nanobot/config.json"
chmod 600 "$HOME/.nanobot/config.json"
green "config patched (model=custom/$MODEL)"

# ---------- 5. shim & units ----------
step "Syncing shim venv"
( cd "$REPO_DIR/shim" && uv sync --quiet )

mkdir -p "$HOME/.config/systemd/user" \
         "$HOME/.local/state/claude-shim" \
         "$HOME/.local/state/nanobot"

# Expand %h manually so units are portable across systemd versions.
install -m 0644 "$REPO_DIR/systemd/claude-shim.service" "$HOME/.config/systemd/user/claude-shim.service"
install -m 0644 "$REPO_DIR/systemd/nanobot.service"    "$HOME/.config/systemd/user/nanobot.service"

# Replace %h with actual $HOME for broader compatibility.
sed -i "s|%h|$HOME|g" "$HOME/.config/systemd/user/claude-shim.service"
sed -i "s|%h|$HOME|g" "$HOME/.config/systemd/user/nanobot.service"

# Resolve claude binary path at install time. The unit template assumes
# $HOME/.local/bin/claude, but npm global installs may put it in
# /usr/local/bin or elsewhere — hardcoding breaks the unit with
# FileNotFoundError under systemd-user (which has a minimal PATH).
CLAUDE_PATH="$(command -v claude || true)"
[ -n "$CLAUDE_PATH" ] || { red "claude not in PATH — cannot resolve binary"; exit 1; }
CLAUDE_DIR="$(dirname "$CLAUDE_PATH")"
sed -i "s|^Environment=\"CLAUDE_BIN=.*\"|Environment=\"CLAUDE_BIN=$CLAUDE_PATH\"|" \
  "$HOME/.config/systemd/user/claude-shim.service"
sed -i "s|PATH=$HOME/.local/bin|PATH=$CLAUDE_DIR:$HOME/.local/bin|" \
  "$HOME/.config/systemd/user/claude-shim.service"
green "claude resolved at $CLAUDE_PATH"

# Shim working dir must exist in the location the unit expects.
mkdir -p "$HOME/nanobot-claude-oauth/shim"
cp -rf "$REPO_DIR/shim/"* "$HOME/nanobot-claude-oauth/shim/"

systemctl --user daemon-reload
systemctl --user enable --now claude-shim.service
systemctl --user enable --now nanobot.service

# Enable linger so user services survive logout. Try non-interactively
# first (works if bootstrap.sh already cached sudo or NOPASSWD is set);
# fall back to a visible tip if sudo would need a password.
if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q Linger=yes; then
  if sudo -n loginctl enable-linger "$USER" 2>/dev/null; then
    green "linger enabled"
  else
    yellow "Tip: sudo loginctl enable-linger $USER  (needs password; otherwise services die on logout)"
  fi
fi

# ---------- 6. smoke test ----------
step "Smoke tests"
sleep 3

if curl -sf http://127.0.0.1:8787/health >/dev/null; then
  green "shim /health ok"
else
  red "shim /health failed"
  journalctl --user -u claude-shim -n 40 --no-pager || true
  exit 1
fi

SMOKE=$(curl -sS -X POST http://127.0.0.1:8787/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"reply exactly: pong\"}]}")
CONTENT=$(echo "$SMOKE" | jq -r '.choices[0].message.content // "ERROR"')
if [ "$CONTENT" = "pong" ]; then
  green "shim /v1/chat/completions ok (pong)"
else
  red "shim returned: $SMOKE"
  exit 1
fi

if systemctl --user is-active nanobot >/dev/null; then
  green "nanobot service active"
else
  red "nanobot service not active"
  journalctl --user -u nanobot -n 40 --no-pager || true
  exit 1
fi

green "Done. Send a message to your Telegram bot to test end-to-end."
