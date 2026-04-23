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

## Fresh server setup — step by step

Follow these steps in order on a brand-new Linux VPS (tested on Ubuntu 22.04 / 24.04).
**Everything from step 4 onwards runs as a dedicated non-root user** —
this is required because Claude Code refuses to run with
`--dangerously-skip-permissions` under root, and our shim needs that flag.

### 1. SSH into the VPS as root

```bash
ssh root@<your-vps-ip>
```

### 2. Create a non-root user (one-time, as root)

Pick any name — this guide uses `claude`. You will log in with this
account from now on; never as root.

```bash
# Create the user (will prompt for a password — remember it,
# you'll use it to SSH in later). Hit Enter through the name/phone fields.
adduser claude

# Grant sudo rights. You'll type the password once at the start of the
# bootstrap; sudo caches it (default 15 min) and the installer refreshes
# the timestamp in the background so no further prompts appear.
usermod -aG sudo claude

# Keep user services alive after SSH logout. Must be run as root —
# regular users cannot enable linger for themselves.
loginctl enable-linger claude
```

### 3. Install Node.js and Claude Code CLI (still as root)

Claude Code needs Node ≥ 20. Ubuntu 24.04 ships with Node 20; on 22.04 add
the NodeSource repo first (`curl -fsSL https://deb.nodesource.com/setup_20.x | bash -`).

```bash
apt update
apt install -y nodejs npm
npm install -g @anthropic-ai/claude-code
```

Installing `claude` system-wide means every user on the box can run it —
we only OAuth once, in step 4.

### 4. Switch to the `claude` user and sign in to Claude Code

```bash
su - claude          # becomes the new user; prompt will change
claude               # prints a URL — open it in YOUR LOCAL browser,
                     # complete Pro/Max OAuth, paste the code back
```

When `claude` shows a REPL prompt after the browser flow, the token is
saved to `~/.claude/.credentials.json`. Hit `Ctrl-D` or type `/exit` to
leave the REPL. Do **not** skip this step — the installer checks for that
file and will abort without it.

### 5. Run the one-liner installer (as `claude`)

```bash
curl -fsSL https://raw.githubusercontent.com/smixs/nanobot-claude/main/scripts/bootstrap.sh | bash
```

The installer asks three questions:

1. **Telegram bot token** — get one from [@BotFather](https://t.me/BotFather); leave blank to skip Telegram entirely (you can enable it later in `~/.nanobot/config.json`)
2. **Claude model** — `claude-sonnet-4-6` (default), `claude-opus-4-7`, or `claude-haiku-4-5`
3. **Timezone** — IANA name, e.g. `Europe/Moscow`, `UTC`, `Asia/Tashkent`

It then installs dependencies (`git`, `curl`, `jq`, `uv`), clones the
repo into `~/nanobot-claude-oauth`, patches `~/.nanobot/config.json`
to point at the local shim, installs and starts two systemd-user
services (`claude-shim` on port 8787, `nanobot` on port 18790),
and runs a smoke test. Total time ≈ 2 minutes. You'll be asked for
your sudo password **once** at the very beginning — the installer
caches it and refreshes the timestamp in the background, so no
repeat prompts.

### 6. From now on, SSH in as `claude` — not root

```bash
# Don't do this anymore:
ssh root@<vps>

# Do this:
ssh claude@<vps>
```

Everything lives under `/home/claude` — services, configs, logs.
Services auto-start on boot thanks to `linger`.

Send a message to your Telegram bot to verify end-to-end.

## Prerequisites (manual install only)

* Linux VPS with **systemd**
* `node >= 20`, `uv`, `jq`, `curl`, `systemctl`
* **A non-root user with sudo rights** — Claude Code refuses to run with `--dangerously-skip-permissions` under root
* **Claude Code** installed and signed in: `claude` once interactively so
  `~/.claude/.credentials.json` is populated
* (For Telegram) a bot token from [@BotFather](https://t.me/BotFather)

## Advanced / manual install

For CI, reinstalls, or when you want to pass configuration through
environment variables rather than answering the bootstrap prompts.
Must still run as a non-root user (see step 2 of the fresh-server
guide above):

```bash
git clone https://github.com/smixs/nanobot-claude.git ~/nanobot-claude-oauth
cd ~/nanobot-claude-oauth

# Optional: pass TELEGRAM_BOT_TOKEN to wire up the Telegram channel in one shot
TELEGRAM_BOT_TOKEN=123456:AA...  NANOBOT_TZ=Europe/Moscow  ./scripts/install.sh
```

`scripts/install.sh` is idempotent. It:

1. Verifies prerequisites and that Claude Code is already signed in
2. Installs `nanobot-ai` via `uv tool install` (if missing)
3. Runs `nanobot onboard` to scaffold `~/.nanobot/config.json` (if missing)
4. Patches that config to use a `custom` provider pointed at the local shim
5. Installs two systemd-user units (`claude-shim`, `nanobot`) and starts them
6. Resolves the `claude` binary path dynamically so the unit works
   regardless of whether it's in `~/.local/bin` or `/usr/local/bin`
7. Smoke-tests the shim with a `reply exactly: pong` prompt

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
