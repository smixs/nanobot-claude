# claude-code-shim

A ~170-line FastAPI app that exposes the locally-installed `claude` CLI as an
OpenAI-compatible chat-completions endpoint so any OpenAI-compat client (nanobot,
LiteLLM users, your own apps) can consume your Claude Pro/Max subscription
without ever seeing the OAuth token.

## Endpoints

| Method | Path                    | Purpose                        |
|--------|-------------------------|--------------------------------|
| GET    | `/health`               | Liveness probe                 |
| GET    | `/v1/models`            | Static list (Sonnet/Opus/Haiku) |
| POST   | `/v1/chat/completions`  | Main endpoint                  |

## Environment

| Var                   | Default                 | Meaning                          |
|-----------------------|-------------------------|----------------------------------|
| `CLAUDE_BIN`          | `claude`                | Absolute path if not on PATH     |
| `DEFAULT_MODEL`       | `claude-sonnet-4-6`     | Fallback if caller omits model   |
| `MAX_INTERNAL_RETRIES`| `3`                     | Retries for empty-result case    |
| `CLAUDE_TIMEOUT_S`    | `180`                   | Per-attempt timeout              |

## Message mapping

* OpenAI `system` → `claude --append-system-prompt`
* `user` / `assistant` history → flattened as `User:/Assistant:` transcript
  and passed as `claude -p <prompt>`
* Claude `stop_reason` → OpenAI `finish_reason`
  (`end_turn` → `stop`, `max_tokens` → `length`, `tool_use` → `tool_calls`)
* Claude `usage.input_tokens` / `output_tokens` → OpenAI `usage.*`

## Running locally

```bash
uv sync
uv run uvicorn server:app --host 127.0.0.1 --port 8787
```

## Under systemd

See `../systemd/claude-shim.service` — installed via `../scripts/install.sh`.
