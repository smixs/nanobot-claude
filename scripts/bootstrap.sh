#!/usr/bin/env bash
#
# Interactive one-liner installer for nanobot-claude-oauth.
#
#   curl -fsSL https://raw.githubusercontent.com/smixs/nanobot-claude/main/scripts/bootstrap.sh | bash
#
# Prompts for Telegram token, model, and timezone via whiptail, then
# delegates to scripts/install.sh with env vars set. Requires Claude
# Code CLI to be pre-installed and signed in — that step needs a
# browser-based OAuth flow which cannot be automated.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/smixs/nanobot-claude.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/nanobot-claude-oauth}"

# When invoked via `curl | bash`, stdin is the pipe — whiptail and any
# `read` would block. Redirecting stdin to the controlling terminal
# fixes that; used by rustup and oh-my-zsh for the same reason.
[ -t 0 ] || exec < /dev/tty

# ---------- 1. Bootstrap whiptail itself (needed for all subsequent TUI) ----------
if ! command -v whiptail >/dev/null; then
  echo "▶ Installing TUI dependency (whiptail)..."
  if command -v apt-get >/dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y whiptail
  elif command -v dnf >/dev/null; then
    sudo dnf install -y newt
  else
    echo "ERROR: unsupported distro. Install whiptail (Debian/Ubuntu) or newt (RHEL) manually." >&2
    exit 1
  fi
fi

# ---------- 2. Explain sudo usage in TUI, then cache credentials ----------
whiptail --title "Nanobot-Claude installer" --msgbox "\
This installer needs sudo for:

 • apt-get install (git, curl, jq if missing)
 • loginctl enable-linger (services survive logout)

Your sudo password will be requested ONCE and cached (~15 min)
for the rest of the install. No further prompts." 14 70

if ! sudo -v; then
  whiptail --msgbox "sudo is required. Aborting." 8 50
  exit 1
fi

# Keep the sudo timestamp fresh for the entire run.
( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# ---------- 3. Install system dependencies ----------
ensure_deps() {
  local need=()
  for bin in git curl jq; do
    command -v "$bin" >/dev/null || need+=("$bin")
  done
  [ ${#need[@]} -eq 0 ] && return 0

  if command -v apt-get >/dev/null; then
    sudo apt-get install -y "${need[@]}"
  elif command -v dnf >/dev/null; then
    sudo dnf install -y "${need[@]}"
  else
    whiptail --msgbox "Unsupported distro. Install manually: ${need[*]}" 10 60
    exit 1
  fi
}
ensure_deps

# ---------- 4. uv (Python package manager — needed by install.sh) ----------
if ! command -v uv >/dev/null; then
  echo "▶ Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"

# ---------- 5. Hard checks: claude CLI + credentials ----------
# We intentionally do NOT auto-install claude-code: its OAuth login
# requires a browser, which cannot be scripted. Fail clearly instead.
if ! command -v claude >/dev/null; then
  whiptail --msgbox "\
Claude Code CLI is not installed.

Install it first:
    npm install -g @anthropic-ai/claude-code

Then sign in (opens a browser):
    claude

Re-run this bootstrap afterwards." 14 70
  exit 1
fi
if [ ! -f "$HOME/.claude/.credentials.json" ]; then
  whiptail --msgbox "\
Claude CLI is installed but not signed in.

Run:
    claude

Complete the OAuth flow (Pro/Max subscription) in your browser,
then re-run this bootstrap." 14 70
  exit 1
fi

# ---------- 6. Clone or update the repo ----------
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "▶ Repo already present — pulling latest"
  git -C "$INSTALL_DIR" pull --ff-only
else
  echo "▶ Cloning $REPO_URL into $INSTALL_DIR"
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

# ---------- 7. Interactive wizard ----------
TG_TOKEN=$(whiptail --title "Step 1 of 3 — Telegram" --inputbox "\
Telegram Bot Token (from @BotFather).

Leave blank to skip the Telegram channel — you can always
add it later by editing ~/.nanobot/config.json." \
  12 70 "" 3>&1 1>&2 2>&3) || exit 1

MODEL=$(whiptail --title "Step 2 of 3 — Model" --menu \
  "Choose the Claude model nanobot will use:" \
  15 65 3 \
  "claude-sonnet-4-6" "Balanced — good default for a chat bot" \
  "claude-opus-4-7"   "Smartest, more expensive, slower" \
  "claude-haiku-4-5"  "Fastest, cheapest, lower quality" \
  3>&1 1>&2 2>&3) || exit 1

TZ=$(whiptail --title "Step 3 of 3 — Timezone" --menu \
  "Choose an IANA timezone for the agent:" \
  20 60 11 \
  "UTC"                 "Coordinated Universal Time" \
  "Europe/Moscow"       "Moscow" \
  "Europe/London"       "London" \
  "Europe/Berlin"       "Berlin / Central Europe" \
  "America/New_York"    "New York / US Eastern" \
  "America/Los_Angeles" "Los Angeles / US Pacific" \
  "Asia/Tashkent"       "Tashkent" \
  "Asia/Dubai"          "Dubai / Gulf" \
  "Asia/Tokyo"          "Tokyo" \
  "Asia/Shanghai"       "Shanghai" \
  "Other"               "Enter an IANA name manually" \
  3>&1 1>&2 2>&3) || exit 1
if [ "$TZ" = "Other" ]; then
  TZ=$(whiptail --inputbox "Enter IANA timezone (e.g. Pacific/Auckland):" \
    10 60 "UTC" 3>&1 1>&2 2>&3) || exit 1
fi

# ---------- 8. Enable linger so services survive logout ----------
if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q Linger=yes; then
  sudo loginctl enable-linger "$USER"
  echo "✓ linger enabled"
fi

# ---------- 9. Delegate to install.sh ----------
export TELEGRAM_BOT_TOKEN="$TG_TOKEN" NANOBOT_MODEL="$MODEL" NANOBOT_TZ="$TZ"
cd "$INSTALL_DIR"
./scripts/install.sh

# ---------- 10. Final verification and summary ----------
./scripts/verify.sh || true

whiptail --title "Done" --msgbox "\
Installation finished!

Check services:
    systemctl --user status claude-shim nanobot

Follow logs:
    journalctl --user -fu claude-shim
    journalctl --user -fu nanobot

Send a message to your Telegram bot to test end-to-end." 16 70
