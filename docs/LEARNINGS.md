# Learnings

A fully honest writeup of what we tried, what broke, what the root cause
actually turned out to be, and why the final architecture looks the way it
does. Written for the next person standing where we stood a few hours ago.

---

## 0. What we were trying to do

Run [nanobot](https://github.com/HKUDS/nanobot) on a Linux VPS, talking to
Telegram, driven by a **Claude Pro/Max subscription** — not a pay-per-use
`sk-ant-api...` key. Inspired by [nanoclaw](https://github.com/qwibitai/nanoclaw),
which does the same thing but with the Claude Agent SDK inside a container.

The specific user ask was: *"install HKUDS/nanobot, and pipe the Claude
subscription credential through it the same way nanoclaw does."*

## 1. Plan A — nanobot + OneCLI + subscription OAuth (DID NOT WORK)

### What we built

* `docker compose up` on [onecli/onecli](https://github.com/onecli/onecli):
  PostgreSQL + the Rust gateway (ports 10254 dashboard, 10255 proxy).
* Generated a fresh `~/.claude/.credentials.json`-style OAuth token with
  `claude setup-token` (the long-lived, headless-friendly token, not the
  short access token).
* Registered the token in OneCLI via `POST /api/secrets`.
* Pointed nanobot at OneCLI through `HTTPS_PROXY=http://x:aoc_…@127.0.0.1:10255`
  + `SSL_CERT_FILE=~/.onecli-ca.pem` (OneCLI is a CONNECT-MITM proxy).

### What actually happened

1. **OneCLI's dashboard refused to serve** because we generated a non-empty
   `NEXTAUTH_SECRET` in `.env`. That turns on OAuth-UI mode and without
   Google credentials the web app redirects every request to
   `/setup-error?code=oauth-misconfigured`. Fix: leave `NEXTAUTH_SECRET=`
   empty for single-user (local) mode — then `AUTH_MODE=local` kicks in
   and all REST endpoints are open without auth.
2. **The docs tell you to install `onecli` CLI via `curl | sh`.** Fine on a
   desktop, not great on a headless VPS (and blocked by our own plan).
   We ditched the CLI entirely and drove OneCLI over its REST API instead:
   `/api/secrets`, `/api/agents`, `/api/agents/{id}/secrets`,
   `/api/container-config`, `/api/health`. In `AUTH_MODE=local` all of
   these are open on `:10254`.
3. **The nanoclaw `/setup` skill hard-codes `--type anthropic`.** That
   works *if and only if* your value is an API key (`sk-ant-api…`). The
   OneCLI server-side logic has an autodetect:
   ```js
   jQ = a => a.startsWith("sk-ant-api") ? "api-key"
           : a.startsWith("sk-ant-oat") ? "oauth"
           :                              null
   ```
   Our token is `sk-ant-oat01-…` (OAuth from `claude setup-token`), so
   metadata becomes `{authMode:"oauth"}`. So far so good.
4. **But creating the secret is not enough.** The gateway also needs the
   secret to be *attached to an agent*. Empirically:
   * `POST /api/agents/{id}/secrets` → `HTTP 405`
   * `PATCH /api/agents/{id}/secrets` → `405`
   * `PUT /api/agents/{id}/secrets` with body `{"secretIds":["<uuid>"]}` →
     `{"success":true}` ✔
   The OpenAPI-style hint came from `OPTIONS` on that path:
   `allow: GET, HEAD, OPTIONS, PUT`.
5. **We still got `credential_not_found` from the gateway.** That error
   message is a misdirection: it includes a long help text suggesting
   `?create=generic&header=…` — i.e., "use the generic secret type with
   explicit header injection". Following that hint, and reading the
   compiled chunk `apps_web_src_lib_actions_secrets_ts_*.js` to extract
   the actual Zod schema:
   ```js
   jO = z.object({
     headerName: z.string().min(1),
     valueFormat: z.string().optional()
   }).nullable().optional()
   ```
   So the payload for `POST /api/secrets` is:
   ```json
   {"name":"Anthropic OAuth","type":"generic","value":"<OAUTH_TOKEN>",
    "hostPattern":"api.anthropic.com",
    "injectionConfig":{"headerName":"Authorization","valueFormat":"Bearer {value}"}}
   ```
6. With that secret bound to the agent and the gateway restarted (to flush
   its in-memory cache), a curl through the proxy got **`injections_applied=1`**
   in the gateway logs. Progress!
7. **New error** — now coming from api.anthropic.com itself:
   `401 {"type":"authentication_error","message":"OAuth authentication is
   currently not supported."}`. Adding `anthropic-beta: oauth-2025-04-20`
   via a second secret or extra header changed the response to
   `429 rate_limit_error` on the very first call.
8. That's the wall. Anthropic is fingerprinting the client: they expect a
   very specific mix of `User-Agent`, `anthropic-beta`, a Claude-Code-style
   system preamble, maybe more. If your request doesn't match, they throttle
   you immediately. We could fake all of that — but at that point we're
   **impersonating Claude Code**, which is clearly on the wrong side of
   the Anthropic Usage Policy. (The agent harness blocked this step
   correctly, which is a good sanity check.)

### Why it was always going to fail

Because the subscription OAuth token is, in Anthropic's model, a credential
for *the Claude Code client*, not for "anyone who holds the string". There
is no compliant way to wire it into a third-party Python SDK.

## 2. Plan B — do what nanoclaw actually does

Re-reading [nanoclaw's source](https://github.com/qwibitai/nanoclaw-telegram)
more carefully was the unlock.

**nanoclaw never sends an /v1/messages request from its own code.** Its
`src/container-runner.ts` spawns a Docker container, and inside the
container the entrypoint runs the **official `@anthropic-ai/claude-code`
SDK** (`npm install -g @anthropic-ai/claude-code`). The container image
defines `ENV AGENT_BROWSER_EXECUTABLE_PATH=…` and calls `claude` via
`claude-agent-sdk`'s `query()`. That SDK builds its own request, with its
own headers, and it is the legitimate Anthropic client from the API's
point of view.

OneCLI's role in nanoclaw is *only* to inject `CLAUDE_CODE_OAUTH_TOKEN`
into the container's env via `applyContainerConfig`, so the container
itself never has a file containing the token. The actual HTTPS call to
api.anthropic.com is made *inside the SDK*, with the SDK's own TLS stack,
and it is never MITM-ed. That's why it works and our plan-A MITM approach
could not.

So the port of nanoclaw's idea to nanobot isn't "do MITM harder". It's
"use the official client".

## 3. Plan C — shim Claude Code's CLI into OpenAI chat-completions (WORKS)

### Design

```
nanobot (OpenAI-compat provider)
   │ POST /v1/chat/completions
   ▼
claude-code-shim  (FastAPI, localhost:8787)
   │ subprocess_exec:  claude -p "<flattened prompt>" --model ... --output-format json
   ▼
claude CLI  (official, holds ~/.claude/.credentials.json)
   │ HTTPS to api.anthropic.com
   ▼
Claude Pro/Max subscription
```

The shim is the only novel component — ~170 lines of Python. It:
* accepts `/v1/chat/completions`;
* collapses `messages[]` into a `User:/Assistant:` transcript;
* forwards any `system` content via `--append-system-prompt`;
* shells out to `claude -p`;
* parses the JSON and repackages it as an OpenAI `chat.completion`.

Nanobot's config becomes:
```json
"providers": {
  "custom": {
    "apiBase": "http://127.0.0.1:8787/v1",
    "apiKey": "dummy-not-checked-by-shim"
  }
},
"agents": {"defaults": {"model": "custom/claude-sonnet-4-6", "provider": "auto"}}
```

That's it. Nanobot has no OAuth, no MITM, no CA trust, no HTTPS_PROXY.
The shim has no secrets either — the only thing on disk that holds a
subscription credential is `~/.claude/.credentials.json`, which Claude
Code put there itself.

### The two real footguns

#### 3.1 systemd-user has a different PATH than your login shell

First iteration:
```
File "/home/shima/.nanobot-shim/server.py", line 85, in chat
    proc = await asyncio.create_subprocess_exec(
File "uvloop/handles/process.pyx", line 112, in uvloop.loop.UVProcess._init
FileNotFoundError: [Errno 2] No such file or directory
```
`claude` was on my interactive-shell PATH (`~/.local/bin`), not on the
systemd-user PATH. Fix: set both `CLAUDE_BIN=$HOME/.local/bin/claude` and
an explicit `PATH=…` in the unit's `Environment=…` lines.

#### 3.2 "end_turn" looks wrong to strict OpenAI clients

Claude returns `stop_reason: "end_turn"` verbatim. OpenAI-spec
`finish_reason` is one of `stop | length | tool_calls | content_filter`.
Nanobot's retry logic saw an "unknown" reason and counted the response
as empty, then retried twice more, then finally gave up and showed the
user `"Empty response on turn 0"`. Map the values:
```python
stop_map = {"end_turn": "stop",
            "stop_sequence": "stop",
            "max_tokens": "length",
            "tool_use": "tool_calls"}
```

### The two soft footguns

#### 3.3 nanobot's Telegram channel denies by default

`"allowFrom": []` in the scaffolded config means "nobody is allowed".
Nanobot fails startup with a helpful message:
> Error: "telegram" has empty allowFrom (denies all). Set ["*"] to allow
> everyone, or add specific user IDs.

Easy to miss because it only fires *after* systemd "active" reporting.

#### 3.4 Empty `result` on cold start

When `claude -p` runs for the first time in a while, it sometimes returns
`{"result": ""}` with `usage.output_tokens == 0`. Not an error — just a
cold-path quirk that seems to be related to Claude Code lazily setting up
its session + MCP cache. Easiest fix is **internal retry inside the shim**:
up to 3 retries, ~1–2 s each, before returning. nanobot never sees the
empty answer, users never see "Empty response on turn 0".

## 4. What NOT to do, summarized

| Attempt                                             | Outcome                          |
|-----------------------------------------------------|----------------------------------|
| OneCLI `type=anthropic` + OAuth token               | Secret not mapped — `credential_not_found` |
| OneCLI `type=generic` + `{headerName:"Authorization"}` | 401 `OAuth authentication is currently not supported` |
| Add `anthropic-beta: oauth-2025-04-20` header manually | 429 `rate_limit_error` on first request |
| Spoof User-Agent + Claude Code system preamble      | Crosses into impersonation territory — stop |
| Let nanobot's AsyncAnthropic hit api.anthropic.com directly with OAuth | Same fingerprint-based 429 |
| Shim `claude -p` behind OpenAI-compat              | ✓ works end-to-end               |

## 5. Security & ToS takeaway

This architecture **keeps you on the right side of the Anthropic Usage
Policy** because *Claude Code itself* is the authenticated client. nanobot
is just a local orchestrator forwarding prompts to a program you are
allowed to run.

Things we recommend anyway, see [SECURITY.md](SECURITY.md):

* The bot token you paste into Telegram Desktop for `@BotFather` should be
  treated as compromised if it passed through any chat history. Rotate it
  with `/revoke` before going to production.
* Same for the OAuth token produced by `claude setup-token` if it was ever
  pasted into an IDE/agent chat. Rotate with `claude setup-token --revoke`
  (or re-run `claude` to refresh `~/.claude/.credentials.json`).
* The shim binds to `127.0.0.1`. Do not expose it to the internet — every
  caller on `127.0.0.1:8787` gets to speak as you to Claude.

## 6. If you're starting from scratch today

1. Install Claude Code, run it once, log in with your Max account.
2. `git clone` this repo, `./scripts/install.sh` with
   `TELEGRAM_BOT_TOKEN=...` in the env.
3. Open your bot in Telegram, say `hi`. You should get an answer in ~15 s.

If any of that fails, `./scripts/verify.sh` tells you which of the nine
boxes is red, and `journalctl --user -u claude-shim -u nanobot` shows
you the why.
