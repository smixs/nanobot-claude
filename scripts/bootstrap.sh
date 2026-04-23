#!/usr/bin/env bash
#
# Interactive one-liner installer for nanobot-claude-oauth.
#
#   curl -fsSL https://raw.githubusercontent.com/smixs/nanobot-claude/main/scripts/bootstrap.sh | bash
#
# Plain-text prompts (no whiptail/ncurses) so it works on ANY terminal
# that has bash + curl, including dumb TTYs, SSH-without-pty, containers.
# Delegates to scripts/install.sh with env vars set. Requires Claude
# Code CLI to be pre-installed and signed in — OAuth needs a browser,
# which cannot be scripted.
#
# CRITICAL: the entire script body is wrapped in main() { ... } and
# invoked at the bottom. When bash reads commands from a pipe (as in
# `curl | bash`), it reads them byte-by-byte from stdin. Any `exec < /dev/tty`
# at top level would reassign stdin and subsequent script lines would be
# read from the TTY instead of the pipe — bash silently waits for user
# input that looks like nothing happening. Wrapping in a function makes
# bash parse the whole body into memory first, then the exec redirect
# is harmless. Pattern copied from rustup, nvm, homebrew installers.

set -euo pipefail

main() {
  # ---------- 0. Make failures visible ----------
  # If anything exits non-zero, print WHERE and WHICH command failed.
  # Without this, `set -e` + subtle errors produce a silent exit.
  trap 'ec=$?; printf "\n\033[31m✗ bootstrap failed at line %s (exit %s)\n  command: %s\033[0m\n" "$LINENO" "$ec" "$BASH_COMMAND" >&2; exit "$ec"' ERR

  # ---------- 0a. First line of visible output (proves we got here) ----------
  printf '\n\033[1m▶ nanobot-claude-oauth bootstrap\033[0m\n'
  printf '  shell=%s  user=%s  pwd=%s  term=%s\n\n' "${BASH_VERSION:-?}" "${USER:-?}" "$PWD" "${TERM:-unset}"

  # ---------- 0b. stdin handling for curl|bash ----------
  # Safe to redirect here: main() has already been fully parsed,
  # bash does not need to read more script from the pipe.
  if [ -t 0 ]; then
    echo "  stdin: interactive tty — no redirect needed"
  else
    if [ ! -c /dev/tty ]; then
      echo "✗ /dev/tty not available — bootstrap.sh needs a controlling terminal." >&2
      echo "  Download and run directly instead:" >&2
      echo "    curl -fsSL <url> -o bootstrap.sh && bash bootstrap.sh" >&2
      exit 1
    fi
    echo "  stdin: piped — redirecting to /dev/tty for prompts"
    exec < /dev/tty
  fi

  local REPO_URL="${REPO_URL:-https://github.com/smixs/nanobot-claude.git}"
  local INSTALL_DIR="${INSTALL_DIR:-$HOME/nanobot-claude-oauth}"

  # ---------- 1. Explain sudo usage and cache credentials ----------
  cat <<'EOF'

==> This installer needs sudo for two things:
      • apt-get / dnf install  (git, curl, jq if missing)
      • loginctl enable-linger (services survive logout)

    Your password will be asked ONCE and cached (~15 min).
    No further prompts after that.

EOF

  if ! sudo -v; then
    echo "✗ sudo required. Aborting." >&2
    exit 1
  fi

  # Keep the sudo timestamp fresh while this script runs.
  ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
  local SUDO_KEEPALIVE_PID=$!
  trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

  # ---------- 2. System dependencies ----------
  local need=()
  for bin in git curl jq; do
    command -v "$bin" >/dev/null || need+=("$bin")
  done
  if [ ${#need[@]} -eq 0 ]; then
    echo "✓ git / curl / jq already installed"
  else
    echo "▶ Installing missing packages: ${need[*]}"
    if command -v apt-get >/dev/null; then
      sudo apt-get update -qq
      sudo apt-get install -y "${need[@]}"
    elif command -v dnf >/dev/null; then
      sudo dnf install -y "${need[@]}"
    else
      echo "✗ Unsupported distro. Install manually: ${need[*]}" >&2
      exit 1
    fi
  fi

  # ---------- 3. uv (Python tool manager — needed by install.sh) ----------
  if ! command -v uv >/dev/null; then
    echo "▶ Installing uv (Astral)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi
  export PATH="$HOME/.local/bin:$PATH"
  echo "✓ uv: $(command -v uv)"

  # ---------- 4. Hard checks: claude CLI + credentials ----------
  if ! command -v claude >/dev/null; then
    cat >&2 <<'EOF'

✗ Claude Code CLI is not installed.

  Install it first:
      npm install -g @anthropic-ai/claude-code

  Then sign in (opens a browser for Pro/Max OAuth):
      claude

  Re-run this bootstrap afterwards.
EOF
    exit 1
  fi
  if [ ! -f "$HOME/.claude/.credentials.json" ]; then
    cat >&2 <<'EOF'

✗ Claude CLI is installed but not signed in.

  Run:
      claude
  Complete the OAuth flow (Pro/Max) in your browser, then re-run.
EOF
    exit 1
  fi
  echo "✓ claude: $(command -v claude)"

  # ---------- 5. Clone or update the repo ----------
  if [ -d "$INSTALL_DIR/.git" ]; then
    echo "▶ Repo already at $INSTALL_DIR — git pull --ff-only"
    git -C "$INSTALL_DIR" pull --ff-only
  else
    echo "▶ Cloning $REPO_URL -> $INSTALL_DIR"
    git clone "$REPO_URL" "$INSTALL_DIR"
  fi

  # ---------- 6. Interactive wizard (plain-text prompts) ----------
  cat <<'EOF'

============================================================
  Configuration — 3 questions
============================================================

EOF

  # --- 6.1 Telegram bot token ---
  local TG_TOKEN
  cat <<'EOF'
1/3.  Telegram bot token (from @BotFather).
      Leave BLANK to skip — you can add it later in ~/.nanobot/config.json.

EOF
  read -rp "      Token: " TG_TOKEN
  echo ""

  # --- 6.2 Model ---
  local MODEL_CHOICE MODEL
  cat <<'EOF'
2/3.  Claude model:
        1) claude-sonnet-4-6   (balanced — default)
        2) claude-opus-4-7     (smartest, slower, pricier)
        3) claude-haiku-4-5    (fastest, cheapest)

