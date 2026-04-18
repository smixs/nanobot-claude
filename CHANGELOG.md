# Changelog

## 0.1.1 — tool use

* Shim now invokes `claude -p` with `--dangerously-skip-permissions` so the
  agent can use Read / Bash / Edit / Write / WebFetch / WebSearch without
  interactive confirmation (required for headless operation).
* SECURITY: combined with `--dangerously-skip-permissions`, nanobot's
  `allowFrom: ["*"]` becomes an RCE surface. Updated docs to require
  narrowing `allowFrom` to specific Telegram user_ids.

## 0.1.0 — initial working shape

* OpenAI-compat shim (`shim/server.py`) forwarding `/v1/chat/completions`
  to the `claude` CLI.
* Two systemd-user units (`claude-shim.service`, `nanobot.service`).
* `scripts/install.sh` idempotent installer.
* `scripts/verify.sh` non-destructive health checks.
* `docs/ARCHITECTURE.md`, `docs/LEARNINGS.md`, `docs/SECURITY.md`.
* Known gaps: no streaming (SSE), no tool-use passthrough.
