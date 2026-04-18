"""
OpenAI-compat shim that delegates to the locally-installed Claude Code CLI.

Mirrors the nanoclaw pattern: Claude Code is the legitimate client. This shim
just adapts its CLI I/O to /v1/chat/completions so nanobot (OpenAI-compat
provider) can talk to it. No MITM, no spoofing — claude CLI authenticates via
the standard ~/.claude/.credentials.json on this machine.
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

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("shim")

app = FastAPI(title="claude-code-shim")


def build_prompt(messages):
    """Turn OpenAI messages into (system_prompt, transcript_prompt).
    Multi-turn history is flattened into a 'User:/Assistant:' transcript so
    claude -p sees the full context; system messages go to --append-system-prompt.
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
    if "/" in model:
        model = model.split("/", 1)[1]
    messages = body.get("messages", [])
    system_prompt, prompt = build_prompt(messages)

    log.info("claude call: model=%s prompt=%r sys=%r", model, prompt[:200], (system_prompt or "")[:120])

    env = {k: v for k, v in os.environ.items() if not k.upper().startswith(("HTTP_PROXY", "HTTPS_PROXY"))}
    env.pop("http_proxy", None)
    env.pop("https_proxy", None)

    content = ""
    result = {}
    last_error = None
    for attempt in range(1, MAX_INTERNAL_RETRIES + 1):
        cmd = [
            CLAUDE_BIN, "-p", prompt,
            "--model", model,
            "--output-format", "json",
            "--dangerously-skip-permissions",
        ]
        if system_prompt:
            cmd += ["--append-system-prompt", system_prompt]
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
        )
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=180)
        except asyncio.TimeoutError:
            proc.kill()
            last_error = "claude CLI timed out"
            continue
        if proc.returncode != 0:
            last_error = stderr.decode(errors="replace")[:500]
            log.warning("attempt %d: non-zero exit %s err=%s", attempt, proc.returncode, last_error[:200])
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
    # Map Claude stop_reason → OpenAI finish_reason
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
