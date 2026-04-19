# Changelog

## 0.1.2 — longer timeouts for heavy tool use

* Default `CLAUDE_TIMEOUT_S` raised from 180 s to 1800 s (30 min) in the
  systemd unit. Heavy agent tasks (`tar -x` on a 1.8 GB archive, multi-file
  edits, chained bash) regularly run past 3 min. Old value caused 502 Bad
  Gateway even when claude was still making progress.
* `MAX_INTERNAL_RETRIES` defaulted to 2 (was 3). With a 30-min timeout,
  retrying three times can burn up to 90 min before we return an error
  to nanobot — two is plenty.
* Both knobs remain env-overridable if you need different bounds.

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
