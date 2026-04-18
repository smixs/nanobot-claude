# Architecture

## One-screen diagram

```
┌──────────────────────────────────────────────────────────────────┐
│ VPS (Linux + systemd)                                            │
│                                                                  │
│ ┌──────────────┐ poll    ┌────────────────────────────────────┐  │
│ │ api.telegram │ ───────►│ nanobot gateway (systemd-user)     │  │
│ │   .org       │ ◄─────── │  httpx → direct TLS (no proxy)     │  │
│ └──────────────┘ send    │                                    │  │
│                          │  OpenAI-compat client points at    │  │
│                          │  http://127.0.0.1:8787/v1          │  │
│                          └────────────────┬───────────────────┘  │
│                                           │ POST /v1/chat/completions│
│                                           ▼                      │
│                          ┌────────────────────────────────────┐  │
│                          │ claude-code-shim (systemd-user)    │  │
│                          │  FastAPI on 127.0.0.1:8787         │  │
│                          │                                    │  │
│                          │  asyncio.create_subprocess_exec(    │  │
│                          │    claude -p "<flattened prompt>"   │  │
│                          │    --model claude-sonnet-4-6        │  │
│                          │    --output-format json)            │  │
│                          └────────────────┬───────────────────┘  │
│                                           │ stdout=JSON          │
│                                           ▼                      │
│                          ┌────────────────────────────────────┐  │
│                          │ claude CLI (official, v2.1+)       │  │
│                          │  reads ~/.claude/.credentials.json  │  │
│                          │  builds request with correct UA,    │  │
│                          │  anthropic-beta, system preamble    │  │
│                          └────────────────┬───────────────────┘  │
│                                           │ HTTPS                │
│                                           ▼                      │
│                              api.anthropic.com (Claude Pro/Max)  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

## Components

### 1. nanobot gateway
* Installed as a `uv tool`, binary at `~/.local/bin/nanobot`.
* Driven by `~/.nanobot/config.json`, which is scaffolded by
  `nanobot onboard` and then patched by `scripts/install.sh`.
* **Provider** is set to `custom` (nanobot's generic OpenAI-compat adapter),
  with `apiBase=http://127.0.0.1:8787/v1`. Model string uses nanobot's
  `provider/model` convention, e.g. `custom/claude-sonnet-4-6`.
* **Telegram** channel uses grammy under the hood (polling mode).
  `streaming: false` is important — see *Gotchas* below.
* **Input allowlist** must contain at least `["*"]`, otherwise nanobot boots
  with `"telegram" has empty allowFrom (denies all)` and exits.

### 2. claude-code-shim
* Single-file FastAPI app in `shim/server.py`.
* Runs under its own systemd-user unit with a clean `PATH` and an absolute
  `CLAUDE_BIN` — without that, `subprocess_exec` hits
  `FileNotFoundError` because systemd-user doesn't inherit the login
  `~/.local/bin`.
* Strips outer `HTTP(S)_PROXY` from the child environment so the `claude`
  CLI always talks directly to `api.anthropic.com` using its built-in trust
  store.
* Implements a small **internal retry loop** (default 3) for the case where
  `claude -p` returns `{"result": ""}` on cold start. Without this, nanobot's
  own provider retry triggers, which is slower and often ends in
  `"Empty response on turn 0"` surfaced to Telegram.
* Maps Claude's `stop_reason` to OpenAI's `finish_reason`. Leaving
  `"end_turn"` verbatim causes strict OpenAI clients (like nanobot's SDK)
  to treat the response as incomplete and retry.

### 3. claude CLI
* Not shipped by this repo — must be installed and signed in beforehand
  (`claude` once interactively → `~/.claude/.credentials.json`).
* The only component that holds the subscription OAuth token.
* Handles token refresh, user-agent, beta headers, everything.

## What this repo deliberately does NOT do

* **No HTTPS MITM.** There is no gateway that re-encrypts traffic; every
  request to `api.anthropic.com` is signed by the official client with its
  real TLS chain and trust store.
* **No token impersonation.** nanobot never receives the OAuth token, so
  it can't leak it and can't be tempted to spoof Claude Code's fingerprint.
* **No custom CA in any Python trust store.** The shim is plain HTTP on
  loopback; no certificate trust dance.
* **No OneCLI in the runtime path.** (It can still run alongside for other
  services — it's just irrelevant to this flow.)

## Request lifecycle, step by step

1. Telegram user sends a message. nanobot's long-poll picks it up.
2. nanobot's agent loop converts the message (plus recent history + system
   preamble) into an OpenAI-style `messages` array and POSTs it to
   `http://127.0.0.1:8787/v1/chat/completions`.
3. The shim flattens the messages into a `User:/Assistant:` transcript,
   extracts `system` content, and spawns `claude -p <prompt> --model
   <model> --output-format json --append-system-prompt <sys>`.
4. claude CLI signs and sends the real request to api.anthropic.com,
   reads the response, and writes a single JSON object to stdout.
5. The shim maps `result`, `usage`, and `stop_reason` into an OpenAI
   `chat.completion` object and returns it.
6. nanobot treats that like any OpenAI response, formats for Telegram,
   calls `sendMessage` via grammy. Message appears in the chat.

Typical cold-start wall-clock: **10–15 s**. Subsequent calls inside the
same idle window can be a few seconds faster because Claude Code caches
its MCP-init artefacts.

## File layout on the VPS after install

```
~/.claude/.credentials.json      ← OAuth; created by `claude login`
~/.nanobot/config.json           ← patched by install.sh
~/.nanobot/secrets.env           ← optional, loaded by nanobot.service
~/.config/systemd/user/claude-shim.service
~/.config/systemd/user/nanobot.service
~/.local/state/claude-shim/shim.log
~/.local/state/nanobot/nanobot.log
~/nanobot-claude-oauth/shim/     ← copy of shim/ used by the unit
```

## Gotchas

Quick summary of the hardest-to-find ones (the long version is in
[LEARNINGS.md](LEARNINGS.md)):

* **PATH inside systemd-user** does not include `~/.local/bin`. Set
  `CLAUDE_BIN` and `PATH` explicitly in the unit.
* **`allowFrom: []` in nanobot** = deny-all. Must be at least `["*"]`.
* **`streaming: true`** on the telegram channel uses `editMessage`; if
  combined with a provider that returns in a single chunk, the flow is
  racy. Keep it off unless you implement SSE in the shim.
* **`stop_reason="end_turn"`** looks like "incomplete" to OpenAI strict
  clients — map it to `"stop"`.
* **Empty `result` on cold start** happens occasionally from the claude
  CLI. The shim retries internally before returning, which keeps nanobot
  from surfacing "Internal Server Error" to Telegram.
