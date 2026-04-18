# Changelog

## 0.1.0 — initial working shape

* OpenAI-compat shim (`shim/server.py`) forwarding `/v1/chat/completions`
  to the `claude` CLI.
* Two systemd-user units (`claude-shim.service`, `nanobot.service`).
* `scripts/install.sh` idempotent installer.
* `scripts/verify.sh` non-destructive health checks.
* `docs/ARCHITECTURE.md`, `docs/LEARNINGS.md`, `docs/SECURITY.md`.
* Known gaps: no streaming (SSE), no tool-use passthrough.
