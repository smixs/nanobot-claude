# Security posture

## Threat model this project *is* designed for

* **You own the VPS.** You're the only user on it.
* **You hold a Claude Pro/Max subscription** and want to use it to power
  your own tools that you host on that VPS.
* Nothing in the flow is multi-tenant. There is no "customer" other than
  the owner.

## Threat model this project *is NOT* designed for

* **Sharing one subscription among multiple people.** Technically the
  shim does not authenticate callers — anyone who can reach
  `127.0.0.1:8787` can burn your quota. Don't make it multi-tenant.
* **Public LLM gateway.** Don't expose the shim or the nanobot HTTP
  surface to the internet.
* **Billing-sensitive isolation.** If a rogue nanobot skill somehow spawns
  abuse prompts in a loop, the usage lands on your Max account like any
  other Claude Code session would.

## Secrets on disk

| File                              | Contents                 | Protection |
|-----------------------------------|--------------------------|------------|
| `~/.claude/.credentials.json`     | Claude OAuth tokens      | `chmod 600`, owned by you; managed by Claude Code itself |
| `~/.nanobot/config.json`          | Telegram bot token (inline) | `chmod 600` by `install.sh` |
| `~/.nanobot/secrets.env`          | (optional env overrides) | `chmod 600` if you add secrets |

The shim keeps nothing on disk.

## Tokens to rotate if they've been exposed

If you ever pasted a token into a chat (AI assistant, Slack,
screenshot, support ticket), rotate it:

* **Telegram bot token** → [@BotFather](https://t.me/BotFather) →
  `/revoke` → select bot → paste the new token into
  `~/.nanobot/config.json` (`.channels.telegram.token`) → `systemctl --user
  restart nanobot`.
* **Claude subscription OAuth** → run `claude setup-token --revoke`
  if you still have the token, or just `claude login` again to refresh
  `~/.claude/.credentials.json`. (The shim picks up the new creds with no
  restart because `claude` re-reads the file per invocation.)

## Agent tool permissions (READ THIS)

The shim passes `--dangerously-skip-permissions` to `claude -p`. That means
the agent can use **Bash, Read, Write, Edit, WebFetch, WebSearch** with no
per-call confirmation. Any prompt that reaches the shim can ask the agent
to run arbitrary shell commands as the VPS user.

Because the shim has no auth of its own, *anyone who can POST to
`127.0.0.1:8787/v1/chat/completions`* can run code on the VPS. On the
default install that surface is reached through the Telegram bot, so the
effective perimeter is your nanobot `allowFrom` list.

**Never ship with `allowFrom: ["*"]`.** Set it to a list of your Telegram
user_ids (look at a nanobot log line like
`Telegram message from 7091451031|shimaoz` to find yours):

```jsonc
"channels": {
  "telegram": {
    "allowFrom": ["7091451031"],   // your ID, nobody else
    ...
  }
}
```

If you need a multi-user deployment, replace
`--dangerously-skip-permissions` in `shim/server.py` with an
`--allowed-tools` whitelist such as `Read Glob Grep WebFetch WebSearch`
(no Bash, no Write), so an abusive message cannot escalate to code
execution.

## Transport

* Shim listens on loopback only. No TLS — it's local, trust boundary is
  `127.0.0.1`.
* Claude Code's outbound TLS to `api.anthropic.com` uses the system
  trust store. No custom CA.
* Telegram's polling traffic uses Telegram's own TLS. No proxy.

## Audit

* `journalctl --user -u claude-shim`: one line per incoming chat with
  model, truncated prompt, and content length. Does **not** log the full
  assistant output (privacy).
* `journalctl --user -u nanobot`: nanobot's internal logs — includes the
  user-visible reply at INFO level. Rotate or redirect if you don't want
  a plain-text conversation log.

## Anthropic Usage Policy posture

This architecture uses the **official Claude Code client** to make every
request. Anthropic sees a regular Claude Code session, authenticated via
the OAuth token they issued to you. There is no spoofing of headers, no
MITM of their TLS, and no impersonation of another client.

That is deliberately different from the OneCLI-based attempt in
[LEARNINGS.md](LEARNINGS.md), which required pretending to be Claude
Code at the header level. If you decide to bring OneCLI back into the
flow for other services, keep it strictly for non-Anthropic outbound
APIs.
