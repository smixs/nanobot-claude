# nanobot-claude-oauth

Run [**nanobot**](https://github.com/HKUDS/nanobot) (multi-channel personal AI
assistant) on your **Claude Pro / Max subscription**, without putting the
OAuth token inside nanobot, and without fighting Anthropic's anti-abuse
fingerprinting.

It does that with a **~170-line OpenAI-compatible shim** that forwards
`/v1/chat/completions` to the official `claude` CLI. Claude Code is the
legitimate client — it signs the request the way Anthropic expects, using the
credentials already stored in `~/.claude/.credentials.json`. Nanobot talks
OpenAI-compat over `http://127.0.0.1:8787/v1` and never sees a subscription
token, a certificate, or an API key.

> Inspired by the [**nanoclaw**](https://github.com/qwibitai/nanoclaw)
> pattern: let the official client do the API call. This project ports the
> idea to nanobot via a local OpenAI shim instead of a Docker container.

## TL;DR

```
Telegram ─► nanobot (OpenAI-compat provider)
                │  POST /v1/chat/completions
                ▼
         claude-code-shim  (127.0.0.1:8787, systemd-user)
                │  subprocess:  claude -p "<prompt>" --output-format json
                ▼
         claude CLI (official Anthropic client)
                │  reads ~/.claude/.credentials.json
                ▼
         api.anthropic.com  ── Claude Pro/Max subscription
```

## Prerequisites

* Linux VPS with **systemd**
* `node >= 20`, `uv`, `jq`, `curl`, `systemctl`
* **Claude Code** installed and signed in: `claude` once interactively so
  `~/.claude/.credentials.json` is populated
* (For Telegram) a bot token from [@BotFather](https://t.me/BotFather)

## Install

```bash
git clone https://github.com/<you>/nanobot-claude-oauth.git
cd nanobot-claude-oauth

# Optional: pass TELEGRAM_BOT_TOKEN to wire up the Telegram channel in one shot
TELEGRAM_BOT_TOKEN=123456:AA...  NANOBOT_TZ=Europe/Moscow  ./scripts/install.sh
```

`scripts/install.sh` is idempotent. It:

1. Verifies prerequisites and that Claude Code is already signed in
2. Installs `nanobot-ai` via `uv tool install` (if missing)
3. Runs `nanobot onboard` to scaffold `~/.nanobot/config.json` (if missing)
4. Patches that config to use a `custom` provider pointed at the local shim
5. Installs two systemd-user units (`claude-shim`, `nanobot`) and starts them
6. Smoke-tests the shim with a `reply exactly: pong` prompt

Verify at any time:
```bash
./scripts/verify.sh
```

Uninstall:
```bash
./scripts/uninstall.sh
```

## Why this repo exists

We tried the obvious "textbook" path first: store the subscription token in
[**OneCLI**](https://github.com/onecli/onecli) (a credential vault + MITM
proxy), point nanobot through `HTTPS_PROXY` at the gateway, let OneCLI inject
the `Authorization` header.

That gets very close to working — **OneCLI does inject headers correctly**,
the TLS chain does work, the token is accepted — but **Anthropic's API
returns `429 rate_limit_error`** as soon as it sees a request that doesn't
"look like" Claude Code (wrong User-Agent, wrong `anthropic-beta` combo, no
expected system preamble). Spoofing those headers would be ToS-sketchy
imperionation, so we stopped chasing it.

Instead we took the [nanoclaw](https://github.com/qwibitai/nanoclaw)
approach: stop pretending to be Claude Code, and just *run* Claude Code. The
shim is the only thing that differs — we translate OpenAI chat-completions to
`claude -p` calls.

Full chronicle of dead ends and fixes in [docs/LEARNINGS.md](docs/LEARNINGS.md).

## Repository layout

```
nanobot-claude-oauth/
├── shim/                 FastAPI app (server.py) + pyproject.toml
├── systemd/              claude-shim.service, nanobot.service
├── config/               example config.json patch, example secrets.env
├── scripts/              install.sh, uninstall.sh, verify.sh
└── docs/
    ├── ARCHITECTURE.md   why each component exists, data flow
    ├── LEARNINGS.md      what we tried, what broke, why
    └── SECURITY.md       ToS posture, recommendations
```

## Status & caveats

* Works for chat messages. Streaming (`stream: true`) is **not** implemented
  in the shim yet — nanobot is configured with `streaming: false` to match.
* Tool-use / function-calling passthrough is not implemented. If nanobot
  asks for tools, the shim will return a plain assistant message. Good
  enough for the default Telegram chat workflow; extend `server.py` if you
  need structured tool calls.
* Cold-start latency of `claude -p` is ~10 s per call (SDK load + auth
  handshake). Keep that in mind when sizing request timeouts.
* OneCLI is **not** in the runtime path here. If you still want it for
  other outbound APIs (Parallel, OpenAI, Resend, …) you can run it alongside
  — this project just ignores it.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

* [HKUDS/nanobot](https://github.com/HKUDS/nanobot) — the framework we are
  wiring up.
* [qwibitai/nanoclaw](https://github.com/qwibitai/nanoclaw) — the architecture
  pattern we borrowed.
* [anthropics/claude-code](https://docs.claude.com/en/docs/claude-code) —
  the actual workhorse.
