# Docker smoke test for scripts/install.sh.
#
# The real claude CLI needs browser OAuth and the real nanobot needs
# systemd — neither is practical in CI. We mock both at the PATH level
# and verify that install.sh completes cleanly, produces a patched
# ~/.nanobot/config.json, and resolves the claude binary path into
# the systemd unit.
#
# Usage: tests/run-tests.sh
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      sudo ca-certificates curl git jq python3 python3-venv \
 && rm -rf /var/lib/apt/lists/*

# Test user with passwordless sudo — bootstrap.sh's sudo -v exits 0
RUN useradd -m -s /bin/bash -G sudo tester \
 && echo 'tester ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# Mock binaries via /usr/local/bin — first in PATH for systemd and scripts
COPY tests/fake-claude /usr/local/bin/claude
COPY tests/fake-systemctl /usr/local/bin/systemctl
COPY tests/fake-systemctl /usr/local/bin/loginctl
COPY tests/fake-systemctl /usr/local/bin/nanobot
RUN chmod +x /usr/local/bin/claude /usr/local/bin/systemctl /usr/local/bin/loginctl /usr/local/bin/nanobot

USER tester
WORKDIR /home/tester

# Fake signed-in credentials so install.sh's precheck passes
RUN mkdir -p /home/tester/.claude \
 && echo '{"subscription":"pro","token":"fake"}' > /home/tester/.claude/.credentials.json

# Install uv into the user's ~/.local/bin as install.sh expects
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/home/tester/.local/bin:${PATH}"

# Copy repo tree into the expected location
COPY --chown=tester:tester . /home/tester/nanobot-claude-oauth
WORKDIR /home/tester/nanobot-claude-oauth

# Drop the smoke test from install.sh (it would POST to 127.0.0.1:8787
# where nothing is listening). We still verify config patching and
# unit generation explicitly below.
RUN sed -i '/^# ---------- 6. smoke test ----------/,$d' scripts/install.sh

# Run install.sh with mocked env. Smoke-test would need a live shim,
# which would need systemd — out of scope for this stage.
# USER is set by interactive shells automatically but not by docker
# build RUN; install.sh's linger block references it.
ENV USER=tester \
    TELEGRAM_BOT_TOKEN="123:mocktoken" \
    NANOBOT_MODEL="claude-sonnet-4-6" \
    NANOBOT_TZ="UTC"
RUN ./scripts/install.sh

# Assert the install produced the expected artifacts
RUN set -eux; \
    test -f "$HOME/.nanobot/config.json"; \
    jq -e '.agents.defaults.model == "custom/claude-sonnet-4-6"' "$HOME/.nanobot/config.json"; \
    jq -e '.agents.defaults.timezone == "UTC"' "$HOME/.nanobot/config.json"; \
    jq -e '.providers.custom.apiBase == "http://127.0.0.1:8787/v1"' "$HOME/.nanobot/config.json"; \
    jq -e '.channels.telegram.enabled == true' "$HOME/.nanobot/config.json"; \
    test -f "$HOME/.config/systemd/user/claude-shim.service"; \
    grep -q "^Environment=\"CLAUDE_BIN=/usr/local/bin/claude\"" "$HOME/.config/systemd/user/claude-shim.service"; \
    grep -q "^Environment=\"PATH=/usr/local/bin:/home/tester/.local/bin" "$HOME/.config/systemd/user/claude-shim.service"; \
    echo "ALL ASSERTIONS PASSED"