EOF
  read -rp "      Choice [1]: " MODEL_CHOICE
  case "${MODEL_CHOICE:-1}" in
    1|"")  MODEL="claude-sonnet-4-6" ;;
    2)     MODEL="claude-opus-4-7" ;;
    3)     MODEL="claude-haiku-4-5" ;;
    *)     MODEL="$MODEL_CHOICE" ;;  # pass-through for custom model names
  esac
  echo "      → $MODEL"
  echo ""

  # --- 6.3 Timezone ---
  local TZ
  cat <<'EOF'
3/3.  Timezone (IANA name).
      Examples: UTC, Europe/Moscow, Europe/Berlin, Asia/Tashkent,
                Asia/Tokyo, America/New_York, America/Los_Angeles.

EOF
  read -rp "      Timezone [UTC]: " TZ
  TZ="${TZ:-UTC}"
  echo "      → $TZ"

  # ---------- 7. Linger ----------
  echo ""
  if loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q Linger=yes; then
    echo "✓ linger already enabled"
  else
    echo "▶ Enabling linger (services survive logout)"
    sudo loginctl enable-linger "$USER"
    echo "✓ linger enabled"
  fi

  # ---------- 8. Delegate to install.sh ----------
  cat <<'EOF'

============================================================
  Running install.sh
============================================================

EOF
  export TELEGRAM_BOT_TOKEN="$TG_TOKEN" NANOBOT_MODEL="$MODEL" NANOBOT_TZ="$TZ"
  cd "$INSTALL_DIR"
  ./scripts/install.sh

  # ---------- 9. Verify ----------
  echo ""
  echo "▶ Running verify.sh"
  ./scripts/verify.sh || true

  cat <<'EOF'

============================================================
  Done
============================================================

Check:
    systemctl --user status claude-shim nanobot
    curl -s http://127.0.0.1:8787/health
    curl -s http://127.0.0.1:18790/health

Logs:
    journalctl --user -fu claude-shim
    journalctl --user -fu nanobot

Send a message to your Telegram bot to test end-to-end.

EOF
}

main "$@"
