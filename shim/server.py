"""
OpenAI-compat shim that delegates to the locally-installed Claude Code CLI.

Why: nanobot uses the Anthropic Python SDK directly. With a Claude Pro/Max
subscription OAuth token, that path hits fingerprinting (429) because the
request does not look like Claude Code. The nanoclaw project avoids that by
running the legitimate @anthropic-ai/claude-code inside a container and
letting it do the API call itself. This shim mirrors that idea for nanobot:
it accepts OpenAI /v1/chat/completions, then shells out to `claude -p` which
is the real, authorized client. No MITM, no header spoofing — claude CLI
authenticates via the standard ~/.claude/.credentials.json on this machine.

Ports: listens on 127.0.0.1:${PORT:-8787}. Point nanobot's `custom` /
`openai-compat` provider at http://127.0.0.1:8787/v1.
"""
import asyncio
import json
import logging
import os
import time
import uuid

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

CLAUDE_BIN = os.environ.get("CLAUDE_BIN", "claude")
DEFAULT_MODEL = os.environ.get("DEFAULT_MODEL", "claude-sonnet-4-6")
MAX_INTERNAL_RETRIES = int(os.environ.get("MAX_INTERNAL_RETRIES", "3"))
CLAUDE_TIMEOUT_S = int(os.environ.get("CLAUDE_TIMEOUT_S", "180"))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("shim")

app = FastAPI(title="claude-code-shim")


def build_prompt(messages):
    """Turn an OpenAI `messages` list into (system_prompt, transcript_prompt).

    claude -p takes a single prompt argument and an optional --append-system-prompt.
    We flatten user/assistant turns into a 'User:/Assistant:' transcript so the
    model sees the full context, and concatenate any `system` messages into the
    system prompt.
    """
    system_parts = []
    convo_parts = []
    for m in messages:
        role = m.get("role")
        content = m.get("content")
        if isinstance(content, list):
            content = "".join(
                p.get("text", "") for p in content if p.get("type") == "text"
            )
        if not content:
            continue
        if role == "system":
            system_parts.append(content)
        elif role == "user":
            convo_parts.append(f"User: {content}")
        elif role == "assistant":
            convo_parts.append(f"Assistant: {content}")
    system_prompt = "\n\n".join(system_parts) if system_parts else None
    prompt = "\n\n".join(convo_parts) if convo_parts else ""
    return system_prompt, prompt


@app.get("/v1/models")
def models():
    ids = ["claude-sonnet-4-6", "claude-opus-4-7", "claude-haiku-4-5"]
    return {
        "object": "list",
        "data": [
            {"id": i, "object": "model", "created": int(time.time()), "owned_by": "anthropic"}
            for i in ids
        ],
    }


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/v1/chat/completions")
async def chat(req: Request):
    body = await req.json()
    model = body.get("model") or DEFAULT_MODEL
    # Allow nanobot's 'provider/model' convention, e.g. 'custom/claude-sonnet-4-6'.
    if "/" in model:
        model = model.split("/", 1)[1]
    messages = body.get("messages", [])
    system_prompt, prompt = build_prompt(messages)

    log.info("claude call: model=%s prompt=%r sys=%r",
             model, prompt[:200], (system_prompt or "")[:120])

    # Never leak an outer HTTP(S)_PROXY into the child (we don't want nanobot's
    # onecli proxy, if someone is experimenting with one, to be inherited).
    env = {k: v for k, v in os.environ.items()
           if not k.upper().startswith(("HTTP_PROXY", "HTTPS_PROXY"))}
    env.pop("http_proxy", None)
    env.pop("https_proxy", None)

    content = ""
    result = {}
    last_error = None
    for attempt in range(1, MAX_INTERNAL_RETRIES + 1):
        cmd = [CLAUDE_BIN, "-p", prompt, "--model", model, "--output-format", "json"]
        if system_prompt:
            cmd += ["--append-system-prompt", system_prompt]
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
        )
        try:
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(), timeout=CLAUDE_TIMEOUT_S
            )
        except asyncio.TimeoutError:
            proc.kill()
            last_error = "claude CLI timed out"
            log.warning("attempt %d: timeout", attempt)
            continue
        if proc.returncode != 0:
            last_error = stderr.decode(errors="replace")[:500]
            log.warning("attempt %d: non-zero exit %s err=%s",
                        attempt, proc.returncode, last_error[:200])
            continue
        try:
            result = json.loads(stdout.decode())
        except json.JSONDecodeError as exc:
            last_error = f"bad JSON: {exc}"
            log.warning("attempt %d: bad JSON %s", attempt, last_error)
            continue
        content = (result.get("result") or "").strip()
        if content:
            log.info("attempt %d: ok, content_len=%d", attempt, len(content))
            break
        last_error = f"empty result (stop_reason={result.get('stop_reason')!r})"
        log.warning("attempt %d: %s", attempt, last_error)

    if not content:
        return JSONResponse(
            {"error": {"message": last_error or "no content", "type": "claude_cli_error"}},
            status_code=502,
        )

    usage = result.get("usage", {}) or {}
    # Map Claude's stop_reason to OpenAI's finish_reason. Using "end_turn"
    # verbatim causes strict OpenAI clients (nanobot) to treat the response
    # as incomplete and retry.
    stop_map = {
        "end_turn": "stop",
        "stop_sequence": "stop",
        "max_tokens": "length",
        "tool_use": "tool_calls",
    }
    raw_stop = result.get("stop_reason")
    finish = stop_map.get(raw_stop, "stop")
    return {
        "id": "chatcmpl-" + uuid.uuid4().hex,
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": content},
                "finish_reason": finish,
            }
        ],
        "usage": {
            "prompt_tokens": usage.get("input_tokens", 0),
            "completion_tokens": usage.get("output_tokens", 0),
            "total_tokens": usage.get("input_tokens", 0) + usage.get("output_tokens", 0),
        },
    }
